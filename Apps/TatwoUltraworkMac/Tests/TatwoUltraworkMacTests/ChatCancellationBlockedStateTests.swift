import Foundation
import TatwoUltraworkCore
import XCTest

@testable import TatwoUltraworkMac

final class ChatCancellationBlockedStateTests: XCTestCase {
    func testCoordinatorPersistsExactAttemptAcrossRelaunch() throws {
        let store = InMemoryCancellationStateStore()
        let clock = MutableCancellationClock(
            now: Date(timeIntervalSince1970: 10))
        let identity = ChatRunnerAttemptIdentity(
            runID: "run-durable",
            attempt: 2,
            instanceID: UUID(),
            revision: 9)
        let first = ChatCancellationDurabilityCoordinator(
            store: store,
            now: { clock.value })

        let requested = try first.requestCancellation(
            identity: identity,
            assistantID: "assistant-missing-after-relaunch",
            threadID: "thread:durable")
        clock.value = Date(timeIntervalSince1970: 20)
        let blocked = try first.markBlocked(
            identity: identity,
            assistantID: requested.assistantID,
            threadID: requested.threadID,
            reason: "probe-unknown")

        let relaunched = ChatCancellationDurabilityCoordinator(
            store: store,
            now: { clock.value })
        XCTAssertEqual(try relaunched.latestOutstanding(), blocked)
        XCTAssertEqual(blocked.identity.attempt, 2)
        XCTAssertEqual(blocked.identity.revision, 9)
        XCTAssertEqual(blocked.phase, .blocked)
    }

    func testResolveRequiresExactFourPartIdentity() throws {
        let store = InMemoryCancellationStateStore()
        let coordinator = ChatCancellationDurabilityCoordinator(store: store)
        let identity = ChatRunnerAttemptIdentity(
            runID: "run-exact",
            attempt: 1,
            instanceID: UUID(),
            revision: 4)
        _ = try coordinator.requestCancellation(
            identity: identity,
            assistantID: "assistant",
            threadID: nil)

        try coordinator.resolve(identity: ChatRunnerAttemptIdentity(
            runID: identity.runID,
            attempt: identity.attempt,
            instanceID: identity.instanceID,
            revision: identity.revision + 1))
        XCTAssertEqual(
            try coordinator.latestOutstanding()?.identity,
            identity)

        try coordinator.resolve(identity: identity)
        XCTAssertNil(try coordinator.latestOutstanding())
    }

    func testRetryTransitionIsExecutableAndDurable() throws {
        let store = InMemoryCancellationStateStore()
        let clock = MutableCancellationClock(
            now: Date(timeIntervalSince1970: 30))
        let coordinator = ChatCancellationDurabilityCoordinator(
            store: store,
            now: { clock.value })
        let identity = ChatRunnerAttemptIdentity(
            runID: "run-retry",
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
        let blocked = try coordinator.markBlocked(
            identity: identity,
            assistantID: "assistant-retry",
            threadID: "thread:retry",
            reason: "wrapper-live-child-unknown")

        clock.value = Date(timeIntervalSince1970: 31)
        let retrying = try coordinator.markRetrying(blocked)

        XCTAssertEqual(retrying.phase, .retrying)
        XCTAssertEqual(retrying.updatedAt, clock.value)
        XCTAssertEqual(try coordinator.latestOutstanding(), retrying)
    }

    func testPhysicalAttemptTrackerPublishesBridgeAttemptTwo() {
        var tracker = ChatCLIPhysicalAttemptTracker()
        tracker.begin(runID: "run-bridge")
        XCTAssertEqual(tracker.attempt, 1)

        tracker.observe(runID: "run-bridge", attempt: 2)
        XCTAssertEqual(tracker.attempt, 2)

        tracker.observe(runID: "different-run", attempt: 3)
        XCTAssertEqual(
            tracker.attempt,
            2,
            "another run cannot overwrite the active attempt identity")
    }

    func testHumanizerCollapsesANSIQuotaAndHidesUpstreamURL() {
        let raw = """
        \u{001B}[31mHTTP 402 Grok Build usage balance exhausted\u{001B}[0m
        https://api.x.ai/v1/chat/completions?internal=1
        HTTP 402 Grok Build usage balance exhausted
        """

        XCTAssertEqual(
            ChatRuntimeTextHumanizer.rawFallback(raw),
            "Grok 4.6 額度用盡，本回合未執行。")
    }

    func testHumanizerCollapsesRepeatedDeferredToolNoise() {
        let raw = """
        No matching deferred tools found
        ToolSearch: No matching deferred tools found
        No matching deferred tools found
        """

        XCTAssertEqual(
            ChatRuntimeTextHumanizer.projectedOutput(raw),
            ChatRuntimeTextProjection(
                text: "目前沒有可用的相符工具，本回合未執行工具操作。",
                collapsedDiagnostic: true,
                isBlocker: true))
    }

    func testHumanizerPreservesPermissionBlockerAuthorityForVisibleOutput() {
        let raw =
            "blocker_class=permission_denied authority_source=runner\nNo mutation authority."

        XCTAssertEqual(
            ChatRuntimeTextHumanizer.projectedOutput(raw),
            ChatRuntimeTextProjection(
                text: """
                    目前權限不足，本回合未執行。
                    blocker_class=permission_denied authority_source=runner
                    """,
                collapsedDiagnostic: true,
                isBlocker: true))
    }

    func testHumanizerClassifiesAuthorityToolBlockerAsBlockedPlainLanguage() {
        let raw =
            "blocker_class=tool_unavailable authority_source=runner; no matching bridged host tool was exposed."

        XCTAssertEqual(
            ChatRuntimeTextHumanizer.projectedOutput(raw),
            ChatRuntimeTextProjection(
                text: """
                    目前沒有可用的相符工具，本回合未執行工具操作。
                    blocker_class=tool_unavailable authority_source=runner
                    """,
                collapsedDiagnostic: true,
                isBlocker: true))
    }

    func testHumanizerDoesNotTreatQuotedHistoricalBlockerAsCurrentFailure() {
        let inline =
            "I am only quoting prior logs: blocker_class=auth happened earlier, but the current review succeeded."
        XCTAssertEqual(
            ChatRuntimeTextHumanizer.projectedOutput(inline),
            ChatRuntimeTextProjection(
                text: inline,
                collapsedDiagnostic: false))

        let fenced = """
        Prior diagnostic for discussion:
        ```text
        blocker_class=auth authority_source=runner
        ```
        The current review succeeded.
        """
        XCTAssertEqual(
            ChatRuntimeTextHumanizer.projectedOutput(fenced),
            ChatRuntimeTextProjection(
                text: fenced,
                collapsedDiagnostic: false))
    }

    func testSuccessfulProcessExitPreservesBlockedAssistantOutcome() {
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedStatus(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                currentStatus: "blocked"),
            "blocked")
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.liveWorkStatus(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                assistantStatus: "blocked"),
            "blocked|本輪受阻")
        XCTAssertNil(
            ChatAssistantTerminalStatusPolicy.resolvedStatus(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                currentStatus: "writing"))
    }

    @MainActor
    func testColdStartUnknownKeepsComposerLockedWithoutAssistantRow() throws {
        let fixture = try makeModelFixture(
            authority: RecordingCancellationAuthority(
                snapshot: .unknown(reason: "registry-unreadable")))
        let identity = ChatRunnerAttemptIdentity(
            runID: "run-cold-unknown",
            attempt: 1,
            instanceID: UUID(),
            revision: 7)
        try fixture.store.upsert(ChatDurableCancellationRecord(
            identity: identity,
            assistantID: "assistant-row-does-not-exist",
            threadID: "thread:missing",
            phase: .blocked,
            reason: "topology-unknown",
            updatedAt: Date()))

        let model = fixture.makeModel()
        model.prompt = "must remain locked"

        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.cancellationBlockedReason, "topology-unknown")
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.messages.contains {
            $0.id == "assistant-row-does-not-exist"
        })
    }

    @MainActor
    func testRepeatedStopRetriesAuthorityWhenAssistantRowIsMissing() throws {
        let authority = RecordingCancellationAuthority(
            snapshot: .unknown(reason: "registry-unreadable"),
            terminationResults: [
                .blocked(reason: "first-probe-unknown"),
                .requested,
            ])
        let fixture = try makeModelFixture(authority: authority)
        let identity = ChatRunnerAttemptIdentity(
            runID: "run-repeat-stop",
            attempt: 1,
            instanceID: UUID(),
            revision: 3)
        try fixture.store.upsert(ChatDurableCancellationRecord(
            identity: identity,
            assistantID: "missing-assistant",
            threadID: nil,
            phase: .blocked,
            reason: "cold-start-unknown",
            updatedAt: Date()))
        let model = fixture.makeModel()

        model.stop()
        model.stop()

        XCTAssertEqual(authority.requestedIdentities, [identity, identity])
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.canSend)
    }

    @MainActor
    func testGlobalLockSelectsNewestOfMultipleUnresolvedAttempts() throws {
        let authority = RecordingCancellationAuthority(
            snapshot: .unknown(reason: "registry-unreadable"),
            terminationResults: [.requested])
        let fixture = try makeModelFixture(authority: authority)
        let older = ChatRunnerAttemptIdentity(
            runID: "run-older-thread",
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
        let newer = ChatRunnerAttemptIdentity(
            runID: "run-newer-thread",
            attempt: 2,
            instanceID: UUID(),
            revision: 6)
        try fixture.store.upsert(ChatDurableCancellationRecord(
            identity: older,
            assistantID: "assistant-older",
            threadID: "thread:older",
            phase: .blocked,
            reason: "older-unknown",
            updatedAt: Date(timeIntervalSince1970: 100)))
        try fixture.store.upsert(ChatDurableCancellationRecord(
            identity: newer,
            assistantID: "assistant-newer",
            threadID: "thread:newer",
            phase: .blocked,
            reason: "newer-unknown",
            updatedAt: Date(timeIntervalSince1970: 200)))

        let model = fixture.makeModel()
        model.stop()

        XCTAssertEqual(authority.requestedIdentities, [newer])
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(try fixture.store.loadOutstanding().count, 2)
    }

    @MainActor
    func testExactAuthoritativeReclaimUnlocksColdStartComposer() throws {
        let identity = ChatRunnerAttemptIdentity(
            runID: "run-reclaimed",
            attempt: 1,
            instanceID: UUID(),
            revision: 8)
        let token = ChatRunnerReclaimToken(
            runID: identity.runID,
            attempt: identity.attempt,
            instanceID: identity.instanceID,
            revision: identity.revision)
        let fixture = try makeModelFixture(
            authority: RecordingCancellationAuthority(
                snapshot: .authoritative(
                    activeRunIDs: [],
                    reclaimTokens: [token])))
        try fixture.store.upsert(ChatDurableCancellationRecord(
            identity: identity,
            assistantID: "assistant-reclaimed",
            threadID: nil,
            phase: .blocked,
            reason: "prior-unknown",
            updatedAt: Date()))

        let model = fixture.makeModel()
        model.prompt = "next turn"

        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.cancellationBlockedReason)
        XCTAssertTrue(model.canSend)
        XCTAssertTrue(try fixture.store.loadOutstanding().isEmpty)
    }

    @MainActor
    private func makeModelFixture(
        authority: RecordingCancellationAuthority
    ) throws -> CancellationModelFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-cancellation-behavior-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument())
        return CancellationModelFixture(
            directory: directory,
            nativeStore: nativeStore,
            store: InMemoryCancellationStateStore(),
            authority: authority)
    }
}

private final class MutableCancellationClock: @unchecked Sendable {
    var value: Date

    init(now: Date) {
        self.value = now
    }
}

private final class InMemoryCancellationStateStore:
    ChatCancellationStateStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records: [ChatDurableCancellationRecord] = []

    func loadOutstanding() throws -> [ChatDurableCancellationRecord] {
        lock.withLock { records }
    }

    func upsert(_ record: ChatDurableCancellationRecord) throws {
        lock.withLock {
            records.removeAll { $0.identity == record.identity }
            records.append(record)
        }
    }

    func remove(identity: ChatRunnerAttemptIdentity) throws {
        lock.withLock {
            records.removeAll { $0.identity == identity }
        }
    }
}

private final class RecordingCancellationAuthority:
    ChatRunnerAuthorityDiscovering,
    @unchecked Sendable
{
    let snapshot: ChatRunnerAuthoritySnapshot
    private let lock = NSLock()
    private var terminationResults: [ChatRunnerTerminationRequestResult]
    private var identities: [ChatRunnerAttemptIdentity] = []

    init(
        snapshot: ChatRunnerAuthoritySnapshot,
        terminationResults: [ChatRunnerTerminationRequestResult] = []
    ) {
        self.snapshot = snapshot
        self.terminationResults = terminationResults
    }

    var requestedIdentities: [ChatRunnerAttemptIdentity] {
        lock.withLock { identities }
    }

    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        snapshot
    }

    func requestTermination(
        for identity: ChatRunnerAttemptIdentity
    ) -> ChatRunnerTerminationRequestResult {
        lock.withLock {
            identities.append(identity)
            guard !terminationResults.isEmpty else {
                return .unknown(reason: "no-scripted-result")
            }
            return terminationResults.removeFirst()
        }
    }
}

@MainActor
private struct CancellationModelFixture {
    let directory: URL
    let nativeStore: TatwoNativeChatStore
    let store: InMemoryCancellationStateStore
    let authority: RecordingCancellationAuthority

    func makeModel() -> ChatPageModel {
        ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatCancellationBlockedStateTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            runnerAuthorityDiscoverer: authority,
            cancellationStateStore: store)
    }
}
