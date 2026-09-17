import Combine
import Foundation
import CryptoKit
import Darwin

struct RemoteThreadRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let statusLine: String
    let isRunning: Bool
}

struct RemoteProjectRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let threads: [RemoteThreadRow]
}

struct RemoteSidebarSection: Identifiable, Equatable, Sendable {
    var id: String { deviceID }
    let deviceID: String
    let deviceName: String
    let isOnline: Bool
    let lastSeenAt: Date
    let projects: [RemoteProjectRow]
}

struct RemoteThreadTransferMessage: Codable, Equatable, Sendable {
    let role: String
    let text: String
    let createdAt: Date

    init(role: String, text: String, createdAt: Date) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    init(_ message: ChatMessage) {
        role = message.role.storageValue
        text = message.text
        createdAt = message.createdAt
    }

    var chatMessage: ChatMessage {
        let parsedRole: ChatMessageRole
        switch role {
        case "user": parsedRole = .user
        case "system": parsedRole = .system
        default: parsedRole = .assistant
        }
        return ChatMessage(role: parsedRole, text: text, createdAt: createdAt)
    }
}

struct RemoteThreadTransferFile: Codable, Equatable, Sendable {
    let relativePath: String
    let base64: String
    // nil is a legacy/unproven packet, never permission to overwrite. "missing" is explicit.
    var baseSHA256: String? = nil
}

enum RemoteThreadTransfer {
    static let missing = "missing"
    private static let transactionLock = NSLock()
    enum TransferError: Error, LocalizedError {
        case unsafeRelativePath(String)
        case unreadableFile(String)
        case invalidBase64(String)
        case conflicts([String])
        case recoveryRequired(String)

        var errorDescription: String? {
            switch self {
            case .unsafeRelativePath(let path): "unsafe_relative_path: \(path)"
            case .unreadableFile(let path): "unreadable_file: \(path)"
            case .invalidBase64(let path): "invalid_base64: \(path)"
            case .conflicts(let paths): "conflicts: " + paths.joined(separator: ", ")
            case .recoveryRequired(let detail): "recovery_required: \(detail)"
            }
        }
    }

    struct Candidate {
        let path: String
        let automatic: Bool
        let observedSHA256: String?
    }

    /// Read every turn, not only latest.json. A git observation is NOT a thread edit.
    static func candidates(threadID: UUID, artifactsRoot: URL, workdir: String) throws -> [Candidate] {
        let folder = artifactsRoot.appendingPathComponent(threadID.uuidString)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "latest.json" }
        var indexes: [TurnArtifactIndex] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            guard data.count <= TurnArtifacts.maxIndexBytes else { throw TransferError.unreadableFile("artifact index") }
            let index = try JSONDecoder().decode(TurnArtifactIndex.self, from: data)
            guard index.threadID == threadID, index.artifacts.count <= TurnArtifacts.maxPaths else {
                throw TransferError.unreadableFile("artifact index")
            }
            indexes.append(index)
        }
        var rows: [String: TurnArtifact] = [:]
        for index in indexes.sorted(by: { $0.endedAt < $1.endedAt }) {
            for row in index.artifacts where !row.outside {
                // Keep the last structured edit even when later turns merely observe it.
                if row.claimed || rows[row.path]?.claimed != true { rows[row.path] = row }
            }
        }
        return try rows.keys.sorted().map { path in
            let row = rows[path]!
            let current = try snapshot(path, in: workdir)
            let observed = current.map { digest($0.data) }
            return Candidate(path: path, automatic: row.claimed && row.exists && current != nil
                && row.sha256 == observed, observedSHA256: observed)
        }
    }

    /// Compatibility for pull_thread: without thread provenance, transfer messages only.
    /// Never fall back to a whole-worktree git status inventory.
    static func changedFiles(in workdir: String) -> [RemoteThreadTransferFile] { [] }

    static func changedFiles(in workdir: String, paths: [String], baselines: [String: String],
                             observedHashes: [String: String]? = nil) throws -> [RemoteThreadTransferFile] {
        try paths.sorted().map { path in
            guard let base = baselines[path], let current = try snapshot(path, in: workdir) else {
                throw TransferError.unreadableFile(path)
            }
            if let observedHashes, observedHashes[path] != digest(current.data) {
                throw TransferError.conflicts([path + " (source changed after selection)"])
            }
            return RemoteThreadTransferFile(relativePath: path, base64: current.data.base64EncodedString(), baseSHA256: base)
        }
    }

    /// Sender's common ancestor must agree with the peer's original, not simply bless any
    /// same-name file currently on the peer. No HEAD / unknown ancestry fails closed.
    static func sourceBaselines(in workdir: String, paths: [String]) throws -> [String: String] {
        func git(_ args: [String]) throws -> (Int32, Data) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["--literal-pathspecs", "-C", workdir] + args
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, data)
        }
        let (status, headData) = try git(["rev-parse", "--verify", "HEAD"])
        guard status == 0 else { throw TransferError.unreadableFile("git HEAD baseline") }
        let head = String(decoding: headData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let (prefixStatus, prefixData) = try git(["rev-parse", "--show-prefix"])
        guard prefixStatus == 0 else { throw TransferError.unreadableFile("git path baseline") }
        let prefix = String(decoding: prefixData.dropLast(prefixData.last == 10 ? 1 : 0), as: UTF8.self)
        var result: [String: String] = [:]
        for path in paths {
            _ = try validatedRelativePath(path)
            let fullPath = prefix + path
            let (found, data) = try git(["show", "\(head):\(fullPath)"])
            if found == 0 { result[path] = digest(data) }
            else {
                let (listed, names) = try git(["ls-tree", "-z", "--full-tree", head, "--", fullPath])
                guard listed == 0, names.isEmpty else { throw TransferError.unreadableFile(path) }
                result[path] = missing
            }
        }
        return result
    }

    static func baselines(paths: [String], in workdir: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in paths { result[path] = try snapshot(path, in: workdir).map { digest($0.data) } ?? missing }
        return result
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Snapshot { let data: Data; let mode: mode_t }

    /// No symlink component is followed, including dangling links and the final leaf.
    /// Keep directory descriptors pinned for writes and rollback (not string-only checks).
    private static func parent(_ path: String, root: String) throws -> (Int32, String)? {
        let parts = try validatedRelativePath(path).split(separator: "/").map(String.init)
        let canonical = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        var fd = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TransferError.unreadableFile(path) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno; Darwin.close(fd)
            if next < 0 {
                if code == ENOENT { return nil }
                throw TransferError.unsafeRelativePath(path)
            }
            fd = next
        }
        return (fd, parts.last!)
    }

    private static func read(_ name: String, at fd: Int32) throws -> Snapshot? {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw TransferError.unsafeRelativePath(name)
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw TransferError.unsafeRelativePath(name) }
        return Snapshot(data: try handle.readToEnd() ?? Data(), mode: info.st_mode & 0o777)
    }

    private static func snapshot(_ path: String, in root: String) throws -> Snapshot? {
        guard let (fd, name) = try parent(path, root: root) else { return nil }
        defer { Darwin.close(fd) }
        return try read(name, at: fd)
    }

    private static func install(_ data: Data, name: String, fd: Int32, mode: mode_t, leftovers: inout [(Int32, String)]) throws {
        let stage = ".w72-" + UUID().uuidString
        let file = openat(fd, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else { throw TransferError.unreadableFile(name) }
        leftovers.append((fd, stage))
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        guard fchmod(file, mode) == 0, fsync(file) == 0, renameat(fd, stage, fd, name) == 0 else {
            throw TransferError.unreadableFile(name)
        }
        leftovers.removeLast()
    }

    /// Originals are copied outside the project before the first write. Successful or
    /// rolled-back receipts go to macOS Trash, never permanent deletion.
    static func write(_ files: [RemoteThreadTransferFile], to workdir: String,
                      backupDirectory: URL? = nil, beforeWrite: ((Int) throws -> Void)? = nil,
                      retire: ((URL) -> Void)? = nil) throws {
        guard !files.isEmpty else { return }
        transactionLock.lock(); defer { transactionLock.unlock() }
        let fm = FileManager.default
        var seen = Set<String>(), conflicts: [String] = []
        var prepared: [(RemoteThreadTransferFile, Data, Snapshot?)] = []
        for file in files {
            let path = try validatedRelativePath(file.relativePath)
            guard seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw TransferError.unsafeRelativePath(path) }
            guard let data = Data(base64Encoded: file.base64) else { throw TransferError.invalidBase64(path) }
            let original = try snapshot(path, in: workdir)
            if file.baseSHA256 == nil || file.baseSHA256 != (original.map { digest($0.data) } ?? missing) { conflicts.append(path) }
            prepared.append((file, data, original))
        }
        guard conflicts.isEmpty else { throw TransferError.conflicts(conflicts) }
        let backup = (backupDirectory ?? fm.temporaryDirectory).resolvingSymlinksInPath()
            .appendingPathComponent("w72-transfer-" + UUID().uuidString)
        let root = URL(fileURLWithPath: workdir).resolvingSymlinksInPath().standardizedFileURL
        guard root.path != "/", !backup.path.hasPrefix(root.path + "/") else { throw TransferError.unsafeRelativePath("backup inside project") }
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var manifest = "# W72 transfer recovery\n\nOriginal source: receiving project \(root.lastPathComponent) (relative paths below).\nRestore: copy N.original to its listed relative path; absent entries had no original.\nDo not permanently remove without independent approval.\n\n"
        for (i, entry) in prepared.enumerated() {
            if let original = entry.2 { try original.data.write(to: backup.appendingPathComponent("\(i).original")) }
            manifest += "- \(i).original → \(entry.0.relativePath): \(entry.0.baseSHA256 ?? "unproven"); mode \(String(entry.2?.mode ?? 0o644, radix: 8))\n"
        }
        let manifestURL = backup.appendingPathComponent("MANIFEST.md")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        var written: [(Int32, String, Int)] = [], opened: [Int32] = []
        var created: [(Int32, String)] = [], leftovers: [(Int32, String)] = []
        defer { for fd in opened { Darwin.close(fd) } }
        func makeParent(_ path: String) throws -> (Int32, String) {
            let parts = path.split(separator: "/").map(String.init)
            var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw TransferError.unreadableFile(path) }
            opened.append(fd)
            for part in parts.dropLast() {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(fd, part, 0o755) == 0 else { throw TransferError.unreadableFile(path) }
                    created.append((fd, part))
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw TransferError.unsafeRelativePath(path) }
                opened.append(next); fd = next
            }
            return (fd, parts.last!)
        }
        // Move newly created files/empty directories out rather than deleting work products.
        func archive(_ fd: Int32, _ name: String) throws {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &path) == 0 else { throw TransferError.unreadableFile(name) }
            let source = URL(fileURLWithPath: String(cString: path)).appendingPathComponent(name)
            try fm.moveItem(at: source, to: backup.appendingPathComponent("discard-" + UUID().uuidString))
        }
        do {
            for (i, entry) in prepared.enumerated() {
                try beforeWrite?(i)
                let (fd, name) = try makeParent(entry.0.relativePath)
                let now = try read(name, at: fd)
                guard (now.map { digest($0.data) } ?? missing) == entry.0.baseSHA256 else {
                    throw TransferError.conflicts([entry.0.relativePath])
                }
                try install(entry.1, name: name, fd: fd, mode: entry.2?.mode ?? 0o644, leftovers: &leftovers)
                written.append((fd, name, i))
            }
        } catch {
            var recoveryFailures: [String] = []
            for (fd, name, i) in written.reversed() {
                do {
                    // Rollback is also a write: never clobber a third-party edit made
                    // after our installation. Continue recovering independent files.
                    guard try read(name, at: fd).map({ digest($0.data) }) == digest(prepared[i].1) else {
                        throw TransferError.conflicts([prepared[i].0.relativePath])
                    }
                    if let original = prepared[i].2 {
                        try install(try Data(contentsOf: backup.appendingPathComponent("\(i).original")), name: name, fd: fd, mode: original.mode, leftovers: &leftovers)
                    } else { try archive(fd, name) }
                } catch { recoveryFailures.append(prepared[i].0.relativePath) }
            }
            for (fd, name) in leftovers {
                do { try archive(fd, name) } catch { recoveryFailures.append(name) }
            }
            for (fd, name) in created.reversed() {
                // An unexpected file in a newly created directory belongs to someone
                // else. Keep that directory rather than moving their work to Trash.
                do {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw TransferError.unreadableFile(name) }
                    defer { Darwin.close(child) }
                    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    guard fcntl(child, F_GETPATH, &path) == 0,
                          try fm.contentsOfDirectory(atPath: String(cString: path)).isEmpty else {
                        throw TransferError.conflicts([name])
                    }
                    try archive(fd, name)
                } catch { recoveryFailures.append(name) }
            }
            if !recoveryFailures.isEmpty {
                manifest += "\nNOT safe to remove: manual recovery required for " + recoveryFailures.joined(separator: ", ") + "\n"
                try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
                throw TransferError.recoveryRequired(backup.lastPathComponent)
            }
            manifest += "\nVerified reason safe to remove: transaction failed; original bytes restored.\n"
            try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
            if let retire { retire(backup) } else { retireBackup(backup) }
            throw error
        }
        manifest += "\nVerified reason safe to remove: every selected file passed baseline checks and installation completed.\n"
        // Receipt/Trash failure must not turn a completed transaction into a false failure.
        try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        if let retire { retire(backup) } else { retireBackup(backup) }
    }

    private static func retireBackup(_ backup: URL) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/trash")
        p.arguments = [backup.path]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        // Failure retains the recovery folder, never removes it permanently.
        if (try? p.run()) != nil { p.waitUntilExit() }
    }

    static func validatedRelativePath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"),
              !components.contains(".."), !components.contains("."), !components.contains(where: { $0.lowercased() == ".git" }), !components.contains("") else {
            throw TransferError.unsafeRelativePath(path)
        }
        return path
    }
}

@MainActor
final class RemoteDeviceSession: ObservableObject {
    enum State: Equatable, Sendable {
        case offline
        case connecting
        case online(Int64)
    }

    let device: DeviceRecord
    let link: RemoteHostLink
    @Published private(set) var engine: RemoteLiveEngine?
    @Published private(set) var state: State = .offline
    @Published private(set) var lastSeenAt: Date

    var onUpdate: (() -> Void)?
    var onHint: ((String) -> Void)?
    var document: TatwoNativeChatStoreDocument {
        engine?.document ?? lastDocument
    }

    private let environment: [String: String]
    private var lastDocument = TatwoNativeChatStoreDocument()
    private var retryDelay: TimeInterval = 30
    private var retryTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    init(
        device: DeviceRecord,
        link: RemoteHostLink,
        environment: [String: String]
    ) {
        self.device = device
        self.link = link
        self.environment = environment
        self.lastSeenAt = device.lastSeenAt
    }

    func start() {
        guard connectTask == nil, engine == nil else { return }
        state = .connecting
        onUpdate?()
        let link = self.link
        let device = self.device
        connectTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { () throws -> [String: Any] in
                    try link.connect(device: device)
                    return try link.call(method: "get_document", params: [:])   // 第一份文件也在背景拉
                }
            }.value
            guard let self else { return }
            self.connectTask = nil
            switch result {
            case .success(let initial):
                self.installConnectedEngine(initial: initial)
            case .failure(let error):
                self.markOffline(error: error)
            }
        }
    }

    @discardableResult
    func connectNow() -> Bool {
        if engine != nil { return true }
        connectTask?.cancel()
        connectTask = nil
        retryTask?.cancel()
        retryTask = nil
        state = .connecting
        onUpdate?()
        do {
            try link.connect(device: device)
            let initial = try link.call(method: "get_document", params: [:])
            installConnectedEngine(initial: initial)
            return true
        } catch {
            markOffline(error: error)
            return false
        }
    }

    func shutdown() {
        retryTask?.cancel()
        connectTask?.cancel()
        retryTask = nil
        connectTask = nil
        engine?.shutdownAll()
        engine = nil
        link.disconnect()
        state = .offline
    }

    private func installConnectedEngine(initial: [String: Any]? = nil) {
        do {
            let cacheRoot = remoteCacheRoot()
            let remote = try RemoteLiveEngine(
                link: link,
                store: ChatLiveStore(root: cacheRoot),
                initial: initial)
            remote.onHint = { [weak self] message in self?.onHint?(message) }
            remote.onChange = { [weak self, weak remote] in
                guard let self, let remote, self.engine === remote else { return }
                self.lastDocument = remote.document
                self.state = .online(remote.currentRevision)
                self.lastSeenAt = Date()
                self.onUpdate?()
            }
            remote.onConnectionStateChange = { [weak self, weak remote] result in
                guard let self, let remote, self.engine === remote else { return }
                switch result {
                case .success(let revision):
                    self.lastDocument = remote.document
                    self.state = .online(revision)
                    self.lastSeenAt = Date()
                    self.retryDelay = 30
                    self.onUpdate?()
                case .failure(let error):
                    self.lastDocument = remote.document
                    remote.shutdownAll()
                    self.engine = nil
                    self.markOffline(error: error)
                }
            }
            engine = remote
            lastDocument = remote.document
            state = .online(remote.currentRevision)
            lastSeenAt = Date()
            retryDelay = 30
            onUpdate?()
        } catch {
            markOffline(error: error)
        }
    }

    private func markOffline(error: Error) {
        engine = nil
        link.disconnect()
        state = .offline
        onHint?("遠端設備 \(device.name) 離線：\(error.localizedDescription)")
        onUpdate?()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.start()
        }
    }

    private func remoteCacheRoot() -> URL {
        let localRoot = environment["TATWO2_LIVE_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("tatwo2/live", isDirectory: true)
        return localRoot
            .appendingPathComponent("remote-sessions", isDirectory: true)
            .appendingPathComponent(device.id, isDirectory: true)
    }
}
