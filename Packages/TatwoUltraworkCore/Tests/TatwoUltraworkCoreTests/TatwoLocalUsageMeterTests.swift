import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoLocalUsageMeterTests: XCTestCase {
  func testRecordsOneRequestWithOptionalTokens() async throws {
    let fixture = makeFixture()
    let meter = TatwoLocalUsageMeter(
      fileURL: fixture.fileURL,
      now: fixture.clock.now)

    await meter.record(
      provider: "minimax",
      inputTokens: 120,
      outputTokens: 45)

    let snapshot = await meter.snapshot(provider: "minimax")
    XCTAssertEqual(snapshot.fiveHour.requestCount, 1)
    XCTAssertEqual(snapshot.fiveHour.inputTokens, 120)
    XCTAssertEqual(snapshot.fiveHour.outputTokens, 45)
    XCTAssertEqual(snapshot.fiveHour.totalTokens, 165)
    XCTAssertEqual(snapshot.sevenDay, snapshot.fiveHour)
  }

  func testAggregatesFiveHourAndSevenDayWindows() async throws {
    let fixture = makeFixture()
    let meter = TatwoLocalUsageMeter(
      fileURL: fixture.fileURL,
      now: fixture.clock.now)

    await meter.record(
      provider: "grok")
    fixture.clock.advance(by: 6 * 60 * 60)
    await meter.record(
      provider: "grok")
    await meter.record(
      provider: "minimax",
      inputTokens: 10,
      outputTokens: 20)

    let grok = await meter.snapshot(provider: "grok")
    XCTAssertEqual(grok.fiveHour.requestCount, 1)
    XCTAssertNil(grok.fiveHour.totalTokens)
    XCTAssertEqual(grok.sevenDay.requestCount, 2)
    XCTAssertNil(grok.sevenDay.totalTokens)
  }

  func testPersistenceRoundTrip() async throws {
    let fixture = makeFixture()
    let first = TatwoLocalUsageMeter(
      fileURL: fixture.fileURL,
      now: fixture.clock.now)
    await first.record(
      provider: "claude",
      inputTokens: 33,
      outputTokens: 44)

    let reloaded = TatwoLocalUsageMeter(
      fileURL: fixture.fileURL,
      now: fixture.clock.now)
    let snapshot = await reloaded.snapshot(provider: "claude")

    XCTAssertEqual(snapshot.sevenDay.requestCount, 1)
    XCTAssertEqual(snapshot.sevenDay.totalTokens, 77)
  }

  func testPrunesRecordsOlderThanThirtyDays() async throws {
    let fixture = makeFixture()
    let meter = TatwoLocalUsageMeter(
      fileURL: fixture.fileURL,
      now: fixture.clock.now)
    await meter.record(provider: "codex-gpt")

    fixture.clock.advance(
      by: TatwoLocalUsageMeter.retentionWindow + 1)
    await meter.record(provider: "codex-gpt")

    let records = await meter.allRecords()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.provider, "codex-gpt")

    let reloaded = TatwoLocalUsageMeter(
      fileURL: fixture.fileURL,
      now: fixture.clock.now)
    let snapshot = await reloaded.snapshot(
      provider: "codex-gpt")
    XCTAssertEqual(snapshot.sevenDay.requestCount, 1)
  }

  func testChatStreamCompletionEventsMapCodexClaudeAndGrokUsage() {
    let recorder = LocalUsageEventRecorder()
    let codex = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      usageRecorder: recorder.record)
    let claude = TatwoNativeChatStreamNormalizer(
      engine: .claude,
      usageRecorder: recorder.record)
    let grok = TatwoNativeChatStreamNormalizer(
      engine: .codex,
      streamFormat: .grokStreamingJSON,
      usageRecorder: recorder.record)

    _ = codex.consume(
      #"{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":7}}"#
        + "\n")
    _ = claude.consume(
      #"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":20,"output_tokens":9}}"#
        + "\n")
    _ = grok.consume(
      #"{"type":"end","sessionId":"grok-session-123"}"#
        + "\n")

    XCTAssertEqual(recorder.values, [
      .init(
        provider: "codex-gpt",
        inputTokens: 12,
        outputTokens: 7),
      .init(
        provider: "claude",
        inputTokens: 20,
        outputTokens: 9),
      .init(
        provider: "grok",
        inputTokens: nil,
        outputTokens: nil),
    ])
  }

  private func makeFixture() -> (
    fileURL: URL,
    clock: LocalUsageTestClock
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "tatwo-local-usage-\(UUID().uuidString)",
        isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return (
      directory.appendingPathComponent("usage.json"),
      LocalUsageTestClock())
  }
}

private final class LocalUsageEventRecorder:
  @unchecked Sendable
{
  struct Value: Equatable {
    let provider: String
    let inputTokens: Int?
    let outputTokens: Int?
  }

  private let lock = NSLock()
  private var storedValues: [Value] = []

  var values: [Value] {
    lock.withLock { storedValues }
  }

  func record(
    provider: String,
    inputTokens: Int?,
    outputTokens: Int?
  ) {
    lock.withLock {
      storedValues.append(Value(
        provider: provider,
        inputTokens: inputTokens,
        outputTokens: outputTokens))
    }
  }
}

private final class LocalUsageTestClock:
  @unchecked Sendable
{
  private let lock = NSLock()
  private var date = Date(
    timeIntervalSince1970: 1_800_000_000)

  func now() -> Date {
    lock.withLock { date }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock {
      date = date.addingTimeInterval(interval)
    }
  }
}
