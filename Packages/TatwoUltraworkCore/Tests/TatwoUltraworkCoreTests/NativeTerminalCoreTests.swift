import XCTest

@testable import TatwoUltraworkCore

final class NativeTerminalCoreTests: XCTestCase {
  #if os(macOS)
  func testNativeTerminalLaunchDefaultsToLoginInteractiveShellWithoutNoRCS() {
    let launch = TatwoNativeTerminalLaunch(
      workingDirectory: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(launch.executable, "/bin/zsh")
    XCTAssertEqual(launch.arguments, ["-l", "-i"])
    XCTAssertFalse(launch.arguments.contains("-f"))
  }
  #endif

  func testANSIParserKeepsBasicForegroundColorSpans() {
    let line = TatwoTerminalANSIParser.parse("normal \u{001B}[31mred\u{001B}[0m tail").lines.first

    XCTAssertEqual(line?.spans.map(\.text).joined(), "normal red tail")
    XCTAssertEqual(line?.spans.first(where: { $0.text == "red" })?.foreground, .red)
    XCTAssertEqual(line?.spans.last?.foreground, .default)
  }

  func testTerminalScreenBufferCoalescesChunksAndCapsLineCount() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 3)

    buffer.append("one\ntwo")
    buffer.append(" continued\nthree\nfour\n")

    XCTAssertEqual(buffer.plainText, "two continued\nthree\nfour")
    XCTAssertEqual(buffer.lines.count, 3)
  }

  func testTerminalScreenBufferDropsANSIEscapeCodesFromPlainText() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 8)

    buffer.append("$ \u{001B}[32mpass\u{001B}[0m\n")

    XCTAssertEqual(buffer.plainText, "$ pass")
    XCTAssertEqual(buffer.lines.first?.spans.first(where: { $0.text == "pass" })?.foreground, .green)
  }

  func testTerminalScreenBufferCUPAndCursorMovementOverwriteAddressedCells() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 12, rows: 4)

    buffer.append("hello\r\nworld")
    buffer.append("\u{001B}[1;2HXY")
    buffer.append("\u{001B}[2;5H!\u{001B}[1A\u{001B}[2D?")

    XCTAssertEqual(buffer.plainText, "hXY?o\nworl!")
  }

  func testTerminalScreenBufferEraseDisplayModesClearExpectedRanges() {
    var eraseToEnd = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 8, rows: 3)
    eraseToEnd.append("abcdef\r\nghijkl")
    eraseToEnd.append("\u{001B}[1;4H\u{001B}[J")
    XCTAssertEqual(eraseToEnd.plainText, "abc")

    var eraseToStart = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 8, rows: 3)
    eraseToStart.append("abcdef\r\nghijkl")
    eraseToStart.append("\u{001B}[2;3H\u{001B}[1J")
    XCTAssertEqual(eraseToStart.plainText, "\n   jkl")

    var eraseAll = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 8, rows: 3)
    eraseAll.append("abcdef\r\nghijkl\u{001B}[2J")
    XCTAssertEqual(eraseAll.plainText, "")
  }

  func testTerminalScreenBufferEraseLineModesClearExpectedRanges() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 8, rows: 3)

    buffer.append("abcdef")
    buffer.append("\u{001B}[1;4H\u{001B}[K")
    XCTAssertEqual(buffer.plainText, "abc")

    buffer.clear()
    buffer.append("abcdef\u{001B}[1;4H\u{001B}[1K")
    XCTAssertEqual(buffer.plainText, "    ef")

    buffer.clear()
    buffer.append("abcdef\u{001B}[2K")
    XCTAssertEqual(buffer.plainText, "")
  }

  func testTerminalScreenBufferScrollRegionScrollsOnlyRegion() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 8, rows: 4)

    buffer.append("top\r\none\r\ntwo\r\nbottom")
    buffer.append("\u{001B}[2;3r\u{001B}[3;1H\r\nnext")

    XCTAssertEqual(buffer.plainText, "top\ntwo\nnext\nbottom")
  }

  func testTerminalScreenBufferAlternateScreenRestoresPrimaryContents() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 12, rows: 3)

    buffer.append("primary")
    buffer.append("\u{001B}[?1049hfullscreen")
    XCTAssertEqual(buffer.plainText, "fullscreen")

    buffer.append("\u{001B}[?1049l")
    XCTAssertEqual(buffer.plainText, "primary")
  }

  func testTerminalScreenBufferKeepsSplitCSIStateAndDropsUnknownSequences() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 12, rows: 3)

    buffer.append("abc\u{001B}[")
    buffer.append("1;2H!")
    buffer.append("\u{001B}[?25l\u{001B}]0;title\u{7}\r\ntail")
    buffer.append("\u{001B}P1;2|hidden-device-payload\u{001B}\\")

    XCTAssertEqual(buffer.plainText, "a!c\ntail")
    XCTAssertFalse(buffer.plainText.contains("[?25l"))
    XCTAssertFalse(buffer.plainText.contains("title"))
    XCTAssertFalse(buffer.plainText.contains("hidden-device-payload"))
  }

  func testTerminalScreenBufferResizePreservesVisibleContentAndBoundsCursor() {
    var buffer = TatwoTerminalScreenBuffer(maxLineCount: 8, columns: 8, rows: 3)
    buffer.append("123456\r\nsecond")

    buffer.resize(columns: 4, rows: 2)
    buffer.append("\u{001B}[99;99HX")

    XCTAssertEqual(buffer.columns, 4)
    XCTAssertEqual(buffer.rowCount, 2)
    XCTAssertEqual(buffer.plainText, "1234\nsecX")
  }

  func testTerminalInputEncoderMapsControlAndNavigationKeysToPTYBytes() {
    XCTAssertEqual(TatwoTerminalInputEncoder.bytes(for: .control("c")), [0x03])
    XCTAssertEqual(TatwoTerminalInputEncoder.bytes(for: .control("[")), [0x1B])
    XCTAssertEqual(TatwoTerminalInputEncoder.bytes(for: .special(.upArrow)), [0x1B, 0x5B, 0x41])
    XCTAssertEqual(TatwoTerminalInputEncoder.bytes(for: .special(.deleteForward)), [0x1B, 0x5B, 0x33, 0x7E])
  }

  func testTerminalInputEncoderPreservesUTF8AndSupportsOptionAsMeta() {
    XCTAssertEqual(
      TatwoTerminalInputEncoder.bytes(for: .text("刺")),
      Array("刺".utf8)
    )
    XCTAssertEqual(
      TatwoTerminalInputEncoder.bytes(for: .text("x"), optionAsMeta: true),
      [0x1B, 0x78]
    )
  }
}
