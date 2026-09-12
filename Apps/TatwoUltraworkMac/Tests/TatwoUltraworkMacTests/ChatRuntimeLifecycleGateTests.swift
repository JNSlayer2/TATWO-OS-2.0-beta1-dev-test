import XCTest
import Darwin

@testable import TatwoUltraworkMac
@testable import TatwoUltraworkCore

final class ChatRuntimeLifecycleGateTests: XCTestCase {
    func testRegularForegroundWindowDoesNotForceLaunchctlChatBoundary() {
        XCTAssertFalse(
            ChatCLIProcessRunner.shouldUseDetachedChatProcessBoundary(
                env: [:]))
        XCTAssertFalse(
            ChatCLIProcessRunner.shouldUseLaunchctlChatProcessBoundary(
                env: [:]))
        XCTAssertFalse(
            ChatCLIProcessRunner.shouldUseDetachedChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_DEFAULT_SURFACE": "window"]))
        XCTAssertFalse(
            ChatCLIProcessRunner.shouldUseLaunchctlChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_DEFAULT_SURFACE": "window"]))
    }

    func testLegacyPanelAgentAndExplicitOverrideKeepLaunchctlChatBoundary() {
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseDetachedChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_FORCE_LAUNCHCTL_CHAT": "1"]))
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseLaunchctlChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_FORCE_LAUNCHCTL_CHAT": "1"]))
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseDetachedChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_AUTOSHOW_PANEL": "1"]))
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseLaunchctlChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_AUTOSHOW_PANEL": "1"]))
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseDetachedChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_DEFAULT_SURFACE": "panel"]))
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseLaunchctlChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_DEFAULT_SURFACE": "panel"]))
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseDetachedChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_BUILD_AS_AGENT": "1"]))
        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseLaunchctlChatProcessBoundary(
                env: ["TATWO_ULTRAWORK_BUILD_AS_AGENT": "1"]))
    }

    func testExplicitBridgeOverrideKeepsShellBoundaryWithoutLaunchctl() {
        let env = ["TATWO_ULTRAWORK_FORCE_CHAT_BRIDGE": "1"]

        XCTAssertTrue(
            ChatCLIProcessRunner.shouldUseDetachedChatProcessBoundary(
                env: env))
        XCTAssertFalse(
            ChatCLIProcessRunner.shouldUseLaunchctlChatProcessBoundary(
                env: env))
    }

    func testProcessTerminationCanonicalizationDistinguishesSignalFromExit() {
        XCTAssertEqual(
            ChatCLIProcessTerminationPolicy.canonicalExitStatus(
                rawStatus: SIGTERM,
                reason: .uncaughtSignal),
            143)
        XCTAssertEqual(
            ChatCLIProcessTerminationPolicy.canonicalExitStatus(
                rawStatus: SIGTERM,
                reason: .exit),
            SIGTERM)
    }

    func testProcessTerminationBoundaryPreservesRawReceiptAndUsesCanonicalStatus()
        throws
    {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let boundary = try XCTUnwrap(
            source.slice(
                from: "process.terminationHandler = { proc in",
                through: "var launchError: Error?"))

        XCTAssertTrue(
            boundary.contains(
                "rawTerminationStatus = proc.terminationStatus"))
        XCTAssertTrue(
            boundary.contains(
                "terminationReason = proc.terminationReason"))
        XCTAssertTrue(
            boundary.contains(
                "processStatus: canonicalTerminationStatus"))
        XCTAssertTrue(
            boundary.contains(
                #""terminationStatus": "\(rawTerminationStatus)""#))
        XCTAssertTrue(
            boundary.contains(
                #""canonicalTerminationStatus": "\(canonicalTerminationStatus)""#))
        XCTAssertTrue(
            boundary.contains(
                "recordWrapperExitCallback(\n                status: effectiveTerminationStatus)"))
        XCTAssertTrue(
            boundary.contains(
                "status: canonicalTerminationStatus"))
    }

    func testRawSIGTERMBecomesCanonical143ForFormalLifecycle() {
        let terminal = expectation(description: "canonical SIGTERM terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: selfSIGTERMFixtureCommand(),
            runID: "canonical-sigterm-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(recorder.exitStatuses, [143])
        XCTAssertEqual(runner.lifecycleSnapshot?.formalExitStatus, 143)
    }

    func testNormalExit15Remains15ForFormalLifecycle() {
        let terminal = expectation(description: "normal exit 15 terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: fixtureCommand(
                output:
                    #"{"type":"item.completed","item":{"id":"exit-15","type":"agent_message","text":"NORMAL_EXIT_15"}}"#,
                exitStatus: 15),
            runID: "normal-exit-15-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(recorder.exitStatuses, [15])
        XCTAssertEqual(runner.lifecycleSnapshot?.formalExitStatus, 15)
    }

    func testDurableFormalSuccessBeatsLaterCleanupSIGTERM() {
        XCTAssertEqual(
            ChatCLITerminalPrecedencePolicy.resolvedStatus(
                processStatus: 143,
                hasDurableFormalSuccess: true,
                cleanupTerminationRequested: true,
                hasPendingRuntimeFailure: false),
            0)
    }

    func testPrematureOrGenuineSIGTERMRemainsFailure() {
        XCTAssertEqual(
            ChatCLITerminalPrecedencePolicy.resolvedStatus(
                processStatus: 143,
                hasDurableFormalSuccess: false,
                cleanupTerminationRequested: true,
                hasPendingRuntimeFailure: false),
            143)
        XCTAssertEqual(
            ChatCLITerminalPrecedencePolicy.resolvedStatus(
                processStatus: 143,
                hasDurableFormalSuccess: true,
                cleanupTerminationRequested: false,
                hasPendingRuntimeFailure: false),
            143)
        XCTAssertEqual(
            ChatCLITerminalPrecedencePolicy.resolvedStatus(
                processStatus: 143,
                hasDurableFormalSuccess: true,
                cleanupTerminationRequested: true,
                hasPendingRuntimeFailure: true),
            143)
    }

    func testFormalSuccessTrackerFreezesBeforeLateCancellationOutput() {
        let tracker = ChatCLIFormalSuccessTracker()

        tracker.consume(#"{"type":"turn.started"}"# + "\n")
        XCTAssertFalse(tracker.freeze())
        tracker.consume(#"{"type":"turn.completed"}"# + "\n")
        tracker.flush()

        XCTAssertFalse(tracker.hasObservedFormalSuccess)
    }

    func testFormalSuccessTrackerPreservesSuccessObservedBeforeCancellation() {
        let tracker = ChatCLIFormalSuccessTracker()

        tracker.consume(#"{"type":"turn.completed"}"# + "\n")
        XCTAssertTrue(tracker.freeze())
        tracker.consume(#"{"type":"turn.completed","id":"late"}"# + "\n")

        XCTAssertTrue(tracker.hasObservedFormalSuccess)
    }

    func testFormalSuccessTrackerPreservesCompleteUnterminatedSuccessBeforeCancellation() {
        let tracker = ChatCLIFormalSuccessTracker()

        tracker.consume(#"{"type":"turn.completed","id":"unterminated"}"#)

        XCTAssertTrue(tracker.freeze())
        XCTAssertTrue(tracker.hasObservedFormalSuccess)
    }

    func testFormalSuccessTrackerFailureInvalidatesLateCompletionEvidence() {
        let tracker = ChatCLIFormalSuccessTracker()

        tracker.consume(#"{"type":"turn.completed"}"# + "\n")
        XCTAssertTrue(tracker.hasObservedFormalSuccess)
        tracker.invalidateForFailure()
        tracker.consume(#"{"type":"turn.completed","id":"late"}"# + "\n")

        XCTAssertFalse(tracker.hasObservedFormalSuccess)
    }

    func testLaunchctlCancellationDecisionResetsAndPersistsFrozenBit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-cancel-decision-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let status = root.appendingPathComponent("status.txt")
        let decision =
            ChatCLILaunchctlCancellationDecision.fileURL(for: status)

        XCTAssertTrue(
            ChatCLILaunchctlCancellationDecision.reset(for: status))
        XCTAssertEqual(
            try String(contentsOf: decision, encoding: .utf8),
            "0\n")
        XCTAssertTrue(
            ChatCLILaunchctlCancellationDecision.persist(
                hasFormalSuccess: true,
                for: status))
        XCTAssertEqual(
            try String(contentsOf: decision, encoding: .utf8),
            "1\n")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBridgeRetryRequiresTerminationCleanupAndExactRolloverExpectation() {
        let state = ChatCLIBridgeRetryState(
            policy: .evidenceGatedSingleRetry(
                auditID: "test-exact-rollover"))
        var launchCount = 0
        var receivedExpectation: ChatRunnerClaimRolloverExpectation?
        let identity = ChatRunnerAttemptIdentity(
            runID: "bridge-retry-state",
            attempt: 1,
            instanceID: UUID(),
            revision: 7)
        let expectation = ChatRunnerClaimRolloverExpectation(
            identity: identity,
            phase: .attemptTerminal(status: 143))
        state.armRetry { expectedPrior in
            launchCount += 1
            receivedExpectation = expectedPrior
        }

        XCTAssertNil(state.takeRetryIfReady())
        state.recordAttemptTermination()
        XCTAssertNil(state.takeRetryIfReady())
        state.recordCleanupComplete()
        XCTAssertNil(
            state.takeRetryIfReady(),
            "cleanup alone must not authorize a generation rollover")
        state.recordRolloverExpectation(expectation)

        let retry = state.takeRetryIfReady()
        XCTAssertNotNil(retry)
        retry?()
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(receivedExpectation, expectation)
        XCTAssertNil(state.takeRetryIfReady(), "retry must be consumed exactly once")
    }

    func testDefaultZeroRetryBudgetMakesAttemptTwoImpossible() {
        let state = ChatCLIBridgeRetryState()
        var launchCount = 0
        let identity = ChatRunnerAttemptIdentity(
            runID: "default-zero-retry",
            attempt: 1,
            instanceID: UUID(),
            revision: 2)

        state.armRetry { _ in launchCount += 1 }
        state.recordAttemptTermination()
        state.recordCleanupComplete()
        state.recordRolloverExpectation(
            ChatRunnerClaimRolloverExpectation(
                identity: identity,
                phase: .attemptTerminal(status: 143)))

        XCTAssertFalse(state.isArmed)
        XCTAssertNil(state.takeRetryIfReady())
        XCTAssertEqual(launchCount, 0)
    }

    func testFormalTerminalCommitClosesNonterminalEventFence() {
        let fence = ChatCLIRuntimeEventFence()
        var nonterminalEventCount = 0

        XCTAssertTrue(fence.shouldEmitNonterminalEvent())
        XCTAssertTrue(fence.emitNonterminalEvent { nonterminalEventCount += 1 })
        XCTAssertTrue(fence.commitFormalTerminal())
        XCTAssertFalse(fence.shouldEmitNonterminalEvent())
        XCTAssertFalse(fence.emitNonterminalEvent { nonterminalEventCount += 1 })
        XCTAssertEqual(nonterminalEventCount, 1)
        XCTAssertFalse(
            fence.commitFormalTerminal(),
            "watchdog/reconciler/exit races share one formal fence")
    }

    func testCancellationFenceSuppressesLateOutputBeforeFormalTerminal() {
        let firstOutput = expectation(description: "pre-cancel output")
        let terminal = expectation(description: "formal terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminal,
            firstOutputExpectation: firstOutput)
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: cancellationLateOutputFixtureCommand(
                firstOutput: "TATWO_BEFORE_CANCEL",
                lateOutput: "TATWO_AFTER_CANCEL"),
            runID: "cancel-late-output-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [firstOutput], timeout: 3)
        runner.terminate()
        wait(for: [terminal], timeout: 5)

        XCTAssertEqual(recorder.outputTexts, ["TATWO_BEFORE_CANCEL"])
        XCTAssertFalse(recorder.eventTags.contains("output:TATWO_AFTER_CANCEL"))
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testCancellationDoesNotPromoteLateTurnCompletedToSuccess() {
        let ready = expectation(description: "fixture installed cancellation trap")
        let terminal = expectation(description: "late success remains cancelled")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminal,
            firstOutputExpectation: ready)
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: cancellationLateFormalSuccessFixtureCommand(),
            runID: "cancel-late-formal-success-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [ready], timeout: 3)
        runner.terminate()
        wait(for: [terminal], timeout: 5)

        XCTAssertEqual(recorder.exitStatuses, [143])
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testAuthorityClaimFailureCleansOwnedGatewayPromptBeforeSpawn() throws {
        // M3b 更新：deprecated 歷史相容組；只保留 prompt lifecycle 合約。
        let plan = gatewayPromptPlan(prompt: "AUTHORITY_CLEANUP_PROMPT")
        let owned = try XCTUnwrap(plan.ownedTemporaryFiles.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        let runner = ChatCLIProcessRunner(
            runnerAuthority: RejectingChatRunnerAuthority())

        let identity = runner.start(
            command: ChatCLICommand(plan: plan, commandMode: .chat),
            runID: "authority-cleanup-\(UUID().uuidString)",
            onEvent: { _ in })

        XCTAssertNil(identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    func testPreSpawnStreamSetupFailureCleansOwnedGatewayPrompt() throws {
        // M3b 更新：deprecated 歷史相容組；只保留 prompt lifecycle 合約。
        let plan = gatewayPromptPlan(prompt: "STREAM_SETUP_CLEANUP_PROMPT")
        let owned = try XCTUnwrap(plan.ownedTemporaryFiles.first)
        let invalidRuntimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-runtime-root-file-\(UUID().uuidString)",
                isDirectory: false)
        try Data("not-a-directory".utf8).write(to: invalidRuntimeRoot)
        defer { try? FileManager.default.removeItem(at: invalidRuntimeRoot) }
        let runner = ChatCLIProcessRunner(runtimeRootURL: invalidRuntimeRoot)

        XCTAssertNotNil(runner.start(
            command: ChatCLICommand(plan: plan, commandMode: .chat),
            runID: "stream-setup-cleanup-\(UUID().uuidString)",
            onEvent: { _ in }))

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(runner.lifecycleSnapshot?.formalExitStatus, -1)
    }

    func testCancellationCleansOwnedGatewayPromptWhenAdapterNeverReadsIt() throws {
        // M3b 更新：deprecated 歷史相容組；只保留 prompt lifecycle 合約。
        let plan = gatewayPromptPlan(prompt: "CANCEL_CLEANUP_PROMPT")
        let owned = try XCTUnwrap(plan.ownedTemporaryFiles.first)
        let terminal = expectation(description: "cancel cleanup terminal")
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: cancellableFixtureCommand(
                ownedTemporaryFiles: plan.ownedTemporaryFiles),
            runID: "cancel-prompt-cleanup-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))

        runner.terminate()
        wait(for: [terminal], timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testTerminateWaitsForRealOwnedSleepDescendantAndProvesBothPIDsDead() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-owned-descendant-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true)
        let childPIDFile = fixtureRoot.appendingPathComponent("child.pid")
        let childReadyFile = fixtureRoot.appendingPathComponent("child.ready")
        var capturedPIDs: [pid_t] = []
        defer {
            // Test cleanup is intentionally bounded to the two exact PIDs
            // captured from this fixture. Never scan or signal a wider set.
            for pid in Set(capturedPIDs) where pid > 1 {
                errno = 0
                if Darwin.kill(pid, 0) == 0 || errno == EPERM {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        let terminal = expectation(description: "owned descendant terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()
        runner.start(
            command: ownedSleepDescendantFixtureCommand(
                childPIDFile: childPIDFile,
                childReadyFile: childReadyFile),
            runID: "owned-descendant-\(UUID().uuidString)",
            onEvent: recorder.record)

        XCTAssertTrue(waitUntilRunnerIsRunning(runner))
        let parentPID = try XCTUnwrap(
            runner.diagnosticsSnapshot.processIdentifier)
        let childPID = try XCTUnwrap(
            waitForPID(in: childPIDFile, timeout: 2))
        XCTAssertTrue(
            waitForNonEmptyFile(at: childReadyFile, timeout: 2),
            "child must install TERM/INT ignore traps before termination")
        capturedPIDs = [parentPID, childPID]
        XCTAssertGreaterThan(parentPID, 1)
        XCTAssertGreaterThan(childPID, 1)
        XCTAssertNotEqual(parentPID, childPID)
        XCTAssertTrue(isProcessAlive(parentPID))
        XCTAssertTrue(isProcessAlive(childPID))

        runner.terminate()

        // The child ignores TERM and INT, so the real parent Process callback
        // arrives first. Cancellation must remain nonterminal until the exact
        // captured child reaches the bounded SIGKILL fallback.
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertTrue(isProcessAlive(childPID))
        XCTAssertEqual(recorder.formalTerminalCount, 0)

        wait(for: [terminal], timeout: 6)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertTrue(waitUntilProcessIsGone(parentPID, timeout: 2))
        XCTAssertTrue(waitUntilProcessIsGone(childPID, timeout: 2))
        assertProcessProbeIsESRCH(parentPID)
        assertProcessProbeIsESRCH(childPID)
    }

    func testBoundedStalePromptRecoveryRemovesOnlyOldOwnedRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-stale-prompt-test-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(
            ".tatwo-gateway-prompt-\(UUID().uuidString).txt")
        let fresh = root.appendingPathComponent(
            ".tatwo-gateway-prompt-\(UUID().uuidString).txt")
        try Data("stale".utf8).write(to: stale)
        try Data("fresh".utf8).write(to: fresh)
        XCTAssertEqual(chmod(stale.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertEqual(chmod(fresh.path, S_IRUSR | S_IWUSR), 0)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(2 * 24 * 60 * 60))],
            ofItemAtPath: stale.path)

        XCTAssertEqual(
            ChatCLITemporaryFileOwner.cleanupStaleGatewayPromptFiles(
                in: root,
                minimumAge: 24 * 60 * 60,
                scanLimit: 8,
                removalLimit: 1),
            1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testMissingTerminationCallbackConvergesOnlyAfterAuthoritativeWrapperInactivity() {
        let terminal = expectation(description: "synthetic cancellation terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.1,
                retryInterval: 0.05,
                maxAttempts: 20),
            terminationCallbackDelivery: { _ in })

        runner.start(
            command: cancellableFixtureCommand(),
            runID: "missing-callback-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(recorder.exitStatuses, [143])
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertEqual(runner.lifecycleSnapshot?.formalExitStatus, 143)
        XCTAssertEqual(
            runner.diagnosticsSnapshot.cancellationConvergenceState,
            .terminalByAuthoritativeInactivity(status: 143))
        XCTAssertFalse(runner.diagnosticsSnapshot.hasProcessReference)
    }

    func testUnknownLaunchctlTopologyFailsClosed() {
        let decision = ChatCLICancellationConvergenceEvaluator.decide(
            wrapper: .inactive,
            launchBoundary: .launchctl(
                label: "com.tatwo.ultrawork.chat.unknown",
                uid: getuid()),
            launchctlProbe: { _, _ in
                .unknown(reason: "probe-permission-denied")
            })

        XCTAssertEqual(
            decision,
            .blocked(
                reason: "launchctl-topology-unknown:probe-permission-denied"))
    }

    func testWrapperExitWithUnknownConvergenceSignalsOneTerminalFailureWhileAuthorityStaysBlocked() throws {
        let terminalFailure = expectation(
            description: "blocked convergence terminal failure signal")
        terminalFailure.assertForOverFulfill = true
        let duplicateCallbackDelivered = expectation(
            description: "duplicate callback delivered")
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminalFailure)
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .requested)
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 2),
            wrapperInactivityProbe: { _ in
                .unknown(reason: "owned-descendant-inactivity-unknown")
            },
            runnerAuthority: authority,
            terminationCallbackDelivery: { callback in
                callback()
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 0.1)
                {
                    callback()
                    duplicateCallbackDelivered.fulfill()
                }
            })
        let runID =
            "blocked-terminal-signal-\(UUID().uuidString)"

        runner.start(
            command: signalTerminatedFixtureCommand(),
            runID: runID,
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        wait(
            for: [terminalFailure, duplicateCallbackDelivered],
            timeout: 3)

        XCTAssertEqual(recorder.runtimeFailureTexts.count, 1)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertEqual(authority.formalTerminalCount, 0)
        XCTAssertNil(runner.lifecycleSnapshot?.formalExitStatus)
        XCTAssertEqual(
            runner.diagnosticsSnapshot.lifecyclePhase,
            .terminationRequested)
        guard case .blocked(let reason) =
            runner.diagnosticsSnapshot.cancellationConvergenceState
        else {
            return XCTFail(
                "unknown descendant convergence must keep authority blocked")
        }
        XCTAssertTrue(reason.contains("inactivity-unknown"))
        let signal = try XCTUnwrap(
            runner.diagnosticsSnapshot.blockedTerminalFailureSignal)
        XCTAssertEqual(signal.runID, runID)
        XCTAssertEqual(signal.wrapperExitStatus, 143)
        XCTAssertTrue(signal.authorityRemainsBlocked)
        XCTAssertFalse(signal.reclaimAllowed)
        XCTAssertTrue(
            signal.idempotencyKey.contains(
                "wrapper-exit-convergence-blocked"))
    }

    func testLaunchctlCancellationCannotCompleteWhileSubmittedLabelStillExists() {
        let boundary = ChatCLICancellationLaunchBoundary.launchctl(
            label: "com.tatwo.ultrawork.chat.still-present",
            uid: getuid())

        XCTAssertEqual(
            ChatCLICancellationConvergenceEvaluator.decide(
                wrapper: .inactive,
                ownedDescendants: [.inactive],
                launchBoundary: boundary,
                launchctlProbe: { _, _ in .present }),
            .retry(reason: "launchctl-label-still-present"))
        XCTAssertEqual(
            ChatCLICancellationConvergenceEvaluator.decide(
                wrapper: .inactive,
                ownedDescendants: [.inactive],
                launchBoundary: boundary,
                launchctlProbe: { _, _ in .absent }),
            .converged)
    }

    func testLaunchctlCancellationCallbackWaitsForBootoutProofBeforeFormalTerminal() {
        let labelPresent = expectation(
            description: "termination observed submitted label still present")
        labelPresent.assertForOverFulfill = false
        let terminal = expectation(
            description: "formal terminal after submitted label became absent")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let probe = ChatLaunchctlProbeRecorder(
            firstPresentExpectation: labelPresent)
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 100),
            launchSurfaceEnvironment: [
                "TATWO_ULTRAWORK_FORCE_LAUNCHCTL_CHAT": "1"
            ],
            launchctlLabelProbe: probe.probe)

        runner.start(
            command: launchctlCancellableFixtureCommand(),
            runID: "launchctl-callback-proof-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        wait(for: [labelPresent], timeout: 3)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(
            recorder.formalTerminalCount,
            0,
            "the wrapper callback cannot formalize while launchctl is present")

        probe.markAbsent()
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(recorder.exitStatuses, [143])
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertGreaterThanOrEqual(probe.probeCount, 2)
    }

    func testBlockedDescendantCaptureRetryRecapturesBeforeSendingSignals() {
        let terminal = expectation(
            description: "formal terminal after descendant recapture")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let capture = ChatDescendantCaptureRecorder(
            firstResult: .blocked(
                knownDescendants: [],
                reason: "transient-child-list-failure"))
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 20),
            ownedDescendantCapture: capture.capture)

        runner.start(
            command: cancellableFixtureCommand(),
            runID: "blocked-descendant-recapture-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(capture.captureCount, 1)
        XCTAssertEqual(recorder.formalTerminalCount, 0)
        XCTAssertTrue(runner.diagnosticsSnapshot.processIsRunning)
        guard case .blocked(let reason) =
            runner.diagnosticsSnapshot.cancellationConvergenceState
        else {
            XCTFail("transient descendant capture failure must stay blocked")
            return
        }
        XCTAssertTrue(reason.contains("transient-child-list-failure"))

        capture.useLiveCapture()
        runner.retryBlockedCancellationConvergence()
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(capture.captureCount, 2)
        XCTAssertEqual(recorder.exitStatuses, [143])
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testBlockedRecaptureRetainsPartialKnownDescendantIdentityUnion() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-partial-known-descendant-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true)
        let childPIDFile = fixtureRoot.appendingPathComponent("child.pid")
        let childReadyFile = fixtureRoot.appendingPathComponent("child.ready")
        var capturedPIDs: [pid_t] = []
        defer {
            for pid in Set(capturedPIDs) where pid > 1 {
                errno = 0
                if Darwin.kill(pid, 0) == 0 || errno == EPERM {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        let terminal = expectation(
            description: "formal terminal after partial-known recapture")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let capture = ChatPartialKnownDescendantCaptureRecorder()
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 20),
            ownedDescendantCapture: capture.capture)

        runner.start(
            command: ownedSleepDescendantFixtureCommand(
                childPIDFile: childPIDFile,
                childReadyFile: childReadyFile),
            runID: "partial-known-descendant-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))
        let parentPID = try XCTUnwrap(
            runner.diagnosticsSnapshot.processIdentifier)
        let childPID = try XCTUnwrap(
            waitForPID(in: childPIDFile, timeout: 2))
        XCTAssertTrue(
            waitForNonEmptyFile(at: childReadyFile, timeout: 2),
            "child must install TERM/INT ignore traps before termination")
        capturedPIDs = [parentPID, childPID]

        runner.terminate()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertGreaterThanOrEqual(capture.firstKnownDescendantCount, 1)
        XCTAssertTrue(isProcessAlive(parentPID))
        XCTAssertTrue(isProcessAlive(childPID))
        XCTAssertEqual(recorder.formalTerminalCount, 0)

        runner.retryBlockedCancellationConvergence()
        wait(for: [terminal], timeout: 6)

        XCTAssertEqual(capture.captureCount, 2)
        XCTAssertTrue(
            waitUntilProcessIsGone(childPID, timeout: 2),
            "retry returning an empty fresh set must retain and reap the first known child")
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testAuthorityRetryRecapturesAndRetainsFirstCapturedIdentityUnion() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-authority-recapture-union-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true)
        let childPIDFile = fixtureRoot.appendingPathComponent("child.pid")
        let childReadyFile = fixtureRoot.appendingPathComponent("child.ready")
        var capturedPIDs: [pid_t] = []
        defer {
            for pid in Set(capturedPIDs) where pid > 1 {
                errno = 0
                if Darwin.kill(pid, 0) == 0 || errno == EPERM {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        let terminal = expectation(
            description: "formal terminal after authority recapture")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let capture = ChatCapturedThenEmptyDescendantRecorder()
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .blocked(reason: "transient-authority-block"))
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 20),
            ownedDescendantCapture: capture.capture,
            runnerAuthority: authority)

        runner.start(
            command: ownedSleepDescendantFixtureCommand(
                childPIDFile: childPIDFile,
                childReadyFile: childReadyFile),
            runID: "authority-recapture-union-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))
        let parentPID = try XCTUnwrap(
            runner.diagnosticsSnapshot.processIdentifier)
        let childPID = try XCTUnwrap(
            waitForPID(in: childPIDFile, timeout: 2))
        XCTAssertTrue(
            waitForNonEmptyFile(at: childReadyFile, timeout: 2),
            "child must install TERM/INT ignore traps before termination")
        capturedPIDs = [parentPID, childPID]

        runner.terminate()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(capture.captureCount, 1)
        XCTAssertTrue(isProcessAlive(childPID))
        XCTAssertEqual(recorder.formalTerminalCount, 0)

        authority.setTerminationResult(.requested)
        runner.retryBlockedCancellationConvergence()
        wait(for: [terminal], timeout: 6)

        XCTAssertEqual(
            capture.captureCount,
            2,
            "an explicit blocked retry must recapture descendants")
        XCTAssertTrue(
            waitUntilProcessIsGone(childPID, timeout: 2),
            "an empty retry capture must retain and reap first-capture identities")
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testRunnerAuthorityBlockedTerminationRequiresExplicitRetry() {
        let terminal = expectation(
            description: "formal terminal after authority retry")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .blocked(
                reason: "launchctl-termination-request-failed"))
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 20),
            runnerAuthority: authority)

        runner.start(
            command: cancellableFixtureCommand(),
            runID: "authority-blocked-retry-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(authority.terminationRequestCount, 1)
        XCTAssertTrue(runner.diagnosticsSnapshot.processIsRunning)
        XCTAssertEqual(recorder.formalTerminalCount, 0)
        guard case .blocked(let reason) =
            runner.diagnosticsSnapshot.cancellationConvergenceState
        else {
            XCTFail("blocked authority mutation must block local terminal state")
            return
        }
        XCTAssertTrue(reason.contains("runner-authority-termination-blocked"))

        authority.setTerminationResult(.requested)
        runner.retryBlockedCancellationConvergence()
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(authority.terminationRequestCount, 2)
        XCTAssertEqual(authority.formalTerminalCount, 1)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testRunnerAuthorityUnknownTerminationRequiresExplicitRetry() {
        let terminal = expectation(
            description: "formal terminal after unknown authority retry")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .unknown(
                reason: "runner-registry-unreadable"))
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 20),
            runnerAuthority: authority)

        runner.start(
            command: cancellableFixtureCommand(),
            runID: "authority-unknown-retry-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertTrue(runner.diagnosticsSnapshot.processIsRunning)
        XCTAssertEqual(recorder.formalTerminalCount, 0)
        guard case .blocked(let reason) =
            runner.diagnosticsSnapshot.cancellationConvergenceState
        else {
            XCTFail("unknown authority mutation must fail closed")
            return
        }
        XCTAssertTrue(reason.contains("runner-authority-termination-unknown"))

        authority.setTerminationResult(.requested)
        runner.retryBlockedCancellationConvergence()
        wait(for: [terminal], timeout: 3)

        XCTAssertEqual(authority.terminationRequestCount, 2)
        XCTAssertEqual(authority.formalTerminalCount, 1)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testAuthoritativeConvergenceAndLateCallbackEmitExactlyOneFormalTerminal() {
        let terminal = expectation(description: "exactly one terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.1,
                retryInterval: 0.05,
                maxAttempts: 20),
            terminationCallbackDelivery: { callback in
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 0.4,
                    execute: callback)
            })

        runner.start(
            command: cancellableFixtureCommand(),
            runID: "late-callback-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        wait(for: [terminal], timeout: 3)

        let delayedCallback = expectation(description: "late callback delivered")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
            delayedCallback.fulfill()
        }
        wait(for: [delayedCallback], timeout: 1)
        XCTAssertEqual(recorder.exitStatuses, [143])
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testCallbackAndConvergenceRacePublishOneDurableFormalTerminal() {
        let terminal = expectation(
            description: "one durable formal terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .requested)
        let callbackDelivered = expectation(
            description: "late process callback delivered")
        let runner = ChatCLIProcessRunner(
            cancellationConvergencePolicy: ChatCLICancellationConvergencePolicy(
                initialDelay: 0.05,
                retryInterval: 0.05,
                maxAttempts: 20),
            runnerAuthority: authority,
            terminationCallbackDelivery: { callback in
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 0.35)
                {
                    callback()
                    callbackDelivered.fulfill()
                }
            })

        runner.start(
            command: cancellableFixtureCommand(),
            runID: "durable-terminal-race-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        wait(for: [terminal, callbackDelivered], timeout: 3)

        XCTAssertEqual(recorder.exitStatuses, [143])
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertEqual(
            authority.formalTerminalCount,
            1,
            "callback and missing-callback convergence share one durable publisher")
        XCTAssertEqual(runner.diagnosticsSnapshot.lifecyclePhase, .terminated)
    }

    func testRunTerminalPersistenceFailureBlocksVisibleTerminal() {
        let noTerminal = expectation(
            description: "persistence failure blocks visible terminal")
        noTerminal.isInverted = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: noTerminal)
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .requested)
        authority.setRunTerminalResult(
            .blocked(reason: "runner-terminal-persistence-failed"))
        let runner = ChatCLIProcessRunner(
            outputPollPolicy: ChatCLIOutputPollPolicy(
                initialDelay: 0.01,
                repeatInterval: 0.01),
            runnerAuthority: authority)

        runner.start(
            command: fixtureCommand(output: ""),
            runID: "terminal-persistence-block-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [noTerminal], timeout: 0.3)
        XCTAssertEqual(authority.formalTerminalCount, 1)
        XCTAssertEqual(recorder.formalTerminalCount, 0)
        XCTAssertEqual(
            runner.diagnosticsSnapshot.lifecyclePhase,
            .terminationRequested)
        guard case .blocked(let reason) =
            runner.diagnosticsSnapshot.cancellationConvergenceState
        else {
            return XCTFail(
                "failed durable terminal persistence must keep the run blocked")
        }
        XCTAssertTrue(
            reason.contains("runner-authority-terminal-persistence-blocked"))
    }

    func testIdempotentSameRunTerminalStillPublishesVisibleTerminal() {
        let terminal = expectation(
            description: "idempotent durable terminal is visible")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminal)
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .requested)
        authority.setRunTerminalResult(.idempotent)
        let runner = ChatCLIProcessRunner(
            outputPollPolicy: ChatCLIOutputPollPolicy(
                initialDelay: 0.01,
                repeatInterval: 0.01),
            runnerAuthority: authority)

        runner.start(
            command: fixtureCommand(output: ""),
            runID: "terminal-idempotent-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 3)
        XCTAssertEqual(authority.formalTerminalCount, 1)
        XCTAssertEqual(recorder.exitStatuses, [0])
        XCTAssertEqual(
            runner.diagnosticsSnapshot.lifecyclePhase,
            .terminated)
    }

    func testSpawnFailurePersistsRunTerminalExactlyOnce() {
        // M3a 更新：spawn failure 現在固定重試一次；兩次實體啟動失敗
        // 仍只能提交一個 run-level formal terminal。
        let failure = expectation(description: "spawn failure delivered")
        let authority = ControllableChatRunnerAuthority(
            terminationResult: .requested)
        let runner = ChatCLIProcessRunner(runnerAuthority: authority)

        runner.start(
            command: ChatCLICommand(
                engine: .codex,
                executable: "/definitely/missing/tatwo-chat-runner",
                arguments: [],
                workingDirectory: FileManager.default.temporaryDirectory,
                expectsJSON: false,
                capturesSessionID: false,
                standardInputFromDevNull: true,
                requiresForegroundScheduling: false,
                runtimeAdapter: .gatewayDirect,
                commandMode: .chat),
            runID: "spawn-terminal-once-\(UUID().uuidString)"
        ) { event in
            if case .runtimeFailure = event {
                failure.fulfill()
            }
        }

        wait(for: [failure], timeout: 3)
        XCTAssertEqual(runner.diagnosticsSnapshot.physicalAttempt, 2)
        XCTAssertEqual(
            authority.formalTerminalCount,
            1,
            "spawn error must not pre-record and then record the same run terminal")
    }

    func testQueuedTurnContextIncludesPriorAssistantThatWasAppendedAfterLaterQueuedUser() {
        let userOne = ChatMessage(role: .user, text: "U1", eventKind: .message)
        let assistantOne = ChatMessage(role: .assistant, text: "A1", eventKind: .message)
        let userTwo = ChatMessage(
            role: .user,
            text: "U2",
            status: nil,
            eventKind: .message)
        let userThree = ChatMessage(
            role: .user,
            text: "U3",
            status: "queued",
            eventKind: .message)
        // A2 is physically appended after U3 because both queued user rows were
        // already visible before the U2 runner began.
        let assistantTwo = ChatMessage(role: .assistant, text: "A2", eventKind: .message)

        let transcript = ChatQueueContextPolicy.transcriptForExecution(
            messages: [userOne, assistantOne, userTwo, userThree, assistantTwo],
            currentMessageID: userThree.id,
            pendingMessageIDs: [])

        XCTAssertEqual(transcript.map(\.text), ["U1", "A1", "U2", "A2"])
        XCTAssertFalse(transcript.contains { $0.id == userThree.id })
    }

    func testQueuedTurnContextExcludesEveryStillPendingQueuedUser() {
        let completedUser = ChatMessage(role: .user, text: "done", eventKind: .message)
        let current = ChatMessage(
            role: .user,
            text: "current",
            status: "queued",
            eventKind: .message)
        let future = ChatMessage(
            role: .user,
            text: "future",
            status: "queued",
            eventKind: .message)

        let transcript = ChatQueueContextPolicy.transcriptForExecution(
            messages: [completedUser, current, future],
            currentMessageID: current.id,
            pendingMessageIDs: [future.id])

        XCTAssertEqual(transcript.map(\.text), ["done"])
    }

    func testQueuedTicketBudgetCountsEveryRetainedString() {
        let snapshot = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: "gpt-5.6-sol",
            phase: .plan,
            contractID: "contract-1",
            contractBindingID: "binding-1",
            requestedEffort: .low,
            forwardedEffort: .low,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)
        let ticket = ChatQueuedTicket(
            threadID: nil,
            discussionID: nil,
            messageID: "queued-message",
            displayTurn: "display",
            commandBaseTurn: "base",
            visibleTurn: "visible",
            attachmentPaths: ["/tmp/a", "/tmp/b"],
            preview: "preview",
            dispatchSnapshot: snapshot)

        XCTAssertEqual(
            ticket.residentUTF8Bytes,
            [
                "display", "base", "visible", "/tmp/a", "/tmp/b", "preview",
                "gpt-5.6-sol", "gpt-5.6-sol", "gpt-5.6-sol",
                "contract-1", "binding-1", "low", "low",
                "forwarded_awaiting_provider", "none",
            ]
                .reduce(0) { $0 + $1.utf8.count })
    }

    func testForcedKillPolicyRejectsUnsafePIDs() {
        for pid in [pid_t.min, -1, 0, 1] {
            XCTAssertFalse(ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(pid))
        }
        XCTAssertTrue(ChatCLIProcessTerminationPolicy.isSafeSignalTargetPID(2))
        XCTAssertGreaterThan(
            ChatCLIProcessTerminationPolicy.forceKillDelay,
            ChatCLIProcessTerminationPolicy.interruptDelay)
    }

    func testStaleRunCannotReleaseNewerRunNoNapActivity() {
        let registry = ChatCLINoNapActivityRegistry()
        let oldToken = NSObject()
        let newToken = NSObject()

        XCTAssertNil(registry.install(oldToken, for: "run-a"))
        XCTAssertNil(registry.install(newToken, for: "run-b"))
        XCTAssertTrue(registry.contains(runID: "run-a"))
        XCTAssertTrue(registry.contains(runID: "run-b"))

        XCTAssertTrue(registry.remove(for: "run-a") === oldToken)
        XCTAssertFalse(registry.contains(runID: "run-a"))
        XCTAssertTrue(
            registry.contains(runID: "run-b"),
            "run A's late termination callback must not release run B's activity")
        XCTAssertTrue(registry.remove(for: "run-b") === newToken)
    }

    func testReplacingSameRunNoNapActivityReturnsOnlyPriorToken() {
        let registry = ChatCLINoNapActivityRegistry()
        let firstToken = NSObject()
        let retryToken = NSObject()

        XCTAssertNil(registry.install(firstToken, for: "run-a"))
        XCTAssertTrue(registry.install(retryToken, for: "run-a") === firstToken)
        XCTAssertTrue(registry.contains(runID: "run-a"))
        XCTAssertTrue(registry.remove(for: "run-a") === retryToken)
        XCTAssertNil(registry.remove(for: "run-a"))
    }

    func testWatchdogDoesNotStopFiveMinuteToolTurnWithRecentActivity() {
        let policy = ChatCLIWatchdogPolicy.production

        XCTAssertNil(policy.failureMessage(
            elapsedSinceStart: 360,
            idleInterval: 1,
            hasAssistantVisibleOutput: true,
            lastLine: "tool event"))
        XCTAssertNil(policy.failureMessage(
            elapsedSinceStart: 599,
            idleInterval: 599,
            hasAssistantVisibleOutput: false,
            lastLine: nil))
    }

    func testWatchdogStopsOnlyAfterTenMinuteProductionBoundary() {
        let policy = ChatCLIWatchdogPolicy.production

        XCTAssertNil(policy.failureMessage(
            elapsedSinceStart: 601,
            idleInterval: 599,
            hasAssistantVisibleOutput: true,
            lastLine: "thinking"))
        XCTAssertTrue(
            policy.failureMessage(
                elapsedSinceStart: 601,
                idleInterval: 600,
                hasAssistantVisibleOutput: true,
                lastLine: "thinking")?
                .contains("Chat route stalled") == true)
        XCTAssertTrue(
            policy.failureMessage(
                elapsedSinceStart: 601,
                idleInterval: 1,
                hasAssistantVisibleOutput: false,
                lastLine: "stderr startup noise")?
                .contains("Chat route degraded") == true)
    }

    func testRunnerCentralizesAllTerminationPathsBehindBoundedSIGKILLFallback() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")

        XCTAssertTrue(source.contains("private func requestBoundedTermination("))
        XCTAssertTrue(source.contains("ChatCLIProcessTerminationPolicy.forceKillDelay"))
        XCTAssertTrue(source.contains("Darwin.kill(pid, SIGKILL)"))
        XCTAssertTrue(source.contains("event: \"forced-kill\""))
        XCTAssertEqual(
            source.components(separatedBy: ".terminate()").count - 1,
            1,
            "raw TERM calls must stay centralized in requestBoundedTermination")
        for reason in [
            "bridge-handoff",
            "zero-byte-fail-fast",
            "stall-watchdog",
            "stream-failure",
            "runner-terminate"
        ] {
            XCTAssertTrue(source.contains("reason: \"\(reason)\""))
        }
    }

    func testRunnerPersistsFrozenLaunchctlDecisionBeforeEverySignalBoundary() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let bounded = try XCTUnwrap(
            source.slice(
                from: "private func requestBoundedTermination(",
                through: "private func ensureCancellationConvergenceScheduled("))
        let authority = try XCTUnwrap(
            source.slice(
                from: "private func requestCancellationTermination(",
                through: "private func ensureCancellationDecisionBeforeSignal("))
        let stop = try XCTUnwrap(
            source.slice(
                from: "func terminate() {",
                through: "deinit {"))

        XCTAssertLessThan(
            try XCTUnwrap(bounded.range(
                of: "ensureCancellationDecisionBeforeSignal(")?.lowerBound),
            try XCTUnwrap(bounded.range(
                of: "process.terminate()")?.lowerBound))
        XCTAssertLessThan(
            try XCTUnwrap(authority.range(
                of: "ensureCancellationDecisionBeforeSignal(")?.lowerBound),
            try XCTUnwrap(authority.range(
                of: "runnerAuthority.requestTermination(")?.lowerBound))
        XCTAssertLessThan(
            try XCTUnwrap(stop.range(
                of: "ensureCancellationDecisionBeforeSignal(")?.lowerBound),
            try XCTUnwrap(stop.range(
                of: "requestCancellationTermination(")?.lowerBound))
    }

    func testStructuredStreamFailureWaitsForRealProcessTermination() throws {
        let runtime = try ChatSourceFamily.read("ChatRuntime.swift")
        let page = try ChatSourceFamily.read("ChatPageModel.swift")
        let routing = try XCTUnwrap(
            runtime.slice(
                from: "let routeParsedEvents: @Sendable ([ChatCLIEvent], String, Bool) -> Void",
                through: "process.terminationHandler = { proc in"))

        XCTAssertTrue(routing.contains("if case .failure(let message) = event"))
        XCTAssertTrue(routing.contains("recordPendingRuntimeFailure(message, runID: runID)"))
        XCTAssertTrue(routing.contains("!processAlreadyExited"))
        XCTAssertTrue(routing.contains("reason: \"stream-failure\""))
        XCTAssertTrue(routing.contains("continue"))
        XCTAssertFalse(page.contains("formalRunnerStatus(runID: runID) ?? -1"))
        XCTAssertTrue(
            page.contains("guard let status = formalRunnerStatus(runID: runID) else { return }"))
    }

    func testPostExitDrainAndFlushNeverRequestTermination() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let routing = try XCTUnwrap(
            source.slice(
                from: "let routeParsedEvents: @Sendable ([ChatCLIEvent], String, Bool) -> Void",
                through: "process.terminationHandler = { proc in"))
        let termination = try XCTUnwrap(
            source.slice(
                from: "private func requestBoundedTermination(",
                through: "static func probeWrapperInactivity("))

        XCTAssertTrue(routing.contains("let processAlreadyExited = true"))
        XCTAssertTrue(
            routing.contains(
                "consume(data, fallbackPrefix, processAlreadyExited)"))
        XCTAssertTrue(
            routing.contains(
                "routeParsedEvents(lineParser.flush(), \"\", processAlreadyExited)"))
        XCTAssertTrue(routing.contains("processAlreadyExited: processAlreadyExited"))
        XCTAssertTrue(
            termination.contains(
                "guard !processAlreadyExited else { return }"),
            "post-exit structured failures may be parsed but cannot signal a dead child")
    }

    func testStreamEventGateSerializesBridgeArmBehindInFlightEventBatch() {
        let gate = ChatCLIStreamEventGate()
        let batchEntered = DispatchSemaphore(value: 0)
        let releaseBatch = DispatchSemaphore(value: 0)
        let bridgeEntered = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            gate.sync {
                batchEntered.signal()
                _ = releaseBatch.wait(timeout: .now() + 2)
            }
        }
        XCTAssertEqual(batchEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = gate.sync {
                bridgeEntered.signal()
            }
        }
        XCTAssertEqual(
            bridgeEntered.wait(timeout: .now() + 0.05),
            .timedOut,
            "bridge decision must not enter during an attempt-1 event batch")

        releaseBatch.signal()
        XCTAssertEqual(bridgeEntered.wait(timeout: .now() + 1), .success)
    }

    func testBridgeCheckpointAndPollerShareOneStreamEventGate() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let routing = try XCTUnwrap(
            source.slice(
                from: "let streamEventGate = ChatCLIStreamEventGate()",
                through: "process.terminationHandler = { proc in"))
        let checkpoint = try XCTUnwrap(
            source.slice(
                from: "private func startBridgeCheckpointIfNeeded(",
                through: "private func startZeroByteFailFastIfNeeded("))

        XCTAssertTrue(routing.contains("streamEventGate.sync"))
        XCTAssertTrue(routing.contains("tailState.drain"))
        XCTAssertTrue(routing.contains("let processAlreadyExited = true"))
        XCTAssertTrue(
            routing.contains(
                "consume(data, fallbackPrefix, processAlreadyExited)"))
        XCTAssertTrue(
            routing.contains(
                "routeParsedEvents(lineParser.flush(), \"\", processAlreadyExited)"))
        XCTAssertTrue(checkpoint.contains("streamEventGate: ChatCLIStreamEventGate"))
        XCTAssertTrue(checkpoint.contains("streamEventGate.sync"))
        XCTAssertTrue(checkpoint.contains("ownsRunningProcess(process, runID: runID)"))
    }

    func testEveryRuntimeTimerUsesActivatedFailClosedInstallation() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let install = try XCTUnwrap(
            source.slice(
                from: "private func installActivatedTimer(",
                through: "private func cancelWatchdog("))

        // 2026-08-21 D1 waiting heartbeat 併入統一安裝路徑（主導授權 6→7）
        XCTAssertEqual(
            source.components(separatedBy: "installActivatedTimer(").count - 1,
            7,
            "six timer call sites plus the helper declaration must share one install path")
        XCTAssertTrue(install.contains("timer.activate()"))
        XCTAssertTrue(install.contains("self.process === process"))
        XCTAssertTrue(install.contains("&& process.isRunning"))
        XCTAssertTrue(install.contains("&& lifecyclePhase == .running"))
        XCTAssertTrue(install.contains("if !installed {\n            timer.cancel()"))
        XCTAssertFalse(source.contains("timer.resume()"))
    }

    func testRunnerDeliversFinalAssistantJSONLWithoutTrailingNewlineBeforeFormalExit() {
        let terminal = expectation(description: "formal terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()
        let marker = "TATWO_FINAL_UNTERMINATED_ASSISTANT"
        let json = #"{"type":"item.completed","item":{"id":"item-final","type":"agent_message","text":"\#(marker)"}}"#

        runner.start(
            command: fixtureCommand(output: json),
            runID: "final-assistant-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)

        XCTAssertEqual(recorder.outputTexts, [marker])
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertEqual(recorder.exitStatuses, [0])
        XCTAssertTrue(recorder.runtimeFailureTexts.isEmpty)
    }

    func testRunnerDeliversFinalStructuredFailureWithoutTrailingNewlineAsFormalFailure() {
        let terminal = expectation(description: "formal failure")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()
        let json = #"{"type":"response.failed","error":{"message":"TATWO_FINAL_UNTERMINATED_FAILURE"}}"#

        runner.start(
            command: fixtureCommand(output: json),
            runID: "final-failure-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)

        XCTAssertTrue(recorder.outputTexts.isEmpty)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertTrue(recorder.exitStatuses.isEmpty)
        XCTAssertEqual(
            recorder.runtimeFailureTexts,
            ["TATWO_FINAL_UNTERMINATED_FAILURE"])

        let delayedSignalFence = expectation(description: "bounded signal timers settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.35) {
            delayedSignalFence.fulfill()
        }
        wait(for: [delayedSignalFence], timeout: 2)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testStructuredFailureFencesLateCompletionFromSameReadBatch() {
        let terminal = expectation(description: "formal failure")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()
        let stream = """
        {"type":"response.output_text.delta","delta":"PARTIAL_BEFORE_FAILURE"}
        {"type":"response.failed","error":{"message":"AUTHORITATIVE_STREAM_FAILURE"}}
        {"type":"item.completed","item":{"id":"late-item","type":"agent_message","text":"LATE_SUCCESS_MUST_NOT_PUBLISH"}}
        {"type":"turn.completed","model":"fable-5"}

        """

        runner.start(
            command: fixtureCommand(output: stream),
            runID: "failure-fences-late-completion-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)

        XCTAssertEqual(recorder.outputTexts, ["PARTIAL_BEFORE_FAILURE"])
        XCTAssertEqual(
            recorder.runtimeFailureTexts,
            ["AUTHORITATIVE_STREAM_FAILURE"])
        XCTAssertFalse(
            recorder.outputTexts.contains("LATE_SUCCESS_MUST_NOT_PUBLISH"))
        XCTAssertTrue(recorder.exitStatuses.isEmpty)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testCodexExecReconnectProgressKeepsSameAttemptAliveThroughCompletion() {
        let terminal = expectation(description: "formal completion")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let marker = "RECONNECTED_SAME_ATTEMPT_OK"
        let first =
            #"{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion: stream closed before response.completed)"}"#
        let final = """
        {"type":"error","message":"Reconnecting... 2/5 (stream disconnected before completion: upstream reset)"}
        {"type":"item.completed","item":{"id":"reconnect-final","type":"agent_message","text":"\(marker)"}}
        {"type":"turn.completed"}

        """
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: codexExecStagedFixtureCommand(
                firstOutput: first,
                finalOutput: final,
                delay: 0.35),
            runID: "codex-reconnect-progress-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)

        XCTAssertEqual(
            recorder.reconnectProgress.map { [$0.attempt, $0.maximumAttempts] },
            [[1, 5], [2, 5]])
        XCTAssertEqual(recorder.outputTexts, [marker])
        XCTAssertEqual(recorder.exitStatuses, [0])
        XCTAssertTrue(recorder.runtimeFailureTexts.isEmpty)
        XCTAssertEqual(runner.diagnosticsSnapshot.physicalAttempt, 1)
    }

    func testReconnectProgressBeforeDuplicateTerminalFailurePublishesOnlyOnce() {
        let terminal = expectation(description: "one formal failure")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()
        let stream = """
        {"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion: upstream reset)"}
        {"type":"response.failed","error":{"message":"AUTHORITATIVE_RECONNECT_EXHAUSTED"}}
        {"type":"response.failed","error":{"message":"DUPLICATE_MUST_NOT_PUBLISH"}}
        {"type":"item.completed","item":{"id":"late","type":"agent_message","text":"LATE_SUCCESS_MUST_NOT_PUBLISH"}}

        """

        runner.start(
            command: fixtureCommand(output: stream),
            runID: "reconnect-duplicate-terminal-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)

        XCTAssertEqual(recorder.reconnectProgress.map(\.attempt), [1])
        XCTAssertEqual(
            recorder.runtimeFailureTexts,
            ["AUTHORITATIVE_RECONNECT_EXHAUSTED"])
        XCTAssertTrue(recorder.outputTexts.isEmpty)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
    }

    func testOutputPollerPublishesHeadAndFinalizerFlushesUnterminatedTail() {
        let firstOutput = expectation(description: "poller delivered first output")
        let terminal = expectation(description: "formal terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminal,
            firstOutputExpectation: firstOutput)
        let runner = ChatCLIProcessRunner()
        let head = #"{"type":"item.completed","item":{"id":"item-head","type":"agent_message","text":"TATWO_POLLER_HEAD"}}"#
        let tail = #"{"type":"item.completed","item":{"id":"item-tail","type":"agent_message","text":"TATWO_FINALIZER_TAIL"}}"#

        runner.start(
            command: stagedFixtureCommand(
                firstOutput: head,
                finalOutput: tail,
                // Keep the child alive long enough for the production poller
                // to publish `head`, but leave real scheduling slack before
                // the separate five-second terminal expectation expires.
                delay: 0.5),
            runID: "poller-finalizer-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [firstOutput], timeout: 3)
        let running = runner.diagnosticsSnapshot
        XCTAssertTrue(running.hasProcessReference)
        XCTAssertTrue(running.processIsRunning)
        XCTAssertGreaterThan(
            running.activeTimerCount,
            0,
            "this test must exercise an installed poller, not only final drain")

        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(
            recorder.outputTexts,
            ["TATWO_POLLER_HEAD", "TATWO_FINALIZER_TAIL"])
        XCTAssertEqual(recorder.eventTags.last, "exit:0")
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertEqual(runner.diagnosticsSnapshot.activeTimerCount, 0)
    }

    func testOneRunnerSurvivesOneHundredPollerPartialAndUnterminatedJSONLFinalizeRacesWithoutLossDuplicateOrLeak() {
        let pollObserver = ChatOutputPollObserverRecorder()
        let runner = ChatCLIProcessRunner(
            outputPollPolicy: ChatCLIOutputPollPolicy(
                initialDelay: 0.01,
                repeatInterval: 0.01),
            outputPollObserver: pollObserver.record)

        for turn in 0..<100 {
            let firstOutput = expectation(description: "turn \(turn) poller output")
            let terminal = expectation(description: "turn \(turn) terminal")
            terminal.assertForOverFulfill = true
            let recorder = ChatRuntimeEventRecorder(
                terminalExpectation: terminal,
                firstOutputExpectation: firstOutput,
                firstOutputBlock: 0.35)
            let headMarker = "TATWO_POLLER_RACE_HEAD_\(turn)"
            let tailMarker = "TATWO_POLLER_RACE_TAIL_\(turn)"
            let runID = "poller-finalizer-race-\(turn)-\(UUID().uuidString)"
            let releaseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(runID)-release")
            let headJSON = #"{"type":"item.completed","item":{"id":"head-\#(turn)","type":"agent_message","text":"\#(headMarker)"}}"#
            let tail = #"{"type":"item.completed","item":{"id":"tail-\#(turn)","type":"agent_message","text":"\#(tailMarker)"}}"#
            let split = max(1, headJSON.count / 2)
            let headPrefix = String(headJSON.prefix(split))
            let headSuffix = String(headJSON.dropFirst(split))

            runner.start(
                command: partialGatedStagedFixtureCommand(
                    firstOutputPrefix: headPrefix,
                    firstOutputSuffix: headSuffix,
                    finalOutput: tail,
                    releaseFilePath: releaseURL.path),
                runID: runID,
                onEvent: recorder.record)

            wait(for: [firstOutput], timeout: 3)
            XCTAssertTrue(
                pollObserver.contains(runID),
                "turn \(turn) must be published by an installed poller before finalization")
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: releaseURL.path,
                    contents: Data()),
                "turn \(turn) must release the staged child")

            wait(for: [terminal], timeout: 5)
            try? FileManager.default.removeItem(at: releaseURL)
            XCTAssertEqual(
                recorder.outputTexts,
                [headMarker, tailMarker],
                "turn \(turn)")
            XCTAssertEqual(
                recorder.eventTags,
                ["output:\(headMarker)", "output:\(tailMarker)", "exit:0"],
                "turn \(turn)")
            XCTAssertEqual(recorder.formalTerminalCount, 1, "turn \(turn)")

            let settled = runner.diagnosticsSnapshot
            XCTAssertFalse(settled.hasProcessReference, "turn \(turn)")
            XCTAssertFalse(settled.processIsRunning, "turn \(turn)")
            XCTAssertEqual(settled.activeTimerCount, 0, "turn \(turn)")
            XCTAssertEqual(settled.noNapActivityCount, 0, "turn \(turn)")
            XCTAssertEqual(settled.lifecyclePhase, .terminated, "turn \(turn)")
        }

        let postRaceFirstOutput = expectation(
            description: "post-race poller output")
        let postRaceTerminal = expectation(
            description: "post-race formal terminal")
        postRaceTerminal.assertForOverFulfill = true
        let postRaceRecorder = ChatRuntimeEventRecorder(
            terminalExpectation: postRaceTerminal,
            firstOutputExpectation: postRaceFirstOutput)
        let postRaceRunID =
            "poller-finalizer-post-race-\(UUID().uuidString)"
        let postRaceHead = "TATWO_POLLER_POST_RACE_HEAD"
        let postRaceTail = "TATWO_POLLER_POST_RACE_TAIL"
        let postRaceHeadJSON =
            #"{"type":"item.completed","item":{"id":"post-race-head","type":"agent_message","text":"\#(postRaceHead)"}}"#
        let postRaceTailJSON =
            #"{"type":"item.completed","item":{"id":"post-race-tail","type":"agent_message","text":"\#(postRaceTail)"}}"#

        let postRaceIdentity = runner.start(
            command: stagedFixtureCommand(
                firstOutput: postRaceHeadJSON,
                finalOutput: postRaceTailJSON,
                delay: 0.5),
            runID: postRaceRunID,
            onEvent: postRaceRecorder.record)

        wait(for: [postRaceFirstOutput], timeout: 3)
        let postRaceRunning = runner.diagnosticsSnapshot
        XCTAssertTrue(pollObserver.contains(postRaceRunID))
        XCTAssertTrue(postRaceRunning.hasProcessReference)
        XCTAssertTrue(postRaceRunning.processIsRunning)
        XCTAssertGreaterThan(postRaceRunning.activeTimerCount, 0)
        XCTAssertEqual(postRaceRunning.lifecycleRunID, postRaceRunID)
        XCTAssertEqual(postRaceRunning.authorityIdentity, postRaceIdentity)
        XCTAssertEqual(postRaceRunning.physicalAttempt, 1)

        wait(for: [postRaceTerminal], timeout: 5)
        XCTAssertEqual(
            postRaceRecorder.outputTexts,
            [postRaceHead, postRaceTail])
        XCTAssertEqual(
            postRaceRecorder.eventTags,
            [
                "output:\(postRaceHead)",
                "output:\(postRaceTail)",
                "exit:0",
            ])
        XCTAssertEqual(postRaceRecorder.formalTerminalCount, 1)
        XCTAssertTrue(postRaceRecorder.runtimeFailureTexts.isEmpty)

        let postRaceSettled = runner.diagnosticsSnapshot
        XCTAssertFalse(postRaceSettled.hasProcessReference)
        XCTAssertFalse(postRaceSettled.processIsRunning)
        XCTAssertEqual(postRaceSettled.activeTimerCount, 0)
        XCTAssertEqual(postRaceSettled.noNapActivityCount, 0)
        XCTAssertEqual(postRaceSettled.lifecycleRunID, postRaceRunID)
        XCTAssertEqual(postRaceSettled.authorityIdentity, postRaceIdentity)
        XCTAssertEqual(postRaceSettled.physicalAttempt, 1)
        XCTAssertEqual(postRaceSettled.lifecyclePhase, .terminated)
    }

    func testMainQueueDeliveryKeepsFinalAssistantBeforeFormalTerminal() throws {
        let page = try ChatSourceFamily.read("ChatPageModel.swift")
        let callback = try XCTUnwrap(
            page.slice(
                from: "let runnerIdentity = dispatchService.startRuntime(",
                through: "startRunnerStateReconciler(for: assistantID, runID: runID)"))
        XCTAssertTrue(callback.contains("activityTurnID: assistantID"))
        XCTAssertTrue(callback.contains("DispatchQueue.main.async"))
        XCTAssertFalse(callback.contains("Task { @MainActor"))

        let terminal = expectation(description: "main queue formal terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()
        let marker = "TATWO_MAIN_QUEUE_FINAL_ASSISTANT"
        let json = #"{"type":"item.completed","item":{"id":"item-main","type":"agent_message","text":"\#(marker)"}}"#

        runner.start(
            command: fixtureCommand(output: json),
            runID: "main-queue-order-\(UUID().uuidString)")
        { event in
            DispatchQueue.main.async {
                recorder.record(event)
            }
        }

        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(recorder.eventTags, ["output:\(marker)", "exit:0"])
    }

    func testOneRunnerReuseKeepsTimerHygieneAcrossOneHundredUnterminatedJSONLTurns() {
        let runner = ChatCLIProcessRunner()

        for turn in 0..<100 {
            let terminal = expectation(description: "turn \(turn) terminal")
            terminal.assertForOverFulfill = true
            let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
            let marker = "TATWO_SAME_RUNNER_SOAK_\(turn)"
            let json = #"{"type":"item.completed","item":{"id":"item-\#(turn)","type":"agent_message","text":"\#(marker)"}}"#

            runner.start(
                command: fixtureCommand(output: json),
                runID: "same-runner-soak-\(turn)-\(UUID().uuidString)",
                onEvent: recorder.record)

            wait(for: [terminal], timeout: 5)

            XCTAssertEqual(recorder.outputTexts, [marker], "turn \(turn)")
            XCTAssertEqual(recorder.formalTerminalCount, 1, "turn \(turn)")
            XCTAssertEqual(recorder.exitStatuses, [0], "turn \(turn)")
            XCTAssertTrue(recorder.runtimeFailureTexts.isEmpty, "turn \(turn)")

            let diagnostics = runner.diagnosticsSnapshot
            XCTAssertFalse(diagnostics.hasProcessReference, "turn \(turn)")
            XCTAssertFalse(diagnostics.processIsRunning, "turn \(turn)")
            XCTAssertEqual(diagnostics.activeTimerCount, 0, "turn \(turn)")
            XCTAssertEqual(diagnostics.noNapActivityCount, 0, "turn \(turn)")
            XCTAssertEqual(diagnostics.lifecyclePhase, .terminated, "turn \(turn)")
        }
    }

    func testLateDuplicateTerminalIsRejectedAfterRunnerSettles() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let lifecycle = try XCTUnwrap(
            source.slice(
                from: "private func recordFormalTermination(",
                through: "private func commitFormalTerminationLocked("))
        let fence = try XCTUnwrap(
            source.slice(
                from: "private func emitFormalTermination(",
                through: "@discardableResult\n    private func recordFormalTermination("))

        XCTAssertTrue(
            lifecycle.contains(
                "guard lifecycleRunID == runID, lifecyclePhase != .terminated else { return nil }"))
        XCTAssertTrue(
            fence.contains("guard eventFence.commitFormalTerminal() else { return }"))

        let terminal = expectation(description: "one settled terminal")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner(
            terminationCallbackDelivery: { callback in
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 0.35,
                    execute: callback)
            })
        runner.start(
            command: cancellableFixtureCommand(),
            runID: "late-duplicate-settling-\(UUID().uuidString)",
            onEvent: recorder.record)
        XCTAssertTrue(waitUntilRunnerIsRunning(runner))

        runner.terminate()
        wait(for: [terminal], timeout: 3)
        let settled = expectation(description: "late callback settled")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.65) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1)

        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertEqual(runner.diagnosticsSnapshot.lifecyclePhase, .terminated)
    }

    func testChatPageModelUIVisibleFinalAssistantTextPrecedesFormalFinish() throws {
        let page = try ChatSourceFamily.read("ChatPageModel.swift")
        let handle = try XCTUnwrap(
            page.slice(
                from: "private func handle(_ event: ChatCLIEvent, runID: String)",
                through: "private func formalRunnerStatus(runID: String)"))

        guard
            let outputRange = handle.range(
                of: "appendPlanAwareAssistantOutput(projection.text)"),
            let exitRange = handle.range(
                of: "case .exit(let status):"),
            let terminalRange = handle.range(
                of: "acceptFormalTerminalEvent(runID: runID, status: status)")
        else {
            XCTFail("ChatPageModel handle ordering seam is missing")
            return
        }
        XCTAssertLessThan(
            outputRange.lowerBound,
            exitRange.lowerBound,
            "the UI-visible assistant append branch must precede the formal exit branch")
        XCTAssertLessThan(
            outputRange.lowerBound,
            terminalRange.lowerBound,
            "final assistant text must be appended before formal finish is accepted")

        let firstOutput = expectation(description: "UI-visible final assistant text")
        let terminal = expectation(description: "UI-visible formal finish")
        terminal.assertForOverFulfill = true
        let recorder = ChatRuntimeEventRecorder(
            terminalExpectation: terminal,
            firstOutputExpectation: firstOutput)
        let runner = ChatCLIProcessRunner()
        let marker = "TATWO_CHAT_PAGE_UI_VISIBLE_FINAL"
        let json = #"{"type":"item.completed","item":{"id":"item-page-ui","type":"agent_message","text":"\#(marker)"}}"#
        runner.start(
            command: fixtureCommand(output: json),
            runID: "chat-page-ui-order-\(UUID().uuidString)",
            onEvent: { event in
                DispatchQueue.main.async {
                    recorder.record(event)
                }
            })
        wait(for: [firstOutput, terminal], timeout: 5, enforceOrder: true)
        XCTAssertEqual(recorder.eventTags, ["output:\(marker)", "exit:0"])
    }

    func testBridgeCheckpointInstallRejectionLeavesSkippedReceipt() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let checkpoint = try XCTUnwrap(
            source.slice(
                from: "private func startBridgeCheckpointIfNeeded(",
                through: "private func startZeroByteFailFastIfNeeded("))
        XCTAssertTrue(checkpoint.contains("if installed"))
        XCTAssertTrue(checkpoint.contains("event: \"bridge-checkpoint-skipped\""))
        XCTAssertTrue(checkpoint.contains("\"reason\": \"install-rejected\""))
    }

    func testGatewayDirectStreamedProducerShapeAppendsOnlyDeltas() {
        let stream = """
        {"type":"thread.started","thread_id":"tatwo-gateway-streaming"}
        {"type":"turn.started"}
        {"type":"response.output_text.delta","delta":"DIRECT_"}
        {"type":"response.output_text.delta","delta":"GATEWAY_OK"}
        {"type":"system","control_type":"response.output_item.done","item_id":"msg_1","item_type":"message","source":"model_gateway_sse"}
        {"type":"system","control_type":"response.completed","source":"model_gateway_sse"}
        {"type":"turn.completed","output_delivery":{"mode":"delta","streamed":true,"delta_event_count":2}}

        """

        let result = normalizedAssistantText(from: stream)

        XCTAssertEqual(result.fragments, ["DIRECT_", "GATEWAY_OK"])
        XCTAssertEqual(result.text, "DIRECT_GATEWAY_OK")
    }

    func testGatewayDirectTerminalFallbackProducerShapeAppendsOnePayload() {
        let stream = """
        {"type":"thread.started","thread_id":"tatwo-gateway-fallback"}
        {"type":"turn.started"}
        {"type":"system","control_type":"response.output_item.done","item_id":"msg_1","item_type":"message","source":"model_gateway_sse"}
        {"type":"system","control_type":"response.completed","source":"model_gateway_sse"}
        {"type":"item.completed","item":{"id":"msg_1","type":"agent_message","text":"DIRECT_GATEWAY_OK"}}
        {"type":"turn.completed","output_delivery":{"mode":"terminal_fallback","streamed":true,"delta_event_count":0}}

        """

        let result = normalizedAssistantText(from: stream)

        XCTAssertEqual(result.fragments, ["DIRECT_GATEWAY_OK"])
        XCTAssertEqual(result.text, "DIRECT_GATEWAY_OK")
    }

    // MARK: - M3a 更新：timeout / retry / stderr

    func testM3aSpawnRetryPolicyRetriesOnlyZeroOutputNonzeroFirstAttempt() {
        XCTAssertTrue(
            ChatCLISpawnRetryPolicy.shouldRetry(
                attempt: 1,
                terminationStatus: 7,
                stdoutByteCount: 0))
        XCTAssertFalse(
            ChatCLISpawnRetryPolicy.shouldRetry(
                attempt: 1,
                terminationStatus: 7,
                stdoutByteCount: 1))
        XCTAssertFalse(
            ChatCLISpawnRetryPolicy.shouldRetry(
                attempt: 2,
                terminationStatus: 7,
                stdoutByteCount: 0))
        XCTAssertFalse(
            ChatCLISpawnRetryPolicy.shouldRetry(
                attempt: 1,
                terminationStatus: 0,
                stdoutByteCount: 0))
    }

    func testM3aZeroOutputFailureRetriesExactlyOnceThenSucceeds() {
        let terminal = expectation(description: "retry completion")
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("m3a-retry-\(UUID().uuidString)")
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: retryOnceFixtureCommand(marker: marker),
            runID: "m3a-zero-output-retry-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(runner.diagnosticsSnapshot.physicalAttempt, 2)
        XCTAssertEqual(recorder.outputTexts, ["M3A_RETRY_OK"])
        XCTAssertEqual(recorder.exitStatuses, [0])
        XCTAssertEqual(
            recorder.diagnosticTexts.filter {
                $0.contains("zero_output_nonzero_exit")
            }.count,
            1)
    }

    func testM3aAnyStdoutFailureDoesNotRetry() {
        let terminal = expectation(description: "output failure")
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: fixtureCommand(output: "VISIBLE_SIDE_EFFECT", exitStatus: 9),
            runID: "m3a-output-no-retry-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(runner.diagnosticsSnapshot.physicalAttempt, 1)
        XCTAssertFalse(
            recorder.diagnosticTexts.contains {
                $0.contains("spawn_retry=1")
            })
    }

    func testM3aHardTimeoutEndsTurnWithExistingFailureEvent() {
        let terminal = expectation(description: "hard timeout failure")
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner(
            watchdogPolicy: ChatCLIWatchdogPolicy(
                startupGrace: 30,
                stallTimeout: 30),
            hardTurnTimeout: 0.15)

        runner.start(
            command: signalTerminatedFixtureCommand(),
            runID: "m3a-hard-timeout-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(recorder.formalTerminalCount, 1)
        XCTAssertTrue(
            recorder.runtimeFailureTexts.first?.contains(
                "Chat CLI turn timed out") == true)
    }

    func testM3aFinalFailurePreservesCappedStderrTail() {
        let terminal = expectation(description: "stderr failure")
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()

        runner.start(
            command: stderrFailureFixtureCommand(),
            runID: "m3a-stderr-tail-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(runner.diagnosticsSnapshot.physicalAttempt, 2)
        let failure = recorder.runtimeFailureTexts.joined()
        XCTAssertTrue(failure.contains("stderr_tail_8kb:"))
        XCTAssertTrue(failure.contains("M3A_STDERR_TAIL_MARKER"))
        XCTAssertLessThan(failure.utf8.count, 8 * 1024 + 512)
    }

    func testM3aProcessLaunchFailureRetriesOnce() {
        let terminal = expectation(description: "launch failure")
        let recorder = ChatRuntimeEventRecorder(terminalExpectation: terminal)
        let runner = ChatCLIProcessRunner()
        let command = ChatCLICommand(
            engine: .codex,
            executable: "/definitely/missing/m3a-cli",
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)

        runner.start(
            command: command,
            runID: "m3a-launch-retry-\(UUID().uuidString)",
            onEvent: recorder.record)

        wait(for: [terminal], timeout: 5)
        XCTAssertEqual(runner.diagnosticsSnapshot.physicalAttempt, 2)
        XCTAssertEqual(
            recorder.diagnosticTexts.filter {
                $0.contains("process_launch_failure")
            }.count,
            1)
    }

    private func fixtureCommand(output: String, exitStatus: Int32 = 0) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s' "$1"; exit "$2""#,
                "--",
                output,
                String(exitStatus),
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func retryOnceFixtureCommand(marker: URL) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"if [ ! -e "$1" ]; then : > "$1"; exit 7; fi; printf '%s' '{"type":"item.completed","item":{"id":"m3a","type":"agent_message","text":"M3A_RETRY_OK"}}'; exit 0"#,
                "--",
                marker.path,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func stderrFailureFixtureCommand() -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"i=0; while [ "$i" -lt 9000 ]; do printf x >&2; i=$((i+1)); done; printf 'M3A_STDERR_TAIL_MARKER' >&2; exit 9"#,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func selfSIGTERMFixtureCommand() -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                "kill -TERM $$",
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func signalTerminatedFixtureCommand() -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sleep",
            arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func stagedFixtureCommand(
        firstOutput: String,
        finalOutput: String,
        delay: TimeInterval
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s\n' "$1"; sleep "$3"; printf '%s' "$2"; exit 0"#,
                "--",
                firstOutput,
                finalOutput,
                String(delay),
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func codexExecStagedFixtureCommand(
        firstOutput: String,
        finalOutput: String,
        delay: TimeInterval
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s\n' "$1"; sleep "$3"; printf '%s' "$2"; exit 0"#,
                "--",
                firstOutput,
                finalOutput,
                String(delay),
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .codexExec,
            commandMode: .chat)
    }

    private func gatedStagedFixtureCommand(
        firstOutput: String,
        finalOutput: String,
        releaseFilePath: String
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s\n' "$1"; while [ ! -e "$3" ]; do sleep 0.01; done; printf '%s' "$2"; exit 0"#,
                "--",
                firstOutput,
                finalOutput,
                releaseFilePath,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func partialGatedStagedFixtureCommand(
        firstOutputPrefix: String,
        firstOutputSuffix: String,
        finalOutput: String,
        releaseFilePath: String
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s' "$1"; sleep 0.01; printf '%s\n' "$2"; while [ ! -e "$4" ]; do sleep 0.01; done; printf '%s' "$3"; exit 0"#,
                "--",
                firstOutputPrefix,
                firstOutputSuffix,
                finalOutput,
                releaseFilePath,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func cancellationLateOutputFixtureCommand(
        firstOutput: String,
        lateOutput: String
    ) -> ChatCLICommand {
        let firstJSON =
            #"{"type":"item.completed","item":{"id":"before-cancel","type":"agent_message","text":"\#(firstOutput)"}}"#
        let lateJSON =
            #"{"type":"item.completed","item":{"id":"after-cancel","type":"agent_message","text":"\#(lateOutput)"}}"#
        return ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"printf '%s\n' "$1"; trap 'printf "%s" "$2"; exit 143' TERM INT; while :; do sleep 0.05; done"#,
                "--",
                firstJSON,
                lateJSON,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func cancellationLateFormalSuccessFixtureCommand() -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"trap 'printf "%s\n" "{\"type\":\"turn.completed\"}"; exit 143' TERM INT; printf "%s\n" "{\"type\":\"item.completed\",\"item\":{\"id\":\"cancel-ready\",\"type\":\"agent_message\",\"text\":\"TATWO_READY_TO_CANCEL\"}}"; while :; do sleep 0.05; done"#,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: true,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func cancellableFixtureCommand(
        ownedTemporaryFiles: [TatwoChatOwnedTemporaryFile] = []
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"trap 'exit 143' TERM INT; while :; do sleep 0.05; done"#,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat,
            ownedTemporaryFiles: ownedTemporaryFiles)
    }

    private func launchctlCancellableFixtureCommand() -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"trap 'exit 143' TERM INT; while :; do sleep 0.05; done"#,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .codexExec,
            commandMode: .chat)
    }

    private func ownedSleepDescendantFixtureCommand(
        childPIDFile: URL,
        childReadyFile: URL
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"trap 'exit 143' TERM INT; /bin/sh -c 'trap "" TERM INT; printf "%s\n" ready > "$1"; exec /bin/sleep 30' -- "$2" & child=$!; printf '%s\n' "$child" > "$1"; wait "$child""#,
                "--",
                childPIDFile.path,
                childReadyFile.path,
            ],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func gatewayPromptPlan(prompt: String) -> TatwoChatCommandPlan {
        TatwoChatCommandPlanner.plan(
            mode: .chat,
            route: TatwoChatRouteProfile(
                id: "deprecated-gateway-lifecycle-fixture",
                displayName: "Deprecated gateway lifecycle fixture",
                family: "Deprecated",
                engine: .codex,
                runtimeAdapter: .gatewayDirect,
                canonicalModelSlug: "deprecated-lifecycle-fixture",
                modelArgument: "deprecated-lifecycle-fixture",
                contextWindowLabel: "fixture",
                supportsImageInput: false,
                pluginFit: "historical lifecycle only",
                sessionRisk: "deprecated",
                defaultEffort: .low,
                allowedEfforts: [],
                notes: ["M3b 更新：正式 Chat route 不得選用"]),
            turn: prompt,
            workingDirectoryPath: FileManager.default.temporaryDirectory.path,
            permissionPreset: .approveForMe,
            effort: .high,
            gatewayDirectScriptPath: "/tmp/tatwo-direct-gateway-chat.mjs",
            toolHostRequirementTurn: prompt,
            computerHostRunID: "gateway-prompt-lifecycle-run",
            computerHostTurnID: "gateway-prompt-lifecycle-turn")
    }

    private func waitUntilRunnerIsRunning(
        _ runner: ChatCLIProcessRunner,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runner.diagnosticsSnapshot.processIsRunning {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func waitForPID(
        in file: URL,
        timeout: TimeInterval
    ) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               value > 1
            {
                return value
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private func waitForNonEmptyFile(
        at file: URL,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file), !data.isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func waitUntilProcessIsGone(
        _ pid: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func assertProcessProbeIsESRCH(
        _ pid: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        errno = 0
        XCTAssertEqual(
            Darwin.kill(pid, 0),
            -1,
            file: file,
            line: line)
        XCTAssertEqual(
            errno,
            ESRCH,
            file: file,
            line: line)
    }

    private func normalizedAssistantText(
        from stream: String
    ) -> (fragments: [String], text: String) {
        let normalizer = TatwoNativeChatStreamNormalizer(
            engine: .codex,
            emitsSessionEvents: false)
        let fragments = normalizer.consume(stream)
            .filter { $0.kind == .message }
            .map(\.text)
        let text = fragments.reduce(into: "") { accumulated, fragment in
            accumulated = ChatPageAssistantTextAppendPolicy.appending(
                fragment,
                to: accumulated)
        }
        return (fragments, text)
    }
}

private final class ChatLaunchctlProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let firstPresentExpectation: XCTestExpectation
    private var deliveredFirstPresent = false
    private var absent = false
    private var count = 0

    init(firstPresentExpectation: XCTestExpectation) {
        self.firstPresentExpectation = firstPresentExpectation
    }

    func probe(
        label: String,
        uid: uid_t
    ) -> ChatCLILaunchctlLabelProbeResult {
        _ = label
        _ = uid
        lock.lock()
        count += 1
        let shouldReportAbsent = absent
        let shouldFulfill = !shouldReportAbsent && !deliveredFirstPresent
        if shouldFulfill {
            deliveredFirstPresent = true
        }
        lock.unlock()
        if shouldFulfill {
            firstPresentExpectation.fulfill()
        }
        return shouldReportAbsent ? .absent : .present
    }

    func markAbsent() {
        lock.lock()
        absent = true
        lock.unlock()
    }

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ChatDescendantCaptureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let firstResult: ChatCLIOwnedDescendantCaptureResult
    private var shouldUseLiveCapture = false
    private var count = 0

    init(firstResult: ChatCLIOwnedDescendantCaptureResult) {
        self.firstResult = firstResult
    }

    func capture(
        rootPID: pid_t,
        maximumCount: Int
    ) -> ChatCLIOwnedDescendantCaptureResult {
        lock.lock()
        count += 1
        let currentCount = count
        let useLiveCapture = shouldUseLiveCapture
        lock.unlock()
        if currentCount == 1 || !useLiveCapture {
            return firstResult
        }
        return ChatCLIOwnedDescendantCapture.capture(
            rootPID: rootPID,
            maximumCount: maximumCount)
    }

    func useLiveCapture() {
        lock.lock()
        shouldUseLiveCapture = true
        lock.unlock()
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ChatPartialKnownDescendantCaptureRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0
    private var knownDescendantCount = 0

    func capture(
        rootPID: pid_t,
        maximumCount: Int
    ) -> ChatCLIOwnedDescendantCaptureResult {
        lock.lock()
        count += 1
        let currentCount = count
        lock.unlock()

        guard currentCount == 1 else {
            // Simulate a retry observation after the first child has already
            // reparented/disappeared from the wrapper's current child list.
            // ChatCLICancellationContext must union this empty fresh result
            // with the exact identities learned by the blocked first capture.
            return .captured([])
        }
        let live = ChatCLIOwnedDescendantCapture.capture(
            rootPID: rootPID,
            maximumCount: maximumCount)
        switch live {
        case .captured(let descendants):
            lock.lock()
            knownDescendantCount = descendants.count
            lock.unlock()
            return .blocked(
                knownDescendants: descendants,
                reason: "transient-after-partial-identity-capture")
        case .blocked(let knownDescendants, let reason):
            lock.lock()
            knownDescendantCount = knownDescendants.count
            lock.unlock()
            return .blocked(
                knownDescendants: knownDescendants,
                reason: reason)
        }
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var firstKnownDescendantCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return knownDescendantCount
    }
}

private final class ChatCapturedThenEmptyDescendantRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    func capture(
        rootPID: pid_t,
        maximumCount: Int
    ) -> ChatCLIOwnedDescendantCaptureResult {
        lock.lock()
        count += 1
        let currentCount = count
        lock.unlock()
        guard currentCount == 1 else {
            return .captured([])
        }
        return ChatCLIOwnedDescendantCapture.capture(
            rootPID: rootPID,
            maximumCount: maximumCount)
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ControllableChatRunnerAuthority:
    ChatRunnerAuthorityRecording,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var terminationResult: ChatRunnerTerminationRequestResult
    private var terminationRequests = 0
    private var attemptTerminalStatuses: [Int32] = []
    private var runTerminalStatuses: [Int32] = []
    private var runTerminalResult: ChatRunnerTerminalPersistenceResult =
        .persisted

    init(terminationResult: ChatRunnerTerminationRequestResult) {
        self.terminationResult = terminationResult
    }

    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        .unknown(reason: "test-controllable-authority")
    }

    func requestTermination(
        for identity: ChatRunnerAttemptIdentity
    ) -> ChatRunnerTerminationRequestResult {
        _ = identity
        lock.lock()
        defer { lock.unlock() }
        terminationRequests += 1
        return terminationResult
    }

    func claim(
        runID: String,
        attempt: UInt64
    ) throws -> ChatRunnerAttemptIdentity {
        ChatRunnerAttemptIdentity(
            runID: runID,
            attempt: attempt,
            instanceID: UUID(),
            revision: attempt)
    }

    func attach(
        identity: ChatRunnerAttemptIdentity,
        launch: ChatRunnerLaunchIdentity
    ) throws {
        _ = identity
        _ = launch
    }

    func heartbeat(identity: ChatRunnerAttemptIdentity) {
        _ = identity
    }

    func recordAttemptTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        _ = identity
        lock.lock()
        attemptTerminalStatuses.append(status)
        lock.unlock()
        return .persisted
    }

    func recordRunTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        _ = identity
        lock.lock()
        runTerminalStatuses.append(status)
        let result = runTerminalResult
        lock.unlock()
        return result
    }

    func setTerminationResult(
        _ result: ChatRunnerTerminationRequestResult
    ) {
        lock.lock()
        terminationResult = result
        lock.unlock()
    }

    func setRunTerminalResult(
        _ result: ChatRunnerTerminalPersistenceResult
    ) {
        lock.lock()
        runTerminalResult = result
        lock.unlock()
    }

    var terminationRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequests
    }

    var formalTerminalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runTerminalStatuses.count
    }

    var attemptTerminalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptTerminalStatuses.count
    }
}

private struct RejectingChatRunnerAuthority: ChatRunnerAuthorityRecording {
    private enum Rejection: Error {
        case rejected
    }

    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        .unknown(reason: "test-authority-rejects-claim")
    }

    func requestTermination(
        for identity: ChatRunnerAttemptIdentity
    ) -> ChatRunnerTerminationRequestResult {
        _ = identity
        return .unknown(reason: "test-authority-rejects-claim")
    }

    func claim(
        runID: String,
        attempt: UInt64
    ) throws -> ChatRunnerAttemptIdentity {
        _ = runID
        _ = attempt
        throw Rejection.rejected
    }

    func attach(
        identity: ChatRunnerAttemptIdentity,
        launch: ChatRunnerLaunchIdentity
    ) throws {
        _ = identity
        _ = launch
        throw Rejection.rejected
    }

    func heartbeat(identity: ChatRunnerAttemptIdentity) {
        _ = identity
    }

    func recordAttemptTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        _ = identity
        _ = status
        return .blocked(reason: "test-authority-rejects-attempt-terminal")
    }

    func recordRunTerminal(
        identity: ChatRunnerAttemptIdentity,
        status: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        _ = identity
        _ = status
        return .blocked(reason: "test-authority-rejects-run-terminal")
    }
}

private final class ChatOutputPollObserverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var runIDs: Set<String> = []

    func record(_ runID: String) {
        lock.lock()
        runIDs.insert(runID)
        lock.unlock()
    }

    func contains(_ runID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runIDs.contains(runID)
    }
}

private final class ChatRuntimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let terminalExpectation: XCTestExpectation
    private let firstOutputExpectation: XCTestExpectation?
    private let firstOutputBlock: TimeInterval
    private var firstOutputDelivered = false
    private var events: [ChatCLIEvent] = []

    init(
        terminalExpectation: XCTestExpectation,
        firstOutputExpectation: XCTestExpectation? = nil,
        firstOutputBlock: TimeInterval = 0
    ) {
        self.terminalExpectation = terminalExpectation
        self.firstOutputExpectation = firstOutputExpectation
        self.firstOutputBlock = firstOutputBlock
    }

    func record(_ event: ChatCLIEvent) {
        lock.lock()
        events.append(event)
        let isFirstOutput: Bool
        if case .output = event, !firstOutputDelivered {
            firstOutputDelivered = true
            isFirstOutput = true
        } else {
            isFirstOutput = false
        }
        let isFormalTerminal: Bool
        switch event {
        case .exit, .runtimeFailure:
            isFormalTerminal = true
        default:
            isFormalTerminal = false
        }
        lock.unlock()
        if isFirstOutput {
            firstOutputExpectation?.fulfill()
            if firstOutputBlock > 0 {
                Thread.sleep(forTimeInterval: firstOutputBlock)
            }
        }
        if isFormalTerminal {
            terminalExpectation.fulfill()
        }
    }

    var outputTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap {
            if case .output(let text) = $0 { return text }
            return nil
        }
    }

    var exitStatuses: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap {
            if case .exit(let status) = $0 { return status }
            return nil
        }
    }

    var runtimeFailureTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap {
            if case .runtimeFailure(let text) = $0 { return text }
            return nil
        }
    }

    var reconnectProgress: [TatwoNativeChatReconnectProgress] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap {
            if case .reconnectProgress(let progress) = $0 { return progress }
            return nil
        }
    }

    var diagnosticTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap {
            if case .diagnostic(let text) = $0 { return text }
            return nil
        }
    }

    var formalTerminalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.reduce(into: 0) { count, event in
            switch event {
            case .exit, .runtimeFailure:
                count += 1
            default:
                break
            }
        }
    }

    var eventTags: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            switch event {
            case .output(let text):
                return "output:\(text)"
            case .exit(let status):
                return "exit:\(status)"
            case .runtimeFailure(let message):
                return "runtimeFailure:\(message)"
            case .failure(let message):
                return "failure:\(message)"
            default:
                return nil
            }
        }
    }
}
