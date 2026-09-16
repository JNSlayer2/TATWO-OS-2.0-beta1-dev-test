import SwiftUI

/// W67 intentionally stays glass in both app palettes; system appearance and
/// accessibility contrast/transparency still belong to the native material.
struct BrowserOmniboxGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                .fill(LiquidGlassTokens.browserOmniboxMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                        .fill(LiquidGlassTokens.browserOmniboxTint(for: colorScheme)
                            .opacity(LiquidGlassTokens.browserOmniboxTintOpacity))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                        .strokeBorder(LiquidGlassTokens.browserOmniboxBorder
                            .opacity(LiquidGlassTokens.browserOmniboxBorderOpacity),
                            lineWidth: BrowserOmniboxMetrics.strokeWidth)
                }
                .allowsHitTesting(false)
        }
    }
}
