import Foundation
import XCTest

@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

@MainActor
final class ChatPlanWorkOSLocalActionTests: XCTestCase {
    func testDiscussingPlanExposesWorkOSConfirmationMarker() throws {
        let source = try sourceText("ChatPage.swift")

        XCTAssertTrue(source.contains("\"plan-execution-run\""))
        XCTAssertTrue(source.contains("\"確認計畫／送交 Work OS\""))
        XCTAssertTrue(source.contains("\"plan-confirm-work-os-status\""))
        XCTAssertFalse(source.contains("\"plan-canvas-confirm\""))
    }

    func testOrdinaryTatwoOSNextTextIsBlockedBeforeRunnerSubmission()
        async throws
    {
        let fixture = try makeModelFixture("text-next")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.selectedThreadID = fixture.threadID
        let messagesBefore = fixture.model.messages
        fixture.model.prompt = "tatwo.os.next"

        fixture.model.send()

        XCTAssertEqual(fixture.model.prompt, "tatwo.os.next")
        XCTAssertEqual(fixture.model.messages, messagesBefore)
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertEqual(fixture.runner.startCount, 0)
        XCTAssertTrue(
            fixture.model.composerHint?.contains(
                "確認計畫／送交 Work OS") == true)
    }

    func testPlanModeProjectsEffectiveReadOnlyPermissionWithoutMutation()
        async throws
    {
        let fixture = try makeModelFixture("permission")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.selectedThreadID = fixture.threadID
        fixture.model.permissionPreset = .approveForMe
        fixture.model.setPlanModeEnabled(true)

        XCTAssertEqual(
            fixture.model.effectivePermissionLabel(compact: false),
            "代核 · Plan 唯讀")
        XCTAssertEqual(
            fixture.model.effectivePermissionLabel(compact: true),
            "代核 · Plan 唯讀")
        XCTAssertEqual(fixture.model.permissionPreset, .approveForMe)
        XCTAssertTrue(
            fixture.model.effectivePermissionMappingSummary.contains(
                "Plan 模式只讀"))
    }

    func testBridgeUsesExactInjectedCanonicalRootGoalAndContract()
        throws
    {
        let root = temporaryRoot("bridge")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TatwoGoalRunStore(directoryURL: root)
        let registry = TatwoDispatchRegistry(directoryURL: root)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .s,
            scenarioProfileID: "coding",
            objective: "execute confirmed plan",
            store: store)
        let threadID = UUID()
        let request = ChatPlanWorkOSLocalActionRequest(
            artifactThreadID: threadID,
            selectedThreadID: threadID,
            goalID: contract.goalID,
            contractID: contract.contractID,
            expectedStateRoot: root)

        let next = try ChatPlanWorkOSLocalActionBridge.resolveNext(
            request: request,
            store: store,
            registry: registry,
            scenarioBook: TatwoScenarioConfigDefaults.book)

        XCTAssertTrue(next.ok)
        XCTAssertEqual(next.goalID, contract.goalID)
        XCTAssertEqual(next.contractID, contract.contractID)
        XCTAssertEqual(
            store.directoryURL.standardizedFileURL,
            root.standardizedFileURL)
        XCTAssertEqual(
            registry.directoryURL.standardizedFileURL,
            root.standardizedFileURL)
    }

    func testInjectedLocalActionReceivesCanonicalIDsAndStateRoot()
        async throws
    {
        let capture = NextRequestCapture()
        let fixture = try makeModelFixture(
            "capture",
            nextResolver: { request, _, _, _ in
                capture.request = request
                return Self.acceptedNext(for: request)
            })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.selectedThreadID = fixture.threadID
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .s,
            scenarioProfileID: "coding",
            objective: "confirmed execution revision",
            store: fixture.model.goalRunStore)
        fixture.model.selectedWorkOSContract = contract
        let artifact = TatwoPlanArtifactV1(
            threadID: fixture.threadID,
            objective: "planning-only predecessor",
            sections: [.init(title: "Steps", body: "Execute safely.")])

        XCTAssertTrue(
            fixture.model.performConfirmedPlanWorkOSLocalAction(
                artifact: artifact))
        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.artifactThreadID, fixture.threadID)
        XCTAssertEqual(request.selectedThreadID, fixture.threadID)
        XCTAssertEqual(request.goalID, contract.goalID)
        XCTAssertEqual(request.contractID, contract.contractID)
        XCTAssertEqual(
            request.expectedStateRoot.standardizedFileURL,
            fixture.model.goalRunStore.directoryURL.standardizedFileURL)
        XCTAssertEqual(
            fixture.model.planWorkOSLocalActionPresentation.phase,
            .dispatching)
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.isInFlight)
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.message.contains(
                "canonical transition"))
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.message.contains(
                "runner 尚未啟動"))
        XCTAssertFalse(
            fixture.model.planWorkOSLocalActionPresentation.message.contains(
                "已送交 Work OS"))
        XCTAssertNil(
            fixture.model.planWorkOSLocalActionPresentation.dispatchID)
        XCTAssertNil(
            fixture.model.planWorkOSLocalActionPresentation.runnerEvidenceID)
    }

    func testMissingDispatchRecordCannotPublishConfirmedPlanSuccess()
        async throws
    {
        let fixture = try makeModelFixture("missing-dispatch-evidence")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.selectedThreadID = fixture.threadID
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .s,
            scenarioProfileID: "coding",
            objective: "confirmed execution revision",
            store: fixture.model.goalRunStore)
        fixture.model.selectedWorkOSContract = contract
        let artifact = TatwoPlanArtifactV1(
            threadID: fixture.threadID,
            objective: "planning predecessor",
            sections: [.init(title: "Steps", body: "Require evidence.")])

        XCTAssertTrue(
            fixture.model.performConfirmedPlanWorkOSLocalAction(
                artifact: artifact))
        XCTAssertFalse(
            fixture.model
                .publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
                    dispatchID: "missing-dispatch"))
        XCTAssertEqual(
            fixture.model.planWorkOSLocalActionPresentation.phase,
            .failed)
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.isRetryable)
        XCTAssertEqual(
            fixture.model.planWorkOSLocalActionPresentation.dispatchID,
            "missing-dispatch")
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.message.contains(
                "找不到 canonical dispatch record"))
        XCTAssertEqual(fixture.runner.startCount, 0)
    }

    func testRunningDispatchWithoutMatchingRunnerLivenessCannotPublishSuccess()
        async throws
    {
        let fixture = try makeModelFixture("running-without-runner")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.selectedThreadID = fixture.threadID
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .s,
            scenarioProfileID: "coding",
            objective: "confirmed execution revision",
            store: fixture.model.goalRunStore)
        fixture.model.selectedWorkOSContract = contract
        let artifact = TatwoPlanArtifactV1(
            threadID: fixture.threadID,
            objective: "planning predecessor",
            sections: [.init(title: "Steps", body: "Require liveness.")])
        let queued = try fixture.model.dispatchRegistry.begin(
            contractID: contract.contractID,
            goalID: contract.goalID,
            bindingID: "single-model",
            sourceSlotID: "main",
            identity: .sub,
            modelID: "gpt-5.5",
            subtask: "execute confirmed plan")
        _ = try fixture.model.dispatchRegistry.update(
            contractID: contract.contractID,
            dispatchID: queued.id,
            status: .running)

        XCTAssertTrue(
            fixture.model.performConfirmedPlanWorkOSLocalAction(
                artifact: artifact))
        XCTAssertFalse(
            fixture.model
                .publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
                    dispatchID: queued.id))
        XCTAssertEqual(
            fixture.model.planWorkOSLocalActionPresentation.phase,
            .dispatching)
        XCTAssertEqual(
            fixture.model.planWorkOSLocalActionPresentation.dispatchID,
            queued.id)
        XCTAssertNil(
            fixture.model.planWorkOSLocalActionPresentation.runnerEvidenceID)
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.message.contains(
                "尚未觀測到對應 runner liveness"))
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertEqual(fixture.runner.startCount, 0)
    }

    func testInFlightAndConfirmedPlanClicksAreIdempotent() async throws {
        let capture = NextRequestCapture()
        let fixture = try makeModelFixture(
            "idempotent",
            nextResolver: { request, _, _, _ in
                capture.request = request
                return Self.acceptedNext(for: request)
            })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.selectedThreadID = fixture.threadID
        let discussing = TatwoPlanArtifactV1(
            threadID: fixture.threadID,
            objective: "one confirmation",
            sections: [.init(title: "Steps", body: "Only once.")])
        fixture.model.activePlanArtifact = discussing
        fixture.model.planConfirmInFlight = true

        fixture.model.confirmActivePlan()

        XCTAssertEqual(fixture.model.activePlanArtifact, discussing)
        XCTAssertNil(capture.request)

        var confirmed = discussing
        confirmed.confirm()
        fixture.model.planConfirmInFlight = false
        fixture.model.activePlanArtifact = confirmed
        fixture.model.confirmActivePlan()

        XCTAssertNil(capture.request)
        XCTAssertEqual(
            fixture.model.composerHint,
            "這份計畫已確認；不會重複送交 Work OS。")
    }

    func testNextFailureIsRetryableAndDoesNotStartRunner() async throws {
        let fixture = try makeModelFixture(
            "next-failure",
            nextResolver: { _, _, _, _ in
                throw ChatPlanWorkOSLocalActionError.nextRejected(
                    code: "test_rejection")
            })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.selectedThreadID = fixture.threadID
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .s,
            scenarioProfileID: "coding",
            objective: "confirmed execution revision",
            store: fixture.model.goalRunStore)
        fixture.model.selectedWorkOSContract = contract
        let artifact = TatwoPlanArtifactV1(
            threadID: fixture.threadID,
            objective: "planning predecessor",
            sections: [.init(title: "Steps", body: "Do not dispatch.")])
        let messagesBefore = fixture.model.messages

        XCTAssertFalse(
            fixture.model.performConfirmedPlanWorkOSLocalAction(
                artifact: artifact))
        XCTAssertEqual(fixture.runner.startCount, 0)
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertEqual(fixture.model.messages, messagesBefore)
        XCTAssertEqual(
            fixture.model.planWorkOSLocalActionPresentation.phase,
            .failed)
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.isRetryable)
        XCTAssertTrue(
            fixture.model.planWorkOSLocalActionPresentation.message.contains(
                "test_rejection"))
    }

    func testRevisionAndLocalNextPrecedeSingleModelDispatchInSource()
        throws
    {
        let source = try sourceText("ChatPageModel+Workflows.swift")
        let activation = try XCTUnwrap(
            source.range(of: "    private func activateGoalFromPromptAsync("))
        let activationTail = String(source[activation.lowerBound...])
        let revision = try XCTUnwrap(
            activationTail.range(
                of: "prepareConfirmedPlanGoalRevisionIfNeeded("))
        let localNext = try XCTUnwrap(
            activationTail.range(
                of: "performConfirmedPlanWorkOSLocalAction("))
        let dispatch = try XCTUnwrap(
            activationTail.range(of: "beginSingleModelGoalDispatch("))
        let singleModelBranch = try XCTUnwrap(
            activationTail.range(
                of: "        if singleModelTopology {",
                range: localNext.upperBound..<activationTail.endIndex))
        let singleModelTail = String(
            activationTail[singleModelBranch.lowerBound...])
        let singleModelDispatch = try XCTUnwrap(
            singleModelTail.range(
                of: "beginSingleModelGoalDispatch(subtask: objective)"))
        let runnerSettlement = try XCTUnwrap(
            singleModelTail.range(
                of: "settleAcceptedSingleModelGoalDispatchStart("))
        let successPublication = try XCTUnwrap(
            singleModelTail.range(
                of:
                    "publishConfirmedPlanWorkOSDispatchSuccessIfVerified(",
                range:
                    runnerSettlement.upperBound..<singleModelTail.endIndex))

        XCTAssertLessThan(
            revision.lowerBound.utf16Offset(in: activationTail),
            localNext.lowerBound.utf16Offset(in: activationTail))
        XCTAssertLessThan(
            localNext.lowerBound.utf16Offset(in: activationTail),
            dispatch.lowerBound.utf16Offset(in: activationTail))
        XCTAssertLessThan(
            singleModelDispatch.lowerBound.utf16Offset(in: singleModelTail),
            runnerSettlement.lowerBound.utf16Offset(in: singleModelTail))
        XCTAssertLessThan(
            runnerSettlement.lowerBound.utf16Offset(in: singleModelTail),
            successPublication.lowerBound.utf16Offset(in: singleModelTail))
        XCTAssertTrue(
            singleModelTail.contains(
                "failConfirmedPlanDispatch("))
        XCTAssertTrue(
            activationTail.contains(
                "Work OS 未建立可驗證的 canonical dispatch record"))
        let artifact = TatwoPlanArtifactV1(
            threadID: UUID(),
            objective: "只做規劃，不要修改檔案。",
            sections: [.init(title: "Plan", body: "A safe plan.")])
        let execution =
            ChatPageModel.confirmedPlanExecutionObjective(artifact)
        XCTAssertTrue(execution.contains("supersedes"))
        XCTAssertFalse(execution.contains("只做規劃"))
    }

    func testPLGPlanPublishesSuccessOnlyAfterRunnerStartGate() throws {
        let source = try sourceText("ChatPageModel+Workflows.swift")
        let confirmation = try XCTUnwrap(
            source.range(
                of: "    private func finishConfirmingActivePlan("))
        let tail = String(source[confirmation.lowerBound...])
        let localNext = try XCTUnwrap(
            tail.range(
                of: "performConfirmedPlanWorkOSLocalAction(artifact: artifact)"))
        let runnerStart = try XCTUnwrap(
            tail.range(
                of: "confirmPLGPlanAndStartLoops(",
                range: localNext.upperBound..<tail.endIndex))
        let successPublication = try XCTUnwrap(
            tail.range(
                of:
                    "publishConfirmedPlanWorkOSDispatchSuccessIfVerified(",
                range: runnerStart.upperBound..<tail.endIndex))

        XCTAssertLessThan(
            localNext.lowerBound.utf16Offset(in: tail),
            runnerStart.lowerBound.utf16Offset(in: tail))
        XCTAssertLessThan(
            runnerStart.lowerBound.utf16Offset(in: tail),
            successPublication.lowerBound.utf16Offset(in: tail))
        let betweenNextAndRunner = String(
            tail[localNext.lowerBound..<runnerStart.lowerBound])
        XCTAssertFalse(
            betweenNextAndRunner.contains("phase: .succeeded"))
    }

    func testConfirmedPlanGoalUsesBoundObjectiveInsteadOfComposerDraft()
        throws
    {
        let source = try sourceText("ChatPageModel+Workflows.swift")
        let confirmation = try XCTUnwrap(
            source.range(
                of: "    private func finishConfirmingActivePlan("))
        let activation = try XCTUnwrap(
            source.range(
                of: "    private func activateGoalFromPromptAsync(",
                range: confirmation.upperBound..<source.endIndex))
        let confirmationSource = String(
            source[confirmation.lowerBound..<activation.lowerBound])
        let activationSource = String(source[activation.lowerBound...])

        XCTAssertFalse(
            confirmationSource.contains("prompt = \"/goal \""),
            "送交 Work OS 不得靠預填 composer 再等待第二次 Send")
        XCTAssertTrue(
            confirmationSource.contains(
                "objectiveOverride: executionObjective"))
        XCTAssertTrue(
            confirmationSource.contains(
                "不得啟動 SwiftPM 或 repo 探索"))
        XCTAssertTrue(
            activationSource.contains(
                "let explicitObjective = objectiveOverride?"))
        XCTAssertTrue(
            activationSource.contains(
                "A confirmed Plan is a canonical UI action, not a composer draft."))
    }

    func testConfirmedPlanExecutionUsesDedicatedTransportWithoutComposerState()
        throws
    {
        let source = try ChatSourceFamily.read("ChatPageModel.swift")
        let start = try XCTUnwrap(
            source.range(
                of: "    func startConfirmedPlanExecutionTurn("))
        let end = try XCTUnwrap(
            source.range(
                of: "    func submitCurrentChatTurn(",
                range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("startTurn("))
        XCTAssertTrue(
            body.contains(
                "ChatPlanThoughtPresentation"))
        XCTAssertTrue(
            body.contains(
                ".isConfirmedPlanExecutionPrompt(executionMessage)"))
        XCTAssertTrue(body.contains("attachmentPaths: []"))
        XCTAssertTrue(
            body.contains(
                #"previewTurn: "已確認 Plan → Work OS""#))
        XCTAssertTrue(
            body.contains(
                "ChatConfirmedPlanDispatchBindingPolicy.matches("))
        XCTAssertTrue(
            body.contains(
                "dispatchBindingID: canonicalDispatch.bindingID"))
        XCTAssertTrue(
            body.contains(
                "dispatchSourceSlotID: canonicalDispatch.sourceSlotID"))
        XCTAssertTrue(
            body.contains(
                "userMessageAlreadyAppended: true"),
            "confirmed execution must reuse/defer its canonical anchor, not publish success before authority checks")
        XCTAssertTrue(body.contains(
            "canonicalSourceSlotID: canonicalDispatch.sourceSlotID"))
        XCTAssertFalse(body.contains("submitCurrentChatTurn("))
        XCTAssertFalse(body.contains("prompt ="))
        XCTAssertFalse(
            body.contains("clearComposerDraftAfterAcceptedSubmission"))
        XCTAssertFalse(body.contains("droppedPaths"))
    }

    func testConfirmedPlanDispatchBindingUsesSourceSlotIDNotBindingID() {
        XCTAssertTrue(
            ChatConfirmedPlanDispatchBindingPolicy.matches(
                snapshotContractID: "contract-id",
                snapshotBindingID: "slot-id",
                dispatchContractID: "contract-id",
                dispatchBindingID: "binding-id",
                dispatchSourceSlotID: "slot-id",
                issuedBindingID: "binding-id",
                issuedSourceSlotID: "slot-id"))
        XCTAssertFalse(
            ChatConfirmedPlanDispatchBindingPolicy.matches(
                snapshotContractID: "contract-id",
                snapshotBindingID: "binding-id",
                dispatchContractID: "contract-id",
                dispatchBindingID: "binding-id",
                dispatchSourceSlotID: "slot-id",
                issuedBindingID: "binding-id",
                issuedSourceSlotID: "slot-id"))
    }

    func testConfirmedPlanDispatchBindingRejectsIssuedSourceSlotMismatch() {
        XCTAssertFalse(
            ChatConfirmedPlanDispatchBindingPolicy.matches(
                snapshotContractID: "contract-id",
                snapshotBindingID: "slot-id",
                dispatchContractID: "contract-id",
                dispatchBindingID: "binding-id",
                dispatchSourceSlotID: "slot-id",
                issuedBindingID: "binding-id",
                issuedSourceSlotID: "different-slot"))
    }

    func testEveryConfirmedPlanDispatchBranchUsesDedicatedTransport()
        throws
    {
        let source = try sourceText("ChatPageModel+Workflows.swift")
        let activationStart = try XCTUnwrap(
            source.range(
                of: "    private func activateGoalFromPromptAsync("))
        let activationEnd = try XCTUnwrap(
            source.range(
                of: "    @discardableResult\n"
                    + "    func beginSingleModelGoalDispatch(",
                range:
                    activationStart.upperBound..<source.endIndex))
        let activation = String(
            source[activationStart.lowerBound..<activationEnd.lowerBound])
        XCTAssertGreaterThanOrEqual(
            activation.components(
                separatedBy: "startConfirmedPlanExecutionTurn("
            ).count - 1,
            2)
        XCTAssertTrue(
            activation.contains(
                "已確認 Plan 不會排入一般 chat queue"))

        let finishStart = try XCTUnwrap(
            source.range(
                of: "    private func finishConfirmingActivePlan("))
        let finishEnd = try XCTUnwrap(
            source.range(
                of: "    private func confirmedPlanExecutionPrompt(",
                range: finishStart.upperBound..<source.endIndex))
        let finish = String(
            source[finishStart.lowerBound..<finishEnd.lowerBound])
        XCTAssertTrue(
            finish.contains(
                "usesConfirmedPlanTransport: true"))

        let plgStart = try XCTUnwrap(
            source.range(
                of: "    func confirmPLGPlanAndStartLoops("))
        let plgEnd = try XCTUnwrap(
            source.range(
                of: "    /// exact 原生開發（XXL）Scenario",
                range: plgStart.upperBound..<source.endIndex))
        let plg = String(source[plgStart.lowerBound..<plgEnd.lowerBound])
        XCTAssertGreaterThanOrEqual(
            plg.components(
                separatedBy: "startConfirmedPlanExecutionTurn("
            ).count - 1,
            2)
        XCTAssertTrue(
            plg.contains(
                "usesConfirmedPlanTransport: Bool = false"))
    }

    private static func acceptedNext(
        for request: ChatPlanWorkOSLocalActionRequest
    ) -> TatwoWorkOSNextAction {
        TatwoWorkOSNextAction(
            ok: true,
            goalID: request.goalID,
            contractID: request.contractID,
            currentLoopID: "main",
            nextStep: "execute confirmed plan",
            requiredReceiptsBeforePass: [],
            decision: WorkOSGateDecision(
                ok: true,
                code: "next_action_ready",
                message: "ready"))
    }

    private func makeModelFixture(
        _ suffix: String,
        nextResolver: ChatPlanWorkOSNextResolver? = nil
    ) throws -> (
        root: URL,
        model: ChatPageModel,
        threadID: UUID,
        runner: CountingNativeRunner
    ) {
        let root = temporaryRoot(suffix)
        let threadID = UUID()
        let store = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try store.save(
            TatwoNativeChatStoreDocument(
                threads: [
                    TatwoNativeChatThread(
                        id: threadID,
                        title: "Plan local action")
                ]))
        let runner = CountingNativeRunner()
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatPlanWorkOSLocalActionTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            planWorkOSNextResolver: nextResolver ?? {
                request,
                _,
                _,
                _ in
                ChatPlanWorkOSLocalActionTests.acceptedNext(
                    for: request)
            },
            nativeRunner: runner)
        return (root, model, threadID, runner)
    }

    private func waitForInitialStoreLoad(
        _ model: ChatPageModel
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isLoadingStore && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-plan-local-action-\(suffix)-\(UUID().uuidString)",
            isDirectory: true)
    }

    private func sourceText(_ name: String) throws -> String {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/TatwoUltraworkMac",
                isDirectory: true)
        return try ChatSourceFamily.read(url: sourceRoot.appendingPathComponent(name))
    }
}

private final class NextRequestCapture {
    var request: ChatPlanWorkOSLocalActionRequest?
}

private final class CountingNativeRunner:
    ChatNativeAgentRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedStartCount = 0

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }

    func start(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        lock.lock()
        storedStartCount += 1
        lock.unlock()
        return ChatRunnerAttemptIdentity(
            runID: request.runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
    }

    func terminate() {}
}
