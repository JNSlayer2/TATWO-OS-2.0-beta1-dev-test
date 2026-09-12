import Foundation

public enum TatwoOSModeRouteStatus: String, Codable, Sendable, CaseIterable {
  case dashboardReady = "dashboard_ready"
  case gatewayDryRun = "gateway_dry_run"
  case hostInstallBlocked = "host_install_blocked"
}

public struct TatwoOSModeRouteV1: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let displayName: String
  public let route: String
  public let mode: WorkModeID
  public let provider: String
  public let speedDefault: String
  public let reasoningPolicy: String
  public let status: TatwoOSModeRouteStatus
  public let plainPurpose: String
  public let modelDropdownPolicy: String
  public let safetyNotes: [String]

  public init(
    id: String,
    displayName: String,
    route: String,
    mode: WorkModeID,
    provider: String = "model_gateway",
    speedDefault: String = "fast",
    reasoningPolicy: String = "follow Codex App / CLI",
    status: TatwoOSModeRouteStatus,
    plainPurpose: String,
    modelDropdownPolicy: String,
    safetyNotes: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.route = route
    self.mode = mode
    self.provider = provider
    self.speedDefault = speedDefault
    self.reasoningPolicy = reasoningPolicy
    self.status = status
    self.plainPurpose = TatwoPrivacyRedactor.redacted(plainPurpose)
    self.modelDropdownPolicy = TatwoPrivacyRedactor.redacted(modelDropdownPolicy)
    self.safetyNotes = safetyNotes.map(TatwoPrivacyRedactor.redacted)
  }
}

public struct TatwoOSModeRouteInstallPlanV1: Codable, Sendable, Equatable {
  public let schema: String
  public let routes: [TatwoOSModeRouteV1]
  public let existingModelsPolicy: String
  public let signedCodexAppBundleMutationAllowed: Bool
  public let launchAgentMutationAllowed: Bool
  public let requiresPreflightBeforeHostInstall: Bool
  public let smokeRequiredBeforeActive: [String]
  public let rollbackNotes: [String]

  public init(
    schema: String = "TatwoOSModeRouteInstallPlanV1",
    routes: [TatwoOSModeRouteV1],
    existingModelsPolicy: String,
    signedCodexAppBundleMutationAllowed: Bool,
    launchAgentMutationAllowed: Bool,
    requiresPreflightBeforeHostInstall: Bool,
    smokeRequiredBeforeActive: [String],
    rollbackNotes: [String]
  ) {
    self.schema = schema
    self.routes = routes
    self.existingModelsPolicy = existingModelsPolicy
    self.signedCodexAppBundleMutationAllowed = signedCodexAppBundleMutationAllowed
    self.launchAgentMutationAllowed = launchAgentMutationAllowed
    self.requiresPreflightBeforeHostInstall = requiresPreflightBeforeHostInstall
    self.smokeRequiredBeforeActive = smokeRequiredBeforeActive
    self.rollbackNotes = rollbackNotes
  }
}

public enum TatwoOSModeRouteCatalog {
  public static let all: [TatwoOSModeRouteV1] = [
    route(.s, purpose: "小修 / 查找 / 微調：主線直跑，不開分流。"),
    route(.m, purpose: "通用協作：Plan 主導、Loops 副審與 sub、Goal 收口。"),
    route(.l, purpose: "專案級工作：單領域深 loop、沙盒 / rollback 收據。"),
    route(.xl, purpose: "重型工程：主線監督、多領域 loops、沙盒與人工 gate。"),
  ]

  public static var installPlan: TatwoOSModeRouteInstallPlanV1 {
    TatwoOSModeRouteInstallPlanV1(
      routes: all,
      existingModelsPolicy: "只新增 TATWO ULTRAWORK S/M/L/XL；不移除 GPT、Claude、Grok、MiniMax 或任何既有模型。",
      signedCodexAppBundleMutationAllowed: false,
      launchAgentMutationAllowed: false,
      requiresPreflightBeforeHostInstall: true,
      smokeRequiredBeforeActive: [
        "tatwo-ultrawork routes list --json",
        "tatwo-ultrawork os begin --mode XL --scenario ui-ux --json",
        "gateway same-thread smoke: gpt-5.5 -> tatwo-os-<mode> -> gpt-5.5",
        "doctor --json after route registration",
      ],
      rollbackNotes: [
        "路由先作 dry-run / dashboard-ready，不直接改 signed Codex App。",
        "正式寫入 gateway 前先備份 gateway config/state。",
        "任何 route smoke 不通時標為 degraded，不刪除既有模型。",
      ])
  }

  public static func route(for mode: WorkModeID) -> TatwoOSModeRouteV1 {
    all.first { $0.mode == mode } ?? route(mode, purpose: "TATWO Ultrawork OS mode route.")
  }

  private static func route(_ mode: WorkModeID, purpose: String) -> TatwoOSModeRouteV1 {
    let lower = mode.rawValue.lowercased()
    return TatwoOSModeRouteV1(
      id: "tatwo-os-\(lower)",
      displayName: "TATWO ULTRAWORK \(mode.rawValue)",
      route: "tatwo-os-\(lower)",
      mode: mode,
      status: .dashboardReady,
      plainPurpose: purpose,
      modelDropdownPolicy: "Codex App dropdown 保留所有原模型，額外新增此 OS mode route；實際模型由 Dashboard 身份組與情境設定決定。",
      safetyNotes: [
        "route 不是單一模型；它先進 Work OS contract，再由身份組調度模型。",
        "速度預設 fast；reasoning 跟隨 Codex App / CLI。",
        "沒有 contractID 或收據不足時 fail closed。",
      ])
  }
}
