// 2.0 新畫面（不是照搬）：設定頁「GitHub」— OS 管多個 GitHub 帳號，CLI 與各家引擎都透過 OS 拿憑證（使用者 2026-09-05）。
// 新畫面一律放 New/；Facade 禁自畫 View。
import SwiftUI
import AppKit

struct GitHubAccountsCard: View {
    @ObservedObject var model: ChatPageModel
    @AppStorage(FeedbackSettings.repositoryKey) private var feedbackRepository = FeedbackSettings.defaultRepository
    @State private var tokenField = ""
    @State private var loginInput = ""
    @State private var mappingPath: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub")
                    .font(.title3.bold())
                Text("把你的 GitHub 帳號登進 OS。之後 git、各家引擎、終端機要推拉程式碼時，OS 依「網址上的帳號名」或「資料夾對映」自動給對的帳號，不用再切來切去。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("回報倉庫").font(.headline)
                TextField("owner/repo", text: $feedbackRepository)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("回報倉庫")
                Text("格式 owner/repo").font(.footnote).foregroundStyle(.secondary)
                if !FeedbackSettings.isValidRepository(feedbackRepository.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Text("格式無效，目前使用預設倉庫：\(FeedbackSettings.defaultRepository)")
                        .font(.footnote).foregroundStyle(.red)
                }
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
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                            Text(account.scopes.isEmpty ? "加入 \(Self.stamp(account.addedAt))" : "權限 \(account.scopes.joined(separator: "、"))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle(isOn: Binding(get: { account.mcpAlwaysOn },
                                                 set: { _ in model.toggleGitHubMCPAlwaysOn(account.username) })) {
                                Text("常駐 MCP")
                                    .font(.footnote.weight(.semibold))
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("開：所有對話預設都能用這個帳號的 GitHub 工具（看 issue、開 PR、搜程式碼…）。關：資訊卡的 MCP 清單還是有它，要用時手動勾。")
                            if !account.isDefault {
                                Button("設為預設") { model.setDefaultGitHubAccount(account.username) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            Button("檢查") { model.verifyGitHubAccount(account.username) }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button("移除") { model.removeGitHubAccount(account.username) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        // 資料夾對映
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(account.folderMappings, id: \.self) { path in
                                HStack {
                                    Text(path).font(.footnote.monospaced()).lineLimit(1)
                                    Spacer()
                                    Button("拿掉") { model.removeGitHubFolderMapping(account: account.username, path: path) }
                                        .buttonStyle(.borderless).controlSize(.small)
                                }
                            }
                            HStack {
                                TextField("這個路徑底下的 repo 都用這個帳號（例：~/Projects/example）",
                                          text: Binding(get: { mappingPath[account.username] ?? "" },
                                                        set: { mappingPath[account.username] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.footnote)
                                Button("加入對映") {
                                    let p = (mappingPath[account.username] ?? "").trimmingCharacters(in: .whitespaces)
                                    guard !p.isEmpty else { return }
                                    model.addGitHubFolderMapping(account: account.username, path: p)
                                    mappingPath[account.username] = ""
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.leading, 4)
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

            Text("規則：網址帶帳號名（tatwo214@github.com/…）就用那個；沒帶就看 repo 在哪個資料夾對映；都沒有用預設帳號。不是 github.com 的網址 OS 不插手。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.refreshGitHubAccounts() }
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

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f.string(from: date)
    }
}
