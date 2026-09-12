import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoGBrainReaderCoreTests: XCTestCase {
  private let fileManager = FileManager.default

  func testListReturnsCuratedAndTruthMetadataOnly() throws {
    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }

    let curated = root.appendingPathComponent("curated", isDirectory: true)
    let truth = root.appendingPathComponent("truth", isDirectory: true)
    try fileManager.createDirectory(at: curated, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: truth, withIntermediateDirectories: true)

    let curatedFile = curated.appendingPathComponent("memory.md")
    let truthFile = truth.appendingPathComponent("facts.json")
    try "# Curated memory\nBody".write(to: curatedFile, atomically: true, encoding: .utf8)
    try "{\n  \"fact\": true\n}".write(to: truthFile, atomically: true, encoding: .utf8)
    try "ignore".write(
      to: curated.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)

    let result = TatwoGBrainReader(rootURL: root).list()

    XCTAssertEqual(result.status, .available)
    XCTAssertEqual(result.entries.count, 2)
    XCTAssertEqual(
      result.entries.map(\.relativePath),
      ["curated/memory.md", "truth/facts.json"])

    let curatedEntry = try XCTUnwrap(result.entries.first)
    XCTAssertEqual(curatedEntry.fileName, "memory.md")
    XCTAssertEqual(curatedEntry.title, "Curated memory")
    XCTAssertEqual(curatedEntry.layer, .curated)
    XCTAssertGreaterThan(curatedEntry.size, 0)
    XCTAssertLessThanOrEqual(curatedEntry.modifiedAt, Date())

    let truthEntry = try XCTUnwrap(result.entries.last)
    XCTAssertEqual(truthEntry.title, "facts")
    XCTAssertEqual(truthEntry.layer, .truth)
  }

  func testListMissingRootReturnsEmptyStatusWithoutThrowing() {
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("missing-gbrain-\(UUID().uuidString)", isDirectory: true)

    let result = TatwoGBrainReader(rootURL: root).list()

    XCTAssertEqual(result.status, .rootMissing)
    XCTAssertTrue(result.entries.isEmpty)
  }

  func testListEmptyOrMissingLayersReturnsAvailableEmptyResult() throws {
    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
      at: root.appendingPathComponent("curated", isDirectory: true),
      withIntermediateDirectories: true)

    let result = TatwoGBrainReader(rootURL: root).list()

    XCTAssertEqual(result.status, .available)
    XCTAssertTrue(result.entries.isEmpty)
  }

  func testReadReturnsLocalContentAndRejectsPathsOutsideReadableLayers() throws {
    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }
    let file = root.appendingPathComponent("truth/local.md")
    try fileManager.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "# Local only\nsecret".write(to: file, atomically: true, encoding: .utf8)

    let reader = TatwoGBrainReader(rootURL: root)
    let read = reader.read(entryPath: "truth/local.md")
    let rejected = reader.read(entryPath: "../outside.md")

    XCTAssertEqual(read.status, .available)
    XCTAssertEqual(read.content, "# Local only\nsecret")
    XCTAssertFalse(read.truncated)
    XCTAssertEqual(rejected.status, .invalidPath)
    XCTAssertEqual(rejected.content, "")
  }

  func testReadTruncatesOversizedFileAtConfiguredByteLimit() throws {
    let root = try makeRoot()
    defer { try? fileManager.removeItem(at: root) }
    let file = root.appendingPathComponent("curated/large.md")
    try fileManager.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: Character("a").asciiValue!, count: 40).write(to: file)

    let read = TatwoGBrainReader(rootURL: root, maximumReadBytes: 16)
      .read(entryPath: "curated/large.md")

    XCTAssertEqual(read.status, .available)
    XCTAssertEqual(read.content, String(repeating: "a", count: 16))
    XCTAssertTrue(read.truncated)
  }

  private func makeRoot() throws -> URL {
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("tatwo-gbrain-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
