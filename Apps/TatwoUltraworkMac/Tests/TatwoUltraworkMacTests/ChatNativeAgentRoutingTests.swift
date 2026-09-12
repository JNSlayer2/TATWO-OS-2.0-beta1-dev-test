import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class ChatNativeAgentRoutingTests: XCTestCase {
    // MARK: Deprecated beginSolExecutor fixture references
    //
    // The M4c plan note is dated 2026-08-20. Any beginSolExecutor call in this
    // suite is retained only to construct historical Sol/Opus dispatch state;
    // it is not evidence of an App production caller.

    func testSingleModelGoalActivationSerializesBeforeFirstAwait()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)
        let functionStart = try XCTUnwrap(source.range(
            of: "private func activateGoalFromPromptAsync("))
        let functionTail = source[functionStart.lowerBound...]
        let serialization = try XCTUnwrap(functionTail.range(
            of: "singleModelGoalActivationInFlight"))
        let firstAwait = try XCTUnwrap(functionTail.range(
            of: "await prepareNativeDevelopmentScenarioForPLGIfNeeded"))

        XCTAssertLessThan(
            serialization.lowerBound,
            firstAwait.lowerBound,
            "A second Plan Execute click must be rejected before the first activation suspends.")
    }

    func testFallbackReasonSurvivesCommandAndStoredTurnProjection() {
        let plan = TatwoChatCommandPlan(
            routeID: "grok-build",
            engine: .codex,
            runtimeAdapter: .gatewayDirect,
            canonicalModelSlug: "grok-build",
            executable: "node",
            arguments: [],
            workingDirectoryPath: "/tmp",
            expectsJSON: true,
            capturesSessionID: false,
            runtimeFallbackReason: .grokExecutableUnavailable)
        let command = ChatCLICommand(plan: plan, commandMode: .chat)
        XCTAssertEqual(
            command.runtimeFallbackReason,
            .grokExecutableUnavailable)

        let message = ChatMessage(
            role: .assistant,
            text: "",
            runtimeAdapterID: command.runtimeAdapter.rawValue,
            runtimeFallbackReason: command.runtimeFallbackReason)
        let restored = ChatMessage(stored: message.storedRecord)
        XCTAssertEqual(
            restored.runtimeFallbackReason,
            .grokExecutableUnavailable)

        var journal = ChatTranscriptJournalV1()
        let appendOutcome = ChatTranscriptJournalAdapter.append(
            message: message,
            threadID: "m2a-fallback-thread",
            to: &journal)
        guard case .appended = appendOutcome else {
            return XCTFail("fallback turn should append to canonical journal")
        }
        let projected = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "m2a-fallback-thread",
            from: journal)
        XCTAssertEqual(
            projected.first?.runtimeFallbackReason,
            .grokExecutableUnavailable)
    }

    @MainActor
    func testGoalPromptOnFreshUserOwnedThreadCreatesGoalAndFirstRound()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-fresh-goal-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())

        let commandCenter = TatwoNewChatCommandCenter()
        let registration = commandCenter.register {
            model.newChat()
        }
        defer { commandCenter.unregister(registration) }
        commandCenter.request()
        let threadID = try XCTUnwrap(model.selectedThreadID)
        XCTAssertEqual(
            model.selectedThread?.sourceMarker,
            TatwoNativeChatThreadSourceMarker.userOwned)
        model.isRunning = true

        model.prompt = "/goal 建立 fresh App Goal"
        model.send()
        for _ in 0..<160 where model.selectedThread?.workOSGoalID == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "state=\(model.selectedWorkOSStateMessage)",
            "goal=\(model.selectedGoalRecord?.status.rawValue ?? "nil")",
            "primary=\(model.selectedThread?.loopsConfig?.primaryModelID ?? "nil")",
            "bindings=\(model.selectedWorkOSContract?.identityBindings.map { "\($0.identity.rawValue):\($0.modelID ?? "nil"):\($0.authority.rawValue):\($0.canMutateHost)" } ?? [])",
            "activations=\(model.selectedWorkOSContract?.loopGovernorDecision.activatedBindings.map { "\($0.id):\($0.phase.rawValue):\($0.enabled):\($0.boundModelIDs)" } ?? [])",
        ].joined(separator: " ")
        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(model.document.threads.count, 1)
        XCTAssertNotNil(model.selectedThread?.workOSGoalID, diagnostic)
        XCTAssertNotNil(
            model.selectedThread?.workOSContractID,
            diagnostic)
        XCTAssertEqual(
            model.selectedGoalRecord?.status,
            .planned,
            diagnostic)
        XCTAssertEqual(model.queuedChatTurnCount, 1, diagnostic)
        XCTAssertEqual(model.prompt, "", diagnostic)
        XCTAssertNil(model.authorityBootstrapModel.pendingProposal)
    }

    @MainActor
    func testDirectGoalActivationOnFreshThreadCreatesGoalAndSubmitsFirstRound()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-direct-fresh-goal-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
        model.newChat()
        model.isRunning = true
        let request = "/goal 在 calc.py 加 divide 函式"
        model.prompt = request

        model.commitOrActivateGoalFromPrompt()
        for _ in 0..<160 where model.selectedThread?.workOSGoalID == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "plgError=\(model.plgError ?? "nil")",
            "state=\(model.selectedWorkOSStateMessage)",
        ].joined(separator: " ")
        XCTAssertNotNil(model.selectedThread?.workOSGoalID, diagnostic)
        XCTAssertNotNil(model.selectedGoalRecord, diagnostic)
        XCTAssertEqual(model.queuedChatTurnCount, 1, diagnostic)
        XCTAssertEqual(model.prompt, "", diagnostic)
    }

    @MainActor
    func testPlanSingleModelCreatesSContractAndRunningDispatch()
        async throws
    {
        let persistentRoot = ProcessInfo.processInfo.environment[
            "TATWO_PLAN_GOAL_TEST_ROOT"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = (persistentRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(
                "tatwo-plan-single-goal-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            if persistentRoot == nil {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        model.newChat()

        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "完成一個有明確驗收標準的輕量任務",
                requireObjectiveMatch: true,
                allowCreateIfUnbound: true,
                automaticallyBootstrapUserOwnedAuthority: true,
                forceSingleModel: true),
            model.selectedWorkOSStateMessage)
        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertEqual(contract.mode, .s)
        XCTAssertEqual(
            contract.routeBindingOverride?.primaryModelID,
            model.routeChoice.canonicalModelSlug)

        XCTAssertTrue(
            model.beginSingleModelGoalDispatch(
                subtask: "完成一個有明確驗收標準的輕量任務"),
            model.composerHint ?? "missing dispatch")
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .running)
        XCTAssertEqual(
            model.pendingSingleModelGoalDispatch?.status,
            .running)
    }

    @MainActor
    func testQueuedPlanSingleModelKeepsDispatchRunningUntilRunnerStarts()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-plan-single-goal-queued-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        model.newChat()
        model.isRunning = true
        model.prompt = "/goal 完成一個有明確驗收標準的輕量任務"

        model.activateGoalFromPrompt(forceSingleModel: true)
        for _ in 0..<160
            where model.pendingSingleModelGoalDispatch == nil
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let contractID = try XCTUnwrap(
            model.selectedThread?.workOSContractID,
            model.composerHint ?? model.selectedWorkOSStateMessage)
        XCTAssertEqual(model.queuedChatTurnCount, 1)
        XCTAssertEqual(
            model.pendingSingleModelGoalDispatch?.status,
            .running)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contractID).status,
            .running)
    }

    @MainActor
    func testDuplicatePlanSingleModelActivationDoesNotInvalidatePendingDispatch()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-plan-single-goal-duplicate-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        model.newChat()
        model.isRunning = true
        model.prompt = "/goal 完成一個有明確驗收標準的輕量任務"

        model.activateGoalFromPrompt(forceSingleModel: true)
        model.activateGoalFromPrompt(forceSingleModel: true)
        for _ in 0..<160
            where model.selectedThread?.workOSContractID == nil
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        let contractID = try XCTUnwrap(
            model.selectedThread?.workOSContractID,
            model.composerHint ?? model.selectedWorkOSStateMessage)
        let run = try XCTUnwrap(
            registry.run(forContractID: contractID))
        XCTAssertEqual(run.records.count, 1)
        XCTAssertEqual(run.records.first?.status, .running)
        XCTAssertEqual(
            model.pendingSingleModelGoalDispatch?.status,
            .running)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contractID).status,
            .running)
        XCTAssertEqual(model.queuedChatTurnCount, 1)
    }

    @MainActor
    func testPlanSingleModelCompletedDispatchCanBeJudgedAndClosed()
        async throws
    {
        let persistentRoot = ProcessInfo.processInfo.environment[
            "TATWO_PLAN_GOAL_TEST_ROOT"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = (persistentRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(
                "tatwo-plan-single-goal-close-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            if persistentRoot == nil {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        model.newChat()

        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "完成輕量 Plan→Goal 驗收閉環",
                requireObjectiveMatch: true,
                allowCreateIfUnbound: true,
                automaticallyBootstrapUserOwnedAuthority: true,
                forceSingleModel: true),
            model.selectedWorkOSStateMessage)
        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertTrue(
            model.beginSingleModelGoalDispatch(
                subtask: contract.objective),
            model.composerHint ?? "missing dispatch")
        let dispatch = try XCTUnwrap(
            model.pendingSingleModelGoalDispatch)

        _ = try TatwoGoalRunDispatchLifecycle.update(
            contractID: contract.contractID,
            dispatchID: dispatch.id,
            status: .completed,
            receiptID: "chat-turn-test",
            outputRef: "tatwo-chat://chat-turn-test",
            goalStore: goalStore,
            dispatchRegistry: registry)
        _ = try TatwoGoalRunDispatchLifecycle.finalize(
            contractID: contract.contractID,
            goalStore: goalStore,
            dispatchRegistry: registry)
        model.refreshSelectedWorkOSState(
            contractID: contract.contractID)
        for _ in 0..<160
            where model.selectedGoalRecord?.status != .passed
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let settled = try goalStore.requireIssuedContract(contract.contractID)
        let mapped = Set(settled.receipts.compactMap(\.satisfiesRequirementID))
        XCTAssertTrue(mapped.contains("contract-id"))
        XCTAssertTrue(mapped.contains("mode-budget"))
        XCTAssertTrue(mapped.contains("goal-cycle-seal"))
        XCTAssertTrue(mapped.contains("local-check"))
        XCTAssertTrue(mapped.contains("s-no-sub"))
        XCTAssertTrue(mapped.contains("cleanup-inventory"))
        XCTAssertFalse(settled.receipts.contains {
            $0.receiptID.hasPrefix("goal-judge-")
        })
        XCTAssertEqual(settled.status, .passed)

        model.endActiveGoal()

        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .passed)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertFalse(model.canJudgeAndCompleteActiveGoal)
    }

    @MainActor
    func testPlanToGoalInferredSingleModelTopologySettlesPersistedGoal()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-plan-goal-inferred-single-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchRegistry: registry,
            nativeRunner: RecordingNativeAgentRunner(),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        model.selectedEffort = .medium

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let objective =
            "建立 task_counter.py、README.md、test_task_counter.py 並完成 unittest"
        var plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: objective,
            sections: [
                .init(
                    title: "實作與驗收",
                    body:
                        "只建立三個指定檔案，完成純函式、CLI 與 unittest。"),
            ],
            sourceAssistantMessageID: UUID().uuidString)
        plan.updateDiscussion(
            objective: objective,
            sections: plan.sections)
        plan.confirm()
        XCTAssertTrue(model.persistPlanArtifact(plan))

        model.prompt = "/goal \(objective)"
        model.commitOrActivateGoalFromPrompt()
        for _ in 0..<160 where dispatch.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(dispatch.startCount, 1)
        XCTAssertTrue(model.messages.contains {
            $0.role == .user && $0.text.contains(objective)
        })

        dispatch.emit(.toolUse(ChatCLIActivity(
            text: "exec_command",
            rawType: "command_execution")))
        dispatch.emit(.output("已完成三個指定檔案與 unittest 驗證。"))
        dispatch.emit(.exit(0))
        for _ in 0..<160
            where model.selectedGoalRecord?.status != .passed
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        let run = try XCTUnwrap(
            registry.run(forContractID: contract.contractID))
        XCTAssertEqual(contract.mode, .s)
        XCTAssertEqual(run.records.count, 1)
        XCTAssertEqual(run.records.first?.identity, .lead)
        XCTAssertEqual(run.records.first?.status, .completed)
        XCTAssertTrue(
            run.records.first?.receiptID?.hasPrefix("chat-turn-") == true)

        let settled = try goalStore.requireIssuedContract(
            contract.contractID)
        let required: Set<String> = Set(
            contract.receiptRequirements
                .compactMap { requirement in
                    requirement.requiredForPass
                        ? requirement.id
                        : nil
                })
        let persisted: Set<String> = Set(
            settled.receipts.compactMap {
                $0.satisfiesRequirementID
            })
        XCTAssertEqual(settled.status, GoalRunStatus.passed)
        XCTAssertTrue(required.isSubset(of: persisted))
        XCTAssertFalse(settled.receipts.contains {
            $0.receiptID.hasPrefix("goal-judge-")
        })
        XCTAssertEqual(model.selectedWorkOSGoalStatusLabel, "passed")
        XCTAssertEqual(
            model.activeGoalStatusPresentationLabel,
            "目標已完成")
        XCTAssertEqual(model.activeGoalStepProgress.current, 5)
        XCTAssertEqual(model.activeGoalStepProgress.total, 5)

        let receiptCount = settled.receipts.count
        let recordCount = run.records.count
        dispatch.emit(.exit(0))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID)
                .receipts.count,
            receiptCount)
        XCTAssertEqual(
            try XCTUnwrap(
                registry.run(forContractID: contract.contractID))
                .records.count,
            recordCount)
    }

    @MainActor
    func testConfirmedPlanGoalExecutesPlanAndRejectsZeroToolSuccess()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-goal-execution-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchRegistry: registry,
            nativeRunner: RecordingNativeAgentRunner(),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        model.selectedEffort = .medium

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let originalRequest =
            "原始使用者需求：建立 task counter 並依確認後的 Plan 執行"
        let sourceAssistantMessageID = UUID().uuidString
        // Seed the canonical journal, not just its disposable UI projection.
        for message in [
            ChatMessage(role: .user, text: originalRequest),
            ChatMessage(
                id: sourceAssistantMessageID,
                role: .assistant,
                text: "已產生可確認的 Plan。"),
        ] {
            XCTAssertTrue(model.appendMessage(message))
        }
        let objective =
            "在 session-plan-goal-terra-r8 建立檔案並執行測試"
        let implementationBody =
            "建立 task_counter.py、README.md、test_task_counter.py，"
            + "再執行 python unittest 驗證。"
        let plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: objective,
            sections: [
                .init(
                    title: "實作與驗收",
                    body: implementationBody),
            ],
            sourceAssistantMessageID: sourceAssistantMessageID,
            planFlowSelection: .init(
                destination: .goal,
                collaboration: .singleModel,
                modelAssignment: .single,
                primaryModelID: "gpt-5.6-terra",
                auxiliaryModelCount: 0))
        XCTAssertTrue(model.persistPlanArtifact(plan))

        model.confirmActivePlan()
        for _ in 0..<160 where dispatch.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(dispatch.startCount, 1)
        let executionPrompt = try XCTUnwrap(
            dispatch.nativePrompts.last)
        XCTAssertTrue(executionPrompt.contains("直接實作"))
        XCTAssertTrue(executionPrompt.contains("不要重新規劃"))
        XCTAssertTrue(executionPrompt.contains(implementationBody))
        XCTAssertFalse(
            model.isPlanModeEnabled,
            "accepted confirmed-Plan execution must leave Plan interaction semantics before runner start")
        XCTAssertEqual(
            model.messages.filter { $0.role == .user }.map(\.text),
            [originalRequest])
        XCTAssertFalse(model.messages.contains {
            $0.role == .user && $0.text.contains(implementationBody)
        })
        XCTAssertEqual(model.activePlanArtifact?.state, .confirmed)
        XCTAssertEqual(model.activePlanArtifact?.objective, objective)
        XCTAssertEqual(
            model.activePlanArtifact?.sourceAssistantMessageID,
            sourceAssistantMessageID)
        let dispatchLivenessHint = model.composerHint ?? ""
        XCTAssertTrue(
            dispatchLivenessHint.contains(
                "App 尚未觀測到對應 runner liveness"),
            dispatchLivenessHint)
        XCTAssertTrue(
            dispatchLivenessHint.contains("不會提前宣告成功"),
            dispatchLivenessHint)
        XCTAssertFalse(
            dispatchLivenessHint.contains(
                "已送交 Work OS：正在執行已確認計畫。"),
            dispatchLivenessHint)
        XCTAssertEqual(
            model.planWorkOSLocalActionPresentation.phase,
            .dispatching)

        dispatch.emit(.output(
            "計畫：先建立三個檔案，再執行 unittest。"))
        dispatch.emit(.exit(0))
        try await Task.sleep(nanoseconds: 250_000_000)

        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        let run = try XCTUnwrap(
            registry.run(forContractID: contract.contractID))
        XCTAssertEqual(run.records.count, 1)
        XCTAssertEqual(run.records.first?.status, .failed)
        XCTAssertEqual(
            run.records.first?.failureReceipt?.errorCode,
            "operational_failure")
        XCTAssertTrue(
            run.records.first?.failureReceipt?.operatorMessage
                .contains("without tool execution evidence") == true)
        XCTAssertNotEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .passed)
        XCTAssertNotEqual(
            model.activeGoalStatusPresentationLabel,
            "目標已完成")
        XCTAssertTrue(model.messages.contains {
            $0.role == .assistant
                && $0.eventKind == .failure
                && $0.text.contains("本輪沒有工具執行證據")
        })
    }

    @MainActor
    func testConfirmedPlanQueuedExecutionKeepsFullCommandWithoutUserEcho()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-queued-hidden-echo-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchRegistry: registry,
            nativeRunner: RecordingNativeAgentRunner(),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        model.selectedEffort = .medium

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let originalRequest =
            "原始需求：依已確認 Plan 完成 queue-safe execution"
        let executionBody =
            "完整執行 queue-safe-plan-marker，並保留 runner command。"
        let executionPrompt = """
        依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃。

        # Plan
        \(executionBody)
        """
        let sourceAssistantMessageID = UUID().uuidString
        model.messages = [
            ChatMessage(role: .user, text: originalRequest),
            ChatMessage(
                id: sourceAssistantMessageID,
                role: .assistant,
                text: "已產生 queue-safe Plan。"),
        ]
        var plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: originalRequest,
            sections: [
                .init(title: "執行", body: executionBody),
            ],
            sourceAssistantMessageID: sourceAssistantMessageID)
        plan.confirm()
        XCTAssertTrue(model.persistPlanArtifact(plan))

        model.isRunning = true
        model.prompt = "/goal \(originalRequest)"
        model.commitOrActivateGoalFromPrompt(
            forceSingleModel: true,
            executionPromptOverride: executionPrompt)
        for _ in 0..<160 where model.queuedChatTurnCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "queued=\(model.queuedChatTurnCount)",
            "goal=\(model.selectedGoalRecord?.status.rawValue ?? "nil")",
        ].joined(separator: " ")
        XCTAssertEqual(model.queuedChatTurnCount, 1, diagnostic)
        let ticket = try XCTUnwrap(model.chatQueue.first)
        XCTAssertTrue(
            ticket.commandBaseTurn.contains(executionPrompt),
            diagnostic)
        XCTAssertTrue(ticket.visibleTurn.contains(executionPrompt), diagnostic)
        XCTAssertEqual(
            model.messages.filter { $0.role == .user }.map(\.text),
            [originalRequest],
            diagnostic)
        XCTAssertFalse(model.messages.contains {
            $0.role == .user && $0.text.contains("queue-safe-plan-marker")
        })
        XCTAssertEqual(
            model.composerHint,
            "已插入佇列；會在目前回覆結束後執行。",
            diagnostic)
        XCTAssertEqual(dispatch.startCount, 0, diagnostic)
        XCTAssertNil(model.activeSingleModelGoalDispatch, diagnostic)
        XCTAssertEqual(model.activePlanArtifact?.state, .confirmed, diagnostic)
        XCTAssertEqual(
            model.activePlanArtifact?.sourceAssistantMessageID,
            sourceAssistantMessageID,
            diagnostic)

        model.isRunning = false
        model.resumeQueuedChatTurns()
        for _ in 0..<160 where dispatch.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(dispatch.startCount, 1, diagnostic)
        XCTAssertTrue(
            try XCTUnwrap(dispatch.nativePrompts.last)
                .contains(executionPrompt),
            diagnostic)
        XCTAssertEqual(
            model.messages.filter { $0.role == .user }.map(\.text),
            [originalRequest],
            diagnostic)
        let contractID = try XCTUnwrap(
            model.selectedWorkOSContract?.contractID)
        XCTAssertEqual(
            try XCTUnwrap(
                registry.run(forContractID: contractID))
                .records.first?.status,
            .running)
    }

    @MainActor
    func testOrdinaryChatStillAppendsVisibleUserMessage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-ordinary-chat-visible-echo-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        model.newChat()
        let ordinaryRequest = "普通 chat 必須保留這一列 user message"
        model.prompt = ordinaryRequest

        XCTAssertTrue(model.submitCurrentChatTurn())
        for _ in 0..<160 where dispatch.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(dispatch.startCount, 1)
        XCTAssertTrue(model.messages.contains {
            $0.role == .user && $0.text == ordinaryRequest
        })
    }

    @MainActor
    func testExplicitWorkOSConfirmationGatePromptStagesPlanWithoutExecution()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-workos-confirmation-gate-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatch = RecordingChatDispatchService()
        var computerHostExecutionCount = 0
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer(),
            computerHostExecutor: { _, _, _, _ in
                computerHostExecutionCount += 1
                throw NSError(
                    domain: "unexpected-computer-host-execution",
                    code: 1)
            })
        model.newChat()
        let request = """
        現在允許執行一個瀏覽器任務：使用目前同一個 TATWO staging 的內建 Chromium 瀏覽器，預設以 Google 搜尋 OpenAI 官方 WebMCP 資訊，只採用 OpenAI 官方來源，整理三點摘要並附來源。請先建立或更新 Work OS Goal Contract、Context/Architecture 與 Plan，然後顯示可點擊的「送交 Work OS」確認入口；在該入口被點擊前不要啟動 runner。Plan 期間只顯示簡潔進度，逐步思考與工具活動必須收合在單一「思考中」區域。送交後完成 Plan→Goal／PLG→Work 閉環，並用內建 Chromium 實際完成搜尋。
        """
        model.prompt = request

        model.send()

        XCTAssertEqual(dispatch.startCount, 0)
        XCTAssertEqual(computerHostExecutionCount, 0)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.selectedDispatchRecords.isEmpty)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertTrue(model.isPlanModeEnabled)
        let artifact = try XCTUnwrap(model.activePlanArtifact)
        XCTAssertEqual(artifact.state, .discussing)
        XCTAssertEqual(artifact.objective, request)
        XCTAssertEqual(
            artifact.sections.map(\.title),
            [
                "Goal Contract",
                "Context / Architecture",
                "Plan",
                "Validation / Rollback",
            ])
        XCTAssertTrue(model.messages.contains {
            $0.role == .user && $0.text == request
        })
        XCTAssertFalse(model.messages.contains { $0.role == .assistant })

        // The round86 failure text cannot become an ordinary terminal reply:
        // no runtime owns a callback before confirmation, so even a stray
        // model event is inert and the local Plan gate stays authoritative.
        dispatch.emit(.output(
            "目前不能建立可點擊的送交 Work OS 入口；我已直接完成瀏覽摘要。"))
        dispatch.emit(.exit(0))
        XCTAssertEqual(dispatch.startCount, 0)
        XCTAssertEqual(computerHostExecutionCount, 0)
        XCTAssertEqual(model.activePlanArtifact?.planID, artifact.planID)
        XCTAssertEqual(model.activePlanArtifact?.state, .discussing)
        XCTAssertFalse(model.messages.contains {
            $0.role == .assistant
                && $0.text.contains("我已直接完成瀏覽摘要")
        })
    }

    @MainActor
    func testConfirmedPlanStructuredComputerHostBlockerSurvivesGenericHint() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-structured-blocker-preserved-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeComposerHintModel(root: root)
        let blocker =
            "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
            + " blocker_class=binding_failed"
            + " authority_source=app_mcp_runtime"
        model.planConfirmInFlight = true

        model.flashComposerHint(blocker)
        model.flashComposerHint("Runner 未啟動；請稍後再試。")

        XCTAssertEqual(model.composerHint, blocker)
    }

    @MainActor
    func testConfirmedPlanNewerStructuredComputerHostBlockerReplacesOlderOne() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-structured-blocker-replaced-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeComposerHintModel(root: root)
        let olderBlocker =
            "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
            + " blocker_class=binding_failed"
            + " authority_source=app_mcp_runtime"
        let newerBlocker =
            "Computer Host 尚未就緒：執行授權建立失敗。"
            + " blocker_class=approval_failed"
            + " authority_source=computer_host_approval"
        model.planConfirmInFlight = true

        model.flashComposerHint(olderBlocker)
        model.flashComposerHint(newerBlocker)

        XCTAssertEqual(model.composerHint, newerBlocker)
    }

    @MainActor
    func testStructuredComputerHostBlockerAllowsOrdinaryHintAfterConfirmationEnds() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-structured-blocker-ordinary-hint-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeComposerHintModel(root: root)
        let blocker =
            "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
            + " blocker_class=binding_failed"
            + " authority_source=app_mcp_runtime"
        model.planConfirmInFlight = true
        model.flashComposerHint(blocker)

        model.planConfirmInFlight = false
        model.flashComposerHint("普通提示")

        XCTAssertEqual(model.composerHint, "普通提示")
    }

    @MainActor
    func testNewPlanConfirmationInvalidatesStaleStructuredBlockerOwnership() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-structured-blocker-stale-retry-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeComposerHintModel(root: root)
        let staleBlocker =
            "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
            + " blocker_class=binding_failed"
            + " authority_source=app_mcp_runtime"
        model.planConfirmInFlight = true
        model.flashComposerHint(staleBlocker)
        model.planConfirmInFlight = false

        model.resetConfirmedPlanComputerHostBlockerHint()
        model.planConfirmInFlight = true
        model.flashComposerHint("正在確認計劃並啟動工作流程…")

        XCTAssertEqual(
            model.composerHint,
            "正在確認計劃並啟動工作流程…")
    }

    @MainActor
    func testContaminatedStructuredComputerHostBlockerIsNotRetained() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-structured-blocker-contaminated-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeComposerHintModel(root: root)
        let contaminated =
            "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
            + " blocker_class=binding_failed"
            + " authority_source=app_mcp_runtime"
            + "\n已送交 Work OS"
            + "\nendpoint=https://sensitive.example.invalid/mcp"
            + "\ntoken=tok_do_not_retain"
            + "\nsocket=/tmp/private.sock"
        model.planConfirmInFlight = true

        model.flashComposerHint(contaminated)
        model.flashComposerHint("Runner 未啟動；請稍後再試。")

        XCTAssertEqual(
            model.composerHint,
            "Runner 未啟動；請稍後再試。")
    }

    @MainActor
    func testStructuredComputerHostBlockerDoesNotLeakIntoNextUnrelatedTurn()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-structured-blocker-next-turn-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        model.newChat()
        let blocker =
            "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
            + " blocker_class=binding_failed"
            + " authority_source=app_mcp_runtime"
        model.planConfirmInFlight = true
        model.flashComposerHint(blocker)
        model.planConfirmInFlight = false
        let ordinaryRequest = "下一輪普通 chat 不得繼承上一輪 blocker"
        model.prompt = ordinaryRequest

        XCTAssertTrue(model.submitCurrentChatTurn())
        for _ in 0..<160 where dispatch.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(dispatch.startCount, 1)
        XCTAssertFalse(model.composerHint?.contains(
            "blocker_class=binding_failed") == true)
        XCTAssertTrue(model.messages.contains {
            $0.role == .user && $0.text == ordinaryRequest
        })
    }

    @MainActor
    func testConfirmedPlanPLGDispatchCarriesPlanArtifactIntoExecution()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-plg-execution-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let native = RecordingNativeAgentRunner()
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: native)
        model.newChat()
        let template = try XCTUnwrap(
            model.coworkTemplates.first(where: {
                $0.scenarioID
                    == TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLSolOpusScenarioID
            }))
        model.applyCoworkTemplate(template)

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let objective =
            "在目前工作區建立 counter.py 並執行測試"
        let implementationBody =
            "建立 counter.py 與 test_counter.py，執行 python -m unittest，"
            + "並以實際命令輸出作為驗收證據。"
        let plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: objective,
            sections: [
                .init(
                    title: "實作與驗收",
                    body: implementationBody),
            ],
            sourceAssistantMessageID: UUID().uuidString,
            planFlowSelection: .init(
                destination: .plg,
                collaboration: .multiModel,
                modelAssignment: .primarySecondary,
                primaryModelID: "gpt-5.6-sol",
                secondaryModelID: "opus-5",
                auxiliaryModelCount: 1))
        XCTAssertTrue(model.persistPlanArtifact(plan))

        model.confirmActivePlan()
        for _ in 0..<160 where native.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "plgError=\(model.plgError ?? "nil")",
            "phase=\(model.activePLGRun?.phase.rawValue ?? "nil")",
            "goal=\(model.selectedGoalRecord?.status.rawValue ?? "nil")",
            "nativeStarts=\(native.startCount)",
        ].joined(separator: " ")
        XCTAssertEqual(native.startCount, 1, diagnostic)
        XCTAssertEqual(model.activePlanArtifact?.state, .confirmed, diagnostic)
        XCTAssertNotEqual(model.activePLGRun?.phase, .planning, diagnostic)
        XCTAssertFalse(
            model.currentConversationWorkspaceURL().path
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            diagnostic)
        let executionPrompt = try XCTUnwrap(native.request?.prompt)
        XCTAssertTrue(executionPrompt.contains("直接實作"), diagnostic)
        XCTAssertTrue(executionPrompt.contains("不要重新規劃"), diagnostic)
        XCTAssertTrue(executionPrompt.contains("# Plan"), diagnostic)
        XCTAssertTrue(executionPrompt.contains(implementationBody), diagnostic)
        XCTAssertNotEqual(
            executionPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines),
            objective,
            "exact PLG runner must receive the canonical confirmed execution envelope, not the plain objective")
    }

    @MainActor
    func testConfirmedPlanGoalSingleModelExecutesNonDevelopmentPlanInsteadOfRestatingObjective()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-goal-single-browser-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchRegistry: registry,
            nativeRunner: RecordingNativeAgentRunner(),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        model.selectedEffort = .medium

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let objective =
            "用內建瀏覽器透過 Google 查找 OpenAI 官方 WebMCP 資訊"
        let executionBody =
            "開啟 Google、只採用 OpenAI 官方來源，最後整理三點摘要；"
            + "不要修改任何檔案。"
        let plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: objective,
            sections: [
                .init(
                    title: "瀏覽器執行與驗收",
                    body: executionBody),
            ],
            sourceAssistantMessageID: UUID().uuidString,
            planFlowSelection: .init(
                destination: .goal,
                collaboration: .singleModel,
                modelAssignment: .single,
                primaryModelID: "gpt-5.6-terra",
                auxiliaryModelCount: 0))
        XCTAssertTrue(model.persistPlanArtifact(plan))

        model.confirmActivePlan()
        for _ in 0..<160 where dispatch.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "goal=\(model.selectedGoalRecord?.status.rawValue ?? "nil")",
            "reason=\(model.selectedGoalRecord?.statusReason ?? "nil")",
            "state=\(model.selectedWorkOSStateMessage)",
            "dispatchStarts=\(dispatch.startCount)",
        ].joined(separator: " ")
        XCTAssertEqual(dispatch.startCount, 1, diagnostic)
        let contract = try XCTUnwrap(
            model.selectedWorkOSContract,
            diagnostic)
        let canonicalDispatchID = try XCTUnwrap(
            model.planWorkOSLocalActionPresentation.dispatchID,
            diagnostic)
        let canonicalRun = try XCTUnwrap(
            registry.run(forContractID: contract.contractID),
            diagnostic)
        XCTAssertEqual(
            canonicalRun.contractID,
            contract.contractID,
            diagnostic)
        XCTAssertEqual(canonicalRun.records.count, 1, diagnostic)
        let canonicalRecord = try XCTUnwrap(
            canonicalRun.records.first,
            diagnostic)
        XCTAssertEqual(canonicalRecord.id, canonicalDispatchID, diagnostic)
        XCTAssertEqual(
            canonicalRecord.contractID,
            contract.contractID,
            diagnostic)
        XCTAssertEqual(canonicalRecord.goalID, contract.goalID, diagnostic)
        XCTAssertEqual(canonicalRecord.status, .running, diagnostic)
        XCTAssertNil(canonicalRecord.receiptID, diagnostic)
        XCTAssertNil(canonicalRecord.failureReceipt, diagnostic)
        let executionPrompt = try XCTUnwrap(
            dispatch.nativePrompts.last)
        XCTAssertTrue(executionPrompt.contains("直接實作"), diagnostic)
        XCTAssertTrue(executionPrompt.contains("不要重新規劃"), diagnostic)
        XCTAssertTrue(executionPrompt.contains("瀏覽器操作"), diagnostic)
        XCTAssertTrue(executionPrompt.contains(executionBody), diagnostic)
        XCTAssertFalse(
            model.messages.contains(where: {
                $0.role == .user && $0.text.contains(executionBody)
            }),
            "確認後 Plan execution envelope 只能進 runner，不能把全文重貼到 transcript")
        XCTAssertTrue(
            model.messages.contains(where: {
                $0.role == .assistant
                    && $0.eventKind == .thinking
                    && $0.status == "completed|已送交 Work OS"
            }),
            "空 transcript 也必須建立可綁定的 canonical turn，並只公開收合後的 Work OS 狀態")
        XCTAssertEqual(
            model.messages.filter {
                $0.role == .assistant
                    && $0.eventKind == .thinking
                    && $0.status == "completed|已送交 Work OS"
            }.count,
            1,
            "成功 dispatch 只能建立一筆折疊後的 Work OS 狀態")
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: threadID
        ).stableKey
        let durableJournal = try ChatTranscriptJournalDiskStore(
            fileURL: root.appendingPathComponent("journal.json")
        ).load()
        let durableProjection =
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: threadKey,
                from: durableJournal)
        XCTAssertEqual(
            durableProjection.filter {
                $0.role == .assistant
                    && $0.eventKind == .thinking
                    && $0.status == "completed|已送交 Work OS"
            }.count,
            1,
            "durable journal 也只能有一筆折疊狀態")
        XCTAssertFalse(
            durableProjection.contains {
                $0.role == .user && $0.text.contains(executionBody)
            },
            "durable projection 不得洩漏 Plan execution body")
        let durableJSON = String(
            data: try JSONEncoder().encode(durableJournal),
            encoding: .utf8) ?? ""
        XCTAssertFalse(
            durableJSON.contains(executionBody),
            "raw journal 不得保存完整 Plan execution body")
        XCTAssertNotEqual(
            executionPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines),
            objective,
            "Goal + single model 必須送出已確認計畫的執行提示，不能再送原始目標讓模型重做一次 Plan")
    }

    @MainActor
    func testConfirmedPlanComputerHostBindingFailureDoesNotPublishWorkOSAnchor()
        async throws
    {
        let sensitiveFailure = """
        endpoint=https://sensitive.example.invalid/mcp \
        token=tok_live_do_not_publish \
        socket=/tmp/private-app-mcp.sock \
        route=secret-provider-route
        """
        let safeBlockerClass = "blocker_class=binding_failed"
        let safeAuthoritySource =
            "authority_source=app_mcp_runtime"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-computer-host-gate-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: root.appendingPathComponent("journal.json"))
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer(),
            appMCPRuntimeProvider: {
                .failed(sensitiveFailure)
            })
        model.newChat()
        model.setSingleModel("opus-5")

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let executionBody =
            "使用 Computer Use 操作內建瀏覽器，以 Google 搜尋官方資料。"
        let plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: "以內建瀏覽器完成官方資料查核",
            sections: [
                .init(title: "瀏覽器任務", body: executionBody),
            ],
            sourceAssistantMessageID: UUID().uuidString,
            planFlowSelection: .init(
                destination: .goal,
                collaboration: .singleModel,
                modelAssignment: .single,
                primaryModelID: "opus-5",
                auxiliaryModelCount: 0))
        XCTAssertTrue(model.persistPlanArtifact(plan))

        model.confirmActivePlan()
        for _ in 0..<240
        where model.composerHint?.contains(safeBlockerClass) != true
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(dispatch.startCount, 0)
        try await assertConfirmedPlanComputerHostBlockerSurvivesLegacyTimer(
            model: model,
            expectedBlockerClass: .bindingFailed,
            safeBlockerClass: safeBlockerClass)
        try assertComputerHostBlockerIsSafelyPublished(
            model: model,
            journalStore: journalStore,
            threadID: threadID,
            safeBlockerClass: safeBlockerClass,
            safeAuthoritySource: safeAuthoritySource,
            forbiddenFragments: [
                sensitiveFailure,
                "https://sensitive.example.invalid/mcp",
                "tok_live_do_not_publish",
                "/tmp/private-app-mcp.sock",
                "secret-provider-route",
            ],
            executionBody: executionBody)
    }

    @MainActor
    func testConfirmedPlanComputerHostApprovalFailureDoesNotPublishRawError()
        async throws
    {
        let sensitiveError = """
        approval endpoint=https://approval.example.invalid \
        token=tok_approval_do_not_publish \
        socket=/tmp/private-approval.sock \
        route=secret-approval-route
        """
        let safeBlockerClass = "blocker_class=approval_failed"
        let safeAuthoritySource =
            "authority_source=computer_host_approval"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-computer-host-approval-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: root.appendingPathComponent("journal.json"))
        let dispatch = RecordingChatDispatchService()
        let endpoint = try XCTUnwrap(
            TatwoAppMCPEndpoint(
                urlString: "http://127.0.0.1:19457"))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer(),
            appMCPRuntimeProvider: {
                .ready(endpoint)
            },
            computerHostApprovalLeaseIssuer: { _, _ in
                throw NSError(
                    domain: "ChatNativeAgentRoutingTests",
                    code: 73,
                    userInfo: [
                        NSLocalizedDescriptionKey: sensitiveError,
                    ])
            })
        model.newChat()
        model.setSingleModel("opus-5")

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let executionBody =
            "使用 Computer Use 操作內建瀏覽器，以 Google 搜尋官方資料。"
        let plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective: "以內建瀏覽器完成官方資料查核",
            sections: [
                .init(title: "瀏覽器任務", body: executionBody),
            ],
            sourceAssistantMessageID: UUID().uuidString,
            planFlowSelection: .init(
                destination: .goal,
                collaboration: .singleModel,
                modelAssignment: .single,
                primaryModelID: "opus-5",
                auxiliaryModelCount: 0))
        XCTAssertTrue(model.persistPlanArtifact(plan))

        model.confirmActivePlan()
        for _ in 0..<240
        where model.composerHint?.contains(safeBlockerClass) != true
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(dispatch.startCount, 0)
        try await assertConfirmedPlanComputerHostBlockerSurvivesLegacyTimer(
            model: model,
            expectedBlockerClass: .approvalFailed,
            safeBlockerClass: safeBlockerClass)
        try assertComputerHostBlockerIsSafelyPublished(
            model: model,
            journalStore: journalStore,
            threadID: threadID,
            safeBlockerClass: safeBlockerClass,
            safeAuthoritySource: safeAuthoritySource,
            forbiddenFragments: [
                sensitiveError,
                "https://approval.example.invalid",
                "tok_approval_do_not_publish",
                "/tmp/private-approval.sock",
                "secret-approval-route",
            ],
            executionBody: executionBody)
    }

    @MainActor
    func testConfirmedPlanDeferredBoundaryDoesNotAwaitReplacementQueuedTask()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-bound-task-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let sessionStore = TatwoSessionStore(
            directoryURL: goalStore.directoryURL)
        let dispatchRegistry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let threadID = UUID()
        let objective = "以確認後計畫完成安全瀏覽器查核"
        let proposedContract = try WorkOSFactory.projectContract(
            mode: .s,
            scenarioProfileID: "coding",
            objective: objective)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: goalStore.directoryURL,
            contractID: proposedContract.contractID)
        let attachment = try sessionStore.beginCurrent(
            mode: .s,
            scenarioProfileID: "coding",
            objective: objective,
            owner: TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread(threadID.uuidString.lowercased()),
                workspacePath:
                    TatwoRuntimeLayout.applicationSupportRoot()
                        .appendingPathComponent(
                            "chat-workspace",
                            isDirectory: true)
                        .standardizedFileURL.path),
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        let contract = attachment.contract
        let thread = TatwoNativeChatThread(
            id: threadID,
            title: "confirmed Plan deferred boundary identity",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            loopsConfig: TatwoNativeThreadLoopsConfig(
                scenarioID: "coding",
                mode: .s,
                identitySummary:
                    "confirmed Plan deferred boundary fixture",
                tokenBudget: "focused fixture"),
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID,
            selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                identity: TatwoObjectiveIdentity.make(
                    contract.objective)))
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: root.appendingPathComponent(
                "remote-authorization",
                isDirectory: true))
        let sessionID = thread.id.uuidString.lowercased()
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: sessionID,
            targetDeviceID: "replacement-boundary-target",
            contractID: contract.contractID,
            now: Date())
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: root.appendingPathComponent(
                "pending-remote-target.json"))
        _ = try pendingStore.arm(
            grant: grant,
            goalID: contract.goalID,
            targetDisplayName: "Mac mini")
        let dispatcher =
            BlockingReplacementRemoteTurnDispatcher()
        defer { dispatcher.releaseReplacement() }
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: dispatchRegistry,
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher,
            nativeRunner: RecordingNativeAgentRunner())
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord =
            try goalStore.requireIssuedContract(contract.contractID)
        let confirmedRouteID = try XCTUnwrap(
            contract.identityBindings.first(where: {
                $0.identity == .lead
            })?.modelID)
        model.setSingleModel(
            confirmedRouteID,
            syncCollaborationLead: false)

        model.beginConfirmedPlanConfirmationBoundary()
        model.prompt = """
        依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃、不要只重述計畫。
        必須使用可用工具直接執行計畫；只有計畫明確要求時才修改檔案，並實際完成計畫中的測試、瀏覽器操作或其他驗證。
        若受到權限、環境或需求阻塞，請明確回報阻塞；沒有工具執行與驗證證據時不得宣稱完成。

        # Plan
        使用 Computer Use 操作內建瀏覽器，以 Google 搜尋官方資料。
        """
        XCTAssertTrue(
            model.submitCurrentChatTurn(
                applyPromptCollaboration: false,
                suppressUserEcho: true))
        XCTAssertTrue(model.isRunning)

        model.prompt = "下一個排隊回合必須保持 blocked，不能成為 Plan boundary 的等待物。"
        XCTAssertTrue(
            model.submitCurrentChatTurn(
                applyPromptCollaboration: false))
        XCTAssertEqual(model.queuedChatTurnCount, 1)

        for _ in 0..<240 where dispatcher.requestCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(
            dispatcher.requestCount,
            2,
            "queued replacement remote task never reached its blocking dispatcher")
        XCTAssertTrue(
            dispatcher.replacementIsBlocked,
            "replacement task must remain blocked while the Plan boundary is checked")

        let boundaryReturned = expectation(
            description:
                "confirmed Plan boundary returns without awaiting replacement")
        Task { @MainActor in
            await model.awaitConfirmedPlanDeferredStartBoundaryIfNeeded()
            boundaryReturned.fulfill()
        }
        await fulfillment(of: [boundaryReturned], timeout: 1)

        let awaited = try XCTUnwrap(
            model.confirmedPlanComputerHostBlockerHintTrace.last(where: {
                $0.event == .deferredStartBoundaryAwaited
            }))
        XCTAssertEqual(
            awaited.deferredRemoteTurnGeneration,
            1,
            "boundary trace must stay bound to the original confirmed turn")
        XCTAssertNotNil(awaited.deferredBoundaryIdentity)
        XCTAssertNotNil(awaited.confirmationGeneration)
        XCTAssertFalse(awaited.deferredBoundaryCancelled ?? true)
        XCTAssertTrue(
            dispatcher.replacementIsBlocked,
            "boundary returned only because it did not await the queued replacement")

        dispatcher.releaseReplacement()
        for _ in 0..<240 where model.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        model.planConfirmInFlight = false
        model.finishConfirmedPlanConfirmationBoundary()
    }

    @MainActor
    func testComputerHostExecutionFailureDoesNotPublishRawError()
        async throws
    {
        let sensitiveError = """
        execution endpoint=https://execution.example.invalid \
        token=tok_execution_do_not_publish \
        socket=/tmp/private-execution.sock \
        route=secret-execution-route
        """
        let safeBlockerClass = "blocker_class=host_execution_failed"
        let safeAuthoritySource =
            "authority_source=computer_host_runtime"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-computer-host-execution-failure-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let threadID = UUID()
        let request = "請使用 Computer Use 開啟 Finder。"
        let prefix = String(threadID.uuidString.prefix(8)).lowercased()
        let contractObjective =
            "Tatwo Chat request: \(request) [\(prefix)]"
        let topology = TatwoNativeThreadLoopsConfig(
            scenarioID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            mode: .xxl,
            identitySummary: "computer host execution redaction",
            tokenBudget: "focused fixture",
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: "opus-5")
        let proposedContract = try WorkOSFactory.projectContract(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: contractObjective)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: goalStore.directoryURL,
            contractID: proposedContract.contractID)
        let dispatchRegistry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let attachment = try TatwoSessionStore(
            directoryURL: goalStore.directoryURL
        ).beginCurrent(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: contractObjective,
            owner: TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread(threadID.uuidString.lowercased()),
                workspacePath:
                    TatwoRuntimeLayout.applicationSupportRoot()
                        .appendingPathComponent(
                            "chat-workspace",
                            isDirectory: true)
                        .standardizedFileURL.path),
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        let contract = attachment.contract
        let thread = TatwoNativeChatThread(
            id: threadID,
            title: "computer host execution redaction",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            loopsConfig: topology,
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID,
            selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                identity: TatwoObjectiveIdentity.make(contractObjective)))
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: root.appendingPathComponent("journal.json"))
        let dispatch = RecordingChatDispatchService()
        var computerHostExecutionCount = 0
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: journalStore,
            goalRunStore: goalStore,
            dispatchRegistry: dispatchRegistry,
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer(),
            computerHostExecutor: { _, _, _, _ in
                computerHostExecutionCount += 1
                throw NSError(
                    domain: "ChatNativeAgentRoutingTests",
                    code: 74,
                    userInfo: [
                        NSLocalizedDescriptionKey: sensitiveError,
                    ])
            })
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.setSingleModel(
            "gpt-5.6-sol",
            syncCollaborationLead: false)
        model.prompt = request

        let accepted = model.submitCurrentChatTurn()
        let submitDiagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "state=\(model.selectedWorkOSStateMessage)",
            "selectedContract=\(model.selectedWorkOSContract?.contractID ?? "nil")",
            "threadContract=\(model.selectedThread?.workOSContractID ?? "nil")",
            "threadGoal=\(model.selectedThread?.workOSGoalID ?? "nil")",
            "scenario=\(model.selectedThread?.loopsConfig?.scenarioID ?? "nil")",
            "mode=\(model.selectedThread?.loopsConfig?.mode.rawValue ?? "nil")",
        ].joined(separator: " ")
        XCTAssertTrue(accepted, submitDiagnostic)
        for _ in 0..<160 where dispatch.startCount == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(dispatch.startCount, 1, submitDiagnostic)

        dispatch.emit(.output("""
        <TATWO_COMPUTER_ACTION>{"schema":"TatwoComputerActionV1","action":"open_app","value":"Finder"}</TATWO_COMPUTER_ACTION>
        """))
        for _ in 0..<160
        where model.composerHint?.contains(safeBlockerClass) != true
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(computerHostExecutionCount, 1)

        try assertComputerHostBlockerIsSafelyPublished(
            model: model,
            journalStore: journalStore,
            threadID: thread.id,
            safeBlockerClass: safeBlockerClass,
            safeAuthoritySource: safeAuthoritySource,
            forbiddenFragments: [
                sensitiveError,
                "https://execution.example.invalid",
                "tok_execution_do_not_publish",
                "/tmp/private-execution.sock",
                "secret-execution-route",
            ],
            executionBody:
                "PRIVATE FULL PLAN BODY MUST NEVER ENTER EXECUTION FAILURE SURFACES")
    }

    @MainActor
    func testConfirmedPlanPendingNativePreparationFailureDoesNotPublishWorkOSAnchor()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-confirmed-plan-native-preparation-gate-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "依確認後 Plan 修改 ChatPageModel 並執行測試",
            store: goalStore)
        let conflictingDispatch =
            try TatwoNativeDevelopmentDispatchCoordinator
                .beginSelectedExecutor(
                    contract: contract,
                    selectedModelID: "opus-5",
                    subtask: "不同 model 的既有 pending dispatch",
                    goalStore: goalStore,
                    dispatchRegistry: registry)
        let thread = TatwoNativeChatThread(
            title: "confirmed plan native preparation gate",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: root.appendingPathComponent("journal.json"))
        let dispatch = RecordingChatDispatchService()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: journalStore,
            goalRunStore: goalStore,
            dispatchRegistry: registry,
            nativeRunner: RecordingNativeAgentRunner(),
            dispatchService: dispatch,
            runtimeEventReducer: DefaultChatRuntimeEventReducer())
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.pendingNativeDevelopmentDispatch = conflictingDispatch
        model.setSingleModel(
            "gpt-5.6-sol",
            syncCollaborationLead: false)

        let executionBody =
            "修改 ChatPageModel.swift 的 dispatch gate，並執行 focused Swift tests。"
        let executionPrompt = """
        依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃、不要只重述計畫。
        必須使用可用工具直接執行計畫；只有計畫明確要求時才修改檔案，並實際完成計畫中的測試、瀏覽器操作或其他驗證。
        若受到權限、環境或需求阻塞，請明確回報阻塞；沒有工具執行與驗證證據時不得宣稱完成。

        # Plan
        \(executionBody)
        """
        model.prompt = executionPrompt

        XCTAssertFalse(
            model.submitCurrentChatTurn(suppressUserEcho: true))
        XCTAssertEqual(dispatch.startCount, 0)
        XCTAssertTrue(
            model.composerHint?.contains(
                "已有不同 contract／model 的 pending dispatch") == true,
            model.composerHint ?? "native preparation failure was silent")
        XCTAssertFalse(model.messages.contains {
            $0.text.contains("已送交 Work OS")
                || $0.status?.contains("已送交 Work OS") == true
        })
        XCTAssertFalse(model.messages.contains {
            $0.text.contains(executionBody)
                || $0.status?.contains(executionBody) == true
        })

        let journal = try journalStore.load()
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let projection = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: threadKey,
            from: journal)
        XCTAssertFalse(projection.contains {
            $0.text.contains("已送交 Work OS")
                || $0.status?.contains("已送交 Work OS") == true
        })
        XCTAssertFalse(projection.contains {
            $0.text.contains(executionBody)
                || $0.status?.contains(executionBody) == true
        })
        let rawJournal = String(
            data: try JSONEncoder().encode(journal),
            encoding: .utf8) ?? ""
        XCTAssertFalse(rawJournal.contains("已送交 Work OS"))
        XCTAssertFalse(rawJournal.contains(executionBody))
    }

    @MainActor
    func testSwitchingChatRowsParksRunningTurnAndIsolatesComposerState()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-dual-session-park-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
        model.newChat()
        let first = try XCTUnwrap(model.selectedThreadID)
        model.isRunning = true
        model.prompt = "first-thread-draft"
        model.newChat()
        let second = try XCTUnwrap(
            model.document.threads.first { $0.id != first }?.id)
        XCTAssertNotEqual(first, second)

        model.selectStandaloneThread(second)
        XCTAssertEqual(model.selectedThreadID, second)
        XCTAssertFalse(model.isRunning)
        XCTAssertNotEqual(model.prompt, "first-thread-draft")

        model.isRunning = true
        model.prompt = "second-thread-draft"
        model.selectStandaloneThread(first)
        XCTAssertEqual(model.selectedThreadID, first)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.prompt, "first-thread-draft")

        model.selectStandaloneThread(second)
        XCTAssertEqual(model.selectedThreadID, second)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.prompt, "second-thread-draft")
    }

    @MainActor
    func testStructuredComputerHostBlockerDoesNotCrossThreadSelectionBoundary()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-structured-blocker-thread-boundary-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeComposerHintModel(root: root)
        model.newChat()
        let first = try XCTUnwrap(model.selectedThreadID)
        model.newChat()
        let second = try XCTUnwrap(
            model.document.threads.first { $0.id != first }?.id)
        model.selectStandaloneThread(first)
        let blocker =
            "Computer Host 尚未就緒：App MCP listener 綁定失敗。"
            + " blocker_class=binding_failed"
            + " authority_source=app_mcp_runtime"
        model.planConfirmInFlight = true
        model.flashComposerHint(blocker)
        model.planConfirmInFlight = false
        let ownerSnapshot = try XCTUnwrap(
            model.confirmedPlanComputerHostBlockerHintTrace.last(where: {
                $0.event == .structuredPublish
            }))

        model.selectStandaloneThread(second)

        XCTAssertEqual(model.selectedThreadID, second)
        XCTAssertFalse(
            model.composerHint?.contains(
                "blocker_class=binding_failed") == true)
        let boundarySnapshot = try XCTUnwrap(
            model.confirmedPlanComputerHostBlockerHintTrace.last(where: {
                $0.event == .sessionBoundaryClear
            }))
        XCTAssertNil(boundarySnapshot.pendingBlockerClass)
        XCTAssertNil(boundarySnapshot.visibleBlockerClass)
        XCTAssertNil(boundarySnapshot.ownerGeneration)
        XCTAssertGreaterThan(
            boundarySnapshot.clearGeneration,
            ownerSnapshot.clearGeneration)
    }

    @MainActor
    private func assertConfirmedPlanComputerHostBlockerSurvivesLegacyTimer(
        model: ChatPageModel,
        expectedBlockerClass:
            ConfirmedPlanComputerHostBlockerHintTraceEntry.BlockerClass,
        safeBlockerClass: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<240 where model.planConfirmInFlight {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(
            model.planConfirmInFlight,
            "confirmed-Plan async boundary did not release",
            file: file,
            line: line)
        XCTAssertTrue(
            model.isPlanModeEnabled,
            "a rejected direct start must restore Plan mode for retry",
            file: file,
            line: line)
        XCTAssertEqual(
            model.activePlanArtifact?.state,
            .discussing,
            "a rejected direct start must reopen the confirmed artifact",
            file: file,
            line: line)

        let traceAtBoundary =
            model.confirmedPlanComputerHostBlockerHintTrace
        let deferredBoundarySnapshot = traceAtBoundary.last(where: {
                $0.event == .deferredStartBoundaryAwaited
            })
        XCTAssertNotNil(
            deferredBoundarySnapshot,
            "confirmed-Plan fixture did not cross the real deferred remote-claim start boundary",
            file: file,
            line: line)
        let boundarySnapshot = traceAtBoundary.last(where: {
            $0.event == .boundaryRepublish
        })
        let releasedSnapshot = traceAtBoundary.last(where: {
            $0.event == .confirmationReleased
        })
        XCTAssertEqual(
            boundarySnapshot?.visibleBlockerClass,
            expectedBlockerClass,
            "boundary republish did not own the safe blocker",
            file: file,
            line: line)
        XCTAssertEqual(
            releasedSnapshot?.visibleBlockerClass,
            expectedBlockerClass,
            "released confirmation lost the safe blocker",
            file: file,
            line: line)
        XCTAssertFalse(
            releasedSnapshot?.planConfirmInFlight ?? true,
            "released snapshot still reports confirmation in flight",
            file: file,
            line: line)
        XCTAssertEqual(
            releasedSnapshot?.ownerGeneration,
            releasedSnapshot?.clearGeneration,
            "released blocker ownership is not generation-bound",
            file: file,
            line: line)
        XCTAssertNotNil(
            deferredBoundarySnapshot?.deferredBoundaryIdentity,
            "deferred boundary trace lacks its acceptance-bound identity",
            file: file,
            line: line)
        XCTAssertNotNil(
            deferredBoundarySnapshot?.deferredRemoteTurnGeneration,
            "deferred boundary trace lacks its remote-turn generation",
            file: file,
            line: line)
        XCTAssertEqual(
            deferredBoundarySnapshot?.confirmationGeneration,
            releasedSnapshot?.confirmationGeneration,
            "deferred boundary trace is not bound to the released confirmation generation",
            file: file,
            line: line)
        XCTAssertEqual(
            deferredBoundarySnapshot?.deferredBoundaryCancelled,
            false,
            "successful Computer Host failure publication was mislabeled as cancellation",
            file: file,
            line: line)
        XCTAssertTrue(
            traceAtBoundary.contains(where: {
                $0.event == .timerAutoClearSuppressed
                    && $0.visibleBlockerClass == expectedBlockerClass
            }),
            "safe blocker did not suppress the transient timer",
            file: file,
            line: line)

        let traceCountBeforeLegacyDeadline = traceAtBoundary.count
        try await Task.sleep(nanoseconds: 7_250_000_000)

        XCTAssertTrue(
            model.composerHint?.contains(safeBlockerClass) == true,
            "safe blocker disappeared at the legacy seven-second deadline",
            file: file,
            line: line)
        XCTAssertFalse(
            model.confirmedPlanComputerHostBlockerHintTrace
                .dropFirst(traceCountBeforeLegacyDeadline)
                .contains(where: {
                    $0.event == .timerClear
                        && $0.visibleBlockerClass == expectedBlockerClass
                }),
            "legacy timer cleared the safe blocker",
            file: file,
            line: line)
    }

    @MainActor
    private func assertComputerHostBlockerIsSafelyPublished(
        model: ChatPageModel,
        journalStore: ChatTranscriptJournalDiskStore,
        threadID: UUID,
        safeBlockerClass: String,
        safeAuthoritySource: String,
        forbiddenFragments: [String],
        executionBody: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let hint = model.composerHint ?? ""
        let memoryRows = model.messages
        let projectedRows = model.transcriptMessages
        let journal = try journalStore.load()
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: threadID
        ).stableKey
        let durableRows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: threadKey,
            from: journal)
        let rawJournal = String(
            data: try JSONEncoder().encode(journal),
            encoding: .utf8) ?? ""
        let surfaces: [(name: String, content: String)] = [
            ("composer", hint),
            (
                "memory",
                memoryRows.map {
                    "\($0.text)\n\($0.status ?? "")"
                }.joined(separator: "\n")
            ),
            (
                "projected",
                projectedRows.map {
                    "\($0.text)\n\($0.status ?? "")"
                }.joined(separator: "\n")
            ),
            (
                "durable",
                durableRows.map {
                    "\($0.text)\n\($0.status ?? "")"
                }.joined(separator: "\n")
            ),
            ("raw journal", rawJournal),
        ]

        for surface in surfaces {
            XCTAssertTrue(
                surface.content.contains(safeBlockerClass),
                "safe blocker class missing from \(surface.name) surface",
                file: file,
                line: line)
            XCTAssertTrue(
                surface.content.contains(safeAuthoritySource),
                "exact authority source missing from \(surface.name) surface",
                file: file,
                line: line)
            XCTAssertFalse(
                surface.content.contains("已送交 Work OS"),
                "premature Work OS success anchor escaped into \(surface.name) surface",
                file: file,
                line: line)
            XCTAssertFalse(
                surface.content.contains(executionBody),
                "Plan execution body escaped into \(surface.name) surface",
                file: file,
                line: line)
            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    surface.content.contains(fragment),
                    "sensitive runtime detail escaped into \(surface.name) surface: \(fragment)",
                    file: file,
                    line: line)
            }
        }
    }

    @MainActor
    func testDirectPLGStartOnFreshThreadCreatesRunAndSubmitsFirstRound()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-direct-fresh-plg-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
        model.newChat()
        model.isRunning = true
        let objective = "在 calc.py 加 divide 函式"

        let started = await model.startPLGRun(objective: objective)
        XCTAssertTrue(
            started,
            [
                "hint=\(model.composerHint ?? "nil")",
                "plgError=\(model.plgError ?? "nil")",
                "state=\(model.selectedWorkOSStateMessage)",
            ].joined(separator: " "))
        model.prompt = objective
        model.submitCurrentChatTurn(applyPromptCollaboration: false)

        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "plgError=\(model.plgError ?? "nil")",
            "state=\(model.selectedWorkOSStateMessage)",
        ].joined(separator: " ")
        XCTAssertNotNil(model.selectedThread?.workOSGoalID, diagnostic)
        XCTAssertNotNil(model.selectedGoalRecord, diagnostic)
        XCTAssertEqual(model.activePLGRun?.phase, .planning, diagnostic)
        XCTAssertEqual(model.queuedChatTurnCount, 1, diagnostic)
        XCTAssertEqual(model.prompt, "", diagnostic)
    }

    @MainActor
    func testDedicatedCollaborationGoalBlockKeepsPromptAndShowsReason()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-dedicated-goal-block-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
        let topology = TatwoNativeThreadLoopsConfig(
            scenarioID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            mode: .xxl,
            identitySummary: "dedicated collaboration topology",
            tokenBudget: "existing",
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: "opus-5")
        let source = TatwoNativeChatThread(
            title: "existing collaboration",
            sourceMarker:
                TatwoNativeChatThreadSourceMarker.userOwned,
            loopsConfig: topology)
        model.document = TatwoNativeChatStoreDocument(
            threads: [source])
        model.selectedThreadID = source.id
        model.newChat()
        XCTAssertNil(model.selectedThread?.sourceMarker)
        XCTAssertEqual(model.selectedThread?.loopsConfig, topology)

        let request = "/goal 在 calc.py 加 divide 函式"
        model.prompt = request
        model.commitOrActivateGoalFromPrompt()
        for _ in 0..<160
        where model.authorityBootstrapModel.pendingProposal == nil
            && model.composerHint == nil
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(model.prompt, request)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertEqual(model.queuedChatTurnCount, 0)
        XCTAssertNotNil(model.authorityBootstrapModel.pendingProposal)
        XCTAssertTrue(
            model.composerHint?.contains(
                "authority-lock bootstrap") == true,
            model.composerHint
                ?? "dedicated collaboration block was silent")
    }

    @MainActor
    func testConfirmedFreshNativeGoalStartsSelectedOpusMutationRuntime()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-fresh-opus-goal-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let native = RecordingNativeAgentRunner()
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: native)
        model.newChat()
        model.setSingleModel("opus-5")
        let request =
            "/goal 只重做 TATWO Island 的液態玻璃底板濾鏡，對照本機 macOS 27 原生 Liquid Glass 逐輪截圖校正，直到材質、透光、模糊、折射、高光與收合動畫一致。保留現有 Island 互動、Ultrawork 漸變拉條與 Fable 5 紀念主題，不做其他改動。"

        model.prompt = request
        model.send()
        for _ in 0..<160
        where model.selectedThread?.loopsConfig?.scenarioID
            != TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(model.authorityBootstrapModel.pendingProposal)
        XCTAssertEqual(
            model.selectedThread?.loopsConfig?.scenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID)
        XCTAssertEqual(
            model.currentTurnDispatchRoute().canonicalModelSlug,
            "opus-5")

        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let dispatch = try XCTUnwrap(
            model.selectedDispatchRecords.first {
                $0.id == native.request?.dispatchID
            })
        let snapshot = ChatTurnContractEffortResolver.resolve(
            route: model.currentTurnDispatchRoute(),
            phase: .loops,
            contract: try XCTUnwrap(model.selectedWorkOSContract),
            uiSelectedEffort: .high)
        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "scenario=\(model.selectedWorkOSContract?.scenario ?? "nil")",
            "goalStatus=\(model.selectedGoalRecord?.status.rawValue ?? "nil")",
            "plgPhase=\(model.activePLGRun?.phase.rawValue ?? "nil")",
            "nativeStarts=\(native.startCount)",
            "blocker=\(model.lastNativeRuntimeStartBlocker ?? "nil")",
            "dispatches=\(model.selectedDispatchRecords.map { "\($0.id):\($0.status.rawValue):\($0.modelID)" })",
        ].joined(separator: " ")
        XCTAssertEqual(
            snapshot.contractBindingID, dispatch.sourceSlotID, diagnostic)
        XCTAssertNotEqual(
            snapshot.contractBindingID, dispatch.bindingID, diagnostic)
        XCTAssertNotEqual(
            model.lastNativeRuntimeStartBlocker,
            "mutation_dispatch_missing",
            diagnostic)
        XCTAssertEqual(
            model.selectedWorkOSContract?.scenario,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
            diagnostic)
        XCTAssertEqual(model.selectedGoalRecord?.status, .running, diagnostic)
        XCTAssertEqual(native.startCount, 1, diagnostic)
        XCTAssertEqual(native.request?.modelID, "opus-5", diagnostic)
        XCTAssertEqual(native.request?.effort, "high", diagnostic)
        XCTAssertFalse(try XCTUnwrap(native.request).readOnly, diagnostic)
        XCTAssertNotNil(native.request?.dispatchID, diagnostic)
        XCTAssertTrue(
            model.selectedDispatchRecords.contains {
                $0.id == native.request?.dispatchID
                    && $0.status == .running
                    && $0.modelID == "opus-5"
            },
            diagnostic)
    }

    @MainActor
    func testPLGPromptOnFreshUserOwnedThreadCreatesPlanningRunAndFirstRound()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-fresh-plg-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())

        let commandCenter = TatwoNewChatCommandCenter()
        let registration = commandCenter.register {
            model.newChat()
        }
        defer { commandCenter.unregister(registration) }
        commandCenter.request()
        let threadID = try XCTUnwrap(model.selectedThreadID)
        XCTAssertEqual(
            model.selectedThread?.sourceMarker,
            TatwoNativeChatThreadSourceMarker.userOwned)
        model.isRunning = true

        model.prompt = "/plg 建立 fresh App 原生開發閉環"
        model.send()
        for _ in 0..<160 where model.activePLGRun == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(model.document.threads.count, 1)
        XCTAssertEqual(
            model.selectedThread?.loopsConfig?.scenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
            "A fresh /plg development request must bind the native Sol/Opus scenario before authority bootstrap or contract issuance.")
        XCTAssertEqual(
            model.currentTurnDispatchRoute().canonicalModelSlug,
            TatwoNativeDevelopmentDispatchCoordinator.solModelID)
        XCTAssertEqual(model.activePLGRun?.phase, .planning)
        XCTAssertNotNil(model.selectedThread?.workOSGoalID)
        XCTAssertEqual(model.queuedChatTurnCount, 1)
        XCTAssertEqual(model.prompt, "")
        XCTAssertNil(model.authorityBootstrapModel.pendingProposal)
    }

    /// 2026-08-27 staging67 exact regression:
    ///
    /// fresh project thread → Terra medium / standard → Ultrawork Off →
    /// completed `/plan` + clarification → `/plg`.
    ///
    /// The Plan objective is development-shaped, but that classification is
    /// not topology authority. It must not restore the app-wide XXL preset or
    /// its stale role assignments before contract initialization.
    @MainActor
    func testCompletedPlanOnFreshProjectThreadDoesNotResurrectStaleXXLForPLG()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-plan-plg-off-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let native = RecordingNativeAgentRunner()
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: native)
        let projectID = UUID()
        let threadID = UUID()
        let projectWorkdir =
            "\(NSHomeDirectory())/Library/Application Support/tatwo2/runtime/sandbox/test/session-plan-plg-terra-r4"
        let providerSessionID = "01a043e4-e96d-7352-ae8b-4596636b1860"
        let thread = TatwoNativeChatThread(
            id: threadID,
            title: "fresh project plan",
            codexCLISessionID: providerSessionID,
            sourceMarker: nil,
            adapterSessionHandles: [
                TatwoNativeAdapterSessionHandle(
                    adapterID:
                        TatwoChatRuntimeAdapter.codexExec.rawValue,
                    modelID: "gpt-5.6-terra",
                    providerSessionID: providerSessionID),
            ],
            isPlanModeEnabled: false,
            loopsConfig: nil)
        model.document = TatwoNativeChatStoreDocument(
            projects: [
                TatwoNativeChatProject(
                    id: projectID,
                    name: "test",
                    workdir: projectWorkdir,
                    threads: [thread]),
            ])
        model.selectedProjectID = projectID
        model.selectedThreadID = threadID
        model.selectedModel = "gpt-5.6-terra"
        model.selectedEffort = .medium
        XCTAssertTrue(model.persistStore())

        // Preserve a stale app-wide XXL selection as the regression poison.
        // The selected thread itself remains Off and therefore owns no
        // topology authority.
        let staleTemplate = try XCTUnwrap(
            model.coworkTemplates.first(where: {
                $0.mode == .xxl
            }))
        model.selectedCoworkTemplateID = staleTemplate.id
        var plan = TatwoPlanArtifactV1(
            threadID: threadID,
            objective:
                "在 Python 專案建立 task counter 並補 unittest",
            sections: [
                .init(
                    title: "實作",
                    body: "建立小型 Python 任務並驗證 3 個案例。"),
            ],
            sourceAssistantMessageID: UUID().uuidString)
        plan.updateDiscussion(
            objective: plan.objective,
            sections: plan.sections)
        model.activePlanArtifact = plan

        let request =
            "/plg 在 Python 專案建立 task counter 並補 unittest"
        model.prompt = request
        model.send()
        for _ in 0..<160
        where model.composerHint?.contains("Ultrawork Off") != true
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let persisted = try TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false
        ).load()
        let persistedThread = try XCTUnwrap(
            persisted.projects.first(where: { $0.id == projectID })?
                .threads.first(where: { $0.id == threadID }))
        let diagnostic = [
            "hint=\(model.composerHint ?? "nil")",
            "plgError=\(model.plgError ?? "nil")",
            "route=\(model.currentTurnDispatchRoute().canonicalModelSlug)",
            "effort=\(model.selectedEffort.rawValue)",
            "loops=\(String(describing: model.selectedThread?.loopsConfig))",
        ].joined(separator: " ")

        XCTAssertEqual(model.prompt, request, diagnostic)
        XCTAssertEqual(model.selectedThreadID, threadID, diagnostic)
        XCTAssertEqual(model.selectedModel, "gpt-5.6-terra", diagnostic)
        XCTAssertEqual(model.selectedEffort, .medium, diagnostic)
        XCTAssertFalse(model.collaborationIsEnabled, diagnostic)
        XCTAssertNil(model.selectedThread?.loopsConfig, diagnostic)
        XCTAssertNil(persistedThread.loopsConfig, diagnostic)
        XCTAssertNil(model.selectedWorkOSContract, diagnostic)
        XCTAssertNil(model.selectedGoalRecord, diagnostic)
        XCTAssertNil(model.activePLGRun, diagnostic)
        XCTAssertEqual(native.startCount, 0, diagnostic)
        XCTAssertTrue(
            model.composerHint?.contains("未套用舊的 XXL") == true,
            diagnostic)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: goalStore.directoryURL,
                includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .count,
            0,
            "No contract/goal artifact may be initialized before explicit topology selection. \(diagnostic)")
    }

    @MainActor
    func testGoalCreationFailureKeepsPromptAndShowsConcreteReason()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-goal-visible-rejection-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
        model.newChat()
        model.createDiscussionForSelectedThread()
        XCTAssertTrue(model.isDiscussionSessionSelected)

        let request = "/goal Discussion 不可建立主線 Goal"
        model.prompt = request
        model.send()
        for _ in 0..<160 where model.composerHint == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(model.prompt, request)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertTrue(
            model.composerHint?.contains("Discussion") == true,
            model.composerHint ?? "missing concrete rejection reason")
    }

    @MainActor
    func testDiscussionBranchInheritsParentSnapshotAndMergesReceipt()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-discussion-lifecycle-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
        let parentMessage = TatwoNativeChatStoredMessage(
            role: "user",
            text: "父 thread 已確認的上下文",
            eventKind: .message)
        let thread = TatwoNativeChatThread(
            title: "支線父 thread",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned,
            messages: [parentMessage])
        model.document = TatwoNativeChatStoreDocument(threads: [thread])
        model.selectedThreadID = thread.id
        model.messages = [ChatMessage(stored: parentMessage)]

        let discussionID = try XCTUnwrap(
            model.createDiscussionForSelectedThread(title: "檢查支線入口"))
        XCTAssertEqual(model.selectedDiscussionID, discussionID)
        let discussion = try XCTUnwrap(model.selectedDiscussion)
        XCTAssertEqual(discussion.title, "檢查支線入口")
        XCTAssertEqual(
            discussion.forkCheckpoint?.parentMessages,
            [parentMessage])
        XCTAssertEqual(
            discussion.forkCheckpoint?.parentTranscriptSHA256,
            TatwoNativeSessionTree.transcriptSHA256([parentMessage]))

        model.messages = [
            ChatMessage(role: .assistant, text: "支線完成結論")
        ]
        model.mergeDiscussionIntoParent(discussionID)

        let mergedDiscussion = try XCTUnwrap(
            model.selectedThread?.discussions.first(where: {
                $0.id == discussionID
            }))
        XCTAssertEqual(mergedDiscussion.mergeReceipts.count, 1)
        let parentMessages = model.selectedThread?.messages ?? []
        XCTAssertTrue(
            parentMessages.contains {
                $0.text.contains("[Discussion merge receipt]")
                    && $0.text.contains("支線完成結論")
            })
        XCTAssertFalse(
            parentMessages.contains {
                $0.role == "assistant" && $0.text == "支線完成結論"
            })
    }

    @MainActor
    func testDiscussionCommandBlockedByActiveMainTurnKeepsPromptAndReason()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-discussion-visible-rejection-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
        let commandCenter = TatwoNewChatCommandCenter()
        let registration = commandCenter.register {
            model.newChat()
        }
        defer { commandCenter.unregister(registration) }
        commandCenter.request()
        model.isRunning = true
        let request = "# 保留這個支線任務"
        model.prompt = request

        model.send()

        XCTAssertEqual(model.prompt, request)
        XCTAssertTrue(model.selectedThread?.discussions.isEmpty == true)
        XCTAssertTrue(
            model.composerHint?.contains("輸入已保留") == true,
            model.composerHint ?? "missing visible branch rejection")
    }

    @MainActor
    func testNativeDevelopmentPLGPreservesBoundGoalAndStartsNewMainChat()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-bound-plg-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let sessionStore = TatwoSessionStore(
            directoryURL: goalStore.directoryURL)
        let dispatchRegistry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let oldThreadID = UUID()
        let oldObjective = "保留既有 Goal"
        let proposedOldContract = try WorkOSFactory.projectContract(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .exactXXLSolOpusLunaGrokScenarioID,
            objective: oldObjective)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: goalStore.directoryURL,
            contractID: proposedOldContract.contractID)
        let oldAttachment = try sessionStore.beginCurrent(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .exactXXLSolOpusLunaGrokScenarioID,
            objective: oldObjective,
            owner: TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread(
                    oldThreadID.uuidString.lowercased()),
                workspacePath:
                    TatwoRuntimeLayout.applicationSupportRoot()
                        .appendingPathComponent(
                            "chat-workspace",
                            isDirectory: true)
                        .standardizedFileURL.path),
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        let oldContract = oldAttachment.contract
        let oldLoopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID:
                TatwoScenarioConfigDefaults
                    .exactXXLSolOpusLunaGrokScenarioID,
            mode: .xxl,
            identitySummary: "既有 Sol／Opus／Luna／Grok",
            tokenBudget: "existing",
            primaryModelID: nil,
            secondaryModelID: nil)
        let oldThread = TatwoNativeChatThread(
            id: oldThreadID,
            title: "既有 Goal thread",
            loopsConfig: oldLoopsConfig,
            workOSGoalID: oldContract.goalID,
            workOSContractID: oldContract.contractID)
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        model.document = TatwoNativeChatStoreDocument(threads: [oldThread])
        model.selectedThreadID = oldThread.id
        model.selectedWorkOSContract = oldContract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            oldContract.contractID)

        model.prompt =
            "/plg 修復並驗證 TATWO OS 自主開發能力，使用 read_file、git_diff、run_command"
        model.send()
        for _ in 0..<160 where model.document.threads.count < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(model.document.threads.count, 2)
        XCTAssertNotEqual(model.selectedThreadID, oldThread.id)
        let preserved = try XCTUnwrap(
            model.document.threads.first(where: { $0.id == oldThread.id }))
        XCTAssertEqual(preserved.loopsConfig, oldLoopsConfig)
        XCTAssertEqual(preserved.workOSGoalID, oldContract.goalID)
        XCTAssertEqual(
            preserved.workOSContractID,
            oldContract.contractID)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(oldContract.contractID).status,
            .cancelled)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(oldContract.contractID)
                .statusReason,
            "superseded_before_dispatch")
        XCTAssertNil(try sessionStore.current())
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertEqual(
            model.selectedThread?.loopsConfig?.scenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID)
        XCTAssertFalse(
            model.plgError?.contains("Scenario 綁定失敗") == true)
    }

    @MainActor
    func testDifferentNativeGoalAfterFailedDispatchPreservesOldEvidenceAndStartsNewMainChat()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-failed-goal-replacement-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let sessionStore = TatwoSessionStore(
            directoryURL: goalStore.directoryURL)
        let dispatchRegistry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let oldThreadID = UUID()
        let oldObjective = "錯誤的 Opus Island 派工"
        let proposedOldContract = try WorkOSFactory.projectContract(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: oldObjective)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: goalStore.directoryURL,
            contractID: proposedOldContract.contractID)
        let oldAttachment = try sessionStore.beginCurrent(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: oldObjective,
            owner: TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread(
                    oldThreadID.uuidString.lowercased()),
                workspacePath:
                    TatwoRuntimeLayout.applicationSupportRoot()
                        .appendingPathComponent(
                            "chat-workspace",
                            isDirectory: true)
                        .standardizedFileURL.path),
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        let oldContract = oldAttachment.contract
        let failedDispatch =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: oldContract,
                subtask: "錯誤的 Island 執行 lane",
                goalStore: goalStore,
                dispatchRegistry: dispatchRegistry)
        _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
            contractID: oldContract.contractID,
            dispatchID: failedDispatch.id,
            errorCode: "native_exit_130",
            message: "Native agent exited with status 130",
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(oldContract.contractID).status,
            .blocked)

        let oldLoopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            mode: .xxl,
            identitySummary: "錯誤的 Sol／Opus lane",
            tokenBudget: "existing",
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: "opus-5")
        let oldThread = TatwoNativeChatThread(
            id: oldThreadID,
            title: "失敗 Goal thread",
            loopsConfig: oldLoopsConfig,
            workOSGoalID: oldContract.goalID,
            workOSContractID: oldContract.contractID)
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        model.document = TatwoNativeChatStoreDocument(threads: [oldThread])
        model.selectedThreadID = oldThread.id
        model.selectedWorkOSContract = oldContract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            oldContract.contractID)
        let replacementObjective = """
            請使用 read_file、git_diff、run_command 實際修改並驗證程式碼。
            Fable 5 Medium 先完成 Tatwo Island 減碼與縮展效能，
            receipt 完整後才由 Grok 4.6 High 重做 Aurora 液態玻璃。
            Fable 5 紀念主題與 Ultrawork 漸變拉條不得變動。
            """

        let prepared =
            await model.prepareNativeDevelopmentScenarioForPLGIfNeeded(
                objective: replacementObjective)
        XCTAssertTrue(prepared)

        XCTAssertEqual(model.document.threads.count, 2)
        XCTAssertNotEqual(model.selectedThreadID, oldThread.id)
        let preserved = try XCTUnwrap(
            model.document.threads.first(where: { $0.id == oldThread.id }))
        XCTAssertEqual(preserved.loopsConfig, oldLoopsConfig)
        XCTAssertEqual(preserved.workOSGoalID, oldContract.goalID)
        XCTAssertEqual(
            preserved.workOSContractID,
            oldContract.contractID)
        let failedGoal = try goalStore.requireIssuedContract(
            oldContract.contractID)
        XCTAssertEqual(failedGoal.status, .failed)
        XCTAssertEqual(
            failedGoal.statusReason,
            "replaced_after_terminal_dispatch_failure:\(failedDispatch.id)")
        XCTAssertNil(try sessionStore.current())
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertEqual(
            model.selectedThread?.loopsConfig?.scenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID)
        XCTAssertEqual(
            model.currentTurnDispatchRoute().canonicalModelSlug,
            "fable-5")
    }

    @MainActor
    func testFreshPLGConfirmPlanStartsBoundNativeDispatchWithoutSecondGoalCommand()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-fresh-plg-e2e-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let native = RecordingNativeAgentRunner()
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: native)
        let request = """
            /plg 建立 App 原生開發收據。
            請實際依序使用 TATWO 原生工具：
            1. read_file 讀取 Package.swift。
            2. git_diff 檢查目前變更。
            3. run_command 執行 git diff --check。
            """

        model.prompt = request
        model.send()
        for _ in 0..<160
        where model.selectedThread?.loopsConfig?.scenarioID
            != TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(model.authorityBootstrapModel.pendingProposal)
        XCTAssertEqual(
            model.selectedThread?.loopsConfig?.scenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID)

        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(
            model.selectedWorkOSContract?.scenario,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID)
        XCTAssertEqual(native.startCount, 1)
        XCTAssertEqual(
            model.messages.last?.runtimeAdapterID,
            TatwoChatRuntimeAdapter.nativeAgent.rawValue)
        XCTAssertEqual(native.request?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(native.request?.effort, "high")
        XCTAssertTrue(try XCTUnwrap(native.request).readOnly)
        XCTAssertNil(native.request?.dispatchID)

        native.emit(.output("原生規劃完成"))
        native.emit(.exit(0))
        for _ in 0..<160 where model.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(model.isRunning)

        XCTAssertTrue(model.confirmPLGPlanAndStartLoops())
        for _ in 0..<160 where native.startCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let dispatch = try XCTUnwrap(
            model.selectedDispatchRecords.first {
                $0.id == native.request?.dispatchID
            })
        let snapshot = ChatTurnContractEffortResolver.resolve(
            route: model.currentTurnDispatchRoute(),
            phase: .loops,
            contract: try XCTUnwrap(model.selectedWorkOSContract),
            uiSelectedEffort: .high)
        let goalDiagnostic =
            "hint=\(model.composerHint ?? "nil") "
            + "goalStatus=\(model.selectedGoalRecord?.status.rawValue ?? "nil") "
            + "plgPhase=\(model.activePLGRun?.phase.rawValue ?? "nil") "
            + "blocker=\(model.lastNativeRuntimeStartBlocker ?? "nil") "
            + "dispatches=\(model.selectedDispatchRecords.map { "\($0.id):\($0.status.rawValue):binding=\($0.bindingID):source=\($0.sourceSlotID):identity=\($0.identity.rawValue):model=\($0.modelID)" }) "
            + "bindings=\(model.selectedWorkOSContract?.identityBindings.map { "\($0.id):source=\($0.sourceSlotID):identity=\($0.identity.rawValue):model=\($0.modelID ?? "nil")" } ?? []) "
            + "activations=\(model.selectedWorkOSContract?.loopGovernorDecision.activatedBindings.map { "\($0.id):phase=\($0.phase.rawValue):models=\($0.boundModelIDs)" } ?? [])"
        XCTAssertEqual(
            snapshot.contractBindingID, dispatch.sourceSlotID, goalDiagnostic)
        XCTAssertNotEqual(
            snapshot.contractBindingID, dispatch.bindingID, goalDiagnostic)
        XCTAssertNotEqual(
            model.lastNativeRuntimeStartBlocker,
            "mutation_dispatch_missing",
            goalDiagnostic)
        XCTAssertEqual(
            model.selectedGoalRecord?.status,
            .running,
            goalDiagnostic)
        XCTAssertEqual(native.startCount, 2)
        XCTAssertEqual(
            model.messages.last?.runtimeAdapterID,
            TatwoChatRuntimeAdapter.nativeAgent.rawValue,
            goalDiagnostic)
        XCTAssertFalse(
            try XCTUnwrap(native.request).readOnly,
            goalDiagnostic)
        XCTAssertNotNil(native.request?.dispatchID, goalDiagnostic)
        XCTAssertTrue(
            model.selectedDispatchRecords.contains {
                $0.id == native.request?.dispatchID
                    && $0.status == .running
            },
            goalDiagnostic)
    }

    @MainActor
    func testReloadedBoundGoalWithoutProjectionRebuildsAndStartsSolDispatch()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-reloaded-goal-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let dispatchRegistry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let plgChainStore = TatwoPLGChainStore(
            directory: root.appendingPathComponent("plg-chains"),
            anchorAuthority: ChatNativeAgentTestAnchorAuthority())
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let request = """
            /plg 修復並驗證 TATWO OS 自主開發能力。
            請使用 read_file、git_diff、run_command。
            """
        let planningNative = RecordingNativeAgentRunner()
        let planningModel = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent(
                    "planning-journal.json")),
            goalRunStore: goalStore,
            plgChainStore: plgChainStore,
            dispatchRegistry: dispatchRegistry,
            nativeRunner: planningNative)

        planningModel.prompt = request
        planningModel.send()
        for _ in 0..<160 where planningNative.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(planningNative.startCount, 1)
        planningNative.emit(.exit(0))
        for _ in 0..<160 where planningModel.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(planningModel.isRunning)
        XCTAssertTrue(planningModel.advancePLGFromPlanning())
        XCTAssertEqual(planningModel.activePLGRun?.phase, .leadAdversarial)
        let originalContractID = try XCTUnwrap(
            planningModel.selectedWorkOSContract?.contractID)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(originalContractID).status,
            .planned)
        XCTAssertEqual(
            try nativeStore.load().threads.first?
                .activePLGRunProjection?.phase,
            .leadAdversarial)

        var strippedDocument = try nativeStore.load()
        strippedDocument.threads[0].activePLGRunProjection = nil
        try nativeStore.save(strippedDocument)
        let recoveredPLGChainStore = TatwoPLGChainStore(
            directory: root.appendingPathComponent(
                "recovered-plg-chains"),
            anchorAuthority: ChatNativeAgentTestAnchorAuthority())
        let reloadedNative = RecordingNativeAgentRunner()
        let reloaded = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent(
                    "reloaded-journal.json")),
            goalRunStore: goalStore,
            plgChainStore: recoveredPLGChainStore,
            dispatchRegistry: dispatchRegistry,
            nativeRunner: reloadedNative)
        for _ in 0..<200 where reloaded.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(reloaded.isLoadingStore)
        XCTAssertEqual(
            reloaded.selectedWorkOSContract?.contractID,
            originalContractID)
        XCTAssertNil(reloaded.activePLGRun)
        reloaded.setSingleModel("gpt-5.6-sol")
        reloaded.prompt = "/goal"

        reloaded.send()

        for _ in 0..<160 where reloadedNative.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let hintDiagnostic = reloaded.composerHint ?? "nil"
        let contractDiagnostic =
            reloaded.selectedWorkOSContract?.contractID ?? "nil"
        let goalStatusDiagnostic =
            reloaded.selectedGoalRecord?.status.rawValue ?? "nil"
        let plgPhaseDiagnostic =
            reloaded.activePLGRun?.phase.rawValue ?? "nil"
        let dispatchDiagnostic = reloaded.selectedDispatchRecords.map {
            "\($0.id):\($0.status.rawValue)"
        }
        let diagnostic = [
            "hint=\(hintDiagnostic)",
            "contract=\(contractDiagnostic)",
            "goalStatus=\(goalStatusDiagnostic)",
            "plgPhase=\(plgPhaseDiagnostic)",
            "dispatches=\(dispatchDiagnostic)",
            "send=\(reloaded.sendAvailabilityDiagnostic)",
        ].joined(separator: " ")
        XCTAssertEqual(
            reloaded.selectedWorkOSContract?.contractID,
            originalContractID,
            diagnostic)
        XCTAssertEqual(
            reloaded.selectedGoalRecord?.status,
            .running,
            diagnostic)
        XCTAssertEqual(reloadedNative.startCount, 1, diagnostic)
        XCTAssertEqual(
            reloadedNative.request?.dispatchID,
            reloaded.selectedDispatchRecords.first(where: {
                $0.status == TatwoDispatchStatus.running
            })?.id,
            diagnostic)

        reloadedNative.emit(.exit(0))
        for _ in 0..<160 where reloaded.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(reloaded.isRunning)

        reloaded.setSingleModel("opus-5")
        reloaded.prompt = "/goal 重做 Tatwo Island Liquid Glass"
        reloaded.send()
        for _ in 0..<160 where reloadedNative.startCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(reloadedNative.startCount, 2)
        XCTAssertEqual(reloadedNative.request?.modelID, "opus-5")
        XCTAssertEqual(reloadedNative.request?.effort, "high")
        XCTAssertFalse(try XCTUnwrap(reloadedNative.request).readOnly)
        XCTAssertTrue(
            reloaded.selectedDispatchRecords.contains {
                $0.id == reloadedNative.request?.dispatchID
                    && $0.status == .running
                    && $0.identity == .supervisor
                    && $0.modelID == "opus-5"
            })
    }

    @MainActor
    func testStandaloneGoalOwnerRemainsStableWhileNativeWorkspaceUsesConfiguredRepository()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-owner-workspace-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent(
            "configured-workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let native = RecordingNativeAgentRunner()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_CHAT_WORKDIR": workspace.path,
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            nativeRunner: native)
        let request = "/plg 驗證 standalone native workspace owner"

        model.prompt = request
        model.send()
        for _ in 0..<160
        where model.authorityBootstrapModel.pendingProposal == nil
            && ((try? TatwoSessionStore(
                directoryURL: goalStore.directoryURL).current()) ?? nil) == nil
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        await model.authorityBootstrapModel.confirmPending()
        XCTAssertNil(
            model.authorityBootstrapModel.errorMessage,
            model.authorityBootstrapModel.errorMessage ?? "")
        model.prompt = request
        model.send()
        for _ in 0..<160
        where ((try? TatwoSessionStore(
            directoryURL: goalStore.directoryURL).current()) ?? nil) == nil
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let pointer = try XCTUnwrap(
            try TatwoSessionStore(
                directoryURL: goalStore.directoryURL).current())
        XCTAssertEqual(
            pointer.ownerBinding?.workspacePath,
            TatwoRuntimeLayout.applicationSupportRoot()
                .appendingPathComponent(
                    "chat-workspace",
                    isDirectory: true)
                .standardizedFileURL.path)
        XCTAssertEqual(
            model.currentConversationWorkspaceURL().standardizedFileURL.path,
            workspace.standardizedFileURL.path)
    }

    func testBuildCommandForwardsCurrentTurnDevelopmentDecision() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try ChatSourceFamily.read("ChatPageModel.swift")

        XCTAssertTrue(source.contains(
            "let developmentDecision =\n            nativeDevelopmentDecision(for: visibleTurn)"))
        XCTAssertTrue(source.contains(
            "nativeDevelopmentRequested: developmentDecision.requested"))
        XCTAssertTrue(source.contains(
            "nativeDevelopmentAccess: developmentAccess"))
        XCTAssertTrue(source.contains(
            "let developmentAccess =\n            nativeDevelopmentAccess(for: visibleTurn)"))
        XCTAssertTrue(source.contains(
            "contractStatus:\n                selectedGoalRecord?.status\n                    ?? selectedWorkOSContract?.goalRun.status"))
    }

    @MainActor
    func testConfirmedRunningDispatchForcesNativeMutationForNeutralGoalText()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-confirmed-dispatch-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "讓 Island 與系統外觀一致",
            store: goalStore)
        let dispatch =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: contract.objective,
                goalStore: goalStore,
                dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: native)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.pendingNativeDevelopmentDispatch = dispatch

        let classifier = TatwoChatCommandPlanner.nativeDevelopmentDecision(
            currentVisibleTurn: contract.objective,
            mode: .chat,
            interactionMode: .standard,
            scenarioPhase: .loops,
            contractStatus: .running)
        XCTAssertEqual(classifier.access, .none)
        XCTAssertEqual(
            model.nativeDevelopmentAccess(for: contract.objective),
            .mutation,
            "The explicit /goal dispatch is the mutation authority; neutral wording must not fall back to chat-only routing.")
    }

    @MainActor
    func testConfirmedSolDispatchSubmitStartsNativeRunnerForNeutralGoalText()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-confirmed-submit-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "讓 Island 與系統外觀一致",
            store: goalStore)
        let dispatch =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: contract.objective,
                goalStore: goalStore,
                dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let thread = TatwoNativeChatThread(
            title: "confirmed Sol dispatch",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            nativeRunner: native)
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.pendingNativeDevelopmentDispatch = dispatch
        model.setSingleModel("gpt-5.6-sol")
        model.prompt = contract.objective

        XCTAssertNotNil(model.selectedThread)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(
            model.nativeDevelopmentAccess(for: contract.objective),
            .mutation)
        model.submitCurrentChatTurn()

        for _ in 0..<160 where native.startCount == 0 && model.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(model.composerHint)
        XCTAssertEqual(
            model.messages.last?.runtimeAdapterID,
            TatwoChatRuntimeAdapter.nativeAgent.rawValue)
        XCTAssertEqual(native.startCount, 1)
        XCTAssertEqual(native.request?.dispatchID, dispatch.id)
        XCTAssertEqual(native.request?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(native.request?.effort, "high")
        XCTAssertFalse(try XCTUnwrap(native.request).readOnly)
    }

    // M4b 更新：成功 settlement 只橋接真實執行可證明的四種 requirement，
    // 同一 dispatch 重送不重複，cycle seal 後也不會自動 advance。
    @MainActor
    func testM4bSuccessfulSettlementBridgesExactReceiptsSealsAndAdvancesOnlyOnCall()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-m4b-receipts-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "M4b receipt bridge and cycle seal",
            store: goalStore)
        let dispatch =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: contract.objective,
                goalStore: goalStore,
                dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let model = try makeNativeDevelopmentModel(
            root: root,
            goalStore: goalStore,
            registry: registry,
            contract: contract,
            dispatch: dispatch,
            modelID: "gpt-5.6-sol",
            native: native)

        model.submitCurrentChatTurn()
        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let request = try XCTUnwrap(native.request)
        let terminalReceiptID = "native-terminal:m4b-sol"
        let artifactURL = try writeM4bEvidenceArtifact(
            root: root,
            request: request,
            terminalReceiptID: terminalReceiptID)

        native.emit(.nativeTerminalReceipt(
            receiptID: terminalReceiptID,
            outputRef: artifactURL.path))
        native.emit(.exit(0))
        try await waitForDispatchStatus(
            .completed,
            dispatchID: dispatch.id,
            contractID: contract.contractID,
            registry: registry)

        let settled = try goalStore.requireIssuedContract(
            contract.contractID)
        let mapped = settled.receipts.filter {
            $0.satisfiesRequirementID != nil
        }
        XCTAssertEqual(
            Set(mapped.compactMap(\.satisfiesRequirementID)),
            ["dispatch-liveness", "goal-tracker", "sandbox", "rollback"])
        XCTAssertEqual(mapped.count, 4)
        XCTAssertEqual(
            mapped.first {
                $0.satisfiesRequirementID == "dispatch-liveness"
            }?.receiptID,
            terminalReceiptID)
        XCTAssertEqual(
            mapped.first {
                $0.satisfiesRequirementID == "goal-tracker"
            }?.receiptID,
            dispatch.id)
        XCTAssertEqual(
            Set(mapped.filter {
                ["sandbox", "rollback"].contains(
                    $0.satisfiesRequirementID ?? "")
            }.map(\.receiptID)),
            [artifactURL.path])
        XCTAssertFalse(mapped.contains {
            [
                "human-gate",
                "scope-review",
                "goal-cycle-seal",
                "contract-id",
                "mode-budget",
                "identity-bindings",
            ].contains($0.satisfiesRequirementID ?? "")
        })
        XCTAssertEqual(settled.status, .awaitingNextCycle)
        XCTAssertEqual(settled.latestDispatchCycleEpoch, 1)
        XCTAssertNotNil(
            try registry.run(forContractID: contract.contractID)?.sealID)

        let receiptCount = settled.receipts.count
        native.emit(.nativeTerminalReceipt(
            receiptID: terminalReceiptID,
            outputRef: artifactURL.path))
        native.emit(.exit(0))
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID)
                .receipts.count,
            receiptCount)

        XCTAssertTrue(model.advanceNativeDevelopmentCycle())
        let advanced = try goalStore.requireIssuedContract(
            contract.contractID)
        XCTAssertEqual(advanced.status, .running)
        XCTAssertEqual(
            try registry.run(forContractID: contract.contractID)?
                .activeCycleEpoch,
            2)
    }

    // M4b 更新：failed settlement 不得提交任何 execution requirement。
    @MainActor
    func testM4bFailedSettlementDoesNotBridgeReceipts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-m4b-failed-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "M4b failed settlement",
            store: goalStore)
        let dispatch =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: contract.objective,
                goalStore: goalStore,
                dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let model = try makeNativeDevelopmentModel(
            root: root,
            goalStore: goalStore,
            registry: registry,
            contract: contract,
            dispatch: dispatch,
            modelID: "gpt-5.6-sol",
            native: native)

        model.submitCurrentChatTurn()
        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        native.emit(.runtimeFailure("Native development failed"))
        native.emit(.exit(1))
        try await waitForDispatchStatus(
            .failed,
            dispatchID: dispatch.id,
            contractID: contract.contractID,
            registry: registry)

        let stored = try goalStore.requireIssuedContract(
            contract.contractID)
        XCTAssertTrue(stored.receipts.allSatisfy {
            $0.satisfiesRequirementID == nil
        })
        XCTAssertEqual(stored.status, .blocked)
        XCTAssertEqual(
            try registry.run(forContractID: contract.contractID)?
                .records.first(where: { $0.id == dispatch.id })?.status,
            .failed)
    }

    // M4b 更新：receipt journal 故障只留下診斷，不得回滾已完成 settlement。
    @MainActor
    func testM4bReceiptSubmissionFailureDoesNotFailCompletedSettlement()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-m4b-submit-failure-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "M4b receipt failure isolation",
            store: goalStore)
        let dispatch =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: contract.objective,
                goalStore: goalStore,
                dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let model = try makeNativeDevelopmentModel(
            root: root,
            goalStore: goalStore,
            registry: registry,
            contract: contract,
            dispatch: dispatch,
            modelID: "gpt-5.6-sol",
            native: native,
            receiptSubmitter: {
                goalID,
                contractID,
                loopID,
                receiptID,
                receiptKind,
                _,
                _ in
                WorkOSReceiptSubmissionResult(
                    ok: false,
                    goalID: goalID,
                    contractID: contractID,
                    loopID: loopID,
                    receiptID: receiptID,
                    receiptKind: receiptKind,
                    decision: WorkOSGateDecision(
                        ok: false,
                        code: "m4b_injected_submit_failure",
                        message: "injected"),
                    nextAction: "none")
            })

        model.submitCurrentChatTurn()
        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let request = try XCTUnwrap(native.request)
        let terminalReceiptID = "native-terminal:m4b-submit-failure"
        let artifactURL = try writeM4bEvidenceArtifact(
            root: root,
            request: request,
            terminalReceiptID: terminalReceiptID)
        native.emit(.nativeTerminalReceipt(
            receiptID: terminalReceiptID,
            outputRef: artifactURL.path))
        native.emit(.exit(0))
        try await waitForDispatchStatus(
            .completed,
            dispatchID: dispatch.id,
            contractID: contract.contractID,
            registry: registry)

        let stored = try goalStore.requireIssuedContract(
            contract.contractID)
        XCTAssertEqual(stored.status, .awaitingNextCycle)
        XCTAssertTrue(stored.receipts.allSatisfy {
            $0.satisfiesRequirementID == nil
        })
        XCTAssertEqual(
            try registry.run(forContractID: contract.contractID)?
                .records.first(where: { $0.id == dispatch.id })?.status,
            .completed)
        XCTAssertTrue(
            model.lastNativeDevelopmentReceiptBridgeFailure?
                .contains("m4b_injected_submit_failure") == true)
    }

    // M4b 更新：worktree 隔離與 rollback 證據分開判定；git/base commit
    // 證據無效時仍可提交 sandbox，但不得順便自動滿足 rollback。
    @MainActor
    func testM4bSettlementDoesNotForgeRollbackFromSandboxEvidence()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-m4b-sandbox-only-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "M4b sandbox-only evidence",
            store: goalStore)
        let dispatch =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: contract.objective,
                goalStore: goalStore,
                dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let model = try makeNativeDevelopmentModel(
            root: root,
            goalStore: goalStore,
            registry: registry,
            contract: contract,
            dispatch: dispatch,
            modelID: "gpt-5.6-sol",
            native: native)

        model.submitCurrentChatTurn()
        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let request = try XCTUnwrap(native.request)
        let terminalReceiptID = "native-terminal:m4b-sandbox-only"
        let artifactURL = try writeM4bEvidenceArtifact(
            root: root,
            request: request,
            terminalReceiptID: terminalReceiptID,
            hasGitEvidence: false)
        native.emit(.nativeTerminalReceipt(
            receiptID: terminalReceiptID,
            outputRef: artifactURL.path))
        native.emit(.exit(0))
        try await waitForDispatchStatus(
            .completed,
            dispatchID: dispatch.id,
            contractID: contract.contractID,
            registry: registry)

        let mapped = try goalStore.requireIssuedContract(
            contract.contractID).receipts.filter {
                $0.satisfiesRequirementID != nil
            }
        XCTAssertEqual(
            Set(mapped.compactMap(\.satisfiesRequirementID)),
            ["dispatch-liveness", "goal-tracker", "sandbox"])
        XCTAssertFalse(mapped.contains {
            $0.satisfiesRequirementID == "rollback"
        })
    }

    @MainActor
    func testCompletedFableDispatchAutomaticallyStartsGrokSecondLane()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-fable-grok-auto-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let objective = """
            Fable 5 先完成 Island，完成 receipt 後才由 Grok 4.6
            優化 Aurora。Fable5 紀念主題與 Ultrawork 拉條不得變動。
            """
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
            objective: objective,
            store: goalStore)
        let fableDispatch =
            try TatwoNativeDevelopmentDispatchCoordinator
                .beginSelectedExecutor(
                    contract: contract,
                    selectedModelID: "fable-5",
                    subtask: objective,
                    goalStore: goalStore,
                    dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let thread = TatwoNativeChatThread(
            title: "Fable then Grok",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: registry,
            nativeRunner: native)
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.pendingNativeDevelopmentDispatch = fableDispatch
        model.setSingleModel("fable-5", syncCollaborationLead: false)
        model.prompt = model.nativeDevelopmentLaneTask(
            modelID: "fable-5",
            objective: objective)

        model.submitCurrentChatTurn(applyPromptCollaboration: false)
        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(native.startCount, 1)
        XCTAssertEqual(native.request?.modelID, "fable-5")
        XCTAssertEqual(native.request?.effort, "medium")
        XCTAssertEqual(native.request?.dispatchID, fableDispatch.id)
        XCTAssertTrue(
            native.request?.prompt.contains("嚴格只處理 Tatwo Island")
                == true)

        native.emit(.output("Fable Island receipt complete"))
        native.emit(.nativeTerminalReceipt(
            receiptID: "native-terminal:fable-island",
            outputRef: "native-run:fable-island"))
        native.emit(.exit(0))
        for _ in 0..<160 where native.startCount < 2 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(native.startCount, 2)
        XCTAssertEqual(native.request?.modelID, "grok-build")
        XCTAssertEqual(native.request?.effort, "high")
        XCTAssertNotEqual(native.request?.dispatchID, fableDispatch.id)
        XCTAssertTrue(
            native.request?.prompt.contains(
                "TATWO /plg 第二 lane：Grok 4.6 High")
                == true)
        let records = try XCTUnwrap(
            registry.run(forContractID: contract.contractID)).records
        XCTAssertTrue(records.contains {
            $0.id == fableDispatch.id
                && $0.status == .completed
                && $0.receiptID == "native-terminal:fable-island"
                && $0.outputRef != nil
        })
        XCTAssertTrue(records.contains {
            $0.id == native.request?.dispatchID
                && $0.modelID == "grok-build"
                && $0.status == .running
        })
        XCTAssertFalse(records.contains {
            ["gpt-5.6-sol", "opus-5"].contains($0.modelID)
        })
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .running)
        XCTAssertNil(
            try registry.run(forContractID: contract.contractID)?.sealID,
            "M4b missing Grok lane must not seal after only Fable completed")

        // M4b 更新：精確保留尚未啟用的 Grok attestation failure；
        // 不 seal、不把 failed lane 假裝成 completed，Goal 保持 running。
        native.emit(.runtimeFailure(
            "Governed development session failed: "
                + TatwoNativeDevelopmentDispatchCoordinator
                    .grokDevAttestationUnverifiedErrorCode))
        native.emit(.exit(1))
        let grokDispatchID = try XCTUnwrap(native.request?.dispatchID)
        try await waitForDispatchStatus(
            .failed,
            dispatchID: grokDispatchID,
            contractID: contract.contractID,
            registry: registry)
        let failedRecords = try XCTUnwrap(
            registry.run(forContractID: contract.contractID)).records
        XCTAssertTrue(failedRecords.contains {
            $0.modelID == "grok-build"
                && $0.status == .failed
                && $0.failureReceipt?.errorCode
                    == TatwoNativeDevelopmentDispatchCoordinator
                        .grokDevAttestationUnverifiedErrorCode
        })
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .running)
        XCTAssertNil(
            try registry.run(forContractID: contract.contractID)?.sealID)
        XCTAssertFalse(model.sealCompletedNativeDevelopmentCycleIfReady())
    }

    // M4b 更新：Fable + Grok 兩條 required lane 都 completed 才可 finalize。
    @MainActor
    func testM4bFableAndGrokCompletedLanesFinalizeThroughLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-m4b-two-lanes-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
            objective: "M4b finalize both lanes",
            store: goalStore)
        let fable =
            try TatwoNativeDevelopmentDispatchCoordinator
                .beginSelectedExecutor(
                    contract: contract,
                    selectedModelID: "fable-5",
                    subtask: "Fable lane",
                    goalStore: goalStore,
                    dispatchRegistry: registry)
        _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
            contractID: contract.contractID,
            dispatchID: fable.id,
            receiptID: "terminal:fable",
            outputRef: "artifact:fable",
            goalStore: goalStore,
            dispatchRegistry: registry)
        let grok =
            try TatwoNativeDevelopmentDispatchCoordinator
                .beginSelectedExecutor(
                    contract: contract,
                    selectedModelID: "grok-build",
                    subtask: "Grok lane",
                    goalStore: goalStore,
                    dispatchRegistry: registry)
        _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
            contractID: contract.contractID,
            dispatchID: grok.id,
            receiptID: "terminal:grok",
            outputRef: "artifact:grok",
            goalStore: goalStore,
            dispatchRegistry: registry)
        let model = try makeNativeDevelopmentModel(
            root: root,
            goalStore: goalStore,
            registry: registry,
            contract: contract,
            dispatch: nil,
            modelID: "fable-5",
            native: RecordingNativeAgentRunner())

        XCTAssertTrue(model.sealCompletedNativeDevelopmentCycleIfReady())
        let finalized = try goalStore.requireIssuedContract(
            contract.contractID)
        XCTAssertEqual(finalized.status, .awaitingNextCycle)
        XCTAssertEqual(
            try registry.run(forContractID: contract.contractID)?
                .sealedRecordIDs,
            [fable.id, grok.id])
    }

    @MainActor
    func testNativeExitZeroWithoutTerminalReceiptFailsDispatchAndDoesNotStartGrok()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-missing-terminal-receipt-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: root.appendingPathComponent("dispatches"))
        let objective =
            "Fable 5 完成 Island 並有 terminal receipt 後，Grok 4.6 才能開始 Aurora。"
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID,
            objective: objective,
            store: goalStore)
        let fableDispatch =
            try TatwoNativeDevelopmentDispatchCoordinator
                .beginSelectedExecutor(
                    contract: contract,
                    selectedModelID: "fable-5",
                    subtask: objective,
                    goalStore: goalStore,
                    dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let thread = TatwoNativeChatThread(
            title: "Missing terminal receipt",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: registry,
            nativeRunner: native)
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.pendingNativeDevelopmentDispatch = fableDispatch
        model.setSingleModel("fable-5", syncCollaborationLead: false)
        model.prompt = model.nativeDevelopmentLaneTask(
            modelID: "fable-5",
            objective: objective)

        model.submitCurrentChatTurn(applyPromptCollaboration: false)
        for _ in 0..<160 where native.startCount < 1 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        native.emit(.output("模型宣稱完成，但 runtime 沒有 terminal receipt"))
        native.emit(.exit(0))
        for _ in 0..<80 where model.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(native.startCount, 1)
        let record = try XCTUnwrap(
            registry.run(forContractID: contract.contractID)?
                .records.first(where: { $0.id == fableDispatch.id }))
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(
            record.failureReceipt?.errorCode,
            "native_terminal_receipt_missing")
        XCTAssertNil(record.receiptID)
        XCTAssertNil(record.outputRef)
    }

    @MainActor
    func testRunningNativeGoalAutoBeginsSelectedDispatchForMutationTurn()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-running-auto-dispatch-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "修好 Sol gateway",
            store: goalStore)
        let completedSeed =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: "先前已完成的 Sol 工具輪",
                goalStore: goalStore,
                dispatchRegistry: registry)
        _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
            contractID: contract.contractID,
            dispatchID: completedSeed.id,
            outputRef: "native-run:completed-seed",
            goalStore: goalStore,
            dispatchRegistry: registry)
        let native = RecordingNativeAgentRunner()
        let thread = TatwoNativeChatThread(
            title: "running native Goal",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: registry,
            nativeRunner: native)
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract =
            try WorkOSFactory.storedContractProjection(
                contractID: contract.contractID,
                fallbackMode: .xxl,
                fallbackScenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLSolOpusScenarioID,
                store: goalStore)
        model.selectedGoalRecord = nil
        model.setSingleModel("gpt-5.6-sol")
        model.prompt = "請修改 ChatPageModel.swift 並執行測試"

        XCTAssertNil(model.pendingNativeDevelopmentDispatch)
        XCTAssertEqual(
            model.nativeDevelopmentAccess(for: model.prompt),
            .mutation)

        model.submitCurrentChatTurn()

        for _ in 0..<160 where native.startCount == 0 && model.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let snapshot = ChatTurnContractEffortResolver.resolve(
            route: model.currentTurnDispatchRoute(),
            phase: .loops,
            contract: contract,
            uiSelectedEffort: .high)
        let records = try XCTUnwrap(TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL
        ).run(forContractID: contract.contractID)).records
        let dispatch = try XCTUnwrap(
            records.first { $0.id == native.request?.dispatchID })
        XCTAssertEqual(snapshot.contractBindingID, dispatch.sourceSlotID)
        XCTAssertNotEqual(snapshot.contractBindingID, dispatch.bindingID)
        XCTAssertNotEqual(
            model.lastNativeRuntimeStartBlocker,
            "mutation_dispatch_missing")
        XCTAssertEqual(native.startCount, 1)
        XCTAssertNotNil(native.request?.dispatchID)
        XCTAssertTrue(
            records.contains {
                $0.id == native.request?.dispatchID
                    && $0.status == .running
                    && $0.modelID == "gpt-5.6-sol"
            },
            "request=\(String(describing: native.request)) records=\(records)")
    }

    @MainActor
    func testBlockedNativeGoalRetriesFailedDispatchBeforeFreezingMutationTurn()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-blocked-retry-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "修好 Sol gateway",
            store: goalStore)
        let failedSeed =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: "先前 Sol 工具輪",
                goalStore: goalStore,
                dispatchRegistry: registry)
        _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
            contractID: contract.contractID,
            dispatchID: failedSeed.id,
            errorCode: "native_step_limit",
            message: "Native agent step limit reached",
            goalStore: goalStore,
            dispatchRegistry: registry)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .blocked)

        let native = RecordingNativeAgentRunner()
        let thread = TatwoNativeChatThread(
            title: "blocked native Goal",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: registry,
            nativeRunner: native)
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.setSingleModel("gpt-5.6-sol")
        model.prompt = """
            不修改任何檔案。只驗證 Sol 原生自主開發工具鏈。
            請依序使用 TATWO 原生工具：
            1. read_file 讀取 Package.swift
            2. git_diff 檢查 WorkOS.swift
            3. run_command 執行 /bin/pwd
            """

        model.submitCurrentChatTurn()

        for _ in 0..<160 where native.startCount == 0 && model.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let records = try XCTUnwrap(TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL
        ).run(forContractID: contract.contractID)).records
        let retry = try XCTUnwrap(
            records.first {
                $0.status == .running
                    && $0.supersedes == failedSeed.id
            })
        XCTAssertEqual(native.startCount, 1)
        XCTAssertEqual(native.request?.dispatchID, retry.id)
        XCTAssertEqual(native.request?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(native.request?.effort, "high")
        XCTAssertFalse(try XCTUnwrap(native.request).readOnly)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .running)
    }

    @MainActor
    func testBlockedNativeGoalStartsReadOnlySolSmokeWithoutCreatingDispatch()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-blocked-read-only-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
            objective: "修好 Sol gateway",
            store: goalStore)
        let failedSeed =
            try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
                contract: contract,
                subtask: "先前 Sol 工具輪",
                goalStore: goalStore,
                dispatchRegistry: registry)
        _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
            contractID: contract.contractID,
            dispatchID: failedSeed.id,
            errorCode: "native_step_limit",
            message: "Native agent step limit reached",
            goalStore: goalStore,
            dispatchRegistry: registry)

        let native = RecordingNativeAgentRunner()
        let thread = TatwoNativeChatThread(
            title: "blocked native Goal read-only smoke",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: registry,
            nativeRunner: native)
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.setSingleModel("gpt-5.6-sol")
        model.prompt = """
            延續目前同一個 Goal／contract，不建立新 Goal，不修改任何檔案，不重啟、不部署、不開第二個 App。這一輪只驗證 TATWO OS 自主開發工具鏈：必須使用 TATWO tatwo-native-agent，依序執行 read_file 讀取 Package.swift、git_diff 讀取 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkOS.swift 的目前差異、run_command 執行 /bin/pwd。禁止改用 gateway-direct、禁止改用模型內建 shell、禁止 fallback。完成後只回報三個 TATWO tool receipt、run_command exit code、實際工作目錄、route/model/effort attestation，以及 zero fallback。
            """

        XCTAssertEqual(
            model.nativeDevelopmentAccess(for: model.prompt),
            .readOnly)
        model.submitCurrentChatTurn()

        for _ in 0..<160 where native.startCount == 0 && model.isRunning {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(native.startCount, 1)
        XCTAssertEqual(native.request?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(native.request?.effort, "high")
        XCTAssertTrue(try XCTUnwrap(native.request).readOnly)
        XCTAssertNil(native.request?.dispatchID)
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .blocked)
    }

    func testPlannedGoalMutationShowsConfirmationGuidanceBeforeAnyRunnerStarts()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try ChatSourceFamily.read("ChatPageModel.swift")
        let start = try XCTUnwrap(source.range(
            of: "    func startTurn("))
        let end = try XCTUnwrap(source.range(
            of: "    func applyNativeGovernanceFallbackPresentation(",
            range: start.upperBound..<source.endIndex))
        let startTurn = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(startTurn.contains(
            "plannedNativeDevelopmentBlockerHint(for: visibleTurn)"))
        XCTAssertTrue(startTurn.contains("確認計畫，進入分工"))
        XCTAssertTrue(startTurn.contains("派工中／執行中"))
        XCTAssertLessThan(
            try XCTUnwrap(startTurn.range(
                of: "plannedNativeDevelopmentBlockerHint(for: visibleTurn)"))
                .lowerBound,
            try XCTUnwrap(startTurn.range(of: "runnerIdentity = dispatchService.startRuntime("))
                .lowerBound)
    }

    func testGoalConfirmationDoesNotLeaveRunningDispatchWhenRunnerNeverStarts()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflow = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(workflow.range(
            of: "    func commitPLGGoalFromPrompt()"))
        let end = try XCTUnwrap(workflow.range(
            of: "    @discardableResult\n    func beginSelectedNativeDevelopmentDispatch(",
            range: start.upperBound..<workflow.endIndex))
        let confirmation = String(
            workflow[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(confirmation.contains("guard !isRunning else"))
        XCTAssertTrue(confirmation.contains(
            "let nativeDispatchID = pendingNativeDevelopmentDispatch?.id"))
        XCTAssertTrue(confirmation.contains(
            "pendingNativeDevelopmentDispatch?.id == nativeDispatchID"))
        XCTAssertTrue(confirmation.contains(
            "failPendingNativeDevelopmentDispatchStart("))
    }

    /// 2026-08-21 HINTFIX-2：閉環驗收抓到 PLG 進 Goal 路徑把 composer 原始
    /// slug（預設 gpt-5.5，非合約 lane 成員）直接塞給 coordinator →
    /// selectedExecutorBindingMissing fail-closed。每一條原生派工路徑都
    /// 必須先經 selectedNativeDevelopmentExecutorModelID 映射到合約的
    /// active executor binding。
    func testEveryNativeDispatchPathResolvesExecutorThroughContractBindings()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflow = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)

        let confirmStart = try XCTUnwrap(workflow.range(
            of: "    func confirmPLGPlanAndStartLoops("))
        let confirmEnd = try XCTUnwrap(workflow.range(
            of: "    @discardableResult\n    func beginSelectedNativeDevelopmentDispatch(",
            range: confirmStart.upperBound..<workflow.endIndex))
        let confirmBody = String(
            workflow[confirmStart.lowerBound..<confirmEnd.lowerBound])
        XCTAssertTrue(
            confirmBody.contains(
                "selectedNativeDevelopmentExecutorModelID("),
            "PLG Goal confirmation must resolve the executor via contract bindings")
        XCTAssertFalse(
            confirmBody.contains(
                "let selectedModelID =\n            currentTurnDispatchRoute().canonicalModelSlug"),
            "raw composer slug must never reach the dispatch coordinator")

        let beginStart = try XCTUnwrap(workflow.range(
            of: "    func beginSelectedNativeDevelopmentDispatch("))
        let beginBody = String(workflow[beginStart.lowerBound...])
            .components(separatedBy: "\n    }\n")[0]
        XCTAssertTrue(
            beginBody.contains(
                "?? selectedNativeDevelopmentExecutorModelID("),
            "nil-default dispatch path must also resolve via contract bindings")

        // HINTFIX-3：lane 回合必須先把 turn route 對齊已解析 executor，
        // 否則 command 拿不到 native 開發權限 → native_access_denied。
        XCTAssertEqual(
            workflow.components(separatedBy:
                "alignTurnRouteForNativeDispatch(modelID: selectedModelID)\n"
            ).count - 1, 2,
            "both native lane submits must align the turn route to the resolved executor")
        XCTAssertTrue(
            confirmBody.contains(
                "alignTurnRouteForNativeDispatch(modelID: selectedModelID)"))
    }

    @MainActor
    func testGoalConfirmationCanRetryAfterPlanningAdvancedButDispatchDidNotStart() {
        XCTAssertTrue(
            ChatPageModel.canCommitPLGGoal(from: .planning))
        XCTAssertTrue(
            ChatPageModel.canCommitPLGGoal(from: .leadAdversarial))
        XCTAssertFalse(
            ChatPageModel.canCommitPLGGoal(from: .awaitingHumanAuth))
        XCTAssertFalse(
            ChatPageModel.canCommitPLGGoal(from: .executingLoops))
    }

    func testGoalSlashRoutesRetryableLeadAdversarialPhaseBackToPLGCommit()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflow = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(workflow.range(
            of: "    func commitOrActivateGoalFromPrompt("))
        let end = try XCTUnwrap(workflow.range(
            of: "    func activateGoalFromPrompt(",
            range: start.upperBound..<workflow.endIndex))
        let routing = String(workflow[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(routing.contains(
            "Self.canCommitPLGGoal(from: phase)"))
        XCTAssertTrue(routing.contains("commitPLGGoalFromPrompt()"))
    }

    func testStopUsesDispatchSnapshotAndTerminatesBothRuntimeDomains()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try ChatSourceFamily.read("ChatPageModel.swift")
        let start = try XCTUnwrap(source.range(of: "    func stop() {"))
        let end = try XCTUnwrap(source.range(
            of: "    func startRunnerStateReconciler(",
            range: start.upperBound..<source.endIndex))
        let stop = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(stop.contains(
            "terminateRunnersForCurrentSession()"))
        let helperStart = try XCTUnwrap(source.range(
            of: "    func terminateRunnersForCurrentSession()"))
        let helperEnd = try XCTUnwrap(source.range(
            of: "    func selectStandaloneThread(",
            range: helperStart.upperBound..<source.endIndex))
        let helper = String(
            source[helperStart.lowerBound..<helperEnd.lowerBound])
        XCTAssertTrue(helper.contains(
            "cliRunnersBySessionKey[key]?.terminate()"))
        XCTAssertTrue(helper.contains(
            "nativeRunnersBySessionKey[key]?.terminate()"))
    }

    func testNativeRuntimeEventsMapToTypedChatActivity() {
        let invocation = TatwoNativeToolInvocationID(
            modelStep: 1,
            toolIndex: 0,
            providerCallID: "provider-call")

        guard case .thinking(let thinking) = ChatNativeAgentRunner.chatEvent(
            from: TatwoNativeAgentEvent(kind: .modelRequested(step: 1)))
        else {
            return XCTFail("model progress must become typed thinking activity")
        }
        XCTAssertEqual(thinking.rawType, "native_model")

        guard case .toolUse(let started) = ChatNativeAgentRunner.chatEvent(
            from: TatwoNativeAgentEvent(
                kind: .toolRequested(
                    invocation: invocation,
                    name: "read_file")))
        else {
            return XCTFail("tool request must become typed tool activity")
        }
        XCTAssertEqual(started.text, "read_file")
        XCTAssertEqual(started.rawType, "native_tool_started")

        guard case .toolUse(let completed) = ChatNativeAgentRunner.chatEvent(
            from: TatwoNativeAgentEvent(
                kind: .toolCompleted(
                    invocation: invocation,
                    isError: false)))
        else {
            return XCTFail("tool completion must become typed tool activity")
        }
        XCTAssertEqual(completed.rawType, "native_tool_completed")
    }

    func testProductionNativeCompositionUsesBundledSubscriptionRuntime()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = try ChatSourceFamily.read("ChatRuntime.swift")
        let pageModel = try ChatSourceFamily.read("ChatPageModel.swift")
        let governedRunner = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/GovernedDevSessionRunner.swift"),
            encoding: .utf8)

        // M4a 更新：只替換 ChatNativeAgentRunning 的生產注入縫；
        // lifecycle/root-isolation 與 startRuntime 守門保持原測試合約。
        XCTAssertTrue(pageModel.contains("GovernedDevSessionRunner("))
        XCTAssertTrue(pageModel.contains(
            "TatwoNativeAgentRunnerBuildConfiguration"))
        XCTAssertTrue(governedRunner.contains(
            "ChatNativeSubscriptionRuntimeLocator.helperName"))
        XCTAssertTrue(governedRunner.contains(
            "ChatNativeClaudeSubscriptionRuntimeLocator.helperName"))
        XCTAssertTrue(governedRunner.contains(
            "case .grokAttestationUnverified: \"grok_dev_attestation_unverified\""))
        XCTAssertFalse(governedRunner.contains(
            "[\"--permission-mode\", \"bypassPermissions\"]"))
        XCTAssertFalse(governedRunner.contains(
            "[\"-s\", \"danger-full-access\"]"))
        XCTAssertFalse(runtime.contains(".codex/auth.json"))
        XCTAssertFalse(runtime.contains("127.0.0.1:4177"))
        XCTAssertFalse(runtime.contains("ChatNativeGatewayCodexAuthHeaderProvider"))
        XCTAssertFalse(pageModel.contains("ChatNativeGatewayCodexAuthHeaderProvider"))
        XCTAssertTrue(runtime.contains(
            "ChatNativeOpenAISubscriptionModelTransport"))
        XCTAssertTrue(runtime.contains(
            "ChatNativeClaudeSubscriptionModelTransport"))
        XCTAssertTrue(runtime.contains(
            "ChatNativeGrokSubscriptionModelTransport"))
        XCTAssertFalse(runtime.contains("TatwoNativeDirectResponsesTransport("))
        XCTAssertFalse(runtime.contains("TatwoNativeAnthropicMessagesTransport("))
        XCTAssertFalse(runtime.contains("ChatNativeSolKeychainCredentialBroker()"))
        XCTAssertFalse(runtime.contains("ChatNativeOpusKeychainCredentialBroker()"))
    }

    func testProductionSubscriptionRunnerForcesSolAndOpusHigh() {
        XCTAssertEqual(
            ChatNativeAgentRunner.requiredSubscriptionEffort(
                modelID: "gpt-5.6-sol",
                requestedEffort: "low"),
            "high")
        XCTAssertEqual(
            ChatNativeAgentRunner.requiredSubscriptionEffort(
                modelID: "opus-5",
                requestedEffort: "medium"),
            "high")
        XCTAssertEqual(
            ChatNativeAgentRunner.requiredSubscriptionEffort(
                modelID: "fable-5",
                requestedEffort: "high"),
            "medium")
        XCTAssertEqual(
            ChatNativeAgentRunner.requiredSubscriptionEffort(
                modelID: "grok-build",
                requestedEffort: "medium"),
            "high")
        XCTAssertEqual(
            ChatNativeAgentRunner.requiredSubscriptionEffort(
                modelID: "unknown-model",
            requestedEffort: "low"),
            "low")
    }

    func testProductionRunnerAllowsThirtyMinuteNativeDevelopmentWindow() {
        XCTAssertEqual(
            ChatNativeAgentRunner.productionMaximumRunDuration,
            30 * 60)
        // M4a 更新：新載具沿用同一 production 30 分鐘上限。
        XCTAssertEqual(
            GovernedDevSessionRunner.productionMaximumRunDuration,
            30 * 60)
    }

    func testProductionRunnerAllowsFullNativeDevelopmentToolLoop() {
        XCTAssertEqual(
            ChatNativeAgentRunner.productionMaximumModelSteps,
            96)
        XCTAssertEqual(
            ChatNativeAgentRunner.productionMaximumToolCalls,
            256)
    }

    func testTerminateStopsBlockedSubscriptionSessionAndEmitsCancelledExit()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-runner-cancellation-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = BlockingRunnerSubscriptionSession()
        let recorder = ChatNativeEventRecorder()
        let runner = ChatNativeAgentRunner(
            subscriptionSessionFactory: { _ in session },
            journalDirectoryURL: root)

        XCTAssertNotNil(runner.start(
            request: ChatNativeAgentRunRequest(
                runID: "blocked-subscription",
                dispatchID: nil,
                prompt: "inspect",
                modelID: "gpt-5.6-sol",
                effort: "high",
                contractID: "contract",
                workspaceRoot: root.path,
                readOnly: true)
        ) { event in
            recorder.append(event)
        })
        await session.waitUntilListening()

        runner.terminate()
        for _ in 0..<100 {
            if await session.stopCountValue() > 0,
               recorder.events.contains(where: {
                   guard case .exit(130) = $0 else { return false }
                   return true
               })
            {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stopCountBeforeRelease = await session.stopCountValue()
        let eventsBeforeRelease = recorder.events
        await session.release()

        XCTAssertEqual(
            stopCountBeforeRelease,
            1,
            "Cancelling a native run must stop its live subscription session.")
        XCTAssertTrue(eventsBeforeRelease.contains {
            guard case .exit(130) = $0 else { return false }
            return true
        })
    }

    func testProductionRunnerRejectsUnsupportedModelBeforeCredentialOrNetwork()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-runner-unsupported-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subscription = RunnerSubscriptionSessionFactoryCapture()
        let recorder = ChatNativeEventRecorder()
        let exited = expectation(description: "unsupported model exits")
        let runner = ChatNativeAgentRunner(
            subscriptionSessionFactory: { scratch in
                subscription.make(scratch: scratch)
            },
            journalDirectoryURL: root)

        XCTAssertNotNil(runner.start(
            request: ChatNativeAgentRunRequest(
                runID: "unsupported-model",
                dispatchID: nil,
                prompt: "run tests",
                modelID: "unknown-model",
                effort: "high",
                contractID: "contract",
                workspaceRoot: root.path,
                readOnly: false)
        ) { event in
            recorder.append(event)
            if case .exit = event {
                exited.fulfill()
            }
        })
        await fulfillment(of: [exited], timeout: 2)

        XCTAssertEqual(subscription.makeCount, 0)
        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        guard case .runtimeFailure(let message) = events[0] else {
            return XCTFail("unsupported model must fail closed")
        }
        XCTAssertEqual(
            message,
            "TATWO subscription runtime unavailable for selected model")
        guard case .exit(1) = events[1] else {
            return XCTFail("unsupported model must terminate unsuccessfully")
        }
    }

    func testProductionRunnerSelectsOpusThroughSubscriptionRuntime()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-runner-opus-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subscription = RunnerClaudeSubscriptionProcessCapture(
            assistantText: "OPUS_SUBSCRIPTION_OK")
        let recorder = ChatNativeEventRecorder()
        let exited = expectation(description: "Opus subscription route exits")
        let runner = ChatNativeAgentRunner(
            claudeSubscriptionRunnerFactory: { subscription },
            journalDirectoryURL: root)

        XCTAssertNotNil(runner.start(
            request: ChatNativeAgentRunRequest(
                runID: "opus-direct",
                dispatchID: nil,
                prompt: "inspect",
                modelID: "opus-5",
                effort: "high",
                contractID: "contract",
                workspaceRoot: root.path,
                readOnly: true)
        ) { event in
            recorder.append(event)
            if case .exit = event {
                exited.fulfill()
            }
        })
        await fulfillment(of: [exited], timeout: 2)

        XCTAssertEqual(subscription.authStatusCount, 1)
        XCTAssertEqual(subscription.modelRunCount, 1)
        XCTAssertEqual(subscription.recordedModel, "claude-opus-5")
        XCTAssertEqual(subscription.recordedEffort, "high")
        XCTAssertTrue(recorder.events.contains {
            guard case .output(let text) = $0 else { return false }
            return text == "OPUS_SUBSCRIPTION_OK"
        })
        guard case .exit(0) = recorder.events.last else {
            return XCTFail(
                "Opus subscription completion must exit successfully")
        }
    }

    @MainActor
    func testUnavailableCLIAdapterEmitsMachineReadableFailureWithoutStartingGateway()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-unavailable-cli-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        let recorder = ChatNativeEventRecorder()
        let command = ChatCLICommand(
            engine: .claude,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .unavailable,
            commandMode: .chat,
            runtimeFallbackReason: .claudeExecutableUnavailable)
        let snapshot = ChatTurnDispatchSnapshot(
            routeID: "fable5",
            canonicalModelID: "fable-5",
            vendorModelID: nil,
            phase: .loops,
            contractID: nil,
            contractBindingID: nil,
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)

        XCTAssertNotNil(DefaultChatDispatchService().startRuntime(
            model: model,
            command: command,
            nativePrompt: "reply",
            dispatchSnapshot: snapshot,
            runID: "unavailable-cli",
            activityTurnID: "assistant-turn",
            onEvent: recorder.append))

        XCTAssertEqual(recorder.events.count, 1)
        guard case .runtimeFailure(let message) = recorder.events[0] else {
            return XCTFail("unavailable adapter must terminate with runtimeFailure")
        }
        XCTAssertTrue(message.contains("runtime_unavailable"))
        XCTAssertTrue(
            message.contains(
                TatwoChatRuntimeFallbackReason
                    .claudeExecutableUnavailable.rawValue))
        XCTAssertTrue(message.contains("請更新/重裝 App"))
        XCTAssertFalse(message.contains("gateway"))
        XCTAssertFalse(message.contains("4177"))
    }

    @MainActor
    func testAskFirstPermissionStartsNativeRuntimeReadOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-agent-read-only-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
            objective: "native read only route",
            store: goalStore)
        let native = RecordingNativeAgentRunner()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            nativeRunner: native)
        model.selectedWorkOSContract = contract
        let thread = TatwoNativeChatThread(
            title: "native read only",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        model.document = TatwoNativeChatStoreDocument(threads: [thread])
        model.selectedThreadID = thread.id
        model.permissionPreset = .askFirst
        let command = ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .nativeAgent,
            commandMode: .chat,
            nativeDevelopmentAccess: .readOnly)
        let snapshot = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: nil,
            phase: .plan,
            contractID: contract.contractID,
            contractBindingID: try nativeBindingID(
                in: contract,
                phase: .plan,
                modelID: "gpt-5.6-sol"),
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)

        XCTAssertNotNil(DefaultChatDispatchService().startRuntime(
            model: model,
            command: command,
            nativePrompt: "inspect only",
            dispatchSnapshot: snapshot,
            runID: "native-read-only",
            activityTurnID: "assistant-turn"
        ) { _ in })
        XCTAssertEqual(native.request?.readOnly, true)
        XCTAssertEqual(native.request?.permissionPreset, .askFirst)
    }

    @MainActor
    func testNativeAdapterStartsInjectedInProcessRunnerInsteadOfFalseCLIPlaceholder()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-agent-routing-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xl,
            scenarioProfileID: "general-xl-fable5",
            objective: "native in-process coding route",
            store: goalStore)
        let native = RecordingNativeAgentRunner()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            nativeRunner: native)
        model.selectedWorkOSContract = contract
        let thread = TatwoNativeChatThread(
            title: "native mutation",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        model.document = TatwoNativeChatStoreDocument(threads: [thread])
        model.selectedThreadID = thread.id
        try goalStore.updateStatus(
            contractID: contract.contractID,
            status: .dispatching)

        let command = ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .nativeAgent,
            commandMode: .chat,
            nativeDevelopmentAccess: .mutation)
        let snapshot = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: nil,
            phase: .loops,
            contractID: contract.contractID,
            contractBindingID: try nativeBindingID(
                in: contract,
                phase: .loops,
                modelID: "gpt-5.6-sol"),
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)
        let receivedEvents = ChatNativeEventRecorder()

        let identity = DefaultChatDispatchService().startRuntime(
            model: model,
            command: command,
            nativePrompt: "修改程式並執行測試",
            dispatchSnapshot: snapshot,
            runID: "native-run",
            activityTurnID: "assistant-turn"
        ) { event in
            receivedEvents.append(event)
        }

        XCTAssertNotNil(identity)
        let request = try XCTUnwrap(native.request)
        XCTAssertEqual(request.runID, "native-run")
        XCTAssertEqual(request.prompt, "修改程式並執行測試")
        XCTAssertEqual(request.modelID, "gpt-5.6-sol")
        XCTAssertEqual(request.effort, "high")
        XCTAssertEqual(request.contractID, contract.contractID)
        XCTAssertEqual(
            URL(fileURLWithPath: request.workspaceRoot).standardizedFileURL,
            root.standardizedFileURL)
        XCTAssertFalse(request.readOnly)
        XCTAssertEqual(native.startCount, 1)
        XCTAssertEqual(native.terminateCount, 0)

        native.emit(.output("native reply"))
        native.emit(.exit(0))
        let events = receivedEvents.events
        XCTAssertEqual(events.count, 2)
        guard case .output("native reply") = events[0] else {
            return XCTFail("native output callback was not forwarded")
        }
        guard case .exit(0) = events[1] else {
            return XCTFail("native terminal callback was not forwarded")
        }
    }

    @MainActor
    func testCompatibilityAdapterDoesNotStartNativeRunner() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-agent-compat-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = RecordingNativeAgentRunner()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: root),
            nativeRunner: native)
        let command = ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .codexExec,
            commandMode: .chat)
        let snapshot = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: nil,
            phase: .loops,
            contractID: nil,
            contractBindingID: nil,
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)

        XCTAssertNotNil(
            DefaultChatDispatchService().startRuntime(
            model: model,
                command: command,
                nativePrompt: "compatibility",
                dispatchSnapshot: snapshot,
                runID: "compat-run",
                activityTurnID: "assistant-turn"
            ) { _ in })
        XCTAssertEqual(native.startCount, 0)
    }

    @MainActor
    func testNonDispatchNativeGuardFailureFallsBackToCLIWithReason() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-agent-user-turn-fallback-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = RecordingNativeAgentRunner()
        let model = makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(directoryURL: root),
            native: native)
        let assistantID = UUID().uuidString
        model.messages = [
            ChatMessage(
                id: assistantID,
                role: .assistant,
                text: "",
                status: "streaming",
                runtimeAdapterID:
                    TatwoChatRuntimeAdapter.nativeAgent.rawValue)
        ]
        model.activeAssistantID = assistantID
        let nativeCommand = ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .nativeAgent,
            commandMode: .chat,
            nativeDevelopmentAccess: .none)
        let fallbackCommand = ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/true",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .codexExec,
            commandMode: .chat)
        let snapshot = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: nil,
            phase: .loops,
            contractID: nil,
            contractBindingID: nil,
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)

        XCTAssertNotNil(DefaultChatDispatchService().startRuntime(
            model: model,
            command: nativeCommand,
            nativePrompt: "ordinary user turn",
            dispatchSnapshot: snapshot,
            runID: "user-turn-fallback",
            activityTurnID: assistantID,
            allowsNativeGovernanceFallback: true,
            nativeGovernanceFallbackCommand: fallbackCommand
        ) { _ in })
        XCTAssertEqual(native.startCount, 0)
        XCTAssertEqual(
            model.messages.first?.runtimeAdapterID,
            TatwoChatRuntimeAdapter.codexExec.rawValue)
        XCTAssertEqual(
            model.messages.first?.runtimeFallbackReason,
            .nativeGovernanceNotEngaged)
        XCTAssertEqual(
            model.lastNativeRuntimeStartBlocker,
            "native_access_denied")
    }

    @MainActor
    func testNativeRuntimeBindsOnlyToFrozenDispatchContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-agent-contract-binding-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let contractA = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
            objective: "contract A",
            store: goalStore)
        let contractB = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
            objective: "contract B",
            store: goalStore)
        let native = RecordingNativeAgentRunner()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            nativeRunner: native)
        model.selectedWorkOSContract = contractB
        let thread = TatwoNativeChatThread(
            title: "contract B",
            workOSGoalID: contractB.goalID,
            workOSContractID: contractB.contractID)
        model.document = TatwoNativeChatStoreDocument(threads: [thread])
        model.selectedThreadID = thread.id

        let command = ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .nativeAgent,
            commandMode: .chat,
            nativeDevelopmentAccess: .readOnly)
        let mismatched = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: nil,
            phase: .plan,
            contractID: contractA.contractID,
            contractBindingID: try nativeBindingID(
                in: contractA,
                phase: .plan,
                modelID: "gpt-5.6-sol"),
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)

        XCTAssertNil(DefaultChatDispatchService().startRuntime(
            model: model,
            command: command,
            nativePrompt: "read only",
            dispatchSnapshot: mismatched,
            runID: "mismatch",
            activityTurnID: "assistant-turn"
        ) { _ in })
        XCTAssertEqual(native.startCount, 0)
    }

    @MainActor
    func testNativeRuntimeRejectsRouteAndCanonicalModelMismatch() throws {
        let fixture = try makeNativeRuntimeFixture("route-model-mismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.selectedWorkOSContract = fixture.contract
        attachThread(to: fixture.model, contract: fixture.contract)
        try fixture.goalStore.updateStatus(
            contractID: fixture.contract.contractID,
            status: .dispatching)

        let mismatched = ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "opus-5",
            vendorModelID: nil,
            phase: .loops,
            contractID: fixture.contract.contractID,
            contractBindingID: try nativeBindingID(
                in: fixture.contract,
                phase: .loops,
                modelID: "opus-5"),
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)

        XCTAssertNil(DefaultChatDispatchService().startRuntime(
            model: fixture.model,
            command: nativeCommand(access: .mutation, root: fixture.root),
            nativePrompt: "run tests",
            dispatchSnapshot: mismatched,
            runID: "route-model-mismatch",
            activityTurnID: "assistant-turn"
        ) { _ in })
        XCTAssertEqual(fixture.native.startCount, 0)
    }

    @MainActor
    func testNativeRuntimeRequiresSelectedThreadPointer() throws {
        let fixture = try makeNativeRuntimeFixture("missing-thread")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.selectedWorkOSContract = fixture.contract

        XCTAssertNil(DefaultChatDispatchService().startRuntime(
            model: fixture.model,
            command: nativeCommand(access: .readOnly, root: fixture.root),
            nativePrompt: "inspect",
            dispatchSnapshot: try nativeSnapshot(
                contract: fixture.contract,
                phase: .plan),
            runID: "missing-thread",
            activityTurnID: "assistant-turn"
        ) { _ in })
        XCTAssertEqual(fixture.native.startCount, 0)
        XCTAssertEqual(
            fixture.model.lastNativeRuntimeStartBlocker,
            "selected_thread_missing")
    }

    @MainActor
    func testNativeRuntimeRejectsSelectedThreadGoalMismatch() throws {
        let fixture = try makeNativeRuntimeFixture("thread-goal-mismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.selectedWorkOSContract = fixture.contract
        let thread = TatwoNativeChatThread(
            title: "wrong goal pointer",
            workOSGoalID: "goal-other",
            workOSContractID: fixture.contract.contractID)
        fixture.model.document = TatwoNativeChatStoreDocument(
            threads: [thread])
        fixture.model.selectedThreadID = thread.id

        XCTAssertNil(DefaultChatDispatchService().startRuntime(
            model: fixture.model,
            command: nativeCommand(access: .readOnly, root: fixture.root),
            nativePrompt: "inspect",
            dispatchSnapshot: try nativeSnapshot(
                contract: fixture.contract,
                phase: .plan),
            runID: "thread-goal-mismatch",
            activityTurnID: "assistant-turn"
        ) { _ in })
        XCTAssertEqual(fixture.native.startCount, 0)
    }

    @MainActor
    func testNativeRuntimeRequiresIssuedGoalInItsOwnStore() throws {
        let fixture = try makeNativeRuntimeFixture("missing-store")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let emptyStoreRoot = fixture.root.appendingPathComponent("empty-store")
        let emptyStore = TatwoGoalRunStore(directoryURL: emptyStoreRoot)
        let native = RecordingNativeAgentRunner()
        let model = makeModel(
            root: fixture.root.appendingPathComponent("model"),
            goalStore: emptyStore,
            native: native)
        model.selectedWorkOSContract = fixture.contract
        attachThread(to: model, contract: fixture.contract)

        XCTAssertNil(DefaultChatDispatchService().startRuntime(
            model: model,
            command: nativeCommand(access: .readOnly, root: fixture.root),
            nativePrompt: "inspect",
            dispatchSnapshot: try nativeSnapshot(
                contract: fixture.contract,
                phase: .plan),
            runID: "missing-store",
            activityTurnID: "assistant-turn"
        ) { _ in })
        XCTAssertEqual(native.startCount, 0)
    }

    @MainActor
    func testNativeRuntimeRejectsTerminalStoreDrift() throws {
        let fixture = try makeNativeRuntimeFixture("terminal-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.selectedWorkOSContract = fixture.contract
        attachThread(to: fixture.model, contract: fixture.contract)
        let registry = TatwoDispatchRegistry(
            directoryURL: fixture.goalStore.directoryURL)
        let binding = try XCTUnwrap(
            fixture.contract.identityBindings.first(where: {
                $0.modelID != nil
            }))
        let modelID = try XCTUnwrap(binding.modelID)
        let dispatch = try TatwoGoalRunDispatchLifecycle.begin(
            contractID: fixture.contract.contractID,
            bindingID: binding.id,
            sourceSlotID: binding.sourceSlotID,
            identity: binding.identity,
            modelID: modelID,
            subtask: "canonical terminal drift fixture",
            helperCap: try XCTUnwrap(
                TatwoCatalog.defaults.mode(fixture.contract.mode)?
                    .maxHelpers),
            goalStore: fixture.goalStore,
            dispatchRegistry: registry,
            scenarioBook: TatwoScenarioConfigDefaults.book)
        _ = try TatwoGoalRunDispatchLifecycle.update(
            contractID: fixture.contract.contractID,
            dispatchID: dispatch.id,
            status: .completed,
            receiptID: "terminal:\(dispatch.id)",
            outputRef: "tatwo-test://terminal-drift/\(dispatch.id)",
            goalStore: fixture.goalStore,
            dispatchRegistry: registry)
        _ = try TatwoGoalRunDispatchLifecycle.finalize(
            contractID: fixture.contract.contractID,
            goalStore: fixture.goalStore,
            dispatchRegistry: registry)
        for requirement in fixture.contract.receiptRequirements
        where requirement.requiredForPass {
            let submission = WorkOSFactory.submitReceipt(
                goalID: fixture.contract.goalID,
                contractID: fixture.contract.contractID,
                loopID: fixture.contract.mainlineLoop.id,
                receiptID: "evidence-\(requirement.id)",
                receiptKind: requirement.kind,
                satisfiesRequirementID: requirement.id,
                store: fixture.goalStore)
            XCTAssertTrue(
                submission.ok,
                submission.decision.message)
        }
        let closed = try WorkOSFactory.closeGoal(
            goalID: fixture.contract.goalID,
            contractID: fixture.contract.contractID,
            mode: fixture.contract.mode,
            scenarioProfileID: fixture.contract.scenario,
            objective: fixture.contract.objective,
            suppliedReceiptIDs: [],
            store: fixture.goalStore,
            dispatchRegistry: registry)
        XCTAssertTrue(closed.ok, closed.decision.message)
        XCTAssertEqual(closed.status, .passed)

        XCTAssertNil(DefaultChatDispatchService().startRuntime(
            model: fixture.model,
            command: nativeCommand(access: .readOnly, root: fixture.root),
            nativePrompt: "inspect",
            dispatchSnapshot: try nativeSnapshot(
                contract: fixture.contract,
                phase: .plan),
            runID: "terminal-drift",
            activityTurnID: "assistant-turn"
        ) { _ in })
        XCTAssertEqual(fixture.native.startCount, 0)
    }

    @MainActor
    private func makeNativeRuntimeFixture(
        _ name: String
    ) throws -> (
        root: URL,
        goalStore: TatwoGoalRunStore,
        contract: TatwoWorkOSContractV1,
        native: RecordingNativeAgentRunner,
        model: ChatPageModel
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-native-agent-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
            objective: name,
            store: goalStore)
        let native = RecordingNativeAgentRunner()
        return (
            root,
            goalStore,
            contract,
            native,
            makeModel(root: root, goalStore: goalStore, native: native))
    }

    @MainActor
    private func makeNativeDevelopmentModel(
        root: URL,
        goalStore: TatwoGoalRunStore,
        registry: TatwoDispatchRegistry,
        contract: TatwoWorkOSContractV1,
        dispatch: TatwoDispatchRecord?,
        modelID: String,
        native: RecordingNativeAgentRunner,
        receiptSubmitter: @escaping
            ChatNativeDevelopmentReceiptSubmitting = {
                goalID,
                contractID,
                loopID,
                receiptID,
                receiptKind,
                satisfiesRequirementID,
                store in
                WorkOSFactory.submitReceipt(
                    goalID: goalID,
                    contractID: contractID,
                    loopID: loopID,
                    receiptID: receiptID,
                    receiptKind: receiptKind,
                    satisfiesRequirementID: satisfiesRequirementID,
                    store: store)
            }
    ) throws -> ChatPageModel {
        let thread = TatwoNativeChatThread(
            title: "M4b native development",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: registry,
            nativeDevelopmentReceiptSubmitter: receiptSubmitter,
            nativeRunner: native)
        model.selectStandaloneThread(thread.id)
        model.selectedWorkOSContract = contract
        model.selectedGoalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        model.pendingNativeDevelopmentDispatch = dispatch
        model.setSingleModel(
            modelID,
            syncCollaborationLead: false)
        model.prompt = model.nativeDevelopmentLaneTask(
            modelID: modelID,
            objective: contract.objective)
        return model
    }

    private func writeM4bEvidenceArtifact(
        root: URL,
        request: ChatNativeAgentRunRequest,
        terminalReceiptID: String,
        provesRollback: Bool = true,
        hasGitEvidence: Bool = true
    ) throws -> URL {
        let repositoryRoot = root.appendingPathComponent(
            "repository",
            isDirectory: true)
        let worktree = repositoryRoot
            .appendingPathComponent(".worktrees", isDirectory: true)
            .appendingPathComponent(
                "m4b-\(request.dispatchID ?? request.runID)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktree,
            withIntermediateDirectories: true)
        if hasGitEvidence {
            try FileManager.default.createDirectory(
                at: repositoryRoot.appendingPathComponent(
                    ".git",
                    isDirectory: true),
                withIntermediateDirectories: true)
            try Data("gitdir: test".utf8).write(
                to: worktree.appendingPathComponent(
                    ".git",
                    isDirectory: false))
        }
        let artifactURL = root
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(
                "\(request.runID).json",
                isDirectory: false)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let baseCommit = provesRollback
            ? String(repeating: "a", count: 40)
            : "rollback-evidence-missing"
        let artifact = GovernedDevSessionArtifactV1(
            schema: "GovernedDevSessionArtifactV1",
            runID: request.runID,
            dispatchID: request.dispatchID,
            contractID: request.contractID,
            modelID: request.modelID,
            effort: request.effort,
            readOnly: request.readOnly,
            repositoryRoot: repositoryRoot.path,
            worktreePath: worktree.path,
            worktreeBranch: "tatwo/m4b-test",
            baseCommit: baseCommit,
            outputRefDescription: "M4b test artifact",
            preRunDigest: GovernedDevGitDigestV1(
                headCommit: baseCommit,
                statusPorcelainSHA256:
                    String(repeating: "b", count: 64)),
            postRunDigest: GovernedDevGitDigestV1(
                headCommit: String(repeating: "c", count: 40),
                statusPorcelainSHA256:
                    String(repeating: "d", count: 64)),
            diffStat: "1 file changed",
            changedFiles: ["ChatPageModel.swift"],
            cliJSONEventCount: 1,
            commandEventCount: 1,
            toolEventCount: 1,
            stdoutSHA256: String(repeating: "e", count: 64),
            stderrSHA256: String(repeating: "f", count: 64),
            terminalReceiptID: terminalReceiptID,
            completedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifact).write(
            to: artifactURL,
            options: [.atomic])
        return artifactURL
    }

    @MainActor
    private func waitForDispatchStatus(
        _ expected: TatwoDispatchStatus,
        dispatchID: String,
        contractID: String,
        registry: TatwoDispatchRegistry
    ) async throws {
        for _ in 0..<160 {
            if try registry.run(forContractID: contractID)?
                .records.first(where: { $0.id == dispatchID })?
                .status == expected
            {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail(
            "dispatch \(dispatchID) did not reach \(expected.rawValue)")
    }

    @MainActor
    private func makeComposerHintModel(root: URL) -> ChatPageModel {
        makeModel(
            root: root,
            goalStore: TatwoGoalRunStore(
                directoryURL: root.appendingPathComponent("goals")),
            native: RecordingNativeAgentRunner())
    }

    @MainActor
    private func makeModel(
        root: URL,
        goalStore: TatwoGoalRunStore,
        native: RecordingNativeAgentRunner
    ) -> ChatPageModel {
        ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatNativeAgentRoutingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            // Routing tests must not depend on the host login Keychain.
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ChatNativeAgentTestAnchorAuthority()),
            nativeRunner: native)
    }

    @MainActor
    private func attachThread(
        to model: ChatPageModel,
        contract: TatwoWorkOSContractV1
    ) {
        let thread = TatwoNativeChatThread(
            title: "native runtime",
            workOSGoalID: contract.goalID,
            workOSContractID: contract.contractID)
        model.document = TatwoNativeChatStoreDocument(threads: [thread])
        model.selectedThreadID = thread.id
    }

    private func nativeCommand(
        access: TatwoNativeDevelopmentAccess,
        root: URL
    ) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .nativeAgent,
            commandMode: .chat,
            nativeDevelopmentAccess: access)
    }

    private func nativeSnapshot(
        contract: TatwoWorkOSContractV1,
        phase: TatwoScenarioPhase
    ) throws -> ChatTurnDispatchSnapshot {
        ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-sol",
            canonicalModelID: "gpt-5.6-sol",
            vendorModelID: nil,
            phase: phase,
            contractID: contract.contractID,
            contractBindingID: try nativeBindingID(
                in: contract,
                phase: phase,
                modelID: "gpt-5.6-sol"),
            requestedEffort: .high,
            forwardedEffort: .high,
            effortOutcome: .forwardedAwaitingProvider,
            blocker: nil)
    }

    private func nativeBindingID(
        in contract: TatwoWorkOSContractV1,
        phase: TatwoScenarioPhase,
        modelID: String
    ) throws -> String {
        try XCTUnwrap(
            contract.loopGovernorDecision.activatedBindings.first {
                $0.enabled
                    && $0.dynamicActivation != .disabled
                    && $0.phase == phase
                    && $0.boundModelIDs.contains {
                        TatwoGatewayDispatchCatalog.normalize($0)
                            == TatwoGatewayDispatchCatalog.normalize(modelID)
                    }
            }?.id)
    }

    // MARK: staging69 live regression — Ultrawork S PLG confirm

    /// 2026-08-28 staging69 live evidence（PID 15491，bundle
    /// `com.tatwo.ultrawork.staging.s20260827T192055Z.09735968`）：fresh PLG
    /// thread 是 Ultrawork **S**／主導 GPT-5.6 Terra，簽發的合約是
    /// `mode=S, scenario=daily`，identityBindings 只有 lead + verifier、
    /// `authority=brain_only`、`canMutateHost=false`。按下【確認計畫，進入
    /// 分工】後 UI 停在「PLG 未能進入 Goal：exact Scenario 沒有可驗證的
    /// active executor binding」，Loops 卡維持尚未派發、0 planned branches、
    /// 無 runtime receipt。
    ///
    /// 根因是確認鍵只實作 XXL exact 原生開發 lane；S 合約結構上不可能有
    /// `toolIntentBridge` executor binding，所以永遠 fail-closed。
    @MainActor
    func testUltraworkSinglePLGConfirmationStartsLeadBoundGoalDispatch()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-plg-s-confirm-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(
            root: root,
            goalStore: goalStore,
            native: RecordingNativeAgentRunner())
        model.newChat()

        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "在沙盒建立三個檔案並通過測試",
                requireObjectiveMatch: true,
                allowCreateIfUnbound: true,
                automaticallyBootstrapUserOwnedAuthority: true,
                forceSingleModel: true),
            model.selectedWorkOSStateMessage)
        let contract = try XCTUnwrap(model.selectedWorkOSContract)

        // Live shape assertions: this is the exact contract that made the
        // native executor resolver structurally unsatisfiable.
        XCTAssertEqual(contract.mode, .s)
        XCTAssertFalse(
            ChatPageModel.isExactNativeDevelopmentScenario(
                contract.scenario))
        XCTAssertTrue(
            contract.identityBindings.allSatisfy { !$0.canMutateHost },
            "S contract must stay brain-only; no toolIntentBridge executor")
        XCTAssertTrue(
            contract.identityBindings.contains { $0.identity == .lead })

        // Screenshot state: planning already advanced to leadAdversarial
        // (「主導群對抗驗證中」), which `canCommitPLGGoal` treats as retryable.
        var run = TatwoPLGRunFactory.make(
            objective: contract.objective,
            contractID: contract.contractID,
            goalID: contract.goalID,
            leadModelIDs: contract.identityBindings
                .filter { $0.identity == .lead }
                .compactMap(\.modelID),
            subModelIDs: [],
            nowISO: "2026-08-28T01:44:00Z")
        run.phase = .leadAdversarial
        model.activePLGRun = run

        XCTAssertTrue(
            model.confirmPLGPlanAndStartLoops(restoreProjection: false),
            model.composerHint ?? "confirm returned false with no hint")
        XCTAssertEqual(
            try goalStore.requireIssuedContract(contract.contractID).status,
            .running,
            model.composerHint ?? "goal did not reach running")
        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(
            model.selectedDispatchRecords.contains {
                $0.identity == .lead && $0.status == .running
            },
            "confirmation must leave a lead-bound runtime dispatch receipt")
        XCTAssertNotEqual(
            model.composerHint,
            "PLG 未能進入 Goal：exact Scenario 沒有可驗證的 active executor binding。")
    }

    /// 確認鍵必須先依拓撲分流，才輪到 exact 原生開發 lane 的 executor
    /// 解析；否則 S／非 exact Scenario 又會被同一條 XXL gate 擋死。
    func testPLGConfirmationBranchesTopologyBeforeNativeExecutorResolution()
        throws
    {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflow = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(workflow.range(
            of: "    func confirmPLGPlanAndStartLoops("))
        let end = try XCTUnwrap(workflow.range(
            of: "    @discardableResult\n    func beginSelectedNativeDevelopmentDispatch(",
            range: start.upperBound..<workflow.endIndex))
        let confirmBody = String(workflow[start.lowerBound..<end.lowerBound])

        let branch = try XCTUnwrap(confirmBody.range(
            of: "Self.isExactNativeDevelopmentScenario(plgContract.scenario)"))
        let resolver = try XCTUnwrap(confirmBody.range(
            of: "selectedNativeDevelopmentExecutorModelID("))
        XCTAssertTrue(
            branch.lowerBound < resolver.lowerBound,
            "topology branch must precede the XXL executor resolver")
        XCTAssertTrue(
            confirmBody.contains("confirmPLGPlanWithSingleModelLead("),
            "non-exact scenarios need the single-model lead branch")
        XCTAssertTrue(
            confirmBody.contains("beginSingleModelGoalDispatch(subtask: objective)"),
            "S confirmation must reuse the /goal single-model dispatch path")
        XCTAssertTrue(
            confirmBody.contains("failPendingSingleModelGoalDispatch("),
            "S confirmation must fail closed when the runner never starts")
    }
}

private final class ChatNativeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [ChatCLIEvent] = []

    var events: [ChatCLIEvent] {
        lock.withLock { storedEvents }
    }

    func append(_ event: ChatCLIEvent) {
        lock.withLock {
            storedEvents.append(event)
        }
    }
}

private struct ChatNativeAgentTestAnchorAuthority:
    TatwoPLGAnchorAuthority
{
    func sign(_ material: String) -> String {
        "chat-native-agent-test-anchor|\(material)"
    }

    func verify(_ signature: String, material: String) -> Bool {
        signature == sign(material)
    }
}

private final class RunnerSubscriptionSessionFactoryCapture:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let modelID: String
    private let assistantText: String
    private var storedMakeCount = 0
    private var storedThreadModel: String?

    init(
        modelID: String = "gpt-5.6-sol",
        assistantText: String = "SUBSCRIPTION_OK"
    ) {
        self.modelID = modelID
        self.assistantText = assistantText
    }

    var makeCount: Int {
        lock.withLock { storedMakeCount }
    }

    var recordedThreadModel: String? {
        lock.withLock { storedThreadModel }
    }

    func make(
        scratch: URL
    ) -> any ChatNativeSubscriptionAppServerSession {
        lock.withLock {
            storedMakeCount += 1
        }
        return RunnerSubscriptionSession(
            modelID: modelID,
            assistantText: assistantText,
            recordThreadModel: { [weak self] model in
                self?.lock.withLock {
                    self?.storedThreadModel = model
                }
            })
    }
}

private actor RunnerSubscriptionSession:
    ChatNativeSubscriptionAppServerSession
{
    private let modelID: String
    private let assistantText: String
    private let recordThreadModel: @Sendable (String?) -> Void
    private var messages: [Data]

    init(
        modelID: String,
        assistantText: String,
        recordThreadModel: @escaping @Sendable (String?) -> Void
    ) {
        self.modelID = modelID
        self.assistantText = assistantText
        self.recordThreadModel = recordThreadModel
        self.messages = [
            Data(
                """
                {"method":"item/completed","params":{"item":{"type":"agentMessage","text":"\(assistantText)","phase":"final_answer"}}}
                """.utf8),
            Data(
                """
                {"method":"turn/completed","params":{"turn":{"status":"completed","error":null}}}
                """.utf8),
        ]
    }

    func request(
        method: String,
        params: Data
    ) async throws -> Data {
        let object = try Self.object(params)
        switch method {
        case "initialize":
            return try Self.data(["codexHome": "/tmp/tatwo"])
        case "account/read":
            return try Self.data([
                "account": [
                    "type": "chatgpt",
                    "email": "owner@example.invalid",
                    "planType": "pro",
                ],
                "requiresOpenaiAuth": true,
            ])
        case "model/list":
            return try Self.data([
                "data": [["model": modelID]],
            ])
        case "thread/start":
            recordThreadModel(object["model"] as? String)
            return try Self.data([
                "thread": ["id": "thread-1"],
                "model": modelID,
                "modelProvider": "openai",
                "reasoningEffort": "high",
            ])
        case "turn/start":
            return try Self.data([
                "turn": [
                    "id": "turn-1",
                    "status": "inProgress",
                    "items": [],
                ],
            ])
        default:
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
    }

    func notify(method: String, params: Data) async throws {}

    func nextMessage() async throws -> Data {
        guard !messages.isEmpty else {
            throw ChatNativeSubscriptionRuntimeError.processExited
        }
        return messages.removeFirst()
    }

    func respond(
        id: ChatNativeSubscriptionJSONRPCID,
        result: Data
    ) async throws {}

    func stop() async {}

    private static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any])
    }

    private static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

private actor BlockingRunnerSubscriptionSession:
    ChatNativeSubscriptionAppServerSession
{
    private var listening = false
    private var listeningWaiters: [CheckedContinuation<Void, Never>] = []
    private var messageContinuation:
        CheckedContinuation<Data, Error>?
    private var stopCount = 0

    func request(
        method: String,
        params: Data
    ) async throws -> Data {
        switch method {
        case "initialize":
            return try Self.data(["codexHome": "/tmp/tatwo"])
        case "account/read":
            return try Self.data([
                "account": [
                    "type": "chatgpt",
                    "email": "owner@example.invalid",
                    "planType": "pro",
                ],
                "requiresOpenaiAuth": true,
            ])
        case "model/list":
            return try Self.data([
                "data": [["model": "gpt-5.6-sol"]],
            ])
        case "thread/start":
            return try Self.data([
                "thread": ["id": "thread-1"],
                "model": "gpt-5.6-sol",
                "modelProvider": "openai",
                "reasoningEffort": "high",
            ])
        case "turn/start":
            return try Self.data([
                "turn": [
                    "id": "turn-1",
                    "status": "inProgress",
                    "items": [],
                ],
            ])
        default:
            throw ChatNativeSubscriptionRuntimeError.invalidProtocol
        }
    }

    func notify(method: String, params: Data) async throws {}

    func nextMessage() async throws -> Data {
        listening = true
        let waiters = listeningWaiters
        listeningWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            messageContinuation = continuation
        }
    }

    func respond(
        id: ChatNativeSubscriptionJSONRPCID,
        result: Data
    ) async throws {}

    func stop() async {
        stopCount += 1
        let continuation = messageContinuation
        messageContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    func waitUntilListening() async {
        if listening { return }
        await withCheckedContinuation { continuation in
            listeningWaiters.append(continuation)
        }
    }

    func stopCountValue() -> Int {
        stopCount
    }

    func release() {
        let continuation = messageContinuation
        messageContinuation = nil
        continuation?.resume(
            throwing: ChatNativeSubscriptionRuntimeError.processExited)
    }

    private static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

private final class RunnerClaudeSubscriptionProcessCapture:
    ChatNativeClaudeProcessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let assistantText: String
    private var storedAuthStatusCount = 0
    private var storedModelRunCount = 0
    private var storedModel: String?
    private var storedEffort: String?

    init(assistantText: String) {
        self.assistantText = assistantText
    }

    var authStatusCount: Int {
        lock.withLock { storedAuthStatusCount }
    }

    var modelRunCount: Int {
        lock.withLock { storedModelRunCount }
    }

    var recordedModel: String? {
        lock.withLock { storedModel }
    }

    var recordedEffort: String? {
        lock.withLock { storedEffort }
    }

    func run(
        arguments: [String],
        standardInput: Data?,
        environment: [String: String],
        currentDirectoryURL: URL
    ) async throws -> ChatNativeClaudeProcessResult {
        if arguments == ["auth", "status", "--json"] {
            lock.withLock { storedAuthStatusCount += 1 }
            return ChatNativeClaudeProcessResult(
                exitCode: 0,
                stdout: Data(
                    #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                        .utf8),
                stderr: Data())
        }
        lock.withLock {
            storedModelRunCount += 1
            if let modelIndex = arguments.firstIndex(of: "--model"),
               arguments.indices.contains(modelIndex + 1)
            {
                storedModel = arguments[modelIndex + 1]
            }
            if let effortIndex = arguments.firstIndex(of: "--effort"),
               arguments.indices.contains(effortIndex + 1)
            {
                storedEffort = arguments[effortIndex + 1]
            }
        }
        let response = """
        {"is_error":false,"subtype":"success","modelUsage":{"claude-opus-5":{"canonicalModel":"claude-opus-5","provider":"firstParty","outputTokens":64}},"structured_output":{"kind":"assistant_text","text":"\(assistantText)"}}
        """
        return ChatNativeClaudeProcessResult(
            exitCode: 0,
            stdout: Data(response.utf8),
            stderr: Data())
    }

    func stop() {}
}

private final class RecordingNativeAgentRunner:
    ChatNativeAgentRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRequest: ChatNativeAgentRunRequest?
    private var storedCallback: (@Sendable (ChatCLIEvent) -> Void)?
    private var storedStartCount = 0
    private var storedTerminateCount = 0

    var request: ChatNativeAgentRunRequest? {
        lock.withLock { storedRequest }
    }

    var startCount: Int {
        lock.withLock { storedStartCount }
    }

    var terminateCount: Int {
        lock.withLock { storedTerminateCount }
    }

    func start(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        lock.withLock {
            storedRequest = request
            storedCallback = onEvent
            storedStartCount += 1
        }
        return ChatRunnerAttemptIdentity(
            runID: request.runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
    }

    func terminate() {
        lock.withLock {
            storedTerminateCount += 1
        }
    }

    func emit(_ event: ChatCLIEvent) {
        let callback = lock.withLock { storedCallback }
        callback?(event)
    }
}

@MainActor
private final class RecordingChatDispatchService: ChatDispatchService {
    private var callback: (@Sendable (ChatCLIEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var nativePrompts: [String] = []

    func startRuntime(
        model: ChatPageModel,
        command: ChatCLICommand,
        nativePrompt: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        runID: String,
        activityTurnID: String,
        allowsNativeGovernanceFallback: Bool,
        nativeGovernanceFallbackCommand: ChatCLICommand?,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        startCount += 1
        nativePrompts.append(nativePrompt)
        callback = onEvent
        return ChatRunnerAttemptIdentity(
            runID: runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
    }

    func emit(_ event: ChatCLIEvent) {
        callback?(event)
    }
}

private final class BlockingReplacementRemoteTurnDispatcher:
    ChatRemoteTurnDispatching,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var storedRequestCount = 0
    private var replacementReleased = false
    private var replacementWaiting = false

    var requestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedRequestCount
    }

    var replacementIsBlocked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return replacementWaiting && !replacementReleased
    }

    func releaseReplacement() {
        condition.lock()
        replacementReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func dispatch(
        _ request: ChatRemoteTurnDispatchRequest
    ) -> ChatRemoteTurnDispatchOutcome {
        condition.lock()
        storedRequestCount += 1
        let attempt = storedRequestCount
        if attempt == 2 {
            replacementWaiting = true
            condition.broadcast()
            while !replacementReleased {
                condition.wait()
            }
            replacementWaiting = false
        }
        condition.unlock()
        return .blocked(.adapterUnavailable)
    }
}
