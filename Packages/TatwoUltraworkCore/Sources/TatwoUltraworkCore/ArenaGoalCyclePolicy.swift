import Foundation

public enum TatwoArenaGradingState: String, Codable, Sendable, CaseIterable, Equatable {
  case implementationOpen = "implementation_open"
  case readyForGrading = "ready_for_grading"
  case invalidSubmission = "invalid_submission"
}

public struct TatwoArenaGoalCyclePolicy: Codable, Sendable, Equatable {
  public let schema: String
  public let maxGoalExecutionCycles: Int
  public let planRevisionLimit: String
  public let loopLedgerEntryLimit: String
  public let finalSubmissionSealRequired: Bool
  public let postSealMutationPolicy: String
  public let gradingTriggerRules: [String]
  public let plainRule: String

  public init(
    schema: String = "TatwoArenaGoalCyclePolicyV1",
    maxGoalExecutionCycles: Int,
    planRevisionLimit: String,
    loopLedgerEntryLimit: String,
    finalSubmissionSealRequired: Bool,
    postSealMutationPolicy: String,
    gradingTriggerRules: [String],
    plainRule: String
  ) {
    self.schema = schema
    self.maxGoalExecutionCycles = max(1, maxGoalExecutionCycles)
    self.planRevisionLimit = planRevisionLimit
    self.loopLedgerEntryLimit = loopLedgerEntryLimit
    self.finalSubmissionSealRequired = finalSubmissionSealRequired
    self.postSealMutationPolicy = postSealMutationPolicy
    self.gradingTriggerRules = gradingTriggerRules
    self.plainRule = plainRule
  }
}

public struct TatwoArenaPlanLoopGoalProtocol: Codable, Sendable, Equatable {
  public let schema: String
  public let appliesToAllSandboxes: Bool
  public let mainlineName: String
  public let branchName: String
  public let mainlineRequiredArtifacts: [String]
  public let branchRequiredArtifacts: [String]
  public let modelToolChoiceRule: String
  public let allowedRegistryEntryIDs: [String]
  public let forbiddenToolRules: [String]
  public let gradingRule: String
  public let scoreAfterAllSandboxTests: Bool

  public init(
    schema: String = "TatwoArenaPlanLoopGoalProtocolV1",
    appliesToAllSandboxes: Bool,
    mainlineName: String,
    branchName: String,
    mainlineRequiredArtifacts: [String],
    branchRequiredArtifacts: [String],
    modelToolChoiceRule: String,
    allowedRegistryEntryIDs: [String],
    forbiddenToolRules: [String],
    gradingRule: String,
    scoreAfterAllSandboxTests: Bool
  ) {
    self.schema = schema
    self.appliesToAllSandboxes = appliesToAllSandboxes
    self.mainlineName = mainlineName
    self.branchName = branchName
    self.mainlineRequiredArtifacts = mainlineRequiredArtifacts
    self.branchRequiredArtifacts = branchRequiredArtifacts
    self.modelToolChoiceRule = modelToolChoiceRule
    self.allowedRegistryEntryIDs = allowedRegistryEntryIDs
    self.forbiddenToolRules = forbiddenToolRules
    self.gradingRule = gradingRule
    self.scoreAfterAllSandboxTests = scoreAfterAllSandboxTests
  }
}

public struct TatwoArenaGoalCycleAssessment: Codable, Sendable, Equatable {
  public let schema: String
  public let goalExecutionCycles: Int
  public let maxGoalExecutionCycles: Int
  public let remainingExecutionCycles: Int
  public let finalSubmissionSealed: Bool
  public let fileHashesChangedAfterSeal: Bool
  public let planRevisionLimit: String
  public let loopLedgerEntryLimit: String
  public let state: TatwoArenaGradingState
  public let mustEnterGrading: Bool
  public let canContinueImplementation: Bool
  public let decisionCode: String
  public let decisionText: String

  public init(
    schema: String = "TatwoArenaGoalCycleAssessmentV1",
    goalExecutionCycles: Int,
    maxGoalExecutionCycles: Int,
    remainingExecutionCycles: Int,
    finalSubmissionSealed: Bool,
    fileHashesChangedAfterSeal: Bool,
    planRevisionLimit: String,
    loopLedgerEntryLimit: String,
    state: TatwoArenaGradingState,
    mustEnterGrading: Bool,
    canContinueImplementation: Bool,
    decisionCode: String,
    decisionText: String
  ) {
    self.schema = schema
    self.goalExecutionCycles = max(0, goalExecutionCycles)
    self.maxGoalExecutionCycles = max(1, maxGoalExecutionCycles)
    self.remainingExecutionCycles = max(0, remainingExecutionCycles)
    self.finalSubmissionSealed = finalSubmissionSealed
    self.fileHashesChangedAfterSeal = fileHashesChangedAfterSeal
    self.planRevisionLimit = planRevisionLimit
    self.loopLedgerEntryLimit = loopLedgerEntryLimit
    self.state = state
    self.mustEnterGrading = mustEnterGrading
    self.canContinueImplementation = canContinueImplementation
    self.decisionCode = decisionCode
    self.decisionText = decisionText
  }
}

public struct TatwoArenaPlanLoopGoalScore: Codable, Sendable, Equatable {
  public let schema: String
  public let goalDecomposition: Int
  public let mainlineDiscipline: Int
  public let branchOptimization: Int
  public let loopReceiptQuality: Int
  public let toolChoiceFromRegistry: Int
  public let stopAndSealDiscipline: Int
  public let total: Int
  public let notes: [String]

  public init(
    schema: String = "TatwoArenaPlanLoopGoalScoreV1",
    goalDecomposition: Int,
    mainlineDiscipline: Int,
    branchOptimization: Int,
    loopReceiptQuality: Int,
    toolChoiceFromRegistry: Int,
    stopAndSealDiscipline: Int,
    notes: [String]
  ) {
    self.schema = schema
    self.goalDecomposition = Self.clamp(goalDecomposition, max: 20)
    self.mainlineDiscipline = Self.clamp(mainlineDiscipline, max: 20)
    self.branchOptimization = Self.clamp(branchOptimization, max: 15)
    self.loopReceiptQuality = Self.clamp(loopReceiptQuality, max: 20)
    self.toolChoiceFromRegistry = Self.clamp(toolChoiceFromRegistry, max: 10)
    self.stopAndSealDiscipline = Self.clamp(stopAndSealDiscipline, max: 15)
    self.total = self.goalDecomposition + self.mainlineDiscipline + self.branchOptimization
      + self.loopReceiptQuality + self.toolChoiceFromRegistry + self.stopAndSealDiscipline
    self.notes = notes
  }

  private static func clamp(_ value: Int, max: Int) -> Int {
    Swift.max(0, Swift.min(value, max))
  }
}

public struct TatwoArenaPlanLoopGoalScoreReport: Codable, Sendable, Equatable {
  public let schema: String
  public let modelSlug: String
  public let expectedSandboxTests: Int
  public let completedSandboxTests: Int
  public let missingSandboxTests: [String]
  public let allSandboxTestsComplete: Bool
  public let scoreAfterAllSandboxTests: Bool
  public let modelSelfEvaluationAccepted: Bool
  public let goalCycleAssessment: TatwoArenaGoalCycleAssessment
  public let canScorePlanLoopGoal: Bool
  public let decisionCode: String
  public let decisionText: String
  public let presentArtifacts: [String]
  public let missingRequiredArtifacts: [String]
  public let toolChoicesAllRegistered: Bool
  public let inputVerificationMode: String
  public let inputsVerifiedFromDisk: Bool
  public let inputsAssertedByCaller: Bool
  public let scoreEligibleReceiptPresent: Bool
  public let scoreUsableAsGateEvidence: Bool
  public let score: TatwoArenaPlanLoopGoalScore?
  public let notes: [String]

  public init(
    schema: String = "TatwoArenaPlanLoopGoalScoreReportV1",
    modelSlug: String,
    expectedSandboxTests: Int,
    completedSandboxTests: Int,
    missingSandboxTests: [String],
    allSandboxTestsComplete: Bool,
    scoreAfterAllSandboxTests: Bool,
    modelSelfEvaluationAccepted: Bool,
    goalCycleAssessment: TatwoArenaGoalCycleAssessment,
    canScorePlanLoopGoal: Bool,
    decisionCode: String,
    decisionText: String,
    presentArtifacts: [String],
    missingRequiredArtifacts: [String],
    toolChoicesAllRegistered: Bool,
    inputVerificationMode: String = "caller_asserted",
    inputsVerifiedFromDisk: Bool = false,
    inputsAssertedByCaller: Bool = true,
    scoreEligibleReceiptPresent: Bool = false,
    scoreUsableAsGateEvidence: Bool = false,
    score: TatwoArenaPlanLoopGoalScore?,
    notes: [String]
  ) {
    self.schema = schema
    self.modelSlug = modelSlug
    self.expectedSandboxTests = max(0, expectedSandboxTests)
    self.completedSandboxTests = max(0, completedSandboxTests)
    self.missingSandboxTests = missingSandboxTests
    self.allSandboxTestsComplete = allSandboxTestsComplete
    self.scoreAfterAllSandboxTests = scoreAfterAllSandboxTests
    self.modelSelfEvaluationAccepted = modelSelfEvaluationAccepted
    self.goalCycleAssessment = goalCycleAssessment
    self.canScorePlanLoopGoal = canScorePlanLoopGoal
    self.decisionCode = decisionCode
    self.decisionText = decisionText
    self.presentArtifacts = presentArtifacts
    self.missingRequiredArtifacts = missingRequiredArtifacts
    self.toolChoicesAllRegistered = toolChoicesAllRegistered
    self.inputVerificationMode = inputVerificationMode
    self.inputsVerifiedFromDisk = inputsVerifiedFromDisk
    self.inputsAssertedByCaller = inputsAssertedByCaller
    self.scoreEligibleReceiptPresent = scoreEligibleReceiptPresent
    self.scoreUsableAsGateEvidence = scoreUsableAsGateEvidence
    self.score = score
    self.notes = notes
  }
}

public enum TatwoArenaPolicyFactory {
  public static let goalCyclePolicy = TatwoArenaGoalCyclePolicy(
    maxGoalExecutionCycles: 5,
    planRevisionLimit: "unlimited",
    loopLedgerEntryLimit: "unlimited",
    finalSubmissionSealRequired: true,
    postSealMutationPolicy: "sealed submission hashes are immutable; any post-seal mutation invalidates the submission",
    gradingTriggerRules: [
      "A model may think, plan, and record loop-ledger entries without a hard count limit.",
      "Each goal may run at most 5 implementation/execution cycles before grading.",
      "Early final submission also enters grading immediately, even if fewer than 5 cycles were used.",
      "After final submission is sealed, no model/Codex/manual patch may modify the submitted files.",
      "If sealed hashes change, mark invalid_submission instead of asking the model to repair itself.",
    ],
    plainRule: "每個 goal 最多 5 次實作巡迴；plan 與 loop-ledger 不限量，但不能用無限規劃逃避封存評分。")

  public static func planLoopGoalProtocol(catalog: TatwoCatalog = .defaults)
    -> TatwoArenaPlanLoopGoalProtocol
  {
    TatwoArenaPlanLoopGoalProtocol(
      appliesToAllSandboxes: true,
      mainlineName: "plan+loops+goal-主線",
      branchName: "plan+loops+goal-支線優化",
      mainlineRequiredArtifacts: [
        "goal-contract.md",
        "plan.md",
        "loop-ledger.json",
        "mainline-decision.md",
        "final-submission/seal.json",
      ],
      branchRequiredArtifacts: [
        "branch-optimization-plan.md",
        "branch-loop-ledger.json",
        "tool-choice-ledger.json",
        "receipt-index.json",
      ],
      modelToolChoiceRule: "模型自行決定哪些環節使用哪些 MCP / skills，但只能從 Ultrawork 插件與技能 registry 選；每次選用都要寫入 tool-choice-ledger 與 receipt-index。",
      allowedRegistryEntryIDs: catalog.plugins.map(\.id).sorted(),
      forbiddenToolRules: [
        "不可使用未登記在 Ultrawork 分頁 registry 的 MCP / skill 當成有效收據。",
        "不可修改測試、hidden tests、評分器、seal.json 或 protected files 來讓自己通過。",
        "不可在 sealed 後補 patch；sealed 後變更直接 invalid_submission。",
      ],
      gradingRule: "所有沙盒測試結束後，才為模型的 plan+loops+goal 另行評分；模型自評不能直接給過。",
      scoreAfterAllSandboxTests: true)
  }

  public static func assessGoalCycle(
    goalExecutionCycles rawGoalExecutionCycles: Int,
    finalSubmissionSealed: Bool,
    fileHashesChangedAfterSeal: Bool = false,
    policy: TatwoArenaGoalCyclePolicy = goalCyclePolicy
  ) -> TatwoArenaGoalCycleAssessment {
    let cycles = max(0, rawGoalExecutionCycles)
    let remaining = max(0, policy.maxGoalExecutionCycles - cycles)

    if fileHashesChangedAfterSeal {
      return TatwoArenaGoalCycleAssessment(
        goalExecutionCycles: cycles,
        maxGoalExecutionCycles: policy.maxGoalExecutionCycles,
        remainingExecutionCycles: 0,
        finalSubmissionSealed: finalSubmissionSealed,
        fileHashesChangedAfterSeal: true,
        planRevisionLimit: policy.planRevisionLimit,
        loopLedgerEntryLimit: policy.loopLedgerEntryLimit,
        state: .invalidSubmission,
        mustEnterGrading: true,
        canContinueImplementation: false,
        decisionCode: "sealed_hash_changed_invalid",
        decisionText: "封存後檔案 hash 改變；不可補救，直接標記 invalid submission。")
    }

    if finalSubmissionSealed {
      return TatwoArenaGoalCycleAssessment(
        goalExecutionCycles: cycles,
        maxGoalExecutionCycles: policy.maxGoalExecutionCycles,
        remainingExecutionCycles: 0,
        finalSubmissionSealed: true,
        fileHashesChangedAfterSeal: false,
        planRevisionLimit: policy.planRevisionLimit,
        loopLedgerEntryLimit: policy.loopLedgerEntryLimit,
        state: .readyForGrading,
        mustEnterGrading: true,
        canContinueImplementation: false,
        decisionCode: "sealed_enter_grading",
        decisionText: "final submission 已封存；不論用了幾次巡迴，直接進入評分。")
    }

    if cycles >= policy.maxGoalExecutionCycles {
      return TatwoArenaGoalCycleAssessment(
        goalExecutionCycles: cycles,
        maxGoalExecutionCycles: policy.maxGoalExecutionCycles,
        remainingExecutionCycles: 0,
        finalSubmissionSealed: false,
        fileHashesChangedAfterSeal: false,
        planRevisionLimit: policy.planRevisionLimit,
        loopLedgerEntryLimit: policy.loopLedgerEntryLimit,
        state: .readyForGrading,
        mustEnterGrading: true,
        canContinueImplementation: false,
        decisionCode: "goal_cycle_cap_reached_enter_grading",
        decisionText: "goal 實作巡迴已達 5 次上限；停止修改並進入評分。")
    }

    return TatwoArenaGoalCycleAssessment(
      goalExecutionCycles: cycles,
      maxGoalExecutionCycles: policy.maxGoalExecutionCycles,
      remainingExecutionCycles: remaining,
      finalSubmissionSealed: false,
      fileHashesChangedAfterSeal: false,
      planRevisionLimit: policy.planRevisionLimit,
      loopLedgerEntryLimit: policy.loopLedgerEntryLimit,
      state: .implementationOpen,
      mustEnterGrading: false,
      canContinueImplementation: true,
      decisionCode: "implementation_cycle_available",
      decisionText: "尚可繼續實作巡迴；plan 與 loop-ledger 可繼續記錄，但 goal 仍最多 5 次。")
  }

  public static func scorePlanLoopGoal(
    modelSlug rawModelSlug: String,
    expectedSandboxTests rawExpectedSandboxTests: Int,
    completedSandboxTests rawCompletedSandboxTests: Int,
    missingSandboxTests rawMissingSandboxTests: [String] = [],
    goalExecutionCycles: Int,
    finalSubmissionSealed: Bool,
    fileHashesChangedAfterSeal: Bool = false,
    presentArtifacts rawPresentArtifacts: [String],
    toolChoicesAllRegistered: Bool,
    inputsVerifiedFromDisk: Bool = false,
    scoreEligibleReceiptPresent: Bool = false,
    catalog: TatwoCatalog = .defaults
  ) -> TatwoArenaPlanLoopGoalScoreReport {
    let modelSlug = rawModelSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "unknown"
      : rawModelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
    let expectedSandboxTests = max(0, rawExpectedSandboxTests)
    let completedSandboxTests = max(0, rawCompletedSandboxTests)
    let missingSandboxTests = rawMissingSandboxTests
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .sorted()
    let presentArtifacts = Array(Set(rawPresentArtifacts.map(normalizedArtifactName)))
      .filter { !$0.isEmpty }
      .sorted()
    let presentSet = Set(presentArtifacts)
    let protocolSpec = planLoopGoalProtocol(catalog: catalog)
    let requiredArtifacts =
      protocolSpec.mainlineRequiredArtifacts + protocolSpec.branchRequiredArtifacts
    let missingRequiredArtifacts = requiredArtifacts
      .filter { !hasArtifact($0, in: presentSet) }
      .sorted()
    let allSandboxTestsComplete =
      expectedSandboxTests > 0
      && completedSandboxTests >= expectedSandboxTests
      && missingSandboxTests.isEmpty
    let cycleAssessment = assessGoalCycle(
      goalExecutionCycles: goalExecutionCycles,
      finalSubmissionSealed: finalSubmissionSealed,
      fileHashesChangedAfterSeal: fileHashesChangedAfterSeal)

    let inputsAssertedByCaller = !inputsVerifiedFromDisk
    let inputVerificationMode = inputsVerifiedFromDisk
      ? "verified_from_disk"
      : "caller_asserted_not_deterministic_receipt"

    var baseNotes = [
      "plan+loops+goal 分數只在所有 sandbox 測試完成後計算。",
      "模型自評不能直接通過；只讀 artifact、seal、測試與 registry receipts。",
      "模型可自行選 MCP / skills，但有效工具只能來自 Ultrawork registry。",
    ]

    if inputsAssertedByCaller {
      baseNotes.append("此 PLG 輸入目前是 caller-asserted；不可把分數當成 gate evidence，直到 grader 從磁碟驗證 artifact、tool-choice-ledger、seal hash 與 scoreEligible。")
    }
    if !scoreEligibleReceiptPresent {
      baseNotes.append("尚未看到 scoreEligible=true 的 grader receipt；PLG 分數即使可計算，也不可作為通過收據。")
    }

    if cycleAssessment.state == .invalidSubmission {
      baseNotes.append("sealed 後 hash 變更，PLG 不補救，直接 invalid_submission。")
      return TatwoArenaPlanLoopGoalScoreReport(
        modelSlug: modelSlug,
        expectedSandboxTests: expectedSandboxTests,
        completedSandboxTests: completedSandboxTests,
        missingSandboxTests: missingSandboxTests,
        allSandboxTestsComplete: allSandboxTestsComplete,
        scoreAfterAllSandboxTests: protocolSpec.scoreAfterAllSandboxTests,
        modelSelfEvaluationAccepted: false,
        goalCycleAssessment: cycleAssessment,
        canScorePlanLoopGoal: false,
        decisionCode: "invalid_submission_plg_score_blocked",
        decisionText: "封存後檔案被改動；此模型提交無效，不進行正常 PLG 加分。",
        presentArtifacts: presentArtifacts,
        missingRequiredArtifacts: missingRequiredArtifacts,
        toolChoicesAllRegistered: toolChoicesAllRegistered,
        inputVerificationMode: inputVerificationMode,
        inputsVerifiedFromDisk: inputsVerifiedFromDisk,
        inputsAssertedByCaller: inputsAssertedByCaller,
        scoreEligibleReceiptPresent: scoreEligibleReceiptPresent,
        scoreUsableAsGateEvidence: false,
        score: nil,
        notes: baseNotes)
    }

    guard allSandboxTestsComplete else {
      baseNotes.append("尚有 sandbox 測試未完成，所以不能先替模型 PLG 打分。")
      return TatwoArenaPlanLoopGoalScoreReport(
        modelSlug: modelSlug,
        expectedSandboxTests: expectedSandboxTests,
        completedSandboxTests: completedSandboxTests,
        missingSandboxTests: missingSandboxTests,
        allSandboxTestsComplete: false,
        scoreAfterAllSandboxTests: protocolSpec.scoreAfterAllSandboxTests,
        modelSelfEvaluationAccepted: false,
        goalCycleAssessment: cycleAssessment,
        canScorePlanLoopGoal: false,
        decisionCode: "sandbox_tests_incomplete_plg_score_blocked",
        decisionText: "必須等所有沙盒測試完成後，才評分此模型的 plan+loops+goal。",
        presentArtifacts: presentArtifacts,
        missingRequiredArtifacts: missingRequiredArtifacts,
        toolChoicesAllRegistered: toolChoicesAllRegistered,
        inputVerificationMode: inputVerificationMode,
        inputsVerifiedFromDisk: inputsVerifiedFromDisk,
        inputsAssertedByCaller: inputsAssertedByCaller,
        scoreEligibleReceiptPresent: scoreEligibleReceiptPresent,
        scoreUsableAsGateEvidence: false,
        score: nil,
        notes: baseNotes)
    }

    guard cycleAssessment.mustEnterGrading else {
      baseNotes.append("Goal 尚可繼續實作；未封存也未達 5 次上限，所以不能先評 PLG。")
      return TatwoArenaPlanLoopGoalScoreReport(
        modelSlug: modelSlug,
        expectedSandboxTests: expectedSandboxTests,
        completedSandboxTests: completedSandboxTests,
        missingSandboxTests: missingSandboxTests,
        allSandboxTestsComplete: true,
        scoreAfterAllSandboxTests: protocolSpec.scoreAfterAllSandboxTests,
        modelSelfEvaluationAccepted: false,
        goalCycleAssessment: cycleAssessment,
        canScorePlanLoopGoal: false,
        decisionCode: "implementation_open_plg_score_blocked",
        decisionText: "Goal 還在實作期；封存或達 5 次上限後才可評分 PLG。",
        presentArtifacts: presentArtifacts,
        missingRequiredArtifacts: missingRequiredArtifacts,
        toolChoicesAllRegistered: toolChoicesAllRegistered,
        inputVerificationMode: inputVerificationMode,
        inputsVerifiedFromDisk: inputsVerifiedFromDisk,
        inputsAssertedByCaller: inputsAssertedByCaller,
        scoreEligibleReceiptPresent: scoreEligibleReceiptPresent,
        scoreUsableAsGateEvidence: false,
        score: nil,
        notes: baseNotes)
    }

    let scoreUsableAsGateEvidence =
      inputsVerifiedFromDisk
      && !inputsAssertedByCaller
      && scoreEligibleReceiptPresent
      && missingRequiredArtifacts.isEmpty
      && toolChoicesAllRegistered

    let score = TatwoArenaPlanLoopGoalScore(
      goalDecomposition: points([
        ("goal-contract.md", 10),
        ("plan.md", 10),
      ], in: presentSet),
      mainlineDiscipline: points([
        ("loop-ledger.json", 8),
        ("mainline-decision.md", 7),
        ("final-submission/seal.json", 5),
      ], in: presentSet),
      branchOptimization: points([
        ("branch-optimization-plan.md", 8),
        ("branch-loop-ledger.json", 7),
      ], in: presentSet),
      loopReceiptQuality: points([
        ("loop-ledger.json", 6),
        ("branch-loop-ledger.json", 4),
        ("receipt-index.json", 10),
      ], in: presentSet),
      toolChoiceFromRegistry: points([
        ("tool-choice-ledger.json", 5),
      ], in: presentSet) + (toolChoicesAllRegistered ? 5 : 0),
      stopAndSealDiscipline:
        (goalExecutionCycles <= goalCyclePolicy.maxGoalExecutionCycles ? 5 : 0)
        + (hasArtifact("final-submission/seal.json", in: presentSet) ? 5 : 0)
        + (!fileHashesChangedAfterSeal ? 5 : 0),
      notes: baseNotes + [
        missingRequiredArtifacts.isEmpty
          ? "所有 PLG 必要 artifacts 皆存在。"
          : "缺少 PLG artifacts: \(missingRequiredArtifacts.joined(separator: ", "))",
        toolChoicesAllRegistered ? "tool-choice-ledger 使用 registry 內工具。" : "tool-choice-ledger 含未登記工具或尚未驗證。",
        scoreUsableAsGateEvidence ? "PLG scorer inputs 已由磁碟收據驗證，可作為 gate evidence。" : "PLG 分數目前不可作為 gate evidence；需要磁碟驗證與 scoreEligible receipt。",
      ])

    return TatwoArenaPlanLoopGoalScoreReport(
      modelSlug: modelSlug,
      expectedSandboxTests: expectedSandboxTests,
      completedSandboxTests: completedSandboxTests,
      missingSandboxTests: missingSandboxTests,
      allSandboxTestsComplete: true,
      scoreAfterAllSandboxTests: protocolSpec.scoreAfterAllSandboxTests,
      modelSelfEvaluationAccepted: false,
      goalCycleAssessment: cycleAssessment,
      canScorePlanLoopGoal: true,
      decisionCode: "all_sandbox_tests_complete_score_plg",
      decisionText: "所有沙盒測試已完成且 goal 已進評分狀態；可以計算模型的 PLG 分數。",
      presentArtifacts: presentArtifacts,
      missingRequiredArtifacts: missingRequiredArtifacts,
      toolChoicesAllRegistered: toolChoicesAllRegistered,
      inputVerificationMode: inputVerificationMode,
      inputsVerifiedFromDisk: inputsVerifiedFromDisk,
      inputsAssertedByCaller: inputsAssertedByCaller,
      scoreEligibleReceiptPresent: scoreEligibleReceiptPresent,
      scoreUsableAsGateEvidence: scoreUsableAsGateEvidence,
      score: score,
      notes: score.notes)
  }

  private static func points(_ items: [(String, Int)], in presentSet: Set<String>) -> Int {
    items.reduce(0) { partial, item in
      partial + (hasArtifact(item.0, in: presentSet) ? item.1 : 0)
    }
  }

  private static func normalizedArtifactName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\", with: "/")
  }

  private static func hasArtifact(_ required: String, in presentSet: Set<String>) -> Bool {
    let normalized = normalizedArtifactName(required)
    if presentSet.contains(normalized) { return true }
    return presentSet.contains { artifact in
      artifact == normalized || artifact.hasSuffix("/\(normalized)")
    }
  }
}
