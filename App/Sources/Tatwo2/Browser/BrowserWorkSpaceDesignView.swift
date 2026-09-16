import SwiftUI
import Combine

// MARK: - Registry projection (also compiled directly by the isolated test)
@MainActor
final class BrowserWorkSpaceStore: ObservableObject {
    struct Space: Identifiable, Equatable {
        let id: Int
        var name: String
        var isSessionSpace = false
    }
    struct Download: Identifiable {
        let id: Int
        let name: String
        let size: String
        let time: String
        var section: String { time.hasPrefix("今天") ? "今天" : time.hasPrefix("昨天") ? "昨天" : "Earlier" }
        var isImage: Bool { name.lowercased().hasSuffix(".png") }
    }
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var selectedSpaceID = 0
    @Published var focusMode = false
    @Published var searchFocusRequest = 0
    @Published private(set) var downloads = [
        Download(id: 0, name: "工作筆記.pdf", size: "2.4 MB", time: "今天 10:30"),
        Download(id: 1, name: "參考圖片.png", size: "840 KB", time: "昨天 16:20"),
    ]
    var selectedSpace: Space { spaces.first { $0.id == selectedSpaceID } ?? spaces[0] }
    var spacePageCount: Int { spaces.count }
    func selectSpace(_ id: Int) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id
        if !selectedSpace.isSessionSpace { lastWorkSpaceID = spaceIDs[id] }
        refresh()
    }
    func addSpace() {
        let space = registry.addSpace(name: "空間 \(spaces.count)")
        selectSpace(spaceKey(space.id))
    }
    func clearDownloads() { downloads = [] }

    struct Bookmark: Identifiable, Equatable {
        let id: UUID
        var title: String
        var url: String
    }
    struct Folder: Identifiable {
        var id = UUID()
        var name = "新資料夾"
        var bookmarks: [Bookmark] = []
        private(set) var expanded = false
        private(set) var chevronExpanded = false
        mutating func toggle() {
            expanded = !bookmarks.isEmpty && !expanded
            chevronExpanded = bookmarks.isEmpty ? !chevronExpanded : expanded
        }
    }
    @Published private(set) var folders: [Folder] = []
    @Published var annotationTab: BrowserTab?
    @Published var bookmarkEditorActive = false
    @Published private(set) var lastRemovedBookmark: BrowserTabRegistry.RemovedBookmark?
    private var currentFolderID: UUID?

    func showAnnotations(_ id: Int) { annotationTab = registry.tabs.first { $0.id == tabIDs[id] } }
    func showSessionAnnotations(_ id: UUID) { annotationTab = registry.tabs.first { $0.id == id } }
    func deleteBookmark(_ id: UUID) {
        guard let removed = registry.bookmarkRemoval(id) else { return }
        lastRemovedBookmark = removed
        registry.removeBookmark(id)
    }
    func undoBookmarkDeletion() {
        guard let removed = lastRemovedBookmark, registry.restoreBookmark(removed) else { return }
        lastRemovedBookmark = nil
    }
    func openBookmark(_ bookmark: Bookmark, folderID: UUID) {
        guard let spaceID = currentSpaceUUID, let url = URL(string: bookmark.url) else { return }
        currentFolderID = folderID
        let tab = registry.openTab(owner: .workSpace(spaceID: spaceID), url: url, title: bookmark.title, folderID: folderID)
        select(tabKey(tab.id))
    }

    func toggleFolder(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        currentFolderID = id
        folders[index].toggle()
    }
    @discardableResult
    func addFolder() -> UUID {
        guard let spaceID = spaceIDs[selectedSpaceID],
              let folder = registry.addFolder(spaceID: spaceID) else { return UUID() }
        return folder.id
    }
    func renameFolder(_ id: UUID, to name: String) {
        registry.renameFolder(id, to: name)
    }
    @discardableResult
    func saveBookmark(tabID: Int, into folderID: UUID) -> Bool {
        guard let id = tabIDs[tabID], let tab = registry.tabs.first(where: { $0.id == id }),
              let url = tab.url else { return false }
        return registry.addBookmark(folderID: folderID, url: url, title: tab.title) != nil
    }
    func bookmarkCurrentTab() {
        let folderID = folders.first { $0.id == currentFolderID }?.id ?? folders.first?.id ?? addFolder()
        saveBookmark(tabID: selectedID, into: folderID)
    }
    func saveDraggedTabs(_ payloads: [String], into folderID: UUID) -> Bool {
        guard canAddTab else { return false }
        var saved = false
        for payload in payloads where payload.hasPrefix("tatwo-browser-tab:") {
            guard let id = Int(payload.dropFirst("tatwo-browser-tab:".count)) else { continue }
            if saveBookmark(tabID: id, into: folderID) { saved = true }
        }
        return saved
    }

    struct Tab: Identifiable, Equatable {
        let id: Int
        var title: String
        var pinned = false
        var url = "about:blank"
        var sleeping = false
        var faviconPNG: Data?
    }
    struct Suggestion: Identifiable {
        let id: String
        let section: String
        let title: String
        let tabID: Int?
    }
    enum ImportSource: String, CaseIterable, Identifiable {
        case arc = "Arc", chrome = "Chrome", brave = "Brave", edge = "Edge"
        case opera = "Opera", vivaldi = "Vivaldi", safari = "Safari"
        var id: String { rawValue }
    }
    enum ImportData: String, CaseIterable, Identifiable {
        case bookmarks = "書籤（含資料夾結構）", passwords = "密碼"
        case history = "瀏覽紀錄（最近 90 天）", extensions = "擴充功能", pinned = "釘選分頁"
        var id: String { rawValue }
    }

    static let importExplanation = "從 Arc 只能拿到書籤、密碼、瀏覽紀錄；Arc 的 Spaces、釘選分頁、Easels、Boosts 不會過來。從 Chrome／Brave／Edge／Opera／Vivaldi 另可導入擴充功能與釘選分頁。Firefox 不支援。"
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedID = 0
    @Published var importPresented = false
    @Published private(set) var importSource: ImportSource = .arc
    @Published private(set) var importData: Set<ImportData> = [.bookmarks, .passwords, .history]
    @Published var profile = "Default"
    @Published private(set) var notice = ""
    private let registry: BrowserTabRegistry
    private var lastWorkSpaceID: UUID?
    private var observation: AnyCancellable?
    // Stable window-local integer aliases preserve the existing view/drag payload API.
    private var spaceIDs: [Int: UUID] = [:]
    private var tabIDs: [Int: UUID] = [:]
    private var folderStates: [UUID: Folder] = [:]
    init(registry: BrowserTabRegistry? = nil) {
        self.registry = registry ?? .shared
        refresh()
        if let first = spaces.first(where: { !$0.isSessionSpace }) { selectSpace(first.id) }
        observation = self.registry.changes.sink { [weak self] in self?.refresh() }
    }
    private func spaceKey(_ id: UUID) -> Int {
        if let key = spaceIDs.first(where: { $0.value == id })?.key { return key }
        let key = spaceIDs.count; spaceIDs[key] = id; return key
    }
    private func tabKey(_ id: UUID) -> Int {
        if let key = tabIDs.first(where: { $0.value == id })?.key { return key }
        let key = tabIDs.count; tabIDs[key] = id; return key
    }
    private func refresh() {
        for folder in folders { folderStates[folder.id] = folder }
        spaces = registry.spaces.map { Space(id: spaceKey($0.id), name: $0.name, isSessionSpace: $0.isSessionSpace) }
        spaces = spaces.filter(\.isSessionSpace) + spaces.filter { !$0.isSessionSpace }
        if !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = spaces.first(where: { !$0.isSessionSpace })?.id ?? spaces.first?.id ?? 0
        }
        refreshSessionFolders()
        guard let spaceID = spaceIDs[selectedSpaceID], let space = registry.spaces.first(where: { $0.id == spaceID }) else { return }
        folders = space.folders.map { folder in
            var projected = folderStates[folder.id] ?? Folder(id: folder.id)
            projected.name = folder.name
            projected.bookmarks = folder.bookmarks.map { Bookmark(id: $0.id, title: $0.title, url: $0.url.absoluteString) }
            return projected
        }
        let owned = space.isSessionSpace ? registry.tabs.filter {
            if case .chatSession = $0.owner { return true }; return false
        } : registry.tabs(ownedBy: .workSpace(spaceID: space.id))
        tabs = owned.map { Tab(id: tabKey($0.id), title: $0.title, pinned: $0.isPinned, url: $0.url?.absoluteString ?? "about:blank", sleeping: $0.isSleeping, faviconPNG: $0.faviconPNG) }
        if !tabs.contains(where: { $0.id == selectedID }) { selectedID = tabs.first?.id ?? -1 }
        if tabs.isEmpty { focusMode = false }
    }
    struct SessionFolder: Identifiable {
        // nil is the general folder, distinct from a project actually named 一般.
        let id: String?
        var name: String { id ?? "一般" }
        let sessions: [OpenBrowserSessionSummary]
        let tabs: [BrowserTab]
        var expanded = true
    }
    @Published private(set) var sessionFolders: [SessionFolder] = []
    @Published private(set) var botTabs: [BrowserTab] = []
    @Published private(set) var selectedSessionTabID: UUID?
    private var selectedSessionID: String?
    private func refreshSessionFolders() {
        let groups = Dictionary(grouping: registry.openSessions) { session -> String? in
            let name = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        var keys = groups.keys.sorted { ($0 ?? "") < ($1 ?? "") }
        if keys.isEmpty { keys = [nil] }
        sessionFolders = keys.map { key in
            let summaries = groups[key] ?? []
            return SessionFolder(id: key, sessions: summaries,
                tabs: summaries.flatMap { registry.tabs(ownedBy: .chatSession(sessionID: $0.sessionID)) },
                expanded: sessionFolders.first { $0.id == key }?.expanded ?? true)
        }
        botTabs = registry.tabs.filter { if case .bot = $0.owner { return true }; return false }
        if !sessionFolders.flatMap(\.tabs).contains(where: { $0.id == selectedSessionTabID }) {
            selectedSessionTabID = selectedSessionID.flatMap { registry.tabs(ownedBy: .chatSession(sessionID: $0)).first?.id }
            if selectedSessionTabID == nil { selectedSessionID = nil }
        }
    }
    func toggleSessionFolder(_ id: String?) {
        guard let index = sessionFolders.firstIndex(where: { $0.id == id }) else { return }
        sessionFolders[index].expanded.toggle()
    }
    func closeSessionFolder(_ id: String?) {
        let sessions = sessionFolders.first { $0.id == id }?.sessions ?? []
        for session in sessions { registry.closeAll(ownedBy: .chatSession(sessionID: session.sessionID)) }
    }
    func selectSessionTab(_ id: UUID) {
        guard sessionFolders.flatMap(\.tabs).contains(where: { $0.id == id }) else { return }
        selectedSessionTabID = id
        selectedSessionID = selectedSession?.sessionID
    }
    var selectedSession: OpenBrowserSessionSummary? {
        guard let tab = registry.tabs.first(where: { $0.id == selectedSessionTabID }),
              case let .chatSession(id) = tab.owner else { return nil }
        return registry.openSessions.first { $0.sessionID == id }
    }
    var sessionLanes: [BrowserTab] {
        guard let session = selectedSession else { return [] }
        return registry.tabs(ownedBy: .chatSession(sessionID: session.sessionID))
    }
    var sessionDestination: BrowserSpace? {
        registry.spaces.first { $0.id == lastWorkSpaceID && !$0.isSessionSpace }
            ?? registry.spaces.first { !$0.isSessionSpace }
    }
    var sessionBookmarkFolders: [BrowserFolder] { sessionDestination?.folders ?? [] }
    func moveSessionTab(_ id: UUID) {
        guard let space = sessionDestination, isChatTab(id) else { return }
        registry.move(id, to: .workSpace(spaceID: space.id))
    }
    func bookmarkSessionTab(_ id: UUID, into folderID: UUID) {
        guard isChatTab(id), sessionBookmarkFolders.contains(where: { $0.id == folderID }),
              let tab = registry.tabs.first(where: { $0.id == id }), let url = tab.url,
              registry.addBookmark(folderID: folderID, url: url, title: tab.title) != nil else { return }
        registry.close(id)
    }
    func closeSessionTab(_ id: UUID) {
        if isChatTab(id) { registry.close(id) }
    }
    private func isChatTab(_ id: UUID) -> Bool {
        registry.tabs.contains { tab in
            guard tab.id == id else { return false }
            if case .chatSession = tab.owner { return true }; return false
        }
    }
    var canAddTab: Bool { !selectedSpace.isSessionSpace }
    var selectedTab: Tab { tabs.first { $0.id == selectedID } ?? Tab(id: -1, title: "新分頁") }
    var activeTabs: [Tab] { tabs.filter { !$0.pinned } }
    var pinnedTabs: [Tab] { tabs.filter(\.pinned) }

    func select(_ id: Int) {
        guard tabs.contains(where: { $0.id == id }), let uuid = tabIDs[id] else { return }
        selectedID = id
        registry.touch(uuid)
    }
    var selectedRegistryID: UUID? { canAddTab ? tabIDs[selectedID] : nil }
    var currentSpaceUUID: UUID? { canAddTab ? spaceIDs[selectedSpaceID] : nil }
    func addTab(url: URL? = nil) {
        guard canAddTab, let spaceID = spaceIDs[selectedSpaceID] else { return }
        let tab = registry.openTab(owner: .workSpace(spaceID: spaceID), url: url)
        selectedID = tabKey(tab.id)
    }
    /// External links (other apps, default-browser handoff): switch to the target space and select the new tab.
    func openExternal(spaceID: UUID, url: URL) {
        guard registry.spaces.contains(where: { $0.id == spaceID && !$0.isSessionSpace }) else { return }
        selectSpace(spaceKey(spaceID))
        let tab = registry.openTab(owner: .workSpace(spaceID: spaceID), url: url)
        selectedID = tabKey(tab.id)
    }
    func openPopup(spaceID: UUID, url: URL) {
        guard registry.spaces.contains(where: { $0.id == spaceID && !$0.isSessionSpace }) else { return }
        let folderID = registry.tabs.first { $0.id == selectedRegistryID && $0.owner == .workSpace(spaceID: spaceID) }?.folderID
        _ = registry.openTab(owner: .workSpace(spaceID: spaceID), url: url, folderID: folderID)
    }
    func reopenClosedTab() {
        guard let spaceID = currentSpaceUUID,
              let tab = registry.reopenClosedTab(owner: .workSpace(spaceID: spaceID)) else { return }
        currentFolderID = tab.folderID
        select(tabKey(tab.id))
    }
    var canReopenClosedTab: Bool {
        guard let spaceID = currentSpaceUUID else { return false }
        return registry.recentlyClosed.contains { $0.owner == .workSpace(spaceID: spaceID) }
    }
    func selectTabNumber(_ number: Int) {
        guard let index = BrowserDailyNavigation.tabIndex(number: number, count: tabs.count) else { return }
        select(tabs[index].id)
    }
    func close(_ id: Int) {
        guard tabs.contains(where: { $0.id == id }), let uuid = tabIDs[id] else { return }
        registry.close(uuid)
    }
    func searchTabs(_ text: String) -> [Tab] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return tabs.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) }
    }
    func suggestions(for text: String) -> [Suggestion] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var result: [Suggestion] = []
        if let tab = searchTabs(text).first {
            result.append(Suggestion(id: "tab-\(tab.id)", section: "已開分頁", title: tab.title, tabID: tab.id))
        }
        result.append(Suggestion(id: "search", section: "搜尋", title: "搜尋「\(text)」", tabID: nil))
        return Array(result.prefix(3))
    }
    func showDesignNotice() { notice = "設計稿：未接線" }
    /// New action-list entrypoints use the existing production importer, not the design fixture sheet.
    func requestImport() {
        NotificationCenter.default.post(name: Notification.Name("tatwo.browser.openImport"), object: nil,
            userInfo: currentSpaceUUID.map { ["spaceID": $0] })
    }
    func openImport() { notice = ""; importPresented = true }
    func cancelImport() { importPresented = false }
    func finishImport() { importPresented = false; showDesignNotice() }
    func supports(_ data: ImportData) -> Bool {
        importSource != .safari && (importSource != .arc || (data != .extensions && data != .pinned))
    }
    func selectSource(_ source: ImportSource) {
        guard source != .safari else { return }
        importSource = source
        importData = importData.filter { supports($0) }
    }
    func setImportData(_ data: ImportData, selected: Bool) {
        guard supports(data) else { return }
        if selected { importData.insert(data) } else { importData.remove(data) }
    }
}
// MARK: - End local fixture model

struct BrowserWorkSpaceDesignView: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    @ObservedObject private var runtime = BrowserWorkSpaceRuntime.shared
    @FocusState private var addressFocused: Bool
    @State private var diagnosticsPresented = false
    @State private var loginHelpPresented = false
    @State private var browserFocused = false
    @State private var findPresented = false
    @State private var findFocusRequest = 0
    @State private var shortcutMap = BrowserGeneralSettings.load().shortcuts
    @State private var query = ""
    @State private var command: EmbeddedBrowserCommand?
    @State private var commandTabID: UUID?
    @State private var settingsError: String?
    @State private var settings = BrowserSettings.load()
    @State private var tabSearchPresented = false
    @State private var tabSearch = ""
    @State private var searchIndex = 0
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case search, tabSearch }
    private var palette: TatwoThemePalette { TatwoActivePalette.current }
    private var searchResults: [BrowserWorkSpaceStore.Tab] { store.searchTabs(tabSearch) }
    private var fieldFill: Color { Color(red: 246 / 255, green: 242 / 255, blue: 234 / 255) }
    private var folderFill: Color { Color(red: 154 / 255, green: 163 / 255, blue: 173 / 255) }
    private var shadowColor: Color { Color(red: 120 / 255, green: 90 / 255, blue: 70 / 255) }

    var body: some View {
        Group {
            if EmbeddedBrowserEnginePolicy.current != .chromiumCEF { BrowserEngineUnavailablePlaceholder() }
            else if store.selectedSpace.isSessionSpace { sessionContent }
            else { browserContent }
        }
            .background(palette.canvasBase)
            .background {
                // Undo bookmark deletion is a listed action; it only has a key when the user binds one.
                if let combo = shortcutMap.bindings[.undoBookmarkDeletion] {
                    Button("") { store.undoBookmarkDeletion() }
                        .disabled(store.lastRemovedBookmark == nil || focusedField != nil || store.bookmarkEditorActive
                            || store.annotationTab != nil || store.importPresented)
                        .keyboardShortcut(combo.equivalent, modifiers: combo.eventModifiers)
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserShortcutMap.changed)) { _ in
                shortcutMap = BrowserGeneralSettings.load().shortcuts
            }
            .overlay { if tabSearchPresented { tabSearchOverlay } }
            .sheet(isPresented: $diagnosticsPresented) { BrowserDiagnosticsView() }
            .sheet(isPresented: $loginHelpPresented) { BrowserLoginHelpView(currentURL: store.selectedTab.url) }
            .sheet(item: $store.annotationTab) { BrowserAnnotationSheet(tab: $0).background(BrowserAnnotationShortcutDismiss()) }
            .sheet(isPresented: $store.importPresented) { importSheet }
            .onChange(of: store.selectedSpaceID) { _, _ in
                tabSearchPresented = false; focusedField = nil; restoreAddress()
            }
            .onChange(of: store.selectedID) { _, _ in command = nil; restoreAddress() }
            .onChange(of: store.selectedTab.url) { _, _ in if focusedField != .search { restoreAddress() } }
            .onAppear { restoreAddress() }
            .task(id: store.searchFocusRequest) {
                guard store.searchFocusRequest > 0 else { return }
                let requestedTab = store.selectedRegistryID
                let previousFindRequest = findFocusRequest
                addressFocused = false; focusedField = nil
                // This task runs after the newly selected toolbar is mounted.
                await Task.yield()
                guard !Task.isCancelled, previousFindRequest == findFocusRequest,
                      requestedTab == store.selectedRegistryID else { return }
                focusedField = .search
                addressFocused = requestedTab != nil
            }
            .onExitCommand { tabSearchPresented = false; focusedField = nil; restoreAddress() }
    }

    private var sessionContent: some View {
        ScrollView {
            if let session = store.selectedSession {
                VStack(alignment: .leading, spacing: BrowserSidebarMetrics.laneRowSpacing) {
                    Text(session.threadTitle).font(.headline)
                    ForEach(store.sessionLanes) { lane in
                        HStack(spacing: BrowserSidebarMetrics.laneRowSpacing) {
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                                .frame(width: BrowserSidebarMetrics.laneThumbSize.width, height: BrowserSidebarMetrics.laneThumbSize.height)
                                .background(palette.surfaceBorder.opacity(0.3), in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.laneThumbCornerRadius))
                                .accessibilityLabel("縮圖佔位")
                            VStack(alignment: .leading, spacing: BrowserSidebarMetrics.childGap) {
                                Text(lane.title).font(.system(size: BrowserSidebarMetrics.rowFontSize)).lineLimit(1)
                                Text(lane.url?.absoluteString ?? "about:blank").lineLimit(2).textSelection(.enabled)
                                Text(lane.lastActiveAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }.padding(BrowserSidebarMetrics.laneCardPadding).frame(maxWidth: BrowserSidebarMetrics.laneCardWidth, alignment: .leading)
                    .background(fieldFill, in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.laneCardCornerRadius))
                    .padding(BrowserSidebarMetrics.laneCardOuterInset)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func favicon(_ tab: BrowserWorkSpaceStore.Tab) -> some View {
        Group {
            if let data = tab.faviconPNG, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }
            .font(.system(size: 10, weight: .bold)).foregroundStyle(fieldFill)
            .frame(width: 16, height: 16)
            .background(tab.id.isMultiple(of: 2) ? palette.brandAccent : folderFill,
                        in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Centered Search and extensions
    private var page: some View {
        ZStack {
            RadialGradient(colors: [palette.brandAccent.opacity(0.16), .clear],
                           center: .center, startRadius: 0, endRadius: 230)
                .frame(maxWidth: 780, maxHeight: 460).allowsHitTesting(false)
            searchBox
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) { extensionStrip.padding(.top, 14).padding(.trailing, 16) }
        .overlay(alignment: .bottom) {
            if !store.notice.isEmpty { Text(store.notice).font(.caption).foregroundStyle(.secondary).padding(12) }
        }

    }

    private func send(_ action: EmbeddedBrowserCommand.Action) {
        commandTabID = store.selectedRegistryID
        command = EmbeddedBrowserCommand(action: action)
    }

    private var searchEngineMenu: some View {
        Picker("搜尋引擎", selection: Binding(get: { settings.searchEngine }, set: { engine in
            do {
                let updated = BrowserSettings(searchEngine: engine)
                try updated.save()
                settings = updated
                settingsError = nil
            } catch { settingsError = "搜尋設定未儲存：\(error.localizedDescription)" }
        })) {
            Text("Google").tag(BrowserSearchEngine.google)
            Text("DuckDuckGo").tag(BrowserSearchEngine.duckduckgo)
            Text("Bing").tag(BrowserSearchEngine.bing)
        }
    }

    private func restoreAddress() {
        query = store.selectedRegistryID == nil ? "" : store.selectedTab.url
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            if let tabID = store.selectedRegistryID, let spaceID = store.currentSpaceUUID {
                HStack(alignment: .top, spacing: 0) {
                    EmbeddedBrowserToolbar(addressText: $query, addressFieldFocused: $addressFocused,
                        state: runtime.navigationTabID == tabID ? runtime.navigationState : .blank,
                        enabled: true, onSubmit: submitSearch, onCommand: send,
                        openTabs: store.tabs.map { BrowserAddressSuggestion(id: String($0.id), title: $0.title, url: $0.url) },
                        onSelectTab: { if let id = Int($0) { store.select(id) } })
                    Menu {
                        Button("在網頁中尋找…") { performBrowserAction(.findInPage) }
                        Button("列印…") { send(.printPage) }
                        Button("存成 PDF 並用系統預覽開啟") { send(.printPDF) }
                        if runtime.navigationTabID == tabID && runtime.navigationState.isPDF {
                            Button("下載 PDF 並用系統預覽開啟") { send(.openPDF) }
                        }
                        Button("登入協助…") { loginHelpPresented = true }
                        Button("重設此網站的多檔下載權限") { send(.resetDownloadPermission) }
                        Divider()
                        Button("搜尋分頁…", action: openTabSearch)
                        Button(store.focusMode ? "離開專注模式" : "專注模式") { store.focusMode.toggle() }
                        Divider()
                        Button("關閉目前分頁") { store.close(store.selectedID) }
                        Button("重新開啟關閉的分頁", action: store.reopenClosedTab).disabled(!store.canReopenClosedTab)
                        Button("復原刪除的書籤", action: store.undoBookmarkDeletion).disabled(store.lastRemovedBookmark == nil)
                        Button("診斷…") { diagnosticsPresented = true }
                        Button("新增 space", action: store.addSpace)
                        Button("從其他瀏覽器導入…", action: store.requestImport)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: BrowserSidebarMetrics.controlHitSize, minHeight: BrowserSidebarMetrics.controlHitSize)
                    }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("瀏覽器功能")
                    Button("註解") { store.showAnnotations(store.selectedID) }
                        .buttonStyle(.plain)
                        .frame(minWidth: BrowserSidebarMetrics.controlHitSize, minHeight: BrowserSidebarMetrics.controlHitSize)
                        .padding(.trailing, BrowserSidebarMetrics.rowHorizontalPadding)
                }
                BrowserNavigationProgress(tabID: tabID,
                    state: runtime.navigationTabID == tabID ? runtime.navigationState : .blank)
                if runtime.navigationTabID == tabID && runtime.navigationState.isPDF {
                    HStack {
                        Text("PDF 未顯示內容時，可使用系統預覽。").font(.callout)
                        Spacer()
                        Button("下載 PDF 並開啟") { send(.openPDF) }
                    }.padding(10).background(.quaternary)
                }
                if findPresented {
                    BrowserFindBar(presented: $findPresented, count: runtime.findCount, activeIndex: runtime.findIndex,
                                   onCommand: send, focusRequest: findFocusRequest)
                        .id(tabID)
                }
                // This surface mounts TatwoCEFBrowserView through the shared native tab host (actor: .human).
                BrowserWorkSpaceCEFSurface(tabID: tabID, spaceID: spaceID, command: commandTabID == tabID ? command : nil,
                    onPopup: { store.openPopup(spaceID: $0, url: $1) })
            } else { page }
        }
        .overlay(alignment: .bottom) {
            if let settingsError { Text(settingsError).font(.caption).padding(8).background(.regularMaterial) }
        }
        .background {
            BrowserDailyNavigationControls(focused: browserFocused && !store.bookmarkEditorActive && store.annotationTab == nil && !store.importPresented && !tabSearchPresented && !diagnosticsPresented && !loginHelpPresented,
                shortcutSerial: runtime.shortcutSerial, shortcutKind: runtime.shortcutKind,
                hasTab: store.selectedRegistryID != nil, editingAddress: addressFocused || focusedField != nil,
                url: runtime.navigationState.urlString, findPresented: $findPresented,
                onCommand: send, onReopen: store.reopenClosedTab, onTabNumber: store.selectTabNumber,
                onAction: performBrowserAction)
        }
        .background(BrowserDailyFocusScope(focused: $browserFocused, acceptsWindowResponder: true))
        .onChange(of: focusedField) { _, value in if value == .search { addressFocused = true } }
        .onChange(of: addressFocused) { _, value in focusedField = value ? .search : nil }
        .onChange(of: findPresented) { _, value in
            if value { addressFocused = false; focusedField = nil }
        }
        .onChange(of: store.selectedID) { _, _ in findPresented = false }
    }

    private func performBrowserAction(_ action: BrowserAction) {
        switch action {
        case .newTab: if store.canAddTab { store.addTab(); store.searchFocusRequest += 1 }
        case .closeTab: store.close(store.selectedID)
        case .focusAddressBar: store.searchFocusRequest += 1
        case .findInPage:
            addressFocused = false; focusedField = nil
            findFocusRequest &+= 1; findPresented = true
        case .nextTab, .previousTab:
            let tabs = store.tabs
            guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == store.selectedID }) else { return }
            store.select(tabs[(index + (action == .nextTab ? 1 : tabs.count - 1)) % tabs.count].id)
        case .toggleAnnotations: store.showAnnotations(store.selectedID)
        case .openDiagnostics: diagnosticsPresented = true
        case .newSpace: store.addSpace()
        case .openImport: store.requestImport()
        case .printPage: send(.printPage)
        case .printPDF: send(.printPDF)
        default: break
        }
    }

    private var extensionStrip: some View {
        HStack(spacing: 12) {
            Button("重新開啟關閉的分頁", action: store.reopenClosedTab).disabled(!store.canReopenClosedTab)
            Label("擴充功能尚未支援", systemImage: "puzzlepiece.extension")
                .font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(.borderless)
    }

    private var searchBox: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField("Search", text: $query).font(.system(size: 14.5))
                    .textFieldStyle(.plain).focused($focusedField, equals: .search)
                    .onSubmit(submitSearch).contextMenu { searchEngineMenu }
            }.padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 12)
            HStack {
                roundButton("加入分頁", "plus") { store.addTab(); store.searchFocusRequest += 1 }.disabled(!store.canAddTab)
                Spacer()
                roundButton("搜尋", "arrow.up", action: submitSearch)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 13).padding(.horizontal, 14).padding(.bottom, 11)
        .background(fieldFill, in: RoundedRectangle(cornerRadius: 15))
        .shadow(color: shadowColor.opacity(0.18), radius: 17, x: 0, y: 10)
        .overlay(alignment: .top) {
            // An overlay does not move the centered box when suggestions appear.
            if !store.suggestions(for: query).isEmpty {
                suggestionList.offset(y: 104)
            }
        }
    }

    private func roundButton(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16))
                .frame(width: 30, height: 30).background(palette.surfaceBorder.opacity(0.45), in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(store.suggestions(for: query)) { suggestion in
                Button {
                    if let id = suggestion.tabID { store.select(id) }
                    else { submitSearch() }
                    restoreAddress()
                } label: {
                    HStack {
                        Text(suggestion.section).font(.caption).foregroundStyle(.secondary)
                        Text(suggestion.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.background(fieldFill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func submitSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        settings = BrowserSettings.load()
        guard let url = BrowserOmniboxResolver.resolve(query, engine: settings.searchEngine) else { return }
        if store.selectedRegistryID == nil { store.addTab(url: url) }
        else { send(.load(url)) }
        addressFocused = false
        focusedField = nil
    }

    // MARK: - Tab search (only existing local tabs)
    private func openTabSearch() {
        tabSearch = ""; searchIndex = 0; tabSearchPresented = true; focusedField = .tabSearch
    }
    private var tabSearchOverlay: some View {
        ZStack {
            palette.canvasBase.opacity(0.85).onTapGesture { tabSearchPresented = false }
            VStack(spacing: 10) {
                HStack {
                    TextField("搜尋分頁", text: $tabSearch).textFieldStyle(.plain)
                        .focused($focusedField, equals: .tabSearch)
                        .onAppear { focusedField = .tabSearch }
                        .onChange(of: tabSearch) { _, _ in searchIndex = 0 }
                        .onSubmit(selectSearchResult)
                    Button("取消") { tabSearchPresented = false }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, tab in
                                Button { store.select(tab.id); tabSearchPresented = false } label: {
                                    HStack { favicon(tab); Text(tab.title); Spacer() }.padding(8)
                                        .background(index == searchIndex ? palette.surfaceBorder : .clear,
                                                    in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain).id(tab.id)
                            }
                        }
                    }.frame(maxHeight: 320)
                    .onChange(of: searchIndex) { _, index in
                        if searchResults.indices.contains(index) { proxy.scrollTo(searchResults[index].id) }
                    }
                }
                if searchResults.isEmpty { Text("沒有符合的分頁").foregroundStyle(.secondary) }
            }
            .padding(18).frame(maxWidth: 480)
            .background(fieldFill, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard))
            .padding(24)
            .onMoveCommand { direction in
                if direction == .down { searchIndex = min(searchIndex + 1, max(0, searchResults.count - 1)) }
                if direction == .up { searchIndex = max(0, searchIndex - 1) }
            }
        }
    }
    private func selectSearchResult() {
        guard searchResults.indices.contains(searchIndex) else { return }
        store.select(searchResults[searchIndex].id); tabSearchPresented = false
    }

    // MARK: - Import sheet (local choices only)
    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("從其他瀏覽器導入").font(.system(size: 16, weight: .bold))
            Text("Dia 的入口：首次啟動精靈，或 Dia 選單 › Import from Another Browser。TATWO 放在 Browser work space 的空間選單。")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            Text("來源").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(BrowserWorkSpaceStore.ImportSource.allCases) { source in
                    Button { store.selectSource(source) } label: {
                        HStack(spacing: 8) {
                            Text(String(source.rawValue.prefix(1)))
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(fieldFill)
                                .frame(width: 18, height: 18)
                                .background(palette.brandAccent, in: RoundedRectangle(cornerRadius: 5))
                            Text(source == .safari ? "Safari・即將支援" : source.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }.padding(9).frame(maxWidth: .infinity)
                            .background(palette.brandAccent.opacity(store.importSource == source ? 0.10 : 0.04),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(palette.brandAccent.opacity(store.importSource == source ? 0.7 : 0), lineWidth: 1.5))
                    }.buttonStyle(.plain).disabled(source == .safari).opacity(source == .safari ? 0.5 : 1)
                }
            }
            Text("要導入的資料").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2),
                      alignment: .leading, spacing: 6) {
                ForEach(BrowserWorkSpaceStore.ImportData.allCases) { data in
                    Toggle(data.rawValue + (store.supports(data) ? "" : "（Arc 不提供）"), isOn: Binding(
                        get: { store.importData.contains(data) },
                        set: { store.setImportData(data, selected: $0) }
                    )).toggleStyle(.checkbox).disabled(!store.supports(data)).font(.system(size: 13))
                }
            }
            Text(BrowserWorkSpaceStore.importExplanation).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true).padding(10)
                .background(palette.surfaceBorder.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Picker("設定檔", selection: $store.profile) {
                    Text("Default").tag("Default")
                    Text("工作（示意）").tag("工作")
                }.frame(maxWidth: 220)
                Spacer()
                Button("取消", action: store.cancelImport).keyboardShortcut(.cancelAction)
                Button("導入", action: store.finishImport).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 520).background(fieldFill)
    }
}

// Shared chat shell owns the header and OS footer; this view only supplies browser rows.
struct BrowserWorkSpaceSidebarList: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    @ObservedObject private var downloadStore = BrowserDownloadStore.shared
    @State private var hoveredTab: Int?
    @State private var targetedFolderID: UUID?
    @State private var editingFolderID: UUID?
    @State private var folderName = ""
    @State private var pinsExpanded = true
    @State private var downloadQuery = ""
    @State private var downloadStatusFilter = "全部"
    @State private var selectedDownloadID: String?
    @State private var hoveredDownloadID: String?
    @State private var downloadsPresented = false
    @State private var diagnosticsPresented = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case close(Int), folderName }
    private var palette: TatwoThemePalette { TatwoActivePalette.current }
    private var fieldFill: Color { Color(red: 246 / 255, green: 242 / 255, blue: 234 / 255) }
    private var folderFill: Color { Color(red: 154 / 255, green: 163 / 255, blue: 173 / 255) }
    private var shadowColor: Color { Color(red: 120 / 255, green: 90 / 255, blue: 70 / 255) }

    var body: some View {
        VStack(spacing: WorkspaceSidebarMetrics.sectionSpacing) {
            if store.selectedSpace.isSessionSpace {
                sessionSidebar
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        pinnedSection
                        folderSection
                        Divider().padding(.horizontal, 6).padding(.vertical, 8)
                        newTabButton
                        ForEach(store.activeTabs) { tab in tabRow(tab) }
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("重新開啟關閉的分頁", action: store.reopenClosedTab).disabled(!store.canReopenClosedTab)
                    Button("復原刪除的書籤", action: store.undoBookmarkDeletion).disabled(store.lastRemovedBookmark == nil)
                    Button("新增分頁") { store.addTab(); store.searchFocusRequest += 1 }.disabled(!store.canAddTab)
                    Button("新增書籤（目前分頁）", action: store.bookmarkCurrentTab)
                    Button("新增 space", action: store.addSpace)
                    Button("從其他瀏覽器導入…", action: store.requestImport)
                    Button("註解…") { store.showAnnotations(store.selectedID) }
                    Button("新增資料夾", action: beginFolderNaming)
                    Divider()
                    Button("診斷…") { diagnosticsPresented = true }
                }
            }
            spaceControls
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $diagnosticsPresented) { BrowserDiagnosticsView() }
    }

    // MARK: - Session space (registry-only, no creation or drop targets)
    private var sessionSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(store.sessionFolders) { folder in
                    VStack(alignment: .leading, spacing: 1) {
                        Button { store.toggleSessionFolder(folder.id) } label: {
                            HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                                Image(systemName: "folder.fill").foregroundStyle(folderFill).frame(width: BrowserSidebarMetrics.rowIconWidth)
                                HStack(spacing: BrowserSidebarMetrics.childGap) {
                                    Text(folder.name).fontWeight(.bold)
                                    chevron(expanded: folder.expanded)
                                }
                                Spacer(minLength: 0)
                            }.font(.system(size: BrowserSidebarMetrics.rowFontSize))
                                .padding(.vertical, BrowserSidebarMetrics.rowVerticalPadding)
                                .padding(.horizontal, BrowserSidebarMetrics.rowHorizontalPadding)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button("全部關閉並移除") { store.closeSessionFolder(folder.id) }
                                .disabled(folder.tabs.isEmpty)
                        }
                        if folder.expanded {
                            ForEach(folder.tabs) { tab in sessionTabRow(tab) }
                        }
                    }
                }
                Divider().padding(.horizontal, BrowserSidebarMetrics.dividerHorizontalInset)
                    .padding(.vertical, BrowserSidebarMetrics.dividerVerticalInset)
                Text("Bot 開啟的瀏覽器").font(.system(size: BrowserSidebarMetrics.metaFontSize, weight: .semibold))
                    .foregroundStyle(.secondary).padding(BrowserSidebarMetrics.captionPadding)
                BrowserBotTabRows(tabs: store.botTabs)
                if store.botTabs.isEmpty {
                    Text("尚未有 bot 瀏覽器").font(.system(size: BrowserSidebarMetrics.metaFontSize))
                        .foregroundStyle(.tertiary).padding(BrowserSidebarMetrics.captionPadding)
                }
            }
        }.frame(maxHeight: .infinity)
    }

    private func sessionTabRow(_ tab: BrowserTab) -> some View {
        BrowserTabRow(title: tab.title, host: tab.url?.host ?? "about:blank", favicon: tab.faviconPNG,
            selected: store.selectedSessionTabID == tab.id,
            leadingInset: BrowserSidebarMetrics.childLeadingInset,
            onSelect: { store.selectSessionTab(tab.id) }).help(tab.url?.absoluteString ?? tab.title)
            .accessibilityAddTraits(store.selectedSessionTabID == tab.id ? .isSelected : [])
            .contextMenu {
                Menu("移入 browser space") {
                    Button("成為分頁（到目前 space）") { store.moveSessionTab(tab.id) }
                        .disabled(store.sessionDestination == nil)
                    Menu("存成書籤到") {
                        ForEach(store.sessionBookmarkFolders) { folder in
                            Button(folder.name) { store.bookmarkSessionTab(tab.id, into: folder.id) }
                        }
                    }.disabled(tab.url == nil || store.sessionBookmarkFolders.isEmpty)
                }
                Button("註解…") { store.showSessionAnnotations(tab.id) }
                Button("關閉") { store.closeSessionTab(tab.id) }
            }
    }

    private var spaceControls: some View {
        HStack(spacing: 8) {
            Button { downloadsPresented.toggle() } label: {
                Image(systemName: "arrow.down.circle").frame(width: 28, height: 28)
            }
            .accessibilityLabel("瀏覽器下載")
            .sheet(isPresented: $downloadsPresented) { downloadsSheet }
            Spacer(minLength: 0)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(store.spaces) { space in
                        Button { store.selectSpace(space.id) } label: {
                            ZStack {
                                if space.isSessionSpace {
                                    Circle().strokeBorder(folderFill, lineWidth: BrowserSidebarMetrics.spaceDotStroke)
                                    Circle().fill(store.selectedSpaceID == space.id ? folderFill : .clear)
                                } else {
                                    Circle().fill(store.selectedSpaceID == space.id ? folderFill : palette.surfaceBorder)
                                }
                            }.frame(width: BrowserSidebarMetrics.spaceDotSize, height: BrowserSidebarMetrics.spaceDotSize)
                                .frame(width: BrowserSidebarMetrics.spaceDotHitWidth, height: BrowserSidebarMetrics.spaceDotHitHeight)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(space.name)
                        .accessibilityAddTraits(store.selectedSpaceID == space.id ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
            Button(action: store.addSpace) {
                Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.accessibilityLabel("新增空間")
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 6)
    }

    private var downloadsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("下載").font(.headline)
                Spacer()
                Button("完成") { downloadsPresented = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            downloadsContent
        }
        .frame(width: 660, height: 520)
        .background { LiquidGlassPanelCard(cornerRadius: LiquidGlassTokens.radiusCard) { Color.clear } }
        .onExitCommand { downloadsPresented = false }
    }

    private var downloadsContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜尋下載", text: $downloadQuery).textFieldStyle(.plain)
                    Menu {
                        ForEach(["全部", "進行中", "已完成", "未完成"], id: \.self) { filter in
                            Button(filter) { downloadStatusFilter = filter }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease").frame(width: 28, height: 28)
                    }.accessibilityLabel("篩選下載：\(downloadStatusFilter)")
                }
                HStack {
                    Spacer()
                    Button("清除紀錄", action: downloadStore.clearDownloads)
                        .disabled(!downloadStore.downloads.contains { $0.state.isTerminal })
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if downloadStore.downloads.isEmpty { Text("尚無下載").foregroundStyle(.secondary) }
                        ForEach(["今天", "昨天", "Earlier"], id: \.self) { section in
                            let files = downloadStore.downloads.filter {
                                $0.section == section && (downloadQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(downloadQuery)) &&
                                (downloadStatusFilter == "全部" ||
                                 (downloadStatusFilter == "進行中" && !$0.state.isTerminal) ||
                                 (downloadStatusFilter == "已完成" && $0.done) ||
                                 (downloadStatusFilter == "未完成" && ($0.state == .failed || $0.state == .cancelled)))
                            }
                            if !files.isEmpty {
                                Text(section).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                                ForEach(files) { download in downloadRow(download) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(16).frame(width: 330)
            Divider()
            downloadPreview.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func downloadRow(_ download: BrowserDownloadStore.Item) -> some View {
        let selected = selectedDownloadID == download.id
        let trashVisible = selected || hoveredDownloadID == download.id
        return HStack(spacing: 8) {
            Button { selectedDownloadID = download.id } label: {
                HStack(spacing: 10) {
                    downloadArtwork(download, large: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(download.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                        Text(download.time).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.accessibilityAddTraits(selected ? .isSelected : [])
            if downloadStore.canCancel(download) {
                Button { downloadStore.cancel(download) } label: { Image(systemName: "xmark.circle").frame(width: 28, height: 32) }
                    .accessibilityLabel("取消下載 \(download.name)")
            } else if downloadStore.canRetry(download) {
                Button { downloadStore.retry(download) } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 32) }
                    .accessibilityLabel("重試下載 \(download.name)")
            }
            Button { downloadStore.hide(download) } label: {
                Image(systemName: "trash").frame(width: 28, height: 32)
            }
            .accessibilityLabel("隱藏下載紀錄 \(download.name)")
            .disabled(!download.state.isTerminal)
            .opacity(trashVisible ? 1 : 0).allowsHitTesting(trashVisible)
        }
        .padding(8)
        .background(selected ? palette.surfaceBorder : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onHover { hoveredDownloadID = $0 ? download.id : nil }
        .contextMenu {
            Button("在 Finder 顯示") { downloadStore.reveal(download) }.disabled(!download.done)
            Button("快速預覽") { downloadStore.preview(download) }.disabled(!download.done)
            Button("取消下載") { downloadStore.cancel(download) }.disabled(!downloadStore.canCancel(download))
            Button("重試下載") { downloadStore.retry(download) }.disabled(!downloadStore.canRetry(download))
        }
    }

    private var downloadPreview: some View {
        VStack(spacing: 16) {
            if let download = downloadStore.downloads.first(where: { $0.id == selectedDownloadID }) {
                downloadArtwork(download, large: true)
                Text(download.name).font(.headline).lineLimit(2)
                Text(download.time).font(.caption).foregroundStyle(.secondary)
                if !download.state.isTerminal && download.total > 0 {
                    ProgressView(value: Double(download.received), total: Double(max(download.total, download.received)))
                }
                if let failure = download.failure {
                    Text(failure).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack {
                    if downloadStore.canPause(download) { Button("暫停") { downloadStore.pause(download) } }
                    if downloadStore.canResume(download) { Button("繼續下載") { downloadStore.resume(download) } }
                    if downloadStore.canCancel(download) { Button("取消下載") { downloadStore.cancel(download) } }
                    if downloadStore.canRetry(download) { Button("重試下載") { downloadStore.retry(download) } }
                }
                Button("快速預覽") { downloadStore.preview(download) }.disabled(!download.done)
                Button("在 Finder 顯示") { downloadStore.reveal(download) }.disabled(!download.done)
            } else {
                Text("選一個檔案預覽").font(.callout).foregroundStyle(.tertiary)
            }
        }.padding(20).accessibilityElement(children: .contain).accessibilityLabel("下載預覽")
    }

    private func downloadArtwork(_ download: BrowserDownloadStore.Item, large: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(download.isImage ? folderFill : .white)
            if download.isImage {
                Image(systemName: "photo").font(.system(size: large ? 64 : 20)).foregroundStyle(palette.brandAccent)
            } else {
                VStack(alignment: .leading, spacing: large ? 12 : 4) {
                    ForEach(0..<5) { line in
                        RoundedRectangle(cornerRadius: 1).fill(folderFill)
                            .frame(width: large ? (line == 4 ? 90 : 150) : (line == 4 ? 14 : 24), height: large ? 4 : 2)
                    }
                    Spacer(minLength: 0)
                }.padding(large ? 24 : 6)
            }
        }
        .frame(width: large ? 230 : 38, height: large ? 300 : 48)
        .accessibilityHidden(true)
    }

    // MARK: - Sidebar sections: pinned / folders / divider / new tab / tabs
    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { pinsExpanded.toggle() } label: {
                HStack(spacing: 9) {
                    Text("📌").frame(width: 18)
                    Text("釘選分頁").fontWeight(.bold)
                    chevron(expanded: pinsExpanded)
                    Spacer(minLength: 0)
                }.padding(8)
            }.buttonStyle(.plain)
            if pinsExpanded {
                ForEach(store.pinnedTabs) { tab in tabRow(tab).padding(.leading, 16) }
            }
        }.font(.system(size: 13.5))
    }

    private func beginFolderNaming() {
        finishFolderNaming()
        store.bookmarkEditorActive = true
        editingFolderID = store.addFolder()
        folderName = "新資料夾"
        focusedField = .folderName
    }

    private func finishFolderNaming() {
        if let id = editingFolderID { store.renameFolder(id, to: folderName) }
        editingFolderID = nil
        store.bookmarkEditorActive = false
    }

    private var folderSection: some View {
        ForEach(store.folders) { folder in
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if editingFolderID == folder.id {
                        HStack(spacing: 9) {
                            Image(systemName: "folder.fill").foregroundStyle(folderFill).frame(width: 18)
                            TextField("資料夾名稱", text: $folderName)
                                .textFieldStyle(.plain).focused($focusedField, equals: .folderName)
                                .onSubmit { finishFolderNaming() }
                                .onExitCommand { editingFolderID = nil; store.bookmarkEditorActive = false }
                                .onAppear { focusedField = .folderName }
                                .onChange(of: focusedField) { _, value in
                                    if value != .folderName { finishFolderNaming() }
                                }
                        }.padding(8)
                    } else {
                        Button { store.toggleFolder(folder.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "folder.fill").foregroundStyle(folderFill).frame(width: 18)
                                HStack(spacing: 2) {
                                    Text(folder.name).fontWeight(.bold)
                                    chevron(expanded: folder.chevronExpanded)
                                }
                                Spacer(minLength: 0)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.font(.system(size: 13.5))
                    .background(targetedFolderID == folder.id ? palette.surfaceBorder : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .contextMenu {
                        Button("新增書籤（目前分頁）") { store.saveBookmark(tabID: store.selectedID, into: folder.id) }
                            .disabled(store.selectedRegistryID == nil)
                    }
                    .dropDestination(for: String.self) { payloads, _ in
                        store.saveDraggedTabs(payloads, into: folder.id)
                    } isTargeted: { targeted in
                        if targeted { targetedFolderID = folder.id }
                        else if targetedFolderID == folder.id { targetedFolderID = nil }
                    }
                if folder.expanded {
                    ForEach(folder.bookmarks) { bookmark in
                        Button { store.openBookmark(bookmark, folderID: folder.id) } label: {
                            HStack(spacing: 9) {
                                favicon(.init(id: 0, title: bookmark.title, url: bookmark.url))
                                Text(bookmark.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }.font(.system(size: 13.5)).padding(8).padding(.leading, 16)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(bookmark.url)
                            .contextMenu {
                                Button("新增書籤（目前分頁）") { store.saveBookmark(tabID: store.selectedID, into: folder.id) }
                                Button("刪除書籤") {
                                    store.deleteBookmark(bookmark.id)
                                    IslandNotice.shared.info(title: "已刪除書籤", detail: "\(bookmark.title)・側欄右鍵可復原", duration: 6)
                                }
                            }
                    }
                }
            }
        }
    }

    private var newTabButton: some View {
        Button { store.addTab(); store.searchFocusRequest += 1 } label: {
            Label("新分頁", systemImage: "plus")
                .font(.system(size: 13.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }.buttonStyle(.plain).disabled(!store.canAddTab)
    }

    private func tabRow(_ tab: BrowserWorkSpaceStore.Tab) -> some View {
        let selected = store.selectedID == tab.id
        return HStack(spacing: 2) {
            BrowserTabRow(variant: .workspace, title: tab.title, favicon: tab.faviconPNG, selected: selected,
                sleeping: tab.sleeping, workspaceIconFill: tab.id.isMultiple(of: 2) ? palette.brandAccent : folderFill,
                workspaceIconForeground: fieldFill, onSelect: { store.select(tab.id) })
            Button { store.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 30)
            }
            .accessibilityLabel("關閉 \(tab.title)")
            .help("關閉分頁")
            .focused($focusedField, equals: .close(tab.id))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tab.sleeping ? .tertiary : .primary)
        .background(selected ? fieldFill : .clear, in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: shadowColor.opacity(selected ? 0.14 : 0), radius: 4, x: 0, y: 2)
        .contextMenu {
            Button("關閉分頁") { store.close(tab.id) }
            Button("重新開啟關閉的分頁", action: store.reopenClosedTab).disabled(!store.canReopenClosedTab)
            Button("註解…") { store.showAnnotations(tab.id) }
        }
        .onHover { hoveredTab = $0 ? tab.id : nil }
        .onDrag { NSItemProvider(object: "tatwo-browser-tab:\(tab.id)" as NSString) }
    }

    private func favicon(_ tab: BrowserWorkSpaceStore.Tab) -> some View {
        Group {
            if let data = tab.faviconPNG, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: "globe").foregroundStyle(.secondary) }
        }
            .font(.system(size: 10, weight: .bold)).foregroundStyle(fieldFill)
            .frame(width: 16, height: 16)
            .background(tab.id.isMultiple(of: 2) ? palette.brandAccent : folderFill,
                        in: RoundedRectangle(cornerRadius: 4))
    }

    private func chevron(expanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(.easeInOut(duration: 0.18), value: expanded)
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }

}
