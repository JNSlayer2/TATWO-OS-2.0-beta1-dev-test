import Foundation

public struct EngineID: Codable, Sendable, Hashable, RawRepresentable, ExpressibleByStringLiteral, Comparable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  public init(stringLiteral value: StringLiteralType) {
    self.init(rawValue: value)
  }

  public static func < (lhs: EngineID, rhs: EngineID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public static let codex: EngineID = "codex"
  public static let claudeCLI: EngineID = "claude-cli"
  public static let chatgptProMCP: EngineID = "chatgpt-pro-mcp"
  public static let grok: EngineID = "grok"
  public static let minimax: EngineID = "minimax"
  public static let localModel: EngineID = "local-model"
  public static let modelGateway: EngineID = "model-gateway"
}

public enum EngineKind: String, Codable, Sendable, CaseIterable, Equatable {
  case host
  case cli
  case mcp
  case api
  case local
}

public enum HostCapability: String, Codable, Sendable, CaseIterable, Comparable, Equatable {
  case readFiles = "read_files"
  case writeFiles = "write_files"
  case applyPatch = "apply_patch"
  case shell
  case runTests = "run_tests"
  case uiScreenshot = "ui_screenshot"
  case modelGateway = "model_gateway"
  case sameThreadSwitch = "same_thread_switch"
  case mcpClient = "mcp_client"
  case mcpServer = "mcp_server"
  case sandbox
  case review
  case research
  case news
  case bulkDraft = "bulk_draft"
  case finalJudge = "final_judge"
  case handoff

  public static func < (lhs: HostCapability, rhs: HostCapability) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct EngineAdapter: Codable, Sendable, Identifiable, Equatable {
  public var id: String { engineID.rawValue }
  public let engineID: EngineID
  public let displayName: String
  public let kind: EngineKind
  public let defaultModels: [String]
  public let hostFitScore: Int
  public let isDefaultHost: Bool
  public let capabilities: [HostCapability]
  public let defaultAuthority: AuthorityMode
  public let installState: InstallState
  public let safetyLevel: SafetyLevel
  public let plainStrength: String
  public let plainLimits: String

  public init(
    engineID: EngineID,
    displayName: String,
    kind: EngineKind,
    defaultModels: [String],
    hostFitScore: Int,
    isDefaultHost: Bool = false,
    capabilities: [HostCapability],
    defaultAuthority: AuthorityMode,
    installState: InstallState = .unknown,
    safetyLevel: SafetyLevel,
    plainStrength: String,
    plainLimits: String
  ) {
    self.engineID = engineID
    self.displayName = displayName
    self.kind = kind
    self.defaultModels = defaultModels
    self.hostFitScore = min(5, max(1, hostFitScore))
    self.isDefaultHost = isDefaultHost
    self.capabilities = Array(Set(capabilities)).sorted()
    self.defaultAuthority = defaultAuthority
    self.installState = installState
    self.safetyLevel = safetyLevel
    self.plainStrength = plainStrength
    self.plainLimits = plainLimits
  }

  public var canMutateHostSafely: Bool {
    capabilities.contains(.writeFiles) && capabilities.contains(.applyPatch)
      && capabilities.contains(.shell) && capabilities.contains(.runTests)
  }
}

public enum IdentityKind: String, Codable, Sendable, CaseIterable, Comparable, Equatable {
  case lead
  case supervisor
  case consultant
  case sub
  case news
  case verifier

  public static func < (lhs: IdentityKind, rhs: IdentityKind) -> Bool {
    let order: [IdentityKind] = [.lead, .supervisor, .consultant, .sub, .news, .verifier]
    return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
  }

  public var chineseName: String {
    switch self {
    case .lead: return "主導"
    case .supervisor: return "監督"
    case .consultant: return "顧問"
    case .sub: return "sub"
    case .news: return "消息"
    case .verifier: return "驗收"
    }
  }
}

public struct IdentityDefinition: Codable, Sendable, Identifiable, Equatable {
  public var id: String { kind.rawValue }
  public let kind: IdentityKind
  public let title: String
  public let plainDefinition: String
  public let canOwnFinalAnswer: Bool
  public let canMutateHostByDefault: Bool
  public let requiredEvidence: [String]

  public init(
    kind: IdentityKind,
    title: String? = nil,
    plainDefinition: String,
    canOwnFinalAnswer: Bool,
    canMutateHostByDefault: Bool,
    requiredEvidence: [String]
  ) {
    self.kind = kind
    self.title = title ?? kind.chineseName
    self.plainDefinition = plainDefinition
    self.canOwnFinalAnswer = canOwnFinalAnswer
    self.canMutateHostByDefault = canMutateHostByDefault
    self.requiredEvidence = requiredEvidence
  }
}

public struct IdentityCandidate: Codable, Sendable, Identifiable, Equatable {
  public var id: String { "\(engineID.rawValue):\(modelID)" }
  public let engineID: EngineID
  public let modelID: String
  public let fitScore: Int
  public let authority: AuthorityMode
  public let canMutateHost: Bool
  public let bestWhen: String
  public let caution: String

  public init(
    engineID: EngineID,
    modelID: String,
    fitScore: Int,
    authority: AuthorityMode,
    canMutateHost: Bool = false,
    bestWhen: String,
    caution: String
  ) {
    self.engineID = engineID
    self.modelID = modelID
    self.fitScore = min(5, max(1, fitScore))
    self.authority = authority
    self.canMutateHost = canMutateHost
    self.bestWhen = bestWhen
    self.caution = caution
  }
}

public struct IdentitySlot: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let kind: IdentityKind
  public let label: String
  public let required: Bool
  public let budgetWeight: Double
  public let helperCap: Int
  public let responsibilities: [String]
  public let requiredEvidence: [String]
  public let candidates: [IdentityCandidate]

  public init(
    id: String,
    kind: IdentityKind,
    label: String,
    required: Bool,
    budgetWeight: Double,
    helperCap: Int,
    responsibilities: [String],
    requiredEvidence: [String],
    candidates: [IdentityCandidate]
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.required = required
    self.budgetWeight = max(0, min(1, budgetWeight))
    self.helperCap = max(0, helperCap)
    self.responsibilities = responsibilities
    self.requiredEvidence = requiredEvidence
    self.candidates = candidates.sorted { lhs, rhs in
      if lhs.fitScore == rhs.fitScore { return lhs.engineID < rhs.engineID }
      return lhs.fitScore > rhs.fitScore
    }
  }

  public var primaryCandidate: IdentityCandidate? { candidates.first }
}

public struct ScenarioProfile: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let displayName: String
  public let baseScenario: ScenarioID?
  public let plainPurpose: String
  public let defaultMode: WorkModeID
  public let editable: Bool
  public let allowsNewsIdentity: Bool
  public let identitySlots: [IdentitySlot]
  public let agentsMarkdownTemplate: String
  public let guardrails: [String]

  public init(
    id: String,
    displayName: String,
    baseScenario: ScenarioID?,
    plainPurpose: String,
    defaultMode: WorkModeID,
    editable: Bool = true,
    allowsNewsIdentity: Bool,
    identitySlots: [IdentitySlot],
    agentsMarkdownTemplate: String,
    guardrails: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.baseScenario = baseScenario
    self.plainPurpose = plainPurpose
    self.defaultMode = defaultMode
    self.editable = editable
    self.allowsNewsIdentity = allowsNewsIdentity
    self.identitySlots = identitySlots
    self.agentsMarkdownTemplate = agentsMarkdownTemplate
    self.guardrails = guardrails
  }
}

public struct ModeIdentityPlan: Codable, Sendable, Identifiable, Equatable {
  public var id: String { mode.rawValue }
  public let mode: WorkModeID
  public let chineseName: String
  public let budgetLabel: String
  public let helperLimit: Int
  public let roundLimit: Int
  public let sandboxRequired: Bool
  public let humanApprovalRequired: Bool
  public let identitySlots: [IdentitySlot]
  public let requiredReceipts: [String]
  public let stopRules: [String]

  public init(
    mode: WorkModeID,
    chineseName: String,
    budgetLabel: String,
    helperLimit: Int,
    roundLimit: Int,
    sandboxRequired: Bool,
    humanApprovalRequired: Bool,
    identitySlots: [IdentitySlot],
    requiredReceipts: [String],
    stopRules: [String]
  ) {
    self.mode = mode
    self.chineseName = chineseName
    self.budgetLabel = budgetLabel
    self.helperLimit = helperLimit
    self.roundLimit = roundLimit
    self.sandboxRequired = sandboxRequired
    self.humanApprovalRequired = humanApprovalRequired
    self.identitySlots = identitySlots
    self.requiredReceipts = requiredReceipts
    self.stopRules = stopRules
  }
}

public struct TraitEvaluationDimension: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let plainMeaning: String
  public let usedForIdentities: [IdentityKind]

  public init(id: String, title: String, plainMeaning: String, usedForIdentities: [IdentityKind]) {
    self.id = id
    self.title = title
    self.plainMeaning = plainMeaning
    self.usedForIdentities = usedForIdentities
  }
}

public struct UltraworkTopic: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let outline: String
  public let details: [String]
  public let toolPrinciples: [String]
  public let hostMutationPolicy: String

  public init(
    id: String,
    title: String,
    outline: String,
    details: [String],
    toolPrinciples: [String],
    hostMutationPolicy: String
  ) {
    self.id = id
    self.title = title
    self.outline = outline
    self.details = details
    self.toolPrinciples = toolPrinciples
    self.hostMutationPolicy = hostMutationPolicy
  }
}

public enum TatwoIdentityCatalog {
  public static let engines: [EngineAdapter] = [
    EngineAdapter(
      engineID: .modelGateway,
      displayName: "TATWO Model Gateway",
      kind: .mcp,
      defaultModels: TatwoGatewayDispatchCatalog.allowedModels.sorted(),
      hostFitScore: 1,
      capabilities: [.modelGateway, .sameThreadSwitch, .review, .research, .news, .bulkDraft],
      defaultAuthority: .brainOnly,
      safetyLevel: .high,
      plainStrength: "跨品牌文字 dispatch 的單一路徑；身份組先選模型，再由 gateway route。",
      plainLimits: "只回傳建議與收據，hostMutationAllowed 永遠為 false。"
    ),
    EngineAdapter(
      engineID: .codex,
      displayName: "Codex App / CLI",
      kind: .host,
      defaultModels: ["gpt-5.5"],
      hostFitScore: 5,
      isDefaultHost: true,
      capabilities: [
        .readFiles, .writeFiles, .applyPatch, .shell, .runTests, .uiScreenshot, .modelGateway,
        .sameThreadSwitch, .mcpClient, .mcpServer, .sandbox, .review, .handoff,
      ],
      defaultAuthority: .toolIntentBridge,
      safetyLevel: .critical,
      plainStrength: "目前最適合當 host executor：懂本機 workspace、patch、shell、測試與 Codex App gateway。",
      plainLimits: "Codex 是最高適配宿主，不等於 Tatwo 本身；UI/UJ 與高風險驗收不可自我放行。"
    ),
    EngineAdapter(
      engineID: .claudeCLI,
      displayName: "Claude CLI",
      kind: .cli,
      defaultModels: ["opus-5", "sonnet-5", "haiku-4-5"],
      hostFitScore: 2,
      capabilities: [.review, .research, .finalJudge],
      defaultAuthority: .patchProposal,
      safetyLevel: .high,
      plainStrength: "適合審稿、架構反方、長上下文裁決與 patch intent。",
      plainLimits: "預設不直接改主機；它的通過意見必須轉成 Codex 可重跑證據。"
    ),
    EngineAdapter(
      engineID: .chatgptProMCP,
      displayName: "ChatGPT Pro MCP",
      kind: .mcp,
      defaultModels: ["pro-research"],
      hostFitScore: 1,
      capabilities: [.research, .review, .handoff],
      defaultAuthority: .researchBridge,
      safetyLevel: .high,
      plainStrength: "適合 bounded research、產品規劃、反方 memo。",
      plainLimits: "不是 dropdown 模型，也不是檔案執行器；非同步結果只當 advisory evidence。"
    ),
    EngineAdapter(
      engineID: .grok,
      displayName: "Grok",
      kind: .api,
      defaultModels: ["grok-build"],
      hostFitScore: 1,
      capabilities: [.news, .research, .review],
      defaultAuthority: .brainOnly,
      safetyLevel: .medium,
      plainStrength: "適合查消息、找外部反例、挑戰過度保守結論。",
      plainLimits: "消息不能直接當最終證據；要交叉來源或 deterministic check。"
    ),
    EngineAdapter(
      engineID: .minimax,
      displayName: "MiniMax",
      kind: .api,
      defaultModels: ["minimax-m3"],
      hostFitScore: 1,
      capabilities: [.bulkDraft, .research],
      defaultAuthority: .brainOnly,
      safetyLevel: .medium,
      plainStrength: "適合大量草稿、候選清單、局部掃描。",
      plainLimits: "不當最終 judge；不能碰工具與主機。"
    ),
    EngineAdapter(
      engineID: .localModel,
      displayName: "Local / Qwen",
      kind: .local,
      defaultModels: ["qwen-local"],
      hostFitScore: 2,
      capabilities: [.bulkDraft, .review, .research],
      defaultAuthority: .brainOnly,
      safetyLevel: .medium,
      plainStrength: "適合便宜探索、離線草稿、低敏資料整理。",
      plainLimits: "除非另外接安全 host adapter，否則只輸出建議，不直接寫檔。"
    ),
  ]

  public static let identityDefinitions: [IdentityDefinition] = [
    IdentityDefinition(
      kind: .lead,
      plainDefinition: "負責任務定義、拆解、收斂與最後口徑；不是每次都固定 GPT，會依情境與特質替換。",
      canOwnFinalAnswer: true,
      canMutateHostByDefault: true,
      requiredEvidence: ["mode plan", "scope receipt", "final diff/test summary"]),
    IdentityDefinition(
      kind: .supervisor,
      plainDefinition: "檢查主導是否偏離、漏掉風險或偷換完成定義；可以擋下，但不直接亂改。",
      canOwnFinalAnswer: false,
      canMutateHostByDefault: false,
      requiredEvidence: ["review notes", "blocking findings or explicit pass reason"]),
    IdentityDefinition(
      kind: .consultant,
      plainDefinition: "提供專業意見、架構替代方案或設計方向；不負責最終決策。",
      canOwnFinalAnswer: false,
      canMutateHostByDefault: false,
      requiredEvidence: ["bounded advice", "assumptions stated"]),
    IdentityDefinition(
      kind: .sub,
      plainDefinition: "大量分工、草稿、掃描、局部推演；只交短結果，不自己擴權。",
      canOwnFinalAnswer: false,
      canMutateHostByDefault: false,
      requiredEvidence: ["assigned scope", "candidate list", "skipped scope if any"]),
    IdentityDefinition(
      kind: .news,
      plainDefinition: "查最新消息、外部來源、反例；只在需要外部資訊的情境啟用。",
      canOwnFinalAnswer: false,
      canMutateHostByDefault: false,
      requiredEvidence: ["source or freshness note", "cross-check status"]),
    IdentityDefinition(
      kind: .verifier,
      plainDefinition: "根據測試、截圖、smoke、redaction、人工確認放行或擋下；不能由 builder 自我驗收。",
      canOwnFinalAnswer: false,
      canMutateHostByDefault: false,
      requiredEvidence: ["test/smoke/screenshot receipt", "fail-closed decision"]),
  ]

  public static let traitDimensions: [TraitEvaluationDimension] = [
    TraitEvaluationDimension(
      id: "code-architecture", title: "代碼架構工整", plainMeaning: "檔案分層、命名、邊界與可維護性。",
      usedForIdentities: [.lead, .consultant, .verifier]),
    TraitEvaluationDimension(
      id: "syntax-consistency", title: "代碼語法一致性", plainMeaning: "風格一致、少破壞既有寫法、少低級錯。",
      usedForIdentities: [.consultant, .sub, .verifier]),
    TraitEvaluationDimension(
      id: "macro-architecture", title: "任務宏觀架構理解", plainMeaning: "看懂整體目標、風險、順序與完工邊界。",
      usedForIdentities: [.lead, .supervisor]),
    TraitEvaluationDimension(
      id: "context", title: "上下文", plainMeaning: "長任務中保留前後關係與使用者偏好。",
      usedForIdentities: [.lead, .supervisor, .consultant]),
    TraitEvaluationDimension(
      id: "multimodal", title: "多模態水準", plainMeaning: "看圖、看 UI、理解畫面與文字混合資訊。",
      usedForIdentities: [.consultant, .verifier]),
    TraitEvaluationDimension(
      id: "3d-modeling-spatial", title: "3D建模與空間比例", plainMeaning: "能否把抽象需求轉成可建模的比例、構圖、材質、全景/模型輸出與可驗收作品。",
      usedForIdentities: [.lead, .consultant, .sub, .verifier]),
    TraitEvaluationDimension(
      id: "hallucination-control", title: "幻覺度控制", plainMeaning: "越高代表越少亂編，越會要求證據。",
      usedForIdentities: [.supervisor, .verifier]),
    TraitEvaluationDimension(
      id: "moral-conservatism", title: "模型道德保守度", plainMeaning: "安全邊界與拒答傾向；高分代表可控但不過度卡死。",
      usedForIdentities: [.supervisor, .verifier]),
    TraitEvaluationDimension(
      id: "aesthetics", title: "美感", plainMeaning: "版面、比例、留白、視覺焦點與質感判斷。",
      usedForIdentities: [.lead, .consultant, .verifier]),
    TraitEvaluationDimension(
      id: "token-efficiency", title: "Token 消耗", plainMeaning: "越高代表越省、越適合長期大量調用。",
      usedForIdentities: [.lead, .supervisor, .sub]),
    TraitEvaluationDimension(
      id: "reasoning-depth", title: "推理深度", plainMeaning: "面對複雜因果與取捨時能否深入拆解。",
      usedForIdentities: [.lead, .supervisor, .consultant]),
    TraitEvaluationDimension(
      id: "instruction-following", title: "指令遵循強度", plainMeaning: "是否穩定遵守使用者限制、格式與不做事項。",
      usedForIdentities: [.lead, .sub, .verifier]),
    TraitEvaluationDimension(
      id: "creativity", title: "創造力", plainMeaning: "提出新方案、新角度、替代路線的能力。",
      usedForIdentities: [.consultant, .sub, .news]),
    TraitEvaluationDimension(
      id: "self-correction", title: "自我修正", plainMeaning: "發現錯誤後能不能收斂、修正、承認不確定。",
      usedForIdentities: [.lead, .supervisor, .verifier]),
    TraitEvaluationDimension(
      id: "stability", title: "穩定性", plainMeaning: "長回合、工具橋、供應商狀態下不崩流程。",
      usedForIdentities: [.lead, .supervisor, .verifier]),
    TraitEvaluationDimension(
      id: "opinion-integration", title: "多意見整合", plainMeaning: "把多模型、多立場意見合併成可執行結論。",
      usedForIdentities: [.lead, .supervisor]),
    TraitEvaluationDimension(
      id: "first-principles", title: "第一性原理思考", plainMeaning: "回到問題本質，而不是只套模板或跟風。",
      usedForIdentities: [.lead, .consultant]),
    TraitEvaluationDimension(
      id: "independent-objectivity", title: "獨立思考與客觀堅持", plainMeaning: "敢提出反例，不被主模型或使用者語氣帶偏。",
      usedForIdentities: [.supervisor, .consultant, .news]),
    TraitEvaluationDimension(
      id: "plugin-fit", title: "外部插件適配", plainMeaning: "理解 MCP、skills、CLI、工具權限與收據要求。",
      usedForIdentities: [.lead, .sub, .verifier]),
    TraitEvaluationDimension(
      id: "multi-model-collab", title: "多模協作能力", plainMeaning: "能在身份組中交接、補位、反駁與不越權。",
      usedForIdentities: [.lead, .supervisor, .consultant, .sub]),
    TraitEvaluationDimension(
      id: "solo-capability", title: "單打獨鬥能力", plainMeaning: "沒有 helper 時能否獨立完成可驗收成果。",
      usedForIdentities: [.lead, .sub]),
    TraitEvaluationDimension(
      id: "info-forecasting", title: "整合資訊與預判能力", plainMeaning: "整合外部消息、趨勢、風險並做下一步預判。",
      usedForIdentities: [.lead, .news, .consultant]),
    TraitEvaluationDimension(
      id: "writing", title: "文筆", plainMeaning: "文字清晰、有層次、能整理成可交付說明。",
      usedForIdentities: [.lead, .consultant]),
    TraitEvaluationDimension(
      id: "tact", title: "圓融度", plainMeaning: "溝通不硬拗，能把反對意見講清楚又不失焦。",
      usedForIdentities: [.lead, .supervisor, .consultant]),
  ]

  public static let coreIdentitySlots: [IdentitySlot] = [
    slot(
      id: "lead", kind: .lead, label: "主導", required: true, budgetWeight: 0.35, helperCap: 1,
      responsibilities: ["定義目標", "拆解工作", "合併結論", "維持停止條件"],
      evidence: ["mode receipt", "scope receipt"],
      candidates: [
        candidate(.modelGateway, "fable-5", 5, .brainOnly, best: "Work OS 主導與 Goal 收斂；經 canonical gateway dispatch。", caution: "不直接改主機，host 落地仍由 Codex executor。"),
        candidate(.codex, "gpt-5.5", 4, .toolIntentBridge, canMutateHost: true, best: "需要真實落地 patch、測試、CLI/App 驗收。", caution: "UI/UJ 不能自我放行。"),
        candidate(.claudeCLI, "opus-5", 4, .patchProposal, best: "需要保守架構主導或高風險反方。", caution: "預設只能提案，不能直接改主機。"),
        candidate(.claudeCLI, "sonnet-5", 4, .patchProposal, best: "需要工程一致性主導、M/L debug 或 code review 起手。", caution: "不直接改主機，需 Codex 跑測試。"),
        candidate(.localModel, "qwen-local", 2, .brainOnly, best: "低風險離線草稿。", caution: "不可當最終 host。"),
      ]),
    slot(
      id: "supervisor", kind: .supervisor, label: "監督", required: false, budgetWeight: 0.15, helperCap: 2,
      responsibilities: ["找偏航", "列 blocking risk", "檢查完成定義"],
      evidence: ["review receipt"],
      candidates: [
        candidate(.modelGateway, "gpt-5.6-terra", 5, .brainOnly, best: "refute-first 副審、量測與漂移檢查。", caution: "不直接寫檔或 final pass。"),
        candidate(.claudeCLI, "opus-5", 4, .brainOnly, best: "高風險 fail-closed 與架構審核。", caution: "不直接寫檔。"),
        candidate(.claudeCLI, "sonnet-5", 4, .patchProposal, best: "程式碼審稿、漏測檢查與修補意圖。", caution: "需 Codex 跑測試。"),
        candidate(.chatgptProMCP, "pro-review", 3, .researchBridge, best: "長 memo 或外部規劃審查。", caution: "非同步，不阻塞核心修補。"),
      ]),
    slot(
      id: "consultant", kind: .consultant, label: "顧問", required: false, budgetWeight: 0.12, helperCap: 4,
      responsibilities: ["提供替代方案", "補專業視角", "說明取捨"],
      evidence: ["assumption list"],
      candidates: [
        candidate(.chatgptProMCP, "pro-research", 4, .researchBridge, best: "產品/架構深度整理。", caution: "不得輸出私密 raw log。"),
        candidate(.claudeCLI, "sonnet-5", 4, .patchProposal, best: "程式、文件與 debug 顧問。", caution: "不自動放行。"),
        candidate(.grok, "grok-build", 3, .brainOnly, best: "外部視角與反例。", caution: "要標註消息來源狀態。"),
      ]),
    slot(
      id: "sub", kind: .sub, label: "sub", required: false, budgetWeight: 0.20, helperCap: 16,
      responsibilities: ["大量草稿", "局部掃描", "候選清單", "反例枚舉"],
      evidence: ["assigned scope", "candidate summary"],
      candidates: [
        candidate(.modelGateway, "gpt-5.6-sol", 5, .brainOnly, best: "依 contract 執行局部 loops 並回交 receipts。", caution: "不得擴權成主導或 host。"),
        candidate(.minimax, "minimax-m3", 4, .brainOnly, best: "大量候選與草稿。", caution: "不可當 judge。"),
        candidate(.localModel, "qwen-local", 4, .brainOnly, best: "便宜離線草稿。", caution: "不可改主機。"),
        candidate(.claudeCLI, "haiku-4-5", 3, .brainOnly, best: "短審查或局部掃描。", caution: "注意工具橋穩定度。"),
      ]),
    slot(
      id: "news", kind: .news, label: "消息", required: false, budgetWeight: 0.10, helperCap: 2,
      responsibilities: ["查最新消息", "找外部反例", "標註來源狀態"],
      evidence: ["freshness note", "source cross-check"],
      candidates: [
        candidate(.grok, "grok-build", 5, .brainOnly, best: "最新消息與尖銳反例。", caution: "不能當唯一證據。"),
        candidate(.chatgptProMCP, "pro-research", 4, .researchBridge, best: "長研究與來源整理。", caution: "非同步，需回填收據。"),
      ]),
    slot(
      id: "verifier", kind: .verifier, label: "驗收", required: true, budgetWeight: 0.18, helperCap: 2,
      responsibilities: ["測試與 smoke", "UI 截圖", "redaction", "放行/擋下"],
      evidence: ["test receipt", "screenshot if UI", "judge decision"],
      candidates: [
        candidate(.codex, "deterministic-checks", 5, .toolIntentBridge, canMutateHost: false, best: "跑測試、截圖、CLI smoke、redaction scan。", caution: "builder 產物需獨立 review，不靠自評。"),
        candidate(.claudeCLI, "opus-5", 4, .brainOnly, best: "高風險最終裁決。", caution: "需引用實際證據。"),
        candidate(.claudeCLI, "sonnet-5", 5, .patchProposal, best: "程式碼驗收、漏測檢查與 patch intent。", caution: "不能替代測試。"),
      ]),
  ]

  public static let scenarioProfiles: [ScenarioProfile] = [
    profile(
      id: "ui-ux", displayName: "UI / UX", base: .design, defaultMode: .m,
      purpose: "先看架構與畫面目標，再落地 UI；預設不啟用消息。",
      allowsNews: false,
      slotIDs: ["ui-visual-lead", "ui-code-curator", "ui-interaction-verifier"],
      guardrails: ["沒有截圖不可通過", "build pass 不等於 UI 通過", "主視覺與交互驗收不可同一人自評"]),
    profile(
      id: "daily", displayName: "通用", base: .daily, defaultMode: .s,
      purpose: "通用問答、整理、輕量修補與跨領域小協作；能單引擎完成就不開大隊伍。",
      allowsNews: true,
      slotIDs: ["lead", "supervisor", "sub", "consultant", "news"],
      guardrails: ["用最低模式完成", "消息身份只在需要外部資訊時啟用"]),
    profile(
      id: "debug", displayName: "Debug", base: .coding, defaultMode: .m,
      purpose: "主導定位問題，監督檢查假設，sub 做局部掃描，顧問提出修法。",
      allowsNews: false,
      slotIDs: ["lead", "supervisor", "sub", "consultant", "verifier"],
      guardrails: ["先重現再修", "沒有測試或 smoke 不宣稱修好"]),
    profile(
      id: "coding", displayName: "寫代碼", base: .coding, defaultMode: .m,
      purpose: "Codex host 落地，其他 engine 審稿、草稿或裁決。",
      allowsNews: false,
      slotIDs: ["coding-lead", "supervisor", "sub", "coding-consultant", "verifier"],
      guardrails: ["patch 由安全 host 套用", "reviewer 不能直接 final pass"]),
    profile(
      id: "trading-risk", displayName: "交易 / 風控", base: .trading, defaultMode: .l,
      purpose: "預設只讀；涉及資金、槓桿、停損、下單必須人工風控。",
      allowsNews: true,
      slotIDs: ["lead", "news", "supervisor", "verifier"],
      guardrails: ["不直接下單", "不改 live risk", "不碰 secrets"]),
    profile(
      id: "modeling", displayName: "建模", base: .modeling, defaultMode: .l,
      purpose: "多候選、多反例、可重現測試收斂。",
      allowsNews: true,
      slotIDs: ["lead", "sub", "consultant", "news", "verifier"],
      guardrails: ["claim 無 evidence 只是假設", "保留可復查收據"]),
    profile(
      id: "editing", displayName: "剪輯", base: .design, defaultMode: .m,
      purpose: "整理素材、節奏、字幕、分鏡與輸出驗收。",
      allowsNews: false,
      slotIDs: ["lead", "consultant", "sub", "verifier"],
      guardrails: ["先定義交付格式", "輸出需可播放或可預覽收據"]),
    profile(
      id: "video-research", displayName: "影片研究", base: .modeling, defaultMode: .l,
      purpose: "需要消息、來源、剪輯線索與反方驗證的長研究。",
      allowsNews: true,
      slotIDs: ["lead", "news", "sub", "consultant", "verifier"],
      guardrails: ["標註來源新鮮度", "來源不足不做定論"]),
  ]

  public static let ultraworkTopics: [UltraworkTopic] = [
    UltraworkTopic(
      id: "cli-mcp", title: "CLI / App MCP", outline: "同一套 core 給 App、Codex CLI、其他 MCP client 調用。",
      details: ["App 開著時走本地 HTTP App MCP；App 未開時 CLI 用 core library fallback。", "Codex 是最高適配 host，但 Claude CLI、generic CLI、其他 MCP client 都能讀同一套 schema。", "工具只回傳身份、情境、預算、工作流與收據規則，不直接授權危險寫入。"],
      toolPrinciples: ["tatwo-ultrawork mcp call <tool> --app-url http://127.0.0.1:17377 --json", "tatwo-ultrawork mcp call <tool> --json", "tatwo-ultrawork mcp serve --stdio", "tatwo-ultrawork engine capabilities --engine codex --json"],
      hostMutationPolicy: "MCP 查詢不等於 host install 授權。"),
    UltraworkTopic(
      id: "skills", title: "Skills / Agents", outline: "skill 是規則來源，agents.md 是情境身份配置模板。",
      details: ["情境頁輸出 agents.md 風格身份組：先身份，再候選 engine/model。", "舊 open-ultrawork 與 gateway 只作 archive reference，不恢復成主入口。"],
      toolPrinciples: ["只同步 canonical tatwo-ultrawork", "外部模型只拿必要片段，不拿 raw private context"],
      hostMutationPolicy: "同步 skill/MCP 要在 App review 後做，不由模型自動改。"),
    UltraworkTopic(
      id: "model-gateway", title: "Model Gateway", outline: "gateway 是模型路由與同 thread 切換，不是身份組本身。",
      details: ["同 thread dropdown 保留；Tatwo mode 是外層協作模式。", "新模型先成為 EngineAdapter 或 model candidate，再由特質分配身份。"],
      toolPrinciples: ["route by model", "fast default", "same-thread smoke receipt"],
      hostMutationPolicy: "不得新增一堆 Codex provider 造成更新衝突。"),
    UltraworkTopic(
      id: "sandbox", title: "Sandbox / Colima", outline: "沙盒是驗證器，不是模型；先證明不崩再上主機。",
      details: ["L/XL 先用 temporary workspace；Colima 缺少時降級，不崩潰。", "不得自動安裝、啟動、pull image、掛載 HOME/Volumes 或 token。"],
      toolPrinciples: ["colima preflight", "colima run --dry-run", "sandbox evidence bundle"],
      hostMutationPolicy: "真實 host install 需人類批准、備份、rollback、live smoke。"),
    UltraworkTopic(
      id: "sub-loops", title: "Sub / Loops", outline: "任務越難才組隊；每輪分派、驗證、合併。",
      details: ["S 不開 sub；M ≤4 helper；L ≤16 helper；XL ≤48 helper。", "sub 只能做明確範圍，不得自己擴權或呼叫危險工具。"],
      toolPrinciples: ["assigned scope", "round limit", "no silent retries"],
      hostMutationPolicy: "sub 結果必須由主導合併、驗收身份放行。"),
    UltraworkTopic(
      id: "receipts", title: "Receipts / Rollback", outline: "沒有收據就不是完成；模型文字不是驗收。",
      details: ["M/L/XL 要留下 mode、scope、role、validation、rollback、plugin/MCP、redaction 收據。", "UI/UJ 必須有 screenshot / visual diff / checklist 或人工確認。"],
      toolPrinciples: ["receipt requirements", "handoff pack", "redaction scan"],
      hostMutationPolicy: "收據不得包含 token、raw log、完整聊天或私密路徑。"),
  ]

  public static func engine(_ id: EngineID) -> EngineAdapter? {
    engines.first { $0.engineID == id }
  }

  public static func scenarioProfile(_ id: String) -> ScenarioProfile? {
    let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return scenarioProfiles.first { $0.id == normalized }
      ?? scenarioProfiles.first { $0.baseScenario?.rawValue == normalized }
  }

  public static func identitySlot(_ id: String) -> IdentitySlot? {
    scenarioSpecificSlots[id] ?? coreIdentitySlots.first { $0.id == id }
  }

  public static func modePlan(
    mode: WorkModeID,
    scenarioProfileID: String? = nil,
    catalog: TatwoCatalog = .defaults
  ) -> ModeIdentityPlan {
    let workMode = catalog.mode(mode) ?? catalog.workModes.last ?? fallbackWorkMode(mode)
    let scenarioSlots = scenarioProfileID.flatMap(scenarioProfile)?.identitySlots
    let slots = slotsForMode(mode, preferredSlots: scenarioSlots)
    return ModeIdentityPlan(
      mode: mode,
      chineseName: workMode.chineseName,
      budgetLabel: workMode.defaultBudget.tokenRangeLabel,
      helperLimit: workMode.maxHelpers,
      roundLimit: workMode.maxRounds,
      sandboxRequired: workMode.requiresSandbox,
      humanApprovalRequired: workMode.requiresHumanApproval,
      identitySlots: slots,
      requiredReceipts: receiptsForMode(mode, slots: slots),
      stopRules: workMode.stopRules
    )
  }

  private static func slotsForMode(_ mode: WorkModeID, preferredSlots: [IdentitySlot]?) -> [IdentitySlot] {
    let base: [IdentitySlot]
    switch mode {
    case .s:
      base = coreIdentitySlots.filter { $0.kind == .lead || $0.kind == .verifier }
        .map { slot in
          slot.kind == .verifier
            ? IdentitySlot(
              id: "s-verifier", kind: .verifier, label: "驗收（本機檢查）", required: false,
              budgetWeight: 0.05, helperCap: 0, responsibilities: ["直接證據或 smoke"],
              requiredEvidence: ["local check"], candidates: slot.candidates)
            : slot
        }
    case .m:
      base = coreIdentitySlots.filter { [.lead, .supervisor, .consultant, .sub, .verifier].contains($0.kind) }
    case .l:
      base = coreIdentitySlots.filter { [.lead, .supervisor, .consultant, .sub, .news, .verifier].contains($0.kind) }
    case .xl, .xxl:
      base = coreIdentitySlots
    }
    guard let preferredSlots, !preferredSlots.isEmpty else { return base }
    let allowed = Set(base.map(\.kind))
    return preferredSlots.filter { allowed.contains($0.kind) || $0.required }
  }

  private static func receiptsForMode(_ mode: WorkModeID, slots: [IdentitySlot]) -> [String] {
    var receipts = ["mode receipt", "identity plan receipt", "budget receipt"]
    if mode >= .m { receipts += ["project-map or scope receipt", "review receipt"] }
    if mode >= .l { receipts += ["validation receipt", "rollback receipt", "redaction receipt"] }
    if mode >= .xl { receipts += ["sandbox receipt", "human approval receipt", "host MCP registration smoke receipt"] }
    if slots.contains(where: { $0.kind == .news }) { receipts.append("freshness/source receipt") }
    return Array(NSOrderedSet(array: receipts)) as? [String] ?? receipts
  }

  private static var scenarioSpecificSlots: [String: IdentitySlot] {
    [
      "coding-lead": slot(
        id: "coding-lead", kind: .lead, label: "代碼主導", required: true,
        budgetWeight: 0.35, helperCap: 1,
        responsibilities: ["定義代碼目標", "拆解工程工作", "收斂證據", "維持停止條件"],
        evidence: ["mode receipt", "scope receipt"],
        candidates: [
          candidate(.modelGateway, "gpt-5.6-sol", 5, .brainOnly, best: "依 Work OS contract 主導 coding Goal、拆解與收斂。", caution: "身份是主導；host 落地仍由安全 Codex executor 執行。"),
          candidate(.modelGateway, "fable-5", 4, .brainOnly, best: "需要長上下文架構主導或 Goal 收斂時候選。", caution: "不直接改主機，且不覆蓋 coding profile 的 Sol 預設。"),
          candidate(.codex, "gpt-5.5", 4, .toolIntentBridge, canMutateHost: true, best: "需要真實落地 patch、測試、CLI/App 驗收。", caution: "host 能力不等於可跳過獨立驗收。"),
          candidate(.claudeCLI, "opus-5", 4, .patchProposal, best: "需要保守架構主導或高風險反方。", caution: "預設只能提案，不能直接改主機。"),
          candidate(.claudeCLI, "sonnet-5", 4, .patchProposal, best: "需要工程一致性主導、debug 或 code review 起手。", caution: "不直接改主機，需 Codex 跑測試。"),
        ]),
      "coding-consultant": slot(
        id: "coding-consultant", kind: .consultant, label: "ChatGPT Pro 專案顧問",
        required: false, budgetWeight: 0.12, helperCap: 1,
        responsibilities: ["提供專案綁定研究", "補架構替代方案", "輸出 advisory evidence"],
        evidence: ["bounded advice", "assumptions stated"],
        candidates: [
          candidate(.chatgptProMCP, "pro-research", 5, .researchBridge, best: "透過專案綁定 MCP 做 bounded research 與反方 memo。", caution: "只屬 consultant/advisory；不是通用模型引擎、lead、sub 或 host executor。"),
        ]),
      "ui-visual-lead": slot(
        id: "ui-visual-lead", kind: .lead, label: "主視覺", required: true, budgetWeight: 0.32,
        helperCap: 1,
        responsibilities: ["定義視覺層級", "保持 Codex Switch 乾淨玻璃風格", "把畫面目標講清楚"],
        evidence: ["design target", "screenshot after change"],
        candidates: [
          candidate(.claudeCLI, "opus-5", 5, .brainOnly, best: "保守審美與架構取捨。", caution: "不能直接改檔。"),
          candidate(.codex, "gpt-5.5", 4, .toolIntentBridge, canMutateHost: true, best: "把視覺規劃落地到 SwiftUI。", caution: "需獨立截圖驗收。"),
          candidate(.minimax, "minimax-m3", 3, .brainOnly, best: "快速產生多種版面候選。", caution: "不做 final pass。"),
        ]),
      "ui-code-curator": slot(
        id: "ui-code-curator", kind: .consultant, label: "代碼歸納", required: true,
        budgetWeight: 0.22, helperCap: 2,
        responsibilities: ["拆分視圖", "避免把備註塞進主畫面", "維持 SwiftUI 結構"],
        evidence: ["build receipt", "diff summary"],
        candidates: [
          candidate(.codex, "gpt-5.5", 5, .toolIntentBridge, canMutateHost: true, best: "改 Swift 檔、跑 build/test。", caution: "不能自評 UI 通過。"),
          candidate(.claudeCLI, "sonnet-5", 5, .patchProposal, best: "審查 SwiftUI 結構、可維護性與漏測。", caution: "需 Codex 套用。"),
        ]),
      "ui-interaction-verifier": slot(
        id: "ui-interaction-verifier", kind: .verifier, label: "交互驗收", required: true,
        budgetWeight: 0.24, helperCap: 2,
        responsibilities: ["截圖驗收", "檢查是否擠成一團", "確認可展開而不是備註牆"],
        evidence: ["screenshot", "visual checklist", "manual or judge pass"],
        candidates: [
          candidate(.codex, "screenshot-smoke", 5, .toolIntentBridge, best: "啟動 app 並截圖。", caution: "工程測試通過不代表 UI 通過。"),
          candidate(.claudeCLI, "opus-5", 4, .brainOnly, best: "高風險 UI/UJ fail-closed 審核。", caution: "需看實際截圖。"),
        ]),
    ]
  }

  private static func profile(
    id: String,
    displayName: String,
    base: ScenarioID?,
    defaultMode: WorkModeID,
    purpose: String,
    allowsNews: Bool,
    slotIDs: [String],
    guardrails: [String]
  ) -> ScenarioProfile {
    let slots = slotIDs.compactMap { identitySlot($0) }
    let md = agentsMarkdown(id: id, displayName: displayName, slots: slots, guardrails: guardrails)
    return ScenarioProfile(
      id: id,
      displayName: displayName,
      baseScenario: base,
      plainPurpose: purpose,
      defaultMode: defaultMode,
      allowsNewsIdentity: allowsNews,
      identitySlots: slots,
      agentsMarkdownTemplate: md,
      guardrails: guardrails
    )
  }

  private static func agentsMarkdown(
    id: String, displayName: String, slots: [IdentitySlot], guardrails: [String]
  ) -> String {
    let slotLines = slots.map { slot in
      "- \(slot.label) (\(slot.kind.chineseName)): \(slot.responsibilities.joined(separator: "、"))"
    }.joined(separator: "\n")
    let guardLines = guardrails.map { "- \($0)" }.joined(separator: "\n")
    return """
      # AGENTS.md - \(displayName) [\(id)]

      ## Identity groups
      \(slotLines)

      ## Guardrails
      \(guardLines)
      """
  }

  private static func slot(
    id: String,
    kind: IdentityKind,
    label: String,
    required: Bool,
    budgetWeight: Double,
    helperCap: Int,
    responsibilities: [String],
    evidence: [String],
    candidates: [IdentityCandidate]
  ) -> IdentitySlot {
    IdentitySlot(
      id: id,
      kind: kind,
      label: label,
      required: required,
      budgetWeight: budgetWeight,
      helperCap: helperCap,
      responsibilities: responsibilities,
      requiredEvidence: evidence,
      candidates: candidates)
  }

  private static func candidate(
    _ engineID: EngineID,
    _ modelID: String,
    _ fitScore: Int,
    _ authority: AuthorityMode,
    canMutateHost: Bool = false,
    best: String,
    caution: String
  ) -> IdentityCandidate {
    IdentityCandidate(
      engineID: engineID,
      modelID: modelID,
      fitScore: fitScore,
      authority: authority,
      canMutateHost: canMutateHost,
      bestWhen: best,
      caution: caution)
  }

  private static func fallbackWorkMode(_ mode: WorkModeID) -> WorkMode {
    WorkMode(
      mode: mode,
      englishName: mode.rawValue,
      chineseName: mode.rawValue,
      plainDescription: "custom catalog empty fallback",
      maxHelpers: mode >= .xl ? 48 : 0,
      maxRounds: mode >= .xl ? 3 : 1,
      requiresSandbox: mode >= .xl,
      requiresHumanApproval: mode >= .xl,
      requiresIndependentVerification: mode != .s,
      defaultBudget: WorkModeBudget(
        tokenRangeLabel: "custom budget unknown", helperLimitLabel: "custom helper unknown",
        roundLimitLabel: "custom round unknown", requiresBudgetReceipt: true),
      roleAssignments: [],
      stopRules: ["custom catalog empty fallback"])
  }
}
