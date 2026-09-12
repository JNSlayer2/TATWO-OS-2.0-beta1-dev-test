import XCTest

@testable import TatwoUltraworkCore

final class ChatActivityNormalizerTests: XCTestCase {
  func testOptInActivityChannelKeepsLegacyEndSuppressionAndEmitsPair() {
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      activityTurnID: "turn-a",
      emitsActivityEvents: true)
    let stream = """
    {"type":"codex/event/exec_command_begin","command":"swift test"}
    {"type":"codex/event/exec_command_end","exit_code":0}

    """

    let legacy = normalizer.consume(stream)
    let activities = normalizer.drainActivityEvents()

    XCTAssertEqual(legacy.map(\.kind), [.toolUse])
    XCTAssertFalse(legacy.contains { $0.text.contains("_end") })
    XCTAssertEqual(activities.count, 2)
    XCTAssertEqual(activities.map(\.status), [.running, .succeeded])
    XCTAssertEqual(activities[0].id, activities[1].id)
    XCTAssertEqual(activities.map(\.turnID), ["turn-a", "turn-a"])
    XCTAssertEqual(activities.map(\.attempt), [1, 1])
  }

  func testActivityChannelIsOptInAndDefaultNormalizerRemainsQuiet() {
    let normalizer = TatwoNativeChatStreamNormalizer(engine: .codex)
    _ = normalizer.consume("{\"type\":\"codex/event/exec_command_end\",\"exit_code\":0}\n")

    XCTAssertTrue(normalizer.drainActivityEvents().isEmpty)
  }

  /// Bridge retry = attempt 2 must tag activity identity with attempt/generation.
  func testActivityAttemptTagsBridgeRetryGeneration() {
    let attempt2 = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      activityTurnID: "turn-bridge",
      activityAttempt: 2,
      emitsActivityEvents: true)
    _ = attempt2.consume("{\"type\":\"codex/event/exec_command_begin\",\"command\":\"echo retry\"}\n")
    let activities = attempt2.drainActivityEvents()
    XCTAssertEqual(activities.count, 1)
    XCTAssertEqual(activities[0].attempt, 2)
    XCTAssertEqual(activities[0].generation, 2)
    XCTAssertEqual(activities[0].turnID, "turn-bridge")
    XCTAssertTrue(activities[0].id.contains(":a2:"), "synthetic id should embed attempt")
  }
}
