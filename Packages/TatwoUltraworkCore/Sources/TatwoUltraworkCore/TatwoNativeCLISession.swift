import CryptoKit
import Darwin
import Foundation

public enum TatwoNativeCLIEngine: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
  case codex
  case claude
  case openclaw
  case grok
  case sandbox

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    case .openclaw: "OpenClaw"
    case .grok: "Grok"
    case .sandbox: "Sandbox"
    }
  }
}

public struct TatwoNativeCLISession: Codable, Sendable, Equatable, Hashable, Identifiable {
  public var id: UUID
  public var name: String
  public var engine: TatwoNativeCLIEngine
  public var cwd: String
  public var createdISO: String
  public var isArchived: Bool
  /// 跨面接力來源關聯：此 session 由哪條 chat thread 接來（nil = 直接新建）。optional 向後相容。
  public var sourceThreadID: UUID?
  /// 接力當下攜帶的 context 摘要（父 thread 的標題/近況），供終端 seed 顯示與後續 context 續作。
  public var seededContext: String?

  public init(
    id: UUID = UUID(),
    name: String,
    engine: TatwoNativeCLIEngine,
    cwd: String,
    createdISO: String = ISO8601DateFormatter().string(from: Date()),
    isArchived: Bool = false,
    sourceThreadID: UUID? = nil,
    seededContext: String? = nil
  ) {
    self.sourceThreadID = sourceThreadID
    self.seededContext = seededContext
    self.id = id
    self.name = name
    self.engine = engine
    self.cwd = cwd
    self.createdISO = createdISO
    self.isArchived = isArchived
  }
}

/// Value-semantic backend state for multiple concurrently available CLI sessions.
///
/// This intentionally stays separate from `TatwoNativeCLISession`, whose shape is
/// already persisted inside project documents and consumed by the current App UI.
public struct TatwoNativeCLISessionBook: Codable, Sendable, Equatable {
  public enum Engine: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case codex
    case claude
    case grok
    case generic
  }

  public struct Session: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var engine: Engine
    public var title: String
    public var workdir: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var isRunning: Bool

    private enum CodingKeys: String, CodingKey {
      case id
      case engine
      case title
      case workdir
      case createdAt
      case updatedAt
      case isRunning
    }

    public init(
      id: UUID = UUID(),
      engine: Engine,
      title: String,
      workdir: String? = nil,
      createdAt: Date = Date(),
      updatedAt: Date? = nil,
      isRunning: Bool = true
    ) {
      self.id = id
      self.engine = engine
      self.title = title
      self.workdir = workdir
      self.createdAt = createdAt
      self.updatedAt = updatedAt ?? createdAt
      self.isRunning = isRunning
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
      self.engine = try container.decodeIfPresent(Engine.self, forKey: .engine) ?? .generic
      self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "CLI Session"
      self.workdir = try container.decodeIfPresent(String.self, forKey: .workdir)
      self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
      self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
      self.isRunning = try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
    }
  }

  public private(set) var sessions: [Session]
  public private(set) var activeSessionID: UUID?

  private enum CodingKeys: String, CodingKey {
    case sessions
    case activeSessionID
  }

  public init(sessions: [Session] = [], activeSessionID: UUID? = nil) {
    self.sessions = sessions
    self.activeSessionID = Self.validActiveSessionID(
      activeSessionID,
      sessions: sessions)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    let decodedActiveSessionID = try container.decodeIfPresent(UUID.self, forKey: .activeSessionID)
    self.sessions = decodedSessions
    self.activeSessionID = Self.validActiveSessionID(
      decodedActiveSessionID,
      sessions: decodedSessions)
  }

  public var activeSession: Session? {
    guard let activeSessionID else { return nil }
    return sessions.first { $0.id == activeSessionID }
  }

  @discardableResult
  public mutating func open(
    engine: Engine,
    title: String,
    workdir: String?,
    at date: Date = Date()
  ) -> UUID {
    let session = Session(
      engine: engine,
      title: title,
      workdir: workdir,
      createdAt: date)
    sessions.append(session)
    activeSessionID = session.id
    return session.id
  }

  @discardableResult
  public mutating func close(_ id: UUID) -> Bool {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      return false
    }
    let wasActive = activeSessionID == id
    sessions.remove(at: index)
    if wasActive {
      activeSessionID = index < sessions.count
        ? sessions[index].id
        : sessions.last?.id
    }
    return true
  }

  @discardableResult
  public mutating func select(_ id: UUID) -> Bool {
    guard sessions.contains(where: { $0.id == id }) else {
      return false
    }
    activeSessionID = id
    return true
  }

  @discardableResult
  public mutating func rename(
    _ id: UUID,
    title: String,
    at date: Date = Date()
  ) -> Bool {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      return false
    }
    sessions[index].title = title
    sessions[index].updatedAt = date
    return true
  }

  @discardableResult
  public mutating func reorder(
    _ id: UUID,
    to destinationIndex: Int,
    at date: Date = Date()
  ) -> Bool {
    guard let sourceIndex = sessions.firstIndex(where: { $0.id == id }) else {
      return false
    }
    let boundedDestination = min(max(destinationIndex, 0), sessions.count - 1)
    var session = sessions.remove(at: sourceIndex)
    session.updatedAt = date
    sessions.insert(session, at: boundedDestination)
    return true
  }

  @discardableResult
  public mutating func setRunning(
    _ isRunning: Bool,
    for id: UUID,
    at date: Date = Date()
  ) -> Bool {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else {
      return false
    }
    sessions[index].isRunning = isRunning
    sessions[index].updatedAt = date
    return true
  }

  private static func validActiveSessionID(
    _ candidate: UUID?,
    sessions: [Session]
  ) -> UUID? {
    if let candidate, sessions.contains(where: { $0.id == candidate }) {
      return candidate
    }
    return sessions.first?.id
  }
}
