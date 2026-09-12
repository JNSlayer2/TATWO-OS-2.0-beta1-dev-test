import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoPlanArtifactTests: XCTestCase {
  private let createdAt = Date(timeIntervalSince1970: 1_724_000_000)
  private let updatedAt = Date(timeIntervalSince1970: 1_724_000_120)

  func testCanonicalEncodingIsStableAndRoundTrips() throws {
    let artifact = TatwoPlanArtifactV1(
      planID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      threadID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      objective: "Add a safe calculator plan",
      sections: [
        .init(title: "Scope", body: "Inspect `calc.py`."),
        .init(title: "Symbols", body: "Update `add` and `sub`."),
      ],
      sourceAssistantMessageID: "assistant-plan-1",
      createdAt: createdAt,
      updatedAt: updatedAt,
      state: .discussing)

    let first = try artifact.canonicalJSONData()
    let second = try artifact.canonicalJSONData()

    XCTAssertEqual(first, second)
    XCTAssertEqual(
      try JSONDecoder.tatwoPlanArtifact.decode(TatwoPlanArtifactV1.self, from: first),
      artifact)
    XCTAssertEqual(artifact.schema, TatwoPlanArtifactV1.schemaName)
    XCTAssertEqual(artifact.sourceAssistantMessageID, "assistant-plan-1")

    let text = try XCTUnwrap(String(data: first, encoding: .utf8))
    XCTAssertLessThan(
      try XCTUnwrap(text.range(of: "\"objective\"")?.lowerBound),
      try XCTUnwrap(text.range(of: "\"planID\"")?.lowerBound))
  }

  func testLegacyArtifactDecodesWithoutPlanFlowSelection() throws {
    let artifact = TatwoPlanArtifactV1(
      threadID: UUID(),
      objective: "legacy",
      createdAt: createdAt)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: artifact.canonicalJSONData()) as? [String: Any])
    object.removeValue(forKey: "planFlowSelection")
    object.removeValue(forKey: "sourceAssistantMessageID")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder.tatwoPlanArtifact.decode(
      TatwoPlanArtifactV1.self,
      from: legacyData)
    XCTAssertNil(decoded.planFlowSelection)
    XCTAssertNil(decoded.sourceAssistantMessageID)
  }

  func testPlanFlowSelectionReportsMissingFieldsAndCompletes() {
    var selection = TatwoPlanArtifactV1.PlanFlowSelectionV1(
      destination: .plg,
      collaboration: .multiModel,
      modelAssignment: .primarySecondary)
    XCTAssertEqual(
      selection.missingSelections,
      ["primaryModelID", "secondaryModelID"])
    selection.primaryModelID = "gpt-5.5"
    selection.secondaryModelID = "sonnet-5"
    XCTAssertTrue(selection.isComplete)
  }

  func testPlanFlowSelectionDoesNotPretendPLGSingleModelIsExecutable() {
    let incomplete = TatwoPlanArtifactV1.PlanFlowSelectionV1()
    XCTAssertEqual(
      incomplete.missingSelections,
      ["destination", "collaboration"])
    XCTAssertEqual(incomplete.executionBlocker, "請先選擇 /goal 或 /plg")
    XCTAssertEqual(incomplete.selectionSummary, "已選：未選流程 · 未選拓撲")

    let plgOnly = TatwoPlanArtifactV1.PlanFlowSelectionV1(
      destination: .plg)
    XCTAssertEqual(plgOnly.executionBlocker, "請先選擇 單模型 或 Ultrawork")

    let plgSingle = TatwoPlanArtifactV1.PlanFlowSelectionV1(
      destination: .plg,
      collaboration: .singleModel,
      modelAssignment: .single)
    XCTAssertEqual(plgSingle.missingSelections, ["plgRequiresUltrawork"])
    XCTAssertEqual(
      plgSingle.executionBlocker,
      "PLG 需要 Ultrawork 協作；單模型請改選 /goal")
    XCTAssertFalse(plgSingle.isComplete)
    XCTAssertEqual(plgSingle.selectionSummary, "已選：/plg · 單模型")

    let goalSingle = TatwoPlanArtifactV1.PlanFlowSelectionV1(
      destination: .goal,
      collaboration: .singleModel,
      modelAssignment: .single)
    XCTAssertTrue(goalSingle.isComplete)
    XCTAssertNil(goalSingle.executionBlocker)
    XCTAssertEqual(goalSingle.selectionSummary, "已選：/goal · 單模型")
  }

  /// 2026-08-27 缺陷 B：/plg + Ultrawork S 已在角色設定顯示「主導 terra」，
  /// 回到執行畫面卻報「Ultrawork 尚未指定主導模型」且 Execute 反灰。
  /// S 只有主導、沒有副審，硬要 secondary 也會讓同一張卡片卡死。
  func testUltraworkLeaderOnlyTopologyIsExecutableWithoutAuxiliaryModel() {
    var sTier = TatwoPlanArtifactV1.PlanFlowSelectionV1(
      destination: .plg,
      collaboration: .multiModel,
      modelAssignment: .primarySecondary,
      primaryModelID: "gpt-5.6-terra",
      secondaryModelID: nil,
      auxiliaryModelCount: 0)

    XCTAssertEqual(sTier.missingSelections, [])
    XCTAssertNil(sTier.executionBlocker)
    XCTAssertTrue(sTier.isComplete)

    sTier.primaryModelID = nil
    XCTAssertEqual(sTier.missingSelections, ["primaryModelID"])
    XCTAssertEqual(sTier.executionBlocker, "Ultrawork 尚未指定主導模型")
  }

  func testUltraworkWithAuxiliarySlotsStillRequiresSecondaryModel() {
    let mTier = TatwoPlanArtifactV1.PlanFlowSelectionV1(
      destination: .plg,
      collaboration: .multiModel,
      modelAssignment: .primarySecondary,
      primaryModelID: "gpt-5.6-terra",
      secondaryModelID: nil,
      auxiliaryModelCount: 1)

    XCTAssertEqual(mTier.missingSelections, ["secondaryModelID"])
    XCTAssertEqual(mTier.executionBlocker, "Ultrawork 尚未指定輔模型")

    // 舊資料沒有 auxiliaryModelCount 時維持原本的 fail-closed 行為。
    let legacy = TatwoPlanArtifactV1.PlanFlowSelectionV1(
      destination: .plg,
      collaboration: .multiModel,
      modelAssignment: .primarySecondary,
      primaryModelID: "gpt-5.6-terra")
    XCTAssertEqual(legacy.missingSelections, ["secondaryModelID"])
  }

  func testAuxiliaryModelCountRoundTripsAndStaysOptionalOnLegacyJSON() throws {
    let artifact = TatwoPlanArtifactV1(
      threadID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
      objective: "terra s tier",
      createdAt: createdAt,
      planFlowSelection: .init(
        destination: .plg,
        collaboration: .multiModel,
        modelAssignment: .primarySecondary,
        primaryModelID: "gpt-5.6-terra",
        auxiliaryModelCount: 0))

    let decoded = try JSONDecoder.tatwoPlanArtifact.decode(
      TatwoPlanArtifactV1.self,
      from: artifact.canonicalJSONData())
    XCTAssertEqual(decoded, artifact)
    XCTAssertEqual(decoded.planFlowSelection?.auxiliaryModelCount, 0)
    XCTAssertEqual(decoded.planFlowSelection?.primaryModelID, "gpt-5.6-terra")

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: artifact.canonicalJSONData()) as? [String: Any])
    var selection = try XCTUnwrap(
      object["planFlowSelection"] as? [String: Any])
    selection.removeValue(forKey: "auxiliaryModelCount")
    object["planFlowSelection"] = selection
    let legacy = try JSONDecoder.tatwoPlanArtifact.decode(
      TatwoPlanArtifactV1.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.planFlowSelection?.auxiliaryModelCount)
    XCTAssertTrue(legacy.planFlowSelection?.requiresAuxiliaryModel == true)
  }

  func testMarkdownExportHasStableDiffableFormat() {
    let artifact = TatwoPlanArtifactV1(
      planID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      threadID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      objective: "Add a safe calculator plan",
      sections: [
        .init(title: "Scope", body: "Inspect `calc.py`."),
        .init(title: "Symbols", body: "Update `add` and `sub`."),
      ],
      createdAt: createdAt,
      updatedAt: updatedAt,
      state: .discussing)

    XCTAssertEqual(
      artifact.markdownExport(),
      """
      # Plan

      ## Objective

      Add a safe calculator plan

      ## Scope

      Inspect `calc.py`.

      ## Symbols

      Update `add` and `sub`.
      """)
  }

  func testOnlyExplicitConfirmationMovesArtifactToConfirmed() {
    var artifact = TatwoPlanArtifactV1(
      threadID: UUID(),
      objective: "Initial objective",
      createdAt: createdAt)

    artifact.updateDiscussion(
      objective: "Refined objective",
      sections: [.init(title: "Steps", body: "Discuss first.")],
      at: updatedAt)

    XCTAssertEqual(artifact.state, .discussing)
    XCTAssertEqual(artifact.createdAt, createdAt)
    XCTAssertEqual(artifact.updatedAt, updatedAt)

    artifact.confirm(at: updatedAt.addingTimeInterval(30))

    XCTAssertEqual(artifact.state, .confirmed)
    XCTAssertEqual(artifact.updatedAt, updatedAt.addingTimeInterval(30))
  }

  func testNewDiscussionAfterConfirmationReturnsToDiscussingWithoutReplacingIdentity() {
    let planID = UUID()
    let threadID = UUID()
    var artifact = TatwoPlanArtifactV1(
      planID: planID,
      threadID: threadID,
      objective: "Initial objective",
      createdAt: createdAt,
      state: .confirmed)

    artifact.updateDiscussion(
      objective: "Changed after confirmation",
      sections: [.init(title: "Impact", body: "Re-open review.")],
      at: updatedAt)

    XCTAssertEqual(artifact.planID, planID)
    XCTAssertEqual(artifact.threadID, threadID)
    XCTAssertEqual(artifact.createdAt, createdAt)
    XCTAssertEqual(artifact.updatedAt, updatedAt)
    XCTAssertEqual(artifact.state, .discussing)
    XCTAssertEqual(artifact.objective, "Changed after confirmation")
  }

  func testPlanResponseSectionsParseSupportedMarkdownHeadings() {
    let sections = TatwoPlanArtifactV1.sections(
      fromModelResponse: """
      # 架構
      保留既有 runtime。

      **測試**
      先寫 RED。

      3. 驗收
      跑 parse 與全量測試。
      """)

    XCTAssertEqual(sections, [
      .init(title: "架構", body: "保留既有 runtime。"),
      .init(title: "測試", body: "先寫 RED。"),
      .init(title: "驗收", body: "跑 parse 與全量測試。"),
    ])
  }

  func testPlanResponseDropsEmptyContainerHeading() {
    let sections = TatwoPlanArtifactV1.sections(
      fromModelResponse: """
      # Plan

      ## Context

      Keep the existing store authoritative.
      """)

    XCTAssertEqual(
      sections,
      [
        .init(
          title: "Context",
          body: "Keep the existing store authoritative.")
      ])
  }

  func testPlanResponseWithoutStructureFallsBackToSinglePlanSection() {
    XCTAssertEqual(
      TatwoPlanArtifactV1.sections(
        fromModelResponse: "先檢查現況，再逐項修改與驗收。"),
      [.init(title: "計劃", body: "先檢查現況，再逐項修改與驗收。")])
  }

  func testPlanResponseNumberedLinesSplitOnlyWhenTheyAreSectionHeadings() {
    XCTAssertEqual(
      TatwoPlanArtifactV1.sections(
        fromModelResponse: """
        1. 現況
        讀取來源。
        2. 修改
        寫入 sections。
        """),
      [
        .init(title: "現況", body: "讀取來源。"),
        .init(title: "修改", body: "寫入 sections。"),
      ])
  }

  func testOrderedImplementationListStaysInsideMarkdownSection() {
    XCTAssertEqual(
      TatwoPlanArtifactV1.sections(
        fromModelResponse: """
        ## Implementation

        1. Validate the selected folder.
        2. Preview imported metadata.
        3. Persist after confirmation.

        ## Validation

        Exercise cancellation and restart recovery.
        """),
      [
        .init(
          title: "Implementation",
          body: """
          1. Validate the selected folder.
          2. Preview imported metadata.
          3. Persist after confirmation.
          """),
        .init(
          title: "Validation",
          body: "Exercise cancellation and restart recovery."),
      ])
  }

  func testPreHeadingNumberedContentIsNeverDropped() {
    XCTAssertEqual(
      TatwoPlanArtifactV1.sections(
        fromModelResponse: """
        1. Inspect the current import path.
        2. Preserve existing metadata.

        ## Validation

        Exercise cancellation and restart recovery.
        """),
      [
        .init(
          title: "計劃",
          body: """
          1. Inspect the current import path.
          2. Preserve existing metadata.
          """),
        .init(
          title: "Validation",
          body: "Exercise cancellation and restart recovery."),
      ],
      "Content before the first recognized section heading must remain visible")
  }

  // MARK: 2026-08-21 畫布內編輯（鉛筆→修改→儲存）

  func testEditableTextRoundTripsThroughApplyEditedText() {
    var artifact = TatwoPlanArtifactV1(
      threadID: UUID(),
      objective: "原目標",
      sections: [
        .init(title: "範圍", body: "只動 calc.py。"),
        .init(title: "驗收", body: "測試全綠。"),
      ],
      state: .confirmed)
    let text = artifact.editableText()
    artifact.applyEditedText(text)
    XCTAssertEqual(artifact.objective, "原目標")
    XCTAssertEqual(
      artifact.sections.map(\.title), ["範圍", "驗收"])
    XCTAssertEqual(
      artifact.sections.map(\.body), ["只動 calc.py。", "測試全綠。"])
    XCTAssertEqual(
      artifact.state, .discussing,
      "手改內容必須退回 discussing，確認需重新走人門")
  }

  func testApplyEditedTextUpdatesObjectiveAndParsesSections() {
    var artifact = TatwoPlanArtifactV1(
      threadID: UUID(), objective: "舊目標")
    artifact.applyEditedText("""
      新目標：加 power 函式

      ## 實作
      改 calc.py。

      ## 風險
      無。
      """)
    XCTAssertEqual(artifact.objective, "新目標：加 power 函式")
    XCTAssertEqual(artifact.sections.map(\.title), ["實作", "風險"])
  }

  func testApplyEditedTextIgnoresEmptyInputAndKeepsArtifact() {
    var artifact = TatwoPlanArtifactV1(
      threadID: UUID(),
      objective: "保留我",
      sections: [.init(title: "唯一", body: "內容")])
    let before = artifact
    artifact.applyEditedText("   \n  ")
    XCTAssertEqual(artifact, before, "空輸入不得清空計劃書")
  }
}
