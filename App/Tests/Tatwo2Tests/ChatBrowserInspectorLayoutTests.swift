import XCTest
@testable import Tatwo2

final class ChatBrowserInspectorLayoutTests: XCTestCase {
    func testDockedBrowserAlwaysReservesSidebarAndChat() {
        for width in stride(from: CGFloat(480), through: 3000, by: 10) {
            let result = ChatBrowserInspectorLayout.resolve(windowWidth: width)
            if result.canDock {
                XCTAssertGreaterThanOrEqual(result.minimumWidth, 320)
                XCTAssertLessThanOrEqual(result.minimumWidth, result.idealWidth)
                XCTAssertLessThanOrEqual(result.idealWidth, result.maximumWidth)
                XCTAssertLessThanOrEqual(result.maximumWidth, 960)
                XCTAssertGreaterThanOrEqual(width - result.maximumWidth - ChatBrowserInspectorLayout.dividerWidth,
                    WorkspaceSidebarMetrics.width + WorkspaceSidebarMetrics.contentGap
                        + ChatRightPanelLayoutPolicy.minimumMainContentWidth)
            } else { XCTAssertEqual(result.maximumWidth, 0) }
        }
    }

    func testScreenshotSizedWindowCannotGiveBrowser640Points() {
        let result = ChatBrowserInspectorLayout.resolve(windowWidth: 1220)
        XCTAssertTrue(result.canDock)
        XCTAssertEqual(result.maximumWidth, 605)
        XCTAssertEqual(result.idealWidth, 488)
    }

    func testNarrowAndInvalidWidthsUseStackedPanel() {
        for width: CGFloat in [0, 480, 800, 934, -1, .nan, .infinity] {
            XCTAssertFalse(ChatBrowserInspectorLayout.resolve(windowWidth: width).canDock)
        }
        XCTAssertTrue(ChatBrowserInspectorLayout.resolve(windowWidth: 935).canDock)
    }
    func testCompactBrowserLeavesMostHeightForChat() {
        for height in stride(from: CGFloat(360), through: 1600, by: 40) {
            let panel = ChatBrowserInspectorLayout.compactPanelHeight(windowHeight: height)
            XCTAssertGreaterThan(panel, 0)
            XCTAssertLessThanOrEqual(panel, 420)
            XCTAssertGreaterThanOrEqual(height - panel, height * 0.57)
        }
        for height: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertEqual(ChatBrowserInspectorLayout.compactPanelHeight(windowHeight: height), 0)
        }
    }
    func testDragClampsToBothEdgesAndRestoresPreferredWidth() {
        let layout = ChatBrowserInspectorLayout.resolve(windowWidth: 1220)
        XCTAssertEqual(layout.clampedWidth(0), 488)
        XCTAssertEqual(layout.clampedWidth(.nan), 488)
        XCTAssertEqual(layout.clampedWidth(100), 320)
        XCTAssertEqual(layout.clampedWidth(550), 550)
        XCTAssertEqual(layout.clampedWidth(900), 605)
        XCTAssertEqual(ChatBrowserInspectorLayout.resolve(windowWidth: 700).clampedWidth(550), 0)
    }

}
