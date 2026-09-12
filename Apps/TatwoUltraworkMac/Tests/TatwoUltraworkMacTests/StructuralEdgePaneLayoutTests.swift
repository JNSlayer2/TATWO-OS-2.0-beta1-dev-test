import Foundation
import XCTest

final class StructuralEdgePaneLayoutTests: XCTestCase {
    func testChatAndCLISidebarsAreFullHeightEdgePanes() throws {
        let source = try appSource("ChatPage.swift")

        XCTAssertFalse(
            source.contains("LiquidGlassPanelCard(cornerRadius: 16)"),
            "Chat/CLI structural sidebars must not render as rounded floating cards")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "LiquidGlassPanelCard(cornerRadius: 0)")
                .count - 1,
            2,
            "Chat and CLI sidebars must use square edge surfaces")
        XCTAssertGreaterThanOrEqual(
            source.components(
                separatedBy:
                    ".ignoresSafeArea(.container, edges: [.top, .bottom])")
                .count - 1,
            2,
            "Chat and CLI sidebars must extend through the titlebar and window bottom")
    }

    func testBotSidebarIsAFullHeightEdgePane() throws {
        let source = try appSource("BotPage.swift")

        XCTAssertFalse(
            source.contains("LiquidGlassPanelCard(cornerRadius: 16)"),
            "Bot structural sidebar must not render as a rounded floating card")
        XCTAssertTrue(source.contains("LiquidGlassPanelCard(cornerRadius: 0)"))
        XCTAssertTrue(
            source.contains(
                ".ignoresSafeArea(.container, edges: [.top, .bottom])"))
    }

    func testLoopsWorkspaceIsAFullHeightEdgePane() throws {
        let source = try appSource("LoopsSessionRail.swift")

        XCTAssertFalse(
            source.contains(
                ".liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)"),
            "Loops workspace root must not render as a rounded floating card")
        XCTAssertTrue(source.contains(".liquidGlassSurface(cornerRadius: 0)"))
        XCTAssertTrue(
            source.contains(
                ".ignoresSafeArea(.container, edges: [.top, .bottom])"))
    }

    func testRetainedChatDoesNotShortenStructuralPanes() throws {
        let appShell = try appSource("AppShell.swift")
        let chatPage = try appSource("ChatPage.swift")
        let retainedPage = try sourceSlice(
            appShell,
            from: "private func retainedWindowPage",
            through: "private func pageContent")

        XCTAssertFalse(
            retainedPage.contains(".padding(.bottom, 18)"),
            "The retained Chat page must remain full-height")
        XCTAssertFalse(
            chatPage.contains(".padding(.bottom, -18)"),
            "Structural panes must not rely on brittle negative-padding compensation")
        XCTAssertTrue(
            chatPage.contains(
                "composer(contentMaxWidth: contentMaxWidth, forceCompactToolbar: forceCompactToolbar)\n"
                    + "                    .frame(maxWidth: contentMaxWidth ?? composerMaxWidth)\n"
                    + "                    .frame(maxWidth: .infinity, alignment: .center)\n"
                    + "                    .padding(.bottom, 18)"),
            "Chat content should retain its 18pt composer gutter after the global inset is removed")
    }

    private func appSource(_ filename: String) throws -> String {
        try ChatSourceFamily.read(url: appSourceFileURL(filename))
    }

    private func appSourceFileURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TatwoUltraworkMac")
            .appendingPathComponent(filename)
    }

    private func sourceSlice(
        _ source: String,
        from startMarker: String,
        through endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
