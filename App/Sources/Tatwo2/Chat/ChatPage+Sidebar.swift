// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPage+Sidebar.swift；改動 56 行（原因：保留既有改動，cli-ui 最小掛接；新增 UI 邏輯在 New、資料在 Facade）
import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin

enum ChatSidebarLayoutPolicy {
    static func width(for layoutWidth: CGFloat) -> CGFloat {
        WorkspaceSidebarMetrics.width
    }
}


extension ChatPage {
    var isChatProjectRailPinned: Bool {
        model.mode == .browser ? !browserWorkSpaceStore.focusMode : sidebarPinnedPref || Self.envRailPinned
    }
    var isChatProjectRailInteractionActive: Bool {
        model.mode == .browser && browserWorkSpaceStore.sidebarInteractionActive
    }
    var cliVisibleProjectIDs: Set<String> {
        Set(cliVisibleProjectIDsRaw.split(separator: ",").map(String.init))
    }

    func addCLIVisibleProject(_ id: UUID?) {
        guard let id else { return }
        var set = cliVisibleProjectIDs
        set.insert(id.uuidString)
        cliVisibleProjectIDsRaw = set.joined(separator: ",")
    }

    func removeCLIVisibleProject(_ id: UUID) {
        var set = cliVisibleProjectIDs
        set.remove(id.uuidString)
        cliVisibleProjectIDsRaw = set.joined(separator: ",")
    }

    var cliVisibleProjects: [TatwoNativeChatProject] {
        model.document.projects.filter { cliVisibleProjectIDs.contains($0.id.uuidString) }
    }
    var isChatProjectRailExpanded: Bool {
        isChatProjectRailHovering || isChatProjectRailPinned
    }
    @ViewBuilder
    var chatCanvasLegibilityLayer: some View {
        if surface == .window {
            ZStack {
                Rectangle()
                    .fill(LiquidGlassTokens.canvasBackground.opacity(0.10))
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.018),
                        Color.white.opacity(0.006),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .allowsHitTesting(false)
        }
    }

    var topChrome: some View {
        HStack(spacing: 10) {
            Label("Chat OS", systemImage: "macwindow.and.cursorarrow")
                .font(.headline.weight(.black))
            Text(model.isRunning ? "streaming" : "ready")
                .font(.caption2.weight(.black))
                .foregroundStyle(model.isRunning ? .orange : .green)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background((model.isRunning ? Color.orange : Color.green).opacity(0.12), in: Capsule())
            segmentedPills(title: "模式", selection: $model.mode, values: ChatRunMode.visibleChatTabs)
            routeChip
            Spacer()
            Menu {
                Button { model.exportHandoffPack() } label: {
                    Label("匯出交接包", systemImage: "square.and.arrow.up")
                }
                Button { model.importHandoffPack() } label: {
                    Label("匯入交接包", systemImage: "square.and.arrow.down")
                }
                Divider()
                Button { showDeveloperInfo.toggle() } label: {
                    Label("開發資訊", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .popover(isPresented: $showDeveloperInfo, arrowEdge: .bottom) {
                developerInfo
                    .frame(width: 520)
                    .padding(16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }

    var routeChip: some View {
        Label(model.routeChoice.title, systemImage: model.routeChoice.engine.symbol)
            .font(.caption2.weight(.black))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .chatGlassChip()
    }

    @ViewBuilder
    var sidebar: some View {
        switch model.mode {
        case .chat, .custom:
            chatSidebar
        case .cli:
            cliSidebar
        case .browser:
            if ChatRunMode.browserPreviewEnabled { browserSidebar }
        case .bot:
            // Bot owns its sidebar; do not nest the chat rail.
            EmptyView()
        }
    }

    var browserSidebar: some View {
        WorkspaceSidebarShell {
            VStack(alignment: .leading, spacing: WorkspaceSidebarMetrics.sectionSpacing) {
                workspaceModeSection
                    .padding(.top, WorkspaceSidebarMetrics.headerTopInset)
                    .contextMenu {
                        ForEach(ChatRunMode.visibleChatTabs) { mode in
                            Button(mode.displayName) { model.mode = mode }
                        }
                    }
                BrowserWorkSpaceSidebarList(store: browserWorkSpaceStore)
                    .frame(maxHeight: .infinity)
                workspaceSidebarFooter
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        // Window-relative band: deliberately outside both the mode section's top
        // padding and the glass shell's internal content inset.
        .overlay(alignment: .topLeading) {
            browserSpaceSwitcher
            .padding(.leading, WindowChromeMetrics.appControlLeadingX)
            .padding(.top, WindowChromeMetrics.trafficLightTopInset
                + WindowChromeMetrics.nativeTrafficLightDiameter / 2
                - WorkspaceSidebarMetrics.spaceSwitcherHeight / 2)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    /// Space name shares the traffic-light baseline; sidebar control lives in the toolbar.
    var browserSpaceSwitcher: some View {
        browserSpaceMenu
    }

    private var browserSpaceMenu: some View {
        Menu {
            ForEach(browserWorkSpaceStore.spaces) { space in
                Button(space.name) { browserWorkSpaceStore.selectSpace(space.id) }
            }
            Button("新增空間", action: browserWorkSpaceStore.addSpace)
            Divider()
            Button("從其他瀏覽器導入…", action: browserWorkSpaceStore.requestImport)
        } label: {
            HStack(spacing: WorkspaceSidebarMetrics.spaceSwitcherSpacing) {
                Text(browserWorkSpaceStore.selectedSpace.name)
                    .font(.system(size: WorkspaceSidebarMetrics.spaceSwitcherFontSize, weight: .bold)).lineLimit(1)
            }
            .padding(.horizontal, WorkspaceSidebarMetrics.spaceSwitcherHorizontalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: WorkspaceSidebarMetrics.spaceSwitcherMenuWidth, height: WorkspaceSidebarMetrics.spaceSwitcherHeight, alignment: .leading)
        .accessibilityLabel("切換瀏覽器空間")
        .accessibilityIdentifier("browser.spaceSwitcher")
    }

    var chatSidebar: some View {
        // 結構側欄不是浮板：外層必須貼齊 App 天地，圓角只留給內部卡片。
        WorkspaceSidebarShell {
            VStack(alignment: .leading, spacing: WorkspaceSidebarMetrics.sectionSpacing) {
                // 2026-08-23 使用者：分頁列上移（54→36，貼紅綠燈帶下緣）；
                // 「工作區」字樣移除，其右鍵工具移掛到分頁列。
                workspaceModeSection
                    .padding(.top, WorkspaceSidebarMetrics.headerTopInset)
                    .contextMenu {
                        workspaceUtilityContextMenu
                    }
                    .popover(isPresented: $showComputerUseInfo, arrowEdge: .top) {
                        ComputerUseEvaluationCard()
                            .frame(width: 360)
                            .padding(14)
                    }

                // 搜尋：縮小並與分頁列同寬（同 12pt 邊界）。
                HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    TextField("搜尋", text: $model.searchText)
                        .font(ChatTypography.systemUI(12, weight: .regular))
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .chatGlassChip()
                // 2026-09-11 使用者：搜尋縮窄，跟分頁條一樣在側欄內再內縮 12pt。
                .padding(.horizontal, 12)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.isLoadingStore {
                            chatStoreLoadingRows
                        } else {
                            projectSidebarSectionHeader

                            if projectsSectionExpanded {
                                if !model.filteredProjects.isEmpty {
                                    ForEach(model.filteredProjects) { project in
                                        projectSection(project)
                                    }
                                } else {
                                    emptySidebarText("尚無專案")
                                        .padding(.horizontal, 4)
                                }
                                RemoteDevicesSidebarSections(model: model)   // 2.0：已配對設備各一段（New/RemoteDevicesSidebarSections.swift）
                            }

                            chatSidebarSectionHeader

                            if chatsSectionExpanded {
                                if !model.pinnedThreadRefs.isEmpty {
                                    ForEach(model.pinnedThreadRefs) { item in
                                        threadRow(project: item.project, thread: item.thread, context: .pinned)
                                    }
                                }

                                ForEach(ChatSidebarThreadTreeRow.rows(model.sidebarStandaloneThreads)) { row in
                                    threadRow(project: nil, thread: row.thread,
                                              context: row.depth == 0 ? .standalone : .subthread)
                                        .padding(.leading, CGFloat(min(row.depth, 6)) * 16)
                                }

                                if model.sidebarStandaloneThreads.isEmpty && model.pinnedThreadRefs.isEmpty {
                                    emptySidebarText("尚無聊天")
                                        .padding(.horizontal, 4)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)

                workspaceSidebarFooter
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    var workspaceSidebarFooter: some View {
        VStack(spacing: WorkspaceSidebarMetrics.sectionSpacing) {
                Divider().opacity(0.35)
                HStack(alignment: .center, spacing: 10) {
                    // 左下角統一入口：TATWO OS 系統布標，點擊叫出標準玻璃浮層。
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                            showOSMenu.toggle()
                        }
                    } label: {
                        TatwoOSMark(size: 12)
                            .frame(height: 26, alignment: .center)
                            .contentShape(Rectangle())
                            .opacity(showOSMenu ? 1 : 0.92)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("TATWO OS")

                    Spacer(minLength: 4)

                    // 額度條已撤（額度移進 TATWO OS 選單）。

                    SidebarUpdateShortcut {
                        updateSettingsSection = .github
                        showOSMenu = false
                        showSettingsPage = true
                    }
                    userRowTrailingControls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomLeading) {
                    if showTabDesignPhilosophy {
                        TabDesignPhilosophyPopoverView()
                            .offset(x: -18, y: -44)
                            .onHover(perform: updateTabDesignPhilosophyHover)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomLeading)))
                            .zIndex(10)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .zIndex(showTabDesignPhilosophy ? 10 : 0)
        }
    }

    var userRowTrailingControls: some View {
        HStack(spacing: 2) {
            Button {
                tabDesignPhilosophyCloseWorkItem?.cancel()
                tabDesignPhilosophyCloseWorkItem = nil
                showTabDesignPhilosophy = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("分頁設計說明")
            .accessibilityLabel("分頁設計說明")
            .accessibilityIdentifier("chat-sidebar-design-philosophy-info")
            .onHover(perform: updateTabDesignPhilosophyHover)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    func updateTabDesignPhilosophyHover(_ hovering: Bool) {
        tabDesignPhilosophyHoverGeneration += 1
        let generation = tabDesignPhilosophyHoverGeneration
        tabDesignPhilosophyCloseWorkItem?.cancel()
        tabDesignPhilosophyCloseWorkItem = nil

        if hovering {
            showTabDesignPhilosophy = true
            return
        }

        let workItem = DispatchWorkItem {
            guard generation == tabDesignPhilosophyHoverGeneration else { return }
            tabDesignPhilosophyCloseWorkItem = nil
            showTabDesignPhilosophy = false
        }
        tabDesignPhilosophyCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    var chatStoreLoadingRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("載入對話")
                    .font(ChatTypography.systemUI(12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(index == 0 ? 0.09 : 0.055))
                    .frame(height: index == 0 ? 28 : 22)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("載入對話")
    }

    var sidebarModeSwitcher: some View {
        workspaceModeSection
    }

    var workspaceModeSection: some View {
        WorkspaceSidebarModePicker(modes: ChatRunMode.visibleChatTabs, selection: model.mode) { mode in
            withAnimation(.easeInOut(duration: 0.14)) { model.mode = mode }
        }
    }


    var cliSidebar: some View {
        WorkspaceSidebarShell {
            VStack(alignment: .leading, spacing: WorkspaceSidebarMetrics.sectionSpacing) {
                sidebarModeSwitcher.padding(.top, WorkspaceSidebarMetrics.headerTopInset)
                Menu {
                    ForEach(model.document.projects) { project in
                        Menu(project.name.isEmpty ? project.workdir : project.name) {
                            ForEach(project.threads) { thread in
                                Button(thread.title) { model.select(projectID: project.id, threadID: thread.id) }
                            }
                            Button("新增專案討論串") { model.createThread(inProject: project.id) }
                        }
                    }
                    Divider()
                    Button("新增專案（選資料夾）") {
                        if let id = model.createProjectFromExistingFolder() { addCLIVisibleProject(id) }
                    }
                } label: {
                    HStack {
                        Label(model.selectedThreadProject?.name ?? "終端工作台", systemImage: "folder")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                    }
                    .font(.system(size: CLIWorkbenchMetrics.labelFont, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(CLIWorkbenchMetrics.inset)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                ScrollView {
                    CLIWorkbenchSessionRows(tabs: model.cliWorkbenchTabs,
                        selectedTabID: model.cliSelectedWorkbenchID, panes: model.cliWorkbenchPanes,
                        appearance: .osTheme(TatwoActivePalette.current), send: model.sendCLIWorkbench)
                }
                .scrollIndicators(.hidden)
                workspaceSidebarFooter
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    var cliSessionTreeProjects: [CLISessionTreeProject] {
        cliVisibleProjects.map { project in
            CLISessionTreeProject(
                id: project.id,
                name: project.name.isEmpty ? project.workdir : project.name,
                sessions: project.sessions.filter { !$0.isArchived }.map { session in
                    CLISessionTreeTerminalSession(
                        id: session.id,
                        name: session.name,
                        engineLabel: session.engine.displayName,
                        cwd: session.cwd)
                })
        }
    }

    var cliOpenBookSessions: [CLISessionTreeOpenSession] {
        model.cliTabs.map { tab in
            CLISessionTreeOpenSession(
                id: tab.id,
                title: tab.title,
                engine: tab.engine,
                isRunning: (model.cliTabStatuses[tab.id] ?? "").hasPrefix("running"))
        }
    }

    func refreshCLILoopTree() {
        let maps = cliSourceThreadMaps()
        let rows = CLILoopsTreeLoader.loadLoopRows(
            sourceThreadByContractID: maps.byContract,
            sourceThreadByGoalID: maps.byGoal)
        cliLoopTreeRows = rows
        if let selectedCLILoopID {
            selectedCLILoopDetail = CLILoopsTreeLoader.loadDetail(
                recordID: selectedCLILoopID,
                sourceThreadByContractID: maps.byContract,
                sourceThreadByGoalID: maps.byGoal)
        }
    }

    func selectCLILoop(_ loopID: String) {
        selectedCLILoopID = loopID
        let maps = cliSourceThreadMaps()
        selectedCLILoopDetail = CLILoopsTreeLoader.loadDetail(
            recordID: loopID,
            sourceThreadByContractID: maps.byContract,
            sourceThreadByGoalID: maps.byGoal)
    }

    func clearCLILoopSelection() {
        selectedCLILoopID = nil
        selectedCLILoopDetail = nil
    }

    /// chat／Ultrawork thread 上的 contract／goal → 標題，供 loop 列「來源」標籤。
    func cliSourceThreadMaps() -> (byContract: [String: String], byGoal: [String: String]) {
        var byContract: [String: String] = [:]
        var byGoal: [String: String] = [:]
        for project in model.document.projects {
            for thread in project.threads {
                let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = title.isEmpty ? "thread" : title
                if let contractID = thread.workOSContractID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !contractID.isEmpty
                {
                    byContract[contractID] = label
                }
                if let goalID = thread.workOSGoalID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !goalID.isEmpty
                {
                    byGoal[goalID] = label
                }
            }
        }
        return (byContract, byGoal)
    }

    func chatProjectHoverSurface(width: CGFloat) -> some View {
        let expanded = isChatProjectRailExpanded
        return ZStack(alignment: .topLeading) {
            if expanded {
                ZStack(alignment: .topLeading) {
                    // Full-height retention layer. The visible sidebar can be
                    // shorter than the window while lists are sparse; without a
                    // behind-the-card tracking surface, moving through the
                    // lower-left rail area briefly left the hover region and
                    // made the project list feel like it would not stay open.
                    // `hitTest == nil` keeps all real clicks going to the
                    // sidebar rows or the chat canvas.
                    ChatProjectHoverTrackingView(onHover: updateChatProjectHover)
                        .frame(width: width + chatProjectRailExitZoneWidth)
                        .frame(maxHeight: .infinity)

                    HStack(alignment: .top, spacing: 0) {
                        sidebar
                            // 頂天落地：rail 玻璃填滿視窗高度，不再只有內容高度（使用者：左列上下沒頂天落地）。
                            .frame(width: width)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 0)
                            .onHover(perform: updateChatProjectHover)

                        // Exit buffer: the rail remains open while the pointer
                        // is near it. It closes only after the pointer leaves
                        // this invisible far-away zone, matching Codex App's
                        // sidebar retention without leaving a permanent glass
                        // strip on the left.
                        ChatProjectHoverTrackingView(onHover: updateChatProjectHover)
                            .frame(width: chatProjectRailExitZoneWidth)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: width + chatProjectRailExitZoneWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .transition(.asymmetric(
                    insertion: .offset(x: -8, y: 0).combined(with: .opacity),
                    removal: .offset(x: -8, y: 0).combined(with: .opacity)))
            } else {
                // Codex App shows no persistent affordance when the rail is
                // collapsed; only an invisible hover hit zone reveals it, so
                // there is no always-visible glass/line here. Leave a tiny
                // dead guard at the physical window edge because the visual
                // rounded window/shadow can make "outside the app" still count
                // as inside the transparent NSWindow bounds.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: chatProjectRailEdgeGuardWidth)
                        .allowsHitTesting(false)
                    ChatProjectHoverTrackingView(onHover: updateChatProjectHover, passthrough: false)
                        .frame(width: chatProjectRailRevealWidth)
                }
                    .frame(maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(width: expanded ? width + chatProjectRailExitZoneWidth : chatProjectRailEdgeGuardWidth + chatProjectRailRevealWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    func updateChatProjectHover(_ hovering: Bool) {
        chatProjectPointerInside = hovering
        chatProjectHoverGeneration += 1
        let generation = chatProjectHoverGeneration
        if hovering {
            chatProjectHoverCloseWorkItem?.cancel()
            chatProjectHoverCloseWorkItem = nil
            if !isChatProjectRailHovering {
                withAnimation(.easeInOut(duration: 0.24)) {
                    isChatProjectRailHovering = true
                }
            }
        } else {
            guard !isChatProjectRailPinned && !isChatProjectRailInteractionActive else { return }
            chatProjectHoverCloseWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                guard generation == chatProjectHoverGeneration, !isChatProjectRailPinned,
                      !isChatProjectRailInteractionActive else { return }
                chatProjectHoverCloseWorkItem = nil
                withAnimation(.easeInOut(duration: 0.22)) {
                    isChatProjectRailHovering = false
                }
            }
            chatProjectHoverCloseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + chatProjectRailCloseDelay, execute: workItem)
        }
    }

    func resetChatProjectHover() {
        chatProjectHoverGeneration += 1
        chatProjectHoverCloseWorkItem?.cancel()
        chatProjectHoverCloseWorkItem = nil
        isChatProjectRailHovering = false
        chatProjectPointerInside = false
    }

    /// Gen-4 export-only 場景選擇：僅 snapshot 模式讀取（g4-env-contract）。
    static let botExportScene: String? = {
        let env = ProcessInfo.processInfo.environment
        guard env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil else { return nil }
        return env["TATWO_ULTRAWORK_EXPORT_BOT_SCENE"]
    }()

    var developerInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("開發者資訊", systemImage: "curlybraces.square")
                .font(.headline.weight(.black))
            Text(model.bindingSummary)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
            segmentedPills(title: "皮 debug", selection: $model.skin, values: ChatSkin.allCases)
            Text("頂欄不再切皮或引擎；Claude 皮只保留在此 debug 開關，實際引擎由 composer 模型自動路由。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            bindingMatrix
            featureMappingDeck
        }
    }

    var bindingMatrix: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("2×2 binding matrix")
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(TatwoNativePaneBindingMatrix.allCases, id: \.self) { binding in
                    MatrixChip(binding: binding, isSelected: binding.skin == model.skin && binding.engine == model.routeChoice.engine)
                }
                Spacer(minLength: 0)
            }
        }
    }

    var featureMappingDeck: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("原生路由旗標映射（主畫面已收納）")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.routeChoice.engine.rawValue)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 7)], spacing: 7) {
                ForEach(model.activeMappings, id: \.feature) { mapping in
                    FeatureMappingPill(mapping: mapping)
                }
            }
        }
    }

    func segmentedPills<Value>(title: String, selection: Binding<Value>, values: [Value]) -> some View where Value: CaseIterable & Identifiable & RawRepresentable, Value.RawValue == String {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
            ForEach(values) { value in
                Button {
                    selection.wrappedValue = value
                } label: {
                    Text(value.rawValue)
                        .font(.caption2.weight(.black))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .foregroundStyle(
                            selection.wrappedValue.id == value.id
                                ? LiquidGlassTokens.brandAccent
                                : Color.secondary
                        )
                        .chatGlassChip(isSelected: selection.wrappedValue.id == value.id)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .tatwoAdaptiveCapsule(material: .thinMaterial)
    }

    func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.black))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    func emptySidebarText(_ text: String) -> some View {
        Text(text)
            .font(ChatTypography.systemUI(12.5, weight: .regular))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
    }

    var projectSidebarSectionHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    projectsSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("專案")
                        .font(ChatTypography.sidebarHeader)
                    Image(systemName: projectsSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(.secondary.opacity(0.72))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(projectsSectionExpanded ? "收起專案" : "展開專案")
            .frame(minHeight: 30)
            Spacer(minLength: 8)
            Button {
                model.createProjectFromExistingFolder()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .black))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("建立專案並選擇工作區資料夾")
            .accessibilityIdentifier("chat-sidebar-new-project")
            .contentShape(Rectangle())
        }
        .padding(.top, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    var chatSidebarSectionHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    chatsSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("聊天")
                        .font(ChatTypography.sidebarHeader)
                    Image(systemName: chatsSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(.secondary.opacity(0.72))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(chatsSectionExpanded ? "收起聊天" : "展開聊天")
            .frame(minHeight: 30)
            Spacer(minLength: 8)
            Button {
                model.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .black))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("新聊天")
            .contentShape(Rectangle())
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    func projectSection(_ project: TatwoNativeChatProject) -> some View {
        let sortedThreads = project.threads
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return model.threadActivityDate(lhs) > model.threadActivityDate(rhs)
            }
        let visibleRows = ChatSidebarThreadTreeRow.rows(sortedThreads)
        return LazyVStack(alignment: .leading, spacing: 5) {
            Button {
                model.setProjectExpanded(project.id, isExpanded: !project.isExpanded)
            } label: {
                HStack(spacing: 8) {
                    // Codex parity: project is a flat container row, not a
                    // selected chat row. The selection capsule belongs only to
                    // child threads.
                    Image(systemName: project.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(project.name)
                        .font(ChatTypography.sidebarProject)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project.workdir)
            .chatMenuRowHover()
            // 2026-09-02：專案列可直接開新聊天（Codex App 同款；之前只有
            // 建專案時的第一個 thread，之後無法在專案內再開）。
            .overlay(alignment: .trailing) {
                Button {
                    model.createThread(inProject: project.id)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在這個專案開新聊天")
                .padding(.trailing, 6)
            }

            if project.isExpanded {
                ForEach(visibleRows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        threadRow(project: project, thread: row.thread,
                                  context: row.depth == 0 ? .project : .subthread)
                        ForEach(row.thread.discussions.filter { !$0.isArchived }) { discussion in
                            discussionRow(project: project, thread: row.thread, discussion: discussion)
                                .padding(.leading, 16)
                        }
                    }
                    .padding(.leading, 24 + CGFloat(min(row.depth, 6)) * 16)
                }
            }
        }
    }

    // Presentation-only: stored checkpoint strings stay machine-readable.
    static func displayedDiscussionCloseSummary(_ raw: String?) -> String {
        let emptyCopy = "這條討論收工時沒有留下需要保留的內容"
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyCopy }

        if trimmed.lowercased().hasPrefix("checkpoint ") {
            let parts = trimmed.split(separator: "·", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count >= 3 {
                let countToken = parts[1]
                    .replacingOccurrences(of: "messages", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let count = Int(countToken)
                let body = parts.dropFirst(2).joined(separator: "·")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let bodyIsEmpty = body.isEmpty || body == "無可見訊息"
                if count == 0 || bodyIsEmpty {
                    return emptyCopy
                }
                if let count, count > 1 {
                    return "\(body)（共 \(count) 則訊息）"
                }
                return body
            }
        }

        if trimmed == "無可見訊息" {
            return emptyCopy
        }
        return trimmed
    }

    func discussionRow(project: TatwoNativeChatProject, thread: TatwoNativeChatThread, discussion: TatwoNativeDiscussion) -> some View {
        let isSelected = model.selectedDiscussionID == discussion.id
        let isCompressed = discussion.status == .compressed
        let detailsExpanded = expandedDiscussionDetailIDs.contains(discussion.id)
        let hasCollapsibleDetails = !discussion.inheritedSnapshot.isEmpty || isCompressed
        return VStack(alignment: .leading, spacing: 4) {
        Button {
            model.selectDiscussion(projectID: project.id, threadID: thread.id, discussionID: discussion.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCompressed ? "checkmark.circle.fill" : "number")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .frame(width: 13)
                // 討論串就是簡單拿來討論：只留標題，關閉才 dim，不再用刪除線。
                Text("# \(discussion.title)")
                    .font(ChatTypography.systemUI(11.5, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(
                        isCompressed
                            ? Color.secondary.opacity(0.75)
                            : (isSelected ? LiquidGlassTokens.brandAccent : .primary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(
                        isCompressed
                            ? Color.secondary.opacity(0.45)
                            : LiquidGlassTokens.brandAccent.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .help(isCompressed ? "已收工" : "討論中")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chatGlassChip(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isCompressed {
                Button {
                    model.selectDiscussion(projectID: project.id, threadID: thread.id, discussionID: discussion.id)
                    model.compressDiscussion(discussion.id)
                } label: { Label("收工壓縮", systemImage: "arrow.down.right.and.arrow.up.left") }
            }
                Button {
                    model.selectDiscussion(projectID: project.id, threadID: thread.id, discussionID: discussion.id)
                    model.mergeDiscussionIntoParent(discussion.id)
                } label: { Label("把結論併回主線", systemImage: "arrow.triangle.merge") }
        }

        if isSelected {
            VStack(alignment: .leading, spacing: 5) {
                // 三段式機制（繼承快照/收工摘要）保留，只是預設收合成一顆小展開器，
                // 避免每次選取討論串就整包資料攤開。
                if hasCollapsibleDetails {
                    Button {
                        if detailsExpanded {
                            expandedDiscussionDetailIDs.remove(discussion.id)
                        } else {
                            expandedDiscussionDetailIDs.insert(discussion.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .black))
                            Text(detailsExpanded ? "收起繼承與收工細節" : "查看繼承與收工細節")
                                .font(ChatTypography.systemUI(9.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if detailsExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if !discussion.inheritedSnapshot.isEmpty {
                            Text("繼承快照")
                                .font(ChatTypography.systemUI(9.5, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(discussion.inheritedSnapshot)
                                .font(ChatTypography.systemUI(10.5, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        if isCompressed {
                            Text("收工摘要")
                                .font(ChatTypography.systemUI(9.5, weight: .bold))
                                .foregroundStyle(LiquidGlassTokens.brandAccent)
                            Text(Self.displayedDiscussionCloseSummary(discussion.compressedSummary))
                                .font(ChatTypography.systemUI(10.5, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
                if !isCompressed {
                    Button {
                        model.selectDiscussion(projectID: project.id, threadID: thread.id, discussionID: discussion.id)
                        model.compressDiscussion(discussion.id)
                    } label: {
                        Label("收工壓縮", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(ChatTypography.systemUI(10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LiquidGlassTokens.brandAccent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .chatGlassChip(isSelected: true)
        }
        }
    }

    enum ChatSidebarThreadContext {
        case pinned
        case standalone
        case project
        case subthread
    }

    func threadRow(
        project: TatwoNativeChatProject?,
        thread: TatwoNativeChatThread,
        context: ChatSidebarThreadContext = .project
    ) -> some View {
        let isSelected = model.selectedThreadID == thread.id
        let isSubthread: Bool = {
            if case .subthread = context { return true }
            return false
        }()
        let subtitle = threadRowSubtitle(project: project, thread: thread, context: context)
        return Button {
            if let project {
                model.select(projectID: project.id, threadID: thread.id)
            } else {
                model.selectStandaloneThread(thread.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if context == .pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10.5, weight: .black))
                        .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : Color.secondary)
                        .frame(width: 14, height: 18)
                        .padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(isSubthread ? "# \(thread.title)" : thread.title)
                        .font(ChatTypography.sidebarThreadTitle.weight(isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? LiquidGlassTokens.brandAccent : .primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(ChatTypography.sidebarThreadPreview)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if isSubthread, let liveness = thread.liveness {
                    Spacer(minLength: 4)
                    Circle()
                        .fill(subthreadLivenessColor(liveness))
                        .frame(width: 7, height: 7)
                        .help(liveness.label)
                        .accessibilityLabel(liveness.label)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, subtitle.isEmpty ? 7 : 6)
            .frame(minHeight: subtitle.isEmpty ? 34 : 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Codex 式：未選中乾淨無方框，只選中列有淡 brandAccent 高亮（使用者：thread 按鈕很醜）。
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LiquidGlassTokens.brandAccent.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMenuRowHover(isSelected: isSelected)
        .contextMenu {
            // 相近功能分組（Codex 風右鍵）：基本管理 / 衍生接續 / 取用 / 危險。
            // 每個動作先選中本列 thread，讓 selection-based model 呼叫作用在它身上。
            // ── 基本管理 ──
            Button {
                selectThreadForRow(project: project, thread: thread)
                model.toggleSelectedThreadPinned()
            } label: {
                Label(thread.isPinned ? "取消釘選" : "釘選聊天",
                      systemImage: thread.isPinned ? "pin.slash" : "pin")
            }
            Button {
                selectThreadForRow(project: project, thread: thread)
                model.requestRenameSelectedThread()
            } label: { Label("重新命名對話串", systemImage: "pencil") }
            Divider()
            // ── 衍生接續 ──
            Button {
                selectThreadForRow(project: project, thread: thread)
                model.createDiscussionForSelectedThread()
            } label: { Label("建立 #討論串", systemImage: "number") }
            if project != nil {
                Button {
                    model.handoffThreadToCLISession(project: project, thread: thread)
                } label: { Label("接到 CLI session", systemImage: "terminal") }
            }
            Button {
                selectThreadForRow(project: project, thread: thread)
                model.duplicateSelectedThread(asBranch: true)
            } label: { Label("分支", systemImage: "arrow.triangle.branch") }
            Divider()
            // ── 取用 ──
            // 2.0：把這條對話（訊息＋有改動的檔案）併回另一台已配對設備（New/RemoteDevicesSidebarSections 的反向）
            if !model.remoteSidebarSections.isEmpty {
                Menu {
                    ForEach(model.remoteSidebarSections) { section in
                        Button(section.isOnline ? section.deviceName : "\(section.deviceName)（離線）") {
                            _ = model.pushThreadToDevice(thread.id, section.deviceID)
                        }
                        .disabled(!section.isOnline)
                    }
                } label: { Label("併回設備…", systemImage: "arrow.up.forward.app") }
            }
            Button {
                selectThreadForRow(project: project, thread: thread)
                model.copySelectedThreadSummary()
            } label: { Label("複製摘要", systemImage: "doc.on.doc") }
            // 2026-08-21 使用者需求：右鍵可直接複製對話串 id。
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    thread.id.uuidString.lowercased(), forType: .string)
            } label: { Label("複製對話串 ID", systemImage: "number.circle") }
            Button {
                selectThreadForRow(project: project, thread: thread)
                NotificationCenter.default.post(name: .tatwoOpenWorkOSWindow, object: TatwoPage.chat.rawValue)
            } label: { Label("在新視窗中開啟", systemImage: "macwindow.on.rectangle") }
            Divider()
            // ── 危險 ──
            Button(role: .destructive) {
                selectThreadForRow(project: project, thread: thread)
                model.archiveSelectedThread()
            } label: { Label("封存聊天", systemImage: "archivebox") }
        }
    }

    func subthreadLivenessColor(_ liveness: ThreadLiveness) -> Color {
        switch liveness {
        case .active:
            return LiquidGlassTokens.loopsPositive
        case .idle:
            return LiquidGlassTokens.loopsCaution
        case .stalled:
            return LiquidGlassTokens.loopsCritical
        case .done:
            return Color.secondary.opacity(0.55)
        case .failed:
            return LiquidGlassTokens.loopsCritical   // 已失敗：沿用既有紅色，不改佈局
        }
    }

    func selectThreadForRow(project: TatwoNativeChatProject?, thread: TatwoNativeChatThread) {
        if let project {
            model.select(projectID: project.id, threadID: thread.id)
        } else {
            model.selectStandaloneThread(thread.id)
        }
    }

    func threadRowSubtitle(project: TatwoNativeChatProject?, thread: TatwoNativeChatThread, context: ChatSidebarThreadContext) -> String {
        let preview = thread.lastPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 副標與標題重複(preview 就是標題文字)時隱藏，避免同一句顯示兩次（使用者：thread 按鈕很醜）。
        let deduped = (preview == title || title.hasPrefix(preview) || preview.hasPrefix(title)) ? "" : preview
        switch context {
        case .pinned:
            return deduped.isEmpty ? (project.map { compactProjectLabel($0.name) } ?? "") : deduped
        case .standalone, .project:
            return deduped
        case .subthread:
            return ""
        }
    }

    func chip(systemImage: String, text: String) -> some View {
        Label(text.isEmpty ? "—" : text, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(.secondary)
            .chatGlassChip()
    }

    func threadInfoContextStrip(
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
                    threadInfoFlatMetric(item.0, item.1, systemImage: item.2, tint: tint)
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

    func threadOutputFilesCard(files: [String], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Label("輸出內容", systemImage: "doc.text")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("\(total)")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(
                        total > 0 ? LiquidGlassTokens.brandAccent : Color.secondary
                    )
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
                    if total > files.count {
                        Text("+\(total - files.count) more")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 18)
                    }
                }
            }
        }
        .padding(9)
        .chatGlassChip()
        .help("對齊 Codex App 右側 Plan 卡：用 git status 顯示本 thread 目前可驗證的輸出檔案，不顯示本機絕對路徑。")
    }

    func threadInfoFlatMetric(_ title: String, _ value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, weight: .bold, design: title == "Contract" ? .monospaced : .rounded))
                .foregroundStyle(title == "Contract" ? tint : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func compactProjectLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let candidate = trimmed.replacingOccurrences(of: #"^Tatwo\s+"#, with: "", options: .regularExpression)
        let display = candidate.count < trimmed.count ? candidate : trimmed
        if display.count <= 18 { return display }
        return String(display.prefix(16)) + "…"
    }

    func compactBranchLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—" else { return "—" }
        let tail = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        if tail.count <= 18 { return tail }
        return String(tail.prefix(16)) + "…"
    }

    func compactThreadLabel(_ id: UUID?) -> String {
        guard let raw = id?.uuidString.lowercased(), !raw.isEmpty else { return "—" }
        return String(raw.prefix(8))
    }

    func threadSubagentsCard(rows: [ThreadSubagentPresentationRow]) -> some View {
        let hasRunning = rows.contains { $0.statusLabel == "working" }
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
                    ChatModelAvatar(route: row.route, size: 17)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(row.identityLabel)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text(row.modelID)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(row.detail)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(row.statusLabel)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(row.tint)
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

    func threadPluginSummaryStrip(selected: [PluginRegistryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                    threadInfoPluginsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Label("Plugins · 提示", systemImage: "puzzlepiece.extension")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.primary)
                    pluginCountBubble(selected.count)
                    Spacer(minLength: 0)
                    if !threadInfoPluginsExpanded {
                        threadPluginCompactChips(selected)
                    }
                    Image(systemName: threadInfoPluginsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.secondary)
                        .frame(width: 11)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("僅做需求判斷與上下文提示；Chat route 未開放 Plugin invocation。")

            Text("Chat：僅做需求判斷／上下文提示；未開放 Plugin invocation。真正執行需切到可授權流程並由人類確認。")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if threadInfoPluginsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("管理")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button {
                            model.reloadPluginRegistry()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .help("重新讀取 PluginRegistry staging")
                    }
                    if model.availableThreadPluginEntries.isEmpty {
                        Text("正在掃描技能…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.availableThreadPluginEntries.prefix(7)) { entry in
                            threadPluginToggle(entry)
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

    func pluginCountBubble(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(count > 0 ? LiquidGlassTokens.brandAccent : Color.secondary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .chatGlassChip(isSelected: count > 0)
    }

    @ViewBuilder
    func threadPluginCompactChips(_ selected: [PluginRegistryEntry]) -> some View {
        if selected.isEmpty {
            Text("無常駐")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(selected.prefix(2))) { entry in
                    Text(entry.name)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .foregroundStyle(LiquidGlassTokens.brandAccent)
                        .chatGlassChip(isSelected: true)
                }
                if selected.count > 2 {
                    Text("+\(selected.count - 2)")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 112, alignment: .trailing)
            .clipped()
        }
    }

    func threadPluginToggle(_ entry: PluginRegistryEntry) -> some View {
        let enabled = model.isThreadPluginEnabled(entry.id)
        return Toggle(isOn: Binding(
            get: { model.isThreadPluginEnabled(entry.id) },
            set: { model.setThreadPlugin(entry.id, enabled: $0) }
        )) {
            HStack(spacing: 7) {
                Image(systemName: enabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(enabled ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(entry.kind.rawValue)
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .foregroundStyle(enabled ? LiquidGlassTokens.brandAccent : Color.secondary)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .chatGlassChip(isSelected: enabled)
                        Text(pluginMicroSummary(entry.purpose))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .chatGlassChip(isSelected: enabled)
        .help(entry.trigger)
    }

    func pluginMicroSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 36 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 36)
        return String(trimmed[..<end]) + "…"
    }

}
