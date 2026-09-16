import AppKit
import Foundation
import SwiftUI
import WebKit

// No production singleton, host Keychain, account or network is used by this executable.
enum BrowserRequestPolicyEvaluator {
    static func origin(of url: URL) -> String? { BrowserPasswordOrigin.normalized(url.absoluteString) }
}
@MainActor final class IslandNotice {
    static let shared = IslandNotice()
    enum Decision { case allow, cancel }
    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval) async -> Decision { .cancel }
    func confirm(title: String, detail: String, confirmLabel: String, cancelLabel: String, timeout: TimeInterval = 20) async -> Bool { false }
    func info(title: String, detail: String) {}
}
final class W59Secrets: BrowserSecretStore {
    var values: [UUID: String] = [:]
    var failWrite = false
    func set(_ secret: String, for id: UUID) throws {
        if failWrite { throw BrowserPasswordVaultError.secretUnavailable }
        values[id] = secret
    }
    func get(_ id: UUID) throws -> String? { values[id] }
    func remove(_ id: UUID) throws { values.removeValue(forKey: id) }
}
@MainActor final class W59Page: BrowserAILoginTarget {
    var aiLoginIsAgent = true
    var aiLoginOrigin: String? = "https://example.com"
    var navigationGeneration: UInt64 = 1
    var aiLoginState = BrowserAILoginState(phase: "idle")
    var fills = 0, codes = 0
    var code = ""
    var otpInitially = false
    var repeatOTP = false
    func prepareAgentLogin() -> Bool {
        aiLoginState = .init(phase: otpInitially ? "two_factor" : "ready",
            formID: otpInitially ? "w59-otp" : "w58-login", generation: navigationGeneration)
        return true
    }
    func cancelAgentLogin() { aiLoginState = .init(phase: "idle") }
    func fillCredentialForAgentUsername(_ username: String, password: String, formID: String, navigationGeneration: UInt64) -> Bool {
        fills += 1; self.navigationGeneration += 1
        aiLoginState = .init(phase: "two_factor", formID: "w59-otp", generation: self.navigationGeneration)
        return true
    }
    func fillOneTimeCodeForAgent(_ code: String, navigationGeneration: UInt64) -> Bool {
        self.code = code; codes += 1; self.navigationGeneration += 1
        aiLoginState = .init(phase: repeatOTP ? "two_factor" : "complete", formID: "w59-otp",
            generation: self.navigationGeneration, finalURL: "https://example.com/home", title: "Example")
        return true
    }
}
@main struct W59Checks {
    @MainActor static var count = 0
    @MainActor static func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    @MainActor static func fails(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("expected failure") } catch { count += 1 }
    }
    @MainActor static func vault(_ store: W59Secrets = W59Secrets(), pending: W59Secrets = W59Secrets()) -> BrowserAIVault {
        BrowserAIVault(indexURL: nil, secrets: store, authenticator: AlwaysAllowAuthenticator(),
            totpSecrets: W59Secrets(), pendingSecrets: pending)
    }
    @MainActor static func main() async throws {
        try cryptography()
        try await credentials()
        try await rotation()
        try await breaches()
        if CommandLine.arguments.contains("--render") { try render(URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("W59 production Swift fixture passed: \(count) checks")
    }
    @MainActor static func cryptography() throws {
        check(CustodySHA1.hex("") == "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709", "SHA1 empty")
        check(CustodySHA1.hex("abc") == "A9993E364706816ABA3E25717850C26C9CD0D89D", "SHA1 abc")
        // RFC 6238 Appendix B, SHA1 secret 12345678901234567890 (public test vector).
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let vectors: [(Double, String)] = [(59,"94287082"),(1111111109,"07081804"),(1111111111,"14050471"),
            (1234567890,"89005924"),(2000000000,"69279037"),(20000000000,"65353130")]
        for (time, code) in vectors {
            check(try TOTP.code(secret: secret, at: time, digits: 8) == code, "RFC SHA1 vector")
            check(try TOTP.code(secret: secret, at: time) == String(code.suffix(6)), "production six-digit truncation")
        }
        check(try TOTP.code(secret: secret, at: 29) != TOTP.code(secret: secret, at: 30), "30 second boundary")
        let uri = "otpauth://totp/example.com:example?secret=\(secret)&issuer=example.com"
        check(try TOTP.secret(from: uri) == secret, "otpauth parse")
        for input in [uri + "&digits=8", uri + "&period=60", uri + "&algorithm=SHA256", uri + "&secret=AAAA",
                      uri.replacingOccurrences(of: "//totp", with: "//hotp"), "bad-secret", "AAAAAAAAAAAAAAAAA1"] {
            fails { _ = try TOTP.secret(from: input) }
        }
        fails { _ = try TOTP.code(secret: secret, at: -.infinity) }
        for _ in 0..<64 {
            let p = try AIPasswordChange.strongPassword()
            check(p.count == 20 && p.contains(where: \.isUppercase) && p.contains(where: \.isLowercase) &&
                p.contains(where: \.isNumber) && p.contains { !$0.isLetter && !$0.isNumber }, "20-character CSPRNG composition")
        }
    }
    @MainActor static func credentials() async throws {
        let store = W59Secrets(), pending = W59Secrets(), v = vault(store, pending: pending)
        let item = try v.add(origin: "https://example.com", username: "example-ai", password: "example-old", label: "示範")
        check(item.authenticatorStatus == .unbound, "unbound status")
        try v.bindAuthenticator(item.id, secret: nil, humanHeld: true)
        check(v.credentials[0].authenticatorStatus == .humanHeld, "human-held status")
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        try v.bindAuthenticator(item.id, secret: secret, humanHeld: false)
        check(v.credentials[0].authenticatorStatus == .managed, "managed status")
        let json = String(decoding: try JSONEncoder().encode(v.credentials), as: UTF8.self)
        check(!json.contains(secret) && !json.contains("example-old") && !json.contains("\"totpSecret\""), "metadata never encodes secrets")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        for key in ["hasTOTPSecret","authenticatorHeldByHuman","disabledAt","twoFactorRequiredAt","passwordChangeFailedAt","breachedAt"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(AICredential.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.statusTitle == "正常" && decoded.authenticatorStatus == .unbound, "W58 metadata migration")
        let indexURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("migration-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"credentials":[legacy]]).write(to:indexURL)
        let upgraded = BrowserAIVault(indexURL:indexURL, secrets:store, authenticator:AlwaysAllowAuthenticator(),
            totpSecrets:W59Secrets(), pendingSecrets:W59Secrets())
        check(upgraded.credentials.count == 1, "W58 index loads without losing accounts")
        try upgraded.setEnabled(item.id, enabled:false)
        let stored = try JSONSerialization.jsonObject(with:Data(contentsOf:indexURL)) as! [String:Any]
        check(stored["schemaVersion"] as? Int == 2, "new index fails closed in old W58 readers")

        let caller = AICaller(engine: "example", botID: nil, threadID: "example-thread", preset: .fullAccess)
        let page = W59Page()
        let result = try await BrowserAILogin.login(target: page, origin: item.origin, username: nil,
            caller: caller, vault: v, current: {true}, ask: {_,_ in true}, notice: {_ in}, audit: {_,_,_ in})
        check(result.ok && page.fills == 1 && page.codes == 1 && page.code.count == 6, "password then one TOTP dispatch")
        page.otpInitially = true; page.repeatOTP = true
        do {
            _ = try await BrowserAILogin.login(target: page, origin: item.origin, username: nil,
                caller: caller, vault: v, current: {true}, ask: {_,_ in true}, notice: {_ in}, audit: {_,_,_ in})
            preconditionFailure("repeated OTP must stop")
        } catch {
            check((error as? AIVaultLoginError)?.description == "ai_login_two_factor_required", "repeated OTP error")
            check(v.credentials[0].statusTitle == "2FA 需人接手", "2FA result visible")
        }
        try v.bindAuthenticator(item.id, secret: nil, humanHeld: false)
        let before = page.codes
        do {
            _ = try await BrowserAILogin.login(target: page, origin: item.origin, username: nil,
                caller: caller, vault: v, current: {true}, ask: {_,_ in true}, notice: {_ in}, audit: {_,_,_ in})
        } catch { check(page.codes == before, "missing secret never sends a code") }
        try v.setEnabled(item.id, enabled: false)
        check(v.matches(origin: item.origin, caller: caller).isEmpty && v.credentials[0].statusTitle == "已停用", "disabled stops release")
        try v.setEnabled(item.id, enabled: true)
        let csv = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\n\"Example, AI\",https://example.com,example-import,example-new,\"private note\",\(secret.isEmpty ? "" : "otpauth://totp/example?secret=" + secret)\r\nPersonal,https://example.invalid,example-human,example-personal,,\r\nUnsupported,https://example.invalid,example-unsupported,example-password,,otpauth://hotp/example?secret=\(secret)\r\n"
        let preview = try AIICloudImportPreview.parse(Data(csv.utf8))
        check(preview.items.count == 2 && preview.skipped == 1 && preview.items[0].totpSecret == secret, "iCloud CSV OTPAuth and unsupported row")
        check(try v.importICloud([]) == 0 && v.credentials.count == 1, "default empty selection imports nothing")
        check(try v.importICloud([preview.items[0]]) == 1 && v.credentials.count == 2, "only explicitly selected account imported")
        check(!v.credentials.contains { $0.username == "example-human" }, "personal unselected account absent")
        try v.update(v.credentials[1].id, allowedCallers: .thread(id: "example-thread"))
        _ = try v.importICloud([preview.items[0]])
        check(v.credentials[1].allowedCallers == .thread(id: "example-thread"), "import cannot widen existing scope")
        try v.stagePasswordChange(item.id, password: "example-candidate")
        fails { try v.stagePasswordChange(item.id, password: "example-replacement") }
        fails { try v.beginPasswordChange(item.id) }
        check(pending.values[item.id] == "example-candidate" && store.values[item.id] == "example-old", "unresolved candidate cannot be overwritten")
        try v.recordPasswordChangeFailure(item.id)
        try await v.reconcilePendingPasswordChange(item.id, useNewPassword: true)
        check(store.values[item.id] == "example-candidate" && pending.values[item.id] == nil, "human reconciliation updates vault after auth")
        try v.disableAll()
        check(v.credentials.allSatisfy { $0.disabledAt != nil }, "emergency disables every AI account")
    }
    @MainActor static func rotation() async throws {
        let stages: [AIPasswordChange.Stage] = [.generating,.opening,.asking,.loggingIn,.confirming,.authenticating,.staging,.filling,.submitting,.verifying,.committing]
        for failure in stages + [.idle] {
            let store = W59Secrets(), pending = W59Secrets(), v = vault(store, pending: pending)
            let item = try v.add(origin: "https://example.com", username: "example-ai", password: "example-old", label: "示範")
            let flow = AIPasswordChange()
            var cancelled = 0, calls: [AIPasswordChange.Stage] = []
            func step(_ stage: AIPasswordChange.Stage) throws {
                calls.append(stage)
                if failure == stage { throw AIPasswordChange.Failure.unsupported }
            }
            await flow.run(origin: item.origin, operations: .init(current: {true},
                generate: {try step(.generating); return "example-candidate"},
                open: {_ in try step(.opening)}, ask: { calls.append(.asking); return failure != .asking },
                login: {try step(.loggingIn)}, fill: {_ in try step(.filling)},
                confirm: {calls.append(.confirming); return failure != .confirming},
                authenticate: {try step(.authenticating)}, stageSecret: {try step(.staging); try v.stagePasswordChange(item.id, password: $0)},
                submit: {try step(.submitting)}, verify: {try step(.verifying); return true},
                commit: {try step(.committing); try v.finishPasswordChange(item.id, password: $0)},
                cancel: {cancelled += 1}, failed: {try? v.recordPasswordChangeFailure(item.id)}))
            check(cancelled == 1, "all paths clear native fields")
            if failure == .idle {
                check(flow.stage == .complete && store.values[item.id] == "example-candidate", "only verified success commits")
                check(calls.firstIndex(of: .authenticating)! < calls.firstIndex(of: .filling)!, "auth before any secret-bearing DOM fill")
                check(calls.firstIndex(of: .staging)! < calls.firstIndex(of: .filling)!, "candidate saved before page input events")
            } else {
                check(flow.stage == .failed && flow.failedAt == failure && store.values[item.id] == "example-old", "each stage failure preserves old canonical secret")
                check(v.credentials[0].statusTitle == "換密碼未完成", "every failure visible")
            }
        }
        // Auto-assistance bypasses only the first ask, never final confirm or auth.
        let flow = AIPasswordChange(); var asks = 0, confirms = 0, auths = 0
        await flow.run(origin: "https://example.com", automaticallyAssisted: true, operations: .init(current: {true},
            generate: {"example-candidate"}, open: {_ in}, ask: {asks += 1; return false}, login: {}, fill: {_ in},
            confirm: {confirms += 1; return true}, authenticate: {auths += 1}, stageSecret: {_ in}, submit: {},
            verify: {true}, commit: {_ in}, cancel: {}, failed: {}))
        check(flow.stage == .complete && asks == 0 && confirms == 1 && auths == 1, "automatic mode still asks and authenticates at final gate")
    }
    @MainActor static func breaches() async throws {
        let human = BrowserPasswordVault(indexURL: nil, secrets: W59Secrets(), authenticator: AlwaysAllowAuthenticator())
        let ai = vault()
        let a = try ai.add(origin: "https://example.com", username: "example-ai", password: "example-shared", label: "AI")
        let h = try human.add(origin: "https://example.com", username: "example-human", password: "example-shared", title: "Human", source: .manual)
        let hash = CustodySHA1.hex("example-shared"), parts = try BreachRules.splitSHA1(hash)
        check(parts.prefix.count == 5 && parts.suffix.count == 35, "HIBP partition")
        check(try BreachRules.match(range: "\(parts.suffix):0\r\n", sha1: hash) == 0, "padding ignored")
        check(try BreachRules.match(range: "bad:10\r\n\(parts.suffix.lowercased()):12\r\n", sha1: hash) == 12, "local suffix match")
        fails { _ = try BreachRules.match(range: "<html>unavailable</html>", sha1: hash) }
        let keyA = BreachRules.Account(vault: .ai, id: a.id), keyH = BreachRules.Account(vault: .human, id: h.id)
        let local = BreachRules.localRules([keyA:hash,keyH:hash])
        check(local.reused == [keyA,keyH] && local.sharedAcrossVaults == [keyA,keyH], "duplicate and cross-vault rules")
        var queries: [String] = [], notices: [String] = [], assists = 0
        let detector = BreachDetector(human: human, ai: ai, defaults: nil, lookup: { prefix in
            queries.append(prefix); return "\(parts.suffix):12\n"
        }, notice: {notices.append($0)})
        detector.automaticallyAssistAI = true; detector.onAssistAI = {_ in assists += 1}
        await detector.scan(full: true)
        check(queries == [parts.prefix], "only prefix goes to transport; one range per scan")
        check(ai.credentials[0].breachedAt != nil && human.credentials[0].breachedAt != nil, "both vaults marked")
        check(assists == 1 && notices.count == 1 && !detector.localWarnings.isEmpty, "notice, local warning and AI opt-in route")
        await detector.scan(full: true)
        check(assists == 1, "repeat finding does not repeatedly rotate")
        let stale = BreachDetector(human: human, ai: ai, defaults: nil, lookup: {_ in
            try ai.update(a.id, password: "example-changed")
            return "\(parts.suffix):99\n"
        }, notice: {_ in})
        await stale.scan(full: false, requested: [keyA])
        check(ai.credentials[0].breachedAt == nil, "network await cannot apply stale breach to changed secret")
        let offline = BreachDetector(human: human, ai: ai, defaults: nil, lookup: {_ in throw BreachRules.Failure.unavailable}, notice: {_ in})
        await offline.scan(full: true)
        check(offline.pendingRetryCount == 2, "failed changed-account lookups remain queued for retry")
        check(human.credentials[0].breachedAt != nil && offline.summary?.contains("未全部完成") == true, "network failure preserves previous warning")
    }
    @MainActor static func render(_ root: URL) throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let ai = vault(), human = BrowserPasswordVault(indexURL: nil, secrets: W59Secrets(), authenticator: AlwaysAllowAuthenticator())
        let a = try ai.add(origin: "https://example.com", username: "example-ai", password: "example-password", label: "程式碼")
        try ai.bindAuthenticator(a.id, secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", humanHeld: false)
        let b = try ai.add(origin: "https://example.invalid", username: "example-bot", password: "example-other", label: "文件")
        try ai.bindAuthenticator(b.id, secret: nil, humanHeld: true); try ai.recordTwoFactorRequired(b.id)
        let c = try ai.add(origin: "https://example.com", username: "example-import", password: "example-third", label: "商店")
        try ai.setBreached(c.id, breached: true)
        let detector = BreachDetector(human: human, ai: ai, defaults: nil, lookup: {_ in ""}, notice: {_ in})
        for surface in AgentAccountsSettingsView.Surface.allCases {
            let content = AgentAccountsSettingsView(vault: ai, detector: detector, initialSurface: surface,
                changePassword: {_ in}, activity: {}).frame(width: 880, height: 700).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x:0,y:0,width:880,height:700), styleMask:[.borderless], backing:.buffered, defer:false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.3))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in:host.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(surface == .accounts ? "w59-accounts.png" : "w59-wallets.png"))
            window.close()
        }
        print("W59 native synthetic settings renders: 880x700, accounts and wallets; no real vault")
    }
}
