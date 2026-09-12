import Foundation
import Darwin
import CryptoKit
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore

final class ChatCLICancellationContext: @unchecked Sendable {
    let process: Process
    let command: ChatCLICommand
    let runID: String
    let attempt: Int
    let eventFence: ChatCLIRuntimeEventFence
    let launchBoundary: ChatCLICancellationLaunchBoundary
    let onEvent: @Sendable (ChatCLIEvent) -> Void
    private let freezeFormalSuccess: @Sendable () -> Bool
    private let persistLaunchctlCancellationDecision:
        @Sendable (Bool) -> Bool
    private let cancellationDecisionLock = NSLock()
    private var frozenFormalSuccess: Bool?
    private let ownedDescendantCapture:
        @Sendable (pid_t, Int) -> ChatCLIOwnedDescendantCaptureResult
    private let descendantLock = NSLock()
    private var cachedOwnedDescendantCapture:
        ChatCLIOwnedDescendantCaptureResult?
    private var retainedOwnedDescendants:
        [pid_t: ChatCLIOwnedProcessIdentity] = [:]
    private var retainedOwnedDescendantOrder: [pid_t] = []
    private var ownedDescendantProofRequired = false
    private var minimumConvergenceExhaustionUptime: TimeInterval?
    private var wrapperExitCallbackStatus: Int32?

    init(
        process: Process,
        command: ChatCLICommand,
        runID: String,
        attempt: Int,
        eventFence: ChatCLIRuntimeEventFence,
        launchBoundary: ChatCLICancellationLaunchBoundary,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void,
        ownedDescendantCapture:
            @escaping @Sendable (pid_t, Int) ->
                ChatCLIOwnedDescendantCaptureResult,
        freezeFormalSuccessAtCancellation:
            @escaping @Sendable () -> Bool,
        persistLaunchctlCancellationDecision:
            @escaping @Sendable (Bool) -> Bool
    ) {
        self.process = process
        self.command = command
        self.runID = runID
        self.attempt = attempt
        self.eventFence = eventFence
        self.launchBoundary = launchBoundary
        self.onEvent = onEvent
        self.ownedDescendantCapture = ownedDescendantCapture
        self.freezeFormalSuccess =
            freezeFormalSuccessAtCancellation
        self.persistLaunchctlCancellationDecision =
            persistLaunchctlCancellationDecision
    }

    @discardableResult
    func freezeFormalSuccessAtCancellation()
        -> ChatCLICancellationFreezeResult
    {
        cancellationDecisionLock.lock()
        defer { cancellationDecisionLock.unlock() }
        let hasFormalSuccess: Bool
        if let frozenFormalSuccess {
            hasFormalSuccess = frozenFormalSuccess
        } else {
            hasFormalSuccess = freezeFormalSuccess()
            frozenFormalSuccess = hasFormalSuccess
        }
        return ChatCLICancellationFreezeResult(
            hasFormalSuccess: hasFormalSuccess,
            launchctlDecisionPersisted:
                persistLaunchctlCancellationDecision(hasFormalSuccess))
    }

    func captureOwnedDescendants(
        retryingBlockedCapture: Bool = false
    ) -> ChatCLIOwnedDescendantCaptureResult {
        descendantLock.lock()
        defer { descendantLock.unlock() }
        if let cachedOwnedDescendantCapture, !retryingBlockedCapture {
            return cachedOwnedDescendantCapture
        }
        let capture = ownedDescendantCapture(
            process.processIdentifier,
            ChatCLIProcessTerminationPolicy.maximumOwnedDescendantCount)
        switch capture {
        case .captured(let descendants):
            for descendant in descendants {
                if retainedOwnedDescendants[descendant.pid] == nil {
                    retainedOwnedDescendantOrder.append(descendant.pid)
                }
                retainedOwnedDescendants[descendant.pid] = descendant
            }
            let retained = retainedOwnedDescendantOrder.compactMap {
                retainedOwnedDescendants[$0]
            }
            let merged = ChatCLIOwnedDescendantCaptureResult.captured(retained)
            cachedOwnedDescendantCapture = merged
            return merged
        case .blocked(let knownDescendants, let reason):
            for descendant in knownDescendants {
                if retainedOwnedDescendants[descendant.pid] == nil {
                    retainedOwnedDescendantOrder.append(descendant.pid)
                }
                retainedOwnedDescendants[descendant.pid] = descendant
            }
            let retained = retainedOwnedDescendantOrder.compactMap {
                retainedOwnedDescendants[$0]
            }
            let merged = ChatCLIOwnedDescendantCaptureResult.blocked(
                knownDescendants: retained,
                reason: reason)
            cachedOwnedDescendantCapture = merged
            return merged
        }
    }

    func requireOwnedDescendantProof() {
        descendantLock.lock()
        ownedDescendantProofRequired = true
        descendantLock.unlock()
    }

    func isOwnedDescendantProofRequired() -> Bool {
        descendantLock.lock()
        defer { descendantLock.unlock() }
        return ownedDescendantProofRequired
    }

    func ownedDescendantCaptureSnapshot() -> ChatCLIOwnedDescendantCaptureResult? {
        descendantLock.lock()
        defer { descendantLock.unlock() }
        return cachedOwnedDescendantCapture
    }

    func requireConvergenceBudgetThroughForcedKill(delay: TimeInterval) {
        let deadline =
            ProcessInfo.processInfo.systemUptime + max(0, delay)
        descendantLock.lock()
        minimumConvergenceExhaustionUptime = max(
            minimumConvergenceExhaustionUptime ?? deadline,
            deadline)
        descendantLock.unlock()
    }

    func remainingConvergenceExhaustionDelay() -> TimeInterval {
        descendantLock.lock()
        defer { descendantLock.unlock() }
        guard let minimumConvergenceExhaustionUptime else { return 0 }
        return max(
            0,
            minimumConvergenceExhaustionUptime
                - ProcessInfo.processInfo.systemUptime)
    }

    func recordWrapperExitCallback(status: Int32) {
        descendantLock.lock()
        if wrapperExitCallbackStatus == nil {
            wrapperExitCallbackStatus = status
        }
        descendantLock.unlock()
    }

    func recordedWrapperExitCallbackStatus() -> Int32? {
        descendantLock.lock()
        defer { descendantLock.unlock() }
        return wrapperExitCallbackStatus
    }
}

enum ChatCLICancellationLaunchBoundary: Sendable, Equatable {
    case process
    case launchctl(label: String?, uid: uid_t)
    case unknown(shape: String)
}

struct ChatCLICancellationConvergencePolicy: Sendable, Equatable {
    let initialDelay: TimeInterval
    let retryInterval: TimeInterval
    let maxAttempts: Int

    static let production = ChatCLICancellationConvergencePolicy(
        initialDelay: ChatCLIProcessTerminationPolicy.forceKillDelay + 0.25,
        retryInterval: 0.5,
        maxAttempts: 4)
}

enum ChatCLICancellationConvergenceState: Sendable, Equatable {
    case notRequested
    case awaitingProbe(attempt: Int)
    case blocked(reason: String)
    case terminalByCallback(status: Int32)
    case terminalByAuthoritativeInactivity(status: Int32)
}

enum ChatCLICancellationConvergenceDecision: Sendable, Equatable {
    case converged
    case retry(reason: String)
    case blocked(reason: String)
}

enum ChatCLICancellationConvergenceEvaluator {
    static func decide(
        wrapper: ChatCLIWrapperInactivityProbeResult,
        ownedDescendants: [ChatCLIWrapperInactivityProbeResult] = [],
        launchBoundary: ChatCLICancellationLaunchBoundary,
        launchctlProbe: (String, uid_t) -> ChatCLILaunchctlLabelProbeResult
    ) -> ChatCLICancellationConvergenceDecision {
        switch wrapper {
        case .active:
            return .retry(reason: "wrapper-still-active")
        case .unknown(let reason):
            return .blocked(reason: "wrapper-inactivity-unknown:\(reason)")
        case .inactive:
            break
        }

        for descendant in ownedDescendants {
            switch descendant {
            case .active:
                return .retry(reason: "owned-descendant-still-active")
            case .unknown(let reason):
                return .blocked(
                    reason: "owned-descendant-inactivity-unknown:\(reason)")
            case .inactive:
                continue
            }
        }

        switch launchBoundary {
        case .process:
            return .converged
        case .launchctl(let label, let uid):
            guard let label, !label.isEmpty else {
                return .blocked(reason: "launchctl-label-missing")
            }
            switch launchctlProbe(label, uid) {
            case .absent:
                return .converged
            case .present:
                return .retry(reason: "launchctl-label-still-present")
            case .unknown(let reason):
                return .blocked(reason: "launchctl-topology-unknown:\(reason)")
            }
        case .unknown(let shape):
            return .blocked(reason: "launch-topology-unknown:\(shape)")
        }
    }
}

struct ChatCLICancellationFreezeResult: Sendable {
    let hasFormalSuccess: Bool
    let launchctlDecisionPersisted: Bool
}

struct ChatCLILaunchctlCancellationDecision {
    static let suffix = ".cancel-decision"

    static func fileURL(for statusURL: URL) -> URL {
        URL(fileURLWithPath: statusURL.path + suffix)
    }

    @discardableResult
    static func reset(for statusURL: URL) -> Bool {
        persistRaw(Data("0\n".utf8), for: statusURL)
    }

    @discardableResult
    static func persist(
        hasFormalSuccess: Bool,
        for statusURL: URL
    ) -> Bool {
        persistRaw(
            Data((hasFormalSuccess ? "1\n" : "0\n").utf8),
            for: statusURL)
    }

    private static func persistRaw(
        _ data: Data,
        for statusURL: URL
    ) -> Bool {
        do {
            try data.write(
                to: fileURL(for: statusURL),
                options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

struct ChatCLIBlockedTerminalFailureSignal: Sendable, Equatable {
    let idempotencyKey: String
    let runID: String
    let attempt: Int
    let wrapperExitStatus: Int32
    let convergenceBlockReason: String
    let authorityRemainsBlocked: Bool
    let reclaimAllowed: Bool

    var message: String {
        "Chat route wrapper exited with status \(wrapperExitStatus), but cancellation convergence remains unproven (\(convergenceBlockReason)). A terminal failure must be persisted for this turn while runner authority and reclaim stay blocked."
    }
}

struct ChatCLIFormalTerminationResult: Sendable {
    let status: Int32
    let failureMessage: String?
}

enum ChatCLIProcessTerminationPolicy {
    static let interruptDelay: TimeInterval = 1.2
    static let forceKillDelay: TimeInterval = 3.0
    static let forceKillProofMargin: TimeInterval = 0.25
    static let maximumOwnedDescendantCount = 32

    static func canonicalExitStatus(
        rawStatus: Int32,
        reason: Process.TerminationReason
    ) -> Int32 {
        switch reason {
        case .uncaughtSignal:
            return 128 + rawStatus
        case .exit:
            return rawStatus
        @unknown default:
            return rawStatus
        }
    }

    static func isSafeSignalTargetPID(_ pid: pid_t) -> Bool {
        pid > 1
    }
}

enum ChatCLITerminalPrecedencePolicy {
    static func resolvedStatus(
        processStatus: Int32,
        hasDurableFormalSuccess: Bool,
        cleanupTerminationRequested: Bool,
        hasPendingRuntimeFailure: Bool
    ) -> Int32 {
        guard processStatus == 143,
              hasDurableFormalSuccess,
              cleanupTerminationRequested,
              !hasPendingRuntimeFailure
        else { return processStatus }
        return 0
    }
}
