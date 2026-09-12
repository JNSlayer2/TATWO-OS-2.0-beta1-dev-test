import Foundation
import XCTest

@testable import TatwoUltraworkMac
import TatwoUltraworkCore

final class ChatColdStartHydrationTests: XCTestCase {
    func testApplicationDidFinishLaunchingDoesNotResolveChatCompositionOrSweepLaunchctl()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("TatwoUltraworkMac")
                .appendingPathComponent("AppShell.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(source.range(
            of: "private func installMainMenuWithEditCommands",
            range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(body.contains("TatwoChatProcessCompositionRegistry"))
        XCTAssertFalse(body.contains("launchctl"))
        XCTAssertFalse(body.contains("sweep"))
        XCTAssertTrue(
            source.contains(
                "chatModel.scheduleColdStartHydrationAfterFirstFrame()"))
        XCTAssertTrue(
            source.contains("TatwoChatPostFirstFrameLaunchSweep.schedule"))
        let panelStart = try XCTUnwrap(source.range(
            of: "struct TatwoPanelView: View"))
        let hydratedStart = try XCTUnwrap(source.range(
            of: "private struct TatwoHydratedPanelView: View",
            range: panelStart.upperBound..<source.endIndex))
        let panelSource = String(
            source[panelStart.lowerBound..<hydratedStart.lowerBound])
        let panelInitStart = try XCTUnwrap(panelSource.range(of: "init("))
        let panelBodyStart = try XCTUnwrap(panelSource.range(
            of: "var body: some View",
            range: panelInitStart.upperBound..<panelSource.endIndex))
        let panelInit = String(
            panelSource[
                panelInitStart.lowerBound..<panelBodyStart.lowerBound])
        XCTAssertFalse(
            panelInit.contains("TatwoChatProcessCompositionRegistry"))
        let yieldRange = try XCTUnwrap(
            panelSource.range(of: "await Task.yield()"))
        let compositionRange = try XCTUnwrap(panelSource.range(
            of: "TatwoChatProcessCompositionRegistry.chatPageModel"))
        XCTAssertLessThan(
            yieldRange.lowerBound,
            compositionRange.lowerBound)
        XCTAssertEqual(
            source.components(
                separatedBy:
                    "TatwoChatPostFirstFrameLaunchSweep.schedule(")
                .count - 1,
            1)
        XCTAssertTrue(
            source.contains("if let sharedChatPageModel"))
    }

    func testUserFacingDocumentMutationEntrypointsRemainColdStartGated()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try ChatSourceFamily.read("ChatPageModel.swift")

        let userFacingEntrypoints = [
            "func checkGitHubRepoUpdates(for projectID: UUID)",
            "func createCLISession(in projectID: UUID, engine: TatwoNativeCLIEngine)",
            "func handoffThreadToCLISession(",
            "func handoffCLISessionToThread(",
            "func enableCodexThreadMirror()",
            "func persistSelectedDiscussionID(",
            "private func promoteGatewayContinuationIfEligible("
        ]
        for signature in userFacingEntrypoints {
            let start = try XCTUnwrap(source.range(of: signature))
            let inspectedEnd = source.index(
                start.lowerBound,
                offsetBy: min(
                    640,
                    source.distance(
                        from: start.lowerBound,
                        to: source.endIndex)))
            let entrypointPrefix = String(
                source[start.lowerBound..<inspectedEnd])
            XCTAssertTrue(
                entrypointPrefix.contains(
                    "guard allowColdStartDocumentMutation() else"),
                "\(signature) must fail closed before mutating document")
        }

        let projectionStart = try XCTUnwrap(source.range(
            of: "func replaceEphemeralTranscriptProjection("))
        let projectionEnd = source.index(
            projectionStart.lowerBound,
            offsetBy: min(
                480,
                source.distance(
                    from: projectionStart.lowerBound,
                    to: source.endIndex)))
        XCTAssertTrue(
            source[projectionStart.lowerBound..<projectionEnd].contains(
                "guard coldStartDocumentMutationAllowed else"))
    }

    @MainActor
    func testInitAndFirstFrameSchedulingDoNotTouchTenThousandRecordAuthorityOrDiskRecovery()
        async throws
    {
        let fixture = try makeFixture(name: "first-frame")
        let corruptJournal = Data("journal-must-remain-untouched".utf8)
        try corruptJournal.write(to: fixture.journalURL)

        let seedStore = TatwoNativeChatStore(
            url: fixture.nativeStoreURL,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try seedStore.save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(title: "migration sentinel")
        ]))
        let productionShapeStore = TatwoNativeChatStore(
            url: fixture.nativeStoreURL,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: true)
        let ledgerURL = try XCTUnwrap(productionShapeStore.unifiedLedger?.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))

        let authority = CountingColdStartAuthority(
            historicalRecordCount: 10_000,
            snapshot: .unknown(reason: "fixture-unknown"))
        let model = makeDeferredModel(
            fixture: fixture,
            nativeStore: productionShapeStore,
            authority: authority)
        model.prompt = "first-frame-safe-send"

        XCTAssertEqual(model.coldStartHydrationState, .notScheduled)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(authority.discoveryCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), corruptJournal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))

        model.scheduleColdStartHydrationAfterFirstFrame()
        model.scheduleColdStartHydrationAfterFirstFrame()

        // Scheduling is synchronous, but recovery starts only after MainActor
        // yields back to SwiftUI's initial render transaction.
        XCTAssertEqual(model.coldStartHydrationState, .scheduled)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(authority.discoveryCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.journalURL), corruptJournal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))

        try await waitForHydration(model)
        model.scheduleColdStartHydrationAfterFirstFrame()

        XCTAssertEqual(model.coldStartHydrationState, .completed)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(authority.discoveryCount, 1)
        XCTAssertEqual(authority.lastHistoricalChecksum, 9_999)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    @MainActor
    func testSendAvailabilityDiagnosticExplainsColdStartBlockAndReadyState()
        async throws
    {
        let fixture = try makeFixture(name: "send-availability-diagnostic")
        let store = TatwoNativeChatStore(
            url: fixture.nativeStoreURL,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try store.save(TatwoNativeChatStoreDocument())
        let model = makeDeferredModel(
            fixture: fixture,
            nativeStore: store,
            authority: CountingColdStartAuthority(
                historicalRecordCount: 0,
                snapshot: .authoritative(
                    activeRunIDs: [],
                    reclaimTokens: [])))
        model.prompt = "/plg diagnose native runtime"

        XCTAssertEqual(
            model.sendAvailabilityDiagnostic,
            "blocked · action=0 · cold-start=not-scheduled · prompt=present · cancellation=none · route=clear")

        model.send()

        XCTAssertEqual(
            model.sendAvailabilityDiagnostic,
            "blocked · action=1 · cold-start=not-scheduled · prompt=present · cancellation=none · route=clear")

        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForHydration(model)

        XCTAssertEqual(
            model.sendAvailabilityDiagnostic,
            "ready · action=1 · cold-start=completed · prompt=present · cancellation=none · route=clear")
    }

    @MainActor
    func testDelayedInitialStoreApplyBlocksMutationUntilDurablePayloadIsInstalled()
        async throws
    {
        let fixture = try makeFixture(name: "delayed-store")
        let store = TatwoNativeChatStore(
            url: fixture.nativeStoreURL,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try store.save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(title: "durable sentinel")
        ]))
        let barrier = DelayedColdStartStoreLoadBarrier()
        let authority = CountingColdStartAuthority(
            historicalRecordCount: 10_000,
            snapshot: .unknown(reason: "fixture-unknown"))
        let model = makeDeferredModel(
            fixture: fixture,
            nativeStore: store,
            authority: authority,
            storeLoadBarrier: {
                try await barrier.wait()
            })

        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitUntil {
            await barrier.entryCount == 1
        }

        XCTAssertEqual(model.coldStartHydrationState, .loadingStore)
        XCTAssertTrue(model.document.threads.isEmpty)
        model.newChat()
        model.submitCurrentChatTurn()
        XCTAssertTrue(model.document.threads.isEmpty)

        await barrier.release()
        try await waitForHydration(model)

        XCTAssertEqual(
            model.document.threads.map(\.title),
            ["durable sentinel"])
        model.newChat()
        XCTAssertEqual(
            Set(model.document.threads.map(\.title)),
            Set(["durable sentinel", "新聊天"]))
    }

    @MainActor
    func testFailedHydrationRetryStartsExactlyOneNewAttempt()
        async throws
    {
        let fixture = try makeFixture(name: "failed-retry")
        let barrier = FailFirstColdStartStoreLoadBarrier()
        let authority = CountingColdStartAuthority(
            historicalRecordCount: 10_000,
            snapshot: .unknown(reason: "fixture-unknown"))
        let model = makeDeferredModel(
            fixture: fixture,
            authority: authority,
            storeLoadBarrier: {
                try await barrier.wait()
            })

        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitUntil {
            if case .failed = model.coldStartHydrationState {
                return true
            }
            return false
        }

        XCTAssertTrue(model.canRetryColdStartHydration)
        XCTAssertNotNil(model.coldStartHydrationFailureMessage)
        let failedAttemptCount = await barrier.attemptCount
        XCTAssertEqual(failedAttemptCount, 1)
        XCTAssertEqual(authority.discoveryCount, 1)

        model.retryColdStartHydration()
        model.retryColdStartHydration()
        try await waitForHydration(model)

        let recoveredAttemptCount = await barrier.attemptCount
        XCTAssertEqual(recoveredAttemptCount, 2)
        XCTAssertEqual(authority.discoveryCount, 2)
    }

    @MainActor
    func testHydrationTimeoutFailsClosedAndRetryRecovers()
        async throws
    {
        let fixture = try makeFixture(name: "timeout-retry")
        let barrier = TimeoutFirstColdStartStoreLoadBarrier()
        let authority = CountingColdStartAuthority(
            historicalRecordCount: 10_000,
            snapshot: .unknown(reason: "fixture-unknown"))
        let model = makeDeferredModel(
            fixture: fixture,
            authority: authority,
            storeLoadBarrier: {
                try await barrier.wait()
            },
            // Five milliseconds made the retry assertion depend on scheduler
            // luck: attempt two still has to read and apply the durable store
            // after the deliberately blocked first attempt times out.
            hydrationTimeoutNanoseconds: 250_000_000)
        model.prompt = "must-remain-blocked"

        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitUntil {
            model.coldStartHydrationState == .timedOut
        }

        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.canRetryColdStartHydration)
        XCTAssertNotNil(model.coldStartHydrationFailureMessage)

        await barrier.releaseFirstAttempt()
        model.retryColdStartHydration()
        try await waitForHydration(model)

        let recoveredAttemptCount = await barrier.attemptCount
        XCTAssertEqual(recoveredAttemptCount, 2)
        XCTAssertEqual(authority.discoveryCount, 2)
        XCTAssertTrue(model.canSend)
    }

    @MainActor
    func testTimedOutAttemptCompletingAfterRetryCannotOverwriteSecondAttempt()
        async throws
    {
        let fixture = try makeFixture(name: "overlapping-timeout-retry")
        let store = TatwoNativeChatStore(
            url: fixture.nativeStoreURL,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try store.save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(title: "attempt-two-store")
        ]))
        let storeBarrier = DelayedColdStartStoreLoadBarrier()
        let identity = ChatRunnerAttemptIdentity(
            runID: "overlap-run",
            attempt: 7,
            instanceID: UUID(),
            revision: 19)
        let cancellationStore = ChatCancellationStateDiskStore(
            fileURL: fixture.cancellationURL)
        try cancellationStore.upsert(ChatDurableCancellationRecord(
            identity: identity,
            assistantID: "assistant-overlap",
            threadID: nil,
            phase: .blocked,
            reason: "overlap-authority-unknown",
            updatedAt: Date(timeIntervalSince1970: 300)))
        let staleReclaimToken = ChatRunnerReclaimToken(
            runID: identity.runID,
            attempt: identity.attempt,
            instanceID: identity.instanceID,
            revision: identity.revision)
        let authority = OverlappingColdStartAuthority(
            firstSnapshot: .authoritative(
                activeRunIDs: [],
                reclaimTokens: [staleReclaimToken]),
            laterSnapshot: .unknown(
                reason: "attempt-two-authority-unknown"))
        let model = makeDeferredModel(
            fixture: fixture,
            nativeStore: store,
            authority: authority,
            cancellationStore: cancellationStore,
            storeLoadBarrier: {
                try await storeBarrier.wait()
            },
            hydrationTimeoutNanoseconds: 500_000_000)

        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitUntil {
            authority.firstAttemptIsBlocked
        }
        try await waitUntil {
            model.coldStartHydrationState == .timedOut
        }

        model.retryColdStartHydration()
        try await waitUntil {
            authority.secondAttemptStarted
        }
        try await waitUntil {
            await storeBarrier.entryCount == 1
        }

        XCTAssertEqual(model.coldStartHydrationState, .loadingStore)
        XCTAssertTrue(model.document.threads.isEmpty)
        XCTAssertEqual(
            model.cancellationBlockedReason,
            "overlap-authority-unknown")
        XCTAssertEqual(authority.discoveryCount, 2)

        authority.releaseFirstAttempt()
        try await waitUntil {
            authority.firstAttemptDidReturn
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        // Attempt 1 returned a reclaim token after attempt 2 had already
        // installed unknown authority and entered its store load. Its stale
        // callback must not remove the lock, apply its payload, or falsely
        // complete hydration while attempt 2's store remains blocked.
        XCTAssertEqual(model.coldStartHydrationState, .loadingStore)
        XCTAssertTrue(model.document.threads.isEmpty)
        XCTAssertEqual(
            model.cancellationBlockedReason,
            "overlap-authority-unknown")
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(
            try cancellationStore.loadOutstanding().map(\.identity),
            [identity])

        await storeBarrier.release()
        try await waitForHydration(model)

        XCTAssertEqual(
            model.document.threads.map(\.title),
            ["attempt-two-store"])
        XCTAssertEqual(
            model.cancellationBlockedReason,
            "overlap-authority-unknown")
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(
            try cancellationStore.loadOutstanding().map(\.identity),
            [identity])
    }

    @MainActor
    func testUnknownAuthorityRetainsDurableCancellationLockFailClosed()
        async throws
    {
        let fixture = try makeFixture(name: "unknown-lock")
        let identity = ChatRunnerAttemptIdentity(
            runID: "unknown-run",
            attempt: 3,
            instanceID: UUID(),
            revision: 8)
        let cancellationStore = ChatCancellationStateDiskStore(
            fileURL: fixture.cancellationURL)
        try cancellationStore.upsert(ChatDurableCancellationRecord(
            identity: identity,
            assistantID: "assistant-unknown",
            threadID: nil,
            phase: .blocked,
            reason: "authority-unknown",
            updatedAt: Date(timeIntervalSince1970: 100)))
        let authority = CountingColdStartAuthority(
            historicalRecordCount: 10_000,
            snapshot: .unknown(reason: "launchctl-topology-unknown"))
        let model = makeDeferredModel(
            fixture: fixture,
            authority: authority,
            cancellationStore: cancellationStore)

        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForHydration(model)

        XCTAssertEqual(model.cancellationBlockedReason, "authority-unknown")
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(
            try cancellationStore.loadOutstanding().map(\.identity),
            [identity])
        XCTAssertEqual(authority.discoveryCount, 1)
    }

    @MainActor
    func testExactReclaimTokenResolvesDurableCancellationLock()
        async throws
    {
        let fixture = try makeFixture(name: "exact-reclaim")
        let identity = ChatRunnerAttemptIdentity(
            runID: "terminal-run",
            attempt: 4,
            instanceID: UUID(),
            revision: 12)
        let cancellationStore = ChatCancellationStateDiskStore(
            fileURL: fixture.cancellationURL)
        try cancellationStore.upsert(ChatDurableCancellationRecord(
            identity: identity,
            assistantID: "assistant-terminal",
            threadID: nil,
            phase: .retrying,
            reason: "awaiting-reclaim",
            updatedAt: Date(timeIntervalSince1970: 200)))
        let token = ChatRunnerReclaimToken(
            runID: identity.runID,
            attempt: identity.attempt,
            instanceID: identity.instanceID,
            revision: identity.revision)
        let authority = CountingColdStartAuthority(
            historicalRecordCount: 10_000,
            snapshot: .authoritative(
                activeRunIDs: [],
                reclaimTokens: [token]))
        let model = makeDeferredModel(
            fixture: fixture,
            authority: authority,
            cancellationStore: cancellationStore)

        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForHydration(model)

        XCTAssertNil(model.cancellationBlockedReason)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(try cancellationStore.loadOutstanding().isEmpty)
        XCTAssertEqual(authority.discoveryCount, 1)
    }

    @MainActor
    private func makeDeferredModel(
        fixture: ColdStartFixture,
        nativeStore: TatwoNativeChatStore? = nil,
        authority: any ChatRunnerAuthorityDiscovering,
        cancellationStore: ChatCancellationStateDiskStore? = nil,
        storeLoadBarrier:
            (@Sendable () async throws -> Void)? = nil,
        hydrationTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) -> ChatPageModel {
        ChatPageModel(
            environment: [
                "TATWO_ULTRAWORK_CHAT_COLD_START_HYDRATION": "deferred",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_STATE_DIR": fixture.stateRoot.path,
            ],
            store: nativeStore ?? TatwoNativeChatStore(
                url: fixture.nativeStoreURL,
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: fixture.journalURL),
            goalRunStore: TatwoGoalRunStore(
                directoryURL: fixture.stateRoot),
            runnerAuthorityDiscoverer: authority,
            cancellationStateStore: cancellationStore
                ?? ChatCancellationStateDiskStore(
                    fileURL: fixture.cancellationURL),
            coldStartInitialStoreLoadBarrier: storeLoadBarrier,
            coldStartHydrationTimeoutNanoseconds:
                hydrationTimeoutNanoseconds)
    }

    @MainActor
    private func waitForHydration(
        _ model: ChatPageModel
    ) async throws {
        for _ in 0..<1_000 {
            if model.coldStartHydrationState == .completed {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail(
            "cold-start hydration did not complete; state=\(model.coldStartHydrationState)")
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("cold-start condition did not become true")
    }

    private func makeFixture(name: String) throws -> ColdStartFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-cold-start-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return ColdStartFixture(
            root: root,
            nativeStoreURL: root.appendingPathComponent("native-chat.json"),
            journalURL: root.appendingPathComponent("journal.json"),
            cancellationURL: root.appendingPathComponent(
                "cancellation.json"),
            stateRoot: root.appendingPathComponent(
                "state",
                isDirectory: true))
    }
}

private final class OverlappingColdStartAuthority:
    ChatRunnerAuthorityRecording,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private let firstSnapshot: ChatRunnerAuthoritySnapshot
    private let laterSnapshot: ChatRunnerAuthoritySnapshot
    private var storedDiscoveryCount = 0
    private var shouldReleaseFirstAttempt = false
    private var storedFirstAttemptIsBlocked = false
    private var storedFirstAttemptDidReturn = false
    private var storedSecondAttemptStarted = false

    init(
        firstSnapshot: ChatRunnerAuthoritySnapshot,
        laterSnapshot: ChatRunnerAuthoritySnapshot
    ) {
        self.firstSnapshot = firstSnapshot
        self.laterSnapshot = laterSnapshot
    }

    var discoveryCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedDiscoveryCount
    }

    var firstAttemptIsBlocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return storedFirstAttemptIsBlocked
    }

    var firstAttemptDidReturn: Bool {
        condition.lock()
        defer { condition.unlock() }
        return storedFirstAttemptDidReturn
    }

    var secondAttemptStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return storedSecondAttemptStarted
    }

    func releaseFirstAttempt() {
        condition.lock()
        shouldReleaseFirstAttempt = true
        condition.broadcast()
        condition.unlock()
    }

    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        condition.lock()
        storedDiscoveryCount += 1
        let discovery = storedDiscoveryCount
        if discovery == 1 {
            storedFirstAttemptIsBlocked = true
            condition.broadcast()
            while !shouldReleaseFirstAttempt {
                condition.wait()
            }
            storedFirstAttemptDidReturn = true
            condition.broadcast()
            condition.unlock()
            return firstSnapshot
        }
        storedSecondAttemptStarted = true
        condition.broadcast()
        condition.unlock()
        return laterSnapshot
    }

    func claim(
        runID _: String,
        attempt _: UInt64
    ) throws -> ChatRunnerAttemptIdentity {
        throw ChatDurableRunnerAuthorityError.claimBlocked(
            reason: "cold-start-test-does-not-launch")
    }

    func attach(
        identity _: ChatRunnerAttemptIdentity,
        launch _: ChatRunnerLaunchIdentity
    ) throws {
        throw ChatDurableRunnerAuthorityError.claimBlocked(
            reason: "cold-start-test-does-not-launch")
    }

    func heartbeat(identity _: ChatRunnerAttemptIdentity) {}

    func recordAttemptTerminal(
        identity _: ChatRunnerAttemptIdentity,
        status _: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        .blocked(reason: "cold-start-test-does-not-launch")
    }

    func recordRunTerminal(
        identity _: ChatRunnerAttemptIdentity,
        status _: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        .blocked(reason: "cold-start-test-does-not-launch")
    }
}

private struct ColdStartFixture {
    let root: URL
    let nativeStoreURL: URL
    let journalURL: URL
    let cancellationURL: URL
    let stateRoot: URL
}

private actor DelayedColdStartStoreLoadBarrier {
    private(set) var entryCount = 0
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        entryCount += 1
        guard !isReleased else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FailFirstColdStartStoreLoadBarrier {
    private enum ExpectedFailure: Error {
        case firstAttempt
    }

    private(set) var attemptCount = 0

    func wait() async throws {
        attemptCount += 1
        if attemptCount == 1 {
            throw ExpectedFailure.firstAttempt
        }
    }
}

private actor TimeoutFirstColdStartStoreLoadBarrier {
    private(set) var attemptCount = 0
    private var firstAttemptContinuation:
        CheckedContinuation<Void, Error>?

    func wait() async throws {
        attemptCount += 1
        guard attemptCount == 1 else { return }
        try await withCheckedThrowingContinuation { continuation in
            firstAttemptContinuation = continuation
        }
    }

    func releaseFirstAttempt() {
        firstAttemptContinuation?.resume()
        firstAttemptContinuation = nil
    }
}

private final class CountingColdStartAuthority:
    ChatRunnerAuthorityRecording,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let historicalRecordCount: Int
    private let snapshot: ChatRunnerAuthoritySnapshot
    private var storedDiscoveryCount = 0
    private var storedHistoricalChecksum = -1

    init(
        historicalRecordCount: Int,
        snapshot: ChatRunnerAuthoritySnapshot
    ) {
        self.historicalRecordCount = historicalRecordCount
        self.snapshot = snapshot
    }

    var discoveryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDiscoveryCount
    }

    var lastHistoricalChecksum: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedHistoricalChecksum
    }

    func discoverRunnerAuthority() -> ChatRunnerAuthoritySnapshot {
        var checksum = -1
        for index in 0..<historicalRecordCount {
            checksum = index
        }
        lock.lock()
        storedDiscoveryCount += 1
        storedHistoricalChecksum = checksum
        lock.unlock()
        return snapshot
    }

    func claim(
        runID _: String,
        attempt _: UInt64
    ) throws -> ChatRunnerAttemptIdentity {
        throw ChatDurableRunnerAuthorityError.claimBlocked(
            reason: "cold-start-test-does-not-launch")
    }

    func attach(
        identity _: ChatRunnerAttemptIdentity,
        launch _: ChatRunnerLaunchIdentity
    ) throws {
        throw ChatDurableRunnerAuthorityError.claimBlocked(
            reason: "cold-start-test-does-not-launch")
    }

    func heartbeat(identity _: ChatRunnerAttemptIdentity) {}

    func recordAttemptTerminal(
        identity _: ChatRunnerAttemptIdentity,
        status _: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        .blocked(reason: "cold-start-test-does-not-launch")
    }

    func recordRunTerminal(
        identity _: ChatRunnerAttemptIdentity,
        status _: Int32
    ) -> ChatRunnerTerminalPersistenceResult {
        .blocked(reason: "cold-start-test-does-not-launch")
    }
}
