import SwiftUI

/// Existing OS palette + geometry, not a second theme system or new glass effect.
struct CLIWorkbenchAppearance {
    let canvas: Color
    let surface: Color
    let border: Color
    let accent: Color
    let ink: Color
    let secondaryInk: Color
    let cornerRadius: CGFloat

    static func osTheme(_ palette: TatwoThemePalette) -> Self {
        Self(canvas: palette.canvasBase, surface: palette.surfaceFill,
             border: palette.usesGlass ? Color.gray.opacity(LiquidGlassTokens.strokeOpacity) : palette.surfaceBorder,
             accent: palette.brandAccent,
             ink: Color(nsColor: .init(calibratedWhite: 0.16, alpha: 1)),
             secondaryInk: Color(nsColor: .init(calibratedWhite: 0.48, alpha: 1)),
             cornerRadius: LiquidGlassTokens.radiusChip)
    }
}
