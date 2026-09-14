import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// W50 settings surface only; W49 owns the import flow and W47 owns page filling.
@MainActor
struct BrowserPasswordsSettingsView: View {
    @ObservedObject var vault: BrowserPasswordVault
    @State private var search = ""
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var passwordAssist = BrowserGeneralSettings.load().passwordAssist
    @State private var passwordFillRequiresAuth = BrowserGeneralSettings.load().passwordFillRequiresAuth
    private let aiVault: BrowserAIVault

    init(vault: BrowserPasswordVault? = nil, aiVault: BrowserAIVault? = nil) {
        self.vault = vault ?? .shared
        self.aiVault = aiVault ?? .shared
    }

    private var filteredCredentials: [BrowserCredential] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return vault.credentials.filter {
            query.isEmpty || [$0.origin, $0.username, $0.title].contains {
                $0.localizedStandardContains(query)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("密碼").font(.headline)
                Spacer(minLength: 8)
                Button("匯出 CSV") { exportCSV() }
                    .disabled(exporting || vault.credentials.isEmpty || vault.storageError != nil)
                Button("從其他瀏覽器導入…") {
                    NotificationCenter.default.post(
                        name: Notification.Name("tatwo.browser.openImport"), object: nil)
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)

            Toggle("自動填入與儲存提示", isOn: $passwordAssist)
                .onChange(of: passwordAssist) { _, enabled in
                    do { try BrowserGeneralSettings.savePasswordAssist(enabled) }
                    catch {
                        passwordAssist = BrowserGeneralSettings.load().passwordAssist
                        errorMessage = "無法儲存密碼提示設定，請稍後再試。"
                    }
                }
            Toggle("填入密碼前要 Touch ID", isOn: $passwordFillRequiresAuth)
                .onChange(of: passwordFillRequiresAuth) { _, enabled in
                    do { try BrowserGeneralSettings.savePasswordFillRequiresAuth(enabled) }
                    catch {
                        passwordFillRequiresAuth = BrowserGeneralSettings.load().passwordFillRequiresAuth
                        errorMessage = "無法儲存身分驗證設定。"
                    }
                }
            Text("同一分頁、同一網站驗證後 5 分鐘內免重驗；不支援 Touch ID 時使用系統登入密碼。")
                .font(.footnote).foregroundStyle(.secondary)

            TextField("搜尋網站或使用者名稱", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜尋密碼")

            if let error = vault.storageError {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else if filteredCredentials.isEmpty {
                Text(search.isEmpty ? "尚未儲存密碼。" : "找不到符合的密碼。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredCredentials) { credential in
                        BrowserPasswordSettingsRow(vault: vault, credential: credential)
                        Divider().opacity(0.4)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
            Divider()
            // AI 帳號 use a separate index and Keychain service, never the human list.
            BrowserAIVaultSettingsView(vault: aiVault)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            exporting = false
        }
    }

    private func exportCSV() {
        // Pick the destination before authentication; no plaintext waits in a save panel.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TATWO-passwords.csv"
        panel.message = "CSV 會包含未加密的密碼，請存放在安全的位置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        errorMessage = nil
        exportTask = Task { @MainActor in
            defer { exporting = false }
            do {
                let data = try await vault.exportCSV(reason: "匯出瀏覽器密碼")
                try Task.checkCancellation()
                try BrowserPasswordCSVFileWriter.write(data, to: url)
            } catch is CancellationError {
                // Leaving settings cancels pending disclosure/export.
            } catch {
                // Do not surface arbitrary provider errors that may contain sensitive values.
                errorMessage = "無法匯出密碼，請確認身分驗證與儲存位置後再試。"
            }
        }
    }
}

/// Plaintext is intentional for an explicit CSV export, but must be owner-readable only.
/// mkstemp starts at 0600; rename publishes atomically, even over an existing 0644 file.
enum BrowserPasswordCSVFileWriter {
    static func write(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        var template = url.deletingLastPathComponent()
            .appendingPathComponent(".tatwo-password-export-XXXXXX").path.utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = template.withUnsafeBufferPointer {
            URL(fileURLWithPath: String(cString: $0.baseAddress!))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            // Only our uncommitted export staging file; never remove the destination.
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

@MainActor
private struct BrowserPasswordSettingsRow: View {
    @ObservedObject var vault: BrowserPasswordVault
    let credential: BrowserCredential
    @State private var revealedPassword: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var copied = false

    private var host: String { URL(string: credential.origin)?.host ?? credential.origin }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(host).font(.subheadline.weight(.medium)).lineLimit(1)
                        .help(credential.origin)
                    Text(credential.username.isEmpty ? "未填使用者名稱" : credential.username)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Text(revealedPassword ?? "••••••••")
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button(revealedPassword == nil ? "顯示" : "隱藏") { reveal() }
                    Button(copied ? "已拷貝" : "拷貝") { copy() }
                        .help("驗證後拷貝，60 秒後清除剪貼簿")
                    Button("刪除", role: .destructive) { delete() }
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(busy)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
        .onDisappear { concealAndCancel() }
        .onChange(of: credential.updatedAt) { _, _ in concealAndCancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Conceal already-visible values when the user switches away.
            conceal()
        }
    }

    private func conceal() {
        hideTask?.cancel()
        hideTask = nil
        revealedPassword = nil
    }

    private func concealAndCancel() {
        operation?.cancel()
        operation = nil
        busy = false
        copied = false
        conceal()
    }

    private func reveal() {
        if revealedPassword != nil { conceal(); return }
        busy = true
        errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let password = try await vault.revealPassword(credential.id, reason: "顯示瀏覽器密碼")
                try Task.checkCancellation()
                guard NSApplication.shared.isActive else { return }
                revealedPassword = password
                hideTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    revealedPassword = nil
                }
            } catch is CancellationError {
            } catch {
                errorMessage = "無法顯示密碼，請完成身分驗證後再試。"
            }
        }
    }

    private func copy() {
        busy = true
        copied = false
        errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                try await vault.copyPassword(credential.id)
                copied = true
            } catch is CancellationError {
            } catch {
                errorMessage = "無法拷貝密碼，請完成身分驗證後再試。"
            }
        }
    }

    private func delete() {
        conceal()
        busy = true
        errorMessage = nil
        operation = Task { @MainActor in
            defer { busy = false }
            let confirmed = await IslandNotice.shared.confirm(
                title: "刪除這組密碼？",
                detail: "將刪除 \(host) 的這組登入資料，此動作無法復原。",
                confirmLabel: "刪除", cancelLabel: "取消")
            guard confirmed, !Task.isCancelled else { return }
            do { try vault.delete(credential.id) }
            catch { errorMessage = "無法刪除密碼，請稍後再試。" }
        }
    }
}
