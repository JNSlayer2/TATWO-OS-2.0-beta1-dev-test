import XCTest

@testable import TatwoUltraworkCore

final class EngineAgnosticMCPTests: XCTestCase {
  func testCoreIdentityDefinitionsContainSixCanonicalGroups() throws {
    let kinds = TatwoIdentityCatalog.identityDefinitions.map(\.kind)
    XCTAssertEqual(kinds, [.lead, .supervisor, .consultant, .sub, .news, .verifier])

    for definition in TatwoIdentityCatalog.identityDefinitions {
      XCTAssertFalse(definition.plainDefinition.isEmpty)
      XCTAssertFalse(definition.requiredEvidence.isEmpty)
    }
  }

  func testScenarioProfilesUseDomainIdentitySlotsInsteadOfHardBoundModels() throws {
    let ui = try XCTUnwrap(TatwoIdentityCatalog.scenarioProfile("ui-ux"))
    XCTAssertEqual(ui.baseScenario, .design)
    XCTAssertFalse(ui.allowsNewsIdentity)
    XCTAssertFalse(ui.identitySlots.contains { $0.kind == .news })
    XCTAssertTrue(ui.identitySlots.contains { $0.label == "主視覺" })
    XCTAssertTrue(ui.identitySlots.contains { $0.label == "代碼歸納" })
    XCTAssertTrue(ui.identitySlots.contains { $0.label == "交互驗收" })
    XCTAssertTrue(ui.agentsMarkdownTemplate.contains("主視覺"))

    let video = try XCTUnwrap(TatwoIdentityCatalog.scenarioProfile("video-research"))
    XCTAssertTrue(video.allowsNewsIdentity)
    XCTAssertTrue(video.identitySlots.contains { $0.kind == .news })
  }

  func testCodexIsHighestFitHostButNotTheOnlyEngine() throws {
    let engines = TatwoIdentityCatalog.engines
    let codex = try XCTUnwrap(TatwoIdentityCatalog.engine(.codex))
    XCTAssertTrue(codex.isDefaultHost)
    XCTAssertEqual(codex.hostFitScore, engines.map(\.hostFitScore).max())
    XCTAssertTrue(codex.canMutateHostSafely)

    XCTAssertGreaterThan(engines.count, 1)
    XCTAssertTrue(engines.contains { $0.engineID == .claudeCLI })
    XCTAssertTrue(engines.contains { $0.engineID == .grok })
    XCTAssertTrue(engines.contains { $0.engineID == .minimax })
    XCTAssertTrue(
      engines.filter { $0.engineID != .codex }.allSatisfy { !$0.canMutateHostSafely },
      "External engines stay advisory unless a safe host adapter is explicitly added")
  }

  func testModePlanOutputsIdentityGroupsBudgetsAndReceipts() throws {
    let xl = TatwoIdentityCatalog.modePlan(mode: .xl, scenarioProfileID: "ui-ux")
    XCTAssertEqual(xl.mode, .xl)
    XCTAssertEqual(xl.helperLimit, 48)
    XCTAssertEqual(xl.roundLimit, 3)
    XCTAssertTrue(xl.sandboxRequired)
    XCTAssertTrue(xl.humanApprovalRequired)
    XCTAssertTrue(xl.identitySlots.contains { $0.kind == .lead })
    XCTAssertTrue(xl.identitySlots.contains { $0.kind == .verifier })
    XCTAssertTrue(xl.identitySlots.contains { $0.label == "主視覺" })
    XCTAssertTrue(xl.requiredReceipts.contains("identity plan receipt"))
    XCTAssertTrue(xl.requiredReceipts.contains("sandbox receipt"))
  }

  func testGateway56GenericIdentityRoutesStayAlignedAcrossCatalogScenarioAndDispatch() throws {
    XCTAssertEqual(TatwoGatewayDispatchCatalog.models(for: .lead), ["fable-5"])
    XCTAssertEqual(TatwoGatewayDispatchCatalog.models(for: .supervisor), ["gpt-5.6-terra"])
    XCTAssertEqual(TatwoGatewayDispatchCatalog.models(for: .sub), ["gpt-5.6-sol"])

    let genericModePlan = TatwoIdentityCatalog.modePlan(mode: .xxl, scenarioProfileID: "daily")
    XCTAssertEqual(
      genericModePlan.identitySlots.first { $0.kind == .lead }?.primaryCandidate?.modelID,
      "fable-5")
    XCTAssertEqual(
      genericModePlan.identitySlots.first { $0.kind == .supervisor }?.primaryCandidate?.modelID,
      "gpt-5.6-terra")
    XCTAssertEqual(
      genericModePlan.identitySlots.first { $0.kind == .sub }?.primaryCandidate?.modelID,
      "gpt-5.6-sol")

    let scenario = TatwoScenarioConfigDefaults.defaultModeConfig(.xxl)
    XCTAssertEqual(scenario.bindings.first { $0.identity == "主導" }?.boundModelIDs, ["fable-5"])
    XCTAssertEqual(scenario.bindings.first { $0.identity == "副審" }?.boundModelIDs, ["gpt-5.6-terra"])
    XCTAssertEqual(scenario.bindings.first { $0.identity == "sub" }?.boundModelIDs, ["gpt-5.6-sol"])

    for model in ["fable-5", "gpt-5.6-sol", "gpt-5.6-terra"] {
      XCTAssertTrue(TatwoGatewayDispatchCatalog.allowedModels.contains(model))
      XCTAssertTrue(TatwoExecutionManifestFactory.isDispatchable(modelID: model))
    }
  }

  func testCodingIdentityProfileSpecializesGenericLeadToSolAndKeepsProAdvisory() throws {
    let codingModePlan = TatwoIdentityCatalog.modePlan(
      mode: .xxl,
      scenarioProfileID: "coding")

    XCTAssertEqual(
      codingModePlan.identitySlots.first { $0.kind == .lead }?.primaryCandidate?.modelID,
      "gpt-5.6-sol")
    XCTAssertEqual(
      codingModePlan.identitySlots.first { $0.kind == .consultant }?.primaryCandidate?.engineID,
      .chatgptProMCP)
    XCTAssertEqual(
      codingModePlan.identitySlots.first { $0.kind == .consultant }?.primaryCandidate?.modelID,
      "pro-research")
    XCTAssertEqual(
      codingModePlan.identitySlots.first { $0.kind == .consultant }?.primaryCandidate?.authority,
      .researchBridge)
    XCTAssertFalse(
      codingModePlan.identitySlots.first { $0.kind == .consultant }?.primaryCandidate?
        .canMutateHost ?? true)
  }

  func testWorkflowRunPlanCarriesIdentitySlotsForAgents() throws {
    let plan = WorkflowRunFactory.makePlan(
      objective: "engine agnostic app mcp",
      mode: .xl,
      scenario: .design
    )

    XCTAssertEqual(plan.schema, "TatwoWorkflowRunPlanV1")
    XCTAssertFalse(plan.identitySlots.isEmpty)
    XCTAssertTrue(plan.identitySlots.contains { $0.kind == .lead })
    XCTAssertTrue(plan.identitySlots.contains { $0.kind == .verifier })
    XCTAssertTrue(plan.stopRules.contains { $0.contains("UI/UX") || $0.contains("截圖") })
  }

  func testMCPRegistryExposesRequiredStableToolsAndFallbackCalls() throws {
    let names = Set(TatwoMCPRegistry.tools.map(\.name))
    XCTAssertTrue(names.contains("tatwo.mcp.manifest"))
    XCTAssertTrue(names.contains("tatwo.mcp.client_config"))
    XCTAssertTrue(names.contains("tatwo.engine.capabilities"))
    XCTAssertTrue(names.contains("tatwo.identities.list"))
    XCTAssertTrue(names.contains("tatwo.scenario.get"))
    XCTAssertTrue(names.contains("tatwo.scenario.agents"))
    XCTAssertTrue(names.contains("tatwo.scenario.workflow"))
    XCTAssertTrue(names.contains("tatwo.os.begin"))
    XCTAssertTrue(names.contains("tatwo.os.session.attach"))
    XCTAssertTrue(names.contains("tatwo.os.next"))
    XCTAssertTrue(names.contains("tatwo.os.loop.status"))
    XCTAssertTrue(names.contains("tatwo.os.receipt.submit"))
    XCTAssertTrue(names.contains("tatwo.os.goal.close"))
    XCTAssertTrue(names.contains("tatwo.gateway.status"))
    XCTAssertTrue(names.contains("tatwo.gateway.models"))
    XCTAssertTrue(names.contains("tatwo.gateway.dispatch"))
    XCTAssertTrue(names.contains("tatwo.gateway.fanout"))
    XCTAssertTrue(names.contains("tatwo.sandbox.begin"))
    XCTAssertTrue(names.contains("tatwo.sandbox.write_artifact"))
    XCTAssertTrue(names.contains("tatwo.sandbox.run_command"))
    XCTAssertTrue(names.contains("tatwo.sandbox.receipt"))
    XCTAssertTrue(names.contains("tatwo.sandbox.promote_plan"))
    XCTAssertTrue(names.contains("tatwo.traits.list"))
    XCTAssertTrue(names.contains("tatwo.mode.plan"))
    XCTAssertTrue(names.contains("tatwo.ultrawork.topics"))
    XCTAssertTrue(names.contains("tatwo.workflow.preview"))
    XCTAssertTrue(names.contains("tatwo.receipt.requirements"))
    XCTAssertTrue(names.contains("tatwo.handoff.pack"))
    let readOnlyToolNames = Set(
      TatwoMCPRegistry.tools
        .filter { !$0.hostMutationAllowed }
        .map(\.name))
    XCTAssertTrue(readOnlyToolNames.contains("tatwo.scenario.workflow"))
    XCTAssertTrue(readOnlyToolNames.contains("tatwo.mode.plan"))
    XCTAssertTrue(readOnlyToolNames.contains("tatwo.gateway.dispatch"))

    let result = TatwoMCPRegistry.call(
      tool: "tatwo.mode.plan",
      arguments: ["mode": .string("XL"), "scenario": .string("ui-ux")]
    )
    XCTAssertTrue(result.ok)
    XCTAssertTrue(result.fallbackCoreLibraryUsed)
    XCTAssertFalse(result.hostMutationAllowed)
  }

  func testPreviewMCPToolsUseExactStagingScenarioBookAndUnknownCustomFailsClosed() throws {
    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
    var book = duplicated.book
    let scenarioIndex = try XCTUnwrap(
      book.scenarios.firstIndex { $0.id == duplicated.scenarioID })
    var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
    config.bindings = [
      TatwoScenarioIdentityBinding(
        id: "mcp-staging-lead",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.6-sol"],
        responsibility: "MCP staging lead",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "mcp-staging-supervisor",
        phase: .loops,
        identity: "副審",
        boundModelIDs: ["opus-5"],
        responsibility: "MCP staging supervisor",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "mcp-staging-sub",
        phase: .loops,
        identity: "sub",
        boundModelIDs: ["gpt-5.6-luna", "grok-build"],
        responsibility: "MCP staging exact sub routes",
        dynamicActivation: .allowed),
    ]
    book.scenarios[scenarioIndex].modeConfigs[.xxl] = config

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-mcp-preview-\(UUID().uuidString)", isDirectory: true)
    let configURL = root.appendingPathComponent("scenario-config.json")
    try TatwoScenarioConfigStore(fileURL: configURL).save(book)
    setenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH", configURL.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH")
      try? FileManager.default.removeItem(at: root)
    }

    let expectedContract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID: duplicated.scenarioID,
      objective: "Tatwo receipt requirements",
      scenarioBook: book)
    let expectedModels = ["gpt-5.6-sol", "opus-5", "gpt-5.6-luna", "grok-build"]

    let modeResult = TatwoMCPRegistry.call(
      tool: "tatwo.mode.plan",
      arguments: [
        "mode": .string("XXL"),
        "scenario": .string(duplicated.scenarioID),
      ])
    XCTAssertTrue(modeResult.ok, modeResult.error ?? "")
    XCTAssertEqual(try primaryModels(inModePlanPayload: modeResult.payload), expectedModels)

    let workflowResult = TatwoMCPRegistry.call(
      tool: "tatwo.workflow.preview",
      arguments: [
        "mode": .string("XXL"),
        "scenario": .string(duplicated.scenarioID),
      ])
    XCTAssertTrue(workflowResult.ok, workflowResult.error ?? "")
    guard case .object(let workflowPayload)? = workflowResult.payload else {
      return XCTFail("expected workflow preview payload")
    }
    XCTAssertEqual(
      try primaryModels(inModePlanPayload: workflowPayload["modePlan"]),
      expectedModels)
    XCTAssertEqual(
      try primaryModels(inModePlanPayload: workflowPayload["workflow"]),
      expectedModels)
    XCTAssertEqual(
      workflowPayload["workflowKind"],
      .string("exact_identity_topology_preview"))
    XCTAssertEqual(
      workflowPayload["processTemplateScope"],
      .string("generic_plg_process_not_identity_topology"))
    guard case .string(let mermaid)? = workflowPayload["mermaid"] else {
      return XCTFail("expected exact identity topology mermaid")
    }
    for model in expectedModels {
      XCTAssertTrue(mermaid.contains(model), "mermaid must expose exact route \(model)")
    }

    let receiptResult = TatwoMCPRegistry.call(
      tool: "tatwo.receipt.requirements",
      arguments: [
        "mode": .string("XXL"),
        "scenario": .string(duplicated.scenarioID),
      ])
    XCTAssertTrue(receiptResult.ok, receiptResult.error ?? "")
    guard case .object(let receiptPayload)? = receiptResult.payload,
      case .array(let receiptValues)? = receiptPayload["receipts"]
    else {
      return XCTFail("expected receipt requirement payload")
    }
    XCTAssertEqual(
      receiptValues.compactMap {
        guard case .string(let value) = $0 else { return nil }
        return value
      },
      expectedContract.receiptRequirements.map(\.id))

    for tool in ["tatwo.mode.plan", "tatwo.workflow.preview", "tatwo.receipt.requirements"] {
      let unknown = TatwoMCPRegistry.call(
        tool: tool,
        arguments: [
          "mode": .string("XXL"),
          "scenario": .string("custom-copy-does-not-exist"),
        ])
      XCTAssertFalse(unknown.ok, "\(tool) must fail closed for an unknown custom scenario")
    }
  }

  func testMCPSessionAttachRehydratesCurrentGoalAndFailsClosedOnMismatch() throws {
    let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-mcp-session-attach-\(UUID().uuidString)", isDirectory: true)
    setenv("TATWO_ULTRAWORK_APP_SUPPORT", appSupport.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_APP_SUPPORT")
      // The test only owns this root if the exercised paths materialized it.
      // Cleanup must be idempotent when a fail-closed path leaves it absent.
      if FileManager.default.fileExists(atPath: appSupport.path) {
        try? FileManager.default.removeItem(at: appSupport)
      }
    }
    let stateRoot = appSupport.appendingPathComponent(
      "state", isDirectory: true)
    let workspace = appSupport.appendingPathComponent(
      "workspace", isDirectory: true)
    let ownerThread = "mcp-exact-thread"
    let projected = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "MCP exact session attach")
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: stateRoot,
      contractID: projected.contractID)

    let begin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: [
        "mode": .string("XXL"),
        "scenario": .string("coding"),
        "objective": .string("MCP exact session attach"),
        "provider": .string("codex"),
        "workspace": .string(workspace.path),
        "stateRoot": .string(stateRoot.path),
        "ownerThread": .string(ownerThread),
      ])
    guard case .object(let beginPayload)? = begin.payload,
      case .string(let contractID)? = beginPayload["contractID"],
      case .string(let goalID)? = beginPayload["goalID"]
    else { return XCTFail("expected contractID and goalID from os.begin") }
    let record = try TatwoGoalRunStore.default().requireIssuedContract(contractID)

    let attached = TatwoMCPRegistry.call(
      tool: "tatwo_os_session_attach",
      arguments: [
        "provider": .string("codex"),
        "workspace": .string(workspace.path),
        "ownerThread": .string(ownerThread),
        "contractID": .string(contractID),
        "goalID": .string(goalID),
        "mode": .string("XXL"),
        "scenario": .string(record.scenario),
        "objective": .string(record.objective),
      ])
    XCTAssertTrue(attached.ok, attached.error ?? "")

    let wrongKind = TatwoMCPRegistry.call(
      tool: "tatwo.os.session.attach",
      arguments: [
        "provider": .string("codex"),
        "workspace": .string(workspace.path),
        "ownerSession": .string(ownerThread),
      ])
    XCTAssertFalse(wrongKind.ok)
    XCTAssertTrue(
      wrongKind.error?.contains("ownerKind") == true,
      wrongKind.error ?? "")

    let neitherOwner = TatwoMCPRegistry.call(
      tool: "tatwo.os.session.attach",
      arguments: [
        "provider": .string("codex"),
        "workspace": .string(workspace.path),
      ])
    XCTAssertFalse(neitherOwner.ok)
    XCTAssertEqual(
      neitherOwner.error,
      "exactly_one_required:ownerSession,ownerThread")

    let bothOwners = TatwoMCPRegistry.call(
      tool: "tatwo.os.session.attach",
      arguments: [
        "provider": .string("codex"),
        "workspace": .string(workspace.path),
        "ownerSession": .string(ownerThread),
        "ownerThread": .string(ownerThread),
      ])
    XCTAssertFalse(bothOwners.ok)
    XCTAssertEqual(
      bothOwners.error,
      "exactly_one_required:ownerSession,ownerThread")

    let missingProvider = TatwoMCPRegistry.call(
      tool: "tatwo.os.session.attach",
      arguments: [
        "workspace": .string(workspace.path),
        "ownerThread": .string(ownerThread),
      ])
    XCTAssertFalse(missingProvider.ok)
    XCTAssertEqual(
      missingProvider.error,
      "missing_or_invalid_required:provider,workspace")

    let goalDirectory = TatwoGoalRunStore.default().directoryURL
      .appendingPathComponent("goals", isDirectory: true)
    let goalFiles = try FileManager.default.contentsOfDirectory(
      at: goalDirectory,
      includingPropertiesForKeys: nil)
    XCTAssertEqual(goalFiles.filter { $0.pathExtension == "json" }.count, 1)

    let mismatched = TatwoMCPRegistry.call(
      tool: "tatwo.os.session.attach",
      arguments: [
        "provider": .string("codex"),
        "workspace": .string(workspace.path),
        "ownerThread": .string(ownerThread),
        "contractID": .string("contract-xxl-coding-different"),
      ])
    XCTAssertFalse(mismatched.ok)
    XCTAssertTrue(mismatched.error?.contains("contractID") == true)
  }

  func testGatewayAndSandboxFallbackToolsAreFailClosedAndUsable() throws {
    // B2/E: gateway.dispatch now requires a registered contract. Redirect the store to a
    // temp dir and begin a real contract for the gateway sub-block.
    let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-gw-\(UUID().uuidString)", isDirectory: true)
    setenv("TATWO_ULTRAWORK_APP_SUPPORT", appSupport.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_APP_SUPPORT")
      try? FileManager.default.removeItem(at: appSupport)
    }

    let noContract = TatwoMCPRegistry.call(
      tool: "tatwo_gateway_dispatch",
      arguments: ["model": .string("minimax-m3"), "prompt": .string("ping")]
    )
    XCTAssertFalse(noContract.ok)
    XCTAssertTrue(noContract.error?.contains("contractID") == true)

    // A never-issued contractID is now rejected (not just non-empty).
    let forgedContract = TatwoMCPRegistry.call(
      tool: "tatwo.gateway.dispatch",
      arguments: [
        "contractID": .string("contract-m-coding-ffffffffffff"),
        "model": .string("minimax-m3"), "prompt": .string("ping"), "dryRun": .bool(true),
      ]
    )
    XCTAssertFalse(forgedContract.ok)

    let osBegin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "M", scenario: "coding", objective: "gateway gate"))
    guard case .object(let osBeginPayload)? = osBegin.payload,
      case .string(let contractID)? = osBeginPayload["contractID"]
    else { return XCTFail("expected contractID from os.begin") }

    let gatewayDryRun = TatwoMCPRegistry.call(
      tool: "tatwo.gateway.dispatch",
      arguments: [
        "contractID": .string(contractID),
        "model": .string("minimax-m3"),
        "prompt": .string("Return one sentence."),
        "dryRun": .bool(true),
      ]
    )
    XCTAssertTrue(gatewayDryRun.ok, gatewayDryRun.error ?? "")
    XCTAssertFalse(gatewayDryRun.hostMutationAllowed)
    let gatewayText = String(data: try JSONEncoder().encode(gatewayDryRun), encoding: .utf8) ?? ""
    XCTAssertTrue(gatewayText.contains("TatwoGatewayDispatchReceiptV1"))
    XCTAssertTrue(gatewayText.contains("hostMutationAllowed"))
    XCTAssertFalse(gatewayText.contains("/Users/"))
    XCTAssertFalse(gatewayText.contains("/Volumes/"))

    let imageDispatch = TatwoMCPRegistry.call(
      tool: "tatwo.gateway.dispatch",
      arguments: [
        "contractID": .string(contractID),
        "model": .string("minimax-m3"),
        "prompt": .string("Inspect the image."),
        "attachmentPaths": .array([.string("/tmp/reference.png")]),
        "dryRun": .bool(true),
      ])
    XCTAssertFalse(imageDispatch.ok)
    XCTAssertEqual(imageDispatch.error, "unsupported_input:image_attachment")

    let deferredSonnet = TatwoMCPRegistry.call(
      tool: "tatwo.gateway.dispatch",
      arguments: [
        "contractID": .string(contractID),
        "model": .string("sonnet-4-6"),
        "prompt": .string("Review only."),
        "dryRun": .bool(true),
      ])
    XCTAssertFalse(deferredSonnet.ok)
    XCTAssertEqual(deferredSonnet.error, "route_health_v2_required:sonnet-5")

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("tatwo-swift-mcp-sandbox-\(UUID().uuidString)", isDirectory: true)
    setenv("TATWO_ULTRAWORK_SANDBOX_ROOT", tmp.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_SANDBOX_ROOT")
      try? FileManager.default.removeItem(at: tmp)
    }

    let begin = TatwoMCPRegistry.call(
      tool: "tatwo.sandbox.begin",
      arguments: [
        "contractID": .string(contractID),
        "sandboxID": .string("test-sandbox"),
        "objective": .string("unit sandbox"),
      ])
    XCTAssertTrue(begin.ok)

    let escape = TatwoMCPRegistry.call(
      tool: "tatwo.sandbox.write_artifact",
      arguments: [
        "contractID": .string(contractID),
        "sandboxID": .string("test-sandbox"),
        "relativePath": .string("../escape.txt"),
        "content": .string("no"),
      ])
    XCTAssertFalse(escape.ok)

    let write = TatwoMCPRegistry.call(
      tool: "tatwo.sandbox.write_artifact",
      arguments: [
        "contractID": .string(contractID),
        "sandboxID": .string("test-sandbox"),
        "relativePath": .string("generated-artifacts/hello.js"),
        "content": .string("console.log('OK_TATWO_SWIFT_SANDBOX')"),
      ])
    XCTAssertTrue(write.ok)

    let run = TatwoMCPRegistry.call(
      tool: "tatwo.sandbox.run_command",
      arguments: [
        "contractID": .string(contractID),
        "sandboxID": .string("test-sandbox"),
        "command": .string("node"),
        "args": .array([.string("generated-artifacts/hello.js")]),
      ])
    XCTAssertTrue(run.ok)
    let runText = String(data: try JSONEncoder().encode(run), encoding: .utf8) ?? ""
    XCTAssertTrue(runText.contains("OK_TATWO_SWIFT_SANDBOX"))

    let receipt = TatwoMCPRegistry.call(
      tool: "tatwo.sandbox.receipt",
      arguments: [
        "contractID": .string(contractID),
        "sandboxID": .string("test-sandbox"),
      ])
    XCTAssertTrue(receipt.ok)
    let receiptText = String(data: try JSONEncoder().encode(receipt), encoding: .utf8) ?? ""
    XCTAssertTrue(receiptText.contains("TatwoSandboxReceiptBundleV1"))

    let promote = TatwoMCPRegistry.call(
      tool: "tatwo.sandbox.promote_plan",
      arguments: [
        "contractID": .string(contractID),
        "sandboxID": .string("test-sandbox"),
      ])
    XCTAssertTrue(promote.ok)
    let promoteText = String(data: try JSONEncoder().encode(promote), encoding: .utf8) ?? ""
    XCTAssertTrue(promoteText.contains("\"promoteAllowed\":false"))
    XCTAssertTrue(promoteText.contains("\"hostMutationAllowed\":false"))
  }

  func testAppMCPManifestIsCallableFromCLIAndNotCodexOnly() throws {
    let manifest = TatwoMCPRegistry.manifest
    XCTAssertTrue(manifest.engineAgnostic)
    XCTAssertEqual(manifest.defaultHostEngine, EngineID.codex.rawValue)
    XCTAssertTrue(manifest.plainContract.contains("Codex"))
    XCTAssertTrue(manifest.plainContract.contains("CLI"))
    XCTAssertTrue(manifest.clientEntrypoints.contains { $0.canCallFromCLI && !$0.requiresCodexHost })

    let manifestResult = TatwoMCPRegistry.call(tool: "tatwo_app_mcp_manifest")
    XCTAssertTrue(manifestResult.ok)
    XCTAssertFalse(manifestResult.hostMutationAllowed)

    let clientConfig = TatwoMCPRegistry.call(
      tool: "tatwo.mcp.client_config",
      arguments: ["engine": .string("claude-cli")]
    )
    XCTAssertTrue(clientConfig.ok)
    let text = String(data: try JSONEncoder().encode(clientConfig), encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("TatwoMCPClientConfigV1"))
    XCTAssertTrue(text.contains("codexRequired"))
    XCTAssertTrue(text.contains("false"))
    XCTAssertTrue(text.contains("tatwo-ultrawork mcp call"))

    let engine = TatwoMCPRegistry.call(
      tool: "tatwo_engine_capabilities",
      arguments: ["engine": .string("codex")]
    )
    XCTAssertTrue(engine.ok)
  }

  func testReceiptRequirementsFailClosedForUIWithoutVisualEvidence() throws {
    let result = TatwoMCPRegistry.call(
      tool: "tatwo.receipt.requirements",
      arguments: ["mode": .string("XL"), "scenario": .string("ui-ux")]
    )
    XCTAssertTrue(result.ok)
    let data = try JSONEncoder().encode(result)
    let text = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("UI") || text.contains("screenshot"))
    XCTAssertFalse(text.contains("/Users/"))
    XCTAssertFalse(text.contains("/Volumes/"))
  }

  private func primaryModels(inModePlanPayload payload: JSONValue?) throws -> [String] {
    guard case .object(let modePlan)? = payload,
      case .array(let slots)? = modePlan["identitySlots"]
    else {
      throw NSError(
        domain: "EngineAgnosticMCPTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "missing ModeIdentityPlan identitySlots"])
    }
    return slots.compactMap { slot in
      guard case .object(let slotObject) = slot,
        case .array(let candidates)? = slotObject["candidates"],
        case .object(let primary)? = candidates.first,
        case .string(let modelID)? = primary["modelID"]
      else { return nil }
      return modelID
    }
  }
}
