import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoLoopsSubActivityPresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testFiltersToCurrentContractAndExposesWorkStatusAndElapsedTime() {
    let result = TatwoLoopsSubActivityPresenter.present(
      rows: [
        input(id: "mine", contractID: "current", startedAgo: 125),
        input(id: "other", contractID: "other", startedAgo: 999)
      ],
      currentContractID: "current",
      phase: .running,
      now: now)

    guard case .rows(let rows) = result else {
      return XCTFail("Expected visible rows")
    }
    XCTAssertEqual(rows.map(\.id), ["mine"])
    XCTAssertEqual(rows[0].identity, "builder")
    XCTAssertEqual(rows[0].modelName, "gpt-5.6-sol")
    XCTAssertEqual(rows[0].currentWork, "實作 presenter")
    XCTAssertEqual(rows[0].status, .running)
    XCTAssertEqual(rows[0].elapsedSeconds, 125)
    XCTAssertEqual(rows[0].elapsedLabel, "2 分 5 秒")
    XCTAssertEqual(rows[0].stepNumber, 1)
  }

  func testStableSortRunsBeforeQueueThenUsesStartedAt() {
    let result = TatwoLoopsSubActivityPresenter.present(
      rows: [
        input(id: "queued", queued: true, startedAgo: 500),
        input(id: "newer", startedAgo: 100),
        input(id: "older", startedAgo: 300)
      ],
      currentContractID: "current",
      phase: .running,
      now: now)

    guard case .rows(let rows) = result else {
      return XCTFail("Expected visible rows")
    }
    XCTAssertEqual(rows.map(\.id), ["older", "newer", "queued"])
    XCTAssertEqual(rows.map(\.status), [.running, .running, .queued])
    XCTAssertEqual(rows.map(\.stepNumber), [1, 2, 3])
  }

  func testContractPhaseProjectsAcceptanceBlockedAndCompletedStatuses() {
    let rows = [input(id: "worker")]
    let expectations: [(TatwoLoopsContractActivityPhase, TatwoLoopsSubActivityStatus)] = [
      (TatwoLoopsContractActivityPhase.awaitingAcceptance, .awaitingAcceptance),
      (.blocked, .blocked),
      (.completed, .completed)
    ]
    for (phase, status) in expectations {
      guard case .rows(let presented) = TatwoLoopsSubActivityPresenter.present(
        rows: rows,
        currentContractID: "current",
        phase: phase,
        now: now)
      else {
        return XCTFail("Expected row for \(phase)")
      }
      XCTAssertEqual(presented.first?.status, status)
    }
  }

  func testEmptyContractResultHasExplicitIdleSemantic() {
    XCTAssertEqual(
      TatwoLoopsSubActivityPresenter.present(
        rows: [input(id: "other", contractID: "other")],
        currentContractID: "current",
        phase: .running,
        now: now),
      .empty(message: "目前沒有 sub 在跑"))
  }

  private func input(
    id: String,
    contractID: String = "current",
    queued: Bool = false,
    startedAgo: TimeInterval = 60
  ) -> TatwoLoopsSubActivityInput {
    TatwoLoopsSubActivityInput(
      id: id,
      contractID: contractID,
      identity: "builder",
      modelName: "gpt-5.6-sol",
      subtask: "實作 presenter",
      queued: queued,
      startedAt: now.addingTimeInterval(-startedAgo))
  }
}
