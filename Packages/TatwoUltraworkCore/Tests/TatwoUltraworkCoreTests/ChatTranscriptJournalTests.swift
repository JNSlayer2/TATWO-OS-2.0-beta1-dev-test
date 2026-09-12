import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatTranscriptJournalTests: XCTestCase {
  func testDuplicateReplayIsIdempotentAndConflictingEventIDIsIgnored() throws {
    var journal = ChatTranscriptJournalV1()
    let event = makeEvent(
      eventID: "event-1",
      sequence: 1,
      phase: .running)

    XCTAssertEqual(journal.append(event), .appended)
    XCTAssertEqual(
      journal.append(event),
      .ignored(.duplicateEvent(eventID: "event-1")))

    let conflicting = makeEvent(
      eventID: "event-1",
      sequence: 2,
      phase: .completed)
    XCTAssertEqual(
      journal.append(conflicting),
      .ignored(.conflictingEventID(eventID: "event-1")))

    XCTAssertEqual(journal.events, [event])
    let item = try XCTUnwrap(journal.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1"))
    XCTAssertEqual(item.phase, .running)
    XCTAssertEqual(item.eventIDs, ["event-1"])
    XCTAssertEqual(journal.event(id: "event-1"), event)
    XCTAssertNil(journal.event(id: "missing"))
  }

  func testReconnectReplayDeduplicatesHistoryThenAcceptsNextSequence() throws {
    let start = makeEvent(
      eventID: "event-start",
      sequence: 10,
      phase: .running,
      occurredAt: Date(timeIntervalSince1970: 10))
    let update = makeEvent(
      eventID: "event-update",
      sequence: 11,
      phase: .running,
      occurredAt: Date(timeIntervalSince1970: 11),
      summary: "Compiled targets")
    let completed = makeEvent(
      eventID: "event-complete",
      sequence: 12,
      phase: .completed,
      occurredAt: Date(timeIntervalSince1970: 12),
      summary: "Tests passed")

    var initial = ChatTranscriptJournalV1()
    XCTAssertEqual(initial.replay([start, update]), [.appended, .appended])
    let restored = try ChatTranscriptJournalV1.restoring(
      from: initial.encodedSnapshot())
    var reconnected = restored

    XCTAssertEqual(
      reconnected.replay([start, update, completed]),
      [
        .ignored(.duplicateEvent(eventID: "event-start")),
        .ignored(.duplicateEvent(eventID: "event-update")),
        .appended,
      ])

    let item = try XCTUnwrap(reconnected.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1"))
    XCTAssertEqual(item.phase, .completed)
    XCTAssertEqual(item.lastSequence, 12)
    XCTAssertEqual(item.summary, "Tests passed")
    XCTAssertEqual(reconnected.events.count, 3)
  }

  func testTerminalLatchRejectsLateEventWithoutAdvancingTurnSequence() throws {
    var journal = ChatTranscriptJournalV1()
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "event-1",
      sequence: 1,
      phase: .running)), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "event-2",
      sequence: 2,
      phase: .failed)), .appended)

    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "event-late",
        sequence: 3,
        phase: .running,
        summary: "must not regress")),
      .ignored(.terminalItem(itemID: "item-1", phase: .failed)))

    // Rejected sequence 3 did not poison the turn. A different item may use it.
    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "event-next-item",
        itemID: "item-2",
        sequence: 3,
        kind: .result,
        phase: .completed)),
      .appended)

    let terminal = try XCTUnwrap(journal.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1"))
    XCTAssertEqual(terminal.phase, .failed)
    XCTAssertNil(terminal.summary)
    XCTAssertEqual(terminal.eventIDs, ["event-1", "event-2"])
  }

  func testRemoteHigherAttemptReopensStableTerminalItemAndSurvivesReplay() throws {
    let attempt1 = ChatTranscriptSourceMetadataV1(
      source: "tatwo",
      model: "remote-loop",
      runtime: "tatwo-remote",
      runID: "logical-remote-1",
      attempt: 1)
    let attempt2 = ChatTranscriptSourceMetadataV1(
      source: "tatwo",
      model: "remote-loop",
      runtime: "tatwo-remote",
      runID: "logical-remote-1",
      attempt: 2)
    var journal = ChatTranscriptJournalV1()

    XCTAssertEqual(journal.append(makeEvent(
      eventID: "remote-a1-running",
      sequence: 1,
      kind: .remoteJob,
      phase: .running,
      source: attempt1,
      summary: "attempt 1 running",
      attributes: ["remotePublicState": "執行中"])), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "remote-a1-failed",
      sequence: 2,
      kind: .remoteJob,
      phase: .failed,
      source: attempt1,
      summary: "attempt 1 failed",
      attributes: ["remoteTerminalOutcome": "失敗"])), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "remote-a2-running",
      sequence: 3,
      kind: .remoteJob,
      phase: .running,
      source: attempt2,
      summary: "attempt 2 running",
      attributes: ["remotePublicState": "執行中"])), .appended)
    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "remote-a1-late",
        sequence: 4,
        kind: .remoteJob,
        phase: .running,
        source: attempt1,
        summary: "stale attempt 1")),
      .ignored(.staleAttempt(itemID: "item-1", current: 2, received: 1)))

    let live = try XCTUnwrap(journal.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1"))
    XCTAssertEqual(live.phase, .running)
    XCTAssertEqual(live.source.attempt, 2)
    XCTAssertEqual(live.summary, "attempt 2 running")
    XCTAssertNil(live.attributes["remoteTerminalOutcome"])
    XCTAssertEqual(
      live.eventIDs,
      ["remote-a1-running", "remote-a1-failed", "remote-a2-running"])

    let restored = try ChatTranscriptJournalV1.restoring(
      from: journal.encodedSnapshot())
    let replayed = try XCTUnwrap(restored.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1"))
    XCTAssertEqual(restored.events.count, 3)
    XCTAssertEqual(restored.orderedItems(threadID: "thread-1").count, 1)
    XCTAssertEqual(replayed, live)
  }

  func testRemoteHigherAttemptCannotReopenCompletedItem() throws {
    let attempt1 = ChatTranscriptSourceMetadataV1(
      source: "tatwo",
      model: "remote-loop",
      runtime: "tatwo-remote",
      runID: "logical-remote-completed",
      attempt: 1)
    let attempt2 = ChatTranscriptSourceMetadataV1(
      source: "tatwo",
      model: "remote-loop",
      runtime: "tatwo-remote",
      runID: "logical-remote-completed",
      attempt: 2)
    var journal = ChatTranscriptJournalV1()

    XCTAssertEqual(journal.append(makeEvent(
      eventID: "remote-completed-a1",
      sequence: 1,
      kind: .remoteJob,
      phase: .completed,
      source: attempt1,
      summary: "verified result")), .appended)
    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "remote-running-a2",
        sequence: 2,
        kind: .remoteJob,
        phase: .running,
        source: attempt2,
        summary: "must not reopen")),
      .ignored(.terminalItem(itemID: "item-1", phase: .completed)))

    let item = try XCTUnwrap(journal.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1"))
    XCTAssertEqual(item.phase, .completed)
    XCTAssertEqual(item.source.attempt, 1)
    XCTAssertEqual(item.eventIDs, ["remote-completed-a1"])
  }

  func testStaleSequenceAndLifecycleRegressionAreExplicitIgnoredOutcomes() throws {
    var journal = ChatTranscriptJournalV1()
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "event-5",
      sequence: 5,
      phase: .running)), .appended)

    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "event-4",
        itemID: "other-item",
        sequence: 4,
        phase: .pending)),
      .ignored(.staleSequence(lastAccepted: 5, received: 4)))
    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "event-6",
        sequence: 6,
        phase: .pending)),
      .ignored(.lifecycleRegression(
        itemID: "item-1",
        current: .running,
        received: .pending)))

    XCTAssertEqual(journal.events.map(\.eventID), ["event-5"])
  }

  func testSameItemIDIsIsolatedAcrossTurnsAndThreads() throws {
    var journal = ChatTranscriptJournalV1()
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "turn-a-complete",
      threadID: "thread-a",
      turnID: "turn-a",
      itemID: "shared-item",
      sequence: 1,
      phase: .completed)), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "turn-b-running",
      threadID: "thread-a",
      turnID: "turn-b",
      itemID: "shared-item",
      sequence: 1,
      phase: .running)), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "thread-b-running",
      threadID: "thread-b",
      turnID: "turn-a",
      itemID: "shared-item",
      sequence: 1,
      phase: .pending)), .appended)

    XCTAssertEqual(
      journal.item(
        threadID: "thread-a",
        turnID: "turn-a",
        itemID: "shared-item")?.phase,
      .completed)
    XCTAssertEqual(
      journal.item(
        threadID: "thread-a",
        turnID: "turn-b",
        itemID: "shared-item")?.phase,
      .running)
    XCTAssertEqual(
      journal.item(
        threadID: "thread-b",
        turnID: "turn-a",
        itemID: "shared-item")?.phase,
      .pending)
  }

  func testProviderNeutralMetadataAndRequiredItemKindsAreRetained() throws {
    let providers: [(String, String, String)] = [
      ("codex", "gpt-5.6-codex", "app-server"),
      ("claude", "opus-5", "claude-cli"),
      ("fable", "fable-5", "native-pane"),
      ("grok", "grok-code-fast", "isolated-cli"),
    ]
    var journal = ChatTranscriptJournalV1()

    for (index, provider) in providers.enumerated() {
      let source = ChatTranscriptSourceMetadataV1(
        source: provider.0,
        model: provider.1,
        runtime: provider.2,
        sessionID: "session-\(provider.0)",
        runID: "run-\(provider.0)",
        attempt: UInt64(index + 1))
      XCTAssertEqual(
        journal.append(makeEvent(
          eventID: "event-\(provider.0)",
          turnID: "turn-\(provider.0)",
          itemID: "item-\(provider.0)",
          sequence: 1,
          kind: .tool,
          phase: .completed,
          source: source)),
        .appended)
    }

    let retained = journal.threads
      .flatMap(\.turns)
      .flatMap(\.items)
      .map(\.source)
    XCTAssertEqual(Set(retained.map(\.source)), Set(providers.map(\.0)))
    XCTAssertEqual(Set(retained.map(\.model)), Set(providers.map(\.1)))
    XCTAssertEqual(Set(retained.map(\.runtime)), Set(providers.map(\.2)))

    XCTAssertTrue(Set([
      ChatTranscriptItemKindV1.message,
      ChatTranscriptItemKindV1.reasoningSummary,
      .command,
      .fileChange,
      .search,
      .tool,
      .remoteJob,
      .approval,
      .result,
      .error,
    ]).isSubset(of: Set(ChatTranscriptItemKindV1.allCases)))
  }

  func testOrderedItemsUsesAcceptedChronologyAcrossOpaqueTurnIDs() {
    var journal = ChatTranscriptJournalV1()
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "later",
      turnID: "turn-a",
      itemID: "later-item",
      sequence: 1,
      kind: .result,
      phase: .completed,
      occurredAt: Date(timeIntervalSince1970: 20))), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "earlier",
      turnID: "turn-z",
      itemID: "earlier-item",
      sequence: 1,
      kind: .message,
      phase: .completed,
      occurredAt: Date(timeIntervalSince1970: 10))), .appended)

    XCTAssertEqual(
      journal.orderedItems(threadID: "thread-1").map(\.id),
      ["earlier-item", "later-item"])
  }

  func testReasoningItemPersistsOnlyAUserVisibleSummarySurface() throws {
    var journal = ChatTranscriptJournalV1()
    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "reasoning-summary",
        itemID: "reasoning-1",
        sequence: 1,
        kind: .reasoningSummary,
        phase: .completed,
        title: "Reasoning summary",
        summary: "Compared the two safe implementation options.",
        attributes: ["privateReasoning": "must not persist"])),
      .appended)

    let item = try XCTUnwrap(journal.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "reasoning-1"))
    XCTAssertTrue(item.attributes.isEmpty)
    let data = try journal.encodedSnapshot()
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("Compared the two safe implementation options."))
    XCTAssertFalse(json.contains("chainOfThought"))
    XCTAssertFalse(json.contains("privateReasoning"))
  }

  func testTurnAttestationMetadataRoundTripsWithoutInventingEffectiveEffort() throws {
    let source = ChatTranscriptSourceMetadataV1(
      source: "codex",
      model: "gpt-5.6-luna",
      runtime: "codex-exec",
      sessionID: "session-1",
      runID: "run-1",
      attempt: 1,
      requestedModelID: "gpt-5.6-luna",
      requestedVendorModelID: "gpt-5.6-luna",
      actualCanonicalModel: nil,
      actualVendorModel: nil,
      requestedEffort: .xhigh,
      forwardedEffort: .xhigh,
      effectiveEffortAttestation: .xhigh,
      fallbackCount: nil,
      attestationOutcome: .forwardedAwaitingProvider,
      providerResponseID: nil,
      providerSessionID: nil)

    XCTAssertNil(
      source.effectiveEffortAttestation,
      "forwarded argv/config is not provider proof of effective effort")

    var journal = ChatTranscriptJournalV1()
    XCTAssertEqual(
      journal.append(makeEvent(
        eventID: "attestation-requested",
        sequence: 1,
        phase: .running,
        source: source)),
      .appended)
    let restored = try ChatTranscriptJournalV1.restoring(
      from: journal.encodedSnapshot())
    let roundTripped = try XCTUnwrap(restored.events.first?.source)

    XCTAssertEqual(roundTripped.requestedModelID, "gpt-5.6-luna")
    XCTAssertEqual(roundTripped.requestedVendorModelID, "gpt-5.6-luna")
    XCTAssertEqual(roundTripped.requestedEffort, .xhigh)
    XCTAssertEqual(roundTripped.forwardedEffort, .xhigh)
    XCTAssertNil(roundTripped.actualCanonicalModel)
    XCTAssertNil(roundTripped.actualVendorModel)
    XCTAssertNil(roundTripped.effectiveEffortAttestation)
    XCTAssertNil(roundTripped.fallbackCount)
    XCTAssertEqual(
      roundTripped.attestationOutcome,
      .forwardedAwaitingProvider)
  }

  func testProviderEvidenceCanMonotonicallyCompleteTurnAttestation() throws {
    let requested = ChatTranscriptSourceMetadataV1(
      source: "codex",
      model: "gpt-5.6-luna",
      runtime: "codex-exec",
      sessionID: "session-1",
      runID: "run-1",
      attempt: 1,
      requestedModelID: "gpt-5.6-luna",
      requestedVendorModelID: "gpt-5.6-luna",
      requestedEffort: .xhigh,
      forwardedEffort: .xhigh,
      attestationOutcome: .forwardedAwaitingProvider)
    let verified = ChatTranscriptSourceMetadataV1(
      source: "codex",
      model: "gpt-5.6-luna",
      runtime: "codex-exec",
      sessionID: "session-1",
      runID: "run-1",
      attempt: 1,
      requestedModelID: "gpt-5.6-luna",
      requestedVendorModelID: "gpt-5.6-luna",
      actualCanonicalModel: "gpt-5.6-luna",
      actualVendorModel: "gpt-5.6-luna",
      requestedEffort: .xhigh,
      forwardedEffort: .xhigh,
      effectiveEffortAttestation: .xhigh,
      fallbackCount: 0,
      attestationOutcome: .verified,
      providerResponseID: "response-1",
      providerSessionID: "provider-session-1")
    var journal = ChatTranscriptJournalV1()

    XCTAssertEqual(journal.append(makeEvent(
      eventID: "attestation-running",
      sequence: 1,
      phase: .running,
      source: requested)), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "attestation-completed",
      sequence: 2,
      phase: .completed,
      source: verified)), .appended)

    let item = try XCTUnwrap(journal.item(
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1"))
    XCTAssertEqual(item.source.actualCanonicalModel, "gpt-5.6-luna")
    XCTAssertEqual(item.source.actualVendorModel, "gpt-5.6-luna")
    XCTAssertEqual(item.source.effectiveEffortAttestation, .xhigh)
    XCTAssertEqual(item.source.fallbackCount, 0)
    XCTAssertEqual(item.source.attestationOutcome, .verified)
    XCTAssertEqual(item.source.providerResponseID, "response-1")
    XCTAssertEqual(item.source.providerSessionID, "provider-session-1")
  }

  func testLegacySourceMetadataDecodesWithAttestationFieldsUnknown() throws {
    let legacy = Data(
      """
      {
        "source": "claude",
        "model": "fable-5",
        "runtime": "gateway",
        "sessionID": "legacy-session",
        "runID": "legacy-run",
        "attempt": 1
      }
      """.utf8)
    let decoded = try JSONDecoder().decode(
      ChatTranscriptSourceMetadataV1.self,
      from: legacy)

    XCTAssertNil(decoded.requestedModelID)
    XCTAssertNil(decoded.requestedVendorModelID)
    XCTAssertNil(decoded.actualCanonicalModel)
    XCTAssertNil(decoded.actualVendorModel)
    XCTAssertNil(decoded.requestedEffort)
    XCTAssertNil(decoded.forwardedEffort)
    XCTAssertNil(decoded.effectiveEffortAttestation)
    XCTAssertNil(decoded.fallbackCount)
    XCTAssertNil(decoded.attestationOutcome)
    XCTAssertNil(decoded.providerResponseID)
    XCTAssertNil(decoded.providerSessionID)
  }

  func testJSONRoundTripPreservesProjectionAndUsesDeterministicOrdering() throws {
    var journal = ChatTranscriptJournalV1()
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "z-event",
      threadID: "thread-z",
      turnID: "turn-z",
      itemID: "item-z",
      sequence: 2,
      phase: .completed,
      attributes: ["z": "last", "a": "first"])), .appended)
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "a-event",
      threadID: "thread-a",
      turnID: "turn-a",
      itemID: "item-b",
      sequence: 2,
      phase: .completed)), .appended)

    // Append in valid order in a second turn to exercise item ordering.
    XCTAssertEqual(journal.append(makeEvent(
      eventID: "c-event",
      threadID: "thread-a",
      turnID: "turn-b",
      itemID: "item-b",
      sequence: 2,
      phase: .completed)), .appended)
    // A second journal exercises sequence-based item ordering.
    var ordered = ChatTranscriptJournalV1()
    XCTAssertEqual(ordered.append(makeEvent(
      eventID: "item-a",
      itemID: "item-a",
      sequence: 1,
      phase: .completed)), .appended)
    XCTAssertEqual(ordered.append(makeEvent(
      eventID: "item-b",
      itemID: "item-b",
      sequence: 2,
      phase: .completed)), .appended)

    let first = try journal.encodedSnapshot()
    let second = try journal.encodedSnapshot()
    XCTAssertEqual(first, second)

    let restored = try ChatTranscriptJournalV1.restoring(from: first)
    XCTAssertEqual(restored.snapshot, journal.snapshot)
    XCTAssertEqual(restored.threads.map(\.id), ["thread-a", "thread-z"])
    XCTAssertEqual(
      ordered.turn(threadID: "thread-1", turnID: "turn-1")?.items.map(\.id),
      ["item-a", "item-b"])
    XCTAssertEqual(try restored.encodedSnapshot(), first)
  }

  private func makeEvent(
    eventID: String,
    threadID: String = "thread-1",
    turnID: String = "turn-1",
    itemID: String = "item-1",
    sequence: UInt64,
    kind: ChatTranscriptItemKindV1 = .command,
    phase: ChatTranscriptLifecyclePhaseV1,
    source: ChatTranscriptSourceMetadataV1 = ChatTranscriptSourceMetadataV1(
      source: "codex",
      model: "gpt-5.6-codex",
      runtime: "app-server",
      sessionID: "session-1",
      runID: "run-1",
      attempt: 1),
    occurredAt: Date = Date(timeIntervalSince1970: 1),
    title: String = "Run command",
    summary: String? = nil,
    attributes: [String: String] = [:]
  ) -> ChatTranscriptEventV1 {
    ChatTranscriptEventV1(
      eventID: eventID,
      threadID: threadID,
      turnID: turnID,
      itemID: itemID,
      sequence: sequence,
      kind: kind,
      phase: phase,
      source: source,
      sourceEventType: "\(source.source).item.\(phase.rawValue)",
      occurredAt: occurredAt,
      title: title,
      summary: summary,
      attributes: attributes)
  }
}
