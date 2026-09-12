import XCTest

@testable import TatwoUltraworkCore

final class CodexSessionActivitySourceTests: XCTestCase {
  func testLoadsRecentCodexExecSessionsFromCodexHomeRolloutJSONL() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let day = root.appendingPathComponent("sessions/2026/07/06", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent(
      "rollout-2026-07-06T09-07-28-019f34f7-456b-7e03-acb8-230657c03311.jsonl")
    try """
      {"timestamp":"2026-07-06T01:07:28.262Z","type":"session_meta","payload":{"id":"019f34f7-456b-7e03-acb8-230657c03311","timestamp":"2026-07-06T01:07:28.262Z","cwd":"/tmp/tatwo2-fixture/AI/Codex/project/插件/tatwo-wt-loop-a","originator":"codex_exec","model_provider":"model_gateway"}}
      {"timestamp":"2026-07-06T01:07:28.625Z","type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/tmp/tatwo2-fixture/AI/Codex/project/插件/tatwo-wt-loop-a"}}
      """.write(to: rollout, atomically: true, encoding: .utf8)

    let records = TatwoCodexSessionActivitySource.loadRecent(
      codexHomeCandidates: [root],
      since: ISO8601DateFormatter().date(from: "2026-07-05T00:00:00Z")!,
      now: ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!)

    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].modelID, "gpt-5.5")
    XCTAssertEqual(records[0].modelProvider, "model_gateway")
    XCTAssertEqual(records[0].originator, "codex_exec")
    XCTAssertEqual(records[0].workdirSummary, "插件/tatwo-wt-loop-a")
    XCTAssertEqual(records[0].sourceKind, .codexSessionJSONL)
  }

  func testExternalVolumeCandidatesExcludedUnlessOptedIn() throws {
    // The default (launch) path must never surface a /Volumes candidate — a
    // fileExists() on one triggers the macOS removable-volume dialog. Even with a
    // CODEX_HOME env pointing at an external volume, allowExternalVolumes:false
    // must drop it before any stat.
    let tmpHome = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let env = [
      "HOME": tmpHome.path,
      "CODEX_HOME": "/Volumes/fixture-volume/CliHome",
    ]
    let gated = TatwoCodexSessionActivitySource.defaultCodexHomeCandidates(
      environment: env, allowExternalVolumes: false)
    XCTAssertFalse(
      gated.contains { $0.standardizedFileURL.path.hasPrefix("/Volumes/") },
      "launch candidates must not include any /Volumes path")
  }

  func testResolvesOntoExternalVolumeDetectsLiteralAndSymlink() throws {
    // Lexical /Volumes literal.
    XCTAssertTrue(
      TatwoCodexSessionActivitySource.resolvesOntoExternalVolume("/Volumes/fixture-volume/CliHome"))
    // Symlink that points onto a /Volumes target (mirrors the real ~/.codex link)
    // is detected via readlink WITHOUT accessing the target volume.
    let rawRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rawRoot) }
    // Canonicalize the temp root so the probe's leading path holds no incidental
    // system symlinks (e.g. /var -> /private/var); this isolates the assertion to
    // the .codex -> /Volumes hop we actually care about (the real ~/.codex lives
    // under /Users and has no such indirection).
    let root = URL(fileURLWithPath: rawRoot.resolvingSymlinksInPath().path, isDirectory: true)
    let link = root.appendingPathComponent(".codex")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "/Volumes/fixture-volume/CliHome")
    XCTAssertTrue(
      TatwoCodexSessionActivitySource.resolvesOntoExternalVolume(
        link.appendingPathComponent("state_5.sqlite").path),
      "a ~/.codex-style symlink onto /Volumes must be detected as external")
    // A purely-internal temp path is not external.
    XCTAssertFalse(
      TatwoCodexSessionActivitySource.resolvesOntoExternalVolume(
        root.appendingPathComponent("state_5.sqlite").path))
  }

  func testMissingModelIsNotInventedAsGPT55() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let day = root.appendingPathComponent("sessions/2026/07/06", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent(
      "rollout-2026-07-06T09-51-38-019f351f-b716-7603-91f6-5049afda2f8c.jsonl")
    try """
      {"timestamp":"2026-07-06T01:51:38.798Z","type":"session_meta","payload":{"id":"019f351f-b716-7603-91f6-5049afda2f8c","timestamp":"2026-07-06T01:51:38.798Z","cwd":"/tmp/tatwo2-fixture/AI/Codex/project/插件/Tatwo Ultrawork","originator":"codex_exec","model_provider":"model_gateway"}}
      """.write(to: rollout, atomically: true, encoding: .utf8)

    let records = TatwoCodexSessionActivitySource.loadRecent(
      codexHomeCandidates: [root],
      since: ISO8601DateFormatter().date(from: "2026-07-06T00:00:00Z")!,
      now: ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!)

    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].modelID, "model_gateway")
    XCTAssertEqual(records[0].modelConfidence, .providerOnly)
  }

  func testBoundedHeaderStillParsesCompleteLinesWhenCutoffSplitsUTF8() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let day = root.appendingPathComponent("sessions/2026/07/06", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent(
      "rollout-2026-07-06T10-00-00-019f351f-b716-7603-91f6-5049afda2f8d.jsonl")
    let header = """
      {"timestamp":"2026-07-06T02:00:00.000Z","type":"session_meta","payload":{"id":"019f351f-b716-7603-91f6-5049afda2f8d","timestamp":"2026-07-06T02:00:00.000Z","cwd":"/tmp/tatwo2-fixture/AI/Codex/project/插件/Tatwo Ultrawork","originator":"codex_exec","model_provider":"model_gateway"}}
      {"timestamp":"2026-07-06T02:00:00.100Z","type":"turn_context","payload":{"model":"sonnet-5","cwd":"/tmp/tatwo2-fixture/AI/Codex/project/插件/Tatwo Ultrawork"}}

      """
    let maxHeaderBytes = 512 * 1024
    var data = Data(header.utf8)
    XCTAssertLessThan(data.count, maxHeaderBytes - 2)
    data.append(Data(repeating: 0x61, count: maxHeaderBytes - data.count - 2))
    data.append(contentsOf: [0xF0, 0x9F])
    try data.write(to: rollout, options: .atomic)

    let records = TatwoCodexSessionActivitySource.loadRecent(
      codexHomeCandidates: [root],
      since: ISO8601DateFormatter().date(from: "2026-07-06T00:00:00Z")!,
      now: ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!)

    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].modelID, "sonnet-5")
  }

  func testMissingInjectedHomeClassifiesVolumeAbsent() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-home-missing-\(UUID().uuidString)", isDirectory: true)
    let cacheRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("activity-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let result = TatwoCodexSessionActivitySource.loadRecentOutcome(
      codexHomeCandidates: [missing],
      since: Date().addingTimeInterval(-60),
      cacheRootURL: cacheRoot)

    XCTAssertEqual(result.state, .unavailable)
    XCTAssertEqual(result.failure, .volumeAbsent)
    XCTAssertNil(result.value)
  }

  func testCodexActivityUsesLastGoodCacheWhenHomeDisappears() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-home-cache-\(UUID().uuidString)", isDirectory: true)
    let cacheRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("activity-cache-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: cacheRoot)
    }

    let day = root.appendingPathComponent("sessions/2026/07/06", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent("rollout-cache.jsonl")
    try """
      {"type":"session_meta","payload":{"id":"cache-session","timestamp":"2026-07-06T01:07:28.262Z","cwd":"/tmp/cache","originator":"codex_exec","model_provider":"model_gateway"}}
      {"type":"turn_context","payload":{"model":"gpt-5.5"}}
      """.write(to: rollout, atomically: true, encoding: .utf8)

    let cutoff = ISO8601DateFormatter().date(from: "2026-07-05T00:00:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!
    let fresh = TatwoCodexSessionActivitySource.loadRecentOutcome(
      codexHomeCandidates: [root],
      since: cutoff,
      now: now,
      cacheRootURL: cacheRoot)
    XCTAssertEqual(fresh.state, .fresh)
    XCTAssertEqual(fresh.value?.count, 1)

    try FileManager.default.removeItem(at: root)
    let stale = TatwoCodexSessionActivitySource.loadRecentOutcome(
      codexHomeCandidates: [root],
      since: cutoff,
      now: now,
      cacheRootURL: cacheRoot)
    XCTAssertEqual(stale.state, .stale)
    XCTAssertEqual(stale.failure, .volumeAbsent)
    XCTAssertEqual(stale.value?.first?.id, fresh.value?.first?.id)
    XCTAssertNotNil(stale.lastGoodAt)
  }
}
