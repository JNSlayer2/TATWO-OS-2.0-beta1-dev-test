import CryptoKit
import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class ChatTranscriptJournalIntegrationTests: XCTestCase {
    func testActivityLifecycleUsesStableItemIDAndDeduplicatesReplay() throws {
        var journal = ChatTranscriptJournalV1()
        let startedAt = Date(timeIntervalSince1970: 100)
        let running = activity(
            status: .running,
            startedAt: startedAt)
        let completed = activity(
            status: .succeeded,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2))

        XCTAssertEqual(
            ChatTranscriptJournalAdapter.append(
                activity: running,
                context: context(),
                to: &journal),
            .appended)
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.append(
                activity: running,
                context: context(),
                to: &journal),
            .ignored(.duplicateEvent(eventID: journal.events[0].eventID)))
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.append(
                activity: completed,
                context: context(),
                to: &journal),
            .appended)

        let item = try XCTUnwrap(
            journal.turn(threadID: "thread-1", turnID: "turn-1")?.items.first)
        XCTAssertEqual(item.kind, .command)
        XCTAssertEqual(item.phase, .completed)
        XCTAssertEqual(item.eventIDs.count, 2)
        XCTAssertEqual(journal.events.map(\.sequence), [1, 2])
    }

    func testActivityAttemptsProduceIsolatedItems() throws {
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: activity(status: .running, attempt: 1),
                context: context(),
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: activity(status: .running, attempt: 2),
                context: context(),
                to: &journal
            ).wasAppended)

        let items = try XCTUnwrap(
            journal.turn(threadID: "thread-1", turnID: "turn-1")?.items)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.source.attempt)), Set([UInt64(1), UInt64(2)]))
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    func testNormalizedReasoningDeltaNeverPersistsRawText() throws {
        var journal = ChatTranscriptJournalV1()
        let privateText =
            "PRIVATE_REASONING_MARKER_7E892EA1_NEVER_PERSIST"

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendReasoningSummary(
                text: privateText,
                rawType: "response.reasoning.delta",
                context: context(),
                to: &journal
            ).wasAppended)

        let data = try journal.encodedSnapshot()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(privateText))
        let item = try XCTUnwrap(
            journal.turn(threadID: "thread-1", turnID: "turn-1")?.items.first)
        XCTAssertEqual(item.kind, .reasoningSummary)
        XCTAssertEqual(item.summary, "思考中")
        XCTAssertTrue(item.attributes.isEmpty)
        let projected = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected.first?.eventKind, .thinking)
        XCTAssertEqual(projected.first?.text, "")
        XCTAssertEqual(projected.first?.status, "completed|思考中")
        XCTAssertFalse(
            projected.contains(where: {
                $0.text.contains(privateText)
                    || ($0.status?.contains(privateText) ?? false)
            }))
    }

    func testActivityThinkingUsesSafeReasoningSummaryPolicy() throws {
        var journal = ChatTranscriptJournalV1()
        let secret = "activity-secret-token"
        let thinking = ChatActivityEventV1(
            id: "thinking-summary",
            kind: .thinking,
            label: "Thinking",
            detail: "Authorization: Bearer \(secret)",
            startedAt: Date(timeIntervalSince1970: 101),
            endedAt: Date(timeIntervalSince1970: 102),
            status: .succeeded,
            turnID: "turn-1",
            sourceType: "response.reasoning.summary")

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: thinking,
                context: context(),
                to: &journal
            ).wasAppended)

        let item = try XCTUnwrap(
            journal.turn(threadID: "thread-1", turnID: "turn-1")?.items.first)
        let json = try XCTUnwrap(
            String(data: journal.encodedSnapshot(), encoding: .utf8))
        XCTAssertEqual(item.kind, .reasoningSummary)
        XCTAssertEqual(item.summary, "思考中")
        XCTAssertFalse(json.contains(secret))
        let projected = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-1",
                from: journal
            ).first)
        XCTAssertEqual(projected.eventKind, .thinking)
        XCTAssertEqual(projected.text, "")
        XCTAssertEqual(projected.status, "completed|思考中")
        XCTAssertFalse(projected.isTranscriptNoise)
    }

    func testStructuredWorkDetailsStayInJournalButMainTranscriptFoldsThem()
        throws
    {
        var journal = ChatTranscriptJournalV1()
        let context = context(
            turnID: "turn-folded-work",
            runID: "run-folded-work")
        let base = Date(timeIntervalSince1970: 110)
        let privateReasoning = "SECRET_REASONING_6F45"
        let rawPayloads = [
            "process --token SECRET_PROCESS_91A2",
            "source dump SECRET_SOURCE_14C8",
            "tool result SECRET_TOOL_7BD0",
        ]
        let activities = [
            ChatActivityEventV1(
                id: "process-step",
                kind: .command,
                label: "Process",
                detail: rawPayloads[0],
                startedAt: base.addingTimeInterval(1),
                endedAt: base.addingTimeInterval(1),
                status: .succeeded,
                turnID: context.turnID,
                sourceType: "command_execution"),
            ChatActivityEventV1(
                id: "source-step",
                kind: .search,
                label: "Source",
                detail: rawPayloads[1],
                startedAt: base.addingTimeInterval(2),
                endedAt: base.addingTimeInterval(2),
                status: .succeeded,
                turnID: context.turnID,
                sourceType: "source_search"),
            ChatActivityEventV1(
                id: "tool-step",
                kind: .toolUse,
                label: "Tool",
                detail: rawPayloads[2],
                startedAt: base.addingTimeInterval(3),
                endedAt: base.addingTimeInterval(3),
                status: .succeeded,
                turnID: context.turnID,
                sourceType: "tool_result"),
        ]

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendReasoningSummary(
                text: privateReasoning,
                rawType: "response.reasoning.delta",
                context: context,
                occurredAt: base,
                to: &journal
            ).wasAppended)
        for activity in activities {
            XCTAssertTrue(
                ChatTranscriptJournalAdapter.append(
                    activity: activity,
                    context: context,
                    to: &journal
                ).wasAppended)
        }
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendResult(
                messageID: "final-plan",
                text: "# Plan\n\nFinal result remains visible.",
                phase: .completed,
                occurredAt: base.addingTimeInterval(4),
                context: context,
                to: &journal
            ).wasAppended)

        let auditItems = journal.orderedItems(threadID: context.threadID)
        for payload in rawPayloads {
            XCTAssertTrue(auditItems.contains { $0.summary == payload })
        }

        let projected = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: context.threadID,
            from: journal)
        XCTAssertEqual(projected.count, 2)
        let thinking = try XCTUnwrap(
            projected.first(where: { $0.eventKind == .thinking }))
        XCTAssertTrue(thinking.text.isEmpty)
        XCTAssertEqual(thinking.status, "completed|思考中")
        XCTAssertEqual(
            projected.first(where: { $0.eventKind == .message })?.text,
            "# Plan\n\nFinal result remains visible.")

        let exposed = projected.map {
            "\($0.text)\n\($0.status ?? "")"
        }.joined(separator: "\n")
        XCTAssertFalse(exposed.contains(privateReasoning))
        for payload in rawPayloads {
            XCTAssertFalse(exposed.contains(payload))
        }

        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: context.turnID,
                workMessages: [thinking],
                turnMessages: projected))
        let accessibilityText = (
            [ChatInlineWorkTimelineSummary.resolve(timeline).compactText]
                + ChatInlineWorkTimelineDetailProjection.rows(
                    for: timeline,
                    isExpanded: true).map(\.label)
        ).joined(separator: "\n")
        XCTAssertFalse(accessibilityText.contains(privateReasoning))
        for payload in rawPayloads {
            XCTAssertFalse(accessibilityText.contains(payload))
        }
    }

    func testCompletedCommandProjectsAsSafeFoldedWorkSummary() throws {
        var journal = ChatTranscriptJournalV1()
        let startedAt = Date(timeIntervalSince1970: 120)

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: activity(
                    status: .running,
                    startedAt: startedAt),
                context: context(),
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: activity(
                    status: .succeeded,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(1)),
                context: context(),
                to: &journal
            ).wasAppended)

        let row = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-1",
                from: journal
            ).first)
        XCTAssertEqual(row.eventKind, .thinking)
        XCTAssertEqual(row.text, "")
        XCTAssertEqual(row.status, "completed|思考中")
        XCTAssertFalse(row.isTranscriptNoise)
    }

    func testToolUseAndStructuredActivityProjectOneConvergingRow() throws {
        var journal = ChatTranscriptJournalV1()
        let startedAt = Date(timeIntervalSince1970: 130)
        let running = activity(
            status: .running,
            startedAt: startedAt)
        let completed = activity(
            status: .succeeded,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2))

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: running,
                context: context(),
                to: &journal
            ).wasAppended)
        let structuredItem = try XCTUnwrap(
            journal.orderedItems(threadID: "thread-1").first {
                $0.attributes["activityID"] == running.id
            })
        let structuredItemID = structuredItem.id
        XCTAssertTrue(
            journal.append(
                legacyToolEvent(
                    eventID: "event-live-legacy-1",
                    itemID: "legacy-live-1",
                    turnID: structuredItemID,
                    parentActivityID: "unrelated-live-1",
                    occurredAt: startedAt)
            ).wasAppended)
        XCTAssertTrue(
            journal.append(
                legacyToolEvent(
                    eventID: "event-live-legacy-2",
                    itemID: "legacy-live-2",
                    turnID: "unrelated-live-2",
                    parentActivityID: "legacy-live-1",
                    occurredAt: startedAt)
            ).wasAppended)
        XCTAssertTrue(
            journal.append(
                legacyToolEvent(
                    eventID: "event-live-legacy-3",
                    itemID: "legacy-live-3",
                    turnID: "legacy-live-2",
                    parentActivityID: "unrelated-live-3",
                    occurredAt: startedAt)
            ).wasAppended)

        var rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "")
        XCTAssertEqual(rows.first?.status, "thinking|思考中")

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: completed,
                context: context(),
                to: &journal
            ).wasAppended)

        rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        let completedStructuredItem = try XCTUnwrap(
            journal.item(
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: structuredItemID))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.id,
            "journal-work:thread-1:turn-1")
        XCTAssertEqual(rows.first?.status, "completed|思考中")
        XCTAssertEqual(completedStructuredItem.phase, .completed)
        XCTAssertEqual(completedStructuredItem.eventIDs.count, 2)
    }

    func testStructuredActivityDoesNotHideDifferentLegacyToolInSameTurnAttempt() throws {
        var journal = ChatTranscriptJournalV1()
        let startedAt = Date(timeIntervalSince1970: 135)
        let unrelatedLegacyTool = ChatMessage(
            id: "turn-1",
            role: .assistant,
            text: "git status",
            status: "completed|git status",
            modelID: "gpt-5.5",
            eventKind: .toolUse,
            runtimeAdapterID: "codex-exec",
            createdAt: startedAt)

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: unrelatedLegacyTool,
                threadID: "thread-1",
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: activity(
                    status: .succeeded,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(1)),
                context: context(),
                to: &journal
            ).wasAppended)

        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.eventKind, .thinking)
        XCTAssertEqual(rows.first?.text, "")
        XCTAssertEqual(rows.first?.status, "completed|思考中")
    }

    func testStructuredActivityDoesNotHideIdentityMatchedLegacyCommandWithoutAncestry()
        throws
    {
        var journal = ChatTranscriptJournalV1()
        let startedAt = Date(timeIntervalSince1970: 138)

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: activity(
                    status: .succeeded,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(1)),
                context: context(),
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "turn-1",
                    role: .assistant,
                    text: "swift test",
                    status: "completed|swift test",
                    modelID: "gpt-5.5",
                    eventKind: .toolUse,
                    runtimeAdapterID: "codex-exec",
                    createdAt: startedAt.addingTimeInterval(1)),
                threadID: "thread-1",
                to: &journal
            ).wasAppended)

        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "")
        XCTAssertEqual(rows.first?.status, "completed|思考中")
        XCTAssertEqual(Set(rows.map(\.createdAt)).count, 1)
    }

    func testStructuredActivitiesSuppressFourGenerationLegacyProjectionAncestry() throws {
        var journal = ChatTranscriptJournalV1()
        let startedAt = Date(timeIntervalSince1970: 140)
        let primary = activity(
            status: .succeeded,
            id: "command-primary",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1))
        let legitimateRepeat = activity(
            status: .succeeded,
            id: "command-legitimate-repeat",
            startedAt: startedAt.addingTimeInterval(2),
            endedAt: startedAt.addingTimeInterval(3))

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: primary,
                context: context(),
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: legitimateRepeat,
                context: context(),
                to: &journal
            ).wasAppended)

        let structuredItems = journal.orderedItems(threadID: "thread-1")
            .filter { $0.attributes["sourceType"] != "tatwo/legacy/tool" }
        var parentID = try XCTUnwrap(
            structuredItems.first {
                $0.attributes["activityID"] == primary.id
            }?.id)
        for generation in 1...4 {
            XCTAssertTrue(
                ChatTranscriptJournalAdapter.append(
                    message: ChatMessage(
                        id: parentID,
                        role: .assistant,
                        text: "swift test",
                        status: "completed|swift test",
                        modelID: "gpt-5.5",
                        eventKind: .toolUse,
                        runtimeAdapterID: "codex-exec",
                        createdAt: startedAt.addingTimeInterval(
                            3 + TimeInterval(generation))),
                    threadID: "thread-1",
                    to: &journal
                ).wasAppended)
            let child = try XCTUnwrap(
                journal.orderedItems(threadID: "thread-1").first {
                    $0.attributes["sourceType"] == "tatwo/legacy/tool"
                        && $0.attributes["activityID"] == parentID
                })
            parentID = child.id
        }

        let allItems = journal.orderedItems(threadID: "thread-1")
        XCTAssertEqual(
            allItems.filter {
                $0.attributes["sourceType"] == "tatwo/legacy/tool"
            }.count,
            4)
        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.eventKind, .thinking)
        XCTAssertEqual(rows.first?.text, "")
        XCTAssertEqual(rows.first?.status, "completed|思考中")
    }

    func testLegacyOnlyFourGenerationAncestryRemainsVisible() throws {
        var journal = ChatTranscriptJournalV1()
        let startedAt = Date(timeIntervalSince1970: 150)
        var parentID = "orphan-legacy-root"
        var legacyItemIDs: [String] = []

        for generation in 1...4 {
            XCTAssertTrue(
                ChatTranscriptJournalAdapter.append(
                    message: ChatMessage(
                        id: parentID,
                        role: .assistant,
                        text: "swift test",
                        status: "completed|swift test",
                        modelID: "gpt-5.5",
                        eventKind: .toolUse,
                        runtimeAdapterID: "codex-exec",
                        createdAt: startedAt.addingTimeInterval(
                            TimeInterval(generation))),
                    threadID: "thread-1",
                    to: &journal
                ).wasAppended)
            let item = try XCTUnwrap(
                journal.orderedItems(threadID: "thread-1").first {
                    $0.attributes["sourceType"] == "tatwo/legacy/tool"
                        && $0.attributes["activityID"] == parentID
                })
            legacyItemIDs.append(item.id)
            parentID = item.id
        }

        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map(\.turnID)), Set([
            "orphan-legacy-root",
            legacyItemIDs[0],
            legacyItemIDs[1],
            legacyItemIDs[2],
        ]))
        XCTAssertTrue(rows.allSatisfy {
            $0.eventKind == .thinking
                && $0.text.isEmpty
                && $0.status == "completed|思考中"
        })
    }

    func testLegacyProjectionSelfCycleRemainsVisible() {
        var journal = ChatTranscriptJournalV1()
        let itemID = "legacy-self-cycle"

        XCTAssertTrue(
            journal.append(
                legacyToolEvent(
                    eventID: "event-self-cycle",
                    itemID: itemID,
                    turnID: "turn-self-cycle",
                    parentActivityID: itemID,
                    occurredAt: Date(timeIntervalSince1970: 160))
            ).wasAppended)

        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.turnID, "turn-self-cycle")
        XCTAssertEqual(rows.first?.text, "")
    }

    func testLegacyProjectionTwoNodeCycleDoesNotHideLaterUnrelatedRepeat() {
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            journal.append(
                legacyToolEvent(
                    eventID: "event-cycle-a",
                    itemID: "legacy-cycle-a",
                    turnID: "turn-cycle-a",
                    parentActivityID: "legacy-cycle-b",
                    occurredAt: Date(timeIntervalSince1970: 170))
            ).wasAppended)
        XCTAssertTrue(
            journal.append(
                legacyToolEvent(
                    eventID: "event-cycle-b",
                    itemID: "legacy-cycle-b",
                    turnID: "turn-cycle-b",
                    parentActivityID: "legacy-cycle-a",
                    occurredAt: Date(timeIntervalSince1970: 171))
            ).wasAppended)
        XCTAssertTrue(
            journal.append(
                legacyToolEvent(
                    eventID: "event-later-repeat",
                    itemID: "legacy-later-repeat",
                    turnID: "turn-later-repeat",
                    parentActivityID: "unrelated-legacy-root",
                    occurredAt: Date(timeIntervalSince1970: 180))
            ).wasAppended)

        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(
            rows.map(\.turnID),
            ["turn-cycle-a", "turn-cycle-b", "turn-later-repeat"])
        XCTAssertTrue(rows.allSatisfy { $0.text.isEmpty })
    }

    func testCompletedNormalizedReasoningProjectsThinkingRow() {
        var journal = ChatTranscriptJournalV1()
        let privateText =
            "PRIVATE_REASONING_MARKER_01AF_PROJECTED_NEVER"

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendReasoningSummary(
                text: privateText,
                rawType: "response.reasoning.delta",
                context: context(),
                to: &journal
            ).wasAppended)

        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-1",
            from: journal)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.eventKind, .thinking)
        XCTAssertEqual(rows.first?.text, "")
        XCTAssertEqual(rows.first?.status, "completed|思考中")
        XCTAssertFalse(rows.contains(where: { $0.text.contains(privateText) }))
    }

    func testResultAndErrorProjectionPreservesTerminalLifecycle() throws {
        var journal = ChatTranscriptJournalV1()
        let now = Date(timeIntervalSince1970: 200)

        for (turnID, phase) in [
            ("completed-turn", ChatTranscriptLifecyclePhaseV1.completed),
            ("failed-turn", .failed),
            ("cancelled-turn", .cancelled),
        ] {
            XCTAssertTrue(
                ChatTranscriptJournalAdapter.appendResult(
                    messageID: "\(turnID)-message",
                    text: "answer",
                    phase: phase,
                    occurredAt: now,
                    context: context(turnID: turnID),
                    to: &journal
                ).wasAppended)
        }
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendError(
                message: "runtime exploded",
                context: context(turnID: "error-turn"),
                occurredAt: now,
                to: &journal
            ).wasAppended)

        XCTAssertEqual(
            journal.turn(threadID: "thread-1", turnID: "completed-turn")?.items.first?.phase,
            .completed)
        XCTAssertEqual(
            journal.turn(threadID: "thread-1", turnID: "failed-turn")?.items.first?.phase,
            .failed)
        XCTAssertEqual(
            journal.turn(threadID: "thread-1", turnID: "cancelled-turn")?.items.first?.phase,
            .cancelled)
        let error = try XCTUnwrap(
            journal.turn(threadID: "thread-1", turnID: "error-turn")?.items.first)
        XCTAssertEqual(error.kind, .error)
        XCTAssertEqual(error.phase, .failed)
    }

    func testStoredMessageReconnectReplayIsIdempotent() {
        let now = Date(timeIntervalSince1970: 300)
        let messages = [
            ChatMessage(
                id: "user",
                role: .user,
                text: "question",
                createdAt: now),
            ChatMessage(
                id: "result",
                role: .assistant,
                text: "answer",
                status: "done",
                modelID: "gpt-5.5",
                createdAt: now),
            ChatMessage(
                id: "failure",
                role: .assistant,
                text: "failed",
                status: "failed",
                modelID: "claude-sonnet-5",
                eventKind: .failure,
                createdAt: now),
            ChatMessage(
                id: "tool",
                role: .assistant,
                text: "swift test",
                status: "tool",
                modelID: "fable5",
                eventKind: .toolUse,
                createdAt: now),
            ChatMessage(
                id: "thinking",
                role: .assistant,
                text: "folded summary",
                status: "folded",
                modelID: "grok-build",
                eventKind: .thinking,
                createdAt: now),
        ]
        var journal = ChatTranscriptJournalV1()
        let fallback = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.5",
            runtime: "codex-exec")

        let first = ChatTranscriptJournalAdapter.replay(
            messages: messages,
            threadID: "thread-reconnect",
            fallbackSource: fallback,
            into: &journal)
        let second = ChatTranscriptJournalAdapter.replay(
            messages: messages,
            threadID: "thread-reconnect",
            fallbackSource: fallback,
            into: &journal)

        XCTAssertEqual(first.filter(\.wasAppended).count, 5)
        XCTAssertEqual(second.filter(\.wasAppended).count, 0)
        XCTAssertEqual(journal.events.count, 5)
    }

    func testLegacyMigrationPreservesWhitelistedRolesAndProjectsChronologically() {
        let records = [
            TatwoNativeChatStoredMessage(
                id: "assistant",
                role: "assistant",
                text: "answer",
                modelID: "gpt-5.5",
                createdAt: Date(timeIntervalSince1970: 20)),
            TatwoNativeChatStoredMessage(
                id: "user",
                role: "user",
                text: "question",
                createdAt: Date(timeIntervalSince1970: 10)),
            TatwoNativeChatStoredMessage(
                id: "system",
                role: "system",
                text: "receipt",
                status: "receipt",
                createdAt: Date(timeIntervalSince1970: 30)),
        ]
        var journal = ChatTranscriptJournalV1()

        let migration = ChatTranscriptJournalAdapter.replay(
            storedMessages: records,
            threadID: "thread-canonical",
            into: &journal)
        let projection = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-canonical",
            from: journal)

        XCTAssertTrue(migration.isComplete)
        XCTAssertEqual(migration.appendedCount, 3)
        XCTAssertEqual(projection.map(\.id), ["user", "assistant", "system"])
        XCTAssertEqual(projection.map(\.role), [.user, .assistant, .system])
        XCTAssertEqual(projection.map(\.text), ["question", "answer", "receipt"])
    }

    func testLegacyMigrationRejectsUnknownRoleFailClosed() {
        let records = [
            TatwoNativeChatStoredMessage(
                id: "unknown-role",
                role: "developer",
                text: "must not be silently promoted"),
        ]
        var journal = ChatTranscriptJournalV1()

        let migration = ChatTranscriptJournalAdapter.replay(
            storedMessages: records,
            threadID: "thread-invalid-role",
            into: &journal)

        XCTAssertFalse(migration.isComplete)
        XCTAssertEqual(migration.rejectedMessageIDs, ["unknown-role"])
        XCTAssertTrue(journal.events.isEmpty)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-invalid-role",
                from: journal
            ).isEmpty)
    }

    func testLegacyMigrationAcceptsEveryStoredRoleAlias() {
        let aliases = [
            ("you", ChatMessageRole.user),
            ("cli", .assistant),
            ("codex", .assistant),
            ("claude", .assistant),
            ("os", .system),
            ("work-os", .system),
        ]
        var journal = ChatTranscriptJournalV1()

        let migration = ChatTranscriptJournalAdapter.replay(
            storedMessages: aliases.enumerated().map { index, entry in
                TatwoNativeChatStoredMessage(
                    id: "alias-\(index)",
                    role: entry.0,
                    text: entry.0,
                    createdAt: Date(timeIntervalSince1970: Double(index)))
            },
            threadID: "thread-aliases",
            into: &journal)

        XCTAssertTrue(migration.isComplete)
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-aliases",
                from: journal
            ).map(\.role),
            aliases.map(\.1))
    }

    func testDuplicateLegacyIDConflictHardFailsWithoutPublishingCandidate() {
        let createdAt = Date(timeIntervalSince1970: 25)
        var journal = ChatTranscriptJournalV1()
        let original = TatwoNativeChatStoredMessage(
            id: "same-id",
            role: "assistant",
            text: "same answer",
            modelID: "gpt-5.5",
            createdAt: createdAt)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.replay(
                storedMessages: [original],
                threadID: "thread-conflict",
                into: &journal
            ).isComplete)
        let before = journal

        let migration = ChatTranscriptJournalAdapter.replay(
            storedMessages: [
                TatwoNativeChatStoredMessage(
                    id: original.id,
                    role: original.role,
                    text: original.text,
                    modelID: "claude-sonnet-5",
                    createdAt: createdAt),
            ],
            threadID: "thread-conflict",
            into: &journal)

        XCTAssertFalse(migration.isComplete)
        XCTAssertEqual(migration.rejectedMessageIDs, [original.id])
        guard case .ignored(.conflictingEventID) = migration.outcomes.first else {
            return XCTFail("same legacy ID with different source metadata must conflict")
        }
        XCTAssertEqual(journal, before)
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-conflict",
                from: journal
            ).first?.modelID,
            original.modelID)
    }

    func testQueuedSecondUserOrderingMatchesLiveAndRelaunchProjection() throws {
        let firstUser = ChatMessage(
            id: "first-user",
            role: .user,
            text: "first",
            createdAt: Date(timeIntervalSince1970: 10))
        let firstAssistant = ChatMessage(
            id: "first-assistant",
            role: .assistant,
            text: "answer",
            modelID: "gpt-5.5",
            createdAt: Date(timeIntervalSince1970: 20))
        let queuedSecondUser = ChatMessage(
            id: "queued-second-user",
            role: .user,
            text: "second",
            status: "queued",
            createdAt: Date(timeIntervalSince1970: 30))
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: firstUser,
            threadID: "thread-order",
            to: &journal
        ).wasAppended)
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: queuedSecondUser,
            threadID: "thread-order",
            to: &journal
        ).wasAppended)
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: firstAssistant,
            threadID: "thread-order",
            to: &journal
        ).wasAppended)

        let liveIDs = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-order",
            from: journal
        ).map(\.id)
        let relaunched = try ChatTranscriptJournalV1.restoring(
            from: journal.encodedSnapshot())
        let relaunchedIDs = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-order",
            from: relaunched
        ).map(\.id)

        XCTAssertEqual(liveIDs, ["first-user", "first-assistant", "queued-second-user"])
        XCTAssertEqual(relaunchedIDs, liveIDs)
        XCTAssertEqual(
            journal.orderedItems(threadID: "thread-order")
                .first(where: { $0.turnID == firstAssistant.id })?
                .createdAt,
            firstAssistant.createdAt)
    }

    func testLegacyThinkingProjectionNeverExposesPrivateReasoningText() throws {
        let privateText =
            "PRIVATE_REASONING_MARKER_LEGACY_90D1_NEVER_PERSIST"
        var journal = ChatTranscriptJournalV1()

        let migration = ChatTranscriptJournalAdapter.replay(
            storedMessages: [
                TatwoNativeChatStoredMessage(
                    id: "thinking",
                    role: "assistant",
                    text: privateText,
                    status: "thinking",
                    modelID: "gpt-5.5",
                    eventKind: .thinking),
            ],
            threadID: "thread-reasoning",
            into: &journal)
        let projection = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-reasoning",
            from: journal)
        let json = try XCTUnwrap(
            String(data: journal.encodedSnapshot(), encoding: .utf8))

        XCTAssertTrue(migration.isComplete)
        XCTAssertEqual(projection.count, 1)
        XCTAssertEqual(projection.first?.eventKind, .thinking)
        XCTAssertEqual(projection.first?.text, "")
        XCTAssertEqual(projection.first?.status, "completed|思考中")
        XCTAssertFalse(
            projection.contains(where: {
                $0.text.contains(privateText)
                    || ($0.status?.contains(privateText) ?? false)
            }))
        XCTAssertFalse(json.contains(privateText))
    }

    func testQueuedUserLifecycleProjectsCompletedStatusAsCleared() {
        let queued = ChatMessage(
            id: "queued-user",
            role: .user,
            text: "run this next",
            status: "queued",
            eventKind: .message,
            createdAt: Date(timeIntervalSince1970: 10))
        var completed = queued
        completed.status = nil
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: queued,
                threadID: "thread-queue",
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: completed,
                threadID: "thread-queue",
                to: &journal
            ).wasAppended)

        let projection = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-queue",
            from: journal)
        XCTAssertEqual(projection.count, 1)
        XCTAssertEqual(projection[0].id, queued.id)
        XCTAssertNil(projection[0].status)
    }

    func testMetadataPersistenceScrubsLegacyTranscriptPayloads() {
        let discussion = TatwoNativeDiscussion(
            title: "child",
            inheritedSnapshot: "",
            messages: [
                TatwoNativeChatStoredMessage(role: "assistant", text: "child answer"),
            ])
        let standalone = TatwoNativeChatThread(
            title: "standalone",
            discussions: [discussion],
            messages: [
                TatwoNativeChatStoredMessage(role: "user", text: "standalone question"),
            ])
        let projectThread = TatwoNativeChatThread(
            title: "project",
            messages: [
                TatwoNativeChatStoredMessage(role: "assistant", text: "project answer"),
            ])
        let document = TatwoNativeChatStoreDocument(
            threads: [standalone],
            projects: [
                TatwoNativeChatProject(
                    name: "project",
                    workdir: "/tmp/project",
                    threads: [projectThread]),
            ])

        let scrubbed = ChatTranscriptJournalAdapter
            .removingLegacyTranscriptPayloads(from: document)

        XCTAssertNil(scrubbed.threads[0].messages)
        XCTAssertTrue(scrubbed.threads[0].discussions[0].messages.isEmpty)
        XCTAssertNil(scrubbed.projects[0].threads[0].messages)
    }

    func testLivePartialFailureAndReconnectReplayShareStableErrorEvent() throws {
        let messageID = "failure-message"
        let now = Date(timeIntervalSince1970: 350)
        var journal = ChatTranscriptJournalV1()
        let message = ChatMessage(
            id: messageID,
            role: .assistant,
            text: "partial visible answer\nconnection closed before the response completed",
            status: "failed",
            modelID: "fable5",
            eventKind: .failure,
            createdAt: now)

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: message,
                threadID: "thread-1",
                to: &journal
            ).wasAppended)

        let replay = ChatTranscriptJournalAdapter.replay(
            messages: [message],
            threadID: "thread-1",
            fallbackSource: context().source,
            into: &journal)

        XCTAssertEqual(replay.count, 1)
        guard case .ignored(.duplicateEvent) = replay[0] else {
            return XCTFail("relaunch replay must resolve to the live error event")
        }
        let turn = try XCTUnwrap(
            journal.turn(threadID: "thread-1", turnID: messageID))
        XCTAssertEqual(turn.items.filter { $0.kind == .error }.count, 1)
        XCTAssertEqual(journal.events.filter { $0.kind == .error }.count, 1)
    }

    func testDiskStoreRoundTripsSnapshotJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-journal-\(UUID().uuidString)", isDirectory: true)
        let store = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                activity: activity(status: .succeeded),
                context: context(),
                to: &journal
            ).wasAppended)

        try store.save(journal)

        XCTAssertEqual(try store.load(), journal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testUserMessageAppendCanonicalizesTransportPromptBeforeJournalWrite() throws {
        let raw = """
            [Hidden TATWO Chat interface contract]
            private interface
            [/Hidden TATWO Chat interface contract]

            Keep only this visible request.
            """
        let message = ChatMessage(
            id: "user-sanitized",
            role: .user,
            text: raw,
            eventKind: .message,
            createdAt: Date(timeIntervalSince1970: 100))
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: message,
                threadID: "thread-1",
                to: &journal
            ).wasAppended)
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-1",
                from: journal).map(\.text),
            ["Keep only this visible request."])
        XCTAssertFalse(
            try String(decoding: journal.encodedSnapshot(), as: UTF8.self)
                .contains("[Hidden TATWO"))
    }

    func testDiskLoadMigratesExistingRawPromptWithBackupAndDirectReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let store = ChatTranscriptJournalDiskStore(fileURL: fileURL)
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        let occurredAt = Date(timeIntervalSince1970: 200)
        var raw = ChatTranscriptJournalV1()

        let hiddenRequest = ChatTranscriptEventV1(
            eventID: "raw-hidden-event",
            threadID: "thread-1",
            turnID: "raw-hidden-turn",
            itemID: "raw-hidden-item",
            sequence: 1,
            kind: .message,
            phase: .completed,
            source: source,
            sourceEventType: "codex/response_item/message",
            occurredAt: occurredAt,
            title: "User message",
            summary: """
                [Hidden TATWO Computer Host contract — do not quote]
                <TATWO_COMPUTER_ACTION>private example</TATWO_COMPUTER_ACTION>
                [/Hidden TATWO Computer Host contract]

                Keep the visible host request.
                """,
            attributes: [
                "messageID": "raw-hidden-turn",
                "role": "user",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
                "status": "",
            ])
        let delegated = ChatTranscriptEventV1(
            eventID: "raw-delegation-event",
            threadID: "thread-1",
            turnID: "raw-delegation-turn",
            itemID: "raw-delegation-item",
            sequence: 1,
            kind: .message,
            phase: .completed,
            source: source,
            sourceEventType: "codex/response_item/message",
            occurredAt: occurredAt.addingTimeInterval(1),
            title: "User message",
            summary: """
                <codex_delegation>
                  <source_thread_id>019fb652-a553-7890-b177-b939073e4f0d</source_thread_id>
                  <input>Keep the delegated request.</input>
                </codex_delegation>
                """,
            attributes: [
                "messageID": "raw-delegation-turn",
                "role": "user",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
                "status": "",
            ])
        let internalOnly = ChatTranscriptEventV1(
            eventID: "raw-internal-only-event",
            threadID: "thread-1",
            turnID: "raw-internal-only-turn",
            itemID: "raw-internal-only-item",
            sequence: 1,
            kind: .message,
            phase: .completed,
            source: source,
            occurredAt: occurredAt.addingTimeInterval(2),
            title: "User message",
            summary: """
                [Hidden Codex-style Goal state]
                private goal
                [/Hidden Codex-style Goal state]
                """,
            attributes: [
                "messageID": "raw-internal-only-turn",
                "role": "user",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
                "status": "",
            ])
        let unrelated = ChatTranscriptEventV1(
            eventID: "unrelated-event",
            threadID: "thread-1",
            turnID: "unrelated-turn",
            itemID: "unrelated-item",
            sequence: 1,
            kind: .result,
            phase: .completed,
            source: source,
            occurredAt: occurredAt.addingTimeInterval(3),
            title: "Result",
            summary: "Unrelated assistant result",
            attributes: [
                "messageID": "unrelated-turn",
                "role": "assistant",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
            ])
        for event in [hiddenRequest, delegated, internalOnly, unrelated] {
            XCTAssertTrue(raw.append(event).wasAppended)
        }
        let originalBytes = try raw.encodedSnapshot()
        try originalBytes.write(to: fileURL, options: [.atomic])

        let migrated = try store.load()
        let migratedBytes = try Data(contentsOf: fileURL)
        let migratedText = String(decoding: migratedBytes, as: UTF8.self)
        let migratedByID = Dictionary(
            uniqueKeysWithValues: migrated.events.map { ($0.eventID, $0) })

        XCTAssertEqual(Set(migratedByID.keys), [
            "raw-hidden-event",
            "raw-delegation-event",
            "unrelated-event",
        ])
        XCTAssertEqual(migrated.events.map(\.sequence), [1, 1, 1])
        XCTAssertEqual(
            migratedByID["raw-hidden-event"]?.occurredAt,
            occurredAt)
        XCTAssertEqual(
            migratedByID["raw-hidden-event"]?.attributes,
            hiddenRequest.attributes)
        XCTAssertEqual(
            migratedByID["raw-hidden-event"]?.summary,
            "Keep the visible host request.")
        XCTAssertEqual(
            migratedByID["raw-delegation-event"]?.summary,
            "Keep the delegated request.")
        XCTAssertEqual(
            migratedByID["unrelated-event"]?.summary,
            "Unrelated assistant result")
        XCTAssertFalse(migratedText.contains("[Hidden"))
        XCTAssertFalse(migratedText.contains("<codex_delegation>"))
        XCTAssertFalse(migratedText.contains("TATWO_COMPUTER_ACTION"))

        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        let repairDirectories = try FileManager.default.contentsOfDirectory(
            at: repairRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        XCTAssertEqual(repairDirectories.count, 1)
        let repairDirectory = try XCTUnwrap(repairDirectories.first)
        XCTAssertEqual(
            try Data(contentsOf: repairDirectory.appendingPathComponent("journal.json")),
            originalBytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repairDirectory
                    .appendingPathComponent("migration-receipt.json").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repairDirectory
                    .appendingPathComponent(
                        "migration-receipt.prepared.json").path))
        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: repairDirectory.appendingPathComponent(
                        "migration-receipt.json")))
                as? [String: Any])
        XCTAssertEqual(receipt["status"] as? String, "completed")

        let firstCanonicalBytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(try store.load(), migrated)
        XCTAssertEqual(try Data(contentsOf: fileURL), firstCanonicalBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: repairRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]).count,
            1,
            "an idempotent second load must not create another backup")
    }

    func testSaveMergingRawPreMigrationJournalCannotRestoreTransportPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-remerge-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let store = ChatTranscriptJournalDiskStore(fileURL: fileURL)
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var raw = ChatTranscriptJournalV1()
        let event = ChatTranscriptEventV1(
            eventID: "raw-remerge-event",
            threadID: "thread-1",
            turnID: "raw-remerge-turn",
            itemID: "raw-remerge-item",
            sequence: 1,
            kind: .message,
            phase: .completed,
            source: source,
            sourceEventType: "codex/response_item/message",
            occurredAt: Date(timeIntervalSince1970: 300),
            title: "User message",
            summary: """
                [Hidden TATWO Chat interface contract]
                private interface
                [/Hidden TATWO Chat interface contract]

                Keep the visible remerge request.
                """,
            attributes: [
                "messageID": "raw-remerge-turn",
                "role": "user",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
                "status": "",
            ])
        XCTAssertTrue(raw.append(event).wasAppended)
        try raw.encodedSnapshot().write(to: fileURL, options: [.atomic])

        let migrated = try store.load()
        let persisted = try store.saveMerging(raw)
        let persistedText = String(
            decoding: try Data(contentsOf: fileURL),
            as: UTF8.self)

        XCTAssertEqual(persisted, migrated)
        XCTAssertEqual(
            persisted.events.map(\.summary),
            ["Keep the visible remerge request."])
        XCTAssertFalse(persistedText.contains("private interface"))
        XCTAssertFalse(persistedText.contains("[Hidden TATWO"))
    }

    func testMigrationBackupFailureLeavesCanonicalBytesUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-backup-failure-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let store = ChatTranscriptJournalDiskStore(fileURL: fileURL)
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var raw = ChatTranscriptJournalV1()
        let event = ChatTranscriptEventV1(
            eventID: "raw-backup-failure-event",
            threadID: "thread-1",
            turnID: "raw-backup-failure-turn",
            itemID: "raw-backup-failure-item",
            sequence: 1,
            kind: .message,
            phase: .completed,
            source: source,
            sourceEventType: "codex/response_item/message",
            occurredAt: Date(timeIntervalSince1970: 400),
            title: "User message",
            summary: """
                [Hidden Codex-style Goal state]
                private goal
                [/Hidden Codex-style Goal state]

                Keep the visible request.
                """,
            attributes: [
                "messageID": "raw-backup-failure-turn",
                "role": "user",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
                "status": "",
            ])
        XCTAssertTrue(raw.append(event).wasAppended)
        let originalBytes = try raw.encodedSnapshot()
        try originalBytes.write(to: fileURL, options: [.atomic])
        try Data("not-a-directory".utf8).write(
            to: directory.appendingPathComponent("chat-repair-backups"),
            options: [.atomic])

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
    }

    func testCanonicalReplacementFailureLeavesRawJournalAndOnlyPreparedReceipt() throws {
        enum SyntheticWriteError: Error {
            case failed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-replacement-failure-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let store = ChatTranscriptJournalDiskStore(
            fileURL: fileURL,
            canonicalSnapshotWriter: { _, _ in
                throw SyntheticWriteError.failed
            })
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var raw = ChatTranscriptJournalV1()
        let event = ChatTranscriptEventV1(
            eventID: "raw-replacement-failure-event",
            threadID: "thread-1",
            turnID: "raw-replacement-failure-turn",
            itemID: "raw-replacement-failure-item",
            sequence: 1,
            kind: .message,
            phase: .completed,
            source: source,
            sourceEventType: "codex/response_item/message",
            occurredAt: Date(timeIntervalSince1970: 450),
            title: "User message",
            summary: """
                [Hidden TATWO Chat interface contract]
                private interface
                [/Hidden TATWO Chat interface contract]

                Keep the visible request.
                """,
            attributes: [
                "messageID": "raw-replacement-failure-turn",
                "role": "user",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
                "status": "",
            ])
        XCTAssertTrue(raw.append(event).wasAppended)
        let originalBytes = try raw.encodedSnapshot()
        try originalBytes.write(to: fileURL, options: [.atomic])

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        let firstDirectories = try FileManager.default.contentsOfDirectory(
            at: repairRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        let repairDirectory = try XCTUnwrap(firstDirectories.first)
        XCTAssertEqual(firstDirectories.count, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: repairDirectory.appendingPathComponent(
                    "journal.json")),
            originalBytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repairDirectory.appendingPathComponent(
                    "migration-receipt.prepared.json").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repairDirectory.appendingPathComponent(
                    "migration-receipt.json").path))
        let preparedReceipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: repairDirectory.appendingPathComponent(
                        "migration-receipt.prepared.json")))
                as? [String: Any])
        XCTAssertEqual(preparedReceipt["status"] as? String, "prepared")

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: repairRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]).count,
            1,
            "same original SHA must reuse one backup directory on retry")
    }

    func testCanonicalReplacementReadbackMismatchRecoversFromPreparedBackup()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-readback-recovery-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var raw = ChatTranscriptJournalV1()
        XCTAssertTrue(
            raw.append(ChatTranscriptEventV1(
                eventID: "raw-readback-recovery-event",
                threadID: "thread-1",
                turnID: "raw-readback-recovery-turn",
                itemID: "raw-readback-recovery-item",
                sequence: 1,
                kind: .message,
                phase: .completed,
                source: source,
                sourceEventType: "codex/response_item/message",
                occurredAt: Date(timeIntervalSince1970: 475),
                title: "User message",
                summary: """
                    [Hidden TATWO Chat interface contract]
                    private interface
                    [/Hidden TATWO Chat interface contract]

                    Keep the visible recovery request.
                    """,
                attributes: [
                    "messageID": "raw-readback-recovery-turn",
                    "role": "user",
                    "eventKind": TatwoNativeChatEventKind.message.rawValue,
                    "status": "",
                ])
            ).wasAppended)
        let originalBytes = try raw.encodedSnapshot()
        try originalBytes.write(to: fileURL, options: [.atomic])
        let mismatchingStore = ChatTranscriptJournalDiskStore(
            fileURL: fileURL,
            canonicalSnapshotWriter: { _, _ in
                // Returning success without replacing the raw canonical file
                // must not be accepted as a committed sanitizer migration.
            })

        XCTAssertThrowsError(try mismatchingStore.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)

        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        let repairDirectory = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: repairRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
                .first)
        let preparedURL = repairDirectory.appendingPathComponent(
            "migration-receipt.prepared.json")
        let completedURL = repairDirectory.appendingPathComponent(
            "migration-receipt.json")
        XCTAssertEqual(
            try Data(
                contentsOf: repairDirectory.appendingPathComponent(
                    "journal.json")),
            originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedURL.path))

        let recovered = try ChatTranscriptJournalDiskStore(
            fileURL: fileURL
        ).load()

        XCTAssertEqual(
            recovered.events.map(\.summary),
            ["Keep the visible recovery request."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path))
        XCTAssertEqual(
            try Data(
                contentsOf: repairDirectory.appendingPathComponent(
                    "journal.json")),
            originalBytes)
        let canonicalText = String(
            decoding: try Data(contentsOf: fileURL),
            as: UTF8.self)
        XCTAssertFalse(canonicalText.contains("private interface"))
        XCTAssertFalse(canonicalText.contains("[Hidden TATWO"))
    }

    func testPreparedSanitizerReceiptRecoversInvalidCanonicalAndQuarantinesBytes()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-invalid-recovery-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let invalidBytes = Data("invalid-canonical-after-writer-success".utf8)
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var raw = ChatTranscriptJournalV1()
        XCTAssertTrue(
            raw.append(ChatTranscriptEventV1(
                eventID: "raw-invalid-recovery-event",
                threadID: "thread-1",
                turnID: "raw-invalid-recovery-turn",
                itemID: "raw-invalid-recovery-item",
                sequence: 1,
                kind: .message,
                phase: .completed,
                source: source,
                sourceEventType: "codex/response_item/message",
                occurredAt: Date(timeIntervalSince1970: 485),
                title: "User message",
                summary: """
                    [Hidden Codex-style Goal state]
                    private recovery goal
                    [/Hidden Codex-style Goal state]

                    Keep the invalid recovery request.
                    """,
                attributes: [
                    "messageID": "raw-invalid-recovery-turn",
                    "role": "user",
                    "eventKind": TatwoNativeChatEventKind.message.rawValue,
                    "status": "",
                ])
            ).wasAppended)
        let originalBytes = try raw.encodedSnapshot()
        try originalBytes.write(to: fileURL, options: [.atomic])
        let invalidWriterStore = ChatTranscriptJournalDiskStore(
            fileURL: fileURL,
            canonicalSnapshotWriter: { _, url in
                try invalidBytes.write(to: url, options: [.atomic])
            })

        XCTAssertThrowsError(try invalidWriterStore.load())
        XCTAssertEqual(try Data(contentsOf: fileURL), invalidBytes)

        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        let repairDirectory = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: repairRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
                .first)
        let backupURL = repairDirectory.appendingPathComponent("journal.json")
        let preparedURL = repairDirectory.appendingPathComponent(
            "migration-receipt.prepared.json")
        let completedURL = repairDirectory.appendingPathComponent(
            "migration-receipt.json")
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedURL.path))

        let recovered = try ChatTranscriptJournalDiskStore(
            fileURL: fileURL
        ).load()

        XCTAssertEqual(
            recovered.events.map(\.summary),
            ["Keep the invalid recovery request."])
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path))
        let quarantineURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter {
                $0.lastPathComponent.hasPrefix("journal.json.unexpected-")
                    && $0.pathExtension == "quarantine"
            }
        XCTAssertEqual(quarantineURLs.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantineURLs.first)),
            invalidBytes)
        let canonicalText = String(
            decoding: try Data(contentsOf: fileURL),
            as: UTF8.self)
        XCTAssertFalse(canonicalText.contains("private recovery goal"))
        XCTAssertFalse(canonicalText.contains("[Hidden Codex-style"))
    }

    func testMultiplePreparedSanitizerReceiptsFailClosedWithoutChoosingDirectoryOrder()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-ambiguous-prepared-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let canonicalBytes = Data("ambiguous-canonical-evidence".utf8)
        try canonicalBytes.write(to: fileURL, options: [.atomic])
        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: repairRoot,
            withIntermediateDirectories: true)

        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var backups: [(url: URL, data: Data)] = []
        var preparedReceipts: [(url: URL, data: Data)] = []
        for index in 1 ... 2 {
            let fixture = try makePreparedSanitizerFixture(
                canonicalURL: fileURL,
                repairRoot: repairRoot,
                index: index,
                source: source)
            backups.append((fixture.backupURL, fixture.backupData))
            preparedReceipts.append(
                (fixture.preparedURL, fixture.preparedData))
        }
        let repairTreeBefore = try fileTreeSnapshot(at: repairRoot)

        XCTAssertThrowsError(
            try ChatTranscriptJournalDiskStore(fileURL: fileURL).load()
        ) { error in
            guard let diskError =
                error as? ChatTranscriptJournalDiskStoreError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            guard case .mergeRejected = diskError else {
                return XCTFail("unexpected disk store error: \(diskError)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), canonicalBytes)
        for backup in backups {
            XCTAssertEqual(try Data(contentsOf: backup.url), backup.data)
        }
        for receipt in preparedReceipts {
            XCTAssertEqual(try Data(contentsOf: receipt.url), receipt.data)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: receipt.url.deletingLastPathComponent()
                        .appendingPathComponent("migration-receipt.json").path))
        }
        let quarantineURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "quarantine" }
        XCTAssertTrue(quarantineURLs.isEmpty)
        XCTAssertEqual(
            try fileTreeSnapshot(at: repairRoot),
            repairTreeBefore)
    }

    func testMalformedPreparedReceiptBeforeOrAfterValidCandidateNeverMutatesEvidence()
        throws
    {
        for malformedSortsBeforeValid in [true, false] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "chat-journal-sanitizer-malformed-order-\(UUID().uuidString)",
                    isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("journal.json")
            let canonicalBytes = Data(
                "malformed-order-canonical-\(malformedSortsBeforeValid)".utf8)
            try canonicalBytes.write(to: fileURL, options: [.atomic])
            let repairRoot = directory.appendingPathComponent(
                "chat-repair-backups",
                isDirectory: true)
            try FileManager.default.createDirectory(
                at: repairRoot,
                withIntermediateDirectories: true)
            let source = ChatTranscriptSourceMetadataV1(
                source: "codex",
                model: "gpt-5.6-luna",
                runtime: "codex-app-mirror",
                runID: "mirror-run")
            let validFixture = try makePreparedSanitizerFixture(
                canonicalURL: fileURL,
                repairRoot: repairRoot,
                index: malformedSortsBeforeValid ? 4 : 5,
                source: source)
            let malformedDirectory = repairRoot.appendingPathComponent(
                malformedSortsBeforeValid
                    ? "sanitizer-v1-!malformed-before"
                    : "sanitizer-v1-zz-malformed-after",
                isDirectory: true)
            try FileManager.default.createDirectory(
                at: malformedDirectory,
                withIntermediateDirectories: true)
            let malformedReceiptURL = malformedDirectory.appendingPathComponent(
                "migration-receipt.prepared.json")
            let malformedReceiptData =
                Data("{\"schema\":\"broken\"".utf8)
            try malformedReceiptData.write(
                to: malformedReceiptURL,
                options: [.atomic])
            let validDirectory =
                validFixture.preparedURL.deletingLastPathComponent()
            if malformedSortsBeforeValid {
                XCTAssertLessThan(
                    malformedDirectory.path,
                    validDirectory.path)
            } else {
                XCTAssertGreaterThan(
                    malformedDirectory.path,
                    validDirectory.path)
            }
            let repairTreeBefore = try fileTreeSnapshot(at: repairRoot)

            XCTAssertThrowsError(
                try ChatTranscriptJournalDiskStore(fileURL: fileURL).load()
            ) { error in
                guard let diskError =
                    error as? ChatTranscriptJournalDiskStoreError
                else {
                    return XCTFail("unexpected error: \(error)")
                }
                guard case .mergeRejected = diskError else {
                    return XCTFail(
                        "unexpected disk store error: \(diskError)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: fileURL), canonicalBytes)
            XCTAssertEqual(
                try Data(contentsOf: validFixture.backupURL),
                validFixture.backupData)
            XCTAssertEqual(
                try Data(contentsOf: validFixture.preparedURL),
                validFixture.preparedData)
            XCTAssertEqual(
                try Data(contentsOf: malformedReceiptURL),
                malformedReceiptData)
            XCTAssertEqual(
                try fileTreeSnapshot(at: repairRoot),
                repairTreeBefore)
            let quarantineURLs =
                try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "quarantine" }
            XCTAssertTrue(quarantineURLs.isEmpty)
        }
    }

    func testSoleValidPreparedReceiptRestoresMissingCanonicalBeforeMigration()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-missing-canonical-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: repairRoot,
            withIntermediateDirectories: true)
        let fixture = try makePreparedSanitizerFixture(
            canonicalURL: fileURL,
            repairRoot: repairRoot,
            index: 6,
            source: ChatTranscriptSourceMetadataV1(
                source: "codex",
                model: "gpt-5.6-luna",
                runtime: "codex-app-mirror",
                runID: "mirror-run"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path))

        let recovered = try ChatTranscriptJournalDiskStore(
            fileURL: fileURL
        ).load()

        XCTAssertEqual(
            recovered.events.map(\.summary),
            ["Prepared backup 6"])
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            fixture.authoritativeSanitizedData)
        XCTAssertEqual(
            try Data(contentsOf: fixture.backupURL),
            fixture.backupData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.preparedURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.preparedURL.deletingLastPathComponent()
                    .appendingPathComponent("migration-receipt.json").path))
        let quarantineURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [])
            .filter { $0.pathExtension == "quarantine" }
        XCTAssertTrue(quarantineURLs.isEmpty)
    }

    func testForgedPreparedSanitizerReceiptCannotFinalizeArbitraryCanonicalBytes()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-forged-prepared-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: repairRoot,
            withIntermediateDirectories: true)
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")

        var arbitraryCanonical = ChatTranscriptJournalV1()
        XCTAssertTrue(
            arbitraryCanonical.append(ChatTranscriptEventV1(
                eventID: "forged-canonical-event",
                threadID: "thread-1",
                turnID: "forged-canonical-turn",
                itemID: "forged-canonical-item",
                sequence: 1,
                kind: .result,
                phase: .completed,
                source: source,
                sourceEventType: "codex/response_item/message",
                occurredAt: Date(timeIntervalSince1970: 499),
                title: "Result",
                summary: "Arbitrary decodable canonical evidence",
                attributes: [
                    "messageID": "forged-canonical-turn",
                    "role": "assistant",
                    "eventKind": TatwoNativeChatEventKind.message.rawValue,
                ])
            ).wasAppended)
        let canonicalBytes = try arbitraryCanonical.encodedSnapshot()
        try canonicalBytes.write(to: fileURL, options: [.atomic])
        let fixture = try makePreparedSanitizerFixture(
            canonicalURL: fileURL,
            repairRoot: repairRoot,
            index: 3,
            source: source,
            sanitizedSHA256Override: sha256Hex(canonicalBytes))
        let repairTreeBefore = try fileTreeSnapshot(at: repairRoot)

        XCTAssertNotEqual(
            sha256Hex(fixture.authoritativeSanitizedData),
            sha256Hex(canonicalBytes))
        XCTAssertThrowsError(
            try ChatTranscriptJournalDiskStore(fileURL: fileURL).load()
        ) { error in
            guard let diskError =
                error as? ChatTranscriptJournalDiskStoreError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            guard case .mergeRejected = diskError else {
                return XCTFail("unexpected disk store error: \(diskError)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), canonicalBytes)
        XCTAssertEqual(
            try Data(contentsOf: fixture.backupURL),
            fixture.backupData)
        XCTAssertEqual(
            try Data(contentsOf: fixture.preparedURL),
            fixture.preparedData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.preparedURL.deletingLastPathComponent()
                    .appendingPathComponent("migration-receipt.json").path))
        let quarantineURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "quarantine" }
        XCTAssertTrue(quarantineURLs.isEmpty)
        XCTAssertEqual(
            try fileTreeSnapshot(at: repairRoot),
            repairTreeBefore)
    }

    func testCompletedReceiptWriteFailureRecoversOnRelaunch() throws {
        enum SyntheticWriteError: Error {
            case failed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-completed-receipt-failure-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var raw = ChatTranscriptJournalV1()
        for index in 0 ..< 72 {
            let turnID = "raw-completed-receipt-failure-turn-\(index)"
            XCTAssertTrue(
                raw.append(ChatTranscriptEventV1(
                    eventID:
                        "raw-completed-receipt-failure-event-\(index)",
                    threadID: index < 24 ? "thread-1" : "thread-2",
                    turnID: turnID,
                    itemID:
                        "raw-completed-receipt-failure-item-\(index)",
                    sequence: 1,
                    kind: .message,
                    phase: .completed,
                    source: source,
                    occurredAt: Date(
                        timeIntervalSince1970: 460 + TimeInterval(index)),
                    title: "User message",
                    summary: """
                        [Hidden TATWO Chat interface contract]
                        private interface \(index)
                        [/Hidden TATWO Chat interface contract]

                        Keep visible request \(index).
                        """,
                    attributes: [
                        "messageID": turnID,
                        "role": "user",
                        "eventKind":
                            TatwoNativeChatEventKind.message.rawValue,
                        "status": "",
                    ])
                ).wasAppended)
        }
        let originalBytes = try raw.encodedSnapshot()
        try originalBytes.write(to: fileURL, options: [.atomic])
        let failingStore = ChatTranscriptJournalDiskStore(
            fileURL: fileURL,
            migrationReceiptWriter: { data, url in
                if url.lastPathComponent == "migration-receipt.json" {
                    throw SyntheticWriteError.failed
                }
                try data.write(to: url, options: [.atomic])
            })

        XCTAssertThrowsError(try failingStore.load())
        let sanitizedBytes = try Data(contentsOf: fileURL)
        XCTAssertNotEqual(sanitizedBytes, originalBytes)
        XCTAssertFalse(
            String(decoding: sanitizedBytes, as: UTF8.self)
                .contains("private interface"))
        let expectedSanitizedJournal =
            try ChatTranscriptJournalV1.restoring(from: sanitizedBytes)
        XCTAssertEqual(expectedSanitizedJournal.events.count, 72)
        let expectedEventIDs =
            expectedSanitizedJournal.events.map(\.eventID)
        let expectedMessageIDs =
            expectedSanitizedJournal.events.compactMap {
                $0.attributes["messageID"]
            }
        XCTAssertEqual(Set(expectedEventIDs).count, 72)
        XCTAssertEqual(Set(expectedMessageIDs).count, 72)

        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        let repairDirectories =
            try FileManager.default.contentsOfDirectory(
                at: repairRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        XCTAssertEqual(repairDirectories.count, 1)
        let repairDirectory = try XCTUnwrap(
            repairDirectories.first)
        let backupURL = repairDirectory.appendingPathComponent("journal.json")
        let preparedURL = repairDirectory.appendingPathComponent(
            "migration-receipt.prepared.json")
        let completedURL = repairDirectory.appendingPathComponent(
            "migration-receipt.json")
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedURL.path))
        let preparedData = try Data(contentsOf: preparedURL)
        var expectedCompletedReceipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: preparedData)
                as? [String: Any])
        expectedCompletedReceipt["status"] = "completed"

        let recovered = try ChatTranscriptJournalDiskStore(
            fileURL: fileURL).load()
        XCTAssertEqual(recovered, expectedSanitizedJournal)
        XCTAssertEqual(recovered.events.map(\.eventID), expectedEventIDs)
        XCTAssertEqual(
            recovered.events.compactMap { $0.attributes["messageID"] },
            expectedMessageIDs)
        XCTAssertEqual(try Data(contentsOf: fileURL), sanitizedBytes)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path))
        let completedData = try Data(contentsOf: completedURL)
        XCTAssertEqual(
            try XCTUnwrap(
                try JSONSerialization.jsonObject(with: completedData)
                    as? [String: Any]) as NSDictionary,
            expectedCompletedReceipt as NSDictionary)
        let completedRepairTree = try fileTreeSnapshot(at: repairDirectory)

        let secondStore = ChatTranscriptJournalDiskStore(fileURL: fileURL)
        let secondColdStart = try secondStore.load()
        XCTAssertEqual(secondColdStart, expectedSanitizedJournal)
        try secondStore.save(secondColdStart)
        let thirdColdStart =
            try ChatTranscriptJournalDiskStore(fileURL: fileURL).load()
        XCTAssertEqual(thirdColdStart, expectedSanitizedJournal)
        XCTAssertEqual(thirdColdStart.events.count, 72)
        XCTAssertEqual(try Data(contentsOf: fileURL), sanitizedBytes)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedURL.path))
        XCTAssertEqual(try Data(contentsOf: completedURL), completedData)
        XCTAssertEqual(
            try fileTreeSnapshot(at: repairDirectory),
            completedRepairTree)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: repairDirectory,
                includingPropertiesForKeys: nil,
                options: [])
                .filter { $0.lastPathComponent == "migration-receipt.json" }
                .count,
            1)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [])
                .filter { $0.pathExtension == "quarantine" }
                .isEmpty)
    }

    func testPreparedReceiptRemovalFailureRecoversOnRelaunch() throws {
        enum SyntheticRemoveError: Error {
            case failed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-prepared-remove-failure-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.6-luna",
            runtime: "codex-app-mirror",
            runID: "mirror-run")
        var raw = ChatTranscriptJournalV1()
        let event = ChatTranscriptEventV1(
            eventID: "raw-prepared-remove-failure-event",
            threadID: "thread-1",
            turnID: "raw-prepared-remove-failure-turn",
            itemID: "raw-prepared-remove-failure-item",
            sequence: 1,
            kind: .message,
            phase: .completed,
            source: source,
            occurredAt: Date(timeIntervalSince1970: 470),
            title: "User message",
            summary: """
                [Hidden Codex-style Goal state]
                private goal
                [/Hidden Codex-style Goal state]

                Keep the visible request.
                """,
            attributes: [
                "messageID": "raw-prepared-remove-failure-turn",
                "role": "user",
                "eventKind": TatwoNativeChatEventKind.message.rawValue,
                "status": "",
            ])
        XCTAssertTrue(raw.append(event).wasAppended)
        try raw.encodedSnapshot().write(to: fileURL, options: [.atomic])
        let failingStore = ChatTranscriptJournalDiskStore(
            fileURL: fileURL,
            migrationFileRemover: { url in
                if url.lastPathComponent
                    == "migration-receipt.prepared.json"
                {
                    throw SyntheticRemoveError.failed
                }
                try FileManager.default.removeItem(at: url)
            })

        XCTAssertThrowsError(try failingStore.load())
        let repairRoot = directory.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        let repairDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: repairRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]).first)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repairDirectory.appendingPathComponent(
                    "migration-receipt.prepared.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repairDirectory.appendingPathComponent(
                    "migration-receipt.json").path))

        let recovered = try ChatTranscriptJournalDiskStore(
            fileURL: fileURL).load()
        XCTAssertEqual(
            recovered.events.map(\.summary),
            ["Keep the visible request."])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repairDirectory.appendingPathComponent(
                    "migration-receipt.prepared.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repairDirectory.appendingPathComponent(
                    "migration-receipt.json").path))
    }

    func testMigrationPreservesLegitimateActivityThatMentionsTransportMarkers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-sanitizer-activity-literals-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let source = ChatTranscriptSourceMetadataV1(
            source: "codex",
            model: "gpt-5.5",
            runtime: "codex-exec",
            runID: "diagnostic-run")
        let commandSummary =
            #"/bin/zsh -lc 'rg -n "\[Hidden TATWO|<codex_delegation>" .'"#
        let resultSummary =
            "診斷結果只引用 `[Hidden TATWO ...]` 與 `<codex_delegation>` 名稱。"
        var journal = ChatTranscriptJournalV1()
        for event in [
            ChatTranscriptEventV1(
                eventID: "literal-command",
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "command-item",
                sequence: 1,
                kind: .command,
                phase: .completed,
                source: source,
                occurredAt: Date(timeIntervalSince1970: 500),
                title: "Command",
                summary: commandSummary),
            ChatTranscriptEventV1(
                eventID: "literal-result",
                threadID: "thread-1",
                turnID: "turn-1",
                itemID: "result-item",
                sequence: 2,
                kind: .result,
                phase: .completed,
                source: source,
                occurredAt: Date(timeIntervalSince1970: 501),
                title: "Result",
                summary: resultSummary),
        ] {
            XCTAssertTrue(journal.append(event).wasAppended)
        }

        try store.save(journal)
        let loaded = try store.load()

        XCTAssertEqual(loaded.events.map(\.summary), [commandSummary, resultSummary])
    }

    func testSaveReplacesExistingSnapshotInsteadOfMerging() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-replace-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var first = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendError(
                message: "old snapshot",
                context: context(turnID: "turn-old"),
                occurredAt: Date(timeIntervalSince1970: 100),
                to: &first
            ).wasAppended)
        try store.save(first)
        var replacement = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendError(
                message: "replacement snapshot",
                context: context(turnID: "turn-replacement"),
                occurredAt: Date(timeIntervalSince1970: 200),
                to: &replacement
            ).wasAppended)

        try store.save(replacement)

        XCTAssertEqual(try store.load(), replacement)
        XCTAssertEqual(try store.load().events.map(\.turnID), ["turn-replacement"])
    }

    func testSaveMergingReturnsDiskCanonicalJournalForSecondMergeWithSubmillisecondDate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-canonical-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        // This exact Foundation Date changes by one ULP after the journal's
        // millisecondsSince1970 encode/decode boundary.
        let submillisecondDate = Date(
            timeIntervalSinceReferenceDate: Double(bitPattern: 0x41c80f176e085575))
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendError(
                message: "canonical disk state",
                context: context(),
                occurredAt: submillisecondDate,
                to: &journal
            ).wasAppended)

        var persisted = try store.saveMerging(journal)

        XCTAssertEqual(persisted, try store.load())
        XCTAssertNotEqual(
            persisted.events.first?.occurredAt,
            submillisecondDate,
            "the first save must return the disk-canonical Date, not the sub-ms in-memory value")
        XCTAssertEqual(
            try persisted.encodedSnapshot(),
            try journal.encodedSnapshot())
        XCTAssertEqual(
            try Data(contentsOf: store.fileURL),
            try persisted.encodedSnapshot())

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.appendError(
                message: "second durable event",
                context: context(turnID: "turn-after-canonical-save"),
                occurredAt: submillisecondDate.addingTimeInterval(1),
                to: &persisted
            ).wasAppended)

        let secondPersisted = try store.saveMerging(persisted)

        XCTAssertEqual(secondPersisted, try store.load())
        XCTAssertEqual(secondPersisted.events.count, 2)
        XCTAssertEqual(
            Set(secondPersisted.events.map(\.turnID)),
            Set(["turn-1", "turn-after-canonical-save"]))
    }

    func testCorruptDiskSnapshotMovesOriginalBytesToUniqueQuarantine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-journal-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let corruptBytes = Data("not-valid-journal-json".utf8)
        try corruptBytes.write(to: fileURL)

        let loaded = try ChatTranscriptJournalDiskStore(fileURL: fileURL).load()

        XCTAssertEqual(loaded, ChatTranscriptJournalV1())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let quarantineURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix("journal.json.invalid-")
                    && $0.pathExtension == "quarantine"
            }
        XCTAssertEqual(quarantineURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(quarantineURLs.first)), corruptBytes)
    }

    @MainActor
    func testSaveFailureDoesNotPublishUndurableJournal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-journal-save-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let blockingParent = directory.appendingPathComponent("not-a-directory")
        let blockerBytes = Data("keep".utf8)
        try blockerBytes.write(to: blockingParent)
        let transcriptStore = ChatTranscriptJournalDiskStore(
            fileURL: blockingParent.appendingPathComponent("journal.json"))
        let model = makeModel(directory: directory, transcriptStore: transcriptStore)
        let before = model.chatTranscriptJournal

        model.mutateTranscriptJournal {
            ChatTranscriptJournalAdapter.appendError(
                message: "must not appear durable",
                context: self.context(),
                to: &$0)
        }

        XCTAssertEqual(model.chatTranscriptJournal, before)
        XCTAssertEqual(try Data(contentsOf: blockingParent), blockerBytes)
    }

    @MainActor
    func testCoalescedMutationKeepsMemoryAheadOfDiskUntilFlush() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-coalesce-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let store = ChatTranscriptJournalDiskStore(fileURL: fileURL)
        let model = makeModel(directory: directory, transcriptStore: store)

        XCTAssertTrue(model.mutateTranscriptJournal(persist: .coalesced) {
            ChatTranscriptJournalAdapter.appendError(
                message: "coalesced-stream-event",
                context: self.context(),
                to: &$0)
        })
        XCTAssertFalse(model.chatTranscriptJournal.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        model.flushCoalescedTranscriptJournal()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try store.load().events.count, 1)
    }

    @MainActor
    func testImmediateMutationAfterCoalescedFlushUsesDiskCanonicalJournal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-coalesce-canonical-\(UUID().uuidString)",
                isDirectory: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let store = ChatTranscriptJournalDiskStore(fileURL: fileURL)
        let model = makeModel(directory: directory, transcriptStore: store)
        let submillisecondDate = Date(
            timeIntervalSinceReferenceDate: Double(bitPattern: 0x41c80f176e085575))

        XCTAssertTrue(model.mutateTranscriptJournal(persist: .coalesced) {
            ChatTranscriptJournalAdapter.appendError(
                message: "coalesced-stream-event",
                context: self.context(),
                occurredAt: submillisecondDate,
                to: &$0)
        })
        model.flushCoalescedTranscriptJournal()

        XCTAssertTrue(model.mutateTranscriptJournal {
            ChatTranscriptJournalAdapter.appendError(
                message: "next-immediate-event",
                context: self.context(turnID: "turn-after-flush"),
                occurredAt: submillisecondDate.addingTimeInterval(1),
                to: &$0)
        })
        XCTAssertEqual(try store.load().events.count, 2)
    }

    @MainActor
    func testJournalWriteFailureDoesNotPublishTerminalUIFirst() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-terminal-save-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(title: "terminal gate")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocker)
        let model = makeModel(
            store: nativeStore,
            transcriptStore: ChatTranscriptJournalDiskStore(
                fileURL: blocker.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)

        let inFlight = ChatMessage(
            id: "assistant-terminal",
            role: .assistant,
            text: "visible partial",
            status: "streaming",
            modelID: "gpt-5.5",
            createdAt: Date(timeIntervalSince1970: 500))
        var terminal = inFlight
        terminal.status = nil
        model.messages = [inFlight]

        XCTAssertFalse(model.commitTranscriptTerminalMessage(terminal))
        XCTAssertEqual(model.messages, [inFlight])
        XCTAssertTrue(model.chatTranscriptJournal.events.isEmpty)
    }

    @MainActor
    func testColdStartWithUnknownRunnerAuthorityPreservesPendingAndRunningRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-orphan-cold-start-\(UUID().uuidString)", isDirectory: true)
        let thread = TatwoNativeChatThread(title: "orphan")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var journal = ChatTranscriptJournalV1()
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: ChatMessage(
                id: "pending-user",
                role: .user,
                text: "queued",
                status: "queued"),
            threadID: threadKey,
            to: &journal
        ).wasAppended)
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: ChatMessage(
                id: "running-assistant",
                role: .assistant,
                text: "",
                status: "streaming",
                modelID: "gpt-5.5"),
            threadID: threadKey,
            to: &journal
        ).wasAppended)
        try journalStore.save(journal)

        let model = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)

        let phases = model.chatTranscriptJournal
            .orderedItems(threadID: threadKey)
            .map(\.phase)
        XCTAssertEqual(phases, [.pending, .running])
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadKey,
                from: model.chatTranscriptJournal
            ).map(\.status),
            ["queued", "streaming"])
        XCTAssertEqual(
            try journalStore.load().encodedSnapshot(),
            try model.chatTranscriptJournal.encodedSnapshot())
    }

    @MainActor
    func testAuthoritativeSnapshotWithoutReclaimTokenPreservesColdStartRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-authoritative-orphan-cold-start-\(UUID().uuidString)",
                isDirectory: true)
        let thread = TatwoNativeChatThread(title: "authoritative orphan")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var journal = ChatTranscriptJournalV1()
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: ChatMessage(
                id: "authoritative-running-assistant",
                role: .assistant,
                text: "",
                status: "streaming",
                modelID: "gpt-5.5"),
            threadID: threadKey,
            to: &journal
        ).wasAppended)
        try journalStore.save(journal)

        let model = makeModel(
            store: nativeStore,
            transcriptStore: journalStore,
            runnerAuthorityDiscoverer: StaticChatRunnerAuthorityDiscoverer(
                snapshot: .authoritative(
                    activeRunIDs: [],
                    reclaimTokens: [])))
        try await waitForInitialStoreLoad(model)

        XCTAssertEqual(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .map(\.phase),
            [.running])
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadKey,
                from: model.chatTranscriptJournal
            ).map(\.status),
            ["streaming"])
    }

    @MainActor
    func testExactRevisionBoundReclaimTokenCancelsMatchingColdStartRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-reclaim-token-cold-start-\(UUID().uuidString)",
                isDirectory: true)
        let thread = TatwoNativeChatThread(title: "reclaim token")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var journal = ChatTranscriptJournalV1()
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let messageID = "reclaimable-running-assistant"
        let instanceID = UUID()
        let token = ChatRunnerReclaimToken(
            runID: "message:\(messageID)",
            attempt: nil,
            instanceID: instanceID,
            revision: 7)
        let context = ChatTranscriptJournalContext(
            threadID: threadKey,
            turnID: messageID,
            runID: token.runID,
            source: ChatTranscriptSourceMetadataV1(
                source: "codex",
                model: "gpt-5.5",
                runtime: "codex-exec",
                runID: token.runID,
                attempt: nil,
                runnerInstanceID: instanceID,
                runnerRevision: token.revision))
        XCTAssertTrue(ChatTranscriptJournalAdapter.appendResult(
            messageID: messageID,
            text: "",
            phase: .running,
            occurredAt: Date(timeIntervalSince1970: 7_000),
            context: context,
            to: &journal
        ).wasAppended)
        try journalStore.save(journal)

        let model = makeModel(
            store: nativeStore,
            transcriptStore: journalStore,
            runnerAuthorityDiscoverer: StaticChatRunnerAuthorityDiscoverer(
                snapshot: .authoritative(
                    activeRunIDs: [],
                    reclaimTokens: [token])))
        try await waitForInitialStoreLoad(model)

        XCTAssertEqual(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .map(\.phase),
            [.cancelled])
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadKey,
                from: model.chatTranscriptJournal
            ).map(\.status),
            ["stopped"])
    }

    func testReclaimTokenInstanceOrRevisionMismatchPreservesColdStartRow() throws {
        let instanceID = UUID()
        let runID = "run-exact-reclaim"
        let messageID = "assistant-exact-reclaim"
        let context = ChatTranscriptJournalContext(
            threadID: "thread-exact-reclaim",
            turnID: messageID,
            runID: runID,
            source: ChatTranscriptSourceMetadataV1(
                source: "codex",
                model: "gpt-5.5",
                runtime: "codex-exec",
                runID: runID,
                attempt: 2,
                runnerInstanceID: instanceID,
                runnerRevision: 11))

        for token in [
            ChatRunnerReclaimToken(
                runID: runID,
                attempt: 2,
                instanceID: UUID(),
                revision: 11),
            ChatRunnerReclaimToken(
                runID: runID,
                attempt: 2,
                instanceID: instanceID,
                revision: 12),
        ] {
            var journal = ChatTranscriptJournalV1()
            XCTAssertTrue(ChatTranscriptJournalAdapter.appendResult(
                messageID: messageID,
                text: "",
                phase: .running,
                occurredAt: Date(timeIntervalSince1970: 7_100),
                context: context,
                to: &journal
            ).wasAppended)

            XCTAssertTrue(ChatTranscriptJournalAdapter.cancelColdStartOrphans(
                activeRunIDs: [],
                reclaimTokens: [token],
                in: &journal
            ).isEmpty)
            XCTAssertEqual(
                journal.orderedItems(threadID: context.threadID).map(\.phase),
                [.running])
        }
    }

    @MainActor
    func testModelSelectionDuringActiveTurnIsQueuedForNextTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-model-selection-\(UUID().uuidString)",
                isDirectory: true)
        let model = makeModel(
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")))
        model.selectedModel = "gpt-5.5"
        model.isRunning = true

        model.setSingleModel("fable5")

        XCTAssertEqual(model.selectedModel, "gpt-5.5")
        XCTAssertEqual(model.pendingModelID, "fable5")
        XCTAssertEqual(
            model.modelPickerRouteLabel,
            "GPT-5.5 · 下一輪 fable5")

        model.isRunning = false
        model.applyPendingModelSelectionIfPossible()

        XCTAssertEqual(model.selectedModel, "fable5")
        XCTAssertNil(model.pendingModelID)
    }

    @MainActor
    func testNarrativeModelRoleMentionsDoNotMutateLoopsConfigOrSelectedSendRoute() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-narrative-route-atomicity-\(UUID().uuidString)",
                isDirectory: true)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_STATE_DIR": directory.path,
            ],
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: directory))
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        model.mutateSelectedThread { thread in
            thread.isPlanModeEnabled = true
            thread.loopsConfig = TatwoNativeThreadLoopsConfig(
                scenarioID: "general-xxl-fable5-sol",
                mode: .xxl,
                identitySummary: "Fable5 主導，Sol 協作",
                tokenBudget: "test",
                primaryModelID: "fable-5",
                secondaryModelID: "gpt-5.6-terra")
        }
        model.setSingleModel("gpt-5.6-sol")
        model.isRunning = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let loopsConfigBefore = try encoder.encode(
            XCTUnwrap(model.activeLoopsConfig))

        model.prompt = """
        這一輪只讓目前 UI 已選的 Sol 回答。Fable5 仍是 Work OS 主導，
        Terra 只是副審；不要啟動 sub，也不要改協作設定。
        """
        model.send()

        XCTAssertEqual(
            try encoder.encode(XCTUnwrap(model.activeLoopsConfig)),
            loopsConfigBefore)
        XCTAssertEqual(model.selectedModel, "gpt-5.6-sol")
        XCTAssertNil(model.pendingModelID)
        XCTAssertEqual(model.chatQueue.count, 1)
        let queued = try XCTUnwrap(model.chatQueue.last)
        XCTAssertEqual(queued.dispatchSnapshot.routeID, "gpt-5.6-sol")
        XCTAssertEqual(
            queued.dispatchSnapshot.canonicalModelID,
            "gpt-5.6-sol")
    }

    @MainActor
    func testExplicitTatwoUltraworkMutatesCollaborationButKeepsSelectedSendRoute() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-explicit-route-atomicity-\(UUID().uuidString)",
                isDirectory: true)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_STATE_DIR": directory.path,
            ],
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: directory))
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        model.mutateSelectedThread { thread in
            thread.isPlanModeEnabled = true
            thread.loopsConfig = TatwoNativeThreadLoopsConfig(
                scenarioID: "general-xxl-fable5-sol",
                mode: .xxl,
                identitySummary: "Fable5 主導，Sol 協作",
                tokenBudget: "test",
                primaryModelID: "fable-5",
                secondaryModelID: "gpt-5.6-terra")
        }
        model.setSingleModel("gpt-5.6-sol")
        model.isRunning = true

        model.prompt =
            "$tatwo-ultrawork mode=XXL，opus5 主導，sonnet5 副審"
        model.send()

        XCTAssertEqual(model.activeLoopsConfig?.primaryModelID, "opus-5")
        XCTAssertEqual(model.activeLoopsConfig?.secondaryModelID, "sonnet-5")
        XCTAssertEqual(model.selectedModel, "gpt-5.6-sol")
        XCTAssertEqual(model.pendingModelID, "opus5")
        XCTAssertEqual(model.chatQueue.count, 1)
        let queued = try XCTUnwrap(model.chatQueue.last)
        XCTAssertEqual(queued.dispatchSnapshot.routeID, "gpt-5.6-sol")
        XCTAssertEqual(
            queued.dispatchSnapshot.canonicalModelID,
            "gpt-5.6-sol")
    }

    func testActiveTurnRouteAttributionPrefersSnapshotThenPersistedMessageAndNeverGuesses() {
        let solSnapshot = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: "gpt-5.6-sol",
            phase: .loops,
            contractID: nil,
            contractBindingID: nil,
            requestedEffort: nil,
            forwardedEffort: nil,
            effortOutcome: .noNativeEffortRequested,
            blocker: nil)
        let persistedSol = ChatMessage(
            role: .assistant,
            text: "restored",
            modelID: "gpt-5.6-sol")
        let staleOpus = ChatMessage(
            role: .assistant,
            text: "stale",
            modelID: "opus5")

        XCTAssertEqual(
            ChatActiveTurnRouteAttributionPolicy.modelID(
                dispatchSnapshot: solSnapshot,
                activeMessage: staleOpus),
            "gpt-5.6-sol")
        XCTAssertEqual(
            ChatActiveTurnRouteAttributionPolicy.modelID(
                dispatchSnapshot: nil,
                activeMessage: persistedSol),
            "gpt-5.6-sol")
        XCTAssertNil(
            ChatActiveTurnRouteAttributionPolicy.modelID(
                dispatchSnapshot: nil,
                activeMessage: nil))
        XCTAssertNil(
            ChatActiveTurnRouteAttributionPolicy.modelID(
                dispatchSnapshot: nil,
                activeMessage: ChatMessage(
                    role: .assistant,
                    text: "unknown")))
    }

    @MainActor
    func testPendingRouteOwnsCooldownPreflight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-route-cooldown-\(UUID().uuidString)",
                isDirectory: true)
        let cooldownDirectory = directory.appendingPathComponent(
            "cooldowns",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: cooldownDirectory,
            withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let fableCooldown = TatwoGatewayCooldownRecordV1(
            provider: "fable-5",
            scope: "route",
            reason: "pending route quota",
            tripAtUTC: formatter.string(from: now.addingTimeInterval(-60)),
            resetAtUTC: formatter.string(from: now.addingTimeInterval(3_600)),
            sourceEventID: "event-pending-fable",
            contractID: "contract-pending-fable")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fableCooldown).write(
            to: cooldownDirectory.appendingPathComponent("fable.json"),
            options: .atomic)

        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_STATE_DIR": directory.path,
            ],
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)
        model.selectedModel = "gpt-5.5"
        model.isRunning = true
        model.setSingleModel("fable5")
        model.prompt = "queue on pending route"

        XCTAssertFalse(model.canSend)

        model.setSingleModel("minimax-m3")

        XCTAssertTrue(model.canSend)
    }

    @MainActor
    func testPendingTextRouteOwnsSendTimeAttachmentValidation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-route-attachment-\(UUID().uuidString)",
                isDirectory: true)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_STATE_DIR": directory.path,
            ],
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        model.selectedModel = "gpt-5.6-sol"
        model.isRunning = true
        model.setSingleModel("minimax-m3")
        model.prompt = "do not queue an unsupported image"
        model.droppedPaths = ["/tmp/pending-route-image.png"]
        model.droppedPathDisplayNames = [
            "/tmp/pending-route-image.png": "pending-route-image.png"
        ]

        model.send()

        XCTAssertTrue(model.droppedPaths.isEmpty)
        XCTAssertTrue(model.droppedPathDisplayNames.isEmpty)
        XCTAssertEqual(model.queuedChatTurnCount, 0)
        XCTAssertEqual(model.prompt, "do not queue an unsupported image")
        XCTAssertTrue(
            model.composerHint?.contains("MiniMax M3") == true)
    }

    @MainActor
    func testConflictingActiveAndReclaimAuthorityPreservesColdStartRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-conflicting-authority-\(UUID().uuidString)",
                isDirectory: true)
        let thread = TatwoNativeChatThread(title: "conflicting authority")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var journal = ChatTranscriptJournalV1()
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let messageID = "conflicting-running-assistant"
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: ChatMessage(
                id: messageID,
                role: .assistant,
                text: "",
                status: "streaming",
                modelID: "gpt-5.5"),
            threadID: threadKey,
            to: &journal
        ).wasAppended)
        try journalStore.save(journal)

        let runID = "message:\(messageID)"
        let token = ChatRunnerReclaimToken(
            runID: runID,
            attempt: nil,
            instanceID: UUID(),
            revision: 9)
        let model = makeModel(
            store: nativeStore,
            transcriptStore: journalStore,
            runnerAuthorityDiscoverer: StaticChatRunnerAuthorityDiscoverer(
                snapshot: .authoritative(
                    activeRunIDs: [runID],
                    reclaimTokens: [token])))
        try await waitForInitialStoreLoad(model)

        XCTAssertEqual(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .map(\.phase),
            [.running])
    }

    @MainActor
    func testEmptyLiveTranscriptFallsBackToCanonicalJournalProjection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-empty-live-fallback-\(UUID().uuidString)", isDirectory: true)
        let thread = TatwoNativeChatThread(title: "fallback")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var journal = ChatTranscriptJournalV1()
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: ChatMessage(
                id: "canonical-user",
                role: .user,
                text: "durable"),
            threadID: threadKey,
            to: &journal
        ).wasAppended)
        try journalStore.save(journal)
        let model = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)

        model.messages = []

        XCTAssertEqual(model.transcriptMessages.map(\.id), ["canonical-user"])
    }

    @MainActor
    func testConflictingReconnectReplayDoesNotRefreshCanonicalProjection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-strict-replay-\(UUID().uuidString)", isDirectory: true)
        let thread = TatwoNativeChatThread(title: "strict replay")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let createdAt = Date(timeIntervalSince1970: 700)
        let canonical = ChatMessage(
            id: "assistant-conflict",
            role: .assistant,
            text: "same text",
            modelID: "gpt-5.5",
            createdAt: createdAt)
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(ChatTranscriptJournalAdapter.append(
            message: canonical,
            threadID: threadKey,
            to: &journal
        ).wasAppended)
        try journalStore.save(journal)
        let model = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)
        let beforeJournal = model.chatTranscriptJournal
        var conflicting = canonical
        conflicting.modelID = "claude-sonnet-5"
        model.messages = [conflicting]

        model.replaySelectedTranscriptMessages()

        XCTAssertEqual(model.messages, [conflicting])
        XCTAssertEqual(model.chatTranscriptJournal, beforeJournal)
    }

    @MainActor
    func testMigrationRequiresAuthoritativeJournalReadbackBeforeScrubbing72Rows()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-authoritative-readback-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let firstID = UUID(
            uuidString: "019FC7BB-387D-7B42-945B-4C12DB57B624")!
        let secondID = UUID(
            uuidString: "019FC7BB-387D-7B42-945B-4C12DB57B648")!
        let firstRows = migrationRows(
            prefix: "first",
            count: 24,
            baseTime: 1_000,
            assistantModel: "gpt-5.6-sol")
        let secondRows = migrationRows(
            prefix: "second",
            count: 48,
            baseTime: 2_000,
            assistantModel: "gpt-5.6-luna")
        let expectedDigests = [
            firstID: storedMessageDigest(firstRows),
            secondID: storedMessageDigest(secondRows),
        ]
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: firstID,
                title: "First canonical standalone",
                codexSessionID: firstID.uuidString.lowercased(),
                lastPreview: "first preview",
                messages: firstRows),
            TatwoNativeChatThread(
                id: secondID,
                title: "Second canonical standalone",
                codexSessionID: secondID.uuidString.lowercased(),
                lastPreview: "second preview",
                messages: secondRows),
        ]))
        let journalURL = directory.appendingPathComponent("journal.json")
        let rejectingStore = ChatTranscriptJournalDiskStore(
            fileURL: journalURL,
            canonicalSnapshotWriter: { _, url in
                try Data("invalid-journal-readback".utf8).write(
                    to: url,
                    options: [.atomic])
            })
        var rejectedModel: ChatPageModel? = makeModel(
            store: nativeStore,
            transcriptStore: rejectingStore)
        try await waitForInitialStoreLoad(try XCTUnwrap(rejectedModel))

        XCTAssertFalse(rejectedModel!.legacyTranscriptMigrationCompleted)
        XCTAssertEqual(rejectedModel!.document.threads.count, 2)
        XCTAssertEqual(
            storedMessageDigest(
                try inlineRows(rejectedModel!.document, id: firstID)),
            expectedDigests[firstID])
        XCTAssertEqual(
            storedMessageDigest(
                try inlineRows(rejectedModel!.document, id: secondID)),
            expectedDigests[secondID])
        XCTAssertEqual(
            try inlineRows(rejectedModel!.document, id: firstID).count
                + inlineRows(rejectedModel!.document, id: secondID).count,
            72)
        XCTAssertTrue(rejectedModel!.persistStore())
        let rejectedNativeReload = try nativeStore.load()
        XCTAssertEqual(
            storedMessageDigest(
                try inlineRows(rejectedNativeReload, id: firstID)),
            expectedDigests[firstID])
        XCTAssertEqual(
            storedMessageDigest(
                try inlineRows(rejectedNativeReload, id: secondID)),
            expectedDigests[secondID])
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil))
                .contains {
                    $0.lastPathComponent.hasPrefix("journal.json.invalid-")
                        && $0.pathExtension == "quarantine"
                })
        rejectedModel = nil

        let normalStore = ChatTranscriptJournalDiskStore(fileURL: journalURL)
        var migratedModel: ChatPageModel? = makeModel(
            store: nativeStore,
            transcriptStore: normalStore)
        try await waitForInitialStoreLoad(try XCTUnwrap(migratedModel))

        XCTAssertTrue(migratedModel!.legacyTranscriptMigrationCompleted)
        let migratedJournal = try normalStore.load()
        XCTAssertEqual(migratedJournal.events.count, 72)
        XCTAssertEqual(
            Set(migratedJournal.events.map(\.eventID)).count,
            migratedJournal.events.count)
        XCTAssertEqual(
            storedMessageDigest(projectedRows(migratedJournal, id: firstID)),
            expectedDigests[firstID])
        XCTAssertEqual(
            storedMessageDigest(projectedRows(migratedJournal, id: secondID)),
            expectedDigests[secondID])
        XCTAssertEqual(
            try nativeStore.load().threads
                .compactMap(\.messages)
                .reduce(0) { $0 + $1.count },
            0)
        let migratedEventCount = migratedJournal.events.count
        migratedModel = nil

        let journalOnlyModel = makeModel(
            store: nativeStore,
            transcriptStore: normalStore)
        try await waitForInitialStoreLoad(journalOnlyModel)

        XCTAssertTrue(journalOnlyModel.legacyTranscriptMigrationCompleted)
        XCTAssertEqual(
            Set(journalOnlyModel.document.threads.map(\.id)),
            Set([firstID, secondID]))
        XCTAssertEqual(journalOnlyModel.document.threads.count, 2)
        XCTAssertEqual(
            storedMessageDigest(
                try inlineRows(journalOnlyModel.document, id: firstID)),
            expectedDigests[firstID])
        XCTAssertEqual(
            storedMessageDigest(
                try inlineRows(journalOnlyModel.document, id: secondID)),
            expectedDigests[secondID])
        XCTAssertEqual(
            try inlineRows(journalOnlyModel.document, id: firstID).count,
            24)
        XCTAssertEqual(
            try inlineRows(journalOnlyModel.document, id: secondID).count,
            48)
        XCTAssertTrue(journalOnlyModel.persistStore())
        let journalOnlyReload = try normalStore.load()
        XCTAssertEqual(journalOnlyReload.events.count, migratedEventCount)
        XCTAssertEqual(
            Set(journalOnlyReload.events.map(\.eventID)).count,
            migratedEventCount)
        XCTAssertEqual(
            storedMessageDigest(projectedRows(journalOnlyReload, id: firstID)),
            expectedDigests[firstID])
        XCTAssertEqual(
            storedMessageDigest(projectedRows(journalOnlyReload, id: secondID)),
            expectedDigests[secondID])
    }

    func testJournalSaveRejectsMissingAndValidButDifferentDiskReadback()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-journal-readback-mismatch-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("journal.json")
        var expected = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "expected-message",
                    role: .user,
                    text: "expected"),
                threadID: "thread:expected",
                to: &expected
            ).wasAppended)
        var different = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "different-message",
                    role: .user,
                    text: "different"),
                threadID: "thread:different",
                to: &different
            ).wasAppended)
        let differentSnapshot = try different.encodedSnapshot()

        XCTAssertThrowsError(
            try ChatTranscriptJournalDiskStore(
                fileURL: fileURL,
                canonicalSnapshotWriter: { _, _ in }
            ).save(expected))
        XCTAssertThrowsError(
            try ChatTranscriptJournalDiskStore(
                fileURL: fileURL,
                canonicalSnapshotWriter: { _, url in
                    try differentSnapshot.write(to: url, options: [.atomic])
                }
            ).save(expected))
    }

    @MainActor
    func testMigrationCompletionRollsBackWhenNativeStorePersistFails()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-native-persist-gate-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nativeURL = directory.appendingPathComponent("native-chat.json")
        let nativeBackupURL = directory.appendingPathComponent(
            "native-chat.backup.json")
        let threadID = UUID()
        let firstRow = TatwoNativeChatStoredMessage(
            id: "first-native-row",
            role: "user",
            text: "first native row",
            createdAt: Date(timeIntervalSince1970: 1_000))
        let secondRow = TatwoNativeChatStoredMessage(
            id: "second-native-row",
            role: "user",
            text: """
                [Hidden TATWO Chat interface contract]
                private native payload
                [/Hidden TATWO Chat interface contract]

                second native row
                """,
            createdAt: Date(timeIntervalSince1970: 2_000))
        let nativeStore = TatwoNativeChatStore(
            url: nativeURL,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: threadID,
                title: "native persist gate",
                messages: [firstRow])
        ]))
        let transcriptStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let model = makeModel(
            store: nativeStore,
            transcriptStore: transcriptStore)
        try await waitForInitialStoreLoad(model)
        XCTAssertTrue(model.legacyTranscriptMigrationCompleted)

        model.document.threads[0].messages = [firstRow, secondRow]
        model.legacyTranscriptMigrationCompleted = false
        try FileManager.default.moveItem(
            at: nativeURL,
            to: nativeBackupURL)
        try FileManager.default.createDirectory(
            at: nativeURL,
            withIntermediateDirectories: true)

        model.migrateLegacyDocumentTranscriptsIfNeeded()

        XCTAssertFalse(model.legacyTranscriptMigrationCompleted)
        XCTAssertEqual(
            model.document.threads[0].messages,
            [firstRow, secondRow])
        XCTAssertNotNil(model.chatStorePersistenceWarning)
        XCTAssertEqual(
            Set(projectedRows(try transcriptStore.load(), id: threadID).map(\.id)),
            Set([firstRow.id, secondRow.id]))

        let blockerURL = directory.appendingPathComponent(
            "native-write-blocker",
            isDirectory: true)
        try FileManager.default.moveItem(at: nativeURL, to: blockerURL)
        try FileManager.default.moveItem(
            at: nativeBackupURL,
            to: nativeURL)

        XCTAssertTrue(model.persistStore())
        XCTAssertEqual(
            try nativeStore.load().threads[0].messages,
            [firstRow, secondRow],
            "a later unrelated persist must retain the exact legacy payload")
    }

    @MainActor
    func testBlockedMigrationSendAndRelaunchPreservesLegacyRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-blocked-migration-relaunch-\(UUID().uuidString)", isDirectory: true)
        let legacyRows = [
            TatwoNativeChatStoredMessage(
                id: "legacy-user",
                role: "user",
                text: "keep user",
                createdAt: Date(timeIntervalSince1970: 10)),
            TatwoNativeChatStoredMessage(
                id: "legacy-unknown",
                role: "developer",
                text: "keep unknown",
                createdAt: Date(timeIntervalSince1970: 20)),
        ]
        let thread = TatwoNativeChatThread(
            title: "blocked migration",
            messages: legacyRows)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let first = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(first)
        XCTAssertFalse(first.legacyTranscriptMigrationCompleted)

        let sent = ChatMessage(
            id: "new-user",
            role: .user,
            text: "send after block",
            createdAt: Date(timeIntervalSince1970: 30))
        XCTAssertTrue(first.recordCanonicalMessage(sent))
        first.persistStore()
        XCTAssertEqual(
            try nativeStore.load().threads[0].messages,
            legacyRows)

        let relaunched = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(relaunched)

        XCTAssertFalse(relaunched.legacyTranscriptMigrationCompleted)
        XCTAssertEqual(
            Set(relaunched.transcriptMessages.map(\.id)),
            Set(["legacy-user", "legacy-unknown", "new-user"]))
        XCTAssertEqual(
            try nativeStore.load().threads[0].messages,
            legacyRows)
    }

    @MainActor
    func testQuarantineFailureRecoversAfterPermissionsAreRestored() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-journal-quarantine-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("journal.json")
        let corruptBytes = Data("corrupt-and-must-survive".utf8)
        try corruptBytes.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path)
        let transcriptStore = ChatTranscriptJournalDiskStore(fileURL: fileURL)
        let model = makeModel(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("chat-model-\(UUID().uuidString)", isDirectory: true),
            transcriptStore: transcriptStore)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)

        XCTAssertFalse(model.chatTranscriptJournalPersistenceAllowed)
        XCTAssertFalse(model.mutateTranscriptJournal {
            ChatTranscriptJournalAdapter.appendError(
                message: "saved after permissions recover",
                context: self.context(),
                to: &$0)
        })
        XCTAssertTrue(model.chatTranscriptJournal.events.isEmpty)
        try await waitUntil {
            model.chatTranscriptJournalPersistenceAllowed
        }
        let recovered = model.mutateTranscriptJournal {
            ChatTranscriptJournalAdapter.appendError(
                message: "saved after permissions recover",
                context: self.context(),
                to: &$0)
        }

        XCTAssertTrue(recovered)
        XCTAssertTrue(model.chatTranscriptJournalPersistenceAllowed)
        XCTAssertEqual(try transcriptStore.load(), model.chatTranscriptJournal)
        XCTAssertEqual(
            model.chatTranscriptJournal
                .orderedItems(threadID: "thread-1")
                .first?.summary,
            "saved after permissions recover")
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("journal.json.invalid-")
                && $0.pathExtension == "quarantine"
        }
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantined.first)),
            corruptBytes)
    }

    func testSourceMetadataMapsCodexClaudeFableAndGrok() {
        let cases = [
            ("gpt-5.5", "codex"),
            ("sonnet5", "claude"),
            ("fable5", "fable"),
            ("grok-build", "grok"),
        ]

        for (routeID, expectedSource) in cases {
            let route = ChatRouteChoice.resolve(routeID)
            let metadata = ChatTranscriptJournalAdapter.sourceMetadata(
                route: route,
                runID: "run-\(routeID)",
                attempt: 2)
            XCTAssertEqual(metadata.source, expectedSource, routeID)
            XCTAssertEqual(metadata.model, route.canonicalModelSlug, routeID)
            XCTAssertEqual(metadata.runtime, route.runtimeAdapter.rawValue, routeID)
            XCTAssertEqual(metadata.runID, "run-\(routeID)", routeID)
            XCTAssertEqual(metadata.attempt, 2, routeID)
        }
    }

    func testRemoteJobReducerCollapsesLogicalAttemptsIntoOneFiveStateProjection() throws {
        let records = [
            remoteRecord(
                id: "dispatch-a1",
                logicalDispatchID: "logical-remote-1",
                remoteJobID: "job-a1",
                status: .running,
                remoteStatus: .delivered,
                updatedAt: Date(timeIntervalSince1970: 1_000)),
            remoteRecord(
                id: "dispatch-a2",
                logicalDispatchID: "logical-remote-1",
                remoteJobID: "job-a2",
                status: .running,
                remoteStatus: .running,
                updatedAt: Date(timeIntervalSince1970: 1_010)),
            remoteRecord(
                id: "dispatch-a3",
                logicalDispatchID: "logical-remote-1",
                remoteJobID: "job-a3",
                status: .verified,
                remoteStatus: .verified,
                updatedAt: Date(timeIntervalSince1970: 1_020)),
        ]

        let projection = try XCTUnwrap(ChatRemoteJobReducer.project(records).first)

        XCTAssertEqual(ChatRemoteJobReducer.project(records).count, 1)
        XCTAssertEqual(projection.logicalKey, "logical-remote-1")
        XCTAssertEqual(projection.attempt, 3)
        XCTAssertEqual(projection.publicState, .verified)
        XCTAssertEqual(
            Set(ChatRemoteJobPublicState.allCases.map(\.rawValue)),
            Set(["已送達", "已啟動", "執行中", "已完成", "已驗收"]))
        XCTAssertEqual(projection.publicNarrative, "遠端工作已完成並驗收")
        let lifecycle = try XCTUnwrap(projection.toolDetails["lifecycle"])
        for stage in ["借用原因：", "目標：", "傳送：", "排隊/執行：", "回傳：", "本機驗證：", "完成："] {
            XCTAssertTrue(lifecycle.contains(stage), stage)
            XCTAssertFalse(projection.publicNarrative.contains(stage), stage)
        }
        XCTAssertFalse(projection.publicNarrative.contains("logical-remote-1"))
        XCTAssertFalse(projection.publicNarrative.contains("job-a3"))
        XCTAssertFalse(projection.publicNarrative.contains("/private/worktree"))
        XCTAssertEqual(
            projection.toolDetails["jobID"],
            "job-a3")
        XCTAssertEqual(
            projection.toolDetails["outputRef"],
            "/private/worktree/result.json")
    }

    func testAcceptedPendingTargetAndRegistryRetriesRemainOneCanonicalRemoteRow() throws {
        let logicalJobID = "logical-canonical-remote-row"
        let threadID = "thread-canonical-remote-row"
        let target = ChatPendingRemoteTargetV1(
            sessionID: "session-canonical",
            contractID: "contract-canonical",
            goalID: "goal-canonical",
            targetDeviceID: "device-canonical",
            targetDisplayName: "Mac mini",
            grantID: "grant-canonical",
            issuedAt: Date(timeIntervalSince1970: 8_000),
            operationID: "operation-canonical",
            claimID: "claim-canonical",
            logicalJobID: logicalJobID)
        let accepted = ChatRemoteJobReducer.acceptedRemoteDispatch(
            target: target,
            acceptance: ChatRemoteTurnDispatchAcceptance(
                logicalJobID: logicalJobID,
                remoteJobID: "job-attempt-1",
                acceptedAt: Date(timeIntervalSince1970: 8_001)))
        let attempt1Running = remoteRecord(
            id: "dispatch-running-1",
            logicalDispatchID: logicalJobID,
            remoteJobID: "job-attempt-1",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 8_010))
        let attempt1Failed = remoteRecord(
            id: "dispatch-failed-1",
            logicalDispatchID: logicalJobID,
            remoteJobID: "job-attempt-1",
            status: .failed,
            remoteStatus: .failed,
            updatedAt: Date(timeIntervalSince1970: 8_020),
            errorMessage: "attempt one failed")
        let attempt2Running = remoteRecord(
            id: "dispatch-running-2",
            logicalDispatchID: logicalJobID,
            remoteJobID: "job-attempt-2",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 8_030))
        var journal = ChatTranscriptJournalV1()

        XCTAssertEqual(accepted.logicalKey, logicalJobID)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: accepted,
                threadID: threadID,
                to: &journal
            ).wasAppended)
        let acceptedMessageID = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadID,
                from: journal
            ).first?.id)

        for records in [
            [attempt1Running],
            [attempt1Running, attempt1Failed],
            [attempt1Running, attempt1Failed, attempt2Running],
        ] {
            XCTAssertTrue(
                ChatTranscriptJournalAdapter.append(
                    remoteJob: try XCTUnwrap(
                        ChatRemoteJobReducer.project(records).first),
                    threadID: threadID,
                    to: &journal
                ).wasAppended)
            XCTAssertEqual(
                ChatTranscriptJournalAdapter.projectedMessages(
                    threadID: threadID,
                    from: journal
                ).first?.id,
                acceptedMessageID)
        }

        let remoteItems = journal.orderedItems(threadID: threadID)
            .filter { $0.kind == .remoteJob }
        let item = try XCTUnwrap(remoteItems.first)
        let row = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadID,
                from: journal
            ).first)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: row.status))

        XCTAssertEqual(remoteItems.count, 1)
        XCTAssertEqual(item.source.attempt, 2)
        XCTAssertEqual(item.phase, .running)
        XCTAssertEqual(item.eventIDs.count, 4)
        XCTAssertEqual(payload.state, .running)
        XCTAssertNil(payload.terminalOutcome)
        XCTAssertEqual(payload.details["jobID"], "job-attempt-2")
        XCTAssertEqual(payload.details["attempts"], "2")
        XCTAssertEqual(row.text, "正在遠端設備執行")
        XCTAssertTrue(payload.details["lifecycle"]?.contains("第 2 次嘗試") == true)
        XCTAssertFalse(row.text.contains("attempt one failed"))
    }

    func testAcceptedDispatchReplayIgnoresChangedAcceptedAt() throws {
        let target = ChatPendingRemoteTargetV1(
            sessionID: "session-acceptance-replay",
            contractID: "contract-acceptance-replay",
            goalID: "goal-acceptance-replay",
            targetDeviceID: "device-acceptance-replay",
            targetDisplayName: "Mac mini",
            grantID: "grant-acceptance-replay",
            issuedAt: Date(timeIntervalSince1970: 8_035),
            operationID: "operation-acceptance-replay",
            claimID: "claim-acceptance-replay",
            logicalJobID: "logical-acceptance-replay")
        let first = ChatRemoteJobReducer.acceptedRemoteDispatch(
            target: target,
            acceptance: ChatRemoteTurnDispatchAcceptance(
                logicalJobID: target.logicalJobID,
                remoteJobID: "job-acceptance-replay",
                acceptedAt: Date(timeIntervalSince1970: 8_036)))
        let replay = ChatRemoteJobReducer.acceptedRemoteDispatch(
            target: target,
            acceptance: ChatRemoteTurnDispatchAcceptance(
                logicalJobID: target.logicalJobID,
                remoteJobID: "job-acceptance-replay",
                acceptedAt: Date(timeIntervalSince1970: 8_037)))
        var journal = ChatTranscriptJournalV1()

        XCTAssertEqual(
            ChatTranscriptJournalAdapter.append(
                remoteJob: first,
                threadID: "thread-acceptance-replay",
                to: &journal),
            .appended)
        guard case .ignored(.duplicateEvent) =
            ChatTranscriptJournalAdapter.append(
                remoteJob: replay,
                threadID: "thread-acceptance-replay",
                to: &journal)
        else {
            return XCTFail("acceptedAt refresh must replay the same dispatch receipt")
        }

        XCTAssertEqual(journal.events.count, 1)
        XCTAssertEqual(
            journal.events.first?.occurredAt,
            Date(timeIntervalSince1970: 8_036))
    }

    @MainActor
    func testSelectedDispatchObserverDefersAndOrdersJournalPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-remote-deferred-persistence-\(UUID().uuidString)",
                isDirectory: true)
        let thread = TatwoNativeChatThread(
            title: "deferred persistence",
            workOSGoalID: "goal-deferred-persistence",
            workOSContractID: "contract-deferred-persistence")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let model = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)
        let before = model.chatTranscriptJournal

        model.selectedDispatchRecords = [
            remoteRecord(
                id: "dispatch-deferred-running-1",
                logicalDispatchID: "logical-deferred",
                remoteJobID: "job-deferred",
                status: .running,
                remoteStatus: .running,
                updatedAt: Date(timeIntervalSince1970: 8_037)),
        ]
        model.selectedDispatchRecords = [
            remoteRecord(
                id: "dispatch-deferred-failed-1",
                logicalDispatchID: "logical-deferred",
                remoteJobID: "job-deferred",
                status: .failed,
                remoteStatus: .failed,
                updatedAt: Date(timeIntervalSince1970: 8_038),
                errorMessage: "latest terminal"),
        ]

        XCTAssertEqual(
            model.chatTranscriptJournal,
            before,
            "the @Published observer must not synchronously write or publish journal state")
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        try await waitUntil {
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob })?
                .phase == .failed
        }

        let item = try XCTUnwrap(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob }))
        XCTAssertEqual(item.attributes["remoteTerminalOutcome"], "失敗")
        XCTAssertEqual(item.attributes["remoteBlocker"], "latest terminal")
        XCTAssertEqual(try journalStore.load(), model.chatTranscriptJournal)
    }

    @MainActor
    func testRedispatchAcceptanceReopensFailedRowBeforeAttemptTwoRegistry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-remote-accepted-retry-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(title: "accepted retry")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let model = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)
        let target = ChatPendingRemoteTargetV1(
            sessionID: thread.id.uuidString.lowercased(),
            contractID: "contract-accepted-retry",
            goalID: "goal-accepted-retry",
            targetDeviceID: "device-accepted-retry",
            targetDisplayName: "Mac mini",
            grantID: "grant-accepted-retry",
            issuedAt: Date(timeIntervalSince1970: 8_040),
            operationID: "operation-accepted-retry",
            claimID: "claim-accepted-retry",
            logicalJobID: "logical-accepted-retry")

        XCTAssertTrue(
            model.recordAcceptedRemoteDispatch(
                target: target,
                acceptance: ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: target.logicalJobID,
                    remoteJobID: "job-accepted-retry-1",
                    acceptedAt: Date(timeIntervalSince1970: 8_041))))
        model.selectedDispatchRecords = [
            remoteRecord(
                id: "dispatch-accepted-running-1",
                logicalDispatchID: target.logicalJobID,
                remoteJobID: "job-accepted-retry-1",
                status: .running,
                remoteStatus: .running,
                updatedAt: Date(timeIntervalSince1970: 8_050)),
        ]
        model.selectedDispatchRecords = [
            remoteRecord(
                id: "dispatch-accepted-failed-1",
                logicalDispatchID: target.logicalJobID,
                remoteJobID: "job-accepted-retry-1",
                status: .failed,
                remoteStatus: .failed,
                updatedAt: Date(timeIntervalSince1970: 8_060),
                errorMessage: "attempt one failed"),
        ]
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        try await waitUntil {
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob })?
                .phase == .failed
        }
        let failedItem = try XCTUnwrap(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob }))
        let stableMessageID = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadKey,
                from: model.chatTranscriptJournal
            ).first?.id)
        XCTAssertEqual(failedItem.phase, .failed)
        XCTAssertEqual(failedItem.source.attempt, 1)

        XCTAssertTrue(
            model.recordAcceptedRemoteDispatch(
                target: target,
                acceptance: ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: target.logicalJobID,
                    remoteJobID: "job-accepted-retry-2",
                    acceptedAt: Date(timeIntervalSince1970: 8_070))))

        let deliveredItems = model.chatTranscriptJournal
            .orderedItems(threadID: threadKey)
            .filter { $0.kind == .remoteJob }
        let deliveredItem = try XCTUnwrap(deliveredItems.first)
        let deliveredRow = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadKey,
                from: model.chatTranscriptJournal
            ).first)
        let deliveredPayload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: deliveredRow.status))

        XCTAssertEqual(deliveredItems.count, 1)
        XCTAssertEqual(deliveredItem.source.attempt, 2)
        XCTAssertEqual(deliveredItem.phase, .running)
        XCTAssertEqual(deliveredItem.attributes["remotePublicState"], "已送達")
        XCTAssertNil(deliveredItem.attributes["remoteTerminalOutcome"])
        XCTAssertEqual(deliveredPayload.state, .delivered)
        XCTAssertEqual(deliveredPayload.details["jobID"], "job-accepted-retry-2")
        XCTAssertEqual(deliveredPayload.details["attempts"], "2")
        XCTAssertEqual(deliveredRow.id, stableMessageID)
        XCTAssertEqual(deliveredRow.text, "已送達遠端設備，等待啟動")
        XCTAssertTrue(
            deliveredPayload.details["lifecycle"]?.contains("第 2 次嘗試") == true)

        model.selectedDispatchRecords = [
            remoteRecord(
                id: "dispatch-accepted-running-2",
                logicalDispatchID: target.logicalJobID,
                remoteJobID: "job-accepted-retry-2",
                status: .running,
                remoteStatus: .running,
                updatedAt: Date(timeIntervalSince1970: 8_080)),
        ]
        try await waitUntil {
            let item = model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob })
            return item?.source.attempt == 2
                && item?.attributes["remotePublicState"] == "執行中"
        }
        let runningItem = try XCTUnwrap(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob }))
        XCTAssertEqual(runningItem.source.attempt, 2)
        XCTAssertEqual(runningItem.attributes["remotePublicState"], "執行中")
        XCTAssertEqual(try journalStore.load(), model.chatTranscriptJournal)
    }

    @MainActor
    func testRedispatchAcceptanceCannotReopenCompletedRemoteRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-remote-completed-acceptance-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(title: "completed acceptance")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let model = makeModel(
            store: nativeStore,
            transcriptStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)
        let target = ChatPendingRemoteTargetV1(
            sessionID: thread.id.uuidString.lowercased(),
            contractID: "contract-completed-acceptance",
            goalID: "goal-completed-acceptance",
            targetDeviceID: "device-completed-acceptance",
            targetDisplayName: "Mac mini",
            grantID: "grant-completed-acceptance",
            issuedAt: Date(timeIntervalSince1970: 8_090),
            operationID: "operation-completed-acceptance",
            claimID: "claim-completed-acceptance",
            logicalJobID: "logical-completed-acceptance")

        XCTAssertTrue(
            model.recordAcceptedRemoteDispatch(
                target: target,
                acceptance: ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: target.logicalJobID,
                    remoteJobID: "job-completed-1",
                    acceptedAt: Date(timeIntervalSince1970: 8_091))))
        model.selectedDispatchRecords = [
            remoteRecord(
                id: "dispatch-completed-1",
                logicalDispatchID: target.logicalJobID,
                remoteJobID: "job-completed-1",
                status: .completed,
                remoteStatus: .completed,
                updatedAt: Date(timeIntervalSince1970: 8_100)),
        ]
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        try await waitUntil {
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob })?
                .phase == .completed
        }
        let completedBefore = try XCTUnwrap(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob }))

        XCTAssertTrue(
            model.recordAcceptedRemoteDispatch(
                target: target,
                acceptance: ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: target.logicalJobID,
                    remoteJobID: "job-completed-2",
                    acceptedAt: Date(timeIntervalSince1970: 8_110))))

        let completedAfter = try XCTUnwrap(
            model.chatTranscriptJournal
                .orderedItems(threadID: threadKey)
                .first(where: { $0.kind == .remoteJob }))
        XCTAssertEqual(completedAfter, completedBefore)
        XCTAssertEqual(completedAfter.phase, .completed)
        XCTAssertEqual(completedAfter.source.attempt, 1)
        XCTAssertEqual(completedAfter.attributes["remotePublicState"], "已完成")
        XCTAssertEqual(completedAfter.attributes["detail.jobID"], "job-completed-1")
    }

    @MainActor
    func testRemoteLifecycleSelectedInDiscussionPersistsOnlyToMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-remote-discussion-namespace-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let discussion = TatwoNativeDiscussion(
            title: "child discussion",
            inheritedSnapshot: "")
        let thread = TatwoNativeChatThread(
            title: "remote main thread",
            workOSGoalID: "goal-discussion-namespace",
            workOSContractID: "contract-discussion-namespace",
            discussions: [discussion])
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let model = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)
        model.selectDiscussion(
            projectID: nil,
            threadID: thread.id,
            discussionID: discussion.id)
        XCTAssertEqual(model.selectedSessionReference?.kind, .discussion)
        XCTAssertEqual(
            model.selectedRemoteBorrowSessionID,
            thread.id.uuidString.lowercased())
        let target = ChatPendingRemoteTargetV1(
            sessionID: thread.id.uuidString.lowercased(),
            contractID: "contract-discussion-namespace",
            goalID: "goal-discussion-namespace",
            targetDeviceID: "device-discussion-namespace",
            targetDisplayName: "Mac mini",
            grantID: "grant-discussion-namespace",
            issuedAt: Date(timeIntervalSince1970: 8_120),
            operationID: "operation-discussion-namespace",
            claimID: "claim-discussion-namespace",
            logicalJobID: "logical-discussion-namespace")

        XCTAssertTrue(
            model.recordPendingRemoteTargetBlocker(
                target: target,
                blocker: "等待遠端目標",
                occurredAt: Date(timeIntervalSince1970: 8_121)))
        XCTAssertTrue(
            model.recordAcceptedRemoteDispatch(
                target: target,
                acceptance: ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: target.logicalJobID,
                    remoteJobID: "job-discussion-namespace",
                    acceptedAt: Date(timeIntervalSince1970: 8_122))))
        model.selectedDispatchRecords = [
            remoteRecord(
                id: "dispatch-discussion-namespace-1",
                logicalDispatchID: target.logicalJobID,
                remoteJobID: "job-discussion-namespace",
                status: .running,
                remoteStatus: .running,
                updatedAt: Date(timeIntervalSince1970: 8_123)),
        ]

        let mainThreadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let discussionKey = TatwoNativeChatSessionReference(
            kind: .discussion,
            id: discussion.id
        ).stableKey
        try await waitUntil {
            model.chatTranscriptJournal
                .orderedItems(threadID: mainThreadKey)
                .first(where: { $0.kind == .remoteJob })?
                .attributes["remotePublicState"] == "執行中"
        }
        let mainRemoteItems = model.chatTranscriptJournal
            .orderedItems(threadID: mainThreadKey)
            .filter { $0.kind == .remoteJob }
        let mainItem = try XCTUnwrap(mainRemoteItems.first)

        XCTAssertEqual(mainRemoteItems.count, 1)
        XCTAssertEqual(mainItem.eventIDs.count, 3)
        XCTAssertEqual(mainItem.attributes["logicalDispatchID"], target.logicalJobID)
        XCTAssertEqual(mainItem.attributes["remotePublicState"], "執行中")
        XCTAssertTrue(
            model.chatTranscriptJournal
                .orderedItems(threadID: discussionKey)
                .filter { $0.kind == .remoteJob }
                .isEmpty)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: discussionKey,
                from: model.chatTranscriptJournal
            ).isEmpty)
        XCTAssertEqual(try journalStore.load(), model.chatTranscriptJournal)
    }

    func testRemoteJobReducerFiltersLocalOnlyRecordsAndMixedLocalEvidence() throws {
        let localOnly = localRecord(
            id: "local-only",
            logicalDispatchID: "logical-local-only",
            status: .failed,
            updatedAt: Date(timeIntervalSince1970: 8_100),
            errorMessage: "local-only failure")

        XCTAssertTrue(ChatRemoteJobReducer.project([localOnly]).isEmpty)

        let validRemote = remoteRecord(
            id: "dispatch-valid-1",
            logicalDispatchID: "logical-mixed",
            remoteJobID: "job-valid",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 8_110))
        let misleadingLocal = localRecord(
            id: "local-misleading",
            logicalDispatchID: "logical-mixed",
            status: .failed,
            updatedAt: Date(timeIntervalSince1970: 9_999),
            errorMessage: "must not contaminate remote evidence")

        let projection = try XCTUnwrap(
            ChatRemoteJobReducer.project([misleadingLocal, validRemote]).first)

        XCTAssertEqual(
            ChatRemoteJobReducer.project([misleadingLocal, validRemote]).count,
            1)
        XCTAssertEqual(projection.logicalKey, "logical-mixed")
        XCTAssertEqual(projection.publicState, .running)
        XCTAssertNil(projection.terminalOutcome)
        XCTAssertNil(projection.blocker)
        XCTAssertEqual(projection.toolDetails["jobID"], "job-valid")
        XCTAssertNil(projection.toolDetails["error"])
        XCTAssertFalse(
            projection.publicNarrative.contains("must not contaminate remote evidence"))
    }

    func testRemoteTimestampOnlyRefreshDedupesAndAllowsTerminalProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-remote-event-identity-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let threadID = "thread-remote-event-identity"
        let logicalID = "logical-remote-event-identity"
        let running1 = remoteRecord(
            id: "dispatch-refresh-1",
            logicalDispatchID: logicalID,
            remoteJobID: "job-refresh",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 8_200))
        let running2 = remoteRecord(
            id: "dispatch-refresh-1",
            logicalDispatchID: logicalID,
            remoteJobID: "job-refresh",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 8_210))
        let failed = remoteRecord(
            id: "dispatch-refresh-1",
            logicalDispatchID: logicalID,
            remoteJobID: "job-refresh",
            status: .failed,
            remoteStatus: .failed,
            updatedAt: Date(timeIntervalSince1970: 8_220),
            errorMessage: "real terminal evidence")
        var journal = ChatTranscriptJournalV1()

        for (index, record) in [running1, running2, failed].enumerated() {
            let projection = try XCTUnwrap(
                ChatRemoteJobReducer.project([record]).first)
            let outcome = ChatTranscriptJournalAdapter.append(
                remoteJob: projection,
                threadID: threadID,
                to: &journal)
            if index == 1 {
                guard case .ignored(.duplicateEvent(eventID: _)) = outcome else {
                    XCTFail("timestamp-only refresh must be ignored, got \(outcome)")
                    continue
                }
            } else {
                XCTAssertEqual(outcome, .appended)
            }
            try store.save(journal)
            journal = try store.load()
        }

        let item = try XCTUnwrap(
            journal.orderedItems(threadID: threadID)
                .first(where: { $0.kind == .remoteJob }))
        let row = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadID,
                from: journal
            ).first)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: row.status))

        XCTAssertEqual(journal.events.count, 2)
        XCTAssertEqual(Set(journal.events.map(\.eventID)).count, 2)
        XCTAssertEqual(item.eventIDs.count, 2)
        XCTAssertEqual(item.phase, .failed)
        XCTAssertEqual(item.attributes["remoteTerminalOutcome"], "失敗")
        XCTAssertNil(payload.state)
        XCTAssertEqual(payload.blocker, "real terminal evidence")
    }

    func testRemoteObservationIdentitySurvivesHalfMillisecondSnapshotRoundTrip() throws {
        let halfMillisecond = Date(timeIntervalSince1970: 8_250.0005)
        let projection = remoteProjection(
            state: .running,
            occurredAt: halfMillisecond)
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: projection,
                threadID: "thread-half-millisecond",
                to: &journal
            ).wasAppended)

        var restored = try ChatTranscriptJournalV1.restoring(
            from: journal.encodedSnapshot())
        let restoredDate = try XCTUnwrap(restored.events.first?.occurredAt)
        let replay = remoteProjection(
            state: .running,
            occurredAt: restoredDate)
        guard case .ignored(.duplicateEvent) =
            ChatTranscriptJournalAdapter.append(
                remoteJob: replay,
                threadID: "thread-half-millisecond",
                to: &restored)
        else {
            return XCTFail("encoder round-trip must preserve observation identity")
        }
        XCTAssertEqual(restored.events.count, 1)
    }

    func testRemoteHeartbeatTimestampRefreshDoesNotGrowJournalWithoutSemanticChange() throws {
        let first = remoteProjection(
            state: .running,
            occurredAt: Date(timeIntervalSince1970: 8_255))
        let heartbeatOnlyRefresh = remoteProjection(
            state: .running,
            occurredAt: Date(timeIntervalSince1970: 8_355))
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: first,
                threadID: "thread-heartbeat-only",
                to: &journal
            ).wasAppended)
        guard case .ignored(.duplicateEvent) =
            ChatTranscriptJournalAdapter.append(
                remoteJob: heartbeatOnlyRefresh,
                threadID: "thread-heartbeat-only",
                to: &journal)
        else {
            return XCTFail("timestamp-only refresh must be a semantic duplicate")
        }
        XCTAssertEqual(journal.events.count, 1)
        XCTAssertEqual(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-heartbeat-only",
                from: journal
            ).count,
            1)
    }

    func testRegistryAttemptTwoCannotReopenJournalCompletedByAttemptOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-real-registry-terminal-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("state"))
        let logicalJobID = "logical-real-registry-terminal"
        let firstJob = remoteRegistryJob(
            jobID: "job-real-registry-1",
            logicalJobID: logicalJobID,
            dispatchNonce: "nonce-real-registry-1",
            workPath: root.appendingPathComponent("work"))
        let secondJob = remoteRegistryJob(
            jobID: "job-real-registry-2",
            logicalJobID: logicalJobID,
            dispatchNonce: "nonce-real-registry-2",
            workPath: root.appendingPathComponent("work"))

        XCTAssertEqual(
            try registry.ensureInboundRemoteMirror(job: firstJob).resolvedAttempt,
            1)
        XCTAssertEqual(
            try registry.ensureInboundRemoteMirror(job: secondJob).resolvedAttempt,
            2)
        _ = try registry.projectRemoteStatus(
            contractID: firstJob.contractID,
            remoteJobID: firstJob.jobID,
            remoteStatus: .completed,
            now: Date(timeIntervalSince1970: 8_260))
        let completedRecords = try XCTUnwrap(
            registry.run(forContractID: firstJob.contractID)?.records.filter {
                $0.remoteJobID == firstJob.jobID
            })
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: try XCTUnwrap(
                    ChatRemoteJobReducer.project(completedRecords).first),
                threadID: "thread-real-registry-terminal",
                to: &journal
            ).wasAppended)
        let completedBefore = try XCTUnwrap(
            journal.orderedItems(threadID: "thread-real-registry-terminal").first)

        _ = try registry.projectRemoteStatus(
            contractID: secondJob.contractID,
            remoteJobID: secondJob.jobID,
            remoteStatus: .running,
            now: Date(timeIntervalSince1970: 8_270))
        let allRecords = try XCTUnwrap(
            registry.run(forContractID: firstJob.contractID)?.records)
        guard case .ignored(.terminalItem) =
            ChatTranscriptJournalAdapter.append(
                remoteJob: try XCTUnwrap(
                    ChatRemoteJobReducer.project(allRecords).first),
                threadID: "thread-real-registry-terminal",
                to: &journal)
        else {
            return XCTFail("attempt two must not reopen a completed journal row")
        }

        XCTAssertEqual(
            journal.orderedItems(threadID: "thread-real-registry-terminal").first,
            completedBefore)
        XCTAssertEqual(completedBefore.phase, .completed)
        XCTAssertEqual(completedBefore.source.attempt, 1)
    }

    @MainActor
    func testStaleRemoteAttemptReplayIsAcceptedAsHarmless() {
        XCTAssertTrue(
            ChatPageModel.isAcceptedRemoteJobReplayOutcome(
                .ignored(.staleAttempt(
                    itemID: "remote-item",
                    current: 2,
                    received: 1))))
    }

    func testRemoteJobReducerChoosesHighestAttemptBeforeLatestTimestamp() throws {
        let delayedAttempt1 = remoteRecord(
            id: "dispatch-late-1",
            logicalDispatchID: "logical-attempt-order",
            remoteJobID: "job-attempt-1",
            status: .failed,
            remoteStatus: .failed,
            updatedAt: Date(timeIntervalSince1970: 9_999),
            errorMessage: "late attempt one failure")
        let runningAttempt2 = remoteRecord(
            id: "dispatch-live-2",
            logicalDispatchID: "logical-attempt-order",
            remoteJobID: "job-attempt-2",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 9_000))

        let projection = try XCTUnwrap(
            ChatRemoteJobReducer.project([
                delayedAttempt1,
                runningAttempt2,
            ]).first)

        XCTAssertEqual(projection.attempt, 2)
        XCTAssertEqual(projection.publicState, .running)
        XCTAssertNil(projection.terminalOutcome)
        XCTAssertNil(projection.blocker)
        XCTAssertEqual(projection.toolDetails["jobID"], "job-attempt-2")
        XCTAssertFalse(projection.publicNarrative.contains("late attempt one failure"))
    }

    func testRemoteJobReducerLatchesTerminalWithinWinningAttempt() throws {
        let failed = remoteRecord(
            id: "dispatch-terminal-1",
            logicalDispatchID: "logical-terminal-latch",
            remoteJobID: "job-terminal-latch",
            status: .failed,
            remoteStatus: .failed,
            updatedAt: Date(timeIntervalSince1970: 10_000),
            errorMessage: "attempt failed")
        let delayedRunning = remoteRecord(
            id: "dispatch-delayed-running-1",
            logicalDispatchID: "logical-terminal-latch",
            remoteJobID: "job-terminal-latch",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 10_100))

        let projection = try XCTUnwrap(
            ChatRemoteJobReducer.project([failed, delayedRunning]).first)

        XCTAssertEqual(projection.attempt, 1)
        XCTAssertNil(projection.publicState)
        XCTAssertEqual(projection.terminalOutcome, .failed)
        XCTAssertEqual(projection.blocker, "attempt failed")
        XCTAssertEqual(projection.publicNarrative, "遠端工作失敗 · 查看詳情")
        XCTAssertTrue(projection.toolDetails["lifecycle"]?.contains("失敗") == true)
        XCTAssertEqual(
            projection.occurredAt,
            Date(timeIntervalSince1970: 10_000))
    }

    func testRemoteJobJournalKeepsStableItemAndRejectsLifecycleRegression() throws {
        var journal = ChatTranscriptJournalV1()
        let completed = remoteProjection(
            state: .completed,
            occurredAt: Date(timeIntervalSince1970: 2_000))
        let delivered = remoteProjection(
            state: .delivered,
            occurredAt: Date(timeIntervalSince1970: 2_010))
        let verified = remoteProjection(
            state: .verified,
            occurredAt: Date(timeIntervalSince1970: 2_020))

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: completed,
                threadID: "thread-remote",
                to: &journal
            ).wasAppended)
        guard case .ignored(.lifecycleRegression) =
            ChatTranscriptJournalAdapter.append(
                remoteJob: delivered,
                threadID: "thread-remote",
                to: &journal)
        else {
            return XCTFail("a stale dispatch refresh must not regress the inline item")
        }
        guard case .ignored(.terminalItem(_, phase: .completed)) =
            ChatTranscriptJournalAdapter.append(
                remoteJob: verified,
                threadID: "thread-remote",
                to: &journal)
        else {
            return XCTFail("completed must remain the latched journal terminal phase")
        }

        let items = journal.orderedItems(threadID: "thread-remote")
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].eventIDs.count, 1)
        XCTAssertEqual(items[0].attributes["remotePublicState"], "已完成")
        XCTAssertEqual(items[0].phase, .completed)
    }

    func testRemoteJobFailureTerminallyReplacesRunningInlineItem() throws {
        let running = remoteRecord(
            id: "dispatch-failure-running",
            logicalDispatchID: "logical-terminal-failure",
            remoteJobID: "job-terminal-failure",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 2_100))
        let failed = remoteRecord(
            id: "dispatch-failure-terminal",
            logicalDispatchID: "logical-terminal-failure",
            remoteJobID: "job-terminal-failure",
            status: .failed,
            remoteStatus: .failed,
            updatedAt: Date(timeIntervalSince1970: 2_110),
            errorMessage: "target runner exited safely")
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: try XCTUnwrap(ChatRemoteJobReducer.project([running]).first),
                threadID: "thread-terminal-failure",
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: try XCTUnwrap(ChatRemoteJobReducer.project([failed]).first),
                threadID: "thread-terminal-failure",
                to: &journal
            ).wasAppended)

        let items = journal.orderedItems(threadID: "thread-terminal-failure")
            .filter { $0.kind == .remoteJob }
        let item = try XCTUnwrap(items.first)
        let row = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-terminal-failure",
                from: journal
            ).first)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: row.status))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.eventIDs.count, 2)
        XCTAssertEqual(item.phase, .failed)
        XCTAssertEqual(item.attributes["remoteTerminalOutcome"], "失敗")
        XCTAssertEqual(item.attributes["remoteBlocker"], "target runner exited safely")
        XCTAssertNil(payload.state)
        XCTAssertEqual(payload.terminalOutcome, .failed)
        XCTAssertEqual(payload.blocker, "target runner exited safely")
        XCTAssertEqual(row.text, "遠端工作失敗 · 查看詳情")
    }

    func testRemoteJobCancellationTerminallyReplacesRunningInlineItem() throws {
        let running = remoteRecord(
            id: "dispatch-cancel-running",
            logicalDispatchID: "logical-terminal-cancel",
            remoteJobID: "job-terminal-cancel",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 2_200))
        let cancelled = remoteRecord(
            id: "dispatch-cancel-terminal",
            logicalDispatchID: "logical-terminal-cancel",
            remoteJobID: "job-terminal-cancel",
            status: .failed,
            remoteStatus: .cancelled,
            updatedAt: Date(timeIntervalSince1970: 2_210),
            errorMessage: "cancelled by origin")
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: try XCTUnwrap(ChatRemoteJobReducer.project([running]).first),
                threadID: "thread-terminal-cancel",
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: try XCTUnwrap(ChatRemoteJobReducer.project([cancelled]).first),
                threadID: "thread-terminal-cancel",
                to: &journal
            ).wasAppended)

        let items = journal.orderedItems(threadID: "thread-terminal-cancel")
            .filter { $0.kind == .remoteJob }
        let item = try XCTUnwrap(items.first)
        let row = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-terminal-cancel",
                from: journal
            ).first)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: row.status))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.eventIDs.count, 2)
        XCTAssertEqual(item.phase, .cancelled)
        XCTAssertEqual(item.attributes["remoteTerminalOutcome"], "已取消")
        XCTAssertEqual(item.attributes["remoteBlocker"], "cancelled by origin")
        XCTAssertNil(payload.state)
        XCTAssertEqual(payload.terminalOutcome, .cancelled)
        XCTAssertEqual(payload.blocker, "cancelled by origin")
        XCTAssertEqual(row.text, "遠端工作已取消")
    }

    func testRemoteJobRepeatedRefreshAndRelaunchProjectExactlyOneInlineRow() throws {
        let record = remoteRecord(
            id: "dispatch-one",
            logicalDispatchID: "logical-one",
            remoteJobID: "job-one",
            status: .running,
            remoteStatus: .running,
            updatedAt: Date(timeIntervalSince1970: 3_000))
        let projection = try XCTUnwrap(ChatRemoteJobReducer.project([record]).first)
        var journal = ChatTranscriptJournalV1()

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: projection,
                threadID: "thread-relaunch",
                to: &journal
            ).wasAppended)
        guard case .ignored(.duplicateEvent) =
            ChatTranscriptJournalAdapter.append(
                remoteJob: projection,
                threadID: "thread-relaunch",
                to: &journal)
        else {
            return XCTFail("identical registry refresh must be replay-idempotent")
        }

        let relaunched = try ChatTranscriptJournalV1.restoring(
            from: journal.encodedSnapshot())
        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-relaunch",
            from: relaunched)
        let row = try XCTUnwrap(rows.first)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: row.status))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.eventKind, .toolUse)
        XCTAssertEqual(payload.state, .running)
        XCTAssertEqual(payload.details["jobID"], "job-one")
        XCTAssertFalse(row.text.contains("job-one"))
        XCTAssertFalse(row.text.contains("sha256:"))
    }

    func testRemoteBorrowBlockerUpdatesSameRemoteItemWithoutInventingJobIdentity() throws {
        var journal = ChatTranscriptJournalV1()
        let first = ChatRemoteJobReducer.waitingForTargetBinding(
            logicalKey: "borrow-session-contract-target",
            targetDisplayName: "Mac mini",
            targetDeviceID: "device-real",
            contractID: "contract-real",
            goalID: "goal-real",
            blocker: "等待目標環境綁定",
            occurredAt: Date(timeIntervalSince1970: 4_000))
        let refreshed = ChatRemoteJobReducer.waitingForTargetBinding(
            logicalKey: first.logicalKey,
            targetDisplayName: "Mac mini",
            targetDeviceID: "device-real",
            contractID: "contract-real",
            goalID: "goal-real",
            blocker: "目標設備能力尚未驗證",
            occurredAt: Date(timeIntervalSince1970: 4_010))

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: first,
                threadID: "thread-borrow",
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: refreshed,
                threadID: "thread-borrow",
                to: &journal
            ).wasAppended)

        let items = journal.orderedItems(threadID: "thread-borrow")
            .filter { $0.kind == .remoteJob }
        let row = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-borrow",
                from: journal
            ).first)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: row.status))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].eventIDs.count, 2)
        XCTAssertNil(payload.state)
        XCTAssertEqual(payload.blocker, "目標設備能力尚未驗證")
        XCTAssertNil(payload.details["jobID"])
        XCTAssertNil(payload.details["workPath"])
        XCTAssertEqual(row.text, "等待遠端設備 · 查看詳情")
        XCTAssertTrue(
            payload.details["lifecycle"]?
                .contains("目標設備能力尚未驗證") == true)
        XCTAssertFalse(row.text.contains("device-real"))
        XCTAssertFalse(row.text.contains("contract-real"))
    }

    @MainActor
    func testSuccessfulArmHidesPriorSyntheticBorrowBlocker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-prearm-reconcile-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(
            title: "prearm reconcile",
            workOSGoalID: "goal-prearm-reconcile",
            workOSContractID: "contract-prearm-reconcile")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            pendingRemoteTargetStore: ChatPendingRemoteTargetDiskStore(
                fileURL: directory.appendingPathComponent("pending.json")))
        try await waitForInitialStoreLoad(model)
        let targetDeviceID = "device-prearm-reconcile"
        let sessionID = thread.id.uuidString.lowercased()
        let firstObservedAt = Date(timeIntervalSince1970: 8_280)
        XCTAssertTrue(
            model.recordRemoteBorrowBlocker(
                targetDisplayName: "Mac mini",
                targetDeviceID: targetDeviceID,
                blocker: "待命目標暫時無法保存",
                occurredAt: firstObservedAt))

        let armedTarget = await model.armPendingRemoteTarget(
            grant: TatwoRemoteSessionGrantV1(
                sessionID: sessionID,
                targetDeviceID: targetDeviceID,
                contractID: "contract-prearm-reconcile",
                issuedAt: firstObservedAt),
            goalID: "goal-prearm-reconcile",
            targetDisplayName: "Mac mini",
            now: firstObservedAt.addingTimeInterval(1))
        let target = try XCTUnwrap(armedTarget)
        XCTAssertTrue(
            model.recordPendingRemoteTargetBlocker(
                target: target,
                blocker: "等待下一個一般 Chat 回合",
                occurredAt: firstObservedAt.addingTimeInterval(2)))

        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let journalItems = model.chatTranscriptJournal
            .orderedItems(threadID: threadKey)
            .filter { $0.kind == .remoteJob }
        let visibleRows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: threadKey,
            from: model.chatTranscriptJournal)
            .filter { $0.eventKind == .toolUse }
        let syntheticKey = [
            "borrow",
            sessionID,
            "contract-prearm-reconcile",
            targetDeviceID,
        ].joined(separator: ":")
        let synthetic = try XCTUnwrap(journalItems.first {
            $0.attributes["logicalDispatchID"] == syntheticKey
        })

        XCTAssertEqual(journalItems.count, 2)
        XCTAssertEqual(visibleRows.count, 1)
        XCTAssertEqual(synthetic.phase, .cancelled)
        XCTAssertEqual(synthetic.attributes["remoteProjectionHidden"], "true")
        XCTAssertEqual(
            visibleRows.first?.id,
            journalItems.first {
                $0.attributes["logicalDispatchID"] == target.logicalJobID
            }?.id)
    }

    func testPendingRemoteTargetPersistsExactGrantAndReusesClaimAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-remote-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let now = Date(timeIntervalSince1970: 6_000)
        let grant = TatwoRemoteSessionGrantV1(
            id: "grant-exact",
            sessionID: "session-exact",
            targetDeviceID: "device-exact",
            contractID: "contract-exact",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600))

        let armed = try store.arm(
            grant: grant,
            goalID: "goal-exact",
            targetDisplayName: "Mac mini",
            now: now)

        XCTAssertEqual(armed.grantID, "grant-exact")
        XCTAssertEqual(armed.sessionID, "session-exact")
        XCTAssertEqual(armed.contractID, "contract-exact")
        XCTAssertEqual(armed.goalID, "goal-exact")
        XCTAssertEqual(armed.state, .armed)
        XCTAssertEqual(
            try ChatPendingRemoteTargetDiskStore(fileURL: store.fileURL)
                .pending(sessionID: "session-exact"),
            armed)
        let claimed = try XCTUnwrap(store.claim(sessionID: "session-exact"))
        XCTAssertEqual(claimed.state, .claiming)
        XCTAssertEqual(claimed.claimID, armed.claimID)
        XCTAssertEqual(claimed.logicalJobID, armed.logicalJobID)
        let relaunchedClaim = try XCTUnwrap(
            ChatPendingRemoteTargetDiskStore(fileURL: store.fileURL)
                .claim(sessionID: "session-exact"))
        XCTAssertEqual(relaunchedClaim.state, .claiming)
        XCTAssertEqual(relaunchedClaim.operationID, claimed.operationID)
        XCTAssertEqual(relaunchedClaim.claimID, claimed.claimID)
        XCTAssertEqual(relaunchedClaim.logicalJobID, claimed.logicalJobID)
        XCTAssertEqual(relaunchedClaim.logicalKey, claimed.logicalKey)
        let inflight = try store.markInflight(claimID: claimed.claimID)
        XCTAssertEqual(inflight.state, .inflight)
        let relaunchedInflight = try XCTUnwrap(
            ChatPendingRemoteTargetDiskStore(fileURL: store.fileURL)
                .claim(sessionID: "session-exact"))
        XCTAssertEqual(relaunchedInflight.state, .inflight)
        XCTAssertEqual(relaunchedInflight.operationID, inflight.operationID)
        XCTAssertEqual(relaunchedInflight.claimID, inflight.claimID)
        XCTAssertEqual(relaunchedInflight.logicalJobID, inflight.logicalJobID)
    }

    func testPendingRemoteTargetsStayIsolatedBySessionAndTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-multi-target-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let now = Date(timeIntervalSince1970: 6_050)
        let sessionID = "session-multi-target"
        let first = try store.arm(
            grant: TatwoRemoteSessionGrantV1(
                id: "grant-target-a",
                sessionID: sessionID,
                targetDeviceID: "device-target-a",
                contractID: "contract-multi-target",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(3_600)),
            goalID: "goal-multi-target",
            targetDisplayName: "Mac mini",
            now: now)
        let second = try store.arm(
            grant: TatwoRemoteSessionGrantV1(
                id: "grant-target-b",
                sessionID: sessionID,
                targetDeviceID: "device-target-b",
                contractID: "contract-multi-target",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(3_600)),
            goalID: "goal-multi-target",
            targetDisplayName: "MacBook",
            now: now.addingTimeInterval(1))

        XCTAssertEqual(
            try store.pending(
                sessionID: sessionID,
                targetDeviceID: first.targetDeviceID),
            first)
        XCTAssertEqual(
            try store.pending(
                sessionID: sessionID,
                targetDeviceID: second.targetDeviceID),
            second)
        XCTAssertEqual(try store.pendingTargets(sessionID: sessionID).count, 2)

        let claimedSecond = try XCTUnwrap(
            store.claim(
                sessionID: sessionID,
                targetDeviceID: second.targetDeviceID))
        XCTAssertEqual(claimedSecond.claimID, second.claimID)
        XCTAssertEqual(claimedSecond.state, .claiming)
        XCTAssertEqual(
            try store.pending(
                sessionID: sessionID,
                targetDeviceID: first.targetDeviceID)?.state,
            .armed)

        XCTAssertThrowsError(try store.claim(sessionID: sessionID)) { error in
            guard case ChatPendingRemoteTargetStoreError.ambiguousTargets(let targets) = error
            else {
                return XCTFail("expected ambiguousTargets, got \(error)")
            }
            XCTAssertEqual(Set(targets.map(\.targetDeviceID)), [
                first.targetDeviceID,
                second.targetDeviceID,
            ])
        }
        let claimedFirst = try XCTUnwrap(
            store.claim(
                sessionID: sessionID,
                targetDeviceID: first.targetDeviceID))
        XCTAssertEqual(claimedFirst.claimID, first.claimID)
        XCTAssertEqual(claimedFirst.state, .claiming)
        XCTAssertTrue(
            try store.invalidate(
                sessionID: sessionID,
                targetDeviceID: second.targetDeviceID))
        XCTAssertNil(
            try store.pending(
                sessionID: sessionID,
                targetDeviceID: second.targetDeviceID))
        XCTAssertEqual(
            try store.pending(
                sessionID: sessionID,
                targetDeviceID: first.targetDeviceID)?.claimID,
            first.claimID)
    }

    func testRearmAfterConsumedCreatesNewOperationAndJobIdentities() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-rearm-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let now = Date(timeIntervalSince1970: 6_100)
        let grant = TatwoRemoteSessionGrantV1(
            id: "grant-rearm",
            sessionID: "session-rearm",
            targetDeviceID: "device-rearm",
            contractID: "contract-rearm",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600))
        let first = try store.arm(
            grant: grant,
            goalID: "goal-rearm",
            targetDisplayName: "Mac mini",
            now: now)
        _ = try store.claim(sessionID: first.sessionID)
        _ = try store.markInflight(claimID: first.claimID)
        _ = try store.markAccepted(
            claimID: first.claimID,
            remoteJobID: "job-first",
            acceptedAt: now.addingTimeInterval(1))
        try store.consumeAccepted(claimID: first.claimID)

        let second = try store.arm(
            grant: grant,
            goalID: "goal-rearm",
            targetDisplayName: "Mac mini",
            now: now.addingTimeInterval(2))

        XCTAssertEqual(second.state, .armed)
        XCTAssertNotEqual(second.operationID, first.operationID)
        XCTAssertNotEqual(second.claimID, first.claimID)
        XCTAssertNotEqual(second.logicalJobID, first.logicalJobID)
        XCTAssertNotEqual(second.logicalKey, first.logicalKey)
        XCTAssertEqual(
            try XCTUnwrap(store.claim(sessionID: second.sessionID)).claimID,
            second.claimID)
    }

    func testRearmedBorrowCreatesANewRemoteTranscriptRow() throws {
        var journal = ChatTranscriptJournalV1()
        let first = ChatPendingRemoteTargetV1(
            sessionID: "session-rearm-row",
            contractID: "contract-rearm-row",
            goalID: "goal-rearm-row",
            targetDeviceID: "device-rearm-row",
            targetDisplayName: "Mac mini",
            grantID: "grant-rearm-row",
            issuedAt: Date(timeIntervalSince1970: 6_200),
            operationID: "operation-first",
            claimID: "claim-first",
            logicalJobID: "logical-first")
        let second = ChatPendingRemoteTargetV1(
            sessionID: first.sessionID,
            contractID: first.contractID,
            goalID: first.goalID,
            targetDeviceID: first.targetDeviceID,
            targetDisplayName: first.targetDisplayName,
            grantID: first.grantID,
            issuedAt: first.issuedAt,
            operationID: "operation-second",
            claimID: "claim-second",
            logicalJobID: "logical-second")

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: ChatRemoteJobReducer.waitingForTargetBinding(
                    logicalKey: first.logicalKey,
                    targetDisplayName: first.targetDisplayName,
                    targetDeviceID: first.targetDeviceID,
                    contractID: first.contractID,
                    goalID: first.goalID,
                    blocker: "等待第一個一般 Chat 回合",
                    occurredAt: Date(timeIntervalSince1970: 6_200)),
                threadID: "thread-rearm-row",
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: ChatRemoteJobReducer.waitingForTargetBinding(
                    logicalKey: second.logicalKey,
                    targetDisplayName: second.targetDisplayName,
                    targetDeviceID: second.targetDeviceID,
                    contractID: second.contractID,
                    goalID: second.goalID,
                    blocker: "等待第二個一般 Chat 回合",
                    occurredAt: Date(timeIntervalSince1970: 6_210)),
                threadID: "thread-rearm-row",
                to: &journal
            ).wasAppended)

        let remoteRows = journal.orderedItems(threadID: "thread-rearm-row")
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 2)
        XCTAssertNotEqual(remoteRows[0].id, remoteRows[1].id)
    }

    func testUnavailableRemoteDispatcherFailsClosedWithoutInventingJobIdentity() throws {
        let request = ChatRemoteTurnDispatchRequest(
            visibleTurn: "run tests",
            invocation: TatwoRemoteBorrowInvocationV1(
                sessionID: "session-1",
                targetDeviceID: "device-1",
                contractID: "contract-1",
                goalID: "goal-1",
                mode: .manual,
                risk: .lowRisk,
                grantID: "grant-1"),
            claimID: "claim-1",
            logicalJobID: "logical-1",
            contractMode: .xl,
            agent: .codex,
            exactModelRouteID: "gpt-5.5",
            readinessChallengeNonce: "challenge-1",
            targetReadinessManifest: nil,
            readinessBinding: nil)

        XCTAssertEqual(
            ChatUnavailableRemoteTurnDispatcher().dispatch(request),
            .blocked(.adapterUnavailable))
    }

    func testUnavailableDispatchReleasesClaimForRetryWithSameIdentities() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-unavailable-\(UUID().uuidString)",
                isDirectory: true)
        let store = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let now = Date()
        let target = try store.arm(
            grant: TatwoRemoteSessionGrantV1(
                sessionID: "session-unavailable",
                targetDeviceID: "device-unavailable",
                contractID: "contract-unavailable",
                issuedAt: now),
            goalID: "goal-unavailable",
            targetDisplayName: "Mac mini",
            now: now)
        let claimed = try XCTUnwrap(
            store.claim(sessionID: target.sessionID))
        _ = try store.markInflight(claimID: claimed.claimID)
        let outcome = ChatUnavailableRemoteTurnDispatcher().dispatch(
            ChatRemoteTurnDispatchRequest(
                visibleTurn: "do not fake a job",
                invocation: TatwoRemoteBorrowInvocationV1(
                    sessionID: claimed.sessionID,
                    targetDeviceID: claimed.targetDeviceID,
                    contractID: claimed.contractID,
                    goalID: claimed.goalID,
                    mode: .manual,
                    risk: .lowRisk,
                    grantID: claimed.grantID),
                claimID: claimed.claimID,
                logicalJobID: claimed.logicalJobID,
                contractMode: .xl,
                agent: .codex,
                exactModelRouteID: "gpt-5.5",
                readinessChallengeNonce: "challenge-unavailable",
                targetReadinessManifest: nil,
                readinessBinding: nil))

        XCTAssertEqual(outcome, .blocked(.adapterUnavailable))
        let released = try store.releaseForRetry(claimID: claimed.claimID)
        XCTAssertEqual(released.state, .armed)
        XCTAssertEqual(released.claimID, claimed.claimID)
        XCTAssertEqual(released.logicalJobID, claimed.logicalJobID)
        let retried = try XCTUnwrap(store.claim(sessionID: target.sessionID))
        XCTAssertEqual(retried.state, .claiming)
        XCTAssertEqual(retried.claimID, claimed.claimID)
        XCTAssertEqual(retried.logicalJobID, claimed.logicalJobID)
        let blocker = ChatRemoteJobReducer.waitingForTargetBinding(
            logicalKey: target.logicalKey,
            targetDisplayName: target.targetDisplayName,
            targetDeviceID: target.targetDeviceID,
            contractID: target.contractID,
            goalID: target.goalID,
            blocker: ChatRemoteTurnDispatchBlocker.adapterUnavailable.rawValue,
            occurredAt: now)
        XCTAssertNil(blocker.toolDetails["jobID"])
        XCTAssertNil(blocker.toolDetails["workPath"])
    }

    @MainActor
    func testSessionOnlyTurnWithTwoArmedTargetsFailsClosedWithoutDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-ambiguous-runtime-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(
            title: "ambiguous remote targets",
            workOSGoalID: "goal-ambiguous",
            workOSContractID: "contract-ambiguous")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent("authorization", isDirectory: true))
        let now = Date()
        let sessionID = thread.id.uuidString.lowercased()
        let grantA = try authorizationStore.issueSessionGrant(
            sessionID: sessionID,
            targetDeviceID: "device-arm-a",
            contractID: "contract-ambiguous",
            now: now)
        let grantB = try authorizationStore.issueSessionGrant(
            sessionID: sessionID,
            targetDeviceID: "device-arm-b",
            contractID: "contract-ambiguous",
            now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let targetA = try pendingStore.arm(
            grant: grantA,
            goalID: "goal-ambiguous",
            targetDisplayName: "Mac mini",
            now: now)
        let targetB = try pendingStore.arm(
            grant: grantB,
            goalID: "goal-ambiguous",
            targetDisplayName: "MacBook",
            now: now.addingTimeInterval(1))
        let dispatcher = RecordingRemoteTurnDispatcher(
            outcome: .blocked(.dispatchRejected))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher)
        try await waitForInitialStoreLoad(model)

        model.prompt = "must choose one remote target"
        model.submitCurrentChatTurn()
        try await waitUntil {
            !model.isRunning
                && model.composerHint?.contains("2 個待命遠端目標") == true
        }

        XCTAssertTrue(dispatcher.requests.isEmpty)
        XCTAssertEqual(
            try pendingStore.pending(
                sessionID: sessionID,
                targetDeviceID: targetA.targetDeviceID)?.state,
            .armed)
        XCTAssertEqual(
            try pendingStore.pending(
                sessionID: sessionID,
                targetDeviceID: targetB.targetDeviceID)?.state,
            .armed)
        XCTAssertTrue(
            model.messages.contains {
                $0.role == .user && $0.text == "must choose one remote target"
            })
        let remoteRows = model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id
                ).stableKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 2)
        XCTAssertEqual(
            Set(remoteRows.compactMap { $0.attributes["detail.targetDeviceID"] }),
            [targetA.targetDeviceID, targetB.targetDeviceID])
        XCTAssertTrue(
            remoteRows.allSatisfy {
                $0.attributes["remoteBlocker"]?.contains(
                    "同時有 2 個待命遠端目標") == true
            })
    }

    @MainActor
    func testNextOrdinaryTurnConsumesPendingTargetAndDispatchesExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-dispatch-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(
            title: "remote",
            workOSGoalID: "goal-remote",
            workOSContractID: "contract-remote")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent("authorization", isDirectory: true))
        let now = Date()
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: thread.id.uuidString.lowercased(),
            targetDeviceID: "device-remote",
            contractID: "contract-remote",
            now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let goalRunStore = TatwoGoalRunStore(directoryURL: directory)
        try writeGoalRun(
            TatwoStoredGoalRun(
                goalID: "goal-remote",
                contractID: "contract-remote",
                mode: .xl,
                scenario: "chat-remote-test",
                objective: "dispatch one queued Chat turn",
                status: .planned,
                issuedAt: now,
                updatedAt: now),
            to: goalRunStore)
        let pending = try pendingStore.arm(
            grant: grant,
            goalID: "goal-remote",
            targetDisplayName: "Mac mini",
            now: now)
        let dispatcher = RecordingRemoteTurnDispatcher(
            outcome: .accepted(
                ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: pending.logicalJobID,
                    remoteJobID: "job-real",
                    acceptedAt: now)))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: journalStore,
            goalRunStore: goalRunStore,
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher)
        try await waitForInitialStoreLoad(model)

        model.prompt = "/issue list"
        model.send()
        XCTAssertTrue(dispatcher.requests.isEmpty)
        XCTAssertNotNil(try pendingStore.pending(sessionID: grant.sessionID))

        model.isRunning = true
        model.prompt = "run focused tests"
        model.submitCurrentChatTurn()
        XCTAssertTrue(dispatcher.requests.isEmpty)
        XCTAssertNotNil(try pendingStore.pending(sessionID: grant.sessionID))
        XCTAssertEqual(model.queuedChatTurnCount, 1)

        model.isRunning = false
        model.resumeQueuedChatTurns()
        try await waitUntil {
            dispatcher.requests.count == 1 && !model.isRunning
        }

        XCTAssertEqual(dispatcher.requests.count, 1)
        XCTAssertEqual(dispatcher.requests[0].visibleTurn, "run focused tests")
        XCTAssertEqual(dispatcher.requests[0].invocation.grantID, grant.id)
        XCTAssertEqual(dispatcher.requests[0].claimID, pending.claimID)
        XCTAssertEqual(dispatcher.requests[0].logicalJobID, pending.logicalJobID)
        XCTAssertEqual(dispatcher.requests[0].contractMode, .xl)
        XCTAssertEqual(dispatcher.requests[0].agent, .codex)
        XCTAssertEqual(dispatcher.requests[0].exactModelRouteID, "gpt-5.5")
        XCTAssertTrue(
            TatwoLoopPathComponent.isValid(
                dispatcher.requests[0].readinessChallengeNonce))
        XCTAssertNil(dispatcher.requests[0].targetReadinessManifest)
        XCTAssertNil(dispatcher.requests[0].readinessBinding)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(try pendingStore.pending(sessionID: grant.sessionID))
        let remoteRows = model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id
                ).stableKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(remoteRows[0].attributes["detail.jobID"], "job-real")
    }

    @MainActor
    func testStopImmediatelyCancelsPendingRemoteClaimBeforeDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-stop-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(
            title: "remote stop",
            workOSGoalID: "goal-stop",
            workOSContractID: "contract-stop")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent("authorization", isDirectory: true))
        let now = Date()
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: thread.id.uuidString.lowercased(),
            targetDeviceID: "device-stop",
            contractID: "contract-stop",
            now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let goalRunStore = TatwoGoalRunStore(directoryURL: directory)
        try writeGoalRun(
            TatwoStoredGoalRun(
                goalID: "goal-stop",
                contractID: "contract-stop",
                mode: .xl,
                scenario: "chat-remote-stop-test",
                objective: "stop before remote dispatch",
                status: .planned,
                issuedAt: now,
                updatedAt: now),
            to: goalRunStore)
        let pending = try pendingStore.arm(
            grant: grant,
            goalID: "goal-stop",
            targetDisplayName: "Mac mini",
            now: now)
        let dispatcher = RecordingRemoteTurnDispatcher(
            outcome: .accepted(
                ChatRemoteTurnDispatchAcceptance(
                    logicalJobID: pending.logicalJobID,
                    remoteJobID: "job-must-not-exist",
                    acceptedAt: now)))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalRunStore,
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher)
        try await waitForInitialStoreLoad(model)

        model.prompt = "do not dispatch after stop"
        model.submitCurrentChatTurn()
        model.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(dispatcher.requests.isEmpty)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(
            try pendingStore.pending(sessionID: grant.sessionID)?.state,
            .armed)
        let remoteRows = model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id
                ).stableKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertTrue(
            remoteRows.allSatisfy {
                $0.attributes["detail.jobID"] != "job-must-not-exist"
            })
    }

    @MainActor
    func testAcceptedRelaunchJournalsOnceWithoutRedispatchAndContinuesFreshPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-accepted-relaunch-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(
            title: "accepted relaunch",
            workOSGoalID: "goal-accepted",
            workOSContractID: "contract-accepted")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent("authorization", isDirectory: true))
        let now = Date()
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: thread.id.uuidString.lowercased(),
            targetDeviceID: "device-accepted",
            contractID: "contract-accepted",
            now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let armed = try pendingStore.arm(
            grant: grant,
            goalID: "goal-accepted",
            targetDisplayName: "Mac mini",
            now: now)
        _ = try pendingStore.claim(sessionID: armed.sessionID)
        _ = try pendingStore.markInflight(claimID: armed.claimID)
        let accepted = try pendingStore.markAccepted(
            claimID: armed.claimID,
            remoteJobID: "job-accepted",
            acceptedAt: now)
        let dispatcher = RecordingRemoteTurnDispatcher(
            outcome: .blocked(.dispatchRejected))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher)
        try await waitForInitialStoreLoad(model)

        model.prompt = "reconcile accepted receipt"
        model.submitCurrentChatTurn()
        try await waitUntil {
            (try? pendingStore.pending(sessionID: accepted.sessionID)) == nil
                && !model.lastCommand.isEmpty
        }
        model.stop()

        XCTAssertTrue(dispatcher.requests.isEmpty)
        let remoteRows = model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id
                ).stableKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(remoteRows[0].eventIDs.count, 1)
        XCTAssertEqual(remoteRows[0].attributes["detail.jobID"], "job-accepted")
        XCTAssertEqual(
            remoteRows[0].attributes["detail.logicalJobID"],
            accepted.logicalJobID)
        XCTAssertFalse(
            model.lastCommand.isEmpty,
            "the previous accepted receipt must not consume the newly submitted prompt")
        XCTAssertTrue(
            model.messages.contains {
                $0.role == .user && $0.text == "reconcile accepted receipt"
            })
    }

    @MainActor
    func testRevokedGrantInvalidatesPendingTargetWithoutCallingDispatcher() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-revoked-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(
            title: "revoked",
            workOSGoalID: "goal-revoked",
            workOSContractID: "contract-revoked")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent("authorization", isDirectory: true))
        let now = Date()
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: thread.id.uuidString.lowercased(),
            targetDeviceID: "device-revoked",
            contractID: "contract-revoked",
            now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        _ = try pendingStore.arm(
            grant: grant,
            goalID: "goal-revoked",
            targetDisplayName: "Mac mini",
            now: now)
        _ = try authorizationStore.revokeSession(
            sessionID: grant.sessionID,
            now: now.addingTimeInterval(1))
        let dispatcher = RecordingRemoteTurnDispatcher(
            outcome: .blocked(.dispatchRejected))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher)
        try await waitForInitialStoreLoad(model)

        model.prompt = "must not dispatch"
        model.submitCurrentChatTurn()
        try await waitUntil {
            !model.isRunning
                && (try? pendingStore.pending(sessionID: grant.sessionID)) == nil
        }

        XCTAssertTrue(dispatcher.requests.isEmpty)
        XCTAssertNil(try pendingStore.pending(sessionID: grant.sessionID))
        XCTAssertFalse(model.isRunning)
        let remoteRows = model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id
                ).stableKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(
            remoteRows[0].attributes["remoteBlocker"],
            "遠端借用許可已撤銷或過期")
    }

    @MainActor
    func testGoalCloseInvalidatesArmedPendingTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-goal-close-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let goalRunStore = TatwoGoalRunStore(
            directoryURL: directory.appendingPathComponent(
                "work-os-state",
                isDirectory: true))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "Close the exact active chat goal",
            store: goalRunStore)
        for receipt in contract.receiptRequirements where receipt.requiredForPass {
            let result = WorkOSFactory.submitReceipt(
                goalID: contract.goalID,
                contractID: contract.contractID,
                loopID: contract.mainlineLoop.id,
                receiptID: receipt.id,
                receiptKind: "goal-close-pending-target-test",
                store: goalRunStore)
            XCTAssertTrue(result.ok, result.decision.message)
        }
        let registry = TatwoDispatchRegistry(directoryURL: goalRunStore.directoryURL)
        try WorkOSFactory.finalizeSuccessfulDispatchFixtureForTesting(
            contract: contract, store: goalRunStore, registry: registry)
        XCTAssertEqual(
            try goalRunStore.requireIssuedContract(contract.contractID).status,
            .awaitingNextCycle)
        let thread = TatwoNativeChatThread(
            title: "goal close",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let sessionStore = TatwoSessionStore(
            directoryURL: goalRunStore.directoryURL)
        try sessionStore.writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective))
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let now = Date()
        _ = try pendingStore.arm(
            grant: TatwoRemoteSessionGrantV1(
                sessionID: thread.id.uuidString.lowercased(),
                targetDeviceID: "device-close",
                contractID: contract.contractID,
                issuedAt: now),
            goalID: contract.goalID,
            targetDisplayName: "Mac mini",
            now: now)
        let goalDirectory = goalRunStore.directoryURL.appendingPathComponent(
            "goals",
            isDirectory: true)
        let goalFileCountBefore = try FileManager.default.contentsOfDirectory(
            at: goalDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .count
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalRunStore,
            pendingRemoteTargetStore: pendingStore)
        try await waitForInitialStoreLoad(model)

        model.endActiveGoal()
        try await waitUntil {
            (try? pendingStore.pending(
                sessionID: thread.id.uuidString.lowercased())) == nil
        }

        XCTAssertNil(
            try pendingStore.pending(
                sessionID: thread.id.uuidString.lowercased()))
        XCTAssertNil(try sessionStore.current())
        XCTAssertEqual(
            try goalRunStore.requireIssuedContract(contract.contractID).status,
            .passed)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains(
                "普通 Chat 不會自動建立 Goal"),
            model.selectedWorkOSStateMessage)
        let goalFileCountAfter = try FileManager.default.contentsOfDirectory(
            at: goalDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .count
        XCTAssertEqual(goalFileCountAfter, goalFileCountBefore)
    }

    @MainActor
    func testVerifiedTargetTrustLossInvalidatesPendingTargetAndKeepsOneRemoteRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-pending-trust-loss-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(
            title: "trust loss",
            workOSGoalID: "goal-trust",
            workOSContractID: "contract-trust")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let now = Date()
        let target = try pendingStore.arm(
            grant: TatwoRemoteSessionGrantV1(
                sessionID: thread.id.uuidString.lowercased(),
                targetDeviceID: "device-trust",
                contractID: "contract-trust",
                issuedAt: now),
            goalID: "goal-trust",
            targetDisplayName: "Mac mini",
            now: now)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: journalStore,
            pendingRemoteTargetStore: pendingStore)
        try await waitForInitialStoreLoad(model)
        XCTAssertTrue(
            model.recordPendingRemoteTargetBlocker(
                target: target,
                blocker: "等待下一個一般 Chat 回合",
                occurredAt: now))

        model.revalidatePendingRemoteTarget(
            verifiedTargetDeviceIDs: [],
            definitiveLeaseLossBlocker: nil)
        try await waitUntil {
            let remoteRows = model.chatTranscriptJournal
                .orderedItems(
                    threadID: TatwoNativeChatSessionReference(
                        kind: .thread,
                        id: thread.id
                    ).stableKey)
                .filter { $0.kind == .remoteJob }
            return (try? pendingStore.pending(sessionID: target.sessionID)) == nil
                && remoteRows.first?.attributes["remoteBlocker"]
                    == ChatRemoteTurnDispatchBlocker.targetTrustLost.rawValue
        }

        XCTAssertNil(try pendingStore.pending(sessionID: target.sessionID))
        let remoteRows = model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id
                ).stableKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(
            remoteRows[0].attributes["remoteBlocker"],
            ChatRemoteTurnDispatchBlocker.targetTrustLost.rawValue)
        XCTAssertNil(remoteRows[0].attributes["detail.jobID"])
    }

    func testColdStartOrphanReconciliationDoesNotCancelDurableRemoteLifecycle() throws {
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: remoteProjection(
                    state: .running,
                    occurredAt: Date(timeIntervalSince1970: 5_000)),
                threadID: "thread-remote-orphan",
                projectionProcessID: "process-before-relaunch",
                to: &journal
            ).wasAppended)

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.cancelColdStartOrphans(
                activeRunIDs: [],
                reclaimTokens: [],
                in: &journal
            ).isEmpty)
        let item = try XCTUnwrap(
            journal.orderedItems(threadID: "thread-remote-orphan").first)
        XCTAssertEqual(item.kind, .remoteJob)
        XCTAssertEqual(item.attributes["remotePublicState"], "執行中")
        XCTAssertEqual(item.phase, .running)
    }

    func testAcceptedRemoteJobRelaunchBecomesPreservedUnknownAndNonActive() throws {
        var journal = ChatTranscriptJournalV1()
        let accepted = remoteProjection(
            state: .started,
            occurredAt: Date(timeIntervalSince1970: 5_100))
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: accepted,
                threadID: "thread-remote-accepted-relaunch",
                projectionProcessID: "process-before-relaunch",
                to: &journal
            ).wasAppended)
        let stableItemID = try XCTUnwrap(
            journal.orderedItems(threadID: "thread-remote-accepted-relaunch").first?.id)

        let outcomes = ChatTranscriptJournalAdapter.markColdStartRemoteJobsUnknown(
            projectionProcessID: "process-after-relaunch",
            occurredAt: Date(timeIntervalSince1970: 5_110),
            in: &journal)

        XCTAssertEqual(outcomes, [.appended])
        let item = try XCTUnwrap(
            journal.orderedItems(threadID: "thread-remote-accepted-relaunch").first)
        let row = try XCTUnwrap(
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: "thread-remote-accepted-relaunch",
                from: journal
            ).first)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: row.status))
        XCTAssertEqual(item.id, stableItemID)
        XCTAssertEqual(item.eventIDs.count, 2)
        XCTAssertEqual(item.phase, .running)
        XCTAssertEqual(item.attributes["remoteColdStartOrphaned"], "true")
        XCTAssertNil(payload.state)
        XCTAssertNil(payload.terminalOutcome)
        XCTAssertEqual(payload.runtimeTruth, .unknownAfterRelaunch)
        XCTAssertEqual(
            payload.details["lastKnownPublicState"],
            ChatRemoteJobPublicState.started.rawValue)
        XCTAssertEqual(
            row.text,
            "遠端工作狀態未知 · 等待目標端權威證據")
        XCTAssertFalse(ChatRemoteJobInlineActivityPolicy.isActive(payload))
    }

    func testRunningRemoteJobRelaunchUnknownIsIdempotentAndTerminalStillWins() throws {
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: remoteProjection(
                    state: .running,
                    occurredAt: Date(timeIntervalSince1970: 5_200)),
                threadID: "thread-remote-running-relaunch",
                projectionProcessID: "process-before-relaunch",
                to: &journal
            ).wasAppended)

        XCTAssertEqual(
            ChatTranscriptJournalAdapter.markColdStartRemoteJobsUnknown(
                projectionProcessID: "process-after-relaunch",
                occurredAt: Date(timeIntervalSince1970: 5_210),
                in: &journal),
            [.appended])
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.markColdStartRemoteJobsUnknown(
                projectionProcessID: "process-after-relaunch",
                occurredAt: Date(timeIntervalSince1970: 5_220),
                in: &journal
            ).isEmpty)

        let unknownItem = try XCTUnwrap(
            journal.orderedItems(threadID: "thread-remote-running-relaunch").first)
        XCTAssertEqual(unknownItem.eventIDs.count, 2)
        XCTAssertEqual(
            unknownItem.attributes["remoteRuntimeTruth"],
            ChatRemoteJobRuntimeTruth.unknownAfterRelaunch.rawValue)

        var terminalJournal = ChatTranscriptJournalV1()
        let terminal = ChatRemoteJobProjection(
            logicalKey: "logical-terminal-relaunch",
            attempt: 1,
            publicState: nil,
            terminalOutcome: .failed,
            runtimeTruth: .terminalReceipt,
            publicNarrative: "遠端工作失敗 · 查看詳情",
            blocker: "terminal receipt",
            toolDetails: ["receiptID": "receipt-terminal"],
            occurredAt: Date(timeIntervalSince1970: 5_230),
            identity: .observation,
            isHidden: false)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                remoteJob: terminal,
                threadID: "thread-remote-terminal-relaunch",
                projectionProcessID: "process-before-relaunch",
                to: &terminalJournal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.markColdStartRemoteJobsUnknown(
                projectionProcessID: "process-after-relaunch",
                occurredAt: Date(timeIntervalSince1970: 5_240),
                in: &terminalJournal
            ).isEmpty)
        let terminalItem = try XCTUnwrap(
            terminalJournal
                .orderedItems(threadID: "thread-remote-terminal-relaunch")
                .first)
        XCTAssertEqual(terminalItem.phase, .failed)
        XCTAssertEqual(terminalItem.eventIDs.count, 1)
        XCTAssertEqual(
            terminalItem.attributes["remoteRuntimeTruth"],
            ChatRemoteJobRuntimeTruth.terminalReceipt.rawValue)
    }

    @MainActor
    func testComposerDraftSwitchFlushKeepsThreadAndDiscussionIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-draft-switch-isolation-\(UUID().uuidString)",
                isDirectory: true)
        let discussion = TatwoNativeDiscussion(
            title: "Child",
            inheritedSnapshot: "")
        let thread = TatwoNativeChatThread(
            title: "Parent",
            discussions: [discussion])
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let draftStore = TatwoChatComposerDraftStore.colocated(with: nativeStore.url)
        let model = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)

        model.selectStandaloneThread(thread.id)
        model.prompt = "parent draft"
        model.selectDiscussion(
            projectID: nil,
            threadID: thread.id,
            discussionID: discussion.id)

        let parentReference = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id)
        XCTAssertEqual(
            try draftStore.load().draftsBySessionKey[parentReference.stableKey],
            "parent draft")
        XCTAssertEqual(model.prompt, "")

        model.prompt = "child draft"
        model.selectStandaloneThread(thread.id)
        XCTAssertEqual(model.prompt, "parent draft")
        model.selectDiscussion(
            projectID: nil,
            threadID: thread.id,
            discussionID: discussion.id)
        XCTAssertEqual(model.prompt, "child draft")
    }

    @MainActor
    func testComposerDraftRestoresAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-draft-relaunch-\(UUID().uuidString)",
                isDirectory: true)
        let thread = TatwoNativeChatThread(title: "Relaunch")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let draftStore = TatwoChatComposerDraftStore.colocated(with: nativeStore.url)
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let model = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)
        model.selectStandaloneThread(thread.id)
        model.prompt = "survive relaunch"
        XCTAssertTrue(model.flushCurrentComposerDraft())

        let relaunched = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: journalStore)
        try await waitForInitialStoreLoad(relaunched)
        relaunched.selectStandaloneThread(thread.id)
        XCTAssertEqual(relaunched.prompt, "survive relaunch")
    }

    @MainActor
    func testSelectingSecondUserOwnedRowDoesNotRenderFirstRowIndependentJournal()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-dual-row-transcript-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let threadA = TatwoNativeChatThread(
            title: "/plan expense_ledger",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned)
        let threadB = TatwoNativeChatThread(
            title: "/plan habit_grid",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [threadA, threadB]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        var journal = ChatTranscriptJournalV1()
        let keyA = TatwoNativeChatSessionReference(
            kind: .thread,
            id: threadA.id
        ).stableKey
        let keyB = TatwoNativeChatSessionReference(
            kind: .thread,
            id: threadB.id
        ).stableKey
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "user-a",
                    role: .user,
                    text: "在 session-plan-goal-r5 內建立 expense_ledger",
                    eventKind: .message,
                    createdAt: t0),
                threadID: keyA,
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "result-a",
                    role: .assistant,
                    text: "已完成 expense_ledger，共 3 個檔案",
                    eventKind: .message,
                    createdAt: t0.addingTimeInterval(1)),
                threadID: keyA,
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "user-b",
                    role: .user,
                    text: "在 session-plan-plg-r5 內建立 habit_grid",
                    eventKind: .message,
                    createdAt: t0.addingTimeInterval(2)),
                threadID: keyB,
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "result-b",
                    role: .assistant,
                    text: "已完成 habit_grid，共 6 個檔案",
                    eventKind: .message,
                    createdAt: t0.addingTimeInterval(3)),
                threadID: keyB,
                to: &journal
            ).wasAppended)
        try journalStore.save(journal)

        let model = makeModel(store: nativeStore, transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)
        let projectedA = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: keyA,
            from: model.chatTranscriptJournal)
        let projectedB = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: keyB,
            from: model.chatTranscriptJournal)
        XCTAssertTrue(projectedA.contains { $0.text.contains("expense_ledger") })
        XCTAssertFalse(projectedA.contains { $0.text.contains("habit_grid") })
        XCTAssertTrue(projectedB.contains { $0.text.contains("habit_grid") })
        XCTAssertFalse(projectedB.contains { $0.text.contains("expense_ledger") })

        model.selectStandaloneThread(threadA.id)
        XCTAssertTrue(
            model.transcriptMessages.contains { $0.text.contains("expense_ledger") })
        XCTAssertFalse(
            model.transcriptMessages.contains { $0.text.contains("habit_grid") })

        model.selectStandaloneThread(threadB.id)
        XCTAssertTrue(
            model.transcriptMessages.contains { $0.text.contains("habit_grid") })
        XCTAssertFalse(
            model.transcriptMessages.contains { $0.text.contains("expense_ledger") })

        // Shared in-memory fallback: a background turn can seed the selected
        // row's live buffer/cache with another thread's completed transcript.
        // Clicking B must still project B's independent journal.
        model.messages = projectedA + projectedB
        model.preserveCurrentMessages()
        model.selectStandaloneThread(threadA.id)
        model.selectStandaloneThread(threadB.id)

        let selectedTexts = model.transcriptMessages.map(\.text)
        XCTAssertTrue(
            selectedTexts.contains { $0.contains("habit_grid") },
            selectedTexts.joined(separator: " | "))
        XCTAssertFalse(
            selectedTexts.contains { $0.contains("expense_ledger") },
            selectedTexts.joined(separator: " | "))
        XCTAssertFalse(
            selectedTexts.contains { $0.contains("session-plan-goal-r5") },
            selectedTexts.joined(separator: " | "))
    }

    @MainActor
    func testAcceptedQueuedSendClearsOnlyAcceptedSessionDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-draft-accepted-clear-\(UUID().uuidString)",
                isDirectory: true)
        let threadA = TatwoNativeChatThread(title: "A")
        let threadB = TatwoNativeChatThread(title: "B")
        let referenceA = TatwoNativeChatSessionReference(kind: .thread, id: threadA.id)
        let referenceB = TatwoNativeChatSessionReference(kind: .thread, id: threadB.id)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [threadA, threadB]))
        let draftStore = TatwoChatComposerDraftStore.colocated(with: nativeStore.url)
        try draftStore.save([
            referenceA.stableKey: "send me",
            referenceB.stableKey: "keep me",
        ])
        let model = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)
        model.selectStandaloneThread(threadA.id)
        model.isRunning = true

        model.submitCurrentChatTurn(applyPromptCollaboration: false)

        XCTAssertEqual(model.queuedChatTurnCount, 1)
        XCTAssertEqual(model.prompt, "")
        let stored = try draftStore.load().draftsBySessionKey
        XCTAssertNil(stored[referenceA.stableKey])
        XCTAssertEqual(stored[referenceB.stableKey], "keep me")
    }

    @MainActor
    func testJournalWriteFailurePreservesPromptAndDurableDraftWithWarning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-draft-journal-failure-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let thread = TatwoNativeChatThread(title: "Fail safely")
        let reference = TatwoNativeChatSessionReference(kind: .thread, id: thread.id)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let draftStore = TatwoChatComposerDraftStore.colocated(with: nativeStore.url)
        let blockedParent = directory.appendingPathComponent("journal-blocker")
        try Data("block".utf8).write(to: blockedParent)
        let model = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: ChatTranscriptJournalDiskStore(
                fileURL: blockedParent.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)
        model.selectStandaloneThread(thread.id)
        model.prompt = "do not lose this"
        XCTAssertTrue(model.flushCurrentComposerDraft())

        model.submitCurrentChatTurn(applyPromptCollaboration: false)

        XCTAssertEqual(model.prompt, "do not lose this")
        XCTAssertEqual(
            try draftStore.load().draftsBySessionKey[reference.stableKey],
            "do not lose this")
        XCTAssertTrue(model.composerHint?.contains("送出失敗") == true)
    }

    @MainActor
    func testContainerCloseFlushesPendingComposerDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-draft-close-flush-\(UUID().uuidString)",
                isDirectory: true)
        let thread = TatwoNativeChatThread(title: "Close")
        let reference = TatwoNativeChatSessionReference(kind: .thread, id: thread.id)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let draftStore = TatwoChatComposerDraftStore.colocated(with: nativeStore.url)
        let model = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")))
        try await waitForInitialStoreLoad(model)
        model.selectStandaloneThread(thread.id)
        model.prompt = "flush on close"

        model.shutdownForContainerClose()

        XCTAssertEqual(
            try draftStore.load().draftsBySessionKey[reference.stableKey],
            "flush on close")
    }

    @MainActor
    func testAcceptedStaleDraftIsReconciledButIdenticalRetypeSurvives() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-draft-identity-reconcile-\(UUID().uuidString)",
                isDirectory: true)
        let thread = TatwoNativeChatThread(title: "Identity")
        let reference = TatwoNativeChatSessionReference(kind: .thread, id: thread.id)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let draftParent = directory.appendingPathComponent(
            "drafts",
            isDirectory: true)
        let draftStore = TatwoChatComposerDraftStore(
            url: draftParent.appendingPathComponent("chat-composer-drafts-v1.json"))
        try draftStore.save([reference.stableKey: "same text"])
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let model = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: journalStore)
        try await waitForInitialStoreLoad(model)
        model.selectStandaloneThread(thread.id)

        let savedDraftParent = directory.appendingPathComponent("drafts-saved")
        try FileManager.default.moveItem(at: draftParent, to: savedDraftParent)
        try Data("block".utf8).write(to: draftParent)
        model.isRunning = true
        model.submitCurrentChatTurn(applyPromptCollaboration: false)
        XCTAssertEqual(model.prompt, "")
        XCTAssertNotNil(model.composerDraftPersistenceWarning)

        let blockerAside = directory.appendingPathComponent("drafts-blocker")
        try FileManager.default.moveItem(at: draftParent, to: blockerAside)
        try FileManager.default.moveItem(at: savedDraftParent, to: draftParent)

        let relaunched = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: journalStore)
        try await waitForInitialStoreLoad(relaunched)
        relaunched.selectStandaloneThread(thread.id)
        XCTAssertEqual(relaunched.prompt, "")

        relaunched.prompt = "same text"
        XCTAssertTrue(relaunched.flushCurrentComposerDraft())
        let retypedRelaunch = makeModel(
            store: nativeStore,
            composerDraftStore: draftStore,
            transcriptStore: journalStore)
        try await waitForInitialStoreLoad(retypedRelaunch)
        retypedRelaunch.selectStandaloneThread(thread.id)
        XCTAssertEqual(retypedRelaunch.prompt, "same text")
    }

    private func remoteProjection(
        state: ChatRemoteJobPublicState?,
        occurredAt: Date
    ) -> ChatRemoteJobProjection {
        ChatRemoteJobProjection(
            logicalKey: "logical-stable",
            attempt: 1,
            publicState: state,
            terminalOutcome: nil,
            runtimeTruth: .observedThisProcess,
            publicNarrative:
                "借用原因：本機工作需要遠端算力"
                + " → 目標：遠端設備"
                + " → 傳送：已送達"
                + " → 排隊/執行：\(state?.rawValue ?? "尚未開始")"
                + " → 回傳：等待"
                + " → 本機驗證：等待"
                + " → 完成：等待",
            blocker: nil,
            toolDetails: [
                "jobID": "job-stable",
                "jobDigest":
                    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ],
            occurredAt: occurredAt,
            identity: .observation,
            isHidden: false)
    }

    private func remoteRegistryJob(
        jobID: String,
        logicalJobID: String,
        dispatchNonce: String,
        workPath: URL
    ) -> TatwoLoopJobV1 {
        TatwoLoopJobV1(
            jobID: jobID,
            logicalJobID: logicalJobID,
            dispatchNonce: dispatchNonce,
            contractID: "contract-real-registry-terminal",
            goalID: "goal-real-registry-terminal",
            identity: .sub,
            originDeviceID: "origin-real-registry-terminal",
            targetDeviceID: "target-real-registry-terminal",
            payload: .shellSafe(
                TatwoShellSafePayloadV1(command: .true)),
            workPath: workPath.path,
            resourceCaps: TatwoLoopResourceCapsV1(
                maxDurationSec: 2,
                maxOutputBytes: 256),
            stopConditions: TatwoLoopStopConditionsV1(
                cancelFileSignal: true,
                rules: ["cancel-file"]),
            createdAt: Date(timeIntervalSince1970: 8_250))
    }

    private func remoteRecord(
        id: String,
        logicalDispatchID: String,
        remoteJobID: String,
        status: TatwoDispatchStatus,
        remoteStatus: TatwoLoopJobStatusV1,
        updatedAt: Date,
        errorMessage: String? = nil
    ) -> TatwoDispatchRecord {
        TatwoDispatchRecord(
            id: id,
            contractID: "contract-hidden",
            goalID: "goal-hidden",
            bindingID: "binding-hidden",
            sourceSlotID: "slot-hidden",
            identity: .sub,
            modelID: "gpt-5.6-sol",
            subtask: "inspect /private/worktree",
            logicalDispatchID: logicalDispatchID,
            attempt: Int(id.suffix(1)) ?? 1,
            status: status,
            startedAt: updatedAt.addingTimeInterval(-20),
            updatedAt: updatedAt,
            receiptID: "receipt-\(id)",
            outputRef: id.hasSuffix("3") ? "/private/worktree/result.json" : nil,
            errorMessage: errorMessage,
            remoteJobID: remoteJobID,
            originDeviceID: "origin-hidden",
            targetDeviceID: "target-hidden",
            remoteStatus: remoteStatus,
            remoteJobDigest:
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            remoteDispatchNonce: "nonce-\(id)",
            consumedResultDigest:
                remoteStatus == .verified
                ? "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                : nil)
    }

    private func localRecord(
        id: String,
        logicalDispatchID: String,
        status: TatwoDispatchStatus,
        updatedAt: Date,
        errorMessage: String? = nil
    ) -> TatwoDispatchRecord {
        TatwoDispatchRecord(
            id: id,
            contractID: "contract-local",
            goalID: "goal-local",
            bindingID: "binding-local",
            sourceSlotID: "slot-local",
            identity: .sub,
            modelID: "gpt-5.6-sol",
            subtask: "local work",
            logicalDispatchID: logicalDispatchID,
            attempt: 1,
            status: status,
            startedAt: updatedAt.addingTimeInterval(-20),
            updatedAt: updatedAt,
            errorMessage: errorMessage)
    }

    private func context(
        turnID: String = "turn-1",
        runID: String = "run-1"
    ) -> ChatTranscriptJournalContext {
        ChatTranscriptJournalContext(
            threadID: "thread-1",
            turnID: turnID,
            runID: runID,
            source: ChatTranscriptSourceMetadataV1(
                source: "codex",
                model: "gpt-5.5",
                runtime: "codex-exec",
                runID: runID))
    }

    private func activity(
        status: ChatActivityStatusV1,
        id: String = "command-1",
        attempt: Int = 1,
        startedAt: Date = Date(timeIntervalSince1970: 100),
        endedAt: Date? = nil
    ) -> ChatActivityEventV1 {
        ChatActivityEventV1(
            id: id,
            kind: .command,
            label: "Run tests",
            detail: "swift test",
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            turnID: "turn-1",
            attempt: attempt,
            sourceType: "command_execution")
    }

    private func legacyToolEvent(
        eventID: String,
        itemID: String,
        turnID: String,
        parentActivityID: String,
        occurredAt: Date
    ) -> ChatTranscriptEventV1 {
        ChatTranscriptEventV1(
            eventID: eventID,
            threadID: "thread-1",
            turnID: turnID,
            itemID: itemID,
            sequence: 1,
            kind: .tool,
            phase: .completed,
            source: ChatTranscriptSourceMetadataV1(
                source: "codex",
                model: "gpt-5.5",
                runtime: "codex-exec",
                runID: "legacy:\(itemID)",
                attempt: 1),
            sourceEventType: "tatwo/legacy/tool",
            occurredAt: occurredAt,
            title: "Tool",
            summary: "swift test",
            attributes: [
                "activityID": parentActivityID,
                "attempt": "1",
                "sourceType": "tatwo/legacy/tool",
            ])
    }

    private func migrationRows(
        prefix: String,
        count: Int,
        baseTime: TimeInterval,
        assistantModel: String
    ) -> [TatwoNativeChatStoredMessage] {
        (0..<count).map { index in
            let isUser = index.isMultiple(of: 2)
            return TatwoNativeChatStoredMessage(
                id: "\(prefix)-\(index)",
                role: isUser ? "user" : "assistant",
                text: "\(prefix) canonical message \(index)",
                modelID: isUser ? nil : assistantModel,
                eventKind: .message,
                runtimeAdapterID: isUser ? nil : "app-server",
                createdAt: Date(
                    timeIntervalSince1970: baseTime + TimeInterval(index)))
        }
    }

    private func storedMessageDigest(
        _ rows: [TatwoNativeChatStoredMessage]
    ) -> String {
        var payload = Data()
        for row in rows {
            for field in [
                row.id,
                row.role,
                row.text,
                row.status ?? "",
                row.modelID ?? "",
                row.eventKind.rawValue,
                row.runtimeAdapterID ?? "",
                String(row.createdAt.timeIntervalSince1970),
            ] {
                let data = Data(field.utf8)
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) {
                    payload.append(contentsOf: $0)
                }
                payload.append(data)
            }
        }
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct PreparedSanitizerFixture {
        let backupURL: URL
        let backupData: Data
        let preparedURL: URL
        let preparedData: Data
        let authoritativeSanitizedData: Data
    }

    private struct FileTreeEntry: Equatable {
        let relativePath: String
        let isDirectory: Bool
        let data: Data?
    }

    private func makePreparedSanitizerFixture(
        canonicalURL: URL,
        repairRoot: URL,
        index: Int,
        source: ChatTranscriptSourceMetadataV1,
        sanitizedSHA256Override: String? = nil
    ) throws -> PreparedSanitizerFixture {
        let occurredAt = Date(
            timeIntervalSince1970: 490 + TimeInterval(index))
        let attributes = [
            "messageID": "prepared-turn-\(index)",
            "role": "user",
            "eventKind": TatwoNativeChatEventKind.message.rawValue,
            "status": "",
        ]
        let visibleSummary = "Prepared backup \(index)"
        func event(summary: String) -> ChatTranscriptEventV1 {
            ChatTranscriptEventV1(
                eventID: "prepared-event-\(index)",
                threadID: "thread-1",
                turnID: "prepared-turn-\(index)",
                itemID: "prepared-item-\(index)",
                sequence: 1,
                kind: .message,
                phase: .completed,
                source: source,
                sourceEventType: "codex/response_item/message",
                occurredAt: occurredAt,
                title: "User message",
                summary: summary,
                attributes: attributes)
        }

        var backupJournal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            backupJournal.append(event(summary: """
                [Hidden TATWO Chat interface contract]
                private prepared contract \(index)
                [/Hidden TATWO Chat interface contract]

                \(visibleSummary)
                """)).wasAppended)
        let backupData = try backupJournal.encodedSnapshot()

        var sanitizedJournal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            sanitizedJournal.append(
                event(summary: visibleSummary)
            ).wasAppended)
        let authoritativeSanitizedData =
            try sanitizedJournal.encodedSnapshot()
        let originalSHA256 = sha256Hex(backupData)
        let repairDirectory = repairRoot.appendingPathComponent(
            "sanitizer-v1-\(originalSHA256)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: repairDirectory,
            withIntermediateDirectories: true)
        let backupURL = repairDirectory.appendingPathComponent("journal.json")
        try backupData.write(to: backupURL, options: [.atomic])
        let preparedURL = repairDirectory.appendingPathComponent(
            "migration-receipt.prepared.json")
        let preparedData = try JSONSerialization.data(
            withJSONObject: [
                "schema": "TatwoChatTranscriptSanitizerMigrationReceiptV1",
                "status": "prepared",
                "source": canonicalURL.path,
                "backup": backupURL.path,
                "rewrittenEvents": 1,
                "removedEvents": 0,
                "originalSHA256": originalSHA256,
                "sanitizedSHA256": sanitizedSHA256Override
                    ?? sha256Hex(authoritativeSanitizedData),
            ],
            options: [.prettyPrinted, .sortedKeys])
        try preparedData.write(to: preparedURL, options: [.atomic])
        return PreparedSanitizerFixture(
            backupURL: backupURL,
            backupData: backupData,
            preparedURL: preparedURL,
            preparedData: preparedData,
            authoritativeSanitizedData: authoritativeSanitizedData)
    }

    private func fileTreeSnapshot(at root: URL) throws -> [FileTreeEntry] {
        var entries: [FileTreeEntry] = []

        func appendContents(of directory: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: child.path,
                    isDirectory: &isDirectory)
                else { continue }
                let relativePath = prefix.isEmpty
                    ? child.lastPathComponent
                    : "\(prefix)/\(child.lastPathComponent)"
                entries.append(
                    FileTreeEntry(
                        relativePath: relativePath,
                        isDirectory: isDirectory.boolValue,
                        data: isDirectory.boolValue
                            ? nil
                            : try Data(contentsOf: child)))
                if isDirectory.boolValue {
                    try appendContents(
                        of: child,
                        prefix: relativePath)
                }
            }
        }

        try appendContents(of: root, prefix: "")
        return entries
    }

    private func inlineRows(
        _ document: TatwoNativeChatStoreDocument,
        id: UUID
    ) throws -> [TatwoNativeChatStoredMessage] {
        try XCTUnwrap(
            document.threads.first(where: { $0.id == id })?.messages)
    }

    private func projectedRows(
        _ journal: ChatTranscriptJournalV1,
        id: UUID
    ) -> [TatwoNativeChatStoredMessage] {
        ChatTranscriptJournalAdapter.projectedMessages(
            threadID: TatwoNativeChatSessionReference(
                kind: .thread,
                id: id
            ).stableKey,
            from: journal)
            .map(\.storedRecord)
    }

    @MainActor
    private func makeModel(
        directory: URL,
        transcriptStore: ChatTranscriptJournalDiskStore
    ) -> ChatPageModel {
        makeModel(
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptStore: transcriptStore)
    }

    @MainActor
    private func makeModel(
        store: TatwoNativeChatStore,
        composerDraftStore: TatwoChatComposerDraftStore? = nil,
        transcriptStore: ChatTranscriptJournalDiskStore,
        runnerAuthorityDiscoverer:
            any ChatRunnerAuthorityDiscovering =
                ChatUnknownRunnerAuthorityDiscoverer()
    ) -> ChatPageModel {
        ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatTranscriptJournalIntegrationTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            composerDraftStore: composerDraftStore,
            transcriptJournalStore: transcriptStore,
            runnerAuthorityDiscoverer: runnerAuthorityDiscoverer)
    }

    @MainActor
    private func waitForInitialStoreLoad(
        _ model: ChatPageModel
    ) async throws {
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 300,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for asynchronous remote-target state")
    }

    private func writeGoalRun(
        _ goal: TatwoStoredGoalRun,
        to store: TatwoGoalRunStore
    ) throws {
        let directory = store.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(goal).write(
            to: directory.appendingPathComponent("\(goal.contractID).json"),
            options: .atomic)
    }
}

private final class RecordingRemoteTurnDispatcher:
    ChatRemoteTurnDispatching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRequests: [ChatRemoteTurnDispatchRequest] = []
    private let outcome: ChatRemoteTurnDispatchOutcome

    var requests: [ChatRemoteTurnDispatchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    init(outcome: ChatRemoteTurnDispatchOutcome) {
        self.outcome = outcome
    }

    func dispatch(
        _ request: ChatRemoteTurnDispatchRequest
    ) -> ChatRemoteTurnDispatchOutcome {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        return outcome
    }
}

private struct StaticChatRunnerAuthorityDiscoverer:
    ChatRunnerAuthorityDiscovering
{
    let snapshot: ChatRunnerAuthoritySnapshot

    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        snapshot
    }
}
