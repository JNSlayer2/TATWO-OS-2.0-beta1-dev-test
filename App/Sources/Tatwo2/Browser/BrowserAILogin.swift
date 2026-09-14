import Foundation

struct BrowserAILoginState {
    var phase: String
    var formID = ""
    var generation: UInt64 = 0
    var error = ""
    var finalURL = ""
    var title = ""
}

@MainActor
protocol BrowserAILoginTarget: AnyObject {
    var aiLoginIsAgent: Bool { get }
    var aiLoginOrigin: String? { get }
    var navigationGeneration: UInt64 { get }
    var aiLoginState: BrowserAILoginState { get }
    func prepareAgentLogin() -> Bool
    func cancelAgentLogin()
    func fillCredentialForAgentUsername(_ username: String, password: String, formID: String,
                                       navigationGeneration: UInt64) -> Bool
}

/// The only agent login coordinator. All dependencies are native-bound, never MCP arguments.
/// No global consent cache; every attempt is caller/target/revision bound and single-dispatch.
@MainActor
enum BrowserAILogin {
    struct Result: Equatable { let ok: Bool; let finalURL: String; let title: String }
    static func login(target: any BrowserAILoginTarget, origin raw: String, username: String?,
                      caller: AICaller, vault: BrowserAIVault,
                      current: () -> Bool,
                      ask: (String, String) async -> Bool,
                      notice: (String) -> Void,
                      audit: (String, String, String) throws -> Void,
                      timeout: TimeInterval = 30) async throws -> Result {
        var decision = "denied"
        var accountName = username ?? ""
        let host = URLComponents(string: raw)?.host ?? ""
        do {
            guard target.aiLoginIsAgent else { throw AIVaultLoginError("ai_login_human_tab_denied") }
            guard let origin = BrowserPasswordOrigin.normalized(raw),
                  origin.hasPrefix("https://"),
                  BrowserPasswordOrigin.normalized(target.aiLoginOrigin ?? "") == origin else {
                throw AIVaultLoginError("ai_login_origin_mismatch")
            }
            guard current(), !Task.isCancelled else { throw AIVaultLoginError("ai_login_revoked") }
            let policy = AIVaultLoginPolicy.decision(caller.preset, readOnly: caller.readOnly)
            guard policy != .deny else { throw AIVaultLoginError("ai_login_read_only") }
            let matches = vault.matches(origin: origin, caller: caller).filter { username == nil || $0.username == username }
            guard !matches.isEmpty else { throw AIVaultLoginError("ai_login_no_account") }
            guard matches.count == 1, let account = matches.first else { throw AIVaultLoginError("ai_login_ambiguous_account") }
            accountName = account.username
            let generation = target.navigationGeneration
            let revision = vault.revision
            func pageCurrent() -> Bool {
                current() && !Task.isCancelled && target.aiLoginIsAgent &&
                    target.navigationGeneration == generation && generation > 0 &&
                    BrowserPasswordOrigin.normalized(target.aiLoginOrigin ?? "") == origin && vault.revision == revision
            }
            guard pageCurrent(), target.prepareAgentLogin() else { throw AIVaultLoginError("ai_login_no_form") }
            defer { target.cancelAgentLogin() }
            let prepareDeadline = ProcessInfo.processInfo.systemUptime + min(5, timeout)
            while target.aiLoginState.phase == "preparing" {
                guard pageCurrent() else { throw AIVaultLoginError("ai_login_stale_page") }
                guard ProcessInfo.processInfo.systemUptime < prepareDeadline else { throw AIVaultLoginError("ai_login_form_timeout") }
                try await Task.sleep(for: .milliseconds(50))
            }
            let form = target.aiLoginState
            guard form.error.isEmpty else { throw AIVaultLoginError(form.error) }
            guard pageCurrent(), form.phase == "ready", !form.formID.isEmpty, form.generation == generation else {
                throw AIVaultLoginError("ai_login_stale_page")
            }
            decision = policy.rawValue
            if policy == .ask {
                let detail = safeDisplay("\(account.label)・\(account.username)")
                guard await ask("AI 想登入 \(host)", detail) else { throw AIVaultLoginError("ai_login_denied") }
                decision = "approved"
            }
            guard pageCurrent() else { throw AIVaultLoginError("ai_login_stale_page") }
            // Persist the authorization before a side effect. Failure to audit prevents dispatch.
            try audit(host, accountName, decision)
            try vault.fillForApprovedLogin(account.id, caller: caller, origin: origin) { user, password in
                guard pageCurrent() else { return false }
                return target.fillCredentialForAgentUsername(user, password: password, formID: form.formID,
                    navigationGeneration: generation)
            }
            decision = "dispatched"
            // The renderer, not a timer or URL change, produces complete after the next load_end scan.
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                guard current(), !Task.isCancelled, target.aiLoginIsAgent, vault.revision == revision else {
                    throw AIVaultLoginError("ai_login_result_unavailable_do_not_replay")
                }
                let state = target.aiLoginState
                guard state.error.isEmpty else { throw AIVaultLoginError(state.error) }
                if state.phase == "complete", state.generation > generation {
                    guard BrowserPasswordOrigin.normalized(target.aiLoginOrigin ?? "") == origin,
                          BrowserPasswordOrigin.normalized(state.finalURL) == origin else {
                        throw AIVaultLoginError("ai_login_origin_changed_do_not_replay")
                    }
                    try vault.recordUse(account.id)
                    try audit(host, accountName, "completed")
                    if policy == .allowWithNotice { notice("AI 已用 \(safeDisplay(account.label)) 登入 \(host)") }
                    return Result(ok: true, finalURL: state.finalURL, title: state.title)
                }
                guard state.phase != "idle" else { throw AIVaultLoginError("ai_login_revoked") }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw AIVaultLoginError("ai_login_load_timeout_do_not_replay")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            // Only allowlisted/native codes reach audit/wire; Keychain/provider errors never do.
            let code = (error as? AIVaultLoginError)?.description ?? "ai_login_storage_or_cancelled"
            try? audit(host, accountName, "\(decision):\(code)")
            throw AIVaultLoginError(code)
        }
    }

    private static func safeDisplay(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
        }.map(String.init).joined().prefix(180))
    }
}
