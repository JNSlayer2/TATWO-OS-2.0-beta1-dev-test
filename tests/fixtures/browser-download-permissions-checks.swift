@MainActor final class TatwoCEFBrowserView {
    var window: NSWindow? = nil
    var blocksThirdPartyCookies = true
    var adBlock = true
    var onPrivateNetworkRequested: ((String, @escaping (Bool) -> Void) -> Void)?
    var onPermissionRequested: ((String, String, @escaping (Bool) -> Void) -> Void)?
    var onPopupRequested: ((String) -> Void)?
    var onPopupCreated: ((TatwoCEFBrowserView) -> Void)?
    var onDownloadEvent: (([String: Any]) -> Void)?
    var onDownloadProgress: ((String, String, Int64, Int64, Bool) -> Void)?
    func cancelDownload(_ id: String) -> Bool { true }
    func pauseDownload(_ id: String) -> Bool { true }
    func resumeDownload(_ id: String) -> Bool { true }
    func retryDownload(_ url: String) -> Bool { true }
    func resetCurrentDownloadPermission() -> Bool { true }
}
@MainActor enum BrowserPopupFeatures { static func attach(to browser: TatwoCEFBrowserView) {} }
struct BrowserActorPolicy {
    enum Actor { case human }
    struct Settings { static func load() -> Self { Self() } }
    var blocksThirdPartyCookies = true
    var adBlock = true
    static func resolve(actor: Actor, settings: Settings) -> Self { Self() }
}
@MainActor final class IslandNotice {
    static let shared = IslandNotice()
    var infos = 0
    func info(title: String, detail: String) { infos += 1 }
}
@MainActor final class ConsentAnswers {
    var asks = 0
    var continuation: CheckedContinuation<Bool, Never>?
    func ask(_ title: String, _ detail: String, _ window: NSWindow?) async -> Bool {
        asks += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func answer(_ allowed: Bool) { let c = continuation; continuation = nil; c?.resume(returning: allowed) }
}
@main struct Fixture {
    @MainActor static func main() async {
        let answers = ConsentAnswers()
        let consent = BrowserHumanInteraction(prompt: answers.ask)
        let first = Task { await consent.allowPrivateHost("NAS.LOCAL.") }
        let second = Task { await consent.allowPrivateHost("nas.local") }
        while answers.continuation == nil { await Task.yield() }
        precondition(answers.asks == 1)
        answers.answer(true)
        let firstValue = await first.value
        let secondValue = await second.value
        precondition(firstValue && secondValue)
        let cached = await consent.allowPrivateHost("nas.local")
        precondition(cached && answers.asks == 1)
        let denied = Task { await consent.allowPrivateHost("127.0.0.1") }
        while answers.continuation == nil { await Task.yield() }
        answers.answer(false)
        let deniedValue = await denied.value
        precondition(!deniedValue)
        let retry = Task { await consent.allowPrivateHost("127.0.0.1") }
        while answers.continuation == nil { await Task.yield() }
        precondition(answers.asks == 3, "denial must not poison subsequent requests")
        answers.answer(true)
        let retryValue = await retry.value
        precondition(retryValue)
        precondition(BrowserHumanInteraction.title(String(repeating: "x", count: 100)).count == 14)
        precondition(!BrowserHumanInteraction.oneLine("a\r\nb").contains("\n"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tatwo-download-test-\(UUID().uuidString)")
        let history = directory.appendingPathComponent("history.json")
        let store = BrowserDownloadStore(storageURL: history)
        var cancelled = 0; var paused = 0; var resumed = 0; var retried = 0
        let controls = BrowserDownloadStore.Controls(cancel: { cancelled += 1; return true }, pause: { paused += 1; return true },
            resume: { resumed += 1; return true }, retry: { retried += 1; return true })
        func event(_ id: String, _ state: String, received: Int64 = 128) -> [String: Any] {
            ["id": id, "filename": "fixture.bin", "state": state, "received": received, "total": Int64(2048),
             "sourceURL": "https://secret-user:secret-password@example.test/private/token-path?credential=secret-query#secret-fragment",
             "error": state == "failed" ? "下載中斷" : ""]
        }
        store.update(event: event("broken", "starting"), controls: controls)
        precondition(store.downloads[0].state == .starting && store.canCancel(store.downloads[0]))
        store.update(event: event("broken", "downloading"), controls: controls)
        store.pause(store.downloads[0]); precondition(paused == 1)
        store.update(event: event("broken", "paused"), controls: controls)
        precondition(store.canResume(store.downloads[0]))
        store.resume(store.downloads[0]); precondition(resumed == 1)
        store.update(event: event("broken", "failed"), controls: controls)
        precondition(!store.downloads[0].done && store.canRetry(store.downloads[0]))
        precondition(!store.canCancel(store.downloads[0]))
        store.update(event: event("broken", "cancelled"), controls: controls)
        store.update(event: event("broken", "completed", received: 2048), controls: controls)
        precondition(store.downloads[0].state == .failed, "late callbacks cannot erase failure")
        store.retry(store.downloads[0]); precondition(retried == 1)
        store.update(event: event("cancelled", "downloading"), controls: controls)
        store.cancel(store.downloads[0]); precondition(cancelled == 1)
        store.update(event: event("cancelled", "cancelled"), controls: controls)
        precondition(store.downloads[0].state == .cancelled && !store.downloads[0].done)
        store.update(event: event("finished", "completed", received: 2048), controls: controls)
        store.update(event: event("finished", "completed", received: 2048), controls: controls)
        precondition(store.downloads[0].done && IslandNotice.shared.infos == 1)
        store.update(event: event("pending", "starting"), controls: controls)
        var invalid = event("unsafe", "completed"); invalid["filename"] = "../unsafe"
        store.update(event: invalid, controls: controls)
        precondition(store.downloads.count == 4)
        let saved = try! String(contentsOf: history, encoding: .utf8)
        for secret in ["secret-user", "secret-password", "secret-query", "secret-fragment", "token-path"] {
            precondition(!saved.contains(secret), "history must omit credentials and complete source URLs")
        }
        precondition(store.downloads[0].sourceOrigin == "https://example.test")
        let restored = BrowserDownloadStore(storageURL: history)
        precondition(restored.downloads.count == 4)
        precondition(restored.downloads.first { $0.id == "pending" }?.state == .failed)
        precondition(restored.downloads.allSatisfy { !restored.canRetry($0) }, "never retry in a different profile after restart")
        store.clearDownloads()
        precondition(store.downloads.count == 1 && store.downloads[0].id == "pending")
        store.update(event: event("finished", "completed"), controls: controls)
        precondition(store.downloads.count == 1, "hidden terminal entries must stay hidden")
        let attributes = try! FileManager.default.attributesOfItem(atPath: history.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let closingStore = BrowserDownloadStore(storageURL: nil)
        let closedOwner = BrowserDownloadStore.Controls(cancel: { false }, pause: { false }, resume: { false }, retry: { false })
        closingStore.update(event: event("closed-owner", "downloading"), controls: closedOwner)
        var closed = event("closed-owner", "cancelled")
        closed["error"] = "來源分頁已關閉，下載已取消。"
        closingStore.update(event: closed, controls: closedOwner)
        precondition(closingStore.downloads[0].state == .cancelled && !closingStore.downloads[0].done)
        precondition(closingStore.downloads[0].failure?.contains("來源分頁已關閉") == true)
        closingStore.update(event: event("closed-owner", "completed"), controls: closedOwner)
        precondition(closingStore.downloads[0].state == .cancelled)
        closingStore.retry(closingStore.downloads[0])
        precondition(!closingStore.canRetry(closingStore.downloads[0]), "closed profile owner must not be replaced by another browser")
        print("PASS: consent coalescing, allow cache, denial retry, six download states, controls, late callbacks, history privacy, restart ownership, clear/history permissions")
    }
}
