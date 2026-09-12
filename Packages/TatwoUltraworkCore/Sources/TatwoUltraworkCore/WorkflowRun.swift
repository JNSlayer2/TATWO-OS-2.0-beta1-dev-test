import CryptoKit
import Foundation

public enum WorkflowStepStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case pending
  case ready
  case manualGate = "manual_gate"
  case blocked
  case done
}

public struct WorkflowRunStep: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let ownerRole: String
  public let status: WorkflowStepStatus
  public let allowedHostMutation: Bool
  public let requiredEvidence: [EvidenceKind]
  public let doneCondition: String

  public init(
    id: String,
    title: String,
    ownerRole: String,
    status: WorkflowStepStatus,
    allowedHostMutation: Bool,
    requiredEvidence: [EvidenceKind],
    doneCondition: String
  ) {
    self.id = id
    self.title = title
    self.ownerRole = ownerRole
    self.status = status
    self.allowedHostMutation = allowedHostMutation
    self.requiredEvidence = requiredEvidence
    self.doneCondition = doneCondition
  }
}

public struct WorkflowGate: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let failClosedReason: String
  public let requiredBeforePass: [String]

  public init(id: String, title: String, failClosedReason: String, requiredBeforePass: [String]) {
    self.id = id
    self.title = title
    self.failClosedReason = failClosedReason
    self.requiredBeforePass = requiredBeforePass
  }
}

public struct WorkflowRunPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let planID: String
  public let objective: String
  public let mode: WorkModeID
  public let scenario: ScenarioID
  public let createdAt: Date
  public let dryRunOnly: Bool
  public let sandboxRequired: Bool
  public let humanApprovalRequired: Bool
  public let hostMutationAllowed: Bool
  public let budgetLabel: String
  public let helperLimit: Int
  public let roundLimit: Int
  public let identitySlots: [IdentitySlot]
  public let roleAssignments: [ModelRoleAssignment]
  public let steps: [WorkflowRunStep]
  public let gates: [WorkflowGate]
  public let stopRules: [String]
  public let safeMemoryPolicy: [String]

  public init(
    schema: String = "TatwoWorkflowRunPlanV1",
    planID: String,
    objective: String,
    mode: WorkModeID,
    scenario: ScenarioID,
    createdAt: Date = Date(),
    dryRunOnly: Bool,
    sandboxRequired: Bool,
    humanApprovalRequired: Bool,
    hostMutationAllowed: Bool,
    budgetLabel: String,
    helperLimit: Int,
    roundLimit: Int,
    identitySlots: [IdentitySlot] = [],
    roleAssignments: [ModelRoleAssignment],
    steps: [WorkflowRunStep],
    gates: [WorkflowGate],
    stopRules: [String],
    safeMemoryPolicy: [String]
  ) {
    self.schema = schema
    self.planID = planID
    self.objective = objective
    self.mode = mode
    self.scenario = scenario
    self.createdAt = createdAt
    self.dryRunOnly = dryRunOnly
    self.sandboxRequired = sandboxRequired
    self.humanApprovalRequired = humanApprovalRequired
    self.hostMutationAllowed = hostMutationAllowed
    self.budgetLabel = budgetLabel
    self.helperLimit = helperLimit
    self.roundLimit = roundLimit
    self.identitySlots = identitySlots
    self.roleAssignments = roleAssignments
    self.steps = steps
    self.gates = gates
    self.stopRules = stopRules
    self.safeMemoryPolicy = safeMemoryPolicy
  }
}

public struct HandoffPack: Codable, Sendable, Equatable {
  public let schema: String
  public let planID: String
  public let objective: String
  public let mode: WorkModeID
  public let scenario: ScenarioID
  public let summary: String
  public let currentStepID: String
  public let nextActions: [String]
  public let evidenceRequired: [String]
  public let commands: [String]
  public let privacyRules: [String]
  public let contentHash: String

  public init(
    schema: String = "TatwoHandoffPackV1",
    planID: String,
    objective: String,
    mode: WorkModeID,
    scenario: ScenarioID,
    summary: String,
    currentStepID: String,
    nextActions: [String],
    evidenceRequired: [String],
    commands: [String],
    privacyRules: [String],
    contentHash: String
  ) {
    self.schema = schema
    self.planID = planID
    self.objective = objective
    self.mode = mode
    self.scenario = scenario
    self.summary = summary
    self.currentStepID = currentStepID
    self.nextActions = nextActions
    self.evidenceRequired = evidenceRequired
    self.commands = commands
    self.privacyRules = privacyRules
    self.contentHash = contentHash
  }
}

public struct InstallDependency: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public let kind: RegistryKind
  public let required: Bool
  public let detection: String
  public let prompt: String
  public let defaultAction: InstallAction

  public init(
    id: String, name: String, kind: RegistryKind, required: Bool, detection: String, prompt: String,
    defaultAction: InstallAction
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.required = required
    self.detection = detection
    self.prompt = prompt
    self.defaultAction = defaultAction
  }
}

public enum InstallAction: String, Codable, Sendable, CaseIterable, Equatable {
  case install
  case skip
  case later
  case manual
}

public struct HostInstallPlan: Codable, Sendable, Equatable {
  public let schema: String
  public let hostMutationDefault: Bool
  public let preflightCommands: [String]
  public let backupTargets: [String]
  public let dependencies: [InstallDependency]
  public let smokeCommands: [String]
  public let rollbackPlan: [String]

  public init(
    schema: String = "TatwoHostInstallPlanV1",
    hostMutationDefault: Bool,
    preflightCommands: [String],
    backupTargets: [String],
    dependencies: [InstallDependency],
    smokeCommands: [String],
    rollbackPlan: [String]
  ) {
    self.schema = schema
    self.hostMutationDefault = hostMutationDefault
    self.preflightCommands = preflightCommands
    self.backupTargets = backupTargets
    self.dependencies = dependencies
    self.smokeCommands = smokeCommands
    self.rollbackPlan = rollbackPlan
  }
}

public enum WorkflowRunFactory {
  public static func makePlan(
    objective: String,
    mode: WorkModeID,
    scenario: ScenarioID,
    dryRunOnly: Bool = true,
    catalog: TatwoCatalog = .defaults
  ) -> WorkflowRunPlan {
    let rawObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    let safeObjective =
      rawObjective.isEmpty
      ? "未命名 Tatwo Ultrawork 任務"
      : TatwoPrivacyRedactor.redacted(rawObjective)
    let workMode = catalog.mode(mode) ?? catalog.workModes.last ?? fallbackMode(mode)
    let scenarioDef = catalog.scenario(scenario)
    let runID = stablePlanID(objective: safeObjective, mode: mode, scenario: scenario)
    // Workflow plans may allow Codex to prepare patch/build steps in a sandbox,
    // but they must never authorize real host installation by themselves.
    // Host mutation is released only by the separate host readiness gate after
    // human approval, backup, live same-thread smoke, and MCP registration smoke.
    let humanApprovalRequired = workMode.requiresHumanApproval || !dryRunOnly
    let hostMutationAllowed = false
    let scenarioProfileID = profileID(for: scenario)
    let identityPlan = TatwoIdentityCatalog.modePlan(
      mode: mode, scenarioProfileID: scenarioProfileID, catalog: catalog)
    let profileGuardrails =
      TatwoIdentityCatalog.scenarioProfile(scenarioProfileID)?.guardrails ?? []

    return WorkflowRunPlan(
      planID: runID,
      objective: safeObjective,
      mode: mode,
      scenario: scenario,
      dryRunOnly: dryRunOnly,
      sandboxRequired: workMode.requiresSandbox,
      humanApprovalRequired: humanApprovalRequired,
      hostMutationAllowed: hostMutationAllowed,
      budgetLabel: workMode.defaultBudget.tokenRangeLabel,
      helperLimit: workMode.maxHelpers,
      roundLimit: workMode.maxRounds,
      identitySlots: identityPlan.identitySlots,
      roleAssignments: scenarioDef?.roleWeights ?? workMode.roleAssignments,
      steps: steps(for: workMode, scenario: scenario, dryRunOnly: dryRunOnly),
      gates: gates(for: workMode, scenario: scenario),
      stopRules: workMode.stopRules + (scenarioDef?.guardrails ?? []) + profileGuardrails,
      safeMemoryPolicy: [
        "只存模式偏好、情境權重、契合度、成功/失敗收據、可重用 failure mode",
        "不存 raw log、token、完整聊天、私密路徑、截圖原檔",
        "任何記憶寫入前先跑 SafeMemoryGate",
      ]
    )
  }

  public static func makeHandoffPack(
    objective: String,
    mode: WorkModeID,
    scenario: ScenarioID,
    catalog: TatwoCatalog = .defaults
  ) -> HandoffPack {
    let plan = makePlan(
      objective: objective, mode: mode, scenario: scenario, dryRunOnly: true, catalog: catalog)
    let commands = [
      "swift test",
      "swift run tatwo-ultrawork workflow run --mode \(mode.rawValue) --scenario \(scenario.rawValue) --objective '<objective>' --dry-run --json",
      "swift run tatwo-ultrawork sandbox preflight --json",
      "swift run tatwo-ultrawork colima preflight --json",
      "swift run tatwo-ultrawork colima run --mode \(mode.rawValue) --scenario \(scenario.rawValue) --objective '<objective>' --dry-run --json",
      "bash scripts/tatwo-ultrawork-sandbox-check.sh",
    ]
    let nextActions = plan.steps.prefix(5).map { "\($0.id): \($0.doneCondition)" }
    let evidenceRequired = plan.gates.flatMap(\.requiredBeforePass)
    let privacyRules = [
      "handoff 不包含本機絕對路徑、token、raw log、完整聊天",
      "外部模型只能提出研究、審稿、patch intent；寫檔與 shell 由 Codex executor 執行",
      "沒有工具 trace 的內容不可宣稱已驗證",
    ]
    let hashInput =
      ([plan.planID, plan.objective, mode.rawValue, scenario.rawValue] + nextActions
      + evidenceRequired + commands + privacyRules).joined(separator: "\n")
    return HandoffPack(
      planID: plan.planID,
      objective: plan.objective,
      mode: mode,
      scenario: scenario,
      summary: "Tatwo Ultrawork \(mode.rawValue) / \(scenario.rawValue) workflow-first handoff",
      currentStepID: plan.steps.first?.id ?? "define",
      nextActions: nextActions,
      evidenceRequired: evidenceRequired,
      commands: commands,
      privacyRules: privacyRules,
      contentHash: sha256Hex(Data(hashInput.utf8))
    )
  }

  public static func installPlan(catalog: TatwoCatalog = .defaults) -> HostInstallPlan {
    HostInstallPlan(
      hostMutationDefault: false,
      preflightCommands: [
        "bash scripts/install-tatwo-ultrawork.sh --preflight",
        "tatwo-ultrawork host preflight --json",
        "node scripts/tatwo-host-preflight.mjs --json",
        "node scripts/tatwo-host-sandbox-rehearsal.mjs --json",
        "node scripts/tatwo-host-backup-plan.mjs --dry-run --json",
        "tatwo-ultrawork host receipt-flow --json",
        "node scripts/tatwo-host-rollback-plan.mjs --json",
        "node scripts/tatwo-host-same-thread-smoke.mjs --json",
        "node scripts/tatwo-host-mcp-registration-smoke.mjs --json",
        "tatwo-ultrawork host install-gate --json",
        "bash scripts/tatwo-ultrawork-sandbox-check.sh",
        "swift run tatwo-ultrawork doctor --json",
      ],
      backupTargets: [
        "Codex config.toml",
        "Codex state database/cache",
        "model gateway config/cache",
        "Tatwo Ultrawork app data",
      ],
      dependencies: [
        InstallDependency(
          id: "codex-cli", name: "Codex CLI/App", kind: .app, required: true,
          detection: "command -v codex / app bundle exists", prompt: "安裝或確認 Codex App/CLI？",
          defaultAction: .manual),
        InstallDependency(
          id: "node", name: "Node.js", kind: .localRuntime, required: true,
          detection: "command -v node", prompt: "MCP 與 gateway smoke 需要 Node，是否安裝？",
          defaultAction: .manual),
        InstallDependency(
          id: "swift", name: "Swift toolchain", kind: .localRuntime, required: true,
          detection: "swift --version", prompt: "建置 macOS app/CLI 需要 Swift，是否安裝 Xcode/CLT？",
          defaultAction: .manual),
        InstallDependency(
          id: "codex-app-model-gateway", name: "model-gateway", kind: .localRuntime,
          required: false, detection: "gateway health/post-update-check",
          prompt: "是否接入同 thread 多模型 gateway？", defaultAction: .later),
        InstallDependency(
          id: "open-ultrawork", name: "open-ultrawork skill", kind: .skill, required: false,
          detection: "skill path/selftest", prompt: "是否啟用 S/M/L/XL 協作規則？", defaultAction: .later),
        InstallDependency(
          id: "colima-sandbox-runner", name: "Colima sandbox runner", kind: .localRuntime,
          required: false, detection: "tatwo-ultrawork colima preflight --json",
          prompt: "是否把 Colima 作為 L/XL 可選隔離驗證器？不會自動安裝或啟動。", defaultAction: .later),
        InstallDependency(
          id: "chatgpt-pro-mcp", name: "ChatGPT Pro MCP", kind: .mcp, required: true,
          detection: "ChatGPT Pro MCP plugin/MCP status + bridge health",
          prompt: "完整 TATWO 必須安裝/連接 ChatGPT Pro MCP 作為 Pro 研究/審稿 lane；是否現在設定？",
          defaultAction: .manual),
        InstallDependency(
          id: "gitnexus", name: "GitNexus", kind: .plugin, required: false,
          detection: "plugin installed", prompt: "是否啟用專案地圖/影響範圍工具？", defaultAction: .skip),
      ],
      smokeCommands: [
        "tatwo-ultrawork doctor --json",
        "tatwo-ultrawork workflow preview --mode XL --scenario code --json",
        "tatwo-ultrawork workflow run --mode XL --scenario code --objective smoke --dry-run --json",
        "tatwo-ultrawork colima preflight --json",
        "tatwo-ultrawork colima run --mode XL --scenario code --objective smoke --dry-run --json",
        "tatwo-ultrawork host install-gate --json",
        "node scripts/tatwo-host-readiness-gate.mjs --latest",
        "node scripts/tatwo-host-receipt-bundle.mjs --latest",
        "node scripts/tatwo-host-sandbox-rehearsal.mjs --json",
        "MODEL_GATEWAY_DIR=<gateway-dir> bash <gateway-dir>/scripts/post-update-check.sh --full",
        "gateway same-thread smoke if gateway is enabled",
        "open-ultrawork selftest if skill is enabled",
      ],
      rollbackPlan: [
        "停止新的 host mutation",
        "還原 Codex config/state/cache 備份",
        "停用 Tatwo MCP entry 或 gateway route",
        "重新跑 doctor 與 smoke 確認回復",
      ]
    )
  }

  private static func steps(for mode: WorkMode, scenario: ScenarioID, dryRunOnly: Bool)
    -> [WorkflowRunStep]
  {
    [
      WorkflowRunStep(
        id: "define", title: "定義任務與完成標準", ownerRole: "Human + GPT controller", status: .ready,
        allowedHostMutation: false, requiredEvidence: [.cliOutput],
        doneCondition: "目標、禁止事項、驗收方式都寫入 plan"),
      WorkflowRunStep(
        id: "project-map", title: "GitNexus 專案地圖 / 影響範圍", ownerRole: "GitNexus + Codex",
        status: mode.mode >= .m ? .ready : .blocked, allowedHostMutation: false,
        requiredEvidence: [.cliOutput],
        doneCondition: "M/L/XL 啟動時固定調用一次 GitNexus，留下入口與影響範圍收據；S 小修可跳過"),
      WorkflowRunStep(
        id: "sandbox", title: "建立沙盒", ownerRole: "Codex executor + optional Colima runner",
        status: mode.requiresSandbox ? .ready : .pending, allowedHostMutation: false,
        requiredEvidence: [.sandboxRun, .cliOutput],
        doneCondition:
          "臨時 workspace/app data/測試 port 可重現；L/XL 可加 Colima 可選驗證，但缺少時只降級，且未碰 host config"),
      WorkflowRunStep(
        id: "scout", title: "分派 scout/reviewer", ownerRole: "MiniMax / Grok / Claude",
        status: mode.maxHelpers > 0 ? .pending : .blocked, allowedHostMutation: false,
        requiredEvidence: [.cliOutput], doneCondition: "只產出候選、反例、patch intent，不直接寫檔"),
      WorkflowRunStep(
        id: "build", title: "Codex 落地修改", ownerRole: "Codex executor", status: .pending,
        allowedHostMutation: false, requiredEvidence: [.build, .cliOutput],
        doneCondition: "所有檔案修改都能被 diff 與測試追蹤；主機實裝仍需獨立人工 gate"),
      WorkflowRunStep(
        id: "review", title: "獨立審稿", ownerRole: "Reviewer",
        status: mode.requiresIndependentVerification ? .pending : .blocked,
        allowedHostMutation: false, requiredEvidence: [.cliOutput],
        doneCondition: "Reviewer 只能提問題，不可 final pass"),
      WorkflowRunStep(
        id: "verify", title: "證據驗證", ownerRole: "Verifier", status: .pending,
        allowedHostMutation: false,
        requiredEvidence: scenario == .design
          ? [.build, .screenshot, .visualDiff] : [.build, .cliOutput],
        doneCondition: "測試/截圖/hash/收據存在且能重跑"),
      WorkflowRunStep(
        id: "judge", title: "裁決 gate", ownerRole: "Judge", status: .pending,
        allowedHostMutation: false, requiredEvidence: [.cliOutput],
        doneCondition: "P0/P1 與 blocking finding 全部解決或明確風險接受"),
      WorkflowRunStep(
        id: "host-install", title: "主機實裝", ownerRole: "Human + Codex", status: .manualGate,
        allowedHostMutation: false, requiredEvidence: [.cliOutput, .redactionScan],
        doneCondition:
          "備份完成、readiness gate 通過、live same-thread smoke 與 MCP 註冊 smoke 都有收據、人類授權後才可動 host"),
      WorkflowRunStep(
        id: "receipt", title: "收據與 safe memory", ownerRole: "Tatwo Ultrawork", status: .pending,
        allowedHostMutation: false, requiredEvidence: [.cliOutput],
        doneCondition: "只保存安全摘要與 failure mode，不保存 raw/private content"),
    ]
  }

  private static func gates(for mode: WorkMode, scenario: ScenarioID) -> [WorkflowGate] {
    var gates = [
      WorkflowGate(
        id: "budget", title: "預算/輪次 gate",
        failClosedReason: "超過 \(mode.maxRounds) 輪或 \(mode.maxHelpers) helpers 就停",
        requiredBeforePass: [
          "budget receipt", "helper count <= \(mode.maxHelpers)",
          "round count <= \(mode.maxRounds)",
        ]),
      WorkflowGate(
        id: "roles", title: "分工 gate",
        failClosedReason: "Builder/Reviewer/Verifier/Judge 不能同一角色自我放行",
        requiredBeforePass: [
          "distinct role receipts", "reviewer cannot final pass", "judge decision",
        ]),
      WorkflowGate(
        id: "project-map", title: "GitNexus M+ 入口/影響範圍 gate",
        failClosedReason: mode.mode >= .m ? "M/L/XL 需要 GitNexus 專案地圖收據後才分派協作" : "S 小修可不跑 GitNexus",
        requiredBeforePass: mode.mode >= .m
          ? ["GitNexus project-map receipt", "entrypoints / impact range noted"]
          : ["S mode may skip GitNexus"]),
      WorkflowGate(
        id: "sandbox", title: "沙盒 gate",
        failClosedReason: mode.requiresSandbox ? "XL 必須沙盒先過" : "高風險改動需要隔離證據",
        requiredBeforePass: [
          "sandbox preflight", "no host config mutation",
          "Colima optional verifier preflight for L/XL or explicit degraded receipt",
        ]),
    ]
    if scenario == .design {
      gates.append(
        WorkflowGate(
          id: "visual", title: "UI/UX 視覺 gate", failClosedReason: "build pass 不等於 UI pass",
          requiredBeforePass: ["screenshot or recording", "sha256 hash", "visual checklist"]))
    }
    if scenario == .trading {
      gates.append(
        WorkflowGate(
          id: "trading-risk", title: "交易風控 gate", failClosedReason: "涉及資金/下單/槓桿/停損必須額外人工風控",
          requiredBeforePass: [
            "read-only proof", "no order mutation", "human risk approval if live",
          ]))
    }
    gates.append(
      WorkflowGate(
        id: "host-install",
        title: "主機實裝 gate",
        failClosedReason: "workflow run 不能自動放行主機實裝",
        requiredBeforePass: [
          "host sandbox rehearsal receipt",
          "human approval receipt",
          "host backup receipt",
          "live same-thread smoke receipt",
          "host MCP registration smoke receipt",
        ]
      ))
    return gates
  }

  private static func stablePlanID(objective: String, mode: WorkModeID, scenario: ScenarioID)
    -> String
  {
    let prefix = "tatwo-\(mode.rawValue.lowercased())-\(scenario.rawValue)"
    let digest = sha256Hex(Data("\(objective)\n\(mode.rawValue)\n\(scenario.rawValue)".utf8))
      .prefix(12)
    return "\(prefix)-\(digest)"
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

  private static func fallbackMode(_ mode: WorkModeID) -> WorkMode {
    WorkMode(
      mode: mode,
      englishName: mode.rawValue,
      chineseName: "\(mode.rawValue) fallback",
      plainDescription: "Fallback mode used only when a custom catalog is empty.",
      maxHelpers: 0,
      maxRounds: 1,
      requiresSandbox: mode >= .xl,
      requiresHumanApproval: true,
      requiresIndependentVerification: mode != .s,
      defaultBudget: WorkModeBudget(
        tokenRangeLabel: "未設定", helperLimitLabel: "0 helper", roundLimitLabel: "1 輪",
        requiresBudgetReceipt: true),
      roleAssignments: [
        ModelRoleAssignment(
          id: "fallback-controller",
          model: "gpt-controller",
          role: "主控",
          weight: 1.0,
          responsibility: "Fallback controller for empty custom catalogs.",
          defaultAuthority: .toolIntentBridge
        )
      ],
      stopRules: ["custom catalog empty; fail closed and avoid host mutation"]
    )
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
