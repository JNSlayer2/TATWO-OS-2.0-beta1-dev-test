import SwiftUI

/// G1 installation/status surface. No device commands or installation side effects.
struct PocketAdAssistantSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Jump Over Creek", systemImage: "hand.raised.app")
                .font(.headline)
            Text("逐 App 選擇屏蔽、自動跳過與保留獎勵。")
                .foregroundStyle(.secondary)
            Divider()
            LabeledContent("開發階段", value: "UI 原型 · 尚未處理廣告")
            LabeledContent("裝置端版本", value: "尚未安裝／未讀取")
            LabeledContent("iPhone · iOS 26／27", value: "待真機驗證")
            LabeledContent("iPad · iPadOS 26／27", value: "待真機驗證")
            Divider()
            Text("安裝與裝置相容性").font(.headline)
            Text("完成 UI 驗收與技術驗證後，才提供可用安裝方案。未驗證的系統不標示為支援。")
                .font(.callout).foregroundStyle(.secondary)
            Text("停用與移除").font(.headline)
            Text("此頁不會安裝描述檔、VPN 或憑證，也不會控制手機。原型不修改其他 App 資料。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("pocket-ad-assistant")
    }
}
