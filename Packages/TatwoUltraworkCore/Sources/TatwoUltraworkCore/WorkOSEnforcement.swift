import Foundation

public enum WorkOSActionMutation: String, Codable, Sendable, CaseIterable, Equatable {
  case readOnly = "read_only"
  case submitReceipt = "submit_receipt"
  case runSandbox = "run_sandbox"
  case writeFiles = "write_files"
  case hostMutation = "host_mutation"
  case promoteRunState = "promote_run_state"
}

public enum WorkOSActionSurface: String, Codable, Sendable, CaseIterable, Equatable {
  case cli
  case mcp
  case appVisualizer = "app_visualizer"
  case appControl = "app_control"
  case gateway
  case agent
}

public struct WorkOSAgentActionIntent: Codable, Sendable, Equatable {
  public let contractID: String?
  public let identity: IdentityKind
  public let toolName: String
  public let requestedMutation: WorkOSActionMutation
  public let sourceSurface: WorkOSActionSurface
  public let receiptID: String?

  public init(
    contractID: String?,
    identity: IdentityKind,
    toolName: String,
    requestedMutation: WorkOSActionMutation = .readOnly,
    sourceSurface: WorkOSActionSurface = .agent,
    receiptID: String? = nil
  ) {
    self.contractID = contractID.map { TatwoPrivacyRedactor.redacted($0) }
    self.identity = identity
    self.toolName = TatwoPrivacyRedactor.redacted(toolName.trimmingCharacters(in: .whitespacesAndNewlines))
    self.requestedMutation = requestedMutation
    self.sourceSurface = sourceSurface
    self.receiptID = receiptID.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct WorkOSEnforcementDecision: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let code: String
  public let message: String
  public let contractID: String?
  public let toolName: String
  public let sourceSurface: WorkOSActionSurface
  public let allowedNextTools: [String]
  public let requiredReceipts: [String]
  public let canMutateHost: Bool
  public let canPromoteRunState: Bool
  public let warnings: [String]

  public init(
    schema: String = "TatwoWorkOSEnforcementDecisionV1",
    ok: Bool,
    code: String,
    message: String,
    contractID: String?,
    toolName: String,
    sourceSurface: WorkOSActionSurface,
    allowedNextTools: [String],
    requiredReceipts: [String],
    canMutateHost: Bool,
    canPromoteRunState: Bool,
    warnings: [String] = []
  ) {
    self.schema = schema
    self.ok = ok
    self.code = code
    self.message = TatwoPrivacyRedactor.redacted(message)
    self.contractID = contractID.map { TatwoPrivacyRedactor.redacted($0) }
    self.toolName = TatwoPrivacyRedactor.redacted(toolName)
    self.sourceSurface = sourceSurface
    self.allowedNextTools = allowedNextTools.map { TatwoPrivacyRedactor.redacted($0) }
    self.requiredReceipts = requiredReceipts.map { TatwoPrivacyRedactor.redacted($0) }
    self.canMutateHost = canMutateHost
    self.canPromoteRunState = canPromoteRunState
    self.warnings = warnings.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct TatwoWorkOSConstitution: Codable, Sendable, Equatable {
  public let schema: String
  public let agentsMD: String
  public let toolsMD: String
  public let receiptsMD: String
  public let hardRules: [String]
  public let registeredTools: [String]

  public init(
    schema: String = "TatwoWorkOSConstitutionV1",
    agentsMD: String,
    toolsMD: String,
    receiptsMD: String,
    hardRules: [String],
    registeredTools: [String]
  ) {
    self.schema = schema
    self.agentsMD = TatwoPrivacyRedactor.redacted(agentsMD)
    self.toolsMD = TatwoPrivacyRedactor.redacted(toolsMD)
    self.receiptsMD = TatwoPrivacyRedactor.redacted(receiptsMD)
    self.hardRules = hardRules.map { TatwoPrivacyRedactor.redacted($0) }
    self.registeredTools = registeredTools.map { TatwoPrivacyRedactor.redacted($0) }
  }
}

public struct TatwoWorkOSHandoffPack: Codable, Sendable, Equatable {
  public let schema: String
  public let goalID: String
  public let contractID: String
  public let mode: WorkModeID
  public let scenario: String
  public let identityBindings: [TatwoWorkOSDashboardIdentitySlot]
  public let dashboard: TatwoWorkOSDashboardSnapshot
  public let constitution: TatwoWorkOSConstitution
  public let allowedNextTools: [String]
  public let firstAction: String
  public let forbiddenActions: [String]
  public let agentsMD: String
  public let toolsMD: String
  public let receiptsMD: String

  public init(
    schema: String = "TatwoWorkOSHandoffPackV1",
    goalID: String,
    contractID: String,
    mode: WorkModeID,
    scenario: String,
    identityBindings: [TatwoWorkOSDashboardIdentitySlot],
    dashboard: TatwoWorkOSDashboardSnapshot,
    constitution: TatwoWorkOSConstitution,
    allowedNextTools: [String],
    firstAction: String,
    forbiddenActions: [String],
    agentsMD: String,
    toolsMD: String,
    receiptsMD: String
  ) {
    self.schema = schema
    self.goalID = TatwoPrivacyRedactor.redacted(goalID)
    self.contractID = TatwoPrivacyRedactor.redacted(contractID)
    self.mode = mode
    self.scenario = TatwoPrivacyRedactor.redacted(scenario)
    self.identityBindings = identityBindings
    self.dashboard = dashboard
    self.constitution = constitution
    self.allowedNextTools = allowedNextTools.map { TatwoPrivacyRedactor.redacted($0) }
    self.firstAction = TatwoPrivacyRedactor.redacted(firstAction)
    self.forbiddenActions = forbiddenActions.map { TatwoPrivacyRedactor.redacted($0) }
    self.agentsMD = TatwoPrivacyRedactor.redacted(agentsMD)
    self.toolsMD = TatwoPrivacyRedactor.redacted(toolsMD)
    self.receiptsMD = TatwoPrivacyRedactor.redacted(receiptsMD)
  }
}

public enum WorkOSEnforcementFactory {
  public static func constitution(contract: TatwoWorkOSContractV1? = nil) -> TatwoWorkOSConstitution {
    let tools = contract.map(TatwoWorkOSDashboardFactory.normalizedAllowedTools) ?? defaultRegisteredTools
    let hardRules = [
      "沒有 contractID，一律 fail closed。",
      "App / dashboard / visualizer 只能顯示，不可直接 pass goal。",
      "模型文字與自評不是 receipt。",
      "工具只能從 Ultrawork registry / contract allowedTools 選用。",
      "host mutation 預設關閉；sandbox、backup、rollback、人類授權缺一不可升 active。",
      "正式工作 goal 不限制次數；沙盒評分才限制最多 5 次 execution cycles，封存後直接評分。",
      "fan-out goal 必須有 dispatch-liveness 與 supervision-patrol 收據；未監控派工不得報 running。",
      "codex exec / background dispatch 必須使用 < /dev/null 關 stdin、約 2 分鐘起跑確認、10 分鐘 stall watchdog。",
      "goal tracker 是 OS activation 動作；缺可視 tracker 證據時 tatwo.os.next 回 goal_tracker_missing。",
      "scope drift 必須即時裁決記錄 allow-with-note 或 reject-and-redo；未裁決 drift 阻擋 pass。",
      "刪除永遠先封存到 macOS Trash 並附來源/復原/可刪理由 Markdown；永久刪除必須換人複審。",
      "Chat UI 不放無意義說明；功能必須整齊收納在模型/權限/工具/收據等夾層，不能四散或裝飾化。",
      "Chat/Codex-App-style UI pass 必須用同 run 目前 Codex App baseline，且 Codex verifier 與當次 identity contract 綁定的獨立 reviewer 同意一致；Tatwo-only 差異要有使用者要求來源。",
    ]
    let agents = """
    # AGENTS.md - TATWO Work OS
    1. 先呼叫 tatwo.os.begin 取得 GoalRun 與 contractID。
    2. 每個 action 都要帶 contractID；缺少就停止。
    3. 身份組先於模型：lead / supervisor / consultant / sub / news / verifier。
    4. domain loops 只提交 receipts 回 mainline，不自行實裝主機。
    5. Codex host 擁有檔案與 shell；外部模型是 advisory / review / research。
    6. 背景派工必須 codex exec ... < /dev/null、2 分鐘起跑確認、10 分鐘卡死看門狗。
    7. 有派工就要約 10 分鐘 supervision patrol，巡檢 process/output/files/scope drift。
    8. 刪除必須先 trash 封存並附 Markdown；另一位 reviewer 才能批准永久移除。
    9. UI 元件必須有真實用途與資料來源；Chat 分頁還原 Codex App 時要邊做邊截圖校正。
    10. Chat/Codex-App-style UI 驗收需同 run 的目前 Codex App baseline + Tatwo candidate + Codex verifier + 當次 identity contract 綁定的獨立 reviewer parity receipt。
    """
    let toolsMD = """
    # TOOLS.md - TATWO Work OS
    允許工具由 contract.allowedTools 決定。未登記 MCP/skill 不得算有效 receipt。
    常用入口：tatwo.os.next、tatwo.os.loop.status、tatwo.os.receipt.submit、tatwo.os.goal.close、tatwo.os.dashboard、tatwo.os.enforce、tatwo.os.handoff。
    """
    let receiptsMD = """
    # RECEIPTS.md - TATWO Work OS
    pass 前必須有 contract、mode budget、scope、identity、sandbox/staging、test/smoke、UI screenshot 或 domain evidence、rollback、人類 gate（若 XL）等 receipts。
    fan-out goal 必須額外有 dispatch-liveness（stdin closed + startup confirmed + 10-minute watchdog）與 supervision-patrol（process liveness / output growth / changed-file count / scope drift + adjudication）收據。
    UI/UJ 缺截圖或互動證據時，不得宣稱完成；Chat/Codex-App-style UI 另需 codex-app-parity receipt。
    cleanup / deletion receipts 必須包含 Trash 封存位置、來源、復原方式、可刪理由與獨立複審狀態。
    """
    return TatwoWorkOSConstitution(
      agentsMD: agents,
      toolsMD: toolsMD,
      receiptsMD: receiptsMD,
      hardRules: hardRules,
      registeredTools: tools)
  }

  public static func enforce(
    _ intent: WorkOSAgentActionIntent,
    contract: TatwoWorkOSContractV1?
  ) -> WorkOSEnforcementDecision {
    let normalizedContractID = intent.contractID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let allowedTools = contract.map(TatwoWorkOSDashboardFactory.normalizedAllowedTools) ?? defaultRegisteredTools
    let requiredReceipts = contract?.receiptRequirements.filter(\.requiredForPass).map(\.id) ?? []

    guard !normalizedContractID.isEmpty else {
      return decision(
        ok: false,
        code: "missing_contract_id",
        message: "缺 contractID：agent 不可自行猜流程或呼叫工具。",
        intent: intent,
        allowedTools: allowedTools,
        requiredReceipts: requiredReceipts,
        canMutateHost: false,
        canPromoteRunState: false)
    }

    if let contract, normalizedContractID != contract.contractID {
      return decision(
        ok: false,
        code: "contract_mismatch",
        message: "contractID 與目前 Work OS contract 不一致，拒絕執行。",
        intent: intent,
        allowedTools: allowedTools,
        requiredReceipts: requiredReceipts,
        canMutateHost: false,
        canPromoteRunState: false)
    }

    if intent.sourceSurface == .appVisualizer && intent.requestedMutation == .promoteRunState {
      return decision(
        ok: false,
        code: "visualizer_cannot_promote",
        message: "Dashboard / App visualizer 只能顯示 READY/ROLLBACK，不能直接 pass goal。",
        intent: intent,
        allowedTools: allowedTools,
        requiredReceipts: requiredReceipts,
        canMutateHost: false,
        canPromoteRunState: false)
    }

    if [.writeFiles, .hostMutation].contains(intent.requestedMutation), contract?.sandboxPolicy.hostMutationAllowed != true {
      return decision(
        ok: false,
        code: "host_mutation_denied",
        message: "目前 contract 未授權 host mutation；必須留在 sandbox/staging。",
        intent: intent,
        allowedTools: allowedTools,
        requiredReceipts: requiredReceipts,
        canMutateHost: false,
        canPromoteRunState: false)
    }

    let tool = intent.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tool.isEmpty && !allowedTools.contains(tool) {
      return decision(
        ok: false,
        code: "unregistered_or_disallowed_tool",
        message: "工具未列入目前 contract / Ultrawork registry：\(tool)。",
        intent: intent,
        allowedTools: allowedTools,
        requiredReceipts: requiredReceipts,
        canMutateHost: contract?.sandboxPolicy.hostMutationAllowed == true,
        canPromoteRunState: false,
        warnings: ["如果需要新 MCP/skill，先加入 Ultrawork registry 並通過 sandbox selftest。"])
    }

    if intent.requestedMutation == .submitReceipt,
      (intent.receiptID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return decision(
        ok: false,
        code: "missing_receipt_id",
        message: "提交 receipt 時必須帶 receiptID。",
        intent: intent,
        allowedTools: allowedTools,
        requiredReceipts: requiredReceipts,
        canMutateHost: false,
        canPromoteRunState: false)
    }

    return decision(
      ok: true,
      code: "os_action_allowed",
      message: "Action 已通過 Work OS enforcement；仍需依 next action 與 receipts 執行。",
      intent: intent,
      allowedTools: allowedTools,
      requiredReceipts: requiredReceipts,
      canMutateHost: contract?.sandboxPolicy.hostMutationAllowed == true,
      canPromoteRunState: false,
      warnings: contract?.sandboxPolicy.humanGateRequired == true ? ["此模式需要 human gate；READY 不是自動 promotion。"] : [])
  }

  public static func handoffPack(contract: TatwoWorkOSContractV1) -> TatwoWorkOSHandoffPack {
    let dashboard = TatwoWorkOSDashboardFactory.make(contract: contract)
    let constitution = constitution(contract: contract)
    let allowedTools = TatwoWorkOSDashboardFactory.normalizedAllowedTools(contract)
    return TatwoWorkOSHandoffPack(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      identityBindings: dashboard.identitySlots,
      dashboard: dashboard,
      constitution: constitution,
      allowedNextTools: allowedTools,
      firstAction: "呼叫 tatwo.os.next 並帶 contractID；不要 naked tool call。",
      forbiddenActions: [
        "缺 contractID 的工具呼叫",
        "App visualizer 直接 pass / promote",
        "未登記 MCP/skill 當作有效 receipt",
        "未授權 host mutation / signed App patch / LaunchAgent 寫入",
        "模型自評當通過證據",
        "codex exec 未 < /dev/null 關 stdin 或未設 2 分鐘起跑確認 / 10 分鐘卡死看門狗",
        "有派工但缺 supervision-patrol 或 scope drift 裁決記錄",
      ],
      agentsMD: constitution.agentsMD,
      toolsMD: constitution.toolsMD,
      receiptsMD: constitution.receiptsMD)
  }

  private static func decision(
    ok: Bool,
    code: String,
    message: String,
    intent: WorkOSAgentActionIntent,
    allowedTools: [String],
    requiredReceipts: [String],
    canMutateHost: Bool,
    canPromoteRunState: Bool,
    warnings: [String] = []
  ) -> WorkOSEnforcementDecision {
    WorkOSEnforcementDecision(
      ok: ok,
      code: code,
      message: message,
      contractID: intent.contractID,
      toolName: intent.toolName,
      sourceSurface: intent.sourceSurface,
      allowedNextTools: allowedTools,
      requiredReceipts: requiredReceipts,
      canMutateHost: canMutateHost,
      canPromoteRunState: canPromoteRunState,
      warnings: warnings)
  }

  private static let defaultRegisteredTools: [String] = [
    "tatwo.os.begin",
    "tatwo.os.next",
    "tatwo.os.loop.status",
    "tatwo.os.receipt.submit",
    "tatwo.os.goal.close",
    "tatwo.os.dashboard",
    "tatwo.os.enforce",
    "tatwo.os.handoff",
    "tatwo.os.constitution",
    "tatwo.scenario.workflow",
    "tatwo.workflow.preview",
    "tatwo.web_check.plan",
    "tatwo.web_check.import_receipt",
    "tatwo.web_arena.plan",
    "tatwo.sandbox_arena.plan",
    "tatwo.arena.plan_loop_goal.policy",
    "tatwo.arena.plan_loop_goal.score",
    "multi_agent_v1.send_input",
    "multi_agent_v1.wait_agent",
    "multi_agent_v1.resume_agent",
    "multi_agent_v1.close_agent",
    "computer-use",
    "tatwo.gateway.dispatch",
    "tatwo.gateway.fanout",
  ]
}
