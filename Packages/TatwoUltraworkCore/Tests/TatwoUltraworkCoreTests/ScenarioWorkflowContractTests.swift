import XCTest

@testable import TatwoUltraworkCore

final class ScenarioWorkflowContractTests: XCTestCase {
  func testScenarioWorkflowToolIsExposedAndAliasWorks() throws {
    let names = Set(TatwoMCPRegistry.tools.map(\.name))
    XCTAssertTrue(names.contains("tatwo.scenario.workflow"))
    let workflowTool = try XCTUnwrap(
      TatwoMCPRegistry.tools.first { $0.name == "tatwo.scenario.workflow" })
    XCTAssertFalse(workflowTool.hostMutationAllowed)

    let result = TatwoMCPRegistry.call(
      tool: "tatwo_scenario_workflow",
      arguments: [
        "mode": .string("L"),
        "scenario": .string("ui-ux"),
        "objective": .string("dropdown scenario workflow smoke"),
      ])
    XCTAssertTrue(result.ok, result.error ?? "")
    XCTAssertFalse(result.hostMutationAllowed)
    let text = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("TatwoScenarioWorkflowContractV1"))
    XCTAssertTrue(text.contains("TatwoWorkOSContractV1"))
    XCTAssertTrue(text.contains("identity-setup"))
    XCTAssertTrue(text.contains("不可說外部模型已參與"))
  }

  func testUIUXContractUsesIdentitySlotsAndVisualFailClosedReceipts() throws {
    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .l,
      scenarioProfileID: "ui-ux",
      objective: "make scenarios page dropdown first")

    XCTAssertEqual(contract.schema, "TatwoScenarioWorkflowContractV1")
    XCTAssertEqual(contract.scenarioProfileID, "ui-ux")
    XCTAssertEqual(contract.baseScenario, .design)
    XCTAssertFalse(contract.hostMutationAllowed)
    XCTAssertEqual(contract.modePlan.helperLimit, 16)
    XCTAssertTrue(contract.scenarioProfile.identitySlots.contains { $0.label == "主視覺" })
    XCTAssertTrue(contract.scenarioProfile.identitySlots.contains { $0.label == "交互驗收" })
    XCTAssertTrue(contract.loopNodes.contains { $0.id == "identity-setup" })
    XCTAssertTrue(contract.loopNodes.contains { $0.id == "work-os-contract" })
    XCTAssertTrue(contract.loopNodes.contains { $0.id == "project-map" && $0.required })
    XCTAssertTrue(contract.loopNodes.contains { $0.id == "sandbox" && $0.required })
    XCTAssertTrue(contract.receiptRequirements.contains("screenshot or recording"))
    XCTAssertTrue(contract.failClosedRule.contains("UI/UJ"))
    XCTAssertTrue(contract.forbiddenClaims.contains { $0.contains("build pass") || $0.contains("UI") })
  }

  func testSModeContractDoesNotRequireSubFanout() throws {
    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .s,
      scenarioProfileID: "daily",
      objective: "small direct answer")

    XCTAssertEqual(contract.mode, .s)
    XCTAssertEqual(contract.modePlan.helperLimit, 0)
    XCTAssertFalse(contract.modePlan.identitySlots.contains { $0.kind == .sub })
    XCTAssertTrue(contract.loopNodes.contains { $0.id == "project-map" && !$0.required })
    XCTAssertTrue(contract.loopNodes.contains { $0.id == "scout-sub-news" && !$0.required })
    XCTAssertTrue(contract.receiptRequirements.contains("S mode no-sub note"))
  }

  func testScenarioWorkflowModePlanUsesExactCustomPreviewBindings() throws {
    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
    var book = duplicated.book
    let scenarioIndex = try XCTUnwrap(
      book.scenarios.firstIndex { $0.id == duplicated.scenarioID })
    var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
    config.bindings = [
      TatwoScenarioIdentityBinding(
        id: "workflow-preview-lead",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.6-sol"],
        responsibility: "Exact custom workflow lead",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "workflow-preview-supervisor",
        phase: .loops,
        identity: "副審",
        boundModelIDs: ["opus-5"],
        responsibility: "Exact custom workflow supervisor",
        dynamicActivation: .always),
    ]
    book.scenarios[scenarioIndex].modeConfigs[.xxl] = config

    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .xxl,
      scenarioProfileID: duplicated.scenarioID,
      objective: "Scenario factory must remain a pure exact preview",
      scenarioBook: book)

    XCTAssertEqual(
      contract.modePlan.identitySlots.map(\.id),
      contract.workOSContract.identityBindings.map(\.sourceSlotID))
    XCTAssertEqual(
      contract.modePlan.identitySlots.map { $0.primaryCandidate?.modelID },
      contract.workOSContract.identityBindings.map(\.modelID))
    XCTAssertEqual(contract.identitySlots, contract.modePlan.identitySlots)
    XCTAssertEqual(
      contract.workOSContract.identityBindings.map(\.modelID),
      ["gpt-5.6-sol", "opus-5"])
  }

  // M4b 更新：workflow 仍保留完整 close gates；執行收據橋只能提供
  // dispatch/goal/sandbox/rollback 證據，不能從 workflow 合約移除人門與 PLG seal。
  func testM4bNativeDevelopmentWorkflowKeepsNonExecutionCloseGates() throws {
    let workflow = try ScenarioWorkflowContractFactory.make(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID,
      objective: "M4b workflow close-gate preservation")
    let required = Set(
      workflow.workOSContract.receiptRequirements
        .filter(\.requiredForPass)
        .map(\.id))

    XCTAssertTrue(
      Set(["dispatch-liveness", "goal-tracker", "sandbox", "rollback"])
        .isSubset(of: required))
    XCTAssertTrue(
      Set([
        "contract-id",
        "mode-budget",
        "identity-bindings",
        "plan-loop-goal-mainline",
        "plan-loop-goal-branch",
        "goal-cycle-seal",
        "scope-review",
        "human-gate",
      ]).isSubset(of: required))
  }

  func testContractForbidsFakeExecutionAndHostMutation() throws {
    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .xl,
      scenarioProfileID: "coding",
      objective: "agent must ask workflow before work")

    XCTAssertFalse(contract.hostMutationAllowed)
    XCTAssertTrue(contract.forbiddenClaims.contains { $0.contains("bridge/tool/CLI receipt") })
    XCTAssertTrue(contract.forbiddenClaims.contains { $0.contains("自評") })
    XCTAssertTrue(contract.forbiddenActions.contains { $0.contains("signed Codex App") })
    XCTAssertTrue(contract.forbiddenActions.contains { $0.contains("token") })
    XCTAssertTrue(contract.requiredTools.contains("tatwo.scenario.workflow"))
    XCTAssertTrue(contract.requiredTools.contains("tatwo.os.begin"))
    XCTAssertTrue(contract.recommendedPlugins.contains("gitnexus"))
    XCTAssertTrue(contract.recommendedPlugins.contains("colima-sandbox-runner"))
  }

  func testShowLoopsProjectionIsReadOnlyReceiptMappedAndReplacementReady() throws {
    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .l,
      scenarioProfileID: "ui-ux",
      objective: "dropdown loop projection must be receipt mapped")

    XCTAssertEqual(contract.showLoopsProjection.schema, "TatwoShowLoopsProjectionV1")
    XCTAssertEqual(
      contract.showLoopsProjection.visualizerSourceOfTruth,
      "workflow_contract_planning_preview; runtime_event_log_required_for_progress")
    XCTAssertFalse(contract.showLoopsProjection.visualizerCanMutateRunState)
    XCTAssertTrue(contract.showLoopsProjection.promotionRequiresReceipts)
    XCTAssertEqual(contract.showLoopsProjection.presentationLabel, "規劃預覽")
    XCTAssertEqual(contract.showLoopsProjection.dispatchSummary, "尚未派發")
    XCTAssertEqual(contract.showLoopsProjection.runtimeReceiptSummary, "無 runtime receipt")
    XCTAssertEqual(contract.showLoopsProjection.runtimeProgressEventCount, 0)
    XCTAssertEqual(contract.showLoopsProjection.runtimeReceiptCount, 0)
    XCTAssertTrue(contract.showLoopsProjection.missingEventNodePolicy.contains("規劃預覽"))
    XCTAssertTrue(contract.visualizationHints.style.contains("show-loops"))
    XCTAssertTrue(contract.visualizationHints.replacementReady)
    XCTAssertEqual(contract.showLoopsProjection.events.count, contract.loopNodes.count)
    XCTAssertEqual(contract.showLoopsProjection.edges, contract.loopEdges)

    let loopNodeIDs = Set(contract.loopNodes.map(\.id))
    for event in contract.showLoopsProjection.events {
      XCTAssertTrue(loopNodeIDs.contains(event.phaseID), "event \(event.id) must map back to a loop node")
      XCTAssertFalse(event.runEventID.isEmpty)
      XCTAssertFalse(event.contractCallID.isEmpty)
      XCTAssertEqual(event.contractCallID, contract.showLoopsProjection.contractCallID)
      XCTAssertFalse(event.modelBindingID.isEmpty)
      XCTAssertFalse(event.inputHash.isEmpty)
      XCTAssertTrue(event.readOnlyProjection)
      XCTAssertFalse(event.canPromoteRunState)
      XCTAssertEqual(event.status, .notDispatched)
      XCTAssertEqual(event.plainStatus, "尚未派發")
      XCTAssertFalse(event.countsAsRuntimeProgress)
      XCTAssertFalse(event.hasRuntimeReceipt)
      if event.required {
        XCTAssertFalse(event.receiptRefs.isEmpty, "required event \(event.phaseID) must expose receipt refs")
      }
    }
  }

  func testPassedProjectionWithoutRuntimeReceiptIsFailClosedToReceiptGate() throws {
    let event = ScenarioRunEventProjection(
      id: "event-verifier",
      runEventID: "run-event-verifier",
      seq: 1,
      phaseID: "verifier",
      title: "Verifier",
      identityID: "verifier",
      identityLabel: "驗收",
      contractCallID: "contract-call",
      modelBindingID: "binding-verifier",
      required: true,
      receiptRefs: ["receipt-required-tests"],
      inputHash: "abc",
      outputHash: "def",
      status: .passed)

    XCTAssertEqual(event.status, .receiptGated)
    XCTAssertEqual(event.runtimeReceiptRefs, [])
    XCTAssertTrue(event.plainStatus.contains("無 runtime receipt"))
    XCTAssertFalse(event.hasRuntimeReceipt)
  }

  func testProjectionDecodesLegacyPayloadWithoutNewTruthFields() throws {
    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "legacy projection decode")
    let data = try JSONEncoder().encode(contract.showLoopsProjection)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "presentationLabel")
    object.removeValue(forKey: "dispatchSummary")
    object.removeValue(forKey: "runtimeReceiptSummary")
    if var events = object["events"] as? [[String: Any]] {
      for index in events.indices {
        events[index].removeValue(forKey: "runtimeReceiptRefs")
      }
      object["events"] = events
    }

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(
      ScenarioShowLoopsProjection.self,
      from: legacyData)

    XCTAssertEqual(decoded.presentationLabel, "規劃預覽")
    XCTAssertEqual(decoded.dispatchSummary, "尚未派發")
    XCTAssertEqual(decoded.runtimeReceiptSummary, "無 runtime receipt")
    XCTAssertTrue(decoded.events.allSatisfy { $0.runtimeReceiptRefs.isEmpty })
  }

  func testAgentInvocationPolicyRequiresContractFirstAndBlocksNakedToolCalls() throws {
    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .xl,
      scenarioProfileID: "coding",
      objective: "agents must not act before contract")
    let policy = contract.agentInvocationPolicy

    XCTAssertEqual(policy.schema, "TatwoAgentInvocationPolicyV1")
    XCTAssertTrue(policy.mustCallWorkflowToolBeforeActing)
    XCTAssertEqual(policy.requiredFirstTool, "tatwo.os.begin")
    XCTAssertTrue(policy.noReceiptNoClaim)
    XCTAssertTrue(policy.externalModelReceiptRequired)
    XCTAssertFalse(policy.hostMutationDefaultAllowed)
    XCTAssertTrue(policy.requiresContractCallIDForEveryAction)
    XCTAssertTrue(policy.rejectsNakedToolCall)
    XCTAssertFalse(policy.visualizerCanPromoteRunState)
    XCTAssertTrue(policy.sameModelMultiRoleMarkedSimulated)
    XCTAssertTrue(policy.fakeExecutionBlockedMessage.contains("Work OS contractID"))
    XCTAssertTrue(policy.requiredBeforeAnyPatch.contains("Work OS contractID"))
  }

  func testMCPScenarioWorkflowPayloadContainsShowLoopsProjection() throws {
    let result = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.workflow",
      arguments: [
        "mode": .string("M"),
        "scenario": .string("debug"),
        "objective": .string("projection mcp payload smoke"),
      ])
    XCTAssertTrue(result.ok, result.error ?? "")

    guard case .object(let payload) = result.payload,
      case .object(let projection)? = payload["showLoopsProjection"],
      case .string("TatwoShowLoopsProjectionV1")? = projection["schema"],
      case .bool(false)? = projection["visualizerCanMutateRunState"],
      case .bool(true)? = projection["promotionRequiresReceipts"],
      case .string("規劃預覽")? = projection["presentationLabel"],
      case .string("尚未派發")? = projection["dispatchSummary"],
      case .string("無 runtime receipt")? = projection["runtimeReceiptSummary"],
      case .array(let events)? = projection["events"],
      case .object(let firstEvent)? = events.first
    else {
      return XCTFail("expected showLoopsProjection in MCP scenario workflow payload")
    }

    XCTAssertFalse(events.isEmpty)
    XCTAssertNotEqual(firstEvent["runEventID"], .string(""))
    XCTAssertNotEqual(firstEvent["contractCallID"], .string(""))
    XCTAssertNotEqual(firstEvent["modelBindingID"], .string(""))
    XCTAssertNotEqual(firstEvent["inputHash"], .string(""))
    XCTAssertEqual(firstEvent["readOnlyProjection"], .bool(true))
    XCTAssertEqual(firstEvent["canPromoteRunState"], .bool(false))
    XCTAssertEqual(firstEvent["status"], .string("not_dispatched"))
    XCTAssertEqual(firstEvent["runtimeReceiptRefs"], .array([]))

    let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? ""
    XCTAssertTrue(encoded.contains("TatwoShowLoopsProjectionV1"))
    XCTAssertTrue(encoded.contains("visualizerCanMutateRunState"))
    XCTAssertTrue(encoded.contains("contractCallID"))
  }

  func testMCPScenarioWorkflowKeepsNumericHelperCapsAsNumbers() throws {
    let result = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.workflow",
      arguments: [
        "mode": .string("M"),
        "scenario": .string("debug"),
        "objective": .string("helper cap numeric regression"),
      ])
    XCTAssertTrue(result.ok, result.error ?? "")

    guard case .object(let payload) = result.payload,
      case .array(let slots)? = payload["identitySlots"],
      let lead = slots.compactMap({ value -> [String: JSONValue]? in
        guard case .object(let object) = value else { return nil }
        return object["id"] == .string("lead") ? object : nil
      }).first,
      let helperCap = lead["helperCap"]
    else {
      return XCTFail("expected lead identity slot in MCP payload")
    }

    XCTAssertEqual(helperCap, .number(1), "helperCap must stay numeric in MCP JSONValue, not true/false")

    let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("\"helperCap\":true"), "encoded MCP JSON must not expose helperCap as true")
  }

}
