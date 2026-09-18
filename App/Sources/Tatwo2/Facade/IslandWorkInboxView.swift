import SwiftUI

/// The footer and the expanded Island observe the same bounded snapshot. No
/// work is approved here; tapping a row only routes to its owning surface.
struct IslandWorkInboxView: View {
    @ObservedObject var inbox: IslandExceptionsCount
    var canOpen: (IslandWorkSnapshot.Target) -> Bool = IslandExceptionsNavigation.canOpen
    var onOpen: (IslandWorkSnapshot.Target) -> Void = IslandExceptionsNavigation.open

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("待處理事項（\(inbox.count)）")
                    .font(.headline)
                Spacer()
                if inbox.count > 2 {
                    Text("捲動查看全部")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !inbox.hasLoaded {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在讀取待處理事項…")
                }
            } else if inbox.data.exceptions.isEmpty {
                Text("目前沒有待處理事項")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(inbox.data.exceptions) { item in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? "未命名工作" : item.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(2)
                                    Text(item.hint)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                if canOpen(item.target) {
                                    Button("查看") { onOpen(item.target) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("查看 \(item.title)")
                                } else {
                                    Text("原工作已無法開啟")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .accessibilityLabel("待處理事項清單")
            }
            Spacer(minLength: 0)
        }
        .frame(width: LiquidGlassTokens.islandBlankWidth,
               height: LiquidGlassTokens.islandBlankHeight,
               alignment: .topLeading)
        .padding(.top, LiquidGlassTokens.islandNoticeTopInset)
        .task { await inbox.observe() }
    }
}
