import Foundation
import TatwoCEFBridge

/// Process-local consent; never saved into a profile or shared with an agent.
@MainActor
final class BrowserHumanInteraction {
    static let shared = BrowserHumanInteraction()
    private var decisions: [String: Bool] = [:]
    private var pending: [String: Task<Bool, Never>] = [:]

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
    }
    static func title(_ text: String) -> String {
        let clean = oneLine(text)
        return clean.count <= 14 ? clean : String(clean.prefix(13)) + "…"
    }

    func allowPrivateHost(_ rawHost: String) async -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !host.isEmpty else { return false }
        if let decision = decisions[host] { return decision }
        if let task = pending[host] { return await task.value }
        let task = Task { @MainActor in
            await IslandNotice.shared.ask(
                title: Self.title("允許連到區網 \(host)？"),
                detail: Self.oneLine("主機：\(host)；僅限本次 App 使用期間"),
                allowLabel: "允許", timeout: 20) == .allow
        }
        pending[host] = task
        let allowed = await task.value
        decisions[host] = allowed
        pending[host] = nil
        return allowed
    }

    func configure(_ browser: TatwoCEFBrowserView, onPopup: @escaping (URL) -> Void) {
        let policy = BrowserActorPolicy.resolve(actor: .human, settings: .load())
        browser.blocksThirdPartyCookies = policy.blocksThirdPartyCookies
        browser.adBlock = policy.adBlock
        browser.onPrivateNetworkRequested = { host, completion in
            Task { @MainActor in completion(await Self.shared.allowPrivateHost(host)) }
        }
        browser.onPermissionRequested = { site, permission, completion in
            Task { @MainActor in
                let host = URL(string: site)?.host ?? site
                let allowed = await IslandNotice.shared.ask(
                    title: Self.title("\(host) 想使用\(permission)"),
                    detail: Self.oneLine("\(site) — \(permission)；僅限這次請求"),
                    allowLabel: "允許", timeout: 20) == .allow
                completion(allowed)
            }
        }
        browser.onPopupRequested = { raw in
            guard let url = URL(string: raw) else { return }
            onPopup(url)
        }
        browser.onDownloadProgress = { id, filename, received, total, done in
            BrowserDownloadStore.shared.update(id: id, filename: filename, received: received, total: total, done: done)
        }
    }
}
