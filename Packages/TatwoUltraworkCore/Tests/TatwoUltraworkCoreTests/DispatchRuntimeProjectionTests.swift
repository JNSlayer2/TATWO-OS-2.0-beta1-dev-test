import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class DispatchRuntimeProjectionTests: XCTestCase {
  func testRemoteAcceptedIsStartedRatherThanRunningOrVerified() {
    let summary = TatwoDispatchRuntimeReducer.reduce(
      records: [record(status: .queued, remoteStatus: .accepted)])

    XCTAssertEqual(summary.phase, .started)
    XCTAssertEqual(summary.startedCount, 1)
    XCTAssertEqual(summary.runningCount, 0)
    XCTAssertEqual(summary.verifiedCount, 0)
    XCTAssertEqual(summary.acceptedCount, 1)
    XCTAssertEqual(summary.terminalCount, 0)
    XCTAssertEqual(summary.settledCount, 0)
    XCTAssertEqual(summary.headline, "已啟動")
  }

  func testCompletedAndVerifiedRemainSeparateStates() {
    let completed = TatwoDispatchRuntimeReducer.reduce(
      records: [record(status: .completed, receiptID: "receipt-completed")])
    let verified = TatwoDispatchRuntimeReducer.reduce(
      records: [record(status: .verified, receiptID: "receipt-verified")])

    XCTAssertEqual(completed.phase, .completed)
    XCTAssertEqual(completed.completedCount, 1)
    XCTAssertEqual(completed.verifiedCount, 0)
    XCTAssertEqual(completed.terminalCount, 1)
    XCTAssertEqual(completed.settledCount, 1)
    XCTAssertEqual(completed.acceptedCount, 1)
    XCTAssertEqual(completed.headline, "已完成，等待驗收")

    XCTAssertEqual(verified.phase, .verified)
    XCTAssertEqual(verified.completedCount, 0)
    XCTAssertEqual(verified.verifiedCount, 1)
    XCTAssertEqual(verified.terminalCount, 0)
    XCTAssertEqual(verified.settledCount, 1)
    XCTAssertEqual(verified.acceptedCount, 1)
    XCTAssertEqual(verified.headline, "已驗收")
  }

  func testLatestBindingAttemptWinsOverStaleFailure() {
    let stale = record(
      id: "attempt-1",
      status: .failed,
      updatedAt: Date(timeIntervalSince1970: 10))
    let current = record(
      id: "attempt-2",
      status: .running,
      updatedAt: Date(timeIntervalSince1970: 20))

    let summary = TatwoDispatchRuntimeReducer.reduce(records: [stale, current])

    XCTAssertEqual(summary.recordCount, 1)
    XCTAssertEqual(summary.phase, .running)
    XCTAssertEqual(summary.runningCount, 1)
    XCTAssertEqual(summary.failedCount, 0)
  }

  func testHigherAttemptWinsEvenWhenStaleAttemptHasLaterTimestamp() {
    let stale = record(
      id: "attempt-1-stale-update",
      status: .failed,
      attempt: 1,
      updatedAt: Date(timeIntervalSince1970: 30))
    let current = record(
      id: "attempt-2-current",
      status: .running,
      attempt: 2,
      updatedAt: Date(timeIntervalSince1970: 20))

    let projection = TatwoDispatchRuntimeReducer.project(
      records: [stale, current])

    XCTAssertEqual(projection.canonicalRecords.map(\.id), ["attempt-2-current"])
    XCTAssertEqual(projection.summary.recordCount, 1)
    XCTAssertEqual(projection.summary.phase, .running)
    XCTAssertEqual(projection.summary.failedCount, 0)
  }

  func testProjectionSummaryAndDetailRowsUseSameCanonicalRecordSet() {
    let stale = record(
      id: "binding-a-attempt-1",
      status: .failed,
      bindingID: "binding-a",
      attempt: 1,
      updatedAt: Date(timeIntervalSince1970: 10))
    let current = record(
      id: "binding-a-attempt-2",
      status: .completed,
      bindingID: "binding-a",
      attempt: 2,
      receiptID: "receipt-a",
      updatedAt: Date(timeIntervalSince1970: 20))
    let secondBinding = record(
      id: "binding-b-attempt-1",
      status: .queued,
      bindingID: "binding-b",
      attempt: 1,
      updatedAt: Date(timeIntervalSince1970: 15))

    let projection = TatwoDispatchRuntimeReducer.project(
      records: [stale, secondBinding, current])

    XCTAssertEqual(projection.canonicalRecords.count, 2)
    XCTAssertEqual(projection.summary.recordCount, projection.canonicalRecords.count)
    XCTAssertEqual(
      Set(projection.canonicalRecords.map(\.id)),
      Set(["binding-a-attempt-2", "binding-b-attempt-1"]))
    XCTAssertEqual(projection.summary.completedCount, 1)
    XCTAssertEqual(projection.summary.queuedCount, 1)
    XCTAssertEqual(projection.summary.failedCount, 0)
    XCTAssertEqual(projection.summary.runtimeReceiptCount, 1)
  }

  func testQueuedWorkCannotBePresentedAsFinishedWaitingForReceipt() {
    let summary = TatwoDispatchRuntimeReducer.reduce(
      records: [record(status: .queued)])

    XCTAssertEqual(summary.phase, .queued)
    XCTAssertEqual(summary.headline, "已排隊")
    XCTAssertEqual(summary.runtimeReceiptLabel, "無 runtime receipt")
    XCTAssertTrue(summary.hasRuntimeEvidence)
  }

  private func record(
    id: String = "dispatch-runtime",
    status: TatwoDispatchStatus,
    bindingID: String = "binding-runtime",
    attempt: Int? = nil,
    remoteStatus: TatwoLoopJobStatusV1? = nil,
    receiptID: String? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 20)
  ) -> TatwoDispatchRecord {
    TatwoDispatchRecord(
      id: id,
      contractID: "contract-runtime",
      goalID: "goal-runtime",
      bindingID: bindingID,
      sourceSlotID: "slot-runtime",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "Runtime projection test",
      attempt: attempt,
      status: status,
      startedAt: Date(timeIntervalSince1970: 1),
      updatedAt: updatedAt,
      receiptID: receiptID,
      remoteStatus: remoteStatus)
  }
}
