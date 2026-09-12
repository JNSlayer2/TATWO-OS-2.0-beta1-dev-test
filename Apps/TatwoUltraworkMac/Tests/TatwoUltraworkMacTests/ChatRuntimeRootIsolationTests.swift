import XCTest

@testable import TatwoUltraworkMac

final class ChatRuntimeRootIsolationTests: XCTestCase {
    func testLaunchSweepUsesTheResolvedProcessCompositionRuntimeRoot() {
        let base = uniqueFixtureRoot("composition-sweep")
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: "com.tatwo.ultrawork.staging",
            infoDictionary: [
                TatwoChatProcessCompositionResolver.stagingMarkerInfoKey:
                    "staging-service|staging-account",
            ],
            bundleURL: base.appendingPathComponent(
                "Tatwo Ultrawork Staging.app",
                isDirectory: true),
            applicationSupportBase: base,
            processID: 808)

        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertEqual(
            TatwoChatLaunchSweepRootResolver.runtimeRoot(
                for: composition),
            composition.storage.chatRuntimeRootURL)
        XCTAssertFalse(
            composition.storage.chatRuntimeRootURL.path.contains(
                "/tatwo-ultrawork-chat-cli/"))
    }

    func testDefaultRootFactorySeparatesProductionStagingAndTestProcesses() {
        let temp = uniqueFixtureRoot("default-root-factory")
        let production = ChatCLIRuntimeRootFactory.defaultRoot(
            temporaryDirectory: temp,
            environment: [:],
            bundleIdentifier: "com.tatwo.ultrawork",
            executableURL: URL(fileURLWithPath:
                "/Applications/Tatwo Ultrawork.app/Contents/MacOS/Tatwo Ultrawork"),
            processID: 100)
        let staging = ChatCLIRuntimeRootFactory.defaultRoot(
            temporaryDirectory: temp,
            environment: [:],
            bundleIdentifier: "com.tatwo.ultrawork",
            executableURL: URL(fileURLWithPath:
                "/tmp/tatwo2-fixture/staging/Tatwo Ultrawork.app/Contents/MacOS/Tatwo Ultrawork"),
            processID: 100)
        let testA = ChatCLIRuntimeRootFactory.defaultRoot(
            temporaryDirectory: temp,
            environment: ["XCTestConfigurationFilePath": "/tmp/a.xctestconfiguration"],
            bundleIdentifier: "com.tatwo.ultrawork.tests",
            executableURL: URL(fileURLWithPath: "/tmp/TatwoUltraworkMacTests"),
            processID: 200)
        let testB = ChatCLIRuntimeRootFactory.defaultRoot(
            temporaryDirectory: temp,
            environment: ["XCTestConfigurationFilePath": "/tmp/b.xctestconfiguration"],
            bundleIdentifier: "com.tatwo.ultrawork.tests",
            executableURL: URL(fileURLWithPath: "/tmp/TatwoUltraworkMacTests"),
            processID: 201)

        XCTAssertNotEqual(production, staging)
        XCTAssertNotEqual(testA, testB)
        for root in [production, staging, testA, testB] {
            XCTAssertTrue(root.path.contains(
                "/tatwo-ultrawork-chat-cli/instances/"))
            XCTAssertNotEqual(
                root,
                temp.appendingPathComponent(
                    "tatwo-ultrawork-chat-cli",
                    isDirectory: true))
        }
    }

    func testTenThousandLegacyReceiptsAreOutsideInstanceInitAndStartMaintenance()
        async throws
    {
        let fixtureRoot = uniqueFixtureRoot("legacy-isolation")
        let legacyRoot = fixtureRoot.appendingPathComponent(
            "tatwo-ultrawork-chat-cli",
            isDirectory: true)
        let instanceRoot = legacyRoot
            .appendingPathComponent("instances", isDirectory: true)
            .appendingPathComponent("instance-a", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true)
        for index in 0..<10_000 {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: legacyRoot
                    .appendingPathComponent("spawn-unrelated-\(index).jsonl")
                    .path,
                contents: Data("{}\n".utf8)))
        }

        let probe = ChatRuntimeSweepLauncherProbe()
        let recorder = ChatRuntimeRootEventRecorder()
        let runner = ChatCLIProcessRunner(
            runtimeRootURL: instanceRoot,
            runtimeSweepGate: ChatCLIRuntimeSweepGate(debounceInterval: 60),
            runtimeSweepLauncher: { root, reason, completion in
                Task {
                    await probe.launch(
                        root: root,
                        reason: reason,
                        completion: completion)
                }
            })

        for _ in 0..<200 {
            if await probe.launchCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let initialLaunchCount = await probe.launchCount
        XCTAssertEqual(initialLaunchCount, 1)
        runner.start(
            command: fixtureCommand(),
            runID: "instance-a-turn",
            onEvent: { event in
                Task {
                    await recorder.record(event)
                }
            })
        for _ in 0..<500 {
            if await recorder.terminalCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let terminalCount = await recorder.terminalCount
        XCTAssertGreaterThanOrEqual(terminalCount, 1)

        let launchCount = await probe.launchCount
        let roots = await probe.roots
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(roots, [instanceRoot.standardizedFileURL])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: instanceRoot
                .appendingPathComponent("spawn-instance-a-turn.jsonl")
                .path))
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]))?
                .filter { $0.lastPathComponent.hasPrefix("spawn-unrelated-") }
                .count,
            10_000)
        await probe.completeAll()
    }

    func testInjectedRootsKeepSpawnAndStreamArtifactsIsolated() async throws {
        let fixtureRoot = uniqueFixtureRoot("root-pair")
        let rootA = fixtureRoot.appendingPathComponent("A", isDirectory: true)
        let rootB = fixtureRoot.appendingPathComponent("B", isDirectory: true)
        let recorderA = ChatRuntimeRootEventRecorder()
        let recorderB = ChatRuntimeRootEventRecorder()
        let runnerA = ChatCLIProcessRunner(
            runtimeRootURL: rootA,
            runtimeSweepLauncher: { _, _, completion in completion() })
        let runnerB = ChatCLIProcessRunner(
            runtimeRootURL: rootB,
            runtimeSweepLauncher: { _, _, completion in completion() })

        runnerA.start(
            command: fixtureCommand(),
            runID: "root-a-run",
            onEvent: { event in
                Task {
                    await recorderA.record(event)
                }
            })
        runnerB.start(
            command: fixtureCommand(),
            runID: "root-b-run",
            onEvent: { event in
                Task {
                    await recorderB.record(event)
                }
            })
        for _ in 0..<500 {
            let terminalCountA = await recorderA.terminalCount
            let terminalCountB = await recorderB.terminalCount
            if terminalCountA > 0, terminalCountB > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let terminalCountA = await recorderA.terminalCount
        let terminalCountB = await recorderB.terminalCount
        XCTAssertGreaterThanOrEqual(terminalCountA, 1)
        XCTAssertGreaterThanOrEqual(terminalCountB, 1)

        let namesA = Set((try? FileManager.default.contentsOfDirectory(
            atPath: rootA.path)) ?? [])
        let namesB = Set((try? FileManager.default.contentsOfDirectory(
            atPath: rootB.path)) ?? [])
        XCTAssertTrue(namesA.contains("spawn-root-a-run.jsonl"))
        XCTAssertTrue(namesA.contains("stdout-root-a-run.jsonl"))
        XCTAssertFalse(namesA.contains("spawn-root-b-run.jsonl"))
        XCTAssertFalse(namesA.contains("stdout-root-b-run.jsonl"))
        XCTAssertTrue(namesB.contains("spawn-root-b-run.jsonl"))
        XCTAssertTrue(namesB.contains("stdout-root-b-run.jsonl"))
        XCTAssertFalse(namesB.contains("spawn-root-a-run.jsonl"))
        XCTAssertFalse(namesB.contains("stdout-root-a-run.jsonl"))
    }

    func testRetentionPreservesUnknownAndActiveArtifactsFailClosed() {
        let root = uniqueFixtureRoot("retention-preserve")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let unknownURL = createOldArtifact(
            root: root,
            name: "spawn-unknown-run.jsonl")
        let activeURL = createOldArtifact(
            root: root,
            name: "spawn-active-run.jsonl")
        let reclaimToken = ChatRunnerReclaimToken(
            runID: "active-run",
            attempt: 1,
            instanceID: UUID(),
            revision: 4)

        XCTAssertEqual(
            ChatCLIRuntimeArtifactRetirement.retireReclaimableArtifacts(
                in: root,
                authority: .unknown(reason: "probe-permission-denied"),
                policy: ChatCLIRuntimeRetentionPolicy(minimumArtifactAge: 0)),
            0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownURL.path))

        XCTAssertEqual(
            ChatCLIRuntimeArtifactRetirement.retireReclaimableArtifacts(
                in: root,
                authority: .authoritative(
                    activeRunIDs: ["active-run"],
                    reclaimTokens: [reclaimToken]),
                policy: ChatCLIRuntimeRetentionPolicy(minimumArtifactAge: 0)),
            0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path))
    }

    func testRetentionMovesOnlyAgedExactReclaimArtifactsOutOfHotRoot() {
        let root = uniqueFixtureRoot("retention-reclaim")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let reclaimRun = "terminal-run"
        for name in [
            "spawn-\(reclaimRun).jsonl",
            "stdout-\(reclaimRun).jsonl",
            "stderr-\(reclaimRun)-attempt2.log",
            "status-\(reclaimRun).txt"
        ] {
            _ = createOldArtifact(root: root, name: name)
        }
        let unrelated = createOldArtifact(
            root: root,
            name: "spawn-unrelated-run.jsonl")
        let token = ChatRunnerReclaimToken(
            runID: reclaimRun,
            attempt: 2,
            instanceID: UUID(),
            revision: 9)

        XCTAssertEqual(
            ChatCLIRuntimeArtifactRetirement.retireReclaimableArtifacts(
                in: root,
                authority: .authoritative(
                    activeRunIDs: [],
                    reclaimTokens: [token]),
                policy: ChatCLIRuntimeRetentionPolicy(minimumArtifactAge: 60),
                now: Date()),
            4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "spawn-\(reclaimRun).jsonl").path))
        let retiredRoot = root.appendingPathComponent("retired", isDirectory: true)
        let retiredBatches = (try? FileManager.default.contentsOfDirectory(
            at: retiredRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        XCTAssertEqual(retiredBatches.count, 1)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(
                atPath: retiredBatches[0].path))?.count,
            4)
    }

    func testSweepGateCoalescesInflightAndDebouncesCompletedSweep() {
        let gate = ChatCLIRuntimeSweepGate(debounceInterval: 30)
        let startedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(gate.begin(now: startedAt), .started)
        for offset in 1...100 {
            XCTAssertEqual(
                gate.begin(now: startedAt.addingTimeInterval(Double(offset))),
                .alreadyRunning)
        }
        gate.complete(now: startedAt.addingTimeInterval(101))
        XCTAssertEqual(
            gate.begin(now: startedAt.addingTimeInterval(120)),
            .debounced)
        XCTAssertEqual(
            gate.begin(now: startedAt.addingTimeInterval(132)),
            .started)
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
                "tatwo-chat-runtime-root-tests",
                isDirectory: true)
            .appendingPathComponent(
                "\(label)-\(UUID().uuidString)",
                isDirectory: true)
    }

    @discardableResult
    private func createOldArtifact(root: URL, name: String) -> URL {
        let url = root.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: Data("fixture".utf8)))
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: url.path)
        return url
    }
}

private actor ChatRuntimeSweepLauncherProbe {
    private var launches: [(root: URL, completion: @Sendable () -> Void)] = []

    func launch(
        root: URL,
        reason _: String,
        completion: @escaping @Sendable () -> Void
    ) {
        launches.append((root.standardizedFileURL, completion))
    }

    var launchCount: Int {
        launches.count
    }

    var roots: [URL] {
        launches.map(\.root)
    }

    func completeAll() {
        let completions = launches.map(\.completion)
        launches.removeAll()
        completions.forEach { $0() }
    }
}

private actor ChatRuntimeRootEventRecorder {
    private(set) var terminalCount = 0

    func record(_ event: ChatCLIEvent) {
        switch event {
        case .exit, .runtimeFailure:
            terminalCount += 1
        default:
            break
        }
    }
}
