import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoPluginControllerS2Tests: XCTestCase {
  private var tempRoot: URL!

  override func setUpWithError() throws {
    tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-plugin-s2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempRoot {
      try? FileManager.default.removeItem(at: tempRoot)
    }
  }

  // MARK: - Projection

  func testProjectPortableCodexAndClaudeFragments() throws {
    let entry = try portableEntry(
      id: "gitnexus",
      command: "gitnexus",
      args: ["serve"],
      templates: [
        "codex": "codex.mcp-server.v1",
        "claude": "claude.mcp-server.v1",
      ])

    let codex = try TatwoPluginProjectionV1.project(entry: entry, brand: .codex)
    let claude = try TatwoPluginProjectionV1.project(entry: entry, brand: .claude)

    let codexFragment = try XCTUnwrap(codex.fragment)
    XCTAssertTrue(codexFragment.body.contains("[mcp_servers.gitnexus]"))
    XCTAssertTrue(codexFragment.body.contains("command = \"gitnexus\""))
    XCTAssertTrue(codexFragment.body.contains("args = [\"serve\"]"))
    XCTAssertTrue(codexFragment.body.contains("transport = \"stdio\""))
    XCTAssertFalse(codexFragment.writesNativeConfig)

    let claudeFragment = try XCTUnwrap(claude.fragment)
    XCTAssertTrue(claudeFragment.body.contains("\"command\""))
    XCTAssertTrue(claudeFragment.body.contains("gitnexus"))
    XCTAssertTrue(claudeFragment.body.contains("stdio"))
    XCTAssertEqual(claudeFragment.templateID, "claude.mcp-server.v1")
  }

  func testVendorAndAppNativeNotProjectable() throws {
    let vendor = TatwoPluginRegistryEntryV1(
      id: "computer-use",
      type: .vendorNative,
      desiredState: .enabled,
      implementations: [
        TatwoPluginVendorImplementationV1(
          implementationID: "codex-computer-use",
          provider: "codex",
          capabilityID: "computer-use",
          entrypoint: "codex.native.computer_use",
          priority: 10)
      ],
      routing: TatwoPluginVendorRoutingV1(
        laneRef: "d12-capability-lane:computer-use",
        selection: "capability_then_priority",
        fallback: "declared_only"))

    let app = TatwoPluginRegistryEntryV1(
      id: "tatwo-right-panel",
      type: .appNative,
      desiredState: .enabled,
      appFeature: TatwoPluginAppFeatureV1(moduleID: "TatwoUltraworkMac.right_panel"))

    let vendorOutcome = try TatwoPluginProjectionV1.project(entry: vendor, brand: .codex)
    let appOutcome = try TatwoPluginProjectionV1.project(entry: app, brand: .claude)

    XCTAssertFalse(vendorOutcome.isProjected)
    XCTAssertTrue(
      try XCTUnwrap(vendorOutcome.notProjectableReason).contains("vendor_native"))
    XCTAssertFalse(appOutcome.isProjected)
    XCTAssertTrue(
      try XCTUnwrap(appOutcome.notProjectableReason).contains("app_native"))
  }

  func testMissingBrandTemplateFailClosed() throws {
    let entry = try portableEntry(
      id: "gitnexus",
      command: "gitnexus",
      args: ["serve"],
      templates: [
        "codex": "codex.mcp-server.v1"
        // claude missing
      ])
    XCTAssertThrowsError(
      try TatwoPluginProjectionV1.project(entry: entry, brand: .claude)
    ) { error in
      XCTAssertEqual(
        error as? TatwoPluginProjectionErrorV1,
        .missingBrandTemplate(entryID: "gitnexus", brand: "claude"))
    }
  }

  func testUnknownTemplateIDFailClosed() throws {
    let entry = try portableEntry(
      id: "gitnexus",
      command: "gitnexus",
      args: ["serve"],
      templates: [
        "codex": "codex.mcp-server.v9-unknown"
      ])
    XCTAssertThrowsError(
      try TatwoPluginProjectionV1.project(entry: entry, brand: .codex)
    ) { error in
      XCTAssertEqual(
        error as? TatwoPluginProjectionErrorV1,
        .unknownTemplateID(
          entryID: "gitnexus", brand: "codex", templateID: "codex.mcp-server.v9-unknown"))
    }
  }

  // MARK: - Four plan states

  func testFourPlanStatesCreateUpdateUnchangedConflict() throws {
    let registry = TatwoPluginControllerRegistryDocumentV1(
      registryRevision: "s2-four-state",
      entries: [
        try portableEntry(id: "alpha", command: "alpha", args: ["a"]),
        try portableEntry(id: "beta", command: "beta-new", args: ["b2"]),
        try portableEntry(id: "gamma", command: "gamma", args: ["g"]),
        try portableEntry(id: "delta", command: "delta-registry", args: ["d1"]),
      ])

    // alpha missing → create
    // beta present, different, owned → update
    // gamma present, same → unchanged
    // delta present, different, not owned → conflict
    let codex = [
      TatwoPluginObservedMcpServerV1(
        serverID: "beta", source: .codexToml, transport: "stdio", command: "beta-old", args: ["b1"]),
      TatwoPluginObservedMcpServerV1(
        serverID: "gamma", source: .codexToml, transport: "stdio", command: "gamma", args: ["g"]),
      TatwoPluginObservedMcpServerV1(
        serverID: "delta", source: .codexToml, transport: "stdio", command: "delta-hand",
        args: ["hand"]),
    ]

    let betaObserved = codex[0]
    let betaHash = try TatwoPluginProjectionV1.fragmentSHA256(
      managed: .fromObserved(betaObserved), brand: .codex)
    let plan = try TatwoPluginStagedPlanV1.build(
      registry: registry,
      brands: [.codex],
      codexServers: codex,
      claudeServers: [],
      ownershipRecords: [
        TatwoPluginOwnershipRecordV1(
          serverID: "beta",
          brand: .codex,
          targetPath: "~/.codex/config.toml#mcp_servers.beta",
          appliedFragmentSHA256: betaHash,
          appliedAtRevision: "s2-four-state",
          appliedAt: "2026-07-30T00:00:00Z")
      ])

    XCTAssertTrue(plan.requiresHumanGate)
    XCTAssertFalse(plan.writesNativeConfig)

    let byID = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.entryID, $0) })
    XCTAssertEqual(byID["alpha"]?.action, .create)
    XCTAssertEqual(byID["beta"]?.action, .update)
    XCTAssertEqual(byID["gamma"]?.action, .unchanged)
    XCTAssertEqual(byID["delta"]?.action, .conflict)

    for item in plan.items {
      XCTAssertTrue(item.requiresHumanGate, "every item requires human gate")
    }

    XCTAssertFalse(try XCTUnwrap(byID["alpha"]?.unifiedDiff).isEmpty)
    XCTAssertTrue(try XCTUnwrap(byID["alpha"]?.unifiedDiff).contains("+command=alpha"))
    XCTAssertFalse(try XCTUnwrap(byID["beta"]?.unifiedDiff).isEmpty)
    XCTAssertTrue(try XCTUnwrap(byID["beta"]?.unifiedDiff).contains("-command=beta-old"))
    XCTAssertTrue(try XCTUnwrap(byID["beta"]?.unifiedDiff).contains("+command=beta-new"))
    XCTAssertEqual(byID["gamma"]?.unifiedDiff, "")
    XCTAssertFalse(try XCTUnwrap(byID["delta"]?.unifiedDiff).isEmpty)
  }

  func testNotProjectableRowsForVendorAndApp() throws {
    let seed = try TatwoPluginControllerRegistryLoaderV1.load(from: try XCTUnwrap(seedRegistryURL()))
    let plan = try TatwoPluginStagedPlanV1.build(
      registry: seed,
      brands: [.codex, .claude],
      codexServers: [],
      claudeServers: [],
      ownershipRecords: [])

    let vendor = plan.items.first { $0.entryID == "computer-use" }
    let app = plan.items.first { $0.entryID == "tatwo-right-panel" }
    XCTAssertEqual(vendor?.action, .notProjectable)
    XCTAssertEqual(app?.action, .notProjectable)
    XCTAssertTrue(try XCTUnwrap(vendor?.reason).contains("vendor_native"))
    XCTAssertTrue(try XCTUnwrap(app?.reason).contains("app_native"))
  }

  func testUnifiedDiffStableAcrossRuns() throws {
    let first = TatwoPluginUnifiedDiffV1.diff(
      path: "logical",
      oldText: "command=old\nargs=[\"a\"]\n",
      newText: "command=new\nargs=[\"a\"]\n")
    let second = TatwoPluginUnifiedDiffV1.diff(
      path: "logical",
      oldText: "command=old\nargs=[\"a\"]\n",
      newText: "command=new\nargs=[\"a\"]\n")
    XCTAssertEqual(first, second)
    XCTAssertTrue(first.hasPrefix("--- a/logical\n+++ b/logical\n"))
    XCTAssertTrue(first.contains("-command=old"))
    XCTAssertTrue(first.contains("+command=new"))

    let entry = try portableEntry(id: "stable", command: "cmd", args: ["x"])
    let a = try TatwoPluginProjectionV1.project(entry: entry, brand: .codex).fragment
    let b = try TatwoPluginProjectionV1.project(entry: entry, brand: .codex).fragment
    XCTAssertEqual(a?.body, b?.body)
    XCTAssertEqual(a?.managed.stableManagedText(), b?.managed.stableManagedText())
  }

  func testPlanFromInjectedFixturePathsNeverTouchesHome() throws {
    let registryURL = try XCTUnwrap(seedRegistryURL())
    let codexURL = tempRoot.appendingPathComponent("fixture-codex.toml")
    let claudeURL = tempRoot.appendingPathComponent("fixture-claude.mcp.json")
    try """
      [mcp_servers.gitnexus]
      command = "gitnexus"
      args = ["serve"]
      transport = "stdio"
      """.write(to: codexURL, atomically: true, encoding: .utf8)
    try """
      {"mcpServers":{"gitnexus":{"type":"stdio","command":"gitnexus","args":["serve"]}}}
      """.write(to: claudeURL, atomically: true, encoding: .utf8)

    let plan = try TatwoPluginStagedPlanV1.buildFromInjectedPaths(
      registryURL: registryURL,
      codexConfigURL: codexURL,
      claudeMcpJSONURL: claudeURL,
      brands: [.codex],
      ownershipRecords: [],
      allowedRootURL: tempRoot)

    let git = try XCTUnwrap(plan.items.first { $0.entryID == "gitnexus" && $0.brand == .codex })
    XCTAssertEqual(git.action, .unchanged)

    // Missing seed servers → create (not owned).
    let web = try XCTUnwrap(plan.items.first { $0.entryID == "web-check" && $0.brand == .codex })
    XCTAssertEqual(web.action, .create)
    XCTAssertTrue(plan.requiresHumanGate)
  }

  func testStagedProjectionPlannerSeamWritesNativeFalse() throws {
    let seed = try TatwoPluginControllerRegistryLoaderV1.load(from: try XCTUnwrap(seedRegistryURL()))
    let planner = TatwoPluginStagedProjectionPlannerV1()
    let plan = try planner.planProjection(registry: seed, entryID: "gitnexus")
    XCTAssertEqual(plan.writesNativeConfig, false)
    XCTAssertEqual(plan.targets.count, 2)
    XCTAssertEqual(Set(plan.targets.map(\.brand)), ["codex", "claude"])
  }

  func testOwnershipProvenanceFailsClosedAndBindsBrandAndTarget() throws {
    let entry = try portableEntry(id: "same-id", command: "desired", args: ["d"])
    let registry = TatwoPluginControllerRegistryDocumentV1(
      registryRevision: "ownership",
      entries: [entry])
    let codexObserved = TatwoPluginObservedMcpServerV1(
      serverID: "same-id", source: .codexToml, transport: "stdio",
      command: "user-edit-codex", args: ["x"])

    let noRecord = try TatwoPluginStagedPlanV1.build(
      registry: registry, brands: [.codex], codexServers: [codexObserved],
      claudeServers: [], ownershipRecords: [])
    XCTAssertEqual(noRecord.items.first?.action, .conflict)

    let stale = try TatwoPluginStagedPlanV1.build(
      registry: registry, brands: [.codex], codexServers: [codexObserved],
      claudeServers: [], ownershipRecords: [
        TatwoPluginOwnershipRecordV1(
          serverID: "same-id", brand: .codex,
          targetPath: "~/.codex/config.toml#mcp_servers.same-id",
          appliedFragmentSHA256: String(repeating: "0", count: 64),
          appliedAtRevision: "ownership", appliedAt: "2026-07-30T00:00:00Z")
      ])
    XCTAssertEqual(stale.items.first?.action, .conflict)

    let currentHash = try TatwoPluginProjectionV1.fragmentSHA256(
      managed: .fromObserved(codexObserved), brand: .codex)
    let crossBrandOnly = try TatwoPluginStagedPlanV1.build(
      registry: registry, brands: [.codex], codexServers: [codexObserved],
      claudeServers: [], ownershipRecords: [
        TatwoPluginOwnershipRecordV1(
          serverID: "same-id", brand: .claude,
          targetPath: "~/.claude/.mcp.json#mcpServers.same-id",
          appliedFragmentSHA256: currentHash,
          appliedAtRevision: "ownership", appliedAt: "2026-07-30T00:00:00Z")
      ])
    XCTAssertEqual(crossBrandOnly.items.first?.action, .conflict)

    let matching = try TatwoPluginStagedPlanV1.build(
      registry: registry, brands: [.codex], codexServers: [codexObserved],
      claudeServers: [], ownershipRecords: [
        TatwoPluginOwnershipRecordV1(
          serverID: "same-id", brand: .codex,
          targetPath: "~/.codex/config.toml#mcp_servers.same-id",
          appliedFragmentSHA256: currentHash,
          appliedAtRevision: "ownership", appliedAt: "2026-07-30T00:00:00Z")
      ])
    XCTAssertEqual(matching.items.first?.action, .update)

    let desiredObserved = TatwoPluginObservedMcpServerV1(
      serverID: "same-id", source: .codexToml, transport: "stdio",
      command: "desired", args: ["d"])
    let desiredHash = try TatwoPluginProjectionV1.fragmentSHA256(
      managed: .fromObserved(desiredObserved), brand: .codex)
    let unchanged = try TatwoPluginStagedPlanV1.build(
      registry: registry, brands: [.codex], codexServers: [desiredObserved],
      claudeServers: [], ownershipRecords: [
        TatwoPluginOwnershipRecordV1(
          serverID: "same-id", brand: .codex,
          targetPath: "~/.codex/config.toml#mcp_servers.same-id",
          appliedFragmentSHA256: desiredHash,
          appliedAtRevision: "ownership", appliedAt: "2026-07-30T00:00:00Z")
      ])
    XCTAssertEqual(unchanged.items.first?.action, .unchanged)
  }

  func testCodexTOMLEscapesControlsAndSanitizesPaths() throws {
    let id = "bad\"]\n[evil"
    let entry = try portableEntry(
      id: id, command: "runner\nmalicious = \"yes\"",
      args: ["ok", "line1\nline2", "]\u{0001}"])
    let fragment = try XCTUnwrap(
      TatwoPluginProjectionV1.project(entry: entry, brand: .codex).fragment)
    XCTAssertFalse(fragment.logicalPath.contains("\n"))
    XCTAssertFalse(fragment.logicalPath.contains("\r"))
    let diff = TatwoPluginUnifiedDiffV1.diff(
      path: fragment.logicalPath, oldText: "", newText: fragment.body)
    XCTAssertFalse(diff.contains(id))
    XCTAssertTrue(fragment.body.contains("\\n"))
    XCTAssertTrue(fragment.body.contains("\\\""))
    XCTAssertTrue(fragment.body.contains("\\u0001"))
  }

  // MARK: - Helpers

  private func portableEntry(
    id: String,
    command: String,
    args: [String],
    templates: [String: String] = [
      "codex": "codex.mcp-server.v1",
      "claude": "claude.mcp-server.v1",
    ]
  ) throws -> TatwoPluginRegistryEntryV1 {
    var refs: [String: TatwoPluginProjectionTemplateRefV1] = [:]
    for (brand, templateID) in templates {
      refs[brand] = TatwoPluginProjectionTemplateRefV1(templateID: templateID)
    }
    return TatwoPluginRegistryEntryV1(
      id: id,
      type: .portableMcp,
      desiredState: .enabled,
      canonicalDefinition: TatwoPluginCanonicalMcpDefinitionV1(
        transport: .stdio,
        command: command,
        args: args),
      projectionTemplates: refs)
  }

  private func seedRegistryURL() -> URL? {
    // #filePath = <repo>/Packages/TatwoUltraworkCore/Tests/TatwoUltraworkCoreTests/This.swift
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = testsDir
      .deletingLastPathComponent() // TatwoUltraworkCoreTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // TatwoUltraworkCore
      .deletingLastPathComponent() // Packages
    let seed = repoRoot.appendingPathComponent("registry/plugins.v1.json")
    return FileManager.default.fileExists(atPath: seed.path) ? seed : nil
  }
}
