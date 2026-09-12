import Foundation

public enum AgentInvocationRecoveryDisposition: Sendable, Equatable {
  case notSeen
  case retryAllowed
  case alreadyCompleted
  case outcomeUnknown
}

public enum AgentVerifiedInvocationAction: Sendable, Equatable {
  case execute
  case skipVerified
}

public enum AgentInvocationReconciliation: Sendable, Equatable {
  case provenNotExecuted
  case provenExecuted
  case stillUnknown
}

public enum AgentOutcomeUnknownDecision: Sendable, Equatable {
  case executeNew(invocationID: String)
  case retrySame(invocationID: String)
  case acceptReconciledExecution(invocationID: String)
  case pendingHumanGate(invocationID: String)
}

public enum AgentOutcomeUnknownResolver {
  public static func resolve(
    originalInvocationID: String,
    retrySafe: Bool,
    reconciliation: AgentInvocationReconciliation,
    newInvocationID: () -> String
  ) -> AgentOutcomeUnknownDecision {
    switch reconciliation {
    case .provenNotExecuted:
      return .executeNew(invocationID: newInvocationID())
    case .provenExecuted:
      return .acceptReconciledExecution(invocationID: originalInvocationID)
    case .stillUnknown where retrySafe:
      // The same invocation ID is mandatory so a retry-safe tool can
      // deduplicate instead of creating a second side effect.
      return .retrySame(invocationID: originalInvocationID)
    case .stillUnknown:
      return .pendingHumanGate(invocationID: originalInvocationID)
    }
  }
}

public struct AgentKernelRecovery: Sendable, Equatable {
  public let checkpoint: AgentKernelCheckpoint?
  public let nextStep: Int
  public let pendingApprovalID: String?
  private let invocationDispositions: [
    String: AgentInvocationRecoveryDisposition
  ]
  private let invocationEvidence: [String: AgentInvocationEvidence]

  init(
    checkpoint: AgentKernelCheckpoint?,
    pendingApprovalID: String?,
    invocationDispositions: [
      String: AgentInvocationRecoveryDisposition
    ],
    invocationEvidence: [String: AgentInvocationEvidence]
  ) {
    self.checkpoint = checkpoint
    nextStep = (checkpoint?.completedStep ?? 0) + 1
    self.pendingApprovalID = pendingApprovalID
    self.invocationDispositions = invocationDispositions
    self.invocationEvidence = invocationEvidence
  }

  public func evidence(for invocationID: String) -> AgentInvocationEvidence? {
    invocationEvidence[invocationID]
  }

  public func disposition(
    for invocationID: String
  ) -> AgentInvocationRecoveryDisposition {
    invocationDispositions[invocationID] ?? .notSeen
  }
}

public final class AgentKernelRun: @unchecked Sendable {
  public let runID: String
  private let store: AgentKernelEventLog
  private let lock = NSLock()

  public init(
    runID: String,
    store: AgentKernelEventLog
  ) {
    self.runID = runID
    self.store = store
  }

  public func start() throws {
    try append(.runStarted)
  }

  public func commitCheckpoint(
    _ checkpoint: AgentKernelCheckpoint
  ) throws {
    try append(.checkpointCommitted(checkpoint))
    let lastSequence = try requiredLastSequence()
    try store.saveSnapshot(
      AgentKernelSnapshot(
        runID: runID,
        lastEventSequence: lastSequence,
        checkpoint: checkpoint))
  }

  public func beginInvocation(
    id: String,
    sideEffecting: Bool
  ) throws {
    let recovery = try recover(markUnknownOutcomes: false)
    switch recovery.disposition(for: id) {
    case .notSeen, .retryAllowed:
      try append(
        .invocationStarted(
          id: id,
          sideEffecting: sideEffecting))
    case .alreadyCompleted:
      return
    case .outcomeUnknown:
      throw AgentKernelRunError.invocationOutcomeUnknown(id)
    }
  }

  public func beginVerifiedInvocation(
    id: String,
    sideEffecting: Bool,
    argsHash: String,
    expectedResultDigest: String,
    expectedArtifactDigests: [String]
  ) throws -> AgentVerifiedInvocationAction {
    let recovery = try recover(markUnknownOutcomes: false)
    switch recovery.disposition(for: id) {
    case .notSeen, .retryAllowed:
      try append(.invocationStarted(id: id, sideEffecting: sideEffecting))
      try append(.invocationArgsRecorded(id: id, argsHash: argsHash))
      return .execute
    case .alreadyCompleted:
      guard recovery.evidence(for: id) == AgentInvocationEvidence(
        argsHash: argsHash,
        resultDigest: expectedResultDigest,
        artifactDigests: expectedArtifactDigests)
      else {
        throw AgentKernelRunError.completedInvocationEvidenceMismatch(id)
      }
      return .skipVerified
    case .outcomeUnknown:
      throw AgentKernelRunError.invocationOutcomeUnknown(id)
    }
  }

  public func completeInvocation(id: String) throws {
    try append(.invocationCompleted(id: id))
  }

  public func completeInvocation(
    id: String,
    resultDigest: String,
    artifactDigests: [String]
  ) throws {
    let events = try store.read(runID: runID)
    guard let argsHash = events.reversed().compactMap({ event -> String? in
      guard case let .invocationArgsRecorded(recordedID, hash) = event.payload,
            recordedID == id
      else { return nil }
      return hash
    }).first else {
      throw AgentKernelRunError.missingInvocationArgsHash(id)
    }
    try append(
      .invocationEvidenceRecorded(
        id: id,
        evidence: AgentInvocationEvidence(
          argsHash: argsHash,
          resultDigest: resultDigest,
          artifactDigests: artifactDigests)))
    try append(.invocationCompleted(id: id))
  }

  public func requestApproval(id: String) throws {
    try append(.approvalRequested(id: id))
  }

  public func resolveApproval(id: String) throws {
    let recovery = try recover(markUnknownOutcomes: false)
    guard recovery.pendingApprovalID == id else {
      throw AgentKernelRunError.approvalMismatch
    }
    try append(.approvalResolved(id: id))
  }

  public func recordUsage(
    _ report: AgentTransportUsageReport
  ) throws {
    let usage = report.canonical
    try append(.usageReported(usage))
    if usage.source == .unavailable {
      throw AgentKernelRunError.usageUnavailable
    }
  }

  public func stop(reason: AgentKernelStopReason) throws {
    try append(.stopped(reason: reason.rawValue))
  }

  public func attestTurn(
    requested: String,
    actual: String,
    effort: String
  ) throws {
    try append(
      .turnAttested(
        AgentKernelAttestation(
          requested: requested,
          actual: actual,
          effort: effort)))
  }

  @discardableResult
  public func changeTransport(
    to transport: String
  ) throws -> AgentKernelCheckpoint {
    let events = try store.read(runID: runID)
    guard case let .checkpointCommitted(checkpoint)? = events.last?.payload else {
      throw AgentKernelRunError.notAtTurnBoundary
    }

    var attestation: AgentKernelAttestation?
    attestationSearch: for event in events.dropLast().reversed() {
      switch event.payload {
      case let .turnAttested(value):
        attestation = value
      case .checkpointCommitted, .transportChanged:
        break attestationSearch
      default:
        continue
      }
      if attestation != nil {
        break attestationSearch
      }
    }
    guard let attestation else {
      throw AgentKernelRunError.missingTurnAttestation
    }

    try append(
      .transportChanged(
        from: attestation.actual,
        to: transport))
    return checkpoint
  }

  public func recover() throws -> AgentKernelRecovery {
    try recover(markUnknownOutcomes: true)
  }

  private func recover(
    markUnknownOutcomes: Bool
  ) throws -> AgentKernelRecovery {
    let events = try store.readRecoverablePrefix(runID: runID)
    var checkpoint: AgentKernelCheckpoint?
    var dispositions: [
      String: AgentInvocationRecoveryDisposition
    ] = [:]
    var unresolvedSideEffects: Set<String> = []
    var pendingApprovalID: String?
    var evidence: [String: AgentInvocationEvidence] = [:]

    for event in events {
      switch event.payload {
      case let .checkpointCommitted(committed):
        checkpoint = committed
      case let .invocationStarted(id, sideEffecting):
        dispositions[id] = sideEffecting
          ? .outcomeUnknown
          : .retryAllowed
        if sideEffecting {
          unresolvedSideEffects.insert(id)
        }
      case let .invocationCompleted(id):
        dispositions[id] = .alreadyCompleted
        unresolvedSideEffects.remove(id)
      case let .invocationEvidenceRecorded(id, value):
        evidence[id] = value
      case let .invocationOutcomeUnknown(id):
        dispositions[id] = .outcomeUnknown
        unresolvedSideEffects.remove(id)
      case let .approvalRequested(id):
        pendingApprovalID = id
      case let .approvalResolved(id):
        if pendingApprovalID == id {
          pendingApprovalID = nil
        }
      default:
        break
      }
    }

    if markUnknownOutcomes {
      for id in unresolvedSideEffects.sorted() {
        try append(.invocationOutcomeUnknown(id: id))
      }
    }
    return AgentKernelRecovery(
      checkpoint: checkpoint,
      pendingApprovalID: pendingApprovalID,
      invocationDispositions: dispositions,
      invocationEvidence: evidence)
  }

  private func append(
    _ payload: AgentKernelEventPayload
  ) throws {
    try lock.withLock {
      let sequence = (try store.lastEvent(runID: runID)?
        .eventSequence ?? 0) + 1
      try store.append(
        AgentKernelEvent(
          runID: runID,
          runSequence: sequence,
          eventSequence: sequence,
          payload: payload))
    }
  }

  private func requiredLastSequence() throws -> Int {
    guard let sequence = try store.lastEvent(runID: runID)?
      .eventSequence
    else {
      throw AgentKernelRunError.runNotStarted
    }
    return sequence
  }
}

public enum AgentKernelRunError: Error, Sendable, Equatable {
  case runNotStarted
  case invocationOutcomeUnknown(String)
  case completedInvocationEvidenceMismatch(String)
  case missingInvocationArgsHash(String)
  case approvalMismatch
  case usageUnavailable
  case notAtTurnBoundary
  case missingTurnAttestation
}
