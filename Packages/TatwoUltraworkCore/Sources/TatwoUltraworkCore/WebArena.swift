import Foundation

public enum TatwoWebArenaSuiteID: String, Codable, Sendable, CaseIterable, Equatable {
  case v1
}

public enum TatwoWebArenaCaseID: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case tattoo = "tattoo"
  case assetLibrary3D = "3d-asset-library"
  case pionexStyle = "pionex-style"
}

public enum TatwoWebArenaModelStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case planned
  case skipped
  case scaffolded
}

public enum TatwoWebArenaReportStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case passed
  case needsVisualEvidence = "needs_visual_evidence"
  case engineeringFailed = "engineering_failed"
  case failed
  case skipped
}

public struct TatwoWebArenaScoreWeights: Codable, Sendable, Equatable {
  public let topicUnderstanding: Int
  public let functionality: Int
  public let uiUXAesthetics: Int
  public let engineeringQuality: Int
  public let instructionFollowingHonesty: Int

  public init(
    topicUnderstanding: Int,
    functionality: Int,
    uiUXAesthetics: Int,
    engineeringQuality: Int,
    instructionFollowingHonesty: Int
  ) {
    self.topicUnderstanding = topicUnderstanding
    self.functionality = functionality
    self.uiUXAesthetics = uiUXAesthetics
    self.engineeringQuality = engineeringQuality
    self.instructionFollowingHonesty = instructionFollowingHonesty
  }

  public var total: Int {
    topicUnderstanding + functionality + uiUXAesthetics + engineeringQuality
      + instructionFollowingHonesty
  }
}

public struct TatwoWebArenaScoreInput: Codable, Sendable, Equatable {
  public let topicUnderstanding: Int
  public let functionality: Int
  public let uiUXAesthetics: Int
  public let engineeringQuality: Int
  public let instructionFollowingHonesty: Int

  public init(
    topicUnderstanding: Int,
    functionality: Int,
    uiUXAesthetics: Int,
    engineeringQuality: Int,
    instructionFollowingHonesty: Int
  ) {
    self.topicUnderstanding = topicUnderstanding
    self.functionality = functionality
    self.uiUXAesthetics = uiUXAesthetics
    self.engineeringQuality = engineeringQuality
    self.instructionFollowingHonesty = instructionFollowingHonesty
  }

  public static let zero = TatwoWebArenaScoreInput(
    topicUnderstanding: 0,
    functionality: 0,
    uiUXAesthetics: 0,
    engineeringQuality: 0,
    instructionFollowingHonesty: 0)
}

public struct TatwoWebArenaCasePlan: Codable, Sendable, Identifiable, Equatable {
  public let id: TatwoWebArenaCaseID
  public let folderName: String
  public let title: String
  public let benchmarkPurpose: String
  public let scoreWeights: TatwoWebArenaScoreWeights
  public let scoringFocus: [String]
  public let safetyRules: [String]
  public let prompt: String
  public let models: [TatwoWebArenaModelPlan]

  public init(
    id: TatwoWebArenaCaseID,
    folderName: String,
    title: String,
    benchmarkPurpose: String,
    scoreWeights: TatwoWebArenaScoreWeights,
    scoringFocus: [String],
    safetyRules: [String],
    prompt: String,
    models: [TatwoWebArenaModelPlan]
  ) {
    self.id = id
    self.folderName = folderName
    self.title = title
    self.benchmarkPurpose = benchmarkPurpose
    self.scoreWeights = scoreWeights
    self.scoringFocus = scoringFocus
    self.safetyRules = safetyRules
    self.prompt = prompt
    self.models = models
  }
}

public struct TatwoWebArenaModelPlan: Codable, Sendable, Identifiable, Equatable {
  public var id: String { slug }
  public let slug: String
  public let displayName: String
  public let folderName: String
  public let status: TatwoWebArenaModelStatus
  public let statusReason: String
  public let relativeFolderPath: String
  public let requiredFiles: [String]

  public init(
    slug: String,
    displayName: String,
    folderName: String,
    status: TatwoWebArenaModelStatus,
    statusReason: String,
    relativeFolderPath: String,
    requiredFiles: [String]
  ) {
    self.slug = slug
    self.displayName = displayName
    self.folderName = folderName
    self.status = status
    self.statusReason = statusReason
    self.relativeFolderPath = relativeFolderPath
    self.requiredFiles = requiredFiles
  }
}

public struct TatwoWebArenaPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let suite: TatwoWebArenaSuiteID
  public let rootRelativePath: String
  public let runID: String
  public let cases: [TatwoWebArenaCasePlan]
  public let scoringStandard: [String]
  public let goalCyclePolicy: TatwoArenaGoalCyclePolicy
  public let planLoopGoalProtocol: TatwoArenaPlanLoopGoalProtocol
  public let localOnlyRules: [String]
  public let runCommand: String
  public let reportCommand: String
  public let cleanupCommand: String

  public init(
    schema: String = "TatwoWebArenaPlanV1",
    suite: TatwoWebArenaSuiteID,
    rootRelativePath: String,
    runID: String,
    cases: [TatwoWebArenaCasePlan],
    scoringStandard: [String],
    goalCyclePolicy: TatwoArenaGoalCyclePolicy = TatwoArenaPolicyFactory.goalCyclePolicy,
    planLoopGoalProtocol: TatwoArenaPlanLoopGoalProtocol = TatwoArenaPolicyFactory.planLoopGoalProtocol(),
    localOnlyRules: [String],
    runCommand: String,
    reportCommand: String,
    cleanupCommand: String
  ) {
    self.schema = schema
    self.suite = suite
    self.rootRelativePath = rootRelativePath
    self.runID = runID
    self.cases = cases
    self.scoringStandard = scoringStandard
    self.goalCyclePolicy = goalCyclePolicy
    self.planLoopGoalProtocol = planLoopGoalProtocol
    self.localOnlyRules = localOnlyRules
    self.runCommand = runCommand
    self.reportCommand = reportCommand
    self.cleanupCommand = cleanupCommand
  }
}

public struct TatwoWebArenaEvaluationReport: Codable, Sendable, Equatable {
  public let schema: String
  public let suiteCase: TatwoWebArenaCaseID
  public let modelSlug: String
  public let modelFolderName: String
  public let status: TatwoWebArenaReportStatus
  public let scoreWeights: TatwoWebArenaScoreWeights
  public let scoreInput: TatwoWebArenaScoreInput
  public let finalScore: Int
  public let buildSucceeded: Bool
  public let webCheckErrors: Int
  public let webCheckWarnings: Int
  public let desktopScreenshotPresent: Bool
  public let mobileScreenshotPresent: Bool
  public let visualAccepted: Bool
  public let engineeringPassed: Bool
  public let uiUJPassed: Bool
  public let requiredNotice: String
  public let notes: [String]

  public init(
    schema: String = "TatwoWebArenaEvaluationReportV1",
    suiteCase: TatwoWebArenaCaseID,
    modelSlug: String,
    modelFolderName: String,
    status: TatwoWebArenaReportStatus,
    scoreWeights: TatwoWebArenaScoreWeights,
    scoreInput: TatwoWebArenaScoreInput,
    finalScore: Int,
    buildSucceeded: Bool,
    webCheckErrors: Int,
    webCheckWarnings: Int,
    desktopScreenshotPresent: Bool,
    mobileScreenshotPresent: Bool,
    visualAccepted: Bool,
    engineeringPassed: Bool,
    uiUJPassed: Bool,
    requiredNotice: String,
    notes: [String]
  ) {
    self.schema = schema
    self.suiteCase = suiteCase
    self.modelSlug = modelSlug
    self.modelFolderName = modelFolderName
    self.status = status
    self.scoreWeights = scoreWeights
    self.scoreInput = scoreInput
    self.finalScore = finalScore
    self.buildSucceeded = buildSucceeded
    self.webCheckErrors = webCheckErrors
    self.webCheckWarnings = webCheckWarnings
    self.desktopScreenshotPresent = desktopScreenshotPresent
    self.mobileScreenshotPresent = mobileScreenshotPresent
    self.visualAccepted = visualAccepted
    self.engineeringPassed = engineeringPassed
    self.uiUJPassed = uiUJPassed
    self.requiredNotice = requiredNotice
    self.notes = notes
  }
}

public struct TatwoWebArenaRunReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let suite: TatwoWebArenaSuiteID
  public let runID: String
  public let rootRelativePath: String
  public let createdModelFolders: [String]
  public let modelFanoutExecuted: Bool
  public let hostMutationAllowed: Bool
  public let status: String
  public let notes: [String]

  public init(
    schema: String = "TatwoWebArenaRunReceiptV1",
    suite: TatwoWebArenaSuiteID,
    runID: String,
    rootRelativePath: String,
    createdModelFolders: [String],
    modelFanoutExecuted: Bool,
    hostMutationAllowed: Bool,
    status: String,
    notes: [String]
  ) {
    self.schema = schema
    self.suite = suite
    self.runID = runID
    self.rootRelativePath = rootRelativePath
    self.createdModelFolders = createdModelFolders
    self.modelFanoutExecuted = modelFanoutExecuted
    self.hostMutationAllowed = hostMutationAllowed
    self.status = status
    self.notes = notes
  }
}

public struct TatwoWebArenaRunSummary: Codable, Sendable, Equatable {
  public let schema: String
  public let runID: String
  public let rootRelativePath: String
  public let reportCount: Int
  public let cases: [TatwoWebArenaCaseSummary]
  public let modelTotals: [TatwoWebArenaModelTotal]
  public let missingReports: [String]
  /// Phase 3: how many aggregated reports are backed by a verified submission seal. A score
  /// with no verified seal is not trustworthy evidence — a model can write its own report.
  public let sealVerifiedReportCount: Int
  /// Phase 3b (縮減版): when a grader key (`TATWO_ARENA_SEAL_KEY`) is configured, unsealed
  /// reports are dropped from the score aggregation entirely and counted here instead.
  /// Without a key (casual/scaffold runs) nothing is excluded and this stays 0.
  public let excludedUnsealedReportCount: Int

  public init(
    schema: String = "TatwoWebArenaRunSummaryV1",
    runID: String,
    rootRelativePath: String,
    reportCount: Int,
    cases: [TatwoWebArenaCaseSummary],
    modelTotals: [TatwoWebArenaModelTotal],
    missingReports: [String],
    sealVerifiedReportCount: Int = 0,
    excludedUnsealedReportCount: Int = 0
  ) {
    self.schema = schema
    self.runID = runID
    self.rootRelativePath = rootRelativePath
    self.reportCount = reportCount
    self.cases = cases
    self.modelTotals = modelTotals
    self.missingReports = missingReports
    self.sealVerifiedReportCount = sealVerifiedReportCount
    self.excludedUnsealedReportCount = excludedUnsealedReportCount
  }

  private enum CodingKeys: String, CodingKey {
    case schema, runID, rootRelativePath, reportCount, cases, modelTotals, missingReports
    case sealVerifiedReportCount, excludedUnsealedReportCount
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.schema = try c.decode(String.self, forKey: .schema)
    self.runID = try c.decode(String.self, forKey: .runID)
    self.rootRelativePath = try c.decode(String.self, forKey: .rootRelativePath)
    self.reportCount = try c.decode(Int.self, forKey: .reportCount)
    self.cases = try c.decode([TatwoWebArenaCaseSummary].self, forKey: .cases)
    self.modelTotals = try c.decode([TatwoWebArenaModelTotal].self, forKey: .modelTotals)
    self.missingReports = try c.decode([String].self, forKey: .missingReports)
    self.sealVerifiedReportCount =
      try c.decodeIfPresent(Int.self, forKey: .sealVerifiedReportCount) ?? 0
    self.excludedUnsealedReportCount =
      try c.decodeIfPresent(Int.self, forKey: .excludedUnsealedReportCount) ?? 0
  }
}

public struct TatwoWebArenaCaseSummary: Codable, Sendable, Equatable {
  public let caseID: TatwoWebArenaCaseID
  public let folderName: String
  public let reports: [TatwoWebArenaEvaluationReport]
}

public struct TatwoWebArenaModelTotal: Codable, Sendable, Equatable {
  public let modelFolderName: String
  public let reportCount: Int
  public let totalScore: Int
  public let averageScore: Double
  public let blockedCount: Int
  /// Phase 3b: how many of this model's reports are backed by a verified submission seal, and
  /// the score summed from only those reports. A forged 評分報告.json over an unsealed/tampered
  /// submission contributes 0 here, so the trustworthy ranking sorts it below sealed work.
  public let sealVerifiedReportCount: Int
  public let sealVerifiedScore: Int

  public init(
    modelFolderName: String,
    reportCount: Int,
    totalScore: Int,
    averageScore: Double,
    blockedCount: Int,
    sealVerifiedReportCount: Int = 0,
    sealVerifiedScore: Int = 0
  ) {
    self.modelFolderName = modelFolderName
    self.reportCount = reportCount
    self.totalScore = totalScore
    self.averageScore = averageScore
    self.blockedCount = blockedCount
    self.sealVerifiedReportCount = sealVerifiedReportCount
    self.sealVerifiedScore = sealVerifiedScore
  }

  private enum CodingKeys: String, CodingKey {
    case modelFolderName, reportCount, totalScore, averageScore, blockedCount
    case sealVerifiedReportCount, sealVerifiedScore
  }

  // Lenient decode so an older summary.json (without the seal fields) still loads.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.modelFolderName = try c.decode(String.self, forKey: .modelFolderName)
    self.reportCount = try c.decode(Int.self, forKey: .reportCount)
    self.totalScore = try c.decode(Int.self, forKey: .totalScore)
    self.averageScore = try c.decode(Double.self, forKey: .averageScore)
    self.blockedCount = try c.decode(Int.self, forKey: .blockedCount)
    self.sealVerifiedReportCount = try c.decodeIfPresent(Int.self, forKey: .sealVerifiedReportCount) ?? 0
    self.sealVerifiedScore = try c.decodeIfPresent(Int.self, forKey: .sealVerifiedScore) ?? 0
  }
}


public struct TatwoWebArenaCaseEvidence: Codable, Sendable, Identifiable, Equatable {
  public var id: TatwoWebArenaCaseID { caseID }
  public let caseID: TatwoWebArenaCaseID
  public let title: String
  public let score: Int
  public let status: TatwoWebArenaReportStatus
  public let engineeringPassed: Bool
  public let uiUJPassed: Bool
  public let webCheckErrors: Int
  public let webCheckWarnings: Int

  public init(
    caseID: TatwoWebArenaCaseID,
    title: String,
    score: Int,
    status: TatwoWebArenaReportStatus,
    engineeringPassed: Bool,
    uiUJPassed: Bool,
    webCheckErrors: Int,
    webCheckWarnings: Int
  ) {
    self.caseID = caseID
    self.title = title
    self.score = score
    self.status = status
    self.engineeringPassed = engineeringPassed
    self.uiUJPassed = uiUJPassed
    self.webCheckErrors = webCheckErrors
    self.webCheckWarnings = webCheckWarnings
  }
}


public struct TatwoWebArenaTraitDimensionEvidence: Codable, Sendable, Identifiable, Equatable {
  public var id: String { dimensionID }
  public let dimensionID: String
  public let dimensionTitle: String
  public let value0To10: Double
  public let evidenceSource: String
  public let status: String
  public let note: String

  public init(
    dimensionID: String,
    dimensionTitle: String,
    value0To10: Double,
    evidenceSource: String,
    status: String,
    note: String
  ) {
    self.dimensionID = dimensionID
    self.dimensionTitle = dimensionTitle
    self.value0To10 = value0To10
    self.evidenceSource = evidenceSource
    self.status = status
    self.note = note
  }
}

public enum TatwoWebArenaScoreCategory: String, Codable, Sendable, CaseIterable, Equatable {
  case topicUnderstanding
  case functionality
  case uiUXAesthetics
  case engineeringQuality
  case instructionFollowingHonesty

  public var title: String {
    switch self {
    case .topicUnderstanding: return "Web Arena 主題理解"
    case .functionality: return "Web Arena 功能完整度"
    case .uiUXAesthetics: return "Web Arena UI/UX美感"
    case .engineeringQuality: return "Web Arena 工程品質"
    case .instructionFollowingHonesty: return "Web Arena 指令遵循與誠實度"
    }
  }
}

public struct TatwoWebArenaTraitMapping: Codable, Sendable, Identifiable, Equatable {
  public var id: String { "\(arena):\(category.rawValue)->\(dimensionID)" }
  public let arena: String
  public let category: TatwoWebArenaScoreCategory
  public let dimensionID: String
  public let dimensionTitle: String
  public let rationale: String

  public init(
    arena: String,
    category: TatwoWebArenaScoreCategory,
    dimensionID: String,
    dimensionTitle: String,
    rationale: String
  ) {
    self.arena = arena
    self.category = category
    self.dimensionID = dimensionID
    self.dimensionTitle = dimensionTitle
    self.rationale = rationale
  }
}

public enum TatwoWebArenaTraitMappingCatalog {
  public static let mappings: [TatwoWebArenaTraitMapping] = [
    TatwoWebArenaTraitMapping(
      arena: "Web Arena v1",
      category: .topicUnderstanding,
      dimensionID: "macro-architecture",
      dimensionTitle: "任務宏觀架構理解",
      rationale: "能否把刺青、3D資產庫、交易所等題意轉成整體產品架構。"),
    TatwoWebArenaTraitMapping(
      arena: "Web Arena v1",
      category: .functionality,
      dimensionID: "solo-capability",
      dimensionTitle: "單打獨鬥能力",
      rationale: "功能完整度代表單模型獨立把需求落成可檢查頁面的能力。"),
    TatwoWebArenaTraitMapping(
      arena: "Web Arena v1",
      category: .uiUXAesthetics,
      dimensionID: "aesthetics",
      dimensionTitle: "美感",
      rationale: "UI/UX美感直接對應版面、比例、留白與視覺焦點。"),
    TatwoWebArenaTraitMapping(
      arena: "Web Arena v1",
      category: .engineeringQuality,
      dimensionID: "code-architecture",
      dimensionTitle: "代碼架構工整",
      rationale: "工程品質對應可維護檔案、樣式、互動與檢查結果。"),
    TatwoWebArenaTraitMapping(
      arena: "Web Arena v1",
      category: .instructionFollowingHonesty,
      dimensionID: "hallucination-control",
      dimensionTitle: "幻覺度控制",
      rationale: "指令遵循與誠實度用來約束是否亂用品牌、偽造能力或忽略禁止事項。"),
  ]

  public static var markdownTable: String {
    let header = "| 考場 | 類別 | 特質維度 | 映射理由 |\n|---|---|---|---|"
    let rows = mappings.map {
      "| \($0.arena) | \($0.category.title) | \($0.dimensionTitle) (`\($0.dimensionID)`) | \($0.rationale) |"
    }
    return ([header] + rows).joined(separator: "\n")
  }

  public static func derivedEvidence(from evidence: TatwoWebArenaModelEvidence) -> [TatwoWebArenaTraitDimensionEvidence] {
    guard evidence.hasExamScoreRecord else { return [] }
    let averageFinalScore0To10 = max(0, min(10, evidence.averageScore / 10))
    return mappings.map { mapping in
      TatwoWebArenaTraitDimensionEvidence(
        dimensionID: mapping.dimensionID,
        dimensionTitle: mapping.dimensionTitle,
        value0To10: averageFinalScore0To10,
        evidenceSource: "\(mapping.arena) derived · \(mapping.category.title)",
        status: evidence.status,
        note: "由 sealed case finalScore 平均 \(Self.formatOneDecimal(evidence.averageScore))/100 映射；不是人工覆蓋，人工評分可另行覆寫。\(mapping.rationale)"
      )
    }
  }

  private static func formatOneDecimal(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded.truncatingRemainder(dividingBy: 1) == 0 {
      return "\(Int(rounded))"
    }
    return String(format: "%.1f", rounded)
  }
}

public struct TatwoWebArenaModelEvidence: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let modelSlug: String
  public let displayName: String
  public let arena: String
  public let runID: String
  public let testedAt: String
  public let status: String
  public let averageScore: Double
  public let totalScore: Int
  public let reportCount: Int
  public let failedCount: Int
  public let sealVerifiedReportCount: Int
  public let modelFanoutExecuted: Bool
  public let dispatchComplete: Bool
  public let evidenceRelativePath: String
  public let summaryRelativePath: String
  public let interpretation: String
  public let routingImplication: String
  public let limitations: [String]
  public let caseEvidence: [TatwoWebArenaCaseEvidence]
  /// Canonical mapping into the shared trait dimensions.
  /// This is evidence, not a standalone model ranking or global score.
  public let traitDimensionEvidence: [TatwoWebArenaTraitDimensionEvidence]

  public init(
    id: String,
    modelSlug: String,
    displayName: String,
    arena: String,
    runID: String,
    testedAt: String,
    status: String,
    averageScore: Double,
    totalScore: Int,
    reportCount: Int,
    failedCount: Int,
    sealVerifiedReportCount: Int,
    modelFanoutExecuted: Bool,
    dispatchComplete: Bool,
    evidenceRelativePath: String,
    summaryRelativePath: String,
    interpretation: String,
    routingImplication: String,
    limitations: [String],
    caseEvidence: [TatwoWebArenaCaseEvidence],
    traitDimensionEvidence: [TatwoWebArenaTraitDimensionEvidence] = []
  ) {
    self.id = id
    self.modelSlug = modelSlug
    self.displayName = displayName
    self.arena = arena
    self.runID = runID
    self.testedAt = testedAt
    self.status = status
    self.averageScore = averageScore
    self.totalScore = totalScore
    self.reportCount = reportCount
    self.failedCount = failedCount
    self.sealVerifiedReportCount = sealVerifiedReportCount
    self.modelFanoutExecuted = modelFanoutExecuted
    self.dispatchComplete = dispatchComplete
    self.evidenceRelativePath = evidenceRelativePath
    self.summaryRelativePath = summaryRelativePath
    self.interpretation = interpretation
    self.routingImplication = routingImplication
    self.limitations = limitations
    self.caseEvidence = caseEvidence
    self.traitDimensionEvidence = traitDimensionEvidence
  }
}

public extension TatwoWebArenaModelEvidence {
  var hasExamScoreRecord: Bool {
    reportCount > 0 && caseEvidence.isEmpty == false
  }

  var examScoreSummaryLabel: String {
    guard hasExamScoreRecord else { return "Web 考試紀錄缺" }
    return "Web 考試均分 \(Self.formatOneDecimal(averageScore))/100"
  }

  var manualTraitScoreLabel: String {
    traitDimensionEvidence.isEmpty ? "+人工評分" : "人工評分 \(traitDimensionEvidence.count) 項"
  }

  var manualTraitScoreIsPending: Bool {
    traitDimensionEvidence.isEmpty
  }

  private static func formatOneDecimal(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded.truncatingRemainder(dividingBy: 1) == 0 {
      return "\(Int(rounded))"
    }
    return String(format: "%.1f", rounded)
  }
}

public struct TatwoWebArenaCleanupCandidate: Codable, Sendable, Equatable {
  public let runID: String
  public let relativePath: String
  public let reason: String
}

public struct TatwoWebArenaCleanupPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let rootRelativePath: String
  public let olderThanDays: Int
  public let dryRun: Bool
  public let hostMutationAllowed: Bool
  public let deletionExecuted: Bool
  public let candidates: [TatwoWebArenaCleanupCandidate]
  public let keepPolicy: [String]

  public init(
    schema: String = "TatwoWebArenaCleanupPlanV1",
    rootRelativePath: String,
    olderThanDays: Int,
    dryRun: Bool,
    hostMutationAllowed: Bool,
    deletionExecuted: Bool,
    candidates: [TatwoWebArenaCleanupCandidate],
    keepPolicy: [String]
  ) {
    self.schema = schema
    self.rootRelativePath = rootRelativePath
    self.olderThanDays = olderThanDays
    self.dryRun = dryRun
    self.hostMutationAllowed = hostMutationAllowed
    self.deletionExecuted = deletionExecuted
    self.candidates = candidates
    self.keepPolicy = keepPolicy
  }
}

public enum TatwoWebArenaFactory {
  public static let rootRelativePath = ".tatwo-ultrawork/網頁設計沙盒"

  public static let importedModelEvidence: [TatwoWebArenaModelEvidence] = [
    TatwoWebArenaModelEvidence(
      id: "minimax-m3-web-arena-v4-20260702",
      modelSlug: "minimax-m3",
      displayName: "MiniMax M3",
      arena: "Web Arena v1",
      runID: "20260702-minimax-m3-web-arena-formal-v4",
      testedAt: "2026-07-02",
      status: "rollback_required",
      averageScore: 53.333333333333336,
      totalScore: 160,
      reportCount: 3,
      failedCount: 3,
      sealVerifiedReportCount: 3,
      modelFanoutExecuted: true,
      dispatchComplete: false,
      evidenceRelativePath: ".tatwo-ultrawork/evidence/20260702-minimax-m3-web-arena-formal-v4/live-run-receipt.json",
      summaryRelativePath: ".tatwo-ultrawork/網頁設計沙盒/20260702-minimax-m3-web-arena-formal-v4/summary.json",
      interpretation: "語義覆蓋與主題延展不差，但正式封存後三題皆未通過工程/UI gate。",
      routingImplication: "保留為大量草稿、候選、checklist、測試點 scout；不可當 sealed frontend finisher、UI/UJ 驗收或 final judge。",
      limitations: [
        "Web Arena 只測三類靜態網頁，不代表所有領域總能力。",
        "UI/UJ 尚未經 human/product-design 放行；web-check 只算工程證據。",
        "dispatchComplete=false，部分檔案輸出曾 fetch failed 或 empty output。"
      ],
      caseEvidence: [
        TatwoWebArenaCaseEvidence(caseID: .tattoo, title: "刺青網頁", score: 55, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 0, webCheckWarnings: 2),
        TatwoWebArenaCaseEvidence(caseID: .assetLibrary3D, title: "3D 資產收納", score: 50, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 0, webCheckWarnings: 0),
        TatwoWebArenaCaseEvidence(caseID: .pionexStyle, title: "交易所結構", score: 55, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 1, webCheckWarnings: 4),
      ],
      traitDimensionEvidence: [
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "macro-architecture", dimensionTitle: "任務宏觀架構理解", value0To10: 2.7, evidenceSource: "human Web Arena v4", status: "human-rejected", note: "三題主題理解平均；刺青有辨識但整體不可升分"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "code-architecture", dimensionTitle: "代碼架構工整", value0To10: 0.4, evidenceSource: "human Web Arena v4", status: "human-rejected", note: "功能完整度平均極低，只能證明不適合前端完工"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "aesthetics", dimensionTitle: "美感", value0To10: 0.0, evidenceSource: "human Web Arena v4", status: "human-rejected", note: "三題 UI/UX 美感皆為 0"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "creativity", dimensionTitle: "創造力", value0To10: 0.0, evidenceSource: "human Web Arena v4", status: "human-rejected", note: "3D 資產收納題未展現可用創造規劃"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "info-forecasting", dimensionTitle: "整合資訊與預判能力", value0To10: 0.1, evidenceSource: "human Web Arena v4", status: "human-rejected", note: "Pionex-style 題幾乎未通過人類產品理解"),
      ]
    ),
    TatwoWebArenaModelEvidence(
      id: "grok-build-web-arena-v1-20260702",
      modelSlug: "grok-build",
      displayName: "Grok",
      arena: "Web Arena v1",
      runID: "20260702-grok-build-web-arena-formal-v1",
      testedAt: "2026-07-02",
      status: "rollback_required",
      averageScore: 38.666666666666664,
      totalScore: 116,
      reportCount: 3,
      failedCount: 3,
      sealVerifiedReportCount: 3,
      modelFanoutExecuted: true,
      dispatchComplete: false,
      evidenceRelativePath: ".tatwo-ultrawork/evidence/20260702-grok-build-web-arena-formal-v1/live-run-receipt.json",
      summaryRelativePath: ".tatwo-ultrawork/網頁設計沙盒/20260702-grok-build-web-arena-formal-v1/summary.json",
      interpretation: "主題結構在 3D 資產與交易所題能抓到重點，但多個檔案 timeout / empty output，封存作品未通過工程與 UI/UJ gate。",
      routingImplication: "保留為消息、反例、產品結構 scout；可用來補外部視角與功能清單，不可當 sealed frontend finisher、UI/UJ 驗收或 final judge。",
      limitations: [
        "Web Arena 只測三類靜態網頁，不代表所有領域總能力。",
        "Grok route 在本次最高思考下出現多次 timeout，dispatchComplete=false。",
        "web-check 沒有錯不代表 UI 通過；本次三題皆 rollback_required。"
      ],
      caseEvidence: [
        TatwoWebArenaCaseEvidence(caseID: .tattoo, title: "刺青網頁", score: 11, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 0, webCheckWarnings: 0),
        TatwoWebArenaCaseEvidence(caseID: .assetLibrary3D, title: "3D 資產收納", score: 50, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 0, webCheckWarnings: 0),
        TatwoWebArenaCaseEvidence(caseID: .pionexStyle, title: "交易所結構", score: 55, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 0, webCheckWarnings: 0),
      ],
      traitDimensionEvidence: [
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "macro-architecture", dimensionTitle: "任務宏觀架構理解", value0To10: 5.3, evidenceSource: "human Web Arena v1", status: "mixed", note: "刺青失敗；3D 與交易所題抓到部分產品結構"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "code-architecture", dimensionTitle: "代碼架構工整", value0To10: 2.3, evidenceSource: "human Web Arena v1", status: "weak", note: "功能完整度平均偏低，工程仍 fail"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "aesthetics", dimensionTitle: "美感", value0To10: 0.5, evidenceSource: "human Web Arena v1", status: "human-rejected", note: "UI/UX 美感平均 5/100，不可當視覺主導"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "creativity", dimensionTitle: "創造力", value0To10: 2.5, evidenceSource: "human Web Arena v1", status: "weak", note: "3D 資產題有主題辨識，但功能與 UI 很弱"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "info-forecasting", dimensionTitle: "整合資訊與預判能力", value0To10: 5.4, evidenceSource: "human Web Arena v1", status: "usable-scout", note: "Pionex-style 題顯示較強產品結構/資訊架構 scout 訊號"),
        TatwoWebArenaTraitDimensionEvidence(dimensionID: "stability", dimensionTitle: "穩定性", value0To10: 2.0, evidenceSource: "auto Web Arena v1", status: "failed", note: "正式 run 多次 timeout / empty output，不能升為穩定完工者"),
      ]
    ),
    TatwoWebArenaModelEvidence(
      id: "gpt-5-4-web-arena-v2-20260702",
      modelSlug: "gpt-5.4",
      displayName: "GPT-5.4",
      arena: "Web Arena v1",
      runID: "20260702-gpt-5-4-web-arena-formal-v2",
      testedAt: "2026-07-02",
      status: "rollback_required",
      averageScore: 65.66666666666667,
      totalScore: 197,
      reportCount: 3,
      failedCount: 3,
      sealVerifiedReportCount: 3,
      modelFanoutExecuted: true,
      dispatchComplete: true,
      evidenceRelativePath: ".tatwo-ultrawork/evidence/20260702-gpt-5-4-web-arena-formal-v2/live-run-receipt.json",
      summaryRelativePath: ".tatwo-ultrawork/網頁設計沙盒/20260702-gpt-5-4-web-arena-formal-v2/summary.json",
      interpretation: "三題語義覆蓋完整、dispatch 全完成、封存與截圖齊全；但 web-check 有阻塞錯誤，UI/UJ 也未經獨立視覺 gate，因此仍不能放行。",
      routingImplication: "可作 S/M 級草稿建置與結構補位；若要升 frontend finisher，必須由 Codex/Sonnet 修 web-check，再交 Product Design 或人工視覺 gate。",
      limitations: [
        "Web Arena 只測三類靜態網頁，不代表所有領域總能力。",
        "本次為 xhigh + 600000ms timeout 的 v2 正式 run；v1 因基礎 timeout 過短已停止，不作評分依據。",
        "三題 buildSucceeded=true 但 engineeringPassed=false；不可把高語義分誤讀成可上線。"
      ],
      caseEvidence: [
        TatwoWebArenaCaseEvidence(caseID: .tattoo, title: "刺青網頁", score: 62, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 4, webCheckWarnings: 6),
        TatwoWebArenaCaseEvidence(caseID: .assetLibrary3D, title: "3D 資產收納", score: 65, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 4, webCheckWarnings: 9),
        TatwoWebArenaCaseEvidence(caseID: .pionexStyle, title: "交易所結構", score: 70, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 5, webCheckWarnings: 9),
      ]
    ),
    TatwoWebArenaModelEvidence(
      id: "sonnet-5-web-arena-v1-20260702",
      modelSlug: "sonnet-5",
      displayName: "Sonnet 5",
      arena: "Web Arena v1",
      runID: "20260702-sonnet-5-web-arena-v1-from-start",
      testedAt: "2026-07-02",
      status: "rollback_required",
      averageScore: 65.66666666666667,
      totalScore: 197,
      reportCount: 3,
      failedCount: 3,
      sealVerifiedReportCount: 3,
      modelFanoutExecuted: true,
      dispatchComplete: true,
      evidenceRelativePath: ".tatwo-ultrawork/evidence/20260702-sonnet-5-web-arena-v1-from-start/live-run-receipt.json",
      summaryRelativePath: ".tatwo-ultrawork/網頁設計沙盒/20260702-sonnet-5-web-arena-v1-from-start/summary.json",
      interpretation: "Sonnet 5 已完成三題正式 Web Arena，dispatch 與封存完整；但 engineering/UI gate 仍為 rollback_required，尚未轉成人工特質分數。",
      routingImplication: "保留為工程副審與 patch intent 強候選；Web Arena 只能證明已跑過網頁沙盒，正式特質仍需人工/收據映射後才可顯示分數。",
      limitations: [
        "Web Arena 只測三類靜態網頁，不代表所有領域總能力。",
        "三題 buildSucceeded=true 但 engineeringPassed=false；不能當 frontend finisher。",
        "目前沒有 human-to-traits correction receipt；Web Arena 考試分照常顯示，可另加人工評分覆蓋。"
      ],
      caseEvidence: [
        TatwoWebArenaCaseEvidence(caseID: .tattoo, title: "刺青網頁", score: 62, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 4, webCheckWarnings: 6),
        TatwoWebArenaCaseEvidence(caseID: .assetLibrary3D, title: "3D 資產收納", score: 65, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 4, webCheckWarnings: 9),
        TatwoWebArenaCaseEvidence(caseID: .pionexStyle, title: "交易所結構", score: 70, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 5, webCheckWarnings: 9),
      ]
    ),
    TatwoWebArenaModelEvidence(
      id: "fable-5-web-arena-v1-20260702",
      modelSlug: "fable-5",
      displayName: "Fable 5",
      arena: "Web Arena v1",
      runID: "20260702-fable-5-web-arena-formal-v1",
      testedAt: "2026-07-02",
      status: "rollback_required",
      averageScore: 64,
      totalScore: 192,
      reportCount: 3,
      failedCount: 3,
      sealVerifiedReportCount: 3,
      modelFanoutExecuted: true,
      dispatchComplete: true,
      evidenceRelativePath: ".tatwo-ultrawork/evidence/20260702-fable-5-web-arena-formal-v1/live-run-receipt.json",
      summaryRelativePath: ".tatwo-ultrawork/網頁設計沙盒/20260702-fable-5-web-arena-formal-v1/summary.json",
      interpretation: "Fable 5 已完成三題正式 Web Arena，語義覆蓋完整、封存與截圖齊全；但三題都被 web-check / UI gate 擋下，所以不能作為可放行的前端完工者。",
      routingImplication: "保留為昂貴的高階草稿與架構/產品構想候選；暫不自動排進常駐協作流，除非使用者明確授權用量並補上工程修復與 UI/UJ 副審。",
      limitations: [
        "本次只測 Web Arena 基本三項，不含 3D 建模、Debug、Code Architecture 或多模態。",
        "三題 buildSucceeded=true 但 engineeringPassed=false；web-check 阻塞錯誤仍需其他模型或 Codex 修復。",
        "Fable 5 成本高且可能撞額度；不可預設 fan-out 或當無限制 sub。"
      ],
      caseEvidence: [
        TatwoWebArenaCaseEvidence(caseID: .tattoo, title: "刺青網頁", score: 62, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 1, webCheckWarnings: 2),
        TatwoWebArenaCaseEvidence(caseID: .assetLibrary3D, title: "3D 資產收納", score: 65, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 3, webCheckWarnings: 4),
        TatwoWebArenaCaseEvidence(caseID: .pionexStyle, title: "交易所結構", score: 65, status: .failed, engineeringPassed: false, uiUJPassed: false, webCheckErrors: 1, webCheckWarnings: 1),
      ]
    )
  ]

  public static let defaultModelSlugs = [
    "gpt-5.5", "sonnet-5", "fable-5", "opus-5", "minimax-m3",
  ]

  public static let requiredModelFiles = [
    "prompt.md",
    "goal-contract.md",
    "plan.md",
    "loop-ledger.json",
    "branch-optimization-plan.md",
    "branch-loop-ledger.json",
    "tool-choice-ledger.json",
    "receipt-index.json",
    "model-output.md",
    "generated-project/",
    "final-submission/seal.json",
    "build.log",
    "web-check-report.json",
    "screenshot-desktop.png",
    "screenshot-mobile.png",
    "評分報告.json",
    "評分報告.md",
  ]

  public static let localOnlyRules = [
    "所有 arena 產物只放在 .tatwo-ultrawork/網頁設計沙盒/，方便整批刪除。",
    "web-check 只負責工程品質，不負責美感分。",
    "沒有 desktop/mobile screenshot 或互動證據時，UI/UJ 不可標為通過。",
    "Pionex-style 只做內部 benchmark：不使用官方 logo、商標素材、原文案、真登入或真交易。",
    "模型 route 不可用時建立資料夾與 skipped 報告，但不得偽裝已測試。",
    "所有 sandbox 都必須遵循 plan+loops+goal-主線 與 plan+loops+goal-支線優化。",
    "每個 goal 最多 5 次實作巡迴；plan 與 loop-ledger 不限量，但封存後不可補改。",
    "模型自行選 MCP/skills，但只能使用 Ultrawork registry 登記工具，並輸出 tool-choice-ledger。",
  ]

  public static func plan(
    suite: TatwoWebArenaSuiteID = .v1,
    runID: String,
    models: [String] = defaultModelSlugs
  ) -> TatwoWebArenaPlan {
    let safeRunID = sanitizedRunID(runID)
    let normalizedModels = normalizeModels(models)
    let cases = suiteCases(suite).map { template -> TatwoWebArenaCasePlan in
      let modelPlans = normalizedModels.map { model in
        modelPlan(slug: model, runID: safeRunID, caseFolderName: template.folderName)
      }
      return TatwoWebArenaCasePlan(
        id: template.id,
        folderName: template.folderName,
        title: template.title,
        benchmarkPurpose: template.benchmarkPurpose,
        scoreWeights: template.scoreWeights,
        scoringFocus: template.scoringFocus,
        safetyRules: template.safetyRules,
        prompt: template.prompt,
        models: modelPlans)
    }
    let modelArg = normalizedModels.joined(separator: ",")
    return TatwoWebArenaPlan(
      suite: suite,
      rootRelativePath: rootRelativePath,
      runID: safeRunID,
      cases: cases,
      scoringStandard: [
        "每個模型每個網頁滿分 100，依三種任務目的使用不同權重。",
        "工程品質由 build + web-check errors/warnings 參與；web-check 不裁決美感。",
        "UI/UJ 分需要 desktop/mobile screenshot 或互動證據；缺圖時不可通過。",
        "最終排名同時看刺青、3D 資產、Pionex-style 三類，不用單一總分取代模型定位。",
        "所有沙盒測完後，才另行評分模型的 plan+loops+goal discipline；模型自評不算 pass。",
      ],
      goalCyclePolicy: TatwoArenaPolicyFactory.goalCyclePolicy,
      planLoopGoalProtocol: TatwoArenaPolicyFactory.planLoopGoalProtocol(),
      localOnlyRules: localOnlyRules,
      runCommand: "tatwo-ultrawork web-arena run --suite \(suite.rawValue) --run \(safeRunID) --models \(modelArg) --live --json",
      reportCommand: "tatwo-ultrawork web-arena report --run \(safeRunID) --json",
      cleanupCommand: "tatwo-ultrawork web-arena cleanup --older-than 14d --dry-run --json")
  }

  public static func evaluate(
    suiteCase: TatwoWebArenaCaseID,
    modelSlug: String,
    buildSucceeded: Bool,
    webCheckErrors: Int,
    webCheckWarnings: Int,
    desktopScreenshotPresent: Bool,
    mobileScreenshotPresent: Bool,
    visualAccepted: Bool,
    scoreInput: TatwoWebArenaScoreInput
  ) -> TatwoWebArenaEvaluationReport {
    let weights = scoreWeights(for: suiteCase)
    let engineeringPassed = buildSucceeded && webCheckErrors == 0
    let screenshotEvidence = desktopScreenshotPresent && mobileScreenshotPresent
    let uiUJPassed = screenshotEvidence && visualAccepted
    let status: TatwoWebArenaReportStatus
    let requiredNotice: String

    if engineeringPassed && uiUJPassed {
      status = .passed
      requiredNotice = "工程檢查與 UI/UJ 驗收皆通過。"
    } else if engineeringPassed && !uiUJPassed {
      status = .needsVisualEvidence
      requiredNotice = "工程檢查通過，UI/UJ 未通過"
    } else if !engineeringPassed && uiUJPassed {
      status = .engineeringFailed
      requiredNotice = "視覺可接受，工程驗收未通過"
    } else {
      status = .failed
      requiredNotice = "工程驗收未通過，UI/UJ 未通過或證據不足。"
    }

    let effectiveUIUX = uiUJPassed ? scoreInput.uiUXAesthetics : 0
    let effectiveEngineering = engineeringPassed ? scoreInput.engineeringQuality : min(scoreInput.engineeringQuality, weights.engineeringQuality / 2)
    let finalScore =
      clamp(scoreInput.topicUnderstanding, max: weights.topicUnderstanding)
      + clamp(scoreInput.functionality, max: weights.functionality)
      + clamp(effectiveUIUX, max: weights.uiUXAesthetics)
      + clamp(effectiveEngineering, max: weights.engineeringQuality)
      + clamp(scoreInput.instructionFollowingHonesty, max: weights.instructionFollowingHonesty)

    var notes = [
      "web-check participates in engineeringQuality only; it does not grade aesthetics",
      "UI/UJ pass requires visual evidence, not model self-approval",
    ]
    if !screenshotEvidence {
      notes.append("desktop/mobile screenshot missing or placeholder-only; UI/UJ cannot pass")
    }
    if webCheckErrors > 0 {
      notes.append("web-check blocking errors: \(webCheckErrors); warnings: \(webCheckWarnings)")
    }

    return TatwoWebArenaEvaluationReport(
      suiteCase: suiteCase,
      modelSlug: normalizedModelSlug(modelSlug),
      modelFolderName: folderName(for: modelSlug),
      status: status,
      scoreWeights: weights,
      scoreInput: scoreInput,
      finalScore: finalScore,
      buildSucceeded: buildSucceeded,
      webCheckErrors: webCheckErrors,
      webCheckWarnings: webCheckWarnings,
      desktopScreenshotPresent: desktopScreenshotPresent,
      mobileScreenshotPresent: mobileScreenshotPresent,
      visualAccepted: visualAccepted,
      engineeringPassed: engineeringPassed,
      uiUJPassed: uiUJPassed,
      requiredNotice: requiredNotice,
      notes: notes)
  }

  public static func skippedReport(
    suiteCase: TatwoWebArenaCaseID,
    modelSlug: String,
    reason: String
  ) -> TatwoWebArenaEvaluationReport {
    let weights = scoreWeights(for: suiteCase)
    return TatwoWebArenaEvaluationReport(
      suiteCase: suiteCase,
      modelSlug: normalizedModelSlug(modelSlug),
      modelFolderName: folderName(for: modelSlug),
      status: .skipped,
      scoreWeights: weights,
      scoreInput: .zero,
      finalScore: 0,
      buildSucceeded: false,
      webCheckErrors: 0,
      webCheckWarnings: 0,
      desktopScreenshotPresent: false,
      mobileScreenshotPresent: false,
      visualAccepted: false,
      engineeringPassed: false,
      uiUJPassed: false,
      requiredNotice: "skipped: \(reason)",
      notes: ["route unavailable / skipped", "no model fan-out executed", "not counted as tested evidence"])
  }

  public static func scaffoldRun(
    root: URL,
    suite: TatwoWebArenaSuiteID = .v1,
    runID: String,
    models: [String] = defaultModelSlugs
  ) throws -> TatwoWebArenaRunReceipt {
    let plan = plan(suite: suite, runID: runID, models: models)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    var created: [String] = []
    for suiteCase in plan.cases {
      for model in suiteCase.models {
        let folder = root.appendingPathComponent(model.relativeFolderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: folder.appendingPathComponent("generated-project", isDirectory: true),
          withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: folder.appendingPathComponent("final-submission", isDirectory: true),
          withIntermediateDirectories: true)
        try "".write(
          to: folder.appendingPathComponent("generated-project/.gitkeep"),
          atomically: true,
          encoding: .utf8)
        try generatedProjectReadme(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("generated-project/README.md"),
          atomically: true,
          encoding: .utf8)
        try generatedProjectManifestJSON(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("generated-project/arena-project-manifest.json"),
          atomically: true,
          encoding: .utf8)

        try suiteCase.prompt.write(
          to: folder.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        try goalContractMarkdown(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("goal-contract.md"), atomically: true, encoding: .utf8)
        try planMarkdown(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try loopLedgerJSON(model: model, suiteCase: suiteCase, branch: false).write(
          to: folder.appendingPathComponent("loop-ledger.json"), atomically: true, encoding: .utf8)
        try branchOptimizationMarkdown(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("branch-optimization-plan.md"), atomically: true, encoding: .utf8)
        try loopLedgerJSON(model: model, suiteCase: suiteCase, branch: true).write(
          to: folder.appendingPathComponent("branch-loop-ledger.json"), atomically: true, encoding: .utf8)
        try toolChoiceLedgerJSON(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("tool-choice-ledger.json"), atomically: true, encoding: .utf8)
        try receiptIndexJSON(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("receipt-index.json"), atomically: true, encoding: .utf8)
        try sealJSON(model: model, suiteCase: suiteCase, sealed: false).write(
          to: folder.appendingPathComponent("final-submission/seal.json"), atomically: true, encoding: .utf8)
        try modelOutputMarkdown(model: model, suiteCase: suiteCase).write(
          to: folder.appendingPathComponent("model-output.md"), atomically: true, encoding: .utf8)
        try buildLog(model: model).write(
          to: folder.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
        try webCheckPlaceholderJSON(model: model).write(
          to: folder.appendingPathComponent("web-check-report.json"), atomically: true,
          encoding: .utf8)
        try placeholderPNG.write(to: folder.appendingPathComponent("screenshot-desktop.png"), options: .atomic)
        try placeholderPNG.write(to: folder.appendingPathComponent("screenshot-mobile.png"), options: .atomic)

        let report: TatwoWebArenaEvaluationReport =
          model.status == .skipped
          ? skippedReport(
            suiteCase: suiteCase.id,
            modelSlug: model.slug,
            reason: model.statusReason)
          : evaluate(
            suiteCase: suiteCase.id,
            modelSlug: model.slug,
            buildSucceeded: false,
            webCheckErrors: 0,
            webCheckWarnings: 0,
            desktopScreenshotPresent: false,
            mobileScreenshotPresent: false,
            visualAccepted: false,
            scoreInput: .zero)
        let reportData = try encoder.encode(report)
        try reportData.write(to: folder.appendingPathComponent("評分報告.json"), options: .atomic)
        try reportMarkdown(report).write(
          to: folder.appendingPathComponent("評分報告.md"), atomically: true, encoding: .utf8)
        created.append(model.relativeFolderPath)
      }
    }
    _ = try writeRunSummaryArtifacts(root: root, runID: plan.runID)

    return TatwoWebArenaRunReceipt(
      suite: suite,
      runID: plan.runID,
      rootRelativePath: rootRelativePath,
      createdModelFolders: created,
      modelFanoutExecuted: false,
      hostMutationAllowed: false,
      status: "scaffolded_only",
      notes: [
        "created fixed folder/file scaffold for Web Arena v1",
        "this is only the test room; use web-arena run --live --models <model> for real model dispatch",
        "no external model fan-out executed; routes must be authorized separately",
        "placeholder screenshots are not visual evidence; reports remain UI/UJ not passed",
        "all sandbox submissions must obey plan+loops+goal mainline/branch protocol and max 5 goal execution cycles",
      ])
  }

  public static func runSummary(
    root: URL, runID: String,
    signingKey: String? = ProcessInfo.processInfo.environment["TATWO_ARENA_SEAL_KEY"]
  ) throws -> TatwoWebArenaRunSummary {
    let safeRunID = sanitizedRunID(runID)
    let runRoot = root.appendingPathComponent(rootRelativePath, isDirectory: true)
      .appendingPathComponent(safeRunID, isDirectory: true)
    let decoder = JSONDecoder()
    var caseSummaries: [TatwoWebArenaCaseSummary] = []
    var missing: [String] = []
    var allReports: [TatwoWebArenaEvaluationReport] = []
    var sealVerifiedReportCount = 0
    var excludedUnsealedReportCount = 0
    var verifiedByModel: [String: (count: Int, score: Int)] = [:]
    // Phase 3b (縮減版): a configured grader key marks this a formal graded run — unsealed
    // reports then drop out of the ranking aggregation entirely. Keyless runs (考試場外
    // 隨手測 / scaffold) keep the lenient count-everything behavior.
    let enforceSealExclusion = !(signingKey ?? "").isEmpty

    for suiteCase in suiteCases(.v1) {
      var reports: [TatwoWebArenaEvaluationReport] = []
      let caseRoot = runRoot.appendingPathComponent(suiteCase.folderName, isDirectory: true)
      let modelFolders =
        (try? FileManager.default.contentsOfDirectory(
          at: caseRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
      for modelFolder in modelFolders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let isDir = (try? modelFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard isDir else { continue }
        let reportURL = modelFolder.appendingPathComponent("評分報告.json")
        if let data = try? Data(contentsOf: reportURL),
          let report = try? decoder.decode(TatwoWebArenaEvaluationReport.self, from: data)
        {
          // Phase 3: a report is only trustworthy if its submission is sealed and the seal
          // still verifies. Model-written 評分報告.json over an unsealed / tampered
          // generated-project is counted separately so a forged score can't pass as truth.
          let verified = isReportSealVerified(
            modelFolder: modelFolder, decoder: decoder, signingKey: signingKey)
          if enforceSealExclusion && !verified {
            excludedUnsealedReportCount += 1
            continue
          }
          reports.append(report)
          allReports.append(report)
          if verified {
            sealVerifiedReportCount += 1
            var acc = verifiedByModel[report.modelFolderName] ?? (count: 0, score: 0)
            acc.count += 1
            acc.score += report.finalScore
            verifiedByModel[report.modelFolderName] = acc
          }
        } else {
          missing.append("\(suiteCase.folderName)/\(modelFolder.lastPathComponent)/評分報告.json")
        }
      }
      caseSummaries.append(
        TatwoWebArenaCaseSummary(
          caseID: suiteCase.id,
          folderName: suiteCase.folderName,
          reports: reports))
    }

    let totals = Dictionary(grouping: allReports, by: \.modelFolderName).map { model, reports in
      let total = reports.reduce(0) { $0 + $1.finalScore }
      let blocked = reports.filter { $0.status != .passed }.count
      let verified = verifiedByModel[model] ?? (count: 0, score: 0)
      return TatwoWebArenaModelTotal(
        modelFolderName: model,
        reportCount: reports.count,
        totalScore: total,
        averageScore: reports.isEmpty ? 0 : Double(total) / Double(reports.count),
        blockedCount: blocked,
        sealVerifiedReportCount: verified.count,
        sealVerifiedScore: verified.score)
    }
    .sorted { lhs, rhs in
      // Phase 3b trustworthy ranking: seal-verified score first (a forged/unsealed report
      // contributes 0), then raw average, then name. Scaffold data (no seals) all score 0
      // here and gracefully falls back to the average-score order.
      if lhs.sealVerifiedScore != rhs.sealVerifiedScore { return lhs.sealVerifiedScore > rhs.sealVerifiedScore }
      if lhs.averageScore == rhs.averageScore { return lhs.modelFolderName < rhs.modelFolderName }
      return lhs.averageScore > rhs.averageScore
    }

    return TatwoWebArenaRunSummary(
      runID: safeRunID,
      rootRelativePath: rootRelativePath,
      reportCount: allReports.count,
      cases: caseSummaries,
      modelTotals: totals,
      missingReports: missing,
      sealVerifiedReportCount: sealVerifiedReportCount,
      excludedUnsealedReportCount: excludedUnsealedReportCount)
  }

  /// A submission is seal-verified when `final-submission/seal.json` is sealed and the
  /// `generated-project/` directory still matches the recorded hashes.
  static func isReportSealVerified(
    modelFolder: URL, decoder: JSONDecoder,
    signingKey: String? = ProcessInfo.processInfo.environment["TATWO_ARENA_SEAL_KEY"]
  ) -> Bool {
    let sealURL = modelFolder.appendingPathComponent("final-submission/seal.json")
    guard let sealData = try? Data(contentsOf: sealURL),
      let seal = try? decoder.decode(TatwoArenaSubmissionSeal.self, from: sealData),
      seal.sealed
    else { return false }
    let submissionDir = modelFolder.appendingPathComponent("generated-project", isDirectory: true)
    // When a grader key is configured, verify also enforces provenance (a self-sealed
    // submission without the key fails). Without a key it stays tamper-evidence only.
    let verification = try? TatwoArenaSubmissionSealer.verify(
      directory: submissionDir, against: seal, signingKey: signingKey)
    return verification?.verified == true
  }

  public static func cleanupPlan(
    root: URL,
    olderThanDays: Int,
    now: Date = Date(),
    dryRun: Bool = true
  ) throws -> TatwoWebArenaCleanupPlan {
    let arenaRoot = root.appendingPathComponent(rootRelativePath, isDirectory: true)
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: arenaRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
    let cutoff = Calendar(identifier: .gregorian).date(
      byAdding: .day, value: -olderThanDays, to: now) ?? now
    let candidates = entries.compactMap { url -> TatwoWebArenaCleanupCandidate? in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        return nil
      }
      let runID = url.lastPathComponent
      let runDate = dateFromRunID(runID)
        ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      guard let runDate, runDate < cutoff else { return nil }
      return TatwoWebArenaCleanupCandidate(
        runID: runID,
        relativePath: "\(rootRelativePath)/\(runID)",
        reason: "older than \(olderThanDays)d; dry-run only keeps summary.json / 總評分報告.md policy")
    }
    .sorted { $0.runID < $1.runID }

    return TatwoWebArenaCleanupPlan(
      rootRelativePath: rootRelativePath,
      olderThanDays: olderThanDays,
      dryRun: dryRun,
      hostMutationAllowed: false,
      deletionExecuted: false,
      candidates: candidates,
      keepPolicy: [
        "先 dry-run；未經明確授權不刪 generated-project、screenshots、build artifacts。",
        "可保留 summary.json / 總評分報告.md，刪除大型生成物需由 CLI host 額外執行。",
        "不得掃到主專案、skills、Codex auth、gateway runtime。",
	      ])
  }

  @discardableResult
  public static func writeRunSummaryArtifacts(root: URL, runID: String) throws -> TatwoWebArenaRunSummary {
    let summary = try runSummary(root: root, runID: runID)
    let runRoot = root.appendingPathComponent(rootRelativePath, isDirectory: true)
      .appendingPathComponent(summary.runID, isDirectory: true)
    try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(summary).write(to: runRoot.appendingPathComponent("summary.json"), options: .atomic)
    try runSummaryMarkdown(summary).write(
      to: runRoot.appendingPathComponent("總評分報告.md"),
      atomically: true,
      encoding: .utf8)
    return summary
  }

  public static func suiteFromString(_ raw: String?) -> TatwoWebArenaSuiteID {
    TatwoWebArenaSuiteID(rawValue: raw?.lowercased() ?? "v1") ?? .v1
  }

  public static func normalizeModels(_ raw: [String]) -> [String] {
    let flattened = raw.flatMap { value in
      value.split(separator: ",").map { String($0) }
    }
    let models = uniquePreservingOrder(flattened.map(normalizedModelSlug).filter { !$0.isEmpty })
    return models.isEmpty ? defaultModelSlugs : models
  }

  public static func normalizedModelSlug(_ raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    switch s {
    case "gpt55", "gpt-5-5": return "gpt-5.5"
    case "gpt54", "gpt-5-4": return "gpt-5.4"
    case "sonnet5", "claude-sonnet-5": return "sonnet-5"
    case "fable5": return "fable-5"
    case "opus5", "opus-5", "claude-opus-5", "opus": return "opus-5"
    case "minimax", "minimax-m3": return "minimax-m3"
    case "grok", "grok-build": return "grok-build"
    default: return s
    }
  }

  public static func folderName(for raw: String) -> String {
    switch normalizedModelSlug(raw) {
    case "gpt-5.5": return "GPT5.5"
    case "gpt-5.4": return "GPT5.4"
    case "sonnet-5", "claude-sonnet-5": return "SONNET5"
    case "fable-5": return "FABLE5"
    case "opus-5": return "OPUS5"
    case "minimax-m3", "minimax": return "MINIMAX-M3"
    case "grok-build", "grok": return "GROK"
    default:
      let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      var safe = cleaned.replacingOccurrences(
        of: "[^A-Z0-9._-]", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
      while safe.contains("..") {
        safe = safe.replacingOccurrences(of: "..", with: ".")
      }
      safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
      return safe.isEmpty ? "UNKNOWN" : String(safe.prefix(64))
    }
  }

  public static func isUnavailableModelRoute(_ raw: String) -> Bool {
    let normalized = normalizedModelSlug(raw)
    return normalized.hasPrefix("fable-5-")
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

  public static func scoreWeights(for suiteCase: TatwoWebArenaCaseID) -> TatwoWebArenaScoreWeights {
    switch suiteCase {
    case .tattoo:
      return TatwoWebArenaScoreWeights(
        topicUnderstanding: 25, functionality: 20, uiUXAesthetics: 30,
        engineeringQuality: 15, instructionFollowingHonesty: 10)
    case .assetLibrary3D:
      return TatwoWebArenaScoreWeights(
        topicUnderstanding: 20, functionality: 25, uiUXAesthetics: 25,
        engineeringQuality: 20, instructionFollowingHonesty: 10)
    case .pionexStyle:
      return TatwoWebArenaScoreWeights(
        topicUnderstanding: 20, functionality: 30, uiUXAesthetics: 20,
        engineeringQuality: 20, instructionFollowingHonesty: 10)
    }
  }

  private static func modelPlan(
    slug: String,
    runID: String,
    caseFolderName: String
  ) -> TatwoWebArenaModelPlan {
    let folder = folderName(for: slug)
    let normalized = normalizedModelSlug(slug)
    let unavailable = isUnavailableModelRoute(normalized)
    let status: TatwoWebArenaModelStatus = unavailable ? .skipped : .planned
    let reason = unavailable
      ? "route unavailable / skipped until Fable 5 is configured"
      : "planned; route availability checked at execution time"
    let relative = "\(rootRelativePath)/\(runID)/\(caseFolderName)/\(folder)"
    return TatwoWebArenaModelPlan(
      slug: normalized,
      displayName: folder,
      folderName: folder,
      status: status,
      statusReason: reason,
      relativeFolderPath: relative,
      requiredFiles: requiredModelFiles)
  }

  private struct CaseTemplate {
    let id: TatwoWebArenaCaseID
    let folderName: String
    let title: String
    let benchmarkPurpose: String
    let scoreWeights: TatwoWebArenaScoreWeights
    let scoringFocus: [String]
    let safetyRules: [String]
    let prompt: String
  }

  private static func suiteCases(_ suite: TatwoWebArenaSuiteID) -> [CaseTemplate] {
    switch suite {
    case .v1:
      return [tattooCase, assetCase, pionexCase]
    }
  }

  private static let tattooCase = CaseTemplate(
    id: .tattoo,
    folderName: "01-刺青網頁",
    title: "刺青網頁",
    benchmarkPurpose: "測試模型能否理解刺青產業，將作品、師傅、預約、信任感轉成品牌設計。",
    scoreWeights: scoreWeights(for: .tattoo),
    scoringFocus: [
      "刺青店需求：作品展示、風格分類、預約、師傅介紹、FAQ、信任感",
      "品牌質感、留白、作品焦點與產業語氣",
      "客人能看懂流程並願意預約",
    ],
    safetyRules: ["不得使用真實店家商標或未授權作品圖", "不得偽造醫療/衛生認證"],
    prompt: """
      # TATWO Web Arena v1 / 刺青網頁

      請建立一個高質感刺青工作室網站。重點不是通用模板，而是把刺青產業需求轉成可預約、可信任、有作品焦點的設計。

      必須包含：作品展示、風格分類、師傅介紹、預約 CTA、流程說明、FAQ、衛生與照護提醒。
      驗收會看：產業理解、功能完整度、UI/UX 美感、工程品質、指令遵循與誠實度。
      """
  )

  private static let assetCase = CaseTemplate(
    id: .assetLibrary3D,
    folderName: "02-3D資產收納網頁",
    title: "3D 資產收納網頁",
    benchmarkPurpose: "測試模型創造力與產品規劃能力，能否自行發想 3D asset library 的工具型 UX。",
    scoreWeights: scoreWeights(for: .assetLibrary3D),
    scoringFocus: [
      "分類、標籤、搜尋、預覽、版本、授權、收藏等 asset 管理概念",
      "給創作者、建模師、專案團隊使用的 dashboard / grid / detail page",
      "兼顧美感與工具性，不能只做漂亮空殼",
    ],
    safetyRules: ["不得引用未授權 3D 資產", "不得假裝連接真實雲端素材庫"],
    prompt: """
      # TATWO Web Arena v1 / 3D 資產收納網頁

      請自行設計一個 3D asset library / 資產收納網頁。目標用戶是創作者、建模師與小型專案團隊。

      必須包含：dashboard、資產 grid、搜尋/標籤/分類、預覽、版本、授權、收藏、專案使用狀態與 detail page 概念。
      驗收會看：主題發想、架構創造、功能完整度、UI/UX 美感、工程品質、指令遵循與誠實度。
      """
  )

  private static let pionexCase = CaseTemplate(
    id: .pionexStyle,
    folderName: "03-Pionex交易所複製",
    title: "Pionex-style 交易所複製",
    benchmarkPurpose: "測試模型觀察複雜金融產品後，能否還原功能結構、分頁與資訊密度。",
    scoreWeights: scoreWeights(for: .pionexStyle),
    scoringFocus: [
      "首頁、行情、交易、Bot、資產、登入 CTA 等常見交易所結構",
      "交易機器人、Grid Bot、Copy Bot、行情表、交易入口",
      "公開頁面可觀察到的 trading-bot exchange 定位、Futures Grid / Copy Bot 區塊與信任數據節奏；只取功能結構，不取品牌素材",
      "高資訊密度但不混亂；表格、價格、狀態、卡片、風險提示清楚",
    ],
    safetyRules: [
      "只做內部 benchmark，不使用官方 logo、商標素材或直接照搬文案",
      "不得建立真實登入、真交易、下單、API key 或資金功能",
      "必須避免讓使用者誤認為官方交易所",
    ],
    prompt: """
      # TATWO Web Arena v1 / Pionex-style 交易所複製

      請建立一個 Pionex-style 的交易所產品結構 benchmark。參考公開功能類型，但不要使用官方 logo、商標素材、原文案或官方品牌名稱。

      可觀察但不可照抄的公開頁面線索：內建交易機器人定位、Futures Grid / Grid Bot、Copy Bot、交易量/使用者/年資等信任數據節奏。
      必須包含：首頁、行情、交易、Bot、資產、登入 CTA、交易機器人卡片、行情表、風險提示。
      禁止：真實登入、真交易、API key、下單、官方品牌冒充。
      驗收會看：功能觀察、分頁理解、複雜 UI 還原、資訊密度控制、工程品質、指令遵循與誠實度。
      """
  )

  private static func clamp(_ value: Int, max: Int) -> Int {
    Swift.max(0, Swift.min(value, max))
  }

  private static func goalContractMarkdown(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    """
    # Goal Contract

    - protocol: plan+loops+goal-主線
    - case: \(suiteCase.folderName)
    - model: \(model.folderName)
    - maxGoalExecutionCycles: \(TatwoArenaPolicyFactory.goalCyclePolicy.maxGoalExecutionCycles)

    ## Main goal
    Complete this sandbox case as a sealed model submission.

    ## Non-goals
    - Do not modify tests, hidden tests, scorer, seal, or protected files.
    - Do not use unregistered MCP / skills as score evidence.
    - Do not patch after final submission is sealed.

    ## Pass boundary
    The model may plan freely, but implementation execution is capped at 5 goal cycles. Grading starts after all sandbox checks finish.
    """
  }

  private static func planMarkdown(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    """
    # Plan

    - protocol: plan+loops+goal-主線
    - model: \(model.folderName)
    - case: \(suiteCase.folderName)

    The real model must write its own plan here before implementation. Plan revisions are unlimited, but they do not reset the 5-cycle goal execution cap.
    """
  }

  private static func branchOptimizationMarkdown(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    """
    # Branch Optimization Plan

    - protocol: plan+loops+goal-支線優化
    - model: \(model.folderName)
    - case: \(suiteCase.folderName)

    The model may choose where branch optimization is useful. It must explain which branch loops were opened, why, and how their receipts merge back to the mainline.
    """
  }

  private static func loopLedgerJSON(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan,
    branch: Bool
  ) -> String {
    let object: [String: Any] = [
      "schema": branch ? "TatwoArenaBranchLoopLedgerV1" : "TatwoArenaMainlineLoopLedgerV1",
      "protocol": branch ? "plan+loops+goal-支線優化" : "plan+loops+goal-主線",
      "caseID": suiteCase.id.rawValue,
      "caseFolderName": suiteCase.folderName,
      "modelSlug": model.slug,
      "modelFolderName": model.folderName,
      "maxGoalExecutionCycles": TatwoArenaPolicyFactory.goalCyclePolicy.maxGoalExecutionCycles,
      "planRevisionLimit": TatwoArenaPolicyFactory.goalCyclePolicy.planRevisionLimit,
      "loopLedgerEntryLimit": TatwoArenaPolicyFactory.goalCyclePolicy.loopLedgerEntryLimit,
      "entries": [] as [Any],
      "note": "Real model runs must append loop receipts here; planning entries are unlimited but implementation cycles are capped at 5."
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func toolChoiceLedgerJSON(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    let protocolSpec = TatwoArenaPolicyFactory.planLoopGoalProtocol()
    let object: [String: Any] = [
      "schema": "TatwoArenaToolChoiceLedgerV1",
      "caseID": suiteCase.id.rawValue,
      "modelSlug": model.slug,
      "modelFolderName": model.folderName,
      "modelMayChooseTools": true,
      "allowedRegistryEntryIDs": protocolSpec.allowedRegistryEntryIDs,
      "rule": protocolSpec.modelToolChoiceRule,
      "entries": [] as [Any]
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func receiptIndexJSON(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    let object: [String: Any] = [
      "schema": "TatwoArenaReceiptIndexV1",
      "caseID": suiteCase.id.rawValue,
      "modelSlug": model.slug,
      "modelFolderName": model.folderName,
      "scorePlanLoopsGoalAfterAllSandboxTests": true,
      "receipts": [] as [Any]
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func sealJSON(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan,
    sealed: Bool
  ) -> String {
    let object: [String: Any] = [
      "schema": "TatwoArenaSubmissionSealV1",
      "caseID": suiteCase.id.rawValue,
      "modelSlug": model.slug,
      "modelFolderName": model.folderName,
      "sealed": sealed,
      "editable": !sealed,
      "maxGoalExecutionCycles": TatwoArenaPolicyFactory.goalCyclePolicy.maxGoalExecutionCycles,
      "postSealMutationPolicy": TatwoArenaPolicyFactory.goalCyclePolicy.postSealMutationPolicy,
      "fileHashes": [:] as [String: String],
      "note": "When a real model submits final output, this seal must record hashes. After sealed=true, any hash change invalidates the submission."
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func modelOutputMarkdown(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    """
    # Model Output

    - case: \(suiteCase.folderName)
    - model: \(model.folderName)
    - status: \(model.status.rawValue)
    - reason: \(model.statusReason)

    v1 scaffold does not execute paid/API model fan-out by default. 真正模型輸出需由 Work OS contract 與使用者授權後寫入本檔。
    """
  }

  private static func buildLog(model: TatwoWebArenaModelPlan) -> String {
    """
    TATWO Web Arena scaffold
    model=\(model.folderName)
    status=not-built
    reason=no generated project executed yet; build receipt pending
    """
  }

  private static func webCheckPlaceholderJSON(model: TatwoWebArenaModelPlan) -> String {
    let object: [String: Any] = [
      "ok": false,
      "schema": "TatwoWebArenaWebCheckPlaceholderV1",
      "model": model.folderName,
      "summary": [
        "errorCount": 0,
        "warningCount": 0,
        "total": 0,
        "categories": [:] as [String: Any],
      ],
      "degraded": "web-check not run yet",
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func generatedProjectReadme(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    """
    # Generated Project Scaffold

    - case: \(suiteCase.folderName)
    - model: \(model.folderName)
    - status: \(model.status.rawValue)

    This folder is a TATWO Web Arena generated-project scaffold, not model-generated evidence.
    v1 creates this folder so every benchmark lane has a stable place for future model output,
    build logs, web-check receipts, screenshots, and scoring reports.

    Do not count this scaffold as a model benchmark score. 真正模型輸出需由 Work OS contract、
    明確模型 route、使用者授權與預算上限後寫入。
    """
  }

  private static func generatedProjectManifestJSON(
    model: TatwoWebArenaModelPlan,
    suiteCase: TatwoWebArenaCasePlan
  ) -> String {
    let object: [String: Any] = [
      "schema": "TatwoWebArenaGeneratedProjectManifestV1",
      "caseID": suiteCase.id.rawValue,
      "caseFolderName": suiteCase.folderName,
      "modelSlug": model.slug,
      "modelFolderName": model.folderName,
      "status": model.status.rawValue,
      "generatedProjectKind": "scaffold",
      "modelFanoutExecuted": false,
      "scoreEligible": false,
      "notes": [
        "not model-generated evidence",
        "future authorized model output must replace or extend this scaffold",
        "Pionex-style benchmark remains internal and must not use official logo, trademark assets, copied copy, real login, or real trading",
      ],
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func reportMarkdown(_ report: TatwoWebArenaEvaluationReport) -> String {
    """
    # 評分報告

    - schema: \(report.schema)
    - case: \(report.suiteCase.rawValue)
    - model: \(report.modelFolderName)
    - status: \(report.status.rawValue)
    - finalScore: \(report.finalScore)/100
    - engineeringPassed: \(report.engineeringPassed)
    - uiUJPassed: \(report.uiUJPassed)

    ## 必要註記
    \(report.requiredNotice)

    ## Notes
    \(report.notes.map { "- \($0)" }.joined(separator: "\n"))
    """
  }

  private static func runSummaryMarkdown(_ summary: TatwoWebArenaRunSummary) -> String {
    let modelRows = summary.modelTotals.map { total in
      "- \(total.modelFolderName): reports \(total.reportCount), average \(String(format: "%.1f", total.averageScore)), blocked \(total.blockedCount)"
    }.joined(separator: "\n")
    let caseRows = summary.cases.map { suiteCase in
      "- \(suiteCase.folderName): \(suiteCase.reports.count) reports"
    }.joined(separator: "\n")
    let missingRows = summary.missingReports.isEmpty
      ? "- none"
      : summary.missingReports.map { "- \($0)" }.joined(separator: "\n")

    return """
    # TATWO Web Arena v1 總評分報告

    - runID: \(summary.runID)
    - reportCount: \(summary.reportCount)
    - root: \(summary.rootRelativePath)

    ## 重要聲明

    目前 v1 scaffold 產物不代表模型實測通過。模型分數只有在 generated-project 由明確授權的模型 route 產生、build/web-check/screenshot/人工視覺驗收收據齊全後，才可列入 arena-tested 證據。

    ## Case reports

    \(caseRows)

    ## Model totals

    \(modelRows.isEmpty ? "- none" : modelRows)

    ## Missing reports

    \(missingRows)
    """
  }

  private static let placeholderPNG: Data =
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")
    ?? Data()

  private static func sanitizedRunID(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? TatwoWebArenaRuntime.defaultRunID() : trimmed
    let safe = base.replacingOccurrences(
      of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
      .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    if safe.isEmpty { return TatwoWebArenaRuntime.defaultRunID() }
    var clipped = String(safe.prefix(80))
    while clipped.contains("..") {
      clipped = clipped.replacingOccurrences(of: "..", with: ".")
    }
    let final = clipped.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    return final.isEmpty ? TatwoWebArenaRuntime.defaultRunID() : final
  }

  private static func dateFromRunID(_ runID: String) -> Date? {
    guard runID.count >= 8 else { return nil }
    let prefix = String(runID.prefix(8))
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return formatter.date(from: prefix)
  }
}
