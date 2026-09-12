import XCTest

@testable import TatwoUltraworkCore

final class SandboxArenaTests: XCTestCase {
  func testDefinitionsExposeAllMissingSandboxesWithPLGGoalStandard() throws {
    let defs = TatwoSandboxArenaFactory.definitions()
    XCTAssertEqual(defs.map(\.arena), [
      .codeArchitecture, .debug, .research, .multimodal, .pluginMCP, .writing, .modeling3D,
    ])

    for def in defs {
      XCTAssertTrue(def.rootRelativePath.hasPrefix(".tatwo-ultrawork/"))
      XCTAssertEqual(def.goalStandard.mainlineProtocol, "plan+loops+goal-主線")
      XCTAssertEqual(def.goalStandard.branchProtocol, "plan+loops+goal-支線優化")
      XCTAssertEqual(def.goalStandard.maxGoalExecutionCycles, 5)
      XCTAssertTrue(def.requiredModelFiles.contains("tool-choice-ledger.json"))
      XCTAssertTrue(def.requiredModelFiles.contains("final-submission/seal.json"))
      XCTAssertEqual(def.cases.count, 3)
      XCTAssertTrue(def.localOnlyRules.contains { $0.contains("所有測試完成前") })
    }
  }

  func testCodeArchitectureAndDebugArenasHaveHiddenTestsAndProtectedFileAudit() throws {
    let code = TatwoSandboxArenaFactory.plan(
      arena: .codeArchitecture,
      runID: "20260701-sandbox-arena-v1",
      models: ["gpt-5.5", "sonnet-5", "fable-5"])
    XCTAssertEqual(code.rootRelativePath, ".tatwo-ultrawork/代碼架構沙盒")
    XCTAssertEqual(code.cases.map(\.folderName), ["01-功能新增", "02-重構邊界", "03-MCP插件Adapter"])
    XCTAssertTrue(code.cases.allSatisfy { !$0.hiddenChecks.isEmpty })
    XCTAssertTrue(code.cases.allSatisfy { !$0.protectedFiles.isEmpty })
    XCTAssertTrue(code.cases.flatMap(\.requiredReceipts).contains("hidden-tests"))
    XCTAssertEqual(code.cases.first?.models.map(\.folderName), ["GPT5.5", "SONNET5", "FABLE5"])
    XCTAssertEqual(code.cases.first?.models.first { $0.folderName == "FABLE5" }?.status, .planned)

    let debug = TatwoSandboxArenaFactory.plan(
      arena: .debug,
      runID: "20260701-sandbox-arena-v1",
      models: ["gpt-5.5"])
    XCTAssertEqual(debug.rootRelativePath, ".tatwo-ultrawork/Debug沙盒")
    XCTAssertTrue(debug.cases.first?.requiredReceipts.contains("reproduction-log") == true)
    XCTAssertTrue(debug.cases.first?.prompt.contains("先產生 reproduction receipt") == true)
    XCTAssertTrue(debug.cases.map(\.id).contains("regression-trap"))
  }

  func testResearchMultimodalPluginAndWritingArenasMapToMissingTraitCoverage() throws {
    let research = TatwoSandboxArenaFactory.definition(.research)
    XCTAssertTrue(research.cases.flatMap(\.measuredTraits).contains("幻覺度"))
    XCTAssertTrue(research.cases.flatMap(\.requiredReceipts).contains("claim-evidence-table"))

    let multimodal = TatwoSandboxArenaFactory.definition(.multimodal)
    XCTAssertTrue(multimodal.cases.flatMap(\.measuredTraits).contains("多模態水準"))
    XCTAssertTrue(multimodal.cases.flatMap(\.hiddenChecks).contains("hallucinated UI element"))

    let plugin = TatwoSandboxArenaFactory.definition(.pluginMCP)
    XCTAssertTrue(plugin.cases.flatMap(\.requiredReceipts).contains("registry-check"))
    XCTAssertTrue(plugin.cases.flatMap(\.hiddenChecks).contains("missing contractID"))

    let writing = TatwoSandboxArenaFactory.definition(.writing)
    XCTAssertTrue(writing.cases.flatMap(\.measuredTraits).contains("文筆"))
    XCTAssertTrue(writing.cases.flatMap(\.requiredReceipts).contains("readability-review"))
  }

  func testFableBaseIsPlannedButPreviewAliasesStaySkippedUntilRouteIsConfigured() throws {
    let plan = TatwoSandboxArenaFactory.plan(
      arena: .writing,
      runID: "20260701-sandbox-arena-v1",
      models: ["fable5", "fable-5", "fable-5-preview"])

    let models = plan.cases.first?.models ?? []
    XCTAssertEqual(models.map(\.slug), ["fable-5", "fable-5-preview"])
    XCTAssertEqual(models.first { $0.slug == "fable-5" }?.status, .planned)
    XCTAssertEqual(models.first { $0.slug == "fable-5-preview" }?.status, .skipped)
    XCTAssertTrue(models.first { $0.slug == "fable-5-preview" }?.statusReason.contains("route unavailable") == true)
  }


  func test3DModelingArenaCreatesBlenderAndUE58WorkpieceFolders() throws {
    let plan = TatwoSandboxArenaFactory.plan(
      arena: .modeling3D,
      runID: "20260701-3d-arena-v1",
      models: ["gpt-5.5", "fable-5"])

    XCTAssertEqual(plan.rootRelativePath, ".tatwo-ultrawork/3D測試/模型")
    XCTAssertEqual(plan.cases.map(\.folderName), ["01-3D模型規格", "02-Blender作品評分", "03-UE5.8作品驗收"])
    XCTAssertTrue(plan.cases.flatMap(\.requiredReceipts).contains("blender-artifact-index"))
    XCTAssertTrue(plan.cases.flatMap(\.requiredReceipts).contains("ue5-import-manifest"))
    XCTAssertTrue(plan.localOnlyRules.contains { $0.contains("Blender") && $0.contains("UE5.8") })
    XCTAssertTrue(plan.localOnlyRules.contains { $0.contains("degraded") || $0.contains("崩潰") })

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receipt = try TatwoSandboxArenaFactory.scaffoldRun(
      root: root,
      arena: .modeling3D,
      runID: "20260701-3d-arena-v1",
      models: ["gpt-5.5"])

    XCTAssertFalse(receipt.modelFanoutExecuted)
    XCTAssertFalse(receipt.hostMutationAllowed)
    let modelRoot = root
      .appendingPathComponent(".tatwo-ultrawork/3D測試/模型/20260701-3d-arena-v1/02-Blender作品評分/GPT5.5")
    XCTAssertTrue(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("generated-artifacts/作品/Blender/README.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("generated-artifacts/作品/UE5.8/README.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("generated-artifacts/評分/3d-workspace-manifest.json").path))
    let manifest = try String(contentsOf: modelRoot.appendingPathComponent("generated-artifacts/評分/3d-workspace-manifest.json"), encoding: .utf8)
    XCTAssertTrue(manifest.contains("externalToolsAutoStarted"))
    XCTAssertTrue(manifest.contains("false"))
  }

  func testScaffoldCollectionCreatesAllArenaFoldersAndKeepsFanoutClosed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let receipt = try TatwoSandboxArenaFactory.scaffoldCollection(
      root: root,
      arenas: [.codeArchitecture, .debug],
      runID: "20260701-sandbox-arena-v1",
      models: ["gpt-5.5", "fable-5"])

    XCTAssertEqual(receipt.receipts.count, 2)
    XCTAssertFalse(receipt.modelFanoutExecuted)
    XCTAssertFalse(receipt.hostMutationAllowed)

    for arena in [TatwoSandboxArenaID.codeArchitecture, .debug] {
      let plan = TatwoSandboxArenaFactory.plan(
        arena: arena,
        runID: "20260701-sandbox-arena-v1",
        models: ["gpt-5.5", "fable-5"])
      for suiteCase in plan.cases {
        for model in suiteCase.models {
          let modelRoot = root.appendingPathComponent(model.relativeFolderPath)
          for required in TatwoSandboxArenaFactory.requiredModelFiles {
            XCTAssertTrue(
              FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent(required).path),
              "missing \(required) in \(modelRoot.path)")
          }
          let toolChoice = try String(
            contentsOf: modelRoot.appendingPathComponent("tool-choice-ledger.json"),
            encoding: .utf8)
          XCTAssertTrue(toolChoice.contains("allowedRegistryEntryIDs"))
          let report = try String(
            contentsOf: modelRoot.appendingPathComponent("評分報告.md"),
            encoding: .utf8)
          XCTAssertTrue(report.contains("scaffold") || report.contains("skipped"))
        }
      }
      let summary = root.appendingPathComponent(plan.rootRelativePath)
        .appendingPathComponent("20260701-sandbox-arena-v1/summary.json")
      XCTAssertTrue(FileManager.default.fileExists(atPath: summary.path))
    }
  }

  func testMCPExposesSandboxArenaPlanAndReportTools() throws {
    let names = Set(TatwoMCPRegistry.tools.map(\.name))
    XCTAssertTrue(names.contains("tatwo.sandbox_arena.list"))
    XCTAssertTrue(names.contains("tatwo.sandbox_arena.plan"))
    XCTAssertTrue(names.contains("tatwo.sandbox_arena.report"))
    XCTAssertTrue(TatwoMCPRegistry.tools.filter { $0.name.contains("sandbox_arena") }.allSatisfy { !$0.hostMutationAllowed })

    let result = TatwoMCPRegistry.call(
      tool: "tatwo_sandbox_arena_plan",
      arguments: ["arena": .string("all"), "models": .string("gpt-5.5,sonnet-5,fable-5")])
    XCTAssertTrue(result.ok, result.error ?? "")
    let text = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("TatwoSandboxArenaCollectionPlanV1"))
    XCTAssertTrue(text.contains("代碼架構沙盒"))
    XCTAssertTrue(text.contains("Debug沙盒"))
    XCTAssertTrue(text.contains("文筆溝通沙盒"))
    XCTAssertTrue(text.contains("3d-modeling"))
  }
}
