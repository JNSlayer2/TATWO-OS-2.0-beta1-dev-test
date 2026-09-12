import CryptoKit
import Foundation

public struct ScenarioLoopNode: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let ownerIdentity: IdentityKind?
  public let plainPurpose: String
  public let required: Bool
  public let requiredEvidence: [String]
  public let failClosedAction: String

  public init(
    id: String,
    title: String,
    ownerIdentity: IdentityKind?,
    plainPurpose: String,
    required: Bool,
    requiredEvidence: [String],
    failClosedAction: String
  ) {
    self.id = id
    self.title = title
    self.ownerIdentity = ownerIdentity
    self.plainPurpose = plainPurpose
    self.required = required
    self.requiredEvidence = requiredEvidence
    self.failClosedAction = failClosedAction
  }
}

public struct ScenarioVisualizationHints: Codable, Sendable, Equatable {
  public let schema: String
  public let style: String
  public let sourceURL: String
  public let sourceStatus: String
  public let plainPurpose: String
  public let layout: String
  public let nodeOrder: [String]
  public let groupByIdentity: Bool
  public let showReceiptsOnNodes: Bool
  public let replacementReady: Bool

  public init(
    schema: String = "TatwoScenarioLoopVisualizationV1",
    style: String,
    sourceURL: String,
    sourceStatus: String,
    plainPurpose: String,
    layout: String,
    nodeOrder: [String],
    groupByIdentity: Bool,
    showReceiptsOnNodes: Bool,
    replacementReady: Bool
  ) {
    self.schema = schema
    self.style = style
    self.sourceURL = sourceURL
    self.sourceStatus = sourceStatus
    self.plainPurpose = plainPurpose
    self.layout = layout
    self.nodeOrder = nodeOrder
    self.groupByIdentity = groupByIdentity
    self.showReceiptsOnNodes = showReceiptsOnNodes
    self.replacementReady = replacementReady
  }
}

public struct AgentInvocationPolicy: Codable, Sendable, Equatable {
  public let schema: String
  public let mustCallWorkflowToolBeforeActing: Bool
  public let requiredFirstTool: String
  public let noReceiptNoClaim: Bool
  public let externalModelReceiptRequired: Bool
  public let hostMutationDefaultAllowed: Bool
  public let requiresContractCallIDForEveryAction: Bool
  public let rejectsNakedToolCall: Bool
  public let visualizerCanPromoteRunState: Bool
  public let sameModelMultiRoleMarkedSimulated: Bool
  public let fakeExecutionBlockedMessage: String
  public let requiredBeforeAnyPatch: [String]

  public init(
    schema: String = "TatwoAgentInvocationPolicyV1",
    mustCallWorkflowToolBeforeActing: Bool,
    requiredFirstTool: String,
    noReceiptNoClaim: Bool,
    externalModelReceiptRequired: Bool,
    hostMutationDefaultAllowed: Bool,
    requiresContractCallIDForEveryAction: Bool = true,
    rejectsNakedToolCall: Bool = true,
    visualizerCanPromoteRunState: Bool = false,
    sameModelMultiRoleMarkedSimulated: Bool = true,
    fakeExecutionBlockedMessage: String,
    requiredBeforeAnyPatch: [String]
  ) {
    self.schema = schema
    self.mustCallWorkflowToolBeforeActing = mustCallWorkflowToolBeforeActing
    self.requiredFirstTool = requiredFirstTool
    self.noReceiptNoClaim = noReceiptNoClaim
    self.externalModelReceiptRequired = externalModelReceiptRequired
    self.hostMutationDefaultAllowed = hostMutationDefaultAllowed
    self.requiresContractCallIDForEveryAction = requiresContractCallIDForEveryAction
    self.rejectsNakedToolCall = rejectsNakedToolCall
    self.visualizerCanPromoteRunState = visualizerCanPromoteRunState
    self.sameModelMultiRoleMarkedSimulated = sameModelMultiRoleMarkedSimulated
    self.fakeExecutionBlockedMessage = fakeExecutionBlockedMessage
    self.requiredBeforeAnyPatch = requiredBeforeAnyPatch
  }
}

public enum ScenarioRunEventStatus: String, Codable, Sendable, Equatable {
  case planned
  case notDispatched = "not_dispatched"
  case dispatched
  case running
  case waitingForReceipt = "waiting_for_receipt"
  case receiptGated = "receipt_gated"
  case blocked
  case passed

  public var plainLabel: String {
    switch self {
    case .planned: return "規劃預覽"
    case .notDispatched: return "尚未派發"
    case .dispatched: return "已派發"
    case .running: return "執行中"
    case .waitingForReceipt, .receiptGated: return "等待 runtime receipt"
    case .blocked: return "執行受阻"
    case .passed: return "已驗收"
    }
  }

  public var countsAsRuntimeProgress: Bool {
    switch self {
    case .dispatched, .running, .waitingForReceipt, .receiptGated, .blocked, .passed:
      return true
    case .planned, .notDispatched:
      return false
    }
  }
}

public struct ScenarioRunEventProjection: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let runEventID: String
  public let seq: Int
  public let phaseID: String
  public let title: String
  public let identityID: String
  public let identityLabel: String
  public let contractCallID: String
  public let modelBindingID: String
  public let required: Bool
  public let receiptRefs: [String]
  public let inputHash: String
  public let outputHash: String?
  public let status: ScenarioRunEventStatus
  public let runtimeReceiptRefs: [String]
  public let readOnlyProjection: Bool
  public let canPromoteRunState: Bool

  public init(
    id: String,
    runEventID: String,
    seq: Int,
    phaseID: String,
    title: String,
    identityID: String,
    identityLabel: String,
    contractCallID: String,
    modelBindingID: String,
    required: Bool,
    receiptRefs: [String],
    inputHash: String,
    outputHash: String?,
    status: ScenarioRunEventStatus,
    runtimeReceiptRefs: [String] = [],
    readOnlyProjection: Bool = true,
    canPromoteRunState: Bool = false
  ) {
    self.id = id
    self.runEventID = runEventID
    self.seq = seq
    self.phaseID = phaseID
    self.title = title
    self.identityID = identityID
    self.identityLabel = identityLabel
    self.contractCallID = contractCallID
    self.modelBindingID = modelBindingID
    self.required = required
    self.receiptRefs = receiptRefs
    self.inputHash = inputHash
    self.outputHash = outputHash
    self.runtimeReceiptRefs = runtimeReceiptRefs
      .map { TatwoPrivacyRedactor.redacted($0) }
    self.status =
      status == .passed && self.runtimeReceiptRefs.isEmpty
      ? .receiptGated
      : status
    self.readOnlyProjection = readOnlyProjection
    self.canPromoteRunState = canPromoteRunState
  }

  public var plainStatus: String {
    if status == .receiptGated && runtimeReceiptRefs.isEmpty {
      return "已有完成宣告，但無 runtime receipt；不可算已驗收"
    }
    return status.plainLabel
  }

  public var countsAsRuntimeProgress: Bool {
    status.countsAsRuntimeProgress
  }

  public var hasRuntimeReceipt: Bool {
    !runtimeReceiptRefs.isEmpty
  }

  private enum CodingKeys: String, CodingKey {
    case id, runEventID, seq, phaseID, title, identityID, identityLabel
    case contractCallID, modelBindingID, required, receiptRefs, inputHash
    case outputHash, status, runtimeReceiptRefs, readOnlyProjection, canPromoteRunState
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      runEventID: try container.decode(String.self, forKey: .runEventID),
      seq: try container.decode(Int.self, forKey: .seq),
      phaseID: try container.decode(String.self, forKey: .phaseID),
      title: try container.decode(String.self, forKey: .title),
      identityID: try container.decode(String.self, forKey: .identityID),
      identityLabel: try container.decode(String.self, forKey: .identityLabel),
      contractCallID: try container.decode(String.self, forKey: .contractCallID),
      modelBindingID: try container.decode(String.self, forKey: .modelBindingID),
      required: try container.decode(Bool.self, forKey: .required),
      receiptRefs: try container.decode([String].self, forKey: .receiptRefs),
      inputHash: try container.decode(String.self, forKey: .inputHash),
      outputHash: try container.decodeIfPresent(String.self, forKey: .outputHash),
      status: try container.decode(ScenarioRunEventStatus.self, forKey: .status),
      runtimeReceiptRefs: try container.decodeIfPresent(
        [String].self,
        forKey: .runtimeReceiptRefs) ?? [],
      readOnlyProjection: try container.decode(Bool.self, forKey: .readOnlyProjection),
      canPromoteRunState: try container.decode(Bool.self, forKey: .canPromoteRunState))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(runEventID, forKey: .runEventID)
    try container.encode(seq, forKey: .seq)
    try container.encode(phaseID, forKey: .phaseID)
    try container.encode(title, forKey: .title)
    try container.encode(identityID, forKey: .identityID)
    try container.encode(identityLabel, forKey: .identityLabel)
    try container.encode(contractCallID, forKey: .contractCallID)
    try container.encode(modelBindingID, forKey: .modelBindingID)
    try container.encode(required, forKey: .required)
    try container.encode(receiptRefs, forKey: .receiptRefs)
    try container.encode(inputHash, forKey: .inputHash)
    try container.encodeIfPresent(outputHash, forKey: .outputHash)
    try container.encode(status, forKey: .status)
    try container.encode(runtimeReceiptRefs, forKey: .runtimeReceiptRefs)
    try container.encode(readOnlyProjection, forKey: .readOnlyProjection)
    try container.encode(canPromoteRunState, forKey: .canPromoteRunState)
  }
}

public struct ScenarioShowLoopsProjection: Codable, Sendable, Equatable {
  public let schema: String
  public let runID: String
  public let contractCallID: String
  public let visualizerSourceOfTruth: String
  public let visualizerCanMutateRunState: Bool
  public let promotionRequiresReceipts: Bool
  public let missingEventNodePolicy: String
  public let presentationLabel: String
  public let dispatchSummary: String
  public let runtimeReceiptSummary: String
  public let events: [ScenarioRunEventProjection]
  public let edges: [WorkflowEdge]

  public init(
    schema: String = "TatwoShowLoopsProjectionV1",
    runID: String,
    contractCallID: String,
    visualizerSourceOfTruth: String,
    visualizerCanMutateRunState: Bool,
    promotionRequiresReceipts: Bool,
    missingEventNodePolicy: String,
    presentationLabel: String = "規劃預覽",
    dispatchSummary: String = "尚未派發",
    runtimeReceiptSummary: String = "無 runtime receipt",
    events: [ScenarioRunEventProjection],
    edges: [WorkflowEdge]
  ) {
    self.schema = schema
    self.runID = runID
    self.contractCallID = contractCallID
    self.visualizerSourceOfTruth = visualizerSourceOfTruth
    self.visualizerCanMutateRunState = visualizerCanMutateRunState
    self.promotionRequiresReceipts = promotionRequiresReceipts
    self.missingEventNodePolicy = missingEventNodePolicy
    self.presentationLabel = presentationLabel
    self.dispatchSummary = dispatchSummary
    self.runtimeReceiptSummary = runtimeReceiptSummary
    self.events = events
    self.edges = edges
  }

  public var runtimeProgressEventCount: Int {
    events.filter(\.countsAsRuntimeProgress).count
  }

  public var runtimeReceiptCount: Int {
    events.reduce(0) { $0 + $1.runtimeReceiptRefs.count }
  }

  private enum CodingKeys: String, CodingKey {
    case schema, runID, contractCallID, visualizerSourceOfTruth
    case visualizerCanMutateRunState, promotionRequiresReceipts, missingEventNodePolicy
    case presentationLabel, dispatchSummary, runtimeReceiptSummary, events, edges
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      schema: try container.decode(String.self, forKey: .schema),
      runID: try container.decode(String.self, forKey: .runID),
      contractCallID: try container.decode(String.self, forKey: .contractCallID),
      visualizerSourceOfTruth: try container.decode(
        String.self,
        forKey: .visualizerSourceOfTruth),
      visualizerCanMutateRunState: try container.decode(
        Bool.self,
        forKey: .visualizerCanMutateRunState),
      promotionRequiresReceipts: try container.decode(
        Bool.self,
        forKey: .promotionRequiresReceipts),
      missingEventNodePolicy: try container.decode(
        String.self,
        forKey: .missingEventNodePolicy),
      presentationLabel: try container.decodeIfPresent(
        String.self,
        forKey: .presentationLabel) ?? "規劃預覽",
      dispatchSummary: try container.decodeIfPresent(
        String.self,
        forKey: .dispatchSummary) ?? "尚未派發",
      runtimeReceiptSummary: try container.decodeIfPresent(
        String.self,
        forKey: .runtimeReceiptSummary) ?? "無 runtime receipt",
      events: try container.decode([ScenarioRunEventProjection].self, forKey: .events),
      edges: try container.decode([WorkflowEdge].self, forKey: .edges))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(runID, forKey: .runID)
    try container.encode(contractCallID, forKey: .contractCallID)
    try container.encode(visualizerSourceOfTruth, forKey: .visualizerSourceOfTruth)
    try container.encode(visualizerCanMutateRunState, forKey: .visualizerCanMutateRunState)
    try container.encode(promotionRequiresReceipts, forKey: .promotionRequiresReceipts)
    try container.encode(missingEventNodePolicy, forKey: .missingEventNodePolicy)
    try container.encode(presentationLabel, forKey: .presentationLabel)
    try container.encode(dispatchSummary, forKey: .dispatchSummary)
    try container.encode(runtimeReceiptSummary, forKey: .runtimeReceiptSummary)
    try container.encode(events, forKey: .events)
    try container.encode(edges, forKey: .edges)
  }
}

public struct ScenarioWorkflowContract: Codable, Sendable, Equatable {
  public let schema: String
  public let objective: String
  public let mode: WorkModeID
  public let scenarioProfileID: String
  public let baseScenario: ScenarioID
  public let hostMutationAllowed: Bool
  public let workOSContract: TatwoWorkOSContractV1
  public let scenarioProfile: ScenarioProfile
  public let modePlan: ModeIdentityPlan
  public let identitySlots: [IdentitySlot]
  public let leadStrategy: LeadStrategy
  public let workflowRunPlan: WorkflowRunPlan
  public let loopNodes: [ScenarioLoopNode]
  public let loopEdges: [WorkflowEdge]
  public let showLoopsProjection: ScenarioShowLoopsProjection
  public let visualizationHints: ScenarioVisualizationHints
  public let agentInvocationPolicy: AgentInvocationPolicy
  public let requiredTools: [String]
  public let recommendedPlugins: [String]
  public let forbiddenClaims: [String]
  public let forbiddenActions: [String]
  public let receiptRequirements: [String]
  public let failClosedRule: String
  public let advisoryOnlyNotes: [String]

  public init(
    schema: String = "TatwoScenarioWorkflowContractV1",
    objective: String,
    mode: WorkModeID,
    scenarioProfileID: String,
    baseScenario: ScenarioID,
    hostMutationAllowed: Bool,
    workOSContract: TatwoWorkOSContractV1,
    scenarioProfile: ScenarioProfile,
    modePlan: ModeIdentityPlan,
    identitySlots: [IdentitySlot],
    leadStrategy: LeadStrategy,
    workflowRunPlan: WorkflowRunPlan,
    loopNodes: [ScenarioLoopNode],
    loopEdges: [WorkflowEdge],
    showLoopsProjection: ScenarioShowLoopsProjection,
    visualizationHints: ScenarioVisualizationHints,
    agentInvocationPolicy: AgentInvocationPolicy,
    requiredTools: [String],
    recommendedPlugins: [String],
    forbiddenClaims: [String],
    forbiddenActions: [String],
    receiptRequirements: [String],
    failClosedRule: String,
    advisoryOnlyNotes: [String]
  ) {
    self.schema = schema
    self.objective = objective
    self.mode = mode
    self.scenarioProfileID = scenarioProfileID
    self.baseScenario = baseScenario
    self.hostMutationAllowed = hostMutationAllowed
    self.workOSContract = workOSContract
    self.scenarioProfile = scenarioProfile
    self.modePlan = modePlan
    self.identitySlots = identitySlots
    self.leadStrategy = leadStrategy
    self.workflowRunPlan = workflowRunPlan
    self.loopNodes = loopNodes
    self.loopEdges = loopEdges
    self.showLoopsProjection = showLoopsProjection
    self.visualizationHints = visualizationHints
    self.agentInvocationPolicy = agentInvocationPolicy
    self.requiredTools = requiredTools
    self.recommendedPlugins = recommendedPlugins
    self.forbiddenClaims = forbiddenClaims
    self.forbiddenActions = forbiddenActions
    self.receiptRequirements = receiptRequirements
    self.failClosedRule = failClosedRule
    self.advisoryOnlyNotes = advisoryOnlyNotes
  }
}

public enum ScenarioWorkflowContractFactory {
  public static func make(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String,
    objective rawObjective: String = "Tatwo Ultrawork scenario workflow",
    dryRunOnly: Bool = true,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    loopPresetID: String? = nil,
    enabledLoopTemplateIDs: [String]? = nil
  ) throws -> ScenarioWorkflowContract {
    let normalizedScenario = rawScenarioProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = try resolveScenarioContext(normalizedScenario, scenarioBook: scenarioBook)
    let profile = context.profile
    let baseScenario = profile.baseScenario ?? .coding
    let objective = sanitizedObjective(rawObjective)
    let workOSContract = try WorkOSFactory.preview(
      mode: mode,
      scenarioProfileID: context.scenarioID,
      objective: objective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      loopPresetID: loopPresetID,
      enabledLoopTemplateIDs: enabledLoopTemplateIDs)
    let modePlan = try WorkOSFactory.previewModePlan(
      mode: mode,
      scenarioProfileID: context.scenarioID,
      catalog: catalog,
      scenarioBook: scenarioBook,
      contract: workOSContract)
    let leadStrategy = TeamRoutingCatalog.leadStrategy(
      mode: mode, scenarioProfileID: profile.id, scenario: baseScenario)
    let runPlan = WorkflowRunFactory.makePlan(
      objective: objective,
      mode: mode,
      scenario: baseScenario,
      dryRunOnly: dryRunOnly,
      catalog: catalog)
    let loopNodes = makeLoopNodes(
      mode: mode,
      profile: profile,
      baseScenario: baseScenario,
      modePlan: modePlan,
      runPlan: runPlan,
      workOSContract: workOSContract)
    let edges = makeLoopEdges(loopNodes: loopNodes)
    let receipts = makeReceiptRequirements(mode: mode, profile: profile, modePlan: modePlan, runPlan: runPlan)
    let projection = makeShowLoopsProjection(
      mode: mode,
      profile: profile,
      objective: objective,
      loopNodes: loopNodes,
      loopEdges: edges)

    return ScenarioWorkflowContract(
      objective: objective,
      mode: mode,
      scenarioProfileID: context.scenarioID,
      baseScenario: baseScenario,
      hostMutationAllowed: false,
      workOSContract: workOSContract,
      scenarioProfile: profile,
      modePlan: modePlan,
      identitySlots: modePlan.identitySlots,
      leadStrategy: leadStrategy,
      workflowRunPlan: runPlan,
      loopNodes: loopNodes,
      loopEdges: edges,
      showLoopsProjection: projection,
      visualizationHints: makeVisualizationHints(loopNodes: loopNodes),
      agentInvocationPolicy: makeAgentInvocationPolicy(mode: mode, profile: profile),
      requiredTools: makeRequiredTools(mode: mode, profile: profile),
      recommendedPlugins: makeRecommendedPlugins(mode: mode, profile: profile),
      forbiddenClaims: makeForbiddenClaims(profile: profile),
      forbiddenActions: makeForbiddenActions(),
      receiptRequirements: receipts,
      failClosedRule: failClosedRule(mode: mode, profile: profile),
      advisoryOnlyNotes: [
        "外部模型只能做研究、審稿、patch intent 或反方；檔案、shell、截圖、實裝由安全 host 執行。",
        "tatwo.scenario.workflow 是相容入口；正式行為以 workOSContract / tatwo.os.begin 的 contractID 為準。",
        "主 / 副 / sub 是身份組選填，不是固定模型名稱；主導中心依 mode/scenario/profile 切換，不固定 GPT。",
        "showLoopsProjection 是規劃預覽：planned identity、receipt-required refs 與節點數都不算 runtime 進度；尚未派發時固定顯示無 runtime receipt。",
        "沒有 bridge/tool/CLI 收據時，不宣稱 Opus、Grok、MiniMax、ChatGPT Pro MCP 已實際執行。",
      ])
  }

  private struct ResolvedScenarioContext {
    let scenarioID: String
    let profile: ScenarioProfile
    let customConfig: TatwoCustomScenarioConfig?
  }

  private static func resolveScenarioContext(
    _ raw: String,
    scenarioBook: TatwoScenarioConfigBookV1
  ) throws -> ResolvedScenarioContext {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let profile = TatwoIdentityCatalog.scenarioProfile(normalized.isEmpty ? "coding" : normalized) {
      return ResolvedScenarioContext(scenarioID: profile.id, profile: profile, customConfig: nil)
    }
    if let config = scenarioBook.scenario(id: normalized) {
      let profileID = config.baseScenario.map(profileID(for:)) ?? "coding"
      guard
        let profile = TatwoIdentityCatalog.scenarioProfile(profileID)
          ?? TatwoIdentityCatalog.scenarioProfile("coding")
          ?? TatwoIdentityCatalog.scenarioProfiles.first
      else {
        throw TatwoParseError.unknownScenario(raw)
      }
      return ResolvedScenarioContext(scenarioID: config.id, profile: profile, customConfig: config)
    }
    if let scenario = try? ScenarioID.parse(raw),
      let profile = TatwoIdentityCatalog.scenarioProfile(profileID(for: scenario))
    {
      return ResolvedScenarioContext(scenarioID: profile.id, profile: profile, customConfig: nil)
    }
    throw TatwoParseError.unknownScenario(raw)
  }

  private static func profileID(for scenario: ScenarioID) -> String {
    switch scenario {
    case .daily: return "daily"
    case .design: return "ui-ux"
    case .coding: return "coding"
    case .trading: return "trading-risk"
    case .modeling: return "modeling"
    }
  }

  private static func sanitizedObjective(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty
      ? "Tatwo Ultrawork scenario workflow"
      : TatwoPrivacyRedactor.redacted(trimmed)
  }

  private static func makeLoopNodes(
    mode: WorkModeID,
    profile: ScenarioProfile,
    baseScenario: ScenarioID,
    modePlan: ModeIdentityPlan,
    runPlan: WorkflowRunPlan,
    workOSContract: TatwoWorkOSContractV1
  ) -> [ScenarioLoopNode] {
    var nodes: [ScenarioLoopNode] = [
      ScenarioLoopNode(
        id: "user-task",
        title: "任務與完成定義",
        ownerIdentity: .lead,
        plainPurpose: "先寫清楚目標、不要做什麼、畫面/功能怎樣才算通過。",
        required: true,
        requiredEvidence: ["objective", "target", "stop condition"],
        failClosedAction: "目標不清楚就先收斂，不開始大規模分派。"),
      ScenarioLoopNode(
        id: "mode-budget",
        title: "模式 / 預算 gate",
        ownerIdentity: .lead,
        plainPurpose: "套用 \(mode.rawValue) 模式、helper 上限、輪次與預算；越簡單越不開大隊伍。",
        required: true,
        requiredEvidence: modePlan.requiredReceipts.filter { $0.contains("mode") || $0.contains("budget") },
        failClosedAction: "超出 helper 或輪次就停，交 checkpoint。"),
      ScenarioLoopNode(
        id: "identity-setup",
        title: "身份組選填",
        ownerIdentity: .lead,
        plainPurpose: "先決定主 / 副 / sub / 驗收等身份，再依特質選填模型；不是把模型名稱硬塞進流程。",
        required: true,
        requiredEvidence: ["identity plan receipt"],
        failClosedAction: "身份或權限不明時，不派工具、不寫檔。"),
      ScenarioLoopNode(
        id: "work-os-contract",
        title: "Work OS contract",
        ownerIdentity: .lead,
        plainPurpose: "相容入口內部先建立 goalID / contractID；後續 agent action 沒有 contractID 一律 fail closed。",
        required: true,
        requiredEvidence: ["goalID \(workOSContract.goalID)", "contractID \(workOSContract.contractID)"],
        failClosedAction: "沒有 Work OS contract 就不進入工具、patch、receipt 或 goal close。"),
    ]

    nodes.append(
      ScenarioLoopNode(
        id: "project-map",
        title: "影響範圍 / 專案地圖",
        ownerIdentity: .supervisor,
        plainPurpose: mode >= .m
          ? "M/L/XL 先確認入口、影響檔案與不該碰的範圍。"
          : "S 小修可跳過；如果影響範圍不明就升級。",
        required: mode >= .m,
        requiredEvidence: mode >= .m ? ["project-map or scope receipt"] : ["S mode skip note"],
        failClosedAction: "M+ 沒有範圍收據就不分派協作。"))

    nodes.append(
      ScenarioLoopNode(
        id: "sandbox",
        title: "沙盒 / 隔離 rehearsal",
        ownerIdentity: .verifier,
        plainPurpose: mode >= .l
          ? "L/XL 先在臨時 workspace 或 Colima dry-run 驗證，不直接碰 host。"
          : "S/M 可用本機 smoke；高風險再升級到沙盒。",
        required: mode >= .l || runPlan.sandboxRequired,
        requiredEvidence: mode >= .l || runPlan.sandboxRequired
          ? ["sandbox receipt or explicit degraded receipt", "no host mutation proof"]
          : ["local smoke if changed"],
        failClosedAction: "沙盒或降級收據缺失時，不做 host promotion。"))

    let hasSub = profile.identitySlots.contains { $0.kind == .sub }
    let hasNews = profile.identitySlots.contains { $0.kind == .news }
    if !workOSContract.domainLoops.isEmpty {
      // T1/T7: cycle >1 instances share their domain's cycle-1 receipt, so the workflow
      // graph keeps one required node per domain (annotated with its cycle fan-out) instead
      // of duplicate receipt-less nodes.
      let cycleCountByDomain = Dictionary(grouping: workOSContract.domainLoops, by: \.domain)
      nodes += workOSContract.domainLoops.filter { $0.cycleIndex == 1 }.map { loop in
        let cycles = cycleCountByDomain[loop.domain]?.count ?? 1
        return ScenarioLoopNode(
          id: "domain-\(loop.domain.rawValue)",
          title: cycles > 1
            ? "\(loop.domain.plainName) 領域 loop × \(cycles) cycles"
            : "\(loop.domain.plainName) 領域 loop",
          ownerIdentity: loop.ownerIdentity,
          plainPurpose: "\(loop.title)：\(loop.autonomyLevel)。\(loop.mergeBackRule)",
          required: true,
          requiredEvidence: loop.requiredReceipts.map(\.id),
          failClosedAction: "domain loop 沒有 receipt 不可回併 mainline。")
      }
    }
    nodes.append(
      ScenarioLoopNode(
        id: "scout-sub-news",
        title: hasNews ? "sub / 消息探索" : "sub 探索",
        ownerIdentity: hasNews ? .news : .sub,
        plainPurpose: "只產出候選、反例、來源或 checklist；不直接 final pass。",
        required: mode >= .m && (hasSub || hasNews),
        requiredEvidence: ["assigned scope", hasNews ? "freshness/source receipt" : "candidate summary"],
        failClosedAction: "沒有明確分派範圍時，sub/news 不啟動。"))

    nodes += [
      ScenarioLoopNode(
        id: "builder",
        title: "主導落地",
        ownerIdentity: .lead,
        plainPurpose: "由安全 host 套 patch、跑 build 或整理結論；外部模型輸出只當意圖。",
        required: true,
        requiredEvidence: ["diff or command receipt", "build/smoke output if code changed"],
        failClosedAction: "沒有 host trace 就不宣稱已修改或已跑過。"),
      ScenarioLoopNode(
        id: "reviewer",
        title: "副導 / 監督審稿",
        ownerIdentity: .supervisor,
        plainPurpose: "檢查偏航、明顯 UI/UJ 問題、漏測與完成定義；可擋下但不自我放行。",
        required: mode >= .m,
        requiredEvidence: ["review receipt", "blocking findings resolved or accepted"],
        failClosedAction: "reviewer 沒過或沒回，結果維持 beta / 未驗收。"),
      ScenarioLoopNode(
        id: "verifier",
        title: "驗收證據",
        ownerIdentity: .verifier,
        plainPurpose: baseScenario == .design
          ? "UI/UJ 必須有截圖或互動證據；build pass 不等於畫面通過。"
          : "用測試、CLI smoke、redaction 或可重跑輸出證明。",
        required: true,
        requiredEvidence: baseScenario == .design
          ? ["screenshot or recording", "visual checklist", "build/test receipt"]
          : ["test/smoke receipt", "redaction if shareable"],
        failClosedAction: baseScenario == .design
          ? "缺截圖時固定回報：工程測試通過，UI 尚未驗收。"
          : "缺可重跑證據就不宣稱完成。"),
      ScenarioLoopNode(
        id: "judge",
        title: "裁決 / 合併",
        ownerIdentity: .verifier,
        plainPurpose: "把主導、監督、sub 與驗收證據合併成 pass / continue / rollback。",
        required: mode >= .m,
        requiredEvidence: ["judge decision", "unresolved risk list"],
        failClosedAction: "P0/P1 或未解 blocking finding 存在時不放行。"),
      ScenarioLoopNode(
        id: "rollback-receipt",
        title: "回滾 / 收據 / handoff",
        ownerIdentity: .verifier,
        plainPurpose: "留下可回朔結果：做了什麼、哪些沒驗、如何回滾或下一輪。",
        required: true,
        requiredEvidence: ["validation receipt", "rollback note", "handoff pack if continuing"],
        failClosedAction: "收據不完整就只交 checkpoint，不稱正式完成。"),
    ]

    return nodes
  }


  private static func makeShowLoopsProjection(
    mode: WorkModeID,
    profile: ScenarioProfile,
    objective: String,
    loopNodes: [ScenarioLoopNode],
    loopEdges: [WorkflowEdge]
  ) -> ScenarioShowLoopsProjection {
    let runID = "scenario-\(mode.rawValue.lowercased())-\(profile.id)-\(shortHash(objective))"
    let contractCallID = "contract-\(runID)"
    let events = loopNodes.enumerated().map { index, node in
      let identity = node.ownerIdentity ?? .lead
      let phaseInput = "\(runID)|\(node.id)|\(identity.rawValue)|\(index + 1)"
      let receiptRefs = node.requiredEvidence.map { requirement in
        "receipt-required-\(slug(requirement))"
      }
      return ScenarioRunEventProjection(
        id: "event-\(node.id)",
        runEventID: "run-event-\(index + 1)-\(node.id)",
        seq: index + 1,
        phaseID: node.id,
        title: node.title,
        identityID: identity.rawValue,
        identityLabel: identity.chineseName,
        contractCallID: contractCallID,
        modelBindingID: "identity-first-\(identity.rawValue)",
        required: node.required,
        receiptRefs: receiptRefs,
        inputHash: shortHash(phaseInput),
        outputHash: nil,
        status: .notDispatched,
        runtimeReceiptRefs: [],
        readOnlyProjection: true,
        canPromoteRunState: false)
    }
    return ScenarioShowLoopsProjection(
      runID: runID,
      contractCallID: contractCallID,
      visualizerSourceOfTruth:
        "workflow_contract_planning_preview; runtime_event_log_required_for_progress",
      visualizerCanMutateRunState: false,
      promotionRequiresReceipts: true,
      missingEventNodePolicy:
        "任何沒有 runtime dispatch record 與 runtime receipt 的視覺節點都只是規劃預覽／decoration，不可 promotion。",
      presentationLabel: "規劃預覽",
      dispatchSummary: "尚未派發",
      runtimeReceiptSummary: "無 runtime receipt",
      events: events,
      edges: loopEdges)
  }

  private static func makeLoopEdges(loopNodes: [ScenarioLoopNode]) -> [WorkflowEdge] {
    zip(loopNodes, loopNodes.dropFirst()).enumerated().map { index, pair in
      WorkflowEdge(
        id: "scenario-loop-e\(index + 1)",
        from: pair.0.id,
        to: pair.1.id,
        label: pair.1.required ? "必過" : "條件啟用")
    }
  }

  private static func makeRequiredTools(mode: WorkModeID, profile: ScenarioProfile) -> [String] {
    var tools = [
      "tatwo.os.begin",
      "tatwo.os.next",
      "tatwo.os.receipt.submit",
      "tatwo.scenario.workflow",
      "tatwo.mode.plan",
      "tatwo.receipt.requirements",
      "tatwo.handoff.pack",
    ]
    if mode >= .m { tools.append("GitNexus project-map / deterministic scope fallback") }
    if mode >= .l { tools.append("tatwo-ultrawork colima run --dry-run or sandbox rehearsal") }
    if profile.baseScenario == .design { tools.append("UI screenshot / visual smoke") }
    return Array(NSOrderedSet(array: tools)) as? [String] ?? tools
  }

  private static func makeVisualizationHints(loopNodes: [ScenarioLoopNode]) -> ScenarioVisualizationHints {
    ScenarioVisualizationHints(
      style: "show-loops-inspired-local",
      sourceURL: "https://github.com/JNSlayer2/show-loops",
      sourceStatus: "optional_external_repo_not_required; local schema remains the source of truth until repo access is verified",
      plainPurpose: "規劃預覽：用身份組節點呈現可能的任務流；沒有 runtime dispatch record 時固定是尚未派發、無 runtime receipt。",
      layout: "read-only planning preview: task -> mode -> identity -> scope -> sandbox -> scout -> builder -> reviewer -> verifier -> judge -> receipt",
      nodeOrder: loopNodes.map(\.id),
      groupByIdentity: true,
      showReceiptsOnNodes: true,
      replacementReady: true)
  }

  private static func makeAgentInvocationPolicy(mode: WorkModeID, profile: ScenarioProfile)
    -> AgentInvocationPolicy
  {
    var beforePatch = ["tatwo.os.begin", "Work OS contractID", "mode receipt", "identity plan receipt"]
    beforePatch.append("tatwo.scenario.workflow compatibility entry allowed only if it returns workOSContract")
    if mode >= .m { beforePatch.append("project-map or scope receipt") }
    if mode >= .l { beforePatch.append("sandbox or degraded-sandbox receipt") }
    if profile.baseScenario == .design { beforePatch.append("UI target + visual evidence plan") }
    return AgentInvocationPolicy(
      mustCallWorkflowToolBeforeActing: true,
      requiredFirstTool: "tatwo.os.begin",
      noReceiptNoClaim: true,
      externalModelReceiptRequired: true,
      hostMutationDefaultAllowed: false,
      requiresContractCallIDForEveryAction: true,
      rejectsNakedToolCall: true,
      visualizerCanPromoteRunState: false,
      sameModelMultiRoleMarkedSimulated: true,
      fakeExecutionBlockedMessage: "沒有 Work OS contractID、runtime dispatch record 或 bridge/tool/CLI receipt 時，只能說「規劃預覽／尚未派發／無 runtime receipt」，不能說外部模型已執行。",
      requiredBeforeAnyPatch: Array(NSOrderedSet(array: beforePatch)) as? [String] ?? beforePatch)
  }

  private static func makeRecommendedPlugins(mode: WorkModeID, profile: ScenarioProfile) -> [String] {
    var plugins = ["tatwo-ultrawork", "chatgpt-pro-mcp"]
    if mode >= .m { plugins.append("gitnexus") }
    if mode >= .l { plugins.append("colima-sandbox-runner") }
    if mode >= .m && profile.baseScenario == .design { plugins.append("product-design") }
    if profile.identitySlots.contains(where: { $0.kind == .news }) { plugins.append("grok/news lane") }
    plugins.append("codex-app-model-gateway")
    return Array(NSOrderedSet(array: plugins)) as? [String] ?? plugins
  }

  private static func makeForbiddenClaims(profile: ScenarioProfile) -> [String] {
    var claims = [
      "不可說外部模型已參與，除非有 bridge/tool/CLI receipt。",
      "不可把 planned identity、receipt-required refs、節點數或預估輪次當 runtime 進度。",
      "不可把模型文字自評當驗收。",
      "不可說已實裝 host，除非有備份、live smoke、MCP registration smoke 與人類授權。",
      "不可讓 builder 自己當最終驗收。",
    ]
    if profile.baseScenario == .design {
      claims.append("不可用 build pass 取代 UI 截圖/互動驗收。")
    }
    return claims
  }

  private static func makeForbiddenActions() -> [String] {
    [
      "不得修改 signed Codex App bundle。",
      "不得自動寫真實 LaunchAgent 或主機 Codex session/auth 狀態。",
      "不得把 token、cookie、raw log、完整聊天、私密路徑放進公開 artifact。",
      "不得讓 sub/news/consultant 自行開危險工具或寫檔。",
    ]
  }

  private static func makeReceiptRequirements(
    mode: WorkModeID,
    profile: ScenarioProfile,
    modePlan: ModeIdentityPlan,
    runPlan: WorkflowRunPlan
  ) -> [String] {
    var receipts = modePlan.requiredReceipts + runPlan.gates.flatMap(\.requiredBeforePass)
    if profile.baseScenario == .design {
      receipts += ["screenshot or recording", "visual checklist"]
    }
    if mode == .s {
      receipts = receipts.filter { !$0.localizedCaseInsensitiveContains("GitNexus") }
      receipts.append("S mode no-sub note")
    }
    return Array(NSOrderedSet(array: receipts)) as? [String] ?? receipts
  }

  private static func failClosedRule(mode: WorkModeID, profile: ScenarioProfile) -> String {
    if profile.baseScenario == .design {
      return "UI/UJ 缺截圖或互動證據時，不可宣稱完成；只能說工程測試通過，UI 尚未驗收。"
    }
    if mode >= .m {
      return "M/L/XL 缺 scope、review、validation 任一收據時，不可宣稱完成。"
    }
    return "S 小修缺本機檢查或直接證據時，不可宣稱完成。"
  }

  private static func shortHash(_ raw: String) -> String {
    SHA256.hash(data: Data(raw.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  private static func slug(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let lowered = raw.lowercased()
    var output = ""
    for scalar in lowered.unicodeScalars {
      if allowed.contains(scalar) {
        output.unicodeScalars.append(scalar)
      } else if output.last != "-" {
        output.append("-")
      }
    }
    let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "receipt" : String(trimmed.prefix(48))
  }

}
