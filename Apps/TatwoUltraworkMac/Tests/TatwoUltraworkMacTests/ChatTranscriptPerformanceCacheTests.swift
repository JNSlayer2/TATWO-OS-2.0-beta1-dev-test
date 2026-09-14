import AppKit
import Foundation
import os
import SwiftUI
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

private final class ChatSnapshotIdentityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [ObjectIdentifier] = []

    func append(_ identity: ObjectIdentifier) {
        lock.lock()
        identities.append(identity)
        lock.unlock()
    }

    var uniqueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(identities).count
    }
}

private final class ChatPreparedSnapshotBox: @unchecked Sendable {
    let snapshots: [ChatMessageDerivedSnapshot]

    @MainActor
    init(source: String, count: Int) {
        snapshots = (0..<count).map { index in
            let display = "\(source)\(index)"
            return ChatMessageDerivedSnapshot(
                transcriptDisplayText: display,
                transcriptTextView: Text(display),
                inlineAttachments: [],
                isTranscriptNoise: false,
                isInertAssistantStreamingPlaceholder: false,
                isInertAssistantPlaceholder: false)
        }
    }
}

@MainActor
private final class ChatInjectedStreamingLayoutMeasurer:
    ChatStreamingTextLayoutMeasuring
{
    private var measuredWidth: CGFloat?
    private(set) var callCount = 0

    func measure(
        width: CGFloat,
        container: NSTextContainer,
        layoutManager: NSLayoutManager
    ) -> ChatStreamingTextLayoutMeasurement {
        callCount += 1
        let didResize = measuredWidth != width
        measuredWidth = width
        if didResize {
            container.size = NSSize(
                width: width,
                height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        return ChatStreamingTextLayoutMeasurement(
            size: CGSize(
                width: width,
                height: ceil(layoutManager.usedRect(for: container).height)),
            didResizeTextContainer: didResize,
            laidOutGlyphRange: layoutManager.glyphRange(for: container))
    }
}

@MainActor
final class ChatTranscriptPerformanceCacheTests: XCTestCase {
    func testTranscriptProjectionReusesSameSessionAndSourceRevisions() {
        let cache = ChatTranscriptProjectionCache()
        let messages = [
            ChatMessage(
                id: "assistant-1",
                role: .assistant,
                text: "stable answer"),
        ]
        let key = ChatTranscriptProjectionCacheKey(
            selectedSessionStableKey: "thread:one",
            liveMessagesRevision: 7,
            journalRevision: 11,
            documentRevision: 3,
            journalPersistenceAllowed: true,
            legacyMigrationCompleted: true)
        var builds = 0

        for _ in 0..<8 {
            let projection = cache.resolve(key: key) {
                builds += 1
                return messages.filter {
                    !$0.isTranscriptNoise
                        && !$0.isInertAssistantPlaceholder
                }
            }
            XCTAssertEqual(projection, messages)
        }

        XCTAssertEqual(builds, 1)
        XCTAssertEqual(
            cache.metrics,
            ChatTranscriptProjectionCacheMetrics(
                hits: 7,
                misses: 1,
                recomputations: 1,
                fullProjectionResidentScans: 1,
                cachedSessionCount: 1,
                residentBytes:
                    MemoryLayout<ChatMessage>.stride
                    + "assistant-1".utf8.count
                    + "stable answer".utf8.count))
    }

    func testTranscriptProjectionInvalidatesForContentJournalAndSession() {
        let cache = ChatTranscriptProjectionCache()
        var builds = 0
        func resolve(_ key: ChatTranscriptProjectionCacheKey) {
            _ = cache.resolve(key: key) {
                builds += 1
                return [
                    ChatMessage(
                        id: "assistant-\(builds)",
                        role: .assistant,
                        text: "answer \(builds)"),
                ]
            }
        }
        let base = ChatTranscriptProjectionCacheKey(
            selectedSessionStableKey: "thread:one",
            liveMessagesRevision: 1,
            journalRevision: 1,
            documentRevision: 1,
            journalPersistenceAllowed: true,
            legacyMigrationCompleted: true)

        resolve(base)
        resolve(base)
        resolve(ChatTranscriptProjectionCacheKey(
            selectedSessionStableKey: "thread:one",
            liveMessagesRevision: 2,
            journalRevision: 1,
            documentRevision: 1,
            journalPersistenceAllowed: true,
            legacyMigrationCompleted: true))
        resolve(ChatTranscriptProjectionCacheKey(
            selectedSessionStableKey: "thread:one",
            liveMessagesRevision: 2,
            journalRevision: 2,
            documentRevision: 1,
            journalPersistenceAllowed: true,
            legacyMigrationCompleted: true))
        resolve(ChatTranscriptProjectionCacheKey(
            selectedSessionStableKey: "thread:two",
            liveMessagesRevision: 2,
            journalRevision: 2,
            documentRevision: 1,
            journalPersistenceAllowed: true,
            legacyMigrationCompleted: true))

        XCTAssertEqual(builds, 4)
        XCTAssertEqual(cache.metrics.hits, 1)
        XCTAssertEqual(cache.metrics.recomputations, 4)
    }

    func testProjectionRevisionIsStableAcrossEquivalentReconstruction() {
        let cache = ChatTranscriptProjectionCache()
        let createdAt = Date(timeIntervalSinceReferenceDate: 42_000)
        let first = [
            ChatMessage(
                id: "user-stable",
                role: .user,
                text: "question",
                createdAt: createdAt),
            ChatMessage(
                id: "assistant-stable",
                role: .assistant,
                text: "answer",
                status: "done",
                modelID: "gpt-5.6-sol",
                eventKind: .message,
                runtimeAdapterID: "codex-exec",
                turnID: "turn-stable",
                createdAt: createdAt.addingTimeInterval(1)),
        ]
        let rebuilt = first.map {
            ChatMessage(
                id: $0.id,
                role: $0.role,
                text: $0.text,
                status: $0.status,
                modelID: $0.modelID,
                eventKind: $0.eventKind,
                runtimeAdapterID: $0.runtimeAdapterID,
                runtimeFallbackReason: $0.runtimeFallbackReason,
                turnID: $0.turnID,
                planQuestions: $0.planQuestions,
                createdAt: $0.createdAt)
        }

        func revision(
            messages: [ChatMessage],
            sourceRevision: UInt64
        ) -> ChatTranscriptSemanticRevision? {
            cache.resolve(
                key: ChatTranscriptProjectionCacheKey(
                    selectedSessionStableKey: "thread:stable-rebuild",
                    liveMessagesRevision: sourceRevision,
                    journalRevision: 1,
                    documentRevision: 1,
                    journalPersistenceAllowed: true,
                    legacyMigrationCompleted: true)
            ) {
                messages
            }.last?.transcriptProjectionRevision
        }

        XCTAssertEqual(
            revision(messages: first, sourceRevision: 1),
            revision(messages: rebuilt, sourceRevision: 2))
    }

    func testProjectionRevisionInvalidatesEveryMiddleRowDisplaySemantic() {
        let cache = ChatTranscriptProjectionCache()
        let createdAt = Date(timeIntervalSinceReferenceDate: 84_000)
        let question = PlanQuestionV1(
            id: "question-1",
            question: "Choose?",
            options: [
                .init(label: "A", detail: "first"),
                .init(label: "B", detail: "second"),
            ])
        let middle = ChatMessage(
            id: "middle",
            role: .assistant,
            text: "answer",
            status: "done",
            modelID: "gpt-5.6-sol",
            eventKind: .message,
            runtimeAdapterID: "codex-exec",
            runtimeFallbackReason: nil,
            turnID: "turn-1",
            planQuestions: [question],
            createdAt: createdAt)
        let leading = ChatMessage(
            id: "leading",
            role: .user,
            text: "question",
            createdAt: createdAt.addingTimeInterval(-1))
        let trailing = ChatMessage(
            id: "trailing",
            role: .system,
            text: "receipt",
            createdAt: createdAt.addingTimeInterval(1))

        func reconstructed(
            id: String = middle.id,
            role: ChatMessageRole = middle.role,
            text: String = middle.text,
            status: String? = middle.status,
            modelID: String? = middle.modelID,
            eventKind: TatwoNativeChatEventKind = middle.eventKind,
            runtimeAdapterID: String? = middle.runtimeAdapterID,
            runtimeFallbackReason: TatwoChatRuntimeFallbackReason? =
                middle.runtimeFallbackReason,
            turnID: String? = middle.turnID,
            planQuestions: [PlanQuestionV1] = middle.planQuestions,
            createdAt: Date = middle.createdAt
        ) -> ChatMessage {
            ChatMessage(
                id: id,
                role: role,
                text: text,
                status: status,
                modelID: modelID,
                eventKind: eventKind,
                runtimeAdapterID: runtimeAdapterID,
                runtimeFallbackReason: runtimeFallbackReason,
                turnID: turnID,
                planQuestions: planQuestions,
                createdAt: createdAt)
        }

        var sourceRevision: UInt64 = 0
        func revision(
            middle candidate: ChatMessage
        ) -> ChatTranscriptSemanticRevision {
            sourceRevision &+= 1
            return cache.resolve(
                key: ChatTranscriptProjectionCacheKey(
                    selectedSessionStableKey: "thread:middle-semantics",
                    liveMessagesRevision: sourceRevision,
                    journalRevision: 1,
                    documentRevision: 1,
                    journalPersistenceAllowed: true,
                    legacyMigrationCompleted: true)
            ) {
                [leading, candidate, trailing]
            }.last!.transcriptProjectionRevision
        }

        let baseline = revision(middle: middle)
        let changedQuestion = PlanQuestionV1(
            id: question.id,
            question: "Choose a different path?",
            options: question.options)
        let variants = [
            reconstructed(id: "middle-other"),
            reconstructed(role: .user),
            reconstructed(text: "answer changed"),
            reconstructed(status: "streaming"),
            reconstructed(modelID: "sonnet-5"),
            reconstructed(eventKind: .thinking),
            reconstructed(runtimeAdapterID: "claude-cli-native"),
            reconstructed(
                runtimeFallbackReason: .codexExecutableUnavailable),
            reconstructed(turnID: "turn-2"),
            reconstructed(planQuestions: [changedQuestion]),
            reconstructed(createdAt: createdAt.addingTimeInterval(0.5)),
        ]

        XCTAssertEqual(revision(middle: reconstructed()), baseline)
        for variant in variants {
            XCTAssertNotEqual(revision(middle: variant), baseline)
        }
    }

    func testDisplayFingerprintReadsOnlyTailAndInvalidatesSourceMutationsOnce() {
        let cache = ChatTranscriptProjectionCache()
        var messages = (0..<10_000).map { index in
            ChatMessage(
                id: "message-\(index)",
                role: index == 4_000 ? .assistant : .user,
                text: "stable-\(index)",
                status: index == 5_000 ? "open" : nil)
        }
        var sourceRevision: UInt64 = 1
        var journalRevision: UInt64 = 1
        var sessionKey = "thread:long"
        var builds = 0

        func resolve() -> [ChatMessage] {
            cache.resolve(
                key: ChatTranscriptProjectionCacheKey(
                    selectedSessionStableKey: sessionKey,
                    liveMessagesRevision: sourceRevision,
                    journalRevision: journalRevision,
                    documentRevision: 1,
                    journalPersistenceAllowed: true,
                    legacyMigrationCompleted: true)
            ) {
                builds += 1
                return messages
            }
        }

        let initialProjection = resolve()
        let initial = ChatTranscriptDisplayFingerprint(initialProjection)
        for _ in 0..<64 {
            let repeated =
                ChatTranscriptDisplayFingerprint(resolve())
            XCTAssertEqual(repeated, initial)
            XCTAssertEqual(repeated.inspectedRowCount, 1)
            XCTAssertEqual(
                repeated.latestAssistantMessageID,
                "message-4000")
            XCTAssertFalse(repeated.latestAssistantHasPlanQuestions)
        }
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(cache.metrics.recomputations, 1)

        let originalTextUTF8Count = messages[4_000].text.utf8.count
        messages[4_000].text = "mutate-4000"
        XCTAssertEqual(
            messages[4_000].text.utf8.count,
            originalTextUTF8Count)
        sourceRevision &+= 1
        let contentMutation =
            ChatTranscriptDisplayFingerprint(resolve())
        XCTAssertNotEqual(contentMutation, initial)
        XCTAssertEqual(
            ChatTranscriptDisplayFingerprint(resolve()),
            contentMutation)
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(cache.metrics.recomputations, 2)

        let originalStatusUTF8Count = messages[5_000].status?.utf8.count
        messages[5_000].status = "done"
        XCTAssertEqual(
            messages[5_000].status?.utf8.count,
            originalStatusUTF8Count)
        sourceRevision &+= 1
        let statusMutation =
            ChatTranscriptDisplayFingerprint(resolve())
        XCTAssertNotEqual(statusMutation, contentMutation)
        XCTAssertEqual(
            ChatTranscriptDisplayFingerprint(resolve()),
            statusMutation)
        XCTAssertEqual(builds, 3)
        XCTAssertEqual(cache.metrics.recomputations, 3)
        XCTAssertEqual(statusMutation.inspectedRowCount, 1)

        messages[4_000].planQuestions.append(
            PlanQuestionV1(
                id: "q1",
                question: "Which path?",
                options: [
                    .init(label: "A", detail: "one"),
                    .init(label: "B", detail: "two"),
                ]))
        sourceRevision &+= 1
        let planQuestionMutation =
            ChatTranscriptDisplayFingerprint(resolve())
        XCTAssertNotEqual(planQuestionMutation, statusMutation)
        XCTAssertEqual(
            planQuestionMutation.latestAssistantMessageID,
            "message-4000")
        XCTAssertTrue(
            planQuestionMutation.latestAssistantHasPlanQuestions)
        XCTAssertEqual(
            ChatTranscriptDisplayFingerprint(resolve()),
            planQuestionMutation)
        XCTAssertEqual(builds, 4)

        let formerAssistant = messages[4_000]
        messages[4_000] = ChatMessage(
            id: formerAssistant.id,
            role: .user,
            text: formerAssistant.text,
            status: formerAssistant.status,
            modelID: formerAssistant.modelID,
            eventKind: formerAssistant.eventKind,
            runtimeAdapterID: formerAssistant.runtimeAdapterID,
            runtimeFallbackReason:
                formerAssistant.runtimeFallbackReason,
            turnID: formerAssistant.turnID,
            planQuestions: formerAssistant.planQuestions,
            createdAt: formerAssistant.createdAt)
        sourceRevision &+= 1
        let roleMutation =
            ChatTranscriptDisplayFingerprint(resolve())
        XCTAssertNotEqual(roleMutation, planQuestionMutation)
        XCTAssertNil(roleMutation.latestAssistantMessageID)
        XCTAssertFalse(roleMutation.latestAssistantHasPlanQuestions)
        XCTAssertEqual(
            ChatTranscriptDisplayFingerprint(resolve()),
            roleMutation)
        XCTAssertEqual(builds, 5)

        journalRevision &+= 1
        let journalMutation =
            ChatTranscriptDisplayFingerprint(resolve())
        XCTAssertEqual(journalMutation, roleMutation)
        XCTAssertEqual(
            ChatTranscriptDisplayFingerprint(resolve()),
            journalMutation)
        XCTAssertEqual(builds, 6)

        sessionKey = "thread:other"
        let sessionMutation =
            ChatTranscriptDisplayFingerprint(resolve())
        XCTAssertEqual(sessionMutation, journalMutation)
        XCTAssertEqual(
            ChatTranscriptDisplayFingerprint(resolve()),
            sessionMutation)
        XCTAssertEqual(builds, 7)
        XCTAssertEqual(sessionMutation.inspectedRowCount, 1)
    }

    func testLiveProjectionReevaluatesOnlyStreamingSuffix() {
        let cache = ChatTranscriptProjectionCache()
        var messages = [
            ChatMessage(id: "user-1", role: .user, text: "question"),
            ChatMessage(id: "assistant-1", role: .assistant, text: "answer"),
            ChatMessage(
                id: "assistant-2",
                role: .assistant,
                text: "",
                status: "streaming"),
        ]

        func resolve() -> [ChatMessage] {
            cache.resolveLive(sessionKey: "thread:one", messages: messages) {
                !$0.isTranscriptNoise && !$0.isInertAssistantPlaceholder
            }
        }

        XCTAssertEqual(resolve().map(\.id), ["user-1", "assistant-1"])
        XCTAssertEqual(cache.metrics.liveIdentityEvaluations, 3)
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 3)

        messages[2].text = "n"
        XCTAssertEqual(
            resolve().map(\.id),
            ["user-1", "assistant-1", "assistant-2"])
        XCTAssertEqual(cache.metrics.liveIdentityEvaluations, 4)
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 4)
        XCTAssertEqual(cache.metrics.incrementalUpdates, 1)

        messages[2].appendTranscriptText("ext token")
        XCTAssertEqual(resolve().last?.text, "next token")
        XCTAssertEqual(cache.metrics.liveIdentityEvaluations, 5)
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 5)
        XCTAssertEqual(cache.metrics.incrementalUpdates, 2)

        _ = resolve()
        XCTAssertEqual(cache.metrics.liveIdentityEvaluations, 5)
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 5)

        messages[2].status = "done"
        XCTAssertEqual(resolve().last?.text, "next token")
        XCTAssertEqual(cache.metrics.liveIdentityEvaluations, 6)
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 6)
        XCTAssertEqual(cache.metrics.incrementalUpdates, 3)
    }

    func testLiveProjectionIncludeRevisionAndResidentAccountingStaySuffixBounded() {
        let cache = ChatTranscriptProjectionCache()
        var messages = (0..<10_000).map { index in
            ChatMessage(
                id: "message-\(index)",
                role: index.isMultiple(of: 2) ? .assistant : .user,
                text: "stable-\(index)")
        }

        func resolve(includeRevision: UInt64) -> [ChatMessage] {
            cache.resolveLive(
                sessionKey: "thread:resident-suffix",
                messages: messages,
                includeRevision: includeRevision
            ) {
                !$0.isTranscriptNoise && !$0.isInertAssistantPlaceholder
            }
        }

        XCTAssertEqual(resolve(includeRevision: 1).count, messages.count)
        XCTAssertEqual(cache.metrics.liveResidentByteEvaluations, 10_000)
        XCTAssertEqual(cache.metrics.fullProjectionResidentScans, 0)

        messages[9_999].appendTranscriptText("-token")
        let appended = resolve(includeRevision: 1)
        XCTAssertEqual(appended.last?.text, "stable-9999-token")
        XCTAssertEqual(cache.metrics.liveResidentByteEvaluations, 10_001)
        XCTAssertEqual(cache.metrics.liveMetadataAssignments, 2)
        XCTAssertEqual(cache.metrics.fullProjectionResidentScans, 0)

        _ = resolve(includeRevision: 2)
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 20_001)
        XCTAssertEqual(cache.metrics.liveResidentByteEvaluations, 20_001)
        XCTAssertEqual(cache.metrics.fullProjectionResidentScans, 0)
    }

    func testTranscriptProjectionPreservesBoundedSessionsAcrossSwitches() {
        let cache = ChatTranscriptProjectionCache(maximumSessionCount: 2)
        var builds = 0

        func resolve(session: String, revision: UInt64) -> [ChatMessage] {
            cache.resolve(
                key: ChatTranscriptProjectionCacheKey(
                    selectedSessionStableKey: session,
                    liveMessagesRevision: revision,
                    journalRevision: 1,
                    documentRevision: 1,
                    journalPersistenceAllowed: true,
                    legacyMigrationCompleted: true)
            ) {
                builds += 1
                return [
                    ChatMessage(
                        id: "\(session)-assistant",
                        role: .assistant,
                        text: "\(session)-answer"),
                ]
            }
        }

        XCTAssertEqual(resolve(session: "thread:a", revision: 1).count, 1)
        XCTAssertEqual(resolve(session: "thread:b", revision: 1).count, 1)
        XCTAssertEqual(resolve(session: "thread:a", revision: 1).count, 1)
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(cache.metrics.hits, 1)
        XCTAssertEqual(cache.metrics.cachedSessionCount, 2)

        _ = resolve(session: "thread:c", revision: 1)
        XCTAssertEqual(cache.metrics.cachedSessionCount, 2)
        XCTAssertEqual(cache.metrics.evictions, 1)

        _ = resolve(session: "thread:b", revision: 1)
        XCTAssertEqual(builds, 4)
        XCTAssertEqual(cache.metrics.evictions, 2)
    }

    func testTranscriptProjectionEvictsHistoricalSessionsByResidentBytes() {
        let cache = ChatTranscriptProjectionCache(
            maximumSessionCount: 8,
            maximumResidentBytes: 1_200)
        var builds = 0

        func resolve(session: String, fill: Character) {
            _ = cache.resolve(
                key: ChatTranscriptProjectionCacheKey(
                    selectedSessionStableKey: session,
                    liveMessagesRevision: 1,
                    journalRevision: 1,
                    documentRevision: 1,
                    journalPersistenceAllowed: true,
                    legacyMigrationCompleted: true)
            ) {
                builds += 1
                return [
                    ChatMessage(
                        id: "\(session)-assistant",
                        role: .assistant,
                        text: String(repeating: fill, count: 800)),
                ]
            }
        }

        resolve(session: "thread:a", fill: "a")
        resolve(session: "thread:b", fill: "b")

        XCTAssertEqual(cache.metrics.cachedSessionCount, 1)
        XCTAssertGreaterThan(cache.metrics.evictions, 0)

        resolve(session: "thread:b", fill: "b")
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(cache.metrics.hits, 1)

        resolve(session: "thread:a", fill: "a")
        XCTAssertEqual(builds, 3)
    }

    func testOversizedActiveProjectionRemainsCachedInsteadOfThrashing() {
        let cache = ChatTranscriptProjectionCache(
            maximumSessionCount: 8,
            maximumResidentBytes: 128)
        let key = ChatTranscriptProjectionCacheKey(
            selectedSessionStableKey: "thread:oversized",
            liveMessagesRevision: 1,
            journalRevision: 1,
            documentRevision: 1,
            journalPersistenceAllowed: true,
            legacyMigrationCompleted: true)
        var builds = 0

        for _ in 0..<4 {
            _ = cache.resolve(key: key) {
                builds += 1
                return [
                    ChatMessage(
                        id: "large",
                        role: .assistant,
                        text: String(repeating: "x", count: 4_096)),
                ]
            }
        }

        XCTAssertEqual(builds, 1)
        XCTAssertEqual(cache.metrics.hits, 3)
        XCTAssertEqual(cache.metrics.cachedSessionCount, 1)
        XCTAssertGreaterThan(cache.metrics.residentBytes, 128)
    }

    func testLiveProjectionPreservesParsedRowsAcrossSessionSwitches() {
        let cache = ChatTranscriptProjectionCache(maximumSessionCount: 2)
        let first = [
            ChatMessage(id: "a-user", role: .user, text: "question a"),
            ChatMessage(id: "a-assistant", role: .assistant, text: "answer a"),
        ]
        let second = [
            ChatMessage(id: "b-user", role: .user, text: "question b"),
            ChatMessage(id: "b-assistant", role: .assistant, text: "answer b"),
        ]

        func resolve(
            session: String,
            messages: [ChatMessage]
        ) -> [ChatMessage] {
            cache.resolveLive(sessionKey: session, messages: messages) {
                !$0.isTranscriptNoise && !$0.isInertAssistantPlaceholder
            }
        }

        XCTAssertEqual(
            resolve(session: "thread:a", messages: first).map(\.id),
            ["a-user", "a-assistant"])
        XCTAssertEqual(
            resolve(session: "thread:b", messages: second).map(\.id),
            ["b-user", "b-assistant"])
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 4)

        XCTAssertEqual(
            resolve(session: "thread:a", messages: first).map(\.id),
            ["a-user", "a-assistant"])
        XCTAssertEqual(cache.metrics.liveMessageEvaluations, 4)
        XCTAssertEqual(cache.metrics.cachedSessionCount, 2)
    }

    func testMessageDerivedValuesReuseStableSnapshotAndInvalidateOnMutation() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        var message = ChatMessage(
            id: "message-1",
            role: .assistant,
            text: """
                Result
                <file path="/tmp/report.txt" name="report.txt">
                """,
            status: nil)

        let first = message.derivedSnapshot(using: cache)
        let second = message.derivedSnapshot(using: cache)
        let reconstructed = ChatMessage(
            id: "message-1",
            role: .assistant,
            text: """
                Result
                <file path="/tmp/report.txt" name="report.txt">
                """,
            status: nil)
        let third = reconstructed.derivedSnapshot(using: cache)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
        XCTAssertTrue(first === second)
        XCTAssertTrue(second === third)
        XCTAssertEqual(first.transcriptDisplayText, "Result")
        XCTAssertEqual(first.inlineAttachments.map(\.path), ["/tmp/report.txt"])
        XCTAssertEqual(cache.metricsSnapshot().computations, 1)
        XCTAssertEqual(cache.metricsSnapshot().hits, 2)

        message.text = "Updated result"
        let changed = message.derivedSnapshot(using: cache)

        XCTAssertEqual(changed.transcriptDisplayText, "Updated result")
        XCTAssertTrue(changed.inlineAttachments.isEmpty)
        XCTAssertFalse(first === changed)
        XCTAssertEqual(cache.metricsSnapshot().computations, 2)
        XCTAssertEqual(cache.metricsSnapshot().misses, 2)
    }

    func testDerivedCacheTreatsFingerprintCollisionAsCacheMiss() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        let collision = ChatStableContentFingerprint("same-fingerprint")
        let firstKey = ChatMessageDerivedCacheKey(
            messageID: "message-collision",
            role: ChatMessageRole.assistant.storageValue,
            text: "first source",
            status: nil,
            textFingerprint: collision,
            statusFingerprint: .empty,
            statusWasNil: true,
            eventKind: TatwoNativeChatEventKind.message.rawValue,
            hasPlanQuestions: false)
        let secondKey = ChatMessageDerivedCacheKey(
            messageID: "message-collision",
            role: ChatMessageRole.assistant.storageValue,
            text: "other source",
            status: nil,
            textFingerprint: collision,
            statusFingerprint: .empty,
            statusWasNil: true,
            eventKind: TatwoNativeChatEventKind.message.rawValue,
            hasPlanQuestions: false)
        var computations = 0

        func resolve(
            key: ChatMessageDerivedCacheKey,
            displayText: String
        ) -> ChatMessageDerivedSnapshot {
            cache.resolve(key: key) {
                computations += 1
                return ChatMessageDerivedSnapshot(
                    transcriptDisplayText: displayText,
                    transcriptTextView: Text(displayText),
                    inlineAttachments: [],
                    isTranscriptNoise: false,
                    isInertAssistantStreamingPlaceholder: false,
                    isInertAssistantPlaceholder: false)
            }
        }

        XCTAssertEqual(
            resolve(key: firstKey, displayText: "first").transcriptDisplayText,
            "first")
        XCTAssertEqual(
            resolve(key: secondKey, displayText: "other").transcriptDisplayText,
            "other")
        XCTAssertEqual(computations, 2)
        XCTAssertEqual(cache.metricsSnapshot().misses, 2)
    }

    func testDerivedCacheParserVersionInvalidatesSameSource() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        let source = "same source"
        let fingerprint = ChatStableContentFingerprint(source)
        var computations = 0

        func resolve(parserVersion: Int) -> ChatMessageDerivedSnapshot {
            cache.resolve(
                key: ChatMessageDerivedCacheKey(
                    messageID: "message-parser-version",
                    role: ChatMessageRole.assistant.storageValue,
                    text: source,
                    status: nil,
                    textFingerprint: fingerprint,
                    statusFingerprint: .empty,
                    statusWasNil: true,
                    eventKind:
                        TatwoNativeChatEventKind.message.rawValue,
                    hasPlanQuestions: false,
                    parserVersion: parserVersion)
            ) {
                computations += 1
                let display = "parser-\(parserVersion)"
                return ChatMessageDerivedSnapshot(
                    transcriptDisplayText: display,
                    transcriptTextView: Text(display),
                    inlineAttachments: [],
                    isTranscriptNoise: false,
                    isInertAssistantStreamingPlaceholder: false,
                    isInertAssistantPlaceholder: false)
            }
        }

        XCTAssertEqual(
            resolve(parserVersion: 1).transcriptDisplayText,
            "parser-1")
        XCTAssertEqual(
            resolve(parserVersion: 2).transcriptDisplayText,
            "parser-2")
        XCTAssertEqual(
            resolve(parserVersion: 1).transcriptDisplayText,
            "parser-1")
        XCTAssertEqual(computations, 3)
        XCTAssertEqual(cache.metricsSnapshot().hits, 0)
        XCTAssertEqual(cache.metricsSnapshot().misses, 3)
        XCTAssertEqual(cache.metricsSnapshot().entryCount, 1)
    }

    func testLiveMessageIdentityIsDeterministicFixedSizeAndSourceFree() {
        let fixedDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let source = String(repeating: "large streaming source ", count: 4_096)
        let first = ChatTranscriptProjectionCache.LiveMessageIdentity(
            ChatMessage(
                id: "message-semantic",
                role: .assistant,
                text: source,
                status: "streaming",
                createdAt: fixedDate))
        let reconstructed = ChatTranscriptProjectionCache.LiveMessageIdentity(
            ChatMessage(
                id: "message-semantic",
                role: .assistant,
                text: source,
                status: "streaming",
                createdAt: fixedDate))
        let changed = ChatTranscriptProjectionCache.LiveMessageIdentity(
            ChatMessage(
                id: "message-semantic",
                role: .assistant,
                text: source + "delta",
                status: "streaming",
                createdAt: fixedDate))

        XCTAssertEqual(first, reconstructed)
        XCTAssertNotEqual(first, changed)
        XCTAssertEqual(
            MemoryLayout<
                ChatTranscriptProjectionCache.LiveMessageIdentity
            >.stride,
            MemoryLayout<ChatMessageSemanticIdentity>.stride)
        XCTAssertLessThanOrEqual(
            MemoryLayout<
                ChatTranscriptProjectionCache.LiveMessageIdentity
            >.stride,
            32)
        XCTAssertFalse(
            Mirror(reflecting: first).children.contains {
                $0.value is String || $0.value is [PlanQuestionV1]
            })
    }

    func testMessageDerivedCacheInvalidatesStatusAndEventExactlyOnce() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        var message = ChatMessage(
            id: "message-status-event",
            role: .assistant,
            text: "",
            status: "streaming")

        let streaming = message.derivedSnapshot(using: cache)
        XCTAssertTrue(streaming.isInertAssistantStreamingPlaceholder)
        XCTAssertTrue(
            streaming === message.derivedSnapshot(using: cache))

        message.status = "completed"
        let completed = message.derivedSnapshot(using: cache)
        XCTAssertFalse(streaming === completed)
        XCTAssertTrue(
            completed === message.derivedSnapshot(using: cache))

        message.eventKind = .thinking
        let thinking = message.derivedSnapshot(using: cache)
        XCTAssertFalse(completed === thinking)
        XCTAssertTrue(
            thinking === message.derivedSnapshot(using: cache))

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.computations, 3)
        XCTAssertEqual(metrics.misses, 3)
        XCTAssertEqual(metrics.hits, 3)
    }

    func testMessageDerivedCacheIsCountAndByteBounded() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 2,
            maximumResidentBytes: 2_048)

        for index in 0..<6 {
            let message = ChatMessage(
                id: "message-\(index)",
                role: .assistant,
                text: String(repeating: "\(index)", count: 120))
            _ = message.derivedSnapshot(using: cache)
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertLessThanOrEqual(metrics.entryCount, 2)
        XCTAssertLessThanOrEqual(metrics.residentBytes, 2_048)
        XCTAssertGreaterThan(metrics.evictions, 0)
    }

    func testMessageDerivedCacheCountsExactSourceKeyBytesForOversizeBypass() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024)
        let largeFilteredSource =
            String(repeating: "<file path=\"/tmp/a\" name=\"a\">\n", count: 256)
        let key = ChatMessageDerivedCacheKey(
            messageID: "large-filtered-source",
            role: ChatMessageRole.assistant.storageValue,
            text: largeFilteredSource,
            status: nil,
            textFingerprint:
                ChatStableContentFingerprint(largeFilteredSource),
            statusFingerprint: .empty,
            statusWasNil: true,
            eventKind: TatwoNativeChatEventKind.message.rawValue,
            hasPlanQuestions: false)

        _ = cache.resolve(key: key) {
            ChatMessageDerivedSnapshot(
                transcriptDisplayText: "",
                transcriptTextView: Text(""),
                inlineAttachments: [],
                isTranscriptNoise: false,
                isInertAssistantStreamingPlaceholder: false,
                isInertAssistantPlaceholder: true)
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.oversizedBypasses, 1)
        XCTAssertEqual(metrics.entryCount, 0)
        XCTAssertEqual(metrics.residentBytes, 0)
    }

    func testMessageDerivedCacheConcurrentRacesConvergeOnOneSnapshot() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        let source = String(repeating: "concurrent source ", count: 64)
        let key = ChatMessageDerivedCacheKey(
            messageID: "concurrent-derived",
            role: ChatMessageRole.assistant.storageValue,
            text: source,
            status: nil,
            textFingerprint: ChatStableContentFingerprint(source),
            statusFingerprint: .empty,
            statusWasNil: true,
            eventKind: TatwoNativeChatEventKind.message.rawValue,
            hasPlanQuestions: false)
        let identities = ChatSnapshotIdentityCollector()
        let prepared = ChatPreparedSnapshotBox(source: source, count: 64)

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let snapshot = cache.resolve(key: key) {
                prepared.snapshots[index]
            }
            identities.append(ObjectIdentifier(snapshot))
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(identities.uniqueCount, 1)
        XCTAssertEqual(metrics.entryCount, 1)
        XCTAssertEqual(metrics.hits + metrics.misses, 64)
        XCTAssertGreaterThanOrEqual(metrics.computations, 1)
        XCTAssertLessThanOrEqual(metrics.computations, 64)
        XCTAssertLessThanOrEqual(
            metrics.residentBytes,
            cache.maximumResidentBytes)
    }

    func testMessageDerivedCacheEvictsLeastRecentlyUsedInConstantTimeOrder() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 2,
            maximumResidentBytes: 1_024 * 1_024)
        let first = ChatMessage(id: "first", role: .assistant, text: "first")
        let second = ChatMessage(id: "second", role: .assistant, text: "second")
        let third = ChatMessage(id: "third", role: .assistant, text: "third")

        _ = first.derivedSnapshot(using: cache)
        _ = second.derivedSnapshot(using: cache)
        _ = first.derivedSnapshot(using: cache)
        _ = third.derivedSnapshot(using: cache)
        _ = first.derivedSnapshot(using: cache)
        _ = second.derivedSnapshot(using: cache)

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.computations, 4)
        XCTAssertEqual(metrics.hits, 2)
        XCTAssertEqual(metrics.evictions, 2)
        XCTAssertEqual(metrics.entryCount, 2)
    }

    func testMessageDerivedCacheInvalidatesSameLengthMutation() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        var message = ChatMessage(
            id: "message-same-length",
            role: .assistant,
            text: "answer-a")

        XCTAssertEqual(
            message.derivedSnapshot(using: cache).transcriptDisplayText,
            "answer-a")
        message.text = "answer-b"
        XCTAssertEqual(
            message.derivedSnapshot(using: cache).transcriptDisplayText,
            "answer-b")

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.computations, 2)
        XCTAssertEqual(metrics.misses, 2)
    }

    func testMessageIncrementalStreamingAppendKeepsExactFingerprint() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        var message = ChatMessage(
            id: "message-streaming-append",
            role: .assistant,
            text: "prefix",
            status: "streaming")

        let initial = message.derivedSnapshot(using: cache)
        message.appendTranscriptText("-suffix")
        let appended = message.derivedSnapshot(using: cache)

        XCTAssertEqual(message.text, "prefix-suffix")
        XCTAssertEqual(
            message.derivedTextFingerprint,
            ChatStableContentFingerprint("prefix-suffix"))
        XCTAssertEqual(message.derivedTextUTF8Count, 13)
        XCTAssertFalse(initial === appended)
        XCTAssertEqual(appended.transcriptDisplayText, "prefix-suffix")

        let repeated = message.derivedSnapshot(using: cache)
        XCTAssertTrue(appended === repeated)
        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.computations, 2)
        XCTAssertEqual(metrics.misses, 2)
        XCTAssertEqual(metrics.hits, 1)
        XCTAssertEqual(metrics.hits + metrics.misses, 3)
    }

    func testProductionDerivedResolverIncrementallyProcessesFiftyKilobyteStream() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 16 * 1_024 * 1_024)
        var expected =
            String(repeating: "abcdefghij\n", count: 4_700) + "tail"
        var message = ChatMessage(
            id: "message-production-50kb",
            role: .assistant,
            text: expected,
            status: "streaming")

        XCTAssertGreaterThan(message.derivedTextUTF8Count, 50 * 1_024)
        XCTAssertEqual(
            message.derivedSnapshot(using: cache).transcriptDisplayText,
            expected)
        for index in 0..<128 {
            let suffix = "-token-\(index)"
            expected.append(contentsOf: suffix)
            message.appendTranscriptText(suffix)
            let snapshot = message.derivedSnapshot(using: cache)
            XCTAssertEqual(snapshot.transcriptDisplayText, expected)
            XCTAssertEqual(snapshot.displayAppendSuffix, suffix)
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.fullComputations, 1)
        XCTAssertEqual(metrics.incrementalComputations, 128)
        XCTAssertEqual(metrics.incrementalFallbacks, 0)
        XCTAssertEqual(metrics.computations, 129)
        XCTAssertEqual(metrics.entryCount, 1)
    }

    func testProductionDerivedResolverHidesControlLineWhenPrefixCompletes() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        var message = ChatMessage(
            id: "message-control-prefix",
            role: .assistant,
            text: "Visible\n<imag",
            status: "streaming")

        let incomplete = message.derivedSnapshot(using: cache)
        XCTAssertEqual(incomplete.transcriptDisplayText, "Visible\n<imag")
        message.appendTranscriptText("e ")
        let completed = message.derivedSnapshot(using: cache)

        XCTAssertEqual(completed.transcriptDisplayText, "Visible")
        XCTAssertNil(completed.displayAppendSuffix)
        XCTAssertEqual(cache.metricsSnapshot().fullComputations, 1)
        XCTAssertEqual(cache.metricsSnapshot().incrementalComputations, 1)
    }

    func testProductionDerivedResolverPromotesCompletedMarkdownAttachment() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        var message = ChatMessage(
            id: "message-markdown-attachment",
            role: .assistant,
            text: "Visible\n![report](/tmp/report",
            status: "streaming")

        let incomplete = message.derivedSnapshot(using: cache)
        XCTAssertEqual(
            incomplete.transcriptDisplayText,
            "Visible\n![report](/tmp/report")
        XCTAssertTrue(incomplete.inlineAttachments.isEmpty)
        message.appendTranscriptText(".txt)")
        let completed = message.derivedSnapshot(using: cache)

        XCTAssertEqual(completed.transcriptDisplayText, "Visible")
        XCTAssertEqual(
            completed.inlineAttachments,
            [ChatInlineAttachment(
                path: "/tmp/report.txt",
                name: "report")])
        XCTAssertNil(completed.displayAppendSuffix)
        XCTAssertEqual(cache.metricsSnapshot().fullComputations, 1)
        XCTAssertEqual(cache.metricsSnapshot().incrementalComputations, 1)
    }

    func testIncrementalDerivedOutputMatchesFullResolverForEveryToken() {
        let incrementalCache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 4 * 1_024 * 1_024)
        let referenceCache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 4 * 1_024 * 1_024)
        var message = ChatMessage(
            id: "message-token-equivalence",
            role: .assistant,
            text: "Visible",
            status: "streaming")
        _ = message.derivedSnapshot(using: incrementalCache)
        let streamed =
            "\n  - nested item"
            + "\n    indented continuation"
            + "\n<imag"
            + "e /tmp/preview.png>"
            + "\n![report](/tmp/report"
            + ".txt)"
            + "\n## artifact: /tmp/artifact.json"
            + "\n\tfinal indented line  "

        for (index, character) in streamed.enumerated() {
            message.appendTranscriptText(String(character))
            let incremental =
                message.derivedSnapshot(using: incrementalCache)
            let reference = ChatMessage(
                id: "message-token-equivalence",
                role: .assistant,
                text: message.text,
                status: "streaming"
            ).derivedSnapshot(using: referenceCache)

            XCTAssertEqual(
                incremental.transcriptDisplayText,
                reference.transcriptDisplayText,
                "display mismatch after token \(index)")
            XCTAssertEqual(
                incremental.inlineAttachments,
                reference.inlineAttachments,
                "attachment mismatch after token \(index)")
        }

        let metrics = incrementalCache.metricsSnapshot()
        XCTAssertEqual(metrics.fullComputations, 1)
        XCTAssertEqual(metrics.incrementalFallbacks, 0)
        XCTAssertEqual(
            metrics.incrementalComputations,
            streamed.count)
    }

    func testLargeTrailingMemoryCitationUsesBoundedIncrementalWorkAndCRLFParity() {
        let incrementalCache = ChatMessageDerivedValueCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 16 * 1_024 * 1_024)
        let citationEntries = (0..<2_048).map { index in
            "MEMORY.md:\(index)-\(index + 1)|note=[bounded incremental line]"
        }.joined(separator: "\r\n")
        let source =
            "Visible body\r\n"
            + "<oai-mem-citation>\r\n"
            + "<citation_entries>\r\n"
            + citationEntries
            + "\r\n</citation_entries>\r\n"
            + "<rollout_ids>\r\n"
            + "019f2967-9bb0-7702-9e39-e82e06a861b3\r\n"
            + "</rollout_ids>\r\n"
        var message = ChatMessage(
            id: "message-large-memory-citation",
            role: .assistant,
            text: source,
            status: "streaming")
        let initialSourceUTF8Count = message.text.utf8.count

        func assertIncrementalMatchesFull(_ step: String) {
            let incremental =
                message.derivedSnapshot(using: incrementalCache)
            let referenceCache = ChatMessageDerivedValueCache(
                maximumEntryCount: 1,
                maximumResidentBytes: 16 * 1_024 * 1_024)
            let reference = ChatMessage(
                id: message.id,
                role: message.role,
                text: message.text,
                status: message.status
            ).derivedSnapshot(using: referenceCache)
            XCTAssertEqual(
                incremental.transcriptDisplayText,
                reference.transcriptDisplayText,
                step)
            XCTAssertEqual(
                incremental.inlineAttachments,
                reference.inlineAttachments,
                step)
            XCTAssertEqual(
                incremental.transcriptDisplayFingerprint,
                ChatStableContentFingerprint(
                    incremental.transcriptDisplayText),
                step)
        }

        assertIncrementalMatchesFull("initial incomplete citation")
        for character in "</oai-mem-citation>" {
            message.appendTranscriptText(String(character))
            assertIncrementalMatchesFull("closing token \(character)")
        }
        message.appendTranscriptText("\r\n   ")
        assertIncrementalMatchesFull("trailing CRLF whitespace")
        XCTAssertEqual(
            message.derivedSnapshot(using: incrementalCache)
                .transcriptDisplayText,
            "Visible body")
        var metrics = incrementalCache.metricsSnapshot()
        XCTAssertEqual(metrics.incrementalWholeDisplayRehashes, 1)

        message.appendTranscriptText("P")
        assertIncrementalMatchesFull("citation reveal")
        let rehashesAfterReveal =
            incrementalCache.metricsSnapshot()
                .incrementalWholeDisplayRehashes
        message.appendTranscriptText("rose")
        assertIncrementalMatchesFull("post-citation prose append")

        metrics = incrementalCache.metricsSnapshot()
        XCTAssertEqual(metrics.incrementalFallbacks, 0)
        XCTAssertEqual(metrics.incrementalWholeDisplayRehashes, 2)
        XCTAssertEqual(
            metrics.incrementalWholeDisplayRehashes,
            rehashesAfterReveal)
        XCTAssertLessThan(
            metrics.incrementalProjectionBytesScanned,
            4_096)
        XCTAssertLessThan(
            metrics.incrementalWholeDisplayBytesRehashed,
            initialSourceUTF8Count + 1_024)
    }

    func testComplexDocumentProducesOneAttributedPayloadForEveryBlockKind() {
        let markdown = """
        # Heading

        Paragraph

        ```swift
        let value = 42
        ```

        | Name | Value |
        |:-----|------:|
        | answer | 42 |

        > quoted text

        ---
        """
        let document =
            TatwoAssistantTranscriptPresentation.document(markdown: markdown)
        let identity = ChatTranscriptRenderIdentity(
            messageID: "assistant-complex-document",
            sourceText: markdown,
            textFingerprint: ChatStableContentFingerprint(markdown))
        let payload = ChatTranscriptFlowComposer.cachedDocumentPayload(
            document: document,
            renderIdentity: identity)

        XCTAssertNotNil(payload)
        XCTAssertTrue(document.blocks.contains {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        XCTAssertTrue(document.blocks.contains {
            if case .table = $0.kind { return true }
            return false
        })
        XCTAssertTrue(document.blocks.contains {
            if case .blockquote = $0.kind { return true }
            return false
        })
        XCTAssertTrue(document.blocks.contains {
            if case .horizontalRule = $0.kind { return true }
            return false
        })
        let unwrappedPayload = try! XCTUnwrap(payload)
        let rendered = unwrappedPayload.attributed.string
        XCTAssertTrue(rendered.contains("let value = 42"))
        XCTAssertTrue(rendered.contains("Name"))
        XCTAssertTrue(rendered.contains("answer"))
        XCTAssertTrue(rendered.contains("quoted text"))

        var semantics = Set<String>()
        var codeContent: String?
        var codeLanguage: String?
        var tableColumnCount: Int?
        unwrappedPayload.attributed.enumerateAttributes(
            in: NSRange(
                location: 0,
                length: unwrappedPayload.attributed.length),
            options: []
        ) { attributes, _, _ in
            if let semantic =
                attributes[.chatTranscriptBlockSemantic] as? String
            {
                semantics.insert(semantic)
            }
            codeContent =
                codeContent
                ?? attributes[.chatTranscriptCodeContent] as? String
            codeLanguage =
                codeLanguage
                ?? attributes[.chatTranscriptCodeLanguage] as? String
            tableColumnCount =
                tableColumnCount
                ?? (attributes[.chatTranscriptTableColumnCount]
                    as? NSNumber)?.intValue
        }
        XCTAssertEqual(
            semantics,
            ["code", "table", "blockquote", "horizontal-rule"])
        XCTAssertEqual(codeContent, "let value = 42")
        XCTAssertEqual(codeLanguage, "swift")
        XCTAssertEqual(tableColumnCount, 2)
        XCTAssertTrue(rendered.contains("\u{200B}"))
    }

    func testStructuredCodeAccessoriesAndHorizontalViewerRemainFunctional() {
        let markdown = """
        ```swift
        let veryLongValue = 42
        ```
        """
        let document =
            TatwoAssistantTranscriptPresentation.document(markdown: markdown)
        let identity = ChatTranscriptRenderIdentity(
            messageID: "assistant-code-accessory",
            sourceText: markdown,
            textFingerprint: ChatStableContentFingerprint(markdown))
        let payload = try! XCTUnwrap(
            ChatTranscriptFlowComposer.cachedDocumentPayload(
                document: document,
                renderIdentity: identity))
        let textView = ChatFlowTextView()
        textView.textStorage?.setAttributedString(payload.attributed)
        textView.synchronizeCodeBlockAccessories()

        let accessory = try! XCTUnwrap(
            textView.codeBlockAccessoryViews.first?.view)
        XCTAssertEqual(textView.codeBlockAccessoryViews.count, 1)
        XCTAssertEqual(accessory.code, "let veryLongValue = 42")
        XCTAssertEqual(accessory.language, "swift")
        XCTAssertEqual(accessory.copyButton.title, "複製")
        XCTAssertEqual(
            accessory.copyButton.accessibilityLabel(),
            "複製程式碼")
        XCTAssertEqual(accessory.horizontalViewerButton.title, "橫向檢視")
        XCTAssertEqual(
            accessory.horizontalViewerButton.accessibilityLabel(),
            "水平檢視程式碼")

        let scrollView =
            ChatCodeBlockHorizontalViewer.makeScrollView(
                code: accessory.code)
        let codeView = try! XCTUnwrap(
            scrollView.documentView as? NSTextView)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(
            try! XCTUnwrap(codeView.textContainer).widthTracksTextView)
        XCTAssertEqual(
            codeView.defaultParagraphStyle?.lineBreakMode,
            .byClipping)
        XCTAssertEqual(codeView.string, accessory.code)
    }

    func testTranscriptLinkPolicyConsumesUnsafeTargetsAndOpensOnlyPublicWebURLs() {
        let textView = ChatFlowTextView()
        var opened: [URL] = []
        textView.safeLinkOpener = {
            opened.append($0)
            return true
        }

        let publicURL = URL(string: "https://example.com/safe")!
        XCTAssertEqual(
            ChatTranscriptLinkPolicy.safeURL(from: publicURL),
            publicURL)
        XCTAssertTrue(
            textView.textView(
                textView,
                clickedOnLink: publicURL,
                at: 0))
        XCTAssertEqual(opened, [publicURL])

        let unsafeTargets: [Any] = [
            URL(fileURLWithPath: "/tmp/private"),
            "javascript:alert(1)",
            "http://127.0.0.1/private",
            "http://" + [192, 168, 1, 1].map(String.init).joined(separator: ".") + "/",
            NSObject(),
        ]
        for target in unsafeTargets {
            XCTAssertNil(
                ChatTranscriptLinkPolicy.safeURL(from: target),
                "\(target)")
            XCTAssertTrue(
                textView.textView(
                    textView,
                    clickedOnLink: target,
                    at: 0))
        }
        XCTAssertEqual(opened, [publicURL])
    }

    func testStructuredTableTabsAdaptToMeasuredTranscriptWidth() {
        let markdown = """
        | Name | Value | Notes |
        |:-----|------:|:------|
        | answer | 42 | measured |
        """
        let document =
            TatwoAssistantTranscriptPresentation.document(markdown: markdown)
        let identity = ChatTranscriptRenderIdentity(
            messageID: "assistant-table-width",
            sourceText: markdown,
            textFingerprint: ChatStableContentFingerprint(markdown))
        let payload = try! XCTUnwrap(
            ChatTranscriptFlowComposer.cachedDocumentPayload(
                document: document,
                renderIdentity: identity))
        let measurer = ChatInjectedStreamingLayoutMeasurer()
        let controller = ChatStreamingPlainTextStorageController(
            layoutMeasurer: measurer)
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(
                width: 480,
                height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        controller.applyStructured(
            sourceText: markdown,
            sourceFingerprint: ChatStableContentFingerprint(markdown),
            attributed: payload.attributed,
            contentFingerprint: payload.fingerprint,
            presentationIdentity: ChatTranscriptPresentationIdentity(
                messageID: "assistant-table-width",
                parserVersion:
                    TatwoAssistantTranscriptCache.defaultParserVersion,
                sessionBoundaryGeneration: 1),
            sourceRevision: UUID(),
            to: storage)

        func tableTabLocations() -> [CGFloat] {
            var locations: [CGFloat] = []
            storage.enumerateAttribute(
                .chatTranscriptTableColumnCount,
                in: NSRange(location: 0, length: storage.length),
                options: []
            ) { value, range, stop in
                guard value != nil,
                      let style =
                        storage.attribute(
                            .paragraphStyle,
                            at: range.location,
                            effectiveRange: nil) as? NSParagraphStyle
                else { return }
                locations = style.tabStops.map(\.location)
                stop.pointee = true
            }
            return locations
        }

        _ = controller.measure(
            width: 480,
            traits: layoutTraits(displayScale: 2),
            container: container,
            layoutManager: layoutManager)
        let wideTabs = tableTabLocations()
        _ = controller.measure(
            width: 240,
            traits: layoutTraits(displayScale: 2),
            container: container,
            layoutManager: layoutManager)
        let narrowTabs = tableTabLocations()

        XCTAssertEqual(wideTabs.count, 2)
        XCTAssertEqual(narrowTabs.count, 2)
        XCTAssertNotEqual(wideTabs, narrowTabs)
        XCTAssertGreaterThan(wideTabs[0], narrowTabs[0])
        XCTAssertEqual(controller.metrics.structuredWidthAdaptations, 2)
    }

    func testProductionAssistantBodyKeepsOneRepresentableViewType() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = appRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("TatwoUltraworkMac")
            .appendingPathComponent("ChatPageLeafViews.swift")
        let source = try ChatSourceFamily.read(url: sourceURL)
        let start = try XCTUnwrap(
            source.range(
                of: "private struct ChatAssistantTranscriptCachedText: View {"))
        let end = try XCTUnwrap(
            source.range(
                of: "\nenum ChatRemoteJobInlineLabel",
                range: start.upperBound..<source.endIndex))
        let bodySource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(
            bodySource.components(
                separatedBy: "ChatStreamingPlainTextFlowText("
            ).count - 1,
            1)
        XCTAssertFalse(bodySource.contains("ChatAssistantTranscriptBlockView("))
        XCTAssertFalse(bodySource.contains("if let complexDocument"))
        XCTAssertFalse(bodySource.contains(".id("))
    }

    func testDerivedCacheRetainsLatestGenerationPerMessageAndCrossMessageLRU() {
        let cache = ChatMessageDerivedValueCache(
            maximumEntryCount: 2,
            maximumResidentBytes: 1_024 * 1_024)
        var first = ChatMessage(
            id: "latest-first",
            role: .assistant,
            text: "first")
        let second = ChatMessage(
            id: "latest-second",
            role: .assistant,
            text: "second")
        let third = ChatMessage(
            id: "latest-third",
            role: .assistant,
            text: "third")

        _ = first.derivedSnapshot(using: cache)
        first.appendTranscriptText("-new")
        _ = first.derivedSnapshot(using: cache)
        XCTAssertEqual(cache.metricsSnapshot().entryCount, 1)
        _ = second.derivedSnapshot(using: cache)
        _ = first.derivedSnapshot(using: cache)
        _ = third.derivedSnapshot(using: cache)

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.entryCount, 2)
        XCTAssertEqual(metrics.evictions, 1)
        XCTAssertEqual(
            first.derivedSnapshot(using: cache).transcriptDisplayText,
            "first-new")
        XCTAssertEqual(cache.metricsSnapshot().entryCount, 2)
    }

    func testFiftyKilobyteStreamingPlainTextUsesInjectedGlyphEvidenceRequiresInstruments() {
        let measurer = ChatInjectedStreamingLayoutMeasurer()
        let controller = ChatStreamingPlainTextStorageController(
            layoutMeasurer: measurer)
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(
                width: 520,
                height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let traits = layoutTraits(displayScale: 2)
        var source = String(repeating: "abcdefghij", count: 5_120)
        var fingerprint = ChatStableContentFingerprint(source)
        var revision = UUID()
        let identity = ChatTranscriptPresentationIdentity(
            messageID: "assistant-large",
            parserVersion:
                TatwoAssistantTranscriptCache.defaultParserVersion,
            sessionBoundaryGeneration: 1)

        controller.apply(
            text: source,
            fingerprint: fingerprint,
            presentationIdentity: identity,
            sourceRevision: revision,
            to: storage)
        _ = controller.measure(
            width: 520,
            traits: traits,
            container: container,
            layoutManager: layoutManager)

        for index in 0..<128 {
            let suffix = "-token-\(index)"
            source.append(contentsOf: suffix)
            fingerprint = fingerprint.appending(suffix)
            let baseRevision = revision
            revision = UUID()
            controller.apply(
                text: source,
                fingerprint: fingerprint,
                presentationIdentity: identity,
                sourceRevision: revision,
                appendBaseRevision: baseRevision,
                appendedDisplaySuffix: suffix,
                to: storage)
            _ = controller.measure(
                width: 520,
                traits: traits,
                container: container,
                layoutManager: layoutManager)
        }

        XCTAssertEqual(storage.string, source)
        XCTAssertGreaterThan(source.utf8.count, 50 * 1_024)
        XCTAssertEqual(controller.metrics.fullAttributedReplacements, 1)
        XCTAssertEqual(controller.metrics.fullPayloadBuilds, 1)
        XCTAssertEqual(controller.metrics.incrementalAttributedAppends, 128)
        XCTAssertEqual(controller.metrics.layoutComputations, 129)
        XCTAssertEqual(controller.metrics.fullLayoutComputations, 1)
        XCTAssertEqual(
            controller.metrics.incrementalLayoutComputations,
            128)
        XCTAssertLessThan(
            controller.metrics.fullPayloadBuilds,
            controller.metrics.incrementalAttributedAppends)
        XCTAssertLessThan(
            controller.metrics.fullLayoutComputations,
            controller.metrics.incrementalLayoutComputations)
        XCTAssertEqual(controller.metrics.textContainerResizes, 1)
        XCTAssertEqual(measurer.callCount, 129)
        XCTAssertGreaterThan(
            controller.metrics.lastLaidOutGlyphRange.length,
            50 * 1_024)
    }

    func testStreamingControllerKeepsTextViewIdentityAcrossStructuredTransition() {
        let textView = NSTextView()
        let storage = try! XCTUnwrap(textView.textStorage)
        let controller = ChatStreamingPlainTextStorageController()
        let textViewIdentity = ObjectIdentifier(textView)
        let controllerIdentity = ObjectIdentifier(controller)
        let presentation = ChatTranscriptPresentationIdentity(
            messageID: "assistant-identity",
            parserVersion:
                TatwoAssistantTranscriptCache.defaultParserVersion,
            sessionBoundaryGeneration: 1)
        let firstRevision = UUID()
        let plain = "Plain stream"

        controller.apply(
            text: plain,
            fingerprint: ChatStableContentFingerprint(plain),
            presentationIdentity: presentation,
            sourceRevision: firstRevision,
            to: storage,
            preservingStateOf: textView)
        textView.setSelectedRange(NSRange(location: 1, length: 4))

        let structured = NSAttributedString(
            string: "Plain stream",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        controller.applyStructured(
            sourceText: plain,
            sourceFingerprint: ChatStableContentFingerprint(plain),
            attributed: structured,
            contentFingerprint:
                ChatSelectableFlowTextContentFingerprint(structured),
            presentationIdentity: presentation,
            sourceRevision: firstRevision,
            to: storage,
            preservingStateOf: textView)

        XCTAssertEqual(ObjectIdentifier(textView), textViewIdentity)
        XCTAssertEqual(ObjectIdentifier(controller), controllerIdentity)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 4))

        let appended = plain + "!"
        let appendedRevision = UUID()
        controller.apply(
            text: appended,
            fingerprint: ChatStableContentFingerprint(appended),
            presentationIdentity: presentation,
            sourceRevision: appendedRevision,
            appendBaseRevision: firstRevision,
            appendedDisplaySuffix: "!",
            to: storage,
            preservingStateOf: textView)

        XCTAssertEqual(ObjectIdentifier(textView), textViewIdentity)
        XCTAssertEqual(ObjectIdentifier(controller), controllerIdentity)
        XCTAssertEqual(storage.string, appended)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 4))
        XCTAssertEqual(controller.metrics.structuredAttributedReplacements, 1)
        XCTAssertEqual(controller.metrics.fullAttributedReplacements, 2)
        XCTAssertEqual(controller.metrics.incrementalAttributedAppends, 1)

        controller.apply(
            text: appended,
            fingerprint: ChatStableContentFingerprint(appended),
            presentationIdentity: presentation,
            sourceRevision: appendedRevision,
            appendBaseRevision: firstRevision,
            appendedDisplaySuffix: "!",
            to: storage,
            preservingStateOf: textView)

        XCTAssertEqual(ObjectIdentifier(textView), textViewIdentity)
        XCTAssertEqual(ObjectIdentifier(controller), controllerIdentity)
        XCTAssertEqual(storage.string, appended)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 4))
        XCTAssertEqual(
            storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
            NSFont.boldSystemFont(ofSize: 13))
        XCTAssertEqual(controller.metrics.structuredAttributedReplacements, 1)
        XCTAssertEqual(controller.metrics.fullAttributedReplacements, 2)
        XCTAssertEqual(controller.metrics.incrementalAttributedAppends, 1)
    }

    func testAssistantParseCoalescingUsesShortDelayOnlyForSmallIncrementalAppends() {
        let threshold =
            TatwoAssistantTranscriptThrottle.longTextByteThreshold

        XCTAssertNil(
            ChatAssistantTranscriptParseCoalescing.delay(
                utf8Count: threshold,
                isIncrementalAppend: false))
        XCTAssertEqual(
            ChatAssistantTranscriptParseCoalescing.delay(
                utf8Count: threshold,
                isIncrementalAppend: true),
            .milliseconds(48))
        XCTAssertEqual(
            ChatAssistantTranscriptParseCoalescing.delay(
                utf8Count: threshold + 1,
                isIncrementalAppend: false),
            TatwoAssistantTranscriptThrottle.longTextDelay)
        XCTAssertEqual(
            ChatAssistantTranscriptParseCoalescing.delay(
                utf8Count: threshold + 1,
                isIncrementalAppend: true),
            TatwoAssistantTranscriptThrottle.longTextDelay)
    }

    func testPresentationIdentityChangesForceFullReplacement() {
        let controller = ChatStreamingPlainTextStorageController()
        let storage = NSTextStorage()
        let text = "presentation"
        let fingerprint = ChatStableContentFingerprint(text)
        let revision = UUID()
        let base = ChatTranscriptPresentationIdentity(
            messageID: "assistant-presentation",
            parserVersion:
                TatwoAssistantTranscriptCache.defaultParserVersion,
            pointSize: 13,
            lineSpacing: 3,
            sessionBoundaryGeneration: 1)

        controller.apply(
            text: text,
            fingerprint: fingerprint,
            presentationIdentity: base,
            sourceRevision: revision,
            to: storage)
        controller.apply(
            text: text,
            fingerprint: fingerprint,
            presentationIdentity: ChatTranscriptPresentationIdentity(
                messageID: "assistant-presentation",
                parserVersion:
                    TatwoAssistantTranscriptCache.defaultParserVersion,
                pointSize: 14,
                lineSpacing: 3,
                sessionBoundaryGeneration: 1),
            sourceRevision: revision,
            to: storage)
        controller.apply(
            text: text,
            fingerprint: fingerprint,
            presentationIdentity: ChatTranscriptPresentationIdentity(
                messageID: "assistant-presentation",
                parserVersion:
                    TatwoAssistantTranscriptCache.defaultParserVersion,
                pointSize: 14,
                lineSpacing: 4,
                sessionBoundaryGeneration: 1),
            sourceRevision: revision,
            to: storage)
        controller.apply(
            text: text,
            fingerprint: fingerprint,
            presentationIdentity: ChatTranscriptPresentationIdentity(
                messageID: "assistant-presentation",
                parserVersion:
                    TatwoAssistantTranscriptCache.defaultParserVersion,
                pointSize: 14,
                lineSpacing: 4,
                sessionBoundaryGeneration: 2),
            sourceRevision: revision,
            to: storage)

        XCTAssertEqual(controller.metrics.fullAttributedReplacements, 4)
        XCTAssertEqual(controller.metrics.incrementalAttributedAppends, 0)
    }

    func testFlowTextLayoutCacheHitsAndInvalidatesWidthContentAndTraits() {
        let cache = ChatSelectableFlowTextLayoutCache(maximumEntryCount: 8)
        let attributed = NSAttributedString(
            string: "same content",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let content = ChatSelectableFlowTextContentFingerprint(
            attributed)
        let semanticIdentity = UUID()
        let otherAttributed = NSAttributedString(
            string: "changed content",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let otherContent = ChatSelectableFlowTextContentFingerprint(
            otherAttributed)
        let otherSemanticIdentity = UUID()
        let baseTraits = layoutTraits(displayScale: 2)
        let changedTraits = layoutTraits(displayScale: 1)
        var measurements = 0

        func resolve(
            content: ChatSelectableFlowTextContentFingerprint = content,
            semanticIdentity: UUID = semanticIdentity,
            width: CGFloat = 520,
            traits: ChatSelectableFlowTextLayoutTraits = baseTraits
        ) -> CGSize {
            cache.resolve(
                key: ChatSelectableFlowTextLayoutKey(
                    content: content,
                    semanticIdentity: semanticIdentity,
                    width: width,
                    traits: traits)
            ) {
                measurements += 1
                return CGSize(width: width, height: CGFloat(measurements * 10))
            }
        }

        XCTAssertEqual(resolve(), CGSize(width: 520, height: 10))
        XCTAssertEqual(resolve(), CGSize(width: 520, height: 10))
        XCTAssertEqual(resolve(width: 480), CGSize(width: 480, height: 20))
        XCTAssertEqual(
            resolve(
                content: otherContent,
                semanticIdentity: otherSemanticIdentity),
            CGSize(width: 520, height: 30))
        XCTAssertEqual(
            resolve(traits: changedTraits),
            CGSize(width: 520, height: 40))

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(measurements, 4)
        XCTAssertEqual(metrics.hits, 1)
        XCTAssertEqual(metrics.misses, 4)
        XCTAssertEqual(metrics.measurements, 4)
        XCTAssertEqual(metrics.hits + metrics.misses, 5)
    }

    func testFlowTextLayoutCachePreparesViewStateOnHit() {
        let cache = ChatSelectableFlowTextLayoutCache(maximumEntryCount: 8)
        let attributed = NSAttributedString(string: "same content")
        let content = ChatSelectableFlowTextContentFingerprint(
            attributed)
        let semanticIdentity = UUID()
        let key = ChatSelectableFlowTextLayoutKey(
            content: content,
            semanticIdentity: semanticIdentity,
            width: 520,
            traits: layoutTraits(displayScale: 2))
        var preparations = 0
        var measurements = 0

        func resolve() -> CGSize {
            cache.resolve(
                key: key,
                prepare: {
                    preparations += 1
                }
            ) {
                measurements += 1
                return CGSize(width: 520, height: 42)
            }
        }

        XCTAssertEqual(resolve(), CGSize(width: 520, height: 42))
        XCTAssertEqual(resolve(), CGSize(width: 520, height: 42))
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(measurements, 1)
        XCTAssertEqual(cache.metricsSnapshot().hits, 1)
    }

    func testFlowTextLayoutCacheMissesForSameLengthDifferentContent() {
        let cache = ChatSelectableFlowTextLayoutCache(maximumEntryCount: 8)
        let firstAttributed = NSAttributedString(
            string: "same-size-a",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let secondAttributed = NSAttributedString(
            string: "same-size-b",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let firstContent =
            ChatSelectableFlowTextContentFingerprint(firstAttributed)
        let secondContent =
            ChatSelectableFlowTextContentFingerprint(secondAttributed)
        let traits = layoutTraits(displayScale: 2)
        let firstSemanticIdentity = UUID()
        let secondSemanticIdentity = UUID()
        var measurements = 0

        func resolve(
            semanticIdentity: UUID,
            content: ChatSelectableFlowTextContentFingerprint
        ) {
            _ = cache.resolve(
                key: ChatSelectableFlowTextLayoutKey(
                    content: content,
                    semanticIdentity: semanticIdentity,
                    width: 520,
                    traits: traits)
            ) {
                measurements += 1
                return CGSize(width: 520, height: CGFloat(measurements))
            }
        }

        XCTAssertEqual(firstAttributed.length, secondAttributed.length)
        XCTAssertNotEqual(firstContent, secondContent)
        resolve(
            semanticIdentity: firstSemanticIdentity,
            content: firstContent)
        resolve(
            semanticIdentity: firstSemanticIdentity,
            content: firstContent)
        resolve(
            semanticIdentity: secondSemanticIdentity,
            content: secondContent)

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(measurements, 2)
        XCTAssertEqual(metrics.hits, 1)
        XCTAssertEqual(metrics.misses, 2)
        XCTAssertEqual(metrics.hits + metrics.misses, 3)
    }

    func testFlowTextLayoutKeyUsesSemanticIdentityAsCollisionGuard() {
        let firstAttributed = NSAttributedString(
            string: "semantic-equal",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let reconstructedAttributed = NSAttributedString(
            string: "semantic-equal",
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let firstContent =
            ChatSelectableFlowTextContentFingerprint(firstAttributed)
        let reconstructedContent =
            ChatSelectableFlowTextContentFingerprint(
                reconstructedAttributed)
        let traits = layoutTraits(displayScale: 2)

        XCTAssertEqual(firstContent, reconstructedContent)
        XCTAssertNotEqual(
            ChatSelectableFlowTextLayoutKey(
                content: firstContent,
                semanticIdentity: UUID(),
                width: 520,
                traits: traits),
            ChatSelectableFlowTextLayoutKey(
                content: reconstructedContent,
                semanticIdentity: UUID(),
                width: 520,
                traits: traits))
    }

    func testComposerProvidesStablePrecomputedLayoutFingerprint() {
        let first = ChatTranscriptFlowComposer.plainPayload("same content")
        let second = ChatTranscriptFlowComposer.plainPayload("same content")
        let changed = ChatTranscriptFlowComposer.plainPayload("changed content")

        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
        XCTAssertEqual(first.fingerprint.attributedLength, first.attributed.length)
        XCTAssertEqual(first.fingerprint.attributeRunCount, 1)
    }

    func testAttributedPayloadPreservesInlineAndListSemanticsOnCacheHit() {
        ChatTranscriptFlowPayloadCache.shared.reset()
        defer { ChatTranscriptFlowPayloadCache.shared.reset() }
        let markdown =
            "**bold** *italic* ~~strike~~ [link](https://example.com)\n\n- item"
        let document =
            TatwoAssistantTranscriptPresentation.document(markdown: markdown)
        let blocks = document.blocks.filter {
            ChatTranscriptFlowComposer.isFlowKind($0.kind)
        }
        let firstBlock = try! XCTUnwrap(blocks.first)
        let lastBlock = try! XCTUnwrap(blocks.last)
        let identity = ChatTranscriptRenderIdentity(
            messageID: "semantic-payload",
            sourceText: markdown,
            textFingerprint: ChatStableContentFingerprint(markdown))

        let first = ChatTranscriptFlowComposer.cachedAttributedPayload(
            blocks: blocks,
            previousKind: nil,
            renderIdentity: identity,
            segmentFirstID: firstBlock.id,
            segmentLastID: lastBlock.id)
        let repeated = ChatTranscriptFlowComposer.cachedAttributedPayload(
            blocks: blocks,
            previousKind: nil,
            renderIdentity: identity,
            segmentFirstID: firstBlock.id,
            segmentLastID: lastBlock.id)

        XCTAssertTrue(first === repeated)
        XCTAssertTrue(first.attributed === repeated.attributed)

        let rendered = first.attributed
        let source = rendered.string as NSString
        let boldRange = source.range(of: "bold")
        let italicRange = source.range(of: "italic")
        let strikeRange = source.range(of: "strike")
        let linkRange = source.range(of: "link")
        let itemRange = source.range(of: "item")
        XCTAssertNotEqual(boldRange.location, NSNotFound)
        XCTAssertNotEqual(italicRange.location, NSNotFound)
        XCTAssertNotEqual(strikeRange.location, NSNotFound)
        XCTAssertNotEqual(linkRange.location, NSNotFound)
        XCTAssertNotEqual(itemRange.location, NSNotFound)

        let boldFont = rendered.attribute(
            .font,
            at: boldRange.location,
            effectiveRange: nil) as? NSFont
        let italicFont = rendered.attribute(
            .font,
            at: italicRange.location,
            effectiveRange: nil) as? NSFont
        XCTAssertTrue(
            boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(
            italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        XCTAssertNotEqual(
            rendered.attribute(
                .strikethroughStyle,
                at: strikeRange.location,
                effectiveRange: nil) as? Int,
            0)
        XCTAssertEqual(
            (rendered.attribute(
                .link,
                at: linkRange.location,
                effectiveRange: nil) as? URL)?.absoluteString,
            "https://example.com")

        let listStyle = rendered.attribute(
            .paragraphStyle,
            at: itemRange.location,
            effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(listStyle?.headIndent ?? 0, 0)
        XCTAssertEqual(listStyle?.firstLineHeadIndent, 0)
        XCTAssertEqual(listStyle?.tabStops.count, 2)
        XCTAssertLessThan(
            listStyle?.tabStops[0].location ?? 0,
            listStyle?.tabStops[1].location ?? 0)
    }

    func testStaticTranscriptRenderIdentityIsStableAndContentScoped() {
        let first =
            ChatTranscriptRenderIdentity.staticTranscript("same plan")
        let repeated =
            ChatTranscriptRenderIdentity.staticTranscript("same plan")
        let changed =
            ChatTranscriptRenderIdentity.staticTranscript("changed plan")

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, changed)
        XCTAssertNil(ChatTranscriptRenderIdentity.staticTranscript(""))
    }

    func testFlowPayloadCacheReusesExactAttributedIdentityAndMutatesOnce() {
        let cache = ChatTranscriptFlowPayloadCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        let firstIdentity = ChatTranscriptRenderIdentity(
            messageID: "assistant-payload",
            sourceText: "same-size-a",
            textFingerprint: ChatStableContentFingerprint("same-size-a"))
        let secondIdentity = ChatTranscriptRenderIdentity(
            messageID: "assistant-payload",
            sourceText: "same-size-b",
            textFingerprint: ChatStableContentFingerprint("same-size-b"))
        var computations = 0

        func resolve(
            _ text: String,
            identity: ChatTranscriptRenderIdentity
        ) -> ChatTranscriptFlowComposer.Payload {
            cache.resolve(
                key: ChatTranscriptFlowPayloadCacheKey(
                    renderIdentity: identity,
                    variant: .plain)
            ) {
                computations += 1
                return ChatTranscriptFlowComposer.plainPayload(text)
            }
        }

        let first = resolve("same-size-a", identity: firstIdentity)
        let repeated = resolve("same-size-a", identity: firstIdentity)
        XCTAssertTrue(first === repeated)
        XCTAssertTrue(first.attributed === repeated.attributed)
        XCTAssertEqual(
            first.layoutSemanticIdentity,
            repeated.layoutSemanticIdentity)
        XCTAssertEqual(computations, 1)

        let mutated = resolve("same-size-b", identity: secondIdentity)
        let mutatedRepeated = resolve(
            "same-size-b",
            identity: secondIdentity)
        XCTAssertFalse(first === mutated)
        XCTAssertTrue(mutated === mutatedRepeated)
        XCTAssertTrue(mutated.attributed === mutatedRepeated.attributed)
        XCTAssertNotEqual(first.fingerprint, mutated.fingerprint)
        XCTAssertEqual(computations, 2)

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.computations, 2)
        XCTAssertEqual(metrics.misses, 2)
        XCTAssertEqual(metrics.hits, 2)
    }

    func testFlowPayloadParserVersionInvalidatesSameSource() {
        let cache = ChatTranscriptFlowPayloadCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        let source = "same parser source"
        let identity = ChatTranscriptRenderIdentity(
            messageID: "payload-parser-version",
            sourceText: source,
            textFingerprint: ChatStableContentFingerprint(source))
        var computations = 0

        func resolve(parserVersion: Int)
            -> ChatTranscriptFlowComposer.Payload
        {
            cache.resolve(
                key: ChatTranscriptFlowPayloadCacheKey(
                    renderIdentity: identity,
                    variant: .plain,
                    parserVersion: parserVersion)
            ) {
                computations += 1
                return ChatTranscriptFlowComposer.plainPayload(
                    "parser-\(parserVersion)")
            }
        }

        XCTAssertEqual(
            resolve(parserVersion: 1).attributed.string,
            "parser-1")
        XCTAssertEqual(
            resolve(parserVersion: 2).attributed.string,
            "parser-2")
        XCTAssertEqual(
            resolve(parserVersion: 1).attributed.string,
            "parser-1")
        XCTAssertEqual(computations, 2)
        XCTAssertEqual(cache.metricsSnapshot().hits, 1)
        XCTAssertEqual(cache.metricsSnapshot().misses, 2)
    }

    func testRenderIdentityTreatsFingerprintCollisionAsPayloadMiss() {
        let cache = ChatTranscriptFlowPayloadCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024 * 1_024)
        let collision = ChatStableContentFingerprint("same-fingerprint")
        let firstIdentity = ChatTranscriptRenderIdentity(
            messageID: "assistant-collision",
            sourceText: "first source",
            textFingerprint: collision)
        let secondIdentity = ChatTranscriptRenderIdentity(
            messageID: "assistant-collision",
            sourceText: "other source",
            textFingerprint: collision)
        var computations = 0

        func resolve(
            identity: ChatTranscriptRenderIdentity,
            text: String
        ) -> ChatTranscriptFlowComposer.Payload {
            cache.resolve(
                key: ChatTranscriptFlowPayloadCacheKey(
                    renderIdentity: identity,
                    variant: .plain)
            ) {
                computations += 1
                return ChatTranscriptFlowComposer.plainPayload(text)
            }
        }

        let first = resolve(identity: firstIdentity, text: "first source")
        let second = resolve(identity: secondIdentity, text: "other source")

        XCTAssertEqual(first.attributed.string, "first source")
        XCTAssertEqual(second.attributed.string, "other source")
        XCTAssertFalse(first === second)
        XCTAssertEqual(computations, 2)
    }

    func testFlowPayloadCacheIsCountAndByteBounded() {
        let cache = ChatTranscriptFlowPayloadCache(
            maximumEntryCount: 2,
            maximumResidentBytes: 2_048)

        for index in 0..<6 {
            let source = String(repeating: "\(index)", count: 80)
            let identity = ChatTranscriptRenderIdentity(
                messageID: "payload-\(index)",
                sourceText: source,
                textFingerprint: ChatStableContentFingerprint(
                    source))
            _ = cache.resolve(
                key: ChatTranscriptFlowPayloadCacheKey(
                    renderIdentity: identity,
                    variant: .plain)
            ) {
                ChatTranscriptFlowComposer.plainPayload(
                    source)
            }
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertLessThanOrEqual(metrics.entryCount, 2)
        XCTAssertLessThanOrEqual(metrics.residentBytes, 2_048)
        XCTAssertGreaterThan(metrics.evictions, 0)
    }

    func testFlowPayloadCacheCountsExactSourceKeyBytesForOversizeBypass() {
        let cache = ChatTranscriptFlowPayloadCache(
            maximumEntryCount: 8,
            maximumResidentBytes: 1_024)
        let largeSource = String(repeating: "filtered-source-", count: 512)
        let identity = ChatTranscriptRenderIdentity(
            messageID: "large-payload-source",
            sourceText: largeSource,
            textFingerprint: ChatStableContentFingerprint(largeSource))

        _ = cache.resolve(
            key: ChatTranscriptFlowPayloadCacheKey(
                renderIdentity: identity,
                variant: .plain)
        ) {
            ChatTranscriptFlowComposer.plainPayload("x")
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.oversizedBypasses, 1)
        XCTAssertEqual(metrics.entryCount, 0)
        XCTAssertEqual(metrics.residentBytes, 0)
    }

    func testFlowTextFingerprintIncludesFontAndLayoutCacheIsBounded() {
        let regular = ChatSelectableFlowTextContentFingerprint(
            NSAttributedString(
                string: "font-sensitive",
                attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let larger = ChatSelectableFlowTextContentFingerprint(
            NSAttributedString(
                string: "font-sensitive",
                attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        XCTAssertNotEqual(regular, larger)

        let cache = ChatSelectableFlowTextLayoutCache(maximumEntryCount: 2)
        let traits = layoutTraits(displayScale: 2)
        let regularSemanticIdentity = UUID()
        for width in [320.0, 420.0, 520.0, 620.0] {
            _ = cache.resolve(
                key: ChatSelectableFlowTextLayoutKey(
                    content: regular,
                    semanticIdentity: regularSemanticIdentity,
                    width: width,
                    traits: traits)
            ) {
                CGSize(width: width, height: 20)
            }
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(metrics.entryCount, 2)
        XCTAssertEqual(metrics.evictions, 2)
    }

    func testFlowTextFingerprintIncludesParagraphLayoutProperties() {
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = 3
        baseParagraph.paragraphSpacing = 5
        baseParagraph.firstLineHeadIndent = 7
        baseParagraph.defaultTabInterval = 28
        baseParagraph.hyphenationFactor = 0.2

        let changedParagraph = baseParagraph.mutableCopy()
            as! NSMutableParagraphStyle
        changedParagraph.baseWritingDirection = .rightToLeft

        let base = ChatSelectableFlowTextContentFingerprint(
            NSAttributedString(
                string: "paragraph-sensitive",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .paragraphStyle: baseParagraph,
                ]))
        let changed = ChatSelectableFlowTextContentFingerprint(
            NSAttributedString(
                string: "paragraph-sensitive",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .paragraphStyle: changedParagraph,
                ]))

        XCTAssertTrue(base.isCacheable)
        XCTAssertTrue(changed.isCacheable)
        XCTAssertNotEqual(base, changed)
    }

    func testUnknownAttributedValueBypassesLayoutCacheWithoutEntryChurn() {
        final class UnknownLayoutAttribute: NSObject {}

        let attributed = NSAttributedString(
            string: "unknown-attribute",
            attributes: [
                NSAttributedString.Key("tatwo.unknown-layout"):
                    UnknownLayoutAttribute(),
            ])
        let content = ChatSelectableFlowTextContentFingerprint(attributed)
        XCTAssertFalse(content.isCacheable)
        let semanticIdentity = UUID()

        let cache = ChatSelectableFlowTextLayoutCache(maximumEntryCount: 8)
        let key = ChatSelectableFlowTextLayoutKey(
            content: content,
            semanticIdentity: semanticIdentity,
            width: 520,
            traits: layoutTraits(displayScale: 2))
        var measurements = 0
        for _ in 0..<2 {
            _ = cache.resolve(key: key) {
                measurements += 1
                return CGSize(width: 520, height: 20)
            }
        }

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(measurements, 2)
        XCTAssertEqual(metrics.uncacheableBypasses, 2)
        XCTAssertEqual(metrics.entryCount, 0)
    }

    func testFlowTextWidthKeyUsesDisplayPixelCanonicalization() {
        let attributed = NSAttributedString(string: "pixel width")
        let content = ChatSelectableFlowTextContentFingerprint(
            attributed)
        let traits = layoutTraits(displayScale: 2)
        let semanticIdentity = UUID()
        let first = ChatSelectableFlowTextLayoutKey(
            content: content,
            semanticIdentity: semanticIdentity,
            width: 520.01,
            traits: traits)
        let samePixel = ChatSelectableFlowTextLayoutKey(
            content: content,
            semanticIdentity: semanticIdentity,
            width: 520.20,
            traits: traits)
        let nextPixel = ChatSelectableFlowTextLayoutKey(
            content: content,
            semanticIdentity: semanticIdentity,
            width: 520.30,
            traits: traits)

        XCTAssertEqual(first, samePixel)
        XCTAssertEqual(first.layoutWidth, 520)
        XCTAssertNotEqual(first, nextPixel)
        XCTAssertEqual(nextPixel.layoutWidth, 520.5)
    }

    func testFlowTextLayoutCacheHonorsRecentAccessBeforeEviction() {
        let cache = ChatSelectableFlowTextLayoutCache(maximumEntryCount: 2)
        let attributed = NSAttributedString(string: "lru")
        let content = ChatSelectableFlowTextContentFingerprint(
            attributed)
        let traits = layoutTraits(displayScale: 2)
        let semanticIdentity = UUID()
        var measurements = 0

        func resolve(_ width: CGFloat) {
            _ = cache.resolve(
                key: ChatSelectableFlowTextLayoutKey(
                    content: content,
                    semanticIdentity: semanticIdentity,
                    width: width,
                    traits: traits)
            ) {
                measurements += 1
                return CGSize(width: width, height: CGFloat(measurements))
            }
        }

        resolve(320)
        resolve(420)
        resolve(320)
        resolve(520)
        resolve(320)
        resolve(420)

        let metrics = cache.metricsSnapshot()
        XCTAssertEqual(measurements, 4)
        XCTAssertEqual(metrics.hits, 2)
        XCTAssertEqual(metrics.evictions, 2)
    }

    func testSessionBoundaryPreservesSharedReproducibleCaches() {
        ChatTranscriptPerformanceCacheCoordinator.resetSharedCaches()
        defer {
            ChatTranscriptPerformanceCacheCoordinator.resetSharedCaches()
        }
        let attributed = NSAttributedString(string: "session-boundary")
        let content = ChatSelectableFlowTextContentFingerprint(
            attributed)
        let semanticIdentity = UUID()
        let key = ChatSelectableFlowTextLayoutKey(
            content: content,
            semanticIdentity: semanticIdentity,
            width: 520,
            traits: layoutTraits(displayScale: 2))
        _ = ChatSelectableFlowTextLayoutCache.shared.resolve(key: key) {
            CGSize(width: 520, height: 20)
        }
        let message = ChatMessage(
            id: "session-message",
            role: .assistant,
            text: "private session text")
        _ = message.derivedSnapshot(using: .shared)
        let renderIdentity = ChatTranscriptRenderIdentity(
            messageID: "session-message",
            sourceText: message.text,
            textFingerprint: message.derivedTextFingerprint)
        _ = ChatTranscriptFlowPayloadCache.shared.resolve(
            key: ChatTranscriptFlowPayloadCacheKey(
                renderIdentity: renderIdentity,
                variant: .plain)
        ) {
            ChatTranscriptFlowComposer.plainPayload("private session text")
        }

        let layoutEntries =
            ChatSelectableFlowTextLayoutCache.shared
                .metricsSnapshot().entryCount
        let derivedEntries =
            ChatMessageDerivedValueCache.shared.metricsSnapshot().entryCount
        let payloadEntries =
            ChatTranscriptFlowPayloadCache.shared.metricsSnapshot().entryCount
        XCTAssertGreaterThan(layoutEntries, 0)
        XCTAssertGreaterThan(derivedEntries, 0)
        XCTAssertGreaterThan(payloadEntries, 0)

        ChatTranscriptPerformanceCacheCoordinator.sessionBoundaryDidChange()

        XCTAssertEqual(
            ChatSelectableFlowTextLayoutCache.shared
                .metricsSnapshot().entryCount,
            layoutEntries)
        XCTAssertEqual(
            ChatMessageDerivedValueCache.shared.metricsSnapshot().entryCount,
            derivedEntries)
        XCTAssertEqual(
            ChatTranscriptFlowPayloadCache.shared.metricsSnapshot().entryCount,
            payloadEntries)
    }

    func testExplicitPressureResetDropsAllSharedReproducibleCaches() {
        let identity = ChatTranscriptRenderIdentity(
            messageID: "pressure-message",
            sourceText: "pressure",
            textFingerprint: ChatStableContentFingerprint("pressure"))
        _ = ChatTranscriptFlowPayloadCache.shared.resolve(
            key: ChatTranscriptFlowPayloadCacheKey(
                renderIdentity: identity,
                variant: .plain)
        ) {
            ChatTranscriptFlowComposer.plainPayload("pressure")
        }
        let message = ChatMessage(
            id: "pressure-message",
            role: .assistant,
            text: "pressure")
        _ = message.derivedSnapshot(using: .shared)

        ChatTranscriptPerformanceCacheCoordinator.resetSharedCaches()

        XCTAssertEqual(
            ChatMessageDerivedValueCache.shared.metricsSnapshot().entryCount,
            0)
        XCTAssertEqual(
            ChatTranscriptFlowPayloadCache.shared.metricsSnapshot().entryCount,
            0)
        XCTAssertEqual(
            ChatSelectableFlowTextLayoutCache.shared
                .metricsSnapshot().entryCount,
            0)
    }

    func testScheduledPressureResetHopsFromBackgroundToMainActor() async {
        ChatTranscriptPerformanceCacheCoordinator.resetSharedCaches()
        let attributed = NSAttributedString(string: "actor-safe-pressure")
        let content = ChatSelectableFlowTextContentFingerprint(attributed)
        let key = ChatSelectableFlowTextLayoutKey(
            content: content,
            semanticIdentity: UUID(),
            width: 480,
            traits: layoutTraits(displayScale: 2))
        _ = ChatSelectableFlowTextLayoutCache.shared.resolve(key: key) {
            CGSize(width: 480, height: 24)
        }
        XCTAssertEqual(
            ChatSelectableFlowTextLayoutCache.shared
                .metricsSnapshot().entryCount,
            1)

        let observed = OSAllocatedUnfairLock(
            initialState: (wasMainThread: false, count: 0))
        let resetExpectation = expectation(
            description: "pressure reset posts from main actor")
        let token = NotificationCenter.default.addObserver(
            forName:
                ChatTranscriptPerformanceCacheCoordinator.resetNotification,
            object: nil,
            queue: nil
        ) { _ in
            observed.withLock {
                $0.wasMainThread = Thread.isMainThread
                $0.count += 1
            }
            resetExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            ChatTranscriptPerformanceCacheCoordinator.resetSharedCaches()
        }

        await Task.detached {
            ChatTranscriptPerformanceCacheCoordinator
                .scheduleMemoryPressureReset()
        }.value
        await fulfillment(of: [resetExpectation], timeout: 2)

        XCTAssertTrue(observed.withLock { $0.wasMainThread })
        XCTAssertEqual(observed.withLock { $0.count }, 1)
        XCTAssertEqual(
            ChatSelectableFlowTextLayoutCache.shared
                .metricsSnapshot().entryCount,
            0)
    }

    func testPressureResetDropsModelOwnedProjectionCache() async {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("native-chat-threads.json")
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "focused-test",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR_DISABLED": "1",
            ],
            store: TatwoNativeChatStore(url: storeURL, fallbackURLs: []))
        model.messages = [
            ChatMessage(
                id: "pressure-model-message",
                role: .assistant,
                text: "cached projection"),
        ]

        _ = model.transcriptMessages
        _ = await model.assistantTranscriptCache.document(
            messageID: "pressure-assistant-document",
            markdown: "**cached assistant document**")
        XCTAssertEqual(
            model.transcriptProjectionCacheMetrics.recomputations,
            1)
        XCTAssertGreaterThan(model.assistantTranscriptCache.count, 0)
        XCTAssertGreaterThan(
            model.assistantTranscriptCache.residentByteCount,
            0)

        ChatTranscriptPerformanceCacheCoordinator.resetSharedCaches()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            model.transcriptProjectionCacheMetrics,
            ChatTranscriptProjectionCacheMetrics())
        XCTAssertEqual(model.assistantTranscriptCache.count, 0)
        XCTAssertEqual(model.assistantTranscriptCache.residentByteCount, 0)
    }

    private func layoutTraits(
        displayScale: CGFloat
    ) -> ChatSelectableFlowTextLayoutTraits {
        ChatSelectableFlowTextLayoutTraits(
            displayScale: displayScale,
            dynamicTypeSize: "large",
            layoutDirection: "leftToRight",
            legibilityWeight: "regular",
            localeIdentifier: "en_US",
            appearanceName: "NSAppearanceNameAqua",
            tracksAvailableWidth: false,
            lineFragmentPadding: 0,
            inset: .zero)
    }
}
