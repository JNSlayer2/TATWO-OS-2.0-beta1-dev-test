import CryptoKit
import Darwin
import Foundation

/// Exact identity of one physical runner attempt.
///
/// `runID` alone is not authority: a bridge retry or relaunched runner can
/// reuse the logical run while changing the physical attempt. Every durable
/// cancellation mutation is therefore bound to all four fields.
struct ChatRunnerAttemptIdentity: Codable, Sendable, Equatable, Hashable {
    let runID: String
    let attempt: UInt64
    let instanceID: UUID
    let revision: UInt64
}

/// Exact compare-and-swap precondition for replacing one physical attempt
/// with the next attempt of the same logical run.
///
/// A caller may request rollover only after it has durably observed the
/// previous exact generation enter `attemptTerminal`. The authority registry
/// independently rechecks both that phase/status and that the previous PID
/// plus launchctl identity are inactive before committing the new claim.
enum ChatRunnerClaimExpectedPriorPhase: Sendable, Equatable, Hashable {
    case attemptTerminal(status: Int32)
}

struct ChatRunnerClaimRolloverExpectation: Sendable, Equatable, Hashable {
    let identity: ChatRunnerAttemptIdentity
    let phase: ChatRunnerClaimExpectedPriorPhase
}

/// Capability proving that a specific persisted runner attempt may be
/// reclaimed after cold start.
///
/// The authority discoverer must only issue this token after it has verified
/// formal terminal state plus runner/process death. The journal layer treats
/// the token as an opaque capability and still requires an exact
/// `(runID, attempt, instanceID, revision)` match before writing a cancelled
/// terminal event.
struct ChatRunnerReclaimToken: Sendable, Equatable, Hashable {
    let runID: String
    let attempt: UInt64?
    let instanceID: UUID
    let revision: UInt64
}

enum ChatRunnerTerminationRequestResult: Sendable, Equatable {
    case requested
    case blocked(reason: String)
    case formalTerminal(status: Int32)
    case reclaimed(ChatRunnerReclaimToken)
    case unknown(reason: String)
}

/// Cross-process authority result for cold-start runner reconciliation.
///
/// There are three effective per-run states:
/// - present in `activeRunIDs`: preserve as live;
/// - covered by an exact `reclaimTokens` capability: reclaim once;
/// - every other run, or a global `.unknown`: preserve fail-closed.
enum ChatRunnerAuthoritySnapshot: Sendable, Equatable {
    case authoritative(
        activeRunIDs: Set<String>,
        reclaimTokens: Set<ChatRunnerReclaimToken>
    )
    case unknown(reason: String)
}

protocol ChatRunnerAuthorityDiscovering: Sendable {
    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot
    func requestTermination(
        for identity: ChatRunnerAttemptIdentity
    ) -> ChatRunnerTerminationRequestResult
}

extension ChatRunnerAuthorityDiscovering {
    func requestTermination(
        for identity: ChatRunnerAttemptIdentity
    ) -> ChatRunnerTerminationRequestResult {
        _ = identity
        return .unknown(reason: "durable-runner-termination-unavailable")
    }
}

/// Test/fixture default. Production must explicitly inject one shared
/// `ChatRunnerAuthorityRecording` into both ChatPageModel and its runner.
struct ChatUnknownRunnerAuthorityDiscoverer: ChatRunnerAuthorityDiscovering {
    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        .unknown(reason: "durable-runner-authority-unavailable")
    }
}

struct ChatRunnerLaunchIdentity: Sendable, Equatable {
    let pid: pid_t
    let executablePath: String
    let argvDigest: String
    let launchShape: String
    let launchctlLabel: String?
    let uid: uid_t

    static func digest(
        executable: String,
        arguments: [String]
    ) -> String {
        let material = ([executable] + arguments)
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

protocol ChatRunnerAuthorityRecording: ChatRunnerAuthorityDiscovering {
    func claim(runID: String, attempt: UInt64) throws -> ChatRunnerAttemptIdentity
    func claim(
        runID: String,
        attempt: UInt64,
        expectedPrior: ChatRunnerClaimRolloverExpectation?
    ) throws -> ChatRunnerAttemptIdentity
    func attach(
        identity: ChatRunnerAttemptIdentity,
        launch: ChatRunnerLaunchIdentity
    ) throws
    func heartbeat(identity: ChatRunnerAttemptIdentity)
    func recordAttemptTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult
    func recordRunTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult
}

extension ChatRunnerAuthorityRecording {
    func claim(
        runID: String,
        attempt: UInt64,
        expectedPrior: ChatRunnerClaimRolloverExpectation?
    ) throws -> ChatRunnerAttemptIdentity {
        guard expectedPrior == nil else {
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-rollover-authority-unavailable")
        }
        return try claim(runID: runID, attempt: attempt)
    }
}

enum ChatRunnerTerminalPersistenceResult: Sendable, Equatable {
    case persisted
    case idempotent
    case blocked(reason: String)
}

enum ChatDurableRunnerAuthorityError: Error, Equatable {
    case invalidRunID
    case lockUnavailable
    case lockTimedOut(path: String, waited: TimeInterval)
    case identityMismatch
    case processIdentityUnavailable
    case claimBlocked(reason: String)
}

/// Durable, cross-process authority for the one physical Chat runner generation
/// currently owning a logical run.
///
/// The record contains only operational identity. Prompt/model output and raw
/// errors never enter this registry. Every read/write is protected by `flock`;
/// record replacement is atomic. Unknown process or launchctl topology is
/// preserved fail-closed.
final class ChatDurableRunnerAuthority:
    ChatRunnerAuthorityRecording,
    @unchecked Sendable
{
    private enum Phase: String, Codable {
        case claimed
        case attached
        case attemptTerminal
        case terminationRequested
        case formalTerminal
    }

    private struct Record: Codable, Equatable {
        var identity: ChatRunnerAttemptIdentity
        var phase: Phase
        var ownerPID: pid_t
        var runnerPID: pid_t?
        var runnerStartToken: String?
        var executablePath: String?
        var argvDigest: String?
        var launchShape: String?
        var launchctlLabel: String?
        var uid: uid_t
        var terminalStatus: Int32?
        var updatedAt: Date
    }

    private enum ProcessProbe {
        case alive
        case dead
        case unknown(String)
    }

    let rootURL: URL
    private let now: @Sendable () -> Date

    init(
        rootURL: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rootURL = rootURL
        self.now = now
    }

    static func production(stateRoot: URL) -> ChatDurableRunnerAuthority {
        ChatDurableRunnerAuthority(
            rootURL: stateRoot.appendingPathComponent(
                "chat-runner-authority-v1",
                isDirectory: true))
    }

    func claim(
        runID: String,
        attempt: UInt64
    ) throws -> ChatRunnerAttemptIdentity {
        try claim(
            runID: runID,
            attempt: attempt,
            expectedPrior: nil)
    }

    func claim(
        runID: String,
        attempt: UInt64,
        expectedPrior: ChatRunnerClaimRolloverExpectation?
    ) throws -> ChatRunnerAttemptIdentity {
        guard !runID.isEmpty, attempt > 0 else {
            throw ChatDurableRunnerAuthorityError.invalidRunID
        }
        return try withRegistryLock {
            let previous = try loadRecordIfPresent(runID: runID)
            if let previous {
                try validateRolloverClaim(
                    runID: runID,
                    attempt: attempt,
                    previous: previous,
                    expectedPrior: expectedPrior)
            } else if expectedPrior != nil {
                throw ChatDurableRunnerAuthorityError.claimBlocked(
                    reason: "runner-expected-prior-missing")
            }
            let identity = ChatRunnerAttemptIdentity(
                runID: runID,
                attempt: attempt,
                instanceID: UUID(),
                revision: (previous?.identity.revision ?? 0) &+ 1)
            try save(Record(
                identity: identity,
                phase: .claimed,
                ownerPID: getpid(),
                runnerPID: nil,
                runnerStartToken: nil,
                executablePath: nil,
                argvDigest: nil,
                launchShape: nil,
                launchctlLabel: nil,
                uid: getuid(),
                terminalStatus: nil,
                updatedAt: now()))
            return identity
        }
    }

    private func validateRolloverClaim(
        runID: String,
        attempt: UInt64,
        previous: Record,
        expectedPrior: ChatRunnerClaimRolloverExpectation?
    ) throws {
        guard let expectedPrior else {
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-existing-generation-requires-expected-prior")
        }
        guard expectedPrior.identity.runID == runID,
              expectedPrior.identity == previous.identity
        else {
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-stale-expected-prior-identity")
        }
        guard attempt == previous.identity.attempt &+ 1 else {
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-attempt-rollover-not-next")
        }
        let expectedTerminalStatus: Int32
        switch expectedPrior.phase {
        case .attemptTerminal(let status):
            expectedTerminalStatus = status
        }
        guard previous.phase == .attemptTerminal,
              previous.terminalStatus == expectedTerminalStatus else {
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-expected-prior-phase-mismatch")
        }

        switch processProbe(previous) {
        case .dead:
            break
        case .alive:
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-prior-process-still-active")
        case .unknown(let reason):
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-prior-process-unknown:\(reason)")
        }

        switch launchctlProbe(previous) {
        case .absent:
            break
        case .present:
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-prior-launchctl-still-active")
        case .unknown(let reason):
            throw ChatDurableRunnerAuthorityError.claimBlocked(
                reason: "runner-prior-launchctl-unknown:\(reason)")
        }
    }

    func attach(
        identity: ChatRunnerAttemptIdentity,
        launch: ChatRunnerLaunchIdentity
    ) throws {
        guard let startToken = Self.processStartToken(pid: launch.pid) else {
            throw ChatDurableRunnerAuthorityError.processIdentityUnavailable
        }
        try mutateExact(identity) { record in
            record.phase = .attached
            record.runnerPID = launch.pid
            record.runnerStartToken = startToken
            record.executablePath = Self.canonicalPath(launch.executablePath)
            record.argvDigest = launch.argvDigest
            record.launchShape = launch.launchShape
            record.launchctlLabel = launch.launchctlLabel
            record.uid = launch.uid
            record.updatedAt = now()
        }
    }

    func heartbeat(identity: ChatRunnerAttemptIdentity) {
        try? mutateExact(identity) { record in
            guard record.phase == .attached else { return }
            record.updatedAt = now()
        }
    }

    func recordAttemptTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        persistTerminal(
            identity: identity,
            status: status,
            phase: .attemptTerminal)
    }

    func recordRunTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        persistTerminal(
            identity: identity,
            status: status,
            phase: .formalTerminal)
    }

    private func persistTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32,
        phase requestedPhase: Phase
    ) -> ChatRunnerTerminalPersistenceResult {
        do {
            return try withRegistryLock {
                guard var record = try loadRecordIfPresent(
                    runID: identity.runID),
                      record.identity == identity
                else {
                    return .blocked(reason: "runner-generation-mismatch")
                }

                if record.phase == requestedPhase {
                    return record.terminalStatus == status
                        ? .idempotent
                        : .blocked(reason: "runner-terminal-conflict")
                }
                if record.phase == .formalTerminal {
                    return record.terminalStatus == status
                        ? .idempotent
                        : .blocked(reason: "runner-terminal-conflict")
                }

                record.phase = requestedPhase
                record.terminalStatus = status
                record.updatedAt = now()
                try save(record)
                return .persisted
            }
        } catch {
            return .blocked(reason: "runner-terminal-persistence-failed")
        }
    }

    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        do {
            return try withRegistryLock {
                let records = try loadAllRecords()
                var active = Set<String>()
                var reclaim = Set<ChatRunnerReclaimToken>()
                for var record in records {
                    switch classify(record) {
                    case .active:
                        active.insert(record.identity.runID)
                    case .reclaimable(let status):
                        if record.phase != .formalTerminal {
                            record.phase = .formalTerminal
                            record.terminalStatus = status
                            record.updatedAt = now()
                            try save(record)
                        }
                        reclaim.insert(Self.reclaimToken(record.identity))
                    case .unknown(let reason):
                        return .unknown(
                            reason: "\(reason):\(record.identity.runID)")
                    }
                }
                return .authoritative(
                    activeRunIDs: active,
                    reclaimTokens: reclaim)
            }
        } catch {
            return .unknown(reason: "runner-registry-unreadable")
        }
    }

    func requestTermination(
        for identity: ChatRunnerAttemptIdentity
    ) -> ChatRunnerTerminationRequestResult {
        do {
            return try withRegistryLock {
                guard var record = try loadRecordIfPresent(runID: identity.runID),
                      record.identity == identity
                else {
                    return .unknown(reason: "runner-generation-mismatch")
                }

                switch classify(record) {
                case .reclaimable(let status):
                    if record.phase != .formalTerminal {
                        record.phase = .formalTerminal
                        record.terminalStatus = status
                        record.updatedAt = now()
                        try save(record)
                    }
                    return .reclaimed(Self.reclaimToken(identity))
                case .unknown(let reason):
                    return .blocked(reason: reason)
                case .active:
                    break
                }

                guard let runnerPID = record.runnerPID,
                      ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(
                        runnerPID)
                else {
                    return .blocked(reason: "runner-pid-unknown")
                }
                if let label = record.launchctlLabel, !label.isEmpty {
                    switch ChatCLIProcessRunner.probeLaunchctlLabel(
                        label: label,
                        uid: record.uid)
                    {
                    case .present:
                        guard Self.signalLaunchctl(
                            label: label,
                            uid: record.uid,
                            signal: "SIGTERM")
                        else {
                            return .blocked(
                                reason: "launchctl-termination-request-failed")
                        }
                    case .absent:
                        break
                    case .unknown(let reason):
                        return .blocked(
                            reason: "launchctl-topology-unknown:\(reason)")
                    }
                }
                guard Darwin.kill(runnerPID, SIGTERM) == 0 || errno == ESRCH else {
                    return .blocked(reason: "runner-termination-request-failed")
                }
                record.phase = .terminationRequested
                record.updatedAt = now()
                try save(record)
                return .requested
            }
        } catch {
            return .unknown(reason: "runner-registry-unreadable")
        }
    }

    private enum Classification {
        case active
        case reclaimable(status: Int32)
        case unknown(String)
    }

    private func classify(_ record: Record) -> Classification {
        switch processProbe(record) {
        case .unknown(let reason):
            return .unknown(reason)
        case .alive:
            if record.phase == .formalTerminal {
                return .unknown("formal-terminal-process-still-alive")
            }
            return .active
        case .dead:
            break
        }

        switch launchctlProbe(record) {
        case .unknown(let reason):
            return .unknown(reason)
        case .present:
            return record.phase == .formalTerminal
                ? .unknown("formal-terminal-launchctl-still-present")
                : .active
        case .absent:
            break
        }

        switch record.phase {
        case .formalTerminal:
            return .reclaimable(status: record.terminalStatus ?? 143)
        case .attemptTerminal:
            // A bridge attempt ending is not the logical run ending. During
            // the small handoff window before attempt 2 is claimed, preserve
            // the run fail-closed rather than minting a reclaim capability.
            return .unknown("bridge-attempt-terminal-without-run-terminal")
        case .terminationRequested:
            // The exact generation received TERM and both its PID identity and
            // launchctl boundary are now absent. Persist a formal cancellation
            // terminal before issuing the one-time exact reclaim capability.
            return .reclaimable(status: 143)
        case .claimed, .attached:
            return .unknown("runner-ended-without-formal-terminal")
        }
    }

    private func processProbe(_ record: Record) -> ProcessProbe {
        guard let pid = record.runnerPID else {
            // A claimed generation may fail closed before spawn/attach. Once
            // that exact generation has a formal terminal record, there is no
            // physical PID that could still be alive.
            return record.phase == .formalTerminal
                ? .dead
                : .unknown("runner-attach-incomplete")
        }
        guard
              let expectedStart = record.runnerStartToken,
              let expectedExecutable = record.executablePath
        else {
            return .unknown("runner-process-identity-missing")
        }
        errno = 0
        guard Darwin.kill(pid, 0) == 0 else {
            if errno == ESRCH { return .dead }
            if errno == EPERM {
                return .unknown("runner-probe-permission-denied")
            }
            return .unknown("runner-probe-errno-\(errno)")
        }
        guard let actualStart = Self.processStartToken(pid: pid),
              let actualExecutable = Self.processExecutablePath(pid: pid)
        else {
            return .unknown("runner-process-identity-unreadable")
        }
        guard actualStart == expectedStart,
              Self.canonicalPath(actualExecutable) == expectedExecutable
        else {
            // PID reuse proves this generation is no longer alive.
            return .dead
        }
        return .alive
    }

    private func launchctlProbe(
        _ record: Record
    ) -> ChatCLILaunchctlLabelProbeResult {
        guard let label = record.launchctlLabel, !label.isEmpty else {
            return .absent
        }
        return ChatCLIProcessRunner.probeLaunchctlLabel(
            label: label,
            uid: record.uid)
    }

    private func mutateExact(
        _ identity: ChatRunnerAttemptIdentity,
        mutation: (inout Record) throws -> Void
    ) throws {
        try withRegistryLock {
            guard var record = try loadRecordIfPresent(runID: identity.runID),
                  record.identity == identity
            else {
                throw ChatDurableRunnerAuthorityError.identityMismatch
            }
            try mutation(&record)
            try save(record)
        }
    }

    private func withRegistryLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true)
        let descriptor = Darwin.open(
            rootURL.appendingPathComponent(".lock").path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ChatDurableRunnerAuthorityError.lockUnavailable
        }
        defer { Darwin.close(descriptor) }
        let lockPath = rootURL.appendingPathComponent(".lock").path
        let startedAt = ProcessInfo.processInfo.systemUptime
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw ChatDurableRunnerAuthorityError.lockUnavailable
            }
            let waited = ProcessInfo.processInfo.systemUptime - startedAt
            guard waited < 8 else {
                throw ChatDurableRunnerAuthorityError.lockTimedOut(
                    path: lockPath,
                    waited: waited)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func loadAllRecords() throws -> [Record] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map {
            try Self.decoder.decode(Record.self, from: Data(contentsOf: $0))
        }
    }

    private func loadRecordIfPresent(runID: String) throws -> Record? {
        let url = recordURL(runID: runID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Self.decoder.decode(
            Record.self,
            from: Data(contentsOf: url))
    }

    private func save(_ record: Record) throws {
        try Self.encoder.encode(record).write(
            to: recordURL(runID: record.identity.runID),
            options: .atomic)
    }

    private func recordURL(runID: String) -> URL {
        let digest = SHA256.hash(data: Data(runID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootURL.appendingPathComponent("\(digest).json")
    }

    private static func reclaimToken(
        _ identity: ChatRunnerAttemptIdentity
    ) -> ChatRunnerReclaimToken {
        ChatRunnerReclaimToken(
            runID: identity.runID,
            attempt: identity.attempt,
            instanceID: identity.instanceID,
            revision: identity.revision)
    }

    private static func processStartToken(pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let received = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expected)
        guard received == expected else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    private static func processExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN))
        let length = proc_pidpath(
            pid,
            &buffer,
            UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func signalLaunchctl(
        label: String,
        uid: uid_t,
        signal: String
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "kill",
            signal,
            "gui/\(uid)/\(label)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum ChatDurableCancellationPhase: String, Codable, Sendable, Equatable {
    case cancellationRequested
    case blocked
    case retrying
}

struct ChatDurableCancellationRecord: Codable, Sendable, Equatable {
    let identity: ChatRunnerAttemptIdentity
    let assistantID: String
    let threadID: String?
    var phase: ChatDurableCancellationPhase
    var reason: String?
    var updatedAt: Date
}

protocol ChatCancellationStateStoring: Sendable {
    func loadOutstanding() throws -> [ChatDurableCancellationRecord]
    func upsert(_ record: ChatDurableCancellationRecord) throws
    func remove(identity: ChatRunnerAttemptIdentity) throws
}

/// Small operational-only journal for unresolved cancellation locks.
///
/// It never stores prompts, model output, raw errors, auth, or tool payloads.
/// Atomic replacement prevents a torn write from silently unlocking Chat.
final class ChatCancellationStateDiskStore:
    ChatCancellationStateStoring,
    @unchecked Sendable
{
    private struct Document: Codable {
        var records: [ChatDurableCancellationRecord]
    }

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadOutstanding() throws -> [ChatDurableCancellationRecord] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return []
            }
            let data = try Data(contentsOf: fileURL)
            return try Self.makeDecoder().decode(Document.self, from: data).records
        }
    }

    func upsert(_ record: ChatDurableCancellationRecord) throws {
        try lock.withLock {
            var records = try loadUnlocked()
            if let index = records.firstIndex(where: {
                $0.identity == record.identity
            }) {
                records[index] = record
            } else {
                records.append(record)
            }
            try saveUnlocked(records)
        }
    }

    func remove(identity: ChatRunnerAttemptIdentity) throws {
        try lock.withLock {
            var records = try loadUnlocked()
            records.removeAll { $0.identity == identity }
            try saveUnlocked(records)
        }
    }

    private func loadUnlocked() throws -> [ChatDurableCancellationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try Self.makeDecoder().decode(Document.self, from: data).records
    }

    private func saveUnlocked(_ records: [ChatDurableCancellationRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(Document(records: records))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Testable state machine used by ChatPageModel to keep cancellation locked
/// across process death and App relaunch.
final class ChatCancellationDurabilityCoordinator: @unchecked Sendable {
    private let store: any ChatCancellationStateStoring
    private let now: @Sendable () -> Date

    init(
        store: any ChatCancellationStateStoring,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    func latestOutstanding() throws -> ChatDurableCancellationRecord? {
        try allOutstanding().max {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.identity.runID < $1.identity.runID
        }
    }

    func allOutstanding() throws -> [ChatDurableCancellationRecord] {
        try store.loadOutstanding()
    }

    @discardableResult
    func requestCancellation(
        identity: ChatRunnerAttemptIdentity,
        assistantID: String,
        threadID: String?
    ) throws -> ChatDurableCancellationRecord {
        let record = ChatDurableCancellationRecord(
            identity: identity,
            assistantID: assistantID,
            threadID: threadID,
            phase: .cancellationRequested,
            reason: nil,
            updatedAt: now())
        try store.upsert(record)
        return record
    }

    @discardableResult
    func markBlocked(
        identity: ChatRunnerAttemptIdentity,
        assistantID: String,
        threadID: String?,
        reason: String
    ) throws -> ChatDurableCancellationRecord {
        let record = ChatDurableCancellationRecord(
            identity: identity,
            assistantID: assistantID,
            threadID: threadID,
            phase: .blocked,
            reason: reason,
            updatedAt: now())
        try store.upsert(record)
        return record
    }

    @discardableResult
    func markRetrying(
        _ record: ChatDurableCancellationRecord
    ) throws -> ChatDurableCancellationRecord {
        var updated = record
        updated.phase = .retrying
        updated.updatedAt = now()
        try store.upsert(updated)
        return updated
    }

    func resolve(identity: ChatRunnerAttemptIdentity) throws {
        try store.remove(identity: identity)
    }
}
