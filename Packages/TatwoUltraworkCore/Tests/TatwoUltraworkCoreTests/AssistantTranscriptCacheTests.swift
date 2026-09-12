import Foundation
import os
import XCTest

@testable import TatwoUltraworkCore

@MainActor
final class AssistantTranscriptCacheTests: XCTestCase {
  func testSameMessageAndTextKeyDoesNotParseTwice() {
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8) { markdown in
      parseCount.withLock { $0 += 1 }
      return TatwoAssistantTranscriptPresentation.document(markdown: markdown)
    }

    let first = cache.document(messageID: "assistant-1", markdown: "**Hello**")
    let second = cache.document(messageID: "assistant-1", markdown: "**Hello**")

    XCTAssertEqual(first, second)
    XCTAssertEqual(parseCount.withLock { $0 }, 1)
  }

  func testTextChangeForSameMessageCreatesANewCacheKey() {
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8) { markdown in
      parseCount.withLock { $0 += 1 }
      return TatwoAssistantTranscriptPresentation.document(markdown: markdown)
    }

    _ = cache.document(messageID: "assistant-1", markdown: "First")
    _ = cache.document(messageID: "assistant-1", markdown: "First plus delta")

    XCTAssertEqual(parseCount.withLock { $0 }, 2)
  }

  func testCacheKeyUsesMessageIDUTF8CountAndHash() {
    let markdown = "Hello"
    let key = TatwoAssistantTranscriptCacheKey(messageID: "assistant-1", markdown: markdown)
    let same = TatwoAssistantTranscriptCacheKey(messageID: "assistant-1", markdown: markdown)
    let longer = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-1",
      markdown: markdown + "!")

    XCTAssertEqual(key.messageID, "assistant-1")
    XCTAssertEqual(key.utf8Count, markdown.utf8.count)
    XCTAssertEqual(
      key.parserVersion,
      TatwoAssistantTranscriptCache.defaultParserVersion)
    XCTAssertEqual(key, same)
    XCTAssertNotEqual(key.textHash, longer.textHash)
    XCTAssertNotEqual(key.utf8Count, longer.utf8Count)
    XCTAssertNotEqual(key, longer)
  }

  func testPrecomputedFingerprintKeyMatchesNormallyHashedKey() {
    let markdown = String(repeating: "streaming markdown ", count: 256)
    let normallyHashed = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-precomputed",
      markdown: markdown)
    let precomputed = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-precomputed",
      markdown: markdown,
      utf8Count: normallyHashed.utf8Count,
      fingerprint: normallyHashed.textHash)

    XCTAssertEqual(precomputed, normallyHashed)
    XCTAssertEqual(precomputed.utf8Count, markdown.utf8.count)
    XCTAssertEqual(
      precomputed.parserVersion,
      TatwoAssistantTranscriptCache.defaultParserVersion)
  }

  func testParserVersionIsPartOfKeyAndForcesReparse() {
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8) { markdown in
      parseCount.withLock { $0 += 1 }
      return TatwoAssistantTranscriptPresentation.document(markdown: markdown)
    }
    let first = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-parser",
      markdown: "same source",
      parserVersion: 1)
    let second = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-parser",
      markdown: "same source",
      parserVersion: 2)

    XCTAssertNotEqual(first, second)
    _ = cache.document(for: first, markdown: "same source")
    _ = cache.document(for: first, markdown: "same source")
    _ = cache.document(for: second, markdown: "same source")

    XCTAssertEqual(parseCount.withLock { $0 }, 2)
    XCTAssertNil(cache.cachedDocument(for: first))
    XCTAssertNotNil(cache.cachedDocument(for: second))
    XCTAssertEqual(cache.count, 1)
  }

  func testCacheKeyUsesExactMarkdownWhenFingerprintCollides() {
    let first = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-collision",
      markdown: "first source",
      utf8Count: 12,
      fingerprint: 42)
    let second = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-collision",
      markdown: "other source",
      utf8Count: 12,
      fingerprint: 42)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8)

    XCTAssertNotEqual(first, second)
    let firstRequest = cache.beginRequest(for: first)
    XCTAssertTrue(cache.storeIfCurrent(
      TatwoAssistantTranscriptPresentation.document(markdown: "first source"),
      for: first,
      request: firstRequest))
    let secondRequest = cache.beginRequest(for: second)
    XCTAssertTrue(cache.storeIfCurrent(
      TatwoAssistantTranscriptPresentation.document(markdown: "other source"),
      for: second,
      request: secondRequest))

    XCTAssertNil(cache.cachedDocument(for: first))
    let cached = try! XCTUnwrap(cache.cachedDocument(for: second))
    let firstBlock = try! XCTUnwrap(cached.blocks.first)
    XCTAssertEqual(String(firstBlock.content.characters), "other source")
  }

  func testCacheEvictsLeastRecentlyUsedEntryAtCapacity() {
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 2) { markdown in
      parseCount.withLock { $0 += 1 }
      return TatwoAssistantTranscriptPresentation.document(markdown: markdown)
    }

    _ = cache.document(messageID: "assistant-1", markdown: "One")
    _ = cache.document(messageID: "assistant-2", markdown: "Two")
    _ = cache.document(messageID: "assistant-3", markdown: "Three")
    _ = cache.document(messageID: "assistant-1", markdown: "One")

    XCTAssertEqual(parseCount.withLock { $0 }, 4)
    XCTAssertLessThanOrEqual(cache.count, 2)
  }

  func testRecentAccessProtectsEntryFromNextEviction() {
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 2) { markdown in
      parseCount.withLock { $0 += 1 }
      return TatwoAssistantTranscriptPresentation.document(markdown: markdown)
    }
    let first = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-1",
      markdown: "One")
    let second = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-2",
      markdown: "Two")
    let third = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-3",
      markdown: "Three")

    _ = cache.document(for: first, markdown: "One")
    _ = cache.document(for: second, markdown: "Two")
    XCTAssertNotNil(cache.cachedDocument(for: first))
    _ = cache.document(for: third, markdown: "Three")

    XCTAssertNotNil(cache.cachedDocument(for: first))
    XCTAssertNil(cache.cachedDocument(for: second))
    XCTAssertNotNil(cache.cachedDocument(for: third))
    XCTAssertEqual(parseCount.withLock { $0 }, 3)
    XCTAssertEqual(cache.count, 2)
  }

  func testNewerMarkdownForSameMessageReplacesPriorEntry() {
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8)
    _ = cache.document(messageID: "assistant-1", markdown: "one")
    _ = cache.document(messageID: "assistant-1", markdown: "one two")

    XCTAssertEqual(cache.count, 1)
    XCTAssertGreaterThan(cache.residentByteCount, "one two".utf8.count)
    XCTAssertLessThanOrEqual(
      cache.residentByteCount,
      TatwoAssistantTranscriptCache.defaultMaximumResidentBytes)
  }

  func testCacheEvictsByResidentBytes() {
    let firstMarkdown = String(repeating: "x", count: 600)
    let secondMarkdown = String(repeating: "y", count: 600)
    // The nonallocating estimator intentionally uses a conservative four-byte
    // character allowance plus fixed attributed-run overhead.
    let singleEntryCeiling = 5_000
    let cache = TatwoAssistantTranscriptCache(
      maximumEntryCount: 50,
      maximumResidentBytes: singleEntryCeiling)
    _ = cache.document(
      messageID: "assistant-1",
      markdown: firstMarkdown)
    _ = cache.document(
      messageID: "assistant-2",
      markdown: secondMarkdown)

    XCTAssertEqual(cache.count, 1)
    XCTAssertLessThanOrEqual(cache.residentByteCount, singleEntryCeiling)
    XCTAssertGreaterThan(cache.residentByteCount, firstMarkdown.utf8.count)
    XCTAssertNil(
      cache.cachedDocument(
        for: TatwoAssistantTranscriptCacheKey(
          messageID: "assistant-1",
          markdown: firstMarkdown)))
    XCTAssertNotNil(
      cache.cachedDocument(
        for: TatwoAssistantTranscriptCacheKey(
          messageID: "assistant-2",
          markdown: secondMarkdown)))
  }

  func testShortSourceWithHugeDocumentPayloadBypassesResidency() {
    let hugeMarkdown = """
      | Header A | Header B |
      | --- | --- |
      \(String(repeating: "| **expanded cell** | `payload` |\n", count: 512))
      """
    let hugeDocument =
      TatwoAssistantTranscriptPresentation.document(markdown: hugeMarkdown)
    XCTAssertGreaterThan(hugeDocument.blocks.count, 0)
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let cache = TatwoAssistantTranscriptCache(
      maximumEntryCount: 8,
      maximumResidentBytes: 2_048
    ) { _ in
      parseCount.withLock { $0 += 1 }
      return hugeDocument
    }

    _ = cache.document(messageID: "expanded", markdown: "x")
    _ = cache.document(messageID: "expanded", markdown: "x")

    XCTAssertEqual(parseCount.withLock { $0 }, 2)
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.residentByteCount, 0)
  }

  func testOversizedReplacementRemovesPriorSameMessageEntry() {
    let hugeDocument = TatwoAssistantTranscriptPresentation.document(
      markdown: String(repeating: "**expanded**\n", count: 512))
    let cache = TatwoAssistantTranscriptCache(
      maximumEntryCount: 8,
      maximumResidentBytes: 2_048
    ) { markdown in
      markdown == "small"
        ? TatwoAssistantTranscriptPresentation.document(markdown: markdown)
        : hugeDocument
    }
    let smallKey = TatwoAssistantTranscriptCacheKey(
      messageID: "same-message",
      markdown: "small")
    let hugeKey = TatwoAssistantTranscriptCacheKey(
      messageID: "same-message",
      markdown: "expand")

    _ = cache.document(for: smallKey, markdown: "small")
    XCTAssertEqual(cache.count, 1)
    XCTAssertGreaterThan(cache.residentByteCount, 0)

    _ = cache.document(for: hugeKey, markdown: "expand")

    XCTAssertNil(cache.cachedDocument(for: smallKey))
    XCTAssertNil(cache.cachedDocument(for: hugeKey))
    XCTAssertEqual(cache.count, 0)
    XCTAssertEqual(cache.residentByteCount, 0)
  }

  func testAsyncDocumentParsesOffCallerAndCaches() async {
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8)
    let first = await cache.document(messageID: "assistant-1", markdown: "**Hi**")
    let second = await cache.document(messageID: "assistant-1", markdown: "**Hi**")

    XCTAssertEqual(first, second)
    XCTAssertEqual(cache.count, 1)
    XCTAssertEqual(first.blocks.isEmpty, false)
  }

  func testLongMarkdownUsesOneHundredMillisecondDebounce() {
    let longMarkdown = String(repeating: "a", count: 8 * 1_024 + 1)

    XCTAssertEqual(
      TatwoAssistantTranscriptThrottle.delay(for: longMarkdown),
      .milliseconds(100))
    XCTAssertNil(
      TatwoAssistantTranscriptThrottle.delay(
        for: String(repeating: "a", count: 8 * 1_024)))
    XCTAssertEqual(
      TatwoAssistantTranscriptThrottle.delay(
        utf8Count: longMarkdown.utf8.count),
      .milliseconds(100))
  }

  func testAsyncParseMetadataCanBeStoredWithoutMainActorDocumentWalk() async {
    let markdown = String(repeating: "**metadata** paragraph\n", count: 256)
    let key = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-metadata",
      markdown: markdown)
    let cache = TatwoAssistantTranscriptCache(
      maximumEntryCount: 8,
      maximumResidentBytes: 4 * 1_024 * 1_024)
    let request = cache.beginRequest(for: key)

    let parsed = await cache.parseDocumentWithMetadata(markdown: markdown)
    let result = try! XCTUnwrap(parsed)
    XCTAssertGreaterThan(result.estimatedResidentBytes, markdown.utf8.count)
    XCTAssertTrue(cache.storeIfCurrent(
      result.document,
      documentResidentBytes: result.estimatedResidentBytes,
      for: key,
      request: request))
    XCTAssertNotNil(cache.cachedDocument(for: key))
    XCTAssertGreaterThan(cache.residentByteCount, result.estimatedResidentBytes)
  }

  func testInterleavedAsyncParsesDoNotStoreStaleKeyForSameMessage() async {
    let staleMarkdown = "aaaa"
    let freshMarkdown = "bbbb"
    let startedStale = OSAllocatedUnfairLock(initialState: false)
    let holdStale = OSAllocatedUnfairLock(initialState: true)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8) { markdown in
      if markdown == staleMarkdown {
        startedStale.withLock { $0 = true }
        while holdStale.withLock({ $0 }) {
          Thread.sleep(forTimeInterval: 0.001)
        }
      }
      return TatwoAssistantTranscriptPresentation.document(markdown: markdown)
    }

    let staleKey = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-1",
      markdown: staleMarkdown)
    let freshKey = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-1",
      markdown: freshMarkdown)
    XCTAssertEqual(staleKey.utf8Count, freshKey.utf8Count)
    XCTAssertNotEqual(staleKey.textHash, freshKey.textHash)

    async let staleParsed = cache.document(for: staleKey, markdown: staleMarkdown)
    let staleStartDeadline = Date().addingTimeInterval(2)
    while !startedStale.withLock({ $0 }) {
      if Date() > staleStartDeadline {
        XCTFail("stale parse never left the main actor")
        holdStale.withLock { $0 = false }
        _ = await staleParsed
        return
      }
      await Task.yield()
    }
    _ = await cache.document(for: freshKey, markdown: freshMarkdown)
    holdStale.withLock { $0 = false }
    _ = await staleParsed

    XCTAssertNotNil(cache.cachedDocument(for: freshKey))
    XCTAssertNil(cache.cachedDocument(for: staleKey))
    XCTAssertEqual(cache.count, 1)
    XCTAssertNil(
      cache.latestRequestedGeneration(forMessageID: "assistant-1"))
  }

  func testCancelledAsyncParseDoesNotInsert() async {
    let markdown = "hold-this-parse"
    let started = OSAllocatedUnfairLock(initialState: false)
    let hold = OSAllocatedUnfairLock(initialState: true)
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8) { text in
      if text == markdown {
        started.withLock { $0 = true }
        while hold.withLock({ $0 }) {
          Thread.sleep(forTimeInterval: 0.001)
        }
      }
      return TatwoAssistantTranscriptPresentation.document(markdown: text)
    }
    let key = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-cancel",
      markdown: markdown)

    let task = Task { @MainActor in
      await cache.document(for: key, markdown: markdown)
    }
    let startDeadline = Date().addingTimeInterval(2)
    while !started.withLock({ $0 }) {
      if Date() > startDeadline {
        XCTFail("cancelled parse never left the main actor")
        hold.withLock { $0 = false }
        _ = await task.value
        return
      }
      await Task.yield()
    }
    task.cancel()
    hold.withLock { $0 = false }
    _ = await task.value

    XCTAssertNil(cache.cachedDocument(for: key))
    XCTAssertEqual(cache.count, 0)
  }

  func testStoreIfCurrentRejectsStaleKeyForSameMessage() {
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 8)
    let staleKey = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-1",
      markdown: "old text")
    let currentKey = TatwoAssistantTranscriptCacheKey(
      messageID: "assistant-1",
      markdown: "new text")
    let staleRequest = cache.beginRequest(for: staleKey)
    let currentRequest = cache.beginRequest(for: currentKey)

    let parsed = TatwoAssistantTranscriptPresentation.document(markdown: "old text")
    XCTAssertFalse(cache.storeIfCurrent(
      parsed,
      for: staleKey,
      request: staleRequest))
    XCTAssertEqual(cache.count, 0)
    XCTAssertTrue(cache.storeIfCurrent(
      parsed,
      for: currentKey,
      request: currentRequest))
    XCTAssertEqual(cache.count, 1)
    XCTAssertNotNil(cache.cachedDocument(for: currentKey))
    XCTAssertNil(cache.cachedDocument(for: staleKey))
  }

  func testRequestGenerationsAreFixedSizeBoundedAndCollisionSafe() {
    let cache = TatwoAssistantTranscriptCache(maximumEntryCount: 2)
    let first = TatwoAssistantTranscriptCacheKey(
      messageID: "same",
      markdown: "first source",
      utf8Count: 12,
      fingerprint: 42)
    let second = TatwoAssistantTranscriptCacheKey(
      messageID: "same",
      markdown: "other source",
      utf8Count: 12,
      fingerprint: 42)
    let firstRequest = cache.beginRequest(for: first)
    let secondRequest = cache.beginRequest(for: second)

    XCTAssertFalse(cache.isCurrent(firstRequest, for: first))
    XCTAssertTrue(cache.isCurrent(secondRequest, for: second))
    XCTAssertNotEqual(firstRequest, secondRequest)
    XCTAssertLessThanOrEqual(
      MemoryLayout<TatwoAssistantTranscriptCache.RequestToken>.stride,
      32)

    for index in 0..<64 {
      _ = cache.beginRequest(
        for: TatwoAssistantTranscriptCacheKey(
          messageID: "message-\(index)",
          markdown: String(repeating: "x", count: 4_096)))
    }
    XCTAssertNil(cache.latestRequestedGeneration(forMessageID: "same"))
    XCTAssertNotNil(
      cache.latestRequestedGeneration(forMessageID: "message-63"))
  }
}
