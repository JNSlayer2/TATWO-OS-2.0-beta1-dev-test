import XCTest

@testable import TatwoUltraworkCore

final class WebArenaTests: XCTestCase {
  func testV1PlanCreatesThreeCasesAndExactModelFolderStructure() throws {
    let plan = TatwoWebArenaFactory.plan(
      suite: .v1,
      runID: "20260701-web-arena-v1",
      models: ["gpt-5.5", "sonnet-5", "fable-5", "opus-5", "minimax-m3"]
    )

    XCTAssertEqual(plan.schema, "TatwoWebArenaPlanV1")
    XCTAssertEqual(plan.rootRelativePath, ".tatwo-ultrawork/網頁設計沙盒")
    XCTAssertEqual(plan.runID, "20260701-web-arena-v1")
    XCTAssertEqual(plan.cases.map(\.folderName), ["01-刺青網頁", "02-3D資產收納網頁", "03-Pionex交易所複製"])

    for testCase in plan.cases {
      XCTAssertEqual(testCase.models.map(\.folderName), ["GPT5.5", "SONNET5", "FABLE5", "OPUS5", "MINIMAX-M3"])
      for model in testCase.models {
        XCTAssertTrue(model.relativeFolderPath.contains("網頁設計沙盒/20260701-web-arena-v1/\(testCase.folderName)/\(model.folderName)"))
        XCTAssertEqual(model.requiredFiles, TatwoWebArenaFactory.requiredModelFiles)
      }
    }

    let fable = try XCTUnwrap(plan.cases.first?.models.first { $0.folderName == "FABLE5" })
    XCTAssertEqual(fable.status, .planned)
    XCTAssertTrue(fable.statusReason.contains("route availability checked"))
    XCTAssertTrue(plan.runCommand.contains("web-arena run"))
    XCTAssertTrue(plan.runCommand.contains("--live"))
  }

  func testScoreWeightsMatchThreeBenchmarkPurposes() throws {
    let plan = TatwoWebArenaFactory.plan(suite: .v1, runID: "r", models: ["gpt-5.5"])
    let weights = Dictionary(uniqueKeysWithValues: plan.cases.map { ($0.id, $0.scoreWeights) })

    XCTAssertEqual(weights[.tattoo], TatwoWebArenaScoreWeights(topicUnderstanding: 25, functionality: 20, uiUXAesthetics: 30, engineeringQuality: 15, instructionFollowingHonesty: 10))
    XCTAssertEqual(weights[.assetLibrary3D], TatwoWebArenaScoreWeights(topicUnderstanding: 20, functionality: 25, uiUXAesthetics: 25, engineeringQuality: 20, instructionFollowingHonesty: 10))
    XCTAssertEqual(weights[.pionexStyle], TatwoWebArenaScoreWeights(topicUnderstanding: 20, functionality: 30, uiUXAesthetics: 20, engineeringQuality: 20, instructionFollowingHonesty: 10))
    XCTAssertTrue(plan.cases.first { $0.id == .pionexStyle }!.safetyRules.contains { $0.contains("不使用官方 logo") || $0.contains("不接真交易") })
  }

  func testWebArenaStaticTraitMappingDerivesExamScoresWithoutManualOverride() throws {
    let evidence = try XCTUnwrap(TatwoWebArenaFactory.importedModelEvidence.first { $0.modelSlug == "sonnet-5" })
    let derived = TatwoWebArenaTraitMappingCatalog.derivedEvidence(from: evidence)

    XCTAssertEqual(TatwoWebArenaTraitMappingCatalog.mappings.map(\.category), TatwoWebArenaScoreCategory.allCases)
    XCTAssertTrue(TatwoWebArenaTraitMappingCatalog.markdownTable.contains("Web Arena 主題理解"))
    XCTAssertTrue(TatwoWebArenaTraitMappingCatalog.markdownTable.contains("任務宏觀架構理解"))
    XCTAssertEqual(derived.count, 5)
    XCTAssertTrue(derived.allSatisfy { $0.evidenceSource.contains("derived") })
    XCTAssertTrue(derived.contains { $0.dimensionID == "macro-architecture" && $0.value0To10 == evidence.averageScore / 10 })
    XCTAssertTrue(derived.contains { $0.dimensionID == "aesthetics" && $0.evidenceSource.contains("UI/UX美感") })
    XCTAssertTrue(derived.contains { $0.dimensionID == "hallucination-control" && $0.evidenceSource.contains("誠實度") })
  }

  func testFableBaseIsPlannedButPreviewAliasesStaySkippedInWebArena() throws {
    let plan = TatwoWebArenaFactory.plan(
      suite: .v1,
      runID: "20260701-web-arena-v1",
      models: ["fable5", "fable-5", "fable-5-preview"])

    let models = plan.cases.first?.models ?? []
    XCTAssertTrue(models.contains { $0.slug == "fable-5" && $0.status == .planned })
    XCTAssertTrue(models.contains { $0.slug == "fable-5-preview" && $0.status == .skipped })
    XCTAssertFalse(TatwoWebArenaFactory.isUnavailableModelRoute("fable-5"))
    XCTAssertTrue(TatwoWebArenaFactory.isUnavailableModelRoute("fable-5-preview"))
  }

  func testMissingScreenshotsBlockUIUJEvenWhenEngineeringPasses() throws {
    let report = TatwoWebArenaFactory.evaluate(
      suiteCase: .tattoo,
      modelSlug: "gpt-5.5",
      buildSucceeded: true,
      webCheckErrors: 0,
      webCheckWarnings: 0,
      desktopScreenshotPresent: false,
      mobileScreenshotPresent: false,
      visualAccepted: false,
      scoreInput: TatwoWebArenaScoreInput(
        topicUnderstanding: 22,
        functionality: 18,
        uiUXAesthetics: 24,
        engineeringQuality: 15,
        instructionFollowingHonesty: 10))

    XCTAssertEqual(report.engineeringPassed, true)
    XCTAssertEqual(report.uiUJPassed, false)
    XCTAssertEqual(report.status, .needsVisualEvidence)
    XCTAssertTrue(report.requiredNotice.contains("工程檢查通過，UI/UJ 未通過"))
    XCTAssertLessThan(report.finalScore, 100)
  }

  func testVisualCanPassButEngineeringBlocksPromotion() throws {
    let report = TatwoWebArenaFactory.evaluate(
      suiteCase: .assetLibrary3D,
      modelSlug: "sonnet-5",
      buildSucceeded: true,
      webCheckErrors: 2,
      webCheckWarnings: 0,
      desktopScreenshotPresent: true,
      mobileScreenshotPresent: true,
      visualAccepted: true,
      scoreInput: TatwoWebArenaScoreInput(
        topicUnderstanding: 19,
        functionality: 22,
        uiUXAesthetics: 23,
        engineeringQuality: 10,
        instructionFollowingHonesty: 9))

    XCTAssertEqual(report.uiUJPassed, true)
    XCTAssertEqual(report.engineeringPassed, false)
    XCTAssertEqual(report.status, .engineeringFailed)
    XCTAssertTrue(report.requiredNotice.contains("視覺可接受，工程驗收未通過"))
  }

  func testScaffoldRunCreatesRequiredFoldersAndSkippedReportsWithoutPretendingToScore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let run = try TatwoWebArenaFactory.scaffoldRun(
      root: root,
      suite: .v1,
      runID: "20260701-web-arena-v1",
      models: ["gpt-5.5", "fable-5"])

    XCTAssertEqual(run.schema, "TatwoWebArenaRunReceiptV1")
    XCTAssertFalse(run.hostMutationAllowed)
    XCTAssertFalse(run.modelFanoutExecuted)
    XCTAssertEqual(run.status, "scaffolded_only")
    XCTAssertTrue(run.notes.contains { $0.contains("run --live") })

    let base = root.appendingPathComponent(".tatwo-ultrawork/網頁設計沙盒/20260701-web-arena-v1")
    for folder in ["01-刺青網頁", "02-3D資產收納網頁", "03-Pionex交易所複製"] {
      for model in ["GPT5.5", "FABLE5"] {
        let modelRoot = base.appendingPathComponent("\(folder)/\(model)")
        for required in TatwoWebArenaFactory.requiredModelFiles {
          XCTAssertTrue(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent(required).path), "missing \(required) in \(modelRoot.path)")
        }
        let markdown = try String(contentsOf: modelRoot.appendingPathComponent("評分報告.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("UI/UJ 未通過") || markdown.contains("skipped"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("generated-project/README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("generated-project/arena-project-manifest.json").path))
        let projectReadme = try String(contentsOf: modelRoot.appendingPathComponent("generated-project/README.md"), encoding: .utf8)
        XCTAssertTrue(projectReadme.contains("not model-generated evidence"))
      }
    }

    let summaryJSON = base.appendingPathComponent("summary.json")
    let summaryMarkdown = base.appendingPathComponent("總評分報告.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: summaryJSON.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: summaryMarkdown.path))
    let summaryText = try String(contentsOf: summaryMarkdown, encoding: .utf8)
    XCTAssertTrue(summaryText.contains("TATWO Web Arena v1"))
    XCTAssertTrue(summaryText.contains("不代表模型實測通過"))
  }

  func testReportCommandArtifactsCanBeRefreshedWithoutDeletingSandbox() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try TatwoWebArenaFactory.scaffoldRun(
      root: root,
      suite: .v1,
      runID: "20260701-web-arena-v1",
      models: ["gpt-5.5", "sonnet-5"])
    let runRoot = root.appendingPathComponent(".tatwo-ultrawork/網頁設計沙盒/20260701-web-arena-v1")
    try FileManager.default.removeItem(at: runRoot.appendingPathComponent("summary.json"))
    try FileManager.default.removeItem(at: runRoot.appendingPathComponent("總評分報告.md"))

    let summary = try TatwoWebArenaFactory.writeRunSummaryArtifacts(root: root, runID: "20260701-web-arena-v1")

    XCTAssertEqual(summary.reportCount, 6)
    XCTAssertTrue(FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("summary.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("總評分報告.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("01-刺青網頁/GPT5.5/generated-project").path))
  }

  func testCleanupPlanIsDryRunAndOnlyTargetsSandboxRuns() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldRun = root.appendingPathComponent(".tatwo-ultrawork/網頁設計沙盒/20260601-web-arena-v1", isDirectory: true)
    let newRun = root.appendingPathComponent(".tatwo-ultrawork/網頁設計沙盒/20260701-web-arena-v1", isDirectory: true)
    try FileManager.default.createDirectory(at: oldRun, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newRun, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!

    let cleanup = try TatwoWebArenaFactory.cleanupPlan(root: root, olderThanDays: 14, now: now, dryRun: true)

    XCTAssertTrue(cleanup.dryRun)
    XCTAssertFalse(cleanup.hostMutationAllowed)
    XCTAssertTrue(cleanup.candidates.contains { $0.runID == "20260601-web-arena-v1" })
    XCTAssertFalse(cleanup.candidates.contains { $0.runID == "20260701-web-arena-v1" })
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldRun.path), "dry-run must not delete files")
  }


  func testImportedMiniMaxEvidenceIsSandboxEvidenceNotGlobalModelRanking() throws {
    let evidence = try XCTUnwrap(TatwoWebArenaFactory.importedModelEvidence.first { $0.modelSlug == "minimax-m3" })

    XCTAssertEqual(evidence.id, "minimax-m3-web-arena-v4-20260702")
    XCTAssertEqual(evidence.status, "rollback_required")
    XCTAssertEqual(evidence.reportCount, 3)
    XCTAssertEqual(evidence.failedCount, 3)
    XCTAssertEqual(evidence.sealVerifiedReportCount, 3)
    XCTAssertEqual(evidence.dispatchComplete, false)
    XCTAssertEqual(evidence.caseEvidence.map(\.score), [55, 50, 55])
    XCTAssertEqual(evidence.examScoreSummaryLabel, "Web 考試均分 53.3/100")
    XCTAssertEqual(evidence.manualTraitScoreLabel, "人工評分 5 項")
    XCTAssertFalse(evidence.traitDimensionEvidence.isEmpty)
    XCTAssertEqual(evidence.traitDimensionEvidence.first?.dimensionID, "macro-architecture")
    XCTAssertEqual(evidence.traitDimensionEvidence.first?.value0To10, 2.7)
    XCTAssertTrue(evidence.traitDimensionEvidence.contains { $0.dimensionID == "aesthetics" && $0.value0To10 == 0.0 })
    XCTAssertTrue(evidence.routingImplication.contains("scout"))
    XCTAssertTrue(evidence.routingImplication.contains("不可"))
  }

  func testImportedGrokEvidenceIsSandboxEvidenceNotGlobalModelRanking() throws {
    let evidence = try XCTUnwrap(TatwoWebArenaFactory.importedModelEvidence.first { $0.modelSlug == "grok-build" })

    XCTAssertEqual(evidence.id, "grok-build-web-arena-v1-20260702")
    XCTAssertEqual(evidence.status, "rollback_required")
    XCTAssertEqual(evidence.reportCount, 3)
    XCTAssertEqual(evidence.failedCount, 3)
    XCTAssertEqual(evidence.sealVerifiedReportCount, 3)
    XCTAssertEqual(evidence.dispatchComplete, false)
    XCTAssertEqual(evidence.caseEvidence.map(\.score), [11, 50, 55])
    XCTAssertFalse(evidence.traitDimensionEvidence.isEmpty)
    XCTAssertTrue(evidence.traitDimensionEvidence.contains { $0.dimensionID == "info-forecasting" && $0.value0To10 == 5.4 })
    XCTAssertTrue(evidence.traitDimensionEvidence.contains { $0.dimensionID == "aesthetics" && $0.value0To10 == 0.5 })
    XCTAssertTrue(evidence.routingImplication.contains("消息"))
    XCTAssertTrue(evidence.routingImplication.contains("不可"))
  }

  func testImportedGPT54EvidenceKeepsRollbackGateDespiteHigherSandboxScore() throws {
    let evidence = try XCTUnwrap(TatwoWebArenaFactory.importedModelEvidence.first { $0.modelSlug == "gpt-5.4" })

    XCTAssertEqual(evidence.id, "gpt-5-4-web-arena-v2-20260702")
    XCTAssertEqual(evidence.status, "rollback_required")
    XCTAssertEqual(evidence.reportCount, 3)
    XCTAssertEqual(evidence.failedCount, 3)
    XCTAssertEqual(evidence.sealVerifiedReportCount, 3)
    XCTAssertEqual(evidence.dispatchComplete, true)
    XCTAssertEqual(evidence.caseEvidence.map(\.score), [62, 65, 70])
    XCTAssertTrue(evidence.hasExamScoreRecord)
    XCTAssertEqual(evidence.examScoreSummaryLabel, "Web 考試均分 65.7/100")
    XCTAssertEqual(evidence.manualTraitScoreLabel, "+人工評分")
    XCTAssertTrue(evidence.traitDimensionEvidence.isEmpty, "Unreviewed auto Web Arena totals must not become trait evidence")
    XCTAssertTrue(evidence.caseEvidence.allSatisfy { $0.engineeringPassed == false })
    XCTAssertTrue(evidence.routingImplication.contains("Codex"))
    XCTAssertTrue(evidence.limitations.contains { $0.contains("不可把高語義分誤讀成可上線") })
  }

  func testImportedSonnet5EvidenceKeepsTraitDimensionsPendingUntilHumanMapping() throws {
    let evidence = try XCTUnwrap(TatwoWebArenaFactory.importedModelEvidence.first { $0.modelSlug == "sonnet-5" })

    XCTAssertEqual(evidence.id, "sonnet-5-web-arena-v1-20260702")
    XCTAssertEqual(evidence.status, "rollback_required")
    XCTAssertEqual(evidence.reportCount, 3)
    XCTAssertEqual(evidence.failedCount, 3)
    XCTAssertEqual(evidence.sealVerifiedReportCount, 3)
    XCTAssertEqual(evidence.dispatchComplete, true)
    XCTAssertEqual(evidence.caseEvidence.map(\.score), [62, 65, 70])
    XCTAssertTrue(evidence.hasExamScoreRecord)
    XCTAssertEqual(evidence.examScoreSummaryLabel, "Web 考試均分 65.7/100")
    XCTAssertEqual(evidence.manualTraitScoreLabel, "+人工評分")
    XCTAssertTrue(evidence.traitDimensionEvidence.isEmpty, "Sonnet 5 Web Arena totals must stay pending until mapped into the canonical traits")
    XCTAssertTrue(evidence.routingImplication.contains("正式特質"))
  }

  func testImportedFable5EvidenceIsWebArenaOnlyAndNotAutoRouted() throws {
    let evidence = try XCTUnwrap(TatwoWebArenaFactory.importedModelEvidence.first { $0.modelSlug == "fable-5" })

    XCTAssertEqual(evidence.id, "fable-5-web-arena-v1-20260702")
    XCTAssertEqual(evidence.status, "rollback_required")
    XCTAssertEqual(evidence.reportCount, 3)
    XCTAssertEqual(evidence.failedCount, 3)
    XCTAssertEqual(evidence.sealVerifiedReportCount, 3)
    XCTAssertEqual(evidence.dispatchComplete, true)
    XCTAssertEqual(evidence.caseEvidence.map(\.score), [62, 65, 65])
    XCTAssertTrue(evidence.hasExamScoreRecord)
    XCTAssertEqual(evidence.examScoreSummaryLabel, "Web 考試均分 64/100")
    XCTAssertEqual(evidence.manualTraitScoreLabel, "+人工評分")
    XCTAssertTrue(evidence.traitDimensionEvidence.isEmpty, "Unreviewed auto Web Arena totals must not become trait evidence")
    XCTAssertTrue(evidence.caseEvidence.allSatisfy { $0.engineeringPassed == false })
    XCTAssertTrue(evidence.routingImplication.contains("昂貴"))
    XCTAssertTrue(evidence.routingImplication.contains("不自動"))
    XCTAssertTrue(evidence.limitations.contains { $0.contains("不含 3D") })
  }

  func testImported3DModelingEvidenceAddsDedicatedTraitWithoutPretendingWeb3DIsBlender() throws {
    let gpt54 = try XCTUnwrap(Tatwo3DModelingArenaFactory.importedModelEvidence.first { $0.modelSlug == "gpt-5.4" })
    XCTAssertEqual(gpt54.canonicalScore0To100, 52)
    XCTAssertEqual(gpt54.status, "rollback_required")
    XCTAssertTrue(gpt54.hasOfficialExamScoreRecord)
    XCTAssertEqual(gpt54.examScoreSummaryLabel, "3D 考試 52/100")
    XCTAssertTrue(gpt54.traitDimensionEvidence.contains { $0.dimensionID == "3d-modeling-spatial" && $0.value0To10 == 5.2 })

    let sonnet = try XCTUnwrap(Tatwo3DModelingArenaFactory.importedModelEvidence.first { $0.modelSlug == "sonnet-5" })
    XCTAssertEqual(sonnet.canonicalScore0To100, 0)
    XCTAssertEqual(sonnet.examScoreSummaryLabel, "3D 考試 0/100")
    XCTAssertTrue(sonnet.caseEvidence.contains { $0.official == false && $0.note.contains("不可作正式模型考試分") })

    let fable = try XCTUnwrap(Tatwo3DModelingArenaFactory.importedModelEvidence.first { $0.modelSlug == "fable-5" })
    XCTAssertEqual(fable.canonicalScore0To100, 0)
    XCTAssertTrue(fable.routingImplication.contains("3D 規格主導"))
  }

  func testWebArenaModelAliasesIncludeGrokAndGPT54() throws {
    let plan = TatwoWebArenaFactory.plan(suite: .v1, runID: "alias-run", models: ["grok", "gpt54", "gpt-5-4"])
    let models = plan.cases.first?.models ?? []

    XCTAssertEqual(models.map(\.slug), ["grok-build", "gpt-5.4"])
    XCTAssertEqual(models.map(\.folderName), ["GROK", "GPT5.4"])
    XCTAssertTrue(plan.runCommand.contains("grok-build,gpt-5.4"))
  }

  func testMCPRegistryExposesWebArenaReadOnlyTools() throws {
    let names = Set(TatwoMCPRegistry.tools.map(\.name))
    XCTAssertTrue(names.contains("tatwo.web_arena.plan"))
    XCTAssertTrue(names.contains("tatwo.web_arena.report"))
    XCTAssertTrue(names.contains("tatwo.web_arena.cleanup_plan"))
    XCTAssertTrue(TatwoMCPRegistry.tools.filter { $0.name.contains("web_arena") }.allSatisfy { !$0.hostMutationAllowed })

    let result = TatwoMCPRegistry.call(
      tool: "tatwo_web_arena_plan",
      arguments: ["suite": .string("v1"), "models": .string("gpt-5.5,sonnet-5,fable-5")])
    XCTAssertTrue(result.ok, result.error ?? "")
    let text = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("TatwoWebArenaPlanV1"))
    XCTAssertTrue(text.contains("網頁設計沙盒"))
  }
  func testRunIDAndCustomModelNamesCannotEscapeSandboxOrBreakJSON() throws {
    let plan = TatwoWebArenaFactory.plan(
      suite: .v1,
      runID: "../../bad/run\"id",
      models: ["custom/model\"name"])

    XCTAssertFalse(plan.runID.contains(".."))
    XCTAssertFalse(plan.runID.contains("/"))
    XCTAssertFalse(plan.runID.contains("\""))
    let model = try XCTUnwrap(plan.cases.first?.models.first)
    XCTAssertFalse(model.folderName.contains("/"))
    XCTAssertFalse(model.folderName.contains("\""))
    XCTAssertFalse(model.relativeFolderPath.contains(".."))
    XCTAssertFalse(TatwoWebArenaFactory.folderName(for: "custom..model").contains(".."))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try TatwoWebArenaFactory.scaffoldRun(
      root: root,
      suite: .v1,
      runID: "../../bad/run\"id",
      models: ["custom/model\"name"])

    let report = root.appendingPathComponent(plan.rootRelativePath)
      .appendingPathComponent(plan.runID)
      .appendingPathComponent("01-刺青網頁")
      .appendingPathComponent(model.folderName)
      .appendingPathComponent("web-check-report.json")
    let data = try Data(contentsOf: report)
    XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

}
