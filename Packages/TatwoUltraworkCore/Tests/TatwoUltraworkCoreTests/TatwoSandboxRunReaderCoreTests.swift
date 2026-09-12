import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoSandboxRunReaderCoreTests: XCTestCase {
  private let fileManager = FileManager.default

  func testListRunsReturnsReceiptMetadataNewestFirst() throws {
    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }

    let older = try makeRun(
      root: root,
      sandboxType: "Debug沙盒",
      runID: "older-run",
      modifiedAt: Date(timeIntervalSince1970: 100))
    try write("{}", to: older.appendingPathComponent("summary.json"))
    try write("{}", to: older.appendingPathComponent("case/model/評分報告.json"))

    let newer = try makeRun(
      root: root,
      sandboxType: "網頁設計沙盒",
      runID: "newer-run",
      modifiedAt: Date(timeIntervalSince1970: 200))
    try write("{}", to: newer.appendingPathComponent("summary.json"))
    try write("{}", to: newer.appendingPathComponent("case/model/final-submission/seal.json"))

    let runs = TatwoSandboxRunReader(rootURL: root).listRuns()

    XCTAssertEqual(runs.map(\.runID), ["newer-run", "older-run"])
    XCTAssertEqual(runs.map(\.sandboxType), ["網頁設計沙盒", "Debug沙盒"])
    XCTAssertEqual(runs.map(\.id), ["網頁設計沙盒/newer-run", "Debug沙盒/older-run"])
    XCTAssertEqual(runs.map(\.hasSummary), [true, true])
    XCTAssertEqual(runs.map(\.hasSeal), [true, false])
    XCTAssertEqual(runs.map(\.hasScoreReport), [false, true])
  }

  func testReadSummaryReturnsExactJSONAndRejectsInvalidOrMissingRuns() throws {
    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }
    let runURL = try makeRun(
      root: root,
      sandboxType: "研究查證沙盒",
      runID: "research-1",
      modifiedAt: Date())
    let summary = "{\n  \"schema\": \"FixtureSummaryV1\"\n}\n"
    try write(summary, to: runURL.appendingPathComponent("summary.json"))

    let reader = TatwoSandboxRunReader(rootURL: root)
    let run = try XCTUnwrap(reader.listRuns().first)

    XCTAssertEqual(reader.readSummary(for: run), summary)
    XCTAssertNil(reader.readSummary(sandboxType: "研究查證沙盒", runID: "../escape"))
    XCTAssertNil(reader.readSummary(sandboxType: "unknown", runID: "research-1"))
    XCTAssertNil(reader.readSummary(sandboxType: "研究查證沙盒", runID: "missing"))
  }

  func testMissingRootAndEmptySandboxTypesReturnNoRuns() throws {
    let missing = fileManager.temporaryDirectory
      .appendingPathComponent("missing-sandbox-\(UUID().uuidString)", isDirectory: true)
    XCTAssertEqual(TatwoSandboxRunReader(rootURL: missing).listRuns(), [])

    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
      at: root.appendingPathComponent("代碼架構沙盒", isDirectory: true),
      withIntermediateDirectories: true)
    XCTAssertEqual(TatwoSandboxRunReader(rootURL: root).listRuns(), [])
  }

  func testListIgnoresUnknownFoldersFilesAndSymlinkedRuns() throws {
    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
      at: root.appendingPathComponent("not-a-sandbox/run", isDirectory: true),
      withIntermediateDirectories: true)
    try write(
      "not a run",
      to: root.appendingPathComponent("Debug沙盒/README.md"))

    let outside = fileManager.temporaryDirectory
      .appendingPathComponent("outside-run-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: outside) }
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(
      at: root.appendingPathComponent("Debug沙盒/symlink-run"),
      withDestinationURL: outside)

    XCTAssertEqual(TatwoSandboxRunReader(rootURL: root).listRuns(), [])
  }

  func testTatwoSandboxRunIsCodableSendableValue() throws {
    let run = TatwoSandboxRun(
      runID: "run-1",
      sandboxType: "多模態理解沙盒",
      modifiedAt: Date(timeIntervalSince1970: 123),
      hasSummary: true,
      hasSeal: true,
      hasScoreReport: false)

    let decoded = try JSONDecoder().decode(
      TatwoSandboxRun.self,
      from: JSONEncoder().encode(run))

    XCTAssertEqual(decoded, run)
    assertSendable(decoded)
  }

  private func makeRoot() throws -> URL {
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("tatwo-sandbox-reader-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeRun(
    root: URL,
    sandboxType: String,
    runID: String,
    modifiedAt: Date
  ) throws -> URL {
    let runURL = root
      .appendingPathComponent(sandboxType, isDirectory: true)
      .appendingPathComponent(runID, isDirectory: true)
    try fileManager.createDirectory(at: runURL, withIntermediateDirectories: true)
    try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: runURL.path)
    return runURL
  }

  private func write(_ string: String, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try string.write(to: url, atomically: true, encoding: .utf8)
  }

  private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
