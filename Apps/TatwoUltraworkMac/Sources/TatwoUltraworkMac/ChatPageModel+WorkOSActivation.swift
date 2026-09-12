import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    /// `/goal` and `/plg` are explicit activation surfaces. They must first
    /// persist the selected scenario/mode on the thread so the collaboration
    /// shown after issuance is the same topology that signed the contract.
    ///
    /// If a canonical Goal already exists, reconstruct from that immutable
    /// contract instead of guessing from the current picker.
    private func materializeLoopsConfigForExplicitWorkOSActivationIfNeeded()
        -> Bool
    {
        guard let location = selectedThreadLocation() else { return false }
        var thread = thread(at: location)
        guard thread.loopsConfig == nil else { return true }

        let existingContractID = Self.normalizedNonEmpty(
            thread.workOSContractID)
        let existingGoalID = Self.normalizedNonEmpty(thread.workOSGoalID)
        let materialized: TatwoNativeThreadLoopsConfig
        if existingContractID != nil || existingGoalID != nil {
            guard let existingContractID, let existingGoalID else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：thread 綁定不完整，無法還原協作拓撲。")
                return false
            }
            do {
                let issued = try goalRunStore.requireIssuedContract(
                    existingContractID)
                guard issued.goalID == existingGoalID else {
                    throw TatwoSessionAttachmentError.pointerGoalRunMismatch(
                        "thread_loops_config")
                }
                let contract = try WorkOSFactory.storedContractProjection(
                    contractID: existingContractID,
                    fallbackMode: issued.mode,
                    fallbackScenarioProfileID: issued.scenario,
                    fallbackObjective: issued.objective,
                    scenarioBook: scenarioConfigBook,
                    store: goalRunStore)
                materialized = loopsConfig(materializing: contract)
            } catch {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：canonical Goal 存在但協作拓撲無法還原。")
                return false
            }
        } else {
            guard let template = selectedCoworkTemplate else {
                quarantineSelectedWorkOSState(
                    "Work OS activation 已停止：找不到可簽發的情境／模式。")
                return false
            }
            selectedCoworkTemplateID = template.id
            materialized = loopsConfig(for: template)
        }

        thread.loopsConfig = materialized
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        guard publishDocumentChangeAndPersist() else {
            quarantineSelectedWorkOSState(
                "Work OS activation 已停止：協作情境尚未安全寫入 thread。")
            return false
        }
        return true
    }

    @discardableResult
    func ensureSelectedThreadWorkOSContract(
        objectiveHint: String? = nil,
        requireObjectiveMatch: Bool = false,
        allowCreateIfUnbound: Bool = false,
        allowLegacyV1OwnerMigration: Bool = false,
        automaticallyBootstrapUserOwnedAuthority: Bool = false,
        forceSingleModel: Bool = false
    ) -> Bool {
        guard !isDiscussionSessionSelected else {
            selectedWorkOSStateMessage = "Discussion 是 branch-local session；未 merge receipt 前不建立或沿用主線 Work OS contract。"
            return false
        }
        guard let thread = selectedThread else {
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            selectedWorkOSStateMessage = "尚無 selected thread"
            return false
        }
        guard !workOSBindingMutationRecoveryBlocked else {
            selectedWorkOSStateMessage =
                "Work OS 綁定復原仍在隔離；已停止建立新 Goal，請保留 durable intent 後重啟重試。"
            return false
        }
        if workOSBindingPersistencePending {
            guard persistStore() else {
                selectedWorkOSStateMessage =
                    "Work OS 綁定更新尚未安全寫入磁碟；已停止建立新 Goal，下一次操作會自動重試。"
                return false
            }
            do {
                if let intent = try workOSBindingMutationIntentStore.load() {
                    let predecessorGoal = try goalRunStore
                        .requireIssuedContract(intent.oldContractID)
                    guard Self.workOSBindingMutationIntentIsApplied(
                        intent,
                        in: try store.load(),
                        predecessorGoal: predecessorGoal,
                        standaloneWorkspacePath:
                            Self.safeChatWorkspaceURL()
                                .standardizedFileURL.path)
                    else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try workOSBindingMutationIntentStore.remove(intent)
                }
            } catch {
                workOSBindingMutationRecoveryBlocked = true
                workOSBindingMutationRecoveryIntent =
                    try? workOSBindingMutationIntentStore.load()
                selectedWorkOSStateMessage =
                    "Work OS 綁定已寫入，但 durable mutation intent 尚未完成清理；已停止建立新 Goal。"
                return false
            }
        }

        // 2026-08-21 使用者裁決：指標屬於別的 Chat row 時，這一列不接手
        // 也不隔離；下面的「純聊天不建 Goal」關卡也要放它過。
        var currentSessionOwnedByAnotherThread = false
        let canonicalOwner = currentSessionCanonicalOwner(
            for: thread,
            projectID: selectedProjectID)
        let isSelectedProjectMirror =
            selectedProjectID != nil
            && thread.sourceMarker
                == TatwoNativeChatThreadSourceMarker.codexAppMirror
            && Self.isCodexAppMirrorThread(thread)
        if (isSelectedThreadStandalone
                && isEligibleTatwoChatWorkspaceMirror(thread))
            || isSelectedProjectMirror
            || canonicalOwner != nil
        {
            if allowCreateIfUnbound, currentSessionPointerPresent {
                switch recoverTerminalCurrentSessionForExplicitActivation(
                    thread: thread,
                    projectID: selectedProjectID,
                    canonicalOwner: canonicalOwner)
                {
                case .notApplicable, .recovered:
                    break
                case .quarantined:
                    return false
                }
            }
            let currentSessionAttachResult =
                attachVerifiedCurrentSessionToSelectedThreadIfEligible(
                    allowLegacyV1OwnerMigration:
                        allowLegacyV1OwnerMigration)
            if currentSessionPointerPresent {
                switch currentSessionAttachResult {
                case .attached:
                    break
                case .quarantined:
                    return false
                case .ownedByAnotherThread:
                    currentSessionOwnedByAnotherThread = true
                case .notApplicable:
                    // 2026-08-21「每對話一 session」第三洞（親測抓到）：
                    // 新 thread 尚無 loops 綁定＝不符 dedicated 資格，attach
                    // 回 notApplicable；但指標屬於另一個真實 Chat row 時這
                    // 不是事故——放行讓本列自建。孤兒指標維持隔離。
                    if let pointerOwner =
                        ((try? TatwoSessionStore(
                            directoryURL: goalRunStore.directoryURL)
                            .snapshotCurrent()) ?? nil)?
                            .pointer.ownerBinding,
                       currentSessionPointerIsOwnedByAnExistingOtherThread(
                           pointerOwner: pointerOwner,
                           excluding: thread.id)
                    {
                        currentSessionOwnedByAnotherThread = true
                    } else {
                        quarantineSelectedWorkOSState(
                            "Work OS continuity 已隔離：current-session 無法安全接到此 Tatwo chat-workspace row。")
                        return false
                    }
                }
            }
            if currentSessionPointerPresent,
               !currentSessionOwnedByAnotherThread,
               verifiedCurrentSessionBundle == nil {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：current-session 存在但 canonical GoalRun 驗證失敗，未建立新 Goal。")
                return false
            }
        }

        if allowCreateIfUnbound,
           !forceSingleModel,
           !materializeLoopsConfigForExplicitWorkOSActivationIfNeeded()
        {
            return false
        }
        let refreshedThread = selectedThread ?? thread
        let context = selectedThreadWorkOSContext(
            thread: refreshedThread,
            objectiveHint: objectiveHint,
            forceSingleModel: forceSingleModel)
        let routeBindingOverride = forceSingleModel
            ? WorkOSRouteBindingOverride(
                primaryModelID:
                    currentTurnDispatchRoute().canonicalModelSlug,
                secondaryModelID: nil)
            : workOSRouteBindingOverride(
                for: refreshedThread.loopsConfig)
        let existingContractID = Self.normalizedNonEmpty(
            refreshedThread.workOSContractID)
        let existingGoalID = Self.normalizedNonEmpty(
            refreshedThread.workOSGoalID)
        let hasAnyExistingBinding =
            existingContractID != nil
            || existingGoalID != nil
            || refreshedThread.selectedThreadWorkOSContext != nil
            || refreshedThread.activePLGRunProjection != nil

        if hasAnyExistingBinding {
            guard let existingContractID,
                  let existingGoalID,
                  let storedContext = refreshedThread.selectedThreadWorkOSContext
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：thread 綁定不完整，未建立新 Goal。")
                return false
            }
            do {
                let issued = try goalRunStore.requireIssuedContract(existingContractID)
                let issuedIdentity = TatwoObjectiveIdentity.make(issued.objective)
                guard issued.goalID == existingGoalID,
                      storedContext.matches(issuedIdentity),
                      issued.mode == context.mode,
                      issued.scenario == context.scenario,
                      Self.effectiveWorkOSRouteBindingOverride(
                        mode: issued.mode,
                        scenarioID: issued.scenario,
                        explicit: issued.routeBindingOverride)
                        == Self.effectiveWorkOSRouteBindingOverride(
                            mode: context.mode,
                            scenarioID: context.scenario,
                            explicit: routeBindingOverride),
                      !requireObjectiveMatch
                        || issuedIdentity.objectiveHash == context.objectiveHash,
                      TatwoPLGGovernance.canReuseIssuedContract(
                        issuedObjective: issued.objective,
                        requestedObjective: context.objective,
                        requireObjectiveMatch: requireObjectiveMatch)
                else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：objective／route／Goal binding 不一致，未建立新 Goal。")
                    return false
                }

                // 2026-08-28 staging69/runtime-63 live：這條 reuse 關卡漏了
                // 2026-08-21「每個對話各自一個 Work OS session」的裁決。
                // attach 路徑已經把「指標屬於**另一條真實 Chat row**」判成良性
                // （`.ownedByAnotherThread`），但這裡仍要求磁碟指標必須指向
                // 本列的合約，於是第二個 Ultrawork 對話一旦取得 current-session
                // 指標，第一條對話就再也送不出任何 Work OS 回合：
                // `submitCurrentChatTurn` 在 append canonical user message 之前
                // 就 return false，PLG【確認計畫，進入分工】隨即把剛開的單模型
                // dispatch 標成 `gateway_error: … 單模型 runner 未取得執行權`。
                //
                // 指標不屬於本列時，本列的權威來源是它自己已簽發、上面剛剛
                // 逐項驗過的 durable binding；孤兒指標（誰都不屬於）仍走原本的
                // fail-closed，`currentSessionOwnedByAnotherThread` 只有在證明
                // 有「別人」擁有它時才會為 true。
                if !currentSessionOwnedByAnotherThread,
                   (isSelectedThreadStandalone
                        && isEligibleTatwoChatWorkspaceMirror(refreshedThread))
                    || (selectedProjectID != nil
                        && refreshedThread.sourceMarker
                            == TatwoNativeChatThreadSourceMarker.codexAppMirror
                        && Self.isCodexAppMirrorThread(refreshedThread))
                    || currentSessionCanonicalOwner(
                        for: refreshedThread,
                        projectID: selectedProjectID) != nil
                {
                    guard let bundle = verifiedCurrentSessionBundle,
                          verifiedCurrentSessionBundleIsCanonical(bundle),
                          existingContractID == bundle.contract.contractID,
                          existingGoalID == bundle.contract.goalID
                    else {
                        quarantineSelectedWorkOSState(
                            "Work OS continuity 已隔離：thread 與 verified current-session 關係不一致。")
                        return false
                    }
                }

                let contract = try WorkOSFactory.storedContractProjection(
                    contractID: existingContractID,
                    fallbackMode: issued.mode,
                    fallbackScenarioProfileID: issued.scenario,
                    fallbackObjective: issued.objective,
                    scenarioBook: scenarioConfigBook,
                    store: goalRunStore)
                selectedWorkOSContract = contract
                selectedGoalRecord = issued
                selectedDispatchRecords = try dispatchRegistry.latestRecordsByBinding(
                    forContractID: contract.contractID)
                selectedWorkOSStateMessage = "Work OS contract 已連線"
                return true
            } catch {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：canonical GoalRun 無法驗證，未建立新 Goal。")
                return false
            }
        }

        guard allowCreateIfUnbound else {
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            selectedWorkOSStateMessage =
                "普通 Chat 不會建立新 Goal／Contract；請用 /goal、/plg 或明確 $tatwo-ultrawork 指令啟動。"
            // 2026-08-21 使用者裁決：current-session 屬於別的 Chat row 時，
            // 這一列還沒有自己的 Goal 是正常狀態，不該連「講話」都被擋。
            // 放行成純聊天回合（仍然不建立任何 Goal／Contract）；要開工
            // 依舊得走 /goal、/plg 或明確 $tatwo-ultrawork。
            //
            // 但只放行「完全乾淨」的新對話：還帶著 durable binding
            // invalidation 的 thread 正在復原程序中，不是新聊天，必須維持
            // 原本的 fail-closed（否則會在 cold-start 復原途中被寫入干擾）。
            return currentSessionOwnedByAnotherThread
                && refreshedThread.bindingInvalidation == nil
        }

        do {
            guard let canonicalOwner else {
                selectedWorkOSStateMessage =
                    "Work OS contract 建立已停止：缺少明確 provider session/thread owner。"
                return false
            }
            let authorityInstanceDiscriminator =
                Self.canonicalChatAuthorityInstanceDiscriminator(for: canonicalOwner)
            let proposedContract = try WorkOSFactory.projectContract(
                mode: context.mode,
                scenarioProfileID: context.scenario,
                objective: context.objective,
                catalog: .defaults,
                scenarioBook: scenarioConfigBook,
                routeBindingOverride: routeBindingOverride,
                authorityInstanceDiscriminator: authorityInstanceDiscriminator)
            let bootstrapPreflight =
                try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
                    goalStoreRoot: goalRunStore.directoryURL,
                    contractID: proposedContract.contractID)
            let bootstrapProposal =
                TatwoAppAuthorityBootstrapProposalV1(
                    goalStoreRoot: goalRunStore.directoryURL,
                    contractID: proposedContract.contractID,
                    owner: canonicalOwner,
                    preflight: bootstrapPreflight,
                    objectivePreview: context.preview)
            if !authorityBootstrapModel.consumeConfirmedReadback(
                for: bootstrapProposal)
            {
                // 2026-08-27 runtime-63: project rows persisted before the
                // creation sites stamped `sourceMarker` carry no marker at
                // all, so the marker test alone left them stuck on the
                // explicit AppShell bootstrap even though their canonical
                // owner is this exact Tatwo chat row.
                //
                // The relaxation is deliberately scoped to *project* rows. A
                // standalone row with no marker is a dedicated collaboration
                // chat (`createDedicatedCollaborationChat` clears the marker
                // when it inherits a topology) and must keep the explicit
                // authority-lock gate. Codex-App mirror rows resolve to
                // provider `codex` and are excluded by the owner test.
                let selfOwnedLegacyProjectRow =
                    selectedProjectID != nil
                    && Self.canonicalOwnerIsSelfOwnedTatwoChatRow(
                        canonicalOwner,
                        thread: refreshedThread)
                if automaticallyBootstrapUserOwnedAuthority,
                   refreshedThread.sourceMarker
                    == TatwoNativeChatThreadSourceMarker.userOwned
                    || selfOwnedLegacyProjectRow
                {
                    do {
                        guard
                            try authorityBootstrapModel
                                .bootstrapAndConsumeExplicitUserOwnedActivation(
                                    bootstrapProposal)
                        else {
                            selectedWorkOSStateMessage =
                                "Work OS contract 尚未建立：authority-lock fresh readback 未通過。"
                            return false
                        }
                    } catch {
                        selectedWorkOSStateMessage =
                            "Work OS contract 尚未建立："
                            + TatwoPrivacyRedactor.redacted(
                                error.localizedDescription)
                        return false
                    }
                } else {
                    authorityBootstrapModel.stage(bootstrapProposal)
                    selectedWorkOSStateMessage =
                        "Work OS contract 尚未建立：請先在 AppShell 明確確認 authority-lock bootstrap，再重新送出。"
                    return false
                }
            }
            let sessionStore = TatwoSessionStore(
                directoryURL: goalRunStore.directoryURL)
            let attachment = try sessionStore.beginCurrent(
                mode: context.mode,
                scenarioProfileID: context.scenario,
                objective: context.objective,
                catalog: .defaults,
                scenarioBook: scenarioConfigBook,
                routeBindingOverride: routeBindingOverride,
                authorityInstanceDiscriminator: authorityInstanceDiscriminator,
                owner: canonicalOwner,
                goalStore: goalRunStore,
                dispatchRegistry: dispatchRegistry)
            let contract = attachment.contract
            let issuedGoalRecord = attachment.goalRecord
            let verifiedBundle = ChatVerifiedCurrentSessionBundle(
                pointer: attachment.pointer,
                contract: attachment.contract,
                goalRecord: attachment.goalRecord)
            currentSessionPointerPresent = true
            verifiedCurrentSessionBundle = verifiedBundle
            guard updateSelectedThreadWorkOSMetadata(
                goalID: contract.goalID,
                contractID: contract.contractID,
                objectiveIdentity:
                    TatwoObjectiveIdentity.make(contract.objective))
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            selectedWorkOSContract = contract
            selectedGoalRecord = issuedGoalRecord
            selectedDispatchRecords = try dispatchRegistry.latestRecordsByBinding(
                forContractID: contract.contractID)
            selectedWorkOSStateMessage = "Work OS contract 已建立 · \(context.preview)"
            return true
        } catch {
            inspectCurrentSessionBundleFromDisk()
            quarantineSelectedWorkOSState(
                "Work OS contract／current-session 建立失敗；未啟動本輪："
                    + TatwoPrivacyRedactor.redacted(error.localizedDescription))
            return false
        }
    }

    func send() {
        sendActionSequence += 1
        guard canSend else { return }
        let submissionRoute = currentTurnDispatchRoute()
        let rejectedAttachments = droppedPaths.filter {
            !submissionRoute.profile.acceptsAttachmentPath($0)
        }
        if !rejectedAttachments.isEmpty {
            droppedPaths.removeAll { rejectedAttachments.contains($0) }
            for path in rejectedAttachments {
                droppedPathDisplayNames.removeValue(forKey: path)
            }
            flashComposerHint(
                "\(submissionRoute.title) 目前是純文字 route；已移除不會被傳送的圖片。")
            return
        }
        // Slash commands are control-surface actions, not ordinary chat text.
        // /plan and /goal mirror Codex-style persistent thread state. /plg is
        // the explicit Plan → Loops → Goal workflow and must not be aliased.
        if mode == .chat {
            if handleDiscussionForkFromPromptIfPresent() {
                return
            }
            if handleSlashCommandChainIfPresent() {
                return
            }
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.resemblesLocalWorkOSNextCommand(trimmed) {
                flashComposerHint(
                    "tatwo.os.next 不是聊天指令；請在 Plan 上使用「確認計畫／送交 Work OS」。")
                return
            }
            if selectedThreadID == nil,
               matchesSlash(trimmed, "/plg")
                    || matchesSlash(trimmed, "/goal")
            {
                newChat()
            }
            if matchesSlash(trimmed, "/plg") {
                triggerPLGFromPrompt()
                return
            }
            if matchesSlash(trimmed, "/plan") {
                handlePlanSlashCommand()
                return
            }
            if matchesSlash(trimmed, "/goal") {
                commitOrActivateGoalFromPrompt()
                return
            }
            if matchesSlash(trimmed, "/issue") {
                handleIssueSlashCommand()
                return
            }
            if matchesSlash(trimmed, "/蒸餾") {
                triggerDistillFromPrompt()
                return
            }
            if routeExplicitWorkOSConfirmationGatePromptIfNeeded() {
                return
            }
        }
        if mode == .cli {
            // 有多工分頁→送當前 active 分頁；否則退回舊單一終端。
            if activeCLITabID != nil {
                sendActiveCLITabInput()
            } else {
                sendNativeTerminalInput()
            }
            return
        }
        if Self.hasExplicitPromptCollaborationControl(in: prompt) {
            submitCurrentChatTurn(applyPromptCollaboration: true)
        } else {
            submitCurrentChatTurn()
        }
    }

    /// Earliest fail-closed boundary for a prose request that explicitly asks
    /// the App to create its clickable Work OS gate. This must run before
    /// `submitCurrentChatTurn()`, which computes Computer Host intent and may
    /// start a runtime. Returning true always consumes the classified request,
    /// including local persistence failures, so it can never fall through to
    /// an ordinary executable chat completion.
    private func routeExplicitWorkOSConfirmationGatePromptIfNeeded() -> Bool {
        guard let objective = Self.workOSConfirmationGateObjective(
            in: prompt)
        else { return false }
        if selectedThreadID == nil {
            newChat()
        }
        guard let threadID = selectedThreadID else {
            flashComposerHint(
                "Plan gate 未建立：目前沒有可綁定的 thread；未啟動 runner。")
            return true
        }
        guard stageWorkOSConfirmationGatePlan(
            objective: objective,
            threadID: threadID)
        else {
            // `persistPlanArtifact` already publishes the storage reason. The
            // request is still consumed to preserve the no-runner boundary.
            return true
        }
        let userMessage = ChatMessage(
            role: .user,
            text: objective,
            eventKind: .message)
        guard appendMessage(userMessage) else {
            flashComposerHint(
                "Plan 已建立，但原始請求無法寫入 transcript；未啟動 runner。")
            return true
        }
        updateSelectedThreadPreview(objective, sessionID: nil)
        _ = clearComposerDraftAfterAcceptedSubmission()
        droppedPaths = []
        droppedPathDisplayNames = [:]
        return true
    }

    /// `# <task>` opens one child session from the current main thread,
    /// snapshots the parent's transcript, switches into the child, and submits
    /// the task as that child's first turn. A child never opens a nested child.
    private func handleDiscussionForkFromPromptIfPresent() -> Bool {
        let trimmed = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "#" else { return false }
        let bodyStart = trimmed.index(after: trimmed.startIndex)
        if bodyStart < trimmed.endIndex,
           !trimmed[bodyStart].isWhitespace
        {
            return false
        }
        let task = String(trimmed[bodyStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            prompt = "# "
            flashComposerHint("請在 # 後輸入支線任務。")
            return true
        }
        if selectedThreadID == nil {
            createUserOwnedChat()
        }
        guard selectedThread != nil else {
            flashComposerHint("#討論串未建立：找不到可繼承的主 thread。")
            return true
        }
        guard !isDiscussionSessionSelected else {
            flashComposerHint("#討論串未建立：支線不能再開巢狀支線；請先回主線。")
            return true
        }
        guard !isRunning else {
            flashComposerHint("#討論串尚未送出：目前主線正在回覆；輸入已保留，完成後重試。")
            return true
        }
        let title = task
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? task
        guard let discussionID =
                createDiscussionForSelectedThread(title: title),
              selectedDiscussionID == discussionID
        else {
            flashComposerHint("#討論串未建立：父 thread 快照或支線選取失敗。")
            return true
        }
        prompt = task
        submitCurrentChatTurn(applyPromptCollaboration: false)
        guard prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            if composerHint?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty != false {
                flashComposerHint(
                    "#討論串已建立，但首回合未送出；輸入仍保留，請依提示重試。")
            }
            return true
        }
        flashComposerHint("已開啟 #\(title.prefix(64))，並送出支線首回合。")
        return true
    }

    /// Supports several slash commands in one composer submission while
    /// keeping execution commands fail-closed: local `/issue` captures may be
    /// chained, and at most one runtime command must be the final line.
    private func handleSlashCommandChainIfPresent() -> Bool {
        let invocations = TatwoSlashCommandParser.commandLines(
            in: prompt,
            commands: ChatComposerSlashCatalog.commands)
        guard invocations.count > 1 else { return false }

        let runtimeCommands: Set<String> = ["/plg", "/plan", "/goal", "/蒸餾"]
        let runtimeIndexes = invocations.indices.filter {
            runtimeCommands.contains(invocations[$0].command)
        }
        guard runtimeIndexes.count <= 1,
              runtimeIndexes.first.map({ $0 == invocations.index(before: invocations.endIndex) }) ?? true
        else {
            flashComposerHint("多指令中，/plg／/plan／/goal／/蒸餾 只能放最後一行。")
            return true
        }

        for invocation in invocations where invocation.command == "/issue" {
            captureIssueSlashCommand(argument: invocation.argument)
        }

        guard let runtimeIndex = runtimeIndexes.first else {
            prompt = ""
            reloadIssueList()
            issueProjectionRan = true
            requestOpenInfoCard = true
            flashComposerHint("已處理 \(invocations.count) 個 Issue List 指令。")
            return true
        }

        let runtime = invocations[runtimeIndex]
        prompt = runtime.argument.isEmpty
            ? runtime.command
            : "\(runtime.command) \(runtime.argument)"
        if selectedThreadID == nil,
           ["/plg", "/goal"].contains(runtime.command)
        {
            newChat()
        }
        switch runtime.command {
        case "/plg":
            triggerPLGFromPrompt()
        case "/plan":
            handlePlanSlashCommand()
        case "/goal":
            commitOrActivateGoalFromPrompt()
        case "/蒸餾":
            triggerDistillFromPrompt()
        default:
            return false
        }
        return true
    }

    /// Confirmed Plan execution is not a composer submission. It already has
    /// a canonical Goal/contract/dispatch and must start that exact governed
    /// turn without consuming unrelated draft state or entering the ordinary
    /// running-turn queue.
    @discardableResult
    func startConfirmedPlanExecutionTurn(
        _ commandDisplayTurn: String
    ) -> Bool {
        let executionMessage = ChatMessage(
            role: .user,
            text: commandDisplayTurn,
            eventKind: .message)
        guard ChatPlanThoughtPresentation
            .isConfirmedPlanExecutionPrompt(executionMessage)
        else {
            flashComposerHint(
                "已確認計畫未送出：execution envelope 無法驗證。")
            return false
        }
        guard coldStartHydrationState == .completed else {
            flashComposerHint(
                "聊天資料仍在載入；已確認計畫尚未送交 Work OS。")
            return false
        }
        guard selectedThreadID != nil, selectedThread != nil else {
            flashComposerHint(
                "已確認計畫未送出：找不到綁定的 selected thread。")
            return false
        }
        guard !isRunning else {
            flashComposerHint(
                "已確認計畫未送出：目前已有回合執行中；請重試確認。")
            return false
        }
        guard ensureSelectedThreadWorkOSContract(
            allowCreateIfUnbound: false),
              let contract = selectedWorkOSContract,
              let thread = selectedThread,
              thread.workOSContractID == contract.contractID,
              thread.workOSGoalID == contract.goalID
        else {
            let reason = selectedWorkOSStateMessage.trimmingCharacters(
                in: .whitespacesAndNewlines)
            flashComposerHint(
                reason.isEmpty
                    ? "已確認計畫未送出：canonical Work OS contract 無法驗證。"
                    : reason)
            return false
        }
        var candidateDispatches: [TatwoDispatchRecord] = []
        if let pendingNativeDevelopmentDispatch {
            candidateDispatches.append(pendingNativeDevelopmentDispatch)
        }
        if let pendingSingleModelGoalDispatch {
            candidateDispatches.append(pendingSingleModelGoalDispatch)
        }

        var matchingDispatches: [TatwoDispatchRecord] = []
        for dispatch in candidateDispatches {
            guard dispatch.contractID == contract.contractID else {
                continue
            }
            guard dispatch.goalID == nil
                    || dispatch.goalID == contract.goalID
            else {
                continue
            }
            guard dispatch.status == .running else {
                continue
            }
            let normalizedDispatchModelID =
                TatwoGatewayDispatchCatalog.normalize(dispatch.modelID)
            let hasMatchingBinding = contract.identityBindings.contains {
                binding -> Bool in
                guard binding.id == dispatch.bindingID,
                      binding.sourceSlotID == dispatch.sourceSlotID
                else {
                    return false
                }
                let normalizedBindingModelID = binding.modelID.map {
                    TatwoGatewayDispatchCatalog.normalize($0)
                }
                return normalizedBindingModelID
                    == normalizedDispatchModelID
            }
            guard hasMatchingBinding else {
                continue
            }
            matchingDispatches.append(dispatch)
        }
        guard matchingDispatches.count == 1,
              let canonicalDispatch = matchingDispatches.first
        else {
            flashComposerHint(
                "已確認計畫未送出：必須恰有一筆 canonical running dispatch。")
            return false
        }

        let snapshotRoute = currentTurnDispatchRoute()
        guard TatwoGatewayDispatchCatalog.normalize(
            snapshotRoute.canonicalModelSlug)
            == TatwoGatewayDispatchCatalog.normalize(
                canonicalDispatch.modelID)
        else {
            flashComposerHint(
                "已確認計畫未送出：目前 route 與 canonical dispatch 不一致。")
            return false
        }
        let computerUseRequested =
            TatwoChatCommandPlanner.requiresTatwoComputerHost(
                for: commandDisplayTurn)
        let computerHostDecision = ChatComputerHostTurnDecision(
            userRequested: computerUseRequested,
            route: TatwoComputerHostTurnRoutingPolicy.select(
                userRequestedComputerUse: computerUseRequested,
                isChatMode: mode == .chat,
                isPlanMode: isPlanModeEnabled,
                route: snapshotRoute.profile))
        if computerHostDecision.isAuthorized {
            computerAutoContinuationBudget =
                ChatComputerAutoContinuationBudget(
                    maximumSteps:
                        computerAutoContinuationBudget.maximumSteps)
            pendingComputerAutoContinuation = nil
        }
        let pluginDecisionContext =
            recordThreadPluginDecision(for: commandDisplayTurn)
        let dispatchSnapshot = ChatTurnContractEffortResolver.resolve(
            route: snapshotRoute,
            phase: currentTurnScenarioPhase,
            contract: contract,
            uiSelectedEffort: selectedEffort,
            canonicalSourceSlotID: canonicalDispatch.sourceSlotID,
            computerHostDecision: computerHostDecision)
        guard let issuedBinding = contract.identityBindings.first(
            where: { $0.id == canonicalDispatch.bindingID }),
              ChatConfirmedPlanDispatchBindingPolicy.matches(
                snapshotContractID: dispatchSnapshot.contractID,
                snapshotBindingID: dispatchSnapshot.contractBindingID,
                dispatchContractID: canonicalDispatch.contractID,
                dispatchBindingID: canonicalDispatch.bindingID,
                dispatchSourceSlotID: canonicalDispatch.sourceSlotID,
                issuedBindingID: issuedBinding.id,
                issuedSourceSlotID: issuedBinding.sourceSlotID)
        else {
            flashComposerHint(
                "已確認計畫未送出：frozen dispatch snapshot 與 canonical dispatch 不一致。")
            return false
        }
        let commandBaseTurn = turnWithHiddenLoopsContext(
            commandDisplayTurn,
            computerHostDecision: computerHostDecision,
            pluginDecisionContext: pluginDecisionContext,
            attachmentPaths: [],
            includePendingHandoff: false)
        return startTurn(
            displayTurn: commandDisplayTurn,
            commandTurn: turnWithThreadTranscriptContext(
                commandBaseTurn,
                dispatchSnapshot: dispatchSnapshot),
            visibleTurn: commandDisplayTurn,
            attachmentPaths: [],
            previewTurn: "已確認 Plan → Work OS",
            dispatchSnapshot: dispatchSnapshot,
            userMessageAlreadyAppended: true,
            commandBaseTurn: commandBaseTurn)
    }

    /// Codex-style Plan/Goal 與普通 chat 共用同一個 thread/runtime 送出路徑。
    /// suppressUserEcho：授權後自動續跑用——不再把使用者上一句重貼進 transcript。
    @discardableResult
    func submitCurrentChatTurn(
        applyPromptCollaboration: Bool = false,
        suppressUserEcho: Bool = false,
        computerAutoContinuation: Bool = false
    ) -> Bool {
        clearConfirmedPlanComputerHostBlockerBeforeUnrelatedTurnIfNeeded()
        guard coldStartHydrationState == .completed else {
            flashComposerHint("聊天資料仍在載入；訊息尚未送出，請稍候再試。")
            return false
        }
        if selectedThreadID == nil { newChat() }
        // The model picker is the send-time route authority. Capture it before
        // an explicit prompt control updates Work OS identities so collaboration
        // configuration cannot rewrite this turn's dispatch route.
        let snapshotRoute = currentTurnDispatchRoute()
        if applyPromptCollaboration {
            applyPromptDrivenCollaborationIfNeeded()
        }
        let attachmentPaths = droppedPaths
        let attachmentDisplayNames = droppedPathDisplayNames
        let previewTurn = ChatAttachmentTranscript.previewText(
            userText: prompt,
            attachmentPaths: attachmentPaths,
            attachmentDisplayNames: attachmentDisplayNames)
        let commandDisplayTurn = composedTurn(route: snapshotRoute)
        let displayTurn = ChatAttachmentTranscript.displayTurn(
            text: commandDisplayTurn,
            attachmentPaths: attachmentPaths,
            attachmentDisplayNames: attachmentDisplayNames,
            imageStore: imageAssetStore)
        let computerUseRequested = TatwoChatCommandPlanner.requiresTatwoComputerHost(
            for: commandDisplayTurn)
        let computerHostDecision = ChatComputerHostTurnDecision(
            userRequested: computerUseRequested,
            route: TatwoComputerHostTurnRoutingPolicy.select(
                userRequestedComputerUse: computerUseRequested,
                isChatMode: mode == .chat,
                isPlanMode: isPlanModeEnabled,
                route: snapshotRoute.profile))
        if computerHostDecision.isAuthorized && !computerAutoContinuation {
            computerAutoContinuationBudget =
                ChatComputerAutoContinuationBudget(
                    maximumSteps: computerAutoContinuationBudget.maximumSteps)
            pendingComputerAutoContinuation = nil
        }
        let requiresWorkOSContract =
            computerHostDecision.isAuthorized
            || (collaborationIsEnabled
                && !isPlanModeEnabled
                && !isDiscussionSessionSelected)
        if requiresWorkOSContract {
            guard ensureSelectedThreadWorkOSContract(
                objectiveHint: commandDisplayTurn,
                allowCreateIfUnbound: applyPromptCollaboration,
                allowLegacyV1OwnerMigration: applyPromptCollaboration)
            else {
                let reason = selectedWorkOSStateMessage
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                flashComposerHint(
                    reason.isEmpty
                        ? "訊息尚未送出：Work OS session owner 無法驗證。"
                        : reason)
                return false
            }
        }
        if currentChatInteractionMode == .standard,
           pendingSingleModelGoalDispatch != nil
                || pendingNativeDevelopmentDispatch != nil
        {
            switch ChatApprovedTaskOutputRoot.resolve(
                in: commandDisplayTurn)
            {
            case .invalid:
                flashComposerHint(
                    "訊息尚未送出：測試輸出路徑越過 TATWO OS/runtime/sandbox/test allowlist。")
                return false
            case .ambiguous:
                flashComposerHint(
                    "訊息尚未送出：同一執行回合只能指定一個測試輸出資料夾。")
                return false
            case .none, .approved:
                break
            }
        }
        guard prepareBlockedNativeDevelopmentRetryIfNeeded(
            for: commandDisplayTurn,
            route: snapshotRoute)
        else { return false }
        let pluginDecisionContext = isPlanModeEnabled
            ? nil
            : recordThreadPluginDecision(for: commandDisplayTurn)
        let dispatchSnapshot = currentTurnDispatchSnapshot(
            route: snapshotRoute,
            computerHostDecision: computerHostDecision)
        let commandBaseTurn = turnWithHiddenLoopsContext(
            commandDisplayTurn,
            computerHostDecision: computerHostDecision,
            pluginDecisionContext: pluginDecisionContext)
        let accepted: Bool
        if isRunning {
            accepted = enqueueChatTurn(
                displayTurn: displayTurn,
                commandBaseTurn: commandBaseTurn,
                visibleTurn: commandDisplayTurn,
                attachmentPaths: attachmentPaths,
                previewTurn: previewTurn,
                dispatchSnapshot: dispatchSnapshot,
                suppressUserEcho: suppressUserEcho)
        } else {
            accepted = startTurn(
                displayTurn: displayTurn,
                commandTurn: turnWithThreadTranscriptContext(
                    commandBaseTurn,
                    dispatchSnapshot: dispatchSnapshot),
                visibleTurn: commandDisplayTurn,
                attachmentPaths: attachmentPaths,
                previewTurn: previewTurn,
                dispatchSnapshot: dispatchSnapshot,
                userMessageAlreadyAppended: suppressUserEcho,
                commandBaseTurn: commandBaseTurn)
        }
        guard accepted else { return false }
        clearPendingHandoffAfterComposingTurn()
        _ = clearComposerDraftAfterAcceptedSubmission()
        droppedPaths = []
        droppedPathDisplayNames = [:]
        return true
    }

    private func applyPromptDrivenCollaborationIfNeeded() {
        guard !isDiscussionSessionSelected else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intent = Self.promptCollaborationIntent(in: text) else { return }
        let activeConfig = activeLoopsConfig
        let activeTemplate = activeConfig.flatMap { config in
            coworkTemplates.first(where: { $0.scenarioID == config.scenarioID })
        }
        let requestedMode = intent.mode
        let preferredCategory = activeTemplate?.category
            ?? selectedCoworkTemplate?.category
        let template: TatwoCoworkTicketTemplate?
        if let requestedMode,
           activeConfig?.mode != requestedMode {
            template =
                coworkTemplates.first {
                    $0.mode == requestedMode
                        && $0.category == preferredCategory
                }
                ?? coworkTemplates.first(where: { $0.mode == requestedMode })
        } else {
            template = activeTemplate
                ?? selectedCoworkTemplate
                ?? coworkTemplates.first(where: { $0.mode == (requestedMode ?? .m) })
        }
        guard let template = template
            ?? coworkTemplates.first
        else { return }
        selectedCoworkTemplateID = template.id
        var config: TatwoNativeThreadLoopsConfig
        if let activeConfig,
           requestedMode == nil || requestedMode == activeConfig.mode {
            // `$tatwo-ultrawork` is an explicit control surface, but omitted
            // fields are not mutations. Preserve the exact issued topology and
            // apply only primary/secondary/mode deltas named in this turn.
            config = activeConfig
        } else {
            config = loopsConfig(
                for: template,
                mode: requestedMode ?? template.mode)
        }
        if let primary = intent.primaryModelID {
            config.primaryModelID = primary
        }
        if let secondary = intent.secondaryModelID {
            config.secondaryModelID = secondary
        } else if let primary = config.primaryModelID,
                  config.secondaryModelID == primary {
            let candidates = scenarioConfigBook.modeConfig(
                scenarioID: config.scenarioID,
                mode: config.mode
            ).map { Self.modelCandidates(from: $0.bindings) }
                ?? activeLoopsModelCandidates
            config.secondaryModelID = Self.fallbackSecondaryModelID(
                primary: primary,
                candidates: candidates)
        }

        if let preserved = intent.preserveSingleRouteID {
            updateSelectedThreadLoopsConfig(config, syncSingleModelFromLead: false)
            setSingleModel(preserved, syncCollaborationLead: false)
        } else {
            updateSelectedThreadLoopsConfig(config, syncSingleModelFromLead: true)
        }
    }

    private static func promptCollaborationIntent(in rawText: String) -> PromptCollaborationIntent? {
        guard let controlLine = ultraworkControlLine(in: rawText) else { return nil }
        let text = controlLine.lowercased()
        let mentions = modelMentions(in: text)

        var intent = PromptCollaborationIntent()
        intent.mode = promptWorkMode(in: text)
        intent.preserveSingleRouteID = promptPreservedSingleRouteID(in: text)
        intent.primaryModelID = promptPrimaryModelID(in: text, mentions: mentions)
        intent.secondaryModelID = promptSecondaryModelID(in: text, mentions: mentions, primary: intent.primaryModelID)
        return intent
    }

    /// Only an executable `$tatwo-ultrawork` control line may cross the
    /// Chat → Work OS begin boundary. Model names, mode names, quoted history,
    /// or ordinary prose in a long-running thread are conversation content and
    /// must never mint another GoalRun.
    private static func hasExplicitPromptCollaborationControl(
        in rawText: String
    ) -> Bool {
        ultraworkControlLine(in: rawText) != nil
    }

    /// Return one explicit, executable control line only.
    ///
    /// Quoted prose, blockquotes and fenced code are documentation, not
    /// authority. Requiring the marker at the start of the trimmed line also
    /// prevents ordinary sentences from smuggling a control mutation.
    static func ultraworkControlLine(in rawText: String) -> String? {
        let marker = "$tatwo-ultrawork"
        var fenced = false
        for rawLine in rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            let line = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenced.toggle()
                continue
            }
            guard !fenced, !line.hasPrefix(">") else { continue }

            let lower = line.lowercased()
            guard lower.hasPrefix(marker) else { continue }
            let boundaryIndex = lower.index(
                lower.startIndex,
                offsetBy: marker.count)
            if boundaryIndex < lower.endIndex {
                let boundary = lower[boundaryIndex]
                guard boundary.isWhitespace
                    || boundary == ":"
                    || boundary == "："
                    || boundary == "="
                    || boundary == ","
                    || boundary == "，"
                else { continue }
            }

            let directive = String(lower[boundaryIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let leadingNegations = [
                "不要",
                "不啟動",
                "別",
                "停用",
                "取消",
                "do not",
                "don't",
                "don’t",
                "without",
                "not use",
                "off",
                "disable",
                "stop",
            ]
            if leadingNegations.contains(where: {
                directive == $0
                    || directive.hasPrefix("\($0) ")
                    || directive.hasPrefix("\($0)，")
                    || directive.hasPrefix("\($0),")
            }) {
                continue
            }
            if directive.range(
                of: #"(?i)^(?:mode|模式)\s*[:=：]?\s*(?:off|停用|取消)(?:\s|$)"#,
                options: .regularExpression
            ) != nil {
                continue
            }
            return line
        }
        return nil
    }

    private static func modelMentions(in text: String) -> [PromptModelMention] {
        let aliases: [(String, [String])] = [
            ("opus-5", ["opus5", "opus-5", "claude-opus-5", "opus"]),
            ("sonnet-5", ["sonnet5", "sonnet-5", "sonnet 5"]),
            ("gpt-5.5", ["gpt5.5", "gpt-5.5", "gtp5.5", "gtp-5.5", "gpt 5.5"]),
            ("fable-5", ["fable5", "fable-5", "fable 5"]),
            ("minimax-m3", ["minimax-m3", "minimax m3", "minimax"]),
            ("grok-build", ["grok-build", "grok build", "grok"]),
            (
                "haiku-4-5",
                [
                    "haiku4.5",
                    "haiku-4-5",
                    "haiku",
                ])
        ]
        var result: [PromptModelMention] = []
        var seenRanges = Set<String>()
        for (modelID, modelAliases) in aliases {
            for alias in modelAliases {
                var searchStart = text.startIndex
                while searchStart < text.endIndex,
                      let range = text.range(of: alias, range: searchStart..<text.endIndex) {
                    let key = "\(modelID)-\(range.lowerBound.utf16Offset(in: text))"
                    if !seenRanges.contains(key) {
                        result.append(PromptModelMention(modelID: modelID, range: range))
                        seenRanges.insert(key)
                    }
                    searchStart = range.upperBound
                }
            }
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func promptWorkMode(in text: String) -> WorkModeID? {
        // Mode changes are control-plane mutations. Accept only a per-turn
        // directive attached to `$tatwo-ultrawork` (or an explicit mode/模式
        // assignment), never ordinary prose such as "副審", "協作", or "專案".
        let directives: [(String, WorkModeID)] = [
            ("xxl", .xxl),
            ("xl", .xl),
            ("l", .l),
            ("m", .m),
            ("s", .s),
        ]
        for (token, mode) in directives {
            let escaped = NSRegularExpression.escapedPattern(for: token)
            let patterns = [
                "(?i)\\$tatwo-ultrawork\\s*(?:(?:mode|模式)\\s*[:=：]?\\s*)?\(escaped)(?![a-z0-9])",
                "(?i)(?<![a-z0-9_-])(?:mode|模式)\\s*[:=：]\\s*\(escaped)(?![a-z0-9])",
            ]
            if patterns.contains(where: {
                text.range(of: $0, options: .regularExpression) != nil
            }) {
                return mode
            }
        }
        return nil
    }

    private static func containsLooseToken(_ token: String, in text: String) -> Bool {
        text.range(
            of: "(^|[^a-z0-9])\(NSRegularExpression.escapedPattern(for: token))([^a-z0-9]|$)",
            options: .regularExpression
        ) != nil
    }

    private static func promptPreservedSingleRouteID(in text: String) -> String? {
        let hasGPT = text.contains("gpt5.5")
            || text.contains("gpt-5.5")
            || text.contains("gtp5.5")
            || text.contains("gtp-5.5")
        let priority = text.contains("對話優先")
            || text.contains("仍為對話")
            || text.contains("conversation priority")
            || text.contains("chat priority")
        return hasGPT && priority ? "gpt-5.5" : nil
    }

    private static func promptPrimaryModelID(in text: String, mentions: [PromptModelMention]) -> String? {
        if let explicit = mentions.first(where: { mentionHasPrimaryMarker($0, in: text) }) {
            return explicit.modelID
        }
        if let afterBy = firstMention(after: "由", in: text, mentions: mentions) {
            return afterBy.modelID
        }
        if mentions.contains(where: { $0.modelID == "opus-5" }),
           mentions.contains(where: { $0.modelID == "sonnet-5" }) {
            return "opus-5"
        }
        return mentions.first?.modelID
    }

    private static func promptSecondaryModelID(in text: String, mentions: [PromptModelMention], primary: String?) -> String? {
        if let explicit = mentions.first(where: { $0.modelID != primary && mentionHasSecondaryMarker($0, in: text) }) {
            return explicit.modelID
        }
        if let primary,
           let primaryIndex = mentions.firstIndex(where: { $0.modelID == primary }),
           let next = mentions.dropFirst(primaryIndex + 1).first(where: { $0.modelID != primary }) {
            return next.modelID
        }
        return mentions.first(where: { $0.modelID != primary })?.modelID
    }

    private static func firstMention(after marker: String, in text: String, mentions: [PromptModelMention]) -> PromptModelMention? {
        guard let markerRange = text.range(of: marker) else { return nil }
        return mentions.first { $0.range.lowerBound >= markerRange.upperBound }
    }

    private static func mentionHasPrimaryMarker(_ mention: PromptModelMention, in text: String) -> Bool {
        trailingText(after: mention.range, in: text, limit: 12).contains("主")
            || trailingText(after: mention.range, in: text, limit: 16).contains("lead")
            || trailingText(after: mention.range, in: text, limit: 18).contains("primary")
    }

    private static func mentionHasSecondaryMarker(_ mention: PromptModelMention, in text: String) -> Bool {
        trailingText(after: mention.range, in: text, limit: 12).contains("副")
            || trailingText(after: mention.range, in: text, limit: 12).contains("輔")
            || trailingText(after: mention.range, in: text, limit: 18).contains("review")
    }

    private static func trailingText(after range: Range<String.Index>, in text: String, limit: Int) -> String {
        let end = text.index(range.upperBound, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[range.upperBound..<end])
    }

    private static func fallbackSecondaryModelID(primary: String?, candidates: [String]) -> String? {
        candidates.first { $0 != primary } ?? (primary == "sonnet-5" ? "gpt-5.5" : "sonnet-5")
    }

    var currentTurnScenarioPhase: TatwoScenarioPhase {
        if let pending = pendingNativeDevelopmentDispatch,
           pending.status == .running,
           pending.contractID == selectedWorkOSContract?.contractID
        {
            // The exact running dispatch is stronger execution authority than
            // a lagging PLG/UI projection. `/goal` creates this record before
            // composing the executor turn, so that same turn must resolve the
            // loops binding rather than fall back to the plan binding.
            return .loops
        }
        if isPlanModeEnabled {
            return .plan
        }
        switch selectedGoalRecord?.status ?? selectedWorkOSContract?.goalRun.status {
        case .dispatching?, .running?:
            return .loops
        case .succeeded?, .failed?, .cancelled?, .humanGate?,
             .awaitingNextCycle?, .blocked?, .passed?, .rollbackRequired?,
             .superseded?:
            return .goal
        case .planned?, nil:
            break
        }
        if let phase = activePLGRun?.phase {
            switch phase {
            case .planning, .leadAdversarial, .awaitingHumanAuth:
                return .plan
            case .executingLoops, .branchesReporting:
                return .loops
            case .mainlineGoalCheck, .passed, .rollbackRequired:
                return .goal
            }
        }
        return selectedGoalRecord == nil && selectedWorkOSContract == nil
            ? .loops : .plan
    }
}
