import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatStreamReconnectTests: XCTestCase {

  // MARK: - State machine: disconnect → degraded → recover

  func testDisconnectDegradesWithBackoffThenRecoversToConnected() {
    let sessionID = UUID()
    let policy = ChatStreamReconnectPolicy(
      initialBackoff: 1,
      maxBackoff: 30,
      multiplier: 2,
      maxAttempts: 5)
    let controller = ChatStreamReconnectController(
      sessionID: sessionID,
      policy: policy,
      now: Date(timeIntervalSince1970: 1_000))

    XCTAssertEqual(controller.snapshot.phase, .connected)
    XCTAssertEqual(controller.statusToken, "connected")

    let t0 = Date(timeIntervalSince1970: 1_100)
    let decision = controller.noteDisconnect(reason: "stream_eof", at: t0)

    XCTAssertEqual(decision.state.phase, .degraded)
    XCTAssertEqual(decision.state.attempt, 1)
    XCTAssertTrue(decision.shouldScheduleRetry)
    XCTAssertEqual(decision.retryDelay, 1)
    XCTAssertEqual(decision.state.nextRetryAt, t0.addingTimeInterval(1))
    XCTAssertTrue(decision.state.statusToken.contains("degraded|retrying|attempt=1"))

    // Backoff not elapsed yet.
    XCTAssertFalse(controller.shouldAttemptRetry(at: t0.addingTimeInterval(0.5)))
    XCTAssertTrue(controller.shouldAttemptRetry(at: t0.addingTimeInterval(1)))

    let recovered = controller.noteRetrySucceeded(
      at: t0.addingTimeInterval(2),
      lastStableSequence: 3)
    XCTAssertEqual(recovered.phase, .connected)
    XCTAssertEqual(recovered.attempt, 0)
    XCTAssertNil(recovered.nextRetryAt)
    XCTAssertEqual(recovered.lastStableSequence, 3)
    XCTAssertEqual(controller.statusToken, "connected")
  }

  // MARK: - Reconnect only from stable checkpoint (no tail replay)

  func testReconnectMaterialDropsTailAndRestoresStableOnly() throws {
    let sessionID = UUID()
    let ledger = StreamTranscriptLedger(sessionID: sessionID)
    _ = ledger.beginTail(content: "stable-body")
    _ = try ledger.promoteTail()
    _ = ledger.appendTailChunk("LIVE_TAIL_MUST_NOT_REPLAY")

    XCTAssertTrue(ledger.hasTail)
    XCTAssertEqual(ledger.displayFragments.count, 2)

    let controller = ChatStreamReconnectController(sessionID: sessionID)
    let decision = controller.noteDisconnect(reason: "socket_reset", at: Date(), ledger: ledger)

    XCTAssertNotNil(decision.material)
    XCTAssertTrue(decision.material?.discardedTail == true)
    XCTAssertEqual(decision.material?.stableFragments.count, 1)
    XCTAssertEqual(decision.material?.stableFragments.first?.content, "stable-body")
    XCTAssertFalse(decision.material?.stableFragments.contains(where: \.isTail) ?? true)
    XCTAssertFalse(ledger.hasTail)

    let restored = try ChatStreamReconnectPersistence.restoreLedger(from: decision.material!)
    XCTAssertEqual(restored.sessionID, sessionID)
    XCTAssertEqual(restored.persistableFragments.map(\.content), ["stable-body"])
    XCTAssertFalse(restored.hasTail)
    XCTAssertFalse(
      restored.displayFragments.contains { $0.content.contains("LIVE_TAIL") })
  }

  func testReconnectUsesReconnectSnapshotSemanticsFromWave1() throws {
    let ledger = StreamTranscriptLedger()
    _ = ledger.beginTail(content: "a")
    _ = try ledger.promoteTail()
    _ = ledger.appendTailChunk("partial-tail")

    let material = ChatStreamReconnectPersistence.materialForReconnect(from: ledger)
    XCTAssertEqual(material.stableFragments.map(\.content), ledger.reconnectSnapshot().map(\.content))
    XCTAssertEqual(
      ChatStreamReconnectPersistence.reconnectStoredMessages([
        TatwoNativeChatStoredMessage(
          role: "assistant",
          text: "half",
          status: "streaming"),
        TatwoNativeChatStoredMessage(
          role: "assistant",
          text: "done",
          status: nil),
      ]).map(\.text),
      ["done"])
  }

  // MARK: - Backoff ceiling + attempt budget (no infinite retry)

  func testExponentialBackoffIsCappedAndAttemptsExhaustToOffline() {
    let policy = ChatStreamReconnectPolicy(
      initialBackoff: 2,
      maxBackoff: 10,
      multiplier: 2,
      maxAttempts: 4)
    let controller = ChatStreamReconnectController(
      sessionID: UUID(),
      policy: policy,
      now: Date(timeIntervalSince1970: 0))

    XCTAssertEqual(controller.backoffInterval(forAttempt: 1), 2)
    XCTAssertEqual(controller.backoffInterval(forAttempt: 2), 4)
    XCTAssertEqual(controller.backoffInterval(forAttempt: 3), 8)
    // 2 * 2^3 = 16 → clamped to maxBackoff 10
    XCTAssertEqual(controller.backoffInterval(forAttempt: 4), 10)
    XCTAssertEqual(controller.backoffInterval(forAttempt: 99), 10)

    var now = Date(timeIntervalSince1970: 100)
    var decision = controller.noteDisconnect(reason: "d1", at: now)
    XCTAssertEqual(decision.state.phase, .degraded)
    XCTAssertEqual(decision.state.attempt, 1)
    XCTAssertEqual(decision.retryDelay, 2)

    // Fail attempts 1..3 → stay degraded with attempts 2,3,4
    for expectedAttempt in 2...4 {
      now = now.addingTimeInterval(100)
      decision = controller.noteRetryFailed(reason: "fail-\(expectedAttempt)", at: now)
      XCTAssertEqual(decision.state.phase, .degraded)
      XCTAssertEqual(decision.state.attempt, expectedAttempt)
      XCTAssertTrue(decision.shouldScheduleRetry)
    }

    // Fail attempt 4 → offline; no more automatic retry.
    now = now.addingTimeInterval(100)
    decision = controller.noteRetryFailed(reason: "final", at: now)
    XCTAssertEqual(decision.state.phase, .offline)
    XCTAssertFalse(decision.shouldScheduleRetry)
    XCTAssertNil(decision.retryDelay)
    XCTAssertTrue(decision.state.statusToken.hasPrefix("offline|"))
    XCTAssertFalse(controller.shouldAttemptRetry(at: now.addingTimeInterval(1_000)))

    // Further disconnects while offline do not re-arm infinite retries.
    decision = controller.noteDisconnect(reason: "still_down", at: now.addingTimeInterval(50))
    XCTAssertEqual(decision.state.phase, .offline)
    XCTAssertFalse(decision.shouldScheduleRetry)
  }

  func testManualReconnectFromOfflineResetsBudget() {
    let policy = ChatStreamReconnectPolicy(
      initialBackoff: 1,
      maxBackoff: 8,
      multiplier: 2,
      maxAttempts: 2)
    let controller = ChatStreamReconnectController(sessionID: UUID(), policy: policy)

    var now = Date(timeIntervalSince1970: 500)
    _ = controller.noteDisconnect(reason: "a", at: now)
    now = now.addingTimeInterval(10)
    _ = controller.noteRetryFailed(reason: "b", at: now)
    now = now.addingTimeInterval(10)
    let offline = controller.noteRetryFailed(reason: "c", at: now)
    XCTAssertEqual(offline.state.phase, .offline)

    now = now.addingTimeInterval(30)
    let manual = controller.requestManualReconnect(reason: "user_retry", at: now)
    XCTAssertEqual(manual.state.phase, .degraded)
    XCTAssertEqual(manual.state.attempt, 1)
    XCTAssertTrue(manual.shouldScheduleRetry)
    XCTAssertEqual(manual.retryDelay, 1)
  }

  func testStatusTokenStableForExistingFields() {
    let controller = ChatStreamReconnectController(sessionID: UUID())
    XCTAssertEqual(controller.statusToken, "connected")

    let t = Date(timeIntervalSince1970: 42)
    _ = controller.noteDisconnect(reason: "net", at: t)
    let token = controller.statusToken
    XCTAssertTrue(token.hasPrefix("degraded|retrying|attempt=1|backoff="))
    // Fits existing lastPreview / status style (compact, no UI chrome).
    XCTAssertLessThanOrEqual(token.count, 80)
  }
}
