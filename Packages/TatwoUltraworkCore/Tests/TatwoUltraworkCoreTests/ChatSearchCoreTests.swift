import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatSearchCoreTests: XCTestCase {
  private let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
  private let threadID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
  private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!

  func testIndexerBuildsMessageAndSafeCLICommandDocumentsWithCompleteIdentity() {
    var history = TatwoCLICommandHistoryBook()
    _ = history.record(
      command: "swift test",
      sessionID: sessionID,
      engine: .codex,
      entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
      executedAt: Date(timeIntervalSince1970: 200))

    let documents = TatwoChatSearchIndexer.documents(
      from: [
        TatwoChatSearchMessage(
          projectID: projectID,
          threadID: threadID,
          messageID: "message-1",
          title: "Health thread",
          role: "assistant",
          text: "Build finished",
          attachmentNames: ["receipt.json"],
          timestamp: Date(timeIntervalSince1970: 100))
      ],
      history: history)

    XCTAssertEqual(documents.count, 2)
    XCTAssertEqual(documents[0].sourceKind, .message)
    XCTAssertEqual(documents[0].projectID, projectID)
    XCTAssertEqual(documents[0].threadID, threadID)
    XCTAssertEqual(documents[0].messageID, "message-1")
    XCTAssertEqual(documents[0].searchableText, "assistant\nBuild finished\nreceipt.json")
    XCTAssertEqual(documents[1].sourceKind, .cliCommand)
    XCTAssertEqual(documents[1].cliSessionID, sessionID)
    XCTAssertEqual(documents[1].searchableText, "swift test")
  }

  func testIndexerNeverExposesRedactedCommandRawText() {
    var history = TatwoCLICommandHistoryBook()
    _ = history.record(
      command: "deploy --token raw-secret",
      sessionID: sessionID,
      engine: .generic,
      entryID: UUID(),
      executedAt: .distantPast)

    let index = TatwoChatSearchIndex(messages: [], history: history)

    XCTAssertTrue(index.search(TatwoChatSearchQuery(rawText: "raw-secret")).isEmpty)
    XCTAssertEqual(
      index.search(TatwoChatSearchQuery(rawText: "敏感命令")).first?.source.sourceKind,
      .cliCommand)
  }

  func testSearchNormalizationIsCaseDiacriticWidthAndWhitespaceInsensitive() {
    let document = makeDocument(
      id: "normalized",
      title: "Other",
      text: "ＣＡＦÉ　　混合 測試")
    let results = TatwoChatSearchMatcher.search(
      query: TatwoChatSearchQuery(rawText: "cafe 混合　測試"),
      in: [document])

    XCTAssertEqual(results.map(\.id), ["normalized"])
  }

  func testRankingPrefersTitleExactThenPrefixThenMessageTokenThenSubstring() {
    let documents = [
      makeDocument(id: "substring", title: "Other", text: "rebuilding"),
      makeDocument(id: "token", title: "Other", text: "run build now"),
      makeDocument(id: "prefix", title: "Build logs", text: "other"),
      makeDocument(id: "exact", title: "Build", text: "other")
    ]

    let results = TatwoChatSearchMatcher.search(
      query: TatwoChatSearchQuery(rawText: "build"),
      in: documents)

    XCTAssertEqual(results.map(\.id), ["exact", "prefix", "token", "substring"])
    XCTAssertGreaterThan(results[0].score, results[1].score)
    XCTAssertGreaterThan(results[1].score, results[2].score)
    XCTAssertGreaterThan(results[2].score, results[3].score)
  }

  func testEqualScoreSortsNewerFirstThenStableID() {
    let documents = [
      makeDocument(
        id: "older",
        title: "Other",
        text: "needle",
        timestamp: Date(timeIntervalSince1970: 100)),
      makeDocument(
        id: "z-new",
        title: "Other",
        text: "needle",
        timestamp: Date(timeIntervalSince1970: 200)),
      makeDocument(
        id: "a-new",
        title: "Other",
        text: "needle",
        timestamp: Date(timeIntervalSince1970: 200))
    ]

    let results = TatwoChatSearchMatcher.search(
      query: TatwoChatSearchQuery(rawText: "needle"),
      in: documents)

    XCTAssertEqual(results.map(\.id), ["a-new", "z-new", "older"])
  }

  func testScopeAndLimitAreAppliedWithoutCrashing() {
    let documents = [
      makeDocument(id: "message", title: "needle", text: "needle"),
      TatwoChatSearchDocument(
        id: "cli",
        sourceKind: .cliCommand,
        cliSessionID: sessionID,
        title: "CLI codex",
        searchableText: "needle",
        timestamp: .distantPast)
    ]

    let cliOnly = TatwoChatSearchMatcher.search(
      query: TatwoChatSearchQuery(
        rawText: "needle",
        scope: .cliCommands,
        resultLimit: 5),
      in: documents)
    let zeroLimit = TatwoChatSearchMatcher.search(
      query: TatwoChatSearchQuery(rawText: "needle", resultLimit: 0),
      in: documents)
    let blank = TatwoChatSearchMatcher.search(
      query: TatwoChatSearchQuery(rawText: " \n "),
      in: documents)

    XCTAssertEqual(cliOnly.map(\.id), ["cli"])
    XCTAssertTrue(zeroLimit.isEmpty)
    XCTAssertTrue(blank.isEmpty)
  }

  func testMultipleMatchesExposeNormalizedScalarRangesAndCenteredSnippet() {
    let document = makeDocument(
      id: "many",
      title: "Other",
      text: "prefix prefix echo middle echo suffix suffix")

    let result = TatwoChatSearchMatcher.search(
      query: TatwoChatSearchQuery(rawText: "echo"),
      in: [document],
      snippetScalarLimit: 20).first

    XCTAssertEqual(result?.matchedRanges.count, 2)
    XCTAssertTrue(result?.snippet.contains("echo") == true)
    XCTAssertLessThanOrEqual(result?.snippet.unicodeScalars.count ?? .max, 22)
  }

  func testSearchResultCarriesNavigationIdentity() {
    let document = TatwoChatSearchDocument(
      id: "identity",
      sourceKind: .message,
      projectID: projectID,
      threadID: threadID,
      messageID: "message-identity",
      title: "Thread",
      searchableText: "find me",
      timestamp: .distantPast)

    let result = TatwoChatSearchIndex(documents: [document])
      .search(TatwoChatSearchQuery(rawText: "find"))
      .first

    XCTAssertEqual(result?.source.projectID, projectID)
    XCTAssertEqual(result?.source.threadID, threadID)
    XCTAssertEqual(result?.source.messageID, "message-identity")
  }

  func testIndexOnlySearchesCallerProvidedRetainedMessages() {
    let retained = TatwoChatSearchMessage(
      threadID: threadID,
      messageID: "retained",
      title: "Thread",
      text: "still searchable")
    let index = TatwoChatSearchIndex(messages: [retained], history: .init())

    XCTAssertEqual(
      index.search(TatwoChatSearchQuery(rawText: "searchable")).map(\.id),
      ["message:retained"])
    XCTAssertTrue(index.search(TatwoChatSearchQuery(rawText: "discarded")).isEmpty)
  }

  func testCodableRoundTripAndEmptyInputsAreSafe() throws {
    let index = TatwoChatSearchIndex(
      documents: [makeDocument(id: "roundtrip", title: "Title", text: "Text")])
    let decoded = try JSONDecoder().decode(
      TatwoChatSearchIndex.self,
      from: JSONEncoder().encode(index))

    XCTAssertEqual(decoded, index)
    XCTAssertTrue(
      TatwoChatSearchIndex(messages: [], history: .init())
        .search(TatwoChatSearchQuery(rawText: "anything"))
        .isEmpty)
  }

  private func makeDocument(
    id: String,
    title: String,
    text: String,
    timestamp: Date? = nil
  ) -> TatwoChatSearchDocument {
    TatwoChatSearchDocument(
      id: id,
      sourceKind: .message,
      projectID: projectID,
      threadID: threadID,
      messageID: id,
      title: title,
      searchableText: text,
      timestamp: timestamp)
  }
}
