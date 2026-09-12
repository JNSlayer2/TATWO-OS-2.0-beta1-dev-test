import Foundation
import XCTest

@testable import TatwoUltraworkMac
import TatwoUltraworkCore

/// Regression cover for the staging-60 Computer Use blocker: every Sky
/// `get_app_state` timed out after ~17s while Finder AX stayed healthy, and
/// 100% of main-thread samples were parked in
/// `TatwoPanelView.body` -> `TatwoChatProcessComposition.makeChatPageModel`
/// -> `ChatPageModel.init` -> `ChatCLIProcessRunner.init` ->
/// `FileManager.createDirectory` -> `mkdirat`, against an isolated runtime
/// root on an external volume.
///
/// Runtime-root creation must therefore never happen synchronously during
/// model/runner composition, while still being guaranteed, fail-closed, and
/// idempotent by the time a turn actually needs it.
final class ChatRuntimeRootLazyPreparationTests: XCTestCase {
    // MARK: - No synchronous filesystem I/O at composition time

    func testRunnerInitDoesNotPrepareOrCreateTheRuntimeRoot() {
        let root = uniqueFixtureRoot("init-no-mkdir")
        let preparer = CountingRuntimeRootPreparer()

        let runner = ChatCLIProcessRunner(
            runtimeRootURL: root,
            runtimeSweepGate: ChatCLIRuntimeSweepGate(debounceInterval: 600),
            runtimeSweepLauncher: { _, _, completion in completion() },
            runtimeRootPreparer: { try preparer.prepare($0) })

        XCTAssertEqual(preparer.callCount, 0)
        XCTAssertFalse(runner.runtimeRootIsPrepared)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "ChatCLIProcessRunner.init must not issue mkdir on the calling "
                + "thread; it can be MainActor inside SwiftUI body composition.")
    }

    func testRunnerInitWithTheRealFileManagerStillCreatesNothing() {
        let root = uniqueFixtureRoot("init-real-filemanager")

        _ = ChatCLIProcessRunner(
            runtimeRootURL: root,
            runtimeSweepGate: ChatCLIRuntimeSweepGate(debounceInterval: 600),
            runtimeSweepLauncher: { _, _, completion in completion() })

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testChatPageModelCompositionDoesNotCreateTheChatRuntimeRoot() throws {
        let fixture = uniqueFixtureRoot("model-composition")
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: true)
        // Model the staging shape: an injected, isolated runtime root that is
        // *not* the production root and does not exist yet.
        let runtimeRoot = fixture
            .appendingPathComponent("runtime-60", isDirectory: true)
            .appendingPathComponent("chat-cli-runtime-v1", isDirectory: true)

        let model = ChatPageModel(
            environment: [
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_STATE_DIR":
                    fixture.appendingPathComponent("state").path,
            ],
            store: TatwoNativeChatStore(
                url: fixture.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            chatRuntimeRootURL: runtimeRoot)

        XCTAssertEqual(
            model.runner.runtimeRootURL,
            runtimeRoot.standardizedFileURL)
        XCTAssertFalse(model.runner.runtimeRootIsPrepared)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtimeRoot.path),
            "Composing ChatPageModel on MainActor must not block on mkdirat "
                + "against the (possibly external-volume) runtime root.")
    }

    @MainActor
    func testPerSessionRunnerCompositionDoesNotCreateItsSubRoot() throws {
        let fixture = uniqueFixtureRoot("per-session-runner")
        try FileManager.default.createDirectory(
            at: fixture,
            withIntermediateDirectories: true)
        let runtimeRoot = fixture
            .appendingPathComponent("chat-cli-runtime-v1", isDirectory: true)
        let model = ChatPageModel(
            environment: [
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_STATE_DIR":
                    fixture.appendingPathComponent("state").path,
            ],
            store: TatwoNativeChatStore(
                url: fixture.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            chatRuntimeRootURL: runtimeRoot)

        // The first call hands back the shared runner; a second session key
        // builds an extra runner with its own sub-root. Neither may mkdir.
        _ = model.processRunnerForTurnStart()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtimeRoot.path))
    }

    // MARK: - Preparation still happens before the runtime actually uses it

    func testFirstTurnPreparesTheRuntimeRootBeforeStreamArtifactsAreWritten()
        async throws
    {
        let root = uniqueFixtureRoot("first-turn-prepares")
        let preparer = CountingRuntimeRootPreparer()
        let events = LazyPreparationEventRecorder()
        let runner = ChatCLIProcessRunner(
            runtimeRootURL: root,
            runtimeSweepGate: ChatCLIRuntimeSweepGate(debounceInterval: 600),
            runtimeSweepLauncher: { _, _, completion in completion() },
            runtimeRootPreparer: { try preparer.prepare($0) })

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        runner.start(
            command: fixtureCommand(),
            runID: "lazy-prepare-run",
            onEvent: { event in
                Task { await events.record(event) }
            })

        try await waitUntil { await events.isTerminal }

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(runner.runtimeRootIsPrepared)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "stdout-lazy-prepare-run.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "spawn-lazy-prepare-run.jsonl").path))
        // Preparation is cached: the turn's several artifact writers must not
        // re-issue mkdir once the root is known to exist.
        XCTAssertEqual(preparer.callCount, 1)
        let failures = await events.failures
        XCTAssertTrue(failures.isEmpty, "unexpected failures: \(failures)")
    }

    // MARK: - Fail-closed

    func testPreparationFailureThrowsAndIsNeverCachedAsSuccess() throws {
        let root = uniqueFixtureRoot("prepare-fail-closed")
        let preparer = CountingRuntimeRootPreparer(failure: fixtureFailure())
        let runner = ChatCLIProcessRunner(
            runtimeRootURL: root,
            runtimeSweepGate: ChatCLIRuntimeSweepGate(debounceInterval: 600),
            runtimeSweepLauncher: { _, _, completion in completion() },
            runtimeRootPreparer: { try preparer.prepare($0) })

        XCTAssertThrowsError(try runner.prepareRuntimeRootIfNeeded())
        XCTAssertFalse(runner.runtimeRootIsPrepared)
        XCTAssertThrowsError(try runner.prepareRuntimeRootIfNeeded())
        XCTAssertEqual(preparer.callCount, 2, "failures must not be cached")

        // A transient volume stall must not permanently poison the runner.
        preparer.failure = nil
        XCTAssertNoThrow(try runner.prepareRuntimeRootIfNeeded())
        XCTAssertTrue(runner.runtimeRootIsPrepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testTurnFailsClosedWithoutSpawningWhenRuntimeRootCannotBePrepared()
        async throws
    {
        let root = uniqueFixtureRoot("turn-fail-closed")
        let preparer = CountingRuntimeRootPreparer(failure: fixtureFailure())
        let events = LazyPreparationEventRecorder()
        let runner = ChatCLIProcessRunner(
            runtimeRootURL: root,
            runtimeSweepGate: ChatCLIRuntimeSweepGate(debounceInterval: 600),
            runtimeSweepLauncher: { _, _, completion in completion() },
            runtimeRootPreparer: { try preparer.prepare($0) })

        runner.start(
            command: fixtureCommand(),
            runID: "fail-closed-run",
            onEvent: { event in
                Task { await events.record(event) }
            })

        try await waitUntil { await events.isTerminal }

        let failures = await events.failures
        XCTAssertEqual(failures.count, 1)
        let message = try XCTUnwrap(failures.first)
        XCTAssertTrue(
            message.contains("Unable to prepare model runtime directory"),
            "failure must name the real root cause, got: \(message)")
        XCTAssertTrue(message.contains(root.standardizedFileURL.path))
        XCTAssertFalse(runner.runtimeRootIsPrepared)
        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(runner.diagnosticsSnapshot.hasProcessReference)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "stdout-fail-closed-run.jsonl").path),
            "no stream artifact may be created when preparation failed")
    }

    // MARK: - Idempotent / concurrency safe

    func testConcurrentPreparationIssuesExactlyOneCreationAndIsIdempotent()
        async throws
    {
        let root = uniqueFixtureRoot("concurrent-prepare")
        let preparer = CountingRuntimeRootPreparer()
        let runner = ChatCLIProcessRunner(
            runtimeRootURL: root,
            runtimeSweepGate: ChatCLIRuntimeSweepGate(debounceInterval: 600),
            runtimeSweepLauncher: { _, _, completion in completion() },
            runtimeRootPreparer: { try preparer.prepare($0) })

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    (try? runner.prepareRuntimeRootIfNeeded()) != nil
                }
            }
            for await succeeded in group {
                XCTAssertTrue(succeeded)
            }
        }

        XCTAssertEqual(preparer.callCount, 1)
        XCTAssertTrue(runner.runtimeRootIsPrepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(preparer.maxConcurrentCalls, 1)

        // Repeated sequential preparation stays a no-op.
        for _ in 0..<10 {
            XCTAssertNoThrow(try runner.prepareRuntimeRootIfNeeded())
        }
        XCTAssertEqual(preparer.callCount, 1)

        // A forced re-preparation (stale cache recovery) still works.
        XCTAssertNoThrow(try runner.prepareRuntimeRootIfNeeded(force: true))
        XCTAssertEqual(preparer.callCount, 2)
    }

    // MARK: - Source contract

    func testRunnerInitBodyContainsNoFilesystemCreationCall() throws {
        let source = try ChatSourceFamily.read("ChatRuntime.swift")
        let start = try XCTUnwrap(source.range(
            of: "self.watchdogPolicy = watchdogPolicy"))
        let end = try XCTUnwrap(source.range(
            of: "scheduleRuntimeMaintenance(reason: \"runner-init\")",
            range: start.upperBound..<source.endIndex))
        let initBody = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(initBody.contains("createDirectory"))
        XCTAssertFalse(initBody.contains("FileManager.default"))
        XCTAssertFalse(initBody.contains("contentsOfDirectory"))
        XCTAssertFalse(initBody.contains(".write(to:"))
        // Durable authority discovery reads the on-disk registry under the
        // same state root; it must stay off the composing (Main) thread too.
        let scheduleStart = try XCTUnwrap(source.range(
            of: "private func scheduleRuntimeMaintenance(reason: String) {"))
        let scheduleEnd = try XCTUnwrap(source.range(
            of: "private static func launchStaleSweep(",
            range: scheduleStart.upperBound..<source.endIndex))
        let scheduleBody = String(
            source[scheduleStart.lowerBound..<scheduleEnd.lowerBound])
        let asyncRange = try XCTUnwrap(scheduleBody.range(
            of: "DispatchQueue.global(qos: .utility).async"))
        let discoverRange = try XCTUnwrap(scheduleBody.range(
            of: "discoverRunnerAuthority()"))
        XCTAssertLessThan(asyncRange.lowerBound, discoverRange.lowerBound)
    }

    // MARK: - Helpers

    private func fixtureFailure() -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteVolumeReadOnlyError,
            userInfo: [
                NSLocalizedDescriptionKey: "fixture-runtime-root-unavailable"
            ])
    }

    private func fixtureCommand() -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/bin/sh",
            arguments: ["-c", "exit 0"],
            workingDirectory: FileManager.default.temporaryDirectory,
            expectsJSON: false,
            capturesSessionID: false,
            standardInputFromDevNull: true,
            requiresForegroundScheduling: false,
            runtimeAdapter: .gatewayDirect,
            commandMode: .chat)
    }

    private func uniqueFixtureRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-runtime-lazy-prep-tests",
                isDirectory: true)
            .appendingPathComponent(
                "\(label)-\(UUID().uuidString)",
                isDirectory: true)
    }

    private func waitUntil(
        _ condition: @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<600 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for runner terminal event")
    }
}

private final class CountingRuntimeRootPreparer: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0
    private var storedInFlight = 0
    private var storedMaxConcurrentCalls = 0
    private var storedFailure: Error?

    init(failure: Error? = nil) {
        self.storedFailure = failure
    }

    var failure: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedFailure
        }
        set {
            lock.lock()
            storedFailure = newValue
            lock.unlock()
        }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    var maxConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMaxConcurrentCalls
    }

    func prepare(_ root: URL) throws {
        lock.lock()
        storedCallCount += 1
        storedInFlight += 1
        storedMaxConcurrentCalls = max(storedMaxConcurrentCalls, storedInFlight)
        let failure = storedFailure
        lock.unlock()
        defer {
            lock.lock()
            storedInFlight -= 1
            lock.unlock()
        }
        if let failure { throw failure }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
    }
}

private actor LazyPreparationEventRecorder {
    private(set) var failures: [String] = []
    private(set) var isTerminal = false

    func record(_ event: ChatCLIEvent) {
        switch event {
        case .failure(let message):
            failures.append(message)
            isTerminal = true
        case .exit, .runtimeFailure:
            isTerminal = true
        default:
            break
        }
    }
}
