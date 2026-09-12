import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class GrokStreamingJSONTests: XCTestCase {
  func testCompleteFixtureStreamsThoughtAndTextThenCapturesEndSessionWithoutRenderingEnd() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/grok-streaming-fixture.jsonl")
    let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON)

    let events = normalizer.consume(fixture) + normalizer.flush()
    XCTAssertEqual(
      events.filter { $0.kind == .thinking }.map(\.text).joined(),
      "The user wants me to reply with just one line: \"stream-ok\". This is a simple smoke test.")
    XCTAssertEqual(
      events.filter { $0.kind == .message }.map(\.text).joined(),
      "stream-ok")
    let session = try XCTUnwrap(events.first { $0.kind == .session })
    XCTAssertEqual(
      session.sessionID,
      "01a01ddb-f132-7651-bc5c-ba885cac01da")
    XCTAssertEqual(session.rawType, "end")
    XCTAssertFalse(events.contains {
      $0.kind == .message
        && ($0.text.contains("EndTurn")
          || $0.text.contains("b128b4ec-b797-4b86-9289-3bf58767deb1"))
    })
    XCTAssertFalse(events.contains { $0.kind == .failure })
    XCTAssertFalse(events.contains { $0.kind == .raw })
  }

  func testUnknownGrokEventTypeIsIgnored() {
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON)
    XCTAssertEqual(
      normalizer.consume(
        #"{"type":"future_event","data":"ignore safely"}"# + "\n"),
      [])
  }

  func testGrokSessionIdentifierIsCapturedOnlyFromEndEvent() {
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON)
    let events = normalizer.consume(
      #"{"type":"text","data":"ok","sessionId":"01a01ddb-f132-7651-bc5c-ba885cac01da"}"# + "\n")
    XCTAssertFalse(events.contains { $0.kind == .session })
    XCTAssertEqual(events.last?.kind, .message)
  }

  func testGrokErrorEventIsVisibleFailure() {
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON)
    let events = normalizer.consume(
      #"{"type":"error","message":"quota exhausted"}"# + "\n")

    XCTAssertEqual(events.map(\.kind), [.failure])
    XCTAssertEqual(events.first?.text, "quota exhausted")
    XCTAssertEqual(events.first?.rawType, "error")
  }

  func testGrokErrorEventWithoutMessageStillProducesVisibleFailure() {
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON)

    XCTAssertEqual(
      normalizer.consume(#"{"type":"error"}"# + "\n"),
      [
        TatwoNativeChatEvent(
          engine: .codex,
          kind: .failure,
          text: "[error]",
          rawType: "error")
      ])
  }

  func testHighFrequencyGrokTextChunksAreCoalescedWithoutLossOrReordering() {
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON)
    let chunks = Array("abcdefghijklmnopqrstuvwxyz").map {
      #"{"type":"text","data":"\#($0)"}"# + "\n"
    }

    let streamed = chunks.flatMap(normalizer.consume)
    let flushed = normalizer.flush()
    let messages = (streamed + flushed).filter { $0.kind == .message }

    XCTAssertLessThanOrEqual(messages.count, 2)
    XCTAssertEqual(messages.map(\.text).joined(), "abcdefghijklmnopqrstuvwxyz")
  }

  func testGrokEndEventImmediatelyFlushesPendingTextBeforeSession() throws {
    let normalizer = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON)

    XCTAssertEqual(
      normalizer.consume(#"{"type":"text","data":"warmup"}"# + "\n")
        .map(\.text),
      ["warmup"])
    XCTAssertEqual(
      normalizer.consume(#"{"type":"text","data":"partial"}"# + "\n"),
      [])
    let terminalEvents = normalizer.consume(
      #"{"type":"end","stopReason":"EndTurn","sessionId":"01a01ddb-f132-7651-bc5c-ba885cac01da"}"#
        + "\n")

    XCTAssertEqual(terminalEvents.map(\.kind), [.message, .session])
    XCTAssertEqual(terminalEvents.first?.text, "partial")
    XCTAssertEqual(
      try XCTUnwrap(terminalEvents.last?.sessionID),
      "01a01ddb-f132-7651-bc5c-ba885cac01da")
  }
}
