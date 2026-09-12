import XCTest

@testable import TatwoUltraworkCore

final class IntegrationPlanTests: XCTestCase {
  func testIntegrationPlanIsSandboxFirstAndHostClosedByDefault() throws {
    let plan = IntegrationPlanner.makePlan()

    XCTAssertEqual(plan.schema, "TatwoIntegrationPlanV1")
    XCTAssertFalse(plan.hostMutationDefault)
    XCTAssertEqual(plan.stages.first?.id, "preflight")
    XCTAssertTrue(plan.stages.contains { $0.id == "sandbox-smoke" })
    XCTAssertTrue(
      plan.stages.contains { $0.id == "backup-before-host" && $0.requiresHumanApproval })
    XCTAssertTrue(plan.rollbackSteps.contains { $0.contains("還原") || $0.contains("rollback") })
  }

  func testStabilityPlanContainsKnownCodexDisconnectPreventionRules() throws {
    let plan = IntegrationPlanner.stabilityPlan()
    let allText = (plan.guards.map(\.plainRule) + plan.disconnectRules.map(\.rule)).joined(
      separator: "\n")

    XCTAssertEqual(plan.schema, "TatwoStabilityPlanV1")
    XCTAssertTrue(allText.contains("response.in_progress"))
    XCTAssertTrue(allText.contains("64MB"))
    XCTAssertTrue(allText.contains("App bundle"))
    XCTAssertTrue(allText.contains("models_cache.json"))
    XCTAssertTrue(allText.contains("auth") || allText.contains("OAuth"))
    XCTAssertTrue(allText.contains("CODEX_HOME"))
    XCTAssertTrue(allText.contains("rollback") || allText.contains("回滾"))
  }

  func testStableIntegrationNeverPatchesSignedCodexBundleOrWritesLaunchAgentInSandbox() throws {
    let plan = IntegrationPlanner.makePlan()
    let sandbox = try XCTUnwrap(plan.stages.first { $0.id == "sandbox-smoke" })
    let denied = Set(sandbox.deniedActions)

    XCTAssertTrue(denied.contains("patch_signed_codex_app_bundle"))
    XCTAssertTrue(denied.contains("write_real_launchagent"))
    XCTAssertTrue(denied.contains("mutate_host_codex_config"))
  }

  func testIntegrationPlanIncludesGatewayOpenUltraworkAndMCPChecks() throws {
    let plan = IntegrationPlanner.makePlan()
    let checks = plan.stages.flatMap(\.checks).joined(separator: "\n")

    XCTAssertTrue(checks.contains("gateway"))
    XCTAssertTrue(checks.contains("open-ultrawork"))
    XCTAssertTrue(checks.contains("MCP"))
    XCTAssertTrue(checks.contains("redaction"))
    XCTAssertTrue(checks.contains("readiness"))
  }

  func testFuguArchitecturePolicyIsIdeaOnlyAndBlocksModelIntegration() throws {
    let policy = IntegrationPlanner.fuguArchitecturePolicy()
    let text =
      ([policy.plainSummary] + policy.adoptedIdeas + policy.rejectedIdeas + policy.guardrails
      + policy.verificationSignals).joined(separator: "\n")

    XCTAssertEqual(policy.schema, "TatwoFuguArchitecturePolicyV1")
    XCTAssertFalse(policy.integratesFuguModel)
    XCTAssertTrue(text.contains("不接入 Fugu 模型"))
    XCTAssertTrue(text.contains("一個入口") || text.contains("多模型"))
    XCTAssertTrue(text.contains("任務越難") || text.contains("簡單任務"))
    XCTAssertTrue(text.contains("分派") && text.contains("驗證") && text.contains("合併"))
    XCTAssertTrue(text.contains("可回朔") || text.contains("收據"))
    XCTAssertTrue(text.contains("黑盒") || text.contains("單 API"))
    XCTAssertTrue(text.contains("無上限") || text.contains("遞迴"))
    XCTAssertTrue(text.contains("按量 API") || text.contains("fan-out"))
    XCTAssertTrue(text.contains("沙盒"))
    XCTAssertTrue(text.contains("Codex executor"))
  }

  func testIntegrationPlanCarriesFuguPolicyAsGuardrailNotDependency() throws {
    let plan = IntegrationPlanner.makePlan()
    let policy = IntegrationPlanner.fuguArchitecturePolicy()
    let planText =
      (plan.stages.flatMap(\.checks) + plan.stages.flatMap(\.deniedActions) + plan.rollbackSteps)
      .joined(separator: "\n")
    let policyText = ([policy.plainSummary] + policy.guardrails + policy.rejectedIdeas).joined(
      separator: "\n")

    XCTAssertFalse(policy.integratesFuguModel)
    XCTAssertFalse(planText.lowercased().contains("install fugu"))
    XCTAssertTrue(policyText.contains("不接入 Fugu 模型"))
    XCTAssertTrue(policy.guardrails.contains { $0.contains("沙盒") && $0.contains("實裝") })
    XCTAssertTrue(policy.guardrails.contains { $0.contains("Codex executor") && $0.contains("工具") })
  }

}
