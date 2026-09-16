import SwiftUI

/// Do not present imported extension inventory as installed executable code.
struct BrowserExtensionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Chrome 擴充功能", systemImage: "puzzlepiece.extension")
                .font(.headline)
            Text("此版本尚不能安裝或執行 Chrome 擴充功能。")
            Text("從其他瀏覽器導入的擴充清單不代表已安裝；原瀏覽器的擴充與資料不受影響。")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
