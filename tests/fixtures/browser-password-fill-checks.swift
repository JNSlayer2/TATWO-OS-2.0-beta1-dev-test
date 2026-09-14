import Foundation
import WebKit

enum BrowserRequestPolicyEvaluator {
    static func origin(of url: URL) -> String? { BrowserPasswordOrigin.normalized(url.absoluteString) }
}

@MainActor
final class IslandNotice {
    static let shared = IslandNotice()
    enum Decision { case allow, cancel, timeout }
    var requests: [(title: String, detail: String, label: String)] = []
    var answer: Decision = .allow
    var suspend = false
    var continuation: CheckedContinuation<Decision, Never>?
    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval) async -> Decision {
        precondition(timeout == 20)
        requests.append((title, detail, allowLabel))
        if suspend { return await withCheckedContinuation { continuation = $0 } }
        return answer
    }
}

@MainActor
final class FakePasswordBridge: BrowserPasswordAssistBridge {
    var passwordAssistIsHuman = true
    var passwordAssistOrigin: String? = "https://example.com/login"
    var navigationGeneration: UInt64 = 1
    var passwordAssistEnabled = false
    var onLoginFormDetected: ((String, String, String, String, String) -> Void)?
    var onCredentialSubmitted: ((String, String, String) -> Void)?
    var onPasswordAssistPageLoaded: ((String, UInt64, Bool, Bool) -> Void)?
    var onPasswordAssistInvalidated: ((Bool, Bool) -> Void)?
    var fills: [(username: String, password: String, form: String, generation: UInt64)] = []
    func fillCredentialUsername(_ username: String, password: String, formID: String,
                                navigationGeneration: UInt64) {
        fills.append((username, password, formID, navigationGeneration))
    }
    func detect(_ username: String = "") {
        onLoginFormDetected?("https://example.com", "form-1", "username-1", "password-1", username)
    }
    func submit(_ username: String, _ password: String) {
        onCredentialSubmitted?("https://example.com", username, password)
    }
    func navigate(success: Bool = true, loginRemains: Bool = false, reload: Bool = false,
                  origin: String = "https://example.com") {
        navigationGeneration += 1
        onPasswordAssistInvalidated?(reload, !reload)
        passwordAssistOrigin = origin + "/next"
        onPasswordAssistPageLoaded?(origin, navigationGeneration, success, loginRemains)
    }
}

@main
struct PasswordFillChecks {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    @MainActor static func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
    @MainActor static func main() async throws {
        let store = InMemorySecretStore()
        let vault = BrowserPasswordVault(indexURL: nil, secrets: store, authenticator: AlwaysAllowAuthenticator())
        let initial = try vault.add(origin: "https://example.com", username: "alice",
                                    password: "fixture-secret-first", title: "Example", source: .manual)
        try vault.add(origin: "https://example.com", username: "bob",
                      password: "fixture-secret-second", title: "Example", source: .manual)
        let notice = IslandNotice.shared
        let bridge = FakePasswordBridge()
        var enabled = true
        let assist = BrowserPasswordAssist(bridge: bridge, vault: vault, enabled: { enabled }, authenticator: AlwaysAllowAuthenticator())
        bridge.detect()
        await settle()
        check(notice.requests.count == 1, "one Island ask")
        check(notice.requests.last?.title == "要填入密碼嗎", "fill title")
        check(notice.requests.last?.detail == "example.com・alice・其他 1 組在設定 › 密碼", "multiple accounts")
        check(bridge.fills.count == 1, "approval calls bridge")
        check(bridge.fills[0].username == "alice" && bridge.fills[0].password == "fixture-secret-first" &&
              bridge.fills[0].form == "form-1" && bridge.fills[0].generation == 1, "exact fill arguments")
        bridge.detect()
        await settle()
        check(notice.requests.count == 1, "same origin no repeat")
        bridge.navigate(reload: true)
        notice.answer = .cancel
        bridge.detect()
        await settle()
        check(notice.requests.count == 2 && bridge.fills.count == 1, "cancel never fills")
        bridge.detect()
        bridge.navigate()
        bridge.detect()
        await settle()
        check(notice.requests.count == 2, "denial survives navigation within session")
        bridge.navigate(reload: true)
        notice.answer = .allow
        bridge.detect("bob")
        await settle()
        check(bridge.fills.last?.username == "bob", "prefilled username selects matching account")
        bridge.navigate(reload: true)
        bridge.detect("unknown")
        await settle()
        check(notice.requests.count == 3, "unknown prefill never overwritten")

        let saveStart = notice.requests.count
        bridge.submit("carol", "fixture-secret-new")
        await settle()
        check(notice.requests.count == saveStart && vault.credentials.count == 2, "submit alone never asks/saves")
        bridge.onPasswordAssistPageLoaded?("https://example.com", bridge.navigationGeneration, true, false)
        await settle()
        check(notice.requests.count == saveStart, "same generation load ignored")
        bridge.navigate()
        await settle()
        check(notice.requests.count == saveStart + 1 && notice.requests.last?.title == "要儲存這組密碼嗎", "askSave")
        let saved = vault.credentials.first { $0.username == "carol" }!
        check(try saved.source == .saved && store.get(saved.id) == "fixture-secret-new", "approved vault.add")
        bridge.submit("carol", "fixture-secret-new")
        bridge.navigate()
        await settle()
        check(notice.requests.count == saveStart + 1, "identical password none")
        bridge.submit("carol", "fixture-secret-updated")
        bridge.navigate()
        await settle()
        check(notice.requests.last?.title == "要更新密碼嗎", "askUpdate")
        check(try store.get(saved.id) == "fixture-secret-updated", "approved vault.update")

        let afterUpdate = notice.requests.count
        for (success, loginRemains) in [(false, false), (true, true)] {
            bridge.submit("failed", "fixture-secret-failed")
            bridge.navigate(success: success, loginRemains: loginRemains)
            await settle()
        }
        check(notice.requests.count == afterUpdate && !vault.credentials.contains { $0.username == "failed" },
              "HTTP error and login form remaining never save")
        bridge.submit("cross", "fixture-secret-cross")
        bridge.navigate(origin: "https://other.example")
        await settle()
        check(notice.requests.count == afterUpdate, "cross-origin navigation discards submitted values")
        bridge.passwordAssistOrigin = "https://example.com"
        notice.answer = .cancel
        bridge.submit("denied", "fixture-secret-denied")
        bridge.navigate()
        await settle()
        check(!vault.credentials.contains { $0.username == "denied" }, "save denial")
        notice.answer = .allow

        let disabledStart = notice.requests.count
        enabled = false
        assist.refreshSettings()
        bridge.navigate(reload: true)
        bridge.detect()
        bridge.submit("disabled", "fixture-secret-disabled")
        bridge.navigate()
        await settle()
        check(notice.requests.count == disabledStart && !bridge.passwordAssistEnabled, "setting off: no fill/save/update")
        enabled = true
        assist.refreshSettings()
        bridge.passwordAssistIsHuman = false
        bridge.detect()
        bridge.submit("agent", "fixture-secret-agent")
        bridge.navigate()
        await settle()
        check(notice.requests.count == disabledStart, "agent actor and takeover refuse callbacks")
        bridge.passwordAssistIsHuman = true

        // Revocation even when a fake Island ignores cancellation and returns a late allow.
        for kind in ["navigation", "takeover", "setting", "close"] {
            bridge.passwordAssistIsHuman = true
            enabled = true
            assist.refreshSettings()
            bridge.navigate(reload: true)
            notice.suspend = true
            bridge.detect()
            while notice.continuation == nil { await Task.yield() }
            let fills = bridge.fills.count
            switch kind {
            case "navigation": bridge.navigate()
            case "takeover":
                bridge.passwordAssistIsHuman = false
                bridge.onPasswordAssistInvalidated?(false, false)
                bridge.passwordAssistIsHuman = true // no ABA approval after human recovery
            case "setting":
                enabled = false; assist.refreshSettings()
                enabled = true; assist.refreshSettings()
            default: assist.invalidate()
            }
            let continuation = notice.continuation
            notice.continuation = nil
            notice.suspend = false
            continuation?.resume(returning: .allow)
            await settle()
            check(bridge.fills.count == fills, "late approval rejected: " + kind)
        }
        // A settings edit concurrent with a save prompt must survive.
        notice.suspend = true
        bridge.submit("alice", "fixture-secret-conflict")
        bridge.navigate()
        while notice.continuation == nil { await Task.yield() }
        try vault.update(initial.id, password: "fixture-secret-settings", username: nil, title: nil)
        let continuation = notice.continuation
        notice.continuation = nil
        notice.suspend = false
        continuation?.resume(returning: .allow)
        await settle()
        check(try store.get(initial.id) == "fixture-secret-settings", "concurrent settings update preserved")
        assist.invalidate()

        let settingsURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try Data(#"{"searchEngine":"bing","unrelated":"retained"}"#.utf8).write(to: settingsURL)
        check(BrowserGeneralSettings.load(from: settingsURL).passwordAssist, "old settings default on")
        let stale = BrowserGeneralSettings.load(from: settingsURL)
        try BrowserGeneralSettings.savePasswordAssist(false, to: settingsURL)
        check(!BrowserGeneralSettings.load(from: settingsURL).passwordAssist, "setting persisted off")
        try stale.save(to: settingsURL)
        check(!BrowserGeneralSettings.load(from: settingsURL).passwordAssist, "stale general editor cannot reenable")
        let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        check(fields["unrelated"] as? String == "retained" && fields["searchEngine"] as? String == "bing",
              "single-key settings writer preserves other room keys")
        var edited = BrowserGeneralSettings.load(from: settingsURL)
        edited.passwordAssist = true
        try edited.save(to: settingsURL)
        check(BrowserGeneralSettings.load(from: settingsURL) == edited, "explicit general-settings property edit persists")
        print("W57c password fill fixture passed: \(checks) checks")
    }
}
