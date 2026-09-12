import Foundation
import XCTest

@testable import TatwoUltraworkCore

@testable import TatwoUltraworkMac

/// App-level cover for the two 2026-08-27 runtime-63 live staging blockers.
///
/// 1. Project-thread owner continuity — project `test`
///    (`<your-volume>/runtime/sandbox/test`), thread
///    `F0453782-09FC-45A7-804F-C856153AD290`. `/plan` succeeded on GPT-5.6
///    Terra medium, but the row had been persisted with **no** `sourceMarker`,
///    so `currentSessionCanonicalOwner(for:projectID:)` matched neither the
///    `userOwned` branch nor the standalone branch and returned nil. `/goal`
///    then fail-closed synchronously with
///    `目標未建立：Work OS contract 建立已停止：缺少明確 provider session/thread owner。`
///
/// 2. Ordinary `/plg` route continuity — thread
///    `4858FD76-5DDE-4B13-8E9E-667FEF59F881`, goal
///    `goal-xxl-general-xxl-sol-opus5-luna-grok-exact-24bf426f5d5e`. `/plg`
///    bound the native-development XXL scenario, `collaborationLevel` left
///    `.off`, and the view's "apply stored Ultrawork roles" hook wrote the
///    app-wide `UltraworkRoleConfiguration` defaults (`gpt-5.5` / `sonnet-5`)
///    into the row's `loopsConfig` **after** the XXL contract had been issued
///    for the same turn. The persisted row proves it: `primaryModelID` was
///    exactly `gpt-5.5` and `secondaryModelID` exactly `sonnet-5`, with
///    `bindingInvalidation reason=loopsConfigChanged` and the goal at
///    `cancelled`/`superseded_before_dispatch` in the same second as issuance.
///    The turn could therefore never establish a dispatch attempt:
///    `啟動失敗：runner authority 無法建立實體 attempt。
///    [goal_terminal_before_dispatch status=cancelled
///    reason=superseded_before_dispatch]`.
final class ChatProjectOwnerAndUltraworkRoleRegressionTests: XCTestCase {

    // MARK: 1 — project-thread owner continuity

    /// The exact live shape: a project row persisted without any
    /// `sourceMarker`. `/goal` must materialize the contract instead of
    /// stopping on "缺少明確 provider session/thread owner".
    @MainActor
    func testProjectThreadWithoutSourceMarkerMaterializesGoalContract()
        async throws
    {
        let root = temporaryRoot("project-owner-goal")
        defer { try? FileManager.default.removeItem(at: root) }
        let workdir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workdir,
            withIntermediateDirectories: true)
        let model = makeModel(root: root)
        let thread = TatwoNativeChatThread(
            title: "/plan 請規劃一個有明確終點的小型 Python 任務",
            codexSessionID: "01a043e4-e96d-7352-ae8b-4596636b1860",
            sourceMarker: nil,
            adapterSessionHandles: [
                TatwoNativeAdapterSessionHandle(
                    adapterID: "codex-exec",
                    modelID: "gpt-5.6-terra",
                    providerSessionID:
                        "01a043e4-e96d-7352-ae8b-4596636b1860"),
            ])
        let project = TatwoNativeChatProject(
            name: "test",
            workdir: workdir.path,
            threads: [thread])
        model.document.projects = [project]
        model.select(projectID: project.id, threadID: thread.id)
        XCTAssertNil(
            model.selectedThread?.sourceMarker,
            "fixture must reproduce the marker-less persisted row")

        model.selectedModel = "gpt-5.6-terra"
        model.isRunning = true
        model.prompt = "/goal 在專案目錄完成 task_counter.py 與測試"
        model.commitOrActivateGoalFromPrompt(forceSingleModel: true)
        try await waitForGoalBinding(model)

        let diagnostic = diagnostics(model)
        XCTAssertFalse(
            model.selectedWorkOSStateMessage.contains(
                "缺少明確 provider session/thread owner"),
            diagnostic)
        XCTAssertNotNil(model.selectedWorkOSContract, diagnostic)
        XCTAssertNotNil(model.selectedThread?.workOSGoalID, diagnostic)
        XCTAssertEqual(model.prompt, "", diagnostic)
    }

    /// The owner must be this exact row inside its own project workspace: no
    /// fallback to another thread and no synthesized provider session ID.
    @MainActor
    func testProjectThreadOwnerIsThisRowInsideItsProjectWorkspace()
        async throws
    {
        let root = temporaryRoot("project-owner-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let workdir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workdir,
            withIntermediateDirectories: true)
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(root: root, goalStore: goalStore)
        let otherThread = TatwoNativeChatThread(
            title: "另一列",
            sourceMarker: TatwoNativeChatThreadSourceMarker.userOwned)
        let thread = TatwoNativeChatThread(title: "專案列", sourceMarker: nil)
        let project = TatwoNativeChatProject(
            name: "test",
            workdir: workdir.path,
            threads: [thread, otherThread])
        model.document.projects = [project]
        model.select(projectID: project.id, threadID: thread.id)
        model.selectedModel = "gpt-5.6-terra"
        model.isRunning = true
        model.prompt = "/goal 在專案目錄完成 task_counter.py 與測試"
        model.commitOrActivateGoalFromPrompt(forceSingleModel: true)
        try await waitForGoalBinding(model)

        let diagnostic = diagnostics(model)
        let contractID = try XCTUnwrap(
            model.selectedWorkOSContract?.contractID,
            diagnostic)
        let record = try goalStore.requireIssuedContract(contractID)
        XCTAssertEqual(
            record.authorityInstanceDiscriminator,
            "provider:tatwo-chat|ownerKind:thread|sessionID:"
                + thread.id.uuidString.lowercased(),
            diagnostic)
        XCTAssertFalse(
            record.authorityInstanceDiscriminator?
                .contains(otherThread.id.uuidString.lowercased()) ?? false,
            diagnostic)
    }

    /// Negative control: an unresolvable project workdir must still fail
    /// closed on the owner gate rather than borrow the standalone workspace.
    @MainActor
    func testProjectThreadWithEmptyWorkdirStillFailsClosedOnOwner()
        async throws
    {
        let root = temporaryRoot("project-owner-empty-workdir")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        let thread = TatwoNativeChatThread(title: "專案列", sourceMarker: nil)
        let project = TatwoNativeChatProject(
            name: "test",
            workdir: "   ",
            threads: [thread])
        model.document.projects = [project]
        model.select(projectID: project.id, threadID: thread.id)
        model.selectedModel = "gpt-5.6-terra"
        model.isRunning = true
        model.prompt = "/goal 在專案目錄完成 task_counter.py 與測試"
        model.commitOrActivateGoalFromPrompt(forceSingleModel: true)
        for _ in 0..<40
        where !model.selectedWorkOSStateMessage.contains(
            "缺少明確 provider session/thread owner")
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertTrue(
            model.selectedWorkOSStateMessage.contains(
                "缺少明確 provider session/thread owner"),
            diagnostics(model))
        XCTAssertNil(model.selectedWorkOSContract, diagnostics(model))
    }

    /// Creation-site defense: rows the App creates under a project must carry
    /// the user-owned marker so the persisted shape matches the resolved
    /// owner from the first write.
    @MainActor
    func testProjectThreadCreatedFromCLIHandoffIsStampedUserOwned() throws {
        let root = temporaryRoot("project-thread-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        let session = TatwoNativeCLISession(
            name: "terminal",
            engine: .codex,
            cwd: root.path)
        let project = TatwoNativeChatProject(
            name: "test",
            workdir: root.path,
            sessions: [session])
        model.document.projects = [project]

        model.handoffCLISessionToThread(project: project, session: session)

        let created = try XCTUnwrap(
            model.document.projects.first(where: { $0.id == project.id })?
                .threads.first)
        XCTAssertEqual(
            created.sourceMarker,
            TatwoNativeChatThreadSourceMarker.userOwned)
    }

    // MARK: 2 — app-wide Ultrawork role memory is never row authority

    /// The exact live path: a row carrying a scenario-declared XXL topology
    /// must not have `gpt-5.5`/`sonnet-5` written into it by app-wide memory.
    @MainActor
    func testStoredUltraworkRolesNeverOverrideScenarioDeclaredTopology()
        throws
    {
        let root = temporaryRoot("ultrawork-roles-scenario")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        applyNativeDevelopmentXXLTopology(to: model)

        let applied = model.applyStoredUltraworkRoleDefaults(
            primaryModelID: UltraworkRoleConfiguration.defaultValue
                .primaryModelID,
            secondaryModelID: UltraworkRoleConfiguration.defaultValue
                .auxiliaryModelID(at: 0))

        XCTAssertFalse(applied)
        XCTAssertNil(model.selectedThread?.loopsConfig?.primaryModelID)
        XCTAssertNil(model.selectedThread?.loopsConfig?.secondaryModelID)
        XCTAssertNil(model.selectedThread?.bindingInvalidation)
        XCTAssertEqual(model.selectedModel, "gpt-5.6-terra")
    }

    /// A row already bound to an issued contract must never be mutated by
    /// app-wide memory: that mutation is what superseded the just-issued goal
    /// before the turn could establish a dispatch attempt.
    @MainActor
    func testStoredUltraworkRolesNeverSupersedeAnIssuedContract() throws {
        let root = temporaryRoot("ultrawork-roles-issued")
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(root: root, goalStore: goalStore)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "runtime-63 plg self-supersede",
            store: goalStore)
        bindContract(contract, to: model)

        let applied = model.applyStoredUltraworkRoleDefaults(
            primaryModelID: "gpt-5.5",
            secondaryModelID: "sonnet-5")

        XCTAssertFalse(applied)
        XCTAssertNil(model.selectedThread?.loopsConfig?.primaryModelID)
        XCTAssertNil(model.selectedThread?.bindingInvalidation)
        let record = try goalStore.requireIssuedContract(contract.contractID)
        XCTAssertEqual(record.status, .planned)
        XCTAssertNil(record.statusReason)
        XCTAssertEqual(
            model.selectedThread?.workOSContractID,
            contract.contractID)
    }

    /// Positive control: a row that declares no topology at all still gets the
    /// app-wide default seeded, and seeding never moves the composing route.
    @MainActor
    func testStoredUltraworkRolesStillSeedARowWithNoDeclaredTopology() throws {
        let root = temporaryRoot("ultrawork-roles-seed")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        setLoopsConfig(
            TatwoNativeThreadLoopsConfig(
                scenarioID: "runtime63-unbound-scenario",
                mode: .m,
                identitySummary: "no declared bindings",
                tokenBudget: "M",
                primaryModelID: nil,
                secondaryModelID: nil),
            on: model)

        let applied = model.applyStoredUltraworkRoleDefaults(
            primaryModelID: "gpt-5.5",
            secondaryModelID: "sonnet-5")

        XCTAssertTrue(applied)
        XCTAssertEqual(
            model.selectedThread?.loopsConfig?.primaryModelID,
            "gpt-5.5")
        XCTAssertEqual(
            model.selectedThread?.loopsConfig?.secondaryModelID,
            "sonnet-5")
        XCTAssertEqual(model.selectedModel, "gpt-5.6-terra")
    }

    // MARK: Fixtures

    @MainActor
    private func makeModel(
        root: URL,
        goalStore: TatwoGoalRunStore? = nil
    ) -> ChatPageModel {
        ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatProjectOwnerAndUltraworkRoleRegressionTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "1",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: root.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: goalStore
                ?? TatwoGoalRunStore(
                    directoryURL: root.appendingPathComponent("goals")),
            plgChainStore: TatwoPLGChainStore(
                directory: root.appendingPathComponent("plg-chains"),
                anchorAuthority: ProjectOwnerTestAnchorAuthority()))
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-\(label)-\(UUID().uuidString)",
                isDirectory: true)
    }

    @MainActor
    private func applyNativeDevelopmentXXLTopology(to model: ChatPageModel) {
        setLoopsConfig(
            TatwoNativeThreadLoopsConfig(
                scenarioID: TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
                mode: .xxl,
                identitySummary:
                    "Plan:主導=gpt-5.6-sol；Loops:副審=opus-5；Loops:sub=gpt-5.6-luna",
                tokenBudget: "XXL",
                primaryModelID: nil,
                secondaryModelID: nil),
            on: model)
    }

    @MainActor
    private func setLoopsConfig(
        _ config: TatwoNativeThreadLoopsConfig,
        on model: ChatPageModel
    ) {
        guard let threadID = model.selectedThreadID,
              let index = model.document.threads.firstIndex(where: {
                  $0.id == threadID
              })
        else { return XCTFail("expected a selected standalone thread") }
        model.document.threads[index].loopsConfig = config
    }

    @MainActor
    private func bindContract(
        _ contract: TatwoWorkOSContractV1,
        to model: ChatPageModel
    ) {
        guard let threadID = model.selectedThreadID,
              let index = model.document.threads.firstIndex(where: {
                  $0.id == threadID
              })
        else { return XCTFail("expected a selected standalone thread") }
        model.document.threads[index].loopsConfig =
            TatwoNativeThreadLoopsConfig(
                scenarioID: "runtime63-unbound-scenario",
                mode: .m,
                identitySummary: "issued contract row",
                tokenBudget: "M",
                primaryModelID: nil,
                secondaryModelID: nil)
        model.document.threads[index].workOSContractID = contract.contractID
        model.document.threads[index].workOSGoalID = contract.goalID
        model.selectedWorkOSContract = contract
    }

    @MainActor
    private func waitForGoalBinding(_ model: ChatPageModel) async throws {
        for _ in 0..<200
        where model.selectedThread?.workOSGoalID == nil
            && model.selectedWorkOSContract == nil
        {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @MainActor
    private func diagnostics(_ model: ChatPageModel) -> String {
        [
            "hint=\(model.composerHint ?? "nil")",
            "plgError=\(model.plgError ?? "nil")",
            "state=\(model.selectedWorkOSStateMessage)",
            "marker=\(model.selectedThread?.sourceMarker ?? "nil")",
            "contract=\(model.selectedWorkOSContract?.contractID ?? "nil")",
            "loops=\(model.selectedThread?.loopsConfig?.scenarioID ?? "nil")",
        ].joined(separator: " ")
    }
}

private struct ProjectOwnerTestAnchorAuthority: TatwoPLGAnchorAuthority {
    func sign(_ material: String) -> String {
        "project-owner-test-anchor|\(material)"
    }

    func verify(_ signature: String, material: String) -> Bool {
        signature == sign(material)
    }
}
