import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ContextCompressionTests: XCTestCase {
  func testLogCompressionPreservesFatalSignalAndCanRetrieveOriginal() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let log = (0..<120).map { index in
      if index == 57 {
        return "2026-07-07T19:20:00Z FATAL deploy failed because bundle hash mismatched"
      }
      return "2026-07-07T19:19:\(String(format: "%02d", index % 60))Z INFO step \(index) ok"
    }.joined(separator: "\n")

    let receipt = try TatwoContextCompressionFactory.compress(
      text: log,
      kind: .auto,
      sourceLabel: "build.log",
      runID: "test-run",
      root: root,
      policy: .init(maxCompressedCharacters: 1_800))

    XCTAssertEqual(receipt.kind, .log)
    XCTAssertTrue(receipt.reversible)
    XCTAssertTrue(receipt.compressedText.contains("FATAL deploy failed"))
    XCTAssertTrue(receipt.reductionRatio > 0)
    XCTAssertTrue(receipt.estimatedCompressedTokens < receipt.estimatedOriginalTokens)

    let retrieved = try TatwoContextCompressionFactory.retrieve(
      id: receipt.id,
      root: root,
      runID: "test-run")
    XCTAssertEqual(retrieved.text, log)
    XCTAssertEqual(retrieved.originalSHA256, receipt.originalSHA256)
  }

  func testJSONCompressionPreservesShapeAndDiagnosticFields() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let json = """
      {
        "status": "failed",
        "message": "route refused",
        "items": [
          { "id": "a", "path": "/tmp/tatwo2-fixture/private/file.swift", "ok": false }
        ],
        "metadata": { "attempt": 3, "provider": "local" }
      }
      """

    let receipt = try TatwoContextCompressionFactory.compress(
      text: json,
      kind: .json,
      sourceLabel: "gateway-response.json",
      runID: "json-run",
      root: root)

    XCTAssertEqual(receipt.kind, .json)
    XCTAssertTrue(receipt.compressedText.contains("$.items: array count=1"))
    XCTAssertTrue(receipt.compressedText.contains("$.message: string"))
    XCTAssertFalse(receipt.compressedText.contains("/tmp/tatwo2-fixture/private"))
    XCTAssertTrue(receipt.compressedText.contains("<local-path>"))
  }

  func testSensitiveContentRejectedByDefault() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(
      try TatwoContextCompressionFactory.compress(
        text: "access_token=abc123 refresh_token=def456",
        kind: .text,
        root: root)
    ) { error in
      guard case TatwoContextCompressionError.sensitiveContent(let findings) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertFalse(findings.isEmpty)
    }
  }

  func testStatsAggregatesReceipts() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try TatwoContextCompressionFactory.compress(
      text: "ERROR one\n" + String(repeating: "info line\n", count: 80),
      kind: .log,
      runID: "stats",
      root: root)
    _ = try TatwoContextCompressionFactory.compress(
      text: "# Title\n\n- must keep receipts\n" + String(repeating: "body text ", count: 200),
      kind: .text,
      runID: "stats",
      root: root)

    let stats = try TatwoContextCompressionFactory.stats(root: root)
    XCTAssertEqual(stats.receiptCount, 2)
    XCTAssertEqual(stats.byKind["log"], 1)
    XCTAssertEqual(stats.byKind["text"], 1)
    XCTAssertTrue(stats.originalBytes > stats.compressedBytes)
  }

  func testMCPRetrieveWithoutRunIDIsScopedToContractID() throws {
    let root = temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let previousCWD = FileManager.default.currentDirectoryPath
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))
    defer {
      _ = FileManager.default.changeCurrentDirectoryPath(previousCWD)
      try? FileManager.default.removeItem(at: root)
    }

    let contractA = "contract-m-coding-\(UUID().uuidString.lowercased())"
    let contractB = "contract-m-coding-\(UUID().uuidString.lowercased())"
    let compress = TatwoMCPRegistry.call(
      tool: "tatwo.context.compress",
      arguments: [
        "contractID": .string(contractA),
        "text": .string("INFO ok\nERROR scoped retrieve should stay in contract A\nINFO done"),
        "kind": .string("log"),
      ])
    XCTAssertTrue(compress.ok, compress.error ?? "")
    guard case .object(let compressedPayload)? = compress.payload,
      case .string(let id)? = compressedPayload["id"]
    else {
      return XCTFail("expected context compression id")
    }

    let crossContractRetrieve = TatwoMCPRegistry.call(
      tool: "tatwo.context.retrieve",
      arguments: [
        "contractID": .string(contractB),
        "id": .string(id),
      ])
    XCTAssertFalse(crossContractRetrieve.ok)

    let owningContractRetrieve = TatwoMCPRegistry.call(
      tool: "tatwo.context.retrieve",
      arguments: [
        "contractID": .string(contractA),
        "id": .string(id),
      ])
    XCTAssertTrue(owningContractRetrieve.ok, owningContractRetrieve.error ?? "")
  }

  private func temporaryRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-context-tests-\(UUID().uuidString)", isDirectory: true)
  }
}
