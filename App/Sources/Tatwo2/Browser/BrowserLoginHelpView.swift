import AppKit
import SwiftUI

struct BrowserLoginHelpView: View {
    let currentURL: String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var origin: URL? { BrowserExternalLoginPolicy.websiteOrigin(currentURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("登入協助").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("若畫面停在通行密鑰或 Touch ID 驗證，請使用網站的『試試其他方式』，選擇密碼或其他可用驗證方式。")
            Text("這個本機測試版的 Touch ID 通行密鑰支援尚未完成；不需要刪除通行密鑰或關閉兩步驗證。")
                .foregroundStyle(.secondary)
            Divider()
            Text("也可以在預設瀏覽器重新開始登入。它使用自己的登入狀態，不會繼承 TATWO 的 Cookie；只會開啟目前網站首頁，不會傳出驗證網址中的路徑或代碼。")
            if let origin {
                Text(origin.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
            }
            Button("在預設瀏覽器開啟目前網站") { openExternal() }
                .disabled(origin == nil)
            if origin == nil { Text("請先開啟 HTTP 或 HTTPS 網站。").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .padding(24).frame(width: 520)
    }

    private func openExternal() {
        guard let origin else { return }
        guard let destination = NSWorkspace.shared.urlForApplication(toOpen: origin) else {
            error = "找不到預設瀏覽器，請先在 macOS 系統設定中選擇瀏覽器。"; return
        }
        guard Bundle(url: destination)?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            error = "目前預設瀏覽器是 TATWO。請先在 macOS 系統設定中改為另一個瀏覽器，再重試。"; return
        }
        error = nil
        if !NSWorkspace.shared.open(origin) { error = "無法開啟預設瀏覽器，請稍後重試。" }
    }
}
