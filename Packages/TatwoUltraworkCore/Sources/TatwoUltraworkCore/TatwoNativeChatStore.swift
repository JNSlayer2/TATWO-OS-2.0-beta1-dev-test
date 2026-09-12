import CryptoKit
import Darwin
import Foundation

public struct TatwoNativeChatStoreDocument: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var updatedAt: Date
  /// Codex-style standalone chats. These are not project children and must be
  /// rendered separately from `projects[].threads`.
  public var threads: [TatwoNativeChatThread]
  public var projects: [TatwoNativeChatProject]
  /// The discussion selected when Chat last closed. Thread/project location is
  /// resolved from the discussion ID after the document reloads.
  public var selectedDiscussionID: UUID?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case updatedAt
    case threads
    case projects
    case selectedDiscussionID
  }

  public init(
    schemaVersion: Int = 1,
    updatedAt: Date = Date(),
    threads: [TatwoNativeChatThread] = [],
    projects: [TatwoNativeChatProject] = [],
    selectedDiscussionID: UUID? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.updatedAt = updatedAt
    self.threads = threads
    self.projects = projects
    self.selectedDiscussionID = selectedDiscussionID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    self.threads = try container.decodeIfPresent([TatwoNativeChatThread].self, forKey: .threads) ?? []
    self.projects = try container.decodeIfPresent([TatwoNativeChatProject].self, forKey: .projects) ?? []
    self.selectedDiscussionID = try container.decodeIfPresent(UUID.self, forKey: .selectedDiscussionID)
  }
}

public enum TatwoNativeChatStoreError: Error, LocalizedError, Equatable {
  case migrationRequired

  public var errorDescription: String? {
    switch self {
    case .migrationRequired:
      "native_chat_migration_required"
    }
  }
}

public struct TatwoNativeChatStore: Sendable {
  public let url: URL
  public let fallbackURLs: [URL]
  public let unifiedLedger: TatwoUnifiedSessionLedger?

  public init(
    url: URL,
    fallbackURLs: [URL] = [],
    unifiedLedger: TatwoUnifiedSessionLedger? = nil,
    mirrorsToUnifiedLedger: Bool = true
  ) {
    self.url = url
    self.fallbackURLs = fallbackURLs.filter { $0.standardizedFileURL != url.standardizedFileURL }
    self.unifiedLedger = mirrorsToUnifiedLedger
      ? unifiedLedger ?? TatwoUnifiedSessionLedger(
        fileURL: url.deletingLastPathComponent()
          .appendingPathComponent("sessions/unified-session-ledger.jsonl"))
      : nil
  }

  public func load() throws -> TatwoNativeChatStoreDocument {
    // Reconnect / cold start only restores stable transcript material.
    // Legacy files that still contain unfinished stream tails are readable
    // but those rows are sealed out so half-messages never reappear in UI.
    if FileManager.default.fileExists(atPath: url.path) {
      return ChatStreamPersistence.sealing(try Self.decode(url))
    }
    let fallbacks = fallbackURLs.filter {
      FileManager.default.fileExists(atPath: $0.path)
    }
    guard let first = fallbacks.first else {
      return TatwoNativeChatStoreDocument()
    }
    let firstData = try Data(contentsOf: first)
    if fallbacks.dropFirst().contains(where: {
      (try? Data(contentsOf: $0)) != firstData
    }) {
      throw TatwoNativeChatStoreError.migrationRequired
    }
    let decoded = try JSONDecoder.tatwoNativeChat.decode(
      TatwoNativeChatStoreDocument.self,
      from: firstData)
    return ChatStreamPersistence.sealing(decoded)
  }

  public func save(_ document: TatwoNativeChatStoreDocument) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      let existingFallbacks = fallbackURLs.filter {
        FileManager.default.fileExists(atPath: $0.path)
      }
      if let first = existingFallbacks.first {
        let firstData = try Data(contentsOf: first)
        if existingFallbacks.dropFirst().contains(where: {
          (try? Data(contentsOf: $0)) != firstData
        }) {
          throw TatwoNativeChatStoreError.migrationRequired
        }
      }
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Fail-closed: unfinished stream tails (status streaming/thinking/…) never land on disk.
    var copy = ChatStreamPersistence.sealing(document)
    copy.updatedAt = Date()
    if let unifiedLedger {
      _ = try unifiedLedger.migrate(document: copy, source: url.path)
    }
    let data = try JSONEncoder.tatwoNativeChat.encode(copy)
    try data.write(to: url, options: [.atomic])
  }

  @discardableResult
  public func migrateToUnifiedLedger() throws -> TatwoUnifiedSessionMigrationReceiptV1? {
    guard let unifiedLedger else { return nil }
    return try unifiedLedger.migrate(document: load(), source: url.path)
  }

  public static func defaultStore(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> TatwoNativeChatStore {
    if let explicitStore = environment["TATWO_ULTRAWORK_NATIVE_CHAT_STORE"],
       !explicitStore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return TatwoNativeChatStore(url: URL(fileURLWithPath: explicitStore))
    }
    let canonical = defaultURL(environment: environment, fileManager: fileManager)
    let fallbacks = shouldUseLegacyDefaultFallback(canonical: canonical, fileManager: fileManager)
      ? legacyDefaultURLs(fileManager: fileManager)
      : []
    return TatwoNativeChatStore(url: canonical, fallbackURLs: fallbacks)
  }

  public static func canonicalDefaultURL(in applicationSupportRoot: URL) -> URL {
    applicationSupportRoot
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("native-chat-threads.json")
  }

  public static func legacyDefaultURLs(in applicationSupportRoot: URL) -> [URL] {
    TatwoRuntimeLayout.legacyApplicationSupportRoots(
      applicationSupportBase: applicationSupportRoot
    ).map {
      $0.appendingPathComponent("native-chat-threads.json")
    }
  }

  public static func defaultURL(fileManager: FileManager = .default) -> URL {
    defaultURL(environment: ProcessInfo.processInfo.environment, fileManager: fileManager)
  }

  public static func defaultURL(environment: [String: String], fileManager: FileManager = .default) -> URL {
    TatwoRuntimeLayout.applicationSupportRoot(
      environment: environment,
      fileManager: fileManager
    ).appendingPathComponent("native-chat-threads.json")
  }

  public static func legacyDefaultURLs(fileManager: FileManager = .default) -> [URL] {
    let root = (try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return legacyDefaultURLs(in: root)
  }

  private static func shouldUseLegacyDefaultFallback(canonical: URL, fileManager: FileManager) -> Bool {
    let root = (try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let defaultCanonical = canonicalDefaultURL(in: root).standardizedFileURL
    return canonical.standardizedFileURL == defaultCanonical
  }

  private static func decode(_ url: URL) throws -> TatwoNativeChatStoreDocument {
    try JSONDecoder.tatwoNativeChat.decode(
      TatwoNativeChatStoreDocument.self,
      from: Data(contentsOf: url))
  }
}

private extension JSONEncoder {
  static var tatwoNativeChat: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private extension JSONDecoder {
  static var tatwoNativeChat: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
