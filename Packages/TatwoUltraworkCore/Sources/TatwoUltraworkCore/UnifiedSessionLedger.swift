import CryptoKit
import Foundation

public enum TatwoSessionEventKind: String, Codable, Sendable {
  case thread, discussion, loop, modelTurn = "model_turn", toolAction = "tool_action", receipt
}

public struct TatwoUnifiedSessionEventV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let id: String
  public let threadID: String
  public let discussionID: String?
  public let provider: String
  public let providerSessionID: String?
  public let kind: TatwoSessionEventKind
  public let occurredAt: Date
  public let summary: String

  public init(
    schema: String = "TatwoUnifiedSessionEventV1",
    id: String,
    threadID: String,
    discussionID: String? = nil,
    provider: String,
    providerSessionID: String? = nil,
    kind: TatwoSessionEventKind,
    occurredAt: Date = Date(),
    summary: String
  ) {
    self.schema = schema
    self.id = id
    self.threadID = threadID
    self.discussionID = discussionID
    self.provider = provider
    self.providerSessionID = providerSessionID
    self.kind = kind
    self.occurredAt = occurredAt
    self.summary = TatwoPrivacyRedactor.redacted(summary)
  }

  private enum CodingKeys: String, CodingKey {
    case schema, id, threadID, discussionID, provider, providerSessionID, kind, occurredAt, summary
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decodeIfPresent(String.self, forKey: .schema)
      ?? "TatwoUnifiedSessionEventV1"
    id = try container.decode(String.self, forKey: .id)
    threadID = try container.decode(String.self, forKey: .threadID)
    discussionID = try container.decodeIfPresent(String.self, forKey: .discussionID)
    provider = try container.decode(String.self, forKey: .provider)
    providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
    kind = try container.decode(TatwoSessionEventKind.self, forKey: .kind)
    if let encodedTime = try? container.decode(Double.self, forKey: .occurredAt) {
      let seconds = encodedTime > 10_000_000_000 ? encodedTime / 1_000 : encodedTime
      occurredAt = Date(timeIntervalSince1970: seconds)
    } else {
      let raw = try container.decode(String.self, forKey: .occurredAt)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let standard = ISO8601DateFormatter()
      guard let date = fractional.date(from: raw) ?? standard.date(from: raw) else {
        throw DecodingError.dataCorruptedError(
          forKey: .occurredAt, in: container, debugDescription: "Invalid event date")
      }
      occurredAt = date
    }
    summary = try container.decode(String.self, forKey: .summary)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(id, forKey: .id)
    try container.encode(threadID, forKey: .threadID)
    try container.encodeIfPresent(discussionID, forKey: .discussionID)
    try container.encode(provider, forKey: .provider)
    try container.encodeIfPresent(providerSessionID, forKey: .providerSessionID)
    try container.encode(kind, forKey: .kind)
    try container.encode(occurredAt.timeIntervalSince1970, forKey: .occurredAt)
    try container.encode(summary, forKey: .summary)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.schema == rhs.schema
      && lhs.id == rhs.id
      && lhs.threadID == rhs.threadID
      && lhs.discussionID == rhs.discussionID
      && lhs.provider == rhs.provider
      && lhs.providerSessionID == rhs.providerSessionID
      && lhs.kind == rhs.kind
      && abs(lhs.occurredAt.timeIntervalSince1970 - rhs.occurredAt.timeIntervalSince1970)
        < 0.000_001
      && lhs.summary == rhs.summary
  }
}

public struct TatwoUnifiedSessionCorruptionReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let lineNumber: Int
  public let lineSHA256: String
  public let reason: String

  public init(
    schema: String = "TatwoUnifiedSessionCorruptionReceiptV1",
    lineNumber: Int,
    lineSHA256: String,
    reason: String
  ) {
    self.schema = schema
    self.lineNumber = lineNumber
    self.lineSHA256 = lineSHA256
    self.reason = TatwoPrivacyRedactor.redacted(reason)
  }
}

public struct TatwoUnifiedSessionLedgerReadV1: Codable, Sendable, Equatable {
  public let schema: String
  public let events: [TatwoUnifiedSessionEventV1]
  public let corruptionReceipts: [TatwoUnifiedSessionCorruptionReceiptV1]

  public init(
    schema: String = "TatwoUnifiedSessionLedgerReadV1",
    events: [TatwoUnifiedSessionEventV1],
    corruptionReceipts: [TatwoUnifiedSessionCorruptionReceiptV1]
  ) {
    self.schema = schema
    self.events = events
    self.corruptionReceipts = corruptionReceipts
  }
}

public enum TatwoUnifiedSessionActivityProjection {
  public static func latestActivityByThreadID(
    from events: [TatwoUnifiedSessionEventV1]
  ) -> [String: Date] {
    events.reduce(into: [:]) { result, event in
      if let current = result[event.threadID], current >= event.occurredAt {
        return
      }
      result[event.threadID] = event.occurredAt
    }
  }

  public static func activityDate(
    threadID: String,
    fallback: Date,
    latestActivityByThreadID: [String: Date]
  ) -> Date {
    guard let ledgerActivity = latestActivityByThreadID[threadID] else {
      return fallback
    }
    return max(ledgerActivity, fallback)
  }
}

public struct TatwoUnifiedSessionMigrationReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let source: String
  public let candidateEvents: Int
  public let appendedEvents: Int
  public let totalEvents: Int

  public init(
    schema: String = "TatwoUnifiedSessionMigrationReceiptV1",
    source: String,
    candidateEvents: Int,
    appendedEvents: Int,
    totalEvents: Int
  ) {
    self.schema = schema
    self.source = TatwoPrivacyRedactor.redacted(source)
    self.candidateEvents = candidateEvents
    self.appendedEvents = appendedEvents
    self.totalEvents = totalEvents
  }
}

public struct TatwoUnifiedSessionLedger: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  public static func `default`(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    let support = TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
    return Self(fileURL: support.appendingPathComponent("sessions/unified-session-ledger.jsonl"))
  }

  public func append(_ event: TatwoUnifiedSessionEventV1) throws {
    _ = try append(contentsOf: [event])
  }

  @discardableResult
  public func append(contentsOf events: [TatwoUnifiedSessionEventV1]) throws -> Int {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try TatwoFileLock.withExclusiveLock(for: fileURL) {
      let existingIDs = Set(try inspectUnlocked().events.map(\.id))
      var seen = existingIDs
      let additions = events.filter { seen.insert($0.id).inserted }
      guard !additions.isEmpty else { return 0 }
      let encoder = JSONEncoder()
      var data = Data()
      for event in additions {
        data.append(try encoder.encode(event))
        data.append(0x0A)
      }
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        try data.write(to: fileURL, options: [.atomic])
      } else {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
      }
      return additions.count
    }
  }

  public func load() throws -> [TatwoUnifiedSessionEventV1] {
    try inspect().events
  }

  public func inspect() throws -> TatwoUnifiedSessionLedgerReadV1 {
    try TatwoFileLock.withExclusiveLock(for: fileURL) {
      try inspectUnlocked()
    }
  }

  @discardableResult
  public func migrate(
    document: TatwoNativeChatStoreDocument,
    source: String = "native-chat-store"
  ) throws -> TatwoUnifiedSessionMigrationReceiptV1 {
    let candidates = TatwoUnifiedSessionImportAdapter.events(from: document)
    let appended = try append(contentsOf: candidates)
    return TatwoUnifiedSessionMigrationReceiptV1(
      source: source,
      candidateEvents: candidates.count,
      appendedEvents: appended,
      totalEvents: try load().count)
  }

  private func inspectUnlocked() throws -> TatwoUnifiedSessionLedgerReadV1 {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return TatwoUnifiedSessionLedgerReadV1(events: [], corruptionReceipts: [])
    }
    let decoder = JSONDecoder()
    var events: [TatwoUnifiedSessionEventV1] = []
    var corruptions: [TatwoUnifiedSessionCorruptionReceiptV1] = []
    let lines = try String(contentsOf: fileURL, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() where !line.isEmpty {
      let data = Data(line.utf8)
      do {
        events.append(try decoder.decode(TatwoUnifiedSessionEventV1.self, from: data))
      } catch {
        corruptions.append(TatwoUnifiedSessionCorruptionReceiptV1(
          lineNumber: index + 1,
          lineSHA256: Self.sha256(data),
          reason: "decode_failed:\(String(describing: error))"))
      }
    }
    return TatwoUnifiedSessionLedgerReadV1(
      events: events.sorted {
        if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
        return $0.occurredAt < $1.occurredAt
      },
      corruptionReceipts: corruptions)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public enum TatwoUnifiedSessionImportAdapter {
  public static func events(
    from document: TatwoNativeChatStoreDocument
  ) -> [TatwoUnifiedSessionEventV1] {
    let threads = document.threads + document.projects.flatMap(\.threads)
    return threads.flatMap(events(from:))
  }

  public static func events(
    from thread: TatwoNativeChatThread
  ) -> [TatwoUnifiedSessionEventV1] {
    let threadID = thread.id.uuidString.lowercased()
    var events = [
      TatwoUnifiedSessionEventV1(
        id: "thread:\(threadID):\(microseconds(thread.updatedAt))",
        threadID: threadID,
        provider: "tatwo",
        kind: .thread,
        occurredAt: thread.updatedAt,
        summary: thread.title)
    ]
    events += (thread.messages ?? []).map {
      messageEvent($0, threadID: threadID, discussionID: nil, handles: thread.adapterSessionHandles)
    }
    for discussion in thread.discussions {
      let discussionID = discussion.id.uuidString.lowercased()
      let occurredAt = isoDate(discussion.createdISO) ?? thread.createdAt
      events.append(TatwoUnifiedSessionEventV1(
        id: "discussion:\(threadID):\(discussionID)",
        threadID: threadID,
        discussionID: discussionID,
        provider: "tatwo",
        kind: .discussion,
        occurredAt: occurredAt,
        summary: discussion.title))
      events += discussion.messages.map {
        messageEvent(
          $0,
          threadID: threadID,
          discussionID: discussionID,
          handles: discussion.adapterSessionHandles)
      }
    }
    return events
  }

  private static func messageEvent(
    _ message: TatwoNativeChatStoredMessage,
    threadID: String,
    discussionID: String?,
    handles: [TatwoNativeAdapterSessionHandle]
  ) -> TatwoUnifiedSessionEventV1 {
    let provider = provider(for: message)
    let providerSessionID = handles.last {
      guard !$0.providerSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
      }
      if let modelID = message.modelID {
        return $0.modelID == modelID || $0.modelID == nil
      }
      return $0.modelID == nil
    }?.providerSessionID
    return TatwoUnifiedSessionEventV1(
      id: "message:\(threadID):\(discussionID ?? "main"):\(message.id)",
      threadID: threadID,
      discussionID: discussionID,
      provider: provider,
      providerSessionID: providerSessionID,
      kind: message.eventKind == .toolUse ? .toolAction : .modelTurn,
      occurredAt: message.createdAt,
      summary: "[\(message.role)] \(message.text)")
  }

  private static func provider(for message: TatwoNativeChatStoredMessage) -> String {
    if message.role.lowercased() == "user" { return "user" }
    let model = (message.modelID ?? "").lowercased()
    if model.contains("grok") { return "grok" }
    if model.contains("minimax") { return "minimax" }
    if ["fable", "claude", "sonnet", "opus", "haiku"].contains(where: model.contains) {
      return "claude"
    }
    if model.contains("gpt") || model.contains("codex") { return "codex" }
    return model.isEmpty ? "tatwo" : model
  }

  private static func microseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
  }

  private static func isoDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}
