import XCTest
@testable import TatwoUltraworkCore

final class ScenarioConfigTests: XCTestCase {
  private var currentScenarioNames: [String] {
    [
      TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioName,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioName,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLFableGrokScenarioName,
      TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioName
    ] + round13ScenarioNames
  }

  private let round13ScenarioNames = [
    "通用 · XXL · fable5+sol主導",
    "通用 · XL · fable5主導",
    "通用 · L · fable5主導",
    "通用 · L · sol主導",
    "通用 · M · sol主導",
    "通用 · S · terra",
    "UI UX · XL · 8方向煙火（gpt5.5主導·sonnet5評審）",
    "UI UX · L · 5方向煙火",
    "UI UX · M · 3方向煙火",
    "UI UX · S · 2方向輕評",
  ]

  private let legacyRound9ScenarioNames = [
    "XL 重型 · fable5主導＋gpt5.5＋sonnet5",
    "L 專案 · fable5＋gpt5.5",
    "M 協作 · gpt5.5＋sonnet5",
    "M 協作 · gpt5.5＋sonnet5＋minimax",
    "M 協作 · gpt5.5＋minimax＋grok",
    "S 小修 · gpt5.5",
  ]

  func testRound13DefaultScenarioSeedsUseCategoryModeMemberSchema() throws {
    let book = TatwoScenarioConfigDefaults.book

    XCTAssertEqual(book.scenarios.map(\.displayName), currentScenarioNames)
    XCTAssertEqual(Set(book.scenarios.map(\.displayName)).count, 14)
    XCTAssertFalse(book.scenarios.contains { $0.displayName.contains("通用 副本") })
    XCTAssertFalse(book.scenarios.contains { $0.displayName == "通用" })

    // [0] = 通用 · XXL · fable5+sol主導：雙主導(fable5@高 + sol@超高)、terra 獨立副審、luna sub。
    let xxl = try XCTUnwrap(book.scenarios.first { $0.displayName == round13ScenarioNames[0] })
    XCTAssertEqual(xxl.id, "general-xxl-fable5-sol")
    let xxlLeads = xxl.modeConfigs[.xxl]?.bindings.filter { $0.phase == .plan && $0.identity == "主導" } ?? []
    XCTAssertEqual(Set(xxlLeads.flatMap(\.boundModelIDs)), ["fable-5", "gpt-5.6-sol"])
    XCTAssertEqual(xxlLeads.first { $0.boundModelIDs == ["fable-5"] }?.reasoningEffort, .high)
    XCTAssertEqual(xxlLeads.first { $0.boundModelIDs == ["gpt-5.6-sol"] }?.reasoningEffort, .xhigh)
    XCTAssertEqual(xxl.modeConfigs[.xxl]?.bindings.first { $0.phase == .loops && $0.identity == "副審" }?.boundModelIDs, ["gpt-5.6-terra"])
    XCTAssertEqual(xxl.modeConfigs[.xxl]?.bindings.first { $0.phase == .loops && $0.identity == "sub" }?.boundModelIDs, ["gpt-5.6-luna"])

    // [5] = 通用 · S · terra：主線-only、terra@超高 主導/驗收，id 保留 "daily"。
    let small = try XCTUnwrap(book.scenarios.first { $0.displayName == round13ScenarioNames[5] })
    XCTAssertEqual(small.id, "daily")
    XCTAssertEqual(small.modeConfigs[.s]?.bindings.first { $0.phase == .plan && $0.identity == "主導" }?.boundModelIDs, ["gpt-5.6-terra"])
    XCTAssertEqual(small.modeConfigs[.s]?.bindings.first { $0.phase == .plan && $0.identity == "主導" }?.reasoningEffort, .xhigh)
  }

  func testDefaultExactXXLScenarioUsesSolOpusLunaGrokAndNoFable() throws {
    let scenario = try XCTUnwrap(
      TatwoScenarioConfigDefaults.book.scenario(
        id: TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID))
    let bindings = try XCTUnwrap(scenario.modeConfigs[.xxl]?.bindings)

    XCTAssertEqual(bindings.count, 6)
    XCTAssertEqual(
      bindings.filter { $0.identityKind == .lead }.map(\.boundModelIDs),
      [["gpt-5.6-sol"]])
    XCTAssertEqual(
      bindings.first { $0.boundModelIDs == ["gpt-5.6-sol"] }?.reasoningEffort,
      .low)
    XCTAssertTrue(
      bindings.first { $0.boundModelIDs == ["gpt-5.6-sol"] }?
        .responsibility.contains("service tier fast") == true)

    let supervisor = try XCTUnwrap(
      bindings.first { $0.identityKind == .supervisor })
    XCTAssertEqual(supervisor.boundModelIDs, ["opus-5"])
    XCTAssertEqual(supervisor.reasoningEffort, .high)
    XCTAssertEqual(
      bindings.filter { $0.identityKind == .verifier }.map(\.phase),
      [.loops, .goal])
    XCTAssertTrue(
      bindings.filter { $0.identityKind == .verifier }.allSatisfy {
        $0.boundModelIDs == ["opus-5"] && $0.reasoningEffort == .high
      })

    let subs = bindings.filter { $0.identityKind == .sub }
    XCTAssertEqual(
      subs.map(\.boundModelIDs),
      [["gpt-5.6-luna"], ["grok-build"]])
    XCTAssertEqual(subs.map(\.reasoningEffort), [.xhigh, .xhigh])
    XCTAssertFalse(bindings.flatMap(\.boundModelIDs).contains("fable-5"))
  }

  func testNativeDevelopmentXXLScenarioBindsSolAndOpusHighAcrossPlanLoopsGoal()
    throws
  {
    let scenario = try XCTUnwrap(
      TatwoScenarioConfigDefaults.book.scenario(
        id: "general-xxl-sol-opus5-native-development-exact"))
    let bindings = try XCTUnwrap(scenario.modeConfigs[.xxl]?.bindings)

    XCTAssertEqual(bindings.count, 5)
    XCTAssertEqual(
      bindings.first {
        $0.phase == .plan && $0.boundModelIDs == ["gpt-5.6-sol"]
      }?.reasoningEffort,
      .high)
    XCTAssertEqual(
      bindings.first {
        $0.phase == .loops
          && $0.identityKind == .sub
          && $0.boundModelIDs == ["gpt-5.6-sol"]
      }?.reasoningEffort,
      .high)
    XCTAssertEqual(
      bindings.first {
        $0.phase == .loops
          && $0.identityKind == .supervisor
          && $0.boundModelIDs == ["opus-5"]
      }?.reasoningEffort,
      .high)
    XCTAssertEqual(
      bindings.first {
        $0.phase == .loops
          && $0.identityKind == .verifier
          && $0.boundModelIDs == ["opus-5"]
      }?.reasoningEffort,
      .high)
    XCTAssertEqual(
      bindings.first {
        $0.phase == .goal
          && $0.identityKind == .verifier
          && $0.boundModelIDs == ["opus-5"]
      }?.reasoningEffort,
      .high)
  }

  func testExactXXLScenarioKeepsSolAsOnlyLeadAndSeparateReviewerAndSubs() throws {
    let scenario = try XCTUnwrap(
      TatwoScenarioConfigDefaults.book.scenario(
        id: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID))
    let bindings = try XCTUnwrap(scenario.modeConfigs[.xxl]?.bindings)

    XCTAssertEqual(bindings.count, 4)
    XCTAssertEqual(
      bindings.filter { $0.phase == .plan && $0.identity == "主導" }.map(\.boundModelIDs),
      [["gpt-5.6-sol"]])
    XCTAssertEqual(
      bindings.first { $0.boundModelIDs == ["gpt-5.6-sol"] }?.reasoningEffort,
      .low)

    let reviewer = try XCTUnwrap(
      bindings.first { $0.phase == .loops && $0.identity == "副審" })
    XCTAssertEqual(reviewer.identityKind, .supervisor)
    XCTAssertEqual(reviewer.boundModelIDs, ["fable-5"])
    XCTAssertNil(reviewer.reasoningEffort)

    let subs = bindings.filter { $0.phase == .loops && $0.identity == "sub" }
    XCTAssertEqual(subs.map(\.boundModelIDs), [["gpt-5.6-luna"], ["grok-build"]])
    XCTAssertEqual(subs.map(\.reasoningEffort), [.xhigh, .xhigh])
  }

  func testRound13NormalizationMigratesLegacyNamesAndAddsUIUXFamily() throws {
    var legacy = TatwoScenarioConfigBookV1(scenarios: [
      TatwoCustomScenarioConfig(
        id: "daily",
        displayName: "通用",
        baseScenario: .daily,
        builtin: true,
        modeConfigs: TatwoScenarioConfigDefaults.defaultDailyModeConfigs),
      TatwoCustomScenarioConfig(
        id: "custom-copy-daily-1",
        displayName: "通用 副本",
        baseScenario: .daily,
        builtin: false,
        modeConfigs: TatwoScenarioConfigDefaults.defaultDailyModeConfigs),
      TatwoCustomScenarioConfig(
        id: "custom-copy-daily-2",
        displayName: "通用 副本 2",
        baseScenario: .daily,
        builtin: false,
        modeConfigs: TatwoScenarioConfigDefaults.defaultDailyModeConfigs),
    ])

    legacy.scenarios[0].modeConfigs[.m]?.toolBindings = []
    let normalized = legacy.normalizedForCurrentDefaults()

    XCTAssertEqual(normalized.scenarios.map(\.displayName), currentScenarioNames)
    XCTAssertFalse(normalized.scenarios.contains { $0.displayName.contains("通用 副本") })
    XCTAssertFalse(normalized.scenarios.contains { $0.id.hasPrefix("custom-copy-daily") })
    XCTAssertEqual(normalized.scenarios.filter { $0.displayName.hasPrefix("UI UX ·") }.count, 4)
  }
  func testRound13UIUXSeedsBindFireworksTemplateAndR12IdentityGroups() throws {
    let book = TatwoScenarioConfigDefaults.book
    let uiXL = try XCTUnwrap(book.scenario(id: "ui-ux-xl-fireworks"))
    XCTAssertEqual(uiXL.displayName, "UI UX · XL · 8方向煙火（gpt5.5主導·sonnet5評審）")
    XCTAssertEqual(uiXL.baseScenario, .design)

    let xlConfig = try XCTUnwrap(uiXL.modeConfigs[.xl])
    XCTAssertTrue(xlConfig.toolBindings.contains { $0.loopTemplateID == TatwoUIFireworksLoopTemplate.id })
    XCTAssertEqual(xlConfig.bindings.first { $0.id == "ui-ux-xl-plan-lead" }?.boundModelIDs, ["fable-5"])
    XCTAssertEqual(xlConfig.bindings.first { $0.id == "ui-ux-xl-high-risk-judge" }?.boundModelIDs, ["opus-5"])
    XCTAssertEqual(xlConfig.bindings.first { $0.id == "ui-ux-xl-loops-reviewer" }?.boundModelIDs, ["gpt-5.6-terra"])
    XCTAssertEqual(xlConfig.bindings.first { $0.id == "ui-ux-xl-loops-sub" }?.boundModelIDs, ["gpt-5.6-sol"])
  }

  func testScenarioDisplayCategoriesGroupByNamePrefix() throws {
    let groups = TatwoScenarioConfigDefaults.book.scenarioDisplayGroups
    XCTAssertEqual(groups.map(\.category), ["通用", "UI UX"])
    XCTAssertEqual(groups.first { $0.category == "通用" }?.scenarios.count, 10)
    XCTAssertEqual(groups.first { $0.category == "UI UX" }?.scenarios.count, 4)
  }

  func testScenarioConfigStoreLoadMigratesLiveStoreInPlaceAndWritesBakBeforeSaving() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let configPath = dir.appendingPathComponent("scenario-config.json")
    let store = TatwoScenarioConfigStore(fileURL: configPath)
    let legacy = TatwoScenarioConfigBookV1(scenarios: legacyRound9ScenarioNames.enumerated().map { index, name in
      TatwoCustomScenarioConfig(
        id: index == 5 ? "daily" : "legacy-round9-\(index)",
        displayName: name,
        baseScenario: index == 5 ? .daily : .coding,
        builtin: true,
        modeConfigs: TatwoScenarioConfigDefaults.defaultDailyModeConfigs)
    })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let legacyData = try encoder.encode(legacy)
    try legacyData.write(to: configPath)

    let loaded = try store.load()

    XCTAssertEqual(loaded.scenarios.map(\.displayName), currentScenarioNames)
    let saved = try Data(contentsOf: configPath)
    XCTAssertNotEqual(saved, legacyData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: configPath.appendingPathExtension("bak").path))
    XCTAssertEqual(try Data(contentsOf: configPath.appendingPathExtension("bak")), legacyData)
  }


  func testDailyMDefaultBindsRequestedModels() throws {
    let config = TatwoScenarioConfigDefaults.dailyM
    XCTAssertEqual(config.mode, .m)
    XCTAssertTrue(config.tokenBudget.contains("不限制 goal 次數") || config.tokenBudget.contains("goal 不限次數"))

    let planLead = try XCTUnwrap(config.bindings.first { $0.id == "daily-m-plan-lead" })
    XCTAssertEqual(planLead.phase, .plan)
    XCTAssertEqual(planLead.identity, "主導")
    XCTAssertEqual(planLead.boundModelIDs, ["fable-5"])

    let supervisor = try XCTUnwrap(config.bindings.first { $0.id == "daily-m-loops-supervisor" })
    XCTAssertEqual(supervisor.phase, .loops)
    XCTAssertEqual(supervisor.identity, "副審")
    XCTAssertEqual(supervisor.boundModelIDs, ["gpt-5.6-terra"])
    XCTAssertTrue(supervisor.responsibility.contains("指引 sub"))

    let sub = try XCTUnwrap(config.bindings.first { $0.id == "daily-m-loops-sub" })
    XCTAssertEqual(sub.boundModelIDs, ["gpt-5.6-sol"])
  }


  func testScenarioConfigNormalizesLegacyDailyLabelAndToolBindings() throws {
    var legacy = TatwoScenarioConfigDefaults.book
    let dailyIndex = try XCTUnwrap(legacy.scenarios.firstIndex { $0.id == "daily" })
    legacy.scenarios[dailyIndex].displayName = "日常"
    legacy.scenarios[dailyIndex].modeConfigs[.m]?.toolBindings = []
    legacy.scenarios[dailyIndex].modeConfigs[.m]?.tokenBudget = "日常 M legacy budget"
    legacy.scenarios[dailyIndex].modeConfigs[.m]?.agentsMarkdown = "# 日常 M legacy"

    let normalized = legacy.normalizedForCurrentDefaults()

    XCTAssertEqual(normalized.scenario(id: "daily")?.displayName, "通用 · S · terra")
    XCTAssertFalse(normalized.modeConfig(scenarioID: "daily", mode: .m)?.tokenBudget.contains("日常") == true)
    XCTAssertFalse(normalized.modeConfig(scenarioID: "daily", mode: .m)?.agentsMarkdown.contains("日常") == true)
    XCTAssertFalse(normalized.modeConfig(scenarioID: "daily", mode: .m)?.toolBindings.isEmpty ?? true)
    XCTAssertEqual(try ScenarioID.parse("通用"), .daily)
    XCTAssertEqual(try ScenarioID.parse("general"), .daily)
  }

  func testScenarioConfigStableHashIncludesToolBindings() throws {
    let base = TatwoScenarioConfigDefaults.book
    var changed = base
    changed.scenarios[0].modeConfigs[.m]?.toolBindings.append(
      TatwoScenarioToolBinding(
        id: "hash-smoke-tool",
        registryID: "product-design",
        phase: .goal,
        enabled: true,
        required: true,
        note: "Hash must change when Dashboard tool binding changes."))

    XCTAssertNotEqual(base.stableHash, changed.stableHash)
  }

  func testScenarioConfigStoresCanvasWorkflowNodesAndEdges() throws {
    var book = TatwoScenarioConfigDefaults.book
    let dailyIndex = try XCTUnwrap(book.scenarios.firstIndex { $0.id == "daily" })
    var modeConfig = try XCTUnwrap(book.scenarios[dailyIndex].modeConfigs[.m])
    modeConfig.workflowNodes = [
      TatwoScenarioWorkflowNode(
        id: "canvas-plan",
        phase: .plan,
        title: "Plan 工作筐",
        identity: "主導",
        detail: "直接在畫布填 $tatwo-ultrawork /mcp",
        x: 390,
        y: 238,
        boundModelIDs: ["gpt-5.5"],
        toolRegistryIDs: ["tatwo-ultrawork"]),
      TatwoScenarioWorkflowNode(
        id: "canvas-loop",
        phase: .loops,
        title: "Loops 工作筐",
        identity: "副審",
        detail: "拖拽到支線區後保存",
        x: 610,
        y: 420,
        boundModelIDs: ["sonnet-5"],
        toolRegistryIDs: ["product-design"]),
    ]
    modeConfig.workflowEdges = [
      TatwoScenarioWorkflowEdge(id: "edge-plan-loop", fromNodeID: "canvas-plan", toNodeID: "canvas-loop", label: "自定義箭頭")
    ]
    book.scenarios[dailyIndex].modeConfigs[.m] = modeConfig

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = TatwoScenarioConfigStore(fileURL: dir.appendingPathComponent("scenario-config.json"))
    try store.save(book)
    let loaded = try store.load()

    XCTAssertEqual(loaded.modeConfig(scenarioID: "daily", mode: .m)?.workflowNodes.count, 2)
    XCTAssertEqual(loaded.modeConfig(scenarioID: "daily", mode: .m)?.workflowEdges.first?.fromNodeID, "canvas-plan")
    XCTAssertNotEqual(TatwoScenarioConfigDefaults.book.stableHash, loaded.stableHash)
  }

  func testLoopGovernorUsesScenarioConfigAndDoesNotLimitFormalGoalCycles() throws {
    let decision = TatwoLoopGovernor.decide(mode: .m, scenarioID: "daily")
    XCTAssertEqual(decision.mode, .m)
    XCTAssertEqual(decision.scenarioID, "daily")
    XCTAssertTrue(decision.formalGoalCycleRule.contains("不限制次數"))
    XCTAssertTrue(decision.sandboxCycleRule.contains("5 次"))
    XCTAssertTrue(decision.activatedBindings.contains { $0.boundModelIDs.contains("gpt-5.6-terra") })
  }

  func testScenarioConfigStoreRoundTripsCustomScenario() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = TatwoScenarioConfigStore(fileURL: dir.appendingPathComponent("scenario-config.json"))
    var book = TatwoScenarioConfigDefaults.book
    book.scenarios.append(TatwoCustomScenarioConfig(id: "custom-debug", displayName: "Debug", baseScenario: .coding, builtin: false, modeConfigs: [.m: TatwoScenarioConfigDefaults.dailyM]))

    try store.save(book)
    let loaded = try store.load()
    XCTAssertNotNil(loaded.scenario(id: "custom-debug"))
    XCTAssertEqual(loaded.modeConfig(scenarioID: "custom-debug", mode: .m)?.bindings.count, TatwoScenarioConfigDefaults.dailyM.bindings.count)
  }

  func testDefaultScenarioConfigCarriesAllModes() throws {
    let daily = try XCTUnwrap(TatwoScenarioConfigDefaults.book.scenario(id: "daily"))
    XCTAssertTrue(daily.builtin)
    XCTAssertEqual(Set(daily.modeConfigs.keys), Set(WorkModeID.allCases))
    XCTAssertTrue(daily.modeConfigs[.s]?.gateRules.contains { $0.contains("不啟動 sub") } == true)
    XCTAssertTrue(daily.modeConfigs[.xl]?.receiptRules.contains("human-gate") == true)
  }

  func testBuiltinScenarioIsProtectedAndDuplicateIsEditable() throws {
    let book = TatwoScenarioConfigDefaults.book

    XCTAssertThrowsError(
      try TatwoScenarioConfigMutator.renameScenario(
        in: book,
        scenarioID: "daily",
        displayName: "不可直接改"))

    let duplicated = try TatwoScenarioConfigMutator.duplicateScenario(
      in: book,
      scenarioID: "daily")
    XCTAssertFalse(try XCTUnwrap(duplicated.book.scenario(id: duplicated.scenarioID)).builtin)

    let updated = try TatwoScenarioConfigMutator.updateTokenBudget(
      in: duplicated.book,
      scenarioID: duplicated.scenarioID,
      mode: .xl,
      tokenBudget: "XL custom budget")
    XCTAssertEqual(
      updated.book.modeConfig(scenarioID: duplicated.scenarioID, mode: .xl)?.tokenBudget,
      "XL custom budget")
  }

  func testUnlockScenarioCreatesEditableStagingCopyAndKeepsBuiltinLocked() throws {
    let unlocked = try TatwoScenarioConfigMutator.unlockScenarioForStaging(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: "daily")

    let builtin = try XCTUnwrap(unlocked.book.scenario(id: "daily"))
    let staging = try XCTUnwrap(unlocked.book.scenario(id: unlocked.scenarioID))
    XCTAssertTrue(builtin.builtin)
    XCTAssertFalse(staging.builtin)
    XCTAssertNotEqual(staging.id, builtin.id)
    XCTAssertEqual(
      builtin.modeConfigs[.m]?.workflowNodes,
      TatwoScenarioConfigDefaults.book.scenario(id: "daily")?.modeConfigs[.m]?.workflowNodes)
  }

  func testCanvasVersionsSaveSnapshotAndRevertWithoutTouchingVersionHistory() throws {
    let unlocked = try TatwoScenarioConfigMutator.unlockScenarioForStaging(
      in: TatwoScenarioConfigDefaults.book,
      scenarioID: "daily")
    let scenarioID = unlocked.scenarioID

    var book = unlocked.book
    guard let scenarioIndex = book.scenarios.firstIndex(where: { $0.id == scenarioID }) else {
      return XCTFail("missing staging scenario")
    }
    book.scenarios[scenarioIndex].modeConfigs[.m]?.workflowNodes = [
      TatwoScenarioWorkflowNode(
        id: "first-box",
        phase: .plan,
        title: "第一版",
        identity: "Plan Lead",
        detail: "snapshot one",
        x: 320,
        y: 180)
    ]

    let first = try TatwoScenarioConfigMutator.saveCanvasVersion(
      in: book,
      scenarioID: scenarioID,
      mode: .m,
      name: "第一版",
      now: Date(timeIntervalSince1970: 1_800_000_001))
    let firstVersionID = try XCTUnwrap(first.book.modeConfig(scenarioID: scenarioID, mode: .m)?.canvasVersions.first?.id)

    var changed = first.book
    guard let changedIndex = changed.scenarios.firstIndex(where: { $0.id == scenarioID }) else {
      return XCTFail("missing staging scenario")
    }
    changed.scenarios[changedIndex].modeConfigs[.m]?.workflowNodes[0].title = "第二版"
    let second = try TatwoScenarioConfigMutator.saveCanvasVersion(
      in: changed,
      scenarioID: scenarioID,
      mode: .m,
      name: "第二版",
      now: Date(timeIntervalSince1970: 1_800_000_002))

    XCTAssertEqual(second.book.modeConfig(scenarioID: scenarioID, mode: .m)?.canvasVersions.count, 2)
    XCTAssertNotEqual(
      second.book.modeConfig(scenarioID: scenarioID, mode: .m)?.canvasVersions[0].hash,
      second.book.modeConfig(scenarioID: scenarioID, mode: .m)?.canvasVersions[1].hash)

    let reverted = try TatwoScenarioConfigMutator.revertCanvasVersion(
      in: second.book,
      scenarioID: scenarioID,
      mode: .m,
      versionID: firstVersionID)

    XCTAssertEqual(
      reverted.book.modeConfig(scenarioID: scenarioID, mode: .m)?.workflowNodes.first?.title,
      "第一版")
    XCTAssertEqual(reverted.book.modeConfig(scenarioID: scenarioID, mode: .m)?.canvasVersions.count, 2)
  }

  func testWorkOSUsesCustomScenarioConfigBindingsWhenProvided() throws {
    var book = TatwoScenarioConfigDefaults.book
    let custom = try TatwoScenarioConfigMutator.addCustomScenario(
      to: book,
      displayName: "自定義 Debug",
      baseScenario: .coding)
    book = custom.book

    let bindingID = try XCTUnwrap(
      book.modeConfig(scenarioID: custom.scenarioID, mode: .m)?
        .bindings
        .first { $0.phase == .loops && $0.identity == "副審" }?
        .id)
    let rebound = try TatwoScenarioConfigMutator.setBindingModels(
      in: book,
      scenarioID: custom.scenarioID,
      mode: .m,
      bindingID: bindingID,
      modelIDs: ["sonnet-5", "gpt-5.4", "minimax-m3"])

    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: custom.scenarioID,
      objective: "custom scenario smoke",
      scenarioBook: rebound.book)

    XCTAssertEqual(contract.scenario, custom.scenarioID)
    XCTAssertEqual(contract.loopGovernorDecision.configHash, rebound.book.stableHash)
    XCTAssertTrue(contract.loopGovernorDecision.activatedBindings.contains { $0.id == bindingID })
    XCTAssertTrue(contract.identityBindings.contains { $0.modelID == "minimax-m3" && $0.identity == .supervisor })
  }

  func testMCPOSBeginReadsSameStagingScenarioConfigFromStore() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let configPath = dir.appendingPathComponent("scenario-config.json")
    let store = TatwoScenarioConfigStore(fileURL: configPath)
    let custom = try TatwoScenarioConfigMutator.addCustomScenario(
      to: TatwoScenarioConfigDefaults.book,
      displayName: "MCP Custom",
      baseScenario: .coding)
    try store.save(custom.book)

    setenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH", configPath.path, 1)
    setenv("TATWO_ULTRAWORK_STATE_DIR", dir.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH")
      unsetenv("TATWO_ULTRAWORK_STATE_DIR")
      try? FileManager.default.removeItem(at: dir)
    }

    let result = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "M",
        scenario: custom.scenarioID,
        objective: "mcp staging config smoke"))

    XCTAssertTrue(result.ok, result.error ?? "")
    guard case .object(let payload)? = result.payload,
      case .string(let scenario)? = payload["scenario"],
      case .object(let decision)? = payload["loopGovernorDecision"],
      case .string(let configHash)? = decision["configHash"]
    else {
      return XCTFail("expected WorkOS payload")
    }
    XCTAssertEqual(scenario, custom.scenarioID)
    XCTAssertEqual(configHash, custom.book.stableHash)
  }

  func testMCPScenarioConfigMutationsPersistToSameWorkOSStagingConfig() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let configPath = dir.appendingPathComponent("scenario-config.json")
    setenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH", configPath.path, 1)
    setenv("TATWO_ULTRAWORK_STATE_DIR", dir.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH")
      unsetenv("TATWO_ULTRAWORK_STATE_DIR")
    }

    // Phase 2: config mutation now requires a registered contract — begin one first.
    let gateBegin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "M", scenario: "coding", objective: "config gate"))
    guard case .object(let gatePayload)? = gateBegin.payload,
      case .string(let contractID)? = gatePayload["contractID"]
    else { return XCTFail("expected contractID from os.begin") }

    let add = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.config.add",
      arguments: [
        "contractID": .string(contractID),
        "displayName": .string("MCP Editable Daily"),
        "baseScenario": .string("daily"),
      ])
    XCTAssertTrue(add.ok, add.error ?? "")
    let scenarioID = try mutationScenarioID(add)

    let budget = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.config.update_token_budget",
      arguments: [
        "contractID": .string(contractID),
        "scenario": .string(scenarioID),
        "mode": .string("M"),
        "tokenBudget": .string("MCP custom M budget; formal goal has no fixed cycle limit."),
      ])
    XCTAssertTrue(budget.ok, budget.error ?? "")

    let bind = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.config.set_binding_models",
      arguments: [
        "contractID": .string(contractID),
        "scenario": .string(scenarioID),
        "mode": .string("M"),
        "bindingID": .string("daily-m-loops-supervisor"),
        "modelIDs": .array([.string("sonnet-5"), .string("gpt-5.4"), .string("minimax-m3")]),
      ])
    XCTAssertTrue(bind.ok, bind.error ?? "")

    let responsibility = TatwoMCPRegistry.call(
      tool: "tatwo_scenario_config_update_binding_responsibility",
      arguments: [
        "contractID": .string(contractID),
        "scenario": .string(scenarioID),
        "mode": .string("M"),
        "bindingID": .string("daily-m-loops-supervisor"),
        "responsibility": .string("Alias smoke: supervise loops and approve sub receipts."),
      ])
    XCTAssertTrue(responsibility.ok, responsibility.error ?? "")

    let stored = try TatwoScenarioConfigStore(fileURL: configPath).load()
    XCTAssertEqual(
      stored.modeConfig(scenarioID: scenarioID, mode: .m)?.tokenBudget,
      "MCP custom M budget; formal goal has no fixed cycle limit.")
    XCTAssertEqual(
      stored.modeConfig(scenarioID: scenarioID, mode: .m)?
        .bindings.first { $0.id == "daily-m-loops-supervisor" }?
        .boundModelIDs,
      ["sonnet-5", "gpt-5.4", "minimax-m3"])
    XCTAssertEqual(
      stored.modeConfig(scenarioID: scenarioID, mode: .m)?
        .bindings.first { $0.id == "daily-m-loops-supervisor" }?
        .responsibility,
      "Alias smoke: supervise loops and approve sub receipts.")

    let begin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "M",
        scenario: scenarioID,
        objective: "mcp mutation staging smoke"))
    XCTAssertTrue(begin.ok, begin.error ?? "")
    guard case .object(let beginPayload)? = begin.payload,
      case .object(let decision)? = beginPayload["loopGovernorDecision"],
      case .string(let configHash)? = decision["configHash"]
    else {
      return XCTFail("expected WorkOS payload after mutation")
    }
    XCTAssertEqual(configHash, stored.stableHash)
  }

  func testWorkOSContractEmbedsLoopGovernorDecisionAndDashboardBindings() throws {
    let contract = try WorkOSFactory.projectContract(mode: .m, scenarioProfileID: "daily", objective: "daily m")
    XCTAssertEqual(contract.loopGovernorDecision.mode, .m)
    XCTAssertTrue(contract.loopGovernorDecision.activatedBindings.contains { $0.id == "daily-m-loops-supervisor" })
    XCTAssertTrue(contract.identityBindings.contains { $0.modelID == "gpt-5.6-terra" && $0.identity == .supervisor })
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "goal-cycle-seal" && $0.plainPurpose.contains("正式 goal 不受此限制") })
  }

  private func mutationScenarioID(_ result: TatwoMCPToolCallResult) throws -> String {
    guard case .object(let payload)? = result.payload,
      case .string(let scenarioID)? = payload["scenarioID"]
    else {
      throw XCTSkip("missing mutation scenarioID")
    }
    return scenarioID
  }
}
