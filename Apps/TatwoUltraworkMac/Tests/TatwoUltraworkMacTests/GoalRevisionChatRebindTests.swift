import Foundation
import XCTest
@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

@MainActor
final class GoalRevisionChatRebindTests: XCTestCase {
    func testExactConfirmedPredecessorRebindsSameThreadToSuccessor()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "exact-predecessor",
            selectedBinding: .predecessor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let originalThreadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        let originalSessionID = try XCTUnwrap(
            fixture.model.selectedThread?.codexSessionID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.predecessor.contractID)
        XCTAssertEqual(fixture.model.document.threads.count, 1)

        let confirmation = try confirmRevision(fixture)

        XCTAssertTrue(
            fixture.model.refreshAfterGoalRevisionPromotion())
        XCTAssertEqual(fixture.model.selectedThreadID, originalThreadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.codexSessionID,
            originalSessionID)
        XCTAssertEqual(fixture.model.document.threads.count, 1)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            confirmation.transition.successor.goalID)
        XCTAssertEqual(
            fixture.model.selectedWorkOSContract?.contractID,
            confirmation.transition.successor.contractID)
        XCTAssertEqual(
            fixture.model.selectedGoalRecord?.predecessorContractID,
            fixture.predecessor.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.loopsConfig?.mode,
            .xxl)
        XCTAssertEqual(
            fixture.model.selectedThread?.loopsConfig?.scenarioID,
            TatwoScenarioConfigDefaults
                .exactXXLSolOpusLunaGrokScenarioID)
        XCTAssertNil(
            fixture.model.selectedThread?.bindingInvalidation)
        let persisted = try fixture.store.load()
        XCTAssertNil(
            persisted.threads.first?
                .bindingInvalidation)
        XCTAssertEqual(
            persisted.threads.first?.workOSContractID,
            confirmation.transition.successor.contractID)
    }

    func testRelaunchCompletesExactSuccessorAfterCrashFollowingInvalidationMark()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "crash-after-invalidation-mark",
            selectedBinding: .predecessor,
            pointerKind: .v2OwnerBound)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let confirmation = try confirmRevision(fixture)
        let crashedThread = try XCTUnwrap(
            fixture.model.selectedThread)
        let invalidation = try goalRevisionInvalidation(
            fixture: fixture,
            thread: crashedThread,
            successor: confirmation.transition.successor,
            successorContract: confirmation.readback.contract)
        var document = try fixture.store.load()
        document.threads[0].bindingInvalidation = invalidation
        try fixture.store.save(document)

        let reloaded = makeReloadedModel(fixture)
        try await waitForInitialStoreLoad(reloaded)

        XCTAssertEqual(
            reloaded.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertEqual(
            reloaded.selectedThread?.workOSGoalID,
            confirmation.transition.successor.goalID)
        XCTAssertNil(reloaded.selectedThread?.bindingInvalidation)
        let persisted = try fixture.store.load()
        XCTAssertEqual(
            persisted.threads.first?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertNil(persisted.threads.first?.bindingInvalidation)
    }

    func testRelaunchCompletesExactSuccessorAfterCrashFollowingPredecessorClear()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "crash-after-predecessor-clear",
            selectedBinding: .predecessor,
            pointerKind: .v2OwnerBound)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let confirmation = try confirmRevision(fixture)
        var crashedThread = try XCTUnwrap(
            fixture.model.selectedThread)
        let invalidation = try goalRevisionInvalidation(
            fixture: fixture,
            thread: crashedThread,
            successor: confirmation.transition.successor,
            successorContract: confirmation.readback.contract)
        crashedThread.loopsConfig = materializedLoopsConfig(
            matching: confirmation.readback.contract)
        crashedThread.workOSContractID = nil
        crashedThread.workOSGoalID = nil
        crashedThread.selectedThreadWorkOSContext = nil
        crashedThread.activePLGRunProjection = nil
        crashedThread.bindingInvalidation = invalidation
        var document = try fixture.store.load()
        document.threads[0] = crashedThread
        try fixture.store.save(document)

        let reloaded = makeReloadedModel(fixture)
        try await waitForInitialStoreLoad(reloaded)

        XCTAssertEqual(
            reloaded.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertEqual(
            reloaded.selectedThread?.workOSGoalID,
            confirmation.transition.successor.goalID)
        XCTAssertNil(reloaded.selectedThread?.bindingInvalidation)
        let persisted = try fixture.store.load()
        XCTAssertEqual(
            persisted.threads.first?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertNil(persisted.threads.first?.bindingInvalidation)
    }

    func testRelaunchCompletesExactSuccessorWhenPromotionFinishedBeforeRebindStarted()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "crash-before-invalidation-mark",
            selectedBinding: .predecessor,
            pointerKind: .v2OwnerBound)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let confirmation = try confirmRevision(fixture)
        let persistedBeforeRelaunch = try fixture.store.load()
        XCTAssertEqual(
            persistedBeforeRelaunch.threads.first?.workOSContractID,
            fixture.predecessor.contractID)
        XCTAssertNil(
            persistedBeforeRelaunch.threads.first?.bindingInvalidation)

        let reloaded = makeReloadedModel(fixture)
        try await waitForInitialStoreLoad(reloaded)

        XCTAssertEqual(
            reloaded.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertEqual(
            reloaded.selectedThread?.workOSGoalID,
            confirmation.transition.successor.goalID)
        XCTAssertNil(reloaded.selectedThread?.bindingInvalidation)
        let persisted = try fixture.store.load()
        XCTAssertEqual(
            persisted.threads.first?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertNil(persisted.threads.first?.bindingInvalidation)
    }

    func testChangedSuccessorGoalRevisionFailsClosedBeforeRebind()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "changed-successor-revision",
            selectedBinding: .predecessor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let confirmation = try confirmRevision(fixture)
        var changedSuccessor = try fixture.goalStore
            .requireIssuedContract(
                confirmation.transition.successor.contractID)
        changedSuccessor.revision =
            changedSuccessor.resolvedRevision + 1
        changedSuccessor.updatedAt = Date()
        try writeFixtureGoalRecord(
            changedSuccessor,
            store: fixture.goalStore)

        XCTAssertFalse(
            fixture.model.refreshAfterGoalRevisionPromotion())
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.predecessor.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            fixture.predecessor.goalID)
        XCTAssertNil(
            fixture.model.selectedThread?.bindingInvalidation)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "隔離"))
    }

    func testUnrelatedTerminalSelectedBindingIsNeverReboundAfterPromotion()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "unrelated-terminal",
            selectedBinding: .unrelatedTerminal)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let originalThreadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        let originalSessionID = try XCTUnwrap(
            fixture.model.selectedThread?.codexSessionID)
        let unrelated = try XCTUnwrap(fixture.unrelatedTerminal)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            unrelated.contractID)

        let confirmation = try confirmRevision(fixture)

        XCTAssertFalse(
            fixture.model.refreshAfterGoalRevisionPromotion())
        XCTAssertEqual(fixture.model.selectedThreadID, originalThreadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.codexSessionID,
            originalSessionID)
        XCTAssertEqual(fixture.model.document.threads.count, 1)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            unrelated.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            unrelated.goalID)
        XCTAssertNotEqual(
            fixture.model.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedGoalRecord)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "隔離"))
    }

    func testOrdinaryProjectAttachDoesNotReplaceUnrelatedSucceededBinding()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "unrelated-succeeded",
            selectedBinding: .unrelatedSucceeded,
            pointerKind: .v2ProjectOwnerBound)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let projectID = try XCTUnwrap(
            fixture.model.selectedProjectID)
        let threadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        let unrelated = try XCTUnwrap(fixture.unrelatedTerminal)
        let persisted = try fixture.goalStore.requireIssuedContract(
            unrelated.contractID)
        XCTAssertEqual(persisted.status, .succeeded)
        XCTAssertEqual(
            persisted.statusReason,
            "fixture_awaiting_goal_judge")

        fixture.model.select(
            projectID: projectID,
            threadID: threadID)

        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            unrelated.contractID)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSGoalID,
            unrelated.goalID)
        XCTAssertNotEqual(
            fixture.model.selectedThread?.workOSContractID,
            fixture.predecessor.contractID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedGoalRecord)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "隔離"))
    }

    func testUnboundSelectedRowRemainsUnboundAfterConfirmedPromotion()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "unbound-refusal",
            selectedBinding: .predecessor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let originalThreadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        let originalSessionID = try XCTUnwrap(
            fixture.model.selectedThread?.codexSessionID)
        let threadIndex = try XCTUnwrap(
            fixture.model.document.threads.firstIndex {
                $0.id == originalThreadID
            })
        fixture.model.document.threads[threadIndex].workOSContractID = nil
        fixture.model.document.threads[threadIndex].workOSGoalID = nil
        fixture.model.document.threads[threadIndex]
            .selectedThreadWorkOSContext = nil
        fixture.model.document.threads[threadIndex].activePLGRunProjection = nil
        fixture.model.document.threads[threadIndex].loopsConfig = nil

        let confirmation = try confirmRevision(fixture)

        XCTAssertFalse(
            fixture.model.refreshAfterGoalRevisionPromotion())
        XCTAssertEqual(fixture.model.selectedThreadID, originalThreadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.codexSessionID,
            originalSessionID)
        XCTAssertEqual(fixture.model.document.threads.count, 1)
        XCTAssertNil(
            fixture.model.selectedThread?.workOSContractID)
        XCTAssertNil(fixture.model.selectedThread?.workOSGoalID)
        XCTAssertNil(
            fixture.model.selectedThread?
                .selectedThreadWorkOSContext)
        XCTAssertNotEqual(
            fixture.model.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertNil(fixture.model.selectedWorkOSContract)
        XCTAssertNil(fixture.model.selectedGoalRecord)
        XCTAssertTrue(
            fixture.model.selectedWorkOSStateMessage.contains(
                "exact predecessor"))
    }

    func testV2OwnerBoundExactPredecessorRebindsWithoutChangingSession()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "v2-owner",
            selectedBinding: .predecessor,
            pointerKind: .v2OwnerBound)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let originalThreadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        let originalSessionID = try XCTUnwrap(
            fixture.model.selectedThread?.codexSessionID)
        XCTAssertEqual(
            try fixture.sessionStore.snapshotCurrent()?
                .pointer.schema,
            "TatwoSessionPointerV2")

        let confirmation = try confirmRevision(fixture)

        XCTAssertTrue(
            fixture.model.refreshAfterGoalRevisionPromotion())
        XCTAssertEqual(fixture.model.selectedThreadID, originalThreadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.codexSessionID,
            originalSessionID)
        XCTAssertEqual(fixture.model.document.threads.count, 1)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        XCTAssertEqual(
            confirmation.pointerSnapshot.pointer.schema,
            "TatwoSessionPointerV2")
        XCTAssertEqual(
            confirmation.pointerSnapshot.pointer.ownerBinding?
                .sessionID,
            originalSessionID)
    }

    func testV1ProjectOwnerMigrationRebindsExactPredecessorOnly()
        async throws
    {
        let fixture = try makeFixture(
            suffix: "v1-project-owner-migration",
            selectedBinding: .predecessor,
            pointerKind: .v1ProjectOwnerMigration)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await waitForInitialStoreLoad(fixture.model)

        let originalProjectID = try XCTUnwrap(
            fixture.model.selectedProjectID)
        let originalThreadID = try XCTUnwrap(
            fixture.model.selectedThreadID)
        let originalSessionID = try XCTUnwrap(
            fixture.model.selectedThread?.codexSessionID)
        XCTAssertEqual(
            try fixture.sessionStore.snapshotCurrent()?
                .pointer.schema,
            "TatwoSessionPointerV1")

        let confirmation = try confirmRevision(fixture)

        XCTAssertTrue(
            fixture.model.refreshAfterGoalRevisionPromotion())
        XCTAssertEqual(
            fixture.model.selectedProjectID,
            originalProjectID)
        XCTAssertEqual(fixture.model.selectedThreadID, originalThreadID)
        XCTAssertEqual(
            fixture.model.selectedThread?.codexSessionID,
            originalSessionID)
        XCTAssertEqual(fixture.model.document.projects.count, 1)
        XCTAssertEqual(
            fixture.model.document.projects.first?
                .threads.count,
            1)
        XCTAssertEqual(
            fixture.model.selectedThread?.workOSContractID,
            confirmation.transition.successor.contractID)
        let migratedPointer = try XCTUnwrap(
            fixture.sessionStore.snapshotCurrent()?.pointer)
        XCTAssertEqual(
            migratedPointer.schema,
            "TatwoSessionPointerV2")
        XCTAssertEqual(
            migratedPointer.ownerBinding?.sessionID,
            originalSessionID)
        XCTAssertEqual(
            migratedPointer.contractID,
            confirmation.transition.successor.contractID)
    }

    private enum SelectedBinding {
        case predecessor
        case unrelatedTerminal
        case unrelatedSucceeded
    }

    private enum PointerKind {
        case v1Standalone
        case v2OwnerBound
        case v2ProjectOwnerBound
        case v1ProjectOwnerMigration
    }

    private struct Fixture {
        let root: URL
        let store: TatwoNativeChatStore
        let model: ChatPageModel
        let goalStore: TatwoGoalRunStore
        let sessionStore: TatwoSessionStore
        let dispatchRegistry: TatwoDispatchRegistry
        let predecessor: TatwoWorkOSContractV1
        let unrelatedTerminal: TatwoWorkOSContractV1?
        let artifact: TatwoGoalRevisionIssuerArtifactEvidence
        let now: Date
    }

    private func makeFixture(
        suffix: String,
        selectedBinding: SelectedBinding,
        pointerKind: PointerKind = .v1Standalone
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-goal-revision-chat-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let store = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        let dispatchRegistry = TatwoDispatchRegistry(directoryURL: root)
        let threadID = UUID()
        let sessionID = threadID.uuidString.lowercased()
        let chatWorkspacePath =
            TatwoRuntimeLayout.applicationSupportRoot()
                .appendingPathComponent(
                    "chat-workspace",
                    isDirectory: true)
                .standardizedFileURL.path
        let projectWorkspacePath = root
            .appendingPathComponent(
                "project-workspace",
                isDirectory: true)
            .standardizedFileURL.path
        let owner: TatwoSessionOwnerExpectationV1?
        switch pointerKind {
        case .v1Standalone, .v1ProjectOwnerMigration:
            owner = nil
        case .v2OwnerBound:
            owner = TatwoSessionOwnerExpectationV1(
                provider: "codex",
                externalProviderSessionID: sessionID,
                workspacePath: chatWorkspacePath)
        case .v2ProjectOwnerBound:
            owner = TatwoSessionOwnerExpectationV1(
                provider: "codex",
                externalProviderSessionID: sessionID,
                workspacePath: projectWorkspacePath)
        }
        let attachment = try beginHistoricalCurrentForMigrationTest(
            sessionStore: sessionStore,
            goalStore: goalStore,
            dispatchRegistry: dispatchRegistry,
            mode: .m,
            scenarioProfileID: "coding",
            objective: "Exact predecessor objective \(suffix)",
            owner: owner,
            pointerKind: pointerKind)
        _ = try goalStore.updateStatus(
            contractID: attachment.contract.contractID,
            status: .running,
            authority: .revisionPromotion,
            reason: "fixture_running")

        let unrelated: TatwoWorkOSContractV1?
        let selectedContract: TatwoWorkOSContractV1
        switch selectedBinding {
        case .predecessor:
            unrelated = nil
            selectedContract = attachment.contract
        case .unrelatedTerminal:
            let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
                mode: .m,
                scenarioProfileID: "coding",
                objective: "Unrelated terminal objective \(suffix)",
                store: goalStore)
            _ = try goalStore.updateStatus(
                contractID: contract.contractID,
                status: .running,
                authority: .revisionPromotion,
                reason: "fixture_running")
            _ = try goalStore.updateStatus(
                contractID: contract.contractID,
                status: .failed)
            unrelated = contract
            selectedContract = contract
        case .unrelatedSucceeded:
            let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
                mode: .m,
                scenarioProfileID: "coding",
                objective: "Unrelated succeeded objective \(suffix)",
                store: goalStore)
            var record = try goalStore.requireIssuedContract(
                contract.contractID)
            record.status = .succeeded
            record.statusReason = "fixture_awaiting_goal_judge"
            record.updatedAt = Date()
            try writeFixtureGoalRecord(record, store: goalStore)
            unrelated = contract
            selectedContract = contract
        }

        let mirroredWorkspacePath: String
        switch pointerKind {
        case .v1ProjectOwnerMigration, .v2ProjectOwnerBound:
            mirroredWorkspacePath = projectWorkspacePath
        case .v1Standalone, .v2OwnerBound:
            mirroredWorkspacePath = chatWorkspacePath
        }
        let thread = TatwoNativeChatThread(
            id: threadID,
            title: "Existing confirmed Chat thread",
            codexSessionID: sessionID,
            mirroredCodexWorkspacePath: mirroredWorkspacePath,
            sourceMarker:
                TatwoNativeChatThreadSourceMarker.codexAppMirror,
            loopsConfig: loopsConfig(matching: selectedContract),
            workOSGoalID: selectedContract.goalID,
            workOSContractID: selectedContract.contractID,
            selectedThreadWorkOSContext: TatwoStoredObjectiveContextV2(
                identity: TatwoObjectiveIdentity.make(
                    selectedContract.objective)))
        switch pointerKind {
        case .v1ProjectOwnerMigration, .v2ProjectOwnerBound:
            try store.save(
                TatwoNativeChatStoreDocument(
                    projects: [
                        TatwoNativeChatProject(
                            name: "Goal revision project",
                            workdir: projectWorkspacePath,
                            threads: [thread])
                    ]))
        case .v1Standalone, .v2OwnerBound:
            try store.save(
                TatwoNativeChatStoreDocument(threads: [thread]))
        }

        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "GoalRevisionChatRebindTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            dispatchRegistry: dispatchRegistry)
        let artifact = TatwoGoalRevisionIssuerArtifactEvidence(
            identity: TatwoHumanGateIssuerArtifactIdentityV1(
                bundleIdentifier: "com.tatwo.ultrawork",
                teamIdentifier: "TESTTEAM",
                codeDirectoryHash: "fixture-cdhash",
                executableSHA256: String(repeating: "b", count: 64)),
            executableURL: root.appendingPathComponent(
                "TatwoUltraworkMac"))
        return Fixture(
            root: root,
            store: store,
            model: model,
            goalStore: goalStore,
            sessionStore: sessionStore,
            dispatchRegistry: dispatchRegistry,
            predecessor: attachment.contract,
            unrelatedTerminal: unrelated,
            artifact: artifact,
            now: Date(timeIntervalSince1970: 1_800_000_100))
    }

    /// Explicit historical V1/V2 fixture for owner-migration/rebind tests.
    ///
    /// This is not a formal current-session writer: production `beginCurrent`
    /// exclusively mints V3. The fixture initializes the formal lock boundary
    /// and Goal record, then deliberately saves legacy pointer bytes.
    private func beginHistoricalCurrentForMigrationTest(
        sessionStore: TatwoSessionStore,
        goalStore: TatwoGoalRunStore,
        dispatchRegistry: TatwoDispatchRegistry,
        mode: WorkModeID,
        scenarioProfileID: String,
        objective: String,
        owner: TatwoSessionOwnerExpectationV1?,
        pointerKind _: PointerKind
    ) throws -> TatwoSessionAttachmentV1 {
        let contract = try WorkOSFactory.projectContract(
            mode: mode,
            scenarioProfileID: scenarioProfileID,
            objective: objective)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: goalStore.directoryURL,
            contractID: contract.contractID)
        try goalStore.recordBegin(contract: contract)
        _ = try dispatchRegistry.recordManifest(
            TatwoExecutionManifestFactory.make(contract: contract))
        let ownerBinding = owner.map {
            TatwoSessionOwnerBindingV1(
                provider: $0.provider,
                externalProviderSessionID:
                    $0.externalProviderSessionID,
                workspacePath: $0.workspacePath,
                contractID: contract.contractID,
                goalID: contract.goalID)
        }
        let pointer = TatwoSessionPointer(
            schema: ownerBinding == nil
                ? "TatwoSessionPointerV1"
                : "TatwoSessionPointerV2",
            contractID: contract.contractID,
            goalID: contract.goalID,
            mode: contract.mode,
            scenario: contract.scenario,
            objective: contract.objective,
            ownerBinding: ownerBinding,
            generation: 1)
        try sessionStore.writeRawPointerFixtureForTesting(pointer)
        return TatwoSessionAttachmentV1(
            pointer: pointer,
            contract: contract,
            goalRecord:
                try goalStore.requireIssuedContract(contract.contractID))
    }

    private func goalRevisionInvalidation(
        fixture: Fixture,
        thread: TatwoNativeChatThread,
        successor: TatwoStoredGoalRun,
        successorContract: TatwoWorkOSContractV1
    ) throws -> TatwoNativeThreadBindingInvalidationV1 {
        let predecessor = try fixture.goalStore
            .requireIssuedContract(fixture.predecessor.contractID)
        let successorRecord = try fixture.goalStore
            .requireIssuedContract(successor.contractID)
        let sessionID = try XCTUnwrap(thread.codexSessionID)
        let workspacePath = try XCTUnwrap(
            thread.mirroredCodexWorkspacePath)
        return TatwoNativeThreadBindingInvalidationV1(
            reason: .goalRevisionChanged,
            threadID: thread.id,
            projectID: nil,
            previousBinding: TatwoNativeThreadBindingIdentityV1(
                contractID: fixture.predecessor.contractID,
                goalID: fixture.predecessor.goalID,
                goalRevision: predecessor.resolvedRevision),
            previousPointerGeneration:
                successorRecord.supersession?
                    .oldPointerGeneration,
            previousLoopsConfig: loopsConfig(
                matching: fixture.predecessor),
            desiredLoopsConfig: materializedLoopsConfig(
                matching: successorContract),
            expectedSuccessor:
                TatwoNativeThreadBindingIdentityV1(
                    contractID: successor.contractID,
                    goalID: successor.goalID,
                    goalRevision:
                        successorRecord.resolvedRevision),
            authorityProvenance:
                TatwoNativeThreadBindingAuthorityProvenanceV1(
                    provider: "codex",
                    externalProviderSessionID: sessionID,
                    workspacePath: workspacePath),
            createdAt: Date(timeIntervalSince1970: 1_800_000_101))
    }

    private func makeReloadedModel(
        _ fixture: Fixture
    ) -> ChatPageModel {
        ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "GoalRevisionChatRebindTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: fixture.store,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: fixture.root.appendingPathComponent(
                    "reloaded-journal-\(UUID().uuidString).json")),
            goalRunStore: fixture.goalStore,
            dispatchRegistry: fixture.dispatchRegistry)
    }

    private func writeFixtureGoalRecord(
        _ record: TatwoStoredGoalRun,
        store: TatwoGoalRunStore
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(
            to: store.fileURL(forContractID: record.contractID),
            options: [.atomic])
    }

    private func confirmRevision(
        _ fixture: Fixture
    ) throws -> TatwoGoalRevisionConfirmationResult {
        let challenge = try TatwoGoalRevisionCoordinator.prepare(
            selection: TatwoGoalRevisionSelection(
                mode: .xxl,
                scenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .exactXXLSolOpusLunaGrokScenarioID,
                scenarioBook: TatwoScenarioConfigDefaults.book,
                loopPresetID: "recommended",
                enabledLoopTemplateIDs: nil),
            goalStore: fixture.goalStore,
            sessionStore: fixture.sessionStore,
            challengeID: "chat-rebind-\(fixture.predecessor.contractID)",
            now: fixture.now,
            artifactProvider: { fixture.artifact })
        return try TatwoGoalRevisionCoordinator.confirm(
            challenge: challenge,
            newObjective:
                "Confirmed successor objective preserving the same Chat thread.",
            goalStore: fixture.goalStore,
            sessionStore: fixture.sessionStore,
            dispatchRegistry: fixture.dispatchRegistry,
            now: fixture.now,
            artifactProvider: { fixture.artifact })
    }

    private func loopsConfig(
        matching contract: TatwoWorkOSContractV1
    ) -> TatwoNativeThreadLoopsConfig {
        TatwoNativeThreadLoopsConfig(
            scenarioID: contract.scenario,
            mode: contract.mode,
            identitySummary: "confirmed revision fixture",
            tokenBudget: "fixture",
            primaryModelID:
                contract.routeBindingOverride?.primaryModelID,
            secondaryModelID:
                contract.routeBindingOverride?.secondaryModelID)
    }

    private func loopsConfig(
        matching goal: TatwoStoredGoalRun
    ) -> TatwoNativeThreadLoopsConfig {
        TatwoNativeThreadLoopsConfig(
            scenarioID: goal.scenario,
            mode: goal.mode,
            identitySummary: "confirmed revision fixture",
            tokenBudget: "fixture",
            primaryModelID:
                goal.routeBindingOverride?.primaryModelID,
            secondaryModelID:
                goal.routeBindingOverride?.secondaryModelID)
    }

    private func materializedLoopsConfig(
        matching contract: TatwoWorkOSContractV1
    ) -> TatwoNativeThreadLoopsConfig {
        let identitySummary = contract.identityBindings
            .compactMap { binding -> String? in
                guard let modelID = binding.modelID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !modelID.isEmpty
                else { return nil }
                return "\(binding.identity.rawValue)=\(modelID)"
            }
            .prefix(4)
            .joined(separator: "；")
        let modeConfig = TatwoScenarioConfigDefaults.book.modeConfig(
            scenarioID: contract.scenario,
            mode: contract.mode)
        return TatwoNativeThreadLoopsConfig(
            scenarioID: contract.scenario,
            mode: contract.mode,
            identitySummary: identitySummary.isEmpty
                ? "active contract \(contract.contractID)"
                : identitySummary,
            tokenBudget: modeConfig?.tokenBudget ?? "active contract",
            primaryModelID:
                contract.routeBindingOverride?.primaryModelID,
            secondaryModelID:
                contract.routeBindingOverride?.secondaryModelID)
    }

    private func waitForInitialStoreLoad(
        _ model: ChatPageModel
    ) async throws {
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }
}
