import Foundation

public enum TatwoWorkOSDashboardLaneKind: String, Codable, Sendable, CaseIterable, Equatable {
  case goal
  case contract
  case mainline
  case domain
  case sandbox
  case receipts
  case outcome
}

public struct TatwoWorkOSDashboardGoalSummary: Codable, Sendable, Equatable {
  public let goalID: String
  public let objective: String
  public let status: GoalRunStatus
  public let mode: WorkModeID
  public let scenario: String
  public let currentLoopID: String

  public init(goalID: String, objective: String, status: GoalRunStatus, mode: WorkModeID, scenario: String, currentLoopID: String) {
    self.goalID = goalID
    self.objective = TatwoPrivacyRedactor.redacted(objective)
    self.status = status
    self.mode = mode
    self.scenario = TatwoPrivacyRedactor.redacted(scenario)
    self.currentLoopID = TatwoPrivacyRedactor.redacted(currentLoopID)
  }
}

public struct TatwoWorkOSDashboardContractSummary: Codable, Sendable, Equatable {
  public let contractID: String
  public let mode: WorkModeID
  public let scenario: String
  public let configStage: WorkOSConfigStage
  public let failClosed: Bool
  public let gatewayRoutes: [String]
  public let visualizerCanPromoteRunState: Bool

  public init(contractID: String, mode: WorkModeID, scenario: String, configStage: WorkOSConfigStage, failClosed: Bool, gatewayRoutes: [String], visualizerCanPromoteRunState: Bool) {
    self.contractID = TatwoPrivacyRedactor.redacted(contractID)
    self.mode = mode
    self.scenario = TatwoPrivacyRedactor.redacted(scenario)
    self.configStage = configStage
    self.failClosed = failClosed
    self.gatewayRoutes = gatewayRoutes.map { TatwoPrivacyRedactor.redacted($0) }
    self.visualizerCanPromoteRunState = visualizerCanPromoteRunState
  }
}

public struct TatwoWorkOSDashboardLane: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let kind: TatwoWorkOSDashboardLaneKind
  public let title: String
  public let ownerIdentity: IdentityKind
  public let status: GoalRunStatus
  public let allowedTools: [String]
  public let receiptIDs: [String]
  public let plainPurpose: String
  public let canPromoteRunState: Bool

  public init(id: String, kind: TatwoWorkOSDashboardLaneKind, title: String, ownerIdentity: IdentityKind, status: GoalRunStatus, allowedTools: [String], receiptIDs: [String], plainPurpose: String, canPromoteRunState: Bool = false) {
    self.id = TatwoPrivacyRedactor.redacted(id)
    self.kind = kind
    self.title = TatwoPrivacyRedactor.redacted(title)
    self.ownerIdentity = ownerIdentity
    self.status = status
    self.allowedTools = allowedTools.map { TatwoPrivacyRedactor.redacted($0) }
    self.receiptIDs = receiptIDs.map { TatwoPrivacyRedactor.redacted($0) }
    self.plainPurpose = TatwoPrivacyRedactor.redacted(plainPurpose)
    self.canPromoteRunState = canPromoteRunState
  }
}

public struct TatwoWorkOSDashboardIdentitySlot: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let identity: IdentityKind
  public let label: String
  public let engineID: EngineID?
  public let modelID: String?
  public let authority: AuthorityMode
  public let canMutateHost: Bool
  public let bindingRule: String

  public init(binding: WorkOSIdentityBinding) {
    self.id = binding.id
    self.identity = binding.identity
    self.label = binding.label
    self.engineID = binding.engineID
    self.modelID = binding.modelID.map { TatwoPrivacyRedactor.redacted($0) }
    self.authority = binding.authority
    self.canMutateHost = binding.canMutateHost
    self.bindingRule = TatwoPrivacyRedactor.redacted(binding.bindingRule)
  }
}

public struct TatwoWorkOSDashboardToolRail: Codable, Sendable, Equatable {
  public let registeredOnly: Bool
  public let source: String
  public let allowedTools: [String]
  public let deniedByDefault: [String]

  public init(registeredOnly: Bool, source: String, allowedTools: [String], deniedByDefault: [String]) {
    self.registeredOnly = registeredOnly
    self.source = TatwoPrivacyRedactor.redacted(source)
    self.allowedTools = allowedTools.map { TatwoPrivacyRedactor.redacted($0) }
    self.deniedByDefault = deniedByDefault.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct TatwoWorkOSDashboardSandboxSummary: Codable, Sendable, Equatable {
  public let required: Bool
  public let defaultType: WorkOSSandboxType
  public let allowedTypes: [WorkOSSandboxType]
  public let stagingConfigRequired: Bool
  public let hostMutationAllowed: Bool
  public let humanGateRequired: Bool
  public let promotionRule: String
  public let forbiddenTargets: [String]

  public init(policy: WorkOSSandboxPolicy) {
    self.required = policy.required
    self.defaultType = policy.defaultType
    self.allowedTypes = policy.allowedTypes
    self.stagingConfigRequired = policy.stagingConfigRequired
    self.hostMutationAllowed = policy.hostMutationAllowed
    self.humanGateRequired = policy.humanGateRequired
    self.promotionRule = TatwoPrivacyRedactor.redacted(policy.promotionRule)
    self.forbiddenTargets = policy.forbiddenTargets.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct TatwoWorkOSDashboardReceiptRail: Codable, Sendable, Equatable {
  public let requiredReceiptIDs: [String]
  public let optionalReceiptIDs: [String]
  public let submittedReceiptIDs: [String]
  public let missingRequiredReceiptIDs: [String]
  public let requiredCount: Int
  public let submittedCount: Int
  public let missingCount: Int

  public init(requirements: [WorkOSReceiptRequirement], submittedReceiptIDs: [String]) {
    let submitted = Array(NSOrderedSet(array: submittedReceiptIDs.map { TatwoPrivacyRedactor.redacted($0) })) as? [String] ?? submittedReceiptIDs
    let required = requirements.filter(\.requiredForPass).map(\.id)
    let optional = requirements.filter { !$0.requiredForPass }.map(\.id)
    let submittedSet = Set(submitted)
    let missing = required.filter { !submittedSet.contains($0) }
    self.requiredReceiptIDs = required.map { TatwoPrivacyRedactor.redacted($0) }
    self.optionalReceiptIDs = optional.map { TatwoPrivacyRedactor.redacted($0) }
    self.submittedReceiptIDs = submitted
    self.missingRequiredReceiptIDs = missing.map { TatwoPrivacyRedactor.redacted($0) }
    self.requiredCount = required.count
    self.submittedCount = submitted.count
    self.missingCount = missing.count
  }
}

public struct TatwoWorkOSDashboardNextAction: Codable, Sendable, Equatable {
  public let tool: String
  public let commandHint: String
  public let plainText: String
  public let mustCarryContractID: Bool

  public init(
    tool: String,
    commandHint: String,
    plainText: String,
    mustCarryContractID: Bool
  ) {
    self.tool = TatwoPrivacyRedactor.redacted(tool)
    self.commandHint = TatwoPrivacyRedactor.redacted(commandHint)
    self.plainText = TatwoPrivacyRedactor.redacted(plainText)
    self.mustCarryContractID = mustCarryContractID
  }

  public init(contract: TatwoWorkOSContractV1) {
    self.tool = "tatwo.os.next"
    self.commandHint = "tatwo-ultrawork os next --goal \(contract.goalID) --contract \(contract.contractID) --json"
    self.plainText = TatwoPrivacyRedactor.redacted(contract.nextAction)
    self.mustCarryContractID = true
  }
}

public struct TatwoWorkOSDashboardOutcome: Codable, Sendable, Equatable {
  public let readyLabel: String
  public let rollbackLabel: String
  public let readyWhen: [String]
  public let rollbackWhen: [String]
  public let canPassFromDashboard: Bool

  public init(
    readyLabel: String,
    rollbackLabel: String,
    readyWhen: [String],
    rollbackWhen: [String],
    canPassFromDashboard: Bool
  ) {
    self.readyLabel = TatwoPrivacyRedactor.redacted(readyLabel)
    self.rollbackLabel = TatwoPrivacyRedactor.redacted(rollbackLabel)
    self.readyWhen = readyWhen.map { TatwoPrivacyRedactor.redacted($0) }
    self.rollbackWhen = rollbackWhen.map { TatwoPrivacyRedactor.redacted($0) }
    self.canPassFromDashboard = canPassFromDashboard
  }

  public init(receiptRail: TatwoWorkOSDashboardReceiptRail, sandbox: WorkOSSandboxPolicy) {
    let missingText = receiptRail.missingCount == 0 ? "receipt 齊全，等待人工 promotion gate" : "缺 \(receiptRail.missingCount) 個必要 receipt"
    self.readyLabel = "READY：\(missingText)"
    self.rollbackLabel = "ROLLBACK：證據不足、sandbox 失敗、host 風險或人類未放行時回滾"
    self.readyWhen = [
      "contractID 有效",
      "必要 receipt 齊全",
      sandbox.required ? "sandbox/staging selftest 通過" : "local evidence 通過",
      sandbox.humanGateRequired ? "人工 gate 明確授權" : "模式允許自動關閉",
    ]
    self.rollbackWhen = [
      "缺必要 receipt",
      "post-seal mutation 或測試失敗",
      "host mutation 未授權",
      "App visualizer 嘗試直接 pass",
    ]
    self.canPassFromDashboard = false
  }
}

public struct TatwoWorkOSDashboardSnapshot: Codable, Sendable, Equatable {
  public let schema: String
  public let readOnly: Bool
  public let canPromoteRunState: Bool
  public let generatedAt: Date
  public let goal: TatwoWorkOSDashboardGoalSummary
  public let contract: TatwoWorkOSDashboardContractSummary
  public let lanes: [TatwoWorkOSDashboardLane]
  public let identitySlots: [TatwoWorkOSDashboardIdentitySlot]
  public let toolRail: TatwoWorkOSDashboardToolRail
  public let sandbox: TatwoWorkOSDashboardSandboxSummary
  public let receiptRail: TatwoWorkOSDashboardReceiptRail
  public let nextAction: TatwoWorkOSDashboardNextAction
  public let outcome: TatwoWorkOSDashboardOutcome
  public let dashboardRules: [String]
  /// B2: the real (and last-known) sub-dispatches per identity binding, sourced from the
  /// dispatch registry. Empty when no dispatch has been recorded — the honest "nothing is
  /// running / nothing has run yet" state, never a faked sub.
  public let runningWorkers: [TatwoWorkOSDashboardRunningWorker]
  /// Present when a persisted current-session pointer exists but cannot be validated
  /// against the canonical GoalRun. In this state the dashboard is an integrity block,
  /// not a synthetic replacement contract.
  public let sessionIntegrityIssue: String?

  public init(
    schema: String = "TatwoWorkOSDashboardSnapshotV1",
    readOnly: Bool = true,
    canPromoteRunState: Bool = false,
    generatedAt: Date = Date(),
    goal: TatwoWorkOSDashboardGoalSummary,
    contract: TatwoWorkOSDashboardContractSummary,
    lanes: [TatwoWorkOSDashboardLane],
    identitySlots: [TatwoWorkOSDashboardIdentitySlot],
    toolRail: TatwoWorkOSDashboardToolRail,
    sandbox: TatwoWorkOSDashboardSandboxSummary,
    receiptRail: TatwoWorkOSDashboardReceiptRail,
    nextAction: TatwoWorkOSDashboardNextAction,
    outcome: TatwoWorkOSDashboardOutcome,
    dashboardRules: [String],
    runningWorkers: [TatwoWorkOSDashboardRunningWorker] = [],
    sessionIntegrityIssue: String? = nil
  ) {
    self.schema = schema
    self.readOnly = readOnly
    self.canPromoteRunState = canPromoteRunState
    self.generatedAt = generatedAt
    self.goal = goal
    self.contract = contract
    self.lanes = lanes
    self.identitySlots = identitySlots
    self.toolRail = toolRail
    self.sandbox = sandbox
    self.receiptRail = receiptRail
    self.nextAction = nextAction
    self.outcome = outcome
    self.dashboardRules = dashboardRules.map { TatwoPrivacyRedactor.redacted($0) }
    self.runningWorkers = runningWorkers
    self.sessionIntegrityIssue = sessionIntegrityIssue.map { TatwoPrivacyRedactor.redacted($0) }
  }

  /// Return a copy with runningWorkers replaced. Lets a UI keep the base snapshot live from
  /// its source while overlaying registry-polled workers, without re-seeding @State.
  public func withRunningWorkers(_ workers: [TatwoWorkOSDashboardRunningWorker])
    -> TatwoWorkOSDashboardSnapshot
  {
    TatwoWorkOSDashboardSnapshot(
      schema: schema, readOnly: readOnly, canPromoteRunState: canPromoteRunState,
      generatedAt: generatedAt, goal: goal, contract: contract, lanes: lanes,
      identitySlots: identitySlots, toolRail: toolRail, sandbox: sandbox,
      receiptRail: receiptRail, nextAction: nextAction, outcome: outcome,
      dashboardRules: dashboardRules, runningWorkers: workers,
      sessionIntegrityIssue: sessionIntegrityIssue)
  }
}

public struct TatwoWorkOSDashboardRunningWorker: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let bindingID: String
  public let identity: IdentityKind
  public let modelID: String
  public let status: TatwoDispatchStatus
  public let startedAt: Date
  public let updatedAt: Date
  public let receiptID: String?

  public init(record: TatwoDispatchRecord) {
    self.id = TatwoPrivacyRedactor.redacted(record.id)
    // Raw (not redacted): this is the join key to TatwoWorkOSDashboardIdentitySlot.id,
    // which is also stored raw. A binding id carries no secret.
    self.bindingID = record.bindingID
    self.identity = record.identity
    self.modelID = TatwoPrivacyRedactor.redacted(record.modelID)
    self.status = record.status
    self.startedAt = record.startedAt
    self.updatedAt = record.updatedAt
    self.receiptID = record.receiptID.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public enum TatwoWorkOSDashboardFactory {
  public static func makeSessionIntegrityFailure(
    mode: WorkModeID,
    scenario: String,
    reason: String
  ) -> TatwoWorkOSDashboardSnapshot {
    let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let issue =
      normalizedReason.isEmpty
      ? "current-session pointer could not be validated against canonical GoalRun state"
      : normalizedReason
    let sandboxPolicy = WorkOSSandboxPolicy(
      required: true,
      defaultType: .tempWorkspace,
      allowedTypes: [.tempWorkspace],
      stagingConfigRequired: true,
      hostMutationAllowed: false,
      humanGateRequired: true,
      promotionRule: "先修復 current-session 與 canonical GoalRun 一致性，再恢復 Plan／Loops。",
      forbiddenTargets: [
        "tatwo.os.next",
        "dispatch",
        "goal mutation",
        "host mutation",
      ])
    let receiptRail = TatwoWorkOSDashboardReceiptRail(
      requirements: [],
      submittedReceiptIDs: [])
    return TatwoWorkOSDashboardSnapshot(
      goal: TatwoWorkOSDashboardGoalSummary(
        goalID: "current-session-unverifiable",
        objective: "目前 Work OS Session 無法驗證；未建立替代 Goal。",
        status: .blocked,
        mode: mode,
        scenario: scenario,
        currentLoopID: "none"),
      contract: TatwoWorkOSDashboardContractSummary(
        contractID: "current-session-unverifiable",
        mode: mode,
        scenario: scenario,
        configStage: .staging,
        failClosed: true,
        gatewayRoutes: [],
        visualizerCanPromoteRunState: false),
      lanes: [
        TatwoWorkOSDashboardLane(
          id: "current-session-integrity",
          kind: .contract,
          title: "Current Session Integrity",
          ownerIdentity: .lead,
          status: .blocked,
          allowedTools: [],
          receiptIDs: [],
          plainPurpose: "current-session 與 canonical GoalRun 驗證失敗；禁止建立替代 Goal 或派發 Loops。")
      ],
      identitySlots: [],
      toolRail: TatwoWorkOSDashboardToolRail(
        registeredOnly: true,
        source: "current-session integrity gate",
        allowedTools: [],
        deniedByDefault: [
          "tatwo.os.next",
          "dispatch",
          "goal close",
          "host mutation",
        ]),
      sandbox: TatwoWorkOSDashboardSandboxSummary(policy: sandboxPolicy),
      receiptRail: receiptRail,
      nextAction: TatwoWorkOSDashboardNextAction(
        tool: "none",
        commandHint: "",
        plainText: "先檢查 current-session pointer 與 canonical GoalRun；完整一致前不派工。",
        mustCarryContractID: false),
      outcome: TatwoWorkOSDashboardOutcome(
        readyLabel: "BLOCKED：current-session 無法驗證",
        rollbackLabel: "FAIL CLOSED：未建立替代 Goal，未派發 Loops",
        readyWhen: [
          "pointer schema 正確",
          "pointer 與 canonical GoalRun 全欄位一致",
          "stored contract projection 可重建且 route binding 一致",
        ],
        rollbackWhen: [
          "pointer 無法解碼",
          "GoalRun 缺失或欄位不一致",
          "stored projection 失敗",
        ],
        canPassFromDashboard: false),
      dashboardRules: [
        "current-session integrity failure 不得降級成 synthetic begin。",
        "此畫面只呈現阻擋狀態，不代表有新 Goal 或新 Loops。",
        "修復 pointer／GoalRun 後必須重新讀取並驗證。",
      ],
      runningWorkers: [],
      sessionIntegrityIssue: issue)
  }

  public static func make(
    contract: TatwoWorkOSContractV1,
    submittedReceiptIDs: [String] = [],
    registry: TatwoDispatchRegistry? = nil
  ) -> TatwoWorkOSDashboardSnapshot {
    // B2: read real dispatch records for this contract; any read error (incl. no run on disk
    // yet) degrades to [] — the honest "nothing dispatched yet" state, never a throw/crash.
    let runningWorkers =
      ((try? registry?.latestRecordsByBinding(forContractID: contract.contractID)) ?? nil)?
      .map(TatwoWorkOSDashboardRunningWorker.init) ?? []
    let receiptRail = TatwoWorkOSDashboardReceiptRail(
      requirements: contract.receiptRequirements,
      submittedReceiptIDs: submittedReceiptIDs)
    let allowedTools = normalizedAllowedTools(contract)
    let lanes = makeLanes(contract: contract, allowedTools: allowedTools)
    return TatwoWorkOSDashboardSnapshot(
      goal: TatwoWorkOSDashboardGoalSummary(
        goalID: contract.goalID,
        objective: contract.objective,
        status: contract.goalRun.status,
        mode: contract.mode,
        scenario: contract.scenario,
        currentLoopID: contract.goalRun.currentLoopID),
      contract: TatwoWorkOSDashboardContractSummary(
        contractID: contract.contractID,
        mode: contract.mode,
        scenario: contract.scenario,
        configStage: contract.configStage,
        failClosed: true,
        gatewayRoutes: contract.gatewayRouteReservations.map(\.route),
        visualizerCanPromoteRunState: false),
      lanes: lanes,
      identitySlots: contract.identityBindings.map(TatwoWorkOSDashboardIdentitySlot.init),
      toolRail: TatwoWorkOSDashboardToolRail(
        registeredOnly: true,
        source: "Work OS contract + Ultrawork registry",
        allowedTools: allowedTools,
        deniedByDefault: [
          "unregistered MCP/skill",
          "signed Codex App bundle patch",
          "auth/session/token/browser profile access",
          "real LaunchAgent mutation",
          "paid/API fan-out without human budget",
        ]),
      sandbox: TatwoWorkOSDashboardSandboxSummary(policy: contract.sandboxPolicy),
      receiptRail: receiptRail,
      nextAction: TatwoWorkOSDashboardNextAction(contract: contract),
      outcome: TatwoWorkOSDashboardOutcome(receiptRail: receiptRail, sandbox: contract.sandboxPolicy),
      dashboardRules: [
        "Dashboard 是 OS 控制台與投影，不是 pass 按鈕。",
        "所有 agent action 都必須攜帶 contractID。",
        "主線監督 domain loops；domain loops 只提交 receipts 回主線。",
        "READY 只代表證據可進人工 promotion gate；不是自動實裝。",
        "ROLLBACK 比裸 PASS/FAIL 更重要：缺證據或 host 風險就退回。",
      ],
      runningWorkers: runningWorkers)
  }

  public static func normalizedAllowedTools(_ contract: TatwoWorkOSContractV1) -> [String] {
    let tools = contract.mainlineLoop.allowedTools
      + contract.domainLoops.flatMap(\.allowedTools)
      + [
        "tatwo.os.begin",
        "tatwo.os.next",
        "tatwo.os.loop.status",
        "tatwo.os.receipt.submit",
        "tatwo.os.goal.close",
        "tatwo.os.dashboard",
        "tatwo.os.enforce",
        "tatwo.os.handoff",
        "tatwo.os.constitution",
      ]
    let trimmed = tools.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return Array(NSOrderedSet(array: trimmed)) as? [String] ?? trimmed
  }

  private static func makeLanes(contract: TatwoWorkOSContractV1, allowedTools: [String]) -> [TatwoWorkOSDashboardLane] {
    var lanes: [TatwoWorkOSDashboardLane] = [
      TatwoWorkOSDashboardLane(
        id: "goal",
        kind: .goal,
        title: "GoalRun",
        ownerIdentity: .lead,
        status: contract.goalRun.status,
        allowedTools: ["tatwo.os.next"],
        receiptIDs: ["contract-id", "mode-budget"],
        plainPurpose: "使用者任務先進 OS goal，不讓模型直接猜流程。"),
      TatwoWorkOSDashboardLane(
        id: "contract",
        kind: .contract,
        title: "OS Contract",
        ownerIdentity: .lead,
        status: .planned,
        allowedTools: ["tatwo.os.enforce", "tatwo.os.handoff"],
        receiptIDs: ["contract-id", "identity-bindings"],
        plainPurpose: "contractID 是所有 action 的邊界；缺少就 fail closed。"),
      TatwoWorkOSDashboardLane(
        id: contract.mainlineLoop.id,
        kind: .mainline,
        title: contract.mainlineLoop.title,
        ownerIdentity: contract.mainlineLoop.ownerIdentity,
        status: contract.mainlineLoop.status,
        allowedTools: contract.mainlineLoop.allowedTools,
        receiptIDs: contract.mainlineLoop.requiredReceipts.map(\.id),
        plainPurpose: contract.mainlineLoop.objective),
    ]
    lanes += contract.domainLoops.map {
      TatwoWorkOSDashboardLane(
        id: $0.id,
        kind: .domain,
        title: $0.title,
        ownerIdentity: $0.ownerIdentity,
        status: $0.status,
        allowedTools: $0.allowedTools,
        receiptIDs: $0.requiredReceipts.map(\.id),
        plainPurpose: $0.mergeBackRule)
    }
    lanes += [
      TatwoWorkOSDashboardLane(
        id: "sandbox",
        kind: .sandbox,
        title: "Sandbox / Staging",
        ownerIdentity: .verifier,
        status: .planned,
        allowedTools: allowedTools.filter { $0.contains("sandbox") || $0.contains("colima") || $0.contains("web-check") },
        receiptIDs: ["sandbox", "staging", "rollback"],
        plainPurpose: contract.sandboxPolicy.promotionRule),
      TatwoWorkOSDashboardLane(
        id: "receipts",
        kind: .receipts,
        title: "Receipt Rail",
        ownerIdentity: .verifier,
        status: .planned,
        allowedTools: ["tatwo.os.receipt.submit", "tatwo.os.goal.close"],
        receiptIDs: contract.receiptRequirements.map(\.id),
        plainPurpose: "模型自評不算 receipt；測試、截圖、review、sandbox、rollback 才算。"),
      TatwoWorkOSDashboardLane(
        id: "outcome",
        kind: .outcome,
        title: "READY / ROLLBACK",
        ownerIdentity: .lead,
        status: .humanGate,
        allowedTools: ["tatwo.os.goal.close"],
        receiptIDs: contract.receiptRequirements.filter(\.requiredForPass).map(\.id),
        plainPurpose: "READY 等待人工 gate；ROLLBACK 處理證據不足或主機風險。"),
    ]
    return lanes
  }
}
