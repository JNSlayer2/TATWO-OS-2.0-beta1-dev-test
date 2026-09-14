import SwiftUI

/// Pure row partition; no view state or workspace dependencies.
enum WorkspaceModeRows {
    static func layout(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let rows = (count + 4) / 5
        let perRow = (count + rows - 1) / rows
        return stride(from: 0, to: count, by: perRow).map { min(perRow, count - $0) }
    }

    static func fontSize(count: Int) -> Double {
        switch count {
        case ...3: 12.5
        case 4: 11.5
        default: 10.5
        }
    }
}

/// Shared full-inner-width header for every workspace.
struct WorkspaceSidebarModePicker: View {
    let modes: [ChatRunMode]
    let selection: ChatRunMode
    let onSelect: (ChatRunMode) -> Void

    var body: some View {
        let rows = WorkspaceModeRows.layout(count: modes.count)
        VStack(spacing: 5) {
            ForEach(rows.indices, id: \.self) { row in
                let start = rows.prefix(row).reduce(0, +)
                HStack(spacing: 5) {
                    ForEach(Array(modes[start..<(start + rows[row])])) { mode in
                        modeButton(mode, count: rows[row])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(4)
        .chatGlassChip()
        // Same outer inset as before W36 so Chat/CLI/Bot with ≤3 modes render exactly as today.
        .padding(.horizontal, 12)
    }

    private func modeButton(_ mode: ChatRunMode, count: Int) -> some View {
        let selected = selection == mode
        return Button { onSelect(mode) } label: {
            Text(mode.displayName)
                .font(ChatTypography.systemUI(WorkspaceModeRows.fontSize(count: count),
                                               weight: selected ? .bold : .semibold))
                .lineLimit(1)
                // Declared sizes are 12.5 / 11.5 / 10.5 (≤3 / 4 / 5 per row). Only a
                // four- or five-column row may shrink slightly further (SF "Browser" exceeds a
                // 40pt chip at 10.5); chip height never changes.
                .minimumScaleFactor(count >= 4 ? 0.8 : 1.0)
                .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.90))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .chatGlassChip(isSelected: selected)
                .contentShape(RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip,
                                               style: LiquidGlassTokens.shapeStyle))
        }
        .buttonStyle(.plain)
        .help(mode.subtitle)
        .accessibilityIdentifier("chat-workspace-mode-\(mode.rawValue.lowercased())")
    }
}
