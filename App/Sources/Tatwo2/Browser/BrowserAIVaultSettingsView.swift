import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BrowserAIVaultSettingsView: View {
    @ObservedObject var vault: BrowserAIVault
    @State private var adding = false
    @State private var message: String?
    let changePassword: (UUID) -> Void
    @State private var importPreview: AIICloudImportPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(vault.credentials.count) 個帳號").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("匯入 iCloud", action: importICloud)
                Button("CSV 匯入", action: importCSV)
                Button("＋ 新增帳號") { adding = true }
            }
            .buttonStyle(.bordered).font(.caption)
            .disabled(vault.storageError != nil)
            if let error = vault.storageError { Text(error).foregroundStyle(.red) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    ForEach(["網站", "帳號", "標籤", "驗證器", "最近使用", "狀態", "⋯"], id: \.self) {
                        Text($0).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(vault.credentials) { account in
                    BrowserAIVaultSettingsRow(vault: vault, account: account, changePassword: changePassword)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if vault.credentials.isEmpty {
                Text("尚未配置 AI 專屬帳號。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $adding) { BrowserAIVaultAddView(vault: vault) }
        .sheet(item: $importPreview) { preview in AIICloudImportView(vault: vault, preview: preview) }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "欄位：origin,username,password,label。新增帳號允許所有引擎，更新沿用原範圍；請只選 AI 專屬帳號。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try vault.importCSV(url: url)
            message = "新增 \(result.added)；更新 \(result.updated)；略過 \(result.skipped)。請自行刪除含明文密碼的 CSV 原檔。"
        } catch { message = "匯入失敗；先前成功的項目已保留。請檢查 CSV 與鑰匙圈。" }
    }

    private func importICloud() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "選擇 Apple「密碼」App 匯出的 CSV；下一步逐一勾選給 AI 的帳號，預設全不勾。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importPreview = try AIICloudImportPreview.read(url) }
        catch { message = "無法讀取 CSV，請確認檔案格式。" }
    }

}

@MainActor
struct BrowserAIVaultAddView: View {
    @ObservedObject var vault: BrowserAIVault
    @Environment(\.dismiss) private var dismiss
    @State private var origin = ""
    @State private var username = ""
    @State private var password = ""
    @State private var label = ""
    @State private var scope = "any"
    @State private var scopeID = ""
    @State private var failed = false

    var body: some View {
        Form {
            Text("新增 AI 帳號").font(.headline)
            TextField("網站（https://…）", text: $origin)
            TextField("帳號", text: $username)
            SecureField("密碼", text: $password)
            TextField("標籤", text: $label)
            Picker("允許範圍", selection: $scope) {
                Text("所有引擎").tag("any")
                Text("指定 Bot").tag("bot")
                Text("指定對話").tag("thread")
            }
            if scope != "any" { TextField(scope == "bot" ? "Bot ID" : "對話 ID", text: $scopeID) }
            if failed { Text("儲存失敗，請確認網站、範圍 ID 與鑰匙圈。").foregroundStyle(.red) }
            HStack {
                Button("取消") { password = ""; dismiss() }
                Spacer()
                Button("儲存", action: save)
                    .disabled(password.isEmpty || origin.isEmpty || (scope != "any" && scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 430)
        .onDisappear { password = "" }
    }

    private func save() {
        let id = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let callerScope: CallerScope = scope == "bot" ? .bot(id: id) : scope == "thread" ? .thread(id: id) : .anyEngine
        do {
            try vault.add(origin: origin, username: username, password: password, label: label, allowedCallers: callerScope)
            password = ""
            dismiss()
        } catch { failed = true }
    }
}

@MainActor
private struct BrowserAIVaultSettingsRow: View {
    @ObservedObject var vault: BrowserAIVault
    let account: AICredential
    let changePassword: (UUID) -> Void
    @State private var editing: AIAccountEditKind?
    @State private var revealed: String?
    @State private var task: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var failed = false

    var body: some View {
        GridRow(alignment: .top) {
            Text(URL(string: account.origin)?.host ?? account.origin).lineLimit(1).help(account.origin)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.username).lineLimit(1).help(account.username).privacySensitive()
                if let revealed {
                    Text(revealed).font(.system(.caption, design: .monospaced)).privacySensitive()
                }
                if failed { Text("操作未完成").foregroundStyle(.red) }
            }
            Text(account.label).lineLimit(1).help(account.allowedCallers.title)
            Text(account.authenticatorStatus.rawValue)
                .foregroundStyle(account.authenticatorStatus == .managed ? .green : .secondary)
            Text(account.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .foregroundStyle(.secondary)
            Text(account.statusTitle).foregroundStyle(account.statusTitle == "正常" ? .green : .orange)
            Menu {
                Button("快速修改密碼") { changePassword(account.id) }.disabled(account.disabledAt != nil)
                Button(revealed == nil ? "顯示密碼（Touch ID）" : "隱藏密碼", action: reveal)
                if account.passwordChangeFailedAt != nil {
                    Button("顯示待確認新密碼（Touch ID）") { reveal(pending: true) }
                    Button("網站已採用新密碼，同步保險庫…") { reconcile(useNew: true) }
                    Button("網站仍使用舊密碼，放棄候選…") { reconcile(useNew: false) }
                }
                Button("綁定驗證器") { editing = .authenticator }
                Button("改標籤") { editing = .label }
                Button("只允許某條對話") { editing = .scope }
                Button(account.disabledAt == nil ? "停用" : "啟用") {
                    do { try vault.setEnabled(account.id, enabled: account.disabledAt != nil) }
                    catch { failed = true }
                }
                Button("刪除", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis").accessibilityLabel("帳號操作") }
            .menuStyle(.borderlessButton).fixedSize().disabled(task != nil || vault.storageError != nil)
        }
        .font(.system(size: 12))
        .sheet(item: $editing) { kind in AIAccountEditView(vault: vault, account: account, kind: kind) }
        .onDisappear(perform: cancel)
        .onChange(of: account) { _, _ in cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            revealed = nil
        }
    }

    private func cancel() {
        task?.cancel(); task = nil
        hideTask?.cancel(); hideTask = nil
        revealed = nil
    }

    private func reveal() { reveal(pending: false) }

    private func reveal(pending: Bool) {
        if revealed != nil { cancel(); return }
        failed = false
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let value = try await pending ? vault.revealPendingPasswordChange(account.id) :
                    vault.revealPassword(id: account.id, reason: "顯示 AI 帳號密碼")
                try Task.checkCancellation()
                guard NSApplication.shared.isActive else { return }
                revealed = value
                hideTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    revealed = nil
                }
            } catch is CancellationError {
            } catch { failed = true }
        }
    }

    private func delete() {
        revealed = nil
        failed = false
        task = Task { @MainActor in
            defer { task = nil }
            let confirmed = await IslandNotice.shared.confirm(title: "刪除 AI 帳號？",
                detail: "\(account.label)・\(account.username)；刪除後 AI 將無法再使用此帳號。此動作無法復原。",
                confirmLabel: "刪除", cancelLabel: "取消")
            guard confirmed, !Task.isCancelled else { return }
            do { try vault.delete(account.id) } catch { failed = true }
        }
    }

    private func reconcile(useNew: Bool) {
        task = Task { @MainActor in
            defer { task = nil }
            guard await IslandNotice.shared.confirm(title: useNew ? "同步新密碼？" : "放棄待確認的新密碼？",
                detail: useNew ? "請先確認網站已接受新密碼；這會替換本機舊密碼，並需要 Touch ID。" :
                    "請先確認網站仍接受舊密碼。這只移除本機候選，不能復原網站上的密碼變更。",
                confirmLabel: "確認", cancelLabel: "取消"), !Task.isCancelled else { return }
            do { try await vault.reconcilePendingPasswordChange(account.id, useNewPassword: useNew) }
            catch { failed = true }
        }
    }
}
