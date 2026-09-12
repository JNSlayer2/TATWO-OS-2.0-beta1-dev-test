// 2.0 新畫面（不是照搬）：使用者 2026-09-03 要求「設定頁做瀏覽器管理，並有一項管理未關閉的瀏覽器」。
// 新畫面一律放 New/，不放 Facade（Facade 禁自畫 View）；定位冊已補條目。
import SwiftUI

/// 設定頁「瀏覽器管理」上方的「未關閉的瀏覽器」卡：每條討論串自己的分頁組（D23）。
/// 放 Facade 讓照搬的 ChatPageSettings.swift 只加一行。
struct OpenBrowsersCard: View {
    @ObservedObject var model: ChatPageModel

    var body: some View {
        let sessions = model.openBrowserSessions
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("未關閉的瀏覽器（\(sessions.count)）")
                    .font(.headline)
                Spacer()
                if !sessions.isEmpty {
                    Button("全部關閉") { model.closeAllBrowserLanes() }
                        .buttonStyle(.bordered)
                }
            }
            if sessions.isEmpty {
                Text("目前沒有討論串留著開啟的網頁。切換討論串時，各自的分頁組會分開保存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.projectName.isEmpty ? item.threadTitle : "\(item.projectName) › \(item.threadTitle)")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(item.urls.prefix(3).map { $0.host ?? $0.absoluteString }.joined(separator: "、") + (item.laneCount > 3 ? "…" : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(item.laneCount) 個分頁")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("關閉") { model.closeBrowserLanes(for: item.sessionID) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
