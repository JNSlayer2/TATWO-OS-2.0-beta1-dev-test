// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/NativeTerminalCore.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public enum TatwoTerminalColor: String, Codable, Sendable, Equatable, Hashable {
  case `default`
  case black
  case red
  case green
  case yellow
  case blue
  case magenta
  case cyan
  case white
  case brightBlack
  case brightRed
  case brightGreen
  case brightYellow
  case brightBlue
  case brightMagenta
  case brightCyan
  case brightWhite
}

public struct TatwoTerminalSpan: Codable, Sendable, Equatable, Hashable {
  public var text: String
  public var foreground: TatwoTerminalColor
  public var isBold: Bool

  public init(text: String, foreground: TatwoTerminalColor = .default, isBold: Bool = false) {
    self.text = text
    self.foreground = foreground
    self.isBold = isBold
  }
}

public struct TatwoTerminalLine: Codable, Sendable, Equatable, Hashable, Identifiable {
  public var id: Int
  public var spans: [TatwoTerminalSpan]

  public init(id: Int, spans: [TatwoTerminalSpan]) {
    self.id = id
    self.spans = spans
  }

  public var plainText: String {
    spans.map(\.text).joined()
  }
}

public struct TatwoTerminalParseResult: Codable, Sendable, Equatable, Hashable {
  public var lines: [TatwoTerminalLine]

  public init(lines: [TatwoTerminalLine]) {
    self.lines = lines
  }

  public var plainText: String {
    lines.map(\.plainText).joined(separator: "\n")
  }
}

public enum TatwoTerminalANSIParser {
  public static func parse(_ text: String) -> TatwoTerminalParseResult {
    var lines: [TatwoTerminalLine] = []
    var spans: [TatwoTerminalSpan] = []
    var currentText = ""
    var currentColor: TatwoTerminalColor = .default
    var isBold = false
    var index = text.startIndex

    func flushText() {
      guard !currentText.isEmpty else { return }
      if let last = spans.indices.last,
         spans[last].foreground == currentColor,
         spans[last].isBold == isBold {
        spans[last].text += currentText
      } else {
        spans.append(TatwoTerminalSpan(text: currentText, foreground: currentColor, isBold: isBold))
      }
      currentText = ""
    }

    func flushLine() {
      flushText()
      lines.append(TatwoTerminalLine(id: lines.count, spans: spans.isEmpty ? [TatwoTerminalSpan(text: "")] : spans))
      spans = []
    }

    while index < text.endIndex {
      let char = text[index]
      if char == "\n" {
        flushLine()
        index = text.index(after: index)
        continue
      }
      if char == "\u{001B}" {
        let next = text.index(after: index)
        if next < text.endIndex, text[next] == "[" {
          var commandEnd = text.index(after: next)
          while commandEnd < text.endIndex {
            let scalar = text[commandEnd]
            if scalar.isLetter { break }
            commandEnd = text.index(after: commandEnd)
          }
          if commandEnd < text.endIndex {
            let command = text[commandEnd]
            let payloadStart = text.index(after: next)
            let payload = String(text[payloadStart..<commandEnd])
            index = text.index(after: commandEnd)
            if command == "m" {
              flushText()
              applySGR(payload, color: &currentColor, isBold: &isBold)
            }
            continue
          }
        }
      }
      currentText.append(char)
      index = text.index(after: index)
    }

    flushText()
    if !spans.isEmpty || lines.isEmpty {
      lines.append(TatwoTerminalLine(id: lines.count, spans: spans.isEmpty ? [TatwoTerminalSpan(text: "")] : spans))
    }
    return TatwoTerminalParseResult(lines: lines)
  }

  private static func applySGR(_ payload: String, color: inout TatwoTerminalColor, isBold: inout Bool) {
    let codes = payload.isEmpty ? [0] : payload.split(separator: ";").compactMap { Int($0) }
    for code in codes {
      switch code {
      case 0:
        color = .default
        isBold = false
      case 1:
        isBold = true
      case 22:
        isBold = false
      case 39:
        color = .default
      case 30: color = .black
      case 31: color = .red
      case 32: color = .green
      case 33: color = .yellow
      case 34: color = .blue
      case 35: color = .magenta
      case 36: color = .cyan
      case 37: color = .white
      case 90: color = .brightBlack
      case 91: color = .brightRed
      case 92: color = .brightGreen
      case 93: color = .brightYellow
      case 94: color = .brightBlue
      case 95: color = .brightMagenta
      case 96: color = .brightCyan
      case 97: color = .brightWhite
      default:
        continue
      }
    }
  }
}

public struct TatwoTerminalScreenBuffer: Sendable, Equatable {
  public let maxLineCount: Int
  public private(set) var columns: Int
  public private(set) var rowCount: Int

  private struct Cell: Sendable, Equatable {
    var character: Character = " "
    var foreground: TatwoTerminalColor = .default
    var isBold = false
  }

  private struct Surface: Sendable, Equatable {
    var rows: [[Cell]]
    var cursorRow = 0
    var cursorColumn = 0
    var savedCursorRow = 0
    var savedCursorColumn = 0
    var scrollTop = 0
    var scrollBottom: Int

    init(columns: Int, rows: Int) {
      self.rows = Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
      self.scrollBottom = rows - 1
    }
  }

  private enum ParserState: Sendable, Equatable {
    case ground
    case escape
    case csi(String)
    case osc
    case oscEscape
    case stringControl
    case stringControlEscape
    case charset
  }

  private var primary: Surface
  private var alternate: Surface
  private var scrollback: [[Cell]] = []
  private var usesAlternateScreen = false
  private var parserState: ParserState = .ground
  private var currentForeground: TatwoTerminalColor = .default
  private var currentBold = false

  public init(maxLineCount: Int = 1_200, columns: Int = 120, rows: Int = 40) {
    self.maxLineCount = max(1, maxLineCount)
    self.columns = max(1, columns)
    self.rowCount = max(1, rows)
    self.primary = Surface(columns: self.columns, rows: self.rowCount)
    self.alternate = Surface(columns: self.columns, rows: self.rowCount)
  }

  public mutating func clear() {
    primary = Surface(columns: columns, rows: rowCount)
    alternate = Surface(columns: columns, rows: rowCount)
    scrollback = []
    usesAlternateScreen = false
    parserState = .ground
    currentForeground = .default
    currentBold = false
  }

  public mutating func resize(columns: Int, rows: Int) {
    let newColumns = max(1, columns)
    let newRows = max(1, rows)
    guard newColumns != self.columns || newRows != rowCount else { return }

    primary = resized(primary, columns: newColumns, rows: newRows)
    alternate = resized(alternate, columns: newColumns, rows: newRows)
    self.columns = newColumns
    self.rowCount = newRows
  }

  public mutating func append(_ chunk: String) {
    guard !chunk.isEmpty else { return }
    for scalar in chunk.unicodeScalars {
      let character = Character(String(scalar))
      switch parserState {
      case .ground:
        consumeGround(character)
      case .escape:
        consumeEscape(character)
      case .csi(let payload):
        consumeCSI(character, payload: payload)
      case .osc:
        if character == "\u{7}" {
          parserState = .ground
        } else if character == "\u{001B}" {
          parserState = .oscEscape
        }
      case .oscEscape:
        parserState = character == "\\" ? .ground : .osc
      case .stringControl:
        if character == "\u{7}" {
          parserState = .ground
        } else if character == "\u{001B}" {
          parserState = .stringControlEscape
        }
      case .stringControlEscape:
        parserState = character == "\\" ? .ground : .stringControl
      case .charset:
        parserState = .ground
      }
    }
  }

  public var lines: [TatwoTerminalLine] {
    displayRows.enumerated().map { offset, row in
      let lastContent = row.lastIndex(where: { $0.character != " " })
      guard let lastContent else {
        return TatwoTerminalLine(id: offset, spans: [TatwoTerminalSpan(text: "")])
      }

      var spans: [TatwoTerminalSpan] = []
      for cell in row[...lastContent] {
        let text = String(cell.character)
        if let last = spans.indices.last,
           spans[last].foreground == cell.foreground,
           spans[last].isBold == cell.isBold {
          spans[last].text += text
        } else {
          spans.append(
            TatwoTerminalSpan(
              text: text,
              foreground: cell.foreground,
              isBold: cell.isBold
            )
          )
        }
      }
      return TatwoTerminalLine(id: offset, spans: spans)
    }
  }

  public var plainText: String {
    lines.map(\.plainText).joined(separator: "\n")
  }

  private var displayRows: [[Cell]] {
    let surface = activeSurface
    let lastContentRow = surface.rows.lastIndex { row in
      row.contains { $0.character != " " }
    }
    var rows = usesAlternateScreen ? [] : scrollback
    if let lastContentRow {
      rows.append(contentsOf: surface.rows[...lastContentRow])
    }
    if rows.isEmpty {
      rows = [Array(repeating: Cell(), count: columns)]
    }
    return Array(rows.suffix(maxLineCount))
  }

  private var activeSurface: Surface {
    usesAlternateScreen ? alternate : primary
  }

  private mutating func storeActiveSurface(_ surface: Surface) {
    if usesAlternateScreen {
      alternate = surface
    } else {
      primary = surface
    }
  }

  private mutating func consumeGround(_ character: Character) {
    switch character {
    case "\u{001B}":
      parserState = .escape
    case "\n", "\u{B}", "\u{C}":
      lineFeed()
    case "\r":
      var surface = activeSurface
      surface.cursorColumn = 0
      storeActiveSurface(surface)
    case "\u{8}", "\u{7F}":
      var surface = activeSurface
      surface.cursorColumn = max(0, surface.cursorColumn - 1)
      storeActiveSurface(surface)
    case "\t":
      var surface = activeSurface
      surface.cursorColumn = min(columns - 1, ((surface.cursorColumn / 8) + 1) * 8)
      storeActiveSurface(surface)
    case "\u{0}"..."\u{1F}":
      break
    default:
      write(character)
    }
  }

  private mutating func consumeEscape(_ character: Character) {
    switch character {
    case "[":
      parserState = .csi("")
    case "]":
      parserState = .osc
    case "P", "X", "^", "_":
      parserState = .stringControl
    case "(", ")", "*", "+":
      parserState = .charset
    case "7":
      saveCursor()
      parserState = .ground
    case "8":
      restoreCursor()
      parserState = .ground
    case "D":
      lineFeed()
      parserState = .ground
    case "E":
      lineFeed()
      parserState = .ground
    case "M":
      reverseIndex()
      parserState = .ground
    case "c":
      clear()
    default:
      parserState = .ground
    }
  }

  private mutating func consumeCSI(_ character: Character, payload: String) {
    guard let scalar = character.unicodeScalars.first else {
      parserState = .ground
      return
    }
    if (0x40...0x7E).contains(scalar.value) {
      applyCSI(payload: payload, command: character)
      parserState = .ground
    } else if payload.count < 128 {
      parserState = .csi(payload + String(character))
    } else {
      parserState = .ground
    }
  }

  private mutating func applyCSI(payload: String, command: Character) {
    let isPrivate = payload.hasPrefix("?")
    let parameterText = isPrivate ? String(payload.dropFirst()) : payload
    let parameters = parameterText.split(separator: ";", omittingEmptySubsequences: false).map {
      Int($0) ?? 0
    }

    func value(_ index: Int, default defaultValue: Int) -> Int {
      guard parameters.indices.contains(index), parameters[index] != 0 else { return defaultValue }
      return parameters[index]
    }

    switch command {
    case "A":
      moveCursor(rows: -value(0, default: 1), columns: 0)
    case "B":
      moveCursor(rows: value(0, default: 1), columns: 0)
    case "C":
      moveCursor(rows: 0, columns: value(0, default: 1))
    case "D":
      moveCursor(rows: 0, columns: -value(0, default: 1))
    case "E":
      moveCursor(rows: value(0, default: 1), columns: 0)
      setCursorColumn(0)
    case "F":
      moveCursor(rows: -value(0, default: 1), columns: 0)
      setCursorColumn(0)
    case "G":
      setCursorColumn(value(0, default: 1) - 1)
    case "H", "f":
      setCursor(row: value(0, default: 1) - 1, column: value(1, default: 1) - 1)
    case "J":
      eraseDisplay(mode: parameters.first ?? 0)
    case "K":
      eraseLine(mode: parameters.first ?? 0)
    case "L":
      insertLines(value(0, default: 1))
    case "M":
      deleteLines(value(0, default: 1))
    case "P":
      deleteCharacters(value(0, default: 1))
    case "S":
      scrollUp(value(0, default: 1))
    case "T":
      scrollDown(value(0, default: 1))
    case "X":
      eraseCharacters(value(0, default: 1))
    case "@":
      insertBlankCharacters(value(0, default: 1))
    case "d":
      setCursorRow(value(0, default: 1) - 1)
    case "m":
      applySGR(parameters)
    case "r":
      setScrollRegion(
        top: value(0, default: 1) - 1,
        bottom: value(1, default: rowCount) - 1
      )
    case "s":
      saveCursor()
    case "u":
      restoreCursor()
    case "h":
      if isPrivate, parameters.contains(1049) {
        enterAlternateScreen()
      }
    case "l":
      if isPrivate, parameters.contains(1049) {
        leaveAlternateScreen()
      }
    default:
      break
    }
  }

  private mutating func write(_ character: Character) {
    var surface = activeSurface
    if surface.cursorColumn >= columns {
      surface.cursorColumn = 0
      advanceLine(in: &surface)
    }
    surface.rows[surface.cursorRow][surface.cursorColumn] = Cell(
      character: character,
      foreground: currentForeground,
      isBold: currentBold
    )
    surface.cursorColumn += 1
    storeActiveSurface(surface)
  }

  private mutating func lineFeed() {
    var surface = activeSurface
    surface.cursorColumn = 0
    advanceLine(in: &surface)
    storeActiveSurface(surface)
  }

  private mutating func advanceLine(in surface: inout Surface) {
    if surface.cursorRow == surface.scrollBottom {
      scrollRegionUp(in: &surface, count: 1)
    } else {
      surface.cursorRow = min(rowCount - 1, surface.cursorRow + 1)
    }
  }

  private mutating func reverseIndex() {
    var surface = activeSurface
    if surface.cursorRow == surface.scrollTop {
      scrollRegionDown(in: &surface, count: 1)
    } else {
      surface.cursorRow = max(0, surface.cursorRow - 1)
    }
    storeActiveSurface(surface)
  }

  private mutating func moveCursor(rows: Int, columns: Int) {
    var surface = activeSurface
    surface.cursorRow = min(rowCount - 1, max(0, surface.cursorRow + rows))
    surface.cursorColumn = min(self.columns - 1, max(0, surface.cursorColumn + columns))
    storeActiveSurface(surface)
  }

  private mutating func setCursor(row: Int, column: Int) {
    var surface = activeSurface
    surface.cursorRow = min(rowCount - 1, max(0, row))
    surface.cursorColumn = min(columns - 1, max(0, column))
    storeActiveSurface(surface)
  }

  private mutating func setCursorRow(_ row: Int) {
    var surface = activeSurface
    surface.cursorRow = min(rowCount - 1, max(0, row))
    storeActiveSurface(surface)
  }

  private mutating func setCursorColumn(_ column: Int) {
    var surface = activeSurface
    surface.cursorColumn = min(columns - 1, max(0, column))
    storeActiveSurface(surface)
  }

  private mutating func saveCursor() {
    var surface = activeSurface
    surface.savedCursorRow = surface.cursorRow
    surface.savedCursorColumn = min(columns - 1, surface.cursorColumn)
    storeActiveSurface(surface)
  }

  private mutating func restoreCursor() {
    var surface = activeSurface
    surface.cursorRow = min(rowCount - 1, max(0, surface.savedCursorRow))
    surface.cursorColumn = min(columns - 1, max(0, surface.savedCursorColumn))
    storeActiveSurface(surface)
  }

  private mutating func eraseDisplay(mode: Int) {
    var surface = activeSurface
    switch mode {
    case 1:
      if surface.cursorRow > 0 {
        for row in 0..<surface.cursorRow {
          surface.rows[row] = blankRow()
        }
      }
      eraseCells(in: &surface.rows[surface.cursorRow], range: 0...surface.cursorColumn)
    case 2, 3:
      surface.rows = Array(repeating: blankRow(), count: rowCount)
      if mode == 3, !usesAlternateScreen {
        scrollback = []
      }
    default:
      eraseCells(
        in: &surface.rows[surface.cursorRow],
        range: surface.cursorColumn...(columns - 1)
      )
      if surface.cursorRow + 1 < rowCount {
        for row in (surface.cursorRow + 1)..<rowCount {
          surface.rows[row] = blankRow()
        }
      }
    }
    storeActiveSurface(surface)
  }

  private mutating func eraseLine(mode: Int) {
    var surface = activeSurface
    switch mode {
    case 1:
      eraseCells(in: &surface.rows[surface.cursorRow], range: 0...surface.cursorColumn)
    case 2:
      surface.rows[surface.cursorRow] = blankRow()
    default:
      eraseCells(
        in: &surface.rows[surface.cursorRow],
        range: surface.cursorColumn...(columns - 1)
      )
    }
    storeActiveSurface(surface)
  }

  private func eraseCells(in row: inout [Cell], range: ClosedRange<Int>) {
    let lower = max(0, range.lowerBound)
    let upper = min(columns - 1, range.upperBound)
    guard lower <= upper else { return }
    for index in lower...upper {
      row[index] = Cell()
    }
  }

  private mutating func eraseCharacters(_ count: Int) {
    var surface = activeSurface
    let upper = min(columns - 1, surface.cursorColumn + max(1, count) - 1)
    eraseCells(in: &surface.rows[surface.cursorRow], range: surface.cursorColumn...upper)
    storeActiveSurface(surface)
  }

  private mutating func insertBlankCharacters(_ count: Int) {
    var surface = activeSurface
    let row = surface.cursorRow
    let column = min(columns - 1, surface.cursorColumn)
    let amount = min(max(1, count), columns - column)
    surface.rows[row].insert(contentsOf: Array(repeating: Cell(), count: amount), at: column)
    surface.rows[row] = Array(surface.rows[row].prefix(columns))
    storeActiveSurface(surface)
  }

  private mutating func deleteCharacters(_ count: Int) {
    var surface = activeSurface
    let row = surface.cursorRow
    let column = min(columns - 1, surface.cursorColumn)
    let amount = min(max(1, count), columns - column)
    surface.rows[row].removeSubrange(column..<(column + amount))
    surface.rows[row].append(contentsOf: Array(repeating: Cell(), count: amount))
    storeActiveSurface(surface)
  }

  private mutating func insertLines(_ count: Int) {
    var surface = activeSurface
    guard (surface.scrollTop...surface.scrollBottom).contains(surface.cursorRow) else { return }
    let amount = min(max(1, count), surface.scrollBottom - surface.cursorRow + 1)
    for _ in 0..<amount {
      surface.rows.insert(blankRow(), at: surface.cursorRow)
      surface.rows.remove(at: surface.scrollBottom + 1)
    }
    storeActiveSurface(surface)
  }

  private mutating func deleteLines(_ count: Int) {
    var surface = activeSurface
    guard (surface.scrollTop...surface.scrollBottom).contains(surface.cursorRow) else { return }
    let amount = min(max(1, count), surface.scrollBottom - surface.cursorRow + 1)
    for _ in 0..<amount {
      surface.rows.remove(at: surface.cursorRow)
      surface.rows.insert(blankRow(), at: surface.scrollBottom)
    }
    storeActiveSurface(surface)
  }

  private mutating func setScrollRegion(top: Int, bottom: Int) {
    var surface = activeSurface
    if top >= 0, bottom < rowCount, top < bottom {
      surface.scrollTop = top
      surface.scrollBottom = bottom
    } else {
      surface.scrollTop = 0
      surface.scrollBottom = rowCount - 1
    }
    surface.cursorRow = 0
    surface.cursorColumn = 0
    storeActiveSurface(surface)
  }

  private mutating func scrollUp(_ count: Int) {
    var surface = activeSurface
    scrollRegionUp(in: &surface, count: count)
    storeActiveSurface(surface)
  }

  private mutating func scrollDown(_ count: Int) {
    var surface = activeSurface
    scrollRegionDown(in: &surface, count: count)
    storeActiveSurface(surface)
  }

  private mutating func scrollRegionUp(in surface: inout Surface, count: Int) {
    let amount = min(max(1, count), surface.scrollBottom - surface.scrollTop + 1)
    for _ in 0..<amount {
      let removed = surface.rows.remove(at: surface.scrollTop)
      surface.rows.insert(blankRow(), at: surface.scrollBottom)
      if !usesAlternateScreen,
         surface.scrollTop == 0,
         surface.scrollBottom == rowCount - 1 {
        scrollback.append(removed)
        if scrollback.count > maxLineCount {
          scrollback = Array(scrollback.suffix(maxLineCount))
        }
      }
    }
  }

  private func scrollRegionDown(in surface: inout Surface, count: Int) {
    let amount = min(max(1, count), surface.scrollBottom - surface.scrollTop + 1)
    for _ in 0..<amount {
      surface.rows.remove(at: surface.scrollBottom)
      surface.rows.insert(blankRow(), at: surface.scrollTop)
    }
  }

  private mutating func enterAlternateScreen() {
    guard !usesAlternateScreen else { return }
    usesAlternateScreen = true
    alternate = Surface(columns: columns, rows: rowCount)
  }

  private mutating func leaveAlternateScreen() {
    guard usesAlternateScreen else { return }
    usesAlternateScreen = false
  }

  private mutating func applySGR(_ parameters: [Int]) {
    let codes = parameters.isEmpty ? [0] : parameters
    var index = 0
    while index < codes.count {
      let code = codes[index]
      switch code {
      case 0:
        currentForeground = .default
        currentBold = false
      case 1:
        currentBold = true
      case 22:
        currentBold = false
      case 30: currentForeground = .black
      case 31: currentForeground = .red
      case 32: currentForeground = .green
      case 33: currentForeground = .yellow
      case 34: currentForeground = .blue
      case 35: currentForeground = .magenta
      case 36: currentForeground = .cyan
      case 37: currentForeground = .white
      case 39: currentForeground = .default
      case 90: currentForeground = .brightBlack
      case 91: currentForeground = .brightRed
      case 92: currentForeground = .brightGreen
      case 93: currentForeground = .brightYellow
      case 94: currentForeground = .brightBlue
      case 95: currentForeground = .brightMagenta
      case 96: currentForeground = .brightCyan
      case 97: currentForeground = .brightWhite
      case 38:
        if index + 2 < codes.count, codes[index + 1] == 5 {
          currentForeground = indexedColor(codes[index + 2])
          index += 2
        } else if index + 4 < codes.count, codes[index + 1] == 2 {
          index += 4
        }
      case 48:
        if index + 2 < codes.count, codes[index + 1] == 5 {
          index += 2
        } else if index + 4 < codes.count, codes[index + 1] == 2 {
          index += 4
        }
      default:
        break
      }
      index += 1
    }
  }

  private func indexedColor(_ value: Int) -> TatwoTerminalColor {
    switch value {
    case 0: return .black
    case 1: return .red
    case 2: return .green
    case 3: return .yellow
    case 4: return .blue
    case 5: return .magenta
    case 6: return .cyan
    case 7: return .white
    case 8: return .brightBlack
    case 9: return .brightRed
    case 10: return .brightGreen
    case 11: return .brightYellow
    case 12: return .brightBlue
    case 13: return .brightMagenta
    case 14: return .brightCyan
    case 15: return .brightWhite
    default: return .default
    }
  }

  private func resized(_ surface: Surface, columns: Int, rows: Int) -> Surface {
    var resized = Surface(columns: columns, rows: rows)
    let copiedRows = min(rows, surface.rows.count)
    let copiedColumns = min(columns, self.columns)
    if copiedRows > 0, copiedColumns > 0 {
      for row in 0..<copiedRows {
        for column in 0..<copiedColumns {
          resized.rows[row][column] = surface.rows[row][column]
        }
      }
    }
    resized.cursorRow = min(rows - 1, surface.cursorRow)
    resized.cursorColumn = min(columns - 1, surface.cursorColumn)
    resized.savedCursorRow = min(rows - 1, surface.savedCursorRow)
    resized.savedCursorColumn = min(columns - 1, surface.savedCursorColumn)
    resized.scrollTop = min(rows - 1, surface.scrollTop)
    resized.scrollBottom = min(rows - 1, max(resized.scrollTop, surface.scrollBottom))
    if resized.scrollTop >= resized.scrollBottom {
      resized.scrollTop = 0
      resized.scrollBottom = rows - 1
    }
    return resized
  }

  private func blankRow() -> [Cell] {
    Array(repeating: Cell(), count: columns)
  }
}

#if os(macOS)
public struct TatwoNativeTerminalLaunch: Sendable, Equatable {
  public var executable: String
  public var arguments: [String]
  public var workingDirectory: URL
  public var environment: [String: String]

  public init(
    executable: String = "/bin/zsh",
    // Login + interactive: source user profile (.zprofile/.zshrc) so PATH includes
    // Homebrew/local bins (claude/node/brew). Do not use -f (NO_RCS); that strips PATH.
    arguments: [String] = ["-l", "-i"],
    workingDirectory: URL,
    environment: [String: String] = [:]
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public enum TatwoNativeTerminalStatus: Sendable, Equatable {
  case idle
  case starting
  case running(pid: Int32)
  case exited(Int32)
  case failed(String)

  public var displayText: String {
    switch self {
    case .idle:
      return "idle"
    case .starting:
      return "starting"
    case .running(let pid):
      return "running pid=\(pid)"
    case .exited(let status):
      return "exited \(status)"
    case .failed(let message):
      return "failed \(message)"
    }
  }
}

public final class TatwoNativeTerminalSession: @unchecked Sendable {
  private let launch: TatwoNativeTerminalLaunch
  private let onUpdate: @Sendable ([TatwoTerminalLine]) -> Void
  private let onStatus: @Sendable (TatwoNativeTerminalStatus) -> Void
  private let queue = DispatchQueue(label: "tatwo.native-terminal.session", qos: .userInitiated)
  private let lock = NSLock()
  private let throttleNanoseconds: UInt64
  private var process: Process?
  private var inputPipe: Pipe?
  private var screenBuffer: TatwoTerminalScreenBuffer
  private var flushScheduled = false

  public init(
    launch: TatwoNativeTerminalLaunch,
    maxLineCount: Int = 1_200,
    throttleInterval: TimeInterval = 0.05,
    onUpdate: @escaping @Sendable ([TatwoTerminalLine]) -> Void,
    onStatus: @escaping @Sendable (TatwoNativeTerminalStatus) -> Void
  ) {
    self.launch = launch
    self.onUpdate = onUpdate
    self.onStatus = onStatus
    self.throttleNanoseconds = UInt64(max(0.016, throttleInterval) * 1_000_000_000)
    self.screenBuffer = TatwoTerminalScreenBuffer(maxLineCount: maxLineCount)
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return process?.isRunning == true
  }

  public func start(seedText: String? = nil) {
    terminate()
    queue.async { [weak self] in
      self?.startOnQueue(seedText: seedText)
    }
  }

  public func sendLine(_ text: String, echo: Bool = true) {
    let line = text.hasSuffix("\n") ? text : text + "\n"
    if echo {
      appendOutput("\u{001B}[90m$ \(text)\u{001B}[0m\n")
    }
    queue.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let handle = self.inputPipe?.fileHandleForWriting
      self.lock.unlock()
      do {
        try handle?.write(contentsOf: Data(line.utf8))
      } catch {
        self.appendOutput("\u{001B}[31mstdin write failed: \(error.localizedDescription)\u{001B}[0m\n")
        self.emitStatus(.failed(error.localizedDescription))
      }
    }
  }

  public func terminate() {
    lock.lock()
    let proc = process
    let input = inputPipe
    process = nil
    inputPipe = nil
    lock.unlock()

    proc?.standardOutput = nil
    proc?.standardError = nil
    try? input?.fileHandleForWriting.close()
    if proc?.isRunning == true {
      proc?.terminate()
    }
  }

  private func startOnQueue(seedText: String?) {
    emitStatus(.starting)
    screenBuffer.clear()
    if let seedText, !seedText.isEmpty {
      appendOutput(seedText)
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: launch.executable)
    process.arguments = launch.arguments
    process.currentDirectoryURL = launch.workingDirectory

    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = environment["TERM"] ?? "xterm-256color"
    environment["CLICOLOR"] = environment["CLICOLOR"] ?? "1"
    environment["PS1"] = environment["PS1"] ?? "%F{cyan}tatwo%f %1~ %# "
    for (key, value) in launch.environment {
      environment[key] = value
    }
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    let consume: @Sendable (Data) -> Void = { [weak self] data in
      guard let self, !data.isEmpty else { return }
      self.appendOutput(String(decoding: data, as: UTF8.self))
    }
    output.fileHandleForReading.readabilityHandler = { handle in
      consume(handle.availableData)
    }
    error.fileHandleForReading.readabilityHandler = { handle in
      consume(handle.availableData)
    }
    process.terminationHandler = { [weak self] proc in
      output.fileHandleForReading.readabilityHandler = nil
      error.fileHandleForReading.readabilityHandler = nil
      self?.appendOutput("\n\u{001B}[90m[process exited \(proc.terminationStatus)]\u{001B}[0m\n")
      self?.emitStatus(.exited(proc.terminationStatus))
    }

    do {
      lock.lock()
      self.process = process
      self.inputPipe = input
      lock.unlock()
      try process.run()
      emitStatus(.running(pid: process.processIdentifier))
    } catch {
      lock.lock()
      if self.process === process {
        self.process = nil
        self.inputPipe = nil
      }
      lock.unlock()
      appendOutput("\u{001B}[31mterminal launch failed: \(error.localizedDescription)\u{001B}[0m\n")
      emitStatus(.failed(error.localizedDescription))
    }
  }

  private func appendOutput(_ text: String) {
    queue.async { [weak self] in
      guard let self else { return }
      self.screenBuffer.append(text)
      self.scheduleFlushOnQueue()
    }
  }

  private func scheduleFlushOnQueue() {
    guard !flushScheduled else { return }
    flushScheduled = true
    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(throttleNanoseconds))) { [weak self] in
      guard let self else { return }
      self.flushScheduled = false
      let lines = self.screenBuffer.lines
      DispatchQueue.main.async {
        self.onUpdate(lines)
      }
    }
  }

  private func emitStatus(_ status: TatwoNativeTerminalStatus) {
    DispatchQueue.main.async {
      self.onStatus(status)
    }
  }

  deinit {
    terminate()
  }
}
#endif
