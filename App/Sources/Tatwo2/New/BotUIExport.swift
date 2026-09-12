import Foundation

/// Explicit bot-live export only: isolated on-disk library, prewritten transcript,
/// no engine send and no user library access.
enum BotUIExport {
    static func prepare() async throws -> ChatPageModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo2-bot-ui-export-" + UUID().uuidString)
        let store = BotStore(root: root)
        await store.library.ready()
        let bot = try await store.library.create(.init(id: "export-live-one", name: "工作 bot",
            emoji: "🤖", role: "general", engine: "codex", workdir: root.path), instructions: "Export fixture")
        _ = try await store.library.create(.init(id: "export-live-two", name: "整理 bot",
            emoji: "📝", role: "general", engine: "codex", workdir: root.path), instructions: "Export fixture")
        let liveStore = ChatLiveStore(root: root)
        let project = LiveProjectRecord(name: "Bot UI fixture", workdir: root.path)
        var thread = LiveThreadRecord(projectID: project.id, title: "Bot 真對話")
        thread.messages = [
            LiveMessageRecord(ChatMessage(id: "bot-ui-user", role: .user, text: "整理今天的工作，列出下一步。")),
            LiveMessageRecord(ChatMessage(id: "bot-ui-assistant", role: .assistant, text: "已整理目前工作。下一步是檢查待辦，並確認尚未完成的項目。"))
        ]
        liveStore.save(.init(projects: [project], threads: [thread], selectedThreadID: thread.id))
        try await store.library.recordSession(botID: bot.id, threadID: thread.id.uuidString, engine: bot.engine,
                                              at: "2026-09-06T00:00:00Z")
        try await BotMemory(library: store.library).updateState(botID: bot.id,
            patch: .init(currentTask: "整理今天的工作", nextSteps: ["檢查待辦", "確認未完成項目"],
                         lastThreadID: thread.id.uuidString))
        return await MainActor.run {
            let live = ChatLiveEngine(store: liveStore)
            let model = ChatPageModel(environment: ["TATWO2_LIVE_ROOT": root.path], botCoreFixture: (live, store))
            // This fixture can display library data but must never start a sidecar.
            model.botSendTestHook = { _, _, _ in }
            return model
        }
    }
}
