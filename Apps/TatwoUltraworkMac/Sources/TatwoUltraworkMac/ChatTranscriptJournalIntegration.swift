import AppKit
import CryptoKit
import Foundation
import TatwoUltraworkCore

enum ChatPendingRemoteTargetStateV1: String, Codable, Sendable, Equatable {
    case armed
    case claiming
    case inflight
    case accepted
    case consumed
}

struct ChatPendingRemoteTargetV1: Codable, Sendable, Equatable {
    static let schemaName = "ChatPendingRemoteTargetV1"

    let schema: String
    let sessionID: String
    let contractID: String
    let goalID: String
    let targetDeviceID: String
    let targetDisplayName: String
    let grantID: String
    let issuedAt: Date
    let persistedAt: Date
    let operationID: String
    let state: ChatPendingRemoteTargetStateV1
    let claimID: String
    let logicalJobID: String
    let claimedAt: Date?
    let remoteJobID: String?
    let acceptedAt: Date?

    init(
        schema: String = Self.schemaName,
        sessionID: String,
        contractID: String,
        goalID: String,
        targetDeviceID: String,
        targetDisplayName: String,
        grantID: String,
        issuedAt: Date,
        persistedAt: Date = Date(),
        operationID: String,
        state: ChatPendingRemoteTargetStateV1 = .armed,
        claimID: String,
        logicalJobID: String,
        claimedAt: Date? = nil,
        remoteJobID: String? = nil,
        acceptedAt: Date? = nil
    ) {
        self.schema = schema
        self.sessionID = sessionID
        self.contractID = contractID
        self.goalID = goalID
        self.targetDeviceID = targetDeviceID
        self.targetDisplayName = targetDisplayName
        self.grantID = grantID
        self.issuedAt = issuedAt
        self.persistedAt = persistedAt
        self.operationID = operationID
        self.state = state
        self.claimID = claimID
        self.logicalJobID = logicalJobID
        self.claimedAt = claimedAt
        self.remoteJobID = remoteJobID
        self.acceptedAt = acceptedAt
    }

    var logicalKey: String {
        ["borrow", sessionID, contractID, targetDeviceID, operationID]
            .joined(separator: ":")
    }

    func transitioning(
        to state: ChatPendingRemoteTargetStateV1,
        claimedAt: Date? = nil,
        remoteJobID: String? = nil,
        acceptedAt: Date? = nil
    ) -> Self {
        Self(
            schema: schema,
            sessionID: sessionID,
            contractID: contractID,
            goalID: goalID,
            targetDeviceID: targetDeviceID,
            targetDisplayName: targetDisplayName,
            grantID: grantID,
            issuedAt: issuedAt,
            persistedAt: persistedAt,
            operationID: operationID,
            state: state,
            claimID: claimID,
            logicalJobID: logicalJobID,
            claimedAt: claimedAt ?? self.claimedAt,
            remoteJobID: remoteJobID ?? self.remoteJobID,
            acceptedAt: acceptedAt ?? self.acceptedAt)
    }
}

enum ChatPendingRemoteTargetStoreError: Error, LocalizedError, Equatable {
    case invalidBinding(String)
    case ambiguousTargets([ChatPendingRemoteTargetV1])
    case unreadableState

    var errorDescription: String? {
        switch self {
        case .invalidBinding(let field):
            "遠端借用待命目標缺少有效的 \(field)，已停止操作。"
        case .ambiguousTargets(let targets):
            "這個 Chat Session 同時有 \(targets.count) 個待命遠端目標，"
                + "未明確指定設備時不會派工。"
        case .unreadableState:
            "遠端借用待命狀態無法安全讀取，已停止操作。"
        }
    }
}

final class ChatPendingRemoteTargetDiskStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        var schema = "ChatPendingRemoteTargetSnapshotV1"
        var targets: [ChatPendingRemoteTargetV1] = []
    }

    let fileURL: URL
    private static let processLock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    @discardableResult
    func arm(
        grant: TatwoRemoteSessionGrantV1,
        goalID: String,
        targetDisplayName: String,
        now: Date = Date()
    ) throws -> ChatPendingRemoteTargetV1 {
        guard grant.schema == "TatwoRemoteSessionGrantV1",
              grant.risk == .lowRisk,
              grant.isActive(at: now)
        else {
            throw ChatPendingRemoteTargetStoreError.invalidBinding("grant")
        }
        let operationID = UUID().uuidString.lowercased()
        let target = ChatPendingRemoteTargetV1(
            sessionID: try Self.requireIdentifier(grant.sessionID, field: "sessionID"),
            contractID: try Self.requireIdentifier(grant.contractID, field: "contractID"),
            goalID: try Self.requireIdentifier(goalID, field: "goalID"),
            targetDeviceID: try Self.requireIdentifier(
                grant.targetDeviceID,
                field: "targetDeviceID"),
            targetDisplayName: Self.publicDisplayName(targetDisplayName),
            grantID: try Self.requireIdentifier(grant.id, field: "grantID"),
            issuedAt: grant.issuedAt,
            persistedAt: now,
            operationID: operationID,
            claimID: Self.stableID(
                prefix: "remote-claim",
                parts: [
                    operationID,
                ]),
            logicalJobID: Self.stableID(
                prefix: "remote-logical",
                parts: [
                    operationID,
                    grant.sessionID,
                    grant.contractID,
                    goalID,
                    grant.targetDeviceID,
                    grant.id,
                ]))
        return try Self.processLock.withLock {
            var snapshot = try loadUnlocked()
            if let existing = snapshot.targets.first(where: {
                $0.sessionID == target.sessionID
                    && $0.contractID == target.contractID
                    && $0.goalID == target.goalID
                    && $0.targetDeviceID == target.targetDeviceID
                    && $0.grantID == target.grantID
                    && $0.state != .consumed
            }) {
                return existing
            }
            if snapshot.targets.contains(where: {
                $0.sessionID == target.sessionID
                    && $0.targetDeviceID == target.targetDeviceID
                    && $0.state != .consumed
            }) {
                throw ChatPendingRemoteTargetStoreError.invalidBinding(
                    "session.target.bindingConflict")
            }
            snapshot.targets.append(target)
            try saveUnlocked(snapshot)
            return target
        }
    }

    /// Atomically claims one session/target's durable operation without deleting it.
    /// A session-only claim is valid only when exactly one non-consumed target
    /// remains. Multiple targets require an explicit target binding and fail closed
    /// instead of inheriting append order. Relaunch/retry returns the same claim and
    /// logical job identities.
    func claim(
        sessionID: String,
        targetDeviceID: String? = nil,
        now: Date = Date()
    ) throws -> ChatPendingRemoteTargetV1? {
        let normalizedSessionID = try Self.requireIdentifier(
            sessionID,
            field: "sessionID")
        let normalizedTargetID = try targetDeviceID.map {
            try Self.requireIdentifier($0, field: "targetDeviceID")
        }
        return try Self.processLock.withLock {
            var snapshot = try loadUnlocked()
            let matchingIndices = snapshot.targets.indices.filter {
                snapshot.targets[$0].sessionID == normalizedSessionID
                    && (normalizedTargetID == nil
                        || snapshot.targets[$0].targetDeviceID == normalizedTargetID)
                    && snapshot.targets[$0].state != .consumed
            }
            guard !matchingIndices.isEmpty else {
                return nil
            }
            if normalizedTargetID == nil, matchingIndices.count > 1 {
                throw ChatPendingRemoteTargetStoreError.ambiguousTargets(
                    matchingIndices.map { snapshot.targets[$0] })
            }
            let index = matchingIndices[0]
            let current = snapshot.targets[index]
            switch current.state {
            case .armed:
                let claimed = current.transitioning(to: .claiming, claimedAt: now)
                snapshot.targets[index] = claimed
                try saveUnlocked(snapshot)
                return claimed
            case .claiming, .inflight, .accepted:
                return current
            case .consumed:
                return nil
            }
        }
    }

    func pending(
        sessionID: String,
        targetDeviceID: String? = nil
    ) throws -> ChatPendingRemoteTargetV1? {
        let normalizedSessionID = try Self.requireIdentifier(
            sessionID,
            field: "sessionID")
        let normalizedTargetID = try targetDeviceID.map {
            try Self.requireIdentifier($0, field: "targetDeviceID")
        }
        return try Self.processLock.withLock {
            try loadUnlocked().targets.first {
                $0.sessionID == normalizedSessionID
                    && (normalizedTargetID == nil
                        || $0.targetDeviceID == normalizedTargetID)
                    && $0.state != .consumed
            }
        }
    }

    func pendingTargets(sessionID: String) throws -> [ChatPendingRemoteTargetV1] {
        let normalizedSessionID = try Self.requireIdentifier(
            sessionID,
            field: "sessionID")
        return try Self.processLock.withLock {
            try loadUnlocked().targets.filter {
                $0.sessionID == normalizedSessionID && $0.state != .consumed
            }
        }
    }

    func markInflight(claimID: String) throws -> ChatPendingRemoteTargetV1 {
        try transition(claimID: claimID) { current in
            guard current.state == .claiming || current.state == .inflight else {
                throw ChatPendingRemoteTargetStoreError.invalidBinding("claim.state")
            }
            return current.transitioning(to: .inflight)
        }
    }

    func releaseForRetry(claimID: String) throws -> ChatPendingRemoteTargetV1 {
        try transition(claimID: claimID) { current in
            guard current.state == .claiming || current.state == .inflight else {
                throw ChatPendingRemoteTargetStoreError.invalidBinding("claim.state")
            }
            return current.transitioning(to: .armed)
        }
    }

    func markAccepted(
        claimID: String,
        remoteJobID: String,
        acceptedAt: Date
    ) throws -> ChatPendingRemoteTargetV1 {
        let normalizedJobID = try Self.requireIdentifier(remoteJobID, field: "remoteJobID")
        return try transition(claimID: claimID) { current in
            guard current.state == .inflight || current.state == .accepted else {
                throw ChatPendingRemoteTargetStoreError.invalidBinding("claim.state")
            }
            if current.state == .accepted {
                guard current.remoteJobID == normalizedJobID else {
                    throw ChatPendingRemoteTargetStoreError.invalidBinding(
                        "accepted.remoteJobID")
                }
                return current
            }
            return current.transitioning(
                to: .accepted,
                remoteJobID: normalizedJobID,
                acceptedAt: acceptedAt)
        }
    }

    func consumeAccepted(claimID: String) throws {
        _ = try transition(claimID: claimID) { current in
            guard current.state == .accepted || current.state == .consumed else {
                throw ChatPendingRemoteTargetStoreError.invalidBinding("claim.state")
            }
            return current.transitioning(to: .consumed)
        }
    }

    @discardableResult
    func invalidate(
        sessionID: String,
        targetDeviceID: String? = nil
    ) throws -> Bool {
        let normalizedSessionID = try Self.requireIdentifier(
            sessionID,
            field: "sessionID")
        let normalizedTargetID = try targetDeviceID.map {
            try Self.requireIdentifier($0, field: "targetDeviceID")
        }
        return try Self.processLock.withLock {
            var snapshot = try loadUnlocked()
            var didChange = false
            for index in snapshot.targets.indices where
                snapshot.targets[index].sessionID == normalizedSessionID
                    && (normalizedTargetID == nil
                        || snapshot.targets[index].targetDeviceID == normalizedTargetID)
                    && snapshot.targets[index].state != .consumed
            {
                snapshot.targets[index] = snapshot.targets[index].transitioning(
                    to: .consumed)
                didChange = true
            }
            guard didChange else { return false }
            try saveUnlocked(snapshot)
            return true
        }
    }

    private func transition(
        claimID: String,
        update: (ChatPendingRemoteTargetV1) throws -> ChatPendingRemoteTargetV1
    ) throws -> ChatPendingRemoteTargetV1 {
        let normalizedClaimID = try Self.requireIdentifier(claimID, field: "claimID")
        return try Self.processLock.withLock {
            var snapshot = try loadUnlocked()
            guard let index = snapshot.targets.firstIndex(where: {
                $0.claimID == normalizedClaimID
            }) else {
                throw ChatPendingRemoteTargetStoreError.invalidBinding("claimID")
            }
            let updated = try update(snapshot.targets[index])
            snapshot.targets[index] = updated
            try saveUnlocked(snapshot)
            return updated
        }
    }

    private func loadUnlocked() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.schema == "ChatPendingRemoteTargetSnapshotV1",
                  snapshot.targets.allSatisfy({
                      $0.schema == ChatPendingRemoteTargetV1.schemaName
                  })
            else {
                throw ChatPendingRemoteTargetStoreError.unreadableState
            }
            return snapshot
        } catch let error as ChatPendingRemoteTargetStoreError {
            throw error
        } catch {
            throw ChatPendingRemoteTargetStoreError.unreadableState
        }
    }

    private func saveUnlocked(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
    }

    private static func requireIdentifier(
        _ value: String,
        field: String
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.value != 47
                      && $0.value != 92
              })
        else {
            throw ChatPendingRemoteTargetStoreError.invalidBinding(field)
        }
        return trimmed
    }

    private static func publicDisplayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "遠端設備" : trimmed).prefix(80))
    }

    private static func stableID(prefix: String, parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

struct ChatRemoteTurnDispatchRequest: Sendable, Equatable {
    let visibleTurn: String
    let invocation: TatwoRemoteBorrowInvocationV1
    let claimID: String
    let logicalJobID: String
    /// Exact Work OS mode read from the canonical GoalRun record immediately
    /// before dispatch. The production material provider re-reads and matches it.
    let contractMode: WorkModeID
    let agent: TatwoRemoteAgentKindV1
    let exactModelRouteID: String
    /// Unique for this physical dispatch attempt. It is bound into the signed
    /// job readiness requirement and is never reused as a process-global nonce.
    let readinessChallengeNonce: String
    /// Optional preloaded artifact/binding. Production still reloads canonical
    /// inbox truth and requires exact equality; tests may leave these nil.
    let targetReadinessManifest: TatwoRemoteDispatchReadinessManifestV1?
    let readinessBinding: TatwoRemoteDispatchReadinessBindingV1?
}

struct ChatRemoteTurnDispatchAcceptance: Sendable, Equatable {
    let logicalJobID: String
    let remoteJobID: String
    let acceptedAt: Date

    var hasValidJobIdentity: Bool {
        [logicalJobID, remoteJobID].allSatisfy {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && trimmed.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        }
    }
}

enum ChatRemoteTurnDispatchBlocker: String, Sendable, Equatable {
    case adapterUnavailable =
        "遠端派工缺少 target-signed readiness 與目標 workspace binding；production runner 尚未可安全呼叫"
    case readinessManifestMissing = "目標設備 readiness manifest 尚未送達 sealed channel"
    case readinessManifestStale = "目標設備 readiness manifest 已過期"
    case readinessManifestMismatch = "目標設備 readiness manifest 與 agent、route 或 workspace binding 不符"
    case contractModeMismatch = "Work OS mode 與 canonical GoalRun 不符"
    case originLeaseLost = "本機已不是有效的 origin authority"
    case targetTrustLost = "目標設備信任已失效"
    case targetLeaseLost = "目標設備租約已失效"
    case dispatchRejected = "遠端派工遭拒"
}

enum ChatRemoteTurnDispatchOutcome: Sendable, Equatable {
    case accepted(ChatRemoteTurnDispatchAcceptance)
    case blocked(ChatRemoteTurnDispatchBlocker)
}

enum ChatPendingRemoteClaimResult: Sendable, Equatable {
    case claimed(ChatPendingRemoteTargetV1?)
    case ambiguousTargets([ChatPendingRemoteTargetV1])
    case unreadable
}

enum ChatPendingRemoteDispatchResult: Sendable, Equatable {
    case accepted(ChatPendingRemoteTargetV1, ChatRemoteTurnDispatchAcceptance)
    case retryable(ChatPendingRemoteTargetV1, String)
    case invalidated(ChatPendingRemoteTargetV1, String)
    case storageBlocked(ChatPendingRemoteTargetV1, String)
}

final class ChatRemoteTurnCancellationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var dispatchBegan = false

    /// Returns whether synchronous dispatch had already crossed its irreversible
    /// boundary. Callers must not release an inflight claim in that case because
    /// the remote side may already have accepted it.
    @discardableResult
    func cancel() -> Bool {
        lock.withLock {
            cancelled = true
            return dispatchBegan
        }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Atomically closes the Stop-vs-dispatch race. Once this returns true, the
    /// dispatcher result must be durably reconciled even if UI publication is
    /// later suppressed by the model generation fence.
    func tryBeginDispatch() -> Bool {
        lock.withLock {
            guard !cancelled, !dispatchBegan else { return false }
            dispatchBegan = true
            return true
        }
    }
}

protocol ChatRemoteTurnDispatching: Sendable {
    func dispatch(_ request: ChatRemoteTurnDispatchRequest) -> ChatRemoteTurnDispatchOutcome
}

struct ChatUnavailableRemoteTurnDispatcher: ChatRemoteTurnDispatching {
    func dispatch(
        _ request: ChatRemoteTurnDispatchRequest
    ) -> ChatRemoteTurnDispatchOutcome {
        .blocked(.adapterUnavailable)
    }
}

struct ChatTranscriptJournalContext: Sendable, Equatable {
    let threadID: String
    let turnID: String
    let runID: String
    let source: ChatTranscriptSourceMetadataV1
}

struct ChatTranscriptLegacyMigrationResult: Equatable {
    let outcomes: [ChatTranscriptAppendOutcomeV1]
    let rejectedMessageIDs: [String]

    var appendedCount: Int {
        outcomes.filter(\.wasAppended).count
    }

    var isComplete: Bool {
        rejectedMessageIDs.isEmpty
    }
}

enum ChatRemoteJobPublicState: String, Codable, CaseIterable, Sendable, Equatable {
    case delivered = "已送達"
    case started = "已啟動"
    case running = "執行中"
    case completed = "已完成"
    case verified = "已驗收"

    var rank: Int {
        switch self {
        case .delivered: 1
        case .started: 2
        case .running: 3
        case .completed: 4
        case .verified: 5
        }
    }
}

enum ChatRemoteJobTerminalOutcome: String, Codable, Sendable, Equatable {
    case failed = "失敗"
    case cancelled = "已取消"

    var rank: Int { 6 }

    var lifecyclePhase: ChatTranscriptLifecyclePhaseV1 {
        switch self {
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    var defaultBlocker: String {
        switch self {
        case .failed: "遠端工作失敗"
        case .cancelled: "遠端工作已取消"
        }
    }
}

enum ChatRemoteJobRuntimeTruth: String, Codable, Sendable, Equatable {
    /// This process observed a fresh acceptance/registry projection. It may
    /// animate while the remote lifecycle remains non-terminal.
    case observedThisProcess = "observed-this-process"
    /// A persisted non-terminal row survived relaunch, but this process has no
    /// target-side liveness authority. Preserve it without claiming activity.
    case unknownAfterRelaunch = "unknown-after-relaunch"
    /// A terminal receipt/state is latched and outranks runtime liveness.
    case terminalReceipt = "terminal-receipt"
    /// No target-side execution has been authoritatively observed yet.
    case waitingForAuthority = "waiting-for-authority"
}

enum ChatRemoteJobProjectionIdentity: Sendable, Equatable {
    /// Dispatch acceptance is a durable receipt keyed by logical + physical job
    /// identity. Replayed acceptedAt timestamps must not invent another event.
    case acceptedDispatch(remoteJobID: String)
    /// Registry/waiting projections are semantic observations. Heartbeat-only
    /// timestamp refreshes are not user-facing state transitions and must not
    /// grow the durable journal.
    case observation
}

struct ChatRemoteJobProjection: Sendable, Equatable {
    let logicalKey: String
    let attempt: UInt64
    let publicState: ChatRemoteJobPublicState?
    let terminalOutcome: ChatRemoteJobTerminalOutcome?
    let runtimeTruth: ChatRemoteJobRuntimeTruth
    let publicNarrative: String
    let blocker: String?
    let toolDetails: [String: String]
    let occurredAt: Date
    let identity: ChatRemoteJobProjectionIdentity
    let isHidden: Bool
}

enum ChatRemoteJobReducer {
    static func project(_ records: [TatwoDispatchRecord]) -> [ChatRemoteJobProjection] {
        Dictionary(grouping: records.filter(isRemoteRecord), by: canonicalKey)
            .map { key, groupedRecords in
                projection(logicalKey: key, records: groupedRecords)
            }
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt < $1.occurredAt
                }
                return $0.logicalKey < $1.logicalKey
            }
    }

    static func waitingForTargetBinding(
        logicalKey: String,
        targetDisplayName: String,
        targetDeviceID: String,
        contractID: String,
        goalID: String,
        blocker: String,
        occurredAt: Date
    ) -> ChatRemoteJobProjection {
        let safeTarget = publicTargetName(targetDisplayName)
        let safeBlocker = publicBlocker(blocker)
        let lifecycle =
            "借用原因：本機工作需要遠端算力"
            + " → 目標：\(safeTarget)"
            + " → 傳送：\(safeBlocker)"
            + " → 排隊/執行：尚未開始"
            + " → 回傳：等待"
            + " → 本機驗證：等待"
            + " → 完成：等待"
        return ChatRemoteJobProjection(
            logicalKey: logicalKey,
            attempt: 1,
            publicState: nil,
            terminalOutcome: nil,
            runtimeTruth: .waitingForAuthority,
            publicNarrative: publicStatus(
                publicState: nil,
                terminalOutcome: nil,
                blocker: safeBlocker),
            blocker: safeBlocker,
            toolDetails: [
                "attempts": "1",
                "contractID": safeDetail(contractID),
                "goalID": safeDetail(goalID),
                "lifecycle": safeDetail(lifecycle),
                "targetDeviceID": safeDetail(targetDeviceID),
            ],
            occurredAt: occurredAt,
            identity: .observation,
            isHidden: false)
    }

    static func supersededWaitingForTargetBinding(
        logicalKey: String,
        occurredAt: Date
    ) -> ChatRemoteJobProjection {
        ChatRemoteJobProjection(
            logicalKey: logicalKey,
            attempt: 1,
            publicState: nil,
            terminalOutcome: .cancelled,
            runtimeTruth: .terminalReceipt,
            publicNarrative: "先前的待命提示已由正式遠端工作承接",
            blocker: nil,
            toolDetails: [:],
            occurredAt: occurredAt,
            identity: .observation,
            isHidden: true)
    }

    static func acceptedRemoteDispatch(
        target: ChatPendingRemoteTargetV1,
        acceptance: ChatRemoteTurnDispatchAcceptance,
        attempt: UInt64 = 1
    ) -> ChatRemoteJobProjection {
        let resolvedAttempt = max(attempt, 1)
        let attemptStage = resolvedAttempt > 1
            ? " → 重試：第 \(resolvedAttempt) 次嘗試"
            : ""
        let lifecycle =
            "借用原因：本機工作需要遠端算力"
            + " → 目標：\(publicTargetName(target.targetDisplayName))"
            + " → 傳送：已送達"
            + " → 排隊/執行：等待目標啟動"
            + " → 回傳：等待"
            + " → 本機驗證：等待"
            + attemptStage
            + " → 完成：等待"
        return ChatRemoteJobProjection(
            logicalKey: target.logicalJobID,
            attempt: resolvedAttempt,
            publicState: .delivered,
            terminalOutcome: nil,
            runtimeTruth: .observedThisProcess,
            publicNarrative: publicStatus(
                publicState: .delivered,
                terminalOutcome: nil,
                blocker: nil),
            blocker: nil,
            toolDetails: [
                "attempts": String(resolvedAttempt),
                "contractID": safeDetail(target.contractID),
                "goalID": safeDetail(target.goalID),
                "jobID": safeDetail(acceptance.remoteJobID),
                "lifecycle": safeDetail(lifecycle),
                "logicalJobID": safeDetail(acceptance.logicalJobID),
                "targetDeviceID": safeDetail(target.targetDeviceID),
            ],
            occurredAt: acceptance.acceptedAt,
            identity: .acceptedDispatch(remoteJobID: acceptance.remoteJobID),
            isHidden: false)
    }

    private static func projection(
        logicalKey: String,
        records: [TatwoDispatchRecord]
    ) -> ChatRemoteJobProjection {
        let winningAttempt = records.map(\.resolvedAttempt).max() ?? 1
        let sorted = records.filter {
            $0.resolvedAttempt == winningAttempt
        }.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id < $1.id
        }
        let highestPublicState = sorted
            .compactMap(publicState)
            .max { $0.rank < $1.rank }
        let terminalRecord = sorted.last {
            terminalOutcome(for: $0) != nil
        }
        // Named distinctly from `terminalOutcome(for:)` so Swift 6.3 does not
        // treat the function call in the `last` closure as a circular reference
        // to this local.
        let terminalOutcomeValue = terminalRecord.flatMap {
            terminalOutcome(for: $0)
        }
        let recordedBlocker = sorted.reversed()
            .compactMap { record in
                normalized(record.errorMessage)
                    ?? normalized(record.failureReceipt?.operatorMessage)
            }
            .first
            .map(publicBlocker)
        let blocker = recordedBlocker ?? terminalOutcomeValue?.defaultBlocker
        let target = sorted.contains(where: { normalized($0.targetDeviceID) != nil })
            ? "已綁定的遠端設備"
            : "遠端設備"
        let lifecycle = lifecycleNarrative(
            attempt: UInt64(max(winningAttempt, 1)),
            publicState: highestPublicState,
            terminalOutcome: terminalOutcomeValue,
            target: target,
            blocker: blocker)
        var details = toolDetails(records: sorted)
        details["lifecycle"] = safeDetail(lifecycle)
        return ChatRemoteJobProjection(
            logicalKey: logicalKey,
            attempt: UInt64(max(winningAttempt, 1)),
            publicState: terminalOutcomeValue == nil ? highestPublicState : nil,
            terminalOutcome: terminalOutcomeValue,
            runtimeTruth: terminalOutcomeValue != nil
                || highestPublicState == .completed
                || highestPublicState == .verified
                ? .terminalReceipt
                : .observedThisProcess,
            publicNarrative: publicStatus(
                publicState: highestPublicState,
                terminalOutcome: terminalOutcomeValue,
                blocker: blocker),
            blocker: blocker,
            toolDetails: details,
            occurredAt: terminalRecord?.updatedAt
                ?? sorted.map(\.updatedAt).max()
                ?? sorted.map(\.startedAt).max()
                ?? Date(timeIntervalSince1970: 0),
            identity: .observation,
            isHidden: false)
    }

    private static func canonicalKey(_ record: TatwoDispatchRecord) -> String {
        normalized(record.logicalDispatchID)
            ?? normalized(record.remoteJobID)
            ?? record.id
    }

    private static func isRemoteRecord(_ record: TatwoDispatchRecord) -> Bool {
        normalized(record.remoteJobID) != nil
            && normalized(record.originDeviceID) != nil
            && normalized(record.targetDeviceID) != nil
            && record.remoteStatus != nil
    }

    private static func publicState(
        _ record: TatwoDispatchRecord
    ) -> ChatRemoteJobPublicState? {
        if let remoteStatus = record.remoteStatus {
            switch remoteStatus {
            case .queued, .failed, .cancelled:
                return nil
            case .delivered:
                return .delivered
            case .accepted:
                return .started
            case .running:
                return .running
            case .completed:
                return .completed
            case .verified:
                return .verified
            }
        }
        guard normalized(record.remoteJobID) != nil else { return nil }
        switch record.status {
        case .queued, .failed:
            return nil
        case .running:
            return .running
        case .completed:
            return .completed
        case .verified:
            return .verified
        }
    }

    private static func terminalOutcome(
        for record: TatwoDispatchRecord
    ) -> ChatRemoteJobTerminalOutcome? {
        if let remoteStatus = record.remoteStatus {
            switch remoteStatus {
            case .failed:
                return .failed
            case .cancelled:
                return .cancelled
            case .queued, .delivered, .accepted, .running, .completed, .verified:
                return nil
            }
        }
        return record.status == .failed ? .failed : nil
    }

    private static func lifecycleNarrative(
        attempt: UInt64,
        publicState: ChatRemoteJobPublicState?,
        terminalOutcome: ChatRemoteJobTerminalOutcome?,
        target: String,
        blocker: String?
    ) -> String {
        let transfer: String
        let execution: String
        let returnStage: String
        let localVerification: String
        let completion: String
        switch terminalOutcome {
        case .failed:
            transfer = publicState == nil
                ? "派工失敗"
                : ChatRemoteJobPublicState.delivered.rawValue
            execution = ChatRemoteJobTerminalOutcome.failed.rawValue
            returnStage = "未回傳"
            localVerification = "未驗證"
            completion = blocker ?? ChatRemoteJobTerminalOutcome.failed.defaultBlocker
        case .cancelled:
            transfer = publicState == nil
                ? "派工已取消"
                : ChatRemoteJobPublicState.delivered.rawValue
            execution = ChatRemoteJobTerminalOutcome.cancelled.rawValue
            returnStage = "未回傳"
            localVerification = "未驗證"
            completion = blocker ?? ChatRemoteJobTerminalOutcome.cancelled.defaultBlocker
        case nil:
            switch publicState {
        case .delivered:
            transfer = ChatRemoteJobPublicState.delivered.rawValue
            execution = "等待啟動"
            returnStage = "等待"
            localVerification = "等待"
            completion = "等待"
        case .started:
            transfer = ChatRemoteJobPublicState.delivered.rawValue
            execution = ChatRemoteJobPublicState.started.rawValue
            returnStage = "等待"
            localVerification = "等待"
            completion = "等待"
        case .running:
            transfer = ChatRemoteJobPublicState.delivered.rawValue
            execution = ChatRemoteJobPublicState.running.rawValue
            returnStage = "等待"
            localVerification = "等待"
            completion = "等待"
        case .completed:
            transfer = ChatRemoteJobPublicState.delivered.rawValue
            execution = ChatRemoteJobPublicState.completed.rawValue
            returnStage = "已回傳"
            localVerification = "等待"
            completion = "等待驗收"
        case .verified:
            transfer = ChatRemoteJobPublicState.delivered.rawValue
            execution = ChatRemoteJobPublicState.completed.rawValue
            returnStage = "已回傳"
            localVerification = ChatRemoteJobPublicState.verified.rawValue
            completion = "完成"
        case nil:
            transfer = blocker ?? "等待可信派工證據"
            execution = "尚未開始"
            returnStage = "等待"
            localVerification = "等待"
            completion = "等待"
            }
        }
        let attemptStage = attempt > 1
            ? " → 重試：第 \(attempt) 次嘗試"
            : ""
        return
            "借用原因：本機工作需要遠端算力"
            + " → 目標：\(target)"
            + " → 傳送：\(transfer)"
            + " → 排隊/執行：\(execution)"
            + " → 回傳：\(returnStage)"
            + " → 本機驗證：\(localVerification)"
            + attemptStage
            + " → 完成：\(completion)"
    }

    private static func publicStatus(
        publicState: ChatRemoteJobPublicState?,
        terminalOutcome: ChatRemoteJobTerminalOutcome?,
        blocker: String?
    ) -> String {
        switch terminalOutcome {
        case .failed:
            return "遠端工作失敗 · 查看詳情"
        case .cancelled:
            return "遠端工作已取消"
        case nil:
            switch publicState {
            case .delivered:
                return "已送達遠端設備，等待啟動"
            case .started:
                return "遠端設備已啟動，準備執行"
            case .running:
                return "正在遠端設備執行"
            case .completed:
                return "遠端結果已回傳，正在本機驗證"
            case .verified:
                return "遠端工作已完成並驗收"
            case nil:
                guard blocker != nil else { return "等待遠端設備" }
                return "等待遠端設備 · 查看詳情"
            }
        }
    }

    private static func toolDetails(
        records: [TatwoDispatchRecord]
    ) -> [String: String] {
        var details: [String: String] = [:]
        insert("logicalDispatchID", values: records.map(\.logicalDispatchID), into: &details)
        insert("dispatchRecordID", values: records.map { Optional($0.id) }, into: &details)
        insert("jobID", values: records.map(\.remoteJobID), into: &details)
        insert("originDeviceID", values: records.map(\.originDeviceID), into: &details)
        insert("targetDeviceID", values: records.map(\.targetDeviceID), into: &details)
        insert("receiptID", values: records.map(\.receiptID), into: &details)
        insert("jobDigest", values: records.map(\.remoteJobDigest), into: &details)
        insert("dispatchNonce", values: records.map(\.remoteDispatchNonce), into: &details)
        insert("resultDigest", values: records.map(\.consumedResultDigest), into: &details)
        insert("outputRef", values: records.map(\.outputRef), into: &details)
        insert("rawStatus", values: records.map {
            Optional($0.remoteStatus?.rawValue ?? $0.status.rawValue)
        }, into: &details)
        insert("error", values: records.map {
            $0.errorMessage ?? $0.failureReceipt?.operatorMessage
        }, into: &details)
        details["attempts"] = records
            .map(\.resolvedAttempt)
            .sorted()
            .map(String.init)
            .joined(separator: ", ")
        return details
    }

    private static func insert(
        _ key: String,
        values: [String?],
        into details: inout [String: String]
    ) {
        let unique = Array(Set(values.compactMap(normalized))).sorted()
        guard !unique.isEmpty else { return }
        details[key] = safeDetail(unique.joined(separator: ", "))
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func publicTargetName(_ value: String) -> String {
        let safe = TatwoPrivacyRedactor.redacted(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "遠端設備" : String(safe.prefix(80))
    }

    private static func publicBlocker(_ value: String) -> String {
        let safe = TatwoPrivacyRedactor.redacted(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "等待目標環境綁定" : String(safe.prefix(180))
    }

    private static func safeDetail(_ value: String) -> String {
        String(TatwoPrivacyRedactor.redacted(value).prefix(512))
    }
}

enum ChatRemoteJobInlinePresentation {
    struct Payload: Codable, Equatable {
        let state: ChatRemoteJobPublicState?
        let terminalOutcome: ChatRemoteJobTerminalOutcome?
        let runtimeTruth: ChatRemoteJobRuntimeTruth?
        let blocker: String?
        let details: [String: String]

        init(
            state: ChatRemoteJobPublicState?,
            terminalOutcome: ChatRemoteJobTerminalOutcome?,
            runtimeTruth: ChatRemoteJobRuntimeTruth? = nil,
            blocker: String?,
            details: [String: String]
        ) {
            self.state = state
            self.terminalOutcome = terminalOutcome
            self.runtimeTruth = runtimeTruth
            self.blocker = blocker
            self.details = details
        }
    }

    private static let prefix = "remote-job-v1:"

    static func status(
        state: ChatRemoteJobPublicState?,
        terminalOutcome: ChatRemoteJobTerminalOutcome? = nil,
        runtimeTruth: ChatRemoteJobRuntimeTruth?,
        blocker: String?,
        details: [String: String]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(
            Payload(
                state: state,
                terminalOutcome: terminalOutcome,
                runtimeTruth: runtimeTruth,
                blocker: blocker,
                details: details))) ?? Data()
        return prefix + data.base64EncodedString()
    }

    static func payload(from status: String?) -> Payload? {
        guard let status, status.hasPrefix(prefix) else { return nil }
        let encoded = String(status.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}

struct ChatTranscriptJournalDiskStore: Sendable {
    private struct SanitizerMigrationReceiptV1: Codable, Equatable {
        let schema: String
        let status: String
        let source: String
        let backup: String
        let rewrittenEvents: Int
        let removedEvents: Int
        let originalSHA256: String
        let sanitizedSHA256: String

        func changingStatus(to status: String) -> Self {
            Self(
                schema: schema,
                status: status,
                source: source,
                backup: backup,
                rewrittenEvents: rewrittenEvents,
                removedEvents: removedEvents,
                originalSHA256: originalSHA256,
                sanitizedSHA256: sanitizedSHA256)
        }
    }

    private struct PreparedSanitizerMigration {
        let directory: URL
        let preparedURL: URL
        let prepared: SanitizerMigrationReceiptV1
        let backupData: Data
        let authoritativeSanitizedData: Data
    }

    let fileURL: URL
    private static let processLock = NSLock()
    private static let coalesceLock = NSLock()
    nonisolated(unsafe) private static var pendingCoalescedSaves: [URL: PendingCoalescedSave] = [:]
    nonisolated(unsafe) private static var didInstallTerminateFlushHook = false
    static let coalescedSaveDelay: TimeInterval = 0.5

    private struct PendingCoalescedSave {
        var journal: ChatTranscriptJournalV1
        var workItem: DispatchWorkItem
    }

    private let canonicalSnapshotWriter:
        @Sendable (Data, URL) throws -> Void
    private let migrationReceiptWriter:
        @Sendable (Data, URL) throws -> Void
    private let migrationFileRemover:
        @Sendable (URL) throws -> Void

    init(
        fileURL: URL,
        canonicalSnapshotWriter:
            @escaping @Sendable (Data, URL) throws -> Void = { data, url in
                try data.write(to: url, options: [.atomic])
            },
        migrationReceiptWriter:
            @escaping @Sendable (Data, URL) throws -> Void = { data, url in
                try data.write(to: url, options: [.atomic])
            },
        migrationFileRemover:
            @escaping @Sendable (URL) throws -> Void = { url in
                try FileManager.default.removeItem(at: url)
            }
    ) {
        self.fileURL = fileURL
        self.canonicalSnapshotWriter = canonicalSnapshotWriter
        self.migrationReceiptWriter = migrationReceiptWriter
        self.migrationFileRemover = migrationFileRemover
    }

    func load() throws -> ChatTranscriptJournalV1 {
        try Self.processLock.withLock {
            try loadCanonicalUnlocked()
        }
    }

    @discardableResult
    func saveMerging(
        _ journal: ChatTranscriptJournalV1
    ) throws -> ChatTranscriptJournalV1 {
        let pending = Self.takePendingCoalescedJournal(for: fileURL)
        return try Self.processLock.withLock {
            var latest = try loadCanonicalUnlocked()
            if let pending {
                let canonicalPending = try diskCanonicalJournal(pending)
                try merge(canonicalPending.events, into: &latest)
            }
            let incoming = try diskCanonicalJournal(journal)
            try merge(incoming.events, into: &latest)
            return try saveUnlocked(latest)
        }
    }

    func scheduleCoalescedSave(_ journal: ChatTranscriptJournalV1) {
        Self.installTerminateFlushHookIfNeeded()
        let url = fileURL
        Self.coalesceLock.lock()
        Self.pendingCoalescedSaves[url]?.workItem.cancel()
        let workItem = DispatchWorkItem {
            Self.flushPendingCoalescedSave(for: url)
        }
        Self.pendingCoalescedSaves[url] = PendingCoalescedSave(
            journal: journal,
            workItem: workItem)
        Self.coalesceLock.unlock()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.coalescedSaveDelay,
            execute: workItem)
    }

    func flushCoalescedSaveIfNeeded() {
        Self.flushPendingCoalescedSave(for: fileURL)
    }

    private static func takePendingCoalescedJournal(for url: URL) -> ChatTranscriptJournalV1? {
        coalesceLock.lock()
        defer { coalesceLock.unlock() }
        let pending = pendingCoalescedSaves.removeValue(forKey: url)
        pending?.workItem.cancel()
        return pending?.journal
    }

    private static func flushPendingCoalescedSave(for url: URL) {
        guard let journal = takePendingCoalescedJournal(for: url) else { return }
        _ = try? ChatTranscriptJournalDiskStore(fileURL: url).saveMerging(journal)
    }

    private static func flushAllPendingCoalescedSaves() {
        coalesceLock.lock()
        let urls = Array(pendingCoalescedSaves.keys)
        coalesceLock.unlock()
        for url in urls {
            flushPendingCoalescedSave(for: url)
        }
    }

    private static func installTerminateFlushHookIfNeeded() {
        coalesceLock.lock()
        let shouldInstall = !didInstallTerminateFlushHook
        if shouldInstall {
            didInstallTerminateFlushHook = true
        }
        coalesceLock.unlock()
        guard shouldInstall else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            flushAllPendingCoalescedSaves()
        }
    }

    @discardableResult
    func mergeRemoteJobProjections(
        _ projections: [ChatRemoteJobProjection],
        threadID: String,
        projectionProcessID: String =
            ChatTranscriptJournalAdapter.remoteProjectionProcessID
    ) throws -> ChatTranscriptJournalV1 {
        let pending = Self.takePendingCoalescedJournal(for: fileURL)
        return try Self.processLock.withLock {
            var latest = try loadCanonicalUnlocked()
            if let pending {
                let canonicalPending = try diskCanonicalJournal(pending)
                try merge(canonicalPending.events, into: &latest)
            }
            let outcomes = projections.map {
                ChatTranscriptJournalAdapter.append(
                    remoteJob: $0,
                    threadID: threadID,
                    projectionProcessID: projectionProcessID,
                    to: &latest)
            }
            guard outcomes.allSatisfy(Self.isAcceptedRemoteJobReplayOutcome)
            else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }
            if outcomes.contains(where: \.wasAppended) {
                return try saveUnlocked(latest)
            }
            return latest
        }
    }

    func save(_ journal: ChatTranscriptJournalV1) throws {
        let pending = Self.takePendingCoalescedJournal(for: fileURL)
        try Self.processLock.withLock {
            var latest = try diskCanonicalJournal(journal)
            if let pending {
                let canonicalPending = try diskCanonicalJournal(pending)
                try merge(canonicalPending.events, into: &latest)
            }
            _ = try saveUnlocked(latest)
        }
    }

    private func loadCanonicalUnlocked() throws -> ChatTranscriptJournalV1 {
        try reconcilePreparedMigrationReceiptsUnlocked()
        let loaded = try loadUnlocked()
        let migration = try sanitizedUserTranscriptJournal(loaded)
        guard migration.didChange else { return loaded }

        let originalData = try Data(contentsOf: fileURL)
        let originalSHA256 = Self.sha256Hex(originalData)
        let sanitizedData = try migration.journal.encodedSnapshot()
        let sanitizedSHA256 = Self.sha256Hex(sanitizedData)
        let backupRoot = fileURL.deletingLastPathComponent()
            .appendingPathComponent("chat-repair-backups", isDirectory: true)
            .appendingPathComponent(
                "sanitizer-v1-\(originalSHA256)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupRoot,
            withIntermediateDirectories: true)
        let backupURL = backupRoot.appendingPathComponent(
            fileURL.lastPathComponent,
            isDirectory: false)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            guard try Data(contentsOf: backupURL) == originalData else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }
        } else {
            try originalData.write(to: backupURL, options: [.atomic])
        }

        let preparedReceipt = SanitizerMigrationReceiptV1(
            schema: "TatwoChatTranscriptSanitizerMigrationReceiptV1",
            status: "prepared",
            source: fileURL.path,
            backup: backupURL.path,
            rewrittenEvents: migration.rewrittenEvents,
            removedEvents: migration.removedEvents,
            originalSHA256: originalSHA256,
            sanitizedSHA256: sanitizedSHA256)
        let completedReceipt = preparedReceipt.changingStatus(to: "completed")
        let preparedReceiptURL = backupRoot.appendingPathComponent(
            "migration-receipt.prepared.json")
        let completedReceiptURL = backupRoot.appendingPathComponent(
            "migration-receipt.json")
        if FileManager.default.fileExists(atPath: completedReceiptURL.path) {
            try migrationFileRemover(completedReceiptURL)
        }
        try migrationReceiptWriter(
            try encodedMigrationReceipt(preparedReceipt),
            preparedReceiptURL)

        // This is a canonical replacement, not a merge. Re-merging the raw
        // events would restore the exact hidden prompt rows we just removed.
        try canonicalSnapshotWriter(sanitizedData, fileURL)
        // The writer is injectable and success does not prove which bytes
        // reached the canonical path. Read that path exactly once, bind the
        // completed receipt to its digest, and decode those same bytes.
        let persistedSanitizedData = try Data(contentsOf: fileURL)
        guard Self.sha256Hex(persistedSanitizedData) == sanitizedSHA256 else {
            throw ChatTranscriptJournalDiskStoreError.mergeRejected
        }
        let persistedSanitizedJournal =
            try ChatTranscriptJournalV1.restoring(
                from: persistedSanitizedData)
        try migrationReceiptWriter(
            try encodedMigrationReceipt(completedReceipt),
            completedReceiptURL)
        try migrationFileRemover(preparedReceiptURL)
        return persistedSanitizedJournal
    }

    private func reconcilePreparedMigrationReceiptsUnlocked() throws {
        let repairRoot = fileURL.deletingLastPathComponent()
            .appendingPathComponent("chat-repair-backups", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: repairRoot.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return }

        let migrationDirectories = try FileManager.default.contentsOfDirectory(
            at: repairRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("sanitizer-v1-") }
            .sorted { $0.path < $1.path }
        var preparedMigrations: [PreparedSanitizerMigration] = []
        for directory in migrationDirectories {
            let preparedURL = directory.appendingPathComponent(
                "migration-receipt.prepared.json")
            guard FileManager.default.fileExists(atPath: preparedURL.path)
            else { continue }

            let prepared = try decodedMigrationReceipt(at: preparedURL)
            guard prepared.schema
                == "TatwoChatTranscriptSanitizerMigrationReceiptV1",
                prepared.status == "prepared",
                URL(fileURLWithPath: prepared.source).standardizedFileURL
                    == fileURL.standardizedFileURL,
                directory.lastPathComponent
                    == "sanitizer-v1-\(prepared.originalSHA256)"
            else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }

            let backupURL = URL(fileURLWithPath: prepared.backup)
                .standardizedFileURL
            let expectedBackupURL = directory.appendingPathComponent(
                fileURL.lastPathComponent).standardizedFileURL
            guard backupURL == expectedBackupURL else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }
            let backupData = try Data(contentsOf: backupURL)
            guard Self.sha256Hex(backupData) == prepared.originalSHA256 else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }
            let backupJournal =
                try ChatTranscriptJournalV1.restoring(from: backupData)
            let recomputedMigration =
                try sanitizedUserTranscriptJournal(backupJournal)
            let recomputedSanitizedData =
                try recomputedMigration.journal.encodedSnapshot()
            guard recomputedMigration.didChange,
                  prepared.rewrittenEvents
                    == recomputedMigration.rewrittenEvents,
                  prepared.removedEvents
                    == recomputedMigration.removedEvents,
                  prepared.sanitizedSHA256
                    == Self.sha256Hex(recomputedSanitizedData)
            else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }

            preparedMigrations.append(
                PreparedSanitizerMigration(
                    directory: directory,
                    preparedURL: preparedURL,
                    prepared: prepared,
                    backupData: backupData,
                    authoritativeSanitizedData: recomputedSanitizedData))
        }

        // A content-addressed sanitizer directory is unique only for one raw
        // snapshot. Two independently valid prepared receipts targeting the
        // same canonical path represent conflicting recovery histories. Do not
        // let directory sort order choose which backup rewrites or quarantines
        // canonical evidence.
        guard preparedMigrations.count <= 1 else {
            throw ChatTranscriptJournalDiskStoreError.mergeRejected
        }

        for migration in preparedMigrations {
            let directory = migration.directory
            let preparedURL = migration.preparedURL
            let prepared = migration.prepared
            let backupData = migration.backupData
            let authoritativeSanitizedData =
                migration.authoritativeSanitizedData
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                try restorePreparedMigrationBackupUnlocked(
                    backupData,
                    expectedSHA256: prepared.originalSHA256)
                continue
            }
            let currentData = try Data(contentsOf: fileURL)
            let currentSHA256 = Self.sha256Hex(currentData)
            if currentSHA256 == prepared.originalSHA256 {
                // The canonical replacement did not commit. The normal
                // migration path below will retry against this same
                // content-addressed backup.
                continue
            }
            if currentData != authoritativeSanitizedData {
                // A writer may have returned success after publishing invalid
                // or unrelated bytes. Preserve that evidence before restoring
                // the verified raw backup for a normal sanitizer retry.
                try quarantineCanonicalFileUnlocked(reason: "unexpected")
                try restorePreparedMigrationBackupUnlocked(
                    backupData,
                    expectedSHA256: prepared.originalSHA256)
                continue
            }
            guard currentSHA256 == prepared.sanitizedSHA256 else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }
            _ = try ChatTranscriptJournalV1.restoring(from: currentData)

            let completedURL = directory.appendingPathComponent(
                "migration-receipt.json")
            let expectedCompleted = prepared.changingStatus(to: "completed")
            if FileManager.default.fileExists(atPath: completedURL.path) {
                guard try decodedMigrationReceipt(at: completedURL)
                    == expectedCompleted
                else {
                    throw ChatTranscriptJournalDiskStoreError.mergeRejected
                }
            } else {
                try migrationReceiptWriter(
                    try encodedMigrationReceipt(expectedCompleted),
                    completedURL)
            }
            try migrationFileRemover(preparedURL)
        }
    }

    private func restorePreparedMigrationBackupUnlocked(
        _ backupData: Data,
        expectedSHA256: String
    ) throws {
        try backupData.write(to: fileURL, options: [.atomic])
        let restoredData = try Data(contentsOf: fileURL)
        guard restoredData == backupData,
              Self.sha256Hex(restoredData) == expectedSHA256
        else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try quarantineCanonicalFileUnlocked(reason: "restore-mismatch")
            }
            throw ChatTranscriptJournalDiskStoreError.mergeRejected
        }
    }

    private func encodedMigrationReceipt(
        _ receipt: SanitizerMigrationReceiptV1
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(receipt)
    }

    private func decodedMigrationReceipt(
        at url: URL
    ) throws -> SanitizerMigrationReceiptV1 {
        do {
            return try JSONDecoder().decode(
                SanitizerMigrationReceiptV1.self,
                from: Data(contentsOf: url))
        } catch {
            // Recovery receipts are authority-bearing evidence. Whether the
            // bytes are truncated, structurally invalid, or unreadable, do not
            // let a codec/IO detail escape as an alternate recovery path.
            throw ChatTranscriptJournalDiskStoreError.mergeRejected
        }
    }

    private func loadUnlocked() throws -> ChatTranscriptJournalV1 {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ChatTranscriptJournalV1()
        }
        let snapshot = try Data(contentsOf: fileURL)
        do {
            return try ChatTranscriptJournalV1.restoring(from: snapshot)
        } catch {
            do {
                try quarantineCanonicalFileUnlocked(reason: "invalid")
            } catch {
                throw ChatTranscriptJournalDiskStoreError.quarantineFailed
            }
            return ChatTranscriptJournalV1()
        }
    }

    private func quarantineCanonicalFileUnlocked(reason: String) throws {
        let quarantineURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(fileURL.lastPathComponent).\(reason)-\(UUID().uuidString).quarantine")
        try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
    }

    private func saveUnlocked(
        _ journal: ChatTranscriptJournalV1
    ) throws -> ChatTranscriptJournalV1 {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let snapshot = try journal.encodedSnapshot()
        try canonicalSnapshotWriter(snapshot, fileURL)
        let persistedSnapshot = try Data(contentsOf: fileURL)
        guard persistedSnapshot == snapshot else {
            _ = try loadUnlocked()
            throw ChatTranscriptJournalDiskStoreError.mergeRejected
        }
        return try ChatTranscriptJournalV1.restoring(from: persistedSnapshot)
    }

    private func sanitizedUserTranscriptJournal(
        _ journal: ChatTranscriptJournalV1
    ) throws -> (
        journal: ChatTranscriptJournalV1,
        didChange: Bool,
        rewrittenEvents: Int,
        removedEvents: Int
    ) {
        var sanitized = ChatTranscriptJournalV1()
        var didChange = false
        var rewrittenEvents = 0
        var removedEvents = 0

        for event in journal.events {
            let isUserMessage = event.kind == .message
                && event.attributes["role"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "user"
            guard isUserMessage, let rawSummary = event.summary else {
                let outcome = sanitized.append(event)
                guard outcome.wasAppended else {
                    throw ChatTranscriptJournalDiskStoreError.mergeRejected
                }
                continue
            }

            let cleanSummary =
                TatwoChatTranscriptPresentation.cleanedTranscriptSource(
                    rawSummary,
                    role: .user)
            if cleanSummary.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
            {
                didChange = true
                removedEvents += 1
                continue
            }
            let candidate: ChatTranscriptEventV1
            if cleanSummary == rawSummary {
                candidate = event
            } else {
                didChange = true
                rewrittenEvents += 1
                candidate = ChatTranscriptEventV1(
                    eventID: event.eventID,
                    threadID: event.threadID,
                    turnID: event.turnID,
                    itemID: event.itemID,
                    sequence: event.sequence,
                    kind: event.kind,
                    phase: event.phase,
                    source: event.source,
                    sourceEventType: event.sourceEventType,
                    occurredAt: event.occurredAt,
                    title: event.title,
                    summary: cleanSummary,
                    attributes: event.attributes)
            }
            let outcome = sanitized.append(candidate)
            guard outcome.wasAppended else {
                throw ChatTranscriptJournalDiskStoreError.mergeRejected
            }
        }
        return (
            sanitized,
            didChange,
            rewrittenEvents,
            removedEvents)
    }

    /// Every persisted Date crosses the journal's millisecond JSON boundary.
    /// Coalesced UI state can still contain the original sub-millisecond Date,
    /// so replaying it against a disk-loaded snapshot would otherwise turn an
    /// idempotent event into a conflicting event ID. Normalize the complete
    /// candidate through the exact durable codec before any merge.
    private func diskCanonicalJournal(
        _ journal: ChatTranscriptJournalV1
    ) throws -> ChatTranscriptJournalV1 {
        let sanitized = try sanitizedUserTranscriptJournal(journal).journal
        return try ChatTranscriptJournalV1.restoring(
            from: sanitized.encodedSnapshot())
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func merge(
        _ events: [ChatTranscriptEventV1],
        into journal: inout ChatTranscriptJournalV1
    ) throws {
        for event in events {
            let outcome = journal.append(event)
            if outcome.wasAppended { continue }
            if case .ignored(.duplicateEvent) = outcome { continue }
            throw ChatTranscriptJournalDiskStoreError.mergeRejected
        }
    }

    private static func isAcceptedRemoteJobReplayOutcome(
        _ outcome: ChatTranscriptAppendOutcomeV1
    ) -> Bool {
        if outcome.wasAppended { return true }
        switch outcome {
        case .ignored(.duplicateEvent),
             .ignored(.lifecycleRegression),
             .ignored(.staleAttempt),
             .ignored(.terminalItem):
            return true
        case .appended, .ignored:
            return false
        }
    }
}

enum ChatTranscriptJournalDiskStoreError: Error {
    case quarantineFailed
    case mergeRejected
}

enum ChatTranscriptJournalPersistMode: Sendable, Equatable {
    case immediate
    case coalesced
}

enum ChatTranscriptJournalAdapter {
    static let remoteProjectionProcessID = UUID().uuidString.lowercased()

    private enum CanonicalRole: String {
        case user
        case assistant
        case system

        init?(_ role: ChatMessageRole) {
            switch role {
            case .user: self = .user
            case .assistant: self = .assistant
            case .system: self = .system
            }
        }

        init?(storedRole: String) {
            switch storedRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "user", "you": self = .user
            case "assistant", "cli", "codex", "claude": self = .assistant
            case "system", "os", "work-os": self = .system
            default: return nil
            }
        }

        var messageRole: ChatMessageRole {
            switch self {
            case .user: .user
            case .assistant: .assistant
            case .system: .system
            }
        }
    }

    static func sourceMetadata(
        route: ChatRouteChoice,
        runID: String,
        attempt: UInt64? = nil,
        runnerInstanceID: UUID? = nil,
        runnerRevision: UInt64? = nil
    ) -> ChatTranscriptSourceMetadataV1 {
        ChatTranscriptSourceMetadataV1(
            source: providerID(for: route),
            model: route.canonicalModelSlug,
            runtime: route.runtimeAdapter.rawValue,
            runID: runID,
            attempt: attempt,
            runnerInstanceID: runnerInstanceID,
            runnerRevision: runnerRevision)
    }

    /// Provider identity resolved from one model identity only.
    ///
    /// Both the frozen per-turn provenance and the assistant message
    /// projection resolve `source` through this, so command/activity events
    /// and the result of the same turn cannot disagree on provider.
    static func provenanceProviderID(modelID: String) -> String {
        providerID(modelID: modelID)
            ?? ChatRouteChoice.resolveOrNil(modelID).map { providerID(for: $0) }
            ?? "assistant"
    }

    /// Source metadata built from this turn's immutable execution provenance.
    ///
    /// Unlike `sourceMetadata(route:…)` this never reads the live model
    /// picker, so a mid-turn route change cannot split one run's attribution
    /// across two model identities.
    static func sourceMetadata(
        provenance: ChatTurnExecutionProvenance,
        runID: String,
        attempt: UInt64? = nil,
        runnerInstanceID: UUID? = nil,
        runnerRevision: UInt64? = nil
    ) -> ChatTranscriptSourceMetadataV1 {
        ChatTranscriptSourceMetadataV1(
            source: provenance.providerID,
            model: provenance.modelID,
            runtime: provenance.runtimeAdapterID,
            runID: runID,
            attempt: attempt,
            runnerInstanceID: runnerInstanceID,
            runnerRevision: runnerRevision)
    }

    @discardableResult
    static func append(
        activity: ChatActivityEventV1,
        context: ChatTranscriptJournalContext,
        to journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptAppendOutcomeV1 {
        let phase: ChatTranscriptLifecyclePhaseV1
        switch activity.status {
        case .running:
            phase = .running
        case .succeeded:
            phase = .completed
        case .failed:
            phase = .failed
        }
        let source = ChatTranscriptSourceMetadataV1(
            source: context.source.source,
            model: context.source.model,
            runtime: context.source.runtime,
            sessionID: context.source.sessionID,
            runID: context.source.runID,
            attempt: UInt64(activity.attempt),
            runnerInstanceID: context.source.runnerInstanceID,
            runnerRevision: context.source.runnerRevision)
        let isReasoningSummary = activity.kind == .thinking
        let durableSummary = isReasoningSummary
            ? safeReasoningSummary(
                text: activity.detail ?? "",
                rawType: activity.sourceType)
            : activity.detail
        let itemID = stableID(
            prefix: "chat-item",
            parts: [
                context.threadID,
                context.turnID,
                "attempt:\(activity.attempt)",
                "activity:\(activity.id)",
            ])
        let eventID = stableID(
            prefix: "chat-event",
            parts: [
                itemID,
                phase.rawValue,
                activity.sourceType ?? "",
                durableSummary ?? "",
            ])
        return appendStableEvent(
            eventID: eventID,
            itemID: itemID,
            kind: itemKind(for: activity.kind),
            phase: phase,
            title: isReasoningSummary ? "Reasoning summary" : activity.label,
            summary: durableSummary,
            attributes: activityAttributes(activity),
            sourceEventType: activity.sourceType,
            occurredAt: activity.endedAt ?? activity.startedAt,
            context: ChatTranscriptJournalContext(
                threadID: context.threadID,
                turnID: context.turnID,
                runID: context.runID,
                source: source),
            to: &journal)
    }

    /// All reasoning deltas for one turn converge into one structural summary
    /// item. Raw reasoning content/deltas are never copied into the durable
    /// journal.
    @discardableResult
    static func appendReasoningSummary(
        text: String,
        rawType: String?,
        context: ChatTranscriptJournalContext,
        occurredAt: Date = Date(),
        to journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptAppendOutcomeV1 {
        let existingBytes = journal.turn(
            threadID: context.threadID,
            turnID: context.turnID)?
            .items
            .filter { $0.kind == .reasoningSummary }
            .compactMap(\.summary)
            .reduce(0) { $0 + $1.utf8.count } ?? 0
        let remainingBytes = max(0, 256 * 1_024 - existingBytes)
        let summary = safeReasoningSummary(
            text: text,
            rawType: rawType,
            maximumBytes: remainingBytes)
        let itemID = stableID(
            prefix: "chat-item",
            parts: [
                context.threadID,
                context.turnID,
                "reasoning-summary",
            ])
        return appendStableEvent(
            eventID: stableID(
                prefix: "chat-event",
                parts: [itemID, ChatTranscriptLifecyclePhaseV1.completed.rawValue]),
            itemID: itemID,
            kind: .reasoningSummary,
            phase: .completed,
            title: "Reasoning summary",
            summary: summary,
            attributes: [:],
            sourceEventType: nil,
            occurredAt: occurredAt,
            context: context,
            to: &journal)
    }

    @discardableResult
    static func appendResult(
        messageID: String,
        text: String?,
        phase: ChatTranscriptLifecyclePhaseV1,
        occurredAt: Date,
        runtimeFallbackReason: TatwoChatRuntimeFallbackReason? = nil,
        planQuestions: [PlanQuestionV1] = [],
        context: ChatTranscriptJournalContext,
        to journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptAppendOutcomeV1 {
        let itemID = stableID(
            prefix: "chat-item",
            parts: [context.threadID, context.turnID, "result", messageID])
        var attributes: [String: String] = [
            "messageID": messageID,
            "role": CanonicalRole.assistant.rawValue,
            "eventKind": phase == .failed
                ? TatwoNativeChatEventKind.failure.rawValue
                : TatwoNativeChatEventKind.message.rawValue,
            "runtimeFallbackReason": runtimeFallbackReason?.rawValue ?? "",
        ]
        // A clarification-request turn can have empty visible text, so the
        // questions are its only durable payload. Journaling them keeps the
        // card alive across the post-commit projection refresh and cold start.
        if let encoded = TatwoPlanQuestionJournalCodec.encode(planQuestions) {
            attributes[TatwoPlanQuestionJournalCodec.attributeKey] = encoded
        }
        return appendStableEvent(
            eventID: stableID(
                prefix: "chat-event",
                parts: [itemID, phase.rawValue]),
            itemID: itemID,
            kind: .result,
            phase: phase,
            title: phase == .completed ? "Result" : "Turn ended",
            summary: normalizedNonEmpty(text),
            attributes: attributes,
            sourceEventType: "tatwo/chat/result",
            occurredAt: occurredAt,
            context: context,
            to: &journal)
    }

    @discardableResult
    static func appendError(
        message: String,
        context: ChatTranscriptJournalContext,
        occurredAt: Date = Date(),
        runtimeFallbackReason: TatwoChatRuntimeFallbackReason? = nil,
        to journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptAppendOutcomeV1 {
        let normalized = normalizedNonEmpty(message) ?? "Unknown chat runtime error"
        let itemID = stableID(
            prefix: "chat-item",
            parts: [context.threadID, context.turnID, "error"])
        return appendStableEvent(
            eventID: stableID(
                prefix: "chat-event",
                parts: [itemID, ChatTranscriptLifecyclePhaseV1.failed.rawValue]),
            itemID: itemID,
            kind: .error,
            phase: .failed,
            title: "Error",
            summary: normalized,
            attributes: [
                "messageID": context.turnID,
                "role": CanonicalRole.assistant.rawValue,
                "eventKind": TatwoNativeChatEventKind.failure.rawValue,
                "runtimeFallbackReason": runtimeFallbackReason?.rawValue ?? "",
            ],
            sourceEventType: "tatwo/chat/error",
            occurredAt: occurredAt,
            context: context,
            to: &journal)
    }

    @discardableResult
    static func append(
        remoteJob: ChatRemoteJobProjection,
        threadID: String,
        projectionProcessID: String = remoteProjectionProcessID,
        to journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptAppendOutcomeV1 {
        let turnID = stableID(
            prefix: "chat-remote-turn",
            parts: [threadID, remoteJob.logicalKey])
        let itemID = stableID(
            prefix: "chat-remote-item",
            parts: [threadID, remoteJob.logicalKey])
        let incomingRank = remoteJob.terminalOutcome?.rank
            ?? remoteJob.publicState?.rank
            ?? 0
        let incomingPhase = remoteJob.terminalOutcome?.lifecyclePhase
            ?? (remoteJob.publicState == .completed
                || remoteJob.publicState == .verified ? .completed
                : (remoteJob.publicState == nil ? .pending : .running))
        let existingItem = journal.item(
            threadID: threadID,
            turnID: turnID,
            itemID: itemID)
        if let existing = existingItem,
           let existingRank = Int(existing.attributes["remotePublicRank"] ?? "0")
        {
            let existingAttempt = existing.source.attempt ?? 0
            if existingAttempt > remoteJob.attempt {
                return .ignored(.staleAttempt(
                    itemID: itemID,
                    current: existingAttempt,
                    received: remoteJob.attempt))
            }
            if existingAttempt == remoteJob.attempt,
               existingRank > incomingRank
            {
                return .ignored(.lifecycleRegression(
                    itemID: itemID,
                    current: existing.phase,
                    received: incomingPhase))
            }
            if existingAttempt == remoteJob.attempt,
               existing.phase.isTerminal
            {
                return .ignored(.terminalItem(itemID: itemID, phase: existing.phase))
            }
        }

        var attributes = [
            "logicalDispatchID": remoteJob.logicalKey,
            "remotePublicRank": String(incomingRank),
            "remoteAttempt": String(remoteJob.attempt),
            "remoteProjectionProcessID":
                normalizedNonEmpty(projectionProcessID)
                ?? remoteProjectionProcessID,
            "remoteRuntimeTruth": remoteJob.runtimeTruth.rawValue,
        ]
        if let publicState = remoteJob.publicState {
            attributes["remotePublicState"] = publicState.rawValue
        } else {
            attributes["remotePublicState"] = ""
        }
        if let terminalOutcome = remoteJob.terminalOutcome {
            // Item attributes merge across events, so an explicit tombstone is
            // required to replace a previously projected `.running` state.
            attributes["remotePublicState"] = ""
            attributes["remoteTerminalOutcome"] = terminalOutcome.rawValue
        }
        if let blocker = remoteJob.blocker {
            attributes["remoteBlocker"] = blocker
        } else if existingItem?.attributes["remoteRuntimeTruth"]
            == ChatRemoteJobRuntimeTruth.unknownAfterRelaunch.rawValue
        {
            attributes["remoteBlocker"] = ""
        }
        if remoteJob.runtimeTruth != .unknownAfterRelaunch,
           existingItem?.attributes["remoteRuntimeTruth"]
            == ChatRemoteJobRuntimeTruth.unknownAfterRelaunch.rawValue
        {
            attributes["remoteColdStartOrphaned"] = ""
        }
        if remoteJob.isHidden {
            attributes["remoteProjectionHidden"] = "true"
        }
        for (key, value) in remoteJob.toolDetails {
            attributes["detail.\(key)"] = value
        }
        let phase = incomingPhase
        let source = ChatTranscriptSourceMetadataV1(
            source: "tatwo",
            model: "remote-loop",
            runtime: "tatwo-remote",
            runID: remoteJob.logicalKey,
            attempt: remoteJob.attempt)
        let evidence = attributes
            .filter { key, value in
                if key == "remoteProjectionProcessID"
                    || key == "remoteRuntimeTruth"
                    || key == "remoteColdStartOrphaned"
                {
                    return false
                }
                return !value.isEmpty
            }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\u{1E}")
        let projectionIdentity: String
        let sourceEventType: String
        switch remoteJob.identity {
        case .acceptedDispatch(let remoteJobID):
            projectionIdentity = "accepted:\(remoteJob.logicalKey):\(remoteJobID)"
            sourceEventType = "tatwo/remote-job/accepted-dispatch"
        case .observation:
            projectionIdentity = "observation:\(remoteJob.logicalKey):\(remoteJob.attempt)"
            sourceEventType = "tatwo/remote-job/projection-observation"
        }
        let eventID = stableID(
            prefix: "chat-remote-event",
            parts: [
                itemID,
                String(incomingRank),
                remoteJob.publicNarrative,
                evidence,
                projectionIdentity,
            ])
        if journal.event(id: eventID) != nil {
            // Process-local truth may legitimately differ after relaunch, but
            // replaying the same accepted/registry evidence must not reactivate
            // a row that cold-start reconciliation projected as unknown.
            return .ignored(.duplicateEvent(eventID: eventID))
        }
        let occurredAt: Date
        if case .acceptedDispatch = remoteJob.identity,
           let existing = journal.event(id: eventID)
        {
            // AcceptedAt is observation metadata, not receipt identity. Reuse
            // the first durable timestamp so a replay compares as a duplicate
            // while still rejecting any changed semantic evidence.
            occurredAt = existing.occurredAt
        } else {
            occurredAt = remoteJob.occurredAt
        }
        return appendStableEvent(
            eventID: eventID,
            itemID: itemID,
            kind: .remoteJob,
            phase: phase,
            title: "遠端工作",
            summary: remoteJob.publicNarrative,
            attributes: attributes,
            sourceEventType: sourceEventType,
            occurredAt: occurredAt,
            context: ChatTranscriptJournalContext(
                threadID: threadID,
                turnID: turnID,
                runID: remoteJob.logicalKey,
                source: source),
            to: &journal)
    }

    /// A local runner registry has no authority over remote execution. On
    /// relaunch, preserve accepted/running remote rows but remove their active
    /// claim until a fresh target-side observation arrives in this process.
    ///
    /// Terminal rows are intentionally excluded: their durable receipt/state
    /// remains latched and always wins over liveness uncertainty.
    @discardableResult
    static func markColdStartRemoteJobsUnknown(
        projectionProcessID: String = remoteProjectionProcessID,
        occurredAt: Date = Date(),
        in journal: inout ChatTranscriptJournalV1
    ) -> [ChatTranscriptAppendOutcomeV1] {
        let normalizedProcessID =
            normalizedNonEmpty(projectionProcessID) ?? remoteProjectionProcessID
        let staleItems = journal.threads
            .flatMap(\.turns)
            .flatMap(\.items)
            .filter { item in
                guard item.kind == .remoteJob,
                      !item.phase.isTerminal,
                      item.attributes["remoteProjectionProcessID"]
                        != normalizedProcessID,
                      normalizedNonEmpty(item.attributes["logicalDispatchID"]) != nil,
                      let state = item.attributes["remotePublicState"]
                        .flatMap(ChatRemoteJobPublicState.init(rawValue:))
                else {
                    return false
                }
                return state == .delivered || state == .started || state == .running
            }

        return staleItems.map { item in
            let lastKnownState = item.attributes["remotePublicState"] ?? ""
            var attributes = item.attributes
            attributes["remotePublicState"] = ""
            attributes["remoteTerminalOutcome"] = ""
            attributes["remoteRuntimeTruth"] =
                ChatRemoteJobRuntimeTruth.unknownAfterRelaunch.rawValue
            attributes["remoteProjectionProcessID"] = normalizedProcessID
            attributes["remoteColdStartOrphaned"] = "true"
            attributes["remoteBlocker"] =
                "App 重新啟動後尚未取得目標端權威存活或終止收據"
            attributes["detail.lastKnownPublicState"] = lastKnownState
            attributes["detail.runtimeTruth"] =
                ChatRemoteJobRuntimeTruth.unknownAfterRelaunch.rawValue
            let context = ChatTranscriptJournalContext(
                threadID: item.threadID,
                turnID: item.turnID,
                runID: item.source.runID ?? "remote-orphan:\(item.turnID)",
                source: item.source)
            return appendStableEvent(
                eventID: stableID(
                    prefix: "chat-remote-cold-start-unknown",
                    parts: [
                        item.threadID,
                        item.turnID,
                        item.id,
                        item.eventIDs.last ?? "",
                        normalizedProcessID,
                    ]),
                itemID: item.id,
                kind: .remoteJob,
                phase: .running,
                title: item.title,
                summary: "遠端工作狀態未知 · 等待目標端權威證據",
                attributes: attributes,
                sourceEventType: "tatwo/remote-job/cold-start-unknown",
                occurredAt: occurredAt,
                context: context,
                to: &journal)
        }
    }

    private static func remoteOccurredAtIdentity(_ date: Date) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(date))
            .map { String(decoding: $0, as: UTF8.self) }
            ?? String(date.timeIntervalSince1970 * 1_000)
    }

    /// One-time migration from the legacy message array. The role parser is a
    /// strict whitelist: unknown roles are reported to the caller and the
    /// document must not be scrubbed until every row is accepted.
    @discardableResult
    static func replay(
        storedMessages: [TatwoNativeChatStoredMessage],
        threadID: String,
        into journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptLegacyMigrationResult {
        var candidate = journal
        var outcomes: [ChatTranscriptAppendOutcomeV1] = []
        var rejectedMessageIDs: [String] = []
        for record in storedMessages {
            if [.session, .raw, .exit].contains(record.eventKind) {
                continue
            }
            guard let role = CanonicalRole(storedRole: record.role) else {
                rejectedMessageIDs.append(record.id)
                continue
            }
            let durableText = canonicalMessageText(
                record.text,
                role: role)
            if role == .user, durableText == nil {
                // A complete App-injected prompt row is transport context, not
                // a user message. Dropping it is a successful migration.
                continue
            }
            let message = ChatMessage(
                id: record.id,
                role: role.messageRole,
                text: durableText ?? record.text,
                status: record.status,
                modelID: record.modelID,
                eventKind: record.eventKind,
                runtimeAdapterID: record.runtimeAdapterID,
                runtimeFallbackReason: record.runtimeFallbackReason,
                createdAt: record.createdAt)
            let outcome = append(
                message: message,
                threadID: threadID,
                to: &candidate)
            outcomes.append(outcome)
            if case .ignored(let reason) = outcome {
                guard case .duplicateEvent = reason else {
                    rejectedMessageIDs.append(record.id)
                    continue
                }
            }
        }
        if rejectedMessageIDs.isEmpty {
            journal = candidate
        }
        return ChatTranscriptLegacyMigrationResult(
            outcomes: outcomes,
            rejectedMessageIDs: rejectedMessageIDs)
    }

    /// Reconnect/cold-start migration from already sealed in-memory rows.
    /// Stable message IDs make repeated selection and relaunch replay
    /// idempotent. All three visible roles are retained.
    @discardableResult
    static func replay(
        messages: [ChatMessage],
        threadID: String,
        fallbackSource: ChatTranscriptSourceMetadataV1,
        into journal: inout ChatTranscriptJournalV1
    ) -> [ChatTranscriptAppendOutcomeV1] {
        _ = fallbackSource
        return messages.compactMap { message -> ChatTranscriptAppendOutcomeV1? in
            guard CanonicalRole(message.role) != nil else { return nil }
            return append(message: message, threadID: threadID, to: &journal)
        }
    }

    @discardableResult
    static func append(
        message: ChatMessage,
        threadID: String,
        to journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptAppendOutcomeV1 {
        guard let role = CanonicalRole(message.role) else {
            return .ignored(.invalidIdentifier(field: "messageRole"))
        }
        if ChatPlanThoughtPresentation.isConfirmedPlanExecutionPrompt(message) {
            let source = ChatTranscriptSourceMetadataV1(
                source: "tatwo",
                model: "work-os",
                runtime: "tatwo-chat",
                runID: "confirmed-plan:\(message.id)")
            let context = ChatTranscriptJournalContext(
                threadID: threadID,
                turnID: message.id,
                runID: source.runID ?? "confirmed-plan:\(message.id)",
                source: source)
            // The full envelope remains available only to the active runner.
            // Durable history records one public folded state, never the Plan
            // body or App-authored execution instructions.
            return appendReasoningSummary(
                text: "已送交 Work OS",
                rawType: "tatwo/confirmed-plan/reasoning-summary",
                context: context,
                occurredAt: message.createdAt,
                to: &journal)
        }
        let source = messageSource(message, role: role)
        let context = ChatTranscriptJournalContext(
            threadID: threadID,
            turnID: message.id,
            runID: source.runID ?? "message:\(message.id)",
            source: source)
        guard let durableText = canonicalMessageText(
            message.text,
            role: role)
        else {
            return .ignored(.invalidIdentifier(field: "messageText"))
        }

        if role == .assistant {
            switch message.eventKind {
            case .message:
                return appendResult(
                    messageID: message.id,
                    text: durableText,
                    phase: persistedPhase(status: message.status),
                    occurredAt: message.createdAt,
                    runtimeFallbackReason: message.runtimeFallbackReason,
                    planQuestions: message.planQuestions,
                    context: context,
                    to: &journal)
            case .failure:
                return appendError(
                    message: durableText,
                    context: context,
                    occurredAt: message.createdAt,
                    runtimeFallbackReason: message.runtimeFallbackReason,
                    to: &journal)
            case .thinking:
                // Legacy thinking rows may contain private reasoning. Preserve
                // only the existence of a folded summary surface, never text.
                return appendReasoningSummary(
                    text: "",
                    rawType: "tatwo/legacy/reasoning-summary",
                    context: context,
                    occurredAt: message.createdAt,
                    to: &journal)
            case .toolUse:
                let activity = ChatActivityEventV1(
                    id: message.id,
                    kind: .toolUse,
                    label: "Tool",
                    detail: normalizedNonEmpty(durableText),
                    startedAt: message.createdAt,
                    endedAt: message.createdAt,
                    status: message.status?.lowercased().hasPrefix("failed") == true
                        ? .failed
                        : .succeeded,
                    turnID: message.id,
                    sourceType: "tatwo/legacy/tool")
                return append(activity: activity, context: context, to: &journal)
            case .session, .continuation, .raw, .exit:
                return .ignored(.invalidIdentifier(field: "messageEventKind"))
            }
        }

        guard message.eventKind == .message || message.eventKind == .failure else {
            return .ignored(.invalidIdentifier(field: "messageEventKind"))
        }
        let phase = persistedPhase(status: message.status)
        let itemID = stableID(
            prefix: "chat-item",
            parts: [threadID, message.id, "message", role.rawValue])
        if let existing = journal.item(
            threadID: threadID,
            turnID: message.id,
            itemID: itemID),
           existing.kind == .message,
           existing.phase == phase,
           existing.summary == normalizedNonEmpty(durableText),
           existing.attributes["role"] == role.rawValue,
           existing.attributes["eventKind"] == message.eventKind.rawValue,
           existing.attributes["status"] == (message.status ?? ""),
           existing.attributes["runtimeFallbackReason"]
                == (message.runtimeFallbackReason?.rawValue ?? ""),
           let existingEventID = existing.eventIDs.last
        {
            // Sanitizer migrations preserve historical event IDs. A later
            // mirror replay of the same clean logical message must therefore
            // resolve as an idempotent duplicate even though old IDs may have
            // been derived from the pre-sanitized transport text.
            return .ignored(.duplicateEvent(eventID: existingEventID))
        }
        let attributes = [
            "messageID": message.id,
            "role": role.rawValue,
            "eventKind": message.eventKind.rawValue,
            "status": message.status ?? "",
            "runtimeFallbackReason":
                message.runtimeFallbackReason?.rawValue ?? "",
        ]
        return appendStableEvent(
            eventID: stableID(
                prefix: "chat-event",
                parts: [
                    itemID,
                    phase.rawValue,
                    durableText,
                    message.status ?? "",
                    message.runtimeFallbackReason?.rawValue ?? "",
                ]),
            itemID: itemID,
            kind: .message,
            phase: phase,
            title: role == .user ? "User message" : "System message",
            summary: normalizedNonEmpty(durableText),
            attributes: attributes,
            sourceEventType: "tatwo/chat/message",
            occurredAt: message.createdAt,
            context: context,
            to: &journal)
    }

    private static func canonicalMessageText(
        _ text: String,
        role: CanonicalRole
    ) -> String? {
        guard role == .user else {
            return text
        }
        let cleaned = TatwoChatTranscriptPresentation.cleanedTranscriptSource(
            text,
            role: .user)
        guard !cleaned.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return cleaned
    }

    static func projectedMessages(
        threadID: String,
        from journal: ChatTranscriptJournalV1
    ) -> [ChatMessage] {
        let items = journal.orderedItems(threadID: threadID)
        let itemsByID = Dictionary(grouping: items, by: \.id)
        let projectionItems = items.filter { item in
            if isLegacyToolUseProjection(item),
                legacyToolProjectionIsShadowed(
                    item,
                    itemsByID: itemsByID)
            {
                return false
            }
            return true
        }
        let foldedItemsByTurnID = Dictionary(
            grouping: projectionItems.filter(isFoldedWorkItem),
            by: \.turnID)
        var projectedWorkTurnIDs = Set<String>()
        let rows = projectionItems.compactMap { item -> ChatMessage? in
            guard isFoldedWorkItem(item) else {
                return projectedMessage(item)
            }
            guard projectedWorkTurnIDs.insert(item.turnID).inserted else {
                return nil
            }
            return projectedWorkSummary(
                foldedItemsByTurnID[item.turnID] ?? [item])
        }
        return limitingPlanQuestionsToNewestRow(rows)
    }

    private static func isFoldedWorkItem(
        _ item: ChatTranscriptItemV1
    ) -> Bool {
        switch item.kind {
        case .reasoningSummary, .command, .fileChange, .search, .tool:
            true
        case .message, .result, .error, .approval, .remoteJob:
            false
        }
    }

    private static func projectedWorkSummary(
        _ items: [ChatTranscriptItemV1]
    ) -> ChatMessage? {
        guard let first = items.first else { return nil }
        var confirmedPlanDetail: String?
        for item in items where
            item.kind == .reasoningSummary
                && item.source.runID?.hasPrefix("confirmed-plan:") == true
        {
            confirmedPlanDetail = item.summary
            break
        }
        let status: String
        if items.contains(where: { $0.phase == .failed }) {
            status = "failed|工作步驟失敗"
        } else if items.contains(where: {
            $0.phase == .pending || $0.phase == .running
        }) {
            status = "thinking|思考中"
        } else if items.contains(where: { $0.phase == .cancelled }) {
            status = "stopped|已停止"
        } else {
            status = "completed|\(confirmedPlanDetail ?? "思考中")"
        }
        return ChatMessage(
            id: "journal-work:\(first.threadID):\(first.turnID)",
            role: .assistant,
            text: "",
            status: status,
            modelID: first.source.model,
            eventKind: .thinking,
            runtimeAdapterID: first.source.runtime,
            turnID: first.turnID,
            createdAt: items.map(\.createdAt).min() ?? first.createdAt)
    }

    /// A clarification request is answerable only while it is the newest row in
    /// its thread. Journal items are terminal once completed, so a consumed
    /// question set can never be erased in place; instead any later journaled
    /// turn proves the answer is already in flight and demotes the older
    /// question set to inert history.
    private static func limitingPlanQuestionsToNewestRow(
        _ rows: [ChatMessage]
    ) -> [ChatMessage] {
        guard let newestIndex = rows.indices.last else { return rows }
        return rows.enumerated().map { index, row in
            guard index != newestIndex, !row.planQuestions.isEmpty else {
                return row
            }
            var stripped = row
            stripped.planQuestions = []
            return stripped
        }
    }

    private static func isLegacyToolUseProjection(
        _ item: ChatTranscriptItemV1
    ) -> Bool {
        item.kind == .tool
            && item.attributes["sourceType"] == "tatwo/legacy/tool"
    }

    private static func legacyToolProjectionIsShadowed(
        _ item: ChatTranscriptItemV1,
        itemsByID: [String: [ChatTranscriptItemV1]]
    ) -> Bool {
        var pending = legacyProjectionParentIDs(for: item)
        var visited = Set([item.id])
        while let parentID = pending.popLast() {
            guard visited.insert(parentID).inserted else {
                continue
            }
            for parent in itemsByID[parentID] ?? [] {
                if parent.attributes["activityID"] != nil,
                   !isLegacyToolUseProjection(parent)
                {
                    return true
                }
                guard isLegacyToolUseProjection(parent) else {
                    continue
                }
                pending.append(contentsOf: legacyProjectionParentIDs(for: parent))
            }
        }
        return false
    }

    private static func legacyProjectionParentIDs(
        for item: ChatTranscriptItemV1
    ) -> [String] {
        [item.attributes["activityID"], item.turnID]
            .compactMap(normalizedNonEmpty)
    }

    static func mergingCanonicalProjection(
        _ canonical: [ChatMessage],
        withLegacy records: [TatwoNativeChatStoredMessage]
    ) -> [ChatMessage] {
        let legacy = records.map(ChatMessage.init(stored:))
        let legacyIDs = Set(legacy.map(\.id))
        return (legacy + canonical.filter { !legacyIDs.contains($0.id) }).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id < $1.id
        }
    }

    /// Seals journal rows that claimed to be in flight before this process
    /// started but have no matching live runner. Stable IDs and timestamps make
    /// repeated cold starts idempotent.
    @discardableResult
    static func cancelColdStartOrphans(
        activeRunIDs: Set<String>,
        reclaimTokens: Set<ChatRunnerReclaimToken>,
        in journal: inout ChatTranscriptJournalV1
    ) -> [ChatTranscriptAppendOutcomeV1] {
        var candidate = journal
        var outcomes: [ChatTranscriptAppendOutcomeV1] = []
        let orphanItems = journal.threads
            .flatMap(\.turns)
            .flatMap(\.items)
            .filter { item in
                guard item.kind != .remoteJob, !item.phase.isTerminal else {
                    return false
                }
                guard let runID = item.source.runID,
                      !activeRunIDs.contains(runID)
                else {
                    return false
                }
                return reclaimTokens.contains { token in
                    token.runID == runID
                        && token.attempt == item.source.attempt
                        && token.instanceID == item.source.runnerInstanceID
                        && token.revision == item.source.runnerRevision
                }
            }

        for item in orphanItems {
            let context = ChatTranscriptJournalContext(
                threadID: item.threadID,
                turnID: item.turnID,
                runID: item.source.runID ?? "orphan:\(item.turnID)",
                source: item.source)
            var attributes = item.attributes
            attributes["coldStartOrphan"] = "true"
            if attributes["status"] != nil {
                attributes["status"] = ""
            }
            let outcome = appendStableEvent(
                eventID: stableID(
                    prefix: "chat-event-orphan-cancel",
                    parts: [item.threadID, item.turnID, item.id]),
                itemID: item.id,
                kind: item.kind,
                phase: .cancelled,
                title: item.title,
                summary: item.summary,
                attributes: attributes,
                sourceEventType: "tatwo/chat/cold-start-orphan",
                occurredAt: item.updatedAt,
                context: context,
                to: &candidate)
            outcomes.append(outcome)
        }

        if outcomes.allSatisfy(isSuccessfulReplayOutcome) {
            journal = candidate
        }
        return outcomes
    }

    static func removingLegacyTranscriptPayloads(
        from document: TatwoNativeChatStoreDocument
    ) -> TatwoNativeChatStoreDocument {
        var scrubbed = document
        for index in scrubbed.threads.indices {
            scrubbed.threads[index].messages = nil
            for discussionIndex in scrubbed.threads[index].discussions.indices {
                scrubbed.threads[index].discussions[discussionIndex].messages = []
            }
        }
        for projectIndex in scrubbed.projects.indices {
            for threadIndex in scrubbed.projects[projectIndex].threads.indices {
                scrubbed.projects[projectIndex].threads[threadIndex].messages = nil
                for discussionIndex in
                    scrubbed.projects[projectIndex].threads[threadIndex].discussions.indices
                {
                    scrubbed.projects[projectIndex].threads[threadIndex]
                        .discussions[discussionIndex].messages = []
                }
            }
        }
        return scrubbed
    }

    private static func appendStableEvent(
        eventID: String,
        itemID: String,
        kind: ChatTranscriptItemKindV1,
        phase: ChatTranscriptLifecyclePhaseV1,
        title: String,
        summary: String?,
        attributes: [String: String],
        sourceEventType: String?,
        occurredAt: Date,
        context: ChatTranscriptJournalContext,
        to journal: inout ChatTranscriptJournalV1
    ) -> ChatTranscriptAppendOutcomeV1 {
        let existing = journal.event(id: eventID)
        let event = ChatTranscriptEventV1(
            eventID: eventID,
            threadID: context.threadID,
            turnID: context.turnID,
            itemID: itemID,
            sequence: existing?.sequence
                ?? nextSequence(
                    threadID: context.threadID,
                    turnID: context.turnID,
                    in: journal),
            kind: kind,
            phase: phase,
            source: context.source,
            sourceEventType: sourceEventType,
            occurredAt: occurredAt,
            title: title,
            summary: summary,
            attributes: attributes)
        return journal.append(event)
    }

    private static func nextSequence(
        threadID: String,
        turnID: String,
        in journal: ChatTranscriptJournalV1
    ) -> UInt64 {
        let last = journal.turn(threadID: threadID, turnID: turnID)?
            .items
            .map(\.lastSequence)
            .max() ?? 0
        return last == UInt64.max ? UInt64.max : last + 1
    }

    private static func itemKind(
        for kind: ChatActivityKindV1
    ) -> ChatTranscriptItemKindV1 {
        switch kind {
        case .command:
            .command
        case .fileEdit:
            .fileChange
        case .search:
            .search
        case .thinking:
            .reasoningSummary
        case .fileRead, .webFetch, .toolUse, .mcp, .unknown:
            .tool
        }
    }

    private static func activityAttributes(
        _ activity: ChatActivityEventV1
    ) -> [String: String] {
        var attributes = [
            "activityID": activity.id,
            "attempt": String(activity.attempt),
        ]
        if let sourceType = normalizedNonEmpty(activity.sourceType) {
            attributes["sourceType"] = sourceType
        }
        return attributes
    }

    private static func safeReasoningSummary(
        text: String,
        rawType: String?,
        maximumBytes: Int = 256 * 1_024
    ) -> String? {
        _ = text
        let loweredType = rawType?.lowercased() ?? ""
        let isNormalizedThinking = loweredType.contains("thinking")
            || loweredType.contains("reasoning")
            || loweredType.contains("thought")
            || loweredType.contains("summary")
        guard isNormalizedThinking else { return nil }
        // Never derive durable content from provider reasoning text, even
        // after redaction or truncation. Preserve only a bounded structural
        // state required to render one collapsible thinking timeline.
        let structuralSummary =
            loweredType == "tatwo/confirmed-plan/reasoning-summary"
            ? "已送交 Work OS"
            : "思考中"
        guard structuralSummary.utf8.count <= maximumBytes else { return nil }
        return structuralSummary
    }

    private static func persistedPhase(
        status: String?
    ) -> ChatTranscriptLifecyclePhaseV1 {
        let normalized = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalized.hasPrefix("queued") || normalized.hasPrefix("pending") {
            return .pending
        }
        if normalized.hasPrefix("stream")
            || normalized.hasPrefix("thinking")
            || normalized.hasPrefix("working")
            || normalized.hasPrefix("checking")
        {
            return .running
        }
        if normalized.hasPrefix("failed") || normalized.hasPrefix("error") {
            return .failed
        }
        if normalized.hasPrefix("stopped") || normalized.hasPrefix("cancelled") {
            return .cancelled
        }
        return .completed
    }

    private static func messageSource(
        _ message: ChatMessage,
        role: CanonicalRole
    ) -> ChatTranscriptSourceMetadataV1 {
        switch role {
        case .user:
            return ChatTranscriptSourceMetadataV1(
                source: "human",
                model: "user",
                runtime: "tatwo-chat",
                runID: "message:\(message.id)")
        case .system:
            return ChatTranscriptSourceMetadataV1(
                source: "tatwo",
                model: "work-os",
                runtime: "tatwo-chat",
                runID: "message:\(message.id)")
        case .assistant:
            let model = normalizedNonEmpty(message.modelID) ?? "assistant"
            return ChatTranscriptSourceMetadataV1(
                source: provenanceProviderID(modelID: model),
                model: model,
                runtime: normalizedNonEmpty(message.runtimeAdapterID) ?? "tatwo-chat",
                runID: "message:\(message.id)")
        }
    }

    private static func projectedMessage(
        _ item: ChatTranscriptItemV1
    ) -> ChatMessage? {
        let role: ChatMessageRole
        let eventKind: TatwoNativeChatEventKind
        let text: String
        let status: String?

        switch item.kind {
        case .message:
            guard
                let rawRole = item.attributes["role"],
                let canonicalRole = CanonicalRole(storedRole: rawRole),
                let rawEventKind = item.attributes["eventKind"],
                let storedEventKind = TatwoNativeChatEventKind(rawValue: rawEventKind),
                storedEventKind == .message || storedEventKind == .failure
            else { return nil }
            role = canonicalRole.messageRole
            eventKind = storedEventKind
            text = item.summary ?? ""
            status = normalizedNonEmpty(item.attributes["status"])
                ?? lifecycleStatus(item.phase)
        case .result:
            role = .assistant
            eventKind = item.phase == .failed ? .failure : .message
            text = item.summary ?? ""
            status = lifecycleStatus(item.phase)
        case .error:
            role = .assistant
            eventKind = .failure
            text = item.summary ?? item.title
            status = "failed"
        case .reasoningSummary:
            role = .assistant
            eventKind = .thinking
            if let summary = item.summary {
                text = summary
                status = switch item.phase {
                case .pending: "pending|\(summary)"
                case .running: "thinking|\(summary)"
                case .completed: "completed|\(summary)"
                case .failed: "failed|\(summary)"
                case .cancelled: "stopped|\(summary)"
                }
            } else {
                guard !item.phase.isTerminal else { return nil }
                text = ""
                status = "thinking"
            }
        case .remoteJob:
            guard item.attributes["remoteProjectionHidden"] != "true" else {
                return nil
            }
            role = .assistant
            eventKind = .toolUse
            text = item.summary ?? item.title
            let details: [String: String] = Dictionary(
                uniqueKeysWithValues: item.attributes.compactMap { key, value -> (String, String)? in
                    guard key.hasPrefix("detail.") else { return nil }
                    return (String(key.dropFirst("detail.".count)), value)
                })
            status = ChatRemoteJobInlinePresentation.status(
                state: item.attributes["remotePublicState"]
                    .flatMap(ChatRemoteJobPublicState.init(rawValue:)),
                terminalOutcome: item.attributes["remoteTerminalOutcome"]
                    .flatMap(ChatRemoteJobTerminalOutcome.init(rawValue:)),
                runtimeTruth: item.attributes["remoteRuntimeTruth"]
                    .flatMap(ChatRemoteJobRuntimeTruth.init(rawValue:)),
                blocker: normalizedNonEmpty(item.attributes["remoteBlocker"]),
                details: details)
        case .command, .fileChange, .search, .tool, .approval:
            role = .assistant
            eventKind = .toolUse
            text = item.summary ?? item.title
            status = activityStatus(item)
        }

        return ChatMessage(
            id: item.attributes["messageID"] ?? item.id,
            role: role,
            text: text,
            status: status,
            modelID: role == .assistant ? item.source.model : nil,
            eventKind: eventKind,
            runtimeAdapterID: role == .assistant ? item.source.runtime : nil,
            runtimeFallbackReason: item.attributes["runtimeFallbackReason"]
                .flatMap(TatwoChatRuntimeFallbackReason.init(rawValue:)),
            turnID: item.turnID,
            planQuestions: TatwoPlanQuestionJournalCodec.decode(
                item.attributes[TatwoPlanQuestionJournalCodec.attributeKey]),
            createdAt: item.createdAt)
    }

    private static func lifecycleStatus(
        _ phase: ChatTranscriptLifecyclePhaseV1
    ) -> String? {
        switch phase {
        case .pending: "pending"
        case .running: "streaming"
        case .completed: nil
        case .failed: "failed"
        case .cancelled: "stopped"
        }
    }

    private static func activityStatus(
        _ item: ChatTranscriptItemV1
    ) -> String? {
        let detail = item.summary ?? item.title
        return switch item.phase {
        case .pending: "pending|\(detail)"
        case .running: "working|\(detail)"
        case .completed: "completed|\(detail)"
        case .failed: "failed|\(detail)"
        case .cancelled: "stopped|\(detail)"
        }
    }

    private static func providerID(for route: ChatRouteChoice) -> String {
        providerID(modelID: [
            route.id,
            route.family,
            route.canonicalModelSlug,
            route.modelArgument ?? "",
        ].joined(separator: " ")) ?? {
            switch route.engine {
            case .codex: "codex"
            case .claude: "claude"
            }
        }()
    }

    private static func providerID(modelID: String?) -> String? {
        let normalized = modelID?.lowercased() ?? ""
        if normalized.contains("grok") { return "grok" }
        if normalized.contains("fable") { return "fable" }
        if normalized.contains("claude")
            || normalized.contains("sonnet")
            || normalized.contains("opus")
            || normalized.contains("haiku")
        {
            return "claude"
        }
        if normalized.contains("codex")
            || normalized.contains("gpt")
            || normalized.contains("openai")
        {
            return "codex"
        }
        return nil
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSuccessfulReplayOutcome(
        _ outcome: ChatTranscriptAppendOutcomeV1
    ) -> Bool {
        if outcome.wasAppended { return true }
        if case .ignored(.duplicateEvent) = outcome { return true }
        return false
    }

    private static func stableID(prefix: String, parts: [String]) -> String {
        let material = parts.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }
}

@MainActor
extension ChatPageModel {
    private static var lastProjectedThreadByStoreURL: [URL: String] = [:]

    private var selectedRemoteThreadReference: TatwoNativeChatSessionReference? {
        guard let selectedThreadID else { return nil }
        return TatwoNativeChatSessionReference(kind: .thread, id: selectedThreadID)
    }

    @discardableResult
    func armPendingRemoteTarget(
        grant: TatwoRemoteSessionGrantV1,
        goalID: String,
        targetDisplayName: String,
        now: Date = Date()
    ) async -> ChatPendingRemoteTargetV1? {
        let store = pendingRemoteTargetStore
        let reference = selectedRemoteThreadReference
        let target: ChatPendingRemoteTargetV1? = await Task.detached(
            priority: .userInitiated
        ) { () -> ChatPendingRemoteTargetV1? in
            do {
                return try store.arm(
                    grant: grant,
                    goalID: goalID,
                    targetDisplayName: targetDisplayName,
                    now: now)
            } catch {
                return nil
            }
        }.value
        if let target, let reference {
            reconcileSyntheticRemoteBorrowBlocker(
                target: target,
                reference: reference,
                occurredAt: now)
        }
        return target
    }

    func invalidatePendingRemoteTargetForSelectedSession() {
        guard let sessionID = selectedRemoteBorrowSessionID else { return }
        let store = pendingRemoteTargetStore
        Task.detached(priority: .utility) {
            _ = try? store.invalidate(sessionID: sessionID)
        }
    }

    func revalidatePendingRemoteTarget(
        verifiedTargetDeviceIDs: Set<String>?,
        definitiveLeaseLossBlocker: String?
    ) {
        guard let sessionID = selectedRemoteBorrowSessionID else { return }
        let store = pendingRemoteTargetStore
        Task { [weak self] in
            let invalidations = await Task.detached(priority: .utility) {
                guard let pendingTargets = try? store.pendingTargets(
                    sessionID: sessionID)
                else {
                    return [(ChatPendingRemoteTargetV1, String)]()
                }
                return pendingTargets.compactMap { pending in
                    let blocker: String?
                    if let verifiedTargetDeviceIDs,
                       !verifiedTargetDeviceIDs.contains(pending.targetDeviceID)
                    {
                        blocker = ChatRemoteTurnDispatchBlocker.targetTrustLost.rawValue
                    } else {
                        blocker = definitiveLeaseLossBlocker
                    }
                    guard let blocker,
                          (try? store.invalidate(
                              sessionID: sessionID,
                              targetDeviceID: pending.targetDeviceID)) == true
                    else {
                        return nil
                    }
                    return (pending, blocker)
                }
            }.value
            guard let self,
                  self.selectedRemoteBorrowSessionID == sessionID
            else { return }
            for (pending, blocker) in invalidations {
                _ = self.recordPendingRemoteTargetBlocker(
                    target: pending,
                    blocker: blocker)
            }
        }
    }

    func recordSelectedDispatchRemoteJobs(
        _ records: [TatwoDispatchRecord]
    ) {
        guard chatTranscriptJournalPersistenceAllowed,
              let reference = selectedRemoteThreadReference
        else { return }
        let projections = ChatRemoteJobReducer.project(records)
        guard !projections.isEmpty else { return }
        let previous = selectedDispatchPersistenceTask
        let store = chatTranscriptJournalStore
        selectedDispatchPersistenceTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self,
                  self.chatTranscriptJournalPersistenceAllowed
            else { return }
            var observedRevision = self.chatTranscriptJournalRevision
            let projectionProcessID = self.remoteProjectionProcessID
            let persistenceResult = await Task.detached(priority: .utility) {
                try? store.mergeRemoteJobProjections(
                    projections,
                    threadID: reference.stableKey,
                    projectionProcessID: projectionProcessID)
            }.value
            guard var persisted = persistenceResult else { return }

            while self.chatTranscriptJournalRevision != observedRevision {
                observedRevision = self.chatTranscriptJournalRevision
                let loadResult = await Task.detached(priority: .utility) {
                    try? store.load()
                }.value
                guard let latest = loadResult else { return }
                persisted = latest
            }

            self.replaceChatTranscriptJournal(persisted)
            if self.selectedSessionReference == reference {
                self.refreshSelectedTranscriptProjection(from: persisted)
            }
        }
    }

    @discardableResult
    func recordRemoteBorrowBlocker(
        targetDisplayName: String,
        targetDeviceID: String,
        blocker: String,
        occurredAt: Date = Date()
    ) -> Bool {
        guard chatTranscriptJournalPersistenceAllowed,
              let reference = selectedRemoteThreadReference,
              let sessionID = selectedRemoteBorrowSessionID,
              let contractID = selectedThread?.workOSContractID,
              let goalID = selectedThread?.workOSGoalID
        else { return false }
        let logicalKey = [
            "borrow",
            sessionID,
            contractID,
            targetDeviceID,
        ].joined(separator: ":")
        return persistRemoteJobProjections(
            [
                ChatRemoteJobReducer.waitingForTargetBinding(
                    logicalKey: logicalKey,
                    targetDisplayName: targetDisplayName,
                    targetDeviceID: targetDeviceID,
                    contractID: contractID,
                    goalID: goalID,
                    blocker: blocker,
                    occurredAt: occurredAt),
            ],
            reference: reference)
    }

    @discardableResult
    func recordPendingRemoteTargetBlocker(
        target: ChatPendingRemoteTargetV1,
        blocker: String,
        occurredAt: Date = Date()
    ) -> Bool {
        guard chatTranscriptJournalPersistenceAllowed,
              let reference = selectedRemoteThreadReference
        else { return false }
        return persistRemoteJobProjections(
            [
                ChatRemoteJobReducer.waitingForTargetBinding(
                    logicalKey: target.logicalJobID,
                    targetDisplayName: target.targetDisplayName,
                    targetDeviceID: target.targetDeviceID,
                    contractID: target.contractID,
                    goalID: target.goalID,
                    blocker: blocker,
                    occurredAt: occurredAt),
            ],
            reference: reference)
    }

    private func reconcileSyntheticRemoteBorrowBlocker(
        target: ChatPendingRemoteTargetV1,
        reference: TatwoNativeChatSessionReference,
        occurredAt: Date
    ) {
        guard chatTranscriptJournalPersistenceAllowed else { return }
        let syntheticLogicalKey = [
            "borrow",
            target.sessionID,
            target.contractID,
            target.targetDeviceID,
        ].joined(separator: ":")
        guard chatTranscriptJournal
            .orderedItems(threadID: reference.stableKey)
            .contains(where: {
                $0.kind == .remoteJob
                    && $0.attributes["logicalDispatchID"] == syntheticLogicalKey
                    && $0.attributes["remoteProjectionHidden"] != "true"
            })
        else { return }
        _ = persistRemoteJobProjections(
            [
                ChatRemoteJobReducer.supersededWaitingForTargetBinding(
                    logicalKey: syntheticLogicalKey,
                    occurredAt: occurredAt),
            ],
            reference: reference)
    }

    @discardableResult
    func recordAcceptedRemoteDispatch(
        target: ChatPendingRemoteTargetV1,
        acceptance: ChatRemoteTurnDispatchAcceptance
    ) -> Bool {
        guard chatTranscriptJournalPersistenceAllowed,
              let reference = selectedRemoteThreadReference
        else { return false }
        let attempt = acceptedRemoteDispatchAttempt(
            target: target,
            acceptance: acceptance,
            reference: reference)
        return persistRemoteJobProjections(
            [
                ChatRemoteJobReducer.acceptedRemoteDispatch(
                    target: target,
                    acceptance: acceptance,
                    attempt: attempt),
            ],
            reference: reference)
    }

    private func acceptedRemoteDispatchAttempt(
        target: ChatPendingRemoteTargetV1,
        acceptance: ChatRemoteTurnDispatchAcceptance,
        reference: TatwoNativeChatSessionReference
    ) -> UInt64 {
        guard let current = chatTranscriptJournal
            .orderedItems(threadID: reference.stableKey)
            .first(where: {
                $0.kind == .remoteJob
                    && $0.attributes["logicalDispatchID"] == target.logicalJobID
            })
        else {
            return 1
        }
        let currentAttempt = max(current.source.attempt ?? 1, 1)
        if current.phase == .completed
            || current.attributes["remotePublicState"]
                == ChatRemoteJobPublicState.completed.rawValue
            || current.attributes["remotePublicState"]
                == ChatRemoteJobPublicState.verified.rawValue
        {
            return currentAttempt
        }
        let currentJobIDs = Set(
            (current.attributes["detail.jobID"] ?? "")
                .split(separator: ",")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty })
        guard !currentJobIDs.isEmpty,
              !currentJobIDs.contains(acceptance.remoteJobID)
        else {
            return currentAttempt
        }
        return currentAttempt == UInt64.max
            ? UInt64.max
            : currentAttempt + 1
    }

    @discardableResult
    private func persistRemoteJobProjections(
        _ projections: [ChatRemoteJobProjection],
        reference: TatwoNativeChatSessionReference
    ) -> Bool {
        var journal = chatTranscriptJournal
        let outcomes = projections.map {
            ChatTranscriptJournalAdapter.append(
                remoteJob: $0,
                threadID: reference.stableKey,
                projectionProcessID: remoteProjectionProcessID,
                to: &journal)
        }
        guard outcomes.allSatisfy(Self.isAcceptedRemoteJobReplayOutcome) else {
            return false
        }
        do {
            if outcomes.contains(where: \.wasAppended) {
                journal = try chatTranscriptJournalStore.saveMerging(journal)
                replaceChatTranscriptJournal(journal)
            }
            if selectedSessionReference == reference {
                refreshSelectedTranscriptProjection(from: journal)
            }
            return true
        } catch {
            return false
        }
    }

    static func isAcceptedRemoteJobReplayOutcome(
        _ outcome: ChatTranscriptAppendOutcomeV1
    ) -> Bool {
        if outcome.wasAppended { return true }
        switch outcome {
        case .ignored(.duplicateEvent),
             .ignored(.lifecycleRegression),
             .ignored(.staleAttempt),
             .ignored(.terminalItem):
            return true
        case .appended, .ignored:
            return false
        }
    }

    @discardableResult
    func recordTranscriptActivity(
        _ activity: ChatActivityEventV1,
        runID: String
    ) -> Bool {
        guard let context = transcriptJournalContext(
            turnID: activity.turnID,
            runID: runID,
            attempt: UInt64(activity.attempt))
        else { return false }
        return mutateTranscriptJournal(persist: .coalesced) {
            ChatTranscriptJournalAdapter.append(
                activity: activity,
                context: context,
                to: &$0)
        }
    }

    func recordTranscriptReasoning(
        _ activity: ChatCLIActivity,
        runID: String
    ) {
        guard let turnID = activeAssistantID,
              let context = transcriptJournalContext(turnID: turnID, runID: runID)
        else { return }
        mutateTranscriptJournal(persist: .coalesced) {
            ChatTranscriptJournalAdapter.appendReasoningSummary(
                text: activity.text,
                rawType: activity.rawType,
                context: context,
                to: &$0)
        }
    }

    func recordTranscriptResult(
        assistantID: String,
        runID: String,
        phase: ChatTranscriptLifecyclePhaseV1
    ) {
        flushCoalescedTranscriptJournal()
        guard let context = transcriptJournalContext(
            turnID: assistantID,
            runID: runID)
        else { return }
        guard let message = messages.first(where: { $0.id == assistantID }) else {
            return
        }
        mutateTranscriptJournal {
            ChatTranscriptJournalAdapter.appendResult(
                messageID: assistantID,
                text: message.text,
                phase: phase,
                occurredAt: message.createdAt,
                context: context,
                to: &$0)
        }
    }

    func recordTranscriptError(
        _ message: String,
        assistantID: String,
        runID: String
    ) {
        flushCoalescedTranscriptJournal()
        guard let context = transcriptJournalContext(
            turnID: assistantID,
            runID: runID)
        else { return }
        mutateTranscriptJournal {
            ChatTranscriptJournalAdapter.appendError(
                message: message,
                context: context,
                to: &$0)
        }
    }

    @discardableResult
    func recordCanonicalMessage(_ message: ChatMessage) -> Bool {
        guard let reference =
                transcriptMutationReference ?? selectedSessionReference
        else { return false }
        return mutateTranscriptJournal {
            ChatTranscriptJournalAdapter.append(
                message: message,
                threadID: reference.stableKey,
                to: &$0)
        }
    }

    /// Terminal transcript rows are published only through this durable gate.
    /// Callers must not mutate `messages` to the terminal candidate first.
    @discardableResult
    func commitTranscriptTerminalMessage(_ message: ChatMessage) -> Bool {
        recordCanonicalMessage(message)
    }

    func recordCanonicalStoredMessages(
        _ records: [TatwoNativeChatStoredMessage],
        reference: TatwoNativeChatSessionReference
    ) -> Bool {
        guard chatTranscriptJournalPersistenceAllowed else { return false }
        var journal = chatTranscriptJournal
        let migration = ChatTranscriptJournalAdapter.replay(
            storedMessages: records,
            threadID: reference.stableKey,
            into: &journal)
        guard migration.isComplete else { return false }
        do {
            if migration.appendedCount > 0 {
                journal = try chatTranscriptJournalStore.saveMerging(journal)
                replaceChatTranscriptJournal(journal)
            }
            materializeCanonicalTranscript(
                reference: reference,
                from: journal)
            return true
        } catch {
            return false
        }
    }

    /// Migrates every legacy thread/discussion transcript before metadata
    /// persistence is allowed to scrub those duplicate payloads. Any unknown
    /// role or journal save failure leaves the legacy document untouched.
    func migrateLegacyDocumentTranscriptsIfNeeded() {
        guard chatTranscriptJournalPersistenceAllowed else { return }
        var journal = chatTranscriptJournal
        var rejectedMessageIDs: [String] = []
        var appendedCount = 0

        func migrate(
            _ records: [TatwoNativeChatStoredMessage],
            reference: TatwoNativeChatSessionReference
        ) {
            let result = ChatTranscriptJournalAdapter.replay(
                storedMessages: records,
                threadID: reference.stableKey,
                into: &journal)
            appendedCount += result.appendedCount
            rejectedMessageIDs.append(contentsOf: result.rejectedMessageIDs)
        }

        for thread in document.threads {
            migrate(
                thread.messages ?? [],
                reference: TatwoNativeChatSessionReference(kind: .thread, id: thread.id))
            for discussion in thread.discussions {
                migrate(
                    discussion.messages,
                    reference: TatwoNativeChatSessionReference(
                        kind: .discussion,
                        id: discussion.id))
            }
        }
        for project in document.projects {
            for thread in project.threads {
                migrate(
                    thread.messages ?? [],
                    reference: TatwoNativeChatSessionReference(kind: .thread, id: thread.id))
                for discussion in thread.discussions {
                    migrate(
                        discussion.messages,
                        reference: TatwoNativeChatSessionReference(
                            kind: .discussion,
                            id: discussion.id))
                }
            }
        }

        guard rejectedMessageIDs.isEmpty else {
            legacyTranscriptMigrationCompleted = false
            fputs(
                "tatwo_chat_transcript_migration_blocked=invalid_roles count=\(rejectedMessageIDs.count)\n",
                stderr)
            return
        }
        do {
            if appendedCount > 0 {
                journal = try chatTranscriptJournalStore.saveMerging(journal)
            }
            replaceChatTranscriptJournal(journal)
            legacyTranscriptMigrationCompleted = true
            // `persistStore` derives a scrubbed copy without mutating
            // `document`. Do not materialize the canonical compatibility
            // projection until that native commit succeeds: on failure the
            // exact legacy inline payload must remain available to every
            // later unrelated save.
            guard persistStore() else {
                legacyTranscriptMigrationCompleted = false
                return
            }
            materializeAllCanonicalTranscripts()
        } catch {
            legacyTranscriptMigrationCompleted = false
        }
    }

    func replaySelectedTranscriptMessages() {
        guard chatTranscriptJournalPersistenceAllowed else { return }
        guard let reference = selectedSessionReference else { return }
        var journal = chatTranscriptJournal
        let source = ChatTranscriptJournalAdapter.sourceMetadata(
            route: routeChoice,
            runID: "reconnect:\(reference.stableKey)")
        let outcomes = ChatTranscriptJournalAdapter.replay(
            messages: messages,
            threadID: reference.stableKey,
            fallbackSource: source,
            into: &journal)
        guard outcomes.allSatisfy({ outcome in
            if outcome.wasAppended { return true }
            if case .ignored(.duplicateEvent) = outcome { return true }
            return false
        }) else {
            return
        }
        do {
            if outcomes.contains(where: \.wasAppended) {
                journal = try chatTranscriptJournalStore.saveMerging(journal)
                replaceChatTranscriptJournal(journal)
            }
            refreshSelectedTranscriptProjection(from: journal)
        } catch {
            return
        }
    }

    private func transcriptJournalContext(
        turnID: String,
        runID: String,
        attempt: UInt64? = nil
    ) -> ChatTranscriptJournalContext? {
        guard let reference =
                transcriptMutationReference ?? selectedSessionReference
        else { return nil }
        let runnerIdentity = activeRunnerJournalIdentity?.runID == runID
            ? activeRunnerJournalIdentity
            : nil
        // `routeChoice` is the live model picker and may already point at a
        // different route than the one that actually spawned this run (a
        // topology mutation, a `下一輪` pending route, an executor
        // realignment). Command/activity events must be stamped from the
        // turn's frozen provenance instead, or one run's transcript splits
        // across two model identities.
        let source: ChatTranscriptSourceMetadataV1
        if let provenance = activeTurnExecutionProvenance,
           provenance.matches(runID: runID)
        {
            source = ChatTranscriptJournalAdapter.sourceMetadata(
                provenance: provenance,
                runID: runID,
                attempt: attempt ?? runnerIdentity?.attempt,
                runnerInstanceID: runnerIdentity?.instanceID,
                runnerRevision: runnerIdentity?.revision)
        } else {
            source = ChatTranscriptJournalAdapter.sourceMetadata(
                route: routeChoice,
                runID: runID,
                attempt: attempt ?? runnerIdentity?.attempt,
                runnerInstanceID: runnerIdentity?.instanceID,
                runnerRevision: runnerIdentity?.revision)
        }
        return ChatTranscriptJournalContext(
            threadID: reference.stableKey,
            turnID: turnID,
            runID: runID,
            source: source)
    }

    @discardableResult
    func mutateTranscriptJournal(
        persist: ChatTranscriptJournalPersistMode = .immediate,
        _ mutation: (inout ChatTranscriptJournalV1) -> ChatTranscriptAppendOutcomeV1
    ) -> Bool {
        guard recoverChatTranscriptJournalPersistenceIfNeeded() else {
            return false
        }
        let selectedKey = selectedSessionReference?.stableKey
        let beforeSelected = selectedKey.flatMap { chatTranscriptJournal.thread(id: $0) }
        var journal = chatTranscriptJournal
        let outcome = mutation(&journal)
        if case .ignored(.duplicateEvent) = outcome {
            refreshSelectedTranscriptProjectionIfNeeded(
                from: journal,
                beforeSelected: beforeSelected,
                selectedKey: selectedKey)
            return true
        }
        guard outcome.wasAppended else { return false }
        switch persist {
        case .coalesced:
            replaceChatTranscriptJournal(journal)
            refreshSelectedTranscriptProjectionIfNeeded(
                from: journal,
                beforeSelected: beforeSelected,
                selectedKey: selectedKey)
            chatTranscriptJournalStore.scheduleCoalescedSave(journal)
            return true
        case .immediate:
            do {
                journal = try chatTranscriptJournalStore.saveMerging(journal)
                replaceChatTranscriptJournal(journal)
                refreshSelectedTranscriptProjectionIfNeeded(
                    from: journal,
                    beforeSelected: beforeSelected,
                    selectedKey: selectedKey)
                return true
            } catch {
                return false
            }
        }
    }

    func flushCoalescedTranscriptJournal() {
        chatTranscriptJournalStore.flushCoalescedSaveIfNeeded()
    }

    private func refreshSelectedTranscriptProjectionIfNeeded(
        from journal: ChatTranscriptJournalV1,
        beforeSelected: ChatTranscriptThreadV1?,
        selectedKey: String?
    ) {
        guard let selectedKey else { return }
        let afterSelected = journal.thread(id: selectedKey)
        guard beforeSelected != afterSelected else { return }
        refreshSelectedTranscriptProjection(from: journal)
    }

    private static func noteProjectedThreadAndFlushIfChanged(
        store: ChatTranscriptJournalDiskStore,
        selectedKey: String?
    ) {
        let url = store.fileURL
        let previous = lastProjectedThreadByStoreURL[url]
        guard previous != selectedKey else { return }
        if previous != nil {
            store.flushCoalescedSaveIfNeeded()
        }
        lastProjectedThreadByStoreURL[url] = selectedKey
    }

    func refreshSelectedTranscriptProjection(
        from journal: ChatTranscriptJournalV1
    ) {
        let selectedKey = selectedSessionReference?.stableKey
        Self.noteProjectedThreadAndFlushIfChanged(
            store: chatTranscriptJournalStore,
            selectedKey: selectedKey)
        guard let reference =
                transcriptMutationReference ?? selectedSessionReference
        else { return }
        let canonical = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: reference.stableKey,
            from: journal)
        let durable = legacyTranscriptMigrationCompleted
            ? canonical
            : ChatTranscriptJournalAdapter.mergingCanonicalProjection(
                canonical,
                withLegacy: legacyStoredMessages(for: reference))
        let canonicalIDs = Set(durable.map(\.id))
        let ephemeral = messages.filter { message in
            guard !canonicalIDs.contains(message.id) else { return false }
            if message.id == activeAssistantID { return true }
            return ChatStreamPersistence.isInFlightStoredMessage(message.storedRecord)
        }
        let orderedEphemeral = ephemeral.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id < $1.id
        }
        // Canonical rows are already journal-sequence ordered. Re-sorting them
        // by timestamps can move a final result (whose timestamp began at turn
        // creation) ahead of the tool events it follows.
        let combined = durable + orderedEphemeral
        applyCanonicalTranscriptProjection(
            combined,
            reference: reference)
    }

    private func materializeAllCanonicalTranscripts() {
        for thread in document.threads {
            materializeCanonicalTranscript(
                reference: TatwoNativeChatSessionReference(kind: .thread, id: thread.id),
                from: chatTranscriptJournal)
            for discussion in thread.discussions {
                materializeCanonicalTranscript(
                    reference: TatwoNativeChatSessionReference(
                        kind: .discussion,
                        id: discussion.id),
                    from: chatTranscriptJournal)
            }
        }
        for project in document.projects {
            for thread in project.threads {
                materializeCanonicalTranscript(
                    reference: TatwoNativeChatSessionReference(kind: .thread, id: thread.id),
                    from: chatTranscriptJournal)
                for discussion in thread.discussions {
                    materializeCanonicalTranscript(
                        reference: TatwoNativeChatSessionReference(
                            kind: .discussion,
                            id: discussion.id),
                        from: chatTranscriptJournal)
                }
            }
        }
    }

    private func materializeCanonicalTranscript(
        reference: TatwoNativeChatSessionReference,
        from journal: ChatTranscriptJournalV1
    ) {
        let canonical = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: reference.stableKey,
            from: journal)
        let rows: [ChatMessage]
        if legacyTranscriptMigrationCompleted {
            rows = canonical
        } else {
            rows = ChatTranscriptJournalAdapter.mergingCanonicalProjection(
                canonical,
                withLegacy: legacyStoredMessages(for: reference))
        }
        guard !rows.isEmpty else { return }
        replaceEphemeralTranscriptProjection(
            rows.map(\.storedRecord),
            reference: reference)
    }

    /// Reconciles local in-flight rows only when runner authority is known.
    ///
    /// A fresh App process cannot infer that an empty in-memory runner set is
    /// authoritative: a launchctl-owned child may still be running, or the
    /// durable runner registry may be temporarily unreadable. Treat that state
    /// as unknown and preserve the journal instead of inventing a cancelled
    /// terminal row while the real model keeps working.
    func reconcileColdStartTranscriptOrphans(
        authority injectedAuthority: ChatRunnerAuthoritySnapshot? = nil
    ) {
        guard chatTranscriptJournalPersistenceAllowed else { return }
        var journal = chatTranscriptJournal
        var outcomes = ChatTranscriptJournalAdapter.markColdStartRemoteJobsUnknown(
            projectionProcessID: remoteProjectionProcessID,
            in: &journal)

        let authority =
            injectedAuthority
            ?? runnerAuthorityDiscoverer.discoverRunnerAuthority()
        switch authority {
        case .unknown:
            break
        case .authoritative(let active, let reclaim):
            guard Set(reclaim.map(\.runID)).isDisjoint(with: active) else {
                // Conflicting local authority evidence is never permission to
                // publish a local terminal cancellation. Remote rows have
                // already been preserved as unknown above.
                break
            }
            outcomes += ChatTranscriptJournalAdapter.cancelColdStartOrphans(
                activeRunIDs: active,
                reclaimTokens: reclaim,
                in: &journal)
        }
        guard !outcomes.isEmpty else { return }
        guard outcomes.allSatisfy({ outcome in
            if outcome.wasAppended { return true }
            if case .ignored(.duplicateEvent) = outcome { return true }
            return false
        }) else {
            blockChatTranscriptJournalPersistence()
            return
        }
        do {
            if outcomes.contains(where: \.wasAppended) {
                journal = try chatTranscriptJournalStore.saveMerging(journal)
            }
            replaceChatTranscriptJournal(journal)
        } catch {
            blockChatTranscriptJournalPersistence()
        }
    }

    private func legacyStoredMessages(
        for reference: TatwoNativeChatSessionReference
    ) -> [TatwoNativeChatStoredMessage] {
        switch reference.kind {
        case .thread:
            if let thread = document.threads.first(where: { $0.id == reference.id }) {
                return thread.messages ?? []
            }
            return document.projects
                .lazy
                .compactMap { project in
                    project.threads.first(where: { $0.id == reference.id })?.messages
                }
                .first ?? []
        case .discussion:
            let allThreads = document.threads + document.projects.flatMap(\.threads)
            return allThreads
                .lazy
                .compactMap { thread in
                    thread.discussions.first(where: { $0.id == reference.id })?.messages
                }
                .first ?? []
        }
    }
}
