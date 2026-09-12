import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class CLICommandHistoryTests: XCTestCase {
  private let sessionA = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
  private let sessionB = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!

  func testRecordKeepsSessionsIsolatedAndStoresSafeCommand() {
    var book = TatwoCLICommandHistoryBook()

    XCTAssertEqual(
      book.record(
        command: "swift test",
        sessionID: sessionA,
        engine: .codex,
        entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
        executedAt: Date(timeIntervalSince1970: 100),
        workdirToken: "repo"),
      .stored)
    XCTAssertEqual(
      book.record(
        command: "git status",
        sessionID: sessionB,
        engine: .claude,
        entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
        executedAt: Date(timeIntervalSince1970: 200)),
      .stored)

    XCTAssertEqual(book.entries(for: sessionA).map(\.command), ["swift test"])
    XCTAssertEqual(book.entries(for: sessionB).map(\.command), ["git status"])
    XCTAssertEqual(book.entries(for: sessionA).first?.workdirToken, "repo")
  }

  func testAdjacentDuplicateUpdatesTimestampWithoutGrowingHistory() {
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000121")!
    var book = TatwoCLICommandHistoryBook()

    _ = book.record(
      command: "swift test",
      sessionID: sessionA,
      engine: .codex,
      entryID: firstID,
      executedAt: Date(timeIntervalSince1970: 100))
    _ = book.record(
      command: "  swift test  ",
      sessionID: sessionA,
      engine: .codex,
      entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000122")!,
      executedAt: Date(timeIntervalSince1970: 300),
      workdirToken: "updated")

    let entry = book.entries(for: sessionA).first
    XCTAssertEqual(book.entries(for: sessionA).count, 1)
    XCTAssertEqual(entry?.id, firstID)
    XCTAssertEqual(entry?.command, "swift test")
    XCTAssertEqual(entry?.executedAt, Date(timeIntervalSince1970: 300))
    XCTAssertEqual(entry?.workdirToken, "updated")
  }

  func testNonAdjacentDuplicateRemainsASeparateRecallPoint() {
    var book = TatwoCLICommandHistoryBook()
    for (offset, command) in ["one", "two", "one"].enumerated() {
      _ = book.record(
        command: command,
        sessionID: sessionA,
        engine: .generic,
        entryID: UUID(),
        executedAt: Date(timeIntervalSince1970: TimeInterval(offset)))
    }

    XCTAssertEqual(book.recallableCommands(for: sessionA), ["one", "two", "one"])
  }

  func testPerSessionLimitDropsOldestEntriesAndZeroLimitIsSafe() {
    var limited = TatwoCLICommandHistoryBook(perSessionLimit: 2)
    for (offset, command) in ["one", "two", "three"].enumerated() {
      _ = limited.record(
        command: command,
        sessionID: sessionA,
        engine: .generic,
        entryID: UUID(),
        executedAt: Date(timeIntervalSince1970: TimeInterval(offset)))
    }

    var disabled = TatwoCLICommandHistoryBook(perSessionLimit: 0)
    let decision = disabled.record(
      command: "not retained",
      sessionID: sessionA,
      engine: .generic,
      entryID: UUID(),
      executedAt: .distantPast)

    XCTAssertEqual(limited.recallableCommands(for: sessionA), ["two", "three"])
    XCTAssertEqual(decision, .stored)
    XCTAssertTrue(disabled.entries(for: sessionA).isEmpty)
  }

  func testSensitivityPolicyRedactsCommonSecretShapesBeforeStorage() {
    let sensitiveCommands = [
      "curl -H 'Authorization: Bearer abc123' https://example.test",
      "deploy --token abc123",
      "deploy --password=abc123",
      "PASSWORD=abc123 deploy",
      "SECRET_KEY=abc123 deploy",
      "psql -p abc123"
    ]

    for (offset, command) in sensitiveCommands.enumerated() {
      var book = TatwoCLICommandHistoryBook()
      XCTAssertEqual(
        book.record(
          command: command,
          sessionID: sessionA,
          engine: .generic,
          entryID: UUID(),
          executedAt: Date(timeIntervalSince1970: TimeInterval(offset))),
        .redacted,
        command)

      let entry = book.entries(for: sessionA).first
      XCTAssertNil(entry?.command, command)
      XCTAssertEqual(entry?.displayPreview, "敏感命令未保存", command)
      XCTAssertEqual(entry?.storageDecision, .redacted, command)
    }
  }

  func testPrivateKeyAndBlankCommandsAreExcludedEntirely() {
    var book = TatwoCLICommandHistoryBook()

    let privateKeyDecision = book.record(
      command: "-----BEGIN OPENSSH PRIVATE KEY-----\nraw-secret",
      sessionID: sessionA,
      engine: .generic,
      entryID: UUID(),
      executedAt: .distantPast)
    let blankDecision = book.record(
      command: " \n\t ",
      sessionID: sessionA,
      engine: .generic,
      entryID: UUID(),
      executedAt: .distantFuture)

    XCTAssertEqual(privateKeyDecision, .excluded)
    XCTAssertEqual(blankDecision, .excluded)
    XCTAssertTrue(book.entries(for: sessionA).isEmpty)
  }

  func testEntryInitializerNeverRetainsRawTextForRedactedDecision() {
    let entry = TatwoCLICommandHistoryEntry(
      id: UUID(),
      sessionID: sessionA,
      engine: .codex,
      command: "should-not-survive",
      displayPreview: "safe preview",
      executedAt: .distantPast,
      workdirToken: nil,
      storageDecision: .redacted)

    XCTAssertNil(entry.command)
    XCTAssertEqual(entry.displayPreview, "safe preview")
  }

  func testEntryDecodeNeverRetainsRawTextForRedactedDecision() throws {
    let json = """
    {
      "id": "00000000-0000-0000-0000-000000000141",
      "sessionID": "00000000-0000-0000-0000-000000000101",
      "engine": "codex",
      "command": "should-not-survive",
      "displayPreview": "敏感命令未保存",
      "executedAt": -978307100,
      "storageDecision": "redacted"
    }
    """

    let entry = try JSONDecoder().decode(
      TatwoCLICommandHistoryEntry.self,
      from: Data(json.utf8))

    XCTAssertNil(entry.command)
    XCTAssertEqual(entry.storageDecision, .redacted)
  }

  func testNavigationMovesOlderNewerAndRestoresDraftAtBoundaries() {
    var book = TatwoCLICommandHistoryBook()
    for command in ["one", "two"] {
      _ = book.record(
        command: command,
        sessionID: sessionA,
        engine: .generic,
        entryID: UUID(),
        executedAt: .distantPast)
    }
    _ = book.record(
      command: "deploy --token secret",
      sessionID: sessionA,
      engine: .generic,
      entryID: UUID(),
      executedAt: .distantFuture)

    var result = TatwoCLIHistoryNavigator.navigate(
      .up,
      state: TatwoCLIHistoryNavigationState(draft: "draft"),
      commands: book.recallableCommands(for: sessionA))
    XCTAssertEqual(result.value, "two")

    result = TatwoCLIHistoryNavigator.navigate(
      .up,
      state: result.state,
      commands: book.recallableCommands(for: sessionA))
    XCTAssertEqual(result.value, "one")

    result = TatwoCLIHistoryNavigator.navigate(
      .up,
      state: result.state,
      commands: book.recallableCommands(for: sessionA))
    XCTAssertEqual(result.value, "one")

    result = TatwoCLIHistoryNavigator.navigate(
      .down,
      state: result.state,
      commands: book.recallableCommands(for: sessionA))
    XCTAssertEqual(result.value, "two")

    result = TatwoCLIHistoryNavigator.navigate(
      .down,
      state: result.state,
      commands: book.recallableCommands(for: sessionA))
    XCTAssertEqual(result.value, "draft")
    XCTAssertNil(result.state.cursor)

    result = TatwoCLIHistoryNavigator.navigate(
      .escape,
      state: TatwoCLIHistoryNavigationState(draft: "draft", cursor: 0),
      commands: book.recallableCommands(for: sessionA))
    XCTAssertEqual(result.value, "draft")
    XCTAssertNil(result.state.cursor)
  }

  func testEmptyNavigationReturnsDraftWithoutCrashing() {
    let state = TatwoCLIHistoryNavigationState(draft: "draft")
    let result = TatwoCLIHistoryNavigator.navigate(.up, state: state, commands: [])

    XCTAssertEqual(result.state, state)
    XCTAssertEqual(result.value, "draft")
  }

  func testCodableRoundTripAndLegacyMissingFieldsAreSafe() throws {
    var book = TatwoCLICommandHistoryBook(perSessionLimit: 5)
    _ = book.record(
      command: "swift build",
      sessionID: sessionA,
      engine: .codex,
      entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000131")!,
      executedAt: Date(timeIntervalSince1970: 100))

    let roundTrip = try JSONDecoder().decode(
      TatwoCLICommandHistoryBook.self,
      from: JSONEncoder().encode(book))
    let legacy = try JSONDecoder().decode(
      TatwoCLICommandHistoryBook.self,
      from: Data("{}".utf8))

    XCTAssertEqual(roundTrip, book)
    XCTAssertTrue(legacy.entriesBySession.isEmpty)
    XCTAssertEqual(legacy.perSessionLimit, 200)
  }

  func testMalformedLegacyEntriesFieldDegradesToEmptyBook() throws {
    let malformed = try JSONDecoder().decode(
      TatwoCLICommandHistoryBook.self,
      from: Data(#"{"entriesBySession":"legacy"}"#.utf8))

    XCTAssertTrue(malformed.entriesBySession.isEmpty)
    XCTAssertEqual(malformed.perSessionLimit, 200)
  }
}
