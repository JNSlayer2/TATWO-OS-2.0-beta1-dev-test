import Foundation
import XCTest

@testable import TatwoUltraworkCore

@testable import TatwoUltraworkMac

/// App-level cover for the 2026-08-27 staging61 live failure
/// (thread `thread:34b8b85a-5b68-476e-b346-81656733062e`,
/// run `339CAEFE-68FF-41A2-A4D2-811533023698`,
/// contract `contract-xxl-general-xxl-sol-opus5-luna-grok-exact-2cd42154892f`).
///
/// Three separate defects were observed in one turn:
/// 1. `/goal <objective>` from a GPT-5.6 Terra thread inherited a stale XXL
///    topology and switched the runner away from the composing route,
/// 2. that turn's `command` journal events were stamped `gpt-5.5` while its
///    `result` was stamped `gpt-5.6-terra`, and
/// 3. the goal ended `cancelled`/`superseded_before_dispatch` before dispatch,
///    yet a host mutation-capable runner still started and created files.
final class ChatGoalProvenanceAuthorityRegressionTests: XCTestCase {

    // MARK: 1 — stale XXL inheritance / model switch

    @MainActor
    func testOrdinaryGoalFromTerraThreadDropsStaleXXLTopology()
        async throws
    {
        let root = temporaryRoot("goal-stale-xxl")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        applyStaleNativeDevelopmentXXLTopology(to: model)
        XCTAssertTrue(model.collaborationIsEnabled)

        model.isRunning = true
        model.prompt = "/goal 在 sandbox 目錄完成 task_counter.py 與測試"
        model.commitOrActivateGoalFromPrompt()
        try await waitForGoalBinding(model)

        let diagnostic = diagnostics(model)
        XCTAssertEqual(model.selectedModel, "gpt-5.6-terra", diagnostic)
        XCTAssertNil(model.selectedThread?.loopsConfig, diagnostic)
        XCTAssertEqual(model.selectedWorkOSContract?.mode, .s, diagnostic)
        XCTAssertNotEqual(
            model.selectedWorkOSContract?.scenario,
            TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
            diagnostic)
        let leadModelIDs = (model.selectedWorkOSContract?.identityBindings ?? [])
            .filter { $0.identity == .lead }
            .compactMap(\.modelID)
            .map(TatwoGatewayDispatchCatalog.normalize)
        XCTAssertEqual(
            Set(leadModelIDs),
            Set([TatwoGatewayDispatchCatalog.normalize("gpt-5.6-terra")]),
            diagnostic)
    }

    /// Positive control: an explicit Ultrawork/XXL request in the same command
    /// still binds the exact native-development XXL topology.
    @MainActor
    func testExplicitUltraworkGoalStillBindsXXLTopology() async throws {
        let root = temporaryRoot("goal-explicit-xxl")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        model.isRunning = true
        model.prompt =
            "/goal ultrawork XXL 在 sandbox 目錄完成 task_counter.py 與測試"
        model.commitOrActivateGoalFromPrompt()
        try await waitForGoalBinding(model)

        let diagnostic = diagnostics(model)
        XCTAssertEqual(model.selectedWorkOSContract?.mode, .xxl, diagnostic)
        XCTAssertNotNil(model.selectedThread?.loopsConfig, diagnostic)
    }

    /// Positive control: the Plan canvas' explicit "Ultrawork collaboration →
    /// Goal" selection still binds an Ultrawork topology without naming it in
    /// the command text.
    @MainActor
    func testPlanCanvasUltraworkGoalStillBindsUltraworkTopology()
        async throws
    {
        let root = temporaryRoot("goal-plan-canvas-xxl")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"
        model.isRunning = true
        model.prompt = "/goal 在 sandbox 目錄完成 task_counter.py 與測試"
        model.commitOrActivateGoalFromPrompt(
            forceSingleModel: false,
            ultraworkExplicitlyRequested: true)
        try await waitForGoalBinding(model)

        let diagnostic = diagnostics(model)
        XCTAssertNotEqual(
            model.selectedWorkOSContract?.mode,
            .s,
            diagnostic)
        XCTAssertNotNil(model.selectedThread?.loopsConfig, diagnostic)
    }

    // MARK: 2 — command/result provenance split

    @MainActor
    func testCommandAndResultShareOneImmutableTurnProvenance() throws {
        let root = temporaryRoot("goal-provenance")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"

        let runID = "339CAEFE-68FF-41A2-A4D2-811533023698"
        let assistantID = UUID().uuidString
        stampTurn(
            on: model,
            assistantID: assistantID,
            runID: runID,
            modelID: "gpt-5.6-terra",
            runtimeAdapterID: TatwoChatRuntimeAdapter.codexExec.rawValue)

        // The live mid-turn mutation: the picker moved to gpt-5.5 while the
        // run kept executing on the frozen Terra route.
        model.selectedModel = "gpt-5.5"

        XCTAssertTrue(
            model.recordTranscriptActivity(
                commandActivity(turnID: assistantID),
                runID: runID))
        model.recordTranscriptResult(
            assistantID: assistantID,
            runID: runID,
            phase: .completed)

        let items = try XCTUnwrap(
            model.chatTranscriptJournal
                .turn(
                    threadID: try XCTUnwrap(
                        model.selectedSessionReference?.stableKey),
                    turnID: assistantID)?
                .items)
        let command = try XCTUnwrap(items.first { $0.kind == .command })
        let result = try XCTUnwrap(items.first { $0.kind == .result })
        XCTAssertEqual(command.source.model, "gpt-5.6-terra")
        XCTAssertEqual(command.source.model, result.source.model)
        XCTAssertEqual(command.source.runtime, result.source.runtime)
        XCTAssertEqual(command.source.source, result.source.source)
        XCTAssertEqual(
            command.source.runtime,
            TatwoChatRuntimeAdapter.codexExec.rawValue)
    }

    /// Pins the exact defect shape: without the frozen per-turn provenance the
    /// command event falls back to the mutable model picker and splits away
    /// from the result — `gpt-5.5` versus `gpt-5.6-terra`, as observed live.
    @MainActor
    func testWithoutTurnProvenanceCommandAttributionSplitsFromResult() throws {
        let root = temporaryRoot("goal-provenance-split")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()
        model.selectedModel = "gpt-5.6-terra"

        let runID = UUID().uuidString
        let assistantID = UUID().uuidString
        stampTurn(
            on: model,
            assistantID: assistantID,
            runID: runID,
            modelID: "gpt-5.6-terra",
            runtimeAdapterID: TatwoChatRuntimeAdapter.codexExec.rawValue)
        model.activeTurnExecutionProvenance = nil
        model.selectedModel = "gpt-5.5"

        XCTAssertTrue(
            model.recordTranscriptActivity(
                commandActivity(turnID: assistantID),
                runID: runID))
        model.recordTranscriptResult(
            assistantID: assistantID,
            runID: runID,
            phase: .completed)

        let items = try XCTUnwrap(
            model.chatTranscriptJournal
                .turn(
                    threadID: try XCTUnwrap(
                        model.selectedSessionReference?.stableKey),
                    turnID: assistantID)?
                .items)
        let command = try XCTUnwrap(items.first { $0.kind == .command })
        let result = try XCTUnwrap(items.first { $0.kind == .result })
        XCTAssertEqual(command.source.model, "gpt-5.5")
        XCTAssertEqual(result.source.model, "gpt-5.5")
        XCTAssertNotEqual(command.source.model, "gpt-5.6-terra")
    }

    // MARK: 3 — cancelled / superseded-before-dispatch mutation

    @MainActor
    func testSupersededBeforeDispatchGoalBlocksProviderCLIRunnerStart()
        throws
    {
        let root = temporaryRoot("goal-superseded-dispatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(root: root, goalStore: goalStore)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "staging61 superseded before dispatch",
            store: goalStore)
        model.newChat()
        bindSelectedThread(to: contract, on: model)
        model.selectedWorkOSContract = contract

        var cancelled = try goalStore.requireIssuedContract(
            contract.contractID)
        cancelled.status = .cancelled
        cancelled.statusReason = "superseded_before_dispatch"
        cancelled.updatedAt = Date()
        try writeGoalRecord(cancelled, to: goalStore)

        let command = providerCLICommand(root: root)
        let snapshot = snapshot(contractID: contract.contractID)
        XCTAssertEqual(
            model.lastMileGoalAuthorityBlocker(
                dispatchSnapshot: snapshot,
                command: command),
            "goal_terminal_before_dispatch status=cancelled reason=superseded_before_dispatch")

        let identity = DefaultChatDispatchService().startRuntime(
            model: model,
            command: command,
            nativePrompt: "建立 task_counter.py",
            dispatchSnapshot: snapshot,
            runID: UUID().uuidString,
            activityTurnID: UUID().uuidString,
            allowsNativeGovernanceFallback: false,
            nativeGovernanceFallbackCommand: nil,
            onEvent: { _ in })
        XCTAssertNil(
            identity,
            "a terminal-before-dispatch goal must not spawn a mutation-capable runner")
        XCTAssertEqual(
            model.lastNativeRuntimeStartBlocker,
            "goal_terminal_before_dispatch status=cancelled reason=superseded_before_dispatch")
    }

    /// Control: the same provider-CLI transport still starts while the goal
    /// holds authority.
    @MainActor
    func testRunningGoalStillPassesLastMileAuthorityGate() throws {
        let root = temporaryRoot("goal-running-dispatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(root: root, goalStore: goalStore)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "staging61 running control",
            store: goalStore)
        model.newChat()
        bindSelectedThread(to: contract, on: model)
        model.selectedWorkOSContract = contract

        var running = try goalStore.requireIssuedContract(contract.contractID)
        running.status = .running
        running.updatedAt = Date()
        try writeGoalRecord(running, to: goalStore)

        XCTAssertNil(
            model.lastMileGoalAuthorityBlocker(
                dispatchSnapshot: snapshot(contractID: contract.contractID),
                command: providerCLICommand(root: root)))
    }

    /// The last-mile authority source is the durable thread row that owns the
    /// physical turn, not whichever contract object the UI currently projects.
    @MainActor
    func testLastMileAuthorityIgnoresDifferentSelectedContractProjection()
        throws
    {
        let root = temporaryRoot("goal-thread-authority")
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(root: root, goalStore: goalStore)
        let turnContract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "turn-owned authority",
            store: goalStore)
        let projectedContract =
            try WorkOSFactory.issueDetachedFixtureForTesting(
                mode: .m,
                scenarioProfileID: "debug",
                objective: "unrelated UI projection",
                store: goalStore)
        model.newChat()
        bindSelectedThread(to: turnContract, on: model)
        model.selectedWorkOSContract = projectedContract

        var running = try goalStore.requireIssuedContract(
            turnContract.contractID)
        running.status = .running
        running.updatedAt = Date()
        try writeGoalRecord(running, to: goalStore)

        XCTAssertNil(
            model.lastMileGoalAuthorityBlocker(
                dispatchSnapshot: snapshot(
                    contractID: turnContract.contractID),
                command: providerCLICommand(root: root)))
    }

    /// A host-mutation turn whose owning thread lost its durable contract
    /// binding must fail closed even if the UI still projects that contract.
    @MainActor
    func testMissingTurnThreadBindingCannotBypassLastMileAuthority()
        throws
    {
        let root = temporaryRoot("goal-thread-authority-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let goalStore = TatwoGoalRunStore(
            directoryURL: root.appendingPathComponent("goals"))
        let model = makeModel(root: root, goalStore: goalStore)
        let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
            mode: .m,
            scenarioProfileID: "coding",
            objective: "missing durable thread binding",
            store: goalStore)
        model.newChat()
        model.selectedWorkOSContract = contract

        var running = try goalStore.requireIssuedContract(
            contract.contractID)
        running.status = .running
        running.updatedAt = Date()
        try writeGoalRecord(running, to: goalStore)

        XCTAssertEqual(
            model.lastMileGoalAuthorityBlocker(
                dispatchSnapshot: snapshot(contractID: contract.contractID),
                command: providerCLICommand(root: root)),
            "durable_contract_binding_missing status=running")
    }

    /// Nil binding is only a denial after a turn froze a Goal contract. Ordinary
    /// host-capable chat without any Goal binding must not be reclassified as a
    /// corrupt Goal turn.
    @MainActor
    func testUncontractedProviderCLITurnHasNoGoalAuthorityBlocker() {
        let root = temporaryRoot("ordinary-uncontracted-turn")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.newChat()

        XCTAssertNil(
            model.lastMileGoalAuthorityBlocker(
                dispatchSnapshot: snapshot(contractID: nil),
                command: providerCLICommand(root: root)))
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
                    "ChatGoalProvenanceAuthorityRegressionTests",
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
                anchorAuthority: GoalProvenanceTestAnchorAuthority()))
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-\(label)-\(UUID().uuidString)",
                isDirectory: true)
    }

    @MainActor
    private func bindSelectedThread(
        to contract: TatwoWorkOSContractV1,
        on model: ChatPageModel
    ) {
        guard let threadID = model.selectedThreadID,
              let index = model.document.threads.firstIndex(where: {
                  $0.id == threadID
              })
        else { return XCTFail("expected selected standalone thread") }
        model.document.threads[index].workOSContractID = contract.contractID
        model.document.threads[index].workOSGoalID = contract.goalID
    }

    /// Leaves the selected thread carrying the App-owned native-development
    /// XXL scenario an earlier `/plan` would have bound — the exact stale
    /// state the live thread was in when `/goal` was typed.
    @MainActor
    private func applyStaleNativeDevelopmentXXLTopology(
        to model: ChatPageModel
    ) {
        guard let threadID = model.selectedThreadID,
              let index = model.document.threads.firstIndex(where: {
                  $0.id == threadID
              })
        else { return XCTFail("expected a selected thread") }
        model.document.threads[index].loopsConfig =
            TatwoNativeThreadLoopsConfig(
                scenarioID: TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLSolOpusScenarioID,
                mode: .xxl,
                identitySummary: "stale native development topology",
                tokenBudget: "XXL",
                primaryModelID: "gpt-5.6-sol",
                secondaryModelID: "opus-5")
    }

    @MainActor
    private func stampTurn(
        on model: ChatPageModel,
        assistantID: String,
        runID: String,
        modelID: String,
        runtimeAdapterID: String
    ) {
        model.activeTurnExecutionProvenance = ChatTurnExecutionProvenance(
            runID: runID,
            turnID: assistantID,
            modelID: modelID,
            canonicalModelID: modelID,
            runtimeAdapterID: runtimeAdapterID,
            providerID: ChatTranscriptJournalAdapter
                .provenanceProviderID(modelID: modelID))
        model.activeAssistantID = assistantID
        model.messages.append(
            ChatMessage(
                id: assistantID,
                role: .assistant,
                text: "已建立三個檔案並跑完 unittest。",
                status: "completed",
                modelID: modelID,
                eventKind: .message,
                runtimeAdapterID: runtimeAdapterID,
                turnID: assistantID))
    }

    private func commandActivity(turnID: String) -> ChatActivityEventV1 {
        ChatActivityEventV1(
            id: "command-1",
            kind: .command,
            label: "Command",
            detail: #"/bin/zsh -lc "python3 -m unittest -v""#,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_001),
            status: .succeeded,
            turnID: turnID)
    }

    private func providerCLICommand(root: URL) -> ChatCLICommand {
        ChatCLICommand(
            engine: .codex,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: root,
            expectsJSON: false,
            capturesSessionID: false,
            runtimeAdapter: .codexExec,
            commandMode: .chat,
            nativeDevelopmentAccess: .mutation)
    }

    private func snapshot(contractID: String?) -> ChatTurnDispatchSnapshot {
        ChatTurnDispatchSnapshot(
            routeID: "gpt-5.6-terra",
            canonicalModelID: "gpt-5.6-terra",
            vendorModelID: "gpt-5.6-terra",
            phase: .loops,
            contractID: contractID,
            contractBindingID: nil,
            requestedEffort: nil,
            forwardedEffort: nil,
            effortOutcome: .noNativeEffortRequested,
            blocker: nil)
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
            "mode=\(model.selectedWorkOSContract?.mode.rawValue ?? "nil")",
            "scenario=\(model.selectedWorkOSContract?.scenario ?? "nil")",
            "selectedModel=\(model.selectedModel)",
            "loops=\(model.selectedThread?.loopsConfig?.scenarioID ?? "nil")",
        ].joined(separator: " ")
    }
}

private struct GoalProvenanceTestAnchorAuthority: TatwoPLGAnchorAuthority {
    func sign(_ material: String) -> String {
        "goal-provenance-test-anchor|\(material)"
    }

    func verify(_ signature: String, material: String) -> Bool {
        signature == sign(material)
    }
}
