import AppKit
import XCTest
@testable import TatwoUltraworkMac

final class WindowChromeMetricsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    func testChromeMetricsMatchCodexHiddenInsetContract() {
        // 2026-07-11：頂部 gap 修（#27）將 band 46→34；仍 ≥ 交通燈 topInset16+diameter14=30，契約成立。
        XCTAssertEqual(WindowChromeMetrics.bandHeight, 34)
        XCTAssertEqual(WindowChromeMetrics.windowCornerRadius, 12)
        XCTAssertEqual(WindowChromeMetrics.trafficLightLeadingInset, 16)
        XCTAssertEqual(WindowChromeMetrics.trafficLightTopInset, 16)
        XCTAssertEqual(WindowChromeMetrics.nativeTrafficLightDiameter, 14)
        XCTAssertEqual(WindowChromeMetrics.controlSpacing, 8)
    }

    func testWindowChromeSourceSealsTransparentWindowCorners() throws {
        let chrome = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/WindowChrome.swift")
        let appShell = try source(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift")

        XCTAssertTrue(chrome.contains("backgroundColor = .clear"))
        XCTAssertTrue(chrome.contains("isOpaque = false"))
        XCTAssertTrue(chrome.contains(
            "contentView.layer?.cornerRadius = WindowChromeMetrics.windowCornerRadius"))
        XCTAssertTrue(chrome.contains("contentView.layer?.cornerCurve = .continuous"))
        XCTAssertTrue(chrome.contains("contentView.layer?.masksToBounds = true"))
        let hostingRoot = try XCTUnwrap(appShell.range(
            of: "window.contentViewController = hostingController"))
        // 2026-09-03：表面依主題二選一。玻璃主題走透明＋遮圓角；實底主題（fable5）走不透明視窗，
        // 圓角交給系統畫，避免透明視窗在取景／螢幕共享管線出現黑色方角。
        let cornerSeal = try XCTUnwrap(appShell.range(
            of: "window.applyTatwoWindowSurface()",
            range: hostingRoot.upperBound..<appShell.endIndex))
        XCTAssertLessThan(hostingRoot.lowerBound, cornerSeal.lowerBound)
        XCTAssertTrue(appShell.contains("TatwoThemeStore.shared.$activeThemeID"))
        XCTAssertTrue(chrome.contains("backgroundColor = NSColor(palette.canvasBase)"))
        XCTAssertTrue(chrome.contains("isOpaque = true"))
        XCTAssertTrue(chrome.contains("contentView.layer?.masksToBounds = false"))
    }

    func testHeaderControlsBeginAfterNativeTrafficLightSafeZone() {
        XCTAssertGreaterThanOrEqual(
            WindowChromeMetrics.appControlLeadingX,
            WindowChromeMetrics.trafficLightClusterMaxX + WindowChromeMetrics.headerHorizontalInset
        )
    }

    @MainActor
    func testWorkOSWindowUsesFullSizeTransparentChromeAndAlignedNativeButtons() throws {
        _ = NSApplication.shared
        let window = TatwoWorkOSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 980),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.configureTatwoChrome()
        window.layoutTatwoTrafficLights()

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.isMovableByWindowBackground)

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let closeFrame = try XCTUnwrap(close.superview?.convert(close.frame, to: nil))
        XCTAssertEqual(closeFrame.minX, WindowChromeMetrics.trafficLightLeadingInset, accuracy: 0.5)

        let topInset = window.frame.height - closeFrame.maxY
        XCTAssertEqual(topInset, WindowChromeMetrics.trafficLightTopInset, accuracy: 0.5)

        let trafficButtons = [
            try XCTUnwrap(window.standardWindowButton(.closeButton)),
            try XCTUnwrap(window.standardWindowButton(.miniaturizeButton)),
            try XCTUnwrap(window.standardWindowButton(.zoomButton)),
        ]
        for button in trafficButtons {
            let frame = try XCTUnwrap(button.superview?.convert(button.frame, to: nil))
            XCTAssertLessThanOrEqual(frame.maxX, WindowChromeMetrics.trafficLightSafeWidth)
        }

        let themeFrame = try XCTUnwrap(window.contentView?.superview)
        let closeCenterInThemeFrame = themeFrame.convert(
            NSPoint(x: closeFrame.midX, y: closeFrame.midY),
            from: nil
        )
        XCTAssertTrue(themeFrame.hitTest(closeCenterInThemeFrame) === close)
    }
}
