import Foundation

/// Isolated headless coverage, reached by TATWO2_BOTCORETEST without any model call.
enum BotNotesAcceptance {
    static func run(root: URL) async throws {
        let library = BotLibrary(root: root); await library.ready()
        let memory = BotMemory(library: library)
        let bot = try await library.create(.init(id: "notes", name: "notes", emoji: "", role: "general", engine: "claude", workdir: root.path), instructions: "fixture")
        let legacy = try JSONDecoder().decode(BotMemoryState.self, from: Data(#"{"currentTask":"legacy","nextSteps":[],"openQuestions":[]}"#.utf8))
        try BotCore2Acceptance.check("notes_legacy_version", legacy.version == 0)
        let first = try await memory.updateState(botID: bot.id, patch: .init(currentTask: "first"), baseVersion: 0)
        let conflict = try await memory.updateState(botID: bot.id, patch: .init(currentTask: "stale"), baseVersion: 0)
        try BotCore2Acceptance.check("notes_conflict_no_overwrite", !first.conflict && first.current.version == 1 && conflict.conflict && conflict.yours?.currentTask == "stale" && memory.state(botID: bot.id)?.currentTask == "first" && memory.state(botID: bot.id)?.version == 1)
        try await memory.updateState(botID: bot.id, patch: .init(currentTask: "unversioned", nextSteps: Array(repeating: "step", count: 8), openQuestions: Array(repeating: "question", count: 8)))
        try BotCore2Acceptance.check("notes_unversioned_event", memory.events(botID: bot.id, last: 1).first?.unversioned == true && memory.state(botID: bot.id)?.version == 2)
        let pending = try await memory.remember(botID: bot.id, text: String(repeating: "字", count: 100), threadID: "fixture")
        let confirmed = try await memory.remember(botID: bot.id, text: "confirmed", threadID: "fixture")
        let rejected = try await memory.remember(botID: bot.id, text: "rejected", threadID: "fixture")
        try await memory.confirm(botID: bot.id, pendingID: confirmed)
        try await memory.reject(botID: bot.id, pendingID: rejected)
        let list = memory.pendingList(botID: bot.id)
        try BotCore2Acceptance.check("notes_pending_three_states", Set(list.map(\.status)) == Set(["pending", "rejected", "confirmed"]) && list.first(where: { $0.id == pending })?.text.count == 80)
        let note = memory.resumeNote(botID: bot.id)
        try BotCore2Acceptance.check("notes_resume_limits", note.nextSteps.count == 5 && note.openQuestions.count == 5 && note.recentEvents.count == 5 && note.pendingCount == 1 && memory.systemPrompt(botID: bot.id).contains(note.summary))
        let reopened = BotLibrary(root: root); await reopened.ready()
        let again = BotMemory(library: reopened)
        try BotCore2Acceptance.check("notes_reopen_persistence", again.state(botID: bot.id) == memory.state(botID: bot.id) && again.pendingList(botID: bot.id) == list && again.resumeNote(botID: bot.id) == note && again.events(botID: bot.id, last: 100).contains { $0.unversioned == true })
        for i in 0..<24 { _ = try await memory.remember(botID: bot.id, text: "limit-\(i)", threadID: "fixture") }
        try BotCore2Acceptance.check("notes_pending_limit", memory.pendingList(botID: bot.id).count == 20)
        // Competing writers use the same serial compare-and-write lane.
        async let a = memory.updateState(botID: bot.id, patch: .init(currentTask: "a"), baseVersion: 2)
        async let b = memory.updateState(botID: bot.id, patch: .init(currentTask: "b"), baseVersion: 2)
        let results = try await [a, b]
        try BotCore2Acceptance.check("notes_concurrent_compare_write", results.filter { $0.conflict }.count == 1 && memory.state(botID: bot.id)?.version == 3)
    }
}
