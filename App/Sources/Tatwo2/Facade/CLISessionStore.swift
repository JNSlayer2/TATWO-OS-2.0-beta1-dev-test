import Foundation

public enum CLISessionStatus: String, Codable, Sendable { case running, waitingInput, exited, unknown }

/// Metadata is small; all scrollback I/O and writes are serialized off the UI thread.
final class CLISessionStore: @unchecked Sendable {
    struct Record: Codable, Identifiable, Sendable, Equatable {
        var id: UUID
        var title: String
        var engine: String
        var cwd: String
        var createdAt: Date
        var lastActiveAt: Date
        var status: CLISessionStatus
        var exitCode: Int32?
        var pinned: Bool
        var order: Int
        // Optional for old JSON records. Absence never authorizes relaunch.
        var threadID: UUID? = nil
        var projectID: UUID? = nil
        var tmuxName: String? = nil
        var background: Bool? = nil
    }
    struct Workspace: Codable {
        var tabs: [CLIWorkbenchTab] = []
        var selectedTabID: UUID?
    }
    struct Workbench: Codable {
        var version = 1
        var threads: [String: Workspace] = [:]
        var editingOptions = CLIWorkbenchEditingOptions()
    }
    private(set) var workbench = Workbench()
    private var workbenchWritable = true
    private var workbenchGeneration = 0
    let root: URL
    private let queue = DispatchQueue(label: "tatwo.cli.persistence", qos: .utility)
    private let lock = NSLock()
    private var records: [Record] = []
    private var buffers: [UUID: Data] = [:]
    private var metadataWritable = true
    private var errorMessage: String?
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return errorMessage }
    static let limit = 2 * 1024 * 1024
    /// tmux capture includes unused screen rows. Text consumers want output, not
    /// a suffix consisting solely of the bottom of an otherwise empty screen.
    static func textTail(_ text: String, lines: Int) -> String {
        var rows = text.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        return rows.suffix(max(0, min(lines, 10000))).joined(separator: "\n")
    }

    init(root: URL) {
        self.root = root
        let metadataURL = root.appendingPathComponent("cli-sessions.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            do {
                records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: metadataURL))
            } catch {
                // Preserve unreadable/corrupt user metadata rather than replacing it with [].
                metadataWritable = false
                errorMessage = "metadata read: \(error)"
            }
        }
        let workspaceURL = root.appendingPathComponent("cli-workbench.json")
        if FileManager.default.fileExists(atPath: workspaceURL.path) {
            do {
                workbench = try JSONDecoder().decode(Workbench.self, from: Data(contentsOf: workspaceURL))
                workbenchWritable = workbench.version == 1
            } catch {
                workbenchWritable = false
                errorMessage = "workbench read: \(error)"
            }
        }
        // Only the tmux runtime can confirm survival. Never trust cached running state.
        for i in records.indices where records[i].status != .exited {
            records[i].status = records[i].tmuxName == nil ? .exited : .unknown
            records[i].exitCode = nil
        }
        let initial = records
        queue.async { [self] in persist(initial) }
    }
    var sessions: [Record] {
        lock.lock(); defer { lock.unlock() }
        return records.sorted { $0.order < $1.order }
    }
    func update(_ id: UUID, _ change: (inout Record) -> Void) {
        lock.lock()
        guard let i = records.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let old = records[i]
        change(&records[i])
        guard old != records[i] else { lock.unlock(); return }
        let snapshot = records
        queue.async { [self] in persist(snapshot) }
        lock.unlock()
    }
    func insert(_ record: Record) {
        lock.lock()
        guard !records.contains(where: { $0.id == record.id }) else { lock.unlock(); return }
        records.append(record)
        let snapshot = records
        queue.async { [self] in persist(snapshot) }
        lock.unlock()
    }
    func append(_ data: Data, to id: UUID) {
        queue.async { [self] in
            lock.lock()
            var buffer = buffers[id] ?? Data()
            buffer.append(data)
            buffer = Data(buffer.suffix(Self.limit))
            buffers[id] = buffer
            lock.unlock()
            do {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("cli-scrollback"), withIntermediateDirectories: true)
                let url = logURL(id)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try Data().write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size + UInt64(data.count) > UInt64(Self.limit) {
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: buffer)
                    try handle.truncate(atOffset: UInt64(buffer.count))
                } else { try handle.write(contentsOf: data) }
            } catch { report(error) }
        }
    }
    func scrollback(_ id: UUID) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffers[id] ?? Data(), as: UTF8.self)
    }
    /// Historical snapshots are loaded on demand, never eagerly on App launch.
    func loadScrollback(_ id: UUID) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let data: Data
                if let handle = try? FileHandle(forReadingFrom: logURL(id)) {
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEnd()) ?? 0
                    try? handle.seek(toOffset: size > UInt64(Self.limit) ? size - UInt64(Self.limit) : 0)
                    data = (try? handle.read(upToCount: Self.limit)) ?? Data()
                } else { data = Data() }
                lock.lock(); buffers[id] = data; lock.unlock()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
    func snapshot(_ data: Data, for id: UUID) {
        let bounded = Data(data.suffix(Self.limit))
        queue.async { [self] in
            lock.lock(); buffers[id] = bounded; lock.unlock()
            do {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("cli-scrollback"), withIntermediateDirectories: true)
                try bounded.write(to: logURL(id), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL(id).path)
            } catch { report(error) }
        }
    }
    func saveWorkbench(_ document: Workbench) {
        guard workbenchWritable else { return }
        lock.lock()
        workbench = document
        workbenchGeneration += 1
        let generation = workbenchGeneration
        lock.unlock()
        // Split dragging updates presentation immediately; only the settled layout hits the SSD.
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [self] in
            lock.lock()
            let current = generation == workbenchGeneration
            lock.unlock()
            if current { persistWorkbench(document) }
        }
    }
    func flush() async {
        lock.lock()
        workbenchGeneration += 1
        let document = workbench
        lock.unlock()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                persistWorkbench(document)
                continuation.resume()
            }
        }
    }
    /// App termination cannot leave a debounced layout write behind after process exit.
    func finishPendingWrites() {
        lock.lock()
        workbenchGeneration += 1
        let document = workbench
        lock.unlock()
        queue.sync { persistWorkbench(document) }
    }
    private func persistWorkbench(_ document: Workbench) {
        guard workbenchWritable else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("cli-workbench.json")
            try JSONEncoder().encode(document).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { report(error) }
    }
    func logURL(_ id: UUID) -> URL {
        root.appendingPathComponent("cli-scrollback/\(id.uuidString.lowercased()).log")
    }
    private func persist(_ snapshot: [Record]) {
        guard metadataWritable else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("cli-sessions.json")
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        lock.lock(); errorMessage = String(describing: error); lock.unlock()
        fputs("cli_persistence_error=\(error)\n", stderr)
    }
}
