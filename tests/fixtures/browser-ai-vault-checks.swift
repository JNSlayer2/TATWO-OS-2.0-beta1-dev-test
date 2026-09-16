import AppKit
import Foundation
import SwiftUI
import WebKit

enum BrowserRequestPolicyEvaluator {
    static func origin(of url: URL) -> String? { BrowserPasswordOrigin.normalized(url.absoluteString) }
}
@MainActor final class IslandNotice {
    static let shared = IslandNotice()
    enum Decision { case allow, cancel }
    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval) async -> Decision { .allow }
    func confirm(title: String, detail: String, confirmLabel: String, cancelLabel: String) async -> Bool { false }
}
@MainActor final class W58Auth: BrowserVaultAuthenticator {
    var calls = 0, reasons: [String] = []
    var deny = false
    var during: (() -> Void)?
    func authenticate(reason: String) async throws {
        calls += 1; reasons.append(reason); during?()
        if deny { throw BrowserPasswordVaultError.authenticationFailed }
    }
}
final class W58Secrets: BrowserSecretStore {
    var values: [UUID: String] = [:]
    var reads = 0, writes = 0
    func set(_ secret: String, for id: UUID) throws { values[id] = secret; writes += 1 }
    func get(_ id: UUID) throws -> String? { reads += 1; return values[id] }
    func remove(_ id: UUID) throws { values.removeValue(forKey: id) }
}
@MainActor final class W58HumanPage: BrowserPasswordAssistBridge {
    var passwordAssistIsHuman = true
    var passwordAssistOrigin: String? = "https://example.com"
    var navigationGeneration: UInt64 = 1
    var passwordAssistEnabled = false
    var onLoginFormDetected: ((String, String, String, String, String) -> Void)?
    var onCredentialSubmitted: ((String, String, String) -> Void)?
    var onPasswordAssistPageLoaded: ((String, UInt64, Bool, Bool) -> Void)?
    var onPasswordAssistInvalidated: ((Bool, Bool) -> Void)?
    var fills = 0
    var onFill: (() -> Void)?
    func fillCredentialUsername(_ username: String, password: String, formID: String, navigationGeneration: UInt64) {
        onFill?(); fills += 1
    }
    func detect() { onLoginFormDetected?(passwordAssistOrigin!, "form", "user", "pass", "") }
    func reload() { navigationGeneration += 1; onPasswordAssistInvalidated?(true, false) }
}
@MainActor final class W58AgentPage: BrowserAILoginTarget {
    var aiLoginIsAgent = true
    var aiLoginOrigin: String? = "https://example.com/login"
    var navigationGeneration: UInt64 = 3
    var aiLoginState = BrowserAILoginState(phase: "idle")
    var fills = 0, preparations = 0
    var error = ""
    var complete = true
    var finalURL = "https://example.com/home"
    var received = ""
    func prepareAgentLogin() -> Bool {
        preparations += 1
        aiLoginState = BrowserAILoginState(phase: "ready", formID: "form", generation: navigationGeneration, error: error)
        return true
    }
    func cancelAgentLogin() { aiLoginState = BrowserAILoginState(phase: "idle") }
    func fillCredentialForAgentUsername(_ username: String, password: String, formID: String, navigationGeneration: UInt64) -> Bool {
        fills += 1; received = password
        self.navigationGeneration += complete ? 1 : 0
        aiLoginState = BrowserAILoginState(phase: complete ? "complete" : "submitted", generation: self.navigationGeneration,
            finalURL: finalURL, title: "Home")
        return true
    }
}

@main struct W58Checks {
    @MainActor static var count = 0
    @MainActor static func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    @MainActor static func settle() async { for _ in 0..<80 { await Task.yield() } }
    @MainActor static func rejects(_ code: String, _ body: () async throws -> Void) async {
        do { try await body(); preconditionFailure("expected " + code) }
        catch { check((error as? AIVaultLoginError)?.description == code, "wrong error code for " + code) }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.contains("--render") { try render(root); return }
        try await human(root)
        try await vault(root)
        try await login()
        try tabs(root)
        print("W58 AI vault fixture passed: \(count) checks")
    }
    @MainActor static func tabs(_ root: URL) throws {
        let file = root.appendingPathComponent("tabs-\(UUID()).json")
        let registry = BrowserTabRegistry(storageURL: file)
        let owner = BrowserTabOwner.chatSession(sessionID: "w58-fixture")
        let human = registry.openTab(owner: owner, url: URL(string: "https://example.com/login"))
        registry.select(human.id)
        let humanBefore = registry.tabs.first { $0.id == human.id }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(human)) as! [String: Any]
        legacy.removeValue(forKey: "isAgentTab")
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(!decoded.usesAgentContext, "old tabs decode as human")
        let ai = registry.tabForAgentNavigation(ownedBy: owner)!
        check(ai.id != human.id && ai.usesAgentContext && registry.tabs.count == 2, "AI navigation creates isolated tab beside human")
        check(registry.tabs.first { $0.id == human.id } == humanBefore, "human tab unchanged")
        registry.select(human.id)
        check(registry.tabForAgentNavigation(ownedBy: owner)?.id == ai.id, "next AI navigation selects its own existing tab")
        registry.markSleeping(ai.id, true)
        registry.markSleeping(ai.id, false)
        check(registry.tabs.first { $0.id == ai.id }?.usesAgentContext == true, "wake retains AI identity")
        if var snapshot = registry.laneSnapshot(for: "w58-fixture") {
            snapshot.laneURLs[human.id.uuidString] = URL(string: "https://example.com/updated")
            registry.storeLanes(snapshot, for: "w58-fixture")
        }
        check(registry.tabs.first { $0.id == ai.id }?.usesAgentContext == true, "legacy adapter retains AI identity")
        try registry.flush()
        let restored = BrowserTabRegistry(storageURL: file)
        check(restored.tabs.first { $0.id == ai.id }?.usesAgentContext == true, "durable AI identity")
        let space = BrowserTabOwner.workSpace(spaceID: registry.spaces.first { !$0.isSessionSpace }!.id)
        registry.move(ai.id, to: space)
        check(registry.tabs.first { $0.id == ai.id }?.owner == owner, "cannot relabel AI as human space")
        check(registry.tabForAgentNavigation(ownedBy: space) == nil, "workspace never creates agent tab")
        registry.close(ai.id)
        check(registry.reopenClosedTab(owner: owner)?.usesAgentContext == true, "reopen preserves isolated actor")
        let bot = BrowserTabOwner.bot(botID: "w58-bot")
        let botTab = registry.tabForAgentNavigation(ownedBy: bot)!
        check(botTab.usesAgentContext && registry.selectedTab(ownedBy: bot)?.id == botTab.id, "bot-owned selection")
    }
    @MainActor static func human(_ root: URL) async throws {
        let settings = root.appendingPathComponent("settings.json")
        try Data(#"{"searchEngine":"bing","passwordFillRequiresAuth":"bad","unrelated":7}"#.utf8).write(to: settings)
        check(BrowserGeneralSettings.load(from: settings).passwordFillRequiresAuth, "malformed flag defaults true")
        let stale = BrowserGeneralSettings.load(from: settings)
        try BrowserGeneralSettings.savePasswordFillRequiresAuth(false, to: settings)
        try stale.save(to: settings)
        check(!BrowserGeneralSettings.load(from: settings).passwordFillRequiresAuth, "merge preserves off")
        try BrowserGeneralSettings.savePasswordFillRequiresAuth(true, to: settings)
        check(BrowserGeneralSettings.load(from: settings).passwordFillRequiresAuth, "flag persists true")
        let store = W58Secrets(), auth = W58Auth(), page = W58HumanPage()
        let vault = BrowserPasswordVault(indexURL: nil, secrets: store, authenticator: auth)
        try vault.add(origin: "https://example.com", username: "human", password: "fixture-secret-human", title: "Human", source: .manual)
        try vault.add(origin: "https://other.example", username: "human", password: "fixture-secret-other", title: "Other", source: .manual)
        var now = 100.0, enabled = true, requires = true, asks = 0
        let assist = BrowserPasswordAssist(bridge: page, vault: vault, enabled: {enabled}, authenticator: auth,
            requiresAuth: {requires}, uptime: {now}, ask: { _, _, _ in asks += 1; return true })
        auth.during = { check(page.fills == 0 && store.reads == 0, "authentication before secret read and fill") }
        page.detect(); await settle()
        check(page.fills == 1 && auth.calls == 1 && asks == 1, "ask then auth then fill")
        check(auth.reasons == ["填入 example.com 的密碼"], "reason uses host")
        auth.during = nil
        now = 399; page.reload(); page.detect(); await settle()
        check(page.fills == 2 && auth.calls == 1, "299 seconds cache")
        now = 400; page.reload(); page.detect(); await settle()
        check(page.fills == 3 && auth.calls == 2, "300 seconds expires")
        page.passwordAssistOrigin = "https://other.example"; page.reload(); page.detect(); await settle()
        check(auth.calls == 3, "different origin no shared auth")
        let second = W58HumanPage()
        let assist2 = BrowserPasswordAssist(bridge: second, vault: vault, enabled: {true}, authenticator: auth,
            requiresAuth: {true}, uptime: {now}, ask: {_,_,_ in true})
        second.detect(); await settle()
        check(auth.calls == 4, "different tab no shared auth")
        second.onPasswordAssistInvalidated?(false, false)
        second.reload(); second.detect(); await settle()
        check(second.fills == 2 && auth.calls == 4, "ordinary navigation preserves same-tab origin auth cache")
        assist2.invalidate()
        auth.deny = true; now += 300; page.reload(); let reads = store.reads; page.detect(); await settle()
        let deniedAsks = asks
        page.detect(); await settle()
        check(page.fills == 4 && store.reads == reads && asks == deniedAsks, "denied auth no secret read/fill/reask")
        requires = false; page.reload(); page.detect(); await settle()
        check(page.fills == 5, "explicit flag off bypasses authenticator only")
        requires = true; auth.deny = false; now += 300
        auth.during = { page.reload() }
        page.reload(); page.detect(); await settle()
        check(page.fills == 5, "navigation during auth no fill")
        auth.during = nil
        enabled = false; assist.refreshSettings(); enabled = true; assist.refreshSettings()
        page.passwordAssistIsHuman = false; assist.refreshSettings(); page.reload(); page.detect(); await settle()
        check(!page.passwordAssistEnabled && page.fills == 5, "agent never activates human assist")
        assist.invalidate()
    }
    @MainActor static func vault(_ root: URL) async throws {
        let humanSecrets = W58Secrets(), aiSecrets = W58Secrets(), auth = W58Auth()
        let humanIndex = root.appendingPathComponent("human-index-\(UUID()).json")
        let human = BrowserPasswordVault(indexURL: humanIndex, secrets: humanSecrets, authenticator: auth)
        let index = root.appendingPathComponent("ai-index-\(UUID()).json")
        let ai = BrowserAIVault(indexURL: index, secrets: aiSecrets, authenticator: auth)
        let caller = AICaller(engine: "codex", botID: "bot-A", threadID: "thread-A", preset: .fullAccess)
        let h = try human.add(origin: "https://example.com", username: "human", password: "fixture-secret-human", title: "", source: .manual)
        let a = try ai.add(origin: "https://example.com", username: "ai", password: "fixture-secret-ai", label: "AI")
        check(human.matches(origin: "https://example.com").map(\.id) == [h.id], "human cannot match AI")
        check(ai.matches(origin: "https://example.com", caller: caller).map(\.id) == [a.id], "AI cannot match human")
        check(humanSecrets.values[a.id] == nil && aiSecrets.values[h.id] == nil, "separate secret backends")
        check(!String(decoding: try Data(contentsOf: index), as: UTF8.self).contains("fixture-secret-"), "metadata contains no passwords")
        for scope in [CallerScope.anyEngine, .bot(id: "bot-A"), .thread(id: "thread-A")] {
            check(scope.allows(caller), "scope accepts bound caller")
            check(try JSONDecoder().decode(CallerScope.self, from: JSONEncoder().encode(scope)) == scope, "scope roundtrip")
        }
        check(!CallerScope.bot(id: "bot-B").allows(caller), "foreign bot denied")
        check(!CallerScope.thread(id: "thread-B").allows(caller), "foreign thread denied")
        check(!CallerScope.bot(id: "").allows(caller), "empty scope denied")
        let uuid = UUID()
        check(CallerScope.thread(id: uuid.uuidString.lowercased()).allows(
            AICaller(engine: "codex", botID: nil, threadID: uuid.uuidString, preset: nil)), "UUID case insensitive")
        let wrongHuman = BrowserPasswordVault(indexURL: index, secrets: humanSecrets, authenticator: auth)
        let wrongAI = BrowserAIVault(indexURL: humanIndex, secrets: aiSecrets, authenticator: auth)
        check(wrongHuman.storageError != nil && wrongHuman.matches(origin: "https://example.com").isEmpty,
            "human rejects AI metadata index")
        check(wrongAI.storageError != nil && wrongAI.matches(origin: "https://example.com", caller: caller).isEmpty,
            "AI rejects human metadata index")
        check(ai.matches(origin: "https://sub.example.com", caller: caller).isEmpty, "no suffix match")
        check(ai.matches(origin: "http://example.com", caller: caller).isEmpty, "no scheme downgrade")
        check(ai.matches(origin: "https://example.com:8443", caller: caller).isEmpty, "no cross-port credential release")
        try ai.update(a.id, allowedCallers: .bot(id: "bot-A"))
        let csv = root.appendingPathComponent("input.csv")
        try Data("origin,username,password,label\r\nhttps://example.com,ai,fixture-secret-new,updated\r\nhttps://new.example,b,fixture-secret-b,\"quoted, label\"\r\ninvalid,b,,skip\r\n".utf8).write(to: csv)
        let result = try ai.importCSV(url: csv)
        check(result.added == 1 && result.updated == 1 && result.skipped == 1, "CSV counts")
        check(ai.credentials.first { $0.id == a.id }?.allowedCallers == .bot(id: "bot-A"), "CSV does not widen scope")
        let authBefore = auth.calls
        check(try await ai.revealPassword(id: a.id, reason: "reveal") == "fixture-secret-new", "human authenticated AI reveal")
        let exported = try await ai.exportCSV(reason: "export")
        check(auth.calls == authBefore + 2 && String(decoding: exported, as: UTF8.self).hasPrefix("origin,username,password,label"), "export authenticates")
        auth.deny = true
        let reads = aiSecrets.reads
        do { _ = try await ai.exportCSV(reason: "denied"); preconditionFailure() } catch {}
        check(aiSecrets.reads == reads, "denied export no reads")
        try ai.recordUse(a.id)
        check(ai.credentials.first { $0.id == a.id }?.useCount == 1, "usage count")
        let audit = root.appendingPathComponent("ai-audit-\(UUID()).log")
        try BrowserDiagnosticsAudit.appendAILogin(caller: "codex/bot-A/thread-A", origin: "https://example.com/path?private=1",
            username: "ai\nforged", decision: "allow", to: audit)
        let log = try String(contentsOf: audit, encoding: .utf8)
        check(!log.contains("fixture-secret-") && log.split(separator: "\n").count == 1 && !log.contains("private=1"), "audit no secrets/query/injected lines")
        let tail = BrowserDiagnosticsAudit.readTail(at: audit)
        check(tail.lines.first?.contains("ai_login caller=codex/bot-A/thread-A origin=example.com username=aiforged decision=allow") == true, "audit readable line")
        let restored = BrowserAIVault(indexURL: index, secrets: aiSecrets, authenticator: auth)
        check(restored.credentials == ai.credentials, "AI metadata reload")
        try ai.delete(a.id)
        check(aiSecrets.values[a.id] == nil && ai.credentials.count == 1 && human.credentials.count == 1, "AI delete does not mutate human")
    }
    @MainActor static func login() async throws {
        let store = W58Secrets()
        let vault = BrowserAIVault(indexURL: nil, secrets: store, authenticator: W58Auth())
        let account = try vault.add(origin: "https://example.com", username: "ai", password: "fixture-secret-login", label: "Work")
        var asks = 0, notices = 0, audits: [String] = []
        let ask: (String,String) async -> Bool = {title,detail in
            check(title == "AI 想登入 example.com" && detail == "Work・ai", "Island login text")
            asks += 1; return true
        }
        let audit: (String,String,String) throws -> Void = { audits.append("\($0)|\($1)|\($2)") }
        for preset: TatwoPermissionPreset? in [.fullAccess,.approveForMe,.askFirst,nil,.configFile] {
            let before = asks, beforeNotice = notices, page = W58AgentPage()
            let caller = AICaller(engine: "codex", botID: nil, threadID: "t", preset: preset)
            let result = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
                caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in notices += 1}, audit: audit)
            check(result.ok && result.finalURL == "https://example.com/home" && result.title == "Home", "login result shape")
            check(page.fills == 1 && page.received == "fixture-secret-login", "native single fill")
            check(asks - before == ([TatwoPermissionPreset.askFirst,.configFile].contains(preset ?? .askFirst) ? 1 : 0), "preset ask matrix")
            check(notices - beforeNotice == (preset == .approveForMe ? 1 : 0), "preset notice matrix")
        }
        check(vault.credentials[0].useCount == 5 && !audits.joined().contains("fixture-secret-"), "usage and audit secret exclusion")
        for preset: TatwoPermissionPreset? in [.fullAccess,.approveForMe,.askFirst,nil] {
            let page = W58AgentPage(), caller = AICaller(engine: "codex", botID: nil, threadID: "t", preset: preset, readOnly: true)
            await rejects("ai_login_read_only") {
                _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
                    caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: audit)
            }
            check(page.preparations == 0 && page.fills == 0, "readonly no dispatch")
        }
        let caller = AICaller(engine: "codex", botID: nil, threadID: "t", preset: .askFirst)
        let page = W58AgentPage()
        page.aiLoginIsAgent = false
        await rejects("ai_login_human_tab_denied") {
            _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
                caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: audit)
        }
        check(page.fills == 0 && page.preparations == 0, "human never prepared or filled")
        page.aiLoginIsAgent = true
        for code in ["ai_login_no_form", "ai_login_two_factor_required"] {
            page.error = code
            await rejects(code) { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
                caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: audit) }
        }
        page.error = ""
        await rejects("ai_login_no_account") { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: "missing",
            caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: audit) }
        await rejects("ai_login_origin_mismatch") { _ = try await BrowserAILogin.login(target: page, origin: "https://other.example", username: nil,
            caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: audit) }
        await rejects("ai_login_denied") { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
            caller: caller, vault: vault, current: {true}, ask: {_,_ in false}, notice: {_ in}, audit: audit) }
        var current = true
        let reads = store.reads
        await rejects("ai_login_stale_page") { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
            caller: caller, vault: vault, current: {current}, ask: {_,_ in current = false; return true}, notice: {_ in}, audit: audit) }
        check(store.reads == reads && page.fills == 0, "revocation after ask before secret read")
        await rejects("ai_login_stale_page") { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
            caller: caller, vault: vault, current: {true}, ask: {_,_ in try! vault.update(account.id, password: "fixture-secret-edited"); return true}, notice: {_ in}, audit: audit) }
        check(page.fills == 0, "password-only edit revokes approval")
        await rejects("ai_login_storage_or_cancelled") { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
            caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: {_,_,_ in throw BrowserPasswordVaultError.indexUnavailable}) }
        check(page.fills == 0, "failed audit prevents dispatch")
        page.finalURL = "https://other.example/done"
        await rejects("ai_login_origin_changed_do_not_replay") { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
            caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: audit) }
        check(vault.credentials[0].useCount == 5, "cross-origin completion not successful use")
        page.finalURL = "https://example.com/home"
        page.complete = false
        await rejects("ai_login_load_timeout_do_not_replay") { _ = try await BrowserAILogin.login(target: page, origin: "https://example.com", username: nil,
            caller: caller, vault: vault, current: {true}, ask: ask, notice: {_ in}, audit: audit, timeout: 0.01) }
        check(page.fills == 2 && vault.credentials[0].useCount == 5, "no next load means no success nor usage")
    }
    @MainActor static func render(_ root: URL) throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let human = BrowserPasswordVault(indexURL: nil, secrets: InMemorySecretStore(), authenticator: AlwaysAllowAuthenticator())
        let ai = BrowserAIVault(indexURL: nil, secrets: InMemorySecretStore(), authenticator: AlwaysAllowAuthenticator())
        try human.add(origin: "https://example.com", username: "human@example.com", password: "fixture-secret-human", title: "Personal", source: .manual)
        try ai.add(origin: "https://work.example", username: "assistant@example.com", password: "fixture-secret-ai", label: "工作帳號", allowedCallers: .anyEngine)
        try ai.add(origin: "https://tools.example", username: "research-bot", password: "fixture-secret-bot", label: "研究專用", allowedCallers: .bot(id: "research"))
        let host = NSHostingView(rootView: ScrollView { BrowserPasswordsSettingsView(vault: human).padding(18) }
            .frame(width: 680, height: 780).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 680,height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("w58-passwords.png"))
        window.close()
        print("W58 synthetic settings render 680x780; no real Keychain or installed App")
    }
}
