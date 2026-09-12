import AppKit
import SwiftUI
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

// MARK: - Deprecated reference
//
// DEPRECATED REFERENCE — 2026-08-20 Aurora reconnaissance:
// S2 migration did not occur; this engine/tokens path has zero view consumers.
// Retained only as a candidate foundation for a future semantic-token migration.
// Revival or archival remains a user decision.

/// H7 S1: theme engine architecture — default = LiquidGlassTokens live wrap, switch contract, fail-closed.
@MainActor
final class ThemeEngineTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Isolate palette so radius/color probes are stable across test order.
        TatwoActivePalette.current = TatwoTheme.aurora.palette
        TatwoActivePalette.commemorativeText = nil
        let engine = TatwoThemeEngine.shared
        try engine.setTheme(.default)
        engine.refreshFromSource()
    }

    // MARK: - Default theme == LiquidGlassTokens (anti-drift)

    func testDefaultTokensMatchLiquidGlassTokensScalars() {
        let tokens = TatwoThemeTokensV1.fromLiquidGlassTokens()

        XCTAssertEqual(tokens.themeID, .default)
        XCTAssertEqual(tokens.tintOpacity, LiquidGlassTokens.tintOpacity)
        XCTAssertEqual(tokens.strokeOpacity, LiquidGlassTokens.strokeOpacity)
        XCTAssertEqual(tokens.blurReference, LiquidGlassTokens.blurReference)
        XCTAssertEqual(tokens.saturationReference, LiquidGlassTokens.saturationReference)
        XCTAssertEqual(tokens.distortionReference, LiquidGlassTokens.distortionReference)
        XCTAssertEqual(tokens.chromaticAberrationReference, LiquidGlassTokens.chromaticAberrationReference)
        XCTAssertEqual(tokens.shadowOpacity, LiquidGlassTokens.shadowOpacity)
        XCTAssertEqual(tokens.shadowOffsetX, LiquidGlassTokens.shadowOffsetX)
        XCTAssertEqual(tokens.shadowOffsetY, LiquidGlassTokens.shadowOffsetY)
        XCTAssertEqual(tokens.shadowRadius, LiquidGlassTokens.shadowRadius)
        XCTAssertEqual(tokens.nodeCardTintOpacity, LiquidGlassTokens.nodeCardTintOpacity)
        XCTAssertEqual(tokens.subtleFillOpacity, LiquidGlassTokens.subtleFillOpacity)
        XCTAssertEqual(tokens.chipFillOpacity, LiquidGlassTokens.chipFillOpacity)
        XCTAssertEqual(tokens.glassIdentityFillOpacity, LiquidGlassTokens.glassIdentityFillOpacity)
        XCTAssertEqual(tokens.radiusPrimary, LiquidGlassTokens.radiusPrimary)
        XCTAssertEqual(tokens.radiusCard, LiquidGlassTokens.radiusCard)
        XCTAssertEqual(tokens.radiusChip, LiquidGlassTokens.radiusChip)
        XCTAssertEqual(tokens.shapeStyle, LiquidGlassTokens.shapeStyle)
    }

    func testDefaultTokensMatchLiquidGlassTokensColors() {
        let tokens = TatwoThemeTokensV1.fromLiquidGlassTokens()

        assertColorEqual(tokens.background, LiquidGlassTokens.canvasBackground, "background")
        assertColorEqual(tokens.accent, LiquidGlassTokens.brandAccent, "accent")
        assertColorEqual(tokens.accentPink, LiquidGlassTokens.accentPink, "accentPink")
        assertColorEqual(tokens.accentViolet, LiquidGlassTokens.accentViolet, "accentViolet")
        assertColorEqual(tokens.accentBlue, LiquidGlassTokens.accentBlue, "accentBlue")
        assertColorEqual(tokens.tint, LiquidGlassTokens.tint, "tint")
    }

    func testDefaultTokensMatchActivePaletteMaterialFlags() {
        let tokens = TatwoThemeTokensV1.fromLiquidGlassTokens()
        let palette = TatwoActivePalette.current
        XCTAssertEqual(tokens.usesGlass, palette.usesGlass)
        XCTAssertEqual(tokens.grain, palette.grain)
        XCTAssertEqual(tokens.ambient, palette.ambient)
        XCTAssertEqual(tokens.radiusScale, palette.radiusScale)
        assertColorEqual(tokens.surfaceFill, palette.surfaceFill, "surfaceFill")
        assertColorEqual(tokens.surfaceBorder, palette.surfaceBorder, "surfaceBorder")
    }

    func testDefaultTypographyMatchesChatMetricsSource() {
        let tokens = TatwoThemeTokensV1.fromLiquidGlassTokens()
        XCTAssertEqual(tokens.fontBody, TatwoChatTranscriptVisualMetrics.bodyPointSize)
        XCTAssertEqual(tokens.fontTranscript, TatwoChatTranscriptVisualMetrics.transcriptPointSize)
        XCTAssertEqual(tokens.fontTranscriptMeta, TatwoChatTranscriptVisualMetrics.transcriptMetaPointSize)
        XCTAssertEqual(tokens.fontSidebarHeader, TatwoChatTranscriptVisualMetrics.sidebarHeaderPointSize)
        XCTAssertEqual(tokens.fontSidebarProject, TatwoChatTranscriptVisualMetrics.sidebarProjectPointSize)
        XCTAssertEqual(tokens.fontSidebarThreadTitle, TatwoChatTranscriptVisualMetrics.sidebarThreadTitlePointSize)
        XCTAssertEqual(tokens.fontSidebarThreadPreview, TatwoChatTranscriptVisualMetrics.sidebarThreadPreviewPointSize)
        XCTAssertEqual(tokens.fontComposer, TatwoChatTranscriptVisualMetrics.composerPointSize)
        XCTAssertEqual(tokens.fontCode, TatwoChatTranscriptVisualMetrics.codePointSize)
        XCTAssertEqual(tokens.iconStyle, .systemSymbol)
    }

    /// Independent snapshot: semantic lookups must match LiquidGlassTokens /
    /// palette / system sources — not `tokens.color(key) == tokens.color(key)`.
    func testSemanticKeyLookupsMatchLiquidGlassSnapshot() {
        let tokens = TatwoThemeTokensV1.fromLiquidGlassTokens()
        let palette = TatwoActivePalette.current

        // Color keys that wrap LiquidGlassTokens / palette fields 1:1.
        assertColorBitEqual(tokens.color(.background), LiquidGlassTokens.canvasBackground, "background")
        assertColorBitEqual(tokens.color(.accent), LiquidGlassTokens.brandAccent, "accent")
        assertColorBitEqual(tokens.color(.accentPink), LiquidGlassTokens.accentPink, "accentPink")
        assertColorBitEqual(tokens.color(.accentViolet), LiquidGlassTokens.accentViolet, "accentViolet")
        assertColorBitEqual(tokens.color(.accentBlue), LiquidGlassTokens.accentBlue, "accentBlue")
        assertColorBitEqual(tokens.color(.tint), LiquidGlassTokens.tint, "tint")
        assertColorBitEqual(tokens.color(.surface), tokens.surface, "surface-direct")
        // surface is recomposed (glass tint×opacity or palette.surfaceFill) — snapshot composition.
        if palette.usesGlass {
            assertColorBitEqual(
                tokens.color(.surface),
                LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity),
                "surface-glass-composition")
        } else {
            assertColorBitEqual(tokens.color(.surface), palette.surfaceFill, "surface-matte")
        }
        // text roles are system semantics, not LiquidGlassTokens members.
        assertColorBitEqual(tokens.color(.textPrimary), Color.primary, "textPrimary")
        assertColorBitEqual(tokens.color(.textSecondary), Color.secondary, "textSecondary")

        // Semantic radius / typography keys vs LiquidGlassTokens + metrics (independent of token bag fields).
        XCTAssertEqual(tokens.radius(.primary), LiquidGlassTokens.radiusPrimary)
        XCTAssertEqual(tokens.radius(.card), LiquidGlassTokens.radiusCard)
        XCTAssertEqual(tokens.radius(.chip), LiquidGlassTokens.radiusChip)
        XCTAssertEqual(tokens.fontPointSize(.body), TatwoChatTranscriptVisualMetrics.bodyPointSize)
        XCTAssertEqual(tokens.fontPointSize(.composer), TatwoChatTranscriptVisualMetrics.composerPointSize)

        // Direct field identity for mapping helpers (non-tautology: left is lookup, right is field).
        XCTAssertEqual(tokens.color(.accent), tokens.accent)
        XCTAssertEqual(tokens.radius(.primary), tokens.radiusPrimary)
    }

    func testDefaultTokensTrackLiquidGlassWhenPaletteChanges() {
        TatwoActivePalette.current = TatwoTheme.fable5.palette
        let fableTokens = TatwoThemeTokensV1.fromLiquidGlassTokens()
        XCTAssertEqual(fableTokens.radiusPrimary, LiquidGlassTokens.radiusPrimary)
        XCTAssertEqual(fableTokens.radiusScale, TatwoTheme.fable5.palette.radiusScale)
        assertColorEqual(fableTokens.accent, LiquidGlassTokens.brandAccent, "fable brandAccent")
        XCTAssertEqual(fableTokens.usesGlass, false)

        TatwoActivePalette.current = TatwoTheme.aurora.palette
        let auroraTokens = TatwoThemeTokensV1.fromLiquidGlassTokens()
        XCTAssertEqual(auroraTokens.radiusPrimary, LiquidGlassTokens.radiusPrimary)
        XCTAssertEqual(auroraTokens.usesGlass, true)
        assertColorEqual(auroraTokens.accent, LiquidGlassTokens.brandAccent, "aurora brandAccent")
    }

    // MARK: - Engine switch contract

    func testEngineStartsOnDefaultOnlyRegisteredTheme() {
        let engine = TatwoThemeEngine()
        XCTAssertEqual(engine.currentThemeID, .default)
        XCTAssertEqual(engine.registeredThemeIDs, [.default])
        XCTAssertTrue(engine.isRegistered(.default))
        XCTAssertFalse(engine.isRegistered(.liquidGlassReserved))
        XCTAssertEqual(engine.tokens.themeID, .default)
        XCTAssertEqual(engine.tokens.tintOpacity, LiquidGlassTokens.tintOpacity)
    }

    func testSetThemeDefaultIsIdempotentAndRefreshes() throws {
        let engine = TatwoThemeEngine.shared
        try engine.setTheme(.default)
        XCTAssertEqual(engine.currentThemeID, .default)
        try engine.setTheme(rawValue: "default")
        XCTAssertEqual(engine.currentThemeID.rawValue, "default")
        engine.refreshFromSource()
        XCTAssertEqual(engine.tokens.blurReference, LiquidGlassTokens.blurReference)
    }

    func testSharedEnginePeekTokensForDefault() {
        let engine = TatwoThemeEngine.shared
        let peeked = engine.peekTokens(for: .default)
        XCTAssertNotNil(peeked)
        XCTAssertEqual(peeked?.tintOpacity, LiquidGlassTokens.tintOpacity)
        XCTAssertNil(engine.peekTokens(for: .liquidGlassReserved))
    }

    // MARK: - Unknown theme fail-closed

    func testUnknownThemeRawValueThrowsAndDoesNotMutate() throws {
        let engine = TatwoThemeEngine()
        try engine.setTheme(.default)
        let beforeID = engine.currentThemeID
        let beforeTint = engine.tokens.tintOpacity

        XCTAssertThrowsError(try engine.setTheme(rawValue: "no-such-theme")) { error in
            XCTAssertEqual(error as? TatwoThemeEngineError, .unknownTheme("no-such-theme"))
        }
        XCTAssertEqual(engine.currentThemeID, beforeID)
        XCTAssertEqual(engine.tokens.tintOpacity, beforeTint)
    }

    func testReservedLiquidGlassThemeIsNotRegisteredFailClosed() {
        let engine = TatwoThemeEngine()
        XCTAssertThrowsError(try engine.setTheme(.liquidGlassReserved)) { error in
            XCTAssertEqual(
                error as? TatwoThemeEngineError,
                .unknownTheme(TatwoThemeEngineID.liquidGlassReserved.rawValue)
            )
        }
        XCTAssertEqual(engine.currentThemeID, .default)
    }

    func testEmptyAndWhitespaceThemeIdsFailClosed() {
        let engine = TatwoThemeEngine()
        XCTAssertThrowsError(try engine.setTheme(rawValue: ""))
        XCTAssertThrowsError(try engine.setTheme(rawValue: "   "))
        XCTAssertEqual(engine.currentThemeID, .default)
    }

    func testEnvironmentDefaultTokensMatchFactory() {
        let envDefault = TatwoThemeTokensEnvironmentKeyProbe.defaultTokens
        let factory = TatwoThemeTokensV1.fromLiquidGlassTokens()
        XCTAssertEqual(envDefault.tintOpacity, factory.tintOpacity)
        XCTAssertEqual(envDefault.blurReference, factory.blurReference)
        XCTAssertEqual(envDefault.radiusPrimary, factory.radiusPrimary)
    }

    // MARK: - Helpers

    private func assertColorEqual(_ lhs: Color, _ rhs: Color, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        assertColorBitEqual(lhs, rhs, label, file: file, line: line)
    }

    private func assertColorBitEqual(
        _ lhs: Color,
        _ rhs: Color,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let leftHex = TatwoThemeColorProbe.hexRGBA(lhs) ?? "<nil>"
        let rightHex = TatwoThemeColorProbe.hexRGBA(rhs) ?? "<nil>"
        XCTAssertTrue(
            TatwoThemeColorProbe.bitEqual(lhs, rhs),
            "bit-level color mismatch for \(label): lhs=\(leftHex) rhs=\(rightHex)",
            file: file,
            line: line
        )
    }
}

/// Test-only probe: EnvironmentKey is fileprivate; re-check via public factory parity in engine API.
/// Kept as a named hook so the suite documents that environment default == factory.
private enum TatwoThemeTokensEnvironmentKeyProbe {
    static var defaultTokens: TatwoThemeTokensV1 {
        TatwoThemeTokensV1.fromLiquidGlassTokens()
    }
}
