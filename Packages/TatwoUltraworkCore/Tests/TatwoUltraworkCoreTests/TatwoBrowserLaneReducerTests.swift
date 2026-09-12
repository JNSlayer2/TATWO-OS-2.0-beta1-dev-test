import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoBrowserLaneReducerTests: XCTestCase {
  private let firstDate = Date(timeIntervalSince1970: 1_000)
  private let secondDate = Date(timeIntervalSince1970: 2_000)
  private let thirdDate = Date(timeIntervalSince1970: 3_000)

  func testOpeningFirstGoalBoundLaneSelectsIt() {
    let state = reduce(
      .init(),
      .open(
        id: id("spec"),
        binding: .goal(goalID: "goal-12", contractID: "contract-12"),
        title: "Specification"),
      at: firstDate)

    XCTAssertEqual(state.lanes.map(\.id), [id("spec")])
    XCTAssertEqual(state.selectedLaneID, id("spec"))
    XCTAssertEqual(
      state.lanes.first?.binding,
      .goal(goalID: "goal-12", contractID: "contract-12"))
    XCTAssertEqual(state.lanes.first?.createdAt, firstDate)
    XCTAssertEqual(state.lanes.first?.lastActiveAt, firstDate)
  }

  func testOpeningAnotherLaneAppendsAndSelectsIt() {
    var state = reduce(
      .init(),
      .open(id: id("one"), binding: .unboundReadOnly, title: "One"),
      at: firstDate)

    state = reduce(
      state,
      .open(id: id("two"), binding: .unboundReadOnly, title: "Two"),
      at: secondDate)

    XCTAssertEqual(state.lanes.map(\.id), [id("one"), id("two")])
    XCTAssertEqual(state.selectedLaneID, id("two"))
  }

  func testOpeningExistingLaneDoesNotRebindOrReplaceIt() {
    var state = reduce(
      .init(),
      .open(
        id: id("stable"),
        binding: .goal(goalID: "original-goal", contractID: "original-contract"),
        title: "Original"),
      at: firstDate)

    state = reduce(
      state,
      .open(
        id: id("stable"),
        binding: .goal(goalID: "other-goal", contractID: "other-contract"),
        title: "Replacement"),
      at: secondDate)

    XCTAssertEqual(state.lanes.count, 1)
    XCTAssertEqual(state.lanes[0].title, "Original")
    XCTAssertEqual(
      state.lanes[0].binding,
      .goal(goalID: "original-goal", contractID: "original-contract"))
    XCTAssertEqual(state.lanes[0].lastActiveAt, firstDate)
  }

  func testOpeningLaneWithIncompleteGoalBindingIsSafeNoOp() {
    let missingGoal = reduce(
      .init(),
      .open(
        id: id("missing-goal"),
        binding: .goal(goalID: "", contractID: "contract"),
        title: "Missing Goal"),
      at: firstDate)
    let missingContract = reduce(
      .init(),
      .open(
        id: id("missing-contract"),
        binding: .goal(goalID: "goal", contractID: "  "),
        title: "Missing Contract"),
      at: firstDate)

    XCTAssertTrue(missingGoal.lanes.isEmpty)
    XCTAssertNil(missingGoal.selectedLaneID)
    XCTAssertTrue(missingContract.lanes.isEmpty)
    XCTAssertNil(missingContract.selectedLaneID)
  }

  func testOpeningBlankLaneIDIsSafeNoOp() {
    let state = reduce(
      .init(),
      .open(id: id("  "), binding: .unboundReadOnly, title: "Invalid"),
      at: firstDate)

    XCTAssertTrue(state.lanes.isEmpty)
    XCTAssertNil(state.selectedLaneID)
  }

  func testLaneLimitRejectsAdditionalOpenWithoutChangingSelection() {
    var state = TatwoBrowserLaneState(maximumLaneCount: 2)
    state = reduce(
      state,
      .open(id: id("one"), binding: .unboundReadOnly, title: "One"),
      at: firstDate)
    state = reduce(
      state,
      .open(id: id("two"), binding: .unboundReadOnly, title: "Two"),
      at: secondDate)

    let unchanged = reduce(
      state,
      .open(id: id("three"), binding: .unboundReadOnly, title: "Three"),
      at: thirdDate)

    XCTAssertEqual(unchanged, state)
  }

  func testSelectingLaneUpdatesSelectionAndLastActiveTimestamp() {
    var state = stateWithThreeLanes()

    state = reduce(state, .select(id("one")), at: thirdDate)

    XCTAssertEqual(state.selectedLaneID, id("one"))
    XCTAssertEqual(state.lanes.first(where: { $0.id == id("one") })?.lastActiveAt, thirdDate)
  }

  func testSelectingMissingLaneIsSafeNoOp() {
    let state = stateWithThreeLanes()

    let unchanged = reduce(state, .select(id("missing")), at: thirdDate)

    XCTAssertEqual(unchanged, state)
  }

  func testClosingSelectedLaneChoosesLeftNeighbor() {
    var state = stateWithThreeLanes()
    state = reduce(state, .select(id("two")), at: thirdDate)

    state = reduce(state, .close(id("two")), at: thirdDate)

    XCTAssertEqual(state.lanes.map(\.id), [id("one"), id("three")])
    XCTAssertEqual(state.selectedLaneID, id("one"))
    XCTAssertEqual(state.lanes[0].lastActiveAt, thirdDate)
  }

  func testClosingFirstSelectedLaneChoosesRightNeighbor() {
    var state = stateWithThreeLanes()
    state = reduce(state, .select(id("one")), at: thirdDate)

    state = reduce(state, .close(id("one")), at: thirdDate)

    XCTAssertEqual(state.lanes.map(\.id), [id("two"), id("three")])
    XCTAssertEqual(state.selectedLaneID, id("two"))
  }

  func testClosingLastLaneLeavesExplicitEmptyState() {
    var state = reduce(
      .init(),
      .open(id: id("only"), binding: .unboundReadOnly, title: "Only"),
      at: firstDate)

    state = reduce(state, .close(id("only")), at: secondDate)

    XCTAssertTrue(state.lanes.isEmpty)
    XCTAssertNil(state.selectedLaneID)
  }

  func testClosingMissingOrInactiveLaneDoesNotCreateDanglingSelection() {
    var state = stateWithThreeLanes()
    let missingClose = reduce(state, .close(id("missing")), at: thirdDate)
    XCTAssertEqual(missingClose, state)

    state = reduce(state, .close(id("one")), at: thirdDate)

    XCTAssertEqual(state.lanes.map(\.id), [id("two"), id("three")])
    XCTAssertEqual(state.selectedLaneID, id("three"))
  }

  func testPinningLaneChangesOnlyRequestedValueAndMissingLaneIsNoOp() {
    let state = stateWithThreeLanes()

    let pinned = reduce(state, .pin(id("two"), true), at: thirdDate)
    XCTAssertTrue(pinned.lanes.first(where: { $0.id == id("two") })?.isPinned == true)
    XCTAssertEqual(pinned.selectedLaneID, state.selectedLaneID)
    XCTAssertEqual(
      pinned.lanes.first(where: { $0.id == id("two") })?.lastActiveAt,
      state.lanes.first(where: { $0.id == id("two") })?.lastActiveAt)

    let unchanged = reduce(pinned, .pin(id("missing"), true), at: thirdDate)
    XCTAssertEqual(unchanged, pinned)
  }

  func testPinnedLanesAreStablySortedBeforeUnpinnedLanes() {
    var state = stateWithThreeLanes()

    state = reduce(state, .pin(id("two"), true), at: thirdDate)
    XCTAssertEqual(state.lanes.map(\.id), [id("two"), id("one"), id("three")])

    state = reduce(state, .pin(id("three"), true), at: thirdDate)
    XCTAssertEqual(state.lanes.map(\.id), [id("two"), id("three"), id("one")])

    state = reduce(state, .pin(id("two"), false), at: thirdDate)
    XCTAssertEqual(state.lanes.map(\.id), [id("three"), id("two"), id("one")])
  }

  func testOpeningAtCapacityKeepsPinnedFirstOrderingAndEightLaneLimit() {
    var state = TatwoBrowserLaneState()
    for index in 0 ..< TatwoBrowserLaneState.defaultMaximumLaneCount {
      state = reduce(
        state,
        .open(
          id: id("lane-\(index)"),
          binding: .unboundReadOnly,
          title: "Lane \(index)"),
        at: firstDate.addingTimeInterval(Double(index)))
    }
    state = reduce(state, .pin(id("lane-6"), true), at: thirdDate)

    let rejected = reduce(
      state,
      .open(
        id: id("lane-8"),
        binding: .unboundReadOnly,
        title: "Ninth"),
      at: thirdDate)

    XCTAssertEqual(rejected.lanes.count, 8)
    XCTAssertEqual(rejected.lanes.first?.id, id("lane-6"))
    XCTAssertNil(rejected.lanes.first(where: { $0.id == id("lane-8") }))
  }

  func testStateAndActionsHaveCodableValueSemantics() throws {
    let state = stateWithThreeLanes()
    var copied = state
    copied = reduce(copied, .pin(id("one"), true), at: thirdDate)

    XCTAssertNotEqual(copied, state)
    XCTAssertFalse(state.lanes[0].isPinned)

    let stateData = try JSONEncoder().encode(state)
    let decodedState = try JSONDecoder().decode(TatwoBrowserLaneState.self, from: stateData)
    XCTAssertEqual(decodedState, state)

    let action = TatwoBrowserLaneAction.open(
      id: id("round-trip"),
      binding: .goal(goalID: "goal", contractID: "contract"),
      title: "Round Trip")
    let actionData = try JSONEncoder().encode(action)
    let decodedAction = try JSONDecoder().decode(TatwoBrowserLaneAction.self, from: actionData)
    XCTAssertEqual(decodedAction, action)
  }

  private func stateWithThreeLanes() -> TatwoBrowserLaneState {
    var state = TatwoBrowserLaneState()
    state = reduce(
      state,
      .open(id: id("one"), binding: .unboundReadOnly, title: "One"),
      at: firstDate)
    state = reduce(
      state,
      .open(
        id: id("two"),
        binding: .goal(goalID: "goal", contractID: "contract"),
        title: "Two"),
      at: secondDate)
    state = reduce(
      state,
      .open(id: id("three"), binding: .unboundReadOnly, title: "Three"),
      at: thirdDate)
    return state
  }

  private func reduce(
    _ state: TatwoBrowserLaneState,
    _ action: TatwoBrowserLaneAction,
    at now: Date
  ) -> TatwoBrowserLaneState {
    TatwoBrowserLaneReducer.reduce(state: state, action: action, now: now)
  }

  private func id(_ value: String) -> TatwoBrowserLaneID {
    TatwoBrowserLaneID(rawValue: value)
  }
}
