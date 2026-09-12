import Foundation
import Darwin

/// App-owned long-running commands launched for one discussion thread.
/// Jobs are intentionally limited to the App's user privileges and are persisted under LIVE_ROOT.
final class BackgroundJobManager: @unchecked Sendable {
    struct Record: Codable, Sendable {
        var jobID: UUID
        var pid: Int32
        var title: String
        var command: String
        var cwd: String
        var logPath: String
        var threadID: UUID
        var startedAt: Date
        var state: String
        var exitCode: Int32?
        var requestKey: String? = nil
        var stopRequested: Bool? = nil
        var terminationSignal: Int32? = nil

        var completionStatus: String {
            if state == "unknown" { return "info|背景工作狀態未知" }
            if let signal = terminationSignal {
                return stopRequested == true && (signal == SIGTERM || signal == SIGKILL)
                    ? "info|背景工作已取消" : "error|背景工作失敗"
            }
            guard let exitCode else { return "info|背景工作結果未知" }
            return exitCode == 0 ? "success|背景工作完成" : "error|背景工作失敗"
        }
    }

    private let queue = DispatchQueue(label: "ai.tatwo.tatwo2.background-jobs")
    private let root: URL
    private let registryURL: URL
    private var records: [UUID: Record] = [:]
    private var processes: [UUID: Process] = [:]
    private var timer: DispatchSourceTimer?
    private var completion: (@MainActor @Sendable (Record) -> Void)?
    /// Registry transitions stay serialized; observers never run on the job queue.
    /// Replay uses the original job ID so the transcript can durably deduplicate.
    var onCompletion: (@MainActor @Sendable (Record) -> Void)? {
        get { queue.sync { completion } }
        set {
            queue.sync {
                completion = newValue
                for record in records.values.sorted(by: { $0.startedAt < $1.startedAt })
                    where record.state != "running" {
                    notify(record)
                }
            }
        }
    }

    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        registryURL = self.root.appendingPathComponent("bg-jobs.json")
        queue.sync {
            try? FileManager.default.createDirectory(at: self.root.appendingPathComponent("bg", isDirectory: true), withIntermediateDirectories: true)
            load()
            refreshDetachedJobs()
            persist()
            updateTimer()
        }
    }

    deinit { timer?.cancel() }

    func run(command: String, cwd: String, title: String, threadID: UUID, requestKey: String? = nil) throws -> Record {
        try queue.sync {
            if let requestKey {
                guard !requestKey.isEmpty, requestKey.utf8.count <= 256 else {
                    throw NSError(domain: "BackgroundJobManager", code: 2)
                }
                if let existing = records.values.first(where: {
                    $0.threadID == threadID && $0.requestKey == requestKey && Date().timeIntervalSince($0.startedAt) >= 0 && Date().timeIntervalSince($0.startedAt) < 600
                }) { return existing }
            }
            var isDirectory: ObjCBool = false
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw NSError(domain: "BackgroundJobManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid_params"])
            }
            let id = UUID()
            let logURL = root.appendingPathComponent("bg", isDirectory: true).appendingPathComponent("\(id.uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] finished in
                log.closeFile()
                self?.queue.async {
                    guard let self, var current = self.records[id], current.state == "running" else { return }
                    current.state = "exited"
                    current.exitCode = finished.terminationStatus
                    current.terminationSignal = finished.terminationReason == .uncaughtSignal
                        ? finished.terminationStatus : nil
                    self.records[id] = current
                    self.processes[id] = nil
                    self.persist()
                    self.updateTimer()
                    self.notify(current)
                }
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                log.closeFile()
                throw error
            }
            _ = setpgid(process.processIdentifier, process.processIdentifier)
            var record = Record(jobID: id, pid: process.processIdentifier, title: title, command: command, cwd: cwd,
                                logPath: logURL.path, threadID: threadID, startedAt: Date(), state: "running", exitCode: nil)
            record.requestKey = requestKey
            records[id] = record
            processes[id] = process
            persist()
            record = records[id] ?? record
            return record
        }
    }

    /// Read-only projection. All log I/O stays on the job queue; never refreshes or persists.
    struct Snapshot: Sendable {
        var jobID: UUID
        var title: String
        var state: String
        var startedAt: Date
        var lastLine: String
        var threadID: UUID? = nil
        var exitCode: Int32? = nil
    }
    func snapshot(includeLastLine: Bool = true) async -> [Snapshot] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let rows = records.values.sorted { $0.startedAt < $1.startedAt }.prefix(200).map { record in
                    Snapshot(jobID: record.jobID, title: record.title, state: record.state,
                             startedAt: record.startedAt, lastLine: includeLastLine ? lastLine(record.logPath) : "",
                             threadID: record.threadID, exitCode: record.exitCode)
                }
                continuation.resume(returning: rows)
            }
        }
    }
    private func lastLine(_ path: String) -> String {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return "" }
        try? file.seek(toOffset: size > 8192 ? size - 8192 : 0)
        guard let data = try? file.read(upToCount: 8192) else { return "" }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    func status(jobID: UUID) -> Record? {
        queue.sync {
            refresh(jobID)
            return records[jobID]
        }
    }

    func stop(jobID: UUID) -> Record? {
        queue.sync {
            refresh(jobID)
            requestStop(jobID)
            return records[jobID]
        }
    }

    func stopAll() {
        queue.sync {
            for id in Array(records.keys) { refresh(id); requestStop(id) }
            // This path is also used during App termination: its delayed blocks
            // may never execute. Keep the existing bounded shutdown grace.
            if processes.values.contains(where: \.isRunning) {
                usleep(200_000)
                for process in processes.values where process.isRunning
                    && getpgid(process.processIdentifier) == process.processIdentifier {
                    _ = terminateGroup(process.processIdentifier, signal: SIGKILL)
                }
            }
        }
    }

    private func requestStop(_ id: UUID) {
        guard var record = records[id], record.state == "running", record.stopRequested != true else { return }
        // Never signal PID 0/1 or an unrelated process group.
        guard record.pid > 1, getpgid(record.pid) == record.pid,
              processes[id].map({ $0.isRunning }) ?? true,
              terminateGroup(record.pid, signal: SIGTERM) else { return }
        record.stopRequested = true
        records[id] = record
        persist()
        // One bounded escalation, not a blocking wait on the main/job queue.
        // A detached PID has no retained Process identity: do not guess later.
        if let process = processes[id] {
            queue.asyncAfter(deadline: .now() + 2) { [weak self, weak process] in
                guard let self, let process, process.isRunning,
                      self.processes[id] === process,
                      self.records[id]?.state == "running",
                      getpgid(process.processIdentifier) == process.processIdentifier else { return }
                _ = self.terminateGroup(process.processIdentifier, signal: SIGKILL)
            }
        }
    }

    /// Caller-scoped metadata only. Does not open any job log.
    func list(threadID: UUID) -> [[String: Any]] {
        queue.sync {
            records.values.filter { $0.threadID == threadID }
                .sorted { $0.startedAt > $1.startedAt }.prefix(50)
                .map { metadata($0) }
        }
    }

    private func metadata(_ record: Record) -> [String: Any] {
        var value: [String: Any] = [
            "jobID": record.jobID.uuidString, "title": record.title, "state": record.state,
            "startedAt": Self.iso8601.string(from: record.startedAt),
            "elapsedSec": max(0, Int(Date().timeIntervalSince(record.startedAt))),
            "logPath": record.logPath,
        ]
        if let code = record.exitCode { value["exitCode"] = code }
        if let requested = record.stopRequested { value["stopRequested"] = requested }
        if let signal = record.terminationSignal { value["terminationSignal"] = signal }
        return value
    }

    func response(_ record: Record, tailBytes: Int = 8192) -> [String: Any] {
        var value = metadata(record)
        value["pid"] = record.pid
        value["logTail"] = tail(record.logPath, bytes: min(65536, max(0, tailBytes)))
        return value
    }

    /// Owned processes already have termination callbacks. Poll only detached jobs.
    private func updateTimer() {
        let needed = records.values.contains { $0.state == "running" && processes[$0.jobID] == nil }
        guard needed else { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.refreshAll() }
        timer.resume(); self.timer = timer
    }

    var pollsDetachedJobs: Bool { queue.sync { timer != nil } }
    private func refreshAll() { for id in Array(records.keys) { refresh(id) }; updateTimer() }
    private func refresh(_ id: UUID) {
        guard var record = records[id], record.state == "running", processes[id] == nil else { return }
        if !processGroupAlive(record.pid) {
            // After relaunch there is no native wait status. Do not invent exit 0
            // or a cancellation result merely because a PID disappeared.
            record.state = "unknown"
            records[id] = record
            persist()
            updateTimer()
            notify(record)
        }
    }
    private func refreshDetachedJobs() { for id in records.keys { refresh(id) } }
    private func processGroupAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(-pid, 0) == 0 || errno == EPERM
    }
    @discardableResult private func terminateGroup(_ pid: Int32, signal: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(-pid, signal) == 0
    }
    private func notify(_ record: Record) {
        guard let completion else { return }
        DispatchQueue.main.async { completion(record) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: registryURL) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let rows = try? decoder.decode([Record].self, from: data) { records = Dictionary(uniqueKeysWithValues: rows.map { ($0.jobID, $0) }) }
    }
    private func persist() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records.values.sorted { $0.startedAt < $1.startedAt }) { try? data.write(to: registryURL, options: .atomic) }
    }
    private func tail(_ path: String, lines: Int) -> String {
        let data = Self.readLogTail(path)
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    private func tail(_ path: String, bytes: Int) -> String {
        guard bytes > 0, let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return "" }
        try? file.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? file.read(upToCount: bytes) else { return "" }
        // Trim incomplete UTF-8 at the byte boundary rather than expanding replacement characters.
        for offset in 0...min(3, data.count) {
            if let text = String(data: data.dropFirst(offset), encoding: .utf8) { return text }
        }
        return String(data: Data(data.map { $0 < 128 ? $0 : 63 }), encoding: .utf8) ?? ""
    }
    static func readLogTail(_ path: String) -> Data {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return Data() }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            try file.seek(toOffset: size > 65536 ? size - 65536 : 0)
            return try file.read(upToCount: 65536) ?? Data()
        } catch { return Data() }
    }
    private static let iso8601 = ISO8601DateFormatter()
}
