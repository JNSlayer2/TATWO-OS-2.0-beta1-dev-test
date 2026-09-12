import Foundation
import Darwin

struct BotLibraryRecord: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var emoji: String
    var role: String
    var engine: String
    var model: String?
    var workdir: String
    var parentBotID: String?
    var spaceIDs: [String] = []
    var isTemporary: Bool = false
    var createdAt: String = BotLibrary.timestamp()
    var updatedAt: String = BotLibrary.timestamp()
    var permissions = BotPermissions()
    var skills: [String] = []
    var version = 1
}

struct BotSessionRecord: Codable, Equatable {
    var threadID: String
    var engine: String
    var startedAt: String
    var lastActiveAt: String
}

struct BotLibrarySnapshot {
    var bots: [BotLibraryRecord] = []
    var instructions: [String: String] = [:]
    var states: [String: BotMemoryState] = [:]
    var profiles: [String: [BotMemoryEntry]] = [:]
    var pending: [String: [BotMemoryCandidate]] = [:]
    var events: [String: [BotMemoryEvent]] = [:]
    var pendingResults: [String: [BotPendingResult]] = [:]
    var sessions: [String: [BotSessionRecord]] = [:]
    var spaces: [BotSpaceRecord] = []
    var spaceWorkspace = SpaceWorkspaceDocument()
    var spaceWorkspaceError: String?
    var lastError: String?
    var loaded = false
}

enum BotLibraryError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let reason): return reason } }
}

/// All filesystem operations execute on this serial queue. Public reads use a locked
/// memory snapshot; callers never wait for disk from the main thread.
final class BotLibrary: @unchecked Sendable {
    let root: URL
    let skillsRoot: URL
    private let queue = DispatchQueue(label: "tatwo2.bot-library", qos: .utility)
    private let lock = NSLock()
    private var cached = BotLibrarySnapshot()
    private var value = BotLibrarySnapshot() // queue-owned working snapshot
    private let fm = FileManager.default
    var snapshot: BotLibrarySnapshot { lock.lock(); defer { lock.unlock() }; return cached }
    var lastError: String? { snapshot.lastError }
    func list() -> [BotLibraryRecord] { snapshot.bots }
    func bot(id: String) -> BotLibraryRecord? { snapshot.bots.first { $0.id == id } }
    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    init(root: URL, skillsRoot: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/tatwo2/skills")) {
        self.root = root; self.skillsRoot = skillsRoot
        queue.async { self.load() }
    }

    private func publish() { lock.lock(); cached = value; lock.unlock() }
    func ready() async { _ = try? await perform { () } }
    func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { let result = try operation(); self.publish(); continuation.resume(returning: result) }
                catch { self.value.lastError = String(describing: error); self.publish(); continuation.resume(throwing: error) }
            }
        }
    }
    private func validID(_ id: String) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"), id.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BotLibraryError.invalid("invalid_bot_id")
        }
    }
    func directory(_ id: String) throws -> URL {
        try validID(id)
        let base = root.appendingPathComponent("bots", isDirectory: true)
        let dir = base.appendingPathComponent(id, isDirectory: true)
        guard dir.resolvingSymlinksInPath().path == base.resolvingSymlinksInPath().appendingPathComponent(id).path else {
            throw BotLibraryError.invalid("bot_directory_symlink_rejected")
        }
        return dir
    }
    private func mkdir(_ url: URL) throws {
        try safeFile(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func safeFile(_ url: URL) throws {
        let base = root.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(base),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw BotLibraryError.invalid("bot_file_symlink_rejected")
        }
    }
    private func validateContent(_ text: String) throws {
        // Never read credentials; reject recognizable secret material at every persisted text boundary.
        // This is a defensive filter, not a claim that arbitrary prose can be classified perfectly.
        let secretPatterns = [
            #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#,
            #"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}"#,
            #"\b(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}"#,
            #"(?i)(?:api[_-]?key|access[_-]?token|client[_-]?secret)\s*[=:]\s*[\"']?[A-Za-z0-9_./+-]{12,}"#,
        ]
        guard !secretPatterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) else {
            throw BotLibraryError.invalid("secret_material_rejected")
        }
    }
    func writeText(_ text: String, to url: URL) throws {
        try safeFile(url)
        try validateContent(text)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw BotLibraryError.invalid("atomic_write_open_failed") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8)); try handle.synchronize(); try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw BotLibraryError.invalid("atomic_write_rename_failed") }
    }
    func write<T: Encodable>(_ object: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeText(String(decoding: encoder.encode(object), as: UTF8.self), to: url)
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try safeFile(url)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func readText(_ url: URL) throws -> String { try safeFile(url); return try String(contentsOf: url, encoding: .utf8) }

    private func load() {
        do {
            try mkdir(root.appendingPathComponent("bots"))
            do { try migrate() } catch { value.lastError = String(describing: error) }
            for dir in try fm.contentsOfDirectory(at: root.appendingPathComponent("bots"), includingPropertiesForKeys: nil) {
                do {
                    _ = try directory(dir.lastPathComponent)
                    let bot = try read(BotLibraryRecord.self, dir.appendingPathComponent("bot.json"))
                    guard bot.id == dir.lastPathComponent, bot.version == 1 else { throw BotLibraryError.invalid("bot_identity_or_version_mismatch") }
                    let instructions = try readText(dir.appendingPathComponent("instructions.md"))
                    let state = try read(BotMemoryState.self, dir.appendingPathComponent("memory/state.json"))
                    let pending = try read([BotMemoryCandidate].self, dir.appendingPathComponent("memory/pending.json"))
                    let profile = try readText(dir.appendingPathComponent("memory/profile.md"))
                    let parsedProfile = BotMemory.parseProfile(profile)
                    guard parsedProfile.count == profile.split(separator: "\n").count else { throw BotLibraryError.invalid("malformed_profile_preserved") }
                    let events = try readText(dir.appendingPathComponent("memory/events.jsonl")).split(separator: "\n").map {
                        try JSONDecoder().decode(BotMemoryEvent.self, from: Data($0.utf8))
                    }
                    let sessions = try read([BotSessionRecord].self, dir.appendingPathComponent("sessions.json"))
                    value.bots.append(bot); value.instructions[bot.id] = instructions
                    value.states[bot.id] = state; value.pending[bot.id] = pending
                    value.profiles[bot.id] = parsedProfile
                    value.events[bot.id] = events; value.sessions[bot.id] = sessions
                    // Old pending events lacked candidate IDs; seed at most 20 old candidates.
                    value.pendingResults[bot.id] = pending.suffix(20).reversed().map {
                        BotPendingResult(id: $0.id, text: String($0.text.prefix(80)), at: $0.at, status: "pending")
                    }
                    for event in events { Self.projectPending(event, into: &value.pendingResults[bot.id, default: []]) }
                } catch { value.lastError = "\(dir.lastPathComponent): \(error)" }
            }
            let spaces = root.appendingPathComponent("bot-spaces.json")
            if fm.fileExists(atPath: spaces.path) { value.spaces = try read([BotSpaceRecord].self, spaces) }
        } catch { value.lastError = String(describing: error) }
        // Load independently: corrupt legacy Bot data must not skip this read and
        // subsequently permit overwriting an existing workspace with defaults.
        let workspace = root.appendingPathComponent("space-workspaces.json")
        do {
            if fm.fileExists(atPath: workspace.path) {
                value.spaceWorkspace = try read(SpaceWorkspaceDocument.self, workspace).validated()
            }
        } catch {
            value.spaceWorkspaceError = String(describing: error)
        }
        value.loaded = true; publish()
    }

    /// Serialized read-modify-write prevents a background result in one domain
    /// from overwriting an intervening edit in another domain.
    func updateSpaceDomain(
        id: String, _ edit: @escaping (inout SpaceDomainRecord) throws -> Void
    ) async throws -> SpaceDomainRecord {
        try await perform {
            guard self.value.spaceWorkspaceError == nil else {
                throw BotLibraryError.invalid("space_document_requires_recovery")
            }
            guard !id.isEmpty else { throw BotLibraryError.invalid("space_id_missing") }
            var next = self.value.spaceWorkspace
            var domain = next.domains[id] ?? SpaceDomainRecord(id: id)
            try edit(&domain)
            next.domains[id] = domain
            _ = try next.validated()
            try self.write(next, to: self.root.appendingPathComponent("space-workspaces.json"))
            self.value.spaceWorkspace = next
            return domain
        }
    }

    func selectWorkspaceDomain(_ id: String) async throws {
        _ = try await perform {
            guard self.value.spaceWorkspaceError == nil,
                  self.value.spaces.contains(where: { $0.id == id }) else {
                throw BotLibraryError.invalid("space_selection_invalid")
            }
            var next = self.value.spaceWorkspace
            next.selectedDomainID = id
            try self.write(next, to: self.root.appendingPathComponent("space-workspaces.json"))
            self.value.spaceWorkspace = next
        }
    }

    /// Reserve once BEFORE creating a Bot/thread. A retry reuses all identities.
    /// The reservation is not a completed/visible work interface.
    func reserveSpaceInterface(spaceID: String, draftID: UUID, name: String) async throws -> SpaceWorkInterfaceRecord {
        let domain = try await updateSpaceDomain(id: spaceID) { domain in
            if domain.interfaces.contains(where: { $0.id == draftID }) { return }
            guard domain.draft.id == draftID,
                  !domain.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BotLibraryError.invalid("space_draft_missing_or_changed")
            }
            if let botID = domain.draft.existingBotID {
                guard self.value.bots.contains(where: { $0.id == botID && $0.spaceIDs.contains(spaceID) }) else {
                    throw BotLibraryError.invalid("space_bot_not_owned")
                }
            }
            domain.interfaces.append(SpaceWorkInterfaceRecord(
                id: draftID, spaceID: spaceID,
                botID: domain.draft.existingBotID ?? "space-bot-\(draftID.uuidString.lowercased())",
                conversationID: UUID(), createsDedicatedBot: domain.draft.existingBotID == nil,
                name: name, initialRequest: domain.draft.text))
        }
        guard let item = domain.interfaces.first(where: { $0.id == draftID }) else {
            throw BotLibraryError.invalid("space_reservation_missing")
        }
        return item
    }

    /// New dedicated Bots are assembled outside the live bot directory. A failed
    /// write leaves only a reservation-owned staging folder, reusable on retry.
    func createSpaceBot(_ input: BotLibraryRecord, reservation: SpaceWorkInterfaceRecord,
                        instructions: String) async throws -> BotLibraryRecord {
        try await perform {
            guard reservation.createsDedicatedBot, input.id == reservation.botID,
                  input.spaceIDs == [reservation.spaceID], input.skills.isEmpty,
                  self.value.spaceWorkspace.domains[reservation.spaceID]?.interfaces
                    .contains(where: { $0.id == reservation.id && $0.botID == input.id }) == true else {
                throw BotLibraryError.invalid("space_bot_reservation_mismatch")
            }
            if let existing = self.value.bots.first(where: { $0.id == input.id }) { return existing }
            let bot = try self.validate(input)
            let target = try self.directory(bot.id)
            guard !self.fm.fileExists(atPath: target.path) else {
                throw BotLibraryError.invalid("space_bot_destination_requires_recovery")
            }
            let stage = self.root.appendingPathComponent("space-bot-staging")
                .appendingPathComponent(reservation.id.uuidString.lowercased())
            try self.mkdir(stage)
            try self.mkdir(stage.appendingPathComponent("memory"))
            try self.mkdir(stage.appendingPathComponent("skills"))
            try self.writeText(instructions, to: stage.appendingPathComponent("instructions.md"))
            try self.writeText("", to: stage.appendingPathComponent("memory/profile.md"))
            try self.write(BotMemoryState(), to: stage.appendingPathComponent("memory/state.json"))
            try self.write([BotMemoryCandidate](), to: stage.appendingPathComponent("memory/pending.json"))
            try self.writeText("", to: stage.appendingPathComponent("memory/events.jsonl"))
            try self.write([BotSessionRecord](), to: stage.appendingPathComponent("sessions.json"))
            try self.write(bot, to: stage.appendingPathComponent("bot.json"))
            try self.fm.moveItem(at: stage, to: target)
            self.value.bots.append(bot); self.value.instructions[bot.id] = instructions
            self.value.states[bot.id] = BotMemoryState(); self.value.pending[bot.id] = []
            self.value.profiles[bot.id] = []; self.value.events[bot.id] = []; self.value.sessions[bot.id] = []
            return bot
        }
    }

    private func migrate() throws {
        let legacy = root.appendingPathComponent("bots.json")
        guard fm.fileExists(atPath: legacy.path) else { return }
        let doc = try read(BotStoreDocument.self, legacy)
        // Never overwrite a pre-existing bot folder (including malformed records).
        // A partial migration retains the legacy file for explicit recovery.
        for old in doc.bots {
            let dir = try directory(old.id)
            guard !fm.fileExists(atPath: dir.path) else { throw BotLibraryError.invalid("migration_destination_exists:\(old.id)") }
        }
        for old in doc.bots {
            var bot = BotLibraryRecord(id: old.id, name: old.name, emoji: old.emoji, role: old.role,
                engine: old.defaultEngine, model: old.defaultModel, workdir: old.workdir,
                parentBotID: old.parentBotID, spaceIDs: old.spaceIDs, isTemporary: old.isTemporary)
            bot = try validate(bot)
            try install(bot, instructions: old.systemPrompt)
            if let thread = doc.threadIDsByBotID[old.id] {
                let now = Self.timestamp()
                try write([BotSessionRecord(threadID: thread.uuidString, engine: bot.engine, startedAt: now, lastActiveAt: now)], to: directory(old.id).appendingPathComponent("sessions.json"))
            }
        }
        try write(doc.spaces, to: root.appendingPathComponent("bot-spaces.json"))
        try fm.moveItem(at: legacy, to: root.appendingPathComponent("bots.json.migrated-\(Self.timestamp().replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8))"))
    }
    private func validate(_ input: BotLibraryRecord) throws -> BotLibraryRecord {
        var bot = input
        try validID(bot.id)
        guard bot.version == 1, ["ask", "auto", "full"].contains(bot.permissions.approval),
              ["claude", "codex", "grok"].contains(bot.engine), bot.workdir.hasPrefix("/"),
              bot.permissions.folders.allSatisfy({ $0.hasPrefix("/") }) else { throw BotLibraryError.invalid("invalid_bot_configuration") }
        if !bot.permissions.allows(path: bot.workdir) { bot.permissions.folders.append(bot.workdir) }
        for skill in bot.skills {
            try validID(skill)
            let dir = skillsRoot.appendingPathComponent(skill)
            guard fm.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) else { throw BotLibraryError.invalid("missing_skill:\(skill)") }
        }
        return bot
    }
    private func install(_ bot: BotLibraryRecord, instructions: String) throws {
        let dir = try directory(bot.id)
        try mkdir(dir); try mkdir(dir.appendingPathComponent("memory")); try mkdir(dir.appendingPathComponent("skills"))
        try writeText(instructions, to: dir.appendingPathComponent("instructions.md"))
        try writeText("", to: dir.appendingPathComponent("memory/profile.md"))
        try write(BotMemoryState(), to: dir.appendingPathComponent("memory/state.json"))
        try write([BotMemoryCandidate](), to: dir.appendingPathComponent("memory/pending.json"))
        try writeText("", to: dir.appendingPathComponent("memory/events.jsonl"))
        try write([BotSessionRecord](), to: dir.appendingPathComponent("sessions.json"))
        try syncSkills(bot)
        try write(bot, to: dir.appendingPathComponent("bot.json"))
    }
    private func syncSkills(_ bot: BotLibraryRecord) throws {
        let dir = try directory(bot.id).appendingPathComponent("skills")
        try safeFile(dir)
        for existing in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where !bot.skills.contains(existing.lastPathComponent) {
            let archive = try directory(bot.id).appendingPathComponent("skills-archive")
            try mkdir(archive)
            try fm.moveItem(at: existing, to: archive.appendingPathComponent(existing.lastPathComponent + "-" + UUID().uuidString))
        }
        for name in Set(bot.skills) {
            let link = dir.appendingPathComponent(name)
            let target = skillsRoot.appendingPathComponent(name).path
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target { continue }
            if (try? fm.attributesOfItem(atPath: link.path)) != nil { throw BotLibraryError.invalid("skill_link_conflict:\(name)") }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        }
    }
    @discardableResult func create(_ input: BotLibraryRecord, instructions: String) async throws -> BotLibraryRecord {
        try await perform {
            let bot = try self.validate(input); let dir = try self.directory(bot.id)
            guard !self.fm.fileExists(atPath: dir.path) else { throw BotLibraryError.invalid("bot_already_exists") }
            try self.install(bot, instructions: instructions)
            self.value.bots.append(bot); self.value.instructions[bot.id] = instructions
            self.value.states[bot.id] = BotMemoryState(); self.value.pending[bot.id] = []
            self.value.profiles[bot.id] = []; self.value.events[bot.id] = []; self.value.sessions[bot.id] = []
            try self.appendEvent(bot.id, kind: "created", summary: "Bot created")
            return bot
        }
    }
    func update(_ input: BotLibraryRecord, instructions: String? = nil) async throws {
        try await perform {
            var bot = try self.validate(input)
            guard let i = self.value.bots.firstIndex(where: { $0.id == bot.id }) else { throw BotLibraryError.invalid("bot_not_found") }
            let old = self.value.bots[i]; bot.createdAt = old.createdAt; bot.updatedAt = Self.timestamp()
            let dir = try self.directory(bot.id)
            try self.syncSkills(bot)
            if let instructions { try self.writeText(instructions, to: dir.appendingPathComponent("instructions.md")); self.value.instructions[bot.id] = instructions }
            try self.write(bot, to: dir.appendingPathComponent("bot.json"))
            self.value.bots[i] = bot
            try self.appendEvent(bot.id, kind: "updated", summary: "Bot configuration, permissions or skills changed", before: String(decoding: JSONEncoder().encode(old), as: UTF8.self), after: String(decoding: JSONEncoder().encode(bot), as: UTF8.self))
        }
    }
    func archive(id: String) async throws {
        try await perform {
            try self.require(id)
            let archive = self.root.appendingPathComponent("bots-archive")
            try self.mkdir(archive)
            try self.appendEvent(id, kind: "archived", summary: "Bot archived")
            try self.fm.moveItem(at: self.directory(id), to: archive.appendingPathComponent(id + "-" + Self.timestamp().replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)))
            self.value.bots.removeAll { $0.id == id }
            self.value.instructions[id] = nil; self.value.states[id] = nil; self.value.profiles[id] = nil
            self.value.pending[id] = nil; self.value.events[id] = nil; self.value.sessions[id] = nil
        }
    }
    func recordSession(botID: String, threadID: String, engine: String, at: String? = nil) async throws {
        try await perform {
            try self.require(botID)
            var sessions = self.value.sessions[botID] ?? []; let now = at ?? Self.timestamp()   // 同一回合完成可傳同一個時間戳，跟 state.lastSessionAt 一致
            if let i = sessions.firstIndex(where: { $0.threadID == threadID && $0.engine == engine }) { sessions[i].lastActiveAt = now }
            else { sessions.append(BotSessionRecord(threadID: threadID, engine: engine, startedAt: now, lastActiveAt: now)) }
            try self.write(sessions, to: self.directory(botID).appendingPathComponent("sessions.json"))
            self.value.sessions[botID] = sessions
        }
    }
    func saveSpaces(_ spaces: [BotSpaceRecord]) async throws {
        try await perform { try self.write(spaces, to: self.root.appendingPathComponent("bot-spaces.json")); self.value.spaces = spaces }
    }
    func require(_ id: String) throws {
        guard value.bots.contains(where: { $0.id == id }) else { throw BotLibraryError.invalid("bot_not_found") }
    }
    func appendEvent(_ id: String, kind: String, summary: String, threadID: String? = nil, tool: String? = nil, before: String? = nil, after: String? = nil, unversioned: Bool? = nil) throws {
        let event = BotMemoryEvent(at: Self.timestamp(), kind: kind, source: .init(threadID: threadID, tool: tool), summary: summary, before: before, after: after, unversioned: unversioned)
        let file = try directory(id).appendingPathComponent("memory/events.jsonl")
        try safeFile(file)
        let encoded = try JSONEncoder().encode(event)
        try validateContent(String(decoding: encoded, as: UTF8.self))
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: encoded + Data([10])); try handle.synchronize()
        value.events[id, default: []].append(event)
        Self.projectPending(event, into: &value.pendingResults[id, default: []])
    }

    private static func projectPending(_ event: BotMemoryEvent, into items: inout [BotPendingResult]) {
        let statuses = ["remember_pending": "pending", "confirmed_by_user": "confirmed", "rejected_by_user": "rejected"]
        guard let status = statuses[event.kind], event.summary.hasPrefix("m-") else { return }
        items.removeAll { $0.id == event.summary }
        items.insert(.init(id: event.summary, text: String((event.after ?? event.before ?? "").prefix(80)), at: event.at, status: status), at: 0)
        items = Array(items.prefix(20))
    }

    // Memory mutations share the same serial transaction lane as configuration writes.
    func memoryChange<T>(_ id: String, _ operation: @escaping (inout BotLibrarySnapshot, URL) throws -> T) async throws -> T {
        try await perform { try self.require(id); let dir = try self.directory(id); var copy = self.value; let result = try operation(&copy, dir); copy.events = self.value.events; copy.pendingResults = self.value.pendingResults; self.value = copy; return result }
    }
}
