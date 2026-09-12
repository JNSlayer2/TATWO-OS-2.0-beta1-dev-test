// DEPRECATED REFERENCE — 2026-08-20 Aurora reconnaissance:
// S2 migration did not occur; this engine/tokens path has zero view consumers.
// Retained only as a candidate foundation for a future semantic-token migration.
// Revival or archival remains a user decision.

import AppKit
import SwiftUI
import TatwoUltraworkCore

// MARK: - H7 S1 semantic token layer
//
// Placement: **App layer** (`TatwoUltraworkMac`), not Core.
// Reason: tokens resolve SwiftUI `Color` / material / radius that already live beside
// `LiquidGlassTokens` and `ChatTypography`. Core stays free of SwiftUI design-surface types.
//
// Single source rule: default theme values are **live reads** of `LiquidGlassTokens`
// (and typography metrics already used by `ChatTypography`). No duplicated literals.
// Views still read `LiquidGlassTokens` directly in S1; this bag is the migration target for S2.

/// Runtime theme identifier for the V1 engine (stringly typed so unknown IDs fail closed).
struct TatwoThemeEngineID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// S1 sole registered theme: wraps current `LiquidGlassTokens` live values.
    static let `default` = TatwoThemeEngineID(rawValue: "default")

    /// Reserved for a future dedicated liquid-glass pack (not registered in S1).
    static let liquidGlassReserved = TatwoThemeEngineID(rawValue: "liquidGlass")
}

// MARK: Semantic keys (migration vocabulary for S2)

enum TatwoThemeColorSemanticKey: String, CaseIterable, Sendable {
    case background
    case surface
    case accent
    case accentPink
    case accentViolet
    case accentBlue
    case tint
    case textPrimary
    case textSecondary
}

enum TatwoThemeRadiusSemanticKey: String, CaseIterable, Sendable {
    case primary
    case card
    case chip
}

enum TatwoThemeMaterialSemanticKey: String, CaseIterable, Sendable {
    case shapeStyle
    case tintOpacity
    case strokeOpacity
    case blurReference
    case saturationReference
    case distortionReference
    case chromaticAberrationReference
    case shadowOpacity
    case shadowOffsetX
    case shadowOffsetY
    case shadowRadius
    case nodeCardTintOpacity
    case subtleFillOpacity
    case chipFillOpacity
    case glassIdentityFillOpacity
    case usesGlass
    case grain
    case ambient
    case radiusScale
}

enum TatwoThemeTypographySemanticKey: String, CaseIterable, Sendable {
    case body
    case transcript
    case transcriptMeta
    case sidebarHeader
    case sidebarProject
    case sidebarThreadTitle
    case sidebarThreadPreview
    case composer
    case code
}

enum TatwoThemeIconStyle: String, CaseIterable, Sendable {
    /// Current app: SF Symbols via system cascade (no custom icon set).
    case systemSymbol
}

/// Semantic token bag V1. Default theme maps 1:1 onto live `LiquidGlassTokens` / metrics sources.
struct TatwoThemeTokensV1: Sendable, Equatable {
    let themeID: TatwoThemeEngineID

    // Color semantics
    let background: Color
    let surface: Color
    let accent: Color
    let accentPink: Color
    let accentViolet: Color
    let accentBlue: Color
    let tint: Color
    /// System text roles — not palette-driven (matches TatwoTheme design: semantic status/text stay stable).
    let textPrimary: Color
    let textSecondary: Color

    // Radius / shape
    let radiusPrimary: CGFloat
    let radiusCard: CGFloat
    let radiusChip: CGFloat
    let shapeStyle: RoundedCornerStyle

    // Material / glass parameters
    let tintOpacity: Double
    let strokeOpacity: Double
    let blurReference: Double
    let saturationReference: Double
    let distortionReference: Double
    let chromaticAberrationReference: Double
    let shadowOpacity: Double
    let shadowOffsetX: CGFloat
    let shadowOffsetY: CGFloat
    let shadowRadius: CGFloat
    let nodeCardTintOpacity: Double
    let subtleFillOpacity: Double
    let chipFillOpacity: Double
    let glassIdentityFillOpacity: Double
    let usesGlass: Bool
    let grain: Double
    let ambient: Double
    let radiusScale: Double
    let surfaceFill: Color
    let surfaceBorder: Color

    // Typography scale (point sizes — fonts still constructed by ChatTypography in S1)
    let fontBody: CGFloat
    let fontTranscript: CGFloat
    let fontTranscriptMeta: CGFloat
    let fontSidebarHeader: CGFloat
    let fontSidebarProject: CGFloat
    let fontSidebarThreadTitle: CGFloat
    let fontSidebarThreadPreview: CGFloat
    let fontComposer: CGFloat
    let fontCode: CGFloat

    // Icon style
    let iconStyle: TatwoThemeIconStyle

    // MARK: - Single-source factory

    /// Default theme: every design value is read from `LiquidGlassTokens` / active palette /
    /// `TatwoChatTranscriptVisualMetrics` — never re-stated as a second truth source.
    static func fromLiquidGlassTokens(
        themeID: TatwoThemeEngineID = .default
    ) -> TatwoThemeTokensV1 {
        let palette = TatwoActivePalette.current
        return TatwoThemeTokensV1(
            themeID: themeID,
            background: LiquidGlassTokens.canvasBackground,
            surface: palette.usesGlass
                ? LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity)
                : palette.surfaceFill,
            accent: LiquidGlassTokens.brandAccent,
            accentPink: LiquidGlassTokens.accentPink,
            accentViolet: LiquidGlassTokens.accentViolet,
            accentBlue: LiquidGlassTokens.accentBlue,
            tint: LiquidGlassTokens.tint,
            textPrimary: Color.primary,
            textSecondary: Color.secondary,
            radiusPrimary: LiquidGlassTokens.radiusPrimary,
            radiusCard: LiquidGlassTokens.radiusCard,
            radiusChip: LiquidGlassTokens.radiusChip,
            shapeStyle: LiquidGlassTokens.shapeStyle,
            tintOpacity: LiquidGlassTokens.tintOpacity,
            strokeOpacity: LiquidGlassTokens.strokeOpacity,
            blurReference: LiquidGlassTokens.blurReference,
            saturationReference: LiquidGlassTokens.saturationReference,
            distortionReference: LiquidGlassTokens.distortionReference,
            chromaticAberrationReference: LiquidGlassTokens.chromaticAberrationReference,
            shadowOpacity: LiquidGlassTokens.shadowOpacity,
            shadowOffsetX: LiquidGlassTokens.shadowOffsetX,
            shadowOffsetY: LiquidGlassTokens.shadowOffsetY,
            shadowRadius: LiquidGlassTokens.shadowRadius,
            nodeCardTintOpacity: LiquidGlassTokens.nodeCardTintOpacity,
            subtleFillOpacity: LiquidGlassTokens.subtleFillOpacity,
            chipFillOpacity: LiquidGlassTokens.chipFillOpacity,
            glassIdentityFillOpacity: LiquidGlassTokens.glassIdentityFillOpacity,
            usesGlass: palette.usesGlass,
            grain: palette.grain,
            ambient: palette.ambient,
            radiusScale: palette.radiusScale,
            surfaceFill: palette.surfaceFill,
            surfaceBorder: palette.surfaceBorder,
            fontBody: TatwoChatTranscriptVisualMetrics.bodyPointSize,
            fontTranscript: TatwoChatTranscriptVisualMetrics.transcriptPointSize,
            fontTranscriptMeta: TatwoChatTranscriptVisualMetrics.transcriptMetaPointSize,
            fontSidebarHeader: TatwoChatTranscriptVisualMetrics.sidebarHeaderPointSize,
            fontSidebarProject: TatwoChatTranscriptVisualMetrics.sidebarProjectPointSize,
            fontSidebarThreadTitle: TatwoChatTranscriptVisualMetrics.sidebarThreadTitlePointSize,
            fontSidebarThreadPreview: TatwoChatTranscriptVisualMetrics.sidebarThreadPreviewPointSize,
            fontComposer: TatwoChatTranscriptVisualMetrics.composerPointSize,
            fontCode: TatwoChatTranscriptVisualMetrics.codePointSize,
            iconStyle: .systemSymbol
        )
    }

    // MARK: - Semantic lookup (S2 migration helpers; unused by views in S1)

    func color(_ key: TatwoThemeColorSemanticKey) -> Color {
        switch key {
        case .background: background
        case .surface: surface
        case .accent: accent
        case .accentPink: accentPink
        case .accentViolet: accentViolet
        case .accentBlue: accentBlue
        case .tint: tint
        case .textPrimary: textPrimary
        case .textSecondary: textSecondary
        }
    }

    func radius(_ key: TatwoThemeRadiusSemanticKey) -> CGFloat {
        switch key {
        case .primary: radiusPrimary
        case .card: radiusCard
        case .chip: radiusChip
        }
    }

    func fontPointSize(_ key: TatwoThemeTypographySemanticKey) -> CGFloat {
        switch key {
        case .body: fontBody
        case .transcript: fontTranscript
        case .transcriptMeta: fontTranscriptMeta
        case .sidebarHeader: fontSidebarHeader
        case .sidebarProject: fontSidebarProject
        case .sidebarThreadTitle: fontSidebarThreadTitle
        case .sidebarThreadPreview: fontSidebarThreadPreview
        case .composer: fontComposer
        case .code: fontCode
        }
    }
}

// MARK: - Color component equality helpers (tests / drift guards)

enum TatwoThemeColorProbe {
    /// Device-RGB components for bit-stable comparison of SwiftUI colors used as tokens.
    static func rgba(_ color: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else { return nil }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }

    /// Bit-level fingerprint of device-RGB components (native Double/Float bitPattern per channel).
    /// Used by Theme tests so equality is representation-exact, not epsilon-approximate.
    static func componentBitFingerprint(_ color: Color) -> String? {
        guard let rgba = rgba(color) else { return nil }
        return [
            bitHex(rgba.0),
            bitHex(rgba.1),
            bitHex(rgba.2),
            bitHex(rgba.3)
        ].joined(separator: ":")
    }

    /// Hex-style serialization of the same device-RGB components (full-width bit hex).
    static func hexRGBA(_ color: Color) -> String? {
        componentBitFingerprint(color)
    }

    private static func bitHex(_ value: CGFloat) -> String {
        String(value.native.bitPattern, radix: 16)
    }

    private static func nativeBitsEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        lhs.native.bitPattern == rhs.native.bitPattern
    }

    /// Bit-exact equality of device-RGB channel bit patterns (and CGColor components when available).
    static func bitEqual(_ lhs: Color, _ rhs: Color) -> Bool {
        guard let left = componentBitFingerprint(lhs),
              let right = componentBitFingerprint(rhs)
        else {
            return false
        }
        if left != right {
            return false
        }
        // Cross-check raw NSColor/deviceRGB components (still bit-level via native bitPattern).
        let leftNS = NSColor(lhs)
        let rightNS = NSColor(rhs)
        guard let leftRGB = leftNS.usingColorSpace(.deviceRGB),
              let rightRGB = rightNS.usingColorSpace(.deviceRGB)
        else {
            return true
        }
        return nativeBitsEqual(leftRGB.redComponent, rightRGB.redComponent)
            && nativeBitsEqual(leftRGB.greenComponent, rightRGB.greenComponent)
            && nativeBitsEqual(leftRGB.blueComponent, rightRGB.blueComponent)
            && nativeBitsEqual(leftRGB.alphaComponent, rightRGB.alphaComponent)
    }

    @available(*, deprecated, message: "Use bitEqual for Theme S1 evidence; epsilon is not bit-level.")
    static func approximatelyEqual(_ lhs: Color, _ rhs: Color, epsilon: CGFloat = 0.000_1) -> Bool {
        bitEqual(lhs, rhs) || {
            guard let a = rgba(lhs), let b = rgba(rhs) else {
                return false
            }
            return abs(a.0 - b.0) <= epsilon
                && abs(a.1 - b.1) <= epsilon
                && abs(a.2 - b.2) <= epsilon
                && abs(a.3 - b.3) <= epsilon
        }()
    }
}
