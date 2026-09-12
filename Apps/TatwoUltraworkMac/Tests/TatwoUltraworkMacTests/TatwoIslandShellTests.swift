import AppKit
import SwiftUI
import XCTest
@testable import TatwoUltraworkMac

final class TatwoIslandShellTests: XCTestCase {
    private static let mainPathMarker = "// MARK: - macOS 26+ 系統原生 Liquid Glass 主路徑"
    private static let notchMarker = "// MARK: - 頂部黑 notch"

    func testMacOS27PathUsesSystemGlassEffectAsTheOnlyBaseplate() throws {
        let mainPath = try Self.section(
            from: Self.mainPathMarker,
            to: Self.notchMarker
        )

        XCTAssertTrue(mainPath.contains("if #available(macOS 26.0, *)"))
        XCTAssertTrue(mainPath.contains("Color.clear"))
        XCTAssertFalse(mainPath.contains(".fill(Color.white.opacity"))
        XCTAssertTrue(
            mainPath.contains(
                ".glassEffect(.regular.interactive(glassIsInteractive), in: shellShape)"
            )
        )
        XCTAssertEqual(mainPath.components(separatedBy: ".glassEffect(").count - 1, 1)
        // 主路徑不准再出現任何一層手工仿製底板／濾鏡／描邊。
        XCTAssertFalse(mainPath.contains("NSVisualEffectView"))
        XCTAssertFalse(mainPath.contains("TatwoIslandNativeGlass"))
        XCTAssertFalse(mainPath.contains("LiquidGlassPanelMaterial"))
        XCTAssertFalse(mainPath.contains(".stroke("))
        XCTAssertFalse(mainPath.contains("Color.black.opacity"))
        XCTAssertFalse(mainPath.contains(".tint("))
        XCTAssertFalse(mainPath.contains(".blendMode("))
    }

    func testIslandDropsHandRolledRimAndWallpaperSampling() throws {
        let source = try Self.islandSource()

        // 手工 rim、桌布取樣與它的 observer 全部移除：系統玻璃自己處理
        // 邊緣能量與明暗自適應，再疊一套就是第二塊假玻璃。
        XCTAssertFalse(source.contains("TatwoIslandZoneHighlights"))
        XCTAssertFalse(source.contains("TatwoIslandAmbientPalette"))
        XCTAssertFalse(source.contains("TatwoIslandAmbientLight"))
        XCTAssertFalse(source.contains("desktopImageURL"))
        XCTAssertFalse(source.contains("addObserver"))
        XCTAssertFalse(source.contains(".hudWindow"))
        XCTAssertFalse(source.contains("NSAppearance(named: .vibrantDark)"))
    }

    func testSystemGlassIsNotClippedIntoASecondBottomPlate() throws {
        let source = try Self.islandSource()
        let start = try XCTUnwrap(
            source.range(of: "TatwoIslandBaseplate("))
        let end = try XCTUnwrap(
            source.range(
                of: "// 系統玻璃的 hover 能量有自己的退場時間。",
                range: start.upperBound..<source.endIndex))
        let baseplateUse = String(source[start.lowerBound..<end.lowerBound])

        // 底板一旦被 clipShape 裁掉，系統外投影會被切成沿底邊的白帶。
        XCTAssertFalse(baseplateUse.contains(".clipShape("))
    }

    func testBlackNotchRendersBehindSystemGlassSoTheMaterialBlursIt() throws {
        let source = try Self.islandSource()
        let surfaceStart = try XCTUnwrap(
            source.range(of: "struct TatwoIslandShellSurface:")
        )
        let surfaceEnd = try XCTUnwrap(
            source.range(
                of: "struct TatwoIslandShellShape:",
                range: surfaceStart.upperBound..<source.endIndex))
        let surface = String(source[surfaceStart.lowerBound..<surfaceEnd.lowerBound])
        let blackPaint = try XCTUnwrap(surface.range(of: "TatwoIslandNotchBlackPaint("))
        let systemGlass = try XCTUnwrap(surface.range(of: "TatwoIslandBaseplate("))
        let recoveryPaint = try XCTUnwrap(
            surface.range(
                of: "TatwoIslandNotchBlackPaint(",
                range: systemGlass.upperBound..<surface.endIndex
            )
        )

        XCTAssertLessThan(
            blackPaint.lowerBound,
            systemGlass.lowerBound,
            "The black notch must be composited below the system glass so it is seen through the glass material, not painted crisply on top."
        )
        XCTAssertGreaterThan(
            recoveryPaint.lowerBound,
            systemGlass.lowerBound,
            "The collapse-only recovery pass must sit above the glass so the system highlight cannot outlive the geometry animation."
        )
    }

    func testCollapsedIslandDisablesInteractiveGlassBeforeTheCollapseAnimationFinishes() throws {
        let source = try Self.islandSource()

        XCTAssertTrue(
            source.contains("glassIsInteractive: state.isExpanded"),
            "The target expansion state must disable interactive glass as soon as collapse begins."
        )
        XCTAssertTrue(
            source.contains(".glassEffect(.regular.interactive(glassIsInteractive), in: shellShape)"),
            "The system glass must retain its material while dropping the pointer-driven highlight during collapse."
        )
        XCTAssertTrue(
            source.contains("let collapsedRecoveryOpacity = 1 - min(max(progress, 0), 1)"),
            "The normal black notch must recover on the same progress clock as the collapse geometry."
        )
        XCTAssertTrue(
            source.contains(".opacity(collapsedRecoveryOpacity)"),
            "A foreground recovery pass must mask the system glass highlight tail during collapse."
        )
    }

    func testNotchBlurStaysMaskedInsideTheNotch() throws {
        let source = try Self.islandSource()
        let notchStart = try XCTUnwrap(source.range(of: Self.notchMarker))
        let notch = String(source[notchStart.upperBound...])
        let blur = try XCTUnwrap(notch.range(of: ".blur(radius: 4.5 * progress)"))
        let mask = try XCTUnwrap(
            notch.range(of: ".mask {", range: blur.upperBound..<notch.endIndex))

        XCTAssertTrue(notch.contains(".compositingGroup()"))
        XCTAssertLessThan(blur.upperBound, mask.lowerBound)
    }

    func testLegacyFallbackChainIsFullyRemoved() throws {
        let source = try Self.islandSource()

        // 2026-08-19 減碼：舊系統手工玻璃鏈整段移除，島檔不准再殘留
        // WebGL 材質、behind-window 取景或手工 mask 的任何痕跡。
        XCTAssertFalse(source.contains("TatwoIslandLegacyGlass"))
        XCTAssertFalse(source.contains("TatwoIslandNativeGlass"))
        XCTAssertFalse(source.contains("TatwoIslandMaskedEffectView"))
        XCTAssertFalse(source.contains("LiquidGlassPanelMaterial("))
        XCTAssertFalse(source.contains("islandTuned"))
        XCTAssertFalse(source.contains("NSVisualEffectView"))
        XCTAssertFalse(source.contains("underWindowBackground"))
        XCTAssertFalse(source.contains("maskImage"))
    }

    func testDashboardTruthOpticsPreservedForAuroraRework() {
        // island 研究出的 Dashboard 玻璃1 真值保留給 Aurora 重做，不得漂移。
        let optics = LiquidGlassPanelOptics.islandTuned
        XCTAssertEqual(optics.alpha, 0.18)
        XCTAssertEqual(optics.saturation, 1.0)
        XCTAssertEqual(optics.distortion, 1.3)
        XCTAssertEqual(optics.blur, 2.2)
        XCTAssertEqual(optics.chromaticAberration, 1.5)
    }

    func testCollapseRecoveryPassIsSkippedWhenFullyExpanded() throws {
        let source = try Self.islandSource()

        // 展開穩態補償層不掛進渲染樹：條件渲染省一層 compositing。
        XCTAssertTrue(source.contains("if collapsedRecoveryOpacity > 0 {"))
    }

    func testFixedOverlayStaysCenteredAndTopAnchored() {
        let screenFrame = NSRect(x: 120, y: 80, width: 1_440, height: 900)
        let overlay = TatwoIslandShellMetrics.overlayFrame(in: screenFrame)
        let collapsed = TatwoIslandShellMetrics.geometry(progress: 0, within: overlay.size)
        let expanded = TatwoIslandShellMetrics.geometry(progress: 1, within: overlay.size)

        XCTAssertEqual(TatwoIslandShellMetrics.collapsedSize, NSSize(width: 240, height: 33))
        XCTAssertEqual(TatwoIslandShellMetrics.expandedSize, NSSize(width: 648, height: 172))
        XCTAssertEqual(overlay.size, TatwoIslandShellMetrics.expandedOverlaySize)
        XCTAssertEqual(collapsed.bodySize, TatwoIslandShellMetrics.collapsedSize)
        XCTAssertEqual(expanded.bodySize, TatwoIslandShellMetrics.expandedSize)
        XCTAssertEqual(overlay.midX, screenFrame.midX)
        XCTAssertEqual(overlay.maxY, screenFrame.maxY)
        XCTAssertEqual(TatwoIslandShellMetrics.collapseDelay, 0.06)
        XCTAssertEqual(collapsed.topReverseCornerRadius, 10)
        XCTAssertEqual(expanded.topReverseCornerRadius, 22)
    }

    func testFixedOverlayRemainsWithinSmallScreenFrame() {
        let screenFrame = NSRect(x: 0, y: 0, width: 220, height: 130)
        let overlay = TatwoIslandShellMetrics.overlayFrame(in: screenFrame)
        let collapsed = TatwoIslandShellMetrics.geometry(progress: 0, within: overlay.size)

        XCTAssertGreaterThanOrEqual(overlay.minX, screenFrame.minX)
        XCTAssertLessThanOrEqual(overlay.maxX, screenFrame.maxX)
        XCTAssertGreaterThanOrEqual(overlay.minY, screenFrame.minY)
        XCTAssertEqual(overlay.maxY, screenFrame.maxY)
        XCTAssertEqual(collapsed.bodySize, NSSize(width: 220, height: 33))
    }

    func testShellPathUsesReverseTopCornersAndContinuousBottomCorners() {
        let shape = TatwoIslandShellShape(
            topReverseCornerRadius: 14,
            bottomCornerRadius: 23
        )
        let path = shape.path(in: NSRect(x: 0, y: 0, width: 676, height: 172))

        XCTAssertTrue(path.contains(CGPoint(x: 7, y: 1)))
        XCTAssertFalse(path.contains(CGPoint(x: 7, y: 13)))
        XCTAssertTrue(path.contains(CGPoint(x: 15, y: 14)))
        XCTAssertFalse(path.contains(CGPoint(x: 15, y: 171)))
        XCTAssertTrue(path.contains(CGPoint(x: 37, y: 171)))
    }

    @MainActor
    func testSingleProgressDrivesFrameAndBothCornerRadii() {
        let geometry = TatwoIslandShellMetrics.geometry(
            progress: 0.5,
            within: TatwoIslandShellMetrics.expandedOverlaySize
        )

        XCTAssertEqual(geometry.bodySize, NSSize(width: 444, height: 102.5))
        XCTAssertEqual(geometry.topReverseCornerRadius, 16)
        XCTAssertEqual(geometry.bottomCornerRadius, 22.5)
        XCTAssertEqual(geometry.shellSize, NSSize(width: 476, height: 102.5))

        var surface = TatwoIslandShellSurface(
            progress: 0,
            overlaySize: TatwoIslandShellMetrics.expandedOverlaySize,
            onHover: { _ in }
        )
        surface.animatableData = 0.5

        XCTAssertEqual(surface.progress, 0.5)
    }

    @MainActor
    func testPointerExitWaitsBeforeCollapsing() async {
        let state = TatwoIslandShellState(collapseDelay: 0.01)

        state.setPointerInside(true)
        state.setPointerInside(false)

        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 1)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 0)
    }

    @MainActor
    func testPointerReturnWithinGracePeriodCancelsCollapse() async {
        let state = TatwoIslandShellState(collapseDelay: 0.01)

        state.setPointerInside(true)
        state.setPointerInside(false)
        state.setPointerInside(true)

        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(state.isExpanded)
    }

    @MainActor
    func testPanelStaysNonActivating() {
        _ = NSApplication.shared
        let state = TatwoIslandShellState()
        let panel = TatwoIslandShellPanel(
            contentRect: .zero,
            viewController: NSHostingController(rootView: TatwoIslandShellView(state: state))
        )

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, TatwoIslandShellMetrics.windowLevel)
        XCTAssertTrue(panel.collectionBehavior.contains(NSWindow.CollectionBehavior.canJoinAllSpaces))
    }

    private static func section(from start: String, to end: String) throws -> String {
        let source = try islandSource()
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }

    private static func islandSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("TatwoUltraworkMac")
                .appendingPathComponent("TatwoIslandShell.swift"),
            encoding: .utf8
        )
    }
}
