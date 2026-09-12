import XCTest

@testable import TatwoUltraworkCore

final class WorkOSTests: XCTestCase {
  func testSModeCreatesMainlineOnlyAndNoDomainFanout() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .s,
      scenarioProfileID: "daily",
      objective: "small fix")

    XCTAssertEqual(contract.schema, "TatwoWorkOSContractV1")
    XCTAssertEqual(contract.mode, .s)
    XCTAssertEqual(contract.goalRun.status, .planned)
    XCTAssertTrue(contract.domainLoops.isEmpty)
    XCTAssertFalse(contract.mainlineLoop.reviewerGateRequired)
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "s-no-sub" })
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "cleanup-inventory" })
    XCTAssertTrue(contract.sandboxPolicy.stagingConfigRequired)
    XCTAssertFalse(contract.sandboxPolicy.hostMutationAllowed)
  }

  func testMModeCreatesReviewerGateWithDefaultThreeDomainLoops() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "debug",
      objective: "reviewer gate smoke")

    XCTAssertEqual(contract.mode, .m)
    // T1 模式重校: M 預設 3 個 domain loops（不再 mainline only），全部 cycle 1。
    XCTAssertEqual(contract.domainLoops.count, 3)
    XCTAssertTrue(contract.domainLoops.allSatisfy { $0.cycleIndex == 1 })
    XCTAssertEqual(
      Set(contract.domainLoops.map(\.domain)),
      Set(WorkOSFactory.scenarioDomains(for: TatwoIdentityCatalog.scenarioProfiles.first { $0.id == "debug" }!)))
    XCTAssertTrue(contract.mainlineLoop.reviewerGateRequired)
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "reviewer-gate" })
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "scope-review" })
    XCTAssertTrue(contract.mainlineLoop.phases.contains("通過前必須副審"))
  }

  func testCodingContractDefaultsToSolLeadAndKeepsChatGPTProMCPAdvisoryOnly() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "Issue the next coding contract with project-bound advisory research")

    let leads = contract.identityBindings.filter { $0.identity == .lead }
    XCTAssertEqual(leads.map(\.sourceSlotID), ["coding-lead"])
    XCTAssertEqual(leads.map(\.engineID), [.modelGateway])
    XCTAssertEqual(leads.map(\.modelID), ["gpt-5.6-sol"])

    let proBindings = contract.identityBindings.filter { $0.engineID == .chatgptProMCP }
    XCTAssertEqual(proBindings.map(\.identity), [.consultant])
    XCTAssertEqual(proBindings.map(\.sourceSlotID), ["coding-consultant"])
    XCTAssertEqual(proBindings.map(\.modelID), ["pro-research"])
    XCTAssertTrue(proBindings.allSatisfy { $0.authority == .researchBridge })
    XCTAssertTrue(proBindings.allSatisfy { !$0.canMutateHost })

    let executionBindings = contract.identityBindings.filter {
      $0.identity == .lead || $0.identity == .sub
    }
    XCTAssertFalse(executionBindings.contains { $0.engineID == .chatgptProMCP })
    XCTAssertFalse(
      contract.identityBindings.contains { $0.modelID == EngineID.chatgptProMCP.rawValue })
  }

  func testLModeCreatesEightLoopsViaCycleExpansionAndRollbackReceipt() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .l,
      scenarioProfileID: "ui-ux",
      objective: "single ui loop")

    XCTAssertEqual(contract.mode, .l)
    // T1 模式重校: L 預設 8 個 loops — 3 個 domain 模板 + cycle 實例補足。
    XCTAssertEqual(contract.domainLoops.count, 8)
    XCTAssertEqual(contract.domainLoops.filter { $0.cycleIndex == 1 }.count, 3)
    // Cycle >1 實例不掛必過收據（同域回報 cycle 1），goal-close 收據數不爆炸。
    XCTAssertTrue(
      contract.domainLoops.filter { $0.cycleIndex > 1 }.allSatisfy(\.requiredReceipts.isEmpty))
    XCTAssertEqual(contract.domainLoops.first?.domain, .ui)
    XCTAssertTrue(contract.sandboxPolicy.required)
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "rollback" })
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "domain-ui-loop" })
    XCTAssertTrue(
      contract.receiptRequirements.contains { $0.id == "web-check-full-scan" && $0.requiredForPass }
    )
    XCTAssertTrue(
      contract.receiptRequirements.contains { $0.id == "product-design-audit" && $0.requiredForPass }
    )
    XCTAssertTrue(
      contract.domainLoops.first?.requiredReceipts.contains { $0.id == "web-check-full-scan" }
        == true)
    XCTAssertTrue(
      contract.domainLoops.first?.requiredReceipts.contains { $0.id == "product-design-audit" }
        == true)
  }

  func testFable5LeadGPT55LoopsIntentOverridesDebugIdentityBindings() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .l,
      scenarioProfileID: "debug",
      objective: "Fable5 returns as WorkOS lead while GPT5.5 handles loops, and repair Fable5 disconnect stability")

    let lead = try XCTUnwrap(contract.identityBindings.first { $0.identity == .lead })
    XCTAssertEqual(lead.engineID, .claudeCLI)
    XCTAssertEqual(lead.modelID, "fable-5")
    XCTAssertEqual(lead.authority, .toolIntentBridge)
    XCTAssertFalse(lead.canMutateHost)
    XCTAssertTrue(lead.bindingRule.contains("live smoke"))
    XCTAssertTrue(lead.bindingRule.contains("健康"))
    XCTAssertTrue(lead.bindingRule.contains("retry-loop"))

    let loops = try XCTUnwrap(contract.identityBindings.first { $0.identity == .sub })
    XCTAssertEqual(loops.engineID, .codex)
    XCTAssertEqual(loops.modelID, "gpt-5.5")
    XCTAssertFalse(loops.canMutateHost)
    XCTAssertTrue(loops.bindingRule.contains("GPT5.5"))

    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "fable5-route-health" })
    XCTAssertTrue(contract.mainlineLoop.nextStep.contains("fable5-route-health"))
    XCTAssertTrue(contract.stopRules.contains { $0.contains("自動重試") })
    XCTAssertTrue(contract.failClosedRules.contains { $0.contains("舊錯誤狀態硬降權") || $0.contains("quota") || $0.contains("session-limit") })
  }

  func testExactXXLScenarioProjectsSolLeadFableReviewerAndTwoXHighSubs() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
      objective:
        "Sol is sole lead; Fable5 reviews; Luna xhigh and Grok4.6 xhigh execute loops")

    let governor = contract.loopGovernorDecision.activatedBindings
    XCTAssertEqual(
      governor.filter { $0.identityKind == .lead }.map(\.boundModelIDs),
      [["gpt-5.6-sol"]])
    XCTAssertEqual(
      governor.filter { $0.identityKind == .supervisor }.map(\.boundModelIDs),
      [["fable-5"]])
    XCTAssertEqual(
      governor.filter { $0.identityKind == .sub }.map(\.boundModelIDs),
      [["gpt-5.6-luna"], ["grok-build"]])
    XCTAssertEqual(
      governor.filter { $0.identityKind == .sub }.map(\.reasoningEffort),
      [.xhigh, .xhigh])

    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .lead }.map(\.modelID),
      ["gpt-5.6-sol"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .supervisor }.map(\.modelID),
      ["fable-5"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .sub }.map(\.modelID),
      ["gpt-5.6-luna", "grok-build"])
    XCTAssertFalse(
      contract.identityBindings.contains {
        $0.identity == .lead && $0.modelID == "fable-5"
      })
    XCTAssertFalse(contract.identityBindings.contains { $0.modelID == "gpt-5.5" })
  }

  func testExactXXLMultiLaneFanOutPreservesPrimaryLoopIdentityAndPinsEveryLane() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
      objective: "Multi-lane loop identity remains stable")
    let subSlotIDs = contract.identityBindings
      .filter { $0.identity == .sub }
      .map(\.sourceSlotID)
      .sorted()
    XCTAssertEqual(subSlotIDs.count, 2)

    let cycleOneByDomain = Dictionary(
      grouping: contract.domainLoops.filter {
        $0.cycleIndex == 1 && $0.ownerIdentity == .sub
      },
      by: \.domain)
    XCTAssertFalse(cycleOneByDomain.isEmpty)
    for (domain, lanes) in cycleOneByDomain {
      XCTAssertEqual(lanes.count, 2, domain.rawValue)
      XCTAssertEqual(Set(lanes.compactMap(\.ownerSourceSlotID)), Set(subSlotIDs), domain.rawValue)
      let primary = lanes.filter { !$0.id.contains("-lane-") }
      let secondary = lanes.filter { $0.id.contains("-lane-") }
      XCTAssertEqual(primary.count, 1, domain.rawValue)
      XCTAssertEqual(secondary.count, 1, domain.rawValue)
      XCTAssertEqual(primary.first?.ownerSourceSlotID, subSlotIDs.first, domain.rawValue)
      XCTAssertFalse(primary.first?.title.contains(" · lane ") == true, domain.rawValue)
      XCTAssertTrue(secondary.first?.title.contains(" · lane ") == true, domain.rawValue)
    }
  }

  func testExactXXLScenarioWithBothLegacyTokensKeepsGovernorAndIdentityBindingsUnified() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
      objective:
        "Legacy history explicitly mentions Fable5 and GPT5.5, but this exact topology keeps Sol lead, Fable supervisor, and Luna/Grok xhigh subs")

    let governor = contract.loopGovernorDecision.activatedBindings.filter {
      $0.enabled && $0.dynamicActivation != .disabled
    }
    XCTAssertEqual(governor.filter { $0.identityKind == .lead }.count, 1)
    XCTAssertEqual(governor.filter { $0.identityKind == .supervisor }.count, 1)
    XCTAssertEqual(governor.filter { $0.identityKind == .sub }.count, 2)
    XCTAssertEqual(
      governor
        .filter { $0.identityKind == .lead }
        .flatMap(\.boundModelIDs),
      ["gpt-5.6-sol"])
    XCTAssertEqual(
      governor
        .filter { $0.identityKind == .supervisor }
        .flatMap(\.boundModelIDs),
      ["fable-5"])
    XCTAssertEqual(
      governor
        .filter { $0.identityKind == .sub }
        .flatMap(\.boundModelIDs),
      ["gpt-5.6-luna", "grok-build"])
    XCTAssertEqual(
      governor
        .filter { $0.identityKind == .sub }
        .map(\.reasoningEffort),
      [.xhigh, .xhigh])

    XCTAssertEqual(contract.identityBindings.count, governor.count)
    for governorBinding in governor {
      let expectedIdentity = try XCTUnwrap(governorBinding.identityKind)
      XCTAssertEqual(
        contract.identityBindings
          .filter { $0.sourceSlotID == governorBinding.id }
          .map(\.identity),
        [expectedIdentity])
      XCTAssertEqual(
        contract.identityBindings
          .filter { $0.sourceSlotID == governorBinding.id }
          .map(\.modelID),
        governorBinding.boundModelIDs.map(Optional.some))
    }
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .lead }.map(\.modelID),
      ["gpt-5.6-sol"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .supervisor }.map(\.modelID),
      ["fable-5"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .sub }.map(\.modelID),
      ["gpt-5.6-luna", "grok-build"])
    XCTAssertEqual(
      Set(contract.identityBindings.map(\.sourceSlotID)).count,
      contract.identityBindings.count)
    XCTAssertFalse(
      contract.identityBindings.contains {
        $0.identity == .lead && $0.modelID == "fable-5"
      })
    XCTAssertFalse(contract.identityBindings.contains { $0.modelID == "gpt-5.5" })
    XCTAssertFalse(contract.receiptRequirements.contains { $0.id == "fable5-route-health" })
  }

  func testConfiguredCustomCopyTopologyOutranksLegacyObjectiveInferenceWithoutShapeAssumptions() throws {
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let store = TatwoGoalRunStore(directoryURL: storeRoot)
    defer { try? FileManager.default.removeItem(at: storeRoot) }

    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID)
    var book = duplicated.book
    let scenarioIndex = try XCTUnwrap(
      book.scenarios.firstIndex { $0.id == duplicated.scenarioID })
    var modeConfig = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
    modeConfig.bindings = [
      TatwoScenarioIdentityBinding(
        id: "custom-plan-lead-sol-primary",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.6-sol"],
        responsibility: "primary Sol lead",
        dynamicActivation: .always,
        reasoningEffort: .low),
      TatwoScenarioIdentityBinding(
        id: "custom-plan-lead-sol-continuity",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.6-sol"],
        responsibility: "Sol continuity lane",
        dynamicActivation: .always,
        reasoningEffort: .low),
      TatwoScenarioIdentityBinding(
        id: "custom-loops-supervisor-fable5",
        phase: .loops,
        identity: "副審",
        boundModelIDs: ["fable-5"],
        responsibility: "Fable reviewer",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "custom-loops-sub-combined",
        phase: .loops,
        identity: "sub",
        boundModelIDs: ["gpt-5.6-luna", "grok-build"],
        responsibility: "combined independent loop candidates",
        dynamicActivation: .allowed,
        reasoningEffort: .xhigh),
      TatwoScenarioIdentityBinding(
        id: "custom-goal-verifier-fable5",
        phase: .goal,
        identity: "驗收",
        boundModelIDs: ["fable-5"],
        responsibility: "Fable verifier",
        dynamicActivation: .always),
    ]
    book.scenarios[scenarioIndex].modeConfigs[.xxl] = modeConfig

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID: duplicated.scenarioID,
      objective:
        "Current contract uses Sol lead, Fable5 reviewer, Luna/Grok loops; stale history also mentioned Fable5 lead and GPT5.5 loops",
      scenarioBook: book,
      store: store)

    let configured = contract.loopGovernorDecision.activatedBindings
    XCTAssertEqual(configured, modeConfig.bindings)
    XCTAssertEqual(
      contract.identityBindings.count,
      configured.reduce(0) { $0 + max(1, $1.boundModelIDs.count) })
    for configuredBinding in configured {
      let expectedModels =
        configuredBinding.boundModelIDs.isEmpty
        ? [String?](arrayLiteral: nil)
        : configuredBinding.boundModelIDs.map(Optional.some)
      let issued = contract.identityBindings.filter {
        $0.sourceSlotID == configuredBinding.id
      }
      let expectedIdentity = try XCTUnwrap(configuredBinding.identityKind)
      XCTAssertEqual(
        issued.map(\.identity),
        Array(repeating: expectedIdentity, count: issued.count))
      XCTAssertEqual(issued.map(\.modelID), expectedModels)
    }
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .lead }.map(\.modelID),
      ["gpt-5.6-sol", "gpt-5.6-sol"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .supervisor }.map(\.modelID),
      ["fable-5"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .sub }.map(\.modelID),
      ["gpt-5.6-luna", "grok-build"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .verifier }.map(\.modelID),
      ["fable-5"])
    XCTAssertFalse(contract.identityBindings.contains { $0.modelID == "gpt-5.5" })
    XCTAssertFalse(contract.receiptRequirements.contains { $0.id == "fable5-route-health" })

    let issuedSnapshot = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
    XCTAssertEqual(issuedSnapshot.count, contract.identityBindings.count)
    XCTAssertEqual(
      Set(issuedSnapshot.map(\.sourceSlotID)),
      Set(contract.identityBindings.map(\.sourceSlotID)))
    let storedSnapshot = try store.snapshot(forContractID: contract.contractID)
    let persisted = try XCTUnwrap(storedSnapshot.record.issuedIdentityBindings)
    XCTAssertEqual(persisted, issuedSnapshot)
    XCTAssertEqual(
      storedSnapshot.record.issuedIdentityBindingsDigest,
      TatwoIssuedIdentityBindingV1.deterministicDigest(for: issuedSnapshot))
    let projected = try WorkOSFactory.storedContractProjection(
      snapshot: storedSnapshot,
      scenarioBook: book,
      store: store)
    XCTAssertEqual(projected.identityBindings, contract.identityBindings)
    XCTAssertEqual(projected.loopGovernorDecision, contract.loopGovernorDecision)

    let manifest = TatwoExecutionManifestFactory.make(
      contract: projected,
      generatedAt: Date(timeIntervalSince1970: 1_785_817_600))
    XCTAssertEqual(
      manifest.entries.map(\.sourceSlotID),
      projected.identityBindings.map(\.sourceSlotID))
    XCTAssertEqual(
      manifest.entries.map(\.modelID),
      projected.identityBindings.map(\.modelID))
    XCTAssertEqual(
      manifest.entries.map(\.identity),
      projected.identityBindings.map(\.identity))
    XCTAssertFalse(manifest.entries.contains { $0.modelID == "gpt-5.5" })

    let routeTuples: ([String], [String], [String]) = (
      projected.identityBindings.map {
        "\($0.sourceSlotID)|\($0.identity.rawValue)|\($0.modelID ?? "<nil>")"
      }.sorted(),
      persisted.map {
        "\($0.sourceSlotID)|\($0.identity.rawValue)|\($0.modelID ?? "<nil>")"
      }.sorted(),
      manifest.entries.map {
        "\($0.sourceSlotID)|\($0.identity.rawValue)|\($0.modelID ?? "<nil>")"
      }.sorted())
    XCTAssertEqual(routeTuples.0, routeTuples.1)
    XCTAssertEqual(routeTuples.0, routeTuples.2)
  }

  func testPreviewModePlanProjectsCustomCopyIdentityBindingsExactly() throws {
    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID)
    var book = duplicated.book
    let scenarioIndex = try XCTUnwrap(
      book.scenarios.firstIndex { $0.id == duplicated.scenarioID })
    var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
    config.bindings = [
      TatwoScenarioIdentityBinding(
        id: "preview-custom-lead",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["opus-5"],
        responsibility: "Custom-copy preview lead",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "preview-custom-sub",
        phase: .loops,
        identity: "sub",
        boundModelIDs: ["gpt-5.6-luna", "grok-build"],
        responsibility: "Custom-copy exact parallel loops",
        dynamicActivation: .allowed,
        reasoningEffort: .xhigh),
    ]
    book.scenarios[scenarioIndex].modeConfigs[.xxl] = config

    let contract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID: duplicated.scenarioID,
      objective: "Preview custom-copy exact topology",
      scenarioBook: book)
    let modePlan = try WorkOSFactory.previewModePlan(
      mode: .xxl,
      scenarioProfileID: duplicated.scenarioID,
      scenarioBook: book,
      contract: contract)

    XCTAssertEqual(
      contract.identityBindings.map(\.sourceSlotID),
      ["preview-custom-lead", "preview-custom-sub", "preview-custom-sub"])
    XCTAssertEqual(
      modePlan.identitySlots.map(\.id),
      contract.identityBindings.map(\.sourceSlotID))
    XCTAssertEqual(
      modePlan.identitySlots.map(\.kind),
      contract.identityBindings.map(\.identity))
    XCTAssertEqual(
      modePlan.identitySlots.map { $0.primaryCandidate?.modelID },
      contract.identityBindings.map(\.modelID))
    XCTAssertEqual(
      modePlan.identitySlots.map { $0.primaryCandidate?.engineID },
      contract.identityBindings.map(\.engineID))
  }

  func testPreviewModePlanProjectsIssuedCustomContractAfterScenarioBookDrift() throws {
    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
    let contract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID: duplicated.scenarioID,
      objective: "Issued custom contract remains the preview authority",
      scenarioBook: duplicated.book)

    let modePlan = try WorkOSFactory.previewModePlan(
      mode: .s,
      scenarioBook: TatwoScenarioConfigDefaults.book,
      contract: contract)

    XCTAssertEqual(modePlan.mode, contract.mode)
    XCTAssertEqual(
      modePlan.identitySlots.map(\.id),
      contract.identityBindings.map(\.sourceSlotID))
    XCTAssertEqual(
      modePlan.identitySlots.map { $0.primaryCandidate?.modelID },
      contract.identityBindings.map(\.modelID))
    XCTAssertEqual(
      modePlan.requiredReceipts,
      contract.receiptRequirements.map(\.id))
    XCTAssertEqual(modePlan.stopRules, contract.stopRules)
  }

  func testPreviewModePlanKeepsGeneralXXLSolOpus5LunaGrokExact() throws {
    let scenarioID = TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID
    let contract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID: scenarioID)
    let modePlan = try WorkOSFactory.previewModePlan(
      mode: .xxl,
      scenarioProfileID: scenarioID,
      contract: contract)

    XCTAssertEqual(
      modePlan.identitySlots.map(\.id),
      contract.identityBindings.map(\.sourceSlotID))
    XCTAssertEqual(
      modePlan.identitySlots.map { $0.primaryCandidate?.modelID },
      ["gpt-5.6-sol", "opus-5", "opus-5", "gpt-5.6-luna", "grok-build", "opus-5"])
    XCTAssertEqual(
      modePlan.identitySlots.map(\.kind),
      [.lead, .supervisor, .verifier, .sub, .sub, .verifier])
  }

  func testNativeDevelopmentContractGrantsHostMutationOnlyToLoopsExecutors()
    throws
  {
    let contract = try WorkOSFactory.preview(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID)

    let solExecutor = try XCTUnwrap(
      contract.identityBindings.first {
        $0.sourceSlotID
          == TatwoNativeDevelopmentDispatchCoordinator.solExecutorSourceSlotID
      })
    XCTAssertEqual(solExecutor.authority, .toolIntentBridge)
    XCTAssertTrue(solExecutor.canMutateHost)

    let opusSupervisor = try XCTUnwrap(
      contract.identityBindings.first {
        $0.sourceSlotID
          == TatwoNativeDevelopmentDispatchCoordinator
            .opusSupervisorSourceSlotID
      })
    XCTAssertEqual(opusSupervisor.authority, .toolIntentBridge)
    XCTAssertTrue(opusSupervisor.canMutateHost)

    let nonExecutors = contract.identityBindings.filter {
      $0.id != solExecutor.id && $0.id != opusSupervisor.id
    }
    XCTAssertTrue(nonExecutors.allSatisfy { $0.authority == .brainOnly })
    XCTAssertTrue(nonExecutors.allSatisfy { !$0.canMutateHost })
  }

  func testPreviewAndPreviewModePlanFailClosedForUnknownCustomScenario() {
    XCTAssertThrowsError(
      try WorkOSFactory.preview(
        mode: .xxl,
        scenarioProfileID: "custom-copy-does-not-exist"))
    XCTAssertThrowsError(
      try WorkOSFactory.previewModePlan(
        mode: .xxl,
        scenarioProfileID: "custom-copy-does-not-exist"))
  }

  func testConfiguredScenarioBindingsOutrankLegacyObjectiveInferenceAcrossMLXLAndXXL() throws {
    for mode in [WorkModeID.m, .l, .xl, .xxl] {
      let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
        in: TatwoScenarioConfigDefaults.book,
        scenarioID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID)
      let contract = try WorkOSFactory.projectContract(
        mode: mode,
        scenarioProfileID: duplicated.scenarioID,
        objective: "Stale history says Fable5 lead with GPT5.5 loops",
        scenarioBook: duplicated.book)

      let configured = contract.loopGovernorDecision.activatedBindings
      XCTAssertFalse(configured.isEmpty, "mode \(mode.rawValue) must have configured bindings")
      XCTAssertEqual(
        contract.identityBindings.count,
        configured.reduce(0) { $0 + max(1, $1.boundModelIDs.count) })
      XCTAssertFalse(
        contract.receiptRequirements.contains { $0.id == "fable5-route-health" },
        "mode \(mode.rawValue) must not activate legacy inference")
      for configuredBinding in configured {
        let expectedModels =
          configuredBinding.boundModelIDs.isEmpty
          ? [String?](arrayLiteral: nil)
          : configuredBinding.boundModelIDs.map(Optional.some)
        XCTAssertEqual(
          contract.identityBindings
            .filter { $0.sourceSlotID == configuredBinding.id }
            .map(\.modelID),
          expectedModels)
      }
    }
  }

  func testDeclaredEmptyDisabledOrInvalidTopologyNeverFallsThroughToLegacyInference() throws {
    enum TopologyVariant: CaseIterable, Equatable {
      case empty
      case disabled
      case invalid
    }

    for mode in [WorkModeID.m, .l, .xl, .xxl] {
      for variant in TopologyVariant.allCases {
        let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
          in: TatwoScenarioConfigDefaults.book,
          scenarioID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID)
        var book = duplicated.book
        let scenarioIndex = try XCTUnwrap(
          book.scenarios.firstIndex { $0.id == duplicated.scenarioID })
        var modeConfig = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[mode])
        switch variant {
        case .empty:
          modeConfig.bindings = []
        case .disabled:
          modeConfig.bindings = modeConfig.bindings.map {
            var binding = $0
            binding.enabled = false
            binding.dynamicActivation = .disabled
            return binding
          }
        case .invalid:
          modeConfig.bindings = [
            TatwoScenarioIdentityBinding(
              id: "configured-invalid-\(mode.rawValue.lowercased())",
              phase: .plan,
              identity: "not-a-workos-identity",
              boundModelIDs: ["fable-5"],
              responsibility: "Invalid configured topology must fail closed to consultant, not legacy.",
              dynamicActivation: .always)
          ]
        }
        book.scenarios[scenarioIndex].modeConfigs[mode] = modeConfig

        let contract = try WorkOSFactory.projectContract(
          mode: mode,
          scenarioProfileID: duplicated.scenarioID,
          objective: "Stale history says Fable5 lead and GPT5.5 loops",
          scenarioBook: book)

        XCTAssertFalse(
          contract.receiptRequirements.contains { $0.id == "fable5-route-health" },
          "\(mode.rawValue) \(variant) must not activate legacy inference")
        XCTAssertFalse(
          contract.identityBindings.contains {
            $0.sourceSlotID.hasPrefix("role-intent-")
              || $0.bindingRule.contains("使用者指定 Fable5")
              || $0.bindingRule.contains("使用者指定 GPT5.5")
          },
          "\(mode.rawValue) \(variant) must not synthesize legacy role-intent bindings")
        if variant == .invalid {
          XCTAssertEqual(
            contract.identityBindings.map(\.identity),
            [.consultant])
        } else {
          XCTAssertTrue(contract.loopGovernorDecision.activatedBindings.isEmpty)
          XCTAssertTrue(
            contract.identityBindings.isEmpty,
            "\(mode.rawValue) \(variant) declared topology must not receive generic bindings")
          let previewPlan = try WorkOSFactory.previewModePlan(
            mode: mode,
            scenarioProfileID: duplicated.scenarioID,
            scenarioBook: book,
            contract: contract)
          XCTAssertTrue(
            previewPlan.identitySlots.isEmpty,
            "\(mode.rawValue) \(variant) declared topology must preview zero identity slots")
        }
      }
    }
  }

  func testRoutePickerOverrideRewritesGovernorAndIdentityBindingsTogether() throws {
    let routeOverride = WorkOSRouteBindingOverride(
      primaryModelID: "opus-5",
      secondaryModelID: "grok-build")
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
      objective: "Explicit picker routes are the dispatch topology",
      routeBindingOverride: routeOverride)

    XCTAssertEqual(contract.routeBindingOverride, routeOverride)
    XCTAssertTrue(
      contract.loopGovernorDecision.activatedBindings
        .filter { $0.identityKind == .lead }
        .allSatisfy { $0.boundModelIDs == ["opus-5"] })
    XCTAssertTrue(
      contract.loopGovernorDecision.activatedBindings
        .filter { $0.identityKind == .sub }
        .allSatisfy { $0.boundModelIDs == ["grok-build"] })
    XCTAssertTrue(
      contract.identityBindings
        .filter { $0.identity == .lead }
        .allSatisfy { $0.modelID == "opus-5" })
    XCTAssertTrue(
      contract.identityBindings
        .filter { $0.identity == .sub }
        .allSatisfy { $0.modelID == "grok-build" })
  }

  func testRoutePickerOverrideRewritesFallbackIdentityPlanWithoutGovernorBindings() throws {
    let routeOverride = WorkOSRouteBindingOverride(
      primaryModelID: "opus-5",
      secondaryModelID: "grok-build")
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "Fallback mode topology must still honor the explicit picker",
      scenarioBook: TatwoScenarioConfigDefaults.book,
      routeBindingOverride: routeOverride)

    XCTAssertTrue(contract.loopGovernorDecision.activatedBindings.isEmpty)
    XCTAssertTrue(
      contract.identityBindings
        .filter { $0.identity == .lead }
        .allSatisfy { $0.modelID == "opus-5" })
    XCTAssertTrue(
      contract.identityBindings
        .filter { $0.identity == .sub }
        .allSatisfy { $0.modelID == "grok-build" })
  }

  func testRoutePickerOverrideFailsClosedWhenRequestedRoleIsMissing() {
    XCTAssertThrowsError(
      try WorkOSFactory.projectContract(
        mode: .s,
        scenarioProfileID: "daily",
        objective: "S mode has no sub role",
        routeBindingOverride: WorkOSRouteBindingOverride(
          primaryModelID: nil,
          secondaryModelID: "grok-build")))
  }

  func testRoutePickerOverrideFailsClosedOnConflictingEffortTopology() throws {
    var book = TatwoScenarioConfigDefaults.book
    let scenarioIndex = try XCTUnwrap(
      book.scenarios.firstIndex {
        $0.id == TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID
      })
    var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
    let grokIndex = try XCTUnwrap(
      config.bindings.firstIndex { $0.boundModelIDs == ["grok-build"] })
    config.bindings[grokIndex].reasoningEffort = .high
    book.scenarios[scenarioIndex].modeConfigs[.xxl] = config

    XCTAssertThrowsError(
      try WorkOSFactory.projectContract(
        mode: .xxl,
        scenarioProfileID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
        objective: "Conflicting sub effort must not be flattened into one route",
        scenarioBook: book,
        routeBindingOverride: WorkOSRouteBindingOverride(
          primaryModelID: nil,
          secondaryModelID: "grok-build")))
  }

  func testSecondaryOnlyPickerIgnoresUnrelatedDualSolEffortConflict() throws {
    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID)
    var book = duplicated.book
    let scenarioIndex = try XCTUnwrap(
      book.scenarios.firstIndex { $0.id == duplicated.scenarioID })
    var config = try XCTUnwrap(book.scenarios[scenarioIndex].modeConfigs[.xxl])
    config.bindings = [
      TatwoScenarioIdentityBinding(
        id: "dual-sol-lead-low",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.6-sol"],
        responsibility: "Primary Sol lane",
        dynamicActivation: .always,
        reasoningEffort: .low),
      TatwoScenarioIdentityBinding(
        id: "dual-sol-lead-xhigh",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.6-sol"],
        responsibility: "Independent Sol continuity lane",
        dynamicActivation: .always,
        reasoningEffort: .xhigh),
      TatwoScenarioIdentityBinding(
        id: "dual-sol-sub-luna",
        phase: .loops,
        identity: "sub",
        boundModelIDs: ["gpt-5.6-luna"],
        responsibility: "Picker-controlled sub lane",
        dynamicActivation: .allowed,
        reasoningEffort: .xhigh),
    ]
    book.scenarios[scenarioIndex].modeConfigs[.xxl] = config

    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: duplicated.scenarioID,
      objective: "Secondary-only picker must not reinterpret unrelated lead effort.",
      scenarioBook: book,
      routeBindingOverride: WorkOSRouteBindingOverride(
        primaryModelID: nil,
        secondaryModelID: "grok-build"))

    XCTAssertEqual(
      contract.loopGovernorDecision.activatedBindings
        .filter { $0.identityKind == .lead }
        .map(\.reasoningEffort),
      [.low, .xhigh])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .lead }.map(\.modelID),
      ["gpt-5.6-sol", "gpt-5.6-sol"])
    XCTAssertEqual(
      contract.identityBindings.filter { $0.identity == .sub }.map(\.modelID),
      ["grok-build"])
  }

  func testStoreBackedCloseGoalPreservesPickerOverrideReceiptGate() throws {
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let store = TatwoGoalRunStore(directoryURL: storeRoot)
    let registry = TatwoDispatchRegistry(directoryURL: storeRoot)
    defer { try? FileManager.default.removeItem(at: storeRoot) }

    let routeOverride = WorkOSRouteBindingOverride(
      primaryModelID: "opus-5",
      secondaryModelID: "grok-build")
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l,
      scenarioProfileID: "debug",
      objective: "Stale history says Fable5 lead and GPT5.5 loops",
      routeBindingOverride: routeOverride,
      store: store)
    XCTAssertEqual(contract.routeBindingOverride, routeOverride)
    XCTAssertFalse(contract.receiptRequirements.contains { $0.id == "fable5-route-health" })

    let alreadySubmitted = try store.submittedReceiptIDs(contractID: contract.contractID)
    for receiptID in contract.receiptRequirements.filter(\.requiredForPass).map(\.id)
    where !alreadySubmitted.contains(receiptID)
    {
      let submission = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: nil,
        receiptID: receiptID,
        receiptKind: "test",
        store: store)
      XCTAssertTrue(submission.ok, submission.decision.message)
    }
    let dispatchBinding = try XCTUnwrap(
      contract.identityBindings.first {
        TatwoExecutionManifestFactory.isDispatchable(modelID: $0.modelID)
      })
    let dispatch = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: dispatchBinding.id,
      sourceSlotID: dispatchBinding.sourceSlotID,
      identity: dispatchBinding.identity,
      modelID: try XCTUnwrap(dispatchBinding.modelID),
      subtask: "picker override close receipt gate",
      helperCap: 1,
      goalStore: store,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: dispatch.id,
      status: .completed,
      receiptID: "picker-terminal-receipt",
      outputRef: "tatwo-test://picker-terminal-receipt",
      goalStore: store,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: store,
      dispatchRegistry: registry)

    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .l,
      scenarioProfileID: "debug",
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store,
      dispatchRegistry: registry)

    XCTAssertTrue(close.ok, close.decision.message)
    XCTAssertEqual(close.status, .passed)
    XCTAssertTrue(close.missingReceiptIDs.isEmpty)
    XCTAssertFalse(close.suppliedReceiptIDs.contains("fable5-route-health"))
  }

  // M4b 更新：native-development workflow 的 required gate 原封不動；
  // execution evidence 只滿足精確綁定的一項，不能順便越過 human/plan seal。
  func testM4bEvidenceReceiptKeepsNativeWorkflowCloseGatesIntact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-m4b-workos-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID,
      objective: "M4b workflow receipt boundaries",
      store: store)
    let liveness = try XCTUnwrap(
      contract.receiptRequirements.first {
        $0.id == "dispatch-liveness" && $0.requiredForPass
      })

    let submission = WorkOSFactory.submitReceipt(
      goalID: contract.goalID,
      contractID: contract.contractID,
      loopID: contract.mainlineLoop.id,
      receiptID: "native-terminal:m4b-workos",
      receiptKind: liveness.kind,
      satisfiesRequirementID: liveness.id,
      store: store)
    XCTAssertTrue(submission.ok, submission.decision.message)

    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store)
    XCTAssertFalse(close.ok)
    XCTAssertTrue(close.suppliedReceiptIDs.contains("dispatch-liveness"))
    XCTAssertFalse(close.missingReceiptIDs.contains("dispatch-liveness"))
    XCTAssertTrue(close.missingReceiptIDs.contains("goal-cycle-seal"))
    XCTAssertTrue(close.missingReceiptIDs.contains("human-gate"))
    XCTAssertTrue(close.missingReceiptIDs.contains("scope-review"))
  }

  func testXLModeCreatesMainlineAndMultipleDomainLoops() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "multi domain app shell")

    XCTAssertEqual(contract.mode, .xl)
    XCTAssertEqual(Set(contract.domainLoops.map(\.domain)), [.ui, .code, .ops])
    XCTAssertTrue(contract.sandboxPolicy.required)
    XCTAssertTrue(contract.sandboxPolicy.humanGateRequired)
    XCTAssertEqual(contract.configStage, .staging)
    XCTAssertEqual(contract.showLoopsProjection.schema, "TatwoWorkOSShowLoopsProjectionV1")
    XCTAssertTrue(contract.showLoopsProjection.readOnly)
    XCTAssertFalse(contract.showLoopsProjection.visualizerCanPromoteRunState)
    XCTAssertTrue(contract.showLoopsProjection.sourceURL.contains("show-loops"))
    XCTAssertTrue(contract.showLoopsProjection.nodes.contains { $0.kind == .mainline })
    XCTAssertTrue(contract.showLoopsProjection.nodes.contains { $0.kind == .domain })
    XCTAssertTrue(contract.showLoopsProjection.nodes.contains { $0.kind == .receipt })
    XCTAssertTrue(contract.showLoopsProjection.nodes.contains { $0.id == "cleanup-inventory" })
    XCTAssertEqual(
      Set(contract.gatewayRouteReservations.map(\.route)),
      [
        "tatwo-os-s", "tatwo-os-m", "tatwo-os-l", "tatwo-os-xl",
      ])
    XCTAssertTrue(contract.failClosedRules.contains { $0.contains("contractID") })
    XCTAssertTrue(
      contract.receiptRequirements.contains {
        $0.id == "web-check-baseline-scan" && $0.requiredForPass
      })
    XCTAssertTrue(
      contract.receiptRequirements.contains {
        $0.id == "web-check-after-scan" && $0.requiredForPass
      })
    XCTAssertTrue(
      contract.receiptRequirements.contains {
        $0.id == "product-design-audit" && $0.requiredForPass
      })
  }

  func testMissingContractIDFailsClosedForActionAndReceiptSubmit() throws {
    let next = try WorkOSFactory.next(
      goalID: "goal-x",
      contractID: nil,
      mode: .m,
      scenarioProfileID: "coding")
    XCTAssertFalse(next.ok)
    XCTAssertEqual(next.decision.code, "missing_contract_id")

    let receipt = WorkOSFactory.submitReceipt(
      goalID: "goal-x",
      contractID: "",
      loopID: "main",
      receiptID: "test-receipt",
      receiptKind: "test")
    XCTAssertFalse(receipt.ok)
    XCTAssertEqual(receipt.decision.code, "missing_contract_id")
  }

  func testThreadPluginDecisionReceiptCannotCloseGoalByItself() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-plugin-decision-goal-\(UUID().uuidString)", isDirectory: true)
    let store = TatwoGoalRunStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "ui-ux",
      objective: "N12 plugin decision is contextual only",
      store: store)

    let decision = WorkOSFactory.submitReceipt(
      goalID: contract.goalID,
      contractID: contract.contractID,
      loopID: contract.mainlineLoop.id,
      receiptID: "thread-plugin-decision-smoke",
      receiptKind: TatwoThreadPluginDecisionContextComposer.receiptKind,
      store: store)
    XCTAssertTrue(decision.ok)

    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .m,
      scenarioProfileID: "ui-ux",
      suppliedReceiptIDs: [],
      store: store)
    XCTAssertFalse(close.ok)
    XCTAssertEqual(close.status, .rollbackRequired)
    XCTAssertTrue(close.suppliedReceiptIDs.contains("thread-plugin-decision-smoke"))
    XCTAssertFalse(close.missingReceiptIDs.contains("thread-plugin-decision-smoke"))
    XCTAssertTrue(close.missingReceiptIDs.contains("cleanup-inventory"))
  }

  func testNextAndLoopStatusKeepBeginIDsWhenObjectiveIsNotRepeated() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "visual blueprint objective")

    let next = try WorkOSFactory.next(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .xl,
      scenarioProfileID: "ui-ux")
    XCTAssertTrue(next.ok)
    XCTAssertEqual(next.goalID, contract.goalID)
    XCTAssertEqual(next.contractID, contract.contractID)
    XCTAssertEqual(next.currentLoopID, contract.mainlineLoop.id)

    let status = try WorkOSFactory.loopStatus(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .xl,
      scenarioProfileID: "ui-ux")
    XCTAssertTrue(status.ok)
    XCTAssertEqual(status.goalID, contract.goalID)
    XCTAssertEqual(status.contractID, contract.contractID)
    XCTAssertEqual(status.mainlineLoop?.id, contract.mainlineLoop.id)
    XCTAssertEqual(status.domainLoops.count, contract.domainLoops.count)
    XCTAssertEqual(status.domainLoops.map(\.id), contract.domainLoops.map(\.id))
    XCTAssertEqual(status.domainLoops.map(\.cycleIndex), contract.domainLoops.map(\.cycleIndex))
    XCTAssertTrue(status.domainLoops.allSatisfy { $0.id.contains(contract.contractID) })
    XCTAssertEqual(Set(status.domainLoops.map(\.id)).count, status.domainLoops.count)
  }

  func testMCPNextAndLoopStatusInferXLContextFromContractID() throws {
    let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-os-infer-\(UUID().uuidString)", isDirectory: true)
    setenv("TATWO_ULTRAWORK_STATE_DIR", stateRoot.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_STATE_DIR")
      try? FileManager.default.removeItem(at: stateRoot)
    }
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "infer context from contract id")
    // #6: next/loop.status now answer from the ledger, so the contract must be one the
    // MCP dispatch actually issued (same deterministic ID as the factory begin above).
    let osBegin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "XL",
        scenario: "ui-ux",
        objective: "infer context from contract id"))
    XCTAssertTrue(osBegin.ok)

    let inferred = WorkOSFactory.inferContext(
      goalID: contract.goalID, contractID: contract.contractID)
    XCTAssertEqual(inferred?.mode, .xl)
    XCTAssertEqual(inferred?.scenarioProfileID, "ui-ux")

    let next = TatwoMCPRegistry.call(
      tool: "tatwo.os.next",
      arguments: [
        "goalID": .string(contract.goalID),
        "contractID": .string(contract.contractID),
      ])
    XCTAssertTrue(next.ok, next.error ?? "")
    guard case .object(let nextPayload) = next.payload,
      case .array(let requiredReceipts)? = nextPayload["requiredReceiptsBeforePass"]
    else {
      return XCTFail("expected next payload")
    }
    let requiredIDs = requiredReceipts.compactMap(\.stringValue)
    XCTAssertTrue(requiredIDs.contains("domain-ui-loop"))
    XCTAssertTrue(requiredIDs.contains("human-gate"))

    let status = TatwoMCPRegistry.call(
      tool: "tatwo.os.loop.status",
      arguments: [
        "goalID": .string(contract.goalID),
        "contractID": .string(contract.contractID),
      ])
    XCTAssertTrue(status.ok, status.error ?? "")
    guard case .object(let statusPayload) = status.payload,
      case .array(let domainLoops)? = statusPayload["domainLoops"]
    else {
      return XCTFail("expected status payload")
    }
    // T1 模式重校: XL 預設 20 個 loops（3 domain × cycle 展開）。
    XCTAssertEqual(domainLoops.count, 20)
  }

  func testGoalCloseRequiresAllRequiredReceipts() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "close requires receipts")

    let missing = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .l,
      scenarioProfileID: "coding",
      objective: "close requires receipts",
      suppliedReceiptIDs: ["contract-id"])
    XCTAssertFalse(missing.ok)
    XCTAssertEqual(missing.status, .rollbackRequired)
    XCTAssertFalse(missing.missingReceiptIDs.isEmpty)

    let allReceipts = contract.receiptRequirements.map(\.id)
    let passed = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .l,
      scenarioProfileID: "coding",
      objective: "close requires receipts",
      suppliedReceiptIDs: allReceipts)
    XCTAssertTrue(passed.ok)
    XCTAssertEqual(passed.status, .passed)
    XCTAssertTrue(passed.missingReceiptIDs.isEmpty)
  }

  func testGoalCloseFailsIfCleanupInventoryIsMissingAfterOtherReceiptsPass() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "close requires cleanup inventory")

    let withoutCleanup = contract.receiptRequirements
      .map(\.id)
      .filter { $0 != PostValidationCleanupInventoryFactory.receiptID }

    let result = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .l,
      scenarioProfileID: "coding",
      objective: "close requires cleanup inventory",
      suppliedReceiptIDs: withoutCleanup)

    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.status, .rollbackRequired)
    XCTAssertTrue(result.missingReceiptIDs.contains(PostValidationCleanupInventoryFactory.receiptID))
  }

  func testStoreBackedGoalCloseRejectsFailedToolUnavailableDispatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-close-terminal-consistency-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "failed dispatch must never become passed",
      store: store)
    let binding = try XCTUnwrap(
      contract.identityBindings.first(where: { $0.modelID != nil }))
    let modelID = try XCTUnwrap(binding.modelID)
    let dispatch = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: modelID,
      subtask: "computer host browser task",
      helperCap: 1,
      goalStore: store,
      dispatchRegistry: registry,
      scenarioBook: TatwoScenarioConfigDefaults.book)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: dispatch.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "tool_unavailable",
      errorMessage: "Computer Host authority was unavailable",
      goalStore: store,
      dispatchRegistry: registry)

    let alreadySubmitted = try store.submittedReceiptIDs(
      contractID: contract.contractID)
    for requirement in contract.receiptRequirements
    where requirement.requiredForPass
      && !alreadySubmitted.contains(requirement.id)
    {
      let submission = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: "evidence-\(requirement.id)",
        receiptKind: requirement.kind,
        satisfiesRequirementID: requirement.id,
        store: store)
      XCTAssertTrue(submission.ok, submission.decision.message)
    }

    let result = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store,
      dispatchRegistry: registry)

    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.status, .blocked)
    XCTAssertEqual(result.decision.code, "tool_unavailable")
    XCTAssertTrue(result.decision.message.contains("Computer Host authority was unavailable"))
    XCTAssertNotEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .passed)
  }

  func testStoreBackedGoalCloseRejectsCompletedButUnsealedDispatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-close-unsealed-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "unsealed dispatch must never become passed",
      store: store)
    let binding = try XCTUnwrap(
      contract.identityBindings.first(where: { $0.modelID != nil }))
    let dispatch = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: try XCTUnwrap(binding.modelID),
      subtask: "complete without seal",
      helperCap: 1,
      goalStore: store,
      dispatchRegistry: registry,
      scenarioBook: TatwoScenarioConfigDefaults.book)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: dispatch.id,
      status: .completed,
      receiptID: "terminal-receipt",
      outputRef: "tatwo-test://terminal-receipt",
      goalStore: store,
      dispatchRegistry: registry)

    let gate = try TatwoGoalRunDispatchLifecycle
      .persistPassedIfTerminalConsistent(
        contractID: contract.contractID,
        requiresCanonicalDispatch: true,
        goalStore: store,
        dispatchRegistry: registry)

    XCTAssertFalse(gate.ok)
    XCTAssertEqual(gate.code, "dispatch_set_unsealed")
    XCTAssertTrue(gate.retryable)
    XCTAssertNotEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .passed)
  }

  func testStoreBackedGoalCloseRejectsMissingDispatchTerminalEvidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-close-missing-dispatch-terminal-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "dispatchable goal requires terminal evidence",
      store: store)
    XCTAssertTrue(
      contract.identityBindings.contains {
        TatwoExecutionManifestFactory.isDispatchable(modelID: $0.modelID)
      })

    for requirement in contract.receiptRequirements
    where requirement.requiredForPass
    {
      let submission = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: "evidence-\(requirement.id)",
        receiptKind: requirement.kind,
        satisfiesRequirementID: requirement.id,
        store: store)
      XCTAssertTrue(submission.ok, submission.decision.message)
    }

    let result = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store,
      dispatchRegistry: registry)

    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.status, .blocked)
    XCTAssertEqual(result.decision.code, "dispatch_terminal_missing")
    XCTAssertNotEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .passed)
  }

  func testDispatchableGoalWithCompleteReceiptsRejectsNilRegistry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-close-missing-registry-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "dispatchable goal requires canonical registry",
      store: store)
    XCTAssertTrue(
      contract.identityBindings.contains {
        TatwoExecutionManifestFactory.isDispatchable(modelID: $0.modelID)
      })

    for requirement in contract.receiptRequirements
    where requirement.requiredForPass
    {
      let submission = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: "evidence-\(requirement.id)",
        receiptKind: requirement.kind,
        satisfiesRequirementID: requirement.id,
        store: store)
      XCTAssertTrue(submission.ok, submission.decision.message)
    }

    let result = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store,
      dispatchRegistry: nil)

    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.status, .blocked)
    XCTAssertEqual(result.decision.code, "dispatch_registry_unavailable")
    XCTAssertNotEqual(result.status, .passed)
    XCTAssertNotEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .passed)
  }

  func testExplicitReceiptOnlyScenarioClosesWithoutDispatchRegistry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-close-receipt-only-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let scenarioID = "receipt-only-no-bindings"
    var modeConfig = TatwoScenarioConfigDefaults.defaultModeConfig(.s)
    modeConfig.bindings = []
    var scenarioBook = TatwoScenarioConfigDefaults.book
    scenarioBook.scenarios.append(
      TatwoCustomScenarioConfig(
        id: scenarioID,
        displayName: "Test · Receipt only",
        baseScenario: .coding,
        builtin: false,
        enabledModes: [.s],
        modeConfigs: [.s: modeConfig]))
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .s,
      scenarioProfileID: scenarioID,
      objective: "explicit receipt-only goal",
      scenarioBook: scenarioBook,
      store: store)
    XCTAssertTrue(contract.identityBindings.isEmpty)

    let requirement = try XCTUnwrap(
      contract.receiptRequirements.first(where: \.requiredForPass))
    // A custom contract must not silently validate against the default book.
    let missingScenario = WorkOSFactory.submitReceipt(
      goalID: contract.goalID,
      contractID: contract.contractID,
      loopID: contract.mainlineLoop.id,
      receiptID: "missing-scenario-evidence",
      receiptKind: requirement.kind,
      satisfiesRequirementID: requirement.id,
      store: store)
    XCTAssertFalse(missingScenario.ok)
    XCTAssertFalse(
      try store.submittedReceiptIDs(contractID: contract.contractID)
        .contains("missing-scenario-evidence"))
    let wrongKind = WorkOSFactory.submitReceipt(
      goalID: contract.goalID,
      contractID: contract.contractID,
      loopID: contract.mainlineLoop.id,
      receiptID: "wrong-kind-evidence",
      receiptKind: "wrong-\(requirement.kind)",
      satisfiesRequirementID: requirement.id,
      scenarioBook: scenarioBook,
      store: store)
    XCTAssertFalse(wrongKind.ok)
    XCTAssertEqual(wrongKind.decision.code, "receipt_requirement_kind_mismatch")
    XCTAssertFalse(
      try store.submittedReceiptIDs(contractID: contract.contractID)
        .contains("wrong-kind-evidence"))

    for requirement in contract.receiptRequirements
    where requirement.requiredForPass
    {
      let submission = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: "evidence-\(requirement.id)",
        receiptKind: requirement.kind,
        satisfiesRequirementID: requirement.id,
        scenarioBook: scenarioBook,
        store: store)
      XCTAssertTrue(submission.ok, submission.decision.message)
    }

    let result = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      scenarioBook: scenarioBook,
      store: store,
      dispatchRegistry: nil)

    XCTAssertTrue(result.ok, result.decision.message)
    XCTAssertEqual(result.status, .passed)
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .passed)
  }

  func testSessionClosePreservesPointerWhenDispatchTerminalEvidenceIsMissing()
    throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-session-close-missing-dispatch-\(UUID().uuidString)",
      isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "session close requires dispatch terminal evidence",
      store: store)
    for requirement in contract.receiptRequirements
    where requirement.requiredForPass
    {
      let submission = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: "evidence-\(requirement.id)",
        receiptKind: requirement.kind,
        satisfiesRequirementID: requirement.id,
        store: store)
      XCTAssertTrue(submission.ok, submission.decision.message)
    }

    let sessionID = "session-\(contract.goalID)"
    let workspacePath = root.appendingPathComponent(
      "workspace",
      isDirectory: true).path
    let pointer = TatwoSessionPointer(
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective)
      .owned(
        provider: "codex",
        sessionID: sessionID,
        workspacePath: workspacePath)
    try sessionStore.writeRawPointerFixtureForTesting(pointer)
    let pointerURL = root.appendingPathComponent(
      "current-session.json",
      isDirectory: false)
    let pointerBytesBefore = try Data(contentsOf: pointerURL)
    let currentBefore = try sessionStore.current()
    let goalBefore = try store.requireIssuedContract(contract.contractID)

    XCTAssertThrowsError(
      try sessionStore.closeAndClearCurrent(
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: sessionID,
          workspacePath: workspacePath)),
        expectedContractID: contract.contractID,
        expectedGoalID: contract.goalID,
        expectedMode: contract.mode,
        expectedScenario: contract.scenario,
        expectedObjective: contract.objective,
        goalStore: store)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionGoalCloseIncomplete)
    }

    XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBytesBefore)
    XCTAssertEqual(try sessionStore.current(), currentBefore)
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID),
      goalBefore)
  }

  func testScenarioWorkflowCompatibilityEmbedsWorkOSContract() throws {
    let contract = try ScenarioWorkflowContractFactory.make(
      mode: .xl,
      scenarioProfileID: "coding",
      objective: "compat routes through work os")

    XCTAssertEqual(contract.workOSContract.schema, "TatwoWorkOSContractV1")
    XCTAssertEqual(contract.workOSContract.mode, .xl)
    XCTAssertFalse(contract.workOSContract.contractID.isEmpty)
    XCTAssertTrue(contract.loopNodes.contains { $0.id == "work-os-contract" })
    XCTAssertTrue(contract.requiredTools.contains("tatwo.os.begin"))
    XCTAssertEqual(contract.agentInvocationPolicy.requiredFirstTool, "tatwo.os.begin")
  }

  func testMCPWorkOSToolsSmokeAndFailClosed() throws {
    let names = Set(TatwoMCPRegistry.tools.map(\.name))
    XCTAssertTrue(names.contains("tatwo.os.begin"))
    XCTAssertTrue(names.contains("tatwo.os.next"))
    XCTAssertTrue(names.contains("tatwo.os.loop.status"))
    XCTAssertTrue(names.contains("tatwo.os.receipt.submit"))
    XCTAssertTrue(names.contains("tatwo.os.goal.close"))
    XCTAssertTrue(names.contains("tatwo.os.dashboard"))
    XCTAssertTrue(names.contains("tatwo.os.enforce"))
    XCTAssertTrue(names.contains("tatwo.os.handoff"))
    XCTAssertTrue(names.contains("tatwo.os.constitution"))
    XCTAssertTrue(names.contains("tatwo.web_check.preflight"))
    XCTAssertTrue(names.contains("tatwo.web_check.plan"))
    XCTAssertTrue(names.contains("tatwo.web_check.import_receipt"))
    XCTAssertTrue(names.contains("tatwo.web_check.receipt_template"))

    // Phase 1: the store is wired into dispatch, so os.begin/submit/close now persist.
    // Redirect the store to a temp dir to keep this smoke test hermetic.
    let tmpAppSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-os-smoke-\(UUID().uuidString)", isDirectory: true)
    setenv("TATWO_ULTRAWORK_APP_SUPPORT", tmpAppSupport.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_APP_SUPPORT")
      try? FileManager.default.removeItem(at: tmpAppSupport)
    }

    let begin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "XL", scenario: "ui-ux", objective: "mcp os smoke"))
    XCTAssertTrue(begin.ok, begin.error ?? "")
    XCTAssertFalse(begin.hostMutationAllowed)

    guard case .object(let beginPayload) = begin.payload,
      case .string(let goalID)? = beginPayload["goalID"],
      case .string(let contractID)? = beginPayload["contractID"],
      case .array(let requiredReceipts)? = beginPayload["receiptRequirements"]
    else {
      return XCTFail("expected Work OS begin payload")
    }

    let next = TatwoMCPRegistry.call(
      tool: "tatwo_os_next",
      arguments: [
        "mode": .string("XL"),
        "scenario": .string("ui-ux"),
        "objective": .string("mcp os smoke"),
        "goalID": .string(goalID),
        "contractID": .string(contractID),
      ])
    XCTAssertTrue(next.ok, next.error ?? "")

    let noContract = TatwoMCPRegistry.call(
      tool: "tatwo.os.receipt.submit",
      arguments: ["goalID": .string(goalID), "receiptID": .string("test-receipt")])
    XCTAssertFalse(noContract.ok)
    XCTAssertTrue(noContract.error?.contains("contractID") == true)

    let requiredIDs: [String] = requiredReceipts.compactMap { value in
      guard case .object(let object) = value, case .string(let id)? = object["id"] else {
        return nil
      }
      return id
    }

    // Fabrication is now fail-closed: naming the required IDs without ever submitting
    // them no longer passes the goal.
    let fabricated = TatwoMCPRegistry.call(
      tool: "tatwo.os.goal.close",
      arguments: [
        "mode": .string("XL"),
        "scenario": .string("ui-ux"),
        "objective": .string("mcp os smoke"),
        "goalID": .string(goalID),
        "contractID": .string(contractID),
        "receiptIDs": .array(requiredIDs.map { JSONValue.string($0) }),
      ])
    XCTAssertFalse(fabricated.ok)

    // Submit through MCP, then provide canonical terminal dispatch evidence before closing.
    for id in requiredIDs {
      let submit = TatwoMCPRegistry.call(
        tool: "tatwo.os.receipt.submit",
        arguments: [
          "contractID": .string(contractID),
          "receiptID": .string(id),
          "receiptKind": .string("test"),
        ])
      XCTAssertTrue(submit.ok, submit.error ?? id)
    }
    let store = TatwoGoalRunStore.default()
    let registry = TatwoDispatchRegistry.default()
    let contract = try WorkOSFactory.storedContractProjection(
      contractID: contractID,
      fallbackMode: .xl,
      fallbackScenarioProfileID: "ui-ux",
      store: store)
    try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: store, registry: registry)
    let close = TatwoMCPRegistry.call(
      tool: "tatwo.os.goal.close",
      arguments: [
        "mode": .string("XL"),
        "scenario": .string("ui-ux"),
        "objective": .string("mcp os smoke"),
        "goalID": .string(goalID),
        "contractID": .string(contractID),
      ])
    XCTAssertTrue(close.ok, close.error ?? "")
  }

  func testCollaborationPresetsExposeCustomLoopsWithoutChangingDefaults() throws {
    let defaults = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "default loops")
    // T1: XL 預設展開到 20 個 loops；cycle 1 仍是三個 scenario domains。
    XCTAssertEqual(defaults.domainLoops.count, 20)
    XCTAssertEqual(
      defaults.domainLoops.filter { $0.cycleIndex == 1 }.map(\.domain), [.ui, .code, .ops])

    let presets = WorkOSFactory.collaborationPresets(mode: .xl, scenarioProfileID: "ui-ux")
    XCTAssertTrue(presets.contains { $0.id == "custom" && $0.editable })
    XCTAssertTrue(presets.contains { $0.id == "mainline-only" })
    XCTAssertTrue(presets.contains { $0.id == "wide-domain" })

    let custom = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "custom loops",
      enabledLoopTemplateIDs: ["loop-template-ui", "loop-template-research"])
    XCTAssertEqual(custom.domainLoops.map(\.domain), [.ui, .research])
    XCTAssertEqual(custom.showLoopsProjection.nodes.filter { $0.kind == .domain }.count, 2)
  }

  func testMModeCanChooseMultipleCustomLoopsByGovernorPolicy() throws {
    let templates = WorkOSFactory.availableLoopTemplates(mode: .m, scenarioProfileID: "coding")
    XCTAssertGreaterThan(templates.count, 1)
    XCTAssertTrue(templates.contains { $0.id == "loop-template-research" })

    let medium = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "custom medium research",
      enabledLoopTemplateIDs: ["loop-template-research", "loop-template-ops"])
    XCTAssertEqual(medium.domainLoops.map(\.domain), [.research, .ops])
    XCTAssertEqual(medium.loopGovernorDecision.mode, .m)
  }

  func testModeBudgetCapsCustomLoops() throws {
    let medium = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "custom medium",
      enabledLoopTemplateIDs: ["loop-template-code", "loop-template-debug", "loop-template-ops"])
    XCTAssertLessThanOrEqual(medium.domainLoops.count, 4)

    let small = try WorkOSFactory.projectContract(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "custom small",
      enabledLoopTemplateIDs: ["loop-template-code"])
    XCTAssertTrue(small.domainLoops.isEmpty)
  }
  func testFanOutGoalsRequireDispatchLivenessAndSupervisionReceipts() throws {
    let medium = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "fanout hardening")
    let receiptIDs = Set(medium.receiptRequirements.map(\.id))
    XCTAssertTrue(receiptIDs.contains("goal-tracker"))
    XCTAssertTrue(receiptIDs.contains("dispatch-liveness"))
    XCTAssertTrue(receiptIDs.contains("supervision-patrol"))
    XCTAssertTrue(medium.failClosedRules.contains { $0.contains("< /dev/null") })
    XCTAssertTrue(medium.stopRules.contains { $0.contains("10 分鐘") || $0.contains("10-minute") })

    let small = try WorkOSFactory.projectContract(
      mode: .s,
      scenarioProfileID: "daily",
      objective: "mainline only")
    let smallReceiptIDs = Set(small.receiptRequirements.map(\.id))
    XCTAssertFalse(smallReceiptIDs.contains("dispatch-liveness"))
    XCTAssertFalse(smallReceiptIDs.contains("supervision-patrol"))
  }

  func testNextBlocksSupervisionGapWhenDispatchIsRunningWithoutPatrol() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-supervision-gap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "running dispatch needs patrol",
      store: store)
    _ = try registry.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub-0",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.5",
      subtask: "background loop")

    let next = try WorkOSFactory.next(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .m,
      scenarioProfileID: "coding",
      objective: "caller fallback must not win",
      store: store,
      registry: registry)

    XCTAssertFalse(next.ok)
    XCTAssertEqual(next.decision.code, "supervision_gap")
    XCTAssertTrue(next.blockingStates.contains("supervision_gap"))
    XCTAssertTrue(next.requiredReceiptsBeforePass.contains("supervision-patrol"))
  }

  func testNextBlocksLegacyFanOutGoalWithoutGoalTrackerReceipt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-goal-tracker-missing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "legacy no tracker")
    let legacy = TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      status: .planned,
      receipts: [])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = try store.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(legacy).write(to: url, options: [.atomic])

    let next = try WorkOSFactory.next(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .m,
      scenarioProfileID: "coding",
      objective: "caller fallback must not win",
      store: store)

    XCTAssertFalse(next.ok)
    XCTAssertEqual(next.decision.code, "goal_tracker_missing")
    XCTAssertTrue(next.blockingStates.contains("goal_tracker_missing"))
    XCTAssertTrue(next.requiredReceiptsBeforePass.contains("goal-tracker"))
  }

  func testNilAuthorityInstanceDiscriminatorPreservesLegacyIDs() throws {
    let legacy = try WorkOSFactory.projectContract(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "small fix")
    let omitted = try WorkOSFactory.projectContract(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "small fix",
      authorityInstanceDiscriminator: nil)

    XCTAssertEqual(omitted.contractID, legacy.contractID)
    XCTAssertEqual(omitted.goalID, legacy.goalID)
    XCTAssertNil(omitted.authorityInstanceDiscriminator)
    XCTAssertNil(legacy.authorityInstanceDiscriminator)
  }

  func testAuthorityInstanceDiscriminatorRejectsEmptyOrWhitespace() {
    for raw in ["", "  \n\t"] {
      XCTAssertThrowsError(
        try WorkOSFactory.projectContract(
          mode: .s,
          scenarioProfileID: "coding",
          objective: "small fix",
          authorityInstanceDiscriminator: raw)
      ) { error in
        XCTAssertEqual(
          error as? TatwoAuthorityInstanceDiscriminatorError,
          .empty)
      }
    }
  }

  func testAuthorityInstanceDiscriminatorIsStableAndScopesDistinctRows() throws {
    let objective = "redacted collision /tmp/tatwo2-fixture/secret"
    let first = "provider:tatwo-chat|ownerKind:thread|sessionID:row-a"
    let second = "provider:tatwo-chat|ownerKind:thread|sessionID:row-b"
    let a1 = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: objective,
      authorityInstanceDiscriminator: first)
    let a2 = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: objective,
      authorityInstanceDiscriminator: first)
    let b = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: objective,
      authorityInstanceDiscriminator: second)

    XCTAssertEqual(a1.contractID, a2.contractID)
    XCTAssertEqual(a1.goalID, a2.goalID)
    XCTAssertEqual(a1.authorityInstanceDiscriminator, first)
    XCTAssertEqual(a2.authorityInstanceDiscriminator, first)
    XCTAssertNotEqual(a1.contractID, b.contractID)
    XCTAssertNotEqual(a1.goalID, b.goalID)
    XCTAssertEqual(b.authorityInstanceDiscriminator, second)
  }

  func testAuthorityScopedIDsUseUnambiguousCanonicalFieldEncoding() throws {
    let firstOverride = WorkOSRouteBindingOverride(
      primaryModelID: "alpha|secondary=beta",
      secondaryModelID: "gamma")
    let secondOverride = WorkOSRouteBindingOverride(
      primaryModelID: "alpha",
      secondaryModelID: "beta|secondary=gamma")
    // This is the exact delimiter collision in the legacy representation.
    XCTAssertEqual(firstOverride.contractIdentity, secondOverride.contractIdentity)

    let discriminator =
      "provider:tatwo-chat|ownerKind:thread|sessionID:row-a"
    let first = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "same scoped objective",
      routeBindingOverride: firstOverride,
      authorityInstanceDiscriminator: discriminator)
    let second = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "same scoped objective",
      routeBindingOverride: secondOverride,
      authorityInstanceDiscriminator: discriminator)

    XCTAssertNotEqual(first.contractID, second.contractID)
    XCTAssertNotEqual(first.goalID, second.goalID)
  }

  func testAuthorityInstanceDiscriminatorAcceptsCanonicalSessionOwner() throws {
    let discriminator =
      "provider:codex-app|ownerKind:session|sessionID:019d_test-42"
    let contract = try WorkOSFactory.projectContract(
      mode: .s,
      scenarioProfileID: "coding",
      objective: "session scoped",
      authorityInstanceDiscriminator: discriminator)

    XCTAssertEqual(
      contract.authorityInstanceDiscriminator,
      discriminator)
  }

  func testAuthorityInstanceDiscriminatorRejectsMalformedOrInjectedValues() {
    let invalid = [
      "provider:|ownerKind:thread|sessionID:row-a",
      "provider:tatwo-chat|ownerKind:thread|sessionID:",
      "ownerKind:thread|provider:tatwo-chat|sessionID:row-a",
      "provider:tatwo-chat|provider:other|sessionID:row-a",
      "provider:tatwo-chat|ownerKind:discussion|sessionID:row-a",
      "provider:tatwo-chat|ownerKind:thread|sessionID:row-a|extra:value",
      "provider:tatwo:chat|ownerKind:thread|sessionID:row-a",
      "provider:tatwo-chat|ownerKind:thread|sessionID:row:a",
      "provider:tatwo-chat|ownerKind:thread|sessionID:row a",
    ]

    for raw in invalid {
      XCTAssertThrowsError(
        try WorkOSFactory.projectContract(
          mode: .s,
          scenarioProfileID: "coding",
          objective: "invalid scoped owner",
          authorityInstanceDiscriminator: raw),
        raw
      ) { error in
        XCTAssertEqual(
          error as? TatwoAuthorityInstanceDiscriminatorError,
          .malformed,
          raw)
      }
    }
  }

  func testRecordBeginStoredContractProjectionReconstructsScopedIDs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-scoped-authority-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let discriminator = "provider:tatwo-chat|ownerKind:thread|sessionID:row-a"
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "scoped persist /tmp/tatwo2-fixture/secret",
      authorityInstanceDiscriminator: discriminator)
    let recorded = try store.recordBegin(contract: contract)
    XCTAssertEqual(recorded.authorityInstanceDiscriminator, discriminator)
    XCTAssertEqual(recorded.contractID, contract.contractID)
    XCTAssertEqual(recorded.goalID, contract.goalID)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let legacyRecord = TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      status: .planned)
    let legacyJSON = try encoder.encode(legacyRecord)
    let legacyText = try XCTUnwrap(String(data: legacyJSON, encoding: .utf8))
    XCTAssertFalse(legacyText.contains("authorityInstanceDiscriminator"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decodedLegacy = try decoder.decode(TatwoStoredGoalRun.self, from: legacyJSON)
    XCTAssertNil(decodedLegacy.authorityInstanceDiscriminator)

    let projected = try WorkOSFactory.storedContractProjection(
      contractID: contract.contractID,
      fallbackMode: .s,
      fallbackScenarioProfileID: "daily",
      fallbackObjective: "must not win",
      store: store)
    XCTAssertEqual(projected.contractID, contract.contractID)
    XCTAssertEqual(projected.goalID, contract.goalID)
    XCTAssertEqual(projected.authorityInstanceDiscriminator, discriminator)
  }

}
