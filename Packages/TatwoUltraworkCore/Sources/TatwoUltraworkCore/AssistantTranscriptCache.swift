import Foundation
import os

public struct TatwoAssistantTranscriptCacheKey: Hashable, Sendable {
  public let messageID: String
  public let utf8Count: Int
  public let textHash: UInt64
  public let parserVersion: Int
  private let markdown: String

  public init(
    messageID: String,
    markdown: String,
    parserVersion: Int = TatwoAssistantTranscriptCache.defaultParserVersion
  ) {
    self.messageID = messageID
    let hashed = Self.hashAndCount(markdown)
    self.utf8Count = hashed.count
    self.textHash = hashed.hash
    self.parserVersion = parserVersion
    self.markdown = markdown
  }

  /// Builds a collision-safe key from fingerprint metadata already maintained
  /// by the caller. Dictionary hashing stays fixed-size, while `markdown`
  /// remains an exact equality guard before a parsed payload can be reused.
  public init(
    messageID: String,
    markdown: String,
    utf8Count: Int,
    fingerprint: UInt64,
    parserVersion: Int = TatwoAssistantTranscriptCache.defaultParserVersion
  ) {
    self.messageID = messageID
    self.utf8Count = utf8Count
    self.textHash = fingerprint
    self.parserVersion = parserVersion
    self.markdown = markdown
  }

  public static func == (
    lhs: TatwoAssistantTranscriptCacheKey,
    rhs: TatwoAssistantTranscriptCacheKey
  ) -> Bool {
    lhs.messageID == rhs.messageID
      && lhs.utf8Count == rhs.utf8Count
      && lhs.textHash == rhs.textHash
      && lhs.parserVersion == rhs.parserVersion
      && lhs.markdown == rhs.markdown
  }

  public func hash(into hasher: inout Hasher) {
    // Keep dictionary lookup fixed-size. Exact markdown equality prevents a
    // fingerprint collision from returning another transcript's document.
    hasher.combine(messageID)
    hasher.combine(utf8Count)
    hasher.combine(textHash)
    hasher.combine(parserVersion)
  }

  fileprivate var estimatedResidentBytes: Int {
    MemoryLayout<Self>.stride
      + messageID.utf8.count
      + utf8Count
      + 64
  }

  private static func hashAndCount(_ text: String) -> (hash: UInt64, count: Int) {
    var value: UInt64 = 14_695_981_039_346_656_037
    var count = 0
    for byte in text.utf8 {
      value ^= UInt64(byte)
      value &*= 1_099_511_628_211
      count += 1
    }
    return (value, count)
  }
}

public struct TatwoAssistantTranscriptParseResult: Sendable {
  public let document: TatwoAssistantTranscriptDocument
  public let estimatedResidentBytes: Int

  fileprivate init(
    document: TatwoAssistantTranscriptDocument,
    estimatedResidentBytes: Int
  ) {
    self.document = document
    self.estimatedResidentBytes = estimatedResidentBytes
  }
}

public enum TatwoAssistantTranscriptThrottle {
  public static let longTextByteThreshold = 8 * 1_024
  public static let longTextDelay = Duration.milliseconds(100)

  public static func delay(for markdown: String) -> Duration? {
    delay(utf8Count: markdown.utf8.count)
  }

  public static func delay(utf8Count: Int) -> Duration? {
    utf8Count > longTextByteThreshold ? longTextDelay : nil
  }
}

@MainActor
public final class TatwoAssistantTranscriptCache {
  public typealias Parser = @Sendable (String) -> TatwoAssistantTranscriptDocument

  public struct RequestToken: Equatable, Sendable {
    fileprivate let generation: UInt64
    fileprivate let utf8Count: Int
    fileprivate let textHash: UInt64
    fileprivate let parserVersion: Int
  }

  /// Single public parser schema truth used by keys, caches, and App rendering.
  public nonisolated static let defaultParserVersion = 1
  public nonisolated static let defaultMaximumEntryCount = 24
  public nonisolated static let defaultMaximumResidentBytes =
    32 * 1_024 * 1_024

  private final class Entry {
    let key: TatwoAssistantTranscriptCacheKey
    var document: TatwoAssistantTranscriptDocument
    var residentBytes: Int
    weak var previous: Entry?
    var next: Entry?

    init(
      key: TatwoAssistantTranscriptCacheKey,
      document: TatwoAssistantTranscriptDocument,
      residentBytes: Int
    ) {
      self.key = key
      self.document = document
      self.residentBytes = residentBytes
    }
  }

  private let maximumEntryCount: Int
  private let maximumResidentBytes: Int
  public let parserVersion: Int
  private let parser: Parser
  private var entries: [TatwoAssistantTranscriptCacheKey: Entry] = [:]
  private var entriesByMessageID: [String: Entry] = [:]
  private var latestRequestByMessageID: [String: RequestToken] = [:]
  private var recentRequestMessageIDs: [String] = []
  private var nextRequestGeneration: UInt64 = 0
  private var leastRecentlyUsed: Entry?
  private var mostRecentlyUsed: Entry?
  private var residentBytes: Int = 0

  public convenience init(
    maximumEntryCount: Int = TatwoAssistantTranscriptCache.defaultMaximumEntryCount,
    maximumResidentBytes: Int = TatwoAssistantTranscriptCache.defaultMaximumResidentBytes,
    parserVersion: Int = TatwoAssistantTranscriptCache.defaultParserVersion
  ) {
    self.init(
      maximumEntryCount: maximumEntryCount,
      maximumResidentBytes: maximumResidentBytes,
      parserVersion: parserVersion,
      parser: TatwoAssistantTranscriptPresentation.document(markdown:))
  }

  public init(
    maximumEntryCount: Int = TatwoAssistantTranscriptCache.defaultMaximumEntryCount,
    maximumResidentBytes: Int = TatwoAssistantTranscriptCache.defaultMaximumResidentBytes,
    parserVersion: Int = TatwoAssistantTranscriptCache.defaultParserVersion,
    parser: @escaping Parser
  ) {
    self.maximumEntryCount = max(1, maximumEntryCount)
    self.maximumResidentBytes = max(1, maximumResidentBytes)
    self.parserVersion = parserVersion
    self.parser = parser
  }

  public var count: Int {
    entries.count
  }

  public var residentByteCount: Int {
    residentBytes
  }

  public func document(
    messageID: String,
    markdown: String
  ) -> TatwoAssistantTranscriptDocument {
    document(
      for: TatwoAssistantTranscriptCacheKey(
        messageID: messageID,
        markdown: markdown,
        parserVersion: parserVersion),
      markdown: markdown)
  }

  public func document(
    messageID: String,
    markdown: String
  ) async -> TatwoAssistantTranscriptDocument {
    await document(
      for: TatwoAssistantTranscriptCacheKey(
        messageID: messageID,
        markdown: markdown,
        parserVersion: parserVersion),
      markdown: markdown)
  }

  public func document(
    for key: TatwoAssistantTranscriptCacheKey,
    markdown: String
  ) -> TatwoAssistantTranscriptDocument {
    let request = beginRequest(for: key)
    if let cached = cachedDocument(for: key) {
      finishRequest(request, forMessageID: key.messageID)
      return cached
    }

    let parsed = parser(markdown)
    _ = storeIfCurrent(parsed, for: key, request: request)
    return parsed
  }

  public func document(
    for key: TatwoAssistantTranscriptCacheKey,
    markdown: String
  ) async -> TatwoAssistantTranscriptDocument {
    let request = beginRequest(for: key)
    if let cached = cachedDocument(for: key) {
      finishRequest(request, forMessageID: key.messageID)
      return cached
    }

    guard let parsed = await parseDocumentWithMetadata(markdown: markdown) else {
      finishRequest(request, forMessageID: key.messageID)
      if let cached = cachedDocument(for: key) {
        return cached
      }
      return TatwoAssistantTranscriptDocument(blocks: [], usedFallback: true)
    }
    guard !Task.isCancelled else {
      finishRequest(request, forMessageID: key.messageID)
      return parsed.document
    }
    if let cached = cachedDocument(for: key) {
      finishRequest(request, forMessageID: key.messageID)
      return cached
    }
    _ = storeIfCurrent(
      parsed.document,
      documentResidentBytes: parsed.estimatedResidentBytes,
      for: key,
      request: request)
    return parsed.document
  }

  /// Returns a fixed-size generation token for stale-parse rejection. The
  /// request table is bounded and never retains markdown, so cancelled or
  /// abandoned requests cannot pin complete transcripts indefinitely.
  @discardableResult
  public func beginRequest(
    for key: TatwoAssistantTranscriptCacheKey
  ) -> RequestToken {
    nextRequestGeneration &+= 1
    let token = RequestToken(
      generation: nextRequestGeneration,
      utf8Count: key.utf8Count,
      textHash: key.textHash,
      parserVersion: key.parserVersion)
    latestRequestByMessageID[key.messageID] = token
    touchRequestMessageID(key.messageID)
    trimRequestTableIfNeeded(protecting: key.messageID)
    return token
  }

  public func latestRequestedGeneration(
    forMessageID messageID: String
  ) -> UInt64? {
    latestRequestByMessageID[messageID]?.generation
  }

  public func isCurrent(
    _ request: RequestToken,
    for key: TatwoAssistantTranscriptCacheKey
  ) -> Bool {
    latestRequestByMessageID[key.messageID] == request
      && request.utf8Count == key.utf8Count
      && request.textHash == key.textHash
      && request.parserVersion == key.parserVersion
  }

  public func finishRequest(
    _ request: RequestToken,
    forMessageID messageID: String
  ) {
    guard latestRequestByMessageID[messageID] == request else { return }
    latestRequestByMessageID.removeValue(forKey: messageID)
    if let index = recentRequestMessageIDs.firstIndex(of: messageID) {
      recentRequestMessageIDs.remove(at: index)
    }
  }

  /// Parses off the caller. Uses a detached task so markdown parse cannot
  /// block the main actor, plus a cancellation flag plus `Task.isCancelled`
  /// so a cancelled parent still drops the result before insert.
  public func parseDocument(markdown: String) async -> TatwoAssistantTranscriptDocument? {
    await parseDocumentWithMetadata(markdown: markdown)?.document
  }

  /// Parses and performs document residency accounting off the caller actor.
  /// The main actor receives fixed-size metadata instead of traversing every
  /// attributed run and grapheme before inserting a large transcript.
  public func parseDocumentWithMetadata(
    markdown: String
  ) async -> TatwoAssistantTranscriptParseResult? {
    let parse = parser
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    return await withTaskCancellationHandler {
      await Task.detached(priority: .userInitiated) {
        guard !cancelled.withLock({ $0 }), !Task.isCancelled else { return nil }
        let document = parse(markdown)
        let result = TatwoAssistantTranscriptParseResult(
          document: document,
          estimatedResidentBytes: Self.estimatedResidentBytes(for: document))
        guard !cancelled.withLock({ $0 }), !Task.isCancelled else {
          return result
        }
        return result
      }.value
    } onCancel: {
      cancelled.withLock { $0 = true }
    }
  }

  /// Inserts only while `requestedKey` is still the latest key for that message.
  @discardableResult
  public func storeIfCurrent(
    _ document: TatwoAssistantTranscriptDocument,
    for requestedKey: TatwoAssistantTranscriptCacheKey,
    request: RequestToken
  ) -> Bool {
    storeIfCurrent(
      document,
      documentResidentBytes: nil,
      for: requestedKey,
      request: request)
  }

  @discardableResult
  public func storeIfCurrent(
    _ document: TatwoAssistantTranscriptDocument,
    documentResidentBytes: Int,
    for requestedKey: TatwoAssistantTranscriptCacheKey,
    request: RequestToken
  ) -> Bool {
    storeIfCurrent(
      document,
      documentResidentBytes: Optional(documentResidentBytes),
      for: requestedKey,
      request: request)
  }

  private func storeIfCurrent(
    _ document: TatwoAssistantTranscriptDocument,
    documentResidentBytes: Int?,
    for requestedKey: TatwoAssistantTranscriptCacheKey,
    request: RequestToken
  ) -> Bool {
    guard isCurrent(request, for: requestedKey) else {
      return false
    }
    insert(
      document,
      documentResidentBytes: documentResidentBytes,
      for: requestedKey)
    finishRequest(request, forMessageID: requestedKey.messageID)
    return true
  }

  public func cachedDocument(
    for key: TatwoAssistantTranscriptCacheKey
  ) -> TatwoAssistantTranscriptDocument? {
    guard let entry = entries[key] else { return nil }
    moveToMostRecentlyUsed(entry)
    return entry.document
  }

  public func removeAll() {
    entries.removeAll(keepingCapacity: true)
    entriesByMessageID.removeAll(keepingCapacity: true)
    latestRequestByMessageID.removeAll(keepingCapacity: true)
    recentRequestMessageIDs.removeAll(keepingCapacity: true)
    leastRecentlyUsed = nil
    mostRecentlyUsed = nil
    residentBytes = 0
  }

  private func touchRequestMessageID(_ messageID: String) {
    if let index = recentRequestMessageIDs.firstIndex(of: messageID) {
      recentRequestMessageIDs.remove(at: index)
    }
    recentRequestMessageIDs.append(messageID)
  }

  private func trimRequestTableIfNeeded(protecting messageID: String) {
    let maximumRequestCount = max(8, maximumEntryCount * 2)
    while recentRequestMessageIDs.count > maximumRequestCount {
      guard let index = recentRequestMessageIDs.firstIndex(
        where: { $0 != messageID })
      else { break }
      let evicted = recentRequestMessageIDs.remove(at: index)
      latestRequestByMessageID.removeValue(forKey: evicted)
    }
  }

  private func insert(
    _ document: TatwoAssistantTranscriptDocument,
    documentResidentBytes: Int? = nil,
    for key: TatwoAssistantTranscriptCacheKey
  ) {
    let byteCount =
      key.estimatedResidentBytes
      + (documentResidentBytes
        ?? Self.estimatedResidentBytes(for: document))

    if let previous = entriesByMessageID[key.messageID],
       previous.key != key
    {
      removeEntry(previous)
    }

    if let existing = entries[key] {
      guard byteCount <= maximumResidentBytes else {
        removeEntry(existing)
        return
      }
      residentBytes -= existing.residentBytes
      existing.document = document
      existing.residentBytes = byteCount
      residentBytes += byteCount
      entriesByMessageID[key.messageID] = existing
      moveToMostRecentlyUsed(existing)
      evictIfNeeded()
      return
    }

    // A document may be far larger than its markdown source (for example, a
    // custom parser can expand a short marker into a table with many attributed
    // cells). Never let one such value defeat the resident-byte ceiling.
    guard byteCount <= maximumResidentBytes else { return }

    let entry = Entry(
      key: key,
      document: document,
      residentBytes: byteCount)
    entries[key] = entry
    entriesByMessageID[key.messageID] = entry
    residentBytes += byteCount
    appendMostRecentlyUsed(entry)
    evictIfNeeded()
  }

  private func appendMostRecentlyUsed(_ entry: Entry) {
    entry.previous = mostRecentlyUsed
    entry.next = nil
    mostRecentlyUsed?.next = entry
    mostRecentlyUsed = entry
    if leastRecentlyUsed == nil {
      leastRecentlyUsed = entry
    }
  }

  private func moveToMostRecentlyUsed(_ entry: Entry) {
    guard mostRecentlyUsed !== entry else { return }
    unlink(entry)
    appendMostRecentlyUsed(entry)
  }

  private func evictIfNeeded() {
    while entries.count > maximumEntryCount
      || residentBytes > maximumResidentBytes
    {
      guard let oldest = leastRecentlyUsed else { break }
      removeEntry(oldest)
    }
  }

  private func removeEntry(_ entry: Entry) {
    unlink(entry)
    entries.removeValue(forKey: entry.key)
    residentBytes -= entry.residentBytes
    if residentBytes < 0 {
      residentBytes = 0
    }
    if entriesByMessageID[entry.key.messageID] === entry {
      entriesByMessageID.removeValue(forKey: entry.key.messageID)
    }
  }

  private func unlink(_ entry: Entry) {
    let previous = entry.previous
    let next = entry.next
    previous?.next = next
    next?.previous = previous
    if leastRecentlyUsed === entry {
      leastRecentlyUsed = next
    }
    if mostRecentlyUsed === entry {
      mostRecentlyUsed = previous
    }
    entry.previous = nil
    entry.next = nil
  }

  private nonisolated static func estimatedResidentBytes(
    for document: TatwoAssistantTranscriptDocument
  ) -> Int {
    var total =
      MemoryLayout<TatwoAssistantTranscriptDocument>.stride
      + MemoryLayout<TatwoAssistantTranscriptBlock>.stride
        * document.blocks.count
      + 64
    for block in document.blocks {
      total += MemoryLayout<TatwoAssistantTranscriptBlock>.stride
      total += MemoryLayout<TatwoAssistantTranscriptBlockKind>.stride
      total += estimatedResidentBytes(for: block.content)
      total += estimatedResidentBytes(for: block.kind)
    }
    return total
  }

  private nonisolated static func estimatedResidentBytes(
    for kind: TatwoAssistantTranscriptBlockKind
  ) -> Int {
    switch kind {
    case .codeBlock(let language):
      return 32 + (language?.utf8.count ?? 0)
    case .table(let table):
      var total =
        MemoryLayout<TatwoAssistantTranscriptTable>.stride
        + MemoryLayout<AttributedString>.stride * table.header.count
        + MemoryLayout<[AttributedString]>.stride * table.rows.count
        + MemoryLayout<TatwoAssistantTranscriptTableAlignment>.stride
          * table.alignments.count
        + 128
      for cell in table.header {
        total += estimatedResidentBytes(for: cell)
      }
      for row in table.rows {
        total += MemoryLayout<AttributedString>.stride * row.count + 32
        for cell in row {
          total += estimatedResidentBytes(for: cell)
        }
      }
      return total
    case .heading, .paragraph, .unorderedListItem, .orderedListItem,
         .blockquote, .horizontalRule, .fallback:
      return 32
    }
  }

  private nonisolated static func estimatedResidentBytes(
    for attributed: AttributedString
  ) -> Int {
    var characterCount = 0
    var runCount = 0
    for run in attributed.runs {
      runCount += 1
      characterCount += attributed.characters[run.range].count
    }
    if runCount == 0 {
      characterCount = attributed.characters.count
    }
    return MemoryLayout<AttributedString>.stride
      // Four bytes per extended grapheme is deliberately conservative without
      // allocating a complete String merely to count its UTF-8 storage.
      + characterCount * 4
      // Attribute containers are opaque. A fixed per-run allowance avoids
      // reflection (`String(describing:)`) and remains O(runs).
      + runCount * 192
      + 64
  }
}
