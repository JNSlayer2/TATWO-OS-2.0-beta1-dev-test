import SwiftUI

// MARK: - Local fixture model (also compiled directly by the isolated test)
@MainActor
final class BrowserDesignStore: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: Int
        var title: String
        var address: String
        var group: String
    }

    struct Suggestion: Identifiable {
        let id: String
        let section: String
        let title: String
        let tabID: Int?
    }

    @Published private(set) var tabs = [
        Tab(id: 0, title: "新分頁", address: "", group: "個人"),
        Tab(id: 1, title: "靈感筆記", address: "notes.example / inspiration", group: "個人"),
        Tab(id: 2, title: "設計週刊", address: "journal.example / design", group: "閱讀"),
        Tab(id: 3, title: "週末散步", address: "walk.example / collection", group: "閱讀"),
    ]
    @Published private(set) var selectedID = 0
    private var nextID = 4

    var selectedTab: Tab { tabs.first { $0.id == selectedID } ?? tabs[0] }

    func select(_ id: Int) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func addTab() {
        tabs.append(Tab(id: nextID, title: "新分頁", address: "", group: "個人"))
        selectedID = nextID
        nextID += 1
    }

    func close(_ id: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty { addTab() }
        else if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
    }

    func move(_ id: Int, before target: Int) -> Bool {
        guard id != target,
              let source = tabs.firstIndex(where: { $0.id == id }),
              let destination = tabs.firstIndex(where: { $0.id == target })
        else { return false }
        let group = tabs[destination].group
        var moved = tabs.remove(at: source)
        // Dropping across a divider joins that local group.
        moved.group = group
        tabs.insert(moved, at: source < destination ? destination - 1 : destination)
        return true
    }

    func suggestions(for text: String) -> [Suggestion] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [
            Suggestion(id: "history", section: "歷史", title: "昨天的閱讀筆記", tabID: nil),
            Suggestion(id: "tab", section: "已開分頁",
                       title: tabs.first { !$0.address.isEmpty }?.title ?? "新分頁",
                       tabID: tabs.first { !$0.address.isEmpty }?.id ?? selectedID),
            Suggestion(id: "search", section: "搜尋建議", title: "搜尋「\(text)」", tabID: nil),
        ]
    }

    func showPlaceholder(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[index].title = String(trimmed.prefix(64))
        tabs[index].address = "preview.example / local"
    }

    func insertingReference(_ title: String, into draft: String) -> String {
        guard let range = draft.range(of: "@", options: .backwards) else { return draft }
        return draft.replacingCharacters(in: range, with: "[\(title)] ")
    }
}
// MARK: - End local fixture model

struct BrowserWorkSpaceDesignView: View {
    @StateObject private var store = BrowserDesignStore()
    @State private var sidebarExpanded = true
    @State private var aiPresented = false
    @State private var commandsPresented = false
    @State private var query = ""
    @State private var suggestionIndex = 0
    @State private var commandQuery = ""
    @State private var aiDraft = ""
    @State private var messages = [
        "你：這一頁有哪些重點？",
        "AI：先留住靈感，再把閱讀整理成自己的筆記。",
        "AI：這是示範對話，沒有讀取頁面內容。",
    ]
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case address, command, assistant }
    private var palette: TatwoThemePalette { TatwoActivePalette.current }
    private var suggestions: [BrowserDesignStore.Suggestion] { store.suggestions(for: query) }

    var body: some View {
        GeometryReader { geometry in
            let inlineAI = geometry.size.width >= 920
            HStack(spacing: 0) {
                tabSidebar
                    .frame(width: sidebarExpanded ? min(212, geometry.size.width * 0.3) : 40)
                Divider()
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if aiPresented && inlineAI {
                    Divider()
                    assistantPanel.frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                if aiPresented && !inlineAI {
                    ZStack(alignment: .trailing) {
                        palette.canvasBase.opacity(LiquidGlassTokens.nodeCardTintOpacity)
                            .onTapGesture { aiPresented = false }
                        assistantPanel
                            .frame(width: min(300, max(0, geometry.size.width - 40)))
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay {
                if commandsPresented { commandOverlay }
            }
        }
        .background(palette.canvasBase)
        .animation(.easeInOut(duration: 0.2), value: sidebarExpanded)
        .animation(.easeInOut(duration: 0.2), value: aiPresented)
        .onChange(of: store.selectedID) { _, _ in
            query = ""
            suggestionIndex = 0
        }
        .onExitCommand {
            if commandsPresented { dismissCommands() }
            else if aiPresented { aiPresented = false }
            else { query = ""; focusedField = nil }
        }
    }

    private var tabSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            iconButton(sidebarExpanded ? "收合分頁欄" : "展開分頁欄", "sidebar.left") {
                sidebarExpanded.toggle()
            }
            if sidebarExpanded {
                HStack {
                    Text("Browser").font(.headline)
                    Spacer()
                    commandButton
                }
                Text("設計稿：未連線").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                            if index > 0 && store.tabs[index - 1].group != tab.group {
                                Divider().padding(.vertical, 8)
                            }
                            tabRow(tab)
                        }
                    }
                }
                Button { newTab() } label: {
                    Label("新分頁", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            } else {
                commandButton
                Spacer()
                iconButton("新分頁", "plus", action: newTab)
            }
        }
        .padding(sidebarExpanded ? 14 : 4)
        .background(palette.surfaceFill.opacity(LiquidGlassTokens.nodeCardTintOpacity))
    }

    private func tabRow(_ tab: BrowserDesignStore.Tab) -> some View {
        HStack(spacing: 4) {
            Button { store.select(tab.id) } label: {
                HStack(spacing: 9) {
                    Circle().fill(palette.brandAccent.opacity(LiquidGlassTokens.tintOpacity))
                        .frame(width: 18, height: 18)
                    Text(tab.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(store.selectedID == tab.id ? .isSelected : [])
            iconButton("關閉 \(tab.title)", "xmark") { store.close(tab.id) }
        }
        .buttonStyle(.plain)
        .padding(.leading, 9)
        .background(
            palette.brandAccent.opacity(store.selectedID == tab.id ? LiquidGlassTokens.tintOpacity : 0),
            in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip))
        .draggable(String(tab.id))
        .dropDestination(for: String.self) { ids, _ in
            guard let raw = ids.first, let id = Int(raw) else { return false }
            return store.move(id, before: tab.id)
        }
        .contextMenu {
            Button("移到最前") {
                if let first = store.tabs.first { _ = store.move(tab.id, before: first.id) }
            }
            Button("關閉分頁") { store.close(tab.id) }
        }
    }

    private var page: some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 28) {
                        Spacer(minLength: 32)
                        if store.selectedTab.address.isEmpty { startPage }
                        else { placeholderPage }
                        Spacer(minLength: 32)
                    }
                    .frame(maxWidth: 640)
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            Button {
                aiPresented.toggle()
                if aiPresented { focusedField = .assistant }
            } label: {
                Label("問這一頁", systemImage: "sparkles").padding(12)
            }
            .buttonStyle(.plain)
            .background(palette.surfaceFill, in: Capsule())
            .padding(20)
            .accessibilityValue(aiPresented ? "已展開" : "已收合")
        }
    }

    private var startPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("今天，想探索什麼？").font(.system(size: 28, weight: .medium))
                .frame(maxWidth: .infinity).padding(.bottom, 12)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("輸入網址，或直接問", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focusedField, equals: .address)
                    // Return previews the typed query; history requires an explicit selection.
                    .onChange(of: query) { _, _ in suggestionIndex = max(0, suggestions.count - 1) }
                    .onKeyPress(.upArrow) { moveSuggestion(-1) }
                    .onKeyPress(.downArrow) { moveSuggestion(1) }
                    .onSubmit { activateSuggestion() }
                iconButton("開啟本地佔位", "arrow.right") { activateSuggestion() }
            }
            .padding(20)
            .background(palette.surfaceFill, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard))
            .shadow(color: palette.brandAccent.opacity(LiquidGlassTokens.shadowOpacity),
                    radius: LiquidGlassTokens.shadowRadius,
                    x: LiquidGlassTokens.shadowOffsetX, y: LiquidGlassTokens.shadowOffsetY)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || suggestions[index - 1].section != item.section {
                            Text(item.section).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        Button { activateSuggestion(index) } label: {
                            HStack {
                                Text(item.title).lineLimit(1)
                                Spacer()
                                if index == suggestionIndex { Image(systemName: "return") }
                            }
                            .padding(10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            palette.brandAccent.opacity(index == suggestionIndex ? LiquidGlassTokens.tintOpacity : 0),
                            in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip))
                        .accessibilityAddTraits(index == suggestionIndex ? .isSelected : [])
                    }
                }
                .padding(14)
                .background(palette.surfaceFill, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard))
            }
        }
    }

    private var placeholderPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("設計稿：未連線", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
            Text(store.selectedTab.title).font(.largeTitle)
            Text(store.selectedTab.address).font(.caption).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(palette.canvasBase, in: Capsule())
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard)
                .fill(palette.brandAccent.opacity(LiquidGlassTokens.chipFillOpacity))
                .frame(height: 150)
            ForEach(0..<5) { line in
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip)
                    .fill(palette.brandAccent.opacity(LiquidGlassTokens.tintOpacity))
                    .frame(height: 8)
                    .padding(.trailing, line.isMultiple(of: 2) ? 20 : 70)
            }
        }
        .padding(28)
        .background(palette.surfaceFill, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusPrimary))
        .accessibilityElement(children: .combine)
    }

    private var assistantPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("問這一頁").font(.headline)
                Spacer()
                iconButton("收合 AI 面板", "xmark") { aiPresented = false }
            }
            Text(store.selectedTab.title).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(palette.canvasBase, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip))
                    }
                }
            }
            if aiDraft.contains("@") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("引用").font(.caption).foregroundStyle(.secondary)
                    referenceButton("分頁：\(store.selectedTab.title)", symbol: "rectangle.on.rectangle")
                    referenceButton("檔案：靈感筆記.md", symbol: "doc")
                }
                .padding(10)
                .background(palette.canvasBase, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(["摘要", "比較觀點", "列出待辦"], id: \.self) { skill in
                        Button { aiDraft = skill; focusedField = .assistant } label: {
                            Text(skill).font(.caption).padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .background(palette.canvasBase, in: Capsule())
                    }
                }
            }
            HStack {
                TextField("輸入問題，@ 引用", text: $aiDraft)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .assistant)
                    .onSubmit(sendDemoMessage)
                iconButton("送出示範訊息", "arrow.up", action: sendDemoMessage)
                    .disabled(aiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(palette.canvasBase, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip))
            Text("示範對話 · 僅保留於本次畫面").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(palette.surfaceFill)
    }

    private var commandButton: some View {
        Button {
            commandsPresented = true
            commandQuery = ""
            focusedField = .command
        } label: {
            Image(systemName: "command").frame(width: 30, height: 30)
        }
        .buttonStyle(.plain).keyboardShortcut("k", modifiers: .command)
        .help("命令面板 ⌘K").accessibilityLabel("命令面板")
    }

    private var commandOverlay: some View {
        ZStack {
            palette.canvasBase.opacity(LiquidGlassTokens.nodeCardTintOpacity)
                .contentShape(Rectangle()).onTapGesture { dismissCommands() }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("搜尋分頁或動作", text: $commandQuery)
                        .textFieldStyle(.plain).focused($focusedField, equals: .command)
                    iconButton("關閉命令面板", "xmark", action: dismissCommands)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("切換分頁").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.tabs.filter { matchesCommand($0.title) }) { tab in
                            commandRow(tab.title, "rectangle.on.rectangle") { store.select(tab.id) }
                        }
                        Divider()
                        Text("歷史").font(.caption).foregroundStyle(.secondary)
                        if matchesCommand("昨天的閱讀筆記") {
                            commandRow("昨天的閱讀筆記", "clock") { store.showPlaceholder("昨天的閱讀筆記") }
                        }
                        Divider()
                        Text("動作").font(.caption).foregroundStyle(.secondary)
                        if matchesCommand("新分頁") { commandRow("新分頁", "plus", action: newTab) }
                        if matchesCommand("切換分頁欄") {
                            commandRow("切換分頁欄", "sidebar.left") { sidebarExpanded.toggle() }
                        }
                        if matchesCommand("問這一頁") {
                            commandRow("問這一頁", "sparkles") { aiPresented = true }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
            .padding(22).frame(maxWidth: 480)
            .background(palette.surfaceFill, in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard))
            .shadow(color: palette.brandAccent.opacity(LiquidGlassTokens.shadowOpacity),
                    radius: LiquidGlassTokens.shadowRadius,
                    x: LiquidGlassTokens.shadowOffsetX, y: LiquidGlassTokens.shadowOffsetY)
            .padding(24)
        }
    }

    private func commandRow(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button { dismissCommands(); action() } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func matchesCommand(_ title: String) -> Bool {
        commandQuery.isEmpty || title.localizedCaseInsensitiveContains(commandQuery)
    }

    private func dismissCommands() {
        commandsPresented = false
        focusedField = nil
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private func referenceButton(_ title: String, symbol: String) -> some View {
        Button {
            aiDraft = store.insertingReference(title, into: aiDraft)
            focusedField = .assistant
        } label: {
            Label(title, systemImage: symbol).font(.caption).lineLimit(1).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func newTab() {
        store.addTab()
        query = ""
        focusedField = .address
    }

    private func moveSuggestion(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        suggestionIndex = (suggestionIndex + delta + suggestions.count) % suggestions.count
        return .handled
    }

    private func activateSuggestion(_ index: Int? = nil) {
        let selected = index ?? suggestionIndex
        if suggestions.indices.contains(selected) {
            let item = suggestions[selected]
            if let id = item.tabID { store.select(id) }
            else { store.showPlaceholder(item.title) }
        } else {
            store.showPlaceholder(query)
        }
        query = ""
        focusedField = nil
    }

    private func sendDemoMessage() {
        let text = aiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append("你：\(text)")
        messages.append("AI：已收到示範問題。這裡只展示對話排版，沒有執行查詢。")
        aiDraft = ""
    }
}
