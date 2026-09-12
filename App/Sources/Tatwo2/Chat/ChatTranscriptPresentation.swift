// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/ChatTranscriptPresentation.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public enum TatwoAssistantTranscriptTableAlignment: Equatable, Sendable {
  case unspecified
  case leading
  case center
  case trailing
}

public struct TatwoAssistantTranscriptTable: Equatable, Sendable {
  public let header: [AttributedString]
  public let rows: [[AttributedString]]
  public let alignments: [TatwoAssistantTranscriptTableAlignment]

  init(
    header: [AttributedString],
    rows: [[AttributedString]],
    alignments: [TatwoAssistantTranscriptTableAlignment]
  ) {
    self.header = header
    self.rows = rows
    self.alignments = alignments
  }

  var plainText: String {
    ([header] + rows)
      .map { row in
        row.map { String($0.characters) }.joined(separator: " | ")
      }
      .joined(separator: "\n")
  }
}

public enum TatwoAssistantTranscriptBlockRenderKind: Equatable, Sendable {
  case heading(level: Int)
  case paragraph
  case unorderedListItem(depth: Int)
  case orderedListItem(depth: Int, ordinal: Int)
  case codeBlock(language: String?)
  case table(TatwoAssistantTranscriptTable)
  case blockquote
  case horizontalRule
  case fallback
}

public enum TatwoAssistantTranscriptBlockKind: Equatable, Sendable {
  case heading(level: Int)
  case paragraph
  case unorderedListItem(depth: Int)
  case orderedListItem(depth: Int, ordinal: Int)
  case codeBlock(language: String?)
  case table(TatwoAssistantTranscriptTable)
  case blockquote
  case horizontalRule
  case fallback

  public var listDepth: Int? {
    switch self {
    case .unorderedListItem(let depth), .orderedListItem(let depth, _):
      depth
    case .heading, .paragraph, .codeBlock, .table, .blockquote,
         .horizontalRule, .fallback:
      nil
    }
  }

  public var renderKind: TatwoAssistantTranscriptBlockRenderKind {
    switch self {
    case .heading(let level):
      .heading(level: level)
    case .paragraph:
      .paragraph
    case .unorderedListItem(let depth):
      .unorderedListItem(depth: depth)
    case .orderedListItem(let depth, let ordinal):
      .orderedListItem(depth: depth, ordinal: ordinal)
    case .codeBlock(let language):
      .codeBlock(language: language)
    case .table(let table):
      .table(table)
    case .blockquote:
      .blockquote
    case .horizontalRule:
      .horizontalRule
    case .fallback:
      .fallback
    }
  }
}

public struct TatwoAssistantTranscriptBlockID: Hashable, Sendable {
  public let contentHash: UInt64
  public let occurrence: Int

  init(contentHash: UInt64, occurrence: Int) {
    self.contentHash = contentHash
    self.occurrence = occurrence
  }
}

public struct TatwoAssistantTranscriptBlock: Equatable, Identifiable, Sendable {
  public let id: TatwoAssistantTranscriptBlockID
  public let kind: TatwoAssistantTranscriptBlockKind
  public let content: AttributedString

  public var plainText: String {
    String(content.characters)
  }

  init(
    id: TatwoAssistantTranscriptBlockID,
    kind: TatwoAssistantTranscriptBlockKind,
    content: AttributedString
  ) {
    self.id = id
    self.kind = kind
    self.content = content
  }
}

public struct TatwoAssistantTranscriptDocument: Equatable, Sendable {
  public let blocks: [TatwoAssistantTranscriptBlock]
  public let usedFallback: Bool

  init(blocks: [TatwoAssistantTranscriptBlock], usedFallback: Bool) {
    self.blocks = blocks
    self.usedFallback = usedFallback
  }
}

public enum TatwoAssistantTranscriptPresentation {
  public static func document(markdown: String) -> TatwoAssistantTranscriptDocument {
    document(markdown: markdown, inlineParser: parseInlineMarkdown)
  }

  static func document(
    markdown: String,
    inlineParser: (String) throws -> AttributedString
  ) -> TatwoAssistantTranscriptDocument {
    do {
      return try parseBlocks(markdown, inlineParser: inlineParser)
    } catch {
      let plainDocument = try? parseBlocks(
        markdown,
        inlineParser: { AttributedString($0) })
      return TatwoAssistantTranscriptDocument(
        blocks: plainDocument?.blocks ?? [
          TatwoAssistantTranscriptBlock(
            id: blockID(
              kind: .fallback,
              source: markdown,
              occurrence: 0),
            kind: .fallback,
            content: AttributedString(markdown))
        ],
        usedFallback: true)
    }
  }

  private static func parseBlocks(
    _ markdown: String,
    inlineParser: (String) throws -> AttributedString
  ) throws -> TatwoAssistantTranscriptDocument {
    var blocks: [TatwoAssistantTranscriptBlock] = []
    var paragraphLines: [String] = []
    var listIndentLevels: [Int] = []
    var pendingListKind: TatwoAssistantTranscriptBlockKind?
    var pendingListLines: [String] = []
    var openFence: MarkdownFence?
    var codeLines: [String] = []
    var usedFallback = false
    var blockOccurrences: [UInt64: Int] = [:]

    func nextBlockID(
      kind: TatwoAssistantTranscriptBlockKind,
      source: String
    ) -> TatwoAssistantTranscriptBlockID {
      let contentHash = blockContentHash(kind: kind, source: source)
      let occurrence = blockOccurrences[contentHash, default: 0]
      blockOccurrences[contentHash] = occurrence + 1
      return blockID(
        contentHash: contentHash,
        occurrence: occurrence)
    }

    func appendBlock(kind: TatwoAssistantTranscriptBlockKind, source: String) throws {
      blocks.append(
        TatwoAssistantTranscriptBlock(
          id: nextBlockID(kind: kind, source: source),
          kind: kind,
          content: try inlineParser(source)))
    }

    func appendPlainBlock(
      kind: TatwoAssistantTranscriptBlockKind,
      source: String,
      identitySource: String? = nil
    ) {
      blocks.append(
        TatwoAssistantTranscriptBlock(
          id: nextBlockID(
            kind: kind,
            source: identitySource ?? source),
          kind: kind,
          content: AttributedString(source)))
    }

    func appendTableBlock(_ parsedTable: ParsedTableBlock) throws {
      let table = TatwoAssistantTranscriptTable(
        header: try parsedTable.header.map(inlineParser),
        rows: try parsedTable.rows.map { row in
          try row.map(inlineParser)
        },
        alignments: parsedTable.alignments)
      let kind = TatwoAssistantTranscriptBlockKind.table(table)
      blocks.append(
        TatwoAssistantTranscriptBlock(
          id: nextBlockID(
            kind: kind,
            source: parsedTable.source),
          kind: kind,
          content: AttributedString(table.plainText)))
    }

    func flushParagraph() throws {
      guard !paragraphLines.isEmpty else { return }
      try appendBlock(
        kind: .paragraph,
        source: paragraphLines.joined(separator: "\n"))
      paragraphLines.removeAll(keepingCapacity: true)
    }

    func flushListItem() throws {
      guard let pendingListKind, !pendingListLines.isEmpty else { return }
      try appendBlock(
        kind: pendingListKind,
        source: pendingListLines.joined(separator: "\n"))
      selfResetPendingList()
    }

    func selfResetPendingList() {
      pendingListKind = nil
      pendingListLines.removeAll(keepingCapacity: true)
    }

    let markdownLines = markdown.components(separatedBy: .newlines)
    var skippedThroughLineIndex = -1

    for (lineIndex, rawLine) in markdownLines.enumerated() {
      guard lineIndex > skippedThroughLineIndex else { continue }

      if let fence = openFence {
        if isClosingFenceLine(rawLine, for: fence) {
          appendPlainBlock(
            kind: .codeBlock(language: fence.language),
            source: codeLines.joined(separator: "\n"))
          openFence = nil
          codeLines.removeAll(keepingCapacity: true)
        } else {
          codeLines.append(rawLine)
        }
        continue
      }

      if let fence = openingFenceLine(rawLine) {
        try flushListItem()
        try flushParagraph()
        listIndentLevels.removeAll(keepingCapacity: true)
        openFence = fence
        codeLines.removeAll(keepingCapacity: true)
        continue
      }

      if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
        try flushListItem()
        try flushParagraph()
        listIndentLevels.removeAll(keepingCapacity: true)
        continue
      }

      if let table = tableBlock(
        startingAt: lineIndex,
        lines: markdownLines)
      {
        try flushListItem()
        try flushParagraph()
        listIndentLevels.removeAll(keepingCapacity: true)
        try appendTableBlock(table)
        skippedThroughLineIndex = table.endLineIndex
        continue
      }

      if let quote = blockquoteBlock(
        startingAt: lineIndex,
        lines: markdownLines)
      {
        try flushListItem()
        try flushParagraph()
        listIndentLevels.removeAll(keepingCapacity: true)
        try appendBlock(
          kind: .blockquote,
          source: quote.content)
        skippedThroughLineIndex = quote.endLineIndex
        continue
      }

      if isHorizontalRuleLine(rawLine) {
        try flushListItem()
        try flushParagraph()
        listIndentLevels.removeAll(keepingCapacity: true)
        appendPlainBlock(
          kind: .horizontalRule,
          source: "",
          identitySource: rawLine.trimmingCharacters(in: .whitespaces))
        continue
      }

      if let heading = headingLine(rawLine) {
        try flushListItem()
        try flushParagraph()
        listIndentLevels.removeAll(keepingCapacity: true)
        try appendBlock(
          kind: .heading(level: heading.level),
          source: heading.content)
        continue
      }

      if let item = listLine(rawLine) {
        try flushListItem()
        try flushParagraph()
        let depth = listDepth(
          for: item.indentation,
          levels: &listIndentLevels)
        switch item.marker {
        case .unordered:
          pendingListKind = .unorderedListItem(depth: depth)
        case .ordered(let ordinal):
          pendingListKind = .orderedListItem(depth: depth, ordinal: ordinal)
        }
        pendingListLines = [item.content]
        continue
      }

      if pendingListKind != nil, indentationWidth(of: rawLine) > 0 {
        pendingListLines.append(
          rawLine.trimmingCharacters(in: .whitespaces))
        continue
      }

      try flushListItem()
      listIndentLevels.removeAll(keepingCapacity: true)
      paragraphLines.append(
        rawLine.trimmingCharacters(in: .whitespaces))
    }

    if let openFence {
      appendPlainBlock(
        kind: .codeBlock(language: openFence.language),
        source: codeLines.joined(separator: "\n"))
      usedFallback = true
    }
    try flushListItem()
    try flushParagraph()
    return TatwoAssistantTranscriptDocument(
      blocks: blocks,
      usedFallback: usedFallback)
  }

  private static func blockID(
    kind: TatwoAssistantTranscriptBlockKind,
    source: String,
    occurrence: Int
  ) -> TatwoAssistantTranscriptBlockID {
    blockID(
      contentHash: blockContentHash(kind: kind, source: source),
      occurrence: occurrence)
  }

  private static func blockID(
    contentHash: UInt64,
    occurrence: Int
  ) -> TatwoAssistantTranscriptBlockID {
    TatwoAssistantTranscriptBlockID(
      contentHash: contentHash,
      occurrence: occurrence)
  }

  private static func blockContentHash(
    kind: TatwoAssistantTranscriptBlockKind,
    source: String
  ) -> UInt64 {
    var value: UInt64 = 14_695_981_039_346_656_037

    func combine(_ text: String) {
      for byte in text.utf8 {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
      }
    }

    combine(blockKindIdentitySource(kind))
    combine("\u{0}")
    combine(source)
    return value
  }

  private static func blockKindIdentitySource(
    _ kind: TatwoAssistantTranscriptBlockKind
  ) -> String {
    switch kind {
    case .heading(let level):
      return "heading:\(level)"
    case .paragraph:
      return "paragraph"
    case .unorderedListItem(let depth):
      return "unordered:\(depth)"
    case .orderedListItem(let depth, let ordinal):
      return "ordered:\(depth):\(ordinal)"
    case .codeBlock(let language):
      return "code:\(language ?? "")"
    case .table(let table):
      let alignmentSource = table.alignments.map {
        switch $0 {
        case .unspecified: "unspecified"
        case .leading: "leading"
        case .center: "center"
        case .trailing: "trailing"
        }
      }
      .joined(separator: ",")
      return "table:\(table.header.count):\(alignmentSource)"
    case .blockquote:
      return "blockquote"
    case .horizontalRule:
      return "horizontal-rule"
    case .fallback:
      return "fallback"
    }
  }

  private static func parseInlineMarkdown(_ source: String) throws -> AttributedString {
    try AttributedString(
      markdown: source,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
  }

  private struct ParsedTableBlock {
    let header: [String]
    let rows: [[String]]
    let alignments: [TatwoAssistantTranscriptTableAlignment]
    let source: String
    let endLineIndex: Int
  }

  private static func tableBlock(
    startingAt startIndex: Int,
    lines: [String]
  ) -> ParsedTableBlock? {
    let delimiterIndex = startIndex + 1
    guard delimiterIndex < lines.count,
          containsUnescapedPipe(lines[startIndex]),
          let header = tableCells(in: lines[startIndex]),
          let delimiterCells = tableCells(in: lines[delimiterIndex]),
          !header.isEmpty,
          header.count == delimiterCells.count
    else { return nil }

    let alignments = delimiterCells.compactMap(tableAlignment)
    guard alignments.count == header.count else { return nil }

    var rows: [[String]] = []
    var sourceLines = [lines[startIndex], lines[delimiterIndex]]
    var endLineIndex = delimiterIndex
    var rowIndex = delimiterIndex + 1

    while rowIndex < lines.count {
      let line = lines[rowIndex]
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
            containsUnescapedPipe(line),
            var row = tableCells(in: line)
      else { break }

      if row.count < header.count {
        row.append(contentsOf: repeatElement("", count: header.count - row.count))
      } else if row.count > header.count {
        row = Array(row.prefix(header.count))
      }
      rows.append(row)
      sourceLines.append(line)
      endLineIndex = rowIndex
      rowIndex += 1
    }

    return ParsedTableBlock(
      header: header,
      rows: rows,
      alignments: alignments,
      source: sourceLines.joined(separator: "\n"),
      endLineIndex: endLineIndex)
  }

  private static func containsUnescapedPipe(_ line: String) -> Bool {
    var escaped = false
    for character in line {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "|" {
        return true
      }
    }
    return false
  }

  private static func tableCells(in line: String) -> [String]? {
    let body = line.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { return nil }

    var cells: [String] = []
    var current = ""
    var escaped = false

    for character in body {
      if escaped {
        current.append("\\")
        current.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "|" {
        cells.append(current.trimmingCharacters(in: .whitespaces))
        current.removeAll(keepingCapacity: true)
      } else {
        current.append(character)
      }
    }
    if escaped {
      current.append("\\")
    }
    cells.append(current.trimmingCharacters(in: .whitespaces))

    if body.first == "|", cells.first?.isEmpty == true {
      cells.removeFirst()
    }
    if body.last == "|", cells.last?.isEmpty == true {
      cells.removeLast()
    }
    return cells
  }

  private static func tableAlignment(
    _ delimiterCell: String
  ) -> TatwoAssistantTranscriptTableAlignment? {
    let compact = delimiterCell.filter { !$0.isWhitespace }
    guard !compact.isEmpty else { return nil }

    let hasLeadingColon = compact.first == ":"
    let hasTrailingColon = compact.last == ":"
    let dashes = compact.dropFirst(hasLeadingColon ? 1 : 0)
      .dropLast(hasTrailingColon ? 1 : 0)
    guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else {
      return nil
    }

    switch (hasLeadingColon, hasTrailingColon) {
    case (true, true):
      return .center
    case (true, false):
      return .leading
    case (false, true):
      return .trailing
    case (false, false):
      return .unspecified
    }
  }

  private struct ParsedBlockquoteBlock {
    let content: String
    let endLineIndex: Int
  }

  private static func blockquoteBlock(
    startingAt startIndex: Int,
    lines: [String]
  ) -> ParsedBlockquoteBlock? {
    guard let firstLine = blockquoteContent(in: lines[startIndex]) else {
      return nil
    }

    var contentLines = [firstLine]
    var endLineIndex = startIndex
    var lineIndex = startIndex + 1
    while lineIndex < lines.count,
          let content = blockquoteContent(in: lines[lineIndex])
    {
      contentLines.append(content)
      endLineIndex = lineIndex
      lineIndex += 1
    }
    return ParsedBlockquoteBlock(
      content: contentLines.joined(separator: "\n"),
      endLineIndex: endLineIndex)
  }

  private static func blockquoteContent(in line: String) -> String? {
    let body = line.drop(while: { $0 == " " || $0 == "\t" })
    guard body.first == ">" else { return nil }
    let contentStart = body.index(after: body.startIndex)
    return String(body[contentStart...].drop(while: { $0 == " " }))
      .trimmingCharacters(in: .whitespaces)
  }

  private static func isHorizontalRuleLine(_ line: String) -> Bool {
    let body = line.trimmingCharacters(in: .whitespaces)
    guard let marker = body.first, marker == "-" || marker == "*" else {
      return false
    }
    let compact = body.filter { !$0.isWhitespace }
    return compact.count >= 3 && compact.allSatisfy { $0 == marker }
  }

  private static func headingLine(
    _ line: String
  ) -> (level: Int, content: String)? {
    let body = line.drop(while: { $0 == " " || $0 == "\t" })
    let markerCount = body.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(markerCount) else { return nil }

    let markerEnd = body.index(body.startIndex, offsetBy: markerCount)
    guard markerEnd < body.endIndex, body[markerEnd].isWhitespace else {
      return nil
    }
    let content = String(body[markerEnd...].drop(while: \.isWhitespace))
      .trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else { return nil }
    return (markerCount, content)
  }

  private enum ListMarker {
    case unordered
    case ordered(Int)
  }

  private struct MarkdownFence {
    let marker: Character
    let length: Int
    let language: String?
  }

  private static func openingFenceLine(_ line: String) -> MarkdownFence? {
    guard let body = fenceCandidateBody(line) else { return nil }
    guard let marker = body.first, marker == "`" || marker == "~" else {
      return nil
    }
    let markerCount = body.prefix(while: { $0 == marker }).count
    guard markerCount >= 3 else { return nil }

    let infoStart = body.index(body.startIndex, offsetBy: markerCount)
    let info = String(body[infoStart...])
      .trimmingCharacters(in: .whitespaces)
    if marker == "`", info.contains("`") {
      return nil
    }
    return MarkdownFence(
      marker: marker,
      length: markerCount,
      language: info.isEmpty ? nil : info)
  }

  private static func isClosingFenceLine(
    _ line: String,
    for fence: MarkdownFence
  ) -> Bool {
    guard let body = fenceCandidateBody(line) else { return false }
    let markerCount = body.prefix(while: { $0 == fence.marker }).count
    guard markerCount >= fence.length else { return false }

    let remainderStart = body.index(body.startIndex, offsetBy: markerCount)
    return body[remainderStart...].allSatisfy(\.isWhitespace)
  }

  private static func fenceCandidateBody(_ line: String) -> Substring? {
    var index = line.startIndex
    var leadingSpaces = 0
    while index < line.endIndex, line[index] == " " {
      leadingSpaces += 1
      guard leadingSpaces <= 3 else { return nil }
      index = line.index(after: index)
    }
    guard index == line.endIndex || line[index] != "\t" else { return nil }
    return line[index...]
  }

  private struct ParsedListLine {
    let indentation: Int
    let marker: ListMarker
    let content: String
  }

  private static func listLine(_ line: String) -> ParsedListLine? {
    let indentation = indentationWidth(of: line)
    let body = line.drop(while: { $0 == " " || $0 == "\t" })
    guard !body.isEmpty else { return nil }

    if let marker = body.first,
       marker == "-" || marker == "+" || marker == "*" {
      let contentStart = body.index(after: body.startIndex)
      guard contentStart < body.endIndex, body[contentStart].isWhitespace else {
        return nil
      }
      let content = String(body[contentStart...].drop(while: \.isWhitespace))
        .trimmingCharacters(in: .whitespaces)
      guard !content.isEmpty else { return nil }
      return ParsedListLine(
        indentation: indentation,
        marker: .unordered,
        content: content)
    }

    let digits = body.prefix(while: \.isNumber)
    guard !digits.isEmpty,
          let ordinal = Int(digits)
    else { return nil }

    let delimiterIndex = body.index(body.startIndex, offsetBy: digits.count)
    guard delimiterIndex < body.endIndex,
          body[delimiterIndex] == "." || body[delimiterIndex] == ")"
    else { return nil }

    let contentStart = body.index(after: delimiterIndex)
    guard contentStart < body.endIndex, body[contentStart].isWhitespace else {
      return nil
    }
    let content = String(body[contentStart...].drop(while: \.isWhitespace))
      .trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else { return nil }
    return ParsedListLine(
      indentation: indentation,
      marker: .ordered(ordinal),
      content: content)
  }

  private static func indentationWidth(of line: String) -> Int {
    line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(into: 0) {
      $0 += $1 == "\t" ? 4 : 1
    }
  }

  private static func listDepth(
    for indentation: Int,
    levels: inout [Int]
  ) -> Int {
    guard let current = levels.last else {
      levels = [indentation]
      return 0
    }

    if indentation > current {
      levels.append(indentation)
      return levels.count - 1
    }

    while levels.count > 1, indentation < (levels.last ?? indentation) {
      levels.removeLast()
    }

    if indentation > (levels.last ?? indentation) {
      levels.append(indentation)
    } else if indentation < (levels.first ?? indentation) {
      levels = [indentation]
    }
    return levels.count - 1
  }
}

public enum TatwoChatTranscriptRole: String, Sendable, Equatable {
  case user
  case assistant
  case system
}

public enum TatwoChatTranscriptPresentation {
  public static func isInternalArtifact(
    _ rawText: String,
    role: TatwoChatTranscriptRole
  ) -> Bool {
    guard role != .user else { return false }

    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }

    if text.hasPrefix("# Context Checkpoint — TATWO Chat Slider Loop")
      || text.hasPrefix("# AGENTS.md instructions")
      || text.hasPrefix("## Handoff Summary") {
      return true
    }

    if isCompleteAnchoredEnvelope(
      text,
      openingTag: "<permissions instructions>",
      closingTag: "</permissions instructions>")
      || isCompleteAnchoredEnvelope(
        text,
        openingTag: "<app-context>",
        closingTag: "</app-context>")
      || isCompleteAnchoredEnvelope(
        text,
        openingTag: "<subagent_notification>",
        closingTag: "</subagent_notification>")
      || isCompleteAnchoredEnvelope(
        text,
        openingTag: "<environment_context>",
        closingTag: "</environment_context>")
      || isOtherLanguageModelHandoffEnvelope(text) {
      return true
    }

    return isInternalDelegationEnvelope(text)
  }

  public static func isInternalDelegationEnvelope(_ rawText: String) -> Bool {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasRolePrefix = text.hasPrefix("你是 Loops 執行手")
      || text.hasPrefix("你是 Loops")
      || text.hasPrefix("You are Loops Executor")
      || text.hasPrefix("You are a Loops Executor")
    guard hasRolePrefix else { return false }

    let lower = text.lowercased()
    let hasContract = lower.contains("contractid=contract-")
      || lower.contains("contract: contract-")
      || lower.contains("contract contract-")
    return hasContract
      && (text.contains("完成即停") || lower.contains("finish and stop"))
      && (text.contains("禁止一切 git") || lower.contains("do not run git"))
  }

  public static func isTranscriptNoise(
    _ rawText: String,
    role: TatwoChatTranscriptRole,
    status: String?,
    eventKind: TatwoNativeChatEventKind
  ) -> Bool {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = cleanedTranscriptSource(trimmed, role: role)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned != trimmed, cleaned.isEmpty {
      return true
    }
    if isInternalArtifact(trimmed, role: role) {
      return true
    }
    if role == .system {
      let normalizedStatus = status?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
      if hiddenSystemStatuses.contains(normalizedStatus) {
        return true
      }
    }
    guard role == .assistant else { return false }

    let trimmedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines)
    if eventKind == .message,
       trimmedStatus?.isEmpty ?? true,
       trimmed == "沒有收到模型回覆。" {
      return true
    }
    if suppressesHistoricalActivity(eventKind: eventKind) {
      let normalizedStatus = status?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // Codex-style activity rows are part of the visible transcript when
      // they carry a public summary or an active lifecycle status. Suppress
      // only inert legacy rows that contain neither.
      return trimmed.isEmpty && normalizedStatus.isEmpty
    }
    return false
  }

  public static func cleanedTranscriptSource(
    _ rawText: String,
    role: TatwoChatTranscriptRole
  ) -> String {
    var source = rawText
    if role == .user {
      source = extractingCappedStatelessCurrentUserRequest(from: source)
      source = unwrappingAnchoredCodexDelegation(from: source)
      source = removingPairedHiddenContextBlocks(from: source)
    } else {
      var removedEnvelope = true
      while removedEnvelope {
        removedEnvelope = false
        for pattern in leadingCleanableEnvelopePatterns {
          let cleaned = source.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression)
          if cleaned != source {
            source = cleaned
            removedEnvelope = true
            break
          }
        }
      }
      source = removingTrailingMemoryCitation(from: source)
    }

    if let request = importedFilesRequestBody(in: source) {
      return request
    }
    guard role != .user else { return source }

    let marker = "## My request for Codex:"
    if let firstMeaningfulIndex = source.firstIndex(where: { !$0.isWhitespace }),
       source[firstMeaningfulIndex...].hasPrefix(marker) {
      let markerEnd = source.index(
        firstMeaningfulIndex,
        offsetBy: marker.count)
      source = String(source[markerEnd...])
    }
    return source
  }

  public static func retainedPersistableSuffix<Element>(
    _ elements: [Element],
    limit: Int,
    isPersistable: (Element) -> Bool
  ) -> [Element] {
    guard limit > 0 else { return [] }
    return Array(elements.filter(isPersistable).suffix(limit))
  }

  public static func usesCompactActivity(
    role: TatwoChatTranscriptRole,
    eventKind: TatwoNativeChatEventKind,
    text: String,
    status: String?
  ) -> Bool {
    guard role == .assistant else { return false }

    let normalizedStatus = status?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    guard !normalizedStatus.contains("fail"),
          !normalizedStatus.contains("error")
    else { return false }

    if eventKind == .thinking || eventKind == .toolUse {
      return true
    }
    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !normalizedStatus.isEmpty
    else { return false }

    let baseStatus = normalizedStatus
      .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      .first
      .map(String.init) ?? ""
    return compactActivityStatuses.contains(baseStatus)
  }

  public static func suppressesHistoricalActivity(
    eventKind: TatwoNativeChatEventKind
  ) -> Bool {
    eventKind == .thinking || eventKind == .toolUse
  }

  public static func assistantMarkdown(_ rawText: String) -> AttributedString {
    assistantMarkdown(rawText, parser: parseAssistantMarkdown)
  }

  static func assistantMarkdown(
    _ rawText: String,
    parser: (String) throws -> AttributedString
  ) -> AttributedString {
    do {
      return try parser(rawText)
    } catch {
      return AttributedString(rawText)
    }
  }

  private static func parseAssistantMarkdown(_ rawText: String) throws -> AttributedString {
    try AttributedString(
      markdown: rawText,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
  }

  private static let compactActivityStatuses: Set<String> = [
    "streaming", "stream", "thinking", "inspecting", "planning",
    "debugging", "working", "checking", "building", "testing",
    "editing", "viewing", "browsing", "searching", "running-command",
    "calling-tool", "using-computer", "collaborating", "waiting-collab",
    "compacting-context",
    "tool-use", "tool use", "waiting", "queued", "completed",
    "done", "stopped"
  ]

  private static let hiddenSystemStatuses: Set<String> = [
    "handoff export", "handoff import",
    "queue", "監工卡", "收據卡", "停止卡", "範圍警報", "紅卡"
  ]

  private static let leadingCleanableEnvelopePatterns = [
    #"^\s*<codex_internal_context\b[\s\S]*?</codex_internal_context>"#,
    #"^\s*<subagent_notification>[\s\S]*?</subagent_notification>"#
  ]

  private static let exactAppInjectedHiddenContextLabels: Set<String> = [
    "TATWO Chat interface contract",
    "TATWO Work OS authority frame",
    "Codex-style Goal state",
    "Codex-style Plan mode contract",
    "TATWO Computer Host contract",
    "TATWO PLG phase state",
    "TATWO thread plugins decision context",
    "image context receipt",
  ]

  /// The stateless gateway may prepend a bounded same-thread history before
  /// the actual user turn. That transport envelope is runner context, not a
  /// visible user message. Only the exact anchored capped-stateless shape is
  /// unwrapped so ordinary prose mentioning these labels remains untouched.
  private static func extractingCappedStatelessCurrentUserRequest(
    from source: String
  ) -> String {
    let lines = transcriptLines(in: source)
    guard let firstIndex = lines.firstIndex(where: {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }),
    lines[firstIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
      == "Conversation history from this same Tatwo thread:"
    else { return source }

    guard let policyIndex = lines.indices.dropFirst(firstIndex + 1).first(where: {
      !lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else { return source }
    let policy = lines[policyIndex].text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard policy.hasPrefix("bridgePolicy=capped-stateless;") else {
      return source
    }

    guard let requestIndex = lines.indices.dropFirst(policyIndex + 1).first(where: {
      lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        == "Current user request:"
    }) else { return source }
    return String(source[lines[requestIndex].nextStart...])
  }

  /// Codex delegation is a transport wrapper. A complete, anchored envelope
  /// contributes only its `<input>` body to the visible/canonical transcript.
  /// Partial envelopes and literal examples remain byte-for-byte visible.
  private static func unwrappingAnchoredCodexDelegation(
    from source: String
  ) -> String {
    let pattern =
      #"(?s)^\s*<codex_delegation>\s*<source_thread_id>[^<\r\n]+</source_thread_id>\s*<input>(.*?)</input>\s*</codex_delegation>\s*$"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)),
          match.range.location != NSNotFound,
          let bodyRange = Range(match.range(at: 1), in: source)
    else { return source }
    return String(source[bodyRange])
  }

  private static func importedFilesRequestBody(in source: String) -> String? {
    let lines = transcriptLines(in: source)
    guard let headingIndex = lines.firstIndex(where: {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }),
    lines[headingIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
      == "# Files mentioned by the user:"
    else { return nil }

    var sawRecognizedFile = false
    for line in lines.dropFirst(headingIndex + 1) {
      let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        continue
      }
      if trimmed == "## My request for Codex:" {
        guard sawRecognizedFile else { return nil }
        let request = String(source[line.nextStart...])
        return request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? nil
          : request
      }
      guard isRecognizedImportedFileLine(trimmed) else { return nil }
      sawRecognizedFile = true
    }
    return nil
  }

  private static func removingTrailingMemoryCitation(from source: String) -> String {
    let lines = transcriptLines(in: source)
    guard let closingIndex = lines.lastIndex(where: {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }),
    lines[closingIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
      == "</oai-mem-citation>",
    let openingIndex = lines[..<closingIndex].lastIndex(where: {
      $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        == "<oai-mem-citation>"
    })
    else { return source }

    let body = source[..<lines[openingIndex].start]
    guard let bodyEnd = body.lastIndex(where: { !$0.isWhitespace }) else {
      return ""
    }
    return String(body[...bodyEnd])
  }

  private static func removingPairedHiddenContextBlocks(from source: String) -> String {
    let lines = transcriptLines(in: source)
    let codeProtectedLines = codeProtectedTranscriptLineIndices(lines)
    let newline = source.contains("\r\n") ? "\r\n" : "\n"
    var visibleLines: [String] = []
    var index = 0
    var removedBlock = false

    while index < lines.count {
      guard !codeProtectedLines.contains(index) else {
        visibleLines.append(normalizedTranscriptLine(lines[index].text))
        index += 1
        continue
      }

      guard let openingLabel = hiddenContextLabel(
        in: lines[index].text,
        isClosing: false)
      else {
        visibleLines.append(normalizedTranscriptLine(lines[index].text))
        index += 1
        continue
      }

      guard let closingIndex = completeHiddenContextBlockEnd(
        startingAt: index,
        openingLabel: openingLabel,
        lines: lines,
        codeProtectedLines: codeProtectedLines)
      else {
        while index < lines.count {
          visibleLines.append(normalizedTranscriptLine(lines[index].text))
          index += 1
        }
        break
      }

      removedBlock = true
      let hadBlankBefore = visibleLines.last.map(isBlankTranscriptLine) ?? false
      while visibleLines.last.map(isBlankTranscriptLine) == true {
        visibleLines.removeLast()
      }

      var nextIndex = closingIndex + 1
      var hadBlankAfter = false
      while nextIndex < lines.count,
            isBlankTranscriptLine(lines[nextIndex].text) {
        hadBlankAfter = true
        nextIndex += 1
      }
      if !visibleLines.isEmpty,
         nextIndex < lines.count,
         hadBlankBefore || hadBlankAfter {
        visibleLines.append("")
      }
      index = nextIndex
    }

    guard removedBlock else { return source }
    return visibleLines.joined(separator: newline)
  }

  private static func completeHiddenContextBlockEnd(
    startingAt openingIndex: Int,
    openingLabel: String,
    lines: [(text: String, start: String.Index, nextStart: String.Index)],
    codeProtectedLines: Set<Int>
  ) -> Int? {
    var labelStack = [openingLabel]
    var index = openingIndex + 1

    while index < lines.count {
      if codeProtectedLines.contains(index) {
        index += 1
        continue
      }

      if let nestedLabel = hiddenContextLabel(
        in: lines[index].text,
        isClosing: false)
      {
        labelStack.append(nestedLabel)
        index += 1
        continue
      }

      if let closingLabel = hiddenContextLabel(
        in: lines[index].text,
        isClosing: true)
      {
        guard labelStack.last == closingLabel else { return nil }
        labelStack.removeLast()
        if labelStack.isEmpty {
          return index
        }
      }
      index += 1
    }

    return nil
  }

  private static func hiddenContextLabel(
    in line: String,
    isClosing: Bool
  ) -> String? {
    let normalizedLine = normalizedTranscriptLine(line)
    var leadingSpaceCount = 0
    for character in normalizedLine {
      if character == " " {
        leadingSpaceCount += 1
        guard leadingSpaceCount <= 3 else { return nil }
      } else if character == "\t" {
        return nil
      } else {
        break
      }
    }

    let trimmed = normalizedLine.trimmingCharacters(in: .whitespaces)
    let prefix = isClosing ? "[/Hidden" : "[Hidden"
    guard trimmed.hasPrefix(prefix),
          trimmed.hasSuffix("]")
    else { return nil }

    let labelStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
    let rawLabel = trimmed[labelStart..<trimmed.index(before: trimmed.endIndex)]
      .trimmingCharacters(in: .whitespaces)
    guard !rawLabel.isEmpty else { return nil }

    if !isClosing,
       let instructionSeparator = rawLabel.range(of: " — ") {
      let label = rawLabel[..<instructionSeparator.lowerBound]
        .trimmingCharacters(in: .whitespaces)
      return isAppInjectedHiddenContextLabel(label) ? label : nil
    }
    return isAppInjectedHiddenContextLabel(rawLabel) ? rawLabel : nil
  }

  private static func isAppInjectedHiddenContextLabel(_ label: String) -> Bool {
    if exactAppInjectedHiddenContextLabels.contains(label) {
      return true
    }
    guard label.hasSuffix(" context") else { return false }
    return label.hasPrefix("TATWO Work OS ")
      || label.hasPrefix("TATWO Ultrawork ")
  }

  private struct TranscriptCodeFence {
    let marker: Character
    let minimumLength: Int
  }

  private static func codeProtectedTranscriptLineIndices(
    _ lines: [(text: String, start: String.Index, nextStart: String.Index)]
  ) -> Set<Int> {
    var result: Set<Int> = []
    var activeFence: TranscriptCodeFence?
    var activeInlineBacktickLength: Int?

    for (index, line) in lines.enumerated() {
      let text = normalizedTranscriptLine(line.text)

      if let fence = activeFence {
        result.insert(index)
        if isClosingTranscriptCodeFence(text, matching: fence) {
          activeFence = nil
        }
        continue
      }

      if activeInlineBacktickLength != nil {
        result.insert(index)
      } else if let fence = openingTranscriptCodeFence(in: text) {
        result.insert(index)
        activeFence = fence
        continue
      }

      activeInlineBacktickLength = inlineBacktickLength(
        afterScanning: text,
        activeLength: activeInlineBacktickLength)
    }
    return result
  }

  private static func openingTranscriptCodeFence(
    in line: String
  ) -> TranscriptCodeFence? {
    var index = line.startIndex
    var leadingSpaces = 0
    while index < line.endIndex, line[index] == " " {
      leadingSpaces += 1
      guard leadingSpaces <= 3 else { return nil }
      index = line.index(after: index)
    }
    guard index < line.endIndex,
          line[index] == "`" || line[index] == "~"
    else { return nil }

    let marker = line[index]
    var markerEnd = index
    while markerEnd < line.endIndex, line[markerEnd] == marker {
      markerEnd = line.index(after: markerEnd)
    }
    let markerLength = line.distance(from: index, to: markerEnd)
    guard markerLength >= 3 else { return nil }

    if marker == "`",
       line[markerEnd...].contains("`") {
      return nil
    }
    return TranscriptCodeFence(
      marker: marker,
      minimumLength: markerLength)
  }

  private static func isClosingTranscriptCodeFence(
    _ line: String,
    matching fence: TranscriptCodeFence
  ) -> Bool {
    var index = line.startIndex
    var leadingSpaces = 0
    while index < line.endIndex, line[index] == " " {
      leadingSpaces += 1
      guard leadingSpaces <= 3 else { return false }
      index = line.index(after: index)
    }
    guard index < line.endIndex, line[index] == fence.marker else {
      return false
    }

    var markerEnd = index
    while markerEnd < line.endIndex, line[markerEnd] == fence.marker {
      markerEnd = line.index(after: markerEnd)
    }
    guard line.distance(from: index, to: markerEnd) >= fence.minimumLength else {
      return false
    }
    return line[markerEnd...].allSatisfy { $0 == " " || $0 == "\t" }
  }

  private static func inlineBacktickLength(
    afterScanning line: String,
    activeLength initialActiveLength: Int?
  ) -> Int? {
    var activeLength = initialActiveLength
    var index = line.startIndex

    while index < line.endIndex {
      guard line[index] == "`" else {
        index = line.index(after: index)
        continue
      }

      var runEnd = index
      while runEnd < line.endIndex, line[runEnd] == "`" {
        runEnd = line.index(after: runEnd)
      }
      let runLength = line.distance(from: index, to: runEnd)

      if let expectedLength = activeLength {
        if runLength == expectedLength {
          activeLength = nil
        }
      } else if !isEscapedBacktick(at: index, in: line) {
        activeLength = runLength
      }
      index = runEnd
    }
    return activeLength
  }

  private static func isEscapedBacktick(
    at index: String.Index,
    in line: String
  ) -> Bool {
    var backslashCount = 0
    var cursor = index
    while cursor > line.startIndex {
      let previous = line.index(before: cursor)
      guard line[previous] == "\\" else { break }
      backslashCount += 1
      cursor = previous
    }
    return backslashCount.isMultiple(of: 2) == false
  }

  private static func normalizedTranscriptLine(_ line: String) -> String {
    line.hasSuffix("\r") ? String(line.dropLast()) : line
  }

  private static func isBlankTranscriptLine(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func transcriptLines(
    in source: String
  ) -> [(text: String, start: String.Index, nextStart: String.Index)] {
    var result: [(text: String, start: String.Index, nextStart: String.Index)] = []
    var lineStart = source.startIndex

    while true {
      let newline = source[lineStart...].firstIndex(of: "\n")
      let lineEnd = newline ?? source.endIndex
      let nextStart = newline.map { source.index(after: $0) } ?? source.endIndex
      result.append((String(source[lineStart..<lineEnd]), lineStart, nextStart))
      guard let newline else { break }
      lineStart = source.index(after: newline)
    }
    return result
  }

  private static func isRecognizedImportedFileLine(_ line: String) -> Bool {
    if line.hasPrefix("<image ")
      || line.hasPrefix("<video ")
      || line.hasPrefix("<file ") {
      guard line.hasSuffix(">"),
            let pathMarker = line.range(of: "path=\"")
      else { return false }
      let pathAndRemainder = line[pathMarker.upperBound...]
      return pathAndRemainder.hasPrefix("/")
        && pathAndRemainder.dropFirst().contains("\"")
    }
    if line.hasPrefix("![") {
      return line.contains("](/") && line.hasSuffix(")")
    }
    guard line.hasPrefix("## "),
          let separator = line.range(of: ": /")
    else { return false }
    return !line[line.index(line.startIndex, offsetBy: 3)..<separator.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  private static func isCompleteAnchoredEnvelope(
    _ text: String,
    openingTag: String,
    closingTag: String
  ) -> Bool {
    text.hasPrefix(openingTag) && text.contains(closingTag)
  }

  private static func isOtherLanguageModelHandoffEnvelope(_ text: String) -> Bool {
    text.hasPrefix("Another language model started to solve this problem")
      && text.contains("Here is the summary produced by the other language model")
  }

}
