import Foundation

struct T2ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, tool, toolResult, system }
    var id: String = UUID().uuidString
    var role: Role
    var text: String
    var toolName: String? = nil
    var isStreaming: Bool = false
    var createdAt: Date = Date()
}

struct T2ChatThread: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = "新討論串"
    var cwd: String = NSHomeDirectory()
    var engine: String = "claude"
    var sessionId: String? = nil
    var model: String? = nil
    var messages: [T2ChatMessage] = []
    var updatedAt: Date = Date()
}

/// 討論串存成一檔一 JSON，放 Application Support/tatwo2/threads/。沒有 sqlite、沒有 journal。
final class T2ThreadStore: ObservableObject {
    @Published var threads: [T2ChatThread] = []
    let dir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("tatwo2/threads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        threads = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(T2ChatThread.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ t: T2ChatThread) {
        var t = t; t.updatedAt = Date()
        if let i = threads.firstIndex(where: { $0.id == t.id }) { threads[i] = t } else { threads.insert(t, at: 0) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(t) { try? d.write(to: dir.appendingPathComponent(t.id + ".json"), options: .atomic) }
    }

    func delete(_ id: String) {
        threads.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".json"))
    }
}
