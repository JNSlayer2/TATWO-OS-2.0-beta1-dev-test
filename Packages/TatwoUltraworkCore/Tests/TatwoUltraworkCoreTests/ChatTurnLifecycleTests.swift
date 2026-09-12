import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatTurnLifecycleTests: XCTestCase {
  func testFiveMinuteToolActivityWithoutFinalTextDoesNotReconcileAliveRunner() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let runID = "run-alive"
    let lifecycle = TatwoChatTurnLifecycle(
      runID: runID,
      assistantID: "assistant-alive",
      startedAt: startedAt)
    let snapshot = TatwoChatRunnerLivenessSnapshot(
      runID: runID,
      phase: .running,
      processIsAlive: true,
      lastActivityAt: startedAt.addingTimeInterval(299),
      formalExitStatus: nil)

    XCTAssertFalse(
      lifecycle.shouldReconcileInactiveRunner(
        snapshot: snapshot,
        now: startedAt.addingTimeInterval(360)),
      "elapsed wall-clock time and absence of final assistant text must not stop a live tool turn")
  }

  func testInactiveReconcileRequiresFormalRunnerTerminationForSameRun() {
    let startedAt = Date(timeIntervalSince1970: 2_000)
    let runID = "run-terminal"
    let lifecycle = TatwoChatTurnLifecycle(
      runID: runID,
      assistantID: "assistant-terminal",
      startedAt: startedAt)

    XCTAssertFalse(
      lifecycle.shouldReconcileInactiveRunner(
        snapshot: TatwoChatRunnerLivenessSnapshot(
          runID: runID,
          phase: .running,
          processIsAlive: false,
          lastActivityAt: startedAt,
          formalExitStatus: nil),
        now: startedAt.addingTimeInterval(600)),
      "a temporarily missing process observation is not a formal terminal event")

    XCTAssertFalse(
      lifecycle.shouldReconcileInactiveRunner(
        snapshot: TatwoChatRunnerLivenessSnapshot(
          runID: "stale-run",
          phase: .terminated,
          processIsAlive: false,
          lastActivityAt: startedAt,
          formalExitStatus: 0),
        now: startedAt.addingTimeInterval(600)),
      "a stale run must never terminate the active turn")

    XCTAssertTrue(
      lifecycle.shouldReconcileInactiveRunner(
        snapshot: TatwoChatRunnerLivenessSnapshot(
          runID: runID,
          phase: .terminated,
          processIsAlive: false,
          lastActivityAt: startedAt,
          formalExitStatus: 0),
        now: startedAt.addingTimeInterval(600)))
  }

  func testCancelProducesOneTerminalTransitionAndRejectsLateEvents() {
    let runID = "run-cancel"
    var lifecycle = TatwoChatTurnLifecycle(
      runID: runID,
      assistantID: "assistant-cancel",
      startedAt: Date(timeIntervalSince1970: 3_000))

    XCTAssertTrue(lifecycle.requestCancellation())
    XCTAssertFalse(lifecycle.requestCancellation(), "repeated stop clicks must be idempotent")
    XCTAssertEqual(lifecycle.phase, .cancellationRequested)
    XCTAssertFalse(
      lifecycle.shouldAcceptNonTerminalEvent(runID: runID),
      "stdout/tool/activity arriving after cancel must not rewrite the terminal row")
    XCTAssertFalse(lifecycle.shouldAcceptNonTerminalEvent(runID: "stale-run"))

    XCTAssertTrue(lifecycle.recordFormalTerminalEvent(runID: runID, status: 143))
    XCTAssertEqual(lifecycle.phase, .terminal)
    XCTAssertEqual(lifecycle.formalExitStatus, 143)
    XCTAssertFalse(
      lifecycle.recordFormalTerminalEvent(runID: runID, status: 143),
      "termination handler and reconciler racing must still produce one terminal transition")
    XCTAssertFalse(lifecycle.recordFormalTerminalEvent(runID: "stale-run", status: 0))
  }

  func testReconcilerPreservesWatchdogFailureWhenLateExitAlsoArrives() {
    let runID = "run-watchdog-race"
    let message = "watchdog stopped a stalled route"
    var lifecycle = TatwoChatTurnLifecycle(
      runID: runID,
      assistantID: "assistant-watchdog",
      startedAt: Date(timeIntervalSince1970: 4_000))
    let snapshot = TatwoChatRunnerLivenessSnapshot(
      runID: runID,
      phase: .terminated,
      processIsAlive: false,
      lastActivityAt: Date(timeIntervalSince1970: 4_600),
      formalExitStatus: 15,
      formalFailureMessage: message)

    XCTAssertTrue(lifecycle.shouldReconcileInactiveRunner(snapshot: snapshot))
    XCTAssertEqual(snapshot.formalFailureMessage, message)
    XCTAssertTrue(lifecycle.recordFormalTerminalEvent(runID: runID, status: 15))
    XCTAssertFalse(
      lifecycle.recordFormalTerminalEvent(runID: runID, status: 15),
      "the late process-exit callback must lose the same terminal latch")
    XCTAssertEqual(snapshot.formalFailureMessage, message)
  }
}
