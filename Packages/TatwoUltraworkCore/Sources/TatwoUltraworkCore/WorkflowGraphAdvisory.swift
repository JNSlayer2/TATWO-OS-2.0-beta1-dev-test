import CryptoKit
import Foundation

// MARK: - Realm markers

/// Phantom marker for artifacts that belong to the live execution domain.
///
/// The enum has no cases and carries no runtime state.  Its only purpose is to
/// make production and simulation artifacts distinct Swift types.
public enum ProductionRealm: Sendable {}

/// Phantom marker for artifacts that belong to the simulation domain.
public enum SimulationRealm: Sendable {}

/// A realm-bound run identifier.  A `WorkflowRunID<SimulationRealm>` cannot be
/// passed where `WorkflowRunID<ProductionRealm>` is required.
public struct WorkflowRunID<Realm>: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}

// MARK: - Committed dispatch facts

/// The committed contract fact consumed by the advisory evaluator.
public struct WorkflowGraphCommittedContract<Realm>: Codable, Equatable, Sendable {
  public let isValid: Bool
  public let isCommitted: Bool
  public let digest: String

  public init(
    isValid: Bool,
    digest: String = "contract",
    isCommitted: Bool = true
  ) {
    self.isValid = isValid
    self.isCommitted = isCommitted
    self.digest = digest
  }

  public var valid: Bool { isValid }
  public var committed: Bool { isCommitted }
}

/// The committed plan fact consumed by the advisory evaluator.
public struct WorkflowGraphCommittedPlan<Realm>: Codable, Equatable, Sendable {
  public let isValid: Bool
  public let isCommitted: Bool
  public let digest: String

  public init(
    isValid: Bool,
    digest: String = "plan",
    isCommitted: Bool = true
  ) {
    self.isValid = isValid
    self.isCommitted = isCommitted
    self.digest = digest
  }

  public var valid: Bool { isValid }
  public var committed: Bool { isCommitted }
}

/// The committed graph/gate readiness fact.
public struct WorkflowGraphCommittedGates<Realm>: Codable, Equatable, Sendable {
  public let isAccepted: Bool
  public let isCommitted: Bool
  public let digest: String

  public init(
    isAccepted: Bool,
    digest: String = "gates",
    isCommitted: Bool = true
  ) {
    self.isAccepted = isAccepted
    self.isCommitted = isCommitted
    self.digest = digest
  }

  public var accepted: Bool { isAccepted }
  public var committed: Bool { isCommitted }
}

/// The committed Loop Governor fact.  This is observed only; the advisory
/// evaluator never asks the Governor to perform work.
public struct WorkflowGraphCommittedGovernor<Realm>: Codable, Equatable, Sendable {
  public let isGranted: Bool
  public let isCommitted: Bool
  public let digest: String

  public init(
    isGranted: Bool,
    digest: String = "governor",
    isCommitted: Bool = true
  ) {
    self.isGranted = isGranted
    self.isCommitted = isCommitted
    self.digest = digest
  }

  public var granted: Bool { isGranted }
  public var committed: Bool { isCommitted }
}

/// A permit-shaped value used only as an input to the advisory evaluator.
///
/// This type intentionally has no validation, issuance, claim, or dispatch
/// methods.  Permit validation remains a pure comparison against the
/// caller-injected evaluation time.
public struct NodeExecutionPermit<Realm>: Codable, Equatable, Hashable, Sendable {
  public let permitID: UUID
  public let isValid: Bool
  public let isCommitted: Bool
  public let digest: String
  public let issuedAtUnixMilliseconds: Int64?
  public let expiresAtUnixMilliseconds: Int64?

  public init(
    permitID: UUID,
    isValid: Bool,
    digest: String = "permit",
    isCommitted: Bool = true,
    issuedAtUnixMilliseconds: Int64? = nil,
    expiresAtUnixMilliseconds: Int64? = nil
  ) {
    self.permitID = permitID
    self.isValid = isValid
    self.isCommitted = isCommitted
    self.digest = digest
    self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
    self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
  }

  /// Convenience for tests and adapters that already have a stable permit
  /// digest but do not need to expose an identifier.
  public init(
    isValid: Bool,
    digest: String = "permit",
    isCommitted: Bool = true,
    issuedAtUnixMilliseconds: Int64? = nil,
    expiresAtUnixMilliseconds: Int64? = nil
  ) {
    self.init(
      permitID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
      isValid: isValid,
      digest: digest,
      isCommitted: isCommitted,
      issuedAtUnixMilliseconds: issuedAtUnixMilliseconds,
      expiresAtUnixMilliseconds: expiresAtUnixMilliseconds)
  }

  public var valid: Bool { isValid }
  public var committed: Bool { isCommitted }
  public var permitDigest: String { digest }
}

/// All facts needed for a graph advisory decision.  Every field is optional so
/// an adapter cannot accidentally turn an absent committed source into an
/// allow.  Realm is phantom-typed across every fact, and the evaluator below
/// accepts only `WorkflowGraphAdvisoryInput<ProductionRealm>`.
public struct WorkflowGraphAdvisoryInput<Realm>: Codable, Equatable, Sendable {
  public let contract: WorkflowGraphCommittedContract<Realm>?
  public let plan: WorkflowGraphCommittedPlan<Realm>?
  public let gates: WorkflowGraphCommittedGates<Realm>?
  public let governor: WorkflowGraphCommittedGovernor<Realm>?
  public let permit: NodeExecutionPermit<Realm>?
  /// Whether the graph has produced a ready result for this dispatch input.
  /// This is injected by the caller and never inferred from ambient state.
  public let graphReady: Bool?
  /// The point at which permit validity is evaluated.  A missing value is a
  /// hard deny rather than an implicit wall-clock read.
  public let evaluationTimeUnixMilliseconds: Int64?

  /// Alias matching the dispatch vocabulary used by adapters.
  public var dispatchPermit: NodeExecutionPermit<Realm>? { permit }

  public init(
    contract: WorkflowGraphCommittedContract<Realm>? = nil,
    plan: WorkflowGraphCommittedPlan<Realm>? = nil,
    gates: WorkflowGraphCommittedGates<Realm>? = nil,
    governor: WorkflowGraphCommittedGovernor<Realm>? = nil,
    permit: NodeExecutionPermit<Realm>? = nil,
    graphReady: Bool? = nil,
    evaluationTimeUnixMilliseconds: Int64? = nil
  ) {
    self.contract = contract
    self.plan = plan
    self.gates = gates
    self.governor = governor
    self.permit = permit
    self.graphReady = graphReady
    self.evaluationTimeUnixMilliseconds = evaluationTimeUnixMilliseconds
  }

  /// Convenience for a fully committed boolean snapshot.  The explicit
  /// optional booleans preserve the missing-source fail-closed behavior.
  public init(
    contractValid: Bool?,
    planValid: Bool? = nil,
    gatesAccepted: Bool? = nil,
    governorGranted: Bool? = nil,
    dispatchPermitValid: Bool? = nil,
    graphReady: Bool? = nil,
    evaluationTimeUnixMilliseconds: Int64? = nil
  ) {
    self.init(
      contract: contractValid.map {
        WorkflowGraphCommittedContract<Realm>(isValid: $0, digest: "inline-contract")
      },
      plan: planValid.map {
        WorkflowGraphCommittedPlan<Realm>(isValid: $0, digest: "inline-plan")
      },
      gates: gatesAccepted.map {
        WorkflowGraphCommittedGates<Realm>(isAccepted: $0, digest: "inline-gates")
      },
      governor: governorGranted.map {
        WorkflowGraphCommittedGovernor<Realm>(isGranted: $0, digest: "inline-governor")
      },
      permit: dispatchPermitValid.map {
        NodeExecutionPermit<Realm>(
          isValid: $0,
          digest: "inline-permit",
          issuedAtUnixMilliseconds: 0,
          expiresAtUnixMilliseconds: Int64.max)
      },
      graphReady: graphReady,
      evaluationTimeUnixMilliseconds: evaluationTimeUnixMilliseconds)
  }

  /// Stable, non-ambient summary material used by divergence records.
  public var canonicalSummary: String {
    let contractSummary = contract.map {
      "\($0.isCommitted):\($0.isValid):\($0.digest)"
    } ?? "<missing>"
    let planSummary = plan.map {
      "\($0.isCommitted):\($0.isValid):\($0.digest)"
    } ?? "<missing>"
    let gatesSummary = gates.map {
      "\($0.isCommitted):\($0.isAccepted):\($0.digest)"
    } ?? "<missing>"
    let governorSummary = governor.map {
      "\($0.isCommitted):\($0.isGranted):\($0.digest)"
    } ?? "<missing>"
    let permitSummary = permit.map {
      let issued = $0.issuedAtUnixMilliseconds.map(String.init) ?? "<nil>"
      let expires = $0.expiresAtUnixMilliseconds.map(String.init) ?? "<nil>"
      return
        "\($0.permitID.uuidString):\($0.isCommitted):\($0.isValid):\($0.digest):\(issued):\(expires)"
    } ?? "<missing>"
    let graphReadySummary = graphReady.map(String.init) ?? "<missing>"
    let evaluationTimeSummary = evaluationTimeUnixMilliseconds.map(String.init) ?? "<missing>"
    return [
      "realm=\(String(describing: Realm.self))",
      "contract=\(contractSummary)",
      "plan=\(planSummary)",
      "gates=\(gatesSummary)",
      "governor=\(governorSummary)",
      "permit=\(permitSummary)",
      "graphReady=\(graphReadySummary)",
      "evaluationTime=\(evaluationTimeSummary)",
    ].joined(separator: "|")
  }

  public var inputDigest: String {
    WorkflowGraphAdvisoryDigest.sha256Hex(canonicalSummary)
  }
}

public typealias ProductionWorkflowGraphAdvisoryInput =
  WorkflowGraphAdvisoryInput<ProductionRealm>
public typealias SimulationWorkflowGraphAdvisoryInput =
  WorkflowGraphAdvisoryInput<SimulationRealm>
public typealias WorkflowGraphCommittedDispatchInput<Realm> =
  WorkflowGraphAdvisoryInput<Realm>

// MARK: - Advisory decision

public enum WorkflowGraphAdvisoryDecision: Codable, Equatable, Sendable {
  case allow
  case deny(reasons: [String])

  public var isAllowed: Bool {
    if case .allow = self { return true }
    return false
  }

  public var reasons: [String] {
    if case .deny(let reasons) = self { return reasons }
    return []
  }

  public static func deny(_ reasons: [String]) -> Self {
    .deny(reasons: reasons)
  }
}

/// Actual dispatch outcome observed from the existing mechanism.  This is a
/// value for comparison only; WorkflowGraph does not receive a dispatch hook.
public enum WorkflowGraphDispatchDecision: Codable, Equatable, Sendable {
  case allow
  case deny

  public init(allowed: Bool) {
    self = allowed ? .allow : .deny
  }

  public var isAllowed: Bool {
    if case .allow = self { return true }
    return false
  }
}

public enum WorkflowGraphAdvisoryReason {
  public static let missingContract = "missing_contract"
  public static let contractNotCommitted = "contract_not_committed"
  public static let contractInvalid = "contract_invalid"
  public static let contractDigestMissing = "contract_digest_missing"
  public static let missingPlan = "missing_plan"
  public static let planNotCommitted = "plan_not_committed"
  public static let planInvalid = "plan_invalid"
  public static let planDigestMissing = "plan_digest_missing"
  public static let missingGraphReadiness = "missing_graph_readiness"
  public static let graphNotReady = "graph_not_ready"
  public static let missingGates = "missing_gates"
  public static let gatesNotCommitted = "gates_not_committed"
  public static let gatesNotAccepted = "gates_not_accepted"
  public static let gatesDigestMissing = "gates_digest_missing"
  public static let missingGovernor = "missing_governor"
  public static let governorNotCommitted = "governor_not_committed"
  public static let governorNotGranted = "governor_not_granted"
  public static let governorDigestMissing = "governor_digest_missing"
  public static let missingPermit = "missing_permit"
  public static let permitNotCommitted = "permit_not_committed"
  public static let permitInvalid = "permit_invalid"
  public static let permitDigestMissing = "permit_digest_missing"
  public static let missingEvaluationTime = "missing_evaluation_time"
  public static let permitIssuedInFuture = "permit_issued_in_future"
  public static let permitExpired = "permit_expired"
  public static let permitIssueTimeMissing = "permit_issue_time_missing"
  public static let permitExpiryMissing = "permit_expiry_missing"
}

// MARK: - Pure evaluator

/// Production-only advisory evaluator.  It consumes an immutable, caller-
/// supplied snapshot and returns an opinion.  It has no dispatch, lease,
/// registry, file, process, or clock capability.
public struct WorkflowGraphAdvisoryEvaluator: Sendable {
  public init() {}

  public func evaluate(
    _ input: WorkflowGraphAdvisoryInput<ProductionRealm>
  ) -> WorkflowGraphAdvisoryDecision {
    var reasons: [String] = []

    guard let contract = input.contract else {
      reasons.append(WorkflowGraphAdvisoryReason.missingContract)
      return finish(reasons)
    }
    if !contract.isCommitted { reasons.append(WorkflowGraphAdvisoryReason.contractNotCommitted) }
    if !contract.isValid { reasons.append(WorkflowGraphAdvisoryReason.contractInvalid) }
    if contract.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append(WorkflowGraphAdvisoryReason.contractDigestMissing)
    }

    guard let plan = input.plan else {
      reasons.append(WorkflowGraphAdvisoryReason.missingPlan)
      return finish(reasons)
    }
    if !plan.isCommitted { reasons.append(WorkflowGraphAdvisoryReason.planNotCommitted) }
    if !plan.isValid { reasons.append(WorkflowGraphAdvisoryReason.planInvalid) }
    if plan.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append(WorkflowGraphAdvisoryReason.planDigestMissing)
    }

    guard let graphReady = input.graphReady else {
      reasons.append(WorkflowGraphAdvisoryReason.missingGraphReadiness)
      return finish(reasons)
    }
    if !graphReady { reasons.append(WorkflowGraphAdvisoryReason.graphNotReady) }

    guard let gates = input.gates else {
      reasons.append(WorkflowGraphAdvisoryReason.missingGates)
      return finish(reasons)
    }
    if !gates.isCommitted { reasons.append(WorkflowGraphAdvisoryReason.gatesNotCommitted) }
    if !gates.isAccepted { reasons.append(WorkflowGraphAdvisoryReason.gatesNotAccepted) }
    if gates.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append(WorkflowGraphAdvisoryReason.gatesDigestMissing)
    }

    guard let governor = input.governor else {
      reasons.append(WorkflowGraphAdvisoryReason.missingGovernor)
      return finish(reasons)
    }
    if !governor.isCommitted { reasons.append(WorkflowGraphAdvisoryReason.governorNotCommitted) }
    if !governor.isGranted { reasons.append(WorkflowGraphAdvisoryReason.governorNotGranted) }
    if governor.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append(WorkflowGraphAdvisoryReason.governorDigestMissing)
    }

    guard let permit = input.permit else {
      reasons.append(WorkflowGraphAdvisoryReason.missingPermit)
      return finish(reasons)
    }
    if !permit.isCommitted { reasons.append(WorkflowGraphAdvisoryReason.permitNotCommitted) }
    if !permit.isValid { reasons.append(WorkflowGraphAdvisoryReason.permitInvalid) }
    if permit.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      reasons.append(WorkflowGraphAdvisoryReason.permitDigestMissing)
    }

    guard let evaluationTime = input.evaluationTimeUnixMilliseconds else {
      reasons.append(WorkflowGraphAdvisoryReason.missingEvaluationTime)
      return finish(reasons)
    }
    guard let issuedAt = permit.issuedAtUnixMilliseconds else {
      reasons.append(WorkflowGraphAdvisoryReason.permitIssueTimeMissing)
      return finish(reasons)
    }
    guard let expiresAt = permit.expiresAtUnixMilliseconds else {
      reasons.append(WorkflowGraphAdvisoryReason.permitExpiryMissing)
      return finish(reasons)
    }
    if issuedAt > evaluationTime {
      reasons.append(WorkflowGraphAdvisoryReason.permitIssuedInFuture)
    }
    if evaluationTime >= expiresAt {
      reasons.append(WorkflowGraphAdvisoryReason.permitExpired)
    }

    return finish(reasons)
  }

  public func evaluate(
    input: WorkflowGraphAdvisoryInput<ProductionRealm>
  ) -> WorkflowGraphAdvisoryDecision {
    evaluate(input)
  }

  public static func evaluate(
    _ input: WorkflowGraphAdvisoryInput<ProductionRealm>
  ) -> WorkflowGraphAdvisoryDecision {
    Self().evaluate(input)
  }

  public static func evaluate(
    input: WorkflowGraphAdvisoryInput<ProductionRealm>
  ) -> WorkflowGraphAdvisoryDecision {
    Self().evaluate(input)
  }

  private func finish(_ reasons: [String]) -> WorkflowGraphAdvisoryDecision {
    reasons.isEmpty ? .allow : .deny(reasons: reasons)
  }
}

// MARK: - Divergence log

public enum WorkflowGraphDivergenceState: String, Codable, Equatable, Sendable {
  case agree
  case graphStricter
  case graphLooser
}

public struct WorkflowGraphDivergenceEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: UInt64
  public let observationID: String
  public let sequence: UInt64
  public let recordedAtUnixMilliseconds: Int64
  public let actualDecision: WorkflowGraphDispatchDecision
  public let graphAdvisory: WorkflowGraphAdvisoryDecision
  public let state: WorkflowGraphDivergenceState
  public let inputDigest: String

  public var actual: WorkflowGraphDispatchDecision { actualDecision }
  public var advisory: WorkflowGraphAdvisoryDecision { graphAdvisory }
  public var divergence: WorkflowGraphDivergenceState { state }

  public init(
    observationID: String,
    sequence: UInt64,
    recordedAtUnixMilliseconds: Int64,
    actualDecision: WorkflowGraphDispatchDecision,
    graphAdvisory: WorkflowGraphAdvisoryDecision,
    inputDigest: String
  ) {
    self.id = sequence
    self.observationID = observationID
    self.sequence = sequence
    self.recordedAtUnixMilliseconds = recordedAtUnixMilliseconds
    self.actualDecision = actualDecision
    self.graphAdvisory = graphAdvisory
    self.state = Self.compare(actual: actualDecision, advisory: graphAdvisory)
    self.inputDigest = inputDigest
  }

  public static func compare(
    actual: WorkflowGraphDispatchDecision,
    advisory: WorkflowGraphAdvisoryDecision
  ) -> WorkflowGraphDivergenceState {
    switch (actual.isAllowed, advisory.isAllowed) {
    case (true, true), (false, false):
      return .agree
    case (true, false):
      return .graphStricter
    case (false, true):
      return .graphLooser
    }
  }
}

public enum WorkflowGraphDivergenceAppendResult: String, Codable, Equatable, Sendable {
  case appended
  case alreadyRecorded
}

public enum WorkflowGraphDivergenceLogError: Error, LocalizedError, Equatable, Sendable {
  case emptyObservationID
  case inputDigestMissing(observationID: String)
  case sequenceDiscontinuity(expected: UInt64, actual: UInt64)
  case observationConflict(observationID: String)

  public var errorDescription: String? {
    switch self {
    case .emptyObservationID:
      return "divergence observationID must be non-empty"
    case let .inputDigestMissing(observationID):
      return "divergence observation \(observationID) is missing inputDigest"
    case let .sequenceDiscontinuity(expected, actual):
      return "divergence sequence must be contiguous: expected \(expected), got \(actual)"
    case let .observationConflict(observationID):
      return "divergence observation \(observationID) was already recorded with different evidence"
    }
  }
}

public struct WorkflowGraphDivergenceStatistics: Codable, Equatable, Sendable {
  public let total: Int
  public let distinctObservationCount: Int
  public let agree: Int
  public let graphStricter: Int
  public let graphLooser: Int

  public init(
    total: Int,
    distinctObservationCount: Int,
    agree: Int,
    graphStricter: Int,
    graphLooser: Int
  ) {
    self.total = total
    self.distinctObservationCount = distinctObservationCount
    self.agree = agree
    self.graphStricter = graphStricter
    self.graphLooser = graphLooser
  }

  public var totalCount: Int { total }
  public var distinctObservationCountValue: Int { distinctObservationCount }
  public var agreeCount: Int { agree }
  public var graphStricterCount: Int { graphStricter }
  public var graphLooserCount: Int { graphLooser }
  public var dangerousGraphLooserCount: Int { graphLooser }
  public var divergenceCount: Int { graphStricter + graphLooser }
  /// Human-facing summary with the dangerous direction called out explicitly.
  public var summary: String {
    "total=\(total) agree=\(agree) graphStricter=\(graphStricter) GRAPH_LOOSER=\(graphLooser)"
  }
}

/// Append-only comparison ledger for the dual-track observation period.
public struct WorkflowGraphDivergenceLog: Codable, Equatable, Sendable {
  private var storage: [WorkflowGraphDivergenceEntry]
  private enum CodingKeys: String, CodingKey {
    case entries
  }

  public init() {
    self.storage = []
  }

  /// Internal/test-only history hydration. Production callers must start empty
  /// and append observations through the guarded API.
  init(entries: [WorkflowGraphDivergenceEntry]) {
    self.storage = entries
  }

  /// Public decoding cannot hydrate arbitrary history. Durable/test fixtures
  /// must use the internal history initializer; production starts empty and
  /// appends through the guarded API.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entries = try container.decodeIfPresent(
      [WorkflowGraphDivergenceEntry].self,
      forKey: .entries) ?? []
    guard entries.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .entries,
        in: container,
        debugDescription: "public divergence-log decoding cannot hydrate history")
    }
    self.storage = []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(storage, forKey: .entries)
  }

  public var entries: [WorkflowGraphDivergenceEntry] { storage }

  public var statistics: WorkflowGraphDivergenceStatistics {
    var agree = 0
    var stricter = 0
    var looser = 0
    for entry in storage {
      switch entry.state {
      case .agree: agree += 1
      case .graphStricter: stricter += 1
      case .graphLooser: looser += 1
      }
    }
    return WorkflowGraphDivergenceStatistics(
      total: storage.count,
      distinctObservationCount: Set(storage.map(\.observationID)).count,
      agree: agree,
      graphStricter: stricter,
      graphLooser: looser)
  }

  public var graphLooserCount: Int { statistics.graphLooser }

  /// Append one observation.  Sequence and timestamp are supplied by the
  /// caller so this operation is deterministic and replayable.
  public mutating func append(
    observationID: String,
    actualDecision: WorkflowGraphDispatchDecision,
    advisory: WorkflowGraphAdvisoryDecision,
    input: WorkflowGraphAdvisoryInput<ProductionRealm>,
    sequence: UInt64,
    recordedAtUnixMilliseconds: Int64
  ) throws -> WorkflowGraphDivergenceAppendResult {
    let normalizedObservationID = observationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedObservationID.isEmpty else {
      throw WorkflowGraphDivergenceLogError.emptyObservationID
    }
    let inputDigest = input.inputDigest
    guard !inputDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowGraphDivergenceLogError.inputDigestMissing(
        observationID: normalizedObservationID)
    }

    let candidate = WorkflowGraphDivergenceEntry(
      observationID: normalizedObservationID,
      sequence: sequence,
      recordedAtUnixMilliseconds: recordedAtUnixMilliseconds,
      actualDecision: actualDecision,
      graphAdvisory: advisory,
      inputDigest: inputDigest)

    if let existing = storage.first(where: { $0.observationID == normalizedObservationID }) {
      guard existing == candidate else {
        throw WorkflowGraphDivergenceLogError.observationConflict(
          observationID: normalizedObservationID)
      }
      return .alreadyRecorded
    }

    if let last = storage.last {
      let (expected, overflow) = last.sequence.addingReportingOverflow(1)
      guard !overflow, sequence == expected else {
        throw WorkflowGraphDivergenceLogError.sequenceDiscontinuity(
          expected: overflow ? UInt64.max : expected,
          actual: sequence)
      }
    }
    storage.append(candidate)
    return .appended
  }

  public mutating func append(
    observationID: String,
    actualAllowed: Bool,
    advisory: WorkflowGraphAdvisoryDecision,
    input: WorkflowGraphAdvisoryInput<ProductionRealm>,
    sequence: UInt64,
    recordedAtUnixMilliseconds: Int64
  ) throws -> WorkflowGraphDivergenceAppendResult {
    try append(
      observationID: observationID,
      actualDecision: WorkflowGraphDispatchDecision(allowed: actualAllowed),
      advisory: advisory,
      input: input,
      sequence: sequence,
      recordedAtUnixMilliseconds: recordedAtUnixMilliseconds)
  }

  public mutating func append(
    observationID: String,
    actual: WorkflowGraphAdvisoryDecision,
    advisory: WorkflowGraphAdvisoryDecision,
    input: WorkflowGraphAdvisoryInput<ProductionRealm>,
    sequence: UInt64,
    recordedAtUnixMilliseconds: Int64
  ) throws -> WorkflowGraphDivergenceAppendResult {
    try append(
      observationID: observationID,
      actualDecision: WorkflowGraphDispatchDecision(allowed: actual.isAllowed),
      advisory: advisory,
      input: input,
      sequence: sequence,
      recordedAtUnixMilliseconds: recordedAtUnixMilliseconds)
  }
}

private enum WorkflowGraphAdvisoryDigest {
  static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
