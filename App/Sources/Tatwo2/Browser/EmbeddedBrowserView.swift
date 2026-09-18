import AppKit
import SwiftUI

/// A window onto the registry, never a second tab store.
struct EmbeddedBrowserView: View {
    let sessionID: String?
    @ObservedObject var model: ChatPageModel
    var isPanelResizing = false
    var agentControllable = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        if let sessionID {
            ChatBrowserPanel(sessionID: sessionID, model: model,
                agentControllable: agentControllable, isPanelResizing: isPanelResizing, onClose: onClose)
                .id(sessionID)
        } else {
            Text("請先選擇討論串").foregroundStyle(.secondary)
        }
    }

    nonisolated static func committedURLForPersistence(_ state: EmbeddedBrowserNavigationState) -> URL? {
        // A direct bridge load may beat the UI's request callback. Apply this
        // rule to all native state updates, not just already-tagged UI lanes.
        guard state.phase == .committed || state.phase == .finished,
              state.hasExplicitCommittedURL,
              let raw = state.committedMainFrameURLString else { return nil }
        return URL(string: raw)
    }
}

private struct ChatBrowserPanel: View {
    let sessionID: String
    @ObservedObject var model: ChatPageModel
    let agentControllable: Bool
    let isPanelResizing: Bool
    let onClose: (() -> Void)?
    @State private var downloadsPresented = false
    @ObservedObject private var registry: BrowserTabRegistry
    @ObservedObject private var runtime: BrowserWorkSpaceRuntime
    @State private var browserFocused = false
    @State private var findPresented = false
    @State private var findFocusRequest = 0
    @State private var addressFocusRequest = 0
    @State private var diagnosticsPresented = false
    @State private var annotationsPresented = false
    @State private var panelID = UUID()
    @State private var addressText = ""
    @State private var command: EmbeddedBrowserCommand?
    @State private var commandTabID: UUID?
    @State private var validationMessage: String?
    @FocusState private var addressFieldFocused: Bool
    @State private var addressExpansionRequested = false

    init(sessionID: String, model: ChatPageModel, agentControllable: Bool, isPanelResizing: Bool, onClose: (() -> Void)?) {
        self.onClose = onClose
        self.sessionID = sessionID
        self.model = model
        self.agentControllable = agentControllable
        self.isPanelResizing = isPanelResizing
        _registry = ObservedObject(wrappedValue: model.browserTabRegistry)
        _runtime = ObservedObject(wrappedValue: BrowserWorkSpaceRuntime.forChat(sessionID, registry: model.browserTabRegistry))
    }

    private var owner: BrowserTabOwner { .chatSession(sessionID: sessionID) }
    private var tabs: [BrowserTab] { registry.tabs(ownedBy: .chatSession(sessionID: sessionID)) }
    private var selected: BrowserTab? { registry.selectedTab(ownedBy: owner) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("瀏覽器", systemImage: "globe").font(.caption.weight(.semibold))
                Spacer()
                Button { downloadsPresented.toggle() } label: { Image(systemName: "arrow.down.circle") }
                    .help("下載項目").accessibilityLabel("下載項目")
                    .popover(isPresented: $downloadsPresented) { ChatBrowserDownloadsView() }
                Menu {
                    Button("在網頁中尋找…") { performBrowserAction(.findInPage) }
                    Button("放大") { changeZoom(1) }
                    Button("縮小") { changeZoom(-1) }
                    Button("原始大小") { issue(.zoom(0)) }
                    Divider()
                    Button("重新開啟已關閉分頁") { _ = registry.reopenClosedTab(owner: owner) }
                    Button("列印…") { issue(.printPage) }.disabled(selected == nil || selected?.usesAgentContext == true)
                    Button("匯出 PDF 並開啟…") { issue(.printPDF) }.disabled(selected == nil || selected?.usesAgentContext == true)
                    Button("瀏覽器診斷") { diagnosticsPresented = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("瀏覽器選單")
                if let onClose {
                    Button(action: onClose) { Image(systemName: "sidebar.right") }
                        .help("收合瀏覽器，保留分頁").accessibilityLabel("收合瀏覽器")
                }
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
            .background(NonWindowDraggingView())
            HStack(spacing: BrowserSidebarMetrics.childGap) {
                ScrollViewReader { tabScroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BrowserSidebarMetrics.childGap) {
                        ForEach(tabs) { tab in
                            HStack(spacing: 0) {
                            BrowserTabRow(title: tab.usesAgentContext ? "AI · \(tab.title)" : tab.title,
                                tabID: tab.id.uuidString, host: tab.url?.host ?? "about:blank",
                                favicon: tab.faviconPNG, selected: selected?.id == tab.id,
                                sleeping: tab.isSleeping, onSelect: { select(tab.id) })
                                Button { registry.close(tab.id) } label: { Image(systemName: "xmark").font(.caption2).padding(6) }
                                    .buttonStyle(.plain).help("關閉分頁")
                                    .accessibilityLabel("關閉分頁：\(tab.title)")
                                    .accessibilityIdentifier("browser.closeTab.\(tab.id.uuidString)")
                            }
                                .frame(width: BrowserSidebarMetrics.chatTabWidth)
                                .id(tab.id)
                                .contextMenu {
                                    Button("關閉") { registry.close(tab.id) }
                                    Button(tab.isPinned ? "取消釘選" : "釘選") { registry.setPinned(tab.id, !tab.isPinned) }
                                    Menu("移入 browser space") {
                                        ForEach(registry.spaces.filter { !$0.isSessionSpace }) { space in
                                            Button(space.name) { registry.move(tab.id, to: .workSpace(spaceID: space.id)) }
                                        }
                                    }
                                    .disabled(tab.usesAgentContext)
                                }
                        }
                    }
                }
                .onChange(of: selected?.id, initial: true) { _, id in
                    if let id { tabScroll.scrollTo(id, anchor: .center) }
                }
                }
                Button(action: openNewTab) { Image(systemName: "plus")
                    .frame(width: BrowserSidebarMetrics.controlHitSize, height: BrowserSidebarMetrics.controlHitSize) }
                    .buttonStyle(.plain).accessibilityLabel("新分頁")
                    .accessibilityIdentifier("browser.newTab")
                    .contextMenu {
                        Button("新增 AI 分頁") { select(registry.openTab(owner: owner, title: "AI 分頁", isAgentTab: true).id) }
                    }
            }.background(NonWindowDraggingView())
            HStack(spacing: BrowserOmniboxMetrics.controlGap) {
                EmbeddedBrowserToolbar(addressText: $addressText, addressFieldFocused: $addressFieldFocused,
                    state: runtime.navigationTabID == selected?.id ? runtime.navigationState : .blank,
                    enabled: selected != nil,
                    onSubmit: loadAddress, onCommand: { issue($0) },
                    openTabs: tabs.map { BrowserAddressSuggestion(id: $0.id.uuidString, title: $0.title, url: $0.url?.absoluteString ?? "") },
                    onSelectTab: { if let id = UUID(uuidString: $0) { select(id) } }, expansionRequest: $addressExpansionRequested)
                Button { annotationsPresented = true } label: {
                    Image(systemName: "note.text")
                }
                    .buttonStyle(.plain).disabled(selected == nil)
                    .frame(minWidth: BrowserSidebarMetrics.controlHitSize, minHeight: BrowserSidebarMetrics.controlHitSize)
                    .padding(.trailing, BrowserSidebarMetrics.rowHorizontalPadding)
                    .help("註解").accessibilityLabel("註解")
            }
            .frame(height: BrowserOmniboxMetrics.toolbarHeight)
            .background(Color(nsColor: .controlBackgroundColor))
            .zIndex(BrowserOmniboxMetrics.chromeZIndex)
            BrowserNavigationProgress(tabID: selected?.id,
                state: runtime.navigationTabID == selected?.id ? runtime.navigationState : .blank)
            if findPresented {
                BrowserFindBar(presented: $findPresented, count: runtime.findCount, activeIndex: runtime.findIndex,
                    onCommand: { issue($0) }, focusRequest: findFocusRequest).id(selected?.id)
            }
            Divider()
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            if EmbeddedBrowserEnginePolicy.current != .chromiumCEF {
                BrowserEngineUnavailablePlaceholder()
            } else if let tab = selected, model.isLive,
               EmbeddedBrowserUIFixturePolicy.allowsRealActions(isFixture: EmbeddedBrowserUIFixturePolicy.isEnabled()) {
                BrowserWorkSpaceCEFSurface(tabID: tab.id, spaceID: BrowserTabRegistry.sessionSpaceID,
                    command: command, onPopup: { _, _ in }, runtime: runtime,
                    isGeometryDragInProgress: isPanelResizing, surfaceID: panelID)
                    .overlay {
                        if (tab.url == nil || tab.url?.absoluteString == "about:blank"),
                           !runtime.navigationState.isLoading,
                           runtime.navigationState.visibleError == nil {
                            VStack(spacing: 12) {
                                Image(systemName: "globe").font(.largeTitle)
                                Text("開始瀏覽").font(.headline)
                                Text("輸入網址或搜尋，同時繼續左側的工作。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("輸入網址或搜尋") { addressFocusRequest &+= 1 }
                                if tab.usesAgentContext {
                                    Text("AI 分頁使用獨立環境；本機預覽請新增一般分頁。")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: .controlBackgroundColor))
                        }
                    }
            } else {
                VStack(spacing: 12) {
                    Text("沒有開啟的分頁").font(.headline)
                    Button("新增分頁", action: openNewTab)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(BrowserDailyFocusScope(focused: $browserFocused))
        .background {
            if EmbeddedBrowserEnginePolicy.current == .chromiumCEF {
                BrowserDailyNavigationControls(focused: browserFocused && !annotationsPresented && !diagnosticsPresented,
                    shortcutSerial: runtime.shortcutSerial, shortcutKind: runtime.shortcutKind,
                hasTab: selected != nil, editingAddress: addressFieldFocused,
                    url: runtime.navigationState.urlString, findPresented: $findPresented,
                    onCommand: { issue($0) }, onReopen: { _ = registry.reopenClosedTab(owner: owner) },
                    onTabNumber: { number in
                        if let index = BrowserDailyNavigation.tabIndex(number: number, count: tabs.count) { select(tabs[index].id) }
                    }, onAction: performBrowserAction)
            }
        }
        .sheet(isPresented: $diagnosticsPresented) { BrowserDiagnosticsView() }
        .sheet(isPresented: $annotationsPresented) {
            if let tab = selected { BrowserAnnotationSheet(tab: tab).background(BrowserAnnotationShortcutDismiss()) }
        }
        .onAppear {
            if tabs.isEmpty { openNewTab() }
            syncSelection()
            consumeBrowserAgentRequest()
        }
        .onChange(of: selected?.id) { _, _ in syncSelection() }
        .onChange(of: findPresented) { _, visible in if visible { addressFieldFocused = false } }
        .task(id: addressFocusRequest) {
            guard addressFocusRequest > 0 else { return }
            let requestedTab = selected?.id
            let previousFindRequest = findFocusRequest
            addressFieldFocused = false
            await Task.yield()
            guard !Task.isCancelled, previousFindRequest == findFocusRequest,
                  requestedTab == selected?.id else { return }
            addressExpansionRequested = true
        }
        .onChange(of: runtime.surfaceID) { _, _ in consumeBrowserAgentRequest() }
        .onChange(of: model.requestedBrowserAgentURL) { _, _ in consumeBrowserAgentRequest() }
        .onChange(of: runtime.navigationState) { _, state in
            guard runtime.navigationTabID == selected?.id else { return }
            model.updateBrowserAgentActivePage(sessionID: sessionID, state: state)
            addressText = EmbeddedBrowserAddressPresentation.text(draft: addressText,
                navigationURL: state.urlString, isEditing: addressFieldFocused)
        }
        .onDisappear {
            if runtime.surfaceID == nil || runtime.surfaceID == panelID {
                model.clearBrowserAgentActivePage(sessionID: sessionID)
            }
        }
    }

    private func performBrowserAction(_ action: BrowserAction) {
        switch action {
        case .newTab: openNewTab()
        case .closeTab: if let selected { registry.close(selected.id) }
        case .focusAddressBar: addressFocusRequest &+= 1
        case .findInPage:
            addressFieldFocused = false; findFocusRequest &+= 1; findPresented = true
        case .toggleAnnotations: annotationsPresented = true
        case .nextTab, .previousTab:
            guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selected?.id }) else { return }
            select(tabs[(index + (action == .nextTab ? 1 : tabs.count - 1)) % tabs.count].id)
        case .openDiagnostics: diagnosticsPresented = true
        case .newSpace: _ = registry.addSpace(name: "新 space")
        case .openImport: NotificationCenter.default.post(name: Notification.Name("tatwo.browser.openImport"), object: nil)
        case .printPage: issue(.printPage)
        case .printPDF: issue(.printPDF)
        default: break
        }
    }

    private func changeZoom(_ delta: Double) {
        let host = URL(string: runtime.navigationState.urlString ?? "")?.host?.lowercased() ?? ""
        let current = BrowserGeneralSettings.load().zoomByHost[host] ?? 0
        issue(.zoom(BrowserDailyNavigation.zoom(current, delta: delta)))
    }
    private func syncSelection() {
        validationMessage = nil
        findPresented = false
        if commandTabID != selected?.id { command = nil; commandTabID = nil }
        addressFieldFocused = false
        addressText = selected?.url?.absoluteString ?? ""
        model.clearBrowserAgentActivePage(sessionID: sessionID)
    }
    private func select(_ id: UUID) { registry.select(id) }
    private func openNewTab() {
        select(registry.openTab(owner: owner).id)
        addressFocusRequest &+= 1
    }
    private func consumeBrowserAgentRequest() {
        guard agentControllable,
              BrowserChatRequestRouting.canConsume(panelID: panelID, mountedSurfaceID: runtime.surfaceID),
              let navigation = model.consumeBrowserAgentNavigation(for: sessionID) else { return }
        guard registry.tabForAgentNavigation(ownedBy: owner) != nil else { return }
        // Keep ungranted URLs out of persistence. The native dispatch gate revalidates the request.
        issue(.load(navigation.url), agentNavigation: navigation)
    }
    private func loadAddress() {
        guard let url = BrowserOmniboxResolver.resolve(addressText, engine: BrowserGeneralSettings.load().searchEngine),
              let tabID = selected?.id else { return }
        switch EmbeddedBrowserNavigationPolicy.decision(for: url, actor: selected?.usesAgentContext == true ? .strict : .human) {
        case .allow: issue(.load(url))
        case let .askOncePerHost(host):
            Task { @MainActor in
                guard await BrowserHumanInteraction.shared.allowPrivateHost(host), selected?.id == tabID else { return }
                issue(.load(url))
            }
        case let .block(reason): validationMessage = EmbeddedBrowserVisibleError.blockedNavigation(reason).message
        }
    }
    private func issue(_ action: EmbeddedBrowserCommand.Action, agentNavigation: BrowserAgentNavigation? = nil) {
        addressFieldFocused = false
        validationMessage = nil
        commandTabID = selected?.id
        command = EmbeddedBrowserCommand(action: action, agentNavigation: agentNavigation)
        model.clearBrowserAgentActivePage(sessionID: sessionID)
    }
}
