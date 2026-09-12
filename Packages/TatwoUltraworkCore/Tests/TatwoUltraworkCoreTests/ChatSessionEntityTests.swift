import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatSessionEntityTests: XCTestCase {

  // MARK: - Lifecycle

  func testSessionLifecycleCreateActivateDegradeArchive() {
    var entity = TatwoSessionEntity(
      kind: .chatThread,
      engine: .codex,
      state: .active,
      source: "chat_thread")

    XCTAssertEqual(entity.state, .active)
    XCTAssertEqual(entity.kind, .chatThread)
    XCTAssertFalse(entity.id.uuidString.isEmpty)

    entity.apply(connection: .degraded, at: Date(timeIntervalSince1970: 10))
    XCTAssertEqual(entity.state, .degraded)
    XCTAssertEqual(entity.updatedAt, Date(timeIntervalSince1970: 10))

    entity.apply(connection: .offline, at: Date(timeIntervalSince1970: 20))
    XCTAssertEqual(entity.state, .offline)

    entity.apply(connection: .connected, at: Date(timeIntervalSince1970: 30))
    XCTAssertEqual(entity.state, .active)

    entity.state = .archived
    XCTAssertEqual(entity.state, .archived)
  }

  func testStreamAndLoopsShareCanonicalSessionIDSemantics() {
    let threadID = UUID()
    let streamEntity = TatwoSessionEntity.forStream(
      sessionID: threadID,
      threadID: threadID,
      engine: .codex)
    let loops = TatwoLoopsSupervisorRule.make(
      parentSupervisorModelID: "fable5",
      parentKind: .thread,
      parentID: threadID,
      projectID: UUID(),
      title: "loop",
      plg: TatwoLoopsPLG(plan: "p", loops: "l", goal: "g"),
      reviewerModelID: nil)
    let loopsEntity = TatwoSessionEntity.from(loops: loops, jobID: "job-1")

    // Stream bound to thread uses thread UUID as primary id.
    XCTAssertEqual(streamEntity.id, threadID)
    XCTAssertEqual(streamEntity.threadID, threadID)

    // Loops has its own id but retains thread association via threadID/parent.
    XCTAssertNotEqual(loopsEntity.id, threadID)
    XCTAssertEqual(loopsEntity.threadID, threadID)
    XCTAssertEqual(loopsEntity.parentSessionID, threadID)
    XCTAssertEqual(loopsEntity.jobID, "job-1")
    XCTAssertEqual(loopsEntity.kind, .loops)

    let ledger = StreamTranscriptLedger(session: streamEntity)
    XCTAssertEqual(ledger.sessionID, streamEntity.id)
    XCTAssertEqual(ledger.sessionID, threadID)

    let reconnect = ChatStreamReconnectController(session: streamEntity)
    XCTAssertEqual(reconnect.snapshot.sessionID, streamEntity.id)
  }

  // MARK: - Compatibility with existing durable shapes

  func testProjectionFromThreadPreservesIDsAndLegacyProviderHandles() throws {
    let threadID = UUID()
    let codexResume = "thread-codex-resume-abc"
    let thread = TatwoNativeChatThread(
      id: threadID,
      title: "legacy thread",
      codexSessionID: codexResume,
      claudeSessionID: nil,
      messages: [
        TatwoNativeChatStoredMessage(role: "user", text: "hello"),
        TatwoNativeChatStoredMessage(role: "assistant", text: "world"),
      ])

    let entity = TatwoSessionEntity.from(thread: thread)
    XCTAssertEqual(entity.id, threadID)
    XCTAssertEqual(entity.kind, .chatThread)
    XCTAssertEqual(entity.threadID, threadID)
    XCTAssertEqual(entity.engine, .codex)
    XCTAssertEqual(
      entity.providerSessionID(forAdapter: TatwoChatRuntimeAdapter.codexExec.rawValue),
      codexResume)

    // Provider resume string is secondary — not the canonical id.
    XCTAssertFalse(
      TatwoSessionEntity.isCanonicalSessionID(codexResume, matching: entity))
    XCTAssertTrue(
      TatwoSessionEntity.isCanonicalSessionID(threadID.uuidString, matching: entity))

    // Chat store document still round-trips messages (entity projection does not mutate).
    let document = TatwoNativeChatStoreDocument(threads: [thread])
    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(TatwoNativeChatStoreDocument.self, from: data)
    XCTAssertEqual(decoded.threads.first?.id, threadID)
    XCTAssertEqual(decoded.threads.first?.messages?.map(\.text), ["hello", "world"])
    XCTAssertEqual(decoded.threads.first?.codexSessionID, codexResume)

    let reprojected = TatwoSessionEntity.from(thread: decoded.threads[0])
    XCTAssertTrue(TatwoSessionEntity.sameIdentity(entity, reprojected))
    XCTAssertEqual(
      reprojected.providerSessionID(forAdapter: TatwoChatRuntimeAdapter.codexExec.rawValue),
      codexResume)
  }

  func testLegacyJSONMigrationDecodeAcceptsAlternateKeys() throws {
    let id = UUID()
    let json = """
      {
        "sessionID": "\(id.uuidString)",
        "createdISO": "2026-04-01T12:00:00Z",
        "engineSource": "codex-exec",
        "status": "degraded|retrying",
        "threadID": "\(id.uuidString)",
        "providerSessionIDs": { "codex-exec": "provider-xyz" }
      }
      """
    let entity = try JSONDecoder().decode(
      TatwoSessionEntity.self,
      from: Data(json.utf8))

    XCTAssertEqual(entity.id, id)
    XCTAssertEqual(entity.engine, .codex)
    XCTAssertEqual(entity.state, .degraded)
    XCTAssertEqual(entity.threadID, id)
    XCTAssertEqual(entity.providerSessionIDs["codex-exec"], "provider-xyz")
    // kind defaults when absent
    XCTAssertEqual(entity.kind, .stream)
  }

  func testRoundTripEncodeDecodePreservesCanonicalFields() throws {
    var entity = TatwoSessionEntity(
      id: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      kind: .cli,
      engine: .grok,
      threadID: UUID(),
      jobID: "job-9",
      parentSessionID: UUID(),
      providerSessionIDs: ["x": "y"],
      state: .active,
      source: "cli")
    entity.upsertProviderSessionID("p-1", adapterID: "codex-exec")

    let data = try JSONEncoder().encode(entity)
    let decoded = try JSONDecoder().decode(TatwoSessionEntity.self, from: data)
    XCTAssertEqual(decoded, entity)
    XCTAssertEqual(decoded.stableKey, "cli:\(entity.id.uuidString.lowercased())")
  }

  func testCLIAndDiscussionProjections() {
    let sourceThread = UUID()
    let cli = TatwoNativeCLISession(
      name: "term",
      engine: .claude,
      cwd: "/tmp",
      sourceThreadID: sourceThread,
      seededContext: "ctx")
    let cliEntity = TatwoSessionEntity.from(cli: cli)
    XCTAssertEqual(cliEntity.id, cli.id)
    XCTAssertEqual(cliEntity.kind, .cli)
    XCTAssertEqual(cliEntity.engine, .claude)
    XCTAssertEqual(cliEntity.threadID, sourceThread)
    XCTAssertEqual(cliEntity.parentSessionID, sourceThread)

    let discussion = TatwoNativeDiscussion(
      title: "side",
      inheritedSnapshot: "snap",
      parentSession: TatwoNativeChatSessionReference(kind: .thread, id: sourceThread))
    let discussionEntity = TatwoSessionEntity.from(
      discussion: discussion,
      parentThreadID: sourceThread)
    XCTAssertEqual(discussionEntity.id, discussion.id)
    XCTAssertEqual(discussionEntity.kind, .chatDiscussion)
    XCTAssertEqual(discussionEntity.threadID, sourceThread)
    XCTAssertEqual(
      discussionEntity.chatSessionReference,
      TatwoNativeChatSessionReference(kind: .discussion, id: discussion.id))
  }

  func testIdSemanticsRejectProviderStringAsPrimary() {
    var entity = TatwoSessionEntity.forStream(engine: .codex)
    let canonical = entity.id
    entity.upsertProviderSessionID("sess_provider_not_uuid", adapterID: "codex-exec")

    XCTAssertEqual(entity.id, canonical)
    XCTAssertEqual(
      entity.providerSessionID(forAdapter: "codex-exec"),
      "sess_provider_not_uuid")
    XCTAssertNotEqual(
      entity.providerSessionID(forAdapter: "codex-exec"),
      entity.id.uuidString)
    XCTAssertFalse(
      TatwoSessionEntity.isCanonicalSessionID(
        "sess_provider_not_uuid",
        matching: entity))
  }
}
