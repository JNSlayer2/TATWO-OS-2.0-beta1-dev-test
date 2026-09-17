// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/BotPage.swift；改動 59 行（原因：保留既有接線；使用者 2026-09-06「全做」頁尾點擊與輔助功能）
import SwiftUI
import AppKit

// Gen-4 bot 分頁（純 UI 展示層；狀態機＝BotPageState / Gen4BotStateMachineV1）。
// 匯出仍是 fixture；live 僅接既有 BotLibrary / sendAsBot，不新增 runner。

enum BotContentMode: String, CaseIterable {
    case botThread, spaceCanvas, addSpace, settings
}

struct BotPageRootView: View {
    @StateObject var state: BotPageState
    @ObservedObject private var spacePreview = SpaceSetupPreviewState.shared
    @ObservedObject private var liveSpaces = SpaceWorkspaceController.shared
    /// 2026-08-23 修「進得去出不來」：側欄 Chat/CLI/Bot 膠囊接真實切換回呼。
    var onSwitchMode: ((ChatRunMode) -> Void)?

    init(sceneID: String, contentMode: BotContentMode = .botThread, quickCardOpen: Bool = false,
         onSwitchMode: ((ChatRunMode) -> Void)? = nil) {
        _state = StateObject(wrappedValue: BotPageState(
            sceneID: sceneID, contentMode: contentMode, quickCardOpen: quickCardOpen,
            isUIOnlyPreview: SpaceSetupPreviewState.isEnabled))
        self.onSwitchMode = onSwitchMode
    }

    /// 場景→畫面模式映射（金樣捕捉用；GEN4 12 場景）。
    static func forScene(_ id: String, onSwitchMode: ((ChatRunMode) -> Void)? = nil) -> BotPageRootView {
        switch id {
        case "space-full", "space-compact", "space-status":
            return .init(sceneID: id, contentMode: .spaceCanvas, onSwitchMode: onSwitchMode)
        case "quick-card":
            return .init(sceneID: id, contentMode: .spaceCanvas, quickCardOpen: true, onSwitchMode: onSwitchMode)
        case "add-space":
            return .init(sceneID: id, contentMode: .addSpace, onSwitchMode: onSwitchMode)
        case "settings-9row":
            return .init(sceneID: id, contentMode: .settings, onSwitchMode: onSwitchMode)
        default:
            return .init(sceneID: id, onSwitchMode: onSwitchMode)
        }
    }

    var body: some View {
        existingBody
    }

    private var existingBody: some View {
        Group {
            if state.unknownScene {
                BotEmptyHint(symbol: "exclamationmark.octagon", text: "未知場景・fail-closed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mainSlot
                    .padding(.leading, sidebarIsPinned ? WorkspaceSidebarMetrics.width : 0)
                    // 書側標籤耳（2026-08-22 使用者：「要在 app 外筐之外」）：
                    // 互動模式用 child window 掛在主窗右緣外側（視圖畫不出視窗外，
                    // 子視窗可以）。Space 快照由測試宿主在主窗範圍外呈現外耳，
                    // 不得為了輸出圖片把外書籤移入主內容。
                    .overlay(alignment: .trailing) {
                        if Self.snapshotExportMode && !state.isUIOnlyPreview {
                            workspaceTabsRail.zIndex(30)
                        }
                    }
                    .background {
                        if !Self.snapshotExportMode {
                            if state.isUIOnlyPreview {
                                SpaceSetupEdgeTabsMounter()
                            } else if let projection = liveSpaces.state {
                                SpaceSetupEdgeTabsMounter(preview: projection,
                                    onSelect: { liveSpaces.openInterface($0) },
                                    onAdd: { liveSpaces.openBuilder() })
                            } else {
                                BotEdgeTabsMounter(state: state)
                            }
                        }
                    }
                    // 私訊小視窗＋FAB＋點空白關窗層：掛在側欄之下，
                    // 小視窗開著時左列 hover 照常可用（2026-08-22 修）。
                    .overlay(alignment: .bottomTrailing) {
                        if !state.isUIOnlyPreview {
                        ZStack(alignment: .bottomTrailing) {
                            if state.quickCardOpen {
                                Color.black.opacity(0.001)
                                    .contentShape(Rectangle())
                                    .onTapGesture { state.closeQuickCard() }
                            }
                            VStack(alignment: .trailing, spacing: 10) {
                                if state.quickCardOpen {
                                    BotMessagesPanel(state: state, onClose: { state.closeQuickCard() })
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                                Button { state.quickCardOpen ? state.closeQuickCard() : state.openQuickCard() } label: {
                                    Image(systemName: "bubble.left.fill")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.75))
                                        .frame(width: 44, height: 44)
                                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                                        .overlay(Circle().stroke(.primary.opacity(0.25), lineWidth: 1))
                                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                                }
                                .buttonStyle(.plain)
                                .help("bot 私訊（展示）")
                            }
                            .padding(.trailing, 12)
                            .padding(.bottom, 8)
                        }
                        }
                    }
                    // 左列改 chat/cli 同款：滑鼠指到左緣才顯示（hover rail）。
                    .overlay(alignment: .leading) {
                        Color.clear
                            .frame(width: 16)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { showSidebar() }
                            }
                    }
                    .overlay(alignment: .leading) {
                        if sidebarShown && !sidebarIsPinned {
                            diaSidebar
                                .transition(.move(edge: .leading).combined(with: .opacity))
                                .zIndex(40)
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: sidebarShown)
                    .overlay(alignment: .leading) {
                        if sidebarIsPinned {
                            diaSidebar
                                .zIndex(40)
                        }
                    }
                    // 雙指滑動：資訊卡開著＝切卡頁（資訊卡⇄Bot’s Bag，像 space switch）；
                    // 否則照舊 switch space（使用者 2026-08-22）。
                    .background(BotSwipeCatcher { direction in
                        if state.isUIOnlyPreview {
                            let ids = spacePreview.domains.map(\.id)
                            if let index = ids.firstIndex(of: spacePreview.selectedDomainID) {
                                spacePreview.selectDomain(ids[(index + (direction > 0 ? 1 : ids.count - 1)) % ids.count])
                            }
                        } else if state.pocketOpen {
                            withAnimation(.easeOut(duration: 0.2)) {
                                infoCardPage = max(0, min(1, infoCardPage + direction))
                            }
                        } else if let projection = liveSpaces.state {
                            let ids = projection.domains.map(\.id)
                            if let index = ids.firstIndex(of: projection.selectedDomainID) {
                                liveSpaces.selectDomain(ids[(index + (direction > 0 ? 1 : ids.count - 1)) % ids.count])
                            }
                        } else {
                            direction > 0 ? state.pagerNext() : state.pagerPrev()
                        }
                    })
            }
        }
        .task(id: liveSpaces.allows(.bot)) {
            if !state.isUIOnlyPreview && liveSpaces.allows(.bot) { await state.observeLiveBots() }
        }
        .onChange(of: liveSpaces.selectedDomainID) { _ in
            if !state.isUIOnlyPreview { state.refreshLiveBots() }
        }
        // 展示水印：右下浮鈕左側（左下會壓到 hover 側欄的底列）。
        .overlay(alignment: .bottomTrailing) {
            if !state.isUIOnlyPreview {
                watermark.padding(.trailing, 56).padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if !state.isUIOnlyPreview && state.contentMode == .settings { settingsOverlay }
        }
        .background {
            if !(state.isUIOnlyPreview && Self.snapshotExportMode) {
                WindowTrafficLightVisibilitySync(sidebarPinned: sidebarIsPinned)
            }
        }
        .overlay(alignment: .topLeading) {
            if !sidebarIsPinned {
                sidebarPinButton
                    // 視窗控制常駐可見，固定鈕排在其右側。
                    .padding(.leading, WindowChromeMetrics.appControlLeadingX)
                    .padding(.top, 7)
                    .zIndex(60)
            }
        }
        // 封存二次確認（臨時工區 → 設定封存區）。
        .alert(
            "封存這隻臨時 bot？",
            isPresented: Binding(
                get: { state.confirmArchiveTempID != nil },
                set: { if !$0 { state.cancelArchiveTempBot() } })
        ) {
            Button("封存") { state.confirmArchiveTempBot() }
            Button("取消", role: .cancel) { state.cancelArchiveTempBot() }
        } message: {
            Text("會移入設定的封存區（不會直接刪除）；要真移除需到設定裡再刪一次。")
        }
        // 書籤圓點雙擊 → 確認全關視窗。
        .alert(
            "關閉工作空間？",
            isPresented: Binding(
                get: { state.confirmCloseBookmarkID != nil },
                set: { if !$0 { state.cancelCloseBookmark() } })
        ) {
            Button("全關並停止運作", role: .destructive) { state.confirmCloseBookmark() }
            Button("取消", role: .cancel) { state.cancelCloseBookmark() }
        } message: {
            Text("「\(state.currentBookmarks.first { $0.id == state.confirmCloseBookmarkID }?.name ?? "")」將停止運作（展示，不影響任何真實系統）。")
        }
    }

    // MARK: - Dia 式左列選單（hover 才顯示；對標 chat/cli 的 hover rail）

    /// 快照 export 模式（金樣捕捉）；互動 runtime 為 false。
    static let snapshotExportMode: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
    }()

    /// export-only：快照模式可強制顯示側欄（驗收截圖用；互動預設 hover 才顯示）。
    private static let exportSidebarShown: Bool = {
        guard snapshotExportMode else { return false }
        return ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_BOT_SIDEBAR"] == "1"
    }()

    @State private var sidebarShown = BotPageRootView.exportSidebarShown
    @State private var sidebarHideTask: DispatchWorkItem?
    /// 2026-08-23 三分頁一致化：左列常駐（Dia 收合鈕）三頁共用同一狀態。
    @AppStorage("tatwo.sidebar.pinned") private var sidebarPinnedPref = false
    @State private var previewPinOverride: Bool?
    /// Capture the real sidebar beside the new content without writing user preferences.
    private var sidebarIsPinned: Bool {
        if state.isUIOnlyPreview {
            return previewPinOverride ?? (sidebarPinnedPref || Self.exportSidebarShown)
        }
        return sidebarPinnedPref
    }

    /// Dia 原樣常駐鈕（同 ChatPage；2026-08-23 使用者三修）。
    private var sidebarPinButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if state.isUIOnlyPreview { previewPinOverride = !sidebarIsPinned }
                else { sidebarPinnedPref.toggle() }
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.62))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(sidebarIsPinned ? "取消左列常駐" : "左列常駐展示")
    }

    private func showSidebar() {
        sidebarHideTask?.cancel(); sidebarHideTask = nil
        sidebarShown = true
    }

    private func scheduleSidebarHide() {
        sidebarHideTask?.cancel()
        let task = DispatchWorkItem { if !sidebarIsPinned { sidebarShown = false } }
        sidebarHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    private var previewVisibleModes: [ChatRunMode] {
        guard state.isUIOnlyPreview else { return ChatRunMode.visibleChatTabs }
        return spacePreview.selectedDomain.visibleTabs.compactMap { ChatRunMode(rawValue: $0.rawValue) }
    }

    private var previewSelectedMode: ChatRunMode {
        guard state.isUIOnlyPreview,
              let tab = spacePreview.selectedDomain.selectedTab,
              let mode = ChatRunMode(rawValue: tab.rawValue) else { return .bot }
        return mode
    }

    /// Domain-owned fixture rows inside the existing Bot sidebar, not a second sidebar.
    private var previewBotRows: some View {
        let domain = spacePreview.selectedDomain
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                ForEach(domain.bots) { bot in
                    sidebarRow(icon: "🤖", title: bot.name,
                               selected: domain.selectedInterface?.bot.id == bot.id,
                               avatar: true) {
                        if let item = domain.interfaces.first(where: { $0.bot.id == bot.id }) {
                            domain.selectInterface(item.id, conversation: true)
                        } else {
                            domain.selectedInterfaceID = nil
                            domain.screen = .conversation
                        }
                    }
                    ForEach(domain.interfaces.filter { $0.bot.id == bot.id }) { item in
                        sidebarRow(icon: "↳", title: item.name,
                                   selected: domain.selectedInterfaceID == item.id, indent: 22) {
                            domain.selectInterface(item.id, conversation: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private var diaSidebar: some View {
        // 結構側欄貼齊 App 天地；內部膠囊與卡片維持各自圓角。
        WorkspaceSidebarShell {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceSidebarModePicker(modes: previewVisibleModes, selection: previewSelectedMode) { mode in
                if state.isUIOnlyPreview,
                   let tab = SpaceSetupPreviewState.Tab(rawValue: mode.rawValue) {
                    spacePreview.selectedDomain.showTab(tab)
                } else if mode != .bot { onSwitchMode?(mode) }
            }
            .padding(.top, WorkspaceSidebarMetrics.headerTopInset)

            if state.isUIOnlyPreview {
                previewBotRows
            } else {
            // 釘選區（書籤內可多選 pin）；header chevron 可收合整段。
            HStack(spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { state.pinnedSectionCollapsed.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                        Text("已釘選").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: state.pinnedSectionCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 6)
            if !state.pinnedSectionCollapsed {
            VStack(alignment: .leading, spacing: 2) {
                // 釘選項可為分類/群/單 bot/sub bot（使用者 2026-08-22：單 bot 也要有釘選）。
                ForEach(state.pinnedBotIDs, id: \.self) { pinnedID in
                    if let principal = state.fixture.principals.first(where: { $0.id == pinnedID }) {
                        pinnedPrincipalRows(principal)
                    } else if let entry = state.ownerOfSub(pinnedID) {
                        pinnedSubRow(owner: entry.owner, member: entry.member)
                    }
                }
            }
            .padding(.horizontal, 8)
            }

            Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                .padding(.horizontal, 14).padding(.vertical, 10)

            // 群組資料夾（書籤＝bot 群組；chevron 展開成員）
            // 整塊清單收臨時工的拖入：拖上來＝轉常駐（使用者 2026-08-22）。
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    // 全域拖拽（2026-08-22）：主清單照 rowOrder 迭代，每列掛
                    // drop delegate＋Dia 式插入指示線（上/下緣品牌色細線）。
                    ForEach(state.mainListEntries) { entry in
                      Group {
                      switch entry {
                      case .promoted(let bot):
                        mainRowWithDrop(id: bot.id) {
                            sidebarRow(icon: bot.emoji, title: bot.name, selected: false, avatar: true) { }
                                .onDrag { NSItemProvider(object: bot.id as NSString) }
                                .contextMenu {
                                    Button("設置") { state.openBotConfig(bot.id) }
                                    Button("移回臨時工區") { state.demoteTempBot(bot.id) }
                                    Button("封存") { state.requestArchiveTempBot(bot.id) }
                                }
                        }
                      case .principal(let principal):
                        mainRowWithDrop(id: principal.id) {
                            folderRow(principal)
                                .onDrag { NSItemProvider(object: principal.id as NSString) }
                        }
                        if state.expandedPrincipalIDs.contains(principal.id) {
                            ForEach(principal.subs) { member in
                                if member.isConsensusGroup {
                                    Button { state.selectSub(member.id, of: principal.id) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                                .frame(width: 18, height: 18)
                                            Text(member.name).font(.system(size: 13)).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.leading, 28)
                                        .frame(height: 30)
                                        .background(member.id == state.selectedSubID ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .onDrag { NSItemProvider(object: member.id as NSString) }
                                    .contextMenu {
                                        Button(state.pinnedBotIDs.contains(member.id) ? "取消釘選" : "釘選") { state.togglePin(member.id) }
                                        Button("設置") { state.openBotConfig(member.id) }
                                    }
                                    .onHover { handleRowHover($0, key: "sub:\(member.id)") }
                                    .overlay(alignment: .topTrailing) {
                                        if hoverPeekID == "sub:\(member.id)" {
                                            hoverSubFlyout(owner: principal, member: member, key: "sub:\(member.id)")
                                                .offset(x: 212)
                                                .zIndex(50)
                                        }
                                    }
                                } else {
                                    sidebarRow(icon: member.emoji, title: member.name,
                                               selected: member.id == state.selectedSubID, indent: 22, avatar: true) {
                                        state.selectSub(member.id, of: principal.id)
                                    }
                                    .onDrag { NSItemProvider(object: member.id as NSString) }
                                    .contextMenu {
                                        Button(state.pinnedBotIDs.contains(member.id) ? "取消釘選" : "釘選") { state.togglePin(member.id) }
                                        Button("設置") { state.openBotConfig(member.id) }
                                    }
                                    .onHover { handleRowHover($0, key: "sub:\(member.id)") }
                                    .overlay(alignment: .topTrailing) {
                                        if hoverPeekID == "sub:\(member.id)" {
                                            hoverSubFlyout(owner: principal, member: member, key: "sub:\(member.id)")
                                                .offset(x: 212)
                                                .zIndex(50)
                                        }
                                    }
                                }
                            }
                        }
                      }
                      }
                    }
                    Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                        .padding(.horizontal, 6).padding(.vertical, 8)
                    // 臨時工區（使用者 2026-08-22 改案）：用完就丟；拖拽上去轉常駐。
                    HStack(spacing: 6) {
                        Text("臨時工區").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text("用完就丟").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                    ForEach(state.tempBots) { temp in
                        HStack(spacing: 8) {
                            BotAvatar(emoji: temp.emoji, size: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(temp.name).font(.system(size: 12.5)).lineLimit(1)
                                Text(temp.task).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            // 封存鈕佔原拖拽鈕位置；只有 hover 到該列才顯示（避免密集）。
                            // 拖拽不需要把手——整列直接拖。
                            Button { state.requestArchiveTempBot(temp.id) } label: {
                                Image(systemName: "archivebox")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .opacity(hoveredTempBotID == temp.id ? 1 : 0)
                            .help("封存（進設定封存區，可再刪除）")
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { hoveredTempBotID = temp.id }
                            else if hoveredTempBotID == temp.id { hoveredTempBotID = nil }
                        }
                        .onDrag { NSItemProvider(object: temp.id as NSString) }
                        .contextMenu {
                            Button("轉常駐 bot") { state.promoteTempBot(temp.id) }
                            Button("設置") { state.openBotConfig(temp.id) }
                            Button("封存") { state.requestArchiveTempBot(temp.id) }
                        }
                        .help("\(temp.name)：整列直接拖到上方清單可轉常駐")
                    }
                    sidebarRow(icon: "＋", title: "create bot", selected: false) {
                        state.createBot()   // 2026-08-22：點擊要能 create（生草稿臨時工＋開設置）
                    }
                }
                .padding(.horizontal, 8)
            }
            // hover 快查 flyout 伸出側欄右緣：解除 ScrollView 裁切（v5 消失的真兇）。
            .scrollClipDisabled()
            }

            Spacer(minLength: 8)

            // Shared footer alignment: OS mark on the left, Space controls on the right.
            Divider().opacity(0.35)
                .padding(.bottom, WorkspaceSidebarMetrics.sectionSpacing)
            HStack(spacing: 10) {
                Button {
                    if state.isUIOnlyPreview { spacePreview.selectedDomain.screen = .settings }
                    else { state.openSettings() }
                } label: {
                    TatwoOSMark(size: 12)
                        .frame(height: 26)
                }
                .buttonStyle(.plain)
                .help("bot setting（展示）")
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    if state.isUIOnlyPreview {
                        ForEach(spacePreview.domains) { domain in
                            Button { spacePreview.selectDomain(domain.id) } label: {
                                Circle()
                                    .fill(domain.id == spacePreview.selectedDomainID ? Color.primary.opacity(0.75) : .primary.opacity(0.22))
                                    .frame(width: 6, height: 6)
                            }
                            .buttonStyle(.plain)
                            .help("Switch Space：\(domain.name)")
                            .accessibilityLabel("Switch Space：\(domain.name)")
                        }
                    } else if let projection = liveSpaces.state {
                        ForEach(projection.domains) { domain in
                            Button { liveSpaces.selectDomain(domain.id) } label: {
                                Circle()
                                    .fill(domain.id == projection.selectedDomainID ? Color.primary.opacity(0.75) : .primary.opacity(0.22))
                                    .frame(width: 6, height: 6)
                            }
                            .buttonStyle(.plain)
                            .help("Switch Space：\(domain.name)")
                            .accessibilityLabel("Switch Space：\(domain.name)")
                        }
                    } else {
                    if state.orderedSpaces.isEmpty {
                        Circle().fill(.primary.opacity(0.15)).frame(width: 6, height: 6)
                    } else {
                        ForEach(Array(state.orderedSpaces.enumerated()), id: \.element.id) { index, space in
                            Button { state.pagerSelect(index: index) } label: {
                                Circle()
                                    .fill(space.id == state.selectedSpace?.id ? Color.primary.opacity(0.75) : .primary.opacity(0.22))
                                    .frame(width: 6, height: 6)
                            }
                            .buttonStyle(.plain)
                            .help("\(space.name)（點擊或雙指滑動切換）")
                        }
                    }
                    Button { state.addBlankSpace() } label: {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("add space：生成新空白空間")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        }
        .frame(width: WorkspaceSidebarMetrics.width)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        // 常駐鈕在左列右上角（同 chat/cli；使用者 2026-08-23）。
        .overlay(alignment: .topTrailing) {
            if sidebarIsPinned {
                sidebarPinButton
                    .padding(.top, 6)
                    .padding(.trailing, 8)
            }
        }
        .shadow(color: .black.opacity(0.10), radius: 8, x: 3)
        // hover 離開整塊側欄（含 flyout）才排程收合。
        .onHover { hovering in
            if hovering { showSidebar() } else { scheduleSidebarHide() }
        }
        // flyout 蓋過主槽；側欄整體提到主內容之上。
        .zIndex(10)
    }

    /// 已釘選：分類/群/單 bot 列（可展開）。hover key 用 "pin:" 前綴，跟資料夾列
    /// 區分——同一 principal 兩列同時亮 flyout 的 bug 真兇（2026-08-22 修）。
    @ViewBuilder
    private func pinnedPrincipalRows(_ principal: BotFixturePrincipal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { state.togglePinnedExpansion(principal.id) } label: {
                HStack(spacing: 8) {
                    if principal.subs.isEmpty && !principal.isGroup {
                        BotAvatar(emoji: principal.emoji, size: 18,
                                  selected: principal.id == state.selectedPrincipalID && state.selectedSubID == nil)
                    } else {
                        Text("📁").font(.system(size: 12)).frame(width: 18, height: 18)
                    }
                    Text(principal.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: state.pinnedExpandedIDs.contains(principal.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .background(principal.id == state.selectedPrincipalID && state.selectedSubID == nil
                            ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("取消釘選") { state.togglePin(principal.id) }
                Button("設置") { state.openBotConfig(principal.id) }
                Button("開啟對話") { state.selectPrincipal(principal.id) }
            }
            .onHover { handleRowHover($0, key: "pin:\(principal.id)") }
            .overlay(alignment: .topTrailing) {
                if hoverPeekID == "pin:\(principal.id)" {
                    hoverFlyout(principal, key: "pin:\(principal.id)")
                        .offset(x: 212)
                        .zIndex(50)
                }
            }
            if state.pinnedExpandedIDs.contains(principal.id) {
                if principal.subs.isEmpty {
                    ForEach(principal.spaces) { space in
                        sidebarRow(icon: "・", title: space.name, selected: false, indent: 22) {
                            state.openWorkspace(principalID: principal.id, spaceID: space.id)
                        }
                    }
                } else {
                    ForEach(principal.subs) { member in
                        sidebarRow(icon: member.isConsensusGroup ? "🗂️" : member.emoji,
                                   title: member.name,
                                   selected: member.id == state.selectedSubID,
                                   indent: 22, avatar: !member.isConsensusGroup) {
                            state.selectSub(member.id, of: principal.id)
                        }
                        .contextMenu {
                            Button(state.pinnedBotIDs.contains(member.id) ? "取消釘選" : "釘選") { state.togglePin(member.id) }
                            Button("設置") { state.openBotConfig(member.id) }
                        }
                    }
                }
            }
        }
    }

    /// 已釘選的單支 sub bot 列。
    private func pinnedSubRow(owner: BotFixturePrincipal, member: BotFixtureSub) -> some View {
        sidebarRow(icon: member.isConsensusGroup ? "🗂️" : member.emoji,
                   title: member.name,
                   selected: member.id == state.selectedSubID,
                   avatar: !member.isConsensusGroup) {
            state.selectSub(member.id, of: owner.id)
        }
        .contextMenu {
            Button("取消釘選") { state.togglePin(member.id) }
            Button("設置") { state.openBotConfig(member.id) }
            Button("開啟對話") { state.selectSub(member.id, of: owner.id) }
        }
        .onHover { handleRowHover($0, key: "pinsub:\(member.id)") }
        .overlay(alignment: .topTrailing) {
            if hoverPeekID == "pinsub:\(member.id)" {
                hoverSubFlyout(owner: owner, member: member, key: "pinsub:\(member.id)")
                    .offset(x: 212)
                    .zIndex(50)
            }
        }
    }

    private func sidebarRow(icon: String, title: String, selected: Bool, indent: CGFloat = 0, prominent: Bool = false, avatar: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if avatar {
                    BotAvatar(emoji: icon, size: 18, selected: selected)
                } else {
                    Text(icon).font(.system(size: 12))
                        .frame(width: 18, height: 18)
                }
                Text(title).font(.system(size: 13, weight: prominent ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 + indent)
            .padding(.trailing, 6)
            .frame(height: 30)
            .background(selected ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.primary.opacity(selected ? 0.20 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @State private var hoverPeekID: String?
    @State private var hoverHideTask: DispatchWorkItem?
    @State private var hoverShowTask: DispatchWorkItem?
    // add space 三段流的路徑/提示詞（展示 view-local；交由 AI 帶入為未來目的）。
    @State private var addSpacePath = ""
    @State private var addSpacePrompt = ""
    // 臨時工區列 hover（封存鈕只在 hover 時顯示）。
    @State private var hoveredTempBotID: String?
    // 全域拖拽置放指示（Dia 式插入線：目標列＋上/下）。
    @State private var dropIndicatorRowID: String?
    @State private var dropIndicatorBelow = false

    /// Dia 式插入指示線：品牌色細線，清楚標出會落在目標列的上緣或下緣。
    private var dropLine: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(LiquidGlassTokens.brandAccent)
            .frame(height: 2.5)
            .shadow(color: LiquidGlassTokens.brandAccent.opacity(0.55), radius: 2)
            .padding(.horizontal, 2)
    }

    /// 主清單列包一層 drop 目標＋插入線 overlay。
    private func mainRowWithDrop<Content: View>(id: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .overlay(alignment: .top) {
                if dropIndicatorRowID == id, !dropIndicatorBelow { dropLine.offset(y: -2) }
            }
            .overlay(alignment: .bottom) {
                if dropIndicatorRowID == id, dropIndicatorBelow { dropLine.offset(y: 2) }
            }
            .onDrop(of: [.plainText], delegate: BotRowDropDelegate(
                targetID: id,
                setIndicator: { rowID, below in
                    dropIndicatorRowID = rowID
                    dropIndicatorBelow = below
                },
                perform: { draggedID, below in
                    state.moveRow(draggedID: draggedID, near: id, below: below)
                }))
    }
    // composer clone（chat 分頁同款；view-local、禁 send）。
    @State private var composerText = ""
    @State private var composerFocused = false
    @State private var composerTextHeight =
        TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight

    private func folderRow(_ principal: BotFixturePrincipal) -> some View {
        Button {
            if principal.subs.isEmpty { state.selectPrincipal(principal.id) }
            else { state.toggleDisclosure(principal.id) }
        } label: {
            HStack(spacing: 8) {
                // 使用者定案 v2：有成員的＝分類（小書籤資料夾）；獨立 bot＝頭像。
                if !principal.subs.isEmpty || principal.isGroup {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                } else {
                    BotAvatar(emoji: principal.emoji, size: 20,
                              selected: principal.id == state.selectedPrincipalID && state.selectedSubID == nil)
                }
                Text(principal.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if principal.sharedSandbox {
                    Image(systemName: "shippingbox").font(.system(size: 8)).foregroundStyle(.secondary)
                        .help("共用 sandbox・展示")
                }
                Spacer(minLength: 0)
                if !principal.subs.isEmpty {
                    Image(systemName: state.expandedPrincipalIDs.contains(principal.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(state.pinnedBotIDs.contains(principal.id) ? "取消釘選" : "釘選") { state.togglePin(principal.id) }
            Button("設置") { state.openBotConfig(principal.id) }
        }
        .onHover { handleRowHover($0, key: "row:\(principal.id)") }
        .overlay(alignment: .topTrailing) {
            if hoverPeekID == "row:\(principal.id)" {
                hoverFlyout(principal, key: "row:\(principal.id)")
                    .offset(x: 212)
                    .zIndex(50)
            }
        }
    }

    /// hover 寬限：滑鼠移進 flyout 不會消失（Dia 式）。
    private func scheduleHoverHide(for id: String) {
        hoverHideTask?.cancel()
        let task = DispatchWorkItem { if hoverPeekID == id { hoverPeekID = nil } }
        hoverHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    /// 列 hover 統一入口（2026-08-22 四修）：停留 1.5 秒才彈；離列給 0.5s 寬限
    /// 讓滑鼠平移進小卡點擊（小卡自己 hover 保活）；移到別列＝舊卡照寬限收掉。
    private func handleRowHover(_ hovering: Bool, key: String) {
        if hovering {
            if hoverPeekID == key {
                hoverHideTask?.cancel(); hoverHideTask = nil   // 回到本列 → 保持
                return
            }
            hoverShowTask?.cancel()
            let task = DispatchWorkItem { hoverPeekID = key }
            hoverShowTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
        } else {
            hoverShowTask?.cancel(); hoverShowTask = nil
            scheduleHoverHide(for: key)
        }
    }

    /// 單支 sub bot 的 hover 快查：權限＋工作狀態（展示值）。
    private func hoverSubFlyout(owner: BotFixturePrincipal, member: BotFixtureSub, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if member.isConsensusGroup {
                    Text("🗂️").font(.system(size: 13)).frame(width: 22, height: 22)
                } else {
                    BotAvatar(emoji: member.emoji, size: 22)
                }
                Text(member.name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 9))
                Text(member.permissionBrief).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            HStack(spacing: 6) {
                Circle()
                    .fill(member.workStatus.contains("運作") || member.workStatus.contains("中")
                          ? Color.green.opacity(0.75) : Color.secondary.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(member.workStatus).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.bottom, 2)
            Text("屬於：\(owner.name)")
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.bottom, 4)
        }
        .padding(8)
        .frame(width: 200, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        // 可點擊（2026-08-22 五修：平移過去要點得到）；hover 保活、離卡走寬限。
        .onHover { hovering in
            if hovering {
                hoverHideTask?.cancel(); hoverHideTask = nil
                hoverShowTask?.cancel(); hoverShowTask = nil
                hoverPeekID = key
                showSidebar()
            } else {
                scheduleHoverHide(for: key)
            }
        }
    }

    private func hoverFlyout(_ principal: BotFixturePrincipal, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // 權限＋工作狀態快查（展示值；使用者 2026-08-22 新增）。
            HStack(spacing: 8) {
                if !principal.subs.isEmpty || principal.isGroup {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                } else {
                    BotAvatar(emoji: principal.emoji, size: 22)
                }
                Text(principal.name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 9))
                Text(principal.permissionBrief).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            HStack(spacing: 6) {
                Circle()
                    .fill(principal.workStatus.contains("運作") || principal.workStatus.contains("巡檢")
                          ? Color.green.opacity(0.75) : Color.secondary.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(principal.workStatus).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.bottom, 4)
            if !principal.subs.isEmpty {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1).padding(.vertical, 3)
            }
            ForEach(principal.subs) { member in
                Button {
                    hoverPeekID = nil
                    state.selectSub(member.id, of: principal.id)
                } label: {
                    HStack(spacing: 9) {
                        if member.isConsensusGroup {
                            Text("🗂️").font(.system(size: 13)).frame(width: 22, height: 22)
                        } else {
                            BotAvatar(emoji: member.emoji, size: 22)
                        }
                        Text(member.name).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 16)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !principal.subs.isEmpty {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1).padding(.vertical, 3)
                Button { hoverPeekID = nil } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                        Text("create bot").font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 200, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.primary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        // 可點擊（2026-08-22 五修：平移過去要點得到）；hover 保活、離卡走寬限。
        .onHover { hovering in
            if hovering {
                hoverHideTask?.cancel(); hoverHideTask = nil
                hoverShowTask?.cancel(); hoverShowTask = nil
                hoverPeekID = key
                showSidebar()
            } else {
                scheduleHoverHide(for: key)
            }
        }
    }

    // MARK: - 主槽

    @ViewBuilder
    private var mainSlot: some View {
        if state.isUIOnlyPreview {
            SpaceSetupPreviewView()
        } else if liveSpaces.presentsInterface || state.contentMode == .addSpace {
            SpaceLiveSetupView()
        } else if liveSpaces.state != nil && !liveSpaces.visibleModes.contains(.bot) {
            SpaceLiveSetupView(opensSettings: true)
        } else {
        switch state.contentMode {
        case .botThread: threadView
        case .spaceCanvas: canvasView
        case .addSpace: addSpaceView
        case .settings:
            // settings 為 overlay；底層維持進入前主槽（契約 §2.1）。
            if state.previousMode == .spaceCanvas { canvasView } else { threadView }
        }
        }
    }

    private var threadView: some View {
        VStack(spacing: 0) {
            if let domain = liveSpaces.state?.selectedDomain, let botID = state.pocketBotKey {
                ForEach(domain.interfaces.filter { $0.bot.id == botID }) { item in
                    Button("\(item.name) · 搭建對話") { liveSpaces.openInterface(item.id) }
                        .buttonStyle(.plain).padding(8)
                }
            }
            legacyThreadView
        }
    }

    private var legacyThreadView: some View {
        // 2026-08-22 使用者：「點擊 bot 不會跳到他的對話」——thread 改跟著
        // selection 走（per-bot 展示對話），不再固定吃場景 thread。
        let thread = state.currentThread
        // 2026-08-22 語義修正：分類（書籤頁，如刺青 work）不是一隻 bot——
        // 選到分類且未選 sub 時，主區＝書籤頁的 bot session 清單；
        // 群（JNS 群）是群聊、獨立 bot / sub 是單聊，照常進對話。
        if let principal = state.selectedPrincipal,
           !principal.subs.isEmpty, !principal.isGroup, state.selectedSubID == nil,
           !state.isLiveLibraryBot(principal.id) {
            return AnyView(categorySessionsView(principal))
        }
        return AnyView(HStack(spacing: 0) {
        VStack(spacing: 0) {
            // LINE 式：對話對象名稱放頂部正中央；右緣＝Bot’s Bag開關（bot 的資訊卡）。
            ZStack {
                if let title = state.currentThreadTitle {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                HStack {
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.18)) { state.pocketOpen.toggle() } } label: {
                        Image(systemName: state.pocketOpen ? "backpack.fill" : "backpack")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(state.pocketOpen ? LiquidGlassTokens.brandAccent : Color.secondary)
                            .frame(width: 30, height: 30)
                            .background(.primary.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Bot’s Bag：這隻 bot 的 plugins／skillet 登記")
                    .padding(.trailing, 14)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            if thread.isEmpty {
                BotEmptyHint(symbol: "bubble.left.and.text.bubble.right", text: state.usesLiveBots ? "還沒開始對話" : "尚無對話")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(thread) { message in
                            BotMessageRow(message: message)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
                    // 排版對齊 chat 分頁：訊息欄與 composer 同一 820 欄寬置中，
                    // 不再貼滿視窗左右緣（2026-08-22 使用者）。
                    .frame(maxWidth: ChatUILayout.chatColumnMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            botComposer
        }
        if state.pocketOpen {
            botInfoCard
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        })
    }

    // MARK: - Bot’s Bag（每隻 bot 的右側資訊卡；plugins／skillet 登記＋回傳）

    @State private var pocketQuery = ""

    private var pocketSearchMatches: [BotFixtureSkill] {
        let query = pocketQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return pocketSkillCatalog.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - W90：Bot’s Bag 的真技能來源（live 不得顯示 fixture 假技能）

    /// live＝PluginsSource 掃到的本機技能；匯出／UI 預覽才用展示 fixture。
    private var pocketSkillCatalog: [BotFixtureSkill] {
        guard state.usesLiveBots else { return BotPageFixture.skilletRegistry }
        guard let model = CLISessionsTermination.model else { return [] }
        return model.availableThreadPluginEntries
            .filter { $0.kind == .skill }
            .map { .init(id: $0.id, name: $0.name, detail: $0.purpose, source: "skillet 主根") }
    }

    /// live＝這隻 bot 的 bot.json `skills`（真的已連結進 bot 目錄）；否則用展示登記。
    private var pocketRegisteredSkills: [BotFixtureSkill] {
        guard state.usesLiveBots else { return state.registeredSkills }
        guard let id = state.pocketBotKey,
              let bot = CLISessionsTermination.model?.botLibraryForBridge?.bot(id: id) else { return [] }
        let catalog = pocketSkillCatalog
        return bot.skills.map { name in
            catalog.first { $0.id == name }
                ?? .init(id: name, name: name, detail: "bot 目錄內已連結的技能", source: "bot 目錄")
        }
    }

    private func pocketIsRegistered(_ skillID: String) -> Bool {
        state.usesLiveBots
            ? pocketRegisteredSkills.contains { $0.id == skillID }
            : state.isSkillRegistered(skillID)
    }

    /// live 的登記／取消登記要寫 bot.json＋連結技能目錄，這條路還沒接；先只讀，不假裝能改。
    private var pocketRegistrationEditable: Bool { !state.usesLiveBots }

    /// 對話中搭建的 skills 目前沒有真實儲存；live 一律空清單。
    private var pocketChatBuiltSkills: [BotFixtureSkill] {
        state.usesLiveBots ? [] : BotPageFixture.chatBuiltSkills
    }

    private var pocketEmptyCatalogHint: String {
        state.usesLiveBots ? "正在掃描技能…" : "沒有可登記的技能"
    }

    @State private var infoCardPage = 0

    /// 資訊卡（chat 分頁右側資訊卡搬用；2026-08-22 使用者）：
    /// 第 1 頁＝bot 資訊卡（chat 同語言）、第 2 頁＝Bot’s Bag；雙指左右滑或點底部圓點切頁。
    private var botInfoCard: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                Group {
                    if infoCardPage == 0 {
                        botInfoPage
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else {
                        pocketContent
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(11)
            }
            // 底部圓點（space switch 同語言）：資訊卡｜Bot’s Bag。
            HStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { page in
                    Button { withAnimation(.easeOut(duration: 0.2)) { infoCardPage = page } } label: {
                        Circle()
                            .fill(page == infoCardPage ? Color.primary.opacity(0.75) : .primary.opacity(0.22))
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                    .help(page == 0 ? "資訊卡（雙指左右滑切換）" : "Bot’s Bag（雙指左右滑切換）")
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 336)
        .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }

    /// 第 1 頁：bot 資訊卡＝chat threadInfoCard 一比一克隆（2026-08-22 使用者：
    /// 「我要一模一樣」）——同段落順序/字級/chip/內距，資料換 fixture。
    @State private var botInfoPluginsExpanded = false

    private var botInfoPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            botSummarySection
            botOutputFilesCard(files: state.usesLiveBots ? state.liveOutputFiles : ["社群貼文/週五背部滿版.md", "素材庫/過程照-01.jpg"], total: state.usesLiveBots ? state.liveOutputFiles.count : 2)
            if let principal = state.selectedPrincipal, !principal.subs.isEmpty {
                botSubagentsCard(principal)
            }
            botInfoContextStrip(
                "來源",
                systemImage: "folder",
                tint: .secondary,
                items: [
                    ("Project", state.usesLiveBots ? (state.liveSource.project ?? "—") : (state.selectedPrincipal?.name ?? "—"), "folder"),
                    ("Branch", state.usesLiveBots ? "—" : (state.selectedSpace?.name ?? "—"), "arrow.branch"),
                    ("Thread", state.usesLiveBots ? (state.liveSource.thread ?? "—") : String((state.pocketBotKey ?? "—").suffix(8)), "number"),
                ])
            botPluginSummaryStrip
            botIssueListSection
        }
        .overlay(alignment: .leading) {
            if botInfoPluginsExpanded {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                LiquidGlassTokens.accentPink,
                                LiquidGlassTokens.accentViolet,
                                LiquidGlassTokens.accentBlue
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(LiquidGlassTokens.tintOpacity)
                    .frame(width: 3, height: 86)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // threadSummarySection 克隆。
    private var botSummarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Thread")
                    .font(.headline.weight(.black))
                Spacer(minLength: 0)
                Text("bot 展示")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.055), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(state.currentThreadTitle ?? "未命名 thread")
                    .font(.caption.weight(.black))
                    .lineLimit(2)
                Text(state.currentThread.last?.text ?? "bot 展示 · 尚未接入")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(ChatUILayout.quietFillOpacity), in: RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ChatUILayout.nestedRadius, style: .continuous).strokeBorder(Color.white.opacity(ChatUILayout.quietStrokeOpacity), lineWidth: 1))

            BotResumeNoteCard(botID: state.pocketBotKey, botName: state.usesLiveBots ? nil : (state.selectedSubID.flatMap { state.ownerOfSub($0)?.member.name } ?? state.selectedPrincipal?.name))
                .id(state.liveNoteRevision)   // 選的是 sub 就用 sub（隔離驗收抓到：原本永遠拿群組名）

            HStack(spacing: 6) {
                botInfoChip(systemImage: "person.2", text: state.usesLiveBots ? "bot" : "bot · 未接入")
                botInfoChip(systemImage: "puzzlepiece.extension", text: "skillet \(state.registeredSkills.count) 項")
                Spacer(minLength: 0)
            }
        }
        .help("Gen-4 展示：fixture 資料，未接入 runner。")
    }

    private func botInfoChip(systemImage: String, text: String) -> some View {
        Label(text.isEmpty ? "—" : text, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(.secondary)
            .chatGlassChip()
    }

    // threadOutputFilesCard 克隆。
    private func botOutputFilesCard(files: [String], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Label("輸出內容", systemImage: "doc.text")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("\(total)")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(total > 0 ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .chatGlassChip(isSelected: total > 0)
            }

            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(file)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(9)
        .chatGlassChip()
    }

    // threadSubagentsCard 克隆（rows＝這隻主 bot 的 subs）。
    private func botSubagentsCard(_ principal: BotFixturePrincipal) -> some View {
        let rows = principal.subs
        let hasRunning = rows.contains { $0.workStatus.contains("中") }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Label(hasRunning ? "Working" : "Agents", systemImage: "person.2.wave.2")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(rows.count)")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows.prefix(5)) { row in
                HStack(spacing: 7) {
                    BotAvatar(emoji: row.isConsensusGroup ? "🗂️" : row.emoji, size: 17)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(row.name)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text(row.role)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(row.permissionBrief)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(row.workStatus)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(row.workStatus.contains("中") ? Color.green.opacity(0.8) : Color.secondary)
                }
                .frame(height: 28)
            }
            if rows.count > 5 {
                Text("+\(rows.count - 5) more")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // threadInfoContextStrip＋threadInfoFlatMetric 克隆。
    private func botInfoContextStrip(
        _ title: String,
        systemImage: String,
        tint: Color,
        items: [(String, String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    botInfoFlatMetric(item.0, item.1, systemImage: item.2, tint: tint)
                    if index < items.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1, height: 24)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .chatGlassChip()
    }

    private func botInfoFlatMetric(_ title: String, _ value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // threadPluginSummaryStrip 克隆（展開的管理清單＝skillet 登記開關）。
    private var botPluginSummaryStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                    botInfoPluginsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Label("Plugins · 提示", systemImage: "puzzlepiece.extension")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.primary)
                    Text("\(state.registeredSkills.count)")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(state.registeredSkills.isEmpty ? Color.secondary : LiquidGlassTokens.brandAccent)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .chatGlassChip(isSelected: !state.registeredSkills.isEmpty)
                    Spacer(minLength: 0)
                    if !botInfoPluginsExpanded {
                        if state.registeredSkills.isEmpty {
                            Text("無常駐")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                ForEach(Array(state.registeredSkills.prefix(2))) { skill in
                                    Text(skill.name)
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .frame(height: 18)
                                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                                        .chatGlassChip(isSelected: true)
                                }
                                if state.registeredSkills.count > 2 {
                                    Text("+\(state.registeredSkills.count - 2)")
                                        .font(.system(size: 9, weight: .black, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: 112, alignment: .trailing)
                            .clipped()
                        }
                    }
                    Image(systemName: botInfoPluginsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.secondary)
                        .frame(width: 11)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("skillet 登記＝授權引用主根；Bot’s Bag在第 2 頁（雙指右滑）。")

            Text("Bot 展示：登記＝授權引用 skillet 主根，不複製；真正調用走白名單，需底層代接入。")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if botInfoPluginsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("管理")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { infoCardPage = 1 }
                        } label: {
                            Image(systemName: "backpack")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .help("開Bot’s Bag（第 2 頁：搜尋 skillet 登記）")
                    }
                    if pocketSkillCatalog.isEmpty {
                        Text(pocketEmptyCatalogHint)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pocketSkillCatalog.prefix(7)) { skill in
                            botPluginToggle(skill)
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(9)
        .chatGlassChip()
    }

    private func botPluginToggle(_ skill: BotFixtureSkill) -> some View {
        let enabled = pocketIsRegistered(skill.id)
        return Toggle(isOn: Binding(
            get: { pocketIsRegistered(skill.id) },
            set: { on in
                guard pocketRegistrationEditable else { return }
                on ? state.registerSkill(skill.id) : state.unregisterSkill(skill.id)
            }
        )) {
            HStack(spacing: 7) {
                Image(systemName: enabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(enabled ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.name)
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                    Text(skill.detail)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!pocketRegistrationEditable)
        .help(pocketRegistrationEditable ? "登記／取消登記" : "live 只讀：技能安裝在 bot 目錄，請到設定 › Plugin 管理")
    }

    // issueListSection 克隆（展示列）。
    private var botIssueListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                Text("Issue List")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(state.usesLiveBots ? "\(state.liveIssueTitles.count)" : "2")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Label("本串", systemImage: "bubble.left")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "plus.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(state.usesLiveBots ? state.liveIssueTitles : ["背部滿版貼文待過目（展示）", "閃預約折扣標籤確認（展示）"], id: \.self) { title in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(title)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// 第 2 頁：Bot’s Bag（plugins／skillet 登記＋回傳）。
    private var pocketContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "backpack")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bot’s Bag").font(.system(size: 13, weight: .bold))
                        Text(state.currentThreadTitle ?? "bot")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !state.usesLiveBots {
                        Text("展示").font(.system(size: 8))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.primary.opacity(0.10), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                // plugins：skillet 登記——搜尋並 enter 即登記到卡上。
                Text("PLUGINS・SKILLET 登記")
                    .font(.system(size: 9, weight: .black)).foregroundStyle(.tertiary)
                TextField(pocketRegistrationEditable ? "搜尋 skillet，Enter 登記" : "搜尋本機技能", text: $pocketQuery)
                .accessibilityLabel("搜尋 skillet")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit {
                        guard pocketRegistrationEditable else { return }
                        if let top = pocketSearchMatches.first {
                            state.registerSkill(top.id)
                            pocketQuery = ""
                        }
                    }
                if pocketSkillCatalog.isEmpty {
                    Text(pocketEmptyCatalogHint)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if !pocketSearchMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pocketSearchMatches.prefix(5)) { skill in
                            Button {
                                guard pocketRegistrationEditable else { return }
                                state.registerSkill(skill.id)
                                pocketQuery = ""
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: pocketIsRegistered(skill.id) ? "checkmark.circle.fill" : (pocketRegistrationEditable ? "plus.circle" : "circle.dashed"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(pocketIsRegistered(skill.id) ? Color.green.opacity(0.7) : Color.secondary)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(skill.name).font(.system(size: 11.5, weight: .semibold))
                                        Text(skill.detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                // 已登記：chat 輸入框 /skill 會列這些。
                Text("已登記（/skill 可用）")
                    .font(.system(size: 9, weight: .black)).foregroundStyle(.tertiary)
                if pocketRegisteredSkills.isEmpty {
                    Text(pocketRegistrationEditable
                         ? "尚未登記——上方搜尋 skillet 並 Enter"
                         : "這隻 bot 還沒有連結任何技能")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pocketRegisteredSkills) { skill in
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars").font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(skill.name).font(.system(size: 11.5, weight: .medium))
                                if skill.source != "skillet 主根" {
                                    Text(skill.source).font(.system(size: 8)).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if pocketRegistrationEditable {
                                    Button { state.unregisterSkill(skill.id) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("取消登記")
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                // 反向：對話中搭建的 skills → 回傳 skillet 主根。
                Text("對話中搭建的 SKILLS")
                    .font(.system(size: 9, weight: .black)).foregroundStyle(.tertiary)
                if pocketChatBuiltSkills.isEmpty {
                    Text("還沒有在對話中搭建的技能")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                ForEach(pocketChatBuiltSkills) { skill in
                    HStack(spacing: 6) {
                        Image(systemName: "hammer").font(.system(size: 9)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(skill.name).font(.system(size: 11.5, weight: .medium))
                            Text(skill.detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if state.returnedSkillIDs.contains(skill.id) {
                            Label("已回傳", systemImage: "checkmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.green.opacity(0.75))
                                .labelStyle(.titleAndIcon)
                        } else {
                            Button("回傳 skillet") { state.returnSkillToSkillet(skill.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(pocketRegistrationEditable
                     ? "登記＝授權引用 skillet 主根，不複製；回傳＝入庫主根（展示）"
                     : "登記＝授權引用 skillet 主根，不複製；這裡列的是本機掃到的技能與這隻 bot 已連結的技能")
                    .font(.system(size: 8.5)).foregroundStyle(.tertiary)
            }
            // W90：live 首屏沒有技能就先掃一次，讓「正在掃描技能…」有結果可換，而不是補假資料。
            .onAppear {
                guard state.usesLiveBots, pocketSkillCatalog.isEmpty else { return }
                _ = CLISessionsTermination.model?.reloadPluginRegistry(ifOlderThan: 30)
            }
    }

    /// 書籤頁（分類）：bot session 清單——LINE 聊天清單式，點 session 進該 bot 對話。
    private func categorySessionsView(_ principal: BotFixturePrincipal) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(principal.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("書籤頁・bot sessions")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(principal.subs) { member in
                        Button { state.selectSub(member.id, of: principal.id) } label: {
                            HStack(spacing: 12) {
                                if member.isConsensusGroup {
                                    Text("🗂️").font(.system(size: 18))
                                        .frame(width: 36, height: 36)
                                        .background(Circle().fill(.primary.opacity(0.10)))
                                } else {
                                    BotAvatar(emoji: member.emoji, size: 36)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(member.name).font(.system(size: 13.5, weight: .semibold))
                                        if member.isConsensusGroup {
                                            Text("群").font(.system(size: 8, weight: .semibold))
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(.primary.opacity(0.08), in: Capsule())
                                        }
                                    }
                                    Text("（展示）\(member.role)")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: ChatUILayout.chatColumnMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            botComposer
        }
    }

    // composer＝chat 分頁原版代碼搬用（使用者 2026-08-22：造型不像→搬代碼）：
    // 同 ChatComposerTextView＋同 metrics＋同 liquidGlassPanelSurface＋同梯形狀態抽屜。
    // 差異只有：送出/選單為展示 no-op（禁 send／禁 runner）。
    private var botComposer: some View {
        let minH = TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight
        let maxH = TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight
        let effective = min(maxH, max(minH, composerTextHeight))
        return VStack(alignment: .leading, spacing: 8) {
            // 「/skill」：列出Bot’s Bag已登記的 skills（chat 斜線列同語言）。
            if composerText.hasPrefix("/skill") || composerText == "/" {
                botSkillRail
            }
            VStack(alignment: .leading, spacing: 0) {
                ChatComposerTextView(
                    text: $composerText,
                    contentHeight: $composerTextHeight,
                    isFocused: composerFocused,
                    placeholder: state.usesLiveBots ? "傳訊息給 bot" : "要求 bot 後續分工（展示）",
                    isMonospaced: false,
                    minimumHeight: minH,
                    maximumHeight: maxH,
                    onSubmit: { if state.sendComposer(composerText) { composerText = "" } },
                    onFocusChange: { composerFocused = $0 },
                    accessibilityTextLabel: "Bot message")   // AX 樹裡的 AXTextArea 是 bridge 的 NSTextView，label 要從這裡給
                    .accessibilityLabel("Bot message")
                    .accessibilityIdentifier("bot-composer")
                    .frame(height: effective)
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
                    .padding(.bottom, 8)
                botComposerToolbar
                    .padding(.horizontal, 11)
                    .padding(.bottom, 8)
            }
            .frame(minHeight: TatwoChatTranscriptVisualMetrics.windowComposerMinimumHeight)
            .liquidGlassPanelSurface(cornerRadius: LiquidGlassTokens.radiusPrimary)

            botComposerStatusBar
                .zIndex(-1)
                .padding(.top, -13)
        }
        .frame(maxWidth: ChatUILayout.chatColumnMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        // 對齊 chat 分頁輸入框底距（chat＝18pt 外框 padding；bot 外框已抵銷，這裡補同量）。
        .padding(.bottom, 18)
    }

    /// /skill 供應列：Bot’s Bag已登記 skills 的 chip（點擊帶入輸入框；展示）。
    private var botSkillRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Label("skills", systemImage: "wand.and.stars")
                    .font(.caption2.weight(.black)).foregroundStyle(.secondary)
                if state.registeredSkills.isEmpty {
                    Text("Bot’s Bag還沒登記 skills——開右上「Bot’s Bag」搜尋 skillet 登記")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(state.registeredSkills) { skill in
                        Button {
                            composerText = "/skill \(skill.name) "
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("/skill \(skill.name)")
                                        .font(.system(size: 11.5, weight: .black, design: .rounded))
                                        .foregroundStyle(.primary)
                                    Text(skill.detail)
                                        .font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(
                                LiquidGlassTokens.brandAccent.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(LiquidGlassTokens.brandAccent.opacity(0.18), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("插入 /skill \(skill.name)（展示）")
                    }
                }
            }
            .padding(.horizontal, 9)
        }
        .frame(height: 34)
    }

    private var botComposerToolbar: some View {
        HStack(spacing: 9) {
            Menu {
                Button { } label: { Label("貼上剪貼簿圖片（展示）", systemImage: "doc.on.clipboard") }
                    .disabled(true)
                Button { } label: { Label("附加檔案…（展示）", systemImage: "paperclip") }
                    .disabled(true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("加入內容（展示）")

            Menu {
                if state.usesLiveBots {
                    Text("檔位來自這隻 bot 的 bot.json（permissions.approval），這裡只顯示不可改")
                } else {
                    Button { } label: { Label("代我核准", systemImage: "checkmark.circle.fill") }
                    Divider()
                    Text("展示模式・權限未生效")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.bubble").font(.system(size: 11, weight: .bold))
                    Text(state.usesLiveBots ? (state.liveApprovalLabel ?? "—") : "代我核准").font(.caption2.weight(.black)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .black)).opacity(0.82)
                }
                .foregroundStyle(Color.orange.opacity(0.86))
                .padding(.horizontal, 7)
                .frame(height: 24)
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .controlSize(.small)
            .help("展示模式・權限未生效")

            Spacer(minLength: 14)

            Text(state.usesLiveBots ? "bot" : "未接入・未派工")
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .chatGlassChip()

            Button { if state.sendComposer(composerText) { composerText = "" } } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .disabled(!state.usesLiveBots || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.plain)
            .background {
                Circle().fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity))
            }
            .overlay {
                Circle().strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity))
            }
            .help("展示模式・未接入")
        }
        .frame(height: 28)
    }

    private var botComposerStatusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.secondary.opacity(0.72)).frame(width: 6, height: 6)
            Text(state.usesLiveBots ? state.liveComposerStatus : "Gen-4 展示・bot 未接入")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background {
            if TatwoActivePalette.current.usesGlass {
                BotRoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        BotRoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                            .fill(LiquidGlassTokens.ultraworkGradient)
                            .opacity(LiquidGlassTokens.glassIdentityFillOpacity * 1.6))
                    .overlay(
                        BotRoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                            .fill(Color.white.opacity(0.12)))
            } else {
                BotRoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .fill(Color.primary.opacity(0.075))
            }
        }
        .overlay {
            if TatwoActivePalette.current.usesGlass {
                BotRoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .stroke(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
            } else {
                BotRoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - space 視圖（Dia 開分頁式：內容＝使用者系統示意；右上 bot 鈕展開抽屜）

    @ViewBuilder
    private var canvasView: some View {
        let density = state.selectedSpace?.density ?? .compact
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // 頂列：space 名＋右上 bot 鈕（對標 Dia 右上 Chat）
                HStack {
                    Text(state.openBookmark?.name ?? state.selectedSpace?.name ?? "space")
                        .font(.system(size: 13, weight: .semibold))
                    if state.openBookmark != nil {
                        Text("使用者系統・書籤")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(density.label)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
                Group {
                    if state.selectedSpace?.id.hasPrefix("fixture-space-blank") == true {
                        // 底列＋生成的新空白空間：等外標籤 add 搭建內容。
                        BotEmptyHint(symbol: "square.dashed",
                                     text: "空白空間・用右側外標籤「＋」搭建工作平台")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch density {
                        case .full: BotSpaceFullCanvas(space: state.selectedSpace)
                        case .compact: BotSpaceCompactCanvas(space: state.selectedSpace)
                        case .status: BotSpaceStatusBar(space: state.selectedSpace)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            EmptyView()
        }
    }

    // MARK: - add space 三段流（chooseDensity → staticPreview → completionMock）

    private var addSpaceView: some View {
        VStack(spacing: 24) {
            Text("搭建工作平台")
                .font(.title2.weight(.semibold))
            Text(state.usesLiveBots ? "使用者工作平台搭建：為當前 space 建立一個領域（按「生效」會真的建立）" : "使用者工作平台搭建：為當前 space 加一個書籤工作空間（展示流程，不會建立任何東西）")
                .font(.callout).foregroundStyle(.secondary)
            switch state.addSpaceStep {
            case .chooseDensity:
                HStack(spacing: 16) {
                    ForEach(BotFixtureDensity.allCases) { density in
                        Button { state.chooseDensity(density) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: density.symbol).font(.system(size: 28))
                                Text(density.label).font(.headline)
                                Text(density.caption).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 150, height: 130)
                            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("取消") { state.addSpaceCancel() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            case .staticPreview:
                // 2026-08-22 使用者：加路徑筐＋提示詞筐，按「生效」交由 AI 帶入
                //（例：貼外接硬碟的 open design 路徑，由 agent 搭建進來）。展示 no-op。
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: state.addSpaceDensity?.symbol ?? "questionmark")
                            .font(.system(size: 22)).foregroundStyle(.secondary)
                        Text("靜態預覽：\(state.addSpaceDensity?.label ?? "")")
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("資料路徑").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("貼上路徑，例如 /Volumes/外接硬碟/open design", text: $addSpacePath)
                        .accessibilityLabel("工作空間路徑")
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("提示詞").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("告訴 agent 要怎麼搭建這個工作空間", text: $addSpacePrompt)
                        .accessibilityLabel("工作空間搭建指示")
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(state.usesLiveBots ? "按「生效」後以這個路徑最後一段為名建立領域" : "按「生效」後交由 AI 帶入資料（展示，不會實際執行）")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(18)
                .frame(width: 420)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
                HStack {
                    Button("返回") { state.addSpaceBack() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer().frame(width: 24)
                    Button("生效") {
                        state.addSpaceComplete(name: SpaceCreation.nameFromPath(addSpacePath) ?? addSpacePath,
                                               density: state.addSpaceDensity?.rawValue)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(addSpacePath.isEmpty)
                        .help(addSpacePath.isEmpty ? "先貼上資料路徑" : "交由 agent 搭建（展示）")
                }
            case .completionMock:
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    // live：真的建立領域（W89）；fixture：維持展示文案。
                    Text(state.addSpaceCreatedName.map(SpaceCreation.successText(name:))
                         ?? "已交由 agent 搭建（展示）")
                        .font(.headline)
                    if let failure = state.addSpaceFailure {
                        Text(failure).font(.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    if !addSpacePath.isEmpty {
                        Text(addSpacePath)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 340)
                    }
                    if state.addSpaceCreatedName == nil && state.addSpaceFailure == nil {
                        Text("agent 會把資料帶入這個工作空間——本代不落盤、不實際執行")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 420, height: 220)
                .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
                HStack {
                    Button("返回") { state.addSpaceBack() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer().frame(width: 24)
                    Button("關閉") { state.addSpaceCancel() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - 右緣書側標籤（外掛窗框、書壓書重疊；手繪 IMG_8547）
    // 2026-08-22 改案：書籤只在對應 space 出現（每 space 自己的收納）；
    // 最下面始終保持 add；圓點運作時白色呼吸光、雙擊跳確認全關。

    private var workspaceTabsRail: some View {
        VStack(spacing: -10) {
            Spacer().frame(height: 44)
            ForEach(Array(state.currentBookmarks.enumerated()), id: \.element.id) { index, bookmark in
                bookmarkTab(bookmark)
                    .zIndex(Double(100 - index))
            }
            addBookmarkTab
                .zIndex(0)
            Spacer()
        }
        .frame(width: 30)
    }

    private func bookmarkTab(_ bookmark: BotFixtureBookmark) -> some View {
        let isOpen = state.openBookmarkID == bookmark.id
        let stopped = state.stoppedBookmarkIDs.contains(bookmark.id)
        let shape = BotSideTabTrapezoid(attachedLeft: false)
        return VStack(spacing: 4) {
            Text(String(bookmark.name.prefix(4)))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BotSideTabTheme.text)
                .frame(width: 15)
                .multilineTextAlignment(.center)
            // 小圓點：綠呼吸=運行中、黃=斷線/錯誤、暗=未開啟；雙擊=確認關閉。
            BotBreathingDot(health: stopped ? .off : bookmark.health)
                .contentShape(Rectangle())
                .gesture(ExclusiveGesture(
                    TapGesture(count: 2).onEnded { state.requestCloseBookmark(bookmark.id) },
                    TapGesture().onEnded { state.toggleBookmark(bookmark.id) }))
        }
        .padding(.vertical, 10)
        .frame(width: 30)
        .background(
            BotSideTabTheme.fill(shape)
                .shadow(color: .black.opacity(0.20), radius: 3, x: -1.5, y: 1.5))
        .overlay(shape.stroke(BotSideTabTheme.stroke(highlighted: isOpen), lineWidth: isOpen ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { state.toggleBookmark(bookmark.id) }
        .help(stopped
              ? "\(bookmark.name)（未開啟・展示）"
              : "\(bookmark.name)（點擊\(isOpen ? "屏蔽" : "展開")工作空間；圓點雙擊全關）")
    }

    /// 書籤最下面始終保持 add＝使用者工作平台搭建入口（點擊開三段流）。
    private var addBookmarkTab: some View {
        let shape = BotSideTabTrapezoid(attachedLeft: false)
        return VStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(BotSideTabTheme.text.opacity(0.85))
        }
        .padding(.vertical, 12)
        .frame(width: 30)
        .background(
            BotSideTabTheme.fill(shape, dimmed: true)
                .shadow(color: .black.opacity(0.14), radius: 3, x: -1.5, y: 1.5))
        .overlay(shape.stroke(BotSideTabTheme.stroke(highlighted: false), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { state.openAddSpace() }
        .help("add 書籤：搭建使用者工作平台（展示）")
    }

    // MARK: - settings overlay（2026-08-22 重設計：Discord 開發者後台式）
    // 左＝bot 導覽（含封存區）；右＝頭貼可換＋權限開關＋封存管理（真刪的第二道防護）。

    private var settingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()
                .onTapGesture { state.closeSettings() }
            HStack(spacing: 0) {
                settingsNavColumn.frame(width: 210)
                Divider().opacity(0.4)
                settingsDetailColumn.frame(minWidth: 430, maxWidth: .infinity)
            }
            .frame(maxWidth: 780, maxHeight: 560)
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
            // 2026-08-22 使用者：打杈鈕取消——點空白處退出（scrim 已可點關）；Esc 保留（隱形鍵）。
            .overlay(alignment: .topTrailing) {
                Button(action: { state.closeSettings() }) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .padding(40)
        }
        // 封存區真刪二次確認。
        .alert(
            "永久刪除這隻封存 bot？",
            isPresented: Binding(
                get: { state.confirmDeleteArchivedID != nil },
                set: { if !$0 { state.cancelDeleteArchived() } })
        ) {
            Button("永久刪除", role: .destructive) { state.confirmDeleteArchived() }
            Button("取消", role: .cancel) { state.cancelDeleteArchived() }
        } message: {
            Text("這是第二道防護後的真移除（展示，不影響真實系統）。")
        }
    }

    /// 左欄（2026-08-22 二版）：只放書籤（分類/群）與獨立 bot，留空給未來；
    /// 點書籤 → 右側展開成員清單，右側點 bot 才進個別編輯。
    private var settingsNavColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("書籤").font(.system(size: 10, weight: .black)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.bottom, 2)
                    ForEach(state.fixture.principals.filter { !$0.subs.isEmpty || $0.isGroup }) { category in
                        Button {
                            state.settingsCategoryID = category.id
                            state.settingsSelection = nil
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                Text(state.displayName(for: category.id, fallback: category.name))
                                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(category.subs.count)")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                            .background(category.id == state.settingsCategoryID
                                        ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text("BOT").font(.system(size: 10, weight: .black)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 2)
                    ForEach(state.fixture.principals.filter { $0.subs.isEmpty && !$0.isGroup }) { bot in
                        settingsNavBotRow(id: bot.id, emoji: bot.emoji, name: bot.name)
                    }
                    ForEach(state.promotedTempBots + state.tempBots) { temp in
                        settingsNavBotRow(id: temp.id, emoji: temp.emoji, name: temp.name)
                    }
                    if !state.archivedTempBots.isEmpty {
                        Text("封存區").font(.system(size: 10, weight: .black)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 2)
                        ForEach(state.archivedTempBots) { archived in
                            settingsNavBotRow(id: archived.id, emoji: archived.emoji,
                                              name: archived.name, archived: true)
                        }
                    }
                    // 留空給未來（使用者 2026-08-22）。
                    Text("未來擴充").font(.system(size: 10, weight: .black)).foregroundStyle(.quaternary)
                        .padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 2)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(height: 30)
                        .overlay(Text("預留").font(.system(size: 10)).foregroundStyle(.quaternary))
                }
            }
        }
        .padding(14)
    }

    private func settingsNavBotRow(id: String, emoji: String, name: String, archived: Bool = false) -> some View {
        Button {
            state.settingsCategoryID = nil
            state.settingsFocus(id)
        } label: {
            HStack(spacing: 8) {
                BotAvatar(emoji: state.displayEmoji(for: id, fallback: emoji), size: 22,
                          selected: id == state.settingsSelection, subdued: archived)
                Text(state.displayName(for: id, fallback: name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(archived ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if archived {
                    Image(systemName: "archivebox").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(id == state.settingsSelection && state.settingsCategoryID == nil
                        ? AnyShapeStyle(.background.opacity(0.95)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let avatarChoices = ["🤖", "🪡", "🌐", "🎨", "📒", "🖨️", "🧾", "📝", "🔖", "🈺", "📊", "🦾", "🧠", "🛰️"]

    /// 目前設置焦點的顯示資料（principal／sub／臨時／封存都可）。
    private var settingsFocusInfo: (id: String, name: String, emoji: String, subtitle: String, archived: Bool)? {
        guard let id = state.settingsSelection else { return nil }
        if let p = state.fixture.principals.first(where: { $0.id == id }) {
            return (id, state.displayName(for: id, fallback: p.name),
                    state.displayEmoji(for: id, fallback: p.emoji),
                    p.isGroup ? "bot 群・成員 \(p.groupMembers.count)" : "獨立 bot", false)
        }
        for p in state.fixture.principals {
            if let s = p.subs.first(where: { $0.id == id }) {
                return (id, state.displayName(for: id, fallback: s.name),
                        state.displayEmoji(for: id, fallback: s.isConsensusGroup ? "🗂️" : s.emoji),
                        "\(p.name) 的 sub・\(s.role)", false)
            }
        }
        if let t = (state.tempBots + state.promotedTempBots).first(where: { $0.id == id }) {
            return (id, state.displayName(for: id, fallback: t.name),
                    state.displayEmoji(for: id, fallback: t.emoji), "臨時工區・\(t.task)", false)
        }
        if let a = state.archivedTempBots.first(where: { $0.id == id }) {
            return (id, state.displayName(for: id, fallback: a.name),
                    state.displayEmoji(for: id, fallback: a.emoji), "封存區・\(a.task)", true)
        }
        return nil
    }

    /// 右欄：書籤成員清單（點 bot 進個別編輯）或個別編輯頁。
    private var settingsDetailColumn: some View {
        Group {
            if let info = settingsFocusInfo {
                settingsEditView(info)
            } else if let catID = state.settingsCategoryID,
                      let category = state.fixture.principals.first(where: { $0.id == catID }) {
                settingsCategoryMembersView(category)
            } else {
                BotEmptyHint(symbol: "gearshape", text: "左側選書籤或 bot")
            }
        }
    }

    /// 右欄：書籤展開＝成員 bot 清單（點了才進各別編輯）。
    private func settingsCategoryMembersView(_ category: BotFixturePrincipal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.displayName(for: category.id, fallback: category.name))
                        .font(.system(size: 15, weight: .bold))
                    Text(category.isGroup ? "bot 群・點成員個別編輯" : "書籤・點 bot 個別編輯")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(category.subs) { member in
                        Button { state.settingsFocus(member.id) } label: {
                            HStack(spacing: 10) {
                                BotAvatar(
                                    emoji: state.displayEmoji(for: member.id,
                                                              fallback: member.isConsensusGroup ? "🗂️" : member.emoji),
                                    size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(state.displayName(for: member.id, fallback: member.name))
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(member.role).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
    }

    /// 個別編輯：上一隻/下一隻＋改名＋換頭貼＋權限開關（或封存管理）。
    private func settingsEditView(_ info: (id: String, name: String, emoji: String, subtitle: String, archived: Bool)) -> some View {
        let siblings = state.settingsEditSiblings
        let index = siblings.firstIndex(of: info.id)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                // 導覽列：返回書籤清單＋上一隻/下一隻。
                HStack(spacing: 8) {
                    if state.settingsCategoryID != nil {
                        Button {
                            state.settingsSelection = nil
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                                Text("成員清單").font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).frame(height: 24)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .chatGlassChip()
                    }
                    Spacer()
                    if let index {
                        Text("\(index + 1)／\(siblings.count)")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Button { state.settingsEditStep(-1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index == nil || index == 0)
                    .help("上一隻 bot")
                    Button { state.settingsEditStep(1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index == nil || index == siblings.count - 1)
                    .help("下一隻 bot")
                }
                HStack(spacing: 14) {
                    BotAvatar(emoji: info.emoji, size: 56, selected: true)
                    VStack(alignment: .leading, spacing: 5) {
                        // 改 bot 名稱（展示 view-local）。
                        TextField("bot 名稱", text: Binding(
                            get: { state.displayName(for: info.id, fallback: info.name) },
                            set: { state.nameOverrides[info.id] = $0 }))
                            .accessibilityLabel("Bot 名稱")
                            .textFieldStyle(.plain)
                            .font(.system(size: 17, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .frame(maxWidth: 220)
                        Text(info.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        Menu {
                            ForEach(Self.avatarChoices, id: \.self) { choice in
                                Button("\(choice)　選用") { state.avatarOverrides[info.id] = choice }
                            }
                            Divider()
                            Button("還原預設") { state.avatarOverrides[info.id] = nil }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "photo.circle").font(.system(size: 11, weight: .bold))
                                Text("更換頭貼").font(.caption2.weight(.black))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .contentShape(Capsule())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .chatGlassChip()
                    }
                    Spacer()
                    Text("展示・未生效")
                        .font(.system(size: 9))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.primary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if info.archived {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("封存管理").font(.system(size: 11, weight: .bold)).foregroundStyle(.primary.opacity(0.65))
                        Text("此 bot 已封存（從臨時工區移入）。要真移除請按下方刪除，會再確認一次。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("永久刪除") { state.requestDeleteArchived(info.id) }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            Button("還原到臨時工區") { state.restoreArchivedTempBot(info.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("權限").font(.system(size: 11, weight: .bold)).foregroundStyle(.primary.opacity(0.65))
                        ForEach(state.fixture.permissionRows) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.label).font(.system(size: 12.5, weight: .medium))
                                    Text("\(row.group)・\(row.value)")
                                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if row.inherited {
                                    Text("inherited")
                                        .font(.system(size: 8))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.primary.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                Toggle("", isOn: Binding(
                                    get: { state.isPermissionEnabled(botID: info.id, permissionID: row.id) },
                                    set: { _ in state.togglePermission(botID: info.id, permissionID: row.id) }))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                    .labelsHidden()
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var watermark: some View {
        Text(state.usesLiveBots ? "" : BotPageFixture.watermark)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(10)
    }
}

// MARK: - chat composer 抽屜梯形（ChatPage.RoundedInvertedTrapezoid 同款搬用；private 無法跨檔引用）

private struct BotRoundedInvertedTrapezoid: Shape {
    var sideSlope: CGFloat = 14
    var cornerRadius: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        let pts = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX - sideSlope, y: rect.maxY),
            CGPoint(x: rect.minX + sideSlope, y: rect.maxY),
        ]
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = Swift.max(0.0001, (dx * dx + dy * dy).squareRoot())
            return CGPoint(x: dx / len, y: dy / len)
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x, dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var path = Path()
        let n = pts.count
        for i in 0..<n {
            let curr = pts[i]
            let prev = pts[(i - 1 + n) % n]
            let next = pts[(i + 1) % n]
            let r = (i <= 1) ? 0 : Swift.min(cornerRadius, dist(prev, curr) / 2, dist(next, curr) / 2)
            let toPrev = unit(curr, prev), toNext = unit(curr, next)
            let p1 = CGPoint(x: curr.x + toPrev.x * r, y: curr.y + toPrev.y * r)
            let p2 = CGPoint(x: curr.x + toNext.x * r, y: curr.y + toNext.y * r)
            if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
            if r > 0 { path.addQuadCurve(to: p2, control: curr) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 書側標籤梯形（chat composer 資訊欄同語言：附著邊平直、外緣斜切＋圓角）

struct BotSideTabTrapezoid: Shape {
    /// true＝附著在左（外掛面板：標籤往右伸出窗外）；false＝附著在右（窗內 export 版）。
    var attachedLeft: Bool = true
    var sideSlope: CGFloat = 5
    var cornerRadius: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let pts: [CGPoint]
        if attachedLeft {
            pts = [
                CGPoint(x: rect.minX, y: rect.minY),                 // 附著上（切平）
                CGPoint(x: rect.maxX, y: rect.minY + sideSlope),     // 外緣上（圓）
                CGPoint(x: rect.maxX, y: rect.maxY - sideSlope),     // 外緣下（圓）
                CGPoint(x: rect.minX, y: rect.maxY),                 // 附著下（切平）
            ]
        } else {
            pts = [
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.minY + sideSlope),
                CGPoint(x: rect.minX, y: rect.maxY - sideSlope),
                CGPoint(x: rect.maxX, y: rect.maxY),
            ]
        }
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            let dx = to.x - from.x, dy = to.y - from.y
            let len = Swift.max(0.0001, (dx * dx + dy * dy).squareRoot())
            return CGPoint(x: dx / len, y: dy / len)
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x, dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }
        var path = Path()
        let n = pts.count
        for i in 0..<n {
            let curr = pts[i]
            let prev = pts[(i - 1 + n) % n]
            let next = pts[(i + 1) % n]
            // 只圓外緣兩角（index 1/2）；附著邊保持直角貼窗框。
            let r = (i == 1 || i == 2) ? Swift.min(cornerRadius, dist(prev, curr) / 2, dist(next, curr) / 2) : 0
            let toPrev = unit(curr, prev), toNext = unit(curr, next)
            let p1 = CGPoint(x: curr.x + toPrev.x * r, y: curr.y + toPrev.y * r)
            let p2 = CGPoint(x: curr.x + toNext.x * r, y: curr.y + toNext.y * r)
            if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
            if r > 0 { path.addQuadCurve(to: p2, control: curr) }
        }
        path.closeSubpath()
        return path
    }
}

/// 標籤主題填色（2026-08-22 三修定案）：
/// fable5＝栗皮茶 KURIKAWACHA RGB(106,64,40)＋白字（使用者色卡 IMG_8550）；
/// 極光＝霜面玻璃＋ultraworkGradient 紫藍＋白紗、白字。
@MainActor
enum BotSideTabTheme {
    static var usesGlass: Bool { TatwoActivePalette.current.usesGlass }
    /// 栗皮茶（使用者指定色卡：C58 M74 Y72 K30 / R106 G64 B40）。
    static let kurikawacha = Color(red: 106.0 / 255.0, green: 64.0 / 255.0, blue: 40.0 / 255.0)

    static var text: Color { .white }

    static func stroke(highlighted: Bool) -> Color {
        Color.white.opacity(highlighted ? 0.8 : 0.35)
    }

    @ViewBuilder
    static func fill(_ shape: BotSideTabTrapezoid, dimmed: Bool = false) -> some View {
        if usesGlass {
            shape.fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(LiquidGlassTokens.ultraworkGradient)
                        .opacity(LiquidGlassTokens.glassIdentityFillOpacity * 1.6))
                .overlay(shape.fill(Color.white.opacity(0.12)))
                .opacity(dimmed ? 0.85 : 1)
        } else {
            shape.fill(kurikawacha.opacity(dimmed ? 0.88 : 1))
        }
    }
}

// MARK: - 雙指滑動觸控板 switch space（scrollWheel 水平手勢；不吃事件、只觸發 pager）

fileprivate final class BotSwipeMonitorView: NSView {
    var onSwipe: ((Int) -> Void)?
    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var fired = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // 離窗即拆 monitor（deinit 受 actor 隔離限制，不在那裡拆）。
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        if event.phase == .began { accumulatedX = 0; fired = false }
        // 只吃「明顯水平」的雙指滑動；垂直捲動照常給清單。
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        accumulatedX += event.scrollingDeltaX
        if !fired, abs(accumulatedX) > 90 {
            fired = true
            // 觸控板左滑（deltaX 負）＝下一個 space；右滑＝上一個。
            onSwipe?(accumulatedX < 0 ? 1 : -1)
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            accumulatedX = 0
        }
    }
}

/// 全域拖拽 drop delegate：進入/移動時回報插入位置（上/下半判定），
/// 離開清指示，落下執行 moveRow（Dia 瀏覽器拖分頁的置放語言）。
fileprivate struct BotRowDropDelegate: DropDelegate {
    let targetID: String
    let setIndicator: (String?, Bool) -> Void
    let perform: (String, Bool) -> Void
    private let rowMidY: CGFloat = 15

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        setIndicator(targetID, info.location.y > rowMidY)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setIndicator(targetID, info.location.y > rowMidY)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setIndicator(nil, false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let below = info.location.y > rowMidY
        setIndicator(nil, false)
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async { perform(id, below) }
        }
        return true
    }
}

fileprivate struct BotSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> BotSwipeMonitorView {
        let view = BotSwipeMonitorView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: BotSwipeMonitorView, context: Context) {
        nsView.onSwipe = onSwipe
    }
}

// MARK: - 外筐之外的書側標籤（child window：貼在主窗右緣外側、跟著主窗移動）
// 一般視圖畫不出視窗邊界；借 NSWindow.addChildWindow 掛一片無框透明面板在
// 窗框右外側，內容仍吃同一個 BotPageState（純展示、零功能）。

@MainActor
final class BotEdgeTabsPanelController {
    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var resizeObserver: NSObjectProtocol?

    func attach(to window: NSWindow, state: BotPageState) {
        attach(to: window, content: BotEdgeTabsPanelView(state: state))
    }

    /// Reuse the existing outside-window geometry for the UI-only Space flow.
    func attach<Content: View>(to window: NSWindow, content: Content) {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: content)
        // 2026-08-22 使用者：標籤要在 app 後面——ordered .below，附著邊塞進
        // app 底下，露出的只有外緣，不佔 app 的邊。
        window.addChildWindow(panel, ordered: .below)
        self.panel = panel
        self.parentWindow = window
        reposition()
        // A rail mounted after the main window is already visible (e.g. switching
        // from Chat to Bot) must be explicitly ordered in. Keep it behind the
        // parent so the original 10-point underlap remains hidden.
        if window.isVisible { panel.order(.below, relativeTo: window.windowNumber) }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    private func reposition() {
        guard let panel, let parent = parentWindow else { return }
        let frame = parent.frame
        // 面板壓在 app 後面：往內塞 10pt（被 app 蓋住），只露外緣標籤。
        panel.setFrame(
            NSRect(x: frame.maxX - 10, y: frame.minY, width: 46, height: frame.height),
            display: true)
    }

    func detach() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        parentWindow = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
    }
}

final class BotEdgeTabsTrackerView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

fileprivate struct BotEdgeTabsMounter: NSViewRepresentable {
    let state: BotPageState

    @MainActor
    final class Coordinator {
        let controller = BotEdgeTabsPanelController()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BotEdgeTabsTrackerView {
        let view = BotEdgeTabsTrackerView()
        let controller = context.coordinator.controller
        let state = state
        view.onWindowChange = { window in
            if let window { controller.attach(to: window, state: state) }
            else { controller.detach() }
        }
        return view
    }

    func updateNSView(_ nsView: BotEdgeTabsTrackerView, context: Context) { }

    static func dismantleNSView(_ nsView: BotEdgeTabsTrackerView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }
}

/// 呼吸圓點（2026-08-22 使用者四修定案）：
/// 語義：綠＝運行中（呼吸）、黃＝斷線/錯誤（恆亮）、暗＝未開啟。
/// 位移根治：改 TimelineView 純繪製 pulse——完全不建立 SwiftUI 動畫交易，
/// 幾何全寫死，任何佈局動畫都帶不動它。
fileprivate struct BotBreathingDot: View {
    let health: BotBookmarkHealth

    private var coreColor: Color {
        switch health {
        case .running: Color.green.opacity(0.9)
        case .error: Color.yellow.opacity(0.95)
        case .off: Color.secondary.opacity(0.45)
        }
    }

    var body: some View {
        ZStack {
            if health == .running {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.5 + 0.5 * sin(t * (2 * .pi / 1.8))
                    Circle()
                        .fill(Color.green)
                        .frame(width: 9, height: 9)
                        .blur(radius: 2.5)
                        .opacity(0.15 + 0.7 * pulse)
                }
                .frame(width: 12, height: 12)
            } else if health == .error {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 9, height: 9)
                    .blur(radius: 2.5)
                    .opacity(0.55)
            }
            Circle()
                .fill(coreColor)
                .frame(width: 5, height: 5)
        }
        .frame(width: 12, height: 12)
    }
}

/// 外掛面板內容：鏡像版書側標籤（右圓角朝外、貼左緣咬住窗框）。
/// 2026-08-22 使用者：平常收小、hover 變大；所有標籤尺寸一致（固定高）。
fileprivate struct BotEdgeTabsPanelView: View {
    @ObservedObject var state: BotPageState
    @State private var hoveredTabID: String?

    private let tabHeight: CGFloat = 78

    private var tabShape: BotSideTabTrapezoid { BotSideTabTrapezoid(attachedLeft: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: -8) {
            Spacer().frame(height: 44)
            ForEach(Array(state.currentBookmarks.enumerated()), id: \.element.id) { index, bookmark in
                tab(bookmark)
                    .zIndex(hoveredTabID == bookmark.id ? 200 : Double(100 - index))
            }
            addTab
                .zIndex(0)
            Spacer()
        }
        // 面板左 10pt 藏在 app 後面；標籤內容右移 8pt 保持露出可讀。
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.14), value: hoveredTabID)
    }

    private func tab(_ bookmark: BotFixtureBookmark) -> some View {
        let isOpen = state.openBookmarkID == bookmark.id
        let stopped = state.stoppedBookmarkIDs.contains(bookmark.id)
        let health: BotBookmarkHealth = stopped ? .off : bookmark.health
        let hovered = hoveredTabID == bookmark.id
        return VStack(spacing: 4) {
            Text(String(bookmark.name.prefix(4)))
                .font(.system(size: hovered ? 10.5 : 9, weight: .semibold))
                .foregroundStyle(BotSideTabTheme.text)
                .frame(width: 15)
                .frame(maxHeight: .infinity)
                .multilineTextAlignment(.center)
            BotBreathingDot(health: health)
                .contentShape(Rectangle())
                .gesture(ExclusiveGesture(
                    TapGesture(count: 2).onEnded { state.requestCloseBookmark(bookmark.id) },
                    TapGesture().onEnded { state.toggleBookmark(bookmark.id) }))
        }
        .padding(.vertical, 8)
        // 尺寸一致性：固定高度；平常收小、hover 變大（只變寬與字級）。
        .frame(width: hovered ? 32 : 24, height: tabHeight)
        // 梯形＋主題色（2026-08-22 使用者）：極光漸變紫藍／fable5 深咖啡、白字。
        .background(
            BotSideTabTheme.fill(tabShape)
                .shadow(color: .black.opacity(0.20), radius: 3, x: 1.5, y: 1.5))
        .overlay(
            tabShape.stroke(BotSideTabTheme.stroke(highlighted: isOpen), lineWidth: isOpen ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredTabID = bookmark.id }
            else if hoveredTabID == bookmark.id { hoveredTabID = nil }
        }
        .onTapGesture { state.toggleBookmark(bookmark.id) }
        .help(stopped
              ? "\(bookmark.name)（未開啟・展示）"
              : "\(bookmark.name)（點擊\(isOpen ? "屏蔽" : "展開")工作空間；圓點雙擊全關）")
    }

    /// add 書籤＝使用者工作平台搭建入口（點擊開三段流）。
    private var addTab: some View {
        let hovered = hoveredTabID == "fixture-add-tab"
        return VStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: hovered ? 11 : 9.5, weight: .bold))
                .foregroundStyle(BotSideTabTheme.text.opacity(0.85))
        }
        .padding(.vertical, 8)
        .frame(width: hovered ? 32 : 24, height: 34)
        .background(
            BotSideTabTheme.fill(tabShape, dimmed: true)
                .shadow(color: .black.opacity(0.14), radius: 3, x: 1.5, y: 1.5))
        .overlay(tabShape.stroke(BotSideTabTheme.stroke(highlighted: false), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredTabID = "fixture-add-tab" }
            else if hoveredTabID == "fixture-add-tab" { hoveredTabID = nil }
        }
        .onTapGesture { state.openAddSpace() }
        .help("add 書籤：搭建使用者工作平台（展示）")
    }
}

// MARK: - 元件

struct BotAvatar: View {
    let emoji: String
    let size: CGFloat
    var selected: Bool = false
    var subdued: Bool = false

    var body: some View {
        Text(emoji)
            .font(.system(size: size <= 22 ? size * 0.68 : size * 0.5))
            .frame(width: size, height: size)
            .background(
                Circle().fill(.primary.opacity(selected ? (subdued ? 0.20 : 0.30) : 0.12)))
            .overlay(Circle().stroke(.primary.opacity(selected ? 0.50 : 0.25), lineWidth: 1))
    }
}

struct BotMessageRow: View {
    let message: BotFixtureMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch message.author {
            case .user:
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 13))
                    .padding(12)
                    .background(.primary.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.primary.opacity(0.22), lineWidth: 1))
            case .bot(let name):
                // 2026-08-22 LINE 式定案：逐訊息名字移除（名稱放對話頂部置中），
                // 頭貼 30pt 頂對齊氣泡。
                BotAvatar(emoji: BotPageFixture.emoji(forBotNamed: name), size: 30)
                    .help(name)
                Text(message.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .liquidGlassSurface(cornerRadius: 12)
                Spacer(minLength: 80)
            }
        }
    }
}

struct BotEmptyHint: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: .continuous))
        .padding(24)
    }
}

struct BotSpaceFullCanvas: View {
    let space: BotFixtureSpace?

    private let topCards = [("素材庫", "photo.on.rectangle", "48 項"), ("草稿", "doc.text", "3 篇待審"), ("排程", "calendar", "本週 5 檔")]
    private let listRows = ["週一作品集貼文（展示）", "週三保養衛教（展示）", "週六閃預約（展示）", "背部滿版完成圖（展示）", "過程照排版建議（展示）"]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(space?.name ?? "space").font(.headline)
                Spacer()
                Text("滿 GUI・fixture 畫布").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(topCards, id: \.0) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: card.1).font(.system(size: 16)).foregroundStyle(.secondary)
                        Text(card.0).font(.system(size: 13, weight: .semibold))
                        Text(card.2).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.primary.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    ForEach(listRows, id: \.self) { row in
                        HStack {
                            Image(systemName: "doc.richtext").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(row).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("展示").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("屬性（展示）").font(.system(size: 12, weight: .bold)).foregroundStyle(.primary.opacity(0.7))
                    ForEach(["狀態：草稿", "負責：PO文 sub", "審核：待過目", "標籤：#刺青 #閃預約"], id: \.self) { line in
                        Text(line).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary.opacity(0.75))
                    }
                    Spacer()
                }
                .frame(width: 180, alignment: .leading)
                .padding(12)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                ForEach(["square.and.pencil", "photo", "calendar.badge.plus", "tray.full"], id: \.self) { icon in
                    Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("工具列（展示）").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.primary.opacity(0.14), in: Capsule())
        }
        .padding(24)
    }
}

struct BotSpaceCompactCanvas: View {
    let space: BotFixtureSpace?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(space?.name ?? "space").font(.headline)
                Spacer()
                Text("簡 GUI・fixture 表列").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(0..<5, id: \.self) { i in
                HStack {
                    Circle().fill(.primary.opacity(0.12)).frame(width: 8, height: 8)
                    Text("展示項目 \(i + 1)").font(.system(size: 12))
                    Spacer()
                    Text("—").foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Spacer()
        }
        .padding(24)
    }
}

struct BotSpaceStatusBar: View {
    let space: BotFixtureSpace?

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Circle().fill(.primary.opacity(0.25)).frame(width: 8, height: 8)
                Text("\(space?.name ?? "space")・無 GUI").font(.system(size: 12, weight: .medium))
                Text("狀態列展示・未接後台").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            .liquidGlassSurface(cornerRadius: 14)
            .padding(24)
        }
    }
}

// bot 私訊小視窗（X 平台 Messages 式；右下浮鈕展開）。
struct BotMessagesPanel: View {
    @ObservedObject var state: BotPageState
    let onClose: () -> Void
    @State private var filterCategoryID: String?
    /// 窗內私訊頁（雙擊列進入；2026-08-22 使用者：不是切主 chat 畫面）。
    @State private var dmTarget: (title: String, emoji: String, principalID: String?, subID: String?)?

    private var rows: [BotFixturePrincipal] {
        if let filterCategoryID,
           let category = state.fixture.principals.first(where: { $0.id == filterCategoryID }) {
            return [category]
        }
        return state.fixture.principals
    }

    var body: some View {
        Group {
            if let dmTarget {
                dmView(dmTarget)
            } else {
                listView
            }
        }
        .frame(width: 320, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.primary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    /// W90：live 私訊頁讀真 transcript（botTranscriptForUI），只有匯出／預覽才用展示 thread。
    private func dmThread(_ target: (title: String, emoji: String, principalID: String?, subID: String?)) -> [BotFixtureMessage] {
        guard state.usesLiveBots else { return BotPageFixture.thread(principalID: target.principalID, subID: target.subID) ?? [] }
        guard let id = target.subID ?? target.principalID,
              let model = CLISessionsTermination.model,
              let bot = model.botLibraryForBridge?.bot(id: id) else { return [] }
        return model.botTranscriptForUI(botID: id).map {
            .init(id: $0.id, author: $0.role == .user ? .user : .bot(name: bot.name), text: $0.text)
        }
    }

    /// 窗內私訊頁：返回鍵＋對話＋唯讀輸入示意。
    private func dmView(_ target: (title: String, emoji: String, principalID: String?, subID: String?)) -> some View {
        let thread = dmThread(target)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // 上一頁：加大可點面積（2026-08-22 使用者：不好按）。
                Button { dmTarget = nil } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("返回清單")
                BotAvatar(emoji: target.emoji, size: 24)
                Text(target.title).font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if thread.isEmpty {
                        Text(state.usesLiveBots ? "還沒有訊息" : "（展示）尚無私訊")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(thread) { message in
                        BotMessageRow(message: message)
                    }
                }
                .padding(12)
            }
            HStack(spacing: 8) {
                Text(state.usesLiveBots ? "私訊輸入尚未接入；這裡顯示的是這隻 bot 的真實對話紀錄" : "私訊（展示・未接入）")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "paperplane")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
        }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 標題列：標題＋書籤濾選（切換鈕 2026-08-22 重設計：chatGlassChip 語言）。
            // 退出＝點小視窗外空白處；Esc 仍可關。
            HStack(spacing: 8) {
                Text("bot").font(.system(size: 16, weight: .bold))
                Spacer()
                // 書籤濾選（2026-08-22 重做二版）：啟用時顯示可拆的分類 chip＋
                // 單顆書籤圓鈕（實心=有濾選）；乾淨不擠。
                if let activeID = filterCategoryID,
                   let category = state.fixture.principals.first(where: { $0.id == activeID }) {
                    HStack(spacing: 4) {
                        Text(category.name)
                            .font(.caption2.weight(.bold))
                            .lineLimit(1)
                        Button { filterCategoryID = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("清除濾選")
                    }
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(LiquidGlassTokens.brandAccent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(LiquidGlassTokens.brandAccent.opacity(0.35), lineWidth: 1))
                }
                Menu {
                    Button {
                        filterCategoryID = nil
                    } label: {
                        Label("全部", systemImage: filterCategoryID == nil ? "checkmark.circle.fill" : "circle")
                    }
                    Divider()
                    ForEach(state.fixture.principals.filter { !$0.subs.isEmpty || $0.isGroup }) { category in
                        Button {
                            filterCategoryID = category.id
                        } label: {
                            Label(category.name,
                                  systemImage: filterCategoryID == category.id ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: filterCategoryID == nil ? "bookmark" : "bookmark.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(filterCategoryID == nil ? Color.secondary : LiquidGlassTokens.brandAccent)
                        .frame(width: 28, height: 28)
                        .background(.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("書籤濾選")
                // Esc 關窗（無可視按鈕）。
                Button(action: onClose) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            // 搜尋
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("搜尋").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 12).padding(.bottom, 6)
            // 清單：bot／bot 群（X 私訊列樣式）。單擊＝主畫面跳轉（窗保持開）；
            // 雙擊＝在小視窗內進入私訊（2026-08-22 使用者）。
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { principal in
                        if principal.subs.isEmpty {
                            messageRow(emoji: principal.emoji, name: principal.name,
                                       preview: "（展示）尚無新訊息", isGroup: principal.isGroup,
                                       selected: principal.id == state.selectedPrincipalID && state.selectedSubID == nil,
                                       onSelect: { state.selectPrincipalKeepingQuickCard(principal.id) },
                                       onOpenDM: {
                                           dmTarget = (principal.name, principal.emoji, principal.id, nil)
                                       })
                            .contextMenu {
                                Button("設置") { state.openBotConfig(principal.id); onClose() }
                            }
                        } else {
                            ForEach(principal.subs) { member in
                                messageRow(emoji: member.isConsensusGroup ? "🗂️" : member.emoji,
                                           name: member.name,
                                           preview: "（展示）\(member.role)", isGroup: member.isConsensusGroup,
                                           selected: member.id == state.selectedSubID,
                                           onSelect: { state.selectSubKeepingQuickCard(member.id, of: principal.id) },
                                           onOpenDM: {
                                               dmTarget = (member.name,
                                                           member.isConsensusGroup ? "🗂️" : member.emoji,
                                                           nil, member.id)
                                           })
                                .contextMenu {
                                    Button("設置") { state.openBotConfig(member.id); onClose() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func messageRow(emoji: String, name: String, preview: String, isGroup: Bool, selected: Bool,
                            onSelect: @escaping () -> Void, onOpenDM: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            BotAvatar(emoji: emoji, size: 34, selected: selected)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if isGroup {
                        Text("群").font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.primary.opacity(0.08), in: Capsule())
                    }
                }
                Text(preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(selected ? Color.primary.opacity(0.05) : .clear)
        // 2026-08-22 使用者：整個橫向都可雙擊開私訊（不只頭貼）；主畫面不動。
        .onTapGesture(count: 2) { onOpenDM() }
        .help("雙擊：開私訊（主畫面不動）")
    }
}
