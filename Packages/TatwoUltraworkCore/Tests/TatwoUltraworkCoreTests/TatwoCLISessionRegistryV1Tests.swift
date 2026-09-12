import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoCLISessionRegistryV1Tests: XCTestCase {
  private var tempRoot: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-cli-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot {
      try? FileManager.default.removeItem(at: tempRoot)
    }
    tempRoot = nil
    try super.tearDownWithError()
  }

  private func makeRegistry() -> TatwoCLISessionRegistryV1 {
    TatwoCLISessionRegistryV1(rootURL: tempRoot)
  }

  // MARK: - Multi-engine classification

  func testMultiEngineClassificationAndMultiOpen() throws {
    let registry = makeRegistry()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    try registry.register(engine: .codex, title: "Codex A", workdir: "/tmp/a", at: t0)
    try registry.register(engine: .codex, title: "Codex B", at: t0.addingTimeInterval(1))
    try registry.register(engine: .claude, title: "Claude R", at: t0.addingTimeInterval(2))
    try registry.register(engine: .openclaw, title: "Claw", at: t0.addingTimeInterval(3))
    try registry.register(engine: .grok, title: "Grok", at: t0.addingTimeInterval(4))
    try registry.register(
      engine: .sandbox,
      title: "Sandbox",
      tags: ["iso", "iso", " trial "],
      at: t0.addingTimeInterval(5))

    let all = try registry.allSessions()
    XCTAssertEqual(all.count, 6)

    XCTAssertEqual(try registry.sessions(engine: .codex).count, 2)
    XCTAssertEqual(try registry.sessions(engine: .claude).map(\.title), ["Claude R"])
    XCTAssertEqual(try registry.sessions(engine: .openclaw).count, 1)
    XCTAssertEqual(try registry.sessions(engine: .grok).count, 1)

    let sandbox = try registry.sessions(engine: .sandbox)
    XCTAssertEqual(sandbox.count, 1)
    XCTAssertEqual(sandbox[0].tags, ["iso", "trial"])
    XCTAssertEqual(sandbox[0].state, .active)
  }

  // MARK: - Persistent round-trip

  func testPersistentRoundTripViaInjectedRoot() throws {
    let registry = makeRegistry()
    let t0 = Date(timeIntervalSince1970: 1_700_000_100)

    let created = try registry.register(
      engine: .claude,
      title: "Persist me",
      workdir: "/workspace/proj",
      tags: ["p2"],
      id: "sess-fixed-1",
      at: t0)
    _ = try registry.markIdle(id: created.id, at: t0.addingTimeInterval(10))

    // New instance on same injected root must reload disk state.
    let reloaded = TatwoCLISessionRegistryV1(rootURL: tempRoot)
    let session = try reloaded.session(id: "sess-fixed-1")
    XCTAssertEqual(session.engine, .claude)
    XCTAssertEqual(session.title, "Persist me")
    XCTAssertEqual(session.workdir, "/workspace/proj")
    XCTAssertEqual(session.tags, ["p2"])
    XCTAssertEqual(session.state, .idle)
    XCTAssertEqual(session.createdAt, t0)
    XCTAssertEqual(session.lastActiveAt, t0.addingTimeInterval(10))

    // Convenience init with injected App Support base (no hard-coded home).
    let supportBase = tempRoot.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: supportBase, withIntermediateDirectories: true)
    let viaLayout = TatwoCLISessionRegistryV1(
      environment: [:],
      applicationSupportBase: supportBase)
    _ = try viaLayout.register(engine: .grok, title: "Layout rooted", at: t0)
    let expectedRoot = TatwoRuntimeLayout.applicationSupportRoot(
      environment: [:],
      applicationSupportBase: supportBase)
    XCTAssertEqual(viaLayout.rootURL, expectedRoot.standardizedFileURL)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: viaLayout.fileURL.path),
      "registry must persist under injected App Support root")
  }

  // MARK: - Prune iron rule

  func testPruneOnlyRemovesStaleExitedNeverActiveOrIdle() throws {
    let registry = makeRegistry()
    let t0 = Date(timeIntervalSince1970: 1_700_000_200)
    let cutoff = t0.addingTimeInterval(1_000)

    let activeID = try registry.register(
      engine: .codex, title: "Running", id: "active-1", at: t0).id
    let idleID = try registry.register(
      engine: .claude, title: "Idle keep", id: "idle-1", at: t0).id
    _ = try registry.markIdle(id: idleID, at: t0.addingTimeInterval(5))

    let staleExitedID = try registry.register(
      engine: .grok, title: "Old exit", id: "exit-old", at: t0).id
    _ = try registry.markExited(id: staleExitedID, at: t0.addingTimeInterval(20))

    let freshExitedID = try registry.register(
      engine: .sandbox, title: "New exit", id: "exit-new", at: t0).id
    _ = try registry.markExited(
      id: freshExitedID,
      at: cutoff.addingTimeInterval(50))

    // Touch active so lastActiveAt is still well below cutoff — must still survive.
    _ = try registry.touch(id: activeID, at: t0.addingTimeInterval(30))

    let removed = try registry.prune(olderThan: cutoff)
    XCTAssertEqual(removed.map(\.id).sorted(), ["exit-old"])

    let remainingIDs = try registry.allSessions().map(\.id).sorted()
    XCTAssertEqual(remainingIDs, ["active-1", "exit-new", "idle-1"])

    XCTAssertEqual(try registry.session(id: activeID).state, .active)
    XCTAssertEqual(try registry.session(id: idleID).state, .idle)
    XCTAssertEqual(try registry.session(id: freshExitedID).state, .exited)
  }

  func testTouchPromotesIdleToActiveAndRejectsExited() throws {
    let registry = makeRegistry()
    let t0 = Date(timeIntervalSince1970: 1_700_000_300)
    let id = try registry.register(engine: .openclaw, title: "Claw", at: t0).id
    _ = try registry.markIdle(id: id, at: t0.addingTimeInterval(1))
    let touched = try registry.touch(id: id, at: t0.addingTimeInterval(2))
    XCTAssertEqual(touched.state, .active)
    XCTAssertEqual(touched.lastActiveAt, t0.addingTimeInterval(2))

    _ = try registry.markExited(id: id, at: t0.addingTimeInterval(3))
    XCTAssertThrowsError(try registry.touch(id: id, at: t0.addingTimeInterval(4))) { error in
      XCTAssertEqual(
        error as? TatwoCLISessionRegistryErrorV1,
        .cannotMutateExited(id))
    }
  }

  // MARK: - Corrupt file fail-closed

  func testCorruptFileFailClosed() throws {
    let registry = makeRegistry()
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

    // Truncated / garbage JSON
    try Data("{not-json".utf8).write(to: registry.fileURL)
    XCTAssertThrowsError(try registry.allSessions()) { error in
      guard case TatwoCLISessionRegistryErrorV1.corruptDocument = error else {
        return XCTFail("expected corruptDocument, got \(error)")
      }
    }

    // Empty file
    try Data().write(to: registry.fileURL)
    XCTAssertThrowsError(try registry.allSessions()) { error in
      guard case TatwoCLISessionRegistryErrorV1.corruptDocument = error else {
        return XCTFail("expected corruptDocument for empty, got \(error)")
      }
    }

    // Valid JSON but wrong schema
    let badSchema = """
      {"schema":"WrongSchemaV0","sessions":[]}
      """
    try Data(badSchema.utf8).write(to: registry.fileURL)
    XCTAssertThrowsError(try registry.allSessions()) { error in
      XCTAssertEqual(
        error as? TatwoCLISessionRegistryErrorV1,
        .schemaMismatch("WrongSchemaV0"))
    }

    // Missing file is empty (not corrupt)
    try FileManager.default.removeItem(at: registry.fileURL)
    XCTAssertEqual(try registry.allSessions(), [])
  }

  func testEnginesMatchOsmd94ClassificationSet() {
    let engines = Set(TatwoCLISessionEngineV1.allCases.map(\.rawValue))
    XCTAssertEqual(
      engines,
      Set(["codex", "claude", "openclaw", "grok", "sandbox"]))
  }
}
