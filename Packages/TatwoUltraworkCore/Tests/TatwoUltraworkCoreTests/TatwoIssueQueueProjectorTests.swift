import XCTest

import TatwoWorkReceiptContracts

@testable import TatwoUltraworkCore

final class TatwoIssueQueueProjectorTests: XCTestCase {

  func testFailedRunProjectsHighPriorityIssue() {
    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [
        makeRun(goalID: "g-failed", status: .failed, objective: "修復 gateway 掉線"),
        makeRun(goalID: "g-blocked", status: .blocked),
        makeRun(goalID: "g-rollback", status: .rollbackRequired),
      ],
      dispatchFailures: [],
      now: date(1_000))

    XCTAssertEqual(issues.count, 3)
    for issue in issues {
      XCTAssertEqual(issue.priority, .high)
    }
    let failed = issues.first { $0.goalRunID == "g-failed" }
    XCTAssertEqual(failed?.issueID, "goalrun:g-failed")
    XCTAssertEqual(failed?.title, "修復 gateway 掉線")
    XCTAssertEqual(failed?.status, .active)
    let blocked = issues.first { $0.goalRunID == "g-blocked" }
    XCTAssertEqual(blocked?.status, .blocked)
  }

  func testInFlightRunProjectsNormalPriority() {
    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [
        makeRun(goalID: "g-running", status: .running),
        makeRun(goalID: "g-dispatching", status: .dispatching),
        makeRun(goalID: "g-gate", status: .humanGate),
      ],
      dispatchFailures: [],
      now: date(1_000))

    XCTAssertEqual(issues.count, 3)
    for issue in issues {
      XCTAssertEqual(issue.priority, .normal)
    }
  }

  func testPassedAndTerminalRunsAreNotProjected() {
    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [
        makeRun(goalID: "g-passed", status: .passed),
        makeRun(goalID: "g-succeeded", status: .succeeded),
        makeRun(goalID: "g-cancelled", status: .cancelled),
      ],
      dispatchFailures: [],
      now: date(1_000))

    XCTAssertTrue(issues.isEmpty)
  }

  func testDispatchFailureProjectsIssueWithDispatchIDAndReason() {
    let record = makeFailedDispatch(
      id: "d-1",
      goalID: "g-1",
      message: "rate_limit from backend",
      occurredAt: date(50),
      updatedAt: date(60))

    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [],
      dispatchFailures: [record],
      now: date(1_000))

    XCTAssertEqual(issues.count, 1)
    let issue = try! XCTUnwrap(issues.first)
    XCTAssertEqual(issue.issueID, "dispatch:d-1")
    XCTAssertEqual(issue.goalRunID, "g-1")
    XCTAssertTrue(issue.title.contains("d-1"))
    XCTAssertTrue(issue.title.contains("rate_limit from backend"))
    XCTAssertEqual(issue.priority, .high)
    XCTAssertEqual(issue.status, .active)
    XCTAssertEqual(issue.createdAt, date(50))
    XCTAssertEqual(issue.updatedAt, date(60))
  }

  func testDispatchRecordWithoutFailureEvidenceIsNotProjected() {
    let healthy = makeDispatch(
      id: "d-ok", goalID: "g-1", status: .completed, updatedAt: date(60))

    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [],
      dispatchFailures: [healthy],
      now: date(1_000))

    XCTAssertTrue(issues.isEmpty)
  }

  func testSortingIsPriorityDescThenUpdatedAtDesc() {
    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [
        makeRun(goalID: "g-normal-new", status: .running, updatedAt: date(900)),
        makeRun(goalID: "g-high-old", status: .failed, updatedAt: date(100)),
        makeRun(goalID: "g-high-new", status: .failed, updatedAt: date(500)),
        makeRun(goalID: "g-normal-old", status: .running, updatedAt: date(200)),
      ],
      dispatchFailures: [],
      now: date(1_000))

    XCTAssertEqual(
      issues.map(\.issueID),
      [
        "goalrun:g-high-new",
        "goalrun:g-high-old",
        "goalrun:g-normal-new",
        "goalrun:g-normal-old",
      ])
  }

  func testSameGoalRunIsDeduplicatedKeepingLatest() {
    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [
        makeRun(goalID: "g-1", status: .running, objective: "舊版", updatedAt: date(100)),
        makeRun(goalID: "g-1", status: .failed, objective: "新版", updatedAt: date(300)),
      ],
      dispatchFailures: [],
      now: date(1_000))

    XCTAssertEqual(issues.count, 1)
    XCTAssertEqual(issues.first?.title, "新版")
    XCTAssertEqual(issues.first?.priority, .high)
  }

  func testEmptyInputsReturnEmptyArray() {
    let issues = TatwoIssueQueueProjector.project(
      goalRuns: [],
      dispatchFailures: [],
      now: date(0))

    XCTAssertTrue(issues.isEmpty)
  }

  // MARK: - Helpers

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private func makeRun(
    goalID: String,
    status: GoalRunStatus,
    objective: String = "objective",
    issuedAt: Date = Date(timeIntervalSince1970: 10),
    updatedAt: Date = Date(timeIntervalSince1970: 20)
  ) -> TatwoStoredGoalRun {
    TatwoStoredGoalRun(
      goalID: goalID,
      contractID: "contract-\(goalID)",
      mode: .m,
      scenario: "default",
      objective: objective,
      status: status,
      issuedAt: issuedAt,
      updatedAt: updatedAt)
  }

  private func makeDispatch(
    id: String,
    goalID: String?,
    status: TatwoDispatchStatus,
    updatedAt: Date,
    failureReceipt: TatwoDispatchFailureReceipt? = nil
  ) -> TatwoDispatchRecord {
    TatwoDispatchRecord(
      id: id,
      contractID: "contract-1",
      goalID: goalID,
      bindingID: "binding-1",
      sourceSlotID: "slot-1",
      identity: .sub,
      modelID: "model-1",
      subtask: "subtask",
      status: status,
      startedAt: Date(timeIntervalSince1970: 30),
      updatedAt: updatedAt,
      failureReceipt: failureReceipt)
  }

  private func makeFailedDispatch(
    id: String,
    goalID: String?,
    message: String,
    occurredAt: Date,
    updatedAt: Date
  ) -> TatwoDispatchRecord {
    makeDispatch(
      id: id,
      goalID: goalID,
      status: .failed,
      updatedAt: updatedAt,
      failureReceipt: TatwoDispatchFailureReceipt(
        failureClass: .retryable,
        errorCode: "rate_limit",
        httpStatus: 429,
        operatorMessage: message,
        rawErrorDigest: nil,
        backendRequestID: nil,
        backendResponseID: nil,
        occurredAt: occurredAt))
  }
}
