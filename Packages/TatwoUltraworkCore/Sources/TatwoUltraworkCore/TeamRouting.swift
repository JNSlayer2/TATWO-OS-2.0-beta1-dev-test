import Foundation

public struct ModelTraitScores: Codable, Sendable, Equatable {
  public let reasoning: Int
  public let coding: Int
  public let designSense: Int
  public let researchFreshness: Int
  public let bulkThroughput: Int
  public let reviewStrictness: Int
  public let costRisk: Int
  public let stabilityRisk: Int
  public let executionAuthority: Int

  public init(
    reasoning: Int,
    coding: Int,
    designSense: Int,
    researchFreshness: Int,
    bulkThroughput: Int,
    reviewStrictness: Int,
    costRisk: Int,
    stabilityRisk: Int,
    executionAuthority: Int
  ) {
    self.reasoning = Self.clamp(reasoning)
    self.coding = Self.clamp(coding)
    self.designSense = Self.clamp(designSense)
    self.researchFreshness = Self.clamp(researchFreshness)
    self.bulkThroughput = Self.clamp(bulkThroughput)
    self.reviewStrictness = Self.clamp(reviewStrictness)
    self.costRisk = Self.clamp(costRisk)
    self.stabilityRisk = Self.clamp(stabilityRisk)
    self.executionAuthority = Self.clamp(executionAuthority)
  }

  private static func clamp(_ value: Int) -> Int { min(5, max(1, value)) }
}

public struct ModelCalibrationNote: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let observedPattern: String
  public let routingImplication: String
  public let confidence: String

  public init(id: String, observedPattern: String, routingImplication: String, confidence: String) {
    self.id = id
    self.observedPattern = observedPattern
    self.routingImplication = routingImplication
    self.confidence = confidence
  }
}

public struct ModelTrait: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let displayName: String
  public let plainSummary: String
  public let plainFailureMode: String
  public let verificationRule: String
  public let strengths: [String]
  public let weaknesses: [String]
  public let bestRoles: [String]
  public let avoidRoles: [String]
  public let calibrationNotes: [ModelCalibrationNote]
  public let scores: ModelTraitScores
  public let defaultAuthority: AuthorityMode
  public let canDirectlyMutateHost: Bool

  public init(
    id: String,
    displayName: String,
    plainSummary: String,
    plainFailureMode: String = "沒有獨立證據時不可自我放行。",
    verificationRule: String = "必須由 Codex executor 產生可重跑證據，再由獨立 reviewer/judge 放行。",
    strengths: [String],
    weaknesses: [String],
    bestRoles: [String],
    avoidRoles: [String],
    calibrationNotes: [ModelCalibrationNote] = [],
    scores: ModelTraitScores,
    defaultAuthority: AuthorityMode,
    canDirectlyMutateHost: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.plainSummary = plainSummary
    self.plainFailureMode = plainFailureMode
    self.verificationRule = verificationRule
    self.strengths = strengths
    self.weaknesses = weaknesses
    self.bestRoles = bestRoles
    self.avoidRoles = avoidRoles
    self.calibrationNotes = calibrationNotes
    self.scores = scores
    self.defaultAuthority = defaultAuthority
    self.canDirectlyMutateHost = canDirectlyMutateHost
  }
}

public struct TeamMember: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let modelID: String
  public let displayName: String
  public let teamRole: String
  public let plainResponsibility: String
  public let whyHere: String
  public let authority: AuthorityMode
  public let canBulkScout: Bool
  public let canFinalJudge: Bool
  public let canDirectlyMutateHost: Bool

  public init(
    id: String,
    modelID: String,
    displayName: String,
    teamRole: String,
    plainResponsibility: String,
    whyHere: String,
    authority: AuthorityMode,
    canBulkScout: Bool = false,
    canFinalJudge: Bool = false,
    canDirectlyMutateHost: Bool = false
  ) {
    self.id = id
    self.modelID = modelID
    self.displayName = displayName
    self.teamRole = teamRole
    self.plainResponsibility = plainResponsibility
    self.whyHere = whyHere
    self.authority = authority
    self.canBulkScout = canBulkScout
    self.canFinalJudge = canFinalJudge
    self.canDirectlyMutateHost = canDirectlyMutateHost
  }
}

public struct TeamGate: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let plainRule: String
  public let requiredEvidence: [EvidenceKind]
  public let failClosedMessage: String

  public init(
    id: String, title: String, plainRule: String, requiredEvidence: [EvidenceKind],
    failClosedMessage: String
  ) {
    self.id = id
    self.title = title
    self.plainRule = plainRule
    self.requiredEvidence = requiredEvidence
    self.failClosedMessage = failClosedMessage
  }
}

public struct TeamWorkflowLoop: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let plainSteps: [String]
  public let scriptsOrCommands: [String]
  public let sandboxPolicy: String
  public let stopCondition: String
  public let requiredReceipts: [String]

  public init(
    id: String, title: String, plainSteps: [String], scriptsOrCommands: [String],
    sandboxPolicy: String, stopCondition: String, requiredReceipts: [String] = []
  ) {
    self.id = id
    self.title = title
    self.plainSteps = plainSteps
    self.scriptsOrCommands = scriptsOrCommands
    self.sandboxPolicy = sandboxPolicy
    self.stopCondition = stopCondition
    self.requiredReceipts = requiredReceipts
  }
}

public struct TeamRoleBoundary: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let roleName: String
  public let owner: String
  public let canDo: [String]
  public let cannotDo: [String]
  public let evidenceBeforePass: [String]

  public init(
    id: String, roleName: String, owner: String, canDo: [String], cannotDo: [String],
    evidenceBeforePass: [String]
  ) {
    self.id = id
    self.roleName = roleName
    self.owner = owner
    self.canDo = canDo
    self.cannotDo = cannotDo
    self.evidenceBeforePass = evidenceBeforePass
  }
}

public struct TeamDefinition: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let chineseName: String
  public let plainPurpose: String
  public let scenarioFits: [ScenarioID]
  public let modeFits: [WorkModeID]
  public let readOnlyByDefault: Bool
  public let members: [TeamMember]
  public let loops: [TeamWorkflowLoop]
  public let gates: [TeamGate]
  public let roleBoundaries: [TeamRoleBoundary]
  public let forbidden: [String]

  public init(
    id: String,
    chineseName: String,
    plainPurpose: String,
    scenarioFits: [ScenarioID],
    modeFits: [WorkModeID],
    readOnlyByDefault: Bool,
    members: [TeamMember],
    loops: [TeamWorkflowLoop],
    gates: [TeamGate],
    roleBoundaries: [TeamRoleBoundary] = [],
    forbidden: [String]
  ) {
    self.id = id
    self.chineseName = chineseName
    self.plainPurpose = plainPurpose
    self.scenarioFits = scenarioFits
    self.modeFits = modeFits
    self.readOnlyByDefault = readOnlyByDefault
    self.members = members
    self.loops = loops
    self.gates = gates
    self.roleBoundaries = roleBoundaries
    self.forbidden = forbidden
  }
}

public struct LeadCompanionEffect: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let modelID: String
  public let displayName: String
  public let roleWhenPaired: String
  public let effectSummary: String
  public let estimatedDelta: Double
  public let caution: String
  public let requiredEvidence: [String]

  public init(
    id: String,
    modelID: String,
    displayName: String,
    roleWhenPaired: String,
    effectSummary: String,
    estimatedDelta: Double,
    caution: String,
    requiredEvidence: [String]
  ) {
    self.id = id
    self.modelID = modelID
    self.displayName = displayName
    self.roleWhenPaired = roleWhenPaired
    self.effectSummary = effectSummary
    self.estimatedDelta = max(-3, min(3, estimatedDelta))
    self.caution = caution
    self.requiredEvidence = requiredEvidence
  }
}

public struct TatwoCollabEvidenceMemberV1: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let model: String
  public let role: String

  public init(id: String? = nil, model: String, role: String) {
    self.id = id ?? "\(model)-\(role)"
    self.model = model
    self.role = role
  }
}

public enum TatwoCollabEvidenceSourceV1: String, Codable, Sendable, Equatable {
  case sandboxExam = "sandbox-exam"
  case liveRunHumanVerdict = "live-run-human-verdict"
}

public enum TatwoCollabDeltaDirectionV1: String, Codable, Sendable, Equatable {
  case positive = "+"
  case flat = "="
  case negative = "-"
}

public struct TatwoCollabEvidenceV1: Codable, Sendable, Identifiable, Equatable {
  public let schema: String
  public let id: String
  public let members: [TatwoCollabEvidenceMemberV1]
  public let taskClass: String
  public let strongBaseline: String
  public let weakBaseline: String
  public let qualitativeVerdict: String
  public let deltaDirection: TatwoCollabDeltaDirectionV1
  public let source: TatwoCollabEvidenceSourceV1
  public let sourceLabel: String
  public let date: String
  public let note: String

  public init(
    schema: String = "TatwoCollabEvidenceV1",
    id: String,
    members: [TatwoCollabEvidenceMemberV1],
    taskClass: String,
    strongBaseline: String,
    weakBaseline: String,
    qualitativeVerdict: String,
    deltaDirection: TatwoCollabDeltaDirectionV1,
    source: TatwoCollabEvidenceSourceV1,
    sourceLabel: String,
    date: String,
    note: String
  ) {
    self.schema = schema
    self.id = id
    self.members = members
    self.taskClass = taskClass
    self.strongBaseline = strongBaseline
    self.weakBaseline = weakBaseline
    self.qualitativeVerdict = qualitativeVerdict
    self.deltaDirection = deltaDirection
    self.source = source
    self.sourceLabel = sourceLabel
    self.date = date
    self.note = note
  }
}

public struct LeadStrategy: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let displayName: String
  public let leadModelID: String
  public let leadDisplayName: String
  public let plainBestWhen: String
  public let plainTradeoff: String
  public let modeFits: [WorkModeID]
  public let scenarioFits: [ScenarioID]
  public let defaultTeamID: String
  public let companionEffects: [LeadCompanionEffect]

  public init(
    id: String,
    displayName: String,
    leadModelID: String,
    leadDisplayName: String,
    plainBestWhen: String,
    plainTradeoff: String,
    modeFits: [WorkModeID],
    scenarioFits: [ScenarioID],
    defaultTeamID: String,
    companionEffects: [LeadCompanionEffect]
  ) {
    self.id = id
    self.displayName = displayName
    self.leadModelID = leadModelID
    self.leadDisplayName = leadDisplayName
    self.plainBestWhen = plainBestWhen
    self.plainTradeoff = plainTradeoff
    self.modeFits = modeFits
    self.scenarioFits = scenarioFits
    self.defaultTeamID = defaultTeamID
    self.companionEffects = companionEffects
  }
}

public struct TeamRecommendation: Codable, Sendable, Equatable {
  public let schema: String
  public let mode: WorkModeID
  public let scenario: ScenarioID
  public let leadStrategy: LeadStrategy
  public let primaryTeam: TeamDefinition
  public let supportingTeams: [TeamDefinition]
  public let requiredGates: [String]
  public let workflowLoops: [TeamWorkflowLoop]
  public let stabilityNotes: [String]

  public init(
    schema: String = "TatwoTeamRecommendationV1",
    mode: WorkModeID,
    scenario: ScenarioID,
    leadStrategy: LeadStrategy,
    primaryTeam: TeamDefinition,
    supportingTeams: [TeamDefinition],
    requiredGates: [String],
    workflowLoops: [TeamWorkflowLoop],
    stabilityNotes: [String]
  ) {
    self.schema = schema
    self.mode = mode
    self.scenario = scenario
    self.leadStrategy = leadStrategy
    self.primaryTeam = primaryTeam
    self.supportingTeams = supportingTeams
    self.requiredGates = requiredGates
    self.workflowLoops = workflowLoops
    self.stabilityNotes = stabilityNotes
  }
}

public struct TeamReadinessScript: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let ownerTeamID: String
  public let command: String
  public let plainPurpose: String
  public let hostMutationAllowed: Bool
  public let sandboxSafe: Bool

  public init(
    id: String,
    title: String,
    ownerTeamID: String,
    command: String,
    plainPurpose: String,
    hostMutationAllowed: Bool = false,
    sandboxSafe: Bool = true
  ) {
    self.id = id
    self.title = title
    self.ownerTeamID = ownerTeamID
    self.command = command
    self.plainPurpose = plainPurpose
    self.hostMutationAllowed = hostMutationAllowed
    self.sandboxSafe = sandboxSafe
  }
}

public struct TeamReadinessReceipt: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let ownerTeamID: String
  public let requiredBeforeHostInstall: Bool
  public let dryRunCanSatisfy: Bool
  public let passRule: String
  public let failureIfMissing: String

  public init(
    id: String,
    title: String,
    ownerTeamID: String,
    requiredBeforeHostInstall: Bool,
    dryRunCanSatisfy: Bool,
    passRule: String,
    failureIfMissing: String
  ) {
    self.id = id
    self.title = title
    self.ownerTeamID = ownerTeamID
    self.requiredBeforeHostInstall = requiredBeforeHostInstall
    self.dryRunCanSatisfy = dryRunCanSatisfy
    self.passRule = passRule
    self.failureIfMissing = failureIfMissing
  }
}

public struct TeamReadinessCard: Codable, Sendable, Identifiable, Equatable {
  public var id: String { team.id }
  public let team: TeamDefinition
  public let modelTraitIDs: [String]
  public let loopIDs: [String]
  public let gateIDs: [String]
  public let scriptIDs: [String]
  public let receiptIDs: [String]
  public let plainNextCheck: String

  public init(
    team: TeamDefinition,
    modelTraitIDs: [String],
    loopIDs: [String],
    gateIDs: [String],
    scriptIDs: [String],
    receiptIDs: [String],
    plainNextCheck: String
  ) {
    self.team = team
    self.modelTraitIDs = modelTraitIDs
    self.loopIDs = loopIDs
    self.gateIDs = gateIDs
    self.scriptIDs = scriptIDs
    self.receiptIDs = receiptIDs
    self.plainNextCheck = plainNextCheck
  }
}

public struct TeamReadinessDashboard: Codable, Sendable, Equatable {
  public let schema: String
  public let mode: WorkModeID
  public let scenario: ScenarioID
  public let leadStrategy: LeadStrategy
  public let availableLeadStrategies: [LeadStrategy]
  public let uiDeferred: Bool
  public let hostMutationAllowed: Bool
  public let hostInstallAllowed: Bool
  public let plainSummary: String
  public let modelTraits: [ModelTrait]
  public let selectedTeams: [TeamReadinessCard]
  public let scripts: [TeamReadinessScript]
  public let receipts: [TeamReadinessReceipt]
  public let failClosedRules: [String]
  public let nextCommands: [String]

  public init(
    schema: String = "TatwoTeamReadinessDashboardV1",
    mode: WorkModeID,
    scenario: ScenarioID,
    leadStrategy: LeadStrategy,
    availableLeadStrategies: [LeadStrategy],
    uiDeferred: Bool,
    hostMutationAllowed: Bool,
    hostInstallAllowed: Bool,
    plainSummary: String,
    modelTraits: [ModelTrait],
    selectedTeams: [TeamReadinessCard],
    scripts: [TeamReadinessScript],
    receipts: [TeamReadinessReceipt],
    failClosedRules: [String],
    nextCommands: [String]
  ) {
    self.schema = schema
    self.mode = mode
    self.scenario = scenario
    self.leadStrategy = leadStrategy
    self.availableLeadStrategies = availableLeadStrategies
    self.uiDeferred = uiDeferred
    self.hostMutationAllowed = hostMutationAllowed
    self.hostInstallAllowed = hostInstallAllowed
    self.plainSummary = plainSummary
    self.modelTraits = modelTraits
    self.selectedTeams = selectedTeams
    self.scripts = scripts
    self.receipts = receipts
    self.failClosedRules = failClosedRules
    self.nextCommands = nextCommands
  }
}

public struct IntegrationStage: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let plainGoal: String
  public let requiresHumanApproval: Bool
  public let mayMutateHost: Bool
  public let checks: [String]
  public let deniedActions: [String]
  public let doneCondition: String

  public init(
    id: String,
    title: String,
    plainGoal: String,
    requiresHumanApproval: Bool,
    mayMutateHost: Bool,
    checks: [String],
    deniedActions: [String],
    doneCondition: String
  ) {
    self.id = id
    self.title = title
    self.plainGoal = plainGoal
    self.requiresHumanApproval = requiresHumanApproval
    self.mayMutateHost = mayMutateHost
    self.checks = checks
    self.deniedActions = deniedActions
    self.doneCondition = doneCondition
  }
}

public struct StabilityGuard: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let plainRule: String
  public let prevents: String
  public let verification: String
  public let severity: SafetyLevel

  public init(
    id: String, title: String, plainRule: String, prevents: String, verification: String,
    severity: SafetyLevel
  ) {
    self.id = id
    self.title = title
    self.plainRule = plainRule
    self.prevents = prevents
    self.verification = verification
    self.severity = severity
  }
}

public struct DisconnectPreventionRule: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let symptom: String
  public let rule: String
  public let acceptance: String

  public init(id: String, symptom: String, rule: String, acceptance: String) {
    self.id = id
    self.symptom = symptom
    self.rule = rule
    self.acceptance = acceptance
  }
}

public struct IntegrationPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let hostMutationDefault: Bool
  public let stages: [IntegrationStage]
  public let rollbackSteps: [String]

  public init(
    schema: String = "TatwoIntegrationPlanV1", hostMutationDefault: Bool,
    stages: [IntegrationStage], rollbackSteps: [String]
  ) {
    self.schema = schema
    self.hostMutationDefault = hostMutationDefault
    self.stages = stages
    self.rollbackSteps = rollbackSteps
  }
}

public struct StabilityPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let guards: [StabilityGuard]
  public let disconnectRules: [DisconnectPreventionRule]

  public init(
    schema: String = "TatwoStabilityPlanV1", guards: [StabilityGuard],
    disconnectRules: [DisconnectPreventionRule]
  ) {
    self.schema = schema
    self.guards = guards
    self.disconnectRules = disconnectRules
  }
}

public struct FuguArchitecturePolicy: Codable, Sendable, Equatable {
  public let schema: String
  public let integratesFuguModel: Bool
  public let plainSummary: String
  public let adoptedIdeas: [String]
  public let rejectedIdeas: [String]
  public let guardrails: [String]
  public let verificationSignals: [String]

  public init(
    schema: String = "TatwoFuguArchitecturePolicyV1",
    integratesFuguModel: Bool,
    plainSummary: String,
    adoptedIdeas: [String],
    rejectedIdeas: [String],
    guardrails: [String],
    verificationSignals: [String]
  ) {
    self.schema = schema
    self.integratesFuguModel = integratesFuguModel
    self.plainSummary = plainSummary
    self.adoptedIdeas = adoptedIdeas
    self.rejectedIdeas = rejectedIdeas
    self.guardrails = guardrails
    self.verificationSignals = verificationSignals
  }
}

public enum TeamRoutingCatalog {
  public static let collaborationEvidencePriority: [String] = ["人工", "考場"]
  public static let collaborationEvidenceUIActionLabel = "+人工評分"

  public static let collaborationEvidence: [TatwoCollabEvidenceV1] = [
    TatwoCollabEvidenceV1(
      id: "gpt55-sonnet5-vs-fable5-20260706",
      members: [
        TatwoCollabEvidenceMemberV1(model: "gpt-5.5", role: "主導 / Codex host"),
        TatwoCollabEvidenceMemberV1(model: "sonnet-5", role: "工程副審"),
      ],
      taskClass: "模型協作實戰比較 2026-07-06",
      strongBaseline: "fable-5 單打",
      weakBaseline: "gpt-5.5＋sonnet-5 協作",
      qualitativeVerdict: "持平",
      deltaDirection: .flat,
      source: .liveRunHumanVerdict,
      sourceLabel: "使用者實戰評價 2026-07-06",
      date: "2026-07-06",
      note: "gpt-5.5＋sonnet-5 協作 vs fable-5 單打 → 持平（=）。"),
    TatwoCollabEvidenceV1(
      id: "solo-beats-multimodel-20260706",
      members: [
        TatwoCollabEvidenceMemberV1(model: "fable-5", role: "單打"),
        TatwoCollabEvidenceMemberV1(model: "gpt-5.5", role: "單打"),
      ],
      taskClass: "單模型與多模型協作比較 2026-07-06",
      strongBaseline: "fable-5 單打 與 gpt-5.5 單打",
      weakBaseline: "多模型協作",
      qualitativeVerdict: "單打勝",
      deltaDirection: .negative,
      source: .liveRunHumanVerdict,
      sourceLabel: "使用者實戰評價 2026-07-06",
      date: "2026-07-06",
      note: "fable-5 單打 與 gpt-5.5 單打 各自 vs 多模型協作 → 單打勝；多模型協作為紅 delta。"),
    TatwoCollabEvidenceV1(
      id: "fable5-lead-gpt55-loops-xl-ui-20260706",
      members: [
        TatwoCollabEvidenceMemberV1(model: "fable-5", role: "主審"),
        TatwoCollabEvidenceMemberV1(model: "gpt-5.5", role: "loops 執行"),
      ],
      taskClass: "XL UI 16點改造實戰 2026-07-06",
      strongBaseline: "fable-5 主審＋gpt-5.5 loops 執行",
      weakBaseline: "未指定弱基線",
      qualitativeVerdict: "高滿意",
      deltaDirection: .positive,
      source: .liveRunHumanVerdict,
      sourceLabel: "使用者實戰評價 2026-07-06",
      date: "2026-07-06",
      note: "fable-5 主審＋gpt-5.5 loops 執行 → 高滿意（+）。"),
  ]

  public static let modelTraits: [ModelTrait] = [
    ModelTrait(
      id: "fable-5",
      displayName: "Fable 5",
      plainSummary: "已可透過 gateway 跑正式 Web Arena；目前定位是昂貴高階候選，適合架構/產品草稿觀察，但不自動進常駐協作流。",
      plainFailureMode: "Web Arena 顯示語義覆蓋強，但工程與 UI gate 全被擋下；再加上成本/額度風險，不能因分數接近 GPT-5.4 就直接升主導或完工者。",
      verificationRule: "升級前至少需要：多輪 route 穩定、same-thread smoke、Debug/Code Arena、3D/多模態按需測試、web-check 修復後的 UI/UJ 副審。",
      strengths: ["高推理與長文審稿潛力", "Web Arena 三題語義覆蓋完整", "可作昂貴的產品/架構草稿候選"],
      weaknesses: ["成本高且可能撞額度，不宜預設 fan-out", "Web Arena 三題 engineeringPassed=false", "缺少 Debug/Code/3D 等跨領域證據"],
      bestRoles: ["高階草稿候選", "架構/產品構想觀察", "明確授權後的深度比較"],
      avoidRoles: ["無授權常駐協作流", "sealed frontend finisher", "host mutation", "唯一 UI/UJ 驗收者"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "fable5-rated-but-disabled",
          observedPattern:
            "早期使用者要求即使 Fable 5 不可用也先保留評級；現在 base fable-5 route 已能完成正式 Web Arena，但仍需成本與驗收 gate。",
          routingImplication:
            "Fable 5 可顯示為 arena-tested 候選；在更多沙盒通過與使用者授權前，不進 teams 或自動調度。",
          confidence: "arena-tested-web-only"
        ),
        ModelCalibrationNote(
          id: "fable5-web-arena-v1-20260702",
          observedPattern:
            "20260702 Web Arena formal v1：三題 dispatchComplete=true、sealVerified=3/3、平均 64；刺青 62、3D 資產 65、交易所結構 65。",
          routingImplication:
            "可作高階草稿與產品結構候選；但三題皆 rollback_required，web-check errors 1/3/1，UI/UJ 未放行，不可當完工者。",
          confidence: "sandbox-evidence"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 5, coding: 4, designSense: 4, researchFreshness: 2, bulkThroughput: 2,
        reviewStrictness: 4, costRisk: 5, stabilityRisk: 3, executionAuthority: 1),
      defaultAuthority: .brainOnly
    ),
    ModelTrait(
      id: "gpt-5.5",
      displayName: "GPT-5.5",
      plainSummary: "最適合當主控：整理大架構、把不同模型意見收斂成可執行步驟，並理解 Codex 工具語義。",
      plainFailureMode: "細修 UI/UX 時，若只有 build 或文字描述，容易過度相信自己已解決；遇到消息/創意也可能偏保守。",
      verificationRule: "UI 必須有截圖、錄影或 visual diff；工程必須有測試/smoke；GPT 不得單獨 final pass 自己主控的結果。",
      strengths: ["大架構歸納與主控規劃", "Codex 工具/patch/測試語義", "保守收斂，適合把混亂討論變成下一步"],
      weaknesses: ["UI/UX 細修若沒有視覺 gate，容易過度相信 build pass", "有時過度保守，會把創意或外部反例壓掉", "不適合大量廉價枚舉"],
      bestRoles: ["主控", "收斂者", "Codex 執行意圖整理"],
      avoidRoles: ["唯一 UI 驗收者", "大量 scout", "高風險唯一裁決"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "gpt-ui-self-pass-risk",
          observedPattern: "過去協作中，GPT 在第一次大量搭建通常很強；但進入 UI/UX 細修時，曾把顯而易見仍糟糕的結果判成通過。",
          routingImplication:
            "GPT-5.5 可當主控與收斂者，但 UI/UX 必須交給設計團隊的 visual gate、獨立 verifier 與 Opus/Human judge。",
          confidence: "high"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 5, coding: 5, designSense: 3, researchFreshness: 3, bulkThroughput: 3,
        reviewStrictness: 4, costRisk: 3, stabilityRisk: 2, executionAuthority: 5),
      defaultAuthority: .toolIntentBridge
    ),
    ModelTrait(
      id: "opus-5",
      displayName: "Opus 5",
      plainSummary: "最適合作保守裁決與高風險審稿：沒有證據時寧可擋下。",
      plainFailureMode: "成本高且偏保守；若 done condition 不清楚，可能只會擋住但不給最短落地路徑。",
      verificationRule: "只讓它裁決有 evidence 的結果；裁決前必須看到 diff、測試、截圖或 readiness receipt，不讓它替代 Codex 實測。",
      strengths: ["長上下文架構風險審核", "高風險 fail-closed 裁決", "UI/代碼架構的深度審稿"],
      weaknesses: ["成本高，不適合每個小任務都用", "可能過度阻擋，需要明確 done condition", "不適合大量草稿掃描"],
      bestRoles: ["最終 judge", "高風險 reviewer", "架構風險審核"],
      avoidRoles: ["bulk scout", "小修預設 reviewer", "直接執行宿主"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "opus-fail-closed-judge",
          observedPattern:
            "過去 gateway/open-ultrawork 穩定化時，重型 Claude/Opus 類 reviewer 最有價值的地方是擋下未證明的 route、auth、rollback 與 UI pass。",
          routingImplication:
            "Opus 5 放在 judge / 高風險 reviewer，不做大量草稿；它只看 evidence bundle，不替代 smoke/test。",
          confidence: "medium-high"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 5, coding: 4, designSense: 4, researchFreshness: 3, bulkThroughput: 1,
        reviewStrictness: 5, costRisk: 5, stabilityRisk: 3, executionAuthority: 1),
      defaultAuthority: .brainOnly
    ),
    ModelTrait(
      id: "sonnet-5",
      displayName: "Sonnet 5",
      plainSummary: "TATWO 的主力工程副審：比舊 Sonnet lane 更適合承擔代碼一致性、漏測檢查、M/L 級 debug 主導與 patch intent。",
      plainFailureMode: "仍然不是宿主，也不是高風險最後裁判；若沒有 diff、測試、截圖或 smoke receipt，它的通過意見只算 reviewer 建議。",
      verificationRule: "Sonnet 5 可主導工程審稿與補測試清單；patch 必須由 Codex 套用並跑測試，L/XL 或高風險再交 Opus / human gate。",
      strengths: ["代碼架構與語法一致性", "patch intent 與漏測檢查", "M/L 級 debug 主導", "多模型工程副審"],
      weaknesses: ["不應作高風險最終裁決", "不是大量低成本模型", "外部消息需要 Grok / Pro MCP 補來源", "不能直接 host mutation"],
      bestRoles: ["工程副審", "代碼一致性主導", "修補建議", "測試缺口檢查"],
      avoidRoles: ["交易風控唯一 judge", "大量候選生成", "host mutation", "無證據 UI 放行"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "sonnet-5-code-reviewer-upgrade",
          observedPattern:
            "Claude Sonnet 5 已成為目前 Sonnet lane；本地 route smoke 與微型能力評分已通過，但尚未跑長期大樣本基準，因此定位為升級 reviewer/engineering lead，而不是最高權限執行者。",
          routingImplication: "放在 supervisor / code reviewer / M-L debug lead；它能提高代碼一致與漏測捕捉，但 host install、same-thread smoke 與 UI/UJ pass 仍由 Codex receipt + Opus/human gate 決定。",
          confidence: "provisional-medium"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 5, coding: 5, designSense: 4, researchFreshness: 2, bulkThroughput: 2,
        reviewStrictness: 5, costRisk: 4, stabilityRisk: 3, executionAuthority: 1),
      defaultAuthority: .patchProposal
    ),
    ModelTrait(
      id: "minimax-m3",
      displayName: "MiniMax M3",
      plainSummary: "適合扛量：候選、草稿、檢查清單、分檔掃描；不能當最後裁決。",
      plainFailureMode: "大量輸出容易混入假陽性或重複點；不能因為列很多就代表正確。",
      verificationRule: "只採納可去重、可驗證的候選；每個 finding 要被 Codex/Reviewer 對照檔案、測試或截圖後才算數。",
      strengths: ["大量草稿與候選清單", "分檔掃描與粗分類", "功能測試想法和 checklist"],
      weaknesses: ["高風險判斷不夠穩", "不應 final pass", "需要 GPT/Opus 收斂"],
      bestRoles: ["bulk scout", "功能測試腦暴", "候選生成"],
      avoidRoles: ["最終 judge", "資安/交易唯一裁決", "直接寫主機"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "minimax-bulk-but-false-positive",
          observedPattern: "過去多模型工作中，MiniMax M3 很適合大量候選、測試點與清單；但大量輸出也會有重複與假陽性。",
          routingImplication: "放在 scout / 功能測試團；輸出必須 schema 化、去重，再由 Codex/Sonnet/Opus 驗證。",
          confidence: "high"
        ),
        ModelCalibrationNote(
          id: "minimax-m3-web-arena-v4-20260702",
          observedPattern: "Web Arena v1 正式 run 20260702-minimax-m3-web-arena-formal-v4：三題皆完成封存且 seal verified，但總狀態 rollback_required，平均 53.3/100；刺青 55、3D 資產 50、交易所結構 55，工程/UI gate 全未通過，且 dispatchComplete=false。",
          routingImplication: "MiniMax M3 在網頁建置可保留為大量草稿、候選、checklist 與測試點 scout；不可升級為 sealed frontend engineering finisher、UI/UJ 驗收或 final judge。",
          confidence: "arena-tested-medium"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 3, coding: 3, designSense: 3, researchFreshness: 2, bulkThroughput: 5,
        reviewStrictness: 2, costRisk: 1, stabilityRisk: 2, executionAuthority: 1),
      defaultAuthority: .brainOnly
    ),
    ModelTrait(
      id: "grok-build",
      displayName: "Grok",
      plainSummary: "適合查新消息、外部觀點與尖銳反例，用來挑戰 GPT 的保守結論。",
      plainFailureMode: "消息與尖銳觀點可能沒有足夠上下文；不能把它的外部說法直接當事實。",
      verificationRule: "重要消息要有來源連結或第二模型交叉驗證；私密資料不交給它，沒有來源就只算反例假設。",
      strengths: ["較新的外部消息", "尖銳反例", "趨勢/市場/社群視角"],
      weaknesses: ["不能當唯一證據來源", "私密資料不給它", "需要來源或第二模型交叉驗證"],
      bestRoles: ["消息 scout", "反方辯手", "趨勢 sanity check"],
      avoidRoles: ["唯一 judge", "處理私密 raw log", "直接執行"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "grok-news-refuter",
          observedPattern: "使用者長期觀察 Grok 在查找消息與反例時通常比 GPT 少一點保守濾鏡，但外部消息仍可能不完整。",
          routingImplication: "放在研究情報/交易風控的 news scout 與反方辯手；重要 claim 必須有來源或第二驗證。",
          confidence: "medium"
        ),
        ModelCalibrationNote(
          id: "grok-build-web-arena-v1-20260702",
          observedPattern: "Web Arena v1 正式 run 20260702-grok-build-web-arena-formal-v1：最高思考 xhigh，三題皆 seal verified，但總狀態 rollback_required，平均 38.7/100；刺青 11、3D 資產 50、交易所結構 55，主要阻塞是 index/app dispatch timeout 與 empty output。",
          routingImplication: "Grok 可用於消息、反例、產品結構與功能清單 scout；不應升級為 sealed frontend engineering finisher、UI/UJ 驗收或 final judge。",
          confidence: "arena-tested-medium"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 4, coding: 3, designSense: 3, researchFreshness: 5, bulkThroughput: 3,
        reviewStrictness: 3, costRisk: 2, stabilityRisk: 3, executionAuthority: 1),
      defaultAuthority: .brainOnly
    ),
    ModelTrait(
      id: "chatgpt-pro-mcp",
      displayName: "ChatGPT Pro MCP",
      plainSummary: "研究/審稿通道，不是 dropdown 同步模型；適合長 memo、來源、反駁、claim/evidence。",
      plainFailureMode: "可能只是 Web memo 而非 confirmed Deep Research；也不能宣稱它已寫檔或跑 shell。",
      verificationRule:
        "輸出必須拆成 claim/evidence/rebuttal/next_test；Codex 用 primary source 或本地測試驗證後才可升級為結論。",
      strengths: ["長篇研究 memo", "claim/evidence/rebuttal", "跨模型 handoff 延續"],
      weaknesses: ["非即時同步模型", "不能直接寫檔或跑 shell", "若 research mode 未啟用只能當 Web memo"],
      bestRoles: ["研究共同作者", "來源審稿", "反方 reviewer"],
      avoidRoles: ["bulk scout", "直接執行", "即時 UI 細修"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "pro-research-async-not-dropdown",
          observedPattern:
            "ChatGPT Pro MCP bridge 已適合做 guarded async 研究/handoff；但 research job 若未完成或 research_mode 未確認，不能當已驗證結論。",
          routingImplication: "放在研究情報團隊，產出 claim/evidence/rebuttal；Codex 再做 primary-source 或本地驗證。",
          confidence: "medium-high"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 5, coding: 3, designSense: 3, researchFreshness: 4, bulkThroughput: 1,
        reviewStrictness: 4, costRisk: 3, stabilityRisk: 4, executionAuthority: 1),
      defaultAuthority: .researchBridge
    ),
    ModelTrait(
      id: "local-qwen-ollama",
      displayName: "Local / Qwen / Ollama",
      plainSummary: "私密、便宜、離線粗掃；能力不夠就升級給 GPT/Sonnet/Opus。",
      plainFailureMode: "複雜推理與新資訊較弱；若結果模糊，容易拖慢後續判斷。",
      verificationRule: "只用於私密初掃/粗分類；關鍵結論必須升級給 GPT/Sonnet/Opus 或 deterministic test。",
      strengths: ["私密粗分類", "離線反覆跑", "便宜初掃"],
      weaknesses: ["複雜推理與審稿不穩", "需要升級門檻", "不能當高風險裁決"],
      bestRoles: ["私密初掃", "粗分類", "低成本預處理"],
      avoidRoles: ["最終 judge", "大型架構唯一規劃", "交易風控定案"],
      calibrationNotes: [
        ModelCalibrationNote(
          id: "local-private-prefilter",
          observedPattern: "本地模型適合作不外流的粗掃與分類；但遇到複雜架構、UI 判斷或新資訊時需要升級。",
          routingImplication:
            "放在私密預處理，不進 final judge；任何關鍵結論都要升級到 GPT/Sonnet/Opus 或 deterministic test。",
          confidence: "medium"
        )
      ],
      scores: ModelTraitScores(
        reasoning: 2, coding: 2, designSense: 2, researchFreshness: 1, bulkThroughput: 4,
        reviewStrictness: 2, costRisk: 1, stabilityRisk: 2, executionAuthority: 1),
      defaultAuthority: .brainOnly
    ),
  ]

  public static let leadStrategies: [LeadStrategy] = [
    LeadStrategy(
      id: "opus-5-lead",
      displayName: "Opus 5 主導",
      leadModelID: "opus-5",
      leadDisplayName: "Opus 5",
      plainBestWhen: "UI/UJ 驗收、L/XL、高風險架構、需要 fail-closed 的工作。",
      plainTradeoff: "更嚴格但成本高、速度慢；Codex/GPT 仍負責把裁決轉成可執行 patch 與測試。",
      modeFits: [.l, .xl],
      scenarioFits: [.design, .coding, .trading, .modeling, .daily],
      defaultTeamID: "opus-review-team",
      companionEffects: [
        LeadCompanionEffect(
          id: "opus-gpt-executor",
          modelID: "gpt-5.5",
          displayName: "GPT-5.5",
          roleWhenPaired: "落地收斂 / Codex host intent",
          effectSummary: "Opus 先定義 blocking 條件，GPT/Codex 把它轉成實作步驟與測試收據。",
          estimatedDelta: 1.0,
          caution: "GPT 不能覆蓋 Opus blocking finding；只能用實測證據解除。",
          requiredEvidence: ["blocking finding ledger", "diff/test receipt", "judge decision"]),
        LeadCompanionEffect(
          id: "opus-sonnet-code",
          modelID: "sonnet-5",
          displayName: "Sonnet 5",
          roleWhenPaired: "工程審稿 / patch intent",
          effectSummary: "Opus 把關高風險，Sonnet 補代碼一致性、漏測與局部 patch intent。",
          estimatedDelta: 1.2,
          caution: "Sonnet 的 patch intent 必須由 Codex 套用並跑測試。",
          requiredEvidence: ["diff review receipt", "test gap list"]),
        LeadCompanionEffect(
          id: "opus-minimax-candidates",
          modelID: "minimax-m3",
          displayName: "MiniMax M3",
          roleWhenPaired: "大量候選 / checklist",
          effectSummary: "Opus 設定篩選標準，MiniMax 扛大量變體、檢查清單與反例枚舉。",
          estimatedDelta: 0.9,
          caution: "大量候選容易假陽性；必須去重與驗證。",
          requiredEvidence: ["candidate summary", "dedupe notes"]),
        LeadCompanionEffect(
          id: "opus-grok-news",
          modelID: "grok-build",
          displayName: "Grok",
          roleWhenPaired: "消息反例 / 外部觀點",
          effectSummary: "Opus 做保守裁決，Grok 補最新消息、外部反例與客觀挑戰。",
          estimatedDelta: 0.9,
          caution: "消息沒有來源或交叉驗證時只能當假設。",
          requiredEvidence: ["source links", "cross-check status"]),
        LeadCompanionEffect(
          id: "opus-pro-memo",
          modelID: "chatgpt-pro-mcp",
          displayName: "ChatGPT Pro MCP",
          roleWhenPaired: "長 memo / 反方研究",
          effectSummary: "Opus 主導裁決，Pro MCP 產出 claim/evidence/rebuttal 給 Codex 驗證。",
          estimatedDelta: 1.0,
          caution: "Pro MCP 不是 dropdown，也不能直接寫檔或跑 shell。",
          requiredEvidence: ["claim ledger", "content hash", "Codex verification notes"]),
      ]),
    LeadStrategy(
      id: "gpt-5.5-lead",
      displayName: "GPT-5.5 主導",
      leadModelID: "gpt-5.5",
      leadDisplayName: "GPT-5.5",
      plainBestWhen: "S/M、小到中型實作、需要 Codex 工具語義與快速收斂的工作。",
      plainTradeoff: "落地強但不能自我驗收；UI/UJ、高風險與 L/XL 要加入 Opus/Verifier gate。",
      modeFits: [.s, .m, .l, .xl],
      scenarioFits: [.daily, .coding, .design, .modeling],
      defaultTeamID: "control-team",
      companionEffects: [
        LeadCompanionEffect(
          id: "gpt-opus-judge",
          modelID: "opus-5",
          displayName: "Opus 5",
          roleWhenPaired: "嚴格驗收 / 高風險 judge",
          effectSummary: "GPT 負責拆解與落地，Opus 負責擋下沒有證據的通過。",
          estimatedDelta: 1.1,
          caution: "UI 不能只靠 GPT 說過；必須有 screenshot/visual diff。",
          requiredEvidence: ["visual/test receipt", "judge decision"]),
        LeadCompanionEffect(
          id: "gpt-sonnet-review",
          modelID: "sonnet-5",
          displayName: "Sonnet 5",
          roleWhenPaired: "代碼審稿 / 漏測檢查",
          effectSummary: "GPT 定義架構與 patch 順序，Sonnet 檢查語法一致與測試缺口。",
          estimatedDelta: 1.0,
          caution: "Sonnet 不是最後裁判；結果仍要測試。",
          requiredEvidence: ["diff review", "test receipt"]),
        LeadCompanionEffect(
          id: "gpt-minimax-bulk",
          modelID: "minimax-m3",
          displayName: "MiniMax M3",
          roleWhenPaired: "大量 sub / 候選草稿",
          effectSummary: "GPT 做挑選合併，MiniMax 扛大量候選與 checklist。",
          estimatedDelta: 0.9,
          caution: "候選多不代表正確；要去重和驗證。",
          requiredEvidence: ["candidate summary", "accepted/rejected notes"]),
        LeadCompanionEffect(
          id: "gpt-grok-refuter",
          modelID: "grok-build",
          displayName: "Grok",
          roleWhenPaired: "消息 / 反方",
          effectSummary: "GPT 收斂決策，Grok 補外部消息與反例，避免過度保守。",
          estimatedDelta: 0.8,
          caution: "外部說法必須標註來源新鮮度。",
          requiredEvidence: ["freshness note", "source cross-check"]),
        LeadCompanionEffect(
          id: "gpt-pro-research",
          modelID: "chatgpt-pro-mcp",
          displayName: "ChatGPT Pro MCP",
          roleWhenPaired: "長文研究 / 反方 memo",
          effectSummary: "GPT 收斂成可執行行動，Pro MCP 補長研究與反方論證。",
          estimatedDelta: 1.0,
          caution: "Pro MCP 結論要回到 Codex 驗證，不直接當完成。",
          requiredEvidence: ["claim/evidence/rebuttal", "Codex verification notes"]),
      ]),
    LeadStrategy(
      id: "sonnet-5-lead",
      displayName: "Sonnet 5 主導",
      leadModelID: "sonnet-5",
      leadDisplayName: "Sonnet 5",
      plainBestWhen: "M/L 級 debug、代碼一致性、review-like 任務，需要先把工程邊界與漏測整理清楚。",
      plainTradeoff: "工程審稿更強，但仍不能直接改 host 或 final judge；Codex/GPT 負責落地，Opus 擋高風險。",
      modeFits: [.m, .l],
      scenarioFits: [.coding],
      defaultTeamID: "code-team",
      companionEffects: [
        LeadCompanionEffect(
          id: "sonnet-gpt-executor",
          modelID: "gpt-5.5",
          displayName: "GPT-5.5",
          roleWhenPaired: "Codex host 落地 / 測試收斂",
          effectSummary: "Sonnet 5 先整理工程一致性、漏測與 patch intent，GPT/Codex 負責套 patch、跑測試、產生收據。",
          estimatedDelta: 0.9,
          caution: "GPT 不能把 Sonnet 的漏測清單忽略；必須用測試或明確取捨解除。",
          requiredEvidence: ["diff/test receipt", "resolved test-gap list"]),
        LeadCompanionEffect(
          id: "sonnet-opus-risk",
          modelID: "opus-5",
          displayName: "Opus 5",
          roleWhenPaired: "高風險裁決 / blocking judge",
          effectSummary: "Sonnet 5 管代碼一致與漏測，Opus 管高風險是否可放行。",
          estimatedDelta: 0.8,
          caution: "Opus 只做裁決與反方，不替代 deterministic tests。",
          requiredEvidence: ["risk finding ledger", "judge decision"]),
        LeadCompanionEffect(
          id: "sonnet-minimax-cases",
          modelID: "minimax-m3",
          displayName: "MiniMax M3",
          roleWhenPaired: "測試案例 / checklist sub",
          effectSummary: "Sonnet 5 定義應測行為，MiniMax 補大量邊界案例候選。",
          estimatedDelta: 0.7,
          caution: "候選案例必須去重，不能把量當品質。",
          requiredEvidence: ["candidate test cases", "dedupe notes"]),
      ]),
    LeadStrategy(
      id: "minimax-m3-lead",
      displayName: "MiniMax M3 輕量主導",
      leadModelID: "minimax-m3",
      leadDisplayName: "MiniMax M3",
      plainBestWhen: "S 級低風險草稿、候選清單、初掃與便宜探索；需要快但不需要 host mutation。",
      plainTradeoff: "不能 final judge，也不能直接寫檔；如果要 Sonnet review 或 Codex patch，必須升到 M 並產生收據。",
      modeFits: [.s, .m],
      scenarioFits: [.daily, .modeling],
      defaultTeamID: "light-scout-team",
      companionEffects: [
        LeadCompanionEffect(
          id: "minimax-sonnet-review",
          modelID: "sonnet-5",
          displayName: "Sonnet 5",
          roleWhenPaired: "M 級審稿 / 一致性檢查",
          effectSummary: "MiniMax 先產出候選，Sonnet 在升級到 M 時檢查一致性與錯誤。",
          estimatedDelta: 0.7,
          caution: "S 模式仍是 0 helper；啟用 Sonnet review 等於升級 M。",
          requiredEvidence: ["mode upgrade note", "review receipt"]),
        LeadCompanionEffect(
          id: "minimax-gpt-host",
          modelID: "gpt-5.5",
          displayName: "GPT-5.5",
          roleWhenPaired: "Codex host 收斂 / 可執行化",
          effectSummary: "MiniMax 給草稿，GPT/Codex 把可用候選收斂成命令、patch 或答案。",
          estimatedDelta: 0.6,
          caution: "沒有 Codex trace 時不能宣稱已落地。",
          requiredEvidence: ["accepted/rejected notes", "host trace if patched"]),
      ]),
  ]

  public static let teams: [TeamDefinition] = {
    let controller = member(
      "gpt-5.5", "GPT-5.5", role: "主控 / 大架構歸納",
      responsibility: "定義目標、收斂各模型意見、交給 Codex executor 落地。", why: "它最懂 Codex 工作語義，但不能單獨驗收 UI。",
      authority: .toolIntentBridge)
    let minimax = member(
      "minimax-m3", "MiniMax M3", role: "大量 scout / 功能測試", responsibility: "產生候選、檢查清單、分檔掃描、功能測試點子。",
      why: "便宜高吞吐，適合扛量。", authority: .brainOnly, canBulkScout: true)
    let grok = member(
      "grok-build", "Grok", role: "消息 / 反例", responsibility: "查新消息、補外部觀點、挑戰過度保守結論。",
      why: "用來補 GPT 的保守盲點。", authority: .brainOnly)
    let sonnet = member(
      "sonnet-5", "Sonnet 5", role: "代碼審稿 / patch intent",
      responsibility: "審 diff、找漏測、提出可套用修補意圖。", why: "工程 reviewer 強，但不是最後裁判。",
      authority: .patchProposal)
    let opus = member(
      "opus-5", "Opus 5", role: "保守 judge", responsibility: "高風險、架構、UI/UX gate 的最後風險裁決。",
      why: "沒有證據就擋下，避免又被糟糕 UI 放行。", authority: .brainOnly, canFinalJudge: true)
    let opusLead = member(
      "opus-5", "Opus 5", role: "高風險主導 / 嚴格驗收",
      responsibility: "在 L/XL 或驗收導向任務中先定義 blocking 條件、證據順序與裁決標準。",
      why: "當任務重點是不要誤放行、不要讓 GPT 自己說過就過時，Opus 可以成為主導中心。",
      authority: .brainOnly, canFinalJudge: true)
    let sonnetLead = member(
      "sonnet-5", "Sonnet 5", role: "工程一致性主導",
      responsibility: "在 M 級 debug/code review 任務中先定義代碼邊界、漏測與一致性要求。",
      why: "當任務重點是代碼一致與漏測，不一定要 GPT 先主導；但仍需 Codex host 落地。",
      authority: .patchProposal)
    let minimaxLead = member(
      "minimax-m3", "MiniMax M3", role: "輕量候選主導",
      responsibility: "在 S 級低風險草稿或候選清單中先大量展開，再交 Codex/GPT 收斂。",
      why: "便宜、高吞吐，適合低風險起手；不是 final judge，也不直接寫檔。",
      authority: .brainOnly, canBulkScout: true)
    let pro = member(
      "chatgpt-pro-mcp", "ChatGPT Pro MCP", role: "研究審稿 / 來源 memo",
      responsibility: "產出 claim/evidence/rebuttal memo，供 Codex 驗證後採用。", why: "適合研究，不適合直接執行。",
      authority: .researchBridge)

    let controlBoundaries = [
      boundary(
        "lead-selection", "主導選擇", "GPT-5.5 / Opus 5",
        canDo: ["依任務選 GPT 主導或 Opus 主導", "高風險時改由 Opus 定義驗收", "記錄主導切換理由"],
        cannotDo: ["把 GPT 固定成唯一主導", "讓主導者自我驗收", "忽略情境差異"],
        evidence: ["lead selection receipt", "mode/scenario receipt"]),
      boundary(
        "controller", "主控", "GPT-5.5 + Codex", canDo: ["定義目標", "拆解任務", "收斂下一步"],
        cannotDo: ["自己 final pass", "繞過測試", "直接 host install"],
        evidence: ["plan receipt", "test/smoke receipt"]),
      boundary(
        "reviewer", "Reviewer", "Opus/Sonnet", canDo: ["找風險", "提出 blocking finding"],
        cannotDo: ["直接寫主機", "替代 Codex 測試"], evidence: ["review receipt"]),
      boundary(
        "verifier", "Verifier", "Codex deterministic checks", canDo: ["跑測試", "產生 smoke/evidence"],
        cannotDo: ["用感覺放行"], evidence: ["cli output", "build/test receipt"]),
    ]
    let designBoundaries = [
      boundary(
        "design-controller", "主控", "Opus 5 / GPT-5.5", canDo: ["依 lead strategy 定義畫面目標", "整理設計方向", "高風險 UI 可由 Opus 先定驗收"],
        cannotDo: ["UI final pass", "沒有截圖就驗收"], evidence: ["design brief", "visual checklist"]),
      boundary(
        "design-scout", "Scout", "MiniMax M3 / Grok", canDo: ["產生變體", "找趨勢與反例"],
        cannotDo: ["judge 裁決", "直接改主機"], evidence: ["候選清單", "反例清單"]),
      boundary(
        "design-builder", "Builder", "Codex executor", canDo: ["套用最小 UI patch", "跑 build/smoke"],
        cannotDo: ["把 build 當 UI pass"], evidence: ["diff", "build receipt"]),
      boundary(
        "design-verifier", "Verifier", "Codex screenshot/visual diff",
        canDo: ["截圖", "hash", "visual checklist"], cannotDo: ["只看 process alive"],
        evidence: ["截圖", "visual diff", "sha256 hash"]),
      boundary(
        "design-judge", "Judge", "Opus 5 / Human", canDo: ["擋下糟糕 UI", "判定 blocking issue"],
        cannotDo: ["自己實作 build", "無證據放行"], evidence: ["visual evidence", "resolved findings"]),
    ]
    let codeBoundaries = [
      boundary(
        "code-controller", "主控", "GPT-5.5 + Codex", canDo: ["拆 patch", "執行修改", "整理 reviewer 意見"],
        cannotDo: ["跳過測試", "讓 reviewer 自我放行"], evidence: ["diff", "test plan"]),
      boundary(
        "code-reviewer", "Reviewer", "Sonnet 5", canDo: ["審 diff", "找漏測", "提 patch intent"],
        cannotDo: ["host mutation", "final high-risk judge"], evidence: ["review receipt"]),
      boundary(
        "code-scout", "Scout", "MiniMax M3", canDo: ["補測試案例", "掃 checklist"],
        cannotDo: ["final pass"], evidence: ["test-case list"]),
      boundary(
        "code-judge", "Judge", "Opus 5", canDo: ["L/XL 風險裁決"], cannotDo: ["替代 test/smoke"],
        evidence: ["test/build/smoke receipts"]),
    ]
    let researchBoundaries = [
      boundary(
        "research-scout", "Scout", "Grok", canDo: ["找新消息", "提出反例"],
        cannotDo: ["唯一證據", "處理私密 raw log"], evidence: ["source links"]),
      boundary(
        "research-author", "Researcher", "ChatGPT Pro MCP",
        canDo: ["來源 memo", "claim/evidence/rebuttal"], cannotDo: ["同步 dropdown 執行", "寫檔跑 shell"],
        evidence: ["content hash", "claim ledger"]),
      boundary(
        "research-controller", "主控", "GPT-5.5 + Codex", canDo: ["收斂成可測行動", "驗證來源"],
        cannotDo: ["把 unsupported claim 當結論"], evidence: ["verification notes"]),
    ]
    let stabilityBoundaries = [
      boundary(
        "stability-inventory", "Scout", "MiniMax M3", canDo: ["設定盤點", "log 分類", "缺項清單"],
        cannotDo: ["改 auth/session", "寫 LaunchAgent"], evidence: ["inventory receipt"]),
      boundary(
        "stability-controller", "主控", "GPT-5.5 + Codex",
        canDo: ["制定 runbook", "跑 preflight/smoke"], cannotDo: ["未備份就 host mutation"],
        evidence: ["preflight", "sandbox smoke"]),
      boundary(
        "stability-judge", "Judge", "Opus 5", canDo: ["斷線風險裁決", "fail-closed review"],
        cannotDo: ["替代 live same-thread smoke"],
        evidence: ["same-thread smoke receipt", "MCP smoke receipt"]),
      boundary(
        "stability-host-gate", "Host Gate", "Human + Codex", canDo: ["人工批准後實裝"],
        cannotDo: ["自動放行 host install"], evidence: ["human approval", "backup receipt"]),
    ]
    let tradingBoundaries = [
      boundary(
        "trading-reader", "主控", "GPT-5.5 + Codex", canDo: ["只讀整理", "產生風險摘要"],
        cannotDo: ["下單", "改槓桿/停損/倉位"], evidence: ["read-only proof"]),
      boundary(
        "trading-refuter", "Scout", "Grok", canDo: ["市場消息反例"], cannotDo: ["唯一交易依據"],
        evidence: ["source links"]),
      boundary(
        "trading-judge", "Judge", "Opus 5 / Claude trade-review", canDo: ["風控副審"],
        cannotDo: ["批准 live mutation"], evidence: ["human risk approval if live"]),
    ]
    let memoryBoundaries = [
      boundary(
        "memory-writer", "主控", "GPT-5.5", canDo: ["蒸餾安全摘要"], cannotDo: ["保存 raw log/token/完整聊天"],
        evidence: ["redaction scan"]),
      boundary(
        "memory-classifier", "Scout", "MiniMax M3", canDo: ["分類 failure mode"],
        cannotDo: ["寫入最終記憶"], evidence: ["classification receipt"]),
      boundary(
        "memory-judge", "Judge", "Opus/GPT", canDo: ["檢查過度泛化"], cannotDo: ["保存私密路徑"],
        evidence: ["SafeMemoryGate"]),
    ]

    let opusLeadBoundaries = [
      boundary(
        "opus-lead", "Opus 主導", "Opus 5",
        canDo: ["定義 blocking 條件", "要求更嚴格驗收", "對高風險結果 fail-closed"],
        cannotDo: ["直接執行主機修改", "替代 Codex 測試", "無證據通過"],
        evidence: ["blocking finding ledger", "judge receipt"]),
      boundary(
        "opus-lead-executor", "執行宿主", "Codex + GPT-5.5",
        canDo: ["把 Opus 裁決轉成 patch/test", "跑 deterministic checks", "整理落地收據"],
        cannotDo: ["覆蓋 Opus blocking finding", "跳過 sandbox/test"],
        evidence: ["diff", "test/smoke receipt"]),
      boundary(
        "opus-lead-support", "補位", "Sonnet / Grok / MiniMax / ChatGPT Pro MCP",
        canDo: ["代碼審稿", "消息反例", "大量候選", "研究 memo"],
        cannotDo: ["final pass", "直接 host mutation"],
        evidence: ["review/source/candidate receipt"]),
    ]

    let lightScoutBoundaries = [
      boundary(
        "minimax-light-lead", "MiniMax 輕量主導", "MiniMax M3",
        canDo: ["低風險候選清單", "草稿", "初步分類"],
        cannotDo: ["final judge", "host mutation", "宣稱已執行工具"],
        evidence: ["candidate summary", "accepted/rejected notes"]),
      boundary(
        "light-upgrade", "升級門檻", "Codex / Sonnet",
        canDo: ["需要審稿時升級 M", "把候選轉成可驗收行動"],
        cannotDo: ["在 S 模式偷偷開 helper", "無 mode receipt 啟用 Sonnet"],
        evidence: ["mode upgrade note", "review receipt if M"]),
    ]

    let visualGate = TeamGate(
      id: "visual-proof", title: "視覺證據 gate",
      plainRule: "UI/UX 不能靠口頭或 build pass；要截圖、錄影或 visual diff。",
      requiredEvidence: [.screenshot, .visualDiff], failClosedMessage: "沒有視覺證據就不通過。")
    let testGate = TeamGate(
      id: "test-proof", title: "測試證據 gate", plainRule: "代碼完成必須有 test/build/smoke，不用 reviewer 感覺放行。",
      requiredEvidence: [.unitTest, .build, .smoke], failClosedMessage: "沒有可重跑測試就不通過。")
    let sandboxGate = TeamGate(
      id: "sandbox-proof", title: "沙盒 gate",
      plainRule: "L/XL 先在 sandbox 跑，沒過不實裝主機；Colima 可作額外隔離驗證，但缺少時只降級。",
      requiredEvidence: [.sandboxRun, .cliOutput], failClosedMessage: "沙盒沒過就停。")
    let researchGate = TeamGate(
      id: "claim-evidence", title: "來源 gate", plainRule: "每個重要 claim 要有 evidence，沒有就是假設。",
      requiredEvidence: [.cliOutput], failClosedMessage: "沒有來源或可驗證證據，不升級成結論。")
    let tradingGate = TeamGate(
      id: "no-live-order", title: "交易風控 gate", plainRule: "預設只讀；不下單、不改槓桿/停損/倉位；涉及資金要人工風控。",
      requiredEvidence: [.cliOutput], failClosedMessage: "任何 live risk mutation 都要停下等人工批准。")
    let memoryGate = TeamGate(
      id: "safe-memory", title: "安全記憶 gate",
      plainRule: "只存摘要、偏好、failure mode；不存 raw log、token、完整聊天、私密路徑。",
      requiredEvidence: [.redactionScan], failClosedMessage: "不安全內容不得寫入記憶。")

    let visualLoop = TeamWorkflowLoop(
      id: "visual-loop",
      title: "設計視覺 loop",
      plainSteps: [
        "GPT 定義畫面目標", "MiniMax 產生多個變體/檢查清單", "Grok 補趨勢或反例", "Codex 實作最小變更",
        "截圖/hash/visual checklist", "Opus 或人工 judge",
      ],
      scriptsOrCommands: [
        "swift test", "swift run tatwo-ultrawork validate receipt --file <receipt.json> --json",
        "browser/simulator screenshot command",
      ],
      sandboxPolicy: "UI 先在 sandbox app data 或 preview 中驗收；不能只看 process alive。",
      stopCondition: "視覺證據通過，或 judge 指出 blocking UI 問題時停下修。",
      requiredReceipts: [
        "design brief", "screenshot or recording", "visual diff/hash", "judge decision",
      ]
    )
    let codeLoop = TeamWorkflowLoop(
      id: "code-loop",
      title: "代碼修改 loop",
      plainSteps: [
        "先寫失敗測試或 smoke", "Codex executor 落地", "Sonnet 審 diff", "MiniMax 補測試案例", "Opus 審 L/XL 風險",
        "測試綠才收據",
      ],
      scriptsOrCommands: [
        "swift test", "swift build --product tatwo-ultrawork",
        "swift run tatwo-ultrawork colima run --mode L --scenario code --objective '<objective>' --dry-run --json",
        "node scripts/tatwo-ultrawork-mcp-smoke.mjs",
      ],
      sandboxPolicy: "涉及 gateway/App/MCP 時先用 sandbox 臨時 state 與測試 port；不得直接碰 host config。",
      stopCondition: "測試與 smoke 綠；第二輪 reviewer 無新 blocking。",
      requiredReceipts: [
        "failing-test or smoke plan", "diff receipt", "test/build output",
        "reviewer finding ledger",
      ]
    )
    let researchLoop = TeamWorkflowLoop(
      id: "research-loop",
      title: "研究情報 loop",
      plainSteps: [
        "Grok 找新消息/反例", "ChatGPT Pro MCP 做來源 memo", "GPT 收斂成可執行結論",
        "Codex 驗證 primary sources 或本地測試",
      ],
      scriptsOrCommands: [
        "tatwo-ultrawork handoff pack --mode L --scenario modeling --objective '<objective>' --json"
      ],
      sandboxPolicy: "研究 lane 只讀；不得寫檔或改設定，只回 public-safe memo。",
      stopCondition: "claim ledger 無 P0/P1 unsupported claim。",
      requiredReceipts: [
        "source list", "claim/evidence ledger", "content hash", "Codex verification notes",
      ]
    )
    let stabilityLoop = TeamWorkflowLoop(
      id: "stability-loop",
      title: "環境穩定 loop",
      plainSteps: [
        "只讀 preflight", "確認 gateway/Codex App/CLI 版本與 auth 狀態", "沙盒 smoke", "備份", "人工授權後實裝",
        "post-install same-thread smoke",
      ],
      scriptsOrCommands: [
        "tatwo-ultrawork integration stability --json", "tatwo-ultrawork colima preflight --json",
        "bash scripts/install-tatwo-ultrawork.sh --preflight",
        "bash scripts/tatwo-ultrawork-sandbox-check.sh",
      ],
      sandboxPolicy:
        "沙盒不得改 ~/.codex、signed app bundle 或真實 LaunchAgent；Colima 不自動安裝、不自動啟動、不掛 HOME/Secrets。",
      stopCondition: "所有穩定 guard 綠；任一 disconnect 風險未解就不實裝。",
      requiredReceipts: [
        "preflight receipt", "sandbox evidence bundle", "host readiness gate",
        "same-thread smoke receipt", "rollback receipt",
      ]
    )
    let tradingLoop = TeamWorkflowLoop(
      id: "trading-readonly-loop",
      title: "交易只讀風控 loop",
      plainSteps: ["只讀盤點", "Grok 補市場/消息反例", "Opus/Claude trade-review 風控", "人工確認才允許下一步"],
      scriptsOrCommands: ["tatwo-ultrawork teams recommend --scenario trading --mode L --json"],
      sandboxPolicy: "交易情境永遠只讀/read-only 起手；不碰 secrets，不下單。",
      stopCondition: "若需要資金/槓桿/停損/倉位改動，立即停止等人工風控。",
      requiredReceipts: [
        "read-only proof", "risk review receipt", "human approval if live mutation",
      ]
    )
    let memoryLoop = TeamWorkflowLoop(
      id: "safe-memory-loop",
      title: "安全記憶 loop",
      plainSteps: ["GPT 蒸餾一句 failure mode", "MiniMax 分類", "Opus/GPT 檢查是否過度泛化", "SafeMemoryGate"],
      scriptsOrCommands: [
        "tatwo-ultrawork memory add --category failure_mode --summary '<safe summary>' --json"
      ],
      sandboxPolicy: "記憶不得保存原始聊天、token、raw log、私密路徑。",
      stopCondition: "SafeMemoryGate 通過，否則不寫。",
      requiredReceipts: ["safe summary", "redaction scan", "SafeMemoryGate receipt"]
    )

    return [
      TeamDefinition(
        id: "control-team", chineseName: "總控團隊", plainPurpose: "把任務拆清楚、決定何時開隊伍、何時停止。",
        scenarioFits: [.daily, .coding, .design, .modeling], modeFits: [.s, .m, .l, .xl],
        readOnlyByDefault: false, members: [controller, opus], loops: [codeLoop],
        gates: [testGate, sandboxGate], roleBoundaries: controlBoundaries,
        forbidden: ["模型自己亂開工具", "沒有 done condition 就開 XL"]),
      TeamDefinition(
        id: "light-scout-team", chineseName: "輕量候選團隊",
        plainPurpose: "S 級低風險任務可由 MiniMax 先做候選/草稿主導；需要審稿或 patch 時升 M。",
        scenarioFits: [.daily, .modeling], modeFits: [.s, .m], readOnlyByDefault: true,
        members: [minimaxLead, sonnetLead, controller], loops: [researchLoop],
        gates: [researchGate], roleBoundaries: lightScoutBoundaries,
        forbidden: ["S 模式偷偷開 helper", "MiniMax final judge", "沒有 host trace 卻宣稱已改檔"]),
      TeamDefinition(
        id: "opus-review-team", chineseName: "Opus 主導審查團隊",
        plainPurpose: "L/XL、高風險、UI 驗收或架構裁決時，改由 Opus 先定義通過條件，再讓其他模型補位。",
        scenarioFits: [.coding, .design, .modeling, .daily], modeFits: [.l, .xl],
        readOnlyByDefault: true, members: [opusLead, controller, sonnet, grok, minimax, pro],
        loops: [codeLoop, visualLoop, researchLoop], gates: [testGate, visualGate, researchGate, sandboxGate],
        roleBoundaries: opusLeadBoundaries,
        forbidden: ["GPT 固定唯一主導", "Opus 無證據放行", "外部模型直接 host mutation"]),
      TeamDefinition(
        id: "design-team", chineseName: "設計團隊",
        plainPurpose: "專門處理 UI/UX：先定義畫面目標，再用截圖驗收，避免 GPT 說過就過。", scenarioFits: [.design],
        modeFits: [.m, .l, .xl], readOnlyByDefault: false,
        members: [opusLead, controller, opus, sonnet, minimax, grok], loops: [visualLoop],
        gates: [visualGate, testGate], roleBoundaries: designBoundaries,
        forbidden: ["build pass 當 UI pass", "GPT 單獨 final pass UI", "沒有截圖就宣稱修好"]),
      TeamDefinition(
        id: "code-team", chineseName: "代碼團隊", plainPurpose: "工程落地、測試、審稿，讓 Codex 當唯一執行宿主。",
        scenarioFits: [.coding], modeFits: [.m, .l, .xl], readOnlyByDefault: false,
        members: [controller, sonnetLead, sonnet, minimax, opus], loops: [codeLoop],
        gates: [testGate, sandboxGate], roleBoundaries: codeBoundaries,
        forbidden: ["外部模型直接寫主機", "測試紅還宣稱完成", "reviewer 自己 final pass"]),
      TeamDefinition(
        id: "research-team", chineseName: "研究情報團隊",
        plainPurpose: "處理新消息、來源、反例與長 memo，最後由 GPT 收斂成可驗證行動。", scenarioFits: [.modeling, .daily],
        modeFits: [.m, .l, .xl], readOnlyByDefault: true, members: [grok, pro, controller, opus],
        loops: [researchLoop], gates: [researchGate], roleBoundaries: researchBoundaries,
        forbidden: ["無來源結論進部署", "把 ChatGPT Pro MCP 當同步 dropdown 模型"]),
      TeamDefinition(
        id: "stability-team", chineseName: "環境穩定團隊",
        plainPurpose: "專門防 Codex 斷線、gateway 崩潰、auth/cache/version 漂移。",
        scenarioFits: [.coding, .daily], modeFits: [.l, .xl], readOnlyByDefault: true,
        members: [controller, minimax, opus], loops: [stabilityLoop],
        gates: [sandboxGate, testGate, memoryGate], roleBoundaries: stabilityBoundaries,
        forbidden: ["沙盒中改真實 LaunchAgent", "patch signed Codex App bundle", "未備份就改 host config"]),
      TeamDefinition(
        id: "trading-risk-team", chineseName: "交易風控團隊",
        plainPurpose: "交易相關永遠只讀起手；任何資金/下單/槓桿/停損都要額外風控。", scenarioFits: [.trading],
        modeFits: [.l, .xl], readOnlyByDefault: true, members: [controller, grok, opus],
        loops: [tradingLoop], gates: [tradingGate, researchGate], roleBoundaries: tradingBoundaries,
        forbidden: ["直接下單", "改 live risk", "讀取或外傳 secrets"]),
      TeamDefinition(
        id: "memory-team", chineseName: "記憶/知識團隊", plainPurpose: "把成功/失敗經驗壓成安全、可復用、低污染的記憶。",
        scenarioFits: [.daily, .coding, .design, .modeling], modeFits: [.m, .l, .xl],
        readOnlyByDefault: true, members: [controller, minimax, opus], loops: [memoryLoop],
        gates: [memoryGate], roleBoundaries: memoryBoundaries,
        forbidden: ["保存 raw log", "保存 token", "保存完整聊天或私密路徑"]),
    ]
  }()

  public static func recommend(mode: WorkModeID, scenario: ScenarioID) -> TeamRecommendation {
    let lead = leadStrategy(mode: mode, scenarioProfileID: nil, scenario: scenario)
    let primaryID: String
    switch scenario {
    case .design: primaryID = "design-team"
    case .coding: primaryID = "code-team"
    case .trading: primaryID = "trading-risk-team"
    case .modeling: primaryID = "research-team"
    case .daily: primaryID = mode == .s ? "control-team" : "stability-team"
    }
    let primary = teams.first { $0.id == primaryID } ?? teams[0]
    let stabilityMode = mode >= .l
    let support = teams.filter { team in
      team.id != primary.id
        && (team.scenarioFits.contains(scenario) || team.id == "memory-team"
          || team.id == lead.defaultTeamID
          || (stabilityMode && team.id == "stability-team")
          || (stabilityMode && scenario != .trading && team.id == "opus-review-team"))
    }
    let loops = uniqueLoops(primary.loops + support.flatMap(\.loops))
    let gateLabels = primary.gates.map { "\($0.title)：\($0.plainRule)" }
    let stabilityNotes = [
      "主導中心：\(lead.displayName)。主導模型依 mode/scenario 選擇，不固定 GPT-5.5。",
      "所有外部模型只能給 brain / patch intent；Codex executor 才能套用與跑測試。",
      mode >= .xl ? "XL 必須先 sandbox，再人工授權 host install。" : "使用能完成任務的最低模式，不自動升 XL。",
      "UI/UX 需要截圖或 visual diff；build/process alive 不算通過。",
    ]
    return TeamRecommendation(
      mode: mode, scenario: scenario, leadStrategy: lead, primaryTeam: primary, supportingTeams: support,
      requiredGates: gateLabels, workflowLoops: loops, stabilityNotes: stabilityNotes)
  }

  public static func leadStrategy(mode: WorkModeID, scenario: ScenarioID) -> LeadStrategy {
    leadStrategy(mode: mode, scenarioProfileID: nil, scenario: scenario)
  }

  public static func leadStrategy(
    mode: WorkModeID,
    scenarioProfileID: String?,
    scenario: ScenarioID
  ) -> LeadStrategy {
    let preferredID: String
    let normalizedProfile = scenarioProfileID?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    switch (mode, scenario, normalizedProfile) {
    case (.s, .daily, _), (.s, .modeling, _):
      preferredID = "minimax-m3-lead"
    case (.m, .coding, "debug"):
      preferredID = "sonnet-5-lead"
    case (.xl, _, _):
      preferredID = "opus-5-lead"
    case (.l, .design, _), (.l, .trading, _):
      preferredID = "opus-5-lead"
    default:
      preferredID = "gpt-5.5-lead"
    }
    return leadStrategies.first { $0.id == preferredID }
      ?? leadStrategies.first { $0.id == "gpt-5.5-lead" }
      ?? LeadStrategy(
        id: "fallback-gpt-lead",
        displayName: "GPT-5.5 主導",
        leadModelID: "gpt-5.5",
        leadDisplayName: "GPT-5.5",
        plainBestWhen: "fallback",
        plainTradeoff: "fallback",
        modeFits: [.s, .m, .l, .xl],
        scenarioFits: [.daily, .coding, .design, .trading, .modeling],
        defaultTeamID: "control-team",
        companionEffects: [])
  }

  public static func readinessDashboard(mode: WorkModeID, scenario: ScenarioID)
    -> TeamReadinessDashboard
  {
    let recommendation = recommend(mode: mode, scenario: scenario)
    let selected = [recommendation.primaryTeam] + recommendation.supportingTeams
    let scripts = readinessScripts(mode: mode, scenario: scenario)
    let receipts = readinessReceipts(scenario: scenario)
    let cards = selected.map { team in
      TeamReadinessCard(
        team: team,
        modelTraitIDs: Array(Set(team.members.map(\.modelID))).sorted(),
        loopIDs: team.loops.map(\.id),
        gateIDs: team.gates.map(\.id),
        scriptIDs: scripts.filter {
          $0.ownerTeamID == team.id
            || ($0.ownerTeamID == "stability-team" && team.id == "stability-team")
        }.map(\.id),
        receiptIDs: receipts.filter {
          $0.ownerTeamID == team.id
            || ($0.ownerTeamID == "stability-team" && team.id == "stability-team")
            || ($0.ownerTeamID == "design-team" && team.id == "design-team")
        }.map(\.id),
        plainNextCheck: nextCheck(for: team)
      )
    }

    return TeamReadinessDashboard(
      mode: mode,
      scenario: scenario,
      leadStrategy: recommendation.leadStrategy,
      availableLeadStrategies: leadStrategies,
      uiDeferred: true,
      hostMutationAllowed: false,
      hostInstallAllowed: false,
      plainSummary:
        "目前主導中心為 \(recommendation.leadStrategy.displayName)；協作流可依任務切換 Opus/GPT 主導，不固定 GPT。任何 host install 都必須等沙盒、備份、rollback、live same-thread、host MCP 註冊與人工授權收據齊全。",
      modelTraits: modelTraits,
      selectedTeams: cards,
      scripts: scripts,
      receipts: receipts,
      failClosedRules: [
        "外部 reviewer 斷線或沒有工具 trace，只能記為 reviewer_unavailable，不得當作 pass。",
        "mcp-stdio 相容 smoke 不能升級成 mcp-host registration receipt。",
        "same-thread dry-run 不能升級成 live same-thread smoke receipt。",
        "UI build/process alive 不能通過 UI/UX；必須有 screenshot、visual diff/hash、checklist 與 judge。",
        "GPT-5.5 可以主控與收斂，但不得單獨 final pass 自己主控的 UI 或高風險結果。",
        "不得把 GPT-5.5 固定成唯一主導；L/XL、高風險或驗收導向任務預設切換 Opus 5 主導。",
        "這個 dashboard 只讀；不改 ~/.codex、不寫 LaunchAgent、不 patch signed Codex App bundle。",
      ],
      nextCommands: [
        "swift run --package-path . tatwo-ultrawork teams dashboard --mode \(mode.rawValue) --scenario \(scenario.rawValue) --json",
        "node scripts/tatwo-team-loop.mjs --mode \(mode.rawValue) --scenario \(scenario.rawValue) --objective '<objective>'",
        "swift run --package-path . tatwo-ultrawork colima run --mode \(mode.rawValue) --scenario \(scenario.rawValue) --objective '<objective>' --dry-run --json",
        "MODEL_GATEWAY_DIR=<gateway-dir> OPEN_ULTRAWORK_DIR=<open-ultrawork-dir> bash scripts/tatwo-ultrawork-sandbox-check.sh",
        "node scripts/tatwo-host-install-runway.mjs --latest --json",
      ]
    )
  }

  private static func readinessScripts(mode: WorkModeID, scenario: ScenarioID)
    -> [TeamReadinessScript]
  {
    [
      TeamReadinessScript(
        id: "swift-tests", title: "Swift 測試", ownerTeamID: "code-team",
        command: "swift test --package-path .",
        plainPurpose: "證明核心 catalog、驗收 gate、host runway 結構可重跑。"),
      TeamReadinessScript(
        id: "team-dashboard", title: "團隊 readiness dashboard", ownerTeamID: "control-team",
        command:
          "swift run --package-path . tatwo-ultrawork teams dashboard --mode \(mode.rawValue) --scenario \(scenario.rawValue) --json",
        plainPurpose: "把模型特質、團隊、loop、script、收據與 fail-closed 規則集中成一張可讀儀表板。"),
      TeamReadinessScript(
        id: "team-loop", title: "團隊 loop packet", ownerTeamID: "control-team",
        command:
          "node scripts/tatwo-team-loop.mjs --mode \(mode.rawValue) --scenario \(scenario.rawValue) --objective '<objective>'",
        plainPurpose: "給 Codex/MCP/外部 reviewer 的短任務包，標清 role boundary 與 required receipts。"),
      TeamReadinessScript(
        id: "colima-preflight", title: "Colima 可選沙盒 preflight", ownerTeamID: "stability-team",
        command: "swift run --package-path . tatwo-ultrawork colima preflight --json",
        plainPurpose: "檢查 Colima/Docker 是否可作 L/XL 額外隔離驗證；缺少時降級不阻塞。"),
      TeamReadinessScript(
        id: "colima-dry-run", title: "Colima 可選沙盒 dry-run", ownerTeamID: "stability-team",
        command:
          "swift run --package-path . tatwo-ultrawork colima run --mode \(mode.rawValue) --scenario \(scenario.rawValue) --objective '<objective>' --dry-run --json",
        plainPurpose: "產生可選 Colima 驗證計畫與安全限制收據，不自動執行容器。"),
      TeamReadinessScript(
        id: "sandbox-check", title: "沙盒總檢", ownerTeamID: "stability-team",
        command: "bash scripts/tatwo-ultrawork-sandbox-check.sh",
        plainPurpose: "在不碰主機的情況下跑完整 build/test/MCP/redaction/對抗驗證。"),
      TeamReadinessScript(
        id: "integration-adversarial", title: "整合對抗驗證", ownerTeamID: "stability-team",
        command:
          "node scripts/tatwo-integration-adversarial-drill.mjs --evidence-dir <evidence-dir> --json",
        plainPurpose: "證明 forged receipts、stdio-only、dry-run evidence 不能冒充 host pass。"),
      TeamReadinessScript(
        id: "host-preflight", title: "主機只讀 preflight", ownerTeamID: "stability-team",
        command: "node scripts/tatwo-host-preflight.mjs --json",
        plainPurpose: "只讀檢查 Codex App/CLI/gateway/app-server/fast/auto-compact 風險。"),
      TeamReadinessScript(
        id: "host-sandbox-rehearsal", title: "假 HOME 實裝演練", ownerTeamID: "stability-team",
        command: "node scripts/tatwo-host-sandbox-rehearsal.mjs --json",
        plainPurpose: "在 fake HOME/CODEX_HOME 演練備份、MCP 註冊、rollback，不碰真主機。"),
      TeamReadinessScript(
        id: "host-runway", title: "host install runway", ownerTeamID: "stability-team",
        command: "node scripts/tatwo-host-install-runway.mjs --latest --json",
        plainPurpose: "顯示目前是否 sandbox ready、缺哪些真實 host 收據、下一步能不能實裝。"),
      TeamReadinessScript(
        id: "verified-gate", title: "證據型最後 gate", ownerTeamID: "stability-team",
        command:
          "node scripts/tatwo-host-install-verified-gate.mjs --latest --human-approval human-YYYYMMDD-scope --json",
        plainPurpose: "只根據 evidence bundle 裁決；缺 live 收據就擋。"),
      TeamReadinessScript(
        id: "visual-gate", title: "UI fail-closed 範例", ownerTeamID: "design-team",
        command: "swift run --package-path . tatwo-ultrawork validate sample-ui --json",
        plainPurpose: "證明只有 build/process alive 的 UI 會被擋下。"),
    ]
  }

  private static func readinessReceipts(scenario: ScenarioID) -> [TeamReadinessReceipt] {
    var receipts = [
      TeamReadinessReceipt(
        id: "sandbox-validated", title: "沙盒通過收據", ownerTeamID: "stability-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: true,
        passRule: "host-readiness-gate.log status=passed 且 sandboxValidated=true。",
        failureIfMissing: "不准進入主機實裝。"),
      TeamReadinessReceipt(
        id: "host-sandbox-rehearsal", title: "假 HOME 演練收據", ownerTeamID: "stability-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: true,
        passRule:
          "realHostMutationPerformed=false、rollbackValidated=true、mcpCompatibilityPassed=true。",
        failureIfMissing: "不准碰真 HOME/CODEX_HOME。"),
      TeamReadinessReceipt(
        id: "host-preflight-clear", title: "主機只讀 preflight clear", ownerTeamID: "stability-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: false,
        passRule: "critical/high unknown 都有處理；不讀 token、不 kill process。",
        failureIfMissing: "未知斷線風險未排除。"),
      TeamReadinessReceipt(
        id: "host-backup", title: "主機備份收據", ownerTeamID: "stability-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: false,
        passRule: "backup-* receipt；備份 config/state/cache，不含 auth/session。",
        failureIfMissing: "裝壞無法回去。"),
      TeamReadinessReceipt(
        id: "rollback", title: "回滾驗證收據", ownerTeamID: "stability-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: false,
        passRule: "rollback-* receipt；可指出每個還原目標。", failureIfMissing: "不准 host mutation。"),
      TeamReadinessReceipt(
        id: "live-same-thread", title: "live 同 thread 多模型 smoke", ownerTeamID: "stability-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: false,
        passRule: "same-thread-* receipt；GPT → 外部模型 → GPT 在同一 thread 通過。",
        failureIfMissing: "不能證明 Codex 不斷線或不失上下文。"),
      TeamReadinessReceipt(
        id: "mcp-host-registration", title: "host MCP 註冊 smoke", ownerTeamID: "stability-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: false,
        passRule: "mcp-host-* receipt；hostRegistrationObserved=true。",
        failureIfMissing: "stdio-only 不能當作 host 已接上。"),
      TeamReadinessReceipt(
        id: "human-approval", title: "人工授權", ownerTeamID: "control-team",
        requiredBeforeHostInstall: true, dryRunCanSatisfy: false,
        passRule: "human-* 或 approval-* ID，且人類知道 scope、備份、rollback。", failureIfMissing: "自動實裝被擋。"),
    ]
    if scenario == .design {
      receipts.append(
        TeamReadinessReceipt(
          id: "visual-proof", title: "UI 視覺證據", ownerTeamID: "design-team",
          requiredBeforeHostInstall: false, dryRunCanSatisfy: false,
          passRule: "screenshot/recording + visual diff/hash + checklist + judge decision。",
          failureIfMissing: "UI/UX 不得宣稱完成。"))
    }
    return receipts
  }

  private static func nextCheck(for team: TeamDefinition) -> String {
    switch team.id {
    case "design-team":
      return "先確定 screenshot/visual diff gate 可重跑；沒有圖就不讓 UI 過。"
    case "stability-team":
      return "先看 sandbox evidence、host runway、same-thread smoke 與 MCP host registration 缺口。"
    case "code-team":
      return "先跑 swift test/build/MCP smoke，讓 reviewer 只審有 diff 與測試的結果。"
    case "research-team":
      return "先把 claim/evidence/rebuttal 拆清楚；unsupported claim 只能當假設。"
    case "trading-risk-team":
      return "保持 read-only；涉及資金、下單、槓桿、停損就停下等人工風控。"
    case "memory-team":
      return "只保存安全摘要與 failure mode；先跑 redaction scan。"
    default:
      return "先確認 done condition、停止條件與需要的收據。"
    }
  }

  private static func member(
    _ modelID: String,
    _ displayName: String,
    role: String,
    responsibility: String,
    why: String,
    authority: AuthorityMode,
    canBulkScout: Bool = false,
    canFinalJudge: Bool = false
  ) -> TeamMember {
    TeamMember(
      id: "\(modelID)-\(role.hashValue.magnitude)",
      modelID: modelID,
      displayName: displayName,
      teamRole: role,
      plainResponsibility: responsibility,
      whyHere: why,
      authority: authority,
      canBulkScout: canBulkScout,
      canFinalJudge: canFinalJudge,
      canDirectlyMutateHost: false
    )
  }

  private static func boundary(
    _ id: String,
    _ roleName: String,
    _ owner: String,
    canDo: [String],
    cannotDo: [String],
    evidence: [String]
  ) -> TeamRoleBoundary {
    TeamRoleBoundary(
      id: id,
      roleName: roleName,
      owner: owner,
      canDo: canDo,
      cannotDo: cannotDo,
      evidenceBeforePass: evidence
    )
  }

  private static func uniqueLoops(_ loops: [TeamWorkflowLoop]) -> [TeamWorkflowLoop] {
    var seen = Set<String>()
    return loops.filter { loop in
      guard !seen.contains(loop.id) else { return false }
      seen.insert(loop.id)
      return true
    }
  }
}

public enum IntegrationPlanner {
  public static func fuguArchitecturePolicy() -> FuguArchitecturePolicy {
    FuguArchitecturePolicy(
      integratesFuguModel: false,
      plainSummary: "Fugu 在 Tatwo v1 只當架構參考：吸收多模型入口、按任務難度組隊、分派→驗證→合併、可回朔收據；不接入 Fugu 模型。",
      adoptedIdeas: [
        "一個入口包住多模型分工，使用者不用每次手動想誰該做什麼。",
        "任務越難才自動組隊；簡單任務維持 S/M，不開大陣仗。",
        "模型池可替換、可禁用，避免單一供應商或單一路由失效。",
        "每輪必須有分派、驗證、合併，不能只收集模型意見。",
        "長任務留下可回朔收據，之後可以接續與審查。",
      ],
      rejectedIdeas: [
        "不接入 Fugu 模型，也不建立 install fugu 依賴。",
        "不做黑盒單 API；Tatwo 必須看得懂誰做了什麼。",
        "不讓模型自己亂開工具或寫檔；Codex executor 才能執行 side effect。",
        "不做無上限遞迴協作；S/M/L/XL 都有 helper、輪次與 budget 硬上限。",
        "不預設按量 API fan-out，避免額度爆炸。",
        "不把所有 session/auth 合併共用，避免壞掉牽連整台。",
      ],
      guardrails: [
        "所有 Fugu-inspired flow 先在沙盒跑；沙盒證據不等於主機實裝通過。",
        "主機實裝前仍需人工授權、備份、rollback、live same-thread smoke、mcp-host registration。",
        "外部模型只能提出 brain/patch/tool intent；Codex executor 產生工具 trace、測試與收據。",
        "任何 route 有 stale error、error_kind 或沒有 last_ok，都不能藏在 gateway health 綠燈後面。",
        "所有可重用記憶只存偏好與 failure mode，不存 raw log、token、完整聊天或私密路徑。",
      ],
      verificationSignals: [
        "teams dashboard 顯示模型特質、團隊、loop、script、receipt 與 fail-closed rules。",
        "tatwo-codex-disconnect-guard.mjs 通過 single provider、response.in_progress、clean 413、route-error-state。",
        "tatwo-integration-adversarial-drill.mjs 擋下 forged receipt、stdio-only、dry-run promotion。",
        "tatwo-host-install-verified-gate.mjs 在缺 live host 收據時必須 blocked。",
        "沒有任何 install plan、dependency 或 prompt 要求安裝 Fugu。",
      ]
    )
  }

  public static func makePlan() -> IntegrationPlan {
    IntegrationPlan(
      hostMutationDefault: false,
      stages: [
        IntegrationStage(
          id: "preflight",
          title: "只讀 preflight",
          plainGoal:
            "先確認 Codex App/CLI、Swift、Node、gateway、open-ultrawork、MCP 與可選 Colima 驗證器是否存在，不改主機。",
          requiresHumanApproval: false,
          mayMutateHost: false,
          checks: [
            "codex CLI/App exists", "swift --version", "node --version",
            "gateway health if enabled", "open-ultrawork selftest if present",
            "MCP registry dry-run", "tatwo-ultrawork colima preflight --json optional",
          ],
          deniedActions: [
            "mutate_host_codex_config", "write_real_launchagent", "patch_signed_codex_app_bundle",
            "auto_install_or_start_colima",
          ],
          doneCondition: "缺項以 install/skip/later 顯示，不能靜默假裝可用。"
        ),
        IntegrationStage(
          id: "sandbox-smoke",
          title: "沙盒 smoke",
          plainGoal: "使用臨時 workspace、臨時 app data、測試 gateway port，先跑到無誤。",
          requiresHumanApproval: false,
          mayMutateHost: false,
          checks: [
            "swift test", "build CLI/app", "tatwo-ultrawork doctor", "workflow dry-run",
            "tatwo-ultrawork colima run --dry-run", "gateway same-thread dry smoke",
            "open-ultrawork selftest", "MCP smoke", "redaction scan", "host readiness gate summary",
          ],
          deniedActions: [
            "patch_signed_codex_app_bundle", "write_real_launchagent", "mutate_host_codex_config",
            "read_or_copy_auth_tokens", "mount_home_or_secrets_into_colima",
          ],
          doneCondition:
            "sandbox evidence bundle 全綠、redaction scan 通過，且 readiness gate 明確標示 host install 仍需備份與人工授權。"
        ),
        IntegrationStage(
          id: "backup-before-host",
          title: "主機實裝前備份",
          plainGoal: "只有 sandbox 過了才備份 Codex config/state/models cache，再請人類授權。",
          requiresHumanApproval: true,
          mayMutateHost: false,
          checks: [
            "backup Codex config.toml", "backup state database/cache", "backup models_cache.json",
            "record rollback receipt",
          ],
          deniedActions: [
            "host_mutation_without_backup", "write_real_launchagent_before_approval",
          ],
          doneCondition: "備份收據存在，人類明確批准才進下一階段。"
        ),
        IntegrationStage(
          id: "host-install",
          title: "主機實裝",
          plainGoal: "把 Tatwo App/MCP 接進 Codex，但保留 gateway dropdown，不硬揉核心。",
          requiresHumanApproval: true,
          mayMutateHost: true,
          checks: [
            "install Tatwo CLI/app", "register MCP entry",
            "gateway provider remains single model_gateway", "fast defaults preserved",
            "no signed app bundle patch",
          ],
          deniedActions: [
            "patch_signed_codex_app_bundle", "split_provider_per_model", "store_tokens_or_raw_logs",
          ],
          doneCondition: "doctor --json 與 gateway same-thread smoke 通過。"
        ),
        IntegrationStage(
          id: "post-install-smoke",
          title: "實裝後 smoke",
          plainGoal: "確認 Codex 不斷線、多模型切換仍在同 thread、Tatwo mode 可查。",
          requiresHumanApproval: false,
          mayMutateHost: false,
          checks: [
            "tatwo-ultrawork doctor --json",
            "tatwo-ultrawork teams recommend --scenario coding --mode M --json",
            "tatwo-ultrawork integration stability --json",
            "gateway gpt-5.5 -> external -> gpt-5.5 same-thread smoke",
            "MCP tools/list + call smoke",
          ],
          deniedActions: ["silent_retry_storm", "commit_private_state"],
          doneCondition: "沒有 reconnect storm，沒有 cache/provider split，MCP 回傳 JSON。"
        ),
      ],
      rollbackSteps: [
        "停止新的 host mutation，保留目前 evidence bundle。",
        "還原 Codex config/state/models cache 備份。",
        "停用 Tatwo MCP entry 或 gateway route；不要 patch signed app bundle。",
        "重跑 doctor/smoke，確認 rollback 後 Codex 可正常開啟。",
      ]
    )
  }

  public static func stabilityPlan() -> StabilityPlan {
    StabilityPlan(
      guards: [
        StabilityGuard(
          id: "single-provider", title: "單一 provider",
          plainRule: "Codex App 只保留 model_gateway；同 thread 只切 model，不切 provider。",
          prevents: "sidebar/thread provider split、舊聊天消失感",
          verification: "codex debug models + same-thread smoke", severity: .critical),
        StabilityGuard(
          id: "provider-config-receipt", title: "provider 設定收據",
          plainRule:
            "主機 preflight 要只讀確認 Codex config 仍是 model_provider=model_gateway；不能每個模型各開 provider。",
          prevents: "dropdown 看起來有模型，但 thread 被切到另一個 provider 後失去上下文",
          verification: "tatwo-host-preflight.mjs check codex-model-provider-single-gateway",
          severity: .critical),
        StabilityGuard(
          id: "semantic-sse", title: "語義 SSE 心跳",
          plainRule: "長 turn 等待期間要送 data-bearing response.in_progress；不要只送 comment keepalive。",
          prevents: "stream disconnected before completion / reconnect storm",
          verification: "gateway long buffered stream regression", severity: .critical),
        StabilityGuard(
          id: "body-cap", title: "乾淨 body cap",
          plainRule: "GATEWAY_MAX_BODY_BYTES 預設 64MB；超限回乾淨 413，不 reset socket。",
          prevents: "大型 ultrawork prompt 斷線重試", verification: "gateway body cap test",
          severity: .high),
        StabilityGuard(
          id: "app-binary-match", title: "App bundle binary 同源",
          plainRule: "app-server/proxy 要走 Codex App bundle binary，不要用 PATH 上舊 CLI。",
          prevents: "initialize handshake timed out / transport_closed",
          verification: "process command path includes App bundle", severity: .critical),
        StabilityGuard(
          id: "cache-refresh", title: "模型 cache 可回復",
          plainRule: "models_cache.json 只是 cache；dropdown 缺模型時備份後刪 cache 重抓，不 patch renderer。",
          prevents: "下拉只剩 GPT 或舊 catalog",
          verification: "gateway /v1/models then codex debug models", severity: .medium),
        StabilityGuard(
          id: "auth-race", title: "auth/OAuth 單一真相",
          plainRule:
            "避免多個 auth.json 副本搶 refresh；auth/session 問題回 completed visible notice，不用 response.failed 造成重試。",
          prevents: "Pro/free 假撞限額、token invalidated、retry storm",
          verification: "post-update auth single-source check", severity: .critical),
        StabilityGuard(
          id: "codex-home", title: "CODEX_HOME 留在本機 SSD",
          plainRule: "Codex App/CLI 不要把 CODEX_HOME 指到 noowners 外接卷；用 $HOME/.codex。",
          prevents: "TCC/權限/crash 問題", verification: "doctor env check", severity: .high),
        StabilityGuard(
          id: "colima-optional", title: "Colima 可選驗證器",
          plainRule:
            "Colima 只作 L/XL optional verifier；不自動安裝、不自動啟動、不掛 HOME/Secrets，缺少時顯示 degraded 而不是讓 Tatwo 崩潰。",
          prevents: "沙盒工具本身拖垮 Codex、誤掛 auth/session、把可選依賴變成硬阻塞",
          verification: "tatwo-ultrawork colima preflight/run --dry-run", severity: .high),
        StabilityGuard(
          id: "rollback", title: "可回滾",
          plainRule: "每次 host mutation 前先備份；rollback path 要能還原 config/state/cache。",
          prevents: "裝了就崩且回不去", verification: "backup receipt + rollback dry-run",
          severity: .critical),
      ],
      disconnectRules: [
        DisconnectPreventionRule(
          id: "backend-notice", symptom: "登入/quota/session limit 被 App 當成 stream failed",
          rule: "後端可處理錯誤要回 completed assistant message，不發 response.failed。",
          acceptance: "UI 顯示可讀錯誤且不 retry storm。"),
        DisconnectPreventionRule(
          id: "timeouts", symptom: "Claude/Grok 長 turn 被中途殺掉",
          rule: "CLAUDE_TIMEOUT_MS=600000，GROK_TIMEOUT_MS=300000，MiniMax 長上下文要有足夠 timeout。",
          acceptance: "長 turn 期間仍有 response.in_progress。"),
        DisconnectPreventionRule(
          id: "client-cancel", symptom: "使用者取消 turn 後 gateway crash",
          rule: "client cancellation / AbortError 當正常控制流，abort upstream 但不崩 gateway。",
          acceptance: "取消請求後 gateway process 仍存活。"),
        DisconnectPreventionRule(
          id: "no-signed-patch", symptom: "更新後 App 被 repair 或簽章壞掉",
          rule: "不 patch signed Codex App bundle；用 MCP/CLI/gateway 外掛入口。",
          acceptance: "codesign/spctl 不因 Tatwo 改動而變紅。"),
      ]
    )
  }
}
