// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoDiffHunkParser.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public enum TatwoDiffChangeKind: String, Codable, Sendable, Equatable {
  case added
  case modified
  case deleted
  case renamed
}

public enum TatwoDiffLineKind: String, Codable, Sendable, Equatable {
  case context
  case added
  case removed
}

public struct TatwoDiffLine: Codable, Sendable, Equatable {
  public let kind: TatwoDiffLineKind
  public let oldLineNumber: Int?
  public let newLineNumber: Int?
  public let text: String

  public init(
    kind: TatwoDiffLineKind,
    oldLineNumber: Int?,
    newLineNumber: Int?,
    text: String
  ) {
    self.kind = kind
    self.oldLineNumber = oldLineNumber
    self.newLineNumber = newLineNumber
    self.text = text
  }
}

public struct TatwoDiffHunk: Codable, Sendable, Equatable {
  public let header: String
  public let lines: [TatwoDiffLine]

  public init(header: String, lines: [TatwoDiffLine]) {
    self.header = header
    self.lines = lines
  }
}

public struct TatwoDiffFile: Codable, Sendable, Equatable {
  public let oldPath: String
  public let newPath: String
  public let changeKind: TatwoDiffChangeKind
  public let hunks: [TatwoDiffHunk]
  public let addedCount: Int
  public let removedCount: Int
  public let isBinary: Bool

  public init(
    oldPath: String,
    newPath: String,
    changeKind: TatwoDiffChangeKind,
    hunks: [TatwoDiffHunk],
    addedCount: Int,
    removedCount: Int,
    isBinary: Bool = false
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    self.changeKind = changeKind
    self.hunks = hunks
    self.addedCount = addedCount
    self.removedCount = removedCount
    self.isBinary = isBinary
  }
}

public struct TatwoParsedDiff: Codable, Sendable, Equatable {
  public let files: [TatwoDiffFile]

  public init(files: [TatwoDiffFile] = []) {
    self.files = files
  }
}

public enum TatwoDiffHunkParser {
  public static func parse(unifiedDiff: String) -> TatwoParsedDiff {
    var files: [TatwoDiffFile] = []
    var currentFile: MutableFile?

    func appendCurrentFile() {
      guard let file = currentFile?.value else { return }
      files.append(file)
      currentFile = nil
    }

    for line in normalizedLines(unifiedDiff) {
      if line.hasPrefix("diff --git ") {
        appendCurrentFile()
        guard let paths = parseDiffHeaderPaths(
          String(line.dropFirst("diff --git ".count)))
        else {
          currentFile = nil
          continue
        }
        currentFile = MutableFile(
          oldPath: normalizedPath(paths.old),
          newPath: normalizedPath(paths.new))
        continue
      }

      if currentFile?.hasActiveHunk == true,
        line == "\\ No newline at end of file"
          || line.first == " "
          || line.first == "+"
          || line.first == "-"
      {
        currentFile?.appendDiffLine(line)
        continue
      }

      if line.hasPrefix("--- ") {
        if currentFile == nil {
          currentFile = MutableFile()
        }
        let path = normalizedPath(parsePatchPath(String(line.dropFirst(4))))
        currentFile?.oldPath = path
        if path == "/dev/null" {
          currentFile?.changeKind = .added
        }
        continue
      }

      if line.hasPrefix("+++ ") {
        if currentFile == nil {
          currentFile = MutableFile()
        }
        let path = normalizedPath(parsePatchPath(String(line.dropFirst(4))))
        currentFile?.newPath = path
        if path == "/dev/null" {
          currentFile?.changeKind = .deleted
        }
        continue
      }

      guard currentFile != nil else { continue }

      if line.hasPrefix("new file mode ") {
        currentFile?.changeKind = .added
      } else if line.hasPrefix("deleted file mode ") {
        currentFile?.changeKind = .deleted
      } else if line.hasPrefix("rename from ") {
        currentFile?.oldPath = normalizedPath(
          String(line.dropFirst("rename from ".count)))
        currentFile?.changeKind = .renamed
      } else if line.hasPrefix("rename to ") {
        currentFile?.newPath = normalizedPath(
          String(line.dropFirst("rename to ".count)))
        currentFile?.changeKind = .renamed
      } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
        currentFile?.markBinary()
      } else if line.hasPrefix("@@") {
        currentFile?.beginHunk(header: line)
      } else {
        currentFile?.appendDiffLine(line)
      }
    }

    appendCurrentFile()
    return TatwoParsedDiff(files: files)
  }

  private struct MutableHunk {
    let header: String
    var oldLineNumber: Int
    var newLineNumber: Int
    var lines: [TatwoDiffLine] = []

    var value: TatwoDiffHunk {
      TatwoDiffHunk(header: header, lines: lines)
    }
  }

  private struct MutableFile {
    var oldPath = ""
    var newPath = ""
    var changeKind: TatwoDiffChangeKind = .modified
    var hunks: [TatwoDiffHunk] = []
    var currentHunk: MutableHunk?
    var addedCount = 0
    var removedCount = 0
    var isBinary = false

    var hasActiveHunk: Bool {
      currentHunk != nil
    }

    init(oldPath: String = "", newPath: String = "") {
      self.oldPath = oldPath
      self.newPath = newPath
    }

    mutating func beginHunk(header: String) {
      guard !isBinary, let starts = parseHunkStarts(header) else { return }
      finishHunk()
      currentHunk = MutableHunk(
        header: header,
        oldLineNumber: starts.old,
        newLineNumber: starts.new)
    }

    mutating func appendDiffLine(_ line: String) {
      guard !isBinary, var hunk = currentHunk else { return }
      guard line != "\\ No newline at end of file", let marker = line.first else {
        return
      }
      let text = String(line.dropFirst())

      switch marker {
      case " ":
        hunk.lines.append(
          TatwoDiffLine(
            kind: .context,
            oldLineNumber: hunk.oldLineNumber,
            newLineNumber: hunk.newLineNumber,
            text: text))
        hunk.oldLineNumber += 1
        hunk.newLineNumber += 1
      case "+":
        hunk.lines.append(
          TatwoDiffLine(
            kind: .added,
            oldLineNumber: nil,
            newLineNumber: hunk.newLineNumber,
            text: text))
        hunk.newLineNumber += 1
        addedCount += 1
      case "-":
        hunk.lines.append(
          TatwoDiffLine(
            kind: .removed,
            oldLineNumber: hunk.oldLineNumber,
            newLineNumber: nil,
            text: text))
        hunk.oldLineNumber += 1
        removedCount += 1
      default:
        return
      }
      currentHunk = hunk
    }

    mutating func markBinary() {
      isBinary = true
      hunks = []
      currentHunk = nil
      addedCount = 0
      removedCount = 0
    }

    mutating func finishHunk() {
      guard let currentHunk else { return }
      hunks.append(currentHunk.value)
      self.currentHunk = nil
    }

    var value: TatwoDiffFile? {
      var copy = self
      copy.finishHunk()
      guard !copy.oldPath.isEmpty || !copy.newPath.isEmpty else { return nil }
      let resolvedOldPath = copy.oldPath.isEmpty ? copy.newPath : copy.oldPath
      let resolvedNewPath = copy.newPath.isEmpty ? copy.oldPath : copy.newPath
      return TatwoDiffFile(
        oldPath: resolvedOldPath,
        newPath: resolvedNewPath,
        changeKind: copy.changeKind,
        hunks: copy.hunks,
        addedCount: copy.addedCount,
        removedCount: copy.removedCount,
        isBinary: copy.isBinary)
    }
  }

  private static func parseHunkStarts(_ header: String) -> (old: Int, new: Int)? {
    guard header.hasPrefix("@@"),
      let closingRange = header.range(
        of: "@@",
        range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex)
    else {
      return nil
    }
    let rangeText = header[
      header.index(header.startIndex, offsetBy: 2)..<closingRange.lowerBound
    ].trimmingCharacters(in: .whitespaces)
    let components = rangeText.split(whereSeparator: \.isWhitespace)
    guard components.count >= 2,
      let oldStart = parseRangeStart(String(components[0]), marker: "-"),
      let newStart = parseRangeStart(String(components[1]), marker: "+")
    else {
      return nil
    }
    return (oldStart, newStart)
  }

  private static func parseRangeStart(_ value: String, marker: Character) -> Int? {
    guard value.first == marker else { return nil }
    let start = value.dropFirst().split(separator: ",", maxSplits: 1).first
    return start.flatMap { Int($0) }
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
      decodeGitPath("b/" + String(value[separator.upperBound...])))
  }

  private static func gitHeaderTokens(_ value: String) -> [String] {
    var tokens: [String] = []
    var token = ""
    var isQuoted = false
    var isEscaped = false

    for character in value {
      if isEscaped {
        token.append(character)
        isEscaped = false
      } else if character == "\\" && isQuoted {
        token.append(character)
        isEscaped = true
      } else if character == "\"" {
        token.append(character)
        isQuoted.toggle()
      } else if character.isWhitespace && !isQuoted {
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
    let path = value.split(
      separator: "\t",
      maxSplits: 1,
      omittingEmptySubsequences: false).first
    return decodeGitPath(path.map(String.init) ?? value)
  }

  private static func normalizedPath(_ value: String) -> String {
    let decoded = decodeGitPath(value)
    if decoded.hasPrefix("a/") || decoded.hasPrefix("b/") {
      return String(decoded.dropFirst(2))
    }
    return decoded
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
        var octalValue = Int(next - 48)
        var consumed = 1
        while consumed < 3, index + consumed + 1 < bytes.count {
          let digit = bytes[index + consumed + 1]
          guard (48...55).contains(digit) else { break }
          octalValue = octalValue * 8 + Int(digit - 48)
          consumed += 1
        }
        decoded.append(UInt8(clamping: octalValue))
        index += consumed + 1
      default:
        decoded.append(next)
        index += 2
      }
    }
    return String(decoding: decoded, as: UTF8.self)
  }

  private static func normalizedLines(_ value: String) -> [String] {
    value.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }
}
