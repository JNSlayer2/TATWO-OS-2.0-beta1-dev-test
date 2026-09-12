import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class ChatRouteChoiceBrandGroupingTests: XCTestCase {
    func testBrandGroupDerivesProviderFromEngineAndModelIdentity() throws {
        XCTAssertEqual(try choice(id: "fable5").brandGroup, .anthropic)
        XCTAssertEqual(try choice(id: "opus5").brandGroup, .anthropic)
        XCTAssertEqual(try choice(id: "gpt-5.5").brandGroup, .openAI)
        XCTAssertEqual(try choice(id: "codex-auto-review").brandGroup, .openAI)
        XCTAssertEqual(try choice(id: "grok-build").brandGroup, .xAI)
        XCTAssertEqual(try choice(id: "minimax-m3").brandGroup, .miniMax)

        let openClaw = ChatRouteChoice(profile: TatwoChatRouteProfile(
            id: "openclaw-main",
            displayName: "OpenClaw",
            family: "Gateway",
            engine: .codex,
            runtimeAdapter: .gatewayDirect,
            modelArgument: "openclaw-main",
            contextWindowLabel: "gateway",
            supportsImageInput: false,
            pluginFit: "loops",
            sessionRisk: "low",
            defaultEffort: .low,
            allowedEfforts: [],
            notes: []
        ))
        XCTAssertEqual(openClaw.brandGroup, .openClaw)
    }

    func testBrandSectionsPutSelectedBrandFirstAndPreserveCatalogOrder() {
        let sections = ChatRouteChoice.brandSections(selectedID: "minimax-m3")

        XCTAssertEqual(sections.map(\.brand), [.miniMax, .openAI, .anthropic, .xAI])
        XCTAssertEqual(
            sections.first(where: { $0.brand == .openAI })?.choices.map(\.id),
            [
                "gpt-5.6-sol",
                "gpt-5.6-terra",
                "gpt-5.6-luna",
                "gpt-5.5",
                "codex-auto-review",
                "gpt-5.4",
            ]
        )
        XCTAssertEqual(
            sections.first(where: { $0.brand == .anthropic })?.choices.map(\.id),
            ["fable5", "haiku4.5", "sonnet5", "opus5"]
        )
    }

    func testHaiku45SelectionDisplaysAndRoutesExactlyWhile46FailsClosed() {
        let resolved = ChatRouteChoice.resolve("claude-haiku-4-5")

        XCTAssertEqual(resolved.id, "haiku4.5")
        XCTAssertEqual(resolved.title, "haiku4.5")
        XCTAssertEqual(resolved.canonicalModelSlug, "haiku-4-5")
        XCTAssertEqual(resolved.modelArgument, "haiku-4-5")
        XCTAssertEqual(
            ChatRouteChoice.brandSections(selectedID: "haiku4.5").first?.brand,
            .anthropic)
        XCTAssertTrue(ChatRouteChoice.all.contains { $0.id == "haiku4.5" })
        XCTAssertEqual(ChatRouteChoice.resolve("haiku4.6").runtimeAdapter, .unavailable)
    }

    func testResolveUnknownRouteDoesNotFallbackToFirstGPTChoice() {
        let resolved = ChatRouteChoice.resolve("future-model-that-is-not-installed")

        XCTAssertEqual(resolved.id, "future-model-that-is-not-installed")
        XCTAssertEqual(resolved.runtimeAdapter, .unavailable)
        XCTAssertNotEqual(resolved.id, ChatRouteChoice.all[0].id)
    }

    @MainActor
    func testOrdinarySendKeepsOffAndLunaRouteWithoutCreatingGoalRun() async throws {
        let fixture = makeModelFixture("ordinary-send")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertNotNil(model.selectedThreadID)

        model.setSingleModel("gpt-5.6-luna")
        model.isRunning = true
        model.prompt = "請讓 Opus5 與 Fable5 用 Ultrawork 多模協作 loops 整理這段普通內容"
        model.send()

        XCTAssertEqual(model.collaborationLevel, .off)
        XCTAssertEqual(model.selectedModel, "gpt-5.6-luna")
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertEqual(model.queuedChatTurnCount, 1)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
    }

    @MainActor
    func testOrdinaryComputerHostTurnWithoutBindingFailsClosedWithoutCreatingGoalRun()
        async throws
    {
        let fixture = makeModelFixture("ordinary-computer-host-unbound")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertNotNil(model.selectedThreadID)

        model.isRunning = true
        model.prompt =
            "請使用 [@電腦](plugin://computer-use@openai-bundled) 操作 Tatwo OS App。"
        model.submitCurrentChatTurn()

        XCTAssertEqual(model.queuedChatTurnCount, 0)
        XCTAssertEqual(
            model.prompt,
            "請使用 [@電腦](plugin://computer-use@openai-bundled) 操作 Tatwo OS App。")
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains("普通 Chat 不會建立新 Goal／Contract"),
            model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testOrdinarySendWithUnboundLoopsConfigFailsClosedWithoutCreatingGoalRun()
        async throws
    {
        let fixture = makeModelFixture("ordinary-send-unbound-loops")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertNotNil(model.selectedThreadID)

        model.setCollaborationLevel(.xxl)
        XCTAssertTrue(model.collaborationIsEnabled)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)

        model.isRunning = true
        model.prompt = "這是普通文字 turn，不得因殘留 loopsConfig 建立新的 Goal。"
        model.submitCurrentChatTurn()

        XCTAssertEqual(model.queuedChatTurnCount, 0)
        XCTAssertEqual(model.prompt, "這是普通文字 turn，不得因殘留 loopsConfig 建立新的 Goal。")
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains("普通 Chat 不會建立新 Goal／Contract"),
            model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testLunaToFableReviewerProseStaysOrdinaryChatWithoutMintingGoalRun()
        async throws
    {
        let fixture = makeModelFixture("luna-fable-reviewer-prose-no-goal")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        let threadID = try XCTUnwrap(model.selectedThreadID)

        model.setSingleModel("gpt-5.6-luna")
        model.isRunning = true
        model.prompt = "Luna xhigh 請在目前同一個 Tatwo Chat thread 做長回合檢查。"
        model.send()

        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(model.selectedModel, "gpt-5.6-luna")
        XCTAssertEqual(model.queuedChatTurnCount, 1)
        XCTAssertEqual(model.collaborationLevel, .off)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)

        model.isRunning = false
        model.setSingleModel("fable5")
        model.isRunning = true
        model.prompt =
            """
            延續目前同一個 Tatwo Chat thread；不得建立新 Session、Goal、視窗或 App。
            你現在是 Fable 5 獨立副審，唯讀，請復核上一輪 Luna 結論與目前 source candidate。
            """
        model.send()

        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(model.selectedModel, "fable5")
        XCTAssertEqual(model.queuedChatTurnCount, 2)
        XCTAssertEqual(model.collaborationLevel, .off)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertEqual(
            try goalRunFileCount(in: fixture.goalStore),
            0,
            "ordinary reviewer prose must not cross the explicit Work OS begin boundary")
    }

    @MainActor
    func testOrdinarySendWithStaleBindingFailsClosedBeforeStartingRunner()
        async throws
    {
        let fixture = makeModelFixture("ordinary-send-stale-binding")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertNotNil(model.selectedThreadID)

        model.setCollaborationLevel(.xxl)
        model.mutateSelectedThread { thread in
            thread.workOSContractID = "contract-stale"
            thread.workOSGoalID = "goal-stale"
            thread.selectedThreadWorkOSContext = TatwoStoredObjectiveContextV2(
                identity: TatwoObjectiveIdentity.make("stale binding objective"))
        }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)

        model.prompt = "普通文字不得沿用或替換無法驗證的 stale Goal binding。"
        model.submitCurrentChatTurn()

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.queuedChatTurnCount, 0)
        XCTAssertEqual(
            model.prompt,
            "普通文字不得沿用或替換無法驗證的 stale Goal binding。")
        XCTAssertEqual(model.selectedThread?.workOSContractID, "contract-stale")
        XCTAssertEqual(model.selectedThread?.workOSGoalID, "goal-stale")
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains("canonical GoalRun 無法驗證"),
            model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testExplicitComposerLoopsActionIsAnAuthorizedGoalCreationSurface()
        async throws
    {
        let fixture = makeModelFixture("explicit-composer-loops-action")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertNotNil(model.selectedThreadID)

        model.setCollaborationLevel(.xxl)
        model.prompt = "由明確的「交給 Work OS Loops」按鈕建立此 Goal。"

        let firstRunID = await model.createAndDispatchLoopFromPrompt()

        XCTAssertNil(firstRunID)
        XCTAssertNotNil(model.authorityBootstrapModel.pendingProposal)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
        await model.authorityBootstrapModel.confirmPending()

        let runID = await model.createAndDispatchLoopFromPrompt()

        XCTAssertNotNil(runID)
        XCTAssertEqual(model.activePLGRun?.id, runID)
        XCTAssertNotNil(model.selectedWorkOSContract)
        XCTAssertNotNil(model.selectedGoalRecord)
        XCTAssertEqual(
            model.selectedThread?.workOSContractID,
            model.selectedWorkOSContract?.contractID)
        XCTAssertEqual(
            model.selectedThread?.workOSGoalID,
            model.selectedWorkOSContract?.goalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertEqual(model.prompt, "")
        XCTAssertTrue(model.requestOpenLoopsPanel)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.queuedChatTurnCount, 0)
    }

    @MainActor
    func testExplicitControlActivatesXXLBeforeXLAndExposesExactOpusGrokRoutes() async throws {
        let fixture = makeModelFixture("explicit-xxl")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertNotNil(model.selectedThreadID)

        model.setSingleModel("gpt-5.6-luna")
        model.isRunning = true
        model.prompt = "$tatwo-ultrawork XXL，Opus 主、Grok 輔"
        model.send()

        XCTAssertNotNil(model.authorityBootstrapModel.pendingProposal)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
        await model.authorityBootstrapModel.confirmPending()
        model.prompt = "$tatwo-ultrawork XXL，Opus 主、Grok 輔"
        model.send()

        XCTAssertEqual(model.collaborationLevel, .xxl)
        XCTAssertEqual(model.activePrimaryModelID, "opus-5")
        XCTAssertEqual(model.activeSecondaryModelID, "grok-build")
        XCTAssertTrue(model.activeLoopsModelCandidates.contains("opus-5"))
        XCTAssertTrue(model.activeLoopsModelCandidates.contains("grok-build"))
        XCTAssertNotNil(model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)

        model.setPrimaryModel("opus-5")
        XCTAssertEqual(model.activePrimaryModelID, "opus-5")
        XCTAssertEqual(model.selectedModel, "gpt-5.6-luna")
        model.isRunning = false
        model.setSingleModel("opus-5", syncCollaborationLead: false)
        XCTAssertEqual(model.routeChoice.id, "opus5")
        XCTAssertEqual(model.routeChoice.canonicalModelSlug, "opus-5")
        XCTAssertEqual(model.routeChoice.modelArgument, "opus")

        model.setSingleModel("grok-build", syncCollaborationLead: false)
        XCTAssertEqual(model.routeChoice.id, "grok-build")
        XCTAssertEqual(model.routeChoice.canonicalModelSlug, "grok-build")
        XCTAssertEqual(model.routeChoice.modelArgument, "grok-build")
        XCTAssertEqual(model.activePrimaryModelID, "opus-5")
        XCTAssertEqual(model.activeSecondaryModelID, "grok-build")
    }

    @MainActor
    func testQuotedFencedAndNegatedUltraworkTextCannotActivateControlPlane() async throws {
        let fixture = makeModelFixture("quoted-fenced-negated-ultrawork")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.prompt = """
            > $tatwo-ultrawork XXL，Fable5 主導

            ```
            $tatwo-ultrawork XXL，Opus5 主導
            ```

            「$tatwo-ultrawork XXL，Grok 主導」
            $tatwo-ultrawork 不啟動，只解釋這個指令
            """

        XCTAssertFalse(model.shouldShowUltraworkActivation)
        model.isRunning = true
        model.send()

        XCTAssertNil(model.activeLoopsConfig)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
    }

    @MainActor
    func testOnlyLeadingExecutableUltraworkControlLineSelectsModeAndModels() async throws {
        let fixture = makeModelFixture("leading-ultrawork-control")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.isRunning = true
        model.prompt = "$tatwo-ultrawork XXL，Fable5 主導，Grok 輔助"

        XCTAssertTrue(model.shouldShowUltraworkActivation)
        model.send()

        XCTAssertNotNil(model.authorityBootstrapModel.pendingProposal)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 0)
        await model.authorityBootstrapModel.confirmPending()
        model.prompt = "$tatwo-ultrawork XXL，Fable5 主導，Grok 輔助"
        model.send()

        XCTAssertEqual(model.collaborationLevel, .xxl)
        XCTAssertEqual(model.activePrimaryModelID, "fable-5")
        XCTAssertEqual(model.activeSecondaryModelID, "grok-build")
        XCTAssertNotNil(model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testDefaultXXLUsesExactScenarioTopologyWithoutImplicitPickerOverride() async throws {
        let fixture = makeModelFixture("default-exact-xxl")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.setCollaborationLevel(.xxl)

        XCTAssertEqual(
            model.activeLoopsConfig?.scenarioID,
            TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
        XCTAssertNil(model.activeLoopsConfig?.primaryModelID)
        XCTAssertNil(model.activeLoopsConfig?.secondaryModelID)
        XCTAssertEqual(model.activePrimaryModelID, "gpt-5.6-sol")
        XCTAssertEqual(model.activeSecondaryModelID, "opus-5")
        let objectiveHint =
            "Sol 主導，Opus5 監工，Luna xhigh 與 Grok4.6 xhigh 執行 loops"
        XCTAssertFalse(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: objectiveHint,
                allowCreateIfUnbound: true),
            "Initial issuance must stage the App-owned authority bootstrap gate.")
        let proposal = try XCTUnwrap(
            model.authorityBootstrapModel.pendingProposal)
        XCTAssertEqual(proposal.owner.provider, "tatwo-chat")
        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains("authority-lock bootstrap"),
            model.selectedWorkOSStateMessage)

        await model.authorityBootstrapModel.confirmPending()

        XCTAssertNil(
            model.authorityBootstrapModel.pendingProposal,
            "confirmed bootstrap should clear the pending AppShell proposal")
        XCTAssertNil(
            model.authorityBootstrapModel.errorMessage,
            model.authorityBootstrapModel.errorMessage ?? "")
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: objectiveHint,
                allowCreateIfUnbound: true),
            model.selectedWorkOSStateMessage)

        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertEqual(
            contract.scenario,
            TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
        XCTAssertNil(contract.routeBindingOverride)
        assertExactDefaultXXLTopology(contract)
    }

    @MainActor
    func testOffGoalKeepsSingleModelTopologyBeforeContractIssue()
        async throws
    {
        let fixture = makeModelFixture("off-goal-materializes-exact")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertEqual(model.collaborationLevel, .off)
        XCTAssertNil(model.selectedThread?.loopsConfig)

        model.prompt = "/goal 讓 OS chat 長時間穩定辦公"
        model.send()
        for _ in 0..<160 where model.selectedWorkOSContract == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertNil(model.authorityBootstrapModel.pendingProposal)
        XCTAssertNil(
            model.selectedThread?.loopsConfig,
            "ordinary /goal must not inherit or materialize Ultrawork topology")
        XCTAssertEqual(model.collaborationLevel, .off)

        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertEqual(contract.mode, .s)
        XCTAssertFalse(
            contract.scenario.contains("xxl"),
            "ordinary /goal must not issue an XXL scenario")
        XCTAssertTrue(
            contract.identityBindings.contains(where: {
                $0.identity == .lead
                    && TatwoGatewayDispatchCatalog.normalize(
                        $0.modelID ?? "")
                        == TatwoGatewayDispatchCatalog.normalize(
                            model.currentTurnDispatchRoute()
                                .canonicalModelSlug)
            }))
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testOffPLGMaterializesFullExactSubsWithoutScalarCollapse()
        async throws
    {
        let fixture = makeModelFixture("off-plg-materializes-exact")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        XCTAssertEqual(model.collaborationLevel, .off)

        let started = await model.startPLGRun(
            objective: "以 Sol 主導並由 Opus、Luna、Grok 完成下一版")
        XCTAssertTrue(
            started,
            [
                "hint=\(model.composerHint ?? "nil")",
                "plgError=\(model.plgError ?? "nil")",
                "state=\(model.selectedWorkOSStateMessage)",
                "source=\(model.selectedThread?.sourceMarker ?? "nil")",
            ].joined(separator: " "))
        XCTAssertNil(model.authorityBootstrapModel.pendingProposal)

        let config = try XCTUnwrap(model.selectedThread?.loopsConfig)
        XCTAssertEqual(
            config.scenarioID,
            TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID)
        XCTAssertNil(config.primaryModelID)
        XCTAssertNil(config.secondaryModelID)
        let run = try XCTUnwrap(model.activePLGRun)
        XCTAssertEqual(run.leadBindings.compactMap(\.modelID), ["gpt-5.6-sol"])
        XCTAssertEqual(
            run.subBindings
                .filter { $0.identity == .supervisor }
                .compactMap(\.modelID),
            ["opus-5"])
        XCTAssertEqual(
            Set(
                run.subBindings
                    .filter { $0.identity == .sub }
                    .compactMap(\.modelID)),
            Set(["gpt-5.6-luna", "grok-build"]))
        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        assertExactDefaultXXLTopology(contract)
        XCTAssertFalse(
            contract.identityBindings.contains { $0.modelID == "fable-5" })
    }

    @MainActor
    func testReviewerAndCollaborationProseCannotDowngradeExplicitXXLState() async throws {
        let fixture = makeModelFixture("xxl-prose-no-downgrade")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: "XXL state must remain authoritative")
        let contractID = try XCTUnwrap(model.selectedWorkOSContract?.contractID)

        model.isRunning = true
        model.prompt =
            "$tatwo-ultrawork 請維持目前安排；副審要仔細，協作與 loops 不要中斷。"
        model.send()

        XCTAssertEqual(model.collaborationLevel, .xxl)
        XCTAssertEqual(model.activeLoopsConfig?.mode, .xxl)
        XCTAssertEqual(model.selectedWorkOSContract?.mode, .xxl)
        XCTAssertEqual(model.selectedWorkOSContract?.contractID, contractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testEnabledXXLSameThreadDifferentPromptsReuseSingleGoalRun() async throws {
        let fixture = makeModelFixture("xxl-different-prompts-no-contract-churn")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: "同一個 Tatwo Chat session 的長回合可靠性驗證")
        let originalContract = try XCTUnwrap(model.selectedWorkOSContract)
        let originalThreadID = try XCTUnwrap(model.selectedThreadID)
        model.isRunning = true

        let prompts = [
            "Sol 只做純文字的失敗後恢復檢查。",
            "Luna xhigh 只做純文字 route audit。",
            "Grok 4.6 xhigh 只做純文字反例副審。",
        ]
        for (turn, prompt) in prompts.enumerated() {
            model.prompt = prompt
            model.send()

            XCTAssertEqual(model.selectedThreadID, originalThreadID, "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedThread?.workOSContractID,
                originalContract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedThread?.workOSGoalID,
                originalContract.goalID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedWorkOSContract?.contractID,
                originalContract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedWorkOSContract?.goalID,
                originalContract.goalID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                try goalRunFileCount(in: fixture.goalStore),
                1,
                "turn \(turn + 1) minted a replacement GoalRun")
        }
    }

    @MainActor
    func testSwitchingSingleRoutePreservesWorkOSIdentityAndActiveContract() async throws {
        let fixture = makeModelFixture("xxl-route-preserves-contract")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        let objectiveHint = "Chat route 切換不得改寫 Work OS 身份或 Goal"
        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: objectiveHint)
        let originalContract = try XCTUnwrap(model.selectedWorkOSContract)
        let originalGoalRecord = try XCTUnwrap(model.selectedGoalRecord)
        let originalLoopsConfig = try XCTUnwrap(model.activeLoopsConfig)
        let routeID = originalContract.routeBindingOverride?.primaryModelID == "opus-5"
            ? "fable5"
            : "opus5"

        model.setSingleModel(routeID)

        XCTAssertEqual(model.selectedModel, ChatRouteChoice.resolve(routeID).id)
        XCTAssertEqual(model.activeLoopsConfig, originalLoopsConfig)
        XCTAssertEqual(model.collaborationLevel, .xxl)
        XCTAssertEqual(model.selectedThread?.workOSContractID, originalContract.contractID)
        XCTAssertEqual(model.selectedThread?.workOSGoalID, originalContract.goalID)
        XCTAssertEqual(model.selectedWorkOSContract?.contractID, originalContract.contractID)
        XCTAssertEqual(model.selectedGoalRecord?.contractID, originalGoalRecord.contractID)
        XCTAssertEqual(model.selectedWorkOSContract?.objective, originalContract.objective)
        XCTAssertEqual(model.selectedWorkOSContract?.scenario, originalContract.scenario)
        XCTAssertEqual(model.selectedWorkOSContract?.mode, originalContract.mode)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)

        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: objectiveHint),
            model.selectedWorkOSStateMessage)
        XCTAssertEqual(model.selectedWorkOSContract?.contractID, originalContract.contractID)
        XCTAssertEqual(model.selectedWorkOSContract?.goalID, originalContract.goalID)
        XCTAssertEqual(model.activeLoopsConfig, originalLoopsConfig)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testTwentyFourSameThreadRouteSwitchesPreserveIssuedContractGoalAndThread() async throws {
        let fixture = makeModelFixture("xxl-24-route-no-contract-churn")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        let threadID = try XCTUnwrap(model.selectedThreadID)
        let objectiveHint =
            "同一 Chat thread 連續切換模型時不得重建 Work OS contract 或 GoalRun"
        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: objectiveHint)
        let originalContract = try XCTUnwrap(model.selectedWorkOSContract)
        let originalGoalRecord = try XCTUnwrap(model.selectedGoalRecord)
        let originalLoopsConfig = try XCTUnwrap(model.activeLoopsConfig)
        let routeSequence = [
            "gpt-5.6-sol", "fable5", "gpt-5.6-luna", "grok-build",
            "opus5", "gpt-5.6-terra",
            "gpt-5.6-sol", "fable5", "gpt-5.6-luna", "grok-build",
            "opus5", "gpt-5.6-terra",
            "gpt-5.6-sol", "fable5", "gpt-5.6-luna", "grok-build",
            "opus5", "gpt-5.6-terra",
            "gpt-5.6-sol", "fable5", "gpt-5.6-luna", "grok-build",
            "opus5", "gpt-5.6-sol",
        ]
        XCTAssertEqual(routeSequence.count, 24)

        for (turn, routeID) in routeSequence.enumerated() {
            model.setSingleModel(routeID)
            XCTAssertTrue(
                model.ensureSelectedThreadWorkOSContract(
                    objectiveHint: objectiveHint),
                "turn \(turn + 1) failed to reuse the issued contract")

            XCTAssertEqual(model.selectedThreadID, threadID, "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedModel,
                ChatRouteChoice.resolve(routeID).id,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedThread?.workOSContractID,
                originalContract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedThread?.workOSGoalID,
                originalContract.goalID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedWorkOSContract?.contractID,
                originalContract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedWorkOSContract?.goalID,
                originalContract.goalID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedGoalRecord?.contractID,
                originalGoalRecord.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedGoalRecord?.goalID,
                originalGoalRecord.goalID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.activeLoopsConfig,
                originalLoopsConfig,
                "turn \(turn + 1)")
            XCTAssertEqual(
                try goalRunFileCount(in: fixture.goalStore),
                1,
                "turn \(turn + 1)")
        }
    }

    @MainActor
    func testArbitraryRestoredStandaloneDoesNotAttachCurrentSessionPointer() async throws {
        let storage = makeFixtureStorage("verified-current-session")
        let thread = TatwoNativeChatThread(
            title: "Restored standalone",
            isPinned: false,
            lastPreview: "")
        try storage.nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID: "general-xxl-fable5-sol",
            objective: "Restore the exact active Work OS session",
            store: storage.goalStore)
        try TatwoSessionStore(directoryURL: storage.goalStore.directoryURL).writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective))

        let model = makeModel(storage: storage)
        try await waitForInitialStoreLoad(model)

        XCTAssertEqual(model.selectedThreadID, thread.id)
        assertNoRestoredWorkOSBinding(model)
        XCTAssertEqual(try goalRunFileCount(in: storage.goalStore), 1)
    }

    @MainActor
    func testMissingMismatchedAndUnverifiableCurrentSessionPointersFailClosed() async throws {
        let missing = makeFixtureStorage("missing-current-session")
        let missingThread = TatwoNativeChatThread(title: "Missing pointer")
        try missing.nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [missingThread]))
        let missingModel = makeModel(storage: missing)
        try await waitForInitialStoreLoad(missingModel)
        assertNoRestoredWorkOSBinding(missingModel)
        XCTAssertEqual(try goalRunFileCount(in: missing.goalStore), 0)

        let unverifiable = makeFixtureStorage("unverifiable-current-session")
        let unverifiableThread = TatwoNativeChatThread(title: "Unverifiable pointer")
        try unverifiable.nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [unverifiableThread]))
        try TatwoSessionStore(directoryURL: unverifiable.goalStore.directoryURL).writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: "contract-missing",
                goalID: "goal-missing",
                mode: .xxl,
                scenario: "general-xxl-fable5-sol",
                objective: "Must not mint a fallback"))
        let unverifiableModel = makeModel(storage: unverifiable)
        try await waitForInitialStoreLoad(unverifiableModel)
        assertNoRestoredWorkOSBinding(unverifiableModel)
        XCTAssertEqual(try goalRunFileCount(in: unverifiable.goalStore), 0)

        let mismatched = makeFixtureStorage("mismatched-current-session")
        let mismatchedThread = TatwoNativeChatThread(title: "Mismatched pointer")
        try mismatched.nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [mismatchedThread]))
        let issued = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID: "general-xxl-fable5-sol",
            objective: "Issued objective",
            store: mismatched.goalStore)
        try TatwoSessionStore(directoryURL: mismatched.goalStore.directoryURL).writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: issued.contractID,
                goalID: "goal-does-not-match-issued-record",
                mode: issued.mode,
                scenario: issued.scenario,
                objective: issued.objective))
        let mismatchedModel = makeModel(storage: mismatched)
        try await waitForInitialStoreLoad(mismatchedModel)
        assertNoRestoredWorkOSBinding(mismatchedModel)
        XCTAssertEqual(try goalRunFileCount(in: mismatched.goalStore), 1)
    }

    @MainActor
    func testActiveLoopsTeamUsesActiveConfigScenarioBeforeSelectedTemplate() async throws {
        let fixture = makeModelFixture("active-scenario-precedence")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        let activeScenarioID = "general-xl-fable5"
        model.mutateSelectedThread { thread in
            thread.loopsConfig = TatwoNativeThreadLoopsConfig(
                scenarioID: activeScenarioID,
                mode: .xl,
                identitySummary: "active scenario",
                tokenBudget: "test")
        }
        let alternateTemplate = try XCTUnwrap(
            model.coworkTemplates.first {
                $0.mode == .xl && $0.scenarioID != activeScenarioID
            })
        model.selectedCoworkTemplateID = alternateTemplate.id

        let expected = model.loopsTeam(
            scenarioID: activeScenarioID,
            mode: .xl)
        let staleTemplateTeam = model.loopsTeam(
            scenarioID: alternateTemplate.scenarioID,
            mode: .xl)

        XCTAssertFalse(expected.isEmpty)
        XCTAssertNotEqual(expected, staleTemplateTeam)
        XCTAssertEqual(model.activeLoopsTeam, expected)
    }

    @MainActor
    func testPrimaryAndSecondaryPickersIssueExactWorkOSBindings() async throws {
        let fixture = makeModelFixture("xxl-exact-route-bindings")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        let objectiveHint = "Primary 與 secondary picker 必須成為派工真值"
        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: objectiveHint)
        let originalContractID = try XCTUnwrap(model.selectedWorkOSContract?.contractID)
        let selectedPrimary = model.activePrimaryModelID == "opus-5"
            ? "fable-5"
            : "opus-5"
        let selectedSecondary = model.activeSecondaryModelID == "grok-build"
            ? "gpt-5.6-sol"
            : "grok-build"

        model.setPrimaryModel(selectedPrimary)
        XCTAssertEqual(model.activeLoopsConfig?.primaryModelID, selectedPrimary)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        let primaryInvalidation = try XCTUnwrap(
            model.selectedThread?.bindingInvalidation)
        XCTAssertEqual(
            primaryInvalidation.desiredLoopsConfigSHA256,
            TatwoNativeThreadBindingInvalidationV1.loopsConfigSHA256(
                model.activeLoopsConfig))
        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(originalContractID).status,
            .cancelled)

        model.setSecondaryModel(selectedSecondary)
        XCTAssertEqual(model.activeLoopsConfig?.secondaryModelID, selectedSecondary)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        let secondaryInvalidation = try XCTUnwrap(
            model.selectedThread?.bindingInvalidation)
        XCTAssertEqual(secondaryInvalidation.id, primaryInvalidation.id)
        XCTAssertEqual(
            secondaryInvalidation.previousBinding,
            primaryInvalidation.previousBinding)
        XCTAssertEqual(
            secondaryInvalidation.previousLoopsConfigSHA256,
            primaryInvalidation.previousLoopsConfigSHA256)
        XCTAssertEqual(
            secondaryInvalidation.desiredLoopsConfigSHA256,
            TatwoNativeThreadBindingInvalidationV1.loopsConfigSHA256(
                model.activeLoopsConfig))
        XCTAssertNotEqual(
            secondaryInvalidation.desiredLoopsConfigSHA256,
            primaryInvalidation.desiredLoopsConfigSHA256)

        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: objectiveHint)
        let revisedContract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertNotEqual(revisedContract.contractID, originalContractID)
        assertExactRouteBindings(
            revisedContract,
            primary: selectedPrimary,
            secondary: selectedSecondary)

        let revisedContractID = revisedContract.contractID
        model.setPrimaryModel(selectedPrimary)
        XCTAssertEqual(model.selectedWorkOSContract?.contractID, revisedContractID)
        XCTAssertEqual(model.selectedThread?.workOSContractID, revisedContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 2)

        model.isRunning = true
        model.prompt =
            "$tatwo-ultrawork 請維持目前 primary／secondary；副審與 loops 繼續。"
        model.send()

        XCTAssertEqual(model.activeLoopsConfig?.primaryModelID, selectedPrimary)
        XCTAssertEqual(model.activeLoopsConfig?.secondaryModelID, selectedSecondary)
        XCTAssertEqual(model.selectedWorkOSContract?.contractID, revisedContractID)
        XCTAssertEqual(model.selectedThread?.workOSContractID, revisedContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 2)
    }

    @MainActor
    func testChangingCollaborationStructureClearsIssuedContractImmediately() async throws {
        let fixture = makeModelFixture("xxl-structure-change")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: "XXL 架構改為 M 時必須重新建立 Goal contract")
        XCTAssertNotNil(model.selectedWorkOSContract)
        XCTAssertNotNil(model.selectedGoalRecord)
        XCTAssertNotNil(model.selectedThread?.workOSContractID)
        XCTAssertNotNil(model.selectedThread?.workOSGoalID)

        model.setCollaborationLevel(.m)

        XCTAssertEqual(model.activeLoopsConfig?.mode, .m)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
    }

    @MainActor
    func testTurningCollaborationOffCancelsOnlyPristineGoalAndClearsBinding() async throws {
        let fixture = makeModelFixture("xxl-off-pristine")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: "關閉協作只可取消尚未派工的 Goal")
        let contractID = try XCTUnwrap(model.selectedWorkOSContract?.contractID)

        model.setCollaborationLevel(.off)

        XCTAssertEqual(model.collaborationLevel, .off)
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertNil(model.selectedWorkOSContract)
        XCTAssertNil(model.selectedGoalRecord)
        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(contractID).status,
            .cancelled)
        XCTAssertNil(
            try TatwoSessionStore(
                directoryURL: fixture.goalStore.directoryURL).current())
    }

    @MainActor
    func testTurningCollaborationOffRefusesToHidePublishedGoal() async throws {
        let fixture = makeModelFixture("xxl-off-published")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }

        model.setCollaborationLevel(.xxl)
        try await confirmPendingAuthorityBootstrapAndRetry(
            model,
            objectiveHint: "已有工作證據時關閉協作必須 fail closed")
        let contract = try XCTUnwrap(model.selectedWorkOSContract)
        _ = try fixture.goalStore.appendReceipt(
            contractID: contract.contractID,
            receiptID: "published-off-evidence",
            kind: "scope",
            loopID: contract.mainlineLoop.id)

        model.setCollaborationLevel(.off)

        XCTAssertEqual(model.collaborationLevel, .xxl)
        XCTAssertEqual(
            model.selectedThread?.workOSContractID,
            contract.contractID)
        XCTAssertEqual(model.selectedThread?.workOSGoalID, contract.goalID)
        XCTAssertEqual(model.selectedWorkOSContract?.contractID, contract.contractID)
        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(contract.contractID).status,
            .planned)
        XCTAssertEqual(
            try TatwoSessionStore(
                directoryURL: fixture.goalStore.directoryURL).current()?.contractID,
            contract.contractID)
        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains("已保留原設定"),
            model.selectedWorkOSStateMessage)
    }

    private func choice(id: String) throws -> ChatRouteChoice {
        try XCTUnwrap(ChatRouteChoice.all.first { $0.id == id })
    }

    private func assertExactRouteBindings(
        _ contract: TatwoWorkOSContractV1,
        primary: String,
        secondary: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            contract.routeBindingOverride?.primaryModelID,
            primary,
            file: file,
            line: line)
        XCTAssertEqual(
            contract.routeBindingOverride?.secondaryModelID,
            secondary,
            file: file,
            line: line)
        let leadBindings = contract.identityBindings.filter { $0.identity == .lead }
        let subBindings = contract.identityBindings.filter { $0.identity == .sub }
        XCTAssertFalse(leadBindings.isEmpty, file: file, line: line)
        XCTAssertFalse(subBindings.isEmpty, file: file, line: line)
        XCTAssertTrue(
            leadBindings.allSatisfy { $0.modelID == primary },
            file: file,
            line: line)
        XCTAssertTrue(
            subBindings.allSatisfy { $0.modelID == secondary },
            file: file,
            line: line)

        let governorLeadBindings =
            contract.loopGovernorDecision.activatedBindings.filter {
                $0.identityKind == .lead
            }
        let governorSubBindings =
            contract.loopGovernorDecision.activatedBindings.filter {
                $0.identityKind == .sub
            }
        XCTAssertFalse(governorLeadBindings.isEmpty, file: file, line: line)
        XCTAssertFalse(governorSubBindings.isEmpty, file: file, line: line)
        XCTAssertTrue(
            governorLeadBindings.allSatisfy { $0.boundModelIDs == [primary] },
            file: file,
            line: line)
        XCTAssertTrue(
            governorSubBindings.allSatisfy { $0.boundModelIDs == [secondary] },
            file: file,
            line: line)

        let manifest = TatwoExecutionManifestFactory.make(
            contract: contract,
            generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(manifest.contractID, contract.contractID, file: file, line: line)
        XCTAssertTrue(
            manifest.entries
                .filter { $0.identity == .lead }
                .allSatisfy { $0.modelID == primary },
            file: file,
            line: line)
        XCTAssertTrue(
            manifest.entries
                .filter { $0.identity == .sub }
                .allSatisfy { $0.modelID == secondary },
            file: file,
            line: line)
    }

    private func assertExactDefaultXXLTopology(
        _ contract: TatwoWorkOSContractV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let governor = contract.loopGovernorDecision.activatedBindings
        XCTAssertEqual(
            governor.filter { $0.identityKind == .lead }.map(\.boundModelIDs),
            [["gpt-5.6-sol"]],
            file: file,
            line: line)
        XCTAssertEqual(
            governor.filter { $0.identityKind == .supervisor }.map(\.boundModelIDs),
            [["opus-5"]],
            file: file,
            line: line)
        XCTAssertEqual(
            governor.filter { $0.identityKind == .supervisor }.map(\.reasoningEffort),
            [.high],
            file: file,
            line: line)
        XCTAssertEqual(
            governor.filter { $0.identityKind == .sub }.map(\.boundModelIDs),
            [["gpt-5.6-luna"], ["grok-build"]],
            file: file,
            line: line)
        XCTAssertEqual(
            governor.filter { $0.identityKind == .sub }.map(\.reasoningEffort),
            [.xhigh, .xhigh],
            file: file,
            line: line)

        XCTAssertEqual(
            contract.identityBindings.filter { $0.identity == .lead }.map(\.modelID),
            ["gpt-5.6-sol"],
            file: file,
            line: line)
        XCTAssertEqual(
            contract.identityBindings.filter { $0.identity == .supervisor }.map(\.modelID),
            ["opus-5"],
            file: file,
            line: line)
        XCTAssertEqual(
            contract.identityBindings.filter { $0.identity == .sub }.map(\.modelID),
            ["gpt-5.6-luna", "grok-build"],
            file: file,
            line: line)
        XCTAssertFalse(
            contract.identityBindings.contains {
                $0.modelID == "fable-5"
            },
            file: file,
            line: line)
        XCTAssertFalse(
            contract.identityBindings.contains { $0.modelID == "gpt-5.5" },
            file: file,
            line: line)
    }

    @MainActor
    private func makeModelFixture(
        _ suffix: String
    ) -> (model: ChatPageModel, goalStore: TatwoGoalRunStore) {
        let storage = makeFixtureStorage(suffix)
        return (makeModel(storage: storage), storage.goalStore)
    }

    private struct FixtureStorage {
        let directory: URL
        let nativeStore: TatwoNativeChatStore
        let goalStore: TatwoGoalRunStore
    }

    private func makeFixtureStorage(_ suffix: String) -> FixtureStorage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-route-authority-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        return FixtureStorage(
            directory: directory,
            nativeStore: nativeStore,
            goalStore: goalStore)
    }

    @MainActor
    private func makeModel(storage: FixtureStorage) -> ChatPageModel {
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatRouteChoiceBrandGroupingTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: storage.nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: storage.directory.appendingPathComponent("journal.json")),
            goalRunStore: storage.goalStore,
            plgChainStore: TatwoPLGChainStore(
                directory: storage.directory.appendingPathComponent(
                    "plg-event-chains",
                    isDirectory: true),
                anchorAuthority:
                    ChatRouteChoiceTestAnchorAuthority()))
        return model
    }

    @MainActor
    private func assertNoRestoredWorkOSBinding(
        _ model: ChatPageModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(model.selectedThread?.workOSContractID, file: file, line: line)
        XCTAssertNil(model.selectedThread?.workOSGoalID, file: file, line: line)
        XCTAssertNil(model.selectedWorkOSContract, file: file, line: line)
        XCTAssertNil(model.selectedGoalRecord, file: file, line: line)
        XCTAssertNil(model.activeLoopsConfig, file: file, line: line)
    }

    @MainActor
    private func confirmPendingAuthorityBootstrapAndRetry(
        _ model: ChatPageModel,
        objectiveHint: String,
        requireObjectiveMatch: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertFalse(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: objectiveHint,
                requireObjectiveMatch: requireObjectiveMatch,
                allowCreateIfUnbound: true),
            "first create must stage AppShell authority bootstrap",
            file: file,
            line: line)
        XCTAssertNotNil(
            model.authorityBootstrapModel.pendingProposal,
            file: file,
            line: line)
        XCTAssertNil(model.selectedWorkOSContract, file: file, line: line)
        XCTAssertNil(model.selectedGoalRecord, file: file, line: line)
        await model.authorityBootstrapModel.confirmPending()
        XCTAssertNil(
            model.authorityBootstrapModel.errorMessage,
            model.authorityBootstrapModel.errorMessage ?? "",
            file: file,
            line: line)
        XCTAssertNil(
            model.authorityBootstrapModel.pendingProposal,
            file: file,
            line: line)
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: objectiveHint,
                requireObjectiveMatch: requireObjectiveMatch,
                allowCreateIfUnbound: true),
            model.selectedWorkOSStateMessage,
            file: file,
            line: line)
    }

    @MainActor
    private func waitForInitialStoreLoad(_ model: ChatPageModel) async throws {
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }

    private func goalRunFileCount(in store: TatwoGoalRunStore) throws -> Int {
        let goals = store.directoryURL.appendingPathComponent("goals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: goals.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: goals,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.count
    }
}

private struct ChatRouteChoiceTestAnchorAuthority:
    TatwoPLGAnchorAuthority
{
    func sign(_ material: String) -> String {
        "chat-route-choice-test-anchor|\(material)"
    }

    func verify(_ signature: String, material: String) -> Bool {
        signature == sign(material)
    }
}
