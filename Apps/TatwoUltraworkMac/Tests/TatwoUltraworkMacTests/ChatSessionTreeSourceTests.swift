import Foundation
import XCTest

final class ChatSessionTreeSourceTests: XCTestCase {
    private var chatPageSource: String {
        get throws {
            try ChatPageSourceScanner.combinedSource()
        }
    }

    func testDiscussionSelectionAndPersistenceRouteTranscriptOnlyToChildSession() throws {
        let source = try chatPageSource
        let selection = try XCTUnwrap(
            source.slice(
                from: "func selectDiscussion(",
                through: "enum ThreadLocation"))
        let persistence = try XCTUnwrap(
            source.slice(
                from: "func persistSelectedThreadMessages()",
                through: "func mutateSelectedThread"))

        XCTAssertTrue(selection.contains("selectedDiscussionID = discussionID"))
        XCTAssertTrue(selection.contains(
            "TatwoNativeChatSessionReference(kind: .discussion, id: discussion.id)"))
        XCTAssertTrue(selection.contains(
            "messages = loadedMessagesForSelection(reference: reference, stored: discussion.messages)"))
        XCTAssertTrue(persistence.contains("if let discussionID = selectedDiscussionID"))
        XCTAssertTrue(persistence.contains("thread.discussions[index].messages = newMessages"))
        XCTAssertTrue(persistence.contains("return\n        }\n        // 防呆"))
    }

    func testInitialLoadRestoresPersistedDiscussionSelection() throws {
        let source = try chatPageSource
        let initialLoad = try XCTUnwrap(
            source.slice(
                from: "func applyInitialStoreLoad(",
                through: "func enableCodexThreadMirror()"))

        XCTAssertTrue(initialLoad.contains("restorePersistedDiscussionSelection()"))
        XCTAssertTrue(initialLoad.contains(
            "if !restorePersistedDiscussionSelection()"))
    }

    func testDiscussionForkCanBeCreatedWhileParentTurnIsStreamingWithoutSwitchingOutputTarget() throws {
        let source = try chatPageSource
        let fork = try XCTUnwrap(
            source.slice(
                from: "func createDiscussionForSelectedThread()",
                through: "func compressDiscussion("))

        XCTAssertFalse(fork.contains("guard !isRunning else"))
        XCTAssertTrue(fork.contains("if isRunning"))
        XCTAssertTrue(fork.contains("目前回覆完成後可切入"))
        XCTAssertFalse(fork.contains("selectedDiscussionID = discussion.id\n            return"))
    }

    func testHashPromptUsesDiscussionEntryAndSkipsMainlineContractGate()
        throws
    {
        let source = try chatPageSource
        // send() and its discussion-fork helper were adjacent before the
        // 2026-09-02 split; read both declaration bodies explicitly.
        let send = try XCTUnwrap(
            source.slice(
                from: "func send()",
                through: "struct PromptCollaborationIntent"))
            + XCTUnwrap(
                source.slice(
                    from: "func handleDiscussionForkFromPromptIfPresent()",
                    through: "struct PromptCollaborationIntent"))
        let submit = try XCTUnwrap(
            source.slice(
                from: "func submitCurrentChatTurn(",
                through: "struct PromptCollaborationIntent"))

        XCTAssertTrue(
            send.contains("handleDiscussionForkFromPromptIfPresent()"))
        XCTAssertTrue(
            send.contains(
                "createDiscussionForSelectedThread(title: title)"))
        XCTAssertTrue(
            send.contains(
                "submitCurrentChatTurn(applyPromptCollaboration: false)"))
        XCTAssertTrue(
            submit.contains("&& !isDiscussionSessionSelected"))
        XCTAssertTrue(
            send.contains("輸入已保留"))
    }

    func testThreadSelectionParksTheActiveTurnInsteadOfBlockingSwitch() throws {
        let source = try chatPageSource
        let standalone = try XCTUnwrap(
            source.slice(
                from: "func selectStandaloneThread(",
                through: "func select("))
        let project = try XCTUnwrap(
            source.slice(
                from: "func select(\n        projectID: UUID,",
                through: "func selectDiscussion("))
        let discussion = try XCTUnwrap(
            source.slice(
                from: "func selectDiscussion(",
                through: "private func loadCodexTranscriptIfNeeded"))

        XCTAssertFalse(standalone.contains("目前 session 正在回覆；完成或停止後才能切換 session。"))
        XCTAssertFalse(project.contains("目前 session 正在回覆；完成或停止後才能切換 session。"))
        XCTAssertFalse(discussion.contains("目前 session 正在回覆；完成或停止後才能切換 session。"))
        XCTAssertTrue(standalone.contains("parkForegroundTurnIfNeeded()"))
        XCTAssertTrue(standalone.contains("restoreParkedTurnForCurrentSelection()"))
        XCTAssertTrue(project.contains("parkForegroundTurnIfNeeded()"))
        XCTAssertTrue(discussion.contains("restoreParkedTurnForCurrentSelection()"))
    }

    func testDiscussionCheckpointAndMergeAreBlockedWhileChildTurnIsStreaming() throws {
        let source = try chatPageSource
        let compression = try XCTUnwrap(
            source.slice(
                from: "func compressDiscussion(",
                through: "/// Explicitly promotes a child result"))
        let merge = try XCTUnwrap(
            source.slice(
                from: "func mergeDiscussionIntoParent(",
                through: "// MARK: #16 loops session"))

        XCTAssertTrue(compression.contains("guard !isRunning else"))
        XCTAssertTrue(merge.contains("guard !isRunning else"))
        XCTAssertTrue(merge.contains("目前 session 正在回覆"))
    }

    func testDiscussionMergeUsesReceiptInsteadOfCopyingChildTranscriptIntoMainline() throws {
        let source = try chatPageSource
        let merge = try XCTUnwrap(
            source.slice(
                from: "func mergeDiscussionIntoParent(",
                through: "// MARK: #16 loops session"))

        XCTAssertTrue(merge.contains("TatwoNativeSessionTree.mergeReceipt("))
        XCTAssertTrue(merge.contains("thread.discussions[index] = discussion"))
        XCTAssertTrue(merge.contains("[Discussion merge receipt]"))
        XCTAssertTrue(merge.contains("receipt.deduplicationKey"))
        XCTAssertTrue(merge.contains("recordCanonicalStoredMessages("))
        XCTAssertTrue(merge.contains("parentMessages.append(receiptRecord)"))
        XCTAssertFalse(merge.contains("append(contentsOf: discussion.messages)"))
        XCTAssertFalse(merge.contains("thread.messages = discussion.messages"))
    }

    func testDiscussionLoopsStayChildScopedWithoutChangingTheOriginalSidebarPresentation() throws {
        let source = try chatPageSource
        let loops = try XCTUnwrap(
            source.slice(
                from: "func createLoopsSessionForSelectedThread()",
                through: "/// D① 變更收據"))
        let dispatch = try XCTUnwrap(
            source.slice(
                from: "func dispatchLoopSub(",
                through: "nonisolated private static func shellQuote"))
        let discussionRow = try XCTUnwrap(
            source.slice(
                from: "func discussionRow(",
                through: "enum ChatSidebarThreadContext"))
        let chatSidebar = try XCTUnwrap(
            source.slice(
                from: "if chatsSectionExpanded {",
                through: "if model.sidebarStandaloneThreads.isEmpty"))
        let threadSource = try XCTUnwrap(
            source.slice(
                from: "var threadSourceItems",
                through: "var threadSummarySection"))
        let threadSummary = try XCTUnwrap(
            source.slice(
                from: "var threadSummarySection",
                through: "var threadPlanSection"))
        let discussionContextMenu = try XCTUnwrap(
            discussionRow.slice(
                from: ".contextMenu {",
                through: "\n        }\n\n        if isSelected"))
        let loopsProjection = try XCTUnwrap(
            source.slice(
                from: "var selectedThreadLoopsSessions",
                through: "var selectedThreadArchivedLoopsSessions"))

        XCTAssertTrue(loopsProjection.contains("selectedDiscussion?.loopsSessions"))
        XCTAssertTrue(loopsProjection.contains("?? selectedThread?.loopsSessions"))
        XCTAssertTrue(loops.contains("selectedDiscussion == nil ? .thread : .discussion"))
        XCTAssertTrue(loops.contains("discussion.loopsSessions.insert(session, at: 0)"))
        XCTAssertTrue(loops.contains("let inheritedGoal = ["))
        XCTAssertTrue(loops.contains("activePLGRun?.planSummary"))
        XCTAssertTrue(loops.contains("goal: inheritedGoal"))
        XCTAssertTrue(dispatch.contains("guard !isDiscussionSessionSelected else"))
        XCTAssertTrue(dispatch.contains("未經明確 merge receipt"))
        XCTAssertTrue(dispatch.contains("TatwoLoopsDispatchPlanner.dispatchObjective("))
        XCTAssertTrue(dispatch.contains("session: session"))
        XCTAssertTrue(dispatch.contains(
            "selectedThreadWorkOSContext(thread: thread).objective"))
        XCTAssertTrue(dispatch.contains("dispatchingLoopID = id"))
        XCTAssertTrue(dispatch.contains("await Task.yield()"))
        XCTAssertTrue(dispatch.contains("selectedThreadID == threadID"))
        XCTAssertTrue(dispatch.contains(
            "confirmPLGPlanAndStartLoops("))
        XCTAssertTrue(dispatch.contains(
            "nativeTaskOverride: planSlice"))
        XCTAssertTrue(dispatch.contains(
            "activeNativeDevelopmentDispatch == nil"))
        XCTAssertFalse(dispatch.contains(
            "session.messages.last(where: { $0.role == \"supervisor\" || $0.role == \"human\" })"))
        XCTAssertFalse(discussionRow.contains("Text(\"DISCUSSION\")"))
        XCTAssertFalse(discussionRow.contains("子 session ·"))
        XCTAssertTrue(discussionContextMenu.contains("把結論併回主線"))
        XCTAssertFalse(chatSidebar.contains(
            "ForEach(item.thread.discussions.filter { !$0.isArchived })"))
        XCTAssertFalse(chatSidebar.contains(
            "ForEach(thread.discussions.filter { !$0.isArchived })"))
        XCTAssertFalse(threadSource.contains("if let discussion = model.selectedDiscussion"))
        XCTAssertFalse(threadSummary.contains(
            "Text(model.isDiscussionSessionSelected ? \"Discussion\" : \"Main session\")"))
        XCTAssertFalse(threadSummary.contains("Forked child session"))
    }

    func testSingleModelConfirmationSettlesAcceptedButNotRunningDispatch()
        throws
    {
        let source = try chatPageSource
        let confirmation = try XCTUnwrap(
            source.slice(
                from: "private func confirmPLGPlanWithSingleModelLead(",
                through: "/// exact 原生開發（XXL）Scenario"))
        let acceptedStart = try XCTUnwrap(
            confirmation.slice(
                from: "guard settleAcceptedSingleModelGoalDispatchStart(",
                through: "let runnerIsVerified ="))
        let runnerLivenessStart = try XCTUnwrap(
            confirmation.range(of: "let runnerIsVerified ="))
        let runnerLiveness = String(
            confirmation[runnerLivenessStart.lowerBound...])
        let settlement = try XCTUnwrap(
            source.slice(
                from: "func settleAcceptedSingleModelGoalDispatchStart(",
                through: "func failPendingSingleModelGoalDispatch("))
        let failedStartSettlement = try XCTUnwrap(
            source.slice(
                from: "func failPendingSingleModelGoalDispatch(",
                through:
                    "private func selectedNativeDevelopmentExecutorModelID("))
        let activeLiveness = try XCTUnwrap(
            settlement.range(
                of: "if activeRunnerInstanceID != nil || startReceipt != nil"))
        let activeLivenessReturn = try XCTUnwrap(
            settlement.range(
                of: "return true",
                range: activeLiveness.upperBound..<settlement.endIndex))
        let deferredLiveness = try XCTUnwrap(
            settlement.range(
                of:
                    "if registerSingleModelGoalDeferredStartSettlementIfActive(",
                range: activeLivenessReturn.upperBound..<settlement.endIndex))
        let deferredLivenessReturn = try XCTUnwrap(
            settlement.range(
                of: "return true",
                range: deferredLiveness.upperBound..<settlement.endIndex))
        let failAcceptedStart = try XCTUnwrap(
            settlement.range(
                of: "failPendingSingleModelGoalDispatch(",
                range: deferredLivenessReturn.upperBound..<settlement.endIndex))
        let failedStartReturn = try XCTUnwrap(
            settlement.range(
                of: "return false",
                range: failAcceptedStart.upperBound..<settlement.endIndex))
        let failedStatus = try XCTUnwrap(
            failedStartSettlement.range(of: "status: .failed"))
        let failedCode = try XCTUnwrap(
            failedStartSettlement.range(
                of: "errorCode: \"single_model_runner_not_started\"",
                range:
                    failedStatus.upperBound..<failedStartSettlement.endIndex))
        let failedMessage = try XCTUnwrap(
            failedStartSettlement.range(
                of: "errorMessage: message",
                range: failedCode.upperBound..<failedStartSettlement.endIndex))

        XCTAssertTrue(
            acceptedStart.contains(
                "guard settleAcceptedSingleModelGoalDispatchStart("))
        XCTAssertTrue(
            acceptedStart.contains(
                "dispatchID: singleModelDispatchID"))
        XCTAssertTrue(
            acceptedStart.contains(
                "單模型 runner 未進入 running；dispatch 已標記失敗，沒有留下假執行中狀態"))
        XCTAssertTrue(acceptedStart.contains("return false"))
        XCTAssertTrue(
            runnerLiveness.contains(
                "let runnerIsVerified ="))
        XCTAssertTrue(runnerLiveness.contains("isRunning"))
        XCTAssertTrue(
            runnerLiveness.contains(
                "activeSingleModelGoalDispatch?.dispatchID == $0"))
        XCTAssertTrue(
            runnerLiveness.contains(
                "單模型執行已進入 running"))
        XCTAssertTrue(
            runnerLiveness.contains(
                "正在等待單模型 runner liveness。"))
        XCTAssertTrue(runnerLiveness.contains("return true"))
        XCTAssertFalse(confirmation.contains("status: .completed"))

        XCTAssertTrue(
            settlement.contains(
                "singleModelGoalDeferredStartAwaitingDispatchIDs.remove(dispatchID)"))
        XCTAssertLessThan(
            activeLiveness.lowerBound,
            activeLivenessReturn.lowerBound)
        XCTAssertLessThan(
            activeLivenessReturn.lowerBound,
            deferredLiveness.lowerBound)
        XCTAssertLessThan(
            deferredLiveness.lowerBound,
            deferredLivenessReturn.lowerBound)
        XCTAssertLessThan(
            deferredLivenessReturn.lowerBound,
            failAcceptedStart.lowerBound)
        XCTAssertLessThan(
            failAcceptedStart.lowerBound,
            failedStartReturn.lowerBound)
        XCTAssertLessThan(failedStatus.lowerBound, failedCode.lowerBound)
        XCTAssertLessThan(failedCode.lowerBound, failedMessage.lowerBound)
        XCTAssertFalse(failedStartSettlement.contains("status: .completed"))
    }

    func testBlockedPlanSubmissionClearsThreadBoundPendingObjective()
        throws
    {
        let source = try chatPageSource
        let planCommand = try XCTUnwrap(
            source.slice(
                from: "    func handlePlanSlashCommand() {",
                through: "    func confirmActivePlan() {"))

        XCTAssertTrue(
            planCommand.contains(
                "pendingPlanObjectives[threadID] = normalized"))
        XCTAssertTrue(
            planCommand.contains(
                "let accepted = submitCurrentChatTurn()"))
        XCTAssertTrue(planCommand.contains("if !accepted {"))
        XCTAssertTrue(
            planCommand.contains(
                "pendingPlanObjectives.removeValue(forKey: threadID)"))
    }

    func testSelectedSessionOwnsProviderHandlesAndComposerForkContext() throws {
        let source = try chatPageSource
        let composer = try XCTUnwrap(
            source.slice(
                from: "func turnWithThreadTranscriptContext(",
                through: "func currentConversationWorkspaceURL"))
        let provider = try XCTUnwrap(
            source.slice(
                from: "private func selectedProviderSessionID(",
                through: "private static func codexCLIResumeSessionID"))

        XCTAssertTrue(provider.contains("if let discussion = selectedDiscussion"))
        XCTAssertTrue(provider.contains("handles: discussion.adapterSessionHandles"))
        XCTAssertTrue(composer.contains(
            "transcriptMessages: messages.map(\\.storedRecord)"))
        XCTAssertTrue(composer.contains(
            "inheritedMessages: selectedDiscussion?.forkCheckpoint?.parentMessages ?? []"))
    }

    func testComputerHostUsesMacOSPrivacyPermissionWithoutPerActionTatwoDialog() throws {
        let source = try chatPageSource
        let send = try XCTUnwrap(
            source.slice(
                from: "func send()",
                through: "func stop()"))
        let execution = try XCTUnwrap(
            source.slice(
                from: "private func executeComputerIntent(",
                through: "private static func compactThinkingStatus"))

        let submission = try XCTUnwrap(source.slice(
            from: "func submitCurrentChatTurn(",
            through: "func stop()"))
        let startTurn = try XCTUnwrap(source.slice(
            from: "func startTurn(",
            through: "func applyNativeGovernanceFallbackPresentation("))
        let preparation = try XCTUnwrap(source.slice(
            from: "func prepareComputerHostBinding(",
            through: "private func freezeComputerHostAuthoritySnapshot("))
        let mcpExecution = try XCTUnwrap(source.slice(
            from: "func executeMCPComputerCall(",
            through: "\n}"))
        XCTAssertTrue(send.contains("submitCurrentChatTurn("))
        XCTAssertTrue(submission.contains("TatwoComputerHostTurnRoutingPolicy.select("))
        XCTAssertTrue(submission.contains("let dispatchSnapshot = currentTurnDispatchSnapshot("))
        XCTAssertTrue(submission.contains("startTurn("))
        XCTAssertTrue(startTurn.contains("guard let computerHostBinding = prepareComputerHostBinding("))
        XCTAssertTrue(startTurn.contains("runID: runID"))
        XCTAssertTrue(startTurn.contains("dispatchSnapshot: dispatchSnapshot"))
        XCTAssertTrue(startTurn.contains("computerHostBindingSlot.install(computerHostBinding)"))
        XCTAssertTrue(startTurn.contains("revokeComputerHostLease(in: computerHostBinding)"))
        XCTAssertTrue(startTurn.contains("computerHostBinding: computerHostBinding"))
        XCTAssertTrue(execution.contains("TatwoComputerApprovalPolicy.evaluate("))
        XCTAssertTrue(execution.contains("TatwoComputerHost.missingPermission("))
        XCTAssertTrue(execution.contains("TatwoComputerHost.requestSystemPermission("))
        XCTAssertTrue(execution.contains("macOS 系統授權"))
        XCTAssertTrue(execution.contains("requestedComputerPermissions.insert("))
        XCTAssertTrue(execution.contains("NSWorkspace.shared.open(settingsURL)"))
        XCTAssertTrue(execution.contains("不會重複彈出授權提示"))
        XCTAssertFalse(execution.contains("requestComputerHostHumanApproval("))
        XCTAssertFalse(execution.contains("NSAlert()"))
        XCTAssertFalse(execution.contains("允許一次"))
        XCTAssertTrue(mcpExecution.contains("let approvalStore = TatwoHostApprovalStore.default()"))
        XCTAssertTrue(source.contains("computerHostMCPAdapterScriptURL()"))
        XCTAssertTrue(source.contains("computerHostContractID: computerHostBinding.decision.route == .mcp"))
        XCTAssertTrue(source.contains("computerHostLeaseID: computerHostBinding.decision.route == .mcp"))
        XCTAssertTrue(source.contains("? computerHostBinding.contractID"))
        XCTAssertTrue(source.contains("? computerHostBinding.lease?.id"))
        XCTAssertTrue(source.contains("let lease = try approvalStore.issue("))
        XCTAssertTrue(source.contains("ttl: 180"))
        let hostDependencyDefaults = try XCTUnwrap(
            source.slice(
                from: "        computerHostApprovalLeaseIssuer",
                through: "        coldStartInitialStoreLoadBarrier:"))
        XCTAssertEqual(
            hostDependencyDefaults.components(
                separatedBy: "TatwoHostApprovalStore.default().issue("
            ).count - 1,
            1)
        XCTAssertEqual(
            hostDependencyDefaults.components(
                separatedBy: "let lease = try approvalStore.issue("
            ).count - 1,
            1)
        XCTAssertTrue(preparation.contains("dispatchSnapshot.contractID"))
        XCTAssertTrue(preparation.contains("selectedThread?.workOSContractID"))
        XCTAssertTrue(
            preparation.contains("goalRunStore.requireIssuedContract(contractID)"))
        let hiddenContext = try XCTUnwrap(
            source.slice(
                from: "func turnWithHiddenLoopsContext(",
                through: "private func chatInterfacePolicyContext"))
        XCTAssertTrue(hiddenContext.contains("computerHostDecision.route == .embeddedIntent"))
        XCTAssertEqual(
            hiddenContext.components(separatedBy: "TatwoComputerToolIntentParser.hiddenPromptContract").count - 1,
            1)
        let outputHandling = try XCTUnwrap(
            source.slice(
                from: "private func handle(_ event: ChatCLIEvent, runID: String)",
                through: "private func executeComputerIntent("))
        XCTAssertTrue(outputHandling.contains("computerHostBindingSlot.binding(for: runID)"))
        XCTAssertTrue(outputHandling.contains(".decision.route ?? .none"))
        XCTAssertTrue(outputHandling.contains("case .embeddedIntent:"))
        XCTAssertTrue(outputHandling.contains("executeComputerIntent(intent, runID: runID)"))
        XCTAssertTrue(outputHandling.contains("case .mcp:"))
        XCTAssertTrue(outputHandling.contains("忽略 legacy embedded intent"))
        XCTAssertTrue(outputHandling.contains("private func handleBuiltInDirect("))
        XCTAssertTrue(outputHandling.contains("decision.route == .embeddedIntent"))
        XCTAssertEqual(
            outputHandling.components(separatedBy: "executeComputerIntent(intent, runID: runID)").count - 1,
            2)
        let launchPreparation = try XCTUnwrap(
            source.slice(
                from: "func prepareComputerHostBinding(",
                through: "func revokeComputerHostLease("))
        XCTAssertTrue(launchPreparation.contains("let decision = dispatchSnapshot.computerHostDecision"))
        XCTAssertTrue(launchPreparation.contains("ChatRouteChoice.resolve(dispatchSnapshot.routeID)"))
        XCTAssertTrue(launchPreparation.contains("decision.route == .mcp"))
        XCTAssertTrue(launchPreparation.contains("route.engine == .claude"))
        XCTAssertTrue(
            launchPreparation.contains(
                "selectedContract.contractID == contractID"))
        XCTAssertTrue(
            launchPreparation.contains("case .ready(let endpoint) = appMCPState"))
        XCTAssertEqual(
            launchPreparation.components(
                separatedBy: "computerHostApprovalLeaseIssuer("
            ).count - 1,
            1)
        let embeddedExecution = try XCTUnwrap(
            source.slice(
                from: "private func executeComputerIntent(",
                through: "func executeMCPComputerCall("))
        XCTAssertTrue(embeddedExecution.contains("computerHostBindingSlot.binding(for: runID)"))
        XCTAssertTrue(embeddedExecution.contains("binding.decision.route == .embeddedIntent"))
        XCTAssertTrue(embeddedExecution.contains("binding.decision.isAuthorized"))
        XCTAssertTrue(embeddedExecution.contains("binding.contractID"))
        XCTAssertTrue(embeddedExecution.contains("binding.mainlineLoopID"))
        XCTAssertTrue(embeddedExecution.contains("binding.workspaceRoot"))
        XCTAssertEqual(
            embeddedExecution.components(
                separatedBy: "computerHostExecutor("
            ).count - 1,
            1)
        let leaseCleanup = try XCTUnwrap(
            source.slice(
                from: "func clearActiveComputerHostLease(runID:",
                through: "private static func compactThinkingStatus"))
        XCTAssertTrue(leaseCleanup.contains("runID ?? activeTurnLifecycle?.runID"))
        XCTAssertTrue(leaseCleanup.contains("computerHostBindingSlot.take(runID: targetRunID)"))
        XCTAssertFalse(leaseCleanup.contains("computerHostBindingSlot.active"))
        XCTAssertTrue(leaseCleanup.contains("revokeComputerHostLease(in: binding)"))
        XCTAssertEqual(
            source.components(separatedBy: "private func executeComputerIntent(").count - 1,
            1)
        XCTAssertEqual(
            source.components(separatedBy: "func prepareComputerHostBinding(").count - 1,
            1)
        XCTAssertTrue(source.contains("var computerHostBindingSlot = ChatComputerHostTurnBindingSlot()"))
        XCTAssertFalse(source.contains("activeComputerHostRoute"))
        XCTAssertFalse(source.contains("activeComputerUseRequested"))
        XCTAssertFalse(source.contains("activeComputerLease"))
        XCTAssertFalse(source.contains("activeComputerWorkspaceRoot"))
        XCTAssertFalse(source.contains("prepareComputerHostLaunchIfPossible"))
        XCTAssertFalse(source.contains("humanApprovalMissing"))
        XCTAssertFalse(source.contains("appleScriptString"))
        let slashCompatibility = try XCTUnwrap(
            source.slice(
                from: "func runSlashCommand(_ item: SlashCommandItem)",
                through: "func evaluatePLGMainline"))
        XCTAssertTrue(slashCompatibility.contains("applySlashCommandSuggestion(item)"))
        XCTAssertFalse(slashCompatibility.contains("triggerPLGFromPrompt()"))
        XCTAssertFalse(slashCompatibility.contains("handlePlanSlashCommand()"))
        XCTAssertFalse(slashCompatibility.contains("activateGoalFromPrompt()"))
    }

    func testSidebarAndInitialSelectionConsumeUnifiedLedgerActivityFirst() throws {
        let source = try chatPageSource
        // The initial-load pipeline spans three declarations that were
        // adjacent before the 2026-09-02 split; read each body explicitly.
        let load = try XCTUnwrap(
            source.slice(
                from: "func startInitialStoreLoad(",
                through: "func enableCodexThreadMirror()"))
            + XCTUnwrap(
                source.slice(
                    from: "nonisolated static func loadInitialStorePayload(",
                    through: "func enableCodexThreadMirror()"))
            + XCTUnwrap(
                source.slice(
                    from: "func applyInitialStoreLoad(",
                    through: "func enableCodexThreadMirror()"))
        let standaloneSorting = try XCTUnwrap(
            source.slice(
                from: "var filteredStandaloneThreads:",
                through: "var sidebarStandaloneThreads:"))
        let projectSorting = try XCTUnwrap(
            source.slice(
                from: "func projectSection(",
                through: "enum ChatSidebarThreadContext"))

        XCTAssertTrue(source.contains("let unifiedLedgerRead: TatwoUnifiedSessionLedgerReadV1"))
        XCTAssertTrue(load.contains("if let ledger = store.unifiedLedger"))
        XCTAssertTrue(load.contains("let read = try? ledger.inspect()"))
        XCTAssertTrue(load.contains("latestLedgerActivityByThreadID ="))
        XCTAssertTrue(load.contains("threadActivityDate("))
        XCTAssertTrue(standaloneSorting.contains("threadActivityDate(lhs) > threadActivityDate(rhs)"))
        XCTAssertTrue(projectSorting.contains("model.threadActivityDate(lhs) > model.threadActivityDate(rhs)"))
    }
}
