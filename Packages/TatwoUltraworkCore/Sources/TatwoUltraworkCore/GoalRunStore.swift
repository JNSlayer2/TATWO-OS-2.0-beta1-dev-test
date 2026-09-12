import CryptoKit
import Foundation

/// Phase 0 persistence spine.
///
/// Before this store existed, `WorkOSFactory.begin/submitReceipt/closeGoal` were
/// stateless: every call re-derived an identical contract from `mode|scenario|objective`,
/// nothing was recorded, and `closeGoal` reconciled caller-supplied receipt-ID strings.
/// That made three fail-closed promises cosmetic: contractID authenticity, "model text is
/// not a receipt", and receipt completeness at close.
///
/// This store turns those promises into store-verified state:
/// - `recordBegin` registers the contractID the factory issued (the missing issuance registry).
/// - `appendReceipt` journals each submitted receipt (submission becomes state, not a return-value echo).
/// - `submittedReceiptIDs` lets `closeGoal` reconcile against what was actually submitted,
///   not against strings the caller hands back.
///
/// It is **additive and opt-in**: `WorkOSFactory` falls back to the legacy stateless path
/// when no store is injected, so existing callers and tests are byte-for-byte unchanged.
/// Cross-process file locking (App/CLI/MCP concurrent access) is deferred to a later phase;
/// writes are `.atomic` like `TatwoPreferenceStore`.
public struct TatwoStoredReceipt: Codable, Sendable, Equatable {
  public let schema: String
  public let receiptID: String
  public let kind: String
  public let loopID: String?
  public let submittedAt: Date
  public let authorizationBindingArtifactSHA256: String?
  /// The exact Work OS requirement this evidence satisfies.
  ///
  /// Legacy/manual receipts used the requirement ID as `receiptID`. M4b keeps
  /// that path intact while allowing a real artifact/dispatch receipt ID to
  /// remain the evidence reference instead of being renamed to a requirement.
  public let satisfiesRequirementID: String?

  public init(
    schema: String = "TatwoStoredReceiptV1",
    receiptID: String,
    kind: String,
    loopID: String? = nil,
    submittedAt: Date = Date(),
    authorizationBindingArtifactSHA256: String? = nil,
    satisfiesRequirementID: String? = nil
  ) {
    self.schema = schema
    self.receiptID = receiptID
    self.kind = kind
    self.loopID = loopID
    self.submittedAt = submittedAt
    self.authorizationBindingArtifactSHA256 = authorizationBindingArtifactSHA256
    self.satisfiesRequirementID = satisfiesRequirementID
  }
}

public struct TatwoGoalRevisionSupersessionMetadataV1: Codable, Sendable, Equatable {
  public let schema: String
  public let predecessorContractID: String
  public let predecessorGoalID: String
  public let predecessorRevision: UInt64
  public let successorContractID: String
  public let successorGoalID: String
  public let successorRevision: UInt64
  public let promotionAuthorizationID: String
  public let humanGateReceiptID: String
  public let supersessionReceiptID: String
  public let oldPointerRevisionDigest: String
  public let oldPointerGeneration: UInt64
  public let oldObjectiveDigest: String
  public let newObjectiveDigest: String
  public let topologyDigest: String
  public let capabilityDigest: String
  public let requestedHostScopeDigest: String
  public let promotionIssuerDomain: String?
  public let oldReceiptsDigest: String?
  public let oldActivationEpoch: UInt64?
  public let bootstrapRecoveryContextDigest: String?
  public let supersededAt: Date

  public init(
    schema: String = "TatwoGoalRevisionSupersessionMetadataV1",
    predecessorContractID: String,
    predecessorGoalID: String,
    predecessorRevision: UInt64,
    successorContractID: String,
    successorGoalID: String,
    successorRevision: UInt64,
    promotionAuthorizationID: String,
    humanGateReceiptID: String,
    supersessionReceiptID: String,
    oldPointerRevisionDigest: String,
    oldPointerGeneration: UInt64,
    oldObjectiveDigest: String,
    newObjectiveDigest: String,
    topologyDigest: String,
    capabilityDigest: String,
    requestedHostScopeDigest: String,
    supersededAt: Date,
    promotionIssuerDomain: String? = nil,
    oldReceiptsDigest: String? = nil,
    oldActivationEpoch: UInt64? = nil,
    bootstrapRecoveryContextDigest: String? = nil
  ) {
    self.schema = schema
    self.predecessorContractID = predecessorContractID
    self.predecessorGoalID = predecessorGoalID
    self.predecessorRevision = predecessorRevision
    self.successorContractID = successorContractID
    self.successorGoalID = successorGoalID
    self.successorRevision = successorRevision
    self.promotionAuthorizationID = promotionAuthorizationID
    self.humanGateReceiptID = humanGateReceiptID
    self.supersessionReceiptID = supersessionReceiptID
    self.oldPointerRevisionDigest = oldPointerRevisionDigest
    self.oldPointerGeneration = oldPointerGeneration
    self.oldObjectiveDigest = oldObjectiveDigest
    self.newObjectiveDigest = newObjectiveDigest
    self.topologyDigest = topologyDigest
    self.capabilityDigest = capabilityDigest
    self.requestedHostScopeDigest = requestedHostScopeDigest
    self.promotionIssuerDomain = promotionIssuerDomain
    self.oldReceiptsDigest = oldReceiptsDigest
    self.oldActivationEpoch = oldActivationEpoch
    self.bootstrapRecoveryContextDigest = bootstrapRecoveryContextDigest
    self.supersededAt = supersededAt
  }
}

/// Canonical identity-routing fact captured at contract issuance.
///
/// Contract IDs intentionally remain compatible with the original
/// `mode|scenario|objective` identity. This snapshot closes the resulting gap:
/// later projections may consult a newer scenario book, but dispatch can only
/// proceed when the rebuilt identity routing still matches these issued facts.
public struct TatwoIssuedIdentityBindingV1: Codable, Sendable, Equatable {
  public let id: String
  public let sourceSlotID: String
  public let identity: IdentityKind
  public let modelID: String?
  public let authority: AuthorityMode
  public let engineID: EngineID?
  public let reasoningEffort: TatwoCodexReasoningEffort?
  public let canMutateHost: Bool

  public init(
    id: String,
    sourceSlotID: String,
    identity: IdentityKind,
    modelID: String?,
    authority: AuthorityMode,
    engineID: EngineID?,
    reasoningEffort: TatwoCodexReasoningEffort?,
    canMutateHost: Bool
  ) {
    self.id = id
    self.sourceSlotID = sourceSlotID
    self.identity = identity
    self.modelID = modelID
    self.authority = authority
    self.engineID = engineID
    self.reasoningEffort = reasoningEffort
    self.canMutateHost = canMutateHost
  }

  public static func canonicalSnapshot(
    for contract: TatwoWorkOSContractV1
  ) -> [TatwoIssuedIdentityBindingV1] {
    let issued = contract.identityBindings.map { binding in
      let effort = contract.loopGovernorDecision.activatedBindings.first { configured in
        guard configured.id == binding.sourceSlotID else { return false }
        guard let modelID = binding.modelID else { return configured.boundModelIDs.isEmpty }
        let normalizedModelID = TatwoGatewayDispatchCatalog.normalize(modelID)
        return configured.boundModelIDs.contains {
          TatwoGatewayDispatchCatalog.normalize($0) == normalizedModelID
        }
      }?.reasoningEffort
      return TatwoIssuedIdentityBindingV1(
        id: binding.id,
        sourceSlotID: binding.sourceSlotID,
        identity: binding.identity,
        modelID: binding.modelID,
        authority: binding.authority,
        engineID: binding.engineID,
        reasoningEffort: effort,
        canMutateHost: binding.canMutateHost)
    }
    return canonicalized(issued)
  }

  /// Order-independent digest of the canonical semantic fields.
  public static func deterministicDigest(
    for bindings: [TatwoIssuedIdentityBindingV1]
  ) -> String {
    var stream = "TatwoIssuedIdentityBindingSnapshotV1"
    for binding in canonicalized(bindings) {
      for value in binding.canonicalFields {
        stream += "|\(value.utf8.count):\(value)"
      }
    }
    let digest = SHA256.hash(data: Data(stream.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }

  static func canonicalized(
    _ bindings: [TatwoIssuedIdentityBindingV1]
  ) -> [TatwoIssuedIdentityBindingV1] {
    bindings.sorted { lhs, rhs in
      lhs.canonicalFields.lexicographicallyPrecedes(rhs.canonicalFields)
    }
  }

  private var canonicalFields: [String] {
    [
      id,
      sourceSlotID,
      identity.rawValue,
      modelID.map { "some:\($0)" } ?? "none",
      authority.rawValue,
      engineID.map { "some:\($0.rawValue)" } ?? "none",
      reasoningEffort.map { "some:\($0.rawValue)" } ?? "none",
      String(canMutateHost),
    ]
  }
}

/// Temporary compatibility policy for contracts issued before the native
/// development Sol/Opus lanes acquired host-mutation bridge authority.
public enum TatwoLegacyNativeDevelopmentBindingUpgradePolicy {
  /// 2026-08-01 00:00:00 Asia/Taipei. Contracts issued at or after this
  /// instant must carry the current binding snapshot exactly.
  public static let grandfatheringCutoff = Date(
    timeIntervalSince1970: 1_785_513_600)

  public static func isGrandfathered(issuedAt: Date) -> Bool {
    issuedAt < grandfatheringCutoff
  }
}

public struct TatwoStoredGoalRun: Codable, Sendable, Equatable {
  static let dispatchSetFinalizedReasonPrefix = "dispatch_set_finalized:"
  static let dispatchCycleFinalizedReasonPrefix = "dispatch_cycle_finalized:"
  static let dispatchCycleOpenedReasonPrefix = "dispatch_cycle_opened:"

  public let schema: String
  public let goalID: String
  public let contractID: String
  public let mode: WorkModeID
  public let scenario: String
  public let objective: String
  public let routeBindingOverride: WorkOSRouteBindingOverride?
  public let authorityInstanceDiscriminator: String?
  public let issuedIdentityBindings: [TatwoIssuedIdentityBindingV1]?
  public let issuedIdentityBindingsDigest: String?
  public var status: GoalRunStatus
  public var statusReason: String?
  /// Latest immutable dispatch-cycle boundary. These survive Goal Judge
  /// diagnostics so a blocked Goal can safely continue from the exact seal.
  public var latestDispatchCycleEpoch: UInt64?
  public var latestDispatchCycleSealID: String?
  public let issuedAt: Date
  public var updatedAt: Date
  public var receipts: [TatwoStoredReceipt]
  public let recoversGoalID: String?
  public let recoversContractID: String?
  public let recoveryReceiptHash: String?
  public let recoveryAuthorizationHash: String?
  public let recoveryReason: String?
  public let recoveryAdjudicationRef: String?
  /// Goal revision lineage. Legacy records decode with `nil` and are treated as
  /// revision 1 until the first explicit revision transition persists them.
  public var revision: UInt64?
  public var predecessorContractID: String?
  public var predecessorGoalID: String?
  public var successorContractID: String?
  public var successorGoalID: String?
  public var supersession: TatwoGoalRevisionSupersessionMetadataV1?

  public init(
    schema: String = "TatwoStoredGoalRunV1",
    goalID: String,
    contractID: String,
    mode: WorkModeID,
    scenario: String,
    objective: String,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    authorityInstanceDiscriminator: String? = nil,
    issuedIdentityBindings: [TatwoIssuedIdentityBindingV1]? = nil,
    issuedIdentityBindingsDigest: String? = nil,
    status: GoalRunStatus,
    statusReason: String? = nil,
    latestDispatchCycleEpoch: UInt64? = nil,
    latestDispatchCycleSealID: String? = nil,
    issuedAt: Date = Date(),
    updatedAt: Date = Date(),
    receipts: [TatwoStoredReceipt] = [],
    recoversGoalID: String? = nil,
    recoversContractID: String? = nil,
    recoveryReceiptHash: String? = nil,
    recoveryAuthorizationHash: String? = nil,
    recoveryReason: String? = nil,
    recoveryAdjudicationRef: String? = nil,
    revision: UInt64? = nil,
    predecessorContractID: String? = nil,
    predecessorGoalID: String? = nil,
    successorContractID: String? = nil,
    successorGoalID: String? = nil,
    supersession: TatwoGoalRevisionSupersessionMetadataV1? = nil
  ) {
    self.schema = schema
    self.goalID = goalID
    self.contractID = contractID
    self.mode = mode
    self.scenario = scenario
    self.objective = objective
    self.routeBindingOverride = routeBindingOverride
    self.authorityInstanceDiscriminator = authorityInstanceDiscriminator
    self.issuedIdentityBindings = issuedIdentityBindings
    self.issuedIdentityBindingsDigest = issuedIdentityBindingsDigest
    self.status = status
    self.statusReason = statusReason
    self.latestDispatchCycleEpoch = latestDispatchCycleEpoch
    self.latestDispatchCycleSealID = latestDispatchCycleSealID
    self.issuedAt = issuedAt
    self.updatedAt = updatedAt
    self.receipts = receipts
    self.recoversGoalID = recoversGoalID
    self.recoversContractID = recoversContractID
    self.recoveryReceiptHash = recoveryReceiptHash
    self.recoveryAuthorizationHash = recoveryAuthorizationHash
    self.recoveryReason = recoveryReason
    self.recoveryAdjudicationRef = recoveryAdjudicationRef
    self.revision = revision
    self.predecessorContractID = predecessorContractID
    self.predecessorGoalID = predecessorGoalID
    self.successorContractID = successorContractID
    self.successorGoalID = successorGoalID
    self.supersession = supersession
  }

  public var resolvedRevision: UInt64 { revision ?? 1 }

  public var submittedReceiptIDs: Set<String> {
    Set(receipts.map(\.receiptID))
  }

  /// Requirement satisfaction remains fail-closed:
  /// - legacy receipts satisfy only an exact matching receipt ID;
  /// - evidence-referenced receipts satisfy only their explicitly journaled,
  ///   contract-validated requirement binding.
  public var satisfiedReceiptRequirementIDs: Set<String> {
    Set(receipts.map { receipt in
      receipt.satisfiesRequirementID ?? receipt.receiptID
    })
  }

  var hasDispatchSetFinalizationReason: Bool {
    statusReason?.hasPrefix(Self.dispatchSetFinalizedReasonPrefix) == true
  }

  var hasDispatchCycleFinalizationReason: Bool {
    statusReason?.hasPrefix(Self.dispatchCycleFinalizedReasonPrefix) == true
  }

  var isResumableDispatchCycleBoundary: Bool {
    if status == .awaitingNextCycle, hasDispatchCycleFinalizationReason {
      return true
    }
    if [.humanGate, .succeeded].contains(status), hasDispatchSetFinalizationReason {
      return true
    }
    return status == .blocked
      && statusReason?.hasPrefix("receipt_incomplete") == true
      && latestDispatchCycleSealID != nil
  }

  var isAttachableAwaitingJudgment: Bool {
    status == .awaitingNextCycle
      || status == .humanGate
      || status == .succeeded
  }
}

public struct TatwoGoalRunBeginDisposition: Sendable, Equatable {
  public let record: TatwoStoredGoalRun
  public let created: Bool
  fileprivate let persistedRevision: Data?

  public init(record: TatwoStoredGoalRun, created: Bool) {
    self.record = record
    self.created = created
    persistedRevision = nil
  }

  fileprivate init(
    record: TatwoStoredGoalRun,
    created: Bool,
    persistedRevision: Data
  ) {
    self.record = record
    self.created = created
    self.persistedRevision = persistedRevision
  }
}

public enum TatwoGoalCandidateCreateOnlyDispositionKindV1: String, Codable, Sendable, Equatable {
  case created
}

/// Exact result of the strict candidate-only persistence boundary.
///
/// Unlike `recordBeginWithDisposition`, this operation never refreshes an
/// existing deterministic ID and intentionally exposes no rollback token.
public struct TatwoGoalCandidateCreateOnlyStoreDispositionV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let disposition: TatwoGoalCandidateCreateOnlyDispositionKindV1
  public let record: TatwoStoredGoalRun
  public let persistedBytesSHA256: String

  public init(
    schema: String = "TatwoGoalCandidateCreateOnlyStoreDispositionV1",
    disposition: TatwoGoalCandidateCreateOnlyDispositionKindV1,
    record: TatwoStoredGoalRun,
    persistedBytesSHA256: String
  ) {
    self.schema = schema
    self.disposition = disposition
    self.record = record
    self.persistedBytesSHA256 = persistedBytesSHA256
  }
}

/// Read-only evidence captured before the create-only candidate lock boundary.
///
/// This preflight never creates the Goal directory, candidate file, or sibling
/// lock. The create-only writer repeats target absence under its lock.
public struct TatwoGoalCandidateStorePreflightV1: Codable, Sendable, Equatable {
  public let schema: String
  public let storeSchema: String
  public let contractID: String
  public let stateRootPath: String
  public let targetJSONPath: String
  public let targetLockPath: String
  public let targetJSONAbsent: Bool
  public let targetLockAbsent: Bool
  public let targetAbsent: Bool
  public let canonicalManifestSHA256: String

  public init(
    schema: String = "TatwoGoalCandidateStorePreflightV1",
    storeSchema: String = "TatwoGoalRunStoreV1",
    contractID: String,
    stateRootPath: String,
    targetJSONPath: String,
    targetLockPath: String,
    targetJSONAbsent: Bool,
    targetLockAbsent: Bool,
    canonicalManifestSHA256: String
  ) {
    self.schema = schema
    self.storeSchema = storeSchema
    self.contractID = contractID
    self.stateRootPath = stateRootPath
    self.targetJSONPath = targetJSONPath
    self.targetLockPath = targetLockPath
    self.targetJSONAbsent = targetJSONAbsent
    self.targetLockAbsent = targetLockAbsent
    targetAbsent = targetJSONAbsent && targetLockAbsent
    self.canonicalManifestSHA256 = canonicalManifestSHA256
  }
}

/// One decoded GoalRun plus the exact persisted bytes it was decoded from.
///
/// Consumers may project UI state from `record`, then use `verifyCurrent` before
/// publishing that projection. The revision token intentionally remains opaque:
/// semantic equality is insufficient because another writer may have replaced
/// the JSON with a different durable revision that decodes to the same values.
public struct TatwoGoalRunSnapshotV1: Sendable, Equatable {
  public let record: TatwoStoredGoalRun
  fileprivate let persistedRevision: Data

  fileprivate init(record: TatwoStoredGoalRun, persistedRevision: Data) {
    self.record = record
    self.persistedRevision = persistedRevision
  }

  /// Opaque evidence for cross-file recovery journals. The raw persisted bytes
  /// remain private to the store; callers can only retain their deterministic digest.
  var persistedRevisionDigest: String {
    let digest = SHA256.hash(data: persistedRevision)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }
}

public enum TatwoGoalRunStoreError: Error, LocalizedError, Sendable, Equatable {
  /// A submit/close/next arrived with a contractID that `begin` never issued into this store.
  case unregisteredContract(String)
  /// A stored contractID could not be turned into a safe on-disk filename.
  case invalidContractID(String)
  /// A caller attempted to bypass the OS-owned GoalRun lifecycle.
  case illegalStatusTransition(from: GoalRunStatus, to: GoalRunStatus, authority: String)
  case recoveryRequiresFailedOrigin(status: GoalRunStatus)
  case invalidRecoveryAuthorization
  case terminalGoalRunImmutable(status: GoalRunStatus)
  case staleGoalRevision(String)
  case issuedIdentityBindingsUnavailable(String)
  case issuedIdentityBindingsDigestMismatch(String)
  case issuedIdentityBindingsMismatch(String)
  case staleGoalRunSnapshot(String)
  case staleDispatchCycleBoundary(expected: String, actual: String)
  case goalCandidateAlreadyExists(String)
  case goalCandidateRequiresPlanned(status: GoalRunStatus)
  case goalCandidateRequiresGoalTracker(String)
  case goalCandidatePersistenceMissing(String)
  case goalCandidateStorePreflightStale(String)
  case goalCandidateStorePreflightReadFailed(String)
  case dispatchRetryExhaustionRunMissing(contractID: String)
  case dispatchRetryExhaustionRunUnreadable(contractID: String)
  case dispatchRetryExhaustionRunContractMismatch(expected: String, actual: String)
  case dispatchRetryExhaustionDispatchMatchCount(
    contractID: String,
    dispatchID: String,
    count: Int)
  case dispatchRetryExhaustionDispatchContractMismatch(expected: String, actual: String)
  case dispatchRetryExhaustionDispatchNotFailed(status: TatwoDispatchStatus)
  case dispatchRetryExhaustionFailureNotRetryable(
    failureClass: TatwoDispatchFailureClass?)
  case dispatchRetryAttemptCapBelowSettlementFloor(requested: Int, floor: Int)
  case dispatchRetryExhaustionAttemptBelowCap(attempt: Int, cap: Int)
  case dispatchRetryExhaustionCycleMismatch(expected: UInt64, actual: UInt64)
  case dispatchRetryExhaustionLiveSupersedingDispatch(
    dispatchID: String,
    supersedingDispatchID: String)
  case dispatchRetryExhaustionReasonMismatch(expected: String, actual: String?)
  case dispatchRetryExhaustionReadbackMismatch(contractID: String)
  case dispatchRetryExhaustionRollbackFailed(contractID: String)

  public var errorDescription: String? {
    switch self {
    case .unregisteredContract(let id):
      return "Unregistered contractID: \(id) was never issued by tatwo.os.begin into this store."
    case .invalidContractID(let id):
      return "Invalid contractID for storage: \(id)"
    case .illegalStatusTransition(let from, let to, let authority):
      return "Illegal GoalRun transition \(from.rawValue) -> \(to.rawValue) for authority \(authority)."
    case .recoveryRequiresFailedOrigin(let status):
      return "Recovery requires a terminal failed GoalRun; origin is \(status.rawValue)."
    case .invalidRecoveryAuthorization:
      return "Recovery requires an explicit non-empty human or orchestrator authorization token."
    case .terminalGoalRunImmutable(let status):
      return "Terminal GoalRun \(status.rawValue) is immutable; create a recovery GoalRun instead."
    case .staleGoalRevision(let id):
      return "stale_goal_revision:\(id)"
    case .issuedIdentityBindingsUnavailable(let id):
      return "Contract \(id) is a legacy GoalRun without an issued identity-binding snapshot; strict dispatch must fail closed."
    case .issuedIdentityBindingsDigestMismatch(let id):
      return "Contract \(id) has an invalid issued identity-binding digest; stored routing evidence is not trustworthy."
    case .issuedIdentityBindingsMismatch(let id):
      return "Contract \(id) identity bindings differ from the canonical bindings captured at issuance; scenario configuration drift is blocked."
    case .staleGoalRunSnapshot(let id):
      return "GoalRun \(id) changed after its exact persisted snapshot was captured."
    case let .staleDispatchCycleBoundary(expected, actual):
      return "Stale GoalRun dispatch cycle boundary: expected \(expected), latest is \(actual)."
    case .goalCandidateAlreadyExists(let id):
      return "goal_candidate_already_exists:\(id)"
    case .goalCandidateRequiresPlanned(let status):
      return "goal_candidate_requires_planned:\(status.rawValue)"
    case .goalCandidateRequiresGoalTracker(let id):
      return "goal_candidate_requires_goal_tracker:\(id)"
    case .goalCandidatePersistenceMissing(let id):
      return "goal_candidate_persistence_missing:\(id)"
    case .goalCandidateStorePreflightStale(let id):
      return "goal_candidate_store_preflight_stale:\(id)"
    case .goalCandidateStorePreflightReadFailed(let reason):
      return "goal_candidate_store_preflight_read_failed:\(reason)"
    case .dispatchRetryExhaustionRunMissing(let contractID):
      return "dispatch_retry_exhaustion_run_missing:\(contractID)"
    case .dispatchRetryExhaustionRunUnreadable(let contractID):
      return "dispatch_retry_exhaustion_run_unreadable:\(contractID)"
    case let .dispatchRetryExhaustionRunContractMismatch(expected, actual):
      return
        "dispatch_retry_exhaustion_run_contract_mismatch:"
        + "expected=\(expected):actual=\(actual)"
    case let .dispatchRetryExhaustionDispatchMatchCount(
      contractID,
      dispatchID,
      count):
      return
        "dispatch_retry_exhaustion_dispatch_match_count:"
        + "contract=\(contractID):dispatch=\(dispatchID):count=\(count)"
    case let .dispatchRetryExhaustionDispatchContractMismatch(expected, actual):
      return
        "dispatch_retry_exhaustion_dispatch_contract_mismatch:"
        + "expected=\(expected):actual=\(actual)"
    case .dispatchRetryExhaustionDispatchNotFailed(let status):
      return "dispatch_retry_exhaustion_dispatch_not_failed:\(status.rawValue)"
    case .dispatchRetryExhaustionFailureNotRetryable(let failureClass):
      return
        "dispatch_retry_exhaustion_failure_not_retryable:"
        + (failureClass?.rawValue ?? "missing")
    case let .dispatchRetryAttemptCapBelowSettlementFloor(requested, floor):
      return
        "dispatch_retry_attempt_cap_below_settlement_floor:"
        + "requested=\(requested):floor=\(floor)"
    case let .dispatchRetryExhaustionAttemptBelowCap(attempt, cap):
      return
        "dispatch_retry_exhaustion_attempt_below_cap:"
        + "attempt=\(attempt):cap=\(cap)"
    case let .dispatchRetryExhaustionCycleMismatch(expected, actual):
      return
        "dispatch_retry_exhaustion_cycle_mismatch:"
        + "expected=\(expected):actual=\(actual)"
    case let .dispatchRetryExhaustionLiveSupersedingDispatch(
      dispatchID,
      supersedingDispatchID):
      return
        "dispatch_retry_exhaustion_live_superseding_dispatch:"
        + "dispatch=\(dispatchID):superseding=\(supersedingDispatchID)"
    case let .dispatchRetryExhaustionReasonMismatch(expected, actual):
      return
        "dispatch_retry_exhaustion_reason_mismatch:"
        + "expected=\(expected):actual=\(actual ?? "missing")"
    case .dispatchRetryExhaustionReadbackMismatch(let contractID):
      return "dispatch_retry_exhaustion_readback_mismatch:\(contractID)"
    case .dispatchRetryExhaustionRollbackFailed(let contractID):
      return "dispatch_retry_exhaustion_rollback_failed:\(contractID)"
    }
  }
}

enum TatwoGoalRunTransitionAuthority: String, Sendable, Equatable {
  case caller
  case ledgerBeginAck = "ledger_begin_ack"
  case cooldownFence = "cooldown_fence"
  case dispatchFailure = "dispatch_failure"
  case dispatchRetry = "dispatch_retry"
  case dispatchRetryExhaustion = "dispatch_retry_exhaustion"
  case dispatchCycleAdvance = "dispatch_cycle_advance"
  case plannedSupersede = "planned_supersede"
  case goalClose = "goal_close"
  case revisionPromotion = "revision_promotion"
}

enum TatwoGoalRunTransitionEvidence: Sendable, Equatable {
  case ledger(dispatchID: String)
  case retry(supersedes: String)
  case failure(dispatchID: String)
  case retryExhaustion(dispatchID: String)
  case reconciliation(stage: String)
}

public struct TatwoGoalRunStore: Sendable {
  /// Store-owned retry policy. Callers may observe this value but cannot lower
  /// the terminal-settlement threshold per invocation.
  public static let dispatchRetryAttemptCap = 2

  public let directoryURL: URL
  private let candidateLockedPreflightHook: (@Sendable () throws -> Void)?
  private let dispatchRetryExhaustionPostWriteHook: (@Sendable () throws -> Void)?
  private let dispatchRetryExhaustionRollbackReadbackHook:
    (@Sendable () throws -> Void)?

  public init(directoryURL: URL) {
    self.directoryURL = Self.canonicalStateRootIfKnownLegacy(directoryURL)
    candidateLockedPreflightHook = nil
    dispatchRetryExhaustionPostWriteHook = nil
    dispatchRetryExhaustionRollbackReadbackHook = nil
  }

  /// Deterministic test seam for exercising a store drift that lands after the
  /// outer authorization preflight and after the target lock is acquired, but
  /// before the final manifest revalidation. Production stores never set it.
  init(
    directoryURL: URL,
    candidateLockedPreflightHook: @escaping @Sendable () throws -> Void
  ) {
    self.directoryURL = Self.canonicalStateRootIfKnownLegacy(directoryURL)
    self.candidateLockedPreflightHook = candidateLockedPreflightHook
    dispatchRetryExhaustionPostWriteHook = nil
    dispatchRetryExhaustionRollbackReadbackHook = nil
  }

  /// Deterministic test seam for forcing a post-write readback mismatch while
  /// the GoalRun lock remains held. Production stores never set it.
  init(
    directoryURL: URL,
    dispatchRetryExhaustionPostWriteHook: @escaping @Sendable () throws -> Void,
    dispatchRetryExhaustionRollbackReadbackHook:
      (@Sendable () throws -> Void)? = nil
  ) {
    self.directoryURL = Self.canonicalStateRootIfKnownLegacy(directoryURL)
    candidateLockedPreflightHook = nil
    self.dispatchRetryExhaustionPostWriteHook =
      dispatchRetryExhaustionPostWriteHook
    self.dispatchRetryExhaustionRollbackReadbackHook =
      dispatchRetryExhaustionRollbackReadbackHook
  }

  /// Validates a caller-selected retry ceiling against the store-owned
  /// settlement floor. Product callers may explicitly choose a larger ceiling
  /// (for example 3), but cannot terminate a logical dispatch before the store
  /// would authorize retry-exhaustion settlement.
  @discardableResult
  public static func validatedDispatchRetryAttemptCap(
    _ requested: Int
  ) throws -> Int {
    guard requested >= dispatchRetryAttemptCap else {
      throw TatwoGoalRunStoreError
        .dispatchRetryAttemptCapBelowSettlementFloor(
          requested: requested,
          floor: dispatchRetryAttemptCap)
    }
    return requested
  }

  // MARK: Registry

  /// Record (or idempotently refresh) the goal run a `begin` call issued.
  /// Re-recording the same contractID preserves already-journaled receipts and `issuedAt`.
  @discardableResult
  public func recordBegin(contract: TatwoWorkOSContractV1) throws -> TatwoStoredGoalRun {
    try recordBeginWithDisposition(contract: contract).record
  }

  /// Same issuance boundary as `recordBegin`, with an exact creation disposition
  /// for callers that must compensate an unpublished GoalRun if current-session
  /// publication fails.
  public func recordBeginWithDisposition(
    contract: TatwoWorkOSContractV1
  ) throws -> TatwoGoalRunBeginDisposition {
    let url = try fileURL(forContractID: contract.contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      let now = Date()
      if var existing = try readRecord(at: url) {
        guard !Self.isImmutableTerminal(existing.status) else {
          throw TatwoGoalRunStoreError.terminalGoalRunImmutable(status: existing.status)
        }
        if existing.issuedIdentityBindings != nil
          || existing.issuedIdentityBindingsDigest != nil
        {
          let issued = try validatedIssuedIdentityBindings(existing)
          let incoming = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
          guard issued == incoming else {
            throw TatwoGoalRunStoreError.issuedIdentityBindingsMismatch(contract.contractID)
          }
        }
        ensureActivationReceipts(for: contract, in: &existing, now: now)
        existing.updatedAt = now
        try write(existing)
        return TatwoGoalRunBeginDisposition(
          record: existing,
          created: false,
          persistedRevision: try Data(contentsOf: url))
      }
      let issuedIdentityBindings = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
      let record = TatwoStoredGoalRun(
        goalID: contract.goalID,
        contractID: contract.contractID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective,
        routeBindingOverride: contract.routeBindingOverride,
        authorityInstanceDiscriminator: contract.authorityInstanceDiscriminator,
        issuedIdentityBindings: issuedIdentityBindings,
        issuedIdentityBindingsDigest: TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: issuedIdentityBindings),
        status: contract.goalRun.status,
        issuedAt: now,
        updatedAt: now,
        receipts: [])
      var seededRecord = record
      ensureActivationReceipts(for: contract, in: &seededRecord, now: now)
      try write(seededRecord)
      return TatwoGoalRunBeginDisposition(
        record: seededRecord,
        created: true,
        persistedRevision: try Data(contentsOf: url))
    }
  }

  /// Persist exactly one fresh planned Goal candidate and stop.
  ///
  /// This route is deliberately narrower than `recordBegin`: a deterministic-ID
  /// collision is an error, not an idempotent refresh. The preflight collision
  /// check avoids even creating a sibling lock file for an already-existing
  /// record; the check is repeated under the per-record lock before a
  /// create-only durable write closes the race with non-cooperating
  /// writers. No rollback/delete capability is returned.
  public func createCandidateOnly(
    contract: TatwoWorkOSContractV1,
    authorizationBindingArtifactSHA256: String,
    expectedPreflight: TatwoGoalCandidateStorePreflightV1
  ) throws -> TatwoGoalCandidateCreateOnlyStoreDispositionV1 {
    guard contract.goalRun.status == .planned else {
      throw TatwoGoalRunStoreError.goalCandidateRequiresPlanned(
        status: contract.goalRun.status)
    }
    let url = try fileURL(forContractID: contract.contractID)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoGoalRunStoreError.goalCandidateAlreadyExists(contract.contractID)
    }

    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard !FileManager.default.fileExists(atPath: url.path) else {
        throw TatwoGoalRunStoreError.goalCandidateAlreadyExists(contract.contractID)
      }
      let lockURL = url.appendingPathExtension("lock")
      guard expectedPreflight.contractID == contract.contractID,
        expectedPreflight.storeSchema == "TatwoGoalRunStoreV1",
        expectedPreflight.targetJSONPath == url.standardizedFileURL.path,
        expectedPreflight.targetLockPath == lockURL.standardizedFileURL.path,
        expectedPreflight.targetJSONAbsent,
        expectedPreflight.targetLockAbsent,
        expectedPreflight.targetAbsent
      else {
        throw TatwoGoalRunStoreError.goalCandidateStorePreflightStale(
          contract.contractID)
      }
      try candidateLockedPreflightHook?()
      let lockedManifestSHA256 = try candidateStoreCanonicalManifestSHA256(
        goalStoreRoot: url.deletingLastPathComponent().standardizedFileURL,
        targetJSONPath: url.standardizedFileURL.path,
        targetLockPath: lockURL.standardizedFileURL.path,
        ignoredPaths: [lockURL.standardizedFileURL.path])
      guard lockedManifestSHA256 == expectedPreflight.canonicalManifestSHA256 else {
        throw TatwoGoalRunStoreError.goalCandidateStorePreflightStale(
          contract.contractID)
      }
      let now = Date()
      let issuedIdentityBindings = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
      var record = TatwoStoredGoalRun(
        goalID: contract.goalID,
        contractID: contract.contractID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective,
        routeBindingOverride: contract.routeBindingOverride,
        authorityInstanceDiscriminator: contract.authorityInstanceDiscriminator,
        issuedIdentityBindings: issuedIdentityBindings,
        issuedIdentityBindingsDigest: TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: issuedIdentityBindings),
        status: .planned,
        issuedAt: now,
        updatedAt: now,
        receipts: [])
      ensureActivationReceipts(
        for: contract,
        in: &record,
        now: now,
        authorizationBindingArtifactSHA256: authorizationBindingArtifactSHA256)
      guard record.receipts.count == 1,
        record.receipts.first?.receiptID == "goal-tracker",
        record.receipts.first?.kind == "goal_tracker",
        record.receipts.first?.authorizationBindingArtifactSHA256
          == authorizationBindingArtifactSHA256
      else {
        throw TatwoGoalRunStoreError.goalCandidateRequiresGoalTracker(
          contract.contractID)
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let encoded = try encoder.encode(record)
      try TatwoCreateOnlyFile.write(encoded, to: url) {
        throw TatwoGoalRunStoreError.goalCandidateAlreadyExists(contract.contractID)
      }
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw TatwoGoalRunStoreError.goalCandidatePersistenceMissing(contract.contractID)
      }
      let exactStoredBytes = try Data(contentsOf: url)
      let exactStoredRecord = try decodedRecord(from: exactStoredBytes)
      return TatwoGoalCandidateCreateOnlyStoreDispositionV1(
        disposition: .created,
        record: exactStoredRecord,
        persistedBytesSHA256: Self.sha256(exactStoredBytes))
    }
  }

  /// Remove only the exact, newly-created GoalRun that never became reachable
  /// from current-session. Any intervening receipt/status mutation changes the
  /// record and fails closed instead of deleting another writer's work.
  @discardableResult
  public func rollbackUnpublishedBegin(
    _ disposition: TatwoGoalRunBeginDisposition
  ) throws -> Bool {
    guard disposition.created,
      let persistedRevision = disposition.persistedRevision
    else { return false }
    let url = try fileURL(forContractID: disposition.record.contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard FileManager.default.fileExists(atPath: url.path) else { return true }
      guard try Data(contentsOf: url) == persistedRevision else { return false }
      try FileManager.default.removeItem(at: url)
      return true
    }
  }

  /// Creates a new append-only GoalRun for a failed origin. The original record is only read
  /// and hashed; it is never rewritten or transitioned back to a non-terminal state.
  @discardableResult
  public func createRecovery(
    originalContractID: String,
    authorizationToken: String,
    reason: String,
    adjudicationRef: String
  ) throws -> TatwoStoredGoalRun {
    let original = try requireIssuedContract(originalContractID)
    guard original.status == .failed else {
      throw TatwoGoalRunStoreError.recoveryRequiresFailedOrigin(status: original.status)
    }
    let normalizedAuthorization = authorizationToken
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedAuthorization.count >= 8 else {
      throw TatwoGoalRunStoreError.invalidRecoveryAuthorization
    }
    let originalURL = try fileURL(forContractID: originalContractID)
    let originalData = try Data(contentsOf: originalURL)
    let receiptHash = Self.sha256(originalData)
    let authorizationHash = Self.sha256(Data(normalizedAuthorization.utf8))
    let recoveryObjective = [
      original.objective,
      "Recovery of \(original.goalID)",
      String(receiptHash.suffix(12)),
    ].joined(separator: " | ")
    let contract = try WorkOSFactory.projectContract(
      mode: original.mode,
      scenarioProfileID: original.scenario,
      objective: recoveryObjective,
      routeBindingOverride: original.routeBindingOverride)
    let recoveryURL = try fileURL(forContractID: contract.contractID)
    return try TatwoFileLock.withExclusiveLock(for: recoveryURL) {
      if let existing = try record(forContractID: contract.contractID) {
        guard existing.recoversGoalID == original.goalID,
          existing.recoversContractID == original.contractID,
          existing.recoveryReceiptHash == receiptHash
        else {
          throw TatwoGoalRunStoreError.illegalStatusTransition(
            from: existing.status,
            to: .planned,
            authority: "recovery_collision")
        }
        return existing
      }
      let now = Date()
      let issuedIdentityBindings = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
      var recovery = TatwoStoredGoalRun(
        goalID: contract.goalID,
        contractID: contract.contractID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective,
        routeBindingOverride: contract.routeBindingOverride,
        authorityInstanceDiscriminator: contract.authorityInstanceDiscriminator,
        issuedIdentityBindings: issuedIdentityBindings,
        issuedIdentityBindingsDigest: TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: issuedIdentityBindings),
        status: .planned,
        statusReason: "recovery_created_for:\(original.goalID)",
        issuedAt: now,
        updatedAt: now,
        receipts: [
          TatwoStoredReceipt(
            receiptID: "recovery-origin-\(String(receiptHash.suffix(12)))",
            kind: "recovery_origin",
            loopID: contract.mainlineLoop.id,
            submittedAt: now)
        ],
        recoversGoalID: original.goalID,
        recoversContractID: original.contractID,
        recoveryReceiptHash: receiptHash,
        recoveryAuthorizationHash: authorizationHash,
        recoveryReason: Self.compactReason(reason),
        recoveryAdjudicationRef: Self.compactReason(adjudicationRef))
      ensureActivationReceipts(for: contract, in: &recovery, now: now)
      try write(recovery)
      return recovery
    }
  }

  /// Fan-out Work OS goals require visible goal tracker evidence at activation.
  /// `tatwo.os.begin` is the activation chokepoint, so the store seeds a deterministic
  /// receipt when the issued contract requires `goal-tracker`; this keeps the tracker
  /// duty out of prose and makes older/unseeded records detectable by `tatwo.os.next`.
  private func ensureActivationReceipts(
    for contract: TatwoWorkOSContractV1,
    in record: inout TatwoStoredGoalRun,
    now: Date,
    authorizationBindingArtifactSHA256: String? = nil
  ) {
    guard contract.receiptRequirements.contains(where: { $0.id == "goal-tracker" }) else { return }
    guard !record.receipts.contains(where: { $0.receiptID == "goal-tracker" }) else { return }
    record.receipts.append(
      TatwoStoredReceipt(
        receiptID: "goal-tracker",
        kind: "goal_tracker",
        loopID: contract.mainlineLoop.id,
        submittedAt: now,
        authorizationBindingArtifactSHA256: authorizationBindingArtifactSHA256))
  }

  public func preflightCandidateCreate(
    contractID: String
  ) throws -> TatwoGoalCandidateStorePreflightV1 {
    let url = try fileURL(forContractID: contractID)
    let lockURL = url.appendingPathExtension("lock")
    let root = url.deletingLastPathComponent().standardizedFileURL
    let targetJSONAbsent = !FileManager.default.fileExists(atPath: url.path)
    let targetLockAbsent = !FileManager.default.fileExists(atPath: lockURL.path)
    return TatwoGoalCandidateStorePreflightV1(
      contractID: contractID,
      stateRootPath: root.path,
      targetJSONPath: url.standardizedFileURL.path,
      targetLockPath: lockURL.standardizedFileURL.path,
      targetJSONAbsent: targetJSONAbsent,
      targetLockAbsent: targetLockAbsent,
      canonicalManifestSHA256: try candidateStoreCanonicalManifestSHA256(
        goalStoreRoot: root,
        targetJSONPath: url.standardizedFileURL.path,
        targetLockPath: lockURL.standardizedFileURL.path))
  }

  private func candidateStoreCanonicalManifestSHA256(
    goalStoreRoot: URL,
    targetJSONPath: String,
    targetLockPath: String,
    ignoredPaths: Set<String> = []
  ) throws -> String {
    let fileManager = FileManager.default
    var fields = [
      "TatwoGoalCandidateStoreCanonicalManifestV1",
      goalStoreRoot.path,
      targetJSONPath,
      targetLockPath,
    ]
    var enumerationError: Error?
    let rootExists = fileManager.fileExists(atPath: goalStoreRoot.path)
    if rootExists {
      guard let enumerator = fileManager.enumerator(
        at: goalStoreRoot,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { url, error in
          enumerationError = TatwoGoalRunStoreError
            .goalCandidateStorePreflightReadFailed(
              "\(url.lastPathComponent):\(error.localizedDescription)")
          return false
        })
      else {
        throw TatwoGoalRunStoreError.goalCandidateStorePreflightReadFailed(
          goalStoreRoot.lastPathComponent)
      }
      var entries: [(path: String, fields: [String])] = []
      for case let entryURL as URL in enumerator {
        let standardized = entryURL.standardizedFileURL
        if ignoredPaths.contains(standardized.path) {
          enumerator.skipDescendants()
          continue
        }
        let relativePath = String(
          standardized.path.dropFirst(goalStoreRoot.path.count)
        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let attributes = try fileManager.attributesOfItem(atPath: standardized.path)
        let fileType = (attributes[.type] as? FileAttributeType)?.rawValue ?? "unknown"
        let size = (attributes[.size] as? NSNumber)?.stringValue ?? "missing"
        let permissions =
          (attributes[.posixPermissions] as? NSNumber)?.stringValue ?? "missing"
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.stringValue ?? "missing"
        let group = (attributes[.groupOwnerAccountID] as? NSNumber)?.stringValue ?? "missing"
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "missing"
        let modified =
          (attributes[.modificationDate] as? Date)
          .map { String(format: "%.9f", $0.timeIntervalSince1970) } ?? "missing"
        let contentIdentity: String
        if (attributes[.type] as? FileAttributeType) == .typeRegular {
          contentIdentity = Self.sha256(try Data(contentsOf: standardized))
        } else if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
          contentIdentity =
            "symlink:\(try fileManager.destinationOfSymbolicLink(atPath: standardized.path))"
          enumerator.skipDescendants()
        } else {
          contentIdentity = "none"
        }
        entries.append(
          (
            relativePath,
            [
              relativePath,
              fileType,
              size,
              permissions,
              owner,
              group,
              inode,
              modified,
              contentIdentity,
            ]
          ))
      }
      for entry in entries.sorted(by: { $0.path < $1.path }) {
        fields.append(contentsOf: entry.fields)
      }
    }
    if let enumerationError {
      throw enumerationError
    }
    var stream = ""
    for field in fields {
      stream += "\(field.utf8.count):\(field)"
    }
    return Self.sha256(Data(stream.utf8))
  }

  public func record(forContractID contractID: String) throws -> TatwoStoredGoalRun? {
    let url = try fileURL(forContractID: contractID)
    return try readRecord(at: url)
  }

  /// Read one GoalRun and its exact persisted revision under the GoalRun lock.
  ///
  /// This is the read boundary for consumers that must not combine a contract
  /// projection, receipt state, and dispatch projection from different GoalRun
  /// revisions.
  public func snapshot(forContractID contractID: String) throws -> TatwoGoalRunSnapshotV1 {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw TatwoGoalRunStoreError.unregisteredContract(contractID)
      }
      let persistedRevision = try Data(contentsOf: url)
      let record = try decodedRecord(from: persistedRevision)
      guard record.contractID == contractID else {
        throw TatwoGoalRunStoreError.unregisteredContract(contractID)
      }
      return TatwoGoalRunSnapshotV1(
        record: record,
        persistedRevision: persistedRevision)
    }
  }

  /// Verify that the GoalRun still contains the exact bytes captured by
  /// `snapshot(forContractID:)`.
  public func verifyCurrent(_ snapshot: TatwoGoalRunSnapshotV1) throws -> Bool {
    let url = try fileURL(forContractID: snapshot.record.contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard FileManager.default.fileExists(atPath: url.path) else { return false }
      return try Data(contentsOf: url) == snapshot.persistedRevision
    }
  }

  /// Execute one mutation boundary only while the exact GoalRun revision is current.
  ///
  /// Unlike `verifyCurrent`, this keeps the GoalRun file lock held through `body`.
  /// Dispatch callers use it to linearize snapshot authorization with registry or
  /// channel mutation, so `updateStatus`/`appendReceipt` cannot land in the gap.
  public func withVerifiedCurrentSnapshot<T>(
    _ snapshot: TatwoGoalRunSnapshotV1,
    _ body: () throws -> T
  ) throws -> T {
    let contractID = snapshot.record.contractID
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard FileManager.default.fileExists(atPath: url.path),
        try Data(contentsOf: url) == snapshot.persistedRevision
      else {
        throw TatwoGoalRunStoreError.staleGoalRunSnapshot(contractID)
      }
      return try body()
    }
  }

  /// Mutable form of the exact-revision transaction.
  ///
  /// The caller owns the surrounding cross-store lock order. This method owns
  /// only the GoalRun file lock, keeps it through `body`, and persists the final
  /// in-memory record before releasing the lock. If `body` throws after placing
  /// the record into an explicit reconciliation state, that state is persisted
  /// before the original error is rethrown.
  func withVerifiedCurrentSnapshotTransaction<T>(
    _ snapshot: TatwoGoalRunSnapshotV1,
    _ body: (inout TatwoStoredGoalRun) throws -> T
  ) throws -> T {
    let contractID = snapshot.record.contractID
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      guard FileManager.default.fileExists(atPath: url.path),
        try Data(contentsOf: url) == snapshot.persistedRevision
      else {
        throw TatwoGoalRunStoreError.staleGoalRunSnapshot(contractID)
      }
      var record = snapshot.record
      do {
        let result = try body(&record)
        if record != snapshot.record {
          try write(record)
        }
        return result
      } catch {
        if record != snapshot.record {
          try write(record)
        }
        throw error
      }
    }
  }

  /// Authenticity gate: reject a contractID this store never issued.
  @discardableResult
  public func requireIssuedContract(_ contractID: String) throws -> TatwoStoredGoalRun {
    guard let record = try record(forContractID: contractID) else {
      throw TatwoGoalRunStoreError.unregisteredContract(contractID)
    }
    return record
  }

  /// Strict dispatch read: legacy records remain decodable for dashboards, but
  /// cannot dispatch without evidence of which identities were issued.
  public func requireIssuedIdentityBindings(
    contractID: String
  ) throws -> [TatwoIssuedIdentityBindingV1] {
    let record = try requireIssuedContract(contractID)
    return try validatedIssuedIdentityBindings(record)
  }

  public func requireIssuedIdentityBindingsDigest(contractID: String) throws -> String {
    let record = try requireIssuedContract(contractID)
    _ = try validatedIssuedIdentityBindings(record)
    guard let digest = record.issuedIdentityBindingsDigest else {
      throw TatwoGoalRunStoreError.issuedIdentityBindingsUnavailable(contractID)
    }
    return digest
  }

  /// Strict verification API for dispatch/reconnect paths that already rebuilt
  /// a contract projection.
  @discardableResult
  public func verifyIssuedIdentityBindings(
    contract: TatwoWorkOSContractV1
  ) throws -> [TatwoIssuedIdentityBindingV1] {
    let record = try requireIssuedContract(contract.contractID)
    let issued = try validatedIssuedIdentityBindings(record)
    let rebuilt = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
    guard issuedIdentityBindingsMatch(
      issued: issued,
      rebuilt: rebuilt,
      contract: contract,
      record: record)
    else {
      throw TatwoGoalRunStoreError.issuedIdentityBindingsMismatch(contract.contractID)
    }
    return issued
  }

  /// General read compatibility: an old record with no snapshot remains
  /// projectable. Once either snapshot field exists, both integrity and exact
  /// rebuilt equivalence become mandatory.
  @discardableResult
  public func verifyIssuedIdentityBindingsIfPresent(
    contract: TatwoWorkOSContractV1
  ) throws -> Bool {
    let record = try requireIssuedContract(contract.contractID)
    return try verifyIssuedIdentityBindingsIfPresent(
      contract: contract,
      record: record)
  }

  /// Snapshot-safe identity verification. The supplied record must be the same
  /// record used to rebuild `contract`; this overload never re-reads the store.
  @discardableResult
  public func verifyIssuedIdentityBindingsIfPresent(
    contract: TatwoWorkOSContractV1,
    record: TatwoStoredGoalRun
  ) throws -> Bool {
    guard record.contractID == contract.contractID else {
      throw TatwoGoalRunStoreError.unregisteredContract(contract.contractID)
    }
    guard record.issuedIdentityBindings != nil || record.issuedIdentityBindingsDigest != nil else {
      return false
    }
    let issued = try validatedIssuedIdentityBindings(record)
    let rebuilt = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
    guard issuedIdentityBindingsMatch(
      issued: issued,
      rebuilt: rebuilt,
      contract: contract,
      record: record)
    else {
      throw TatwoGoalRunStoreError.issuedIdentityBindingsMismatch(contract.contractID)
    }
    return true
  }

  /// Compatibility for the one contract shape issued before native-development
  /// host mutation moved behind the tool-intent bridge. The stored snapshot and
  /// digest remain authoritative; projection may only upgrade the two exact
  /// native-development lanes, and only from brain-only/non-mutating to the
  /// current tool-bridge/mutating authority. Every other issued field must
  /// remain byte-for-byte equivalent after canonicalization.
  private static func matchesLegacyNativeDevelopmentToolBridgeUpgrade(
    issued: [TatwoIssuedIdentityBindingV1],
    rebuilt: [TatwoIssuedIdentityBindingV1],
    contract: TatwoWorkOSContractV1,
    issuedAt: Date
  ) -> Bool {
    guard TatwoLegacyNativeDevelopmentBindingUpgradePolicy.isGrandfathered(
      issuedAt: issuedAt),
      contract.mode == .xxl,
      contract.scenario
        == TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID
    else {
      return false
    }

    let legacySourceSlotIDs: Set<String> = [
      TatwoNativeDevelopmentDispatchCoordinator.solExecutorSourceSlotID,
      TatwoNativeDevelopmentDispatchCoordinator.opusSupervisorSourceSlotID,
    ]
    let upgraded = rebuilt.filter {
      legacySourceSlotIDs.contains($0.sourceSlotID)
    }
    guard upgraded.count == legacySourceSlotIDs.count,
      Set(upgraded.map(\.sourceSlotID)) == legacySourceSlotIDs,
      upgraded.allSatisfy({
        $0.authority == .toolIntentBridge && $0.canMutateHost
      })
    else {
      return false
    }

    let expectedLegacy = TatwoIssuedIdentityBindingV1.canonicalized(
      rebuilt.map { binding in
        guard legacySourceSlotIDs.contains(binding.sourceSlotID) else {
          return binding
        }
        return TatwoIssuedIdentityBindingV1(
          id: binding.id,
          sourceSlotID: binding.sourceSlotID,
          identity: binding.identity,
          modelID: binding.modelID,
          authority: .brainOnly,
          engineID: binding.engineID,
          reasoningEffort: binding.reasoningEffort,
          canMutateHost: false)
      })
    return issued == expectedLegacy
  }

  private func issuedIdentityBindingsMatch(
    issued: [TatwoIssuedIdentityBindingV1],
    rebuilt: [TatwoIssuedIdentityBindingV1],
    contract: TatwoWorkOSContractV1,
    record: TatwoStoredGoalRun
  ) -> Bool {
    if issued == rebuilt {
      return true
    }
    guard Self.matchesLegacyNativeDevelopmentToolBridgeUpgrade(
      issued: issued,
      rebuilt: rebuilt,
      contract: contract,
      issuedAt: record.issuedAt)
    else {
      return false
    }
    TatwoConfigAuditLog(directoryURL: directoryURL).append(
      actor: "goal-run-store",
      action: "legacy_binding_upgrade_grandfathered",
      detail: "scenario=\(record.scenario) issued_at_before=2026-08-01T00:00:00+08:00",
      configHash: record.issuedIdentityBindingsDigest ?? "missing")
    return true
  }

  private func validatedIssuedIdentityBindings(
    _ record: TatwoStoredGoalRun
  ) throws -> [TatwoIssuedIdentityBindingV1] {
    guard let stored = record.issuedIdentityBindings,
      let storedDigest = record.issuedIdentityBindingsDigest
    else {
      throw TatwoGoalRunStoreError.issuedIdentityBindingsUnavailable(record.contractID)
    }
    let canonical = TatwoIssuedIdentityBindingV1.canonicalized(stored)
    guard TatwoIssuedIdentityBindingV1.deterministicDigest(for: canonical) == storedDigest else {
      throw TatwoGoalRunStoreError.issuedIdentityBindingsDigestMismatch(record.contractID)
    }
    return canonical
  }

  // MARK: Receipts

  /// Journal a submitted receipt against an issued contract.
  ///
  /// Legacy entries deduplicate by `receiptID`. Evidence-referenced M4b entries
  /// deduplicate by `(receiptID, satisfiesRequirementID)` so one immutable
  /// artifact may conservatively prove more than one exact requirement without
  /// fabricating replacement receipt IDs.
  @discardableResult
  public func appendReceipt(
    contractID: String,
    receiptID: String,
    kind: String,
    loopID: String? = nil,
    satisfiesRequirementID: String? = nil
  ) throws -> TatwoStoredGoalRun {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var record = try requireIssuedContract(contractID)
      guard record.status != .superseded,
        record.successorContractID == nil
      else {
        throw TatwoGoalRunStoreError.staleGoalRevision(contractID)
      }
      if !record.receipts.contains(where: {
        $0.receiptID == receiptID
          && $0.satisfiesRequirementID == satisfiesRequirementID
      }) {
        record.receipts.append(
          TatwoStoredReceipt(
            receiptID: receiptID,
            kind: kind,
            loopID: loopID,
            satisfiesRequirementID: satisfiesRequirementID))
      }
      record.updatedAt = Date()
      try write(record)
      return record
    }
  }

  public func submittedReceiptIDs(contractID: String) throws -> Set<String> {
    try requireIssuedContract(contractID).submittedReceiptIDs
  }

  // MARK: Status

  @discardableResult
  public func updateStatus(contractID: String, status: GoalRunStatus) throws -> TatwoStoredGoalRun {
    try updateStatus(
      contractID: contractID,
      status: status,
      authority: .caller)
  }

  @discardableResult
  public func updateCooldownStatus(
    contractID: String,
    status: GoalRunStatus,
    reason: String
  ) throws -> TatwoStoredGoalRun {
    try updateStatus(
      contractID: contractID,
      status: status,
      authority: .cooldownFence,
      reason: reason)
  }

  /// Converts a bounded dispatch retry into an explicit terminal GoalRun.
  /// The old logical dispatch remains immutable; recovery requires a newly
  /// confirmed Goal revision/contract rather than silently minting attempt 3.
  @discardableResult
  public func markDispatchRetryExhausted(
    contractID: String,
    dispatchID: String
  ) throws -> TatwoStoredGoalRun {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var current = try requireIssuedContract(contractID)
      let original = current
      let dispatchRegistry = TatwoDispatchRegistry(directoryURL: directoryURL)
      let run: TatwoStoredDispatchRun
      do {
        guard let storedRun = try dispatchRegistry.run(
          forContractID: contractID)
        else {
          throw TatwoGoalRunStoreError.dispatchRetryExhaustionRunMissing(
            contractID: contractID)
        }
        run = storedRun
      } catch let error as TatwoGoalRunStoreError {
        throw error
      } catch {
        throw TatwoGoalRunStoreError.dispatchRetryExhaustionRunUnreadable(
          contractID: contractID)
      }
      guard run.contractID == contractID else {
        throw TatwoGoalRunStoreError.dispatchRetryExhaustionRunContractMismatch(
          expected: contractID,
          actual: run.contractID)
      }
      let matchingDispatches = run.records.filter { $0.id == dispatchID }
      guard matchingDispatches.count == 1,
        let dispatch = matchingDispatches.first
      else {
        throw TatwoGoalRunStoreError.dispatchRetryExhaustionDispatchMatchCount(
          contractID: contractID,
          dispatchID: dispatchID,
          count: matchingDispatches.count)
      }
      guard dispatch.contractID == contractID else {
        throw TatwoGoalRunStoreError
          .dispatchRetryExhaustionDispatchContractMismatch(
            expected: contractID,
            actual: dispatch.contractID)
      }
      guard dispatch.status == .failed else {
        throw TatwoGoalRunStoreError.dispatchRetryExhaustionDispatchNotFailed(
          status: dispatch.status)
      }
      guard dispatch.failureReceipt?.failureClass == .retryable else {
        throw TatwoGoalRunStoreError
          .dispatchRetryExhaustionFailureNotRetryable(
            failureClass: dispatch.failureReceipt?.failureClass)
      }
      guard dispatch.resolvedAttempt >= Self.dispatchRetryAttemptCap else {
        throw TatwoGoalRunStoreError.dispatchRetryExhaustionAttemptBelowCap(
          attempt: dispatch.resolvedAttempt,
          cap: Self.dispatchRetryAttemptCap)
      }
      let activeCycleEpoch = run.activeCycleEpoch ?? 1
      guard dispatch.resolvedCycleEpoch == activeCycleEpoch else {
        throw TatwoGoalRunStoreError.dispatchRetryExhaustionCycleMismatch(
          expected: activeCycleEpoch,
          actual: dispatch.resolvedCycleEpoch)
      }
      if let superseding = Self.liveSupersedingDispatch(
        of: dispatchID,
        in: run.records)
      {
        throw TatwoGoalRunStoreError
          .dispatchRetryExhaustionLiveSupersedingDispatch(
            dispatchID: dispatchID,
            supersedingDispatchID: superseding.id)
      }
      let failedReason =
        "dispatch_failed:\(dispatchID):class=retryable:"
        + "attempt=\(dispatch.resolvedAttempt)"
      let exhaustionReason = "single_model_retry_exhausted:\(dispatchID)"
      let chainedReason = "\(failedReason);\(exhaustionReason)"
      let now = Date(
        timeIntervalSince1970:
          Date().timeIntervalSince1970.rounded(.down))
      if current.status == .failed {
        if current.statusReason == chainedReason
          || current.statusReason == exhaustionReason
          || current.statusReason?.hasSuffix(";\(exhaustionReason)") == true
        {
          return current
        }
        guard current.statusReason == failedReason else {
          throw TatwoGoalRunStoreError.dispatchRetryExhaustionReasonMismatch(
            expected: failedReason,
            actual: current.statusReason)
        }
        try transitionLockedRecord(
          &current,
          status: .failed,
          authority: .dispatchRetryExhaustion,
          reason: chainedReason,
          evidence: .retryExhaustion(dispatchID: dispatchID),
          now: now)
      } else {
        guard current.status == .blocked else {
          throw TatwoGoalRunStoreError.illegalStatusTransition(
            from: current.status,
            to: .failed,
            authority: "single_model_retry_exhausted")
        }
        let existingReason = current.statusReason?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String
        if existingReason == exhaustionReason
          || existingReason?.hasSuffix(";\(exhaustionReason)") == true
        {
          reason = existingReason ?? exhaustionReason
        } else if let existingReason, !existingReason.isEmpty {
          reason = "\(existingReason);\(exhaustionReason)"
        } else {
          reason = exhaustionReason
        }
        try transitionLockedRecord(
          &current,
          status: .failed,
          authority: .dispatchRetryExhaustion,
          reason: reason,
          evidence: .retryExhaustion(dispatchID: dispatchID),
          now: now)
      }
      try write(current)
      try dispatchRetryExhaustionPostWriteHook?()
      let readback = try requireIssuedContract(contractID)
      guard readback == current else {
        do {
          try write(original)
          try dispatchRetryExhaustionRollbackReadbackHook?()
          let rollbackReadback = try requireIssuedContract(contractID)
          guard rollbackReadback == original else {
            throw TatwoGoalRunStoreError.dispatchRetryExhaustionRollbackFailed(
              contractID: contractID)
          }
        } catch let error as TatwoGoalRunStoreError {
          guard case .dispatchRetryExhaustionRollbackFailed = error else {
            throw TatwoGoalRunStoreError.dispatchRetryExhaustionRollbackFailed(
              contractID: contractID)
          }
          throw error
        } catch {
          throw TatwoGoalRunStoreError.dispatchRetryExhaustionRollbackFailed(
            contractID: contractID)
        }
        throw TatwoGoalRunStoreError.dispatchRetryExhaustionReadbackMismatch(
          contractID: contractID)
      }
      return readback
    }
  }

  @discardableResult
  func updateStatus(
    contractID: String,
    status: GoalRunStatus,
    authority: TatwoGoalRunTransitionAuthority,
    reason: String? = nil,
    evidence: TatwoGoalRunTransitionEvidence? = nil
  ) throws -> TatwoStoredGoalRun {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var record = try requireIssuedContract(contractID)
      try transitionLockedRecord(
        &record,
        status: status,
        authority: authority,
        reason: reason,
        evidence: evidence)
      try write(record)
      return record
    }
  }

  func transitionLockedRecord(
    _ record: inout TatwoStoredGoalRun,
    status: GoalRunStatus,
    authority: TatwoGoalRunTransitionAuthority,
    reason: String? = nil,
    evidence: TatwoGoalRunTransitionEvidence? = nil,
    now: Date = Date()
  ) throws {
    guard Self.permitsTransition(
      from: record.status,
      to: status,
      authority: authority,
      evidence: evidence)
    else {
      throw TatwoGoalRunStoreError.illegalStatusTransition(
        from: record.status,
        to: status,
        authority: authority.rawValue)
    }
    record.status = status
    record.statusReason = reason
    record.updatedAt = now
  }

  private static func permitsTransition(
    from: GoalRunStatus,
    to: GoalRunStatus,
    authority: TatwoGoalRunTransitionAuthority,
    evidence: TatwoGoalRunTransitionEvidence?
  ) -> Bool {
    if authority == .dispatchRetryExhaustion {
      guard case let .retryExhaustion(dispatchID) = evidence,
        !dispatchID.isEmpty
      else {
        return false
      }
      return [.blocked, .failed].contains(from) && to == .failed
    }
    if from == .failed { return false }
    if from == to { return true }
    switch authority {
    case .caller:
      return (from == .planned && to == .dispatching)
        || (from == .running && [.failed, .cancelled].contains(to))
    case .ledgerBeginAck:
      guard case .ledger = evidence else {
        if case .reconciliation = evidence {
          return from == .dispatching && to == .blocked
        }
        return false
      }
      return from == .dispatching && [.planned, .running, .blocked, .failed].contains(to)
    case .cooldownFence:
      return (from == .planned && to == .blocked)
        || (from == .blocked && to == .planned)
    case .dispatchFailure:
      guard case .failure = evidence else {
        if case .reconciliation = evidence {
          // Channel-commit / prepare orphans may quarantine before GoalRun leaves planned.
          return [.planned, .dispatching, .running].contains(from) && to == .blocked
        }
        return false
      }
      return (from == .running && [.blocked, .failed].contains(to))
        || (from == .blocked && to == .failed)
    case .dispatchRetry:
      guard case .retry = evidence else { return false }
      return from == .blocked && to == .dispatching
    case .dispatchRetryExhaustion:
      return false
    case .dispatchCycleAdvance:
      return [
        GoalRunStatus.awaitingNextCycle,
        .blocked,
        .humanGate,
        .succeeded,
      ].contains(from) && to == .running
    case .plannedSupersede:
      return from == .planned && to == .cancelled
    case .revisionPromotion:
      return (from == .running && to == .superseded)
        || (from == .planned && to == .running)
    case .goalClose:
      // A completed Goal Judge decision is immutable. The equality fast path
      // above keeps idempotent retries valid, but a later close must not flip
      // `passed` to `rollbackRequired` (or vice versa). Cancelled work is also
      // terminal and cannot be revived through the Goal Judge close authority.
      guard ![.cancelled, .passed, .rollbackRequired, .superseded].contains(from) else {
        return false
      }
      return to == .passed || to == .rollbackRequired
    }
  }

  private static func isImmutableTerminal(_ status: GoalRunStatus) -> Bool {
    switch status {
    case .succeeded, .failed, .cancelled, .passed, .rollbackRequired, .superseded:
      return true
    case .planned, .dispatching, .running, .humanGate, .awaitingNextCycle, .blocked:
      return false
    }
  }

  private static func liveSupersedingDispatch(
    of dispatchID: String,
    in records: [TatwoDispatchRecord]
  ) -> TatwoDispatchRecord? {
    var visited: Set<String> = [dispatchID]
    var frontier = [dispatchID]
    while let ancestorID = frontier.popLast() {
      for candidate in records where candidate.supersedes == ancestorID {
        guard visited.insert(candidate.id).inserted else { continue }
        if candidate.status == .queued || candidate.status == .running {
          return candidate
        }
        frontier.append(candidate.id)
      }
    }
    return nil
  }

  @discardableResult
  func finalizeDispatchSet(
    contractID: String,
    sealID: String,
    recordCount: Int,
    cycleEpoch: UInt64 = 1
  ) throws -> TatwoStoredGoalRun {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var record = try requireIssuedContract(contractID)
      let reason =
        "\(TatwoStoredGoalRun.dispatchCycleFinalizedReasonPrefix)\(cycleEpoch):\(recordCount):\(sealID)"
      if record.status == .awaitingNextCycle,
        record.hasDispatchCycleFinalizationReason
      {
        guard record.statusReason == reason,
          record.latestDispatchCycleEpoch == cycleEpoch,
          record.latestDispatchCycleSealID == sealID
        else {
          throw TatwoGoalRunStoreError.illegalStatusTransition(
            from: record.status,
            to: .awaitingNextCycle,
            authority: "dispatch_finalize_retry")
        }
        return record
      }
      if [.humanGate, .succeeded].contains(record.status),
        record.hasDispatchSetFinalizationReason
      {
        // Preserve legacy bytes/status on an idempotent finalize retry. The
        // explicit cycle-advance compatibility bridge performs the migration.
        guard record.statusReason?.hasSuffix(":\(sealID)") == true else {
          throw TatwoGoalRunStoreError.illegalStatusTransition(
            from: record.status,
            to: .awaitingNextCycle,
            authority: "dispatch_finalize_legacy_retry")
        }
        return record
      }
      guard record.status == .running else {
        throw TatwoGoalRunStoreError.illegalStatusTransition(
          from: record.status,
          to: .awaitingNextCycle,
          authority: "dispatch_finalize")
      }
      record.status = .awaitingNextCycle
      record.statusReason = reason
      record.latestDispatchCycleEpoch = cycleEpoch
      record.latestDispatchCycleSealID = sealID
      record.updatedAt = Date()
      try write(record)
      return try requireIssuedContract(contractID)
    }
  }

  /// Advances from an immutable dispatch-cycle boundary to the next open
  /// cycle. Legacy `succeeded/human_gate + dispatch_set_finalized` records are
  /// interpreted by this explicit compatibility bridge only; unrelated gates
  /// and true terminal Goal states remain closed.
  @discardableResult
  func advanceDispatchCycle(
    contractID: String,
    expectedSealID: String,
    nextEpoch: UInt64
  ) throws -> TatwoStoredGoalRun {
    let url = try fileURL(forContractID: contractID)
    return try TatwoFileLock.withExclusiveLock(for: url) {
      var record = try requireIssuedContract(contractID)
      if record.status == .running,
        record.statusReason
          == "\(TatwoStoredGoalRun.dispatchCycleOpenedReasonPrefix)\(nextEpoch):after:\(expectedSealID)"
      {
        return record
      }
      guard record.isResumableDispatchCycleBoundary else {
        throw TatwoGoalRunStoreError.illegalStatusTransition(
          from: record.status,
          to: .running,
          authority: TatwoGoalRunTransitionAuthority.dispatchCycleAdvance.rawValue)
      }
      let actualSeal =
        record.latestDispatchCycleSealID
        ?? record.statusReason?.split(separator: ":").last.map(String.init)
        ?? ""
      guard actualSeal == expectedSealID else {
        throw TatwoGoalRunStoreError.staleDispatchCycleBoundary(
          expected: expectedSealID,
          actual: actualSeal)
      }
      let priorEpoch = record.latestDispatchCycleEpoch ?? 1
      guard nextEpoch == priorEpoch + 1 else {
        throw TatwoGoalRunStoreError.illegalStatusTransition(
          from: record.status,
          to: .running,
          authority: "dispatch_cycle_epoch_noncontiguous")
      }
      record.status = .running
      record.statusReason =
        "\(TatwoStoredGoalRun.dispatchCycleOpenedReasonPrefix)\(nextEpoch):after:\(expectedSealID)"
      record.latestDispatchCycleEpoch = priorEpoch
      record.latestDispatchCycleSealID = expectedSealID
      record.updatedAt = Date()
      try write(record)
      // Return the canonical persisted representation. JSON's ISO-8601 encoding
      // truncates Date precision, so returning the in-memory value here would
      // make the first response differ from an otherwise idempotent retry.
      return try requireIssuedContract(contractID)
    }
  }

  // MARK: Storage

  private func write(_ record: TatwoStoredGoalRun) throws {
    let url = try fileURL(forContractID: record.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: url, options: [.atomic])
  }

  private func readRecord(at url: URL) throws -> TatwoStoredGoalRun? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try decodedRecord(from: Data(contentsOf: url))
  }

  private func decodedRecord(from data: Data) throws -> TatwoStoredGoalRun {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoStoredGoalRun.self, from: data)
  }

  private static func sha256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }

  private static func compactReason(_ value: String) -> String {
    String(
      TatwoPrivacyRedactor.redacted(value)
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(512))
  }

  /// Shared on-disk store, resolved the same way scenario-config is so CLI, MCP, and App
  /// all agree on one directory (no CLI-`$CWD` vs App-`Application Support` split-brain).
  /// Base directory order: `TATWO_ULTRAWORK_STATE_DIR` → `TATWO_ULTRAWORK_APP_SUPPORT`
  /// → `~/Library/Application Support/Tatwo Ultrawork/state`.
  ///
  /// `TATWO_OS_ROOT` locates the constitution/adapters only; it must never
  /// relocate live GoalRun state or App/CLI/MCP can read different contracts.
  /// Records land under `<base>/goals/<contractID>.json`.
  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> TatwoGoalRunStore {
    func value(_ key: String) -> String? {
      guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
      else { return nil }
      return raw
    }
    let base: URL
    if let stateDir = value("TATWO_ULTRAWORK_STATE_DIR") {
      base = URL(fileURLWithPath: stateDir, isDirectory: true)
    } else if let support = value("TATWO_ULTRAWORK_APP_SUPPORT") {
      base = URL(fileURLWithPath: support, isDirectory: true)
        .appendingPathComponent("state", isDirectory: true)
    } else {
      base = implicitDefaultDirectory(environment: environment)
    }
    return TatwoGoalRunStore(directoryURL: base)
  }

  /// In normal app/CLI launches the implicit base is Application Support. In restricted
  /// sandbox validation (for example Codex running `swift test`) that directory can be
  /// readable but not writable, which would make `tatwo.os.begin` fail before product code
  /// is exercised. Explicit state env vars still fail loudly; only the implicit fallback
  /// degrades to /tmp so tests and read-only sandboxes can create receipts.
  ///
  /// Resolution must remain read-only. The Modes authority monitor observes this directory,
  /// so a create/write/delete probe here would turn every read-side store resolution into a
  /// fresh durable-state revision.
  static func implicitDefaultDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    let candidate = TatwoRuntimeLayout.stateRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    return writableImplicitBase(candidate, fileManager: fileManager)
  }

  private static func writableImplicitBase(
    _ candidate: URL,
    fileManager: FileManager
  ) -> URL {
    let standardizedCandidate = candidate.standardizedFileURL
    var current = standardizedCandidate

    while true {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) {
        if isDirectory.boolValue, fileManager.isWritableFile(atPath: current.path) {
          return standardizedCandidate
        }
        return temporaryFallback(fileManager: fileManager)
      }

      let parent = current.deletingLastPathComponent()
      guard parent.path != current.path else {
        return temporaryFallback(fileManager: fileManager)
      }
      current = parent
    }
  }

  private static func temporaryFallback(fileManager: FileManager) -> URL {
    fileManager.temporaryDirectory
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
  }

  /// Normalize only the one historical live-state fork that shipped without the
  /// product-name space. Arbitrary injected roots (including test fixtures) must
  /// remain byte-for-byte caller-owned.
  static func canonicalStateRootIfKnownLegacy(
    _ candidate: URL,
    fileManager: FileManager = .default
  ) -> URL {
    let applicationSupport = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
    let legacy = applicationSupport
      .appendingPathComponent("TatwoUltrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
      .standardizedFileURL
    guard candidate.standardizedFileURL == legacy else {
      return candidate
    }
    return applicationSupport
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
      .standardizedFileURL
  }

  /// Map a contractID to a safe file under `directoryURL/goals/`. Rejects anything that
  /// does not reduce to `[a-z0-9-]` so a forged/traversal-style contractID cannot escape.
  func fileURL(forContractID contractID: String) throws -> URL {
    let normalized = contractID.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    guard !normalized.isEmpty,
      normalized.lowercased() == normalized,
      normalized.allSatisfy({ allowed.contains($0) })
    else {
      throw TatwoGoalRunStoreError.invalidContractID(contractID)
    }
    return
      directoryURL
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent("\(normalized).json", isDirectory: false)
  }
}
