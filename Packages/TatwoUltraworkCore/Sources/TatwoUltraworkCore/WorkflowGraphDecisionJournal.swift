import CryptoKit
import Foundation

// MARK: - Decision journal (step 3: journal-before-dispatch path, still non-authoritative)
//
// Records the graph's own advisory decision process as an append-only chain:
//   1. pending  — committed input bound before evaluation
//   2. decided  — advisory result after pure evaluation
//
// Divergence log remains a separate ledger that compares graph advisory with the
// existing mechanism. Both may share `observationID` for cross-reference; neither
// overwrites the other. This type intentionally exposes no dispatch, authorize,
// permit-issuance, or registry API.

// MARK: Phase & entry

public enum WorkflowGraphDecisionJournalPhase: String, Codable, Equatable, Sendable {
  case pending
  case decided
}

public struct WorkflowGraphDecisionJournalEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: UInt64
  public let sequence: UInt64
  public let observationID: String
  public let phase: WorkflowGraphDecisionJournalPhase
  public let evaluationTimeUnixMilliseconds: Int64
  public let inputDigest: String
  /// SHA-256 of the previous entry (or genesis for the first entry).
  public let chainDigest: String
  /// SHA-256 of this entry's canonical material (becomes the next chainDigest).
  public let entryDigest: String
  /// Committed advisory input. Required on `pending` so replay can re-evaluate.
  public let committedInput: WorkflowGraphAdvisoryInput<ProductionRealm>?
  /// Advisory outcome. Required on `decided`.
  public let advisoryDecision: WorkflowGraphAdvisoryDecision?
  /// Digest of allow / deny-reasons. Required on `decided`.
  public let reasonsDigest: String?

  public init(
    sequence: UInt64,
    observationID: String,
    phase: WorkflowGraphDecisionJournalPhase,
    evaluationTimeUnixMilliseconds: Int64,
    inputDigest: String,
    chainDigest: String,
    entryDigest: String,
    committedInput: WorkflowGraphAdvisoryInput<ProductionRealm>? = nil,
    advisoryDecision: WorkflowGraphAdvisoryDecision? = nil,
    reasonsDigest: String? = nil
  ) {
    self.id = sequence
    self.sequence = sequence
    self.observationID = observationID
    self.phase = phase
    self.evaluationTimeUnixMilliseconds = evaluationTimeUnixMilliseconds
    self.inputDigest = inputDigest
    self.chainDigest = chainDigest
    self.entryDigest = entryDigest
    self.committedInput = committedInput
    self.advisoryDecision = advisoryDecision
    self.reasonsDigest = reasonsDigest
  }
}

// MARK: Append / errors / replay types

public enum WorkflowGraphDecisionJournalAppendResult: String, Codable, Equatable, Sendable {
  case appended
  case alreadyRecorded
}

public struct WorkflowGraphReplayMismatchDetails: Codable, Equatable, Sendable {
  public let observationID: String
  public let recordedDecision: WorkflowGraphAdvisoryDecision
  public let replayedDecision: WorkflowGraphAdvisoryDecision
  public let recordedReasonsDigest: String
  public let replayedReasonsDigest: String
  public let inputDigest: String

  public init(
    observationID: String,
    recordedDecision: WorkflowGraphAdvisoryDecision,
    replayedDecision: WorkflowGraphAdvisoryDecision,
    recordedReasonsDigest: String,
    replayedReasonsDigest: String,
    inputDigest: String
  ) {
    self.observationID = observationID
    self.recordedDecision = recordedDecision
    self.replayedDecision = replayedDecision
    self.recordedReasonsDigest = recordedReasonsDigest
    self.replayedReasonsDigest = replayedReasonsDigest
    self.inputDigest = inputDigest
  }

  public var summary: String {
    "observationID=\(observationID) recorded=\(Self.canonical(recordedDecision)) "
      + "replayed=\(Self.canonical(replayedDecision)) "
      + "recordedReasonsDigest=\(recordedReasonsDigest) "
      + "replayedReasonsDigest=\(replayedReasonsDigest) "
      + "inputDigest=\(inputDigest)"
  }

  private static func canonical(_ decision: WorkflowGraphAdvisoryDecision) -> String {
    WorkflowGraphDecisionJournalDigest.canonicalDecision(decision)
  }
}

public enum ReplayedDecision: Codable, Equatable, Sendable {
  /// Pending was completed by a decided entry and re-evaluation matched.
  case matched(
    observationID: String,
    decision: WorkflowGraphAdvisoryDecision,
    reasonsDigest: String)
  /// Pending exists without a decided entry (crash / incomplete write path).
  case incomplete(observationID: String, inputDigest: String)

  public var observationID: String {
    switch self {
    case let .matched(observationID, _, _):
      return observationID
    case let .incomplete(observationID, _):
      return observationID
    }
  }

  public var isComplete: Bool {
    if case .matched = self { return true }
    return false
  }
}

public enum WorkflowGraphDecisionJournalError: Error, LocalizedError, Equatable, Sendable {
  case emptyObservationID
  case inputDigestMissing(observationID: String)
  case evaluationTimeMissing(observationID: String)
  case sequenceDiscontinuity(expected: UInt64, actual: UInt64)
  case chainDigestMismatch(expected: String, actual: String, sequence: UInt64)
  case observationConflict(observationID: String)
  case pendingRequired(observationID: String)
  case decidedAlreadyRecorded(observationID: String)
  case committedInputMissing(observationID: String)
  case integrityFailure(String)
  case replayMismatch(details: WorkflowGraphReplayMismatchDetails)

  public var errorDescription: String? {
    switch self {
    case .emptyObservationID:
      return "decision-journal observationID must be non-empty"
    case let .inputDigestMissing(observationID):
      return "decision-journal observation \(observationID) is missing inputDigest"
    case let .evaluationTimeMissing(observationID):
      return "decision-journal observation \(observationID) is missing evaluationTime"
    case let .sequenceDiscontinuity(expected, actual):
      return "decision-journal sequence must be contiguous: expected \(expected), got \(actual)"
    case let .chainDigestMismatch(expected, actual, sequence):
      return
        "decision-journal chainDigest mismatch at sequence \(sequence): expected \(expected), got \(actual)"
    case let .observationConflict(observationID):
      return "decision-journal observation \(observationID) was already recorded with different evidence"
    case let .pendingRequired(observationID):
      return "decision-journal decided requires a prior pending for \(observationID)"
    case let .decidedAlreadyRecorded(observationID):
      return "decision-journal observation \(observationID) already has a decided entry"
    case let .committedInputMissing(observationID):
      return "decision-journal pending for \(observationID) is missing committedInput"
    case let .integrityFailure(detail):
      return "decision-journal integrity failure: \(detail)"
    case let .replayMismatch(details):
      return "decision-journal replayMismatch: \(details.summary)"
    }
  }
}

// MARK: Journal

/// Append-only graph decision journal.
///
/// Public construction starts empty. History hydration is test-only via
/// `init(entries:)`, which validates chainDigest / sequence / observation rules
/// fail-closed before accepting the snapshot.
public struct WorkflowGraphDecisionJournal: Codable, Equatable, Sendable {
  public static let schemaVersion = "WorkflowGraphDecisionJournal/v1"
  public static let genesisChainDigest = WorkflowGraphDecisionJournalDigest.sha256Hex(
    "\(schemaVersion)/genesis")

  private var storage: [WorkflowGraphDecisionJournalEntry]

  private enum CodingKeys: String, CodingKey {
    case entries
  }

  public init() {
    self.storage = []
  }

  /// Internal/test-only history hydration. Production callers must start empty
  /// and append through the guarded pending → decided API.
  init(entries: [WorkflowGraphDecisionJournalEntry]) throws {
    try Self.validateIntegrity(entries)
    self.storage = entries
  }

  /// Public decoding cannot hydrate arbitrary history.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entries = try container.decodeIfPresent(
      [WorkflowGraphDecisionJournalEntry].self,
      forKey: .entries) ?? []
    guard entries.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .entries,
        in: container,
        debugDescription: "public decision-journal decoding cannot hydrate history")
    }
    self.storage = []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(storage, forKey: .entries)
  }

  public var entries: [WorkflowGraphDecisionJournalEntry] { storage }

  public var isEmpty: Bool { storage.isEmpty }

  // MARK: Write path (pending first, then decided)

  /// Append a `pending` record **before** advisory evaluation.
  ///
  /// Binds `observationID`, committed input digest, evaluation time, sequence,
  /// and chainDigest. Does not evaluate and does not dispatch.
  public mutating func beginPending(
    observationID: String,
    input: WorkflowGraphAdvisoryInput<ProductionRealm>,
    sequence: UInt64
  ) throws -> WorkflowGraphDecisionJournalAppendResult {
    let normalizedObservationID = Self.normalizeObservationID(observationID)
    guard !normalizedObservationID.isEmpty else {
      throw WorkflowGraphDecisionJournalError.emptyObservationID
    }
    guard let evaluationTime = input.evaluationTimeUnixMilliseconds else {
      throw WorkflowGraphDecisionJournalError.evaluationTimeMissing(
        observationID: normalizedObservationID)
    }
    let inputDigest = input.inputDigest
    guard !inputDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowGraphDecisionJournalError.inputDigestMissing(
        observationID: normalizedObservationID)
    }

    let chainDigest = expectedChainDigest()
    let entryDigest = WorkflowGraphDecisionJournalDigest.entryDigest(
      sequence: sequence,
      observationID: normalizedObservationID,
      phase: .pending,
      evaluationTimeUnixMilliseconds: evaluationTime,
      inputDigest: inputDigest,
      chainDigest: chainDigest,
      advisoryCanonical: "",
      reasonsDigest: "")

    if let existing = storage.first(where: {
      $0.observationID == normalizedObservationID && $0.phase == .pending
    }) {
      // chainDigest/entryDigest are position-bound; idempotency compares the
      // committed decision payload that the observation originally bound.
      let samePayload =
        existing.sequence == sequence
        && existing.inputDigest == inputDigest
        && existing.evaluationTimeUnixMilliseconds == evaluationTime
        && existing.committedInput == input
      guard samePayload else {
        throw WorkflowGraphDecisionJournalError.observationConflict(
          observationID: normalizedObservationID)
      }
      return .alreadyRecorded
    }

    if storage.contains(where: {
      $0.observationID == normalizedObservationID && $0.phase == .decided
    }) {
      throw WorkflowGraphDecisionJournalError.observationConflict(
        observationID: normalizedObservationID)
    }

    let candidate = WorkflowGraphDecisionJournalEntry(
      sequence: sequence,
      observationID: normalizedObservationID,
      phase: .pending,
      evaluationTimeUnixMilliseconds: evaluationTime,
      inputDigest: inputDigest,
      chainDigest: chainDigest,
      entryDigest: entryDigest,
      committedInput: input,
      advisoryDecision: nil,
      reasonsDigest: nil)
    try appendValidated(candidate)
    return .appended
  }

  /// Append a `decided` record **after** pure advisory evaluation.
  ///
  /// Requires a prior `pending` for the same `observationID`. Stores the
  /// advisory decision and reasons digest. Does not dispatch.
  public mutating func recordDecided(
    observationID: String,
    advisory: WorkflowGraphAdvisoryDecision,
    sequence: UInt64
  ) throws -> WorkflowGraphDecisionJournalAppendResult {
    let normalizedObservationID = Self.normalizeObservationID(observationID)
    guard !normalizedObservationID.isEmpty else {
      throw WorkflowGraphDecisionJournalError.emptyObservationID
    }

    guard
      let pending = storage.last(where: {
        $0.observationID == normalizedObservationID && $0.phase == .pending
      })
    else {
      throw WorkflowGraphDecisionJournalError.pendingRequired(
        observationID: normalizedObservationID)
    }

    let reasonsDigest = WorkflowGraphDecisionJournalDigest.reasonsDigest(for: advisory)
    let advisoryCanonical = WorkflowGraphDecisionJournalDigest.canonicalDecision(advisory)
    let chainDigest = expectedChainDigest()
    let entryDigest = WorkflowGraphDecisionJournalDigest.entryDigest(
      sequence: sequence,
      observationID: normalizedObservationID,
      phase: .decided,
      evaluationTimeUnixMilliseconds: pending.evaluationTimeUnixMilliseconds,
      inputDigest: pending.inputDigest,
      chainDigest: chainDigest,
      advisoryCanonical: advisoryCanonical,
      reasonsDigest: reasonsDigest)

    if let existing = storage.first(where: {
      $0.observationID == normalizedObservationID && $0.phase == .decided
    }) {
      let samePayload =
        existing.sequence == sequence
        && existing.inputDigest == pending.inputDigest
        && existing.evaluationTimeUnixMilliseconds == pending.evaluationTimeUnixMilliseconds
        && existing.advisoryDecision == advisory
        && existing.reasonsDigest?.caseInsensitiveCompare(reasonsDigest) == .orderedSame
      guard samePayload else {
        throw WorkflowGraphDecisionJournalError.observationConflict(
          observationID: normalizedObservationID)
      }
      return .alreadyRecorded
    }

    let candidate = WorkflowGraphDecisionJournalEntry(
      sequence: sequence,
      observationID: normalizedObservationID,
      phase: .decided,
      evaluationTimeUnixMilliseconds: pending.evaluationTimeUnixMilliseconds,
      inputDigest: pending.inputDigest,
      chainDigest: chainDigest,
      entryDigest: entryDigest,
      committedInput: nil,
      advisoryDecision: advisory,
      reasonsDigest: reasonsDigest)
    try appendValidated(candidate)
    return .appended
  }

  /// Journal-first pure advisory evaluation: write `pending`, evaluate, write
  /// `decided`. Still returns only an advisory opinion — never dispatches.
  public mutating func evaluateAndRecord(
    observationID: String,
    input: WorkflowGraphAdvisoryInput<ProductionRealm>,
    pendingSequence: UInt64,
    decidedSequence: UInt64,
    evaluator: WorkflowGraphAdvisoryEvaluator = WorkflowGraphAdvisoryEvaluator()
  ) throws -> WorkflowGraphAdvisoryDecision {
    _ = try beginPending(
      observationID: observationID,
      input: input,
      sequence: pendingSequence)
    let decision = evaluator.evaluate(input)
    _ = try recordDecided(
      observationID: observationID,
      advisory: decision,
      sequence: decidedSequence)
    return decision
  }

  // MARK: Replay

  /// Re-evaluate each decided observation from the journal's committed inputs
  /// and compare against the recorded advisory result.
  ///
  /// - Incomplete (pending without decided) observations are returned as
  ///   `ReplayedDecision.incomplete` and do not throw.
  /// - Any decided observation whose re-evaluation disagrees throws
  ///   `replayMismatch(details:)`.
  public static func replay(
    _ journal: WorkflowGraphDecisionJournal,
    evaluator: WorkflowGraphAdvisoryEvaluator = WorkflowGraphAdvisoryEvaluator()
  ) throws -> [ReplayedDecision] {
    try validateIntegrity(journal.storage)

    var pendingByObservation: [String: WorkflowGraphDecisionJournalEntry] = [:]
    var decidedByObservation: [String: WorkflowGraphDecisionJournalEntry] = [:]
    var observationOrder: [String] = []

    for entry in journal.storage {
      if pendingByObservation[entry.observationID] == nil
        && decidedByObservation[entry.observationID] == nil
      {
        observationOrder.append(entry.observationID)
      }
      switch entry.phase {
      case .pending:
        pendingByObservation[entry.observationID] = entry
      case .decided:
        decidedByObservation[entry.observationID] = entry
      }
    }

    var results: [ReplayedDecision] = []
    for observationID in observationOrder {
      guard let pending = pendingByObservation[observationID] else {
        throw WorkflowGraphDecisionJournalError.integrityFailure(
          "decided without pending for \(observationID)")
      }
      guard let decided = decidedByObservation[observationID] else {
        results.append(
          .incomplete(observationID: observationID, inputDigest: pending.inputDigest))
        continue
      }
      guard let committedInput = pending.committedInput else {
        throw WorkflowGraphDecisionJournalError.committedInputMissing(
          observationID: observationID)
      }
      guard let recordedDecision = decided.advisoryDecision,
        let recordedReasonsDigest = decided.reasonsDigest
      else {
        throw WorkflowGraphDecisionJournalError.integrityFailure(
          "decided entry missing advisory fields for \(observationID)")
      }

      let replayed = evaluator.evaluate(committedInput)
      let replayedReasonsDigest = WorkflowGraphDecisionJournalDigest.reasonsDigest(
        for: replayed)
      if replayed != recordedDecision
        || replayedReasonsDigest.caseInsensitiveCompare(recordedReasonsDigest)
          != .orderedSame
      {
        throw WorkflowGraphDecisionJournalError.replayMismatch(
          details: WorkflowGraphReplayMismatchDetails(
            observationID: observationID,
            recordedDecision: recordedDecision,
            replayedDecision: replayed,
            recordedReasonsDigest: recordedReasonsDigest,
            replayedReasonsDigest: replayedReasonsDigest,
            inputDigest: pending.inputDigest))
      }
      results.append(
        .matched(
          observationID: observationID,
          decision: recordedDecision,
          reasonsDigest: recordedReasonsDigest))
    }
    return results
  }

  public func replay(
    evaluator: WorkflowGraphAdvisoryEvaluator = WorkflowGraphAdvisoryEvaluator()
  ) throws -> [ReplayedDecision] {
    try Self.replay(self, evaluator: evaluator)
  }

  // MARK: Integrity

  static func validateIntegrity(_ entries: [WorkflowGraphDecisionJournalEntry]) throws {
    var previousEntryDigest: String?
    var pendingObservations = Set<String>()
    var decidedObservations = Set<String>()
    var lastSequence: UInt64?

    for entry in entries {
      let normalized = normalizeObservationID(entry.observationID)
      guard normalized == entry.observationID, !normalized.isEmpty else {
        throw WorkflowGraphDecisionJournalError.emptyObservationID
      }
      if entry.inputDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw WorkflowGraphDecisionJournalError.inputDigestMissing(
          observationID: entry.observationID)
      }

      if let lastSequence {
        let (expected, overflow) = lastSequence.addingReportingOverflow(1)
        guard !overflow, entry.sequence == expected else {
          throw WorkflowGraphDecisionJournalError.sequenceDiscontinuity(
            expected: overflow ? UInt64.max : expected,
            actual: entry.sequence)
        }
      }
      lastSequence = entry.sequence

      let expectedChain = previousEntryDigest ?? genesisChainDigest
      guard entry.chainDigest.caseInsensitiveCompare(expectedChain) == .orderedSame else {
        throw WorkflowGraphDecisionJournalError.chainDigestMismatch(
          expected: expectedChain,
          actual: entry.chainDigest,
          sequence: entry.sequence)
      }

      let advisoryCanonical: String
      let reasonsDigest: String
      switch entry.phase {
      case .pending:
        if pendingObservations.contains(entry.observationID) {
          throw WorkflowGraphDecisionJournalError.observationConflict(
            observationID: entry.observationID)
        }
        if decidedObservations.contains(entry.observationID) {
          throw WorkflowGraphDecisionJournalError.integrityFailure(
            "pending after decided for \(entry.observationID)")
        }
        guard entry.committedInput != nil else {
          throw WorkflowGraphDecisionJournalError.committedInputMissing(
            observationID: entry.observationID)
        }
        guard entry.advisoryDecision == nil, entry.reasonsDigest == nil else {
          throw WorkflowGraphDecisionJournalError.integrityFailure(
            "pending must not carry decided fields for \(entry.observationID)")
        }
        if let committed = entry.committedInput {
          guard committed.inputDigest == entry.inputDigest else {
            throw WorkflowGraphDecisionJournalError.integrityFailure(
              "pending inputDigest mismatch for \(entry.observationID)")
          }
          guard committed.evaluationTimeUnixMilliseconds
            == entry.evaluationTimeUnixMilliseconds
          else {
            throw WorkflowGraphDecisionJournalError.integrityFailure(
              "pending evaluationTime mismatch for \(entry.observationID)")
          }
        }
        pendingObservations.insert(entry.observationID)
        advisoryCanonical = ""
        reasonsDigest = ""
      case .decided:
        if !pendingObservations.contains(entry.observationID) {
          throw WorkflowGraphDecisionJournalError.pendingRequired(
            observationID: entry.observationID)
        }
        if decidedObservations.contains(entry.observationID) {
          throw WorkflowGraphDecisionJournalError.observationConflict(
            observationID: entry.observationID)
        }
        guard let decision = entry.advisoryDecision,
          let storedReasons = entry.reasonsDigest
        else {
          throw WorkflowGraphDecisionJournalError.integrityFailure(
            "decided missing advisory fields for \(entry.observationID)")
        }
        guard entry.committedInput == nil else {
          throw WorkflowGraphDecisionJournalError.integrityFailure(
            "decided must not re-store committedInput for \(entry.observationID)")
        }
        let expectedReasons = WorkflowGraphDecisionJournalDigest.reasonsDigest(for: decision)
        guard storedReasons.caseInsensitiveCompare(expectedReasons) == .orderedSame else {
          throw WorkflowGraphDecisionJournalError.integrityFailure(
            "decided reasonsDigest mismatch for \(entry.observationID)")
        }
        decidedObservations.insert(entry.observationID)
        advisoryCanonical = WorkflowGraphDecisionJournalDigest.canonicalDecision(decision)
        reasonsDigest = storedReasons
      }

      let recomputed = WorkflowGraphDecisionJournalDigest.entryDigest(
        sequence: entry.sequence,
        observationID: entry.observationID,
        phase: entry.phase,
        evaluationTimeUnixMilliseconds: entry.evaluationTimeUnixMilliseconds,
        inputDigest: entry.inputDigest,
        chainDigest: entry.chainDigest,
        advisoryCanonical: advisoryCanonical,
        reasonsDigest: reasonsDigest)
      guard recomputed.caseInsensitiveCompare(entry.entryDigest) == .orderedSame else {
        throw WorkflowGraphDecisionJournalError.integrityFailure(
          "entryDigest mismatch at sequence \(entry.sequence)")
      }
      previousEntryDigest = entry.entryDigest
    }
  }

  // MARK: Private helpers

  private mutating func appendValidated(_ candidate: WorkflowGraphDecisionJournalEntry) throws {
    if let last = storage.last {
      let (expected, overflow) = last.sequence.addingReportingOverflow(1)
      guard !overflow, candidate.sequence == expected else {
        throw WorkflowGraphDecisionJournalError.sequenceDiscontinuity(
          expected: overflow ? UInt64.max : expected,
          actual: candidate.sequence)
      }
      guard candidate.chainDigest.caseInsensitiveCompare(last.entryDigest) == .orderedSame else {
        throw WorkflowGraphDecisionJournalError.chainDigestMismatch(
          expected: last.entryDigest,
          actual: candidate.chainDigest,
          sequence: candidate.sequence)
      }
    } else {
      guard
        candidate.chainDigest.caseInsensitiveCompare(Self.genesisChainDigest) == .orderedSame
      else {
        throw WorkflowGraphDecisionJournalError.chainDigestMismatch(
          expected: Self.genesisChainDigest,
          actual: candidate.chainDigest,
          sequence: candidate.sequence)
      }
    }
    storage.append(candidate)
  }

  private func expectedChainDigest() -> String {
    storage.last?.entryDigest ?? Self.genesisChainDigest
  }

  private static func normalizeObservationID(_ observationID: String) -> String {
    observationID.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Digests

enum WorkflowGraphDecisionJournalDigest {
  static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func canonicalDecision(_ decision: WorkflowGraphAdvisoryDecision) -> String {
    switch decision {
    case .allow:
      return "allow"
    case .deny(let reasons):
      // Stable order: preserve recorded reason order (evaluator emits deterministic order).
      return "deny:" + reasons.joined(separator: ",")
    }
  }

  static func reasonsDigest(for decision: WorkflowGraphAdvisoryDecision) -> String {
    sha256Hex(canonicalDecision(decision))
  }

  static func entryDigest(
    sequence: UInt64,
    observationID: String,
    phase: WorkflowGraphDecisionJournalPhase,
    evaluationTimeUnixMilliseconds: Int64,
    inputDigest: String,
    chainDigest: String,
    advisoryCanonical: String,
    reasonsDigest: String
  ) -> String {
    let material = [
      "schema=\(WorkflowGraphDecisionJournal.schemaVersion)",
      "seq=\(sequence)",
      "obs=\(observationID)",
      "phase=\(phase.rawValue)",
      "eval=\(evaluationTimeUnixMilliseconds)",
      "input=\(inputDigest)",
      "chain=\(chainDigest)",
      "advisory=\(advisoryCanonical)",
      "reasons=\(reasonsDigest)",
    ].joined(separator: "|")
    return sha256Hex(material)
  }
}
