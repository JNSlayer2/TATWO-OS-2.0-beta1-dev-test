import Foundation
import XCTest

final class ChatIssueAndSupervisionSourceTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    private var chatPageSource: String {
        get throws {
            try ChatPageSourceScanner.combinedSource(repoRoot: repoRoot)
        }
    }

    func testIssueQuickActionArchivesAndPackOnlyPrefillsComposer() throws {
        let source = try chatPageSource
        let archive = try XCTUnwrap(
            source.slice(
                from: "func archiveIssueListEntry(",
                through: "func updateIssueListEntryBody("))
        let pack = try XCTUnwrap(
            source.slice(
                from: "func packIssueIntoComposer(",
                through: "// MARK: 設定 → Issue List 管理"))
        let issueRow = try XCTUnwrap(
            source.slice(
                from: "func issueListRow(",
                through: "func threadGitHubRepoSection("))

        XCTAssertTrue(archive.contains("status: .archived"))
        XCTAssertFalse(archive.contains("removeIssueListEntry"))
        XCTAssertTrue(pack.contains("prompt +="))
        XCTAssertFalse(pack.contains("send()"))
        XCTAssertTrue(issueRow.contains("issuePackIntoChatButton(entry)"))
        XCTAssertTrue(issueRow.contains("Label(\"帶入聊天\""))
        XCTAssertTrue(issueRow.contains(".onTapGesture(count: 2) { model.archiveIssueListEntry(entry.id) }"))
        XCTAssertTrue(issueRow.contains("附加圖片…"))
        XCTAssertTrue(issueRow.contains("removeIssueImageNote"))
    }

    func testFocusedIssueFromMentionKeepsSamePackIntoChatAction() throws {
        let source = try chatPageSource
        let issueSection = try XCTUnwrap(
            source.slice(
                from: "var issueListSection: some View",
                through: "func issueListRow("))
        let packButton = try XCTUnwrap(
            source.slice(
                from: "func issuePackIntoChatButton(",
                through: "func threadGitHubRepoSection("))

        XCTAssertTrue(issueSection.contains("model.focusedIssueEntryID"))
        XCTAssertTrue(issueSection.contains("issuePackIntoChatButton(focused)"))
        XCTAssertTrue(packButton.contains("model.packIssueIntoComposer(entry)"))
        XCTAssertTrue(packButton.contains("Label(\"帶入聊天\""))
        XCTAssertTrue(packButton.contains("仍要由你按送出才執行"))
    }

    func testLiveWorkAndInterruptQueueKeepOutputBoundToItsOriginalSession() throws {
        let source = try chatPageSource
        let startNext = try XCTUnwrap(
            source.slice(
                from: "func startNextChatIfNeeded()",
                through: "nonisolated static func readGitChangedFiles"))
        let eventHandling = try XCTUnwrap(
            source.slice(
                from: "private func handle(_ event: ChatCLIEvent, runID: String)",
                through: "private func executeComputerIntent("))
        let submission = try XCTUnwrap(
            source.slice(
                from: "func submitCurrentChatTurn(",
                through: "struct PromptCollaborationIntent"))

        XCTAssertTrue(source.contains("@Published internal(set) var liveWorkActivities"))
        XCTAssertTrue(source.contains("@Published internal(set) var chatQueue"))
        XCTAssertTrue(source.contains("func enqueueChatTurn("))
        XCTAssertTrue(source.contains("func resumeQueuedChatTurns()"))
        XCTAssertTrue(
            submission.contains(
                "if isRunning {\n            accepted = enqueueChatTurn("))
        XCTAssertTrue(submission.contains("guard accepted else { return false }"))
        let rejectionGate = try XCTUnwrap(
            submission.range(of: "guard accepted else { return false }"))
        let acceptedCleanup = try XCTUnwrap(
            submission.range(
                of: "clearPendingHandoffAfterComposingTurn()"))
        XCTAssertLessThan(
            rejectionGate.lowerBound,
            acceptedCleanup.lowerBound,
            "rejected start/enqueue attempts must return before accepted-only cleanup")
        XCTAssertTrue(
            submission[acceptedCleanup.lowerBound...]
                .contains("clearComposerDraftAfterAcceptedSubmission()"),
            "composer draft cleanup must remain in the accepted-only path")
        XCTAssertFalse(source.contains("if mode == .chat && isRunning"))
        XCTAssertTrue(source.contains("if model.canSend {\n                    composerSendButton(compactToolbar: compactToolbar)\n                }"))
        XCTAssertTrue(source.contains(".help(model.isRunning ? \"加入插話佇列\" : \"送出\")"))
        XCTAssertTrue(startNext.contains("next.threadID == selectedThreadID"))
        XCTAssertTrue(startNext.contains("next.discussionID == selectedDiscussionID"))
        XCTAssertTrue(startNext.contains("chatQueuePaused = true"))
        XCTAssertTrue(startNext.contains("userMessageAlreadyAppended: true"))
        XCTAssertTrue(startNext.contains("ChatQueueContextPolicy.transcriptForExecution"))
        XCTAssertFalse(startNext.contains("messages[..<index]"))
        XCTAssertTrue(source.contains("static let maxQueuedChatTurns = 32"))
        XCTAssertTrue(source.contains("static let maxQueuedChatUTF8Bytes = 512 * 1024"))
        XCTAssertTrue(source.contains("$0 += $1.residentUTF8Bytes"))
        XCTAssertFalse(source.contains("$1.commandBaseTurn.utf8.count"))
        XCTAssertTrue(eventHandling.contains("recordLiveWork("))
        XCTAssertTrue(eventHandling.contains("startNextChatIfNeeded()"))
    }

    func testUserStopNormalizesSIGTERMToStoppedInsteadOfFailure() throws {
        let source = try chatPageSource
        let stop = try XCTUnwrap(
            source.slice(
                from: "func stop()",
                through: "func startRunnerStateReconciler"))
        let activeRunnerStop = try XCTUnwrap(
            stop.slice(
                from: "if isRunning, var lifecycle = activeTurnLifecycle",
                through: "initialStoreLoadController.cancel()"))
        let eventHandling = try XCTUnwrap(
            source.slice(
                from: "private func handle(_ event: ChatCLIEvent, runID: String)",
                through: "private func executeComputerIntent("))
        let exit = try XCTUnwrap(
            eventHandling.slice(
                from: "case .exit(let status):",
                through: "case .failure(let message):"))
        let finishExit = try XCTUnwrap(
            source.slice(
                from: "func finishExitedTurn(status: Int32)",
                through: "func finishFailureTurn("))
        let finish = try XCTUnwrap(
            source.slice(
                from: "func finishActiveAssistant(",
                through: "private func appendRawFallback"))
        let terminalPolicy = try XCTUnwrap(
            source.slice(
                from: "enum ChatAssistantTerminalStatusPolicy",
                through: "struct ChatWorkOSStateLoadPayload"))

        XCTAssertTrue(stop.contains("userStopRequested = true"))
        XCTAssertTrue(activeRunnerStop.contains("requestCancellation()"))
        XCTAssertFalse(activeRunnerStop.contains("isRunning = false"))
        XCTAssertTrue(stop.contains("pendingRemoteTurnTask"))
        XCTAssertTrue(stop.contains("isRunning = false"))
        XCTAssertFalse(stop.contains("updateActiveStatus(\"terminated\")"))
        XCTAssertTrue(
            exit.contains(
                "let formalStatus: Int32 =\n                executionEvidenceMissing ? 1 : status"))
        XCTAssertTrue(
            exit.contains(
                "acceptFormalTerminalEvent(\n                runID: runID,\n                status: formalStatus)"))
        XCTAssertTrue(exit.contains("finishExitedTurn(status: status)"))
        XCTAssertTrue(finishExit.contains("let wasUserStop = userStopRequested"))
        XCTAssertFalse(finishExit.contains("userStopRequested || status == 143"))
        XCTAssertTrue(finishExit.contains("wasUserInitiatedStop: wasUserStop"))
        XCTAssertTrue(
            finishExit.contains("ChatAssistantTerminalStatusPolicy.liveWorkStatus("))
        XCTAssertTrue(terminalPolicy.contains(#"return "stopped|已停止""#))
        XCTAssertTrue(finish.contains("let wasStopped = wasUserInitiatedStop"))
        XCTAssertFalse(finish.contains("wasUserInitiatedStop || status == 143"))
        XCTAssertTrue(finish.contains("status == 0 || wasStopped"))
        XCTAssertTrue(finish.contains("messages.remove(at: index)"))
        XCTAssertTrue(finish.contains("模型路線中斷，未收到完整回覆。"))
    }

    func testRunnerReconcilerUsesFormalLifecycleInsteadOfFinalAnswerWallClock() throws {
        let source = try chatPageSource
        let reconciler = try XCTUnwrap(
            source.slice(
                from: "func startRunnerStateReconciler",
                through: "private func reconcileInactiveRunner"))

        XCTAssertTrue(reconciler.contains("runner.lifecycleSnapshot"))
        XCTAssertTrue(reconciler.contains("shouldReconcileInactiveRunner"))
        XCTAssertTrue(reconciler.contains("snapshot.formalFailureMessage"))
        XCTAssertTrue(source.contains("guard acceptFormalTerminalEvent(runID: runID, status: status)"))
        XCTAssertTrue(source.contains("finishFailureTurn("))
        XCTAssertFalse(reconciler.contains("noVisibleOutputGrace"))
        XCTAssertFalse(reconciler.contains("activeAssistantHasNoUserVisibleReply"))
        XCTAssertFalse(reconciler.contains("超過"))
    }

    func testRunnerStateReconcilerIsPerRunAndCleansUpWithoutGlobalCancel() throws {
        let source = try chatPageSource
        let reconciler = try XCTUnwrap(
            source.slice(
                from: "func startRunnerStateReconciler(for assistantID: ChatMessage.ID, runID: String)",
                through: "private func presentBlockedCancellation("))
        let startTurn = try XCTUnwrap(
            source.slice(
                from: "func startTurn(",
                through: "func applyNativeGovernanceFallbackPresentation("))
        let finishExit = try XCTUnwrap(
            source.slice(
                from: "func finishExitedTurn(status: Int32)",
                through: "private func startPendingNativeDevelopmentAutoFollowupIfPossible("))
        let finishFailure = try XCTUnwrap(
            source.slice(
                from: "func finishFailureTurn(",
                through: "private func preparedExitedAssistantMessage("))
        let shutdown = try XCTUnwrap(
            source.slice(
                from: "func shutdownForContainerClose()",
                through: "func closeCLITab("))
        let registry = try XCTUnwrap(
            source.slice(
                from: "func cancelRunnerStateReconciler(for runID: String)",
                through: "func startRunnerStateReconciler(for assistantID: ChatMessage.ID, runID: String)"))

        XCTAssertFalse(source.contains("private var runnerStateReconcileTask:"))
        XCTAssertFalse(source.contains("runnerStateReconcileTask?."))
        XCTAssertTrue(source.contains("runnerStateReconcileTasksByRunID"))
        XCTAssertTrue(source.contains("runnerStateReconcileGenerationsByRunID"))

        XCTAssertTrue(reconciler.contains("cancelRunnerStateReconciler(for: runID)"))
        XCTAssertTrue(reconciler.contains("[weak self]"))
        XCTAssertTrue(reconciler.contains("clearRunnerStateReconcilerIfCurrent("))
        XCTAssertTrue(reconciler.contains("runnerStateReconcileTasksByRunID[runID] = task"))
        XCTAssertFalse(reconciler.contains("runnerStateReconcileTask?.cancel()"))
        XCTAssertFalse(reconciler.contains("cancelAllRunnerStateReconcilers()"))

        XCTAssertTrue(startTurn.contains("cancelRunnerStateReconciler(for: previousRunID)"))
        XCTAssertFalse(startTurn.contains("runnerStateReconcileTask?.cancel()"))
        XCTAssertFalse(startTurn.contains("cancelAllRunnerStateReconcilers()"))

        XCTAssertTrue(finishExit.contains("cancelRunnerStateReconciler(for: terminalRunID)"))
        XCTAssertTrue(finishFailure.contains("cancelRunnerStateReconciler(for: terminalRunID)"))
        XCTAssertTrue(shutdown.contains("cancelAllRunnerStateReconcilers()"))

        XCTAssertTrue(registry.contains("removeValue(forKey: runID)?.cancel()"))
        XCTAssertTrue(registry.contains("guard runnerStateReconcileGenerationsByRunID[runID] == generation"))
        XCTAssertTrue(registry.contains("func cancelAllRunnerStateReconcilers()"))
    }

    func testBridgeCancellationWaitsForActualAttemptTerminationBeforeTerminalCommit() throws {
        let runtime = try ChatSourceFamily.read("ChatRuntime.swift")
        let bridgeCheckpoint = try XCTUnwrap(
            runtime.slice(
                from: "private func startBridgeCheckpointIfNeeded",
                through: "private func startZeroByteFailFastIfNeeded"))
        let terminationHandler = try XCTUnwrap(
            runtime.slice(
                from: "process.terminationHandler = { proc in",
                through: "var launchError: Error?"))
        let formalTermination = try XCTUnwrap(
            runtime.slice(
                from: "private func recordFormalTermination(",
                // ChatRuntime.swift split (2026-09-02): the runner file is followed by
                // ChatCLIProcessSupervision.swift in family order.
                through: "struct ChatCLIOwnedProcessIdentity"))

        XCTAssertFalse(bridgeCheckpoint.contains("asyncAfter"))
        XCTAssertTrue(bridgeCheckpoint.contains("bridgeRetryState.armRetry"))
        XCTAssertTrue(terminationHandler.contains("recordAttemptTermination"))
        XCTAssertTrue(terminationHandler.contains("cancelWatchdog"))
        XCTAssertTrue(terminationHandler.contains("cancelOutputPoller"))
        XCTAssertTrue(terminationHandler.contains("cancelBridgeCheckpoint"))
        XCTAssertTrue(terminationHandler.contains("cancelZeroByteFailFast"))
        XCTAssertTrue(terminationHandler.contains("recordCleanupComplete"))
        XCTAssertTrue(terminationHandler.contains("takeRetryIfReady"))
        XCTAssertTrue(terminationHandler.contains("resolveBridgeAttemptTermination"))
        XCTAssertTrue(formalTermination.contains("guard self.process == nil"))
    }

    func testComposerGrowsAndConsumesImagePasteOrDropBeforeTextInsertion() throws {
        let bridge = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageAppKitBridges.swift"),
            encoding: .utf8)
        let composer = try XCTUnwrap(
            bridge.slice(
                from: "struct ChatComposerTextView",
                through: "final class ComposerScrollView"))
        let textView = try XCTUnwrap(
            bridge.slice(
                from: "final class ComposerNSTextView",
                through: "private var cursorAtEnd"))

        XCTAssertTrue(composer.contains("@Binding var contentHeight"))
        XCTAssertTrue(composer.contains("layoutManager.usedRect(for: textContainer)"))
        XCTAssertTrue(composer.contains("let clampedHeight = min(maximumHeight, documentHeight)"))
        XCTAssertTrue(composer.contains("textView.setFrameSize"))
        XCTAssertTrue(textView.contains("var onPasteImage: ((NSPasteboard) -> Bool)?"))
        XCTAssertTrue(textView.contains("onPasteImage?(NSPasteboard.general) == true"))
        XCTAssertTrue(textView.contains("performDragOperation"))
        XCTAssertTrue(textView.contains("sender.draggingPasteboard"))
    }

    func testMultipleSlashCommandsAreParsedFailClosedBeforeNormalSubmission() throws {
        let source = try chatPageSource
        let send = try XCTUnwrap(
            source.slice(
                from: "func send()",
                through: "func submitCurrentChatTurn"))
        let chain = try XCTUnwrap(
            source.slice(
                from: "private func handleSlashCommandChainIfPresent()",
                through: "/// Codex-style Plan/Goal"))

        XCTAssertTrue(send.contains("handleSlashCommandChainIfPresent()"))
        XCTAssertTrue(chain.contains("TatwoSlashCommandParser.commandLines"))
        XCTAssertTrue(chain.contains("runtimeIndexes.count <= 1"))
        XCTAssertTrue(chain.contains("只能放最後一行"))
        XCTAssertTrue(chain.contains("captureIssueSlashCommand"))
    }
}
