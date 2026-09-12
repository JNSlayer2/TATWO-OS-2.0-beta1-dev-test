import Foundation
import Darwin
import CryptoKit
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore

struct ChatCLIOwnedProcessIdentity: Sendable, Equatable {
    let pid: pid_t
    let startToken: String
}

final class ChatCLIProcessActivity: @unchecked Sendable {
    static let stderrTailLimitBytes = 8 * 1024
    private let lock = NSLock()
    private let startedAt = Date()
    private var lastActivityAt = Date()
    private var hasAssistantVisibleOutputFlag = false
    private var watchdogFired = false
    private var lastRawLine: String?
    private var stdoutBytes = 0
    private var stderrTail = Data()

    func mark() {
        lock.lock()
        lastActivityAt = Date()
        lock.unlock()
    }

    // Tracks raw stdout bytes only (never stderr). This is the exact B7
    // stall signature: stderr gets ordinary startup warnings within
    // milliseconds, but stdout — the JSONL protocol stream — stays at 0
    // bytes indefinitely. See TatwoChatCommandPlanner.shouldAttemptZeroByteBridgeRetry.
    func markStdoutBytes(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        stdoutBytes += count
        lock.unlock()
    }

    func stdoutByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stdoutBytes
    }

    func recordStderrBytes(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > Self.stderrTailLimitBytes {
            stderrTail.removeFirst(
                stderrTail.count - Self.stderrTailLimitBytes)
        }
        lock.unlock()
    }

    func stderrTailText() -> String? {
        lock.lock()
        let data = stderrTail
        lock.unlock()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // Tracks the last non-empty stderr/stdout fallback line so a watchdog
    // failure can report which startup phase the CLI got stuck in, instead
    // of requiring a fresh `sample`/`lsof` diagnostic packet every time.
    func recordLastLine(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        lastRawLine = trimmed
        lock.unlock()
    }

    func lastLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRawLine
    }

    // Only call for events that mean usable model progress (assistant text,
    // tool use, thinking, session id). Raw stderr fallback text is process
    // liveness, not proof the model route is answering.
    func markAssistantVisible() {
        lock.lock()
        hasAssistantVisibleOutputFlag = true
        lock.unlock()
    }

    func hasAssistantVisibleOutput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasAssistantVisibleOutputFlag
    }

    func idleInterval() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivityAt)
    }

    func elapsedSinceStart() -> TimeInterval {
        Date().timeIntervalSince(startedAt)
    }

    func markWatchdogFiredIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !watchdogFired else { return false }
        watchdogFired = true
        return true
    }
}

enum ChatCLIOwnedDescendantCapture {
    private struct ProcessObservation {
        let parentPID: pid_t
        let startToken: String
    }

    static func capture(
        rootPID: pid_t,
        maximumCount: Int
    ) -> ChatCLIOwnedDescendantCaptureResult {
        guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(rootPID) else {
            return .blocked(
                knownDescendants: [],
                reason: "unsafe-root-pid")
        }
        guard maximumCount > 0 else {
            return .blocked(
                knownDescendants: [],
                reason: "invalid-descendant-limit")
        }
        guard let rootObservation = observe(pid: rootPID),
              ChatCLIProcessRunner.probeWrapperInactivity(pid: rootPID) == .active
        else {
            return .blocked(
                knownDescendants: [],
                reason: "root-identity-unavailable")
        }

        let rootIdentity = ChatCLIOwnedProcessIdentity(
            pid: rootPID,
            startToken: rootObservation.startToken)
        var admittedParents = [rootIdentity]
        var descendants: [ChatCLIOwnedProcessIdentity] = []
        var seen = Set([rootPID])
        var parentIndex = 0

        while parentIndex < admittedParents.count {
            let parent = admittedParents[parentIndex]
            parentIndex += 1
            guard matches(parent) else {
                return .blocked(
                    knownDescendants: descendants,
                    reason: "owned-parent-identity-changed")
            }

            let remaining = maximumCount - descendants.count
            guard remaining > 0 else {
                return .blocked(
                    knownDescendants: descendants,
                    reason: "owned-descendant-limit-reached")
            }
            var childPIDs = [pid_t](
                repeating: 0,
                count: remaining + 1)
            let childCount = proc_listchildpids(
                parent.pid,
                &childPIDs,
                Int32(childPIDs.count * MemoryLayout<pid_t>.stride))
            guard childCount >= 0 else {
                return .blocked(
                    knownDescendants: descendants,
                    reason: "child-list-failed-\(errno)")
            }
            guard childCount <= remaining else {
                return .blocked(
                    knownDescendants: descendants,
                    reason: "owned-descendant-limit-exceeded")
            }

            for childPID in childPIDs.prefix(Int(childCount)) {
                guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(childPID),
                      childPID != getpid(),
                      seen.insert(childPID).inserted,
                      let observation = observe(pid: childPID),
                      observation.parentPID == parent.pid
                else {
                    continue
                }
                let identity = ChatCLIOwnedProcessIdentity(
                    pid: childPID,
                    startToken: observation.startToken)
                descendants.append(identity)
                admittedParents.append(identity)
            }
        }

        guard matches(rootIdentity),
              ChatCLIProcessRunner.probeWrapperInactivity(pid: rootPID) == .active
        else {
            return .blocked(
                knownDescendants: descendants,
                reason: "root-not-live-through-capture")
        }
        return .captured(descendants)
    }

    static func probeInactivity(
        _ identity: ChatCLIOwnedProcessIdentity
    ) -> ChatCLIWrapperInactivityProbeResult {
        guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(identity.pid) else {
            return .unknown(reason: "unsafe-owned-descendant-pid")
        }
        guard let observation = observe(pid: identity.pid) else {
            errno = 0
            if Darwin.kill(identity.pid, 0) == -1, errno == ESRCH {
                return .inactive
            }
            return .unknown(reason: "owned-descendant-identity-unavailable")
        }
        guard observation.startToken == identity.startToken else {
            // The captured process is gone. A reused PID is not ours and must
            // never inherit this run's signal authority.
            return .inactive
        }
        return ChatCLIProcessRunner.probeWrapperInactivity(pid: identity.pid)
    }

    @discardableResult
    static func signal(
        _ signal: Int32,
        to identity: ChatCLIOwnedProcessIdentity
    ) -> Int32? {
        guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(identity.pid),
              matches(identity)
        else {
            return nil
        }
        return Darwin.kill(identity.pid, signal)
    }

    private static func matches(
        _ identity: ChatCLIOwnedProcessIdentity
    ) -> Bool {
        observe(pid: identity.pid)?.startToken == identity.startToken
    }

    private static func observe(pid: pid_t) -> ProcessObservation? {
        guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(pid) else {
            return nil
        }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let received = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expected)
        guard received == expected else { return nil }
        return ProcessObservation(
            parentPID: pid_t(info.pbi_ppid),
            startToken: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
    }
}

enum ChatCLIOwnedDescendantCaptureResult: Sendable, Equatable {
    case captured([ChatCLIOwnedProcessIdentity])
    case blocked(
        knownDescendants: [ChatCLIOwnedProcessIdentity],
        reason: String)
}

struct ChatCLIWatchdogPolicy: Sendable, Equatable {
    let startupGrace: TimeInterval
    let stallTimeout: TimeInterval

    static let production = ChatCLIWatchdogPolicy(
        startupGrace: 120,
        stallTimeout: 600)

    func failureMessage(
        elapsedSinceStart: TimeInterval,
        idleInterval: TimeInterval,
        hasAssistantVisibleOutput: Bool,
        lastLine: String?
    ) -> String? {
        guard elapsedSinceStart >= startupGrace else { return nil }
        let lastLineSuffix = lastLine.map {
            " Last route output: \($0.prefix(200))"
        } ?? ""

        if idleInterval >= stallTimeout {
            return "Chat route stalled: no model output (stdout/stderr) for \(Int(stallTimeout))s after process activity. The process was stopped so this thread does not stay at `...` forever.\(lastLineSuffix)"
        }
        if !hasAssistantVisibleOutput, elapsedSinceStart >= stallTimeout {
            return "Chat route degraded: process has been running for \(Int(elapsedSinceStart))s but never produced assistant output. The process was stopped; check route/session/quota/auth status.\(lastLineSuffix)"
        }
        return nil
    }
}

struct ChatCLISpawnRetryPolicy {
    static func shouldRetry(
        attempt: Int,
        terminationStatus: Int32,
        stdoutByteCount: Int
    ) -> Bool {
        attempt == 1
            // Only ordinary early command failures are retryable. Canonical
            // signal exits (128 + signal) and the established normal exit-15
            // contract are real lifecycle outcomes, never spawn failures.
            && terminationStatus > 0
            && terminationStatus < 128
            && terminationStatus != 15
            && stdoutByteCount == 0
    }
}

final class ChatCLIBridgeRetryState: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingRetryCount: Int
    private var retry: ((ChatRunnerClaimRolloverExpectation) -> Void)?
    private var attemptTerminated = false
    private var cleanupComplete = false
    private var rolloverExpectation: ChatRunnerClaimRolloverExpectation?
    private var consumed = false

    init(
        policy: TatwoChatCommandPlanner.AutomaticBridgeRetryPolicy = .disabled,
        minimumRetryCount: Int = 0
    ) {
        remainingRetryCount = max(
            max(0, minimumRetryCount),
            policy.automaticRetryCount)
    }

    func armRetry(
        _ retry: @escaping (ChatRunnerClaimRolloverExpectation) -> Void
    ) {
        lock.lock()
        guard remainingRetryCount > 0,
              self.retry == nil,
              !consumed
        else {
            lock.unlock()
            return
        }
        self.retry = retry
        lock.unlock()
    }

    func recordAttemptTermination() {
        lock.lock()
        attemptTerminated = true
        lock.unlock()
    }

    func recordRolloverExpectation(
        _ expectation: ChatRunnerClaimRolloverExpectation
    ) {
        lock.lock()
        rolloverExpectation = expectation
        lock.unlock()
    }

    func recordCleanupComplete() {
        lock.lock()
        cleanupComplete = true
        lock.unlock()
    }

    func takeRetryIfReady() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard attemptTerminated,
              cleanupComplete,
              !consumed,
              let retry,
              let rolloverExpectation
        else { return nil }
        consumed = true
        remainingRetryCount -= 1
        self.retry = nil
        self.rolloverExpectation = nil
        return {
            retry(rolloverExpectation)
        }
    }

    var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retry != nil && !consumed
    }
}

enum ChatCLIBridgeAttemptTerminationResolution: Sendable {
    case internalHandoff
    case formal(ChatCLIFormalTerminationResult)
    case blocked
    case stale
}

final class ChatCLIFormalSuccessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var observed = false
    private var frozen = false

    func consume(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !frozen, !observed else { return }
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            observed = observed || Self.isFormalSuccess(line)
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !frozen, !observed, !buffer.isEmpty else { return }
        observed = Self.isFormalSuccess(buffer)
        buffer = ""
    }

    /// Freezes terminal-precedence evidence at the cancellation boundary.
    /// Bytes drained after Stop may still be parsed for cleanup, but they may
    /// not retroactively turn a user-cancelled run into success.
    @discardableResult
    func freeze() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !observed, !buffer.isEmpty {
            observed = Self.isFormalSuccess(buffer)
        }
        frozen = true
        buffer = ""
        return observed
    }

    func invalidateForFailure() {
        lock.lock()
        observed = false
        frozen = true
        buffer = ""
        lock.unlock()
    }

    var hasObservedFormalSuccess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    private static func isFormalSuccess(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String)?.lowercased() == "turn.completed",
              object["degraded"] as? Bool != true
        else { return false }
        if let errorKind = object["error_kind"] as? String,
           !errorKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        return true
    }
}

struct ChatCLIPhysicalAttemptTracker: Sendable, Equatable {
    private(set) var runID: String?
    private(set) var attempt: UInt64?

    mutating func begin(runID: String) {
        self.runID = runID
        attempt = 1
    }

    mutating func observe(runID: String, attempt: Int) {
        guard self.runID == runID, attempt > 0 else { return }
        self.attempt = UInt64(attempt)
    }
}

struct ChatCLIRunnerDiagnosticsSnapshot: Sendable, Equatable {
    let hasProcessReference: Bool
    let processIsRunning: Bool
    let processIdentifier: pid_t?
    let activeTimerCount: Int
    let noNapActivityCount: Int
    let lifecycleRunID: String?
    /// Current physical spawn attempt for this logical run. Bridge retry is 2.
    let physicalAttempt: UInt64?
    /// Exact authority identity for the currently owned physical attempt.
    let authorityIdentity: ChatRunnerAttemptIdentity?
    let lifecyclePhase: TatwoChatRunnerLifecyclePhase
    let cancellationConvergenceState: ChatCLICancellationConvergenceState
    let blockedTerminalFailureSignal: ChatCLIBlockedTerminalFailureSignal?
}

enum ChatCLIWrapperInactivityProbeResult: Sendable, Equatable {
    case active
    case inactive
    case unknown(reason: String)
}

enum ChatCLILaunchctlLabelProbeResult: Sendable, Equatable {
    case present
    case absent
    case unknown(reason: String)
}
