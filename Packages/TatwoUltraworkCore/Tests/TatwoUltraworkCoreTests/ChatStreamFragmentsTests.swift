import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatStreamFragmentsTests: XCTestCase {

  // MARK: - Types & promote

  func testStreamFragmentStateSeparatesTailFromStable() {
    let session = UUID()
    let tail = StreamFragment(sessionID: session, content: "partial…", state: .tail)
    let stable = StreamFragment(
      sessionID: session,
      content: "done",
      state: .stable(sequence: 1))

    XCTAssertTrue(tail.isTail)
    XCTAssertFalse(tail.isStable)
    XCTAssertNil(tail.stableSequence)
    XCTAssertTrue(stable.isStable)
    XCTAssertEqual(stable.stableSequence, 1)
  }

  func testAppendStableRejectsTail() {
    let ledger = StreamTranscriptLedger()
    let tail = StreamFragment(
      sessionID: ledger.sessionID,
      content: "nope",
      state: .tail)
    XCTAssertThrowsError(try ledger.appendStable(tail)) { error in
      XCTAssertEqual(error as? StreamFragmentPersistenceError, .rejectTail)
    }
  }

  func testPromoteTailIsAtomicAndMonotonic() throws {
    let ledger = StreamTranscriptLedger()
    _ = ledger.beginTail(content: "hel")
    _ = ledger.appendTailChunk("lo")
    let first = try ledger.promoteTail()
    XCTAssertEqual(first.content, "hello")
    XCTAssertEqual(first.stableSequence, 1)
    XCTAssertFalse(ledger.hasTail)
    XCTAssertEqual(ledger.persistableFragments.count, 1)

    _ = ledger.beginTail(content: "world")
    let second = try ledger.promoteTail()
    XCTAssertEqual(second.stableSequence, 2)
    XCTAssertEqual(ledger.lastStableSequence, 2)

    // Sequence must not regress.
    let regress = StreamFragment(
      sessionID: ledger.sessionID,
      content: "old",
      state: .stable(sequence: 2))
    XCTAssertThrowsError(try ledger.appendStable(regress)) { error in
      XCTAssertEqual(
        error as? StreamFragmentPersistenceError,
        .sequenceRegression(current: 2, attempted: 2))
    }
  }

  func testPersistenceGateRejectsUnfinishedTailFragments() {
    let session = UUID()
    let fragments = [
      StreamFragment(sessionID: session, content: "a", state: .stable(sequence: 1)),
      StreamFragment(sessionID: session, content: "b", state: .tail),
    ]
    XCTAssertThrowsError(try ChatStreamPersistence.persistableFragments(fragments)) { error in
      XCTAssertEqual(error as? StreamFragmentPersistenceError, .rejectTail)
    }
    XCTAssertThrowsError(
      try ChatStreamPersistence.requireStable(fragments[1])
    ) { error in
      XCTAssertEqual(error as? StreamFragmentPersistenceError, .rejectTail)
    }
  }

  // MARK: - Cancel / timeout / crash (no half message)

  func testDiscardTailLeavesNoPersistableHalfMessage() {
    let ledger = StreamTranscriptLedger()
    _ = ledger.beginTail(content: "half-written assistant body")
    XCTAssertTrue(ledger.hasTail)
    ledger.discardTail()
    XCTAssertFalse(ledger.hasTail)
    XCTAssertTrue(ledger.persistableFragments.isEmpty)
    XCTAssertTrue(ledger.reconnectSnapshot().isEmpty)
  }

  func testCrashBeforePromoteDoesNotSurfaceTailOnReconnect() throws {
    let ledger = StreamTranscriptLedger()
    _ = ledger.beginTail(content: "stable-ok")
    _ = try ledger.promoteTail()
    _ = ledger.appendTailChunk("THIS_MUST_NOT_RECONNECT")

    // Simulate process death: only reconnectSnapshot is restored.
    let restored = StreamTranscriptLedger(sessionID: ledger.sessionID)
    try restored.restoreStableCheckpoint(ledger.reconnectSnapshot())

    XCTAssertEqual(restored.persistableFragments.map(\.content), ["stable-ok"])
    XCTAssertFalse(restored.hasTail)
    XCTAssertFalse(
      restored.displayFragments.contains(where: { $0.content.contains("THIS_MUST_NOT") }))
  }

  // MARK: - Stored message seal / migration

  func testInFlightStoredMessagesAreNotPersistable() {
    let streaming = TatwoNativeChatStoredMessage(
      role: "assistant",
      text: "partial stream body",
      status: "streaming")
    let thinking = TatwoNativeChatStoredMessage(
      role: "assistant",
      text: "",
      status: "thinking")
    let complete = TatwoNativeChatStoredMessage(
      role: "assistant",
      text: "final answer",
      status: nil)
    let failed = TatwoNativeChatStoredMessage(
      role: "assistant",
      text: "模型路線中斷，未收到完整回覆。",
      status: "failed")
    let user = TatwoNativeChatStoredMessage(
      role: "user",
      text: "hello",
      status: nil)

    XCTAssertTrue(ChatStreamPersistence.isInFlightStoredMessage(streaming))
    XCTAssertTrue(ChatStreamPersistence.isInFlightStoredMessage(thinking))
    XCTAssertFalse(ChatStreamPersistence.isInFlightStoredMessage(complete))
    XCTAssertFalse(ChatStreamPersistence.isInFlightStoredMessage(failed))
    XCTAssertFalse(ChatStreamPersistence.isInFlightStoredMessage(user))

    let filtered = ChatStreamPersistence.persistableStoredMessages([
      user, streaming, thinking, complete, failed,
    ])
    XCTAssertEqual(filtered.map(\.text), ["hello", "final answer", failed.text])
  }

  func testReconnectStoredMessagesDropsLegacyTails() {
    let legacyHalf = TatwoNativeChatStoredMessage(
      role: "assistant",
      text: "half from old writer",
      status: "stream")
    let ok = TatwoNativeChatStoredMessage(
      role: "assistant",
      text: "complete",
      status: nil)
    let reconnected = ChatStreamPersistence.reconnectStoredMessages([legacyHalf, ok])
    XCTAssertEqual(reconnected.map(\.text), ["complete"])
  }

  func testStoreSaveSealsInFlightTailsAndLoadRestoresStableOnly() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-stream-seal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("native-chat-threads.json")
    let store = TatwoNativeChatStore(url: url, mirrorsToUnifiedLedger: false)

    let thread = TatwoNativeChatThread(
      title: "stream",
      messages: [
        TatwoNativeChatStoredMessage(role: "user", text: "hi"),
        TatwoNativeChatStoredMessage(
          role: "assistant",
          text: "partial…",
          status: "streaming"),
        TatwoNativeChatStoredMessage(
          role: "assistant",
          text: "done",
          status: nil),
      ])
    let document = TatwoNativeChatStoreDocument(threads: [thread])
    try store.save(document)

    // Raw file must not contain the unfinished tail body as a durable row.
    let raw = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(raw.contains("partial…"))
    XCTAssertTrue(raw.contains("done"))

    let loaded = try store.load()
    let messages = loaded.threads[0].messages ?? []
    XCTAssertEqual(messages.map(\.text), ["hi", "done"])
  }

  func testLegacyDocumentWithoutStreamFieldsStillDecodes() throws {
    // Pre-Wave2 on-disk shape: only classic message fields, no stream state keys.
    let legacyJSON = """
      {
        "schemaVersion": 1,
        "updatedAt": 0,
        "threads": [
          {
            "id": "019f0000-0000-7000-8000-0000000000aa",
            "title": "Legacy thread",
            "createdAt": 0,
            "updatedAt": 0,
            "messages": [
              {
                "id": "msg-1",
                "role": "user",
                "text": "old user",
                "eventKind": "message",
                "createdAt": 0
              },
              {
                "id": "msg-2",
                "role": "assistant",
                "text": "old assistant complete",
                "eventKind": "message",
                "createdAt": 0
              }
            ]
          }
        ],
        "projects": []
      }
      """
    let decoded = try JSONDecoder().decode(
      TatwoNativeChatStoreDocument.self,
      from: Data(legacyJSON.utf8))
    XCTAssertEqual(decoded.threads.count, 1)
    XCTAssertEqual(decoded.threads[0].messages?.count, 2)
    XCTAssertEqual(decoded.threads[0].messages?[1].text, "old assistant complete")

    // Sealing must keep completed legacy rows.
    let sealed = ChatStreamPersistence.sealing(decoded)
    XCTAssertEqual(sealed.threads[0].messages?.map(\.text), [
      "old user",
      "old assistant complete",
    ])
  }

  func testLegacyInFlightStatusRowIsReadableButSealedOnReconnect() throws {
    let legacyJSON = """
      {
        "schemaVersion": 1,
        "updatedAt": 0,
        "threads": [
          {
            "id": "019f0000-0000-7000-8000-0000000000bb",
            "title": "Half",
            "createdAt": 0,
            "updatedAt": 0,
            "messages": [
              {
                "id": "msg-u",
                "role": "user",
                "text": "go",
                "eventKind": "message",
                "createdAt": 0
              },
              {
                "id": "msg-a",
                "role": "assistant",
                "text": "half-written from crash",
                "status": "streaming",
                "eventKind": "message",
                "createdAt": 0
              }
            ]
          }
        ],
        "projects": []
      }
      """
    let decoded = try JSONDecoder().decode(
      TatwoNativeChatStoreDocument.self,
      from: Data(legacyJSON.utf8))
    // Raw decode still understands the old row (migration compatibility).
    XCTAssertEqual(decoded.threads[0].messages?.count, 2)

    let reconnected = ChatStreamPersistence.reconnectStoredMessages(
      decoded.threads[0].messages ?? [])
    XCTAssertEqual(reconnected.map(\.text), ["go"])
  }
}
