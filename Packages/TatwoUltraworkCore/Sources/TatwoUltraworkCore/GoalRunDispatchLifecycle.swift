import Foundation

public enum TatwoRemoteOutboxIntentStateV1: String, Codable, Sendable, Equatable {
  case prepared
  case publishing
  case committed
  case cancelling
  case cancelled
  case quarantined
}

/// Durable origin-side recovery intent. The full canonical job and exact issued
/// binding are persisted before registry reservation, closing the crash gap
/// between authorization and channel publication.
public struct TatwoRemoteOutboxIntentV1: Codable, Sendable, Equatable {
  public let schema: String
  public let transactionID: String
  public let job: TatwoLoopJobV1
  public let jobCanonicalDigest: String
  public let issuedBinding: TatwoIssuedIdentityBindingV1
  public let exactBindingDigest: String
  public let issuedIdentityBindingsDigest: String
  public let goalRunRevisionDigest: String
  public let preparedGoalRunStatus: GoalRunStatus
  public let preparedAt: Date
  public var state: TatwoRemoteOutboxIntentStateV1
  public var updatedAt: Date
  public var registryDispatchID: String?
  public var quarantineReason: String?

  init(
    job: TatwoLoopJobV1,
    jobCanonicalDigest: String,
    issuedBinding: TatwoIssuedIdentityBindingV1,
    issuedIdentityBindingsDigest: String,
    goalRunRevisionDigest: String,
    preparedGoalRunStatus: GoalRunStatus
  ) {
    let transactionMaterial =
      "\(job.contractID)\n\(job.jobID)\n\(job.dispatchNonce)\n\(jobCanonicalDigest)"
    self.schema = "TatwoRemoteOutboxIntentV1"
    self.transactionID =
      "remote-outbox-\(TatwoLoopJobDigest.sha256(Data(transactionMaterial.utf8)).dropFirst(7))"
    self.job = job
    self.jobCanonicalDigest = jobCanonicalDigest
    self.issuedBinding = issuedBinding
    self.exactBindingDigest =
      TatwoIssuedIdentityBindingV1.deterministicDigest(for: [issuedBinding])
    self.issuedIdentityBindingsDigest = issuedIdentityBindingsDigest
    self.goalRunRevisionDigest = goalRunRevisionDigest
    self.preparedGoalRunStatus = preparedGoalRunStatus
    self.preparedAt = job.createdAt
    self.state = .prepared
    self.updatedAt = job.createdAt
    self.registryDispatchID = nil
    self.quarantineReason = nil
  }
}

enum TatwoRemoteOutboxIntentFaultPoint: String, Sendable, Equatable {
  case afterIntentPrepared
  case afterRegistryReservation
  case afterChannelCommitMarker
}

final class TatwoRemoteOutboxIntentFaultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failAt: TatwoRemoteOutboxIntentFaultPoint?

  init(failAt: TatwoRemoteOutboxIntentFaultPoint? = nil) {
    self.failAt = failAt
  }

  func setFailAt(_ point: TatwoRemoteOutboxIntentFaultPoint?) {
    lock.lock()
    failAt = point
    lock.unlock()
  }

  func check(_ point: TatwoRemoteOutboxIntentFaultPoint) throws {
    lock.lock()
    let shouldFail = failAt == point
    lock.unlock()
    if shouldFail {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_crash_injected",
        message: point.rawValue)
    }
  }
}

public enum TatwoGoalRunDispatchLifecycleError: Error, LocalizedError, Sendable, Equatable {
  case dispatchAlreadyStarting(String)
  case staleGoalRevision(String)
  case goalRunCannotBegin(status: GoalRunStatus)
  case goalRunCannotFinalize(status: GoalRunStatus)
  case dispatchSetEmpty(String)
  case dispatchSetIncomplete([String])
  /// Local gateway dispatch could not resolve an issued identity binding.
  case dispatchBindingMissing(identity: IdentityKind, modelID: String)
  /// More than one issued binding matched and the caller did not identify one exactly.
  case dispatchBindingAmbiguous(identity: IdentityKind, modelID: String, bindingIDs: [String])
  /// Caller-supplied binding tuple disagrees with the issued Work OS contract.
  case dispatchBindingMismatch(field: String, expected: String, actual: String)
  case reconciliationFailed(stage: String, primary: String, cleanup: String)
  case reconciliationRequired(String)
  /// Work OS chokepoint rejected remote dispatch (missing / unregistered contract).
  case remoteDispatchUnauthorized(code: String, message: String)
  /// Job goalID does not match the GoalRun issued for this contractID.
  case remoteGoalIDMismatch(expected: String, actual: String)
  /// Job identity is not bound on the issued Work OS contract.
  case remoteIdentityNotBound(IdentityKind)
  /// Job mode does not match the issued GoalRun mode.
  case remoteModeMismatch(expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .dispatchAlreadyStarting(let contractID):
      return "A dispatch begin is already awaiting ledger acknowledgement for \(contractID)."
    case .staleGoalRevision(let contractID):
      return "stale_goal_revision:\(contractID)"
    case .goalRunCannotBegin(let status):
      return "GoalRun \(status.rawValue) cannot begin a new dispatch."
    case .goalRunCannotFinalize(let status):
      return "GoalRun \(status.rawValue) cannot finalize its dispatch set."
    case .dispatchSetEmpty(let contractID):
      return "GoalRun \(contractID) cannot finalize an empty dispatch set."
    case .dispatchSetIncomplete(let dispatchIDs):
      return "Dispatch set is incomplete: \(dispatchIDs.joined(separator: ", "))."
    case let .dispatchBindingMissing(identity, modelID):
      return "No issued dispatch binding matches identity=\(identity.rawValue) model=\(modelID)."
    case let .dispatchBindingAmbiguous(identity, modelID, bindingIDs):
      return
        "Issued dispatch binding is ambiguous for identity=\(identity.rawValue) model=\(modelID): "
        + bindingIDs.joined(separator: ", ")
    case let .dispatchBindingMismatch(field, expected, actual):
      return "Dispatch binding \(field) mismatch: caller=\(actual) issued=\(expected)."
    case let .reconciliationFailed(stage, primary, cleanup):
      return "Dispatch lifecycle reconciliation failed at \(stage): \(primary); cleanup: \(cleanup)"
    case .reconciliationRequired(let contractID):
      return "GoalRun \(contractID) requires dispatch-ledger reconciliation before retry."
    case let .remoteDispatchUnauthorized(code, message):
      return "remote.dispatch unauthorized (\(code)): \(message)"
    case let .remoteGoalIDMismatch(expected, actual):
      return "remote.dispatch goalID mismatch: job=\(actual) issued=\(expected)"
    case let .remoteIdentityNotBound(identity):
      return "remote.dispatch identity \(identity.rawValue) is not bound on the issued contract."
    case let .remoteModeMismatch(expected, actual):
      return "remote.dispatch mode mismatch: job=\(actual) issued=\(expected)"
    }
  }
}

public struct TatwoGoalRunDispatchCloseGate: Sendable, Equatable {
  public let ok: Bool
  public let code: String
  public let message: String
  public let retryable: Bool

  public init(
    ok: Bool,
    code: String,
    message: String,
    retryable: Bool
  ) {
    self.ok = ok
    self.code = code
    self.message = message
    self.retryable = retryable
  }
}

/// Keeps GoalRun state and the dispatch ledger on one fail-closed lifecycle.
///
/// The CLI and gateway must not independently mutate these two stores. A new run becomes
/// `running` only after the ledger has both created and acknowledged a running dispatch.
/// Terminal GoalRun transitions are propagated, never swallowed.
public enum TatwoGoalRunDispatchLifecycle {
  /// Persists `.passed` only while the GoalRun and its canonical dispatch
  /// terminal evidence agree under the same lifecycle lock.
  ///
  /// Required-receipt evaluation remains the Goal Judge's responsibility. This
  /// is the last consistency fence immediately before durable pass
  /// publication, so a failed, blocked, incomplete, or unsealed dispatch can
  /// never be hidden by an otherwise-complete receipt set.
  @discardableResult
  static func persistPassedIfTerminalConsistent(
    contractID: String,
    requiresCanonicalDispatch: Bool,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoGoalRunDispatchCloseGate {
    try withLifecycleLock(contractID: contractID, goalStore: goalStore) {
      let goal = try requireCurrentRevision(
        contractID: contractID,
        goalStore: goalStore)
      let gate = try terminalConsistencyGate(
        goal: goal,
        requiresCanonicalDispatch: requiresCanonicalDispatch,
        dispatchRegistry: dispatchRegistry)
      guard gate.ok else { return gate }
      let persisted = try goalStore.updateStatus(
        contractID: contractID,
        status: .passed,
        authority: .goalClose,
        reason: "required_receipts_complete_dispatch_terminal_consistent")
      guard persisted.status == .passed else {
        throw TatwoGoalRunStoreError.illegalStatusTransition(
          from: persisted.status,
          to: .passed,
          authority: "goal_close_dispatch_consistency_verify")
      }
      return gate
    }
  }

  private static func terminalConsistencyGate(
    goal: TatwoStoredGoalRun,
    requiresCanonicalDispatch: Bool,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoGoalRunDispatchCloseGate {
    guard let run = try dispatchRegistry.run(forContractID: goal.contractID),
      !run.records.isEmpty
    else {
      if requiresCanonicalDispatch {
        return TatwoGoalRunDispatchCloseGate(
          ok: false,
          code: "dispatch_terminal_missing",
          message:
            "Goal 尚未通過：此 contract 需要 canonical dispatch，"
            + "但 registry 沒有 terminal evidence。請重新派工並取得可驗證終態。",
          retryable: true)
      }
      if [.blocked, .failed, .cancelled, .rollbackRequired, .superseded]
        .contains(goal.status)
      {
        let reason = goal.statusReason?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return TatwoGoalRunDispatchCloseGate(
          ok: false,
          code: "goal_terminal_inconsistent",
          message:
            "Goal 尚未通過：status=\(goal.status.rawValue)"
            + (reason.map { " reason=\($0)" } ?? "")
            + "。修復阻塞原因後可重試，未重新驗證前不會標記完成。",
          retryable: goal.status == .blocked)
      }
      // Some non-execution contracts legitimately close from receipt evidence
      // alone. Once a dispatch run exists, however, it becomes canonical and
      // must pass every check below.
      return TatwoGoalRunDispatchCloseGate(
        ok: true,
        code: "dispatch_not_applicable",
        message: "No canonical dispatch run exists for this receipt-only goal.",
        retryable: false)
    }

    let activeEpoch =
      run.activeCycleEpoch
      ?? run.records.map(\.resolvedCycleEpoch).max()
      ?? 1
    let scoped = run.records.filter {
      $0.resolvedCycleEpoch == activeEpoch
        && ($0.goalID == nil || $0.goalID == goal.goalID)
    }
    let supersededIDs = Set(scoped.compactMap(\.supersedes))
    let heads = scoped.filter { !supersededIDs.contains($0.id) }
    guard !heads.isEmpty else {
      return TatwoGoalRunDispatchCloseGate(
        ok: false,
        code: "dispatch_terminal_missing",
        message:
          "Goal 尚未通過：canonical dispatch run 沒有與目前 goal/epoch 綁定的 terminal head。"
          + "請重新派工並取得可驗證終態。",
        retryable: true)
    }

    if let failed = heads
      .filter({ $0.status == .failed || $0.failureReceipt != nil })
      .max(by: { $0.updatedAt < $1.updatedAt })
    {
      let receipt = failed.failureReceipt
      let errorCode =
        receipt?.errorCode?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        ?? "dispatch_failed"
      let operatorMessage =
        receipt?.operatorMessage.trimmingCharacters(
          in: .whitespacesAndNewlines)
        ?? failed.errorMessage?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        ?? "dispatch failed"
      return TatwoGoalRunDispatchCloseGate(
        ok: false,
        code: errorCode,
        message:
          "Goal 尚未通過：dispatch \(failed.id) 失敗"
          + " (\(errorCode))：\(operatorMessage)。"
          + "修復後可從同一 Goal 重試；目前不會標記完成。",
        retryable: receipt?.failureClass != .terminal)
    }

    if [.blocked, .failed, .cancelled, .rollbackRequired, .superseded]
      .contains(goal.status)
    {
      let reason = goal.statusReason?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return TatwoGoalRunDispatchCloseGate(
        ok: false,
        code: "goal_terminal_inconsistent",
        message:
          "Goal 尚未通過：status=\(goal.status.rawValue)"
          + (reason.map { " reason=\($0)" } ?? "")
          + "。修復阻塞原因後可重試，未重新驗證前不會標記完成。",
        retryable: goal.status == .blocked)
    }

    let incomplete = heads.filter {
      $0.status != .completed && $0.status != .verified
    }
    if let latest = incomplete.max(by: { $0.updatedAt < $1.updatedAt }) {
      return TatwoGoalRunDispatchCloseGate(
        ok: false,
        code: "dispatch_not_terminal",
        message:
          "Goal 尚未通過：dispatch \(latest.id) 仍為 \(latest.status.rawValue)。"
          + "請等待完成或處理阻塞後重試。",
        retryable: true)
    }

    let latestSeal = run.cycleSeals?
      .filter { $0.epoch == activeEpoch }
      .max(by: { $0.sealedAt < $1.sealedAt })
    let sealID = latestSeal?.sealID
      ?? (run.activeCycleEpoch == activeEpoch ? run.sealID : nil)
    let sealedRecordIDs = latestSeal?.recordIDs
      ?? (run.activeCycleEpoch == activeEpoch ? run.sealedRecordIDs : nil)
    let headIDs = heads.map(\.id).sorted()
    guard let sealID,
      !sealID.isEmpty,
      sealedRecordIDs?.sorted() == headIDs,
      goal.latestDispatchCycleSealID == nil
        || goal.latestDispatchCycleSealID == sealID
    else {
      return TatwoGoalRunDispatchCloseGate(
        ok: false,
        code: "dispatch_set_unsealed",
        message:
          "Goal 尚未通過：最新 dispatch terminal set 尚未以同一 seal 封存。"
          + "請先完成 canonical finalize，再重試 Goal Judge。",
        retryable: true)
    }

    return TatwoGoalRunDispatchCloseGate(
      ok: true,
      code: "dispatch_terminal_consistent",
      message: "Canonical dispatch terminal set is complete and sealed.",
      retryable: false)
  }

  @discardableResult
  public static func begin(
    contractID: String,
    bindingID: String,
    sourceSlotID: String,
    identity: IdentityKind,
    modelID: String,
    subtask: String,
    logicalDispatchID: String? = nil,
    supersedes: String? = nil,
    retryAttemptCap: Int = 2,
    helperCap: Int,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigStore.loadDefaultStaging(),
    afterSnapshotProjection: (() throws -> Void)? = nil
  ) throws -> TatwoDispatchRecord {
    let validatedRetryAttemptCap =
      try TatwoGoalRunStore.validatedDispatchRetryAttemptCap(retryAttemptCap)
    return try withLifecycleLock(contractID: contractID, goalStore: goalStore) {
      let snapshot = try goalStore.snapshot(forContractID: contractID)
      let projected = try WorkOSFactory.storedContractProjection(
        snapshot: snapshot,
        catalog: catalog,
        scenarioBook: scenarioBook,
        store: goalStore)
      let binding = try resolveIssuedBinding(
        bindingID: bindingID,
        sourceSlotID: sourceSlotID,
        identity: identity,
        modelID: modelID,
        contract: projected)
      try afterSnapshotProjection?()
      do {
        return try goalStore.withVerifiedCurrentSnapshotTransaction(snapshot) { current in
          try beginFromLockedSnapshot(
            current: &current,
            binding: binding,
            subtask: subtask,
            logicalDispatchID: logicalDispatchID,
            supersedes: supersedes,
            retryAttemptCap: validatedRetryAttemptCap,
            helperCap: helperCap,
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        }
      } catch TatwoGoalRunStoreError.staleGoalRunSnapshot(_) {
        throw TatwoGoalRunDispatchLifecycleError.reconciliationRequired(contractID)
      }
    }
  }

  private static func beginFromLockedSnapshot(
    current: inout TatwoStoredGoalRun,
    binding: WorkOSIdentityBinding,
    subtask: String,
    logicalDispatchID: String?,
    supersedes: String?,
    retryAttemptCap: Int,
    helperCap: Int,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoDispatchRecord {
    let contractID = current.contractID
    try requireCurrentRevision(current)
    if current.status == .blocked,
      current.statusReason?.hasPrefix("reconciliation_required:") == true
    {
      throw TatwoGoalRunDispatchLifecycleError.reconciliationRequired(contractID)
    }
    let enteredDispatching: Bool
    let rollbackStatus: GoalRunStatus
    switch current.status {
    case .planned:
      try goalStore.transitionLockedRecord(
        &current,
        status: .dispatching,
        authority: .caller,
        reason: "dispatch_begin_requested")
      enteredDispatching = true
      rollbackStatus = .planned
    case .running:
      enteredDispatching = false
      rollbackStatus = .running
    case .blocked where supersedes?.isEmpty == false:
      try goalStore.transitionLockedRecord(
        &current,
        status: .dispatching,
        authority: .dispatchRetry,
        reason: "dispatch_retry_requested",
        evidence: .retry(supersedes: supersedes ?? ""))
      enteredDispatching = true
      rollbackStatus = .blocked
    case .dispatching:
      throw TatwoGoalRunDispatchLifecycleError.dispatchAlreadyStarting(contractID)
    case .succeeded, .failed, .cancelled, .humanGate, .awaitingNextCycle, .blocked,
      .passed, .rollbackRequired, .superseded:
      throw TatwoGoalRunDispatchLifecycleError.goalRunCannotBegin(status: current.status)
    }

    let queued: TatwoDispatchRecord
    do {
      queued = try dispatchRegistry.begin(
        contractID: contractID,
        goalID: current.goalID,
        bindingID: binding.id,
        sourceSlotID: binding.sourceSlotID,
        identity: binding.identity,
        modelID: binding.modelID ?? "",
        subtask: subtask,
        logicalDispatchID: logicalDispatchID,
        supersedes: supersedes,
        retryAttemptCap: retryAttemptCap,
        helperCap: helperCap)
    } catch {
      if enteredDispatching {
        try goalStore.transitionLockedRecord(
          &current,
          status: rollbackStatus,
          authority: .ledgerBeginAck,
          reason: "ledger_begin_failed",
          evidence: .ledger(dispatchID: "ledger_begin"))
      }
      throw error
    }

    let running: TatwoDispatchRecord
    do {
      running = try dispatchRegistry.update(
        contractID: contractID,
        dispatchID: queued.id,
        status: .running)
    } catch {
      let primary = String(describing: error)
      do {
        _ = try dispatchRegistry.update(
          contractID: contractID,
          dispatchID: queued.id,
          status: .failed,
          errorMessage: "ledger_ack_failed:\(primary)")
      } catch {
        try goalStore.transitionLockedRecord(
          &current,
          status: .blocked,
          authority: enteredDispatching ? .ledgerBeginAck : .dispatchFailure,
          reason: "reconciliation_required:ledger_ack:\(queued.id)",
          evidence: .reconciliation(stage: "ledger_ack"))
        throw TatwoGoalRunDispatchLifecycleError.reconciliationFailed(
          stage: "ledger_ack",
          primary: primary,
          cleanup: "ledger_fail=\(error)")
      }
      if enteredDispatching {
        try goalStore.transitionLockedRecord(
          &current,
          status: rollbackStatus,
          authority: .ledgerBeginAck,
          reason: "ledger_ack_failed",
          evidence: .ledger(dispatchID: queued.id))
      }
      throw error
    }

    if enteredDispatching {
      try goalStore.transitionLockedRecord(
        &current,
        status: .running,
        authority: .ledgerBeginAck,
        reason: "dispatch_registry_begin_ack:\(running.id)",
        evidence: .ledger(dispatchID: running.id))
    }
    return running
  }

  @discardableResult
  static func begin(
    contractID: String,
    retrySupersedes: String? = nil,
    goalStore: TatwoGoalRunStore,
    ledgerBegin: () throws -> TatwoDispatchRecord,
    ledgerAcknowledge: (TatwoDispatchRecord) throws -> TatwoDispatchRecord,
    ledgerFail: (TatwoDispatchRecord, String) throws -> Void
  ) throws -> TatwoDispatchRecord {
    let issued = try requireCurrentRevision(
      contractID: contractID,
      goalStore: goalStore)
    if issued.status == .blocked,
      issued.statusReason?.hasPrefix("reconciliation_required:") == true
    {
      throw TatwoGoalRunDispatchLifecycleError.reconciliationRequired(contractID)
    }
    let enteredDispatching: Bool
    let rollbackStatus: GoalRunStatus
    switch issued.status {
    case .planned:
      _ = try goalStore.updateStatus(
        contractID: contractID,
        status: .dispatching,
        authority: .caller,
        reason: "dispatch_begin_requested")
      enteredDispatching = true
      rollbackStatus = .planned
    case .running:
      enteredDispatching = false
      rollbackStatus = .running
    case .blocked where retrySupersedes?.isEmpty == false:
      _ = try goalStore.updateStatus(
        contractID: contractID,
        status: .dispatching,
        authority: .dispatchRetry,
        reason: "dispatch_retry_requested",
        evidence: .retry(supersedes: retrySupersedes ?? ""))
      enteredDispatching = true
      rollbackStatus = .blocked
    case .dispatching:
      throw TatwoGoalRunDispatchLifecycleError.dispatchAlreadyStarting(contractID)
    case .succeeded, .failed, .cancelled, .humanGate, .awaitingNextCycle, .blocked,
      .passed, .rollbackRequired, .superseded:
      throw TatwoGoalRunDispatchLifecycleError.goalRunCannotBegin(status: issued.status)
    }

    let queued: TatwoDispatchRecord
    do {
      queued = try ledgerBegin()
    } catch {
      if enteredDispatching {
        try rollbackUnacknowledgedBegin(
          contractID: contractID,
          stage: "ledger_begin",
          primaryError: error,
          rollbackStatus: rollbackStatus,
          goalStore: goalStore)
      }
      throw error
    }

    let running: TatwoDispatchRecord
    do {
      running = try ledgerAcknowledge(queued)
    } catch {
      let primary = String(describing: error)
      var cleanupErrors: [String] = []
      do {
        try ledgerFail(queued, "ledger_ack_failed:\(primary)")
      } catch {
        cleanupErrors.append("ledger_fail=\(error)")
      }
      if !cleanupErrors.isEmpty {
        do {
          _ = try goalStore.updateStatus(
            contractID: contractID,
            status: .blocked,
            authority: enteredDispatching ? .ledgerBeginAck : .dispatchFailure,
            reason: "reconciliation_required:ledger_ack:\(queued.id)",
            evidence: .reconciliation(stage: "ledger_ack"))
        } catch {
          cleanupErrors.append("goal_quarantine=\(error)")
        }
        throw TatwoGoalRunDispatchLifecycleError.reconciliationFailed(
          stage: "ledger_ack",
          primary: primary,
          cleanup: cleanupErrors.joined(separator: "; "))
      }
      if enteredDispatching {
        do {
          _ = try goalStore.updateStatus(
            contractID: contractID,
            status: rollbackStatus,
            authority: .ledgerBeginAck,
            reason: "ledger_ack_failed",
            evidence: .ledger(dispatchID: queued.id))
        } catch {
          cleanupErrors.append("goal_rollback=\(error)")
        }
      }
      throw error
    }

    if enteredDispatching {
      do {
        _ = try goalStore.updateStatus(
          contractID: contractID,
          status: .running,
          authority: .ledgerBeginAck,
          reason: "dispatch_registry_begin_ack:\(running.id)",
          evidence: .ledger(dispatchID: running.id))
      } catch {
        let primary = String(describing: error)
        var cleanupErrors: [String] = []
        do {
          try ledgerFail(running, "goal_running_ack_failed:\(primary)")
        } catch {
          cleanupErrors.append("ledger_fail=\(error)")
        }
        do {
          _ = try goalStore.updateStatus(
            contractID: contractID,
            status: .failed,
            authority: .ledgerBeginAck,
            reason: "goal_running_ack_failed",
            evidence: .ledger(dispatchID: running.id))
        } catch {
          cleanupErrors.append("goal_fail=\(error)")
        }
        if !cleanupErrors.isEmpty {
          throw TatwoGoalRunDispatchLifecycleError.reconciliationFailed(
            stage: "goal_running_ack",
            primary: primary,
            cleanup: cleanupErrors.joined(separator: "; "))
        }
        throw error
      }
    }
    return running
  }

  @discardableResult
  public static func update(
    contractID: String,
    dispatchID: String,
    status: TatwoDispatchStatus,
    receiptID: String? = nil,
    outputRef: String? = nil,
    failureClass: TatwoDispatchFailureClass? = nil,
    errorCode: String? = nil,
    httpStatus: Int? = nil,
    rawErrorDigest: String? = nil,
    backendRequestID: String? = nil,
    backendResponseID: String? = nil,
    errorMessage: String? = nil,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoDispatchRecord {
    try withLifecycleLock(contractID: contractID, goalStore: goalStore) {
      let goal = try requireCurrentRevision(
        contractID: contractID,
        goalStore: goalStore)
      let record = try dispatchRegistry.update(
        contractID: contractID,
        dispatchID: dispatchID,
        status: status,
        receiptID: receiptID,
        outputRef: outputRef,
        failureClass: failureClass,
        errorCode: errorCode,
        httpStatus: httpStatus,
        rawErrorDigest: rawErrorDigest,
        backendRequestID: backendRequestID,
        backendResponseID: backendResponseID,
        errorMessage: errorMessage)

      if status == .failed {
        // M4b update: Grok development is deliberately disabled until its
        // vendor attestation can be verified. Preserve the exact failed lane
        // evidence without converting the Fable+Grok Goal into a retryable
        // dispatch block or pretending that the lane completed. The Goal stays
        // running and therefore cannot pass the canonical finalize barrier.
        if goal.scenario
          == TatwoScenarioConfigDefaults
            .nativeDevelopmentXXLFableGrokScenarioID,
          record.sourceSlotID
            == TatwoNativeDevelopmentDispatchCoordinator
              .grokExecutorSourceSlotID,
          TatwoGatewayDispatchCatalog.normalize(record.modelID)
            == TatwoGatewayDispatchCatalog.normalize("grok-build"),
          record.failureReceipt?.errorCode
            == TatwoNativeDevelopmentDispatchCoordinator
              .grokDevAttestationUnverifiedErrorCode
        {
          return record
        }
        let resolvedClass = record.failureReceipt?.failureClass ?? .unknown
        let retryBudgetExhausted =
          resolvedClass == .retryable && record.resolvedAttempt >= 2
        let goalStatus: GoalRunStatus =
          resolvedClass == .terminal || retryBudgetExhausted ? .failed : .blocked
        _ = try goalStore.updateStatus(
          contractID: contractID,
          status: goalStatus,
          authority: .dispatchFailure,
          reason:
            "dispatch_failed:\(record.id):class=\(resolvedClass.rawValue):attempt=\(record.resolvedAttempt)",
          evidence: .failure(dispatchID: record.id))
      }
      return record
    }
  }

  /// Explicitly seals the known dispatch set after the orchestrator has finished adding work.
  ///
  /// Completing the currently known records is not enough to close a GoalRun because sequential
  /// reviewers may still need to be appended. The caller must cross this barrier, which verifies
  /// a non-empty, fully completed set while holding the same lifecycle lock used by begin/update,
  /// then moves the GoalRun to the human judgment gate. Only `closeGoal` may decide passed versus
  /// rollback-required.
  @discardableResult
  public static func finalize(
    contractID: String,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoStoredGoalRun {
    try withLifecycleLock(contractID: contractID, goalStore: goalStore) {
      let goal = try requireCurrentRevision(
        contractID: contractID,
        goalStore: goalStore)
      if (goal.status == .awaitingNextCycle && goal.hasDispatchCycleFinalizationReason)
        || ([.humanGate, .succeeded].contains(goal.status)
          && goal.hasDispatchSetFinalizationReason)
      {
        guard let run = try dispatchRegistry.run(forContractID: contractID),
          let sealID = run.sealID
        else {
          throw TatwoGoalRunDispatchLifecycleError.goalRunCannotFinalize(status: goal.status)
        }
        return try goalStore.finalizeDispatchSet(
          contractID: contractID,
          sealID: sealID,
          recordCount: run.sealedRecordIDs?.count ?? 0,
          cycleEpoch: run.cycleSeals?.last?.epoch ?? run.activeCycleEpoch ?? 1)
      }
      if goal.status == .planned {
        guard let run = try dispatchRegistry.run(forContractID: contractID),
          !run.records.isEmpty
        else {
          throw TatwoGoalRunDispatchLifecycleError.dispatchSetEmpty(contractID)
        }
      }
      guard goal.status == .running else {
        throw TatwoGoalRunDispatchLifecycleError.goalRunCannotFinalize(status: goal.status)
      }
      let sealed: TatwoStoredDispatchRun
      do {
        sealed = try dispatchRegistry.sealCompletedSet(
          contractID: contractID,
          goalID: goal.goalID)
      } catch TatwoDispatchRegistryError.cannotSealEmpty {
        throw TatwoGoalRunDispatchLifecycleError.dispatchSetEmpty(contractID)
      } catch TatwoDispatchRegistryError.cannotSealIncomplete(let dispatchIDs) {
        throw TatwoGoalRunDispatchLifecycleError.dispatchSetIncomplete(dispatchIDs)
      }
      guard let sealID = sealed.sealID else {
        throw TatwoGoalRunDispatchLifecycleError.reconciliationFailed(
          stage: "dispatch_seal",
          primary: "missing sealID",
          cleanup: "goal remains \(goal.status.rawValue)")
      }
      return try goalStore.finalizeDispatchSet(
        contractID: contractID,
        sealID: sealID,
        recordCount: sealed.sealedRecordIDs?.count ?? 0,
        cycleEpoch: sealed.cycleSeals?.last?.epoch ?? sealed.activeCycleEpoch ?? 1)
    }
  }

  /// Opens a fresh dispatch epoch while preserving all prior records and seals.
  ///
  /// Registry advances first. If the process stops before GoalRun persistence,
  /// retrying this method is safe: registry advance is idempotent and the Goal
  /// transition then catches up under the same lifecycle lock.
  @discardableResult
  public static func advanceCycle(
    contractID: String,
    expectedSealID: String,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoStoredGoalRun {
    try withLifecycleLock(contractID: contractID, goalStore: goalStore) {
      let goal = try requireCurrentRevision(
        contractID: contractID,
        goalStore: goalStore)
      guard goal.isResumableDispatchCycleBoundary
        || (goal.status == .running
          && goal.statusReason?.contains(":after:\(expectedSealID)") == true)
      else {
        throw TatwoGoalRunDispatchLifecycleError.goalRunCannotBegin(status: goal.status)
      }
      let advancedRun = try dispatchRegistry.advanceCycle(
        contractID: contractID,
        goalID: goal.goalID,
        expectedSealID: expectedSealID)
      guard let nextEpoch = advancedRun.activeCycleEpoch else {
        throw TatwoGoalRunDispatchLifecycleError.reconciliationFailed(
          stage: "dispatch_cycle_advance",
          primary: "registry did not persist activeCycleEpoch",
          cleanup: "GoalRun remains \(goal.status.rawValue)")
      }
      return try goalStore.advanceDispatchCycle(
        contractID: contractID,
        expectedSealID: expectedSealID,
        nextEpoch: nextEpoch)
    }
  }

  private static func rollbackUnacknowledgedBegin(
    contractID: String,
    stage: String,
    primaryError: Error,
    rollbackStatus: GoalRunStatus,
    goalStore: TatwoGoalRunStore
  ) throws {
    do {
      _ = try goalStore.updateStatus(
        contractID: contractID,
        status: rollbackStatus,
        authority: .ledgerBeginAck,
        reason: "\(stage)_failed",
        evidence: .ledger(dispatchID: stage))
    } catch {
      throw TatwoGoalRunDispatchLifecycleError.reconciliationFailed(
        stage: stage,
        primary: String(describing: primaryError),
        cleanup: String(describing: error))
    }
  }

  static func withLifecycleLock<T>(
    contractID: String,
    goalStore: TatwoGoalRunStore,
    _ body: () throws -> T
  ) throws -> T {
    try withLifecycleLocks(
      contractIDs: [contractID],
      goalStore: goalStore,
      body)
  }

  /// Acquires multiple canonical lifecycle locks in stable lexical order.
  /// Revision promotion uses this to fence both predecessor and successor
  /// dispatch publication without introducing lock-order inversions.
  static func withLifecycleLocks<T>(
    contractIDs: [String],
    goalStore: TatwoGoalRunStore,
    _ body: () throws -> T
  ) throws -> T {
    let sortedContractIDs = Array(Set(contractIDs)).sorted()
    let lockTargets = try sortedContractIDs.map { contractID -> URL in
      _ = try goalStore.fileURL(forContractID: contractID)
      return goalStore.directoryURL
        .appendingPathComponent("dispatch-lifecycle", isDirectory: true)
        .appendingPathComponent("\(contractID).state", isDirectory: false)
    }

    func acquire(_ index: Int) throws -> T {
      guard index < lockTargets.count else {
        return try body()
      }
      return try TatwoFileLock.withExclusiveLock(for: lockTargets[index]) {
        try acquire(index + 1)
      }
    }
    return try acquire(0)
  }

  @discardableResult
  private static func requireCurrentRevision(
    contractID: String,
    goalStore: TatwoGoalRunStore
  ) throws -> TatwoStoredGoalRun {
    let goal = try goalStore.requireIssuedContract(contractID)
    try requireCurrentRevision(goal)
    return goal
  }

  private static func requireCurrentRevision(
    _ goal: TatwoStoredGoalRun
  ) throws {
    guard goal.status != .superseded,
      goal.successorContractID == nil
    else {
      throw TatwoGoalRunDispatchLifecycleError.staleGoalRevision(
        goal.contractID)
    }
  }

  /// Resolves the exact identity-bound route issued by the stored Work OS contract.
  ///
  /// Binding/source values are never trusted as free-form ledger labels. A caller may omit
  /// them only when identity + canonical model selects exactly one issued binding. When a
  /// binding ID is supplied, all other tuple fields must agree with that binding.
  private static func resolveIssuedBinding(
    bindingID rawBindingID: String,
    sourceSlotID rawSourceSlotID: String,
    identity: IdentityKind,
    modelID rawModelID: String,
    contract: TatwoWorkOSContractV1
  ) throws -> WorkOSIdentityBinding {
    let bindingID = rawBindingID.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceSlotID = rawSourceSlotID.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelID = TatwoGatewayDispatchCatalog.normalize(rawModelID)

    func validate(_ binding: WorkOSIdentityBinding) throws -> WorkOSIdentityBinding {
      if !sourceSlotID.isEmpty, binding.sourceSlotID != sourceSlotID {
        throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMismatch(
          field: "sourceSlotID",
          expected: binding.sourceSlotID,
          actual: sourceSlotID)
      }
      if binding.identity != identity {
        throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMismatch(
          field: "identity",
          expected: binding.identity.rawValue,
          actual: identity.rawValue)
      }
      let issuedModelID = TatwoGatewayDispatchCatalog.normalize(binding.modelID)
      if issuedModelID != modelID {
        throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMismatch(
          field: "modelID",
          expected: issuedModelID,
          actual: modelID)
      }
      return binding
    }

    if !bindingID.isEmpty {
      if let exact = contract.identityBindings.first(where: { $0.id == bindingID }) {
        return try validate(exact)
      }
      let identityModelMatches = contract.identityBindings.filter {
        $0.identity == identity
          && TatwoGatewayDispatchCatalog.normalize($0.modelID) == modelID
      }
      if identityModelMatches.count == 1, let expected = identityModelMatches.first {
        throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMismatch(
          field: "bindingID",
          expected: expected.id,
          actual: bindingID)
      }
      throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMissing(
        identity: identity,
        modelID: modelID)
    }

    var matches = contract.identityBindings.filter {
      $0.identity == identity
        && TatwoGatewayDispatchCatalog.normalize($0.modelID) == modelID
    }
    if !sourceSlotID.isEmpty {
      let sourceMatches = matches.filter { $0.sourceSlotID == sourceSlotID }
      if sourceMatches.isEmpty, matches.count == 1, let expected = matches.first {
        throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMismatch(
          field: "sourceSlotID",
          expected: expected.sourceSlotID,
          actual: sourceSlotID)
      }
      matches = sourceMatches
    }
    guard !matches.isEmpty else {
      throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMissing(
        identity: identity,
        modelID: modelID)
    }
    guard matches.count == 1, let exact = matches.first else {
      throw TatwoGoalRunDispatchLifecycleError.dispatchBindingAmbiguous(
        identity: identity,
        modelID: modelID,
        bindingIDs: matches.map(\.id).sorted())
    }
    return exact
  }

  // MARK: - Remote loop origin dispatch gate

  /// Fail-closed Work OS gate for remote-loop origin dispatch.
  ///
  /// Must run **before** any channel write. Verifies:
  /// - contract was issued by `tatwo.os.begin` into `goalStore` (via chokepoint)
  /// - `job.goalID == issued.goalID`
  /// - GoalRun status allows dispatch (not sealed/closed/terminal)
  /// - job identity is bound on the issued contract
  /// - tatwo-loop payload mode matches issued GoalRun mode when present
  public static func authorizeRemoteDispatch(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
  ) throws -> TatwoStoredGoalRun {
    try authorizeRemoteDispatch(
      job: job,
      goalStore: goalStore,
      environment: environment,
      catalog: catalog,
      scenarioBook: scenarioBook,
      afterSnapshotProjection: nil)
  }

  /// Internal seam for deterministic revision-race tests.
  ///
  /// Production callers always use the public overload. The hook runs after the
  /// durable issued-route projection has been validated but before the final
  /// exact-revision fence.
  static func authorizeRemoteDispatch(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    afterSnapshotProjection: (() throws -> Void)?
  ) throws -> TatwoStoredGoalRun {
    try withAuthorizedRemoteDispatchSnapshot(
      job: job,
      goalStore: goalStore,
      environment: environment,
      catalog: catalog,
      scenarioBook: scenarioBook,
      afterSnapshotProjection: afterSnapshotProjection
    ) { issued, _, _ in
      issued
    }
  }

  private static func withAuthorizedRemoteDispatchSnapshot<T>(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    environment: [String: String],
    catalog: TatwoCatalog,
    scenarioBook: TatwoScenarioConfigBookV1,
    afterSnapshotProjection: (() throws -> Void)?,
    body: (
      TatwoStoredGoalRun,
      TatwoIssuedIdentityBindingV1,
      TatwoGoalRunSnapshotV1
    ) throws -> T
  ) throws -> T {
    try job.validate()
    let toll = TatwoWorkOSChokepoint.authorize(
      contractID: job.contractID,
      action: "remote.dispatch",
      store: goalStore,
      environment: environment)
    guard toll.ok else {
      if toll.code == "stale_goal_revision" {
        throw TatwoGoalRunDispatchLifecycleError.staleGoalRevision(
          job.contractID)
      }
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: toll.code,
        message: toll.message)
    }

    let snapshot = try goalStore.snapshot(forContractID: job.contractID)
    let issued = snapshot.record
    try requireCurrentRevision(issued)
    guard job.goalID == issued.goalID else {
      throw TatwoGoalRunDispatchLifecycleError.remoteGoalIDMismatch(
        expected: issued.goalID,
        actual: job.goalID)
    }

    switch issued.status {
    case .planned, .running:
      break
    case .dispatching:
      throw TatwoGoalRunDispatchLifecycleError.dispatchAlreadyStarting(job.contractID)
    case .succeeded, .failed, .cancelled, .humanGate, .awaitingNextCycle, .blocked,
      .passed, .rollbackRequired, .superseded:
      throw TatwoGoalRunDispatchLifecycleError.goalRunCannotBegin(status: issued.status)
    }

    _ = try WorkOSFactory.storedContractProjection(
      snapshot: snapshot,
      catalog: catalog,
      scenarioBook: scenarioBook,
      store: goalStore)
    guard
      let issuedBindings = issued.issuedIdentityBindings,
      issued.issuedIdentityBindingsDigest != nil
    else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "issued_route_snapshot_missing",
        message: "remote dispatch requires the durable identity-binding snapshot issued by tatwo.os.begin")
    }

    let issuedBinding: TatwoIssuedIdentityBindingV1
    if case let .tatwoLoop(payload) = job.payload {
      guard payload.contractID == job.contractID, payload.goalID == job.goalID else {
        throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
          code: "payload_contract_mismatch",
          message: "tatwo-loop payload contract/goal must match job envelope")
      }
      guard payload.identity == job.identity else {
        throw TatwoGoalRunDispatchLifecycleError.remoteIdentityNotBound(payload.identity)
      }
      guard let exactModelRouteID = payload.exactModelRouteID,
        !exactModelRouteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
          code: "remote_route_binding_missing",
          message: "tatwo-loop remote dispatch requires an exact issued model route")
      }
      issuedBinding = try resolveIssuedRemoteBinding(
        identity: job.identity,
        modelID: exactModelRouteID,
        issuedBindings: issuedBindings)
      guard payload.mode.rawValue == issued.mode.rawValue else {
        throw TatwoGoalRunDispatchLifecycleError.remoteModeMismatch(
          expected: issued.mode.rawValue,
          actual: payload.mode.rawValue)
      }
    } else {
      issuedBinding = try resolveIssuedShellSafeBinding(
        identity: job.identity,
        issuedBindings: issuedBindings)
    }

    try afterSnapshotProjection?()
    do {
      return try goalStore.withVerifiedCurrentSnapshot(snapshot) {
        try body(issued, issuedBinding, snapshot)
      }
    } catch TatwoGoalRunStoreError.staleGoalRunSnapshot {
      throw staleGoalRunSnapshotError()
    }
  }

  private static func staleGoalRunSnapshotError() -> TatwoGoalRunDispatchLifecycleError {
    .remoteDispatchUnauthorized(
      code: "goal_run_snapshot_stale",
      message: "GoalRun changed while remote dispatch authorization was being verified")
  }

  private static func resolveIssuedRemoteBinding(
    identity: IdentityKind,
    modelID rawModelID: String,
    issuedBindings: [TatwoIssuedIdentityBindingV1]
  ) throws -> TatwoIssuedIdentityBindingV1 {
    let modelID = TatwoGatewayDispatchCatalog.normalize(rawModelID)
    let matches = issuedBindings.filter {
      $0.identity == identity
        && TatwoGatewayDispatchCatalog.normalize($0.modelID) == modelID
    }
    guard !matches.isEmpty else {
      throw TatwoGoalRunDispatchLifecycleError.dispatchBindingMissing(
        identity: identity,
        modelID: modelID)
    }
    guard matches.count == 1, let exact = matches.first else {
      throw TatwoGoalRunDispatchLifecycleError.dispatchBindingAmbiguous(
        identity: identity,
        modelID: modelID,
        bindingIDs: matches.map(\.id).sorted())
    }
    return exact
  }

  private static func resolveIssuedShellSafeBinding(
    identity: IdentityKind,
    issuedBindings: [TatwoIssuedIdentityBindingV1]
  ) throws -> TatwoIssuedIdentityBindingV1 {
    let matches = issuedBindings.filter { $0.identity == identity }
    guard !matches.isEmpty else {
      throw TatwoGoalRunDispatchLifecycleError.remoteIdentityNotBound(identity)
    }
    guard matches.count == 1, let exact = matches.first else {
      throw TatwoGoalRunDispatchLifecycleError.dispatchBindingAmbiguous(
        identity: identity,
        modelID: "<identity-only>",
        bindingIDs: matches.map(\.id).sorted())
    }
    return exact
  }

  private static func remoteOutboxIntentURL(
    contractID: String,
    jobID: String,
    goalStore: TatwoGoalRunStore
  ) throws -> URL {
    _ = try goalStore.fileURL(forContractID: contractID)
    return goalStore.directoryURL
      .appendingPathComponent("remote-outbox-intents", isDirectory: true)
      .appendingPathComponent(TatwoLoopPathComponent.sanitize(contractID), isDirectory: true)
      .appendingPathComponent(
        "\(TatwoLoopPathComponent.sanitize(jobID)).json",
        isDirectory: false)
  }

  private static func encodeRemoteOutboxIntent(
    _ intent: TatwoRemoteOutboxIntentV1
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(intent)
  }

  private static func decodeRemoteOutboxIntent(
    from url: URL
  ) throws -> TatwoRemoteOutboxIntentV1 {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      TatwoRemoteOutboxIntentV1.self,
      from: Data(contentsOf: url))
  }

  private static func validateRemoteOutboxIntent(
    _ intent: TatwoRemoteOutboxIntentV1,
    expectedJob: TatwoLoopJobV1? = nil,
    expectedBinding: TatwoIssuedIdentityBindingV1? = nil
  ) throws {
    guard intent.schema == "TatwoRemoteOutboxIntentV1" else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_intent_tampered",
        message: "remote outbox intent schema is invalid")
    }
    if intent.state == .quarantined {
      return
    }
    try intent.job.validate()
    let actualJobDigest = try intent.job.canonicalDigest()
    let transactionMaterial =
      "\(intent.job.contractID)\n\(intent.job.jobID)\n\(intent.job.dispatchNonce)\n\(actualJobDigest)"
    let expectedTransactionID =
      "remote-outbox-\(TatwoLoopJobDigest.sha256(Data(transactionMaterial.utf8)).dropFirst(7))"
    guard intent.jobCanonicalDigest == actualJobDigest,
      intent.transactionID == expectedTransactionID,
      intent.exactBindingDigest
        == TatwoIssuedIdentityBindingV1.deterministicDigest(for: [intent.issuedBinding]),
      intent.issuedBinding.identity == intent.job.identity,
      !intent.issuedIdentityBindingsDigest.isEmpty,
      !intent.goalRunRevisionDigest.isEmpty
    else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_intent_tampered",
        message: "remote outbox intent immutable digest or binding is invalid")
    }
    if let expectedJob {
      guard expectedJob == intent.job else {
        throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
          code: "remote_outbox_intent_conflict",
          message: "existing remote outbox intent is bound to a different job")
      }
    }
    if let expectedBinding {
      guard expectedBinding == intent.issuedBinding else {
        throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
          code: "remote_outbox_binding_conflict",
          message: "existing remote outbox intent is bound to a different issued route")
      }
    }
  }

  private static func prepareRemoteOutboxIntent(
    job: TatwoLoopJobV1,
    issued: TatwoStoredGoalRun,
    issuedBinding: TatwoIssuedIdentityBindingV1,
    snapshot: TatwoGoalRunSnapshotV1,
    goalStore: TatwoGoalRunStore
  ) throws -> TatwoRemoteOutboxIntentV1 {
    guard let issuedIdentityBindingsDigest = issued.issuedIdentityBindingsDigest else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "issued_route_snapshot_missing",
        message: "remote outbox intent requires the issued identity-binding digest")
    }
    let expected = TatwoRemoteOutboxIntentV1(
      job: job,
      jobCanonicalDigest: try job.canonicalDigest(),
      issuedBinding: issuedBinding,
      issuedIdentityBindingsDigest: issuedIdentityBindingsDigest,
      goalRunRevisionDigest: snapshot.persistedRevisionDigest,
      preparedGoalRunStatus: issued.status)
    let url = try remoteOutboxIntentURL(
      contractID: job.contractID,
      jobID: job.jobID,
      goalStore: goalStore)
    let data = try encodeRemoteOutboxIntent(expected)
    var duplicate: TatwoRemoteOutboxIntentV1?
    try TatwoCreateOnlyFile.write(
      data,
      to: url,
      onDuplicate: {
        let existing = try decodeRemoteOutboxIntent(from: url)
        try validateRemoteOutboxIntent(
          existing,
          expectedJob: job,
          expectedBinding: issuedBinding)
        guard existing.issuedIdentityBindingsDigest == issuedIdentityBindingsDigest else {
          throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
            code: "remote_outbox_issued_snapshot_conflict",
            message: "existing intent was prepared from a different issued route snapshot")
        }
        duplicate = existing
      })
    return duplicate ?? expected
  }

  private static func writeRemoteOutboxIntent(
    _ intent: TatwoRemoteOutboxIntentV1,
    goalStore: TatwoGoalRunStore
  ) throws {
    try validateRemoteOutboxIntent(intent)
    let url = try remoteOutboxIntentURL(
      contractID: intent.job.contractID,
      jobID: intent.job.jobID,
      goalStore: goalStore)
    try TatwoAtomicFile.write(try encodeRemoteOutboxIntent(intent), to: url)
  }

  public static func remoteOutboxIntent(
    contractID: String,
    jobID: String,
    goalStore: TatwoGoalRunStore
  ) throws -> TatwoRemoteOutboxIntentV1? {
    let url = try remoteOutboxIntentURL(
      contractID: contractID,
      jobID: jobID,
      goalStore: goalStore)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let intent = try decodeRemoteOutboxIntent(from: url)
    try validateRemoteOutboxIntent(intent)
    guard intent.job.contractID == contractID, intent.job.jobID == jobID else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_path_binding_mismatch",
        message: "remote outbox intent path does not match its embedded job")
    }
    return intent
  }

  private static func requireRemoteOutboxIntent(
    contractID: String,
    jobID: String,
    goalStore: TatwoGoalRunStore
  ) throws -> TatwoRemoteOutboxIntentV1 {
    guard let intent = try remoteOutboxIntent(
      contractID: contractID,
      jobID: jobID,
      goalStore: goalStore)
    else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_intent_missing",
        message: "remote dispatch was never durably prepared")
    }
    return intent
  }

  private static func quarantineRemoteOutboxIntent(
    _ intent: inout TatwoRemoteOutboxIntentV1,
    reason: String,
    goalStore: TatwoGoalRunStore
  ) throws {
    intent.state = .quarantined
    intent.quarantineReason = reason
    intent.updatedAt = Date()
    try writeRemoteOutboxIntent(intent, goalStore: goalStore)
  }

  private static func requireRemoteOutboxReservationAllowed(
    _ intent: TatwoRemoteOutboxIntentV1
  ) throws {
    switch intent.state {
    case .prepared, .publishing, .committed:
      return
    case .cancelling, .cancelled:
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_cancelled",
        message: "cancelling or cancelled remote outbox intent cannot reserve or publish")
    case .quarantined:
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_quarantined",
        message: intent.quarantineReason ?? "remote outbox intent is quarantined")
    }
  }

  private static func bindRemoteOutboxReservation(
    _ record: TatwoDispatchRecord,
    to intent: inout TatwoRemoteOutboxIntentV1
  ) throws {
    if let existing = intent.registryDispatchID, existing != record.id {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_registry_conflict",
        message: "existing intent is bound to a different registry reservation")
    }
    intent.registryDispatchID = record.id
  }

  private static func loadRemoteOutboxIntentUnchecked(
    contractID: String,
    jobID: String,
    goalStore: TatwoGoalRunStore
  ) throws -> TatwoRemoteOutboxIntentV1 {
    let url = try remoteOutboxIntentURL(
      contractID: contractID,
      jobID: jobID,
      goalStore: goalStore)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_outbox_intent_missing",
        message: "remote dispatch was never durably prepared")
    }
    return try decodeRemoteOutboxIntent(from: url)
  }

  /// Authorizes the human-facing remote-compute borrow contract.
  ///
  /// Trust evidence must be the pinned identity loaded by the production runner.
  /// Callers cannot replace it with a UI-provided Boolean.
  public static func authorizeRemoteBorrow(
    job: TatwoLoopJobV1,
    authorizationStore: TatwoRemoteBorrowAuthorizationStore,
    verifiedTargetIdentity: TatwoDevicePublicIdentityV1,
    now: Date = Date()
  ) throws {
    guard let invocation = job.remoteBorrowInvocation else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: TatwoRemoteBorrowAuthorizationBlockerV1.missingInvocation.rawValue,
        message: "remote job is not bound to a Chat session approval")
    }
    do {
      try invocation.validate(
        targetDeviceID: job.targetDeviceID,
        contractID: job.contractID,
        goalID: job.goalID)
    } catch {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: TatwoRemoteBorrowAuthorizationBlockerV1.invocationScopeMismatch.rawValue,
        message: error.localizedDescription)
    }
    guard
      verifiedTargetIdentity.deviceID == job.targetDeviceID,
      verifiedTargetIdentity.keyStatus == .active
    else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: TatwoRemoteBorrowAuthorizationBlockerV1.targetNotTrusted.rawValue,
        message: "target identity is absent, revoked, or does not match the signed job")
    }

    let policy: TatwoRemoteDeviceExecutionPolicyV1
    let grant: TatwoRemoteSessionGrantV1?
    do {
      policy = try authorizationStore.devicePolicy(
        targetDeviceID: job.targetDeviceID)
      grant = try authorizationStore.sessionGrant(
        sessionID: invocation.sessionID,
        targetDeviceID: job.targetDeviceID,
        contractID: job.contractID,
        now: now)
    } catch {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: TatwoRemoteBorrowAuthorizationBlockerV1.authorizationStoreUnreadable.rawValue,
        message: error.localizedDescription)
    }
    let decision = TatwoRemoteBorrowAuthorizationEvaluator.decide(
      mode: invocation.mode,
      risk: invocation.risk,
      policy: policy,
      grant: grant,
      sessionID: invocation.sessionID,
      targetDeviceID: job.targetDeviceID,
      contractID: job.contractID,
      targetIsTrusted: true,
      now: now)
    guard decision.allowed else {
      let blocker = decision.blocker ?? .sessionApprovalRequired
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: blocker.rawValue,
        message: "remote borrow authorization is not active for this invocation")
    }
    guard grant?.id == invocation.grantID else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: TatwoRemoteBorrowAuthorizationBlockerV1.grantIDMismatch.rawValue,
        message: "signed job grant ID does not match the active durable approval")
    }
  }

  /// Authorize remote job against Work OS, then reserve a registry binding (prepare).
  ///
  /// Single critical section: Work OS authorize + remote-borrow authorize + registry
  /// reservation. Does **not** write the channel — callers commit via channel enqueue
  /// only after this reservation succeeds (prepare/commit ordering).
  @discardableResult
  public static func beginRemote(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    authorizationStore: TatwoRemoteBorrowAuthorizationStore,
    verifiedTargetIdentity: TatwoDevicePublicIdentityV1,
    readinessTrust: TatwoLoopJobChannelTrust? = nil,
    readinessProvider: (any TatwoRemoteDispatchReadinessProviding)? = nil,
    readinessRequirements: TatwoRemoteDispatchReadinessRequirementsV1? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
  ) throws -> TatwoDispatchRecord {
    try beginRemote(
      job: job,
      goalStore: goalStore,
      dispatchRegistry: dispatchRegistry,
      authorizationStore: authorizationStore,
      verifiedTargetIdentity: verifiedTargetIdentity,
      readinessTrust: readinessTrust,
      readinessProvider: readinessProvider,
      readinessRequirements: readinessRequirements,
      environment: environment,
      catalog: catalog,
      scenarioBook: scenarioBook,
      afterPreflightAuthorization: nil,
      intentFaultBox: nil)
  }

  /// GoalRun-gated prepare path for bounded `.shellSafe` work.
  ///
  /// Shell-safe jobs do not borrow a Chat session or claim agent readiness, but
  /// they still require an issued, active Work OS contract and reserve their
  /// registry binding under the same lifecycle lock as agent jobs.
  @discardableResult
  static func beginRemoteShellSafe(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    afterSnapshotProjection: (() throws -> Void)? = nil,
    afterCurrentSnapshotVerified: (() throws -> Void)? = nil,
    intentFaultBox: TatwoRemoteOutboxIntentFaultBox? = nil
  ) throws -> TatwoDispatchRecord {
    guard case .shellSafe = job.payload else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_borrow_context_missing",
        message: "agent remote dispatch cannot use the shell-safe prepare path")
    }
    return try withLifecycleLock(contractID: job.contractID, goalStore: goalStore) {
      try withAuthorizedRemoteDispatchSnapshot(
        job: job,
        goalStore: goalStore,
        environment: environment,
        catalog: catalog,
        scenarioBook: scenarioBook,
        afterSnapshotProjection: afterSnapshotProjection
      ) { issued, issuedBinding, snapshot in
        try afterCurrentSnapshotVerified?()
        var intent = try prepareRemoteOutboxIntent(
          job: job,
          issued: issued,
          issuedBinding: issuedBinding,
          snapshot: snapshot,
          goalStore: goalStore)
        try requireRemoteOutboxReservationAllowed(intent)
        try intentFaultBox?.check(.afterIntentPrepared)
        let record = try dispatchRegistry.beginRemote(
          job: job,
          issuedBinding: issuedBinding)
        try intentFaultBox?.check(.afterRegistryReservation)
        try bindRemoteOutboxReservation(record, to: &intent)
        try writeRemoteOutboxIntent(intent, goalStore: goalStore)
        return record
      }
    }
  }

  /// Internal seam used by deterministic race tests after a deliberately stale
  /// preflight authorization. Production callers always use the public overload
  /// and skip the preflight; the locked authorization below is authoritative.
  @discardableResult
  static func beginRemote(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    authorizationStore: TatwoRemoteBorrowAuthorizationStore,
    verifiedTargetIdentity: TatwoDevicePublicIdentityV1,
    readinessTrust: TatwoLoopJobChannelTrust? = nil,
    readinessProvider: (any TatwoRemoteDispatchReadinessProviding)? = nil,
    readinessRequirements: TatwoRemoteDispatchReadinessRequirementsV1? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    afterPreflightAuthorization: (() -> Void)?,
    intentFaultBox: TatwoRemoteOutboxIntentFaultBox? = nil
  ) throws -> TatwoDispatchRecord {
    // Preflight outside both lifecycle and session-grant locks. The target
    // transport may block; never hold authorization locks while collecting it.
    _ = try authorizeRemoteDispatch(
      job: job,
      goalStore: goalStore,
      environment: environment,
      catalog: catalog,
      scenarioBook: scenarioBook)
    guard let invocation = job.remoteBorrowInvocation else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: TatwoRemoteBorrowAuthorizationBlockerV1.missingInvocation.rawValue,
        message: "remote job is not bound to a Chat session approval")
    }
    guard let readinessTrust else {
      throw readinessBlocker(.missingRequirements, stage: "trust")
    }
    let preflightTarget = try currentReadinessTarget(
      job: job,
      verifiedTargetIdentity: verifiedTargetIdentity,
      readinessTrust: readinessTrust,
      environment: environment)
    try authorizeRemoteBorrow(
      job: job,
      authorizationStore: authorizationStore,
      verifiedTargetIdentity: preflightTarget)
    let derivedReadinessRequirements: TatwoRemoteDispatchReadinessRequirementsV1
    do {
      derivedReadinessRequirements = try TatwoRemoteDispatchReadinessRequirementsV1(job: job)
    } catch let error as TatwoRemoteDispatchReadinessError {
      throw readinessBlocker(error, stage: "job_binding")
    }
    guard let readinessProvider else {
      throw readinessBlocker(.missingProvider, stage: "provider")
    }
    if let readinessRequirements,
      readinessRequirements != derivedReadinessRequirements
    {
      throw readinessBlocker(
        .scopeMismatch("challengeNonce"),
        stage: "requirements")
    }
    let readinessRequest: TatwoRemoteDispatchReadinessRequestV1
    do {
      readinessRequest = try TatwoRemoteDispatchReadinessRequestV1(
        job: job,
        requirements: derivedReadinessRequirements)
    } catch let error as TatwoRemoteDispatchReadinessError {
      throw readinessBlocker(error, stage: "request")
    } catch {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_readiness_request_failed",
        message: error.localizedDescription)
    }
    let readinessReceipt: TatwoRemoteDispatchReadinessReceiptV1
    do {
      readinessReceipt = try readinessProvider.readinessReceipt(
        for: readinessRequest)
    } catch {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: "remote_readiness_snapshot_failed",
        message: error.localizedDescription)
    }
    afterPreflightAuthorization?()

    return try withLifecycleLock(contractID: job.contractID, goalStore: goalStore) {
      // Lock order is lifecycle -> GoalRun revision -> authorization scope -> registry.
      // Holding the exact GoalRun revision through beginRemote prevents a status or
      // receipt mutation from landing after authorization but before reservation.
      try withAuthorizedRemoteDispatchSnapshot(
        job: job,
        goalStore: goalStore,
        environment: environment,
        catalog: catalog,
        scenarioBook: scenarioBook,
        afterSnapshotProjection: nil
      ) { issued, issuedBinding, snapshot in
        // Revocation takes only the authorization scope, so it cannot deadlock by
        // acquiring these locks in reverse. Holding it through beginRemote makes
        // the active-grant read and reservation one atomic authorization boundary.
        try authorizationStore.withSessionGrantScopeLock(
          sessionID: invocation.sessionID,
          targetDeviceID: job.targetDeviceID,
          contractID: job.contractID
        ) {
          let currentTarget = try currentReadinessTarget(
            job: job,
            verifiedTargetIdentity: verifiedTargetIdentity,
            readinessTrust: readinessTrust,
            environment: environment)
          try authorizeRemoteBorrow(
            job: job,
            authorizationStore: authorizationStore,
            verifiedTargetIdentity: currentTarget)
          do {
            try readinessReceipt.verify(
              job: job,
              requirements: derivedReadinessRequirements,
              trust: readinessTrust,
              environment: environment)
          } catch let error as TatwoRemoteDispatchReadinessError {
            throw readinessBlocker(error, stage: "verify")
          } catch {
            throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
              code: "remote_readiness_rejected",
              message: error.localizedDescription)
          }
          var intent = try prepareRemoteOutboxIntent(
            job: job,
            issued: issued,
            issuedBinding: issuedBinding,
            snapshot: snapshot,
            goalStore: goalStore)
          try requireRemoteOutboxReservationAllowed(intent)
          try intentFaultBox?.check(.afterIntentPrepared)
          let record = try dispatchRegistry.beginRemote(
            job: job,
            issuedBinding: issuedBinding)
          try intentFaultBox?.check(.afterRegistryReservation)
          try bindRemoteOutboxReservation(record, to: &intent)
          try writeRemoteOutboxIntent(intent, goalStore: goalStore)
          return record
        }
      }
    }
  }

  private static func currentReadinessTarget(
    job: TatwoLoopJobV1,
    verifiedTargetIdentity: TatwoDevicePublicIdentityV1,
    readinessTrust: TatwoLoopJobChannelTrust,
    environment: [String: String]
  ) throws -> TatwoDevicePublicIdentityV1 {
    guard let current = try readinessTrust.currentPinnedIdentity(
      deviceID: job.targetDeviceID,
      environment: environment),
      current == verifiedTargetIdentity,
      current.keyStatus == .active
    else {
      throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
        code: TatwoRemoteBorrowAuthorizationBlockerV1.targetNotTrusted.rawValue,
        message: "target pin is absent, changed, or revoked")
    }
    return current
  }

  private static func readinessBlocker(
    _ error: TatwoRemoteDispatchReadinessError,
    stage: String
  ) -> TatwoGoalRunDispatchLifecycleError {
    TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
      code: "remote_readiness_\(stage)",
      message: error.errorDescription ?? String(describing: error))
  }

  /// Re-authorize the exact current GoalRun revision at the channel commit boundary.
  ///
  /// Reservation and channel publication are two durable mutations. A cancellation
  /// may legitimately land between them, so the origin must fence current state again
  /// and keep the GoalRun file lock through the channel's commit-marker write.
  public static func commitRemoteChannel<T>(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    commit: () throws -> T
  ) throws -> T {
    try commitRemoteChannel(
      job: job,
      goalStore: goalStore,
      environment: environment,
      catalog: catalog,
      scenarioBook: scenarioBook,
      intentFaultBox: nil,
      commit: commit)
  }

  static func commitRemoteChannel<T>(
    job: TatwoLoopJobV1,
    goalStore: TatwoGoalRunStore,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    intentFaultBox: TatwoRemoteOutboxIntentFaultBox?,
    commit: () throws -> T
  ) throws -> T {
    try withLifecycleLock(contractID: job.contractID, goalStore: goalStore) {
      try withAuthorizedRemoteDispatchSnapshot(
        job: job,
        goalStore: goalStore,
        environment: environment,
        catalog: catalog,
        scenarioBook: scenarioBook,
        afterSnapshotProjection: nil
      ) { issued, issuedBinding, _ in
        var intent = try requireRemoteOutboxIntent(
          contractID: job.contractID,
          jobID: job.jobID,
          goalStore: goalStore)
        try validateRemoteOutboxIntent(
          intent,
          expectedJob: job,
          expectedBinding: issuedBinding)
        guard intent.issuedIdentityBindingsDigest == issued.issuedIdentityBindingsDigest else {
          try quarantineRemoteOutboxIntent(
            &intent,
            reason: "issued identity-binding snapshot changed before channel publication",
            goalStore: goalStore)
          throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
            code: "remote_outbox_issued_snapshot_conflict",
            message: "current issued route snapshot does not match the prepared outbox intent")
        }
        switch intent.state {
        case .cancelling, .cancelled:
          throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
            code: "remote_outbox_cancelled",
            message: "cancelling or cancelled remote outbox intent cannot publish")
        case .quarantined:
          throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
            code: "remote_outbox_quarantined",
            message: intent.quarantineReason ?? "remote outbox intent is quarantined")
        case .committed:
          return try commit()
        case .prepared, .publishing:
          intent.state = .publishing
          intent.updatedAt = Date()
          try writeRemoteOutboxIntent(intent, goalStore: goalStore)
        }
        let result = try commit()
        try intentFaultBox?.check(.afterChannelCommitMarker)
        intent.state = .committed
        intent.updatedAt = Date()
        try writeRemoteOutboxIntent(intent, goalStore: goalStore)
        return result
      }
    }
  }

  /// Reopen one durable remote outbox transaction after an origin crash.
  ///
  /// Recovery never invents a replacement job or route. It either completes
  /// the exact prepared attempt, observes cancellation, or persists quarantine.
  @discardableResult
  public static func reconcileRemoteOutbox(
    contractID: String,
    jobID: String,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    channel: TatwoLoopJobChannel,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
  ) throws -> TatwoRemoteOutboxIntentV1 {
    try withLifecycleLock(contractID: contractID, goalStore: goalStore) {
      _ = try requireCurrentRevision(
        contractID: contractID,
        goalStore: goalStore)
      var intent = try loadRemoteOutboxIntentUnchecked(
        contractID: contractID,
        jobID: jobID,
        goalStore: goalStore)
      guard intent.job.contractID == contractID, intent.job.jobID == jobID else {
        intent.state = .quarantined
        intent.quarantineReason = "intent path binding mismatch"
        intent.updatedAt = Date()
        try writeRemoteOutboxIntent(intent, goalStore: goalStore)
        return intent
      }
      do {
        try validateRemoteOutboxIntent(intent)
      } catch {
        intent.state = .quarantined
        intent.quarantineReason = "intent immutable validation failed: \(error.localizedDescription)"
        intent.updatedAt = Date()
        try writeRemoteOutboxIntent(intent, goalStore: goalStore)
        return intent
      }
      if intent.state == .quarantined || intent.state == .cancelled {
        return intent
      }

      if intent.state == .cancelling {
        let outcome = try channel.signalCancel(for: intent.job)
        switch outcome {
        case .cancelled, .terminalWon(.cancelled):
          intent.state = .cancelled
          try projectRemoteCancellationIfReserved(
            intent: intent,
            dispatchRegistry: dispatchRegistry)
        case .terminalWon:
          intent.state = .committed
        }
        intent.updatedAt = Date()
        try writeRemoteOutboxIntent(intent, goalStore: goalStore)
        return intent
      }

      if let cancellation = try channel.reconcileCancelTombstone(for: intent.job) {
        switch cancellation {
        case .cancelled, .terminalWon(.cancelled):
          intent.state = .cancelled
          intent.updatedAt = Date()
          try projectRemoteCancellationIfReserved(
            intent: intent,
            dispatchRegistry: dispatchRegistry)
          try writeRemoteOutboxIntent(intent, goalStore: goalStore)
          return intent
        case .terminalWon:
          intent.state = .committed
          intent.updatedAt = Date()
          try writeRemoteOutboxIntent(intent, goalStore: goalStore)
          return intent
        }
      }

      do {
        return try withAuthorizedRemoteDispatchSnapshot(
          job: intent.job,
          goalStore: goalStore,
          environment: environment,
          catalog: catalog,
          scenarioBook: scenarioBook,
          afterSnapshotProjection: nil
        ) { issued, currentBinding, _ in
          try validateRemoteOutboxIntent(
            intent,
            expectedJob: intent.job,
            expectedBinding: currentBinding)
          guard intent.issuedIdentityBindingsDigest == issued.issuedIdentityBindingsDigest else {
            throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
              code: "remote_outbox_issued_snapshot_conflict",
              message: "current issued route snapshot differs from prepared intent")
          }
          let record = try dispatchRegistry.beginRemote(
            job: intent.job,
            issuedBinding: currentBinding)
          if let existingID = intent.registryDispatchID, existingID != record.id {
            throw TatwoGoalRunDispatchLifecycleError.remoteDispatchUnauthorized(
              code: "remote_outbox_registry_conflict",
              message: "registry reservation ID differs from prepared intent")
          }
          intent.registryDispatchID = record.id
          intent.state = .publishing
          intent.updatedAt = Date()
          try writeRemoteOutboxIntent(intent, goalStore: goalStore)
          _ = try channel.enqueue(intent.job)
          guard channel.hasCommitMarker(forJobID: intent.job.jobID) else {
            throw TatwoLoopJobStateError.missingCommitMarker(jobID: intent.job.jobID)
          }
          intent.state = .committed
          intent.updatedAt = Date()
          try writeRemoteOutboxIntent(intent, goalStore: goalStore)
          return intent
        }
      } catch {
        intent.state = .quarantined
        intent.quarantineReason = "reopen reauthorization or publication failed: \(error.localizedDescription)"
        intent.updatedAt = Date()
        try writeRemoteOutboxIntent(intent, goalStore: goalStore)
        return intent
      }
    }
  }

  /// Public origin cancellation chokepoint. The signed tombstone and channel
  /// publication share one per-job fence; registry projection never creates a
  /// missing reservation merely to record cancellation.
  @discardableResult
  public static func cancelRemoteOutbox(
    contractID: String,
    jobID: String,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    channel: TatwoLoopJobChannel
  ) throws -> TatwoRemoteOutboxIntentV1 {
    try withLifecycleLock(contractID: contractID, goalStore: goalStore) {
      _ = try requireCurrentRevision(
        contractID: contractID,
        goalStore: goalStore)
      var intent = try requireRemoteOutboxIntent(
        contractID: contractID,
        jobID: jobID,
        goalStore: goalStore)
      switch intent.state {
      case .cancelled, .quarantined:
        return intent
      case .prepared, .publishing, .committed:
        intent.state = .cancelling
        intent.updatedAt = Date()
        try writeRemoteOutboxIntent(intent, goalStore: goalStore)
      case .cancelling:
        break
      }
      let outcome = try channel.signalCancel(for: intent.job)
      switch outcome {
      case .cancelled, .terminalWon(.cancelled):
        intent.state = .cancelled
        try projectRemoteCancellationIfReserved(
          intent: intent,
          dispatchRegistry: dispatchRegistry)
      case .terminalWon:
        // A durable terminal channel state wins; cancellation cannot regress it.
        intent.state = .committed
      }
      intent.updatedAt = Date()
      try writeRemoteOutboxIntent(intent, goalStore: goalStore)
      return intent
    }
  }

  private static func projectRemoteCancellationIfReserved(
    intent: TatwoRemoteOutboxIntentV1,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws {
    guard
      try dispatchRegistry.run(forContractID: intent.job.contractID)?
        .records.contains(where: { $0.remoteJobID == intent.job.jobID }) == true
    else {
      return
    }
    _ = try dispatchRegistry.projectRemoteStatus(
      contractID: intent.job.contractID,
      remoteJobID: intent.job.jobID,
      remoteStatus: .cancelled,
      failureCode: "cancelled",
      errorMessage: "origin cancellation tombstone")
  }

  /// Fail-closed quarantine after channel commit fails post-reservation.
  ///
  /// Marks the remote registry row failed and GoalRun blocked with
  /// `reconciliation_required:channel_enqueue:` so later prepare gates refuse dispatch.
  /// Errors are never swallowed with `try?`.
  public static func quarantineChannelEnqueueFailure(
    job: TatwoLoopJobV1,
    error: Error,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws {
    try withLifecycleLock(contractID: job.contractID, goalStore: goalStore) {
      _ = try requireCurrentRevision(
        contractID: job.contractID,
        goalStore: goalStore)
      let primary = error.localizedDescription
      var cleanupErrors: [String] = []

      do {
        _ = try dispatchRegistry.projectRemoteStatus(
          contractID: job.contractID,
          remoteJobID: job.jobID,
          remoteStatus: .failed,
          failureCode: "channel_enqueue_failed",
          errorMessage: "reconciliation_required:channel_enqueue:\(primary)")
      } catch {
        cleanupErrors.append("registry=\(error)")
      }

      do {
        let issued = try goalStore.requireIssuedContract(job.contractID)
        switch issued.status {
        case .planned, .dispatching, .running:
          _ = try goalStore.updateStatus(
            contractID: job.contractID,
            status: .blocked,
            authority: .dispatchFailure,
            reason: "reconciliation_required:channel_enqueue:\(job.jobID)",
            evidence: .reconciliation(stage: "channel_enqueue"))
        case .blocked:
          if issued.statusReason?.hasPrefix("reconciliation_required:") != true {
            // Already blocked for another reason — still pin reconciliation on this job.
            _ = try goalStore.updateStatus(
              contractID: job.contractID,
              status: .blocked,
              authority: .dispatchFailure,
              reason: "reconciliation_required:channel_enqueue:\(job.jobID)",
              evidence: .reconciliation(stage: "channel_enqueue"))
          }
        case .succeeded, .failed, .cancelled, .humanGate, .awaitingNextCycle,
          .passed, .rollbackRequired, .superseded:
          break
        }
      } catch {
        cleanupErrors.append("goal=\(error)")
      }

      if !cleanupErrors.isEmpty {
        throw TatwoGoalRunDispatchLifecycleError.reconciliationFailed(
          stage: "channel_enqueue",
          primary: primary,
          cleanup: cleanupErrors.joined(separator: "; "))
      }
    }
  }
}
