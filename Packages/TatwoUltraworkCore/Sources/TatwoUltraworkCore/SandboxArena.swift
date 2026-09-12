import Foundation

public enum TatwoSandboxArenaID: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case codeArchitecture = "code-architecture"
  case debug = "debug"
  case research = "research"
  case multimodal = "multimodal"
  case pluginMCP = "plugin-mcp"
  case writing = "writing"
  case modeling3D = "3d-modeling"

  public var folderName: String {
    switch self {
    case .codeArchitecture: return "代碼架構沙盒"
    case .debug: return "Debug沙盒"
    case .research: return "研究查證沙盒"
    case .multimodal: return "多模態理解沙盒"
    case .pluginMCP: return "MCP插件適配沙盒"
    case .writing: return "文筆溝通沙盒"
    case .modeling3D: return "3D測試/模型"
    }
  }

  public var title: String {
    switch self {
    case .codeArchitecture: return "Code Architecture Arena"
    case .debug: return "Debug Arena"
    case .research: return "Research / Fact Arena"
    case .multimodal: return "Multimodal Arena"
    case .pluginMCP: return "Plugin / MCP Adaptation Arena"
    case .writing: return "Writing / Communication Arena"
    case .modeling3D: return "3D Modeling Arena"
    }
  }

  public var chineseTitle: String {
    switch self {
    case .codeArchitecture: return "代碼架構評分沙盒"
    case .debug: return "除錯評分沙盒"
    case .research: return "研究查證評分沙盒"
    case .multimodal: return "圖像理解評分沙盒"
    case .pluginMCP: return "插件 / MCP 適配評分沙盒"
    case .writing: return "文筆溝通評分沙盒"
    case .modeling3D: return "3D 建模評分沙盒"
    }
  }

  public static func parse(_ raw: String?) -> [TatwoSandboxArenaID] {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Array(Self.allCases)
    }
    let parts = raw.split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    if parts.contains("all") { return Array(Self.allCases) }
    let mapped = parts.compactMap { part -> TatwoSandboxArenaID? in
      switch part {
      case "code", "architecture", "code-architecture", "code_architecture", "代碼架構":
        return .codeArchitecture
      case "debug", "除錯":
        return .debug
      case "research", "fact", "研究", "查證":
        return .research
      case "multimodal", "vision", "image", "圖像", "多模態":
        return .multimodal
      case "plugin", "mcp", "plugin-mcp", "plugin_mcp", "插件":
        return .pluginMCP
      case "writing", "communication", "文筆", "溝通":
        return .writing
      case "3d", "3d-modeling", "3d_modeling", "modeling-3d", "blender", "ue5", "ue5.8", "un5.8", "unreal", "3d建模", "建模":
        return .modeling3D
      default:
        return nil
      }
    }
    return mapped.isEmpty ? Array(Self.allCases) : uniquePreservingOrder(mapped)
  }

  private static func uniquePreservingOrder(_ values: [TatwoSandboxArenaID]) -> [TatwoSandboxArenaID] {
    var seen = Set<TatwoSandboxArenaID>()
    var result: [TatwoSandboxArenaID] = []
    for value in values where !seen.contains(value) {
      seen.insert(value)
      result.append(value)
    }
    return result
  }
}

public enum TatwoSandboxArenaModelStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case planned
  case skipped
  case scaffolded
}

public enum TatwoSandboxArenaReportStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case scaffolded
  case skipped
  case readyForGrading = "ready_for_grading"
  case invalidSubmission = "invalid_submission"
}

public struct TatwoSandboxArenaGoalStandard: Codable, Sendable, Equatable {
  public let schema: String
  public let mainlineProtocol: String
  public let branchProtocol: String
  public let maxGoalExecutionCycles: Int
  public let planRevisionLimit: String
  public let loopLedgerEntryLimit: String
  public let completionBoundary: String
  public let mainlineStages: [String]
  public let branchStages: [String]
  public let failClosedRules: [String]
  public let scoringRule: String

  public init(
    schema: String = "TatwoSandboxArenaGoalStandardV1",
    mainlineProtocol: String,
    branchProtocol: String,
    maxGoalExecutionCycles: Int,
    planRevisionLimit: String,
    loopLedgerEntryLimit: String,
    completionBoundary: String,
    mainlineStages: [String],
    branchStages: [String],
    failClosedRules: [String],
    scoringRule: String
  ) {
    self.schema = schema
    self.mainlineProtocol = mainlineProtocol
    self.branchProtocol = branchProtocol
    self.maxGoalExecutionCycles = maxGoalExecutionCycles
    self.planRevisionLimit = planRevisionLimit
    self.loopLedgerEntryLimit = loopLedgerEntryLimit
    self.completionBoundary = completionBoundary
    self.mainlineStages = mainlineStages
    self.branchStages = branchStages
    self.failClosedRules = failClosedRules
    self.scoringRule = scoringRule
  }
}

public struct TatwoSandboxArenaCaseTemplate: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let folderName: String
  public let title: String
  public let benchmarkPurpose: String
  public let measuredTraits: [String]
  public let scoringFocus: [String]
  public let requiredReceipts: [String]
  public let hiddenChecks: [String]
  public let protectedFiles: [String]
  public let prompt: String
}

public struct TatwoSandboxArenaDefinition: Codable, Sendable, Identifiable, Equatable {
  public var id: TatwoSandboxArenaID { arena }
  public let schema: String
  public let arena: TatwoSandboxArenaID
  public let title: String
  public let chineseTitle: String
  public let rootRelativePath: String
  public let goalStandard: TatwoSandboxArenaGoalStandard
  public let cases: [TatwoSandboxArenaCaseTemplate]
  public let localOnlyRules: [String]
  public let requiredModelFiles: [String]

  public init(
    schema: String = "TatwoSandboxArenaDefinitionV1",
    arena: TatwoSandboxArenaID,
    rootRelativePath: String,
    goalStandard: TatwoSandboxArenaGoalStandard,
    cases: [TatwoSandboxArenaCaseTemplate],
    localOnlyRules: [String],
    requiredModelFiles: [String]
  ) {
    self.schema = schema
    self.arena = arena
    self.title = arena.title
    self.chineseTitle = arena.chineseTitle
    self.rootRelativePath = rootRelativePath
    self.goalStandard = goalStandard
    self.cases = cases
    self.localOnlyRules = localOnlyRules
    self.requiredModelFiles = requiredModelFiles
  }
}

public struct TatwoSandboxArenaModelPlan: Codable, Sendable, Identifiable, Equatable {
  public var id: String { slug }
  public let slug: String
  public let displayName: String
  public let folderName: String
  public let status: TatwoSandboxArenaModelStatus
  public let statusReason: String
  public let relativeFolderPath: String
  public let requiredFiles: [String]
}

public struct TatwoSandboxArenaCasePlan: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let folderName: String
  public let title: String
  public let benchmarkPurpose: String
  public let measuredTraits: [String]
  public let scoringFocus: [String]
  public let requiredReceipts: [String]
  public let hiddenChecks: [String]
  public let protectedFiles: [String]
  public let prompt: String
  public let models: [TatwoSandboxArenaModelPlan]
}

public struct TatwoSandboxArenaPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let arena: TatwoSandboxArenaID
  public let title: String
  public let chineseTitle: String
  public let rootRelativePath: String
  public let runID: String
  public let cases: [TatwoSandboxArenaCasePlan]
  public let goalStandard: TatwoSandboxArenaGoalStandard
  public let goalCyclePolicy: TatwoArenaGoalCyclePolicy
  public let planLoopGoalProtocol: TatwoArenaPlanLoopGoalProtocol
  public let localOnlyRules: [String]
  public let runCommand: String
  public let reportCommand: String
  public let cleanupHint: String

  public init(
    schema: String = "TatwoSandboxArenaPlanV1",
    arena: TatwoSandboxArenaID,
    title: String,
    chineseTitle: String,
    rootRelativePath: String,
    runID: String,
    cases: [TatwoSandboxArenaCasePlan],
    goalStandard: TatwoSandboxArenaGoalStandard,
    goalCyclePolicy: TatwoArenaGoalCyclePolicy,
    planLoopGoalProtocol: TatwoArenaPlanLoopGoalProtocol,
    localOnlyRules: [String],
    runCommand: String,
    reportCommand: String,
    cleanupHint: String
  ) {
    self.schema = schema
    self.arena = arena
    self.title = title
    self.chineseTitle = chineseTitle
    self.rootRelativePath = rootRelativePath
    self.runID = runID
    self.cases = cases
    self.goalStandard = goalStandard
    self.goalCyclePolicy = goalCyclePolicy
    self.planLoopGoalProtocol = planLoopGoalProtocol
    self.localOnlyRules = localOnlyRules
    self.runCommand = runCommand
    self.reportCommand = reportCommand
    self.cleanupHint = cleanupHint
  }
}

public struct TatwoSandboxArenaRunReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let arena: TatwoSandboxArenaID
  public let runID: String
  public let rootRelativePath: String
  public let createdModelFolders: [String]
  public let modelFanoutExecuted: Bool
  public let hostMutationAllowed: Bool
  public let status: String
  public let notes: [String]

  public init(
    schema: String = "TatwoSandboxArenaRunReceiptV1",
    arena: TatwoSandboxArenaID,
    runID: String,
    rootRelativePath: String,
    createdModelFolders: [String],
    modelFanoutExecuted: Bool,
    hostMutationAllowed: Bool,
    status: String,
    notes: [String]
  ) {
    self.schema = schema
    self.arena = arena
    self.runID = runID
    self.rootRelativePath = rootRelativePath
    self.createdModelFolders = createdModelFolders
    self.modelFanoutExecuted = modelFanoutExecuted
    self.hostMutationAllowed = hostMutationAllowed
    self.status = status
    self.notes = notes
  }
}

public struct TatwoSandboxArenaEvaluationReport: Codable, Sendable, Equatable {
  public let schema: String
  public let arena: TatwoSandboxArenaID
  public let caseID: String
  public let modelSlug: String
  public let modelFolderName: String
  public let status: TatwoSandboxArenaReportStatus
  public let finalScore: Int
  public let goalCycleAssessment: TatwoArenaGoalCycleAssessment
  public let plgScore: TatwoArenaPlanLoopGoalScoreReport
  public let blockingReceipts: [String]
  public let requiredNotice: String
  public let notes: [String]

  public init(
    schema: String = "TatwoSandboxArenaEvaluationReportV1",
    arena: TatwoSandboxArenaID,
    caseID: String,
    modelSlug: String,
    modelFolderName: String,
    status: TatwoSandboxArenaReportStatus,
    finalScore: Int,
    goalCycleAssessment: TatwoArenaGoalCycleAssessment,
    plgScore: TatwoArenaPlanLoopGoalScoreReport,
    blockingReceipts: [String],
    requiredNotice: String,
    notes: [String]
  ) {
    self.schema = schema
    self.arena = arena
    self.caseID = caseID
    self.modelSlug = modelSlug
    self.modelFolderName = modelFolderName
    self.status = status
    self.finalScore = max(0, min(100, finalScore))
    self.goalCycleAssessment = goalCycleAssessment
    self.plgScore = plgScore
    self.blockingReceipts = blockingReceipts
    self.requiredNotice = requiredNotice
    self.notes = notes
  }
}

public struct TatwoSandboxArenaRunSummary: Codable, Sendable, Equatable {
  public let schema: String
  public let arena: TatwoSandboxArenaID
  public let runID: String
  public let rootRelativePath: String
  public let reportCount: Int
  public let missingReports: [String]
  public let reports: [TatwoSandboxArenaEvaluationReport]

  public init(
    schema: String = "TatwoSandboxArenaRunSummaryV1",
    arena: TatwoSandboxArenaID,
    runID: String,
    rootRelativePath: String,
    reportCount: Int,
    missingReports: [String],
    reports: [TatwoSandboxArenaEvaluationReport]
  ) {
    self.schema = schema
    self.arena = arena
    self.runID = runID
    self.rootRelativePath = rootRelativePath
    self.reportCount = reportCount
    self.missingReports = missingReports
    self.reports = reports
  }
}

public struct Tatwo3DModelingArenaCaseEvidence: Codable, Sendable, Identifiable, Equatable {
  public var id: String { caseID }
  public let caseID: String
  public let title: String
  public let score0To100: Int?
  public let status: String
  public let official: Bool
  public let receiptRelativePath: String
  public let note: String

  public init(
    caseID: String,
    title: String,
    score0To100: Int?,
    status: String,
    official: Bool,
    receiptRelativePath: String,
    note: String
  ) {
    self.caseID = caseID
    self.title = title
    self.score0To100 = score0To100.map { max(0, min(100, $0)) }
    self.status = status
    self.official = official
    self.receiptRelativePath = receiptRelativePath
    self.note = note
  }
}

public struct Tatwo3DModelingArenaModelEvidence: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let modelSlug: String
  public let displayName: String
  public let arena: String
  public let runID: String
  public let testedAt: String
  public let status: String
  public let canonicalScore0To100: Int?
  public let scoreStatusLabel: String
  public let evidenceRelativePath: String
  public let summaryRelativePath: String
  public let interpretation: String
  public let routingImplication: String
  public let limitations: [String]
  public let caseEvidence: [Tatwo3DModelingArenaCaseEvidence]
  /// Canonical mapping into the shared trait dimensions.
  /// Only deterministic/official receipts are mapped; assisted debug scores remain notes.
  public let traitDimensionEvidence: [TatwoWebArenaTraitDimensionEvidence]

  public init(
    id: String,
    modelSlug: String,
    displayName: String,
    arena: String,
    runID: String,
    testedAt: String,
    status: String,
    canonicalScore0To100: Int?,
    scoreStatusLabel: String,
    evidenceRelativePath: String,
    summaryRelativePath: String,
    interpretation: String,
    routingImplication: String,
    limitations: [String],
    caseEvidence: [Tatwo3DModelingArenaCaseEvidence],
    traitDimensionEvidence: [TatwoWebArenaTraitDimensionEvidence]
  ) {
    self.id = id
    self.modelSlug = modelSlug
    self.displayName = displayName
    self.arena = arena
    self.runID = runID
    self.testedAt = testedAt
    self.status = status
    self.canonicalScore0To100 = canonicalScore0To100.map { max(0, min(100, $0)) }
    self.scoreStatusLabel = scoreStatusLabel
    self.evidenceRelativePath = evidenceRelativePath
    self.summaryRelativePath = summaryRelativePath
    self.interpretation = interpretation
    self.routingImplication = routingImplication
    self.limitations = limitations
    self.caseEvidence = caseEvidence
    self.traitDimensionEvidence = traitDimensionEvidence
  }
}

public extension Tatwo3DModelingArenaModelEvidence {
  var hasOfficialExamScoreRecord: Bool {
    caseEvidence.contains { $0.official && $0.score0To100 != nil }
      || canonicalScore0To100 != nil
  }

  var examScoreSummaryLabel: String {
    guard let score = canonicalScore0To100 else { return "3D 考試紀錄缺" }
    return "3D 考試 \(score)/100"
  }

  var manualTraitScoreLabel: String {
    traitDimensionEvidence.isEmpty ? "+人工評分" : "人工評分 \(traitDimensionEvidence.count) 項"
  }

  var manualTraitScoreIsPending: Bool {
    traitDimensionEvidence.isEmpty
  }
}

public enum Tatwo3DModelingArenaFactory {
  public static let importedModelEvidence: [Tatwo3DModelingArenaModelEvidence] = [
    Tatwo3DModelingArenaModelEvidence(
      id: "gpt-5-4-blender-q1-20260702",
      modelSlug: "gpt-5.4",
      displayName: "GPT-5.4",
      arena: "3D Modeling Arena / Blender",
      runID: "20260702-gpt-5-4-blender-q1-xinjiang-360-cycle1-official",
      testedAt: "2026-07-02",
      status: "rollback_required",
      canonicalScore0To100: 52,
      scoreStatusLabel: "official 52/100 · rollback",
      evidenceRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-gpt-5-4-blender-q1-xinjiang-360-cycle1-official/01-VisionPro新疆360/GPT-5.4/評分報告.json",
      summaryRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-gpt-5-4-blender-q1-xinjiang-360-cycle1-official/summary.json",
      interpretation: "GPT-5.4 已跑 Blender Q1 正式考試，作品可計分但仍為 rollback_required；這不是通過，只是可作 3D 空間比例的初步證據。",
      routingImplication: "可放在 3D 規格/腳本草稿候選；不能當 3D final judge，也不能因 52 分直接進主導。",
      limitations: [
        "目前只採 Q1 Vision Pro 新疆 360；未完成 MMD 角色與 UE5.8 綜合測試。",
        "同模型較早的兩題 arena v1 提交缺必備 artifacts，官方分數為 0；本列採後續 Q1 official cycle1。",
        "Assisted retry / host 幫忙修補不計入正式盲測分數。"
      ],
      caseEvidence: [
        Tatwo3DModelingArenaCaseEvidence(
          caseID: "vision-pro-xinjiang-360",
          title: "Vision Pro 新疆 360",
          score0To100: 52,
          status: "rollback_required",
          official: true,
          receiptRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-gpt-5-4-blender-q1-xinjiang-360-cycle1-official/summary.json",
          note: "official case finalScore=52；仍需人工/視覺與完整 3D 套件驗收。")
      ],
      traitDimensionEvidence: [
        TatwoWebArenaTraitDimensionEvidence(
          dimensionID: "3d-modeling-spatial",
          dimensionTitle: "3D建模與空間比例",
          value0To10: 5.2,
          evidenceSource: "Blender Arena official Q1",
          status: "rollback_required",
          note: "Vision Pro 新疆 360 official finalScore=52/100；可計初步 3D 證據但未通過。")
      ]
    ),
    Tatwo3DModelingArenaModelEvidence(
      id: "sonnet-5-blender-q1-20260702",
      modelSlug: "sonnet-5",
      displayName: "Sonnet 5",
      arena: "3D Modeling Arena / Blender",
      runID: "20260702-sonnet-5-blender-q1-xinjiang-360-official-retest1",
      testedAt: "2026-07-02",
      status: "rollback_required",
      canonicalScore0To100: 0,
      scoreStatusLabel: "official 0/100 · invalid",
      evidenceRelativePath: ".tatwo-ultrawork/evidence/20260702-sonnet-5-blender-q1-xinjiang-360-official-retest1/05-grade-summary.json",
      summaryRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-sonnet-5-blender-q1-xinjiang-360-official-retest1/summary.json",
      interpretation: "Sonnet 5 已跑 Blender Q1 正式考試與正式重考，但官方嘗試缺 artifacts / PLG failed，正式分數維持 0。",
      routingImplication: "可保留為 3D debug repair / 工程修補候選；正式盲測 3D 建模不能升級，不能用 debug-assisted 成績取代官方 0。",
      limitations: [
        "debug-assisted retry 產出完整檔案且人工 provisional 81，但明確標記為非官方盲測分數。",
        "正式 official 與 official-retest1 均 rollback_required。",
        "未測 MMD 角色與 UE5.8。"
      ],
      caseEvidence: [
        Tatwo3DModelingArenaCaseEvidence(
          caseID: "vision-pro-xinjiang-360",
          title: "Vision Pro 新疆 360 official",
          score0To100: 0,
          status: "invalid_submission",
          official: true,
          receiptRelativePath: ".tatwo-ultrawork/evidence/20260702-sonnet-5-blender-q1-xinjiang-360-official-retest1/05-grade-summary.json",
          note: "official-retest1 missing artifacts / PLG failed；manualVisualPass=false。"),
        Tatwo3DModelingArenaCaseEvidence(
          caseID: "vision-pro-xinjiang-360-debug",
          title: "Debug assisted retry",
          score0To100: 81,
          status: "debug_repair_only",
          official: false,
          receiptRelativePath: ".tatwo-ultrawork/evidence/20260702-sonnet-5-blender-q1-xinjiang-360-debug-retest1/07-manual-visual-inspection.json",
          note: "debug repair passed structure/basic visual gate；不可作正式模型考試分。")
      ],
      traitDimensionEvidence: [
        TatwoWebArenaTraitDimensionEvidence(
          dimensionID: "3d-modeling-spatial",
          dimensionTitle: "3D建模與空間比例",
          value0To10: 0.0,
          evidenceSource: "Blender Arena official",
          status: "official-invalid",
          note: "正式 official / official-retest1 為 invalid_submission；debug-assisted 81 僅作修復證據，不映射正式分。")
      ]
    ),
    Tatwo3DModelingArenaModelEvidence(
      id: "fable-5-blender-q1-20260702",
      modelSlug: "fable-5",
      displayName: "Fable 5",
      arena: "3D Modeling Arena / Blender",
      runID: "20260702-fable-5-blender-q1-xinjiang-360-official",
      testedAt: "2026-07-02",
      status: "rollback_required",
      canonicalScore0To100: 0,
      scoreStatusLabel: "official 0/100 · invalid",
      evidenceRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-fable-5-blender-q1-xinjiang-360-official/summary.json",
      summaryRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-fable-5-blender-q1-xinjiang-360-official/summary.json",
      interpretation: "Fable 5 已跑 Blender Q1 official，但提交被判 invalid_submission，正式分數為 0；之後 debug/retest 不可掩蓋官方失敗。",
      routingImplication: "Fable 5 可作 3D 規格主導/考題設計與高階構想，但目前 3D 建模實作不能升主導或完工者。",
      limitations: [
        "官方考試為 0；debug retest 僅證明可修，不可替代官方盲測。",
        "成本高且可能撞額度，不應預設跑大量 3D fan-out。",
        "未測 MMD 角色與 UE5.8。"
      ],
      caseEvidence: [
        Tatwo3DModelingArenaCaseEvidence(
          caseID: "vision-pro-xinjiang-360",
          title: "Vision Pro 新疆 360 official",
          score0To100: 0,
          status: "invalid_submission",
          official: true,
          receiptRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-fable-5-blender-q1-xinjiang-360-official/summary.json",
          note: "official summary status=rollback_required；case invalid_submission，finalScore=0。"),
        Tatwo3DModelingArenaCaseEvidence(
          caseID: "vision-pro-xinjiang-360-debug",
          title: "Debug retest",
          score0To100: 55,
          status: "debug_repair_only",
          official: false,
          receiptRelativePath: ".tatwo-ultrawork/3D測試/模型/20260702-fable-5-blender-q1-xinjiang-360-retest1-debug/summary.json",
          note: "ready_for_manual_review / automaticScore=55；非官方盲測分。")
      ],
      traitDimensionEvidence: [
        TatwoWebArenaTraitDimensionEvidence(
          dimensionID: "3d-modeling-spatial",
          dimensionTitle: "3D建模與空間比例",
          value0To10: 0.0,
          evidenceSource: "Blender Arena official",
          status: "official-invalid",
          note: "官方 Q1 invalid_submission，正式 3D 分數為 0；debug retest 不取代考試。")
      ]
    )
  ]
}

public struct TatwoSandboxArenaCollectionPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let runID: String
  public let arenas: [TatwoSandboxArenaPlan]
  public let allSandboxTestsRequiredBeforePLGScore: Bool
  public let notes: [String]

  public init(
    schema: String = "TatwoSandboxArenaCollectionPlanV1",
    runID: String,
    arenas: [TatwoSandboxArenaPlan],
    allSandboxTestsRequiredBeforePLGScore: Bool = true,
    notes: [String]
  ) {
    self.schema = schema
    self.runID = runID
    self.arenas = arenas
    self.allSandboxTestsRequiredBeforePLGScore = allSandboxTestsRequiredBeforePLGScore
    self.notes = notes
  }
}

public struct TatwoSandboxArenaCollectionReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let runID: String
  public let receipts: [TatwoSandboxArenaRunReceipt]
  public let modelFanoutExecuted: Bool
  public let hostMutationAllowed: Bool
  public let notes: [String]

  public init(
    schema: String = "TatwoSandboxArenaCollectionReceiptV1",
    runID: String,
    receipts: [TatwoSandboxArenaRunReceipt],
    modelFanoutExecuted: Bool,
    hostMutationAllowed: Bool,
    notes: [String]
  ) {
    self.schema = schema
    self.runID = runID
    self.receipts = receipts
    self.modelFanoutExecuted = modelFanoutExecuted
    self.hostMutationAllowed = hostMutationAllowed
    self.notes = notes
  }
}

public enum TatwoSandboxArenaFactory {
  public static let defaultModelSlugs = [
    "gpt-5.5", "sonnet-5", "fable-5", "opus-5", "minimax-m3",
  ]

  public static let requiredModelFiles = [
    "prompt.md",
    "goal-contract.md",
    "plan.md",
    "loop-ledger.json",
    "mainline-decision.md",
    "branch-optimization-plan.md",
    "branch-loop-ledger.json",
    "tool-choice-ledger.json",
    "receipt-index.json",
    "model-output.md",
    "generated-artifacts/",
    "hidden-tests-manifest.json",
    "protected-files.json",
    "final-submission/seal.json",
    "build.log",
    "grader-report.json",
    "評分報告.json",
    "評分報告.md",
  ]

  public static func rootRelativePath(for arena: TatwoSandboxArenaID) -> String {
    ".tatwo-ultrawork/\(arena.folderName)"
  }

  public static func definitions() -> [TatwoSandboxArenaDefinition] {
    TatwoSandboxArenaID.allCases.map(definition)
  }

  public static func definition(_ arena: TatwoSandboxArenaID) -> TatwoSandboxArenaDefinition {
    TatwoSandboxArenaDefinition(
      arena: arena,
      rootRelativePath: rootRelativePath(for: arena),
      goalStandard: goalStandard(),
      cases: cases(for: arena),
      localOnlyRules: localOnlyRules(for: arena),
      requiredModelFiles: requiredModelFiles)
  }

  public static func plan(
    arena: TatwoSandboxArenaID,
    runID: String,
    models: [String] = defaultModelSlugs
  ) -> TatwoSandboxArenaPlan {
    let safeRunID = sanitizedRunID(runID)
    let normalizedModels = normalizeModels(models)
    let def = definition(arena)
    let cases = def.cases.map { template -> TatwoSandboxArenaCasePlan in
      let modelPlans = normalizedModels.map { model in
        modelPlan(slug: model, runID: safeRunID, arena: arena, caseFolderName: template.folderName)
      }
      return TatwoSandboxArenaCasePlan(
        id: template.id,
        folderName: template.folderName,
        title: template.title,
        benchmarkPurpose: template.benchmarkPurpose,
        measuredTraits: template.measuredTraits,
        scoringFocus: template.scoringFocus,
        requiredReceipts: template.requiredReceipts,
        hiddenChecks: template.hiddenChecks,
        protectedFiles: template.protectedFiles,
        prompt: template.prompt,
        models: modelPlans)
    }
    let modelArg = normalizedModels.joined(separator: ",")
    return TatwoSandboxArenaPlan(
      arena: arena,
      title: arena.title,
      chineseTitle: arena.chineseTitle,
      rootRelativePath: def.rootRelativePath,
      runID: safeRunID,
      cases: cases,
      goalStandard: def.goalStandard,
      goalCyclePolicy: TatwoArenaPolicyFactory.goalCyclePolicy,
      planLoopGoalProtocol: TatwoArenaPolicyFactory.planLoopGoalProtocol(),
      localOnlyRules: def.localOnlyRules,
      runCommand: "tatwo-ultrawork sandbox-arena run --arena \(arena.rawValue) --run \(safeRunID) --models \(modelArg) --json",
      reportCommand: "tatwo-ultrawork sandbox-arena report --arena \(arena.rawValue) --run \(safeRunID) --json",
      cleanupHint: "所有大型產物只在 \(def.rootRelativePath)/\(safeRunID)/；先 dry-run，不自動刪檔。")
  }

  public static func collectionPlan(
    arenas: [TatwoSandboxArenaID] = Array(TatwoSandboxArenaID.allCases),
    runID: String,
    models: [String] = defaultModelSlugs
  ) -> TatwoSandboxArenaCollectionPlan {
    let safeRunID = sanitizedRunID(runID)
    return TatwoSandboxArenaCollectionPlan(
      runID: safeRunID,
      arenas: arenas.map { plan(arena: $0, runID: safeRunID, models: models) },
      notes: [
        "Web Arena 已獨立存在；此 collection 補齊 code/debug/research/multimodal/plugin/writing/3d-modeling 評分沙盒。",
        "每個 arena instance 的 goal cycle 獨立計算；不可跨 arena 共用或互相消耗 5 次上限。",
        "只有所有 sandbox tests 完成後，才可評模型的 PLG discipline。",
      ])
  }

  public static func scaffoldRun(
    root: URL,
    arena: TatwoSandboxArenaID,
    runID: String,
    models: [String] = defaultModelSlugs
  ) throws -> TatwoSandboxArenaRunReceipt {
    let plan = plan(arena: arena, runID: runID, models: models)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var created: [String] = []

    for suiteCase in plan.cases {
      for model in suiteCase.models {
        let folder = root.appendingPathComponent(model.relativeFolderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: folder.appendingPathComponent("generated-artifacts", isDirectory: true),
          withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: folder.appendingPathComponent("final-submission", isDirectory: true),
          withIntermediateDirectories: true)

        try suiteCase.prompt.write(
          to: folder.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        try goalContractMarkdown(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("goal-contract.md"), atomically: true, encoding: .utf8)
        try planMarkdown(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try loopLedgerJSON(plan: plan, suiteCase: suiteCase, model: model, branch: false).write(
          to: folder.appendingPathComponent("loop-ledger.json"), atomically: true, encoding: .utf8)
        try mainlineDecisionMarkdown(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("mainline-decision.md"), atomically: true, encoding: .utf8)
        try branchOptimizationMarkdown(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("branch-optimization-plan.md"), atomically: true, encoding: .utf8)
        try loopLedgerJSON(plan: plan, suiteCase: suiteCase, model: model, branch: true).write(
          to: folder.appendingPathComponent("branch-loop-ledger.json"), atomically: true, encoding: .utf8)
        try toolChoiceLedgerJSON(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("tool-choice-ledger.json"), atomically: true, encoding: .utf8)
        try receiptIndexJSON(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("receipt-index.json"), atomically: true, encoding: .utf8)
        try modelOutputMarkdown(model: model).write(
          to: folder.appendingPathComponent("model-output.md"), atomically: true, encoding: .utf8)
        try hiddenTestsManifestJSON(plan: plan, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("hidden-tests-manifest.json"), atomically: true, encoding: .utf8)
        try protectedFilesJSON(plan: plan, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("protected-files.json"), atomically: true, encoding: .utf8)
        try sealJSON(plan: plan, suiteCase: suiteCase, model: model, sealed: false).write(
          to: folder.appendingPathComponent("final-submission/seal.json"), atomically: true, encoding: .utf8)
        try buildLog(plan: plan, model: model).write(
          to: folder.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
        try graderReportJSON(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("grader-report.json"), atomically: true, encoding: .utf8)
        try generatedArtifactsReadme(plan: plan, suiteCase: suiteCase, model: model).write(
          to: folder.appendingPathComponent("generated-artifacts/README.md"), atomically: true, encoding: .utf8)
        try createArenaSpecificArtifactScaffold(folder: folder, plan: plan, suiteCase: suiteCase, model: model)

        let report = scaffoldReport(plan: plan, suiteCase: suiteCase, model: model)
        try encoder.encode(report).write(to: folder.appendingPathComponent("評分報告.json"), options: .atomic)
        try reportMarkdown(report).write(
          to: folder.appendingPathComponent("評分報告.md"), atomically: true, encoding: .utf8)
        created.append(model.relativeFolderPath)
      }
    }
    _ = try writeRunSummaryArtifacts(root: root, arena: arena, runID: plan.runID)

    return TatwoSandboxArenaRunReceipt(
      arena: arena,
      runID: plan.runID,
      rootRelativePath: plan.rootRelativePath,
      createdModelFolders: created,
      modelFanoutExecuted: false,
      hostMutationAllowed: false,
      status: "scaffolded",
      notes: [
        "created fixed folder/file scaffold for \(arena.title)",
        "no paid/API model fan-out executed",
        "all model folders include PLG mainline/branch artifacts, hidden-tests manifest, protected-file audit, and seal placeholder",
        "actual model output must be sealed before grading; scaffold reports are not tested evidence",
      ])
  }

  public static func scaffoldCollection(
    root: URL,
    arenas: [TatwoSandboxArenaID] = Array(TatwoSandboxArenaID.allCases),
    runID: String,
    models: [String] = defaultModelSlugs
  ) throws -> TatwoSandboxArenaCollectionReceipt {
    let safeRunID = sanitizedRunID(runID)
    let receipts = try arenas.map {
      try scaffoldRun(root: root, arena: $0, runID: safeRunID, models: models)
    }
    return TatwoSandboxArenaCollectionReceipt(
      runID: safeRunID,
      receipts: receipts,
      modelFanoutExecuted: false,
      hostMutationAllowed: false,
      notes: [
        "all missing sandbox arena scaffolds created",
        "Web Arena remains separate under .tatwo-ultrawork/網頁設計沙盒/",
        "PLG score must wait for all selected arenas plus Web Arena if included in the benchmark batch",
      ])
  }

  public static func runSummary(
    root: URL,
    arena: TatwoSandboxArenaID,
    runID: String
  ) throws -> TatwoSandboxArenaRunSummary {
    let safeRunID = sanitizedRunID(runID)
    let plan = plan(arena: arena, runID: safeRunID, models: defaultModelSlugs)
    let decoder = JSONDecoder()
    var reports: [TatwoSandboxArenaEvaluationReport] = []
    var missing: [String] = []

    for suiteCase in plan.cases {
      let caseRoot = root.appendingPathComponent(plan.rootRelativePath, isDirectory: true)
        .appendingPathComponent(safeRunID, isDirectory: true)
        .appendingPathComponent(suiteCase.folderName, isDirectory: true)
      let modelFolders =
        (try? FileManager.default.contentsOfDirectory(
          at: caseRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
      for modelFolder in modelFolders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let isDir = (try? modelFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard isDir else { continue }
        let reportURL = modelFolder.appendingPathComponent("評分報告.json")
        if let data = try? Data(contentsOf: reportURL),
          let report = try? decoder.decode(TatwoSandboxArenaEvaluationReport.self, from: data)
        {
          reports.append(report)
        } else {
          missing.append("\(suiteCase.folderName)/\(modelFolder.lastPathComponent)/評分報告.json")
        }
      }
    }

    return TatwoSandboxArenaRunSummary(
      arena: arena,
      runID: safeRunID,
      rootRelativePath: plan.rootRelativePath,
      reportCount: reports.count,
      missingReports: missing.sorted(),
      reports: reports.sorted { lhs, rhs in
        if lhs.caseID == rhs.caseID { return lhs.modelFolderName < rhs.modelFolderName }
        return lhs.caseID < rhs.caseID
      })
  }

  @discardableResult
  public static func writeRunSummaryArtifacts(
    root: URL,
    arena: TatwoSandboxArenaID,
    runID: String
  ) throws -> TatwoSandboxArenaRunSummary {
    let summary = try runSummary(root: root, arena: arena, runID: runID)
    let runRoot = root.appendingPathComponent(summary.rootRelativePath, isDirectory: true)
      .appendingPathComponent(summary.runID, isDirectory: true)
    try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(summary).write(to: runRoot.appendingPathComponent("summary.json"), options: .atomic)
    try runSummaryMarkdown(summary).write(
      to: runRoot.appendingPathComponent("總評分報告.md"), atomically: true, encoding: .utf8)
    return summary
  }

  public static func normalizeModels(_ models: [String]) -> [String] {
    let expanded = models.flatMap { raw -> [String] in
      raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let normalized = expanded.map(normalizedModelSlug).filter { !$0.isEmpty }
    let unique = uniquePreservingOrder(normalized)
    return unique.isEmpty ? defaultModelSlugs : unique
  }

  public static func sanitizedRunID(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? defaultRunID() : trimmed
    let safe = base.map { ch -> Character in
      if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." { return ch }
      return "-"
    }
    var final = String(safe)
    while final.contains("..") {
      final = final.replacingOccurrences(of: "..", with: ".")
    }
    while final.contains("--") {
      final = final.replacingOccurrences(of: "--", with: "-")
    }
    final = final.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    if final.count > 80 { final = String(final.prefix(80)) }
    return final.isEmpty ? defaultRunID() : final
  }

  public static func defaultRunID(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return "\(formatter.string(from: now))-sandbox-arena-v1"
  }

  private static func uniquePreservingOrder<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    var result: [T] = []
    for value in values where !seen.contains(value) {
      seen.insert(value)
      result.append(value)
    }
    return result
  }

  private static func goalStandard() -> TatwoSandboxArenaGoalStandard {
    let policy = TatwoArenaPolicyFactory.goalCyclePolicy
    let protocolSpec = TatwoArenaPolicyFactory.planLoopGoalProtocol()
    return TatwoSandboxArenaGoalStandard(
      mainlineProtocol: protocolSpec.mainlineName,
      branchProtocol: protocolSpec.branchName,
      maxGoalExecutionCycles: policy.maxGoalExecutionCycles,
      planRevisionLimit: policy.planRevisionLimit,
      loopLedgerEntryLimit: policy.loopLedgerEntryLimit,
      completionBoundary: "所有 required receipts、hidden checks、protected-file audit、seal 與 report 都存在後，才可標記該 sandbox case ready_for_grading。",
      mainlineStages: [
        "goal-contract：鎖定任務、模型、arena、case、預算與 forbidden mutations",
        "plan：模型先規劃，不得直接改檔",
        "loop-ledger：每次實作巡迴記錄目標、工具、輸出、驗證與是否消耗 5 次上限",
        "mainline-decision：主線判斷繼續、rollback、封存或進評分",
        "final-submission/seal：封存 hash；sealed 後任何改動 invalid_submission",
      ],
      branchStages: [
        "branch-optimization-plan：支線優化假設與預期收益",
        "branch-loop-ledger：支線每輪證據與回主線原因",
        "tool-choice-ledger：模型自選 MCP / skills，但只能選 registry 內工具",
        "receipt-index：所有測試、截圖、hidden check、review、sandbox receipt 的索引",
      ],
      failClosedRules: [
        "沒有 contractID / seal / receipt-index 不評分。",
        "goalExecutionCycles > 5 或 sealed 後 hash 變更直接 invalid_submission。",
        "模型自評不能通過；必須有 deterministic receipt。",
        "未登記工具、改 hidden tests、改 protected files、偽造 receipt 都不算通過。",
        "PLG 分數必須等所有 sandbox tests 完成後才計算。",
        "3D 工具沙盒中的 Blender / UE5.8 是 optional verifier；未明確授權不可自動啟動外接硬碟工具。",
      ],
      scoringRule: "PLG 是獨立分數；不取代 build、hidden tests、debug reproduction、source verification、image evidence 或 writing reviewer receipts。")
  }

  private static func localOnlyRules(for arena: TatwoSandboxArenaID) -> [String] {
    [
      "所有 \(arena.chineseTitle) 產物只放在 \(rootRelativePath(for: arena))/，方便整批刪除。",
      "run/scaffold 不會自動呼叫付費/API 模型 fan-out。",
      "每個 arena instance 的 5 次 goal 實作上限獨立計算，不跨 arena 污染。",
      "模型可自選 MCP / skills，但只允許 Ultrawork registry 內工具，並必須寫入 tool-choice-ledger。",
      "hidden checks、protected-files、grader 與 seal 都不可被受測模型修改。",
      "所有測試完成前，不可對模型的 PLG discipline 打分。",
    ] + (arena == .modeling3D ? [
      "Blender 與 UE5.8 作品只放在 generated-artifacts/作品/Blender 與 generated-artifacts/作品/UE5.8。",
      "找不到外接硬碟、Blender、UE5.8 或 MCP 時只能標記 degraded，不可讓整個 Tatwo 崩潰。",
      "預設不開 Blender/UE5.8；只有使用者明確要求 3D 實測時才啟動。",
    ] : [])
  }

  private static func cases(for arena: TatwoSandboxArenaID) -> [TatwoSandboxArenaCaseTemplate] {
    switch arena {
    case .codeArchitecture:
      return [
        template(
          id: "feature-add",
          folderName: "01-功能新增",
          title: "Feature Add",
          purpose: "測模型能不能在既有架構裡新增功能，不破壞邊界。",
          traits: ["代碼架構工整", "代碼語法一致性", "任務宏觀架構理解", "指令遵循強度"],
          focus: ["入口點理解", "模組邊界", "最小 diff", "測試新增", "不破壞原功能"],
          receipts: ["build", "unit-tests", "hidden-tests", "protected-file-audit", "diff-summary"],
          hidden: ["hidden behavior test", "public API compatibility", "no snapshot-only cheat"],
          protected: ["Tests/Hidden/**", "Package.swift unless task asks", "grader/**"],
          promptBody: "在 starter project 中新增指定功能。必須先提交 plan，再最多 5 次實作巡迴，最後封存。"),
        template(
          id: "refactor-boundary",
          folderName: "02-重構邊界",
          title: "Refactor Boundary",
          purpose: "測模型是否能把混亂 code 重構成清楚分層，而不是只改到能跑。",
          traits: ["代碼架構工整", "自我修正", "穩定性", "第一性原理思考"],
          focus: ["責任分離", "命名一致", "重構不改行為", "回歸測試"],
          receipts: ["before-tests", "after-tests", "architecture-note", "hidden-regression-test"],
          hidden: ["behavior parity", "mutation trap", "public output hash"],
          protected: ["fixtures/**", "hidden-tests/**", "grading-rubric.json"],
          promptBody: "重構混亂但可運作的 code。不得改輸出契約，不得改 hidden tests。"),
        template(
          id: "mcp-plugin-adapter",
          folderName: "03-MCP插件Adapter",
          title: "MCP / Plugin Adapter",
          purpose: "測模型能不能建立 adapter、schema、錯誤處理與安全邊界。",
          traits: ["外部插件適配", "多模協作能力", "穩定性", "指令遵循強度"],
          focus: ["schema version", "fail-closed", "redaction", "registry tool allowlist"],
          receipts: ["schema-test", "negative-test", "redaction-test", "adapter-smoke"],
          hidden: ["invalid schema trap", "secret redaction fixture", "unknown-tool denial"],
          protected: ["mcp-schema.lock", "secrets.fixture", "hidden-tests/**"],
          promptBody: "建立一個安全 adapter。未知 tool/schema 版本不符時必須 fail closed。"),
      ]
    case .debug:
      return [
        template(
          id: "failing-test-repair",
          folderName: "01-失敗測試修復",
          title: "Failing Test Repair",
          purpose: "測模型是否先重現錯誤，再做最小修復。",
          traits: ["Debug", "自我修正", "穩定性", "指令遵循強度"],
          focus: ["reproduction receipt", "root cause", "minimal patch", "regression test"],
          receipts: ["reproduction-log", "root-cause-note", "test-pass", "hidden-regression-test"],
          hidden: ["same failure with altered fixture", "test mutation audit"],
          protected: ["Tests/Failing/**", "Tests/Hidden/**", "fixtures/**"],
          promptBody: "先產生 reproduction receipt；沒有重現不得修。最多 5 次實作巡迴。"),
        template(
          id: "runtime-error-repair",
          folderName: "02-Runtime錯誤修復",
          title: "Runtime Error Repair",
          purpose: "測模型能不能從 log/console 找真因，而不是亂猜。",
          traits: ["Debug", "上下文", "自我修正", "穩定性"],
          focus: ["log triage", "stack trace", "small fix", "smoke run"],
          receipts: ["runtime-repro", "stack-trace-note", "smoke-pass", "no-new-error"],
          hidden: ["alternate runtime trigger", "crash loop detection"],
          protected: ["runtime-fixtures/**", "hidden-tests/**", "grader/**"],
          promptBody: "修復 runtime error。必須保留原始錯誤證據與修復後 smoke receipt。"),
        template(
          id: "regression-trap",
          folderName: "03-回歸陷阱",
          title: "Regression Trap",
          purpose: "測模型是否會為了修 A 破壞 B。",
          traits: ["穩定性", "多意見整合", "自我修正", "任務宏觀架構理解"],
          focus: ["multi-test strategy", "side-effect audit", "rollback readiness"],
          receipts: ["target-test-pass", "regression-suite-pass", "rollback-note", "protected-file-audit"],
          hidden: ["non-target feature parity", "negative input trap"],
          protected: ["regression-fixtures/**", "hidden-tests/**"],
          promptBody: "修復指定 bug，同時避免破壞非目標功能。hidden test 會檢查回歸。"),
      ]
    case .research:
      return [
        template(
          id: "official-source-check",
          folderName: "01-官方來源查證",
          title: "Official Source Check",
          purpose: "測模型是否以官方/一手來源建立 claim/evidence 表。",
          traits: ["幻覺度", "整合資訊與預判能力", "獨立思考與客觀堅持", "上下文"],
          focus: ["source quality", "claim status", "unsupported claim handling", "date correctness"],
          receipts: ["source-ledger", "claim-evidence-table", "unsupported-claims", "citation-check"],
          hidden: ["planted outdated source", "quote length check"],
          protected: ["source-fixtures/**", "grader/**"],
          promptBody: "回答研究問題。每個 claim 必須標記 supported / disputed / unsupported。"),
        template(
          id: "version-drift-check",
          folderName: "02-版本變動查證",
          title: "Version Drift Check",
          purpose: "測模型是否知道資料可能過期並主動查證。",
          traits: ["整合資訊與預判能力", "幻覺度", "任務宏觀架構理解", "指令遵循強度"],
          focus: ["freshness", "date clarity", "primary source priority", "uncertainty"],
          receipts: ["freshness-ledger", "dated-summary", "rebuttal-notes", "next-test"],
          hidden: ["changed API trap", "stale doc trap"],
          protected: ["reference-clock.json", "hidden-fixtures/**"],
          promptBody: "處理可能變動的技術/產品資訊。必須使用具體日期，不可假裝最新。"),
        template(
          id: "conflict-resolution",
          folderName: "03-來源衝突判斷",
          title: "Conflict Resolution",
          purpose: "測模型面對互相衝突來源時是否能客觀裁決。",
          traits: ["獨立思考與客觀堅持", "多意見整合", "第一性原理思考", "文筆"],
          focus: ["source ranking", "conflict table", "decision boundary", "rebuttal"],
          receipts: ["conflict-matrix", "source-rank", "decision-note", "confidence-note"],
          hidden: ["biased source", "ambiguous claim"],
          protected: ["source-pack/**", "grader/**"],
          promptBody: "整理衝突來源，不可只挑自己喜歡的證據。"),
      ]
    case .multimodal:
      return [
        template(
          id: "ui-screenshot-diagnosis",
          folderName: "01-UI截圖診斷",
          title: "UI Screenshot Diagnosis",
          purpose: "測模型是否能從截圖抓出明顯 UI/UJ 問題。",
          traits: ["多模態水準", "美感", "指令遵循強度", "自我修正"],
          focus: ["visual observation", "layout issue", "prioritized fixes", "no hallucinated elements"],
          receipts: ["image-observation-table", "issue-list", "fix-priority", "visual-proof"],
          hidden: ["missing obvious bug", "hallucinated UI element"],
          protected: ["image-fixtures/**", "expected-observations.json"],
          promptBody: "看圖診斷 UI。必須列出看見的證據，不可猜不存在元素。"),
        template(
          id: "chart-structure-extraction",
          folderName: "02-圖表結構抽取",
          title: "Chart Structure Extraction",
          purpose: "測模型能否把圖表轉成結構化資料與合理解讀。",
          traits: ["多模態水準", "整合資訊與預判能力", "幻覺度", "上下文"],
          focus: ["axis/legend", "data extraction", "uncertainty", "summary accuracy"],
          receipts: ["structured-output", "uncertainty-note", "chart-summary", "error-bound"],
          hidden: ["axis inversion trap", "legend mismatch"],
          protected: ["chart-fixtures/**", "grader/**"],
          promptBody: "抽取圖表資訊。看不清楚要標不確定，不可硬編數字。"),
        template(
          id: "image-to-spec",
          folderName: "03-圖片轉需求規格",
          title: "Image to Spec",
          purpose: "測模型能否把圖片變成可交付給工程/設計的規格。",
          traits: ["多模態水準", "任務宏觀架構理解", "美感", "代碼架構工整"],
          focus: ["component inventory", "state/spec mapping", "responsive notes", "acceptance criteria"],
          receipts: ["component-spec", "state-map", "acceptance-criteria", "unknowns"],
          hidden: ["missing state", "over-specified guess"],
          protected: ["image-fixtures/**", "spec-rubric.json"],
          promptBody: "把圖像轉成規格。需包含元件、狀態、互動、驗收標準。"),
      ]
    case .pluginMCP:
      return [
        template(
          id: "tool-selection",
          folderName: "01-工具選擇",
          title: "Tool Selection",
          purpose: "測模型是否會從 Ultrawork registry 選對 MCP / skills。",
          traits: ["外部插件適配", "多模協作能力", "指令遵循強度", "穩定性"],
          focus: ["registry allowlist", "why this tool", "no tool overuse", "fallback"],
          receipts: ["tool-choice-ledger", "registry-check", "fallback-note", "tool-risk-note"],
          hidden: ["unregistered tool injection", "unnecessary tool call"],
          protected: ["registry.lock.json", "hidden-tool-traps/**"],
          promptBody: "根據任務自行選工具，但只能使用 registry 中工具；每次選擇都要說明目的與風險。"),
        template(
          id: "receipt-validation",
          folderName: "02-收據驗證",
          title: "Receipt Validation",
          purpose: "測模型能不能辨認真的 receipt 與偽造/不充分 receipt。",
          traits: ["穩定性", "多模協作能力", "幻覺度", "第一性原理思考"],
          focus: ["receipt class", "evidence hash", "host observation", "model text rejection"],
          receipts: ["receipt-index", "forged-receipt-rejection", "hash-check", "decision-note"],
          hidden: ["model-text-only receipt", "stale receipt", "wrong origin"],
          protected: ["receipt-fixtures/**", "grader/**"],
          promptBody: "審查一組 receipts。模型說 approve 不算 receipt，必須驗 origin/hash/class。"),
        template(
          id: "fail-closed-schema",
          folderName: "03-FailClosedSchema",
          title: "Fail-Closed Schema",
          purpose: "測模型是否會在 schema/version/contractID 不符時拒絕執行。",
          traits: ["外部插件適配", "穩定性", "指令遵循強度", "自我修正"],
          focus: ["schema version", "contractID required", "unknown field", "safe error"],
          receipts: ["schema-test", "contract-test", "negative-test", "redaction-check"],
          hidden: ["missing contractID", "old schema", "secret-bearing error"],
          protected: ["schema-fixtures/**", "secrets.fixture"],
          promptBody: "處理 MCP tool payload。缺 contractID 或 schema 不符時必須 fail closed。"),
      ]
    case .modeling3D:
      return [
        template(
          id: "modeling-spec",
          folderName: "01-3D模型規格",
          title: "3D Model Spec",
          purpose: "測模型能不能把需求轉成可建模的輪廓、比例、材質、用途與負面約束。",
          traits: ["3D建模與空間比例", "任務宏觀架構理解", "美感", "指令遵循強度"],
          focus: ["主輪廓", "量感分佈", "關鍵結構", "材質邊界", "用途限制"],
          receipts: ["3d-spec", "shape-checklist", "material-note", "negative-constraints", "scale-note"],
          hidden: ["ambiguous shape trap", "scale mismatch", "over-decorated prompt"],
          protected: ["reference-scale.json", "hidden-checks/**", "grader/**"],
          promptBody: "先做 3D 模型規格，不開 Blender/UE。必須把抽象需求落到輪廓、比例、結構、材質與用途限制。"),
        template(
          id: "blender-workpiece",
          folderName: "02-Blender作品評分",
          title: "Blender Workpiece",
          purpose: "測模型在 Blender MCP 沙盒中產生或修正模型的能力；作品存入 generated-artifacts/作品/Blender。",
          traits: ["3D建模與空間比例", "外部插件適配", "自我修正", "穩定性"],
          focus: ["mesh exists", "object naming", "scale", "materials", "screenshots", "export manifest"],
          receipts: ["blender-artifact-index", "blend-or-export-file", "viewport-screenshot", "mesh-metrics", "export-manifest"],
          hidden: ["empty scene trap", "wrong unit scale", "missing screenshot", "non-exportable mesh"],
          protected: ["Blender/grader/**", "reference-scale.json", "hidden-checks/**"],
          promptBody: "只有使用者明確授權時才啟動 Blender MCP。作品、截圖、匯出與評分報告必須放入 generated-artifacts/作品/Blender。"),
        template(
          id: "ue58-integration",
          folderName: "03-UE5.8作品驗收",
          title: "UE5.8 Integration",
          purpose: "測 Blender 產物進 UE5.8 後是否能匯入、擺放、材質/碰撞/比例正常；作品存入 generated-artifacts/作品/UE5.8。",
          traits: ["外部插件適配", "工程穩定性", "多模協作能力", "整合資訊與預判能力"],
          focus: ["import manifest", "scene placement", "material parity", "collision", "camera/light smoke", "degraded fallback"],
          receipts: ["ue5-import-manifest", "scene-screenshot", "scale-collision-check", "material-check", "engine-degraded-note"],
          hidden: ["missing import", "broken material", "wrong scale", "no degraded note when UE unavailable"],
          protected: ["UE5.8/grader/**", "project-settings.lock", "hidden-checks/**"],
          promptBody: "只有使用者明確授權時才啟動 UE5.8 MCP。不可做真部署；匯入、場景、截圖與評分資料放入 generated-artifacts/作品/UE5.8。"),
      ]
    case .writing:
      return [
        template(
          id: "plain-explanation",
          folderName: "01-白話說明",
          title: "Plain Explanation",
          purpose: "測模型能不能把複雜架構講到使用者看得懂。",
          traits: ["文筆", "圓融度", "上下文", "指令遵循強度"],
          focus: ["low jargon", "accurate simplification", "actionable summary", "no patronizing tone"],
          receipts: ["draft", "readability-review", "user-intent-map", "revision-loop"],
          hidden: ["jargon overload", "wrong simplification"],
          protected: ["brief.md", "rubric.json"],
          promptBody: "把複雜技術規劃用白話說明，不可偷換意思。"),
        template(
          id: "structured-comparison",
          folderName: "02-條理比較",
          title: "Structured Comparison",
          purpose: "測模型能不能把多方案差異清楚分段比較。",
          traits: ["文筆", "多意見整合", "整合資訊與預判能力", "任務宏觀架構理解"],
          focus: ["decision matrix", "trade-off", "clear recommendation", "risk"],
          receipts: ["comparison-table", "recommendation", "risk-note", "counterargument"],
          hidden: ["false equivalence", "missing trade-off"],
          protected: ["comparison-brief.md", "grader/**"],
          promptBody: "比較多方案。必須分清楚優點、短板、風險、何時選誰。"),
        template(
          id: "correction-response",
          folderName: "03-修正回應",
          title: "Correction Response",
          purpose: "測模型被使用者糾正時是否能收斂、承認問題並修正。",
          traits: ["圓融度", "自我修正", "指令遵循強度", "文筆"],
          focus: ["acknowledge", "no excuse", "clear fix", "concise status"],
          receipts: ["before-after", "correction-map", "final-answer", "tone-review"],
          hidden: ["defensive answer", "irrelevant explanation"],
          protected: ["conversation-fixture.md", "tone-rubric.json"],
          promptBody: "使用者指出錯誤後，需簡潔承認、修正、回報證據，不可辯解或灌水。"),
      ]
    }
  }

  private static func template(
    id: String,
    folderName: String,
    title: String,
    purpose: String,
    traits: [String],
    focus: [String],
    receipts: [String],
    hidden: [String],
    protected: [String],
    promptBody: String
  ) -> TatwoSandboxArenaCaseTemplate {
    TatwoSandboxArenaCaseTemplate(
      id: id,
      folderName: folderName,
      title: title,
      benchmarkPurpose: purpose,
      measuredTraits: traits,
      scoringFocus: focus,
      requiredReceipts: receipts,
      hiddenChecks: hidden,
      protectedFiles: protected,
      prompt: """
        # TATWO Sandbox Arena v1 / \(title)

        \(purpose)

        ## Task
        \(promptBody)

        ## Required discipline
        - Follow `plan+loops+goal-主線`.
        - Follow `plan+loops+goal-支線優化`.
        - Maximum 5 implementation / execution cycles per goal.
        - Plan and loop-ledger entries are unlimited, but they do not reset the 5-cycle cap.
        - Choose MCP / skills yourself only from the Ultrawork registry and write every choice into `tool-choice-ledger.json`.
        - Seal final submission before grading. After seal, do not patch.
        - Do not modify hidden checks, protected files, grader, or seal.
        """)
  }

  private static func modelPlan(
    slug: String,
    runID: String,
    arena: TatwoSandboxArenaID,
    caseFolderName: String
  ) -> TatwoSandboxArenaModelPlan {
    let normalized = normalizedModelSlug(slug)
    let unavailable = isUnavailableModelRoute(normalized)
    let status: TatwoSandboxArenaModelStatus = unavailable ? .skipped : .planned
    let reason = unavailable
      ? "route unavailable / skipped until Fable 5 is configured"
      : "planned; no model fan-out executed by scaffold"
    let folder = folderName(for: normalized)
    return TatwoSandboxArenaModelPlan(
      slug: normalized,
      displayName: displayName(for: normalized),
      folderName: folder,
      status: status,
      statusReason: reason,
      relativeFolderPath: "\(rootRelativePath(for: arena))/\(runID)/\(caseFolderName)/\(folder)",
      requiredFiles: requiredModelFiles)
  }

  private static func scaffoldReport(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> TatwoSandboxArenaEvaluationReport {
    let sealed = false
    let cycle = TatwoArenaPolicyFactory.assessGoalCycle(
      goalExecutionCycles: 0,
      finalSubmissionSealed: sealed)
    let plg = TatwoArenaPolicyFactory.scorePlanLoopGoal(
      modelSlug: model.slug,
      expectedSandboxTests: plan.cases.count,
      completedSandboxTests: 0,
      goalExecutionCycles: 0,
      finalSubmissionSealed: sealed,
      presentArtifacts: requiredModelFiles,
      toolChoicesAllRegistered: true)
    let skipped = model.status == .skipped
    return TatwoSandboxArenaEvaluationReport(
      arena: plan.arena,
      caseID: suiteCase.id,
      modelSlug: model.slug,
      modelFolderName: model.folderName,
      status: skipped ? .skipped : .scaffolded,
      finalScore: 0,
      goalCycleAssessment: cycle,
      plgScore: plg,
      blockingReceipts: skipped ? [] : suiteCase.requiredReceipts,
      requiredNotice: skipped
        ? "skipped: \(model.statusReason)"
        : "scaffold only: not model-tested evidence; required receipts pending",
      notes: [
        "modelFanoutExecuted=false",
        "hostMutationAllowed=false",
        "PLG score is blocked until all sandbox tests complete and final submission is sealed or capped",
      ])
  }

  private static func normalizedModelSlug(_ raw: String) -> String {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    if normalized == "fable5" { return "fable-5" }
    if ["opus5", "opus-5", "claude-opus-5", "opus"].contains(normalized) {
      return "opus-5"
    }
    return normalized
  }

  private static func isUnavailableModelRoute(_ slug: String) -> Bool {
    let normalized = normalizedModelSlug(slug)
    return normalized.hasPrefix("fable-5-")
  }

  private static func displayName(for slug: String) -> String {
    switch normalizedModelSlug(slug) {
    case "gpt-5.5": return "GPT-5.5"
    case "sonnet-5": return "Claude Sonnet 5"
    case "fable-5": return "Fable 5"
    case "opus-5": return "Claude Opus 5"
    case "minimax-m3": return "MiniMax M3"
    default: return slug
    }
  }

  private static func folderName(for slug: String) -> String {
    switch normalizedModelSlug(slug) {
    case "gpt-5.5": return "GPT5.5"
    case "sonnet-5": return "SONNET5"
    case "fable-5": return "FABLE5"
    case "opus-5": return "OPUS5"
    case "minimax-m3": return "MINIMAX-M3"
    default:
      let safe = normalizedModelSlug(slug).uppercased().map { ch -> Character in
        if ch.isLetter || ch.isNumber || ch == "-" || ch == "." { return ch }
        return "-"
      }
      return String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }
  }

  private static func jsonString(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }

  private static func goalContractMarkdown(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    """
    # Goal Contract

    - schema: TatwoSandboxArenaGoalContractV1
    - arena: \(plan.arena.rawValue)
    - case: \(suiteCase.id)
    - model: \(model.slug)
    - runID: \(plan.runID)
    - protocol: \(plan.goalStandard.mainlineProtocol)
    - maxGoalExecutionCycles: \(plan.goalStandard.maxGoalExecutionCycles)
    - registryOnlyTools: true
    - hostMutationAllowed: false
    - modelFanoutExecutedByScaffold: false

    Goal: complete this arena case, seal final submission, then enter grading.
    """
  }

  private static func planMarkdown(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    """
    # Plan

    Model \(model.displayName) must produce the real plan before implementation.

    Required stages:
    \(plan.goalStandard.mainlineStages.map { "- \($0)" }.joined(separator: "\n"))

    Required receipts:
    \(suiteCase.requiredReceipts.map { "- \($0)" }.joined(separator: "\n"))
    """
  }

  private static func loopLedgerJSON(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan,
    branch: Bool
  ) -> String {
    jsonString([
      "schema": branch ? "TatwoSandboxArenaBranchLoopLedgerV1" : "TatwoSandboxArenaMainlineLoopLedgerV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "model": model.slug,
      "protocol": branch ? plan.goalStandard.branchProtocol : plan.goalStandard.mainlineProtocol,
      "maxGoalExecutionCycles": plan.goalStandard.maxGoalExecutionCycles,
      "planRevisionLimit": plan.goalStandard.planRevisionLimit,
      "loopLedgerEntryLimit": plan.goalStandard.loopLedgerEntryLimit,
      "entries": [],
      "note": "Scaffold placeholder. Real model loops must append entries; implementation cycles max out at 5.",
    ])
  }

  private static func mainlineDecisionMarkdown(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    """
    # Mainline Decision

    - arena: \(plan.arena.rawValue)
    - case: \(suiteCase.id)
    - model: \(model.slug)
    - currentDecision: scaffold_pending
    - reason: real model output not sealed yet
    """
  }

  private static func branchOptimizationMarkdown(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    """
    # Branch Optimization Plan

    Branch loops are optional but must be recorded when used.
    Model: \(model.displayName)
    Arena: \(plan.arena.title)
    Case: \(suiteCase.title)
    """
  }

  private static func toolChoiceLedgerJSON(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    let protocolSpec = TatwoArenaPolicyFactory.planLoopGoalProtocol()
    return jsonString([
      "schema": "TatwoSandboxArenaToolChoiceLedgerV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "model": model.slug,
      "registryOnly": true,
      "allowedRegistryEntryIDs": protocolSpec.allowedRegistryEntryIDs,
      "entries": [],
    ])
  }

  private static func receiptIndexJSON(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    jsonString([
      "schema": "TatwoSandboxArenaReceiptIndexV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "model": model.slug,
      "requiredReceipts": suiteCase.requiredReceipts,
      "blockingReceiptsPending": suiteCase.requiredReceipts,
      "receipts": [],
    ])
  }

  private static func hiddenTestsManifestJSON(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan
  ) -> String {
    jsonString([
      "schema": "TatwoSandboxArenaHiddenTestsManifestV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "hiddenChecks": suiteCase.hiddenChecks,
      "modelMayReadHiddenExpectedAnswers": false,
      "modelMayModifyHiddenTests": false,
    ])
  }

  private static func protectedFilesJSON(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan
  ) -> String {
    jsonString([
      "schema": "TatwoSandboxArenaProtectedFilesV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "protectedFiles": suiteCase.protectedFiles,
      "mutationPolicy": "protected file mutation invalidates submission unless the prompt explicitly authorizes it",
    ])
  }

  private static func sealJSON(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan,
    sealed: Bool
  ) -> String {
    jsonString([
      "schema": "TatwoSandboxArenaSubmissionSealV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "model": model.slug,
      "sealed": sealed,
      "editable": !sealed,
      "hashes": [:],
      "postSealMutationPolicy": plan.goalCyclePolicy.postSealMutationPolicy,
    ])
  }

  private static func createArenaSpecificArtifactScaffold(
    folder: URL,
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) throws {
    guard plan.arena == .modeling3D else { return }
    let base = folder.appendingPathComponent("generated-artifacts/作品", isDirectory: true)
    let blender = base.appendingPathComponent("Blender", isDirectory: true)
    let ue = base.appendingPathComponent("UE5.8", isDirectory: true)
    let score = folder.appendingPathComponent("generated-artifacts/評分", isDirectory: true)
    for directory in [blender, ue, score] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try threeDWorkspaceReadme(tool: "Blender", plan: plan, suiteCase: suiteCase, model: model).write(
      to: blender.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try threeDWorkspaceReadme(tool: "UE5.8", plan: plan, suiteCase: suiteCase, model: model).write(
      to: ue.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try jsonString([
      "schema": "Tatwo3DArtifactWorkspaceManifestV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "model": model.slug,
      "blenderWorkRoot": "generated-artifacts/作品/Blender",
      "ue58WorkRoot": "generated-artifacts/作品/UE5.8",
      "scoreRoot": "generated-artifacts/評分",
      "externalToolsAutoStarted": false,
      "externalDiskRequiredOnlyWhenUserAuthorizes": true,
      "missingToolPolicy": "degraded_not_crash",
    ]).write(to: score.appendingPathComponent("3d-workspace-manifest.json"), atomically: true, encoding: .utf8)
  }

  private static func threeDWorkspaceReadme(
    tool: String,
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    """
    # \(tool) 作品區

    - schema: Tatwo3DArtifactWorkspaceV1
    - arena: \(plan.arena.rawValue)
    - case: \(suiteCase.id)
    - model: \(model.slug)
    - autoStartTool: false
    - hostMutationAllowed: false
    - missingToolPolicy: degraded_not_crash

    這裡用來存放 \(tool) 作品、截圖、匯出、匯入紀錄與評分資料。
    目前只是 scaffold；只有使用者明確要求 3D 實測時，才可啟動對應 MCP / 外接硬碟工具。
    """
  }

  private static func modelOutputMarkdown(model: TatwoSandboxArenaModelPlan) -> String {
    """
    # Model Output

    Status: scaffold_pending
    Model: \(model.displayName)

    This file must be replaced by authorized model output before sealing.
    """
  }

  private static func buildLog(plan: TatwoSandboxArenaPlan, model: TatwoSandboxArenaModelPlan) -> String {
    """
    TATWO Sandbox Arena scaffold
    arena=\(plan.arena.rawValue)
    model=\(model.slug)
    modelFanoutExecuted=false
    result=scaffold_pending
    """
  }

  private static func graderReportJSON(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    jsonString([
      "schema": "TatwoSandboxArenaGraderReportV1",
      "arena": plan.arena.rawValue,
      "caseID": suiteCase.id,
      "model": model.slug,
      "status": "scaffold_pending",
      "scoreEligible": false,
      "requiredReceipts": suiteCase.requiredReceipts,
    ])
  }

  private static func generatedArtifactsReadme(
    plan: TatwoSandboxArenaPlan,
    suiteCase: TatwoSandboxArenaCasePlan,
    model: TatwoSandboxArenaModelPlan
  ) -> String {
    """
    # Generated Artifacts

    This folder belongs to \(plan.arena.title) / \(suiteCase.title) / \(model.displayName).
    The scaffold is not model-tested evidence.
    Authorized model output may add files here only under a Work OS contract.
    """
  }

  private static func reportMarkdown(_ report: TatwoSandboxArenaEvaluationReport) -> String {
    """
    # 評分報告

    - schema: \(report.schema)
    - arena: \(report.arena.rawValue)
    - case: \(report.caseID)
    - model: \(report.modelSlug)
    - status: \(report.status.rawValue)
    - score: \(report.finalScore)
    - notice: \(report.requiredNotice)
    - PLG canScore: \(report.plgScore.canScorePlanLoopGoal)

    Notes:
    \(report.notes.map { "- \($0)" }.joined(separator: "\n"))
    """
  }

  private static func runSummaryMarkdown(_ summary: TatwoSandboxArenaRunSummary) -> String {
    """
    # \(summary.arena.chineseTitle) 總評分報告

    - runID: \(summary.runID)
    - root: \(summary.rootRelativePath)
    - reports: \(summary.reportCount)
    - missingReports: \(summary.missingReports.count)

    Scaffold reports are not real model benchmark scores.
    """
  }
}
