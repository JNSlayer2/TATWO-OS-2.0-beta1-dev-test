import Foundation

/// 每條討論串自己的瀏覽器分頁組（使用者 2026-09-03：不同 session 有不同瀏覽器需求，切討論串不該共用一個常駐瀏覽器）。
/// 只存分頁清單與網址，不存 cookie／登入（那些由 1.0 的瀏覽器管理／profile 管）。
struct BrowserLaneSnapshot: Codable, Equatable {
    var laneState: TatwoBrowserLaneState
    var laneURLs: [String: URL]
    var updatedAt: Date

    var openURLs: [URL] { laneState.lanes.compactMap { laneURLs[$0.id.rawValue] } }
}

struct OpenBrowserSessionSummary: Identifiable {
    let sessionID: String
    let threadTitle: String
    let projectName: String
    let laneCount: Int
    let urls: [URL]
    let updatedAt: Date
    var id: String { sessionID }
}

extension ChatPageModel {
    func browserLanes(for sessionID: String?) -> BrowserLaneSnapshot? {
        guard let sessionID else { return nil }
        return browserLanesBySession[sessionID]
    }

    func storeBrowserLanes(_ laneState: TatwoBrowserLaneState, laneURLs: [TatwoBrowserLaneID: URL], for sessionID: String?) {
        guard let sessionID else { return }
        var urls: [String: URL] = [:]
        for (key, value) in laneURLs { urls[key.rawValue] = value }
        let next = BrowserLaneSnapshot(laneState: laneState, laneURLs: urls, updatedAt: Date())
        if let existing = browserLanesBySession[sessionID], existing.laneState == next.laneState, existing.laneURLs == next.laneURLs { return }
        browserLanesBySession[sessionID] = next
    }

    /// 設定頁「關閉」：移除該討論串的分頁組；若正在看那條討論串，瀏覽器面板會回到新分頁。
    func closeBrowserLanes(for sessionID: String) {
        browserLanesBySession.removeValue(forKey: sessionID)
    }

    func closeAllBrowserLanes() { browserLanesBySession.removeAll() }

    /// 有開網址的討論串才算「未關閉的瀏覽器」。
    var openBrowserSessions: [OpenBrowserSessionSummary] {
        browserLanesBySession.compactMap { sessionID, snapshot in
            let urls = snapshot.openURLs
            guard !urls.isEmpty else { return nil }
            var title = "（已不存在的討論串）"
            var project = ""
            for p in document.projects {
                if let t = p.threads.first(where: { $0.id.uuidString.lowercased() == sessionID }) { title = t.title; project = p.name; break }
            }
            return OpenBrowserSessionSummary(sessionID: sessionID, threadTitle: title, projectName: project, laneCount: snapshot.laneState.lanes.count, urls: urls, updatedAt: snapshot.updatedAt)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }
}
