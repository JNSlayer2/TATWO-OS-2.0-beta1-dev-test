import Foundation

extension ChatPageModel {
    /// Compatibility projection for the existing embedded panel's close observation.
    /// The registry, not ChatPageModel, owns every tab.
    var browserLanesBySession: [String: BrowserLaneSnapshot] {
        Dictionary(uniqueKeysWithValues: browserTabRegistry.chatSessionIDs.compactMap { id in
            browserTabRegistry.laneSnapshot(for: id).map { (id, $0) }
        })
    }

    func browserLanes(for sessionID: String?) -> BrowserLaneSnapshot? {
        sessionID.flatMap { browserTabRegistry.laneSnapshot(for: $0) }
    }

    func storeBrowserLanes(_ laneState: TatwoBrowserLaneState, laneURLs: [TatwoBrowserLaneID: URL], for sessionID: String?) {
        guard let sessionID else { return }
        let urls = Dictionary(uniqueKeysWithValues: laneURLs.map { ($0.key.rawValue, $0.value) })
        browserTabRegistry.storeLanes(BrowserLaneSnapshot(laneState: laneState, laneURLs: urls, updatedAt: Date()), for: sessionID)
    }

    func closeBrowserLanes(for sessionID: String) {
        browserTabRegistry.closeAll(ownedBy: .chatSession(sessionID: sessionID))
    }

    func closeAllBrowserLanes() {
        for id in browserTabRegistry.chatSessionIDs { closeBrowserLanes(for: id) }
    }

    var openBrowserSessions: [OpenBrowserSessionSummary] { browserTabRegistry.openSessions }
}
