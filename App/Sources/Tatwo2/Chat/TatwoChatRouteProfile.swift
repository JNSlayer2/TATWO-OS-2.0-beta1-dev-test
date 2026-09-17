// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoChatRouteProfile.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import CryptoKit
import Darwin
import Foundation

public struct TatwoChatRouteProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
  public let id: String
  public let displayName: String
  public let family: String
  public let engine: TatwoNativeChatEngine
  public let runtimeAdapter: TatwoChatRuntimeAdapter
  public let canonicalModelSlug: String
  public let modelArgument: String?
  public let contextWindowLabel: String
  public let supportsImageInput: Bool
  public let pluginFit: String
  public let sessionRisk: String
  public let defaultEffort: TatwoCodexReasoningEffort
  public let allowedEfforts: [TatwoCodexReasoningEffort]
  public let defaultSpeedTier: TatwoModelSpeedTier?
  public let allowedSpeedTiers: [TatwoModelSpeedTier]
  public let notes: [String]

  public init(
    id: String,
    displayName: String,
    family: String,
    engine: TatwoNativeChatEngine,
    runtimeAdapter: TatwoChatRuntimeAdapter? = nil,
    canonicalModelSlug: String? = nil,
    modelArgument: String?,
    contextWindowLabel: String,
    supportsImageInput: Bool,
    pluginFit: String,
    sessionRisk: String,
    defaultEffort: TatwoCodexReasoningEffort,
    allowedEfforts: [TatwoCodexReasoningEffort],
    defaultSpeedTier: TatwoModelSpeedTier? = nil,
    allowedSpeedTiers: [TatwoModelSpeedTier] = [],
    notes: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.family = family
    self.engine = engine
    self.runtimeAdapter = runtimeAdapter ?? (engine == .claude ? .claudeCLI : .codexExec)
    self.canonicalModelSlug = canonicalModelSlug ?? modelArgument ?? id
    self.modelArgument = modelArgument
    self.contextWindowLabel = contextWindowLabel
    self.supportsImageInput = supportsImageInput
    self.pluginFit = TatwoPrivacyRedactor.redacted(pluginFit)
    self.sessionRisk = TatwoPrivacyRedactor.redacted(sessionRisk)
    self.defaultEffort = defaultEffort
    self.allowedEfforts = allowedEfforts
    self.defaultSpeedTier = defaultSpeedTier
    self.allowedSpeedTiers = allowedSpeedTiers
    self.notes = notes.map { TatwoPrivacyRedactor.redacted($0) }
  }

  public var menuSubtitle: String {
    let image = supportsImageInput ? "image ok" : "text-first"
    return "\(family) · \(contextWindowLabel) · \(image) · \(pluginFit)"
  }

  public var supportsNativeReasoningControl: Bool {
    !allowedEfforts.isEmpty
  }

  public var supportsNativeSpeedControl: Bool {
    !allowedSpeedTiers.isEmpty
  }

  public func acceptsAttachmentPath(_ path: String) -> Bool {
    acceptsAttachmentPath(
      path,
      interactionMode: .standard,
      requiresTatwoComputerHost: false)
  }

  public func acceptsAttachmentPath(
    _ path: String,
    interactionMode: TatwoChatInteractionMode,
    requiresTatwoComputerHost: Bool
  ) -> Bool {
    !TatwoChatCommandPlanner.isLikelyImagePath(path)
      || imageTransportCapability(
        interactionMode: interactionMode,
        requiresTatwoComputerHost: requiresTatwoComputerHost) != .none
  }

  public func imageTransportCapability(
    interactionMode: TatwoChatInteractionMode = .standard,
    requiresTatwoComputerHost: Bool = false
  ) -> TatwoImageTransportCapability {
    guard supportsImageInput else { return .none }
    switch runtimeAdapter {
    case .nativeAgent:
      return .none
    case .codexExec:
      return .codexExecImage
    case .claudeCLI:
      return .claudeReadRescue
    case .grokCLI:
      return .grokPromptJSONImage
    case .minimaxDirect:
      return .none
    case .gatewayDirect:
      return engine == .claude ? .claudeReadRescue : .none
    case .unavailable:
      return .none
    }
  }

  public func nativeReasoningEffort(for requested: TatwoCodexReasoningEffort) -> TatwoCodexReasoningEffort? {
    guard supportsNativeReasoningControl else { return nil }
    if allowedEfforts.contains(requested) { return requested }
    if allowedEfforts.contains(defaultEffort) { return defaultEffort }
    return allowedEfforts.first
  }

  public func nativeSpeedTier(for requested: TatwoModelSpeedTier?) -> TatwoModelSpeedTier? {
    guard supportsNativeSpeedControl else { return nil }
    if let requested, allowedSpeedTiers.contains(requested) { return requested }
    if let defaultSpeedTier, allowedSpeedTiers.contains(defaultSpeedTier) { return defaultSpeedTier }
    return allowedSpeedTiers.first
  }

  public static let defaults: [TatwoChatRouteProfile] = [
    .init(
      id: "gpt-5.6-sol",
      displayName: "GPT-5.6 Sol",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.6-sol",
      contextWindowLabel: "400k",
      supportsImageInput: true,
      pluginFit: "現代主力 host / tools",
      sessionRisk: "中：新 route 需 smoke",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["GPT-5.6 現代主力；本機 gateway catalog 與 Codex session 已查證", "live catalog 宣告 text + image"]),
    .init(
      id: "gpt-5.6-terra",
      displayName: "GPT-5.6 Terra",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.6-terra",
      contextWindowLabel: "400k",
      supportsImageInput: true,
      pluginFit: "審查 / 驗證",
      sessionRisk: "中：需 active Codex session",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["OS 以 Codex exec 經單一 model_gateway 調度；保留 active Codex Authorization", "live catalog 宣告 text + image"]),
    .init(
      id: "gpt-5.6-luna",
      displayName: "GPT-5.6 Luna",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.6-luna",
      contextWindowLabel: "400k",
      supportsImageInput: true,
      pluginFit: "一般 Chat / 替代路線",
      sessionRisk: "中：需 active Codex session",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["OS 以 Codex exec 經單一 model_gateway 調度；保留 active Codex Authorization", "live catalog 宣告 text + image"]),
    .init(   // 2026-09-05 GPT-6 發布；打包的 codex 0.153.2 的 model/list 已列 gpt-6-astra
      id: "gpt-6-astra",
      displayName: "GPT-6",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-6-astra",
      contextWindowLabel: "長 context",
      supportsImageInput: true,
      pluginFit: "最佳 host / tools",
      sessionRisk: "低",
      defaultEffort: .medium,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["GPT-6（codex 模型名 gpt-6-astra）"]),
    .init(
      id: "gpt-5.5",
      displayName: "GPT-5.5",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.5",
      contextWindowLabel: "長 context",
      supportsImageInput: true,
      pluginFit: "最佳 host / tools",
      sessionRisk: "低",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["預設 Plan Lead / Host Executor", "高風險時才升高推理"]),
    .init(
      id: "minimax-m3",
      displayName: "MiniMax M3",
      family: "MiniMax API",
      engine: .codex,
      runtimeAdapter: .minimaxDirect,
      modelArgument: "minimax-m3",
      contextWindowLabel: "長輸出",
      supportsImageInput: false,
      pluginFit: "bulk sub",
      sessionRisk: "低",
      defaultEffort: .low,
      allowedEfforts: [],
      notes: ["適合批量整理與候選清單；不作最終 gate", "App 內建 MiniMax SSE 直連僅送文字；圖片需改用支援 image transport 的 Codex route"]),
    .init(
      id: "grok-build",
      displayName: "Grok 4.6",
      family: "Grok native",
      engine: .codex,
      runtimeAdapter: .grokCLI,
      modelArgument: "grok-4.6",   // grok 0.2.11 的真模型 id（`grok models`）；"grok-build" 是 route id 不是模型，傳給 --model 會 unknown model id
      contextWindowLabel: "news/refute",
      supportsImageInput: true,
      pluginFit: "反例/外部查證",
      sessionRisk: "中",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["外部消息與反方路線；需要回 Codex 驗證", "App 內建 Grok CLI adapter 以 --prompt-json 原生轉送圖片 content blocks 與 reasoning effort；provider 未回 effective attestation 時不得宣稱已實際生效"]),
    .init(
      id: "fable5",
      displayName: "fable5",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "fable-5",
      // 2026-08-23 修「fable5 不能用」：CLI 只認 vendor 全名 claude-fable-5，
      // 原本塞內部 slug "fable-5" → unrecognized_model（loops 路徑的
      // TatwoAgentEngineBinding 一直是對的，chat 路徑漏掉）。
      modelArgument: "claude-fable-5",
      contextWindowLabel: "200k",
      supportsImageInput: true,
      pluginFit: "規劃/語意 lead",
      sessionRisk: "低：App 內建 Claude CLI；OS 持有 thread context",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["Chat 走 App 內建 Claude CLI，逐回合固定 fable-5 且禁止 Fable→Opus fallback", "Claude CLI adapter 原生轉送 effort；只證明 forwarded，不把缺少 provider effective attestation 說成已生效"]),
    .init(
      id: "fable5.1",
      displayName: "fable5.1",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "fable-5.1",
      // 憲法 v4 §4：主導預設 Fable 5.1。CLI 需 vendor 全名。
      modelArgument: "claude-fable-5-1",
      contextWindowLabel: "200k",
      supportsImageInput: true,
      pluginFit: "規劃/語意 lead",
      sessionRisk: "低：App 內建 Claude CLI；OS 持有 thread context",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["憲法 §4 主導預設", "Claude CLI adapter 原生轉送 effort；只證明 forwarded，不把缺少 provider effective attestation 說成已生效"]),
    .init(
      id: "haiku4.5",
      displayName: "haiku4.5",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "haiku-4-5",
      modelArgument: "haiku-4-5",
      contextWindowLabel: "快速",
      supportsImageInput: true,
      pluginFit: "quick sub",
      sessionRisk: "低：App 內建 Claude CLI；OS 持有 thread context",
      defaultEffort: .low,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["低成本快速掃描", "Claude CLI adapter 原生轉送 effort；圖片 turn 使用 OS 管理的 Claude CLI Read 救援"]),
    .init(
      id: "sonnet5",
      displayName: "sonnet5",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "sonnet-5",
      modelArgument: "sonnet-5",
      contextWindowLabel: "review",
      supportsImageInput: true,
      pluginFit: "Loops Supervisor",
      sessionRisk: "中：App 內建 Claude CLI；OS 持有 thread context",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["N9 預設 Loops 副審", "active route 是 sonnet-5；Claude CLI adapter 原生轉送 effort，圖片 turn 使用 OS 管理的 Claude CLI Read 救援"]),
    .init(
      id: "opus5",
      displayName: "Claude Opus 5",
      family: "Claude native",
      engine: .claude,
      runtimeAdapter: .claudeCLI,
      canonicalModelSlug: "opus-5",
      modelArgument: "opus",
      contextWindowLabel: "judge",
      supportsImageInput: true,
      pluginFit: "Goal Judge",
      sessionRisk: "高：App 內建 Claude CLI；成本/長 context 需 gate",
      defaultEffort: .xhigh,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      notes: ["高風險裁決", "Claude CLI adapter 原生轉送 effort；provider 未回 effective attestation 時不得宣稱已實際生效，成本/上下文仍需人類 gate"]),
    .init(
      id: "codex-auto-review",
      displayName: "Codex Auto Review",
      family: "Codex",
      engine: .codex,
      modelArgument: "gpt-5.5",
      contextWindowLabel: "review",
      supportsImageInput: true,
      pluginFit: "diff review",
      sessionRisk: "低",
      defaultEffort: .medium,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["review lane，不是獨立模型權威"]),
    .init(
      id: "gpt-5.4",
      displayName: "GPT-5.4",
      family: "Codex/GPT",
      engine: .codex,
      modelArgument: "gpt-5.4",
      contextWindowLabel: "fallback",
      supportsImageInput: true,
      pluginFit: "host fallback",
      sessionRisk: "低",
      defaultEffort: .high,
      allowedEfforts: [.low, .medium, .high, .xhigh],
      defaultSpeedTier: .fast,
      allowedSpeedTiers: [.fast, .standard],
      notes: ["GPT-5.5 不穩時的 host fallback"]),
  ]

  private static func normalizedLookupKey(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  public static func resolve(_ id: String) -> TatwoChatRouteProfile {
    let needle = normalizedLookupKey(id)
    let compatibilityAliases: [String: String] = [
      "fable": "fable5",
      "haiku": "haiku45",
      "haiku45": "haiku45",
      "claudehaiku45": "haiku45",
      "sonnet": "sonnet5",
      "sonnet46": "sonnet5",
      "claudesonnet46": "sonnet5",
      "claudesonnet5": "sonnet5",
      "opus": "opus5",
    ]
    let resolvedNeedle = compatibilityAliases[needle] ?? needle
    if let profile = defaults.first(where: { profile in
      [profile.id, profile.canonicalModelSlug, profile.modelArgument, profile.displayName, profile.family]
        .compactMap { $0 }
        .contains { normalizedLookupKey($0) == resolvedNeedle }
    }) {
      return profile
    }

    let requestedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
    let unavailableID = requestedID.isEmpty ? "unavailable" : requestedID
    return TatwoChatRouteProfile(
      id: unavailableID,
      displayName: requestedID.isEmpty ? "Unavailable route" : requestedID,
      family: "Unavailable",
      engine: .codex,
      runtimeAdapter: .unavailable,
      canonicalModelSlug: unavailableID,
      modelArgument: nil,
      contextWindowLabel: "not installed",
      supportsImageInput: false,
      pluginFit: "不可執行",
      sessionRisk: "blocked",
      defaultEffort: .low,
      allowedEfforts: [],
      notes: ["未知或已退役 route；fail closed，不自動改送其他模型"])
  }
}
