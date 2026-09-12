import XCTest
@testable import TatwoUltraworkCore

final class TatwoIndependenceCoreTests: XCTestCase {
  func testCapabilityBootstrapUsesTatwoCanonicalRootAndCodexOnlyAsImport() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("home/.codex/skills/tatwo-ultrawork")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("# skill".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    let environment = [
      "HOME": root.appendingPathComponent("home").path,
      "TATWO_ULTRAWORK_APP_SUPPORT": root.appendingPathComponent("support").path,
    ]
    let receipt = try TatwoCapabilityRegistry.bootstrap(environment: environment)
    XCTAssertEqual(receipt.imported, ["tatwo-ultrawork"])
    XCTAssertEqual(receipt.available, ["tatwo-ultrawork"])
    XCTAssertTrue(receipt.canonicalRoot.contains("capabilities/skills"))
    let status = TatwoCapabilityRegistry.status(environment: environment)
    XCTAssertEqual(status.availableSkills, ["tatwo-ultrawork"])
    XCTAssertFalse(status.roots.canonicalSkillRoot.contains(".codex"))
  }

  func testAppSnapshotDoesNotImplicitlyBootstrapCapabilities() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-snapshot-no-bootstrap-\(UUID().uuidString)")
    let support = root.appendingPathComponent("support", isDirectory: true)
    let environment = [
      "HOME": root.appendingPathComponent("home", isDirectory: true).path,
      "TATWO_ULTRAWORK_APP_SUPPORT": support.path,
      "TATWO_ULTRAWORK_STATE_DIR":
        root.appendingPathComponent("state", isDirectory: true).path,
    ]

    _ = TatwoAppSnapshotFactory.makeCurrent(environment: environment)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: support.appendingPathComponent("capabilities/skills").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: support.appendingPathComponent("capabilities/plugins").path))
  }

  func testDefaultRegistryExposesTatwoUltraworkAsDollarSkillAndSeparateMCP() throws {
    let entries = TatwoPluginRegistryBookV1().normalizedForCurrentDefaults().entries
    let skill = try XCTUnwrap(entries.first { $0.id == "tatwo-ultrawork" })
    let mcp = try XCTUnwrap(entries.first { $0.id == "tatwo-ultrawork-mcp" })
    XCTAssertEqual(skill.kind, .skill)
    XCTAssertEqual(mcp.kind, .mcp)
    XCTAssertEqual(skill.path, "skill:tatwo-ultrawork")
  }

  func testUnifiedLedgerIsProviderIndependentAndDeduplicates() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).jsonl")
    let ledger = TatwoUnifiedSessionLedger(fileURL: file)
    let event = TatwoUnifiedSessionEventV1(
      id: "event-1", threadID: "thread-1", provider: "fable",
      kind: .modelTurn, summary: "hello")
    try ledger.append(event)
    try ledger.append(event)
    XCTAssertEqual(try ledger.load(), [event])
  }

  func testUnifiedLedgerActivityProjectionUsesLatestEventPerThread() {
    let older = Date(timeIntervalSince1970: 10)
    let newer = Date(timeIntervalSince1970: 30)
    let events = [
      TatwoUnifiedSessionEventV1(
        id: "a-old", threadID: "thread-a", provider: "claude",
        kind: .modelTurn, occurredAt: older, summary: "old"),
      TatwoUnifiedSessionEventV1(
        id: "b-new", threadID: "thread-b", provider: "grok",
        kind: .modelTurn, occurredAt: Date(timeIntervalSince1970: 20), summary: "b"),
      TatwoUnifiedSessionEventV1(
        id: "a-new", threadID: "thread-a", provider: "codex",
        kind: .receipt, occurredAt: newer, summary: "new"),
    ]

    XCTAssertEqual(
      TatwoUnifiedSessionActivityProjection.latestActivityByThreadID(from: events),
      ["thread-a": newer, "thread-b": Date(timeIntervalSince1970: 20)])
  }

  func testUnifiedLedgerActivityProjectionFallsBackToThreadUpdatedAt() {
    let fallback = Date(timeIntervalSince1970: 50)
    XCTAssertEqual(
      TatwoUnifiedSessionActivityProjection.activityDate(
        threadID: "missing",
        fallback: fallback,
        latestActivityByThreadID: [:]),
      fallback)
  }

  func testUnifiedLedgerSerializesConcurrentAppendAndReportsCorruptLines() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-unified-ledger-\(UUID().uuidString)", isDirectory: true)
    let file = root.appendingPathComponent("ledger.jsonl")
    let ledger = TatwoUnifiedSessionLedger(fileURL: file)
    let queue = DispatchQueue(label: "tatwo-ledger-test", attributes: .concurrent)
    let group = DispatchGroup()
    for index in 0..<24 {
      group.enter()
      queue.async {
        defer { group.leave() }
        try? ledger.append(TatwoUnifiedSessionEventV1(
          id: "event-\(index)",
          threadID: "thread-1",
          provider: index.isMultiple(of: 2) ? "claude" : "grok",
          kind: .modelTurn,
          occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
          summary: "event \(index)"))
      }
    }
    group.wait()
    XCTAssertEqual(try ledger.load().count, 24)

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{not-json}\n".utf8))
    try handle.close()
    let inspection = try ledger.inspect()
    XCTAssertEqual(inspection.events.count, 24)
    XCTAssertEqual(inspection.corruptionReceipts.count, 1)
    XCTAssertEqual(inspection.corruptionReceipts.first?.lineNumber, 25)
    XCTAssertEqual(inspection.corruptionReceipts.first?.lineSHA256.count, 64)
  }

  func testNativeChatStoreMigratesCodexClaudeAndGrokIntoOneLedgerBeforeSave() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-native-ledger-\(UUID().uuidString)", isDirectory: true)
    let storeURL = root.appendingPathComponent("native-chat-threads.json")
    let ledger = TatwoUnifiedSessionLedger(fileURL: root.appendingPathComponent("ledger.jsonl"))
    let store = TatwoNativeChatStore(url: storeURL, unifiedLedger: ledger)
    let thread = TatwoNativeChatThread(
      title: "one thread",
      messages: [
        TatwoNativeChatStoredMessage(
          id: "codex-turn", role: "assistant", text: "codex",
          modelID: "gpt-5.5", createdAt: Date(timeIntervalSince1970: 1)),
        TatwoNativeChatStoredMessage(
          id: "claude-turn", role: "assistant", text: "claude",
          modelID: "fable5", createdAt: Date(timeIntervalSince1970: 2)),
        TatwoNativeChatStoredMessage(
          id: "grok-turn", role: "assistant", text: "grok",
          modelID: "grok-build", createdAt: Date(timeIntervalSince1970: 3)),
      ])
    try store.save(TatwoNativeChatStoreDocument(threads: [thread]))
    let events = try ledger.load()
    XCTAssertEqual(Set(events.map(\.provider)), Set(["tatwo", "codex", "claude", "grok"]))
    XCTAssertEqual(events.filter { $0.kind == .modelTurn }.count, 3)
    XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
  }

  func testComputerRequestIsDetectedForTatwoComputerHost() {
    XCTAssertTrue(TatwoChatCommandPlanner.requiresTatwoComputerHost(for: "使用 Computer Use 打開 App"))
  }
}
