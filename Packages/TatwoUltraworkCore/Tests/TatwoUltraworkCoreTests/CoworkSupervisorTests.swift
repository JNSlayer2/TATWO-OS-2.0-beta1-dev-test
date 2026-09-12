import XCTest
@testable import TatwoUltraworkCore

final class CoworkSupervisorTests: XCTestCase {
  func testTemplateFactoryReadsNativeDevelopmentXXLScenariosBeforeLegacyExactAndTenNamedScenarios() throws {
    let templates = TatwoCoworkTemplateFactory.templates(from: TatwoScenarioConfigDefaults.book)

    XCTAssertEqual(templates.count, 14)
    XCTAssertEqual(
      templates.map(\.scenarioID),
      TatwoScenarioConfigDefaults.round13SeedScenarios.map(\.id))
    XCTAssertEqual(templates.filter { $0.category == "通用" }.count, 10)
    XCTAssertEqual(templates.filter { $0.category == "UI UX" }.count, 4)
    XCTAssertEqual(
      templates.first?.displayName,
      TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioName)
    XCTAssertEqual(
      templates.dropFirst().first?.displayName,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioName)
    XCTAssertEqual(
      templates.dropFirst(2).first?.displayName,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLFableGrokScenarioName)
    XCTAssertEqual(
      templates.dropFirst(3).first?.displayName,
      TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioName)
    XCTAssertEqual(
      templates.dropFirst(4).first?.displayName,
      "通用 · XXL · fable5+sol主導")
    XCTAssertEqual(templates.last?.displayName, "UI UX · S · 2方向輕評")
  }

  func testTemplateContextIncludesModeScenarioAndIdentityBindings() throws {
    let template = try XCTUnwrap(TatwoCoworkTemplateFactory.templates(from: TatwoScenarioConfigDefaults.book).first)
    let ticket = template.prefixedTicket(userText: "修 UI chat pane")

    XCTAssertTrue(ticket.contains("[TATWO Ultrawork 情境模板]"))
    XCTAssertTrue(
      ticket.contains(
        "scenarioID=\(TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)"))
    XCTAssertTrue(ticket.contains("mode=XXL"))
    XCTAssertTrue(ticket.contains("Plan/Loops/Goal 身份組"))
    XCTAssertTrue(ticket.contains("主導: gpt-5.6-sol"))
    XCTAssertTrue(ticket.contains("副審: opus-5"))
    XCTAssertTrue(ticket.contains("sub: gpt-5.6-luna"))
    XCTAssertTrue(ticket.contains("sub: grok-build"))
    XCTAssertFalse(ticket.contains("fable-5"))
    XCTAssertTrue(ticket.hasSuffix("修 UI chat pane"))
  }

  func testTemplateFactoryRestoresMissingNewExactXXLBeforeLegacyExactAndXXL() throws {
    var staleBook = TatwoScenarioConfigDefaults.book
    staleBook.scenarios.removeAll {
      $0.id == TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID
    }

    let templates = TatwoCoworkTemplateFactory.templates(from: staleBook)

    XCTAssertEqual(
      templates.first?.scenarioID,
      TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
    XCTAssertEqual(
      templates.dropFirst().first?.scenarioID,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID)
    XCTAssertEqual(
      templates.dropFirst(2).first?.scenarioID,
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLFableGrokScenarioID)
    XCTAssertEqual(
      templates.dropFirst(3).first?.scenarioID,
      TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID)
    XCTAssertEqual(
      templates.dropFirst(4).first?.scenarioID,
      "general-xxl-fable5-sol")
  }

  func testTemplateFactoryExcludesNoncanonicalCustomScenario() throws {
    var book = TatwoScenarioConfigDefaults.book
    book.scenarios.append(
      TatwoCustomScenarioConfig(
        id: "custom-noncanonical",
        displayName: "通用 · XXL · custom",
        baseScenario: .coding,
        builtin: false,
        modeConfigs: TatwoScenarioConfigDefaults.defaultDailyModeConfigs))

    XCTAssertEqual(
      TatwoCoworkTemplateFactory.templates(from: book).map(\.scenarioID),
      TatwoScenarioConfigDefaults.round13SeedScenarios.map(\.id))
  }

  func testProgressInspectorEmitsStartupProgressAndStallCardsFromTrueStats() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let startup = TatwoCoworkProgressInspector.card(
      phase: .startup,
      stats: TatwoCoworkRunStats(logByteCount: 128, changedFiles: ["Apps/ChatPage.swift"], receiptFiles: [], measuredAt: start),
      previousGrowthStats: nil,
      runStartedAt: start,
      allowedRelativeRoots: ["Apps", "Packages"])

    XCTAssertEqual(startup.severity, .ok)
    XCTAssertTrue(startup.body.contains("log=128 B"))
    XCTAssertTrue(startup.body.contains("改檔=1"))
    XCTAssertTrue(startup.body.contains("範圍=OK"))

    let stalled = TatwoCoworkProgressInspector.card(
      phase: .patrol,
      stats: TatwoCoworkRunStats(logByteCount: 128, changedFiles: ["Apps/ChatPage.swift"], receiptFiles: [], measuredAt: start.addingTimeInterval(601)),
      previousGrowthStats: startup.stats,
      runStartedAt: start,
      allowedRelativeRoots: ["Apps", "Packages"])

    XCTAssertEqual(stalled.severity, .danger)
    XCTAssertTrue(stalled.title.contains("卡死警報"))
    XCTAssertTrue(stalled.body.contains("10分鐘零成長"))
  }

  func testGitPorcelainParserReturnsChangedPathsWithoutStatusNoise() throws {
    let output = " M Apps/TatwoUltraworkMac/Sources/ChatPage.swift\n?? docs/plans/receipts/round16-receipt.md\nR  old.swift -> Packages/New.swift\n"

    XCTAssertEqual(
      TatwoCoworkGitStatusParser.changedPaths(fromPorcelain: output),
      [
        "Apps/TatwoUltraworkMac/Sources/ChatPage.swift",
        "docs/plans/receipts/round16-receipt.md",
        "Packages/New.swift",
      ])
  }
}
