import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    internal func currentTurnDispatchRoute() -> ChatRouteChoice {
        ChatTurnDispatchRoutePolicy.route(
            active: routeChoice,
            pending: pendingRouteChoice,
            isRunning: isRunning)
    }

    private func frozenDispatchPhase(
        for route: ChatRouteChoice
    ) -> TatwoScenarioPhase {
        let phase = currentTurnScenarioPhase
        guard phase == .goal,
              selectedGoalRecord?.status == .blocked,
              selectedWorkOSContract?.scenario
                == TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
              TatwoGatewayDispatchCatalog.normalize(
                route.canonicalModelSlug)
                == TatwoGatewayDispatchCatalog.normalize("gpt-5.6-sol")
        else { return phase }
        // A blocked native-development Goal is a recovery boundary, not a new
        // Goal-verifier grant for Sol. Freeze Sol read-only diagnostics against
        // its already-issued Loops executor binding; Opus remains on the Goal
        // verifier binding. Mutation still requires a real running dispatch.
        return .loops
    }

    func currentTurnDispatchSnapshot(
        route: ChatRouteChoice,
        computerHostDecision: ChatComputerHostTurnDecision
    ) -> ChatTurnDispatchSnapshot {
        return ChatTurnContractEffortResolver.resolve(
            route: route,
            phase: frozenDispatchPhase(for: route),
            contract: selectedWorkOSContract,
            uiSelectedEffort: selectedEffort,
            computerHostDecision: computerHostDecision)
    }

    @discardableResult
    func startTurn(
        displayTurn: String,
        commandTurn: String,
        visibleTurn: String,
        attachmentPaths: [String],
        previewTurn: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        userMessageAlreadyAppended: Bool = false,
        sourceUserMessageID: ChatMessage.ID? = nil,
        remoteClaimCompleted: Bool = false,
        commandBaseTurn: String? = nil
    ) -> Bool {
        guard dispatchSnapshot.canDispatch else {
            flashComposerHint(
                dispatchSnapshot.blocker
                    ?? "本輪 route/effort contract 無法驗證；沒有派工。")
            return false
        }
        if let blocker = plannedNativeDevelopmentBlockerHint(for: visibleTurn)
        {
            flashComposerHint(
                "\(blocker)請先用 /plg 完成規劃並按【確認計畫，進入分工】；Goal 顯示派工中／執行中後再送出改碼要求。")
            return false
        }
        userStopRequested = false
        if let previousRunID = activeTurnLifecycle?.runID {
            cancelRunnerStateReconciler(for: previousRunID)
        }
        var deferredCanonicalUserMessage: ChatMessage?
        let boundUserMessageID: ChatMessage.ID
        let canonicalUserMessageAccepted: Bool
        if userMessageAlreadyAppended {
            var existingUserMessage =
                sourceUserMessageID.flatMap { messageID in
                    messages.first(where: {
                        $0.id == messageID && $0.role == .user
                    })
                }
                ?? messages.last(where: { $0.role == .user })
            if existingUserMessage == nil {
                let hiddenExecutionMessage = ChatMessage(
                    role: .user,
                    text: displayTurn,
                    eventKind: .message)
                if ChatPlanThoughtPresentation
                    .isConfirmedPlanExecutionPrompt(hiddenExecutionMessage)
                {
                    // Confirmed Plan execution intentionally suppresses the
                    // full App-authored envelope from the visible/native chat
                    // store. Reserve its stable ID now, but defer the durable
                    // folded `已送交 Work OS` anchor until every pre-dispatch
                    // authority/preparation gate has passed.
                    deferredCanonicalUserMessage = hiddenExecutionMessage
                    existingUserMessage = hiddenExecutionMessage
                }
            }
            guard let existingUserMessage else {
                flashComposerHint(
                    "送出失敗：找不到可綁定的 canonical user message。")
                return false
            }
            boundUserMessageID = existingUserMessage.id
            canonicalUserMessageAccepted = true
        } else {
            let userMessage = ChatMessage(
                role: .user,
                text: displayTurn,
                eventKind: .message)
            guard appendMessage(userMessage) else {
                flashComposerHint("送出失敗：canonical transcript journal 無法落盤。")
                return false
            }
            boundUserMessageID = userMessage.id
            canonicalUserMessageAccepted = true
        }
        if !remoteClaimCompleted,
           beginPendingRemoteClaimIfNeeded(
            displayTurn: displayTurn,
            commandTurn: commandTurn,
            visibleTurn: visibleTurn,
            attachmentPaths: attachmentPaths,
            previewTurn: previewTurn,
            dispatchSnapshot: dispatchSnapshot,
            userMessageAlreadyAppended: canonicalUserMessageAccepted)
        {
            return true
        }
        let runID = UUID().uuidString
        let assistantTurnID = UUID().uuidString
        guard let computerHostBinding = prepareComputerHostBinding(
            runID: runID,
            dispatchSnapshot: dispatchSnapshot)
        else {
            return false
        }
        guard computerHostBindingSlot.install(computerHostBinding) else {
            revokeComputerHostLease(in: computerHostBinding)
            flashComposerHint(
                "Computer Host authority 已被其他 active run 佔用；沒有派工。")
            return false
        }
        let command = buildCommand(
            turn: commandTurn,
            visibleTurn: visibleTurn,
            droppedPaths: attachmentPaths,
            dispatchSnapshot: dispatchSnapshot,
            computerHostBinding: computerHostBinding,
            runID: runID,
            turnID: assistantTurnID)
        let nativeGovernanceFallbackCommand =
            command.runtimeAdapter == .nativeAgent
                ? cliDevelopmentFallbackCommand(
                    from: command,
                    prompt: commandTurn,
                    dispatchSnapshot: dispatchSnapshot)
                : nil
        guard preparePendingNativeDevelopmentDispatchIfNeeded(
            command: command,
            subtask: visibleTurn,
            dispatchSnapshot: dispatchSnapshot)
        else {
            revokeComputerHostLease(in: computerHostBinding)
            return false
        }
        if let deferredCanonicalUserMessage,
           !recordCanonicalMessage(deferredCanonicalUserMessage)
        {
            clearActiveComputerHostLease(runID: runID)
            if let dispatchID = pendingNativeDevelopmentDispatch?.id {
                failPendingNativeDevelopmentDispatchStart(
                    dispatchID: dispatchID,
                    message:
                        "Canonical transcript anchor 無法落盤；native runner 未啟動。")
            }
            if let dispatchID = pendingSingleModelGoalDispatch?.id {
                failPendingSingleModelGoalDispatch(
                    dispatchID: dispatchID,
                    message:
                        "Canonical transcript anchor 無法落盤；single-model runner 未啟動。")
            }
            flashComposerHint(
                "送出失敗：canonical transcript journal 無法落盤。")
            return false
        }
        activeGatewayContinuationTurn =
            command.gatewayContinuationRequest.map {
                ChatGatewayContinuationTurnState(
                    runID: runID,
                    request: $0,
                    receipt: nil)
            }
        activeGatewayStaleHandleFallback =
            ChatGatewayContinuationFallbackCoordinator()
        activeGatewayFallbackTurnInputs = ChatGatewayFallbackTurnInputs(
            commandBaseTurn: commandBaseTurn ?? visibleTurn,
            visibleTurn: visibleTurn,
            attachmentPaths: attachmentPaths,
            previewTurn: previewTurn,
            dispatchSnapshot: dispatchSnapshot,
            assistantTurnID: assistantTurnID)
        let turnRoute = ChatRouteChoice.resolve(dispatchSnapshot.routeID)
        activeTurnDispatchSnapshot = dispatchSnapshot
        // One immutable provenance per physical turn. `modelID` and
        // `runtimeAdapterID` are the exact identities stamped on the assistant
        // message below, so the canonical journal's command/activity events and
        // this turn's result can never disagree — even if the model picker,
        // the pending `下一輪` route, or the thread topology changes mid-run.
        activeTurnExecutionProvenance = ChatTurnExecutionProvenance(
            runID: runID,
            turnID: assistantTurnID,
            modelID: turnRoute.id,
            canonicalModelID: dispatchSnapshot.canonicalModelID,
            runtimeAdapterID: command.runtimeAdapter.rawValue,
            providerID: ChatTranscriptJournalAdapter
                .provenanceProviderID(modelID: turnRoute.id))
        let assistant = ChatMessage(
            id: assistantTurnID,
            role: .assistant,
            text: "",
            status: ChatPageAssistantTextAppendPolicy.pendingInFlightStatus,
            modelID: turnRoute.id,
            eventKind: .message,
            runtimeAdapterID: command.runtimeAdapter.rawValue,
            runtimeFallbackReason: command.runtimeFallbackReason,
            turnID: assistantTurnID)
        if isPlanModeEnabled, let planThreadID = selectedThreadID {
            let startingArtifact =
                activePlanArtifact?.threadID == planThreadID
                ? activePlanArtifact
                : try? planArtifactStore?.load(threadID: planThreadID)
            let boundUserTurn = messages.first(where: {
                $0.id == boundUserMessageID && $0.role == .user
            })?.text
            activePlanTurnBinding = ChatPlanTurnBinding(
                threadID: planThreadID,
                sourceUserMessageID: boundUserMessageID,
                assistantMessageID: assistantTurnID,
                objectiveCandidate:
                    ChatPlanClarificationContinuationPolicy
                    .objectiveCandidate(
                        userTurn: visibleTurn,
                        pendingObjective:
                            pendingPlanObjectives[planThreadID],
                        existingObjective: startingArtifact?.objective,
                        boundUserTurn: boundUserTurn),
                startingPlanID: startingArtifact?.planID,
                startingObjective: startingArtifact?.objective,
                startingArtifactUpdatedAt: startingArtifact?.updatedAt)
            if ChatPlanClarificationContinuationPolicy
                .isTerminalEnvelope(visibleTurn)
            {
                terminalPlanTurnAssistantMessageIDs.insert(assistantTurnID)
            }
        } else {
            activePlanTurnBinding = nil
        }
        activeAssistantID = assistant.id
        // Streaming placeholder is memory-only tail; do not land on disk until promote.
        streamLedger = StreamTranscriptLedger()
        if let fragmentID = UUID(uuidString: assistant.id) {
            _ = streamLedger.beginTail(content: "", id: fragmentID)
        } else {
            _ = streamLedger.beginTail(content: "")
        }
        appendMessage(assistant, persist: false)
        isRunning = true
        sessionKeyByRunID[runID] = currentSessionStableKey()
        liveWorkActivities = [
            ChatLiveWorkActivity(
                label: "已送出",
                detail: Self.activityDetail(from: previewTurn),
                systemImage: "paperplane.fill")
        ]
        chatActivityFeedReducer = ChatActivityFeedReducer(maxVisibleCompleted: 12)
        chatActivityFeed = chatActivityFeedReducer.feed
        updateSelectedThreadPreview(previewTurn, sessionID: nil)

        lastCommand = command.display
        let pendingNativeDispatchID =
            pendingNativeDevelopmentDispatch?.id
        let pendingSingleModelDispatchID =
            pendingSingleModelGoalDispatch?.id
        let runnerIdentity = dispatchService.startRuntime(
            model: self,
            command: command,
            nativePrompt: commandTurn,
            dispatchSnapshot: dispatchSnapshot,
            runID: runID,
            activityTurnID: assistant.id,
            allowsNativeGovernanceFallback: true,
            nativeGovernanceFallbackCommand:
                nativeGovernanceFallbackCommand
        ) { [weak self] event in
            // Runner callback invocation is serialized. Enqueue directly on
            // the serial main dispatch queue so the final assistant event
            // cannot be overtaken by a separately scheduled formal terminal.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let activeRuntimeAdapter =
                    self.messages.first(where: {
                        $0.id == assistant.id
                    })?.runtimeAdapterID.flatMap(
                        TatwoChatRuntimeAdapter.init(rawValue:))
                    ?? command.runtimeAdapter
                self.runtimeEventReducer.reduce(
                    event,
                    runID: runID,
                    runtimeAdapter: activeRuntimeAdapter,
                    model: self)
            }
        }
        guard let runnerIdentity else {
            if let pendingNativeDispatchID {
                failPendingNativeDevelopmentDispatchStart(
                    dispatchID: pendingNativeDispatchID,
                    message:
                        "Native runner 未取得本輪 frozen contract authority；派工已 fail closed。")
            }
            if let pendingSingleModelDispatchID {
                failPendingSingleModelGoalDispatch(
                    dispatchID: pendingSingleModelDispatchID,
                    message:
                        "單模型 runner 未取得本輪 frozen contract authority。")
            }
            isRunning = false
            let blockerSuffix = lastNativeRuntimeStartBlocker.map {
                " [\($0)]"
            } ?? ""
            finishFailureTurn(
                runID: runID,
                message:
                    "啟動失敗：runner authority 無法建立實體 attempt。"
                    + blockerSuffix,
                activityFallback: "啟動失敗")
            return false
        }
        activeTurnLifecycle = TatwoChatTurnLifecycle(
            runID: runID,
            assistantID: assistant.id,
            runnerInstanceID: runnerIdentity.instanceID,
            runnerRevision: runnerIdentity.revision)
        if let pending = pendingSingleModelGoalDispatch,
           pending.id == pendingSingleModelDispatchID
        {
            singleModelGoalDispatchContractIDByDispatchID[pending.id] =
                pending.contractID
            let deferredSettlementWasAwaiting =
                singleModelGoalDeferredStartAwaitingDispatchIDs.remove(
                    pending.id) != nil
            if deferredSettlementWasAwaiting {
                singleModelGoalRunnerStartReceiptByDispatchID.removeValue(
                    forKey: pending.id)
            } else {
                singleModelGoalRunnerStartReceiptByDispatchID[pending.id] =
                    runnerIdentity.instanceID
            }
            activeSingleModelGoalDispatch = (
                runID: runID,
                contractID: pending.contractID,
                dispatchID: pending.id,
                runnerInstanceID: runnerIdentity.instanceID,
                observedToolUse: false)
            pendingSingleModelGoalDispatch = nil
        }
        let activeRuntimeAdapter =
            messages.first(where: { $0.id == assistant.id })?
                .runtimeAdapterID.flatMap(
                    TatwoChatRuntimeAdapter.init(rawValue:))
            ?? command.runtimeAdapter
        if [.codexExec, .claudeCLI, .grokCLI, .gatewayDirect]
            .contains(activeRuntimeAdapter)
        {
            startRunnerStateReconciler(for: assistant.id, runID: runID)
        }
        return true
    }


    func applyNativeGovernanceFallbackPresentation(
        command: ChatCLICommand,
        activityTurnID: String
    ) {
        guard let index = messages.firstIndex(where: {
            $0.id == activityTurnID
        }) else { return }
        messages[index].runtimeAdapterID = command.runtimeAdapter.rawValue
        messages[index].runtimeFallbackReason =
            .nativeGovernanceNotEngaged
        if activeTurnExecutionProvenance?.turnID == activityTurnID {
            activeTurnExecutionProvenance = activeTurnExecutionProvenance?
                .replacingRuntimeAdapterID(command.runtimeAdapter.rawValue)
        }
        lastCommand = command.display
    }

    /// Starts a non-blocking disk claim at the actual runtime boundary. A queued
    /// turn reaches this only when dequeued; slash commands and CLI turns never do.
    private func beginPendingRemoteClaimIfNeeded(
        displayTurn: String,
        commandTurn: String,
        visibleTurn: String,
        attachmentPaths: [String],
        previewTurn: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        userMessageAlreadyAppended: Bool
    ) -> Bool {
        guard mode == .chat,
              !isPlanModeEnabled,
              !ChatPlanClarificationContinuationPolicy
                .isClarificationEnvelope(visibleTurn),
              pendingNativeDevelopmentDispatch == nil,
              let sessionID = selectedRemoteBorrowSessionID
        else { return false }
        pendingRemoteTurnTask?.cancel()
        _ = pendingRemoteTurnCancellationFence?.cancel()
        pendingRemoteTurnGeneration &+= 1
        let generation = pendingRemoteTurnGeneration
        let cancellationFence = ChatRemoteTurnCancellationFence()
        pendingRemoteTurnCancellationFence = cancellationFence
        pendingRemoteTurnClaim = nil
        isRunning = true
        let originSessionKey = currentSessionStableKey()
        let deferredSingleModelDispatchID =
            pendingSingleModelGoalDispatch?.id
        let store = pendingRemoteTargetStore
        let remoteTurnTask = Task { @MainActor [weak self] in
            guard let self, !cancellationFence.isCancelled else { return }
            let claimResult = await Task.detached(priority: .userInitiated) {
                do {
                    return ChatPendingRemoteClaimResult.claimed(
                        try store.claim(sessionID: sessionID))
                } catch ChatPendingRemoteTargetStoreError.ambiguousTargets(let targets) {
                    return ChatPendingRemoteClaimResult.ambiguousTargets(targets)
                } catch {
                    return ChatPendingRemoteClaimResult.unreadable
                }
            }.value
            guard self.isCurrentPendingRemoteTurn(
                generation: generation,
                cancellationFence: cancellationFence)
            else {
                if case .claimed(let pending?) = claimResult {
                    await self.releasePendingRemoteClaimAfterCancellation(pending)
                }
                self.failDeferredSingleModelGoalDispatchIfNeeded(
                    dispatchID: deferredSingleModelDispatchID,
                    message:
                        "單模型 runner 的遠端 claim 檢查已取消或被取代；"
                        + "原 dispatch 已 fail closed。")
                return
            }
            guard self.currentSessionStableKey() == originSessionKey else {
                if case .claimed(let pending?) = claimResult {
                    await self.releasePendingRemoteClaimAfterCancellation(pending)
                }
                self.failDeferredSingleModelGoalDispatchIfNeeded(
                    dispatchID: deferredSingleModelDispatchID,
                    message:
                        "單模型 runner 尚在遠端 claim 檢查期間，thread／session 已切換；"
                        + "原 dispatch 已 fail closed。")
                self.completePendingRemoteTurn(
                    generation: generation,
                    startNextQueuedTurn: false)
                return
            }
            switch claimResult {
            case .unreadable:
                if !userMessageAlreadyAppended {
                    _ = self.appendMessage(
                        ChatMessage(role: .user, text: displayTurn, eventKind: .message))
                }
                self.failDeferredSingleModelGoalDispatchIfNeeded(
                    dispatchID: deferredSingleModelDispatchID,
                    message:
                        "單模型 runner 的遠端 claim 狀態無法安全解碼；"
                        + "原 dispatch 已 fail closed。")
                self.flashComposerHint("遠端借用待命狀態無法安全讀取；沒有派工。")
                self.completePendingRemoteTurn(generation: generation)
            case .ambiguousTargets(let targets):
                if !userMessageAlreadyAppended {
                    _ = self.appendMessage(
                        ChatMessage(role: .user, text: displayTurn, eventKind: .message))
                }
                let blocker =
                    "這個 Chat Session 同時有 \(targets.count) 個待命遠端目標；"
                    + "請先明確選擇一台設備，沒有派工。"
                for target in targets {
                    _ = self.recordPendingRemoteTargetBlocker(
                        target: target,
                        blocker: blocker)
                }
                self.failDeferredSingleModelGoalDispatchIfNeeded(
                    dispatchID: deferredSingleModelDispatchID,
                    message:
                        "單模型 runner 的遠端 claim 目標不唯一；"
                        + "原 dispatch 已 fail closed。")
                self.updateSelectedThreadPreview(
                    "遠端派工需要選擇設備 · \(targets.count) 個待命目標",
                    sessionID: nil)
                self.flashComposerHint(blocker)
                self.completePendingRemoteTurn(
                    generation: generation,
                    startNextQueuedTurn: false)
            case .claimed(nil):
                self.completePendingRemoteTurn(
                    generation: generation,
                    startNextQueuedTurn: false)
                let started = self.startTurn(
                    displayTurn: displayTurn,
                    commandTurn: commandTurn,
                    visibleTurn: visibleTurn,
                    attachmentPaths: attachmentPaths,
                    previewTurn: previewTurn,
                    dispatchSnapshot: dispatchSnapshot,
                    userMessageAlreadyAppended: userMessageAlreadyAppended,
                    remoteClaimCompleted: true)
                if !started {
                    self.failDeferredSingleModelGoalDispatchIfNeeded(
                        dispatchID: deferredSingleModelDispatchID,
                        message:
                            "單模型 runner 通過遠端 claim 檢查後仍未建立實體 attempt；"
                            + "原 dispatch 已 fail closed。")
                }
            case .claimed(let pending?):
                if let deferredSingleModelDispatchID,
                   self.singleModelGoalDeferredStartAwaitingDispatchIDs
                    .contains(deferredSingleModelDispatchID)
                {
                    self.failDeferredSingleModelGoalDispatchIfNeeded(
                        dispatchID: deferredSingleModelDispatchID,
                        message:
                            "單模型 Goal dispatch 需要可驗證的 runner identity；"
                            + "遠端借用 claim 不得代替 runner start receipt。")
                    await self.finishRetryablePendingRemoteTurn(
                        pending,
                        blocker:
                            "單模型 Goal dispatch 尚未支援以遠端借用 claim"
                            + " 代替本機 runner identity",
                        generation: generation,
                        cancellationFence: cancellationFence)
                    return
                }
                self.pendingRemoteTurnClaim = pending
                await self.finishPendingRemoteClaim(
                    pending,
                    expectedSessionID: sessionID,
                    displayTurn: displayTurn,
                    commandTurn: commandTurn,
                    visibleTurn: visibleTurn,
                    attachmentPaths: attachmentPaths,
                    previewTurn: previewTurn,
                    dispatchSnapshot: dispatchSnapshot,
                    userMessageAlreadyAppended: userMessageAlreadyAppended,
                    generation: generation,
                    cancellationFence: cancellationFence)
            }
        }
        pendingRemoteTurnTask = remoteTurnTask
        let isConfirmedPlanExecutionTurn =
            ChatPlanThoughtPresentation.isConfirmedPlanExecutionPrompt(
                ChatMessage(
                    role: .user,
                    text: displayTurn,
                    eventKind: .message))
        if planConfirmInFlight,
           isConfirmedPlanExecutionTurn,
           confirmedPlanDeferredStartBoundaryHandle == nil,
           let confirmationGeneration =
                activeConfirmedPlanConfirmationGeneration
        {
            confirmedPlanDeferredStartBoundaryHandle =
                ConfirmedPlanDeferredStartBoundaryHandle(
                    identity: UUID(),
                    remoteTurnGeneration: generation,
                    confirmationGeneration: confirmationGeneration,
                    task: remoteTurnTask,
                    cancellationFence: cancellationFence)
        }
        return true
    }

    private func finishPendingRemoteClaim(
        _ pending: ChatPendingRemoteTargetV1,
        expectedSessionID: String,
        displayTurn: String,
        commandTurn: String,
        visibleTurn: String,
        attachmentPaths: [String],
        previewTurn: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        userMessageAlreadyAppended: Bool,
        generation: UInt64,
        cancellationFence: ChatRemoteTurnCancellationFence
    ) async {
        guard isCurrentPendingRemoteTurn(
            generation: generation,
            cancellationFence: cancellationFence)
        else {
            await releasePendingRemoteClaimAfterCancellation(pending)
            return
        }
        // An accepted receipt belongs to the previous physical turn. Reconcile
        // it first, then continue this newly submitted prompt through the normal
        // local Chat path. Never let a relaunch receipt consume a fresh prompt.
        if pending.state == .accepted {
            await reconcilePreviouslyAcceptedRemoteDispatchAndContinueTurn(
                pending,
                displayTurn: displayTurn,
                commandTurn: commandTurn,
                visibleTurn: visibleTurn,
                attachmentPaths: attachmentPaths,
                previewTurn: previewTurn,
                dispatchSnapshot: dispatchSnapshot,
                userMessageAlreadyAppended: userMessageAlreadyAppended,
                generation: generation,
                cancellationFence: cancellationFence)
            return
        }
        guard selectedRemoteBorrowSessionID == expectedSessionID else {
            await finishTerminalPendingRemoteTurn(
                pending,
                blocker: "Chat Session 已變更",
                displayTurn: displayTurn,
                userMessageAlreadyAppended: userMessageAlreadyAppended,
                generation: generation,
                cancellationFence: cancellationFence)
            return
        }
        if !userMessageAlreadyAppended,
           !appendMessage(ChatMessage(role: .user, text: displayTurn, eventKind: .message))
        {
            await finishRetryablePendingRemoteTurn(
                pending,
                blocker: "canonical transcript journal 無法落盤",
                generation: generation,
                cancellationFence: cancellationFence)
            return
        }
        if pending.contractID != selectedThread?.workOSContractID {
            await finishTerminalPendingRemoteTurn(
                pending,
                blocker: "Work OS Contract 已變更",
                displayTurn: displayTurn,
                userMessageAlreadyAppended: true,
                generation: generation,
                cancellationFence: cancellationFence)
            return
        }
        if pending.goalID != selectedThread?.workOSGoalID {
            await finishTerminalPendingRemoteTurn(
                pending,
                blocker: "Goal 已結束或變更",
                displayTurn: displayTurn,
                userMessageAlreadyAppended: true,
                generation: generation,
                cancellationFence: cancellationFence)
            return
        }

        let authorizationStore = remoteBorrowAuthorizationStore
        let goalStore = goalRunStore
        let store = pendingRemoteTargetStore
        let dispatcher = remoteTurnDispatcher
        let exactModelRouteID = dispatchSnapshot.canonicalModelID
        let remoteAgent: TatwoRemoteAgentKindV1?
        if exactModelRouteID.hasPrefix("grok-") {
            remoteAgent = .grok
        } else if exactModelRouteID.hasPrefix("fable-")
            || exactModelRouteID.hasPrefix("opus-")
            || exactModelRouteID.hasPrefix("sonnet-")
            || exactModelRouteID.hasPrefix("haiku-")
        {
            remoteAgent = .claude
        } else if exactModelRouteID.hasPrefix("gpt-")
            || exactModelRouteID.hasPrefix("chatgpt-")
        {
            remoteAgent = .codex
        } else {
            remoteAgent = nil
        }
        let result: ChatPendingRemoteDispatchResult? = await Task.detached(
            priority: .userInitiated
        ) {
                guard !cancellationFence.isCancelled else {
                    _ = try? store.releaseForRetry(claimID: pending.claimID)
                    return nil
                }
                if pending.state == .accepted {
                    guard let remoteJobID = pending.remoteJobID,
                          let acceptedAt = pending.acceptedAt
                    else {
                        _ = try? store.invalidate(
                            sessionID: pending.sessionID,
                            targetDeviceID: pending.targetDeviceID)
                        return .invalidated(
                            pending,
                            "已接受的遠端派工收據不完整")
                    }
                    return .accepted(
                        pending,
                        ChatRemoteTurnDispatchAcceptance(
                            logicalJobID: pending.logicalJobID,
                            remoteJobID: remoteJobID,
                            acceptedAt: acceptedAt))
                }
                do {
                    let activeGrant = try authorizationStore.sessionGrant(
                        sessionID: pending.sessionID,
                        targetDeviceID: pending.targetDeviceID,
                        contractID: pending.contractID)
                    guard activeGrant?.id == pending.grantID else {
                        _ = try? store.invalidate(
                            sessionID: pending.sessionID,
                            targetDeviceID: pending.targetDeviceID)
                        return .invalidated(
                            pending,
                            "遠端借用許可已撤銷或過期")
                    }
                } catch {
                    do {
                        let released = try store.releaseForRetry(
                            claimID: pending.claimID)
                        return .retryable(
                            released,
                            "遠端借用許可無法安全驗證")
                    } catch {
                        return .storageBlocked(
                            pending,
                            "遠端借用許可與待命狀態都無法安全驗證")
                    }
                }
                guard !cancellationFence.isCancelled else {
                    _ = try? store.releaseForRetry(claimID: pending.claimID)
                    return nil
                }
                let canonicalGoal: TatwoStoredGoalRun
                do {
                    canonicalGoal = try goalStore.requireIssuedContract(
                        pending.contractID)
                } catch {
                    _ = try? store.invalidate(
                        sessionID: pending.sessionID,
                        targetDeviceID: pending.targetDeviceID)
                    return .invalidated(
                        pending,
                        "canonical GoalRun 無法驗證")
                }
                guard canonicalGoal.goalID == pending.goalID else {
                    _ = try? store.invalidate(
                        sessionID: pending.sessionID,
                        targetDeviceID: pending.targetDeviceID)
                    return .invalidated(
                        pending,
                        "canonical GoalRun scope 已變更")
                }
                guard !cancellationFence.isCancelled else {
                    _ = try? store.releaseForRetry(claimID: pending.claimID)
                    return nil
                }
                guard let remoteAgent,
                      TatwoModelIdentityRegistry.canonicalModelID(
                        for: exactModelRouteID) == exactModelRouteID,
                      TatwoModelIdentityRegistry.isActiveDispatchEligible(
                        exactModelRouteID),
                      remoteAgent.acceptsExactModelRouteID(exactModelRouteID)
                else {
                    _ = try? store.invalidate(
                        sessionID: pending.sessionID,
                        targetDeviceID: pending.targetDeviceID)
                    return .invalidated(
                        pending,
                        ChatRemoteTurnDispatchBlocker.readinessManifestMismatch.rawValue)
                }
                guard !cancellationFence.isCancelled else {
                    _ = try? store.releaseForRetry(claimID: pending.claimID)
                    return nil
                }
                let inflight: ChatPendingRemoteTargetV1
                do {
                    inflight = try store.markInflight(claimID: pending.claimID)
                } catch {
                    return .storageBlocked(
                        pending,
                        "遠端 claim 無法持久化為 inflight")
                }
                guard !cancellationFence.isCancelled else {
                    _ = try? store.releaseForRetry(claimID: inflight.claimID)
                    return nil
                }
                let invocation = TatwoRemoteBorrowInvocationV1(
                    sessionID: inflight.sessionID,
                    targetDeviceID: inflight.targetDeviceID,
                    contractID: inflight.contractID,
                    goalID: inflight.goalID,
                    mode: .manual,
                    risk: .lowRisk,
                    grantID: inflight.grantID)
                let request = ChatRemoteTurnDispatchRequest(
                    visibleTurn: visibleTurn,
                    invocation: invocation,
                    claimID: inflight.claimID,
                    logicalJobID: inflight.logicalJobID,
                    contractMode: canonicalGoal.mode,
                    agent: remoteAgent,
                    exactModelRouteID: exactModelRouteID,
                    readinessChallengeNonce:
                        "chat-readiness-\(UUID().uuidString.lowercased())",
                    targetReadinessManifest: nil,
                    readinessBinding: nil)
                guard cancellationFence.tryBeginDispatch() else {
                    _ = try? store.releaseForRetry(claimID: inflight.claimID)
                    return nil
                }
                switch dispatcher.dispatch(request) {
                case .accepted(let acceptance):
                    guard acceptance.hasValidJobIdentity,
                          acceptance.logicalJobID == request.logicalJobID
                    else {
                        _ = try? store.invalidate(
                            sessionID: inflight.sessionID,
                            targetDeviceID: inflight.targetDeviceID)
                        return .invalidated(
                            inflight,
                            ChatRemoteTurnDispatchBlocker.dispatchRejected.rawValue)
                    }
                    do {
                        let accepted = try store.markAccepted(
                            claimID: inflight.claimID,
                            remoteJobID: acceptance.remoteJobID,
                            acceptedAt: acceptance.acceptedAt)
                        return .accepted(accepted, acceptance)
                    } catch {
                        return .storageBlocked(
                            inflight,
                            "遠端工作可能已接受，但 accepted 收據無法安全落盤")
                    }
                case .blocked(let blocker):
                    switch blocker {
                    case .targetTrustLost, .targetLeaseLost, .originLeaseLost,
                         .contractModeMismatch:
                        _ = try? store.invalidate(
                            sessionID: inflight.sessionID,
                            targetDeviceID: inflight.targetDeviceID)
                        return .invalidated(inflight, blocker.rawValue)
                    case .adapterUnavailable, .dispatchRejected,
                         .readinessManifestMissing, .readinessManifestStale,
                         .readinessManifestMismatch:
                        do {
                            let released = try store.releaseForRetry(
                                claimID: inflight.claimID)
                            return .retryable(released, blocker.rawValue)
                        } catch {
                            return .storageBlocked(
                                inflight,
                                "\(blocker.rawValue)；claim 無法安全釋回待命")
                        }
                    }
                }
            }.value
        guard isCurrentPendingRemoteTurn(
            generation: generation,
            cancellationFence: cancellationFence)
        else { return }
        guard let result else {
            completePendingRemoteTurn(generation: generation)
            return
        }
        publishPendingRemoteDispatchResult(
            result,
            pending: pending,
            previewTurn: previewTurn,
            generation: generation,
            cancellationFence: cancellationFence)
    }

    private func reconcilePreviouslyAcceptedRemoteDispatchAndContinueTurn(
        _ pending: ChatPendingRemoteTargetV1,
        displayTurn: String,
        commandTurn: String,
        visibleTurn: String,
        attachmentPaths: [String],
        previewTurn: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        userMessageAlreadyAppended: Bool,
        generation: UInt64,
        cancellationFence: ChatRemoteTurnCancellationFence
    ) async {
        guard let remoteJobID = pending.remoteJobID,
              let acceptedAt = pending.acceptedAt
        else {
            _ = try? pendingRemoteTargetStore.invalidate(
                sessionID: pending.sessionID,
                targetDeviceID: pending.targetDeviceID)
            _ = recordPendingRemoteTargetBlocker(
                target: pending,
                blocker: "已接受的遠端派工收據不完整")
            completePendingRemoteTurn(
                generation: generation,
                startNextQueuedTurn: false)
            startTurn(
                displayTurn: displayTurn,
                commandTurn: commandTurn,
                visibleTurn: visibleTurn,
                attachmentPaths: attachmentPaths,
                previewTurn: previewTurn,
                dispatchSnapshot: dispatchSnapshot,
                userMessageAlreadyAppended: userMessageAlreadyAppended,
                remoteClaimCompleted: true)
            return
        }

        let acceptance = ChatRemoteTurnDispatchAcceptance(
            logicalJobID: pending.logicalJobID,
            remoteJobID: remoteJobID,
            acceptedAt: acceptedAt)
        let journaled = recordAcceptedRemoteDispatch(
            target: pending,
            acceptance: acceptance)
        let store = pendingRemoteTargetStore
        let consumed = await Task.detached(priority: .utility) {
            guard journaled else { return false }
            do {
                try store.consumeAccepted(claimID: pending.claimID)
                return true
            } catch {
                return false
            }
        }.value
        guard isCurrentPendingRemoteTurn(
            generation: generation,
            cancellationFence: cancellationFence)
        else { return }

        if journaled {
            updateSelectedThreadPreview(
                "遠端工作已送達 · \(pending.targetDisplayName)",
                sessionID: nil)
            flashComposerHint(
                consumed
                    ? "已補回上一筆遠端送達收據；這一則新訊息已繼續處理。"
                    : "已補回上一筆遠端送達收據；consumed 狀態待協調，這一則新訊息仍繼續處理。")
        } else {
            flashComposerHint(
                "上一筆 accepted 收據暫時無法寫入 canonical journal；這一則新訊息仍繼續處理，不會被吃掉。")
        }
        completePendingRemoteTurn(
            generation: generation,
            startNextQueuedTurn: false)
        startTurn(
            displayTurn: displayTurn,
            commandTurn: commandTurn,
            visibleTurn: visibleTurn,
            attachmentPaths: attachmentPaths,
            previewTurn: previewTurn,
            dispatchSnapshot: dispatchSnapshot,
            userMessageAlreadyAppended: userMessageAlreadyAppended,
            remoteClaimCompleted: true)
    }

    private func publishPendingRemoteDispatchResult(
        _ result: ChatPendingRemoteDispatchResult,
        pending: ChatPendingRemoteTargetV1,
        previewTurn: String,
        generation: UInt64,
        cancellationFence: ChatRemoteTurnCancellationFence
    ) {
        guard isCurrentPendingRemoteTurn(
            generation: generation,
            cancellationFence: cancellationFence)
        else { return }
        switch result {
        case .retryable(let target, let blocker):
            _ = recordPendingRemoteTargetBlocker(
                target: target,
                blocker: blocker)
            updateSelectedThreadPreview("遠端派工待重試 · \(blocker)", sessionID: nil)
            flashComposerHint("\(blocker)；待命已保留，下一個一般回合可用相同工作識別重試。")
            completePendingRemoteTurn(generation: generation)
        case .invalidated(let target, let blocker):
            _ = recordPendingRemoteTargetBlocker(
                target: target,
                blocker: blocker)
            updateSelectedThreadPreview(
                "遠端派工已停止 · \(blocker)",
                sessionID: nil)
            flashComposerHint("\(blocker)；待命已失效，沒有派工。")
            completePendingRemoteTurn(generation: generation)
        case .storageBlocked(let target, let blocker):
            _ = recordPendingRemoteTargetBlocker(
                target: target,
                blocker: blocker)
            updateSelectedThreadPreview("遠端派工狀態待協調 · \(blocker)", sessionID: nil)
            flashComposerHint("\(blocker)；沒有建立新的本機派工識別。")
            completePendingRemoteTurn(generation: generation)
        case .accepted(let acceptedTarget, let acceptance):
            guard recordAcceptedRemoteDispatch(
                target: acceptedTarget,
                acceptance: acceptance)
            else {
                flashComposerHint(
                    "遠端派工已接受，但 canonical journal 無法落盤；accepted 收據已保留，稍後只重播收據、不重新派工。")
                completePendingRemoteTurn(generation: generation)
                return
            }
            let store = pendingRemoteTargetStore
            pendingRemoteTurnTask = Task { @MainActor [weak self] in
                let consumed = await Task.detached(priority: .utility) {
                    do {
                        try store.consumeAccepted(claimID: acceptedTarget.claimID)
                        return true
                    } catch {
                        return false
                    }
                }.value
                guard let self else { return }
                guard self.isCurrentPendingRemoteTurn(
                    generation: generation,
                    cancellationFence: cancellationFence)
                else { return }
                self.updateSelectedThreadPreview(
                    "遠端工作已送達 · \(acceptedTarget.targetDisplayName)",
                    sessionID: nil)
                self.recordLiveWork(
                    status:
                        "delivered|"
                        + (Self.activityDetail(from: previewTurn) ?? "遠端工作"),
                    isTerminal: false)
                self.flashComposerHint(
                    consumed
                        ? "已送達 \(acceptedTarget.targetDisplayName)；等待目標設備啟動。"
                        : "已送達 \(acceptedTarget.targetDisplayName)；journal 已落盤，但 consumed 狀態待下次安全協調。")
                self.completePendingRemoteTurn(generation: generation)
            }
        }
    }

    private func finishTerminalPendingRemoteTurn(
        _ pending: ChatPendingRemoteTargetV1,
        blocker: String,
        displayTurn: String,
        userMessageAlreadyAppended: Bool,
        generation: UInt64,
        cancellationFence: ChatRemoteTurnCancellationFence
    ) async {
        if !userMessageAlreadyAppended {
            _ = appendMessage(ChatMessage(role: .user, text: displayTurn, eventKind: .message))
        }
        let store = pendingRemoteTargetStore
        let invalidated = await Task.detached(priority: .utility) {
            (try? store.invalidate(
                sessionID: pending.sessionID,
                targetDeviceID: pending.targetDeviceID)) == true
        }.value
        guard isCurrentPendingRemoteTurn(
            generation: generation,
            cancellationFence: cancellationFence)
        else { return }
        let finalBlocker = invalidated
            ? blocker
            : "\(blocker)；待命狀態無法安全失效"
        _ = recordPendingRemoteTargetBlocker(
            target: pending,
            blocker: finalBlocker)
        updateSelectedThreadPreview(
            "遠端派工已停止 · \(finalBlocker)",
            sessionID: nil)
        flashComposerHint("\(finalBlocker)；沒有派工。")
        completePendingRemoteTurn(generation: generation)
    }

    private func finishRetryablePendingRemoteTurn(
        _ pending: ChatPendingRemoteTargetV1,
        blocker: String,
        generation: UInt64,
        cancellationFence: ChatRemoteTurnCancellationFence
    ) async {
        let store = pendingRemoteTargetStore
        let released = await Task.detached(priority: .utility) {
            try? store.releaseForRetry(claimID: pending.claimID)
        }.value
        guard isCurrentPendingRemoteTurn(
            generation: generation,
            cancellationFence: cancellationFence)
        else { return }
        let finalBlocker = released == nil
            ? "\(blocker)；claim 無法安全釋回待命"
            : blocker
        _ = recordPendingRemoteTargetBlocker(
            target: released ?? pending,
            blocker: finalBlocker)
        flashComposerHint("\(finalBlocker)；沒有派工。")
        completePendingRemoteTurn(generation: generation)
    }

    private func completePendingRemoteTurn(
        generation: UInt64,
        startNextQueuedTurn: Bool = true
    ) {
        guard pendingRemoteTurnGeneration == generation else { return }
        pendingRemoteTurnTask = nil
        pendingRemoteTurnCancellationFence = nil
        pendingRemoteTurnClaim = nil
        isRunning = false
        applyPendingModelSelectionIfPossible()
        if startNextQueuedTurn {
            startNextChatIfNeeded()
        }
    }

    private func isCurrentPendingRemoteTurn(
        generation: UInt64,
        cancellationFence: ChatRemoteTurnCancellationFence
    ) -> Bool {
        pendingRemoteTurnGeneration == generation
            && pendingRemoteTurnCancellationFence === cancellationFence
            && !cancellationFence.isCancelled
    }

    private func releasePendingRemoteClaimAfterCancellation(
        _ pending: ChatPendingRemoteTargetV1
    ) async {
        guard pending.state == .claiming || pending.state == .inflight else { return }
        let store = pendingRemoteTargetStore
        _ = await Task.detached(priority: .utility) {
            try? store.releaseForRetry(claimID: pending.claimID)
        }.value
    }

    private func failDeferredSingleModelGoalDispatchIfNeeded(
        dispatchID: String?,
        message: String
    ) {
        guard let dispatchID else { return }
        singleModelGoalDeferredStartAwaitingDispatchIDs.remove(dispatchID)
        guard !singleModelGoalDispatchRuntimeContractIDs(
            dispatchID: dispatchID).isEmpty
        else {
            return
        }
        failPendingSingleModelGoalDispatch(
            dispatchID: dispatchID,
            message: message)
    }

    func cancelPendingRemoteSingleModelDeferredStartIfNeeded(
        message: String
    ) {
        let dispatchIDs =
            Array(singleModelGoalDeferredStartAwaitingDispatchIDs)
        guard !dispatchIDs.isEmpty else { return }
        let cancellationFence = pendingRemoteTurnCancellationFence
        let dispatchAlreadyBegan = cancellationFence?.cancel() ?? false
        let claimedTarget = pendingRemoteTurnClaim
        pendingRemoteTurnGeneration &+= 1
        pendingRemoteTurnTask?.cancel()
        pendingRemoteTurnTask = nil
        pendingRemoteTurnCancellationFence = nil
        pendingRemoteTurnClaim = nil
        if activeTurnLifecycle == nil {
            isRunning = false
        }
        applyPendingModelSelectionIfPossible()
        if !dispatchAlreadyBegan, let claimedTarget {
            Task { @MainActor [weak self] in
                await self?.releasePendingRemoteClaimAfterCancellation(
                    claimedTarget)
            }
        }
        for dispatchID in dispatchIDs {
            failDeferredSingleModelGoalDispatchIfNeeded(
                dispatchID: dispatchID,
                message: message)
        }
    }

    @discardableResult
    func enqueueChatTurn(
        displayTurn: String,
        commandBaseTurn: String,
        visibleTurn: String,
        attachmentPaths: [String],
        previewTurn: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        suppressUserEcho: Bool
    ) -> Bool {
        guard dispatchSnapshot.canDispatch else {
            flashComposerHint(
                dispatchSnapshot.blocker
                    ?? "本輪 route/effort contract 無法驗證；沒有排隊或派工。")
            return false
        }
        guard chatQueue.count < Self.maxQueuedChatTurns else {
            flashComposerHint(
                "插話佇列已達 \(Self.maxQueuedChatTurns) 輪；請等待目前回覆完成後再送，避免長時間辦公時佇列失控。")
            return false
        }
        let message = ChatMessage(
            role: .user,
            text: displayTurn,
            status: "queued",
            eventKind: .message)
        let candidate = ChatQueuedTicket(
            threadID: selectedThreadID,
            discussionID: selectedDiscussionID,
            messageID: message.id,
            displayTurn: displayTurn,
            commandBaseTurn: commandBaseTurn,
            visibleTurn: visibleTurn,
            attachmentPaths: attachmentPaths,
            preview: String(previewTurn.prefix(80)),
            dispatchSnapshot: dispatchSnapshot)
        let nextUTF8Bytes = candidate.residentUTF8Bytes
        let queuedUTF8Bytes = chatQueue.reduce(into: 0) {
            $0 += $1.residentUTF8Bytes
        }
        guard queuedUTF8Bytes + nextUTF8Bytes <= Self.maxQueuedChatUTF8Bytes else {
            flashComposerHint(
                "插話佇列內容已達 \(Self.maxQueuedChatUTF8Bytes / 1024) KiB；請等待目前回覆完成後再送，避免記憶體與上下文壓力。")
            return false
        }
        if !suppressUserEcho {
            guard appendMessage(message) else {
                flashComposerHint("排隊失敗：canonical transcript journal 無法落盤。")
                return false
            }
        }
        chatQueue.append(candidate)
        if suppressUserEcho {
            queuedUserEchoSuppressionMessageIDs.insert(message.id)
        }
        if let dispatchID = pendingSingleModelGoalDispatch?.id {
            singleModelGoalDeferredStartAwaitingDispatchIDs.insert(dispatchID)
        }
        recordLiveWork(
            status: "queued|\(String(previewTurn.prefix(54)))",
            isTerminal: false)
        updateSelectedThreadPreview("插話已排隊 · \(String(previewTurn.prefix(80)))", sessionID: nil)
        flashComposerHint("已插入佇列；會在目前回覆結束後執行。")
        return true
    }

    func stop() {
        cancelPendingRemoteSingleModelDeferredStartIfNeeded(
            message:
                "使用者在單模型 runner 的遠端 claim 檢查期間取消；"
                + "原 dispatch 已 fail closed。")
        if let pendingTask = pendingRemoteTurnTask {
            userStopRequested = true
            let cancellationFence = pendingRemoteTurnCancellationFence
            let dispatchAlreadyBegan = cancellationFence?.cancel() ?? false
            let claimedTarget = pendingRemoteTurnClaim
            pendingRemoteTurnGeneration &+= 1
            pendingTask.cancel()
            pendingRemoteTurnTask = nil
            pendingRemoteTurnCancellationFence = nil
            pendingRemoteTurnClaim = nil
            isRunning = false
            applyPendingModelSelectionIfPossible()
            if !dispatchAlreadyBegan, let claimedTarget {
                Task { @MainActor [weak self] in
                    await self?.releasePendingRemoteClaimAfterCancellation(
                        claimedTarget)
                }
            }
            flashComposerHint(
                dispatchAlreadyBegan
                    ? "已停止等待；遠端派工已跨過送出邊界，accepted 收據若產生將保留供下次安全協調。"
                    : "已停止遠端派工；待命 claim 將安全釋回。")
        }
        if isRunning, var lifecycle = activeTurnLifecycle {
            userStopRequested = true
            if lifecycle.phase == .cancellationRequested {
                retryBlockedCancellationConvergence()
            } else if lifecycle.requestCancellation() {
                activeTurnLifecycle = lifecycle
                persistCancellationRequest(lifecycle)
                // The immutable dispatch snapshot decides which domain is
                // primary. Always stop the other idempotently as a fail-safe so
                // missing or rewritten message metadata cannot leak a task.
                terminateRunnersForCurrentSession()
            }
        }
        initialStoreLoadController.cancel()
        switch coldStartHydrationState {
        case .scheduled, .retryScheduled, .running, .loadingStore:
            failColdStartHydration(
                reason: "initial-store-load-cancelled",
                attempt: coldStartHydrationAttempt)
        default:
            break
        }
        selectedWorkOSStateLoadTask?.cancel()
        if !chatQueue.isEmpty {
            chatQueuePaused = true
            recordLiveWork(status: "paused|已暫停 \(chatQueue.count) 個插話")
        }
        pendingComputerAutoContinuation = nil
        clearActiveComputerHostLease(runID: activeTurnLifecycle?.runID)
    }

    func processRunnerBound(to runID: String) -> ChatCLIProcessRunner {
        if let key = sessionKeyByRunID[runID],
           let bound = cliRunnersBySessionKey[key]
        {
            return bound
        }
        return runner
    }

    func cancelRunnerStateReconciler(for runID: String) {
        runnerStateReconcileGenerationsByRunID.removeValue(forKey: runID)
        runnerStateReconcileTasksByRunID.removeValue(forKey: runID)?.cancel()
    }

    private func clearRunnerStateReconcilerIfCurrent(
        runID: String,
        generation: UUID
    ) {
        guard runnerStateReconcileGenerationsByRunID[runID] == generation else {
            return
        }
        runnerStateReconcileGenerationsByRunID.removeValue(forKey: runID)
        runnerStateReconcileTasksByRunID.removeValue(forKey: runID)
    }

    func cancelAllRunnerStateReconcilers() {
        let tasks = runnerStateReconcileTasksByRunID
        runnerStateReconcileTasksByRunID.removeAll(keepingCapacity: false)
        runnerStateReconcileGenerationsByRunID.removeAll(keepingCapacity: false)
        for task in tasks.values {
            task.cancel()
        }
    }

    func startRunnerStateReconciler(for assistantID: ChatMessage.ID, runID: String) {
        cancelRunnerStateReconciler(for: runID)
        let generation = UUID()
        runnerStateReconcileGenerationsByRunID[runID] = generation
        let task = Task { @MainActor [weak self] in
            defer {
                self?.clearRunnerStateReconcilerIfCurrent(
                    runID: runID,
                    generation: generation)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                guard self.isSessionRunning(runID: runID) else { return }
                let processRunner = self.processRunnerBound(to: runID)
                let diagnostics = processRunner.diagnosticsSnapshot
                if diagnostics.lifecycleRunID == runID {
                    if let signal =
                        diagnostics.blockedTerminalFailureSignal,
                       signal.runID == runID
                    {
                        self.withTurnRuntime(for: runID) {
                            _ = self.consumeBlockedTerminalFailureSignal(
                                runID: runID,
                                eventMessage: signal.message)
                        }
                        let snapshot = processRunner.lifecycleSnapshot
                        guard snapshot?.runID == runID,
                              snapshot?.formalExitStatus != nil
                        else { continue }
                    } else {
                        switch diagnostics.cancellationConvergenceState {
                        case .blocked(let reason):
                            self.withTurnRuntime(for: runID) {
                                self.presentBlockedCancellation(
                                    reason: reason,
                                    assistantID: assistantID,
                                    runID: runID)
                            }
                            continue
                        case .notRequested,
                             .awaitingProbe,
                             .terminalByCallback,
                             .terminalByAuthoritativeInactivity:
                            break
                        }
                    }
                }
                var shouldReconcile = false
                var reconcileStatus: Int32?
                var reconcileFailure: String?
                self.withTurnRuntime(for: runID) {
                    guard self.isRunning,
                          let lifecycle = self.activeTurnLifecycle,
                          lifecycle.runID == runID,
                          lifecycle.assistantID == assistantID,
                          let snapshot = processRunner.lifecycleSnapshot,
                          lifecycle.shouldReconcileInactiveRunner(
                            snapshot: snapshot),
                          let status = snapshot.formalExitStatus
                    else { return }
                    shouldReconcile = true
                    reconcileStatus = status
                    reconcileFailure = snapshot.formalFailureMessage
                }
                guard shouldReconcile, let status = reconcileStatus else {
                    continue
                }
                self.withTurnRuntime(for: runID) {
                    self.reconcileInactiveRunner(
                        assistantID: assistantID,
                        runID: runID,
                        status: status,
                        failureMessage: reconcileFailure)
                }
                return
            }
        }
        runnerStateReconcileTasksByRunID[runID] = task
    }

    private func presentBlockedCancellation(
        reason: String,
        assistantID: ChatMessage.ID,
        runID: String
    ) {
        guard isRunning,
              activeAssistantID == assistantID,
              let lifecycle = activeTurnLifecycle,
              lifecycle.runID == runID,
              lifecycle.phase == .cancellationRequested
        else { return }

        let isNewBlock = cancellationBlockedReason != reason
        cancellationBlockedReason = reason
        persistBlockedCancellation(
            lifecycle: lifecycle,
            assistantID: assistantID,
            reason: reason)
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if !messages[index].text.contains(Self.cancellationBlockedNotice) {
            let separator = messages[index].text.isEmpty ? "" : "\n\n"
            let fragment = separator + Self.cancellationBlockedNotice
            messages[index].text = ChatPageAssistantTextAppendPolicy.appending(
                fragment,
                to: messages[index].text)
            _ = streamLedger.appendTailChunk(fragment)
        }
        messages[index].status = "cancellation-blocked"
        messages[index].eventKind = .message
        messages[index].modelID = activeTurnAttributionModelID(
            fallback: messages[index])
        cacheSelectedSessionMessages()
        if isNewBlock {
            recordLiveWork(status: "cancellation-blocked|取消受阻")
            flashComposerHint("取消受阻；請再次按停止以重試取消。")
        }
    }

    private func retryBlockedCancellationConvergence() {
        guard isRunning,
              cancellationBlockedReason != nil,
              let lifecycle = activeTurnLifecycle,
              lifecycle.phase == .cancellationRequested
        else { return }

        if let record = durableCancellationRecord {
            do {
                durableCancellationRecord =
                    try cancellationDurability.markRetrying(record)
            } catch {
                cancellationBlockedReason =
                    "cancellation-state-persistence-failed"
            }
        }

        guard let identity = cancellationIdentity(for: lifecycle) else {
            cancellationBlockedReason =
                "runner-attempt-authority-unknown"
            return
        }
        let localSnapshot = runner.lifecycleSnapshot
        if localSnapshot?.runID == identity.runID {
            runner.retryBlockedCancellationConvergence()
        } else {
            handleAuthoritativeTerminationRetry(
                runnerAuthorityDiscoverer.requestTermination(for: identity),
                identity: identity)
        }

        if let activeAssistantID,
           let index = messages.firstIndex(where: { $0.id == activeAssistantID })
        {
            if !messages[index].text.contains(Self.cancellationRetryNotice) {
                let separator = messages[index].text.isEmpty ? "" : "\n\n"
                let fragment = separator + Self.cancellationRetryNotice
                messages[index].text = ChatPageAssistantTextAppendPolicy.appending(
                    fragment,
                    to: messages[index].text)
                _ = streamLedger.appendTailChunk(fragment)
            }
            messages[index].status = "cancellation-retrying"
            messages[index].eventKind = .message
            cacheSelectedSessionMessages()
        }
        recordLiveWork(status: "cancellation-retrying|正在重試取消")
        flashComposerHint("正在重試取消；正式終止確認前聊天維持鎖定。")
    }

    private func cancellationIdentity(
        for lifecycle: TatwoChatTurnLifecycle
    ) -> ChatRunnerAttemptIdentity? {
        if let durableCancellationRecord,
           durableCancellationRecord.identity.runID == lifecycle.runID,
           durableCancellationRecord.identity.instanceID
                == lifecycle.runnerInstanceID,
           durableCancellationRecord.identity.revision
                == lifecycle.runnerRevision
        {
            return durableCancellationRecord.identity
        }
        let diagnostics = runner.diagnosticsSnapshot
        guard diagnostics.lifecycleRunID == lifecycle.runID,
              let identity = diagnostics.authorityIdentity,
              identity.runID == lifecycle.runID
        else { return nil }
        return identity
    }

    private func persistCancellationRequest(
        _ lifecycle: TatwoChatTurnLifecycle
    ) {
        guard let identity = cancellationIdentity(for: lifecycle) else {
            cancellationBlockedReason =
                "runner-attempt-authority-unknown"
            flashComposerHint(
                "無法確認目前 runner attempt；取消已送出，但聊天會維持鎖定。")
            return
        }
        do {
            durableCancellationRecord =
                try cancellationDurability.requestCancellation(
                    identity: identity,
                    assistantID: lifecycle.assistantID,
                    threadID: selectedSessionReference?.stableKey)
            cancellationBlockedReason = "cancellation-requested"
        } catch {
            cancellationBlockedReason =
                "cancellation-state-persistence-failed"
            flashComposerHint(
                "取消狀態無法安全落盤；聊天維持鎖定直到正式終止確認。")
        }
    }

    private func persistBlockedCancellation(
        lifecycle: TatwoChatTurnLifecycle,
        assistantID: String,
        reason: String
    ) {
        guard let identity = cancellationIdentity(for: lifecycle) else {
            cancellationBlockedReason =
                "runner-attempt-authority-unknown"
            return
        }
        do {
            durableCancellationRecord =
                try cancellationDurability.markBlocked(
                    identity: identity,
                    assistantID: assistantID,
                    threadID: selectedSessionReference?.stableKey
                        ?? durableCancellationRecord?.threadID,
                    reason: reason)
        } catch {
            cancellationBlockedReason =
                "cancellation-state-persistence-failed"
        }
    }

    private func handleAuthoritativeTerminationRetry(
        _ result: ChatRunnerTerminationRequestResult,
        identity: ChatRunnerAttemptIdentity
    ) {
        switch result {
        case .requested:
            cancellationBlockedReason = "cancellation-requested"
        case .blocked(let reason), .unknown(let reason):
            cancellationBlockedReason = reason
            if let lifecycle = activeTurnLifecycle {
                persistBlockedCancellation(
                    lifecycle: lifecycle,
                    assistantID: lifecycle.assistantID,
                    reason: reason)
            }
        case .formalTerminal(let status):
            guard acceptFormalTerminalEvent(
                runID: identity.runID,
                status: status)
            else { return }
            finishExitedTurn(status: status)
        case .reclaimed(let token):
            guard token.runID == identity.runID,
                  token.attempt == identity.attempt,
                  token.instanceID == identity.instanceID,
                  token.revision == identity.revision
            else {
                cancellationBlockedReason =
                    "runner-reclaim-identity-mismatch"
                return
            }
            reconcileColdStartTranscriptOrphans(
                authority: .authoritative(
                    activeRunIDs: [],
                    reclaimTokens: [token]))
            resolveDurableCancellationLock(identity: identity)
            clearCancellationBlockedPresentation()
            isRunning = false
            userStopRequested = false
            activeAssistantID = nil
            activeTurnLifecycle = nil
            activeTurnDispatchSnapshot = nil
            activeGatewayContinuationTurn = nil
            applyPendingModelSelectionIfPossible()
            restoreDurableCancellationLock()
            if !isRunning {
                startNextChatIfNeeded()
            }
        }
    }

    func restoreDurableCancellationLock(
        outstanding injectedOutstanding:
            [ChatDurableCancellationRecord]? = nil,
        authority injectedAuthority:
            ChatRunnerAuthoritySnapshot? = nil
    ) {
        var outstanding: [ChatDurableCancellationRecord]
        if let injectedOutstanding {
            outstanding = injectedOutstanding
        } else {
            do {
                outstanding = try cancellationDurability.allOutstanding()
            } catch {
                cancellationBlockedReason =
                    "cancellation-state-read-failed"
                isRunning = true
                return
            }
        }
        guard !outstanding.isEmpty else { return }

        let authority =
            injectedAuthority
            ?? runnerAuthorityDiscoverer.discoverRunnerAuthority()
        if case .authoritative(let activeRunIDs, let reclaimTokens) = authority {
            let reclaimable = outstanding.filter { record in
                !activeRunIDs.contains(record.identity.runID)
                    && reclaimTokens.contains { token in
                        token.runID == record.identity.runID
                            && token.attempt == record.identity.attempt
                            && token.instanceID == record.identity.instanceID
                            && token.revision == record.identity.revision
                    }
            }
            for record in reclaimable {
                resolveDurableCancellationLock(identity: record.identity)
            }
            outstanding.removeAll { record in
                reclaimable.contains { $0.identity == record.identity }
            }
            guard !outstanding.isEmpty else { return }
        }

        // Cancellation is App-global, not selected-thread-local. A runner from
        // any thread may still mutate the same workspace; unlocking a different
        // selected thread would allow duplicate execution. Present the newest
        // unresolved attempt, then reveal the next lock after it resolves.
        let record = outstanding.max {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.identity.runID < $1.identity.runID
        }!
        durableCancellationRecord = record
        cancellationBlockedReason =
            record.reason ?? "cancellation-awaiting-authority"
        activeAssistantID = record.assistantID
        var lifecycle = TatwoChatTurnLifecycle(
            runID: record.identity.runID,
            assistantID: record.assistantID,
            runnerInstanceID: record.identity.instanceID,
            runnerRevision: record.identity.revision,
            startedAt: record.updatedAt)
        _ = lifecycle.requestCancellation()
        activeTurnLifecycle = lifecycle
        isRunning = true
    }

    func resolveDurableCancellationAfterFormalTerminal() {
        guard let lifecycle = activeTurnLifecycle else { return }
        guard let identity = cancellationIdentity(for: lifecycle) else {
            return
        }
        resolveDurableCancellationLock(
            identity: identity)
    }

    private func resolveDurableCancellationLock(
        identity: ChatRunnerAttemptIdentity
    ) {
        do {
            try cancellationDurability.resolve(identity: identity)
            if durableCancellationRecord?.identity == identity {
                durableCancellationRecord = nil
            }
        } catch {
            // Formal terminal/reclaim is sufficient to unlock this process,
            // but keep an explicit warning because a stale disk lock may need
            // authoritative reconciliation on the next launch.
            flashComposerHint(
                "已確認執行程序終止，但取消鎖清理失敗；下次啟動將重新核對。")
        }
    }

    func clearCancellationBlockedPresentation() {
        guard cancellationBlockedReason != nil else { return }
        cancellationBlockedReason = nil
        guard let activeAssistantID,
              let index = messages.firstIndex(where: { $0.id == activeAssistantID })
        else { return }

        var cleaned = messages[index].text
        for notice in [Self.cancellationRetryNotice, Self.cancellationBlockedNotice] {
            guard cleaned.hasSuffix(notice) else { continue }
            cleaned.removeLast(notice.count)
            if cleaned.hasSuffix("\n\n") {
                cleaned.removeLast(2)
            }
        }
        messages[index].text = cleaned
        _ = streamLedger.replaceTailContent(cleaned)
    }

    private func reconcileInactiveRunner(
        assistantID: ChatMessage.ID,
        runID: String,
        status: Int32,
        failureMessage: String?
    ) {
        guard isRunning,
              let lifecycle = activeTurnLifecycle,
              lifecycle.runID == runID,
              lifecycle.assistantID == assistantID
        else { return }
        let diagnostics = runner.diagnosticsSnapshot
        let blockedTerminalFailureAlreadyPublished =
            activeAssistantID == nil
                && diagnostics.lifecycleRunID == runID
                && diagnostics.blockedTerminalFailureSignal.map { signal in
                    signal.runID == runID
                        && consumedBlockedTerminalFailureIdempotencyKeys
                            .contains(signal.idempotencyKey)
                } == true
        guard activeAssistantID == assistantID
                || blockedTerminalFailureAlreadyPublished
        else { return }
        guard acceptFormalTerminalEvent(runID: runID, status: status) else { return }
        if blockedTerminalFailureAlreadyPublished {
            finishBlockedTerminalFailureAfterFormalConvergence(runID: runID)
            return
        }
        if userStopRequested {
            finishExitedTurn(status: status)
        } else if let failureMessage {
            finishFailureTurn(
                message: failureMessage,
                activityFallback: "執行失敗")
        } else {
            finishExitedTurn(status: status)
        }
    }

    private func finishBlockedTerminalFailureAfterFormalConvergence(
        runID: String
    ) {
        cancelRunnerStateReconciler(for: runID)
        clearCancellationBlockedPresentation()
        activeGatewayContinuationTurn = nil
        resolveDurableCancellationAfterFormalTerminal()
        userStopRequested = false
        isRunning = false
        reloadCLISessions()
        clearActiveComputerHostLease(runID: runID)
        activeTurnLifecycle = nil
        activeTurnDispatchSnapshot = nil
        applyPendingModelSelectionIfPossible()
        restoreDurableCancellationLock()
        if !isRunning {
            startNextChatIfNeeded()
        }
    }

    func applyCoworkTemplate(_ template: TatwoCoworkTicketTemplate) {
        selectedCoworkTemplateID = template.id
        if selectedThreadID == nil { newChat() }
        updateSelectedThreadLoopsConfig(loopsConfig(for: template))
    }

    func setCollaborationLevel(_ level: ChatCollaborationLevel) {
        if selectedThreadID == nil { newChat() }
        guard level != collaborationLevel else { return }
        guard let workMode = level.workMode else {
            clearSelectedThreadCollaboration()
            return
        }
        // 拉桿過濾：換模式時，若目前情境已是該模式就留著；否則挑同 domain、同模式的情境，
        // 再退回任一同模式情境。避免「拉桿在 XL 但情境還停在 L」的錯配。
        let prev = selectedCoworkTemplate
        let template = (prev?.mode == workMode ? prev : nil)
            ?? coworkTemplates.first(where: { $0.mode == workMode && $0.category == prev?.category })
            ?? coworkTemplates.first(where: { $0.mode == workMode })
            ?? coworkTemplates.first
        guard let template else { return }
        selectedCoworkTemplateID = template.id
        updateSelectedThreadLoopsConfig(loopsConfig(for: template, mode: workMode))
    }

    func setCollaborationScenario(_ templateID: String) {
        guard let template = coworkTemplates.first(where: { $0.id == templateID }) else { return }
        selectedCoworkTemplateID = template.id
        guard let mode = collaborationLevel.workMode else { return }
        if selectedThreadID == nil { newChat() }
        updateSelectedThreadLoopsConfig(loopsConfig(for: template, mode: mode))
    }

    func setLoopsMode(_ mode: WorkModeID) {
        guard let config = activeLoopsConfig else {
            if let template = selectedCoworkTemplate {
                updateSelectedThreadLoopsConfig(loopsConfig(for: template, mode: mode))
            }
            return
        }
        let template = coworkTemplates.first(where: { $0.scenarioID == config.scenarioID }) ?? selectedCoworkTemplate
        guard let template else { return }
        updateSelectedThreadLoopsConfig(loopsConfig(for: template, mode: mode))
    }

    func setPrimaryModel(_ modelID: String) {
        guard var config = activeLoopsConfig else { return }
        let previousPrimary = activePrimaryModelID
        let previousSecondary = activeSecondaryModelID
        config.primaryModelID = modelID
        if modelID == previousSecondary {
            config.secondaryModelID = previousPrimary
        } else if config.secondaryModelID == nil || config.secondaryModelID == modelID {
            config.secondaryModelID = activeLoopsModelCandidates.first(where: { $0 != modelID }) ?? previousSecondary
        }
        updateSelectedThreadLoopsConfig(config)
    }
}
