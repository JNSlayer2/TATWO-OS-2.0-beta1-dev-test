import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class NativeTerminalPoolReconcilerTests: XCTestCase {
  typealias Reconciler = TatwoNativeTerminalPoolReconciler

  func testMissingSessionsSpawnInBookOrderAndDuplicateIDsUseFirstEngine() {
    let firstID = uuid(1)
    let duplicateID = uuid(2)
    let sessions = [
      session(id: firstID, engine: .codex),
      session(id: duplicateID, engine: .claude),
      session(id: duplicateID, engine: .grok),
    ]

    let book = TatwoNativeCLISessionBook(
      sessions: sessions,
      activeSessionID: duplicateID)
    let plan = Reconciler.reconcile(book: book, existingTerminalIDs: [])

    XCTAssertEqual(
      plan.toSpawn,
      [
        .init(id: firstID, engine: .codex),
        .init(id: duplicateID, engine: .claude),
      ])
    XCTAssertTrue(plan.toTerminate.isEmpty)
    XCTAssertTrue(plan.toRespawn.isEmpty)
    XCTAssertEqual(plan.activeToFocus, duplicateID)
  }

  func testClosingMiddleSessionTerminatesOnlyThatTerminalAndKeepsActiveFocus() {
    let firstID = uuid(11)
    let middleID = uuid(12)
    let lastID = uuid(13)
    let sessions = [
      session(id: firstID, engine: .codex),
      session(id: lastID, engine: .grok),
    ]
    let live = [
      Reconciler.LiveTerminal(id: firstID, engine: .codex),
      Reconciler.LiveTerminal(id: middleID, engine: .claude),
      Reconciler.LiveTerminal(id: lastID, engine: .grok),
    ]

    let plan = Reconciler.reconcile(
      sessions: sessions,
      activeSessionID: lastID,
      liveTerminals: live)

    XCTAssertTrue(plan.toSpawn.isEmpty)
    XCTAssertEqual(plan.toTerminate, [middleID])
    XCTAssertTrue(plan.toRespawn.isEmpty)
    XCTAssertEqual(plan.activeToFocus, lastID)
  }

  func testUnknownActiveSessionDoesNotRequestFocus() {
    let knownID = uuid(21)

    let plan = Reconciler.reconcile(
      sessions: [session(id: knownID, engine: .codex)],
      activeSessionID: uuid(22),
      liveTerminals: [.init(id: knownID, engine: .codex)])

    XCTAssertNil(plan.activeToFocus)
  }

  func testEngineChangeRequestsRespawnWithDesiredEngine() {
    let id = uuid(31)

    let book = TatwoNativeCLISessionBook(
      sessions: [session(id: id, engine: .grok)],
      activeSessionID: id)
    let plan = Reconciler.reconcile(
      book: book,
      liveTerminals: [.init(id: id, engine: .codex)])

    XCTAssertTrue(plan.toSpawn.isEmpty)
    XCTAssertTrue(plan.toTerminate.isEmpty)
    XCTAssertEqual(plan.toRespawn, [.init(id: id, engine: .grok)])
    XCTAssertEqual(plan.activeToFocus, id)
  }

  func testEmptyBookTerminatesEveryLiveTerminalInStableIDOrder() {
    let lowerID = uuid(41)
    let upperID = uuid(42)

    let plan = Reconciler.reconcile(
      sessions: [],
      activeSessionID: nil,
      liveTerminals: [
        .init(id: upperID, engine: .claude),
        .init(id: lowerID, engine: .codex),
        .init(id: upperID, engine: .grok),
      ])

    XCTAssertTrue(plan.toSpawn.isEmpty)
    XCTAssertEqual(plan.toTerminate, [lowerID, upperID])
    XCTAssertTrue(plan.toRespawn.isEmpty)
    XCTAssertNil(plan.activeToFocus)
  }

  func testSameInputProducesEqualPlan() {
    let activeID = uuid(51)
    let staleID = uuid(52)
    let sessions = [session(id: activeID, engine: .claude)]
    let live = [Reconciler.LiveTerminal(id: staleID, engine: .generic)]

    let first = Reconciler.reconcile(
      sessions: sessions,
      activeSessionID: activeID,
      liveTerminals: live)
    let second = Reconciler.reconcile(
      sessions: sessions,
      activeSessionID: activeID,
      liveTerminals: live)

    XCTAssertEqual(first, second)
  }

  private func session(
    id: UUID,
    engine: TatwoNativeCLISessionBook.Engine
  ) -> TatwoNativeCLISessionBook.Session {
    TatwoNativeCLISessionBook.Session(
      id: id,
      engine: engine,
      title: engine.rawValue,
      createdAt: Date(timeIntervalSince1970: 1))
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
  }
}
