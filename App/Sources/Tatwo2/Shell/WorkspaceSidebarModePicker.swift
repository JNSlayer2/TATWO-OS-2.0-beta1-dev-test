import SwiftUI

/// The same header for existing pages and domain-created tabs.
struct WorkspaceSidebarModePicker: View {
    let modes: [ChatRunMode]
    let selection: ChatRunMode
    let onSelect: (ChatRunMode) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(modes) { mode in
                let selected = selection == mode
                Button { onSelect(mode) } label: {
                    Text(mode.rawValue)
                        .font(ChatTypography.systemUI(12.5, weight: selected ? .bold : .semibold))
                        .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.90))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .chatGlassChip(isSelected: selected)
                        .contentShape(RoundedRectangle(
                            cornerRadius: LiquidGlassTokens.radiusChip,
                            style: LiquidGlassTokens.shapeStyle))
                }
                .buttonStyle(.plain)
                .help(mode.subtitle)
                .accessibilityIdentifier("chat-workspace-mode-\(mode.rawValue.lowercased())")
            }
        }
        .padding(4)
        .chatGlassChip()
        // 舊版 Bot 分頁：分頁條在側欄內再內縮 12pt（側欄 250 → 分頁條約 190）。
        .padding(.horizontal, 12)
    }
}
