import Foundation

public enum TatwoChangeReceiptFileStatus: String, Codable, Sendable, CaseIterable, Equatable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case untracked
  case typeChanged
  case conflicted
  case unknown
}

public struct TatwoChangeReceiptHunkSummary: Codable, Sendable, Equatable {
  public let oldStart: Int
  public let oldLineCount: Int
  public let newStart: Int
  public let newLineCount: Int
  public let heading: String?
  public let additions: Int
  public let deletions: Int

  public init(
    oldStart: Int,
    oldLineCount: Int,
    newStart: Int,
    newLineCount: Int,
    heading: String? = nil,
    additions: Int,
    deletions: Int
  ) {
    self.oldStart = oldStart
    self.oldLineCount = oldLineCount
    self.newStart = newStart
    self.newLineCount = newLineCount
    self.heading = heading
    self.additions = additions
    self.deletions = deletions
  }
}

public struct TatwoChangeReceiptFile: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let relativePath: String
  public let previousRelativePath: String?
  public let status: TatwoChangeReceiptFileStatus
  public let staged: Bool
  public let unstaged: Bool
  public let additions: Int?
  public let deletions: Int?
  public let isBinary: Bool
  public let hunks: [TatwoChangeReceiptHunkSummary]
  public let warnings: [String]

  public init(
    id: String? = nil,
    relativePath: String,
    previousRelativePath: String? = nil,
    status: TatwoChangeReceiptFileStatus,
    staged: Bool = false,
    unstaged: Bool = false,
    additions: Int? = nil,
    deletions: Int? = nil,
    isBinary: Bool = false,
    hunks: [TatwoChangeReceiptHunkSummary] = [],
    warnings: [String] = []
  ) {
    self.id = id ?? relativePath
    self.relativePath = relativePath
    self.previousRelativePath = previousRelativePath
    self.status = status
    self.staged = staged
    self.unstaged = unstaged
    self.additions = additions
    self.deletions = deletions
    self.isBinary = isBinary
    self.hunks = hunks
    self.warnings = warnings
  }
}

public struct TatwoChangeReceiptSummary: Codable, Sendable, Equatable {
  public let fileCount: Int
  public let additions: Int
  public let deletions: Int
  public let binaryCount: Int
  public let untrackedCount: Int
  public let conflictedCount: Int

  public init(
    fileCount: Int,
    additions: Int,
    deletions: Int,
    binaryCount: Int,
    untrackedCount: Int,
    conflictedCount: Int
  ) {
    self.fileCount = fileCount
    self.additions = additions
    self.deletions = deletions
    self.binaryCount = binaryCount
    self.untrackedCount = untrackedCount
    self.conflictedCount = conflictedCount
  }
}

public struct TatwoChangeReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let summary: TatwoChangeReceiptSummary
  public let files: [TatwoChangeReceiptFile]
  public let warnings: [String]

  public init(
    schema: String = "TatwoChangeReceiptV1",
    summary: TatwoChangeReceiptSummary,
    files: [TatwoChangeReceiptFile],
    warnings: [String] = []
  ) {
    self.schema = schema
    self.summary = summary
    self.files = files
    self.warnings = warnings
  }
}

public enum TatwoChangeReceiptParser {
  public static func parse(diff: String, status: String = "") -> TatwoChangeReceiptV1 {
    let diffResult = parseUnifiedDiff(diff)
    let statusResult = parsePorcelainStatus(status)
    var filesByPath: [String: TatwoChangeReceiptFile] = [:]
    for diffFile in diffResult.files {
      if let existing = filesByPath[diffFile.relativePath] {
        filesByPath[diffFile.relativePath] = merge(existing, with: diffFile)
      } else {
        filesByPath[diffFile.relativePath] = diffFile
      }
    }

    for statusFile in statusResult.files {
      if let diffFile = filesByPath[statusFile.relativePath] {
        filesByPath[statusFile.relativePath] = TatwoChangeReceiptFile(
          relativePath: diffFile.relativePath,
          previousRelativePath: statusFile.previousRelativePath ?? diffFile.previousRelativePath,
          status: statusFile.status,
          staged: statusFile.staged,
          unstaged: statusFile.unstaged,
          additions: diffFile.additions,
          deletions: diffFile.deletions,
          isBinary: diffFile.isBinary,
          hunks: diffFile.hunks,
          warnings: unique(diffFile.warnings + statusFile.warnings))
      } else {
        filesByPath[statusFile.relativePath] = statusFile
      }
    }

    let files = filesByPath.values.sorted {
      $0.relativePath < $1.relativePath
    }
    let summary = TatwoChangeReceiptSummary(
      fileCount: files.count,
      additions: files.compactMap(\.additions).reduce(0, +),
      deletions: files.compactMap(\.deletions).reduce(0, +),
      binaryCount: files.filter(\.isBinary).count,
      untrackedCount: files.filter { $0.status == .untracked }.count,
      conflictedCount: files.filter { $0.status == .conflicted }.count)

    return TatwoChangeReceiptV1(
      summary: summary,
      files: files,
      warnings: unique(diffResult.warnings + statusResult.warnings))
  }

  private static func merge(
    _ first: TatwoChangeReceiptFile,
    with second: TatwoChangeReceiptFile
  ) -> TatwoChangeReceiptFile {
    let isBinary = first.isBinary || second.isBinary
    return TatwoChangeReceiptFile(
      relativePath: first.relativePath,
      previousRelativePath: second.previousRelativePath ?? first.previousRelativePath,
      status: second.status == .modified ? first.status : second.status,
      staged: first.staged || second.staged,
      unstaged: first.unstaged || second.unstaged,
      additions: isBinary ? nil : (first.additions ?? 0) + (second.additions ?? 0),
      deletions: isBinary ? nil : (first.deletions ?? 0) + (second.deletions ?? 0),
      isBinary: isBinary,
      hunks: first.hunks + second.hunks,
      warnings: unique(first.warnings + second.warnings))
  }

  private struct ParseResult {
    var files: [TatwoChangeReceiptFile] = []
    var warnings: [String] = []
  }

  private struct MutableHunk {
    let oldStart: Int
    let oldLineCount: Int
    let newStart: Int
    let newLineCount: Int
    let heading: String?
    var additions = 0
    var deletions = 0

    var value: TatwoChangeReceiptHunkSummary {
      TatwoChangeReceiptHunkSummary(
        oldStart: oldStart,
        oldLineCount: oldLineCount,
        newStart: newStart,
        newLineCount: newLineCount,
        heading: heading,
        additions: additions,
        deletions: deletions)
    }
  }

  private struct MutableDiffFile {
    var oldPath: String?
    var newPath: String?
    var previousPath: String?
    var status: TatwoChangeReceiptFileStatus = .modified
    var isBinary = false
    var additions = 0
    var deletions = 0
    var hunks: [TatwoChangeReceiptHunkSummary] = []
    var currentHunk: MutableHunk?
    var warnings: [String] = []

    mutating func finishHunk() {
      if let currentHunk {
        hunks.append(currentHunk.value)
        self.currentHunk = nil
      }
    }

    mutating func addContentLine(_ line: String) {
      guard currentHunk != nil else { return }
      if line.hasPrefix("+") && !line.hasPrefix("+++") {
        additions += 1
        currentHunk?.additions += 1
      } else if line.hasPrefix("-") && !line.hasPrefix("---") {
        deletions += 1
        currentHunk?.deletions += 1
      }
    }

    mutating func value() -> TatwoChangeReceiptFile? {
      finishHunk()
      let destination = newPath == "/dev/null" ? oldPath : (newPath ?? oldPath)
      guard let destination else { return nil }
      let normalizedPath = normalizedDiffPath(destination)
      guard isSafeRelativePath(normalizedPath) else { return nil }
      let normalizedPrevious = previousPath.map(normalizedDiffPath)
      let lineAdditions: Int? = isBinary ? nil : additions
      let lineDeletions: Int? = isBinary ? nil : deletions
      return TatwoChangeReceiptFile(
        relativePath: normalizedPath,
        previousRelativePath: normalizedPrevious == normalizedPath ? nil : normalizedPrevious,
        status: status,
        additions: lineAdditions,
        deletions: lineDeletions,
        isBinary: isBinary,
        hunks: hunks,
        warnings: warnings)
    }
  }

  private static func parseUnifiedDiff(_ input: String) -> ParseResult {
    guard !input.isEmpty else { return ParseResult() }
    var result = ParseResult()
    var current: MutableDiffFile?

    func appendCurrent() {
      guard var file = current else { return }
      if let value = file.value() {
        result.files.append(value)
      } else {
        result.warnings.append("diff_missing_or_unsafe_path")
      }
      current = nil
    }

    for rawLine in normalizedLines(input) {
      let line = rawLine
      if line.hasPrefix("diff --git ") {
        appendCurrent()
        guard let paths = parseDiffHeaderPaths(String(line.dropFirst("diff --git ".count))) else {
          result.warnings.append("malformed_diff_header")
          current = MutableDiffFile()
          continue
        }
        current = MutableDiffFile(oldPath: paths.old, newPath: paths.new)
        continue
      }

      if line.hasPrefix("--- ") {
        if current == nil {
          current = MutableDiffFile()
        }
        current?.oldPath = parsePatchPath(String(line.dropFirst(4)))
        if current?.oldPath == "/dev/null" {
          current?.status = .added
        }
        continue
      }

      if line.hasPrefix("+++ ") {
        if current == nil {
          current = MutableDiffFile()
        }
        current?.newPath = parsePatchPath(String(line.dropFirst(4)))
        if current?.newPath == "/dev/null" {
          current?.status = .deleted
        }
        continue
      }

      guard current != nil else {
        if line.hasPrefix("@@") || line.hasPrefix("+") || line.hasPrefix("-") {
          result.warnings.append("orphan_diff_content")
        }
        continue
      }

      if line.hasPrefix("new file mode ") {
        current?.status = .added
      } else if line.hasPrefix("deleted file mode ") {
        current?.status = .deleted
      } else if line.hasPrefix("rename from ") {
        let path = decodeGitPath(String(line.dropFirst("rename from ".count)))
        current?.previousPath = path
        current?.oldPath = path
        current?.status = .renamed
      } else if line.hasPrefix("rename to ") {
        current?.newPath = decodeGitPath(String(line.dropFirst("rename to ".count)))
        current?.status = .renamed
      } else if line.hasPrefix("copy from ") {
        let path = decodeGitPath(String(line.dropFirst("copy from ".count)))
        current?.previousPath = path
        current?.oldPath = path
        current?.status = .copied
      } else if line.hasPrefix("copy to ") {
        current?.newPath = decodeGitPath(String(line.dropFirst("copy to ".count)))
        current?.status = .copied
      } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
        current?.isBinary = true
      } else if line.hasPrefix("@@") {
        current?.finishHunk()
        if let hunk = parseHunkHeader(line) {
          current?.currentHunk = hunk
        } else {
          current?.warnings.append("malformed_hunk_header")
          result.warnings.append("malformed_hunk_header")
        }
      } else {
        current?.addContentLine(line)
      }
    }

    appendCurrent()
    return result
  }

  private static func parsePorcelainStatus(_ input: String) -> ParseResult {
    guard !input.isEmpty else { return ParseResult() }
    var result = ParseResult()

    if input.contains("\0") {
      let records = input.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
      var index = 0
      while index < records.count {
        let record = records[index]
        guard let parsed = parseStatusRecord(record) else {
          result.warnings.append("malformed_status_record")
          index += 1
          continue
        }
        if parsed.isIgnored {
          index += 1
          continue
        }
        var previousPath: String?
        if parsed.status == .renamed || parsed.status == .copied {
          let previousIndex = index + 1
          if previousIndex < records.count {
            previousPath = decodeGitPath(records[previousIndex])
            index += 1
          } else {
            result.warnings.append("status_missing_previous_path")
          }
        }
        appendStatusFile(
          parsed: parsed,
          destinationPath: parsed.path,
          previousPath: previousPath,
          result: &result)
        index += 1
      }
      return result
    }

    for line in normalizedLines(input) where !line.isEmpty {
      guard let parsed = parseStatusRecord(line) else {
        result.warnings.append("malformed_status_record")
        continue
      }
      guard !parsed.isIgnored else { continue }
      var destinationPath = parsed.path
      var previousPath: String?
      if parsed.status == .renamed || parsed.status == .copied,
        let separator = destinationPath.range(of: " -> ", options: .backwards)
      {
        previousPath = decodeGitPath(String(destinationPath[..<separator.lowerBound]))
        destinationPath = decodeGitPath(String(destinationPath[separator.upperBound...]))
      }
      appendStatusFile(
        parsed: parsed,
        destinationPath: destinationPath,
        previousPath: previousPath,
        result: &result)
    }
    return result
  }

  private struct ParsedStatusRecord {
    let path: String
    let status: TatwoChangeReceiptFileStatus
    let staged: Bool
    let unstaged: Bool
    let isIgnored: Bool
  }

  private static func parseStatusRecord(_ record: String) -> ParsedStatusRecord? {
    let characters = Array(record)
    guard characters.count >= 3 else { return nil }
    let x = characters[0]
    let y = characters[1]
    let path = decodeGitPath(String(characters.dropFirst(3)))
    guard !path.isEmpty else { return nil }
    let ignored = x == "!" && y == "!"
    let status = statusFor(x: x, y: y)
    return ParsedStatusRecord(
      path: path,
      status: status,
      staged: x != " " && x != "?" && x != "!",
      unstaged: y != " " && y != "?" && y != "!",
      isIgnored: ignored)
  }

  private static func appendStatusFile(
    parsed: ParsedStatusRecord,
    destinationPath: String,
    previousPath: String?,
    result: inout ParseResult
  ) {
    let path = normalizedDiffPath(destinationPath)
    guard isSafeRelativePath(path) else {
      result.warnings.append("unsafe_path:\(destinationPath)")
      return
    }
    let safePreviousPath: String?
    if let previousPath {
      let normalized = normalizedDiffPath(previousPath)
      if isSafeRelativePath(normalized) {
        safePreviousPath = normalized
      } else {
        safePreviousPath = nil
        result.warnings.append("unsafe_previous_path:\(previousPath)")
      }
    } else {
      safePreviousPath = nil
    }
    result.files.append(
      TatwoChangeReceiptFile(
        relativePath: path,
        previousRelativePath: safePreviousPath,
        status: parsed.status,
        staged: parsed.staged,
        unstaged: parsed.unstaged))
  }

  private static func statusFor(x: Character, y: Character) -> TatwoChangeReceiptFileStatus {
    let pair = String([x, y])
    if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair) {
      return .conflicted
    }
    if x == "?" && y == "?" { return .untracked }
    if x == "R" || y == "R" { return .renamed }
    if x == "C" || y == "C" { return .copied }
    if x == "A" || y == "A" { return .added }
    if x == "D" || y == "D" { return .deleted }
    if x == "T" || y == "T" { return .typeChanged }
    if x == "M" || y == "M" { return .modified }
    return .unknown
  }

  private static func parseHunkHeader(_ line: String) -> MutableHunk? {
    guard line.hasPrefix("@@"),
      let closing = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
    else {
      return nil
    }
    let rangeText = line[line.index(line.startIndex, offsetBy: 2)..<closing.lowerBound]
      .trimmingCharacters(in: .whitespaces)
    let ranges = rangeText.split(whereSeparator: \.isWhitespace)
    guard ranges.count >= 2,
      let oldRange = parseHunkRange(String(ranges[0]), prefix: "-"),
      let newRange = parseHunkRange(String(ranges[1]), prefix: "+")
    else {
      return nil
    }
    let headingText = line[closing.upperBound...].trimmingCharacters(in: .whitespaces)
    return MutableHunk(
      oldStart: oldRange.start,
      oldLineCount: oldRange.count,
      newStart: newRange.start,
      newLineCount: newRange.count,
      heading: headingText.isEmpty ? nil : headingText)
  }

  private static func parseHunkRange(
    _ value: String,
    prefix: Character
  ) -> (start: Int, count: Int)? {
    guard value.first == prefix else { return nil }
    let components = value.dropFirst().split(separator: ",", maxSplits: 1)
    guard let start = Int(components[0]) else { return nil }
    let count = components.count == 2 ? Int(components[1]) : 1
    guard let count else { return nil }
    return (start, count)
  }

  private static func parseDiffHeaderPaths(_ value: String) -> (old: String, new: String)? {
    let tokens = gitHeaderTokens(value)
    if tokens.count == 2 {
      return (decodeGitPath(tokens[0]), decodeGitPath(tokens[1]))
    }
    guard let separator = value.range(of: " b/", options: .backwards) else {
      return nil
    }
    return (
      decodeGitPath(String(value[..<separator.lowerBound])),
      decodeGitPath(String(value[separator.upperBound...]).withPrefix("b/")))
  }

  private static func gitHeaderTokens(_ value: String) -> [String] {
    var tokens: [String] = []
    var token = ""
    var quoted = false
    var escaped = false
    for character in value {
      if escaped {
        token.append(character)
        escaped = false
      } else if character == "\\" && quoted {
        token.append(character)
        escaped = true
      } else if character == "\"" {
        token.append(character)
        quoted.toggle()
      } else if character.isWhitespace && !quoted {
        if !token.isEmpty {
          tokens.append(token)
          token = ""
        }
      } else {
        token.append(character)
      }
    }
    if !token.isEmpty {
      tokens.append(token)
    }
    return tokens
  }

  private static func parsePatchPath(_ value: String) -> String {
    let pathOnly = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? value
    return decodeGitPath(pathOnly)
  }

  private static func decodeGitPath(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else {
      return trimmed
    }
    let bytes = Array(trimmed.dropFirst().dropLast().utf8)
    var decoded: [UInt8] = []
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 92, index + 1 < bytes.count else {
        decoded.append(bytes[index])
        index += 1
        continue
      }
      let next = bytes[index + 1]
      switch next {
      case 110:
        decoded.append(10)
        index += 2
      case 116:
        decoded.append(9)
        index += 2
      case 114:
        decoded.append(13)
        index += 2
      case 34, 92:
        decoded.append(next)
        index += 2
      case 48...55:
        var value = Int(next - 48)
        var consumed = 1
        while consumed < 3, index + 1 + consumed < bytes.count {
          let digit = bytes[index + 1 + consumed]
          guard (48...55).contains(digit) else { break }
          value = value * 8 + Int(digit - 48)
          consumed += 1
        }
        decoded.append(UInt8(clamping: value))
        index += consumed + 1
      default:
        decoded.append(next)
        index += 2
      }
    }
    return String(decoding: decoded, as: UTF8.self)
  }

  private static func normalizedDiffPath(_ value: String) -> String {
    let decoded = decodeGitPath(value)
    if decoded.hasPrefix("a/") || decoded.hasPrefix("b/") {
      return String(decoded.dropFirst(2))
    }
    return decoded
  }

  private static func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, value != "/dev/null", !value.hasPrefix("/") else { return false }
    return !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }

  private static func normalizedLines(_ value: String) -> [String] {
    value.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}

private extension String {
  func withPrefix(_ prefix: String) -> String {
    prefix + self
  }
}
