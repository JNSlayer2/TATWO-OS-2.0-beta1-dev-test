import SwiftUI

/// The same header for existing pages and domain-created tabs.
struct WorkspaceSidebarModePicker: View {
    let modes: [ChatRunMode]
    let selection: ChatRunMode
    let onSelect: (ChatRunMode) -> Void

    var body: some View {
        Group {
            if modes.count > 3 {
                ScrollView(.horizontal, showsIndicators: true) { modeButtons }
            } else { modeButtons }
        }
        .padding(4)
        .chatGlassChip()
        .padding(.horizontal, 12)
    }

    private var modeButtons: some View {
        HStack(spacing: 5) {
            ForEach(modes) { mode in
                let selected = selection == mode
                Button { onSelect(mode) } label: {
                    Text(mode.displayName)
                        .lineLimit(1)
                        .padding(.horizontal, modes.count > 3 ? 8 : 0)
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
    }
}
