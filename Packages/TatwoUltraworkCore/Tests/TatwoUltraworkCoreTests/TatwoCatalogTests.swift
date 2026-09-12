import XCTest

@testable import TatwoUltraworkCore

final class TatwoCatalogTests: XCTestCase {
  func testDefaultsExposeAllWorkModesAndFiveScenarios() throws {
    let catalog = TatwoCatalog.defaults
    XCTAssertEqual(catalog.workModes.map(\.mode), [.s, .m, .l, .xl, .xxl])
    XCTAssertEqual(
      Set(catalog.scenarios.map(\.scenario)), Set([.daily, .design, .coding, .trading, .modeling]))
  }

  func testXLRequiresSandboxAndHumanApproval() throws {
    let xl = try XCTUnwrap(TatwoCatalog.defaults.mode(.xl))
    XCTAssertTrue(xl.requiresSandbox)
    XCTAssertTrue(xl.requiresHumanApproval)
    XCTAssertTrue(xl.requiresIndependentVerification)
    XCTAssertEqual(xl.maxHelpers, 48)
    XCTAssertEqual(xl.maxRounds, 3)
  }

  func testXXLIsARealOrchestrationModeWithBoundedConcurrency() throws {
    let xxl = try XCTUnwrap(TatwoCatalog.defaults.mode(.xxl))
    XCTAssertTrue(xxl.requiresSandbox)
    XCTAssertTrue(xxl.requiresHumanApproval)
    XCTAssertTrue(xxl.requiresIndependentVerification)
    XCTAssertEqual(xxl.maxHelpers, 4)
    XCTAssertEqual(xxl.maxRounds, 3)
    XCTAssertTrue(xxl.plainDescription.contains("編排手"))
    XCTAssertTrue(xxl.stopRules.contains { $0.contains("最多 4 個 helper") })
  }

  func testOpusIsRestoredAsDefaultDeputyReviewerWhenClaudeIsAvailable() throws {
    let medium = try XCTUnwrap(TatwoCatalog.defaults.mode(.m))
    XCTAssertTrue(
      medium.roleAssignments.contains {
        $0.model == "opus-5" && $0.role.contains("副審") && $0.defaultAuthority == .brainOnly
      })

    let design = try XCTUnwrap(TatwoCatalog.defaults.scenario(.design))
    XCTAssertTrue(
      design.roleWeights.contains {
        $0.model == "opus-5" && ($0.role.contains("副審") || $0.role.contains("驗收"))
      })
  }

  func testTradingScenarioIsReadOnlyByDefault() throws {
    let trading = try XCTUnwrap(TatwoCatalog.defaults.scenario(.trading))
    XCTAssertTrue(trading.readOnlyByDefault)
    XCTAssertTrue(trading.guardrails.contains { $0.contains("不直接下單") })
  }

  func testPluginRegistryContainsRequiredEntries() throws {
    let ids = Set(TatwoCatalog.defaults.plugins.map(\.id))
    XCTAssertTrue(ids.contains("gitnexus"))
    XCTAssertTrue(ids.contains("chatgpt-pro-mcp"))
    XCTAssertTrue(ids.contains("open-ultrawork"))
    XCTAssertTrue(ids.contains("tatworoom-web-app"))
    XCTAssertTrue(ids.contains("codex-app-model-gateway"))
    XCTAssertTrue(ids.contains("colima-sandbox-runner"))
    XCTAssertTrue(ids.contains("web-check"))
    XCTAssertTrue(ids.contains("product-design"))

    let gitnexus = try XCTUnwrap(TatwoCatalog.defaults.plugins.first { $0.id == "gitnexus" })
    XCTAssertEqual(gitnexus.requiredForModes, [.m, .l, .xl, .xxl])
    XCTAssertTrue(gitnexus.trigger.contains("M/L/XL/XXL"))

    let proMCP = try XCTUnwrap(
      TatwoCatalog.defaults.plugins.first { $0.id == "chatgpt-pro-mcp" })
    XCTAssertEqual(proMCP.requiredForModes, [.m, .l, .xl, .xxl])
    XCTAssertTrue(proMCP.publicInstallHint.contains("required"))

    let colima = try XCTUnwrap(
      TatwoCatalog.defaults.plugins.first { $0.id == "colima-sandbox-runner" })
    XCTAssertEqual(colima.kind, .localRuntime)
    XCTAssertEqual(colima.requiredForModes, [.l, .xl])
    XCTAssertTrue(colima.purpose.contains("不是模型") || colima.purpose.contains("not"))

    let webCheck = try XCTUnwrap(TatwoCatalog.defaults.plugins.first { $0.id == "web-check" })
    XCTAssertEqual(webCheck.kind, .skill)
    XCTAssertEqual(webCheck.requiredForModes, [.m, .l, .xl])
    XCTAssertTrue(webCheck.purpose.contains("驗收收據"))
    XCTAssertTrue(webCheck.trigger.contains("UI"))

    let productDesign = try XCTUnwrap(
      TatwoCatalog.defaults.plugins.first { $0.id == "product-design" })
    XCTAssertEqual(productDesign.kind, .plugin)
    XCTAssertEqual(productDesign.requiredForModes, [.m, .l, .xl])
    XCTAssertTrue(productDesign.purpose.contains("UI/UJ"))
    XCTAssertTrue(productDesign.trigger.contains("L/XL"))

    let xxlModeWideIDs = Set(
      TatwoCatalog.defaults.plugins
        .filter { $0.requiredForModes.contains(.xxl) }
        .map(\.id))
    XCTAssertEqual(
      xxlModeWideIDs,
      Set([
        "gitnexus",
        "chatgpt-pro-mcp",
        "tatwo-ultrawork",
        "tatwo-ultrawork-mcp",
        "codex-app-model-gateway",
      ]))
  }

  func testPluginRegistryMatchesCurrentCodexPluginEnvironment() throws {
    let plugins = TatwoCatalog.defaults.plugins
    for entry in plugins {
      XCTAssertNotEqual(entry.installState, .unknown, "unknown install state: \(entry.id)")
      XCTAssertFalse(
        (entry.smokeCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "missing smoke command: \(entry.id)")
    }

    let expectedInstallStates: [String: InstallState] = [
      "gitnexus": .installed,
      "chatgpt-pro-mcp": .installed,
      "tatwo-ultrawork": .installed,
      "computer-use": .installed,
      "gbrain": .installed,
      "creative-production": .installed,
      "product-design": .installed,
      "build-macos-app": .installed,
      "superpowers": .installed,
    ]

    for (id, installState) in expectedInstallStates {
      let entry = try XCTUnwrap(plugins.first { $0.id == id }, "missing registry entry: \(id)")
      XCTAssertEqual(entry.installState, installState, "wrong install state: \(id)")

      let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
      let object = try XCTUnwrap(encoded as? [String: Any])
      let smokeCommand = try XCTUnwrap(object["smokeCommand"] as? String)
      XCTAssertFalse(smokeCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    let superpowers = try XCTUnwrap(plugins.first { $0.id == "superpowers" })
    XCTAssertTrue(superpowers.publicInstallHint.contains("deprecated-for-gpt56"))
    XCTAssertTrue(superpowers.publicInstallHint.contains("不推薦"))
  }

  func testWorkflowPreviewIncludesSandboxVerifierJudgeAndInstall() throws {
    let workflow = WorkflowFactory.make(mode: .xl, scenario: .coding)
    let kinds = Set(workflow.nodes.map(\.kind))
    XCTAssertTrue(kinds.contains(.projectMap))
    XCTAssertTrue(kinds.contains(.sandbox))
    XCTAssertTrue(kinds.contains(.verifier))
    XCTAssertTrue(kinds.contains(.judge))
    XCTAssertTrue(kinds.contains(.hostInstall))
    XCTAssertTrue(
      workflow.nodes.contains {
        $0.id == "project-map" && $0.ownerRole.contains("GitNexus") && $0.mustProduceEvidence
      })
    XCTAssertTrue(
      workflow.nodes.contains { $0.id == "sandbox" && $0.plainDescription.contains("Colima") })
    XCTAssertTrue(
      workflow.nodes.contains { $0.id == "verifier" && $0.ownerRole.contains("Colima") })
    XCTAssertFalse(workflow.hostMutationPolicy.isEmpty)
  }

  func testScenarioParserAcceptsCodeAlias() throws {
    XCTAssertEqual(try ScenarioID.parse("code"), .coding)
    XCTAssertEqual(try WorkModeID.parse("xl"), .xl)
  }

  func testDoctorKeepsGatewayContractUnknownUntilExternalSmokeRuns() throws {
    let report = DoctorFactory.staticReport(chatGPTProMCPCheck: Self.proMCPCheck(status: .installed))
    let gateway = try XCTUnwrap(report.checks.first { $0.id == "gateway-contract" })
    let proMCP = try XCTUnwrap(report.checks.first { $0.id == "chatgpt-pro-mcp" })

    XCTAssertEqual(gateway.status, .unknown)
    XCTAssertEqual(gateway.severity, .critical)
    XCTAssertEqual(proMCP.status, .installed)
    XCTAssertTrue(report.coreReady)
    XCTAssertTrue(report.sandboxReady)
    XCTAssertFalse(report.hostReady)
    XCTAssertFalse(report.ok)
    XCTAssertFalse(report.hostMutationAllowed)
    XCTAssertTrue(report.blockingReasons.contains { $0.contains("gateway-contract:unknown") })
    XCTAssertFalse(report.blockingReasons.contains { $0.contains("chatgpt-pro-mcp:unknown") })
  }

  func testDoctorModelsChatGPTProMCPInstalledMissingAndCommandFailedWithoutUnknown() throws {
    let installed = DoctorFactory.staticReport(chatGPTProMCPCheck: Self.proMCPCheck(status: .installed))
    XCTAssertEqual(installed.checks.first { $0.id == "chatgpt-pro-mcp" }?.status, .installed)
    XCTAssertFalse(installed.blockingReasons.contains { $0.contains("chatgpt-pro-mcp") })

    let missing = DoctorFactory.staticReport(chatGPTProMCPCheck: Self.proMCPCheck(status: .missing))
    XCTAssertEqual(missing.checks.first { $0.id == "chatgpt-pro-mcp" }?.status, .missing)
    XCTAssertTrue(missing.blockingReasons.contains { $0.contains("chatgpt-pro-mcp:missing") })
    XCTAssertFalse(missing.blockingReasons.contains { $0.contains("chatgpt-pro-mcp:unknown") })

    let commandFailed = DoctorFactory.staticReport(
      chatGPTProMCPCheck: Self.proMCPCheck(status: .missing, message: "doctor command failed"))
    XCTAssertEqual(commandFailed.checks.first { $0.id == "chatgpt-pro-mcp" }?.status, .missing)
    XCTAssertTrue(commandFailed.blockingReasons.contains { $0.contains("doctor command failed") })
    XCTAssertFalse(commandFailed.blockingReasons.contains { $0.contains("chatgpt-pro-mcp:unknown") })
  }

  func testN9ChatRouteProfilesAndPermissionPresetsExposeCodexAppLikeControls() throws {
    let routeIDs = Set(TatwoChatRouteProfile.defaults.map(\.id))
    XCTAssertTrue(routeIDs.contains("gpt-5.5"))
    XCTAssertTrue(routeIDs.contains("fable5"))
    XCTAssertTrue(routeIDs.contains("sonnet5"))
    XCTAssertFalse(routeIDs.contains("sonnet4.6"))

    let sonnet = try XCTUnwrap(TatwoChatRouteProfile.defaults.first { $0.id == "sonnet5" })
    XCTAssertEqual(sonnet.canonicalModelSlug, "sonnet-5")
    XCTAssertEqual(sonnet.engine, .claude)
    XCTAssertEqual(sonnet.runtimeAdapter, .claudeCLI)
    XCTAssertEqual(sonnet.modelArgument, "sonnet-5")
    XCTAssertTrue(sonnet.supportsImageInput)
    XCTAssertEqual(sonnet.allowedEfforts, [.low, .medium, .high, .xhigh])
    XCTAssertTrue(sonnet.pluginFit.contains("Loops"))

    let fable = try XCTUnwrap(TatwoChatRouteProfile.defaults.first { $0.id == "fable5" })
    XCTAssertEqual(fable.canonicalModelSlug, "fable-5")
    XCTAssertEqual(fable.engine, .claude)
    XCTAssertEqual(fable.runtimeAdapter, .claudeCLI)
    XCTAssertTrue(fable.supportsImageInput)
    // 2026-08-23 修：CLI 只認 vendor 全名（"fable-5" 會 unrecognized_model）。
    XCTAssertEqual(fable.modelArgument, "claude-fable-5")
    XCTAssertEqual(fable.allowedEfforts, [.low, .medium, .high, .xhigh])

    let minimax = try XCTUnwrap(TatwoChatRouteProfile.defaults.first { $0.id == "minimax-m3" })
    XCTAssertEqual(minimax.canonicalModelSlug, "minimax-m3")
    XCTAssertEqual(minimax.runtimeAdapter, .minimaxDirect)
    XCTAssertFalse(minimax.supportsImageInput)
    XCTAssertTrue(minimax.allowedEfforts.isEmpty)

    let opus5 = try XCTUnwrap(TatwoChatRouteProfile.defaults.first { $0.id == "opus5" })
    XCTAssertEqual(opus5.canonicalModelSlug, "opus-5")
    XCTAssertEqual(opus5.displayName, "Claude Opus 5")
    XCTAssertEqual(opus5.modelArgument, "opus")
    XCTAssertEqual(opus5.engine, .claude)
    XCTAssertEqual(opus5.runtimeAdapter, .claudeCLI)
    XCTAssertEqual(opus5.contextWindowLabel, "judge")
    XCTAssertEqual(opus5.defaultEffort, .xhigh)
    XCTAssertEqual(opus5.allowedEfforts, [.low, .medium, .high, .xhigh])

    let grok = try XCTUnwrap(TatwoChatRouteProfile.defaults.first { $0.id == "grok-build" })
    XCTAssertEqual(grok.displayName, "Grok 4.6")
    XCTAssertEqual(grok.runtimeAdapter, .grokCLI)
    XCTAssertEqual(grok.defaultEffort, .high)
    XCTAssertEqual(grok.allowedEfforts, [.low, .medium, .high, .xhigh])

    XCTAssertEqual(TatwoPermissionPreset.askFirst.codexArguments, ["-s", "read-only"])
    XCTAssertEqual(TatwoPermissionPreset.approveForMe.codexArguments, ["-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=true"])
    XCTAssertEqual(TatwoPermissionPreset.fullAccess.codexArguments, ["-s", "danger-full-access"])
    XCTAssertTrue(TatwoPermissionPreset.configFile.codexArguments.isEmpty)
  }

  private static func proMCPCheck(
    status: InstallState,
    message: String = "test probe"
  ) -> DoctorCheck {
    DoctorCheck(
      id: "chatgpt-pro-mcp",
      title: "ChatGPT Pro MCP",
      status: status,
      severity: .critical,
      message: message,
      remediation: status == .installed ? nil : "fix test probe")
  }
}
