import SwiftUI

/// W59, approved mockup v3: one selected surface, not stacked account/wallet sections.
@MainActor
struct AgentAccountsSettingsView: View {
    enum Surface: String, CaseIterable, Identifiable {
        case accounts = "帳號", wallets = "錢包"
        var id: Self { self }
    }
    @ObservedObject var vault: BrowserAIVault
    @ObservedObject var detector: BreachDetector
    @State private var surface: Surface = .accounts
    let changePassword: (UUID) -> Void
    let activity: () -> Void

    init(vault: BrowserAIVault? = nil, detector: BreachDetector? = nil,
         initialSurface: Surface = .accounts,
         changePassword: @escaping (UUID) -> Void, activity: @escaping () -> Void) {
        self.vault = vault ?? .shared
        self.detector = detector ?? .shared
        _surface = State(initialValue: initialSurface)
        self.changePassword = changePassword
        self.activity = activity
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("代理帳戶＆錢包").font(.title3.bold())
                        Text("給 AI 用的帳號由 OS 保管：AI 只能請 OS 登入，拿不到密碼；不會填進你自己的分頁。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Picker("帳號與錢包", selection: $surface) {
                        ForEach(Surface.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .clipShape(Capsule())
                    .frame(width: 156, alignment: .trailing)
                }
                if surface == .accounts {
                    BrowserAIVaultSettingsView(vault: vault, changePassword: changePassword)
                } else {
                    AgentWalletPlaceholder()
                }
                AgentAccountsSafetyPanel(vault: vault, detector: detector, activity: activity)
            }
            .padding(22)
        }
    }
}

private struct AgentWalletPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("0 個錢包").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("＋ 建立錢包") {}.disabled(true)
            }
            HStack {
                ForEach(["錢包", "鏈", "地址", "餘額", "今日已用／額度", "狀態", "⋯"], id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            Text("錢包第二期：EVM 熱錢包、額度、允許清單、硬體金庫")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 140)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct AgentAccountsSafetyPanel: View {
    @ObservedObject var vault: BrowserAIVault
    @ObservedObject var detector: BreachDetector
    let activity: () -> Void
    @State private var stopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("授權與外洩處理").font(.headline)
                Spacer()
                Button(detector.isScanning ? "掃描中…" : "立即掃描") { detector.scanNow() }
                    .disabled(detector.isScanning)
                Button("活動紀錄", action: activity)
            }
            .buttonStyle(.bordered).font(.caption)
            LabeledContent("登入", value: "跟對話權限：完整存取權＝自動；代我核准＝自動但通知；要求核准＝每次問")
            LabeledContent("簽名／付款", value: "第二期：額度內自動，超過門檻 Touch ID")
            LabeledContent("外洩偵測", value: "每週 Have I Been Pwned 匿名查詢（只送雜湊前 5 碼）＋本機規則：重複使用、AI 與你的帳號共用密碼")
            // 對照稿第 3 版：「偵測到外洩時」是一列，右側是自動換開關。
            LabeledContent("偵測到外洩時") {
                HStack(spacing: 10) {
                    Text("你的帳號：Island 提醒＋一鍵協助換　·　AI 專屬帳號：自動換新並同步")
                    Spacer(minLength: 0)
                    Toggle("AI 專屬帳號自動換並同步", isOn: $detector.automaticallyAssistAI)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            Text("開啟後自動協助到最後確認；仍須你確認及 Touch ID（不支援時使用系統登入密碼）。成功後更新本機保險庫，不做跨裝置密碼同步。")
                .font(.caption).foregroundStyle(.secondary)
            if let summary = detector.summary { Text(summary).foregroundStyle(.secondary) }
            if !detector.localWarnings.isEmpty {
                Text(detector.localWarnings).foregroundStyle(.orange)
            }
            ForEach(detector.affectedHumanAccounts) { account in
                HStack {
                    Text("\(URL(string: account.origin)?.host ?? "") · \(account.username)")
                        .privacySensitive()
                    Text("密碼曾外洩").foregroundStyle(.red)
                    Spacer()
                    Button("協助換密碼") { detector.assistHuman(account.id) }
                }
            }
            Divider()
            HStack {
                Text("緊急停用").fontWeight(.medium)
                Text("停用所有 AI 帳號，撤銷未完成的登入與換密碼。").foregroundStyle(.secondary)
                Spacer()
                Button("停用", role: .destructive, action: disableAll).disabled(stopping)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func disableAll() {
        stopping = true
        Task { @MainActor in
            defer { stopping = false }
            guard await IslandNotice.shared.confirm(title: "停用所有 AI 帳號？",
                detail: "立即阻止新的登入與未送出的換密碼；不會登出網站上既有的工作階段。",
                confirmLabel: "停用", cancelLabel: "取消") else { return }
            do { try vault.disableAll() }
            catch { detector.reportStorageFailure() }
        }
    }
}
