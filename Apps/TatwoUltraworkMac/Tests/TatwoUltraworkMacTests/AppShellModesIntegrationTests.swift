import Foundation
import Combine
import XCTest
@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class AppShellModesIntegrationTests: XCTestCase {
    func testAuthorityBootstrapProposalAutomaticallyPresentsConfirmationDialog()
        throws
    {
        let source = try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift",
            repoRoot: ChatPageSourceScanner.repoRoot())

        XCTAssertTrue(
            source.contains(
                "of: authorityBootstrapModel.pendingProposal?"))
        XCTAssertTrue(source.contains(".authoritySubjectDigest,"))
        XCTAssertTrue(
            source.contains(
                "showsAuthorityBootstrapConfirmation = true"))
    }

    func testMainMenuKeepsChatAndModesReachableWithoutOpeningAnotherApp() throws {
        let source = try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift",
            repoRoot: ChatPageSourceScanner.repoRoot())

        XCTAssertTrue(source.contains("let navigateMenu = NSMenu(title: \"前往\")"))
        XCTAssertTrue(source.contains("withTitle: \"對話\""))
        XCTAssertTrue(source.contains("keyEquivalent: \"1\""))
        XCTAssertTrue(source.contains("withTitle: \"工作模式\""))
        XCTAssertTrue(source.contains("keyEquivalent: \"2\""))
        XCTAssertTrue(source.contains("#selector(openWorkOSPageFromMenu(_:))"))
        XCTAssertTrue(
            source.contains(
                "name: .tatwoOpenWorkOSWindow"))
    }

    func testModesAuthorityKeepsValidatedIssuedContractAvailableForRevisionWhenBindingsDrift()
        throws
    {
        try withStores { goalStore, sessionStore in
            let scenarioID =
                TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID
            let attachment = try beginFormalCurrent(
                sessionStore: sessionStore,
                goalStore: goalStore,
                mode: .xxl,
                scenarioProfileID: scenarioID,
                objective: "Four-binding issued Goal needs six-binding revision",
                scenarioBook: legacyFourBindingFableGrokBook())
            XCTAssertEqual(attachment.contract.identityBindings.count, 4)

            let resolution = TatwoModesIssuedAuthorityResolver.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book)

            XCTAssertEqual(
                resolution.contract?.contractID,
                attachment.contract.contractID)
            XCTAssertEqual(resolution.contract?.identityBindings.count, 4)
            guard case .revisionRequired =
                resolution.integrityState
            else {
                return XCTFail(
                    "validated issuance drift must require revision, got "
                    + "\(resolution.integrityState)")
            }
            let presentation = ModesScenarioAuthorityPresentation.make(
                previewMode: .xxl,
                previewScenarioProfileID: scenarioID,
                scenarioBook: TatwoScenarioConfigDefaults.book,
                issuedContract: resolution.contract,
                issuedIntegrityState: resolution.integrityState)
            XCTAssertTrue(presentation.canRequestGoalRevision)
        }
    }

    func testModesPreviewFailureDoesNotLeakPartialContractOrPlan() {
        let presentation = ModesScenarioAuthorityPresentation.make(
            previewMode: .m,
            previewScenarioProfileID: "missing-scenario-profile",
            scenarioBook: TatwoScenarioConfigDefaults.book,
            issuedContract: nil,
            issuedIntegrityState: .noPointer
        )

        XCTAssertNil(presentation.previewContract)
        XCTAssertNil(presentation.previewModePlan)
        XCTAssertFalse(
            presentation.previewIssue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
        )
    }

    func testModesAuthorityReportsNoPointerWithoutInventingIssuedContract() {
        withStores { goalStore, sessionStore in
            let resolution = TatwoModesIssuedAuthorityResolver.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book
            )

            XCTAssertNil(resolution.contract)
            XCTAssertEqual(resolution.integrityState, .noPointer)
        }
    }

    func testModesAuthorityUsesExactValidatedCurrentSessionContract() throws {
        try withStores { goalStore, sessionStore in
            let attachment = try beginFormalCurrent(
                sessionStore: sessionStore,
                goalStore: goalStore,
                mode: .xxl,
                scenarioProfileID: "coding",
                objective: "Modes page issued authority"
            )

            let resolution = TatwoModesIssuedAuthorityResolver.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book
            )

            XCTAssertEqual(resolution.contract, attachment.contract)
            XCTAssertEqual(resolution.integrityState, .validated)
        }
    }

    func testModesAuthorityFailsClosedForInvalidCurrentSessionPointer() throws {
        try withStores { goalStore, sessionStore in
            let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
                mode: .m,
                scenarioProfileID: "coding",
                objective: "Invalid Modes pointer must block",
                store: goalStore
            )
            try sessionStore.writeRawPointerFixtureForTesting(
                TatwoSessionPointer(
                    schema: "TatwoSessionPointerV0",
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: contract.objective
                )
            )

            let resolution = TatwoModesIssuedAuthorityResolver.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book
            )

            XCTAssertNil(resolution.contract)
            guard case .blocked(let issue) = resolution.integrityState else {
                return XCTFail("invalid current-session must be blocked")
            }
            XCTAssertTrue(issue.contains("Unsupported current-session pointer schema"))
        }
    }

    func testModesAuthorityFailsClosedForTamperedAuthorityIntent() throws {
        try withStores { goalStore, sessionStore in
            let attachment = try beginFormalCurrent(
                sessionStore: sessionStore,
                goalStore: goalStore,
                mode: .xxl,
                scenarioProfileID:
                    TatwoScenarioConfigDefaults
                        .nativeDevelopmentXXLFableGrokScenarioID,
                objective: "Tampered authority intent must stay blocked"
            )
            let transactionID = try XCTUnwrap(
                attachment.pointer.authorityTransactionID)
            let intentURL = goalStore.directoryURL
                .appendingPathComponent(
                    "goal-authority-transactions",
                    isDirectory: true)
                .appendingPathComponent(transactionID, isDirectory: true)
                .appendingPathComponent(
                    "00-intent.json",
                    isDirectory: false)
            var tampered = try Data(contentsOf: intentURL)
            tampered.append(0x20)
            try tampered.write(to: intentURL, options: [.atomic])

            let resolution = TatwoModesIssuedAuthorityResolver.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book)

            XCTAssertNil(resolution.contract)
            guard case .blocked = resolution.integrityState else {
                return XCTFail("tampered authority intent must remain blocked")
            }
        }
    }

    func testPanelFirstFrameUsesExactValidatedCurrentSessionPresentation() throws {
        try withStores { goalStore, sessionStore in
            let attachment = try beginFormalCurrent(
                sessionStore: sessionStore,
                goalStore: goalStore,
                mode: .xxl,
                scenarioProfileID: "coding",
                objective: "Modes first-frame authority"
            )

            let initialState = TatwoPanelModesInitialAuthority.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book
            )
            let presentation = ModesScenarioAuthorityPresentation.make(
                previewMode: .xxl,
                previewScenarioProfileID: "coding",
                scenarioBook: TatwoScenarioConfigDefaults.book,
                issuedContract: initialState.contract,
                issuedIntegrityState: initialState.integrityState
            )

            XCTAssertEqual(initialState.contract, attachment.contract)
            XCTAssertEqual(initialState.integrityState, .validated)
            XCTAssertEqual(presentation.issuedContract, attachment.contract)
            XCTAssertEqual(presentation.issuedIntegrityState, .validated)
            XCTAssertNil(presentation.mismatchMessage)
        }
    }

    func testPanelFirstFrameFailsClosedForInvalidCurrentSessionPointer() throws {
        try withStores { goalStore, sessionStore in
            let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
                mode: .m,
                scenarioProfileID: "coding",
                objective: "Invalid first-frame Modes pointer must block",
                store: goalStore
            )
            try sessionStore.writeRawPointerFixtureForTesting(
                TatwoSessionPointer(
                    schema: "TatwoSessionPointerV0",
                    contractID: contract.contractID,
                    goalID: contract.goalID,
                    mode: contract.mode,
                    scenario: contract.scenario,
                    objective: contract.objective
                )
            )

            let initialState = TatwoPanelModesInitialAuthority.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book
            )
            let presentation = ModesScenarioAuthorityPresentation.make(
                previewMode: .m,
                previewScenarioProfileID: "coding",
                scenarioBook: TatwoScenarioConfigDefaults.book,
                issuedContract: initialState.contract,
                issuedIntegrityState: initialState.integrityState
            )

            XCTAssertNil(initialState.contract)
            guard case .blocked(let issue) = initialState.integrityState else {
                return XCTFail("invalid current-session must block the first frame")
            }
            XCTAssertTrue(issue.contains("Unsupported current-session pointer schema"))
            XCTAssertNil(presentation.issuedContract)
            XCTAssertEqual(presentation.issuedIntegrityState, .blocked(issue))
        }
    }

    @MainActor
    func testIssuedAuthorityMonitorObservesPointerAndGoalRunDirectoryMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-modes-authority-monitor-\(UUID().uuidString)",
            isDirectory: true
        )
        let goals = root.appendingPathComponent("goals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: goals,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = TatwoModesIssuedAuthorityMonitor(stateDirectoryURL: root)
        let pointerMutation = expectation(description: "current-session mutation observed")
        let goalMutation = expectation(description: "GoalRun mutation observed")
        var observedRevisions: [UInt64] = []
        var cancellable: AnyCancellable?
        cancellable = monitor.$revision
            .dropFirst()
            .sink { revision in
                observedRevisions.append(revision)
                if observedRevisions.count == 1 {
                    pointerMutation.fulfill()
                } else if observedRevisions.count == 2 {
                    goalMutation.fulfill()
                }
            }

        try Data("pointer".utf8).write(
            to: root.appendingPathComponent("current-session.json"),
            options: .atomic
        )
        await fulfillment(of: [pointerMutation], timeout: 2)

        try Data("goal".utf8).write(
            to: goals.appendingPathComponent("contract-monitor.json"),
            options: .atomic
        )
        await fulfillment(of: [goalMutation], timeout: 2)

        XCTAssertGreaterThanOrEqual(monitor.revision, 2)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testIssuedAuthorityMonitorBootstrapsMissingStateAndConverges() async throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-modes-bootstrap-\(UUID().uuidString)",
            isDirectory: true)
        let state = appSupport.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let monitor = TatwoModesIssuedAuthorityMonitor(
            stateDirectoryURL: state,
            debounceInterval: 0.05)
        XCTAssertEqual(monitor.watchedDirectoryPaths, [appSupport.path])

        let revisionAdvanced = expectation(
            description: "bootstrap ancestor observes first durable state")
        var cancellable: AnyCancellable?
        cancellable = monitor.$revision
            .dropFirst()
            .sink { _ in revisionAdvanced.fulfill() }

        let goalStore = TatwoGoalRunStore(directoryURL: state)
        let sessionStore = TatwoSessionStore(directoryURL: state)
        let attachment = try beginFormalCurrent(
            sessionStore: sessionStore,
            goalStore: goalStore,
            mode: .m,
            scenarioProfileID: "coding",
            objective: "bootstrap missing state")

        await fulfillment(of: [revisionAdvanced], timeout: 2)
        XCTAssertTrue(monitor.watchedDirectoryPaths.contains(state.path))
        XCTAssertTrue(
            monitor.watchedDirectoryPaths.contains(
                state.appendingPathComponent("goals", isDirectory: true).path))
        XCTAssertFalse(monitor.watchedDirectoryPaths.contains(appSupport.path))

        let resolution = TatwoModesIssuedAuthorityResolver.resolve(
            environment: [:],
            stateDirectoryURL: monitor.stateDirectoryURL,
            scenarioBook: TatwoScenarioConfigDefaults.book)
        XCTAssertEqual(resolution.contract, attachment.contract)
        XCTAssertEqual(resolution.integrityState, .validated)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testIssuedAuthorityMonitorRecoversAfterStateRenameAndRecreation() async throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-modes-recreate-\(UUID().uuidString)",
            isDirectory: true)
        let state = appSupport.appendingPathComponent("state", isDirectory: true)
        let archivedState =
            appSupport.appendingPathComponent("state-archived", isDirectory: true)
        let initialGoalStore = TatwoGoalRunStore(directoryURL: state)
        let initialSessionStore = TatwoSessionStore(directoryURL: state)
        _ = try beginFormalCurrent(
            sessionStore: initialSessionStore,
            goalStore: initialGoalStore,
            mode: .m,
            scenarioProfileID: "coding",
            objective: "state before rename")
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let monitor = TatwoModesIssuedAuthorityMonitor(
            stateDirectoryURL: state,
            debounceInterval: 0.05)
        let renamed = expectation(description: "state rename observed")
        var didFulfillRenamed = false
        var renameCancellable: AnyCancellable?
        renameCancellable = monitor.$revision
            .dropFirst()
            .sink { _ in
                guard !didFulfillRenamed else { return }
                didFulfillRenamed = true
                renamed.fulfill()
            }

        try FileManager.default.moveItem(at: state, to: archivedState)
        await fulfillment(of: [renamed], timeout: 2)
        XCTAssertEqual(monitor.watchedDirectoryPaths, [appSupport.path])
        withExtendedLifetime(renameCancellable) {}

        let recreated = expectation(description: "state recreation observed")
        var didFulfillRecreated = false
        var recreateCancellable: AnyCancellable?
        recreateCancellable = monitor.$revision
            .dropFirst()
            .sink { revision in
                guard revision >= 2, !didFulfillRecreated else { return }
                didFulfillRecreated = true
                recreated.fulfill()
            }
        let recreatedGoalStore = TatwoGoalRunStore(directoryURL: state)
        let recreatedSessionStore = TatwoSessionStore(directoryURL: state)
        let attachment = try beginFormalCurrent(
            sessionStore: recreatedSessionStore,
            goalStore: recreatedGoalStore,
            mode: .xl,
            scenarioProfileID: "coding",
            objective: "state after recreation")

        await fulfillment(of: [recreated], timeout: 2)
        XCTAssertTrue(monitor.watchedDirectoryPaths.contains(state.path))
        XCTAssertFalse(monitor.watchedDirectoryPaths.contains(appSupport.path))
        XCTAssertEqual(
            TatwoModesIssuedAuthorityResolver.resolve(
                environment: [:],
                stateDirectoryURL: monitor.stateDirectoryURL,
                scenarioBook: TatwoScenarioConfigDefaults.book
            ).contract,
            attachment.contract)
        withExtendedLifetime(recreateCancellable) {}
    }

    @MainActor
    func testIssuedAuthorityMonitorCoalescesVnodeBurst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-modes-authority-burst-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = TatwoModesIssuedAuthorityMonitor(
            stateDirectoryURL: root,
            debounceInterval: 0.1)
        let mutation = expectation(description: "burst coalesced")
        var cancellable: AnyCancellable?
        cancellable = monitor.$revision
            .dropFirst()
            .sink { _ in mutation.fulfill() }

        let pointer = root.appendingPathComponent("current-session.json")
        for index in 0..<8 {
            try Data("pointer-\(index)".utf8).write(
                to: pointer,
                options: .atomic)
        }

        await fulfillment(of: [mutation], timeout: 2)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(monitor.revision, 1)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testIssuedAuthorityResolverReadDoesNotAdvanceMonitorRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-app-shell-modes-read-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(directoryURL: root)
        let sessionStore = TatwoSessionStore(directoryURL: root)
        _ = try beginFormalCurrent(
            sessionStore: sessionStore,
            goalStore: goalStore,
            mode: .m,
            scenarioProfileID: "coding",
            objective: "read-only authority resolution"
        )
        let monitor = TatwoModesIssuedAuthorityMonitor(
            stateDirectoryURL: goalStore.directoryURL,
            debounceInterval: 0.05)

        for _ in 0..<20 {
            let resolution = TatwoModesIssuedAuthorityResolver.resolve(
                environment: [:],
                goalStore: goalStore,
                sessionStore: sessionStore,
                scenarioBook: TatwoScenarioConfigDefaults.book)
            XCTAssertEqual(resolution.integrityState, .validated)
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(monitor.revision, 0)
    }

    func testIssuedAuthorityCoordinatorSerializesOverlappingResolution() async {
        let coordinator = TatwoModesIssuedAuthorityResolutionCoordinator()
        let probe = ResolutionConcurrencyProbe()

        async let first = coordinator.resolve {
            probe.run(delay: 0.12)
        }
        async let second = coordinator.resolve {
            probe.run(delay: 0.02)
        }
        _ = await (first, second)

        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertEqual(probe.completedCount, 2)
    }

    func testIssuedAuthorityCoordinatorDropsCancelledQueuedResolution() async {
        let coordinator = TatwoModesIssuedAuthorityResolutionCoordinator()
        let activeProbe = ResolutionConcurrencyProbe()
        let cancelledProbe = ResolutionConcurrencyProbe()

        let first = Task {
            await coordinator.resolve {
                activeProbe.run(delay: 0.15)
            }
        }
        for _ in 0..<100 where activeProbe.currentActiveCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(activeProbe.currentActiveCount, 1)

        let cancelled = Task {
            await coordinator.resolve {
                cancelledProbe.run(delay: 0)
            }
        }
        cancelled.cancel()

        _ = await first.value
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(cancelledProbe.completedCount, 0)
    }

    func testIssuedAuthorityStaleOrCancelledCompletionCannotApply() {
        XCTAssertTrue(
            TatwoModesIssuedAuthorityResolutionCoordinator.shouldApply(
                expectedRevision: 7,
                currentRevision: 7,
                isCancelled: false))
        XCTAssertFalse(
            TatwoModesIssuedAuthorityResolutionCoordinator.shouldApply(
                expectedRevision: 7,
                currentRevision: 8,
                isCancelled: false))
        XCTAssertFalse(
            TatwoModesIssuedAuthorityResolutionCoordinator.shouldApply(
                expectedRevision: 7,
                currentRevision: 7,
                isCancelled: true))
    }

    func testIssuedAuthoritySemanticNoOpDoesNotRequireAssignment() {
        let unchanged = TatwoModesIssuedAuthorityResolution(
            contract: nil,
            integrityState: .noPointer)
        XCTAssertFalse(
            TatwoModesIssuedAuthorityResolutionCoordinator.shouldAssign(
                currentContract: nil,
                currentIntegrityState: .noPointer,
                resolved: unchanged))
        XCTAssertTrue(
            TatwoModesIssuedAuthorityResolutionCoordinator.shouldAssign(
                currentContract: nil,
                currentIntegrityState: .blocked("changed"),
                resolved: unchanged))
    }

    func testIssuedAuthorityRootBoundResolutionIgnoresConflictingEnvironmentRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-modes-root-bound-\(UUID().uuidString)",
            isDirectory: true)
        let monitoredState = root.appendingPathComponent("monitored", isDirectory: true)
        let conflictingState =
            root.appendingPathComponent("conflicting", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let monitoredGoalStore = TatwoGoalRunStore(directoryURL: monitoredState)
        let monitoredAttachment = try beginFormalCurrent(
            sessionStore: TatwoSessionStore(directoryURL: monitoredState),
            goalStore: monitoredGoalStore,
            mode: .m,
            scenarioProfileID: "coding",
            objective: "monitor-selected state")
        let conflictingGoalStore = TatwoGoalRunStore(directoryURL: conflictingState)
        _ = try beginFormalCurrent(
            sessionStore: TatwoSessionStore(directoryURL: conflictingState),
            goalStore: conflictingGoalStore,
            mode: .xl,
            scenarioProfileID: "coding",
            objective: "environment-selected state")

        let resolution = TatwoModesIssuedAuthorityResolver.resolve(
            environment: ["TATWO_ULTRAWORK_STATE_DIR": conflictingState.path],
            stateDirectoryURL: monitoredState,
            scenarioBook: TatwoScenarioConfigDefaults.book)

        XCTAssertEqual(resolution.contract, monitoredAttachment.contract)
        XCTAssertEqual(resolution.integrityState, .validated)
    }

    private func withStores(
        _ body: (TatwoGoalRunStore, TatwoSessionStore) throws -> Void
    ) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tatwo-app-shell-modes-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(
            TatwoGoalRunStore(directoryURL: root),
            TatwoSessionStore(directoryURL: root)
        )
    }

    private func beginFormalCurrent(
        sessionStore: TatwoSessionStore,
        goalStore: TatwoGoalRunStore,
        mode: WorkModeID,
        scenarioProfileID: String,
        objective: String,
        scenarioBook: TatwoScenarioConfigBookV1 =
            TatwoScenarioConfigDefaults.book
    ) throws -> TatwoSessionAttachmentV1 {
        try FileManager.default.createDirectory(
            at: goalStore.directoryURL,
            withIntermediateDirectories: true)
        let registry = TatwoDispatchRegistry(
            directoryURL: goalStore.directoryURL)
        let owner = TatwoSessionOwnerExpectationV1(
            provider: "tatwo-app-test",
            externalProviderSessionID:
                "app-shell-modes-\(objective)",
            workspacePath: goalStore.directoryURL.path)
        let contract = try WorkOSFactory.projectContract(
            mode: mode,
            scenarioProfileID: scenarioProfileID,
            objective: objective,
            scenarioBook: scenarioBook)
        _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
            goalStoreRoot: goalStore.directoryURL,
            contractID: contract.contractID)
        return try sessionStore.beginCurrent(
            mode: mode,
            scenarioProfileID: scenarioProfileID,
            objective: objective,
            scenarioBook: scenarioBook,
            owner: .session(owner),
            goalStore: goalStore,
            dispatchRegistry: registry)
    }

    private func legacyFourBindingFableGrokBook()
        -> TatwoScenarioConfigBookV1
    {
        var book = TatwoScenarioConfigDefaults.book
        let scenarioID =
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID
        guard let scenarioIndex = book.scenarios.firstIndex(
            where: { $0.id == scenarioID }),
            var modeConfig = book.scenarios[scenarioIndex].modeConfigs[.xxl]
        else {
            return book
        }
        modeConfig.bindings.removeAll {
            $0.id
                == "general-xxl-native-development-loops-supervisor-fable5"
                || $0.id
                    == "general-xxl-native-development-loops-verifier-fable5"
        }
        book.scenarios[scenarioIndex].modeConfigs[.xxl] = modeConfig
        return book
    }
}

private final class ResolutionConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumActive = 0
    private var completions = 0

    var maximumActiveCount: Int {
        lock.withLock { maximumActive }
    }

    var completedCount: Int {
        lock.withLock { completions }
    }

    var currentActiveCount: Int {
        lock.withLock { activeCount }
    }

    func run(delay: TimeInterval) -> TatwoModesIssuedAuthorityResolution {
        lock.withLock {
            activeCount += 1
            maximumActive = max(maximumActive, activeCount)
        }
        Thread.sleep(forTimeInterval: delay)
        lock.withLock {
            activeCount -= 1
            completions += 1
        }
        return TatwoModesIssuedAuthorityResolution(
            contract: nil,
            integrityState: .noPointer)
    }
}
