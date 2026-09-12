import AppKit
import XCTest
import TatwoUltraworkCore

@testable import TatwoUltraworkMac

final class EmbeddedBrowserUIContractTests: XCTestCase {
    func testStartPageSubmissionNormalizesSearchURLAndEmptyInput() {
        XCTAssertEqual(
            EmbeddedBrowserStartPageSubmission.navigationURL(
                for: "tatwo browser")?.absoluteString,
            "https://www.google.com/search?q=tatwo%20browser")
        XCTAssertEqual(
            EmbeddedBrowserStartPageSubmission.navigationURL(
                for: "https://example.com/docs")?.absoluteString,
            "https://example.com/docs")
        XCTAssertNil(
            EmbeddedBrowserStartPageSubmission.navigationURL(
                for: "   \n"))
    }

    func testBrowserPanelWidthClampsToComfortableMinimumAndSeventyTwoPercent() {
        XCTAssertEqual(
            BrowserPanelWidthPolicy.clamp(120, windowWidth: 1_000),
            420)
        XCTAssertEqual(
            BrowserPanelWidthPolicy.clamp(520, windowWidth: 1_000),
            520)
        XCTAssertEqual(
            BrowserPanelWidthPolicy.clamp(900, windowWidth: 1_000),
            720)
    }

    func testBrowserPanelDefaultWidthUsesFortyTwoPercentWithFourEightyFloor() {
        XCTAssertEqual(
            BrowserPanelWidthPolicy.defaultWidth(windowWidth: 1_000),
            480)
        XCTAssertEqual(
            BrowserPanelWidthPolicy.defaultWidth(windowWidth: 1_600),
            672)
        XCTAssertEqual(
            BrowserPanelWidthPolicy.defaultWidth(windowWidth: 500),
            420)
    }

    func testBrowserPanelRestoresRememberedWidthAndMigratesLegacyMinimum() {
        XCTAssertEqual(
            BrowserPanelWidthPolicy.restoredWidth(
                persistedWidth: 560,
                windowWidth: 1_000),
            560)
        XCTAssertEqual(
            BrowserPanelWidthPolicy.restoredWidth(
                persistedWidth: 320,
                windowWidth: 1_000),
            480)
        XCTAssertEqual(
            BrowserPanelWidthPolicy.restoredWidth(
                persistedWidth: 900,
                windowWidth: 1_000),
            720)
        XCTAssertTrue(
            BrowserPanelWidthPolicy.needsLegacyWidthMigration(320))
        XCTAssertFalse(
            BrowserPanelWidthPolicy.needsLegacyWidthMigration(560))
    }

    func testBrowserOverlayWidthDoesNotReflowChatLayout() {
        let initial = BrowserPanelOverlayLayoutPolicy.resolve(
            layoutWidth: 1_000,
            requestedWidth: 420,
            isOpen: true)
        let widened = BrowserPanelOverlayLayoutPolicy.resolve(
            layoutWidth: 1_000,
            requestedWidth: 610,
            isOpen: true)

        XCTAssertEqual(initial.chatContentWidth, 1_000)
        XCTAssertEqual(widened.chatContentWidth, 1_000)
        XCTAssertEqual(initial.panelWidth, 420)
        XCTAssertEqual(widened.panelWidth, 610)
        XCTAssertTrue(initial.isOpen)
        XCTAssertTrue(widened.isOpen)
    }

    func testBrowserOverlayHandleIsAtPanelBottomLeadingCorner() {
        let layout = BrowserPanelOverlayLayoutPolicy.resolve(
            layoutWidth: 1_000,
            requestedWidth: 420,
            isOpen: true)

        XCTAssertEqual(layout.handlePlacement, .bottomLeading)
        XCTAssertEqual(BrowserPanelOverlayLayoutPolicy.handleSize, 24)
        XCTAssertEqual(
            BrowserPanelOverlayLayoutPolicy.handleOffset.width,
            -BrowserPanelOverlayLayoutPolicy.handleSize / 2)
        XCTAssertLessThan(
            BrowserPanelOverlayLayoutPolicy.handleOffset.height,
            0)
        XCTAssertEqual(
            BrowserPanelOverlayLayoutPolicy.windowTopExtension,
            24)
        XCTAssertLessThan(
            BrowserPanelOverlayLayoutPolicy.windowTopExtension,
            WindowChromeMetrics.bandHeight)
    }

    func testBrowserDragPreviewUsesGestureTranslationAndClamps() {
        XCTAssertEqual(
            BrowserPanelDragPolicy.previewWidth(
                persistedWidth: 480,
                translation: -80,
                windowWidth: 1_000),
            560)
        XCTAssertEqual(
            BrowserPanelDragPolicy.previewWidth(
                persistedWidth: 480,
                translation: 800,
                windowWidth: 1_000),
            420)
        XCTAssertEqual(
            BrowserPanelDragPolicy.previewWidth(
                persistedWidth: 480,
                translation: -800,
                windowWidth: 1_000),
            720)
        XCTAssertEqual(
            BrowserPanelDragPolicy.previewWidth(
                persistedWidth: 320,
                translation: -20,
                windowWidth: 1_000),
            500)
    }

    func testCEFGeometryThrottleCoalescesToOneSixtiethSecondAndFinalSyncIsImmediate() {
        XCTAssertEqual(
            TatwoCEFGeometrySyncThrottlePolicy.minimumInterval,
            1.0 / 60.0,
            accuracy: 0.000_001)
        XCTAssertEqual(
            TatwoCEFGeometrySyncThrottlePolicy.delay(
                lastSyncUptime: 10,
                now: 10.002),
            (1.0 / 60.0) - 0.002,
            accuracy: 0.000_001)
        XCTAssertEqual(
            TatwoCEFGeometrySyncThrottlePolicy.delay(
                lastSyncUptime: 10,
                now: 10.1),
            0)
    }

    func testCEFGeometryDragUsesLiveThrottledSyncAndImmediateFinalSync()
        throws
    {
        let source = try chromiumCEFBackendSource()
        let start = try XCTUnwrap(
            source.range(of: "private final class TatwoCEFContainerView"))
        let end = try XCTUnwrap(
            source.range(
                of: "struct EmbeddedChromiumBrowserMountIdentity",
                range: start.upperBound..<source.endIndex))
        let container = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(container.contains(
            "if isGeometryDragInProgress {\n"
                + "            scheduleThrottledGeometrySync()"))
        XCTAssertTrue(container.contains(
            "private func scheduleThrottledGeometrySync()"))
        XCTAssertTrue(container.contains(
            "guard geometrySyncWorkItem == nil"))
        XCTAssertTrue(container.contains(
            "phase: \"container_drag_frame\""))
        XCTAssertTrue(container.contains(
            "phase: \"container_drag_final\""))
        XCTAssertTrue(container.contains(
            "lastGeometrySyncUptime =\n"
                + "            ProcessInfo.processInfo.systemUptime"))
        XCTAssertFalse(container.contains(
            "leave the CEF child\n            // frozen"))
    }

    func testCEFResizeGapUsesOpaquePanelSeparateFromWebDocumentCanvas()
        throws
    {
        let source = try cefBridgeSource()
        XCTAssertTrue(source.contains(
            "NSColor *TatwoCEFOpaquePanelBackgroundNSColor()"))
        XCTAssertTrue(source.contains(
            "self.layer.backgroundColor =\n"
                + "      TatwoCEFOpaquePanelBackgroundNSColor().CGColor;"))
        XCTAssertTrue(source.contains(
            "std::min<CGFloat>(red, 0.92)"))
        XCTAssertTrue(source.contains(
            "std::min<CGFloat>(blue, 0.92)\n"
                + "                            alpha:1]"))
        XCTAssertTrue(source.contains(
            "constexpr uint32_t kBrowserDocumentBackgroundColor = 0xFFFFFFFF;"))
        XCTAssertTrue(source.contains(
            "browser_settings.background_color = kBrowserDocumentBackgroundColor;"))
        XCTAssertTrue(source.contains(
            "settings.background_color = kBrowserDocumentBackgroundColor;"))
    }

    func testFixtureModeNeverPerformsRealAction() {
        var dispatchCount = 0
        XCTAssertTrue(
            EmbeddedBrowserUIFixturePolicy.isEnabled(
                environment: ["TATWO_BROWSER_UI_FIXTURE": "1"]))
        XCTAssertFalse(
            EmbeddedBrowserUIFixturePolicy.performRealAction(
                isFixture: true
            ) {
                dispatchCount += 1
            })
        XCTAssertEqual(dispatchCount, 0)

        XCTAssertTrue(
            EmbeddedBrowserUIFixturePolicy.performRealAction(
                isFixture: false
            ) {
                dispatchCount += 1
            })
        XCTAssertEqual(dispatchCount, 1)
    }

    func testFixtureProvidesThreeProfileScopedBookmarks() {
        let profileKey = UUID()
        let bookmarks =
            EmbeddedBrowserUIFixturePolicy.bookmarks(
                profileKey: profileKey)

        XCTAssertEqual(bookmarks.count, 3)
        XCTAssertTrue(bookmarks.allSatisfy {
            $0.profileKey == profileKey
        })
        XCTAssertEqual(
            Set(bookmarks.map(\.displayTitle)),
            Set(["Apple Developer", "ChatGPT", "Google"]))
    }

    func testBookmarkRailSitsOutsideSearchCardAndClampsToItsWidth() {
        XCTAssertGreaterThanOrEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth,
            28)
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.width(
                isExpanded: false,
                bookmarkCount: 20,
                cardContentWidth: 160),
            30)
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.width(
                isExpanded: true,
                bookmarkCount: 3,
                cardContentWidth: 620),
            174)
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.width(
                isExpanded: true,
                bookmarkCount: 30,
                cardContentWidth: 220),
            220)

        let cardFrame = CGRect(x: 24, y: 80, width: 220, height: 96)
        let railFrame =
            EmbeddedBrowserBookmarkRailLayoutPolicy.visibleRailFrame(
                searchCardFrame: cardFrame,
                isExpanded: true,
                bookmarkCount: 30)

        XCTAssertEqual(railFrame.minX, cardFrame.minX)
        XCTAssertEqual(
            railFrame.minY,
            cardFrame.maxY
                + EmbeddedBrowserBookmarkRailLayoutPolicy.railTopSpacing)
        XCTAssertGreaterThanOrEqual(railFrame.minY, cardFrame.maxY)
        XCTAssertLessThanOrEqual(railFrame.width, cardFrame.width)
    }

    func testBookmarkAnchorUsesCompactNeutralVisualInsideStableHitArea() {
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorVisualSize,
            18)
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorSymbolSize,
            11)
        XCTAssertLessThan(
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorVisualSize,
            EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth)
    }

    func testBookmarkHoverRegionCoversIconThroughLastBubble() {
        let region =
            EmbeddedBrowserBookmarkRailHoverPolicy.hoverRegion(
                isExpanded: true,
                bookmarkCount: 3,
                cardContentWidth: 620)

        XCTAssertEqual(region.minX, 0)
        XCTAssertEqual(region.maxX, 174)
        XCTAssertEqual(region.minY, -10)
        XCTAssertEqual(region.maxY, 40)
        XCTAssertEqual(
            region.height,
            EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth + 20)
    }

    func testBookmarkClickToggleAndOutsideCollapseStateMachine() {
        var state = EmbeddedBrowserBookmarkRailInteractionState()

        state.toggleClick()
        XCTAssertTrue(state.isExpanded)
        XCTAssertTrue(state.isClickExpanded)

        state.pointerEntered()
        state.pointerExited()
        state.collapseIfAllowed(isContextMenuVisible: false)
        XCTAssertTrue(state.isExpanded)

        state.toggleClick()
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isClickExpanded)

        state.pointerEntered()
        XCTAssertTrue(state.isExpanded)
        state.collapseFromOutside()
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isClickExpanded)
    }

    func testBookmarkHoverExitUsesFourTenthsSecondDelayAndCollapseGate() {
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailHoverPolicy
                .collapseDelayMilliseconds,
            400)
        XCTAssertTrue(
            EmbeddedBrowserBookmarkRailHoverPolicy.shouldCollapse(
                isPointerInside: false,
                isPinnedOpen: false,
                isContextMenuVisible: false))
        XCTAssertFalse(
            EmbeddedBrowserBookmarkRailHoverPolicy.shouldCollapse(
                isPointerInside: true,
                isPinnedOpen: false,
                isContextMenuVisible: false))
        XCTAssertFalse(
            EmbeddedBrowserBookmarkRailHoverPolicy.shouldCollapse(
                isPointerInside: false,
                isPinnedOpen: true,
                isContextMenuVisible: false))
        XCTAssertFalse(
            EmbeddedBrowserBookmarkRailHoverPolicy.shouldCollapse(
                isPointerInside: false,
                isPinnedOpen: false,
                isContextMenuVisible: true))
    }

    func testCustomBookmarkRemovalKeepsLastUndoCandidate() {
        let profileKey = UUID()
        let bookmarks =
            EmbeddedBrowserUIFixturePolicy.bookmarks(
                profileKey: profileKey)
        var state = EmbeddedBrowserBookmarkUndoState(
            bookmarks: bookmarks)

        XCTAssertEqual(
            state.remove(id: bookmarks[1].id),
            bookmarks[1])
        XCTAssertEqual(state.bookmarks, [bookmarks[0], bookmarks[2]])
        XCTAssertEqual(state.lastRemoved, bookmarks[1])
        XCTAssertEqual(state.undo(), bookmarks[1])
        XCTAssertEqual(state.bookmarks, bookmarks)
        XCTAssertNil(state.lastRemoved)
        XCTAssertNil(state.undo())
    }

    func testToolbarContainsTabStripExtensionsAndGearControls() throws {
        let source = try embeddedBrowserSource()
        let start = try XCTUnwrap(
            source.range(
                of: "private var browserToolbar: some View"))
        let end = try XCTUnwrap(
            source.range(
                of: "private var browserTabStrip: some View",
                range: start.upperBound..<source.endIndex))
        let toolbar = String(
            source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(toolbar.contains("browserTabStrip"))
        XCTAssertTrue(toolbar.contains(
            "Image(systemName: \"puzzlepiece.extension\")"))
        XCTAssertTrue(toolbar.contains(
            "Image(systemName: \"gearshape\")"))
        XCTAssertTrue(toolbar.contains(
            "TatwoBrowserManagementView("))
        XCTAssertTrue(toolbar.contains("browserTrailingControls"))
        XCTAssertTrue(toolbar.contains(
            ".accessibilityIdentifier(\"browser-toolbar-trailing-controls\")"))
        let extensionButton = try XCTUnwrap(
            toolbar.range(
                of: "Image(systemName: \"puzzlepiece.extension\")"))
        let gearButton = try XCTUnwrap(
            toolbar.range(of: "Image(systemName: \"gearshape\")"))
        XCTAssertLessThan(
            toolbar.distance(
                from: toolbar.startIndex,
                to: extensionButton.lowerBound),
            toolbar.distance(
                from: toolbar.startIndex,
                to: gearButton.lowerBound))
        let tabStrip = try XCTUnwrap(
            toolbar.range(of: "browserTabStrip"))
        let spacer = try XCTUnwrap(
            toolbar.range(
                of: "Spacer(",
                range: tabStrip.upperBound..<toolbar.endIndex))
        let trailingControls = try XCTUnwrap(
            toolbar.range(
                of: "browserTrailingControls",
                range: spacer.upperBound..<toolbar.endIndex))
        XCTAssertLessThan(
            toolbar.distance(
                from: toolbar.startIndex,
                to: tabStrip.lowerBound),
            toolbar.distance(
                from: toolbar.startIndex,
                to: spacer.lowerBound))
        XCTAssertLessThan(
            toolbar.distance(
                from: toolbar.startIndex,
                to: spacer.lowerBound),
            toolbar.distance(
                from: toolbar.startIndex,
                to: trailingControls.lowerBound))
        XCTAssertEqual(
            EmbeddedBrowserToolbarLayoutPolicy.trailingControlSpacing,
            2)
        XCTAssertFalse(toolbar.contains("LiquidGlassTokens.brandAccent"))
        for forbidden in [
            "TextField(",
            "chevron.left",
            "chevron.right",
            "arrow.clockwise",
            "ellipsis",
            "browserEngine.rawValue",
            "highlighter",
            "browserMaintenanceMenu",
        ] {
            XCTAssertFalse(toolbar.contains(forbidden), forbidden)
        }
    }

    func testToolbarControlsAndTabsShareCenteredRowMetrics() {
        XCTAssertEqual(
            EmbeddedBrowserToolbarLayoutPolicy.rowHeight,
            36)
        XCTAssertGreaterThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.toolbarVerticalPadding,
            7)
        XCTAssertGreaterThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.tabSpacing,
            8)
        XCTAssertGreaterThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.tabTitleCloseSpacing,
            8)
        XCTAssertGreaterThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.tabContentSpacing,
            7)
        XCTAssertGreaterThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.tabHorizontalPadding,
            9)
        XCTAssertGreaterThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.controlHitTarget,
            32)
        XCTAssertLessThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.tabHeight,
            EmbeddedBrowserToolbarLayoutPolicy.rowHeight)
        XCTAssertLessThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.tabFaviconSize,
            EmbeddedBrowserToolbarLayoutPolicy.tabHeight)
        XCTAssertLessThanOrEqual(
            EmbeddedBrowserToolbarLayoutPolicy.tabCloseHitTarget,
            EmbeddedBrowserToolbarLayoutPolicy.tabHeight)
    }

    func testToolbarSourceCentersEveryTabRowSurface() throws {
        let source = try embeddedBrowserSource()
        let start = try XCTUnwrap(
            source.range(of: "private var browserToolbar: some View"))
        let end = try XCTUnwrap(
            source.range(
                of: "private var browserExtensionsPopover: some View",
                range: start.upperBound..<source.endIndex))
        let toolbar = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertGreaterThanOrEqual(
            toolbar.components(
                separatedBy:
                    "height: EmbeddedBrowserToolbarLayoutPolicy.rowHeight,"
            ).count - 1,
            2)
        XCTAssertGreaterThanOrEqual(
            toolbar.components(
                separatedBy: "alignment: .center"
            ).count - 1,
            4)
        XCTAssertTrue(toolbar.contains(
            ".vertical,\n            EmbeddedBrowserToolbarLayoutPolicy.toolbarVerticalPadding"))
    }

    @MainActor
    func testCEFTeardownImmediatelyHidesAndDetachesNativeChild() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let browser = NSView(frame: host.bounds)
        host.addSubview(browser)

        TatwoCEFContainerTeardownContract.detachFromHostWindow(browser)

        XCTAssertTrue(browser.isHidden)
        XCTAssertNil(browser.superview)
        XCTAssertTrue(host.subviews.isEmpty)
    }

    func testCEFRepresentableDismantleClosesAfterImmediateHostDetach()
        throws
    {
        let source = try chromiumCEFBackendSource()
        let containerStart = try XCTUnwrap(
            source.range(of: "private final class TatwoCEFContainerView"))
        let closeStart = try XCTUnwrap(
            source.range(
                of: "    func close() {",
                range: containerStart.upperBound..<source.endIndex))
        let closeEnd = try XCTUnwrap(
            source.range(
                of: "\n}\n\nstruct EmbeddedChromiumBrowserMountIdentity",
                range: closeStart.upperBound..<source.endIndex))
        let close = String(
            source[closeStart.lowerBound..<closeEnd.lowerBound])
        let detach = try XCTUnwrap(
            close.range(
                of:
                    "TatwoCEFContainerTeardownContract.detachFromHostWindow"))
        let requestClose = try XCTUnwrap(
            close.range(of: "closingBrowser.closeBrowser"))
        XCTAssertLessThan(detach.lowerBound, requestClose.lowerBound)

        let dismantleStart = try XCTUnwrap(
            source.range(of: "    static func dismantleNSView("))
        let dismantleEnd = try XCTUnwrap(
            source.range(
                of: "\n    private func publishUnavailable",
                range: dismantleStart.upperBound..<source.endIndex))
        let dismantle = String(
            source[dismantleStart.lowerBound..<dismantleEnd.lowerBound])
        XCTAssertTrue(dismantle.contains(
            "(nsView as? TatwoCEFContainerView)?.close()"))
    }

    func testNewTabButtonActionIncreasesLaneCountAndSelectsNewLane() {
        let initialID = TatwoBrowserLaneID(rawValue: "browser-initial")
        let newID = TatwoBrowserLaneID(rawValue: "browser-new")
        let firstDate = Date(timeIntervalSince1970: 1_000)
        let secondDate = Date(timeIntervalSince1970: 2_000)
        let initial = TatwoBrowserLaneReducer.reduce(
            state: TatwoBrowserLaneState(),
            action: .open(
                id: initialID,
                binding: .unboundReadOnly,
                title: "新分頁"),
            now: firstDate)

        let next = EmbeddedBrowserNewTabAction.perform(
            state: initial,
            id: newID,
            now: secondDate)

        XCTAssertEqual(initial.lanes.count, 1)
        XCTAssertEqual(next.lanes.count, 2)
        XCTAssertEqual(next.selectedLaneID, newID)
        XCTAssertEqual(next.selectedLane?.id, newID)
        XCTAssertEqual(next.selectedLane?.title, "新分頁")
    }

    func testNewTabButtonUsesExpandedRectangularHitTarget() throws {
        // The new-tab button is a single plain Button that mirrors the
        // trailing controls (extension / gear) which fire reliably. It lives
        // outside any ScrollView / ViewThatFits so its pointer target never
        // swaps with the layout. There is exactly one openNewTab Button.
        let source = try embeddedBrowserSource()
        let start = try XCTUnwrap(
            source.range(of: "private var browserNewTabButton: some View"))
        let end = try XCTUnwrap(
            source.range(
                of: "private func browserTab(",
                range: start.upperBound..<source.endIndex))
        let button = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(button.contains("Button(action: openNewTab)"))
        XCTAssertTrue(button.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(button.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(button.contains(".controlHitTarget"))
        XCTAssertFalse(button.contains("ScrollView("))
        XCTAssertFalse(button.contains("ViewThatFits("))

        // Exactly one openNewTab action across the whole view — no duplicate
        // rendered into an adaptive/scroll alternative (the old regression).
        XCTAssertEqual(
            source.components(
                separatedBy: "Button(action: openNewTab)"
            ).count - 1,
            1)
    }

    func testNewTabFollowsPillsInLeadingTabStrip() throws {
        // In the toolbar the order is: tab strip (pills) -> new-tab + ->
        // Spacer -> trailing controls (extension / gear). The + sits at the
        // toolbar level, the same structural level as the working controls.
        let source = try embeddedBrowserSource()
        let start = try XCTUnwrap(
            source.range(of: "private var browserToolbar: some View"))
        let end = try XCTUnwrap(
            source.range(
                of: "private var browserTrailingControls: some View",
                range: start.upperBound..<source.endIndex))
        let toolbar = String(source[start.lowerBound..<end.lowerBound])

        let tabStrip = try XCTUnwrap(toolbar.range(of: "browserTabStrip"))
        let newTab = try XCTUnwrap(
            toolbar.range(
                of: "browserNewTabButton",
                range: tabStrip.upperBound..<toolbar.endIndex))
        let spacer = try XCTUnwrap(
            toolbar.range(
                of: "Spacer(",
                range: newTab.upperBound..<toolbar.endIndex))
        let trailing = try XCTUnwrap(
            toolbar.range(
                of: "browserTrailingControls",
                range: spacer.upperBound..<toolbar.endIndex))
        // tabStrip < newTab < Spacer < trailingControls
        XCTAssertLessThan(
            toolbar.distance(from: toolbar.startIndex, to: tabStrip.lowerBound),
            toolbar.distance(from: toolbar.startIndex, to: newTab.lowerBound))
        XCTAssertLessThan(
            toolbar.distance(from: toolbar.startIndex, to: newTab.lowerBound),
            toolbar.distance(from: toolbar.startIndex, to: trailing.lowerBound))
    }

    func testBrowserOverlayIsFlushTopAndToolbarOptsOutOfWindowDragging()
        throws
    {
        // The panel deliberately extends 24pt into the titlebar inset so its
        // card is flush with the app window. Unlike the old unsafe offset-only
        // implementation, the whole toolbar now has an AppKit backing view
        // whose mouseDownCanMoveWindow=false contract preserves every click.
        let source = try chatPageSource()
        let start = try XCTUnwrap(
            source.range(of: "func browserPanelOverlay("))
        let end = try XCTUnwrap(
            source.range(
                of: "func rightPanelTakeoverHeader(",
                range: start.upperBound..<source.endIndex))
        let overlay = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(overlay.contains(
            "+ BrowserPanelOverlayLayoutPolicy.windowTopExtension"))
        XCTAssertTrue(overlay.contains(
            "y: -BrowserPanelOverlayLayoutPolicy.windowTopExtension"))
        XCTAssertFalse(overlay.contains("restingWidth"))
        XCTAssertFalse(overlay.contains("isResizing"))

        let browserSource = try embeddedBrowserSource()
        let toolbarStart = try XCTUnwrap(
            browserSource.range(of: "private var browserToolbar: some View"))
        let toolbarEnd = try XCTUnwrap(
            browserSource.range(
                of: "private var browserTrailingControls: some View",
                range: toolbarStart.upperBound..<browserSource.endIndex))
        let toolbar = String(
            browserSource[toolbarStart.lowerBound..<toolbarEnd.lowerBound])
        XCTAssertTrue(toolbar.contains(
            ".background(NonWindowDraggingView())"))

        let protectorSource = try pluginsPageSource()
        let protectorStart = try XCTUnwrap(
            protectorSource.range(of: "struct NonWindowDraggingView"))
        let protector = String(
            protectorSource[protectorStart.lowerBound...])
        XCTAssertTrue(protector.contains(
            "override var mouseDownCanMoveWindow: Bool { false }"))
    }

    func testBookmarkGlyphShrinksWithoutReducingHitTarget() {
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorSymbolSize,
            11)
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorVisualSize,
            18)
        XCTAssertEqual(
            EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth,
            30)
        XCTAssertLessThan(
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorSymbolSize,
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorVisualSize)
        XCTAssertLessThan(
            EmbeddedBrowserBookmarkRailLayoutPolicy.anchorVisualSize,
            EmbeddedBrowserBookmarkRailLayoutPolicy.bubbleWidth)
    }

    func testTabTitlesUseNeutralForegroundAndActiveBackground() throws {
        let source = try embeddedBrowserSource()
        let start = try XCTUnwrap(
            source.range(of: "private func browserTab("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func browserTabTitle(",
                range: start.upperBound..<source.endIndex))
        let tab = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(tab.contains("Color.primary.opacity(0.92)"))
        XCTAssertTrue(tab.contains("Color.secondary.opacity(0.86)"))
        XCTAssertTrue(tab.contains("Color.primary.opacity(0.07)"))
        XCTAssertFalse(tab.contains("LiquidGlassTokens.brandAccent"))
        XCTAssertFalse(tab.contains("LiquidGlassTokens.tint"))
    }

    func testSmallTabCloseTargetUsesHighPriorityTapInsideScrollView()
        throws
    {
        let source = try embeddedBrowserSource()
        let start = try XCTUnwrap(
            source.range(of: "private func browserTab("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func browserTabTitle(",
                range: start.upperBound..<source.endIndex))
        let tab = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(tab.contains(
            ".highPriorityGesture(TapGesture().onEnded"))
        XCTAssertTrue(tab.contains("closeLane(lane.id)"))
        XCTAssertTrue(tab.contains(
            ".contentShape(Rectangle())"))
        XCTAssertTrue(tab.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(tab.contains(".accessibilityAction"))
        XCTAssertTrue(tab.contains(
            "\"browser-tab-close-\\(lane.id.rawValue)\""))
    }

    func testTabSelectButtonRetainsPlainRectangularHitContract() throws {
        let source = try embeddedBrowserSource()
        let start = try XCTUnwrap(
            source.range(of: "private func browserTab("))
        let end = try XCTUnwrap(
            source.range(
                of: "if !lane.isPinned {",
                range: start.upperBound..<source.endIndex))
        let select = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(select.contains(
            "Button {\n                selectLane(lane.id)"))
        XCTAssertTrue(select.contains(".buttonStyle(.plain)"))
        XCTAssertGreaterThanOrEqual(
            select.components(
                separatedBy: ".contentShape(Rectangle())"
            ).count - 1,
            2)
        XCTAssertTrue(select.contains(
            "\"browser-tab-select-\\(lane.id.rawValue)\""))
        XCTAssertTrue(select.contains(
            "EmbeddedBrowserToolbarLayoutPolicy.tabHeight"))
    }

    func testExtensionsPopoverUsesThreeFixtureRowsAndNoRuntimeLoader() throws {
        XCTAssertEqual(
            EmbeddedBrowserExtensionFixture.items.count,
            3)
        XCTAssertEqual(
            Set(EmbeddedBrowserExtensionFixture.items.map(\.id)),
            Set(["ad-blocker", "password-manager", "translation"]))

        let source = try embeddedBrowserSource()
        XCTAssertTrue(source.contains("Text(\"擴充功能\")"))
        XCTAssertTrue(source.contains(
            "\"載入已解壓縮的擴充功能…\""))
        XCTAssertTrue(source.contains(
            "\"此版本尚未支援載入\""))
        XCTAssertTrue(source.contains("NSOpenPanel()"))
        XCTAssertFalse(source.contains("loadChromeExtension"))
    }

    func testBrowserResizeUsesGestureStateAndAnimationFreeTransaction()
        throws
    {
        let source = try chatPageSource()
        XCTAssertTrue(source.contains(
            "@GestureState var browserPanelDragTranslation"))
        XCTAssertTrue(source.contains(
            "@GestureState var browserPanelResizeActive"))
        XCTAssertTrue(source.contains(
            "transaction.animation = nil"))
        XCTAssertTrue(source.contains(
            "Transaction(animation: nil)"))
        XCTAssertTrue(source.contains(
            "transaction.disablesAnimations = true"))
        XCTAssertTrue(source.contains(
            "isPanelResizing: browserPanelResizeActive"))
        XCTAssertFalse(source.contains("restingWidth:"))
        XCTAssertTrue(source.contains(
            ".opacity(\n"
                + "                                    browserPanelResizeActive ? 1 : 0)"))
        let background = try XCTUnwrap(source.range(of:
            ".background {\n"
                + "                            RoundedRectangle("))
        let material = try XCTUnwrap(
            source.range(
                of: ".liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)",
                range: background.upperBound..<source.endIndex))
        XCTAssertLessThan(
            source.distance(
                from: source.startIndex,
                to: background.lowerBound),
            source.distance(
                from: source.startIndex,
                to: material.lowerBound))
    }

    func testBrowserResizeKeepsWidthIndependentViewIdentity() throws {
        let source = try embeddedBrowserSource()
        XCTAssertFalse(source.contains(".id(panelWidth"))
        XCTAssertFalse(source.contains(".id(isPanelResizing"))
        XCTAssertFalse(source.contains(".id(geometry.size.width"))
        XCTAssertTrue(source.contains(
            ".id(\n"
                + "                        EmbeddedChromiumBrowserMountIdentity("))
    }

    func testStartCardRemovesGoogleCaptionAndBookmarksAvoidSystemMenu()
        throws
    {
        let source = try embeddedBrowserSource()
        XCTAssertFalse(source.contains("Text(\"Google 搜尋\")"))

        let start = try XCTUnwrap(
            source.range(of: "private func bookmarkBubble("))
        let end = try XCTUnwrap(
            source.range(
                of: "@ViewBuilder\n    private func bookmarkFavicon",
                range: start.upperBound..<source.endIndex))
        let bookmarkBubble = String(
            source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(bookmarkBubble.contains(
            "EmbeddedBrowserSecondaryClickSurface"))
        XCTAssertFalse(bookmarkBubble.contains(".contextMenu"))
        XCTAssertTrue(source.contains(
            ".accessibilityIdentifier(\"browser-bookmark-custom-menu\")"))
        XCTAssertTrue(source.contains("Label(\"移除書籤\""))
        XCTAssertTrue(source.contains("\"browser-bookmark-undo\""))
    }

    private func embeddedBrowserSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try ChatSourceFamily.read(url: repoRoot.appendingPathComponent(
                    "TatwoUltraworkMac/Sources/"
                        + "TatwoUltraworkMac/EmbeddedBrowserView.swift"))
    }

    private func chatPageSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try ChatSourceFamily.read(url: repoRoot.appendingPathComponent(
                    "TatwoUltraworkMac/Sources/"
                        + "TatwoUltraworkMac/ChatPage.swift"))
    }

    private func chromiumCEFBackendSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf:
                repoRoot.appendingPathComponent(
                    "TatwoUltraworkMac/Sources/"
                        + "TatwoUltraworkMac/ChromiumCEFBackend.swift"),
            encoding: .utf8)
    }

    private func cefBridgeSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf:
                repoRoot.appendingPathComponent(
                    "TatwoUltraworkMac/Sources/"
                        + "TatwoCEFBridge/TatwoCEFBridge.mm"),
            encoding: .utf8)
    }

    private func pluginsPageSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf:
                repoRoot.appendingPathComponent(
                    "TatwoUltraworkMac/Sources/"
                        + "TatwoUltraworkMac/PluginsPage.swift"),
            encoding: .utf8)
    }
}
