import Foundation
import Dispatch
import CryptoKit
import XCTest
@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ChatPlanGoalContinuityTests: XCTestCase {
    private var chatPageSource: String {
        get throws {
            try ChatPageSourceScanner.combinedSource()
        }
    }

    func testCanonicalChatCreationPassesStableScopedAuthorityInstanceDiscriminator() throws {
        let source = try chatPageSource
        let create = try XCTUnwrap(
            source.slice(
                from: "do {\n            guard let canonicalOwner else {",
                through: "selectedWorkOSStateMessage = \"Work OS contract 已建立"))
        XCTAssertTrue(
            create.contains(
                "canonicalChatAuthorityInstanceDiscriminator(for: canonicalOwner)"))
        XCTAssertTrue(create.contains("authorityInstanceDiscriminator:"))
        XCTAssertTrue(
            create.contains(
                "authorityInstanceDiscriminator: authorityInstanceDiscriminator"))
        XCTAssertTrue(create.contains("sessionStore.beginCurrent("))
        XCTAssertFalse(create.contains("UUID()"))
        XCTAssertFalse(create.contains("workspacePath"))

        let helper = try XCTUnwrap(
            source.slice(
                from: "static func canonicalChatAuthorityInstanceDiscriminator(",
                through: "func currentSessionCanonicalOwner("))
        XCTAssertTrue(helper.contains("provider:\\(owner.provider)"))
        XCTAssertTrue(helper.contains("ownerKind:\\(owner.ownerKind.rawValue)"))
        XCTAssertTrue(helper.contains("sessionID:\\(owner.externalProviderID)"))
        XCTAssertFalse(helper.contains("workspacePath"))
        XCTAssertFalse(helper.contains("objective"))
        XCTAssertFalse(helper.contains("UUID()"))
    }

    /// 2026-08-27 缺陷 A：/plan 完成後在 Plan inspector 選 /goal + 單模型 +
    /// 執行，馬上出現「單模型 runner 未啟動；沒有留下假執行中狀態。」、輸入
    /// 殘留、之後畫面還變成 Ultrawork XXL。
    ///
    /// 根因是單模型 /goal 仍然跑了原生開發 Scenario 準備（那是 Ultrawork/PLG
    /// 的路），把這一列改成 XXL 多模型；接著簽發的卻是 S 合約，送出那一輪
    /// Work OS 重驗就 mode/scenario 不一致而整個隔離。
    @MainActor
    func testSingleModelGoalClearsInheritedUltraworkTopologyForThisSessionOnly()
        async throws
    {
        let fixture = makeModelFixture("single-model-topology")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)

        if model.selectedThreadID == nil { model.newChat() }
        let ultraworkThreadID = try XCTUnwrap(model.selectedThreadID)
        model.setCollaborationLevel(.xxl)
        XCTAssertEqual(model.collaborationLevel, .xxl)

        model.newChat()
        let singleModelThreadID = try XCTUnwrap(model.selectedThreadID)
        XCTAssertNotEqual(singleModelThreadID, ultraworkThreadID)
        model.setCollaborationLevel(.xxl)
        XCTAssertEqual(model.collaborationLevel, .xxl)

        XCTAssertTrue(model.prepareSingleModelTopologyForSelectedThread())
        XCTAssertEqual(model.collaborationLevel, .off)
        XCTAssertNil(model.activeLoopsConfig)
        XCTAssertFalse(model.collaborationIsEnabled)

        // 另一個 session 的 Ultrawork 拓撲不得被這次單模型化影響。
        model.selectedThreadID = ultraworkThreadID
        XCTAssertEqual(model.collaborationLevel, .xxl)

        // 已經是單模型的 session 再呼叫一次仍然成立且不製造變更。
        model.selectedThreadID = singleModelThreadID
        XCTAssertTrue(model.prepareSingleModelTopologyForSelectedThread())
        XCTAssertEqual(model.collaborationLevel, .off)
    }

    /// 2026-08-29：Plan inspector 從已 durable bind 的 XXL Goal 切到
    /// `/goal + 單模型` 時，`.contractSuperseded` 的 desired topology 是 nil。
    /// successor 雖然是 S contract，也不能把 materialized S loops digest
    /// 當成 invalidation 的 desired digest，否則 metadata commit 會固定失敗。
    @MainActor
    func testSingleModelGoalInstallsExactSuccessorAfterXXLSupersession()
        async throws
    {
        let fixture = makeModelFixture("single-model-superseded-successor")
        let model = fixture.model
        let nativeStore = TatwoNativeChatStore(
            url: fixture.goalStore.directoryURL
                .appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(model)

        if model.selectedThreadID == nil { model.newChat() }
        let threadID = try XCTUnwrap(model.selectedThreadID)
        XCTAssertEqual(
            model.selectedThread?.sourceMarker,
            TatwoNativeChatThreadSourceMarker.userOwned)

        model.setCollaborationLevel(.xxl)
        XCTAssertEqual(model.collaborationLevel, .xxl)
        let oldObjective = "Durably bind the original XXL Goal before single-model selection"
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: oldObjective,
                requireObjectiveMatch: true,
                allowCreateIfUnbound: true,
                automaticallyBootstrapUserOwnedAuthority: true),
            model.selectedWorkOSStateMessage)

        let oldContract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertEqual(oldContract.mode, .xxl)
        XCTAssertEqual(model.selectedThread?.workOSContractID, oldContract.contractID)
        XCTAssertEqual(model.selectedThread?.workOSGoalID, oldContract.goalID)
        let oldPointer = try XCTUnwrap(
            TatwoSessionStore(
                directoryURL: fixture.goalStore.directoryURL).current())
        XCTAssertEqual(oldPointer.contractID, oldContract.contractID)
        XCTAssertEqual(oldPointer.goalID, oldContract.goalID)
        let persistedXXLRow = try XCTUnwrap(
            try nativeStore.load().threads.first(where: { $0.id == threadID }))
        XCTAssertEqual(persistedXXLRow.workOSContractID, oldContract.contractID)
        XCTAssertEqual(persistedXXLRow.workOSGoalID, oldContract.goalID)
        XCTAssertEqual(persistedXXLRow.loopsConfig?.mode, .xxl)
        XCTAssertTrue(
            persistedXXLRow.selectedThreadWorkOSContext?.matches(
                TatwoObjectiveIdentity.make(oldContract.objective)) == true)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)

        XCTAssertTrue(model.prepareSingleModelTopologyForSelectedThread())
        let invalidatedThread = try XCTUnwrap(model.selectedThread)
        XCTAssertNil(invalidatedThread.workOSContractID)
        XCTAssertNil(invalidatedThread.workOSGoalID)
        XCTAssertNil(invalidatedThread.loopsConfig)
        XCTAssertNil(invalidatedThread.selectedThreadWorkOSContext)
        let invalidation = try XCTUnwrap(
            invalidatedThread.bindingInvalidation)
        XCTAssertEqual(invalidation.reason, .contractSuperseded)
        XCTAssertNil(invalidation.desiredLoopsConfigSHA256)
        XCTAssertNil(invalidation.expectedSuccessor)
        XCTAssertNil(
            try TatwoSessionStore(
                directoryURL: fixture.goalStore.directoryURL).current())
        let cancelledOldGoal = try fixture.goalStore.requireIssuedContract(
            oldContract.contractID)
        XCTAssertEqual(cancelledOldGoal.status, .cancelled)
        XCTAssertEqual(
            cancelledOldGoal.statusReason,
            "superseded_before_dispatch")

        let newObjective = "Install the exact S Goal selected by the Plan inspector"
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: newObjective,
                requireObjectiveMatch: true,
                allowCreateIfUnbound: true,
                automaticallyBootstrapUserOwnedAuthority: true,
                forceSingleModel: true),
            model.selectedWorkOSStateMessage)

        let newContract = try XCTUnwrap(model.selectedWorkOSContract)
        XCTAssertEqual(newContract.mode, .s)
        XCTAssertNotEqual(newContract.contractID, oldContract.contractID)
        XCTAssertNotEqual(newContract.goalID, oldContract.goalID)
        let current = try XCTUnwrap(
            TatwoSessionStore(
                directoryURL: fixture.goalStore.directoryURL).current())
        XCTAssertEqual(current.contractID, newContract.contractID)
        XCTAssertEqual(current.goalID, newContract.goalID)

        let reboundThread = try XCTUnwrap(model.selectedThread)
        XCTAssertEqual(reboundThread.workOSContractID, newContract.contractID)
        XCTAssertEqual(reboundThread.workOSGoalID, newContract.goalID)
        XCTAssertNil(reboundThread.loopsConfig)
        XCTAssertNil(reboundThread.bindingInvalidation)
        XCTAssertTrue(
            reboundThread.selectedThreadWorkOSContext?.matches(
                TatwoObjectiveIdentity.make(newContract.objective)) == true)

        let persistedSRow = try XCTUnwrap(
            try nativeStore.load().threads.first(where: { $0.id == threadID }))
        XCTAssertEqual(persistedSRow.workOSContractID, newContract.contractID)
        XCTAssertEqual(persistedSRow.workOSGoalID, newContract.goalID)
        XCTAssertNil(persistedSRow.loopsConfig)
        XCTAssertNil(persistedSRow.bindingInvalidation)
        XCTAssertTrue(
            persistedSRow.selectedThreadWorkOSContext?.matches(
                TatwoObjectiveIdentity.make(newContract.objective)) == true)

        let oldGoalAfterRebind = try fixture.goalStore.requireIssuedContract(
            oldContract.contractID)
        XCTAssertEqual(oldGoalAfterRebind.status, .cancelled)
        XCTAssertEqual(
            oldGoalAfterRebind.statusReason,
            "superseded_before_dispatch")
        let newGoal = try fixture.goalStore.requireIssuedContract(
            newContract.contractID)
        XCTAssertEqual(newGoal.status, .planned)
        XCTAssertNil(newGoal.latestDispatchCycleEpoch)
        XCTAssertNil(newGoal.latestDispatchCycleSealID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 2)
        XCTAssertEqual(
            try goalRunFileNames(in: fixture.goalStore),
            [
                "\(oldContract.contractID).json",
                "\(newContract.contractID).json",
            ].sorted())
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.pendingSingleModelGoalDispatch)
        XCTAssertNil(model.activeNativeDevelopmentDispatch)
        XCTAssertTrue(model.selectedDispatchRecords.isEmpty)
    }

    /// 單模型 /goal 不得走 Ultrawork/PLG 的原生開發 XXL Scenario 準備。
    func testSingleModelGoalSkipsNativeDevelopmentXXLScenarioPreparation()
        throws
    {
        let source = try chatPageSource
        let activation = try XCTUnwrap(
            source.slice(
                from: "    private func activateGoalFromPromptAsync(",
                through: "            guard beginSingleModelGoalDispatch("))

        // 拓撲判準比「明確單模型派工」更寬：`forceSingleModel` 之外，
        // 沒有本次修訂明確要求 Ultrawork 的 /goal 也一律單模型化，
        // 避免 thread 上殘留的舊 XXL loopsConfig 被當成使用者請求。
        XCTAssertTrue(
            activation.contains(
                "let singleModelTopology =\n            forceSingleModel\n            || TatwoGoalTopologyAuthority.requestedTopology("),
            "單模型拓撲判準必須由明確請求決定，不得繼承 thread 舊拓撲")
        XCTAssertTrue(
            activation.contains("if singleModelTopology {"),
            "單模型 /goal 必須先把這一列切回單模型拓撲")
        XCTAssertTrue(
            activation.contains(
                "guard prepareSingleModelTopologyForSelectedThread() else {"),
            "單模型 /goal 必須先把這一列切回單模型拓撲")
        XCTAssertTrue(
            activation.contains(
                "let nativeDevelopmentRequested =\n            !singleModelTopology"),
            "單模型 /goal 不得被判定為原生開發 Ultrawork 派工")

        let prepareCallIndex = try XCTUnwrap(
            activation.range(
                of: "prepareNativeDevelopmentScenarioForPLGIfNeeded(")?
                .lowerBound)
        let elseBranchIndex = try XCTUnwrap(
            activation.range(of: "        } else {\n            guard await ")?
                .lowerBound)
        XCTAssertLessThan(
            elseBranchIndex,
            prepareCallIndex,
            "原生開發 Scenario 準備只准留在非單模型分支")
    }

    @MainActor
    func testCompletedPlanResponseReplacesSectionsAndReopensConfirmedPlan()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-response-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = UUID()
        let store = TatwoPlanArtifactDiskStore(directoryURL: root)
        let createdAt = Date(timeIntervalSince1970: 1_724_000_000)
        let planID = UUID()
        try store.save(TatwoPlanArtifactV1(
            planID: planID,
            threadID: threadID,
            objective: "保留原目標",
            sections: [.init(title: "舊內容", body: "會被覆蓋")],
            createdAt: createdAt,
            state: .confirmed))
        let model = ChatPageModel(environment: [
            "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
        ])
        model.planArtifactStore = store

        model.updatePlanArtifactFromCompletedResponse(
            "## 新步驟\n先寫 RED。\n\n## 驗收\n再跑測試。",
            threadID: threadID,
            at: Date(timeIntervalSince1970: 1_724_000_120))

        let updated = try XCTUnwrap(store.load(threadID: threadID))
        XCTAssertEqual(updated.planID, planID)
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.objective, "保留原目標")
        XCTAssertEqual(updated.state, .discussing)
        XCTAssertEqual(updated.sections, [
            .init(title: "新步驟", body: "先寫 RED。"),
            .init(title: "驗收", body: "再跑測試。"),
        ])
    }

    @MainActor
    func testCrossThreadPlanCompletionReadsClarificationFromBoundThread()
        async throws
    {
        let fixture = makeModelFixture("cross-thread-plan-completion")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        let planStore = TatwoPlanArtifactDiskStore(
            directoryURL: fixture.goalStore.directoryURL
                .appendingPathComponent("plans", isDirectory: true))
        model.planArtifactStore = planStore

        let planThreadID = UUID()
        let visibleThreadID = UUID()
        model.document = TatwoNativeChatStoreDocument(
            threads: [
                TatwoNativeChatThread(
                    id: planThreadID,
                    title: "Plan turn"),
                TatwoNativeChatThread(
                    id: visibleThreadID,
                    title: "Currently visible"),
            ])
        model.selectStandaloneThread(planThreadID)
        model.pendingPlanObjectives[planThreadID] =
            "Keep the plan bound to its originating thread"
        let planAssistant = ChatMessage(
            id: "plan-thread-assistant",
            role: .assistant,
            text: "I need one decision before the plan is complete.",
            planQuestions: [
                PlanQuestionV1(
                    id: "plan-scope",
                    question: "Which scope?",
                    options: [
                        .init(
                            label: "Current project",
                            detail: "Keep the change bounded.")
                    ])
            ])
        XCTAssertTrue(model.recordCanonicalMessage(planAssistant))

        model.selectStandaloneThread(visibleThreadID)
        model.messages = [
            ChatMessage(
                id: "visible-thread-assistant",
                role: .assistant,
                text: "No clarification is pending here.")
        ]
        XCTAssertEqual(model.selectedThreadID, visibleThreadID)

        let fallbackOnlyResponse =
            "I need one decision before the plan is complete."
        model.updatePlanArtifactFromCompletedResponse(
            fallbackOnlyResponse,
            threadID: planThreadID,
            assistantMessageID: planAssistant.id)

        XCTAssertNil(
            try planStore.load(threadID: planThreadID),
            "A fallback-only response with a pending clarification must not be persisted merely because another thread is selected")
        XCTAssertEqual(
            model.pendingPlanObjectives[planThreadID],
            "Keep the plan bound to its originating thread")
        XCTAssertNil(
            model.activePlanArtifact,
            "Cross-thread completion must not publish the origin thread's Plan into the currently selected thread")
    }

    @MainActor
    func testThreadSwitchParksPendingSingleModelDispatchBeforeRunnerStart()
        async throws
    {
        let fixture = makeModelFixture(
            "pending-single-model-dispatch-thread-switch")
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        let originThreadID = UUID()
        let visibleThreadID = UUID()
        model.document = TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: originThreadID,
                title: "origin pending dispatch"),
            TatwoNativeChatThread(
                id: visibleThreadID,
                title: "temporarily visible"),
        ])
        model.selectStandaloneThread(originThreadID)
        let dispatch = TatwoDispatchRecord(
            id: "dispatch-pending-thread-switch",
            contractID: "contract-origin-thread",
            goalID: "goal-origin-thread",
            bindingID: "binding-origin-thread",
            sourceSlotID: "slot-origin-thread",
            identity: .lead,
            modelID: "gpt-5.6-terra",
            subtask: "keep this pending dispatch bound to its origin thread",
            status: .running,
            startedAt: Date(),
            updatedAt: Date())
        model.pendingSingleModelGoalDispatch = dispatch
        model.singleModelGoalDispatchContractIDByDispatchID[dispatch.id] =
            dispatch.contractID

        model.selectStandaloneThread(visibleThreadID)
        XCTAssertNil(
            model.pendingSingleModelGoalDispatch,
            "the other foreground thread must not inherit the pending dispatch")
        XCTAssertEqual(
            model.singleModelGoalDispatchContractIDByDispatchID[dispatch.id],
            dispatch.contractID,
            "thread switch must retain the dispatch-bound contract lookup")

        model.selectStandaloneThread(originThreadID)
        XCTAssertEqual(model.pendingSingleModelGoalDispatch?.id, dispatch.id)
        XCTAssertEqual(
            model.pendingSingleModelGoalDispatch?.contractID,
            dispatch.contractID)
    }

    func testCodexMirrorReloadPreservesNativeMessagesAndActivePlanPointer() {
        let mirroredID = UUID(uuidString: "019F613E-88FC-7490-9237-FA2A89A23CD6")!
        let staleID = UUID(uuidString: "019F613E-88FC-7490-9237-FA2A89A23CD7")!
        let draftID = UUID(uuidString: "019F613E-88FC-7490-9237-FA2A89A23CD8")!
        let run = TatwoPLGRunFactory.make(
            objective: "Plan continuity",
            contractID: "contract-xxl-general-continuity",
            goalID: "goal-xxl-general-continuity",
            leadModelIDs: ["fable5"],
            subModelIDs: ["sol"],
            nowISO: "2026-07-17T00:00:00Z")
        let nativeMessage = TatwoNativeChatStoredMessage(
            role: "assistant",
            text: "Fable5 plan reply",
            modelID: "fable5")
        let local = TatwoNativeChatStoreDocument(
            projects: [
                TatwoNativeChatProject(
                    name: "Tatwo OS",
                    workdir: "/tmp/tatwo-os",
                    threads: [
                        TatwoNativeChatThread(
                            id: mirroredID,
                            title: "舊本機標題",
                            codexSessionID: mirroredID.uuidString.lowercased(),
                            isPlanModeEnabled: true,
                            workOSGoalID: run.goalID,
                            workOSContractID: run.contractID,
                            activePLGRunProjection: run,
                            messages: [nativeMessage]),
                        TatwoNativeChatThread(
                            id: staleID,
                            title: "不在目前 Codex 側欄的舊 mirror",
                            codexSessionID: staleID.uuidString.lowercased()),
                        TatwoNativeChatThread(
                            id: draftID,
                            title: "本機草稿",
                            messages: [TatwoNativeChatStoredMessage(role: "user", text: "draft")])
                    ])
            ])
        let codexMirror = TatwoNativeChatStoreDocument(
            projects: [
                TatwoNativeChatProject(
                    name: "Tatwo OS",
                    workdir: "/tmp/tatwo-os",
                    threads: [
                        TatwoNativeChatThread(
                            id: mirroredID,
                            title: "Codex 最新標題",
                            codexSessionID: mirroredID.uuidString.lowercased(),
                            mirroredCodexWorkspacePath: "/tmp/tatwo-os/chat-workspace",
                            sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror,
                            lastPreview: "Codex mirror preview")
                    ])
            ])

        let merged = ChatCodexMirrorMerger.merge(
            codexMirror: codexMirror,
            localDocument: local)
        let threads = merged.projects.flatMap(\.threads)
        let restored = threads.first { $0.id == mirroredID }

        XCTAssertEqual(restored?.title, "Codex 最新標題")
        XCTAssertEqual(restored?.messages, [nativeMessage])
        XCTAssertEqual(restored?.isPlanModeEnabled, true)
        XCTAssertEqual(restored?.workOSContractID, run.contractID)
        XCTAssertEqual(restored?.workOSGoalID, run.goalID)
        XCTAssertEqual(restored?.activePLGRunProjection?.id, run.id)
        XCTAssertEqual(
            restored?.mirroredCodexWorkspacePath,
            "/tmp/tatwo-os/chat-workspace")
        XCTAssertEqual(
            restored?.sourceMarker,
            TatwoNativeChatThreadSourceMarker.codexAppMirror)
        XCTAssertTrue(threads.contains { $0.id == draftID })
        XCTAssertFalse(threads.contains { $0.id == staleID })
    }

    func testCodexMirrorReloadDoesNotAutoCreateProjectsFromSessionCWD() {
        let importedID = UUID(uuidString: "019F613E-88FC-7490-9237-FA2A89A23CD9")!
        let standaloneID = UUID(uuidString: "019F613E-88FC-7490-9237-FA2A89A23CDA")!
        let local = TatwoNativeChatStoreDocument(
            threads: [
                TatwoNativeChatThread(
                    id: UUID(uuidString: "21E084EF-C3BF-4842-8166-ACA5BF05A615")!,
                    title: "本機獨立對話",
                    messages: [TatwoNativeChatStoredMessage(role: "user", text: "keep me")])
            ],
            projects: [
                TatwoNativeChatProject(
                    name: "Tatwo UI loop fixture",
                    workdir: "/tmp/tatwo2-fixture",
                    threads: [
                        TatwoNativeChatThread(
                            title: "N10 transcript visual check")
                    ])
            ])
        let codexMirror = TatwoNativeChatStoreDocument(
            threads: [
                TatwoNativeChatThread(
                    id: standaloneID,
                    title: "Codex projectless chat",
                    codexSessionID: standaloneID.uuidString.lowercased(),
                    sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror,
                    lastPreview: "standalone only")
            ],
            projects: [
                TatwoNativeChatProject(
                    name: "example",
                    workdir: "/Users/example",
                    threads: [
                        TatwoNativeChatThread(
                            id: importedID,
                            title: "MacBook home session",
                            codexSessionID: importedID.uuidString.lowercased(),
                            sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror,
                            lastPreview: "must not become a Tatwo project")
                    ]),
                TatwoNativeChatProject(
                    name: "example-project",
                    workdir: "/Users/example/Documents/example-project",
                    threads: [
                        TatwoNativeChatThread(
                            title: "即時語音聊天介面",
                            codexSessionID: "019f0000-0000-7000-8000-00000000aa18",
                            sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror)
                    ])
            ])

        let merged = ChatCodexMirrorMerger.merge(
            codexMirror: codexMirror,
            localDocument: local)

        XCTAssertEqual(merged.projects.map(\.name), ["Tatwo UI loop fixture"])
        XCTAssertEqual(merged.projects.map(\.workdir), ["/tmp/tatwo2-fixture"])
        XCTAssertFalse(merged.projects.contains { $0.workdir.contains("example") })
        XCTAssertEqual(
            Set(merged.threads.map(\.id)),
            Set([
                local.threads[0].id,
                standaloneID
            ]))
        XCTAssertTrue(merged.threads.contains { $0.id == standaloneID })
        XCTAssertFalse(merged.threads.contains { $0.id == importedID })
        XCTAssertFalse(
            merged.projects.flatMap(\.threads).contains { $0.id == importedID })
    }

    @MainActor
    func testExactNativeDevelopmentCanonicalRouteMaterializationReusesIssuedContract() {
        let scenarioID =
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID
        let legacy = TatwoNativeThreadLoopsConfig(
            scenarioID: scenarioID,
            mode: .xxl,
            identitySummary:
                "Plan:主導=gpt-5.6-sol；Loops:執行手=gpt-5.6-sol；Loops:副審=opus-5；Loops:驗收=opus-5",
            tokenBudget: "native development",
            primaryModelID: nil,
            secondaryModelID: nil)
        let materialized = TatwoNativeThreadLoopsConfig(
            scenarioID: scenarioID,
            mode: .xxl,
            identitySummary: legacy.identitySummary,
            tokenBudget: legacy.tokenBudget,
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: "opus-5")

        XCTAssertTrue(
            ChatPageModel.canReuseIssuedContract(
                from: legacy,
                to: materialized))

        var wrongRoute = materialized
        wrongRoute.secondaryModelID = "sonnet-5"
        XCTAssertFalse(
            ChatPageModel.canReuseIssuedContract(
                from: legacy,
                to: wrongRoute))
    }

    func testCodexMirrorReloadPreservesTatwoOwnedRowsMissingFromSidebar() {
        let standaloneID = UUID(
            uuidString: "21E084EF-C3BF-4842-8166-ACA5BF05A614")!
        let projectThreadID = UUID(
            uuidString: "0075FE9A-C7FD-4B8B-8DD5-E48CF3F0A0F4")!
        let standaloneMessage = TatwoNativeChatStoredMessage(
            role: "user",
            text: "你好")
        let projectMessage = TatwoNativeChatStoredMessage(
            role: "assistant",
            text: "N10 transcript visual check")
        let local = TatwoNativeChatStoreDocument(
            threads: [
                TatwoNativeChatThread(
                    id: standaloneID,
                    title: "你好",
                    codexSessionID:
                        "019f5b1f-9bc5-7a53-978f-68506f90cb09",
                    messages: [standaloneMessage])
            ],
            projects: [
                TatwoNativeChatProject(
                    name: "Tatwo UI loop fixture",
                    workdir: "/tmp/tatwo-ui-loop-fixture",
                    threads: [
                        TatwoNativeChatThread(
                            id: projectThreadID,
                            title: "N10 transcript visual check",
                            codexSessionID:
                                "019f4058-d733-73f3-860f-16f99f336775",
                            messages: [projectMessage])
                    ])
            ])

        let merged = ChatCodexMirrorMerger.merge(
            codexMirror: TatwoNativeChatStoreDocument(),
            localDocument: local)

        XCTAssertEqual(
            merged.threads.first(where: { $0.id == standaloneID })?.messages,
            [standaloneMessage])
        XCTAssertEqual(
            merged.projects
                .flatMap(\.threads)
                .first(where: { $0.id == projectThreadID })?
                .messages,
            [projectMessage])
    }

    func testUnreadableJournalIsQuarantinedAndMirrorMergeKeepsTranscriptWhenLocalInlineMessagesAreNil()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-mirror-fallback-unreadable-journal-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let journalURL = directory.appendingPathComponent("journal.json")
        try Data("not-a-chat-transcript-journal".utf8).write(to: journalURL)
        let unreadableJournal = try ChatTranscriptJournalDiskStore(
            fileURL: journalURL
        ).load()
        XCTAssertTrue(unreadableJournal.events.isEmpty)

        let threadID = UUID(
            uuidString: "019FC23E-6443-7B93-B886-0C2298CC7C15")!
        let mirrorMessage = TatwoNativeChatStoredMessage(
            id: "mirror-good-message",
            role: "assistant",
            text: "mirror transcript remains available",
            modelID: "gpt-5.6-sol",
            runtimeAdapterID: "app-server")
        let local = TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: threadID,
                title: "local metadata",
                codexSessionID: threadID.uuidString.lowercased(),
                isPlanModeEnabled: true,
                messages: nil)
        ])
        let mirror = TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: threadID,
                title: "mirror title",
                codexSessionID: threadID.uuidString.lowercased(),
                mirroredCodexWorkspacePath: "/tmp/codex-workspace",
                sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror,
                lastPreview: mirrorMessage.text,
                messages: [mirrorMessage])
        ])

        let merged = ChatCodexMirrorMerger.merge(
            codexMirror: mirror,
            localDocument: local)

        XCTAssertEqual(merged.threads.count, 1)
        XCTAssertEqual(merged.threads.first?.messages, [mirrorMessage])
        XCTAssertTrue(merged.threads.first?.isPlanModeEnabled == true)
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil))
                .contains {
                    $0.lastPathComponent.hasPrefix(
                        "journal.json.invalid-")
                        && $0.pathExtension == "quarantine"
                })
    }

    func testSupersessionCleanupRetryUsesOnlyNarrowTypedReconciliation()
        throws
    {
        let source = try chatPageSource
        let section = try XCTUnwrap(
            source.slice(
                from: "func supersedePristineCurrentGoalBinding(",
                through: "func supersessionFailureMessage("))

        XCTAssertTrue(
            section.contains("reconcileSupersededTerminalCurrent("))
        XCTAssertTrue(
            section.contains(
                "throw TatwoSessionMutationError\n                    .currentSessionSupersededPointerCleanupRequired"))
        XCTAssertFalse(section.contains("snapshotCurrent()"))
        XCTAssertFalse(section.contains("compareAndClearCurrent("))
    }

    func testCurrentSessionOwnerProvenancePreservesThreadAndSessionKinds()
        throws
    {
        let source = try chatPageSource
        let section = try XCTUnwrap(
            source.slice(
                from: "func currentSessionCanonicalOwner(\n        for thread:",
                through: "func currentSessionCanonicalOwner(\n        _ canonicalOwner:"))

        XCTAssertTrue(
            section.contains(
                "locator: .thread(thread.id.uuidString.lowercased())"))
        XCTAssertTrue(
            section.contains(
                "thread.sourceMarker == TatwoNativeChatThreadSourceMarker.codexAppMirror"))
        XCTAssertTrue(section.contains("Self.isCodexAppMirrorThread(thread)"))
        XCTAssertTrue(
            section.contains(
                "let mirroredWorkspace = Self.normalizedWorkspacePath("))
        XCTAssertTrue(section.contains("locator: .session(sessionID)"))
        XCTAssertFalse(
            section.contains(
                "locator: .session(thread.id.uuidString.lowercased())"))
    }

    func testColdLoadIsStatusOnlyAndSelectedAttachIsSchemaAware()
        throws
    {
        let source = try chatPageSource
        let coldLoad = try XCTUnwrap(
            source.slice(
                from:
                    "nonisolated static func loadInitialStorePayload(",
                through:
                    "func applyInitialStoreLoad("))
        let attach = try XCTUnwrap(
            source.slice(
                from:
                    "func attachVerifiedCurrentSessionToSelectedThreadIfEligible(",
                through:
                    "func refreshAfterGoalRevisionPromotion()"))

        XCTAssertTrue(coldLoad.contains("sessionStore.inspectCurrent("))
        XCTAssertFalse(coldLoad.contains("sessionStore.attachCurrent("))
        XCTAssertTrue(
            attach.contains(
                "ownerVerification:\n                            .legacyV2(canonicalOwner.expectation)"))
        XCTAssertTrue(
            attach.contains(
                "ownerVerification: .canonicalV3(canonicalOwner)"))
        XCTAssertTrue(
            attach.contains(
                "legacyOwnerExpectation: canonicalOwner.expectation"))
        XCTAssertFalse(attach.contains("expectedOwner:"))
    }

    func testDurableIntentRemovalRequiresPersistedDesiredRowState() throws {
        let source = try chatPageSource
        let finishSection = try XCTUnwrap(
            source.slice(
                from: "func finishWorkOSBindingMutationIntent(",
                through:
                    "func supersedePristineCurrentGoalBinding("))
        let validatorSection = try XCTUnwrap(
            source.slice(
                from:
                    "nonisolated static func workOSBindingMutationIntentIsApplied(",
                through:
                    "static let exportCLITabFixtureTranscript"))

        XCTAssertTrue(
            finishSection.contains(
                "workOSBindingMutationIntentIsApplied("))
        XCTAssertTrue(finishSection.contains("in: try store.load()"))
        XCTAssertTrue(
            validatorSection.contains(
                "thread.loopsConfig == intent.desiredLoopsConfig"))
        XCTAssertTrue(
            validatorSection.contains(
                "normalizedNonEmpty(thread.workOSContractID) == nil"))
        XCTAssertTrue(
            validatorSection.contains(
                "normalizedNonEmpty(thread.workOSGoalID) == nil"))
    }

    @MainActor
    func testArbitraryLocalStandaloneIsNotHijackedByCurrentSessionPointer() async throws {
        let localID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "local-not-hijacked"
        ) { _ in
            [
                TatwoNativeChatThread(
                    id: localID,
                    title: "ordinary local chat",
                    updatedAt: Date(timeIntervalSince1970: 300))
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertEqual(fixture.model.selectedThreadID, localID)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testTatwoChatWorkspaceMirrorReattachesExactCurrentSessionPointer() async throws {
        let arbitraryID = UUID()
        let mirroredID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "exact-chat-workspace"
        ) { _ in
            [
                TatwoNativeChatThread(
                    id: arbitraryID,
                    title: "newer unrelated local chat",
                    updatedAt: Date(timeIntervalSince1970: 500)),
                self.tatwoWorkspaceMirrorThread(
                    id: mirroredID,
                    title: "Tatwo workspace row",
                    updatedAt: Date(timeIntervalSince1970: 100))
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertEqual(fixture.model.selectedThreadID, mirroredID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testStandaloneV3OwnerReattachesWhenNativeWorkspacePointsAtExternalRepository()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-v3-owner-external-native-workspace-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let externalRepository = root.appendingPathComponent(
            "native-runtime-repository",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalRepository,
            withIntermediateDirectories: true)
        let threadID = UUID()
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        let contract = try WorkOSFactory.projectContract(
            mode: .m,
            scenarioProfileID: "coding",
            objective:
                "reattach V3 standalone owner while native workspace is external")
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: root,
            contractID: contract.contractID)
        let owner = TatwoCanonicalSessionOwnerV1(
            provider: "tatwo-chat",
            locator: .thread(threadID.uuidString.lowercased()),
            workspacePath: TatwoRuntimeLayout.applicationSupportRoot()
                .appendingPathComponent(
                    "chat-workspace",
                    isDirectory: true)
                .standardizedFileURL.path)
        let transaction = TatwoGoalAuthorityTransaction(
            sessionStore: sessionStore,
            goalStore: goalStore,
            dispatchRegistry: TatwoDispatchRegistry(directoryURL: root))
        let attachment = try transaction.begin(
            contract: contract,
            owner: owner).attachment
        let nativeStore = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: threadID,
                title: "existing standalone Goal",
                loopsConfig: loopsConfig(matching: attachment.contract))
        ]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                "TATWO_ULTRAWORK_CHAT_WORKDIR":
                    externalRepository.standardizedFileURL.path
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: root))

        try await waitForInitialStoreLoad(model)

        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(
            model.selectedThread?.workOSContractID,
            attachment.contract.contractID)
        XCTAssertEqual(
            model.selectedThread?.workOSGoalID,
            attachment.contract.goalID)
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            attachment.contract.contractID)
        XCTAssertEqual(
            model.currentConversationWorkspaceURL()
                .standardizedFileURL.path,
            externalRepository.standardizedFileURL.path)
        XCTAssertEqual(try goalRunFileCount(in: goalStore), 1)
    }

    @MainActor
    func testProjectMirrorV2OwnerReattachesExactCurrentSessionWithoutMutation()
        async throws
    {
        let fixture = try makeVerifiedProjectSessionFixture(
            "project-v2-exact"
        ) { contract, sessionID, workspacePath in
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective
            ).owned(
                provider: "codex",
                sessionID: sessionID,
                workspacePath: workspacePath)
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let goalURL = fixture.goalStore.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
            .appendingPathComponent("\(fixture.contract.contractID).json")
        let pointerBefore = try Data(contentsOf: pointerURL)
        let goalBefore = try Data(contentsOf: goalURL)

        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertEqual(fixture.model.selectedProjectID, fixture.projectID)
        XCTAssertEqual(fixture.model.selectedThreadID, fixture.threadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        fixture.model.prompt = "普通 project mirror turn 必須先沿用 canonical session"
        fixture.model.submitCurrentChatTurn()
        XCTAssertEqual(fixture.model.queuedChatTurnCount, 1)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)
    }

    @MainActor
    func testProjectMirrorColdStartRepairsMissingLoopsConfigFromExactContract()
        async throws
    {
        let scenarioID =
            TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID
        let fixture = try makeVerifiedProjectSessionFixture(
            "project-v2-repair-missing-loops",
            scenarioProfileID: scenarioID,
            pointer: { contract, sessionID, workspacePath in
                TatwoSessionPointer(
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: contract.objective
                ).owned(
                    provider: "codex",
                    sessionID: sessionID,
                    workspacePath: workspacePath)
            },
            projects: { contract, sessionID, workspacePath in
                [
                    TatwoNativeChatProject(
                        name: "Missing loops config",
                        workdir: workspacePath,
                        threads: [
                            TatwoNativeChatThread(
                                id: UUID(uuidString: sessionID)!,
                                title: "Exact bound row without loops config",
                                codexSessionID: sessionID,
                                mirroredCodexWorkspacePath: workspacePath,
                                sourceMarker:
                                    TatwoNativeChatThreadSourceMarker
                                        .codexAppMirror,
                                loopsConfig: nil,
                                workOSGoalID: contract.goalID,
                                workOSContractID: contract.contractID,
                                selectedThreadWorkOSContext:
                                    TatwoStoredObjectiveContextV2(
                                        identity: TatwoObjectiveIdentity.make(
                                            contract.objective)))
                        ])
                ]
            })
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }

        try await waitForInitialStoreLoad(fixture.model)

        let config = try XCTUnwrap(fixture.model.selectedThread?.loopsConfig)
        XCTAssertEqual(config.scenarioID, scenarioID)
        XCTAssertEqual(config.mode, .xxl)
        XCTAssertNil(config.primaryModelID)
        XCTAssertNil(config.secondaryModelID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        let reloaded = try TatwoNativeChatStore(
            url: fixture.goalStore.directoryURL.appendingPathComponent(
                "native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false
        ).load()
        let persisted = try XCTUnwrap(
            reloaded.projects.first?.threads.first?.loopsConfig)
        XCTAssertEqual(persisted, config)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testProjectMirrorLegacyV1OwnerMigrationRequiresExplicitAuthorization()
        async throws
    {
        let fixture = try makeVerifiedProjectSessionFixture(
            "project-v1-migrated"
        ) { contract, _, _ in
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective)
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let goalURL = fixture.goalStore.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
            .appendingPathComponent("\(fixture.contract.contractID).json")
        let pointerBefore = try Data(contentsOf: pointerURL)
        let goalBefore = try Data(contentsOf: goalURL)

        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertEqual(fixture.model.selectedProjectID, fixture.projectID)
        XCTAssertEqual(fixture.model.selectedThreadID, fixture.threadID)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)

        fixture.model.isRunning = true
        fixture.model.prompt = "普通 turn 不得自動取得 legacy owner migration 權限"
        fixture.model.submitCurrentChatTurn()
        fixture.model.isRunning = false
        XCTAssertEqual(fixture.model.queuedChatTurnCount, 0)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)

        XCTAssertTrue(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "明確授權沿用 canonical Goal",
                allowLegacyV1OwnerMigration: true))
        let migratedPointer = try XCTUnwrap(
            TatwoSessionStore(
                directoryURL: fixture.goalStore.directoryURL
            ).current())
        XCTAssertEqual(migratedPointer.schema, "TatwoSessionPointerV2")
        XCTAssertEqual(
            migratedPointer.ownerBinding?.sessionID,
            fixture.threadID.uuidString.lowercased())
        XCTAssertNotEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)
        let migratedBytes = try Data(contentsOf: pointerURL)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        XCTAssertTrue(fixture.model.ensureSelectedThreadWorkOSContract())
        XCTAssertEqual(try Data(contentsOf: pointerURL), migratedBytes)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testProjectMirrorLegacyV1MigrationRefusesMultipleCandidateRows()
        async throws
    {
        let firstSession = UUID()
        let fixture = try makeVerifiedProjectSessionFixture(
            "project-v1-ambiguous",
            sessionUUID: firstSession,
            pointer: { contract, _, _ in
                TatwoSessionPointer(
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: contract.objective)
            },
            projects: { contract, _, workspacePath in
                (0..<2).map { index in
                    let sessionID = index == 0 ? firstSession : UUID()
                    return TatwoNativeChatProject(
                        name: "Legacy candidate \(index)",
                        workdir: workspacePath,
                        threads: [
                            TatwoNativeChatThread(
                                id: sessionID,
                                title: "legacy owner candidate \(index)",
                                codexSessionID:
                                    sessionID.uuidString.lowercased(),
                                mirroredCodexWorkspacePath: workspacePath,
                                sourceMarker:
                                    TatwoNativeChatThreadSourceMarker
                                        .codexAppMirror,
                                updatedAt: Date(
                                    timeIntervalSince1970:
                                        TimeInterval(100 + index)),
                                loopsConfig: self.loopsConfig(
                                    matching: contract))
                        ])
                }
            })
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let pointerBefore = try Data(contentsOf: pointerURL)

        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        fixture.model.prompt = "ambiguous V1 project mirror must not queue"
        fixture.model.submitCurrentChatTurn()
        XCTAssertEqual(fixture.model.queuedChatTurnCount, 0)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "明確 $tatwo-ultrawork 指令授權"),
            fixture.model.selectedWorkOSStateMessage)

        XCTAssertFalse(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "明確授權檢查唯一 legacy project owner",
                allowLegacyV1OwnerMigration: true))
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "零個或多個 project owner candidates"),
            fixture.model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testProjectMirrorLegacyV1ExplicitMigrationReplacesMissingStaleRowProjectionWithCanonical()
        async throws
    {
        let fixture = try makeVerifiedProjectSessionFixture(
            "project-v1-stale-row",
            pointer: { contract, _, _ in
                TatwoSessionPointer(
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: contract.objective)
            },
            projects: { contract, sessionID, workspacePath in
                [
                    TatwoNativeChatProject(
                        name: "Stale project projection",
                        workdir: workspacePath,
                        threads: [
                            TatwoNativeChatThread(
                                id: UUID(uuidString: sessionID)!,
                                title: "stale row",
                                codexSessionID: sessionID,
                                mirroredCodexWorkspacePath: workspacePath,
                                sourceMarker:
                                    TatwoNativeChatThreadSourceMarker
                                        .codexAppMirror,
                                loopsConfig: self.loopsConfig(
                                    matching: contract),
                                workOSGoalID: "goal-stale-missing",
                                workOSContractID:
                                    "contract-stale-missing")
                        ])
                ]
            })
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let goalURL = fixture.goalStore.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
            .appendingPathComponent("\(fixture.contract.contractID).json")
        let pointerBefore = try Data(contentsOf: pointerURL)
        let goalBefore = try Data(contentsOf: goalURL)

        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            "contract-stale-missing")
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            "goal-stale-missing")
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "明確 $tatwo-ultrawork 指令授權"),
            fixture.model.selectedWorkOSStateMessage)

        XCTAssertTrue(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "明確授權以 canonical session 取代 missing stale projection",
                allowLegacyV1OwnerMigration: true))
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContractShortID,
            String(fixture.contract.contractID.suffix(12)))
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertNotEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)
    }

    @MainActor
    func testOrdinaryProjectMirrorWithoutCurrentSessionQueuesWithoutGoalMint()
        async throws
    {
        let fixture = try makeVerifiedProjectSessionFixture(
            "project-no-current-session",
            savePointer: false,
            pointer: { contract, _, _ in
                TatwoSessionPointer(
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: contract.objective)
            },
            projects: { _, sessionID, workspacePath in
                [
                    TatwoNativeChatProject(
                        name: "Unbound project mirror",
                        workdir: workspacePath,
                        threads: [
                            TatwoNativeChatThread(
                                id: UUID(uuidString: sessionID)!,
                                title: "ordinary project chat",
                                codexSessionID: sessionID,
                                mirroredCodexWorkspacePath: workspacePath,
                                sourceMarker:
                                    TatwoNativeChatThreadSourceMarker
                                        .codexAppMirror)
                        ])
                ]
            })
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        XCTAssertNil(fixture.model.selectedThread?.loopsConfig)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)

        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        fixture.model.prompt =
            "普通文字，不含 collaboration 關鍵字，也不得繞過 project continuity gate"
        fixture.model.submitCurrentChatTurn()

        XCTAssertEqual(fixture.model.queuedChatTurnCount, 1)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testProjectMirrorV2WrongOwnerFieldsFailClosed()
        async throws
    {
        let cases: [(
            label: String,
            pointer: (
                TatwoWorkOSContractV1,
                String,
                String
            ) -> TatwoSessionPointer
        )] = [
            (
                "provider",
                { contract, sessionID, workspacePath in
                    TatwoSessionPointer(
                        contractID: contract.contractID,
                        goalID: contract.goalID,
                        mode: contract.mode,
                        scenario: contract.scenario,
                        objective: contract.objective
                    ).owned(
                        provider: "claude",
                        sessionID: sessionID,
                        workspacePath: workspacePath)
                }
            ),
            (
                "session",
                { contract, _, workspacePath in
                    TatwoSessionPointer(
                        contractID: contract.contractID,
                        goalID: contract.goalID,
                        mode: contract.mode,
                        scenario: contract.scenario,
                        objective: contract.objective
                    ).owned(
                        provider: "codex",
                        sessionID: UUID().uuidString.lowercased(),
                        workspacePath: workspacePath)
                }
            ),
            (
                "workspace",
                { contract, sessionID, workspacePath in
                    TatwoSessionPointer(
                        contractID: contract.contractID,
                        goalID: contract.goalID,
                        mode: contract.mode,
                        scenario: contract.scenario,
                        objective: contract.objective
                    ).owned(
                        provider: "codex",
                        sessionID: sessionID,
                        workspacePath: "\(workspacePath)/other")
                }
            ),
        ]

        for testCase in cases {
            let fixture = try makeVerifiedProjectSessionFixture(
                "project-v2-wrong-\(testCase.label)",
                pointer: testCase.pointer)
            defer {
                try? FileManager.default.removeItem(
                    at: fixture.goalStore.directoryURL)
            }
            try await waitForInitialStoreLoad(fixture.model)

            XCTAssertNil(
                fixture.model.selectedThread?.workOSContractID,
                testCase.label)
            XCTAssertNil(
                fixture.model.selectedThread?.workOSGoalID,
                testCase.label)
            XCTAssertNil(
                fixture.model.selectedWorkOSContract,
                testCase.label)
            XCTAssertFalse(
                fixture.model.ensureSelectedThreadWorkOSContract(),
                testCase.label)
            XCTAssertEqual(
                try goalRunFileCount(in: fixture.goalStore),
                1,
                testCase.label)
            XCTAssertTrue(
                fixture.model.selectedWorkOSStateMessage.contains(
                    "V2 owner"),
                "\(testCase.label): \(fixture.model.selectedWorkOSStateMessage)")
        }
    }

    @MainActor
    func testProjectMirrorDuplicateV2OwnerRowsRemainQuarantined()
        async throws
    {
        let sharedThreadID = UUID()
        let fixture = try makeVerifiedProjectSessionFixture(
            "project-v2-duplicate-owner",
            sessionUUID: sharedThreadID,
            pointer: { contract, sessionID, workspacePath in
                TatwoSessionPointer(
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: contract.objective
                ).owned(
                    provider: "codex",
                    sessionID: sessionID,
                    workspacePath: workspacePath)
            },
            projects: { _, sessionID, workspacePath in
                (0..<2).map { index in
                    TatwoNativeChatProject(
                        name: "Duplicate \(index)",
                        workdir: workspacePath,
                        threads: [
                            TatwoNativeChatThread(
                                id: sharedThreadID,
                                title: "duplicate owner \(index)",
                                codexSessionID: sessionID,
                                mirroredCodexWorkspacePath: workspacePath,
                                sourceMarker:
                                    TatwoNativeChatThreadSourceMarker
                                        .codexAppMirror,
                                updatedAt: Date(
                                    timeIntervalSince1970:
                                        TimeInterval(100 + index)))
                        ])
                }
            })
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }

        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "零個或多個 Chat rows"),
            fixture.model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testAutoWrittenPointerSurvivesFreshReloadMirrorMergeAndSecondTurn()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-fresh-reload-auto-pointer-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let mirroredID = UUID()
        let codexMirror = TatwoNativeChatStoreDocument(threads: [
            tatwoWorkspaceMirrorThread(
                id: mirroredID,
                title: "Codex mirror fresh reload continuity")
        ])
        try nativeStore.save(
            ChatCodexMirrorMerger.merge(
                codexMirror: codexMirror,
                localDocument: TatwoNativeChatStoreDocument()))

        var firstModel: ChatPageModel? = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory))
        try await waitForInitialStoreLoad(try XCTUnwrap(firstModel))
        firstModel?.setCollaborationLevel(.m)
        try await confirmAuthorityBootstrapAndEnsure(
            try XCTUnwrap(firstModel),
            objectiveHint: "首次合法 begin 必須自動寫入 current-session")

        let originalContractID = try XCTUnwrap(
            firstModel?.selectedWorkOSContract?.contractID)
        let originalGoalID = try XCTUnwrap(
            firstModel?.selectedWorkOSContract?.goalID)
        let pointerURL = directory.appendingPathComponent("current-session.json")
        let originalPointer = try Data(contentsOf: pointerURL)
        let originalGoalFiles = try goalRunFileNames(in: goalStore)
        XCTAssertEqual(originalGoalFiles, ["\(originalContractID).json"])

        firstModel?.isRunning = true
        firstModel?.prompt = "turn 1：同 session 高強度任務第一輪"
        firstModel?.submitCurrentChatTurn()
        XCTAssertEqual(firstModel?.queuedChatTurnCount, 1)
        XCTAssertEqual(
            firstModel?.selectedThread?.workOSContractID,
            originalContractID)
        XCTAssertEqual(firstModel?.selectedThread?.workOSGoalID, originalGoalID)
        firstModel?.isRunning = false
        firstModel?.persistStore()
        firstModel = nil

        // Re-run the same Codex mirror merge against the persisted Tatwo row,
        // matching a real cold-start overlay refresh before model 2 attaches.
        let remerged = ChatCodexMirrorMerger.merge(
            codexMirror: codexMirror,
            localDocument: try nativeStore.load())
        try nativeStore.save(remerged)

        let secondModel = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory))
        try await waitForInitialStoreLoad(secondModel)

        XCTAssertEqual(secondModel.selectedThreadID, mirroredID)
        XCTAssertEqual(
            secondModel.selectedThread?.workOSContractID,
            originalContractID)
        XCTAssertEqual(secondModel.selectedThread?.workOSGoalID, originalGoalID)
        XCTAssertEqual(
            secondModel.selectedWorkOSContract?.contractID,
            originalContractID)

        secondModel.isRunning = true
        defer { secondModel.isRunning = false }
        secondModel.prompt = "turn 2：fresh reload 後沿用同一 GoalRun"
        secondModel.submitCurrentChatTurn()

        XCTAssertEqual(secondModel.queuedChatTurnCount, 1)
        XCTAssertEqual(
            secondModel.selectedThread?.workOSContractID,
            originalContractID)
        XCTAssertEqual(secondModel.selectedThread?.workOSGoalID, originalGoalID)
        XCTAssertEqual(try goalRunFileNames(in: goalStore), originalGoalFiles)
        XCTAssertEqual(try Data(contentsOf: pointerURL), originalPointer)
    }

    @MainActor
    func testDivergedLegacyChatStoresExposeFailClosedPersistenceWarning()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-diverged-legacy-warning-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstLegacyURL = directory.appendingPathComponent("legacy-a.json")
        let secondLegacyURL = directory.appendingPathComponent("legacy-b.json")
        try TatwoNativeChatStore(
            url: firstLegacyURL,
            mirrorsToUnifiedLedger: false
        ).save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(title: "legacy A")
        ]))
        try TatwoNativeChatStore(
            url: secondLegacyURL,
            mirrorsToUnifiedLedger: false
        ).save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(title: "legacy B")
        ]))
        let canonicalURL = directory.appendingPathComponent("canonical.json")
        let nativeStore = TatwoNativeChatStore(
            url: canonicalURL,
            fallbackURLs: [firstLegacyURL, secondLegacyURL],
            mirrorsToUnifiedLedger: false)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        try await waitForInitialStoreLoad(model)

        model.persistStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertTrue(
            model.chatStorePersistenceWarning?.contains(
                "兩份內容不同的舊 Chat 資料") == true)
        XCTAssertTrue(
            model.chatStorePersistenceWarning?.contains("不會猜哪份正確") == true)
    }

    @MainActor
    func testNativePersistFailureKeepsLegacyRowsUntilColdRelaunchCompletesMigration()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-native-persist-failure-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)

        func legacyMessages(
            prefix: String,
            count: Int,
            epoch: TimeInterval
        ) -> [TatwoNativeChatStoredMessage] {
            (0..<count).map { index in
                let text =
                    index == 0
                    ? """
                        [Hidden Codex-style Goal state]
                        private transport-only goal context
                        [/Hidden Codex-style Goal state]

                        \(prefix) visible legacy message \(index)
                        """
                    : "\(prefix) legacy message \(index)"
                return TatwoNativeChatStoredMessage(
                    id: "\(prefix)-\(index)",
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: text,
                    modelID: index.isMultiple(of: 2) ? nil : "gpt-5.6-sol",
                    createdAt: Date(
                        timeIntervalSince1970: epoch + TimeInterval(index)))
            }
        }

        let firstID = UUID()
        let secondID = UUID()
        let firstMessages = legacyMessages(
            prefix: "first",
            count: 24,
            epoch: 1_000)
        let secondMessages = legacyMessages(
            prefix: "second",
            count: 48,
            epoch: 2_000)
        let legacyThreads = [
            TatwoNativeChatThread(
                id: firstID,
                title: "First legacy row",
                createdAt: Date(timeIntervalSince1970: 900),
                updatedAt: Date(timeIntervalSince1970: 1_100),
                messages: firstMessages),
            TatwoNativeChatThread(
                id: secondID,
                title: "Second legacy row",
                createdAt: Date(timeIntervalSince1970: 1_900),
                updatedAt: Date(timeIntervalSince1970: 2_100),
                messages: secondMessages),
        ]
        let fallbackURL = directory.appendingPathComponent("legacy-chat.json")
        try TatwoNativeChatStore(
            url: fallbackURL,
            mirrorsToUnifiedLedger: false
        ).save(TatwoNativeChatStoreDocument(threads: legacyThreads))

        let blockedParent = directory.appendingPathComponent(
            "canonical-parent")
        try Data("block native save".utf8).write(
            to: blockedParent,
            options: [.atomic])
        let nativeStore = TatwoNativeChatStore(
            url: blockedParent.appendingPathComponent("native-chat.json"),
            fallbackURLs: [fallbackURL],
            mirrorsToUnifiedLedger: false)
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let environment = [
            "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            "TATWO_ULTRAWORK_APP_SUPPORT": directory.path,
        ]
        let firstModel = ChatPageModel(
            environment: environment,
            store: nativeStore,
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        try await waitForInitialStoreLoad(firstModel)

        XCTAssertFalse(firstModel.legacyTranscriptMigrationCompleted)
        XCTAssertEqual(firstModel.document.threads.count, 2)
        firstModel.selectStandaloneThread(firstID)
        XCTAssertEqual(firstModel.messages.count, 24)
        firstModel.selectStandaloneThread(secondID)
        XCTAssertEqual(firstModel.messages.count, 48)
        XCTAssertEqual(try journalStore.load().events.count, 72)
        XCTAssertEqual(
            try nativeStore.load().threads,
            legacyThreads,
            "failed native persistence must preserve exact legacy payloads")

        let preservedBlocker = directory.appendingPathComponent(
            "canonical-parent.blocker")
        try FileManager.default.moveItem(
            at: blockedParent,
            to: preservedBlocker)

        XCTAssertTrue(
            firstModel.persistStore(),
            "an unrelated later persist must succeed without scrubbing legacy rows")
        XCTAssertFalse(firstModel.legacyTranscriptMigrationCompleted)
        XCTAssertEqual(
            try nativeStore.load().threads,
            legacyThreads,
            "migration=false must keep exact inline payloads on unrelated saves")

        let relaunched = ChatPageModel(
            environment: environment,
            store: nativeStore,
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        try await waitForInitialStoreLoad(relaunched)

        XCTAssertTrue(relaunched.legacyTranscriptMigrationCompleted)
        XCTAssertEqual(relaunched.document.threads.count, 2)
        relaunched.selectStandaloneThread(firstID)
        XCTAssertEqual(relaunched.messages.count, 24)
        relaunched.selectStandaloneThread(secondID)
        XCTAssertEqual(relaunched.messages.count, 48)
        XCTAssertEqual(try journalStore.load().events.count, 72)
        XCTAssertEqual(
            try nativeStore.load().threads.compactMap(\.messages).reduce(0) {
                $0 + $1.count
            },
            0,
            "only the successful relaunch migration may scrub inline transcripts")
    }

    @MainActor
    func testColdStartCodexMirrorPreservesTwoCanonicalTatwoThreadsUnderHighTurnVolume()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-two-canonical-cold-start-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)

        let firstID = UUID(
            uuidString: "019FC23E-6443-7B93-B886-0C2298CC7C13")!
        let secondID = UUID(
            uuidString: "019FC23E-6443-7B93-B886-0C2298CC7C14")!
        let firstSessionID = firstID.uuidString.lowercased()
        let secondSessionID = secondID.uuidString.lowercased()
        let firstMessageCount = 240
        let secondMessageCount = 480
        let totalMessageCount = firstMessageCount + secondMessageCount
        let firstMessages = (0..<firstMessageCount).map { index in
            TatwoNativeChatStoredMessage(
                id: "first-\(index)",
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "first canonical message \(index) "
                    + String(repeating: "high-volume-context-", count: 24),
                modelID: index.isMultiple(of: 2) ? nil : "gpt-5.6-sol",
                createdAt: Date(
                    timeIntervalSince1970: TimeInterval(1_000 + index)))
        }
        let secondMessages = (0..<secondMessageCount).map { index in
            TatwoNativeChatStoredMessage(
                id: "second-\(index)",
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "second canonical message \(index) "
                    + String(repeating: "high-volume-context-", count: 24),
                modelID: index.isMultiple(of: 2) ? nil : "gpt-5.6-luna",
                createdAt: Date(
                    timeIntervalSince1970: TimeInterval(2_000 + index)))
        }
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: firstID,
                title: "stale first local title",
                codexSessionID: firstSessionID,
                updatedAt: Date(timeIntervalSince1970: 1_035),
                lastPreview: "stale first local preview",
                messages: firstMessages),
            TatwoNativeChatThread(
                id: secondID,
                title: "stale second local title",
                codexSessionID: secondSessionID,
                updatedAt: Date(timeIntervalSince1970: 2_035),
                lastPreview: "stale second local preview",
                messages: secondMessages),
        ]))

        let databaseURL = directory.appendingPathComponent("state_5.sqlite")
        let globalStateURL = directory.appendingPathComponent(
            ".codex-global-state.json")
        let chatWorkspace = directory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
            .appendingPathComponent("chat-workspace", isDirectory: true)
            .standardizedFileURL
        let escapedWorkspace = chatWorkspace.path.replacingOccurrences(
            of: "'",
            with: "''")
        try runSQLite(
            db: databaseURL,
            sql: """
            CREATE TABLE threads (
              id TEXT PRIMARY KEY,
              rollout_path TEXT NOT NULL,
              cwd TEXT NOT NULL,
              title TEXT NOT NULL,
              source TEXT NOT NULL,
              thread_source TEXT,
              preview TEXT NOT NULL DEFAULT '',
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              created_at_ms INTEGER,
              updated_at_ms INTEGER,
              recency_at_ms INTEGER NOT NULL DEFAULT 0,
              archived INTEGER NOT NULL DEFAULT 0,
              model TEXT
            );
            INSERT INTO threads (
              id, rollout_path, cwd, title, source, thread_source, preview,
              created_at, updated_at, created_at_ms, updated_at_ms,
              recency_at_ms, archived, model
            ) VALUES
            (
              '\(firstSessionID)',
              '/tmp/tatwo-first-canonical-rollout.jsonl',
              '\(escapedWorkspace)',
              'Codex first canonical title',
              'user',
              'user',
              'Codex first canonical preview',
              100, 300, 100000, 300000, 300000, 0, 'gpt-5.6-sol'
            ),
            (
              '\(secondSessionID)',
              '/tmp/tatwo-second-canonical-rollout.jsonl',
              '\(escapedWorkspace)',
              'Codex second canonical title',
              'user',
              'user',
              'Codex second canonical preview',
              200, 400, 200000, 400000, 400000, 0, 'gpt-5.6-luna'
            );
            """)
        try """
            {
              "project-order": [],
              "electron-saved-workspace-roots": [],
              "thread-project-assignments": {},
              "thread-workspace-root-hints": {},
              "projectless-thread-ids": [],
              "sidebar-project-thread-orders": {}
            }
            """.data(using: .utf8)!.write(to: globalStateURL)

        let bridge = TatwoCodexAppStateBridge(
            sourcePaths: .init(
                stateDatabaseURL: databaseURL,
                globalStateURL: globalStateURL),
            maxThreadRows: 10,
            maxThreadsPerProject: 10,
            maxStandaloneThreads: 10)
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let environment = [
            "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_CHAT_COLD_START_HYDRATION": "deferred",
            "TATWO_ULTRAWORK_APP_SUPPORT": directory.path,
        ]
        func semanticDigest(_ messages: [ChatMessage]) -> String {
            var payload = Data()
            for message in messages {
                let trimmedRuntime = message.runtimeAdapterID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedRuntime =
                    trimmedRuntime?.isEmpty == false
                    ? trimmedRuntime!
                    : (message.role == .assistant ? "tatwo-chat" : "")
                for field in [
                    message.id,
                    message.role.storageValue,
                    message.text,
                    message.modelID ?? "",
                    message.eventKind.rawValue,
                    normalizedRuntime,
                ] {
                    let data = Data(field.utf8)
                    var length = UInt64(data.count).bigEndian
                    withUnsafeBytes(of: &length) {
                        payload.append(contentsOf: $0)
                    }
                    payload.append(data)
                }
            }
            return SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        let expectedDigests = [
            firstID: semanticDigest(
                firstMessages.map { ChatMessage(stored: $0) }),
            secondID: semanticDigest(
                secondMessages.map { ChatMessage(stored: $0) }),
        ]
        var firstModel: ChatPageModel? = ChatPageModel(
            environment: environment,
            store: nativeStore,
            codexAppStateBridge: bridge,
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        firstModel?.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForInitialStoreLoad(try XCTUnwrap(firstModel))

        XCTAssertEqual(firstModel!.codexMirrorStatus, .loaded)
        let firstLoadedRows = firstModel!.document.threads
        XCTAssertTrue(firstModel!.document.projects.isEmpty)
        XCTAssertEqual(Set(firstLoadedRows.map(\.id)), Set([firstID, secondID]))
        XCTAssertEqual(firstLoadedRows.count, 2)
        firstModel!.selectStandaloneThread(firstID)
        XCTAssertEqual(firstModel!.messages.count, firstMessageCount)
        XCTAssertEqual(
            semanticDigest(firstModel!.messages),
            expectedDigests[firstID])
        firstModel!.selectStandaloneThread(secondID)
        XCTAssertEqual(firstModel!.messages.count, secondMessageCount)
        XCTAssertEqual(
            semanticDigest(firstModel!.messages),
            expectedDigests[secondID])
        XCTAssertEqual(
            firstLoadedRows.first(where: { $0.id == firstID })?.title,
            "Codex first canonical title")
        XCTAssertEqual(
            firstLoadedRows.first(where: { $0.id == secondID })?.title,
            "Codex second canonical title")
        XCTAssertEqual(
            firstLoadedRows.first(where: { $0.id == firstID })?.lastPreview,
            "Codex first canonical preview")
        XCTAssertEqual(
            firstLoadedRows.first(where: { $0.id == secondID })?.lastPreview,
            "Codex second canonical preview")
        XCTAssertTrue(firstLoadedRows.allSatisfy {
            $0.id.uuidString.lowercased() == $0.codexSessionID
                && $0.mirroredCodexWorkspacePath == chatWorkspace.path
                && $0.sourceMarker
                    == TatwoNativeChatThreadSourceMarker.codexAppMirror
        })
        XCTAssertTrue(firstModel!.persistStore())

        let nativeReload = try nativeStore.load()
        XCTAssertTrue(nativeReload.projects.isEmpty)
        XCTAssertEqual(Set(nativeReload.threads.map(\.id)), Set([firstID, secondID]))
        XCTAssertEqual(nativeReload.threads.count, 2)
        XCTAssertEqual(
            nativeReload.threads.compactMap(\.messages).reduce(0) {
                $0 + $1.count
            },
            0,
            "legacy inline messages must be scrubbed only after journal migration")
        let journalReload = try journalStore.load()
        let firstJournalMessages =
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: firstID
                ).stableKey,
                from: journalReload)
        let secondJournalMessages =
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: secondID
                ).stableKey,
                from: journalReload)
        XCTAssertEqual(firstJournalMessages.count, firstMessageCount)
        XCTAssertEqual(secondJournalMessages.count, secondMessageCount)
        XCTAssertEqual(
            semanticDigest(firstJournalMessages),
            expectedDigests[firstID])
        XCTAssertEqual(
            semanticDigest(secondJournalMessages),
            expectedDigests[secondID])
        XCTAssertEqual(
            Set(firstJournalMessages.map(\.id)).count,
            firstJournalMessages.count)
        XCTAssertEqual(
            Set(secondJournalMessages.map(\.id)).count,
            secondJournalMessages.count)
        XCTAssertEqual(journalReload.events.count, totalMessageCount)
        XCTAssertEqual(
            Set(journalReload.events.map(\.eventID)).count,
            journalReload.events.count)
        let firstPersistEventCount = journalReload.events.count
        firstModel = nil

        let mirrorCacheRoot =
            TatwoCodexAppStateBridge.defaultMirrorCacheRoot(
                environment: environment)
        if FileManager.default.fileExists(atPath: mirrorCacheRoot.path) {
            try FileManager.default.removeItem(at: mirrorCacheRoot)
        }

        // A real, readable SQLite database with a valid schema and zero rows is
        // a loaded-empty observation, not deletion authority for canonical
        // Tatwo rows or journal-backed transcripts.
        try runSQLite(db: databaseURL, sql: "DELETE FROM threads;")
        var emptyMirrorModel: ChatPageModel? = ChatPageModel(
            environment: environment,
            store: nativeStore,
            codexAppStateBridge: bridge,
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        emptyMirrorModel?.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForInitialStoreLoad(try XCTUnwrap(emptyMirrorModel))

        XCTAssertEqual(emptyMirrorModel!.codexMirrorStatus, .loaded)
        XCTAssertEqual(
            Set(emptyMirrorModel!.document.threads.map(\.id)),
            Set([firstID, secondID]))
        XCTAssertEqual(emptyMirrorModel!.document.threads.count, 2)
        emptyMirrorModel!.selectStandaloneThread(firstID)
        XCTAssertEqual(emptyMirrorModel!.messages.count, firstMessageCount)
        XCTAssertEqual(
            semanticDigest(emptyMirrorModel!.messages),
            expectedDigests[firstID])
        emptyMirrorModel!.selectStandaloneThread(secondID)
        XCTAssertEqual(emptyMirrorModel!.messages.count, secondMessageCount)
        XCTAssertEqual(
            semanticDigest(emptyMirrorModel!.messages),
            expectedDigests[secondID])
        XCTAssertTrue(emptyMirrorModel!.persistStore())
        let emptyMirrorJournal = try journalStore.load()
        XCTAssertEqual(emptyMirrorJournal.events.count, firstPersistEventCount)
        XCTAssertEqual(
            Set(emptyMirrorJournal.events.map(\.eventID)).count,
            emptyMirrorJournal.events.count)
        emptyMirrorModel = nil

        // A readable path containing an invalid SQLite payload must remain
        // unavailable and must never be converted into an empty overlay merge.
        try FileManager.default.removeItem(at: databaseURL)
        try Data("invalid sqlite payload".utf8).write(
            to: databaseURL,
            options: [.atomic])
        if FileManager.default.fileExists(atPath: mirrorCacheRoot.path) {
            try FileManager.default.removeItem(at: mirrorCacheRoot)
        }
        var invalidMirrorModel: ChatPageModel? = ChatPageModel(
            environment: environment,
            store: nativeStore,
            codexAppStateBridge: bridge,
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        invalidMirrorModel?.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForInitialStoreLoad(try XCTUnwrap(invalidMirrorModel))

        XCTAssertEqual(invalidMirrorModel!.codexMirrorStatus, .unavailable)
        XCTAssertEqual(
            Set(invalidMirrorModel!.document.threads.map(\.id)),
            Set([firstID, secondID]))
        XCTAssertEqual(invalidMirrorModel!.document.threads.count, 2)
        invalidMirrorModel!.selectStandaloneThread(firstID)
        XCTAssertEqual(invalidMirrorModel!.messages.count, firstMessageCount)
        XCTAssertEqual(
            semanticDigest(invalidMirrorModel!.messages),
            expectedDigests[firstID])
        invalidMirrorModel!.selectStandaloneThread(secondID)
        XCTAssertEqual(invalidMirrorModel!.messages.count, secondMessageCount)
        XCTAssertEqual(
            semanticDigest(invalidMirrorModel!.messages),
            expectedDigests[secondID])
        XCTAssertTrue(invalidMirrorModel!.persistStore())
        XCTAssertEqual(
            try journalStore.load().events.count,
            firstPersistEventCount)
        invalidMirrorModel = nil

        // A structurally valid SQLite file whose schema cannot satisfy the
        // production thread query is a query failure, not a loaded-empty
        // observation. It must preserve the same canonical rows and journal.
        try FileManager.default.removeItem(at: databaseURL)
        try runSQLite(
            db: databaseURL,
            sql: """
            CREATE TABLE unrelated_state (
              id TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            INSERT INTO unrelated_state (id, value)
            VALUES ('query-failure-fixture', 'must stay unavailable');
            """)
        if FileManager.default.fileExists(atPath: mirrorCacheRoot.path) {
            try FileManager.default.removeItem(at: mirrorCacheRoot)
        }
        var queryFailureMirrorModel: ChatPageModel? = ChatPageModel(
            environment: environment,
            store: nativeStore,
            codexAppStateBridge: bridge,
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        queryFailureMirrorModel?.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForInitialStoreLoad(
            try XCTUnwrap(queryFailureMirrorModel))

        XCTAssertEqual(
            queryFailureMirrorModel!.codexMirrorStatus,
            .unavailable)
        XCTAssertEqual(
            Set(queryFailureMirrorModel!.document.threads.map(\.id)),
            Set([firstID, secondID]))
        XCTAssertEqual(queryFailureMirrorModel!.document.threads.count, 2)
        queryFailureMirrorModel!.selectStandaloneThread(firstID)
        XCTAssertEqual(
            queryFailureMirrorModel!.messages.count,
            firstMessageCount)
        XCTAssertEqual(
            semanticDigest(queryFailureMirrorModel!.messages),
            expectedDigests[firstID])
        queryFailureMirrorModel!.selectStandaloneThread(secondID)
        XCTAssertEqual(
            queryFailureMirrorModel!.messages.count,
            secondMessageCount)
        XCTAssertEqual(
            semanticDigest(queryFailureMirrorModel!.messages),
            expectedDigests[secondID])
        XCTAssertTrue(queryFailureMirrorModel!.persistStore())
        let queryFailureJournal = try journalStore.load()
        XCTAssertEqual(
            queryFailureJournal.events.count,
            firstPersistEventCount)
        XCTAssertEqual(
            Set(queryFailureJournal.events.map(\.eventID)).count,
            queryFailureJournal.events.count)
        queryFailureMirrorModel = nil

        try FileManager.default.removeItem(at: databaseURL)
        let unavailableSourceRoot = directory.appendingPathComponent(
            "missing-codex-source",
            isDirectory: true)
        let unavailableBridge = TatwoCodexAppStateBridge(
            sourcePaths: .init(
                stateDatabaseURL: unavailableSourceRoot
                    .appendingPathComponent("state_5.sqlite"),
                globalStateURL: unavailableSourceRoot
                    .appendingPathComponent(".codex-global-state.json")),
            maxThreadRows: 10,
            maxThreadsPerProject: 10,
            maxStandaloneThreads: 10)

        let secondModel = ChatPageModel(
            environment: environment,
            store: nativeStore,
            codexAppStateBridge: unavailableBridge,
            transcriptJournalStore: journalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory),
            plgChainStore: makeTestPLGChainStore(in: directory))
        secondModel.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForInitialStoreLoad(secondModel)

        XCTAssertEqual(secondModel.codexMirrorStatus, .unavailable)
        XCTAssertTrue(secondModel.document.projects.isEmpty)
        XCTAssertEqual(
            Set(secondModel.document.threads.map(\.id)),
            Set([firstID, secondID]))
        XCTAssertEqual(secondModel.document.threads.count, 2)
        secondModel.selectStandaloneThread(firstID)
        XCTAssertEqual(secondModel.messages.count, firstMessageCount)
        XCTAssertEqual(
            semanticDigest(secondModel.messages),
            expectedDigests[firstID])
        secondModel.selectStandaloneThread(secondID)
        XCTAssertEqual(secondModel.messages.count, secondMessageCount)
        XCTAssertEqual(
            semanticDigest(secondModel.messages),
            expectedDigests[secondID])
        for id in [firstID, secondID] {
            let row = try XCTUnwrap(
                secondModel.document.threads.first(where: { $0.id == id }))
            XCTAssertEqual(row.codexSessionID, id.uuidString.lowercased())
            XCTAssertEqual(row.mirroredCodexWorkspacePath, chatWorkspace.path)
            XCTAssertEqual(
                row.sourceMarker,
                TatwoNativeChatThreadSourceMarker.codexAppMirror)
        }
        XCTAssertEqual(
            secondModel.document.threads.first(where: { $0.id == firstID })?
                .title,
            "Codex first canonical title")
        XCTAssertEqual(
            secondModel.document.threads.first(where: { $0.id == secondID })?
                .title,
            "Codex second canonical title")
        XCTAssertEqual(
            secondModel.document.threads.first(where: { $0.id == firstID })?
                .lastPreview,
            "Codex first canonical preview")
        XCTAssertEqual(
            secondModel.document.threads.first(where: { $0.id == secondID })?
                .lastPreview,
            "Codex second canonical preview")

        XCTAssertTrue(secondModel.persistStore())
        let secondJournalReload = try journalStore.load()
        XCTAssertEqual(secondJournalReload.events.count, firstPersistEventCount)
        XCTAssertEqual(
            semanticDigest(
                ChatTranscriptJournalAdapter.projectedMessages(
                    threadID: TatwoNativeChatSessionReference(
                        kind: .thread,
                        id: firstID
                    ).stableKey,
                    from: secondJournalReload)),
            expectedDigests[firstID])
        XCTAssertEqual(
            semanticDigest(
                ChatTranscriptJournalAdapter.projectedMessages(
                    threadID: TatwoNativeChatSessionReference(
                        kind: .thread,
                        id: secondID
                    ).stableKey,
                    from: secondJournalReload)),
            expectedDigests[secondID])
        let secondNativeReload = try nativeStore.load()
        XCTAssertTrue(secondNativeReload.projects.isEmpty)
        XCTAssertEqual(
            Set(secondNativeReload.threads.map(\.id)),
            Set([firstID, secondID]))
        XCTAssertEqual(secondNativeReload.threads.count, 2)
        XCTAssertEqual(
            secondNativeReload.threads.compactMap(\.messages).reduce(0) {
                $0 + $1.count
            },
            0)
    }

    @MainActor
    func testCodexSQLiteOverlayMergeAttachesCanonicalPointerToExistingTatwoRow()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-codex-overlay-current-session-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)

        let databaseURL = directory.appendingPathComponent("state_5.sqlite")
        let globalStateURL = directory.appendingPathComponent(
            ".codex-global-state.json")
        let threadID = UUID(
            uuidString: "019FC23E-6443-7B93-B886-0C2298CC7C13")!
        let codexSessionID = threadID.uuidString.lowercased()
        let chatWorkspace = TatwoRuntimeLayout.applicationSupportRoot()
            .appendingPathComponent("chat-workspace", isDirectory: true)
            .standardizedFileURL
        try runSQLite(
            db: databaseURL,
            sql: """
            CREATE TABLE threads (
              id TEXT PRIMARY KEY,
              rollout_path TEXT NOT NULL,
              cwd TEXT NOT NULL,
              title TEXT NOT NULL,
              source TEXT NOT NULL,
              thread_source TEXT,
              preview TEXT NOT NULL DEFAULT '',
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              created_at_ms INTEGER,
              updated_at_ms INTEGER,
              recency_at_ms INTEGER NOT NULL DEFAULT 0,
              archived INTEGER NOT NULL DEFAULT 0,
              model TEXT
            );
            INSERT INTO threads (
              id, rollout_path, cwd, title, source, thread_source, preview,
              created_at, updated_at, created_at_ms, updated_at_ms,
              recency_at_ms, archived, model
            )
            VALUES (
              '\(codexSessionID)',
              '/tmp/tatwo-overlay-rollout.jsonl',
              '\(chatWorkspace.path.replacingOccurrences(of: "'", with: "''"))',
              'Codex overlay canonical row',
              'user',
              'user',
              'Codex overlay preview',
              100, 200, 100000, 200000, 200000, 0, 'gpt-5.6-sol'
            );
            """)
        try """
            {
              "project-order": [],
              "electron-saved-workspace-roots": [],
              "thread-project-assignments": {},
              "thread-workspace-root-hints": {},
              "projectless-thread-ids": ["\(codexSessionID)"],
              "sidebar-project-thread-orders": {}
            }
            """.data(using: .utf8)!.write(to: globalStateURL)

        let bridge = TatwoCodexAppStateBridge(
            sourcePaths: .init(
                stateDatabaseURL: databaseURL,
                globalStateURL: globalStateURL),
            maxThreadRows: 10,
            maxThreadsPerProject: 10,
            maxStandaloneThreads: 10)
        let codexMirror = try await Task.detached(priority: .utility) {
            try bridge.loadDocumentOverlay()
        }.value
        let localMessage = TatwoNativeChatStoredMessage(
            role: "user",
            text: "existing Tatwo row state")
        let localDocument = TatwoNativeChatStoreDocument(threads: [
            TatwoNativeChatThread(
                id: threadID,
                title: "stale local title",
                codexSessionID: codexSessionID,
                messages: [localMessage])
        ])
        let merged = ChatCodexMirrorMerger.merge(
            codexMirror: codexMirror,
            localDocument: localDocument)
        let mergedRow = try XCTUnwrap(
            merged.threads.first(where: { $0.id == threadID }))

        XCTAssertEqual(merged.projects.count, 0)
        XCTAssertEqual(mergedRow.codexSessionID, codexSessionID)
        XCTAssertEqual(mergedRow.title, "Codex overlay canonical row")
        XCTAssertEqual(mergedRow.messages, [localMessage])
        XCTAssertEqual(
            mergedRow.sourceMarker,
            TatwoNativeChatThreadSourceMarker.codexAppMirror)
        XCTAssertEqual(
            mergedRow.mirroredCodexWorkspacePath,
            chatWorkspace.path)

        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "Attach the canonical pointer to the real Codex overlay row",
            store: goalStore)
        try TatwoSessionStore(directoryURL: directory).writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective))
        try nativeStore.save(merged)

        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory))
        try await waitForInitialStoreLoad(model)

        XCTAssertEqual(model.selectedThreadID, threadID)
        XCTAssertEqual(model.selectedThread?.codexSessionID, codexSessionID)
        XCTAssertEqual(
            model.selectedThread?.sourceMarker,
            TatwoNativeChatThreadSourceMarker.codexAppMirror)
        XCTAssertEqual(
            model.selectedThread?.mirroredCodexWorkspacePath,
            chatWorkspace.path)
        XCTAssertEqual(
            model.selectedThread?.workOSContractID,
            contract.contractID)
        XCTAssertEqual(model.selectedThread?.workOSGoalID, contract.goalID)
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            contract.contractID)
        XCTAssertEqual(model.selectedWorkOSContract?.goalID, contract.goalID)
        XCTAssertEqual(try goalRunFileNames(in: goalStore), [
            "\(contract.contractID).json"
        ])
    }

    @MainActor
    func testExactCurrentSessionReusesOneGoalRunAcrossTwoCompletedRemoteSubmissions()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-current-session-completed-turns-\(UUID().uuidString)",
                isDirectory: true)
        let mirroredID = UUID()
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID:
                TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
            objective:
                "同一個 Tatwo Chat session 完成一輪後，下一輪必須沿用 canonical GoalRun",
            store: goalStore)
        let sessionStore = TatwoSessionStore(directoryURL: directory)
        try sessionStore.writeRawPointerFixtureForTesting(TatwoSessionPointer(
            contractID: contract.contractID,
            goalID: contract.goalID,
            mode: contract.mode,
            scenario: contract.scenario,
            objective: contract.objective))
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [
            tatwoWorkspaceMirrorThread(
                id: mirroredID,
                title: "Tatwo canonical completed-turn continuity")
        ]))

        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent(
                "authorization",
                isDirectory: true))
        let sessionID = mirroredID.uuidString.lowercased()
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: sessionID,
            targetDeviceID: "target-completed-turns",
            contractID: contract.contractID,
            now: Date())
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let dispatcher = ChatPlanGoalContinuityRemoteDispatcher()
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory),
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher)
        try await waitForInitialStoreLoad(model)

        let originalPointer = try Data(
            contentsOf: directory.appendingPathComponent("current-session.json"))
        let originalGoalFiles = try goalRunFileNames(in: goalStore)
        let canonicalGoalURL = goalStore.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
            .appendingPathComponent("\(contract.contractID).json")
        let originalGoal = try Data(contentsOf: canonicalGoalURL)
        XCTAssertEqual(model.selectedThreadID, mirroredID)
        XCTAssertEqual(model.selectedWorkOSContract?.contractID, contract.contractID)
        XCTAssertEqual(model.selectedWorkOSContract?.goalID, contract.goalID)
        XCTAssertEqual(originalGoalFiles, ["\(contract.contractID).json"])
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.queuedChatTurnCount, 0)
        XCTAssertEqual(contract.identityBindings.count, 4)
        XCTAssertEqual(
            Set(contract.identityBindings.map(\.sourceSlotID)),
            Set([
                "general-xxl-exact-plan-lead-sol",
                "general-xxl-exact-loops-supervisor-fable5",
                "general-xxl-exact-loops-sub-luna",
                "general-xxl-exact-loops-sub-grok",
            ]))
        XCTAssertEqual(
            contract.identityBindings
                .filter { $0.identity == .lead }
                .map(\.modelID),
            ["gpt-5.6-sol"])
        XCTAssertEqual(
            contract.identityBindings
                .filter { $0.identity == .supervisor }
                .map(\.modelID),
            ["fable-5"])
        XCTAssertEqual(
            contract.identityBindings
                .filter { $0.identity == .sub }
                .map(\.modelID),
            ["gpt-5.6-luna", "grok-build"])
        let activatedBindings = Dictionary(
            uniqueKeysWithValues:
                contract.loopGovernorDecision.activatedBindings.map { ($0.id, $0) })
        XCTAssertEqual(
            Set(activatedBindings.keys),
            Set([
                "general-xxl-exact-plan-lead-sol",
                "general-xxl-exact-loops-supervisor-fable5",
                "general-xxl-exact-loops-sub-luna",
                "general-xxl-exact-loops-sub-grok",
            ]))
        let solBinding = try XCTUnwrap(
            activatedBindings["general-xxl-exact-plan-lead-sol"])
        XCTAssertEqual(solBinding.phase, .plan)
        XCTAssertEqual(solBinding.reasoningEffort, .low)
        XCTAssertEqual(solBinding.dynamicActivation, .always)
        let fableBinding = try XCTUnwrap(
            activatedBindings["general-xxl-exact-loops-supervisor-fable5"])
        XCTAssertEqual(fableBinding.phase, .loops)
        XCTAssertNil(fableBinding.reasoningEffort)
        XCTAssertEqual(fableBinding.dynamicActivation, .always)
        let lunaBinding = try XCTUnwrap(
            activatedBindings["general-xxl-exact-loops-sub-luna"])
        XCTAssertEqual(lunaBinding.phase, .loops)
        XCTAssertEqual(lunaBinding.reasoningEffort, .xhigh)
        XCTAssertEqual(lunaBinding.dynamicActivation, .allowed)
        let grokBinding = try XCTUnwrap(
            activatedBindings["general-xxl-exact-loops-sub-grok"])
        XCTAssertEqual(grokBinding.phase, .loops)
        XCTAssertEqual(grokBinding.reasoningEffort, .xhigh)
        XCTAssertEqual(grokBinding.dynamicActivation, .allowed)

        let issuedBindings = try goalStore.requireIssuedIdentityBindings(
            contractID: contract.contractID)
        let issuedBindingsBySourceSlotID = Dictionary(
            uniqueKeysWithValues: issuedBindings.map { ($0.sourceSlotID, $0) })
        XCTAssertEqual(
            Set(issuedBindingsBySourceSlotID.keys),
            Set(activatedBindings.keys))
        XCTAssertEqual(
            issuedBindingsBySourceSlotID[
                "general-xxl-exact-plan-lead-sol"
            ]?.reasoningEffort,
            .low)
        XCTAssertNil(
            issuedBindingsBySourceSlotID[
                "general-xxl-exact-loops-supervisor-fable5"
            ]?.reasoningEffort)
        XCTAssertEqual(
            issuedBindingsBySourceSlotID[
                "general-xxl-exact-loops-sub-luna"
            ]?.reasoningEffort,
            .xhigh)
        XCTAssertEqual(
            issuedBindingsBySourceSlotID[
                "general-xxl-exact-loops-sub-grok"
            ]?.reasoningEffort,
            .xhigh)
        model.setSingleModel("gpt-5.6-sol")
        XCTAssertEqual(model.selectedModel, "gpt-5.6-sol")

        let prompts = [
            "第一輪：Sol 純文字可靠性審計。",
            "第二輪：Luna xhigh 純文字反例審查。",
        ]
        for (turn, prompt) in prompts.enumerated() {
            _ = try pendingStore.arm(
                grant: grant,
                goalID: contract.goalID,
                targetDisplayName: "Mac mini",
                now: Date().addingTimeInterval(TimeInterval(turn)))

            model.isRunning = true
            model.prompt = prompt
            model.submitCurrentChatTurn()
            XCTAssertEqual(model.chatQueue.count, 1, "turn \(turn + 1)")
            let queued = try XCTUnwrap(model.chatQueue.last)
            let queuedSnapshot = queued.dispatchSnapshot
            XCTAssertEqual(
                queuedSnapshot.routeID,
                "gpt-5.6-sol",
                "turn \(turn + 1)")
            XCTAssertEqual(
                queuedSnapshot.canonicalModelID,
                "gpt-5.6-sol",
                "turn \(turn + 1)")
            XCTAssertNotEqual(
                queuedSnapshot.canonicalModelID,
                "grok-build",
                "turn \(turn + 1)")
            XCTAssertEqual(
                queuedSnapshot.contractID,
                contract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                queuedSnapshot.contractBindingID,
                "general-xxl-exact-plan-lead-sol",
                "turn \(turn + 1)")
            XCTAssertNil(queuedSnapshot.blocker, "turn \(turn + 1)")
            model.isRunning = false
            model.resumeQueuedChatTurns()
            try await waitUntil {
                dispatcher.requests.count == turn + 1
                    && !model.isRunning
                    && (try? pendingStore.pending(sessionID: sessionID)) == nil
            }

            XCTAssertEqual(model.queuedChatTurnCount, 0, "turn \(turn + 1)")
            XCTAssertEqual(model.selectedThreadID, mirroredID, "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedThread?.workOSContractID,
                contract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedThread?.workOSGoalID,
                contract.goalID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                model.selectedWorkOSContract?.contractID,
                contract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                try goalRunFileNames(in: goalStore),
                originalGoalFiles,
                "turn \(turn + 1) minted or replaced a GoalRun")
            XCTAssertEqual(
                try Data(contentsOf: canonicalGoalURL),
                originalGoal,
                "turn \(turn + 1) mutated the canonical GoalRun JSON")
            XCTAssertEqual(
                try Data(
                    contentsOf:
                        directory.appendingPathComponent("current-session.json")),
                originalPointer,
                "turn \(turn + 1) rewrote the canonical current-session pointer")

            let requests = dispatcher.requests
            XCTAssertEqual(
                requests[turn].invocation.contractID,
                contract.contractID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                requests[turn].invocation.goalID,
                contract.goalID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                requests[turn].invocation.sessionID,
                sessionID,
                "turn \(turn + 1)")
            XCTAssertEqual(
                requests[turn].exactModelRouteID,
                "gpt-5.6-sol",
                "turn \(turn + 1)")
            XCTAssertEqual(
                requests[turn].exactModelRouteID,
                queuedSnapshot.canonicalModelID,
                "turn \(turn + 1) changed route after leaving the immutable queue snapshot")
            XCTAssertNotEqual(
                requests[turn].exactModelRouteID,
                "grok-build",
                "turn \(turn + 1)")
            XCTAssertEqual(requests[turn].agent, .codex, "turn \(turn + 1)")
            XCTAssertEqual(
                requests[turn].contractMode,
                .xxl,
                "turn \(turn + 1)")
            let remoteRows = model.chatTranscriptJournal
                .orderedItems(
                    threadID: TatwoNativeChatSessionReference(
                        kind: .thread,
                        id: mirroredID
                    ).stableKey)
                .filter { $0.kind == .remoteJob }
            XCTAssertEqual(remoteRows.count, turn + 1, "turn \(turn + 1)")
            XCTAssertTrue(
                remoteRows.allSatisfy {
                    $0.attributes["remotePublicState"] == "已送達"
                },
                "turn \(turn + 1) did not reach the remote accepted terminal boundary")
        }
    }

    @MainActor
    func testOrdinaryCollaborationTurnsReuseAlreadyBoundCanonicalGoalWithoutRemoteArm()
        async throws
    {
        let mirroredID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "ordinary-collaboration-prompts"
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: mirroredID,
                    title: "ordinary collaboration continuity")
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)

        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let goalURL = fixture.goalStore.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
            .appendingPathComponent("\(fixture.contract.contractID).json")
        let originalPointer = try Data(contentsOf: pointerURL)
        let originalGoalData = try Data(contentsOf: goalURL)
        let originalGoalFiles = try goalRunFileNames(in: fixture.goalStore)

        XCTAssertEqual(fixture.model.selectedThreadID, mirroredID)
        XCTAssertTrue(fixture.model.collaborationIsEnabled)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(originalGoalFiles, [
            "\(fixture.contract.contractID).json"
        ])

        // Exercise the ordinary submit path without starting a process or using
        // the remote-compute arm: an already-running turn makes both prompts
        // enter the normal interruption queue after the Work OS continuity gate.
        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        let prompts = [
            "第一個普通 collaboration turn：核對 canonical Goal。",
            "第二個完全不同的普通 prompt：沿用相同 Goal，不得 begin。",
        ]
        for (turn, prompt) in prompts.enumerated() {
            fixture.model.prompt = prompt
            fixture.model.submitCurrentChatTurn()

            XCTAssertEqual(
                fixture.model.queuedChatTurnCount,
                turn + 1,
                "turn \(turn + 1) did not use the ordinary queued Chat path")
            XCTAssertEqual(fixture.model.selectedThreadID, mirroredID)
            XCTAssertEqual(
                fixture.model.selectedThread?.workOSContractID,
                fixture.contract.contractID,
                "turn \(turn + 1) replaced the thread contract")
            XCTAssertEqual(
                fixture.model.selectedThread?.workOSGoalID,
                fixture.contract.goalID,
                "turn \(turn + 1) replaced the thread goal")
            XCTAssertEqual(
                fixture.model.selectedWorkOSContract?.contractID,
                fixture.contract.contractID,
                "turn \(turn + 1) stopped projecting the canonical contract")
            XCTAssertEqual(
                try goalRunFileNames(in: fixture.goalStore),
                originalGoalFiles,
                "turn \(turn + 1) minted another GoalRun")
            XCTAssertEqual(
                try Data(contentsOf: pointerURL),
                originalPointer,
                "turn \(turn + 1) rewrote current-session.json")
            XCTAssertEqual(
                try Data(contentsOf: goalURL),
                originalGoalData,
                "turn \(turn + 1) crossed the begin boundary and rewrote the GoalRun")
        }
    }

    @MainActor
    func testDedicatedNewCollaborationChatAttachesExactCanonicalOwnerBeforeFirstQueuedTurn()
        async throws
    {
        let originalThreadID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "dedicated-new-chat-exact-owner",
            savePointer: false
        ) { contract in
            [
                TatwoNativeChatThread(
                    id: originalThreadID,
                    title: "active collaboration source",
                    loopsConfig: self.loopsConfig(matching: contract))
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)

        let inheritedConfig = try XCTUnwrap(
            fixture.model.selectedThread?.loopsConfig)
        fixture.model.newChat()
        let dedicatedThreadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        XCTAssertNotEqual(dedicatedThreadID, originalThreadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.loopsConfig,
            inheritedConfig)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)

        let sessionStore = TatwoSessionStore(
            directoryURL: fixture.goalStore.directoryURL)
        try sessionStore.writeRawPointerFixtureForTesting(
            nativeChatOwnedPointer(
                contract: fixture.contract,
                threadID: dedicatedThreadID))
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let pointerBefore = try Data(contentsOf: pointerURL)

        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        fixture.model.prompt =
            "dedicated collaboration first turn must bind before acceptance"
        fixture.model.submitCurrentChatTurn()

        XCTAssertEqual(fixture.model.queuedChatTurnCount, 1)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        let attachedConfig = try XCTUnwrap(
            fixture.model.selectedThread?.loopsConfig)
        XCTAssertEqual(attachedConfig.mode, fixture.contract.mode)
        XCTAssertEqual(
            attachedConfig.scenarioID,
            fixture.contract.scenario)
        XCTAssertEqual(
            attachedConfig.primaryModelID,
            fixture.contract.routeBindingOverride?.primaryModelID)
        XCTAssertEqual(
            attachedConfig.secondaryModelID,
            fixture.contract.routeBindingOverride?.secondaryModelID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)

        let persisted = try TatwoNativeChatStore(
            url: fixture.goalStore.directoryURL
                .appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false
        ).load()
        let persistedThread = try XCTUnwrap(
            persisted.threads.first(where: {
                $0.id == dedicatedThreadID
            }))
        XCTAssertEqual(
            persistedThread.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            persistedThread.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(persistedThread.loopsConfig, attachedConfig)
    }

    /// 2026-08-21 使用者裁決推翻舊規格：「每個對話各自一個 Work OS
    /// session」，而且「這種問題根本不該存在」。
    ///
    /// 舊行為：新的協作對話只要 current-session 指標屬於別的 Chat row，
    /// 就整列隔離、送不出訊息——實務上等於「開了第二個 ultrawork 對話
    /// 就被永久鎖死，直到前一個 Goal 結束」，使用者實機撞到。
    ///
    /// 新規格：指標不是我的 → 我就自建自己的 Goal。仍然必須守住的安全
    /// 性質（本測試逐條釘住）：不得竄改別人的指標、不得接手別人的
    /// contract／goalID、不得對別人的 GoalRun 做任何寫入。
    @MainActor
    func testDedicatedNewCollaborationChatMintsItsOwnSessionWhenPointerBelongsToAnotherThread()
        async throws
    {
        // 指標必須屬於一個**真實存在**的別列（這才是使用者實機情境：
        // 前一個對話持有 session）。若指向一個誰都不是的 UUID，那是孤兒
        // 指標＝竄改／損毀，依然必須 fail-closed，由其它測試涵蓋。
        let otherThreadID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "dedicated-new-chat-owner-mismatch",
            savePointer: false
        ) { contract in
            [
                TatwoNativeChatThread(
                    id: otherThreadID,
                    title: "active collaboration source",
                    loopsConfig: self.loopsConfig(matching: contract))
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.newChat()
        let dedicatedThreadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        XCTAssertTrue(fixture.model.collaborationIsEnabled)

        let sessionStore = TatwoSessionStore(
            directoryURL: fixture.goalStore.directoryURL)
        try sessionStore.writeRawPointerFixtureForTesting(
            nativeChatOwnedPointer(
                contract: fixture.contract,
                threadID: otherThreadID))
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let pointerBefore = try Data(contentsOf: pointerURL)

        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        let prompt =
            "another thread owns current-session; this chat mints its own"
        fixture.model.prompt = prompt
        fixture.model.submitCurrentChatTurn()

        // 核心：送得出去，不再被別人的 session 鎖死。
        XCTAssertEqual(fixture.model.selectedThreadID, dedicatedThreadID)
        XCTAssertEqual(
            fixture.model.queuedChatTurnCount, 1,
            "另一列擁有 current-session 不應該讓這一列無法對話")
        XCTAssertTrue(fixture.model.prompt.isEmpty)
        XCTAssertFalse(
            fixture.model.selectedWorkOSStateMessage.contains("已隔離"),
            fixture.model.selectedWorkOSStateMessage)

        // 安全性質一：純聊天回合不會偷接別人的 contract／goal，
        // 也不會擅自建立新的（建 Goal 仍須 /goal、/plg 或明確啟動）。
        XCTAssertNotEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertNotEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)

        // 安全性質二：別人的 current-session 指標一個位元都沒被動過。
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)

        // 安全性質三：沒有多長出 GoalRun 檔案。
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)

        let persisted = try TatwoNativeChatStore(
            url: fixture.goalStore.directoryURL
                .appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false
        ).load()
        let persistedThread = try XCTUnwrap(
            persisted.threads.first(where: {
                $0.id == dedicatedThreadID
            }))
        XCTAssertNotEqual(
            persistedThread.workOSContractID,
            fixture.contract.contractID)
        XCTAssertNotEqual(
            persistedThread.workOSGoalID,
            fixture.contract.goalID)
    }

    @MainActor
    func testDedicatedNewPureChatRemainsUnboundAndUsesOrdinaryQueue()
        async throws
    {
        let fixture = try makeVerifiedSessionFixture(
            "dedicated-new-pure-chat",
            pointer: { contract in
                self.nativeChatOwnedPointer(
                    contract: contract,
                    threadID: UUID())
            }
        ) { _ in
            [TatwoNativeChatThread(title: "pure chat source")]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        fixture.model.newChat()
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let pointerBefore = try Data(contentsOf: pointerURL)

        XCTAssertFalse(fixture.model.collaborationIsEnabled)
        XCTAssertNil(fixture.model.selectedThread?.loopsConfig)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)

        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        fixture.model.prompt = "ordinary pure chat first turn"
        fixture.model.submitCurrentChatTurn()

        XCTAssertEqual(fixture.model.queuedChatTurnCount, 1)
        XCTAssertNil(fixture.model.selectedThread?.loopsConfig)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
    }

    @MainActor
    func testVerifiedCurrentSessionSurvivesRouteSwitchesAndPromptControlWithoutGoalChurn()
        async throws
    {
        let mirroredID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "route-and-prompt-control-continuity"
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: mirroredID,
                    title: "route and prompt-control continuity")
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)

        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let goalURL = fixture.goalStore.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
            .appendingPathComponent("\(fixture.contract.contractID).json")
        let originalPointer = try Data(contentsOf: pointerURL)
        let originalGoalData = try Data(contentsOf: goalURL)
        let originalGoalFiles = try goalRunFileNames(in: fixture.goalStore)
        let originalLoopsConfig = try XCTUnwrap(fixture.model.activeLoopsConfig)
        let alternateTemplate = try XCTUnwrap(
            fixture.model.coworkTemplates.first {
                $0.mode == originalLoopsConfig.mode
                    && $0.scenarioID != originalLoopsConfig.scenarioID
            })

        XCTAssertEqual(fixture.model.selectedThreadID, mirroredID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.goalID,
            fixture.contract.goalID)

        // A stale visual template selection must not replace the already-issued
        // canonical topology when the prompt omits an explicit topology delta.
        fixture.model.selectedCoworkTemplateID = alternateTemplate.id
        let routeSequence = [
            "gpt-5.6-sol",
            "fable5",
            "gpt-5.6-luna",
            "grok-build",
            "opus5",
        ]
        for (turn, routeID) in routeSequence.enumerated() {
            fixture.model.setSingleModel(routeID)

            XCTAssertEqual(
                fixture.model.selectedModel,
                ChatRouteChoice.resolve(routeID).id,
                "route switch \(turn + 1)")
            XCTAssertEqual(
                fixture.model.activeLoopsConfig,
                originalLoopsConfig,
                "route switch \(turn + 1) rewrote Work OS identities")
            XCTAssertEqual(
                fixture.model.selectedThread?.workOSContractID,
                fixture.contract.contractID,
                "route switch \(turn + 1) replaced the thread contract")
            XCTAssertEqual(
                fixture.model.selectedThread?.workOSGoalID,
                fixture.contract.goalID,
                "route switch \(turn + 1) replaced the thread goal")
            XCTAssertEqual(
                fixture.model.selectedWorkOSContract?.contractID,
                fixture.contract.contractID,
                "route switch \(turn + 1) stopped projecting current-session")
            XCTAssertEqual(
                try goalRunFileNames(in: fixture.goalStore),
                originalGoalFiles,
                "route switch \(turn + 1) minted another GoalRun")
            XCTAssertEqual(
                try Data(contentsOf: pointerURL),
                originalPointer,
                "route switch \(turn + 1) rewrote current-session.json")
            XCTAssertEqual(
                try Data(contentsOf: goalURL),
                originalGoalData,
                "route switch \(turn + 1) rewrote the canonical GoalRun")
        }

        fixture.model.isRunning = true
        defer { fixture.model.isRunning = false }
        let prompts = [
            "普通 turn：繼續核對同一個 canonical Goal。",
            "$tatwo-ultrawork 請維持目前協作拓撲；只繼續同一個 Goal。",
        ]
        for (turn, prompt) in prompts.enumerated() {
            fixture.model.prompt = prompt
            fixture.model.submitCurrentChatTurn()

            XCTAssertEqual(
                fixture.model.queuedChatTurnCount,
                turn + 1,
                "prompt turn \(turn + 1) did not enter the ordinary queue")
            XCTAssertEqual(
                fixture.model.activeLoopsConfig,
                originalLoopsConfig,
                "prompt turn \(turn + 1) rebuilt topology from a stale template")
            XCTAssertEqual(
                fixture.model.selectedThread?.workOSContractID,
                fixture.contract.contractID,
                "prompt turn \(turn + 1) replaced the thread contract")
            XCTAssertEqual(
                fixture.model.selectedThread?.workOSGoalID,
                fixture.contract.goalID,
                "prompt turn \(turn + 1) replaced the thread goal")
            XCTAssertEqual(
                fixture.model.selectedWorkOSContract?.contractID,
                fixture.contract.contractID,
                "prompt turn \(turn + 1) stopped projecting current-session")
            XCTAssertEqual(
                fixture.model.selectedWorkOSContract?.goalID,
                fixture.contract.goalID,
                "prompt turn \(turn + 1) stopped projecting the canonical Goal")
            XCTAssertEqual(
                try goalRunFileNames(in: fixture.goalStore),
                originalGoalFiles,
                "prompt turn \(turn + 1) minted another GoalRun")
            XCTAssertEqual(
                try Data(contentsOf: pointerURL),
                originalPointer,
                "prompt turn \(turn + 1) rewrote current-session.json")
            XCTAssertEqual(
                try Data(contentsOf: goalURL),
                originalGoalData,
                "prompt turn \(turn + 1) crossed the begin boundary")
        }
    }

    @MainActor
    func testConflictingTatwoWorkspaceBindingFailsClosedAndKeepsOriginalValues() async throws {
        let mirroredID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "conflicting-binding"
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: mirroredID,
                    title: "conflicting Tatwo workspace row",
                    workOSGoalID: "goal-conflict",
                    workOSContractID: "contract-conflict")
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertFalse(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "must not mint a replacement"))
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            "contract-conflict")
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            "goal-conflict")
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testExistingObjectiveMismatchDoesNotCreateAnotherGoalRun() async throws {
        let fixture = try makeVerifiedSessionFixture(
            "objective-mismatch"
        ) { contract in
            [
                TatwoNativeChatThread(
                    title: "bound local thread",
                    workOSGoalID: contract.goalID,
                    workOSContractID: contract.contractID,
                    selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                        identity: TatwoObjectiveIdentity.make(
                            "different objective identity")))
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertFalse(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: fixture.contract.objective))
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testUnverifiableCurrentSessionPointerBlocksNewGoalForTatwoMirror() async throws {
        let fixture = try makeVerifiedSessionFixture(
            "unverifiable-pointer",
            pointer: { contract in
                TatwoSessionPointer(
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: "tampered current-session objective")
            }
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: UUID(),
                    title: "Tatwo mirror with invalid current-session pointer")
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertFalse(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "must not mint a replacement"))
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testTerminalCurrentSessionPointerIsQuarantinedForTatwoMirror() async throws {
        let fixture = try makeVerifiedSessionFixture(
            "terminal-pointer",
            prepareGoalRun: { goalStore, contract in
                for receipt in contract.receiptRequirements where receipt.requiredForPass {
                    let result = WorkOSFactory.submitReceipt(
                        goalID: contract.goalID,
                        contractID: contract.contractID,
                        loopID: contract.mainlineLoop.id,
                        receiptID: receipt.id,
                        receiptKind: "terminal-chat-session-test",
                        store: goalStore)
                    XCTAssertTrue(result.ok, result.decision.message)
                }
                let registry = TatwoDispatchRegistry(directoryURL: goalStore.directoryURL)
                try WorkOSFactory.finalizeSuccessfulDispatchFixtureForTesting(
                    contract: contract, store: goalStore, registry: registry)
                let closed = try WorkOSFactory.closeGoal(
                    goalID: contract.goalID,
                    contractID: contract.contractID,
                    mode: contract.mode,
                    scenarioProfileID: contract.scenario,
                    objective: contract.objective,
                    suppliedReceiptIDs: [],
                    store: goalStore,
                    dispatchRegistry: registry)
                XCTAssertEqual(closed.status, .passed)
            }
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: UUID(),
                    title: "Tatwo mirror with terminal current-session pointer")
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(fixture.contract.contractID).status,
            .passed)
        XCTAssertFalse(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "must not revive a terminal GoalRun"))
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testColdStartAcceptsMatchingLegacyActivePLGProjectionAndRejectsMismatchedProjection()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-native-route-materialization-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let scenarioID =
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID: scenarioID,
            objective:
                "preserve running native development Goal while canonical route is materialized",
            store: goalStore)
        let threadID = UUID()
        try TatwoSessionStore(directoryURL: directory)
            .writeRawPointerFixtureForTesting(
                nativeChatOwnedPointer(
                    contract: contract,
                    threadID: threadID))

        let issued = try XCTUnwrap(
            try goalStore.requireIssuedContract(contract.contractID)
                .issuedIdentityBindings)
        let legacyNativeToolBridgeSourceSlots: Set<String> = [
            TatwoNativeDevelopmentDispatchCoordinator
                .solExecutorSourceSlotID,
            TatwoNativeDevelopmentDispatchCoordinator
                .opusSupervisorSourceSlotID,
        ]
        let legacyIssued = issued.map { binding in
            guard legacyNativeToolBridgeSourceSlots.contains(
                binding.sourceSlotID)
            else { return binding }
            return TatwoIssuedIdentityBindingV1(
                id: binding.id,
                sourceSlotID: binding.sourceSlotID,
                identity: binding.identity,
                modelID: binding.modelID,
                authority: .brainOnly,
                engineID: binding.engineID,
                reasoningEffort: binding.reasoningEffort,
                canMutateHost: false)
        }
        let originalRecord = try goalStore.requireIssuedContract(
            contract.contractID)
        let running = TatwoStoredGoalRun(
            schema: originalRecord.schema,
            goalID: originalRecord.goalID,
            contractID: originalRecord.contractID,
            mode: originalRecord.mode,
            scenario: originalRecord.scenario,
            objective: originalRecord.objective,
            routeBindingOverride: originalRecord.routeBindingOverride,
            issuedIdentityBindings: legacyIssued,
            issuedIdentityBindingsDigest:
                TatwoIssuedIdentityBindingV1.deterministicDigest(
                    for: legacyIssued),
            status: .running,
            statusReason:
                "dispatch_registry_begin_ack:canonical-route-materialization",
            latestDispatchCycleEpoch:
                originalRecord.latestDispatchCycleEpoch,
            latestDispatchCycleSealID:
                originalRecord.latestDispatchCycleSealID,
            // This fixture exercises the grandfathered pre-cutoff contract,
            // not a newly issued contract that must match strictly.
            issuedAt: Date(timeIntervalSince1970: 1_785_427_200),
            updatedAt: Date(),
            receipts: originalRecord.receipts,
            recoversGoalID: originalRecord.recoversGoalID,
            recoversContractID: originalRecord.recoversContractID,
            recoveryReceiptHash: originalRecord.recoveryReceiptHash,
            recoveryAuthorizationHash:
                originalRecord.recoveryAuthorizationHash,
            recoveryReason: originalRecord.recoveryReason,
            recoveryAdjudicationRef:
                originalRecord.recoveryAdjudicationRef,
            revision: originalRecord.revision,
            predecessorContractID:
                originalRecord.predecessorContractID,
            predecessorGoalID: originalRecord.predecessorGoalID,
            successorContractID:
                originalRecord.successorContractID,
            successorGoalID: originalRecord.successorGoalID,
            supersession: originalRecord.supersession)
        try writeGoalRecord(running, to: goalStore)

        let identitySummary =
            "Plan:主導=gpt-5.6-sol；Loops:執行手=gpt-5.6-sol；Loops:副審=opus-5；Loops:驗收=opus-5"
        let tokenBudget =
            "XXL 原生開發：Sol High 與 Opus 5 High，只使用 TATWO 原生 runtime。"
        let legacyLoopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID: scenarioID,
            mode: .xxl,
            identitySummary: identitySummary,
            tokenBudget: tokenBudget,
            primaryModelID: nil,
            secondaryModelID: nil)
        let desiredLoopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID: scenarioID,
            mode: .xxl,
            identitySummary: identitySummary,
            tokenBudget: tokenBudget,
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: "opus-5")
        let intentStore = WorkOSBindingMutationIntentStore(
            fileURL: directory.appendingPathComponent(
                "work-os-binding-mutation-intent-v1.json"))
        let intent = WorkOSBindingMutationIntentV1(
            threadID: threadID,
            projectID: nil,
            oldContractID: contract.contractID,
            oldGoalID: contract.goalID,
            desiredLoopsConfig: desiredLoopsConfig)
        try intentStore.create(intent)
        let invalidation =
            TatwoNativeThreadBindingInvalidationV1(
                id: intent.id,
                reason: .loopsConfigChanged,
                threadID: threadID,
                projectID: nil,
                previousBinding:
                    TatwoNativeThreadBindingIdentityV1(
                        contractID: contract.contractID,
                        goalID: contract.goalID,
                        goalRevision: running.resolvedRevision),
                previousLoopsConfig: legacyLoopsConfig,
                desiredLoopsConfig: desiredLoopsConfig,
                authorityProvenance:
                    TatwoNativeThreadBindingAuthorityProvenanceV1(
                        provider: "tatwo-chat",
                        externalProviderSessionID:
                            threadID.uuidString.lowercased(),
                        workspacePath:
                            TatwoRuntimeLayout.applicationSupportRoot()
                                .appendingPathComponent(
                                    "chat-workspace",
                                    isDirectory: true)
                                .standardizedFileURL.path))
        let legacyProjectionBindings = contract.identityBindings.map {
            binding in
            guard legacyNativeToolBridgeSourceSlots.contains(
                binding.sourceSlotID)
            else { return binding }
            return WorkOSIdentityBinding(
                id: binding.id,
                identity: binding.identity,
                label: binding.label,
                engineID: binding.engineID,
                modelID: binding.modelID,
                authority: .brainOnly,
                canMutateHost: false,
                sourceSlotID: binding.sourceSlotID,
                bindingRule:
                    "Loop Governor 依 Dashboard Scenario Config 啟用；固定啟用。")
        }
        let activePLGRunProjection = TatwoPLGRun(
            goalID: contract.goalID,
            contractID: contract.contractID,
            revision: Int(running.resolvedRevision),
            phase: .leadAdversarial,
            leadBindings: legacyProjectionBindings.filter {
                $0.identity == .lead
            },
            subBindings: legacyProjectionBindings.filter {
                $0.identity != .lead
            },
            planSummary: contract.objective,
            adversarialConclusion: nil,
            humanAuth: nil,
            branchGoals: [],
            mainlineGoalMet: nil)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(
                threads: [
                    TatwoNativeChatThread(
                        id: threadID,
                        title: "running native development Goal",
                        loopsConfig: legacyLoopsConfig,
                        workOSGoalID: contract.goalID,
                        workOSContractID: contract.contractID,
                        selectedThreadWorkOSContext:
                            TatwoStoredObjectiveContextV2(
                                identity:
                                    TatwoObjectiveIdentity.make(
                                        contract.objective)),
                        bindingInvalidation: invalidation,
                        activePLGRunProjection:
                            activePLGRunProjection)
                ]))

        let model = makeModel(
            store: nativeStore,
            goalStore: goalStore,
            directory: directory)
        try await waitForInitialStoreLoad(model)

        let recovered = try XCTUnwrap(
            model.document.threads.first(where: {
                $0.id == threadID
            }))
        XCTAssertEqual(recovered.loopsConfig, legacyLoopsConfig)
        XCTAssertEqual(
            recovered.workOSContractID,
            contract.contractID)
        XCTAssertEqual(recovered.workOSGoalID, contract.goalID)
        XCTAssertEqual(
            recovered.activePLGRunProjection,
            activePLGRunProjection)
        XCTAssertNil(recovered.bindingInvalidation)
        XCTAssertNil(try intentStore.load())
        XCTAssertEqual(
            try goalStore.requireIssuedContract(
                contract.contractID).status,
            .running)
        XCTAssertFalse(
            model.selectedWorkOSStateMessage.contains("隔離"),
            model.selectedWorkOSStateMessage)

        let mismatchedIntent = WorkOSBindingMutationIntentV1(
            threadID: threadID,
            projectID: nil,
            oldContractID: contract.contractID,
            oldGoalID: contract.goalID,
            desiredLoopsConfig: desiredLoopsConfig)
        try intentStore.create(mismatchedIntent)
        let mismatchedInvalidation =
            TatwoNativeThreadBindingInvalidationV1(
                id: mismatchedIntent.id,
                reason: .loopsConfigChanged,
                threadID: threadID,
                projectID: nil,
                previousBinding:
                    TatwoNativeThreadBindingIdentityV1(
                        contractID: contract.contractID,
                        goalID: contract.goalID,
                        goalRevision: running.resolvedRevision),
                previousLoopsConfig: legacyLoopsConfig,
                desiredLoopsConfig: desiredLoopsConfig,
                authorityProvenance:
                    TatwoNativeThreadBindingAuthorityProvenanceV1(
                        provider: "tatwo-chat",
                        externalProviderSessionID:
                            threadID.uuidString.lowercased(),
                        workspacePath:
                            TatwoRuntimeLayout.applicationSupportRoot()
                                .appendingPathComponent(
                                    "chat-workspace",
                                    isDirectory: true)
                                .standardizedFileURL.path))
        var mismatchedProjection = activePLGRunProjection
        let originalBinding = try XCTUnwrap(
            mismatchedProjection.subBindings.first)
        mismatchedProjection.subBindings[0] = WorkOSIdentityBinding(
            id: originalBinding.id,
            identity: originalBinding.identity,
            label: originalBinding.label,
            engineID: originalBinding.engineID,
            modelID: "sonnet-5",
            authority: originalBinding.authority,
            canMutateHost: originalBinding.canMutateHost,
            sourceSlotID: originalBinding.sourceSlotID,
            bindingRule: originalBinding.bindingRule)
        var mismatchedThread = recovered
        mismatchedThread.bindingInvalidation = mismatchedInvalidation
        mismatchedThread.activePLGRunProjection = mismatchedProjection
        mismatchedThread.updatedAt = Date()
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [mismatchedThread]))

        let quarantinedModel = makeModel(
            store: nativeStore,
            goalStore: goalStore,
            directory: directory)
        try await waitForInitialStoreLoad(quarantinedModel)

        XCTAssertNotNil(
            quarantinedModel.document.threads.first?
                .bindingInvalidation)
        XCTAssertNotNil(try intentStore.load())
        XCTAssertTrue(
            quarantinedModel.selectedWorkOSStateMessage
                .contains("隔離"),
            quarantinedModel.selectedWorkOSStateMessage)
    }

    @MainActor
    func testColdStartCompletesDurableSupersessionIntentAfterCancelCrash()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-supersession-intent-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "durable supersession crash recovery",
            store: goalStore)
        let projectID = UUID()
        let threadID = UUID()
        let unrelatedID = UUID()
        let workspacePath = directory
            .appendingPathComponent("project-workspace", isDirectory: true)
            .standardizedFileURL.path
        try TatwoSessionStore(directoryURL: directory).writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective
            ).owned(
                provider: "codex",
                sessionID: threadID.uuidString.lowercased(),
                workspacePath: workspacePath))
        var cancelled = try goalStore.requireIssuedContract(contract.contractID)
        cancelled.status = .cancelled
        cancelled.statusReason = "superseded_before_dispatch"
        cancelled.updatedAt = Date()
        try writeGoalRecord(cancelled, to: goalStore)

        let desiredLoopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID: "coding",
            mode: .l,
            identitySummary: "desired post-crash config",
            tokenBudget: "durable intent",
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: nil)
        let unrelatedContractID = "contract-unrelated-preserved"
        let unrelatedGoalID = "goal-unrelated-preserved"
        let unrelatedContext = TatwoStoredObjectiveContextV2(
            identity: TatwoObjectiveIdentity.make("unrelated objective"))
        try nativeStore.save(
            TatwoNativeChatStoreDocument(
                projects: [
                    TatwoNativeChatProject(
                        id: projectID,
                        name: "Supersession recovery",
                        workdir: workspacePath,
                        threads: [
                            TatwoNativeChatThread(
                                id: threadID,
                                title: "exact crashed row",
                                codexSessionID: threadID.uuidString.lowercased(),
                                mirroredCodexWorkspacePath: workspacePath,
                                sourceMarker:
                                    TatwoNativeChatThreadSourceMarker
                                        .codexAppMirror,
                                loopsConfig: loopsConfig(matching: contract),
                                workOSGoalID: contract.goalID,
                                workOSContractID: contract.contractID,
                                selectedThreadWorkOSContext:
                                    TatwoStoredObjectiveContextV2(
                                        identity: TatwoObjectiveIdentity.make(
                                            contract.objective))),
                            TatwoNativeChatThread(
                                id: unrelatedID,
                                title: "unrelated row",
                                codexSessionID:
                                    unrelatedID.uuidString.lowercased(),
                                mirroredCodexWorkspacePath: workspacePath,
                                sourceMarker:
                                    TatwoNativeChatThreadSourceMarker
                                        .codexAppMirror,
                                workOSGoalID: unrelatedGoalID,
                                workOSContractID: unrelatedContractID,
                                selectedThreadWorkOSContext:
                                    unrelatedContext),
                        ])
                ]))
        let intentStore = WorkOSBindingMutationIntentStore(
            fileURL: directory.appendingPathComponent(
                "work-os-binding-mutation-intent-v1.json"))
        let intent = WorkOSBindingMutationIntentV1(
            threadID: threadID,
            projectID: projectID,
            oldContractID: contract.contractID,
            oldGoalID: contract.goalID,
            desiredLoopsConfig: desiredLoopsConfig)
        try intentStore.create(intent)

        let model = makeModel(
            store: nativeStore,
            goalStore: goalStore,
            directory: directory)
        try await waitForInitialStoreLoad(model)

        let recovered = try XCTUnwrap(
            model.document.projects.first(where: { $0.id == projectID })?
                .threads.first(where: { $0.id == threadID }))
        XCTAssertEqual(recovered.loopsConfig, desiredLoopsConfig)
        XCTAssertNil(recovered.workOSContractID)
        XCTAssertNil(recovered.workOSGoalID)
        XCTAssertNil(recovered.selectedThreadWorkOSContext)
        XCTAssertNil(recovered.activePLGRunProjection)
        let recoveredInvalidation = try XCTUnwrap(
            recovered.bindingInvalidation)
        XCTAssertEqual(recoveredInvalidation.id, intent.id)
        XCTAssertEqual(
            recoveredInvalidation.reason,
            .loopsConfigChanged)
        XCTAssertEqual(recoveredInvalidation.threadID, threadID)
        XCTAssertEqual(recoveredInvalidation.projectID, projectID)
        XCTAssertEqual(
            recoveredInvalidation.previousBinding.contractID,
            contract.contractID)
        XCTAssertEqual(
            recoveredInvalidation.previousBinding.goalID,
            contract.goalID)
        XCTAssertEqual(
            recoveredInvalidation.desiredLoopsConfigSHA256,
            TatwoNativeThreadBindingInvalidationV1
                .loopsConfigSHA256(desiredLoopsConfig))
        let unrelated = try XCTUnwrap(
            model.document.projects.first(where: { $0.id == projectID })?
                .threads.first(where: { $0.id == unrelatedID }))
        XCTAssertEqual(unrelated.workOSContractID, unrelatedContractID)
        XCTAssertEqual(unrelated.workOSGoalID, unrelatedGoalID)
        XCTAssertEqual(unrelated.selectedThreadWorkOSContext, unrelatedContext)
        XCTAssertNil(try TatwoSessionStore(directoryURL: directory).current())
        XCTAssertNil(try intentStore.load())

        let persistedAfterFirstLaunch = try nativeStore.load()
        let secondModel = makeModel(
            store: nativeStore,
            goalStore: goalStore,
            directory: directory)
        try await waitForInitialStoreLoad(secondModel)
        XCTAssertEqual(try nativeStore.load(), persistedAfterFirstLaunch)
        XCTAssertNil(try intentStore.load())
        XCTAssertNil(try TatwoSessionStore(directoryURL: directory).current())
    }

    @MainActor
    func testColdStartClearsDurableIntentAfterSameEpisodeLoopsRetarget()
        async throws
    {
        let fixture = try makeRetargetedBindingMutationRecoveryFixture(
            suffix: "same-episode",
            mismatch: .none)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await waitForInitialStoreLoad(fixture.model)

        let recovered = try XCTUnwrap(
            fixture.model.document.threads.first(where: {
                $0.id == fixture.threadID
            }))
        XCTAssertEqual(recovered.loopsConfig, fixture.retargetedLoopsConfig)
        XCTAssertNil(recovered.workOSContractID)
        XCTAssertNil(recovered.workOSGoalID)
        XCTAssertNil(recovered.selectedThreadWorkOSContext)
        XCTAssertNil(recovered.activePLGRunProjection)
        XCTAssertEqual(
            recovered.bindingInvalidation?.id,
            fixture.intent.id)
        XCTAssertEqual(
            recovered.bindingInvalidation?.desiredLoopsConfigSHA256,
            TatwoNativeThreadBindingInvalidationV1
                .loopsConfigSHA256(fixture.retargetedLoopsConfig))
        XCTAssertFalse(
            fixture.model.selectedWorkOSStateMessage.contains("隔離"),
            fixture.model.selectedWorkOSStateMessage)
        XCTAssertNil(try fixture.intentStore.load())
        XCTAssertNil(try fixture.sessionStore.current())

        let persisted = try fixture.store.load()
        XCTAssertEqual(
            persisted.threads.first(where: {
                $0.id == fixture.threadID
            })?.loopsConfig,
            fixture.retargetedLoopsConfig)
    }

    @MainActor
    func testColdStartKeepsDurableIntentForWrongRetargetEpisode()
        async throws
    {
        let fixture = try makeRetargetedBindingMutationRecoveryFixture(
            suffix: "wrong-episode",
            mismatch: .wrongEpisodeID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await waitForInitialStoreLoad(fixture.model)

        let quarantined = try XCTUnwrap(
            fixture.model.document.threads.first(where: {
                $0.id == fixture.threadID
            }))
        XCTAssertEqual(
            quarantined.loopsConfig,
            fixture.retargetedLoopsConfig)
        XCTAssertNotEqual(
            quarantined.bindingInvalidation?.id,
            fixture.intent.id)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains("隔離"),
            fixture.model.selectedWorkOSStateMessage)
        XCTAssertEqual(try fixture.intentStore.load(), fixture.intent)
        XCTAssertNotNil(try fixture.sessionStore.current())
    }

    @MainActor
    func testColdStartQuarantinesRetargetedIntentWithWrongReason()
        async throws
    {
        try await assertRetargetedBindingMutationMismatch(
            .wrongReason,
            suffix: "wrong-reason")
    }

    @MainActor
    func testColdStartQuarantinesRetargetedIntentWithWrongPreviousRevision()
        async throws
    {
        try await assertRetargetedBindingMutationMismatch(
            .wrongPreviousRevision,
            suffix: "wrong-previous-revision")
    }

    @MainActor
    func testColdStartQuarantinesRetargetedIntentWithUnexpectedSuccessor()
        async throws
    {
        try await assertRetargetedBindingMutationMismatch(
            .unexpectedSuccessor,
            suffix: "unexpected-successor")
    }

    @MainActor
    func testColdStartQuarantinesRetargetedIntentWithWrongProvenance()
        async throws
    {
        try await assertRetargetedBindingMutationMismatch(
            .wrongProvenance,
            suffix: "wrong-provenance")
    }

    @MainActor
    func testColdStartQuarantinesRetargetedIntentWithWrongThread()
        async throws
    {
        try await assertRetargetedBindingMutationMismatch(
            .wrongThread,
            suffix: "wrong-thread")
    }

    @MainActor
    func testColdStartQuarantinesRetargetedIntentWithWrongProject()
        async throws
    {
        try await assertRetargetedBindingMutationMismatch(
            .wrongProject,
            suffix: "wrong-project")
    }

    @MainActor
    func testRetargetedPickerImmediatelyClearsExactDurableIntent()
        async throws
    {
        let fixture = try makeRetargetedBindingMutationRecoveryFixture(
            suffix: "immediate-finish",
            mismatch: .none,
            persistedAsRetargeted: false,
            createsIntentBeforeModel: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await waitForInitialStoreLoad(fixture.model)
        try fixture.intentStore.create(fixture.intent)
        let pointerBefore = try XCTUnwrap(
            fixture.sessionStore.current())
        let originalInvalidation = try XCTUnwrap(
            fixture.model.selectedThread?.bindingInvalidation)
        XCTAssertEqual(
            fixture.model.activeLoopsConfig,
            fixture.firstDesiredLoopsConfig)

        fixture.model.setPrimaryModel("claude-opus-5")

        let retargeted = try XCTUnwrap(fixture.model.selectedThread)
        XCTAssertNotEqual(
            retargeted.loopsConfig,
            fixture.firstDesiredLoopsConfig)
        XCTAssertEqual(
            retargeted.bindingInvalidation?.id,
            originalInvalidation.id)
        XCTAssertEqual(
            retargeted.bindingInvalidation?.desiredLoopsConfigSHA256,
            TatwoNativeThreadBindingInvalidationV1
                .loopsConfigSHA256(retargeted.loopsConfig))
        XCTAssertNil(try fixture.intentStore.load())
        let pointerAfter = try XCTUnwrap(
            fixture.sessionStore.current())
        XCTAssertEqual(pointerAfter.contractID, pointerBefore.contractID)
        XCTAssertEqual(pointerAfter.goalID, pointerBefore.goalID)
        XCTAssertFalse(
            fixture.model.selectedWorkOSStateMessage.contains(
                "durable mutation intent 尚未完成清理"),
            fixture.model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testExplicitActivationReclaimsExactTerminalPointerAndMintsNewGoal()
        async throws
    {
        let threadID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "explicit-terminal-pointer-recovery",
            prepareGoalRun: { goalStore, contract in
                for receipt in contract.receiptRequirements where receipt.requiredForPass {
                    let result = WorkOSFactory.submitReceipt(
                        goalID: contract.goalID,
                        contractID: contract.contractID,
                        loopID: contract.mainlineLoop.id,
                        receiptID: receipt.id,
                        receiptKind: "explicit-terminal-recovery-test",
                        store: goalStore)
                    XCTAssertTrue(result.ok, result.decision.message)
                }
                let registry = TatwoDispatchRegistry(directoryURL: goalStore.directoryURL)
                try WorkOSFactory.finalizeSuccessfulDispatchFixtureForTesting(
                    contract: contract, store: goalStore, registry: registry)
                let closed = try WorkOSFactory.closeGoal(
                    goalID: contract.goalID,
                    contractID: contract.contractID,
                    mode: contract.mode,
                    scenarioProfileID: contract.scenario,
                    objective: contract.objective,
                    suppliedReceiptIDs: [],
                    store: goalStore,
                    dispatchRegistry: registry)
                XCTAssertEqual(closed.status, .passed)
            }
        ) { contract in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: threadID,
                    title: "explicit terminal pointer recovery",
                    workOSGoalID: contract.goalID,
                    workOSContractID: contract.contractID,
                    selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                        identity: TatwoObjectiveIdentity.make(contract.objective)))
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        let terminalContractID = fixture.contract.contractID
        let terminalGoalID = fixture.contract.goalID

        try await confirmAuthorityBootstrapAndEnsure(
            fixture.model,
            objectiveHint: "explicitly start a new Goal after terminal recovery")

        let replacement = try XCTUnwrap(
            fixture.model.selectedWorkOSContract)
        XCTAssertNotEqual(replacement.contractID, terminalContractID)
        XCTAssertNotEqual(replacement.goalID, terminalGoalID)
        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(
                terminalContractID).status,
            .passed)
        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(
                replacement.contractID).status,
            .planned)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            replacement.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            replacement.goalID)
        let current = try XCTUnwrap(
            TatwoSessionStore(
                directoryURL: fixture.goalStore.directoryURL).current())
        XCTAssertEqual(current.contractID, replacement.contractID)
        XCTAssertEqual(current.goalID, replacement.goalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 2)
    }

    @MainActor
    func testExplicitActivationNeverReclaimsSucceededPointerAwaitingGoalJudge()
        async throws
    {
        let threadID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "explicit-succeeded-pointer-preserved",
            prepareGoalRun: { goalStore, contract in
                var record = try goalStore.requireIssuedContract(
                    contract.contractID)
                record.status = .succeeded
                record.statusReason =
                    "dispatch_set_finalized:1:dispatch-seal-explicit-succeeded"
                record.updatedAt = Date()
                try self.writeGoalRecord(record, to: goalStore)
            }
        ) { contract in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: threadID,
                    title: "succeeded pointer awaits Goal Judge",
                    loopsConfig: self.loopsConfig(matching: contract),
                    workOSGoalID: contract.goalID,
                    workOSContractID: contract.contractID,
                    selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                        identity: TatwoObjectiveIdentity.make(contract.objective)))
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let pointerBefore = try Data(contentsOf: pointerURL)
        let attachedThread = try XCTUnwrap(fixture.model.selectedThread)
        let attachedContext = fixture.model.selectedThreadWorkOSContext(
            thread: attachedThread,
            objectiveHint: "must keep awaiting Goal Judge")
        let attachedRouteOverride = WorkOSRouteBindingOverride(
            primaryModelID: attachedThread.loopsConfig?.primaryModelID,
            secondaryModelID: attachedThread.loopsConfig?.secondaryModelID)
        XCTAssertEqual(attachedThread.workOSContractID, fixture.contract.contractID)
        XCTAssertEqual(attachedThread.workOSGoalID, fixture.contract.goalID)
        XCTAssertTrue(
            attachedThread.selectedThreadWorkOSContext?.matches(
                TatwoObjectiveIdentity.make(fixture.contract.objective)) == true)
        XCTAssertEqual(attachedContext.mode, fixture.contract.mode)
        XCTAssertEqual(attachedContext.scenario, fixture.contract.scenario)
        XCTAssertEqual(
            attachedRouteOverride.isEmpty ? nil : attachedRouteOverride,
            fixture.contract.routeBindingOverride)

        XCTAssertTrue(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "must keep awaiting Goal Judge",
                allowCreateIfUnbound: true),
            fixture.model.selectedWorkOSStateMessage)

        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.goalID,
            fixture.contract.goalID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(
            try fixture.goalStore.requireIssuedContract(
                fixture.contract.contractID).status,
            .succeeded)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testCurrentSessionPointerCreatedMidSessionAttachesWithoutMintingGoal() async throws {
        let mirroredID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "pointer-created-mid-session",
            savePointer: false
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: mirroredID,
                    title: "Tatwo mirror waiting for current-session pointer")
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)

        try TatwoSessionStore(directoryURL: fixture.goalStore.directoryURL).writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: fixture.contract.contractID,
                goalID: fixture.contract.goalID,
                mode: fixture.contract.mode,
                scenario: fixture.contract.scenario,
                objective: fixture.contract.objective))

        XCTAssertTrue(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: fixture.contract.objective))
        XCTAssertEqual(fixture.model.selectedThreadID, mirroredID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testLaterTatwoWorkspaceSelectionUsesVerifiedBundleWithoutNewContract() async throws {
        let fixture = try makeVerifiedSessionFixture(
            "later-selection"
        ) { _ in
            [TatwoNativeChatThread(title: "ordinary local chat")]
        }
        try await waitForInitialStoreLoad(fixture.model)
        let mirroredID = UUID()
        fixture.model.document.threads.append(
            tatwoWorkspaceMirrorThread(
                id: mirroredID,
                title: "later mirrored workspace"))

        fixture.model.selectStandaloneThread(mirroredID)

        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.contract.goalID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testVerifiedPointerCannotAttachToSecondThread() async throws {
        let firstID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "single-pointer-owner"
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: firstID,
                    title: "first workspace row")
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.contract.contractID)

        let secondID = UUID()
        fixture.model.document.threads.append(
            tatwoWorkspaceMirrorThread(
                id: secondID,
                title: "second workspace row",
                updatedAt: Date(timeIntervalSince1970: 900)))
        fixture.model.selectStandaloneThread(secondID)

        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)
        XCTAssertFalse(fixture.model.ensureSelectedThreadWorkOSContract())
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testMultipleUnboundTatwoWorkspaceMirrorsDoNotGuessCurrentSessionOwner() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "ambiguous-workspace-rows"
        ) { _ in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: firstID,
                    title: "first unbound workspace row",
                    updatedAt: Date(timeIntervalSince1970: 100)),
                self.tatwoWorkspaceMirrorThread(
                    id: secondID,
                    title: "second unbound workspace row",
                    updatedAt: Date(timeIntervalSince1970: 900))
            ]
        }
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertNil(
            fixture.model.document.threads.first(where: { $0.id == firstID })?
                .workOSContractID)
        XCTAssertNil(
            fixture.model.document.threads.first(where: { $0.id == secondID })?
                .workOSContractID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertFalse(fixture.model.ensureSelectedThreadWorkOSContract())
        XCTAssertNil(fixture.model.selectedThread?.workOSContractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    func testGoalWithoutRestorablePlanFailsClosedInsteadOfStartingAnotherRun() throws {
        let source = try chatPageSource
        let goalSection = try XCTUnwrap(
            source.slice(
                from: "func commitPLGGoalFromPrompt()",
                through: "func triggerDistillFromPrompt()"))

        XCTAssertTrue(goalSection.contains("restoreActivePLGProjection(from: selectedThread)"))
        XCTAssertTrue(goalSection.contains("找不到可延續的同 thread Plan"))
        XCTAssertFalse(goalSection.contains("if activePLGRun == nil"))
        XCTAssertFalse(goalSection.contains("startPLGRun"))
    }

    func testPlanAndGoalTurnsCannotResetTheirActiveContractFromPromptKeywords() throws {
        let source = try chatPageSource
        let planSection = try XCTUnwrap(
            source.slice(
                from: "func triggerPLGFromPrompt()",
                through: "func startPLGRun(objective: String)"))
        let goalSection = try XCTUnwrap(
            source.slice(
                from: "func commitPLGGoalFromPrompt()",
                through: "func triggerDistillFromPrompt()"))
        let submitSection = try XCTUnwrap(
            source.slice(
                from: "func submitCurrentChatTurn",
                through: "struct PromptCollaborationIntent"))

        XCTAssertTrue(planSection.contains("submitCurrentChatTurn(applyPromptCollaboration: false)"))
        XCTAssertTrue(goalSection.contains("submitCurrentChatTurn(applyPromptCollaboration: false)"))
        XCTAssertTrue(submitSection.contains("applyPromptCollaboration: Bool = false"))
        XCTAssertTrue(submitSection.contains("if applyPromptCollaboration"))
    }

    func testBlockedTerminalRuntimeFailureUsesTypedIdempotentSignalWithoutUnlockingRunnerAuthority()
        throws
    {
        let source = try chatPageSource
        let reconciler = try XCTUnwrap(
            source.slice(
                from: "func startRunnerStateReconciler(",
                through: "private func presentBlockedCancellation("))
        let handle = try XCTUnwrap(
            source.slice(
                from: "private func handle(_ event: ChatCLIEvent, runID: String)",
                through:
                    "func consumeBlockedTerminalFailureSignal("))
        let consumer = try XCTUnwrap(
            source.slice(
                from:
                    "func consumeBlockedTerminalFailureSignal(",
                through: "private func formalRunnerStatus(runID: String)"))
        let formalReconciliation = try XCTUnwrap(
            source.slice(
                from: "private func reconcileInactiveRunner(",
                through: "func applyCoworkTemplate("))

        XCTAssertTrue(
            reconciler.contains(
                "diagnostics.blockedTerminalFailureSignal"))
        XCTAssertTrue(
            reconciler.contains(
                "consumeBlockedTerminalFailureSignal("))
        XCTAssertTrue(
            reconciler.contains(
                "lifecycle.assistantID == assistantID"))
        XCTAssertFalse(
            reconciler.contains(
                "self.activeAssistantID == assistantID"))
        XCTAssertTrue(
            reconciler.contains(
                "snapshot?.formalExitStatus != nil"))
        XCTAssertTrue(
            reconciler.contains(
                "} else {\n                        switch diagnostics.cancellationConvergenceState"))
        XCTAssertTrue(
            handle.contains(
                "case .runtimeFailure(let message):"))
        XCTAssertTrue(
            handle.contains(
                "if consumeBlockedTerminalFailureSignal("))

        XCTAssertTrue(
            consumer.contains(
                "signal.runID == runID"))
        XCTAssertTrue(
            consumer.contains(
                "eventMessage == signal.message"))
        XCTAssertTrue(
            consumer.contains(
                "signal.authorityRemainsBlocked"))
        XCTAssertTrue(consumer.contains("!signal.reclaimAllowed"))
        XCTAssertTrue(
            consumer.contains(
                "consumedBlockedTerminalFailureIdempotencyKeys.contains("))
        XCTAssertTrue(
            consumer.contains(
                "consumedBlockedTerminalFailureIdempotencyKeys.insert("))
        XCTAssertTrue(
            consumer.contains(
                "commitTranscriptTerminalMessage(terminalMessage)"))
        XCTAssertTrue(consumer.contains("isRunning = true"))

        let commit = try XCTUnwrap(
            consumer.range(
                of:
                    "commitTranscriptTerminalMessage(terminalMessage)")?
                .lowerBound)
        let markConsumed = try XCTUnwrap(
            consumer.range(
                of:
                    "consumedBlockedTerminalFailureIdempotencyKeys.insert(")?
                .lowerBound)
        XCTAssertLessThan(commit, markConsumed)

        XCTAssertFalse(
            consumer.contains(
                "resolveDurableCancellationAfterFormalTerminal()"))
        XCTAssertFalse(
            consumer.contains(
                "acceptFormalTerminalEvent("))
        XCTAssertFalse(
            consumer.contains(
                "activeTurnLifecycle = nil"))
        XCTAssertFalse(consumer.contains("startNextChatIfNeeded()"))

        XCTAssertTrue(
            formalReconciliation.contains(
                "lifecycle.assistantID == assistantID"))
        XCTAssertTrue(
            formalReconciliation.contains(
                "blockedTerminalFailureAlreadyPublished"))
        XCTAssertTrue(
            formalReconciliation.contains(
                "consumedBlockedTerminalFailureIdempotencyKeys"))
        XCTAssertTrue(
            formalReconciliation.contains(
                "guard acceptFormalTerminalEvent("))
        XCTAssertTrue(
            formalReconciliation.contains(
                "finishBlockedTerminalFailureAfterFormalConvergence("))
        XCTAssertTrue(
            formalReconciliation.contains(
                "resolveDurableCancellationAfterFormalTerminal()"))
        XCTAssertTrue(
            formalReconciliation.contains(
                "activeTurnLifecycle = nil"))
        XCTAssertTrue(
            formalReconciliation.contains(
                "startNextChatIfNeeded()"))
    }

    func testRepeatedPlanInSameThreadReusesTheRestoredPlanningRun() throws {
        let source = try chatPageSource
        let planSection = try XCTUnwrap(
            source.slice(
                from: "func triggerPLGFromPrompt()",
                through: "func startPLGRun(objective: String)"))

        XCTAssertTrue(planSection.contains("restoreActivePLGProjection(from: selectedThread)"))
        XCTAssertFalse(planSection.contains("if activePLGRun == nil"))
        XCTAssertTrue(planSection.contains("run.phase == .planning"))
        XCTAssertTrue(planSection.contains("沿用同一個 Plan"))
        XCTAssertTrue(planSection.contains("此 thread 已離開 planning"))
    }

    @MainActor
    func testNewLoopGoalInheritanceUsesRecordThenContractThenPLGThenThreadFallback() async throws {
        let fixture = makeModelFixture("loop-goal-precedence")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID: "general-xxl-fable5-sol",
            objective: "Contract objective source",
            store: fixture.goalStore)
        let goalRecord = TatwoStoredGoalRun(
            goalID: contract.goalID,
            contractID: contract.contractID,
            mode: contract.mode,
            scenario: contract.scenario,
            objective: "Goal record objective source",
            routeBindingOverride: contract.routeBindingOverride,
            status: .planned)
        let plg = TatwoPLGRunFactory.make(
            objective: "PLG plan source",
            contractID: contract.contractID,
            goalID: contract.goalID,
            leadModelIDs: ["gpt-5.6-sol"],
            subModelIDs: ["gpt-5.6-luna"],
            nowISO: "2026-08-02T00:00:00Z")

        model.selectedGoalRecord = goalRecord
        model.selectedWorkOSContract = contract
        model.activePLGRun = plg
        let recordLoopID = try XCTUnwrap(
            model.createLoopsSessionForSelectedThread())
        XCTAssertEqual(
            try loopSession(recordLoopID, in: model).plg.goal,
            goalRecord.objective)

        model.selectedGoalRecord = nil
        let contractLoopID = try XCTUnwrap(
            model.createLoopsSessionForSelectedThread())
        XCTAssertEqual(
            try loopSession(contractLoopID, in: model).plg.goal,
            contract.objective)

        model.selectedWorkOSContract = nil
        let plgLoopID = try XCTUnwrap(
            model.createLoopsSessionForSelectedThread())
        XCTAssertEqual(
            try loopSession(plgLoopID, in: model).plg.goal,
            plg.planSummary)

        model.activePLGRun = nil
        let thread = try XCTUnwrap(model.selectedThread)
        let threadFallback = model.selectedThreadWorkOSContext(
            thread: thread).objective
        let fallbackLoopID = try XCTUnwrap(
            model.createLoopsSessionForSelectedThread())
        XCTAssertEqual(
            try loopSession(fallbackLoopID, in: model).plg.goal,
            threadFallback)
    }

    @MainActor
    func testDispatchLoopSubKeepsActiveContractObjectiveAndStoresSubGoalAsPlanSlice() async throws {
        let nativeRunner = ChatPlanGoalRecordingNativeRunner()
        let fixture = makeModelFixture(
            "dispatch-plan-slice",
            nativeRunner: nativeRunner)
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        let preparedNativeScenario =
            await model.prepareNativeDevelopmentScenarioForPLGIfNeeded(
                objective:
                    "請使用 read_file、git_diff、run_command 實際修改並驗證 Swift 程式碼。")
        XCTAssertTrue(preparedNativeScenario)
        try await confirmAuthorityBootstrapAndEnsure(
            model,
            objectiveHint: "Canonical active Goal objective")
        let originalContract = try XCTUnwrap(model.selectedWorkOSContract)
        let originalGoalRecord = try XCTUnwrap(model.selectedGoalRecord)
        let loopID = try XCTUnwrap(
            model.createLoopsSessionForSelectedThread())
        let subPlanSlice = "Only inspect the compact Loops row; never replace the active Goal"
        model.mutateLoopsSession(loopID) { session in
            session.plg = TatwoLoopsPLG(
                plan: "Bounded UI inspection",
                loops: session.plg.loops,
                goal: subPlanSlice)
        }
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)

        model.dispatchLoopSub(loopID)
        XCTAssertEqual(
            model.dispatchingLoopID,
            loopID,
            "按下後必須先投影 pending，不能等 ledger I/O 結束才顯示")

        model.dispatchLoopSub(loopID)
        XCTAssertEqual(
            model.dispatchingLoopID,
            loopID,
            "pending 期間的第二次點擊必須沿用同一 logical dispatch")

        try await waitUntil {
            nativeRunner.startCount == 1
                && model.dispatchingLoopID == nil
        }

        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            originalContract.contractID)
        XCTAssertEqual(
            model.selectedGoalRecord?.contractID,
            originalGoalRecord.contractID)
        XCTAssertEqual(
            model.selectedWorkOSContract?.objective,
            originalContract.objective)
        XCTAssertEqual(model.activePLGRun?.contractID, originalContract.contractID)
        XCTAssertEqual(model.activePLGRun?.goalID, originalContract.goalID)
        XCTAssertEqual(model.activePLGRun?.planSummary, originalContract.objective)
        XCTAssertEqual(nativeRunner.startCount, 1)
        XCTAssertTrue(model.isRunning)
        XCTAssertNotNil(model.activeNativeDevelopmentDispatch)
        XCTAssertTrue(
            model.selectedDispatchRecords.contains(where: {
                $0.contractID == originalContract.contractID
                    && $0.status == .running
            }))
        let updatedLoop = try loopSession(loopID, in: model)
        let dispatchMessage = try XCTUnwrap(
            updatedLoop.messages.last(where: { $0.role == "system" }))
        XCTAssertTrue(
            dispatchMessage.text.contains(
                "Work OS 已接受此 Plan slice；runner 已進入 running。"))
        XCTAssertFalse(
            dispatchMessage.text.contains(subPlanSlice),
            "runtime 狀態列不得重複灌入長 plan slice")
    }

    @MainActor
    func testDispatchLoopSubFailsClosedWhenThreadChangesBeforeDeferredDispatch()
        async throws
    {
        let nativeRunner = ChatPlanGoalRecordingNativeRunner()
        let fixture = makeModelFixture(
            "dispatch-stale-thread",
            nativeRunner: nativeRunner)
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        model.setCollaborationLevel(.xxl)
        try await confirmAuthorityBootstrapAndEnsure(
            model,
            objectiveHint: "Do not dispatch after the selected thread changes")
        let loopID = try XCTUnwrap(
            model.createLoopsSessionForSelectedThread())

        model.dispatchLoopSub(loopID)
        XCTAssertEqual(model.dispatchingLoopID, loopID)
        model.newChat()

        try await waitUntil {
            model.dispatchingLoopID == nil
        }
        XCTAssertEqual(nativeRunner.startCount, 0)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(
            model.composerHint?.contains(
                "thread／session 已切換") == true)
    }

    @MainActor
    func testDispatchLoopSubShowsFailureAndSettlesLedgerWhenRunnerCannotStart()
        async throws
    {
        let fixture = makeModelFixture(
            "dispatch-runner-rejected",
            nativeRunner: ChatPlanGoalRejectingNativeRunner())
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        let preparedNativeScenario =
            await model.prepareNativeDevelopmentScenarioForPLGIfNeeded(
                objective:
                    "請使用 read_file、git_diff、run_command 實際修改並驗證 Swift 程式碼。")
        XCTAssertTrue(preparedNativeScenario)
        try await confirmAuthorityBootstrapAndEnsure(
            model,
            objectiveHint: "Fail visibly when the canonical runner cannot start")
        let contractID = try XCTUnwrap(
            model.selectedWorkOSContract?.contractID)
        let loopID = try XCTUnwrap(
            model.createLoopsSessionForSelectedThread())

        model.dispatchLoopSub(loopID)
        try await waitUntil {
            model.dispatchingLoopID == nil
        }

        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.pendingNativeDevelopmentDispatch)
        XCTAssertNil(model.activeNativeDevelopmentDispatch)
        XCTAssertTrue(
            model.composerHint?.contains(
                "dispatch 已標記失敗") == true,
            model.composerHint ?? "")
        XCTAssertTrue(
            model.selectedDispatchRecords.contains(where: {
                $0.contractID == contractID
                    && $0.status == .failed
            }))
    }

    @MainActor
    func testSameThreadUIOnlyLoopsConfigRefreshPreservesCanonicalGoalBinding() async throws {
        let fixture = makeModelFixture("ui-only-loops-refresh")
        let model = fixture.model
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil { model.newChat() }
        model.setCollaborationLevel(.xxl)
        try await confirmAuthorityBootstrapAndEnsure(
            model,
            objectiveHint: "Preserve this same-thread Goal")
        let originalContract = try XCTUnwrap(model.selectedWorkOSContract)
        let originalGoal = try XCTUnwrap(model.selectedGoalRecord)
        let location = try XCTUnwrap(model.selectedThreadLocation())
        var thread = model.thread(at: location)
        var stalePresentation = try XCTUnwrap(thread.loopsConfig)
        stalePresentation.identitySummary = "stale UI summary"
        stalePresentation.tokenBudget = "stale ephemeral budget label"
        thread.loopsConfig = stalePresentation
        model.replaceThread(thread, at: location)

        model.setLoopsMode(stalePresentation.mode)

        XCTAssertEqual(
            model.selectedThread?.workOSContractID,
            originalContract.contractID)
        XCTAssertEqual(
            model.selectedThread?.workOSGoalID,
            originalGoal.goalID)
        XCTAssertEqual(
            model.selectedWorkOSContract?.contractID,
            originalContract.contractID)
        XCTAssertEqual(
            model.selectedGoalRecord?.contractID,
            originalGoal.contractID)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains("contract 保留"),
            model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testSelectedWorkOSStateUsesInjectedGoalStoreDispatchRegistryRoot() async throws {
        var expectedDispatchID: String?
        let fixture = try makeVerifiedSessionFixture(
            "dispatch-root",
            prepareGoalRun: { goalStore, contract in
                let binding = try XCTUnwrap(contract.identityBindings.first)
                let record = try TatwoDispatchRegistry(
                    directoryURL: goalStore.directoryURL
                ).begin(
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    bindingID: binding.id,
                    sourceSlotID: binding.sourceSlotID,
                    identity: binding.identity,
                    modelID: binding.modelID ?? "gpt-5.6-sol",
                    subtask: "prove selected state uses injected canonical root"
                )
                expectedDispatchID = record.id
            },
            threads: { contract in
                [
                    self.tatwoWorkspaceMirrorThread(
                        id: UUID(),
                        title: "dispatch root mirror",
                        workOSGoalID: contract.goalID,
                        workOSContractID: contract.contractID,
                        selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                            identity: TatwoObjectiveIdentity.make(contract.objective))
                    )
                ]
            }
        )
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertEqual(
            fixture.model.selectedDispatchRecords.map(\.id),
            [try XCTUnwrap(expectedDispatchID)]
        )
        XCTAssertEqual(
            fixture.model.dispatchRegistry.directoryURL.standardizedFileURL,
            fixture.goalStore.directoryURL.standardizedFileURL
        )
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            fixture.contract.contractID
        )
    }

    @MainActor
    func testSameWindowRefreshProjectsExternalSucceededGoalAsTerminalFiveOfFive()
        async throws
    {
        let threadID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "external-succeeded-refresh"
        ) { contract in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: threadID,
                    title: "external succeeded projection",
                    workOSGoalID: contract.goalID,
                    workOSContractID: contract.contractID,
                    selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                        identity: TatwoObjectiveIdentity.make(contract.objective)))
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        let pointerURL = fixture.goalStore.directoryURL
            .appendingPathComponent("current-session.json")
        let pointerBefore = try Data(contentsOf: pointerURL)
        let selectedThreadBefore = try XCTUnwrap(fixture.model.selectedThread)
        let receiptCountBefore = fixture.model.activeGoalReceiptCount

        _ = try fixture.goalStore.updateStatus(
            contractID: fixture.contract.contractID,
            status: .dispatching)
        _ = try fixture.goalStore.updateStatus(
            contractID: fixture.contract.contractID,
            status: .running,
            authority: .ledgerBeginAck,
            reason: "external projection fixture running",
            evidence: .ledger(dispatchID: "dispatch-external-refresh"))
        _ = try fixture.goalStore.appendReceipt(
            contractID: fixture.contract.contractID,
            receiptID: "external-refresh-receipt",
            kind: "external_refresh_test",
            loopID: fixture.contract.mainlineLoop.id)
        var finalized = try fixture.goalStore.finalizeDispatchSet(
            contractID: fixture.contract.contractID,
            sealID: "dispatch-seal-external-refresh",
            recordCount: 1)
        XCTAssertEqual(finalized.status, .awaitingNextCycle)
        finalized.status = .succeeded
        finalized.updatedAt = Date()
        try writeGoalRecord(finalized, to: fixture.goalStore)

        fixture.model.refreshSelectedWorkOSStateForExternalChanges(force: true)
        try await waitUntil {
            fixture.model.selectedGoalRecord?.status == .succeeded
        }

        XCTAssertEqual(fixture.model.selectedThreadID, threadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            selectedThreadBefore.workOSContractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            selectedThreadBefore.workOSGoalID)
        XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
        XCTAssertEqual(
            fixture.model.activeGoalReceiptCount,
            receiptCountBefore + 1)
        XCTAssertEqual(
            fixture.model.activeGoalStatusPresentationLabel,
            "執行完成，等待驗收")
        XCTAssertEqual(
            fixture.model.activeGoalStepProgress.current,
            fixture.model.activeGoalStepProgress.total - 1)
        XCTAssertEqual(fixture.model.activeGoalStepProgress.current, 4)
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    func testRefreshQuarantinesGoalRevisionChangedDuringDispatchRead() async throws {
        let threadID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "refresh-revision-change"
        ) { contract in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: threadID,
                    title: "revision consistency gate",
                    workOSGoalID: contract.goalID,
                    workOSContractID: contract.contractID,
                    selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                        identity: TatwoObjectiveIdentity.make(contract.objective)))
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        let goalStore = fixture.goalStore
        let contract = fixture.contract

        fixture.model.refreshSelectedWorkOSState(
            contractID: contract.contractID,
            afterDispatchRead: { _ in
                _ = try! goalStore.appendReceipt(
                    contractID: contract.contractID,
                    receiptID: "intervening-refresh-revision",
                    kind: "revision-consistency-test",
                    loopID: contract.mainlineLoop.id)
            })
        try await waitUntil {
            fixture.model.selectedWorkOSStateMessage.contains(
                "GoalRun revision")
        }

        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedGoalRecord)
        XCTAssertTrue(fixture.model.selectedDispatchRecords.isEmpty)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "未套用混合狀態"),
            fixture.model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testNewRefreshGenerationPreventsOlderRevisionFailureFromApplying()
        async throws
    {
        let threadID = UUID()
        let fixture = try makeVerifiedSessionFixture(
            "refresh-generation"
        ) { contract in
            [
                self.tatwoWorkspaceMirrorThread(
                    id: threadID,
                    title: "latest refresh generation wins",
                    workOSGoalID: contract.goalID,
                    workOSContractID: contract.contractID,
                    selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                        identity: TatwoObjectiveIdentity.make(contract.objective)))
            ]
        }
        defer {
            try? FileManager.default.removeItem(
                at: fixture.goalStore.directoryURL)
        }
        try await waitForInitialStoreLoad(fixture.model)
        let goalStore = fixture.goalStore
        let contract = fixture.contract
        _ = try goalStore.updateStatus(
            contractID: contract.contractID,
            status: .dispatching)

        let firstDispatchRead = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        fixture.model.refreshSelectedWorkOSState(
            contractID: contract.contractID,
            afterDispatchRead: { _ in
                firstDispatchRead.signal()
                releaseFirstLoad.wait()
            })
        defer { releaseFirstLoad.signal() }
        let firstLoadReachedBarrier = await withCheckedContinuation {
            continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: firstDispatchRead.wait(
                        timeout: .now() + 2) == .success)
            }
        }
        XCTAssertTrue(firstLoadReachedBarrier)

        _ = try goalStore.updateStatus(
            contractID: contract.contractID,
            status: .running,
            authority: .ledgerBeginAck,
            reason: "new refresh generation",
            evidence: .ledger(dispatchID: "dispatch-refresh-generation"))
        fixture.model.refreshSelectedWorkOSState(
            contractID: contract.contractID)
        try await waitUntil {
            fixture.model.selectedGoalRecord?.status == .running
        }

        releaseFirstLoad.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.model.selectedGoalRecord?.status, .running)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.goalRun.status,
            .running)
        XCTAssertFalse(
            fixture.model.selectedWorkOSStateMessage.contains(
                "GoalRun revision"),
            fixture.model.selectedWorkOSStateMessage)
    }

    @MainActor
    func testUnreadableDispatchRegistryQuarantinesSelectedWorkOSState() async throws {
        let fixture = try makeVerifiedSessionFixture(
            "dispatch-corruption",
            prepareGoalRun: { goalStore, contract in
                let dispatchDirectory = goalStore.directoryURL.appendingPathComponent(
                    "dispatches",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: dispatchDirectory,
                    withIntermediateDirectories: true
                )
                try Data("{not-json".utf8).write(
                    to: dispatchDirectory.appendingPathComponent(
                        "\(contract.contractID).json",
                        isDirectory: false
                    ),
                    options: [.atomic]
                )
            },
            threads: { contract in
                [
                    self.tatwoWorkspaceMirrorThread(
                        id: UUID(),
                        title: "corrupt dispatch mirror",
                        workOSGoalID: contract.goalID,
                        workOSContractID: contract.contractID,
                        selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                            identity: TatwoObjectiveIdentity.make(contract.objective))
                    )
                ]
            }
        )
        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedGoalRecord)
        XCTAssertTrue(fixture.model.selectedDispatchRecords.isEmpty)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "dispatch ledger 無法驗證"),
            fixture.model.selectedWorkOSStateMessage
        )
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "未以空清單取代"),
            fixture.model.selectedWorkOSStateMessage
        )
        XCTAssertEqual(try goalRunFileCount(in: fixture.goalStore), 1)
    }

    @MainActor
    private func makeModelFixture(
        _ suffix: String,
        nativeRunner: (any ChatNativeAgentRunning)? = nil
    ) -> (model: ChatPageModel, goalStore: TatwoGoalRunStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-plan-continuity-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory),
            nativeRunner: nativeRunner)
        return (model, goalStore)
    }

    @MainActor
    private func makeModel(
        store: TatwoNativeChatStore,
        goalStore: TatwoGoalRunStore,
        directory: URL
    ) -> ChatPageModel {
        ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory))
    }

    private struct RetargetedBindingMutationRecoveryFixture {
        let directory: URL
        let store: TatwoNativeChatStore
        let model: ChatPageModel
        let sessionStore: TatwoSessionStore
        let intentStore: WorkOSBindingMutationIntentStore
        let intent: WorkOSBindingMutationIntentV1
        let threadID: UUID
        let firstDesiredLoopsConfig: TatwoNativeThreadLoopsConfig
        let retargetedLoopsConfig: TatwoNativeThreadLoopsConfig
        let persistedDocument: TatwoNativeChatStoreDocument
    }

    private enum RetargetedBindingMutationMismatch: Equatable {
        case none
        case wrongEpisodeID
        case wrongReason
        case wrongPreviousRevision
        case unexpectedSuccessor
        case wrongProvenance
        case wrongThread
        case wrongProject
    }

    @MainActor
    private func assertRetargetedBindingMutationMismatch(
        _ mismatch: RetargetedBindingMutationMismatch,
        suffix: String
    ) async throws {
        let fixture = try makeRetargetedBindingMutationRecoveryFixture(
            suffix: suffix,
            mismatch: mismatch)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pointerBefore = try XCTUnwrap(
            fixture.sessionStore.current())

        try await waitForInitialStoreLoad(fixture.model)

        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains("隔離"),
            fixture.model.selectedWorkOSStateMessage)
        XCTAssertFalse(
            fixture.model.ensureSelectedThreadWorkOSContract(
                objectiveHint: "wrong episode must remain blocked",
                allowCreateIfUnbound: true))
        XCTAssertEqual(try fixture.intentStore.load(), fixture.intent)
        let expectedRow = try XCTUnwrap(
            fixture.persistedDocument.threads.first(where: {
                $0.id == fixture.threadID
            }))
        let persistedRow = try XCTUnwrap(
            try fixture.store.load().threads.first(where: {
                $0.id == fixture.threadID
            }))
        XCTAssertEqual(persistedRow.loopsConfig, expectedRow.loopsConfig)
        XCTAssertEqual(
            persistedRow.bindingInvalidation,
            expectedRow.bindingInvalidation)
        XCTAssertEqual(
            persistedRow.workOSContractID,
            expectedRow.workOSContractID)
        XCTAssertEqual(
            persistedRow.workOSGoalID,
            expectedRow.workOSGoalID)
        XCTAssertEqual(
            persistedRow.selectedThreadWorkOSContext,
            expectedRow.selectedThreadWorkOSContext)
        XCTAssertEqual(
            persistedRow.activePLGRunProjection,
            expectedRow.activePLGRunProjection)
        let pointerAfter = try XCTUnwrap(
            fixture.sessionStore.current())
        XCTAssertEqual(pointerAfter.contractID, pointerBefore.contractID)
        XCTAssertEqual(pointerAfter.goalID, pointerBefore.goalID)
    }

    @MainActor
    private func makeRetargetedBindingMutationRecoveryFixture(
        suffix: String,
        mismatch: RetargetedBindingMutationMismatch,
        persistedAsRetargeted: Bool = true,
        createsIntentBeforeModel: Bool = true
    ) throws -> RetargetedBindingMutationRecoveryFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-retargeted-intent-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
        let store = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let sessionStore = TatwoSessionStore(directoryURL: directory)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "retargeted durable mutation intent \(suffix)",
            store: goalStore)
        let threadID = UUID()
        let intentThreadID =
            mismatch == .wrongThread ? UUID() : threadID
        let intentProjectID =
            mismatch == .wrongProject ? UUID() : nil
        let sessionID = threadID.uuidString.lowercased()
        let workspacePath = TatwoRuntimeLayout.applicationSupportRoot()
            .appendingPathComponent(
                "chat-workspace",
                isDirectory: true)
            .standardizedFileURL.path
        try sessionStore.writeRawPointerFixtureForTesting(
            TatwoSessionPointer(
                contractID: contract.contractID,
                goalID: contract.goalID,
                mode: contract.mode,
                scenario: contract.scenario,
                objective: contract.objective)
            .owned(
                provider: "codex",
                sessionID: sessionID,
                workspacePath: workspacePath))
        var cancelled = try goalStore.requireIssuedContract(
            contract.contractID)
        cancelled.status = .cancelled
        cancelled.statusReason = "superseded_before_dispatch"
        cancelled.updatedAt = Date()
        try writeGoalRecord(cancelled, to: goalStore)

        let firstDesiredLoopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID: "coding",
            mode: .l,
            identitySummary: "first picker mutation",
            tokenBudget: "intent-a",
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: nil)
        let retargetedLoopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID: "research",
            mode: .xxl,
            identitySummary: "second picker mutation",
            tokenBudget: "retarget-b",
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: "claude-opus-5")
        let intentStore = WorkOSBindingMutationIntentStore(
            fileURL: directory.appendingPathComponent(
                "work-os-binding-mutation-intent-v1.json"))
        let intent = WorkOSBindingMutationIntentV1(
            threadID: intentThreadID,
            projectID: intentProjectID,
            oldContractID: contract.contractID,
            oldGoalID: contract.goalID,
            desiredLoopsConfig: firstDesiredLoopsConfig,
            createdAt: Date(timeIntervalSince1970: 1_800_001_000))
        if createsIntentBeforeModel {
            try intentStore.create(intent)
        }
        let persistedLoopsConfig = persistedAsRetargeted
            ? retargetedLoopsConfig
            : firstDesiredLoopsConfig
        let expectedSuccessor:
            TatwoNativeThreadBindingIdentityV1? =
                mismatch == .unexpectedSuccessor
                ? TatwoNativeThreadBindingIdentityV1(
                    contractID: "unexpected-successor-contract",
                    goalID: "unexpected-successor-goal",
                    goalRevision: 1)
                : nil
        let invalidation = TatwoNativeThreadBindingInvalidationV1(
            id: mismatch == .wrongEpisodeID ? UUID() : intent.id,
            reason: mismatch == .wrongReason
                ? .contractSuperseded
                : .loopsConfigChanged,
            threadID: intentThreadID,
            projectID: intentProjectID,
            previousBinding: TatwoNativeThreadBindingIdentityV1(
                contractID: contract.contractID,
                goalID: contract.goalID,
                goalRevision: mismatch == .wrongPreviousRevision
                    ? cancelled.resolvedRevision + 1
                    : cancelled.resolvedRevision),
            previousLoopsConfig: loopsConfig(matching: contract),
            desiredLoopsConfig: persistedLoopsConfig,
            expectedSuccessor: expectedSuccessor,
            authorityProvenance:
                TatwoNativeThreadBindingAuthorityProvenanceV1(
                    provider: "codex",
                    externalProviderSessionID:
                        mismatch == .wrongProvenance
                        ? sessionID + "-wrong"
                        : sessionID,
                    workspacePath: workspacePath),
            createdAt: Date(timeIntervalSince1970: 1_800_001_001))
        let persistedDocument = TatwoNativeChatStoreDocument(
            threads: [
                TatwoNativeChatThread(
                    id: threadID,
                    title: "retargeted durable binding row",
                    codexSessionID: sessionID,
                    mirroredCodexWorkspacePath: workspacePath,
                    sourceMarker:
                        TatwoNativeChatThreadSourceMarker.codexAppMirror,
                    loopsConfig: persistedLoopsConfig,
                    bindingInvalidation: invalidation)
            ])
        try store.save(persistedDocument)
        return RetargetedBindingMutationRecoveryFixture(
            directory: directory,
            store: store,
            model: makeModel(
                store: store,
                goalStore: goalStore,
                directory: directory),
            sessionStore: sessionStore,
            intentStore: intentStore,
            intent: intent,
            threadID: threadID,
            firstDesiredLoopsConfig: firstDesiredLoopsConfig,
            retargetedLoopsConfig: retargetedLoopsConfig,
            persistedDocument: persistedDocument)
    }

    @MainActor
    private func waitForInitialStoreLoad(_ model: ChatPageModel) async throws {
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 300,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for completed-turn GoalRun continuity")
    }

    @MainActor
    private func confirmAuthorityBootstrapAndEnsure(
        _ model: ChatPageModel,
        objectiveHint: String
    ) async throws {
        XCTAssertFalse(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: objectiveHint,
                allowCreateIfUnbound: true),
            "first formal activation must stage the AppShell authority bootstrap")
        XCTAssertNotNil(model.authorityBootstrapModel.pendingProposal)
        await model.authorityBootstrapModel.confirmPending()
        XCTAssertNil(
            model.authorityBootstrapModel.errorMessage,
            model.authorityBootstrapModel.errorMessage ?? "")
        XCTAssertTrue(
            model.ensureSelectedThreadWorkOSContract(
                objectiveHint: objectiveHint,
                allowCreateIfUnbound: true),
            model.selectedWorkOSStateMessage)
    }

    @MainActor
    private func loopSession(
        _ id: UUID,
        in model: ChatPageModel
    ) throws -> TatwoLoopsSession {
        let session = model.selectedThreadLoopsSessions.first(where: { $0.id == id })
        return try XCTUnwrap(session)
    }

    private func goalRunFileCount(in store: TatwoGoalRunStore) throws -> Int {
        try goalRunFileNames(in: store).count
    }

    private func goalRunFileNames(in store: TatwoGoalRunStore) throws -> [String] {
        let goals = store.directoryURL.appendingPathComponent("goals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: goals.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: goals,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map(\.lastPathComponent)
        .sorted()
    }

    private func writeGoalRecord(
        _ record: TatwoStoredGoalRun,
        to store: TatwoGoalRunStore
    ) throws {
        let url = try store.fileURL(forContractID: record.contractID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: [.atomic])
    }

    private func tatwoWorkspaceMirrorThread(
        id: UUID,
        title: String,
        updatedAt: Date = Date(),
        loopsConfig: TatwoNativeThreadLoopsConfig? = nil,
        workOSGoalID: String? = nil,
        workOSContractID: String? = nil,
        selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2? = nil
    ) -> TatwoNativeChatThread {
        TatwoNativeChatThread(
            id: id,
            title: title,
            codexSessionID: id.uuidString.lowercased(),
            mirroredCodexWorkspacePath: TatwoRuntimeLayout.applicationSupportRoot()
                .appendingPathComponent("chat-workspace", isDirectory: true)
                .standardizedFileURL.path,
            sourceMarker: TatwoNativeChatThreadSourceMarker.codexAppMirror,
            updatedAt: updatedAt,
            loopsConfig: loopsConfig,
            workOSGoalID: workOSGoalID,
            workOSContractID: workOSContractID,
            selectedThreadWorkOSContext: selectedThreadWorkOSContext)
    }

    private func nativeChatOwnedPointer(
        contract: TatwoWorkOSContractV1,
        threadID: UUID
    ) -> TatwoSessionPointer {
        TatwoSessionPointer(
            contractID: contract.contractID,
            goalID: contract.goalID,
            mode: contract.mode,
            scenario: contract.scenario,
            objective: contract.objective
        ).owned(
            provider: "tatwo-chat",
            sessionID: threadID.uuidString.lowercased(),
            workspacePath: TatwoRuntimeLayout.applicationSupportRoot()
                .appendingPathComponent(
                    "chat-workspace",
                    isDirectory: true)
                .standardizedFileURL.path)
    }

    @MainActor
    private func makeVerifiedProjectSessionFixture(
        _ suffix: String,
        sessionUUID: UUID = UUID(),
        scenarioProfileID: String = "coding",
        savePointer: Bool = true,
        pointer: (
            TatwoWorkOSContractV1,
            String,
            String
        ) -> TatwoSessionPointer,
        projects: ((
            TatwoWorkOSContractV1,
            String,
            String
        ) -> [TatwoNativeChatProject])? = nil
    ) throws -> (
        model: ChatPageModel,
        goalStore: TatwoGoalRunStore,
        contract: TatwoWorkOSContractV1,
        projectID: UUID,
        threadID: UUID
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-project-owner-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
        let workspacePath = directory
            .appendingPathComponent("project-workspace", isDirectory: true)
            .standardizedFileURL.path
        let sessionID = sessionUUID.uuidString.lowercased()
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .xxl,
            scenarioProfileID: scenarioProfileID,
            objective: "Verified project owner \(suffix)",
            store: goalStore)
        if savePointer {
            try TatwoSessionStore(directoryURL: directory).writeRawPointerFixtureForTesting(
                pointer(contract, sessionID, workspacePath))
        }

        let projectRows: [TatwoNativeChatProject]
        if let projects {
            projectRows = projects(contract, sessionID, workspacePath)
        } else {
            projectRows = [
                TatwoNativeChatProject(
                    name: "Verified project owner",
                    workdir: workspacePath,
                    threads: [
                        TatwoNativeChatThread(
                            id: sessionUUID,
                            title: "Verified project mirror",
                            codexSessionID: sessionID,
                            mirroredCodexWorkspacePath: workspacePath,
                            sourceMarker:
                                TatwoNativeChatThreadSourceMarker
                                    .codexAppMirror,
                            loopsConfig: loopsConfig(matching: contract))
                    ])
            ]
        }
        try nativeStore.save(
            TatwoNativeChatStoreDocument(projects: projectRows))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory))
        let firstProject = try XCTUnwrap(projectRows.first)
        let firstThread = try XCTUnwrap(firstProject.threads.first)
        return (
            model,
            goalStore,
            contract,
            firstProject.id,
            firstThread.id)
    }

    // BEGIN TEMPORARY WAVE 1 LIVE-CLONE DRY-RUN HARNESS
    @MainActor
    func testWave1LiveSnapshotCloneColdStartPersistAndJournalOnlyFallback()
        async throws
    {
        guard
            let snapshotRootPath =
                ProcessInfo.processInfo.environment["TATWO_LIVE_CLONE_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !snapshotRootPath.isEmpty
        else {
            throw XCTSkip(
                "Temporary live-clone harness requires TATWO_LIVE_CLONE_ROOT; "
                    + "the ordinary full suite must not read private snapshots.")
        }
        let snapshotRoot = URL(
            fileURLWithPath: snapshotRootPath,
            isDirectory: true)
        let sourceTatwo = snapshotRoot.appendingPathComponent(
            "executable/tatwo",
            isDirectory: true)
        let sourceCodex = snapshotRoot.appendingPathComponent(
            "executable/codex",
            isDirectory: true)
        let sourceRepairs = snapshotRoot.appendingPathComponent(
            "source-raw/tatwo/chat-repair-backups",
            isDirectory: true)
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-wave1-live-clone-\(UUID().uuidString)",
                isDirectory: true)
        let fullRoot = runRoot.appendingPathComponent(
            "full-mirror",
            isDirectory: true)
        let journalOnlyRoot = runRoot.appendingPathComponent(
            "journal-only",
            isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fullRoot,
            withIntermediateDirectories: true)

        func copy(_ source: URL, to destination: URL) throws {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        }
        func runSQLite(
            databaseURL: URL,
            command: String,
            readOnly: Bool = true
        ) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            let databaseArgument =
                readOnly
                ? databaseURL.standardizedFileURL.absoluteString
                    + "?mode=ro&immutable=1"
                : databaseURL.path
            process.arguments = [
                "-noheader",
                databaseArgument,
                command,
            ]
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "TatwoWave1LiveCloneSQLite",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            String(data: errorData, encoding: .utf8)
                            ?? "sqlite3 failed without stderr"
                    ])
            }
            return String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func sha256(_ fileURL: URL) throws -> String {
            SHA256.hash(
                data: try Data(
                    contentsOf: fileURL,
                    options: [.mappedIfSafe])
            )
            .map { String(format: "%02x", $0) }
            .joined()
        }
        struct FileFingerprint: Equatable {
            let isPresent: Bool
            let sha256: String?
        }
        func fingerprint(_ fileURL: URL) throws -> FileFingerprint {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return FileFingerprint(isPresent: false, sha256: nil)
            }
            return FileFingerprint(
                isPresent: true,
                sha256: try sha256(fileURL))
        }
        func sqliteSourceFingerprints(
            _ source: URL
        ) throws -> [String: FileFingerprint] {
            [
                "db": try fingerprint(source),
                "wal": try fingerprint(
                    URL(fileURLWithPath: source.path + "-wal")),
                "shm": try fingerprint(
                    URL(fileURLWithPath: source.path + "-shm")),
            ]
        }
        func sqliteBackup(_ source: URL, to destination: URL) throws {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let sourceBefore = try sqliteSourceFingerprints(source)
            let escapedDestination = destination.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            _ = try runSQLite(
                databaseURL: source,
                command: ".backup \"\(escapedDestination)\"")
            let sourceAfter = try sqliteSourceFingerprints(source)
            for artifact in ["db", "wal", "shm"] {
                XCTAssertEqual(
                    sourceAfter[artifact],
                    sourceBefore[artifact],
                    "SQLite backup changed source \(artifact) "
                        + "presence or SHA-256 digest")
            }
            XCTAssertEqual(
                try runSQLite(
                    databaseURL: destination,
                    command: """
                    PRAGMA locking_mode=EXCLUSIVE;
                    PRAGMA wal_checkpoint(TRUNCATE);
                    PRAGMA journal_mode=DELETE;
                    """,
                    readOnly: false),
                "exclusive\n0|0|0\ndelete")
            XCTAssertEqual(
                try runSQLite(
                    databaseURL: destination,
                    command: "PRAGMA quick_check;"),
                "ok")
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: destination.path + "-wal"))
            XCTAssertFalse(
                fileManager.fileExists(
                    atPath: destination.path + "-shm"))
        }
        func allThreads(
            _ document: TatwoNativeChatStoreDocument
        ) -> [TatwoNativeChatThread] {
            document.threads + document.projects.flatMap(\.threads)
        }
        func sortedThreads(
            _ document: TatwoNativeChatStoreDocument
        ) -> [TatwoNativeChatThread] {
            allThreads(document).sorted {
                $0.id.uuidString < $1.id.uuidString
            }
        }
        func assertStableRows(
            _ actual: TatwoNativeChatStoreDocument,
            equalTo expected: TatwoNativeChatStoreDocument,
            compareMessages: Bool = true,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let actualByID = Dictionary(
                uniqueKeysWithValues: allThreads(actual).map { ($0.id, $0) })
            let expectedByID = Dictionary(
                uniqueKeysWithValues: allThreads(expected).map { ($0.id, $0) })
            let actualIDs = Set(actualByID.keys)
            let expectedIDs = Set(expectedByID.keys)
            let addedIDs = actualIDs.subtracting(expectedIDs)
                .map { $0.uuidString.lowercased() }
                .sorted()
            let removedIDs = expectedIDs.subtracting(actualIDs)
                .map { $0.uuidString.lowercased() }
                .sorted()
            XCTAssertTrue(
                actualIDs == expectedIDs,
                "stable row IDs changed; added=\(addedIDs) "
                    + "removed=\(removedIDs)",
                file: file,
                line: line)
            for (id, expectedRow) in expectedByID {
                let actualRow = actualByID[id]
                XCTAssertEqual(
                    actualRow?.title,
                    expectedRow.title,
                    file: file,
                    line: line)
                XCTAssertEqual(
                    actualRow?.lastPreview,
                    expectedRow.lastPreview,
                    file: file,
                    line: line)
                XCTAssertEqual(
                    actualRow?.codexSessionID,
                    expectedRow.codexSessionID,
                    file: file,
                    line: line)
                XCTAssertEqual(
                    actualRow?.mirroredCodexWorkspacePath,
                    expectedRow.mirroredCodexWorkspacePath,
                    file: file,
                    line: line)
                XCTAssertEqual(
                    actualRow?.sourceMarker,
                    expectedRow.sourceMarker,
                    file: file,
                    line: line)
                XCTAssertEqual(
                    actualRow?.workOSGoalID,
                    expectedRow.workOSGoalID,
                    file: file,
                    line: line)
                XCTAssertEqual(
                    actualRow?.workOSContractID,
                    expectedRow.workOSContractID,
                    file: file,
                    line: line)
                XCTAssertEqual(
                    actualRow?.loopsConfig,
                    expectedRow.loopsConfig,
                    file: file,
                    line: line)
                if compareMessages {
                    XCTAssertTrue(
                        actualRow?.messages == expectedRow.messages,
                        "thread \(id.uuidString.lowercased()) message "
                            + "payload changed; actualCount="
                            + "\(actualRow?.messages?.count ?? 0) "
                            + "expectedCount="
                            + "\(expectedRow.messages?.count ?? 0)",
                        file: file,
                        line: line)
                }
            }
        }
        struct JournalOnlyReadback {
            let nativeFileSHA256: String
            let journalFileSHA256: String
            let nativeThreadIDs: [String]
            let nativeMessageIDsByThread: [String: [String]]
            let journalEventIDs: [String]
            let projectedMessageIDsByThread: [String: [String]]
        }
        func journalOnlyReadback(
            nativeStore: TatwoNativeChatStore,
            journalStore: ChatTranscriptJournalDiskStore
        ) throws -> JournalOnlyReadback {
            let document = try nativeStore.load()
            let journal = try journalStore.load()
            let threads = allThreads(document)
            var nativeMessageIDsByThread: [String: [String]] = [:]
            for thread in threads {
                nativeMessageIDsByThread[
                    thread.id.uuidString.lowercased(),
                    default: []
                ].append(contentsOf: (thread.messages ?? []).map(\.id))
            }
            nativeMessageIDsByThread = nativeMessageIDsByThread.mapValues {
                $0.sorted()
            }

            let nativeStableKeys = threads.map {
                TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: $0.id
                ).stableKey
            }
            let projectionThreadIDs =
                Set(nativeStableKeys).union(journal.events.map(\.threadID))
            var projectedMessageIDsByThread: [String: [String]] = [:]
            for threadID in projectionThreadIDs {
                projectedMessageIDsByThread[threadID] =
                    ChatTranscriptJournalAdapter.projectedMessages(
                        threadID: threadID,
                        from: journal
                    ).map(\.id).sorted()
            }
            return JournalOnlyReadback(
                nativeFileSHA256: try sha256(nativeStore.url),
                journalFileSHA256: try sha256(journalStore.fileURL),
                nativeThreadIDs: threads.map {
                    $0.id.uuidString.lowercased()
                }.sorted(),
                nativeMessageIDsByThread: nativeMessageIDsByThread,
                journalEventIDs: journal.events.map(\.eventID).sorted(),
                projectedMessageIDsByThread:
                    projectedMessageIDsByThread)
        }
        func assertExactIDs(
            _ actual: [String],
            equalTo expected: [String],
            stage: String,
            collection: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let actualSet = Set(actual)
            let expectedSet = Set(expected)
            let added = actualSet.subtracting(expectedSet).sorted()
            let removed = expectedSet.subtracting(actualSet).sorted()
            XCTAssertTrue(
                actual.count == expected.count,
                "\(stage) \(collection) count changed "
                    + "\(expected.count)->\(actual.count); "
                    + "added=\(added); removed=\(removed)",
                file: file,
                line: line)
            XCTAssertTrue(
                actualSet == expectedSet,
                "\(stage) \(collection) IDs changed; "
                    + "added=\(added); removed=\(removed)",
                file: file,
                line: line)
        }
        func assertExactReadback(
            _ actual: JournalOnlyReadback,
            equalTo expected: JournalOnlyReadback,
            stage: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(
                actual.nativeFileSHA256,
                expected.nativeFileSHA256,
                "\(stage) native JSON SHA-256 changed",
                file: file,
                line: line)
            XCTAssertEqual(
                actual.journalFileSHA256,
                expected.journalFileSHA256,
                "\(stage) journal JSON SHA-256 changed",
                file: file,
                line: line)
            assertExactIDs(
                actual.nativeThreadIDs,
                equalTo: expected.nativeThreadIDs,
                stage: stage,
                collection: "native thread",
                file: file,
                line: line)
            assertExactIDs(
                Array(actual.nativeMessageIDsByThread.keys),
                equalTo: Array(expected.nativeMessageIDsByThread.keys),
                stage: stage,
                collection: "native message thread-key",
                file: file,
                line: line)
            for threadID in Set(actual.nativeMessageIDsByThread.keys).union(
                expected.nativeMessageIDsByThread.keys
            ).sorted() {
                assertExactIDs(
                    actual.nativeMessageIDsByThread[threadID] ?? [],
                    equalTo:
                        expected.nativeMessageIDsByThread[threadID] ?? [],
                    stage: stage,
                    collection: "native messages[\(threadID)]",
                    file: file,
                    line: line)
            }
            assertExactIDs(
                actual.journalEventIDs,
                equalTo: expected.journalEventIDs,
                stage: stage,
                collection: "journal event",
                file: file,
                line: line)
            assertExactIDs(
                Array(actual.projectedMessageIDsByThread.keys),
                equalTo:
                    Array(expected.projectedMessageIDsByThread.keys),
                stage: stage,
                collection: "projection thread-key",
                file: file,
                line: line)
            for threadID in Set(
                actual.projectedMessageIDsByThread.keys
            ).union(
                expected.projectedMessageIDsByThread.keys
            ).sorted() {
                assertExactIDs(
                    actual.projectedMessageIDsByThread[threadID] ?? [],
                    equalTo:
                        expected.projectedMessageIDsByThread[threadID]
                        ?? [],
                    stage: stage,
                    collection: "projected messages[\(threadID)]",
                    file: file,
                    line: line)
            }
        }
        @MainActor
        func selectThread(
            _ threadID: UUID,
            in model: ChatPageModel
        ) throws {
            if model.document.threads.contains(where: { $0.id == threadID }) {
                model.selectStandaloneThread(threadID)
                return
            }
            let project = try XCTUnwrap(
                model.document.projects.first {
                    $0.threads.contains(where: { $0.id == threadID })
                })
            model.select(projectID: project.id, threadID: threadID)
        }

        let sourceNative = sourceTatwo.appendingPathComponent(
            "native-chat-threads.json")
        let sourceJournal = sourceTatwo.appendingPathComponent(
            "chat-transcript-journal-v1.json")
        let baselineDocument = try TatwoNativeChatStore(
            url: sourceNative,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false
        ).load()
        let baselineJournal = try ChatTranscriptJournalV1.restoring(
            from: Data(contentsOf: sourceJournal))
        let baselineThreadIDs = Set(allThreads(baselineDocument).map(\.id))
        let baselineEventIDs = baselineJournal.events.map(\.eventID)
        XCTAssertFalse(baselineThreadIDs.isEmpty)
        XCTAssertFalse(baselineEventIDs.isEmpty)
        XCTAssertEqual(Set(baselineEventIDs).count, baselineEventIDs.count)

        let fullNative = fullRoot.appendingPathComponent(
            "native-chat-threads.json")
        let fullJournal = fullRoot.appendingPathComponent(
            "chat-transcript-journal-v1.json")
        let fullCodex = fullRoot.appendingPathComponent(
            "codex",
            isDirectory: true)
        try copy(sourceNative, to: fullNative)
        try copy(sourceJournal, to: fullJournal)
        try copy(
            sourceTatwo.appendingPathComponent(
                "chat-composer-drafts-v1.json"),
            to: fullRoot.appendingPathComponent(
                "chat-composer-drafts-v1.json"))
        let sourceCodexDatabase = sourceCodex.appendingPathComponent(
            "state_5.sqlite")
        let fullCodexDatabase = fullCodex.appendingPathComponent(
            "state_5.sqlite")
        let sourceCodexThreadCount = try runSQLite(
            databaseURL: sourceCodexDatabase,
            command: "SELECT count(*) FROM threads;")
        try sqliteBackup(sourceCodexDatabase, to: fullCodexDatabase)
        XCTAssertEqual(
            try runSQLite(
                databaseURL: fullCodexDatabase,
                command: "SELECT count(*) FROM threads;"),
            sourceCodexThreadCount)
        try copy(
            sourceCodex.appendingPathComponent(".codex-global-state.json"),
            to: fullCodex.appendingPathComponent(
                ".codex-global-state.json"))
        if fileManager.fileExists(atPath: sourceRepairs.path) {
            try copy(
                sourceRepairs,
                to: fullRoot.appendingPathComponent(
                    "chat-repair-backups",
                    isDirectory: true))
        }

        let fullPreferences = fullRoot.appendingPathComponent(
            "preferences.json")
        try TatwoPreferenceStore(fileURL: fullPreferences).save(
            TatwoUserPreferences(
                codexThreadMirrorExternalVolumeOptIn: true))
        let fullEnvironment = [
            "XCTestConfigurationFilePath":
                "ChatPlanGoalContinuityTests",
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_APP_SUPPORT": fullRoot.path,
            "TATWO_ULTRAWORK_PREFERENCES": fullPreferences.path,
            "CODEX_HOME": fullCodex.path,
        ]
        let fullNativeStore = TatwoNativeChatStore(
            url: fullNative,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let fullJournalStore = ChatTranscriptJournalDiskStore(
            fileURL: fullJournal)
        let fullBridge = TatwoCodexAppStateBridge(
            sourcePaths: .init(
                stateDatabaseURL: fullCodexDatabase,
                globalStateURL: fullCodex.appendingPathComponent(
                    ".codex-global-state.json")))
        var firstFullModel: ChatPageModel? = ChatPageModel(
            environment: fullEnvironment,
            store: fullNativeStore,
            codexAppStateBridge: fullBridge,
            transcriptJournalStore: fullJournalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: fullRoot),
            plgChainStore: makeTestPLGChainStore(in: fullRoot))
        try await waitForInitialStoreLoad(try XCTUnwrap(firstFullModel))

        let firstFullMirrorStatus = firstFullModel!.codexMirrorStatus
        XCTAssertEqual(firstFullMirrorStatus, .loaded)
        XCTAssertTrue(
            baselineThreadIDs.isSubset(
                of: Set(allThreads(firstFullModel!.document).map(\.id))))
        XCTAssertTrue(firstFullModel!.persistStore())
        let firstFullDocument = try fullNativeStore.load()
        let firstFullJournal = try fullJournalStore.load()
        let firstFullJournalSHA256 = try sha256(fullJournal)
        XCTAssertTrue(
            baselineThreadIDs.isSubset(
                of: Set(allThreads(firstFullDocument).map(\.id))))
        assertExactIDs(
            firstFullJournal.events.map(\.eventID),
            equalTo: baselineEventIDs,
            stage: "first full persist",
            collection: "journal event")
        XCTAssertEqual(
            Set(firstFullJournal.events.map(\.eventID)).count,
            firstFullJournal.events.count)
        firstFullModel = nil

        let secondFullModel = ChatPageModel(
            environment: fullEnvironment,
            store: fullNativeStore,
            codexAppStateBridge: fullBridge,
            transcriptJournalStore: fullJournalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: fullRoot),
            plgChainStore: makeTestPLGChainStore(in: fullRoot))
        try await waitForInitialStoreLoad(secondFullModel)
        let secondFullMirrorStatus = secondFullModel.codexMirrorStatus
        XCTAssertEqual(secondFullMirrorStatus, .loaded)
        XCTAssertTrue(secondFullModel.persistStore())
        let secondFullDocument = try fullNativeStore.load()
        let secondFullJournal = try fullJournalStore.load()
        let secondFullJournalSHA256 = try sha256(fullJournal)
        assertStableRows(secondFullDocument, equalTo: firstFullDocument)
        XCTAssertTrue(
            secondFullJournal == firstFullJournal,
            "second full journal payload changed; firstEventCount="
                + "\(firstFullJournal.events.count) secondEventCount="
                + "\(secondFullJournal.events.count)")
        XCTAssertTrue(
            secondFullJournalSHA256 == firstFullJournalSHA256,
            "second full journal SHA-256 changed; expected="
                + "\(firstFullJournalSHA256) actual="
                + "\(secondFullJournalSHA256)")

        try fileManager.createDirectory(
            at: journalOnlyRoot,
            withIntermediateDirectories: true)
        let journalOnlyNative = journalOnlyRoot.appendingPathComponent(
            "native-chat-threads.json")
        let journalOnlyJournal = journalOnlyRoot.appendingPathComponent(
            "chat-transcript-journal-v1.json")
        try copy(fullJournal, to: journalOnlyJournal)
        let fullRepairRoot = fullRoot.appendingPathComponent(
            "chat-repair-backups",
            isDirectory: true)
        if fileManager.fileExists(atPath: fullRepairRoot.path) {
            try copy(
                fullRepairRoot,
                to: journalOnlyRoot.appendingPathComponent(
                    "chat-repair-backups",
                    isDirectory: true))
        }
        let journalOnlyNativeStore = TatwoNativeChatStore(
            url: journalOnlyNative,
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let journalOnlyBaselineDocument =
            ChatTranscriptJournalAdapter.removingLegacyTranscriptPayloads(
                from: secondFullDocument)
        try journalOnlyNativeStore.save(journalOnlyBaselineDocument)
        let journalOnlyJournalStore = ChatTranscriptJournalDiskStore(
            fileURL: journalOnlyJournal)
        let unavailableBridge = TatwoCodexAppStateBridge(
            sourcePaths: .init(
                stateDatabaseURL: journalOnlyRoot.appendingPathComponent(
                    "missing/state_5.sqlite"),
                globalStateURL: journalOnlyRoot.appendingPathComponent(
                    "missing/.codex-global-state.json")))
        let journalOnlyPreferences = journalOnlyRoot.appendingPathComponent(
            "preferences.json")
        try TatwoPreferenceStore(fileURL: journalOnlyPreferences).save(
            TatwoUserPreferences(
                codexThreadMirrorExternalVolumeOptIn: true))
        let journalOnlyEnvironment = [
            "XCTestConfigurationFilePath":
                "ChatPlanGoalContinuityTests",
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_APP_SUPPORT": journalOnlyRoot.path,
            "TATWO_ULTRAWORK_PREFERENCES": journalOnlyPreferences.path,
            "CODEX_HOME": journalOnlyRoot.appendingPathComponent(
                "missing",
                isDirectory: true).path,
        ]
        let journalBackedThread = try XCTUnwrap(
            allThreads(journalOnlyBaselineDocument).first { thread in
                !ChatTranscriptJournalAdapter.projectedMessages(
                    threadID: TatwoNativeChatSessionReference(
                        kind: .thread,
                        id: thread.id
                    ).stableKey,
                    from: secondFullJournal
                ).isEmpty
            })
        let expectedJournalProjection =
            ChatTranscriptJournalAdapter.projectedMessages(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: journalBackedThread.id
                ).stableKey,
                from: secondFullJournal)
        XCTAssertFalse(expectedJournalProjection.isEmpty)
        let expectedJournalRecords =
            expectedJournalProjection.map(\.storedRecord)
        let journalOnlyBaselineReadback = try journalOnlyReadback(
            nativeStore: journalOnlyNativeStore,
            journalStore: journalOnlyJournalStore)
        var firstJournalOnlyModel: ChatPageModel? = ChatPageModel(
            environment: journalOnlyEnvironment,
            store: journalOnlyNativeStore,
            codexAppStateBridge: unavailableBridge,
            transcriptJournalStore: journalOnlyJournalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: journalOnlyRoot),
            plgChainStore: makeTestPLGChainStore(in: journalOnlyRoot))
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "first model created")
        try await waitForInitialStoreLoad(
            try XCTUnwrap(firstJournalOnlyModel))

        let firstJournalOnlyStatus =
            firstJournalOnlyModel!.codexMirrorStatus
        XCTAssertEqual(
            firstJournalOnlyStatus,
            .unavailable)
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "first initial load completed")
        try selectThread(
            journalBackedThread.id,
            in: try XCTUnwrap(firstJournalOnlyModel))
        let firstSelectedJournalRecords =
            firstJournalOnlyModel!.transcriptMessages.map(\.storedRecord)
        XCTAssertTrue(
            firstSelectedJournalRecords == expectedJournalRecords,
            "first journal-only selection payload changed; expectedCount="
                + "\(expectedJournalRecords.count) actualCount="
                + "\(firstSelectedJournalRecords.count)")
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "first thread selected")
        assertStableRows(
            firstJournalOnlyModel!.document,
            equalTo: journalOnlyBaselineDocument,
            compareMessages: false)
        XCTAssertTrue(firstJournalOnlyModel!.persistStore())
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "first persist completed")
        let firstJournalOnlyDocument =
            try journalOnlyNativeStore.load()
        let firstJournalOnlyJournal =
            try journalOnlyJournalStore.load()
        assertStableRows(
            firstJournalOnlyDocument,
            equalTo: journalOnlyBaselineDocument)
        XCTAssertTrue(
            firstJournalOnlyJournal == secondFullJournal,
            "first journal-only persist changed journal payload; "
                + "expectedEventCount=\(secondFullJournal.events.count) "
                + "actualEventCount=\(firstJournalOnlyJournal.events.count)")
        firstJournalOnlyModel = nil

        let secondJournalOnlyModel = ChatPageModel(
            environment: journalOnlyEnvironment,
            store: journalOnlyNativeStore,
            codexAppStateBridge: unavailableBridge,
            transcriptJournalStore: journalOnlyJournalStore,
            goalRunStore: TatwoGoalRunStore(directoryURL: journalOnlyRoot),
            plgChainStore: makeTestPLGChainStore(in: journalOnlyRoot))
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "second model created")
        try await waitForInitialStoreLoad(secondJournalOnlyModel)
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "second initial load completed")
        let expectedSecondJournalOnlyStatus:
            TatwoCodexAppStateBridge.MirrorStatus =
                unavailableBridge.sourcePaths.requiresExternalVolumeOptIn
                ? .notEnabled
                : .unavailable
        let secondJournalOnlyStatus =
            secondJournalOnlyModel.codexMirrorStatus
        XCTAssertEqual(
            secondJournalOnlyStatus,
            expectedSecondJournalOnlyStatus)
        XCTAssertEqual(
            try TatwoPreferenceStore(fileURL: journalOnlyPreferences)
                .load()
                .codexThreadMirrorExternalVolumeOptIn,
            !unavailableBridge.sourcePaths.requiresExternalVolumeOptIn)
        try selectThread(
            journalBackedThread.id,
            in: secondJournalOnlyModel)
        let secondSelectedJournalRecords =
            secondJournalOnlyModel.transcriptMessages.map(\.storedRecord)
        XCTAssertTrue(
            secondSelectedJournalRecords == expectedJournalRecords,
            "second journal-only selection payload changed; expectedCount="
                + "\(expectedJournalRecords.count) actualCount="
                + "\(secondSelectedJournalRecords.count)")
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "second thread selected")
        XCTAssertTrue(secondJournalOnlyModel.persistStore())
        assertExactReadback(
            try journalOnlyReadback(
                nativeStore: journalOnlyNativeStore,
                journalStore: journalOnlyJournalStore),
            equalTo: journalOnlyBaselineReadback,
            stage: "second persist completed")
        assertStableRows(
            try journalOnlyNativeStore.load(),
            equalTo: firstJournalOnlyDocument)
        let finalJournalOnlyJournal =
            try journalOnlyJournalStore.load()
        XCTAssertTrue(
            finalJournalOnlyJournal == firstJournalOnlyJournal,
            "second journal-only persist changed journal payload; "
                + "expectedEventCount=\(firstJournalOnlyJournal.events.count) "
                + "actualEventCount=\(finalJournalOnlyJournal.events.count)")
        var observation: [String: Any] = [
            "formalDate": "2026-08-04",
            "sourceSnapshotRoot": snapshotRoot.path,
            "isolatedWorkRoot": runRoot.path,
            "baselineThreadCount": baselineThreadIDs.count,
            "baselineJournalEventCount": baselineEventIDs.count,
            "fullMirrorStatus": secondFullMirrorStatus.rawValue,
            "fullMirrorFirstStatus": firstFullMirrorStatus.rawValue,
            "fullMirrorSecondStatus": secondFullMirrorStatus.rawValue,
            "journalOnlyFirstStatus": firstJournalOnlyStatus.rawValue,
            "journalOnlySecondStatus":
                secondJournalOnlyStatus.rawValue,
            "journalOnlyTranscriptSource": "journal-projection",
            "codexSQLiteSnapshotMethod": "sqlite-backup",
            "codexSQLiteThreadCount": sourceCodexThreadCount,
            "secondFullThreadCount": allThreads(secondFullDocument).count,
            "secondFullJournalEventCount": secondFullJournal.events.count,
            "liveMutationAllowed": false,
            "scope": "single-xctest-observation-not-process-pass",
        ]
        let observedFailureCount = testRun?.failureCount
        let observationFileName: String
        if observedFailureCount == 0 {
            observation["schema"] =
                "TatwoWave1LiveCloneTestcaseObservationV1"
            observation["result"] = "TESTCASE_PASS_CANDIDATE"
            observation["xctestFailureCount"] = 0
            observationFileName =
                "live-clone-dry-run-testcase-observation-"
                + UUID().uuidString.lowercased()
                + ".json"
        } else {
            observation["schema"] =
                "TatwoWave1LiveCloneFailedRunDiagnosticV1"
            observation["result"] = "FAILED_RUN_DIAGNOSTIC"
            observation["xctestFailureCount"] =
                observedFailureCount ?? -1
            observationFileName =
                "live-clone-dry-run-failed-run-diagnostic-"
                + UUID().uuidString.lowercased()
                + ".json"
        }
        let observationURL = snapshotRoot
            .appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent(observationFileName)
        try JSONSerialization.data(
            withJSONObject: observation,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: observationURL, options: [.atomic])
    }
    // END TEMPORARY WAVE 1 LIVE-CLONE DRY-RUN HARNESS

    private func loopsConfig(
        matching contract: TatwoWorkOSContractV1
    ) -> TatwoNativeThreadLoopsConfig {
        TatwoNativeThreadLoopsConfig(
            scenarioID: contract.scenario,
            mode: contract.mode,
            identitySummary: "canonical fixture topology",
            tokenBudget: "fixture",
            primaryModelID: contract.routeBindingOverride?.primaryModelID,
            secondaryModelID: contract.routeBindingOverride?.secondaryModelID)
    }

    @MainActor
    private func makeVerifiedSessionFixture(
        _ suffix: String,
        pointer: ((TatwoWorkOSContractV1) -> TatwoSessionPointer)? = nil,
        savePointer: Bool = true,
        prepareGoalRun: ((
            TatwoGoalRunStore,
            TatwoWorkOSContractV1
        ) throws -> Void)? = nil,
        threads: (TatwoWorkOSContractV1) -> [TatwoNativeChatThread]
    ) throws -> (
        model: ChatPageModel,
        goalStore: TatwoGoalRunStore,
        contract: TatwoWorkOSContractV1
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-current-session-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "Verified current session objective \(suffix)",
            store: goalStore)
        if savePointer {
            try TatwoSessionStore(directoryURL: directory).writeRawPointerFixtureForTesting(
                pointer?(contract)
                    ?? TatwoSessionPointer(
                        contractID: contract.contractID,
                        goalID: contract.goalID,
                        mode: contract.mode,
                        scenario: contract.scenario,
                        objective: contract.objective))
        }
        try prepareGoalRun?(goalStore, contract)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: threads(contract)))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ChatPlanGoalContinuityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            plgChainStore: makeTestPLGChainStore(in: directory))
        return (model, goalStore, contract)
    }

    private func makeTestPLGChainStore(in directory: URL) -> TatwoPLGChainStore {
        TatwoPLGChainStore(
            directory: directory.appendingPathComponent(
                "plg-event-chains-test",
                isDirectory: true),
            anchorAuthority: ChatPlanGoalTestAnchorAuthority())
    }

    private func runSQLite(db: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
            throw NSError(
                domain: "ChatPlanGoalContinuityTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private struct ChatPlanGoalTestAnchorAuthority: TatwoPLGAnchorAuthority {
    func sign(_ material: String) -> String {
        "chat-plan-goal-test-anchor|\(material)"
    }

    func verify(_ signature: String, material: String) -> Bool {
        signature == sign(material)
    }
}

private final class ChatPlanGoalRecordingNativeRunner:
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

private struct ChatPlanGoalRejectingNativeRunner:
    ChatNativeAgentRunning
{
    func start(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        nil
    }

    func terminate() {}
}

private final class ChatPlanGoalContinuityRemoteDispatcher:
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
        let attempt = storedRequests.count
        lock.unlock()
        return .accepted(ChatRemoteTurnDispatchAcceptance(
            logicalJobID: request.logicalJobID,
            remoteJobID: "job-completed-turn-\(attempt)",
            acceptedAt: Date()))
    }
}
