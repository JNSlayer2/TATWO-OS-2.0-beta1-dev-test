import XCTest
@testable import TatwoUltraworkMac

final class ChatRightPanelLayoutPolicyTests: XCTestCase {
    // 資訊卡改懸浮後，右側面板互動只剩 browser / file（見 ChatRightPanelInteractionPolicy）。
    func testBrowserButtonOpensPanelFromNone() {
        let result = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .none,
            isPanelOpen: false,
            action: .toggleBrowser
        )

        XCTAssertEqual(result.content, .browser)
        XCTAssertEqual(result.preference, true)
    }

    func testClosedBrowserButtonReopensPanel() {
        let result = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .browser,
            isPanelOpen: false,
            action: .toggleBrowser
        )

        XCTAssertEqual(result.content, .browser)
        XCTAssertEqual(result.preference, true)
    }

    func testActiveBrowserButtonClosesPanelWithoutLosingCategory() {
        let result = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .browser,
            isPanelOpen: true,
            action: .toggleBrowser
        )

        XCTAssertEqual(result.content, .browser)
        XCTAssertEqual(result.preference, false)
    }

    func testFileButtonSwitchesBrowserCategoryWithoutClosingPanel() {
        let result = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .browser,
            isPanelOpen: true,
            action: .toggleFile
        )

        XCTAssertEqual(result.content, .file)
        XCTAssertEqual(result.preference, true)
    }

    func testActiveFileButtonClosesPanelWithoutLosingCategory() {
        let result = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .file,
            isPanelOpen: true,
            action: .toggleFile
        )

        XCTAssertEqual(result.content, .file)
        XCTAssertEqual(result.preference, false)
    }

    func testLoopsButtonUsesSameOpenCloseContractAsOtherHeavyPanels() {
        let opened = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .file,
            isPanelOpen: true,
            action: .toggleLoops
        )
        let closed = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .loops,
            isPanelOpen: true,
            action: .toggleLoops
        )

        XCTAssertEqual(opened.content, .loops)
        XCTAssertEqual(opened.preference, true)
        XCTAssertEqual(closed.content, .loops)
        XCTAssertEqual(closed.preference, false)
    }

    func testDiffButtonUsesSameOpenCloseContractAsOtherHeavyPanels() {
        let opened = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .none,
            isPanelOpen: false,
            action: .toggleDiff
        )
        let closed = ChatRightPanelInteractionPolicy.reduce(
            currentContent: .diff,
            isPanelOpen: true,
            action: .toggleDiff
        )

        XCTAssertEqual(opened.content, .diff)
        XCTAssertEqual(opened.preference, true)
        XCTAssertEqual(closed.content, .diff)
        XCTAssertEqual(closed.preference, false)
    }

    func testAutomaticPreferenceClosesBelowWideWindowThreshold() {
        let layout = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1220,
            preference: nil
        )

        XCTAssertEqual(layout.presentation, .closed)
        XCTAssertTrue(layout.showsMainContent)
        XCTAssertEqual(layout.panelWidth, 0)
    }

    func testAutomaticPreferenceOpensAtWideWindowThreshold() {
        let layout = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1600,
            preference: nil
        )

        XCTAssertEqual(layout.presentation, .docked)
        XCTAssertTrue(layout.showsMainContent)
        XCTAssertEqual(layout.panelWidth, 320)
        XCTAssertGreaterThanOrEqual(layout.mainContentWidth, 352)
    }

    func testExplicitOpenDocksAt1220WithoutOverlappingMainContent() {
        let layout = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1220,
            preference: true
        )

        XCTAssertEqual(layout.presentation, .docked)
        XCTAssertEqual(layout.panelWidth, 320)
        XCTAssertEqual(layout.mainContentWidth, 888)
        XCTAssertLessThanOrEqual(
            layout.mainContentWidth + layout.spacing + layout.panelWidth,
            1220
        )
    }

    func testLoopsUseContentAwareWidthWithoutExpandingBrowserOrFilePanels() {
        let standard = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1220,
            preference: true,
            widthClass: .standard
        )
        let loops = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1220,
            preference: true,
            widthClass: .loops
        )

        XCTAssertEqual(standard.presentation, .docked)
        XCTAssertEqual(standard.panelWidth, 320)
        XCTAssertEqual(standard.mainContentWidth, 888)
        XCTAssertEqual(loops.presentation, .docked)
        XCTAssertEqual(loops.panelWidth, 560)
        XCTAssertEqual(loops.mainContentWidth, 648)
    }

    func testLoopsExpandOnWideWindowsButKeepAReadableChatCanvas() {
        let loops = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1600,
            preference: true,
            widthClass: .loops
        )

        XCTAssertEqual(loops.presentation, .docked)
        XCTAssertEqual(loops.panelWidth, 704)
        XCTAssertEqual(loops.mainContentWidth, 884)
        XCTAssertGreaterThanOrEqual(
            loops.mainContentWidth,
            ChatRightPanelLayoutPolicy.loopsMinimumMainContentWidth)
    }

    func testLoopsCanExplicitlyTakeOverTheWholeWorkspace() {
        let loops = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1600,
            preference: true,
            widthClass: .loops,
            forceFocus: true
        )

        XCTAssertEqual(loops.presentation, .focusedTakeover)
        XCTAssertEqual(loops.panelWidth, 1600)
        XCTAssertEqual(loops.mainContentWidth, 0)
        XCTAssertFalse(loops.showsMainContent)
    }

    func testLoopsTakeOverBeforeChatWouldShrinkBelowReadableWidth() {
        let loops = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1060,
            preference: true,
            widthClass: .loops
        )

        XCTAssertEqual(loops.presentation, .compactTakeover)
        XCTAssertEqual(loops.mainContentWidth, 0)
    }

    func testLoopsTakeOverWhenPreferredWidthWouldCrushMainContent() {
        let standard = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 800,
            preference: true,
            widthClass: .standard
        )
        let loops = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 800,
            preference: true,
            widthClass: .loops
        )

        XCTAssertEqual(standard.presentation, .docked)
        XCTAssertEqual(loops.presentation, .compactTakeover)
        XCTAssertFalse(loops.showsMainContent)
        XCTAssertEqual(loops.panelWidth, 800)
        XCTAssertEqual(loops.mainContentWidth, 0)
    }

    func testExplicitOpenAt480UsesPaneTakeoverInsteadOfOverlay() {
        let layout = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 480,
            preference: true
        )

        XCTAssertEqual(layout.presentation, .compactTakeover)
        XCTAssertFalse(layout.showsMainContent)
        XCTAssertEqual(layout.panelWidth, 480)
        XCTAssertEqual(layout.mainContentWidth, 0)
    }

    func testExplicitCloseOverridesWideAutomaticDefault() {
        let layout = ChatRightPanelLayoutPolicy.resolve(
            layoutWidth: 1600,
            preference: false
        )

        XCTAssertEqual(layout.presentation, .closed)
        XCTAssertTrue(layout.showsMainContent)
        XCTAssertEqual(layout.panelWidth, 0)
        XCTAssertEqual(layout.mainContentWidth, 1600)
    }

    func testCompactTakeoverSourceKeepsAVisibleReturnToChatControl() throws {
        let source = try ChatSourceFamily.read("ChatPage.swift")

        XCTAssertTrue(
            source.contains(
                "|| rightPanelLayout.presentation == .focusedTakeover"))
        XCTAssertTrue(source.contains(#"isFocusedWorkspace ? "回到並排" : "返回 Chat""#))
        XCTAssertTrue(
            source.contains(
                #": "關閉側邊工作區並返回 Chat""#))
    }
}
