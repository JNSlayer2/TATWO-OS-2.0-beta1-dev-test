import XCTest

@testable import TatwoUltraworkCore

final class WorkflowRunTests: XCTestCase {
  func testXLWorkflowRunPlanIsDryRunSandboxAndManualGateByDefault() throws {
    let plan = WorkflowRunFactory.makePlan(
      objective: "land Tatwo workflow core before UI",
      mode: .xl,
      scenario: .coding
    )

    XCTAssertEqual(plan.schema, "TatwoWorkflowRunPlanV1")
    XCTAssertTrue(plan.dryRunOnly)
    XCTAssertTrue(plan.sandboxRequired)
    XCTAssertTrue(plan.humanApprovalRequired)
    XCTAssertFalse(plan.hostMutationAllowed)
    XCTAssertEqual(plan.helperLimit, 48)
    XCTAssertEqual(plan.roundLimit, 3)
    XCTAssertTrue(plan.steps.contains { $0.id == "project-map" && $0.status == .ready })
    XCTAssertTrue(
      plan.gates.contains {
        $0.id == "project-map" && $0.requiredBeforePass.contains("GitNexus project-map receipt")
      })
    XCTAssertTrue(plan.steps.contains { $0.id == "host-install" && $0.status == .manualGate })
    XCTAssertTrue(plan.gates.contains { $0.id == "roles" })
    XCTAssertTrue(plan.safeMemoryPolicy.contains { $0.contains("不存 raw log") })
  }

  func testDesignScenarioRequiresVisualGate() throws {
    let plan = WorkflowRunFactory.makePlan(
      objective: "validate menu bar panel",
      mode: .m,
      scenario: .design
    )

    XCTAssertTrue(plan.gates.contains { $0.id == "visual" })
    XCTAssertTrue(plan.steps.contains { $0.id == "project-map" && $0.status == .ready })
    let verify = try XCTUnwrap(plan.steps.first { $0.id == "verify" })
    XCTAssertTrue(verify.requiredEvidence.contains(.screenshot))
    XCTAssertTrue(verify.requiredEvidence.contains(.visualDiff))
  }

  func testTradingScenarioAddsReadOnlyRiskGate() throws {
    let plan = WorkflowRunFactory.makePlan(
      objective: "review trading automation",
      mode: .l,
      scenario: .trading
    )

    XCTAssertTrue(plan.stopRules.contains { $0.contains("不直接下單") })
    XCTAssertTrue(plan.gates.contains { $0.id == "trading-risk" })
  }

  func testHandoffPackHasStableHashAndNoRawLocalPathCommands() throws {
    let pack = WorkflowRunFactory.makeHandoffPack(
      objective: "continue Tatwo workflow implementation",
      mode: .xl,
      scenario: .coding
    )

    XCTAssertEqual(pack.schema, "TatwoHandoffPackV1")
    XCTAssertFalse(pack.contentHash.isEmpty)
    XCTAssertEqual(pack.contentHash.count, 64)
    XCTAssertTrue(pack.privacyRules.contains { $0.contains("不包含本機絕對路徑") })
    XCTAssertFalse(pack.commands.contains { $0.contains("/Volumes/") || $0.contains("/Users/") })
  }

  func testWorkflowAndHandoffRedactPrivateObjectiveMaterial() throws {
    let fakeToken = "sk-" + "abc1234567890"
    let fakeBearer = "Authorization: " + "Bearer " + "abcdefghijklmnopqrstuvwxyz"
    let unsafeObjective =
      "review /Volumes/ExampleData/skills/open-ultrawork/SKILL.md and /Users/example/.codex/auth.json \(fakeToken) \(fakeBearer)"
    let plan = WorkflowRunFactory.makePlan(objective: unsafeObjective, mode: .xl, scenario: .coding)
    let pack = WorkflowRunFactory.makeHandoffPack(
      objective: unsafeObjective, mode: .xl, scenario: .coding)

    for text in [plan.objective, pack.objective] {
      XCTAssertFalse(text.contains("/Volumes/"))
      XCTAssertFalse(text.contains("/Users/"))
      XCTAssertFalse(text.contains("auth.json"))
      XCTAssertFalse(text.contains("sk-abc"))
      XCTAssertFalse(text.contains("Bearer abc"))
      XCTAssertTrue(
        text.contains("<local-path>") || text.contains("<token>")
          || text.contains("<private-auth-material>"))
    }
  }

  func testInstallPlanDefaultsToNoHostMutation() throws {
    let plan = WorkflowRunFactory.installPlan()

    XCTAssertEqual(plan.schema, "TatwoHostInstallPlanV1")
    XCTAssertFalse(plan.hostMutationDefault)
    XCTAssertTrue(plan.dependencies.contains { $0.id == "codex-app-model-gateway" })
    XCTAssertTrue(
      plan.dependencies.contains { $0.id == "colima-sandbox-runner" && $0.required == false })
    XCTAssertTrue(
      plan.dependencies.contains {
        $0.id == "chatgpt-pro-mcp" && $0.required == true && $0.defaultAction == .manual
      })
    XCTAssertTrue(
      plan.preflightCommands.contains { $0.contains("install-tatwo-ultrawork.sh --preflight") })
    XCTAssertTrue(plan.preflightCommands.contains { $0.contains("tatwo-ultrawork host preflight") })
    XCTAssertTrue(plan.preflightCommands.contains { $0.contains("tatwo-host-preflight.mjs") })
    XCTAssertTrue(
      plan.preflightCommands.contains { $0.contains("tatwo-host-sandbox-rehearsal.mjs") })
    XCTAssertTrue(plan.preflightCommands.contains { $0.contains("tatwo-host-backup-plan.mjs") })
    XCTAssertTrue(plan.preflightCommands.contains { $0.contains("host receipt-flow") })
    XCTAssertTrue(plan.preflightCommands.contains { $0.contains("tatwo-host-rollback-plan.mjs") })
    XCTAssertTrue(
      plan.preflightCommands.contains { $0.contains("tatwo-host-same-thread-smoke.mjs") })
    XCTAssertTrue(
      plan.preflightCommands.contains { $0.contains("tatwo-host-mcp-registration-smoke.mjs") })
    XCTAssertTrue(plan.preflightCommands.contains { $0.contains("host install-gate") })
    XCTAssertTrue(plan.smokeCommands.contains { $0.contains("tatwo-host-readiness-gate") })
    XCTAssertTrue(plan.smokeCommands.contains { $0.contains("colima preflight") })
    XCTAssertTrue(plan.smokeCommands.contains { $0.contains("tatwo-host-receipt-bundle.mjs") })
    XCTAssertTrue(plan.smokeCommands.contains { $0.contains("tatwo-host-sandbox-rehearsal.mjs") })
    XCTAssertTrue(plan.smokeCommands.contains { $0.contains("host install-gate") })
    XCTAssertTrue(
      plan.smokeCommands.contains { $0.contains("post-update-check") && $0.contains("--full") })
    XCTAssertTrue(plan.rollbackPlan.contains { $0.contains("還原 Codex") })
  }

  func testDefaultCatalogNeverAutoAuthorizesHostInstallForSML() throws {
    for mode in [WorkModeID.s, .m, .l] {
      let plan = WorkflowRunFactory.makePlan(
        objective: "try non dry run host install",
        mode: mode,
        scenario: .coding,
        dryRunOnly: false
      )

      XCTAssertTrue(
        plan.humanApprovalRequired, "non-dry workflow must require a human gate for \(mode)")
      XCTAssertFalse(
        plan.hostMutationAllowed, "workflow run must not authorize host mutation for \(mode)")
      XCTAssertFalse(
        plan.steps.contains { $0.allowedHostMutation },
        "no workflow step may mutate host before readiness gate for \(mode)")

      let hostInstall = try XCTUnwrap(plan.steps.first { $0.id == "host-install" })
      XCTAssertEqual(hostInstall.status, .manualGate)
      XCTAssertFalse(hostInstall.allowedHostMutation)

      let hostGate = try XCTUnwrap(plan.gates.first { $0.id == "host-install" })
      XCTAssertTrue(hostGate.requiredBeforePass.contains("human approval receipt"))
      XCTAssertTrue(hostGate.requiredBeforePass.contains("host sandbox rehearsal receipt"))
      XCTAssertTrue(hostGate.requiredBeforePass.contains("host backup receipt"))
      XCTAssertTrue(hostGate.requiredBeforePass.contains("live same-thread smoke receipt"))
      XCTAssertTrue(hostGate.requiredBeforePass.contains("host MCP registration smoke receipt"))
    }
  }

  func testEmptyCustomCatalogFallsBackWithoutCrashingAndStaysClosed() throws {
    let emptyCatalog = TatwoCatalog(
      usageProviders: [],
      workModes: [],
      scenarios: [],
      compatibility: [],
      plugins: []
    )

    let plan = WorkflowRunFactory.makePlan(
      objective: "empty catalog safety",
      mode: .xl,
      scenario: .coding,
      catalog: emptyCatalog
    )

    XCTAssertEqual(plan.mode, .xl)
    XCTAssertTrue(plan.sandboxRequired)
    XCTAssertTrue(plan.humanApprovalRequired)
    XCTAssertFalse(plan.hostMutationAllowed)
    XCTAssertTrue(plan.stopRules.contains { $0.contains("custom catalog empty") })

    let nonXL = WorkflowRunFactory.makePlan(
      objective: "empty catalog non-xl safety",
      mode: .m,
      scenario: .coding,
      dryRunOnly: false,
      catalog: emptyCatalog
    )
    XCTAssertTrue(nonXL.humanApprovalRequired)
    XCTAssertFalse(nonXL.hostMutationAllowed)
  }
}
