import Foundation

/// Device-local, unsent Chat composer state.
///
/// This file is deliberately separate from `TatwoNativeChatStoreDocument`:
/// native threads are a shared sync surface, while an unfinished prompt must
/// never leave the device that created it.
public struct TatwoChatComposerDraftDocument: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var updatedAt: Date
  public var draftsBySessionKey: [String: String]
  /// Per-session freshness is required to distinguish an unsent draft from a
  /// stale file row whose matching user turn was already accepted into the
  /// canonical transcript journal before a clear-write failed.
  public var draftUpdatedAtBySessionKey: [String: Date]
  /// Latest canonical user-message identity already accounted for by the
  /// local draft state. This is a durable acknowledgement marker, not synced
  /// transcript data. It disambiguates a newly retyped identical draft from a
  /// stale pre-clear row even when filesystem timestamps share one-second
  /// encoding precision.
  public var acknowledgedAcceptedMessageIDBySessionKey: [String: String]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case updatedAt
    case draftsBySessionKey
    case draftUpdatedAtBySessionKey
    case acknowledgedAcceptedMessageIDBySessionKey
  }

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    updatedAt: Date = Date(),
    draftsBySessionKey: [String: String] = [:],
    draftUpdatedAtBySessionKey: [String: Date] = [:],
    acknowledgedAcceptedMessageIDBySessionKey: [String: String] = [:]
  ) {
    let normalizedDrafts = Self.normalized(draftsBySessionKey)
    self.schemaVersion = schemaVersion
    self.updatedAt = updatedAt
    self.draftsBySessionKey = normalizedDrafts
    self.draftUpdatedAtBySessionKey = Self.normalizedDates(
      draftUpdatedAtBySessionKey,
      draftKeys: normalizedDrafts.keys,
      fallback: updatedAt)
    self.acknowledgedAcceptedMessageIDBySessionKey =
      Self.normalizedMessageIDs(acknowledgedAcceptedMessageIDBySessionKey)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    let updatedAt =
      try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    let drafts = Self.normalized(
      try container.decodeIfPresent(
        [String: String].self,
        forKey: .draftsBySessionKey) ?? [:])
    let decodedDates = try container.decodeIfPresent(
      [String: Date].self,
      forKey: .draftUpdatedAtBySessionKey) ?? [:]
    let acknowledgedMessageIDs = try container.decodeIfPresent(
      [String: String].self,
      forKey: .acknowledgedAcceptedMessageIDBySessionKey) ?? [:]

    self.schemaVersion = schemaVersion
    self.updatedAt = updatedAt
    self.draftsBySessionKey = drafts
    self.draftUpdatedAtBySessionKey = Self.normalizedDates(
      decodedDates,
      draftKeys: drafts.keys,
      fallback: updatedAt)
    self.acknowledgedAcceptedMessageIDBySessionKey =
      Self.normalizedMessageIDs(acknowledgedMessageIDs)
  }

  private static func normalized(_ drafts: [String: String]) -> [String: String] {
    drafts.reduce(into: [:]) { result, entry in
      guard !entry.value.isEmpty else { return }
      result[entry.key] = entry.value
    }
  }

  private static func normalizedDates(
    _ dates: [String: Date],
    draftKeys: Dictionary<String, String>.Keys,
    fallback: Date
  ) -> [String: Date] {
    draftKeys.reduce(into: [:]) { result, key in
      result[key] = dates[key] ?? fallback
    }
  }

  private static func normalizedMessageIDs(
    _ messageIDs: [String: String]
  ) -> [String: String] {
    messageIDs.reduce(into: [:]) { result, entry in
      let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty, !value.isEmpty else { return }
      result[key] = value
    }
  }
}

public enum TatwoChatComposerDraftStoreError: Error, LocalizedError, Equatable {
  case unsupportedSchema(Int)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version):
      "chat_composer_draft_schema_unsupported:\(version)"
    }
  }
}

public struct TatwoChatComposerDraftStore: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() throws -> TatwoChatComposerDraftDocument {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return TatwoChatComposerDraftDocument()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(
      TatwoChatComposerDraftDocument.self,
      from: Data(contentsOf: url))
    guard (1...TatwoChatComposerDraftDocument.currentSchemaVersion)
      .contains(document.schemaVersion)
    else {
      throw TatwoChatComposerDraftStoreError.unsupportedSchema(document.schemaVersion)
    }
    return TatwoChatComposerDraftDocument(
      schemaVersion: document.schemaVersion,
      updatedAt: document.updatedAt,
      draftsBySessionKey: document.draftsBySessionKey,
      draftUpdatedAtBySessionKey: document.draftUpdatedAtBySessionKey,
      acknowledgedAcceptedMessageIDBySessionKey:
        document.acknowledgedAcceptedMessageIDBySessionKey)
  }

  public func save(
    _ draftsBySessionKey: [String: String],
    refreshedSessionKeys: Set<String> = [],
    acknowledgedAcceptedMessageIDBySessionKey: [String: String] = [:]
  ) throws {
    let previous = try load()
    let now = Date()
    let normalizedDrafts = draftsBySessionKey.reduce(into: [String: String]()) {
      result,
      entry in
      guard !entry.value.isEmpty else { return }
      result[entry.key] = entry.value
    }
    let draftUpdatedAtBySessionKey = normalizedDrafts.reduce(
      into: [String: Date]()
    ) { result, entry in
      if !refreshedSessionKeys.contains(entry.key),
         previous.draftsBySessionKey[entry.key] == entry.value,
         let previousDate = previous.draftUpdatedAtBySessionKey[entry.key]
      {
        result[entry.key] = previousDate
      } else {
        result[entry.key] = now
      }
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(TatwoChatComposerDraftDocument(
      updatedAt: now,
      draftsBySessionKey: normalizedDrafts,
      draftUpdatedAtBySessionKey: draftUpdatedAtBySessionKey,
      acknowledgedAcceptedMessageIDBySessionKey:
        acknowledgedAcceptedMessageIDBySessionKey))
    try data.write(to: url, options: [.atomic])
  }

  public static func colocated(with nativeChatStoreURL: URL) -> TatwoChatComposerDraftStore {
    TatwoChatComposerDraftStore(
      url: nativeChatStoreURL.deletingLastPathComponent()
        .appendingPathComponent("chat-composer-drafts-v1.json"))
  }
}
