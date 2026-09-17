// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage.swift；改動 35 行（原因：保留既有接線；使用者 2026-09-06「全做」頁尾點擊與輔助功能）
import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin

struct ChatPage: View {
    @StateObject var browserWorkSpaceStore = BrowserWorkSpaceStore()
    @State var islandFooterHovering = false
    @StateObject var islandExceptionsCount = IslandExceptionsCount()
    @State var globalNoteOpen = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil && ["1", "2"].contains(ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_GLOBAL_NOTE"] ?? "")
    @Environment(\.tatwoSurfaceKind) var surface
    @ObservedObject var model: ChatPageModel
    private let retainedLifecycle: TatwoRetainedChatLifecycle?
    let quotaProviders: [UsageProviderStatus]
    let initialLiveQuotaSnapshot: LiveQuotaDeckSnapshot?
    private let gatewayLiveStatus: TatwoGatewayLiveStatus?
    @Binding var rightPanelPreference: Bool?
    @Binding var isRightPanelOpen: Bool
    @State private var dropIsTargeted = false
    @State var showDeveloperInfo = false
    @State var showComputerUseInfo = false
    @State var showIPadConnection = false
    @ObservedObject private var spaceSetupPreview = SpaceSetupPreviewState.shared
    @ObservedObject private var feedback = FeedbackCoordinator.shared
    @State var showTabDesignPhilosophy = false
    @State var tabDesignPhilosophyHoverGeneration = 0
    @State var tabDesignPhilosophyCloseWorkItem: DispatchWorkItem?
    @State var isChatProjectRailHovering = false
    @State var chatProjectPointerInside = false
    /// 2026-08-23 使用者：終端縮小後要有展開鈕才能回去（460 ⇄ 全高）。
    @State var expandedCLITabIDs: Set<UUID> = []
    // 2026-08-23 三分頁一致化：左列常駐改 AppStorage 三頁共用（Dia 收合鈕）；
    // export env 覆寫保留給金樣捕捉。
    @AppStorage("tatwo.sidebar.pinned") var sidebarPinnedPref = false
    static let envRailPinned = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_RAIL_PINNED"] == "1"
    @State var activeGoalDetailsExpanded = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_GOAL_EXPANDED"] == "1"
    @State var threadInfoPluginsExpanded = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_PLUGINS_EXPANDED"] == "1"
    @State var showChatSearch = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_SEARCH_OPEN"] == "1"
    @State var showSingleModelPanel = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_MODEL_PICKER_OPEN"] == "1"
    @State var showUltraworkPanel = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_ULTRAWORK_PANEL_OPEN"] == "1"
    @State var ultraworkRolePickerTarget: UltraworkRoleSlot?
    @State var ultraworkRoleConfiguration =
        UltraworkRoleConfigurationStore().load()
    @State var collaborationControlExpanded = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_COLLAB_EXPANDED"] == "1"
    @State var modelPickerRouteListExpanded = false
    // Codex 式 model picker：推理強度 / 進階 各自摺疊列（使用者 #32：模型/推理強度 rows + 進階）。
    @State var modelPickerEffortExpanded = false
    @State var modelPickerAdvancedExpanded = false
    // CLI 分頁：不預設導入 chat 專案；只顯示使用者明確「新增/匯入」的專案（使用者 D）。
    @AppStorage("tatwo.cli.visibleProjectIDs") var cliVisibleProjectIDsRaw: String = ""

    @State var collaborationSliderEditing = false
    @State var collaborationSliderSettling = false
    @State var collaborationSliderHovering = false
    @State var collaborationSliderVisualRatio: CGFloat?
    @State var collaborationSliderDragStartRatio: CGFloat?
    @State var collaborationSliderDragDirection: CGFloat = 0
    @State var collaborationSliderSettleGeneration = 0
    @State var collaborationSliderRevealProgress: Double =
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_COLLAB_EXPANDED"] == "1" ? 1 : 0
    @State var pendingCollaborationLevel: ChatCollaborationLevel?
    @State var sliderWindowRouteProbeButtonCount = 0
    @State var sliderWindowRouteProbeNativeCount = 0
    @State var sliderArchProbeButtonCount = 0
    @State var sliderArchProbeVisibleValue = 0.25
    @State var sliderArchProbeCompositionValue = 0.58
    @State var projectsSectionExpanded = true
    @State var chatsSectionExpanded = true
    // #討論串 clutter fix: 繼承快照/收工摘要細節預設收合，只在使用者主動展開時顯示。
    @State var expandedDiscussionDetailIDs: Set<UUID> = []
    @State var chatProjectHoverGeneration = 0
    @State var chatProjectHoverCloseWorkItem: DispatchWorkItem?
    /// Project whose GitHub repo list is being edited inline in the info card.
    @State var githubRepoEditingProjectID: UUID?
    @State var rightPanelContent: RightPanelContent = {
        switch ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_RIGHT_PANEL_CONTENT"] {
        case "browser": return .browser
        case "file": return .file
        case "diff": return .diff
        default: return .none
        }
    }()
    @AppStorage("tatwo.chat.browserPanelWidth")
    var browserPanelWidth: Double = 480
    // 跨元件訊號：band 的 TatwoWindowPageRail 讀此值，overlay 開啟時
    // 讓拖曳 NSView 讓出面板水平區，避免 performDrag 吃掉工具列點擊。
    @AppStorage("tatwo.chat.browserOverlayOpen")
    private var browserOverlayOpenSignal: Bool = false
    @GestureState var browserPanelDragTranslation: CGFloat = 0
    @GestureState var browserPanelResizeActive = false
    @State var isBrowserPanelResizeHandleHovered = false
    @State var loopsWorkspaceFocused = false
    // 資訊卡懸浮浮層開關（不進右側面板；使用者 2026-07-12：資訊卡要懸浮，不是開右頁）。
    @State var infoCardFloatingOpen =
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_INFOCARD_FLOATING"] == "1"
    // 設定/主題/選擇主題浮層（使用者 #54：額度改按鈕→主題選擇）。
    enum IssueSettingsTab { case all, archived }
    @State var showOSMenu = false
    @State var showSettingsPage = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_SETTINGS_OPEN"] == "1"  // 2.0 匯出旗標
    @State var updateSettingsSection: TatwoSettingsPage.Section?
    @State var showLiveQuota = false
    @State var showThemePicker =
        ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_CHAT_THEME_PICKER"] == "1"
    @ObservedObject var themeStore = TatwoThemeStore.shared
    /// CLI 分頁的「進行中 loops」列與標題呼吸光暈的資料源（Work OS dispatch registry）。
    /// 和 app delegate 的中斷閘共用同一份判定，不另造事件系統。
    @ObservedObject private var loopsActivity = TatwoLoopsActivityMonitor.shared
    /// CLI 左列 session 樹：Loops 段（進行中＋近 1h）；與 activity 同 registry。
    @State var cliLoopTreeRows: [CLILoopTreeRow] = []
    /// 點 loop 列後主區顯示詳情（非終端）。
    @State var selectedCLILoopID: String?
    @State var selectedCLILoopDetail: CLILoopDetailSnapshot?
    @State private var newChatCommandRegistrationID: UUID?
    @FocusState var composerFocused: Bool
    @State var composerTextHeight =
        TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
    @State var planInspectorPresented = false
    // 瀏覽器改用原生 inspector 承載（使用者 2026-09-01：「Plan 模式的拖拽
    // 表現非常好…照搬」）——系統邊緣拖拽、無把手、內容跟比例、頂部由系統管。
    @State var browserInspectorPresented = false
    let snapshotMenu = ChatSnapshotMenu.current
    private let exportRequestedWidth = Double(ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WIDTH"] ?? "") ?? Double.greatestFiniteMagnitude
    let chatProjectRailEdgeGuardWidth: CGFloat = 10
    let chatProjectRailRevealWidth: CGFloat = 18
    let chatProjectRailExitZoneWidth: CGFloat = 30
    // Hysteresis against edge flicker: at the physical window edge the pointer can
    // briefly cross into the dead edge-guard, which would fire a close and then
    // immediately re-open as it slips back into the reveal strip (visible flicker).
    // A longer close delay keeps the rail open through those sub-threshold dips so
    // only a sustained exit collapses it.
    let chatProjectRailCloseDelay: TimeInterval = 0.40

    /// WORK_OS.md Issue List 區：expandable queue、hover 預覽、點列展開全文。
    /// 右卡雙擊 × 只會封存；永久移除仍保留在設定頁的確認流程。
    @State var expandedIssueIDs: Set<String> = []
    @State var hoveredIssueID: String?
    @State var issueBodyDrafts: [String: String] = [:]
    @State var issueHoverCloseTask: Task<Void, Never>?

    init(
        model: ChatPageModel,
        retainedLifecycle: TatwoRetainedChatLifecycle? = nil,
        quotaProviders: [UsageProviderStatus] = [],
        initialLiveQuotaSnapshot: LiveQuotaDeckSnapshot? = nil,
        gatewayLiveStatus: TatwoGatewayLiveStatus? = nil,
        rightPanelPreference: Binding<Bool?> = .constant(nil),
        isRightPanelOpen: Binding<Bool> = .constant(false)
    ) {
        self.retainedLifecycle = retainedLifecycle
        self.quotaProviders = quotaProviders
        self.initialLiveQuotaSnapshot = initialLiveQuotaSnapshot
        self.gatewayLiveStatus = gatewayLiveStatus
        _rightPanelPreference = rightPanelPreference
        _isRightPanelOpen = isRightPanelOpen
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: isPanel ? 10 : 0) {
            if isPanel {
                topChrome
            }
            GeometryReader { proxy in
                let requestedExportWidth = exportRequestedWidth < 10_000 ? CGFloat(exportRequestedWidth) : proxy.size.width
                let layoutWidth = min(proxy.size.width, requestedExportWidth)
                let contentLayoutWidth = layoutWidth
                let hasThreadInfo = model.mode == .chat && model.selectedThreadID != nil
                let requestedRightPanelLayout = ChatRightPanelLayoutPolicy.resolve(
                    layoutWidth: contentLayoutWidth,
                    preference: rightPanelPreference,
                    widthClass: rightPanelContent == .loops ? .loops : .standard,
                    forceFocus: rightPanelContent == .loops && loopsWorkspaceFocused
                )
                let baseRightPanelLayout = hasThreadInfo
                    ? requestedRightPanelLayout
                    : ChatRightPanelLayoutPolicy.resolve(layoutWidth: contentLayoutWidth, preference: false)
                let browserOverlayLayout =
                    BrowserPanelOverlayLayoutPolicy.resolve(
                        layoutWidth: contentLayoutWidth,
                        requestedWidth:
                            BrowserPanelDragPolicy.previewWidth(
                                persistedWidth:
                                    CGFloat(browserPanelWidth),
                                translation:
                                    browserPanelDragTranslation,
                                windowWidth: contentLayoutWidth),
                        isOpen:
                            rightPanelContent == .browser
                            && baseRightPanelLayout.isOpen)
                let rightPanelLayout = browserOverlayLayout.isOpen
                    ? ChatRightPanelLayoutPolicy.resolve(
                        layoutWidth: contentLayoutWidth,
                        preference: false)
                    : baseRightPanelLayout
                let chatCanvasWidth = rightPanelLayout.mainContentWidth
                // All workspace modes reserve the same shared sidebar width.
                let sidebarWidth = ChatSidebarLayoutPolicy.width(for: layoutWidth)
                let workspaceOwnsSidebar = model.mode == .bot
                let showSidebar = (isChatProjectRailPinned || model.mode == .browser) && !workspaceOwnsSidebar && !isPanel
                    && (model.mode != .browser || ChatRunMode.browserPreviewEnabled)
                    && (model.mode != .browser || !browserWorkSpaceStore.focusMode)
                let showChatProjectHoverRail =
                    rightPanelLayout.showsMainContent
                    && !workspaceOwnsSidebar
                    && (model.mode != .browser || ChatRunMode.browserPreviewEnabled)
                    && !isPanel
                    // Gate the hover rail on the full window width, not the
                    // right-panel-reduced canvas: selecting a thread from the
                    // rail opens the info card, which shrank chatCanvasWidth
                    // below 760 mid-click and made the whole rail vanish before
                    // the click landed. Window width doesn't change on selection,
                    // so the rail now stays put while you click into it.
                    && layoutWidth >= 760
                let layoutPolicy = ChatLayoutPolicy.resolve(
                    layoutWidth: chatCanvasWidth,
                    railPinned: showSidebar,
                    sidebarVisible: showSidebar)
                let leadingReserve: CGFloat = (isPanel || workspaceOwnsSidebar || model.mode == .browser) ? 0 : layoutPolicy.leadingReserve
                let trailingReserve: CGFloat = (isPanel || workspaceOwnsSidebar || model.mode == .browser) ? 0 : layoutPolicy.trailingReserve
                let sidebarContentGap = model.mode == .browser ? WorkspaceSidebarMetrics.browserContentGap : WorkspaceSidebarMetrics.contentGap
                let mainAvailableWidth = max(
                    320,
                    chatCanvasWidth
                    - (showSidebar ? sidebarWidth + sidebarContentGap : 0)
                    - leadingReserve
                    - trailingReserve
                )
                let contentMaxWidth = isPanel
                    ? min(ChatUILayout.chatColumnMaxWidth, mainAvailableWidth)
                    : layoutPolicy.contentMaxWidth
                HStack(alignment: .top, spacing: rightPanelLayout.spacing) {
                    if rightPanelLayout.showsMainContent {
                        ZStack(alignment: .topLeading) {
                            HStack(alignment: .top, spacing: showSidebar ? sidebarContentGap : 0) {
                                if showSidebar {
                                    // 2026-08-21 使用者：「左列分頁請加長跟整個
                                    // app 天地齊平」——側欄玻璃填滿視窗高度。
                                    // 2026-08-23：落地對齊 app 底（抵銷外層 18pt；
                                    // 常駐槽位之前漏掉，只修了 hover rail）。
                                    sidebar
                                        .frame(width: sidebarWidth)
                                        .frame(maxHeight: .infinity, alignment: .top)
                                        .layoutPriority(2)
                                }
                                mainPane(
                                    contentMaxWidth: contentMaxWidth,
                                    forceCompactToolbar: chatCanvasWidth < 900
                                )
                                .padding(.leading, leadingReserve)
                                .padding(.trailing, trailingReserve)
                                .layoutPriority(1)
                            }
                            .frame(width: chatCanvasWidth, alignment: .topLeading)
                            .frame(maxHeight: .infinity, alignment: .topLeading)

                            // 極光實機驗收 #重疊（2026-08-20）：OS 選單開啟時
                            // 抑制 hover rail——左下角一次只有一個面（互斥）。
                            if showChatProjectHoverRail && !showSidebar && !showOSMenu {
                                chatProjectHoverSurface(width: sidebarWidth)
                                    .offset(x: 0)
                                    .zIndex(5)
                            }

                            snapshotMenuOverlay(
                                sidebarWidth: showSidebar ? sidebarWidth : leadingReserve,
                                containerSize: CGSize(width: chatCanvasWidth, height: proxy.size.height)
                            )
                        }
                        .frame(width: chatCanvasWidth, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(WindowTrafficLightVisibilitySync(sidebarPinned: sidebarPinnedPref))
                        // 資訊卡/瀏覽器/檔案：對齊 Codex chrome 頂右單一列（#50/#51）；上移到 band 高度內，與交通燈同水平。
                        // 2026-09-02 使用者：常駐鈕、資訊卡、工具箱三顆一起放在頂右、紅綠燈基準線。
                        .overlay(alignment: .topTrailing) {
                            if !isPanel && model.mode != .browser {
                                rightPanelControlStrip(showsThreadControls: hasThreadInfo)
                                    .padding(.trailing, 14)
                                    .offset(y: -WindowChromeMetrics.chromeRowLift)
                            }
                        }
                        // 懸浮資訊卡浮層（使用者 2026-07-12：資訊卡要懸浮，不開右頁）；掛在 strip 之上、可點外關閉。
                        .overlay {
                            if infoCardFloatingOpen && hasThreadInfo {
                                chatFloatingInfoCardOverlay
                            }
                        }
                        // 2026-08-21 使用者裁決：左下角可點擊的 TATWO OS 字標
                        // 移除，OS 入口只保留左列分頁（chatSidebar）那一份。
                        .overlay {
                            if globalNoteOpen {
                                GlobalNotePanel(isOpen: $globalNoteOpen, windowHeight: proxy.size.height,
                                                documentOpen: rightPanelLayout.isOpen && rightPanelContent == .file)
                            }
                        }
                        // TATWO OS 布標浮層（標準玻璃樣式）；錨定左下、可點外關閉、設定可點擊進入。
                        .overlay {
                            if showOSMenu {
                                tatwoOSMenuOverlay
                            }
                        }
                        // 額度 Live quota 浮層（從左下 OS 選單叫出，自繪不依賴右側工具列）。
                        .overlay {
                            if showLiveQuota {
                                liveQuotaOverlay
                            }
                        }
                        // 設定/主題/選擇主題浮層（使用者 #54）；錨定左下(靠近觸發按鈕)、可點外關閉。
                        .overlay {
                            if showThemePicker {
                                chatThemePickerOverlay
                            }
                        }
                        // ② 全文搜尋浮層（/搜尋 觸發）；開啟建索引、點暗幕/Esc 關閉、點結果跳轉。
                        .overlay {
                            if showChatSearch {
                                TatwoChatSearchOverlay(
                                    indexProvider: { model.makeChatSearchIndex() },
                                    onJump: { doc in
                                        model.jumpToSearchResult(doc)
                                        withAnimation(.easeOut(duration: 0.16)) { showChatSearch = false }
                                    },
                                    onClose: {
                                        withAnimation(.easeOut(duration: 0.16)) { showChatSearch = false }
                                    })
                                .transition(.opacity)
                                .zIndex(60)
                            }
                        }
                        // fable5 蛾裝飾款式預覽（headless 自驗用）：TATWO_ULTRAWORK_MOTH_PREVIEW=1。
                        .overlay {
                            if ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_MOTH_PREVIEW"] == "1" {
                                HStack(spacing: 40) {
                                    ForEach(TatwoMothStyle.allCases) { s in
                                        VStack(spacing: 8) {
                                            TatwoMothDecor(style: s, opacity: 0.9)
                                                .frame(width: 150, height: 190)
                                            Text(s.rawValue).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }

                    if rightPanelLayout.isOpen {
                        // 2026-09-02 使用者：右側工具面板要像左列一樣貼齊 App 天地，
                        // 不再在紅綠燈帶高留一節空白；結構欄不是浮板。
                        LiquidGlassPanelCard(cornerRadius: 0) {
                            VStack(alignment: .leading, spacing: 8) {
                                if rightPanelLayout.presentation == .compactTakeover
                                    || rightPanelLayout.presentation == .focusedTakeover {
                                    rightPanelTakeoverHeader(
                                        presentation: rightPanelLayout.presentation)
                                }
                                rightPanelPane
                            }
                            .padding(.top, WindowChromeMetrics.bandHeight)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(width: rightPanelLayout.panelWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                    }
                }
                .frame(width: contentLayoutWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    if browserOverlayLayout.isOpen {
                        browserPanelOverlay(
                            panelWidth: browserOverlayLayout.panelWidth,
                            panelHeight: proxy.size.height,
                            windowWidth: contentLayoutWidth)
                            .zIndex(80)
                            .onAppear { browserOverlayOpenSignal = true }
                            .onDisappear {
                                browserOverlayOpenSignal = false
                            }
                    }
                }
                .frame(width: layoutWidth, alignment: .topLeading)
                // Settings covers the entire workspace, including open tool panels.
                .overlay {
                    if showSettingsPage {
                        tatwoSettingsOverlay
                    }
                }
                .onAppear {
                    // Snapshot seam: TATWO_ULTRAWORK_EXPORT_RIGHT_PANEL=file|diff opens
                    // the structural right panel so goldens can capture it.
                    if let exported = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_RIGHT_PANEL"],
                       ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil {
                        switch exported {
                        case "file": rightPanelContent = .file
                        case "diff": rightPanelContent = .diff
                        default: break
                        }
                        if rightPanelContent != .none { rightPanelPreference = true }
                    }
                    if BrowserPanelWidthPolicy.needsLegacyWidthMigration(
                        CGFloat(browserPanelWidth))
                    {
                        browserPanelWidth = Double(
                            BrowserPanelWidthPolicy.defaultWidth(
                                windowWidth: contentLayoutWidth))
                    }
                    isRightPanelOpen =
                        browserOverlayLayout.isOpen
                        || rightPanelLayout.isOpen
                }
                .onChange(of: model.requestOpenInfoCard) { _, requested in
                    guard requested else { return }
                    model.requestOpenInfoCard = false
                    if hasThreadInfo {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                            infoCardFloatingOpen = true
                        }
                    }
                }
                // 2.0 水電接點：引擎透過瀏覽器橋要求打開內建瀏覽器面板（同 requestOpenInfoCard 的模式）
                .onChange(of: model.requestOpenBrowserPanel) { _, requested in
                    guard requested else { return }
                    guard model.consumeBrowserAgentPanelRequest() else { return }
                    // 跟工具箱「瀏覽器」同一條路：原生 inspector（會推開 chat、可拖拉調比例），不是舊的右側 overlay
                    browserInspectorPresented = true
                }
                .onChange(of: model.requestOpenAccountBrowser) { _, requested in
                    guard requested else { return }
                    model.requestOpenAccountBrowser = false
                    browserInspectorPresented = true
                }
                .onChange(
                    of:
                        browserOverlayLayout.isOpen
                        || rightPanelLayout.isOpen
                ) { _, newValue in
                    isRightPanelOpen = newValue
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: surface == .window ? .infinity : nil, alignment: .topLeading)
        .font(ChatTypography.body)
        .background(chatCanvasLegibilityLayer)
        .onChange(of: model.planInspectorRequest) { _, request in
            if request != nil { planInspectorPresented = true }
        }
        .inspector(isPresented: $planInspectorPresented) {
            PlanTranscriptInspectorView(
                artifact: model.activePlanArtifact,
                isPresented: $planInspectorPresented,
                isWriting: model.isRunning,
                selection: model.planFlowSelectionProjection?.selection,
                localActionPresentation:
                    model.planWorkOSLocalActionPresentation,
                editableText: model.editablePlanTextForCanvas(),
                onSelectionChange: model.updatePlanFlowSelection,
                onSaveEditedText: model.saveEditedPlanCanvasText,
                ultraworkPanel: AnyView(planUltraworkCanvasPanel),
                ultraworkPrimaryModelID:
                    collaborationRoleModelID(for: .primary),
                ultraworkSecondaryModelID:
                    planUltraworkAuxiliaryCount > 0
                        ? collaborationRoleModelID(for: .auxiliary(0))
                        : nil,
                ultraworkAuxiliaryCount: planUltraworkAuxiliaryCount,
                onDismissUltrawork: {
                    showUltraworkPanel = false
                    ultraworkRolePickerTarget = nil
                },
                onExecute: model.confirmActivePlan,
                onStart: model.startActivePlan,
                onFeedbackSubmitted: model.finishFeedbackPlan,
                onDistillSubmission: model.saveDistillSubmission,
                onPRSubmit: model.submitActivePRPlan,
                onPRDiscuss: model.returnActivePRToDiscussion)
                .id(model.activePlanArtifact?.planID)
        }
        .inspector(isPresented: $browserInspectorPresented) {
            EmbeddedBrowserView(
                sessionID: model.selectedThreadID?.uuidString.lowercased(),
                model: model,
                agentControllable: true)
                .inspectorColumnWidth(min: 420, ideal: 640, max: 960)
        }
        .onAppear {
            model.updateGatewayLiveStatus(gatewayLiveStatus)
            // 容器關閉＝使用者已過 LoopsInterruptGate 確認。這裡除了停 chat runner，
            // 還要顯式收掉 CLI 分頁的 shell，不留給 dealloc（規格：中斷不得靜默遺失）。
            retainedLifecycle?.registerStopHandler {
                model.shutdownForContainerClose()
            }
            // Window-close confirmation (Island) fires only while chat work is running.
            TatwoInterruptGate.activityProvider = { [weak model] in
                model?.hasRunningWork ?? false
            }
            loopsActivity.attach()
            refreshCLILoopTree()
            if model.collaborationLevel != .off {
                applyStoredUltraworkRoleConfigurationToModel()
            }
            if newChatCommandRegistrationID == nil {
                newChatCommandRegistrationID =
                    TatwoNewChatCommandCenter.shared.register {
                        [weak model] in
                        model?.newChat()
                    }
            }
        }
        .onChange(of: loopsActivity.snapshot) { _, _ in
            // activity 輪詢有變 → 重投影左列 Loops（含近 1h 完成）。
            refreshCLILoopTree()
        }
        .onChange(of: gatewayLiveStatus) { _, newStatus in
            model.updateGatewayLiveStatus(newStatus)
        }
        .onChange(of: model.selectedThreadID) { _, _ in
            // 切換 thread 時關掉懸浮資訊卡（避免殘留在別的 thread 上）。右側面板 browser/file 狀態保留。
            if infoCardFloatingOpen { infoCardFloatingOpen = false }
            if planInspectorPresented { planInspectorPresented = false }
            // issue list 回到本串範圍（跨聊天不亂竄；全域要重新 @ 或按切換）。
            model.issueListShowsGlobal = false
        }
        .onChange(of: model.collaborationLevel) { _, newLevel in
            guard newLevel != .off else { return }
            applyStoredUltraworkRoleConfigurationToModel()
        }
        .onChange(of: model.requestOpenLoopsPanel) { _, req in
            // B1：Loops 已併進專案底下的子討論串；舊右側工作區不再有入口。
            if req {
                model.requestOpenLoopsPanel = false
            }
        }
        .onChange(of: model.mode) { _, newMode in
            resetChatProjectHover()
            if newMode == .cli, model.isCLIRuntimeEnabled {
                model.ensureNativeTerminal()
            }
        }
        .onChange(of: browserWorkSpaceStore.focusMode) { _, _ in
            resetChatProjectHover()
        }
        .onChange(of: browserWorkSpaceStore.sidebarInteractionActive) { _, active in
            if !active { updateChatProjectHover(chatProjectPointerInside) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .tatwoChatSelectMode)
        ) { notification in
            guard let raw = notification.object as? String,
                  let requested = ChatRunMode(rawValue: raw),
                  ChatRunMode.visibleChatTabs.contains(requested)
            else { return }
            model.mode = requested
        }
        // 2026-08-23 工程 B 收尾：MCP 工具授權一鍵放行（ChatBubble 按鈕→通知→
        // per-thread allowlist，下一輪生效）。
        .onReceive(
            NotificationCenter.default.publisher(for: .tatwoChatAllowMCPTool)
        ) { notification in
            guard let tool = notification.object as? String else { return }
            model.allowMCPTool(named: tool)
        }
        // 2026-08-24 D 工作流：plan 問題膠囊（ChatBubble 選項→通知→
        // 答案回送同 session 續跑，不重貼使用者訊息）。
        .onReceive(
            NotificationCenter.default.publisher(
                for: .tatwoChatAnswerPlanQuestion)
        ) { notification in
            model.handlePlanQuestionAnswerNotification(notification)
        }
        .onDrop(of: model.mode == .browser && browserWorkSpaceStore.selectedSpace.isSessionSpace
                ? [] : [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $dropIsTargeted) { providers in
            guard model.mode != .browser || !browserWorkSpaceStore.selectedSpace.isSessionSpace else { return false }
            return handleDrop(providers: providers)
        }
        .modifier(SpaceBuilderPresentation())
        .sheet(isPresented: feedback.presentation(for: "Chat")) {
            FeedbackSheet(coordinator: feedback)
        }
        .overlay {
            if dropIsTargeted && !(model.mode == .browser && browserWorkSpaceStore.selectedSpace.isSessionSpace) {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle)
                    .strokeBorder(
                        LiquidGlassTokens.brandAccent.opacity(LiquidGlassTokens.strokeOpacity),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                    )
                    .background(
                        LiquidGlassTokens.brandAccent.opacity(LiquidGlassTokens.tintOpacity),
                        in: RoundedRectangle(
                            cornerRadius: LiquidGlassTokens.radiusCard,
                            style: LiquidGlassTokens.shapeStyle
                        )
                    )
                    .overlay(Label("放開以附加圖片/檔案路徑", systemImage: "photo.badge.plus").font(.headline))
            }
        }
        .onDisappear {
            resetChatProjectHover()
            if let newChatCommandRegistrationID {
                TatwoNewChatCommandCenter.shared.unregister(
                    newChatCommandRegistrationID)
                self.newChatCommandRegistrationID = nil
            }
            loopsActivity.detach()
            if retainedLifecycle == nil {
                model.stop()
            }
        }
    }
}
