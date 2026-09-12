import CryptoKit
import Foundation

public enum TatwoScenarioPhase: String, Codable, Sendable, CaseIterable, Equatable, Comparable {
  case plan
  case loops
  case goal

  public static func < (lhs: TatwoScenarioPhase, rhs: TatwoScenarioPhase) -> Bool {
    let order: [TatwoScenarioPhase] = [.plan, .loops, .goal]
    return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
  }

  public var chineseName: String {
    switch self {
    case .plan: return "Plan"
    case .loops: return "Loops"
    case .goal: return "Goal"
    }
  }
}

public enum TatwoDynamicActivation: String, Codable, Sendable, CaseIterable, Equatable {
  case always
  case allowed
  case manualOnly = "manual_only"
  case disabled

  public var chineseName: String {
    switch self {
    case .always: return "固定啟用"
    case .allowed: return "OS 可動態啟用"
    case .manualOnly: return "需人工同意"
    case .disabled: return "停用"
    }
  }
}

public struct TatwoScenarioIdentityBinding: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var phase: TatwoScenarioPhase
  public var identity: String
  public var boundModelIDs: [String]
  public var responsibility: String
  public var dynamicActivation: TatwoDynamicActivation
  public var enabled: Bool
  /// 這個身份組派工時預設的 reasoning effort。nil = 沿用該模型 route 的預設檔位。
  /// 系統只有 4 檔：低/中/高/超高(xhigh)；使用者口語的 extra/max/ultra 一律正規化到 xhigh。
  public var reasoningEffort: TatwoCodexReasoningEffort?

  public init(
    id: String,
    phase: TatwoScenarioPhase,
    identity: String,
    boundModelIDs: [String],
    responsibility: String,
    dynamicActivation: TatwoDynamicActivation = .allowed,
    enabled: Bool = true,
    reasoningEffort: TatwoCodexReasoningEffort? = nil
  ) {
    self.id = id
    self.phase = phase
    self.identity = identity
    self.boundModelIDs = boundModelIDs
    self.responsibility = responsibility
    self.dynamicActivation = dynamicActivation
    self.enabled = enabled
    self.reasoningEffort = reasoningEffort
  }

  public var identityKind: IdentityKind? {
    switch identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "lead", "主導", "主": return .lead
    case "supervisor", "副審", "監督", "副導", "副": return .supervisor
    case "executor", "執行", "執行手": return .sub
    case "consultant", "顧問": return .consultant
    case "sub", "分工": return .sub
    case "news", "消息", "查證": return .news
    case "verifier", "驗收", "goal 驗收": return .verifier
    default: return nil
    }
  }
}

public struct TatwoScenarioToolBinding: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var registryID: String
  public var phase: TatwoScenarioPhase
  public var loopTemplateID: String?
  public var enabled: Bool
  public var required: Bool
  public var note: String

  public init(
    id: String,
    registryID: String,
    phase: TatwoScenarioPhase,
    loopTemplateID: String? = nil,
    enabled: Bool = true,
    required: Bool = false,
    note: String
  ) {
    self.id = id
    self.registryID = registryID
    self.phase = phase
    self.loopTemplateID = loopTemplateID
    self.enabled = enabled
    self.required = required
    self.note = note
  }
}

public struct TatwoScenarioWorkflowNode: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var phase: TatwoScenarioPhase
  public var title: String
  public var identity: String
  public var detail: String
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var boundModelIDs: [String]
  public var toolRegistryIDs: [String]
  public var enabled: Bool

  public init(
    id: String,
    phase: TatwoScenarioPhase,
    title: String,
    identity: String,
    detail: String,
    x: Double,
    y: Double,
    width: Double = 176,
    height: Double = 82,
    boundModelIDs: [String] = [],
    toolRegistryIDs: [String] = [],
    enabled: Bool = true
  ) {
    self.id = id
    self.phase = phase
    self.title = title
    self.identity = identity
    self.detail = detail
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.boundModelIDs = boundModelIDs
    self.toolRegistryIDs = toolRegistryIDs
    self.enabled = enabled
  }
}

public struct TatwoScenarioWorkflowEdge: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var fromNodeID: String
  public var toNodeID: String
  public var label: String
  public var enabled: Bool

  public init(
    id: String,
    fromNodeID: String,
    toNodeID: String,
    label: String = "",
    enabled: Bool = true
  ) {
    self.id = id
    self.fromNodeID = fromNodeID
    self.toNodeID = toNodeID
    self.label = label
    self.enabled = enabled
  }
}

public struct TatwoScenarioCanvasVersion: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var name: String
  public var createdAt: Date
  public var hash: String
  public var modeConfig: TatwoScenarioModeConfig

  public init(
    id: String,
    name: String,
    createdAt: Date = Date(),
    hash: String,
    modeConfig: TatwoScenarioModeConfig
  ) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.hash = hash
    self.modeConfig = modeConfig
  }
}

public struct TatwoScenarioDynamicPolicy: Codable, Sendable, Equatable {
  public var enabled: Bool
  public var tokenBudgetLabel: String
  public var governorRule: String
  public var humanGateRules: [String]

  public init(
    enabled: Bool = true,
    tokenBudgetLabel: String = "依 Dashboard 設定；正式 goal 不限次數，以 token / 風險 / 人工 gate 控制。",
    governorRule: String = "模型只能提出擴編建議；Loop Governor 根據情境、模式、token、風險與收據批准。",
    humanGateRules: [String] = ["主機實裝", "部署", "金流/交易", "超出 token 預算", "未登記工具"]
  ) {
    self.enabled = enabled
    self.tokenBudgetLabel = tokenBudgetLabel
    self.governorRule = governorRule
    self.humanGateRules = humanGateRules
  }
}

public struct TatwoScenarioModeConfig: Codable, Sendable, Equatable {
  public var mode: WorkModeID
  public var tokenBudget: String
  public var dynamicPolicy: TatwoScenarioDynamicPolicy
  public var bindings: [TatwoScenarioIdentityBinding]
  public var toolBindings: [TatwoScenarioToolBinding]
  public var workflowNodes: [TatwoScenarioWorkflowNode]
  public var workflowEdges: [TatwoScenarioWorkflowEdge]
  public var canvasVersions: [TatwoScenarioCanvasVersion]
  public var receiptRules: [String]
  public var gateRules: [String]
  public var agentsMarkdown: String

  public init(
    mode: WorkModeID,
    tokenBudget: String,
    dynamicPolicy: TatwoScenarioDynamicPolicy = TatwoScenarioDynamicPolicy(),
    bindings: [TatwoScenarioIdentityBinding],
    toolBindings: [TatwoScenarioToolBinding] = [],
    workflowNodes: [TatwoScenarioWorkflowNode] = [],
    workflowEdges: [TatwoScenarioWorkflowEdge] = [],
    canvasVersions: [TatwoScenarioCanvasVersion] = [],
    receiptRules: [String] = [],
    gateRules: [String] = [],
    agentsMarkdown: String = ""
  ) {
    self.mode = mode
    self.tokenBudget = tokenBudget
    self.dynamicPolicy = dynamicPolicy
    self.bindings = bindings
    self.toolBindings = toolBindings
    self.workflowNodes = workflowNodes
    self.workflowEdges = workflowEdges
    self.canvasVersions = canvasVersions
    self.receiptRules = receiptRules
    self.gateRules = gateRules
    self.agentsMarkdown = agentsMarkdown
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case tokenBudget
    case dynamicPolicy
    case bindings
    case toolBindings
    case workflowNodes
    case workflowEdges
    case canvasVersions
    case receiptRules
    case gateRules
    case agentsMarkdown
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decode(WorkModeID.self, forKey: .mode)
    tokenBudget = try container.decode(String.self, forKey: .tokenBudget)
    dynamicPolicy =
      try container.decodeIfPresent(TatwoScenarioDynamicPolicy.self, forKey: .dynamicPolicy)
      ?? TatwoScenarioDynamicPolicy()
    bindings =
      try container.decodeIfPresent([TatwoScenarioIdentityBinding].self, forKey: .bindings)
      ?? []
    toolBindings =
      try container.decodeIfPresent([TatwoScenarioToolBinding].self, forKey: .toolBindings)
      ?? []
    workflowNodes =
      try container.decodeIfPresent([TatwoScenarioWorkflowNode].self, forKey: .workflowNodes)
      ?? []
    workflowEdges =
      try container.decodeIfPresent([TatwoScenarioWorkflowEdge].self, forKey: .workflowEdges)
      ?? []
    canvasVersions =
      try container.decodeIfPresent([TatwoScenarioCanvasVersion].self, forKey: .canvasVersions)
      ?? []
    receiptRules =
      try container.decodeIfPresent([String].self, forKey: .receiptRules)
      ?? []
    gateRules =
      try container.decodeIfPresent([String].self, forKey: .gateRules)
      ?? []
    agentsMarkdown =
      try container.decodeIfPresent(String.self, forKey: .agentsMarkdown)
      ?? ""
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(tokenBudget, forKey: .tokenBudget)
    try container.encode(dynamicPolicy, forKey: .dynamicPolicy)
    try container.encode(bindings, forKey: .bindings)
    try container.encode(toolBindings, forKey: .toolBindings)
    try container.encode(workflowNodes, forKey: .workflowNodes)
    try container.encode(workflowEdges, forKey: .workflowEdges)
    try container.encode(canvasVersions, forKey: .canvasVersions)
    try container.encode(receiptRules, forKey: .receiptRules)
    try container.encode(gateRules, forKey: .gateRules)
    try container.encode(agentsMarkdown, forKey: .agentsMarkdown)
  }

  public var canvasSnapshot: TatwoScenarioModeConfig {
    var copy = self
    copy.canvasVersions = []
    return copy
  }

  public var canvasSnapshotHash: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(canvasSnapshot)) ?? Data()
    let digest = SHA256.hash(data: data)
    return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
  }
}

public struct TatwoCustomScenarioConfig: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var displayName: String
  public var baseScenario: ScenarioID?
  public var builtin: Bool
  public var enabledModes: [WorkModeID]
  public var modeConfigs: [WorkModeID: TatwoScenarioModeConfig]
  public var updatedAt: Date

  public init(
    id: String,
    displayName: String,
    baseScenario: ScenarioID?,
    builtin: Bool = false,
    enabledModes: [WorkModeID] = WorkModeID.allCases,
    modeConfigs: [WorkModeID: TatwoScenarioModeConfig],
    updatedAt: Date = Date(timeIntervalSince1970: 1_782_736_400)
  ) {
    self.id = id
    self.displayName = displayName
    self.baseScenario = baseScenario
    self.builtin = builtin
    self.enabledModes = enabledModes
    self.modeConfigs = modeConfigs
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case baseScenario
    case builtin
    case enabledModes
    case modeConfigs
    case updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    baseScenario = try container.decodeIfPresent(ScenarioID.self, forKey: .baseScenario)
    builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
    enabledModes = try container.decodeIfPresent([WorkModeID].self, forKey: .enabledModes) ?? WorkModeID.allCases
    updatedAt =
      try container.decodeIfPresent(Date.self, forKey: .updatedAt)
      ?? Date(timeIntervalSince1970: 1_782_736_400)

    if let keyedConfigs = try? container.decode([String: TatwoScenarioModeConfig].self, forKey: .modeConfigs) {
      modeConfigs = Dictionary(
        uniqueKeysWithValues: keyedConfigs.compactMap { key, config in
          guard let mode = try? WorkModeID.parse(key) else { return nil }
          return (mode, config)
        })
    } else {
      // Backward compatibility for early staging files whose enum-keyed
      // dictionary encoded as ["M", {...}, "S", {...}].
      modeConfigs =
        try container.decodeIfPresent([WorkModeID: TatwoScenarioModeConfig].self, forKey: .modeConfigs)
        ?? [:]
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encodeIfPresent(baseScenario, forKey: .baseScenario)
    try container.encode(builtin, forKey: .builtin)
    try container.encode(enabledModes, forKey: .enabledModes)
    try container.encode(updatedAt, forKey: .updatedAt)
    let keyedConfigs = Dictionary(
      uniqueKeysWithValues: modeConfigs.map { mode, config in
        (mode.rawValue, config)
      })
    try container.encode(keyedConfigs, forKey: .modeConfigs)
  }

  public var displayCategory: String {
    let parts = displayName.components(separatedBy: " · ")
    return parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? parts.first!.trimmingCharacters(in: .whitespacesAndNewlines)
      : "其他"
  }
}

public struct TatwoScenarioDisplayGroup: Sendable, Identifiable, Equatable {
  public var id: String { category }
  public let category: String
  public let scenarios: [TatwoCustomScenarioConfig]

  public init(category: String, scenarios: [TatwoCustomScenarioConfig]) {
    self.category = category
    self.scenarios = scenarios
  }
}

public struct TatwoScenarioConfigBookV1: Codable, Sendable, Equatable {
  public var schema: String
  public var scenarios: [TatwoCustomScenarioConfig]
  public var updatedAt: Date

  public init(
    schema: String = "TatwoScenarioConfigBookV1",
    scenarios: [TatwoCustomScenarioConfig] = TatwoScenarioConfigDefaults.book.scenarios,
    updatedAt: Date = Date(timeIntervalSince1970: 1_782_736_400)
  ) {
    self.schema = schema
    self.scenarios = scenarios
    self.updatedAt = updatedAt
  }

  public func scenario(id: String) -> TatwoCustomScenarioConfig? {
    scenarios.first { $0.id == id }
  }

  public func modeConfig(scenarioID: String, mode: WorkModeID) -> TatwoScenarioModeConfig? {
    scenario(id: scenarioID)?.modeConfigs[mode]
  }

  public func normalizedForCurrentDefaults() -> TatwoScenarioConfigBookV1 {
    let currentSeeds = TatwoScenarioConfigDefaults.round13SeedScenarios
    let seedIDs = Set(currentSeeds.map(\.id))
    let seedNames = Set(currentSeeds.map(\.displayName))
    func isGenericLegacyGarbage(_ scenario: TatwoCustomScenarioConfig) -> Bool {
      let name = scenario.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if name == "通用" || name == "日常" || name.localizedCaseInsensitiveContains("通用 副本") {
        return true
      }
      if scenario.id.hasPrefix("custom-copy-daily") || scenario.id.hasPrefix("staging-daily") {
        return true
      }
      return false
    }
    func seedWithPreservedCanvasState(_ seed: TatwoCustomScenarioConfig) -> TatwoCustomScenarioConfig {
      guard let current = scenarios.first(where: { $0.id == seed.id || $0.displayName == seed.displayName }),
            !isGenericLegacyGarbage(current)
      else {
        return seed
      }
      var merged = seed
      merged.updatedAt = current.updatedAt
      for mode in WorkModeID.allCases {
        guard var seedMode = merged.modeConfigs[mode],
              let currentMode = current.modeConfigs[mode]
        else { continue }
        // Round 13 resets the built-in scenario list and identity bindings, but
        // saved canvas edits on the surviving seed IDs are user staging state.
        // Keep only canvas-shaped state so old "通用" config text/bindings do
        // not leak back into the six clean named seeds.
        if !currentMode.workflowNodes.isEmpty || !currentMode.workflowEdges.isEmpty || !currentMode.canvasVersions.isEmpty {
          seedMode.workflowNodes = currentMode.workflowNodes
          seedMode.workflowEdges = currentMode.workflowEdges
          seedMode.canvasVersions = currentMode.canvasVersions
          merged.modeConfigs[mode] = seedMode
        }
      }
      return merged
    }
    let preservedCustom = scenarios.filter { scenario in
      guard !seedIDs.contains(scenario.id), !seedNames.contains(scenario.displayName) else { return false }
      if isGenericLegacyGarbage(scenario) { return false }
      return !scenario.builtin
    }
    return TatwoScenarioConfigBookV1(
      schema: schema,
      scenarios: currentSeeds.map(seedWithPreservedCanvasState) + preservedCustom,
      updatedAt: updatedAt
    )
  }

  public var scenarioDisplayGroups: [TatwoScenarioDisplayGroup] {
    var groups: [(category: String, scenarios: [TatwoCustomScenarioConfig])] = []
    for scenario in scenarios {
      let category = scenario.displayCategory
      if let index = groups.firstIndex(where: { $0.category == category }) {
        groups[index].scenarios.append(scenario)
      } else {
        groups.append((category: category, scenarios: [scenario]))
      }
    }
    return groups.map { TatwoScenarioDisplayGroup(category: $0.category, scenarios: $0.scenarios) }
  }

  public var stableHash: String {
    // Hash only semantic scenario config fields. `updatedAt` is dashboard
    // metadata, and Swift Dictionary Codable order is not stable enough for a
    // contract hash after disk round-trips, so build a sorted canonical stream.
    var parts: [String] = []
    func append(_ key: String, _ value: String) {
      parts.append("\(key.count):\(key)=\(value.count):\(value)")
    }

    append("schema", schema)
    for scenario in scenarios.sorted(by: { $0.id < $1.id }) {
      append("scenario.id", scenario.id)
      append("scenario.displayName", scenario.displayName)
      append("scenario.baseScenario", scenario.baseScenario?.rawValue ?? "")
      append("scenario.builtin", String(scenario.builtin))
      append("scenario.enabledModes", scenario.enabledModes.sorted().map(\.rawValue).joined(separator: ","))

      for mode in scenario.modeConfigs.keys.sorted() {
        guard let config = scenario.modeConfigs[mode] else { continue }
        let prefix = "scenario.\(scenario.id).mode.\(mode.rawValue)"
        append("\(prefix).mode", config.mode.rawValue)
        append("\(prefix).tokenBudget", config.tokenBudget)
        append("\(prefix).dynamic.enabled", String(config.dynamicPolicy.enabled))
        append("\(prefix).dynamic.tokenBudgetLabel", config.dynamicPolicy.tokenBudgetLabel)
        append("\(prefix).dynamic.governorRule", config.dynamicPolicy.governorRule)
        append("\(prefix).dynamic.humanGateRules", config.dynamicPolicy.humanGateRules.joined(separator: "\u{1F}"))
        append("\(prefix).receiptRules", config.receiptRules.joined(separator: "\u{1F}"))
        append("\(prefix).gateRules", config.gateRules.joined(separator: "\u{1F}"))
        append("\(prefix).agentsMarkdown", config.agentsMarkdown)

        for binding in config.bindings.sorted(by: {
          if $0.phase != $1.phase { return $0.phase < $1.phase }
          return $0.id < $1.id
        }) {
          let bindingPrefix = "\(prefix).binding.\(binding.id)"
          append("\(bindingPrefix).id", binding.id)
          append("\(bindingPrefix).phase", binding.phase.rawValue)
          append("\(bindingPrefix).identity", binding.identity)
          append("\(bindingPrefix).boundModelIDs", binding.boundModelIDs.joined(separator: "\u{1F}"))
          append("\(bindingPrefix).responsibility", binding.responsibility)
          append("\(bindingPrefix).dynamicActivation", binding.dynamicActivation.rawValue)
          append("\(bindingPrefix).enabled", String(binding.enabled))
          append("\(bindingPrefix).reasoningEffort", binding.reasoningEffort?.rawValue ?? "")
        }

        for toolBinding in config.toolBindings.sorted(by: {
          if $0.phase != $1.phase { return $0.phase < $1.phase }
          return $0.id < $1.id
        }) {
          let toolPrefix = "\(prefix).tool.\(toolBinding.id)"
          append("\(toolPrefix).id", toolBinding.id)
          append("\(toolPrefix).registryID", toolBinding.registryID)
          append("\(toolPrefix).phase", toolBinding.phase.rawValue)
          append("\(toolPrefix).loopTemplateID", toolBinding.loopTemplateID ?? "")
          append("\(toolPrefix).enabled", String(toolBinding.enabled))
          append("\(toolPrefix).required", String(toolBinding.required))
          append("\(toolPrefix).note", toolBinding.note)
        }

        for node in config.workflowNodes.sorted(by: { $0.id < $1.id }) {
          let nodePrefix = "\(prefix).workflowNode.\(node.id)"
          append("\(nodePrefix).id", node.id)
          append("\(nodePrefix).phase", node.phase.rawValue)
          append("\(nodePrefix).title", node.title)
          append("\(nodePrefix).identity", node.identity)
          append("\(nodePrefix).detail", node.detail)
          append("\(nodePrefix).x", String(format: "%.3f", node.x))
          append("\(nodePrefix).y", String(format: "%.3f", node.y))
          append("\(nodePrefix).width", String(format: "%.3f", node.width))
          append("\(nodePrefix).height", String(format: "%.3f", node.height))
          append("\(nodePrefix).boundModelIDs", node.boundModelIDs.joined(separator: "\u{1F}"))
          append("\(nodePrefix).toolRegistryIDs", node.toolRegistryIDs.joined(separator: "\u{1F}"))
          append("\(nodePrefix).enabled", String(node.enabled))
        }

        for edge in config.workflowEdges.sorted(by: { $0.id < $1.id }) {
          let edgePrefix = "\(prefix).workflowEdge.\(edge.id)"
          append("\(edgePrefix).id", edge.id)
          append("\(edgePrefix).fromNodeID", edge.fromNodeID)
          append("\(edgePrefix).toNodeID", edge.toNodeID)
          append("\(edgePrefix).label", edge.label)
          append("\(edgePrefix).enabled", String(edge.enabled))
        }
      }
    }

    let data = Data(parts.joined(separator: "\n").utf8)
    let digest = SHA256.hash(data: data)
    return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
  }
}

public enum TatwoScenarioConfigDefaults {
  public static let exactXXLSolOpusLunaGrokScenarioID =
    "general-xxl-sol-opus5-luna-grok-exact"
  public static let exactXXLSolOpusLunaGrokScenarioName =
    "通用 · XXL · Sol主導＋Opus5監工＋Luna/Grok分工"
  public static let nativeDevelopmentXXLSolOpusScenarioID =
    "general-xxl-sol-opus5-native-development-exact"
  public static let nativeDevelopmentXXLSolOpusScenarioName =
    "通用 · XXL · Sol High＋Opus5 High 原生開發"
  public static let nativeDevelopmentXXLFableGrokScenarioID =
    "general-xxl-fable5-grok46-native-development-exact"
  public static let nativeDevelopmentXXLFableGrokScenarioName =
    "通用 · XXL · Fable5 Medium → Grok4.6 High 原生開發"
  public static let exactXXLSolFableLunaGrokScenarioID =
    "general-xxl-sol-fable5-luna-grok-exact"
  public static let exactXXLSolFableLunaGrokScenarioName =
    "通用 · XXL · Sol主導＋Fable副審＋Luna/Grok分工"

  public static let uiUXDefaultLoopTemplateIDs: [String] = [
    TatwoUIFireworksLoopTemplate.id,
  ]

  public static let round13ScenarioNames: [String] = [
    "通用 · XXL · fable5+sol主導",
    "通用 · XL · fable5主導",
    "通用 · L · fable5主導",
    "通用 · L · sol主導",
    "通用 · M · sol主導",
    "通用 · S · terra",
    "UI UX · XL · 8方向煙火（gpt5.5主導·sonnet5評審）",
    "UI UX · L · 5方向煙火",
    "UI UX · M · 3方向煙火",
    "UI UX · S · 2方向輕評",
  ]

  public static let round9ScenarioNames: [String] = [
    "XL 重型 · fable5主導＋gpt5.5＋sonnet5",
    "L 專案 · fable5＋gpt5.5",
    "M 協作 · gpt5.5＋sonnet5",
    "M 協作 · gpt5.5＋sonnet5＋minimax",
    "M 協作 · gpt5.5＋minimax＋grok",
    "S 小修 · gpt5.5",
  ]

  private static func tool(
    _ registryID: String,
    phase: TatwoScenarioPhase,
    required: Bool = false,
    note: String
  ) -> TatwoScenarioToolBinding {
    TatwoScenarioToolBinding(
      id: "\(registryID)-\(phase.rawValue)",
      registryID: registryID,
      phase: phase,
      enabled: true,
      required: required,
      note: note)
  }

  public static let generalToolBindings: [TatwoScenarioToolBinding] = [
    tool("tatwo-ultrawork", phase: .plan, required: true, note: "讀取 Work OS contract、模式、情境、收據規則。"),
    tool("chatgpt-pro-mcp", phase: .loops, required: true, note: "需要長研究、反方觀點或 Pro 審稿時啟用。"),
    tool("gitnexus", phase: .plan, note: "M/L/XL 需要專案地圖或影響範圍時啟用。"),
    tool("product-design", phase: .goal, note: "UI/UJ 或工作流視覺改動時提交截圖副審收據。"),
    tool("web-check", phase: .goal, note: "前端任務提交本地工程健檢收據。"),
  ]

  public static func defaultModeConfig(_ mode: WorkModeID) -> TatwoScenarioModeConfig {
    switch mode {
    case .s:
      return TatwoScenarioModeConfig(
        mode: .s,
        tokenBudget: "S 小修：主線-only；正式 goal 不限次，以 token、風險與有效推進控制。",
        bindings: [
          TatwoScenarioIdentityBinding(
            id: "daily-s-plan-lead",
            phase: .plan,
            identity: "主導",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .lead),
            responsibility: "快速釐清目標、查找或微調；不啟動 domain fan-out。",
            dynamicActivation: .always),
          TatwoScenarioIdentityBinding(
            id: "daily-s-goal-verifier",
            phase: .goal,
            identity: "驗收",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .verifier),
            responsibility: "用本機證據或直接結果驗收；缺證據不宣稱完成。",
            dynamicActivation: .always),
        ],
        toolBindings: generalToolBindings.filter { ["tatwo-ultrawork"].contains($0.registryID) },
        receiptRules: ["contract-id", "s-no-sub", "local-check", "cleanup-inventory"],
        gateRules: ["S 不啟動 sub/domain fan-out", "正式 goal 不受 5 cycles 限制", "缺直接證據就不完成"],
        agentsMarkdown: "# 通用 S 小修\n主線-only。Plan 主導：GPT5.4。Goal 驗收：GPT5.4。MiniMax M3 僅在使用者要求時作草稿參考，不自動變成 sub。")
    case .m:
      return dailyM
    case .l:
      return TatwoScenarioModeConfig(
        mode: .l,
        tokenBudget: "L 專案：允許單領域深 loop；正式 goal 不限次，以 token、風險、沙盒與人工 gate 控制。",
        bindings: [
          TatwoScenarioIdentityBinding(
            id: "daily-l-plan-lead",
            phase: .plan,
            identity: "主導",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .lead),
            responsibility: "建立主線、拆單一重點 domain loop、定義回滾與驗收邊界。",
            dynamicActivation: .always),
          TatwoScenarioIdentityBinding(
            id: "daily-l-loops-supervisor",
            phase: .loops,
            identity: "副審",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .supervisor),
            responsibility: "監督 domain loop 是否偏航，抓測試缺口與整合風險。",
            dynamicActivation: .allowed),
          TatwoScenarioIdentityBinding(
            id: "daily-l-loops-sub",
            phase: .loops,
            identity: "sub",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .sub),
            responsibility: "補候選方案、反例、checklist 或資料查證；不得自行放行。",
            dynamicActivation: .allowed),
          TatwoScenarioIdentityBinding(
            id: "daily-l-goal-verifier",
            phase: .goal,
            identity: "驗收",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .verifier),
            responsibility: "驗收沙盒、回滾、測試與 domain loop receipt 是否足夠。",
            dynamicActivation: .always),
        ],
        toolBindings: generalToolBindings,
        receiptRules: ["contract-id", "identity-bindings", "loop-governor-decision", "sandbox-or-degraded", "rollback", "cleanup-inventory"],
        gateRules: ["L 需 staging/sandbox receipt", "主機實裝需人工 gate", "沙盒評分才限制 5 execution cycles"],
        agentsMarkdown: "# 通用 L 專案\nPlan 主導：GPT5.5、OPUS5。Loops 副審：Sonnet5、GPT5.4。Loops sub：MiniMax M3、Grok、Haiku。Goal 驗收：OPUS5、GPT5.5。")
    case .xl, .xxl:
      return TatwoScenarioModeConfig(
        mode: mode,
        tokenBudget: "XL 重型：mainline + 多 domain loops；正式 goal 不限次，以 token、風險、人工 gate、沙盒與有效推進控制。",
        bindings: [
          TatwoScenarioIdentityBinding(
            id: "daily-xl-plan-lead",
            phase: .plan,
            identity: "主導",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .lead),
            responsibility: "定義主線、切分多領域 loops、控制範圍、決定是否升級或收斂。",
            dynamicActivation: .always),
          TatwoScenarioIdentityBinding(
            id: "daily-xl-loops-supervisor",
            phase: .loops,
            identity: "副審",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .supervisor),
            responsibility: "逐段審查 loops 結論、風險、測試與偏航；要求 sub 補證據。",
            dynamicActivation: .always),
          TatwoScenarioIdentityBinding(
            id: "daily-xl-loops-sub",
            phase: .loops,
            identity: "sub",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .sub),
            responsibility: "大量候選、反例、清單、消息或邊界測試；只能提交 receipt。",
            dynamicActivation: .allowed),
          TatwoScenarioIdentityBinding(
            id: "daily-xl-goal-verifier",
            phase: .goal,
            identity: "驗收",
            boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .verifier),
            responsibility: "彙整所有 loops、沙盒、回滾與人工 gate；未滿收據即 rollback_required。",
            dynamicActivation: .always),
        ],
        toolBindings: generalToolBindings,
        receiptRules: ["contract-id", "identity-bindings", "loop-governor-decision", "multi-domain-loop", "sandbox", "human-gate", "rollback", "cleanup-inventory"],
        gateRules: ["XL 必須 staging/sandbox", "主機實裝必須人工授權", "正式 goal 不限次但不得無效重複消耗"],
        agentsMarkdown: "# 通用 XL 重型\nPlan 主導：GPT5.5、OPUS5。Loops 副審：Sonnet5、GPT5.4。Loops sub：MiniMax M3、Grok、Haiku。Goal 驗收：OPUS5、GPT5.5。Work OS contract 是最高主導。")
    }
  }

  public static var defaultDailyModeConfigs: [WorkModeID: TatwoScenarioModeConfig] {
    Dictionary(uniqueKeysWithValues: WorkModeID.allCases.map { ($0, defaultModeConfig($0)) })
  }

  private static func canonicalGatewayBindings(
    _ bindings: [TatwoScenarioIdentityBinding]
  ) -> [TatwoScenarioIdentityBinding] {
    bindings.map { binding in
      guard let identity = binding.identityKind else { return binding }
      var aligned = binding
      aligned.boundModelIDs = TatwoGatewayDispatchCatalog.models(for: identity)
      return aligned
    }
  }

  // 通用族 binding 速記：保留使用者顯式綁定的模型與 effort，不經 canonicalGatewayBindings 壓平。
  private static func gBind(
    _ id: String,
    _ phase: TatwoScenarioPhase,
    _ identity: String,
    _ models: [String],
    effort: TatwoCodexReasoningEffort?,
    _ responsibility: String,
    _ activation: TatwoDynamicActivation
  ) -> TatwoScenarioIdentityBinding {
    TatwoScenarioIdentityBinding(
      id: id,
      phase: phase,
      identity: identity,
      boundModelIDs: models,
      responsibility: responsibility,
      dynamicActivation: activation,
      enabled: true,
      reasoningEffort: effort)
  }

  // 通用族專用：拿 mode 的預設 receipt/gate 規則，但用「使用者顯式」的 bindings，模型不被 catalog 覆蓋。
  private static func generalModeConfigs(
    declaredMode: WorkModeID,
    tokenBudget: String,
    bindings: [TatwoScenarioIdentityBinding],
    agentsMarkdown: String
  ) -> [WorkModeID: TatwoScenarioModeConfig] {
    var configs = defaultDailyModeConfigs
    var declared = defaultModeConfig(declaredMode)
    declared.tokenBudget = tokenBudget
    declared.bindings = bindings
    declared.toolBindings = generalToolBindings
    declared.agentsMarkdown = agentsMarkdown
    configs[declaredMode] = declared
    return configs
  }

  // sub 候選池共用說明：不是全部同時啟動。
  private static let subPoolNote =
    "候選池：M/L 預設最多啟動一個，XL/XXL 由 Loop Governor 依 token/風險動態批准；只交 receipts，不自行放行。"

  public static var round13SeedScenarios: [TatwoCustomScenarioConfig] {
    [
      TatwoCustomScenarioConfig(
        id: exactXXLSolOpusLunaGrokScenarioID,
        displayName: exactXXLSolOpusLunaGrokScenarioName,
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .xxl,
          tokenBudget:
            "XXL 編排：Sol 唯一主導（fast/low）；Opus 5 是高強度 Loops Supervisor；Luna 與 Grok 為兩條獨立 xhigh loops/sub。Fable route 停用；每條 route 只認已簽發 contract binding。",
          bindings: [
            gBind(
              "general-xxl-sol-opus-exact-plan-lead-sol",
              .plan,
              "主導",
              ["gpt-5.6-sol"],
              effort: .low,
              "唯一 Plan Lead／主導；service tier fast、reasoning low。不得被 supervisor 或 loops sub 取代。",
              .always),
            gBind(
              "general-xxl-sol-opus-exact-loops-supervisor-opus5",
              .loops,
              "副審",
              ["opus-5"],
              effort: .high,
              "Loops Supervisor／高強度副審；統籌 Loops、反駁與收據檢查，不自過自審。",
              .always),
            gBind(
              "general-xxl-sol-opus-exact-loops-verifier-opus5",
              .loops,
              "驗收",
              ["opus-5"],
              effort: .high,
              "Ops/domain verifier：獨立於 supervisor source slot，承接驗證類 loops 並提交可重跑收據；不得取代 Goal Judge。",
              .always),
            gBind(
              "general-xxl-sol-opus-exact-loops-sub-luna",
              .loops,
              "sub",
              ["gpt-5.6-luna"],
              effort: .xhigh,
              "獨立 Luna Max Loops Sub；提交候選、反例與 receipt，由 Sol 收斂。",
              .allowed),
            gBind(
              "general-xxl-sol-opus-exact-loops-sub-grok",
              .loops,
              "sub",
              ["grok-build"],
              effort: .xhigh,
              "獨立 Grok Loops Sub；provider 未證明可承接前 fail closed，不以 prompt 假裝 effort 生效。",
              .allowed),
            gBind(
              "general-xxl-sol-opus-exact-goal-verifier-opus5",
              .goal,
              "驗收",
              ["opus-5"],
              effort: .high,
              "Goal Verifier：使用獨立 goal source slot 驗證 branches、測試與收據；不得沿用 supervisor 自評直接放行。",
              .always),
          ],
          agentsMarkdown:
            "# 通用 · XXL · Sol/Opus/Luna/Grok exact route contract\nSol 是唯一主導（fast/low）。Opus 5 是 Loops Supervisor、Ops verifier 與 Goal Verifier（各自 source slot，high）。Luna Max 與 Grok 是兩個獨立 loops/sub（xhigh）。本 scenario 不包含 Fable；不得 fallback 後冒稱原 route。")),
      TatwoCustomScenarioConfig(
        id: nativeDevelopmentXXLSolOpusScenarioID,
        displayName: nativeDevelopmentXXLSolOpusScenarioName,
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .xxl,
          tokenBudget:
            "XXL 原生開發：Sol High 建立計畫並擔任 Loops 執行手；Opus 5 High 擔任 Loops Supervisor 並在 Goal 階段獨立驗證。只使用 TATWO 原生 runtime，禁止失敗後 fallback 到外部 Codex／Claude CLI。",
          bindings: [
            gBind(
              "general-xxl-native-development-plan-lead-sol",
              .plan,
              "主導",
              ["gpt-5.6-sol"],
              effort: .high,
              "Plan Lead：建立原生開發計畫、工作邊界與驗收條件；不以規劃身份取得 mutation。",
              .always),
            gBind(
              "general-xxl-native-development-loops-executor-sol",
              .loops,
              "執行手",
              ["gpt-5.6-sol"],
              effort: .high,
              "Loops Host Executor：使用 TATWO 原生 read/search/edit/shell/build/test/Git 工具施工並提交 receipts。",
              .always),
            gBind(
              "general-xxl-native-development-loops-supervisor-opus5",
              .loops,
              "副審",
              ["opus-5"],
              effort: .high,
              "Loops Supervisor：以 Opus 5 High 對抗驗證、補測並可在同一已簽發 contract 下執行受限原生工具；不得自過自審。",
              .always),
            gBind(
              "general-xxl-native-development-loops-verifier-opus5",
              .loops,
              "驗收",
              ["opus-5"],
              effort: .high,
              "Ops/domain verifier：以獨立 loops source slot 驗證執行結果與可重跑收據；不得取代 Goal Judge。",
              .always),
            gBind(
              "general-xxl-native-development-goal-verifier-opus5",
              .goal,
              "驗收",
              ["opus-5"],
              effort: .high,
              "Goal Verifier：獨立核對工具收據、測試、diff、安裝 App 與真人操作證據；證據不足不得通過。",
              .always),
          ],
          agentsMarkdown:
            "# 通用 · XXL · Sol High / Opus 5 High 原生開發\nSol High 是 Plan Lead 與 Loops Host Executor。Opus 5 High 是 Loops Supervisor 與 Goal Verifier。兩者只走 TATWO 原生 runtime；外部 Codex／Claude CLI 不得作 production fallback。")),
      TatwoCustomScenarioConfig(
        id: nativeDevelopmentXXLFableGrokScenarioID,
        displayName: nativeDevelopmentXXLFableGrokScenarioName,
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .xxl,
          tokenBudget:
            "XXL 原生開發：Fable 5 Medium 先完成 Tatwo Island／液態玻璃 lane；其完成收據成立後，Grok 4.6 High 才可開始 Aurora lane。兩條 exact route 都使用訂閱登入與 TATWO 原生 Host Executor；禁止 Sol、Opus、API 或任何 fallback。",
          bindings: [
            gBind(
              "general-xxl-native-development-plan-lead-fable5",
              .plan,
              "主導",
              ["fable-5"],
              effort: .medium,
              "Plan Lead：固化 Island → Aurora 順序、protected surfaces 與驗收條件；不以規劃身份取得 mutation。",
              .always),
            gBind(
              "general-xxl-native-development-loops-executor-fable5",
              .loops,
              "執行手",
              ["fable-5"],
              effort: .medium,
              "第一段 Host Executor：只處理 Tatwo Island 減碼、縮展與液態玻璃；完成並寫入 ledger 後才解鎖 Grok lane。",
              .always),
            gBind(
              "general-xxl-native-development-loops-supervisor-fable5",
              .loops,
              "副審",
              ["fable-5"],
              effort: .medium,
              "Loops Supervisor：承接 debug domain 與第一段對抗驗證；不得取代 Host Executor、自過自審或提前啟動 Grok lane。",
              .always),
            gBind(
              "general-xxl-native-development-loops-executor-grok46",
              .loops,
              "執行手",
              ["grok-build"],
              effort: .high,
              "第二段 Host Executor：只處理 Aurora 主題；必須看到 Fable lane completed receipt，且不得變動 Fable5 紀念主題與 Ultrawork 漸變拉條。",
              .allowed),
            gBind(
              "general-xxl-native-development-loops-verifier-fable5",
              .loops,
              "驗收",
              ["fable-5"],
              effort: .medium,
              "Loops Verifier：承接 ops domain、獨立核對每段 runtime 與 receipt；不得取代 Goal Verifier 或讓 Grok 提前執行。",
              .always),
            gBind(
              "general-xxl-native-development-goal-verifier-fable5",
              .goal,
              "驗收",
              ["fable-5"],
              effort: .medium,
              "Goal Verifier：核對 Island、Aurora、exact route、受保護表面、視覺與資源收據；不得以任一 executor 自報取代證據。",
              .always),
          ],
          agentsMarkdown:
            "# 通用 · XXL · Fable 5 / Grok 4.6 exact native development\n執行順序固定：Fable 5 Medium 完成 Island lane → Grok 4.6 High 完成 Aurora lane → Fable 5 Medium 依收據驗收。只准訂閱登入與 TATWO 原生 runtime；禁止 API、Sol／Opus 代換與兩條 heavy lane 同時執行。")),
      TatwoCustomScenarioConfig(
        id: exactXXLSolFableLunaGrokScenarioID,
        displayName: exactXXLSolFableLunaGrokScenarioName,
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .xxl,
          tokenBudget:
            "XXL 編排：Sol 唯一主導；Fable 5 獨立副審；Luna 與 Grok 為兩條獨立 loops/sub。只有已簽發 contract 明訂的 effort 才是 required；route 無該 provider 能力證據時 fail closed。",
          bindings: [
            gBind(
              "general-xxl-exact-plan-lead-sol",
              .plan,
              "主導",
              ["gpt-5.6-sol"],
              effort: .low,
              "唯一 Plan Lead／主導；service tier fast、reasoning low。不得被 reviewer 或 loops sub 取代。",
              .always),
            gBind(
              "general-xxl-exact-loops-supervisor-fable5",
              .loops,
              "副審",
              ["fable-5"],
              effort: nil,
              "獨立 reviewer／Loops Supervisor；不要求 native effort，只提交審查證據，不自過自審，不得 fallback 到 Opus 冒稱 Fable。",
              .always),
            gBind(
              "general-xxl-exact-loops-sub-luna",
              .loops,
              "sub",
              ["gpt-5.6-luna"],
              effort: .xhigh,
              "獨立 Loops Sub；提交候選、反例與 receipt，由 Sol 收斂。",
              .allowed),
            gBind(
              "general-xxl-exact-loops-sub-grok",
              .loops,
              "sub",
              ["grok-build"],
              effort: .xhigh,
              "獨立 Grok Loops Sub；xhigh 只是 contract request。provider 未證明可承接前必須 fail closed，不得以 prompt 假裝生效。",
              .allowed),
          ],
          agentsMarkdown:
            "# 通用 · XXL · exact route contract\nSol 是唯一主導（fast/low）。Fable 5 是獨立副審（不要求 native effort）。Luna 與 Grok 是兩個獨立 loops/sub（各 request xhigh）。每輪 effort 只認已簽發 contract binding；provider 未 attestation 不宣稱 effective，contract-required unsupported effort 一律 fail closed。")),
      TatwoCustomScenarioConfig(
        id: "general-xxl-fable5-sol",
        displayName: round13ScenarioNames[0],
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .xxl,
          tokenBudget: "XXL 編排：fable-5＋gpt-5.6-sol 雙主導，terra 獨立 refute 副審；mainline＋多 domain loops，正式 goal 不限次，以 token、風險、人工 gate、沙盒與有效推進控制。",
          bindings: [
            gBind("general-xxl-plan-lead-fable5", .plan, "主導", ["fable-5"], effort: .high,
              "編排主線、切分多領域 loops、控制範圍與收斂；與 sol 雙主導。", .always),
            gBind("general-xxl-plan-lead-sol", .plan, "主導", ["gpt-5.6-sol"], effort: .xhigh,
              "co-lead：依 contract 主力執行局部 loops 並回交 receipts。", .always),
            gBind("general-xxl-loops-supervisor", .loops, "副審", ["gpt-5.6-terra"], effort: .xhigh,
              "refute-first 獨立副審、量測與漂移檢查；非主導本人，可揪自審漏洞。", .always),
            gBind("general-xxl-loops-sub", .loops, "sub", ["gpt-5.6-luna"], effort: .xhigh,
              subPoolNote, .allowed),
            gBind("general-xxl-goal-verifier", .goal, "驗收", ["fable-5"], effort: .high,
              "主導裁決＋terra 獨立簽核＋build/test/截圖/rollback receipts，不以自我宣稱代替。", .always),
          ],
          agentsMarkdown: "# 通用 · XXL · fable5+sol主導\n主導：fable-5（高）＋gpt-5.6-sol（超高）雙主導。副審：gpt-5.6-terra（超高，refute-first 獨立）。sub 候選：gpt-5.6-luna（超高）。驗收：fable-5 裁決＋terra 獨立簽核。\neffort 說明：使用者口語 extra/max/ultra 系統無此檔，一律對到最高檔『超高(xhigh)』。")),
      TatwoCustomScenarioConfig(
        id: "general-xl-fable5",
        displayName: round13ScenarioNames[1],
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .xl,
          tokenBudget: "XL 重型：fable-5 主導，terra 獨立副審；mainline＋多 domain loops，正式 goal 不限次，以 token、風險、人工 gate、沙盒與有效推進控制。",
          bindings: [
            gBind("general-xl-plan-lead", .plan, "主導", ["fable-5"], effort: .high,
              "定義主線、切分多領域 loops、控制範圍與收斂條件。", .always),
            gBind("general-xl-loops-supervisor", .loops, "副審", ["gpt-5.6-terra"], effort: .xhigh,
              "refute-first 獨立 reviewer gate；審 patch、抓缺口、阻止無證據通過。", .always),
            gBind("general-xl-loops-sub", .loops, "sub", ["gpt-5.6-sol", "gpt-5.6-luna"], effort: .xhigh,
              subPoolNote, .allowed),
            gBind("general-xl-goal-verifier", .goal, "驗收", ["fable-5"], effort: .high,
              "主導裁決＋terra 副審通過＋build/test/rollback receipts。", .always),
          ],
          agentsMarkdown: "# 通用 · XL · fable5主導\n主導：fable-5（高）。副審：gpt-5.6-terra（超高，refute-first 獨立）。sub 候選：gpt-5.6-sol、gpt-5.6-luna（超高）。驗收：fable-5 裁決＋terra 副審。")),
      TatwoCustomScenarioConfig(
        id: "general-l-fable5",
        displayName: round13ScenarioNames[2],
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .l,
          tokenBudget: "L 專案：fable-5 主導，sol 副審；允許單領域深 loop，正式 goal 不限次，以 token、風險、沙盒與人工 gate 控制。",
          bindings: [
            gBind("general-l-fable5-plan-lead", .plan, "主導", ["fable-5"], effort: .high,
              "建立主線、拆單一重點 domain loop、定義回滾與驗收邊界。", .always),
            gBind("general-l-fable5-loops-supervisor", .loops, "副審", ["gpt-5.6-sol"], effort: .xhigh,
              "獨立審查 domain loop 是否偏航，抓測試缺口與整合風險（sol≠主導，審查有效）。", .always),
            gBind("general-l-fable5-loops-sub", .loops, "sub", ["gpt-5.6-terra", "gpt-5.6-luna", "sonnet-5"], effort: .xhigh,
              subPoolNote, .allowed),
            gBind("general-l-fable5-goal-verifier", .goal, "驗收", ["fable-5"], effort: .high,
              "裁決實作與設計意圖是否收斂；要求 sol 副審與測試 receipts。", .always),
          ],
          agentsMarkdown: "# 通用 · L · fable5主導\n主導：fable-5（高）。副審：gpt-5.6-sol（超高，獨立）。sub 候選：gpt-5.6-terra、gpt-5.6-luna（超高）、sonnet-5。驗收：fable-5 裁決。")),
      TatwoCustomScenarioConfig(
        id: "general-l-sol",
        displayName: round13ScenarioNames[3],
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .l,
          tokenBudget: "L 專案：gpt-5.6-sol 主導，sonnet-5 副審；允許單領域深 loop，正式 goal 不限次，以 token、風險、沙盒與人工 gate 控制。",
          bindings: [
            gBind("general-l-sol-plan-lead", .plan, "主導", ["gpt-5.6-sol"], effort: .xhigh,
              "主導：建立主線、拆單一重點 domain loop、定義回滾與驗收邊界（使用者顯式指定 sol 主導）。", .always),
            gBind("general-l-sol-loops-supervisor", .loops, "副審", ["sonnet-5"], effort: .high,
              "獨立審查 domain loop 偏航、測試缺口與整合風險。", .always),
            gBind("general-l-sol-loops-sub", .loops, "sub", ["gpt-5.6-terra", "gpt-5.6-luna", "grok-build"], effort: .high,
              subPoolNote, .allowed),
            gBind("general-l-sol-goal-verifier", .goal, "驗收", ["gpt-5.6-sol"], effort: .xhigh,
              "主導裁決＋sonnet-5 副審＋沙盒/回滾/測試 receipts。", .always),
          ],
          agentsMarkdown: "# 通用 · L · sol主導\n主導：gpt-5.6-sol（超高，使用者顯式指定）。副審：sonnet-5（高，獨立）。sub 候選：gpt-5.6-terra、gpt-5.6-luna、grok。驗收：sol 裁決＋sonnet-5 副審。")),
      TatwoCustomScenarioConfig(
        id: "general-m-sol",
        displayName: round13ScenarioNames[4],
        baseScenario: .coding,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .m,
          tokenBudget: "M 協作：gpt-5.6-sol 主導，sonnet-5 副審；mainline＋副審 gate，正式 goal 不限次，以 token、風險與有效推進控制。",
          bindings: [
            gBind("general-m-sol-plan-lead", .plan, "主導", ["gpt-5.6-sol"], effort: .xhigh,
              "主導：釐清方向、拆主線 goal、決定 loops 是否啟動（使用者顯式指定 sol 主導）。", .always),
            gBind("general-m-sol-loops-supervisor", .loops, "副審", ["sonnet-5"], effort: .high,
              "驗收 loops 是否離題，指引 sub 對抗驗證，審批 sub 結論。", .allowed),
            gBind("general-m-sol-loops-sub", .loops, "sub", ["grok-build", "gpt-5.4", "gpt-5.6-luna", "minimax-m3"], effort: .high,
              subPoolNote, .allowed),
            gBind("general-m-sol-goal-verifier", .goal, "驗收", ["gpt-5.6-sol"], effort: .xhigh,
              "主導裁決副審結論，檢查各 loops 是否偏離目標。", .always),
          ],
          agentsMarkdown: "# 通用 · M · sol主導\n主導：gpt-5.6-sol（超高，使用者顯式指定）。副審：sonnet-5（高）。sub 候選：grok、gpt-5.4、gpt-5.6-luna、minimax-m3。驗收：sol 裁決。")),
      TatwoCustomScenarioConfig(
        id: "daily",
        displayName: round13ScenarioNames[5],
        baseScenario: .daily,
        builtin: true,
        modeConfigs: generalModeConfigs(
          declaredMode: .s,
          tokenBudget: "S 小修：gpt-5.6-terra 主線-only；正式 goal 不限次，以直接證據收斂，風險升高即升 M 加獨立副審。",
          bindings: [
            gBind("general-s-terra-plan-lead", .plan, "主導", ["gpt-5.6-terra"], effort: .xhigh,
              "主線-only：快速釐清、量測、微調與直接查證；不啟 sub/domain fan-out（使用者顯式指定 terra）。", .always),
            gBind("general-s-terra-goal-verifier", .goal, "驗收", ["gpt-5.6-terra"], effort: .xhigh,
              "直接本地證據驗收；缺證據不宣稱完成；風險升高即升級 M＋獨立副審。", .always),
          ],
          agentsMarkdown: "# 通用 · S · terra\n主線-only。主導/驗收：gpt-5.6-terra（超高，使用者顯式指定）。S 不啟 sub；風險升高請切 M。")),
      TatwoCustomScenarioConfig(
        id: "ui-ux-xl-fireworks",
        displayName: round13ScenarioNames[6],
        baseScenario: .design,
        builtin: true,
        modeConfigs: uiUXModeConfigs(declaredMode: .xl, branchLabel: "8方向煙火")),
      TatwoCustomScenarioConfig(
        id: "ui-ux-l-fireworks",
        displayName: round13ScenarioNames[7],
        baseScenario: .design,
        builtin: true,
        modeConfigs: uiUXModeConfigs(declaredMode: .l, branchLabel: "5方向煙火")),
      TatwoCustomScenarioConfig(
        id: "ui-ux-m-fireworks",
        displayName: round13ScenarioNames[8],
        baseScenario: .design,
        builtin: true,
        modeConfigs: uiUXModeConfigs(declaredMode: .m, branchLabel: "3方向煙火")),
      TatwoCustomScenarioConfig(
        id: "ui-ux-s-fireworks",
        displayName: round13ScenarioNames[9],
        baseScenario: .design,
        builtin: true,
        modeConfigs: uiUXModeConfigs(declaredMode: .s, branchLabel: "2方向輕評"))
    ]
  }

  public static var round9SeedScenarios: [TatwoCustomScenarioConfig] {
    round13SeedScenarios.filter { !$0.id.hasPrefix("ui-ux-") }
  }

  private static func uiUXModeConfigs(declaredMode: WorkModeID, branchLabel: String) -> [WorkModeID: TatwoScenarioModeConfig] {
    var configs = defaultDailyModeConfigs
    var declared = defaultModeConfig(declaredMode)
    declared.tokenBudget = "UI UX \(declaredMode.rawValue)：\(branchLabel)；掛 ui-fireworks 模板，正式 goal 不限次，以截圖、評審、工程測試與人工 gate 收斂。"
    let suffix = declaredMode.rawValue.lowercased()
    declared.bindings = [
      TatwoScenarioIdentityBinding(
        id: "ui-ux-\(suffix)-plan-lead",
        phase: .plan,
        identity: "主導",
        boundModelIDs: ["gpt-5.5", "fable-5"],
        responsibility: "gpt-5.5 主導 UI UX 收斂；fable-5 可選主導但需使用者明示，不自動消耗。",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "ui-ux-\(suffix)-high-risk-judge",
        phase: .goal,
        identity: "高風險判",
        boundModelIDs: ["opus-5"],
        responsibility: "高風險、發布、不可逆或使用者 gate 前做 fail-closed 判定。",
        dynamicActivation: .manualOnly),
      TatwoScenarioIdentityBinding(
        id: "ui-ux-\(suffix)-loops-reviewer",
        phase: .loops,
        identity: "副審",
        boundModelIDs: ["sonnet-5"],
        responsibility: "審視覺層級、互動、八維評審與 patch 缺口；advisory，不得自過。",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "ui-ux-\(suffix)-loops-sub",
        phase: .loops,
        identity: "sub",
        boundModelIDs: ["minimax-m3", "grok", "gpt-5.4", "haiku"],
        responsibility: "低風險候選、反例、文案、清單與批量整理；只交 receipts。",
        dynamicActivation: .allowed),
      TatwoScenarioIdentityBinding(
        id: "ui-ux-\(suffix)-goal-verifier",
        phase: .goal,
        identity: "驗收",
        boundModelIDs: ["gpt-5.5", "opus-5"],
        responsibility: "核對 screenshot/visual diff、build、test、review、rollback 與 cleanup receipt。",
        dynamicActivation: .always),
    ]
    declared.toolBindings = generalToolBindings + [
      TatwoScenarioToolBinding(
        id: "ui-fireworks-template-\(suffix)",
        registryID: "tatwo-ultrawork",
        phase: .loops,
        loopTemplateID: TatwoUIFireworksLoopTemplate.id,
        enabled: true,
        required: true,
        note: "UI UX 族預設掛 ui-fireworks：\(TatwoUIFireworksLoopTemplate.plainDescription)。")
    ]
    declared.receiptRules = ["contract-id", "identity-bindings", "ui-fireworks", "screenshot-or-visual-diff", "reviewer", "build-test", "cleanup-inventory"]
    declared.gateRules = ["UI/UJ 不能只靠 build 通過", "截圖/視覺 diff 缺失即 UI 尚未驗收", "fable-5 主導需使用者明示", "高風險 promotion 需 opus/human gate"]
    declared.agentsMarkdown = "# UI UX \(declaredMode.rawValue) · \(branchLabel)\nPlan 主導：gpt-5.5（fable-5 可選主導）。高風險判：opus-5。Loops 評審：sonnet-5。Loops sub：minimax-m3、grok、gpt-5.4、haiku。Loop 模板：ui-fireworks。"
    declared.bindings = canonicalGatewayBindings(declared.bindings)
    configs[declaredMode] = declared
    return configs
  }

  public static let dailyM = TatwoScenarioModeConfig(
    mode: .m,
    tokenBudget: "通用 M：不限制 goal 次數；由 token、風險、人工 gate 與有效推進控制。",
    bindings: [
      TatwoScenarioIdentityBinding(
        id: "daily-m-plan-lead",
        phase: .plan,
        identity: "主導",
        boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .lead),
        responsibility: "建立方向、拆主線 goal、決定 loops 是否需要啟動。",
        dynamicActivation: .always),
      TatwoScenarioIdentityBinding(
        id: "daily-m-loops-supervisor",
        phase: .loops,
        identity: "副審",
        boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .supervisor),
        responsibility: "驗收 loops 是否離題，指引 sub 對抗驗證，審批 sub 結論。",
        dynamicActivation: .allowed),
      TatwoScenarioIdentityBinding(
        id: "daily-m-loops-sub",
        phase: .loops,
        identity: "sub",
        boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .sub),
        responsibility: "補盲點、提供反例、查消息或低成本對抗。",
        dynamicActivation: .allowed),
      TatwoScenarioIdentityBinding(
        id: "daily-m-goal-verifier",
        phase: .goal,
        identity: "驗收",
        boundModelIDs: TatwoGatewayDispatchCatalog.models(for: .verifier),
        responsibility: "主導驗收副審結論，檢查各 loops 過程是否偏離目標。",
        dynamicActivation: .always),
    ],
    toolBindings: generalToolBindings,
    receiptRules: ["contract-id", "identity-bindings", "loop-governor-decision", "goal-review"],
    gateRules: ["超出 token 預算需人工授權", "正式 goal 不受 5 cycles 限制", "沙盒評分才限制 5 execution cycles"],
    agentsMarkdown: "# 通用 M 協作\nPlan 主導：GPT5.5、OPUS5。Loops 副審：Sonnet5、GPT5.4。Loops sub：MiniMax M3、Haiku、Grok。Goal 驗收由主導檢查副審結論與 loops 是否離題。"
  )

  public static let book = TatwoScenarioConfigBookV1(
    scenarios: round13SeedScenarios
  )
}

public struct TatwoScenarioConfigReadOnlyEvidenceV1: Sendable, Equatable {
  public let schema: String
  public let sourceKind: String
  public let scenarioConfigRawSHA256: String
  public let book: TatwoScenarioConfigBookV1

  public init(
    schema: String = "TatwoScenarioConfigReadOnlyEvidenceV1",
    sourceKind: String,
    scenarioConfigRawSHA256: String,
    book: TatwoScenarioConfigBookV1
  ) {
    self.schema = schema
    self.sourceKind = sourceKind
    self.scenarioConfigRawSHA256 = scenarioConfigRawSHA256
    self.book = book
  }

  public static func projectedOverride(
    _ book: TatwoScenarioConfigBookV1
  ) throws -> TatwoScenarioConfigReadOnlyEvidenceV1 {
    let normalized = book.normalizedForCurrentDefaults()
    return TatwoScenarioConfigReadOnlyEvidenceV1(
      sourceKind: "projected_override",
      scenarioConfigRawSHA256: sha256(try canonicalBytes(normalized)),
      book: normalized)
  }

  fileprivate static func canonicalBytes(
    _ book: TatwoScenarioConfigBookV1
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(book)
  }

  fileprivate static func sha256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }
}

public struct TatwoScenarioConfigStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func defaultFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let explicit = environmentValue("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH", environment: environment)
      ?? environmentValue("TATWO_ULTRAWORK_SCENARIO_CONFIG", environment: environment),
      !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return URL(fileURLWithPath: explicit)
    }
    return TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
      .appendingPathComponent("scenario-config.json")
  }

  public static func defaultStore(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoScenarioConfigStore {
    TatwoScenarioConfigStore(fileURL: defaultFileURL(environment: environment))
  }

  public static func loadDefaultStaging(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoScenarioConfigBookV1 {
    (try? defaultStore(environment: environment).load()) ?? TatwoScenarioConfigDefaults.book.normalizedForCurrentDefaults()
  }

  /// Strict read-only staging loader for candidate/projection routes.
  ///
  /// Existing config bytes are decoded and normalized only in memory. A config
  /// that would require the legacy in-place migration fails closed before any
  /// backup, save, temp-file, or parent-directory mutation. An absent file
  /// returns current normalized defaults without creating the file or parent.
  public static func loadDefaultStagingStrictReadOnly(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TatwoScenarioConfigBookV1 {
    try loadDefaultStagingStrictReadOnlyEvidence(environment: environment).book
  }

  public static func loadDefaultStagingStrictReadOnlyEvidence(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> TatwoScenarioConfigReadOnlyEvidenceV1 {
    try defaultStore(environment: environment).loadStrictReadOnlyEvidence()
  }

  public func loadStrictReadOnly() throws -> TatwoScenarioConfigBookV1 {
    try loadStrictReadOnlyEvidence().book
  }

  public func loadStrictReadOnlyEvidence() throws -> TatwoScenarioConfigReadOnlyEvidenceV1 {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      if Self.isMissingFileError(error) {
        let normalized = TatwoScenarioConfigDefaults.book.normalizedForCurrentDefaults()
        return TatwoScenarioConfigReadOnlyEvidenceV1(
          sourceKind: "normalized_defaults_absent",
          scenarioConfigRawSHA256:
            TatwoScenarioConfigReadOnlyEvidenceV1.sha256(
              try TatwoScenarioConfigReadOnlyEvidenceV1.canonicalBytes(normalized)),
          book: normalized)
      }
      throw TatwoScenarioConfigReadOnlyLoadError.readFailed
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded: TatwoScenarioConfigBookV1
    do {
      decoded = try decoder.decode(TatwoScenarioConfigBookV1.self, from: data)
    } catch {
      throw TatwoScenarioConfigReadOnlyLoadError.decodeFailed
    }
    let normalized = decoded.normalizedForCurrentDefaults()
    guard !Self.needsInPlaceMigration(from: decoded, to: normalized) else {
      throw TatwoScenarioConfigReadOnlyLoadError.migrationRequired
    }
    return TatwoScenarioConfigReadOnlyEvidenceV1(
      sourceKind: "persisted_exact_bytes",
      scenarioConfigRawSHA256:
        TatwoScenarioConfigReadOnlyEvidenceV1.sha256(data),
      book: normalized)
  }

  private static func isMissingFileError(_ error: Error) -> Bool {
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain,
      failure.code == NSFileReadNoSuchFileError
    {
      return true
    }
    return failure.domain == NSPOSIXErrorDomain && failure.code == 2
  }

  public func load() throws -> TatwoScenarioConfigBookV1 {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return TatwoScenarioConfigDefaults.book
    }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(TatwoScenarioConfigBookV1.self, from: data)
    let normalized = decoded.normalizedForCurrentDefaults()
    if Self.needsInPlaceMigration(from: decoded, to: normalized) {
      try writeBackupIfNeeded(originalData: data)
      try save(normalized)
    }
    return normalized
  }

  private static func needsInPlaceMigration(
    from decoded: TatwoScenarioConfigBookV1,
    to normalized: TatwoScenarioConfigBookV1
  ) -> Bool {
    guard decoded.stableHash == normalized.stableHash else { return true }
    let decodedSignature = decoded.scenarios.map { "\($0.id)|\($0.displayName)|\($0.builtin)|\($0.baseScenario?.rawValue ?? "")" }
    let normalizedSignature = normalized.scenarios.map { "\($0.id)|\($0.displayName)|\($0.builtin)|\($0.baseScenario?.rawValue ?? "")" }
    return decodedSignature != normalizedSignature
  }

  private func writeBackupIfNeeded(originalData data: Data) throws {
    let backupURL = fileURL.appendingPathExtension("bak")
    if FileManager.default.fileExists(atPath: backupURL.path) {
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "")
      try data.write(to: fileURL.appendingPathExtension("bak.\(stamp)"), options: [.atomic])
    } else {
      try data.write(to: backupURL, options: [.atomic])
    }
  }

  public func save(_ book: TatwoScenarioConfigBookV1) throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var copy = book
    copy.updatedAt = Date()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(copy).write(to: fileURL, options: [.atomic])
  }

  private static func environmentValue(
    _ key: String,
    environment: [String: String]
  ) -> String? {
    if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      return value
    }
    if let raw = getenv(key) {
      let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty {
        return value
      }
    }
    return nil
  }
}

public enum TatwoScenarioConfigReadOnlyLoadError:
  Error, LocalizedError, Sendable, Equatable
{
  case readFailed
  case decodeFailed
  case migrationRequired

  public var errorDescription: String? {
    switch self {
    case .readFailed:
      return "scenario_config_read_failed"
    case .decodeFailed:
      return "scenario_config_decode_failed"
    case .migrationRequired:
      return "scenario_config_migration_required"
    }
  }
}

public enum TatwoScenarioConfigMutationError: Error, LocalizedError, Equatable {
  case scenarioNotFound(String)
  case builtinScenarioProtected(String)
  case invalidScenarioName
  case bindingNotFound(String)
  case canvasVersionNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .scenarioNotFound(let id):
      return "scenario_not_found:\(id)"
    case .builtinScenarioProtected(let id):
      return "builtin_scenario_protected:\(id)"
    case .invalidScenarioName:
      return "invalid_scenario_name"
    case .bindingNotFound(let id):
      return "binding_not_found:\(id)"
    case .canvasVersionNotFound(let id):
      return "canvas_version_not_found:\(id)"
    }
  }
}

public struct TatwoScenarioConfigMutationResult: Codable, Sendable, Equatable {
  public let schema: String
  public let ok: Bool
  public let stage: String
  public let scenarioID: String
  public let message: String
  public let book: TatwoScenarioConfigBookV1

  public init(
    schema: String = "TatwoScenarioConfigMutationResultV1",
    ok: Bool,
    stage: String = "staging",
    scenarioID: String,
    message: String,
    book: TatwoScenarioConfigBookV1
  ) {
    self.schema = schema
    self.ok = ok
    self.stage = stage
    self.scenarioID = scenarioID
    self.message = message
    self.book = book
  }
}

public enum TatwoScenarioConfigMutator {
  public static func unlockScenarioForStaging(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String
  ) throws -> TatwoScenarioConfigMutationResult {
    guard var source = book.scenario(id: scenarioID) else {
      throw TatwoScenarioConfigMutationError.scenarioNotFound(scenarioID)
    }
    if !source.builtin {
      return TatwoScenarioConfigMutationResult(
        ok: true,
        scenarioID: scenarioID,
        message: "此情境已是 staging 沙盒，可直接編輯；實裝版不會被覆寫。",
        book: book)
    }
    var next = book
    source.id = "staging-\(slug(source.id))-\(Int(Date().timeIntervalSince1970))"
    source.displayName = "\(source.displayName) staging"
    source.builtin = false
    source.updatedAt = Date()
    next.scenarios.append(source)
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: source.id,
      message: "已解鎖為 staging 沙盒畫布；原實裝架構保持鎖定未修改。",
      book: next)
  }

  public static func addCustomScenario(
    to book: TatwoScenarioConfigBookV1,
    displayName rawDisplayName: String,
    baseScenario: ScenarioID? = .coding
  ) throws -> TatwoScenarioConfigMutationResult {
    let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else { throw TatwoScenarioConfigMutationError.invalidScenarioName }
    var next = book
    let id = "custom-\(slug(displayName))-\(Int(Date().timeIntervalSince1970))"
    next.scenarios.append(
      TatwoCustomScenarioConfig(
        id: id,
        displayName: displayName,
        baseScenario: baseScenario,
        builtin: false,
        modeConfigs: TatwoScenarioConfigDefaults.defaultDailyModeConfigs,
        updatedAt: Date()))
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: id,
      message: "已新增 staging 自定義情境；尚未升 active。",
      book: next)
  }

  public static func duplicateScenario(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String
  ) throws -> TatwoScenarioConfigMutationResult {
    guard var source = book.scenario(id: scenarioID) else {
      throw TatwoScenarioConfigMutationError.scenarioNotFound(scenarioID)
    }
    var next = book
    source.id = "custom-copy-\(slug(source.id))-\(Int(Date().timeIntervalSince1970))"
    source.displayName = "\(source.displayName) 副本"
    source.builtin = false
    source.updatedAt = Date()
    next.scenarios.append(source)
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: source.id,
      message: "已複製為可編輯 staging 情境；原內建情境未被修改。",
      book: next)
  }

  public static func saveCanvasVersion(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String,
    mode: WorkModeID,
    name rawName: String? = nil,
    now: Date = Date()
  ) throws -> TatwoScenarioConfigMutationResult {
    var next = try editableBook(book, scenarioID: scenarioID)
    let index = try scenarioIndex(next, scenarioID: scenarioID)
    var modeConfig = next.scenarios[index].modeConfigs[mode]
      ?? TatwoScenarioConfigDefaults.defaultModeConfig(mode)
    let snapshot = modeConfig.canvasSnapshot
    let hash = snapshot.canvasSnapshotHash
    let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? rawName!.trimmingCharacters(in: .whitespacesAndNewlines)
      : "畫布 \(mode.rawValue) \(String(hash.prefix(6)))"
    let version = TatwoScenarioCanvasVersion(
      id: "canvas-version-\(Int(now.timeIntervalSince1970))-\(String(hash.prefix(8)))",
      name: name,
      createdAt: now,
      hash: hash,
      modeConfig: snapshot)
    modeConfig.canvasVersions.insert(version, at: 0)
    modeConfig.canvasVersions = Array(modeConfig.canvasVersions.prefix(24))
    next.scenarios[index].modeConfigs[mode] = modeConfig
    next.scenarios[index].updatedAt = now
    next.updatedAt = now
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: scenarioID,
      message: "已保存 staging 畫布版本 \(String(hash.prefix(7)))。",
      book: next)
  }

  public static func revertCanvasVersion(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String,
    mode: WorkModeID,
    versionID: String
  ) throws -> TatwoScenarioConfigMutationResult {
    var next = try editableBook(book, scenarioID: scenarioID)
    let index = try scenarioIndex(next, scenarioID: scenarioID)
    let current = next.scenarios[index].modeConfigs[mode]
      ?? TatwoScenarioConfigDefaults.defaultModeConfig(mode)
    guard let version = current.canvasVersions.first(where: { $0.id == versionID }) else {
      throw TatwoScenarioConfigMutationError.canvasVersionNotFound(versionID)
    }
    var restored = version.modeConfig.canvasSnapshot
    restored.canvasVersions = current.canvasVersions
    next.scenarios[index].modeConfigs[mode] = restored
    next.scenarios[index].updatedAt = Date()
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: scenarioID,
      message: "已回復到畫布版本 \(String(version.hash.prefix(7)))；仍停留在 staging，可再編輯。",
      book: next)
  }

  public static func renameScenario(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String,
    displayName rawDisplayName: String
  ) throws -> TatwoScenarioConfigMutationResult {
    let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else { throw TatwoScenarioConfigMutationError.invalidScenarioName }
    var next = try editableBook(book, scenarioID: scenarioID)
    let index = try scenarioIndex(next, scenarioID: scenarioID)
    next.scenarios[index].displayName = displayName
    next.scenarios[index].updatedAt = Date()
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: scenarioID,
      message: "已改名 staging 情境。",
      book: next)
  }

  public static func deleteScenario(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String
  ) throws -> TatwoScenarioConfigMutationResult {
    var next = try editableBook(book, scenarioID: scenarioID)
    next.scenarios.removeAll { $0.id == scenarioID }
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: next.scenarios.first?.id ?? "daily",
      message: "已刪除 staging 自定義情境；內建情境不可刪。",
      book: next)
  }

  public static func updateTokenBudget(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String,
    mode: WorkModeID,
    tokenBudget: String
  ) throws -> TatwoScenarioConfigMutationResult {
    var next = try editableBook(book, scenarioID: scenarioID)
    let index = try scenarioIndex(next, scenarioID: scenarioID)
    var modeConfig = next.scenarios[index].modeConfigs[mode]
      ?? TatwoScenarioConfigDefaults.defaultModeConfig(mode)
    modeConfig.tokenBudget = tokenBudget
    next.scenarios[index].modeConfigs[mode] = modeConfig
    next.scenarios[index].updatedAt = Date()
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: scenarioID,
      message: "已更新 \(mode.rawValue) token/gate staging 設定。",
      book: next)
  }

  public static func setBindingModels(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String,
    mode: WorkModeID,
    bindingID: String,
    modelIDs: [String]
  ) throws -> TatwoScenarioConfigMutationResult {
    try updateBinding(in: book, scenarioID: scenarioID, mode: mode, bindingID: bindingID) { binding in
      binding.boundModelIDs = Array(NSOrderedSet(array: modelIDs)) as? [String] ?? modelIDs
    }
  }

  public static func updateBindingResponsibility(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String,
    mode: WorkModeID,
    bindingID: String,
    responsibility: String
  ) throws -> TatwoScenarioConfigMutationResult {
    try updateBinding(in: book, scenarioID: scenarioID, mode: mode, bindingID: bindingID) { binding in
      binding.responsibility = responsibility
    }
  }

  private static func updateBinding(
    in book: TatwoScenarioConfigBookV1,
    scenarioID: String,
    mode: WorkModeID,
    bindingID: String,
    mutate: (inout TatwoScenarioIdentityBinding) -> Void
  ) throws -> TatwoScenarioConfigMutationResult {
    var next = try editableBook(book, scenarioID: scenarioID)
    let index = try scenarioIndex(next, scenarioID: scenarioID)
    var modeConfig = next.scenarios[index].modeConfigs[mode]
      ?? TatwoScenarioConfigDefaults.defaultModeConfig(mode)
    guard let bindingIndex = modeConfig.bindings.firstIndex(where: { $0.id == bindingID }) else {
      throw TatwoScenarioConfigMutationError.bindingNotFound(bindingID)
    }
    mutate(&modeConfig.bindings[bindingIndex])
    next.scenarios[index].modeConfigs[mode] = modeConfig
    next.scenarios[index].updatedAt = Date()
    next.updatedAt = Date()
    return TatwoScenarioConfigMutationResult(
      ok: true,
      scenarioID: scenarioID,
      message: "已更新身份組 staging 設定。",
      book: next)
  }

  private static func editableBook(
    _ book: TatwoScenarioConfigBookV1,
    scenarioID: String
  ) throws -> TatwoScenarioConfigBookV1 {
    guard let scenario = book.scenario(id: scenarioID) else {
      throw TatwoScenarioConfigMutationError.scenarioNotFound(scenarioID)
    }
    guard !scenario.builtin else {
      throw TatwoScenarioConfigMutationError.builtinScenarioProtected(scenarioID)
    }
    return book
  }

  private static func scenarioIndex(
    _ book: TatwoScenarioConfigBookV1,
    scenarioID: String
  ) throws -> Int {
    guard let index = book.scenarios.firstIndex(where: { $0.id == scenarioID }) else {
      throw TatwoScenarioConfigMutationError.scenarioNotFound(scenarioID)
    }
    return index
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
    return trimmed.isEmpty ? "scenario" : String(trimmed.prefix(48))
  }
}

public struct TatwoLoopGovernorDecisionV1: Codable, Sendable, Equatable {
  public let schema: String
  public let configHash: String
  public let mode: WorkModeID
  public let scenarioID: String
  public let tokenBudget: String
  public let activatedBindings: [TatwoScenarioIdentityBinding]
  public let decisionReasons: [String]
  public let humanGateRules: [String]
  public let formalGoalCycleRule: String
  public let sandboxCycleRule: String

  public init(
    schema: String = "TatwoLoopGovernorDecisionV1",
    configHash: String,
    mode: WorkModeID,
    scenarioID: String,
    tokenBudget: String,
    activatedBindings: [TatwoScenarioIdentityBinding],
    decisionReasons: [String],
    humanGateRules: [String],
    formalGoalCycleRule: String = "正式工作 goal 不限制次數；以 token、風險、人工 gate 與有效推進控制。",
    sandboxCycleRule: String = "沙盒評分才限制最多 5 次 execution cycles；封存後不可修改。"
  ) {
    self.schema = schema
    self.configHash = configHash
    self.mode = mode
    self.scenarioID = scenarioID
    self.tokenBudget = tokenBudget
    self.activatedBindings = activatedBindings
    self.decisionReasons = decisionReasons
    self.humanGateRules = humanGateRules
    self.formalGoalCycleRule = formalGoalCycleRule
    self.sandboxCycleRule = sandboxCycleRule
  }
}

public enum TatwoLoopGovernor {
  public static func decide(
    mode: WorkModeID,
    scenarioID: String,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
  ) -> TatwoLoopGovernorDecisionV1 {
    let config = scenarioBook.modeConfig(scenarioID: scenarioID, mode: mode)
    let fallback = scenarioID == "daily" && mode == .m ? TatwoScenarioConfigDefaults.dailyM : nil
    let modeConfig = config ?? fallback
    let bindings = modeConfig?.bindings.filter { $0.enabled && $0.dynamicActivation != .disabled } ?? []
    return TatwoLoopGovernorDecisionV1(
      configHash: scenarioBook.stableHash,
      mode: mode,
      scenarioID: scenarioID,
      tokenBudget: modeConfig?.tokenBudget ?? "未設定；採 WorkOS 內建 token / 風險 gate。",
      activatedBindings: bindings,
      decisionReasons: [
        modeConfig == nil ? "未找到自定義設定，採內建 fallback。" : "使用 Dashboard Scenario Config。",
        "主導只能提出擴編建議；Loop Governor 依 OS 規則批准。",
        "S/M/L/XL 是協作強度預設，不是 goal 次數上限。",
      ],
      humanGateRules: modeConfig?.gateRules ?? ["主機實裝", "部署", "高風險工具"]
    )
  }
}
