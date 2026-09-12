import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class NativeCLISessionBookTests: XCTestCase {
  func testOpenAppendsSessionsInOrderAndSelectsNewestSession() throws {
    let firstDate = Date(timeIntervalSince1970: 100)
    let secondDate = Date(timeIntervalSince1970: 200)
    var book = TatwoNativeCLISessionBook()

    let codexID = book.open(
      engine: .codex,
      title: "Codex work",
      workdir: "/tmp/codex",
      at: firstDate)
    let claudeID = book.open(
      engine: .claude,
      title: "Claude review",
      workdir: nil,
      at: secondDate)

    XCTAssertEqual(book.sessions.map(\.id), [codexID, claudeID])
    XCTAssertEqual(book.sessions.map(\.engine), [.codex, .claude])
    XCTAssertEqual(book.sessions.map(\.title), ["Codex work", "Claude review"])
    XCTAssertEqual(book.sessions.map(\.workdir), ["/tmp/codex", nil])
    XCTAssertEqual(book.sessions.map(\.createdAt), [firstDate, secondDate])
    XCTAssertEqual(book.sessions.map(\.updatedAt), [firstDate, secondDate])
    XCTAssertTrue(book.sessions.allSatisfy(\.isRunning))
    XCTAssertEqual(book.activeSessionID, claudeID)
    XCTAssertEqual(book.activeSession?.id, claudeID)
  }

  func testSelectChangesActiveSessionOnlyForKnownID() throws {
    var book = TatwoNativeCLISessionBook()
    let codexID = book.open(engine: .codex, title: "Codex", workdir: nil)
    let grokID = book.open(engine: .grok, title: "Grok", workdir: nil)

    XCTAssertTrue(book.select(codexID))
    XCTAssertEqual(book.activeSessionID, codexID)

    XCTAssertFalse(book.select(UUID()))
    XCTAssertEqual(book.activeSessionID, codexID)
    XCTAssertEqual(book.sessions.map(\.id), [codexID, grokID])
  }

  func testClosingActiveMiddleSessionFallsForwardThenBack() throws {
    var book = TatwoNativeCLISessionBook()
    let firstID = book.open(engine: .codex, title: "First", workdir: nil)
    let middleID = book.open(engine: .claude, title: "Middle", workdir: nil)
    let lastID = book.open(engine: .generic, title: "Last", workdir: nil)
    XCTAssertTrue(book.select(middleID))

    XCTAssertTrue(book.close(middleID))
    XCTAssertEqual(book.sessions.map(\.id), [firstID, lastID])
    XCTAssertEqual(book.activeSessionID, lastID)

    XCTAssertTrue(book.close(lastID))
    XCTAssertEqual(book.activeSessionID, firstID)
  }

  func testRenameAndRunningStateUpdateTimestamp() throws {
    let openedAt = Date(timeIntervalSince1970: 100)
    let renamedAt = Date(timeIntervalSince1970: 200)
    let stoppedAt = Date(timeIntervalSince1970: 300)
    var book = TatwoNativeCLISessionBook()
    let id = book.open(
      engine: .generic,
      title: "Shell",
      workdir: "/tmp",
      at: openedAt)

    XCTAssertTrue(book.rename(id, title: "Build shell", at: renamedAt))
    XCTAssertEqual(book.activeSession?.title, "Build shell")
    XCTAssertEqual(book.activeSession?.updatedAt, renamedAt)

    XCTAssertTrue(book.setRunning(false, for: id, at: stoppedAt))
    XCTAssertEqual(book.activeSession?.isRunning, false)
    XCTAssertEqual(book.activeSession?.updatedAt, stoppedAt)
  }

  func testReorderMovesSessionAndKeepsActiveSelection() throws {
    let reorderedAt = Date(timeIntervalSince1970: 400)
    var book = TatwoNativeCLISessionBook()
    let firstID = book.open(engine: .codex, title: "First", workdir: nil)
    let middleID = book.open(engine: .claude, title: "Middle", workdir: nil)
    let lastID = book.open(engine: .grok, title: "Last", workdir: nil)

    XCTAssertTrue(book.reorder(middleID, to: 0, at: reorderedAt))
    XCTAssertEqual(book.sessions.map(\.id), [middleID, firstID, lastID])
    XCTAssertEqual(book.sessions.first?.updatedAt, reorderedAt)
    XCTAssertEqual(book.activeSessionID, lastID)
  }

  func testEmptyBookOperationsAreSafe() throws {
    var book = TatwoNativeCLISessionBook()
    let unknownID = UUID()

    XCTAssertTrue(book.sessions.isEmpty)
    XCTAssertNil(book.activeSessionID)
    XCTAssertNil(book.activeSession)
    XCTAssertFalse(book.close(unknownID))
    XCTAssertFalse(book.select(unknownID))
    XCTAssertFalse(book.rename(unknownID, title: "Missing"))
    XCTAssertFalse(book.reorder(unknownID, to: 0))
    XCTAssertFalse(book.setRunning(false, for: unknownID))
  }

  func testCodableRoundTripPreservesOrderAndActiveSession() throws {
    var book = TatwoNativeCLISessionBook()
    let codexID = book.open(
      engine: .codex,
      title: "Codex",
      workdir: "/tmp/codex",
      at: Date(timeIntervalSince1970: 100))
    _ = book.open(
      engine: .generic,
      title: "Generic",
      workdir: nil,
      at: Date(timeIntervalSince1970: 200))
    XCTAssertTrue(book.select(codexID))

    let data = try JSONEncoder().encode(book)
    let decoded = try JSONDecoder().decode(TatwoNativeCLISessionBook.self, from: data)

    XCTAssertEqual(decoded, book)
  }

  func testLegacyDecodeDefaultsMissingFieldsAndSelectsFirstSession() throws {
    let legacyJSON = """
    {
      "sessions": [
        {
          "id": "00000000-0000-0000-0000-000000000701",
          "engine": "codex",
          "title": "Legacy Codex"
        }
      ]
    }
    """
    let data = try XCTUnwrap(legacyJSON.data(using: .utf8))

    let book = try JSONDecoder().decode(TatwoNativeCLISessionBook.self, from: data)
    let session = try XCTUnwrap(book.sessions.first)

    XCTAssertEqual(book.activeSessionID, session.id)
    XCTAssertEqual(book.activeSession, session)
    XCTAssertEqual(session.engine, .codex)
    XCTAssertEqual(session.title, "Legacy Codex")
    XCTAssertNil(session.workdir)
    XCTAssertEqual(session.createdAt, .distantPast)
    XCTAssertEqual(session.updatedAt, .distantPast)
    XCTAssertFalse(session.isRunning)
  }
}
