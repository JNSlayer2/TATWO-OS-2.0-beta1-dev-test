// W6: pointer tests copied from the legacy TatwoIslandShellTests; target and three-second timing adapted.
import XCTest
@testable import Tatwo2

final class TatwoIslandShellTests: XCTestCase {
    @MainActor
    func testPointerExitWaitsBeforeCollapsing() async throws {
        let state = TatwoIslandShellState(collapseDelay: 3)

        XCTAssertFalse(state.isExpanded)
        state.setPointerInside(true)
        XCTAssertTrue(state.isExpanded)
        state.setPointerInside(false)

        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.isExpanded)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertFalse(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 0)
    }

    @MainActor
    func testPointerReturnWithinGracePeriodCancelsCollapse() async throws {
        let state = TatwoIslandShellState(collapseDelay: 3)

        state.setPointerInside(true)
        state.setPointerInside(false)
        state.setPointerInside(true)

        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertTrue(state.isExpanded)
    }

    @MainActor
    func testHeldOpenIgnoresPointerExitAndResumesCollapseAfterRelease() async throws {
        let state = TatwoIslandShellState()
        state.setPointerInside(true)
        state.setPointerInside(false)
        state.holdOpen(true) // Cancels the already scheduled hover collapse.
        state.setPointerInside(true)
        state.setPointerInside(false)
        state.handleCollapseEvent(.escape)
        state.handleCollapseEvent(.outsideTapped)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 1)

        state.holdOpen(false)
        XCTAssertTrue(state.isExpanded, "Releasing consent must allow the full grace period")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.isExpanded)
        try await Task.sleep(for: .milliseconds(3100))
        XCTAssertFalse(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 0)
    }

    @MainActor
    func testReleaseWhilePointerInsideStaysExpandedUntilExit() async throws {
        let state = TatwoIslandShellState()
        state.holdOpen(true)
        state.setPointerInside(true)
        state.holdOpen(false)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertTrue(state.isExpanded)
        state.setPointerInside(false)
        XCTAssertTrue(state.isExpanded)
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertFalse(state.isExpanded)
    }

    func testDefaultSpaceIsWorkOnly() {
        XCTAssertEqual(IslandSpaceRecord.defaults.map(\.kind), [.work])
        XCTAssertEqual(IslandSpaceRecord.defaults.map(\.title), ["工作"])
        XCTAssertEqual(TatwoIslandShellMetrics.collapseDelay, 3)
    }
}
