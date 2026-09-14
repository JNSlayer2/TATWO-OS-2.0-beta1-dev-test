import Foundation

/// The native monitor validates freshness before latching a human request.
/// The request remains pending while an agent action drains, even if that takes > 1 second.
enum BrowserActorRecovery {
    static func shouldRestore(agentControlled: Bool, inFlight: Int,
                              lastAgentActionAt: TimeInterval?, humanInputAt: TimeInterval?,
                              now: TimeInterval) -> Bool {
        guard agentControlled, inFlight == 0, now.isFinite,
              let humanInputAt, humanInputAt.isFinite,
              now >= humanInputAt else { return false }
        guard let lastAgentActionAt else { return true }
        return lastAgentActionAt.isFinite && now - lastAgentActionAt >= 0.3
    }
}

enum BrowserChatRequestRouting {
    static func canConsume(panelID: UUID, mountedSurfaceID: UUID?) -> Bool {
        mountedSurfaceID == panelID
    }
}

@MainActor
enum BrowserChatLifecycle {
    static func didClose(_ sessionID: String, registry: BrowserTabRegistry,
                         retention: BrowserGeneralSettings.SessionRetention) {
        if retention == .closeWithChat {
            registry.closeAll(ownedBy: .chatSession(sessionID: sessionID))
        }
    }
}
