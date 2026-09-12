import SwiftUI

struct T2RootView: View {
    @EnvironmentObject var store: T2ThreadStore
    @State private var selection: String?
    @State private var sessions: [String: T2ChatSession] = [:]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.threads) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).lineLimit(1)
                        Text(t.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(t.id)
                }
                .onDelete { idx in idx.map { store.threads[$0].id }.forEach { sessions[$0]?.shutdown(); sessions[$0] = nil; store.delete($0) } }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar { ToolbarItem { Button { newThread() } label: { Image(systemName: "plus") } } }
        } detail: {
            if let id = selection, let s = session(for: id) {
                T2ChatDetail(session: s).id(id)
            } else {
                ContentUnavailableView("選一條討論串，或按 + 開新的", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .onAppear { if selection == nil { selection = store.threads.first?.id } }
    }

    private func session(for id: String) -> T2ChatSession? {
        if let s = sessions[id] { return s }
        guard let t = store.threads.first(where: { $0.id == id }) else { return nil }
        let s = T2ChatSession(thread: t, store: store)
        sessions[id] = s
        return s
    }

    private func newThread() {
        let t = T2ChatThread()
        store.save(t)
        selection = t.id
    }
}

struct T2ChatDetail: View {
    @ObservedObject var session: T2ChatSession
    @State private var draft = ""
    @State private var cwdDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("工作目錄", text: $cwdDraft, onCommit: { session.thread.cwd = cwdDraft })
                    .textFieldStyle(.roundedBorder).font(.caption).disabled(session.thread.sessionId != nil)
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if session.isBusy { ProgressView().controlSize(.small); Button("中斷") { session.interrupt() } }
            }.padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.thread.messages) { m in T2MessageRow(m: m).id(m.id) }
                    }.padding(14)
                }
                .onChange(of: session.thread.messages.last?.text) { _, _ in
                    if let last = session.thread.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let err = session.lastError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).lineLimit(3)
            }
            Divider()
            HStack(alignment: .bottom) {
                TextEditor(text: $draft).frame(minHeight: 40, maxHeight: 140).font(.body)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                Button("送出") { let t = draft; draft = ""; session.send(t) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(10)
        }
        .onAppear { cwdDraft = session.thread.cwd }
        .sheet(item: $session.pendingPermission) { p in
            VStack(alignment: .leading, spacing: 10) {
                Text("工具執行需要核准：\(p.tool)").font(.headline)
                if let d = p.description { Text(d).font(.subheadline) }
                ScrollView { Text(p.inputPretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    .frame(maxHeight: 260)
                HStack { Spacer(); Button("拒絕") { session.answerPermission(allow: false) }; Button("允許") { session.answerPermission(allow: true) }.keyboardShortcut(.defaultAction) }
            }.padding(16).frame(width: 560)
        }
    }
}

struct T2MessageRow: View {
    let m: T2ChatMessage
    var body: some View {
        switch m.role {
        case .user:
            HStack { Spacer(); Text(m.text).textSelection(.enabled).padding(10).background(Color.accentColor.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 10)) }
        case .assistant:
            HStack(alignment: .top) { Text(m.text).textSelection(.enabled); if m.isStreaming { ProgressView().controlSize(.mini) }; Spacer() }
        case .tool:
            Label("\(m.toolName ?? "工具")  \(m.text)", systemImage: "wrench").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
        case .toolResult:
            Text(m.text).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(8).padding(.leading, 20)
        case .system:
            Text(m.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
