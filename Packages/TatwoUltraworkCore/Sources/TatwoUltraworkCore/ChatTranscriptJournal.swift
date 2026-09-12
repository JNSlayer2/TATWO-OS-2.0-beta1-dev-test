import Foundation

/// Provider-neutral item categories for a durable chat transcript.
///
/// `reasoningSummary` is intentionally a summary-only surface. Adapters must
/// never place private chain-of-thought, hidden reasoning tokens, or raw
/// reasoning deltas in `title` or `summary`. Reasoning attributes are stripped
/// at construction so there is no generic structured payload escape hatch.
public enum ChatTranscriptItemKindV1:
  String, Codable, CaseIterable, Sendable, Equatable, Hashable
{
  case message
  case reasoningSummary
  case command
  case fileChange
  case search
  case tool
  case remoteJob
  case approval
  case result
  case error
}

public enum ChatTranscriptLifecyclePhaseV1:
  String, Codable, CaseIterable, Sendable, Equatable, Hashable
{
  case pending
  case running
  case completed
  case failed
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .pending, .running:
      false
    case .completed, .failed, .cancelled:
      true
    }
  }
}

/// Provider evidence state for one turn.
///
/// `forwardedAwaitingProvider` means the requested effort was placed on the
/// outbound provider request. It is deliberately not proof that the provider
/// honored it. Only `verified` may accompany a non-nil
/// `effectiveEffortAttestation`.
public enum ChatTranscriptAttestationOutcomeV1:
  String, Codable, CaseIterable, Sendable, Equatable, Hashable
{
  case unknown
  case requested
  case forwardedAwaitingProvider = "forwarded_awaiting_provider"
  case verified
  case fallbackObserved = "fallback_observed"
  case unsupportedEffort = "unsupported_effort"
  case providerEvidenceMissing = "provider_evidence_missing"
  case providerMismatch = "provider_mismatch"
}

/// Normalization metadata retained across Codex, Claude, Fable, Grok, and
/// future provider adapters.
public struct ChatTranscriptSourceMetadataV1:
  Codable, Sendable, Equatable, Hashable
{
  /// Stable provider/source family, for example `codex` or `claude`.
  public let source: String
  /// Provider model identifier as observed by the adapter.
  public let model: String
  /// Native runtime/transport, for example `app-server`, `cli`, or `gateway`.
  public let runtime: String
  public let sessionID: String?
  public let runID: String?
  public let attempt: UInt64?
  /// Exact cross-process runner incarnation. A missing value is legacy or
  /// authority-unknown and must never be treated as reclaim permission.
  public let runnerInstanceID: UUID?
  /// Registry revision observed when this journal source was written.
  public let runnerRevision: UInt64?
  /// Contract/UI request identity captured before enqueue or dispatch.
  public let requestedModelID: String?
  /// Provider-facing model argument captured before enqueue or dispatch.
  public let requestedVendorModelID: String?
  /// Canonical model observed from provider response evidence.
  public let actualCanonicalModel: String?
  /// Vendor model observed from provider response evidence.
  public let actualVendorModel: String?
  /// Contract-bound request, or UI selection only when no contract binding matched.
  public let requestedEffort: TatwoCodexReasoningEffort?
  /// Effort actually placed on the outbound provider request.
  public let forwardedEffort: TatwoCodexReasoningEffort?
  /// Provider-attested effective effort. Never infer this from argv or config.
  public let effectiveEffortAttestation: TatwoCodexReasoningEffort?
  /// Number of provider-observed model fallbacks for this turn.
  public let fallbackCount: UInt?
  public let attestationOutcome: ChatTranscriptAttestationOutcomeV1?
  public let providerResponseID: String?
  public let providerSessionID: String?

  public init(
    source: String,
    model: String,
    runtime: String,
    sessionID: String? = nil,
    runID: String? = nil,
    attempt: UInt64? = nil,
    runnerInstanceID: UUID? = nil,
    runnerRevision: UInt64? = nil,
    requestedModelID: String? = nil,
    requestedVendorModelID: String? = nil,
    actualCanonicalModel: String? = nil,
    actualVendorModel: String? = nil,
    requestedEffort: TatwoCodexReasoningEffort? = nil,
    forwardedEffort: TatwoCodexReasoningEffort? = nil,
    effectiveEffortAttestation: TatwoCodexReasoningEffort? = nil,
    fallbackCount: UInt? = nil,
    attestationOutcome: ChatTranscriptAttestationOutcomeV1? = nil,
    providerResponseID: String? = nil,
    providerSessionID: String? = nil
  ) {
    self.source = source
    self.model = model
    self.runtime = runtime
    self.sessionID = sessionID
    self.runID = runID
    self.attempt = attempt
    self.runnerInstanceID = runnerInstanceID
    self.runnerRevision = runnerRevision
    self.requestedModelID = requestedModelID
    self.requestedVendorModelID = requestedVendorModelID
    self.actualCanonicalModel = actualCanonicalModel
    self.actualVendorModel = actualVendorModel
    self.requestedEffort = requestedEffort
    self.forwardedEffort = forwardedEffort
    self.effectiveEffortAttestation =
      attestationOutcome == .verified ? effectiveEffortAttestation : nil
    self.fallbackCount = fallbackCount
    self.attestationOutcome = attestationOutcome
    self.providerResponseID = providerResponseID
    self.providerSessionID = providerSessionID
  }
}

/// One normalized provider event.
///
/// `sequence` is scoped to `(threadID, turnID)` and must increase strictly.
/// `eventID` is journal-global so reconnect replay can be deduplicated before
/// stale-sequence checks.
public struct ChatTranscriptEventV1:
  Codable, Sendable, Equatable, Hashable, Identifiable
{
  public var id: String { eventID }

  public let eventID: String
  public let threadID: String
  public let turnID: String
  public let itemID: String
  public let sequence: UInt64
  public let kind: ChatTranscriptItemKindV1
  public let phase: ChatTranscriptLifecyclePhaseV1
  public let source: ChatTranscriptSourceMetadataV1
  public let sourceEventType: String?
  public let occurredAt: Date
  public let title: String
  /// User-visible/provider-supplied summary. Never private chain-of-thought.
  public let summary: String?
  /// Small provider-neutral facts such as command exit code or changed path.
  public let attributes: [String: String]

  public init(
    eventID: String,
    threadID: String,
    turnID: String,
    itemID: String,
    sequence: UInt64,
    kind: ChatTranscriptItemKindV1,
    phase: ChatTranscriptLifecyclePhaseV1,
    source: ChatTranscriptSourceMetadataV1,
    sourceEventType: String? = nil,
    occurredAt: Date,
    title: String,
    summary: String? = nil,
    attributes: [String: String] = [:]
  ) {
    self.eventID = eventID
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
    self.sequence = sequence
    self.kind = kind
    self.phase = phase
    self.source = source
    self.sourceEventType = sourceEventType
    self.occurredAt = occurredAt
    self.title = title
    self.summary = summary
    self.attributes = kind == .reasoningSummary ? [:] : attributes
  }
}

public struct ChatTranscriptItemV1:
  Codable, Sendable, Equatable, Hashable, Identifiable
{
  public let id: String
  public let threadID: String
  public let turnID: String
  public let kind: ChatTranscriptItemKindV1
  public let phase: ChatTranscriptLifecyclePhaseV1
  public let source: ChatTranscriptSourceMetadataV1
  public let firstSequence: UInt64
  public let lastSequence: UInt64
  public let createdAt: Date
  public let updatedAt: Date
  public let title: String
  /// User-visible/provider-supplied summary. Never private chain-of-thought.
  public let summary: String?
  public let attributes: [String: String]
  public let eventIDs: [String]
}

public struct ChatTranscriptTurnV1:
  Codable, Sendable, Equatable, Hashable, Identifiable
{
  public let id: String
  public let threadID: String
  public let items: [ChatTranscriptItemV1]
}

public struct ChatTranscriptThreadV1:
  Codable, Sendable, Equatable, Hashable, Identifiable
{
  public let id: String
  public let turns: [ChatTranscriptTurnV1]
}

/// Durable persistence artifact. Both accepted events and their deterministic
/// Thread -> Turn -> Item projection are stored so hydration can reject a
/// corrupted or mismatched projection.
public struct ChatTranscriptJournalSnapshotV1:
  Codable, Sendable, Equatable
{
  public static let currentSchema = "ChatTranscriptJournalSnapshotV1"

  public let schema: String
  public let events: [ChatTranscriptEventV1]
  public let threads: [ChatTranscriptThreadV1]

  public init(
    schema: String = Self.currentSchema,
    events: [ChatTranscriptEventV1],
    threads: [ChatTranscriptThreadV1]
  ) {
    self.schema = schema
    self.events = events
    self.threads = threads
  }
}

public enum ChatTranscriptIgnoredEventReasonV1: Sendable, Equatable {
  case invalidIdentifier(field: String)
  case invalidSourceMetadata(field: String)
  case duplicateEvent(eventID: String)
  case conflictingEventID(eventID: String)
  case staleSequence(lastAccepted: UInt64, received: UInt64)
  case staleAttempt(itemID: String, current: UInt64, received: UInt64)
  case terminalItem(itemID: String, phase: ChatTranscriptLifecyclePhaseV1)
  case lifecycleRegression(
    itemID: String,
    current: ChatTranscriptLifecyclePhaseV1,
    received: ChatTranscriptLifecyclePhaseV1)
  case itemIdentityConflict(itemID: String)
}

public enum ChatTranscriptAppendOutcomeV1: Sendable, Equatable {
  case appended
  case ignored(ChatTranscriptIgnoredEventReasonV1)

  public var wasAppended: Bool {
    if case .appended = self { return true }
    return false
  }
}

public enum ChatTranscriptJournalErrorV1:
  Error, LocalizedError, Sendable, Equatable
{
  case unsupportedSchema(String)
  case invalidPersistedEvent(
    eventID: String,
    reason: ChatTranscriptIgnoredEventReasonV1)
  case projectionMismatch

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let schema):
      "unsupported chat transcript journal schema: \(schema)"
    case .invalidPersistedEvent(let eventID, let reason):
      "invalid persisted chat transcript event \(eventID): \(reason)"
    case .projectionMismatch:
      "persisted chat transcript projection does not match its event journal"
    }
  }
}

/// Append-only, replay-idempotent Thread -> Turn -> Item journal.
///
/// Accepted events are the durable source of truth. Projection arrays are
/// rebuilt deterministically. Terminal phases are latched within one attempt;
/// a remote job may reopen the same stable item only with a strictly higher
/// typed source attempt.
public struct ChatTranscriptJournalV1: Sendable, Equatable, Codable {
  private struct TurnKey: Sendable, Hashable {
    let threadID: String
    let turnID: String
  }

  private struct ItemKey: Sendable, Hashable {
    let threadID: String
    let turnID: String
    let itemID: String
  }

  private var acceptedEvents: [ChatTranscriptEventV1]
  private var eventByID: [String: ChatTranscriptEventV1]
  private var lastSequenceByTurn: [TurnKey: UInt64]
  private var itemByKey: [ItemKey: ChatTranscriptItemV1]

  public init() {
    acceptedEvents = []
    eventByID = [:]
    lastSequenceByTurn = [:]
    itemByKey = [:]
  }

  public init(snapshot: ChatTranscriptJournalSnapshotV1) throws {
    guard snapshot.schema == ChatTranscriptJournalSnapshotV1.currentSchema else {
      throw ChatTranscriptJournalErrorV1.unsupportedSchema(snapshot.schema)
    }

    self.init()
    for event in snapshot.events {
      let outcome = append(event)
      guard outcome == .appended else {
        guard case .ignored(let reason) = outcome else {
          preconditionFailure("unhandled chat transcript append outcome")
        }
        throw ChatTranscriptJournalErrorV1.invalidPersistedEvent(
          eventID: event.eventID,
          reason: reason)
      }
    }
    guard threads == snapshot.threads else {
      throw ChatTranscriptJournalErrorV1.projectionMismatch
    }
  }

  private enum CodingKeys: String, CodingKey {
    case snapshot
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let snapshot = try container.decode(
      ChatTranscriptJournalSnapshotV1.self,
      forKey: .snapshot)
    try self.init(snapshot: snapshot)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(snapshot, forKey: .snapshot)
  }

  public var events: [ChatTranscriptEventV1] {
    acceptedEvents.sorted(by: Self.eventOrder)
  }

  public var threads: [ChatTranscriptThreadV1] {
    let groupedByThread = Dictionary(grouping: itemByKey.values, by: \.threadID)
    return groupedByThread.keys.sorted().map { threadID in
      let groupedByTurn = Dictionary(
        grouping: groupedByThread[threadID] ?? [],
        by: \.turnID)
      let turns = groupedByTurn.keys.sorted().map { turnID in
        ChatTranscriptTurnV1(
          id: turnID,
          threadID: threadID,
          items: (groupedByTurn[turnID] ?? []).sorted(by: Self.itemOrder))
      }
      return ChatTranscriptThreadV1(id: threadID, turns: turns)
    }
  }

  public var snapshot: ChatTranscriptJournalSnapshotV1 {
    ChatTranscriptJournalSnapshotV1(events: events, threads: threads)
  }

  public func thread(id: String) -> ChatTranscriptThreadV1? {
    threads.first { $0.id == id }
  }

  public func event(id: String) -> ChatTranscriptEventV1? {
    eventByID[id]
  }

  public func turn(
    threadID: String,
    turnID: String
  ) -> ChatTranscriptTurnV1? {
    thread(id: threadID)?.turns.first { $0.id == turnID }
  }

  public func item(
    threadID: String,
    turnID: String,
    itemID: String
  ) -> ChatTranscriptItemV1? {
    itemByKey[ItemKey(
      threadID: threadID,
      turnID: turnID,
      itemID: itemID)]
  }

  /// Canonical cross-turn ordering for one visible transcript.
  ///
  /// Turn identifiers are provider/session identities, not chronology. UI
  /// hydration must therefore order the reduced items by their accepted event
  /// timestamps instead of sorting UUID/string turn IDs.
  public func orderedItems(threadID: String) -> [ChatTranscriptItemV1] {
    guard let thread = thread(id: threadID) else { return [] }
    return thread.turns
      .flatMap(\.items)
      .sorted(by: Self.transcriptItemOrder)
  }

  @discardableResult
  public mutating func append(
    _ event: ChatTranscriptEventV1
  ) -> ChatTranscriptAppendOutcomeV1 {
    if let invalid = Self.invalidIdentity(in: event) {
      return .ignored(invalid)
    }

    if let recorded = eventByID[event.eventID] {
      return .ignored(
        recorded == event
          ? .duplicateEvent(eventID: event.eventID)
          : .conflictingEventID(eventID: event.eventID))
    }

    let turnKey = TurnKey(threadID: event.threadID, turnID: event.turnID)
    if let lastSequence = lastSequenceByTurn[turnKey],
      event.sequence <= lastSequence
    {
      return .ignored(.staleSequence(
        lastAccepted: lastSequence,
        received: event.sequence))
    }

    let itemKey = ItemKey(
      threadID: event.threadID,
      turnID: event.turnID,
      itemID: event.itemID)
    if let item = itemByKey[itemKey] {
      guard item.kind == event.kind else {
        return .ignored(.itemIdentityConflict(itemID: event.itemID))
      }
      let remoteAttemptOrder = Self.remoteAttemptOrder(
        current: item,
        incoming: event)
      if !Self.sameOperationalSourceIdentity(item.source, event.source),
        remoteAttemptOrder == nil
      {
        return .ignored(.itemIdentityConflict(itemID: event.itemID))
      }
      if remoteAttemptOrder != .orderedAscending,
        Self.hasConflictingAttestation(item.source, event.source)
      {
        return .ignored(.itemIdentityConflict(itemID: event.itemID))
      }
      if remoteAttemptOrder == .orderedDescending {
        return .ignored(.staleAttempt(
          itemID: event.itemID,
          current: item.source.attempt ?? 0,
          received: event.source.attempt ?? 0))
      }
      if item.phase == .completed
        || (item.phase.isTerminal
          && remoteAttemptOrder != .orderedAscending)
      {
        return .ignored(.terminalItem(itemID: event.itemID, phase: item.phase))
      }
      if remoteAttemptOrder != .orderedAscending,
        item.phase == .running, event.phase == .pending
      {
        return .ignored(.lifecycleRegression(
          itemID: event.itemID,
          current: item.phase,
          received: event.phase))
      }
    }

    let item = reducing(event, into: itemByKey[itemKey])
    acceptedEvents.append(event)
    eventByID[event.eventID] = event
    lastSequenceByTurn[turnKey] = event.sequence
    itemByKey[itemKey] = item
    return .appended
  }

  /// Reducer spelling used by stream adapters.
  @discardableResult
  public mutating func reduce(
    _ event: ChatTranscriptEventV1
  ) -> ChatTranscriptAppendOutcomeV1 {
    append(event)
  }

  /// Replays reconnect/cold-start events in source order. Previously accepted
  /// event IDs are explicit duplicate outcomes; new monotonic events append.
  @discardableResult
  public mutating func replay<S: Sequence>(
    _ events: S
  ) -> [ChatTranscriptAppendOutcomeV1]
  where S.Element == ChatTranscriptEventV1 {
    events.map { append($0) }
  }

  /// Canonical JSON bytes suitable for atomic persistence and byte comparison.
  public func encodedSnapshot(prettyPrinted: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = prettyPrinted
      ? [.prettyPrinted, .sortedKeys]
      : [.sortedKeys]
    return try encoder.encode(snapshot)
  }

  public static func restoring(from data: Data) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try Self(snapshot: decoder.decode(
      ChatTranscriptJournalSnapshotV1.self,
      from: data))
  }

  private func reducing(
    _ event: ChatTranscriptEventV1,
    into current: ChatTranscriptItemV1?
  ) -> ChatTranscriptItemV1 {
    guard let current else {
      return ChatTranscriptItemV1(
        id: event.itemID,
        threadID: event.threadID,
        turnID: event.turnID,
        kind: event.kind,
        phase: event.phase,
        source: event.source,
        firstSequence: event.sequence,
        lastSequence: event.sequence,
        createdAt: event.occurredAt,
        updatedAt: event.occurredAt,
        title: event.title,
        summary: event.summary,
        attributes: event.attributes,
        eventIDs: [event.eventID])
    }

    let isHigherRemoteAttempt =
      Self.remoteAttemptOrder(current: current, incoming: event)
        == .orderedAscending
    var attributes = isHigherRemoteAttempt ? [:] : current.attributes
    attributes.merge(event.attributes) { _, incoming in incoming }
    return ChatTranscriptItemV1(
      id: current.id,
      threadID: current.threadID,
      turnID: current.turnID,
      kind: current.kind,
      phase: event.phase,
      source: isHigherRemoteAttempt
        ? event.source
        : Self.mergingAttestation(current.source, event.source),
      firstSequence: current.firstSequence,
      lastSequence: event.sequence,
      createdAt: min(current.createdAt, event.occurredAt),
      updatedAt: max(current.updatedAt, event.occurredAt),
      title: event.title.isEmpty ? current.title : event.title,
      summary: isHigherRemoteAttempt
        ? event.summary
        : (event.summary ?? current.summary),
      attributes: attributes,
      eventIDs: current.eventIDs + [event.eventID])
  }

  private static func remoteAttemptOrder(
    current: ChatTranscriptItemV1,
    incoming event: ChatTranscriptEventV1
  ) -> ComparisonResult? {
    guard current.kind == .remoteJob, event.kind == .remoteJob,
      sameSourceIdentityIgnoringAttempt(current.source, event.source),
      let currentAttempt = current.source.attempt,
      let incomingAttempt = event.source.attempt
    else {
      return nil
    }
    if incomingAttempt < currentAttempt { return .orderedDescending }
    if incomingAttempt > currentAttempt { return .orderedAscending }
    return .orderedSame
  }

  private static func sameSourceIdentityIgnoringAttempt(
    _ lhs: ChatTranscriptSourceMetadataV1,
    _ rhs: ChatTranscriptSourceMetadataV1
  ) -> Bool {
    lhs.source == rhs.source
      && lhs.model == rhs.model
      && lhs.runtime == rhs.runtime
      && lhs.sessionID == rhs.sessionID
      && lhs.runID == rhs.runID
  }

  private static func sameOperationalSourceIdentity(
    _ lhs: ChatTranscriptSourceMetadataV1,
    _ rhs: ChatTranscriptSourceMetadataV1
  ) -> Bool {
    sameSourceIdentityIgnoringAttempt(lhs, rhs)
      && lhs.attempt == rhs.attempt
      && lhs.runnerInstanceID == rhs.runnerInstanceID
      && lhs.runnerRevision == rhs.runnerRevision
  }

  private static func hasConflictingAttestation(
    _ lhs: ChatTranscriptSourceMetadataV1,
    _ rhs: ChatTranscriptSourceMetadataV1
  ) -> Bool {
    func conflicts<T: Equatable>(_ first: T?, _ second: T?) -> Bool {
      guard let first, let second else { return false }
      return first != second
    }
    return conflicts(lhs.requestedModelID, rhs.requestedModelID)
      || conflicts(lhs.requestedVendorModelID, rhs.requestedVendorModelID)
      || conflicts(lhs.actualCanonicalModel, rhs.actualCanonicalModel)
      || conflicts(lhs.actualVendorModel, rhs.actualVendorModel)
      || conflicts(lhs.requestedEffort, rhs.requestedEffort)
      || conflicts(lhs.forwardedEffort, rhs.forwardedEffort)
      || conflicts(
        lhs.effectiveEffortAttestation,
        rhs.effectiveEffortAttestation)
      || conflicts(lhs.providerResponseID, rhs.providerResponseID)
      || conflicts(lhs.providerSessionID, rhs.providerSessionID)
      || {
        guard let current = lhs.fallbackCount, let incoming = rhs.fallbackCount else {
          return false
        }
        return incoming < current
      }()
  }

  private static func mergingAttestation(
    _ current: ChatTranscriptSourceMetadataV1,
    _ incoming: ChatTranscriptSourceMetadataV1
  ) -> ChatTranscriptSourceMetadataV1 {
    ChatTranscriptSourceMetadataV1(
      source: current.source,
      model: current.model,
      runtime: current.runtime,
      sessionID: current.sessionID,
      runID: current.runID,
      attempt: current.attempt,
      runnerInstanceID: current.runnerInstanceID,
      runnerRevision: current.runnerRevision,
      requestedModelID: incoming.requestedModelID ?? current.requestedModelID,
      requestedVendorModelID:
        incoming.requestedVendorModelID ?? current.requestedVendorModelID,
      actualCanonicalModel:
        incoming.actualCanonicalModel ?? current.actualCanonicalModel,
      actualVendorModel: incoming.actualVendorModel ?? current.actualVendorModel,
      requestedEffort: incoming.requestedEffort ?? current.requestedEffort,
      forwardedEffort: incoming.forwardedEffort ?? current.forwardedEffort,
      effectiveEffortAttestation:
        incoming.effectiveEffortAttestation
          ?? current.effectiveEffortAttestation,
      fallbackCount: {
        switch (current.fallbackCount, incoming.fallbackCount) {
        case let (.some(lhs), .some(rhs)): return max(lhs, rhs)
        case let (.some(lhs), .none): return lhs
        case let (.none, .some(rhs)): return rhs
        case (.none, .none): return nil
        }
      }(),
      attestationOutcome:
        incoming.attestationOutcome ?? current.attestationOutcome,
      providerResponseID:
        incoming.providerResponseID ?? current.providerResponseID,
      providerSessionID:
        incoming.providerSessionID ?? current.providerSessionID)
  }

  private static func invalidIdentity(
    in event: ChatTranscriptEventV1
  ) -> ChatTranscriptIgnoredEventReasonV1? {
    for (field, value) in [
      ("eventID", event.eventID),
      ("threadID", event.threadID),
      ("turnID", event.turnID),
      ("itemID", event.itemID),
    ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .invalidIdentifier(field: field)
    }
    for (field, value) in [
      ("source", event.source.source),
      ("model", event.source.model),
      ("runtime", event.source.runtime),
    ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .invalidSourceMetadata(field: field)
    }
    return nil
  }

  private static func eventOrder(
    _ lhs: ChatTranscriptEventV1,
    _ rhs: ChatTranscriptEventV1
  ) -> Bool {
    if lhs.threadID != rhs.threadID { return lhs.threadID < rhs.threadID }
    if lhs.turnID != rhs.turnID { return lhs.turnID < rhs.turnID }
    if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
    return lhs.eventID < rhs.eventID
  }

  private static func itemOrder(
    _ lhs: ChatTranscriptItemV1,
    _ rhs: ChatTranscriptItemV1
  ) -> Bool {
    if lhs.firstSequence != rhs.firstSequence {
      return lhs.firstSequence < rhs.firstSequence
    }
    return lhs.id < rhs.id
  }

  private static func transcriptItemOrder(
    _ lhs: ChatTranscriptItemV1,
    _ rhs: ChatTranscriptItemV1
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    if lhs.updatedAt != rhs.updatedAt {
      return lhs.updatedAt < rhs.updatedAt
    }
    if lhs.threadID == rhs.threadID, lhs.turnID == rhs.turnID,
      lhs.firstSequence != rhs.firstSequence
    {
      return lhs.firstSequence < rhs.firstSequence
    }
    if lhs.turnID != rhs.turnID {
      return lhs.turnID < rhs.turnID
    }
    return lhs.id < rhs.id
  }
}
