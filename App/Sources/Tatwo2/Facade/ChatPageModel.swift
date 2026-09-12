// 來源：Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageModel.swift；只保留 chat 畫面 Binding 欄位與本地假資料入口
import SwiftUI
import AppKit


@MainActor
final class ChatPageModel: ObservableObject {
    struct SlashCommandItem: Identifiable, Hashable {
        let id: String
        let cmd: String
        let title: String
        let subtitle: String
        let icon: String
    }
    let authorityBootstrapModel = TatwoAppAuthorityBootstrapModel()
    let remoteBorrowAuthorizationStore = TatwoRemoteBorrowAuthorizationStore.default()
    let assistantTranscriptCache = TatwoAssistantTranscriptCache()
    private let fixture: ChatFixture
    /// 金樣專用：某些場景要在固定劇本後面多幾則（打字中、錯誤卡），不動 ChatFixture 本體。
    private var fixtureExtraMessages: [ChatMessage] = []
    private let runtimeEnvironment: [String: String]
    private let engineLogin: EngineLogin
    private let deviceRegistry: DeviceRegistry
    private let devicePairingHost: DevicePairingHost
    private let githubAccountsStore: GitHubAccountsStore
    /// 真水電：沒有匯出／假資料環境變數時走 live（Claude sidecar）；有就走 1.0 金樣假資料。
    let isLive: Bool
    private(set) var live: (any LiveEngineAPI)?
    private var localLive: ChatLiveEngine?
    private var pendingPR = PullRequestService.PendingPR()
    private var preparingPR = false
    private var localSelectedThreadID: UUID?
    private var remoteProjectionTask: Task<Void, Never>?
    private var lastRemoteProjectionAt = Date.distantPast
    private var botStore: BotStore?
    private(set) var cliSessionStore: CLISessionStore?
    @Published var cliRailHoveredID: UUID?
    @Published var cliRenamePresented = false
    @Published var cliRenameTitle = ""
    var cliRenameID: UUID?
    @Published var cliRestoringIDs: Set<UUID> = []
    @Published var cliRestoredHistoryIDs: Set<UUID> = []
    var cliUIFixtureRecords: [CLISessionStore.Record] = []
    private var previousCLITabIDs: Set<UUID> = []
    private var cliStore: ChatLiveStore?
    var cliSessionsByThread: [UUID: [TatwoNativeCLISessionBook.Session]] = [:]
    var activeCLITabByThread: [UUID: UUID] = [:]
    private var loadedCLIThreadIDs: Set<UUID> = []
    @Published private var pluginEntries: [PluginRegistryEntry]
    private var lastPluginScanAt = Date.distantPast
    private(set) var pluginRefreshTask: Task<Void, Never>?
    var cliTabOwner: [UUID: UUID] = [:]
    var cliTabLinesByID: [UUID: [TatwoTerminalLine]] = [:]
    var cliTabPTYByID: [UUID: CLIWorkbenchTerminalSession] = [:]
    var closingCLIPTYByID: [UUID: CLIWorkbenchTerminalSession] = [:]
    var cliTabPIDByID: [UUID: Int32] = [:]
    var cliRuntime: CLITmuxRuntime?
    var cliWorkbenchDocument = CLISessionStore.Workbench()
    var cliRefreshTask: Task<Void, Never>?
    @Published var cliPendingCloseTitle: String?
    var cliPendingCloseIDs: [UUID] = []
    private var composerRevision: UInt64 = 0
    @Published var prompt = "" {
        didSet {
            // 打字後建議清單會變，三個 picker 的高亮都歸零，避免指到錯的項目。1.0 :1519
            guard prompt != oldValue else { return }
            composerRevision &+= 1
            if skillSuggestionSelectedIndex != nil { skillSuggestionSelectedIndex = nil }
            if slashCommandSelectedIndex != nil { slashCommandSelectedIndex = nil }
            if issueMentionSelectedIndex != nil { issueMentionSelectedIndex = nil }
            if activeSkillQuery != nil { reloadPluginRegistry(ifOlderThan: 60) }
        }
    }
    // 同 1.0：匯出／假資料模式下由 TATWO_ULTRAWORK_EXPORT_CHAT_MODE 決定 chat / cli / bot
    @Published var mode: ChatRunMode = {
        switch ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_CHAT_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bot": return .bot
        case "cli": return .cli
        default: return .chat
        }
    }() {
        didSet {
            if mode != oldValue {
                ComputerUseController.shared.stop()
                BrowserAgentBridge.shared.revokeRequests()
            }
        }
    }
    @Published var searchText = ""
    @Published var skin: ChatSkin = .codex
    @Published var document = TatwoNativeChatStoreDocument()
    @Published var selectedThreadID: UUID? {
        didSet {
            if selectedThreadID != oldValue {
                ComputerUseController.shared.stop(owner: oldValue)
                BrowserAgentBridge.shared.revokeRequests()
            }
            if selectedThreadID != oldValue {
                composerRevision &+= 1
                loadActivePlanCanvas()
            }
            guard isLive, let activeLive = activeConversationEngine,
                  let id = selectedThreadID, id != oldValue else { return }
            if let selectedRemote {
                self.selectedRemote = (selectedRemote.deviceID, id)
            } else {
                localSelectedThreadID = id
            }
            activeLive.select(id)
            isRunning = activeLive.isRunning(id)
            restoreModelPreferences()
            refreshIssueLists()
            if selectedRemote == nil { refreshGitStatus() }
            loadPersistedCLISessionBook()
        }
    }
    @Published var selectedCLISessionID: String?
    @Published var cliTabStatuses: [UUID: String] = [:]
    @Published var selectedLoopsSessionID: UUID?
    @Published var dispatchingLoopID: UUID?
    @Published var plgPaused = false
    @Published private var fixtureActiveGoalPaused = false
    @Published var activeGoalClock = Date()
    @Published var issueListShowsGlobal = false { didSet { refreshIssueLists() } }
    @Published var requestOpenInfoCard = false
    @Published var requestOpenLoopsPanel = false
    @Published var requestOpenBrowserPanel = false
    @Published private(set) var requestedBrowserAgentURL: String?
    private var pendingBrowserAgentNavigation: BrowserAgentNavigation?
    /// 每條討論串自己的瀏覽器分頁組（key＝討論串 id 小寫）；見 BrowserLaneRegistry.swift
    @Published var browserLanesBySession: [String: BrowserLaneSnapshot] = [:]
    @Published var activePlanArtifact: TatwoPlanArtifactV1?
    @Published var planInspectorRequest: UUID?
    /// 2026-09-11 使用者回饋：提醒遺留太久 → 顯示 4–10 秒（依字數）後自動收掉；換成新提醒就重新計時。
    @Published var composerHint: String? { didSet { scheduleComposerHintExpiry() } }
    private var composerHintExpiry: Task<Void, Never>?
    private func scheduleComposerHintExpiry() {
        composerHintExpiry?.cancel()
        guard let hint = composerHint, !hint.isEmpty else { return }
        let seconds = min(10, max(4, Double(hint.count) * 0.15))
        composerHintExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.composerHint == hint else { return }
            self.composerHint = nil
        }
    }
    @Published var slashCommandSelectedIndex: Int?
    @Published var droppedPathDisplayNames: [String: String] = [:]
    @Published var permissionPreset: TatwoPermissionPreset =
        UserDefaults.standard.string(forKey: "tatwo2.permissionPreset")
            .flatMap(TatwoPermissionPreset.init(rawValue:)) ?? .approveForMe {
        didSet {
            UserDefaults.standard.set(permissionPreset.rawValue, forKey: "tatwo2.permissionPreset")
            live?.autoApprove = permissionPreset == .approveForMe
            localLive?.userPermissionPreset = permissionPreset
        }
    }
    @Published var selectedSpeedTier: TatwoModelSpeedTier = .fast { didSet { persistModelPreferences() } }
    @Published var selectedEffort: TatwoCodexReasoningEffort = .high { didSet { persistModelPreferences() } }
    @Published var pendingArchiveIssuePrompt: (title: String, count: Int)?
    @Published var coldStartHydrationFailureMessage: String?
    @Published var allIssueListEntries: [TatwoIssueListEntryV1] = []
    @Published var archivedIssueListEntries: [TatwoIssueListEntryV1] = []
    @Published var issueListEntries: [TatwoIssueListEntryV1] = []
    @Published var focusedIssueEntryID: String?
    @Published var issueMentionSelectedIndex: Int?
    @Published var skillSuggestionSelectedIndex: Int?
    @Published var chatQueuePaused = false
    @Published var isEnablingCodexMirror = false
    @Published var isLoadingStore = false
    @Published var isRunning = false
    /// Presentation only: hiding the tray never stops or archives its rooms.
    @Published var hiddenDiscussionTrayKeys: Set<String> = []
    private var pendingIssueSubmission: (key: String, id: String)?
    @Published var droppedPaths: [String] = [] {
        didSet { if droppedPaths != oldValue { composerRevision &+= 1 } }
    }
    @Published var gitBranch = "—"
    @Published var gitChangedFileCount = 0
    @Published var gitChangedFilePreview: [String] = []
    @Published var gitChangedFiles: [ChatGitChangedFileSummary] = []
    /// 回合收尾卡的資料：這條對話最新一回合的產出索引（jobs-index 底層寫的 latest.json）。
    @Published var latestTurnArtifacts: TurnArtifactIndex?
    @Published var gitChangedLineAdditions = 0
    @Published var gitChangedLineDeletions = 0
    @Published private var gitHubRepoCheckingProjectIDs: Set<UUID> = []
    @Published private var gitHubRepoCheckMessages: [UUID: String] = [:]
    @Published var lastClaudeRouteReceiptStatus = ""
    @Published var lastCommand = "尚未執行"
    @Published var pendingModelID: String?
    @Published var selectedDiscussionID: UUID?
    @Published var selectedModel = "gpt-5.5" { didSet { persistModelPreferences() } }
    private var restoringModelPreferences = false
    @Published var codexMirrorStatus: TatwoCodexAppStateBridge.MirrorStatus = .notEnabled
    @Published var devices: [DeviceRecord] = []
    @Published var remoteSessions: [RemoteDeviceSession] = []
    @Published var remoteSidebarSections: [RemoteSidebarSection] = []
    @Published var selectedRemote: (deviceID: String, threadID: UUID)? {
        didSet {
            if selectedRemote?.deviceID != oldValue?.deviceID || selectedRemote?.threadID != oldValue?.threadID {
                ComputerUseController.shared.stop()
                BrowserAgentBridge.shared.revokeRequests()
                loadActivePlanCanvas()
            }
        }
    }
    @Published var pairingWindow: (code: String, expiresAt: Date)?
    @Published var pairingListenAddress: String?
    /// 設定頁「設備」卡用：加入主機的結果（設定頁看不到輸入框的 hint）。
    @Published var pairingClientMessage: String?
    @Published var gitHubAccounts: [GitHubAccountRecord] = []
    @Published var gitHubHelperInstalled = false
    @Published var gitHubLoginLog: [String] = []
    @Published var githubLoginInProgress = false
    @Published var githubDeviceCode: String?
    @Published var githubVerificationURL: URL?
    @Published var engineLogins: [EngineLoginStatus] = []
    @Published var engineLoginLog: [String] = []
    @Published var engineLoginInProgress: ClaudeSidecar.Kind?
    @Published var disabledEngines: Set<String> = EngineDisableStore.disabled()
    @Published var engineQuotas: [String: LiveQuotaDisplay] = [:]
    @Published var engineQuotaDetails: [String: EngineQuotaDetail] = [:]
    @Published var upstreamBindings: [UpstreamBindingStatus] = []
    @Published var osDocuments: [OSDocument] = OSDocuments.list()
    @Published var osDocumentText: [String: String] = [:]
    @Published var osDocumentNote: [String: String] = [:]
    @Published var osDocumentPending: [String: String] = [:]

    var canRetryColdStartHydration: Bool { true }
    var cliTabs: [TatwoNativeCLISessionBook.Session] {
        guard let selectedThreadID else { return [] }
        return cliSessionsByThread[selectedThreadID] ?? []
    }
    var activeCLITabID: UUID? {
        guard let selectedThreadID else { return nil }
        return activeCLITabByThread[selectedThreadID]
    }
    var selectedSessionReference: TatwoNativeChatSessionReference? { nil }
    var nativeGoalSnapshot: ChatNativeGoal? {
        guard isLive, selectedRemote == nil else { return nil }
        return localLive?.threadRecord(selectedThreadID)?.nativeGoal
    }
    var nativeGoalIsCurrent: Bool {
        guard let id = selectedThreadID else { return false }
        return localLive?.nativeGoalIsCurrent(id) == true
    }
    var nativeGoalControlPending: Bool {
        guard let id = selectedThreadID else { return false }
        return localLive?.nativeGoalControlPending(id) == true
    }
    var activeGoalPaused: Bool {
        isLive ? nativeGoalSnapshot?.status != "active" || !nativeGoalIsCurrent : fixtureActiveGoalPaused
    }
    var activeGoalStepProgress: (current: Int, total: Int) { isLive ? (0, 0) : (1, 5) }
    var selectedRouteCooldownStatusText: String { "" }
    var selectedWorkOSGoalStatusLabel: String { isLive ? nativeGoalSnapshot?.status ?? "unknown" : "running" }
    var activeGoalObjectiveLabel: String { isLive ? nativeGoalSnapshot?.objective ?? "" : "完成 Tatwo2 Chat UI" }
    var activeGoalElapsedLabel: String { isLive ? nativeGoalSnapshot?.elapsedLabel ?? "—" : "00:00" }
    var activeGoalHeaderProgressLabel: String { isLive ? nativeGoalSnapshot?.usageLabel ?? "—" : "1 / 5" }
    var canResumeActiveGoal: Bool {
        guard isLive else { return true }
        guard selectedRemote == nil, !nativeGoalControlPending, let goal = nativeGoalSnapshot else { return false }
        return goal.canResume || (!nativeGoalIsCurrent && goal.status == "active")
    }
    var canControlActiveGoal: Bool { !isLive || (selectedRemote == nil && !nativeGoalControlPending) }
    var canJudgeAndCompleteActiveGoal: Bool { false }
    var selectedThreadHasWorkOSGoal: Bool { isLive ? nativeGoalSnapshot != nil : fixture.hasWorkOSGoal }
    /// ultrawork 膠囊的檔位。2026-09-04 補接：原本永遠回 .off，等於膠囊點了沒反應
    /// （B2 拆模式／情境卡時說好「誰主導、誰當 sub、誰審改在膠囊選」的那顆）。
    @Published var collaborationLevel: ChatCollaborationLevel = .off
    /// B3 派工卡：展開中的房間報告（收合／展開）。匯出 dispatch 場景預設展開已完成那間，讓金樣看得到設計。
    @Published var expandedDispatchReports: Set<UUID> = ChatPageModel.isDispatchExportScene
        ? [UUID(uuidString: "00000000-0000-0000-0000-00000000B303")!] : []
    /// 主導／副審的模型 id；由膠囊面板的角色選單寫入，送出時併進上游宣告給引擎看。
    @Published var ultraworkPrimaryModelID: String?
    @Published var ultraworkSecondaryModelID: String?
    var isCLIRuntimeEnabled: Bool {
        (isLive && SpaceWorkspaceController.shared.allows(.cli)) || Self.exportChatScene == "cli-多session"
    }
    var planFlowSelectionProjection: PlanFlowSelectionProjectionV1? { nil }
    var planWorkOSLocalActionPresentation: ChatPlanWorkOSLocalActionPresentation { .idle }
    var selectedThreadPluginIDs: [String] { isLive ? selectedThreadPluginEntries.map(\.id) : [] }
    /// `$` 技能選單：只有打了 `$` 且後面還沒空白時才有東西（1.0 :918-930）。
    /// 沒有這道 gate，那排膠囊就會常駐——2026-09-04 使用者回報的就是這個。
    var skillSuggestions: [PluginRegistryEntry] {
        guard isLive, let query = activeSkillQuery else { return [] }
        let lowered = query.lowercased()
        let skills = availableThreadPluginEntries.filter { $0.kind == .skill || $0.id == "tatwo-ultrawork" }
        let matches = skills.filter { entry in
            lowered.isEmpty
                || entry.id.lowercased().contains(lowered)
                || entry.name.lowercased().contains(lowered)
                || (entry.path ?? "").lowercased().contains(lowered)
        }
        return Array(matches.prefix(6))
    }

    private var activeSkillQuery: String? {
        guard let dollar = prompt.lastIndex(of: "$") else { return nil }
        let suffix = prompt[prompt.index(after: dollar)...]
        if suffix.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
        return String(suffix)
    }
    var activePendingHandoff: ChatHandoffEnvelope? { nil }
    var composerFooterState: ChatComposerFooterState { .neutral }
    // 2026-09-04：改回 1.0 的算出來的屬性（原本是 stored，只在 init 賦值一次，
    // 導致切模型永遠停在 gpt-5.5）。來源：ChatPageModel+StateAndSelection.swift:391
    var routeChoice: ChatRouteChoice { ChatRouteChoice.resolve(selectedModel) }
    var pendingRouteChoice: ChatRouteChoice? { pendingModelID.map(ChatRouteChoice.resolve) }
    var modelPickerRouteLabel: String {
        guard let pendingRouteChoice, pendingRouteChoice.id != routeChoice.id else { return routeChoice.title }
        return "\(routeChoice.title) · 下一輪 \(pendingRouteChoice.title)"
    }
    var activeSubagentRows: [ThreadSubagentPresentationRow] { [] }
    var visibleIssueListEntries: [TatwoIssueListEntryV1] { issueListEntries.filter { $0.status != .archived } }
    var filteredProjects: [TatwoNativeChatProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = document.projects.filter { $0.id != document.generalProjectID }
        guard !query.isEmpty else { return projects }
        return projects.compactMap { project in
            var result = project
            result.isExpanded = true
            if project.name.localizedCaseInsensitiveContains(query) { return result }
            // Keep ancestors so a matching child remains reachable in the
            // existing project tree. Search never changes stored expansion.
            let byID = Dictionary(project.threads.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
            var included = Set(project.threads.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.lastPreview.localizedCaseInsensitiveContains(query)
            }.map(\.id))
            for id in Array(included) {
                var parent = byID[id]?.parentThreadID
                var visited = Set<UUID>([id])
                while let next = parent, visited.insert(next).inserted {
                    included.insert(next)
                    parent = byID[next]?.parentThreadID
                }
            }
            result.threads = project.threads.filter { included.contains($0.id) }
            return result.threads.isEmpty ? nil : result
        }
    }
    var bindingSummary: String { "Chat · \(routeChoice.title)" }
    var selectedThread: TatwoNativeChatThread? {
        activeConversationDocument.projects.lazy.flatMap(\.threads).first { $0.id == selectedThreadID }
    }
    var activePendingHandoffSummary: String { activePendingHandoff?.summaryLine ?? "" }
    var activeLoopsConfig: TatwoNativeThreadLoopsConfig? { selectedThread?.loopsConfig }
    var collaborationIsEnabled: Bool { collaborationLevel != .off }
    /// `/` 指令清單。語意由 OS 上游宣告（docs/os-upstream.md）告訴各家引擎，
    /// /issue 與 /討論串由本機處理；其餘語意交原生引擎。
    static let slashCommandItems: [SlashCommandItem] = [
        SlashCommandItem(id: "/pr", cmd: "/pr", title: "/pr — 提交程式碼",
            subtitle: "先討論計畫，確認實作後再送 PR", icon: "arrow.triangle.branch"),
        SlashCommandItem(id: "/feedback", cmd: "/feedback", title: "/feedback — 回報問題",
            subtitle: "檢查原文並確認後，提交至 \(FeedbackSettings.feedbackRepository)", icon: "bubble.left.and.exclamationmark.bubble.right"),
        SlashCommandItem(id: "/plg", cmd: "/plg", title: "/plg — 開工：討論好就派工",
            subtitle: "先講清楚要做什麼，確認後由主導開房間派 sub", icon: "point.3.filled.connected.trianglepath.dotted"),
        SlashCommandItem(id: "/plan", cmd: "/plan", title: "/plan — 只討論不動手",
            subtitle: "純規劃釐清；沒有你的「開始」就不改任何檔", icon: "list.bullet.rectangle"),
        SlashCommandItem(id: "/goal", cmd: "/goal", title: "/goal — 開一張目標卡",
            subtitle: "目標寫進右側資訊卡，之後逐條對齊驗收", icon: "target"),
        SlashCommandItem(id: "/issue", cmd: "/issue", title: "/issue — 支線等待佇列",
            subtitle: "/issue <文字> 捕捉支線；/issue 打開佇列（不啟動執行）", icon: "tray.full"),
        SlashCommandItem(id: "/討論串", cmd: "/討論串", title: "/討論串 — 開啟子討論串",
            subtitle: "主題保留為草稿，送出後才開始工作", icon: "bubble.left.and.bubble.right"),
        SlashCommandItem(id: "/顯示討論串", cmd: "/顯示討論串", title: "/顯示討論串 — 叫回討論串列",
            subtitle: "顯示目前對話的討論串，不啟動或中斷工作", icon: "chevron.up"),
        SlashCommandItem(id: "/蒸餾", cmd: "/蒸餾", title: "/蒸餾 — 把這串的經驗蒸餾進 GBrain",
            subtitle: "需要 gbrain MCP；沒掛就會直說工具不可用", icon: "drop.triangle"),
    ]

    var matchingSlashCommands: [SlashCommandItem] {
        guard mode == .chat else { return [] }
        let ids = Set(ChatComposerSlashCatalog.matches(prompt: prompt).map(\.command))
        return Self.slashCommandItems.filter { ids.contains($0.cmd) }
    }
    var sendAvailabilityDiagnostic: String {
        if isLocalPRCommand { return "檢查改動並開啟 PR 草稿" }
        if isLocalFeedbackCommand { return "開啟回報草稿，不中斷目前工作" }
        if isLocalIssueCommand { return "記錄問題，不中斷目前工作" }
        if isLocalDiscussionCommand { return "開啟討論串，不啟動模型" }
        if isShowDiscussionTrayCommand { return "顯示討論串，不中斷目前工作" }
        if canSteerCurrentTurn { return "插話到目前工作" }
        return canSend ? "可送出" : (isRunning ? "工作執行中" : "請輸入內容")
    }
    var archivedThreadCount: Int {
        isLive ? (activeConversationEngine?.archivedThreadCount ?? 0) : 0
    }
    var selectedThreadProject: TatwoNativeChatProject? {
        activeConversationDocument.projects.first { project in
            project.threads.contains { $0.id == selectedThreadID }
        }
    }
    var selectedThreadPluginSummary: String {
        guard isLive else { return "無 plugins" }
        let selected = selectedThreadPluginEntries
        let skills = availableThreadPluginEntries.filter { $0.kind == .skill }.count
        if selected.isEmpty { return "無 MCP 常駐・\(skills) skills" }
        return "\(selected.count) MCP 常駐・\(skills) skills"
    }
    var pinnedThreadRefs: [ChatSidebarThreadRef] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return document.projects.flatMap { project in
            project.threads.filter {
                $0.isPinned && (query.isEmpty
                    || project.name.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.lastPreview.localizedCaseInsensitiveContains(query))
            }.map { ChatSidebarThreadRef(
                project: project.id == document.generalProjectID ? nil : project, thread: $0) }
        }.sorted {
            let lhs = threadActivityDate($0.thread), rhs = threadActivityDate($1.thread)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    var activeMappings: [TatwoNativeCLIFeatureMapping] { [] }
    var availableThreadPluginEntries: [PluginRegistryEntry] {
        guard isLive else { return [] }
        let engine = selectedMCPEngine
        return pluginEntries.filter {
            $0.kind == .skill || (PluginsSource.mcpEngine(from: $0.id) == engine)
        }.sorted {
            if $0.kind != $1.kind { return $0.kind == .mcp }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    var selectedThreadLoopsSessions: [TatwoLoopsSession] { [] }
    var selectedThreadArchivedLoopsSessions: [TatwoLoopsSession] { [] }
    var selectedThreadSupervisorModelID: String { "gpt-5.5" }
    var loopsLiveRows: [TatwoLoopsLiveRow] { [] }
    var activePLGRun: TatwoPLGRun? { nil }
    var selectedDispatchRuntimeProjection: TatwoDispatchRuntimeProjection { .init() }
    var selectedGoalRecord: TatwoStoredGoalRun? { nil }
    var plgError: String? { nil }
    var canAdvanceNativeDevelopmentCycle: Bool { false }
    /// `@` 搜尋結果：標題／內文／來源逐筆比對，最多 8 筆。1.0 :367
    var issueAtMentionMatches: [TatwoIssueListEntryV1] {
        guard let query = issueAtMentionQuery else { return [] }
        let matched = query.isEmpty ? issueListEntries : issueListEntries.filter {
            $0.title.lowercased().contains(query)
                || $0.body.lowercased().contains(query)
                || $0.sourceReference.lowercased().contains(query)
        }
        // 使用者 2026-09-05：@ 統一叫出，本串排上段、全域排下段
        let current = selectedThreadID?.uuidString
        let mine = matched.filter { $0.threadReference == current }
        let others = matched.filter { $0.threadReference != current }
        return Array((mine + others).prefix(10))
    }
    var effectivePermissionMappingSummary: String { permissionPreset.mappingSummary }
    var sidebarStandaloneThreads: [TatwoNativeChatThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = document.projects.first { $0.id == document.generalProjectID }?.threads ?? []
        return threads.filter {
            !$0.isPinned && (query.isEmpty
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.lastPreview.localizedCaseInsensitiveContains(query))
        }.sorted {
            let lhs = threadActivityDate($0), rhs = threadActivityDate($1)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    var activeGoalNextActionLabel: String { isLive ? activeGoalStatusPresentationLabel : "繼續完成畫面" }
    var activeGoalStatusPresentationLabel: String {
        guard isLive else { return "進行中" }
        if nativeGoalControlPending { return "正在更新目標" }
        guard let goal = nativeGoalSnapshot else {
            if let id = selectedThreadID, localLive?.nativeGoalError(id) != nil { return "目標狀態無法確認" }
            return nativeGoalIsCurrent ? "無目標" : "目標狀態未確認"
        }
        return nativeGoalIsCurrent ? goal.statusLabel : "上次：\(goal.statusLabel)"
    }
    var activeGoalStepProgressLabel: String { "\(activeGoalStepProgress.current) / \(activeGoalStepProgress.total)" }
    var activePlanTurnAssistantMessageID: String? { nil }
    var activeWorkOSLeadLabel: String { selectedModel }
    var activeWorkOSLine: String { "單模型 chat" }
    var activeWorkOSLoopsLabel: String { "未啟用" }
    var activeWorkOSModeLabel: String { "S" }
    var canOpenThreadInCLI: Bool {
        guard selectedRemote == nil else { return false }
        guard
            isLive,
            let record = live?.threadRecord(selectedThreadID),
            let project = live?.projectRecord(record.projectID)
        else { return false }
        var isDirectory: ObjCBool = false
        return !project.workdir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && FileManager.default.fileExists(atPath: project.workdir, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
    var isLocalPRCommand: Bool {
        TatwoSlashCommandParser.prArgument(in: prompt) != nil
    }
    var isLocalFeedbackCommand: Bool {
        TatwoSlashCommandParser.feedbackArgument(in: prompt) != nil
    }
    var isLocalIssueCommand: Bool {
        let command = prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first
        return command == "/issue"
    }
    var isLocalDiscussionCommand: Bool {
        prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "/討論串"
    }
    var isShowDiscussionTrayCommand: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "/顯示討論串"
    }
    private var discussionTrayKey: String {
        "\(selectedRemote?.deviceID ?? "local"):\(selectedThreadID?.uuidString ?? "preview")"
    }
    var isDiscussionTrayHidden: Bool { hiddenDiscussionTrayKeys.contains(discussionTrayKey) }
    func hideDiscussionTray() { hiddenDiscussionTrayKeys.insert(discussionTrayKey) }
    func showDiscussionTray() { hiddenDiscussionTrayKeys.remove(discussionTrayKey) }
    var isLocalNativeGoalCommand: Bool {
        routeChoice.brandGroup == .openAI && prompt.split(maxSplits: 1, whereSeparator: \.isWhitespace).first == "/goal"
    }
    var canSend: Bool {
        let hasContent = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !droppedPaths.isEmpty
        if isLocalPRCommand || isLocalFeedbackCommand || isLocalIssueCommand || isLocalDiscussionCommand || isShowDiscussionTrayCommand { return hasContent }
        return hasContent && !nativeGoalControlPending &&
            (!isRunning || isLocalNativeGoalCommand || canSteerCurrentTurn)
    }
    var canSteerCurrentTurn: Bool {
        guard selectedRemote == nil, routeChoice.brandGroup == .openAI, let id = selectedThreadID else { return false }
        return localLive?.canSteer(id) == true
    }
    var codexMirrorStatusMessage: String {
        switch codexMirrorStatus {
        case .loaded: "Codex 鏡射已啟用"
        case .notEnabled: "Codex 鏡射未啟用"
        case .unavailable: "Codex 鏡射不可用"
        }
    }
    var isActivePlanTurnWriting: Bool { isPlanModeEnabled && isRunning }
    var isPlanModeEnabled: Bool { activePlanArtifact?.state == .discussing }
    var isSelectedThreadStandalone: Bool { selectedThreadProject == nil && selectedThread != nil }
    /// composer 尾端 `@` token 的搜尋字（nil＝沒有 @ token）。1.0 :358
    var issueAtMentionQuery: String? {
        guard let token = prompt.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init),
              token.hasPrefix("@") else { return nil }
        return String(token.dropFirst()).lowercased()
    }
    var queuedChatTurnCount: Int { 0 }
    var remoteMode: DeviceRecord? {
        guard let deviceID = selectedRemote?.deviceID else { return nil }
        return remoteSessions.first { $0.device.id == deviceID }?.device
    }
    var remoteModeLabel: String? { remoteMode.map { "遠端：\($0.name)" } }
    var selectedProjectName: String { selectedThreadProject?.name ?? "無專案" }
    var selectedThreadPluginEntries: [PluginRegistryEntry] {
        guard isLive else { return [] }
        return availableThreadPluginEntries.filter { $0.kind == .mcp && isThreadPluginEnabled($0.id) }
    }
    var shouldOfferCodexMirrorOptIn: Bool { false }
    var shouldShowActiveGoalInlineCard: Bool { isLive && nativeGoalSnapshot != nil }
    var transcriptMessages: [ChatMessage] {
        isLive ? (activeConversationEngine?.transcript(for: selectedThreadID) ?? []) : fixture.messages + fixtureExtraMessages
    }

    private var activeRemoteSession: RemoteDeviceSession? {
        guard let deviceID = selectedRemote?.deviceID else { return nil }
        return remoteSessions.first { $0.device.id == deviceID }
    }

    private var activeConversationEngine: (any LiveEngineAPI)? {
        selectedRemote == nil ? localLive : activeRemoteSession?.engine
    }

    func receiveLocalBackgroundCompletion(_ job: BackgroundJobManager.Record) {
        localLive?.appendBackgroundCompletion(job)
    }

    private var activeConversationDocument: TatwoNativeChatStoreDocument {
        selectedRemote == nil ? document : (activeRemoteSession?.document ?? .init())
    }

    private func configureRemoteSessions() {
        for session in remoteSessions { session.shutdown() }
        guard isLive else {
            remoteSessions = []
            remoteSidebarSections = []
            return
        }
        remoteSessions = devices.map { device in
            let session = RemoteDeviceSession(
                device: device,
                link: RemoteHostLink(environment: runtimeEnvironment),
                environment: runtimeEnvironment)
            session.onHint = { [weak self] message in
                guard let self, self.selectedRemote?.deviceID == device.id else { return }
                self.composerHint = message
            }
            session.onUpdate = { [weak self, weak session] in
                guard let self, let session else { return }
                self.scheduleRemoteSidebarProjection()
                guard self.selectedRemote?.deviceID == session.device.id else { return }
                self.isRunning = session.engine?.isRunning(self.selectedThreadID) ?? false
                self.refreshIssueLists()
                self.objectWillChange.send()
            }
            return session
        }
        rebuildRemoteSidebarSections()
        let synchronousTestConnect =
            runtimeEnvironment["TATWO2_PARALLELTEST"] == "1"
            || runtimeEnvironment["TATWO2_REMOTEUITEST"] == "1"
        for session in remoteSessions {
            if synchronousTestConnect {
                _ = session.connectNow()
            } else {
                session.start()
            }
        }
        if synchronousTestConnect { rebuildRemoteSidebarSections() }
    }

    private func scheduleRemoteSidebarProjection() {
        let elapsed = Date().timeIntervalSince(lastRemoteProjectionAt)
        if elapsed >= 2 {
            rebuildRemoteSidebarSections()
            return
        }
        guard remoteProjectionTask == nil else { return }
        remoteProjectionTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(max(0, 2 - elapsed)))
            guard !Task.isCancelled else { return }
            self.remoteProjectionTask = nil
            self.rebuildRemoteSidebarSections()
        }
    }

    private func rebuildRemoteSidebarSections() {
        remoteProjectionTask?.cancel()
        remoteProjectionTask = nil
        lastRemoteProjectionAt = Date()
        remoteSidebarSections = remoteSessions.map { session in
            let isOnline: Bool
            if case .online = session.state {
                isOnline = true
            } else {
                isOnline = false
            }
            let projects = session.document.projects.map { project in
                RemoteProjectRow(
                    id: project.id,
                    name: project.name,
                    threads: project.threads.map { thread in
                        let statusLine: String
                        if let liveness = thread.liveness {
                            statusLine = liveness.label
                        } else {
                            statusLine = thread.lastPreview
                        }
                        return RemoteThreadRow(
                            id: thread.id,
                            title: thread.title,
                            statusLine: statusLine,
                            isRunning: session.engine?.isRunning(thread.id) ?? false)
                    })
            }
            return RemoteSidebarSection(
                deviceID: session.device.id,
                deviceName: session.device.name,
                isOnline: isOnline,
                lastSeenAt: session.lastSeenAt,
                projects: projects)
        }
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment, botCoreFixture: (ChatLiveEngine, BotStore)? = nil) {
        self.runtimeEnvironment = environment
        let engineLogin = EngineLogin(environment: environment)
        self.engineLogin = engineLogin
        let deviceRegistry = DeviceRegistry(environment: environment)
        self.deviceRegistry = deviceRegistry
        self.devicePairingHost = DevicePairingHost(registry: deviceRegistry, environment: environment)
        self.githubAccountsStore = GitHubAccountsStore(environment: environment)
        let fixture = ChatFixture.resolve(environment: environment)
        self.fixture = fixture
        self.pluginEntries = PluginsSource.load(environment: environment)
        self.selectedModel = fixture.selectedModel
        self.isRunning = fixture.isRunning
        if environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil {
            self.prompt = environment["TATWO_ULTRAWORK_EXPORT_CHAT_PROMPT"] ?? ""
        }
        self.engineLogins = engineLogin.statuses()
        let liveMode = environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] == nil
            && environment["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"] == nil
            && environment["TATWO_ULTRAWORK_CHAT_FIXTURE"] == nil
            && environment["TATWO2_SELFTEST"] != "1"
        // 匯出（金樣）模式給兩台假設備，讓設定頁「設備」卡看得到清單的長相
        let fixtureDevices: [DeviceRecord] = [
            DeviceRecord(id: "fixture-macbook", name: "MacBook（出門用）", host: "192.168.0.225", user: "chenyawei", sshPort: 22,
                         publicKeyFingerprint: "SHA256:qJ3v9nQb1xKfP2wYzR8tL4mH7cD0eA5sV6uB9nC1xYz", addedAt: Date(timeIntervalSinceReferenceDate: 799_000_000),
                         lastSeenAt: Date(timeIntervalSinceReferenceDate: 800_000_000), workdirMap: [:]),
            DeviceRecord(id: "fixture-studio", name: "工作室 Studio", host: "ssh-studio.tatwo214.com", user: "layer2", sshPort: 22,
                         publicKeyFingerprint: "SHA256:aB8cD3eF6gH9iJ2kL5mN8oP1qR4sT7uV0wX3yZ6aB9c", addedAt: Date(timeIntervalSinceReferenceDate: 798_500_000),
                         lastSeenAt: Date(timeIntervalSinceReferenceDate: 799_900_000), workdirMap: [:]),
        ]
        if liveMode { self.devices = deviceRegistry.list() } else { self.devices = fixtureDevices }
        if !liveMode {
            self.gitHubAccounts = [
                GitHubAccountRecord(username: "tatwo214", displayName: "tatwo214（刺青與 OS）", addedAt: Date(timeIntervalSinceReferenceDate: 799_000_000), scopes: ["repo", "workflow"], isDefault: true, folderMappings: [], mcpAlwaysOn: true),
                GitHubAccountRecord(username: "JNSlayer2", displayName: "JNSlayer2（幼兒園研發部）", addedAt: Date(timeIntervalSinceReferenceDate: 799_500_000), scopes: ["repo"], isDefault: false, folderMappings: ["\(NSHomeDirectory())/Library/Application Support/tatwo2/repos/jns"], mcpAlwaysOn: false),
            ]
            self.gitHubHelperInstalled = true
        }
        if !liveMode {
            self.engineLogins = [
                EngineLoginStatus(kind: .codex, isLoggedIn: true, account: "demo-account", detail: "登入資料在 App 自己的資料夾，跟 Codex App 分開"),
                EngineLoginStatus(kind: .claude, isLoggedIn: true, account: "demo-account", detail: ""),
                EngineLoginStatus(kind: .grok, isLoggedIn: false, account: nil, detail: "按「登入」會開瀏覽器走 xAI 的授權"),
            ]
        }
        if !liveMode {
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            self.engineQuotaDetails = [
                "codex": EngineQuotaDetail(tierLabel: "Pro", accountLabel: "demo-account", expiresAt: now.addingTimeInterval(86_400 * 23), subscribedAt: now.addingTimeInterval(-86_400 * 160),
                                           windows: [.init(id: "codex.primary", label: "週上限", usedPercent: 43, resetsAt: now.addingTimeInterval(3_600 * 52)),
                                                     .init(id: "spark.primary", label: "GPT-5.3-Codex-Spark 5 小時", usedPercent: 0, resetsAt: now.addingTimeInterval(3_600 * 4)),
                                                     .init(id: "spark.secondary", label: "GPT-5.3-Codex-Spark 週上限", usedPercent: 0, resetsAt: now.addingTimeInterval(86_400 * 6))],
                                           creditsBalance: nil, note: "OpenAI 官方額度", fetchedAt: now),
                "claude": EngineQuotaDetail(tierLabel: "Max ×5", accountLabel: "demo-account", expiresAt: nil, subscribedAt: now.addingTimeInterval(-86_400 * 165),
                                            windows: [.init(id: "five_hour", label: "5 小時", usedPercent: 40, resetsAt: now.addingTimeInterval(3_600 * 2)),
                                                      .init(id: "seven_day", label: "週上限", usedPercent: 19, resetsAt: now.addingTimeInterval(86_400 * 5)),
                                                      .init(id: "nimbus_quill", label: "Fable 週上限", usedPercent: 0, resetsAt: nil)],
                                            creditsBalance: nil, note: "Anthropic 官方額度", fetchedAt: now),
                "grok": EngineQuotaDetail(tierLabel: "SuperGrok", accountLabel: "demo-account", expiresAt: nil, subscribedAt: nil, windows: [], creditsBalance: nil, note: "xAI 沒有提供額度查詢接口", fetchedAt: nil),
            ]
        }
        self.isLive = liveMode
        if let (engine, store) = botCoreFixture {
            self.live = engine
            self.localLive = engine
            connectPlanCanvas(to: engine)
            self.botStore = store
            self.document = engine.document
            self.selectedThreadID = engine.doc.selectedThreadID
            loadActivePlanCanvas()
            self.isRunning = false
            restoreModelPreferences()
            return
        }
        if liveMode {
            // 使用者 2026-09-07：OS 初始預設 GPT-6／中思考／Fast；不遷移既有討論串或更動金樣。
            selectedModel = "gpt-6-astra"
            selectedEffort = .medium
            selectedSpeedTier = .fast
        }
        CLISessionsTermination.model = self
        if !liveMode {
            let mk = { (id: String, label: String, path: String, state: UpstreamBindingStatus.State, detail: String) in
                UpstreamBindingStatus(target: UpstreamBindingTarget(id: id, label: label, path: path), state: state, detail: detail) }
            self.upstreamBindings = [
                mk("claude-cli", "Claude CLI（~/.claude/CLAUDE.md）", "\(NSHomeDirectory())/.claude/CLAUDE.md", .bound, "已接，跟現在的一頁一致"),
                mk("codex-cli", "Codex CLI（~/.codex/AGENTS.md）", "\(NSHomeDirectory())/.codex/AGENTS.md", .stale, "有代差：一頁規則改過，還沒重新對齊"),
                mk("app-grok", "OS 內的 Grok（獨立資料夾 GROK.md）", "…/engines/grok/GROK.md", .unbound, "還沒接"),
                mk("openclaw:workspace-dashboard", "OpenClaw workspace-dashboard", "\(NSHomeDirectory())/Library/Application Support/tatwo2/openclaw-workspaces/workspace-dashboard/AGENTS.md", .unreachable, "讀不到（資料夾不在或沒權限）"),
            ]
        }
        if !liveMode, Self.exportChatScene == "chat-typing" {
            fixtureExtraMessages = [ChatMessage(role: .user, text: "幫我看一下模型登入頁的額度條為什麼沒對齊", turnID: "fixture-typing")]
            self.isRunning = true
        }
        if !liveMode, Self.exportChatScene == "chat-artifacts" {
            fixtureExtraMessages = [
                ChatMessage(role: .user, text: "把設定頁的額度條改成靠左，並補一份報告", turnID: "fixture-artifacts"),
                ChatMessage(role: .assistant, text: "改好了：額度條靠左對齊，倒數置中；報告寫在 docs/goal-ui-2.0/reports/quota-bar.md。", status: "done", turnID: "fixture-artifacts"),
            ]
            latestTurnArtifacts = TurnArtifactIndex(
                threadID: UUID(uuidString: "00000000-0000-0000-0000-00000000A0A0")!, turnID: "fixture-artifacts", messageID: nil,
                endedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                artifacts: [
                    TurnArtifact(path: "App/Sources/Tatwo2/New/EngineLoginCard.swift", kind: "file", claimed: true, exists: true, sizeBytes: 18_432, sha256: nil, verifiedBy: "lead"),
                    TurnArtifact(path: "docs/goal-ui-2.0/reports/quota-bar.md", kind: "report", claimed: true, exists: true, sizeBytes: 2_310, sha256: nil),
                    TurnArtifact(path: "docs/UI定位冊/截圖/manifest.tsv", kind: "file", claimed: false, exists: true, sizeBytes: 9_870, sha256: nil),
                    TurnArtifact(path: "shots/quota-bar-after.png", kind: "file", claimed: true, exists: false, sizeBytes: nil, sha256: nil),
                ], truncated: false)
        }
        if !liveMode, Self.exportChatScene == "chat-error" {
            fixtureExtraMessages = [
                ChatMessage(role: .user, text: "跑一下測試", turnID: "fixture-error"),
                ChatMessage(role: .system, text: "回合失敗：{\"error\":{\"message\":\"Rate limit reached for gpt-6-astra: weekly limit exhausted, resets in 3d 4h\",\"type\":\"rate_limit\"},\"turnId\":\"t-8813\"}", status: "error|回合失敗", turnID: "fixture-error"),
            ]
        }
        if !liveMode, Self.exportChatScene == "remote-sidebar" {
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            self.remoteSidebarSections = [
                RemoteSidebarSection(deviceID: "fixture-mini", deviceName: "mini（家裡）", isOnline: true, lastSeenAt: now,
                                     projects: [RemoteProjectRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "tatwo2",
                                                                 threads: [RemoteThreadRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!, title: "左列並行實測", statusLine: "GPT 回覆中", isRunning: true),
                                                                           RemoteThreadRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, title: "GitHub MCP 真帳號測試", statusLine: "好", isRunning: false)]),
                                                RemoteProjectRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "一般",
                                                                 threads: [RemoteThreadRow(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!, title: "PO 文 bot", statusLine: "乒", isRunning: false)])]),
                RemoteSidebarSection(deviceID: "fixture-studio", deviceName: "工作室 Studio", isOnline: false, lastSeenAt: now.addingTimeInterval(-3_600 * 5), projects: []),
            ]
        }
        if !liveMode, let first = OSDocuments.list().first {
            osDocumentText[first.id] = "# TATWO OS 2.0 憲法（示意）\n\n## 0. 一句話\nOS 是所有 AI 引擎的上游：規則、技能、工具、記錄由 OS 統一發，引擎只是肌肉。\n\n## 3. 硬規則\n1. 拆之前先討論；封存不直刪；沒有回覆就不動。\n2. 派工無監工＝不算在跑；沉默≠進度。\n"
        }
        self.githubAccountsStore.$deviceCode.assign(to: &$githubDeviceCode)
        self.githubAccountsStore.$verificationURL.assign(to: &$githubVerificationURL)
        self.githubAccountsStore.onEvent = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.appendGitHubLoginLog(message)
            }
        }
        refreshGitHubAccounts()
        self.devicePairingHost.onClose = { [weak self] in
            Task { @MainActor in
                self?.pairingWindow = nil
                self?.pairingListenAddress = nil
                self?.devices = self?.deviceRegistry.list() ?? []
                self?.configureRemoteSessions()
            }
        }
        if liveMode {
            let root = environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let store = ChatLiveStore(root: root)
            let engine = ChatLiveEngine(store: store, environment: environment)
            self.cliSessionStore = CLISessionStore(root: root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/tatwo2/live"))
            self.previousCLITabIDs = Set(self.cliSessionStore?.sessions.map(\.id) ?? [])
            self.cliStore = store
            self.localLive = engine
            connectPlanCanvas(to: engine)
            self.live = engine
            engine.autoApprove = permissionPreset == .approveForMe
            engine.userPermissionPreset = permissionPreset
            self.botStore = BotStore(root: root)
            self.document = engine.document
            self.selectedThreadID = engine.doc.selectedThreadID
            loadActivePlanCanvas()
            self.localSelectedThreadID = engine.doc.selectedThreadID
            self.isRunning = false
            restoreModelPreferences()
            engine.onChange = { [weak self] in
                guard let self, let live = self.live else { return }
                self.document = live.document
                if self.selectedRemote == nil {
                    self.isRunning = live.isRunning(self.selectedThreadID)
                }
                self.applyPendingModelSelectionIfPossible()
                if SpaceWorkspaceController.shared.state != nil { self.applySpaceRuntimePreferences() }
                if self.selectedRemote == nil {
                    self.refreshIssueLists()
                    if !self.isRunning { self.refreshGitStatus() }
                }
                self.objectWillChange.send()
            }
            refreshIssueLists(); refreshGitStatus()
            engine.onHint = { [weak self] hint in self?.composerHint = hint }
            engine.onRoomArchived = { [weak self, weak engine] roomID in
                guard let self, let engine else { return }
                do {
                    _ = try self.reclaimRoom(roomID)
                } catch {
                    engine.appendSystemMessage(
                        threadID: roomID,
                        text: "房間封存但工作樹回收失敗：\(error)",
                        status: "error|房間回收")
                }
            }
            engine.permissionDecider = { [weak self] tool, input in
                guard let self else { return false }
                let alert = NSAlert()
                alert.messageText = "工具執行需要核准：\(tool)"
                alert.informativeText = String(input.prefix(1200))
                alert.addButton(withTitle: "允許"); alert.addButton(withTitle: "拒絕")
                return alert.runModal() == .alertFirstButtonReturn
            }
            if environment["TATWO2_BOTTEST"] == "1" {
                scheduleBotSelfTest(environment: environment)
            }
            reloadPluginRegistry()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await SpaceWorkspaceController.shared.load(model: self)
                if SpaceWorkspaceController.shared.allows(.cli) {
                    self.initializeCLIWorkbench(environment: environment)
                    self.loadPersistedCLISessionBook()
                }
                self.applySpaceRuntimePreferences()
            }
            BrowserAgentBridge.shared.start(model: self)
            OSAgentBridge.shared.start(model: self)
            configureRemoteSessions()
            return
        }

        let threadID = UUID(uuidString: "E3DB5E91-9B88-4485-87B9-AB7B877C2E21")!
        let thread = TatwoNativeChatThread(
            id: threadID,
            title: fixture.threadTitle,
            isPinned: true,
            lastPreview: fixture.messages.last?.text ?? "",
            workOSContractID: fixture.hasWorkOSGoal ? "fixture-contract" : nil,
            workOSGoalID: fixture.hasWorkOSGoal ? "fixture-goal" : nil)
        if fixture.sceneID == "orphan" {
            self.document = TatwoNativeChatStoreDocument(projects: [])
        } else {
            var threads = [thread]
            if Self.exportChatScene == "subthreads" || Self.isDispatchExportScene {
                // B1／B3 假資料：主串底下三條子討論串（active／idle／done）
                let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
                threads += [
                    TatwoNativeChatThread(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B301")!, title: "房間A 升版與遷移", lastPreview: "正在跑 doctor --fix", parentThreadID: threadID, liveness: .active, lastOutputAt: now.addingTimeInterval(-180), engineLabel: "sol"),
                    TatwoNativeChatThread(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B302")!, title: "房間B Discord 外掛", lastPreview: "等待 npm", parentThreadID: threadID, liveness: .idle, lastOutputAt: now.addingTimeInterval(-6 * 60), engineLabel: "sol"),
                    TatwoNativeChatThread(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B303")!, title: "副審", lastPreview: "報告已送出", parentThreadID: threadID, liveness: .done, lastOutputAt: now.addingTimeInterval(-20 * 60), engineLabel: "opus"),
                ]
            }
            self.document = TatwoNativeChatStoreDocument(
                projects: [
                    TatwoNativeChatProject(
                        name: "Tatwo2 UI",
                        workdir: FileManager.default.currentDirectoryPath,
                        threads: threads)
                ])
            if ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_SETTINGS_SECTION"] == "browserManagement" {
                // B5 假資料：兩條討論串留著開啟的網頁
                var lanes = TatwoBrowserLaneState()
                lanes = TatwoBrowserLaneReducer.reduce(state: lanes, action: .open(id: TatwoBrowserLaneID(rawValue: "fx-1"), binding: .unboundReadOnly, title: "TradingView"), now: Date(timeIntervalSinceReferenceDate: 800_000_000))
                let snap = BrowserLaneSnapshot(laneState: lanes, laneURLs: ["fx-1": URL(string: "https://tw.tradingview.com/symbols/BTCUSD/")!], updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
                browserLanesBySession[threadID.uuidString.lowercased()] = snap
            }
        }
        self.selectedThreadID = threadID
        if Self.exportChatScene == "cli-多session" {
            mode = .cli
            cliUIFixtureRecords = CLISessionsFixture.records
            let tabs = cliUIFixtureRecords.prefix(3).map { record in
                TatwoNativeCLISessionBook.Session(id: record.id, engine: .init(rawValue: record.engine) ?? .generic, title: record.title,
                    workdir: record.cwd, createdAt: record.createdAt, updatedAt: record.lastActiveAt,
                    isRunning: record.status != .exited)
            }
            cliSessionsByThread[threadID] = tabs
            activeCLITabByThread[threadID] = tabs.first?.id
            for tab in tabs {
                cliTabOwner[tab.id] = threadID
                cliTabLinesByID[tab.id] = CLISessionsFixture.output.enumerated().map {
                    TatwoTerminalLine(id: $0.offset, spans: [.init(text: $0.element)])
                }
            }
        }
    }
    func refreshIssueLists() {
        guard let activeLive = activeConversationEngine else { return }
        allIssueListEntries = activeLive.issues(threadID: nil, global: true)
        issueListEntries = activeLive.issues(
            threadID: selectedThreadID,
            global: issueListShowsGlobal)
        archivedIssueListEntries = allIssueListEntries.filter { $0.status == .archived }
    }
    func refreshGitStatus() {
        guard selectedRemote == nil else {
            gitBranch = "—"
            gitChangedFileCount = 0
            gitChangedFilePreview = []
            gitChangedFiles = []
            gitChangedLineAdditions = 0
            gitChangedLineDeletions = 0
            return
        }
        guard let live else { return }
        refreshLatestTurnArtifacts()
        live.gitSummary(for: selectedThreadID) { [weak self] g in
            guard let self else { return }
            self.gitBranch = g.branch; self.gitChangedFileCount = g.files.count
            self.gitChangedFilePreview = Array(g.files.prefix(5))
            self.gitChangedFiles = g.files.map { ChatGitChangedFileSummary(path: $0, additions: g.perFile[$0]?.0 ?? 0, deletions: g.perFile[$0]?.1 ?? 0) }
            self.gitChangedLineAdditions = g.additions; self.gitChangedLineDeletions = g.deletions
        }
    }
    /// 讀最新回合的產出索引（背景讀檔，主執行緒只收結果）。
    func refreshLatestTurnArtifacts() {
        guard let threadID = selectedThreadID, let engine = live as? ChatLiveEngine else { latestTurnArtifacts = nil; return }
        let artifacts = engine.turnArtifacts
        Task { [weak self] in
            let index = try? await artifacts.list(threadID: threadID)   // actor：讀檔在它自己的執行緒
            guard let self, self.selectedThreadID == threadID else { return }
            self.latestTurnArtifacts = index
        }
    }

    /// 回合收尾卡點檔名：用系統預設程式打開工作樹裡的那個檔。
    func openArtifact(path: String) {
        guard !path.hasPrefix("/"), !path.contains("..") else { return }
        let engine = live as? ChatLiveEngine
        let record = selectedThreadID.flatMap { engine?.threadRecord($0) }
        let cwd = record.flatMap { t in t.cwdOverride ?? engine?.doc.projects.first { $0.id == t.projectID }?.workdir } ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { flashComposerHint("檔案不在了：\(path)"); return }
        NSWorkspace.shared.open(url)
    }

    func refreshAfterGoalRevisionPromotion() -> Bool { true }
    func scheduleColdStartHydrationAfterFirstFrame() {}
    func retryColdStartHydration() {}
    func reloadIssueList() {
        refreshIssueLists()
        refreshEngineLogins()
    }
    func loadOSDocument(id: String) {
        osDocuments = OSDocuments.list()
        do {
            osDocumentText[id] = try OSDocuments.read(id: id)
        } catch {
            flashComposerHint("讀取文件失敗：\(error.localizedDescription)")
        }
    }
    func saveOSDocument(id: String, text: String) {
        do {
            try OSDocuments.write(id: id, text: text)
            osDocumentText[id] = text
            osDocumentPending[id] = nil
            osDocuments = OSDocuments.list()
            flashComposerHint("已儲存 \(osDocuments.first(where: { $0.id == id })?.title ?? id)，舊版已備份")
        } catch {
            flashComposerHint("儲存文件失敗：\(error.localizedDescription)")
        }
    }
    func tidyOSDocument(id: String) {
        guard isLive, let live else {
            flashComposerHint("請 AI 整理只在 live 模式可用")
            return
        }
        let source: String
        do {
            source = try OSDocuments.read(id: id)
        } catch {
            flashComposerHint("讀取文件失敗：\(error.localizedDescription)")
            return
        }
        guard let document = OSDocuments.list().first(where: { $0.id == id }) else {
            flashComposerHint("找不到文件：\(id)")
            return
        }

        let engine: ClaudeSidecar.Kind
        let modelArgument: String?
        switch routeChoice.brandGroup {
        case .anthropic:
            engine = .claude
            modelArgument = routeChoice.modelArgument.flatMap { $0.hasPrefix("claude") ? $0 : nil }
        case .openAI:
            engine = .codex
            modelArgument = routeChoice.modelArgument ?? routeChoice.canonicalModelSlug
        case .xAI:
            engine = .grok
            modelArgument = nil
        default:
            flashComposerHint("\(routeChoice.title) 還沒有可用的文件整理水電")
            return
        }
        // 送出前只看快取的登入狀態（背景更新），不在主執行緒起子程序查；沒查過就先放行，引擎自己會報錯
        let loginStatus = engineLogins.first(where: { $0.kind == engine })
            ?? EngineLoginStatus(kind: engine, isLoggedIn: true, account: nil, detail: "尚未檢查")
        guard loginStatus.isLoggedIn else {
            flashComposerHint("\(engineLoginDisplayName(engine)) 還沒登入，到設定 › 模型存取登入")
            return
        }

        let projectID = live.doc.projects.first(where: { $0.name == "一般" })?.id
            ?? live.newProject(name: "一般", workdir: OSDocuments.docsRoot)
        let title = "文件整理：\(document.title)"
        let threadID = live.doc.threads.first(where: {
            $0.projectID == projectID && $0.title == title && !$0.isArchived
        })?.id ?? live.newThread(in: projectID, title: title)
        guard !live.isRunning(threadID) else {
            flashComposerHint("\(document.title) 的文件整理還在進行中")
            return
        }

        let previousReplyID = live.transcript(for: threadID)
            .last(where: { $0.role == .assistant && $0.eventKind == .message })?.id
        let note = osDocumentNote[id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let request = """
        把這份文件整理乾淨、保留所有規則、不新增規則、輸出完整檔案。

        檔案：\(document.title)
        使用者這次留的話：
        \(note.isEmpty ? "（沒有另外留言）" : note)

        目前完整內容：
        \(source)
        """
        osDocumentPending[id] = nil
        live.send(
            threadID: threadID,
            text: request,
            model: modelArgument,
            engine: engine,
            systemPrompt: nil,
            attachments: [])
        flashComposerHint("已送到「一般 › \(title)」；完成後先顯示差異，不會自動覆寫")

        Task { @MainActor [weak self, weak live] in
            guard let self, let live else { return }
            for _ in 0..<2_400 {
                try? await Task.sleep(for: .milliseconds(500))
                if live.isRunning(threadID) { continue }
                guard let reply = live.transcript(for: threadID)
                    .last(where: { $0.role == .assistant && $0.eventKind == .message }),
                      reply.id != previousReplyID
                else {
                    self.flashComposerHint("\(document.title) 整理沒有取得助理完整回覆")
                    return
                }
                self.osDocumentPending[id] = reply.text
                self.flashComposerHint("\(document.title) 整理完成；請先看差異，再按套用")
                return
            }
            self.flashComposerHint("\(document.title) 整理等待逾時，原檔未變更")
        }
    }
    func revalidatePendingRemoteTarget(verifiedTargetDeviceIDs: Set<String>?, definitiveLeaseLossBlocker: String?) {}
    func removeIssueListEntry(_ id: String) {
        if rejectRemoteWrite("issue") { return }
        live?.removeIssue(id)
        refreshIssueLists()
    }
    func restoreIssueFromArchive(_ id: String) {
        if rejectRemoteWrite("issue") { return }
        live?.updateIssue(id) { $0.status = .queued }
        refreshIssueLists()
    }
    /// 1.0 規格（os1-root/issue.md）：雙擊＋彈窗＋按「確認」共三段；單擊 no-op、取消保留。只封存佇列項，原討論不動。
    func archiveIssueListEntry(_ id: String) {
        if rejectRemoteWrite("issue") { return }
        let title = allIssueListEntries.first(where: { $0.id == id })?.title ?? ""
        if isLive {
            let alert = NSAlert()
            alert.messageText = "從佇列移除這則 issue？"
            alert.informativeText = "「\(title)」只會從佇列封存，原本的討論串與計畫不會被刪改。"
            alert.addButton(withTitle: "確認移除")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        live?.updateIssue(id) { $0.status = .archived }
        refreshIssueLists()
        flashComposerHint("已從佇列移除「\(title)」")
    }
    @discardableResult
    func openCLITab(engine: TatwoNativeCLISessionBook.Engine, workdir: String? = nil, callerThreadID: UUID? = nil) -> UUID? {
        guard isCLIRuntimeEnabled, selectedRemote == nil, let ownerID = callerThreadID ?? selectedThreadID else { return nil }
        guard !isLive || cliRuntime != nil else {
            flashComposerHint("CLI 正在讀取 Space 設定，請稍後再開啟")
            return nil
        }
        let cwd = workdir ?? selectedThreadProject?.workdir ?? NSHomeDirectory()
        let number = (cliSessionsByThread[ownerID]?.count ?? 0) + 1
        let title = "\(cliEngineTitle(engine)) \(number)"
        let tab = TatwoNativeCLISessionBook.Session(
            id: UUID(),
            engine: engine,
            title: title,
            workdir: cwd,
            createdAt: Date(),
            updatedAt: Date(),
            isRunning: false)
        cliSessionsByThread[ownerID, default: []].append(tab)
        activeCLITabByThread[ownerID] = tab.id
        cliTabOwner[tab.id] = ownerID
        startCLITab(tab, launch: launchForCLI(engine: engine, workdir: cwd))
        registerCLIWorkbenchPane(tab, owner: ownerID)
        persistCLITabs(ownerID: ownerID)
        objectWillChange.send()
        return tab.id
    }
    func selectCLITab(_ id: UUID) {
        guard let ownerID = cliTabOwner[id] else { return }
        if selectedThreadID != ownerID {
            selectedThreadID = ownerID
        }
        activeCLITabByThread[ownerID] = id
        focusCLIWorkbenchPane(id, owner: ownerID)
        cliSessionStore?.update(id) { $0.lastActiveAt = Date() }
        objectWillChange.send()
    }
    func closeCLITab(_ id: UUID) {
        Task { [weak self] in
            do { try await self?.terminateCLIWorkbenchPane(id) }
            catch { self?.composerHint = "無法結束終端：\(error.localizedDescription)" }
        }
    }
    var restorableCLITabs: [CLISessionStore.Record] {
        isLive ? (cliSessionStore?.sessions.filter { previousCLITabIDs.contains($0.id) } ?? []) : Array(cliUIFixtureRecords.dropFirst(3))
    }
    var cliTabsNeedingCloseConfirm: [CLISessionStore.Record] {
        cliSessionStore?.sessions.filter { cliTabPTYByID[$0.id]?.isRunning == true } ?? []
    }
    func terminateAllCLITabs() {
        for session in cliTabPTYByID.values { session.terminate() }
    }
    func renameCLITab(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        cliSessionStore?.update(id) { $0.title = title }
        if let owner = cliTabOwner[id], let i = cliSessionsByThread[owner]?.firstIndex(where: { $0.id == id }) {
            cliSessionsByThread[owner]?[i].title = title
            persistCLITabs(ownerID: owner)
        }
        objectWillChange.send()
    }
    func pinCLITab(_ id: UUID, pinned: Bool = true) {
        cliSessionStore?.update(id) { $0.pinned = pinned }
        objectWillChange.send()
    }
    func reorderCLITabs(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let all = (ids + (cliSessionStore?.sessions.map(\.id) ?? [])).filter { seen.insert($0).inserted }
        for (order, id) in all.enumerated() {
            cliSessionStore?.update(id) { $0.order = order }
            if !isLive, let index = cliUIFixtureRecords.firstIndex(where: { $0.id == id }) {
                cliUIFixtureRecords[index].order = order
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1, $0) })
        for owner in Array(cliSessionsByThread.keys) {
            cliSessionsByThread[owner]?.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
            persistCLITabs(ownerID: owner)
        }
        objectWillChange.send()
    }
    func cliTabStatus(_ id: UUID) -> CLISessionStatus {
        cliUIRecord(id)?.status ?? .exited
    }
    func cliTabScrollback(_ id: UUID) -> String { isLive ? (cliSessionStore?.scrollback(id) ?? "") : cliTabLines(for: id).map(\.plainText).joined(separator: "\n") }
    func sendCLITabOutputToChat(_ id: UUID, lines: Int = 80) {
        Task { [weak self] in
            guard let self else { return }
            let tail = isLive ? await cliWorkbenchTail(id) : cliTabScrollback(id)
            let text = CLISessionStore.textTail(tail, lines: lines)
            prompt += (prompt.isEmpty ? "" : "\n") + text
        }
    }
    @discardableResult
    func restoreCLITab(_ id: UUID) async -> UUID? {
        guard isCLIRuntimeEnabled else { return nil }
        await refreshCLIWorkbenchSessions()
        guard let record = cliSessionStore?.sessions.first(where: { $0.id == id }),
              let owner = record.threadID ?? selectedThreadID else { return nil }
        if cliTabPTYByID[id] == nil { hydrateCLIWorkbenchRecord(record, owner: owner) }
        // Dead sessions open a read-only snapshot with the SAME identity, never a new command.
        if cliTabPTYByID[id]?.isRunning != true {
            let text = await cliSessionStore?.loadScrollback(id) ?? ""
            cliTabLinesByID[id] = text.components(separatedBy: "\n").enumerated().map { TatwoTerminalLine(id: $0.offset, spans: [.init(text: $0.element)]) }
            if let session = cliTabPTYByID[id], session.display == nil {
                let display = NativeTerminalPTYNSView(session: session)
                session.display = display
                display.feed(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            }
        }
        guard let tab = cliSessionsByThread[owner]?.first(where: { $0.id == id }) else { return nil }
        cliSessionStore?.update(id) { $0.background = false }
        registerCLIWorkbenchPane(tab, owner: owner)
        selectedThreadID = owner
        selectCLITab(id)
        return id
    }
    func cliTabLines(for id: UUID) -> [TatwoTerminalLine] { cliTabLinesByID[id] ?? [] }
    func cliTabPTYSession(for id: UUID) -> CLIWorkbenchTerminalSession? { cliTabPTYByID[id] }
    func cliTabProcessID(for id: UUID) -> Int32? { cliTabPIDByID[id] }
    func loadPersistedCLISessionBook() {
        guard isLive, isCLIRuntimeEnabled, let threadID = selectedThreadID, !loadedCLIThreadIDs.contains(threadID) else { return }
        loadedCLIThreadIDs.insert(threadID)
        // Old tabs are historical, never silently respawn a process on navigation.
        // Import pre-store metadata once without claiming its processes are alive.
        for old in cliStore?.cliTabs(threadID: threadID) ?? [] {
            guard cliSessionStore?.sessions.contains(where: { $0.id == old.id }) == false else { continue }
            cliSessionStore?.insert(.init(id: old.id, title: old.title, engine: old.engine,
                cwd: old.cwd, createdAt: Date(), lastActiveAt: Date(), status: .exited,
                pinned: false, order: cliSessionStore?.sessions.count ?? 0, threadID: threadID, background: true))
            previousCLITabIDs.insert(old.id)
        }
        objectWillChange.send()
    }
    func prepareCLITabs() {
        guard isLive, isCLIRuntimeEnabled else { return }
        // Navigation is attach-only. Absent/dead tmux sessions must never be respawned.
        Task { [weak self] in await self?.refreshCLIWorkbenchSessions() }
    }
    func makeChatSearchIndex() -> TatwoChatSearchIndex { .init(documents: []) }
    func jumpToSearchResult(_ document: TatwoChatSearchDocument) {
        guard isLive, let threadID = document.threadID else { return }
        selectedDiscussionID = nil
        selectedThreadID = threadID
    }
    func startActiveGoalTimerIfNeeded() {}
    func stopActiveGoalTimer() {}
    func toggleActiveGoalPause() {
        guard isLive else { fixtureActiveGoalPaused.toggle(); return }
        guard canControlActiveGoal, !activeGoalPaused || canResumeActiveGoal else { return }
        changeNativeGoal(status: activeGoalPaused ? "active" : "paused")
    }
    func endActiveGoal() {
        guard isLive, canControlActiveGoal else { return }
        changeNativeGoal(status: nil)
    }
    private func changeNativeGoal(status: String?) {
        guard selectedRemote == nil, let id = selectedThreadID, let localLive else { return }
        if status == "active", !nativeGoalLoginReady() { return }
        let accepted = localLive.setNativeGoal(threadID: id, status: status) { [weak self] accepted, error in
            guard let self, self.selectedThreadID == id else { return }
            if !accepted { self.flashComposerHint(error ?? "目標操作未確認") }
        }
        if !accepted { flashComposerHint("目前無法操作目標，原狀態已保留") }
    }
    private func nativeGoalLoginReady() -> Bool {
        let status = engineLogin.status(for: .codex)
        replaceEngineLoginStatus(status)
        guard status.isLoggedIn else {
            flashComposerHint("Codex 還沒登入，到設定 › 模型存取登入")
            return false
        }
        return true
    }
    func allowMCPTool(named tool: String) {
        guard tool.hasPrefix("mcp__") else { return }
        let rest = tool.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return }
        let server = String(rest[..<separator.lowerBound])
        guard let entry = availableThreadPluginEntries.first(where: {
            $0.kind == .mcp && PluginsSource.mcpName(from: $0.id) == server
        }) else { return }
        setThreadPlugin(entry.id, enabled: true)
    }
    private func connectPlanCanvas(to engine: ChatLiveEngine) {
        engine.onPlanChange = { [weak self] plan in
            guard let self, self.selectedRemote == nil, self.selectedThreadID == plan.threadID else { return }
            self.activePlanArtifact = plan
        }
        loadActivePlanCanvas()
    }
    private func loadActivePlanCanvas() {
        activePlanArtifact = nil
        guard selectedRemote == nil, let id = selectedThreadID, let engine = localLive else { return }
        do { activePlanArtifact = try engine.loadPlanArtifact(id, recoverInterrupted: !preparingPR && !pendingPR.contains(id)) }
        catch { flashComposerHint("計畫讀取失敗；原檔保留，請先修復資料") }
    }
    @discardableResult
    private func persistPlanCanvas(_ plan: TatwoPlanArtifactV1) -> Bool {
        guard let engine = localLive else { return false }
        do {
            try engine.savePlanArtifact(plan)
            if selectedThreadID == plan.threadID { activePlanArtifact = plan }
            return true
        } catch {
            flashComposerHint("計畫儲存失敗，未套用修改")
            return false
        }
    }
    func confirmActivePlan() {
        guard selectedRemote == nil, var plan = activePlanArtifact, plan.kind != "feedback", plan.state == .discussing,
              localLive?.isRunning(plan.threadID) == false, !preparingPR, !pendingPR.contains(plan.threadID) else { return }
        if plan.kind == "pr" {
            do { _ = try PullRequestCoordinator.shared.identity() }
            catch { plan.prMessage = error.localizedDescription; _ = persistPlanCanvas(plan); return }
        }
        plan.prMessage = nil
        plan.confirm()
        if persistPlanCanvas(plan) {
            if plan.kind == "pr" {
                startPRContribution(description: plan.editableText(), threadID: plan.threadID)
                return
            }
            localLive?.appendSystemMessage(threadID: plan.threadID, text: "計畫已確認；說「開始」即執行", status: "info|Plan")
        }
    }
    func returnActivePRToDiscussion() {
        guard selectedRemote == nil, var plan = activePlanArtifact, plan.kind == "pr",
              plan.prImplementationInterrupted == true, plan.state == .discussing,
              localLive?.isRunning(plan.threadID) == false, !preparingPR,
              !pendingPR.contains(plan.threadID) else { return }
        plan.prImplementationInterrupted = nil
        plan.prMessage = nil
        _ = persistPlanCanvas(plan)
    }
    func editablePlanTextForCanvas() -> String? { activePlanArtifact?.editableText() }
    func finishFeedbackPlan(_ id: UUID) {
        guard var plan = activePlanArtifact, plan.planID == id, plan.kind == "feedback", plan.state == .discussing else { return }
        plan.confirm()
        _ = persistPlanCanvas(plan)
    }
    func ensureNativeTerminal(reset: Bool = false) {
        // Reset is deliberately not a command replay operation in the durable workbench.
        loadPersistedCLISessionBook()
        prepareCLITabs()
    }
    func handlePlanQuestionAnswerNotification(_ notification: Notification) {}
    @discardableResult
    func saveEditedPlanCanvasText(_ text: String) -> Bool {
        guard selectedRemote == nil, var plan = activePlanArtifact, !pendingPR.contains(plan.threadID),
              plan.kind != "pr" || plan.state == .discussing else { return false }
        guard localLive?.isRunning(plan.threadID) == false else {
            flashComposerHint("請等回覆完成再編輯計畫"); return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashComposerHint("計畫不可空白"); return false
        }
        let environment = plan.kind == "feedback" ? plan.sections.first { $0.title == "環境" } : nil
        plan.applyEditedText(text)
        if let environment {
            plan.sections.removeAll { $0.title == "環境" }
            plan.sections.insert(environment, at: min(1, plan.sections.count))
        }
        return persistPlanCanvas(plan)
    }
    func shutdownForContainerClose() {
        ComputerUseController.shared.stop()
        BrowserAgentBridge.shared.revokeRequests()
        devicePairingHost.cancelPairingWindow()
        OSAgentBridge.shared.stopBackgroundJobs()
        cliRefreshTask?.cancel()
        for session in cliTabPTYByID.values { session.detach() }
        saveCLIWorkbench()
        cliTabPTYByID.removeAll()
        cliTabPIDByID.removeAll()
        remoteProjectionTask?.cancel()
        for session in remoteSessions { session.shutdown() }
        localLive?.shutdownAll()
    }
    func stop() {
        // Local revocation precedes any sidecar/transport cancellation.
        ComputerUseController.shared.stop(owner: selectedThreadID)
        BrowserAgentBridge.shared.revokeRequests()
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID else { return }
        activeLive.stop(threadID: id)
        isRunning = activeLive.isRunning(id)
    }

    private func computerUseScope(_ caller: UUID) -> String? {
        // First vertical slice is a user-owned local Chat, not a delegated room
        // or a background Bot. Space/other routes remain explicitly unverified.
        guard isLive, mode == .chat, selectedRemote == nil, selectedThreadID == caller,
              let record = live?.threadRecord(caller), !record.isArchived,
              record.parentThreadID == nil, record.deviceID == nil,
              record.roomReadOnly != true, botIDForBridge(threadID: caller) == nil else { return nil }
        let domain = botLibraryForBridge?.snapshot.spaceWorkspace.selectedDomainID ?? "none"
        let workdir = record.cwdOverride ?? live?.projectRecord(record.projectID)?.workdir ?? NSHomeDirectory()
        return "\(caller.uuidString)|\(record.projectID?.uuidString ?? "none")|\(domain)|\(workdir)"
    }

    func browserAgentRequestScope(_ caller: UUID) -> String? {
        // isRunning stays true until the native terminal event, even after
        // local Stop. That UI liveness state is not permission for new tools.
        guard (localLive as? ChatLiveEngine)?.acceptsBrowserAgentRequests(caller) == true else { return nil }
        return computerUseScope(caller)
    }

    func queueBrowserAgentNavigation(_ navigation: BrowserAgentNavigation) {
        pendingBrowserAgentNavigation = navigation
        requestedBrowserAgentURL = navigation.url.absoluteString
        requestOpenBrowserPanel = true
    }

    func consumeBrowserAgentPanelRequest() -> Bool {
        requestOpenBrowserPanel = false
        guard let navigation = pendingBrowserAgentNavigation,
              BrowserAgentBridge.shared.isRequestCurrent(navigation.request) else { return false }
        return true
    }

    func consumeBrowserAgentNavigation(for sessionID: String?) -> BrowserAgentNavigation? {
        guard let navigation = pendingBrowserAgentNavigation,
              sessionID.flatMap(UUID.init(uuidString:)) == navigation.request.caller else { return nil }
        // Panel opening and URL consumption are separate SwiftUI callbacks;
        // either may run first. Keep the same (eventually finished) token for
        // the panel check, while consuming the URL at most once.
        defer { requestedBrowserAgentURL = nil }
        guard BrowserAgentBridge.shared.isRequestCurrent(navigation.request),
              requestedBrowserAgentURL == navigation.url.absoluteString else { return nil }
        return navigation
    }

    /// Validate the actual Chat entry, not only the MCP or the native input
    /// parser. Shape validation grants no permission and consumes no observation.
    nonisolated static func validateComputerToolParameters(_ method: String, params: [String: Any],
                                                           caller: UUID) throws {
        guard let rawCaller = params["callerThreadID"] as? String,
              UUID(uuidString: rawCaller) == caller else {
            throw ComputerUseFailure("computer_invalid_caller")
        }
        let allowed: Set<String>
        switch method {
        case "computer_start": allowed = ["callerThreadID", "bundleIdentifier"]
        case "computer_stop", "computer_list_apps": allowed = ["callerThreadID"]
        case "computer_observe": allowed = ["callerThreadID", "sessionID"]
        case "computer_action" where params["steps"] != nil:
            guard let observation = params["observationID"] as? String, UUID(uuidString: observation) != nil else {
                throw ComputerUseFailure("computer_invalid_batch")
            }
            _ = try ComputerUseController.batchRequests(params)
            allowed = ["callerThreadID", "sessionID", "observationID", "steps", "image"]
        case "computer_action":
            guard let action = params["action"] as? String,
                  let observation = params["observationID"] as? String, UUID(uuidString: observation) != nil else {
                throw ComputerUseFailure("computer_invalid_action")
            }
            _ = try ComputerUseNative.request(action: action, params: params)
            allowed = Set(params.keys) // Per-action fields were checked by the shared production parser.
        case "computer_batch":
            guard let observation = params["observationID"] as? String, UUID(uuidString: observation) != nil else {
                throw ComputerUseFailure("computer_invalid_batch")
            }
            _ = try ComputerUseController.batchRequests(params)
            allowed = ["callerThreadID", "sessionID", "observationID", "steps", "image"]
        default: throw ComputerUseFailure("computer_unknown_tool")
        }
        guard Set(params.keys).isSubset(of: allowed) else { throw ComputerUseFailure("computer_invalid_arguments") }
        if method == "computer_start" { _ = try ComputerUseTarget.requested(params["bundleIdentifier"]) }
        if method == "computer_observe" || method == "computer_action" || method == "computer_batch" {
            guard let session = params["sessionID"] as? String, UUID(uuidString: session) != nil else {
                throw ComputerUseFailure("computer_session_required")
            }
        }
    }

    func performComputerTool(_ method: String, params: [String: Any], caller: UUID,
                             requestIsConnected: @escaping @Sendable () -> Bool) async throws -> [String: Any] {
        guard let scope = computerUseScope(caller) else { throw ComputerUseFailure("computer_local_chat_required") }
        try Self.validateComputerToolParameters(method, params: params, caller: caller)
        guard let record = live?.threadRecord(caller) else { throw ComputerUseFailure("computer_local_chat_required") }
        let workdir = record.cwdOverride ?? live?.projectRecord(record.projectID)?.workdir ?? NSHomeDirectory()
        return try await ComputerUseController.shared.perform(method, params: params, caller: caller, scope: scope,
                                                              workspace: URL(fileURLWithPath: workdir, isDirectory: true),
                                                              requestIsConnected: requestIsConnected) { [weak self] in
            self?.computerUseScope(caller) == scope && requestIsConnected()
        }
    }
    func startPairingWindow() {
        pairingWindow = nil
        pairingListenAddress = nil
        let host = devicePairingHost
        Task {
            do {
                let value = try await Task.detached {
                    try host.startPairingWindow()
                }.value
                pairingWindow = (value.code, value.expiresAt)
                pairingListenAddress = value.listenAddress
                flashComposerHint("配對碼 \(value.code)，請連到 \(value.listenAddress)；5 分鐘後失效。")
            } catch {
                flashComposerHint("無法開啟配對視窗：\(error.localizedDescription)")
            }
        }
    }
    func cancelPairingWindow() {
        devicePairingHost.cancelPairingWindow()
        pairingWindow = nil
        pairingListenAddress = nil
    }

    func refreshGitHubAccounts() {
        guard isLive else { return }   // 匯出（金樣）模式用固定假帳號
        do {
            gitHubAccounts = try githubAccountsStore.loadAccounts()
            gitHubHelperInstalled = githubAccountsStore.isHelperInstalled()
        } catch {
            appendGitHubLoginLog("讀取 GitHub 帳號失敗：\(error.localizedDescription)")
        }
    }

    func importGitHubAccountsFromGH() {
        appendGitHubLoginLog("開始讀取 gh 已登入帳號")
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            do {
                let imported = try await Task.detached {
                    try await store.importFromGH()
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog("已從 gh 匯入 \(imported.count) 個帳號")
            } catch {
                self?.appendGitHubLoginLog("gh 匯入失敗：\(error.localizedDescription)")
            }
        }
    }

    func loginGitHubViaGH() {
        guard !githubLoginInProgress else { return }
        githubLoginInProgress = true
        githubDeviceCode = nil
        githubVerificationURL = nil
        gitHubLoginLog = []
        appendGitHubLoginLog("請在瀏覽器完成 GitHub 登入")
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            defer { self?.githubLoginInProgress = false }
            do {
                let account = try await Task.detached {
                    try await store.loginViaGH()
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog("已登入 \(account.username)")
            } catch {
                self?.appendGitHubLoginLog("gh 登入失敗：\(error.localizedDescription)")
            }
        }
    }

    func submitGitHubLoginInput(_ text: String) {
        if githubAccountsStore.submitLoginInput(text) {
            appendGitHubLoginLog(text.isEmpty ? "已送出 Enter" : "已送出登入輸入")
        } else {
            appendGitHubLoginLog("目前沒有可接收輸入的 gh 登入程序")
        }
    }

    func addGitHubToken(_ token: String) {
        appendGitHubLoginLog("正在驗證 GitHub token")
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            do {
                let account = try await Task.detached {
                    try await store.addToken(token)
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog("已加入 \(account.username)")
            } catch {
                self?.appendGitHubLoginLog("加入 token 失敗：\(error.localizedDescription)")
            }
        }
    }

    func removeGitHubAccount(_ account: GitHubAccountRecord) {
        removeGitHubAccount(account.username)
    }

    func removeGitHubAccount(_ username: String) {
        do {
            try githubAccountsStore.removeAccount(username)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已移除 \(username)")
        } catch {
            appendGitHubLoginLog("移除帳號失敗：\(error.localizedDescription)")
        }
    }

    func setDefaultGitHubAccount(_ account: GitHubAccountRecord) {
        setDefaultGitHubAccount(account.username)
    }

    func setDefaultGitHubAccount(_ username: String) {
        do {
            try githubAccountsStore.setDefault(username)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已將 \(username) 設為預設帳號")
        } catch {
            appendGitHubLoginLog("設定預設帳號失敗：\(error.localizedDescription)")
        }
    }

    func toggleGitHubMCPAlwaysOn(_ username: String) {
        guard let account = gitHubAccounts.first(where: {
            $0.username.caseInsensitiveCompare(username) == .orderedSame
        }) else { return }
        do {
            try githubAccountsStore.setGitHubMCPAlwaysOn(
                username: account.username,
                on: !account.mcpAlwaysOn)
            refreshGitHubAccounts()
            pluginEntries = PluginsSource.scanNow(environment: runtimeEnvironment)
            appendGitHubLoginLog(
                "\(account.username) MCP 已\(account.mcpAlwaysOn ? "關閉常駐" : "開啟常駐")")
        } catch {
            appendGitHubLoginLog("切換 \(username) MCP 常駐失敗：\(error.localizedDescription)")
        }
    }

    func addGitHubFolderMapping(account: String, path: String) {
        do {
            try githubAccountsStore.addFolderMapping(account: account, path: path)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已加入 \(account) 的資料夾對映")
        } catch {
            appendGitHubLoginLog("加入資料夾對映失敗：\(error.localizedDescription)")
        }
    }

    func addGitHubFolderMapping(account: GitHubAccountRecord, path: String) {
        addGitHubFolderMapping(account: account.username, path: path)
    }

    func removeGitHubFolderMapping(account: String, path: String) {
        do {
            try githubAccountsStore.removeFolderMapping(account: account, path: path)
            refreshGitHubAccounts()
            appendGitHubLoginLog("已移除 \(account) 的資料夾對映")
        } catch {
            appendGitHubLoginLog("移除資料夾對映失敗：\(error.localizedDescription)")
        }
    }

    func removeGitHubFolderMapping(account: GitHubAccountRecord, path: String) {
        removeGitHubFolderMapping(account: account.username, path: path)
    }

    func installGitHubHelper() {
        do {
            try githubAccountsStore.installHelper()
            refreshGitHubAccounts()
            appendGitHubLoginLog("OS 已接管 git 憑證")
        } catch {
            appendGitHubLoginLog("安裝 git credential helper 失敗：\(error.localizedDescription)")
        }
    }

    func restoreGitHubHelper() {
        do {
            try githubAccountsStore.restoreHelper()
            refreshGitHubAccounts()
            appendGitHubLoginLog("已還原原本的 git credential helper")
        } catch {
            appendGitHubLoginLog("還原 git credential helper 失敗：\(error.localizedDescription)")
        }
    }

    func verifyGitHubAccount(_ account: GitHubAccountRecord) {
        verifyGitHubAccount(account.username)
    }

    func verifyGitHubAccount(_ username: String) {
        let store = githubAccountsStore
        Task { @MainActor [weak self] in
            do {
                let verified = try await Task.detached {
                    try await store.verify(username)
                }.value
                self?.refreshGitHubAccounts()
                self?.appendGitHubLoginLog(
                    "\(username) 驗證通過：登入名 \(verified.username)，scopes \(verified.scopes.joined(separator: ", "))")
            } catch {
                self?.appendGitHubLoginLog("\(username) 驗證失敗：\(error.localizedDescription)")
            }
        }
    }

    private func appendGitHubLoginLog(_ message: String) {
        let sanitized = message
            .replacingOccurrences(
                of: #"gh[oprsu]_[A-Za-z0-9_]+"#,
                with: "[REDACTED]",
                options: .regularExpression)
            .replacingOccurrences(
                of: #"github_pat_[A-Za-z0-9_]+"#,
                with: "[REDACTED]",
                options: .regularExpression)
        gitHubLoginLog.append(sanitized)
        if gitHubLoginLog.count > 100 {
            gitHubLoginLog.removeFirst(gitHubLoginLog.count - 100)
        }
    }

    func pairWithHost(host: String, port: Int, code: String, name: String) {
        let client = DevicePairingClient(registry: deviceRegistry)
        Task {
            do {
                let record = try await Task.detached {
                    try client.pair(host: host, port: port, code: code, name: name)
                }.value
                devices = deviceRegistry.list()
                configureRemoteSessions()
                flashComposerHint("已配對「\(record.name)」，並通過 SSH BatchMode 登入驗證。")
                pairingClientMessage = "已配對「\(record.name)」，SSH 登入驗證通過。"
            } catch {
                devices = deviceRegistry.list()
                flashComposerHint("配對失敗：\(error.localizedDescription)")
                pairingClientMessage = "配對失敗：\(error.localizedDescription)"
            }
        }
    }
    func removeDevice(_ id: String) {
        do {
            try deviceRegistry.remove(id: id)
            devices = deviceRegistry.list()
            if selectedRemote?.deviceID == id { exitRemoteMode() }
            configureRemoteSessions()
            flashComposerHint("已移除設備。")
        } catch {
            devices = deviceRegistry.list()
            flashComposerHint("移除設備失敗：\(error.localizedDescription)")
        }
    }
    func removeDevice(id: String) {
        removeDevice(id)
    }
    func deviceRecordsForBridge() -> [DeviceRecord] {
        let rows = deviceRegistry.list()
        devices = rows
        return rows
    }
    @discardableResult
    func enterRemoteMode(_ device: DeviceRecord) -> Bool {
        guard isLive else {
            flashComposerHint("目前不是 live 模式，無法選取遠端討論串")
            return false
        }
        if !remoteSessions.contains(where: { $0.device.id == device.id }) {
            devices = deviceRegistry.list()
            configureRemoteSessions()
        }
        guard let session = remoteSessions.first(where: { $0.device.id == device.id }),
              (session.engine != nil || session.connectNow()),
              let threadID = session.engine?.doc.selectedThreadID
                ?? session.document.projects.lazy.flatMap(\.threads).first?.id
        else {
            flashComposerHint("遠端設備 \(device.name) 尚未連上")
            return false
        }
        return selectRemote(deviceID: device.id, threadID: threadID)
    }

    func exitRemoteMode() {
        guard selectedRemote != nil else { return }
        selectLocalThread(localSelectedThreadID)
        flashComposerHint("已回到本機")
    }

    @discardableResult
    func selectRemote(deviceID: String, threadID: UUID) -> Bool {
        guard
            let session = remoteSessions.first(where: { $0.device.id == deviceID }),
            let remote = session.engine,
            remote.threadRecord(threadID) != nil
        else {
            flashComposerHint("遠端設備尚未連上，或找不到這條討論串")
            return false
        }
        if selectedRemote == nil { localSelectedThreadID = selectedThreadID }
        selectedRemote = (deviceID, threadID)
        selectedDiscussionID = nil
        selectedThreadID = threadID
        remote.select(threadID)
        isRunning = remote.isRunning(threadID)
        refreshIssueLists()
        flashComposerHint("已選取遠端：\(session.device.name)")
        objectWillChange.send()
        return true
    }

    func selectLocalThread(_ threadID: UUID?) {
        selectedRemote = nil
        selectedDiscussionID = nil
        let target = threadID
            ?? localLive?.doc.selectedThreadID
            ?? document.projects.lazy.flatMap(\.threads).first?.id
        selectedThreadID = target
        if let target { localLive?.select(target) }
        localSelectedThreadID = target
        isRunning = localLive?.isRunning(target) ?? false
        refreshIssueLists()
        refreshGitStatus()
        objectWillChange.send()
    }

    @discardableResult
    func pushThreadToDevice(_ threadID: UUID, _ deviceID: String) -> UUID? {
        guard
            let localLive,
            let source = localLive.threadRecord(threadID),
            let project = localLive.projectRecord(source.projectID),
            let session = remoteSessions.first(where: { $0.device.id == deviceID }),
            let remote = session.engine
        else {
            flashComposerHint("併回失敗：本機討論串或遠端設備不可用")
            return nil
        }
        let systemText = "已併回 \(session.device.name)，來源：\(source.title)"
        var messages = localLive.transcript(for: threadID)
            .map(RemoteThreadTransferMessage.init)
        messages.append(RemoteThreadTransferMessage(
            role: "system",
            text: systemText,
            createdAt: Date()))
        let files = RemoteThreadTransfer.changedFiles(
            in: source.cwdOverride ?? project.workdir)
        do {
            let remoteThreadID = try remote.pushThread(
                projectName: project.name,
                title: source.title,
                messages: messages,
                files: files)
            localLive.appendSystemMessage(
                threadID: threadID,
                text: systemText,
                status: "info|設備搬移")
            flashComposerHint("已併回 \(session.device.name)")
            return remoteThreadID
        } catch {
            flashComposerHint("併回 \(session.device.name) 失敗：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func pullThreadFromDevice(_ deviceID: String, _ remoteThreadID: UUID) -> UUID? {
        guard
            let localLive,
            let session = remoteSessions.first(where: { $0.device.id == deviceID }),
            let remote = session.engine
        else {
            flashComposerHint("拉到這台失敗：遠端設備不可用")
            return nil
        }
        do {
            let transfer = try remote.pullThread(threadID: remoteThreadID)
            let localThreadID = try localLive.importTransferredThread(
                projectName: transfer.projectName,
                title: transfer.title,
                messages: transfer.messages,
                files: transfer.files)
            localLive.appendSystemMessage(threadID: localThreadID, text: "已拉到這台，來源：\(transfer.title)（\(session.device.name)）", status: "info|設備搬移")
            selectLocalThread(localThreadID)
            flashComposerHint("已拉到這台，來源：\(transfer.title)")
            return localThreadID
        } catch {
            flashComposerHint("拉到這台失敗：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func rejectRemoteWrite(_ action: String) -> Bool {
        guard selectedRemote != nil else { return false }
        flashComposerHint("遠端討論串不支援 \(action)")
        return true
    }
    func updateGatewayLiveStatus(_ status: TatwoGatewayLiveStatus?) {}
    func updatePlanFlowSelection(_ selection: TatwoPlanArtifactV1.PlanFlowSelectionV1) {}
    @discardableResult
    func handleFeedbackCommand() -> Bool {
        guard let argument = TatwoSlashCommandParser.feedbackArgument(in: prompt) else { return false }
        if !argument.isEmpty {
            guard !rejectRemoteWrite("/feedback"), let id = selectedThreadID, let engine = localLive else {
                flashComposerHint("請先開啟本機討論串"); return true
            }
            guard !engine.isRunning(id), !pendingPR.contains(id) else {
                flashComposerHint("請等目前回合結束再回報"); return true
            }
            let environment = FeedbackEnvironment.current(engine: routeChoice.engine.rawValue)
            let body = "App: \(environment.appVersion) (\(environment.appBuild))\nmacOS: \(environment.macOS)\nEngine: \(environment.engine)"
            let plan = TatwoPlanArtifactV1(threadID: id, objective: argument,
                sections: [.init(title: "環境", body: body)], kind: "feedback")
            guard persistPlanCanvas(plan) else { return true }
            planInspectorRequest = UUID()
            return false // Continue through the ordinary AI send path; keep the draft if rejected.
        }
        if FeedbackCoordinator.shared.present(source: "Chat", initialText: argument) { prompt = "" }
        if (try? githubAccountsStore.loadAccounts())?.first == nil {
            flashComposerHint("請先登入github才能提交issue")
        }
        return true
    }

    func send() {
        if handleFeedbackCommand() { return }
        let planCommand = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if planCommand.split(whereSeparator: \.isWhitespace).first == "/plan" {
            guard !rejectRemoteWrite("/plan"), let id = selectedThreadID, let engine = localLive else {
                flashComposerHint("請先開啟本機討論串"); return
            }
            let objective = String(planCommand.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if objective.isEmpty {
                if activePlanArtifact != nil { planInspectorRequest = UUID(); prompt = "" }
                else { flashComposerHint("/plan 後面接你想討論的計畫") }
                return
            }
            guard !engine.isRunning(id), !pendingPR.contains(id) else {
                flashComposerHint("請等目前回合結束再建立計畫"); return
            }
            let plan = TatwoPlanArtifactV1(threadID: id, objective: String(objective.prefix(60)))
            guard persistPlanCanvas(plan) else { return }
            planInspectorRequest = UUID()
        }
        if isPlanModeEnabled && isLocalNativeGoalCommand {
            flashComposerHint("計畫討論中；確認計畫並說「開始」後再執行"); return
        }
        if activePlanArtifact != nil, let id = selectedThreadID, localLive?.isRunning(id) == true {
            flashComposerHint("請等計畫回覆完成再送出"); return
        }
        if planCommand == "開始", isPlanModeEnabled, activePlanArtifact?.kind != "feedback", activePlanArtifact?.kind != "pr" {
            confirmActivePlan()
            guard !isPlanModeEnabled else { return }
        }
        if isLocalPRCommand {
            let title = TatwoSlashCommandParser.prArgument(in: prompt) ?? ""
            guard let id = selectedThreadID, let engine = activeConversationEngine else {
                flashComposerHint("請先開啟本機專案討論串。")
                return
            }
            guard selectedRemote == nil else {
                engine.appendSystemMessage(threadID: id, text: "/pr 僅支援本機專案討論串。", status: "info|PR")
                return
            }
            guard !engine.isRunning(id), !pendingPR.contains(id), !preparingPR else {
                engine.appendSystemMessage(threadID: id, text: "請等目前工作結束再 /pr", status: "info|PR")
                return
            }
            if !title.isEmpty {
                let plan = TatwoPlanArtifactV1(threadID: id, objective: title, kind: "pr")
                guard persistPlanCanvas(plan) else { return }
                planInspectorRequest = UUID()
            } else {
                prompt = ""
                guard let project = selectedThreadProject else {
                    engine.appendSystemMessage(threadID: id, text: "請先開啟本機專案討論串。", status: "info|PR")
                    return
                }
                let cwd = engine.threadRecord(id)?.cwdOverride ?? project.workdir
                PullRequestCoordinator.shared.present(directory: URL(fileURLWithPath: cwd), title: title) { text in
                    engine.appendSystemMessage(threadID: id, text: text, status: "info|PR")
                }
                return
            }
        }
        if isShowDiscussionTrayCommand {
            showDiscussionTray()
            prompt = ""
            flashComposerHint(dispatchRooms.isEmpty ? "目前沒有子討論串；可用 /討論串 主題 新增" : "已顯示討論串")
            return
        }
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID else { return }
        guard !pendingPR.contains(id) else {
            activeLive.appendSystemMessage(threadID: id, text: "PR 作業處理中，請等目前工作結束。", status: "info|PR")
            return
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLocalDiscussionCommand {
            if rejectRemoteWrite("建立討論串") { return }
            let topic = String(trimmedPrompt.dropFirst("/討論串".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else {
                flashComposerHint("/討論串 後面接主題，例如：/討論串 登入問題")
                return
            }
            guard let discussionID = localLive?.createDiscussion(parentThreadID: id) else {
                flashComposerHint("無法建立討論串，原草稿已保留")
                return
            }
            localLive?.rename(discussionID, Self.dispatchTitle(topic))
            selectedDiscussionID = discussionID
            selectedThreadID = discussionID
            prompt = topic
            return
        }
        if isLocalIssueCommand {
            if rejectRemoteWrite("issue") { return }
            // 1.0 語意：/issue 是「快速記到右側資訊卡的 issue 清單」，不是叫模型改檔
            let rest = String(trimmedPrompt.dropFirst("/issue".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { flashComposerHint("/issue 後面接你要記的問題，例如：/issue 初始安裝的資料夾架構要重想"); return }
            if addIssueFromText(rest, attachments: droppedPaths) {
                prompt = ""
                droppedPaths = []
                droppedPathDisplayNames = [:]
            }
            return
        }
        if isLocalNativeGoalCommand {
            if rejectRemoteWrite("目標") { return }
            let objective = String(trimmedPrompt.dropFirst("/goal".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else {
                localLive?.refreshNativeGoal(id)
                if nativeGoalSnapshot == nil { flashComposerHint("/goal 後面接目標；不會自行建立空白工作") }
                return
            }
            guard nativeGoalLoginReady() else { return }
            let draft = prompt, revision = composerRevision
            let accepted = localLive?.setNativeGoal(threadID: id, status: "active", objective: objective,
                model: routeChoice.modelArgument) { [weak self] accepted, error in
                    guard let self, self.selectedThreadID == id else { return }
                    if accepted {
                        if self.composerRevision == revision && self.prompt == draft { self.prompt = "" }
                    } else { self.flashComposerHint(error ?? "目標未建立，草稿已保留") }
                } == true
            if !accepted { flashComposerHint("目前無法建立目標，草稿已保留") }
            return
        }
        if activeLive.isRunning(id) {
            guard canSteerCurrentTurn, let localLive else { return }
            let draft = prompt, attachments = droppedPaths, revision = composerRevision
            _ = localLive.steer(threadID: id, text: draft, attachments: attachments) { [weak self] accepted, error in
                guard let self, self.selectedThreadID == id else { return }
                if accepted {
                    // Never erase text or files edited while waiting for the
                    // native acknowledgement.
                    if self.composerRevision == revision && self.prompt == draft && self.droppedPaths == attachments {
                        self.prompt = ""
                        self.droppedPaths = []
                        self.droppedPathDisplayNames = [:]
                    }
                } else {
                    self.flashComposerHint(error ?? "插話未送出，草稿已保留")
                }
            }
            return
        }
        let engine: ClaudeSidecar.Kind
        switch routeChoice.brandGroup {
        case .anthropic: engine = .claude
        case .openAI: engine = .codex
        case .xAI: engine = .grok
        default:
            engine = .claude
            flashComposerHint("\(routeChoice.title) 還沒有水電，先用 Claude 回覆")
        }
        if selectedRemote == nil {
            let loginStatus = engineLogin.status(for: engine)
            replaceEngineLoginStatus(loginStatus)
            guard loginStatus.isLoggedIn else {
                let hint = "\(engineLoginDisplayName(engine)) 還沒登入，到設定 › 模型存取登入"
                flashComposerHint(hint)
                // 觀測缺口（2026-09-06 review）：只閃提示的話對話裡什麼都沒有，人和測試都看不出這句為什麼沒送。進一列錯誤卡。
                if let threadID = selectedThreadID { localLive?.appendSystemMessage(threadID: threadID, text: "這句沒有送出：\(hint)。", status: "error|登入") }
                return
            }
        } else if !droppedPaths.isEmpty {
            _ = rejectRemoteWrite("附件")
            return
        }
        let text = prompt
        let modelArg: String?
        switch engine {
        case .claude: modelArg = routeChoice.modelArgument.flatMap { $0.hasPrefix("claude") ? $0 : nil }
        case .codex: modelArg = routeChoice.modelArgument ?? routeChoice.canonicalModelSlug
        case .grok: modelArg = routeChoice.modelArgument   // 真模型 id（grok-4.6）；CLI 會拒絕未知 id，所以成功即 attestation
        }
        let atts = droppedPaths
        let accepted = activeLive.send(
            threadID: id,
            text: text,
            model: modelArg,
            engine: engine,
            systemPrompt: ultraworkTurnBriefing,
            attachments: atts,
            reasoningEffort: engine == .codex ? selectedEffort.codexRawValue : nil,
            serviceTier: engine == .codex ? selectedSpeedTier.appServerValue : nil)
        if accepted {
            prompt = ""
            droppedPaths = []
            droppedPathDisplayNames = [:]
        }
        isRunning = activeLive.isRunning(id)
    }
    func appendDroppedPath(_ path: String) {
        if rejectRemoteWrite("附件") { return }
        guard !droppedPaths.contains(path) else { return }
        droppedPaths.append(path)
        droppedPathDisplayNames[path] = (path as NSString).lastPathComponent
    }

    // Bot memory is App-facing; MCP only receives the six non-confirmation operations.
    var botLibraryForBridge: BotLibrary? { botStore?.library }
    /// Bot 頁資訊卡的真來源：綁定的討論串／專案／issue；沒有就 nil（畫面顯示 —），不用 fixture。
    struct BotUISource { var project: String?; var thread: String?; var threadID: UUID?; var issues: [String] = [] }
    func botSourceForUI(botID: String) -> BotUISource {
        guard botLibraryForBridge?.bot(id: botID) != nil,
              let tid = botThreadBindings[botID] ?? botStore?.threadID(forBotID: botID),
              let engine = localLive as? ChatLiveEngine, let record = engine.threadRecord(tid) else { return .init() }
        let project = engine.doc.projects.first { $0.id == record.projectID }?.name
        return .init(project: project, thread: record.title, threadID: tid, issues: record.issues.map(\.title))
    }
    func botTranscriptForUI(botID: String) -> [ChatMessage] {
        guard botLibraryForBridge?.bot(id: botID) != nil else { return [] }
        return localLive?.transcript(for: botThreadBindings[botID] ?? botStore?.threadID(forBotID: botID)) ?? []
    }
    private var botThreadBindings: [String: UUID] = [:]
    var spaceSubmissionsInFlight = Set<UUID>()
    var botSendTestHook: ((UUID, String, String?) -> Void)?
    func botIDForBridge(threadID: UUID) -> String? {
        botThreadBindings.first(where: { $0.value == threadID })?.key
            ?? botStore?.library.snapshot.spaceWorkspace.domains.values
                .flatMap(\.interfaces).first(where: { $0.conversationID == threadID })?.botID
            ?? botStore?.document.threadIDsByBotID.first(where: { $0.value == threadID })?.key
    }
    @discardableResult
    func sendAsBot(botID: String, text: String, spaceID: String? = nil, interfaceID: UUID? = nil) -> UUID? {
        guard isLive, selectedRemote == nil, let live = live as? ChatLiveEngine,
              let library = botStore?.library, let bot = library.bot(id: botID),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard library.snapshot.spaceWorkspaceError == nil else {
            flashComposerHint("Space 資料需要復原，未送出也未改寫既有對話")
            return nil
        }
        // Grok's current sidecar ignores permissionMode and cannot enforce ask/auto.
        guard bot.engine != "grok" || bot.permissions.approval == "full" else {
            flashComposerHint("Bot Grok 權限檔位尚不支援；未送出")
            return nil
        }
        let interface: SpaceWorkInterfaceRecord?
        if let spaceID, let interfaceID {
            guard let owned = library.snapshot.spaceWorkspace.domains[spaceID]?.interfaces
                .first(where: { $0.id == interfaceID && $0.spaceID == spaceID && $0.botID == botID }),
                  bot.spaceIDs.contains(spaceID) else {
                flashComposerHint("工作介面與 Space／Bot 關聯不符，未送出")
                return nil
            }
            interface = owned
        } else {
            guard spaceID == nil, interfaceID == nil else { return nil }
            interface = nil
        }
        let existing = interface?.conversationID
            ?? botThreadBindings[botID] ?? botStore?.threadID(forBotID: botID)
        let threadID: UUID
        do {
            threadID = try live.prepareBotThread(existing: existing, bot: bot,
                registeredMCP: registeredPluginIDs, reservedID: interface?.conversationID,
                selectThread: interface == nil)
        }
        catch { flashComposerHint(String(describing: error)); return nil }
        if interface == nil {
            botThreadBindings[botID] = threadID
            selectedThreadID = threadID
        }
        let thread = live.threadRecord(threadID)
        let needsPrompt = thread?.sessionIDs[bot.engine] == nil && !(bot.engine == "claude" && thread?.sessionID != nil)
        let persona = needsPrompt ? BotMemory(library: library).systemPrompt(botID: botID) : nil
        let engine = ClaudeSidecar.Kind(rawValue: bot.engine) ?? .claude
        // Test hook is set only by in-process acceptance; never reads an environment bypass.
        if let hook = botSendTestHook { hook(threadID, text, persona); return threadID }
        guard live.send(threadID: threadID, text: text, model: bot.model, engine: engine, systemPrompt: persona) else {
            flashComposerHint("未送出，需求草稿仍保留，可重試")
            return nil
        }
        isRunning = live.isRunning(selectedThreadID)
        Task { @MainActor [weak self, weak live] in
            try? await library.recordSession(botID: botID, threadID: threadID.uuidString, engine: bot.engine)
            while let live, live.isRunning(threadID) { try? await Task.sleep(for: .milliseconds(250)) }
            // 同一回合完成：session 與 state 共用一個時間戳（r6 BOTCORETEST 抓到分別取時跨秒就不等）
            let completedAt = BotLibrary.timestamp()
            try? await library.recordSession(botID: botID, threadID: threadID.uuidString, engine: bot.engine, at: completedAt)
            try? await BotMemory(library: library).updateState(botID: botID, patch: .init(lastSessionAt: completedAt, lastThreadID: threadID.uuidString))
            self?.objectWillChange.send()
        }
        return threadID
    }

    private func scheduleBotSelfTest(environment: [String: String]) {
        guard let botStore else { return }
        print("BOTTEST seed spaces=\(botStore.spaces.count) bots=\(botStore.bots.count)")
        let botID = botStore.bots.first(where: { $0.name == "PO文 bot" })?.id
        guard let botID, let threadID = sendAsBot(botID: botID, text: "只回一個詞：乒") else {
            print("BOTTEST ERROR bot/thread unavailable")
            exit(1)
        }
        Task { @MainActor [weak self] in
            guard let self else { exit(1) }
            var ticks = 0
            while self.isRunning && ticks < 240 {
                try? await Task.sleep(for: .milliseconds(500))
                ticks += 1
            }
            let transcript = self.live?.transcript(for: threadID) ?? []
            for message in transcript {
                print("BOTTEST \(message.role.storageValue.uppercased()) \(message.text.replacingOccurrences(of: "\n", with: "⏎"))")
            }
            let savedBytes = (try? Data(contentsOf: botStore.url))?.count ?? 0
            print("BOTTEST bots.json bytes=\(savedBytes) thread=\(threadID.uuidString)")
            self.shutdownForContainerClose()
            try? await Task.sleep(for: .milliseconds(250))
            exit(!transcript.isEmpty && savedBytes > 0 ? 0 : 1)
        }
    }
    func flashComposerHint(_ message: String) { composerHint = message }
    func refreshEngineLogins() {
        guard isLive else { return }   // 匯出（金樣）模式用固定假狀態
        // 狀態檢查會起子程序（claude auth status 最多 8 秒），一定要離開主執行緒——03:41／03:52 兩次「當機」就是這裡卡住主執行緒
        let login = engineLogin
        Task.detached { [weak self] in
            let list = login.statuses()
            await MainActor.run { self?.engineLogins = list }
        }
    }
    func loginEngine(_ kind: ClaudeSidecar.Kind) {
        engineLoginLog = []
        engineLoginInProgress = kind
        let login = engineLogin
        Task.detached { [weak self] in
            let status = login.login(kind) { line in
                Task { @MainActor [weak self] in
                    self?.engineLoginLog.append(line)
                }
            }
            await MainActor.run {
                self?.replaceEngineLoginStatus(status)
                self?.engineLoginInProgress = nil
            }
        }
    }
    /// 快速記一個問題到右側清單（/issue 與資訊卡的快速欄共用）。第一行是標題，其餘是內文。
    @discardableResult
    func addIssueFromText(_ text: String, attachments: [String] = []) -> Bool {
        guard isLive, selectedRemote == nil, let engine = localLive as? ChatLiveEngine,
              let id = selectedThreadID else { return false }
        let rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return false }
        let firstLine = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? rest
        let rawBody = rest.count > firstLine.count ? String(rest.dropFirst(firstLine.count)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let legacy = IssueImageAssets.extractingLegacyImages(from: rawBody)
        let bodyText = legacy.text
        let key = ([id.uuidString, rest] + attachments).joined(separator: "\u{0}")
        if pendingIssueSubmission?.key != key { pendingIssueSubmission = (key, UUID().uuidString) }
        do {
            let images = try IssueImageAssets.stage(paths: attachments + legacy.paths, root: issueImageRoot)
            var entry = TatwoIssueListEntryV1(id: pendingIssueSubmission!.id,
                title: String(firstLine.prefix(60)), body: bodyText,
                sourceReference: id.uuidString, threadReference: id.uuidString,
                projectReference: engine.threadRecord(id)?.projectID?.uuidString)
            entry.imageAssetPaths = images
            try engine.addIssueChecked(threadID: id, entry: entry)
            pendingIssueSubmission = nil
        } catch {
            flashComposerHint("問題未保存，文字與附件已保留：\(error.localizedDescription)")
            return false
        }
        refreshIssueLists()
        flashComposerHint("已記到右側的問題清單：「\(firstLine.prefix(30))」；打 @ 可以隨時叫出來")
        return true
    }

    func toggleEngineDisabled(_ kind: ClaudeSidecar.Kind) {
        let now = !EngineDisableStore.isDisabled(kind)
        EngineDisableStore.set(kind, disabled: now)
        disabledEngines = EngineDisableStore.disabled()
        flashComposerHint(now ? "\(EngineDisableStore.displayName(kind)) 的 API 已禁用，任何對話都不會送給它" : "\(EngineDisableStore.displayName(kind)) 已解除禁用")
    }
    func isEngineDisabled(_ kind: ClaudeSidecar.Kind) -> Bool { disabledEngines.contains(kind.rawValue) }

    /// 模型登入頁的額度條：跟首頁額度卡同一個來源（Claude／OpenAI 走訂閱 API，Grok 只有 App 自己的記錄）。
    func refreshEngineQuotas() {
        let providers = [
            UsageProviderStatus(id: "claude", displayName: "Claude", status: .installed, cachePolicy: "", liveRefreshPolicy: "", quotaLabel: ""),
            UsageProviderStatus(id: "codex-gpt", displayName: "OpenAI", status: .installed, cachePolicy: "", liveRefreshPolicy: "", quotaLabel: ""),
            UsageProviderStatus(id: "grok", displayName: "Grok", status: .installed, cachePolicy: "", liveRefreshPolicy: "", quotaLabel: ""),
        ]
        Task { [weak self] in
            let snapshot = await TatwoQuotaSnapshotCache.shared.load(providers: providers)
            await MainActor.run { self?.engineQuotas = snapshot.rows }
        }
        guard isLive else { return }
        let paths = engineLogin.paths
        Task.detached { [weak self] in
            let openAI = EngineQuotaFetcher.openAI(paths: paths)
            let anthropic = EngineQuotaFetcher.anthropic(paths: paths)
            let grok = EngineQuotaFetcher.grok()
            await MainActor.run {
                self?.engineQuotaDetails = ["codex": openAI, "claude": anthropic, "grok": grok]
            }
        }
    }

    /// 使用者在模型登入頁按了「使用重置券」並二次確認後才會走到這裡。
    func consumeOpenAIResetCredit() {
        let paths = engineLogin.paths
        Task.detached { [weak self] in
            let message = EngineQuotaFetcher.consumeOpenAIResetCredit(paths: paths)
            await MainActor.run { self?.flashComposerHint(message); self?.refreshEngineQuotas() }
        }
    }

    /// 設定 › OS：各家引擎有沒有接到 OS、有沒有代差。
    func refreshUpstreamBindings() {
        guard isLive else { return }
        let env = runtimeEnvironment
        Task.detached { [weak self] in
            let list = OSUpstreamBinding.statuses(environment: env)
            await MainActor.run { self?.upstreamBindings = list }
        }
    }
    /// Legacy caller cannot bypass the preview and human confirmation in OSBindingCard.
    func installUpstreamBindings() {
        flashComposerHint("請到設定 › OS 先預覽差異，再確認寫入修復")
    }
    var osBindingEnvironment: [String: String] { runtimeEnvironment }
    var osRootPath: String { OSUpstreamBinding.osRoot(environment: runtimeEnvironment) }
    /// OS 總覽頁用：已登記的 MCP／外掛 id（pluginEntries 本身是 private）
    var registeredPluginIDs: [String] { pluginEntries.map(\.id) }

    /// 登入程序要你貼認證碼時（Grok），從設定頁送進去。
    func submitEngineLoginInput(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if engineLogin.submitLoginInput(text) { engineLoginLog.append("已送出認證碼") }
        else { engineLoginLog.append("現在沒有登入在進行，先按「登入」") }
    }
    func logoutEngine(_ kind: ClaudeSidecar.Kind) {
        let login = engineLogin
        Task.detached { [weak self] in
            let status = login.logout(kind) { line in
                Task { @MainActor [weak self] in
                    self?.engineLoginLog.append(line)
                }
            }
            await MainActor.run {
                self?.replaceEngineLoginStatus(status)
            }
        }
    }
    private func replaceEngineLoginStatus(_ status: EngineLoginStatus) {
        if let index = engineLogins.firstIndex(where: { $0.kind == status.kind }) {
            engineLogins[index] = status
        } else {
            engineLogins.append(status)
            engineLogins.sort {
                EngineLogin.kinds.firstIndex(of: $0.kind) ?? .max
                    < EngineLogin.kinds.firstIndex(of: $1.kind) ?? .max
            }
        }
    }
    private func engineLoginDisplayName(_ kind: ClaudeSidecar.Kind) -> String {
        switch kind {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }
    func setSingleModel(_ routeID: String, syncCollaborationLead: Bool = false) {
        let choice = ChatRouteChoice.resolve(routeID)
        if isRunning {
            pendingModelID = choice.id == selectedModel ? nil : choice.id
            flashComposerHint(pendingModelID == nil
                ? "已取消下一輪模型切換；目前回覆仍由 \(routeChoice.title) 執行。"
                : "目前回覆仍由 \(routeChoice.title) 執行；\(choice.title) 會從下一輪開始。")
            return
        }
        pendingModelID = nil
        selectedModel = choice.id
        // 模型選單只管這條討論串的路由；主導／副審身份走 ultrawork 膠囊，不在這裡連動。
        _ = syncCollaborationLead
    }

    /// Preferences belong to the existing thread document, not another global
    /// settings store. Hydration must not write defaults over explicit choices.
    func restoreModelPreferences() {
        guard isLive, let engine = activeConversationEngine else { return }
        restoringModelPreferences = true
        defer { restoringModelPreferences = false }
        let thread = engine.threadRecord(selectedThreadID)
        let choice = ChatRouteChoice.resolve(thread?.requestedModel ?? thread?.model ?? "gpt-6-astra")
        selectedModel = choice.id
        selectedEffort = thread?.requestedEffort.flatMap(TatwoCodexReasoningEffort.init(rawValue:)) ?? choice.defaultEffort
        selectedSpeedTier = thread?.requestedSpeedTier.flatMap(TatwoModelSpeedTier.init(rawValue:))
            ?? choice.defaultSpeedTier ?? .fast
    }

    private func persistModelPreferences() {
        guard isLive, !restoringModelPreferences, selectedRemote == nil,
              let threadID = selectedThreadID, let live = localLive as? ChatLiveEngine else { return }
        live.setModelPreferences(threadID: threadID, model: selectedModel,
                                 effort: selectedEffort.rawValue, speedTier: selectedSpeedTier.rawValue)
    }

    /// 回合結束時把「下一輪再換」落地（1.0 ChatPageModel+StateAndSelection.swift:513）。
    func applyPendingModelSelectionIfPossible() {
        guard !isRunning, let pendingModelID else { return }
        self.pendingModelID = nil
        selectedModel = ChatRouteChoice.resolve(pendingModelID).id
    }
    func restoreMostRecentArchivedThread() {
        if rejectRemoteWrite("還原封存討論串") { return }
        guard isLive, let restored = live?.restoreMostRecentArchivedThread() else { return }
        selectedDiscussionID = nil
        selectedThreadID = restored
    }
    func loadWorkspaceDiff() -> TatwoParsedDiff { .init(files: []) }
    /// issue 的圖片備註存在 live 根目錄的 issue-images/ 底下，entry 只記相對路徑。
    var issueImageRoot: URL {
        let base = runtimeEnvironment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tatwo2/live", isDirectory: true)
        let dir = base.appendingPathComponent("issue-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func issueImageURLs(for entry: TatwoIssueListEntryV1) -> [URL] {
        entry.imageAssetPaths.compactMap { issueImageURL(relativeAssetPath: $0) }
    }
    func importLegacyIssueImages(_ entry: TatwoIssueListEntryV1) {
        guard selectedRemote == nil, let engine = localLive as? ChatLiveEngine else { return }
        let legacy = IssueImageAssets.extractingLegacyImages(from: entry.body)
        guard !legacy.paths.isEmpty else { return }
        do {
            let added = try IssueImageAssets.stage(paths: legacy.paths, root: issueImageRoot)
            var seen = Set<String>()
            let images = (entry.imageAssetPaths + added).filter { seen.insert($0).inserted }
            try engine.updateIssueImagesChecked(id: entry.id, body: legacy.text, images: images)
            refreshIssueLists()
        } catch { flashComposerHint("舊圖片尚未匯入，原文保留：\(error.localizedDescription)") }
    }
    func packIssueIntoComposer(_ entry: TatwoIssueListEntryV1) {
        if rejectRemoteWrite("issue 附件") { return }
        let urls = issueImageURLs(for: entry)
        guard urls.count == entry.imageAssetPaths.count else {
            flashComposerHint("有圖片已遺失，請重新附加；原草稿已保留")
            return
        }
        prompt = (prompt.isEmpty ? "" : prompt + "\n") + "【\(entry.title)】\n\(entry.body)"
        for url in urls {
            appendDroppedPath(url.path)
            droppedPathDisplayNames[url.path] = IssueImageAssets.displayName(url.lastPathComponent)
        }
    }
    func setGitHubRepoBindings(_ bindings: [TatwoGitHubRepoBinding], for projectID: UUID) {
        if rejectRemoteWrite("修改 GitHub 綁定") { return }
        guard isLive, let live else { return }
        var seen = Set<String>()
        let repos = bindings.compactMap { binding -> String? in
            let url = binding.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, seen.insert(url).inserted else { return nil }
            return url
        }
        gitHubRepoCheckMessages[projectID] = nil
        live.setGitHubRepos(repos, for: projectID)
    }
    /// 匯出交接包：2.0 沒有 1.0 的合約收據鏈，改成把這條討論串存成 Markdown，
    /// 你可以直接丟給別人或別台機器。存到專案資料夾，沒有專案就存桌面。
    func exportHandoffPack() {
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID, let thread = selectedThread else {
            flashComposerHint("先選一條討論串再匯出"); return
        }
        var lines = ["# \(thread.title)", "", "匯出時間：\(Self.exportStamp())"]
        if let project = selectedThreadProject { lines += ["專案：\(project.name)", "工作目錄：\(project.workdir)"] }
        lines += ["", "---", ""]
        for m in activeLive.transcript(for: id) {
            let who = m.role == .user ? "使用者" : (m.role == .system ? "系統" : "AI")
            lines += ["## \(who)\(m.status.map { "（\($0)）" } ?? "")", "", m.text, ""]
        }
        let dir = selectedThreadProject?.workdir ?? (NSHomeDirectory() + "/Desktop")
        let safe = thread.title.replacingOccurrences(of: "/", with: "-")
        let path = "\(dir)/交接包-\(safe).md"
        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            flashComposerHint("已匯出：\(path)")
        } catch {
            flashComposerHint("匯出失敗：\(error.localizedDescription)")
        }
    }

    private static func exportStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date())
    }
    /// Captures route and thread before asynchronous checkout; never sends to a newly selected room.
    private func startPRContribution(description: String, threadID: UUID) {
        guard let engine = localLive, !engine.isRunning(threadID),
              let sourcePlan = try? engine.loadPlanArtifact(threadID), sourcePlan.kind == "pr", sourcePlan.state == .confirmed,
              pendingPR.begin(threadID) else { return }
        let kind: ClaudeSidecar.Kind
        switch routeChoice.brandGroup {
        case .anthropic: kind = .claude
        case .openAI: kind = .codex
        case .xAI: kind = .grok
        default: kind = .claude
        }
        let login = engineLogin.status(for: kind)
        replaceEngineLoginStatus(login)
        guard login.isLoggedIn else {
            pendingPR.finish(threadID)
            resetPRPlan(threadID, planID: sourcePlan.planID, message: "這句沒有送出：請先登入目前引擎。")
            return
        }
        let model: String?
        switch kind {
        case .claude: model = routeChoice.modelArgument.flatMap { $0.hasPrefix("claude") ? $0 : nil }
        case .codex: model = routeChoice.modelArgument ?? routeChoice.canonicalModelSlug
        case .grok: model = routeChoice.modelArgument
        }
        let effort = kind == .codex ? selectedEffort.codexRawValue : nil
        let tier = kind == .codex ? selectedSpeedTier.appServerValue : nil
        let briefing = ultraworkTurnBriefing
        let cwd = engine.threadRecord(threadID)?.cwdOverride ?? selectedThreadProject?.workdir
        let repository = PullRequestService.repository
        preparingPR = true
        Task {
            var targetID = threadID
            defer { preparingPR = false }
            do {
                let identity = try PullRequestCoordinator.shared.identity()
                let checkout = try await PullRequestService().contributionCheckout(
                    current: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
                    repository: repository, identity: identity)
                if !checkout.useCurrent {
                    let pid = engine.doc.projects.first { $0.workdir == checkout.directory.path }?.id
                        ?? engine.newProject(name: checkout.directory.lastPathComponent, workdir: checkout.directory.path)
                    targetID = engine.newThread(in: pid)
                    pendingPR.finish(threadID)
                    _ = pendingPR.begin(targetID)
                    selectLocalThread(targetID)
                    engine.appendSystemMessage(threadID: targetID,
                        text: "已取得 TATWO OS 原始碼，開始處理：" + description, status: "info|PR")
                }
                let id = targetID
                if id != threadID {
                    var moved = TatwoPlanArtifactV1(planID: sourcePlan.planID, threadID: id, objective: sourcePlan.objective,
                        sections: sourcePlan.sections, createdAt: sourcePlan.createdAt, state: .confirmed, kind: "pr")
                    moved.executionTurnID = sourcePlan.executionTurnID
                    try engine.savePlanArtifact(moved)
                    var original = sourcePlan
                    original.prContinuationThreadID = id
                    original.prMessage = TatwoPlanArtifactV1.prMovedMessage
                    try engine.savePlanArtifact(original)
                }
                planInspectorRequest = UUID()
                engine.onTurnComplete[id] = { [weak self, weak engine] succeeded, reply in
                    guard let self, let engine, self.pendingPR.contains(id) else { return }
                    guard succeeded else {
                        self.pendingPR.finish(id)
                        self.resetPRPlan(id, planID: sourcePlan.planID, message: "引擎回合失敗或已停止，未開 PR。請檢查已改動檔案後再確認。")
                        return
                    }
                    Task {
                        defer { self.pendingPR.finish(id) }
                        do {
                            guard !engine.isRunning(id) else { throw PullRequestFailure(message: "討論串仍在工作，未開 PR。") }
                            guard var plan = try engine.loadPlanArtifact(id), plan.planID == sourcePlan.planID,
                                  plan.state == .confirmed else { return }
                            guard let sections = PRPlanReview.sections(reply) else {
                                throw PullRequestFailure(message: "缺少完整 tatwo-pr 五段摘要；未送 PR，請補齊後再確認。")
                            }
                            let snapshot = try await PullRequestService.snapshot(at: checkout.directory)
                            plan.sections = sections; plan.state = .ready
                            plan.updatedAt = TatwoPlanArtifactV1.storagePrecision(Date())
                            plan.prReview = PRPlanReview(directory: checkout.directory, repository: repository,
                                account: identity.username, snapshot: snapshot)
                            plan.sourceAssistantMessageID = engine.transcript(for: id).last { $0.role == .assistant }?.id
                            try engine.savePlanArtifact(plan)
                        } catch {
                            self.resetPRPlan(id, planID: sourcePlan.planID, message: error.localizedDescription)
                        }
                    }
                }
                guard engine.send(threadID: id, text: description + "\n\n" + PullRequestService.contributionInstruction,
                    model: model, engine: kind, systemPrompt: briefing,
                    reasoningEffort: effort, serviceTier: tier) else {
                    engine.onTurnComplete[id] = nil
                    throw PullRequestFailure(message: "引擎未接受這次工作，未開 PR。")
                }
            } catch {
                pendingPR.finish(targetID)
                resetPRPlan(targetID, planID: sourcePlan.planID, message: error.localizedDescription)
            }
        }
    }

    private func resetPRPlan(_ id: UUID, planID: UUID, message: String) {
        guard let engine = localLive, var plan = try? engine.loadPlanArtifact(id), plan.planID == planID else { return }
        plan.state = .discussing; plan.executionTurnID = nil; plan.prMessage = message
        _ = persistPlanCanvas(plan)
        engine.appendSystemMessage(threadID: id, text: message, status: "error|PR")
    }

    func submitActivePRPlan() {
        guard selectedRemote == nil, var plan = activePlanArtifact, plan.kind == "pr", plan.state == .ready,
              var review = plan.prReview, !review.attempted, let engine = localLive,
              !engine.isRunning(plan.threadID), pendingPR.begin(plan.threadID) else { return }
        do {
            let identity = try PullRequestCoordinator.shared.identity()
            guard identity.username == review.account, PullRequestService.repository == review.repository else {
                throw PullRequestFailure(message: "帳號或倉庫設定已變更，請切回卡片顯示的帳號與倉庫。")
            }
            let title = plan.sections.first { $0.title == "標題" }?.body ?? ""
            let description = plan.sections.filter { $0.title != "標題" }.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
            review.attempted = true; plan.prReview = review; plan.prMessage = "送出中…"
            guard persistPlanCanvas(plan) else { pendingPR.finish(plan.threadID); return }
            Task {
                defer { pendingPR.finish(plan.threadID) }
                do {
                    let url = try await PullRequestCoordinator.shared.submitPlan(directory: review.directory, repository: review.repository,
                        identity: identity, snapshot: review.snapshot, title: title, description: description)
                    plan.prReview?.submittedURL = url; plan.prMessage = nil
                } catch { plan.prMessage = error.localizedDescription + "\n未自動重送；請先確認本機分支與 GitHub 結果。" }
                _ = persistPlanCanvas(plan)
            }
        } catch {
            pendingPR.finish(plan.threadID); plan.prMessage = error.localizedDescription; _ = persistPlanCanvas(plan)
        }
    }

    func createProjectFromExistingFolder() -> UUID? {
        if rejectRemoteWrite("新增專案") { return nil }
        guard isLive, let live else { return nil }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "選這個資料夾當專案"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let pid = live.newProject(name: url.lastPathComponent, workdir: url.path)
        selectedThreadID = live.newThread(in: pid)
        return pid
    }
    func newChat() {
        if selectedRemote == nil {
            guard isLive, let localLive else { return }
            selectLocalThread(localLive.newThread(in: nil))
            return
        }
        guard isLive, let activeLive = activeConversationEngine else { return }
        let newID = activeLive.newThread(in: selectedThreadProject?.id)
        if let deviceID = selectedRemote?.deviceID {
            selectedRemote = (deviceID, newID)
        }
        selectedThreadID = newID
    }
    func threadActivityDate(_ thread: TatwoNativeChatThread) -> Date {
        localLive?.activityDate(thread.id) ?? .distantPast
    }
    func setProjectExpanded(_ projectID: UUID, isExpanded: Bool) {
        localLive?.setExpanded(projectID, isExpanded)
    }
    func createThread(inProject projectID: UUID) {
        // This action belongs to local project rows, even while a remote
        // conversation is selected. Remote rows have their own actions.
        guard isLive, let localLive,
              document.projects.contains(where: { $0.id == projectID }) else { return }
        selectLocalThread(localLive.newThread(in: projectID))
    }
    func selectDiscussion(projectID: UUID, threadID: UUID, discussionID: UUID) {
        guard
            isLive,
            let activeLive = activeConversationEngine,
            let discussion = activeLive.threadRecord(discussionID),
            discussion.projectID == projectID,
            discussion.parentThreadID == threadID,
            !discussion.isArchived
        else { return }
        selectedDiscussionID = discussionID
        if let deviceID = selectedRemote?.deviceID {
            selectedRemote = (deviceID, discussionID)
        }
        selectedThreadID = discussionID
    }
    func compressDiscussion(_ discussionID: UUID) {
        if rejectRemoteWrite("壓縮支線") { return }
        guard isLive, let parentID = live?.compressDiscussion(discussionID) else { return }
        selectedDiscussionID = nil
        selectedThreadID = parentID
    }
    func select(projectID: UUID, threadID: UUID) { selectLocalThread(threadID) }
    func toggleSelectedThreadPinned() {
        if rejectRemoteWrite("釘選討論串") { return }
        if let id = selectedThreadID { live?.togglePinned(id) }
    }
    func selectStandaloneThread(_ threadID: UUID) { selectLocalThread(threadID) }
    @discardableResult
    func reloadPluginRegistry(ifOlderThan age: TimeInterval = 0, now: Date = Date()) -> Task<Void, Never>? {
        guard isLive else { return nil }
        if let pluginRefreshTask { return pluginRefreshTask }
        guard now.timeIntervalSince(lastPluginScanAt) > age else { return nil }
        let environment = runtimeEnvironment
        pluginRefreshTask = Task { @MainActor [weak self] in
            // Skills are local files; publish them before the potentially slow MCP probe.
            let scanned = await Task.detached(priority: .utility) {
                PluginsSource.scanNow(environment: environment)
            }.value
            self?.pluginEntries = scanned
            self?.skillSuggestionSelectedIndex = nil
            let fresh = await Task.detached(priority: .utility) {
                PluginsSource.refreshNow(environment: environment)
            }.value
            self?.pluginEntries = fresh
            self?.lastPluginScanAt = Date()
            self?.pluginRefreshTask = nil
        }
        return pluginRefreshTask
    }
    func isThreadPluginEnabled(_ pluginID: String) -> Bool {
        guard let engine = PluginsSource.mcpEngine(from: pluginID) else { return true }
        guard engine == selectedMCPEngine,
              let name = PluginsSource.mcpName(from: pluginID)
        else { return false }
        let stored = live?.threadRecord(selectedThreadID)?.enabledMCP ?? []
        return PluginsSource.effectiveEnabledNames(
            stored: stored,
            engine: engine,
            environment: runtimeEnvironment).contains(name)
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
    func setCollaborationLevel(_ level: ChatCollaborationLevel) {
        collaborationLevel = level
        flashComposerHint(level == .off
            ? "ultrawork 關閉；這條討論串只有你和主導。"
            : "ultrawork \(level.title)：主導可以用 dispatch_rooms 開房間派工。")
    }
    func setPrimaryModel(_ modelID: String) { ultraworkPrimaryModelID = modelID }
    func setSecondaryModel(_ modelID: String) { ultraworkSecondaryModelID = modelID }
    func applyStoredUltraworkRoleDefaults(primaryModelID: String, secondaryModelID: String?) {
        ultraworkPrimaryModelID = primaryModelID
        ultraworkSecondaryModelID = secondaryModelID
    }

    /// 開了 ultrawork 時，把「檔位＋誰主導＋誰當 sub」附在這一輪的上游宣告後面，
    /// 讓引擎自己知道可以派工（2.0 的作法：不在 App 寫流程，靠上游宣告讓各家有共識）。
    var ultraworkTurnBriefing: String? {
        guard collaborationLevel != .off else { return nil }
        var lines = ["## 這一輪的 ultrawork 設定",
                     "檔位：\(collaborationLevel.title)（\(collaborationLevel.subtitle)）"]
        if let p = ultraworkPrimaryModelID { lines.append("主導：\(p)") }
        if let sec = ultraworkSecondaryModelID { lines.append("sub／副審：\(sec)") }
        lines.append("可用 tatwo2_os 的 dispatch_rooms 建子討論串；施工才建工作樹。純副審明確指定 readOnly:true，目前支援本機 claude 引擎，只提供 Read/Grep/Glob；其他路徑不會偷偷改成可寫入模式。主導仍負責修正，不需要協作時直接完成工作。")
        return lines.joined(separator: "\n")
    }
    func pasteClipboardImage() -> Bool { pasteClipboardImage(from: .general) }
    func pasteClipboardImage(from pasteboard: NSPasteboard) -> Bool {
        if rejectRemoteWrite("附件") { return false }
        if isLive, let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { appendDroppedPath(url.path) }
            return true
        }
        guard isLive, let img = NSImage(pasteboard: pasteboard), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        appendDroppedImageData(png, suggestedName: "剪貼簿.png"); return true
    }
    func removeDroppedPath(_ path: String) { droppedPaths.removeAll { $0 == path }; droppedPathDisplayNames[path] = nil }
    func effectivePermissionLabel(compact: Bool) -> String { permissionPreset.shortDisplayName }
    func appendDroppedImageData(_ data: Data, suggestedName: String) {
        if rejectRemoteWrite("附件") { return }
        guard let localLive else { return }
        do {
            let url = try localLive.savePastedAttachment(data: data, suggestedName: suggestedName)
            appendDroppedPath(url.path)
        } catch {
            flashComposerHint("圖片無法保存，請重試")
        }
    }
    func resolveArchiveIssuePrompt(keepIssues: Bool) { pendingArchiveIssuePrompt = nil }
    func captureCurrentDiscussionIntoIssueList() {
        if rejectRemoteWrite("issue") { return }
        if let id = selectedThreadID { live?.captureIssue(threadID: id); refreshIssueLists() }
    }
    func updateIssueListEntryBody(_ id: String, body: String) {
        if rejectRemoteWrite("issue") { return }
        live?.updateIssue(id) { $0.body = body }
        refreshIssueLists()
    }
    /// 匯入交接包：選一個檔，內容進輸入框讓你自己決定要不要送出（不自動執行）。
    func importHandoffPack() {
        if rejectRemoteWrite("匯入交接包") { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "選一個交接包（Markdown 或純文字）"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        prompt = prompt.isEmpty ? text : prompt + "\n\n" + text
        flashComposerHint("已帶入 \(url.lastPathComponent)；確認後再送出。")
    }
    func selectCLISession(projectID: UUID, sessionID: UUID) {
        guard
            let project = document.projects.first(where: { $0.id == projectID }),
            let session = project.sessions.first(where: { $0.id == sessionID })
        else { return }
        openCLITab(engine: cliBookEngine(session.engine), workdir: session.cwd)
    }
    func createCLISession(in projectID: UUID, engine: TatwoNativeCLIEngine) {
        guard let project = document.projects.first(where: { $0.id == projectID }) else { return }
        openCLITab(engine: cliBookEngine(engine), workdir: project.workdir)
    }
    func handoffCLISessionToThread(project: TatwoNativeChatProject, session: TatwoNativeCLISession) {}
    func mergeDiscussionIntoParent(_ discussionID: UUID) {
        if rejectRemoteWrite("合併支線") { return }
        guard isLive, let parentID = live?.mergeDiscussionIntoParent(discussionID) else { return }
        selectedDiscussionID = nil
        selectedThreadID = parentID
    }
    func requestRenameSelectedThread() {
        if rejectRemoteWrite("改名") { return }
        guard isLive, let id = selectedThreadID, let current = live?.threadRecord(id)?.title else { return }
        let alert = NSAlert()
        alert.messageText = "重新命名對話串"
        alert.informativeText = "只改 Tatwo2 的討論串標題。"
        alert.addButton(withTitle: "重新命名")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(string: current)
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        live?.rename(id, String(title.prefix(80)))
    }
    func setThreadPlugin(_ pluginID: String, enabled: Bool) {
        if rejectRemoteWrite("修改 MCP") { return }
        guard isLive, PluginsSource.mcpEngine(from: pluginID) != nil else { return }
        live?.setEnabledMCP(pluginID, enabled: enabled, engine: selectedMCPEngine)
        objectWillChange.send()
    }
    private var selectedMCPEngine: PluginsSource.MCPEngine {
        if let raw = live?.threadRecord(selectedThreadID)?.engine,
           let engine = PluginsSource.MCPEngine(rawValue: raw) { return engine }
        switch routeChoice.brandGroup {
        case .openAI: return .codex
        case .anthropic: return .claude
        default: return .grok
        }
    }
    func currentConversationWorkspaceURL() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
    func createLoopsSessionForSelectedThread() {}
    func selectLoopsSession(_ id: UUID) {}
    func archiveLoopsSession(_ id: UUID) {}
    func restoreLoopsSession(_ id: UUID) {}
    func appendHumanLoopNote(_ id: UUID, text: String) {}
    func dispatchLoopSub(_ id: UUID) {}
    func advanceLoopRound(_ id: UUID) {}
    func authorizePLG() {}
    func evaluatePLGMainline(_ accepted: Bool) {}
    func rollbackPLG() {}
    func confirmPLGPlanAndStartLoops() {}
    func endPLGRun() {}
    func togglePLGPause() { plgPaused.toggle() }
    func advanceNativeDevelopmentCycle() -> Bool { false }
    func clearPendingHandoff() {}
    func chooseAttachments() {
        if rejectRemoteWrite("附件") { return }
        guard isLive else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "附加"
        if panel.runModal() == .OK { for url in panel.urls { appendDroppedPath(url.path) } }
    }
    func enableCodexThreadMirror() {}
    func issueImageURL(relativeAssetPath: String) -> URL? {
        guard !relativeAssetPath.hasPrefix("/"),
              !relativeAssetPath.split(separator: "/").contains("..") else { return nil }
        let url = issueImageRoot.appendingPathComponent(relativeAssetPath)
        guard url.resolvingSymlinksInPath().path.hasPrefix(
            issueImageRoot.resolvingSymlinksInPath().path + "/") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func addImageNotes(to entry: TatwoIssueListEntryV1) {
        if rejectRemoteWrite("issue 附件") { return }
        guard isLive, let live else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        panel.message = "選要附在這則 issue 的圖片"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var added: [String] = []
        for url in panel.urls {
            let name = "\(entry.id)-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
            let dest = issueImageRoot.appendingPathComponent(name)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { added.append(name) }
        }
        guard !added.isEmpty else { flashComposerHint("圖片複製失敗"); return }
        live.updateIssue(entry.id) { $0.imageAssetPaths.append(contentsOf: added) }
        refreshIssueLists()
        flashComposerHint("已附加 \(added.count) 張圖片")
    }
    func createDiscussionForSelectedThread() {
        if rejectRemoteWrite("建立支線") { return }
        guard
            isLive,
            let parentID = selectedThreadID,
            let discussionID = live?.createDiscussion(parentThreadID: parentID)
        else { return }
        selectedDiscussionID = discussionID
        selectedThreadID = discussionID
    }
    func applySlashCommandSuggestion(_ item: SlashCommandItem) {
        // 只替換已打好的那半截指令，不動使用者其他字（1.0 :3100）
        prompt = ChatComposerSlashCatalog.inserting(command: item.cmd, into: prompt)
    }
    func archiveSelectedThread() {
        if rejectRemoteWrite("封存") { return }
        guard isLive, let threadID = selectedThreadID else { return }
        let next = live?.archive(threadID)
        selectedDiscussionID = nil
        selectedThreadID = next
    }
    func checkGitHubRepoUpdates(for projectID: UUID) {
        guard
            isLive,
            !gitHubRepoCheckingProjectIDs.contains(projectID),
            let project = live?.projectRecord(projectID),
            !project.githubRepos.isEmpty
        else { return }
        gitHubRepoCheckingProjectIDs.insert(projectID)
        gitHubRepoCheckMessages[projectID] = nil
        let workdir = project.workdir
        Task { @MainActor [weak self] in
            let message = await Task.detached(priority: .utility) {
                Self.readGitHubRepoStatus(workdir: workdir)
            }.value
            guard let self else { return }
            self.gitHubRepoCheckMessages[projectID] = message
            self.gitHubRepoCheckingProjectIDs.remove(projectID)
        }
    }
    func isCheckingGitHubRepo(for projectID: UUID) -> Bool {
        gitHubRepoCheckingProjectIDs.contains(projectID)
    }
    func gitHubRepoCheckMessage(for projectID: UUID) -> String? {
        gitHubRepoCheckMessages[projectID]
    }
    func copySelectedThreadSummary() {
        guard isLive, let activeLive = activeConversationEngine,
              let id = selectedThreadID, let thread = activeLive.threadRecord(id) else { return }
        let rows = activeLive.transcript(for: id).suffix(20)
        let body = rows.map { "\($0.role.storageValue)：\($0.text)" }.joined(separator: "\n")
        let summary = body.isEmpty ? "標題：\(thread.title)" : "標題：\(thread.title)\n\(body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        flashComposerHint("已複製摘要")
    }
    func duplicateSelectedThread(asBranch: Bool) {
        if rejectRemoteWrite(asBranch ? "建立支線副本" : "複製討論串") { return }
        guard
            isLive,
            let sourceID = selectedThreadID,
            let copyID = live?.duplicate(sourceID, asBranch: asBranch)
        else { return }
        selectedDiscussionID = asBranch ? copyID : nil
        selectedThreadID = copyID
    }
    /// →/↓ 下一個、←/↑ 上一個、Enter 插入。優先序：@ issue → / 指令 → $ 技能。1.0 :1344
    func handleComposerSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        if issueAtMentionQuery != nil, !issueAtMentionMatches.isEmpty { return handleIssueMentionKey(key) }
        if !matchingSlashCommands.isEmpty { return handleSlashSuggestionKey(key) }
        return handleSkillSuggestionKey(key)
    }

    func handleSkillSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let suggestions = skillSuggestions
        switch key {
        case .next:
            guard !suggestions.isEmpty else { return false }
            skillSuggestionSelectedIndex = ChatComposerSuggestionSelection.next(
                current: skillSuggestionSelectedIndex, count: suggestions.count)
            return true
        case .prev:
            guard skillSuggestionSelectedIndex != nil else { return false }
            skillSuggestionSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: skillSuggestionSelectedIndex, count: suggestions.count)
            return true
        case .commit:
            guard let cur = skillSuggestionSelectedIndex, cur < suggestions.count else { return false }
            applySkillSuggestion(suggestions[cur])
            return true
        }
    }

    func handleSlashSuggestionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let suggestions = matchingSlashCommands
        switch key {
        case .next:
            guard !suggestions.isEmpty else { return false }
            slashCommandSelectedIndex = ChatComposerSuggestionSelection.next(
                current: slashCommandSelectedIndex, count: suggestions.count)
            return true
        case .prev:
            guard slashCommandSelectedIndex != nil else { return false }
            slashCommandSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: slashCommandSelectedIndex, count: suggestions.count)
            return true
        case .commit:
            guard let cur = slashCommandSelectedIndex, cur < suggestions.count else { return false }
            applySlashCommandSuggestion(suggestions[cur])
            return true
        }
    }

    func handleIssueMentionKey(_ key: ChatComposerSuggestionKey) -> Bool {
        let matches = issueAtMentionMatches
        switch key {
        case .next:
            issueMentionSelectedIndex = ChatComposerSuggestionSelection.next(
                current: issueMentionSelectedIndex, count: matches.count)
            return true
        case .prev:
            guard issueMentionSelectedIndex != nil else { return false }
            issueMentionSelectedIndex = ChatComposerSuggestionSelection.previous(
                current: issueMentionSelectedIndex, count: matches.count)
            return true
        case .commit:
            let index = issueMentionSelectedIndex ?? 0
            guard index < matches.count else { return false }
            issueMentionSelectedIndex = nil
            pickIssueMention(matches[index])
            return true
        }
    }
    func handoffThreadToCLISession(project: TatwoNativeChatProject?, thread: TatwoNativeChatThread, engine: TatwoNativeCLIEngine = .codex) {}
    func openThreadProjectInCLI() {
        guard
            canOpenThreadInCLI,
            let thread = live?.threadRecord(selectedThreadID),
            let project = live?.projectRecord(thread.projectID),
            let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: project.workdir, isDirectory: true)],
            withApplicationAt: terminalURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.flashComposerHint("無法在終端機開啟：\(error.localizedDescription)")
            }
        }
    }
    /// 點選 @ 結果：清掉 @token、把該筆釘進右側資訊卡。1.0 :379
    func pickIssueMention(_ entry: TatwoIssueListEntryV1) {
        var parts = prompt.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        if let last = parts.last, last.hasPrefix("@") { parts.removeLast() }
        prompt = parts.joined(separator: " ")
        focusedIssueEntryID = entry.id
        requestOpenInfoCard = true
    }
    func removeIssueImageNote(_ relativePath: String, from entry: TatwoIssueListEntryV1) {
        if rejectRemoteWrite("issue 附件") { return }
        guard isLive, let engine = localLive as? ChatLiveEngine else { return }
        // Assets may also belong to another issue, composer draft or transcript.
        // Remove this reference only; never move shared bytes underneath readers.
        do {
            try engine.updateIssueImagesChecked(id: entry.id, body: entry.body,
                images: entry.imageAssetPaths.filter { $0 != relativePath })
            refreshIssueLists()
        } catch { flashComposerHint("圖片引用未移除，請重試：\(error.localizedDescription)") }
    }
    func resumeQueuedChatTurns() { chatQueuePaused = false }

    func openCLITestTab(
        executable: String,
        arguments: [String],
        title: String,
        workdir: String
    ) -> UUID? {
        guard let ownerID = selectedThreadID else { return nil }
        let tab = TatwoNativeCLISessionBook.Session(
            id: UUID(),
            engine: .generic,
            title: title,
            workdir: workdir,
            createdAt: Date(),
            updatedAt: Date(),
            isRunning: false)
        cliSessionsByThread[ownerID, default: []].append(tab)
        activeCLITabByThread[ownerID] = tab.id
        cliTabOwner[tab.id] = ownerID
        startCLITab(
            tab,
            launch: TatwoNativeTerminalLaunch(
                executable: executable,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: workdir, isDirectory: true)))
        registerCLIWorkbenchPane(tab, owner: ownerID)
        objectWillChange.send()
        return tab.id
    }

    private func startCLITab(
        _ tab: TatwoNativeCLISessionBook.Session,
        launch: TatwoNativeTerminalLaunch,
        seedText: String? = nil
    ) {
        guard isLive, isCLIRuntimeEnabled, let store = cliSessionStore, let runtime = cliRuntime else { return }
        let owner = cliTabOwner[tab.id]
        let project = owner.flatMap { live?.threadRecord($0)?.projectID }
        store.insert(.init(id: tab.id, title: tab.title, engine: tab.engine.rawValue,
            cwd: tab.workdir ?? NSHomeDirectory(), createdAt: tab.createdAt,
            lastActiveAt: Date(), status: .unknown, pinned: false, order: store.sessions.count,
            threadID: owner, projectID: project, tmuxName: CLITmuxRuntime.name(tab.id), background: false))
        let session = makeCLIWorkbenchSession(id: tab.id, runtime: runtime, store: store)
        cliTabPTYByID[tab.id] = session
        session.start(launch: launch)
    }

    private func updateCLITabRunning(_ id: UUID, isRunning: Bool) {
        guard
            let ownerID = cliTabOwner[id],
            let index = cliSessionsByThread[ownerID]?.firstIndex(where: { $0.id == id })
        else { return }
        cliSessionsByThread[ownerID]?[index].isRunning = isRunning
        cliSessionsByThread[ownerID]?[index].updatedAt = Date()
        objectWillChange.send()
    }

    private func persistCLITabs(ownerID: UUID) {
        let records = (cliSessionsByThread[ownerID] ?? []).map {
            LiveCLITabRecord(
                id: $0.id,
                engine: $0.engine.rawValue,
                cwd: $0.workdir ?? NSHomeDirectory(),
                title: $0.title)
        }
        cliStore?.updateCLITabs(threadID: ownerID, tabs: records)
    }

    private func launchForCLI(
        engine: TatwoNativeCLISessionBook.Engine,
        workdir: String
    ) -> TatwoNativeTerminalLaunch {
        let paths = engineLogin.paths
        var environment = runtimeEnvironment
        environment["PATH"] = paths.runtimeBinDirectory.path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TATWO2_OS_SOCKET"] = OSAgentBridge.resolveSocketPath(environment: runtimeEnvironment)
        environment["TATWO2_BROWSER_SOCKET"] = BrowserAgentBridge.resolveSocketPath(environment: runtimeEnvironment)
        let executable: String
        let arguments: [String]
        switch engine {
        case .claude:
            executable = paths.claudeExecutable.path
            environment["CLAUDE_CONFIG_DIR"] = paths.claudeConfigDirectory.path
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = NativeStagingIsolation.sidecarClaudeNamespace(
                environment: environment, configDirectory: paths.claudeConfigDirectory.path)
            arguments = permissionPreset == .askFirst ? ["--permission-mode", "default"] : permissionPreset.claudeArguments
        case .codex:
            executable = paths.codexExecutable.path
            environment["CODEX_HOME"] = paths.codexHome.path
            arguments = permissionPreset.codexArguments
        case .grok:
            executable = paths.runtimeBinDirectory.appendingPathComponent("grok-isolated").path
            environment["TATWO2_GROK_HOME"] = paths.grokHome.path
            arguments = permissionPreset.grokArguments
        case .generic:
            executable = "/bin/zsh"
            arguments = ["-l", "-i"]
        }
        return TatwoNativeTerminalLaunch(executable: executable, arguments: arguments,
            workingDirectory: URL(fileURLWithPath: workdir, isDirectory: true), environment: environment)
    }

    private func cliBookEngine(_ engine: TatwoNativeCLIEngine) -> TatwoNativeCLISessionBook.Engine {
        switch engine {
        case .codex: return .codex
        case .claude: return .claude
        case .grok: return .grok
        case .openclaw, .sandbox: return .generic
        }
    }

    private func cliEngineTitle(_ engine: TatwoNativeCLISessionBook.Engine) -> String {
        switch engine {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .generic: return "Shell"
        }
    }

    nonisolated private static func readGitHubRepoStatus(workdir: String) -> String {
        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workdir, isDirectory: true)
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_ASKPASS"] = "/usr/bin/false"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (
                    process.terminationStatus,
                    String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return (-1, "")
            }
        }

        let fetch = run(["fetch", "--dry-run"])
        let status = run(["status", "-sb"])
        guard status.status == 0 else {
            return "git status -sb 失敗（exit \(status.status)）"
        }

        func count(after marker: String) -> Int {
            guard let range = status.output.range(of: marker) else { return 0 }
            let suffix = status.output[range.upperBound...]
            return Int(String(suffix.prefix(while: \.isNumber))) ?? 0
        }

        let behind = count(after: "behind ")
        let ahead = count(after: "ahead ")
        var parts = [
            "落後 \(behind) commit",
            ahead > 0 ? "有未推 \(ahead) commit" : "無未推 commit",
        ]
        if fetch.status != 0 {
            parts.append("git fetch --dry-run 失敗（exit \(fetch.status)）")
        }
        return parts.joined(separator: "；")
    }


    // MARK: - 驗收用小門（只在 TATWO2_ACCEPT 無頭驗收時使用；不影響畫面）
    func acceptanceNewProject(name: String, workdir: String) -> UUID? { live?.newProject(name: name, workdir: workdir) }
    func acceptanceNewThread(in projectID: UUID?, title: String) -> UUID? {
        guard let live else { return nil }
        let id = live.newThread(in: projectID, title: title); selectedThreadID = id; return id
    }
    func acceptanceRename(_ id: UUID, _ title: String) { live?.rename(id, title) }
    func acceptanceAddIssue(threadID: UUID, title: String, body: String) {
        guard let live else { return }
        live.captureIssue(threadID: threadID)
        if let last = live.issues(threadID: threadID, global: false).first { live.updateIssue(last.id) { $0.title = title; $0.body = body } }
        refreshIssueLists()
    }
    func acceptanceBotID(named name: String) -> String? { botStore?.bots.first { $0.name == name }?.id }
}
