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
                  Set(domain.tabOrder) == Set(SpaceManagedTab.allCases),
                  domain.tabOrder.count == SpaceManagedTab.allCases.count else {
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

enum SpaceManagedTab: String, Codable, CaseIterable {
    case chat, cli, bot
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
        }) ?? "工作介面").prefix(80))
    }
}

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
