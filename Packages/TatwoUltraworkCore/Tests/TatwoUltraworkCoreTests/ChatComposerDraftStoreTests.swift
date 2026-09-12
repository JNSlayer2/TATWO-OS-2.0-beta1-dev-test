import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatComposerDraftStoreTests: XCTestCase {
  func testRoundTripNormalizesEmptyRowsAndKeepsThreadDiscussionIsolation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoChatComposerDraftStore(
      url: root.appendingPathComponent("chat-composer-drafts-v1.json"))
    let thread = TatwoNativeChatSessionReference(
      kind: .thread,
      id: UUID(uuidString: "019f0000-0000-7000-8000-000000000081")!)
    let discussion = TatwoNativeChatSessionReference(
      kind: .discussion,
      id: UUID(uuidString: "019f0000-0000-7000-8000-000000000082")!)

    try store.save([
      thread.stableKey: "thread draft",
      discussion.stableKey: "discussion draft",
      "thread:empty": "",
    ])

    XCTAssertEqual(
      try store.load().draftsBySessionKey,
      [
        thread.stableKey: "thread draft",
        discussion.stableKey: "discussion draft",
      ])
  }

  func testMissingStoreLoadsEmptyWithoutCreatingAFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-missing-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("chat-composer-drafts-v1.json")
    let store = TatwoChatComposerDraftStore(url: url)

    XCTAssertTrue(try store.load().draftsBySessionKey.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testUnsupportedSchemaFailsClosedWithoutOverwritingSource() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-schema-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("chat-composer-drafts-v1.json")
    let source = Data(
      #"{"schemaVersion":99,"updatedAt":"2026-08-01T00:00:00Z","draftsBySessionKey":{"thread:x":"private"}}"#
        .utf8)
    try source.write(to: url)
    let store = TatwoChatComposerDraftStore(url: url)

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(
        error as? TatwoChatComposerDraftStoreError,
        .unsupportedSchema(99))
    }
    XCTAssertEqual(try Data(contentsOf: url), source)
  }

  func testLegacySchemaLoadsWithPerSessionFreshnessAndUpgradesOnSave() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-schema-upgrade-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("chat-composer-drafts-v1.json")
    let legacyTimestamp = "2026-07-31T12:00:00Z"
    try Data(
      """
      {
        "schemaVersion": 1,
        "updatedAt": "\(legacyTimestamp)",
        "draftsBySessionKey": {
          "thread:legacy": "legacy draft"
        }
      }
      """.utf8
    ).write(to: url)
    let store = TatwoChatComposerDraftStore(url: url)

    let loaded = try store.load()
    XCTAssertEqual(loaded.schemaVersion, 1)
    XCTAssertEqual(
      loaded.draftUpdatedAtBySessionKey["thread:legacy"],
      loaded.updatedAt)

    try store.save(loaded.draftsBySessionKey)
    let upgraded = try store.load()
    XCTAssertEqual(
      upgraded.schemaVersion,
      TatwoChatComposerDraftDocument.currentSchemaVersion)
    XCTAssertEqual(
      upgraded.draftUpdatedAtBySessionKey["thread:legacy"],
      loaded.updatedAt)
  }

  func testSavingAnotherSessionPreservesUnchangedDraftFreshness() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-freshness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoChatComposerDraftStore(
      url: root.appendingPathComponent("chat-composer-drafts-v1.json"))

    try store.save(["thread:a": "draft A"])
    let first = try store.load()
    let draftAUpdatedAt = try XCTUnwrap(
      first.draftUpdatedAtBySessionKey["thread:a"])

    try store.save([
      "thread:a": "draft A",
      "thread:b": "draft B",
    ])
    let second = try store.load()

    XCTAssertEqual(
      second.draftUpdatedAtBySessionKey["thread:a"],
      draftAUpdatedAt)
    XCTAssertNotNil(second.draftUpdatedAtBySessionKey["thread:b"])
  }

  func testExplicitRefreshAdvancesTimestampForRetypedIdenticalDraft() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-retyped-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoChatComposerDraftStore(
      url: root.appendingPathComponent("chat-composer-drafts-v1.json"))

    try store.save(["thread:a": "same text"])
    let firstDate = try XCTUnwrap(
      store.load().draftUpdatedAtBySessionKey["thread:a"])
    Thread.sleep(forTimeInterval: 1.05)

    try store.save(
      ["thread:a": "same text"],
      refreshedSessionKeys: ["thread:a"])
    let refreshedDate = try XCTUnwrap(
      store.load().draftUpdatedAtBySessionKey["thread:a"])

    XCTAssertGreaterThan(refreshedDate, firstDate)
  }

  func testAcceptedMessageAcknowledgementPersistsWithoutADraftRow() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-ack-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoChatComposerDraftStore(
      url: root.appendingPathComponent("chat-composer-drafts-v1.json"))

    try store.save(
      [:],
      acknowledgedAcceptedMessageIDBySessionKey: [
        "thread:a": "accepted-message-1"
      ])
    let loaded = try store.load()

    XCTAssertTrue(loaded.draftsBySessionKey.isEmpty)
    XCTAssertEqual(
      loaded.acknowledgedAcceptedMessageIDBySessionKey["thread:a"],
      "accepted-message-1")
  }

  func testDedicatedDraftFileIsOutsideNativeThreadAndUnifiedLedgerPayloads() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-chat-draft-boundary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nativeStore = TatwoNativeChatStore(
      url: root.appendingPathComponent("native-chat-threads.json"))
    let draftStore = TatwoChatComposerDraftStore.colocated(with: nativeStore.url)
    let thread = TatwoNativeChatThread(title: "Private draft boundary")
    let reference = TatwoNativeChatSessionReference(kind: .thread, id: thread.id)
    let privateDraft = "never-sync-this-unsent-text"

    try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
    try draftStore.save([reference.stableKey: privateDraft])

    XCTAssertNotEqual(draftStore.url, nativeStore.url)
    XCTAssertFalse(try String(contentsOf: nativeStore.url).contains(privateDraft))
    let ledgerURL = try XCTUnwrap(nativeStore.unifiedLedger?.fileURL)
    let ledgerText = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
    XCTAssertFalse(ledgerText.contains(privateDraft))
    XCTAssertEqual(
      try draftStore.load().draftsBySessionKey[reference.stableKey],
      privateDraft)
  }
}
