import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

enum AIAccountEditKind: String, Identifiable {
    case authenticator = "綁定驗證器", label = "改標籤", scope = "只允許某條對話"
    var id: Self { self }
}

@MainActor
struct AIAccountEditView: View {
    let vault: BrowserAIVault
    let account: AICredential
    let kind: AIAccountEditKind
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var humanHeld = false
    @State private var failed = false

    var body: some View {
        Form {
            Text(kind.rawValue).font(.headline)
            if kind == .authenticator {
                Toggle("已綁・人持有（OS 不保存密鑰）", isOn: $humanHeld)
                SecureField("貼上 otpauth:// 或 Base32 密鑰", text: $value).disabled(humanHeld)
                Button("掃 QR 圖檔", action: scanQR).disabled(humanHeld)
                Text("只接受 SHA1、6 碼、30 秒的 TOTP。未支援的規格不會悄悄改成另一種驗證碼。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("清空並儲存＝解除 OS 代管；不會替你解除網站上的 2FA。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField(kind == .label ? "標籤" : "對話 ID", text: $value)
            }
            if failed { Text("未儲存；請檢查內容或鑰匙圈。").foregroundStyle(.red) }
            HStack {
                Button("取消") { value = ""; dismiss() }
                Spacer()
                Button("儲存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(kind == .scope && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 460)
        .onAppear {
            humanHeld = account.authenticatorStatus == .humanHeld
            if kind == .label { value = account.label }
            if kind == .scope, case let .thread(id) = account.allowedCallers { value = id }
        }
        .onDisappear { value = "" }
    }

    private func save() {
        do {
            switch kind {
            case .label: try vault.update(account.id, label: value)
            case .scope:
                try vault.update(account.id, allowedCallers: .thread(id: value.trimmingCharacters(in: .whitespacesAndNewlines)))
            case .authenticator:
                let secret = humanHeld || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : try TOTP.secret(from: value)
                try vault.bindAuthenticator(account.id, secret: secret, humanHeld: humanHeld)
            }
            value = ""
            dismiss()
        } catch { failed = true }
    }

    private func scanQR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? Int, size <= 10_000_000,
                  let image = CIImage(contentsOf: url), image.extent.width <= 8192, image.extent.height <= 8192,
                  let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { throw TOTP.Failure.invalidSecret }
            let codes = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            guard codes.count == 1, let code = codes.first else { throw TOTP.Failure.invalidSecret }
            value = try TOTP.secret(from: code)
            failed = false
        } catch { failed = true }
    }
}

@MainActor
struct AIICloudImportView: View {
    let vault: BrowserAIVault
    let preview: AIICloudImportPreview
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = [] // Never default personal accounts into the AI vault.
    @State private var message: String?
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("匯入 iCloud").font(.headline)
            Text("只勾選允許 AI 使用的帳號；未勾選的密碼及驗證器不會存入保險庫。")
                .font(.footnote).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(preview.items) { item in
                        Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { enabled in
                            if enabled { selected.insert(item.id) } else { selected.remove(item.id) }
                        })) {
                            HStack {
                                Text(URL(string: item.origin)?.host ?? "")
                                Text(item.username).privacySensitive()
                                Spacer()
                                Text(item.totpSecret == nil ? "未含驗證器" : "含驗證器")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(finished)
                    }
                }
            }
            Text("略過 \(preview.skipped) 筆無效或不支援的資料。").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote) }
            HStack {
                Button(finished ? "完成" : "取消") { dismiss() }
                Spacer()
                Button("匯入 \(selected.count) 個帳號", action: save).disabled(selected.isEmpty || finished)
            }
        }
        .padding(22).frame(width: 650, height: 420)
    }

    private func save() {
        do {
            let count = try vault.importICloud(preview.items.filter { selected.contains($0.id) })
            message = "已匯入 \(count) 個帳號。請自行刪除含明文密碼的 CSV 原檔；OS 不會自動刪除。"
            finished = true
        } catch {
            message = "匯入未全部完成，先前成功的項目已保留。請检查鑰匙圈；處理後自行刪除 CSV 原檔。"
        }
    }
}
