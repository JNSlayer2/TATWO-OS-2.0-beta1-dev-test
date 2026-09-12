import Foundation

/// UI projection only. Library snapshots are memory reads; writes use its async queue.
@MainActor
enum BotUIWire {
    static var isLive: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil,
           ChatPageModel.exportChatScene == "bot-live" { return true }
        return env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] == nil
            && env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] == nil
    }

    static func project(_ snapshot: BotLibrarySnapshot) -> BotPageFixture {
        let bots = snapshot.bots
        func sub(_ bot: BotLibraryRecord) -> BotFixtureSub {
            .init(id: bot.id, name: bot.name, role: bot.role, emoji: bot.emoji,
                  permissionBrief: bot.permissions.approval,
                  workStatus: snapshot.states[bot.id]?.currentTask ?? "待命中")
        }
        func spaces(_ bot: BotLibraryRecord) -> [BotFixtureSpace] {
            let known = snapshot.spaces.filter { $0.ownerBotID == bot.id || bot.spaceIDs.contains($0.id) }
                .map { .init(id: $0.id, name: $0.name,
                             density: BotFixtureDensity(rawValue: $0.density) ?? .compact) as BotFixtureSpace }
            return known + bot.spaceIDs.filter { id in !known.contains { $0.id == id } }
                .map { .init(id: $0, name: $0, density: .compact) }
        }
        var principals: [BotFixturePrincipal] = []
        // Keep parent relationships, including intermediate parents as their own rows.
        let parents = Set(bots.compactMap(\.parentBotID))
        for bot in bots where parents.contains(bot.id) || !bot.spaceIDs.isEmpty
            || snapshot.spaces.contains(where: { $0.ownerBotID == bot.id }) {
            let children = bots.filter { $0.parentBotID == bot.id }
            principals.append(.init(id: bot.id, name: bot.name, kind: .bot, emoji: bot.emoji,
                subs: children.map(sub), spaces: spaces(bot), sharedSandbox: false,
                permissionBrief: bot.permissions.approval,
                workStatus: snapshot.states[bot.id]?.currentTask ?? "待命中"))
        }
        for parentID in parents.sorted() where !bots.contains(where: { $0.id == parentID }) {
            principals.append(.init(id: "ui-parent:" + parentID, name: parentID, kind: .bot,
                emoji: "📁", subs: bots.filter { $0.parentBotID == parentID }.map(sub),
                spaces: [], sharedSandbox: false))
        }
        // Space membership is not inferred from names or merged with fixture IDs.
        for space in snapshot.spaces {
            let members = bots.filter { $0.spaceIDs.contains(space.id) }
            guard !members.isEmpty else { continue }
            principals.append(.init(id: "ui-space:" + space.id, name: space.name, kind: .bot,
                emoji: "📁", subs: members.map(sub),
                spaces: [.init(id: space.id, name: space.name,
                               density: BotFixtureDensity(rawValue: space.density) ?? .compact)],
                sharedSandbox: false))
        }
        let represented = Set(principals.flatMap { [$0.id] + $0.subs.map(\.id) })
        // Invalid/missing parent or space references remain visible, not silently lost.
        let remaining = bots.filter { !represented.contains($0.id) }
        if !remaining.isEmpty {
            principals.append(.init(id: "ui-ungrouped", name: "未分組", kind: .bot, emoji: "📁",
                subs: remaining.map(sub), spaces: [], sharedSandbox: false))
        }
        return .init(principals: principals, selectedPrincipalID: nil, selectedSubID: nil,
            selectedSpaceID: nil, expandedPrincipalIDs: [], thread: [], permissionRows: [])
    }
}

@MainActor
enum BotUILiveCache {
    /// 產出索引是 actor，畫面不能同步讀；由 observe 迴圈更新這份快取（botID → 相對路徑）。
    static var outputFiles: [String: [String]] = [:]
    static var lastRevision: [ObjectIdentifier: String] = [:]
}

@MainActor
extension BotPageState {
    var liveSource: ChatPageModel.BotUISource {
        guard usesLiveBots, let id = pocketBotKey, let model = CLISessionsTermination.model else { return .init() }
        return model.botSourceForUI(botID: id)
    }
    var liveIssueTitles: [String] { liveSource.issues }
    /// 這隻 bot 的真實核准檔位（bot.json permissions.approval），只投影不可改；沒有就 nil
    var liveApprovalLabel: String? {
        guard usesLiveBots, let id = pocketBotKey, let bot = CLISessionsTermination.model?.botLibraryForBridge?.bot(id: id) else { return nil }
        switch bot.permissions.approval { case "auto": return "代我核准"; case "full": return "全權"; default: return "先問我" }
    }
    var liveOutputFiles: [String] { pocketBotKey.flatMap { BotUILiveCache.outputFiles[$0] } ?? [] }
    /// 這一輪畫面會用到的全部 live 資料摘要；相同就不通知（review：250ms 無條件重繪違反輕量）
    var liveRevisionKey: String {
        let f = fixture
        // 涵蓋 id／名字／emoji／檔位／狀態／space（review：只比 status 不會抓到改名、換頭貼、換 space、換權限）
        func sig(_ id: String, _ name: String, _ emoji: String, _ status: String?, _ perm: String?, _ spaces: [String]) -> String { [id, name, emoji, status ?? "", perm ?? "", spaces.joined(separator: "+")].joined(separator: ":") }
        let principals = f.principals.map { p in sig(p.id, p.name, p.emoji, p.workStatus, p.permissionBrief, p.spaces.map(\.id)) + "|" + p.subs.map { sig($0.id, $0.name, $0.emoji, $0.workStatus, $0.permissionBrief, []) }.joined(separator: ",") }.joined(separator: ";")
        let src = liveSource
        return [principals, String(liveThread.count), liveThread.last?.text ?? "", liveNoteRevision, src.project ?? "", src.thread ?? "", src.issues.joined(separator: ","), liveOutputFiles.joined(separator: ","), liveComposerStatus].joined(separator: "#")
    }
    func isLiveLibraryBot(_ id: String) -> Bool {
        usesLiveBots && CLISessionsTermination.model?.botLibraryForBridge?.bot(id: id) != nil
    }
    var liveFixture: BotPageFixture {
        var snapshot = CLISessionsTermination.model?.botLibraryForBridge?.snapshot ?? .init()
        if let id = SpaceWorkspaceController.shared.selectedDomainID {
            let owner = snapshot.spaces.first(where: { $0.id == id })?.ownerBotID
            snapshot.bots = snapshot.bots.filter { $0.spaceIDs.contains(id) || $0.id == owner }
                .map { bot in var owned = bot; owned.spaceIDs = [id]; return owned }
            snapshot.spaces = snapshot.spaces.filter { $0.id == id }
        }
        return BotUIWire.project(snapshot)
    }
    var liveThread: [BotFixtureMessage] {
        guard let id = pocketBotKey, let model = CLISessionsTermination.model,
              let bot = model.botLibraryForBridge?.bot(id: id) else { return [] }
        return model.botTranscriptForUI(botID: id).map {
            .init(id: $0.id, author: $0.role == .user ? .user : .bot(name: bot.name), text: $0.text)
        }
    }
    var liveComposerStatus: String {
        CLISessionsTermination.model?.composerHint ?? "對話使用 bot 的權限與設定"
    }
    var liveNoteRevision: String {
        guard usesLiveBots, let id = pocketBotKey,
              let library = CLISessionsTermination.model?.botLibraryForBridge else { return "fixture" }
        let note = BotMemory(library: library).resumeNote(botID: id)
        return id + "|" + String(describing: note)
    }
    func observeLiveBots() async {
        guard usesLiveBots else { return }
        if ChatPageModel.exportChatScene == "bot-live",
           ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil {
            do {
                let model = try await Task.detached { try await BotUIExport.prepare() }.value
                installExportModel(model)
            } catch { return }
        }
        while !Task.isCancelled {
            // 先更新產出檔快取（actor，非同步），再比較摘要，有變更才通知
            if let id = pocketBotKey, let model = CLISessionsTermination.model,
               let tid = model.botSourceForUI(botID: id).threadID, let engine = model.live as? ChatLiveEngine {
                let artifacts = engine.turnArtifacts
                let files = (try? await artifacts.list(threadID: tid))?.artifacts.filter { !$0.outside }.map(\.path) ?? []
                if BotUILiveCache.outputFiles[id] != files { BotUILiveCache.outputFiles[id] = files }
            }
            let key = liveRevisionKey
            if BotUILiveCache.lastRevision[ObjectIdentifier(self)] != key {
                BotUILiveCache.lastRevision[ObjectIdentifier(self)] = key
                refreshLiveBots()
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
    }
    @discardableResult
    func sendComposer(_ text: String, botID: String? = nil) -> Bool {
        // 空白 Enter 不算送出，也不要閃「未送出」提示（真視窗 lab 2026-09-06 抓到的誤導提示）。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard usesLiveBots, let model = CLISessionsTermination.model else { return false }
        guard let id = botID ?? pocketBotKey, model.botLibraryForBridge?.bot(id: id) != nil else {
            model.flashComposerHint("這是展示資料，先 create bot")
            objectWillChange.send()
            return false
        }
        guard model.sendAsBot(botID: id, text: text) != nil else {
            if model.composerHint == nil { model.flashComposerHint("未送出，請確認本機 bot 與對話狀態") }
            objectWillChange.send()
            return false
        }
        refreshLiveBots()
        return true
    }
    @discardableResult
    func createLiveBot() async -> String? {
        guard usesLiveBots, let model = CLISessionsTermination.model,
              let library = model.botLibraryForBridge else { return nil }
        let cwd = model.selectedThreadProject?.workdir
        guard let cwd, !cwd.isEmpty else {
            model.flashComposerHint("請先選擇目前專案，再 create bot")
            objectWillChange.send()
            return nil
        }
        do {
            let bot = try await library.create(.init(id: "bot-" + UUID().uuidString.lowercased(),
                name: "新 bot \(library.snapshot.bots.count + 1)", emoji: "🤖", role: "general",
                engine: "codex", workdir: cwd), instructions: "")
            refreshLiveBots()
            if let owner = ownerOfSub(bot.id) { selectSub(bot.id, of: owner.owner.id) }
            else { selectPrincipal(bot.id) }
            return bot.id
        } catch {
            model.flashComposerHint("create bot 失敗：\(error)")
            objectWillChange.send()
            return nil
        }
    }
}
