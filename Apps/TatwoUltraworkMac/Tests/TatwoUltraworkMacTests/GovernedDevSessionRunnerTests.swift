import CryptoKit
import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class GovernedDevSessionRunnerTests: XCTestCase {
    func testM4aSuccessCreatesDispatchWorktreePersistsEvidenceAndEmitsReceiptBeforeExit()
        async throws
    {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = ImmediateGovernedDevProcessRunner(
            stdout: codexSuccessStream,
            mutation: { worktree in
                try "m4a\n".write(
                    to: worktree.appendingPathComponent("README.md"),
                    atomically: true,
                    encoding: .utf8)
            })
        let recorder = GovernedDevEventRecorder()
        let runner = GovernedDevSessionRunner(
            journalDirectoryURL: fixture.journal,
            environment: executableEnvironment,
            bundleURL: fixture.root,
            isExecutableFile: executablePredicate,
            processRunnerFactory: { fake },
            now: { Date(timeIntervalSince1970: 1_787_100_000) })

        XCTAssertNotNil(runner.start(
            request: request(
                fixture: fixture,
                runID: "run-success",
                dispatchID: "abcdef12-rest",
                modelID: "gpt-5.6-sol",
                readOnly: false),
            onEvent: recorder.record))
        try await waitForExit(recorder)

        XCTAssertEqual(
            recorder.terminalKinds.suffix(2),
            ["receipt", "exit:0"],
            "TatwoNativeTerminalReceiptV1 must be visible before exit(0).")
        let invocation = try XCTUnwrap(fake.invocation)
        // 2026-08-21 WTFIX：worktree 名改為全 dispatch id 雜湊前 8 碼——
        // 真實 id 都以 "dispatch-" 開頭，舊 prefix(8) 讓所有派工同名相撞；
        // 舊 fixture "abcdef12-rest" 恰好遮住這個病。
        let shortID = GovernedDevSessionRunner.worktreeShortID(
            for: "abcdef12-rest")
        XCTAssertTrue(invocation.currentDirectoryURL.path.hasSuffix(
            "/.worktrees/dispatch-\(shortID)"))
        XCTAssertTrue(invocation.executableURL.path.hasSuffix(
            "/Contents/Helpers/TatwoSubscriptionRuntime"))
        XCTAssertEqual(
            invocation.currentDirectoryURL.path,
            try XCTUnwrap(recorder.outputRef).replacingOccurrences(
                of: "/journal/governed-dev-artifacts/run-success.json",
                with: "/repo/.worktrees/dispatch-\(shortID)"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: invocation.currentDirectoryURL
                .appendingPathComponent("README.md").path))

        let artifactURL = URL(fileURLWithPath: try XCTUnwrap(recorder.outputRef))
        let artifact = try decode(
            GovernedDevSessionArtifactV1.self,
            from: artifactURL)
        XCTAssertEqual(artifact.schema, "GovernedDevSessionArtifactV1")
        XCTAssertEqual(artifact.baseCommit, fixture.baseCommit)
        XCTAssertEqual(artifact.preRunDigest.headCommit, fixture.baseCommit)
        XCTAssertEqual(artifact.postRunDigest.headCommit, fixture.baseCommit)
        XCTAssertNotEqual(
            artifact.preRunDigest.statusPorcelainSHA256,
            artifact.postRunDigest.statusPorcelainSHA256)
        XCTAssertEqual(artifact.changedFiles, ["README.md"])
        XCTAssertTrue(artifact.diffStat.contains("README.md"))
        XCTAssertEqual(artifact.commandEventCount, 1)
        XCTAssertEqual(artifact.cliJSONEventCount, 3)
        XCTAssertTrue(artifact.outputRefDescription.contains(fixture.baseCommit))
        let journalRun = try XCTUnwrap(
            GovernedDevSessionRunJournal(rootDirectoryURL: fixture.journal)
                .load(runID: "run-success"))
        XCTAssertEqual(journalRun.preRunDigest, artifact.preRunDigest)
        XCTAssertEqual(journalRun.postRunDigest, artifact.postRunDigest)
        XCTAssertEqual(journalRun.diffStat, artifact.diffStat)
        XCTAssertEqual(journalRun.changedFiles, artifact.changedFiles)
        XCTAssertEqual(journalRun.cliJSONEventCount, artifact.cliJSONEventCount)
        XCTAssertEqual(journalRun.commandEventCount, artifact.commandEventCount)
        XCTAssertEqual(journalRun.toolEventCount, artifact.toolEventCount)

        let terminalURL = fixture.journal
            .appendingPathComponent("native-terminal-receipts/run-success.json")
        let terminal = try decode(TestTerminalReceipt.self, from: terminalURL)
        XCTAssertEqual(terminal.schema, "TatwoNativeTerminalReceiptV1")
        XCTAssertEqual(terminal.outputRef, artifactURL.path)
        XCTAssertEqual(terminal.receiptID, recorder.receiptID)
        XCTAssertEqual(
            terminal.assistantTextSHA256,
            GovernedDevSessionRunner.sha256(Data("DONE".utf8)))
        XCTAssertEqual(
            terminal.receiptID,
            expectedTerminalReceiptID(terminal))
    }

    func testM4aPermissionFlagsAreDerivedFromReadOnlyAndNeverEscalatePastAcceptEdits()
        async throws
    {
        let cases: [(String, Bool, String)] = [
            ("gpt-5.6-sol", true, "read-only"),
            ("gpt-5.6-sol", false, "workspace-write"),
            ("fable-5", true, "readonly-tools"),
            ("opus-5", false, "acceptEdits"),
        ]
        for (index, item) in cases.enumerated() {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let output = item.0.hasPrefix("gpt-")
                ? codexSuccessStream
                : claudeSuccessStream(
                    vendorModelID: item.0 == "fable-5"
                        ? "claude-fable-5" : "claude-opus-5")
            let fake = ImmediateGovernedDevProcessRunner(stdout: output)
            let recorder = GovernedDevEventRecorder()
            var environment = executableEnvironment
            let expectedHome: URL
            if item.0.hasPrefix("gpt-") {
                expectedHome = fixture.root.appendingPathComponent("codex-home")
                environment["TATWO_NATIVE_SUBSCRIPTION_HOME"] =
                    expectedHome.path
            } else {
                expectedHome = fixture.root.appendingPathComponent("claude-home")
                environment["TATWO_NATIVE_CLAUDE_SUBSCRIPTION_HOME"] =
                    expectedHome.path
            }
            let runner = GovernedDevSessionRunner(
                journalDirectoryURL: fixture.journal,
                environment: environment,
                bundleURL: fixture.root,
                isExecutableFile: executablePredicate,
                processRunnerFactory: { fake })
            _ = runner.start(
                request: request(
                    fixture: fixture,
                    runID: "flags-\(index)",
                    dispatchID: "0000000\(index)-dispatch",
                    modelID: item.0,
                    readOnly: item.1),
                onEvent: recorder.record)
            try await waitForExit(recorder)
            let arguments = try XCTUnwrap(fake.invocation).arguments
            XCTAssertFalse(arguments.contains("bypassPermissions"))
            XCTAssertFalse(arguments.contains("danger-full-access"))
            XCTAssertFalse(arguments.contains("plan"))
            switch item.2 {
            case "read-only", "workspace-write":
                XCTAssertTrue(containsPair(arguments, "-s", item.2))
            case "readonly-tools":
                XCTAssertTrue(containsPair(
                    arguments, "--tools", "Read,Grep,Glob"))
                XCTAssertFalse(arguments.contains("acceptEdits"))
            case "acceptEdits":
                XCTAssertTrue(containsPair(
                    arguments, "--permission-mode", "acceptEdits"))
            default:
                XCTFail("Unhandled fixture")
            }
            XCTAssertEqual(fake.invocation?.environment["HOME"], expectedHome.path)
            if item.0.hasPrefix("gpt-") {
                XCTAssertEqual(
                    fake.invocation?.environment["CODEX_HOME"],
                    expectedHome.path)
            } else {
                XCTAssertNil(
                    fake.invocation?.environment["CLAUDE_CONFIG_DIR"])
            }
            XCTAssertTrue(
                fake.invocation?.executableURL.path.hasSuffix(
                    item.0.hasPrefix("gpt-")
                        ? "/Contents/Helpers/TatwoSubscriptionRuntime"
                        : "/Contents/Helpers/TatwoClaudeSubscriptionRuntime")
                    == true)
            XCTAssertEqual(
                fake.invocation?.currentDirectoryURL.path,
                fixture.repo
                    .appendingPathComponent(
                        ".worktrees/dispatch-"
                            + GovernedDevSessionRunner.worktreeShortID(
                                for: "0000000\(index)-dispatch")).path)
        }
    }

    /// WTFIX 回歸：真實 dispatch id（同 slot、只差時間戳/序號）必須得到
    /// 不同 worktree 名；舊 prefix(8) 對兩者都回 "dispatch" 而相撞。
    func testRealisticDispatchIDsGetDistinctWorktreeNames() {
        let a = GovernedDevSessionRunner.worktreeShortID(
            for: "dispatch-binding-general-xxl-native-development-loops-executor-fable5-0-1787121061730-0")
        let b = GovernedDevSessionRunner.worktreeShortID(
            for: "dispatch-binding-general-xxl-native-development-loops-executor-fable5-0-1787273356446-3")
        XCTAssertEqual(a.count, 8)
        XCTAssertEqual(b.count, 8)
        XCTAssertNotEqual(a, b)
    }

    func testM4aClaudeDevelopmentFixturePassesExactFirstPartyAttestation()
        throws
    {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "claude-dev-stream",
            withExtension: "jsonl"))
        let data = try Data(contentsOf: fixtureURL)
        XCTAssertTrue(GovernedDevCLIEventAccumulator.validateClaudeStream(
            data,
            expectedVendorModelID: "claude-haiku-4-5"))
    }

    func testM4aClaudeFallbackModelMixFailsClosedWhileHaikuHelperIsAllowed()
        throws
    {
        let mixed = claudeResultData(modelUsage: [
            "claude-fable-5": usage("claude-fable-5", 80),
            "claude-opus-5": usage("claude-opus-5", 1),
        ])
        XCTAssertFalse(GovernedDevCLIEventAccumulator.validateClaudeStream(
            mixed,
            expectedVendorModelID: "claude-fable-5"))

        let allowedHelper = claudeResultData(modelUsage: [
            "claude-fable-5": usage("claude-fable-5", 80),
            "claude-haiku-4-5-20251001": usage("claude-haiku-4-5", 2),
        ])
        XCTAssertTrue(GovernedDevCLIEventAccumulator.validateClaudeStream(
            allowedHelper,
            expectedVendorModelID: "claude-fable-5"))
    }

    func testM4aCodexModelEchoMismatchFailsClosed()
        async throws
    {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = ImmediateGovernedDevProcessRunner(
            stdout: Data("""
                {"type":"thread.started","model":"gpt-5.5"}
                {"type":"item.completed","item":{"type":"agent_message","text":"DONE"}}
                """.utf8) + Data([0x0A]))
        let recorder = GovernedDevEventRecorder()
        let runner = GovernedDevSessionRunner(
            journalDirectoryURL: fixture.journal,
            environment: executableEnvironment,
            bundleURL: fixture.root,
            isExecutableFile: executablePredicate,
            processRunnerFactory: { fake })

        _ = runner.start(
            request: request(
                fixture: fixture,
                runID: "codex-attestation-mismatch",
                dispatchID: "badc0dex-dispatch",
                modelID: "gpt-5.6-sol",
                readOnly: true),
            onEvent: recorder.record)
        try await waitForExit(recorder)

        XCTAssertTrue(recorder.failures.contains(where: {
            $0.contains("governed_dev_codex_attestation_mismatch")
        }))
        XCTAssertEqual(recorder.terminalKinds.last, "exit:1")
        XCTAssertNil(recorder.receiptID)
    }

    func testM4aProcessRunnerStopTerminatesWholeProcessGroup()
        async throws
    {
        let runner = GovernedDevProcessRunner()
        let invocation = GovernedDevProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3 & wait"],
            standardInput: nil,
            environment: executableEnvironment,
            currentDirectoryURL: FileManager.default.temporaryDirectory)
        let startedAt = Date()
        let task = Task {
            try await runner.run(invocation: invocation) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        runner.stop()
        _ = try await task.value

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            2.5,
            "Stopping must terminate the CLI process group, not only its parent.")
    }

    func testM4aGrokDispatchFailsWithExplicitUnverifiedAttestationReason()
        async throws
    {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = ImmediateGovernedDevProcessRunner(stdout: Data())
        let recorder = GovernedDevEventRecorder()
        let runner = GovernedDevSessionRunner(
            journalDirectoryURL: fixture.journal,
            environment: executableEnvironment,
            bundleURL: fixture.root,
            isExecutableFile: { _ in true },
            processRunnerFactory: { fake })
        _ = runner.start(
            request: request(
                fixture: fixture,
                runID: "grok-blocked",
                dispatchID: "feedface-dispatch",
                modelID: "grok-build",
                readOnly: false),
            onEvent: recorder.record)
        try await waitForExit(recorder)

        XCTAssertTrue(recorder.failures.contains(where: {
            $0.contains("grok_dev_attestation_unverified")
        }))
        XCTAssertEqual(recorder.terminalKinds.last, "exit:1")
        XCTAssertNil(fake.invocation)
    }

    func testM4aTimeoutStopsProcessAndPersistsTimedOutJournalState()
        async throws
    {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fake = BlockingGovernedDevProcessRunner()
        let recorder = GovernedDevEventRecorder()
        let runner = GovernedDevSessionRunner(
            journalDirectoryURL: fixture.journal,
            runtimeGovernor: TatwoRuntimeGovernor(tier: .ram16GB),
            maximumRunDuration: 0.05,
            environment: executableEnvironment,
            bundleURL: fixture.root,
            isExecutableFile: executablePredicate,
            processRunnerFactory: { fake })
        _ = runner.start(
            request: request(
                fixture: fixture,
                runID: "timeout",
                dispatchID: "12345678-timeout",
                modelID: "gpt-5.6-sol",
                readOnly: true),
            onEvent: recorder.record)
        try await waitForExit(recorder)

        XCTAssertGreaterThanOrEqual(fake.stopCount, 1)
        let journal = GovernedDevSessionRunJournal(
            rootDirectoryURL: fixture.journal)
        XCTAssertEqual(try journal.load(runID: "timeout")?.state, .timedOut)
        XCTAssertTrue(recorder.failures.contains(where: {
            $0.contains("timed out")
        }))
    }

    func testM4aRegistersGovernorAsXXLGoalSpawnUntilTermination()
        async throws
    {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let governor = TatwoRuntimeGovernor(tier: .ram16GB)
        let fake = BlockingGovernedDevProcessRunner()
        let recorder = GovernedDevEventRecorder()
        let runner = GovernedDevSessionRunner(
            journalDirectoryURL: fixture.journal,
            runtimeGovernor: governor,
            maximumRunDuration: 30,
            environment: executableEnvironment,
            bundleURL: fixture.root,
            isExecutableFile: executablePredicate,
            processRunnerFactory: { fake })
        _ = runner.start(
            request: request(
                fixture: fixture,
                runID: "governor",
                dispatchID: "87654321-governor",
                modelID: "gpt-5.6-sol",
                readOnly: true),
            onEvent: recorder.record)

        try await waitUntil {
            governor.snapshot().activeLeases.contains(where: {
                $0.kind == .xxlGoalSpawn
            })
        }
        runner.terminate()
        try await waitForExit(recorder)
        try await waitUntil { governor.snapshot().activeLeases.isEmpty }
        XCTAssertGreaterThanOrEqual(fake.stopCount, 1)
    }

    func testM4aJournalDecodesOlderSparseShapeAndReconcilesInterruptedRun()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4a-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = GovernedDevSessionRunJournal(rootDirectoryURL: root)
        try FileManager.default.createDirectory(
            at: journal.directoryURL,
            withIntermediateDirectories: true)
        try Data(#"{"runID":"old-run","state":"running"}"#.utf8)
            .write(to: journal.directoryURL.appendingPathComponent("old-run.json"))

        XCTAssertEqual(try journal.reconcileInterruptedRuns(), 1)
        let reloaded = try XCTUnwrap(journal.load(runID: "old-run"))
        XCTAssertEqual(reloaded.state, .interrupted)
        XCTAssertTrue(reloaded.readOnly)
    }

    private var executableEnvironment: [String: String] {
        [
            "PATH": "/usr/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
        ]
    }

    private var executablePredicate: @Sendable (String) -> Bool {
        { path in
            path.hasSuffix("/TatwoSubscriptionRuntime")
                || path.hasSuffix("/TatwoClaudeSubscriptionRuntime")
                || path.hasSuffix("/codex")
                || path.hasSuffix("/claude")
        }
    }

    private var codexSuccessStream: Data {
        Data("""
        {"type":"thread.started","model":"gpt-5.6-sol"}
        {"type":"item.started","item":{"type":"command_execution","name":"exec_command"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"DONE"}}
        """.utf8) + Data([0x0A])
    }

    private func claudeSuccessStream(vendorModelID: String) -> Data {
        claudeResultData(modelUsage: [
            vendorModelID: usage(vendorModelID, 64),
        ])
    }

    private func usage(_ canonicalModel: String, _ outputTokens: Int) -> [String: Any] {
        [
            "canonicalModel": canonicalModel,
            "provider": "firstParty",
            "outputTokens": outputTokens,
        ]
    }

    private func claudeResultData(modelUsage: [String: Any]) -> Data {
        let object: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": "DONE",
            "modelUsage": modelUsage,
        ]
        var data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func request(
        fixture: RepositoryFixture,
        runID: String,
        dispatchID: String,
        modelID: String,
        readOnly: Bool
    ) -> ChatNativeAgentRunRequest {
        ChatNativeAgentRunRequest(
            runID: runID,
            dispatchID: dispatchID,
            prompt: "Implement and verify the bounded dispatch.",
            modelID: modelID,
            effort: modelID == "fable-5" ? "medium" : "high",
            contractID: "contract-m4a",
            workspaceRoot: fixture.repo.path,
            readOnly: readOnly,
            permissionPreset: .fullAccess)
    }

    private func makeRepository() throws -> RepositoryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-m4a-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        let journal = root.appendingPathComponent("journal")
        try FileManager.default.createDirectory(
            at: repo,
            withIntermediateDirectories: true)
        try git(["init", "-q"], at: repo)
        try "base\n".write(
            to: repo.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8)
        try git(["add", "README.md"], at: repo)
        try git([
            "-c", "user.name=TATWO Test",
            "-c", "user.email=tatwo@example.invalid",
            "commit", "-q", "-m", "base",
        ], at: repo)
        let base = try gitOutput(["rev-parse", "HEAD"], at: repo)
        return RepositoryFixture(
            root: root,
            repo: repo,
            journal: journal,
            baseCommit: base)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        _ = try gitOutput(arguments, at: directory)
    }

    private func gitOutput(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GovernedDevSessionRunnerTests.git",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(decoding: data, as: UTF8.self),
                ])
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForExit(
        _ recorder: GovernedDevEventRecorder
    ) async throws {
        try await waitUntil { recorder.hasExit }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous M4a evidence")
    }

    private func containsPair(
        _ arguments: [String],
        _ first: String,
        _ second: String
    ) -> Bool {
        arguments.indices.contains { index in
            arguments[index] == first
                && arguments.indices.contains(index + 1)
                && arguments[index + 1] == second
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func expectedTerminalReceiptID(
        _ receipt: TestTerminalReceipt
    ) -> String {
        let canonical = [
            receipt.schema,
            receipt.runID,
            receipt.dispatchID ?? "",
            receipt.modelID,
            receipt.effort,
            receipt.contractID,
            String(receipt.eventCount),
            receipt.assistantTextSHA256 ?? "",
            String(Int64(receipt.completedAt.timeIntervalSince1970)),
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "native-terminal:\(digest)"
    }
}

private struct RepositoryFixture {
    let root: URL
    let repo: URL
    let journal: URL
    let baseCommit: String
}

private struct TestTerminalReceipt: Decodable {
    let schema: String
    let receiptID: String
    let runID: String
    let dispatchID: String?
    let modelID: String
    let effort: String
    let contractID: String
    let eventCount: Int
    let assistantTextSHA256: String?
    let completedAt: Date
    let outputRef: String
}

private final class GovernedDevEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var failureStorage: [String] = []
    private var receiptIDStorage: String?
    private var outputRefStorage: String?

    var hasExit: Bool {
        lock.withLock { events.contains(where: { $0.hasPrefix("exit:") }) }
    }

    var terminalKinds: [String] { lock.withLock { events } }
    var failures: [String] { lock.withLock { failureStorage } }
    var receiptID: String? { lock.withLock { receiptIDStorage } }
    var outputRef: String? { lock.withLock { outputRefStorage } }

    func record(_ event: ChatCLIEvent) {
        lock.withLock {
            switch event {
            case .nativeTerminalReceipt(let receiptID, let outputRef):
                receiptIDStorage = receiptID
                outputRefStorage = outputRef
                events.append("receipt")
            case .exit(let status):
                events.append("exit:\(status)")
            case .runtimeFailure(let failure):
                failureStorage.append(failure)
            default:
                break
            }
        }
    }
}

private final class ImmediateGovernedDevProcessRunner:
    GovernedDevProcessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let stdout: Data
    private let stderr: Data
    private let mutation: @Sendable (URL) throws -> Void
    private var invocationStorage: GovernedDevProcessInvocation?

    init(
        stdout: Data,
        stderr: Data = Data(),
        mutation: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.mutation = mutation
    }

    var invocation: GovernedDevProcessInvocation? {
        lock.withLock { invocationStorage }
    }

    func run(
        invocation: GovernedDevProcessInvocation,
        onOutput: @escaping @Sendable (
            GovernedDevProcessInvocation.OutputStream,
            Data
        ) -> Void
    ) async throws -> GovernedDevProcessResult {
        lock.withLock { invocationStorage = invocation }
        try mutation(invocation.currentDirectoryURL)
        if !stdout.isEmpty { onOutput(.stdout, stdout) }
        if !stderr.isEmpty { onOutput(.stderr, stderr) }
        return GovernedDevProcessResult(
            exitCode: 0,
            stdout: stdout,
            stderr: stderr)
    }

    func stop() {}
}

private final class BlockingGovernedDevProcessRunner:
    GovernedDevProcessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var stops = 0

    var stopCount: Int { lock.withLock { stops } }

    func run(
        invocation _: GovernedDevProcessInvocation,
        onOutput _: @escaping @Sendable (
            GovernedDevProcessInvocation.OutputStream,
            Data
        ) -> Void
    ) async throws -> GovernedDevProcessResult {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return GovernedDevProcessResult(
            exitCode: 0,
            stdout: Data(),
            stderr: Data())
    }

    func stop() {
        lock.withLock { stops += 1 }
    }
}
