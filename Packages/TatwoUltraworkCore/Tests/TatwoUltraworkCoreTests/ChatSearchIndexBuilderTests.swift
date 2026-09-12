import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatSearchIndexBuilderTests: XCTestCase {
  private let projectA = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
  private let projectB = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
  private let threadA = UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
  private let threadB = UUID(uuidString: "00000000-0000-0000-0000-000000000312")!
  private let threadC = UUID(uuidString: "00000000-0000-0000-0000-000000000313")!
  private let cliSession = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!

  func testBuildMapsMessagesAcrossProjectsAndThreadsIntoSearchableDocuments() {
    let index = TatwoChatSearchIndexBuilder.build(
      projects: [
        makeProject(
          id: projectA,
          name: "Alpha",
          threads: [
            makeThread(
              id: threadA,
              title: "Planning",
              messages: [
                makeMessage(
                  id: "message-a1",
                  role: "user",
                  text: "alpha planning needle",
                  timestamp: 100),
                makeMessage(
                  id: "message-a2",
                  role: "assistant",
                  text: "alpha reply",
                  timestamp: 200),
              ]),
            makeThread(
              id: threadB,
              title: "Verification",
              messages: [
                makeMessage(
                  id: "message-b1",
                  role: "assistant",
                  text: "cross-thread receipt",
                  timestamp: 300)
              ]),
          ]),
        makeProject(
          id: projectB,
          name: "Beta",
          threads: [
            makeThread(
              id: threadC,
              title: "Shipping",
              messages: [
                makeMessage(
                  id: "message-c1",
                  role: "user",
                  text: "beta shipping needle",
                  timestamp: 400)
              ])
          ]),
      ],
      history: .init())

    XCTAssertEqual(index.documents.count, 4)

    let alpha = index.search(TatwoChatSearchQuery(rawText: "alpha planning needle")).first
    XCTAssertEqual(alpha?.source.sourceKind, .message)
    XCTAssertEqual(alpha?.source.projectID, projectA)
    XCTAssertEqual(alpha?.source.threadID, threadA)
    XCTAssertEqual(alpha?.source.messageID, "message-a1")
    XCTAssertEqual(alpha?.source.title, "Planning")
    XCTAssertEqual(alpha?.source.timestamp, Date(timeIntervalSince1970: 100))

    let beta = index.search(TatwoChatSearchQuery(rawText: "beta shipping needle")).first
    XCTAssertEqual(beta?.source.projectID, projectB)
    XCTAssertEqual(beta?.source.threadID, threadC)
    XCTAssertEqual(beta?.source.messageID, "message-c1")
  }

  func testBuildPreservesConversationCLIAndAllScopeFiltering() {
    var history = TatwoCLICommandHistoryBook()
    _ = history.record(
      command: "shared scope needle",
      sessionID: cliSession,
      engine: .codex,
      entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000322")!,
      executedAt: Date(timeIntervalSince1970: 500))

    let index = TatwoChatSearchIndexBuilder.build(
      projects: [
        makeProject(
          id: projectA,
          name: "Alpha",
          threads: [
            makeThread(
              id: threadA,
              title: "Scope",
              messages: [
                makeMessage(
                  id: "message-scope",
                  role: "user",
                  text: "shared scope needle",
                  timestamp: 400)
              ])
          ])
      ],
      history: history)

    let conversations = index.search(
      TatwoChatSearchQuery(
        rawText: "shared scope needle",
        scope: .conversations))
    let cliCommands = index.search(
      TatwoChatSearchQuery(
        rawText: "shared scope needle",
        scope: .cliCommands))
    let all = index.search(
      TatwoChatSearchQuery(
        rawText: "shared scope needle",
        scope: .all))

    XCTAssertEqual(conversations.map(\.source.sourceKind), [.message])
    XCTAssertEqual(cliCommands.map(\.source.sourceKind), [.cliCommand])
    XCTAssertEqual(Set(all.map(\.source.sourceKind)), [.message, .cliCommand])
  }

  func testBuildHandlesEmptyProjectsNilMessagesAndEmptyHistory() {
    XCTAssertTrue(
      TatwoChatSearchIndexBuilder.build(projects: [], history: .init())
        .documents.isEmpty)

    let projectWithNoMessages = makeProject(
      id: projectA,
      name: "Empty",
      threads: [
        TatwoNativeChatThread(
          id: threadA,
          title: "No messages",
          messages: nil)
      ])

    XCTAssertTrue(
      TatwoChatSearchIndexBuilder.build(
        projects: [projectWithNoMessages],
        history: .init())
        .documents.isEmpty)
  }

  private func makeProject(
    id: UUID,
    name: String,
    threads: [TatwoNativeChatThread]
  ) -> TatwoNativeChatProject {
    TatwoNativeChatProject(
      id: id,
      name: name,
      workdir: "",
      threads: threads)
  }

  private func makeThread(
    id: UUID,
    title: String,
    messages: [TatwoNativeChatStoredMessage]
  ) -> TatwoNativeChatThread {
    TatwoNativeChatThread(
      id: id,
      title: title,
      messages: messages)
  }

  private func makeMessage(
    id: String,
    role: String,
    text: String,
    timestamp: TimeInterval
  ) -> TatwoNativeChatStoredMessage {
    TatwoNativeChatStoredMessage(
      id: id,
      role: role,
      text: text,
      createdAt: Date(timeIntervalSince1970: timestamp))
  }
}
