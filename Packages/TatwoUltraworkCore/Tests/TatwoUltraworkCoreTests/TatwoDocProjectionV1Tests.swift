import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDocProjectionV1Tests: XCTestCase {
  private let fixtureBody = """
    # fixture governance
    rule: single canonical writer
    """

  private let fixtureRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  // MARK: - Project happy path

  func testProjectEmitsHashRevisionHeaderAndBody() throws {
    let sources = [
      TatwoDocProjectionSourceV1(
        logicalName: "os.md",
        body: fixtureBody,
        sourceRevision: fixtureRevision,
        sourcePathForScopeCheck: "os/os.md")
    ]
    let projected = try TatwoDocProjectionV1.project(sources: sources)
    XCTAssertEqual(projected.count, 1)
    let doc = projected[0]
    XCTAssertEqual(doc.logicalName, "os.md")
    XCTAssertEqual(doc.sourceRevision, fixtureRevision)
    XCTAssertEqual(doc.body, fixtureBody)
    XCTAssertEqual(doc.sourceHash.count, 64)
    XCTAssertEqual(doc.sourceHash, TatwoDocProjectionV1.sha256Hex(of: fixtureBody))
    let hash12 = String(doc.sourceHash.prefix(12))
    XCTAssertEqual(doc.header, "此為唯讀投影，權威在 os.md@\(hash12)")
    XCTAssertTrue(doc.header.contains(hash12))
    XCTAssertTrue(doc.header.contains("os.md"))
  }

  // MARK: - Three-state verify

  func testVerifyInSyncWhenSourceUnchanged() throws {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "TODO.md",
      body: fixtureBody,
      sourceRevision: fixtureRevision)
    let doc = try TatwoDocProjectionV1.projectOne(source)
    let status = TatwoDocProjectionV1.verify(projected: doc, against: source)
    XCTAssertEqual(status, .inSync)
    XCTAssertEqual(status.wireLabel, "inSync")
  }

  func testVerifyStaleWhenSourceMoves() throws {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "issue.md",
      body: fixtureBody,
      sourceRevision: fixtureRevision)
    let doc = try TatwoDocProjectionV1.projectOne(source)
    let moved = TatwoDocProjectionSourceV1(
      logicalName: "issue.md",
      body: fixtureBody + "\n## new section\n",
      sourceRevision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    let status = TatwoDocProjectionV1.verify(projected: doc, against: moved)
    XCTAssertEqual(status, .stale(sourceMoved: true))
    XCTAssertEqual(status.wireLabel, "stale(sourceMoved)")
  }

  func testVerifyTamperedWhenLocalBodyEdited() throws {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "os.md",
      body: fixtureBody,
      sourceRevision: fixtureRevision)
    var doc = try TatwoDocProjectionV1.projectOne(source)
    // Simulate receiver editing projected body without updating hash.
    doc = TatwoProjectedDocV1(
      logicalName: doc.logicalName,
      sourceHash: doc.sourceHash,
      sourceRevision: doc.sourceRevision,
      projectedAt: doc.projectedAt,
      header: doc.header,
      body: doc.body + "\n# local edit\n")
    let status = TatwoDocProjectionV1.verify(projected: doc, against: source)
    XCTAssertEqual(status, .tampered(localEdited: true))
    XCTAssertEqual(status.wireLabel, "tampered(localEdited)")
  }

  func testVerifyPrefersTamperedOverStaleWhenBoth() throws {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "os.md",
      body: fixtureBody,
      sourceRevision: fixtureRevision)
    var doc = try TatwoDocProjectionV1.projectOne(source)
    doc = TatwoProjectedDocV1(
      logicalName: doc.logicalName,
      sourceHash: doc.sourceHash,
      sourceRevision: doc.sourceRevision,
      projectedAt: doc.projectedAt,
      header: doc.header,
      body: "totally different local body")
    let movedSource = TatwoDocProjectionSourceV1(
      logicalName: "os.md",
      body: "also moved source",
      sourceRevision: "cccccccccccccccccccccccccccccccccccccccc")
    let status = TatwoDocProjectionV1.verify(projected: doc, against: movedSource)
    // Local integrity fails first → tampered (no write-back; one-way).
    XCTAssertEqual(status, .tampered(localEdited: true))
  }

  // MARK: - One-way surface (no reverse API)

  func testOneWaySurfaceHasNoReverseAPIShape() throws {
    // Structural shape test: public projector API is project + verify only.
    // If a reverse write-back symbol is introduced, this inventory must grow
    // deliberately — not silently.
    let allowed = Set([
      "project",
      "projectOne",
      "verify",
      "parseRenderedFile",
      "makeHeader",
      "sha256Hex",
      "isThreadsForbiddenPath",
      "renderFile",
      "containsPrivateAbsolutePath",
      "schemaName",
      "fileMarker",
      "headerHashPrefixLength",
      "forbiddenPathTokens",
    ])
    let forbidden = [
      "writeBack",
      "writeBackToSource",
      "unproject",
      "pushToSource",
      "mergeBack",
      "applyLocalEdits",
      "syncToCanonical",
      "reverseProject",
    ]
    // Source inventory (compile-time path via string markers; no Mirror of enum methods).
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // Tests/...
      .deletingLastPathComponent() // TatwoUltraworkCoreTests
      .deletingLastPathComponent() // Tests
      .appendingPathComponent("Sources/TatwoUltraworkCore/TatwoDocProjectionV1.swift")
    let sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
    for name in forbidden {
      XCTAssertFalse(
        sourceText.contains("func \(name)"),
        "reverse API \(name) must not exist (one-way hard guarantee)")
      XCTAssertFalse(
        sourceText.contains("static func \(name)"),
        "reverse API \(name) must not exist")
    }
    // Positive: required forward APIs present.
    XCTAssertTrue(sourceText.contains("static func project("))
    XCTAssertTrue(sourceText.contains("static func verify("))
    XCTAssertTrue(sourceText.contains("one-way") || sourceText.contains("One-way"))
    // Keep allowed list honest for future maintainers.
    XCTAssertTrue(allowed.contains("project"))
    XCTAssertTrue(allowed.contains("verify"))
  }

  // MARK: - Header privacy (no private abs paths)

  func testHeaderContainsNoPrivateAbsolutePaths() throws {
    let privateLookingLogical = "os.md"
    let source = TatwoDocProjectionSourceV1(
      logicalName: privateLookingLogical,
      body: fixtureBody,
      sourceRevision: fixtureRevision,
      // Private path used only for scope check; must not leak into header.
      sourcePathForScopeCheck: "/Users/someone/Library/Application Support/secret/os.md")
    let doc = try TatwoDocProjectionV1.projectOne(source)
    XCTAssertFalse(TatwoDocProjectionV1.containsPrivateAbsolutePath(doc.header))
    XCTAssertFalse(doc.header.contains("/Users/"))
    XCTAssertFalse(doc.header.contains("/Volumes/"))
    XCTAssertFalse(doc.header.contains("Application Support"))
    XCTAssertFalse(doc.header.contains("someone"))
    // Rendered file must also stay clean of the private path.
    let rendered = doc.renderedFileText
    XCTAssertFalse(rendered.contains("/Users/someone"))
    XCTAssertFalse(TatwoDocProjectionV1.containsPrivateAbsolutePath(doc.header))
  }

  func testContainsPrivateAbsolutePathDetector() {
    XCTAssertTrue(
      TatwoDocProjectionV1.containsPrivateAbsolutePath(
        "權威在 /Users/example/secret/os.md@abc"))
    XCTAssertTrue(
      TatwoDocProjectionV1.containsPrivateAbsolutePath(
        "權威在 /Volumes/ExampleVolume/secret/os.md@abc"))
    XCTAssertFalse(
      TatwoDocProjectionV1.containsPrivateAbsolutePath(
        "此為唯讀投影，權威在 os.md@abcdef123456"))
  }

  // MARK: - Threads exclusion

  func testThreadsPathSourceRejected() {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "chat.md",
      body: fixtureBody,
      sourceRevision: fixtureRevision,
      sourcePathForScopeCheck: "state/threads/abc.thread.json")
    XCTAssertThrowsError(try TatwoDocProjectionV1.projectOne(source)) { error in
      guard case .threadsSourceForbidden = error as? TatwoDocProjectionErrorV1 else {
        return XCTFail("expected threadsSourceForbidden, got \(error)")
      }
    }
  }

  func testThreadTokenInLogicalNameRejected() {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "my.thread",
      body: fixtureBody,
      sourceRevision: fixtureRevision)
    XCTAssertThrowsError(try TatwoDocProjectionV1.projectOne(source)) { error in
      guard case .threadsSourceForbidden = error as? TatwoDocProjectionErrorV1 else {
        return XCTFail("expected threadsSourceForbidden, got \(error)")
      }
    }
  }

  func testThreadsDirectoryPathRejected() {
    XCTAssertTrue(TatwoDocProjectionV1.isThreadsForbiddenPath("foo/threads/bar.md"))
    XCTAssertTrue(TatwoDocProjectionV1.isThreadsForbiddenPath("x.thread"))
    XCTAssertTrue(TatwoDocProjectionV1.isThreadsForbiddenPath("Chat.Threads/id"))
    XCTAssertFalse(TatwoDocProjectionV1.isThreadsForbiddenPath("os/os.md"))
    XCTAssertFalse(TatwoDocProjectionV1.isThreadsForbiddenPath("docs/protocol/TODO.md"))
  }

  // MARK: - Round-trip render / parse

  func testRenderParseRoundTripPreservesFields() throws {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "os.md",
      body: fixtureBody,
      sourceRevision: fixtureRevision)
    let doc = try TatwoDocProjectionV1.projectOne(source)
    let rendered = TatwoDocProjectionV1.renderFile(from: doc)
    let parsed = try TatwoDocProjectionV1.parseRenderedFile(rendered)
    XCTAssertEqual(parsed.logicalName, doc.logicalName)
    XCTAssertEqual(parsed.sourceHash, doc.sourceHash)
    XCTAssertEqual(parsed.sourceRevision, doc.sourceRevision)
    XCTAssertEqual(parsed.header, doc.header)
    XCTAssertEqual(parsed.body, doc.body)
    XCTAssertEqual(
      TatwoDocProjectionV1.verify(projected: parsed, against: source),
      .inSync)
  }

  // MARK: - Fail-closed inputs

  func testEmptyLogicalNameFails() {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "  ",
      body: fixtureBody,
      sourceRevision: fixtureRevision)
    XCTAssertThrowsError(try TatwoDocProjectionV1.projectOne(source)) { error in
      XCTAssertEqual(error as? TatwoDocProjectionErrorV1, .emptyLogicalName)
    }
  }

  func testEmptyRevisionFails() {
    let source = TatwoDocProjectionSourceV1(
      logicalName: "os.md",
      body: fixtureBody,
      sourceRevision: "")
    XCTAssertThrowsError(try TatwoDocProjectionV1.projectOne(source)) { error in
      XCTAssertEqual(error as? TatwoDocProjectionErrorV1, .emptySourceRevision)
    }
  }
}
