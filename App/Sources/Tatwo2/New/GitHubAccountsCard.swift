// 2.0 新畫面（不是照搬）：設定頁「GitHub」— OS 管多個 GitHub 帳號，CLI 與各家引擎都透過 OS 拿憑證（使用者 2026-09-05）。
// 新畫面一律放 New/；Facade 禁自畫 View。
import SwiftUI
import AppKit

struct GitHubAccountsCard: View {
    @ObservedObject var model: ChatPageModel
    @State private var pendingRemoval: String?
    @State private var tokenField = ""
    @State private var loginInput = ""
    @State private var mappingPath: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub")
                    .font(.title3.bold())
                Text("登入 GitHub 後，AI 和終端機會依網址或資料夾選對帳號，幫你下載或上傳程式碼，不用手動切換。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("回報倉庫").font(.headline)
                Text(FeedbackSettings.defaultRepository)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("回報倉庫")
                Text("問題回報與更新檢查都走這個公開倉庫。").font(.footnote).foregroundStyle(.secondary)
            }
            // 接管 git
            HStack(spacing: 10) {
                Circle()
                    .fill(model.gitHubHelperInstalled ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(model.gitHubHelperInstalled ? "OS 已接管 git 的憑證" : "OS 還沒接管 git 的憑證（現在 git 用的是原本的設定）")
                    .font(.footnote)
                Spacer()
                if model.gitHubHelperInstalled {
                    Button("還原原本設定") { model.restoreGitHubHelper() }
                        .buttonStyle(.bordered)
                } else {
                    Button("讓 OS 接管 git 憑證") { model.installGitHubHelper() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.gitHubAccounts.isEmpty)
                }
            }

            Divider()

            // 帳號清單
            VStack(alignment: .leading, spacing: 8) {
                Text("帳號（\(model.gitHubAccounts.count)）")
                    .font(.headline)
                if model.gitHubAccounts.isEmpty {
                    Text("還沒有帳號。用下面三種方式加一個。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.gitHubAccounts) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(account.username)
                                .font(.subheadline.weight(.medium))
                            if account.isDefault {
                                Text("預設")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(LiquidGlassTokens.brandAccent.opacity(0.15), in: Capsule())
                            }
                            Text(Self.permissions(account.scopes))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Menu {
                                Button("檢查連線") { model.verifyGitHubAccount(account.username) }
                                Button(account.mcpAlwaysOn ? "常駐 MCP（開）" : "常駐 MCP（關）") {
                                    model.toggleGitHubMCPAlwaysOn(account.username)
                                }
                                .help("讓 AI 在每條對話都能直接用這個帳號查 GitHub")
                                if !account.isDefault {
                                    Button("設為預設") { model.setDefaultGitHubAccount(account.username) }
                                }
                                Divider()
                                Button("移除帳號…", role: .destructive) { pendingRemoval = account.username }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(width: 28, height: 28)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("\(account.username) 的帳號選項")
                        }
                        Text(account.mcpAlwaysOn ? "常駐 MCP 已開：AI 在每條對話都能直接用這個帳號查 GitHub" : "常駐 MCP 未開：開啟後 AI 在每條對話都能直接用這個帳號查 GitHub")
                            .font(.footnote).foregroundStyle(.secondary)
                        // 資料夾對映
                        VStack(alignment: .leading, spacing: 6) {
                            Text("哪些資料夾用這個帳號").font(.footnote.weight(.medium))
                            ForEach(account.folderMappings, id: \.self) { path in
                                HStack {
                                    Text(path).font(.footnote.monospaced()).lineLimit(1)
                                        .truncationMode(.middle).help(path).textSelection(.enabled)
                                    Spacer()
                                    Button("移除") { model.removeGitHubFolderMapping(account: account.username, path: path) }
                                        .buttonStyle(.borderless).controlSize(.small)
                                        .accessibilityLabel("移除資料夾 \(path)")
                                }
                            }
                            HStack {
                                TextField("拖入或輸入資料夾路徑，例如 ~/Projects/example",
                                          text: Binding(get: { mappingPath[account.username] ?? "" },
                                                        set: { mappingPath[account.username] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.footnote)
                                    .dropDestination(for: URL.self) { urls, _ in
                                        guard urls.count == 1, let url = urls.first, url.isFileURL,
                                              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                                        else { return false }
                                        mappingPath[account.username] = url.path
                                        return true
                                    }
                                Button("加入") {
                                    let p = (mappingPath[account.username] ?? "").trimmingCharacters(in: .whitespaces)
                                    guard !p.isEmpty else { return }
                                    model.addGitHubFolderMapping(account: account.username, path: p)
                                    mappingPath[account.username] = ""
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled((mappingPath[account.username] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.4)
                }
            }

            // 加帳號
            VStack(alignment: .leading, spacing: 8) {
                Text("加帳號")
                    .font(.headline)
                HStack(spacing: 8) {
                    Button("從這台的 gh 匯入") { model.importGitHubAccountsFromGH() }
                        .buttonStyle(.bordered)
                    Button("用瀏覽器登入新帳號") {
                        loginInput = ""
                        model.loginGitHubViaGH()
                    }
                        .buttonStyle(.bordered)
                        .disabled(model.githubLoginInProgress)
                }
                Text("沒有 gh 的機器用第三種：到 GitHub › Settings › Developer settings 建一個 token（勾 repo），貼在這裡。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField("貼 token", text: $tokenField)
                        .textFieldStyle(.roundedBorder)
                    Button("驗證並加入") {
                        model.addGitHubToken(tokenField.trimmingCharacters(in: .whitespaces))
                        tokenField = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tokenField.count < 10)
                }
                if model.githubLoginInProgress {
                    loginProgress
                }
                if !model.gitHubLoginLog.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.gitHubLoginLog.suffix(6).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("OS 怎麼選帳號：網址裡有帳號名就用那個；沒有就看資料夾對映；都沒有就用預設帳號。")
                Text("這些都可以在 chat 直接請 AI 幫你設定。")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.refreshGitHubAccounts() }
        .alert("移除帳號 \(pendingRemoval ?? "")？", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除", role: .destructive) {
                guard let username = pendingRemoval else { return }
                model.removeGitHubAccount(username)
                pendingRemoval = nil
            }
        } message: {
            Text("會移除 OS 儲存的登入資料與資料夾設定，不會刪除 GitHub 上的帳號或倉庫。")
        }
    }

    // 沿用 EngineLoginCard.loginProgress；W3 的代碼、網址與 stdin 控制。
    private var loginProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("登入中…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let code = model.githubDeviceCode {
                HStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                    Button("複製") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let url = model.githubVerificationURL {
                Link(url.absoluteString, destination: url)
                    .font(.footnote)
            }
            HStack(spacing: 8) {
                TextField("輸入驗證碼（留白送出 Enter）", text: $loginInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitLoginInput() }
                Button("送出") { submitLoginInput() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func submitLoginInput() {
        model.submitGitHubLoginInput(loginInput)
        loginInput = ""
    }

    private static func permissions(_ scopes: [String]) -> String {
        guard !scopes.isEmpty else { return "權限尚未確認" }
        let labels = ["repo": "讀寫 repo", "read:org": "讀組織", "gist": "gist", "workflow": "workflow"]
        return "可" + scopes.map { labels[$0] ?? $0 }.joined(separator: "、")
    }
}
