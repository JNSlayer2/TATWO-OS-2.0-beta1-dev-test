import SwiftUI
import AppKit

private final class GlobalNoteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class GlobalNotePanelModel: ObservableObject {
    @Published var entries: [GlobalNoteStore.Entry] = []
    @Published var hits: [GlobalNoteStore.Hit] = []
    @Published var path = ""
    @Published var text = ""
    @Published var query = ""
    @Published var error = ""
    @Published private(set) var searchError = ""
    @Published var busy = false
    @Published var saving = false
    @Published var jumpLine = 0
    private var original = ""
    private let store: GlobalNoteStore
    private let defaults: UserDefaults
    private var cancellation: GlobalNoteCancellation?
    private var searchTask: Task<Void, Never>?
    let fixture = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
        && ["1", "2"].contains(ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_GLOBAL_NOTE"] ?? "")

    init(store: GlobalNoteStore = GlobalNoteStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    var statusMessage: String {
        [error, searchError].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func load() async {
        if fixture {
            entries = ["工作", "想法", "資料"].map { .init(path: $0, isFolder: true) }
                + ["note.md", "工作/待辦.md", "工作/紀錄.txt", "想法/靈感.md", "資料/參考.txt"].map { .init(path: $0, isFolder: false) }
            path = "note.md"; text = "# 全域筆記\n今天的工作\n記錄重要想法\n待辦事項\n整理參考資料\n下一步\n保留討論重點\n完成後回顧"
            entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            original = text
            return
        }
        busy = true
        defer { busy = false }
        do {
            entries = try await store.perform { s in try s.prepare(); return try s.list() }
            let previous = defaults.string(forKey: "tatwo2.note.lastFile") ?? "note.md"
            let target = entries.contains(where: { $0.path == previous && !$0.isFolder }) ? previous : "note.md"
            text = try await store.perform { try $0.read(target) }; path = target; original = text
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func save() async -> Bool {
        guard !fixture, !path.isEmpty, text != original else { return true }
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        let file = path, content = text, before = original
        do {
            try await store.perform { try $0.save(file, text: content, expected: before) }
            original = content; error = ""; refreshSearch(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func open(_ target: String, line: Int = 0) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        guard await save() else { return }
        do {
            let content = fixture ? text : try await store.perform { try $0.read(target) }
            path = target; text = content; original = content; jumpLine = line
            error = ""
            if !fixture { defaults.set(target, forKey: "tatwo2.note.lastFile") }
        } catch { self.error = error.localizedDescription }
    }
    func move(_ source: String, to target: String, folder: Bool) async {
        let selected: String?
        if path == source {
            selected = target
        } else if folder && path.hasPrefix(source + "/") {
            selected = target + path.dropFirst(source.count)
        } else {
            selected = nil
        }
        await mutate(selecting: selected) { try $0.move(source, to: target, folder: folder) }
    }
    func mutate(selecting target: String? = nil, _ action: @escaping (GlobalNoteStore) throws -> Void) async {
        guard !fixture, !busy else { return }
        busy = true; defer { busy = false }
        guard await save() else { return }
        do {
            entries = try await store.perform { s in try action(s); return try s.list() }
            let preferred = target ?? path
            let selected = entries.contains(where: { $0.path == preferred && !$0.isFolder }) ? preferred : "note.md"
            if selected != path {
                let content = try await store.perform { try $0.read(selected) }
                path = selected; text = content; original = content; jumpLine = 0
            }
            defaults.set(path, forKey: "tatwo2.note.lastFile")
            error = ""; refreshSearch()
        } catch { self.error = error.localizedDescription }
    }
    private func refreshSearch() {
        search()
    }
    func search() {
        cancelSearch()
        hits = []; searchError = ""
        guard !query.isEmpty, !fixture else { return }
        let token = GlobalNoteCancellation(), term = query
        cancellation = token
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                guard !token.cancelled else { return }
                let result = try await store.perform { s in
                    var unreadable = 0
                    let hits = try s.search(term, cancelled: { token.cancelled }, onUnreadable: { _ in unreadable += 1 })
                    return (hits, unreadable)
                }
                guard !token.cancelled else { return }
                hits = result.0
                searchError = result.1 == 0 ? "" : "有 \(result.1) 份筆記無法讀取；其餘搜尋已完成。"
            } catch is CancellationError { }
            catch { if !token.cancelled { searchError = error.localizedDescription } }
        }
    }
    func cancelSearch() { cancellation?.cancel(); searchTask?.cancel() }
}

struct GlobalNotePanel: View {
    @ObservedObject private var feedback = FeedbackCoordinator.shared
    @State private var feedbackCommand = ""
    @StateObject private var model = GlobalNotePanelModel()
    @Binding var isOpen: Bool
    let windowHeight: CGFloat
    let documentOpen: Bool
    @AppStorage("tatwo2.note.stage") private var persistedStage = 1
    @State private var stage = 1
    @State private var command = ""
    @State private var commandPath = ""
    @State private var commandFolder = false
    @State private var name = ""
    @State private var showName = false

    var body: some View {
        ZStack(alignment: documentOpen ? .top : .bottom) {
            Color.clear.contentShape(Rectangle()).onTapGesture { close() }
            LiquidGlassPanelCard(cornerRadius: 14) {
                VStack(spacing: 14) {
                    Capsule().fill(.secondary).frame(width: 46, height: 4)
                        .frame(maxWidth: .infinity).frame(height: 18).contentShape(Rectangle())
                        .accessibilityLabel("拖曳調整全域筆記高度")
                        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                            if value.translation.height < -45 { stage = 2 }
                            if value.translation.height > 45 { stage = 1 }
                            if !model.fixture { persistedStage = stage }
                        })
                    HStack {
                        Text("全域筆記").font(.title3.bold())
                        Spacer()
                        TextField("搜尋", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        Button("存檔") { Task { _ = await model.save() } }.keyboardShortcut("s", modifiers: .command)
                            .disabled(model.busy || model.saving || model.fixture)
                        Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("關閉全域筆記")
                    }
                    HStack(spacing: 12) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.entries) { entry in
                                    Label((entry.path as NSString).lastPathComponent, systemImage: entry.isFolder ? "folder" : "doc.text")
                                        .font(.system(size: 12))
                                        .padding(.leading, entry.path.contains("/") ? 14 : 0)
                                        .padding(5).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(model.path == entry.path ? Color.accentColor.opacity(0.12) : .clear)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { prompt("改名", entry) }
                                        .onTapGesture { if !entry.isFolder { Task { await model.open(entry.path) } } }
                                        .contextMenu { menu(entry) }
                                }
                            }
                        }.frame(width: 220).frame(maxHeight: .infinity).contextMenu { creationMenu("") }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.path).font(.caption).foregroundStyle(.secondary)
                            if !model.query.isEmpty {
                                ScrollView {
                                    LazyVStack(alignment: .leading) {
                                        ForEach(model.hits) { hit in
                                            Button("\(hit.path):\(hit.line)  \(hit.snippet)") {
                                                Task { await model.open(hit.path, line: hit.line) }
                                            }.buttonStyle(.plain).lineLimit(1)
                                        }
                                    }
                                }.frame(maxHeight: 90)
                            }
                            GlobalNoteTextEditor(text: $model.text, line: model.jumpLine, identity: model.path,
                                                 onBlur: { Task { if !model.busy { _ = await model.save() } } })
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .disabled(model.busy || model.saving || model.fixture)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    HStack {
                        TextField("/feedback 回報問題（不附加筆記內容）", text: $feedbackCommand)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { openFeedbackCommand() }
                        Button("回報問題") { feedback.present(source: "全域筆記") }
                    }
                    if !model.statusMessage.isEmpty { Text(model.statusMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(4) // LiquidGlassPanelCard adds 18pt: settings content inset is 22pt.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: max(180, windowHeight * (stage == 2 ? 0.85 : 0.40)))
            .padding(.horizontal, 16)
            .padding(.bottom, documentOpen ? 0 : 8)
            .onTapGesture { } // panel background must not dismiss the overlay
        }
        .sheet(isPresented: feedback.presentation(for: "全域筆記")) { FeedbackSheet(coordinator: feedback) }
        .task {
            stage = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_GLOBAL_NOTE"] == "2" ? 2 : (model.fixture ? 1 : persistedStage)
            await model.load()
        }
        .onChange(of: model.query) { _ in model.search() }
        .onExitCommand { close() }
        .onDisappear { model.cancelSearch() }
        .alert(command, isPresented: $showName) {
            TextField(command == "搬移" ? "目標相對路徑（含檔名）" : "名稱", text: $name)
            Button("取消", role: .cancel) { }
            Button("確定") { execute() }
        }
    }
    private func close() {
        guard !model.busy else { return }
        Task { if await model.save() { isOpen = false } }
    }
    @ViewBuilder private func creationMenu(_ folder: String) -> some View {
        Button("新資料夾") { command = "新資料夾"; commandPath = ""; name = ""; showName = true }
        Button("新文字") { command = "新文字"; commandPath = folder; name = ""; showName = true }
    }
    @ViewBuilder private func menu(_ entry: GlobalNoteStore.Entry) -> some View {
        creationMenu(entry.isFolder ? entry.path : (entry.path as NSString).deletingLastPathComponent)
        Button("改名") { prompt("改名", entry) }.disabled(entry.path == "note.md")
        Button("搬移") { prompt("搬移", entry) }.disabled(entry.isFolder || entry.path == "note.md")
        Button("刪除", role: .destructive) {
            Task { await model.mutate { try $0.trash(entry.path, folder: entry.isFolder) } }
        }.disabled(entry.path == "note.md")
    }
    private func openFeedbackCommand() {
        guard let argument = TatwoSlashCommandParser.feedbackArgument(in: feedbackCommand) else { return }
        if feedback.present(source: "全域筆記", initialText: argument) { feedbackCommand = "" }
    }

    private func prompt(_ action: String, _ entry: GlobalNoteStore.Entry) {
        guard entry.path != "note.md" else { return }
        command = action; commandPath = entry.path; commandFolder = entry.isFolder
        name = action == "搬移" ? entry.path : (entry.path as NSString).lastPathComponent; showName = true
    }
    private func execute() {
        let action = command, source = commandPath, folder = commandFolder, value = name
        Task {
            switch action {
            case "新資料夾":
                await model.mutate { try $0.create(value, folder: true) }
            case "新文字":
                await model.mutate { try $0.create(source.isEmpty ? value : source + "/" + value, folder: false) }
            case "改名":
                let parent = (source as NSString).deletingLastPathComponent
                await model.move(source, to: parent.isEmpty ? value : parent + "/" + value, folder: folder)
            default:
                await model.move(source, to: value, folder: folder)
            }
        }
    }
}

/// Plain NSTextView matches the settings editor's font; the AppKit seam provides exact line jumps.
private struct GlobalNoteTextEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let line: Int
    let identity: String
    let onBlur: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        editor.drawsBackground = false; scroll.drawsBackground = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEnabled
        if editor.string != text { editor.string = text }
        let key = "\(identity):\(line)"
        if context.coordinator.jump != key {
            context.coordinator.jump = key
            if line > 0 {
                let lines = text.components(separatedBy: "\n")
                let offset = lines.prefix(max(0, line - 1)).reduce(0) { $0 + ($1 as NSString).length + 1 }
                let range = NSRange(location: min(offset, (text as NSString).length), length: 0)
                editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GlobalNoteTextEditor
        var jump = ""
        init(_ parent: GlobalNoteTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
        func textDidEndEditing(_ notification: Notification) { parent.onBlur() }
    }
}
