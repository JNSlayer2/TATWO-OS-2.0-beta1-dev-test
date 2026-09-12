import XCTest

@testable import TatwoUltraworkCore

final class SlashCommandParserTests: XCTestCase {
  func testObjectiveRemovesOnlyTheLeadingCommand() {
    XCTAssertEqual(
      TatwoSlashCommandParser.objective(
        from: "/goal 修復文件中的 /plg 說明",
        commands: ["/goal"]),
      "修復文件中的 /plg 說明"
    )
  }

  func testObjectivePrefersTheLongestMatchingPLGPrefix() {
    XCTAssertEqual(
      TatwoSlashCommandParser.objective(
        from: "/plg(plan loops goal) 修復 /goal 與 /plg",
        commands: ["/plg", "/plan", "/plg(plan loops goal)"]),
      "修復 /goal 與 /plg"
    )
  }

  func testObjectiveDoesNotStripCommandTextFromANonCommandPrompt() {
    XCTAssertEqual(
      TatwoSlashCommandParser.objective(
        from: "文件提到 /goal 但不是指令",
        commands: ["/goal"]),
      "文件提到 /goal 但不是指令"
    )
  }

  func testObjectiveDoesNotTrimClosingParenthesisFromContent() {
    XCTAssertEqual(
      TatwoSlashCommandParser.objective(
        from: "/goal 修復 function(foo)",
        commands: ["/goal"]),
      "修復 function(foo)"
    )
  }

  func testTrailingStandalonePLGLineUsesTheBodyAsObjective() {
    let input = """
      修好 Fable5 斷線並驗證長上下文。
      保留正文中的 function(foo)。

      /plg
      """

    XCTAssertTrue(
      TatwoSlashCommandParser.matchesCommand(in: input, commands: ["/plg"]))
    XCTAssertEqual(
      TatwoSlashCommandParser.objective(from: input, commands: ["/plg"]),
      """
      修好 Fable5 斷線並驗證長上下文。
      保留正文中的 function(foo)。
      """
    )
  }

  func testInlineAndCodeBlockPLGTextDoNotTrigger() {
    XCTAssertFalse(
      TatwoSlashCommandParser.matchesCommand(
        in: "請保留這段文字：/plg 這不是命令。",
        commands: ["/plg"]))
    XCTAssertFalse(
      TatwoSlashCommandParser.matchesCommand(
        in: """
        ```text
        /plg
        ```
        """,
        commands: ["/plg"]))
  }

  func testSlashMenuSelectionReplacesPartialCommandBeforeExecution() {
    XCTAssertEqual(
      TatwoSlashCommandParser.replacingPartialCommand(in: "/", with: "/plg"),
      "/plg")
    XCTAssertEqual(
      TatwoSlashCommandParser.replacingPartialCommand(in: "/pl", with: "/plg"),
      "/plg")
  }

  func testCommandLinesAcceptsMultipleIndependentCommands() {
    XCTAssertEqual(
      TatwoSlashCommandParser.commandLines(
        in: """
        /issue 修正輸入框
        /issue 補圖片備註
        """,
        commands: ["/issue", "/plan"]),
      [
        TatwoSlashCommandInvocation(command: "/issue", argument: "修正輸入框"),
        TatwoSlashCommandInvocation(command: "/issue", argument: "補圖片備註"),
      ])
  }

  func testCommandLinesRejectsFreeFormTextAndCodeFences() {
    XCTAssertTrue(
      TatwoSlashCommandParser.commandLines(
        in: "/issue 保留這行\n這不是命令",
        commands: ["/issue"]).isEmpty)
    XCTAssertTrue(
      TatwoSlashCommandParser.commandLines(
        in: "```text\n/issue 不應執行\n```",
        commands: ["/issue"]).isEmpty)
  }

  func testSlashMenuReplacementTargetsTheLastCommandLine() {
    XCTAssertEqual(
      TatwoSlashCommandParser.replacingPartialCommand(
        in: "/issue 第一件\n/pl",
        with: "/plan"),
      "/issue 第一件\n/plan")
  }
}
