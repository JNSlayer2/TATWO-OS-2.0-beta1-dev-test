import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDispatchLedgerReaderCoreTests: XCTestCase {
  private let fileManager = FileManager.default

  func testReadEntriesDecodesMultipleLinesNewestFirst() throws {
    let ledgerURL = temporaryLedgerURL()
    defer { try? fileManager.removeItem(at: ledgerURL.deletingLastPathComponent()) }
    try writeLedger(
      [
        jsonLine(
          id: "older",
          label: "Older loop",
          model: "gpt-5.6-sol",
          status: "done",
          startedAt: "2026-07-12T01:00:00Z",
          endedAt: "2026-07-12T01:10:00Z",
          note: "complete"),
        jsonLine(
          id: "newer",
          label: "Newer loop",
          model: "gpt-5.6-sol",
          status: "running",
          startedAt: "2026-07-12T02:00:00.500Z"),
      ],
      to: ledgerURL)

    let entries = TatwoDispatchLedgerReader(ledgerURL: ledgerURL).readEntries()

    XCTAssertEqual(entries.map(\.id), ["newer", "older"])
    XCTAssertEqual(entries.first?.label, "Newer loop")
    XCTAssertEqual(entries.last?.endedAt, isoDate("2026-07-12T01:10:00Z"))
    XCTAssertEqual(entries.last?.note, "complete")
  }

  func testReadEntriesSkipsMalformedAndSchemaInvalidLines() throws {
    let ledgerURL = temporaryLedgerURL()
    defer { try? fileManager.removeItem(at: ledgerURL.deletingLastPathComponent()) }
    try writeLedger(
      [
        "{not-json",
        jsonLine(
          id: "invalid-status",
          label: "Invalid",
          model: "gpt-5.6-sol",
          status: "queued",
          startedAt: "2026-07-12T03:00:00Z"),
        jsonLine(
          id: "valid",
          label: "Valid",
          model: "gpt-5.6-sol",
          status: "dispatched",
          startedAt: "2026-07-12T04:00:00Z"),
      ],
      to: ledgerURL)

    XCTAssertEqual(
      TatwoDispatchLedgerReader(ledgerURL: ledgerURL).readEntries().map(\.id),
      ["valid"])
  }

  func testReadSeparatesActiveAndRecentEntries() throws {
    let ledgerURL = temporaryLedgerURL()
    defer { try? fileManager.removeItem(at: ledgerURL.deletingLastPathComponent()) }
    try writeLedger(
      [
        jsonLine(
          id: "failed",
          label: "Failed",
          model: "gpt-5.6-sol",
          status: "failed",
          startedAt: "2026-07-12T01:00:00Z"),
        jsonLine(
          id: "dispatched",
          label: "Dispatched",
          model: "gpt-5.6-sol",
          status: "dispatched",
          startedAt: "2026-07-12T02:00:00Z"),
        jsonLine(
          id: "done",
          label: "Done",
          model: "gpt-5.6-sol",
          status: "done",
          startedAt: "2026-07-12T03:00:00Z"),
        jsonLine(
          id: "running",
          label: "Running",
          model: "gpt-5.6-sol",
          status: "running",
          startedAt: "2026-07-12T04:00:00Z"),
      ],
      to: ledgerURL)

    let result = TatwoDispatchLedgerReader(ledgerURL: ledgerURL).read()

    XCTAssertEqual(result.entries.map(\.id), ["running", "done", "dispatched", "failed"])
    XCTAssertEqual(result.active.map(\.id), ["running", "dispatched"])
    XCTAssertEqual(result.recent.map(\.id), ["done", "failed"])
  }

  func testMissingLedgerReturnsEmptyWithoutThrowing() {
    let ledgerURL = temporaryLedgerURL()

    let result = TatwoDispatchLedgerReader(ledgerURL: ledgerURL).read()

    XCTAssertEqual(
      TatwoDispatchLedgerReader.defaultLedgerURL.path,
      fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".tatwo-ultrawork/dispatch-ledger.jsonl").path)
    XCTAssertEqual(result.entries, [])
    XCTAssertEqual(result.active, [])
    XCTAssertEqual(result.recent, [])
  }

  func testEntryIsCodableIdentifiableAndSendable() throws {
    let entry = TatwoDispatchLedgerEntry(
      id: "dispatch-1",
      label: "Sol loop",
      model: "gpt-5.6-sol",
      status: .running,
      startedAt: isoDate("2026-07-12T05:00:00Z"),
      endedAt: nil,
      note: nil)

    let decoded = try JSONDecoder().decode(
      TatwoDispatchLedgerEntry.self,
      from: JSONEncoder().encode(entry))

    XCTAssertEqual(decoded, entry)
    XCTAssertEqual(decoded.id, "dispatch-1")
    assertSendable(decoded)
  }

  private func temporaryLedgerURL() -> URL {
    fileManager.temporaryDirectory
      .appendingPathComponent("tatwo-dispatch-ledger-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("dispatch-ledger.jsonl")
  }

  private func writeLedger(_ lines: [String], to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n")
      .write(to: url, atomically: true, encoding: .utf8)
  }

  private func jsonLine(
    id: String,
    label: String,
    model: String,
    status: String,
    startedAt: String,
    endedAt: String? = nil,
    note: String? = nil
  ) -> String {
    var object: [String: Any] = [
      "id": id,
      "label": label,
      "model": model,
      "status": status,
      "startedAt": startedAt,
    ]
    object["endedAt"] = endedAt
    object["note"] = note
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  private func isoDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
