import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BrowserAIVaultSettingsView: View {
    @ObservedObject var vault: BrowserAIVault
    @State private var adding = false
    @State private var message: String?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI 帳號").font(.headline)
                Spacer()
                Button("新增") { adding = true }
                Button("從 CSV 匯入", action: importCSV)
                Button("匯出 CSV", action: exportCSV)
                    .disabled(vault.credentials.isEmpty || exportTask != nil)
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled(vault.storageError != nil)
            Text("AI 只能用這些帳號登入，看不到密碼；不會填進你的分頁")
                .font(.footnote).foregroundStyle(.secondary)
            Text("兩步驟驗證下一輪").font(.footnote).foregroundStyle(.secondary)
            if let error = vault.storageError { Text(error).foregroundStyle(.red) }
            if vault.credentials.isEmpty {
                Text("尚未配置 AI 專屬帳號。").font(.footnote).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 0) {
                ForEach(vault.credentials) { account in
                    BrowserAIVaultSettingsRow(vault: vault, account: account)
                    Divider().opacity(0.4)
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $adding) { BrowserAIVaultAddView(vault: vault) }
        .onDisappear { exportTask?.cancel(); exportTask = nil }
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
            message = "新增 \(result.added)；更新 \(result.updated)；略過 \(result.skipped)"
        } catch { message = "匯入失敗；先前成功的項目已保留。請檢查 CSV 與鑰匙圈。" }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TATWO-ai-accounts.csv"
        panel.message = "CSV 會包含未加密的密碼，請存放在安全的位置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportTask = Task { @MainActor in
            defer { exportTask = nil }
            do {
                let data = try await vault.exportCSV(reason: "匯出 AI 帳號密碼")
                try Task.checkCancellation()
                try BrowserPasswordCSVFileWriter.write(data, to: url)
            } catch is CancellationError {
            } catch { message = "無法匯出，請確認身分驗證與儲存位置。" }
        }
    }
}

@MainActor
private struct BrowserAIVaultAddView: View {
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
    @State private var revealed: String?
    @State private var task: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(string: account.origin)?.host ?? account.origin).font(.subheadline.weight(.medium))
                    Text("\(account.username) · \(account.label)").font(.footnote)
                    Text(account.allowedCallers.title).font(.caption).foregroundStyle(.secondary)
                    Text("最近使用：\(account.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未使用") · \(account.useCount) 次")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(revealed ?? "••••••••").font(.system(.footnote, design: .monospaced)).privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(revealed == nil ? "顯示密碼" : "隱藏", action: reveal)
                Button("刪除", role: .destructive, action: delete)
            }
            .buttonStyle(.bordered).font(.caption).disabled(task != nil)
            if failed { Text("操作未完成，請確認身分驗證或鑰匙圈。").font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 8)
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

    private func reveal() {
        if revealed != nil { cancel(); return }
        failed = false
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let value = try await vault.revealPassword(id: account.id, reason: "顯示 AI 帳號密碼")
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
}
