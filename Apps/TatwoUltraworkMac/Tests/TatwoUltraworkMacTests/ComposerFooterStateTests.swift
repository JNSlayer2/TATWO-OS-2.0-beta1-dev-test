import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class ComposerFooterStateTests: XCTestCase {
    @MainActor
    func testBlockedBindingIntentOnlyMarksItsExactProjectThreadUnbound()
        throws
    {
        let fixture = try makeBlockedScopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(fixture.model.selectedThreadID, fixture.unrelatedThreadID)
        XCTAssertEqual(fixture.model.composerFooterState, .neutral)

        selectBlockedThread(in: fixture)

        XCTAssertEqual(
            fixture.model.composerFooterState,
            .workContextUnbound)
    }

    @MainActor
    func testSuccessfulMatchingIntentCleanupClearsFooterWithoutRestart()
        throws
    {
        let fixture = try makeBlockedScopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        selectBlockedThread(in: fixture)
        XCTAssertEqual(
            fixture.model.composerFooterState,
            .workContextUnbound)

        try markIntentApplied(
            fixture.blockedIntent,
            in: fixture.store)
        fixture.model.finishWorkOSBindingMutationIntent(
            fixture.blockedIntent)

        XCTAssertNil(try fixture.intentStore.load())
        XCTAssertEqual(fixture.model.composerFooterState, .neutral)
    }

    @MainActor
    func testSuccessfulNonmatchingIntentCleanupDoesNotClearCachedBlocker()
        throws
    {
        let fixture = try makeBlockedScopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        selectBlockedThread(in: fixture)
        XCTAssertEqual(
            fixture.model.composerFooterState,
            .workContextUnbound)

        try fixture.intentStore.remove(fixture.blockedIntent)
        let unrelatedIntent = WorkOSBindingMutationIntentV1(
            threadID: fixture.unrelatedThreadID,
            projectID: fixture.projectID,
            oldContractID: "other-contract",
            oldGoalID: "other-goal",
            desiredLoopsConfig: fixture.loopsConfig)
        try fixture.intentStore.create(unrelatedIntent)
        try markIntentApplied(
            unrelatedIntent,
            in: fixture.store)

        fixture.model.finishWorkOSBindingMutationIntent(unrelatedIntent)

        XCTAssertNil(try fixture.intentStore.load())
        XCTAssertEqual(
            fixture.model.composerFooterState,
            .workContextUnbound)
    }

    @MainActor
    func testMismatchedPersistedInvalidationKeepsIntentAndFooterBlocked()
        throws
    {
        let fixture = try makeBlockedScopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        selectBlockedThread(in: fixture)

        try markIntentApplied(
            fixture.blockedIntent,
            in: fixture.store,
            invalidationID: UUID())
        fixture.model.finishWorkOSBindingMutationIntent(
            fixture.blockedIntent)

        XCTAssertEqual(
            try fixture.intentStore.load(),
            fixture.blockedIntent)
        XCTAssertEqual(
            fixture.model.composerFooterState,
            .workContextUnbound)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "durable mutation intent"))
    }

    @MainActor
    func testStandaloneMatchingIntentCleanupClearsFooterWithoutRestart()
        throws
    {
        let fixture = try makeBlockedScopeFixture(projectScoped: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        selectBlockedThread(in: fixture)
        XCTAssertEqual(
            fixture.model.composerFooterState,
            .workContextUnbound)

        try markIntentApplied(
            fixture.blockedIntent,
            in: fixture.store)
        fixture.model.finishWorkOSBindingMutationIntent(
            fixture.blockedIntent)

        XCTAssertNil(try fixture.intentStore.load())
        XCTAssertEqual(fixture.model.composerFooterState, .neutral)
    }

    @MainActor
    func testRealCollaborationMutationWriterPersistsAppliedStateAndClearsIntent()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-composer-footer-real-writer-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        let intentStore = WorkOSBindingMutationIntentStore(
            fileURL: directory.appendingPathComponent(
                "work-os-binding-mutation-intent-v1.json"))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ComposerFooterStateTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            goalRunStore: goalStore)
        try await waitForInitialStoreLoad(model)
        if model.selectedThreadID == nil {
            model.newChat()
        }
        model.setCollaborationLevel(.m)
        try await confirmAuthorityBootstrapAndEnsure(
            model,
            objectiveHint:
                "H2-B real writer cleanup must retain a neutral footer")
        let oldContractID = try XCTUnwrap(
            model.selectedWorkOSContract?.contractID)
        let oldGoalID = try XCTUnwrap(
            model.selectedWorkOSContract?.goalID)

        model.setCollaborationLevel(.l)

        XCTAssertNil(try intentStore.load())
        XCTAssertNil(model.selectedThread?.workOSContractID)
        XCTAssertNil(model.selectedThread?.workOSGoalID)
        XCTAssertEqual(model.composerFooterState, .neutral)
        let persistedThread = try XCTUnwrap(
            try store.load().threads.first(where: {
                $0.id == model.selectedThreadID
            }))
        let invalidation = try XCTUnwrap(
            persistedThread.bindingInvalidation)
        XCTAssertEqual(
            invalidation.previousBinding.contractID,
            oldContractID)
        XCTAssertEqual(
            invalidation.previousBinding.goalID,
            oldGoalID)
        XCTAssertEqual(
            invalidation.desiredLoopsConfigSHA256,
            TatwoNativeThreadBindingInvalidationV1
                .loopsConfigSHA256(persistedThread.loopsConfig))
        XCTAssertEqual(
            try goalStore.requireIssuedContract(oldContractID).status,
            .cancelled)
    }

    func testFiveStateMappingUsesOnlyTypedInputs() {
        XCTAssertEqual(
            resolve(),
            .neutral)
        XCTAssertEqual(
            resolve(recoveryRequired: true),
            .recoveryRequired)
        XCTAssertEqual(
            resolve(waitingAuthorization: true),
            .waitingAuthorization)
        XCTAssertEqual(
            resolve(bindingRecoveryBlocked: true),
            .workContextUnbound)
        XCTAssertEqual(
            resolve(routeDispatchAllowed: false),
            .routeCooldown)
    }

    func testPriorityIsRecoveryAuthorizationUnboundCooldownNeutral() {
        XCTAssertEqual(
            resolve(
                recoveryRequired: true,
                waitingAuthorization: true,
                bindingRecoveryBlocked: true,
                routeDispatchAllowed: false),
            .recoveryRequired)
        XCTAssertEqual(
            resolve(
                waitingAuthorization: true,
                bindingRecoveryBlocked: true,
                routeDispatchAllowed: false),
            .waitingAuthorization)
        XCTAssertEqual(
            resolve(
                bindingRecoveryBlocked: true,
                routeDispatchAllowed: false),
            .workContextUnbound)
    }

    func testOrdinaryChatAndCLIAreHardGatedToNeutral() {
        let allActive = ChatComposerFooterStateInputs(
            isCLI: false,
            explicitWorkScope: false,
            recoveryRequired: true,
            waitingAuthorization: true,
            bindingRecoveryBlocked: true,
            routeDispatchAllowed: false)
        XCTAssertEqual(
            ChatComposerFooterStateResolver.resolve(allActive),
            .neutral)

        var cli = allActive
        cli.isCLI = true
        cli.explicitWorkScope = true
        XCTAssertEqual(
            ChatComposerFooterStateResolver.resolve(cli),
            .neutral)
    }

    func testUnboundRequiresExplicitWorkScopeAndRecoveryBlocker() {
        XCTAssertEqual(
            ChatComposerFooterStateResolver.resolve(
                ChatComposerFooterStateInputs(
                    explicitWorkScope: false,
                    bindingRecoveryBlocked: true)),
            .neutral)
        XCTAssertEqual(
            resolve(bindingRecoveryBlocked: false),
            .neutral)
        XCTAssertEqual(
            resolve(bindingRecoveryBlocked: true),
            .workContextUnbound)
    }

    func testPresentationLabelsAreFixedAndShort() {
        XCTAssertEqual(ChatComposerFooterState.neutral.presentationText, "無額外提醒")
        XCTAssertEqual(ChatComposerFooterState.recoveryRequired.presentationText, "需要復原")
        XCTAssertEqual(ChatComposerFooterState.waitingAuthorization.presentationText, "等待授權")
        XCTAssertEqual(ChatComposerFooterState.workContextUnbound.presentationText, "工作脈絡未綁定")
        XCTAssertEqual(ChatComposerFooterState.routeCooldown.presentationText, "路由冷卻")
    }

    private func resolve(
        recoveryRequired: Bool = false,
        waitingAuthorization: Bool = false,
        bindingRecoveryBlocked: Bool = false,
        routeDispatchAllowed: Bool = true
    ) -> ChatComposerFooterState {
        ChatComposerFooterStateResolver.resolve(
            ChatComposerFooterStateInputs(
                explicitWorkScope: true,
                recoveryRequired: recoveryRequired,
                waitingAuthorization: waitingAuthorization,
                bindingRecoveryBlocked: bindingRecoveryBlocked,
                routeDispatchAllowed: routeDispatchAllowed))
    }

    @MainActor
    private func makeBlockedScopeFixture(
        projectScoped: Bool = true
    ) throws -> BlockedScopeFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-composer-footer-scope-\(UUID().uuidString)",
                isDirectory: true)
        let projectID = projectScoped ? UUID() : nil
        let blockedThreadID = UUID()
        let unrelatedThreadID = UUID()
        let loopsConfig = TatwoNativeThreadLoopsConfig(
            scenarioID: "coding",
            mode: .m,
            identitySummary: "footer scope fixture",
            tokenBudget: "focused test",
            primaryModelID: "gpt-5.6-sol",
            secondaryModelID: nil)
        let store = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let threads = [
            TatwoNativeChatThread(
                id: blockedThreadID,
                title: "Thread A",
                updatedAt: Date(timeIntervalSince1970: 1),
                loopsConfig: loopsConfig),
            TatwoNativeChatThread(
                id: unrelatedThreadID,
                title: "Thread B",
                updatedAt: Date(timeIntervalSince1970: 2),
                loopsConfig: loopsConfig),
        ]
        if let projectID {
            try store.save(TatwoNativeChatStoreDocument(projects: [
                TatwoNativeChatProject(
                    id: projectID,
                    name: "Footer scope",
                    workdir: directory.path,
                    threads: threads)
            ]))
        } else {
            try store.save(TatwoNativeChatStoreDocument(threads: threads))
        }
        let intentStore = WorkOSBindingMutationIntentStore(
            fileURL: directory.appendingPathComponent(
                "work-os-binding-mutation-intent-v1.json"))
        let blockedIntent = WorkOSBindingMutationIntentV1(
            threadID: blockedThreadID,
            projectID: projectID,
            oldContractID: "missing-contract",
            oldGoalID: "missing-goal",
            desiredLoopsConfig: loopsConfig)
        try intentStore.create(blockedIntent)
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath": "ComposerFooterStateTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            goalRunStore: TatwoGoalRunStore(directoryURL: directory))
        return BlockedScopeFixture(
            directory: directory,
            projectID: projectID,
            blockedThreadID: blockedThreadID,
            unrelatedThreadID: unrelatedThreadID,
            loopsConfig: loopsConfig,
            blockedIntent: blockedIntent,
            intentStore: intentStore,
            store: store,
            model: model)
    }

    private func markIntentApplied(
        _ intent: WorkOSBindingMutationIntentV1,
        in store: TatwoNativeChatStore,
        invalidationID: UUID? = nil
    ) throws {
        var document = try store.load()
        let invalidation = TatwoNativeThreadBindingInvalidationV1(
            id: invalidationID ?? intent.id,
            reason: intent.desiredLoopsConfig == nil
                ? .contractSuperseded
                : .loopsConfigChanged,
            threadID: intent.threadID,
            projectID: intent.projectID,
            previousBinding: TatwoNativeThreadBindingIdentityV1(
                contractID: intent.oldContractID,
                goalID: intent.oldGoalID,
                goalRevision: 1),
            previousLoopsConfig: nil,
            desiredLoopsConfig: intent.desiredLoopsConfig)
        if let projectID = intent.projectID {
            let projectIndex = try XCTUnwrap(
                document.projects.firstIndex(where: { $0.id == projectID }))
            let threadIndex = try XCTUnwrap(
                document.projects[projectIndex].threads.firstIndex(where: {
                    $0.id == intent.threadID
                }))
            document.projects[projectIndex].threads[threadIndex].loopsConfig =
                intent.desiredLoopsConfig
            document.projects[projectIndex].threads[threadIndex]
                .workOSGoalID = nil
            document.projects[projectIndex].threads[threadIndex]
                .workOSContractID = nil
            document.projects[projectIndex].threads[threadIndex]
                .selectedThreadWorkOSContext = nil
            document.projects[projectIndex].threads[threadIndex]
                .activePLGRunProjection = nil
            document.projects[projectIndex].threads[threadIndex]
                .bindingInvalidation = invalidation
        } else {
            let threadIndex = try XCTUnwrap(
                document.threads.firstIndex(where: {
                    $0.id == intent.threadID
                }))
            document.threads[threadIndex].loopsConfig =
                intent.desiredLoopsConfig
            document.threads[threadIndex].workOSGoalID = nil
            document.threads[threadIndex].workOSContractID = nil
            document.threads[threadIndex].selectedThreadWorkOSContext = nil
            document.threads[threadIndex].activePLGRunProjection = nil
            document.threads[threadIndex].bindingInvalidation = invalidation
        }
        try store.save(document)
    }

    @MainActor
    private func selectBlockedThread(
        in fixture: BlockedScopeFixture
    ) {
        if let projectID = fixture.projectID {
            fixture.model.select(
                projectID: projectID,
                threadID: fixture.blockedThreadID)
        } else {
            fixture.model.selectStandaloneThread(
                fixture.blockedThreadID)
        }
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
    private func waitForInitialStoreLoad(
        _ model: ChatPageModel
    ) async throws {
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }

    private struct BlockedScopeFixture {
        let directory: URL
        let projectID: UUID?
        let blockedThreadID: UUID
        let unrelatedThreadID: UUID
        let loopsConfig: TatwoNativeThreadLoopsConfig
        let blockedIntent: WorkOSBindingMutationIntentV1
        let intentStore: WorkOSBindingMutationIntentStore
        let store: TatwoNativeChatStore
        let model: ChatPageModel
    }
}
