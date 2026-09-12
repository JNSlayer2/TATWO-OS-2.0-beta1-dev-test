import Foundation

public struct TatwoSlashCommandInvocation: Equatable, Sendable {
  public let command: String
  public let argument: String

  public init(command: String, argument: String) {
    self.command = command
    self.argument = argument
  }
}

public enum TatwoSlashCommandParser {
  public static func replacingPartialCommand(
    in raw: String,
    with command: String
  ) -> String {
    let replacement = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !replacement.isEmpty else { return raw }

    let lineStart = raw.lastIndex(of: "\n").map { raw.index(after: $0) } ?? raw.startIndex
    let prefix = raw[..<lineStart]
    let activeLine = raw[lineStart...]
    let leadingWhitespace = activeLine.prefix { $0.isWhitespace }
    let remainder = activeLine.dropFirst(leadingWhitespace.count)
    guard remainder.first == "/" else { return raw }

    let tokenEnd = remainder.firstIndex(where: \.isWhitespace) ?? remainder.endIndex
    let token = String(remainder[..<tokenEnd])
    guard replacement.hasPrefix(token) || token.hasPrefix(replacement) else {
      return raw
    }

    return String(prefix) + String(leadingWhitespace) + replacement + String(remainder[tokenEnd...])
  }

  /// Parses a command palette chain where every non-empty line is one slash
  /// command. Free-form multiline prompts intentionally stay out of this API.
  public static func commandLines(
    in raw: String,
    commands: [String]
  ) -> [TatwoSlashCommandInvocation] {
    let candidates = normalizedCommands(commands)
    guard !candidates.isEmpty else { return [] }

    let lines = raw.components(separatedBy: "\n")
    var result: [TatwoSlashCommandInvocation] = []
    var sawCommand = false
    var inFence = false

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        return []
      }
      guard !trimmed.isEmpty else { continue }
      guard !inFence,
            let command = candidates.first(where: { matchesPrefix($0, in: trimmed) })
      else {
        return []
      }
      sawCommand = true
      let remainder = trimmed.dropFirst(command.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      result.append(TatwoSlashCommandInvocation(
        command: command,
        argument: remainder))
    }

    return sawCommand ? result : []
  }

  public static func matchesCommand(in raw: String, commands: [String]) -> Bool {
    commandMatch(in: raw, commands: commands) != nil
  }

  public static func objective(from raw: String, commands: [String]) -> String {
    let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = commandMatch(in: input, commands: commands) else {
      return input
    }

    switch match {
    case .leading(let command):
      let remainder = input.dropFirst(command.count)
      return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    case .trailingLine(let lineIndex):
      var lines = input.components(separatedBy: "\n")
      guard lines.indices.contains(lineIndex) else { return input }
      lines.remove(at: lineIndex)
      return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private enum CommandMatch {
    case leading(String)
    case trailingLine(Int)
  }

  private static func commandMatch(in raw: String, commands: [String]) -> CommandMatch? {
    let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidates = normalizedCommands(commands)
    guard !input.isEmpty, !candidates.isEmpty else { return nil }

    if let command = candidates.first(where: { matchesPrefix($0, in: input) }) {
      return .leading(command)
    }

    let lines = input.components(separatedBy: "\n")
    var inFence = false
    var lastVisibleLineIndex: Int?
    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      guard !inFence, !trimmed.isEmpty else { continue }
      lastVisibleLineIndex = index
    }
    guard let lineIndex = lastVisibleLineIndex else { return nil }
    let lastLine = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    guard candidates.contains(lastLine) else { return nil }
    return .trailingLine(lineIndex)
  }

  private static func normalizedCommands(_ commands: [String]) -> [String] {
    commands
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
  }

  private static func matchesPrefix(_ command: String, in input: String) -> Bool {
    guard input.hasPrefix(command) else { return false }
    guard input.count > command.count else { return true }
    let boundary = input.index(input.startIndex, offsetBy: command.count)
    return input[boundary].isWhitespace || input[boundary] == "("
  }
}
