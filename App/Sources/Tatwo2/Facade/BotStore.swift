import Foundation

/// Bot 模式的 2.0 本地資料。只保存畫面與送訊息需要的欄位，不帶入 1.0 治理型別。
struct BotStoreDocument: Codable, Equatable {
    var spaces: [BotSpaceRecord]
    var bots: [BotRecord]
    var threadIDsByBotID: [String: UUID]
}

struct BotSpaceRecord: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var density: String
    var ownerBotID: String
}

struct BotRecord: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var emoji: String
    var role: String
    var systemPrompt: String
    var defaultEngine: String
    var defaultModel: String?
    var workdir: String
    var parentBotID: String?
    var spaceIDs: [String]
    var isTemporary: Bool
}

/// Compatibility adapter. bots.json is migration input only, never written here.
final class BotStore {
    let library: BotLibrary
    let url: URL
    var document: BotStoreDocument {
        let snapshot = library.snapshot
        let interfaceThreads = Set(snapshot.spaceWorkspace.domains.values
            .flatMap(\.interfaces).map(\.conversationID))
        return BotStoreDocument(spaces: snapshot.spaces, bots: snapshot.bots.map { bot in
            BotRecord(id: bot.id, name: bot.name, emoji: bot.emoji, role: bot.role,
                systemPrompt: snapshot.instructions[bot.id] ?? "", defaultEngine: bot.engine,
                defaultModel: bot.model, workdir: bot.workdir, parentBotID: bot.parentBotID,
                spaceIDs: bot.spaceIDs, isTemporary: bot.isTemporary)
        }, threadIDsByBotID: snapshot.sessions.reduce(into: [:]) { result, pair in
            guard snapshot.loaded, snapshot.spaceWorkspaceError == nil else { return }
            result[pair.key] = pair.value.last(where: {
                guard let id = UUID(uuidString: $0.threadID) else { return false }
                return !interfaceThreads.contains(id)
            })
                .flatMap { UUID(uuidString: $0.threadID) }
        })
    }
    init(root: URL? = nil) {
        let base = root ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/tatwo2/live")
        url = base.appendingPathComponent("bots")
        library = BotLibrary(root: base)
    }
    var spaces: [BotSpaceRecord] { document.spaces }
    var bots: [BotRecord] { document.bots }
    func bot(id: String) -> BotRecord? { bots.first { $0.id == id } }
    func threadID(forBotID botID: String) -> UUID? { document.threadIDsByBotID[botID] }
    func bind(threadID: UUID, toBotID botID: String) {
        guard let bot = library.bot(id: botID) else { return }
        Task { try? await library.recordSession(botID: botID, threadID: threadID.uuidString, engine: bot.engine) }
    }
    @discardableResult
    func createBot(name: String, emoji: String = "🤖", role: String, systemPrompt: String,
        defaultEngine: String = "claude", defaultModel: String? = nil, workdir: String = NSHomeDirectory(),
        parentBotID: String? = nil, spaceIDs: [String] = [], isTemporary: Bool = false) async throws -> BotRecord {
        let bot = BotLibraryRecord(id: "bot-" + UUID().uuidString.lowercased(), name: name, emoji: emoji,
            role: role, engine: defaultEngine, model: defaultModel, workdir: workdir,
            parentBotID: parentBotID, spaceIDs: spaceIDs, isTemporary: isTemporary)
        _ = try await library.create(bot, instructions: systemPrompt)
        return self.bot(id: bot.id)!
    }
    func updateBot(_ old: BotRecord) async throws {
        guard var bot = library.bot(id: old.id) else { throw BotLibraryError.invalid("bot_not_found") }
        bot.name = old.name; bot.emoji = old.emoji; bot.role = old.role; bot.engine = old.defaultEngine
        bot.model = old.defaultModel; bot.workdir = old.workdir; bot.parentBotID = old.parentBotID
        bot.spaceIDs = old.spaceIDs; bot.isTemporary = old.isTemporary
        try await library.update(bot, instructions: old.systemPrompt)
    }
    func createSpace(name: String, density: String, ownerBotID: String) async throws -> BotSpaceRecord {
        guard var bot = library.bot(id: ownerBotID) else { throw BotLibraryError.invalid("bot_not_found") }
        let space = BotSpaceRecord(id: "space-" + UUID().uuidString.lowercased(), name: name, density: density, ownerBotID: ownerBotID)
        bot.spaceIDs.append(space.id)
        try await library.update(bot)
        try await library.saveSpaces(spaces + [space])
        return space
    }

    /// 種子逐項取自 Fixture/BotFixture.swift 的 defaultPrincipals/defaultTempBots。
    private static func fixtureSeed() -> BotStoreDocument {
        let principals = BotPageFixture.defaultPrincipals
        let workdir = NSHomeDirectory()
        let spaces = principals.flatMap { principal in
            principal.spaces.map {
                BotSpaceRecord(
                    id: $0.id,
                    name: $0.name,
                    density: $0.density.rawValue,
                    ownerBotID: principal.id
                )
            }
        }

        var bots: [BotRecord] = []
        for principal in principals {
            bots.append(BotRecord(
                id: principal.id,
                name: principal.name,
                emoji: principal.emoji,
                role: principal.isGroup ? "多人設共識群" : "獨立 bot",
                systemPrompt: systemPrompt(
                    name: principal.name,
                    role: principal.isGroup ? "多人設共識群" : "獨立 bot"
                ),
                defaultEngine: "claude",
                defaultModel: nil,
                workdir: workdir,
                parentBotID: nil,
                spaceIDs: principal.spaces.map(\.id),
                isTemporary: false
            ))
            bots.append(contentsOf: principal.subs.map { sub in
                BotRecord(
                    id: sub.id,
                    name: sub.name,
                    emoji: sub.isConsensusGroup ? "🗂️" : sub.emoji,
                    role: sub.role,
                    systemPrompt: systemPrompt(name: sub.name, role: sub.role),
                    defaultEngine: "claude",
                    defaultModel: nil,
                    workdir: workdir,
                    parentBotID: principal.id,
                    spaceIDs: principal.spaces.map(\.id),
                    isTemporary: false
                )
            })
        }
        bots.append(contentsOf: BotPageFixture.defaultTempBots.map {
            BotRecord(
                id: $0.id,
                name: $0.name,
                emoji: $0.emoji,
                role: $0.task,
                systemPrompt: systemPrompt(name: $0.name, role: $0.task),
                defaultEngine: "claude",
                defaultModel: nil,
                workdir: workdir,
                parentBotID: nil,
                spaceIDs: [],
                isTemporary: true
            )
        })
        return BotStoreDocument(
            spaces: spaces,
            bots: bots,
            threadIDsByBotID: [:]
        )
    }

    private static func systemPrompt(name: String, role: String) -> String {
        """
        你是「\(name)」。你的人設與職責是：\(role)。
        請維持這個角色，直接遵從使用者要求；不要宣稱自己是展示資料。
        """
    }
}
