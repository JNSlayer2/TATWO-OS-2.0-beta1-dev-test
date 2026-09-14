import Combine
import Foundation

/// Deliberately separate from BrowserAgentBridge and metadata/telemetry transports.
@MainActor
protocol BrowserPasswordAssistBridge: AnyObject {
    var passwordAssistIsHuman: Bool { get }
    var passwordAssistOrigin: String? { get }
    var navigationGeneration: UInt64 { get }
    var passwordAssistEnabled: Bool { get set }
    var onLoginFormDetected: ((String, String, String, String, String) -> Void)? { get set }
    var onCredentialSubmitted: ((String, String, String) -> Void)? { get set }
    var onPasswordAssistPageLoaded: ((String, UInt64, Bool, Bool) -> Void)? { get set }
    var onPasswordAssistInvalidated: ((Bool, Bool) -> Void)? { get set }
    func fillCredentialUsername(_ username: String, password: String, formID: String,
                                navigationGeneration: UInt64)
}

/// One native tab lifetime. Secrets exist only in ephemeral callbacks/pending submission;
/// persistence is exclusively an approved vault.add/update operation.
@MainActor
final class BrowserPasswordAssist {
    typealias Ask = @MainActor (String, String, String) async -> Bool
    private weak var bridge: (any BrowserPasswordAssistBridge)?
    private let vault: BrowserPasswordVault
    private let enabled: () -> Bool
    private let ask: Ask
    private let authenticator: BrowserVaultAuthenticator
    private let requiresAuth: () -> Bool
    private let uptime: () -> TimeInterval
    // Per-tab, exact origin, monotonic and memory-only. Never shared with reveal/export or AI.
    private var authenticatedOrigins: [String: TimeInterval] = [:]
    private var askedOrigins: Set<String> = []
    private var epoch: UInt64 = 0
    private var fillTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?
    private struct Submission {
        let origin: String
        let username: String
        let password: String
        let generation: UInt64
        let expires: Date
    }
    private var pending: Submission?

    init(bridge: any BrowserPasswordAssistBridge, vault: BrowserPasswordVault? = nil,
         enabled: @escaping () -> Bool = { BrowserGeneralSettings.load().passwordAssist },
         authenticator: BrowserVaultAuthenticator? = nil,
         requiresAuth: @escaping () -> Bool = { BrowserGeneralSettings.load().passwordFillRequiresAuth },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         ask: Ask? = nil) {
        self.bridge = bridge
        self.vault = vault ?? .shared
        self.enabled = enabled
        self.authenticator = authenticator ?? LocalAuthenticator()
        self.requiresAuth = requiresAuth
        self.uptime = uptime
        self.ask = ask ?? { title, detail, label in
            await IslandNotice.shared.ask(title: title, detail: detail,
                                          allowLabel: label, timeout: 20) == .allow
        }
        bridge.onLoginFormDetected = { [weak self] origin, form, username, password, prefilled in
            self?.detected(origin: origin, formID: form, usernameFieldID: username,
                           passwordFieldID: password, prefilledUsername: prefilled)
        }
        bridge.onCredentialSubmitted = { [weak self] origin, username, password in
            self?.submitted(origin: origin, username: username, password: password)
        }
        bridge.onPasswordAssistPageLoaded = { [weak self] origin, generation, successful, hasPasswordForm in
            self?.loaded(origin: origin, generation: generation, successful: successful,
                         hasPasswordForm: hasPasswordForm)
        }
        bridge.onPasswordAssistInvalidated = { [weak self] reload, preserveSubmission in
            self?.invalidate(reload: reload, preserveSubmission: preserveSubmission)
        }
        settingsObserver = NotificationCenter.default.publisher(for: BrowserGeneralSettings.passwordAssistChanged)
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.refreshSettings() }
                } else {
                    Task { @MainActor [weak self] in self?.refreshSettings() }
                }
            }
        refreshSettings()
    }

    func refreshSettings() {
        let value = enabled() && bridge?.passwordAssistIsHuman == true
        if !value { invalidate() }
        bridge?.passwordAssistEnabled = value
    }

    func invalidate(reload: Bool = false, preserveSubmission: Bool = false) {
        epoch &+= 1
        fillTask?.cancel()
        fillTask = nil
        saveTask?.cancel()
        saveTask = nil
        if reload { askedOrigins.removeAll() }
        // Navigation revokes the fill task, not this tab's five-minute identity check.
        // Closing releases the coordinator; takeover/disable explicitly clears the cache.
        if !enabled() || bridge?.passwordAssistIsHuman != true {
            authenticatedOrigins.removeAll()
        }
        if !preserveSubmission || !enabled() || bridge?.passwordAssistIsHuman != true {
            pending = nil
            expiryTask?.cancel()
            expiryTask = nil
        }
    }

    private func current(origin: String, generation: UInt64) -> Bool {
        guard !Task.isCancelled, enabled(), let bridge,
              bridge.passwordAssistEnabled, bridge.passwordAssistIsHuman,
              bridge.navigationGeneration == generation, generation > 0,
              BrowserPasswordOrigin.normalized(bridge.passwordAssistOrigin ?? "") == origin else { return false }
        return URLComponents(string: origin)?.scheme == "https"
    }

    private func metadata(_ origin: String) -> EmbeddedBrowserPasswordFormMetadata? {
        // Reuse the existing host-risk extractor; the bridge has already checked form.action.
        try? EmbeddedBrowserPasswordFormMetadataExtractor.metadata(fromJavaScriptResult: [[
            "hasPasswordField": true, "actionOrigin": origin, "documentOrigin": origin
        ]]).first
    }

    private func detected(origin raw: String, formID: String, usernameFieldID: String,
                          passwordFieldID: String, prefilledUsername: String) {
        guard let origin = BrowserPasswordOrigin.normalized(raw), let bridge,
              current(origin: origin, generation: bridge.navigationGeneration),
              !formID.isEmpty, !usernameFieldID.isEmpty, !passwordFieldID.isEmpty,
              !askedOrigins.contains(origin), let form = metadata(origin) else { return }
        let matches = vault.matches(origin: origin).filter {
            prefilledUsername.isEmpty || $0.username == prefilledUsername
        }
        guard case let .offerFill(accounts) = BrowserPasswordAutofillPlanner.decision(form: form, matches: matches),
              let account = accounts.first else { return }
        askedOrigins.insert(origin) // Denial/timeout also consumes this origin until explicit reload.
        let generation = bridge.navigationGeneration
        let ticket = epoch
        var detail = Self.detail(origin, account.username)
        if accounts.count > 1 { detail += "・其他 \(accounts.count - 1) 組在設定 › 密碼" }
        fillTask?.cancel()
        fillTask = Task { [weak self] in
            guard let self, await ask("要填入密碼嗎", detail, "填入"),
                  epoch == ticket, current(origin: origin, generation: generation),
                  vault.credentials.contains(account) else { return }
            do {
                if requiresAuth() {
                    let now = uptime()
                    authenticatedOrigins = authenticatedOrigins.filter { now >= $0.value && now - $0.value < 300 }
                    if authenticatedOrigins[origin] == nil {
                        let host = URLComponents(string: origin)?.host ?? ""
                        try await authenticator.authenticate(reason: "填入 \(host) 的密碼")
                        guard epoch == ticket, current(origin: origin, generation: generation),
                              vault.credentials.contains(account) else { return }
                        authenticatedOrigins[origin] = uptime()
                    }
                }
                guard epoch == ticket, current(origin: origin, generation: generation),
                      vault.credentials.contains(account) else { return }
                let password = try vault.passwordForApprovedFill(account.id)
                guard epoch == ticket, current(origin: origin, generation: generation) else { return }
                self.bridge?.fillCredentialUsername(account.username, password: password,
                                                    formID: formID, navigationGeneration: generation)
            } catch {
                // Arbitrary Keychain/provider errors are never logged or shown with secret data.
            }
        }
    }

    private func submitted(origin raw: String, username: String, password: String) {
        guard let origin = BrowserPasswordOrigin.normalized(raw), let bridge,
              current(origin: origin, generation: bridge.navigationGeneration),
              !password.isEmpty, password.utf8.count <= 16_384, username.utf8.count <= 4_096,
              let form = metadata(origin), !form.hasIDNHost, !form.hasConfusableHost,
              !form.hasMixedScriptHost else { return }
        pending = Submission(origin: origin, username: username, password: password,
                             generation: bridge.navigationGeneration, expires: Date().addingTimeInterval(90))
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            self?.pending = nil
        }
    }

    private func loaded(origin raw: String, generation: UInt64, successful: Bool, hasPasswordForm: Bool) {
        guard let submission = pending, generation > submission.generation else { return }
        pending = nil
        expiryTask?.cancel()
        expiryTask = nil
        guard let origin = BrowserPasswordOrigin.normalized(raw), origin == submission.origin,
              successful, !hasPasswordForm, submission.expires > Date(),
              current(origin: origin, generation: generation) else { return }
        let decision: BrowserPasswordSavePlanner.Decision
        do {
            decision = BrowserPasswordSavePlanner.decision(
                origin: origin, username: submission.username, password: submission.password,
                existing: try vault.existingForPasswordAssist(origin: origin, username: submission.username))
        } catch { return }
        let title: String
        let label: String
        switch decision {
        case .none: return
        case .askSave: title = "要儲存這組密碼嗎"; label = "儲存"
        case .askUpdate: title = "要更新密碼嗎"; label = "更新"
        }
        let ticket = epoch
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self, await ask(title, Self.detail(origin, submission.username), label),
                  epoch == ticket, current(origin: origin, generation: generation) else { return }
            do {
                // A settings edit while Island was open must not overwrite a newer credential.
                let latest = BrowserPasswordSavePlanner.decision(
                    origin: origin, username: submission.username, password: submission.password,
                    existing: try vault.existingForPasswordAssist(origin: origin, username: submission.username))
                guard latest == decision else { return }
                switch decision {
                case .askSave:
                    try vault.add(origin: origin, username: submission.username, password: submission.password,
                                  title: URLComponents(string: origin)?.host ?? "", source: .saved)
                case let .askUpdate(account):
                    guard vault.credentials.contains(account) else { return }
                    try vault.update(account.id, password: submission.password, username: nil, title: nil)
                case .none: break
                }
            } catch {
                // Fail closed; never serialize the pending submission or provider error.
            }
        }
    }

    private static func detail(_ origin: String, _ username: String) -> String {
        let host = URLComponents(string: origin)?.host ?? ""
        let clean = username.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) }
        return "\(host)・\(String(String.UnicodeScalarView(clean)).prefix(120))"
    }
}
