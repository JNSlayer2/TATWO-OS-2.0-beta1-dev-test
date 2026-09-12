import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    // MARK: - 切換 UI 重做（模式拉桿過濾情境 + 展示完整 loops 團隊）

    /// 目前協作模式：優先拉桿的 workMode，否則沿用已選情境的宣告模式。
    var currentCollaborationMode: WorkModeID? {
        collaborationLevel.workMode ?? selectedCoworkTemplate?.mode
    }

    /// 只列出「符合目前模式」的情境（拉桿過濾）；同模式可有多個團隊（如 L 有 fable5/sol 兩隊）。
    var currentModeTemplates: [TatwoCoworkTicketTemplate] {
        guard let mode = currentCollaborationMode else { return coworkTemplates }
        let matching = coworkTemplates.filter { $0.mode == mode }
        return matching.isEmpty ? coworkTemplates : matching
    }

    func loopsTeam(scenarioID: String, mode: WorkModeID) -> LoopsTeamDisplay {
        guard let modeConfig = scenarioConfigBook.modeConfig(scenarioID: scenarioID, mode: mode) else {
            return LoopsTeamDisplay()
        }
        func uniq(_ xs: [String]) -> [String] {
            var seen = Set<String>(); return xs.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        var team = LoopsTeamDisplay()
        for b in modeConfig.bindings {
            switch b.identityKind {
            case .lead: team.lead.append(contentsOf: b.boundModelIDs)
            case .supervisor: team.reviewer.append(contentsOf: b.boundModelIDs)
            case .sub: team.sub.append(contentsOf: b.boundModelIDs)
            default: break
            }
        }
        team.lead = uniq(team.lead); team.reviewer = uniq(team.reviewer); team.sub = uniq(team.sub)
        return team
    }

    /// 目前選中情境在目前模式下的完整團隊。
    var activeLoopsTeam: LoopsTeamDisplay {
        guard let mode = currentCollaborationMode,
              let scenarioID = activeLoopsConfig?.scenarioID ?? selectedCoworkTemplate?.scenarioID
        else { return LoopsTeamDisplay() }
        return loopsTeam(scenarioID: scenarioID, mode: mode)
    }

    var filteredProjects: [TatwoNativeChatProject] {
        let query = normalizedSearch
        let activeProjects = document.projects.map { project in
            var copy = project
            copy.threads = project.threads.filter { !$0.isArchived }
            return copy
        }
        guard !query.isEmpty else { return activeProjects }
        return document.projects.compactMap { project in
            var copy = project
            let activeThreads = project.threads.filter { !$0.isArchived }
            let projectMatches = project.name.localizedCaseInsensitiveContains(query) || project.workdir.localizedCaseInsensitiveContains(query)
            copy.threads = activeThreads.filter { thread in
                projectMatches || thread.title.localizedCaseInsensitiveContains(query) || thread.lastPreview.localizedCaseInsensitiveContains(query)
            }
            return projectMatches || !copy.threads.isEmpty ? copy : nil
        }
    }

    var filteredStandaloneThreads: [TatwoNativeChatThread] {
        let activeThreads = document.threads.filter { !$0.isArchived }
        let query = normalizedSearch
        let filtered = query.isEmpty
            ? activeThreads
            : activeThreads.filter { thread in
                thread.title.localizedCaseInsensitiveContains(query)
                    || thread.lastPreview.localizedCaseInsensitiveContains(query)
            }
        return filtered.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return threadActivityDate(lhs) > threadActivityDate(rhs)
        }
    }

    func threadActivityDate(_ thread: TatwoNativeChatThread) -> Date {
        TatwoUnifiedSessionActivityProjection.activityDate(
            threadID: thread.id.uuidString.lowercased(),
            fallback: thread.updatedAt,
            latestActivityByThreadID: latestLedgerActivityByThreadID)
    }

    var sidebarStandaloneThreads: [TatwoNativeChatThread] {
        Array(filteredStandaloneThreads.filter { !$0.isPinned }.prefix(normalizedSearch.isEmpty ? 8 : 18))
    }

    var pinnedThreadRefs: [ChatSidebarThreadRef] {
        // Codex parity: a Project is a source container, not a tag. Project
        // child threads must stay visible under their project tree even when
        // pinned; otherwise the project falsely looks empty and behaves like a
        // generic thread bucket. The global pinned rail is therefore only a
        // shortcut rail for standalone chats.
        let standalone = filteredStandaloneThreads
            .filter(\.isPinned)
            .map { ChatSidebarThreadRef(project: nil, thread: $0) }
        return Array(standalone
            .sorted { lhs, rhs in
                threadActivityDate(lhs.thread) > threadActivityDate(rhs.thread)
            }
            .prefix(8))
    }

    var hasAnyProject: Bool { !document.projects.isEmpty }
    var hasAnyStandaloneThread: Bool { !document.threads.isEmpty }
    var projectCount: Int { document.projects.count }
    var threadCount: Int {
        document.threads.filter { !$0.isArchived }.count + document.projects.reduce(0) { count, project in
            count + project.threads.filter { !$0.isArchived }.count
        }
    }
    var archivedThreadCount: Int {
        document.threads.filter(\.isArchived).count + document.projects.reduce(0) { count, project in
            count + project.threads.filter(\.isArchived).count
        }
    }

    var selectedProjectName: String {
        isSelectedThreadStandalone ? "一般聊天" : (selectedProject?.name ?? "尚無專案")
    }

    var selectedProjectInitial: String {
        let source = selectedProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.first.map { String($0).uppercased() } ?? "—"
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var selectedCoworkTemplate: TatwoCoworkTicketTemplate? {
        coworkTemplates.first(where: { $0.id == selectedCoworkTemplateID }) ?? coworkTemplates.first
    }

    func loopsConfig(for template: TatwoCoworkTicketTemplate, mode overrideMode: WorkModeID? = nil) -> TatwoNativeThreadLoopsConfig {
        let mode = overrideMode ?? template.mode
        let modeConfig = scenarioConfigBook.modeConfig(scenarioID: template.scenarioID, mode: mode)
        let bindings = modeConfig?.bindings ?? template.identityBindings
        let identitySummary = Self.identitySummary(from: bindings)
        return TatwoNativeThreadLoopsConfig(
            scenarioID: template.scenarioID,
            mode: mode,
            identitySummary: identitySummary,
            tokenBudget: modeConfig?.tokenBudget ?? template.tokenBudget,
            // nil means "use the scenario's full declared topology". Persist a
            // route override only after the user explicitly changes a picker;
            // otherwise a two-picker projection would collapse reviewer/sub
            // bindings that the scenario contract represents independently.
            primaryModelID: nil,
            secondaryModelID: nil)
    }

    /// Rehydrate the visible collaboration state from the issued contract
    /// without collapsing its full identity topology into the two legacy
    /// primary/secondary picker scalars. Only a user-issued route override is
    /// round-tripped into those mutable scalar fields.
    func loopsConfig(
        materializing contract: TatwoWorkOSContractV1
    ) -> TatwoNativeThreadLoopsConfig {
        let identitySummary = contract.identityBindings
            .compactMap { binding -> String? in
                guard let modelID = binding.modelID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !modelID.isEmpty
                else { return nil }
                return "\(binding.identity.rawValue)=\(modelID)"
            }
            .prefix(4)
            .joined(separator: "；")
        let modeConfig = scenarioConfigBook.modeConfig(
            scenarioID: contract.scenario,
            mode: contract.mode)
        return TatwoNativeThreadLoopsConfig(
            scenarioID: contract.scenario,
            mode: contract.mode,
            identitySummary: identitySummary.isEmpty
                ? "active contract \(contract.contractID)"
                : identitySummary,
            tokenBudget: modeConfig?.tokenBudget ?? "active contract",
            primaryModelID: contract.routeBindingOverride?.primaryModelID,
            secondaryModelID: contract.routeBindingOverride?.secondaryModelID)
    }

    private static func identitySummary(from bindings: [TatwoScenarioIdentityBinding]) -> String {
        let enabled = bindings.filter(\.enabled)
        let source = enabled.isEmpty ? bindings : enabled
        let parts = source.prefix(4).map { binding in
            let models = binding.boundModelIDs.isEmpty ? "未綁定" : binding.boundModelIDs.joined(separator: "/")
            return "\(binding.phase.chineseName):\(binding.identity)=\(models)"
        }
        return parts.isEmpty ? "身份組未設定" : parts.joined(separator: "；")
    }

    static func modelCandidates(from bindings: [TatwoScenarioIdentityBinding]) -> [String] {
        var seen = Set<String>()
        return bindings.flatMap(\.boundModelIDs).filter { modelID in
            guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seen.contains(modelID)
            else { return false }
            seen.insert(modelID)
            return true
        }
    }

    func newChat() {
        guard allowColdStartDocumentMutation() else { return }
        if TatwoNewChatCommandCenter.isDispatchingUserOwnedRequest {
            createUserOwnedChat()
        } else {
            createDedicatedCollaborationChat()
        }
    }

    func createUserOwnedChat() {
        createNewChat(
            loopsConfig: nil,
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned)
    }

    private func createDedicatedCollaborationChat() {
        // A dedicated Chat created from an active Ultrawork thread keeps only
        // the requested collaboration topology. Contract/Goal identity remains
        // row-local and must be re-established through the canonical
        // current-session owner gate before the first turn can be accepted.
        let inheritedLoopsConfig = selectedThread?.loopsConfig
        createNewChat(
            loopsConfig: inheritedLoopsConfig,
            sourceMarker: inheritedLoopsConfig == nil
                ? TatwoNativeChatThreadSourceMarker.userOwned
                : nil)
    }

    private func createNewChat(
        loopsConfig: TatwoNativeThreadLoopsConfig?,
        sourceMarker: String?
    ) {
        preserveCurrentMessages()
        var doc = document
        let thread = TatwoNativeChatThread(
            title: "新聊天",
            sourceMarker: sourceMarker,
            isPinned: false,
            lastPreview: "",
            loopsConfig: loopsConfig)
        doc.threads.insert(thread, at: 0)
        document = doc
        if isRunning {
            persistStore()
            flashComposerHint("已新增下一個聊天；目前回覆會在背景繼續，可立即切換。")
            return
        }
        selectStandaloneThread(thread.id)
        persistStore()
    }

    func currentSessionStableKey() -> String {
        selectedSessionReference?.stableKey ?? "unbound"
    }

    var isForegroundTurnMutation: Bool {
        transcriptMutationReference == nil
            || transcriptMutationReference == selectedSessionReference
    }

    func sessionIsActivelyStreaming(
        _ reference: TatwoNativeChatSessionReference
    ) -> Bool {
        if isRunning, selectedSessionReference == reference {
            return true
        }
        return parkedTurnBySessionKey[reference.stableKey]?.isRunning == true
    }

    private func captureParkedTurn(
        reference: TatwoNativeChatSessionReference
    ) -> ChatParkedTurnRuntime {
        ChatParkedTurnRuntime(
            sessionReference: reference,
            isRunning: isRunning,
            activeAssistantID: activeAssistantID,
            activeTurnLifecycle: activeTurnLifecycle,
            activeTurnDispatchSnapshot: activeTurnDispatchSnapshot,
            activeTurnExecutionProvenance: activeTurnExecutionProvenance,
            streamLedger: streamLedger,
            userStopRequested: userStopRequested,
            cancellationBlockedReason: cancellationBlockedReason,
            liveWorkActivities: liveWorkActivities,
            chatActivityFeed: chatActivityFeed,
            chatActivityFeedReducer: chatActivityFeedReducer,
            activePlanTurnBinding: activePlanTurnBinding,
            pendingSingleModelGoalDispatch: pendingSingleModelGoalDispatch,
            activeSingleModelGoalDispatch: activeSingleModelGoalDispatch,
            pendingNativeDevelopmentDispatch: pendingNativeDevelopmentDispatch,
            activeNativeDevelopmentDispatch: activeNativeDevelopmentDispatch,
            activeGatewayContinuationTurn: activeGatewayContinuationTurn,
            pendingComputerAutoContinuation: pendingComputerAutoContinuation)
    }

    private func applyParkedTurn(_ parked: ChatParkedTurnRuntime) {
        isRunning = parked.isRunning
        activeAssistantID = parked.activeAssistantID
        activeTurnLifecycle = parked.activeTurnLifecycle
        activeTurnDispatchSnapshot = parked.activeTurnDispatchSnapshot
        activeTurnExecutionProvenance = parked.activeTurnExecutionProvenance
        streamLedger = parked.streamLedger
        userStopRequested = parked.userStopRequested
        cancellationBlockedReason = parked.cancellationBlockedReason
        liveWorkActivities = parked.liveWorkActivities
        chatActivityFeed = parked.chatActivityFeed
        chatActivityFeedReducer = parked.chatActivityFeedReducer
        activePlanTurnBinding = parked.activePlanTurnBinding
        pendingSingleModelGoalDispatch = parked.pendingSingleModelGoalDispatch
        activeSingleModelGoalDispatch = parked.activeSingleModelGoalDispatch
        pendingNativeDevelopmentDispatch = parked.pendingNativeDevelopmentDispatch
        activeNativeDevelopmentDispatch = parked.activeNativeDevelopmentDispatch
        activeGatewayContinuationTurn = parked.activeGatewayContinuationTurn
        pendingComputerAutoContinuation = parked.pendingComputerAutoContinuation
    }

    private func resetForegroundTurnToIdle() {
        isRunning = false
        activeAssistantID = nil
        activeTurnLifecycle = nil
        activeTurnDispatchSnapshot = nil
        activeTurnExecutionProvenance = nil
        streamLedger = StreamTranscriptLedger()
        userStopRequested = false
        cancellationBlockedReason = nil
        liveWorkActivities = []
        chatActivityFeedReducer = ChatActivityFeedReducer(maxVisibleCompleted: 12)
        chatActivityFeed = chatActivityFeedReducer.feed
        activePlanTurnBinding = nil
        pendingSingleModelGoalDispatch = nil
        activeSingleModelGoalDispatch = nil
        pendingNativeDevelopmentDispatch = nil
        activeNativeDevelopmentDispatch = nil
        activeGatewayContinuationTurn = nil
        pendingComputerAutoContinuation = nil
    }

    private var hasForegroundTurnRuntimeState: Bool {
        isRunning
            || activeTurnLifecycle != nil
            || pendingSingleModelGoalDispatch != nil
            || activeSingleModelGoalDispatch != nil
            || pendingNativeDevelopmentDispatch != nil
            || activeNativeDevelopmentDispatch != nil
    }

    func singleModelGoalDispatchRuntimeContractIDs(
        dispatchID: String
    ) -> Set<String> {
        var contractIDs: Set<String> = []
        if let bound = singleModelGoalDispatchContractIDByDispatchID[dispatchID] {
            contractIDs.insert(bound)
        }
        if let pending = pendingSingleModelGoalDispatch,
           pending.id == dispatchID
        {
            contractIDs.insert(pending.contractID)
        }
        if let active = activeSingleModelGoalDispatch,
           active.dispatchID == dispatchID
        {
            contractIDs.insert(active.contractID)
        }
        for parked in parkedTurnBySessionKey.values {
            if let pending = parked.pendingSingleModelGoalDispatch,
               pending.id == dispatchID
            {
                contractIDs.insert(pending.contractID)
            }
            if let active = parked.activeSingleModelGoalDispatch,
               active.dispatchID == dispatchID
            {
                contractIDs.insert(active.contractID)
            }
        }
        return contractIDs
    }

    func singleModelGoalRunnerInstanceID(
        dispatchID: String
    ) -> UUID? {
        if let active = activeSingleModelGoalDispatch,
           active.dispatchID == dispatchID
        {
            return active.runnerInstanceID
        }
        return parkedTurnBySessionKey.values.compactMap { parked in
            guard let active = parked.activeSingleModelGoalDispatch,
                  active.dispatchID == dispatchID
            else { return nil }
            return active.runnerInstanceID
        }.first
    }

    func registerSingleModelGoalDeferredStartSettlementIfActive(
        dispatchID: String
    ) -> Bool {
        let queuedStartIsPending =
            singleModelGoalDeferredStartAwaitingDispatchIDs
                .contains(dispatchID)
        let remoteStartIsPending =
            pendingRemoteTurnTask != nil
            && pendingRemoteTurnCancellationFence?.isCancelled == false
        guard queuedStartIsPending || remoteStartIsPending,
              pendingSingleModelGoalDispatch?.id == dispatchID,
              singleModelGoalDispatchRuntimeContractIDs(
                dispatchID: dispatchID).count == 1
        else {
            return false
        }
        singleModelGoalDeferredStartAwaitingDispatchIDs.insert(dispatchID)
        return true
    }

    func clearSingleModelGoalDispatchRuntimeState(
        dispatchID: String,
        preserveRunnerStartReceipt: Bool = false
    ) {
        if pendingSingleModelGoalDispatch?.id == dispatchID {
            pendingSingleModelGoalDispatch = nil
        }
        if activeSingleModelGoalDispatch?.dispatchID == dispatchID {
            activeSingleModelGoalDispatch = nil
        }
        for sessionKey in Array(parkedTurnBySessionKey.keys) {
            guard var parked = parkedTurnBySessionKey[sessionKey] else {
                continue
            }
            if parked.pendingSingleModelGoalDispatch?.id == dispatchID {
                parked.pendingSingleModelGoalDispatch = nil
            }
            if parked.activeSingleModelGoalDispatch?.dispatchID == dispatchID {
                parked.activeSingleModelGoalDispatch = nil
            }
            if parked.hasForegroundTurnRuntimeState {
                parkedTurnBySessionKey[sessionKey] = parked
            } else {
                parkedTurnBySessionKey.removeValue(forKey: sessionKey)
            }
        }
        singleModelGoalDispatchContractIDByDispatchID.removeValue(
            forKey: dispatchID)
        if !preserveRunnerStartReceipt {
            singleModelGoalRunnerStartReceiptByDispatchID.removeValue(
                forKey: dispatchID)
        }
        singleModelGoalDeferredStartAwaitingDispatchIDs.remove(dispatchID)
    }

    private func parkForegroundTurnIfNeeded() {
        cancelPendingRemoteSingleModelDeferredStartIfNeeded(
            message:
                "單模型 runner 尚在遠端 claim 檢查期間，thread／session 已切換；"
                + "原 dispatch 已 fail closed。")
        guard let reference = selectedSessionReference else {
            resetForegroundTurnToIdle()
            return
        }
        if hasForegroundTurnRuntimeState {
            parkedTurnBySessionKey[reference.stableKey] =
                captureParkedTurn(reference: reference)
        }
        resetForegroundTurnToIdle()
    }

    private func restoreParkedTurnForCurrentSelection() {
        guard let reference = selectedSessionReference,
              let parked = parkedTurnBySessionKey[reference.stableKey]
        else {
            resetForegroundTurnToIdle()
            return
        }
        applyParkedTurn(parked)
    }

    func isSessionRunning(runID: String) -> Bool {
        if isRunning, activeTurnLifecycle?.runID == runID {
            return true
        }
        return parkedTurnBySessionKey.values.contains {
            $0.isRunning && $0.activeTurnLifecycle?.runID == runID
        }
    }

    func withTurnRuntime(for runID: String, _ body: () -> Void) {
        if activeTurnLifecycle?.runID == runID {
            body()
            if let reference = selectedSessionReference {
                if hasForegroundTurnRuntimeState {
                    parkedTurnBySessionKey[reference.stableKey] =
                        captureParkedTurn(reference: reference)
                } else {
                    parkedTurnBySessionKey.removeValue(forKey: reference.stableKey)
                    sessionKeyByRunID.removeValue(forKey: runID)
                }
            }
            return
        }
        guard let sessionKey = sessionKeyByRunID[runID],
              let parked = parkedTurnBySessionKey[sessionKey],
              parked.activeTurnLifecycle?.runID == runID
        else {
            return
        }
        guard let foregroundReference = selectedSessionReference else {
            return
        }
        let foreground = captureParkedTurn(reference: foregroundReference)
        let foregroundMessages = messages
        applyParkedTurn(parked)
        messages = parkedSessionMessages(for: parked.sessionReference)
        transcriptMutationReference = parked.sessionReference
        body()
        let updated = captureParkedTurn(reference: parked.sessionReference)
        if updated.hasForegroundTurnRuntimeState {
            parkedTurnBySessionKey[sessionKey] = updated
        } else {
            parkedTurnBySessionKey.removeValue(forKey: sessionKey)
            sessionKeyByRunID.removeValue(forKey: runID)
        }
        messageCache[parked.sessionReference] = messages
        applyParkedTurn(foreground)
        messages = foregroundMessages
        transcriptMutationReference = nil
    }

    func processRunnerForTurnStart() -> ChatCLIProcessRunner {
        let key = currentSessionStableKey()
        if let existing = cliRunnersBySessionKey[key] {
            return existing
        }
        if !cliRunnersBySessionKey.values.contains(where: { $0 === runner }) {
            cliRunnersBySessionKey[key] = runner
            return runner
        }
        let extra = ChatCLIProcessRunner(
            runnerAuthority:
                runnerAuthorityDiscoverer
                as? any ChatRunnerAuthorityRecording,
            runtimeGovernor: .shared,
            runtimeRootURL: chatCLIRuntimeRootURL.appendingPathComponent(
                "session-\(key.replacingOccurrences(of: ":", with: "-"))",
                isDirectory: true),
            runtimeSweepGate: ChatCLIRuntimeSweepGate())
        cliRunnersBySessionKey[key] = extra
        return extra
    }

    func nativeAgentRunnerForTurnStart() -> any ChatNativeAgentRunning {
        let key = currentSessionStableKey()
        if let existing = nativeRunnersBySessionKey[key] {
            return existing
        }
        if usesInjectedNativeRunner || nativeRunnersBySessionKey.isEmpty {
            nativeRunnersBySessionKey[key] = nativeRunner
            return nativeRunner
        }
        let extra: any ChatNativeAgentRunning
        if TatwoNativeAgentRunnerBuildConfiguration.useGovernedDevSessionRunner {
            extra = GovernedDevSessionRunner(
                journalDirectoryURL: nativeAgentJournalDirectoryURL
                    .appendingPathComponent(
                        "session-\(key.replacingOccurrences(of: ":", with: "-"))",
                        isDirectory: true),
                environment: coldStartEnvironment)
        } else {
            extra = ChatNativeAgentRunner(
                approvalStore: TatwoHostApprovalStore.default(
                    environment: coldStartEnvironment),
                journalDirectoryURL: nativeAgentJournalDirectoryURL
                    .appendingPathComponent(
                        "session-\(key.replacingOccurrences(of: ":", with: "-"))",
                        isDirectory: true))
        }
        nativeRunnersBySessionKey[key] = extra
        return extra
    }

    func miniMaxRunnerForTurnStart() -> any MiniMaxChatRunning {
        let key = currentSessionStableKey()
        if let existing = miniMaxRunnersBySessionKey[key] {
            return existing
        }
        if usesInjectedMiniMaxRunner || miniMaxRunnersBySessionKey.isEmpty {
            miniMaxRunnersBySessionKey[key] = miniMaxRunner
            return miniMaxRunner
        }
        let extra = MiniMaxChatRunner(
            client: MiniMaxChatClient(environment: coldStartEnvironment))
        miniMaxRunnersBySessionKey[key] = extra
        return extra
    }

    func terminateRunnersForCurrentSession() {
        let key = currentSessionStableKey()
        cliRunnersBySessionKey[key]?.terminate()
        nativeRunnersBySessionKey[key]?.terminate()
        miniMaxRunnersBySessionKey[key]?.terminate()
    }

    func selectStandaloneThread(
        _ threadID: UUID,
        persistDiscussionSelection: Bool = true,
        recoverConfirmedGoalRevision: Bool = false
    ) {
        guard allowColdStartDocumentMutation() else { return }
        flushCurrentComposerDraft()
        preserveCurrentMessages()
        parkForegroundTurnIfNeeded()
        selectedProjectID = nil
        selectedThreadID = threadID
        selectedDiscussionID = nil
        if persistDiscussionSelection {
            persistSelectedDiscussionID(nil)
        }
        let currentSessionAttachResult: CurrentSessionAttachResult
        if recoverConfirmedGoalRevision {
            currentSessionAttachResult =
                refreshAfterGoalRevisionPromotion()
                ? .attached
                : .quarantined
        } else {
            currentSessionAttachResult =
                attachVerifiedCurrentSessionToSelectedThreadIfEligible()
        }
        let thread = selectedThread
        restoreComposerDraftForCurrentSession()
        restoreActivePLGProjection(from: thread)
        messages = loadedMessagesForSelection(threadID: threadID, thread: thread)
        // Selection is pure journal readback; replay is reserved for explicit
        // external transcript imports and fixture/import construction.
        persistSelectedThreadMessages()
        loadCodexTranscriptIfNeeded(for: thread, threadID: threadID)
        restoreParkedTurnForCurrentSelection()
        syncSessionIDFromSelection()
        refreshGatewayCooldownProjection()
        if let contractID = thread?.workOSContractID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contractID.isEmpty {
            if currentSessionAttachResult.allowsLocalWorkOSStateProjection {
                refreshSelectedWorkOSState(contractID: contractID)
            }
        } else if currentSessionAttachResult.allowsLocalWorkOSStateProjection {
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            selectedWorkOSStateMessage = "此 thread 尚未由 chat request 建立 GoalRun"
        }
        if !isRunning {
            startNextChatIfNeeded()
        }
        Task { @MainActor [weak self] in
            self?.refreshGitBranch()
        }
    }

    func select(
        projectID: UUID,
        threadID: UUID,
        persistDiscussionSelection: Bool = true,
        recoverConfirmedGoalRevision: Bool = false
    ) {
        guard allowColdStartDocumentMutation() else { return }
        flushCurrentComposerDraft()
        preserveCurrentMessages()
        parkForegroundTurnIfNeeded()
        selectedProjectID = projectID
        selectedThreadID = threadID
        selectedDiscussionID = nil
        if persistDiscussionSelection {
            persistSelectedDiscussionID(nil)
        }
        workspacePath = document.projects.first(where: { $0.id == projectID })?.workdir ?? workspacePath
        let currentSessionAttachResult: CurrentSessionAttachResult
        if recoverConfirmedGoalRevision {
            currentSessionAttachResult =
                refreshAfterGoalRevisionPromotion()
                ? .attached
                : .quarantined
        } else {
            currentSessionAttachResult =
                attachVerifiedCurrentSessionToSelectedThreadIfEligible()
        }
        let thread = selectedThread
        restoreComposerDraftForCurrentSession()
        restoreActivePLGProjection(from: thread)
        messages = loadedMessagesForSelection(threadID: threadID, thread: thread)
        // Selection must not append a second copy of journal-backed messages.
        persistSelectedThreadMessages()
        loadCodexTranscriptIfNeeded(for: thread, threadID: threadID)
        restoreParkedTurnForCurrentSelection()
        syncSessionIDFromSelection()
        refreshGatewayCooldownProjection()
        if let contractID = thread?.workOSContractID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !contractID.isEmpty
        {
            if currentSessionAttachResult.allowsLocalWorkOSStateProjection {
                refreshSelectedWorkOSState(contractID: contractID)
            }
        } else if currentSessionAttachResult.allowsLocalWorkOSStateProjection {
            selectedWorkOSContract = nil
            selectedGoalRecord = nil
            selectedDispatchRecords = []
            selectedWorkOSStateMessage = "此 thread 尚未由 chat request 建立 GoalRun"
        }
        if !isRunning {
            startNextChatIfNeeded()
        }
        Task { @MainActor [weak self] in
            self?.refreshGitBranch()
        }
    }

    func selectDiscussion(
        projectID: UUID?,
        threadID: UUID,
        discussionID: UUID,
        persistDiscussionSelection: Bool = true
    ) {
        guard allowColdStartDocumentMutation() else { return }
        if let projectID {
            select(
                projectID: projectID,
                threadID: threadID,
                persistDiscussionSelection: false)
        } else {
            selectStandaloneThread(
                threadID,
                persistDiscussionSelection: false)
        }
        parkForegroundTurnIfNeeded()
        selectedDiscussionID = discussionID
        selectedLoopsSessionID = nil
        guard let discussion = selectedDiscussion else {
            selectedDiscussionID = nil
            restoreParkedTurnForCurrentSelection()
            return
        }
        if persistDiscussionSelection {
            persistSelectedDiscussionID(discussion.id)
        }
        restoreComposerDraftForCurrentSession()
        let reference = TatwoNativeChatSessionReference(kind: .discussion, id: discussion.id)
        messages = loadedMessagesForSelection(reference: reference, stored: discussion.messages)
        // Discussion selection is also a pure journal projection read.
        persistSelectedThreadMessages()
        restoreParkedTurnForCurrentSelection()
        syncSessionIDFromSelection()
        // A child discussion never rehydrates or mutates the parent's PLG
        // projection. Branch-local loops remain visible in their own rail.
        activePLGRun = nil
        appliedPLGEventIDs = []
        plgAuthorityState = .none
        plgError = nil
    }

    private func loadCodexTranscriptIfNeeded(for thread: TatwoNativeChatThread?, threadID: UUID) {
        guard messages.filter({ !$0.isTranscriptNoise }).isEmpty,
              let bridge = codexAppStateBridge,
              let codexSessionID = thread?.codexSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codexSessionID.isEmpty
        else { return }

        Task { @MainActor [weak self] in
            let records = await Task.detached(priority: .utility) {
                (try? bridge.loadTranscript(threadID: codexSessionID, maxMessages: 64)) ?? []
            }.value
            guard let self,
                  self.selectedThreadID == threadID,
                  self.selectedDiscussionID == nil,
                  self.messages.filter({ !$0.isTranscriptNoise }).isEmpty,
                  !records.isEmpty
            else { return }
            let importedMessages = records.map(ChatMessage.init(stored:))
            self.messages = importedMessages
            self.messageCache[TatwoNativeChatSessionReference(kind: .thread, id: threadID)] = importedMessages
            self.replaySelectedTranscriptMessages()
        }
    }

    func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        guard allowColdStartDocumentMutation() else { return }
        guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        document.projects[index].isExpanded = isExpanded
        persistStore()
    }

    func setGitHubRepoBinding(
        _ binding: TatwoGitHubRepoBinding,
        for projectID: UUID
    ) {
        guard allowColdStartDocumentMutation() else { return }
        guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        document.projects[index].githubRepo = binding
        githubRepoCheckMessageProjectID = nil
        githubRepoCheckMessage = nil
        publishDocumentChangeAndPersist()
    }

    func isCheckingGitHubRepo(for projectID: UUID) -> Bool {
        githubRepoCheckingProjectID == projectID
    }

    func gitHubRepoCheckMessage(for projectID: UUID) -> String? {
        githubRepoCheckMessageProjectID == projectID ? githubRepoCheckMessage : nil
    }

    func setGitHubRepoBindings(
        _ bindings: [TatwoGitHubRepoBinding],
        for projectID: UUID
    ) {
        guard allowColdStartDocumentMutation() else { return }
        guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        document.projects[index].githubRepos = bindings
        githubRepoCheckMessageProjectID = nil
        githubRepoCheckMessage = nil
        publishDocumentChangeAndPersist()
    }

    /// Checks every bound repo of the project (2026-09-02: a project may bind
    /// several repos / accounts). Each binding keeps its own hasUpdate flag.
    func checkGitHubRepoUpdates(for projectID: UUID) {
        guard allowColdStartDocumentMutation() else { return }
        guard githubRepoCheckingProjectID == nil,
              let project = document.projects.first(where: { $0.id == projectID }),
              !project.githubRepos.isEmpty
        else { return }

        githubRepoCheckingProjectID = projectID
        githubRepoCheckMessageProjectID = nil
        githubRepoCheckMessage = nil
        let checkedURLs = project.githubRepos.map(\.url)
        let workdir = project.workdir

        Task { @MainActor [weak self] in
            var results: [(url: String, result: GitHubRepoUpdateCheckResult)] = []
            for url in checkedURLs {
                results.append((url, await GitHubRepoUpdateChecker.check(url: url, workdir: workdir)))
            }
            guard let self else { return }
            defer {
                if self.githubRepoCheckingProjectID == projectID {
                    self.githubRepoCheckingProjectID = nil
                }
            }
            guard self.coldStartDocumentMutationAllowed else { return }
            guard let index = self.document.projects.firstIndex(where: { $0.id == projectID }) else { return }

            let stamp = ISO8601DateFormatter().string(from: Date())
            var updated = 0
            var upToDate = 0
            var failed: [String] = []
            var repos = self.document.projects[index].githubRepos
            for (url, result) in results {
                guard let bindingIndex = repos.firstIndex(where: { $0.url == url }) else { continue }
                switch result {
                case .upToDate:
                    repos[bindingIndex].hasUpdate = false
                    repos[bindingIndex].lastCheckedISO = stamp
                    upToDate += 1
                case .updateAvailable:
                    repos[bindingIndex].hasUpdate = true
                    repos[bindingIndex].lastCheckedISO = stamp
                    updated += 1
                case .credentialUnavailable:
                    failed.append("\(url)（缺憑證）")
                case .unavailable:
                    failed.append(url)
                }
            }
            self.document.projects[index].githubRepos = repos
            self.githubRepoCheckMessageProjectID = projectID
            var parts: [String] = []
            if updated > 0 { parts.append("\(updated) 個倉庫有新提交") }
            if upToDate > 0 { parts.append("\(upToDate) 個倉庫沒有新提交") }
            if !failed.isEmpty { parts.append("無法檢查：" + failed.joined(separator: "、")) }
            self.githubRepoCheckMessage = parts.joined(separator: "；")
            if updated + upToDate > 0 { self.publishDocumentChangeAndPersist() }
        }
    }

    /// 回傳新建/更新的專案 id；使用者取消面板或失敗時回 nil（sol Verifier：取消後不可誤加舊選取）。
    @discardableResult
    func createProjectFromExistingFolder() -> UUID? {
        guard allowColdStartDocumentMutation() else { return nil }
        let panel = NSOpenPanel()
        panel.title = "建立專案"
        panel.message = "選擇專案的工作區資料夾"
        panel.prompt = "使用資料夾"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if FileManager.default.fileExists(atPath: workspacePath) {
            panel.directoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        }

        guard TatwoModalPanelGate.run({ panel.runModal() }) == .OK, let selectedURL = panel.urls.first else { return nil }
        return createOrSelectProject(
            folderURL: selectedURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Creates the project for `folderURL` (or selects the existing one) and
    /// lands on its newest thread. Shared by the Finder panel flow and the
    /// automation seam (`tatwo.app.chat.create_project`).
    func createOrSelectProject(folderURL: URL, preferredName: String? = nil) -> UUID? {
        guard allowColdStartDocumentMutation() else { return nil }
        let workdir = folderURL.path
        let projectName = (preferredName ?? folderURL.lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeProjectName = projectName.isEmpty ? workdir : projectName

        preserveCurrentMessages()
        var doc = document
        let normalizedWorkdir = URL(fileURLWithPath: workdir, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        if let existingIndex = doc.projects.firstIndex(where: { project in
            URL(fileURLWithPath: project.workdir, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path == normalizedWorkdir
        }) {
            doc.projects[existingIndex].name = doc.projects[existingIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? safeProjectName
                : doc.projects[existingIndex].name
            doc.projects[existingIndex].workdir = workdir
            doc.projects[existingIndex].isExpanded = true
            let projectID = doc.projects[existingIndex].id
            let targetThreadID: UUID
            if let newest = doc.projects[existingIndex].threads.filter({ !$0.isArchived }).max(by: { $0.updatedAt < $1.updatedAt }) {
                targetThreadID = newest.id
            } else {
                let thread = TatwoNativeChatThread(
                    title: "新聊天",
                    sourceMarker:
                        TatwoNativeChatThreadSourceMarker.userOwned,
                    isPinned: false,
                    lastPreview: "project thread")
                doc.projects[existingIndex].threads.insert(thread, at: 0)
                targetThreadID = thread.id
            }
            document = doc
            workspacePath = workdir
            select(projectID: projectID, threadID: targetThreadID)
            persistStore()
            registerCreatedProjectRootWithCodexApp(workdir)
            return projectID
        }

        let thread = TatwoNativeChatThread(
            title: "新聊天",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            isPinned: false,
            lastPreview: "project thread")
        let project = TatwoNativeChatProject(
            name: safeProjectName,
            workdir: workdir,
            isExpanded: true,
            threads: [thread])
        doc.projects.insert(project, at: 0)
        document = doc
        workspacePath = workdir
        select(projectID: project.id, threadID: thread.id)
        persistStore()
        registerCreatedProjectRootWithCodexApp(workdir)
        return project.id
    }

    /// New chat inside an existing project (Codex App parity: a project can
    /// hold many threads; each turn runs in the project's workdir).
    @discardableResult
    func createThread(inProject projectID: UUID) -> UUID? {
        guard allowColdStartDocumentMutation() else { return nil }
        preserveCurrentMessages()
        var doc = document
        guard let index = doc.projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let thread = TatwoNativeChatThread(
            title: "新聊天",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            isPinned: false,
            lastPreview: "project thread")
        doc.projects[index].threads.insert(thread, at: 0)
        doc.projects[index].isExpanded = true
        document = doc
        workspacePath = doc.projects[index].workdir
        select(projectID: projectID, threadID: thread.id)
        persistStore()
        return thread.id
    }

    private func registerCreatedProjectRootWithCodexApp(_ workdir: String) {
        guard codexProjectSyncEnabled, let codexAppStateBridge else { return }
        do {
            let receipt = try codexAppStateBridge.registerWorkspaceRoot(workdir)
            if receipt.didChange {
                selectedWorkOSStateMessage = "Codex App 專案根已同步"
            }
        } catch {
            // Project creation in OS Chat must remain usable even if Codex App's
            // optional global-state sync is temporarily unavailable. Keep this
            // as a visible status only; do not create sqlite threads or retry in
            // a loop.
            selectedWorkOSStateMessage = "Codex App 專案根同步失敗：\(error.localizedDescription)"
        }
    }

    func selectedThreadLocation() -> ThreadLocation? {
        guard let selectedThreadID else { return nil }
        if let index = document.threads.firstIndex(where: { $0.id == selectedThreadID }) {
            return .standalone(index)
        }
        if let selectedProjectID,
           let projectIndex = document.projects.firstIndex(where: { $0.id == selectedProjectID }),
           let threadIndex = document.projects[projectIndex].threads.firstIndex(where: { $0.id == selectedThreadID }) {
            return .project(projectIndex: projectIndex, threadIndex: threadIndex)
        }
        for projectIndex in document.projects.indices {
            if let threadIndex = document.projects[projectIndex].threads.firstIndex(where: { $0.id == selectedThreadID }) {
                return .project(projectIndex: projectIndex, threadIndex: threadIndex)
            }
        }
        return nil
    }

    func thread(at location: ThreadLocation) -> TatwoNativeChatThread {
        switch location {
        case .standalone(let index):
            return document.threads[index]
        case .project(let projectIndex, let threadIndex):
            return document.projects[projectIndex].threads[threadIndex]
        }
    }

    func replaceThread(_ thread: TatwoNativeChatThread, at location: ThreadLocation) {
        guard allowColdStartDocumentMutation() else { return }
        switch location {
        case .standalone(let index):
            document.threads[index] = thread
        case .project(let projectIndex, let threadIndex):
            document.projects[projectIndex].threads[threadIndex] = thread
        }
    }

    func toggleSelectedThreadPinned() {
        mutateSelectedThread { thread in
            thread.isPinned.toggle()
            thread.updatedAt = Date()
        }
    }

    func createDiscussionForSelectedThread() {
        _ = createDiscussionForSelectedThread(title: "新討論")
    }

    @discardableResult
    func createDiscussionForSelectedThread(
        title: String
    ) -> UUID? {
        guard allowColdStartDocumentMutation() else { return nil }
        flushCurrentComposerDraft()
        persistSelectedThreadMessages()
        guard let thread = selectedThread else { return nil }
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let discussion = TatwoNativeSessionTree.forkDiscussion(
            from: thread,
            title: normalizedTitle.isEmpty
                ? "新討論"
                : String(normalizedTitle.prefix(64)))
        mutateSelectedThread { thread in
            thread.discussions.insert(discussion, at: 0)
            thread.updatedAt = Date()
        }
        if isRunning {
            flashComposerHint("已建立 #討論串；目前回覆完成後可切入，主線輸出不會寫進支線。")
            return discussion.id
        }
        selectedDiscussionID = discussion.id
        selectedLoopsSessionID = nil
        restoreComposerDraftForCurrentSession()
        messages = []
        persistSelectedDiscussionID(discussion.id)
        syncSessionIDFromSelection()
        return discussion.id
    }

    func compressDiscussion(_ discussionID: UUID) {
        guard allowColdStartDocumentMutation() else { return }
        guard !isRunning else {
            flashComposerHint("目前 session 正在回覆；完成或停止後才能建立 checkpoint。")
            return
        }
        if selectedDiscussionID == discussionID {
            persistSelectedThreadMessages()
        }
        mutateSelectedThread { thread in
            guard let index = thread.discussions.firstIndex(where: { $0.id == discussionID }) else { return }
            let receipt = TatwoNativeSessionTree.checkpoint(for: thread.discussions[index])
            thread.discussions[index].status = .compressed
            thread.discussions[index].checkpointReceipt = receipt
            thread.discussions[index].compressedSummary = receipt.summary
            thread.updatedAt = Date()
        }
    }

    /// Explicitly promotes a child result to the main thread. The child
    /// transcript is never copied wholesale or allowed to overwrite the
    /// parent; the parent receives one immutable receipt message only.
    func mergeDiscussionIntoParent(_ discussionID: UUID) {
        guard allowColdStartDocumentMutation() else { return }
        guard !isRunning else {
            flashComposerHint("目前 session 正在回覆；完成或停止後才能 merge receipt。")
            return
        }
        if selectedDiscussionID == discussionID {
            persistSelectedThreadMessages()
        }
        guard let location = selectedThreadLocation() else { return }
        var thread = thread(at: location)
        guard let index = thread.discussions.firstIndex(where: { $0.id == discussionID }) else { return }
        var discussion = thread.discussions[index]
        let checkpoint = TatwoNativeSessionTree.checkpoint(for: discussion)
        guard let receipt = TatwoNativeSessionTree.mergeReceipt(
            for: discussion,
            checkpoint: checkpoint,
            targetThreadID: thread.id)
        else {
            flashComposerHint("Discussion merge blocked：fork/checkpoint 收據無法驗證。")
            return
        }
        discussion.checkpointReceipt = checkpoint
        if !discussion.mergeReceipts.contains(where: {
            $0.deduplicationKey == receipt.deduplicationKey
        }) {
            discussion.mergeReceipts.append(receipt)
        }
        thread.discussions[index] = discussion

        let receiptText = """
        [Discussion merge receipt]
        mergeKey=\(receipt.deduplicationKey)
        source=\(receipt.sourceSession.stableKey)
        target=\(receipt.targetSession.stableKey)
        forkCheckpoint=\(receipt.forkCheckpointID.uuidString.lowercased())
        sourceCheckpoint=\(receipt.sourceCheckpointID.uuidString.lowercased())
        sourceSHA256=\(receipt.sourceTranscriptSHA256)
        summary=\(receipt.summary)
        """
        let receiptRecord = TatwoNativeChatStoredMessage(
            role: "system",
            text: receiptText,
            status: "merge-receipt",
            eventKind: .message)
        let alreadyMerged = (thread.messages ?? []).contains {
            $0.text.contains("mergeKey=\(receipt.deduplicationKey)")
        }
        if !alreadyMerged {
            guard recordCanonicalStoredMessages(
                [receiptRecord],
                reference: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id))
            else {
                flashComposerHint("Discussion merge blocked：canonical transcript journal 無法落盤。")
                return
            }
            var parentMessages = thread.messages ?? []
            parentMessages.append(receiptRecord)
            thread.messages = Array(parentMessages.suffix(120))
        }
        thread.lastPreview = "Discussion merged · \(receipt.summary)"
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        publishDocumentChangeAndPersist()
        flashComposerHint("Discussion 已明確 merge 為 receipt；主線未被子 session 自動覆寫。")
    }

    @MainActor
    func requestRenameSelectedThread() {
        guard let title = selectedThread?.title else { return }
        let alert = NSAlert()
        alert.messageText = "重新命名對話串"
        alert.informativeText = "只改 Tatwo Chat store 的 thread title，不改檔、不碰 Codex App。"
        alert.addButton(withTitle: "重新命名")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(string: title)
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        let result = TatwoModalPanelGate.run({ alert.runModal() })
        guard result == .alertFirstButtonReturn else { return }
        renameSelectedThread(to: input.stringValue)
    }

    @MainActor
    func copySelectedThreadSummary() {
        let summary = [
            "Thread: \(selectedThread?.title ?? "未命名 thread")",
            "Project: \(selectedProjectName)",
            "Preview: \(selectedThread?.lastPreview ?? "")",
            "Contract: \(selectedWorkOSContractShortID)",
            "Plugins: \(selectedThreadPluginSummary)"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    func duplicateSelectedThread(asBranch: Bool) {
        guard allowColdStartDocumentMutation() else { return }
        guard let location = selectedThreadLocation() else { return }
        persistSelectedThreadMessages()
        let source = thread(at: location)
        let now = Date()
        var copy = source
        copy.id = UUID()
        copy.title = asBranch ? "\(source.title) · branch" : "\(source.title) · copy"
        copy.createdAt = now
        copy.updatedAt = now
        copy.isPinned = false
        copy.isPlanModeEnabled = false
        copy.cliSessionID = nil
        copy.codexSessionID = nil
        copy.codexCLISessionID = nil
        copy.claudeSessionID = nil
        copy.adapterSessionHandles = []
        copy.workOSGoalID = nil
        copy.workOSContractID = nil
        copy.selectedThreadWorkOSContext = nil
        copy.activePLGRunProjection = nil
        // A duplicated main thread keeps its visible transcript, but it must
        // not reuse child session UUIDs, parent-bound loops, or provider
        // handles from the source branch.
        copy.discussions = []
        copy.loopsSessions = []
        copy.lastPreview = asBranch ? "Branch from \(source.title)" : "Copied from \(source.title)"
        guard recordCanonicalStoredMessages(
            copy.messages ?? [],
            reference: TatwoNativeChatSessionReference(kind: .thread, id: copy.id))
        else {
            flashComposerHint("無法建立聊天副本：canonical transcript journal 無法落盤。")
            return
        }
        switch location {
        case .standalone(let threadIndex):
            document.threads.insert(copy, at: threadIndex + 1)
        case .project(let projectIndex, let threadIndex):
            document.projects[projectIndex].threads.insert(copy, at: threadIndex + 1)
        }
        persistStore()
        if isRunning {
            flashComposerHint(asBranch
                ? "已建立 branch；目前回覆完成後可切換，不會混入正在執行的 session。"
                : "已建立聊天副本；目前回覆完成後可切換。")
            return
        }
        switch location {
        case .standalone:
            selectStandaloneThread(copy.id)
        case .project(let projectIndex, _):
            select(projectID: document.projects[projectIndex].id, threadID: copy.id)
        }
    }

    func reloadPluginRegistry() {
        pluginRegistryBook = (try? pluginRegistryStore.load()) ?? TatwoPluginRegistryBookV1().normalizedForCurrentDefaults()
    }

    func isThreadPluginEnabled(_ entryID: String) -> Bool {
        selectedThreadPluginIDs.contains(entryID)
    }

    func setThreadPlugin(_ entryID: String, enabled: Bool) {
        guard selectedThreadID != nil else { return }
        let ids = TatwoThreadPluginDecisionContextComposer.setThreadPluginID(
            entryID,
            enabled: enabled,
            currentIDs: selectedThreadPluginIDs,
            registry: pluginRegistryBook)
        updateSelectedThreadPluginIDs(ids)
    }

    /// `$skill` 建議鍵盤操作。
    func handleSkillSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let suggestions = skillSuggestions
        switch key {
        case .next:
            guard !suggestions.isEmpty else { return false }
            skillSuggestionSelectedIndex = ChatComposerSuggestionSelection.next(
                current: skillSuggestionSelectedIndex,
                count: suggestions.count)
            return true
        case .prev:
            guard skillSuggestionSelectedIndex != nil else { return false }
            skillSuggestionSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: skillSuggestionSelectedIndex,
                count: suggestions.count)
            return true
        case .commit:
            guard let cur = skillSuggestionSelectedIndex, cur < suggestions.count else { return false }
            applySkillSuggestion(suggestions[cur]) // 內部改 prompt → didSet 會重置高亮
            return true
        }
    }

    /// `/` 與 `$` 共用同一套鍵盤語意：→/↓ 下一個、←/↑ 上一個、Enter 插入。
    func handleSlashSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let suggestions = matchingSlashCommands
        switch key {
        case .next:
            guard !suggestions.isEmpty else { return false }
            slashCommandSelectedIndex = ChatComposerSuggestionSelection.next(
                current: slashCommandSelectedIndex,
                count: suggestions.count)
            return true
        case .prev:
            guard slashCommandSelectedIndex != nil else { return false }
            slashCommandSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: slashCommandSelectedIndex,
                count: suggestions.count)
            return true
        case .commit:
            guard let current = slashCommandSelectedIndex,
                  current < suggestions.count
            else { return false }
            applySlashCommandSuggestion(suggestions[current])
            return true
        }
    }

    func handleComposerSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        if issueAtMentionQuery != nil, !issueAtMentionMatches.isEmpty {
            return handleIssueMentionKey(key)
        }
        if !matchingSlashCommands.isEmpty {
            return handleSlashSuggestionKey(key)
        }
        return handleSkillSuggestionKey(key)
    }

    /// @ 搜尋清單鍵盤選取：↑↓ 移動、Enter 釘選（未按過 ↓ 時 Enter 直接選第一筆）。
    func handleIssueMentionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let matches = issueAtMentionMatches
        switch key {
        case .next:
            issueMentionSelectedIndex = ChatComposerSuggestionSelection.next(
                current: issueMentionSelectedIndex,
                count: matches.count)
            return true
        case .prev:
            guard issueMentionSelectedIndex != nil else { return false }
            issueMentionSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: issueMentionSelectedIndex,
                count: matches.count)
            return true
        case .commit:
            let index = issueMentionSelectedIndex ?? 0
            guard index < matches.count else { return false }
            issueMentionSelectedIndex = nil
            pickIssueMention(matches[index])
            return true
        }
    }

    func applySkillSuggestion(_ entry: PluginRegistryEntry) {
        let token = "$\(entry.id)"
        guard let dollar = prompt.lastIndex(of: "$") else {
            prompt = prompt.isEmpty ? "\(token) " : "\(prompt) \(token) "
            return
        }
        let prefix = prompt[..<dollar]
        let suffix = prompt[prompt.index(after: dollar)...]
        if suffix.contains(where: { $0.isWhitespace || $0.isNewline }) {
            prompt = prompt.isEmpty ? "\(token) " : "\(prompt) \(token) "
        } else {
            prompt = String(prefix) + token + " "
        }
    }
}
