import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {
    var workOSBindingMutationIntentStore:
        WorkOSBindingMutationIntentStore
    {
        WorkOSBindingMutationIntentStore(
            fileURL: store.url.deletingLastPathComponent()
                .appendingPathComponent(
                    "work-os-binding-mutation-intent-v1.json",
                    isDirectory: false))
    }
    var activeRunnerJournalIdentity:
        (runID: String, attempt: UInt64?, instanceID: UUID, revision: UInt64)?
    {
        activeTurnLifecycle.map {
            let diagnostics = runner.diagnosticsSnapshot
            if let identity = diagnostics.authorityIdentity,
               identity.runID == $0.runID
            {
                return (
                    runID: identity.runID,
                    attempt: identity.attempt,
                    instanceID: identity.instanceID,
                    revision: identity.revision)
            }
            if let identity = durableCancellationRecord?.identity,
               identity.runID == $0.runID
            {
                return (
                    runID: identity.runID,
                    attempt: identity.attempt,
                    instanceID: identity.instanceID,
                    revision: identity.revision)
            }
            return (
                runID: $0.runID,
                attempt: nil,
                instanceID: $0.runnerInstanceID,
                revision: $0.runnerRevision
            )
        }
    }

    static func shouldDeferColdStartHydration(
        environment: [String: String]
    ) -> Bool {
        switch environment[
            "TATWO_ULTRAWORK_CHAT_COLD_START_HYDRATION"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "deferred", "1", "true":
            return true
        case "immediate", "0", "false":
            return false
        default:
            break
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        if environment["TATWO_ULTRAWORK_EXPORT_TAB"] != nil
            || environment["TATWO_ULTRAWORK_EXPORT_SNAPSHOT"] != nil
            || environment["TATWO_ULTRAWORK_CHAT_FIXTURE"] != nil
        {
            return false
        }
        return true
    }

    /// Begins the disk and runner recovery pipeline only after SwiftUI has
    /// presented the first frame. Repeated `.onAppear` delivery and window
    /// reconstruction are idempotent because the process shares one model and
    /// only `.notScheduled` may transition into the initial pipeline.
    func scheduleColdStartHydrationAfterFirstFrame() {
        guard defersColdStartHydration else { return }
        guard coldStartHydrationState == .notScheduled else { return }
        beginColdStartHydration(isRetry: false)
    }

    func retryColdStartHydration() {
        guard defersColdStartHydration else { return }
        switch coldStartHydrationState {
        case .failed, .timedOut:
            break
        default:
            return
        }
        initialStoreLoadController.cancel()
        coldStartHydrationTask?.cancel()
        coldStartHydrationTimeoutTask?.cancel()
        beginColdStartHydration(isRetry: true)
    }

    var coldStartHydrationFailureMessage: String? {
        switch coldStartHydrationState {
        case .failed(let reason):
            return "Chat 啟動恢復失敗：\(reason)"
        case .timedOut:
            return "Chat 啟動恢復逾時；尚未套用本機聊天資料，傳送與資料變更仍保持鎖定。"
        default:
            return nil
        }
    }

    var canRetryColdStartHydration: Bool {
        switch coldStartHydrationState {
        case .failed, .timedOut:
            return true
        default:
            return false
        }
    }

    private func beginColdStartHydration(isRetry: Bool) {
        coldStartHydrationAttempt &+= 1
        let attempt = coldStartHydrationAttempt
        coldStartHydrationState = isRetry ? .retryScheduled : .scheduled
        scheduleColdStartHydrationTimeout(attempt: attempt)

        let transcriptStore = chatTranscriptJournalStore
        let nativeStore = store
        let cancellationDurability = cancellationDurability
        let authorityDiscoverer = runnerAuthorityDiscoverer
        coldStartHydrationTask = Task { @MainActor [weak self] in
            // `.onAppear` may run while SwiftUI is still committing the initial
            // transaction. Yield once so no recovery work competes with that
            // first render pass.
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.coldStartHydrationAttempt == attempt,
                  self.coldStartHydrationState
                    == (isRetry ? .retryScheduled : .scheduled)
            else { return }
            self.coldStartHydrationState = .running

            let payload = await Task.detached(priority: .utility) {
                let journalLoad: ChatColdStartJournalLoad
                do {
                    journalLoad = .loaded(try transcriptStore.load())
                } catch {
                    journalLoad = .failed(
                        TatwoPrivacyRedactor.redacted(
                            error.localizedDescription))
                }

                let migrationFailure: String?
                do {
                    _ = try nativeStore.migrateToUnifiedLedger()
                    migrationFailure = nil
                } catch {
                    migrationFailure = TatwoPrivacyRedactor.redacted(
                        error.localizedDescription)
                }

                let cancellationLoad: ChatColdStartCancellationLoad
                do {
                    cancellationLoad = .loaded(
                        try cancellationDurability.allOutstanding())
                } catch {
                    cancellationLoad = .failed
                }

                // This may perform one launchctl probe per durable runner
                // record. It must never execute on MainActor.
                let runnerAuthority =
                    authorityDiscoverer.discoverRunnerAuthority()
                return ChatColdStartHydrationPayload(
                    journalLoad: journalLoad,
                    unifiedLedgerMigrationFailure: migrationFailure,
                    cancellationLoad: cancellationLoad,
                    runnerAuthority: runnerAuthority)
            }.value

            guard !Task.isCancelled,
                  self.coldStartHydrationAttempt == attempt,
                  self.coldStartHydrationState == .running
            else { return }
            self.applyColdStartHydration(payload, attempt: attempt)
        }
    }

    private func scheduleColdStartHydrationTimeout(attempt: UInt64) {
        coldStartHydrationTimeoutTask?.cancel()
        let timeout = coldStartHydrationTimeoutNanoseconds
        coldStartHydrationTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard let self,
                  self.coldStartHydrationAttempt == attempt
            else { return }
            switch self.coldStartHydrationState {
            case .scheduled, .retryScheduled, .running, .loadingStore:
                self.initialStoreLoadController.cancel()
                self.coldStartHydrationTask?.cancel()
                self.coldStartHydrationTask = nil
                self.isLoadingStore = false
                self.coldStartHydrationState = .timedOut
            default:
                return
            }
        }
    }

    private func applyColdStartHydration(
        _ payload: ChatColdStartHydrationPayload,
        attempt: UInt64
    ) {
        guard attempt == coldStartHydrationAttempt,
              coldStartHydrationState == .running
        else { return }
        coldStartRunnerAuthoritySnapshot = payload.runnerAuthority
        switch payload.journalLoad {
        case .loaded(let journal):
            replaceChatTranscriptJournal(journal)
            chatTranscriptJournalPersistenceAllowed = true
            chatTranscriptJournalRecoveryPending = false
        case .failed(let reason):
            replaceChatTranscriptJournal(ChatTranscriptJournalV1())
            chatTranscriptJournalPersistenceAllowed = false
            chatTranscriptJournalRecoveryPending = true
            fputs(
                "tatwo_chat_transcript_journal_load_blocked=\(reason)\n",
                stderr)
        }
        if let migrationFailure =
            payload.unifiedLedgerMigrationFailure
        {
            fputs(
                "tatwo_unified_session_migration_failed=\(migrationFailure)\n",
                stderr)
        }

        reconcileColdStartTranscriptOrphans(
            authority: payload.runnerAuthority)
        switch payload.cancellationLoad {
        case .loaded(let outstanding):
            restoreDurableCancellationLock(
                outstanding: outstanding,
                authority: payload.runnerAuthority)
        case .failed:
            cancellationBlockedReason = "cancellation-state-read-failed"
            isRunning = true
        }

        if coldStartFixtureRequested {
            isApplyingInitialStorePayload = true
            installChatTranscriptFixtureIfRequested(
                environment: coldStartEnvironment)
            isApplyingInitialStorePayload = false
            isLoadingStore = false
            finishColdStartHydration(attempt: attempt)
        } else {
            coldStartHydrationState = .loadingStore
            startInitialStoreLoad(
                environment: coldStartEnvironment,
                hydrationAttempt: attempt)
        }
    }

    func finishColdStartHydration(attempt: UInt64) {
        guard attempt == coldStartHydrationAttempt else { return }
        coldStartHydrationTimeoutTask?.cancel()
        coldStartHydrationTimeoutTask = nil
        runnerRuntimeSweepGate.complete()
        coldStartHydrationState = .completed
        coldStartHydrationTask = nil
        isLoadingStore = false
    }

    func failColdStartHydration(
        reason: String,
        attempt: UInt64
    ) {
        guard attempt == coldStartHydrationAttempt else { return }
        coldStartHydrationTimeoutTask?.cancel()
        coldStartHydrationTimeoutTask = nil
        coldStartHydrationTask?.cancel()
        coldStartHydrationTask = nil
        isLoadingStore = false
        coldStartHydrationState = .failed(reason: reason)
    }

    var coldStartDocumentMutationAllowed: Bool {
        coldStartHydrationState == .completed
            || isApplyingInitialStorePayload
    }

    @discardableResult
    func allowColdStartDocumentMutation() -> Bool {
        guard coldStartDocumentMutationAllowed else {
            flashComposerHint(
                coldStartHydrationFailureMessage
                    ?? "Chat 正在安全載入本機資料；完成前不會建立或修改聊天。")
            return false
        }
        return true
    }

    var canSend: Bool {
        guard coldStartHydrationState == .completed else { return false }
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard cancellationBlockedReason == nil else { return false }
        if mode == .cli {
            return hasPrompt && cliRuntimeEnabled
        }
        let routeAvailable =
            mode != .chat || currentTurnRouteCooldownGate.canDispatch
        return hasPrompt && routeAvailable
    }

    var sendAvailabilityDiagnostic: String {
        let hasPrompt =
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cancellation =
            cancellationBlockedReason == nil ? "none" : "blocked"
        let routeCode =
            mode == .chat
                ? currentTurnRouteCooldownGate.projection.code
                : "not-applicable"
        return [
            canSend ? "ready" : "blocked",
            "action=\(sendActionSequence)",
            "cold-start=\(coldStartHydrationDiagnosticCode)",
            "prompt=\(hasPrompt ? "present" : "empty")",
            "cancellation=\(cancellation)",
            "route=\(routeCode)",
        ].joined(separator: " · ")
    }

    private var coldStartHydrationDiagnosticCode: String {
        switch coldStartHydrationState {
        case .notScheduled:
            "not-scheduled"
        case .scheduled:
            "scheduled"
        case .retryScheduled:
            "retry-scheduled"
        case .running:
            "running"
        case .loadingStore:
            "loading-store"
        case .completed:
            "completed"
        case .failed:
            "failed"
        case .timedOut:
            "timed-out"
        }
    }

    var queuedChatTurnCount: Int { chatQueue.count }

    var isCLIRuntimeEnabled: Bool { cliRuntimeEnabled }

    var codexMirrorStatusMessage: String {
        switch codexMirrorStatus {
        case .loaded:
            "Codex 鏡射已啟用"
        case .notEnabled:
            "Codex 鏡射未啟用"
        case .unavailable:
            "Codex 鏡射不可用"
        }
    }

    var shouldOfferCodexMirrorOptIn: Bool {
        codexAppStateBridge?.sourcePaths.requiresExternalVolumeOptIn == true
            && codexMirrorStatus != .loaded
    }

    var bindingSummary: String {
        "\(skin.shortTitle) renderer × \(routeChoice.commandLabel) auto route"
    }

    var activeMappings: [TatwoNativeCLIFeatureMapping] {
        let mapping = TatwoNativeCLIFeatureMap.mapping(engine: routeChoice.engine)
        return TatwoNativeCLIFeature.allCases.compactMap { mapping[$0] }
    }

    var routeChoice: ChatRouteChoice {
        ChatRouteChoice.resolve(selectedModel)
    }

    var pendingRouteChoice: ChatRouteChoice? {
        pendingModelID.map(ChatRouteChoice.resolve)
    }

    var modelPickerRouteLabel: String {
        guard let pendingRouteChoice, pendingRouteChoice.id != routeChoice.id else {
            return routeChoice.title
        }
        return "\(routeChoice.title) · 下一輪 \(pendingRouteChoice.title)"
    }

    func replaceChatTranscriptJournal(_ journal: ChatTranscriptJournalV1) {
        chatTranscriptJournal = journal
        chatTranscriptJournalRevision &+= 1
    }

    func blockChatTranscriptJournalPersistence() {
        chatTranscriptJournalPersistenceAllowed = false
        chatTranscriptJournalRecoveryPending = false
    }

    @discardableResult
    func recoverChatTranscriptJournalPersistenceIfNeeded() -> Bool {
        guard !chatTranscriptJournalPersistenceAllowed else { return true }
        guard coldStartHydrationState == .completed else { return false }
        guard chatTranscriptJournalRecoveryPending else { return false }
        guard chatTranscriptJournalRecoveryTask == nil else { return false }
        let store = chatTranscriptJournalStore
        chatTranscriptJournalRecoveryTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try store.load() }
            }.value
            guard let self else { return }
            self.chatTranscriptJournalRecoveryTask = nil
            guard case .success(let journal) = result else { return }
            self.replaceChatTranscriptJournal(journal)
            self.chatTranscriptJournalPersistenceAllowed = true
            self.chatTranscriptJournalRecoveryPending = false
        }
        return false
    }

    var selectedRouteCooldownGate: TatwoChatCooldownGate {
        TatwoChatCooldownGate(
            projection: selectedGatewayCooldownProjection,
            modelDisplayName: routeChoice.title)
    }

    private var currentTurnRouteCooldownGate: TatwoChatCooldownGate {
        let route = currentTurnDispatchRoute()
        guard route.id != routeChoice.id else {
            return selectedRouteCooldownGate
        }
        return TatwoChatCooldownGate(
            projection: gatewayCooldownStore.projection(
                modelID: route.canonicalModelSlug),
            modelDisplayName: route.title)
    }

    var selectedRouteCooldownStatusText: String {
        selectedRouteCooldownGate.statusText
    }

    var composerFooterState: ChatComposerFooterState {
        ChatComposerFooterStateResolver.resolve(
            ChatComposerFooterStateInputs(
                isCLI: mode == .cli,
                explicitWorkScope: selectedThread?.loopsConfig != nil,
                recoveryRequired:
                    activePLGRun?.phase == .rollbackRequired,
                waitingAuthorization:
                    activePLGRun?.phase == .awaitingHumanAuth,
                bindingRecoveryBlocked:
                    selectedThreadWorkOSBindingMutationRecoveryBlocked,
                routeDispatchAllowed:
                    selectedRouteCooldownGate.canDispatch))
    }

    private var selectedThreadWorkOSBindingMutationRecoveryBlocked: Bool {
        guard workOSBindingMutationRecoveryBlocked,
              let intent = workOSBindingMutationRecoveryIntent,
              let selectedThreadID
        else { return false }
        return intent.threadID == selectedThreadID
            && intent.projectID == selectedProjectID
    }

    var canResumeActiveGoal: Bool {
        selectedRouteCooldownGate.canResume
    }

    func refreshGatewayCooldownProjection(now: Date = Date()) {
        let projection = gatewayCooldownStore.projection(
            modelID: routeChoice.canonicalModelSlug,
            now: now)
        if projection != selectedGatewayCooldownProjection {
            selectedGatewayCooldownProjection = projection
        }
    }

    func setSingleModel(_ routeID: String, syncCollaborationLead: Bool = false) {
        let choice = ChatRouteChoice.resolve(routeID)
        if isRunning {
            pendingModelID = choice.id == selectedModel ? nil : choice.id
            flashComposerHint(
                pendingModelID == nil
                    ? "已取消下一輪模型切換；目前回覆仍由 \(routeChoice.title) 執行。"
                    : "目前回覆仍由 \(routeChoice.title) 執行；\(choice.title) 會從下一輪開始。")
            return
        }
        pendingModelID = nil
        selectedModel = choice.id
        // The Chat model picker controls only this conversation route. Work OS
        // identities are changed through the dedicated primary/secondary
        // binding controls, never as a side effect of switching Chat models.
        _ = syncCollaborationLead
    }

    func applyPendingModelSelectionIfPossible() {
        guard !isRunning, let pendingModelID else { return }
        self.pendingModelID = nil
        let choice = ChatRouteChoice.resolve(pendingModelID)
        selectedModel = choice.id
    }

    private static func normalizedModelKey(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func routeChoice(forModelID modelID: String) -> ChatRouteChoice? {
        let needle = normalizedModelKey(modelID)
        guard !needle.isEmpty else { return nil }
        if let direct = ChatRouteChoice.all.first(where: { choice in
            [choice.id, choice.canonicalModelSlug, choice.modelArgument, choice.title]
                .compactMap { $0 }
                .contains { normalizedModelKey($0) == needle }
        }) {
            return direct
        }
        let compatibilityAliases = [
            "grok": "grok-build",
            "opus": "opus5",
            "fable5": "fable5"
        ]
        if let routeID = compatibilityAliases[needle] {
            return ChatRouteChoice.all.first { $0.id == routeID }
        }
        return nil
    }

    static func osModelID(forRoute choice: ChatRouteChoice) -> String {
        choice.canonicalModelSlug
    }

    var selectedNativeCLISession: TatwoNativeCLISession? {
        guard let selectedCLISessionID else { return nil }
        return document.projects
            .flatMap(\.sessions)
            .first { $0.id.uuidString == selectedCLISessionID }
    }

    var selectedCLISession: ChatCLISessionSnapshot? {
        if let session = selectedNativeCLISession {
            var preview = "engine=\(session.engine.rawValue)\ncwd=\(session.cwd)\nstatus=\(session.isArchived ? "archived" : "active")"
            if let ctx = session.seededContext, !ctx.isEmpty {
                preview += "\n\(ctx)"
            }
            return ChatCLISessionSnapshot(
                id: session.id.uuidString,
                title: session.name,
                detail: "\(session.engine.displayName) · \(session.cwd)",
                updatedAt: ISO8601DateFormatter().date(from: session.createdISO) ?? .distantPast,
                rawPreview: preview,
                isRunning: false)
        }
        guard let selectedCLISessionID else { return cliSessions.first }
        return cliSessions.first(where: { $0.id == selectedCLISessionID }) ?? cliSessions.first
    }

    var selectedProject: TatwoNativeChatProject? {
        guard let selectedProjectID else { return nil }
        return document.projects.first(where: { $0.id == selectedProjectID })
    }

    var selectedThreadProject: TatwoNativeChatProject? {
        guard let selectedThreadID else { return nil }
        if document.threads.contains(where: { $0.id == selectedThreadID }) {
            return nil
        }
        if let selectedProject {
            return selectedProject
        }
        return document.projects.first { project in
            project.threads.contains(where: { $0.id == selectedThreadID })
        }
    }

    var selectedThread: TatwoNativeChatThread? {
        guard let selectedThreadID else { return nil }
        if let thread = document.threads.first(where: { $0.id == selectedThreadID }) {
            return thread
        }
        return document.projects.flatMap(\.threads).first(where: { $0.id == selectedThreadID })
    }

    var selectedDiscussion: TatwoNativeDiscussion? {
        guard let selectedDiscussionID else { return nil }
        return selectedThread?.discussions.first(where: { $0.id == selectedDiscussionID })
    }

    var selectedSessionReference: TatwoNativeChatSessionReference? {
        if let discussion = selectedDiscussion {
            return TatwoNativeChatSessionReference(kind: .discussion, id: discussion.id)
        }
        guard let threadID = selectedThreadID else { return nil }
        return TatwoNativeChatSessionReference(kind: .thread, id: threadID)
    }

    /// Remote compute authorization is intentionally scoped to the main Chat thread.
    /// Discussions and loops inherit that one user-visible Session boundary instead of
    /// minting incompatible IDs that cannot be matched by the Devices page.
    var selectedRemoteBorrowSessionID: String? {
        selectedThread?.id.uuidString.lowercased()
    }

    var isDiscussionSessionSelected: Bool {
        selectedDiscussion != nil
    }

    var selectedSessionStoredMessages: [TatwoNativeChatStoredMessage] {
        if let discussion = selectedDiscussion {
            return discussion.messages
        }
        return selectedThread?.messages ?? []
    }

    var selectedSessionTitle: String {
        if let discussion = selectedDiscussion {
            return "# \(discussion.title)"
        }
        return selectedThread?.title ?? "未命名 thread"
    }

    var selectedSessionPreview: String {
        if let discussion = selectedDiscussion {
            return discussion.lastPreview
        }
        return selectedThread?.lastPreview ?? ""
    }

    var isSelectedThreadStandalone: Bool {
        guard let selectedThreadID else { return false }
        return document.threads.contains(where: { $0.id == selectedThreadID })
    }

    var transcriptMessages: [ChatMessage] {
        transcriptProjectionCache.resolve(
            key: ChatTranscriptProjectionCacheKey(
                selectedSessionStableKey: selectedSessionReference?.stableKey,
                liveMessagesRevision: transcriptMessagesLiveRevision,
                journalRevision: chatTranscriptJournalRevision,
                documentRevision: transcriptMessagesDocumentRevision,
                journalPersistenceAllowed:
                    chatTranscriptJournalPersistenceAllowed,
                legacyMigrationCompleted:
                    legacyTranscriptMigrationCompleted
            )
        ) {
            uncachedTranscriptMessages()
        }
    }

    var transcriptProjectionCacheMetrics:
        ChatTranscriptProjectionCacheMetrics
    {
        transcriptProjectionCache.metrics
    }

    func resetTranscriptProjectionCacheMetrics() {
        transcriptProjectionCache.reset()
    }

    private func uncachedTranscriptMessages() -> [ChatMessage] {
        let live = transcriptProjectionCache.resolveLive(
            sessionKey: selectedSessionReference?.stableKey,
            messages: messages,
            includeRevision: 1
        ) {
            !$0.isTranscriptNoise && !$0.isInertAssistantPlaceholder
        }
        if live.isEmpty,
           chatTranscriptJournalPersistenceAllowed,
           let reference = selectedSessionReference
        {
            let canonical = ChatTranscriptJournalAdapter.projectedMessages(
                threadID: reference.stableKey,
                from: chatTranscriptJournal)
            let durable = legacyTranscriptMigrationCompleted
                ? canonical
                : ChatTranscriptJournalAdapter.mergingCanonicalProjection(
                    canonical,
                    withLegacy: selectedSessionStoredMessages)
            if !durable.isEmpty {
                return durable.filter {
                    !$0.isTranscriptNoise && !$0.isInertAssistantPlaceholder
                }
            }
        }
        if live.isEmpty {
            return selectedSessionStoredMessages
                .map(ChatMessage.init(stored:))
                .filter {
                    !$0.isTranscriptNoise && !$0.isInertAssistantPlaceholder
                }
        }
        return live
    }

    var selectedThreadPluginIDs: [String] {
        selectedThread?.threadPluginIDs ?? []
    }

    var selectedThreadPluginEntries: [PluginRegistryEntry] {
        TatwoThreadPluginDecisionContextComposer.entries(
            for: selectedThreadPluginIDs,
            registry: pluginRegistryBook)
    }

    var availableThreadPluginEntries: [PluginRegistryEntry] {
        pluginRegistryBook.sortedEntries.filter { entry in
            switch entry.kind {
            case .plugin, .skill, .mcp:
                return true
            case .app, .localRuntime:
                return false
            }
        }
    }

    var selectedThreadPluginSummary: String {
        let entries = selectedThreadPluginEntries
        guard !entries.isEmpty else { return "plugins 未登記" }
        return entries.map(\.name).joined(separator: " / ")
    }

    var selectedWorkOSReceiptSummary: String {
        guard let selectedGoalRecord else { return "receipts 0" }
        return "receipts \(selectedGoalRecord.receipts.count)"
    }

    var selectedThreadHasWorkOSGoal: Bool {
        guard !isDiscussionSessionSelected else { return false }
        return selectedGoalRecord != nil
            || selectedWorkOSContract != nil
            || selectedThread?.workOSContractID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var canJudgeAndCompleteActiveGoal: Bool {
        selectedGoalRecord?.mode == .s
            && selectedGoalRecord?.status == .awaitingNextCycle
    }

    var isPlanModeEnabled: Bool {
        mode == .chat && selectedThread?.isPlanModeEnabled == true
    }

    var isActivePlanTurnWriting: Bool {
        guard isRunning,
              let binding = activePlanTurnBinding,
              binding.threadID == selectedThreadID,
              binding.assistantMessageID == activeAssistantID
        else {
            return false
        }
        return true
    }

    var activePlanTurnAssistantMessageID: String? {
        isActivePlanTurnWriting
            ? activePlanTurnBinding?.assistantMessageID
            : nil
    }

    var selectedWorkOSContractShortID: String {
        guard let contractID =
                selectedWorkOSContract?.contractID
                ?? selectedThread?.workOSContractID
        else { return "contract pending" }
        return String(contractID.suffix(12))
    }

    var selectedWorkOSGoalStatusLabel: String {
        selectedGoalRecord?.status.rawValue ?? selectedWorkOSContract?.goalRun.status.rawValue ?? "no goal"
    }

    var activeGoalStatusPresentationLabel: String {
        switch selectedGoalRecord?.status ?? selectedWorkOSContract?.goalRun.status {
        case .planned?:
            return "目標已規劃"
        case .dispatching?:
            return "目標派工中"
        case .running?:
            return "目標執行中"
        case .succeeded?:
            return "執行完成，等待驗收"
        case .passed?:
            return "目標已完成"
        case .failed?:
            return "執行失敗"
        case .cancelled?:
            return "執行已取消"
        case .humanGate?:
            return "目標待核准"
        case .awaitingNextCycle?:
            return "本輪完成，可繼續下一輪"
        case .blocked?:
            return "目標已阻塞"
        case .rollbackRequired?:
            return "目標需回滾"
        case .superseded?:
            return "目標已由新版取代"
        case nil:
            return "目標"
        }
    }

    var selectedThreadHasUserRequest: Bool {
        messages.contains { $0.role == .user }
            || selectedSessionStoredMessages.contains {
                $0.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user"
            }
    }

    var shouldShowActiveGoalInlineCard: Bool {
        selectedThreadID != nil
            && selectedThreadHasWorkOSGoal
    }

    var activeGoalObjectiveLabel: String {
        if let canonicalObjective =
            selectedGoalRecord?.objective
            ?? selectedWorkOSContract?.objective
        {
            let trimmed = canonicalObjective.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let preview = selectedThread?.selectedThreadWorkOSContext?.preview {
            return preview
        }
        let objective = selectedThread?.title ?? "未命名目標"
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名目標" : trimmed
    }

    var activeGoalElapsedLabel: String {
        guard let startedAt = selectedGoalRecord?.issuedAt ?? selectedWorkOSContract?.goalRun.createdAt else {
            return "elapsed —"
        }
        return TatwoCoworkProgressInspector.formatDuration(max(0, Int(Date().timeIntervalSince(startedAt))))
    }

    var activeGoalNextActionLabel: String {
        let next = selectedWorkOSContract?.nextAction.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return next.isEmpty ? "等待下一個 OS action" : next
    }

    var activeGoalReceiptCount: Int {
        selectedGoalRecord?.receipts.count ?? 0
    }

    var activeGoalRequiredReceiptCount: Int {
        max(selectedWorkOSContract?.receiptRequirements.count ?? 0, activeGoalReceiptCount)
    }

    var activeGoalReceiptProgressLabel: String {
        let required = activeGoalRequiredReceiptCount
        guard required > 0 else { return "receipts 0" }
        return "receipts \(activeGoalReceiptCount)/\(required)"
    }

    var activeGoalStepProgress: (current: Int, total: Int) {
        // Codex App-style goal progress should describe the human workflow, not
        // explode into a receipt-count progress bar. Receipts keep their own
        // x/y label; this step chip stays on the stable 5-phase PLG spine:
        // Goal -> Plan -> Loops -> Receipts -> Close / human gate.
        let total = 5
        let requiredReceipts = activeGoalRequiredReceiptCount
        var current = selectedWorkOSContract == nil ? 1 : 2
        if activeGoalReceiptCount > 0 {
            current = 3
        }
        if requiredReceipts > 0, activeGoalReceiptCount >= requiredReceipts {
            current = 4
        }
        switch selectedGoalRecord?.status ?? selectedWorkOSContract?.goalRun.status {
        case .passed?:
            current = total
        case .succeeded?, .rollbackRequired?, .blocked?, .humanGate?,
             .awaitingNextCycle?:
            current = max(current, total - 1)
        default:
            break
        }
        return (min(max(current, 1), total), total)
    }

    var activeGoalStepProgressLabel: String {
        let progress = activeGoalStepProgress
        let required = max(1, activeGoalRequiredReceiptCount)
        return "階段 \(progress.current)/\(progress.total) · 收據 \(activeGoalReceiptCount)/\(required) · 改檔 \(gitChangedFileCount)"
    }

    var activeGoalHeaderProgressLabel: String {
        let progress = activeGoalStepProgress
        let required = max(1, activeGoalRequiredReceiptCount)
        return "階段 \(progress.current)/\(progress.total) · 收據 \(activeGoalReceiptCount)/\(required)"
    }

    var skillSuggestions: [PluginRegistryEntry] {
        guard let query = activeSkillQuery else { return [] }
        return ChatComposerSkillCatalog.suggestions(
            in: pluginRegistryBook,
            query: query)
    }

    private var activeSkillQuery: String? {
        guard let dollar = prompt.lastIndex(of: "$") else { return nil }
        let suffix = prompt[prompt.index(after: dollar)...]
        if suffix.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
        return String(suffix)
    }

    var activeLoopsConfig: TatwoNativeThreadLoopsConfig? {
        snapshotLoopsOverride ?? selectedThread?.loopsConfig
    }

    var collaborationLevel: ChatCollaborationLevel {
        ChatCollaborationLevel(workMode: activeLoopsConfig?.mode)
    }

    var collaborationIsEnabled: Bool {
        // Wave1: ChatRunMode.cowork tab removed; collaboration is loops-config only.
        activeLoopsConfig != nil
    }

    var activeLoopsSummary: String {
        activeLoopsConfig?.summaryLine ?? "尚未選擇 Ultrawork 情境模板"
    }

    var visibleLoopsConfig: TatwoNativeThreadLoopsConfig? {
        activeLoopsConfig ?? selectedCoworkTemplate.map { loopsConfig(for: $0) }
    }

    var activeWorkOSModeLabel: String {
        guard collaborationIsEnabled else { return "Off" }
        return visibleLoopsConfig?.mode.rawValue.uppercased() ?? "M"
    }

    var activeWorkOSScenarioLabel: String {
        guard let scenarioID = visibleLoopsConfig?.scenarioID else { return "manual" }
        let trimmed = scenarioID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "manual" }
        if let scenario = scenarioConfigBook.scenario(id: trimmed),
           !scenario.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return scenario.displayName
        }
        return trimmed
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    var activeWorkOSBudgetLabel: String {
        guard let raw = visibleLoopsConfig?.tokenBudget.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return "budget" }
        let separators: Set<Character> = ["；", ";", "，", ","]
        let firstChunk = raw.split(whereSeparator: { separators.contains($0) }).first.map(String.init) ?? raw
        return firstChunk.count > 18 ? "\(firstChunk.prefix(18))…" : firstChunk
    }

    var activeWorkOSLeadLabel: String {
        visibleLoopsConfig?.primaryModelID ?? activePrimaryModelID
    }

    var activeWorkOSLoopsLabel: String {
        visibleLoopsConfig?.secondaryModelID ?? activeSecondaryModelID
    }

    var activeWorkOSLine: String {
        guard collaborationIsEnabled else { return "Collaboration Off · pure chat" }
        return "\(activeWorkOSModeLabel) · Plan \(activeWorkOSLeadLabel) · Loops \(activeWorkOSLoopsLabel) · receipts"
    }

    var activeSubagentLabels: [String] {
        guard collaborationIsEnabled else { return [] }
        let primary = activePrimaryModelID
        let secondary = activeSecondaryModelID
        return activeLoopsModelCandidates.filter { candidate in
            candidate != primary && candidate != secondary
        }
    }

    var activeSubagentRows: [ThreadSubagentPresentationRow] {
        if !selectedDispatchRecords.isEmpty {
            return selectedDispatchRecords
                .sorted { lhs, rhs in
                    if lhs.status == .running && rhs.status != .running { return true }
                    if lhs.status != .running && rhs.status == .running { return false }
                    return lhs.updatedAt > rhs.updatedAt
                }
                .map { record in
                    let route = ChatRouteChoice.resolve(record.modelID)
                    let statusLabel: String
                    let tint: Color
                    switch record.status {
                    case .queued:
                        statusLabel = "queued"
                        tint = .secondary
                    case .running:
                        statusLabel = "working"
                        tint = .orange
                    case .completed:
                        statusLabel = "done"
                        tint = .green
                    case .verified:
                        statusLabel = "verified"
                        tint = .mint
                    case .failed:
                        statusLabel = "failed"
                        tint = .red
                    }
                    let detail = record.subtask.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ThreadSubagentPresentationRow(
                        id: record.id,
                        identityLabel: record.identity.rawValue,
                        modelID: record.modelID,
                        statusLabel: statusLabel,
                        detail: detail.isEmpty ? "dispatch receipt" : detail,
                        route: route,
                        tint: tint)
                }
        }

        // Do not show "planned agents" on a normal single-model chat. A thread
        // may carry a legacy loopsConfig because model/Ultrawork settings were
        // synced earlier, but until a Work OS contract exists, the right-side
        // card should stay Codex-like: thread facts only, no fake subagent state.
        // Wave1: ChatRunMode.cowork no longer forces planned-agent rows.
        guard selectedWorkOSContract != nil else { return [] }
        return activeSubagentLabels.map { modelID in
            ThreadSubagentPresentationRow(
                id: "planned-\(modelID)",
                identityLabel: "planned",
                modelID: modelID,
                statusLabel: "ready",
                detail: "尚未派發",
                route: ChatRouteChoice.resolve(modelID),
                tint: .secondary)
        }
    }

    var shouldShowUltraworkActivation: Bool {
        activeLoopsConfig != nil
            || Self.ultraworkControlLine(in: prompt) != nil
    }

    var activePendingHandoff: ChatHandoffEnvelope? {
        guard let selectedThreadID else { return nil }
        return pendingHandoffByThreadID[selectedThreadID]
    }

    var activePendingHandoffSummary: String {
        activePendingHandoff?.summaryLine ?? "尚無待併入交接包"
    }

    var activeLoopsModelCandidates: [String] {
        guard let config = activeLoopsConfig,
              let modeConfig = scenarioConfigBook.modeConfig(scenarioID: config.scenarioID, mode: config.mode)
        else { return [] }
        var seen = Set<String>()
        var candidates = modeConfig.bindings.flatMap(\.boundModelIDs).filter { modelID in
            guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seen.contains(modelID)
            else { return false }
            seen.insert(modelID)
            return true
        }
        for overrideID in [config.primaryModelID, config.secondaryModelID].compactMap({ $0 }) {
            guard !overrideID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seen.contains(overrideID)
            else { continue }
            candidates.append(overrideID)
            seen.insert(overrideID)
        }
        if config.mode == .xxl {
            for routeID in ["opus5", "grok-build"] {
                guard let route = ChatRouteChoice.resolveOrNil(routeID) else { continue }
                let canonicalID = route.canonicalModelSlug
                guard seen.insert(canonicalID).inserted else { continue }
                candidates.append(canonicalID)
            }
        }
        return candidates
    }

    var activePrimaryModelID: String {
        activeLoopsConfig?.primaryModelID ?? activeLoopsModelCandidates.first ?? "未指定"
    }

    var activeSecondaryModelID: String {
        activeLoopsConfig?.secondaryModelID ?? activeLoopsModelCandidates.dropFirst().first ?? activeLoopsModelCandidates.first ?? "未指定"
    }
}
