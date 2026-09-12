import CryptoKit
import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .null
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    let object = try JSONSerialization.jsonObject(with: data, options: [])
    return fromAny(object)
  }

  public static func fromAny(_ value: Any) -> JSONValue {
    switch value {
    case let value as String:
      return .string(value)
    case let value as NSNumber:
      // JSONSerialization bridges both JSON booleans and numbers through NSNumber.
      // Check the CoreFoundation type first so numeric 0/1 fields such as helperCap
      // do not become false/true in MCP payloads.
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return .bool(value.boolValue)
      }
      return .number(value.doubleValue)
    case let value as Bool:
      return .bool(value)
    case let value as Int:
      return .number(Double(value))
    case let value as Double:
      return .number(value)
    case let value as [Any]:
      return .array(value.map(fromAny))
    case let value as [String: Any]:
      return .object(value.mapValues(fromAny))
    default:
      return .null
    }
  }
}

public struct TatwoMCPToolDefinition: Codable, Sendable, Identifiable, Equatable {
  public var id: String { name }
  public let name: String
  public let plainPurpose: String
  public let requiredArguments: [String]
  public let optionalArguments: [String]
  public let returnsSchema: String
  public let hostMutationAllowed: Bool
  public let metadata: [String: String]

  public init(
    name: String,
    plainPurpose: String,
    requiredArguments: [String] = [],
    optionalArguments: [String] = [],
    returnsSchema: String,
    hostMutationAllowed: Bool = false,
    metadata: [String: String] = [:]
  ) {
    self.name = name
    self.plainPurpose = plainPurpose
    self.requiredArguments = requiredArguments
    self.optionalArguments = optionalArguments
    self.returnsSchema = returnsSchema
    self.hostMutationAllowed = hostMutationAllowed
    self.metadata = metadata
  }
}

/// Process-local dynamic MCP definitions. The App owns invocation policy; this
/// registry only lets `/manifest` and `/tools/list` expose capability-scoped
/// tools without weakening the static core call switch.
public final class TatwoMCPDynamicToolRegistry: @unchecked Sendable {
  public static let shared = TatwoMCPDynamicToolRegistry()

  private let lock = NSLock()
  private var toolsBySource: [String: [TatwoMCPToolDefinition]] = [:]

  private init() {}

  public func replace(
    source: String,
    tools: [TatwoMCPToolDefinition]
  ) {
    lock.lock()
    if tools.isEmpty {
      toolsBySource.removeValue(forKey: source)
    } else {
      toolsBySource[source] = tools
    }
    lock.unlock()
  }

  public func snapshot() -> [TatwoMCPToolDefinition] {
    lock.lock()
    let snapshot = toolsBySource
      .sorted { $0.key < $1.key }
      .flatMap { $0.value }
    lock.unlock()
    return snapshot
  }
}

public enum TatwoMCPToolFailureKindV1: String, Codable, Sendable, Equatable {
  case contract
  case notFound
  case internalFailure
}

public struct TatwoMCPToolCallResult: Codable, Sendable, Equatable {
  public let schema: String
  public let tool: String
  public let ok: Bool
  public let payload: JSONValue?
  public let error: String?
  public let failureKind: TatwoMCPToolFailureKindV1?
  public let fallbackCoreLibraryUsed: Bool
  public let hostMutationAllowed: Bool

  public init(
    schema: String = "TatwoMCPToolCallResultV1",
    tool: String,
    ok: Bool,
    payload: JSONValue?,
    error: String? = nil,
    failureKind: TatwoMCPToolFailureKindV1? = nil,
    fallbackCoreLibraryUsed: Bool = true,
    hostMutationAllowed: Bool = false
  ) {
    self.schema = schema
    self.tool = tool
    self.ok = ok
    self.payload = payload
    self.error = error
    self.failureKind = failureKind
    self.fallbackCoreLibraryUsed = fallbackCoreLibraryUsed
    self.hostMutationAllowed = hostMutationAllowed
  }
}

public struct TatwoMCPEngineEntrypoint: Codable, Sendable, Identifiable, Equatable {
  public var id: String { engine.rawValue }
  public let engine: EngineID
  public let label: String
  public let command: String
  public let args: [String]
  public let canCallFromCLI: Bool
  public let requiresCodexHost: Bool
  public let plainPurpose: String

  public init(
    engine: EngineID,
    label: String,
    command: String,
    args: [String],
    canCallFromCLI: Bool,
    requiresCodexHost: Bool,
    plainPurpose: String
  ) {
    self.engine = engine
    self.label = label
    self.command = command
    self.args = args
    self.canCallFromCLI = canCallFromCLI
    self.requiresCodexHost = requiresCodexHost
    self.plainPurpose = plainPurpose
  }
}

public struct TatwoMCPClientConfig: Codable, Sendable, Equatable {
  public let schema: String
  public let requestedEngine: String
  public let codexRequired: Bool
  public let defaultHostEngine: String
  public let startCommand: String
  public let startArgs: [String]
  public let cliExamples: [String]
  public let fallbackBehavior: String
  public let safetyRules: [String]

  public init(
    schema: String = "TatwoMCPClientConfigV1",
    requestedEngine: String,
    codexRequired: Bool,
    defaultHostEngine: String,
    startCommand: String,
    startArgs: [String],
    cliExamples: [String],
    fallbackBehavior: String,
    safetyRules: [String]
  ) {
    self.schema = schema
    self.requestedEngine = requestedEngine
    self.codexRequired = codexRequired
    self.defaultHostEngine = defaultHostEngine
    self.startCommand = startCommand
    self.startArgs = startArgs
    self.cliExamples = cliExamples
    self.fallbackBehavior = fallbackBehavior
    self.safetyRules = safetyRules
  }
}

public struct TatwoMCPServerManifest: Codable, Sendable, Equatable {
  public let schema: String
  public let name: String
  public let engineAgnostic: Bool
  public let defaultHostEngine: String
  public let transports: [String]
  public let plainContract: String
  public let clientEntrypoints: [TatwoMCPEngineEntrypoint]
  public let tools: [TatwoMCPToolDefinition]
  public let safetyRules: [String]

  public init(
    schema: String = "TatwoMCPServerManifestV1",
    name: String = "tatwo-ultrawork",
    engineAgnostic: Bool = true,
    defaultHostEngine: String = EngineID.codex.rawValue,
    transports: [String],
    plainContract: String,
    clientEntrypoints: [TatwoMCPEngineEntrypoint],
    tools: [TatwoMCPToolDefinition],
    safetyRules: [String]
  ) {
    self.schema = schema
    self.name = name
    self.engineAgnostic = engineAgnostic
    self.defaultHostEngine = defaultHostEngine
    self.transports = transports
    self.plainContract = plainContract
    self.clientEntrypoints = clientEntrypoints
    self.tools = tools
    self.safetyRules = safetyRules
  }
}

public struct ReceiptRequirementSummary: Codable, Sendable, Equatable {
  public let schema: String
  public let mode: WorkModeID
  public let scenario: String
  public let receipts: [String]
  public let gates: [WorkflowGate]
  public let failClosedRule: String

  public init(
    schema: String = "TatwoReceiptRequirementSummaryV1",
    mode: WorkModeID,
    scenario: String,
    receipts: [String],
    gates: [WorkflowGate],
    failClosedRule: String
  ) {
    self.schema = schema
    self.mode = mode
    self.scenario = scenario
    self.receipts = receipts
    self.gates = gates
    self.failClosedRule = failClosedRule
  }
}

public struct EngineTraitSummary: Codable, Sendable, Equatable {
  public let schema: String
  public let engines: [EngineAdapter]
  public let dimensions: [TraitEvaluationDimension]
  public let modelTraits: [ModelTrait]

  public init(
    schema: String = "TatwoEngineTraitSummaryV1",
    engines: [EngineAdapter],
    dimensions: [TraitEvaluationDimension],
    modelTraits: [ModelTrait]
  ) {
    self.schema = schema
    self.engines = engines
    self.dimensions = dimensions
    self.modelTraits = modelTraits
  }
}

public enum TatwoMCPRegistry {
  public static let clientEntrypoints: [TatwoMCPEngineEntrypoint] = [
    TatwoMCPEngineEntrypoint(
      engine: .codex,
      label: "Codex App / Codex CLI",
      command: "node",
      args: ["<repo>/scripts/tatwo-ultrawork-mcp.mjs"],
      canCallFromCLI: true,
      requiresCodexHost: false,
      plainPurpose: "Codex 是最高適配 host，但只是其中一個 MCP client；它可以用 App/MCP 取得模式、身份、收據與工作流。"),
    TatwoMCPEngineEntrypoint(
      engine: .claudeCLI,
      label: "Claude CLI / other MCP client",
      command: "node",
      args: ["<repo>/scripts/tatwo-ultrawork-mcp.mjs"],
      canCallFromCLI: true,
      requiresCodexHost: false,
      plainPurpose: "其他 CLI 也能接同一個 Tatwo MCP；預設只拿計畫與驗收規則，不取得主機寫入權。"),
    TatwoMCPEngineEntrypoint(
      engine: .localModel,
      label: "Generic CLI fallback",
      command: "tatwo-ultrawork",
      args: ["mcp", "call", "tatwo.mcp.manifest", "--json"],
      canCallFromCLI: true,
      requiresCodexHost: false,
      plainPurpose: "沒有長駐 MCP client 時，CLI 仍可直接呼叫同一套 core schema。"),
  ]

  private static let staticTools: [TatwoMCPToolDefinition] = [
    TatwoMCPToolDefinition(
      name: "tatwo.mcp.manifest",
      plainPurpose: "回傳 engine-agnostic App/CLI/MCP manifest；說明 Codex 只是最高適配 host，不是唯一入口。",
      returnsSchema: "TatwoMCPServerManifestV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.mcp.client_config",
      plainPurpose: "輸出可給 Codex、Claude CLI 或 generic MCP client 使用的啟動設定與 CLI fallback。",
      optionalArguments: ["engine"],
      returnsSchema: "TatwoMCPClientConfigV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.engine.capabilities",
      plainPurpose: "查某個 engine 能做什麼、不能做什麼；避免把 Codex 當唯一引擎。",
      optionalArguments: ["engine"],
      returnsSchema: "EngineAdapter"),
    TatwoMCPToolDefinition(
      name: "tatwo.identities.list",
      plainPurpose: "列出核心身份組：主導、監督、顧問、sub、消息、驗收。",
      returnsSchema: "[IdentityDefinition]"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.get",
      plainPurpose: "取得情境 profile；不帶 id 時列出全部。",
      optionalArguments: ["scenario"],
      returnsSchema: "ScenarioProfile | [ScenarioProfile]"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.agents",
      plainPurpose: "輸出某情境的 agents.md 風格身份配置。",
      optionalArguments: ["scenario"],
      returnsSchema: "ScenarioProfile"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config",
      plainPurpose: "讀取 Dashboard staging scenario config；agents 依這份身份組/模型綁定，不自己猜分工。",
      optionalArguments: ["stage"],
      returnsSchema: "TatwoScenarioConfigBookV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config.add",
      plainPurpose: "新增 staging 自定義情境；只寫 OS staging config，不升 active、不碰 Codex App bundle。",
      optionalArguments: ["displayName", "baseScenario"],
      returnsSchema: "TatwoScenarioConfigMutationResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config.duplicate",
      plainPurpose: "複製內建或自定義情境成可編輯 staging 情境；內建原件保持保護。",
      requiredArguments: ["scenario"],
      returnsSchema: "TatwoScenarioConfigMutationResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config.rename",
      plainPurpose: "改名 staging 自定義情境；內建情境 fail closed。",
      requiredArguments: ["scenario", "displayName"],
      returnsSchema: "TatwoScenarioConfigMutationResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config.delete",
      plainPurpose: "刪除 staging 自定義情境；內建情境 fail closed。",
      requiredArguments: ["scenario"],
      returnsSchema: "TatwoScenarioConfigMutationResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config.update_token_budget",
      plainPurpose: "更新 staging 情境某個 S/M/L/XL 的 token/gate 說明；正式 goal 不因此設固定次數。",
      requiredArguments: ["scenario", "mode", "tokenBudget"],
      returnsSchema: "TatwoScenarioConfigMutationResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config.set_binding_models",
      plainPurpose: "更新 staging 情境某個身份組綁定模型；身份組仍是 OS 主體，模型可替換。",
      requiredArguments: ["scenario", "mode", "bindingID", "modelIDs"],
      returnsSchema: "TatwoScenarioConfigMutationResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.config.update_binding_responsibility",
      plainPurpose: "更新 staging 情境身份組責任描述，讓 agents.md / Work OS contract 讀到同一份分工語意。",
      requiredArguments: ["scenario", "mode", "bindingID", "responsibility"],
      returnsSchema: "TatwoScenarioConfigMutationResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.plugin_registry.list",
      plainPurpose: "讀取 Plugins 分頁唯一 registry 真相源；Scenario 編輯器與工作筐 chips 只能消費這份清單。",
      optionalArguments: ["stage"],
      returnsSchema: "TatwoPluginRegistryBookV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.capabilities.status",
      plainPurpose: "列出 Tatwo canonical skills/plugins roots、可用 skills 與 provider import roots；Codex 只是一個 import provider。",
      returnsSchema: "TatwoCapabilityStatusV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.capabilities.bootstrap",
      plainPurpose: "在 Work OS contract 下把 allowlisted skill 匯入 Tatwo canonical root；不覆蓋既有 canonical skill。",
      requiredArguments: ["contractID"],
      optionalArguments: ["names"],
      returnsSchema: "TatwoCapabilityBootstrapReceiptV1",
      hostMutationAllowed: true),
    TatwoMCPToolDefinition(
      name: "tatwo.context.policy",
      plainPurpose: "回傳 Ultrawork 自研 Headroom-style context 壓縮策略：可逆、本地 cache、敏感內容 fail-closed、shareable 摘要 redaction。",
      returnsSchema: "TatwoContextCompressionPolicyV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.context.compress",
      plainPurpose: "在 Work OS contract 內壓縮長 tool output/log/RAG/code/text，保留可 retrieve 原文 cache 與壓縮收據；不直接改主專案。",
      requiredArguments: ["contractID", "text"],
      optionalArguments: ["kind", "sourceLabel", "runID", "maxCompressedCharacters", "cacheOriginal"],
      returnsSchema: "TatwoContextCompressionReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.context.retrieve",
      plainPurpose: "用 context receipt id 取回本機 cache 原文；需要 contractID，供 verifier 回查，摘要不可取代原始收據。",
      requiredArguments: ["contractID", "id"],
      optionalArguments: ["runID"],
      returnsSchema: "TatwoContextRetrieveResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.context.stats",
      plainPurpose: "彙總本機 context-cache 節省量；只讀統計，不輸出原文。",
      returnsSchema: "TatwoContextCompressionStatsV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.scenario.workflow",
      plainPurpose: "相容入口：依情境 profile + S/M/L/XL 產生身份組、loop、收據與禁止事項；內部以 Work OS contract 為真相來源。",
      optionalArguments: ["mode", "scenario", "objective"],
      returnsSchema: "ScenarioWorkflowContract"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.begin",
      plainPurpose: "以明確 provider、workspace 與 ownerSession/ownerThread one-of 建立新的 formal Work OS authority transaction；不接受 existing ID、不隱式 bootstrap locks，也不可用來修復 current-session。",
      requiredArguments: ["provider", "workspace", "stateRoot"],
      optionalArguments: [
        "mode", "scenario", "objective", "ownerSession", "ownerThread",
      ],
      returnsSchema: "TatwoWorkOSContractV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.goal.candidate.create",
      plainPurpose: "只消費 exact authorization-binding artifact bytes 與其 SHA-256，在所有 Goal lock/write 前驗證 live scenario、contract、identity 與 target absence，才於 GoalRun store 建立一個 fresh planned candidate；deterministic ID 已存在即 fail closed，且不寫 dispatch registry、current-session、thread、promotion 或 supersession。",
      requiredArguments: [
        "mode",
        "scenario",
        "objective",
        "authorizationBindingArtifactSHA256",
        "authorizationBindingArtifactJSON",
      ],
      returnsSchema: "TatwoGoalCandidateCreateOnlyResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.session.attach",
      plainPurpose: "以明確 provider、absolute workspace 與 ownerSession/ownerThread one-of 驗證 V3 canonical owner 後，只讀接回 current-session 指向的 exact canonical GoalRun；任何 mismatch 都 fail closed，絕不呼叫 begin。",
      requiredArguments: ["provider", "workspace"],
      optionalArguments: [
        "ownerSession", "ownerThread", "contractID", "goalID", "mode",
        "scenario", "objective",
      ],
      returnsSchema: "TatwoSessionAttachmentV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.session.revise",
      plainPurpose: "只能消費可信 human-gate issuer 已核發的一次性 Goal revision authorization；exact predecessor、successor、pointer 與 human-gate expectations 全由該授權綁定。此工具不簽發任何 App／host／recovery 授權；無可驗 issuer 時 human_gate_unavailable。",
      requiredArguments: ["authorizationID"],
      returnsSchema: "TatwoGoalRevisionPromotionResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.next",
      plainPurpose: "依 goal/contract 取得下一步，避免 agent 自己猜流程。",
      requiredArguments: ["contractID"],
      optionalArguments: ["goalID", "mode", "scenario", "objective"],
      returnsSchema: "TatwoWorkOSNextActionV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.loop.status",
      plainPurpose: "查 mainline / domain loops 的只讀狀態；App 可視化不可直接放行。",
      requiredArguments: ["contractID"],
      optionalArguments: ["goalID", "mode", "scenario", "objective"],
      returnsSchema: "TatwoWorkOSLoopStatusReportV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.receipt.submit",
      plainPurpose: "提交測試、截圖、review、sandbox receipt；缺 contractID 或 receiptID 直接 fail closed。",
      requiredArguments: ["contractID", "receiptID"],
      optionalArguments: ["goalID", "loopID", "receiptKind"],
      returnsSchema: "TatwoWorkOSReceiptSubmissionResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.goal.close",
      plainPurpose: "只有 required receipts 足夠時才可 pass；不足則 rollback_required。",
      requiredArguments: ["contractID", "receiptIDs"],
      optionalArguments: ["goalID", "mode", "scenario", "objective"],
      returnsSchema: "TatwoWorkOSGoalCloseResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.dashboard",
      plainPurpose: "回傳真正的 Work OS dashboard snapshot：goal、contract、mainline/domain loops、身份組、工具、沙盒、receipts、READY/ROLLBACK；只讀不可放行。",
      optionalArguments: ["mode", "scenario", "objective", "receiptIDs"],
      returnsSchema: "TatwoWorkOSDashboardSnapshotV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.enforce",
      plainPurpose: "檢查 agent action 是否符合 OS contract；缺 contractID、未登記工具、host mutation、visualizer pass 都 fail closed。",
      requiredArguments: ["contractID", "toolName"],
      optionalArguments: ["mode", "scenario", "objective", "identity", "mutation", "surface", "receiptID"],
      returnsSchema: "TatwoWorkOSEnforcementDecisionV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.handoff",
      plainPurpose: "輸出 agents.md / tools.md / receipts.md 風格 handoff pack，讓外部 agents 依 OS 做事而不是自行猜分工。",
      optionalArguments: ["mode", "scenario", "objective"],
      returnsSchema: "TatwoWorkOSHandoffPackV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.os.constitution",
      plainPurpose: "輸出 Work OS constitution：agents、tools、receipts 與硬規則。",
      returnsSchema: "TatwoWorkOSConstitutionV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.gateway.status",
      plainPurpose: "查本機 model-gateway 狀態；供 Claude/Fable/Codex 在 contract 內確認可否召喚 GPT/Grok/MiniMax 等文字 submodel。",
      optionalArguments: ["includeRaw"],
      returnsSchema: "TatwoGatewayStatusReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.gateway.models",
      plainPurpose: "列出 gateway 可見模型與 TATWO dispatch allowlist；不授權 host mutation。",
      optionalArguments: ["allowedOnly"],
      returnsSchema: "TatwoGatewayModelsReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.gateway.dispatch",
      plainPurpose: "contract-bound 單模型文字 dispatch；外部 lead/supervisor 可召喚 submodel，但不能寫主機、不能帶 secrets、不能執行交易/刪檔。",
      requiredArguments: ["contractID", "model", "prompt"],
      optionalArguments: ["goalID", "identity", "purpose", "dryRun", "allowExpensive"],
      returnsSchema: "TatwoGatewayDispatchReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.gateway.fanout",
      plainPurpose: "contract-bound 多模型 fan-out；每個 child receipt 仍是文字建議，Codex host 才能實際改檔/測試/部署。",
      requiredArguments: ["contractID", "models", "prompt"],
      optionalArguments: ["goalID", "identity", "purpose", "dryRun", "allowExpensive", "maxFanout"],
      returnsSchema: "TatwoGatewayFanoutReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox.begin",
      plainPurpose: "建立 contract-bound 路徑隔離沙盒；Claude/Fable 可在沙盒內寫 artifacts，但不能寫主專案。",
      requiredArguments: ["contractID"],
      optionalArguments: ["goalID", "objective", "sandboxID"],
      returnsSchema: "TatwoSandboxSessionReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox.write_artifact",
      plainPurpose: "只在指定 TATWO 沙盒內寫 artifact；拒絕 path escape、控制檔、auth/session-like 內容。",
      requiredArguments: ["contractID", "sandboxID", "relativePath", "content"],
      optionalArguments: ["maxBytes"],
      returnsSchema: "TatwoSandboxArtifactReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox.run_command",
      plainPurpose: "只在指定 TATWO 沙盒內執行 allowlisted command；環境清理且 HOME 指向沙盒 home。",
      requiredArguments: ["contractID", "sandboxID", "command"],
      optionalArguments: ["args", "timeoutMS"],
      returnsSchema: "TatwoSandboxCommandReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox.receipt",
      plainPurpose: "彙整沙盒 artifacts/logs/receipts；作為 promotion 前的 evidence，不等於直接放行。",
      requiredArguments: ["contractID", "sandboxID"],
      returnsSchema: "TatwoSandboxReceiptBundleV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox.promote_plan",
      plainPurpose: "輸出沙盒成果進主機前的 plan-only checklist；永遠不直接 promote。",
      requiredArguments: ["contractID", "sandboxID"],
      optionalArguments: ["targetHint"],
      returnsSchema: "TatwoSandboxPromotePlanV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.host.plan",
      plainPurpose: "回傳 Tatwo 自有 Host Executor 的安全、路徑與 rollback 規則；只讀，不會在此要求使用者再次授權。",
      returnsSchema: "TatwoHostExecutorPlanV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.host.authorize_revision",
      plainPurpose: "消費 App 已核發且綁定目前 Goal revision、精確 action/arguments、workspace/output roots 與資源上限的 HostOperationAuthorization，換取短效執行許可；不簽發人類授權。",
      requiredArguments: ["authorizationID"],
      returnsSchema: "TatwoHostApprovalLeaseV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.host.read_file",
      plainPurpose: "以目前工作階段已確認的執行許可讀取 workspace 內檔案。",
      requiredArguments: ["contractID", "leaseID", "workspaceRoot", "relativePath"],
      returnsSchema: "TatwoHostExecutionReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.host.write_file",
      plainPurpose: "以目前工作階段已確認的執行許可寫入 workspace 檔案，並先建立 rollback backup。",
      requiredArguments: ["contractID", "leaseID", "workspaceRoot", "relativePath", "content"],
      returnsSchema: "TatwoHostExecutionReceiptV1",
      hostMutationAllowed: true),
    TatwoMCPToolDefinition(
      name: "tatwo.host.run_command",
      plainPurpose: "以目前工作階段已確認的執行許可執行 allowlisted executable + argv；不接受 shell command string。",
      requiredArguments: ["contractID", "leaseID", "workspaceRoot", "executable"],
      optionalArguments: ["arguments", "timeoutSeconds"],
      returnsSchema: "TatwoHostExecutionReceiptV1",
      hostMutationAllowed: true),
    TatwoMCPToolDefinition(
      name: "tatwo.host.rollback",
      plainPurpose: "用原 write receipt 與已確認的 rollback 許可還原既有檔案或移除本次新建檔案。",
      requiredArguments: ["contractID", "leaseID", "workspaceRoot", "writeReceipt"],
      returnsSchema: "TatwoHostExecutionReceiptV1",
      hostMutationAllowed: true),
    TatwoMCPToolDefinition(
      name: "tatwo.computer.status",
      plainPurpose: "檢查 Tatwo-native macOS Computer Host 與 Accessibility/Screen Recording 權限；不依賴 Codex Tool Host。",
      returnsSchema: "TatwoComputerHostStatusV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.browser.read_sanitized",
      plainPurpose: "只透過 CEF DOMSnapshot sanitizer 讀取目前 committed 主框架可見文字；輸出 untrusted_web envelope，不回 raw DOM、AX、OCR、截圖、cookie、storage 或表單值。",
      returnsSchema: "TatwoUntrustedPageEnvelopeV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.browser.plan_actions",
      plainPurpose: "將 agent 的 elementID 動作凍結成綁定 snapshot hash、origin、navigation generation、expiry 與 nonce 的 typed plan；不執行。",
      requiredArguments: ["snapshotHash", "actions"],
      returnsSchema: "TatwoBrowserTypedPlanTokenV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.browser.execute_approved_plan",
      plainPurpose: "只執行已由人類 UI 核准且仍綁定目前 snapshot 的下一個 typed browser action；漂移即 stale_snapshot。",
      requiredArguments: ["approvedPlanToken", "workspaceRoot"],
      returnsSchema: "TatwoBrowserApprovedActionReceiptV1",
      hostMutationAllowed: true),
    TatwoMCPToolDefinition(
      name: "tatwo.computer.execute",
      plainPurpose: "依目前工作階段已確認的 UI 操作許可，執行單一明確 action。",
      requiredArguments: ["contractID", "leaseID", "workspaceRoot", "action"],
      optionalArguments: ["value"],
      returnsSchema: "TatwoComputerHostReceiptV1",
      hostMutationAllowed: true),
    TatwoMCPToolDefinition(
      name: "tatwo.web_arena.plan",
      plainPurpose: "建立 TATWO Web Arena v1 三類網頁評分沙盒計畫：刺青、3D 資產收納、Pionex-style；只規劃，不執行模型 fan-out。",
      optionalArguments: ["suite", "runID", "models"],
      returnsSchema: "TatwoWebArenaPlanV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.web_arena.report",
      plainPurpose: "讀取指定 Web Arena run 的本地評分報告並彙總；不重新評分、不刪檔。",
      requiredArguments: ["runID"],
      returnsSchema: "TatwoWebArenaRunSummaryV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.web_arena.cleanup_plan",
      plainPurpose: "列出可清理的網頁設計沙盒 run；MCP 只做 dry-run cleanup plan，不直接刪檔。",
      optionalArguments: ["olderThan", "dryRun"],
      returnsSchema: "TatwoWebArenaCleanupPlanV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox_arena.list",
      plainPurpose: "列出除 Web Arena 外的缺失評分沙盒：代碼架構、Debug、研究、多模態、Plugin/MCP、文筆、3D 建模。",
      returnsSchema: "TatwoSandboxArenaDefinitionV1[]"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox_arena.plan",
      plainPurpose: "建立缺失評分沙盒 v1 計畫；只規劃，不執行模型 fan-out，也不自動啟動 Blender / UE5.8。",
      optionalArguments: ["arena", "runID", "models"],
      returnsSchema: "TatwoSandboxArenaPlanV1 or TatwoSandboxArenaCollectionPlanV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.sandbox_arena.report",
      plainPurpose: "讀取指定缺失評分沙盒 run 的本地 scaffold/report summary；不重新評分、不刪檔。",
      requiredArguments: ["arena", "runID"],
      returnsSchema: "TatwoSandboxArenaRunSummaryV1[]"),
    TatwoMCPToolDefinition(
      name: "tatwo.arena.plan_loop_goal.policy",
      plainPurpose: "回傳所有評分沙盒共用的 plan+loops+goal 主線 / 支線、沙盒五巡迴、工具 registry 選用規則。",
      returnsSchema: "TatwoArenaPlanLoopGoalProtocolV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.arena.plan_loop_goal.score",
      plainPurpose: "所有 sandbox 測試完成後，才計算模型的 Plan+Loops+Goal 分數；未完成、未封存或 sealed 後變更都 fail closed。",
      optionalArguments: [
        "modelSlug", "expectedSandboxTests", "completedSandboxTests", "missingSandboxTests",
        "goalExecutionCycles", "finalSubmissionSealed", "fileHashesChangedAfterSeal",
        "presentArtifacts", "toolChoicesAllRegistered",
      ],
      returnsSchema: "TatwoArenaPlanLoopGoalScoreReportV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.arena.goal_cycle.assess",
      plainPurpose: "依 goal 已用實作巡迴數、封存狀態與 hash 是否變更，判斷是否可繼續或必須進評分。",
      optionalArguments: ["goalExecutionCycles", "finalSubmissionSealed", "fileHashesChangedAfterSeal"],
      returnsSchema: "TatwoArenaGoalCycleAssessmentV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.web_check.preflight",
      plainPurpose: "檢查本地 web-check / 前端健檢是否可用，回傳 429 rule parity 與 local-only 安全規則。",
      returnsSchema: "TatwoWebCheckPreflightV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.web_check.plan",
      plainPurpose: "依 mode/scenario/target 產生 web-check 驗收計畫；只規劃本地 scan，不自動修檔或部署。",
      optionalArguments: ["mode", "scenario", "target", "scanType", "blockingPolicy"],
      returnsSchema: "TatwoWebCheckPlanV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.web_check.import_receipt",
      plainPurpose:
        "匯入 local JSON report 為 TatwoWebCheckReceiptV1；缺 contractID 或 reportJSON 直接 fail closed。",
      requiredArguments: ["contractID", "reportJSON"],
      optionalArguments: ["goalID", "targetKind", "scanType", "blockingPolicy", "command"],
      returnsSchema: "TatwoWebCheckImportResultV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.web_check.receipt_template",
      plainPurpose: "回傳 web-check receipt 模板，供外部 agent 知道該提交哪些欄位。",
      requiredArguments: ["contractID"],
      optionalArguments: ["goalID", "targetKind", "scanType", "blockingPolicy"],
      returnsSchema: "TatwoWebCheckReceiptV1"),
    TatwoMCPToolDefinition(
      name: "tatwo.traits.list",
      plainPurpose: "列出 engine/model 特質評分模板與現有模型特質。",
      returnsSchema: "EngineTraitSummary"),
    TatwoMCPToolDefinition(
      name: "tatwo.mode.plan",
      plainPurpose: "依 S/M/L/XL 產生身份組、預算、收據與停止條件。",
      optionalArguments: ["mode", "scenario"],
      returnsSchema: "ModeIdentityPlan"),
    TatwoMCPToolDefinition(
      name: "tatwo.ultrawork.topics",
      plainPurpose: "列出 Ultrawork 工作流主題：CLI/MCP、skills、gateway、sandbox、sub/loops、receipts。",
      returnsSchema: "[UltraworkTopic]"),
    TatwoMCPToolDefinition(
      name: "tatwo.workflow.preview",
      plainPurpose: "預覽 workflow graph 與 Mermaid，給 App/CLI/agents 共用。",
      optionalArguments: ["mode", "scenario"],
      returnsSchema: "WorkflowPreviewPayload"),
    TatwoMCPToolDefinition(
      name: "tatwo.receipt.requirements",
      plainPurpose: "查詢當前 mode/scenario 必要收據與 fail-closed gate。",
      optionalArguments: ["mode", "scenario"],
      returnsSchema: "ReceiptRequirementSummary"),
    TatwoMCPToolDefinition(
      name: "tatwo.handoff.pack",
      plainPurpose: "建立可交給其他 engine/CLI 的安全 handoff pack。",
      optionalArguments: ["mode", "scenario", "objective"],
      returnsSchema: "HandoffPack"),
  ]

  public static var tools: [TatwoMCPToolDefinition] {
    staticTools + TatwoMCPDynamicToolRegistry.shared.snapshot()
  }

  public static var manifest: TatwoMCPServerManifest {
    TatwoMCPServerManifest(
      transports: ["stdio", "local-http", "core-library-fallback"],
      plainContract:
        "Tatwo Ultrawork 是 App + CLI + MCP 的多引擎控制層。Codex 目前最適合當 host executor，但 Claude CLI、其他 MCP client、或 generic CLI 也能調用同一份 App MCP schema；沒有安全 host capability 的 engine 只拿計畫/收據/建議，不直接寫主機。",
      clientEntrypoints: clientEntrypoints,
      tools: tools,
      safetyRules: [
        "Codex is the default highest-fit host engine, but Tatwo is engine-agnostic.",
        "MCP tools return plans, identities, workflow previews, receipts, and handoff packs; they do not directly grant host mutation.",
        "External engines without safe host capability are advisory only.",
        "No raw logs, tokens, full chats, private paths, or local screenshots in shareable payloads.",
      ])
  }

  public static func call(tool: String, arguments: [String: JSONValue] = [:])
    -> TatwoMCPToolCallResult
  {
    call(
      tool: tool,
      arguments: arguments,
      goalCandidateStoreOverride: nil,
      goalCandidateScenarioBookOverride: nil)
  }

  /// Test-only seam for the create-only Goal candidate route. All other tools,
  /// and the public production entrypoint above, retain their existing stores.
  static func call(
    tool: String,
    arguments: [String: JSONValue],
    goalCandidateStoreOverride: TatwoGoalRunStore?,
    goalCandidateScenarioBookOverride: TatwoScenarioConfigBookV1?
  ) -> TatwoMCPToolCallResult {
    do {
      let canonicalTool = canonicalToolName(tool)
      let payload: JSONValue
      switch canonicalTool {
      case "tatwo.mcp.manifest":
        payload = try JSONValue.fromEncodable(manifest)
      case "tatwo.mcp.client_config":
        let engine = stringArg("engine", arguments) ?? "generic-cli"
        payload = try JSONValue.fromEncodable(clientConfig(for: engine))
      case "tatwo.engine.capabilities":
        let raw = stringArg("engine", arguments) ?? EngineID.codex.rawValue
        let engineID = EngineID(rawValue: raw)
        guard let engine = TatwoIdentityCatalog.engine(engineID) else {
          return failure(tool: tool, error: "unknown_engine:\(raw)")
        }
        payload = try JSONValue.fromEncodable(engine)
      case "tatwo.identities.list":
        payload = try JSONValue.fromEncodable(TatwoIdentityCatalog.identityDefinitions)
      case "tatwo.scenario.get":
        if let scenario = stringArg("scenario", arguments),
          let profile = TatwoIdentityCatalog.scenarioProfile(scenario)
        {
          payload = try JSONValue.fromEncodable(profile)
        } else {
          payload = try JSONValue.fromEncodable(TatwoIdentityCatalog.scenarioProfiles)
        }
      case "tatwo.scenario.agents":
        let scenario = stringArg("scenario", arguments) ?? "ui-ux"
        guard let profile = TatwoIdentityCatalog.scenarioProfile(scenario) else {
          return failure(tool: tool, error: "unknown_scenario:\(scenario)")
        }
        payload = try JSONValue.fromEncodable(profile)
      case "tatwo.scenario.config":
        payload = try JSONValue.fromEncodable(TatwoScenarioConfigStore.loadDefaultStaging())
      case "tatwo.scenario.config.add":
        let displayName = stringArg("displayName", arguments) ?? stringArg("name", arguments) ?? "自定義情境"
        let baseScenario = stringArg("baseScenario", arguments).flatMap { try? ScenarioID.parse($0) }
        payload = try JSONValue.fromEncodable(
          try applyScenarioConfigMutation(contractID: contractIDArg(arguments)) { book in
            try TatwoScenarioConfigMutator.addCustomScenario(
              to: book,
              displayName: displayName,
              baseScenario: baseScenario)
          })
      case "tatwo.scenario.config.duplicate":
        let scenario = stringArg("scenario", arguments) ?? stringArg("scenarioID", arguments) ?? "daily"
        payload = try JSONValue.fromEncodable(
          try applyScenarioConfigMutation(contractID: contractIDArg(arguments)) { book in
            try TatwoScenarioConfigMutator.duplicateScenario(in: book, scenarioID: scenario)
          })
      case "tatwo.scenario.config.rename":
        guard let scenario = stringArg("scenario", arguments) ?? stringArg("scenarioID", arguments),
          let displayName = stringArg("displayName", arguments) ?? stringArg("name", arguments)
        else {
          return failure(tool: tool, error: "missing_required:scenario,displayName")
        }
        payload = try JSONValue.fromEncodable(
          try applyScenarioConfigMutation(contractID: contractIDArg(arguments)) { book in
            try TatwoScenarioConfigMutator.renameScenario(
              in: book,
              scenarioID: scenario,
              displayName: displayName)
          })
      case "tatwo.scenario.config.delete":
        guard let scenario = stringArg("scenario", arguments) ?? stringArg("scenarioID", arguments) else {
          return failure(tool: tool, error: "missing_required:scenario")
        }
        payload = try JSONValue.fromEncodable(
          try applyScenarioConfigMutation(contractID: contractIDArg(arguments)) { book in
            try TatwoScenarioConfigMutator.deleteScenario(in: book, scenarioID: scenario)
          })
      case "tatwo.scenario.config.update_token_budget":
        guard let scenario = stringArg("scenario", arguments) ?? stringArg("scenarioID", arguments),
          let tokenBudget = stringArg("tokenBudget", arguments) ?? stringArg("budget", arguments)
        else {
          return failure(tool: tool, error: "missing_required:scenario,tokenBudget")
        }
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        payload = try JSONValue.fromEncodable(
          try applyScenarioConfigMutation(contractID: contractIDArg(arguments)) { book in
            try TatwoScenarioConfigMutator.updateTokenBudget(
              in: book,
              scenarioID: scenario,
              mode: mode,
              tokenBudget: tokenBudget)
          })
      case "tatwo.scenario.config.set_binding_models":
        guard let scenario = stringArg("scenario", arguments) ?? stringArg("scenarioID", arguments),
          let bindingID = stringArg("bindingID", arguments) ?? stringArg("binding", arguments)
        else {
          return failure(tool: tool, error: "missing_required:scenario,bindingID")
        }
        let modelIDs = stringArrayArg("modelIDs", arguments).isEmpty
          ? stringArrayArg("models", arguments)
          : stringArrayArg("modelIDs", arguments)
        guard arguments["modelIDs"] != nil || arguments["models"] != nil else {
          return failure(tool: tool, error: "missing_required:modelIDs")
        }
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        payload = try JSONValue.fromEncodable(
          try applyScenarioConfigMutation(contractID: contractIDArg(arguments)) { book in
            try TatwoScenarioConfigMutator.setBindingModels(
              in: book,
              scenarioID: scenario,
              mode: mode,
              bindingID: bindingID,
              modelIDs: modelIDs)
          })
      case "tatwo.scenario.config.update_binding_responsibility":
        guard let scenario = stringArg("scenario", arguments) ?? stringArg("scenarioID", arguments),
          let bindingID = stringArg("bindingID", arguments) ?? stringArg("binding", arguments),
          let responsibility = stringArg("responsibility", arguments)
        else {
          return failure(tool: tool, error: "missing_required:scenario,bindingID,responsibility")
        }
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        payload = try JSONValue.fromEncodable(
          try applyScenarioConfigMutation(contractID: contractIDArg(arguments)) { book in
            try TatwoScenarioConfigMutator.updateBindingResponsibility(
              in: book,
              scenarioID: scenario,
              mode: mode,
              bindingID: bindingID,
              responsibility: responsibility)
          })
      case "tatwo.plugin_registry.list":
        payload = try JSONValue.fromEncodable(TatwoPluginRegistryStore.loadDefaultStaging())
      case "tatwo.capabilities.status":
        payload = try JSONValue.fromEncodable(TatwoCapabilityRegistry.status())
      case "tatwo.capabilities.bootstrap":
        let contractID = contractIDArg(arguments) ?? ""
        let gate = TatwoWorkOSChokepoint.authorize(
          contractID: contractID,
          action: "tatwo.capabilities.bootstrap",
          store: TatwoGoalRunStore.default())
        guard gate.ok else { return failure(tool: tool, error: gate.message) }
        let names = stringArrayArg("names", arguments)
        payload = try JSONValue.fromEncodable(
          try TatwoCapabilityRegistry.bootstrap(
            names: names.isEmpty ? ["tatwo-ultrawork"] : names))
      case "tatwo.context.policy":
        payload = try JSONValue.fromEncodable(TatwoContextCompressionFactory.policy())
      case "tatwo.context.compress":
        let contractID = contractIDArg(arguments) ?? ""
        let gate = WorkOSFactory.requireContractID(contractID)
        guard gate.ok else {
          return failure(tool: tool, error: gate.message)
        }
        guard let text = stringArg("text", arguments) ?? stringArg("input", arguments) else {
          return failure(tool: tool, error: "missing_required:text")
        }
        let rawKind = stringArg("kind", arguments) ?? "auto"
        guard let kind = TatwoContextCompressionKind(rawValue: rawKind) else {
          return failure(tool: tool, error: "unknown_context_kind:\(rawKind)")
        }
        let policy = TatwoContextCompressionPolicy(
          maxCompressedCharacters: Int(stringArg("maxCompressedCharacters", arguments) ?? "") ?? TatwoContextCompressionPolicy.default.maxCompressedCharacters,
          maxPreservedDiagnosticLines: Int(stringArg("maxPreservedDiagnosticLines", arguments) ?? "") ?? TatwoContextCompressionPolicy.default.maxPreservedDiagnosticLines,
          maxLineCharacters: Int(stringArg("maxLineCharacters", arguments) ?? "") ?? TatwoContextCompressionPolicy.default.maxLineCharacters,
          cacheOriginal: arguments["cacheOriginal"] == nil ? true : boolArg("cacheOriginal", arguments),
          failOnSensitiveContent: arguments["failOnSensitiveContent"] == nil ? true : boolArg("failOnSensitiveContent", arguments),
          redactShareableOutput: arguments["redactShareableOutput"] == nil ? true : boolArg("redactShareableOutput", arguments))
        payload = try JSONValue.fromEncodable(
          try TatwoContextCompressionFactory.compress(
            text: text,
            kind: kind,
            sourceLabel: stringArg("sourceLabel", arguments) ?? stringArg("source", arguments) ?? "mcp-context",
            runID: stringArg("runID", arguments) ?? stringArg("run", arguments) ?? contractID,
            root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            policy: policy))
      case "tatwo.context.retrieve":
        let contractID = contractIDArg(arguments) ?? ""
        let gate = WorkOSFactory.requireContractID(contractID)
        guard gate.ok else {
          return failure(tool: tool, error: gate.message)
        }
        guard let id = stringArg("id", arguments) else {
          return failure(tool: tool, error: "missing_required:id")
        }
        payload = try JSONValue.fromEncodable(
          try TatwoContextCompressionFactory.retrieve(
            id: id,
            root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            runID: stringArg("runID", arguments) ?? stringArg("run", arguments) ?? contractID))
      case "tatwo.context.stats":
        payload = try JSONValue.fromEncodable(
          try TatwoContextCompressionFactory.stats(
            root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)))
      case "tatwo.scenario.workflow":
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenario = stringArg("scenario", arguments) ?? "ui-ux"
        let objective = stringArg("objective", arguments) ?? "Tatwo scenario workflow"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        payload = try JSONValue.fromEncodable(
          ScenarioWorkflowContractFactory.make(
            mode: mode,
            scenarioProfileID: scenario,
            objective: objective,
            scenarioBook: scenarioBook))
      case "tatwo.os.begin":
        guard
          let provider = nonemptyStringArg("provider", arguments),
          let workspace = nonemptyStringArg("workspace", arguments),
          let rawStateRoot = nonemptyStringArg("stateRoot", arguments),
          rawStateRoot.hasPrefix("/")
        else {
          return failure(
            tool: tool,
            error: "missing_or_invalid_required:provider,workspace,stateRoot")
        }
        let ownerSession = nonemptyStringArg("ownerSession", arguments)
        let ownerThread = nonemptyStringArg("ownerThread", arguments)
        guard (ownerSession == nil) != (ownerThread == nil) else {
          return failure(
            tool: tool,
            error: "exactly_one_required:ownerSession,ownerThread")
        }
        let ownerLocator: TatwoSessionOwnerLocatorV1
        if let ownerThread {
          ownerLocator = .thread(ownerThread)
        } else if let ownerSession {
          ownerLocator = .session(ownerSession)
        } else {
          return failure(
            tool: tool,
            error: "exactly_one_required:ownerSession,ownerThread")
        }
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenario = stringArg("scenario", arguments) ?? "coding"
        let objective = stringArg("objective", arguments) ?? "Tatwo Work OS goal"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let stateRoot = URL(
          fileURLWithPath: rawStateRoot,
          isDirectory: true).standardizedFileURL
        let goalStore = TatwoGoalRunStore(directoryURL: stateRoot)
        let sessionStore = TatwoSessionStore(directoryURL: goalStore.directoryURL)
        let owner = TatwoCanonicalSessionOwnerV1(
          provider: provider,
          locator: ownerLocator,
          workspacePath: workspace)
        // A second begin is not allowed to overwrite the create-only pointer.
        // If the exact owner still has an untouched planned Goal, take the
        // documented supersession route first; every other occupied pointer
        // remains a fail-closed rejection in the authority transaction.
        if let current = try sessionStore.inspectCurrent(
          ownerVerification: .canonicalV3(owner),
          goalStore: goalStore)
        {
          _ = try sessionStore.supersedePristinePlannedCurrent(
            ownerVerification: .canonicalV3(owner),
            expectedContractID: current.contract.contractID,
            expectedGoalID: current.contract.goalID,
            expectedMode: current.contract.mode,
            expectedScenario: current.contract.scenario,
            expectedObjective: current.contract.objective,
            scenarioBook: scenarioBook,
            goalStore: goalStore)
        }
        payload = try JSONValue.fromEncodable(
          WorkOSFactory.beginCanonical(
            mode: mode,
            scenarioProfileID: scenario,
            objective: objective,
            scenarioBook: scenarioBook,
            store: goalStore,
            registry: TatwoDispatchRegistry(
              directoryURL: goalStore.directoryURL),
            sessionStore: sessionStore,
            owner: owner).contract)
      case "tatwo.os.goal.candidate.create":
        guard
          let rawMode = stringArg("mode", arguments),
          let scenario = stringArg("scenario", arguments),
          let objective = stringArg("objective", arguments),
          let authorizationBindingArtifactSHA256 =
            stringArg("authorizationBindingArtifactSHA256", arguments),
          let authorizationBindingArtifactJSON =
            stringArg("authorizationBindingArtifactJSON", arguments)
        else {
          return failure(
            tool: tool,
            error:
              "missing_required:mode,scenario,objective,authorizationBindingArtifactSHA256,authorizationBindingArtifactJSON")
        }
        let mode = try WorkModeID.parse(rawMode)
        let scenarioEvidence: TatwoScenarioConfigReadOnlyEvidenceV1
        if let goalCandidateScenarioBookOverride {
          scenarioEvidence = try TatwoScenarioConfigReadOnlyEvidenceV1
            .projectedOverride(goalCandidateScenarioBookOverride)
        } else {
          scenarioEvidence =
            try TatwoScenarioConfigStore.loadDefaultStagingStrictReadOnlyEvidence()
        }
        payload = try JSONValue.fromEncodable(
          WorkOSFactory.createGoalCandidateOnly(
            mode: mode,
            scenarioProfileID: scenario,
            objective: objective,
            authorizationBindingArtifactSHA256:
              authorizationBindingArtifactSHA256,
            authorizationBindingArtifactJSON:
              authorizationBindingArtifactJSON,
            scenarioConfigSourceKind: scenarioEvidence.sourceKind,
            scenarioConfigRawSHA256: scenarioEvidence.scenarioConfigRawSHA256,
            scenarioBook: scenarioEvidence.book,
            store: goalCandidateStoreOverride ?? TatwoGoalRunStore.default()))
      case "tatwo.os.session.attach":
        guard
          let provider = nonemptyStringArg("provider", arguments),
          let workspace = nonemptyStringArg("workspace", arguments),
          workspace.hasPrefix("/")
        else {
          return failure(
            tool: tool,
            error: "missing_or_invalid_required:provider,workspace")
        }
        let ownerSession = nonemptyStringArg("ownerSession", arguments)
        let ownerThread = nonemptyStringArg("ownerThread", arguments)
        guard (ownerSession == nil) != (ownerThread == nil) else {
          return failure(
            tool: tool,
            error: "exactly_one_required:ownerSession,ownerThread")
        }
        let ownerLocator: TatwoSessionOwnerLocatorV1
        if let ownerThread {
          ownerLocator = .thread(ownerThread)
        } else if let ownerSession {
          ownerLocator = .session(ownerSession)
        } else {
          return failure(
            tool: tool,
            error: "exactly_one_required:ownerSession,ownerThread")
        }
        let canonicalOwner = TatwoCanonicalSessionOwnerV1(
          provider: provider,
          locator: ownerLocator,
          workspacePath: workspace)
        let expectedMode: WorkModeID?
        if let rawMode = stringArg("mode", arguments) {
          expectedMode = try WorkModeID.parse(rawMode)
        } else {
          expectedMode = nil
        }
        payload = try JSONValue.fromEncodable(
          TatwoSessionStore.default().attachCurrent(
            ownerVerification: .canonicalV3(canonicalOwner),
            expectedContractID: contractIDArg(arguments),
            expectedGoalID: stringArg("goalID", arguments) ?? stringArg("goal", arguments),
            expectedMode: expectedMode,
            expectedScenario: stringArg("scenario", arguments),
            expectedObjective: stringArg("objective", arguments),
            scenarioBook: TatwoScenarioConfigStore.loadDefaultStaging(),
            goalStore: TatwoGoalRunStore.default()))
      case "tatwo.os.session.revise":
        guard
          let authorizationID =
            stringArg("authorizationID", arguments)
            ?? stringArg("authorization", arguments),
          !authorizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return failure(
            tool: tool,
            error:
              "missing_required:authorizationID; consume an externally-issued Goal revision authorization; human_gate_unavailable")
        }
        payload = try JSONValue.fromEncodable(
          TatwoSessionStore.default().transitionCurrentToPlannedRevision(
            authorizationID: authorizationID,
            goalStore: TatwoGoalRunStore.default(),
            dispatchRegistry: TatwoDispatchRegistry.default()))
      case "tatwo.os.next":
        let goalID = stringArg("goalID", arguments)
        let contractID = stringArg("contractID", arguments)
        let inferredContext = WorkOSFactory.inferContext(goalID: goalID, contractID: contractID)
        let mode = try WorkModeID.parse(
          stringArg("mode", arguments) ?? inferredContext?.mode.rawValue ?? "M")
        let scenario =
          stringArg("scenario", arguments) ?? inferredContext?.scenarioProfileID ?? "coding"
        let objective = stringArg("objective", arguments) ?? "Tatwo Work OS goal"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let result = try WorkOSFactory.next(
          goalID: goalID,
          contractID: contractID,
          mode: mode,
          scenarioProfileID: scenario,
          objective: objective,
          scenarioBook: scenarioBook,
          store: TatwoGoalRunStore.default(),
          registry: TatwoDispatchRegistry.default())
        guard result.ok else {
          return failure(tool: tool, error: result.decision.message)
        }
        payload = try JSONValue.fromEncodable(result)
      case "tatwo.os.loop.status":
        let goalID = stringArg("goalID", arguments)
        let contractID = stringArg("contractID", arguments)
        let inferredContext = WorkOSFactory.inferContext(goalID: goalID, contractID: contractID)
        let mode = try WorkModeID.parse(
          stringArg("mode", arguments) ?? inferredContext?.mode.rawValue ?? "M")
        let scenario =
          stringArg("scenario", arguments) ?? inferredContext?.scenarioProfileID ?? "coding"
        let objective = stringArg("objective", arguments) ?? "Tatwo Work OS goal"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let result = try WorkOSFactory.loopStatus(
          goalID: goalID,
          contractID: contractID,
          mode: mode,
          scenarioProfileID: scenario,
          objective: objective,
          scenarioBook: scenarioBook,
          store: TatwoGoalRunStore.default())
        guard result.ok else {
          return failure(tool: tool, error: result.decision.message)
        }
        payload = try JSONValue.fromEncodable(result)
      case "tatwo.os.receipt.submit":
        let result = WorkOSFactory.submitReceipt(
          goalID: stringArg("goalID", arguments),
          contractID: stringArg("contractID", arguments),
          loopID: stringArg("loopID", arguments),
          receiptID: stringArg("receiptID", arguments),
          receiptKind: stringArg("receiptKind", arguments) ?? "generic",
          store: TatwoGoalRunStore.default())
        guard result.ok else {
          return failure(tool: tool, error: result.decision.message)
        }
        payload = try JSONValue.fromEncodable(result)
      case "tatwo.os.goal.close":
        let goalID = stringArg("goalID", arguments)
        let contractID = stringArg("contractID", arguments)
        let inferredContext = WorkOSFactory.inferContext(goalID: goalID, contractID: contractID)
        let mode = try WorkModeID.parse(
          stringArg("mode", arguments) ?? inferredContext?.mode.rawValue ?? "M")
        let scenario =
          stringArg("scenario", arguments) ?? inferredContext?.scenarioProfileID ?? "coding"
        let objective = stringArg("objective", arguments) ?? "Tatwo Work OS goal"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let receiptIDs =
          stringArrayArg("receiptIDs", arguments)
          + stringArrayArg("receiptID", arguments)
        let goalStore = TatwoGoalRunStore.default()
        let result = try WorkOSFactory.closeGoal(
          goalID: goalID,
          contractID: contractID,
          mode: mode,
          scenarioProfileID: scenario,
          objective: objective,
          suppliedReceiptIDs: receiptIDs,
          scenarioBook: scenarioBook,
          store: goalStore,
          dispatchRegistry: TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL))
        guard result.ok else {
          return failure(tool: tool, error: result.decision.message)
        }
        payload = try JSONValue.fromEncodable(result)
      case "tatwo.os.dashboard":
        let contractID = contractIDArg(arguments)
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenario = stringArg("scenario", arguments) ?? "coding"
        let objective = stringArg("objective", arguments) ?? "Tatwo Work OS dashboard"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let receiptIDs =
          stringArrayArg("receiptIDs", arguments)
          + stringArrayArg("receiptID", arguments)
        let storedReceiptIDs =
          contractID.map {
            Array((try? TatwoGoalRunStore.default().submittedReceiptIDs(contractID: $0)) ?? [])
          } ?? []
        let contract = try WorkOSFactory.storedContractProjection(
          contractID: contractID,
          fallbackMode: mode,
          fallbackScenarioProfileID: scenario,
          fallbackObjective: objective,
          scenarioBook: scenarioBook)
        payload = try JSONValue.fromEncodable(
          TatwoWorkOSDashboardFactory.make(
            contract: contract, submittedReceiptIDs: Array(Set(receiptIDs + storedReceiptIDs)),
            registry: TatwoDispatchRegistry.default()))
      case "tatwo.os.enforce":
        let goalID = stringArg("goalID", arguments)
        let contractID = contractIDArg(arguments)
        let inferredContext = WorkOSFactory.inferContext(goalID: goalID, contractID: contractID)
        let mode = try WorkModeID.parse(
          stringArg("mode", arguments) ?? inferredContext?.mode.rawValue ?? "M")
        let scenario =
          stringArg("scenario", arguments) ?? inferredContext?.scenarioProfileID ?? "coding"
        let objective = stringArg("objective", arguments) ?? "Tatwo Work OS goal"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let contract =
          contractID == nil
          ? nil
          : try WorkOSFactory.storedContractProjection(
            contractID: contractID,
            fallbackMode: mode,
            fallbackScenarioProfileID: scenario,
            fallbackObjective: objective,
            scenarioBook: scenarioBook)
        let decision = WorkOSEnforcementFactory.enforce(
          WorkOSAgentActionIntent(
            contractID: contractID,
            identity: identityArg("identity", arguments),
            toolName: stringArg("toolName", arguments) ?? stringArg("tool", arguments) ?? "tatwo.os.next",
            requestedMutation: mutationArg("mutation", arguments),
            sourceSurface: surfaceArg("surface", arguments),
            receiptID: stringArg("receiptID", arguments)),
          contract: contract)
        guard decision.ok else {
          return failure(tool: tool, error: decision.message)
        }
        payload = try JSONValue.fromEncodable(decision)
      case "tatwo.os.handoff":
        let contractID = contractIDArg(arguments)
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenario = stringArg("scenario", arguments) ?? "coding"
        let objective = stringArg("objective", arguments) ?? "Tatwo Work OS handoff"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let contract = try WorkOSFactory.storedContractProjection(
          contractID: contractID,
          fallbackMode: mode,
          fallbackScenarioProfileID: scenario,
          fallbackObjective: objective,
          scenarioBook: scenarioBook)
        payload = try JSONValue.fromEncodable(WorkOSEnforcementFactory.handoffPack(contract: contract))
      case "tatwo.os.constitution":
        payload = try JSONValue.fromEncodable(WorkOSEnforcementFactory.constitution())
      case "tatwo.gateway.status":
        payload = try gatewayStatusPayload(arguments: arguments)
      case "tatwo.gateway.models":
        payload = gatewayModelsPayload(arguments: arguments)
      case "tatwo.gateway.dispatch":
        let dispatch = gatewayDispatchPayload(arguments: arguments)
        guard dispatch.ok else {
          return failure(tool: tool, error: dispatch.error ?? "gateway_dispatch_failed")
        }
        payload = dispatch.payload ?? .null
      case "tatwo.gateway.fanout":
        let fanout = gatewayFanoutPayload(arguments: arguments)
        guard fanout.ok else {
          return TatwoMCPToolCallResult(
            tool: tool,
            ok: false,
            payload: fanout.payload,
            error: fanout.error ?? "gateway_fanout_failed")
        }
        payload = fanout.payload ?? .null
      case "tatwo.sandbox.begin":
        let sandbox = try sandboxBeginPayload(arguments: arguments)
        guard sandbox.ok else {
          return failure(tool: tool, error: sandbox.error ?? "sandbox_begin_failed")
        }
        payload = sandbox.payload ?? .null
      case "tatwo.sandbox.write_artifact":
        let sandbox = try sandboxWriteArtifactPayload(arguments: arguments)
        guard sandbox.ok else {
          return failure(tool: tool, error: sandbox.error ?? "sandbox_write_failed")
        }
        payload = sandbox.payload ?? .null
      case "tatwo.sandbox.run_command":
        let sandbox = try sandboxRunCommandPayload(arguments: arguments)
        guard sandbox.ok else {
          return failure(tool: tool, error: sandbox.error ?? "sandbox_run_failed")
        }
        payload = sandbox.payload ?? .null
      case "tatwo.sandbox.receipt":
        let sandbox = try sandboxReceiptPayload(arguments: arguments)
        guard sandbox.ok else {
          return failure(tool: tool, error: sandbox.error ?? "sandbox_receipt_failed")
        }
        payload = sandbox.payload ?? .null
      case "tatwo.sandbox.promote_plan":
        let sandbox = try sandboxPromotePlanPayload(arguments: arguments)
        guard sandbox.ok else {
          return failure(tool: tool, error: sandbox.error ?? "sandbox_promote_plan_failed")
        }
        payload = sandbox.payload ?? .null
      case "tatwo.host.plan":
        payload = try JSONValue.fromEncodable(TatwoHostExecutorPlanV1())
      case "tatwo.host.authorize_revision":
        guard
          let authorizationID =
            stringArg("authorizationID", arguments)
            ?? stringArg("authorization", arguments),
          !authorizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return failure(
            tool: tool,
            error: "missing_required:authorizationID")
        }
        payload = try JSONValue.fromEncodable(
          try TatwoHostApprovalStore.default().issueHostOperationBound(
            authorizationID: authorizationID,
            sessionStore: TatwoSessionStore.default()))
      case "tatwo.host.read_file":
        guard
          let contractID = contractIDArg(arguments),
          let leaseID = stringArg("leaseID", arguments),
          let workspaceRoot = stringArg("workspaceRoot", arguments),
          let relativePath = stringArg("relativePath", arguments)
        else { return failure(tool: tool, error: "missing_required:host_read") }
        payload = try JSONValue.fromEncodable(
          try TatwoHostExecutor.default().readFile(
            contractID: contractID, leaseID: leaseID, workspaceRoot: workspaceRoot,
            relativePath: relativePath))
      case "tatwo.host.write_file":
        guard
          let contractID = contractIDArg(arguments),
          let leaseID = stringArg("leaseID", arguments),
          let workspaceRoot = stringArg("workspaceRoot", arguments),
          let relativePath = stringArg("relativePath", arguments),
          let content = stringArg("content", arguments)
        else { return failure(tool: tool, error: "missing_required:host_write") }
        payload = try JSONValue.fromEncodable(
          try TatwoHostExecutor.default().writeFile(
            contractID: contractID, leaseID: leaseID, workspaceRoot: workspaceRoot,
            relativePath: relativePath, content: content))
      case "tatwo.host.run_command":
        guard
          let contractID = contractIDArg(arguments),
          let leaseID = stringArg("leaseID", arguments),
          let workspaceRoot = stringArg("workspaceRoot", arguments),
          let executable = stringArg("executable", arguments)
        else { return failure(tool: tool, error: "missing_required:host_run") }
        #if os(macOS)
        let timeout = Double(stringArg("timeoutSeconds", arguments) ?? "120") ?? 120
        payload = try JSONValue.fromEncodable(
          try TatwoHostExecutor.default().runCommand(
            contractID: contractID, leaseID: leaseID, workspaceRoot: workspaceRoot,
            executable: executable, arguments: stringArrayArg("arguments", arguments),
            timeout: timeout))
        #else
        return failure(tool: tool, error: TatwoHostExecutorError.unsupportedPlatform.localizedDescription)
        #endif
      case "tatwo.host.rollback":
        guard
          let contractID = contractIDArg(arguments),
          let leaseID = stringArg("leaseID", arguments),
          let workspaceRoot = stringArg("workspaceRoot", arguments),
          let receiptValue = arguments["writeReceipt"]
        else { return failure(tool: tool, error: "missing_required:host_rollback") }
        let receiptData = try JSONEncoder().encode(receiptValue)
        let writeReceipt = try JSONDecoder().decode(
          TatwoHostExecutionReceiptV1.self, from: receiptData)
        payload = try JSONValue.fromEncodable(
          try TatwoHostExecutor.default().rollback(
            contractID: contractID, leaseID: leaseID, workspaceRoot: workspaceRoot,
            writeReceipt: writeReceipt))
      case "tatwo.computer.status":
        payload = try JSONValue.fromEncodable(TatwoComputerHost.status())
      case "tatwo.browser.read_sanitized",
           "tatwo.browser.plan_actions",
           "tatwo.browser.execute_approved_plan":
        return failure(tool: tool, error: "app_runtime_required")
      case "tatwo.computer.execute":
        guard
          let contractID = contractIDArg(arguments),
          let leaseID = stringArg("leaseID", arguments),
          let workspaceRoot = stringArg("workspaceRoot", arguments),
          let rawAction = stringArg("action", arguments),
          let action = TatwoComputerActionKind(rawValue: rawAction)
        else { return failure(tool: tool, error: "missing_or_invalid_required:computer_execute") }
        #if os(macOS)
        let receipt = try TatwoComputerHost().execute(
          contractID: contractID,
          leaseID: leaseID,
          workspaceRoot: workspaceRoot,
          action: action,
          value: stringArg("value", arguments) ?? "")
        payload = try JSONValue.fromEncodable(receipt)
        _ = try? TatwoHostApprovalStore.default().goalRunStore.appendReceipt(
          contractID: contractID,
          receiptID: "computer-\(UUID().uuidString.lowercased())",
          kind: "computer-host")
        #else
        return failure(tool: tool, error: TatwoHostExecutorError.unsupportedPlatform.localizedDescription)
        #endif
      case "tatwo.web_arena.plan":
        let suite = TatwoWebArenaFactory.suiteFromString(stringArg("suite", arguments))
        let runID = stringArg("runID", arguments) ?? stringArg("run", arguments)
          ?? TatwoWebArenaRuntime.defaultRunID()
        let models = stringArrayArg("models", arguments)
        payload = try JSONValue.fromEncodable(
          TatwoWebArenaFactory.plan(
            suite: suite,
            runID: runID,
            models: models.isEmpty ? TatwoWebArenaFactory.defaultModelSlugs : models))
      case "tatwo.web_arena.report":
        let runID = stringArg("runID", arguments) ?? stringArg("run", arguments) ?? ""
        guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return failure(tool: tool, error: "missing_run_id")
        }
        payload = try JSONValue.fromEncodable(
          try TatwoWebArenaFactory.runSummary(
            root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            runID: runID))
      case "tatwo.web_arena.cleanup_plan":
        let olderThan = TatwoWebArenaRuntime.parseOlderThanDays(
          stringArg("olderThan", arguments) ?? stringArg("older-than", arguments) ?? "14d")
        payload = try JSONValue.fromEncodable(
          try TatwoWebArenaFactory.cleanupPlan(
            root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            olderThanDays: olderThan,
            dryRun: true))
      case "tatwo.sandbox_arena.list":
        payload = try JSONValue.fromEncodable(TatwoSandboxArenaFactory.definitions())
      case "tatwo.sandbox_arena.plan":
        let runID = stringArg("runID", arguments) ?? stringArg("run", arguments)
          ?? TatwoSandboxArenaFactory.defaultRunID()
        let models = stringArrayArg("models", arguments)
        let arenas = TatwoSandboxArenaID.parse(stringArg("arena", arguments))
        if arenas.count == 1, let arena = arenas.first {
          payload = try JSONValue.fromEncodable(
            TatwoSandboxArenaFactory.plan(
              arena: arena,
              runID: runID,
              models: models.isEmpty ? TatwoSandboxArenaFactory.defaultModelSlugs : models))
        } else {
          payload = try JSONValue.fromEncodable(
            TatwoSandboxArenaFactory.collectionPlan(
              arenas: arenas,
              runID: runID,
              models: models.isEmpty ? TatwoSandboxArenaFactory.defaultModelSlugs : models))
        }
      case "tatwo.sandbox_arena.report":
        let runID = stringArg("runID", arguments) ?? stringArg("run", arguments) ?? ""
        guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return failure(tool: tool, error: "missing_run_id")
        }
        let arenas = TatwoSandboxArenaID.parse(stringArg("arena", arguments))
        payload = try JSONValue.fromEncodable(
          try arenas.map {
            try TatwoSandboxArenaFactory.runSummary(
              root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
              arena: $0,
              runID: runID)
          })
      case "tatwo.arena.plan_loop_goal.policy":
        payload = try JSONValue.fromEncodable(
          TatwoArenaPolicyFactory.planLoopGoalProtocol())
      case "tatwo.arena.plan_loop_goal.score":
        let expected = Int(stringArg("expectedSandboxTests", arguments) ?? "0") ?? 0
        let completed = Int(stringArg("completedSandboxTests", arguments) ?? "0") ?? 0
        let cycles = Int(stringArg("goalExecutionCycles", arguments) ?? "0") ?? 0
        payload = try JSONValue.fromEncodable(
          TatwoArenaPolicyFactory.scorePlanLoopGoal(
            modelSlug: stringArg("modelSlug", arguments) ?? "unknown",
            expectedSandboxTests: expected,
            completedSandboxTests: completed,
            missingSandboxTests: stringArrayArg("missingSandboxTests", arguments),
            goalExecutionCycles: cycles,
            finalSubmissionSealed: boolArg("finalSubmissionSealed", arguments),
            fileHashesChangedAfterSeal: boolArg("fileHashesChangedAfterSeal", arguments),
            presentArtifacts: stringArrayArg("presentArtifacts", arguments) + stringArrayArg("artifacts", arguments),
            toolChoicesAllRegistered: boolArg("toolChoicesAllRegistered", arguments)))
      case "tatwo.arena.goal_cycle.assess":
        let cycles = Int(stringArg("goalExecutionCycles", arguments) ?? "0") ?? 0
        let sealed = boolArg("finalSubmissionSealed", arguments)
        let hashChanged = boolArg("fileHashesChangedAfterSeal", arguments)
        payload = try JSONValue.fromEncodable(
          TatwoArenaPolicyFactory.assessGoalCycle(
            goalExecutionCycles: cycles,
            finalSubmissionSealed: sealed,
            fileHashesChangedAfterSeal: hashChanged))
      case "tatwo.web_check.preflight":
        payload = try JSONValue.fromEncodable(TatwoWebCheckFactory.preflight())
      case "tatwo.web_check.plan":
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenario = stringArg("scenario", arguments) ?? "ui-ux"
        let target = stringArg("target", arguments) ?? "<local-frontend-project>"
        let scanType = stringArg("scanType", arguments).flatMap(
          TatwoWebCheckScanType.init(rawValue:))
        let blockingPolicy = stringArg("blockingPolicy", arguments).flatMap(
          TatwoWebCheckBlockingPolicy.init(rawValue:))
        payload = try JSONValue.fromEncodable(
          TatwoWebCheckFactory.plan(
            mode: mode,
            scenarioProfileID: scenario,
            target: target,
            scanType: scanType,
            blockingPolicy: blockingPolicy))
      case "tatwo.web_check.import_receipt":
        guard let reportJSON = stringArg("reportJSON", arguments),
          let reportData = reportJSON.data(using: .utf8)
        else {
          return failure(tool: tool, error: "missing_report_json")
        }
        let result = TatwoWebCheckFactory.importReceipt(
          reportData: reportData,
          reportPath: stringArg("reportPath", arguments) ?? "mcp-report.json",
          contractID: stringArg("contractID", arguments),
          goalID: stringArg("goalID", arguments),
          targetKind: stringArg("targetKind", arguments).flatMap(
            TatwoWebCheckTargetKind.init(rawValue:)) ?? .localProject,
          scanType: stringArg("scanType", arguments).flatMap(TatwoWebCheckScanType.init(rawValue:))
            ?? .full,
          blockingPolicy: stringArg("blockingPolicy", arguments).flatMap(
            TatwoWebCheckBlockingPolicy.init(rawValue:)) ?? .noNewError,
          command: stringArg("command", arguments)
            ?? "./bin/tatwo-frontend-doctor <local-frontend-project> --json --json-compact --blocking none"
        )
        guard result.ok else {
          return failure(tool: tool, error: result.decision.message)
        }
        payload = try JSONValue.fromEncodable(result)
      case "tatwo.web_check.receipt_template":
        let contractID = stringArg("contractID", arguments) ?? ""
        let gate = WorkOSFactory.requireContractID(contractID)
        guard gate.ok else {
          return failure(tool: tool, error: gate.message)
        }
        payload = try JSONValue.fromEncodable(
          TatwoWebCheckFactory.receiptTemplate(
            contractID: contractID,
            goalID: stringArg("goalID", arguments),
            targetKind: stringArg("targetKind", arguments).flatMap(
              TatwoWebCheckTargetKind.init(rawValue:)) ?? .localProject,
            scanType: stringArg("scanType", arguments).flatMap(
              TatwoWebCheckScanType.init(rawValue:)) ?? .full,
            blockingPolicy: stringArg("blockingPolicy", arguments).flatMap(
              TatwoWebCheckBlockingPolicy.init(rawValue:)) ?? .noNewError))
      case "tatwo.traits.list":
        payload = try JSONValue.fromEncodable(
          EngineTraitSummary(
            schema: "TatwoEngineTraitSummaryV1",
            engines: TatwoIdentityCatalog.engines,
            dimensions: TatwoIdentityCatalog.traitDimensions,
            modelTraits: TeamRoutingCatalog.modelTraits))
      case "tatwo.mode.plan":
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenario = stringArg("scenario", arguments)
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        payload = try JSONValue.fromEncodable(
          WorkOSFactory.previewModePlan(
            mode: mode,
            scenarioProfileID: scenario,
            scenarioBook: scenarioBook))
      case "tatwo.ultrawork.topics":
        payload = try JSONValue.fromEncodable(TatwoIdentityCatalog.ultraworkTopics)
      case "tatwo.workflow.preview":
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenarioProfileID = stringArg("scenario", arguments) ?? "coding"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let scenarioContract = try ScenarioWorkflowContractFactory.make(
          mode: mode,
          scenarioProfileID: scenarioProfileID,
          scenarioBook: scenarioBook)
        let processTemplate = WorkflowFactory.make(
          mode: mode,
          scenario: scenarioContract.baseScenario)
        let exactTopology = try JSONValue.fromEncodable(scenarioContract.modePlan)
        let object: [String: JSONValue] = [
          "schema": .string("TatwoWorkflowPreviewPayloadV1"),
          "workflow": exactTopology,
          "workflowKind": .string("exact_identity_topology_preview"),
          "mermaid": .string(identityTopologyMermaid(scenarioContract.modePlan)),
          "modePlan": exactTopology,
          "processTemplate": try JSONValue.fromEncodable(processTemplate),
          "processTemplateMermaid": .string(WorkflowFactory.mermaid(processTemplate)),
          "processTemplateScope": .string("generic_plg_process_not_identity_topology"),
        ]
        payload = .object(object)
      case "tatwo.receipt.requirements":
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenarioProfileID = stringArg("scenario", arguments) ?? "coding"
        let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
        let scenarioContract = try ScenarioWorkflowContractFactory.make(
          mode: mode,
          scenarioProfileID: scenarioProfileID,
          objective: "Tatwo receipt requirements",
          scenarioBook: scenarioBook)
        payload = try JSONValue.fromEncodable(
          ReceiptRequirementSummary(
            mode: mode,
            scenario: scenarioContract.scenarioProfileID,
            receipts: scenarioContract.workOSContract.receiptRequirements.map(\.id),
            gates: scenarioContract.workflowRunPlan.gates,
            failClosedRule: "缺任何必要收據就不宣稱完成；UI 沒截圖時固定回報工程測試通過，UI 尚未驗收。"))
      case "tatwo.handoff.pack":
        let mode = try WorkModeID.parse(stringArg("mode", arguments) ?? "M")
        let scenarioProfileID = stringArg("scenario", arguments) ?? "coding"
        let scenario =
          TatwoIdentityCatalog.scenarioProfile(scenarioProfileID)?.baseScenario ?? .coding
        let objective = stringArg("objective", arguments) ?? "Tatwo Ultrawork handoff"
        payload = try JSONValue.fromEncodable(
          WorkflowRunFactory.makeHandoffPack(objective: objective, mode: mode, scenario: scenario))
      default:
        return failure(tool: tool, error: "unknown_tool:\(tool)", kind: .notFound)
      }
      let hostMutationAllowed =
        tools.first(where: { $0.name == canonicalTool })?.hostMutationAllowed ?? false
      return TatwoMCPToolCallResult(
        tool: tool, ok: true, payload: payload, hostMutationAllowed: hostMutationAllowed)
    } catch {
      let kind = failureKind(for: error)
      let prefix = kind == .internalFailure ? "internal_error:" : "contract_error:"
      return failure(
        tool: tool,
        error: prefix + TatwoPrivacyRedactor.redacted(error.localizedDescription),
        kind: kind)
    }
  }

  static func failureKind(for error: Error) -> TatwoMCPToolFailureKindV1 {
    switch error {
    case is TatwoParseError,
         is TatwoScenarioConfigMutationError,
         is TatwoScenarioConfigReadOnlyLoadError,
         is TatwoPLGError,
         is TatwoGoalRunStoreError,
         is TatwoGoalRunDispatchLifecycleError,
         is TatwoDispatchRegistryError,
         is TatwoPluginRegistryError,
         is TatwoHostExecutorError,
         is TatwoPersistenceError,
         is TatwoContextCompressionError,
         is TatwoSessionAttachmentError,
         is TatwoSessionMutationError,
         is TatwoGoalCandidateCreateOnlyError:
      return .contract
    default:
      return .internalFailure
    }
  }

  private static func failure(
    tool: String,
    error: String,
    kind: TatwoMCPToolFailureKindV1 = .contract
  ) -> TatwoMCPToolCallResult {
    TatwoMCPToolCallResult(
      tool: tool,
      ok: false,
      payload: nil,
      error: TatwoPrivacyRedactor.redacted(error),
      failureKind: kind)
  }

  private static func applyScenarioConfigMutation(
    contractID: String?,
    _ mutate: (TatwoScenarioConfigBookV1) throws -> TatwoScenarioConfigMutationResult
  ) throws -> TatwoScenarioConfigMutationResult {
    // Phase 2: staging-config mutation is a write action, so it must happen inside a
    // registered OS run — the scenario-config file is what the next tatwo.os.begin
    // consumes, so an ungated write would let an agent rewrite the identity
    // bindings/budgets every future contract embeds. #2: authorized via the chokepoint.
    let toll = TatwoWorkOSChokepoint.authorize(
      contractID: contractID, action: "tatwo.scenario.config.mutation")
    guard toll.ok else {
      throw TatwoGoalRunStoreError.unregisteredContract(toll.message)
    }
    let store = TatwoScenarioConfigStore.defaultStore()
    let result = try mutate(try store.load())
    try store.save(result.book)
    return result
  }

  private static func contractIDArg(_ arguments: [String: JSONValue]) -> String? {
    stringArg("contractID", arguments) ?? stringArg("contract", arguments)
  }

  private static func stringArg(_ key: String, _ arguments: [String: JSONValue]) -> String? {
    guard let value = arguments[key] else { return nil }
    switch value {
    case .string(let raw):
      return raw
    case .number(let raw):
      if raw.rounded() == raw {
        return String(Int(raw))
      }
      return String(raw)
    default:
      return value.stringValue
    }
  }

  private static func nonemptyStringArg(
    _ key: String,
    _ arguments: [String: JSONValue]
  ) -> String? {
    guard
      let value = stringArg(key, arguments)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }

  private static func boolArg(_ key: String, _ arguments: [String: JSONValue]) -> Bool {
    guard let value = arguments[key] else { return false }
    switch value {
    case .bool(let raw):
      return raw
    case .string(let raw):
      return ["1", "true", "yes", "sealed"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    default:
      return false
    }
  }

  private static func identityTopologyMermaid(_ plan: ModeIdentityPlan) -> String {
    guard !plan.identitySlots.isEmpty else {
      return """
        flowchart LR
          empty["Configured identity topology is empty"]
        """
    }
    var lines = ["flowchart LR"]
    for (index, slot) in plan.identitySlots.enumerated() {
      let nodeID = "identity_\(index + 1)"
      let models = slot.candidates.map(\.modelID).joined(separator: " + ")
      let routeLabel = models.isEmpty ? "unbound / fail closed" : models
      let label = "\(slot.label) · \(routeLabel)"
        .replacingOccurrences(of: "\"", with: "'")
      lines.append("  \(nodeID)[\"\(label)\"]")
      if index > 0 {
        lines.append("  identity_\(index) --> \(nodeID)")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func stringArrayArg(_ key: String, _ arguments: [String: JSONValue]) -> [String] {
    guard let value = arguments[key] else { return [] }
    switch value {
    case .string(let raw):
      return raw.split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { !$0.isEmpty }
    case .array(let values):
      return values.compactMap(\.stringValue)
    default:
      return []
    }
  }

  private static func identityArg(_ key: String, _ arguments: [String: JSONValue]) -> IdentityKind {
    switch stringArg(key, arguments)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "lead", "主導": return .lead
    case "supervisor", "監督", "reviewer", "副審": return .supervisor
    case "consultant", "顧問": return .consultant
    case "news", "消息": return .news
    case "verifier", "驗收", "judge": return .verifier
    case "sub", "helper": return .sub
    default: return .sub
    }
  }

  private static func mutationArg(_ key: String, _ arguments: [String: JSONValue]) -> WorkOSActionMutation {
    stringArg(key, arguments)
      .flatMap { WorkOSActionMutation(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
      ?? .readOnly
  }

  private static func surfaceArg(_ key: String, _ arguments: [String: JSONValue]) -> WorkOSActionSurface {
    stringArg(key, arguments)
      .flatMap { WorkOSActionSurface(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
      ?? .mcp
  }

  private static func canonicalToolName(_ tool: String) -> String {
    let normalized = tool.trimmingCharacters(in: .whitespacesAndNewlines)
    return aliasMap[normalized] ?? normalized
  }

  private static let aliasMap: [String: String] = [
    "tatwo_app_mcp_manifest": "tatwo.mcp.manifest",
    "tatwo_mcp_client_config": "tatwo.mcp.client_config",
    "tatwo_engine_capabilities": "tatwo.engine.capabilities",
    "tatwo_identities_list": "tatwo.identities.list",
    "tatwo_scenario_get": "tatwo.scenario.get",
    "tatwo_scenario_agents": "tatwo.scenario.agents",
    "tatwo_scenario_config": "tatwo.scenario.config",
    "tatwo_scenario_config_add": "tatwo.scenario.config.add",
    "tatwo_scenario_config_duplicate": "tatwo.scenario.config.duplicate",
    "tatwo_scenario_config_rename": "tatwo.scenario.config.rename",
    "tatwo_scenario_config_delete": "tatwo.scenario.config.delete",
    "tatwo_scenario_config_update_token_budget": "tatwo.scenario.config.update_token_budget",
    "tatwo_scenario_config_set_binding_models": "tatwo.scenario.config.set_binding_models",
    "tatwo_scenario_config_update_binding_responsibility": "tatwo.scenario.config.update_binding_responsibility",
    "tatwo_plugin_registry_list": "tatwo.plugin_registry.list",
    "tatwo_plugins_registry": "tatwo.plugin_registry.list",
    "tatwo_context_policy": "tatwo.context.policy",
    "tatwo_context_compress": "tatwo.context.compress",
    "tatwo_context_retrieve": "tatwo.context.retrieve",
    "tatwo_context_stats": "tatwo.context.stats",
    "tatwo_scenario_workflow": "tatwo.scenario.workflow",
    "tatwo_os_begin": "tatwo.os.begin",
    "tatwo_os_goal_candidate_create": "tatwo.os.goal.candidate.create",
    "tatwo_os_session_attach": "tatwo.os.session.attach",
    "tatwo_os_session_revise": "tatwo.os.session.revise",
    "tatwo_os_next": "tatwo.os.next",
    "tatwo_os_loop_status": "tatwo.os.loop.status",
    "tatwo_os_receipt_submit": "tatwo.os.receipt.submit",
    "tatwo_os_goal_close": "tatwo.os.goal.close",
    "tatwo_os_dashboard": "tatwo.os.dashboard",
    "tatwo_os_enforce": "tatwo.os.enforce",
    "tatwo_os_handoff": "tatwo.os.handoff",
    "tatwo_os_constitution": "tatwo.os.constitution",
    "tatwo_gateway_status": "tatwo.gateway.status",
    "tatwo_gateway_models": "tatwo.gateway.models",
    "tatwo_gateway_dispatch": "tatwo.gateway.dispatch",
    "tatwo_gateway_fanout": "tatwo.gateway.fanout",
    "tatwo_sandbox_begin": "tatwo.sandbox.begin",
    "tatwo_sandbox_write_artifact": "tatwo.sandbox.write_artifact",
    "tatwo_sandbox_run_command": "tatwo.sandbox.run_command",
    "tatwo_sandbox_receipt": "tatwo.sandbox.receipt",
    "tatwo_sandbox_promote_plan": "tatwo.sandbox.promote_plan",
    "tatwo_host_authorize_revision": "tatwo.host.authorize_revision",
    "tatwo_web_arena_plan": "tatwo.web_arena.plan",
    "tatwo_web_arena_report": "tatwo.web_arena.report",
    "tatwo_web_arena_cleanup_plan": "tatwo.web_arena.cleanup_plan",
    "tatwo_sandbox_arena_list": "tatwo.sandbox_arena.list",
    "tatwo_sandbox_arena_plan": "tatwo.sandbox_arena.plan",
    "tatwo_sandbox_arena_report": "tatwo.sandbox_arena.report",
    "tatwo_arena_plan_loop_goal_policy": "tatwo.arena.plan_loop_goal.policy",
    "tatwo_arena_plan_loop_goal_score": "tatwo.arena.plan_loop_goal.score",
    "tatwo_arena_plg_score": "tatwo.arena.plan_loop_goal.score",
    "tatwo_arena_goal_cycle_assess": "tatwo.arena.goal_cycle.assess",
    "tatwo_web_check_preflight": "tatwo.web_check.preflight",
    "tatwo_web_check_plan": "tatwo.web_check.plan",
    "tatwo_web_check_import_receipt": "tatwo.web_check.import_receipt",
    "tatwo_web_check_receipt_template": "tatwo.web_check.receipt_template",
    "tatwo_model_traits": "tatwo.traits.list",
    "tatwo_mode_plan": "tatwo.mode.plan",
    "tatwo_ultrawork_topics": "tatwo.ultrawork.topics",
    "tatwo_workflow_preview": "tatwo.workflow.preview",
    "tatwo_receipt_requirements": "tatwo.receipt.requirements",
    "tatwo_handoff_pack": "tatwo.handoff.pack",
  ]

  public static func clientConfig(for requestedEngine: String) -> TatwoMCPClientConfig {
    let engine = requestedEngine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let isCodex =
      engine == EngineID.codex.rawValue || engine == "codex-cli" || engine == "codex-app"
    let isClaude =
      engine == EngineID.claudeCLI.rawValue || engine == "claude" || engine == "claude-code"
    let label =
      isCodex ? "codex" : (isClaude ? "claude-cli" : (engine.isEmpty ? "generic-cli" : engine))

    return TatwoMCPClientConfig(
      requestedEngine: label,
      codexRequired: false,
      defaultHostEngine: EngineID.codex.rawValue,
      startCommand: "node",
      startArgs: ["<repo>/scripts/tatwo-ultrawork-mcp.mjs"],
      cliExamples: [
        "tatwo-ultrawork mcp tools --json",
        "tatwo-ultrawork-mcp  # stdio MCP wrapper for Claude/Fable; exposes gateway + sandbox tools",
        "tatwo-ultrawork mcp serve --port 17377 --json",
        "tatwo-ultrawork mcp call tatwo.gateway.status --json",
        "tatwo-ultrawork mcp call tatwo.gateway.dispatch --contract <contractID> --model minimax-m3 --prompt '<subtask>' --dry-run --json",
        "tatwo-ultrawork mcp call tatwo.sandbox.begin --contract <contractID> --objective '<sandbox objective>' --json",
        "tatwo-ultrawork mcp call tatwo.mode.plan --app-url http://127.0.0.1:17377 --mode L --scenario ui-ux --json",
        "tatwo-ultrawork mcp call tatwo.mode.plan --mode L --scenario ui-ux --json",
        "tatwo-ultrawork mcp call tatwo.scenario.workflow --mode L --scenario ui-ux --objective '<objective>' --json",
        "tatwo-ultrawork mcp call tatwo.os.begin --mode XL --scenario ui-ux --objective '<objective>' --json",
        "tatwo-ultrawork mcp call tatwo.os.goal.candidate.create --mode XXL --scenario coding --objective '<objective>' --json",
        "tatwo-ultrawork mcp call tatwo.os.session.attach --provider <provider> --owner-session <id> --workspace <absolute-path> --contract <contractID> --goal <goalID> --json",
        "tatwo-ultrawork mcp call tatwo.os.session.revise --authorization <externally-issued-id> --json",
        "tatwo-ultrawork mcp call tatwo.host.authorize_revision --authorization <app-issued-host-operation-id> --json",
        "tatwo-ultrawork mcp call tatwo.os.dashboard --mode XL --scenario ui-ux --objective '<objective>' --json",
        "tatwo-ultrawork mcp call tatwo.os.handoff --mode XL --scenario ui-ux --objective '<objective>' --json",
        "tatwo-ultrawork os begin --mode XL --scenario ui-ux --objective '<objective>' --json",
        "tatwo-ultrawork os dashboard --mode XL --scenario ui-ux --objective '<objective>' --json",
        "tatwo-ultrawork mcp call tatwo.workflow.preview --mode XL --scenario coding --json",
        "node <repo>/scripts/tatwo-ultrawork-mcp.mjs  # stdio MCP server for any MCP client",
      ],
      fallbackBehavior:
        "App/MCP server unavailable時，CLI 仍使用 TatwoUltraworkCore fallback 回傳同一套身份組、情境、特質、工作流與收據規則；不需要 Codex 才能讀規格。",
      safetyRules: [
        "Codex highest-fit host != only engine.",
        "Gateway dispatch is text-only and requires contractID; external engines do not gain host mutation.",
        "Sandbox tools may write only inside the configured TATWO sandbox root; promotion is plan-only.",
        "CLI/MCP calls are read/plan/sandbox/receipt by default and do not mutate host project state.",
        "External engines without safe host capability stay advisory outside scoped sandbox artifacts.",
        "Use <repo> placeholder in shareable config; do not publish private local paths.",
      ])
  }

  // internal (not private): TatwoExecutionManifestFactory reuses this allowlist so the
  // manifest's eligibility matches the real gateway.dispatch gate (no duplicated allowlist).
  static let gatewayAllowedModels = TatwoGatewayDispatchCatalog.allowedModels

  static let gatewayExpensiveModels = TatwoGatewayDispatchCatalog.expensiveModels

  private static func gatewayBaseURL() -> String {
    let env = ProcessInfo.processInfo.environment
    let raw = env["TATWO_MODEL_GATEWAY_URL"] ?? env["MODEL_GATEWAY_BASE_URL"] ?? "http://127.0.0.1:4177"
    return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  static func normalizeGatewayModel(_ value: String?) -> String {
    TatwoGatewayDispatchCatalog.normalize(value)
  }

  private static func contractArg(_ arguments: [String: JSONValue]) -> String {
    (stringArg("contractID", arguments) ?? stringArg("contract", arguments) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func gatewayStatusPayload(arguments: [String: JSONValue]) throws -> JSONValue {
    let gateway = gatewayBaseURL()
    var payload: [String: JSONValue] = [
      "schema": .string("TatwoGatewayStatusReceiptV1"),
      "ok": .bool(true),
      "status": .string("core_fallback_ready"),
      "gateway": .string(gateway),
      "hostMutationAllowed": .bool(false),
      "requiresContractIDForDispatch": .bool(true),
      "dispatchBridge": .object([
        "purpose": .string("Claude/Fable/Codex MCP caller can request text-only submodel dispatch through TATWO Work OS."),
        "hostMutationAllowed": .bool(false),
        "requiresContractIDForDispatch": .bool(true),
        "allowedModels": .array(gatewayAllowedModels.sorted().map { .string($0) }),
      ]),
    ]
    if let health = try? httpJSON(urlString: "\(gateway)/health", timeout: 8) {
      payload["liveHealthReachable"] = .bool(true)
      payload["liveHealth"] = health
      payload["routeHealthV2Verified"] = .bool(false)
      payload["status"] = .string(
        gatewayStatusClassification(
          liveHealthReachable: true,
          routeHealthV2Verified: false))
    } else {
      payload["liveHealthReachable"] = .bool(false)
      payload["routeHealthV2Verified"] = .bool(false)
      payload["note"] = .string("Swift CLI fallback is ready; Node stdio MCP wrapper performs full live gateway dispatch for Claude/Fable.")
    }
    return .object(payload)
  }

  static func gatewayStatusClassification(
    liveHealthReachable: Bool,
    routeHealthV2Verified: Bool
  ) -> String {
    if routeHealthV2Verified { return "route_health_v2_verified" }
    if liveHealthReachable { return "reachable_unverified" }
    return "core_fallback_ready"
  }

  private static func gatewayModelsPayload(arguments: [String: JSONValue]) -> JSONValue {
    let allowedOnly = boolArg("allowedOnly", arguments)
    let models = gatewayAllowedModels.sorted().map {
      JSONValue.object([
        "id": .string($0),
        "displayName": .string($0),
        "dispatchAllowed": .bool(TatwoModelIdentityRegistry.isActiveDispatchEligible($0)),
        "currentHealth": .string(
          TatwoModelIdentityRegistry.record(for: $0)?.currentHealth.rawValue
            ?? TatwoModelCurrentHealth.unavailable.rawValue),
        "expensiveOrLimited": .bool(gatewayExpensiveModels.contains($0)),
      ])
    }
    return .object([
      "schema": .string("TatwoGatewayModelsReceiptV1"),
      "ok": .bool(true),
      "status": .string("core_allowlist"),
      "gateway": .string(gatewayBaseURL()),
      "allowedOnly": .bool(allowedOnly),
      "count": .number(Double(models.count)),
      "models": .array(models),
      "hostMutationAllowed": .bool(false),
    ])
  }

  static func gatewayDispatchPayload(
    arguments: [String: JSONValue],
    liveStatusProvider: (String) -> TatwoGatewayLiveStatus? = gatewayLiveStatus
  ) -> TatwoMCPToolCallResult {
    let contractID = contractArg(arguments)
    // #2: all dispatch-shaped writes authorize through the one chokepoint (contract
    // authentication + dev bypass) instead of a hand-placed per-surface gate.
    let toll = TatwoWorkOSChokepoint.authorize(
      contractID: contractID, action: "tatwo.gateway.dispatch")
    guard toll.ok else {
      return failure(tool: "tatwo.gateway.dispatch", error: toll.message)
    }
    let model = normalizeGatewayModel(stringArg("model", arguments))
    guard !model.isEmpty else {
      return failure(tool: "tatwo.gateway.dispatch", error: "missing model")
    }
    guard gatewayAllowedModels.contains(model) else {
      return failure(tool: "tatwo.gateway.dispatch", error: "model not allowlisted by TATWO OS: \(model)")
    }
    let dryRun = boolArg("dryRun", arguments) || boolArg("dry-run", arguments)
    guard let identity = TatwoModelIdentityRegistry.record(for: model) else {
      return failure(
        tool: "tatwo.gateway.dispatch",
        error: "model_identity_missing:\(model)")
    }
    guard identity.currentHealth != .unavailable else {
      return failure(
        tool: "tatwo.gateway.dispatch",
        error: "route_unavailable:\(model)")
    }
    if dryRun, identity.currentHealth == .deferUntilRouteHealthV2 {
      return failure(
        tool: "tatwo.gateway.dispatch",
        error: "route_health_v2_required:\(model)")
    }
    if containsUnsupportedGatewayImageInput(arguments) {
      return failure(
        tool: "tatwo.gateway.dispatch",
        error: "unsupported_input:image_attachment")
    }
    if gatewayExpensiveModels.contains(model), !boolArg("allowExpensive", arguments) {
      return failure(
        tool: "tatwo.gateway.dispatch",
        error: "\(model) is expensive/limited; pass allowExpensive=true for explicit human-approved dispatch")
    }
    let prompt = stringArg("prompt", arguments) ?? stringArg("input", arguments) ?? stringArg("objective", arguments) ?? ""
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return failure(tool: "tatwo.gateway.dispatch", error: "missing prompt/input/objective")
    }
    if let violation = gatewayPromptViolation(prompt) {
      return failure(tool: "tatwo.gateway.dispatch", error: violation)
    }
    if !dryRun {
      switch TatwoGatewayDispatchGate.evaluate(
        status: liveStatusProvider(model),
        modelID: model)
      {
      case .allowed:
        break
      case .blocked(let reason):
        return failure(
          tool: "tatwo.gateway.dispatch",
          error: "route_health_v2_required:\(model):\(reason)")
      }
    }
    let payload: JSONValue = .object([
      "schema": .string("TatwoGatewayDispatchReceiptV1"),
      "ok": .bool(true),
      "status": .string(dryRun ? "dry_run" : "planned_core_fallback"),
      "contractID": .string(contractID),
      "goalID": .string(stringArg("goalID", arguments) ?? stringArg("goal", arguments) ?? ""),
      "model": .string(model),
      "identity": .string(stringArg("identity", arguments) ?? stringArg("role", arguments) ?? "sub"),
      "purpose": .string(stringArg("purpose", arguments) ?? "TATWO gateway subtask"),
      "gateway": .string(gatewayBaseURL()),
      "hostMutationAllowed": .bool(false),
      "routeHealthV2Verified": .bool(!dryRun),
      "plannedRequest": .object([
        "endpoint": .string("/v1/responses"),
        "promptChars": .number(Double(prompt.count)),
        "note": .string("Use Node stdio MCP wrapper tatwo-ultrawork-mcp for live dispatch; Swift CLI fallback keeps a safe dry-run/planned receipt."),
      ]),
      "receiptID": .string("gateway-dispatch-core-\(model)-\(Int(Date().timeIntervalSince1970))"),
    ])
    return TatwoMCPToolCallResult(tool: "tatwo.gateway.dispatch", ok: true, payload: payload)
  }

  static func gatewayFanoutPayload(
    arguments: [String: JSONValue],
    liveStatusProvider: (String) -> TatwoGatewayLiveStatus? = gatewayLiveStatus
  ) -> TatwoMCPToolCallResult {
    let contractID = contractArg(arguments)
    let toll = TatwoWorkOSChokepoint.authorize(
      contractID: contractID, action: "tatwo.gateway.fanout")
    guard toll.ok else {
      return failure(tool: "tatwo.gateway.fanout", error: toll.message)
    }
    if containsUnsupportedGatewayImageInput(arguments) {
      return failure(
        tool: "tatwo.gateway.fanout",
        error: "unsupported_input:image_attachment")
    }
    var models = stringArrayArg("models", arguments).map(normalizeGatewayModel).filter { !$0.isEmpty }
    if models.isEmpty, let model = stringArg("model", arguments) {
      models = [normalizeGatewayModel(model)]
    }
    guard !models.isEmpty else {
      return failure(tool: "tatwo.gateway.fanout", error: "missing requests/models")
    }
    let maxFanout = max(1, min(Int(stringArg("maxFanout", arguments) ?? "4") ?? 4, 8))
    let selected = Array(models.prefix(maxFanout))
    let skipped = Array(models.dropFirst(maxFanout))
    let prompt = stringArg("prompt", arguments) ?? stringArg("input", arguments) ?? stringArg("objective", arguments) ?? ""
    let children = selected.map { model in
      gatewayDispatchPayload(arguments: arguments.merging([
        "model": .string(model),
        "prompt": .string(prompt),
      ]) { _, new in new }, liveStatusProvider: liveStatusProvider)
    }
    let allChildrenSucceeded = children.allSatisfy(\.ok)
    let receipts = zip(selected, children).map { model, child -> JSONValue in
      if let payload = child.payload {
        return payload
      }
      return .object([
        "ok": .bool(false),
        "status": .string("failed"),
        "model": .string(model),
        "error": .string(child.error ?? "gateway_dispatch_failed"),
      ])
    }
    return TatwoMCPToolCallResult(
      tool: "tatwo.gateway.fanout",
      ok: allChildrenSucceeded,
      payload: .object([
        "schema": .string("TatwoGatewayFanoutReceiptV1"),
        "ok": .bool(allChildrenSucceeded),
        "status": .string(allChildrenSucceeded ? "planned_core_fallback" : "partial_or_failed"),
        "contractID": .string(contractID),
        "goalID": .string(stringArg("goalID", arguments) ?? stringArg("goal", arguments) ?? ""),
        "gateway": .string(gatewayBaseURL()),
        "hostMutationAllowed": .bool(false),
        "fanoutCount": .number(Double(selected.count)),
        "skippedByCap": .array(skipped.map { .string($0) }),
        "receipts": .array(receipts),
      ]),
      error: allChildrenSucceeded ? nil : "gateway_fanout_child_failure")
  }

  private static func gatewayPromptViolation(_ prompt: String) -> String? {
    let lowered = prompt.lowercased()
    let blocked = [
      "access_token", "refresh_token", "auth.json", "cookie", "api_key", "secret key",
      "private key", "rm -rf", "sudo ", "launchctl bootstrap", "下單", "槓桿", "止損",
      "live order", "market order", "leverage", "stop-loss",
    ]
    return blocked.first(where: { lowered.contains($0) }).map {
      "forbidden gateway dispatch content: \($0)"
    }
  }

  private static func containsUnsupportedGatewayImageInput(
    _ arguments: [String: JSONValue]
  ) -> Bool {
    let imageKeys = [
      "attachmentPath",
      "attachmentPaths",
      "image",
      "images",
      "imagePath",
      "imagePaths",
      "input_image",
    ]
    return imageKeys.contains { key in
      guard let value = arguments[key] else { return false }
      switch value {
      case .null:
        return false
      case .string(let raw):
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .array(let values):
        return !values.isEmpty
      default:
        return true
      }
    }
  }

  private static func gatewayLiveStatus(modelID: String) -> TatwoGatewayLiveStatus? {
    let gateway = gatewayBaseURL()
    guard
      let endpoint = URL(string: gateway),
      let healthData = try? httpData(urlString: "\(gateway)/health", timeout: 8),
      let catalogData = try? httpData(urlString: "\(gateway)/v1/models", timeout: 8)
    else {
      return nil
    }
    return TatwoGatewayHealthDecoder.decode(
      healthData: healthData,
      catalogData: catalogData,
      endpoint: endpoint,
      requiredRouteIDs: [modelID])
  }

  private static func httpJSON(urlString: String, timeout: TimeInterval) throws -> JSONValue {
    let data = try httpData(urlString: urlString, timeout: timeout)
    let any = try JSONSerialization.jsonObject(with: data, options: [])
    return JSONValue.fromAny(any)
  }

  private static func httpData(urlString: String, timeout: TimeInterval) throws -> Data {
    guard URL(string: urlString) != nil else { throw URLError(.badURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["curl", "-fsS", "--max-time", "\(Int(timeout))", urlString]
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw URLError(.cannotConnectToHost)
    }
    return stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  }

  private static func sandboxBeginPayload(arguments: [String: JSONValue]) throws -> TatwoMCPToolCallResult {
    let contractID = contractArg(arguments)
    // #2: previously this only checked non-empty — a forged contractID could open a
    // sandbox. The chokepoint upgrades it to issued-contract authentication.
    let toll = TatwoWorkOSChokepoint.authorize(
      contractID: contractID, action: "tatwo.sandbox.begin")
    guard toll.ok else {
      return failure(tool: "tatwo.sandbox.begin", error: toll.message)
    }
    let sandboxID = sanitizedID(
      stringArg("sandboxID", arguments) ?? "sandbox-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")
    let root = sandboxRootURL()
    let sandbox = root.appendingPathComponent(sandboxID, isDirectory: true)
    guard isInside(child: sandbox, parent: root) else {
      return failure(tool: "tatwo.sandbox.begin", error: "sandbox path escapes sandbox root")
    }
    for dir in ["generated-artifacts", "receipts", "logs", "home"] {
      try FileManager.default.createDirectory(
        at: sandbox.appendingPathComponent(dir, isDirectory: true),
        withIntermediateDirectories: true)
    }
    let manifest: [String: JSONValue] = [
      "schema": .string("TatwoSandboxManifestV1"),
      "sandboxID": .string(sandboxID),
      "contractID": .string(contractID),
      "goalID": .string(stringArg("goalID", arguments) ?? stringArg("goal", arguments) ?? ""),
      "objective": .string(TatwoPrivacyRedactor.redacted(stringArg("objective", arguments) ?? "")),
      "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
      "hostMutationAllowed": .bool(false),
    ]
    try writeJSON(.object(manifest), to: sandbox.appendingPathComponent(".tatwo-sandbox-manifest.json"))
    return TatwoMCPToolCallResult(
      tool: "tatwo.sandbox.begin",
      ok: true,
      payload: .object([
        "schema": .string("TatwoSandboxSessionReceiptV1"),
        "ok": .bool(true),
        "status": .string("created"),
        "sandboxID": .string(sandboxID),
        "contractID": .string(contractID),
        "sandboxRoot": .string(TatwoPrivacyRedactor.redacted(sandbox.path)),
        "hostMutationAllowed": .bool(false),
        "sandboxWriteAllowed": .bool(true),
        "allowedTools": .array(["tatwo.sandbox.write_artifact", "tatwo.sandbox.run_command", "tatwo.sandbox.receipt", "tatwo.sandbox.promote_plan"].map { .string($0) }),
      ]))
  }

  private static func sandboxWriteArtifactPayload(arguments: [String: JSONValue]) throws -> TatwoMCPToolCallResult {
    let loaded = try loadSandbox(arguments: arguments, tool: "tatwo.sandbox.write_artifact")
    if !loaded.ok { return loaded.result }
    guard let sandbox = loaded.sandboxURL, let contractID = loaded.contractID else { return loaded.result }
    let relativePath = stringArg("relativePath", arguments) ?? stringArg("path", arguments) ?? ""
    guard let target = sandboxTarget(sandbox: sandbox, relativePath: relativePath) else {
      return failure(tool: "tatwo.sandbox.write_artifact", error: "path escapes sandbox or is not allowed")
    }
    guard !isProtectedSandboxFile(relativePath) else {
      return failure(tool: "tatwo.sandbox.write_artifact", error: "protected control file cannot be overwritten")
    }
    let content = stringArg("content", arguments) ?? ""
    let maxBytes = Int(stringArg("maxBytes", arguments) ?? "1048576") ?? 1_048_576
    let data = Data(content.utf8)
    guard data.count <= maxBytes else {
      return failure(tool: "tatwo.sandbox.write_artifact", error: "artifact exceeds maxBytes \(maxBytes)")
    }
    if let violation = sandboxContentViolation(content) {
      return failure(tool: "tatwo.sandbox.write_artifact", error: violation)
    }
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: target, options: .atomic)
    let sha = sha256Hex(data)
    let receipt: JSONValue = .object([
      "schema": .string("TatwoSandboxArtifactReceiptV1"),
      "ok": .bool(true),
      "status": .string("written"),
      "sandboxID": .string(loaded.sandboxID ?? ""),
      "contractID": .string(contractID),
      "relativePath": .string(relativePath),
      "bytes": .number(Double(data.count)),
      "sha256": .string(sha),
      "hostMutationAllowed": .bool(false),
    ])
    try writeJSON(receipt, to: sandbox.appendingPathComponent("receipts/artifact-\(sha.prefix(12)).json"))
    return TatwoMCPToolCallResult(tool: "tatwo.sandbox.write_artifact", ok: true, payload: receipt)
  }

  private static func sandboxRunCommandPayload(arguments: [String: JSONValue]) throws -> TatwoMCPToolCallResult {
    let loaded = try loadSandbox(arguments: arguments, tool: "tatwo.sandbox.run_command")
    if !loaded.ok { return loaded.result }
    guard let sandbox = loaded.sandboxURL, let contractID = loaded.contractID else { return loaded.result }
    let command = stringArg("command", arguments) ?? ""
    let allowed = ["node", "python3", "npm"]
    guard allowed.contains(command) else {
      return failure(tool: "tatwo.sandbox.run_command", error: "command not allowlisted: \(command)")
    }
    let args = stringArrayArg("args", arguments)
    if command == "node", args.contains(where: { ["-e", "-p", "-r"].contains($0) }) {
      return failure(tool: "tatwo.sandbox.run_command", error: "node inline/eval/require flags are blocked")
    }
    if command == "python3", args.contains("-c") {
      return failure(tool: "tatwo.sandbox.run_command", error: "python inline execution is blocked")
    }
    if command == "npm", args.first.map({ ["install", "i", "add", "exec"].contains($0) }) == true {
      return failure(tool: "tatwo.sandbox.run_command", error: "npm install/add/exec are blocked")
    }

    let started = Date()
    let process = Process()
    process.currentDirectoryURL = sandbox
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + args
    process.environment = [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME": sandbox.appendingPathComponent("home", isDirectory: true).path,
      "TATWO_SANDBOX_ID": loaded.sandboxID ?? "",
      "TATWO_CONTRACT_ID": contractID,
    ]
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let durationMS = Int(Date().timeIntervalSince(started) * 1000)
    let receipt: JSONValue = .object([
      "schema": .string("TatwoSandboxCommandReceiptV1"),
      "ok": .bool(process.terminationStatus == 0),
      "status": .string(process.terminationStatus == 0 ? "completed" : "failed"),
      "sandboxID": .string(loaded.sandboxID ?? ""),
      "contractID": .string(contractID),
      "command": .string(command),
      "args": .array(args.map { .string(TatwoPrivacyRedactor.redacted($0)) }),
      "exitCode": .number(Double(process.terminationStatus)),
      "stdout": .string(TatwoPrivacyRedactor.redacted(String(stdout.prefix(12000)))),
      "stderr": .string(TatwoPrivacyRedactor.redacted(String(stderr.prefix(12000)))),
      "durationMS": .number(Double(durationMS)),
      "hostMutationAllowed": .bool(false),
    ])
    let receiptData = try JSONEncoder().encode(receipt)
    try receiptData.write(
      to: sandbox.appendingPathComponent("receipts/command-\(Int(started.timeIntervalSince1970)).json"),
      options: .atomic)
    return TatwoMCPToolCallResult(tool: "tatwo.sandbox.run_command", ok: process.terminationStatus == 0, payload: receipt)
  }

  private static func sandboxReceiptPayload(arguments: [String: JSONValue]) throws -> TatwoMCPToolCallResult {
    let loaded = try loadSandbox(arguments: arguments, tool: "tatwo.sandbox.receipt")
    if !loaded.ok { return loaded.result }
    guard let sandbox = loaded.sandboxURL, let contractID = loaded.contractID else { return loaded.result }
    let artifactRoot = sandbox.appendingPathComponent("generated-artifacts", isDirectory: true)
    let receiptRoot = sandbox.appendingPathComponent("receipts", isDirectory: true)
    let artifacts = listRelativeFiles(root: sandbox, under: artifactRoot)
    let receipts = listRelativeFiles(root: sandbox, under: receiptRoot)
    let bundle: JSONValue = .object([
      "schema": .string("TatwoSandboxReceiptBundleV1"),
      "ok": .bool(true),
      "status": .string("bundled"),
      "sandboxID": .string(loaded.sandboxID ?? ""),
      "contractID": .string(contractID),
      "artifactCount": .number(Double(artifacts.count)),
      "commandCount": .number(Double(receipts.filter { $0.contains("command-") }.count)),
      "artifacts": .array(artifacts.map { .string($0) }),
      "receiptFiles": .array(receipts.map { .string($0) }),
      "hostMutationAllowed": .bool(false),
    ])
    try writeJSON(bundle, to: sandbox.appendingPathComponent("receipts/bundle.json"))
    return TatwoMCPToolCallResult(tool: "tatwo.sandbox.receipt", ok: true, payload: bundle)
  }

  private static func sandboxPromotePlanPayload(arguments: [String: JSONValue]) throws -> TatwoMCPToolCallResult {
    let loaded = try loadSandbox(arguments: arguments, tool: "tatwo.sandbox.promote_plan")
    if !loaded.ok { return loaded.result }
    let plan: JSONValue = .object([
      "schema": .string("TatwoSandboxPromotePlanV1"),
      "ok": .bool(true),
      "status": .string("human_gate_required"),
      "sandboxID": .string(loaded.sandboxID ?? ""),
      "contractID": .string(loaded.contractID ?? ""),
      "targetHint": .string(TatwoPrivacyRedactor.redacted(stringArg("targetHint", arguments) ?? "host project")),
      "promoteAllowed": .bool(false),
      "hostMutationAllowed": .bool(false),
      "requiredBeforePromotion": .array([
        .string("human gate / 人工放行"),
        .string("Codex host applies diff, not Claude/Fable host write"),
        .string("rollback receipt"),
        .string("validation receipts"),
        .string("cleanup inventory receipt"),
      ]),
    ])
    return TatwoMCPToolCallResult(tool: "tatwo.sandbox.promote_plan", ok: true, payload: plan)
  }

  private struct LoadedSandbox {
    let ok: Bool
    let result: TatwoMCPToolCallResult
    let sandboxURL: URL?
    let sandboxID: String?
    let contractID: String?
  }

  private static func loadSandbox(arguments: [String: JSONValue], tool: String) throws -> LoadedSandbox {
    let contractID = contractArg(arguments)
    guard !contractID.isEmpty else {
      return LoadedSandbox(
        ok: false, result: failure(tool: tool, error: "missing contractID; call tatwo.sandbox.begin first"),
        sandboxURL: nil, sandboxID: nil, contractID: nil)
    }
    let sandboxID = sanitizedID(stringArg("sandboxID", arguments) ?? stringArg("sandbox", arguments) ?? "")
    guard !sandboxID.isEmpty else {
      return LoadedSandbox(
        ok: false, result: failure(tool: tool, error: "missing sandboxID; call tatwo.sandbox.begin first"),
        sandboxURL: nil, sandboxID: nil, contractID: contractID)
    }
    let root = sandboxRootURL()
    let sandbox = root.appendingPathComponent(sandboxID, isDirectory: true)
    guard isInside(child: sandbox, parent: root) else {
      return LoadedSandbox(
        ok: false, result: failure(tool: tool, error: "sandbox path escapes sandbox root"),
        sandboxURL: nil, sandboxID: sandboxID, contractID: contractID)
    }
    let manifestURL = sandbox.appendingPathComponent(".tatwo-sandbox-manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      return LoadedSandbox(
        ok: false, result: failure(tool: tool, error: "sandbox manifest not found"),
        sandboxURL: nil, sandboxID: sandboxID, contractID: contractID)
    }
    let manifestText = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
    guard manifestText.contains("\"\(contractID)\"") else {
      return LoadedSandbox(
        ok: false, result: failure(tool: tool, error: "contractID does not match sandbox manifest"),
        sandboxURL: nil, sandboxID: sandboxID, contractID: contractID)
    }
    return LoadedSandbox(
      ok: true, result: TatwoMCPToolCallResult(tool: tool, ok: true, payload: .null),
      sandboxURL: sandbox, sandboxID: sandboxID, contractID: contractID)
  }

  private static func sandboxRootURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    let raw = env["TATWO_ULTRAWORK_SANDBOX_ROOT"]
      ?? "\(FileManager.default.currentDirectoryPath)/.tatwo-ultrawork/mcp-sandboxes"
    return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
  }

  private static func sandboxTarget(sandbox: URL, relativePath: String) -> URL? {
    let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.split(separator: "/").contains("..") else {
      return nil
    }
    let target = sandbox.appendingPathComponent(trimmed).standardizedFileURL
    guard isInside(child: target, parent: sandbox) else { return nil }
    return target
  }

  private static func isInside(child: URL, parent: URL) -> Bool {
    let childPath = child.standardizedFileURL.path
    let parentPath = parent.standardizedFileURL.path
    return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
  }

  private static func isProtectedSandboxFile(_ relativePath: String) -> Bool {
    let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    return name == ".tatwo-sandbox-manifest.json" || name == "cleanup-inventory.json"
      || name.lowercased().contains("auth.json")
  }

  private static func sandboxContentViolation(_ content: String) -> String? {
    let lowered = content.lowercased()
    let blocked = ["access_token", "refresh_token", "auth.json", "bearer ", "api_key", "private key", "session cookie"]
    return blocked.first(where: { lowered.contains($0) }).map {
      "auth/session-like content is forbidden in sandbox artifact: \($0)"
    }
  }

  private static func sanitizedID(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .map { char in
        char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "-"
      }
      .reduce(into: "") { $0.append($1) }
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func writeJSON(_ value: JSONValue, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private static func listRelativeFiles(root: URL, under directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
      return []
    }
    return enumerator.compactMap { item -> String? in
      guard let url = item as? URL else { return nil }
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
        return nil
      }
      let rootPath = root.standardizedFileURL.path + "/"
      return url.standardizedFileURL.path.replacingOccurrences(of: rootPath, with: "")
    }.sorted()
  }
}
