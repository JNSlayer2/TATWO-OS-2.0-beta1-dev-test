import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

/// 快照匯出 fixture。紀律：只影響 export／測試路徑，真實執行零行為差異，
/// 且**絕不接觸 dispatch registry／goal store**（2026-07-13 fixture 覆蓋真 store 教訓）。
final class ExportFixtureTests: XCTestCase {

    @MainActor
    func testDeviceSyncExportFixtureUsesFixedAugustFirstReferenceTime() {
        let expected = Date(timeIntervalSince1970: 1_785_542_400)

        XCTAssertEqual(DeviceCrossSyncCard.exportSyncFixtureReferenceDate, expected)
        XCTAssertLessThan(
            DeviceCrossSyncCard.exportSyncFixtureReferenceDate,
            Date(timeIntervalSince1970: 1_785_628_800)
        )
    }

    // MARK: - loops 活動 fixture

    func testFixtureIsDisabledWhenEnvIsAbsentOrBlank() {
        XCTAssertNil(TatwoLoopsActivityFixture.snapshot(kind: nil))
        XCTAssertNil(TatwoLoopsActivityFixture.snapshot(kind: ""))
    }

    func testUnparseableValuesDoNotEnableTheFixture() {
        for value in ["0", "-3", "yes", "true", "abc"] {
            XCTAssertNil(
                TatwoLoopsActivityFixture.snapshot(kind: value),
                "value=\(value) 不該啟用 fixture")
        }
    }

    func testDefaultFixtureShowsTwoRunningOneQueuedAndOneRemote() {
        let snapshot = try? XCTUnwrap(TatwoLoopsActivityFixture.snapshot(kind: "1"))
        // 2 running + 1 queued + 1 遠端 running（帶 targetDevice）。
        XCTAssertEqual(snapshot?.activeCount, 4)
        XCTAssertEqual(snapshot?.runningCount, 3)
        XCTAssertEqual(snapshot?.queuedCount, 1)
        XCTAssertEqual(snapshot?.isActive, true)
        let remote = snapshot?.rows.first(where: { $0.id == "fixture-remote" })
        XCTAssertEqual(
            remote?.targetDeviceID,
            TatwoLoopsActivityFixture.fixtureRemoteTargetDeviceID)
        XCTAssertEqual(remote?.originDeviceID, "fixture-origin-mini")
    }

    func testNumericFixtureProducesThatManyRunningRows() {
        let snapshot = try? XCTUnwrap(TatwoLoopsActivityFixture.snapshot(kind: "5"))
        XCTAssertEqual(snapshot?.activeCount, 5)
        XCTAssertEqual(snapshot?.runningCount, 5)
        XCTAssertEqual(snapshot?.queuedCount, 0)
    }

    /// 浮動光與 CLI 進行中列都吃 `isActive`；fixture 必須讓它為 true 才拍得到。
    func testFixtureDrivesTheGlowAndStripPredicate() throws {
        let snapshot = try XCTUnwrap(TatwoLoopsActivityFixture.snapshot(kind: "1"))
        XCTAssertTrue(snapshot.isActive)
        XCTAssertFalse(TatwoInterruptGate.activityTally(snapshot).isEmpty)
    }

    /// fixture 生效時 `loopsInProgressNow` 必須直接回 fixture，
    /// 不落到 registry 讀取——用「所有 id 都是合成前綴」證明它沒去讀磁碟。
    @MainActor
    func testMonitorShortCircuitsToFixtureWithoutReadingTheRegistry() {
        let snapshot = TatwoLoopsActivityMonitor.loopsInProgressNow(
            environment: ["TATWO_ULTRAWORK_EXPORT_LOOPS_FIXTURE": "1"])

        XCTAssertEqual(snapshot.activeCount, 4)
        XCTAssertTrue(
            snapshot.rows.allSatisfy { $0.id.hasPrefix("fixture-") },
            "fixture 路徑不得混入任何真實 dispatch 記錄")
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.contractID == "contract-fixture" })
        XCTAssertTrue(
            snapshot.rows.contains {
                $0.targetDeviceID == TatwoLoopsActivityFixture.fixtureRemoteTargetDeviceID
            },
            "export fixture 必須含一筆遠端 targetDevice 列")
    }

    /// 沒設 fixture env 時走真實 registry 路徑：真實執行零行為差異。
    /// 這裡不斷言內容（機器上可能真的有記錄），只斷言它不是合成資料。
    @MainActor
    func testMonitorWithoutFixtureEnvNeverReturnsSyntheticRows() {
        let snapshot = TatwoLoopsActivityMonitor.loopsInProgressNow(environment: [:])
        XCTAssertFalse(
            snapshot.rows.contains { $0.contractID == "contract-fixture" },
            "沒設 env 就不該出現任何 fixture 資料")
    }

    // MARK: - CLI 模式 env

    /// `TATWO_ULTRAWORK_EXPORT_CHAT_MODE=cli` 依賴 ChatRunMode 的大小寫不敏感解析。
    func testChatRunModeResolvesCLICaseInsensitively() {
        for raw in ["CLI", "cli", "Cli"] {
            let resolved = ChatRunMode(rawValue: raw)
                ?? ChatRunMode.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() })
            XCTAssertEqual(resolved, .cli, "raw=\(raw) 應解析為 CLI 模式")
        }
    }

    // MARK: - Chat transcript negative-state selector

    func testChatTranscriptFixtureStateAcceptedSelectorValues() {
        XCTAssertEqual(
            Set(TatwoChatTranscriptFixtureState.acceptedRawValues),
            Set([
                "active",
                "failed",
                "cancelled",
                "disconnected",
                "reconnected",
                "accepted-relaunch",
            ]))
        for raw in TatwoChatTranscriptFixtureState.acceptedRawValues {
            XCTAssertEqual(
                TatwoChatTranscriptFixtureState.parse(raw)?.rawValue,
                raw,
                "accepted selector \(raw) must parse")
        }
        XCTAssertEqual(
            TatwoChatTranscriptFixtureState.environmentKey,
            "TATWO_ULTRAWORK_CHAT_FIXTURE_STATE")
    }

    func testChatTranscriptFixtureStateUnknownValuesFailClosed() {
        for value in [
            "orphan", "0", "-1", "yes", "true", "bogus",
            "failed-soft", "accept", "relaunch", " ",
        ] {
            XCTAssertNil(
                TatwoChatTranscriptFixtureState.parse(value),
                "value=\(value) must fail closed (no invented state)")
            XCTAssertEqual(
                TatwoChatTranscriptFixtureState.resolve(value),
                .active,
                "unknown selector must fall back to active/Stop default")
        }
        XCTAssertNil(TatwoChatTranscriptFixtureState.parse(nil))
        XCTAssertNil(TatwoChatTranscriptFixtureState.parse(""))
        XCTAssertEqual(TatwoChatTranscriptFixtureState.resolve(nil), .active)
        XCTAssertEqual(TatwoChatTranscriptFixtureState.resolve(""), .active)
        // Static orphan visual fixture is intentionally absent.
        XCTAssertFalse(
            TatwoChatTranscriptFixtureState.acceptedRawValues.contains("orphan"))
    }

    /// Fixture identities are pure synthetic export keys — parse/resolve never
    /// touches dispatch registry, goal store, or a real Application Support path.
    func testChatTranscriptFixtureStateIsolationFromRealPersistedState() {
        let syntheticIDs = [
            TatwoChatTranscriptFixtureState.activeInlineMessageID,
            TatwoChatTranscriptFixtureState.remoteLogicalJobID,
            TatwoChatTranscriptFixtureState.remoteJobID,
            TatwoChatTranscriptFixtureState.remoteLogicalKey,
        ]
        for id in syntheticIDs {
            XCTAssertTrue(
                id.contains("fixture"),
                "export identity must stay synthetic: \(id)")
            XCTAssertFalse(id.contains("/Users/"), id)
            XCTAssertFalse(id.contains("Application Support"), id)
            XCTAssertFalse(id.contains("Library/"), id)
            XCTAssertFalse(id.hasPrefix("/"), id)
        }
        // Pure in-memory parse: no ProcessInfo / disk side effects required.
        XCTAssertEqual(TatwoChatTranscriptFixtureState.parse("FAILED"), .failed)
        XCTAssertEqual(
            TatwoChatTranscriptFixtureState.parse("accepted-relaunch"),
            .acceptedRelaunch)
        XCTAssertEqual(
            TatwoChatTranscriptFixtureState.resolve("disconnected"),
            .disconnected)
    }

    @MainActor
    func testReconnectStatesUseOneLocalInlineRowWithoutLegacyStatusUI() throws {
        for state in [
            TatwoChatTranscriptFixtureState.disconnected,
            .reconnected,
        ] {
            let model = try makeChatTranscriptFixture(state: state)
            let stateRows = model.transcriptMessages.filter {
                $0.id == TatwoChatTranscriptFixtureState.activeInlineMessageID
            }

            XCTAssertEqual(stateRows.count, 1, "state=\(state.rawValue)")
            XCTAssertTrue(model.liveWorkActivities.isEmpty, "state=\(state.rawValue)")
            XCTAssertNil(model.composerHint, "state=\(state.rawValue)")
            XCTAssertEqual(
                model.isRunning,
                state == .disconnected,
                "state=\(state.rawValue)")
            if state == .disconnected {
                XCTAssertTrue(stateRows[0].text.contains("正在重連"))
            }
        }
    }

    @MainActor
    func testRemoteFixtureMutatesOneJournalRowRunningFailedAndRelaunch() throws {
        let dispatcher = ExportFixtureRecordingRemoteTurnDispatcher()
        let model = try makeChatTranscriptFixture(
            state: .active,
            remoteTurnDispatcher: dispatcher)

        let runningRows = try remoteRows(in: model)
        let stableID = try XCTUnwrap(runningRows.first?.id)
        let runningPayload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(
                from: runningRows.first?.status))
        XCTAssertEqual(runningRows.count, 1)
        XCTAssertEqual(runningPayload.state, .running)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.activeAssistantID, stableID)
        assertNoDuplicateStatusUI(model)

        XCTAssertTrue(
            model.applyExportOnlyChatTranscriptFixtureState(.failed))
        let failedRows = try remoteRows(in: model)
        let failedPayload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(
                from: failedRows.first?.status))
        XCTAssertEqual(failedRows.count, 1)
        XCTAssertEqual(failedRows.first?.id, stableID)
        XCTAssertNil(failedPayload.state)
        XCTAssertNotNil(failedPayload.blocker)
        XCTAssertTrue(failedRows[0].text.contains("失敗"))
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.activeAssistantID)
        assertNoDuplicateStatusUI(model)

        XCTAssertTrue(
            model.applyExportOnlyChatTranscriptFixtureState(.acceptedRelaunch))
        let relaunchedRows = try remoteRows(in: model)
        let journalRows = try journalRemoteRows(in: model)
        let relaunchedPayload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(
                from: relaunchedRows.first?.status))
        XCTAssertEqual(relaunchedRows.count, 1)
        XCTAssertEqual(relaunchedRows.first?.id, stableID)
        XCTAssertEqual(journalRows.count, 1)
        XCTAssertEqual(journalRows.first?.phase, .running)
        XCTAssertEqual(journalRows.first?.source.attempt, 2)
        XCTAssertEqual(journalRows.first?.eventIDs.count, 3)
        XCTAssertEqual(relaunchedPayload.state, .running)
        XCTAssertEqual(relaunchedPayload.details["attempts"], "2")
        XCTAssertEqual(relaunchedRows[0].text, "正在遠端設備執行")
        XCTAssertTrue(
            relaunchedPayload.details["lifecycle"]?.contains("第 2 次嘗試") == true)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.activeAssistantID, stableID)
        XCTAssertTrue(dispatcher.requests.isEmpty)
        assertNoDuplicateStatusUI(model)
        XCTAssertTrue(model.prompt.isEmpty)
    }

    @MainActor
    func testCancelledRemoteFixtureUsesOneTerminalJournalRow() throws {
        let model = try makeChatTranscriptFixture(state: .cancelled)
        let rows = try remoteRows(in: model)
        let journalRows = try journalRemoteRows(in: model)
        let payload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: rows.first?.status))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(journalRows.count, 1)
        XCTAssertEqual(journalRows.first?.phase, .cancelled)
        XCTAssertNil(payload.state)
        XCTAssertNotNil(payload.blocker)
        XCTAssertTrue(rows[0].text.contains("已取消"))
        XCTAssertFalse(model.isRunning)
        assertNoDuplicateStatusUI(model)
    }

    func testGoldenSceneSelectorIsWindowExportOnlyAndComplete() {
        XCTAssertEqual(
            Set(TatwoExportChatGoldenScene.acceptedRawValues),
            Set([
                "send", "stream", "stop", "resume", "slash", "plg",
                "engine_switch", "reattach", "cold_start", "orphan",
                "queued_turn",
            ]))
        XCTAssertNil(TatwoExportChatGoldenScene.resolve(environment: [
            TatwoExportChatGoldenScene.environmentKey: "send",
        ]))
        XCTAssertEqual(
            TatwoExportChatGoldenScene.resolve(environment: [
                TatwoExportChatGoldenScene.windowSnapshotEnvironmentKey:
                    "/tmp/chat.png",
                TatwoExportChatGoldenScene.environmentKey: "ENGINE_SWITCH",
            ]),
            .engineSwitch)
        XCTAssertNil(TatwoExportChatGoldenScene.resolve(environment: [
            TatwoExportChatGoldenScene.windowSnapshotEnvironmentKey:
                "/tmp/chat.png",
            TatwoExportChatGoldenScene.environmentKey: "unknown",
        ]))
    }

    @MainActor
    func testGoldenScenesBuildFrozenInMemoryChatStates() throws {
        for scene in TatwoExportChatGoldenScene.allCases {
            let model = try makeGoldenSceneFixture(scene)
            XCTAssertFalse(
                model.transcriptMessages.isEmpty,
                "missing rows: \(scene.rawValue)")
            XCTAssertEqual(
                model.isRunning,
                scene.isFrozenInFlight,
                "running state: \(scene.rawValue)")
            XCTAssertEqual(
                model.selectedWorkOSContract != nil,
                scene == .plg,
                "Goal binding: \(scene.rawValue)")
            if scene == .orphan {
                XCTAssertNil(model.selectedProjectID)
                XCTAssertTrue(
                    model.transcriptMessages
                        .contains { $0.text.contains("沒有 Goal") })
            } else {
                XCTAssertNotNil(model.selectedProjectID)
            }
            if scene == .queuedTurn {
                XCTAssertTrue(
                    model.transcriptMessages
                        .contains { $0.status?.hasPrefix("queued|") == true })
            }
        }
    }

    @MainActor
    private func makeChatTranscriptFixture(
        state: TatwoChatTranscriptFixtureState,
        remoteTurnDispatcher:
            any ChatRemoteTurnDispatching = ChatUnavailableRemoteTurnDispatcher()
    ) throws -> ChatPageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-export-fixture-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        return ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ExportFixtureTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
                TatwoChatTranscriptFixtureState.environmentKey: state.rawValue,
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            remoteBorrowAuthorizationStore: TatwoRemoteBorrowAuthorizationStore(
                rootURL: directory.appendingPathComponent(
                    "authorization",
                    isDirectory: true)),
            pendingRemoteTargetStore: ChatPendingRemoteTargetDiskStore(
                fileURL: directory.appendingPathComponent("pending.json")),
            remoteTurnDispatcher: remoteTurnDispatcher)
    }

    @MainActor
    private func makeGoldenSceneFixture(
        _ scene: TatwoExportChatGoldenScene
    ) throws -> ChatPageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-g3-golden-scene-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ExportFixtureTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                TatwoExportChatGoldenScene.windowSnapshotEnvironmentKey:
                    directory.appendingPathComponent("chat.png").path,
                TatwoExportChatGoldenScene.environmentKey: scene.rawValue,
            ],
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            remoteBorrowAuthorizationStore:
                TatwoRemoteBorrowAuthorizationStore(
                    rootURL: directory.appendingPathComponent(
                        "authorization",
                        isDirectory: true)),
            pendingRemoteTargetStore: ChatPendingRemoteTargetDiskStore(
                fileURL: directory.appendingPathComponent("pending.json")))
    }

    @MainActor
    private func remoteRows(in model: ChatPageModel) throws -> [ChatMessage] {
        let remoteIDs = Set(try journalRemoteRows(in: model).map(\.id))
        return model.transcriptMessages.filter { remoteIDs.contains($0.id) }
    }

    @MainActor
    private func journalRemoteRows(
        in model: ChatPageModel
    ) throws -> [ChatTranscriptItemV1] {
        let threadID = try XCTUnwrap(model.selectedThreadID)
        return model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: threadID
                ).stableKey)
            .filter { $0.kind == .remoteJob }
    }

    @MainActor
    private func assertNoDuplicateStatusUI(
        _ model: ChatPageModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(model.liveWorkActivities.isEmpty, file: file, line: line)
        XCTAssertNil(model.composerHint, file: file, line: line)
    }
}

private final class ExportFixtureRecordingRemoteTurnDispatcher:
    ChatRemoteTurnDispatching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRequests: [ChatRemoteTurnDispatchRequest] = []

    var requests: [ChatRemoteTurnDispatchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func dispatch(
        _ request: ChatRemoteTurnDispatchRequest
    ) -> ChatRemoteTurnDispatchOutcome {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        return .blocked(.adapterUnavailable)
    }
}
