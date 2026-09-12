import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    /// 明確的單模型 `/goal`（Plan inspector 選「/goal + 單模型」）必須跑在
    /// 單模型拓撲上。這一列如果還帶著 Ultrawork loopsConfig，簽發出來的是
    /// S 合約、thread 上卻是多模型 mode/scenario；送出那一輪 Work OS 重驗
    /// 會判定 objective／route／Goal binding 不一致而整個隔離，結果就是
    /// runner 一個都沒起來、輸入留在框裡、畫面還留著上一個 Ultrawork 級別。
    ///
    /// 只清目前選取的這一列，其他 session 的協作設定不受影響。
    @discardableResult
    func prepareSingleModelTopologyForSelectedThread() -> Bool {
        guard activeLoopsConfig != nil else { return true }
        setCollaborationLevel(.off)
        guard activeLoopsConfig == nil else {
            if Self.normalizedNonEmpty(selectedWorkOSStateMessage) == nil {
                selectedWorkOSStateMessage =
                    "單模型拓撲未能套用：Ultrawork 協作設定仍留在這個 session。"
            }
            return false
        }
        return true
    }

    /// A Plan confirmation is a new authority revision, not permission to
    /// dispatch under the planning-only Goal that produced the artifact.
    ///
    /// Reuse the existing durable binding-invalidation and pristine
    /// supersession path. The predecessor remains as audit evidence, the exact
    /// current-session pointer is cleared, and the next contract issuance
    /// installs the execution objective as the successor binding.
    @discardableResult
    func prepareConfirmedPlanGoalRevisionIfNeeded(
        executionObjective: String,
        forceSingleModel: Bool
    ) -> Bool {
        guard let location = selectedThreadLocation(),
              var thread = selectedThread
        else {
            selectedWorkOSStateMessage =
                "Plan 確認未送交：找不到目前 thread。"
            return false
        }
        let contractID = Self.normalizedNonEmpty(thread.workOSContractID)
        let goalID = Self.normalizedNonEmpty(thread.workOSGoalID)
        guard contractID != nil || goalID != nil else { return true }
        guard let contractID, let goalID else {
            quarantineSelectedWorkOSState(
                "Plan 確認已停止：舊 Goal／Contract 綁定不完整。")
            return false
        }

        do {
            let predecessor = try goalRunStore.requireIssuedContract(
                contractID)
            let replacement = selectedThreadWorkOSContext(
                thread: thread,
                objectiveHint: executionObjective,
                forceSingleModel: forceSingleModel)
            if predecessor.goalID == goalID,
               TatwoObjectiveIdentity.make(predecessor.objective)
                .objectiveHash == replacement.objectiveHash
            {
                return true
            }

            let desiredLoopsConfig = thread.loopsConfig
            let intent = makeWorkOSBindingMutationIntent(
                for: thread,
                at: location,
                oldContractID: contractID,
                oldGoalID: goalID,
                desiredLoopsConfig: desiredLoopsConfig)
            do {
                try workOSBindingMutationIntentStore.create(intent)
                let invalidation = try makeThreadBindingInvalidation(
                    id: intent.id,
                    reason: desiredLoopsConfig == nil
                        ? .contractSuperseded
                        : .loopsConfigChanged,
                    for: thread,
                    at: location,
                    oldContractID: contractID,
                    oldGoalID: goalID,
                    desiredLoopsConfig: desiredLoopsConfig)
                guard persistThreadBindingInvalidation(
                    invalidation,
                    for: &thread,
                    at: location)
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try supersedePristineCurrentGoalBinding(
                    for: thread,
                    expectedContractID: contractID)
            } catch {
                discardWorkOSBindingMutationIntentIfUncommitted(intent)
                rollbackUncommittedThreadBindingInvalidation(
                    for: &thread,
                    at: location)
                selectedWorkOSStateMessage = supersessionFailureMessage(
                    prefix: "Plan 確認未送交",
                    error: error)
                return false
            }

            invalidatePendingRemoteTargetForSelectedSession()
            thread.workOSGoalID = nil
            thread.workOSContractID = nil
            thread.selectedThreadWorkOSContext = nil
            thread.activePLGRunProjection = nil
            thread.updatedAt = Date()
            replaceThread(thread, at: location)
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .none
            guard publishDocumentChangeAndPersist() else {
                workOSBindingPersistencePending = true
                selectedWorkOSStateMessage =
                    "舊 Plan Goal 已安全取消，但 successor 綁定尚未寫入；未啟動 runner。"
                return false
            }
            finishWorkOSBindingMutationIntent(intent)
            guard !workOSBindingMutationRecoveryBlocked else {
                return false
            }
            selectedWorkOSStateMessage =
                "舊 planning-only Goal 已失效；正在建立確認後的 execution revision。"
            return true
        } catch {
            selectedWorkOSStateMessage =
                "Plan 確認未送交："
                + TatwoPrivacyRedactor.redacted(error.localizedDescription)
            return false
        }
    }

    func clearSelectedThreadCollaboration() {
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        var bindingMutationIntent: WorkOSBindingMutationIntentV1?
        let boundContractID = Self.normalizedNonEmpty(thread.workOSContractID)
        let boundGoalID = Self.normalizedNonEmpty(thread.workOSGoalID)
        if boundContractID != nil || boundGoalID != nil {
            guard let contractID = boundContractID,
                  let goalID = boundGoalID
            else {
                selectedWorkOSStateMessage =
                    "Chat 協作無法關閉：舊 Goal／Contract 綁定不完整，已保留原設定。"
                return
            }
            let intent = makeWorkOSBindingMutationIntent(
                for: thread,
                at: location,
                oldContractID: contractID,
                oldGoalID: goalID,
                desiredLoopsConfig: nil)
            do {
                try workOSBindingMutationIntentStore.create(intent)
                bindingMutationIntent = intent
                let invalidation = try makeThreadBindingInvalidation(
                    id: intent.id,
                    reason: .contractSuperseded,
                    for: thread,
                    at: location,
                    oldContractID: contractID,
                    oldGoalID: goalID,
                    desiredLoopsConfig: nil)
                guard persistThreadBindingInvalidation(
                    invalidation,
                    for: &thread,
                    at: location)
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try supersedePristineCurrentGoalBinding(
                    for: thread,
                    expectedContractID: contractID)
            } catch {
                discardWorkOSBindingMutationIntentIfUncommitted(intent)
                rollbackUncommittedThreadBindingInvalidation(
                    for: &thread,
                    at: location)
                selectedWorkOSStateMessage = supersessionFailureMessage(
                    prefix: "Chat 協作無法關閉",
                    error: error)
                return
            }
        }
        invalidatePendingRemoteTargetForSelectedSession()
        thread.loopsConfig = nil
        thread.workOSGoalID = nil
        thread.workOSContractID = nil
        thread.selectedThreadWorkOSContext = nil
        thread.activePLGRunProjection = nil
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        selectedWorkOSContract = nil
        selectedGoalRecord = nil
        selectedDispatchRecords = []
        activePLGRun = nil
        appliedPLGEventIDs = []
        plgAuthorityState = .none
        let persisted = publishDocumentChangeAndPersist()
        if persisted {
            finishWorkOSBindingMutationIntent(bindingMutationIntent)
            selectedWorkOSStateMessage = "Chat 協作已關閉"
        } else {
            workOSBindingPersistencePending = true
            selectedWorkOSStateMessage =
                "Chat 協作已在目前視窗關閉，但尚未安全寫入磁碟；已停止建立新 Goal，並會自動重試儲存。"
        }
    }

    func makeWorkOSBindingMutationIntent(
        for thread: TatwoNativeChatThread,
        at location: ThreadLocation,
        oldContractID: String,
        oldGoalID: String,
        desiredLoopsConfig: TatwoNativeThreadLoopsConfig?
    ) -> WorkOSBindingMutationIntentV1 {
        let projectID: UUID?
        switch location {
        case .standalone:
            projectID = nil
        case .project(let projectIndex, _):
            projectID = document.projects[projectIndex].id
        }
        return WorkOSBindingMutationIntentV1(
            threadID: thread.id,
            projectID: projectID,
            oldContractID: oldContractID,
            oldGoalID: oldGoalID,
            desiredLoopsConfig: desiredLoopsConfig)
    }

    func makeThreadBindingInvalidation(
        id: UUID = UUID(),
        reason: TatwoNativeThreadBindingInvalidationReasonV1,
        for thread: TatwoNativeChatThread,
        at location: ThreadLocation,
        oldContractID: String,
        oldGoalID: String,
        desiredLoopsConfig: TatwoNativeThreadLoopsConfig?,
        expectedSuccessor:
            TatwoNativeThreadBindingIdentityV1? = nil
    ) throws -> TatwoNativeThreadBindingInvalidationV1 {
        let goal = try goalRunStore.requireIssuedContract(oldContractID)
        guard goal.goalID == oldGoalID else {
            throw TatwoSessionAttachmentError.pointerGoalRunMismatch(
                "binding_invalidation")
        }
        let projectID = projectID(for: location)
        let pointerGeneration: UInt64?
        if reason == .goalRevisionChanged {
            pointerGeneration = goal.supersession?.oldPointerGeneration
        } else if let bundle = verifiedCurrentSessionBundle,
                  bundle.contract.contractID == oldContractID,
                  bundle.contract.goalID == oldGoalID {
            pointerGeneration = bundle.pointer.generation ?? 1
        } else {
            pointerGeneration = nil
        }
        return TatwoNativeThreadBindingInvalidationV1(
            id: id,
            reason: reason,
            threadID: thread.id,
            projectID: projectID,
            previousBinding: TatwoNativeThreadBindingIdentityV1(
                contractID: oldContractID,
                goalID: oldGoalID,
                goalRevision: goal.resolvedRevision),
            previousPointerGeneration: pointerGeneration,
            previousLoopsConfig: thread.loopsConfig,
            desiredLoopsConfig: desiredLoopsConfig,
            expectedSuccessor: expectedSuccessor,
            authorityProvenance: bindingAuthorityProvenance(
                for: thread,
                projectID: projectID))
    }

    func projectID(for location: ThreadLocation) -> UUID? {
        switch location {
        case .standalone:
            return nil
        case .project(let projectIndex, _):
            return document.projects[projectIndex].id
        }
    }

    func bindingAuthorityProvenance(
        for thread: TatwoNativeChatThread,
        projectID: UUID?
    ) -> TatwoNativeThreadBindingAuthorityProvenanceV1? {
        guard let owner = currentSessionCanonicalOwner(
            for: thread,
            projectID: projectID)
        else { return nil }
        return TatwoNativeThreadBindingAuthorityProvenanceV1(
            provider: owner.provider,
            externalProviderSessionID:
                owner.externalProviderID,
            workspacePath: owner.workspacePath)
    }

    @discardableResult
    func persistThreadBindingInvalidation(
        _ invalidation: TatwoNativeThreadBindingInvalidationV1,
        for thread: inout TatwoNativeChatThread,
        at location: ThreadLocation
    ) -> Bool {
        let original = thread
        thread.bindingInvalidation = invalidation
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        guard publishDocumentChangeAndPersist() else {
            thread = original
            replaceThread(original, at: location)
            return false
        }
        return true
    }

    func rollbackUncommittedThreadBindingInvalidation(
        for thread: inout TatwoNativeChatThread,
        at location: ThreadLocation
    ) {
        guard let invalidation = thread.bindingInvalidation,
              let goal = try? goalRunStore.requireIssuedContract(
                invalidation.previousBinding.contractID),
              goal.goalID == invalidation.previousBinding.goalID,
              goal.status == .planned,
              goal.statusReason == nil
        else { return }
        let original = thread
        thread.bindingInvalidation = nil
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        guard publishDocumentChangeAndPersist() else {
            thread = original
            replaceThread(original, at: location)
            workOSBindingMutationRecoveryBlocked = true
            selectedWorkOSStateMessage =
                "Work OS 綁定失效標記無法安全回滾；已停止建立新 Goal。"
            return
        }
    }

    func discardWorkOSBindingMutationIntentIfUncommitted(
        _ intent: WorkOSBindingMutationIntentV1
    ) {
        guard let goal = try? goalRunStore.requireIssuedContract(
            intent.oldContractID),
              Self.workOSBindingMutationPredecessorIsExactlyPlanned(
                goal,
                for: intent)
        else { return }
        try? workOSBindingMutationIntentStore.remove(intent)
    }

    func finishWorkOSBindingMutationIntent(
        _ intent: WorkOSBindingMutationIntentV1?
    ) {
        guard let intent else { return }
        let isCachedRecoveryIntent =
            workOSBindingMutationRecoveryIntent == intent
        do {
            guard try Self.workOSBindingMutationIntentIsApplied(
                intent,
                in: try store.load())
                || Self.workOSBindingMutationIntentIsRetargetSuperseded(
                    intent,
                    in: try store.load())
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try workOSBindingMutationIntentStore.remove(intent)
            clearWorkOSBindingMutationRecoveryCache(ifMatching: intent)
        } catch {
            // A retry for another row must not replace this selected row's
            // cached blocker. Only the exact blocked intent may update the
            // recovery cache; otherwise the footer would incorrectly become
            // neutral merely because an unrelated cleanup was attempted.
            if isCachedRecoveryIntent
                || workOSBindingMutationRecoveryIntent == nil
            {
                workOSBindingMutationRecoveryBlocked = true
                workOSBindingMutationRecoveryIntent = intent
            }
            selectedWorkOSStateMessage =
                "Chat 綁定已寫入，但 durable mutation intent 尚未完成清理；已停止建立新 Goal。"
        }
    }

    private func clearWorkOSBindingMutationRecoveryCache(
        ifMatching completedIntent: WorkOSBindingMutationIntentV1
    ) {
        guard workOSBindingMutationRecoveryIntent == completedIntent else {
            return
        }
        workOSBindingMutationRecoveryIntent = nil
        workOSBindingMutationRecoveryBlocked = false
    }

    func supersedePristineCurrentGoalBinding(
        for thread: TatwoNativeChatThread,
        expectedContractID contractID: String
    ) throws {
        guard let goalID = Self.normalizedNonEmpty(thread.workOSGoalID) else {
            throw TatwoSessionAttachmentError.callerExpectationMismatch(
                "goalID")
        }
        let goalRecord = try goalRunStore.requireIssuedContract(contractID)
        let sessionStore = TatwoSessionStore(
            directoryURL: goalRunStore.directoryURL)
        guard let pointer = try sessionStore.current() else {
            throw TatwoSessionMutationError.noCurrentSession
        }
        let ownerVerification = currentSessionOwnerVerification(
            for: thread,
            projectID: selectedProjectID,
            pointerSchema: pointer.schema)
        do {
            _ = try sessionStore.supersedePristinePlannedCurrent(
                ownerVerification: ownerVerification,
                expectedContractID: contractID,
                expectedGoalID: goalID,
                expectedMode: goalRecord.mode,
                expectedScenario: goalRecord.scenario,
                expectedObjective: goalRecord.objective,
                scenarioBook: scenarioConfigBook,
                goalStore: goalRunStore)
        } catch let error as TatwoSessionMutationError
            where error == .currentSessionSupersededPointerCleanupRequired
        {
            do {
                guard try sessionStore.reconcileSupersededTerminalCurrent(
                    ownerVerification: ownerVerification,
                    expectedContractID: contractID,
                    expectedGoalID: goalID,
                    expectedMode: goalRecord.mode,
                    expectedScenario: goalRecord.scenario,
                    expectedObjective: goalRecord.objective,
                    scenarioBook: scenarioConfigBook,
                    goalStore: goalRunStore) != nil
                else {
                    throw TatwoSessionMutationError
                        .currentSessionSupersededPointerCleanupRequired
                }
            } catch {
                throw TatwoSessionMutationError
                    .currentSessionSupersededPointerCleanupRequired
            }
        }
        currentSessionPointerPresent = false
        verifiedCurrentSessionBundle = nil
    }

    func supersessionFailureMessage(
        prefix: String,
        error: Error
    ) -> String {
        if error as? TatwoSessionMutationError
            == .currentSessionSupersededPointerCleanupRequired
        {
            return "\(prefix)：舊 Goal 已取消，但 terminal pointer 尚未完成精準清理；未建立替代 Goal。"
        }
        return "\(prefix)：舊 Goal 已開始工作、已有派工證據或 current-session 已改變，已保留原設定。"
    }

    /// 結束目標（人類主動）：先關閉 canonical GoalRun，再以 exact revision
    /// compare-and-clear current-session pointer；兩者都完成後才解除本地 UI 綁定。
    func endActiveGoal() {
        guard let location = selectedThreadLocation() else { return }
        let boundThread = thread(at: location)
        guard let contractID = Self.normalizedNonEmpty(
                boundThread.workOSContractID
                    ?? selectedWorkOSContract?.contractID
                    ?? selectedGoalRecord?.contractID),
              let goalID = Self.normalizedNonEmpty(
                boundThread.workOSGoalID
                    ?? selectedWorkOSContract?.goalID
                    ?? selectedGoalRecord?.goalID)
        else { return }

        do {
            let goalRecord = try goalRunStore.requireIssuedContract(contractID)
            guard goalRecord.goalID == goalID,
                  selectedWorkOSContract?.contractID == nil
                    || selectedWorkOSContract?.contractID == contractID,
                  selectedWorkOSContract?.goalID == nil
                    || selectedWorkOSContract?.goalID == goalID,
                  selectedGoalRecord?.contractID == nil
                    || selectedGoalRecord?.contractID == contractID,
                  selectedGoalRecord?.goalID == nil
                    || selectedGoalRecord?.goalID == goalID
            else {
                throw TatwoSessionAttachmentError.pointerGoalRunMismatch(
                    "selected_thread")
            }

            let sessionStore = TatwoSessionStore(
                directoryURL: goalRunStore.directoryURL)
            if goalRecord.mode == .s,
               goalRecord.status == .awaitingNextCycle
            {
                let evidenceID =
                    transcriptMessages.last(where: {
                        $0.role == .assistant
                            && $0.status == "done"
                    })?.id
                    ?? "goal-\(goalID)"
                convergeSingleModelCompletedCycleIfNeeded(
                    contractID: contractID,
                    evidenceID: evidenceID)
            }
            // `closeGoal` 本身就是 Goal Judge：receipts 足夠時它會把 GoalRun
            // 持久化成 `.passed`。判定「尚未收斂」必須看關閉後 store 的實際
            // 狀態，而不是「關閉前不是 terminal」——否則一次成功的關閉會被當成
            // 失敗提早返回，pointer／pending target／thread 綁定全部留在原地。
            var terminalGoal = try goalRunStore.requireIssuedContract(contractID)
            if terminalGoal.status != .passed,
               terminalGoal.status != .rollbackRequired
            {
                let closeResult = try WorkOSFactory.closeGoal(
                    goalID: goalID,
                    contractID: contractID,
                    mode: terminalGoal.mode,
                    scenarioProfileID: terminalGoal.scenario,
                    objective: terminalGoal.objective,
                    suppliedReceiptIDs: [],
                    store: goalRunStore,
                    dispatchRegistry: dispatchRegistry)
                // receipts 不足時 closeGoal 會回報 `.rollbackRequired` 但刻意
                // 不落盤（fail-closed，保留 run 可續跑），所以只信 store。
                let closedGoal = try goalRunStore.requireIssuedContract(contractID)
                guard closedGoal.goalID == goalID,
                      closedGoal.status == .passed
                        || closedGoal.status == .rollbackRequired
                else {
                    if closeResult.status == .blocked {
                        selectedWorkOSStateMessage =
                            closeResult.decision.message
                            + " 修復後可按「結束目標」重試。"
                        flashComposerHint(closeResult.decision.message)
                        return
                    }
                    let missing = closeResult.missingReceiptIDs
                    flashComposerHint(
                        missing.isEmpty
                            ? "Goal Judge 尚未收斂：必要 receipts 不足。"
                            : "Goal Judge 尚未收斂，缺少："
                                + missing.joined(separator: "、"))
                    refreshSelectedWorkOSState(contractID: contractID)
                    return
                }
                terminalGoal = closedGoal
            }
            let pointerSchema =
                try sessionStore.snapshotCurrent()?.pointer.schema
            let ownerVerification = pointerSchema.flatMap {
                currentSessionOwnerVerification(
                    for: boundThread,
                    projectID: selectedProjectID,
                    pointerSchema: $0)
            }
            let closedStatus: GoalRunStatus
            if let terminalAttachment = try sessionStore.closeAndClearCurrent(
                ownerVerification: ownerVerification,
                expectedContractID: contractID,
                expectedGoalID: goalID,
                expectedMode: terminalGoal.mode,
                expectedScenario: terminalGoal.scenario,
                expectedObjective: terminalGoal.objective,
                goalStore: goalRunStore)
            {
                closedStatus = terminalAttachment.goalRecord.status
            } else {
                // No current pointer exists, so there is no pointer mutation to
                // race. Close and verify only the already-bound canonical GoalRun.
                switch terminalGoal.status {
                case .failed, .cancelled, .passed, .rollbackRequired:
                    closedStatus = terminalGoal.status
                case .superseded:
                    throw TatwoSessionMutationError.currentSessionStopDenied(
                        .superseded)
                case .planned, .dispatching, .running, .succeeded,
                     .humanGate, .awaitingNextCycle, .blocked:
                    let result = try WorkOSFactory.closeGoal(
                        goalID: goalID,
                        contractID: contractID,
                        mode: terminalGoal.mode,
                        scenarioProfileID: terminalGoal.scenario,
                        objective: terminalGoal.objective,
                        suppliedReceiptIDs: [],
                        store: goalRunStore,
                        dispatchRegistry: dispatchRegistry)
                    if result.status == .blocked {
                        selectedWorkOSStateMessage =
                            result.decision.message
                            + " 修復後可按「結束目標」重試。"
                        flashComposerHint(result.decision.message)
                        return
                    }
                    guard result.status == .passed
                            || result.status == .rollbackRequired
                    else {
                        throw TatwoGoalRunStoreError.illegalStatusTransition(
                            from: terminalGoal.status,
                            to: result.status,
                            authority: "chat_end_goal")
                    }
                    closedStatus = result.status
                }
            }

            invalidatePendingRemoteTargetForSelectedSession()
            var detachedThread = thread(at: location)
            detachedThread.workOSGoalID = nil
            detachedThread.workOSContractID = nil
            detachedThread.selectedThreadWorkOSContext = nil
            detachedThread.activePLGRunProjection = nil
            detachedThread.updatedAt = Date()
            replaceThread(detachedThread, at: location)
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .none
            activeGoalPaused = false
            currentSessionPointerPresent = false
            verifiedCurrentSessionBundle = nil
            selectedWorkOSStateMessage = closedStatus == .rollbackRequired
                ? "目標已結束並標記需回滾；普通 Chat 不會自動建立 Goal，請用 /goal 或 /plg 啟動下一個"
                : "目標已結束；普通 Chat 不會自動建立 Goal，請用 /goal 或 /plg 啟動下一個"
            publishDocumentChangeAndPersist()
        } catch {
            if let refreshed = try? goalRunStore.requireIssuedContract(contractID) {
                selectedGoalRecord = refreshed
                selectedWorkOSContract = try? WorkOSFactory.storedContractProjection(
                    contractID: refreshed.contractID,
                    fallbackMode: refreshed.mode,
                    fallbackScenarioProfileID: refreshed.scenario,
                    fallbackObjective: refreshed.objective,
                    store: goalRunStore)
            }
            let detail = TatwoPrivacyRedactor.redacted(error.localizedDescription)
            selectedWorkOSStateMessage =
                "目標結束未完成；為避免清錯 Session，已保留原綁定：\(detail)"
            flashComposerHint("目標結束未完成；原綁定已保留。")
        }
    }

    /// 暫停/續跑目標（人類主動）：UI 層標記，暫停時提示不再自動推進。
    func toggleActiveGoalPause() {
        guard selectedWorkOSContract != nil || selectedGoalRecord != nil else { return }
        if activeGoalPaused, !canResumeActiveGoal {
            selectedWorkOSStateMessage = selectedRouteCooldownStatusText
            flashComposerHint(selectedRouteCooldownStatusText)
            return
        }
        activeGoalPaused.toggle()
        selectedWorkOSStateMessage = activeGoalPaused ? "目標已暫停" : "目標已續跑"
    }

    func updateSelectedThreadWorkOSMetadata(
        goalID: String,
        contractID: String,
        objectiveIdentity: TatwoObjectiveIdentity
    ) -> Bool {
        guard let location = selectedThreadLocation() else { return false }
        var thread = thread(at: location)
        if thread.bindingInvalidation != nil {
            guard let bundle = verifiedCurrentSessionBundle,
                  bundle.contract.contractID == contractID,
                  bundle.contract.goalID == goalID,
                  prepareBindingInvalidationForExactSuccessor(
                    thread: &thread,
                    at: location,
                    projectID: projectID(for: location),
                    bundle: bundle),
                  refreshVerifiedCurrentSessionBundleFromDisk(
                    ownerVerification: currentSessionOwnerVerification(
                        for: thread,
                        projectID: projectID(for: location),
                        pointerSchema: bundle.pointer.schema)),
                  let refreshed = verifiedCurrentSessionBundle,
                  exactBindingIdentity(refreshed)
                    == exactBindingIdentity(bundle),
                  threadHasExactBindingInvalidation(
                    thread,
                    projectID: projectID(for: location),
                    bundle: refreshed)
            else { return false }
        }
        let original = thread
        thread.workOSGoalID = goalID
        thread.workOSContractID = contractID
        thread.selectedThreadWorkOSContext = TatwoStoredObjectiveContextV2(
            identity: objectiveIdentity)
        if thread.activePLGRunProjection?.contractID != contractID {
            thread.activePLGRunProjection = nil
            activePLGRun = nil
            appliedPLGEventIDs = []
            plgAuthorityState = .none
        }
        thread.bindingInvalidation = nil
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        guard publishDocumentChangeAndPersist() else {
            replaceThread(original, at: location)
            return false
        }
        return true
    }

    func updateSelectedThreadPluginIDs(_ ids: [String]) {
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        thread.threadPluginIDs = ids.isEmpty ? nil : ids
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        publishDocumentChangeAndPersist()
    }

    func selectedThreadWorkOSContext(
        thread: TatwoNativeChatThread,
        objectiveHint: String? = nil,
        forceSingleModel: Bool = false
    ) -> ChatWorkOSContext {
        let config = forceSingleModel
            ? nil
            : thread.loopsConfig
                ?? selectedCoworkTemplate.map { loopsConfig(for: $0) }
        let mode = forceSingleModel ? .s : (config?.mode ?? .m)
        let scenario = config?.scenarioID ?? "coding"
        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let readableTitle = title.isEmpty ? "未命名 thread" : title
        let hint = objectiveHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(thread.id.uuidString.prefix(8)).lowercased()
        let rawObjective: String
        if let hint, !hint.isEmpty {
            rawObjective = "Tatwo Chat request: \(hint) [\(prefix)]"
        } else {
            let storedUserRequest = thread.messages?.first(where: {
                $0.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user"
            })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let storedUserRequest, !storedUserRequest.isEmpty {
                rawObjective = "Tatwo Chat request: \(storedUserRequest) [\(prefix)]"
            } else {
                rawObjective = "Tatwo Chat thread: \(readableTitle) [\(prefix)]"
            }
        }
        let objectiveIdentity = TatwoObjectiveIdentity.make(
            TatwoPrivacyRedactor.redacted(rawObjective))
        let objectiveHash = objectiveIdentity.objectiveHash
        let preview = objectiveIdentity.preview
        return ChatWorkOSContext(
            mode: mode,
            scenario: scenario,
            objectiveIdentity: objectiveIdentity,
            objectiveHash: objectiveHash,
            preview: preview)
    }

    func refreshSelectedWorkOSState(
        contractID: String,
        afterDispatchRead: (@Sendable (TatwoGoalRunSnapshotV1) -> Void)? = nil
    ) {
        selectedWorkOSStateLoadTask?.cancel()
        let loadGeneration = UUID()
        selectedWorkOSStateLoadGeneration = loadGeneration
        guard let thread = selectedThread else { return }
        if isSelectedCodexProjectMirror() {
            guard let bundle = verifiedCurrentSessionBundle,
                  verifiedCurrentSessionBundleIsCanonical(bundle),
                  bundle.contract.contractID == contractID,
                  thread.workOSGoalID == bundle.contract.goalID
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：project mirror 不得從 stale row-local contract 載入狀態。")
                return
            }
        }
        let selectedThreadID = thread.id
        let scenarioConfigBook = self.scenarioConfigBook
        let goalRunStore = self.goalRunStore
        let dispatchRegistry = self.dispatchRegistry
        selectedWorkOSStateMessage = "Work OS contract 載入中"
        selectedWorkOSStateLoadTask = Task { @MainActor [weak self] in
            let payload = await Task.detached(priority: .utility) {
                do {
                    let snapshot = try goalRunStore.snapshot(
                        forContractID: contractID)
                    let contract = try WorkOSFactory.storedContractProjection(
                        snapshot: snapshot,
                        scenarioBook: scenarioConfigBook,
                        store: goalRunStore)
                    let dispatchRecords =
                        try dispatchRegistry.latestRecordsByBinding(
                            forContractID: contract.contractID)
                    afterDispatchRead?(snapshot)
                    guard try goalRunStore.verifyCurrent(snapshot) else {
                        return ChatWorkOSStateLoadPayload(
                            contract: nil,
                            goalRecord: nil,
                            goalSnapshot: nil,
                            dispatchRecords: [],
                            message:
                                "Work OS continuity 已隔離：GoalRun revision 在 dispatch ledger 讀取期間改變，未套用混合狀態。")
                    }
                    return ChatWorkOSStateLoadPayload(
                        contract: contract,
                        goalRecord: snapshot.record,
                        goalSnapshot: snapshot,
                        dispatchRecords: dispatchRecords,
                        message: "Work OS contract 已連線")
                } catch {
                    return ChatWorkOSStateLoadPayload(
                        contract: nil,
                        goalRecord: nil,
                        goalSnapshot: nil,
                        dispatchRecords: [],
                        message:
                            "Work OS continuity 已隔離：GoalRun／dispatch ledger 無法驗證，未以空清單取代。")
                }
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.selectedWorkOSStateLoadGeneration == loadGeneration,
                  self.selectedThreadID == selectedThreadID,
                  self.selectedThread?.workOSContractID?.trimmingCharacters(in: .whitespacesAndNewlines) == contractID,
                  !self.isSelectedCodexProjectMirror()
                    || (
                        self.verifiedCurrentSessionBundle.map {
                            self.verifiedCurrentSessionBundleIsCanonical($0)
                                && $0.contract.contractID == contractID
                                && $0.contract.goalID
                                    == self.selectedThread?.workOSGoalID
                        } == true
                    )
            else { return }
            guard let snapshot = payload.goalSnapshot,
                  payload.contract != nil,
                  payload.goalRecord != nil
            else {
                self.quarantineSelectedWorkOSState(payload.message)
                return
            }
            let snapshotIsStillCurrent = await Task.detached(priority: .utility) {
                (try? goalRunStore.verifyCurrent(snapshot)) == true
            }.value
            guard !Task.isCancelled,
                  self.selectedWorkOSStateLoadGeneration == loadGeneration,
                  self.selectedThreadID == selectedThreadID,
                  self.selectedThread?.workOSContractID?.trimmingCharacters(in: .whitespacesAndNewlines) == contractID,
                  !self.isSelectedCodexProjectMirror()
                    || (
                        self.verifiedCurrentSessionBundle.map {
                            self.verifiedCurrentSessionBundleIsCanonical($0)
                                && $0.contract.contractID == contractID
                                && $0.contract.goalID
                                    == self.selectedThread?.workOSGoalID
                        } == true
                    )
            else { return }
            guard snapshotIsStillCurrent else {
                self.quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：GoalRun revision 在 MainActor 套用前改變，未套用 stale 狀態。")
                return
            }
            self.selectedWorkOSContract = payload.contract
            self.selectedGoalRecord = payload.goalRecord
            self.selectedDispatchRecords = payload.dispatchRecords
            self.selectedWorkOSStateMessage = payload.message
            if payload.goalRecord?.mode == .s,
               payload.goalRecord?.status == .awaitingNextCycle,
               payload.goalRecord?.statusReason?.hasPrefix(
                "dispatch_cycle_finalized:") == true
            {
                _ = self.convergeSingleModelCompletedCycleIfNeeded(
                    contractID: contractID)
                if let refreshed = try? self.goalRunStore.requireIssuedContract(
                    contractID)
                {
                    self.selectedGoalRecord = refreshed
                    if let refreshedContract =
                        try? WorkOSFactory.storedContractProjection(
                            contractID: contractID,
                            fallbackMode: refreshed.mode,
                            fallbackScenarioProfileID: refreshed.scenario,
                            fallbackObjective: refreshed.objective,
                            scenarioBook: self.scenarioConfigBook,
                            store: self.goalRunStore)
                    {
                        self.selectedWorkOSContract = refreshedContract
                    }
                }
            }
            if let existingBundle = self.verifiedCurrentSessionBundle,
               let refreshedContract = payload.contract,
               let refreshedGoalRecord = payload.goalRecord,
               existingBundle.pointer.contractID == refreshedContract.contractID,
               existingBundle.pointer.goalID == refreshedContract.goalID
            {
                self.verifiedCurrentSessionBundle =
                    ChatVerifiedCurrentSessionBundle(
                        pointer: existingBundle.pointer,
                        contract: refreshedContract,
                        goalRecord: refreshedGoalRecord)
            }
            self.refreshActivePLGDomainProjection()
        }
    }

    /// Active Goal cards remain visible while CLI/MCP writers finalize the same
    /// canonical contract. Poll that ledger on a bounded cadence so the selected
    /// thread converges without a thread switch or App restart.
    func refreshSelectedWorkOSStateForExternalChanges(
        now: Date = Date(),
        force: Bool = false
    ) {
        guard shouldShowActiveGoalInlineCard,
              let contractID =
                selectedWorkOSContract?.contractID
                ?? selectedThread?.workOSContractID,
              !contractID.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
        else { return }
        if !force,
           let lastSelectedWorkOSAutoRefreshAt,
           now.timeIntervalSince(lastSelectedWorkOSAutoRefreshAt)
            < Self.selectedWorkOSAutoRefreshInterval
        {
            return
        }
        lastSelectedWorkOSAutoRefreshAt = now
        refreshSelectedWorkOSState(contractID: contractID)
    }

    func syncSessionIDFromSelection() {
        let handle = selectedProviderSessionID(
            adapter: routeChoice.runtimeAdapter,
            modelID: routeChoice.id)
        switch routeChoice.engine {
        case .codex:
            codexSessionID = TatwoChatCommandPlanner.sanitizedCodexResumeSessionID(handle)
        case .claude:
            claudeSessionID = TatwoChatCommandPlanner.sanitizedClaudeResumeSessionID(handle)
        }
    }

    private func selectedProviderSessionID(
        adapter: TatwoChatRuntimeAdapter,
        modelID: String
    ) -> String? {
        if let discussion = selectedDiscussion {
            return TatwoNativeSessionTree.providerSessionID(
                adapterID: adapter.rawValue,
                modelID: modelID,
                handles: discussion.adapterSessionHandles)
        }
        guard let thread = selectedThread else { return nil }
        if let handle = TatwoNativeSessionTree.providerSessionID(
            adapterID: adapter.rawValue,
            modelID: modelID,
            handles: thread.adapterSessionHandles) {
            return handle
        }
        switch adapter {
        case .codexExec:
            return Self.codexCLIResumeSessionID(from: thread)
        case .claudeCLI:
            return thread.claudeSessionID
        case .grokCLI, .minimaxDirect, .nativeAgent,
             .gatewayDirect, .unavailable:
            return nil
        }
    }

    private func selectedGatewayConversationHandle(
        modelID: String
    ) -> TatwoGatewayConversationHandleV1? {
        guard let threadID = selectedThreadID?
            .uuidString.lowercased()
        else { return nil }
        let discussionID = selectedDiscussionID?
            .uuidString.lowercased()
        if let discussion = selectedDiscussion {
            return TatwoNativeSessionTree.gatewayConversationHandle(
                threadID: threadID,
                discussionID: discussionID,
                adapterID: TatwoChatRuntimeAdapter.gatewayDirect.rawValue,
                modelID: modelID,
                handles: discussion.gatewayConversationHandles)
        }
        guard let thread = selectedThread else { return nil }
        return TatwoNativeSessionTree.gatewayConversationHandle(
            threadID: threadID,
            discussionID: nil,
            adapterID: TatwoChatRuntimeAdapter.gatewayDirect.rawValue,
            modelID: modelID,
            handles: thread.gatewayConversationHandles)
    }

    private func gatewayContinuationRequest(
        route: ChatRouteChoice,
        runtimeAdapter: TatwoChatRuntimeAdapter,
        context: String
    ) -> TatwoGatewayContinuationRequestV1? {
        guard runtimeAdapter == .gatewayDirect,
              let threadID = selectedThreadID?
                .uuidString.lowercased()
        else { return nil }
        let discussionID = selectedDiscussionID?
            .uuidString.lowercased()
        let handle = selectedGatewayConversationHandle(
            modelID: route.canonicalModelSlug)
        let request = TatwoGatewayContinuationRequestV1(
            mode: handle == nil ? .none : .providerResume,
            threadID: threadID,
            discussionID: discussionID,
            runtimeAdapterID: runtimeAdapter.rawValue,
            canonicalModelID: route.canonicalModelSlug,
            previousResponseHandle: handle?.opaqueResponseHandle,
            previousGatewayInstanceID: handle?.gatewayInstanceID,
            contextSHA256: TatwoArtifactReviewHasher.sha256(context))
        return request.isValid ? request : nil
    }

    private static func codexCLIResumeSessionID(from thread: TatwoNativeChatThread?) -> String? {
        if let cliID = TatwoChatCommandPlanner.sanitizedCodexResumeSessionID(thread?.codexCLISessionID) {
            return cliID
        }
        guard let thread else { return nil }
        // Threads imported from Codex App use the Codex desktop thread id as
        // `codexSessionID` so the left rail and transcript mirror can stay
        // aligned.  That id is source metadata, not automatically a safe
        // `codex exec resume` target for Tatwo Chat: in live smoke it can
        // stall or drag the huge desktop context into a tiny Chat turn.  Only
        // use `codexSessionID` as a CLI resume id for local Tatwo-created
        // threads; Codex App mirror ids stay available for transcript import.
        guard !isCodexAppMirrorThread(thread) else { return nil }
        return TatwoChatCommandPlanner.sanitizedCodexResumeSessionID(thread.codexSessionID)
    }

    nonisolated static func isCodexAppMirrorThread(
        _ thread: TatwoNativeChatThread
    ) -> Bool {
        guard let codexID = normalizedNonEmpty(thread.codexSessionID) else { return false }
        return thread.id.uuidString.lowercased() == codexID.lowercased()
    }

    static func persistableSessionID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("tatwo-gateway-") { return nil }
        return trimmed
    }

    func composedTurn(route: ChatRouteChoice) -> String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeEngine = route.engine
        switch routeEngine {
        case .codex:
            let nonImagePaths = droppedPaths.filter { !Self.isLikelyImagePath($0) }
            guard !nonImagePaths.isEmpty else { return text }
            let attachmentText = nonImagePaths.map { "- \($0)" }.joined(separator: "\n")
            text += "\n\n[Dragged file paths]\n\(attachmentText)"
        case .claude:
            let nonImagePaths = droppedPaths.filter { !Self.isLikelyImagePath($0) }
            guard !nonImagePaths.isEmpty else { return text }
            text += "\n\n[Dragged file paths]\n" + nonImagePaths.map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }

    func turnWithThreadTranscriptContext(
        _ currentTurn: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot
    ) -> String {
        turnWithThreadTranscriptContext(
            currentTurn,
            transcriptMessages: messages.map(\.storedRecord),
            dispatchSnapshot: dispatchSnapshot)
    }

    func turnWithThreadTranscriptContext(
        _ currentTurn: String,
        transcriptMessages: [TatwoNativeChatStoredMessage],
        dispatchSnapshot: ChatTurnDispatchSnapshot
    ) -> String {
        guard mode == .chat else { return currentTurn }
        let route = ChatRouteChoice.resolve(dispatchSnapshot.routeID)
        let interactionMode = currentChatInteractionMode
        let requiresTatwoComputerHost =
            dispatchSnapshot.computerHostDecision.isAuthorized
        let nativeSubscriptionPreference =
            nativeSubscriptionPreference(
                route: route,
                dispatchSnapshot: dispatchSnapshot,
                visibleTurn: currentTurn)
        let baselineRuntimeAdapter = TatwoChatCommandPlanner.runtimeAdapterForTurn(
            route: route.profile,
            interactionMode: interactionMode,
            hasImageAttachments: droppedPaths.contains(where: Self.isLikelyImagePath),
            requiresTatwoComputerHost: requiresTatwoComputerHost,
            nativeDevelopmentAccess:
                nativeDevelopmentAccess(for: currentTurn),
            preferNativeSubscription: nativeSubscriptionPreference)
        let baselineHasResumableSession = selectedProviderSessionID(
            adapter: baselineRuntimeAdapter,
            modelID: route.id) != nil
        let bridgesHistoricalImages = ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: currentTurn,
            interactionMode: interactionMode,
            targetRuntimeAdapter: baselineRuntimeAdapter,
            targetHasResumableSession: baselineHasResumableSession)
        let effectiveRuntimeAdapter = TatwoChatCommandPlanner.runtimeAdapterForTurn(
            route: route.profile,
            interactionMode: interactionMode,
            hasImageAttachments: bridgesHistoricalImages
                || droppedPaths.contains(where: Self.isLikelyImagePath),
            requiresTatwoComputerHost: requiresTatwoComputerHost,
            nativeDevelopmentAccess:
                nativeDevelopmentAccess(for: currentTurn),
            preferNativeSubscription: nativeSubscriptionPreference)
        let targetHasResumableSession: Bool
        switch effectiveRuntimeAdapter {
        case .codexExec:
            targetHasResumableSession = TatwoChatCommandPlanner.sanitizedCodexResumeSessionID(
                selectedProviderSessionID(adapter: .codexExec, modelID: route.id)) != nil
        case .claudeCLI:
            targetHasResumableSession = TatwoChatCommandPlanner.sanitizedClaudeResumeSessionID(
                selectedProviderSessionID(adapter: .claudeCLI, modelID: route.id)) != nil
        case .grokCLI:
            targetHasResumableSession = TatwoChatCommandPlanner.sanitizedGrokResumeSessionID(
                selectedProviderSessionID(adapter: .grokCLI, modelID: route.id)) != nil
        case .minimaxDirect:
            targetHasResumableSession = false
        case .gatewayDirect:
            targetHasResumableSession =
                selectedGatewayConversationHandle(
                    modelID: route.canonicalModelSlug) != nil
        case .nativeAgent, .unavailable:
            targetHasResumableSession = false
        }
        return TatwoChatThreadContextComposer.compose(
            currentTurn: currentTurn,
            messages: transcriptMessages,
            inheritedMessages: selectedDiscussion?.forkCheckpoint?.parentMessages ?? [],
            targetEngine: route.engine,
            targetRuntimeAdapter: effectiveRuntimeAdapter,
            targetHasResumableSession: targetHasResumableSession)
    }

    var currentChatInteractionMode: TatwoChatInteractionMode {
        (isPlanModeEnabled || activePLGRun?.phase == .planning) ? .plan : .standard
    }

    func currentConversationWorkspaceURL() -> URL {
        guard mode == .chat else {
            let basePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: basePath.isEmpty ? FileManager.default.currentDirectoryPath : basePath, isDirectory: true)
        }
        return resolvedRuntimeWorkspace().url
    }

    func turnWithHiddenLoopsContext(
        _ visibleTurn: String,
        computerHostDecision: ChatComputerHostTurnDecision,
        pluginDecisionContext: String? = nil,
        attachmentPaths: [String]? = nil,
        includePendingHandoff: Bool = true
    ) -> String {
        guard mode != .cli else { return visibleTurn }
        let effectiveAttachmentPaths = attachmentPaths ?? droppedPaths
        let effectivePendingHandoff =
            includePendingHandoff ? activePendingHandoff : nil
        if !computerHostDecision.isAuthorized,
           !isPlanModeEnabled,
           Self.shouldUseBareExactOutputTurn(
            visibleTurn,
            collaborationIsEnabled: collaborationIsEnabled,
            pluginDecisionContext: pluginDecisionContext,
            hasPendingHandoff: effectivePendingHandoff != nil,
            droppedPaths: effectiveAttachmentPaths
        ) {
            return visibleTurn
        }
        var sections: [String] = [
            chatInterfacePolicyContext(
                visibleTurn: visibleTurn,
                attachmentPaths: effectiveAttachmentPaths)
        ]
        if computerHostDecision.route == .embeddedIntent {
            sections.append(TatwoComputerToolIntentParser.hiddenPromptContract)
        }
        if isPlanModeEnabled {
            sections.append("""
            [Hidden Codex-style Plan mode contract — do not quote this block]
            mode=plan
            planMode=active
            continuity=沿用同一個 thread 的既有上下文；直到 /plan off 前，後續 turn 都維持只規劃。
            Do not execute commands, edit files, dispatch loops, create a GoalRun, or claim implementation.
            Inspect and reason read-only when tools are available.
            Proactively clarify material tradeoffs, scope boundaries, and preference differences. Ask one question at a time with one or more options; do not impose a three-option cap. Do not ask facts that tools or repository evidence can answer.
            Emit each question as exactly one block:
            <TATWO_PLAN_QUESTION>{"id":"stable-id","question":"question text","allowsMultipleSelections":false,"allowsOtherResponse":true,"options":[{"label":"option (Recommended)","detail":"impact or tradeoff"},{"label":"alternative","detail":"impact or tradeoff"}]}</TATWO_PLAN_QUESTION>
            Set allowsMultipleSelections per question. Set allowsOtherResponse=false only when a freeform Other answer is not valid for that question. Append the exact suffix " (Recommended)" to a recommended option label when appropriate; do not add a separate recommendation field.
            Keep detailed symbol inventory in plan artifact sections. Return only a concise conclusion-style chat summary with scope, risks, validation, and the next human decision.
            [/Hidden Codex-style Plan mode contract]
            """)
        }
        let shouldAppendLifecycleContext =
            ChatLifecyclePromptContextPolicy.shouldAppend(
                interactionMode: currentChatInteractionMode)
        if shouldAppendLifecycleContext,
           !isPlanModeEnabled,
           selectedThreadHasWorkOSGoal {
            sections.append("""
            [Hidden Codex-style Goal state — do not quote this block]
            goalMode=active
            continuity=沿用同一個 thread 與目前持續目標；不要自行另建 PLG run。
            interaction=依目前目標繼續工作，必要時回報進度、風險與下一個驗收點。
            [/Hidden Codex-style Goal state]
            """)
        }
        if collaborationIsEnabled, !isDiscussionSessionSelected, let contract = selectedWorkOSContract {
            sections.append("""
            [Hidden TATWO Work OS contract context — do not quote to the user unless asked]
            goalID=\(contract.goalID)
            contractID=\(contract.contractID)
            mode=\(contract.mode.rawValue)
            scenario=\(contract.scenario)
            goalStatus=\(contract.goalRun.status.rawValue)
            requiredReceipts=\(contract.receiptRequirements.map(\.id).joined(separator: ","))
            [/Hidden TATWO Work OS contract context]
            """)
        }
        if collaborationIsEnabled, let config = activeLoopsConfig {
            sections.append("""
            [Hidden TATWO Ultrawork loopsConfig context — do not quote to the user unless asked]
            \(config.summaryLine)
            [/Hidden TATWO Ultrawork loopsConfig context]
            """)
        }
        if let pluginDecisionContext {
            sections.append(pluginDecisionContext)
        }
        if let handoff = effectivePendingHandoff {
            sections.append("""
            [Hidden TATWO Ultrawork pendingHandoff context — use as continuity context, do not quote unless asked]
            summary=\(handoff.summaryLine)
            messages:
            \(handoff.messages.map { "- [\($0.role)] \(Self.handoffContextText($0.text))" }.joined(separator: "\n"))
            [/Hidden TATWO Ultrawork pendingHandoff context]
            """)
        }
        if shouldAppendLifecycleContext, let run = activePLGRun {
            if run.phase == .planning {
                sections.append("""
                [Hidden TATWO PLG phase state — do not quote this block]
                plgPhase=planning
                interaction=在同一個 thread 釐清需求、提出精簡可執行計畫；不得改檔、不得派工、不得宣稱已執行。
                exit=等待使用者以 /goal 或確認計畫明確開始執行。
                [/Hidden TATWO PLG phase state]
                """)
            } else {
                sections.append("""
                [Hidden TATWO PLG phase state — do not quote this block]
                plgPhase=\(run.phase.rawValue)
                interaction=沿用同一個 thread 與已確認計畫執行；Loops 只做必要分工，回報保持精簡。
                [/Hidden TATWO PLG phase state]
                """)
            }
        }
        guard !sections.isEmpty else { return visibleTurn }
        return sections.joined(separator: "\n\n") + "\n\n" + visibleTurn
    }

    private static func shouldUseBareExactOutputTurn(
        _ visibleTurn: String,
        collaborationIsEnabled: Bool,
        pluginDecisionContext: String?,
        hasPendingHandoff: Bool,
        droppedPaths: [String]
    ) -> Bool {
        guard !collaborationIsEnabled else { return false }
        guard pluginDecisionContext == nil else { return false }
        guard !hasPendingHandoff else { return false }
        guard droppedPaths.isEmpty else { return false }
        let trimmed = visibleTurn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        let lower = trimmed.lowercased()
        return lower.contains("只回")
            || lower.contains("只回答")
            || lower.contains("只要回答")
            || lower.contains("reply only")
            || lower.contains("respond only")
    }

    private var isUltraworkEngagedChat: Bool {
        collaborationIsEnabled
            || selectedThreadHasWorkOSGoal
            || activePLGRun != nil
    }

    private func nativeSubscriptionPreference(
        route: ChatRouteChoice,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        visibleTurn: String
    ) -> Bool? {
        guard let contract = selectedWorkOSContract,
              [
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
              ].contains(contract.scenario),
              dispatchSnapshot.contractID == contract.contractID,
              TatwoGatewayDispatchCatalog.normalize(
                route.canonicalModelSlug)
                == TatwoGatewayDispatchCatalog.normalize(
                    dispatchSnapshot.canonicalModelID),
              let contractBindingID =
                dispatchSnapshot.contractBindingID,
              contract.loopGovernorDecision.activatedBindings.contains(
                where: { binding in
                    binding.id == contractBindingID
                        && binding.enabled
                        && binding.dynamicActivation != .disabled
                        && binding.phase == dispatchSnapshot.phase
                        && binding.boundModelIDs.contains {
                            TatwoGatewayDispatchCatalog.normalize($0)
                                == TatwoGatewayDispatchCatalog.normalize(
                                    dispatchSnapshot.canonicalModelID)
                        }
                })
        else { return nil }
        if matchingPendingNativeDevelopmentDispatch(
            dispatchSnapshot: dispatchSnapshot) != nil
        {
            return true
        }

        let issuedStatus =
            (try? goalRunStore.requireIssuedContract(
                contract.contractID).status)
            ?? selectedGoalRecord?.status
            ?? contract.goalRun.status
        let decision = nativeDevelopmentDecision(for: visibleTurn)
        if decision.access == .mutation,
           dispatchSnapshot.phase == .loops,
           [.dispatching, .running].contains(issuedStatus)
        {
            // The dispatch is intentionally created after command planning by
            // preparePendingNativeDevelopmentDispatchIfNeeded. Do not force
            // this governed mutation turn onto the provider CLI before that
            // begin step has had a chance to run.
            return true
        }
        if decision.access == .readOnly,
           activePLGRun?.contractID == contract.contractID,
           activePLGRun?.goalID == contract.goalID,
           activePLGRun?.phase == .planning,
           issuedStatus == .planned,
           dispatchSnapshot.phase == .plan
        {
            return true
        }
        if decision.access == .readOnly,
           issuedStatus == .blocked,
           contract.scenario
                == TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
           dispatchSnapshot.phase == .loops,
           TatwoGatewayDispatchCatalog.normalize(
                route.canonicalModelSlug)
                == TatwoGatewayDispatchCatalog.normalize("gpt-5.6-sol")
        {
            // Frozen-phase recovery smoke: no dispatch is minted, but the
            // already-issued Sol executor binding still owns read-only tools.
            return true
        }
        return nil
    }

    func matchingPendingNativeDevelopmentDispatch(
        dispatchSnapshot: ChatTurnDispatchSnapshot
    ) -> TatwoDispatchRecord? {
        guard let pending = pendingNativeDevelopmentDispatch,
              let contract = selectedWorkOSContract,
              let contractBindingID =
                dispatchSnapshot.contractBindingID,
              pending.status == .running,
              pending.contractID == contract.contractID,
              pending.contractID == dispatchSnapshot.contractID,
              TatwoGatewayDispatchCatalog.normalize(pending.modelID)
                == TatwoGatewayDispatchCatalog.normalize(
                    dispatchSnapshot.canonicalModelID),
              contract.identityBindings.contains(where: { binding in
                  binding.id == pending.bindingID
                      && binding.sourceSlotID == pending.sourceSlotID
                      && binding.sourceSlotID == contractBindingID
                      && binding.modelID.map(
                          TatwoGatewayDispatchCatalog.normalize)
                          == TatwoGatewayDispatchCatalog.normalize(
                              pending.modelID)
              })
        else { return nil }
        return pending
    }

    private func nativeDevelopmentDecision(
        for visibleTurn: String
    ) -> TatwoNativeDevelopmentTurnDecision {
        TatwoChatCommandPlanner.nativeDevelopmentDecision(
            currentVisibleTurn: visibleTurn,
            mode: mode.commandMode,
            interactionMode: currentChatInteractionMode,
            scenarioPhase: currentTurnScenarioPhase,
            contractStatus:
                selectedGoalRecord?.status
                    ?? selectedWorkOSContract?.goalRun.status)
    }

    func plannedNativeDevelopmentBlockerHint(
        for visibleTurn: String
    ) -> String? {
        let decision = nativeDevelopmentDecision(for: visibleTurn)
        let status =
            selectedGoalRecord?.status
                ?? selectedWorkOSContract?.goalRun.status
        guard decision.requested,
              decision.access == .none,
              status == .planned
        else { return nil }
        return "目前 Goal 還在規劃中，尚未開放改碼工具。"
    }

    internal func nativeDevelopmentAccess(
        for visibleTurn: String
    ) -> TatwoNativeDevelopmentAccess {
        if let pending = pendingNativeDevelopmentDispatch,
           pending.contractID == selectedWorkOSContract?.contractID,
           pending.status == .running,
           currentTurnScenarioPhase == .loops
        {
            return .mutation
        }
        return nativeDevelopmentDecision(for: visibleTurn).access
    }

    func prepareBlockedNativeDevelopmentRetryIfNeeded(
        for visibleTurn: String,
        route: ChatRouteChoice
    ) -> Bool {
        guard selectedGoalRecord?.status == .blocked,
              selectedWorkOSContract?.scenario
                == TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
              pendingNativeDevelopmentDispatch == nil
        else { return true }
        // Classify the exact visible turn against the post-retry state. The
        // coordinator remains the authority gate: it only revives this Goal
        // when the selected binding has a failed dispatch to supersede.
        let postRetryDecision =
            TatwoChatCommandPlanner.nativeDevelopmentDecision(
                currentVisibleTurn: visibleTurn,
                mode: mode.commandMode,
                interactionMode: currentChatInteractionMode,
                scenarioPhase: .loops,
                contractStatus: .running)
        guard postRetryDecision.access == .mutation else { return true }
        return beginSelectedNativeDevelopmentDispatch(
            subtask: visibleTurn,
            selectedModelID: route.canonicalModelSlug)
    }

    private var currentChatPromptSurface: TatwoChatPromptSurface {
        isUltraworkEngagedChat ? .workOS : .ordinaryChat
    }

    private func chatInterfacePolicyContext(
        visibleTurn: String,
        attachmentPaths: [String]? = nil
    ) -> String {
        let trimmed = visibleTurn.trimmingCharacters(in: .whitespacesAndNewlines)
        let lengthHint: String
        if trimmed.count <= 80 {
            lengthHint = "short-direct"
        } else if trimmed.count >= 900 {
            lengthHint = "structured-but-concise"
        } else {
            lengthHint = "normal-concise"
        }
        let effectiveAttachmentPaths = attachmentPaths ?? droppedPaths
        let attachmentSummary = effectiveAttachmentPaths.isEmpty
            ? "none"
            : "\(effectiveAttachmentPaths.count) file(s); imageCount=\(effectiveAttachmentPaths.filter(Self.isLikelyImagePath).count)"
        return TatwoChatThreadContextComposer.systemFrame(
            for: currentChatPromptSurface,
            sentenceLengthHint: lengthHint,
            attachmentSummary: attachmentSummary)
    }

    private static func handoffContextText(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(900))
    }

    func recordThreadPluginDecision(for visibleTurn: String) -> String? {
        let entries = selectedThreadPluginEntries
        let contractID =
            selectedWorkOSContract?.contractID
            ?? selectedThread?.workOSContractID
        guard let context = TatwoThreadPluginDecisionContextComposer.compose(
            entries: entries,
            threadID: selectedThreadID?.uuidString.lowercased(),
            contractID: contractID,
            visibleTurn: visibleTurn)
        else { return nil }
        if let contractID {
            _ = try? goalRunStore.appendReceipt(
                contractID: contractID,
                receiptID: context.receiptID,
                kind: context.receiptKind,
                loopID: selectedWorkOSContract?.mainlineLoop.id)
            refreshSelectedWorkOSState(contractID: contractID)
        }
        return context.hiddenContext
    }

    func buildCommand(
        turn: String,
        visibleTurn: String,
        droppedPaths: [String],
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        computerHostBinding: ChatComputerHostTurnBinding,
        runID: String,
        turnID: String
    ) -> ChatCLICommand {
        let runtimeWorkspace = resolvedRuntimeWorkspace()
        let cwd = runtimeWorkspace.url
        let route = ChatRouteChoice.resolve(dispatchSnapshot.routeID)
        let nativeSubscriptionPreference =
            nativeSubscriptionPreference(
                route: route,
                dispatchSnapshot: dispatchSnapshot,
                visibleTurn: visibleTurn)
        let codexResumeID = route.engine == .codex
            ? TatwoChatCommandPlanner.sanitizedCodexResumeSessionID(
                selectedProviderSessionID(adapter: .codexExec, modelID: route.id))
            : nil
        let claudeResumeID = route.engine == .claude
            ? TatwoChatCommandPlanner.sanitizedClaudeResumeSessionID(
                selectedProviderSessionID(adapter: .claudeCLI, modelID: route.id))
            : nil
        let grokResumeID = route.profile.runtimeAdapter == .grokCLI
            ? TatwoChatCommandPlanner.sanitizedGrokResumeSessionID(
                selectedProviderSessionID(
                    adapter: .grokCLI,
                    modelID: route.id))
            : nil
        let targetSessionID = selectedProviderSessionID(
            adapter: TatwoChatCommandPlanner.runtimeAdapterForTurn(
                route: route.profile,
                interactionMode: currentChatInteractionMode,
                hasImageAttachments: droppedPaths.contains(where: Self.isLikelyImagePath),
                preferNativeSubscription: nativeSubscriptionPreference),
            modelID: route.id)
        let baselineRuntimeAdapter = TatwoChatCommandPlanner.runtimeAdapterForTurn(
            route: route.profile,
            interactionMode: currentChatInteractionMode,
            hasImageAttachments: droppedPaths.contains(where: Self.isLikelyImagePath),
            preferNativeSubscription: nativeSubscriptionPreference)
        let shouldBridgeHistoricalImages = ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: visibleTurn,
            interactionMode: currentChatInteractionMode,
            targetRuntimeAdapter: baselineRuntimeAdapter,
            targetHasResumableSession: targetSessionID != nil)
        let imageSelection = route.profile.supportsImageInput
            ? ChatImageDispatchSelector.select(
                currentPaths: droppedPaths,
                transcriptTexts: shouldBridgeHistoricalImages ? messages.map(\.text) : [],
                imageStore: imageAssetStore,
                limit: 8)
            : ChatImageDispatchSelection(paths: [], missingNames: [], omittedCount: 0)
        var runtimeTurn = turn
        if !imageSelection.missingNames.isEmpty || imageSelection.omittedCount > 0 {
            let imageContextReceipt = """

            [Hidden image context receipt — do not quote this block]
            missingImages=\(imageSelection.missingNames.joined(separator: ","))
            omittedOlderImages=\(imageSelection.omittedCount)
            attachedImageCount=\(imageSelection.paths.count)
            [/Hidden image context receipt]
            """
            // Gateway authority binds the exact visible UTF-8 suffix. Keep
            // hidden diagnostics before the composed prompt so image recovery
            // cannot move the visible current turn away from that suffix.
            runtimeTurn = imageContextReceipt + "\n\n" + runtimeTurn
            let missing = imageSelection.missingNames.isEmpty
                ? ""
                : "附件遺失 \(imageSelection.missingNames.count) 張"
            let omitted = imageSelection.omittedCount == 0
                ? ""
                : "較舊圖片省略 \(imageSelection.omittedCount) 張"
            flashComposerHint([missing, omitted].filter { !$0.isEmpty }.joined(separator: "；"))
        }
        let nonImagePaths = droppedPaths.filter {
            !TatwoImageAssetStore.isImageCandidatePath($0)
        }
        let dispatchPaths = imageSelection.paths + nonImagePaths
        let additionalWritableDirectories: [String]
        if currentChatInteractionMode == .standard,
           pendingSingleModelGoalDispatch != nil
                || pendingNativeDevelopmentDispatch != nil
        {
            switch ChatApprovedTaskOutputRoot.resolve(in: visibleTurn) {
            case .approved(let targetPath):
                additionalWritableDirectories = ChatApprovedTaskOutputRoot
                    .revalidatedWritableTarget(targetPath)
                    .map { [$0] }
                    ?? []
            case .none, .invalid, .ambiguous:
                additionalWritableDirectories = []
            }
        } else {
            additionalWritableDirectories = []
        }
        // The planner's legacy API requires a non-optional value. Routes with
        // no native effort capability ignore this default and receive no
        // effort argv; only dispatchSnapshot.forwardedEffort is an attested
        // outbound effort request.
        let plannerEffort = dispatchSnapshot.forwardedEffort
            ?? route.defaultEffort
        let developmentDecision =
            nativeDevelopmentDecision(for: visibleTurn)
        let developmentAccess =
            nativeDevelopmentAccess(for: visibleTurn)
        let resolvedRuntimeAdapter = TatwoChatCommandPlanner.runtimeAdapterForTurn(
            route: route.profile,
            interactionMode: currentChatInteractionMode,
            hasImageAttachments: dispatchPaths.contains(
                where: Self.isLikelyImagePath),
            requiresTatwoComputerHost:
                computerHostBinding.decision.route == .mcp,
            nativeDevelopmentAccess: developmentAccess,
            preferNativeSubscription: nativeSubscriptionPreference)
        let continuationRequest = gatewayContinuationRequest(
            route: route,
            runtimeAdapter: resolvedRuntimeAdapter,
            context: runtimeTurn)
        let plan = TatwoChatCommandPlanner.plan(
            mode: mode.commandMode,
            route: route.profile,
            turn: runtimeTurn,
            workingDirectoryPath: cwd.path,
            permissionPreset: permissionPreset,
            interactionMode: currentChatInteractionMode,
            effort: plannerEffort,
            speedTier: mode.commandMode == .chat ? selectedSpeedTier : nil,
            codexSessionID: codexResumeID,
            claudeSessionID: claudeResumeID,
            grokSessionID: grokResumeID,
            gatewayContinuationRequest: continuationRequest,
            droppedPaths: dispatchPaths,
            additionalWritableDirectories:
                additionalWritableDirectories,
            gatewayDirectScriptPath: Self.gatewayDirectAdapterScriptURL().path,
            toolHostRequirementTurn: visibleTurn,
            computerHostTurnRoute: dispatchSnapshot.computerHostDecision.route,
            computerHostRunID: runID,
            computerHostTurnID: turnID,
            computerHostMCPPath:
                computerHostBinding.decision.route != .mcp
                    || computerHostBinding.lease == nil
                ? nil
                : Self.computerHostMCPAdapterScriptURL().path,
            computerHostAppMCPEndpoint: computerHostBinding.decision.route == .mcp
                ? computerHostBinding.appMCPEndpoint
                : nil,
            appManagementMCPPath:
                appMCPRuntimeProvider().endpoint == nil
                ? nil
                : Self.appManagementMCPAdapterScriptURL().path,
            appManagementMCPEndpoint: appMCPRuntimeProvider().endpoint,
            perThreadAllowedMCPTools: selectedThreadID
                .flatMap { threadAllowedMCPTools[$0].map(Array.init) } ?? [],
            computerHostContractID: computerHostBinding.decision.route == .mcp
                ? computerHostBinding.contractID
                : nil,
            computerHostLeaseID: computerHostBinding.decision.route == .mcp
                ? computerHostBinding.lease?.id
                : nil,
            coworkLogFilePath: nil,
            skipGitRepoCheck: runtimeWorkspace.skipGitRepoCheck,
            nativeDevelopmentRequested: developmentDecision.requested,
            nativeDevelopmentAccess: developmentAccess,
            preferNativeSubscription: nativeSubscriptionPreference,
            codexHomePath:
                ChatNativeSubscriptionHomeLocator().resolve().path,
            bundleURL: Bundle.main.bundleURL,
            environment: ProcessInfo.processInfo.environment,
            isExecutableFile: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        let command = ChatCLICommand(plan: plan, commandMode: mode.commandMode)
        if plan.engine == .claude {
            appendRound18ClaudeRouteReceipt(command: command)
        }
        return command
    }

    func cliDevelopmentFallbackCommand(
        from nativeCommand: ChatCLICommand,
        prompt: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot
    ) -> ChatCLICommand? {
        guard nativeCommand.runtimeAdapter == .nativeAgent,
              let route = ChatRouteChoice.resolveOrNil(
                dispatchSnapshot.routeID)
        else { return nil }
        let plannerEffort =
            dispatchSnapshot.forwardedEffort
                ?? route.defaultEffort
        let plan = TatwoChatCommandPlanner.plan(
            mode: nativeCommand.commandMode,
            route: route.profile,
            turn: prompt,
            workingDirectoryPath: nativeCommand.workingDirectory.path,
            permissionPreset: permissionPreset,
            interactionMode: currentChatInteractionMode,
            effort: plannerEffort,
            speedTier:
                nativeCommand.commandMode == .chat
                    ? selectedSpeedTier : nil,
            codexSessionID:
                route.engine == .codex
                    ? TatwoChatCommandPlanner
                        .sanitizedCodexResumeSessionID(
                            selectedProviderSessionID(
                                adapter: .codexExec,
                                modelID: route.id))
                    : nil,
            claudeSessionID:
                route.engine == .claude
                    ? TatwoChatCommandPlanner
                        .sanitizedClaudeResumeSessionID(
                            selectedProviderSessionID(
                                adapter: .claudeCLI,
                                modelID: route.id))
                    : nil,
            grokSessionID:
                route.profile.runtimeAdapter == .grokCLI
                    ? TatwoChatCommandPlanner
                        .sanitizedGrokResumeSessionID(
                            selectedProviderSessionID(
                                adapter: .grokCLI,
                                modelID: route.id))
                    : nil,
            gatewayDirectScriptPath:
                Self.gatewayDirectAdapterScriptURL().path,
            skipGitRepoCheck:
                nativeCommand.workingDirectory.path
                    == Self.safeChatWorkspaceURL().path,
            nativeDevelopmentRequested: false,
            nativeDevelopmentAccess: .none,
            preferNativeSubscription: nil,
            codexHomePath:
                ChatNativeSubscriptionHomeLocator().resolve().path,
            bundleURL: Bundle.main.bundleURL,
            environment: ProcessInfo.processInfo.environment,
            isExecutableFile: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        guard plan.runtimeAdapter != .nativeAgent,
              plan.runtimeAdapter != .unavailable
        else { return nil }
        return ChatCLICommand(
            plan: plan,
            commandMode: nativeCommand.commandMode
        ).withRuntimeFallbackReason(.nativeGovernanceNotEngaged)
    }
}
