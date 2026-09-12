import XCTest

@testable import TatwoUltraworkCore

final class ChatTranscriptScrollFollowStateTests: XCTestCase {
  func testMoreThanEightyPointsFromBottomStopsFollowingAndShowsJumpControl() {
    var state = ChatTranscriptScrollFollowState()

    state.update(bottomY: 581, viewportHeight: 500)

    XCTAssertFalse(state.isFollowingLatest)
    XCTAssertFalse(state.shouldAutoScrollOnContentChange)
    XCTAssertTrue(state.showsJumpToLatest)
  }

  func testEightyPointsOrLessFromBottomKeepsFollowingNewContent() {
    var state = ChatTranscriptScrollFollowState()

    state.update(bottomY: 580, viewportHeight: 500)

    XCTAssertTrue(state.isFollowingLatest)
    XCTAssertTrue(state.shouldAutoScrollOnContentChange)
    XCTAssertFalse(state.showsJumpToLatest)
  }

  func testJumpToLatestRestoresFollowingAfterUserLeavesBottom() {
    var state = ChatTranscriptScrollFollowState()
    state.update(bottomY: 620, viewportHeight: 500)

    state.jumpToLatest()

    XCTAssertTrue(state.isFollowingLatest)
    XCTAssertTrue(state.shouldAutoScrollOnContentChange)
    XCTAssertFalse(state.showsJumpToLatest)
  }
}
