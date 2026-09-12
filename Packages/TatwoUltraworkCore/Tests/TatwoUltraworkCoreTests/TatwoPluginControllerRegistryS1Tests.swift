import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoPluginControllerRegistryS1Tests: XCTestCase {
  private var tempRoot: URL!

  override func setUpWithError() throws {
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-plugin-s1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot {
      try? FileManager.default.removeItem(at: tempRoot)
    }
  }

  // MARK: - Seed + schema load

  func testSeedRegistryLoadsFailClosedAndListsSixPortableEntries() throws {
    let url = try XCTUnwrap(seedRegistryURL())
    let document = try TatwoPluginControllerRegistryLoaderV1.load(from: url)

    XCTAssertEqual(document.schema, TatwoPluginControllerRegistryDocumentV1.schemaName)
    XCTAssertEqual(document.source, "os_registry")
    XCTAssertEqual(document.registryRevision, "s1-seed-20260730")
    XCTAssertNil(document.activeRevision)

    let portableIDs = document.portableMcpEntries.map(\.id).sorted()
    XCTAssertEqual(
      portableIDs,
      [
        "chatgpt-pro",
        "codebase-memory",
        "gbrain",
        "gitnexus",
        "product-design",
        "web-check",
      ])

    XCTAssertEqual(document.entries.filter { $0.type == .vendorNative }.count, 1)
    XCTAssertEqual(document.entries.filter { $0.type == .appNative }.count, 1)

    let computer = try XCTUnwrap(document.entries.first { $0.id == "computer-use" })
    XCTAssertEqual(computer.type, .vendorNative)
    XCTAssertEqual(computer.implementations?.count, 2)
    XCTAssertEqual(computer.routing?.laneRef, "d12-capability-lane:computer-use")
    XCTAssertNil(computer.canonicalDefinition)

    let panel = try XCTUnwrap(document.entries.first { $0.id == "tatwo-right-panel" })
    XCTAssertEqual(panel.type, .appNative)
    XCTAssertEqual(panel.appFeature?.externalProjection, "none")
    XCTAssertNil(panel.projectionTemplates)
  }

  func testLoadRejectsUnknownSchema() throws {
    let data = Data(
      #"""
      {
        "schema": "NotAPluginRegistry",
        "registryRevision": "x",
        "source": "os_registry",
        "entries": [
          {
            "id": "gitnexus",
            "type": "portable_mcp",
            "desiredState": "enabled",
            "canonicalDefinition": {
              "protocol": "mcp",
              "transport": "stdio",
              "command": "gitnexus"
            },
            "projectionTemplates": {
              "codex": { "templateID": "codex.mcp-server.v1" }
            }
          }
        ]
      }
      """#.utf8)
    XCTAssertThrowsError(try TatwoPluginControllerRegistryLoaderV1.load(data: data)) { error in
      guard let typed = error as? TatwoPluginControllerRegistryErrorV1 else {
        return XCTFail("expected TatwoPluginControllerRegistryErrorV1, got \(error)")
      }
      XCTAssertEqual(typed, .unsupportedSchema("NotAPluginRegistry"))
    }
  }

  func testLoadRejectsUnknownType() throws {
    let data = Data(
      #"""
      {
        "schema": "TatwoPluginControllerRegistryV1",
        "registryRevision": "x",
        "source": "os_registry",
        "entries": [
          {
            "id": "mystery",
            "type": "mystery_kind",
            "desiredState": "enabled"
          }
        ]
      }
      """#.utf8)
    XCTAssertThrowsError(try TatwoPluginControllerRegistryLoaderV1.load(data: data)) { error in
      XCTAssertTrue(
        error is TatwoPluginControllerRegistryErrorV1
          || String(describing: error).contains("mystery")
          || String(describing: error).contains("invalidJSON")
          || String(describing: error).contains("type"),
        "unexpected error: \(error)")
    }
  }

  func testLoadRejectsPortableWithoutCanonicalDefinition() throws {
    let data = Data(
      #"""
      {
        "schema": "TatwoPluginControllerRegistryV1",
        "registryRevision": "x",
        "source": "os_registry",
        "entries": [
          {
            "id": "gitnexus",
            "type": "portable_mcp",
            "desiredState": "enabled",
            "projectionTemplates": {
              "codex": { "templateID": "codex.mcp-server.v1" }
            }
          }
        ]
      }
      """#.utf8)
    XCTAssertThrowsError(try TatwoPluginControllerRegistryLoaderV1.load(data: data)) { error in
      XCTAssertEqual(
        error as? TatwoPluginControllerRegistryErrorV1,
        .missingCanonicalDefinition("gitnexus"))
    }
  }

  func testLoadRejectsForbiddenAuthField() throws {
    let data = Data(
      #"""
      {
        "schema": "TatwoPluginControllerRegistryV1",
        "registryRevision": "x",
        "source": "os_registry",
        "entries": [
          {
            "id": "gitnexus",
            "type": "portable_mcp",
            "desiredState": "enabled",
            "authToken": "literal-secret",
            "canonicalDefinition": {
              "protocol": "mcp",
              "transport": "stdio",
              "command": "gitnexus"
            },
            "projectionTemplates": {
              "codex": { "templateID": "codex.mcp-server.v1" }
            }
          }
        ]
      }
      """#.utf8)
    XCTAssertThrowsError(try TatwoPluginControllerRegistryLoaderV1.load(data: data)) { error in
      XCTAssertEqual(
        error as? TatwoPluginControllerRegistryErrorV1,
        .forbiddenFieldPresent("authToken"))
    }
  }

  func testLoadRejectsPathTraversalID() throws {
    let data = Data(
      #"""
      {
        "schema": "TatwoPluginControllerRegistryV1",
        "registryRevision": "x",
        "source": "os_registry",
        "entries": [
          {
            "id": "../evil",
            "type": "app_native",
            "desiredState": "enabled",
            "appFeature": {
              "moduleID": "x",
              "builtIn": true,
              "externalProjection": "none"
            }
          }
        ]
      }
      """#.utf8)
    XCTAssertThrowsError(try TatwoPluginControllerRegistryLoaderV1.load(data: data)) { error in
      XCTAssertEqual(
        error as? TatwoPluginControllerRegistryErrorV1,
        .invalidEntryID("../evil"))
    }
  }

  func testLoadRejectsVendorWithoutLaneRef() throws {
    let data = Data(
      #"""
      {
        "schema": "TatwoPluginControllerRegistryV1",
        "registryRevision": "x",
        "source": "os_registry",
        "entries": [
          {
            "id": "computer-use",
            "type": "vendor_native",
            "desiredState": "enabled",
            "implementations": [
              {
                "implementationID": "codex-computer-use",
                "provider": "codex",
                "capabilityID": "computer-use",
                "entrypoint": "codex.native.computer_use",
                "priority": 10
              }
            ],
            "routing": {
              "laneRef": "",
              "selection": "capability_then_priority",
              "fallback": "declared_only"
            }
          }
        ]
      }
      """#.utf8)
    XCTAssertThrowsError(try TatwoPluginControllerRegistryLoaderV1.load(data: data)) { error in
      XCTAssertEqual(
        error as? TatwoPluginControllerRegistryErrorV1,
        .invalidLaneRef("computer-use"))
    }
  }

  // MARK: - Fixture readback

  func testFixtureCodexAndClaudeReadback() throws {
    let codexURL = tempRoot.appendingPathComponent("fixture-codex-config.toml")
    let claudeURL = tempRoot.appendingPathComponent("fixture-claude.mcp.json")

    let toml = """
      # fixture only — not a real home path
      model = "gpt-test"

      [mcp_servers.gitnexus]
      command = "gitnexus"
      args = ["serve"]
      transport = "stdio"

      [mcp_servers."chatgpt-pro"]
      command = "chatgpt-pro-mcp"
      args = ["serve"]

      [mcp_servers.orphan-tool]
      command = "orphan"
      args = []

      [plugins.other]
      enabled = true
      """
    try toml.write(to: codexURL, atomically: true, encoding: .utf8)

    let claudeJSON = """
      {
        "mcpServers": {
          "gitnexus": {
            "type": "stdio",
            "command": "gitnexus",
            "args": ["serve"]
          },
          "gbrain": {
            "type": "stdio",
            "command": "gbrain",
            "args": ["mcp"]
          },
          "config-only-claude": {
            "type": "stdio",
            "command": "only-on-claude"
          }
        }
      }
      """
    try claudeJSON.write(to: claudeURL, atomically: true, encoding: .utf8)

    let codexServers = try TatwoPluginConfigReadback.readCodexConfigTOML(at: codexURL)
    let claudeServers = try TatwoPluginConfigReadback.readClaudeMcpJSON(at: claudeURL)

    XCTAssertEqual(
      Set(codexServers.map(\.serverID)),
      ["gitnexus", "chatgpt-pro", "orphan-tool"])
    XCTAssertEqual(
      try XCTUnwrap(codexServers.first { $0.serverID == "gitnexus" }).command,
      "gitnexus")
    XCTAssertEqual(
      try XCTUnwrap(codexServers.first { $0.serverID == "gitnexus" }).args,
      ["serve"])

    XCTAssertEqual(
      Set(claudeServers.map(\.serverID)),
      ["gitnexus", "gbrain", "config-only-claude"])
  }

  func testReadbackRefusesDefaultHomeCodexPath() throws {
    let homeCodex = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".codex/config.toml")
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.assertNotDefaultHomePath(homeCodex.path)
    ) { error in
      XCTAssertEqual(
        error as? TatwoPluginConfigReadbackErrorV1,
        .forbiddenHomePath(homeCodex.path))
    }
  }

  func testReadbackRefusesSymlinkEscapeToHomeCodex() throws {
    let linkURL = tempRoot.appendingPathComponent("escape-codex-config.toml")
    let homeCodex = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".codex/config.toml")
    // Create symlink toward home config (fixture only; must not read home contents).
    // If home file is missing, still link to the path — realpath of parent/home still lands in home tree.
    try FileManager.default.createSymbolicLink(
      at: linkURL,
      withDestinationURL: homeCodex)
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.assertNotDefaultHomePath(linkURL.path)
    ) { error in
      guard let typed = error as? TatwoPluginConfigReadbackErrorV1 else {
        return XCTFail("expected TatwoPluginConfigReadbackErrorV1, got \(error)")
      }
      switch typed {
      case .forbiddenHomePath, .pathEscapesAllowedRoot:
        break
      default:
        XCTFail("expected home/escape rejection, got \(typed)")
      }
    }
    // Also refuse when constrained to fixture root (symlink escapes).
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.assertNotDefaultHomePath(
        linkURL.path,
        allowedRootURL: tempRoot)
    ) { error in
      XCTAssertNotNil(error as? TatwoPluginConfigReadbackErrorV1)
    }
  }

  func testReadbackRejectsOversizedConfig() throws {
    let url = tempRoot.appendingPathComponent("too-big.toml")
    // Keep test light: write slightly over limit by streaming.
    let limit = TatwoPluginConfigReadback.maxConfigBytes
    let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var written = 0
    while written <= limit {
      try handle.write(contentsOf: chunk)
      written += chunk.count
    }
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.readCodexConfigTOML(at: url, allowedRootURL: tempRoot)
    ) { error in
      guard case .inputTooLarge = error as? TatwoPluginConfigReadbackErrorV1 else {
        return XCTFail("expected inputTooLarge, got \(error)")
      }
    }
  }

  func testReadbackRejectsInvalidUTF8() throws {
    let url = tempRoot.appendingPathComponent("bad-utf8.toml")
    try Data([0xFF, 0xFE, 0xFD]).write(to: url)
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.readCodexConfigTOML(at: url, allowedRootURL: tempRoot)
    ) { error in
      guard case .invalidUTF8 = error as? TatwoPluginConfigReadbackErrorV1 else {
        return XCTFail("expected invalidUTF8, got \(error)")
      }
    }
  }

  func testClaudeJSONRejectsMixedArgsAndNonObjectServer() throws {
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.parseClaudeMcpJSON(
        Data(#"{"mcpServers":{"x":{"command":"c","args":["ok",1]}}}"#.utf8))
    ) { error in
      guard case .invalidConfigStructure = error as? TatwoPluginConfigReadbackErrorV1 else {
        return XCTFail("expected invalidConfigStructure for mixed args, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.parseClaudeMcpJSON(
        Data(#"{"mcpServers":{"x":"not-object"}}"#.utf8))
    ) { error in
      guard case .invalidConfigStructure = error as? TatwoPluginConfigReadbackErrorV1 else {
        return XCTFail("expected invalidConfigStructure for non-object server, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.parseClaudeMcpJSON(
        Data(#"{"other":true}"#.utf8))
    ) { error in
      guard case .invalidConfigStructure = error as? TatwoPluginConfigReadbackErrorV1 else {
        return XCTFail("expected invalidConfigStructure for missing mcpServers, got \(error)")
      }
    }
  }

  func testCodexTOMLRejectsMalformedMcpAssignment() throws {
    XCTAssertThrowsError(
      try TatwoPluginConfigReadback.parseCodexMcpServersTOML(
        """
        [mcp_servers.broken]
        command "missing-equals"
        """)
    ) { error in
      guard case .invalidConfigStructure = error as? TatwoPluginConfigReadbackErrorV1 else {
        return XCTFail("expected invalidConfigStructure for malformed TOML, got \(error)")
      }
    }
  }

  // MARK: - Drift three-state

  func testDriftThreeStatesRegistryOnlyConfigOnlyMatched() throws {
    let registry = try TatwoPluginControllerRegistryLoaderV1.load(from: try XCTUnwrap(seedRegistryURL()))

    let codex = [
      TatwoPluginObservedMcpServerV1(
        serverID: "gitnexus", source: .codexToml, command: "gitnexus"),
      TatwoPluginObservedMcpServerV1(
        serverID: "orphan-tool", source: .codexToml, command: "orphan"),
    ]
    let claude = [
      TatwoPluginObservedMcpServerV1(
        serverID: "gitnexus", source: .claudeMcpJson, command: "gitnexus"),
      TatwoPluginObservedMcpServerV1(
        serverID: "gbrain", source: .claudeMcpJson, command: "gbrain"),
      TatwoPluginObservedMcpServerV1(
        serverID: "config-only-claude", source: .claudeMcpJson, command: "x"),
    ]

    let report = TatwoPluginConfigReadback.compareDrift(
      registry: registry,
      codexServers: codex,
      claudeServers: claude,
      codexPathInjected: "/tmp/fixture-codex.toml",
      claudePathInjected: "/tmp/fixture-claude.mcp.json")

    XCTAssertEqual(Set(report.matchedIDs), ["gitnexus", "gbrain"])
    XCTAssertEqual(
      Set(report.configOnlyIDs),
      ["config-only-claude", "orphan-tool"])
    XCTAssertEqual(
      Set(report.registryOnlyIDs),
      [
        "chatgpt-pro",
        "codebase-memory",
        "product-design",
        "web-check",
      ])

    // vendor_native / app_native must not appear in MCP drift ids.
    XCTAssertFalse(report.drift.contains { $0.serverID == "computer-use" })
    XCTAssertFalse(report.drift.contains { $0.serverID == "tatwo-right-panel" })

    let matchedGit = try XCTUnwrap(report.drift.first { $0.serverID == "gitnexus" })
    XCTAssertEqual(matchedGit.kind, .matched)
    XCTAssertEqual(
      Set(matchedGit.configSources),
      [.codexToml, .claudeMcpJson])
  }

  func testEndToEndFixtureReadbackAgainstSeed() throws {
    let registry = try TatwoPluginControllerRegistryLoaderV1.load(from: try XCTUnwrap(seedRegistryURL()))
    let codexURL = tempRoot.appendingPathComponent("e2e-codex.toml")
    let claudeURL = tempRoot.appendingPathComponent("e2e-claude.mcp.json")
    try """
      [mcp_servers.gitnexus]
      command = "gitnexus"
      args = ["serve"]

      [mcp_servers.extra-config]
      command = "extra"
      """.write(to: codexURL, atomically: true, encoding: .utf8)
    try """
      {"mcpServers":{"gitnexus":{"command":"gitnexus","type":"stdio"}}}
      """.write(to: claudeURL, atomically: true, encoding: .utf8)

    let report = try TatwoPluginConfigReadback.readback(
      registry: registry,
      codexConfigURL: codexURL,
      claudeMcpJSONURL: claudeURL)

    XCTAssertEqual(report.matchedIDs, ["gitnexus"])
    XCTAssertTrue(report.configOnlyIDs.contains("extra-config"))
    XCTAssertTrue(report.registryOnlyIDs.contains("web-check"))
    XCTAssertEqual(report.codexPathInjected, codexURL.path)
    XCTAssertEqual(report.claudePathInjected, claudeURL.path)
  }

  // MARK: - Helpers

  private func seedRegistryURL() -> URL? {
    // #filePath = <repo>/Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/This.swift
    let fromFile = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("registry/plugins.v1.json")
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let candidates = [
      fromFile,
      cwd.appendingPathComponent("registry/plugins.v1.json"),
      cwd.appendingPathComponent("../registry/plugins.v1.json"),
      cwd.appendingPathComponent("../../registry/plugins.v1.json"),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }
}
