// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/CLICommandHistory.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public enum TatwoCLIHistoryStorageDecision: String, Codable, Sendable, Equatable {
  case stored
  case redacted
  case excluded
}

public struct TatwoCLICommandSensitivityPolicy: Codable, Sendable, Equatable {
  public let redactedPreview: String

  public init(redactedPreview: String = "敏感命令未保存") {
    self.redactedPreview = redactedPreview
  }

  public func decision(for command: String) -> TatwoCLIHistoryStorageDecision {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .excluded }

    if Self.matches(
      #"-----BEGIN[ A-Z0-9_-]*PRIVATE KEY-----"#,
      in: trimmed)
    {
      return .excluded
    }

    let redactedPatterns = [
      #"\bauthorization\s*:"#,
      #"(^|\s)(?:export\s+)?[a-z0-9_]*(?:token|password|passwd|secret|api_key|access_key|private_key)[a-z0-9_]*\s*="#,
      #"(^|\s)(?:--(?:token|password|passwd|secret|api[-_]key|access[-_]key)|-p)(?:\s|=|$)"#,
      #"\b(?:token|password|passwd|secret|api[-_]?key|access[-_]?key)\b\s*[:=]"#,
      #"\bsk-[a-z0-9_-]{8,}\b"#
    ]

    return redactedPatterns.contains { Self.matches($0, in: trimmed) }
      ? .redacted
      : .stored
  }

  private static func matches(_ pattern: String, in value: String) -> Bool {
    value.range(
      of: pattern,
      options: [.regularExpression, .caseInsensitive]) != nil
  }
}

public struct TatwoCLICommandHistoryEntry:
  Codable,
  Sendable,
  Equatable,
  Identifiable
{
  public let id: UUID
  public let sessionID: UUID
  public let engine: TatwoNativeCLISessionBook.Engine
  public let command: String?
  public let displayPreview: String
  public let executedAt: Date
  public let workdirToken: String?
  public let storageDecision: TatwoCLIHistoryStorageDecision

  private enum CodingKeys: String, CodingKey {
    case id
    case sessionID
    case engine
    case command
    case displayPreview
    case executedAt
    case workdirToken
    case storageDecision
  }

  public init(
    id: UUID,
    sessionID: UUID,
    engine: TatwoNativeCLISessionBook.Engine,
    command: String?,
    displayPreview: String,
    executedAt: Date,
    workdirToken: String?,
    storageDecision: TatwoCLIHistoryStorageDecision
  ) {
    self.id = id
    self.sessionID = sessionID
    self.engine = engine
    self.command = storageDecision == .stored ? command : nil
    self.displayPreview = displayPreview
    self.executedAt = executedAt
    self.workdirToken = workdirToken
    self.storageDecision = storageDecision
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decision =
      try container.decodeIfPresent(
        TatwoCLIHistoryStorageDecision.self,
        forKey: .storageDecision) ?? .excluded
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      sessionID: try container.decode(UUID.self, forKey: .sessionID),
      engine:
        try container.decodeIfPresent(
          TatwoNativeCLISessionBook.Engine.self,
          forKey: .engine) ?? .generic,
      command: try container.decodeIfPresent(String.self, forKey: .command),
      displayPreview:
        try container.decodeIfPresent(String.self, forKey: .displayPreview)
          ?? (decision == .redacted ? "敏感命令未保存" : ""),
      executedAt:
        try container.decodeIfPresent(Date.self, forKey: .executedAt)
          ?? .distantPast,
      workdirToken:
        try container.decodeIfPresent(String.self, forKey: .workdirToken),
      storageDecision: decision)
  }
}

public struct TatwoCLICommandHistoryBook: Codable, Sendable, Equatable {
  public private(set) var entriesBySession: [UUID: [TatwoCLICommandHistoryEntry]]
  public let perSessionLimit: Int

  private enum CodingKeys: String, CodingKey {
    case entriesBySession
    case perSessionLimit
  }

  public init(
    entriesBySession: [UUID: [TatwoCLICommandHistoryEntry]] = [:],
    perSessionLimit: Int = 200
  ) {
    let safeLimit = max(0, perSessionLimit)
    self.perSessionLimit = safeLimit
    self.entriesBySession = Self.sanitize(
      entriesBySession,
      perSessionLimit: safeLimit)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedEntries =
      (try? container.decodeIfPresent(
        [UUID: [TatwoCLICommandHistoryEntry]].self,
        forKey: .entriesBySession)) ?? [:]
    let decodedLimit =
      (try? container.decodeIfPresent(Int.self, forKey: .perSessionLimit)) ?? 200
    self.init(
      entriesBySession: decodedEntries,
      perSessionLimit: decodedLimit)
  }

  public func entries(for sessionID: UUID) -> [TatwoCLICommandHistoryEntry] {
    entriesBySession[sessionID] ?? []
  }

  public func recallableCommands(for sessionID: UUID) -> [String] {
    entries(for: sessionID).compactMap { entry in
      guard entry.storageDecision == .stored else { return nil }
      return entry.command
    }
  }

  @discardableResult
  public mutating func record(
    command: String,
    sessionID: UUID,
    engine: TatwoNativeCLISessionBook.Engine,
    entryID: UUID,
    executedAt: Date,
    workdirToken: String? = nil,
    policy: TatwoCLICommandSensitivityPolicy = .init()
  ) -> TatwoCLIHistoryStorageDecision {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let decision = policy.decision(for: trimmed)
    guard decision != .excluded else { return decision }
    guard perSessionLimit > 0 else { return decision }

    let entry = TatwoCLICommandHistoryEntry(
      id: entryID,
      sessionID: sessionID,
      engine: engine,
      command: decision == .stored ? trimmed : nil,
      displayPreview: decision == .stored ? trimmed : policy.redactedPreview,
      executedAt: executedAt,
      workdirToken: workdirToken,
      storageDecision: decision)

    var sessionEntries = entriesBySession[sessionID] ?? []
    if decision == .stored,
      let last = sessionEntries.last,
      last.storageDecision == .stored,
      last.command == entry.command
    {
      sessionEntries[sessionEntries.count - 1] = TatwoCLICommandHistoryEntry(
        id: last.id,
        sessionID: sessionID,
        engine: engine,
        command: entry.command,
        displayPreview: entry.displayPreview,
        executedAt: executedAt,
        workdirToken: workdirToken,
        storageDecision: .stored)
    } else {
      sessionEntries.append(entry)
    }

    if sessionEntries.count > perSessionLimit {
      sessionEntries.removeFirst(sessionEntries.count - perSessionLimit)
    }
    entriesBySession[sessionID] = sessionEntries
    return decision
  }

  private static func sanitize(
    _ entriesBySession: [UUID: [TatwoCLICommandHistoryEntry]],
    perSessionLimit: Int
  ) -> [UUID: [TatwoCLICommandHistoryEntry]] {
    guard perSessionLimit > 0 else { return [:] }

    return entriesBySession.reduce(into: [:]) { result, element in
      let safeEntries = element.value
        .filter { $0.storageDecision != .excluded }
        .map { entry in
          TatwoCLICommandHistoryEntry(
            id: entry.id,
            sessionID: element.key,
            engine: entry.engine,
            command: entry.command,
            displayPreview: entry.displayPreview,
            executedAt: entry.executedAt,
            workdirToken: entry.workdirToken,
            storageDecision: entry.storageDecision)
        }
      if !safeEntries.isEmpty {
        result[element.key] = Array(safeEntries.suffix(perSessionLimit))
      }
    }
  }
}

public enum TatwoCLIHistoryNavigationDirection:
  String,
  Codable,
  Sendable,
  Equatable
{
  case up
  case down
  case escape
}

public struct TatwoCLIHistoryNavigationState: Codable, Sendable, Equatable {
  public let draft: String
  public let cursor: Int?

  public init(draft: String, cursor: Int? = nil) {
    self.draft = draft
    self.cursor = cursor
  }
}

public struct TatwoCLIHistoryNavigationResult: Codable, Sendable, Equatable {
  public let state: TatwoCLIHistoryNavigationState
  public let value: String

  public init(state: TatwoCLIHistoryNavigationState, value: String) {
    self.state = state
    self.value = value
  }
}

public enum TatwoCLIHistoryNavigator {
  public static func navigate(
    _ direction: TatwoCLIHistoryNavigationDirection,
    state: TatwoCLIHistoryNavigationState,
    commands: [String]
  ) -> TatwoCLIHistoryNavigationResult {
    guard !commands.isEmpty else {
      return TatwoCLIHistoryNavigationResult(state: state, value: state.draft)
    }

    switch direction {
    case .up:
      let nextCursor = max(0, (state.cursor ?? commands.count) - 1)
      return TatwoCLIHistoryNavigationResult(
        state: TatwoCLIHistoryNavigationState(
          draft: state.draft,
          cursor: nextCursor),
        value: commands[nextCursor])

    case .down:
      guard let cursor = state.cursor else {
        return TatwoCLIHistoryNavigationResult(state: state, value: state.draft)
      }
      let nextCursor = cursor + 1
      guard nextCursor < commands.count else {
        return TatwoCLIHistoryNavigationResult(
          state: TatwoCLIHistoryNavigationState(draft: state.draft),
          value: state.draft)
      }
      return TatwoCLIHistoryNavigationResult(
        state: TatwoCLIHistoryNavigationState(
          draft: state.draft,
          cursor: nextCursor),
        value: commands[nextCursor])

    case .escape:
      return TatwoCLIHistoryNavigationResult(
        state: TatwoCLIHistoryNavigationState(draft: state.draft),
        value: state.draft)
    }
  }
}
