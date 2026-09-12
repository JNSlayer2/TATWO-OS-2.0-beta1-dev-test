import Foundation

struct BotMemoryState: Codable, Equatable {
    var version: Int = 0
    var currentTask: String?
    var nextSteps: [String] = []
    var openQuestions: [String] = []
    var lastSessionAt: String?
    var lastThreadID: String?
    enum CodingKeys: String, CodingKey { case version, currentTask, nextSteps, openQuestions, lastSessionAt, lastThreadID }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        currentTask = try c.decodeIfPresent(String.self, forKey: .currentTask)
        nextSteps = try c.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        lastSessionAt = try c.decodeIfPresent(String.self, forKey: .lastSessionAt)
        lastThreadID = try c.decodeIfPresent(String.self, forKey: .lastThreadID)
    }
    var summary: String {
        "上次做到：\(currentTask ?? "無")；下一步：\(nextSteps.joined(separator: "、"))；還沒解決：\(openQuestions.joined(separator: "、"))"
    }
}
struct BotMemoryStatePatch: Codable {
    var currentTask: String?
    var nextSteps: [String]?
    var openQuestions: [String]?
    var lastSessionAt: String?
    var lastThreadID: String?
}
struct BotMemoryCandidate: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var at: String
    var threadID: String
}
struct BotMemoryEntry: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var at: String
    var threadID: String
    var line: String { "- [\(id)] \(text)  <!-- \(at) from \(threadID) -->" }
}
struct BotMemoryEvent: Codable, Equatable {
    struct Source: Codable, Equatable { var threadID: String?; var tool: String? }
    var at: String
    var kind: String
    var source: Source
    var summary: String
    var before: String?
    var after: String?
    var unversioned: Bool? = nil
}

/// App-only confirmation methods are deliberately absent from the MCP tool table.
final class BotMemory {
    let library: BotLibrary
    init(library: BotLibrary) { self.library = library }
    func state(botID: String) -> BotMemoryState? { library.snapshot.states[botID] }
    func profile(botID: String) -> [BotMemoryEntry] { library.snapshot.profiles[botID] ?? [] }
    func events(botID: String, last: Int) -> [BotMemoryEvent] { Array((library.snapshot.events[botID] ?? []).suffix(max(0, last))) }
    static func parseProfile(_ text: String) -> [BotMemoryEntry] {
        text.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("- [m-"), let close = line.range(of: "] "), let meta = line.range(of: "  <!-- ", options: .backwards), line.hasSuffix(" -->"), close.upperBound <= meta.lowerBound else { return nil }
            let id = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let metadata = String(line[meta.upperBound..<line.index(line.endIndex, offsetBy: -4)])
            guard let from = metadata.range(of: " from ") else { return nil }
            return BotMemoryEntry(id: id, text: String(line[close.upperBound..<meta.lowerBound]), at: String(metadata[..<from.lowerBound]), threadID: String(metadata[from.upperBound...]))
        }
    }
    private func singleLine(_ text: String) throws -> String {
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 16_384, !result.contains("\n"), !result.contains("\r"), !result.contains("<!--"), !result.contains("-->") else { throw BotLibraryError.invalid("memory_requires_single_plain_line") }
        return result
    }
    func remember(botID: String, text: String, threadID: String) async throws -> String {
        let text = try singleLine(text); let threadID = try singleLine(threadID)
        return try await library.memoryChange(botID) { snapshot, dir in
            let candidate = BotMemoryCandidate(id: "m-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)), text: text, at: BotLibrary.timestamp(), threadID: threadID)
            var pending = snapshot.pending[botID] ?? []; pending.append(candidate)
            try self.library.write(pending, to: dir.appendingPathComponent("memory/pending.json"))
            snapshot.pending[botID] = pending
            try self.library.appendEvent(botID, kind: "remember_pending", summary: candidate.id, threadID: threadID, tool: "bot_remember", after: text)
            return candidate.id
        }
    }
    func confirm(botID: String, pendingID: String) async throws {
        try await library.memoryChange(botID) { snapshot, dir in
            var pending = snapshot.pending[botID] ?? []
            guard let i = pending.firstIndex(where: { $0.id == pendingID }) else { throw BotLibraryError.invalid("pending_not_found") }
            let candidate = pending.remove(at: i)
            var entries = snapshot.profiles[botID] ?? []
            guard !entries.contains(where: { $0.id == pendingID }) else { throw BotLibraryError.invalid("memory_already_confirmed") }
            entries.append(.init(id: candidate.id, text: candidate.text, at: BotLibrary.timestamp(), threadID: candidate.threadID))
            try self.library.writeText(entries.map(\.line).joined(separator: "\n") + "\n", to: dir.appendingPathComponent("memory/profile.md"))
            try self.library.write(pending, to: dir.appendingPathComponent("memory/pending.json"))
            snapshot.profiles[botID] = entries; snapshot.pending[botID] = pending
            try self.library.appendEvent(botID, kind: "confirmed_by_user", summary: pendingID, threadID: candidate.threadID, after: candidate.text)
        }
    }
    func reject(botID: String, pendingID: String) async throws {
        try await library.memoryChange(botID) { snapshot, dir in
            var pending = snapshot.pending[botID] ?? []
            guard let i = pending.firstIndex(where: { $0.id == pendingID }) else { throw BotLibraryError.invalid("pending_not_found") }
            let candidate = pending.remove(at: i)
            try self.library.write(pending, to: dir.appendingPathComponent("memory/pending.json")); snapshot.pending[botID] = pending
            try self.library.appendEvent(botID, kind: "rejected_by_user", summary: pendingID, before: candidate.text)
        }
    }
    func forget(botID: String, memoryID: String) async throws {
        try await library.memoryChange(botID) { snapshot, dir in
            var entries = snapshot.profiles[botID] ?? []
            guard let i = entries.firstIndex(where: { $0.id == memoryID }) else { throw BotLibraryError.invalid("memory_not_found") }
            let removed = entries.remove(at: i)
            // Record the recoverable before-image before removing the confirmed fact.
            try self.library.appendEvent(botID, kind: "forgotten_by_user", summary: memoryID, before: removed.line)
            try self.library.writeText(entries.map(\.line).joined(separator: "\n") + (entries.isEmpty ? "" : "\n"), to: dir.appendingPathComponent("memory/profile.md"))
            snapshot.profiles[botID] = entries
        }
    }
    @discardableResult func updateState(botID: String, patch: BotMemoryStatePatch, baseVersion: Int? = nil) async throws -> BotStateUpdateResult {
        try await library.memoryChange(botID) { snapshot, dir in
            var state = snapshot.states[botID] ?? BotMemoryState(); let before = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            if let baseVersion, baseVersion != state.version {
                return BotStateUpdateResult(conflict: true, current: state, yours: patch)
            }
            guard state.version < Int.max else { throw BotLibraryError.invalid("state_version_exhausted") }
            state.version += 1
            if let task = patch.currentTask { state.currentTask = task }
            if let steps = patch.nextSteps { state.nextSteps = steps }
            if let questions = patch.openQuestions { state.openQuestions = questions }
            if let at = patch.lastSessionAt { state.lastSessionAt = at }
            if let thread = patch.lastThreadID { state.lastThreadID = thread }
            try self.library.write(state, to: dir.appendingPathComponent("memory/state.json")); snapshot.states[botID] = state
            try self.library.appendEvent(botID, kind: "state_updated", summary: "Session state updated", threadID: patch.lastThreadID, tool: "bot_state_update", before: before, after: String(decoding: try JSONEncoder().encode(state), as: UTF8.self), unversioned: baseVersion == nil ? true : nil)
            return BotStateUpdateResult(conflict: false, current: state, yours: nil)
        }
    }
    func pendingList(botID: String) -> [BotPendingResult] {
        let snapshot = library.snapshot
        return snapshot.pendingResults[botID] ?? []
    }

    func resumeNote(botID: String) -> BotResumeNote {
        let snapshot = library.snapshot
        let state = snapshot.states[botID] ?? BotMemoryState()
        return BotResumeNote(lastSessionAt: state.lastSessionAt, currentTask: state.currentTask.map { String($0.prefix(16384)) }, nextSteps: state.nextSteps.prefix(5).map { String($0.prefix(16384)) }, openQuestions: state.openQuestions.prefix(5).map { String($0.prefix(16384)) }, pendingCount: snapshot.pending[botID]?.count ?? 0, recentEvents: Array((snapshot.events[botID] ?? []).suffix(5)))
    }
    func systemPrompt(botID: String) -> String {
        let snapshot = library.snapshot
        return [snapshot.instructions[botID] ?? "", (snapshot.profiles[botID] ?? []).map(\.line).joined(separator: "\n"), resumeNote(botID: botID).summary].joined(separator: "\n\n")
    }
}
