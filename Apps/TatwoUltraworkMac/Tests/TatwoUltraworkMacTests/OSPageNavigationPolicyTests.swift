import XCTest
@testable import TatwoUltraworkMac

final class OSPageNavigationPolicyTests: XCTestCase {
    func testMenuBarPanelExposesExactlyTheSevenOSPagesInProductOrder() {
        // 2026-08-20 使用者裁決：模式/情境/特質三分頁收成一頁（配置總覽），
        // scenarios/compatibility 退出導覽但 enum case 保留供深連結。
        XCTAssertEqual(
            TatwoPageNavigationPolicy.menuBarOSPages,
            [.usage, .modes, .plugins, .devices, .workflow]
        )
        XCTAssertNotNil(TatwoPage(rawValue: "scenarios"))
        XCTAssertNotNil(TatwoPage(rawValue: "compatibility"))
    }

    func testChatWindowChromeContainsNoPageNavigation() {
        // Wave1: chatWindowPages constant removed; chat remains outside menuBarOSPages.
        XCTAssertFalse(TatwoPageNavigationPolicy.menuBarOSPages.contains(.chat))
        XCTAssertNil(TatwoPage(rawValue: "working"), "Wave1 removed dead TatwoPage.working")
    }

    func testStatusPanelRejectsChatAsOSPageDestination() {
        XCTAssertTrue(TatwoPageNavigationPolicy.canOpenInStatusPanel(.usage))
        XCTAssertTrue(TatwoPageNavigationPolicy.canOpenInStatusPanel(.devices))
        XCTAssertTrue(TatwoPageNavigationPolicy.canOpenInStatusPanel(.workflow))
        XCTAssertFalse(TatwoPageNavigationPolicy.canOpenInStatusPanel(.chat))
    }
}
