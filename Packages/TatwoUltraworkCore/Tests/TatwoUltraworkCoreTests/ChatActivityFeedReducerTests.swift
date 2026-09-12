import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatActivityFeedReducerTests: XCTestCase {
  func testActivityStartAndEndPairIntoOneSucceededRow() {
    let start = Date(timeIntervalSince1970: 100)
    let end = Date(timeIntervalSince1970: 105)
    var reducer = ChatActivityFeedReducer(maxVisibleCompleted: 6)

    reducer.reduce(
      ChatActivityEventV1(
        id: "call-1",
        kind: .command,
        label: "Running command",
        detail: "swift test",
        startedAt: start,
        status: .running,
        turnID: "turn-a")
    )
    reducer.reduce(
      ChatActivityEventV1(
        id: "call-1",
        kind: .command,
        label: "Running command",
        detail: "swift test",
        startedAt: start,
        endedAt: end,
        status: .succeeded,
        turnID: "turn-a")
    )

    let row = XCTAssertSingle(reducer.feed(for: "turn-a").activities)
    XCTAssertEqual(row.id, "call-1")
    XCTAssertEqual(row.status, .succeeded)
    XCTAssertEqual(row.startedAt, start)
    XCTAssertEqual(row.endedAt, end)
  }

  func testActivityOutOfOrderEndIsMergedWhenStartArrives() {
    let start = Date(timeIntervalSince1970: 200)
    let end = Date(timeIntervalSince1970: 208)
    var reducer = ChatActivityFeedReducer()

    reducer.reduce(
      ChatActivityEventV1(
        id: "call-2",
        kind: .fileEdit,
        label: "Editing file",
        startedAt: end,
        endedAt: end,
        status: .succeeded,
        turnID: "turn-a")
    )
    reducer.reduce(
      ChatActivityEventV1(
        id: "call-2",
        kind: .fileEdit,
        label: "Editing file",
        detail: "Sources/Main.swift",
        startedAt: start,
        status: .running,
        turnID: "turn-a")
    )

    let row = XCTAssertSingle(reducer.feed(for: "turn-a").activities)
    XCTAssertEqual(row.status, .succeeded)
    XCTAssertEqual(row.startedAt, start)
    XCTAssertEqual(row.endedAt, end)
    XCTAssertEqual(row.detail, "Sources/Main.swift")
  }

  func testActivityUnpairedEndIsToleratedAsTerminalRow() {
    let end = Date(timeIntervalSince1970: 300)
    var reducer = ChatActivityFeedReducer()
    reducer.reduce(
      ChatActivityEventV1(
        id: "unpaired",
        kind: .webFetch,
        label: "Fetch",
        startedAt: end,
        endedAt: end,
        status: .failed,
        turnID: "turn-a",
        sourceType: "web_fetch_end")
    )

    let row = XCTAssertSingle(reducer.feed(for: "turn-a").activities)
    XCTAssertEqual(row.status, .failed)
    XCTAssertEqual(row.endedAt, end)
    XCTAssertEqual(row.sourceType, "web_fetch_end")
  }

  func testActivityCompletedRowsOverflowByConfiguredCount() {
    var reducer = ChatActivityFeedReducer(maxVisibleCompleted: 2)
    for index in 0..<4 {
      let timestamp = Date(timeIntervalSince1970: TimeInterval(index))
      reducer.reduce(
        ChatActivityEventV1(
          id: "call-\(index)",
          kind: .toolUse,
          label: "Tool \(index)",
          startedAt: timestamp,
          endedAt: timestamp,
          status: .succeeded,
          turnID: "turn-a")
      )
    }

    let feed = reducer.feed(for: "turn-a")
    XCTAssertEqual(feed.activities.count, 2)
    XCTAssertEqual(feed.completedOverflowCount, 2)
    XCTAssertEqual(feed.activities.map(\.id), ["call-3", "call-2"])
  }

  func testActivityFailedStatusRemainsTerminalAfterLateRunningEvent() {
    let start = Date(timeIntervalSince1970: 400)
    let end = Date(timeIntervalSince1970: 401)
    var reducer = ChatActivityFeedReducer()
    reducer.reduce(
      ChatActivityEventV1(
        id: "failed",
        kind: .toolUse,
        label: "Tool",
        startedAt: start,
        endedAt: end,
        status: .failed,
        turnID: "turn-a")
    )
    reducer.reduce(
      ChatActivityEventV1(
        id: "failed",
        kind: .toolUse,
        label: "Tool",
        startedAt: start,
        status: .running,
        turnID: "turn-a")
    )

    let row = XCTAssertSingle(reducer.feed(for: "turn-a").activities)
    XCTAssertEqual(row.status, .failed)
    XCTAssertEqual(row.endedAt, end)
  }

  func testActivityTurnIDsIsolateSameProviderCallID() {
    let start = Date(timeIntervalSince1970: 500)
    let end = Date(timeIntervalSince1970: 501)
    var reducer = ChatActivityFeedReducer()
    reducer.reduce(
      ChatActivityEventV1(
        id: "reused-call-id",
        kind: .command,
        label: "Turn A",
        startedAt: start,
        status: .running,
        turnID: "turn-a")
    )
    reducer.reduce(
      ChatActivityEventV1(
        id: "reused-call-id",
        kind: .command,
        label: "Turn B",
        startedAt: start,
        endedAt: end,
        status: .succeeded,
        turnID: "turn-b")
    )

    let turnA = XCTAssertSingle(reducer.feed(for: "turn-a").activities)
    let turnB = XCTAssertSingle(reducer.feed(for: "turn-b").activities)
    XCTAssertEqual(turnA.status, .running)
    XCTAssertEqual(turnB.status, .succeeded)
    XCTAssertEqual(turnA.label, "Turn A")
    XCTAssertEqual(turnB.label, "Turn B")
  }

  /// SOL-5 I-3 attack shape: bridge retry keeps the same user turn / provider
  /// call ID while attempt-1 late activity and attempt-2 progress co-exist.
  /// Without attempt scoping, attempt-2 terminal would merge into attempt-1.
  func testBridgeRetryAttemptIsolationSameTurnSameProviderCallID() {
    let t1 = Date(timeIntervalSince1970: 600)
    let t2 = Date(timeIntervalSince1970: 601)
    let t3 = Date(timeIntervalSince1970: 610)
    var reducer = ChatActivityFeedReducer()

    // Attempt 1 late drain (would arrive after bridge flag in runtime).
    reducer.reduce(
      ChatActivityEventV1(
        id: "provider-call-shared",
        kind: .command,
        label: "Attempt1 command",
        detail: "stale-tail",
        startedAt: t1,
        status: .running,
        turnID: "turn-bridge",
        attempt: 1)
    )
    // Attempt 2 (bridge retry) reuses the same provider call ID on the same turn.
    reducer.reduce(
      ChatActivityEventV1(
        id: "provider-call-shared",
        kind: .command,
        label: "Attempt2 command",
        detail: "retry-body",
        startedAt: t2,
        status: .running,
        turnID: "turn-bridge",
        attempt: 2)
    )
    reducer.reduce(
      ChatActivityEventV1(
        id: "provider-call-shared",
        kind: .command,
        label: "Attempt2 command",
        detail: "retry-body",
        startedAt: t2,
        endedAt: t3,
        status: .succeeded,
        turnID: "turn-bridge",
        attempt: 2)
    )

    let feed = reducer.feed(for: "turn-bridge")
    XCTAssertEqual(feed.activities.count, 2, "attempt rows must not collapse")
    let attempt1 = feed.activities.first { $0.attempt == 1 }
    let attempt2 = feed.activities.first { $0.attempt == 2 }
    XCTAssertEqual(attempt1?.status, .running)
    XCTAssertEqual(attempt1?.detail, "stale-tail")
    XCTAssertEqual(attempt2?.status, .succeeded)
    XCTAssertEqual(attempt2?.detail, "retry-body")
    XCTAssertEqual(attempt1?.id, attempt2?.id)
    XCTAssertEqual(attempt1?.turnID, "turn-bridge")
    XCTAssertEqual(attempt2?.generation, 2)
  }

  func testBridgeRetrySyntheticSequenceIDsDoNotPairAcrossAttempts() {
    let start = Date(timeIntervalSince1970: 700)
    var reducer = ChatActivityFeedReducer()
    // Same synthetic family sequence number would collide without attempt key.
    reducer.reduce(
      ChatActivityEventV1(
        id: "turn-x:a1:command:1",
        kind: .command,
        label: "A1",
        startedAt: start,
        status: .running,
        turnID: "turn-x",
        attempt: 1)
    )
    reducer.reduce(
      ChatActivityEventV1(
        id: "turn-x:a2:command:1",
        kind: .command,
        label: "A2",
        startedAt: start,
        endedAt: start,
        status: .succeeded,
        turnID: "turn-x",
        attempt: 2)
    )
    let feed = reducer.feed(for: "turn-x")
    XCTAssertEqual(feed.activities.count, 2)
    XCTAssertEqual(Set(feed.activities.map(\.attempt)), Set([1, 2]))
  }

  @discardableResult
  private func XCTAssertSingle<T>(
    _ values: [T],
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> T {
    guard values.count == 1, let value = values.first else {
      XCTFail("expected one value, got \(values.count)", file: file, line: line)
      fatalError("expected one value")
    }
    return value
  }
}
