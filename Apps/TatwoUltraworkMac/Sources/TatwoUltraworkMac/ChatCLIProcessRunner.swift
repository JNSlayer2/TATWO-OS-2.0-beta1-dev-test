import Foundation
import Darwin
import CryptoKit
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore

final class ChatCLIProcessRunner: @unchecked Sendable {
    // Two-tier watchdog policy (Work OS 2min/10min-aligned): a quiet model
    // route gets a real chance to answer before anything degrades, and a
    // truly stuck subprocess still gets reaped instead of hanging forever.
    private static let watchdogPollInterval: TimeInterval = 5

    private let lock = NSLock()
    private let watchdogPolicy: ChatCLIWatchdogPolicy
    // 2026-09-02：原 900s 硬上限會把正在寫碼、持續有輸出的合法回合砍掉
    // （使用者：「工作又斷線」）。無輸出／無進度由 stall watchdog（600s）把關，
    // 硬上限只留作極端保險。
    static let productionHardTurnTimeout: TimeInterval = 4 * 60 * 60
    private let hardTurnTimeout: TimeInterval
    private let outputPollPolicy: ChatCLIOutputPollPolicy
    private let outputPollObserver: (@Sendable (String) -> Void)?
    private let cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy
    private let launchSurfaceEnvironment: [String: String]
    private let wrapperInactivityProbe: @Sendable (pid_t) -> ChatCLIWrapperInactivityProbeResult
    private let launchctlLabelProbe: @Sendable (String, uid_t) -> ChatCLILaunchctlLabelProbeResult
    private let ownedDescendantCapture:
        @Sendable (pid_t, Int) -> ChatCLIOwnedDescendantCaptureResult
    private let terminationCallbackDelivery: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let runnerAuthority: (any ChatRunnerAuthorityRecording)?
    private let runtimeGovernor: TatwoRuntimeGovernor
    let runtimeRootURL: URL
    private let runtimeRetentionPolicy: ChatCLIRuntimeRetentionPolicy
    private let runtimeSweepGate: ChatCLIRuntimeSweepGate
    private let runtimeSweepLauncher:
        @Sendable (URL, String, @escaping @Sendable () -> Void) -> Void
    // Creating the runtime root is filesystem I/O against an arbitrary root
    // that may live on a slow, contended, or stalled external volume. This
    // runner is constructed inside ChatPageModel.init, which itself runs
    // inside SwiftUI body/model composition on MainActor, so a blocked
    // `mkdirat` there freezes the entire main thread -- including AppleEvent
    // and Accessibility service. That reproduced as every Computer-Use
    // `get_app_state` timing out after ~17s against staging while Finder AX
    // stayed healthy, with 100% of main-thread samples parked in
    // ChatCLIProcessRunner.init -> FileManager.createDirectory -> mkdirat.
    // Preparation is therefore lazy and idempotent: it runs at the first
    // runner operation that actually needs the directory, never from init.
    private let runtimeRootPreparer: @Sendable (URL) throws -> Void
    private let runtimeRootPreparationLock = NSLock()
    private var runtimeRootPrepared = false
    private let runtimeReceiptLock = NSLock()
    private var process: Process?
    private var runtimeGovernorAdmissionTask: Task<Void, Never>?
    private var runtimeGovernorAdmissionID: UUID?
    private var runtimeGovernorLease: TatwoRuntimeLease?
    private var runtimeGovernorLeaseHasSpawnedProcess = false
    private var hardTurnDeadline: Date?
    private var watchdog: DispatchSourceTimer?
    private var hardTimeoutTimer: DispatchSourceTimer?
    private var outputPoller: DispatchSourceTimer?
    private var bridgeCheckpoint: DispatchSourceTimer?
    private var zeroByteFailFast: DispatchSourceTimer?
    private var waitingHeartbeat: DispatchSourceTimer?
    private let noNapActivities = ChatCLINoNapActivityRegistry()
    private var lifecycleRunID: String?
    private var physicalAttemptTracker = ChatCLIPhysicalAttemptTracker()
    private var currentAuthorityIdentity: ChatRunnerAttemptIdentity?
    private var lifecyclePhase: TatwoChatRunnerLifecyclePhase = .terminated
    private var lifecycleLastActivityAt = Date.distantPast
    private var lifecycleFormalExitStatus: Int32?
    private var lifecycleFormalFailureMessage: String?
    private var pendingRuntimeFailure: (runID: String, message: String)?
    private var completedBridgeHandoff: (runID: String, status: Int32)?
    private var activeCancellationContext: ChatCLICancellationContext?
    private var cancellationConvergenceGeneration: UUID?
    private var cancellationConvergenceState: ChatCLICancellationConvergenceState = .notRequested
    private var blockedTerminalFailureSignal:
        ChatCLIBlockedTerminalFailureSignal?

    private enum TimerSlot {
        case watchdog
        case hardTimeout
        case outputPoller
        case bridgeCheckpoint
        case zeroByteFailFast
        case waitingHeartbeat
    }

    init(
        watchdogPolicy: ChatCLIWatchdogPolicy = .production,
        hardTurnTimeout: TimeInterval =
            ChatCLIProcessRunner.productionHardTurnTimeout,
        outputPollPolicy: ChatCLIOutputPollPolicy = .production,
        outputPollObserver: (@Sendable (String) -> Void)? = nil,
        cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy = .production,
        launchSurfaceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        wrapperInactivityProbe: @escaping @Sendable (pid_t) -> ChatCLIWrapperInactivityProbeResult =
            ChatCLIProcessRunner.probeWrapperInactivity,
        launchctlLabelProbe: @escaping @Sendable (String, uid_t) -> ChatCLILaunchctlLabelProbeResult =
            ChatCLIProcessRunner.probeLaunchctlLabel,
        ownedDescendantCapture:
            @escaping @Sendable (pid_t, Int) ->
                ChatCLIOwnedDescendantCaptureResult =
            ChatCLIOwnedDescendantCapture.capture,
        runnerAuthority: (any ChatRunnerAuthorityRecording)? = nil,
        runtimeGovernor: TatwoRuntimeGovernor? = nil,
        runtimeRootURL: URL = ChatCLIRuntimeRootFactory.defaultRoot(),
        runtimeRetentionPolicy: ChatCLIRuntimeRetentionPolicy = .production,
        runtimeSweepGate: ChatCLIRuntimeSweepGate = ChatCLIRuntimeSweepGate(),
        runtimeSweepLauncher:
            (@Sendable (URL, String, @escaping @Sendable () -> Void) -> Void)? = nil,
        runtimeRootPreparer: @escaping @Sendable (URL) throws -> Void = { root in
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true)
        },
        terminationCallbackDelivery: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
            callback in callback()
        }
    ) {
        self.watchdogPolicy = watchdogPolicy
        self.hardTurnTimeout = max(0.05, hardTurnTimeout)
        self.outputPollPolicy = outputPollPolicy
        self.outputPollObserver = outputPollObserver
        self.cancellationConvergencePolicy = cancellationConvergencePolicy
        self.launchSurfaceEnvironment = launchSurfaceEnvironment
        self.wrapperInactivityProbe = wrapperInactivityProbe
        self.launchctlLabelProbe = launchctlLabelProbe
        self.ownedDescendantCapture = ownedDescendantCapture
        self.runnerAuthority = runnerAuthority
        self.runtimeGovernor = runtimeGovernor ?? TatwoRuntimeGovernor(
            tier: .detected(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory))
        self.runtimeRootURL = runtimeRootURL.standardizedFileURL
        self.runtimeRetentionPolicy = runtimeRetentionPolicy
        self.runtimeSweepGate = runtimeSweepGate
        self.runtimeSweepLauncher =
            runtimeSweepLauncher
            ?? ChatCLIProcessRunner.launchStaleSweep
        self.runtimeRootPreparer = runtimeRootPreparer
        self.terminationCallbackDelivery = terminationCallbackDelivery
        // No filesystem I/O here on purpose. See runtimeRootPreparer above:
        // init can run on MainActor inside SwiftUI body composition, and the
        // runtime root may be an unresponsive external volume.
        scheduleRuntimeMaintenance(reason: "runner-init")
    }

    /// Creates the runtime root exactly once, off whatever thread first
    /// needs it. Fail-closed: a failure is propagated to the caller and is
    /// never cached, so a transient volume stall cannot permanently poison
    /// this runner and a later attempt can still succeed. Safe to call
    /// concurrently -- the lock is held across creation, so at most one
    /// `mkdir` is issued per successful preparation.
    @discardableResult
    func prepareRuntimeRootIfNeeded(force: Bool = false) throws -> URL {
        runtimeRootPreparationLock.lock()
        defer { runtimeRootPreparationLock.unlock() }
        if runtimeRootPrepared, !force { return runtimeRootURL }
        do {
            try runtimeRootPreparer(runtimeRootURL)
        } catch {
            runtimeRootPrepared = false
            throw error
        }
        runtimeRootPrepared = true
        return runtimeRootURL
    }

    /// Diagnostics/test probe: whether the runtime root has been prepared
    /// successfully at least once by this runner.
    var runtimeRootIsPrepared: Bool {
        runtimeRootPreparationLock.lock()
        defer { runtimeRootPreparationLock.unlock() }
        return runtimeRootPrepared
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    var lifecycleSnapshot: TatwoChatRunnerLivenessSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let lifecycleRunID else { return nil }
        return TatwoChatRunnerLivenessSnapshot(
            runID: lifecycleRunID,
            phase: lifecyclePhase,
            processIsAlive: process?.isRunning == true,
            lastActivityAt: lifecycleLastActivityAt,
            formalExitStatus: lifecycleFormalExitStatus,
            formalFailureMessage: lifecycleFormalFailureMessage)
    }

    var diagnosticsSnapshot: ChatCLIRunnerDiagnosticsSnapshot {
        lock.lock()
        let snapshot = ChatCLIRunnerDiagnosticsSnapshot(
            hasProcessReference: process != nil,
            processIsRunning: process?.isRunning == true,
            processIdentifier: process.map(\.processIdentifier),
            activeTimerCount: [
                watchdog,
                hardTimeoutTimer,
                outputPoller,
                bridgeCheckpoint,
                zeroByteFailFast,
                waitingHeartbeat,
            ]
                .compactMap { $0 }
                .count,
            noNapActivityCount: 0,
            lifecycleRunID: lifecycleRunID,
            physicalAttempt: physicalAttemptTracker.attempt,
            authorityIdentity: currentAuthorityIdentity,
            lifecyclePhase: lifecyclePhase,
            cancellationConvergenceState: cancellationConvergenceState,
            blockedTerminalFailureSignal: blockedTerminalFailureSignal)
        lock.unlock()
        return ChatCLIRunnerDiagnosticsSnapshot(
            hasProcessReference: snapshot.hasProcessReference,
            processIsRunning: snapshot.processIsRunning,
            processIdentifier: snapshot.processIdentifier,
            activeTimerCount: snapshot.activeTimerCount,
            noNapActivityCount: noNapActivities.count,
            lifecycleRunID: snapshot.lifecycleRunID,
            physicalAttempt: snapshot.physicalAttempt,
            authorityIdentity: snapshot.authorityIdentity,
            lifecyclePhase: snapshot.lifecyclePhase,
            cancellationConvergenceState: snapshot.cancellationConvergenceState,
            blockedTerminalFailureSignal:
                snapshot.blockedTerminalFailureSignal)
    }

    // Tatwo Ultrawork ships as an LSUIElement accessory app, which macOS is
    // quick to App Nap once it loses key/active status. App Nap throttles a
    // spawned child's scheduling along with the parent, which reproduces as
    // `codex exec` staying alive with zero stdout/stderr bytes for minutes
    // even though the identical argv/env finishes in seconds from a
    // terminal. Hold a `.userInitiated` activity token for the lifetime of
    // each CLI turn so the child gets normal scheduling regardless of the
    // app's window/focus state.
    private func beginNoNapActivity(for runID: String) {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Tatwo Ultrawork chat CLI turn")
        if let replaced = noNapActivities.install(token, for: runID) {
            ProcessInfo.processInfo.endActivity(replaced)
        }
    }

    private func endNoNapActivity(for runID: String) {
        let token = noNapActivities.remove(for: runID)
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    @discardableResult
    func start(
        command: ChatCLICommand,
        runID: String,
        activityTurnID: String? = nil,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        terminate()
        lock.lock()
        let previousRuntimeStillConverging =
            runtimeGovernorLease != nil
            || runtimeGovernorAdmissionID != nil
            || process?.isRunning == true
        lock.unlock()
        guard !previousRuntimeStillConverging else {
            command.cleanupOwnedTemporaryFiles()
            return nil
        }
        scheduleRuntimeMaintenance(reason: "before-chat-turn")
        guard let identity = claimAuthorityIdentity(
            runID: runID,
            attempt: 1,
            expectedPrior: nil)
        else {
            command.cleanupOwnedTemporaryFiles()
            return nil
        }
        lock.lock()
        lifecycleRunID = runID
        physicalAttemptTracker.begin(runID: runID)
        currentAuthorityIdentity = identity
        lifecyclePhase = .running
        lifecycleLastActivityAt = Date()
        lifecycleFormalExitStatus = nil
        lifecycleFormalFailureMessage = nil
        pendingRuntimeFailure = nil
        completedBridgeHandoff = nil
        activeCancellationContext = nil
        cancellationConvergenceGeneration = nil
        cancellationConvergenceState = .notRequested
        blockedTerminalFailureSignal = nil
        hardTurnDeadline = nil
        lock.unlock()
        if let lease = runtimeGovernor.acquireChatRuntimeIfAvailable(
            kind: .chatPerTurn)
        {
            guard installGovernorLease(lease, runID: runID) else {
                runtimeGovernor.release(lease)
                command.cleanupOwnedTemporaryFiles()
                return nil
            }
            beginNoNapActivity(for: runID)
            spawn(
                command: command,
                runID: runID,
                activityTurnID: activityTurnID,
                attempt: 1,
                authorityIdentity: identity,
                onEvent: onEvent)
            return identity
        }
        let admissionID = UUID()
        lock.lock()
        guard lifecycleRunID == runID, lifecyclePhase == .running else {
            lock.unlock()
            command.cleanupOwnedTemporaryFiles()
            return nil
        }
        runtimeGovernorAdmissionID = admissionID
        lock.unlock()
        let admissionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let lease = try await self.runtimeGovernor.acquireChatRuntime(
                    kind: .chatPerTurn,
                    onWait: { reason in
                        onEvent(.diagnostic(
                            "runtime_wait_reason=\(reason.machineReadableCode)"))
                    })
                guard self.installGovernorLease(
                    lease,
                    runID: runID,
                    admissionID: admissionID)
                else {
                    self.runtimeGovernor.release(lease)
                    command.cleanupOwnedTemporaryFiles()
                    return
                }
                self.beginNoNapActivity(for: runID)
                self.spawn(
                    command: command,
                    runID: runID,
                    activityTurnID: activityTurnID,
                    attempt: 1,
                    authorityIdentity: identity,
                    onEvent: onEvent)
            } catch {
                self.clearGovernorAdmission(
                    admissionID: admissionID,
                    runID: runID)
                command.cleanupOwnedTemporaryFiles()
                self.endNoNapActivity(for: runID)
            }
        }
        lock.lock()
        if lifecycleRunID == runID,
           lifecyclePhase == .running,
           runtimeGovernorAdmissionID == admissionID
        {
            runtimeGovernorAdmissionTask = admissionTask
        } else {
            admissionTask.cancel()
        }
        lock.unlock()
        return identity
    }

    private func installGovernorLease(
        _ lease: TatwoRuntimeLease,
        runID: String,
        admissionID: UUID? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycleRunID == runID,
              lifecyclePhase == .running,
              runtimeGovernorLease == nil
        else {
            return false
        }
        if let admissionID {
            guard runtimeGovernorAdmissionID == admissionID else {
                return false
            }
        }
        runtimeGovernorLease = lease
        runtimeGovernorLeaseHasSpawnedProcess = false
        runtimeGovernorAdmissionTask = nil
        runtimeGovernorAdmissionID = nil
        hardTurnDeadline = Date().addingTimeInterval(hardTurnTimeout)
        return true
    }

    private func clearGovernorAdmission(
        admissionID: UUID,
        runID: String
    ) {
        lock.lock()
        guard lifecycleRunID == runID,
              runtimeGovernorAdmissionID == admissionID
        else {
            lock.unlock()
            return
        }
        runtimeGovernorAdmissionTask = nil
        runtimeGovernorAdmissionID = nil
        lock.unlock()
    }

    // Handles one launch attempt for a turn. Called a second time, with
    // `attempt: 2` and a shell-bridged command, only when
    // startBridgeCheckpointIfNeeded's timer observes the exact B7 zero-byte
    // stall signature on attempt 1. All other flows (normal completion,
    // startup failure, no-output watchdog) are unchanged from before this
    // patch.
    private func spawn(
        command: ChatCLICommand,
        runID: String,
        activityTurnID: String?,
        attempt: Int,
        authorityIdentity: ChatRunnerAttemptIdentity,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) {
        lock.lock()
        physicalAttemptTracker.observe(runID: runID, attempt: attempt)
        lock.unlock()
        let process = Process()
        let eventFence = ChatCLIRuntimeEventFence()
        var launchEnvironment = Self.cliLaunchEnvironment(
            base: ProcessInfo.processInfo.environment)
        for (key, value) in command.environmentOverrides {
            launchEnvironment[key] = value
        }
        let input = Pipe()
        let streamFiles: (stdout: URL, stderr: URL, status: URL)
        do {
            streamFiles = try prepareStreamFiles(runID: runID, attempt: attempt)
        } catch {
            let message =
                "Unable to prepare model runtime directory at "
                + "\(runtimeRootURL.path): \(error.localizedDescription)"
            let result = recordFormalTermination(
                process: nil,
                runID: runID,
                status: -1,
                failureMessage: message)
            if result != nil, eventFence.commitFormalTerminal() {
                releaseGovernorLease()
                onEvent(.failure(message))
            }
            endNoNapActivity(for: runID)
            command.cleanupOwnedTemporaryFiles()
            return
        }
        let baseResolvedExecutable = TatwoChatCommandPlanner.resolvedExecutablePath(
            for: command.executable,
            pathEnvironmentValue: launchEnvironment["PATH"] ?? "",
            isExecutableFile: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        let shouldUseProcessBoundaryForCurrentSurface =
            Self.shouldUseDetachedChatProcessBoundary(
                env: launchSurfaceEnvironment)
        let shouldUseLaunchctlBoundaryForCurrentSurface =
            Self.shouldUseLaunchctlChatProcessBoundary(
                env: launchSurfaceEnvironment)
        let useLaunchctlSubmitBoundary =
            !command.isAlreadyBridged
            && shouldUseLaunchctlBoundaryForCurrentSurface
            && baseResolvedExecutable.hasPrefix("/")
            && TatwoChatCommandPlanner.shouldUseLaunchctlSubmitBoundary(
                mode: command.commandMode,
                runtimeAdapter: command.runtimeAdapter,
                attempt: attempt)
        let useInitialBridgeParent =
            !command.isAlreadyBridged
            && !useLaunchctlSubmitBoundary
            && shouldUseProcessBoundaryForCurrentSurface
            && baseResolvedExecutable.hasPrefix("/")
            && TatwoChatCommandPlanner.shouldUseInitialBridgeParent(
                mode: command.commandMode,
                runtimeAdapter: command.runtimeAdapter,
                attempt: attempt)
        let launchCommand: ChatCLICommand
        let resolvedExecutable: String
        let launchShape: String
        let launchctlLabel: String?
        if useLaunchctlSubmitBoundary {
            // B11: B10 proved that even a zsh parent can inherit enough of
            // the app process tree to leave GUI-launched Codex at 0 stdout.
            // Submit a one-shot, non-persistent launchd job instead. The
            // wrapper only polls/cleans the submitted label; stdout/stderr
            // still stream through the same temp files the Chat UI tails.
            let label = Self.launchctlChatLabel(runID: runID)
            let envArguments = Self.launchctlSubmittedEnvironmentArguments(
                launchEnvironment: launchEnvironment,
                executable: baseResolvedExecutable,
                arguments: command.arguments)
            let bridge = TatwoChatCommandPlanner.launchctlSubmitBoundaryLaunch(
                label: label,
                stdoutPath: streamFiles.stdout.path,
                stderrPath: streamFiles.stderr.path,
                statusPath: streamFiles.status.path,
                uid: "\(getuid())",
                workingDirectoryPath: command.workingDirectory.path,
                executable: "/usr/bin/env",
                arguments: envArguments)
            launchCommand = command.bridged(executable: bridge.executable, arguments: bridge.arguments)
            resolvedExecutable = bridge.executable
            launchShape = "launchctl-submit-boundary"
            launchctlLabel = label
        } else if useInitialBridgeParent {
            // B10: do not spend each user-facing Chat turn proving the known
            // bad shape again. For Chat+codexExec, make `/bin/zsh` the
            // direct child of the app from attempt 1 and let the real
            // `codex` process be the zsh child. The helper keeps every
            // prompt/argv token as `$@`, so shell syntax inside the prompt is
            // never reparsed.
            let bridge = TatwoChatCommandPlanner.zeroByteBridgeLaunch(
                executable: baseResolvedExecutable,
                arguments: command.arguments)
            launchCommand = command.bridged(executable: bridge.executable, arguments: bridge.arguments)
            resolvedExecutable = bridge.executable
            launchShape = "bridge-parent-initial"
            launchctlLabel = nil
        } else {
            launchCommand = command
            resolvedExecutable = baseResolvedExecutable
            launchShape = command.isAlreadyBridged ? "bridge-parent-retry" : "direct"
            launchctlLabel = nil
        }
        if resolvedExecutable.hasPrefix("/") {
            // Spawn the real binary directly instead of routing through
            // `/usr/bin/env`. See resolvedExecutablePath's doc comment: this
            // removes an extra fork+exec hop that is a variable when a
            // GUI-launched turn behaves differently from an identical
            // terminal invocation of the same executable name.
            process.executableURL = URL(fileURLWithPath: resolvedExecutable)
            process.arguments = launchCommand.arguments
        } else {
            // Resolution against our own PATH failed (unexpected); fall back
            // to the previous `/usr/bin/env` indirection so a lookup miss
            // here never turns into "command not found" that a bare name
            // would have found some other way.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchCommand.executable] + launchCommand.arguments
        }
        process.currentDirectoryURL = Self.processCurrentDirectory(
            for: launchCommand,
            launchShape: launchShape)
        process.environment = launchEnvironment
        if launchCommand.requiresForegroundScheduling {
            // This app is LSUIElement (never frontmost), so macOS classifies
            // it and its freshly spawned children as backgrounded at launch.
            // That demotes the child's networking/scheduling QoS enough that
            // a `codex exec`/`claude` turn can stall indefinitely waiting on
            // the model API even though it returns in seconds from a
            // foreground terminal with identical argv/env. Requesting
            // `.userInitiated` QoS here is a real posix_spawn attribute (not
            // just an activity hint on this process), so it actually lands
            // on the child at spawn time.
            process.qualityOfService = .userInitiated
        }

        let stdoutWriteHandle: FileHandle
        let stderrWriteHandle: FileHandle
        do {
            stdoutWriteHandle = try FileHandle(forWritingTo: streamFiles.stdout)
            stderrWriteHandle = try FileHandle(forWritingTo: streamFiles.stderr)
        } catch {
            let message = "Unable to prepare model stream files: \(error.localizedDescription)"
            let result = recordFormalTermination(
                process: nil,
                runID: runID,
                status: -1,
                failureMessage: message)
            if result != nil, eventFence.commitFormalTerminal() {
                releaseGovernorLease()
                onEvent(.failure(message))
            }
            endNoNapActivity(for: runID)
            launchCommand.cleanupOwnedTemporaryFiles()
            return
        }
        let logHandle: FileHandle?
        if let logFileURL = launchCommand.logFileURL {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logFileURL)
        } else {
            logHandle = nil
        }
        if launchCommand.standardInputFromDevNull {
            // Fail closed instead of silently falling back to the unused
            // `input` Pipe: that fallback never gets its write end closed
            // (the close below is gated on `standardInputFromDevNull`), so
            // a child that actually reads stdin would block on EOF forever
            // and look identical to the App Nap stall this fix targets.
            guard let nullInput = FileHandle(forReadingAtPath: "/dev/null") else {
                let message = "Unable to open /dev/null for model stdin; refusing to start with an unclosed stdin pipe."
                let result = recordFormalTermination(
                    process: nil,
                    runID: runID,
                    status: -1,
                    failureMessage: message)
                if result != nil, eventFence.commitFormalTerminal() {
                    releaseGovernorLease()
                    onEvent(.failure(message))
                }
                try? stdoutWriteHandle.close()
                try? stderrWriteHandle.close()
                try? logHandle?.close()
                endNoNapActivity(for: runID)
                launchCommand.cleanupOwnedTemporaryFiles()
                return
            }
            process.standardInput = nullInput
        } else {
            process.standardInput = input
        }
        process.standardOutput = stdoutWriteHandle
        process.standardError = stderrWriteHandle

        let lineParser = ChatCLIStreamAdapter(
            engine: launchCommand.engine,
            expectsJSON: launchCommand.expectsJSON,
            capturesSessionID: launchCommand.capturesSessionID,
            runtimeAdapter: launchCommand.runtimeAdapter,
            activityTurnID: activityTurnID ?? runID,
            activityAttempt: attempt)
        // The output poller and Process termination handler run on different
        // queues. Serialize parse + publish with final flush + fence close so
        // the poller cannot parse a complete event, get preempted, and then
        // lose that event after termination closes the fence.
        let streamEventGate = ChatCLIStreamEventGate()
        let formalSuccessTracker = ChatCLIFormalSuccessTracker()
        let activity = ChatCLIProcessActivity()
        let thinkingHeartbeat = ChatCLIThinkingHeartbeat(
            turnID: activityTurnID ?? runID,
            attempt: attempt,
            onEvent: { event in
                eventFence.emitNonterminalEvent {
                    onEvent(event)
                }
            })
        let tailState = ChatCLIFileTailState(stdoutURL: streamFiles.stdout, stderrURL: streamFiles.stderr)
        let bridgeRetryState = ChatCLIBridgeRetryState(
            policy: command.automaticBridgeRetryPolicy,
            minimumRetryCount: attempt == 1 ? 1 : 0)

        let routeParsedEvents: @Sendable ([ChatCLIEvent], String, Bool) -> Void = {
            events,
            fallbackPrefix,
            processAlreadyExited in
            // After bridge retry is armed, suppress every attempt-1 event
            // (including final unterminated JSONL flushed after exit).
            let suppressAttemptOutput = bridgeRetryState.isArmed
            for event in events {
                if suppressAttemptOutput { continue }
                thinkingHeartbeat.observe(event)
                if case .failure(let message) = event {
                    // A structured stream failure proves this attempt must
                    // stop, not that its child has already exited. Preserve
                    // one pending failure, and immediately close nonterminal
                    // publication so later bytes from the same read batch
                    // cannot resurrect a successful assistant message or
                    // activity after `response.failed`.
                    if self.recordPendingRuntimeFailure(message, runID: runID) {
                        formalSuccessTracker.invalidateForFailure()
                        eventFence.closeNonterminalEvents()
                        // If termination already delivered this final
                        // unterminated event, the real callback below already
                        // owns the formal terminal and must not receive a
                        // redundant TERM/KILL request.
                        if !processAlreadyExited {
                            self.requestBoundedTermination(
                                of: process,
                                runID: runID,
                                attempt: attempt,
                                processAlreadyExited: processAlreadyExited,
                                reason: "stream-failure")
                        }
                    }
                    continue
                }
                eventFence.emitNonterminalEvent {
                    switch event {
                    case .output, .thinking, .toolUse, .reconnectProgress, .activity, .session:
                        // Real model progress. Stderr fallback text always
                        // arrives as `.raw`, so it never lands here.
                        activity.markAssistantVisible()
                    default:
                        break
                    }
                    switch event {
                    case .raw(let raw) where !fallbackPrefix.isEmpty:
                        activity.recordLastLine(raw)
                        onEvent(.raw(fallbackPrefix + raw))
                    case .raw(let raw):
                        activity.recordLastLine(raw)
                        onEvent(event)
                    default:
                        onEvent(event)
                    }
                }
            }
        }

        let consume: @Sendable (Data, String, Bool) -> Void = {
            data,
            fallbackPrefix,
            processAlreadyExited in
            guard !data.isEmpty else { return }
            if !processAlreadyExited {
                self.outputPollObserver?(runID)
            }
            activity.mark()
            self.markLifecycleActivity(runID: runID)
            if fallbackPrefix.isEmpty {
                activity.markStdoutBytes(data.count)
            } else {
                activity.recordStderrBytes(data)
            }
            if let logHandle {
                _ = try? logHandle.seekToEnd()
                try? logHandle.write(contentsOf: data)
            }
            let text = String(decoding: data, as: UTF8.self)
            if fallbackPrefix.isEmpty {
                formalSuccessTracker.consume(text)
            }
            let events = lineParser.consume(text)
            routeParsedEvents(events, fallbackPrefix, processAlreadyExited)
        }

        let drainStreamEvents: @Sendable () -> Void = {
            streamEventGate.sync {
                tailState.drain { data, fallbackPrefix in
                    consume(data, fallbackPrefix, false)
                }
            }
        }

        let finalizeStreamEvents: @Sendable () -> Void = {
            streamEventGate.sync {
                // Reading and publishing must be one critical section.
                // Otherwise the poller can advance the file offset, get
                // preempted before consume(), and let termination flush/close
                // the fence first. Treat every final drain event as post-exit
                // so a structured failure cannot request redundant signals.
                let processAlreadyExited = true
                tailState.drain { data, fallbackPrefix in
                    consume(data, fallbackPrefix, processAlreadyExited)
                }
                routeParsedEvents(lineParser.flush(), "", processAlreadyExited)
                formalSuccessTracker.flush()
                eventFence.closeNonterminalEvents()
            }
        }

        let cancellationLaunchBoundary: ChatCLICancellationLaunchBoundary
        switch launchShape {
        case "direct", "bridge-parent-initial", "bridge-parent-retry":
            cancellationLaunchBoundary = .process
        case "launchctl-submit-boundary":
            cancellationLaunchBoundary = .launchctl(
                label: launchctlLabel,
                uid: getuid())
        default:
            cancellationLaunchBoundary = .unknown(shape: launchShape)
        }
        let cancellationContext = ChatCLICancellationContext(
            process: process,
            command: launchCommand,
            runID: runID,
            attempt: attempt,
            eventFence: eventFence,
            launchBoundary: cancellationLaunchBoundary,
            onEvent: onEvent,
            ownedDescendantCapture: ownedDescendantCapture,
            freezeFormalSuccessAtCancellation: {
                formalSuccessTracker.freeze()
            },
            persistLaunchctlCancellationDecision: { hasFormalSuccess in
                guard case .launchctl = cancellationLaunchBoundary else {
                    return true
                }
                return ChatCLILaunchctlCancellationDecision.persist(
                    hasFormalSuccess: hasFormalSuccess,
                    for: streamFiles.status)
            })

        process.terminationHandler = { proc in
            self.terminationCallbackDelivery {
            thinkingHeartbeat.stop()
            bridgeRetryState.recordAttemptTermination()
            self.cancelWatchdog(for: proc)
            self.cancelHardTimeout(for: proc)
            self.cancelOutputPoller(for: proc)
            self.cancelBridgeCheckpoint(for: proc)
            self.cancelZeroByteFailFast(for: proc)
            self.cancelWaitingHeartbeat(for: proc)
            // Final read + parse + publish + fence close is serialized against
            // the poller so no event can be stranded between offset advance
            // and publication.
            finalizeStreamEvents()
            try? stdoutWriteHandle.close()
            try? stderrWriteHandle.close()
            try? logHandle?.close()
            bridgeRetryState.recordCleanupComplete()
            let rawTerminationStatus = proc.terminationStatus
            let terminationReason = proc.terminationReason
            let canonicalTerminationStatus =
                ChatCLIProcessTerminationPolicy.canonicalExitStatus(
                    rawStatus: rawTerminationStatus,
                    reason: terminationReason)
            let effectiveTerminationStatus = self.resolveTerminalStatus(
                processStatus: canonicalTerminationStatus,
                runID: runID,
                hasDurableFormalSuccess: formalSuccessTracker.hasObservedFormalSuccess)
            if self.isEligibleForSpawnRetry(runID: runID),
               ChatCLISpawnRetryPolicy.shouldRetry(
                attempt: attempt,
                terminationStatus: effectiveTerminationStatus,
                stdoutByteCount: activity.stdoutByteCount())
            {
                bridgeRetryState.armRetry { [weak self] expectedPrior in
                    guard let self else { return }
                    guard let retryIdentity = self.claimAuthorityIdentity(
                        runID: runID,
                        attempt: 2,
                        expectedPrior: expectedPrior)
                    else {
                        self.endNoNapActivity(for: runID)
                        command.cleanupOwnedTemporaryFiles()
                        let message =
                            "runner-authority-attempt-2-claim-failed"
                        if let result = self.recordFormalTermination(
                            process: nil,
                            runID: runID,
                            status: -1,
                            failureMessage: message)
                        {
                            self.emitFormalTermination(
                                result,
                                eventFence: eventFence,
                                onEvent: onEvent)
                        }
                        return
                    }
                    self.lock.lock()
                    if self.lifecycleRunID == runID,
                       self.lifecyclePhase != .terminated
                    {
                        self.currentAuthorityIdentity = retryIdentity
                    }
                    self.lock.unlock()
                    self.spawn(
                        command: command,
                        runID: runID,
                        activityTurnID: activityTurnID,
                        attempt: 2,
                        authorityIdentity: retryIdentity,
                        onEvent: onEvent)
                }
                if bridgeRetryState.isArmed {
                    onEvent(.diagnostic(
                        "spawn_retry=1 reason=zero_output_nonzero_exit"))
                }
            }
            let bridgeRetryArmed = bridgeRetryState.isArmed
            if !bridgeRetryArmed {
                launchCommand.cleanupOwnedTemporaryFiles()
            }
            cancellationContext.recordWrapperExitCallback(
                status: effectiveTerminationStatus)
            self.appendSpawnReceipt(runID: runID, attempt: attempt, event: bridgeRetryArmed ? "bridge-handoff" : "exit", extra: [
                "terminationStatus": "\(rawTerminationStatus)",
                "terminationReason": "\(terminationReason)",
                "canonicalTerminationStatus": "\(canonicalTerminationStatus)",
                "effectiveTerminationStatus": "\(effectiveTerminationStatus)",
                "durableFormalSuccess": "\(formalSuccessTracker.hasObservedFormalSuccess)",
                "stdoutBytes": "\(activity.stdoutByteCount())",
                "activitySuppressed": "\(bridgeRetryArmed)"
            ])
            if self.deferCancellationCallbackUntilTerminalProof(
                process: proc,
                context: cancellationContext)
            {
                return
            }
            if bridgeRetryArmed {
                // A bridge-triggered attempt-1 exit is internal only while
                // the run is still active. If cancel/watchdog moved the run
                // to terminationRequested, this real Process callback owns
                // the formal terminal transition and attempt 2 must not spawn.
                if let runnerAuthority = self.runnerAuthority {
                    switch runnerAuthority.recordAttemptTerminal(
                        identity: authorityIdentity,
                        status: canonicalTerminationStatus)
                    {
                    case .persisted, .idempotent:
                        break
                    case .blocked(let reason):
                        self.blockVisibleTerminalForAuthorityPersistence(
                            runID: runID,
                            reason: reason)
                        return
                    }
                }
                bridgeRetryState.recordRolloverExpectation(
                    ChatRunnerClaimRolloverExpectation(
                        identity: authorityIdentity,
                        phase: .attemptTerminal(
                            status: canonicalTerminationStatus)))
                let resolution = self.resolveBridgeAttemptTermination(
                    process: proc,
                    runID: runID,
                    status: canonicalTerminationStatus)
                switch resolution {
                case .internalHandoff:
                    bridgeRetryState.takeRetryIfReady()?()
                    return
                case .stale:
                    return
                case .blocked:
                    return
                case .formal(let result):
                    self.endNoNapActivity(for: runID)
                    self.emitFormalTermination(result, eventFence: eventFence, onEvent: onEvent)
                    return
                }
            }
            self.endNoNapActivity(for: runID)
            let zeroStdoutFailure = TatwoChatCommandPlanner.zeroStdoutExitRuntimeFailureMessage(
                mode: launchCommand.commandMode,
                runtimeAdapter: launchCommand.runtimeAdapter,
                terminationStatus: effectiveTerminationStatus,
                stdoutByteCount: activity.stdoutByteCount(),
                hasAssistantVisibleOutput: activity.hasAssistantVisibleOutput(),
                launchShape: launchShape)
            let failureWithStderr = Self.failureMessage(
                base:
                    zeroStdoutFailure
                    ?? self.pendingRuntimeFailureMessage(runID: runID),
                terminationStatus: effectiveTerminationStatus,
                stderrTail: activity.stderrTailText())
            guard let formalTermination = self.recordFormalTermination(
                process: proc,
                runID: runID,
                status: effectiveTerminationStatus,
                failureMessage: failureWithStderr)
            else { return }
            self.emitFormalTermination(
                formalTermination,
                eventFence: eventFence,
                onEvent: onEvent)
            }
        }

        var launchError: Error?
        var launchAllowed = false
        lock.lock()
        if lifecycleRunID == runID, lifecyclePhase == .running {
            launchAllowed = true
            self.process = process
            activeCancellationContext = cancellationContext
            do {
                // Hold the lifecycle lock across the short spawn call. A
                // concurrent cancel therefore happens either before launch
                // (attempt 2 is refused) or after the Process is genuinely
                // running (terminate() can signal that real process).
                try process.run()
                runtimeGovernorLeaseHasSpawnedProcess = true
            } catch {
                launchError = error
            }
        }
        lock.unlock()

        guard launchAllowed else {
            try? stdoutWriteHandle.close()
            try? stderrWriteHandle.close()
            try? logHandle?.close()
            launchCommand.cleanupOwnedTemporaryFiles()
            if let result = formalizeCompletedBridgeHandoff(runID: runID) {
                endNoNapActivity(for: runID)
                emitFormalTermination(result, eventFence: eventFence, onEvent: onEvent)
            }
            return
        }

        if let error = launchError {
            thinkingHeartbeat.stop()
            try? stdoutWriteHandle.close()
            try? stderrWriteHandle.close()
            try? logHandle?.close()
            self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "spawn-failure", extra: ["error": error.localizedDescription])
            if retryAfterLaunchFailure(
                process: process,
                command: command,
                runID: runID,
                activityTurnID: activityTurnID,
                attempt: attempt,
                authorityIdentity: authorityIdentity,
                eventFence: eventFence,
                onEvent: onEvent)
            {
                return
            }
            let result = recordFormalTermination(
                process: process,
                runID: runID,
                status: -1,
                failureMessage: error.localizedDescription)
            endNoNapActivity(for: runID)
            launchCommand.cleanupOwnedTemporaryFiles()
            if let result {
                emitFormalTermination(
                    result,
                    eventFence: eventFence,
                    onEvent: onEvent)
            }
            return
        }

        do {
            try runnerAuthority?.attach(
                identity: authorityIdentity,
                launch: ChatRunnerLaunchIdentity(
                    pid: process.processIdentifier,
                    executablePath: process.executableURL?.path
                        ?? resolvedExecutable,
                    argvDigest: ChatRunnerLaunchIdentity.digest(
                        executable: resolvedExecutable,
                        arguments: launchCommand.arguments),
                    launchShape: launchShape,
                    launchctlLabel: launchctlLabel,
                    uid: getuid()))
        } catch {
            thinkingHeartbeat.stop()
            let message = "runner-authority-attach-failed"
            _ = recordPendingRuntimeFailure(message, runID: runID)
            requestBoundedTermination(
                of: process,
                runID: runID,
                attempt: attempt,
                reason: message)
            return
        }

        // Install liveness/output sources immediately after launch. Receipt IO
        // is diagnostic and can be slow under office-scale disk pressure; it
        // must not create a blind window where a live child has no poller or
        // watchdog yet.
        thinkingHeartbeat.start { timer in
            self.installActivatedTimer(
                timer,
                for: process,
                slot: .waitingHeartbeat)
        }
        startOutputPoller(
            for: process,
            drain: drainStreamEvents)
        startNoOutputWatchdog(
            for: process,
            command: launchCommand,
            activity: activity,
            runID: runID)
        startHardTurnTimeout(
            for: process,
            activity: activity,
            runID: runID,
            attempt: attempt)
        startBridgeCheckpointIfNeeded(
            for: process,
            command: launchCommand,
            activity: activity,
            attempt: attempt,
            runID: runID,
            activityTurnID: activityTurnID,
            bridgeRetryState: bridgeRetryState,
            streamEventGate: streamEventGate,
            eventFence: eventFence,
            onEvent: onEvent)
        startZeroByteFailFastIfNeeded(
            for: process,
            command: launchCommand,
            activity: activity,
            attempt: attempt,
            runID: runID,
            launchShape: launchShape)
        self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "spawn", extra: [
            "pid": "\(process.processIdentifier)",
            "executable": TatwoChatCommandPlanner.redacted(process.executableURL?.path ?? ""),
            "argc": "\(launchCommand.arguments.count)",
            "stdinDevNull": "\(launchCommand.standardInputFromDevNull)",
            "stdinBytes":
                "\(launchCommand.standardInputUTF8?.utf8.count ?? 0)",
            "foregroundScheduling": "\(launchCommand.requiresForegroundScheduling)",
            "commandMode": launchCommand.commandMode.rawValue,
            "runtimeAdapter": launchCommand.runtimeAdapter.rawValue,
            "launchShape": launchShape,
            "alreadyBridged": "\(launchCommand.isAlreadyBridged)",
            "automaticBridgeRetryCount":
                "\(launchCommand.automaticBridgeRetryPolicy.automaticRetryCount)",
            "bridgeRetryAuditID":
                launchCommand.automaticBridgeRetryPolicy.auditID,
            "launchctlLabel": launchctlLabel ?? "",
            "detachedBoundary": "\(shouldUseProcessBoundaryForCurrentSurface)",
            "resolvedExecutable": TatwoChatCommandPlanner.redacted(baseResolvedExecutable),
            "cwd": TatwoChatCommandPlanner.redacted(launchCommand.workingDirectory.path),
            "codexHome": TatwoChatCommandPlanner.redacted(launchEnvironment["CODEX_HOME"] ?? ""),
            "tmpdirSet": "\(launchEnvironment["TMPDIR"]?.isEmpty == false)"
        ])
        if let standardInputUTF8 = launchCommand.standardInputUTF8 {
            let inputHandle = input.fileHandleForWriting
            let inputData = Data(standardInputUTF8.utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                try? inputHandle.write(contentsOf: inputData)
                try? inputHandle.close()
            }
        } else if !launchCommand.standardInputFromDevNull {
            try? input.fileHandleForWriting.close()
        }
    }

    private func retryAfterLaunchFailure(
        process: Process,
        command: ChatCLICommand,
        runID: String,
        activityTurnID: String?,
        attempt: Int,
        authorityIdentity: ChatRunnerAttemptIdentity,
        eventFence: ChatCLIRuntimeEventFence,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> Bool {
        guard attempt == 1, isEligibleForSpawnRetry(runID: runID)
        else { return false }

        lock.lock()
        guard lifecycleRunID == runID,
              lifecyclePhase == .running,
              self.process === process
        else {
            lock.unlock()
            return false
        }
        self.process = nil
        if activeCancellationContext?.process === process {
            activeCancellationContext = nil
        }
        lock.unlock()

        appendSpawnReceipt(
            runID: runID,
            attempt: attempt,
            event: "spawn-retry",
            extra: ["reason": "process-launch-failure"])
        eventFence.emitNonterminalEvent {
            onEvent(.diagnostic(
                "spawn_retry=1 reason=process_launch_failure"))
        }
        spawn(
            command: command,
            runID: runID,
            activityTurnID: activityTurnID,
            attempt: 2,
            // Process.run() failed before any PID was attached, so this is a
            // second physical launch of the same durable authority attempt,
            // not an authority rollover to a new process attempt.
            authorityIdentity: authorityIdentity,
            onEvent: onEvent)
        return true
    }

    // B7 (chat-goalrun-20260708-0935): one evidence-gated retry when a
    // chat-mode `codex exec` turn matches the exact stall signature
    // captured in that loop's diagnostics — stderr gets ordinary startup
    // warnings but stdout stays at 0 bytes well past the point every
    // successful terminal/Process repro had already streamed a
    // `thread.started`/`turn.started` event. Re-launching the identical
    // argv through an intermediate `/bin/zsh -c 'exec "$@"' -- ...` hop is
    // the smallest available change to the process's ancestry/session
    // shape without touching argv content (see
    // TatwoChatCommandPlanner.zeroByteBridgeLaunch: every argument stays a
    // distinct `$@` element, so no shell injection risk from prompt text).
    // This is not a confirmed fix — it is the next testable lane after
    // B4-B6 ruled out argv quoting, the `env` hop, App Nap/QoS, and
    // shell-snapshot forking. Fires at most once per turn.
    private func startBridgeCheckpointIfNeeded(
        for process: Process,
        command: ChatCLICommand,
        activity: ChatCLIProcessActivity,
        attempt: Int,
        runID: String,
        activityTurnID: String?,
        bridgeRetryState: ChatCLIBridgeRetryState,
        streamEventGate: ChatCLIStreamEventGate,
        eventFence: ChatCLIRuntimeEventFence,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) {
        guard attempt == 1 else { return }
        guard command.commandMode == .chat, command.runtimeAdapter == .codexExec else { return }
        guard command.automaticBridgeRetryPolicy.automaticRetryCount == 1 else {
            self.appendSpawnReceipt(
                runID: runID,
                attempt: attempt,
                event: "bridge-checkpoint-skipped",
                extra: [
                    "reason": "automatic-retry-policy-zero",
                    "retryAuditID":
                        command.automaticBridgeRetryPolicy.auditID
                ])
            return
        }
        guard !command.isAlreadyBridged else {
            self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "bridge-checkpoint-skipped", extra: [
                "reason": "already-bridged",
                "stdoutBytes": "\(activity.stdoutByteCount())"
            ])
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + TatwoChatCommandPlanner.zeroByteBridgeCheckpoint)
        timer.setEventHandler { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            var retryArmed = false
            streamEventGate.sync {
                // Re-check zero-byte state while excluding the poller and
                // finalizer. The decision now linearizes either before an
                // entire attempt-1 event batch or after it, never mid-batch.
                let elapsed = activity.elapsedSinceStart()
                let shouldBridge = TatwoChatCommandPlanner.shouldArmZeroByteBridgeRetry(
                    mode: command.commandMode,
                    runtimeAdapter: command.runtimeAdapter,
                    attempt: attempt,
                    alreadyBridged: command.isAlreadyBridged,
                    stdoutByteCount: activity.stdoutByteCount(),
                    elapsedSinceStart: elapsed,
                    retryPolicy: command.automaticBridgeRetryPolicy)
                guard shouldBridge else {
                    self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "bridge-checkpoint-fired-skip", extra: [
                        "elapsedSeconds": "\(Int(elapsed))",
                        "stdoutBytes": "\(activity.stdoutByteCount())",
                        "alreadyBridged": "\(command.isAlreadyBridged)"
                    ])
                    return
                }
                guard self.ownsRunningProcess(process, runID: runID) else { return }
                // Bridge the resolved absolute executable actually spawned
                // above (process.executableURL), not command.executable, so a
                // bare-name fallback (the /usr/bin/env path) cannot
                // accidentally re-resolve differently on the retry.
                let bridge = TatwoChatCommandPlanner.zeroByteBridgeLaunch(
                    executable: process.executableURL?.path ?? command.executable,
                    arguments: process.arguments ?? command.arguments)
                let bridgedCommand = command.bridged(
                    executable: bridge.executable,
                    arguments: bridge.arguments)
                bridgeRetryState.armRetry { [weak self] expectedPrior in
                    guard let self else { return }
                    guard let retryIdentity = self.claimAuthorityIdentity(
                        runID: runID,
                        attempt: 2,
                        expectedPrior: expectedPrior)
                    else {
                        self.endNoNapActivity(for: runID)
                        if let result = self.recordFormalTermination(
                            process: nil,
                            runID: runID,
                            status: -1,
                            failureMessage:
                                "runner-authority-attempt-2-claim-failed")
                        {
                            self.emitFormalTermination(
                                result,
                                eventFence: eventFence,
                                onEvent: onEvent)
                        }
                        return
                    }
                    self.lock.lock()
                    if self.lifecycleRunID == runID,
                       self.lifecyclePhase != .terminated
                    {
                        self.currentAuthorityIdentity = retryIdentity
                    }
                    self.lock.unlock()
                    self.spawn(
                        command: bridgedCommand,
                        runID: runID,
                        activityTurnID: activityTurnID,
                        attempt: 2,
                        authorityIdentity: retryIdentity,
                        onEvent: onEvent)
                }
                guard bridgeRetryState.isArmed else { return }
                retryArmed = true
                self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "bridge-trigger", extra: [
                    "elapsedSeconds": "\(Int(elapsed))",
                    "retryAuditID":
                        command.automaticBridgeRetryPolicy.auditID
                ])
                eventFence.emitNonterminalEvent {
                    onEvent(.diagnostic("Chat route produced zero stdout bytes after \(Int(elapsed))s; retrying once through a shell bridge launch path (B7 zero-byte bridge)."))
                }
            }
            guard retryArmed else { return }
            self.requestBoundedTermination(
                of: process,
                runID: runID,
                attempt: attempt,
                reason: "bridge-handoff")
        }
        let installed = installActivatedTimer(
            timer,
            for: process,
            slot: .bridgeCheckpoint)
        if installed {
            self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "bridge-checkpoint-armed", extra: [
                "checkpointSeconds": "\(Int(TatwoChatCommandPlanner.zeroByteBridgeCheckpoint))",
                "alreadyBridged": "\(command.isAlreadyBridged)",
                "automaticRetryCount":
                    "\(command.automaticBridgeRetryPolicy.automaticRetryCount)",
                "retryAuditID":
                    command.automaticBridgeRetryPolicy.auditID
            ])
        } else {
            // Ultrafast children can exit between timer creation and the
            // identity-checked install. Preserve an explicit receipt rather
            // than making the checkpoint look silently absent.
            self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "bridge-checkpoint-skipped", extra: [
                "reason": "install-rejected",
                "stdoutBytes": "\(activity.stdoutByteCount())",
                "alreadyBridged": "\(command.isAlreadyBridged)"
            ])
        }
    }

    // B9 (chat-goalrun-20260708-0935): the bridge retry (attempt 2) used to
    // rely solely on startNoOutputWatchdog, which allocates a brand-new
    // ChatCLIProcessActivity per spawn() call — so its startupGrace/
    // stallTimeout clock restarts from zero on attempt 2 with no memory that
    // attempt 1 already produced this exact zero-stdout stall once. That let
    // a repeat stall run for up to stallTimeout (600s) before anything
    // surfaced, which is why B8 needed a manual kill instead of the
    // watchdog catching it. This does not add another retry (attempt is
    // fixed at 2 by the caller; no further spawn happens here) — it only
    // recognizes the already-proven stall signature faster on the one retry
    // that is allowed, using the same checkpoint/zero-byte gate as the
    // attempt-1 bridge decision.
    private func startZeroByteFailFastIfNeeded(
        for process: Process,
        command: ChatCLICommand,
        activity: ChatCLIProcessActivity,
        attempt: Int,
        runID: String,
        launchShape: String
    ) {
        guard TatwoChatCommandPlanner.shouldArmZeroByteFailFast(
            mode: command.commandMode,
            runtimeAdapter: command.runtimeAdapter,
            attempt: attempt,
            launchShape: launchShape,
            retryPolicy: command.automaticBridgeRetryPolicy
        ) else { return }
        let isRetryAttempt = attempt == 2
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + TatwoChatCommandPlanner.zeroByteBridgeCheckpoint)
        timer.setEventHandler { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            guard activity.stdoutByteCount() == 0 else { return }
            guard self.process === process else { return }
            guard activity.markWatchdogFiredIfNeeded() else { return }
            let elapsed = Int(activity.elapsedSinceStart())
            self.appendSpawnReceipt(runID: runID, attempt: attempt, event: "zero-byte-fail-fast", extra: [
                "elapsedSeconds": "\(elapsed)",
                "launchShape": launchShape,
                "stdoutBytes": "\(activity.stdoutByteCount())"
            ])
            let launchLabel: String
            if isRetryAttempt {
                launchLabel = "shell-bridge retry"
            } else if launchShape == "launchctl-submit-boundary" {
                launchLabel = "launchctl boundary"
            } else {
                launchLabel = "initial shell-parent launch"
            }
            let message =
                "Chat route produced zero stdout bytes after the \(launchLabel) (\(elapsed)s); stopping instead of waiting for the long stall timeout. Check route/session/quota/auth status before retrying."
            guard self.recordPendingRuntimeFailure(message, runID: runID) else { return }
            self.requestBoundedTermination(
                of: process,
                runID: runID,
                attempt: attempt,
                reason: "zero-byte-fail-fast")
        }
        _ = installActivatedTimer(
            timer,
            for: process,
            slot: .zeroByteFailFast)
    }

    // Best-effort JSONL breadcrumb per spawn/exit/bridge event, written next
    // to the turn's stdout/stderr tail files. Replaces the manual
    // `lsof`/`sample` diagnostic packets B3-B7 needed every loop with
    // something the app captures for every real GUI turn automatically.
    private func appendSpawnReceipt(
        runID: String,
        attempt: Int,
        event: String,
        extra: [String: String]
    ) {
        let url = runtimeRootURL.appendingPathComponent("spawn-\(runID).jsonl")
        appendRuntimeReceipt(
            to: url,
            attempt: attempt,
            event: event,
            extra: extra)
    }

    private func appendMaintenanceReceipt(
        event: String,
        extra: [String: String]
    ) {
        appendRuntimeReceipt(
            to: runtimeRootURL.appendingPathComponent("maintenance.jsonl"),
            attempt: 0,
            event: event,
            extra: extra)
    }

    private func appendRuntimeReceipt(
        to url: URL,
        attempt: Int,
        event: String,
        extra: [String: String]
    ) {
        runtimeReceiptLock.lock()
        defer { runtimeReceiptLock.unlock() }
        // Receipts are explicitly best-effort breadcrumbs; keep the same
        // non-fatal behaviour, just through the shared idempotent path.
        try? prepareRuntimeRootIfNeeded()
        var fields = extra
        fields["ts"] = ISO8601DateFormatter().string(from: Date())
        fields["attempt"] = "\(attempt)"
        fields["event"] = event
        let ordered = ["ts", "attempt", "event"] + extra.keys.sorted()
        let line = "{" + ordered.map { key in
            "\"\(key)\":\"\(fields[key, default: ""].replacingOccurrences(of: "\"", with: "'"))\""
        }.joined(separator: ",") + "}\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // This is the first runner operation that genuinely needs the runtime
    // root to exist, so it is where preparation happens. It is fail-closed:
    // a root that cannot be created aborts the spawn with an auditable
    // error instead of launching a child whose stdout/stderr go nowhere.
    private func prepareStreamFiles(
        runID: String,
        attempt: Int
    ) throws -> (stdout: URL, stderr: URL, status: URL) {
        try prepareRuntimeRootIfNeeded()
        let suffix = attempt > 1 ? "\(runID)-attempt\(attempt)" : runID
        let stdoutURL = runtimeRootURL.appendingPathComponent("stdout-\(suffix).jsonl")
        let stderrURL = runtimeRootURL.appendingPathComponent("stderr-\(suffix).log")
        let statusURL = runtimeRootURL.appendingPathComponent("status-\(suffix).txt")
        do {
            try Self.truncateStreamFiles(stdoutURL, stderrURL, statusURL)
        } catch {
            // A cached "root exists" answer can go stale (tmp reaper,
            // external volume remount). Re-create once, then fail closed.
            try prepareRuntimeRootIfNeeded(force: true)
            try Self.truncateStreamFiles(stdoutURL, stderrURL, statusURL)
        }
        _ = ChatCLILaunchctlCancellationDecision.reset(for: statusURL)
        return (stdoutURL, stderrURL, statusURL)
    }

    private static func truncateStreamFiles(
        _ urls: URL...
    ) throws {
        for url in urls {
            try Data().write(to: url, options: .atomic)
        }
    }

    private static func launchctlChatLabel(runID: String) -> String {
        let safe = runID
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" { return character }
                return "-"
            }
        return "\(TatwoChatCommandPlanner.launchctlChatLabelPrefix)\(String(safe).prefix(48))"
    }

    static func shouldUseDetachedChatProcessBoundary(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // The launchctl/zsh ancestry workarounds were introduced for the old
        // LSUIElement panel/app-agent surface.  The normal Work OS window now
        // launches as a regular foreground macOS app, so keeping a shell parent
        // between the app and `codex exec` reintroduces a slower, harder to
        // reason about process shape.  Use the native direct Process launch for
        // regular Chat windows; keep the detached boundary for panel/agent mode
        // or when a diagnostic env explicitly requests it.
        env["TATWO_ULTRAWORK_FORCE_LAUNCHCTL_CHAT"] == "1"
            || env["TATWO_ULTRAWORK_FORCE_CHAT_BRIDGE"] == "1"
            || env["TATWO_ULTRAWORK_AUTOSHOW_PANEL"] == "1"
            || env["TATWO_ULTRAWORK_DEFAULT_SURFACE"] == "panel"
            || env["TATWO_ULTRAWORK_BUILD_AS_AGENT"] == "1"
    }

    static func shouldUseLaunchctlChatProcessBoundary(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // A real 2026-08-05 control proved the opposite of the old B11
        // assumption on the current foreground App: the same Sol argv
        // completed directly in 8s but stayed at zero stdout for 100s after
        // crossing `launchctl submit`. Keep launchd isolation only for the
        // legacy panel/agent surfaces (or an explicit diagnostic override).
        // A normal Work OS window must use the native Process path.
        env["TATWO_ULTRAWORK_FORCE_LAUNCHCTL_CHAT"] == "1"
            || env["TATWO_ULTRAWORK_AUTOSHOW_PANEL"] == "1"
            || env["TATWO_ULTRAWORK_DEFAULT_SURFACE"] == "panel"
            || env["TATWO_ULTRAWORK_BUILD_AS_AGENT"] == "1"
    }

    private static func processCurrentDirectory(
        for command: ChatCLICommand,
        launchShape: String
    ) -> URL {
        // The model command already receives its real workspace explicitly
        // (`codex exec -C`, gateway script args, or route-specific flags).
        // The Process launcher itself should not need to `getcwd()` inside a
        // user project on `/Volumes`.  Live 2026-07-09 sample showed the
        // launchctl wrapper zsh stuck in setupvals -> getcwd before it even
        // submitted the job, leaving Chat at zero stdout/stderr.  Keep shell
        // wrappers in local tmp; preserve native cwd for non-wrapper routes.
        if launchShape == "launchctl-submit-boundary"
            || launchShape == "bridge-parent-initial"
            || launchShape == "bridge-parent-retry" {
            return FileManager.default.temporaryDirectory
        }
        return command.workingDirectory
    }

    private func scheduleRuntimeMaintenance(reason: String) {
        guard runtimeSweepGate.begin() == .started else { return }
        let root = runtimeRootURL
        let retentionPolicy = runtimeRetentionPolicy
        let gate = runtimeSweepGate
        let launcher = runtimeSweepLauncher
        let authorityRecorder = runnerAuthority
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Durable authority discovery reads the on-disk runner registry,
            // which lives under the same (possibly external) state root. It
            // must not run on the caller's thread: `scheduleRuntimeMaintenance`
            // is invoked from init and from `start`, both of which can be on
            // MainActor.
            let authority =
                authorityRecorder?.discoverRunnerAuthority()
                ?? .unknown(reason: "durable-runner-authority-unavailable")
            let retiredPromptFiles =
                ChatCLITemporaryFileOwner.cleanupStaleGatewayPromptFiles()
            let retired = ChatCLIRuntimeArtifactRetirement.retireReclaimableArtifacts(
                in: root,
                authority: authority,
                policy: retentionPolicy)
            self?.appendMaintenanceReceipt(
                event: "launchctl-stale-sweep-start",
                extra: [
                    "reason": reason,
                    "retiredArtifacts": "\(retired)",
                    "retiredPromptFiles": "\(retiredPromptFiles)"
                ])
            launcher(root, reason) { [weak self] in
                self?.appendMaintenanceReceipt(
                    event: "launchctl-stale-sweep-finished",
                    extra: ["reason": reason])
                gate.complete()
            }
        }
    }

    private static func launchStaleSweep(
        root: URL,
        reason _: String,
        completion: @escaping @Sendable () -> Void
    ) {
        let sweep = TatwoChatCommandPlanner.launchctlSubmitStaleJobSweepLaunch(
            rootPath: root.path,
            uid: "\(getuid())",
            currentAppPID: "\(getpid())")
        let process = Process()
        let nullInput = FileHandle(forReadingAtPath: "/dev/null")
        let nullOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.executableURL = URL(fileURLWithPath: sweep.executable)
        process.arguments = sweep.arguments
        if let nullInput { process.standardInput = nullInput }
        if let nullOutput {
            process.standardOutput = nullOutput
            process.standardError = nullOutput
        }
        process.terminationHandler = { _ in
            try? nullInput?.close()
            try? nullOutput?.close()
            completion()
        }
        do {
            try process.run()
        } catch {
            try? nullInput?.close()
            try? nullOutput?.close()
            completion()
        }
    }

    private static func launchctlSubmittedEnvironmentArguments(
        launchEnvironment: [String: String],
        executable: String,
        arguments: [String]
    ) -> [String] {
        let keys = [
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "PATH",
            "TMPDIR",
            "TMP",
            "TEMP",
            "LANG",
            "LC_CTYPE",
            "CODEX_HOME",
            "CODEX_INSTALL_DIR",
            "SSH_AUTH_SOCK"
        ]
        let envPairs = keys.compactMap { key -> String? in
            guard let value = launchEnvironment[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        return envPairs + [executable] + arguments
    }

    private static func cliLaunchEnvironment(base: [String: String]) -> [String: String] {
        // Chat subprocesses are user-facing model routes, not descendants of
        // the Codex thread / SwiftPM / GUI environment that happened to launch
        // Tatwo during development.  In live validation, inheriting a broad app
        // env while forcing `CODEX_HOME` onto an external-volume CLI home could leave
        // `codex exec` stalled with zero stdout from the GUI, while the same
        // argv completed in seconds from a clean terminal/minimal env.  Build a
        // small terminal-like allowlist instead of trying to scrub an unbounded
        // parent environment.
        var env: [String: String] = [:]
        let home = base["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()

        let pathSegments = [
            "/Applications/Codex.app/Contents/Resources",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPath = base["PATH"] ?? ""
        var seen = Set<String>()
        let mergedPath = (pathSegments + existingPath.split(separator: ":").map(String.init))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { segment in
                if seen.contains(segment) { return false }
                seen.insert(segment)
                return true
            }
            .joined(separator: ":")
        env["PATH"] = mergedPath
        env["HOME"] = home
        env["USER"] = base["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        env["LOGNAME"] = base["LOGNAME"].flatMap { $0.isEmpty ? nil : $0 } ?? env["USER"]
        env["SHELL"] = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        env["TMPDIR"] = base["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        env["TMP"] = base["TMP"].flatMap { $0.isEmpty ? nil : $0 } ?? env["TMPDIR"]
        env["TEMP"] = base["TEMP"].flatMap { $0.isEmpty ? nil : $0 } ?? env["TMPDIR"]
        if let lang = base["LANG"], !lang.isEmpty { env["LANG"] = lang }
        if let lcCType = base["LC_CTYPE"], !lcCType.isEmpty { env["LC_CTYPE"] = lcCType }
        if let sshAuthSock = base["SSH_AUTH_SOCK"], !sshAuthSock.isEmpty { env["SSH_AUTH_SOCK"] = sshAuthSock }

        // Resolve CODEX_HOME for the spawned Codex CLI WITHOUT the app itself
        // stat'ing a /Volumes path. A fileExists() on an external volume triggers
        // the macOS removable-volume permission dialog; the spawned `codex` process
        // has its own access and handles a missing home. Prefer the inherited
        // CODEX_HOME (app main() already normalizes it to ~/.codex, which resolves
        // to the same external CliHome via symlink), else fall back to ~/.codex, and
        // only name the external CliHome as a last resort — as a plain env string,
        // never a stat.
        if let inheritedCodexHome = base["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !inheritedCodexHome.isEmpty {
            env["CODEX_HOME"] = inheritedCodexHome
        } else {
            let homeCodex = URL(fileURLWithPath: home).appendingPathComponent(".codex").path
            env["CODEX_HOME"] = homeCodex
        }
        if let installDir = base["CODEX_INSTALL_DIR"], !installDir.isEmpty { env["CODEX_INSTALL_DIR"] = installDir }
        return env
    }

    private static func shouldScrubInheritedCLIEnvironmentKey(_ key: String) -> Bool {
        if key.hasPrefix("XPC_") || key.hasPrefix("__CF") { return true }
        if key.hasPrefix("CODEX_") {
            return key != "CODEX_HOME" && key != "CODEX_INSTALL_DIR"
        }
        return [
            "COMMAND_MODE",
            "LOG_FORMAT"
        ].contains(key)
    }

    private func startNoOutputWatchdog(
        for process: Process,
        command: ChatCLICommand,
        activity: ChatCLIProcessActivity,
        runID: String
    ) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.watchdogPollInterval, repeating: Self.watchdogPollInterval)
        timer.setEventHandler { [weak process] in
            guard let process, process.isRunning else { return }
            self.heartbeatAuthority(runID: runID)

            // Startup/no-assistant grace: a route with zero bytes yet, or
            // only stderr startup noise, still gets a full startupGrace
            // window before anything is treated as a problem.
            let failureMessage = self.watchdogPolicy.failureMessage(
                elapsedSinceStart: activity.elapsedSinceStart(),
                idleInterval: activity.idleInterval(),
                hasAssistantVisibleOutput: activity.hasAssistantVisibleOutput(),
                lastLine: activity.lastLine())
            guard let failureMessage else { return }

            guard activity.markWatchdogFiredIfNeeded() else { return }
            guard self.recordPendingRuntimeFailure(failureMessage, runID: runID) else { return }
            self.requestBoundedTermination(
                of: process,
                runID: runID,
                reason: "stall-watchdog")
        }
        _ = installActivatedTimer(
            timer,
            for: process,
            slot: .watchdog)
    }

    /// M3a 更新：聊天 CLI 單回合硬上限。這與「無輸出 watchdog」分開，
    /// 即使模型持續輸出也不得無限佔用一個 turn。
    private func startHardTurnTimeout(
        for process: Process,
        activity: ChatCLIProcessActivity,
        runID: String,
        attempt: Int
    ) {
        lock.lock()
        let deadline = hardTurnDeadline
        lock.unlock()
        let remaining = max(
            0.05,
            deadline?.timeIntervalSinceNow ?? hardTurnTimeout)
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + remaining)
        timer.setEventHandler { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            guard self.ownsRunningProcess(process, runID: runID) else { return }
            guard activity.markWatchdogFiredIfNeeded() else { return }
            let message =
                "Chat CLI turn timed out after \(Int(self.hardTurnTimeout)) seconds."
            guard self.recordPendingRuntimeFailure(message, runID: runID)
            else { return }
            self.appendSpawnReceipt(
                runID: runID,
                attempt: attempt,
                event: "hard-turn-timeout",
                extra: [
                    "timeoutSeconds": "\(self.hardTurnTimeout)"
                ])
            self.requestBoundedTermination(
                of: process,
                runID: runID,
                attempt: attempt,
                reason: "hard-turn-timeout")
        }
        _ = installActivatedTimer(
            timer,
            for: process,
            slot: .hardTimeout)
    }

    private func ownsRunningProcess(_ process: Process, runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.process === process
            && process.isRunning
            && lifecycleRunID == runID
            && lifecyclePhase == .running
    }

    private func startOutputPoller(
        for process: Process,
        drain: @escaping @Sendable () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + outputPollPolicy.initialDelay,
            repeating: outputPollPolicy.repeatInterval)
        timer.setEventHandler { [weak process] in
            guard let process, process.isRunning else { return }
            drain()
        }
        _ = installActivatedTimer(
            timer,
            for: process,
            slot: .outputPoller)
    }

    /// Dispatch sources are created suspended. A very short-lived child can
    /// terminate between source creation and slot installation; allowing that
    /// suspended source to leave scope can trap in libdispatch. Activate first,
    /// then either publish it under the process-identity lock or cancel it.
    @discardableResult
    private func installActivatedTimer(
        _ timer: DispatchSourceTimer,
        for process: Process,
        slot: TimerSlot
    ) -> Bool {
        timer.activate()
        var replaced: DispatchSourceTimer?
        lock.lock()
        let installed =
            self.process === process
            && process.isRunning
            && lifecyclePhase == .running
        if installed {
            switch slot {
            case .watchdog:
                replaced = watchdog
                watchdog = timer
            case .hardTimeout:
                replaced = hardTimeoutTimer
                hardTimeoutTimer = timer
            case .outputPoller:
                replaced = outputPoller
                outputPoller = timer
            case .bridgeCheckpoint:
                replaced = bridgeCheckpoint
                bridgeCheckpoint = timer
            case .zeroByteFailFast:
                replaced = zeroByteFailFast
                zeroByteFailFast = timer
            case .waitingHeartbeat:
                replaced = waitingHeartbeat
                waitingHeartbeat = timer
            }
        }
        lock.unlock()
        replaced?.cancel()
        if !installed {
            timer.cancel()
        }
        return installed
    }

    private func cancelWatchdog(for process: Process? = nil) {
        lock.lock()
        let shouldCancel = process == nil || self.process === process
        let timer = shouldCancel ? watchdog : nil
        if shouldCancel { watchdog = nil }
        lock.unlock()
        timer?.cancel()
    }

    private func cancelHardTimeout(for process: Process? = nil) {
        lock.lock()
        let shouldCancel = process == nil || self.process === process
        let timer = shouldCancel ? hardTimeoutTimer : nil
        if shouldCancel { hardTimeoutTimer = nil }
        lock.unlock()
        timer?.cancel()
    }

    private func cancelOutputPoller(for process: Process? = nil) {
        lock.lock()
        let shouldCancel = process == nil || self.process === process
        let timer = shouldCancel ? outputPoller : nil
        if shouldCancel { outputPoller = nil }
        lock.unlock()
        timer?.cancel()
    }

    private func cancelBridgeCheckpoint(for process: Process? = nil) {
        lock.lock()
        let shouldCancel = process == nil || self.process === process
        let timer = shouldCancel ? bridgeCheckpoint : nil
        if shouldCancel { bridgeCheckpoint = nil }
        lock.unlock()
        timer?.cancel()
    }

    private func cancelZeroByteFailFast(for process: Process? = nil) {
        lock.lock()
        let shouldCancel = process == nil || self.process === process
        let timer = shouldCancel ? zeroByteFailFast : nil
        if shouldCancel { zeroByteFailFast = nil }
        lock.unlock()
        timer?.cancel()
    }

    private func cancelWaitingHeartbeat(for process: Process? = nil) {
        lock.lock()
        let shouldCancel = process == nil || self.process === process
        let timer = shouldCancel ? waitingHeartbeat : nil
        if shouldCancel { waitingHeartbeat = nil }
        lock.unlock()
        timer?.cancel()
    }

    private func requestBoundedTermination(
        of process: Process,
        runID: String,
        attempt: Int = 0,
        processAlreadyExited: Bool = false,
        reason: String
    ) {
        // A final drain/flush runs after Process delivered its termination
        // callback. Keep that post-exit fact explicit at the signal boundary:
        // a late structured failure may still be parsed, but it must never
        // schedule another TERM/INT/KILL sequence for an already-dead child.
        guard !processAlreadyExited else { return }
        guard process.isRunning else { return }
        let parentPID = process.processIdentifier
        guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(parentPID) else {
            appendSpawnReceipt(
                runID: runID,
                attempt: attempt,
                event: "termination-blocked",
                extra: [
                    "pid": "\(parentPID)",
                    "reason": "unsafe-parent-pid"
                ])
            return
        }

        lock.lock()
        let cancellationContext =
            activeCancellationContext?.process === process
                ? activeCancellationContext
                : nil
        lock.unlock()
        if let cancellationContext,
           !ensureCancellationDecisionBeforeSignal(
                context: cancellationContext,
                reason: reason)
        {
            return
        }
        cancellationContext?.requireOwnedDescendantProof()
        let descendantCapture =
            cancellationContext?.captureOwnedDescendants()
            ?? .blocked(
                knownDescendants: [],
                reason: "active-cancellation-context-unavailable")
        let ownedDescendants: [ChatCLIOwnedProcessIdentity]
        switch descendantCapture {
        case .captured(let descendants):
            ownedDescendants = descendants
        case .blocked(let knownDescendants, let captureReason):
            appendSpawnReceipt(
                runID: runID,
                attempt: attempt,
                event: "owned-descendant-capture-blocked",
                extra: [
                    "pid": "\(parentPID)",
                    "reason": captureReason,
                    "knownDescendantCount": "\(knownDescendants.count)"
                ])
            if let cancellationContext {
                markCancellationConvergenceBlocked(
                    context: cancellationContext,
                    reason: "owned-descendant-capture-blocked:\(captureReason)")
            }
            return
        }
        if !ownedDescendants.isEmpty {
            cancellationContext?.requireConvergenceBudgetThroughForcedKill(
                delay:
                    ChatCLIProcessTerminationPolicy.forceKillDelay
                        + ChatCLIProcessTerminationPolicy.forceKillProofMargin)
        }

        process.terminate()
        for descendant in ownedDescendants.reversed() {
            _ = ChatCLIOwnedDescendantCapture.signal(
                SIGTERM,
                to: descendant)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + ChatCLIProcessTerminationPolicy.interruptDelay
        ) { [weak process] in
            for descendant in ownedDescendants.reversed() {
                _ = ChatCLIOwnedDescendantCapture.signal(
                    SIGINT,
                    to: descendant)
            }
            guard let process,
                  process.isRunning,
                  ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(
                    process.processIdentifier)
            else { return }
            process.interrupt()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + ChatCLIProcessTerminationPolicy.forceKillDelay
        ) { [weak process] in
            var descendantKillCount = 0
            for descendant in ownedDescendants.reversed() {
                if ChatCLIOwnedDescendantCapture.signal(
                    SIGKILL,
                    to: descendant) != nil
                {
                    descendantKillCount += 1
                }
            }
            guard let process, process.isRunning else { return }
            let pid = process.processIdentifier
            guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(pid) else {
                return
            }
            let result = Darwin.kill(pid, SIGKILL)
            self.appendSpawnReceipt(
                runID: runID,
                attempt: attempt,
                event: "forced-kill",
                extra: [
                    "pid": "\(pid)",
                    "reason": reason,
                    "signalResult": "\(result)",
                    "ownedDescendantSignalCount": "\(descendantKillCount)"
                ])
        }
        if let cancellationContext {
            ensureCancellationConvergenceScheduled(
                context: cancellationContext)
        }
    }

    private func ensureCancellationConvergenceScheduled(
        context: ChatCLICancellationContext
    ) {
        lock.lock()
        let convergenceIsBlocked: Bool
        if case .blocked = cancellationConvergenceState {
            convergenceIsBlocked = true
        } else {
            convergenceIsBlocked = false
        }
        guard lifecycleRunID == context.runID,
              lifecyclePhase == .terminationRequested,
              activeCancellationContext === context,
              process === context.process,
              cancellationConvergenceGeneration == nil,
              !convergenceIsBlocked
        else {
            lock.unlock()
            return
        }
        let generation = UUID()
        cancellationConvergenceGeneration = generation
        cancellationConvergenceState = .awaitingProbe(attempt: 1)
        lock.unlock()
        scheduleCancellationConvergence(
            context: context,
            generation: generation,
            attempt: 1)
    }

    private func deferCancellationCallbackUntilTerminalProof(
        process: Process,
        context: ChatCLICancellationContext
    ) -> Bool {
        lock.lock()
        let cancellationRequested =
            lifecycleRunID == context.runID
            && lifecyclePhase == .terminationRequested
            && self.process === process
            && activeCancellationContext === context
        lock.unlock()
        guard cancellationRequested else { return false }
        // `terminationRequested` is also used for a structured runtime
        // failure that was discovered during the final post-exit drain. That
        // path never sent a signal and therefore has no descendant proof to
        // wait for; the real Process callback is already the terminal proof.
        guard context.isOwnedDescendantProofRequired() else { return false }

        let descendantProbes: [ChatCLIWrapperInactivityProbeResult]
        switch context.ownedDescendantCaptureSnapshot() {
        case .captured(let descendants):
            descendantProbes = descendants.map(
                ChatCLIOwnedDescendantCapture.probeInactivity)
        case .blocked(let knownDescendants, let captureReason):
            markCancellationConvergenceBlocked(
                context: context,
                reason: "owned-descendant-capture-blocked:\(captureReason)")
            appendSpawnReceipt(
                runID: context.runID,
                attempt: context.attempt,
                event: "cancellation-callback-deferred",
                extra: [
                    "reason":
                        "owned-descendant-capture-blocked:\(captureReason)",
                    "knownDescendantCount": "\(knownDescendants.count)"
                ])
            return true
        case nil:
            markCancellationConvergenceBlocked(
                context: context,
                reason: "owned-descendant-capture-missing")
            appendSpawnReceipt(
                runID: context.runID,
                attempt: context.attempt,
                event: "cancellation-callback-deferred",
                extra: ["reason": "owned-descendant-capture-missing"])
            return true
        }

        let decision = ChatCLICancellationConvergenceEvaluator.decide(
            wrapper: wrapperInactivityProbe(process.processIdentifier),
            ownedDescendants: descendantProbes,
            launchBoundary: context.launchBoundary,
            launchctlProbe: launchctlLabelProbe)
        switch decision {
        case .converged:
            return false
        case .retry(let reason):
            appendSpawnReceipt(
                runID: context.runID,
                attempt: context.attempt,
                event: "cancellation-callback-deferred",
                extra: ["reason": reason])
            ensureCancellationConvergenceScheduled(context: context)
            return true
        case .blocked(let reason):
            appendSpawnReceipt(
                runID: context.runID,
                attempt: context.attempt,
                event: "cancellation-callback-deferred",
                extra: ["reason": reason])
            markCancellationConvergenceBlocked(
                context: context,
                reason: reason)
            return true
        }
    }

    static func probeWrapperInactivity(
        pid: pid_t
    ) -> ChatCLIWrapperInactivityProbeResult {
        guard ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(pid) else {
            return .unknown(reason: "unsafe-pid")
        }
        errno = 0
        if Darwin.kill(pid, 0) == 0 {
            return .active
        }
        switch errno {
        case ESRCH:
            return .inactive
        case EPERM:
            return .unknown(reason: "permission-denied")
        default:
            return .unknown(reason: "kill-zero-errno-\(errno)")
        }
    }

    static func probeLaunchctlLabel(
        label: String,
        uid: uid_t
    ) -> ChatCLILaunchctlLabelProbeResult {
        guard !label.isEmpty else {
            return .unknown(reason: "empty-label")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(uid)/\(label)"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return .unknown(reason: "launchctl-start-failed")
        }

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            let pid = process.processIdentifier
            if ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(pid) {
                _ = Darwin.kill(pid, SIGKILL)
            }
            return .unknown(reason: "launchctl-probe-timeout")
        }
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
            .lowercased()
        if process.terminationStatus == 0 {
            return .present
        }
        if text.contains("could not find service")
            || text.contains("could not find specified service")
        {
            return .absent
        }
        return .unknown(reason: "launchctl-print-exit-\(process.terminationStatus)")
    }

    private func scheduleCancellationConvergence(
        context: ChatCLICancellationContext,
        generation: UUID,
        attempt: Int,
        minimumDelay: TimeInterval = 0
    ) {
        let policyDelay = attempt == 1
            ? cancellationConvergencePolicy.initialDelay
            : cancellationConvergencePolicy.retryInterval
        let delay = max(policyDelay, minimumDelay)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, delay)
        ) { [weak self] in
            self?.evaluateCancellationConvergence(
                context: context,
                generation: generation,
                attempt: attempt)
        }
    }

    private func evaluateCancellationConvergence(
        context: ChatCLICancellationContext,
        generation: UUID,
        attempt: Int
    ) {
        lock.lock()
        let stillOwnsCancellation =
            cancellationConvergenceGeneration == generation
            && lifecycleRunID == context.runID
            && lifecyclePhase == .terminationRequested
            && activeCancellationContext === context
            && process === context.process
        if stillOwnsCancellation {
            cancellationConvergenceState = .awaitingProbe(attempt: attempt)
        }
        lock.unlock()
        guard stillOwnsCancellation else { return }

        let descendantProbes: [ChatCLIWrapperInactivityProbeResult]
        switch context.ownedDescendantCaptureSnapshot() {
        case .captured(let descendants):
            descendantProbes = descendants.map(
                ChatCLIOwnedDescendantCapture.probeInactivity)
        case .blocked(_, let reason):
            markCancellationConvergenceBlocked(
                context: context,
                generation: generation,
                reason: "owned-descendant-capture-blocked:\(reason)")
            return
        case nil:
            markCancellationConvergenceBlocked(
                context: context,
                generation: generation,
                reason: "owned-descendant-capture-missing")
            return
        }
        let decision = ChatCLICancellationConvergenceEvaluator.decide(
            wrapper: wrapperInactivityProbe(context.process.processIdentifier),
            ownedDescendants: descendantProbes,
            launchBoundary: context.launchBoundary,
            launchctlProbe: launchctlLabelProbe)
        switch decision {
        case .converged:
            let state = ChatCLICancellationConvergenceState
                .terminalByAuthoritativeInactivity(status: 143)
            guard let result = recordFormalTermination(
                process: context.process,
                runID: context.runID,
                status: 143,
                convergenceState: state)
            else { return }
            endNoNapActivity(for: context.runID)
            context.command.cleanupOwnedTemporaryFiles()
            self.appendSpawnReceipt(
                runID: context.runID,
                attempt: context.attempt,
                event: "cancellation-converged",
                extra: [
                    "status": "143",
                    "proof": "wrapper-and-owned-descendants-inactive-and-boundary-absent"
                ])
            emitFormalTermination(
                result,
                eventFence: context.eventFence,
                onEvent: context.onEvent)
        case .retry(let reason):
            guard attempt < max(1, cancellationConvergencePolicy.maxAttempts) else {
                let remainingKillProofDelay =
                    context.remainingConvergenceExhaustionDelay()
                if remainingKillProofDelay > 0 {
                    // A retained descendant may intentionally ignore TERM/INT.
                    // Do not exhaust the bounded probe budget before the exact
                    // identity-bound SIGKILL fallback has had time to run.
                    scheduleCancellationConvergence(
                        context: context,
                        generation: generation,
                        attempt: attempt,
                        minimumDelay: remainingKillProofDelay)
                    return
                }
                markCancellationConvergenceBlocked(
                    context: context,
                    generation: generation,
                    reason: "bounded-probe-exhausted:\(reason)")
                return
            }
            lock.lock()
            let shouldRetry =
                cancellationConvergenceGeneration == generation
                && lifecycleRunID == context.runID
                && lifecyclePhase == .terminationRequested
                && activeCancellationContext === context
            if shouldRetry {
                cancellationConvergenceState = .awaitingProbe(attempt: attempt + 1)
            }
            lock.unlock()
            guard shouldRetry else { return }
            scheduleCancellationConvergence(
                context: context,
                generation: generation,
                attempt: attempt + 1)
        case .blocked(let reason):
            markCancellationConvergenceBlocked(
                context: context,
                generation: generation,
                reason: reason)
        }
    }

    private func markCancellationConvergenceBlocked(
        context: ChatCLICancellationContext,
        generation: UUID,
        reason: String
    ) {
        lock.lock()
        guard cancellationConvergenceGeneration == generation,
              lifecycleRunID == context.runID,
              lifecyclePhase == .terminationRequested,
              activeCancellationContext === context
        else {
            lock.unlock()
            return
        }
        cancellationConvergenceGeneration = nil
        cancellationConvergenceState = .blocked(reason: reason)
        lock.unlock()
        self.appendSpawnReceipt(
            runID: context.runID,
            attempt: context.attempt,
            event: "cancellation-convergence-blocked",
            extra: ["reason": reason])
        publishBlockedTerminalFailureIfWrapperExited(
            context: context,
            reason: reason)
    }

    private func markCancellationConvergenceBlocked(
        context: ChatCLICancellationContext,
        reason: String
    ) {
        lock.lock()
        guard lifecycleRunID == context.runID,
              lifecyclePhase == .terminationRequested,
              activeCancellationContext === context
        else {
            lock.unlock()
            return
        }
        cancellationConvergenceGeneration = nil
        cancellationConvergenceState = .blocked(reason: reason)
        lock.unlock()
        self.appendSpawnReceipt(
            runID: context.runID,
            attempt: context.attempt,
            event: "cancellation-convergence-blocked",
            extra: ["reason": reason])
        publishBlockedTerminalFailureIfWrapperExited(
            context: context,
            reason: reason)
    }

    private func publishBlockedTerminalFailureIfWrapperExited(
        context: ChatCLICancellationContext,
        reason: String
    ) {
        guard let wrapperExitStatus =
            context.recordedWrapperExitCallbackStatus()
        else {
            // A failed probe alone is not terminal evidence. Only the real
            // Process callback may authorize this user-visible failure seam.
            return
        }
        let signal = ChatCLIBlockedTerminalFailureSignal(
            idempotencyKey:
                "\(context.runID):\(context.attempt):wrapper-exit-convergence-blocked",
            runID: context.runID,
            attempt: context.attempt,
            wrapperExitStatus: wrapperExitStatus,
            convergenceBlockReason: reason,
            authorityRemainsBlocked: true,
            reclaimAllowed: false)

        lock.lock()
        guard lifecycleRunID == context.runID,
              lifecyclePhase == .terminationRequested,
              activeCancellationContext === context,
              blockedTerminalFailureSignal == nil
        else {
            lock.unlock()
            return
        }
        blockedTerminalFailureSignal = signal
        lock.unlock()

        // This is the one externally published terminal outcome for the run.
        // It intentionally does not mark runner authority terminal or clear
        // process ownership. A later proof callback may update internal
        // lifecycle state, but the shared event fence prevents duplication.
        guard context.eventFence.commitFormalTerminal() else { return }
        appendSpawnReceipt(
            runID: context.runID,
            attempt: context.attempt,
            event: "blocked-terminal-failure-signaled",
            extra: [
                "idempotencyKey": signal.idempotencyKey,
                "wrapperExitStatus": "\(wrapperExitStatus)",
                "reason": reason,
                "authorityRemainsBlocked": "true",
                "reclaimAllowed": "false"
            ])
        context.onEvent(.runtimeFailure(signal.message))
    }

    private func requestCancellationTermination(
        context: ChatCLICancellationContext,
        authorityIdentity: ChatRunnerAttemptIdentity?,
        retryingBlockedCapture: Bool,
        reason: String
    ) {
        guard ensureCancellationDecisionBeforeSignal(
            context: context,
            reason: reason)
        else {
            return
        }
        context.requireOwnedDescendantProof()
        switch context.captureOwnedDescendants(
            retryingBlockedCapture: retryingBlockedCapture)
        {
        case .captured:
            break
        case .blocked(let knownDescendants, let captureReason):
            appendSpawnReceipt(
                runID: context.runID,
                attempt: context.attempt,
                event: "owned-descendant-capture-blocked",
                extra: [
                    "pid": "\(context.process.processIdentifier)",
                    "reason": captureReason,
                    "knownDescendantCount": "\(knownDescendants.count)",
                    "retryingBlockedCapture": "\(retryingBlockedCapture)"
                ])
            markCancellationConvergenceBlocked(
                context: context,
                reason: "owned-descendant-capture-blocked:\(captureReason)")
            return
        }

        if let authorityIdentity, let runnerAuthority {
            let authorityResult = runnerAuthority.requestTermination(
                for: authorityIdentity)
            switch authorityResult {
            case .requested:
                appendSpawnReceipt(
                    runID: context.runID,
                    attempt: context.attempt,
                    event: "runner-authority-termination-requested",
                    extra: [:])
            case .formalTerminal(let status):
                appendSpawnReceipt(
                    runID: context.runID,
                    attempt: context.attempt,
                    event: "runner-authority-already-terminal",
                    extra: ["status": "\(status)"])
                ensureCancellationConvergenceScheduled(context: context)
                return
            case .reclaimed(let token):
                appendSpawnReceipt(
                    runID: context.runID,
                    attempt: context.attempt,
                    event: "runner-authority-already-reclaimed",
                    extra: ["revision": "\(token.revision)"])
                ensureCancellationConvergenceScheduled(context: context)
                return
            case .blocked(let authorityReason):
                appendSpawnReceipt(
                    runID: context.runID,
                    attempt: context.attempt,
                    event: "runner-authority-termination-blocked",
                    extra: ["reason": authorityReason])
                markCancellationConvergenceBlocked(
                    context: context,
                    reason:
                        "runner-authority-termination-blocked:\(authorityReason)")
                return
            case .unknown(let authorityReason):
                appendSpawnReceipt(
                    runID: context.runID,
                    attempt: context.attempt,
                    event: "runner-authority-termination-unknown",
                    extra: ["reason": authorityReason])
                markCancellationConvergenceBlocked(
                    context: context,
                    reason:
                        "runner-authority-termination-unknown:\(authorityReason)")
                return
            }
        }

        if context.process.isRunning {
            requestBoundedTermination(
                of: context.process,
                runID: context.runID,
                attempt: context.attempt,
                reason: reason)
        }
        ensureCancellationConvergenceScheduled(context: context)
    }

    private func ensureCancellationDecisionBeforeSignal(
        context: ChatCLICancellationContext,
        reason: String
    ) -> Bool {
        let freezeResult =
            context.freezeFormalSuccessAtCancellation()
        guard freezeResult.launchctlDecisionPersisted else {
            let failureReason =
                "launchctl-cancel-decision-persist-failed:\(reason)"
            _ = recordPendingRuntimeFailure(
                failureReason,
                runID: context.runID)
            appendSpawnReceipt(
                runID: context.runID,
                attempt: context.attempt,
                event: "launchctl-cancel-decision-persist-failed",
                extra: [
                    "reason": reason,
                    "hadFormalSuccess":
                        "\(freezeResult.hasFormalSuccess)"
                ])
            markCancellationConvergenceBlocked(
                context: context,
                reason: failureReason)
            return false
        }
        return true
    }

    func retryBlockedCancellationConvergence() {
        lock.lock()
        guard lifecyclePhase == .terminationRequested,
              case .blocked = cancellationConvergenceState,
              let context = activeCancellationContext
        else {
            lock.unlock()
            return
        }
        let authorityIdentity = currentAuthorityIdentity
        cancellationConvergenceState = .notRequested
        lock.unlock()
        requestCancellationTermination(
            context: context,
            authorityIdentity: authorityIdentity,
            retryingBlockedCapture: true,
            reason: "retry-blocked-cancellation")
    }

    func terminate() {
        lock.lock()
        let proc = process
        let runID = lifecycleRunID ?? "unknown"
        let admissionTask = runtimeGovernorAdmissionTask
        runtimeGovernorAdmissionTask = nil
        let admissionID = runtimeGovernorAdmissionID
        runtimeGovernorAdmissionID = nil
        let wasWaitingForGovernor =
            proc == nil
            && admissionID != nil
            && lifecyclePhase == .running
        let hadUnspawnedGovernorLease =
            proc == nil
            && runtimeGovernorLease != nil
            && !runtimeGovernorLeaseHasSpawnedProcess
            && lifecyclePhase == .running
        let governorLease =
            wasWaitingForGovernor || hadUnspawnedGovernorLease
            ? runtimeGovernorLease
            : nil
        if wasWaitingForGovernor || hadUnspawnedGovernorLease {
            runtimeGovernorLease = nil
            runtimeGovernorLeaseHasSpawnedProcess = false
            hardTurnDeadline = nil
            lifecyclePhase = .terminated
            lifecycleFormalExitStatus = nil
        }
        let authorityIdentity =
            lifecyclePhase == .running || lifecyclePhase == .terminationRequested
                ? currentAuthorityIdentity
                : nil
        if lifecyclePhase == .running {
            lifecyclePhase = .terminationRequested
        }
        let context = activeCancellationContext
        let hasMatchingCancellationContext =
            context != nil && context?.process === proc
        let terminationContextUnavailable =
            lifecyclePhase == .terminationRequested
                && !hasMatchingCancellationContext
        if terminationContextUnavailable {
            cancellationConvergenceGeneration = nil
            cancellationConvergenceState = .blocked(
                reason: "active-cancellation-context-unavailable")
        }
        let timer = watchdog
        watchdog = nil
        let hardTimer = hardTimeoutTimer
        hardTimeoutTimer = nil
        let poller = outputPoller
        outputPoller = nil
        let checkpoint = bridgeCheckpoint
        bridgeCheckpoint = nil
        let failFast = zeroByteFailFast
        zeroByteFailFast = nil
        let heartbeat = waitingHeartbeat
        waitingHeartbeat = nil
        lock.unlock()
        admissionTask?.cancel()
        if let governorLease {
            runtimeGovernor.release(governorLease)
        }
        if wasWaitingForGovernor || hadUnspawnedGovernorLease {
            timer?.cancel()
            hardTimer?.cancel()
            poller?.cancel()
            checkpoint?.cancel()
            failFast?.cancel()
            heartbeat?.cancel()
            endNoNapActivity(for: runID)
            return
        }
        context?.requireOwnedDescendantProof()
        let cancellationDecisionReady =
            context.map {
                ensureCancellationDecisionBeforeSignal(
                    context: $0,
                    reason: "runner-terminate")
            } ?? !terminationContextUnavailable
        // Cancellation closes the attempt's event fence before signals or
        // timer cleanup. Any poller/final-drain bytes arriving after Stop are
        // therefore suppressed even if Process never invokes its callback.
        context?.eventFence.closeNonterminalEvents()
        timer?.cancel()
        hardTimer?.cancel()
        poller?.cancel()
        checkpoint?.cancel()
        failFast?.cancel()
        heartbeat?.cancel()
        guard cancellationDecisionReady else {
            return
        }
        if let context, hasMatchingCancellationContext {
            requestCancellationTermination(
                context: context,
                authorityIdentity: authorityIdentity,
                retryingBlockedCapture: false,
                reason: "runner-terminate")
        } else if terminationContextUnavailable {
            appendSpawnReceipt(
                runID: runID,
                attempt: 0,
                event: "termination-blocked",
                extra: ["reason": "active-cancellation-context-unavailable"])
        }
    }

    deinit {
        terminate()
    }

    private func markLifecycleActivity(runID: String) {
        var identity: ChatRunnerAttemptIdentity?
        lock.lock()
        if lifecycleRunID == runID, lifecyclePhase != .terminated {
            lifecycleLastActivityAt = Date()
            identity = currentAuthorityIdentity
        }
        lock.unlock()
        if let identity {
            runnerAuthority?.heartbeat(identity: identity)
        }
    }

    private func heartbeatAuthority(runID: String) {
        var identity: ChatRunnerAttemptIdentity?
        lock.lock()
        if lifecycleRunID == runID, lifecyclePhase != .terminated {
            identity = currentAuthorityIdentity
        }
        lock.unlock()
        if let identity {
            runnerAuthority?.heartbeat(identity: identity)
        }
    }

    private func claimAuthorityIdentity(
        runID: String,
        attempt: UInt64,
        expectedPrior: ChatRunnerClaimRolloverExpectation?
    ) -> ChatRunnerAttemptIdentity? {
        guard let runnerAuthority else {
            // Unknown authority is intentionally retained for tests/fixtures.
            // Production injects a durable recorder and never takes this path.
            return ChatRunnerAttemptIdentity(
                runID: runID,
                attempt: attempt,
                instanceID: UUID(),
                revision: attempt)
        }
        return try? runnerAuthority.claim(
            runID: runID,
            attempt: attempt,
            expectedPrior: expectedPrior)
    }

    private func shouldContinueRun(runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lifecycleRunID == runID && lifecyclePhase == .running
    }

    private func isEligibleForSpawnRetry(runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lifecycleRunID == runID
            && lifecyclePhase == .running
            && pendingRuntimeFailure == nil
    }

    private func pendingRuntimeFailureMessage(runID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingRuntimeFailure?.runID == runID else { return nil }
        return pendingRuntimeFailure?.message
    }

    private static func failureMessage(
        base: String?,
        terminationStatus: Int32,
        stderrTail: String?
    ) -> String? {
        // Preserve the pre-M3a lifecycle event type for ordinary non-zero
        // exits and signals. Only enrich an existing runtime failure, or turn
        // a stderr-backed command failure into a diagnostic runtime failure.
        let stderrBackedOrdinaryFailure =
            terminationStatus > 0
            && terminationStatus < 128
            && terminationStatus != 15
            && stderrTail != nil
        guard base != nil || stderrBackedOrdinaryFailure else { return nil }
        var message = base ?? "Chat CLI exited with status \(terminationStatus)."
        if let stderrTail, !stderrTail.isEmpty {
            message += "\nstderr_tail_8kb:\n\(stderrTail)"
        }
        return message
    }

    private func recordPendingRuntimeFailure(_ message: String, runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycleRunID == runID, lifecyclePhase != .terminated else { return false }
        guard pendingRuntimeFailure == nil else { return false }
        pendingRuntimeFailure = (runID, message)
        if lifecyclePhase == .running {
            lifecyclePhase = .terminationRequested
        }
        return true
    }

    private func resolveTerminalStatus(
        processStatus: Int32,
        runID: String,
        hasDurableFormalSuccess: Bool
    ) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return ChatCLITerminalPrecedencePolicy.resolvedStatus(
            processStatus: processStatus,
            hasDurableFormalSuccess: hasDurableFormalSuccess,
            cleanupTerminationRequested:
                lifecycleRunID == runID && lifecyclePhase == .terminationRequested,
            hasPendingRuntimeFailure:
                pendingRuntimeFailure?.runID == runID)
    }

    private func resolveBridgeAttemptTermination(
        process: Process,
        runID: String,
        status: Int32
    ) -> ChatCLIBridgeAttemptTerminationResolution {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycleRunID == runID,
              lifecyclePhase != .terminated,
              self.process === process
        else { return .stale }

        if lifecyclePhase == .running {
            self.process = nil
            if activeCancellationContext?.process === process {
                activeCancellationContext = nil
            }
            completedBridgeHandoff = (runID, status)
            return .internalHandoff
        }
        guard let result = commitFormalTerminationLocked(
            runID: runID,
            status: status,
            failureMessage: nil)
        else {
            return .blocked
        }
        self.process = nil
        if activeCancellationContext?.process === process {
            activeCancellationContext = nil
        }
        return .formal(result)
    }

    private func formalizeCompletedBridgeHandoff(
        runID: String
    ) -> ChatCLIFormalTerminationResult? {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycleRunID == runID,
              lifecyclePhase == .terminationRequested,
              self.process == nil,
              let completedBridgeHandoff,
              completedBridgeHandoff.runID == runID
        else { return nil }
        return commitFormalTerminationLocked(
            runID: runID,
            status: completedBridgeHandoff.status,
            failureMessage: nil)
    }

    private func emitFormalTermination(
        _ result: ChatCLIFormalTerminationResult,
        eventFence: ChatCLIRuntimeEventFence,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) {
        releaseGovernorLease()
        guard eventFence.commitFormalTerminal() else { return }
        if let failureMessage = result.failureMessage {
            onEvent(.runtimeFailure(failureMessage))
        } else {
            onEvent(.exit(result.status))
        }
    }

    private func releaseGovernorLease() {
        lock.lock()
        let lease = runtimeGovernorLease
        runtimeGovernorLease = nil
        runtimeGovernorLeaseHasSpawnedProcess = false
        runtimeGovernorAdmissionTask = nil
        runtimeGovernorAdmissionID = nil
        hardTurnDeadline = nil
        lock.unlock()
        if let lease {
            runtimeGovernor.release(lease)
        }
    }

    @discardableResult
    private func recordFormalTermination(
        process: Process?,
        runID: String,
        status: Int32,
        failureMessage: String? = nil,
        convergenceState: ChatCLICancellationConvergenceState? = nil
    ) -> ChatCLIFormalTerminationResult? {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycleRunID == runID, lifecyclePhase != .terminated else { return nil }
        if let process {
            guard self.process === process else { return nil }
        } else {
            // A nil Process is only valid when a real termination callback
            // already proved the bridge attempt ended and cleared the ref.
            // Never synthesize terminal state while a process may be alive.
            guard self.process == nil else { return nil }
        }
        guard let result = commitFormalTerminationLocked(
            runID: runID,
            status: status,
            failureMessage: failureMessage,
            convergenceState: convergenceState)
        else {
            return nil
        }
        if let process {
            self.process = nil
            if activeCancellationContext?.process === process {
                activeCancellationContext = nil
            }
        }
        return result
    }

    private func commitFormalTerminationLocked(
        runID: String,
        status: Int32,
        failureMessage: String?,
        convergenceState: ChatCLICancellationConvergenceState? = nil
    ) -> ChatCLIFormalTerminationResult? {
        if let identity = currentAuthorityIdentity,
           identity.runID == runID
        {
            if let runnerAuthority {
                switch runnerAuthority.recordRunTerminal(
                    identity: identity,
                    status: status)
                {
                case .persisted, .idempotent:
                    break
                case .blocked(let reason):
                    lifecyclePhase = .terminationRequested
                    cancellationConvergenceGeneration = nil
                    cancellationConvergenceState = .blocked(
                        reason:
                            "runner-authority-terminal-persistence-blocked:\(reason)")
                    return nil
                }
            }
        }
        let wasTerminationRequested = lifecyclePhase == .terminationRequested
        lifecyclePhase = .terminated
        lifecycleFormalExitStatus = status
        cancellationConvergenceGeneration = nil
        if let convergenceState {
            cancellationConvergenceState = convergenceState
        } else if wasTerminationRequested {
            cancellationConvergenceState = .terminalByCallback(status: status)
        }
        let failure =
            failureMessage
            ?? (pendingRuntimeFailure?.runID == runID
                ? pendingRuntimeFailure?.message
                : nil)
            ?? (blockedTerminalFailureSignal?.runID == runID
                ? blockedTerminalFailureSignal?.message
                : nil)
        lifecycleFormalFailureMessage = failure
        if pendingRuntimeFailure?.runID == runID {
            pendingRuntimeFailure = nil
        }
        if completedBridgeHandoff?.runID == runID {
            completedBridgeHandoff = nil
        }
        return ChatCLIFormalTerminationResult(
            status: status,
            failureMessage: failure)
    }

    private func blockVisibleTerminalForAuthorityPersistence(
        runID: String,
        reason: String
    ) {
        lock.lock()
        guard lifecycleRunID == runID, lifecyclePhase != .terminated else {
            lock.unlock()
            return
        }
        lifecyclePhase = .terminationRequested
        cancellationConvergenceGeneration = nil
        cancellationConvergenceState = .blocked(
            reason: "runner-authority-attempt-terminal-persistence-blocked:\(reason)")
        lock.unlock()
    }
}
