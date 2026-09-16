// Hover exits have no grace period; consent and programmatic previews are separate.
import XCTest
@testable import Tatwo2

final class TatwoIslandShellTests: XCTestCase {
    @MainActor
    func testPointerExitCollapsesSynchronouslyWithoutClicking() {
        let state = TatwoIslandShellState()
        for _ in 0..<3 {
            state.setPointerInside(true)
            XCTAssertTrue(state.isExpanded)
            state.setPointerInside(false)
            XCTAssertFalse(state.isExpanded)
            XCTAssertEqual(state.expansionProgress, 0)
        }
    }

    @MainActor
    func testPointerReturnExpandsWithoutAStaleCollapseTimer() async throws {
        let state = TatwoIslandShellState()
        state.setPointerInside(true)
        state.setPointerInside(false)
        state.setPointerInside(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.isExpanded)
    }

    @MainActor
    func testHeldOpenIgnoresExitAndCollapsesImmediatelyAfterRelease() {
        let state = TatwoIslandShellState()
        state.holdOpen(true)
        state.setPointerInside(true)
        state.setPointerInside(false)
        state.handleCollapseEvent(.escape)
        state.handleCollapseEvent(.outsideTapped)
        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 1)
        state.holdOpen(false)
        XCTAssertFalse(state.isExpanded)
        XCTAssertEqual(state.expansionProgress, 0)
    }

    @MainActor
    func testReleaseWhilePointerInsideStaysExpandedUntilExit() {
        let state = TatwoIslandShellState()
        state.holdOpen(true)
        state.setPointerInside(true)
        state.holdOpen(false)
        XCTAssertTrue(state.isExpanded)
        state.setPointerInside(false)
        XCTAssertFalse(state.isExpanded)
    }

    func testDefaultSpaceIsWorkOnlyAndHoverHasNoDelay() {
        XCTAssertEqual(IslandSpaceRecord.defaults.map(\.kind), [.work])
        XCTAssertEqual(IslandSpaceRecord.defaults.map(\.title), ["工作"])
        XCTAssertEqual(TatwoIslandShellMetrics.collapseDelay, 0)
    }
}
