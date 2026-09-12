// 2.0 真水電：對話資料的存檔格式（JSON，一份文件）。取代 1.0 的 journal／sqlite。
// 畫面吃的仍是 1.0 的 ChatMessage / TatwoNativeChatStoreDocument（在 Facade 的同名薄版），這裡只負責存與讀。
import Foundation

struct LiveMessageRecord: Codable, Equatable {
    var id: String
    var role: String          // user / assistant / system
    var text: String
    var status: String?
    var eventKind: String     // TatwoNativeChatEventKind.rawValue
    var turnID: String?
    var createdAt: Date

    init(_ m: ChatMessage) {
        id = m.id; role = m.role.storageValue; text = m.text; status = m.status
        eventKind = m.eventKind.rawValue; turnID = m.turnID; createdAt = m.createdAt
    }

    var chatMessage: ChatMessage {
        let r: ChatMessageRole = role == "user" ? .user : role == "system" ? .system : .assistant
        return ChatMessage(id: id, role: r, text: text, status: status,
                           eventKind: TatwoNativeChatEventKind(rawValue: eventKind) ?? .message,
                           turnID: turnID, createdAt: createdAt)
    }
}

struct LiveCLITabRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var engine: String
    var cwd: String
    var title: String
}

struct LiveThreadRecord: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var projectID: UUID?
    var title: String = "新聊天"
    var isPinned: Bool = false
    var isArchived: Bool = false
    var sessionID: String?      // 舊欄位（Claude），保留相容
    var sessionIDs: [String: String] = [:]   // 引擎 → session id（claude/codex/grok 各自續接）
    var engine: String?         // 最近用的引擎
    var requestedModel: String?
    var requestedEffort: String?
    var requestedSpeedTier: String?
    var nativeGoal: ChatNativeGoal?
    var model: String?
    var enabledMCP: [String] = []   // 空＝使用該引擎預設全部
    var messages: [LiveMessageRecord] = []
    var issues: [TatwoIssueListEntryV1] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var cliTabs: [LiveCLITabRecord] = []
    var cliTabsUpdatedAt: Date?
    // 2.0 B1/B3：子討論串（sub）欄位；舊 JSON 沒有這些鍵會解成 nil
    var parentThreadID: UUID?
    var roomBrief: String?
    var roomReadOnly: Bool?   // nil/false: existing construction room; true: enforced reviewer runner.
    var lastOutputAt: Date?
    var subStatus: String?   // running / done
    var cwdOverride: String?   // 房間專屬 worktree（E1 派工引擎）；nil 就用專案 workdir
    var botPermissionPreset: TatwoPermissionPreset? // Bot uses the existing native approval enum, not a new permission system.
    var deviceID: String?   // R3：nil＝本機；有值＝從 devices.json 找遠端設備

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        title: String = "新聊天",
        isPinned: Bool = false,
        isArchived: Bool = false,
        sessionID: String? = nil,
        sessionIDs: [String: String] = [:],
        engine: String? = nil,
        model: String? = nil,
        enabledMCP: [String] = [],
        messages: [LiveMessageRecord] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        cliTabs: [LiveCLITabRecord] = [],
        cliTabsUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.sessionID = sessionID
        self.sessionIDs = sessionIDs
        self.engine = engine
        self.model = model
        self.enabledMCP = enabledMCP
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cliTabs = cliTabs
        self.cliTabsUpdatedAt = cliTabsUpdatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, title, isPinned, isArchived, sessionID, sessionIDs, engine, model, enabledMCP
        case messages, createdAt, updatedAt, cliTabs, cliTabsUpdatedAt
        case parentThreadID, roomBrief, roomReadOnly, lastOutputAt, subStatus
        case issues, cwdOverride, deviceID, botPermissionPreset, requestedModel, requestedEffort, requestedSpeedTier, nativeGoal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "新聊天"
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        sessionIDs = try c.decodeIfPresent([String: String].self, forKey: .sessionIDs) ?? [:]
        requestedModel = try c.decodeIfPresent(String.self, forKey: .requestedModel)
        requestedEffort = try c.decodeIfPresent(String.self, forKey: .requestedEffort)
        requestedSpeedTier = try c.decodeIfPresent(String.self, forKey: .requestedSpeedTier)
        nativeGoal = try c.decodeIfPresent(ChatNativeGoal.self, forKey: .nativeGoal)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        enabledMCP = try c.decodeIfPresent([String].self, forKey: .enabledMCP) ?? []
        messages = try c.decodeIfPresent([LiveMessageRecord].self, forKey: .messages) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        cliTabs = try c.decodeIfPresent([LiveCLITabRecord].self, forKey: .cliTabs) ?? []
        cliTabsUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .cliTabsUpdatedAt)
        // 舊 JSON 沒有這些鍵會解成 nil（B1/B3 子討論串欄位；E2 監工要靠它們讀寫活性）
        parentThreadID = try c.decodeIfPresent(UUID.self, forKey: .parentThreadID)
        roomBrief = try c.decodeIfPresent(String.self, forKey: .roomBrief)
        roomReadOnly = try c.decodeIfPresent(Bool.self, forKey: .roomReadOnly)
        lastOutputAt = try c.decodeIfPresent(Date.self, forKey: .lastOutputAt)
        subStatus = try c.decodeIfPresent(String.self, forKey: .subStatus)
        issues = try c.decodeIfPresent([TatwoIssueListEntryV1].self, forKey: .issues) ?? []
        cwdOverride = try c.decodeIfPresent(String.self, forKey: .cwdOverride)
        botPermissionPreset = try c.decodeIfPresent(TatwoPermissionPreset.self, forKey: .botPermissionPreset)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
    }
}

struct LiveProjectRecord: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var workdir: String
    var isExpanded: Bool = true
    var githubRepos: [String] = []

    init(
        id: UUID = UUID(),
        name: String,
        workdir: String,
        isExpanded: Bool = true,
        githubRepos: [String] = []
    ) {
        self.id = id
        self.name = name
        self.workdir = workdir
        self.isExpanded = isExpanded
        self.githubRepos = githubRepos
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, workdir, isExpanded, githubRepos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "一般"
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir) ?? NSHomeDirectory()
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        githubRepos = try c.decodeIfPresent([String].self, forKey: .githubRepos) ?? []
    }
}

struct LiveDocumentRecord: Codable, Equatable {
    var projects: [LiveProjectRecord] = []
    var threads: [LiveThreadRecord] = []
    var selectedThreadID: UUID?
    // Explicit identity: an existing user project called "一般" is still a
    // project. Older documents decode this optional field as nil.
    var generalProjectID: UUID?

    mutating func ensureGeneralProject() -> UUID {
        if let id = generalProjectID, projects.contains(where: { $0.id == id }) { return id }
        let project = LiveProjectRecord(name: "一般", workdir: NSHomeDirectory())
        projects.append(project)
        generalProjectID = project.id
        return project.id
    }

    mutating func prepareChatHierarchy() {
        if projects.isEmpty { _ = ensureGeneralProject() }
        let ids = Set(projects.map(\.id))
        let orphaned = threads.indices.filter { index in
            guard let id = threads[index].projectID else { return true }
            return !ids.contains(id)
        }
        // Previously these records disappeared from the UI. Their engine
        // workdir already fell back to HOME; retain messages and overrides.
        if !orphaned.isEmpty {
            let id = ensureGeneralProject()
            for index in orphaned { threads[index].projectID = id }
        }
    }
}

/// 一份 JSON 放 Application Support/tatwo2/live/document.json。寫入用 atomic，讀不到就給空文件。
final class ChatLiveStore {
    let url: URL
    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tatwo2/live", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("document.json")
    }

    func load() -> LiveDocumentRecord {
        guard let data = try? Data(contentsOf: url) else { return LiveDocumentRecord() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(LiveDocumentRecord.self, from: data)) ?? LiveDocumentRecord()
    }

    /// Pasted images belong to the same persistent store as their transcript,
    /// not the system temporary directory. Never overwrite an existing file.
    func saveAttachment(data: Data, suggestedName: String) throws -> URL {
        let name = (suggestedName as NSString).lastPathComponent
        let safeName = name.isEmpty || name == "." || name == ".." ? "圖片.png" : name
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: target, options: .atomic)
        return target
    }

    func save(_ doc: LiveDocumentRecord) {
        try? saveChecked(doc, verify: false)
    }

    func saveChecked(_ doc: LiveDocumentRecord, verify: Bool = true) throws {
        var merged = doc
        let existing = load()
        for index in merged.threads.indices {
            guard
                let old = existing.threads.first(where: { $0.id == merged.threads[index].id }),
                let oldDate = old.cliTabsUpdatedAt,
                oldDate > (merged.threads[index].cliTabsUpdatedAt ?? .distantPast)
            else { continue }
            merged.threads[index].cliTabs = old.cliTabs
            merged.threads[index].cliTabsUpdatedAt = oldDate
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(merged)
        try data.write(to: url, options: .atomic)
        if verify {
            guard try Data(contentsOf: url) == data else {
                throw BotLibraryError.invalid("chat_store_write_verification_failed")
            }
        }
    }

    func cliTabs(threadID: UUID) -> [LiveCLITabRecord] {
        load().threads.first(where: { $0.id == threadID })?.cliTabs ?? []
    }

    func updateCLITabs(threadID: UUID, tabs: [LiveCLITabRecord]) {
        var doc = load()
        guard let index = doc.threads.firstIndex(where: { $0.id == threadID }) else { return }
        doc.threads[index].cliTabs = tabs
        doc.threads[index].cliTabsUpdatedAt = Date()
        save(doc)
    }
}
