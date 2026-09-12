import Foundation

/// Bridges durable reservations to the existing Bot/runtime path. There is no
/// independent runner, copied transcript or global-current-Space lookup here.
@MainActor
extension ChatPageModel {
    func submitSpaceInterface(
        spaceID: String, draftID: UUID, name: String,
        route: ChatRouteChoice, workdir: String, permission: TatwoPermissionPreset
    ) async throws -> SpaceWorkInterfaceRecord {
        guard isLive, selectedRemote == nil, let library = botLibraryForBridge,
              let engine = live as? ChatLiveEngine else {
            throw BotLibraryError.invalid("space_local_runtime_unavailable")
        }
        guard spaceSubmissionsInFlight.insert(draftID).inserted else {
            throw BotLibraryError.invalid("space_submission_in_progress")
        }
        defer { spaceSubmissionsInFlight.remove(draftID) }
        await library.ready()
        guard library.snapshot.spaces.contains(where: { $0.id == spaceID }) else {
            throw BotLibraryError.invalid("space_domain_not_registered")
        }
        let item = try await library.reserveSpaceInterface(spaceID: spaceID, draftID: draftID, name: name)
        if item.submission == .accepted { return item }
        guard item.submission != .dispatching, item.submission != .recoveryRequired else {
            throw BotLibraryError.invalid("space_delivery_uncertain_requires_recovery")
        }
        var dispatchStarted = false
        do {
            if item.createsDedicatedBot, library.bot(id: item.botID) == nil {
                let engineName: String
                switch route.brandGroup {
                case .anthropic: engineName = "claude"
                case .openAI: engineName = "codex"
                case .xAI: engineName = "grok"
                default: throw BotLibraryError.invalid("space_bot_route_unsupported")
                }
                guard engineName != "grok" || permission == .fullAccess else {
                    throw BotLibraryError.invalid("space_grok_permission_unsupported")
                }
                guard workdir.hasPrefix("/") else {
                    throw BotLibraryError.invalid("space_bot_route_or_directory_unsupported")
                }
                var bot = BotLibraryRecord(
                    id: item.botID, name: "\(name) Bot", emoji: "🤖", role: "工作介面搭建",
                    engine: engineName, model: route.modelArgument, workdir: workdir, spaceIDs: [spaceID])
                switch permission {
                case .askFirst: bot.permissions.approval = "ask"
                case .approveForMe: bot.permissions.approval = "auto"
                case .fullAccess: bot.permissions.approval = "full"
                case .configFile:
                    throw BotLibraryError.invalid("space_bot_custom_config_not_supported")
                }
                _ = try await library.createSpaceBot(bot, reservation: item, instructions: """
                你負責搭建「\(name)」工作介面。請先整理需求、列出必要待確認事項，
                提出介面與操作流程供使用者確認，再進行搭建。
                此工作介面與對話屬於 Space \(spaceID)，不可移往其他 Space。
                """)
            }
            // A durable dispatch intent precedes external work. If delivery becomes
            // uncertain, retries stop rather than guessing and sending again.
            let hasFirstTurn = engine.transcript(for: item.conversationID).contains { $0.role == .user }
            if !hasFirstTurn {
                _ = try await library.updateSpaceDomain(id: item.spaceID) { domain in
                    guard let index = domain.interfaces.firstIndex(where: { $0.id == item.id }) else {
                        throw BotLibraryError.invalid("space_reservation_missing")
                    }
                    domain.interfaces[index].submission = .dispatching
                }
                dispatchStarted = true
                guard sendAsBot(botID: item.botID, text: item.initialRequest,
                                spaceID: item.spaceID, interfaceID: item.id) == item.conversationID else {
                    dispatchStarted = false // Existing send path explicitly rejected the turn.
                    throw BotLibraryError.invalid(composerHint ?? "space_submission_not_accepted")
                }
            }
            try engine.persistSpaceConversation()
            let domain = try await library.updateSpaceDomain(id: item.spaceID) { domain in
                guard let index = domain.interfaces.firstIndex(where: {
                    $0.id == item.id && $0.conversationID == item.conversationID && $0.botID == item.botID
                }) else { throw BotLibraryError.invalid("space_reservation_changed") }
                domain.interfaces[index].submission = .accepted
                domain.interfaces[index].lastError = nil
                domain.selectedInterfaceID = item.id
                // A newer draft typed while awaiting IO belongs to the user.
                if domain.draft.id == draftID && domain.draft.text == item.initialRequest {
                    domain.draft = SpaceBuilderDraft()
                }
            }
            guard let saved = domain.interfaces.first(where: { $0.id == item.id }) else {
                throw BotLibraryError.invalid("space_submission_save_missing")
            }
            return saved
        } catch {
            let failure = String(describing: error)
            let deliveryUncertain = dispatchStarted
            _ = try? await library.updateSpaceDomain(id: item.spaceID) { domain in
                guard let index = domain.interfaces.firstIndex(where: { $0.id == item.id }),
                      domain.interfaces[index].submission != .accepted else { return }
                domain.interfaces[index].submission = deliveryUncertain ? .recoveryRequired : .failed
                domain.interfaces[index].lastError = failure
            }
            throw error
        }
    }

    func spaceInterfaceTranscript(spaceID: String, interfaceID: UUID) -> [ChatMessage] {
        guard let item = botLibraryForBridge?.snapshot.spaceWorkspace.domains[spaceID]?.interfaces
            .first(where: { $0.id == interfaceID && $0.spaceID == spaceID }) else { return [] }
        return live?.transcript(for: item.conversationID) ?? []
    }

    func sendSpaceFollowup(spaceID: String, interfaceID: UUID, requestID: UUID, text: String) async throws {
        guard let library = botLibraryForBridge, let engine = live as? ChatLiveEngine,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let item = library.snapshot.spaceWorkspace.domains[spaceID]?.interfaces
                .first(where: { $0.id == interfaceID && $0.submission == .accepted }) else {
            throw BotLibraryError.invalid("space_conversation_unavailable")
        }
        guard spaceSubmissionsInFlight.insert(requestID).inserted else {
            throw BotLibraryError.invalid("space_submission_in_progress")
        }
        defer { spaceSubmissionsInFlight.remove(requestID) }
        let key = interfaceID.uuidString
        let saved = try await library.updateSpaceDomain(id: spaceID) { domain in
            var requests = domain.followupRequests ?? [:]
            if let old = requests[key] {
                if old.id == requestID && old.status == .accepted { return }
                guard old.status != .dispatching, old.status != .recoveryRequired else {
                    throw BotLibraryError.invalid("space_delivery_uncertain_requires_recovery")
                }
            }
            requests[key] = .init(id: requestID, interfaceID: interfaceID, text: text, status: .dispatching)
            domain.followupRequests = requests
        }
        if saved.followupRequests?[key]?.id == requestID,
           saved.followupRequests?[key]?.status == .accepted { return }
        var accepted = false
        do {
            guard sendAsBot(botID: item.botID, text: text, spaceID: spaceID, interfaceID: interfaceID) == item.conversationID else {
                throw BotLibraryError.invalid(composerHint ?? "space_send_rejected")
            }
            accepted = true
            try engine.persistSpaceConversation()
            _ = try await library.updateSpaceDomain(id: spaceID) { domain in
                guard domain.followupRequests?[key]?.id == requestID else {
                    throw BotLibraryError.invalid("space_request_changed")
                }
                domain.followupRequests?[key]?.status = .accepted
                if domain.conversationDrafts?[key] == text { domain.conversationDrafts?[key] = "" }
            }
        } catch {
            let status: SpaceWorkInterfaceRecord.Submission = accepted ? .recoveryRequired : .failed
            _ = try? await library.updateSpaceDomain(id: spaceID) { domain in
                guard domain.followupRequests?[key]?.id == requestID else { return }
                domain.followupRequests?[key]?.status = status
            }
            throw error
        }
    }
}
