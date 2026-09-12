import XCTest

@testable import TatwoUltraworkCore

final class WorkOSEnforcementTests: XCTestCase {
  private func withTempAppSupport(_ body: () throws -> Void) rethrows {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-os-enforcement-\(UUID().uuidString)", isDirectory: true)
    setenv("TATWO_ULTRAWORK_APP_SUPPORT", tmp.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_APP_SUPPORT")
      try? FileManager.default.removeItem(at: tmp)
    }
    try body()
  }

  func testMissingContractFailsClosed() throws {
    let decision = WorkOSEnforcementFactory.enforce(
      WorkOSAgentActionIntent(
        contractID: nil,
        identity: .sub,
        toolName: "tatwo.os.next",
        requestedMutation: .readOnly,
        sourceSurface: .mcp),
      contract: nil)

    XCTAssertFalse(decision.ok)
    XCTAssertEqual(decision.code, "missing_contract_id")
    XCTAssertFalse(decision.canMutateHost)
    XCTAssertFalse(decision.canPromoteRunState)
  }

  func testVisualizerCannotPromoteGoal() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "visual gate")

    let decision = WorkOSEnforcementFactory.enforce(
      WorkOSAgentActionIntent(
        contractID: contract.contractID,
        identity: .verifier,
        toolName: "tatwo.os.goal.close",
        requestedMutation: .promoteRunState,
        sourceSurface: .appVisualizer),
      contract: contract)

    XCTAssertFalse(decision.ok)
    XCTAssertEqual(decision.code, "visualizer_cannot_promote")
    XCTAssertFalse(decision.canPromoteRunState)
  }

  func testUnregisteredToolFailsClosed() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "tool gate")

    let decision = WorkOSEnforcementFactory.enforce(
      WorkOSAgentActionIntent(
        contractID: contract.contractID,
        identity: .sub,
        toolName: "unknown.write.host",
        requestedMutation: .readOnly,
        sourceSurface: .agent),
      contract: contract)

    XCTAssertFalse(decision.ok)
    XCTAssertEqual(decision.code, "unregistered_or_disallowed_tool")
    XCTAssertTrue(decision.warnings.contains { $0.contains("registry") })
  }

  func testAllowedReadOnlyActionPassesButCannotMutateHost() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "allowed next")

    let decision = WorkOSEnforcementFactory.enforce(
      WorkOSAgentActionIntent(
        contractID: contract.contractID,
        identity: .lead,
        toolName: "tatwo.os.next",
        requestedMutation: .readOnly,
        sourceSurface: .cli),
      contract: contract)

    XCTAssertTrue(decision.ok, decision.message)
    XCTAssertEqual(decision.code, "os_action_allowed")
    XCTAssertFalse(decision.canMutateHost)
    XCTAssertTrue(decision.allowedNextTools.contains("tatwo.os.next"))
  }

  func testLContractAllowsSupervisedAgentAndComputerUseControlPlane() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "chat slider ui debug")

    for toolName in [
      "multi_agent_v1.send_input",
      "multi_agent_v1.wait_agent",
      "multi_agent_v1.resume_agent",
      "multi_agent_v1.close_agent",
      "computer-use",
      "tatwo.gateway.dispatch",
      "tatwo.gateway.fanout",
    ] {
      let decision = WorkOSEnforcementFactory.enforce(
        WorkOSAgentActionIntent(
          contractID: contract.contractID,
          identity: .supervisor,
          toolName: toolName,
          requestedMutation: .readOnly,
          sourceSurface: .agent),
        contract: contract)

      XCTAssertTrue(decision.ok, "\(toolName): \(decision.message)")
      XCTAssertFalse(decision.canMutateHost)
    }
  }

  func testSContractDoesNotAllowAgentFanOutControlPlane() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "single model direct check")

    let decision = WorkOSEnforcementFactory.enforce(
      WorkOSAgentActionIntent(
        contractID: contract.contractID,
        identity: .lead,
        toolName: "multi_agent_v1.send_input",
        requestedMutation: .readOnly,
        sourceSurface: .agent),
      contract: contract)

    XCTAssertFalse(decision.ok)
    XCTAssertEqual(decision.code, "unregistered_or_disallowed_tool")
  }

  func testHandoffPackContainsAgentsToolsReceiptsAndDashboard() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "handoff")

    let pack = WorkOSEnforcementFactory.handoffPack(contract: contract)

    XCTAssertEqual(pack.schema, "TatwoWorkOSHandoffPackV1")
    XCTAssertEqual(pack.contractID, contract.contractID)
    XCTAssertEqual(pack.dashboard.schema, "TatwoWorkOSDashboardSnapshotV1")
    XCTAssertTrue(pack.agentsMD.contains("AGENTS.md"))
    XCTAssertTrue(pack.toolsMD.contains("TOOLS.md"))
    XCTAssertTrue(pack.receiptsMD.contains("RECEIPTS.md"))
    XCTAssertTrue(pack.allowedNextTools.contains("tatwo.os.next"))
    XCTAssertTrue(pack.forbiddenActions.contains { $0.contains("contractID") })
  }

  func testUIUXContractRequiresIdentityBasedCodexAppParityReceipt() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "ui-ux",
      objective: "chat parity gate")
    let requiredIDs = Set(contract.receiptRequirements.filter(\.requiredForPass).map(\.id))

    XCTAssertTrue(requiredIDs.contains("codex-app-parity"))
    XCTAssertTrue(
      contract.receiptRequirements.contains {
        $0.id == "codex-app-parity"
          && $0.plainPurpose.contains("獨立 reviewer")
          && !$0.plainPurpose.contains("Sonnet 5")
      })
  }

  func testMCPExposesDashboardEnforceHandoffAndConstitution() throws {
    try withTempAppSupport {
      let dashboard = TatwoMCPRegistry.call(
        tool: "tatwo.os.dashboard",
        arguments: [
          "mode": .string("XL"),
          "scenario": .string("ui-ux"),
          "objective": .string("mcp dashboard"),
        ])
      XCTAssertTrue(dashboard.ok, dashboard.error ?? "")
      guard case .object(let dashboardPayload) = dashboard.payload else {
        return XCTFail("expected dashboard payload")
      }
      XCTAssertEqual(dashboardPayload["schema"]?.stringValue, "TatwoWorkOSDashboardSnapshotV1")

      let begin = TatwoMCPRegistry.call(
        tool: "tatwo.os.begin",
        arguments: try WorkOSMCPBeginTestSupport.arguments(
          mode: "XL", scenario: "ui-ux", objective: "mcp enforce"))
      XCTAssertTrue(begin.ok, begin.error ?? "")
      guard case .object(let beginPayload) = begin.payload,
        let contractID = beginPayload["contractID"]?.stringValue
      else {
        return XCTFail("expected begin payload with contractID")
      }
      let enforce = TatwoMCPRegistry.call(
        tool: "tatwo_os_enforce",
        arguments: [
          "mode": .string("XL"),
          "scenario": .string("ui-ux"),
          "contractID": .string(contractID),
          "toolName": .string("tatwo.os.next"),
        ])
      XCTAssertTrue(enforce.ok, enforce.error ?? "")

      let handoff = TatwoMCPRegistry.call(
        tool: "tatwo.os.handoff",
        arguments: [
          "mode": .string("XL"),
          "scenario": .string("ui-ux"),
          "contractID": .string(contractID),
        ])
      XCTAssertTrue(handoff.ok, handoff.error ?? "")

      let constitution = TatwoMCPRegistry.call(tool: "tatwo.os.constitution")
      XCTAssertTrue(constitution.ok, constitution.error ?? "")
    }
  }
}
