import Foundation

/// 把 sidecar 的 SDK 事件收斂成畫面上的訊息列。一條討論串一個 session；sidecar 活著就不重開。
@MainActor
final class T2ChatSession: ObservableObject {
    struct PermissionRequest: Identifiable {
        let id: String; let tool: String; let input: [String: Any]; let title: String?; let description: String?
        var inputPretty: String {
            (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(input)"
        }
    }

    @Published var thread: T2ChatThread
    @Published var isBusy = false
    @Published var pendingPermission: PermissionRequest?
    @Published var lastError: String?
    @Published var status: String = "未連線"

    private let store: T2ThreadStore
    private var sidecar: ClaudeSidecar?
    private var streamingId: String?

    init(thread: T2ChatThread, store: T2ThreadStore) {
        self.thread = thread
        self.store = store
    }

    private func ensureSidecar() {
        if let s = sidecar, s.isRunning { return }
        let s = ClaudeSidecar()
        s.onEvent = { [weak self] e in self?.handle(e) }
        do {
            try s.start(cwd: thread.cwd, resume: thread.sessionId, model: thread.model)
            sidecar = s
            status = thread.sessionId == nil ? "啟動中" : "續接 session"
        } catch {
            lastError = "sidecar 啟動失敗：\(error.localizedDescription)"
        }
    }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        ensureSidecar()
        if thread.messages.isEmpty { thread.title = String(t.prefix(24)) }
        thread.messages.append(T2ChatMessage(role: .user, text: t))
        isBusy = true
        sidecar?.send(text: t, uuid: UUID().uuidString)
        persist()
    }

    func interrupt() { sidecar?.interrupt() }
    func answerPermission(allow: Bool) {
        guard let p = pendingPermission else { return }
        sidecar?.respondPermission(id: p.id, allow: allow)
        thread.messages.append(T2ChatMessage(role: .system, text: (allow ? "允許 " : "拒絕 ") + p.tool))
        pendingPermission = nil
    }
    func shutdown() { sidecar?.close(); sidecar = nil; status = "已關閉" }

    private func persist() { store.save(thread) }

    private func appendStreaming(_ delta: String) {
        if let id = streamingId, let i = thread.messages.firstIndex(where: { $0.id == id }) {
            thread.messages[i].text += delta
        } else {
            let m = T2ChatMessage(role: .assistant, text: delta, isStreaming: true)
            streamingId = m.id
            thread.messages.append(m)
        }
    }

    private func endStreaming() {
        if let id = streamingId, let i = thread.messages.firstIndex(where: { $0.id == id }) {
            thread.messages[i].isStreaming = false
        }
        streamingId = nil
    }

    private func handle(_ e: ClaudeSidecar.Event) {
        switch e {
        case .permission(let id, let tool, let input, let title, let description):
            pendingPermission = PermissionRequest(id: id, tool: tool, input: input, title: title, description: description)
        case .stderr(let s):
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { status = String(s.prefix(120)) }
        case .error(let s):
            lastError = s; isBusy = false
        case .closed:
            isBusy = false; status = "sidecar 已結束"; endStreaming()
        case .sdk(let m):
            handleSDK(m)
        }
    }

    private func handleSDK(_ m: [String: Any]) {
        let type = m["type"] as? String ?? ""
        switch type {
        case "system":
            if m["subtype"] as? String == "init", let sid = m["session_id"] as? String {
                thread.sessionId = sid
                if let model = m["model"] as? String { thread.model = model }
                status = "已連線 \(m["model"] as? String ?? "")"
                persist()
            }
        case "stream_event":
            guard let ev = m["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_delta",
               let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta",
               let t = d["text"] as? String { appendStreaming(t) }
            if ev["type"] as? String == "content_block_stop" { endStreaming() }
        case "assistant":
            guard let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for b in content where b["type"] as? String == "tool_use" {
                let name = b["name"] as? String ?? "?"
                let input = b["input"] as? [String: Any] ?? [:]
                let summary = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["pattern"] as? String) ?? (input["description"] as? String) ?? ""
                thread.messages.append(T2ChatMessage(role: .tool, text: summary, toolName: name))
            }
        case "user":
            guard let msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for b in content where b["type"] as? String == "tool_result" {
                var text = ""
                if let s = b["content"] as? String { text = s }
                else if let arr = b["content"] as? [[String: Any]] { text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                let short = text.count > 600 ? String(text.prefix(600)) + "…" : text
                thread.messages.append(T2ChatMessage(role: .toolResult, text: short))
            }
        case "result":
            endStreaming(); isBusy = false
            if m["is_error"] as? Bool == true { lastError = m["result"] as? String }
            status = "完成"
            persist()
        default: break
        }
    }
}
