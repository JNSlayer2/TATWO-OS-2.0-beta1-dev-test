import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoBrowserKnowledgeCoreTests: XCTestCase {
  private let laneA = TatwoBrowserLaneID(rawValue: "lane-a")
  private let laneB = TatwoBrowserLaneID(rawValue: "lane-b")

  func testBookmarkRecordDeduplicatesCanonicalURLWithinGoalAndPreservesIdentity() {
    let originalID = uuid(1)
    var store = TatwoBrowserBookmarkStore()

    XCTAssertEqual(
      store.record(
        bookmark(
          id: originalID,
          url: "https://example.test/spec",
          title: "Old title",
          goalID: "goal-a",
          createdAt: date(100),
          updatedAt: date(100))),
      .inserted(originalID))
    XCTAssertEqual(
      store.record(
        bookmark(
          id: uuid(2),
          url: "https://example.test/spec",
          title: "New title",
          note: "reviewed",
          tags: ["swift", "Swift", " core "],
          goalID: "goal-a",
          createdAt: date(200),
          updatedAt: date(300))),
      .updated(originalID))

    XCTAssertEqual(store.bookmarks.count, 1)
    XCTAssertEqual(store.bookmarks[0].id, originalID)
    XCTAssertEqual(store.bookmarks[0].title, "New title")
    XCTAssertEqual(store.bookmarks[0].note, "reviewed")
    XCTAssertEqual(store.bookmarks[0].tags, ["swift", "core"])
    XCTAssertEqual(store.bookmarks[0].createdAt, date(100))
    XCTAssertEqual(store.bookmarks[0].updatedAt, date(300))
  }

  func testBookmarkSameCanonicalURLInDifferentGoalsRemainsDistinctAndQueryable() {
    var store = TatwoBrowserBookmarkStore()
    _ = store.record(bookmark(id: uuid(1), url: "https://example.test", goalID: "goal-a"))
    _ = store.record(bookmark(id: uuid(2), url: "https://example.test", goalID: "goal-b"))

    XCTAssertEqual(store.bookmarks.count, 2)
    XCTAssertEqual(store.bookmarks(goalID: "goal-a").map(\.id), [uuid(1)])
    XCTAssertEqual(store.bookmarks(goalID: "goal-b").map(\.id), [uuid(2)])
  }

  func testBookmarkGoalMarkingAndMetadataSearchArePureValueOperations() {
    var original = TatwoBrowserBookmarkStore()
    _ = original.record(
      bookmark(
        id: uuid(1),
        url: "https://docs.example.test/swift",
        title: "Concurrency Guide",
        note: "Actors",
        tags: ["reference"]))
    var changed = original

    XCTAssertTrue(changed.markGoal(bookmarkID: uuid(1), goalID: " goal-a ", updatedAt: date(500)))
    XCTAssertEqual(changed.bookmarks(goalID: "goal-a").map(\.id), [uuid(1)])
    XCTAssertEqual(changed.search("actors").map(\.id), [uuid(1)])
    XCTAssertEqual(changed.search("REFERENCE").map(\.id), [uuid(1)])
    XCTAssertNil(original.bookmarks[0].goalID)
  }

  func testHistoryRecordDeduplicatesAdjacentNavigationCallbacks() {
    let firstID = uuid(11)
    var store = TatwoBrowserHistoryStore(deduplicationInterval: 5)

    XCTAssertEqual(
      store.record(
        history(
          id: firstID,
          url: "https://example.test/spec",
          title: "Loading",
          visitedAt: date(100),
          transition: .link)),
      .appended(firstID))
    XCTAssertEqual(
      store.record(
        history(
          id: uuid(12),
          url: "https://example.test/spec",
          title: "Specification",
          visitedAt: date(104),
          transition: .redirect)),
      .deduplicated(firstID))

    XCTAssertEqual(store.entries.count, 1)
    XCTAssertEqual(store.entries[0].id, firstID)
    XCTAssertEqual(store.entries[0].title, "Specification")
    XCTAssertEqual(store.entries[0].visitedAt, date(104))
    XCTAssertEqual(store.entries[0].transition, .redirect)
  }

  func testHistoryDedupeDoesNotMergeDifferentLaneOrGoalSemantics() {
    var store = TatwoBrowserHistoryStore(deduplicationInterval: 10)
    _ = store.record(history(id: uuid(11), url: "https://example.test", goalID: "goal-a"))
    _ = store.record(
      history(id: uuid(12), url: "https://example.test", laneID: laneB, goalID: "goal-a"))
    _ = store.record(history(id: uuid(13), url: "https://example.test", goalID: "goal-b"))

    XCTAssertEqual(store.entries.map(\.id), [uuid(11), uuid(12), uuid(13)])
  }

  func testHistoryPersistenceFlagAndRetentionAreDeterministic() {
    var store = TatwoBrowserHistoryStore(
      maximumEntryCount: 2,
      maximumAge: 100,
      deduplicationInterval: 0)

    XCTAssertEqual(
      store.record(history(id: uuid(10), visitedAt: date(1)), persistenceEnabled: false),
      .skippedPersistenceDisabled)
    _ = store.record(history(id: uuid(11), url: "https://one.test", visitedAt: date(10)))
    _ = store.record(history(id: uuid(12), url: "https://two.test", visitedAt: date(150)))
    _ = store.record(history(id: uuid(13), url: "https://three.test", visitedAt: date(160)))
    _ = store.record(history(id: uuid(14), url: "https://four.test", visitedAt: date(170)))

    XCTAssertEqual(store.entries.map(\.id), [uuid(13), uuid(14)])
  }

  func testHistoryGoalMarkingSupportsGoalQuery() {
    var store = TatwoBrowserHistoryStore()
    _ = store.record(history(id: uuid(11)))

    XCTAssertTrue(store.markGoal(entryID: uuid(11), goalID: "goal-a"))
    XCTAssertFalse(store.markGoal(entryID: uuid(99), goalID: "goal-a"))
    XCTAssertEqual(store.entries(goalID: "goal-a").map(\.id), [uuid(11)])
  }

  func testDownloadLedgerDeduplicatesIDsAndQueriesState() {
    var ledger = TatwoBrowserDownloadLedger()
    let record = download(id: uuid(21))

    XCTAssertTrue(ledger.record(record))
    XCTAssertFalse(ledger.record(record))
    XCTAssertEqual(ledger.records.count, 1)
    XCTAssertEqual(ledger.record(id: uuid(21)), record)
    XCTAssertEqual(ledger.records(state: .awaitingApproval).map(\.id), [uuid(21)])
  }

  func testDownloadGoalMarkingSupportsGoalQuery() {
    var ledger = TatwoBrowserDownloadLedger(records: [download(id: uuid(21))])

    XCTAssertTrue(ledger.markGoal(downloadID: uuid(21), goalID: " goal-a "))
    XCTAssertEqual(ledger.records(goalID: "goal-a").map(\.id), [uuid(21)])
  }

  func testDownloadProgressAndLegalTransitionsUpdateRequestedRecord() {
    var ledger = TatwoBrowserDownloadLedger(records: [
      download(id: uuid(21), expectedBytes: 100)
    ])

    XCTAssertTrue(ledger.transition(downloadID: uuid(21), to: .downloading))
    XCTAssertTrue(ledger.updateProgress(downloadID: uuid(21), receivedBytes: 40))
    XCTAssertTrue(ledger.transition(downloadID: uuid(21), to: .paused))
    XCTAssertTrue(ledger.transition(downloadID: uuid(21), to: .downloading))
    XCTAssertTrue(ledger.transition(downloadID: uuid(21), to: .verifying))
    XCTAssertEqual(ledger.record(id: uuid(21))?.receivedBytes, 40)
    XCTAssertEqual(ledger.record(id: uuid(21))?.state, .verifying)
  }

  func testDownloadInvalidProgressAndTransitionsLeaveLedgerUnchanged() {
    let original = TatwoBrowserDownloadLedger(records: [
      download(id: uuid(21), expectedBytes: 100)
    ])
    var changed = original

    XCTAssertFalse(changed.updateProgress(downloadID: uuid(21), receivedBytes: -1))
    XCTAssertFalse(changed.updateProgress(downloadID: uuid(21), receivedBytes: 101))
    XCTAssertFalse(changed.transition(downloadID: uuid(21), to: .completed))
    XCTAssertFalse(changed.transition(downloadID: uuid(99), to: .downloading))
    XCTAssertEqual(changed, original)
  }

  func testDownloadCompletionRequiresVerifiedSHA256() {
    var ledger = TatwoBrowserDownloadLedger(records: [
      download(id: uuid(21), state: .verifying, receivedBytes: 100, expectedBytes: 100)
    ])

    XCTAssertFalse(ledger.transition(downloadID: uuid(21), to: .completed))
    XCTAssertTrue(
      ledger.updateHashStatus(
        downloadID: uuid(21),
        status: .verified(sha256: String(repeating: "a", count: 64))))
    XCTAssertTrue(
      ledger.transition(downloadID: uuid(21), to: .completed, completedAt: date(500)))
    XCTAssertEqual(ledger.record(id: uuid(21))?.state, .completed)
    XCTAssertEqual(ledger.record(id: uuid(21))?.completedAt, date(500))
  }

  func testDownloadHashMismatchQuarantinesRecord() {
    var ledger = TatwoBrowserDownloadLedger(records: [
      download(id: uuid(21), state: .verifying, expectedBytes: nil)
    ])
    let status = TatwoBrowserDownloadHashStatus.mismatch(
      expectedSHA256: String(repeating: "a", count: 64),
      actualSHA256: String(repeating: "b", count: 64))

    XCTAssertTrue(ledger.updateHashStatus(downloadID: uuid(21), status: status))
    XCTAssertEqual(ledger.record(id: uuid(21))?.hashStatus, status)
    XCTAssertEqual(ledger.record(id: uuid(21))?.state, .quarantined)
  }

  func testKnowledgeModelsRoundTripAndKeepValueSemantics() throws {
    let bookmarkStore = TatwoBrowserBookmarkStore(bookmarks: [
      bookmark(id: uuid(1), goalID: "goal-a")
    ])
    let historyStore = TatwoBrowserHistoryStore(entries: [
      history(id: uuid(11), goalID: "goal-a")
    ])
    let downloadLedger = TatwoBrowserDownloadLedger(records: [
      download(id: uuid(21), goalID: "goal-a")
    ])

    XCTAssertEqual(try roundTrip(bookmarkStore), bookmarkStore)
    XCTAssertEqual(try roundTrip(historyStore), historyStore)
    XCTAssertEqual(try roundTrip(downloadLedger), downloadLedger)

    var copy = bookmarkStore
    _ = copy.record(bookmark(id: uuid(2), url: "https://other.test"))
    XCTAssertEqual(bookmarkStore.bookmarks.count, 1)
    XCTAssertEqual(copy.bookmarks.count, 2)
  }

  private func bookmark(
    id: UUID,
    url: String = "https://example.test",
    title: String = "Example",
    note: String? = nil,
    tags: [String] = [],
    goalID: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 100),
    updatedAt: Date = Date(timeIntervalSince1970: 100)
  ) -> TatwoBrowserBookmark {
    TatwoBrowserBookmark(
      id: id,
      canonicalURL: url,
      title: title,
      note: note,
      tags: tags,
      goalID: goalID,
      contractID: goalID.map { "\($0)-contract" },
      sourceLaneID: laneA,
      createdAt: createdAt,
      updatedAt: updatedAt)
  }

  private func history(
    id: UUID,
    url: String = "https://example.test",
    title: String = "Example",
    laneID: TatwoBrowserLaneID? = nil,
    goalID: String? = nil,
    visitedAt: Date = Date(timeIntervalSince1970: 100),
    transition: TatwoBrowserHistoryTransition = .typed
  ) -> TatwoBrowserHistoryEntry {
    TatwoBrowserHistoryEntry(
      id: id,
      canonicalURL: url,
      title: title,
      domain: URL(string: url)?.host ?? "example.test",
      laneID: laneID ?? laneA,
      goalID: goalID,
      visitedAt: visitedAt,
      transition: transition)
  }

  private func download(
    id: UUID,
    goalID: String? = nil,
    state: TatwoBrowserDownloadState = .awaitingApproval,
    receivedBytes: Int64 = 0,
    expectedBytes: Int64? = 100
  ) -> TatwoBrowserDownloadRecord {
    TatwoBrowserDownloadRecord(
      id: id,
      laneID: laneA,
      goalID: goalID,
      contractID: goalID.map { "\($0)-contract" },
      sourceDomain: "example.test",
      redactedSourceURL: "https://example.test/file",
      suggestedFilename: "file.zip",
      destinationTokenID: "destination-1",
      mimeType: "application/zip",
      risk: .archive,
      state: state,
      receivedBytes: receivedBytes,
      expectedBytes: expectedBytes,
      hashStatus: .pending,
      startedAt: date(100),
      completedAt: nil,
      receiptID: nil)
  }

  private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  }

  private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSince1970: value)
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}
