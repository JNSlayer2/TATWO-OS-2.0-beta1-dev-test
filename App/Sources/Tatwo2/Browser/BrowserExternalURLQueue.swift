import Foundation

extension Notification.Name {
    static let tatwoBrowserOpenExternalURLs = Notification.Name("tatwo.browser.openExternalURLs")
}

/// Notifications wake mounted views; this inbox retains deliveries while no view exists.
/// Main-actor ownership makes each accepted batch drain once, including reentrant deliveries.
@MainActor
final class BrowserExternalURLQueue {
    static let shared = BrowserExternalURLQueue()
    private var pending: [URL] = []
    private let notifications: NotificationCenter
    var hasPendingURLs: Bool { !pending.isEmpty }

    init(notifications: NotificationCenter = .default) { self.notifications = notifications }

    static func accepts(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return !(url.host ?? "").isEmpty
        // 2.0.7: local files are not accepted (the human policy only loads http/https).
        default: return false
        }
    }

    @discardableResult
    func enqueue(_ urls: [URL]) -> Bool {
        let accepted = urls.filter(Self.accepts)
        guard !accepted.isEmpty else { return false }
        pending.append(contentsOf: accepted)
        notifications.post(name: .tatwoBrowserOpenExternalURLs, object: self)
        return true
    }

    func consume(whenMounted mounted: Bool, open: ([URL]) -> Void) {
        guard mounted, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        open(batch)
    }
}
