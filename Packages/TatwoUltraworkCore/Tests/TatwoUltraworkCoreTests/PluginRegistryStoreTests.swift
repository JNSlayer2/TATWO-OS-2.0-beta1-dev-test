import XCTest

@testable import TatwoUltraworkCore

final class PluginRegistryStoreTests: XCTestCase {
  private func makeStore() -> (TatwoPluginRegistryStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    return (
      TatwoPluginRegistryStore(fileURL: root.appendingPathComponent("plugin-registry.json")),
      root
    )
  }

  func testMissingFileReturnsDefaultRegistryEntries() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let book = try store.load()

    XCTAssertTrue(book.entries.contains { $0.id == "gitnexus" })
    XCTAssertTrue(book.entries.contains { $0.id == "chatgpt-pro-mcp" })
  }

  func testNormalizationRefreshesBuiltInRegistryMetadata() throws {
    let staleGitNexus = PluginRegistryEntry(
      id: "gitnexus",
      name: "GitNexus",
      kind: .plugin,
      purpose: "stale",
      trigger: "stale",
      safetyLevel: .low,
      requiredForModes: [],
      installState: .unknown,
      publicInstallHint: "stale")

    let normalized = TatwoPluginRegistryBookV1(entries: [staleGitNexus])
      .normalizedForCurrentDefaults()
    let gitnexus = try XCTUnwrap(normalized.entry(id: "gitnexus"))

    XCTAssertEqual(gitnexus.installState, .installed)
    XCTAssertNotEqual(gitnexus.purpose, "stale")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gitnexus))
    let object = try XCTUnwrap(encoded as? [String: Any])
    XCTAssertNotNil(object["smokeCommand"] as? String)
  }

  func testRegisterSkillRequiresPlainPurposeAndPersistsPath() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(
      try store.register(kind: .skill, path: "/tmp/example/SKILL.md", plainPurpose: "  "))

    let result = try store.register(
      kind: .skill,
      path: "/tmp/example/SKILL.md",
      plainPurpose: "改多檔前先提供專案上下文。",
      name: "Example Skill")

    XCTAssertEqual(result.entry?.kind, .skill)
    XCTAssertEqual(result.entry?.path, "/tmp/example/SKILL.md")
    XCTAssertEqual(try store.load().entry(id: result.entry!.id)?.purpose, "改多檔前先提供專案上下文。")
  }

  func testRegisterRejectsNonSkillOrMCPKinds() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(
      try store.register(kind: .plugin, path: "plugin:demo", plainPurpose: "demo"))
  }

  func testRemoveDefaultEntryPersistsRemovalAcrossNormalization() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try store.remove(id: "gitnexus")
    let reloaded = try store.load()

    XCTAssertFalse(reloaded.entries.contains { $0.id == "gitnexus" })
    XCTAssertTrue(reloaded.removedDefaultIDs.contains("gitnexus"))
  }

  func testMCPReadAPIReturnsPersistedRegistryBook() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.register(
      kind: .mcp,
      path: "mcp:demo",
      plainPurpose: "提供外部研究副審。",
      name: "Demo MCP")

    var environment = ProcessInfo.processInfo.environment
    environment["TATWO_ULTRAWORK_PLUGIN_REGISTRY_PATH"] = store.fileURL.path
    let book = TatwoPluginRegistryStore.loadDefaultStaging(environment: environment)

    XCTAssertTrue(book.entries.contains { $0.name == "Demo MCP" })
  }

  func testExportsRegistryEntriesAsClaudeMCPConfigAndSyncsWithBackup() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try store.register(
      kind: .mcp,
      path: "mcp:tatwo-test-mcp-server",
      plainPurpose: "N5 e2e 測試 MCP 互通項目。",
      name: "Tatwo Test MCP")

    let exported = try store.exportClaudeMCPConfig()
    let server = try XCTUnwrap(exported.mcpServers["mcp-tatwo-test-mcp"])
    XCTAssertEqual(server.type, "stdio")
    XCTAssertEqual(server.command, "tatwo-test-mcp-server")

    let claudeConfigURL = root.appendingPathComponent(".claude.json")
    try Data(#"{"mcpServers":{"keep-existing":{"type":"stdio","command":"existing"}},"other":"value"}"#.utf8)
      .write(to: claudeConfigURL)

    let receipt = try store.syncClaudeMCPConfig(targetURL: claudeConfigURL)
    XCTAssertEqual(receipt.stage, "claude-user-config")
    XCTAssertTrue(receipt.serverNames.contains("mcp-tatwo-test-mcp"))
    XCTAssertNotNil(receipt.backupPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: claudeConfigURL.path + ".bak"))

    let synced = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: claudeConfigURL))
    guard case .object(let rootObject) = synced,
      case .object(let servers) = rootObject["mcpServers"],
      case .object(let syncedServer) = servers["mcp-tatwo-test-mcp"],
      case .string("tatwo-test-mcp-server") = syncedServer["command"],
      case .object = servers["keep-existing"]
    else {
      return XCTFail("expected synced Claude config to preserve existing servers and add Tatwo MCP server")
    }
  }
}
