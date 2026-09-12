import Foundation

/// Last-mile, fail-closed authority gate evaluated immediately before a host
/// mutation-capable runner process is spawned for one Chat turn.
///
/// 2026-08-27 live regression (staging61, run `339CAEFE…`): the Work OS goal
/// bound to the turn reached `cancelled`/`superseded_before_dispatch` at the
/// exact second the contract was issued, yet a `codex-exec` runner still
/// started and created three files on the host. Every existing goal-authority
/// check lived behind `runtimeAdapter == .nativeAgent`, so the provider-CLI
/// transports — the ones that actually ran `/bin/zsh -lc mkdir …` — were never
/// gated at all.
///
/// The turn's frozen dispatch snapshot is an *optimistic* decision taken at
/// submit time. Authority can change between submit and spawn. This gate
/// re-reads the goal record at the spawn boundary so a stale optimistic
/// decision can never mutate the host after authority changed.
public enum TatwoGoalDispatchAuthorityGate {
  public enum Denial: String, Sendable, Equatable {
    /// The goal reached a state/reason that withdraws mutation authority.
    case goalTerminalBeforeDispatch = "goal_terminal_before_dispatch"
    /// The frozen contract could not be re-verified from the goal store.
    case goalRecordUnverifiable = "goal_record_unverifiable"
    /// The durable row that owns the executing turn no longer binds a contract.
    case durableContractBindingMissing = "durable_contract_binding_missing"
    /// A different contract now owns the session that this turn froze.
    case contractAuthorityDrifted = "contract_authority_drifted"
  }

  /// Transports that can create, modify, or delete host state.
  ///
  /// `gatewayDirect`/`minimaxDirect` are brain-only text transports and
  /// `unavailable` never spawns, so an ordinary chat reply on a thread whose
  /// goal ended is untouched by this gate.
  public static func isHostMutationCapable(
    runtimeAdapter: TatwoChatRuntimeAdapter,
    computerHostAuthorized: Bool
  ) -> Bool {
    if computerHostAuthorized { return true }
    switch runtimeAdapter {
    case .codexExec, .claudeCLI, .grokCLI, .nativeAgent:
      return true
    case .gatewayDirect, .minimaxDirect, .unavailable:
      return false
    }
  }

  /// States that cannot authorize a new host mutation at the spawn boundary.
  ///
  /// Natural completions (`succeeded`/`failed`/`passed`) are deliberately not
  /// listed. This last-mile gate protects an already-frozen turn; those states
  /// are not revocation signals, so ordinary follow-up chat keeps the existing
  /// behavior. Creating a new Goal dispatch after natural completion remains
  /// separately forbidden by `TatwoGoalRunDispatchLifecycle.begin`.
  public static func isTerminalBeforeDispatch(
    status: GoalRunStatus
  ) -> Bool {
    switch status {
    case .cancelled, .superseded, .humanGate, .blocked, .rollbackRequired:
      return true
    case .planned, .dispatching, .running, .succeeded, .failed,
         .awaitingNextCycle, .passed:
      return false
    }
  }

  /// - Parameters:
  ///   - frozenContractID: `ChatTurnDispatchSnapshot.contractID` for this turn.
  ///   - goalStatus: status re-read from the goal store at the spawn boundary;
  ///     `nil` means the record could not be re-verified.
  ///   - boundContractID: the contract the session currently claims, if any.
  ///     For a frozen host-mutating contract this must come from the durable
  ///     thread/discussion owner row. Missing is an authority loss, not an
  ///     in-memory projection fallback.
  public static func denial(
    frozenContractID: String?,
    runtimeAdapter: TatwoChatRuntimeAdapter,
    computerHostAuthorized: Bool,
    boundContractID: String?,
    goalStatus: GoalRunStatus?,
    goalStatusReason: String?
  ) -> Denial? {
    let frozen = frozenContractID?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let frozen, !frozen.isEmpty else { return nil }
    guard isHostMutationCapable(
      runtimeAdapter: runtimeAdapter,
      computerHostAuthorized: computerHostAuthorized)
    else { return nil }
    guard let goalStatus else { return .goalRecordUnverifiable }
    // `statusReason` is diagnostic text, not an authority field. Revocation
    // comes only from the typed durable status or contract-binding authority;
    // recognizing reason strings here would silently expand policy whenever a
    // writer chose a new message.
    if isTerminalBeforeDispatch(status: goalStatus) {
      return .goalTerminalBeforeDispatch
    }
    guard let bound = boundContractID?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !bound.isEmpty
    else {
      return .durableContractBindingMissing
    }
    if bound != frozen {
      return .contractAuthorityDrifted
    }
    return nil
  }

  /// Machine-readable blocker string for receipts and runner-start telemetry.
  public static func blocker(
    _ denial: Denial,
    goalStatus: GoalRunStatus?,
    goalStatusReason: String?
  ) -> String {
    var parts = [denial.rawValue]
    if let goalStatus { parts.append("status=\(goalStatus.rawValue)") }
    if let reason = goalStatusReason?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !reason.isEmpty
    {
      parts.append("reason=\(reason)")
    }
    return parts.joined(separator: " ")
  }
}
