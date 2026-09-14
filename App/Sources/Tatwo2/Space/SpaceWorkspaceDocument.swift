import Foundation

/// Durable ownership, independent of whichever window/domain is currently selected.
/// This document lives beside the existing Bot library; it contains references, not
/// copied transcripts or a second chat engine.
struct SpaceWorkspaceDocument: Codable, Equatable {
    var version = 1
    var selectedDomainID: String?
    var domains: [String: SpaceDomainRecord] = [:]

    func validated() throws -> Self {
        guard version == 1 else { throw BotLibraryError.invalid("space_version_unsupported") }
        var interfaceIDs = Set<UUID>()
        var conversations = Set<UUID>()
        for (key, domain) in domains {
            guard key == domain.id, !key.isEmpty,
                  Set(domain.tabOrder) == domain.declaredTabs,
                  domain.tabOrder.count == domain.declaredTabs.count,
                  domain.disabledTabs.isSubset(of: domain.declaredTabs),
                  (domain.customTabs ?? [:]).keys.allSatisfy({
                      !$0.isEmpty && !SpaceManagedTab.allCases.map(\.modeRawValue).contains($0)
                          && !SpaceManagedTab.allCases.map(\.rawValue).contains($0)
                  }) else {
                throw BotLibraryError.invalid("space_identity_or_tab_order_invalid")
            }
            for item in domain.interfaces {
                guard item.spaceID == key, !item.botID.isEmpty,
                      interfaceIDs.insert(item.id).inserted,
                      conversations.insert(item.conversationID).inserted else {
                    throw BotLibraryError.invalid("space_interface_ownership_invalid")
                }
            }
            let ownedInterfaces = Set(domain.interfaces.map(\.id))
            for (requestKey, request) in domain.followupRequests ?? [:] {
                guard UUID(uuidString: requestKey) == request.interfaceID,
                      ownedInterfaces.contains(request.interfaceID) else {
                    throw BotLibraryError.invalid("space_followup_ownership_invalid")
                }
            }
            for draftKey in (domain.conversationDrafts ?? [:]).keys {
                guard let interfaceID = UUID(uuidString: draftKey),
                      ownedInterfaces.contains(interfaceID) else {
                    throw BotLibraryError.invalid("space_conversation_draft_ownership_invalid")
                }
            }
        }
        return self
    }
}

/// A top-level work space identity, not a Bot sidebar bot space.
struct SpaceManagedTab: RawRepresentable, Codable, CaseIterable, Hashable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    static let chat = Self(rawValue: "chat")!
    static let cli = Self(rawValue: "cli")!
    static let bot = Self(rawValue: "bot")!
    static let browser = Self(rawValue: "browser")!
    static let allCases: [Self] = [.chat, .cli, .bot, .browser]
    var modeRawValue: String {
        switch self {
        case .chat: "Chat"
        case .cli: "CLI"
        case .bot: "Bot"
        case .browser: "Browser"
        default: rawValue
        }
    }
    init?(modeRawValue: String) {
        if let builtin = Self.allCases.first(where: { $0.modeRawValue == modeRawValue }) {
            self = builtin
        } else { self.init(rawValue: modeRawValue) }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty work space ID")
        }
        self = value
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct SpaceDomainRecord: Codable, Equatable {
    let id: String
    var tabOrder = SpaceManagedTab.allCases
    // Missing legacy settings use this default domain, leaving all original tabs on.
    var disabledTabs: Set<SpaceManagedTab> = []
    var draft = SpaceBuilderDraft()
    var interfaces: [SpaceWorkInterfaceRecord] = []
    var selectedInterfaceID: UUID?
    var conversationDrafts: [String: String]? = [:]
    var followupRequests: [String: SpaceFollowupRequest]? = [:]
    // Additive metadata for unbuilt work spaces; no Bot or conversation is created by +add.
    var customTabs: [String: String]? = [:]
    var declaredTabs: Set<SpaceManagedTab> {
        Set(SpaceManagedTab.allCases + (customTabs ?? [:]).keys.compactMap { SpaceManagedTab(rawValue: $0) })
    }

    init(id: String) { self.id = id }
    private enum CodingKeys: String, CodingKey {
        case id, tabOrder, disabledTabs, draft, interfaces, selectedInterfaceID
        case conversationDrafts, followupRequests, customTabs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tabOrder = try c.decodeIfPresent([SpaceManagedTab].self, forKey: .tabOrder) ?? []
        // Legacy three-tab documents append newly introduced builtins, preserving order.
        for tab in SpaceManagedTab.allCases where !tabOrder.contains(tab) { tabOrder.append(tab) }
        disabledTabs = try c.decodeIfPresent(Set<SpaceManagedTab>.self, forKey: .disabledTabs) ?? []
        draft = try c.decodeIfPresent(SpaceBuilderDraft.self, forKey: .draft) ?? SpaceBuilderDraft()
        interfaces = try c.decodeIfPresent([SpaceWorkInterfaceRecord].self, forKey: .interfaces) ?? []
        selectedInterfaceID = try c.decodeIfPresent(UUID.self, forKey: .selectedInterfaceID)
        conversationDrafts = try c.decodeIfPresent([String: String].self, forKey: .conversationDrafts)
        followupRequests = try c.decodeIfPresent([String: SpaceFollowupRequest].self, forKey: .followupRequests)
        customTabs = try c.decodeIfPresent([String: String].self, forKey: .customTabs) ?? [:]
    }
}

struct SpaceFollowupRequest: Codable, Equatable {
    let id: UUID
    let interfaceID: UUID
    let text: String
    var status: SpaceWorkInterfaceRecord.Submission
}

struct SpaceBuilderDraft: Codable, Equatable {
    // Stable while submission fails/retries. Opening/cancelling creates no Bot.
    var id = UUID()
    var text = ""
    var existingBotID: String?

    var interfaceName: String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for (index, line) in lines.enumerated() where line.hasPrefix("【名稱】") {
            let inline = String(line.dropFirst("【名稱】".count))
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "：:")))
            if !inline.isEmpty { return String(inline.prefix(80)) }
            if lines.indices.contains(index + 1), !lines[index + 1].hasPrefix("【") {
                return String(lines[index + 1].prefix(80))
            }
            return "工作介面"
        }
        return String((lines.first(where: {
            !$0.hasPrefix("【") && !$0.hasPrefix("請協助我在目前 Space")
                && !$0.hasPrefix("請協助我在目前 work space")
        }) ?? "工作介面").prefix(80))
    }
}

/// A built custom work space and its owned builder conversation.
struct SpaceWorkInterfaceRecord: Codable, Equatable, Identifiable {
    enum Submission: String, Codable { case prepared, dispatching, accepted, failed, recoveryRequired }
    let id: UUID
    let spaceID: String
    let botID: String
    let conversationID: UUID
    let createsDedicatedBot: Bool
    var name: String
    var initialRequest: String
    var submission: Submission = .prepared
    var lastError: String?
}
