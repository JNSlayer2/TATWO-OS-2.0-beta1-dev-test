import Foundation

// MARK: - Unified chat/CLI/loops session entity
//
// Session identity was previously scattered across:
// - TatwoNativeChatThread.id + codexSessionID / claudeSessionID / cliSessionID
// - TatwoNativeChatSessionReference (kind + id)
// - TatwoNativeCLISession / TatwoNativeCLISessionBook.Session
// - TatwoLoopsSession (parentKind + parentID)
// - StreamTranscriptLedger.sessionID (opaque UUID)
//
// Canonical rule: **Tatwo session UUID is the only primary id**.
// Provider resume handles (Codex/Claude session strings) are secondary and
// never replace the Tatwo id in stream ledgers or loops associations.
//
// This type is a projection/binding surface. Existing thread/transcript JSON
// remains the durable store; decode paths stay migration-compatible.

/// Where a session originated / which surface owns it.
public enum TatwoSessionKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case chatThread = "chat_thread"
  case chatDiscussion = "chat_discussion"
  case cli
  case loops
  case stream
}

/// Engine / runtime source for the session (normalized).
public enum TatwoSessionEngine: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case codex
  case claude
  case grok
  case openclaw
  case sandbox
  case gateway
  case multi
  case unknown

  public init(nativeCLI: TatwoNativeCLIEngine) {
    switch nativeCLI {
    case .codex: self = .codex
    case .claude: self = .claude
    case .openclaw: self = .openclaw
    case .grok: self = .grok
    case .sandbox: self = .sandbox
    }
  }

  public init(bookEngine: TatwoNativeCLISessionBook.Engine) {
    switch bookEngine {
    case .codex: self = .codex
    case .claude: self = .claude
    case .grok: self = .grok
    case .generic: self = .unknown
    }
  }

  public init(chatEngine: TatwoNativeChatEngine) {
    switch chatEngine {
    case .codex: self = .codex
    case .claude: self = .claude
    }
  }

  public init(adapterID: String?) {
    let raw = (adapterID ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if raw.isEmpty {
      self = .unknown
      return
    }
    if raw.contains("codex") {
      self = .codex
    } else if raw.contains("claude") {
      self = .claude
    } else if raw.contains("grok") {
      self = .grok
    } else if raw.contains("openclaw") {
      self = .openclaw
    } else if raw.contains("gateway") {
      self = .gateway
    } else if raw.contains("sandbox") {
      self = .sandbox
    } else {
      self = .unknown
    }
  }
}

/// Lifecycle / connectivity state shared by stream + loops consumers.
public enum TatwoSessionEntityState: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case active
  case degraded
  case offline
  case archived
  case completed
  case failed

  public init(connection phase: ChatStreamConnectionPhase) {
    switch phase {
    case .connected: self = .active
    case .degraded: self = .degraded
    case .offline: self = .offline
    }
  }
}

/// Single session entity used by stream ledgers, reconnect controllers, and loops.
public struct TatwoSessionEntity: Identifiable, Codable, Sendable, Equatable, Hashable {
  public let id: UUID
  public let createdAt: Date
  public var updatedAt: Date
  public var kind: TatwoSessionKind
  public var engine: TatwoSessionEngine
  /// Associated chat thread when kind is discussion / cli / loops / stream.
  public var threadID: UUID?
  /// Optional job / dispatch id (loops / remote runners).
  public var jobID: String?
  /// Parent Tatwo session (discussion parent, loops parent, handoff source).
  public var parentSessionID: UUID?
  /// Secondary provider resume handles keyed by adapter id (never primary id).
  public var providerSessionIDs: [String: String]
  public var state: TatwoSessionEntityState
  /// Free-form source tag for diagnostics (`chat`, `cli`, `loops`, `stream`, …).
  public var source: String

  private enum CodingKeys: String, CodingKey {
    case id
    case createdAt
    case updatedAt
    case kind
    case engine
    case threadID
    case jobID
    case parentSessionID
    case providerSessionIDs
    case state
    case source
    // Legacy / alternate keys accepted on decode only.
    case sessionID
    case createdISO
    case engineSource
    case status
  }

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    kind: TatwoSessionKind,
    engine: TatwoSessionEngine = .unknown,
    threadID: UUID? = nil,
    jobID: String? = nil,
    parentSessionID: UUID? = nil,
    providerSessionIDs: [String: String] = [:],
    state: TatwoSessionEntityState = .active,
    source: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.kind = kind
    self.engine = engine
    self.threadID = threadID
    self.jobID = jobID
    self.parentSessionID = parentSessionID
    self.providerSessionIDs = Self.normalizedProviderMap(providerSessionIDs)
    self.state = state
    self.source = source ?? kind.rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if let uuid = try container.decodeIfPresent(UUID.self, forKey: .id) {
      self.id = uuid
    } else if let legacy = try container.decodeIfPresent(String.self, forKey: .sessionID),
      let uuid = UUID(uuidString: legacy)
    {
      self.id = uuid
    } else {
      // Migration-safe: mint a stable-looking id only when completely absent.
      // Callers that need strict identity must supply id.
      self.id = UUID()
    }

    if let created = try container.decodeIfPresent(Date.self, forKey: .createdAt) {
      self.createdAt = created
    } else if let iso = try container.decodeIfPresent(String.self, forKey: .createdISO),
      let parsed = ISO8601DateFormatter().date(from: iso)
    {
      self.createdAt = parsed
    } else {
      self.createdAt = .distantPast
    }

    self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt

    if let kind = try container.decodeIfPresent(TatwoSessionKind.self, forKey: .kind) {
      self.kind = kind
    } else {
      self.kind = .stream
    }

    if let engine = try container.decodeIfPresent(TatwoSessionEngine.self, forKey: .engine) {
      self.engine = engine
    } else if let raw = try container.decodeIfPresent(String.self, forKey: .engineSource) {
      self.engine = TatwoSessionEngine(adapterID: raw)
    } else {
      self.engine = .unknown
    }

    self.threadID = try container.decodeIfPresent(UUID.self, forKey: .threadID)
    self.jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
    self.parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)

    let providers =
      try container.decodeIfPresent([String: String].self, forKey: .providerSessionIDs) ?? [:]
    self.providerSessionIDs = Self.normalizedProviderMap(providers)

    if let state = try container.decodeIfPresent(TatwoSessionEntityState.self, forKey: .state) {
      self.state = state
    } else if let status = try container.decodeIfPresent(String.self, forKey: .status) {
      self.state = Self.state(fromLegacyStatus: status)
    } else {
      self.state = .active
    }

    self.source =
      try container.decodeIfPresent(String.self, forKey: .source)
      ?? kind.rawValue
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(kind, forKey: .kind)
    try container.encode(engine, forKey: .engine)
    try container.encodeIfPresent(threadID, forKey: .threadID)
    try container.encodeIfPresent(jobID, forKey: .jobID)
    try container.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
    try container.encode(providerSessionIDs, forKey: .providerSessionIDs)
    try container.encode(state, forKey: .state)
    try container.encode(source, forKey: .source)
  }

  /// Same shape as `TatwoNativeChatSessionReference.stableKey` when kind maps.
  public var stableKey: String {
    switch kind {
    case .chatThread:
      return "thread:\(id.uuidString.lowercased())"
    case .chatDiscussion:
      return "discussion:\(id.uuidString.lowercased())"
    case .cli:
      return "cli:\(id.uuidString.lowercased())"
    case .loops:
      return "loops:\(id.uuidString.lowercased())"
    case .stream:
      return "stream:\(id.uuidString.lowercased())"
    }
  }

  /// Reference into the chat session tree when applicable.
  public var chatSessionReference: TatwoNativeChatSessionReference? {
    switch kind {
    case .chatThread:
      return TatwoNativeChatSessionReference(kind: .thread, id: id)
    case .chatDiscussion:
      return TatwoNativeChatSessionReference(kind: .discussion, id: id)
    default:
      return nil
    }
  }

  /// Provider resume handle for an adapter, if known.
  public func providerSessionID(forAdapter adapterID: String) -> String? {
    let key = adapterID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    if let exact = providerSessionIDs[key], !exact.isEmpty { return exact }
    let lowered = key.lowercased()
    return providerSessionIDs.first { $0.key.lowercased() == lowered }?.value
  }

  public mutating func upsertProviderSessionID(_ providerSessionID: String, adapterID: String) {
    let adapter = adapterID.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !adapter.isEmpty, !value.isEmpty else { return }
    providerSessionIDs[adapter] = value
    updatedAt = Date()
  }

  public mutating func apply(connection phase: ChatStreamConnectionPhase, at now: Date = Date()) {
    state = TatwoSessionEntityState(connection: phase)
    updatedAt = now
  }

  // MARK: - Projections from existing durable types

  public static func from(thread: TatwoNativeChatThread) -> TatwoSessionEntity {
    var providers: [String: String] = [:]
    for handle in thread.adapterSessionHandles {
      let id = handle.providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty else { continue }
      providers[handle.adapterID] = id
    }
    if providers.isEmpty {
      if let codex = nonEmpty(thread.codexCLISessionID) ?? nonEmpty(thread.codexSessionID) {
        providers[TatwoChatRuntimeAdapter.codexExec.rawValue] = codex
      }
      if let claude = nonEmpty(thread.claudeSessionID) {
        providers[TatwoChatRuntimeAdapter.claudeCLI.rawValue] = claude
      }
    }

    let engine = engineFrom(providerMap: providers, handles: thread.adapterSessionHandles)
    let state: TatwoSessionEntityState = thread.isArchived ? .archived : .active

    return TatwoSessionEntity(
      id: thread.id,
      createdAt: thread.createdAt,
      updatedAt: thread.updatedAt,
      kind: .chatThread,
      engine: engine,
      threadID: thread.id,
      jobID: nil,
      parentSessionID: nil,
      providerSessionIDs: providers,
      state: state,
      source: "chat_thread")
  }

  public static func from(
    discussion: TatwoNativeDiscussion,
    parentThreadID: UUID? = nil
  ) -> TatwoSessionEntity {
    var providers: [String: String] = [:]
    for handle in discussion.adapterSessionHandles {
      let id = handle.providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty else { continue }
      providers[handle.adapterID] = id
    }
    let parent = discussion.parentSession?.id ?? parentThreadID
    let created =
      ISO8601DateFormatter().date(from: discussion.createdISO) ?? .distantPast
    let state: TatwoSessionEntityState
    if discussion.isArchived {
      state = .archived
    } else if discussion.status == .compressed {
      state = .completed
    } else {
      state = .active
    }
    return TatwoSessionEntity(
      id: discussion.id,
      createdAt: created,
      updatedAt: created,
      kind: .chatDiscussion,
      engine: engineFrom(providerMap: providers, handles: discussion.adapterSessionHandles),
      threadID: parent,
      jobID: nil,
      parentSessionID: parent,
      providerSessionIDs: providers,
      state: state,
      source: "chat_discussion")
  }

  public static func from(cli session: TatwoNativeCLISession) -> TatwoSessionEntity {
    let created =
      ISO8601DateFormatter().date(from: session.createdISO) ?? .distantPast
    return TatwoSessionEntity(
      id: session.id,
      createdAt: created,
      updatedAt: created,
      kind: .cli,
      engine: TatwoSessionEngine(nativeCLI: session.engine),
      threadID: session.sourceThreadID,
      jobID: nil,
      parentSessionID: session.sourceThreadID,
      providerSessionIDs: [:],
      state: session.isArchived ? .archived : .active,
      source: "cli")
  }

  public static func from(cliBookSession session: TatwoNativeCLISessionBook.Session) -> TatwoSessionEntity {
    TatwoSessionEntity(
      id: session.id,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      kind: .cli,
      engine: TatwoSessionEngine(bookEngine: session.engine),
      threadID: nil,
      jobID: nil,
      parentSessionID: nil,
      providerSessionIDs: [:],
      state: session.isRunning ? .active : .completed,
      source: "cli_book")
  }

  public static func from(loops session: TatwoLoopsSession, jobID: String? = nil) -> TatwoSessionEntity {
    let created =
      ISO8601DateFormatter().date(from: session.createdISO) ?? .distantPast
    let threadID: UUID?
    switch session.parentKind {
    case .thread:
      threadID = session.parentID
    case .mainChat, .discussion:
      threadID = nil
    }
    let entityState: TatwoSessionEntityState
    switch session.status {
    case .planned, .running:
      entityState = .active
    case .blocked:
      entityState = .degraded
    case .passed:
      entityState = .completed
    case .rollbackRequired:
      entityState = .failed
    }
    return TatwoSessionEntity(
      id: session.id,
      createdAt: created,
      updatedAt: created,
      kind: .loops,
      engine: .unknown,
      threadID: threadID,
      jobID: jobID,
      parentSessionID: session.parentID,
      providerSessionIDs: [:],
      state: entityState,
      source: "loops")
  }

  public static func forStream(
    sessionID: UUID = UUID(),
    threadID: UUID? = nil,
    engine: TatwoSessionEngine = .unknown,
    providerSessionIDs: [String: String] = [:],
    createdAt: Date = Date()
  ) -> TatwoSessionEntity {
    TatwoSessionEntity(
      id: sessionID,
      createdAt: createdAt,
      updatedAt: createdAt,
      kind: .stream,
      engine: engine,
      threadID: threadID,
      jobID: nil,
      parentSessionID: threadID,
      providerSessionIDs: providerSessionIDs,
      state: .active,
      source: "stream")
  }

  /// Build from a chat session reference (thread or discussion id only).
  public static func from(
    reference: TatwoNativeChatSessionReference,
    engine: TatwoSessionEngine = .unknown,
    threadID: UUID? = nil,
    createdAt: Date = Date()
  ) -> TatwoSessionEntity {
    switch reference.kind {
    case .thread:
      return TatwoSessionEntity(
        id: reference.id,
        createdAt: createdAt,
        updatedAt: createdAt,
        kind: .chatThread,
        engine: engine,
        threadID: reference.id,
        state: .active,
        source: "chat_reference")
    case .discussion:
      return TatwoSessionEntity(
        id: reference.id,
        createdAt: createdAt,
        updatedAt: createdAt,
        kind: .chatDiscussion,
        engine: engine,
        threadID: threadID,
        parentSessionID: threadID,
        state: .active,
        source: "chat_reference")
    }
  }

  // MARK: - Identity helpers

  /// Provider resume strings must never be treated as the Tatwo session UUID.
  public static func isCanonicalSessionID(
    _ candidate: String,
    matching entity: TatwoSessionEntity
  ) -> Bool {
    guard let uuid = UUID(uuidString: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      return false
    }
    return uuid == entity.id
  }

  /// True when two projections share the same canonical Tatwo id (not provider id).
  public static func sameIdentity(_ lhs: TatwoSessionEntity, _ rhs: TatwoSessionEntity) -> Bool {
    lhs.id == rhs.id
  }

  // MARK: - Private

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedProviderMap(_ map: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    out.reserveCapacity(map.count)
    for (key, value) in map {
      let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
      let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !k.isEmpty, !v.isEmpty else { continue }
      out[k] = v
    }
    return out
  }

  private static func engineFrom(
    providerMap: [String: String],
    handles: [TatwoNativeAdapterSessionHandle]
  ) -> TatwoSessionEngine {
    let adapters = Set(handles.map(\.adapterID) + providerMap.keys)
    let engines = Set(adapters.map { TatwoSessionEngine(adapterID: $0) }.filter { $0 != .unknown })
    if engines.count > 1 { return .multi }
    if let only = engines.first { return only }
    return .unknown
  }

  private static func state(fromLegacyStatus status: String) -> TatwoSessionEntityState {
    let raw = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch raw {
    case "active", "running", "open", "connected":
      return .active
    case "degraded", "retrying", "blocked":
      return .degraded
    case "offline", "disconnected":
      return .offline
    case "archived":
      return .archived
    case "completed", "passed", "done", "compressed":
      return .completed
    case "failed", "error", "rollback_required", "rollbackrequired":
      return .failed
    default:
      if raw.hasPrefix("degraded") { return .degraded }
      if raw.hasPrefix("offline") { return .offline }
      if raw.hasPrefix("fail") { return .failed }
      return .active
    }
  }
}

// MARK: - Stream / reconnect binding

extension StreamTranscriptLedger {
  /// Bind a stream ledger to the canonical session entity id.
  public convenience init(session: TatwoSessionEntity) {
    self.init(sessionID: session.id)
  }
}

extension ChatStreamReconnectController {
  /// Bind reconnect controller to the same canonical id as the session entity.
  public convenience init(
    session: TatwoSessionEntity,
    policy: ChatStreamReconnectPolicy = .default,
    now: Date = Date()
  ) {
    self.init(sessionID: session.id, policy: policy, now: now)
  }
}
