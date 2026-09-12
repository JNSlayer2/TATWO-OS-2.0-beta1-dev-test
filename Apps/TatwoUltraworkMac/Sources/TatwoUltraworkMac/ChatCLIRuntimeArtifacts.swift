import Foundation
import Darwin
import CryptoKit
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore

enum ChatCLITemporaryFileOwner {
    private static let gatewayPromptPrefix = ".tatwo-gateway-prompt-"
    private static let gatewayContinuationPrefix =
        ".tatwo-gateway-continuation-"
    private static let stalePromptMinimumAge: TimeInterval = 24 * 60 * 60
    private static let stalePromptScanLimit = 256
    private static let stalePromptRemovalLimit = 16

    static func cleanup(_ file: TatwoChatOwnedTemporaryFile) {
        let url = URL(fileURLWithPath: file.path).standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard url.deletingLastPathComponent() == temporaryDirectory,
              (
                url.lastPathComponent.hasPrefix(gatewayPromptPrefix)
                    && url.pathExtension == "txt"
                || url.lastPathComponent.hasPrefix(gatewayContinuationPrefix)
                    && url.pathExtension == "json"
              )
        else {
            return
        }

        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              UInt64(bitPattern: Int64(info.st_dev)) == file.deviceID,
              UInt64(info.st_ino) == file.inode
        else {
            return
        }
        _ = Darwin.unlink(url.path)
    }

    /// Best-effort crash recovery for prompt files whose owning App process
    /// never reached a launch/termination cleanup path. The scan and removals
    /// are both bounded, and only old, regular, mode-0600 files owned by this
    /// uid are eligible.
    @discardableResult
    static func cleanupStaleGatewayPromptFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        minimumAge: TimeInterval = stalePromptMinimumAge,
        scanLimit: Int = stalePromptScanLimit,
        removalLimit: Int = stalePromptRemovalLimit
    ) -> Int {
        let standardizedDirectory = directory.standardizedFileURL
        guard let handle = Darwin.opendir(standardizedDirectory.path) else {
            return 0
        }
        defer { Darwin.closedir(handle) }

        var scanned = 0
        var removed = 0
        while scanned < max(0, scanLimit),
              removed < max(0, removalLimit),
              let entry = Darwin.readdir(handle)
        {
            scanned += 1
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            let isGatewayPrompt =
                name.hasPrefix(gatewayPromptPrefix)
                    && name.hasSuffix(".txt")
            let isGatewayContinuation =
                name.hasPrefix(gatewayContinuationPrefix)
                    && name.hasSuffix(".json")
            guard isGatewayPrompt || isGatewayContinuation
            else {
                continue
            }
            let url = standardizedDirectory.appendingPathComponent(
                name,
                isDirectory: false)
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }

            var openedInfo = stat()
            let opened = Darwin.fstat(descriptor, &openedInfo) == 0
            _ = Darwin.close(descriptor)
            guard opened,
                  openedInfo.st_mode & S_IFMT == S_IFREG,
                  openedInfo.st_uid == getuid(),
                  openedInfo.st_mode & 0o077 == 0,
                  now.timeIntervalSince1970
                    - TimeInterval(openedInfo.st_mtimespec.tv_sec)
                    >= max(0, minimumAge)
            else {
                continue
            }

            // Bind the path we unlink to the inode opened with O_NOFOLLOW.
            var currentInfo = stat()
            guard Darwin.lstat(url.path, &currentInfo) == 0,
                  currentInfo.st_mode & S_IFMT == S_IFREG,
                  currentInfo.st_dev == openedInfo.st_dev,
                  currentInfo.st_ino == openedInfo.st_ino
            else {
                continue
            }
            if Darwin.unlink(url.path) == 0 {
                removed += 1
            }
        }
        return removed
    }
}

enum ChatCLIRuntimeRootFactory {
    static func defaultRoot(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executableURL: URL? = Bundle.main.executableURL,
        processID: pid_t = getpid()
    ) -> URL {
        let isTestProcess =
            environment["XCTestConfigurationFilePath"] != nil
            || environment["SWIFT_TESTING"] == "1"
        let executablePath = executableURL?.standardizedFileURL.path ?? "unknown-executable"
        var identity = [
            bundleIdentifier ?? "unbundled",
            executablePath,
            environment["TATWO_ULTRAWORK_RUNTIME_INSTANCE_ID"] ?? ""
        ].joined(separator: "\u{1F}")
        if isTestProcess {
            // Test bundles can run concurrently from the same executable path.
            // Keep their maintenance and stream files process-local.
            identity += "\u{1F}xctest-\(processID)"
        }
        let readable = (bundleIdentifier ?? executableURL?.lastPathComponent ?? "runtime")
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" {
                    return character
                }
                return "-"
            }
        return temporaryDirectory
            .appendingPathComponent("tatwo-ultrawork-chat-cli", isDirectory: true)
            .appendingPathComponent("instances", isDirectory: true)
            .appendingPathComponent(
                "\(String(readable).prefix(48))-\(stableDigest(identity))",
                isDirectory: true)
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

enum ChatCLIRuntimeArtifactRetirement {
    @discardableResult
    static func retireReclaimableArtifacts(
        in root: URL,
        authority: ChatRunnerAuthoritySnapshot,
        policy: ChatCLIRuntimeRetentionPolicy = .production,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        guard case .authoritative(let activeRunIDs, let reclaimTokens) = authority else {
            // Unknown authority is not an empty active set. Preserve every
            // artifact until exact formal-terminal reclaim authority exists.
            return 0
        }
        let reclaimableRunIDs = Set(
            reclaimTokens.map(\.runID)
                .filter { !activeRunIDs.contains($0) })
        guard !reclaimableRunIDs.isEmpty else { return 0 }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else {
            return 0
        }

        let cutoff = now.addingTimeInterval(-max(0, policy.minimumArtifactAge))
        var candidates: [URL] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey
            ]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt <= cutoff,
                  reclaimableRunIDs.contains(where: {
                      isArtifact(entry.lastPathComponent, for: $0)
                  })
            else {
                continue
            }
            candidates.append(entry)
        }
        guard !candidates.isEmpty else { return 0 }

        // Work OS deletion policy forbids permanent deletion. Retention removes
        // terminal artifacts from the hot scan set by atomically moving them
        // into an instance-local archive; active and authority-unknown files
        // never enter this path.
        let archive = root
            .appendingPathComponent("retired", isDirectory: true)
            .appendingPathComponent(
                "\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)",
                isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: archive,
                withIntermediateDirectories: true)
        } catch {
            return 0
        }

        var retired = 0
        for candidate in candidates {
            let destination = archive.appendingPathComponent(candidate.lastPathComponent)
            do {
                try fileManager.moveItem(at: candidate, to: destination)
                retired += 1
            } catch {
                continue
            }
        }
        return retired
    }

    private static func isArtifact(_ fileName: String, for runID: String) -> Bool {
        if fileName == "spawn-\(runID).jsonl" {
            return true
        }
        for prefix in ["stdout-", "stderr-", "status-"] {
            guard fileName.hasPrefix("\(prefix)\(runID)") else { continue }
            let suffix = String(fileName.dropFirst(prefix.count + runID.count))
            if suffix.hasPrefix(".") || suffix.hasPrefix("-attempt") {
                return true
            }
        }
        return false
    }
}

struct ChatCLIRuntimeRetentionPolicy: Sendable, Equatable {
    let minimumArtifactAge: TimeInterval

    static let production = ChatCLIRuntimeRetentionPolicy(
        minimumArtifactAge: 7 * 24 * 60 * 60)
}

final class ChatCLIRuntimeSweepGate: @unchecked Sendable {
    private let lock = NSLock()
    private let debounceInterval: TimeInterval
    private var inFlight = false
    private var lastCompletedAt: Date?

    init(debounceInterval: TimeInterval = 30) {
        self.debounceInterval = max(0, debounceInterval)
    }

    func begin(now: Date = Date()) -> ChatCLIRuntimeSweepRequestResult {
        lock.lock()
        defer { lock.unlock() }
        if inFlight {
            return .alreadyRunning
        }
        if let lastCompletedAt,
           now.timeIntervalSince(lastCompletedAt) < debounceInterval {
            return .debounced
        }
        inFlight = true
        return .started
    }

    func complete(now: Date = Date()) {
        lock.lock()
        inFlight = false
        lastCompletedAt = now
        lock.unlock()
    }
}

enum ChatCLIRuntimeSweepRequestResult: Sendable, Equatable {
    case started
    case alreadyRunning
    case debounced
}

final class ChatCLIRuntimeEventFence: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptsNonterminalEvents = true
    private var formalTerminalCommitted = false

    func shouldEmitNonterminalEvent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsNonterminalEvents
    }

    @discardableResult
    func emitNonterminalEvent(_ emit: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsNonterminalEvents else { return false }
        emit()
        return true
    }

    @discardableResult
    func closeNonterminalEvents() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsNonterminalEvents else { return false }
        acceptsNonterminalEvents = false
        return true
    }

    @discardableResult
    func commitFormalTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !formalTerminalCommitted else { return false }
        acceptsNonterminalEvents = false
        formalTerminalCommitted = true
        return true
    }
}

final class ChatCLINoNapActivityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tokensByRunID: [String: NSObjectProtocol] = [:]

    @discardableResult
    func install(_ token: NSObjectProtocol, for runID: String) -> NSObjectProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return tokensByRunID.updateValue(token, forKey: runID)
    }

    func remove(for runID: String) -> NSObjectProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return tokensByRunID.removeValue(forKey: runID)
    }

    func contains(runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokensByRunID[runID] != nil
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return tokensByRunID.count
    }
}
