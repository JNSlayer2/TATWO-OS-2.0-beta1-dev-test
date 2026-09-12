import Foundation

public enum GoalRunStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case planned
  case dispatching
  case running
  case succeeded
  case failed
  case cancelled
  case humanGate = "human_gate"
  /// The current immutable dispatch cycle is sealed, while the Goal remains
  /// open for another cycle or an explicit Goal Judge decision.
  case awaitingNextCycle = "awaiting_next_cycle"
  case blocked
  case passed
  case rollbackRequired = "rollback_required"
  /// A running Goal revision was explicitly replaced by a newer revision.
  ///
  /// This is a first-class terminal result. It must not be projected as
  /// success, cancellation, or rollback because the prior revision's receipts
  /// and dispatch evidence remain authoritative audit history.
  case superseded
}

public enum WorkOSDomainKind: String, Codable, Sendable, CaseIterable, Comparable, Equatable {
  case ui
  case code
  case debug
  case research
  case modeling
  case ops
  case custom

  public static func < (lhs: WorkOSDomainKind, rhs: WorkOSDomainKind) -> Bool {
    let order: [WorkOSDomainKind] = [.ui, .code, .debug, .research, .modeling, .ops, .custom]
    return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
  }

  public var plainName: String {
    switch self {
    case .ui: return "UI / UX"
    case .code: return "Code"
    case .debug: return "Debug"
    case .research: return "Research"
    case .modeling: return "Modeling"
    case .ops: return "Ops"
    case .custom: return "Custom"
    }
  }
}

public struct WorkOSContractContext: Codable, Sendable, Equatable {
  public let mode: WorkModeID
  public let scenarioProfileID: String

  public init(mode: WorkModeID, scenarioProfileID: String) {
    self.mode = mode
    self.scenarioProfileID = scenarioProfileID
  }
}

public struct WorkOSLoopTemplate: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let domain: WorkOSDomainKind
  public let title: String
  public let shortLabel: String
  public let ownerIdentity: IdentityKind
  public let defaultEnabledModes: [WorkModeID]
  public let allowedTools: [String]
  public let sandboxType: WorkOSSandboxType
  public let receiptID: String
  public let receiptTitle: String
  public let plainPurpose: String
  public let mergeBackRule: String
  public let budgetWeight: Double
  public let editable: Bool

  public init(
    id: String,
    domain: WorkOSDomainKind,
    title: String,
    shortLabel: String,
    ownerIdentity: IdentityKind,
    defaultEnabledModes: [WorkModeID],
    allowedTools: [String],
    sandboxType: WorkOSSandboxType,
    receiptID: String,
    receiptTitle: String,
    plainPurpose: String,
    mergeBackRule: String,
    budgetWeight: Double,
    editable: Bool = true
  ) {
    self.id = id
    self.domain = domain
    self.title = title
    self.shortLabel = shortLabel
    self.ownerIdentity = ownerIdentity
    self.defaultEnabledModes = defaultEnabledModes
    self.allowedTools = allowedTools
    self.sandboxType = sandboxType
    self.receiptID = receiptID
    self.receiptTitle = receiptTitle
    self.plainPurpose = plainPurpose
    self.mergeBackRule = mergeBackRule
    self.budgetWeight = max(0, min(1, budgetWeight))
    self.editable = editable
  }
}

public struct WorkOSCollaborationPreset: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let displayName: String
  public let mode: WorkModeID
  public let scenarioProfileID: String
  public let plainPurpose: String
  public let loopTemplateIDs: [String]
  public let editable: Bool
  public let isRecommended: Bool
  public let budgetNote: String

  public init(
    id: String,
    displayName: String,
    mode: WorkModeID,
    scenarioProfileID: String,
    plainPurpose: String,
    loopTemplateIDs: [String],
    editable: Bool,
    isRecommended: Bool = false,
    budgetNote: String
  ) {
    self.id = id
    self.displayName = displayName
    self.mode = mode
    self.scenarioProfileID = scenarioProfileID
    self.plainPurpose = plainPurpose
    self.loopTemplateIDs = loopTemplateIDs
    self.editable = editable
    self.isRecommended = isRecommended
    self.budgetNote = budgetNote
  }
}

public enum WorkOSSandboxType: String, Codable, Sendable, CaseIterable, Equatable {
  case none
  case stagingConfig = "staging_config"
  case tempWorkspace = "temp_workspace"
  case colimaDryRun = "colima_dry_run"
}

public enum WorkOSConfigStage: String, Codable, Sendable, CaseIterable, Equatable {
  case staging
  case activeReady = "active_ready"
}

public struct WorkOSReceiptRequirement: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let kind: String
  public let requiredForPass: Bool
  public let plainPurpose: String

  public init(
    id: String,
    title: String,
    kind: String,
    requiredForPass: Bool = true,
    plainPurpose: String
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.requiredForPass = requiredForPass
    self.plainPurpose = plainPurpose
  }
}

public struct WorkOSIdentityBinding: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let identity: IdentityKind
  public let label: String
  public let engineID: EngineID?
  public let modelID: String?
  public let authority: AuthorityMode
  public let canMutateHost: Bool
  public let sourceSlotID: String
  public let bindingRule: String

  public init(
    id: String,
    identity: IdentityKind,
    label: String,
    engineID: EngineID?,
    modelID: String?,
    authority: AuthorityMode,
    canMutateHost: Bool,
    sourceSlotID: String,
    bindingRule: String
  ) {
    self.id = id
    self.identity = identity
    self.label = label
    self.engineID = engineID
    self.modelID = modelID
    self.authority = authority
    self.canMutateHost = canMutateHost
    self.sourceSlotID = sourceSlotID
    self.bindingRule = bindingRule
  }
}

public struct WorkOSRouteBindingOverride: Codable, Sendable, Equatable {
  public let primaryModelID: String?
  public let secondaryModelID: String?

  public init(primaryModelID: String?, secondaryModelID: String?) {
    self.primaryModelID = Self.normalized(primaryModelID)
    self.secondaryModelID = Self.normalized(secondaryModelID)
  }

  public var isEmpty: Bool {
    primaryModelID == nil && secondaryModelID == nil
  }

  var contractIdentity: String {
    "primary=\(primaryModelID ?? "none")|secondary=\(secondaryModelID ?? "none")"
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = TatwoPrivacyRedactor.redacted(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct WorkOSSandboxPolicy: Codable, Sendable, Equatable {
  public let required: Bool
  public let defaultType: WorkOSSandboxType
  public let allowedTypes: [WorkOSSandboxType]
  public let stagingConfigRequired: Bool
  public let hostMutationAllowed: Bool
  public let humanGateRequired: Bool
  public let promotionRule: String
  public let forbiddenTargets: [String]

  public init(
    required: Bool,
    defaultType: WorkOSSandboxType,
    allowedTypes: [WorkOSSandboxType],
    stagingConfigRequired: Bool,
    hostMutationAllowed: Bool,
    humanGateRequired: Bool,
    promotionRule: String,
    forbiddenTargets: [String]
  ) {
    self.required = required
    self.defaultType = defaultType
    self.allowedTypes = allowedTypes
    self.stagingConfigRequired = stagingConfigRequired
    self.hostMutationAllowed = hostMutationAllowed
    self.humanGateRequired = humanGateRequired
    self.promotionRule = promotionRule
    self.forbiddenTargets = forbiddenTargets
  }
}

public struct MainlineLoop: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let ownerIdentity: IdentityKind
  public let objective: String
  public let phases: [String]
  public let allowedTools: [String]
  public let requiredReceipts: [WorkOSReceiptRequirement]
  public let reviewerGateRequired: Bool
  public let status: GoalRunStatus
  public let nextStep: String

  public init(
    id: String,
    title: String,
    ownerIdentity: IdentityKind,
    objective: String,
    phases: [String],
    allowedTools: [String],
    requiredReceipts: [WorkOSReceiptRequirement],
    reviewerGateRequired: Bool,
    status: GoalRunStatus,
    nextStep: String
  ) {
    self.id = id
    self.title = title
    self.ownerIdentity = ownerIdentity
    self.objective = objective
    self.phases = phases
    self.allowedTools = allowedTools
    self.requiredReceipts = requiredReceipts
    self.reviewerGateRequired = reviewerGateRequired
    self.status = status
    self.nextStep = nextStep
  }
}

public struct DomainLoop: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let domain: WorkOSDomainKind
  public let title: String
  public let ownerIdentity: IdentityKind
  /// Explicit affinity to one issued Scenario source slot. When present,
  /// Policy D must resolve exactly that slot and must not choose among peers.
  public let ownerSourceSlotID: String?
  public let allowedTools: [String]
  public let sandboxType: WorkOSSandboxType
  public let requiredReceipts: [WorkOSReceiptRequirement]
  public let status: GoalRunStatus
  public let autonomyLevel: String
  public let mergeBackRule: String
  /// T7 核心語義: every loop is a cycle, and every cycle is a full sub plan+loops+goal.
  /// Same-domain work scales by adding cycle instances (cycleIndex 2, 3, …) instead of
  /// inventing new domains. Only cycle 1 carries required-for-pass receipts; deeper
  /// cycles are coordination units so the goal-close receipt set stays bounded.
  public let cycleIndex: Int

  public init(
    id: String,
    domain: WorkOSDomainKind,
    title: String,
    ownerIdentity: IdentityKind,
    ownerSourceSlotID: String? = nil,
    allowedTools: [String],
    sandboxType: WorkOSSandboxType,
    requiredReceipts: [WorkOSReceiptRequirement],
    status: GoalRunStatus,
    autonomyLevel: String,
    mergeBackRule: String,
    cycleIndex: Int = 1
  ) {
    self.id = id
    self.domain = domain
    self.title = title
    self.ownerIdentity = ownerIdentity
    self.ownerSourceSlotID = ownerSourceSlotID
    self.allowedTools = allowedTools
    self.sandboxType = sandboxType
    self.requiredReceipts = requiredReceipts
    self.status = status
    self.autonomyLevel = autonomyLevel
    self.mergeBackRule = mergeBackRule
    self.cycleIndex = cycleIndex
  }

  private enum CodingKeys: String, CodingKey {
    case id, domain, title, ownerIdentity, ownerSourceSlotID
    case allowedTools, sandboxType
    case requiredReceipts, status, autonomyLevel, mergeBackRule, cycleIndex
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(String.self, forKey: .id)
    self.domain = try c.decode(WorkOSDomainKind.self, forKey: .domain)
    self.title = try c.decode(String.self, forKey: .title)
    self.ownerIdentity = try c.decode(IdentityKind.self, forKey: .ownerIdentity)
    self.ownerSourceSlotID =
      try c.decodeIfPresent(String.self, forKey: .ownerSourceSlotID)
    self.allowedTools = try c.decode([String].self, forKey: .allowedTools)
    self.sandboxType = try c.decode(WorkOSSandboxType.self, forKey: .sandboxType)
    self.requiredReceipts = try c.decode([WorkOSReceiptRequirement].self, forKey: .requiredReceipts)
    self.status = try c.decode(GoalRunStatus.self, forKey: .status)
    self.autonomyLevel = try c.decode(String.self, forKey: .autonomyLevel)
    self.mergeBackRule = try c.decode(String.self, forKey: .mergeBackRule)
    self.cycleIndex = try c.decodeIfPresent(Int.self, forKey: .cycleIndex) ?? 1
  }
}

public struct GoalRun: Codable, Sendable, Equatable {
  public let schema: String
  public let goalID: String
  public let contractID: String
  public let objective: String
  public let mode: WorkModeID
  public let scenario: String
  public let status: GoalRunStatus
  public let currentLoopID: String
  public let createdAt: Date
  public let statusReason: String

  public init(
    schema: String = "TatwoGoalRunV1",
    goalID: String,
    contractID: String,
    objective: String,
    mode: WorkModeID,
    scenario: String,
    status: GoalRunStatus,
    currentLoopID: String,
    createdAt: Date = Date(timeIntervalSince1970: 1_782_736_400),
    statusReason: String
  ) {
    self.schema = schema
    self.goalID = goalID
    self.contractID = contractID
    self.objective = objective
    self.mode = mode
    self.scenario = scenario
    self.status = status
    self.currentLoopID = currentLoopID
    self.createdAt = createdAt
    self.statusReason = statusReason
  }
}

public enum WorkOSShowLoopNodeKind: String, Codable, Sendable, CaseIterable, Equatable {
  case goal
  case contract
  case mainline
  case domain
  case receipt
  case gate
}

public struct WorkOSShowLoopNode: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let kind: WorkOSShowLoopNodeKind
  public let title: String
  public let ownerIdentity: IdentityKind?
  public let status: GoalRunStatus
  public let receiptIDs: [String]
  public let canPromoteRunState: Bool
  public let plainPurpose: String

  public init(
    id: String,
    kind: WorkOSShowLoopNodeKind,
    title: String,
    ownerIdentity: IdentityKind?,
    status: GoalRunStatus,
    receiptIDs: [String],
    canPromoteRunState: Bool,
    plainPurpose: String
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.ownerIdentity = ownerIdentity
    self.status = status
    self.receiptIDs = receiptIDs
    self.canPromoteRunState = canPromoteRunState
    self.plainPurpose = plainPurpose
  }
}

public struct WorkOSShowLoopEdge: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let from: String
  public let to: String
  public let label: String

  public init(id: String, from: String, to: String, label: String) {
    self.id = id
    self.from = from
    self.to = to
    self.label = label
  }
}

public struct WorkOSShowLoopsProjection: Codable, Sendable, Equatable {
  public let schema: String
  public let sourceURL: String
  public let sourceStatus: String
  public let projectionStyle: String
  public let readOnly: Bool
  public let visualizerCanPromoteRunState: Bool
  public let layoutHint: String
  public let nodes: [WorkOSShowLoopNode]
  public let edges: [WorkOSShowLoopEdge]

  public init(
    schema: String = "TatwoWorkOSShowLoopsProjectionV1",
    sourceURL: String,
    sourceStatus: String,
    projectionStyle: String,
    readOnly: Bool,
    visualizerCanPromoteRunState: Bool,
    layoutHint: String,
    nodes: [WorkOSShowLoopNode],
    edges: [WorkOSShowLoopEdge]
  ) {
    self.schema = schema
    self.sourceURL = sourceURL
    self.sourceStatus = sourceStatus
    self.projectionStyle = projectionStyle
    self.readOnly = readOnly
    self.visualizerCanPromoteRunState = visualizerCanPromoteRunState
    self.layoutHint = layoutHint
    self.nodes = nodes
    self.edges = edges
  }
}

public struct WorkOSGatewayRouteReservation: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let route: String
  public let mode: WorkModeID
  public let dryRunOnly: Bool
  public let plainPurpose: String

  public init(id: String, route: String, mode: WorkModeID, dryRunOnly: Bool, plainPurpose: String) {
    self.id = id
    self.route = route
    self.mode = mode
    self.dryRunOnly = dryRunOnly
    self.plainPurpose = plainPurpose
  }
}

public struct TatwoWorkOSContractV1: Codable, Sendable, Equatable {
  public let schema: String
  public let goalID: String
  public let contractID: String
  public let mode: WorkModeID
  public let scenario: String
  public let objective: String
  public let goalCyclePolicy: TatwoArenaGoalCyclePolicy
  public let planLoopGoalProtocol: TatwoArenaPlanLoopGoalProtocol
  public let goalRun: GoalRun
  public let loopGovernorDecision: TatwoLoopGovernorDecisionV1
  public let mainlineLoop: MainlineLoop
  public let domainLoops: [DomainLoop]
  public let identityBindings: [WorkOSIdentityBinding]
  public let routeBindingOverride: WorkOSRouteBindingOverride?
  /// Optional scoped authority-instance discriminator. Only a trimmed non-empty
  /// value participates in issued IDs; nil/empty keeps legacy hashes.
  public let authorityInstanceDiscriminator: String?
  public let sandboxPolicy: WorkOSSandboxPolicy
  public let receiptRequirements: [WorkOSReceiptRequirement]
  public let stopRules: [String]
  public let showLoopsProjection: WorkOSShowLoopsProjection
  public let configStage: WorkOSConfigStage
  public let gatewayRouteReservations: [WorkOSGatewayRouteReservation]
  public let nextAction: String
  public let failClosedRules: [String]
  /// Human-App approvable host scope is independent of model bindings.
  /// `canMutateHost=false` remains valid for every model while a trusted local
  /// human gate may separately authorize one bounded Host Executor action.
  public let humanApprovableHostActions: [TatwoHostActionKind]?
  public let hostActionCeiling: TatwoHostResourceBoundsV1?

  public init(
    schema: String = "TatwoWorkOSContractV1",
    goalID: String,
    contractID: String,
    mode: WorkModeID,
    scenario: String,
    objective: String,
    goalCyclePolicy: TatwoArenaGoalCyclePolicy = TatwoArenaPolicyFactory.goalCyclePolicy,
    planLoopGoalProtocol: TatwoArenaPlanLoopGoalProtocol = TatwoArenaPolicyFactory.planLoopGoalProtocol(),
    goalRun: GoalRun,
    loopGovernorDecision: TatwoLoopGovernorDecisionV1 = TatwoLoopGovernor.decide(mode: .m, scenarioID: "coding"),
    mainlineLoop: MainlineLoop,
    domainLoops: [DomainLoop],
    identityBindings: [WorkOSIdentityBinding],
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    authorityInstanceDiscriminator: String? = nil,
    sandboxPolicy: WorkOSSandboxPolicy,
    receiptRequirements: [WorkOSReceiptRequirement],
    stopRules: [String],
    showLoopsProjection: WorkOSShowLoopsProjection,
    configStage: WorkOSConfigStage,
    gatewayRouteReservations: [WorkOSGatewayRouteReservation],
    nextAction: String,
    failClosedRules: [String],
    humanApprovableHostActions: [TatwoHostActionKind]? =
      TatwoHostActionKind.allCases,
    hostActionCeiling: TatwoHostResourceBoundsV1? =
      TatwoHostResourceBoundsV1(
        maxDurationSeconds: 900,
        maxOutputBytes: 16 * 1_024 * 1_024,
        maxFileCount: 1_024)
  ) {
    self.schema = schema
    self.goalID = goalID
    self.contractID = contractID
    self.mode = mode
    self.scenario = scenario
    self.objective = objective
    self.goalCyclePolicy = goalCyclePolicy
    self.planLoopGoalProtocol = planLoopGoalProtocol
    self.goalRun = goalRun
    self.loopGovernorDecision = loopGovernorDecision
    self.mainlineLoop = mainlineLoop
    self.domainLoops = domainLoops
    self.identityBindings = identityBindings
    self.routeBindingOverride = routeBindingOverride
    self.authorityInstanceDiscriminator = authorityInstanceDiscriminator
    self.sandboxPolicy = sandboxPolicy
    self.receiptRequirements = receiptRequirements
    self.stopRules = stopRules
    self.showLoopsProjection = showLoopsProjection
    self.configStage = configStage
    self.gatewayRouteReservations = gatewayRouteReservations
    self.nextAction = nextAction
    self.failClosedRules = failClosedRules
    self.humanApprovableHostActions =
      humanApprovableHostActions?.sorted { $0.rawValue < $1.rawValue }
    self.hostActionCeiling = hostActionCeiling
  }
}

public struct WorkOSGateDecision: Codable, Sendable, Equatable {
  public let ok: Bool
  public let code: String
  public let message: String

  public init(ok: Bool, code: String, message: String) {
    self.ok = ok
    self.code = code
    self.message = message
  }
}

public struct WorkOSReceiptSubmissionResult: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let goalID: String?
  public let contractID: String?
  public let loopID: String?
  public let receiptID: String?
  public let receiptKind: String
  public let decision: WorkOSGateDecision
  public let nextAction: String

  public init(
    schema: String = "TatwoWorkOSReceiptSubmissionResultV1",
    ok: Bool,
    goalID: String?,
    contractID: String?,
    loopID: String?,
    receiptID: String?,
    receiptKind: String,
    decision: WorkOSGateDecision,
    nextAction: String
  ) {
    self.schema = schema
    self.ok = ok
    self.goalID = goalID
    self.contractID = contractID
    self.loopID = loopID
    self.receiptID = receiptID
    self.receiptKind = receiptKind
    self.decision = decision
    self.nextAction = nextAction
  }
}

public struct TatwoWorkOSNextAction: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let goalID: String?
  public let contractID: String?
  public let currentLoopID: String?
  public let nextStep: String
  public let requiredReceiptsBeforePass: [String]
  /// Hard blocking states surfaced by tatwo.os.next. Examples: supervision_gap, goal_tracker_missing.
  public let blockingStates: [String]
  public let decision: WorkOSGateDecision

  public init(
    schema: String = "TatwoWorkOSNextActionV1",
    ok: Bool,
    goalID: String?,
    contractID: String?,
    currentLoopID: String?,
    nextStep: String,
    requiredReceiptsBeforePass: [String],
    decision: WorkOSGateDecision,
    blockingStates: [String] = []
  ) {
    self.schema = schema
    self.ok = ok
    self.goalID = goalID
    self.contractID = contractID
    self.currentLoopID = currentLoopID
    self.nextStep = nextStep
    self.requiredReceiptsBeforePass = requiredReceiptsBeforePass
    self.blockingStates = blockingStates
    self.decision = decision
  }
}

public struct WorkOSLoopStatusReport: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let goalID: String?
  public let contractID: String?
  public let mainlineLoop: MainlineLoop?
  public let domainLoops: [DomainLoop]
  public let decision: WorkOSGateDecision

  public init(
    schema: String = "TatwoWorkOSLoopStatusReportV1",
    ok: Bool,
    goalID: String?,
    contractID: String?,
    mainlineLoop: MainlineLoop?,
    domainLoops: [DomainLoop],
    decision: WorkOSGateDecision
  ) {
    self.schema = schema
    self.ok = ok
    self.goalID = goalID
    self.contractID = contractID
    self.mainlineLoop = mainlineLoop
    self.domainLoops = domainLoops
    self.decision = decision
  }
}

public struct WorkOSGoalCloseResult: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let goalID: String?
  public let contractID: String?
  public let status: GoalRunStatus
  public let suppliedReceiptIDs: [String]
  public let missingReceiptIDs: [String]
  public let decision: WorkOSGateDecision

  public init(
    schema: String = "TatwoWorkOSGoalCloseResultV1",
    ok: Bool,
    goalID: String?,
    contractID: String?,
    status: GoalRunStatus,
    suppliedReceiptIDs: [String],
    missingReceiptIDs: [String],
    decision: WorkOSGateDecision
  ) {
    self.schema = schema
    self.ok = ok
    self.goalID = goalID
    self.contractID = contractID
    self.status = status
    self.suppliedReceiptIDs = suppliedReceiptIDs
    self.missingReceiptIDs = missingReceiptIDs
    self.decision = decision
  }
}
