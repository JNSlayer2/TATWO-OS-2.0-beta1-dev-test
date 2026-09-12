import AppKit
import SwiftUI

private func runOnMainBounded(
    timeout: TimeInterval = 10,
    _ body: @MainActor @escaping @Sendable () -> Bool
) -> Bool {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result = false
    DispatchQueue.main.async {
        result = MainActor.assumeIsolated(body)
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        return false
    }
    return result
}

@MainActor
enum ChatNativeSubscriptionBrowserLauncher {
    static func open(_ url: URL) -> Bool {
        // Staging 啟動器以 env -i 淨化環境（HOME＝隔離目錄）；由本 app 冷啟
        // 瀏覽器會讓它繼承錯誤 HOME 而找不到使用者鑰匙圈（Arc 實測彈
        // 「找不到鑰匙圈來儲存 Arc」）。優先走 /usr/bin/open 並還原真實
        // 使用者 HOME，讓 LaunchServices 以使用者 session 環境啟動瀏覽器；
        // 失敗才退回 NSWorkspace 與 Safari。
        if openViaUserSession(url) {
            return true
        }
        return open(
            url,
            defaultOpen: {
                NSWorkspace.shared.open($0)
            },
            safariApplicationURL: {
                NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.Safari")
            },
            openWithApplication: { applicationURL, targetURL in
                NSWorkspace.shared.open(
                    [targetURL],
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil)
                return true
            })
    }

    static func open(
        _ url: URL,
        defaultOpen: (URL) -> Bool,
        safariApplicationURL: () -> URL?,
        openWithApplication: (URL, URL) -> Bool
    ) -> Bool {
        if defaultOpen(url) {
            return true
        }
        guard let safariURL = safariApplicationURL() else {
            return false
        }
        return openWithApplication(safariURL, url)
    }

    /// 以使用者 session 環境開 URL：HOME 用目錄服務的真實家目錄
    /// （不信任本進程可能被淨化過的 HOME env）。
    private static func openViaUserSession(_ url: URL) -> Bool {
        guard let realHome = NSHomeDirectoryForUser(NSUserName()) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = realHome
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@MainActor
final class ChatNativeOpenAISubscriptionOnboardingModel:
    ObservableObject
{
    @Published private(set) var status:
        ChatNativeSubscriptionAccountStatus = .signedOut
    @Published private(set) var isWorking = false
    @Published private(set) var notice: String?

    private let accountService: ChatNativeSubscriptionAccountService
    private let openURL: @Sendable (URL) -> Bool

    init(
        accountService: ChatNativeSubscriptionAccountService =
            ChatNativeSubscriptionAccountService(),
        openURL: @escaping @Sendable (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.accountService = accountService
        self.openURL = openURL
    }

    var statusLabel: String {
        switch status {
        case .unavailable:
            "執行環境不可用"
        case .signedOut:
            "尚未登入"
        case .requiresReauthentication:
            "需重新登入"
        case .signedIn(let planType):
            "已登入 · \(Self.planLabel(planType))"
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = status {
            return true
        }
        return false
    }

    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        status = await accountService.status()
        if status == .unavailable {
            notice = "TATWO 內建模型執行環境不可用，請重新安裝或更新 App。"
        } else {
            notice = nil
        }
        isWorking = false
    }

    func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        notice = "請在瀏覽器完成 ChatGPT 訂閱帳號登入。"
        let browserOpener = openURL
        status = await accountService.login { url in
            if Thread.isMainThread {
                return browserOpener(url)
            }
            return runOnMainBounded {
                browserOpener(url)
            }
        }
        switch status {
        case .signedIn:
            notice = "登入完成；Sol 已可由 TATWO OS 直接使用。"
        case .signedOut:
            notice = "尚未完成登入。"
        case .requiresReauthentication:
            notice = "登入狀態已到期，請重新登入 ChatGPT。"
        case .unavailable:
            notice = "登入未完成，請確認網路後重試。"
        }
        isWorking = false
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        status = await accountService.logout()
        switch status {
        case .signedOut:
            notice = "已登出 ChatGPT 訂閱帳號。"
        case .requiresReauthentication:
            notice = "本機仍有已到期的登入資料；請重新登入或再試一次登出。"
        case .signedIn, .unavailable:
            notice = "無法確認登出狀態。"
        }
        isWorking = false
    }

    private static func planLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "pro":
            "ChatGPT Pro"
        case "plus":
            "ChatGPT Plus"
        case "team", "business":
            "ChatGPT Business"
        case "enterprise", "enterprise_cbp_automation",
            "enterprise_cbp_usage_based":
            "ChatGPT Enterprise"
        case "edu":
            "ChatGPT Edu"
        case "free":
            "ChatGPT Free"
        default:
            "ChatGPT"
        }
    }
}

struct ChatNativeOpenAISubscriptionOnboardingView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @StateObject private var model =
        ChatNativeOpenAISubscriptionOnboardingModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ChatGPT 訂閱登入")
                        .font(.system(size: 14, weight: .semibold))
                    Text("TATWO 內建 OpenAI 執行環境 · Sol")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        statusColor.opacity(0.12),
                        in: Capsule())
            }

            Text("使用 ChatGPT 訂閱帳號登入，不需要 API Key，也不需要另外安裝 Codex App。登入資料由 TATWO 的獨立 OpenAI 執行環境管理。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if model.isSignedIn {
                    Button("登出", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)
                } else {
                    Button("登入 ChatGPT") {
                        Task { await model.signIn() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassTokens.brandAccent)
                    .disabled(model.isWorking)
                }

                Button("重新整理") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(notice)
            }
        }
        .padding(16)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous))
        .task {
            await model.refresh()
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .signedIn:
            .green
        case .signedOut, .requiresReauthentication:
            .secondary
        case .unavailable:
            .red
        }
    }
}

@MainActor
final class ChatNativeClaudeSubscriptionOnboardingModel:
    ObservableObject
{
    @Published private(set) var status:
        ChatNativeClaudeSubscriptionAccountStatus = .signedOut
    @Published private(set) var isWorking = false
    @Published private(set) var notice: String?

    private let accountService:
        ChatNativeClaudeSubscriptionAccountService

    init(
        accountService: ChatNativeClaudeSubscriptionAccountService =
            ChatNativeClaudeSubscriptionAccountService()
    ) {
        self.accountService = accountService
    }

    var statusLabel: String {
        switch status {
        case .unavailable:
            "執行環境不可用"
        case .signedOut:
            "尚未登入"
        case .signedIn(let subscriptionType):
            "已登入 · \(subscriptionType.uppercased())"
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        status = await accountService.status()
        notice = status == .unavailable
            ? "TATWO 內建 Claude 執行環境不可用，請重新安裝或更新 App。"
            : nil
        isWorking = false
    }

    func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        notice = "請在瀏覽器完成 Claude 訂閱帳號登入。"
        status = await accountService.login()
        switch status {
        case .signedIn:
            notice = "登入完成；Opus 5 已可由 TATWO OS 直接使用。"
        case .signedOut:
            notice = "尚未完成登入。"
        case .unavailable:
            notice = "登入未完成，請確認網路後重試。"
        }
        isWorking = false
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        status = await accountService.logout()
        notice = status == .signedOut
            ? "已登出 Claude 訂閱帳號。"
            : "無法確認登出狀態。"
        isWorking = false
    }
}

struct ChatNativeClaudeSubscriptionOnboardingView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @StateObject private var model =
        ChatNativeClaudeSubscriptionOnboardingModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude 訂閱登入")
                        .font(.system(size: 14, weight: .semibold))
                    Text("TATWO 內建 Anthropic 執行環境 · Opus 5")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        statusColor.opacity(0.12),
                        in: Capsule())
            }

            Text("使用 Claude 訂閱帳號登入，不需要 API Key，也不需要另外安裝 Claude App。TATWO 只執行官方訂閱流程：claude auth login --claudeai。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if model.isSignedIn {
                    Button("登出", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)
                } else {
                    Button("登入 Claude") {
                        Task { await model.signIn() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassTokens.brandAccent)
                    .disabled(model.isWorking)
                }

                Button("重新整理") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(notice)
            }
        }
        .padding(16)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous))
        .task {
            await model.refresh()
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .signedIn:
            .green
        case .signedOut:
            .secondary
        case .unavailable:
            .red
        }
    }
}

@MainActor
final class ChatNativeGrokSubscriptionOnboardingModel:
    ObservableObject
{
    @Published private(set) var status:
        ChatNativeGrokSubscriptionAccountStatus = .signedOut
    @Published private(set) var isWorking = false
    @Published private(set) var awaitingVerificationCode = false
    @Published private(set) var notice: String?

    private let accountService:
        ChatNativeGrokSubscriptionAccountService
    private let openURL: @Sendable (URL) -> Bool
    private var signInSession:
        (any ChatNativeGrokInteractiveProcessSession)?
    private var signInCancellationRequested = false

    init(
        accountService: ChatNativeGrokSubscriptionAccountService =
            ChatNativeGrokSubscriptionAccountService(),
        openURL: @escaping @Sendable (URL) -> Bool = { url in
            MainActor.assumeIsolated {
                ChatNativeSubscriptionBrowserLauncher.open(url)
            }
        }
    ) {
        self.accountService = accountService
        self.openURL = openURL
    }

    var statusLabel: String {
        switch status {
        case .unavailable:
            "執行環境不可用"
        case .signedOut:
            "尚未登入"
        case .signedIn:
            "已登入 · Grok"
        }
    }

    var isSignedIn: Bool {
        status == .signedIn
    }

    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        status = await accountService.status()
        notice = status == .unavailable
            ? "TATWO 內建 Grok 執行環境不可用，請重新安裝或更新 App。"
            : nil
        isWorking = false
    }

    func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        awaitingVerificationCode = false
        signInCancellationRequested = false
        signInSession = nil
        notice = "請在瀏覽器完成 Grok 訂閱帳號登入。"
        let browserOpener = openURL
        let outcome = await accountService.login(
            openURL: { url in
                if Thread.isMainThread {
                    return browserOpener(url)
                }
                return runOnMainBounded {
                    browserOpener(url)
                }
            },
            onSessionStarted: { [weak self] session in
                Task { @MainActor in
                    guard let self else { return }
                    if self.signInCancellationRequested {
                        session.terminate()
                    } else {
                        self.signInSession = session
                    }
                }
            },
            onAwaitingVerificationCode: { [weak self] in
                Task { @MainActor in
                    guard let self,
                          !self.signInCancellationRequested
                    else {
                        return
                    }
                    self.awaitingVerificationCode = true
                    self.notice =
                        "請輸入瀏覽器顯示的 Grok 官方驗證碼。"
                }
            })
        signInSession = nil
        awaitingVerificationCode = false
        if signInCancellationRequested {
            isWorking = false
            return
        }
        switch outcome {
        case .completed(let accountStatus):
            status = accountStatus
        case .timedOut:
            status = .signedOut
            notice = "Grok 登入已逾時（180 秒），請重新登入。"
            isWorking = false
            return
        }
        switch status {
        case .signedIn:
            notice = "登入完成；Grok 4.6 已可由 TATWO OS 直接使用。"
        case .signedOut:
            notice = "尚未完成登入。"
        case .unavailable:
            notice = "登入未完成，請確認網路後重試。"
        }
        isWorking = false
    }

    func submitVerificationCode(_ code: String) async {
        guard isWorking,
              awaitingVerificationCode,
              let signInSession
        else {
            return
        }
        let verificationCode = code.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !verificationCode.isEmpty else {
            notice = "請輸入瀏覽器顯示的驗證碼。"
            return
        }
        do {
            try await signInSession.send(line: verificationCode)
            awaitingVerificationCode = false
            notice = "驗證碼已送出，正在確認 Grok 登入狀態。"
        } catch {
            awaitingVerificationCode = false
            notice = "驗證碼送出失敗，請取消後重新登入。"
        }
    }

    func cancelSignIn() {
        guard isWorking else { return }
        signInCancellationRequested = true
        signInSession?.terminate()
        signInSession = nil
        awaitingVerificationCode = false
        isWorking = false
        notice = "已取消 Grok 登入。"
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        status = await accountService.logout()
        notice = status == .signedOut
            ? "已登出 Grok 訂閱帳號。"
            : "無法確認登出狀態。"
        isWorking = false
    }
}

struct ChatNativeGrokSubscriptionOnboardingView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @StateObject private var model =
        ChatNativeGrokSubscriptionOnboardingModel()
    @State private var verificationCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Grok 訂閱登入")
                        .font(.system(size: 14, weight: .semibold))
                    Text("TATWO 內建 xAI 執行環境 · Grok 4.6")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        statusColor.opacity(0.12),
                        in: Capsule())
            }

            Text("使用 Grok 訂閱帳號登入，不需要 API Key，也不需要另外安裝 Grok App。TATWO 只執行內建 Grok OAuth 訂閱流程。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if model.isSignedIn {
                    Button("登出", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)
                } else {
                    Button("登入 Grok") {
                        Task { await model.signIn() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassTokens.brandAccent)
                    .disabled(model.isWorking)
                }

                Button("重新整理") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)

                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            // Grok OAuth 是「瀏覽器顯示官方驗證碼 → 貼回」流程；驗證碼在
            // 這裡輸入，由 runtime 寫回 grok CLI 的 stdin。
            if model.awaitingVerificationCode {
                HStack(spacing: 8) {
                    TextField("貼上瀏覽器顯示的驗證碼", text: $verificationCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 260)
                        .onSubmit { submitVerificationCode() }
                    Button("送出驗證碼") { submitVerificationCode() }
                        .buttonStyle(.borderedProminent)
                        .tint(LiquidGlassTokens.brandAccent)
                        .disabled(
                            verificationCode
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty)
                    Button("取消") { model.cancelSignIn() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(notice)
            }
        }
        .padding(16)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous))
        .task {
            await model.refresh()
        }
    }

    private func submitVerificationCode() {
        let code = verificationCode
        verificationCode = ""
        Task { await model.submitVerificationCode(code) }
    }

    private var statusColor: Color {
        switch model.status {
        case .signedIn:
            .green
        case .signedOut:
            .secondary
        case .unavailable:
            .red
        }
    }
}
