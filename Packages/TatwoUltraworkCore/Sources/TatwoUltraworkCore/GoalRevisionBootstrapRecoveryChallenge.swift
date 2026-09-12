import Foundation

/// Caller-supplied audit context for a root-owned recovery candidate.
///
/// These bytes and identifiers are not trusted proof of a human event. The
/// factory only binds their exact digests into a read-only candidate. Trust is
/// established later, and only, when a fresh macOS administrator re-reads and
/// reviews the original bytes, the canonical Goal diff, the grant digest, and
/// the short code before installing the exact root-owned grant.
///
/// All Goal/session/capability fields are deliberately omitted: the factory
/// reads those from the canonical stores.
@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionBootstrapRecoveryChallengeInputV1:
  Sendable, Equatable
{
  public let successorContractID: String
  public let threadID: String
  public let turnID: String
  public let eventID: String
  public let humanMessage: Data
  public let legacyAppVersion: String
  public let legacyAppBuild: String
  public let legacyUnavailableEvidence: Data
  public let deviceID: String
  public let localUserUID: UInt32
  public let recoveryReason: String
  public let issuedAt: Date
  public let expiresAt: Date

  public init(
    successorContractID: String,
    threadID: String,
    turnID: String,
    eventID: String,
    humanMessage: Data,
    legacyAppVersion: String,
    legacyAppBuild: String,
    legacyUnavailableEvidence: Data,
    deviceID: String,
    localUserUID: UInt32,
    recoveryReason: String =
      "installed_app_confirmation_unavailable",
    issuedAt: Date,
    expiresAt: Date
  ) {
    self.successorContractID = successorContractID
    self.threadID = threadID
    self.turnID = turnID
    self.eventID = eventID
    self.humanMessage = humanMessage
    self.legacyAppVersion = legacyAppVersion
    self.legacyAppBuild = legacyAppBuild
    self.legacyUnavailableEvidence = legacyUnavailableEvidence
    self.deviceID = deviceID
    self.localUserUID = localUserUID
    self.recoveryReason = recoveryReason
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }
}

@_spi(TatwoBootstrapRecoveryHost)
public enum TatwoGoalRevisionBootstrapRecoveryChallengeError:
  Error, LocalizedError, Equatable, Sendable
{
  case invalidInput(String)
  case noCurrentSession
  case currentGoalNotRunning(GoalRunStatus)
  case currentStateMismatch
  case successorMatchesPredecessor
  case successorNotPlanned(GoalRunStatus)
  case successorNotPristine(String)
  case predecessorDispatchActive([String])
  case stateChangedDuringPreparation

  public var errorDescription: String? {
    switch self {
    case .invalidInput(let field):
      return "Goal revision recovery input is invalid: \(field)"
    case .noCurrentSession:
      return "No canonical current-session is available."
    case .currentGoalNotRunning(let status):
      return
        "The canonical predecessor Goal must be running; current=\(status.rawValue)."
    case .currentStateMismatch:
      return "The canonical current-session and predecessor Goal do not match."
    case .successorMatchesPredecessor:
      return "The recovery successor must differ from the current predecessor."
    case .successorNotPlanned(let status):
      return
        "The recovery successor must be planned; current=\(status.rawValue)."
    case .successorNotPristine(let reason):
      return "The recovery successor is not pristine: \(reason)"
    case .predecessorDispatchActive(let ids):
      return
        "The predecessor still has active dispatches: "
        + ids.sorted().joined(separator: ",")
    case .stateChangedDuringPreparation:
      return
        "Canonical Goal/session state changed while preparing the recovery plan."
    }
  }
}

/// Exact canonical state held under the predecessor/successor lifecycle locks
/// while a recovery candidate was prepared. Root-admin enrollment renders
/// these exact values instead of re-reading a potentially different projection
/// after the locks have been released.
@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionBootstrapRecoveryPreparedChallengeV1:
  Sendable, Equatable
{
  public let plan: TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1
  public let canonicalCurrentSession: TatwoSessionPointer
  public let currentSessionRevisionDigest: String
  public let canonicalPredecessorGoal: TatwoStoredGoalRun
  public let predecessorPersistedRevisionDigest: String
  public let canonicalSuccessorGoal: TatwoStoredGoalRun
  public let successorPersistedRevisionDigest: String
}

/// Builds the exact root-owned grant from canonical live state without writing
/// any file or mutating Goal/session state.
@_spi(TatwoBootstrapRecoveryHost)
public enum TatwoGoalRevisionBootstrapRecoveryChallengeFactory {
  public static func prepare(
    input: TatwoGoalRevisionBootstrapRecoveryChallengeInputV1,
    goalStore: TatwoGoalRunStore,
    sessionStore: TatwoSessionStore,
    dispatchRegistry: TatwoDispatchRegistry,
    beforeFinalStateValidation:
      (@Sendable () throws -> Void)? = nil
  ) throws -> TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1 {
    try prepareDetailed(
      input: input,
      goalStore: goalStore,
      sessionStore: sessionStore,
      dispatchRegistry: dispatchRegistry,
      beforeFinalStateValidation: beforeFinalStateValidation
    ).plan
  }

  public static func prepareDetailed(
    input: TatwoGoalRevisionBootstrapRecoveryChallengeInputV1,
    goalStore: TatwoGoalRunStore,
    sessionStore: TatwoSessionStore,
    dispatchRegistry: TatwoDispatchRegistry,
    beforeFinalStateValidation:
      (@Sendable () throws -> Void)? = nil
  ) throws -> TatwoGoalRevisionBootstrapRecoveryPreparedChallengeV1 {
    try validate(input)

    guard let pointerSnapshot = try sessionStore.snapshotCurrent() else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .noCurrentSession
    }
    return try TatwoGoalRunDispatchLifecycle.withLifecycleLocks(
      contractIDs: [
        pointerSnapshot.pointer.contractID,
        input.successorContractID,
      ],
      goalStore: goalStore
    ) {
      guard try sessionStore.snapshotCurrent() == pointerSnapshot else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .stateChangedDuringPreparation
      }
      let pointer = pointerSnapshot.pointer
      let oldSnapshot = try goalStore.snapshot(
        forContractID: pointer.contractID)
      let old = oldSnapshot.record
      guard old.status == .running else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .currentGoalNotRunning(old.status)
      }
      guard pointer.goalID == old.goalID,
        pointer.mode == old.mode,
        pointer.scenario == old.scenario,
        pointer.objective == old.objective
      else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .currentStateMismatch
      }

      let successorSnapshot = try goalStore.snapshot(
        forContractID: input.successorContractID)
      let successor = successorSnapshot.record
      guard successor.contractID != old.contractID,
        successor.goalID != old.goalID
      else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .successorMatchesPredecessor
      }
      guard successor.status == .planned else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .successorNotPlanned(successor.status)
      }
      try requirePristineSuccessor(
        successor,
        goalStore: goalStore,
        dispatchRegistry: dispatchRegistry)

      let activeDispatchIDs =
        try dispatchRegistry
        .run(forContractID: old.contractID)?
        .records
        .filter { $0.status == .queued || $0.status == .running }
        .map(\.id)
        ?? []
      guard activeDispatchIDs.isEmpty else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .predecessorDispatchActive(activeDispatchIDs)
      }

      let issuedAt =
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.wholeSecond(
          input.issuedAt)
      let expiresAt =
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.wholeSecond(
          input.expiresAt)
      let sessionID =
        pointer.ownerBinding?.sessionID
        ?? "unowned:\(old.contractID):\(old.goalID)"
      let humanMessageDigest =
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          input.humanMessage)
      let legacyUnavailableEvidenceDigest =
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          input.legacyUnavailableEvidence)
      let requestedHostScopeDigest =
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          Data(
            [
              "revision_activation_only",
              "none",
              "",
              "none",
              "none",
              "none",
            ].joined(separator: "\n").utf8))
      let oldObjectiveDigest =
        TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
          old.objective)
      let oldReceiptsDigest =
        TatwoGoalRevisionPromotionAuthorizationV1.receiptsDigest(
          old.receipts)
      let newObjectiveDigest =
        TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
          successor.objective)
      let topologyDigest =
        TatwoGoalRevisionPromotionAuthorizationV1.topologyDigest(
          sessionID: sessionID,
          oldContractID: old.contractID,
          oldGoalID: old.goalID,
          newContractID: successor.contractID,
          newGoalID: successor.goalID)
      let capabilityDigest =
        TatwoGoalRevisionPromotionAuthorizationV1.capabilityDigest(
          oldBindingsDigest: old.issuedIdentityBindingsDigest,
          newBindingsDigest: successor.issuedIdentityBindingsDigest)
      let seed =
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          TatwoGoalRevisionBootstrapRecoveryEvidenceV1.canonicalData([
            pointerSnapshot.revision.digest,
            oldSnapshot.persistedRevisionDigest,
            successorSnapshot.persistedRevisionDigest,
            input.threadID,
            input.turnID,
            input.eventID,
            humanMessageDigest,
            legacyUnavailableEvidenceDigest,
            input.deviceID,
            String(input.localUserUID),
            String(Int64(issuedAt.timeIntervalSince1970)),
            String(Int64(expiresAt.timeIntervalSince1970)),
          ]))
      let suffix = String(seed.dropFirst("sha256:".count).prefix(24))
      let shortCode =
        String(seed.dropFirst("sha256:".count).prefix(8)).uppercased()
      let evidence =
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1(
          id: "goal-revision-bootstrap-human-\(suffix)",
          challengeID:
            "goal-revision-bootstrap-challenge-\(suffix)",
          threadID: input.threadID,
          turnID: input.turnID,
          eventID: input.eventID,
          observedRole: "user",
          humanMessageDigest: humanMessageDigest,
          legacyAppBundleIdentifier: "com.tatwo.ultrawork",
          legacyAppVersion: input.legacyAppVersion,
          legacyAppBuild: input.legacyAppBuild,
          legacyIssuerAvailability: "unavailable",
          legacyUnavailableEvidenceDigest:
            legacyUnavailableEvidenceDigest,
          authorityKind:
            TatwoGoalRevisionBootstrapRecoveryEvidenceV1
            .rootOwnedGrantAuthorityKind,
          hostKeyID: String(repeating: "0", count: 64)
            .withSHA256Prefix,
          authorizationID:
            "goal-revision-bootstrap-promotion-\(suffix)",
          grantID: "goal-revision-bootstrap-grant-\(suffix)",
          shortCode: shortCode,
          localUserUID: input.localUserUID,
          deviceID: input.deviceID,
          recoveryReason: input.recoveryReason,
          sessionID: sessionID,
          oldPointerRevisionDigest: pointerSnapshot.revision.digest,
          oldPointerGeneration: pointer.generation ?? 1,
          oldContractID: old.contractID,
          oldGoalID: old.goalID,
          oldGoalRevision: old.resolvedRevision,
          oldActivationEpoch: old.resolvedRevision,
          oldObjectiveDigest: oldObjectiveDigest,
          oldReceiptsDigest: oldReceiptsDigest,
          newContractID: successor.contractID,
          newGoalID: successor.goalID,
          newGoalRevision: old.resolvedRevision + 1,
          newObjectiveDigest: newObjectiveDigest,
          topologyDigest: topologyDigest,
          capabilityDigest: capabilityDigest,
          requestedHostScopeDigest: requestedHostScopeDigest,
          allowedOperations:
            TatwoGoalRevisionBootstrapRecoveryEvidenceV1
            .requiredAllowedOperations,
          deniedOperations:
            TatwoGoalRevisionBootstrapRecoveryEvidenceV1
            .requiredDeniedOperations,
          maxUses: 1,
          issuedAt: issuedAt,
          expiresAt: expiresAt,
          nonce: "goal-revision-bootstrap-nonce-\(suffix)")
      let plan =
        try TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1.prepare(
          evidence: evidence)

      try beforeFinalStateValidation?()
      guard try sessionStore.snapshotCurrent() == pointerSnapshot,
        try goalStore.snapshot(forContractID: old.contractID)
          == oldSnapshot,
        try goalStore.snapshot(forContractID: successor.contractID)
          == successorSnapshot
      else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .stateChangedDuringPreparation
      }
      let finalActiveDispatchIDs =
        try dispatchRegistry
        .run(forContractID: old.contractID)?
        .records
        .filter { $0.status == .queued || $0.status == .running }
        .map(\.id)
        ?? []
      guard finalActiveDispatchIDs.isEmpty else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .predecessorDispatchActive(finalActiveDispatchIDs)
      }
      try requirePristineSuccessor(
        successor,
        goalStore: goalStore,
        dispatchRegistry: dispatchRegistry)
      return TatwoGoalRevisionBootstrapRecoveryPreparedChallengeV1(
        plan: plan,
        canonicalCurrentSession: pointerSnapshot.pointer,
        currentSessionRevisionDigest: pointerSnapshot.revision.digest,
        canonicalPredecessorGoal: old,
        predecessorPersistedRevisionDigest:
          oldSnapshot.persistedRevisionDigest,
        canonicalSuccessorGoal: successor,
        successorPersistedRevisionDigest:
          successorSnapshot.persistedRevisionDigest)
    }
  }

  private static func validate(
    _ input: TatwoGoalRevisionBootstrapRecoveryChallengeInputV1
  ) throws {
    let exactStrings = [
      ("successorContractID", input.successorContractID),
      ("threadID", input.threadID),
      ("turnID", input.turnID),
      ("eventID", input.eventID),
      ("legacyAppVersion", input.legacyAppVersion),
      ("legacyAppBuild", input.legacyAppBuild),
      ("deviceID", input.deviceID),
      ("recoveryReason", input.recoveryReason),
    ]
    for (name, value) in exactStrings {
      guard !value.isEmpty,
        value.utf8.count <= 512,
        !value.contains("\0"),
        !value.contains("\n"),
        !value.contains("\r"),
        isSafeAuditString(value),
        value == value.trimmingCharacters(
          in: .whitespacesAndNewlines)
      else {
        throw TatwoGoalRevisionBootstrapRecoveryChallengeError
          .invalidInput(name)
      }
    }
    guard !input.successorContractID.contains("/"),
      !input.successorContractID.contains("..")
    else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .invalidInput("successorContractID")
    }
    guard !input.humanMessage.isEmpty,
      input.humanMessage.count <= 1024 * 1024,
      String(data: input.humanMessage, encoding: .utf8) != nil
    else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .invalidInput("humanMessage")
    }
    guard !input.legacyUnavailableEvidence.isEmpty,
      input.legacyUnavailableEvidence.count <= 1024 * 1024,
      String(
        data: input.legacyUnavailableEvidence,
        encoding: .utf8) != nil
    else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .invalidInput("legacyUnavailableEvidence")
    }
    let issuedAt =
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.wholeSecond(
        input.issuedAt)
    let expiresAt =
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.wholeSecond(
        input.expiresAt)
    guard expiresAt > issuedAt,
      expiresAt.timeIntervalSince(issuedAt) <= 30 * 60
    else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .invalidInput("expiry")
    }
  }

  private static func isSafeAuditString(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      let code = scalar.value
      guard code >= 0x20,
        code != 0x7F,
        !(0x80...0x9F).contains(code)
      else {
        return false
      }
      return !(0x202A...0x202E).contains(code)
        && !(0x2066...0x2069).contains(code)
    }
  }

  private static func requirePristineSuccessor(
    _ successor: TatwoStoredGoalRun,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws {
    guard successor.statusReason == nil,
      successor.latestDispatchCycleEpoch == nil,
      successor.latestDispatchCycleSealID == nil,
      successor.supersession == nil,
      successor.predecessorContractID == nil
    else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .successorNotPristine("goal_metadata")
    }
    guard successor.receipts.allSatisfy({
      $0.receiptID == "goal-tracker" && $0.kind == "goal_tracker"
    }) else {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .successorNotPristine("goal_receipts")
    }
    if dispatchRegistry.hasExecutablePublicationEvidence(
      forContractID: successor.contractID,
      issuedBindingIDs: successor.issuedIdentityBindings?.map(\.id))
    {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .successorNotPristine("dispatch_registry")
    }
    if TatwoRemoteOutboxEvidence.hasPublishedEvidence(
      stateDirectoryURL: goalStore.directoryURL,
      contractID: successor.contractID)
    {
      throw TatwoGoalRevisionBootstrapRecoveryChallengeError
        .successorNotPristine("remote_outbox")
    }
  }
}

private extension String {
  var withSHA256Prefix: String { "sha256:\(self)" }
}
