import Foundation

public struct TatwoBrowserBookmark:
  Codable,
  Sendable,
  Equatable,
  Identifiable
{
  public let id: UUID
  public let canonicalURL: String
  public let title: String
  public let note: String?
  public let tags: [String]
  public private(set) var goalID: String?
  public let contractID: String?
  public let sourceLaneID: TatwoBrowserLaneID?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: UUID,
    canonicalURL: String,
    title: String,
    note: String? = nil,
    tags: [String] = [],
    goalID: String? = nil,
    contractID: String? = nil,
    sourceLaneID: TatwoBrowserLaneID? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.canonicalURL = canonicalURL
    self.title = title
    self.note = note
    self.tags = TatwoBrowserKnowledgeNormalization.tags(tags)
    self.goalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
    self.contractID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(contractID)
    self.sourceLaneID = sourceLaneID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  fileprivate mutating func markGoal(_ goalID: String?) {
    self.goalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
  }
}

public enum TatwoBrowserBookmarkRecordResult: Codable, Sendable, Equatable {
  case inserted(UUID)
  case updated(UUID)
}

public struct TatwoBrowserBookmarkStore: Codable, Sendable, Equatable {
  public private(set) var bookmarks: [TatwoBrowserBookmark]

  public init(bookmarks: [TatwoBrowserBookmark] = []) {
    self.bookmarks = []
    for bookmark in bookmarks {
      _ = record(bookmark)
    }
  }

  @discardableResult
  public mutating func record(
    _ bookmark: TatwoBrowserBookmark
  ) -> TatwoBrowserBookmarkRecordResult {
    if let index = bookmarks.firstIndex(where: {
      $0.canonicalURL == bookmark.canonicalURL
        && $0.goalID == bookmark.goalID
    }) {
      let existing = bookmarks[index]
      bookmarks[index] = TatwoBrowserBookmark(
        id: existing.id,
        canonicalURL: existing.canonicalURL,
        title: bookmark.title,
        note: bookmark.note,
        tags: bookmark.tags,
        goalID: bookmark.goalID,
        contractID: bookmark.contractID,
        sourceLaneID: bookmark.sourceLaneID,
        createdAt: existing.createdAt,
        updatedAt: bookmark.updatedAt)
      return .updated(existing.id)
    }

    bookmarks.append(bookmark)
    return .inserted(bookmark.id)
  }

  public func bookmarks(goalID: String?) -> [TatwoBrowserBookmark] {
    let normalizedGoalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
    return bookmarks.filter { $0.goalID == normalizedGoalID }
  }

  public func search(_ query: String) -> [TatwoBrowserBookmark] {
    let needle = TatwoBrowserKnowledgeNormalization.searchText(query)
    guard !needle.isEmpty else { return bookmarks }

    return bookmarks.filter { bookmark in
      let haystack = TatwoBrowserKnowledgeNormalization.searchText(
        [
          bookmark.canonicalURL,
          bookmark.title,
          bookmark.note ?? "",
          bookmark.tags.joined(separator: " "),
        ].joined(separator: "\n"))
      return haystack.contains(needle)
    }
  }

  @discardableResult
  public mutating func markGoal(
    bookmarkID: UUID,
    goalID: String?,
    updatedAt: Date
  ) -> Bool {
    guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
      return false
    }

    var marked = bookmarks[index]
    marked.markGoal(goalID)
    bookmarks[index] = TatwoBrowserBookmark(
      id: marked.id,
      canonicalURL: marked.canonicalURL,
      title: marked.title,
      note: marked.note,
      tags: marked.tags,
      goalID: marked.goalID,
      contractID: marked.contractID,
      sourceLaneID: marked.sourceLaneID,
      createdAt: marked.createdAt,
      updatedAt: updatedAt)

    bookmarks.removeAll {
      $0.id != bookmarkID
        && $0.canonicalURL == marked.canonicalURL
        && $0.goalID == marked.goalID
    }
    return true
  }
}

public enum TatwoBrowserHistoryTransition:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable,
  CaseIterable
{
  case typed
  case link
  case redirect
  case reload
  case popup
  case restored
}

public struct TatwoBrowserHistoryEntry:
  Codable,
  Sendable,
  Equatable,
  Identifiable
{
  public let id: UUID
  public let canonicalURL: String
  public let title: String
  public let domain: String
  public let laneID: TatwoBrowserLaneID
  public private(set) var goalID: String?
  public let visitedAt: Date
  public let transition: TatwoBrowserHistoryTransition

  public init(
    id: UUID,
    canonicalURL: String,
    title: String,
    domain: String,
    laneID: TatwoBrowserLaneID,
    goalID: String? = nil,
    visitedAt: Date,
    transition: TatwoBrowserHistoryTransition
  ) {
    self.id = id
    self.canonicalURL = canonicalURL
    self.title = title
    self.domain = domain
    self.laneID = laneID
    self.goalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
    self.visitedAt = visitedAt
    self.transition = transition
  }

  fileprivate mutating func markGoal(_ goalID: String?) {
    self.goalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
  }
}

public enum TatwoBrowserHistoryRecordResult: Codable, Sendable, Equatable {
  case appended(UUID)
  case deduplicated(UUID)
  case skippedPersistenceDisabled
  case skippedRetentionDisabled
}

public struct TatwoBrowserHistoryStore: Codable, Sendable, Equatable {
  public static let defaultMaximumEntryCount = 2_000
  public static let defaultMaximumAge: TimeInterval = 90 * 24 * 60 * 60
  public static let defaultDeduplicationInterval: TimeInterval = 5

  public private(set) var entries: [TatwoBrowserHistoryEntry]
  public let maximumEntryCount: Int
  public let maximumAge: TimeInterval
  public let deduplicationInterval: TimeInterval

  public init(
    entries: [TatwoBrowserHistoryEntry] = [],
    maximumEntryCount: Int = TatwoBrowserHistoryStore.defaultMaximumEntryCount,
    maximumAge: TimeInterval = TatwoBrowserHistoryStore.defaultMaximumAge,
    deduplicationInterval: TimeInterval =
      TatwoBrowserHistoryStore.defaultDeduplicationInterval
  ) {
    self.maximumEntryCount = max(0, maximumEntryCount)
    self.maximumAge = max(0, maximumAge)
    self.deduplicationInterval = max(0, deduplicationInterval)
    self.entries = entries
    if let newestDate = entries.map(\.visitedAt).max() {
      trim(referenceDate: newestDate)
    } else if self.maximumEntryCount == 0 {
      self.entries = []
    }
  }

  @discardableResult
  public mutating func record(
    _ entry: TatwoBrowserHistoryEntry,
    persistenceEnabled: Bool = true
  ) -> TatwoBrowserHistoryRecordResult {
    guard persistenceEnabled else {
      return .skippedPersistenceDisabled
    }
    guard maximumEntryCount > 0 else {
      return .skippedRetentionDisabled
    }

    let result: TatwoBrowserHistoryRecordResult
    if let last = entries.last,
      last.canonicalURL == entry.canonicalURL,
      last.laneID == entry.laneID,
      last.goalID == entry.goalID,
      entry.visitedAt.timeIntervalSince(last.visitedAt) >= 0,
      entry.visitedAt.timeIntervalSince(last.visitedAt) <= deduplicationInterval
    {
      entries[entries.count - 1] = TatwoBrowserHistoryEntry(
        id: last.id,
        canonicalURL: entry.canonicalURL,
        title: entry.title,
        domain: entry.domain,
        laneID: entry.laneID,
        goalID: entry.goalID,
        visitedAt: entry.visitedAt,
        transition: entry.transition)
      result = .deduplicated(last.id)
    } else {
      entries.append(entry)
      result = .appended(entry.id)
    }

    trim(referenceDate: entry.visitedAt)
    return result
  }

  public func entries(goalID: String?) -> [TatwoBrowserHistoryEntry] {
    let normalizedGoalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
    return entries.filter { $0.goalID == normalizedGoalID }
  }

  public func search(_ query: String) -> [TatwoBrowserHistoryEntry] {
    let needle = TatwoBrowserKnowledgeNormalization.searchText(query)
    guard !needle.isEmpty else { return entries }
    return entries.filter { entry in
      TatwoBrowserKnowledgeNormalization.searchText(
        "\(entry.title)\n\(entry.domain)\n\(entry.canonicalURL)")
        .contains(needle)
    }
  }

  @discardableResult
  public mutating func markGoal(entryID: UUID, goalID: String?) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
      return false
    }
    entries[index].markGoal(goalID)
    return true
  }

  private mutating func trim(referenceDate: Date) {
    let cutoff = referenceDate.addingTimeInterval(-maximumAge)
    entries.removeAll { $0.visitedAt < cutoff }
    if entries.count > maximumEntryCount {
      entries.removeFirst(entries.count - maximumEntryCount)
    }
  }
}

public enum TatwoBrowserDownloadState:
  String,
  Codable,
  Sendable,
  Equatable,
  Hashable,
  CaseIterable
{
  case awaitingApproval
  case downloading
  case paused
  case cancelled
  case verifying
  case completed
  case failed
  case quarantined
}

public enum TatwoBrowserDownloadRisk:
  String,
  Codable,
  Sendable,
  Equatable,
  CaseIterable
{
  case document
  case archive
  case executable
  case unknown
}

public enum TatwoBrowserDownloadHashStatus: Codable, Sendable, Equatable {
  case pending
  case verified(sha256: String)
  case mismatch(expectedSHA256: String, actualSHA256: String)
  case failed(code: String)

  fileprivate var isValid: Bool {
    switch self {
    case .pending:
      true
    case let .verified(sha256):
      TatwoBrowserKnowledgeNormalization.isSHA256(sha256)
    case let .mismatch(expectedSHA256, actualSHA256):
      TatwoBrowserKnowledgeNormalization.isSHA256(expectedSHA256)
        && TatwoBrowserKnowledgeNormalization.isSHA256(actualSHA256)
    case let .failed(code):
      !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  fileprivate var isVerified: Bool {
    if case .verified = self {
      return true
    }
    return false
  }
}

public struct TatwoBrowserDownloadRecord:
  Codable,
  Sendable,
  Equatable,
  Identifiable
{
  public let id: UUID
  public let laneID: TatwoBrowserLaneID
  public private(set) var goalID: String?
  public let contractID: String?
  public let sourceDomain: String
  public let redactedSourceURL: String
  public let suggestedFilename: String
  public let destinationTokenID: String?
  public let mimeType: String?
  public let risk: TatwoBrowserDownloadRisk
  public private(set) var state: TatwoBrowserDownloadState
  public private(set) var receivedBytes: Int64
  public let expectedBytes: Int64?
  public private(set) var hashStatus: TatwoBrowserDownloadHashStatus
  public let startedAt: Date
  public private(set) var completedAt: Date?
  public let receiptID: String?

  public init(
    id: UUID,
    laneID: TatwoBrowserLaneID,
    goalID: String? = nil,
    contractID: String? = nil,
    sourceDomain: String,
    redactedSourceURL: String,
    suggestedFilename: String,
    destinationTokenID: String? = nil,
    mimeType: String? = nil,
    risk: TatwoBrowserDownloadRisk,
    state: TatwoBrowserDownloadState,
    receivedBytes: Int64,
    expectedBytes: Int64? = nil,
    hashStatus: TatwoBrowserDownloadHashStatus = .pending,
    startedAt: Date,
    completedAt: Date? = nil,
    receiptID: String? = nil
  ) {
    self.id = id
    self.laneID = laneID
    self.goalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
    self.contractID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(contractID)
    self.sourceDomain = sourceDomain
    self.redactedSourceURL = redactedSourceURL
    self.suggestedFilename = suggestedFilename
    self.destinationTokenID =
      TatwoBrowserKnowledgeNormalization.optionalIdentifier(destinationTokenID)
    self.mimeType = TatwoBrowserKnowledgeNormalization.optionalIdentifier(mimeType)
    self.risk = risk
    self.state = state
    let safeExpectedBytes = expectedBytes.map { max(0, $0) }
    self.expectedBytes = safeExpectedBytes
    self.receivedBytes = min(max(0, receivedBytes), safeExpectedBytes ?? Int64.max)
    self.hashStatus = hashStatus.isValid ? hashStatus : .pending
    self.startedAt = startedAt
    self.completedAt = state == .completed ? completedAt : nil
    self.receiptID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(receiptID)
  }

  fileprivate mutating func markGoal(_ goalID: String?) {
    self.goalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
  }

  fileprivate mutating func updateProgress(_ receivedBytes: Int64) {
    self.receivedBytes = receivedBytes
  }

  fileprivate mutating func transition(
    to state: TatwoBrowserDownloadState,
    completedAt: Date?
  ) {
    self.state = state
    self.completedAt = state == .completed ? completedAt : nil
  }

  fileprivate mutating func updateHashStatus(
    _ hashStatus: TatwoBrowserDownloadHashStatus
  ) {
    self.hashStatus = hashStatus
    switch hashStatus {
    case .mismatch:
      state = .quarantined
      completedAt = nil
    case .failed:
      state = .failed
      completedAt = nil
    case .pending, .verified:
      break
    }
  }
}

public struct TatwoBrowserDownloadLedger: Codable, Sendable, Equatable {
  public private(set) var records: [TatwoBrowserDownloadRecord]

  public init(records: [TatwoBrowserDownloadRecord] = []) {
    var seen = Set<UUID>()
    self.records = records.filter { seen.insert($0.id).inserted }
  }

  @discardableResult
  public mutating func record(_ record: TatwoBrowserDownloadRecord) -> Bool {
    guard !records.contains(where: { $0.id == record.id }) else {
      return false
    }
    records.append(record)
    return true
  }

  public func record(id: UUID) -> TatwoBrowserDownloadRecord? {
    records.first(where: { $0.id == id })
  }

  public func records(goalID: String?) -> [TatwoBrowserDownloadRecord] {
    let normalizedGoalID = TatwoBrowserKnowledgeNormalization.optionalIdentifier(goalID)
    return records.filter { $0.goalID == normalizedGoalID }
  }

  public func records(
    state: TatwoBrowserDownloadState
  ) -> [TatwoBrowserDownloadRecord] {
    records.filter { $0.state == state }
  }

  @discardableResult
  public mutating func markGoal(downloadID: UUID, goalID: String?) -> Bool {
    guard let index = records.firstIndex(where: { $0.id == downloadID }) else {
      return false
    }
    records[index].markGoal(goalID)
    return true
  }

  @discardableResult
  public mutating func updateProgress(
    downloadID: UUID,
    receivedBytes: Int64
  ) -> Bool {
    guard receivedBytes >= 0,
      let index = records.firstIndex(where: { $0.id == downloadID }),
      [.downloading, .paused].contains(records[index].state),
      records[index].expectedBytes.map({ receivedBytes <= $0 }) ?? true
    else {
      return false
    }
    records[index].updateProgress(receivedBytes)
    return true
  }

  @discardableResult
  public mutating func transition(
    downloadID: UUID,
    to nextState: TatwoBrowserDownloadState,
    completedAt: Date? = nil
  ) -> Bool {
    guard let index = records.firstIndex(where: { $0.id == downloadID }) else {
      return false
    }

    let record = records[index]
    guard Self.allowedTransitions[record.state, default: []].contains(nextState)
    else {
      return false
    }
    if nextState == .completed {
      guard record.hashStatus.isVerified,
        record.expectedBytes.map({ record.receivedBytes == $0 }) ?? true
      else {
        return false
      }
    }

    records[index].transition(to: nextState, completedAt: completedAt)
    return true
  }

  @discardableResult
  public mutating func updateHashStatus(
    downloadID: UUID,
    status: TatwoBrowserDownloadHashStatus
  ) -> Bool {
    guard status.isValid,
      let index = records.firstIndex(where: { $0.id == downloadID }),
      records[index].state == .verifying
    else {
      return false
    }
    records[index].updateHashStatus(status)
    return true
  }

  private static let allowedTransitions:
    [TatwoBrowserDownloadState: Set<TatwoBrowserDownloadState>] = [
      .awaitingApproval: [.downloading, .cancelled],
      .downloading: [.paused, .cancelled, .verifying, .failed],
      .paused: [.downloading, .cancelled, .failed],
      .verifying: [.completed, .failed, .quarantined],
      .cancelled: [],
      .completed: [],
      .failed: [],
      .quarantined: [],
    ]
}

private enum TatwoBrowserKnowledgeNormalization {
  static func optionalIdentifier(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func tags(_ values: [String]) -> [String] {
    var normalized: [String] = []
    var seen = Set<String>()
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX"))
      if seen.insert(key).inserted {
        normalized.append(trimmed)
      }
    }
    return normalized
  }

  static func searchText(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
  }

  static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy(\.isHexDigit)
  }
}
