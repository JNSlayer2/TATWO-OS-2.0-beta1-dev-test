import Foundation

// MARK: - CLI multi-engine session registry (os.md §9.4 / §5 P2)
//
// Pure Core data layer: persistent multi-open session book classified by
// codex / claude / openclaw / grok / sandbox. No View types.
//
// Persistence root is always injected (env → TatwoRuntimeLayout, or caller
// fixture). Never hardcodes /Volumes or home absolute paths in source.

// MARK: - Engine / lifecycle state

/// Engines managed by the CLI session registry (os.md §9.4 classification).
public enum TatwoCLISessionEngineV1: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case codex
  case claude
  case openclaw
  case grok
  case sandbox
}

/// Session liveness. `prune` only removes `.exited`; never `.active` / `.idle`.
public enum TatwoCLISessionStateV1: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case active
  case idle
  case exited
}

// MARK: - Errors (fail-closed)

public enum TatwoCLISessionRegistryErrorV1: Error, LocalizedError, Equatable, Sendable {
  case corruptDocument(String)
  case schemaMismatch(String)
  case sessionNotFound(String)
  case invalidTitle
  case invalidWorkdir
  case alreadyExited(String)
  case cannotMutateExited(String)

  public var errorDescription: String? {
    switch self {
    case let .corruptDocument(detail):
      "CLI session registry document is corrupt: \(detail)"
    case let .schemaMismatch(schema):
      "CLI session registry schema mismatch: \(schema)"
    case let .sessionNotFound(id):
      "CLI session not found: \(id)"
    case .invalidTitle:
      "CLI session title must be non-empty"
    case .invalidWorkdir:
      "CLI session workdir must be non-empty when provided"
    case let .alreadyExited(id):
      "CLI session already exited: \(id)"
    case let .cannotMutateExited(id):
      "CLI session is exited and cannot be mutated: \(id)"
    }
  }
}

// MARK: - Record

public struct TatwoCLISessionRecordV1: Codable, Sendable, Equatable, Hashable, Identifiable {
  public let id: String
  public let engine: TatwoCLISessionEngineV1
  public var title: String
  public let createdAt: Date
  public var lastActiveAt: Date
  public var state: TatwoCLISessionStateV1
  public var workdir: String?
  public var tags: [String]

  public init(
    id: String = UUID().uuidString,
    engine: TatwoCLISessionEngineV1,
    title: String,
    createdAt: Date = Date(),
    lastActiveAt: Date? = nil,
    state: TatwoCLISessionStateV1 = .active,
    workdir: String? = nil,
    tags: [String] = []
  ) throws {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      throw TatwoCLISessionRegistryErrorV1.invalidTitle
    }
    let normalizedWorkdir = workdir.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let normalizedWorkdir, normalizedWorkdir.isEmpty {
      throw TatwoCLISessionRegistryErrorV1.invalidWorkdir
    }
    self.id = id
    self.engine = engine
    self.title = trimmedTitle
    self.createdAt = createdAt
    self.lastActiveAt = lastActiveAt ?? createdAt
    self.state = state
    self.workdir = normalizedWorkdir
    self.tags = Self.normalizedTags(tags)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case engine
    case title
    case createdAt
    case lastActiveAt
    case state
    case workdir
    case tags
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let engine = try container.decode(TatwoCLISessionEngineV1.self, forKey: .engine)
    let title = try container.decode(String.self, forKey: .title)
    let createdAt = try container.decode(Date.self, forKey: .createdAt)
    let lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
    let state = try container.decode(TatwoCLISessionStateV1.self, forKey: .state)
    let workdir = try container.decodeIfPresent(String.self, forKey: .workdir)
    let tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    try self.init(
      id: id,
      engine: engine,
      title: title,
      createdAt: createdAt,
      lastActiveAt: lastActiveAt,
      state: state,
      workdir: workdir,
      tags: tags)
  }

  static func normalizedTags(_ tags: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for raw in tags {
      let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
      result.append(tag)
    }
    return result
  }
}

// MARK: - On-disk document

public struct TatwoCLISessionRegistryDocumentV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoCLISessionRegistryV1"

  public let schema: String
  public var sessions: [TatwoCLISessionRecordV1]

  public init(
    schema: String = TatwoCLISessionRegistryDocumentV1.schemaName,
    sessions: [TatwoCLISessionRecordV1] = []
  ) throws {
    guard schema == Self.schemaName else {
      throw TatwoCLISessionRegistryErrorV1.schemaMismatch(schema)
    }
    self.schema = schema
    self.sessions = sessions
  }
}

// MARK: - Registry

/// Multi-engine CLI session manager: register / touch / markExited / prune.
///
/// Persistence: `{rootURL}/cli-session-registry-v1.json` (atomic write).
/// Corrupt or schema-mismatched files fail closed (throw); missing file = empty.
public final class TatwoCLISessionRegistryV1: @unchecked Sendable {
  public static let fileName = "cli-session-registry-v1.json"

  public let rootURL: URL
  public let fileURL: URL

  private let lock = NSLock()
  private let fileManager: FileManager

  public init(rootURL: URL, fileManager: FileManager = .default) {
    let standardized = rootURL.standardizedFileURL
    self.rootURL = standardized
    self.fileURL = standardized.appendingPathComponent(Self.fileName, isDirectory: false)
    self.fileManager = fileManager
  }

  /// Production convenience: App Support via `TatwoRuntimeLayout` (injectable env / base).
  public convenience init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) {
    let root = TatwoRuntimeLayout.applicationSupportRoot(
      environment: environment,
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    self.init(rootURL: root, fileManager: fileManager)
  }

  // MARK: Query

  public func allSessions() throws -> [TatwoCLISessionRecordV1] {
    try loadDocument().sessions
  }

  public func sessions(engine: TatwoCLISessionEngineV1) throws -> [TatwoCLISessionRecordV1] {
    try allSessions().filter { $0.engine == engine }
  }

  public func session(id: String) throws -> TatwoCLISessionRecordV1 {
    let sessions = try allSessions()
    guard let found = sessions.first(where: { $0.id == id }) else {
      throw TatwoCLISessionRegistryErrorV1.sessionNotFound(id)
    }
    return found
  }

  // MARK: Lifecycle

  @discardableResult
  public func register(
    engine: TatwoCLISessionEngineV1,
    title: String,
    workdir: String? = nil,
    tags: [String] = [],
    id: String = UUID().uuidString,
    at date: Date = Date()
  ) throws -> TatwoCLISessionRecordV1 {
    let record = try TatwoCLISessionRecordV1(
      id: id,
      engine: engine,
      title: title,
      createdAt: date,
      lastActiveAt: date,
      state: .active,
      workdir: workdir,
      tags: tags)
    return try mutate { document in
      document.sessions.append(record)
      return record
    }
  }

  /// Refresh activity. Non-exited sessions only; idle promotes to active.
  @discardableResult
  public func touch(id: String, at date: Date = Date()) throws -> TatwoCLISessionRecordV1 {
    try mutate { document in
      guard let index = document.sessions.firstIndex(where: { $0.id == id }) else {
        throw TatwoCLISessionRegistryErrorV1.sessionNotFound(id)
      }
      if document.sessions[index].state == .exited {
        throw TatwoCLISessionRegistryErrorV1.cannotMutateExited(id)
      }
      document.sessions[index].lastActiveAt = date
      if document.sessions[index].state == .idle {
        document.sessions[index].state = .active
      }
      return document.sessions[index]
    }
  }

  /// active → idle (keeps the session; prune will not remove it).
  @discardableResult
  public func markIdle(id: String, at date: Date = Date()) throws -> TatwoCLISessionRecordV1 {
    try mutate { document in
      guard let index = document.sessions.firstIndex(where: { $0.id == id }) else {
        throw TatwoCLISessionRegistryErrorV1.sessionNotFound(id)
      }
      let current = document.sessions[index].state
      if current == .exited {
        throw TatwoCLISessionRegistryErrorV1.cannotMutateExited(id)
      }
      document.sessions[index].state = .idle
      document.sessions[index].lastActiveAt = date
      return document.sessions[index]
    }
  }

  @discardableResult
  public func markExited(id: String, at date: Date = Date()) throws -> TatwoCLISessionRecordV1 {
    try mutate { document in
      guard let index = document.sessions.firstIndex(where: { $0.id == id }) else {
        throw TatwoCLISessionRegistryErrorV1.sessionNotFound(id)
      }
      if document.sessions[index].state == .exited {
        throw TatwoCLISessionRegistryErrorV1.alreadyExited(id)
      }
      document.sessions[index].state = .exited
      document.sessions[index].lastActiveAt = date
      return document.sessions[index]
    }
  }

  /// Remove only `.exited` sessions whose `lastActiveAt` is strictly older than
  /// `olderThan`. Never removes `.active` or `.idle` (running-session iron rule).
  @discardableResult
  public func prune(olderThan cutoff: Date) throws -> [TatwoCLISessionRecordV1] {
    try mutate { document in
      var removed: [TatwoCLISessionRecordV1] = []
      var kept: [TatwoCLISessionRecordV1] = []
      for session in document.sessions {
        let isExited = session.state == .exited
        let isStale = session.lastActiveAt < cutoff
        if isExited && isStale {
          removed.append(session)
        } else {
          kept.append(session)
        }
      }
      document.sessions = kept
      return removed
    }
  }

  // MARK: Persistence

  public func loadDocument() throws -> TatwoCLISessionRegistryDocumentV1 {
    lock.lock()
    defer { lock.unlock() }
    return try loadDocumentUnlocked()
  }

  public func saveDocument(_ document: TatwoCLISessionRegistryDocumentV1) throws {
    lock.lock()
    defer { lock.unlock() }
    try saveDocumentUnlocked(document)
  }

  // MARK: - Private

  private func mutate<T>(
    _ body: (inout TatwoCLISessionRegistryDocumentV1) throws -> T
  ) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    var document = try loadDocumentUnlocked()
    let result = try body(&document)
    try saveDocumentUnlocked(document)
    return result
  }

  private func loadDocumentUnlocked() throws -> TatwoCLISessionRegistryDocumentV1 {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return try TatwoCLISessionRegistryDocumentV1(sessions: [])
    }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw TatwoCLISessionRegistryErrorV1.corruptDocument(
        "unreadable: \(error.localizedDescription)")
    }
    if data.isEmpty {
      throw TatwoCLISessionRegistryErrorV1.corruptDocument("empty file")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document: TatwoCLISessionRegistryDocumentV1
    do {
      document = try decoder.decode(TatwoCLISessionRegistryDocumentV1.self, from: data)
    } catch {
      throw TatwoCLISessionRegistryErrorV1.corruptDocument(
        "decode failed: \(error.localizedDescription)")
    }
    guard document.schema == TatwoCLISessionRegistryDocumentV1.schemaName else {
      throw TatwoCLISessionRegistryErrorV1.schemaMismatch(document.schema)
    }
    return document
  }

  private func saveDocumentUnlocked(_ document: TatwoCLISessionRegistryDocumentV1) throws {
    guard document.schema == TatwoCLISessionRegistryDocumentV1.schemaName else {
      throw TatwoCLISessionRegistryErrorV1.schemaMismatch(document.schema)
    }
    try fileManager.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(document)
    try data.write(to: fileURL, options: [.atomic])
  }
}
