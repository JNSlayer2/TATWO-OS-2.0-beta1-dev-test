import Combine
import Foundation

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
}

enum RemoteThreadTransfer {
    enum TransferError: Error, LocalizedError {
        case unsafeRelativePath(String)
        case unreadableFile(String)
        case invalidBase64(String)

        var errorDescription: String? {
            switch self {
            case .unsafeRelativePath(let path): "unsafe_relative_path: \(path)"
            case .unreadableFile(let path): "unreadable_file: \(path)"
            case .invalidBase64(let path): "invalid_base64: \(path)"
            }
        }
    }

    static func changedFiles(in workdir: String) -> [RemoteThreadTransferFile] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workdir, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // 含新檔（untracked）：git diff 只列已追蹤的改動，離線新寫的檔會漏掉
        process.arguments = ["-C", workdir, "status", "--porcelain", "--untracked-files=all"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }

        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { raw -> RemoteThreadTransferFile? in
            // porcelain 每行 "XY path"（rename 是 "old -> new"）；刪除的檔不搬
            let line = String(raw)
            guard line.count > 3 else { return nil }
            let code = line.prefix(2)
            if code.contains("D") { return nil }
            var relativePath = String(line.dropFirst(3))
            if let arrow = relativePath.range(of: " -> ") { relativePath = String(relativePath[arrow.upperBound...]) }
            if relativePath.hasPrefix("\"") { relativePath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard (try? validatedRelativePath(relativePath)) != nil else { return nil }
            let url = URL(fileURLWithPath: workdir, isDirectory: true)
                .appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return RemoteThreadTransferFile(
                relativePath: relativePath,
                base64: data.base64EncodedString())
        }
    }

    static func write(_ files: [RemoteThreadTransferFile], to workdir: String) throws {
        let root = URL(fileURLWithPath: workdir, isDirectory: true).standardizedFileURL
        for file in files {
            let relativePath = try validatedRelativePath(file.relativePath)
            guard let data = Data(base64Encoded: file.base64) else {
                throw TransferError.invalidBase64(relativePath)
            }
            let destination = root.appendingPathComponent(relativePath).standardizedFileURL
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard destination.path.hasPrefix(rootPrefix) else {
                throw TransferError.unsafeRelativePath(relativePath)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                throw TransferError.unreadableFile(relativePath)
            }
        }
    }

    static func validatedRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = NSString(string: trimmed).pathComponents
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !components.contains(".."),
              !components.contains(".")
        else {
            throw TransferError.unsafeRelativePath(path)
        }
        return trimmed
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
