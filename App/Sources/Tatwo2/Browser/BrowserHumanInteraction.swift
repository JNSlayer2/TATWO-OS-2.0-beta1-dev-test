import AppKit
import TatwoCEFBridge

/// Human consent is process-local. Denial is never cached: reload can ask again.
@MainActor
final class BrowserHumanInteraction {
    static let shared = BrowserHumanInteraction()
    typealias ConsentPrompt = @MainActor (String, String, NSWindow?) async -> Bool
    private var decisions: [String: Bool] = [:]
    private var pending: [String: Task<Bool, Never>] = [:]
    private var lastPrompt: Task<Bool, Never>?
    private var promptSerial: UInt64 = 0
    private let prompt: ConsentPrompt

    init(prompt: ConsentPrompt? = nil) {
        self.prompt = prompt ?? Self.presentSheet
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
    }
    static func title(_ text: String) -> String {
        let clean = oneLine(text)
        return clean.count <= 14 ? clean : String(clean.prefix(13)) + "…"
    }

    private static func presentSheet(title: String, detail: String, window: NSWindow?) async -> Bool {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "允許")
        alert.addButton(withTitle: "不允許")
        // Return defaults to denial; approval requires choosing it.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { window.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
            }
            alert.beginSheetModal(for: window) { response in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func ask(title: String, detail: String, window: NSWindow?) async -> Bool {
        let previous = lastPrompt
        promptSerial &+= 1
        let serial = promptSerial
        let prompt = self.prompt
        let task = Task { @MainActor [weak window] in
            _ = await previous?.value
            return await prompt(title, detail, window)
        }
        lastPrompt = task
        let result = await task.value
        if serial == promptSerial { lastPrompt = nil }
        return result
    }

    func allowPrivateHost(_ rawHost: String, window: NSWindow? = nil) async -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !host.isEmpty else { return false }
        if decisions[host] == true { return true }
        if let task = pending[host] { return await task.value }
        let task = Task { @MainActor in
            await ask(title: "允許連接本機或區域網路？",
                      detail: Self.oneLine("網站主機：\(host)\n允許僅適用本次 App 使用期間。選擇不允許後，重新載入可再次詢問。"), window: window)
        }
        pending[host] = task
        let allowed = await task.value
        if allowed { decisions[host] = true }
        pending[host] = nil
        return allowed
    }

    func configure(_ browser: TatwoCEFBrowserView, onPopup: @escaping (URL) -> Void) {
        let policy = BrowserActorPolicy.resolve(actor: .human, settings: .load())
        browser.blocksThirdPartyCookies = policy.blocksThirdPartyCookies
        browser.adBlock = policy.adBlock
        browser.onPrivateNetworkRequested = { [weak browser] host, completion in
            Task { @MainActor in
                guard let browser else { completion(false); return }
                completion(await Self.shared.allowPrivateHost(host, window: browser.window))
            }
        }
        browser.onPermissionRequested = { [weak self, weak browser] site, permission, completion in
            Task { @MainActor in
                guard let self, let browser else { completion(false); return }
                // Show the origin, not an OAuth URL that may contain credentials.
                let origin = BrowserDownloadStore.safeOrigin(site) ?? URL(string: site)?.host ?? "這個網站"
                let scope = permission.contains("下載多個檔案")
                    ? "允許後會記住此網站的多檔下載設定。可在瀏覽器功能選單重設；不允許只取消這次請求。"
                    : "允許僅限這次請求。"
                let allowed = await self.ask(title: "允許網站使用\(Self.oneLine(permission))？",
                    detail: Self.oneLine("\(origin) 想使用\(permission)。\(scope)"), window: browser.window)
                completion(allowed)
            }
        }
        browser.onPopupRequested = { raw in
            guard let url = URL(string: raw) else { return }
            onPopup(url)
        }
        browser.onPopupCreated = { [weak self] popup in
            self?.configure(popup, onPopup: onPopup)
            BrowserPopupFeatures.attach(to: popup)
        }
        browser.onDownloadEvent = { [weak browser] event in
            guard let browser else { return }
            let identifier = event["id"] as? String ?? ""
            let sourceURL = event["sourceURL"] as? String ?? ""
            // Every control remains bound to the exact originating CEF view and
            // request context, including popup downloads. No alternate HTTP client.
            let controls = BrowserDownloadStore.Controls(
                cancel: { [weak browser] in browser?.cancelDownload(identifier) ?? false },
                pause: { [weak browser] in browser?.pauseDownload(identifier) ?? false },
                resume: { [weak browser] in browser?.resumeDownload(identifier) ?? false },
                retry: { [weak browser] in browser?.retryDownload(sourceURL) ?? false })
            BrowserDownloadStore.shared.update(event: event, controls: controls)
        }
        browser.onDownloadProgress = nil
    }

    static func resetDownloadPermission(_ browser: TatwoCEFBrowserView) {
        let reset = browser.resetCurrentDownloadPermission()
        let alert = NSAlert()
        alert.messageText = reset ? "已重設此網站的多檔下載權限" : "目前無法重設下載權限"
        alert.informativeText = reset
            ? "僅清除目前網站的多檔下載設定。重新點選下載連結，需要時會再次詢問。"
            : "請先開啟一般網頁再重試；不會修改其他網站或全域權限。"
        alert.addButton(withTitle: "好")
        if let window = browser.window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
