// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/ChatSearchCore.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public enum TatwoChatSearchSourceKind: String, Codable, Sendable, Equatable {
  case project
  case thread
  case message
  case attachment
  case cliCommand
}

public enum TatwoChatSearchScope: String, Codable, Sendable, Equatable {
  case all
  case conversations
  case cliCommands
}

public struct TatwoChatSearchDocument:
  Codable,
  Sendable,
  Equatable,
  Identifiable
{
  public let id: String
  public let sourceKind: TatwoChatSearchSourceKind
  public let projectID: UUID?
  public let threadID: UUID?
  public let messageID: String?
  public let cliSessionID: UUID?
  public let title: String
  public let searchableText: String
  public let timestamp: Date?

  public init(
    id: String,
    sourceKind: TatwoChatSearchSourceKind,
    projectID: UUID? = nil,
    threadID: UUID? = nil,
    messageID: String? = nil,
    cliSessionID: UUID? = nil,
    title: String = "",
    searchableText: String = "",
    timestamp: Date? = nil
  ) {
    self.id = id
    self.sourceKind = sourceKind
    self.projectID = projectID
    self.threadID = threadID
    self.messageID = messageID
    self.cliSessionID = cliSessionID
    self.title = title
    self.searchableText = searchableText
    self.timestamp = timestamp
  }
}

public struct TatwoChatSearchMessage: Codable, Sendable, Equatable, Identifiable {
  public var id: String { messageID }

  public let projectID: UUID?
  public let threadID: UUID?
  public let messageID: String
  public let title: String
  public let role: String?
  public let text: String?
  public let attachmentNames: [String]
  public let timestamp: Date?

  public init(
    projectID: UUID? = nil,
    threadID: UUID? = nil,
    messageID: String,
    title: String = "",
    role: String? = nil,
    text: String? = nil,
    attachmentNames: [String] = [],
    timestamp: Date? = nil
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.messageID = messageID
    self.title = title
    self.role = role
    self.text = text
    self.attachmentNames = attachmentNames
    self.timestamp = timestamp
  }
}

public struct TatwoChatSearchQuery: Codable, Sendable, Equatable {
  public let rawText: String
  public let scope: TatwoChatSearchScope
  public let resultLimit: Int

  public init(
    rawText: String,
    scope: TatwoChatSearchScope = .all,
    resultLimit: Int = 50
  ) {
    self.rawText = rawText
    self.scope = scope
    self.resultLimit = resultLimit
  }
}

public struct TatwoChatSearchResult:
  Codable,
  Sendable,
  Equatable,
  Identifiable
{
  public let id: String
  public let source: TatwoChatSearchDocument
  public let score: Int
  public let snippet: String
  public let matchedRanges: [Range<Int>]

  public init(
    id: String,
    source: TatwoChatSearchDocument,
    score: Int,
    snippet: String,
    matchedRanges: [Range<Int>]
  ) {
    self.id = id
    self.source = source
    self.score = score
    self.snippet = snippet
    self.matchedRanges = matchedRanges
  }
}

public enum TatwoChatSearchIndexer {
  public static func documents(
    from messages: [TatwoChatSearchMessage],
    history: TatwoCLICommandHistoryBook
  ) -> [TatwoChatSearchDocument] {
    let messageDocuments = messages.map { message in
      let searchableParts =
        [message.role, message.text]
        + message.attachmentNames.map(Optional.some)
      let searchableText = searchableParts
        .compactMap { value -> String? in
          guard let value else { return nil }
          let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: "\n")

      return TatwoChatSearchDocument(
        id: "message:\(message.messageID)",
        sourceKind: .message,
        projectID: message.projectID,
        threadID: message.threadID,
        messageID: message.messageID,
        title: message.title,
        searchableText: searchableText,
        timestamp: message.timestamp)
    }

    let historyDocuments = history.entriesBySession.keys
      .sorted { $0.uuidString < $1.uuidString }
      .flatMap { sessionID in
        history.entries(for: sessionID).compactMap {
          entry -> TatwoChatSearchDocument? in
          guard entry.storageDecision != .excluded else { return nil }
          let searchableText =
            entry.storageDecision == .stored
            ? (entry.command ?? "")
            : entry.displayPreview
          return TatwoChatSearchDocument(
            id: "cli:\(entry.id.uuidString)",
            sourceKind: .cliCommand,
            cliSessionID: sessionID,
            title: "CLI \(entry.engine.rawValue)",
            searchableText: searchableText,
            timestamp: entry.executedAt)
        }
      }

    return messageDocuments + historyDocuments
  }
}

public struct TatwoChatSearchIndex: Codable, Sendable, Equatable {
  public let documents: [TatwoChatSearchDocument]

  public init(documents: [TatwoChatSearchDocument] = []) {
    self.documents = documents
  }

  public init(
    messages: [TatwoChatSearchMessage],
    history: TatwoCLICommandHistoryBook
  ) {
    self.documents = TatwoChatSearchIndexer.documents(
      from: messages,
      history: history)
  }

  public func search(
    _ query: TatwoChatSearchQuery,
    snippetScalarLimit: Int = 160
  ) -> [TatwoChatSearchResult] {
    TatwoChatSearchMatcher.search(
      query: query,
      in: documents,
      snippetScalarLimit: snippetScalarLimit)
  }
}

public enum TatwoChatSearchMatcher {
  public static func search(
    query: TatwoChatSearchQuery,
    in documents: [TatwoChatSearchDocument],
    snippetScalarLimit: Int = 160
  ) -> [TatwoChatSearchResult] {
    let normalizedQuery = NormalizedProjection(query.rawText)
    guard !normalizedQuery.scalars.isEmpty, query.resultLimit > 0 else {
      return []
    }

    let queryScalars = normalizedQuery.scalars
    let queryTokens = scalarTokens(queryScalars)
    let results = documents.compactMap { document -> TatwoChatSearchResult? in
      guard query.scope.includes(document.sourceKind) else { return nil }
      guard let match = bestMatch(
        query: queryScalars,
        queryTokens: queryTokens,
        document: document)
      else {
        return nil
      }

      return TatwoChatSearchResult(
        id: document.id,
        source: document,
        score: match.score,
        snippet: snippet(
          source: match.source,
          projection: match.projection,
          firstMatch: match.ranges[0],
          scalarLimit: snippetScalarLimit),
        matchedRanges: match.ranges)
    }

    return Array(
      results.sorted(by: resultSort).prefix(query.resultLimit))
  }

  private struct Match {
    let score: Int
    let source: String
    let projection: NormalizedProjection
    let ranges: [Range<Int>]
  }

  private static func bestMatch(
    query: [Unicode.Scalar],
    queryTokens: [[Unicode.Scalar]],
    document: TatwoChatSearchDocument
  ) -> Match? {
    let title = NormalizedProjection(document.title)
    let text = NormalizedProjection(document.searchableText)

    if title.scalars == query {
      return Match(
        score: 1_000,
        source: document.title,
        projection: title,
        ranges: [0..<query.count])
    }

    if title.scalars.starts(with: query) {
      return Match(
        score: 900,
        source: document.title,
        projection: title,
        ranges: allRanges(of: query, in: title.scalars))
    }

    if let ranges = tokenRanges(queryTokens, in: title.scalars) {
      return Match(
        score: 800,
        source: document.title,
        projection: title,
        ranges: ranges)
    }

    if let ranges = tokenRanges(queryTokens, in: text.scalars) {
      return Match(
        score: 700,
        source: document.searchableText,
        projection: text,
        ranges: ranges)
    }

    let titlePhraseRanges = allRanges(of: query, in: title.scalars)
    if !titlePhraseRanges.isEmpty {
      return Match(
        score: 600,
        source: document.title,
        projection: title,
        ranges: titlePhraseRanges)
    }

    let textPhraseRanges = allRanges(of: query, in: text.scalars)
    if !textPhraseRanges.isEmpty {
      return Match(
        score: 500,
        source: document.searchableText,
        projection: text,
        ranges: textPhraseRanges)
    }

    if let ranges = substringRanges(queryTokens, in: text.scalars) {
      return Match(
        score: 400,
        source: document.searchableText,
        projection: text,
        ranges: ranges)
    }

    return nil
  }

  private static func resultSort(
    _ lhs: TatwoChatSearchResult,
    _ rhs: TatwoChatSearchResult
  ) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score > rhs.score
    }
    if lhs.source.timestamp != rhs.source.timestamp {
      return (lhs.source.timestamp ?? .distantPast)
        > (rhs.source.timestamp ?? .distantPast)
    }
    return lhs.id < rhs.id
  }

  private static func scalarTokens(
    _ scalars: [Unicode.Scalar]
  ) -> [[Unicode.Scalar]] {
    var tokens: [[Unicode.Scalar]] = []
    var current: [Unicode.Scalar] = []
    let space: Unicode.Scalar = " "

    for scalar in scalars {
      if scalar == space {
        if !current.isEmpty {
          tokens.append(current)
          current.removeAll(keepingCapacity: true)
        }
      } else {
        current.append(scalar)
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }
    return tokens
  }

  private static func tokenRanges(
    _ tokens: [[Unicode.Scalar]],
    in source: [Unicode.Scalar]
  ) -> [Range<Int>]? {
    guard !tokens.isEmpty else { return nil }
    var matches: [Range<Int>] = []

    for token in tokens {
      let ranges = allRanges(of: token, in: source)
        .filter { isTokenRange($0, in: source) }
      guard !ranges.isEmpty else { return nil }
      matches.append(contentsOf: ranges)
    }
    return matches.sorted { $0.lowerBound < $1.lowerBound }
  }

  private static func substringRanges(
    _ tokens: [[Unicode.Scalar]],
    in source: [Unicode.Scalar]
  ) -> [Range<Int>]? {
    guard !tokens.isEmpty else { return nil }
    var matches: [Range<Int>] = []

    for token in tokens {
      let ranges = allRanges(of: token, in: source)
      guard !ranges.isEmpty else { return nil }
      matches.append(contentsOf: ranges)
    }
    return matches.sorted { $0.lowerBound < $1.lowerBound }
  }

  private static func allRanges(
    of needle: [Unicode.Scalar],
    in haystack: [Unicode.Scalar]
  ) -> [Range<Int>] {
    guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
    var ranges: [Range<Int>] = []
    var index = 0

    while index <= haystack.count - needle.count {
      let end = index + needle.count
      if haystack[index..<end].elementsEqual(needle) {
        ranges.append(index..<end)
        index = end
      } else {
        index += 1
      }
    }
    return ranges
  }

  private static func isTokenRange(
    _ range: Range<Int>,
    in source: [Unicode.Scalar]
  ) -> Bool {
    let lowerIsBoundary =
      range.lowerBound == 0 || !isTokenScalar(source[range.lowerBound - 1])
    let upperIsBoundary =
      range.upperBound == source.count || !isTokenScalar(source[range.upperBound])
    return lowerIsBoundary && upperIsBoundary
  }

  private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
  }

  private static func snippet(
    source: String,
    projection: NormalizedProjection,
    firstMatch: Range<Int>,
    scalarLimit: Int
  ) -> String {
    guard !projection.scalars.isEmpty else { return "" }
    let safeLimit = max(1, scalarLimit)
    let count = projection.scalars.count
    guard count > safeLimit else { return source }

    let matchCenter = (firstMatch.lowerBound + firstMatch.upperBound) / 2
    var normalizedStart = max(0, matchCenter - safeLimit / 2)
    let normalizedEnd = min(count, normalizedStart + safeLimit)
    normalizedStart = max(0, normalizedEnd - safeLimit)

    let sourceScalars = Array(source.unicodeScalars)
    let sourceStart = projection.sourceOffsets[normalizedStart]
    let sourceEnd =
      normalizedEnd == count
      ? sourceScalars.count
      : min(
        sourceScalars.count,
        projection.sourceOffsets[normalizedEnd - 1] + 1)
    let body = String(
      String.UnicodeScalarView(sourceScalars[sourceStart..<sourceEnd]))
    let prefix = normalizedStart > 0 ? "…" : ""
    let suffix = normalizedEnd < count ? "…" : ""
    return prefix + body + suffix
  }

  private struct NormalizedProjection {
    let scalars: [Unicode.Scalar]
    let sourceOffsets: [Int]

    init(_ source: String) {
      let sourceScalars = Array(source.unicodeScalars)
      let space: Unicode.Scalar = " "
      var normalized: [Unicode.Scalar] = []
      var offsets: [Int] = []

      for (sourceOffset, sourceScalar) in sourceScalars.enumerated() {
        let folded = String(sourceScalar)
          .folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
          .lowercased(with: Locale(identifier: "en_US_POSIX"))

        for scalar in folded.unicodeScalars {
          if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if !normalized.isEmpty, normalized.last != space {
              normalized.append(space)
              offsets.append(sourceOffset)
            }
          } else {
            normalized.append(scalar)
            offsets.append(sourceOffset)
          }
        }
      }

      if normalized.last == space {
        normalized.removeLast()
        offsets.removeLast()
      }
      self.scalars = normalized
      self.sourceOffsets = offsets
    }
  }
}

private extension TatwoChatSearchScope {
  func includes(_ sourceKind: TatwoChatSearchSourceKind) -> Bool {
    switch self {
    case .all:
      return true
    case .conversations:
      return sourceKind != .cliCommand
    case .cliCommands:
      return sourceKind == .cliCommand
    }
  }
}
