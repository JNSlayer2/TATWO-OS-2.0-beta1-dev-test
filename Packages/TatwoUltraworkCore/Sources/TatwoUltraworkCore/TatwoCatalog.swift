import Foundation

public enum WorkModeID: String, Codable, Sendable, CaseIterable, Comparable {
  case s = "S"
  case m = "M"
  case l = "L"
  case xl = "XL"
  case xxl = "XXL"

  public static func < (lhs: WorkModeID, rhs: WorkModeID) -> Bool {
    // 注意：新增 case 時務必同步此 order 陣列，否則 firstIndex! 會 crash。
    let order: [WorkModeID] = [.s, .m, .l, .xl, .xxl]
    return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
  }
}

public struct WorkModeBudget: Codable, Sendable, Equatable {
  public let tokenRangeLabel: String
  public let helperLimitLabel: String
  public let roundLimitLabel: String
  public let requiresBudgetReceipt: Bool

  public init(
    tokenRangeLabel: String, helperLimitLabel: String, roundLimitLabel: String,
    requiresBudgetReceipt: Bool
  ) {
    self.tokenRangeLabel = tokenRangeLabel
    self.helperLimitLabel = helperLimitLabel
    self.roundLimitLabel = roundLimitLabel
    self.requiresBudgetReceipt = requiresBudgetReceipt
  }
}

public struct ModelRoleAssignment: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let model: String
  public let role: String
  public let weight: Double
  public let responsibility: String
  public let defaultAuthority: AuthorityMode

  public init(
    id: String, model: String, role: String, weight: Double, responsibility: String,
    defaultAuthority: AuthorityMode
  ) {
    self.id = id
    self.model = model
    self.role = role
    self.weight = weight
    self.responsibility = responsibility
    self.defaultAuthority = defaultAuthority
  }
}

public enum AuthorityMode: String, Codable, Sendable, CaseIterable {
  case brainOnly = "brain_only"
  case patchProposal = "patch_proposal"
  case toolIntentBridge = "tool_intent_bridge"
  case sandboxExecutor = "sandbox_executor"
  case nativePeerExecutor = "native_peer_executor"
  case researchBridge = "research_ui_bridge"
}

public struct WorkMode: Codable, Sendable, Identifiable, Equatable {
  public var id: WorkModeID { mode }
  public let mode: WorkModeID
  public let englishName: String
  public let chineseName: String
  public let plainDescription: String
  public let maxHelpers: Int
  public let maxRounds: Int
  public let requiresSandbox: Bool
  public let requiresHumanApproval: Bool
  public let requiresIndependentVerification: Bool
  public let defaultBudget: WorkModeBudget
  public let roleAssignments: [ModelRoleAssignment]
  public let stopRules: [String]

  public init(
    mode: WorkModeID,
    englishName: String,
    chineseName: String,
    plainDescription: String,
    maxHelpers: Int,
    maxRounds: Int,
    requiresSandbox: Bool,
    requiresHumanApproval: Bool,
    requiresIndependentVerification: Bool,
    defaultBudget: WorkModeBudget,
    roleAssignments: [ModelRoleAssignment],
    stopRules: [String]
  ) {
    self.mode = mode
    self.englishName = englishName
    self.chineseName = chineseName
    self.plainDescription = plainDescription
    self.maxHelpers = maxHelpers
    self.maxRounds = maxRounds
    self.requiresSandbox = requiresSandbox
    self.requiresHumanApproval = requiresHumanApproval
    self.requiresIndependentVerification = requiresIndependentVerification
    self.defaultBudget = defaultBudget
    self.roleAssignments = roleAssignments
    self.stopRules = stopRules
  }
}

public enum ScenarioID: String, Codable, Sendable, CaseIterable {
  case daily
  case design
  case coding
  case trading
  case modeling
}

public struct Scenario: Codable, Sendable, Identifiable, Equatable {
  public var id: ScenarioID { scenario }
  public let scenario: ScenarioID
  public let chineseName: String
  public let plainDescription: String
  public let roleWeights: [ModelRoleAssignment]
  public let defaultMode: WorkModeID
  public let readOnlyByDefault: Bool
  public let guardrails: [String]

  public init(
    scenario: ScenarioID,
    chineseName: String,
    plainDescription: String,
    roleWeights: [ModelRoleAssignment],
    defaultMode: WorkModeID,
    readOnlyByDefault: Bool,
    guardrails: [String]
  ) {
    self.scenario = scenario
    self.chineseName = chineseName
    self.plainDescription = plainDescription
    self.roleWeights = roleWeights
    self.defaultMode = defaultMode
    self.readOnlyByDefault = readOnlyByDefault
    self.guardrails = guardrails
  }
}

public struct ModelCompatibility: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let primaryModel: String
  public let companionModel: String
  public let score: Int
  public let goodFor: [String]
  public let weakFor: [String]
  public let plainNotes: String

  public init(
    id: String, primaryModel: String, companionModel: String, score: Int, goodFor: [String],
    weakFor: [String], plainNotes: String
  ) {
    self.id = id
    self.primaryModel = primaryModel
    self.companionModel = companionModel
    self.score = min(5, max(1, score))
    self.goodFor = goodFor
    self.weakFor = weakFor
    self.plainNotes = plainNotes
  }
}

public enum RegistryKind: String, Codable, Sendable, CaseIterable {
  case plugin
  case skill
  case mcp
  case app
  case localRuntime = "local_runtime"
}

public enum SafetyLevel: String, Codable, Sendable, CaseIterable, Comparable {
  case low
  case medium
  case high
  case critical

  public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
    let order: [SafetyLevel] = [.low, .medium, .high, .critical]
    return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
  }
}

public enum InstallState: String, Codable, Sendable, CaseIterable {
  case installed
  case missing
  case skipped
  case unknown
}

public struct PluginRegistryEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public let kind: RegistryKind
  public let purpose: String
  public let path: String?
  public let trigger: String
  public let safetyLevel: SafetyLevel
  public let requiredForModes: [WorkModeID]
  public let installState: InstallState
  public let smokeCommand: String?
  public let publicInstallHint: String

  public init(
    id: String,
    name: String,
    kind: RegistryKind,
    purpose: String,
    path: String? = nil,
    trigger: String,
    safetyLevel: SafetyLevel,
    requiredForModes: [WorkModeID],
    installState: InstallState = .unknown,
    smokeCommand: String? = nil,
    publicInstallHint: String
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.purpose = purpose
    self.path = path
    self.trigger = trigger
    self.safetyLevel = safetyLevel
    self.requiredForModes = requiredForModes
    self.installState = installState
    self.smokeCommand = smokeCommand
    self.publicInstallHint = publicInstallHint
  }
}

public enum WorkflowNodeKind: String, Codable, Sendable, CaseIterable {
  case userTask = "user_task"
  case projectMap = "project_map"
  case sandbox
  case scout
  case builder
  case reviewer
  case verifier
  case judge
  case tests
  case rollback
  case hostInstall = "host_install"
  case receipt
}

public struct WorkflowNode: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let kind: WorkflowNodeKind
  public let ownerRole: String
  public let plainDescription: String
  public let mustProduceEvidence: Bool

  public init(
    id: String, title: String, kind: WorkflowNodeKind, ownerRole: String, plainDescription: String,
    mustProduceEvidence: Bool
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.ownerRole = ownerRole
    self.plainDescription = plainDescription
    self.mustProduceEvidence = mustProduceEvidence
  }
}

public struct WorkflowEdge: Codable, Sendable, Identifiable, Equatable {
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

public struct WorkflowTemplate: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let mode: WorkModeID
  public let scenario: ScenarioID
  public let title: String
  public let nodes: [WorkflowNode]
  public let edges: [WorkflowEdge]
  public let hostMutationPolicy: String

  public init(
    id: String, mode: WorkModeID, scenario: ScenarioID, title: String, nodes: [WorkflowNode],
    edges: [WorkflowEdge], hostMutationPolicy: String
  ) {
    self.id = id
    self.mode = mode
    self.scenario = scenario
    self.title = title
    self.nodes = nodes
    self.edges = edges
    self.hostMutationPolicy = hostMutationPolicy
  }
}

public struct UsageProviderStatus: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let displayName: String
  public let status: InstallState
  public let cachePolicy: String
  public let liveRefreshPolicy: String
  public let quotaLabel: String

  public init(
    id: String, displayName: String, status: InstallState, cachePolicy: String,
    liveRefreshPolicy: String, quotaLabel: String
  ) {
    self.id = id
    self.displayName = displayName
    self.status = status
    self.cachePolicy = cachePolicy
    self.liveRefreshPolicy = liveRefreshPolicy
    self.quotaLabel = quotaLabel
  }
}

public struct TatwoCatalog: Codable, Sendable, Equatable {
  public let usageProviders: [UsageProviderStatus]
  public let workModes: [WorkMode]
  public let scenarios: [Scenario]
  public let compatibility: [ModelCompatibility]
  public let plugins: [PluginRegistryEntry]

  public init(
    usageProviders: [UsageProviderStatus], workModes: [WorkMode], scenarios: [Scenario],
    compatibility: [ModelCompatibility], plugins: [PluginRegistryEntry]
  ) {
    self.usageProviders = usageProviders
    self.workModes = workModes.sorted { $0.mode < $1.mode }
    self.scenarios = scenarios
    self.compatibility = compatibility
    self.plugins = plugins
  }

  public static let defaults = TatwoCatalog(
    usageProviders: [
      UsageProviderStatus(
        id: "codex-gpt", displayName: "Codex / GPT", status: .unknown, cachePolicy: "先顯示本地 cache",
        liveRefreshPolicy: "使用者按重新整理才打 live source", quotaLabel: "依 Codex App / CLI 回報"),
      UsageProviderStatus(
        id: "claude", displayName: "Claude", status: .unknown, cachePolicy: "只顯示上次健康收據",
        liveRefreshPolicy: "透過 gateway/CLI smoke 更新", quotaLabel: "不讀 token，只顯示可用/需登入"),
      UsageProviderStatus(
        id: "grok", displayName: "Grok", status: .unknown, cachePolicy: "保留最後一次查消息能力狀態",
        liveRefreshPolicy: "OAuth/CLI 可用時再刷新", quotaLabel: "消息查找與反例 lane"),
      UsageProviderStatus(
        id: "minimax", displayName: "MiniMax", status: .unknown, cachePolicy: "保留低成本探索 lane 狀態",
        liveRefreshPolicy: "只在確認低風險額度池後啟用", quotaLabel: "大量草稿/掃描 lane"),
      UsageProviderStatus(
        id: "local-api", displayName: "API / 本地模型", status: .unknown,
        cachePolicy: "只保存 endpoint 類型，不保存 key", liveRefreshPolicy: "本地或使用者批准才跑",
        quotaLabel: "local / allowlisted only"),
    ],
    workModes: Defaults.workModes,
    scenarios: Defaults.scenarios,
    compatibility: Defaults.compatibility,
    plugins: Defaults.plugins
  )

  public func mode(_ id: WorkModeID) -> WorkMode? { workModes.first { $0.mode == id } }
  public func scenario(_ id: ScenarioID) -> Scenario? { scenarios.first { $0.scenario == id } }

  public func replacingPlugins(_ plugins: [PluginRegistryEntry]) -> TatwoCatalog {
    TatwoCatalog(
      usageProviders: usageProviders,
      workModes: workModes,
      scenarios: scenarios,
      compatibility: compatibility,
      plugins: plugins)
  }
}

private enum Defaults {
  static let controller = ModelRoleAssignment(
    id: "gpt-controller", model: "gpt-5.5", role: "主控 / 收斂", weight: 0.45,
    responsibility: "定義任務、套用 patch、跑測試、把結論講清楚", defaultAuthority: .toolIntentBridge)
  static let minimaxScout = ModelRoleAssignment(
    id: "minimax-scout", model: "minimax-m3", role: "大量草稿 / 探索", weight: 0.20,
    responsibility: "窄任務快速掃描、列候選、找邊界案例", defaultAuthority: .brainOnly)
  static let grokScout = ModelRoleAssignment(
    id: "grok-news", model: "grok-build", role: "消息 / 反例", weight: 0.15,
    responsibility: "查較新的外部視角、挑戰過度保守結論", defaultAuthority: .brainOnly)
  static let claudeReviewer = ModelRoleAssignment(
    id: "claude-reviewer", model: "sonnet-5", role: "工程副審 / 修補", weight: 0.25,
    responsibility: "檢查 diff、找漏測、提出可套用的修正意圖；M/L code 預設取代舊 Sonnet reviewer", defaultAuthority: .patchProposal)
  static let opusDeputyReviewer = ModelRoleAssignment(
    id: "opus-deputy-reviewer", model: "opus-5", role: "副審 / 嚴格驗收", weight: 0.18,
    responsibility: "作為 Claude 副審檢查 UI/UJ、架構風險與未驗證放行；只給 verdict 與 blocking finding",
    defaultAuthority: .brainOnly)
  static let opusJudge = ModelRoleAssignment(
    id: "opus-judge", model: "opus-5", role: "保守裁決", weight: 0.15,
    responsibility: "高風險 fail-closed，沒有證據就不放行", defaultAuthority: .brainOnly)

  static let workModes: [WorkMode] = [
    WorkMode(
      mode: .s,
      englishName: "Small",
      chineseName: "S 小修",
      plainDescription: "單主控處理小修，不開隊伍，避免協調成本比任務還大。",
      maxHelpers: 0,
      maxRounds: 1,
      requiresSandbox: false,
      requiresHumanApproval: false,
      requiresIndependentVerification: false,
      defaultBudget: WorkModeBudget(
        tokenRangeLabel: "≤ 2 萬輸出量級", helperLimitLabel: "0 helper", roundLimitLabel: "1 輪",
        requiresBudgetReceipt: false),
      roleAssignments: [controller],
      stopRules: ["測試或 smoke 通過即可停", "無新證據時不加派模型"]
    ),
    WorkMode(
      mode: .m,
      englishName: "Medium",
      chineseName: "M 協作",
      plainDescription: "主控加 reviewer，預設 3 個 domain loops（自定義至 8）；適合中型修補或一次架構檢查。",
      maxHelpers: 4,
      maxRounds: 2,
      requiresSandbox: false,
      requiresHumanApproval: false,
      requiresIndependentVerification: true,
      defaultBudget: WorkModeBudget(
        tokenRangeLabel: "約 2–8 萬", helperLimitLabel: "≤4 helper", roundLimitLabel: "≤2 輪",
        requiresBudgetReceipt: true),
      roleAssignments: [controller, claudeReviewer, opusDeputyReviewer, minimaxScout],
      stopRules: ["第二輪仍無新增 critical 就收斂", "reviewer 與 builder 不可同一人最終放行"]
    ),
    WorkMode(
      mode: .l,
      englishName: "Large",
      chineseName: "L 專案",
      plainDescription: "多模組、多風險；預設 8 個 loops（cycle 展開，自定義至 20），需要沙盒或獨立驗證。",
      maxHelpers: 16,
      maxRounds: 2,
      requiresSandbox: false,
      requiresHumanApproval: false,
      requiresIndependentVerification: true,
      defaultBudget: WorkModeBudget(
        tokenRangeLabel: "約 8–30 萬", helperLimitLabel: "≤16 helper", roundLimitLabel: "≤2 輪",
        requiresBudgetReceipt: true),
      roleAssignments: [
        controller, minimaxScout, grokScout, claudeReviewer, opusDeputyReviewer, opusJudge,
      ],
      stopRules: ["每個關鍵結論要有證據", "測試失敗即停下修，不繼續擴散", "UI/UX 沒有截圖不可通過"]
    ),
    WorkMode(
      mode: .xl,
      englishName: "Extra Large",
      chineseName: "XL 重型",
      plainDescription: "大型未知任務；預設 20 個 loops（自定義至 64），沙盒跑到無誤再備份實裝主機。",
      maxHelpers: 48,
      maxRounds: 3,
      requiresSandbox: true,
      requiresHumanApproval: true,
      requiresIndependentVerification: true,
      defaultBudget: WorkModeBudget(
        tokenRangeLabel: "約 30–100 萬，必須分批", helperLimitLabel: "≤48 helper", roundLimitLabel: "≤3 輪",
        requiresBudgetReceipt: true),
      roleAssignments: [
        controller, minimaxScout, grokScout, claudeReviewer, opusDeputyReviewer, opusJudge,
      ],
      stopRules: [
        "未通過 sandbox 不實裝", "任何 host mutation 前要有備份收據", "Verifier 或 Judge 提出 P0/P1 未解時不得放行",
        "達預算或輪次上限即保存 checkpoint",
      ]
    ),
    // Repo-local policy anchor:
    // docs/protocol/CODEX_MULTIAGENT_V2_OS_INTEGRATION.md §5.3 caps the XXL
    // orchestration wave at four active participants and one heavy worker.
    // `maxHelpers` is the dispatch-ledger ceiling; later waves reuse freed slots.
    WorkMode(
      mode: .xxl,
      englishName: "Orchestration",
      chineseName: "XXL 編排級",
      plainDescription: "單一編排手統帥多條 Loops 與 subs；最多 4 個 helper 同時存活，工作量以分波方式擴張。",
      maxHelpers: 4,
      maxRounds: 3,
      requiresSandbox: true,
      requiresHumanApproval: true,
      requiresIndependentVerification: true,
      defaultBudget: WorkModeBudget(
        tokenRangeLabel: "編排級，必須分波與持續量測",
        helperLimitLabel: "≤4 concurrent helpers",
        roundLimitLabel: "每波 ≤3 輪",
        requiresBudgetReceipt: true),
      roleAssignments: [
        controller, minimaxScout, grokScout, claudeReviewer, opusDeputyReviewer, opusJudge,
      ],
      stopRules: [
        "任何時刻最多 4 個 helper 並且只准 1 個 heavy worker",
        "每波必須有 consolidated receipt 與 Lead 實質抽驗",
        "CPU、記憶體、swap、儲存或 UI 響應進入紅燈時先 checkpoint 再縮減併發",
        "未通過 sandbox、rollback 與 human gate 不得 promotion",
      ]
    ),
  ]

  static let scenarios: [Scenario] = [
    Scenario(
      scenario: .daily, chineseName: "通用預設", plainDescription: "通用問答、整理、輕量修補，GPT 主控，少量審稿。",
      roleWeights: [controller, opusDeputyReviewer], defaultMode: .s, readOnlyByDefault: false,
      guardrails: ["能單模型完成就不開大陣仗"]),
    Scenario(
      scenario: .design, chineseName: "設計 / UI", plainDescription: "先定義要看起來像什麼，再用截圖或原型驗收。",
      roleWeights: [controller, minimaxScout, grokScout, opusDeputyReviewer], defaultMode: .m,
      readOnlyByDefault: false, guardrails: ["UI 不能只看 build pass", "必須有 screenshot/crop 或人工確認"]),
    Scenario(
      scenario: .coding, chineseName: "寫代碼", plainDescription: "Codex 主控落地，其他模型找漏洞、補測試、做保守裁決。",
      roleWeights: [controller, minimaxScout, claudeReviewer, opusDeputyReviewer, opusJudge],
      defaultMode: .m,
      readOnlyByDefault: false, guardrails: ["patch 由 Codex 宿主套用", "先測試再宣稱完成"]),
    Scenario(
      scenario: .trading, chineseName: "交易 / 風控", plainDescription: "預設只讀；涉及資金、下單、槓桿、停損要額外風控審查。",
      roleWeights: [controller, grokScout, opusJudge], defaultMode: .l, readOnlyByDefault: true,
      guardrails: ["不直接下單", "不改 live risk", "不碰 secrets", "資金相關需額外人工批准"]),
    Scenario(
      scenario: .modeling, chineseName: "建模 / 研究", plainDescription: "多候選、多反例、最後用可重現測試收斂。",
      roleWeights: [controller, minimaxScout, grokScout, opusJudge], defaultMode: .l,
      readOnlyByDefault: true, guardrails: ["claim 沒 evidence 就只是假設", "保留可復查收據"]),
  ]

  static let compatibility: [ModelCompatibility] = [
    ModelCompatibility(
      id: "gpt55-minimax-m3", primaryModel: "gpt-5.5", companionModel: "minimax-m3", score: 4,
      goodFor: ["大量草稿", "分檔掃描", "候選清單"], weakFor: ["最終裁決", "高風險安全判斷"],
      plainNotes: "MiniMax 適合扛量，GPT 負責收斂與執行語義。"),
    ModelCompatibility(
      id: "gpt55-sonnet-5", primaryModel: "gpt-5.5", companionModel: "sonnet-5", score: 5,
      goodFor: ["程式碼審稿", "漏測檢查", "可套用 patch intent", "文件修補"], weakFor: ["大量低成本枚舉", "無證據 final pass"],
      plainNotes: "Sonnet 5 是工程副審與 M/L debug lead 候選，但最後仍要 Codex 跑測試、Opus/人類看高風險。"),
    ModelCompatibility(
      id: "gpt55-grok", primaryModel: "gpt-5.5", companionModel: "grok-build", score: 4,
      goodFor: ["查較新消息", "尖銳反例", "外部視角"], weakFor: ["未驗證就直接定案", "私密資料處理"],
      plainNotes: "Grok 用來挑戰 GPT 的保守或盲點，不當唯一證據。"),
    ModelCompatibility(
      id: "gpt55-opus", primaryModel: "gpt-5.5", companionModel: "opus-5", score: 5,
      goodFor: ["保守裁決", "長上下文審核", "高風險 fail-closed"], weakFor: ["每個小任務都開重審", "大量草稿"],
      plainNotes: "Opus 適合作最終風險門，不適合拿來掃所有小項。"),
  ]

  static let plugins: [PluginRegistryEntry] = [
    PluginRegistryEntry(
      id: "gitnexus", name: "GitNexus", kind: .plugin,
      purpose: "M 級以上每次啟動協作流時，先查專案地圖、入口與影響範圍；S 小修可跳過。",
      path: "plugin:github/gitnexus",
      trigger: "Tatwo Ultrawork mode M/L/XL/XXL 啟動時固定調用一次；不是每次 grep/file read 都調用",
      safetyLevel: .medium, requiredForModes: [.m, .l, .xl, .xxl],
      installState: .installed,
      smokeCommand: "rg -q '^\\[mcp_servers\\.gitnexus\\]' \"$HOME/.codex/config.toml\"",
      publicInstallHint: "project-map preflight for M+ modes"),
    PluginRegistryEntry(
      id: "chatgpt-pro-mcp", name: "ChatGPT Pro MCP", kind: .mcp,
      purpose: "完整 TATWO 必備的 Pro 研究 / 審稿 lane；負責長 memo、來源整理、反方觀點與 handoff，不是同步 dropdown 模型。",
      path: "mcp:chatgpt-pro-mcp",
      trigger: "安裝時必須連接；實際調用於需要 source-backed research、Pro reviewer 或重大方案反方審稿時",
      safetyLevel: .high, requiredForModes: [.m, .l, .xl, .xxl],
      installState: .installed,
      smokeCommand: "rg -q '^\\[mcp_servers\\.chatgpt_pro_mcp\\]' \"$HOME/.codex/config.toml\"",
      publicInstallHint:
        "required: install/connect chatgpt-pro-mcp guarded async ProResearchJobV1 lane"),
    PluginRegistryEntry(
      id: "tatwo-ultrawork", name: "Tatwo Ultrawork", kind: .skill,
      purpose: "TATWO Work OS 的主技能；輸入 $tatwo-ultrawork 啟動 Plan + Loops + Goal。",
      path: "skill:tatwo-ultrawork",
      trigger: "在 Chat 輸入 $tatwo-ultrawork，或任務需要 Work OS contract、Loops、收據與驗收時。",
      safetyLevel: .high, requiredForModes: [.s, .m, .l, .xl, .xxl],
      installState: .installed,
      smokeCommand: "test -f \"$HOME/Library/Application Support/Tatwo Ultrawork/capabilities/skills/tatwo-ultrawork/SKILL.md\"",
      publicInstallHint: "Tatwo-owned canonical skill"),
    PluginRegistryEntry(
      id: "tatwo-ultrawork-mcp", name: "Tatwo Ultrawork MCP", kind: .mcp,
      purpose: "TATWO Work OS 的 mode、scenario、sandbox、receipt、goal 與 doctor MCP 控制面。",
      path: "mcp:tatwo_ultrawork",
      trigger: "需要查詢或執行 TATWO Work OS contract、workflow、sandbox、receipt 與驗證工具時。",
      safetyLevel: .high, requiredForModes: [.s, .m, .l, .xl, .xxl],
      installState: .installed,
      smokeCommand: "rg -q '^\\[mcp_servers\\.tatwo_ultrawork\\]' \"$HOME/.codex/config.toml\"",
      publicInstallHint: "installed MCP: tatwo_ultrawork"),
    PluginRegistryEntry(
      id: "computer-use", name: "Computer Use", kind: .plugin,
      purpose: "操作與驗證 macOS App 可視介面；用於截圖、互動 smoke 與 UI runtime 證據，不取代測試。",
      path: "plugin:computer-use@openai-bundled",
      trigger: "需要操作本機 App、驗證 UI 互動或產生當輪可視收據時。",
      safetyLevel: .high, requiredForModes: [.m, .l, .xl],
      installState: .installed,
      smokeCommand:
        "rg -q '^\\[plugins\\.\"computer-use@openai-bundled\"\\]' \"$HOME/.codex/config.toml\" && rg -q '^\\[mcp_servers\\.computer-use\\]' \"$HOME/.codex/config.toml\"",
      publicInstallHint: "installed bundled plugin + MCP"),
    PluginRegistryEntry(
      id: "gbrain", name: "GBrain", kind: .mcp,
      purpose: "多代理研究、整理與次級分析入口；輸出仍是 advisory evidence，需由 host receipts 驗證。",
      path: "mcp:gbrain_allai",
      trigger: "需要 GBrain 多代理查詢、整理或交叉分析，且 contract 允許外部 runner 時。",
      safetyLevel: .high, requiredForModes: [.l, .xl],
      installState: .installed,
      smokeCommand: "rg -q '^\\[mcp_servers\\.gbrain_allai\\]' \"$HOME/.codex/config.toml\"",
      publicInstallHint: "installed MCP: gbrain_allai"),
    PluginRegistryEntry(
      id: "open-ultrawork", name: "open-ultrawork", kind: .skill,
      purpose: "S/M/L/XL、分工、預算、停止條件、驗證。", path: "skill:open-ultrawork",
      trigger: "多模型協作、重型模式、對抗驗證", safetyLevel: .high,
      requiredForModes: [.m, .l, .xl], installState: .installed,
      smokeCommand: "test -f \"$HOME/.codex/skills/open-ultrawork/SKILL.md\"",
      publicInstallHint: "skill: open-ultrawork"),
    PluginRegistryEntry(
      id: "tatworoom-web-app", name: "tatworoom-web-app", kind: .skill,
      purpose: "TATWO web/super app 任務專用上下文。",
      path: "skill:tatworoom-web-app",
      trigger: "任務屬於 TATWO 刺青室 / super app / travel / game module", safetyLevel: .medium,
      requiredForModes: [.m, .l, .xl], installState: .installed,
      smokeCommand: "test -f \"$HOME/.codex/skills/tatworoom-web-app/SKILL.md\"",
      publicInstallHint: "skill: tatworoom-web-app"),
    PluginRegistryEntry(
      id: "codex-app-model-gateway", name: "codex-app-model-gateway", kind: .localRuntime,
      purpose: "單一 provider、同 thread 切模型、fast 預設。", path: "local:codex-app-model-gateway",
      trigger: "需要 Codex App dropdown 接多模型",
      safetyLevel: .critical, requiredForModes: [.m, .l, .xl, .xxl],
      installState: .missing,
      smokeCommand: "test -x \"$HOME/.codex/bin/codex-model-gateway\"",
      publicInstallHint: "local gateway runtime; preflight before install"),
    PluginRegistryEntry(
      id: "colima-sandbox-runner", name: "Colima sandbox runner", kind: .localRuntime,
      purpose: "L/XL 可選乾淨容器沙盒驗證器；用 deterministic checks 對抗假完成，不是模型、不做 fan-out。",
      path: "local:colima/docker",
      trigger: "L/XL 高風險改動、依賴隔離、Linux/container-like 驗證；S 預設跳過，M 可手動啟用。", safetyLevel: .high,
      requiredForModes: [.l, .xl],
      installState: .missing,
      smokeCommand: "command -v colima >/dev/null && command -v docker >/dev/null",
      publicInstallHint:
        "optional: brew install colima docker; Tatwo never auto-installs or auto-starts it"),
    PluginRegistryEntry(
      id: "web-check", name: "web-check / 前端健檢", kind: .skill,
      purpose:
        "前端 UI/code/debug/ops 的本地驗收收據來源；掃 React/Next/Vite 風險、規則 parity、JSON report，不當模型也不當最終美感裁判。",
      path: "skill:web-check",
      trigger:
        "UI/UJ、frontend code、public URL read-only scan、前端 debug why file:line；L/XL UI 任務 promotion 前固定檢查。",
      safetyLevel: .high, requiredForModes: [.m, .l, .xl],
      installState: .installed,
      smokeCommand: "test -f \"$HOME/.codex/skills/web-check/SKILL.md\"",
      publicInstallHint:
        "recommended: install local web-check; run ./bin/tatwo-frontend-doctor rules list --json"),
    PluginRegistryEntry(
      id: "product-design", name: "Product Design", kind: .plugin,
      purpose:
        "UI/UJ 截圖式副審收據來源；檢查排版擠壓、資訊層次、工作流可讀性、箭頭理解與 accessibility 風險，不當 builder 或最終放行者。",
      path: "plugin:product-design",
      trigger:
        "UI / dashboard / workflow 視覺改動；M 建議，L/XL UI 任務通過前必須有本輪截圖 audit。",
      safetyLevel: .medium, requiredForModes: [.m, .l, .xl],
      installState: .installed,
      smokeCommand:
        "test -f \"$HOME/.codex/plugins/cache/openai-curated-remote/product-design/.codex-remote-plugin-install.json\"",
      publicInstallHint:
        "recommended: use @product-design audit with local screenshots; no secrets/raw logs upload"),
    PluginRegistryEntry(
      id: "creative-production", name: "Creative Production", kind: .plugin,
      purpose:
        "創意產出 lane：概念、視覺方向、文案、素材生成的結構化產線；作為 UI/內容雛形的創意來源，不當工程 builder 或最終放行者。",
      path: "plugin:creative-production",
      trigger:
        "需要創意概念 / 視覺方向 / 文案 / 素材產線時；人工在 Plugins 分頁登記，由情境編輯器按需選用。",
      safetyLevel: .medium, requiredForModes: [.m, .l, .xl],
      installState: .installed,
      smokeCommand:
        "test -f \"$HOME/.codex/plugins/cache/openai-curated-remote/creative-production/.codex-remote-plugin-install.json\"",
      publicInstallHint:
        "installed remote plugin; run its local probe before production use"),
    PluginRegistryEntry(
      id: "build-macos-app", name: "Build macOS App", kind: .plugin,
      purpose:
        "macOS App 搭建 lane：SwiftPM/SwiftUI 專案 scaffold、build、簽章、封裝、install 的結構化流程參考；供 OS App 自身與衍生 mac app 開發參照，執行仍由 host executor。",
      path: "plugin:build-macos-app",
      trigger:
        "需要新建 / 建置 / 封裝 macOS App 時；人工在 Plugins 分頁登記，由情境編輯器按需選用。",
      safetyLevel: .medium, requiredForModes: [.m, .l, .xl],
      installState: .installed,
      smokeCommand:
        "find \"$HOME/.codex/plugins/cache/openai-curated/build-macos-apps\" -path '*/.codex-plugin/plugin.json' -print -quit | grep -q .",
      publicInstallHint:
        "installed plugin: build-macos-apps@openai-curated"),
    PluginRegistryEntry(
      id: "superpowers", name: "Superpowers", kind: .plugin,
      purpose:
        "舊版工程流程技能集合；在 GPT-5.6 lane 容易加入不必要流程與角色假設，保留僅供舊 contract 相容。",
      path: "plugin:superpowers@openai-curated",
      trigger: "只在既有 contract 明確要求相容舊 Superpowers 流程時使用；GPT-5.6 新任務不推薦。",
      safetyLevel: .medium, requiredForModes: [],
      installState: .installed,
      smokeCommand:
        "find \"$HOME/.codex/plugins/cache/openai-curated/superpowers\" -path '*/.codex-plugin/plugin.json' -print -quit | grep -q .",
      publicInstallHint: "deprecated-for-gpt56；已安裝但不推薦在 GPT-5.6 新任務啟用"),
  ]
}
