import Foundation

/// Decision from the universal enforcement chokepoint.
public struct TatwoWorkOSChokepointDecision: Codable, Sendable, Equatable {
  public let ok: Bool
  /// `authorized`, `dev_bypass`, `missing_contract`, or `unregistered_contract`.
  public let code: String
  public let message: String
  /// True only when TATWO_ULTRAWORK_DEV_BYPASS let the action through without a
  /// registered contract. Receipts should surface this so a bypassed run can
  /// never be mistaken for a governed one.
  public let bypassed: Bool
}

/// The single toll booth every non-trivial write/dispatch action passes through.
///
/// Before this existed each mutation surface carried its own hand-placed
/// `requireIssuedContract` check — correct today, but a new surface added
/// tomorrow is ungoverned unless someone remembers the guard. Routing every
/// gate through `authorize` makes governance structural: a new dispatch-shaped
/// tool calls this one function and inherits contract authentication and the
/// dev bypass for free.
///
/// Dev bypass: setting `TATWO_ULTRAWORK_DEV_BYPASS=1` (or `true`) may authorize
/// a non-sensitive action WITHOUT a registered contract, for quick manual
/// testing only. Host authorization and host-mutation-capable actions remain
/// governed even when the flag is enabled. The flag is default-off, must be
/// set per-process by the human, and every bypass decision is journaled and
/// marked `bypassed=true` / code `dev_bypass`.
public enum TatwoWorkOSChokepoint {
  public static func authorize(
    contractID: String?,
    action: String,
    store: TatwoGoalRunStore = .default(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoWorkOSChokepointDecision {
    let devBypassEnabled = isDevBypassEnabled(environment: environment)
    if devBypassEnabled && !requiresGovernedContractDespiteDevBypass(action: action) {
      TatwoConfigAuditLog(directoryURL: store.directoryURL).append(
        actor: "work-os-chokepoint",
        action: "dev_bypass_applied",
        detail: "action=\(action)",
        configHash: "not_applicable")
      return TatwoWorkOSChokepointDecision(
        ok: true,
        code: "dev_bypass",
        message: "TATWO_ULTRAWORK_DEV_BYPASS 放行 \(action)（未經合約治理，僅供開發測試）",
        bypassed: true)
    }
    if devBypassEnabled {
      TatwoConfigAuditLog(directoryURL: store.directoryURL).append(
        actor: "work-os-chokepoint",
        action: "dev_bypass_denied_sensitive_action",
        detail: "action=\(action)",
        configHash: "not_applicable")
    }
    let normalized = (contractID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return TatwoWorkOSChokepointDecision(
        ok: false,
        code: "missing_contract",
        message: "\(action) 缺 contractID；先呼叫 tatwo.os.begin。",
        bypassed: false)
    }
    do {
      let goal = try store.requireIssuedContract(normalized)
      if goal.status == .superseded || goal.successorContractID != nil {
        return TatwoWorkOSChokepointDecision(
          ok: false,
          code: "stale_goal_revision",
          message: "\(action) 指向已被取代的 Goal revision；fail closed。",
          bypassed: false)
      }
    } catch {
      return TatwoWorkOSChokepointDecision(
        ok: false,
        code: "unregistered_contract",
        message: "\(action) 的 contractID 未由 tatwo.os.begin 登記；fail closed。\(error.localizedDescription)",
        bypassed: false)
    }
    return TatwoWorkOSChokepointDecision(
      ok: true, code: "authorized", message: "\(action) 經收費站授權。", bypassed: false)
  }

  static func isDevBypassEnabled(environment: [String: String]) -> Bool {
    guard let raw = environment["TATWO_ULTRAWORK_DEV_BYPASS"]?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    else { return false }
    return raw == "1" || raw == "true" || raw == "yes"
  }

  static func requiresGovernedContractDespiteDevBypass(action: String) -> Bool {
    if action.hasPrefix("tatwo.host.") {
      // Fail closed for authorization and present/future host mutation actions.
      // Only the known read-only host surfaces keep the development bypass.
      return ![
        "tatwo.host.plan",
        "tatwo.host.read_file",
      ].contains(action)
    }
    if action.hasPrefix("tatwo.computer.") {
      // Computer execution mutates host UI state. Status/screenshot are the
      // only known observation-only surfaces.
      return ![
        "tatwo.computer.status",
        "tatwo.computer.screenshot",
      ].contains(action)
    }
    return false
  }
}
