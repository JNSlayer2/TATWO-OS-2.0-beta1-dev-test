import SwiftUI

/// Shared Chat chrome only. Actions and state remain owned by the caller;
/// rendering this file never creates a Chat model, engine or persistent store.
struct ChatComposerToolbarRow<Content: View>: View {
    let compact: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: compact ? 7 : 9, content: content)
            .frame(height: 28)
    }
}

struct ChatComposerPermissionLabel: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(title).font(.caption2.weight(.black)).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .black)).opacity(0.82)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .contentShape(Capsule())
    }
}

struct ChatComposerModelLabel: View {
    let title: String
    let suffix: String?
    let compact: Bool
    let selected: Bool

    static func width(compact: Bool) -> CGFloat { compact ? 90 : 110 }

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Text(title)
                .font(.caption2.weight(.black))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: compact ? 38 : 63, alignment: .leading)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .frame(width: 24, alignment: .center)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 24, height: 1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 5 : 7)
        .frame(width: Self.width(compact: compact), height: 24)
        .chatGlassChip(isSelected: selected)
        .contentShape(RoundedRectangle(
            cornerRadius: LiquidGlassTokens.radiusChip,
            style: LiquidGlassTokens.shapeStyle))
    }
}

struct ChatComposerCollaborationLabel: View {
    let compact: Bool
    let active: Bool
    let level: String
    let selected: Bool

    static func width(compact: Bool) -> CGFloat { compact ? 116 : 126 }

    var body: some View {
        HStack(spacing: compact ? 5 : 7) {
            Image(systemName: active ? "point.3.connected.trianglepath.dotted" : "target")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? LiquidGlassTokens.brandAccent : Color.secondary)
            Text("ultrawork")
                .font(.caption2.weight(.semibold))
                .frame(width: compact ? 50 : 56, alignment: .leading)
                .lineLimit(1)
            Text(active ? level : "XL")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(LiquidGlassTokens.brandAccent)
                .lineLimit(1)
                .frame(width: 18)
                .opacity(active ? 1 : 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(active ? LiquidGlassTokens.brandAccent : Color.secondary)
        .padding(.horizontal, compact ? 7 : 9)
        .frame(width: Self.width(compact: compact), height: 24)
        .chatGlassChip(isSelected: selected || active, tint: LiquidGlassTokens.brandAccent)
        .contentShape(RoundedRectangle(
            cornerRadius: LiquidGlassTokens.radiusChip,
            style: LiquidGlassTokens.shapeStyle))
    }
}

struct ChatComposerSendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(enabled ? .white : .secondary)
                .frame(width: 28, height: 28)
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!enabled)
        .buttonStyle(.plain)
        .background {
            Circle().fill(enabled
                ? AnyShapeStyle(LiquidGlassTokens.ultraworkGradient)
                : AnyShapeStyle(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity)))
        }
        .overlay {
            Circle().strokeBorder(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.strokeOpacity))
        }
        .shadow(
            color: LiquidGlassTokens.brandAccent.opacity(enabled ? LiquidGlassTokens.shadowOpacity : .zero),
            radius: LiquidGlassTokens.shadowRadius,
            x: LiquidGlassTokens.shadowOffsetX,
            y: LiquidGlassTokens.shadowOffsetY)
    }
}
