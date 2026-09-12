import AppKit
import XCTest

@testable import TatwoUltraworkMac
@testable import TatwoUltraworkCore

final class ChatNewThreadShortcutTests: XCTestCase {
    func testShortcutCatalogMatchesCodexNewChatBindings() {
        XCTAssertEqual(
            TatwoNewChatShortcutCatalog.primaryKeyEquivalent,
            "n")
        XCTAssertEqual(
            TatwoNewChatShortcutCatalog.primaryModifierFlags,
            [.command])
        XCTAssertEqual(
            TatwoNewChatShortcutCatalog.alternateKeyEquivalent,
            "o")
        XCTAssertEqual(
            TatwoNewChatShortcutCatalog.alternateModifierFlags,
            [.command, .shift])
        XCTAssertTrue(
            TatwoNewChatShortcutCatalog.matchesAlternate(
                keyEquivalent: "o",
                modifierFlags: [.command, .shift]))
        XCTAssertFalse(
            TatwoNewChatShortcutCatalog.matchesAlternate(
                keyEquivalent: "o",
                modifierFlags: [.command]))
        XCTAssertFalse(
            TatwoNewChatShortcutCatalog.matchesAlternate(
                keyEquivalent: "o",
                modifierFlags: [.command, .shift, .option]))
    }

    func testMainMenuAndAlternateMonitorRouteBothShortcutsToOneAction() throws {
        let source = try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/AppShell.swift",
            repoRoot: ChatPageSourceScanner.repoRoot())

        XCTAssertTrue(source.contains("let fileMenu = NSMenu(title: \"檔案\")"))
        XCTAssertTrue(source.contains("withTitle: \"新聊天\""))
        XCTAssertTrue(
            source.contains(
                "keyEquivalent: TatwoNewChatShortcutCatalog.primaryKeyEquivalent"))
        XCTAssertTrue(
            source.contains(
                "#selector(requestNewChatFromShortcut(_:))"))
        XCTAssertTrue(
            source.contains(
                "TatwoNewChatShortcutCatalog.matchesAlternate(event)"))
        XCTAssertEqual(
            source.components(
                separatedBy: "requestNewChatFromShortcut(nil)")
                .count - 1,
            1)
        XCTAssertTrue(
            source.contains(
                "TatwoNewChatCommandCenter.shared.request()"))
    }

    func testFocusedComposerLeavesCommandShortcutsForTheAppCommandLayer()
        throws
    {
        let source = try ChatPageSourceScanner.readRelative(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageAppKitBridges.swift",
            repoRoot: ChatPageSourceScanner.repoRoot())
        let start = try XCTUnwrap(
            source.range(of: "private func handleFocusedKeyEvent"))
        let end = try XCTUnwrap(
            source.range(
                of: "override func draw",
                range: start.upperBound..<source.endIndex))
        let handler = String(source[start.lowerBound..<end.lowerBound])

        let commandPassThrough = try XCTUnwrap(
            handler.range(
                of:
                    "if !event.modifierFlags.intersection(blockedModifierMask).isEmpty"))
        let suggestionConsumption = try XCTUnwrap(
            handler.range(of: "if consumeAsSuggestionKey(event)"))
        XCTAssertLessThan(
            commandPassThrough.lowerBound,
            suggestionConsumption.lowerBound)
        XCTAssertTrue(
            handler[commandPassThrough.lowerBound..<suggestionConsumption.lowerBound]
                .contains("return event"))
    }

    @MainActor
    func testOneCommandRequestCreatesExactlyOneThread() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-new-chat-shortcut-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNewThreadShortcutTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false),
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: directory))
        try await waitForInitialStoreLoad(model)
        let commandCenter = TatwoNewChatCommandCenter()
        let registration = commandCenter.register {
            model.newChat()
        }
        defer {
            commandCenter.unregister(registration)
        }
        let originalCount = model.document.threads.count

        commandCenter.request()

        XCTAssertEqual(
            model.document.threads.count,
            originalCount + 1)
    }

    @MainActor
    func testNewChatFirstTurnIsAcceptedForClaudeGrokAndGPT()
        async throws
    {
        for routeID in ["opus5", "grok-build", "gpt-5.6-sol"] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "tatwo-new-chat-first-turn-\(routeID)-\(UUID().uuidString)",
                    isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
            }
            let seed = TatwoNativeChatThread(
                title: "active governed chat",
                loopsConfig: TatwoNativeThreadLoopsConfig(
                    scenarioID:
                        TatwoScenarioConfigDefaults
                            .exactXXLSolOpusLunaGrokScenarioID,
                    mode: .xxl,
                    identitySummary: "seed topology",
                    tokenBudget: "test"))
            let store = TatwoNativeChatStore(
                url: directory.appendingPathComponent("native-chat.json"),
                fallbackURLs: [],
                mirrorsToUnifiedLedger: false)
            try store.save(TatwoNativeChatStoreDocument(threads: [seed]))
            let model = ChatPageModel(
                environment: [
                    "XCTestConfigurationFilePath":
                        "ChatNewThreadShortcutTests",
                    "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                    "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
                ],
                store: store,
                transcriptJournalStore: ChatTranscriptJournalDiskStore(
                    fileURL: directory.appendingPathComponent("journal.json")),
                goalRunStore: TatwoGoalRunStore(directoryURL: directory))
            try await waitForInitialStoreLoad(model)

            let commandCenter = TatwoNewChatCommandCenter()
            let registration = commandCenter.register {
                model.newChat()
            }
            defer {
                commandCenter.unregister(registration)
            }
            commandCenter.request()
            let newThreadID = try XCTUnwrap(model.selectedThreadID)
            XCTAssertNotEqual(newThreadID, seed.id, routeID)
            XCTAssertNil(
                model.selectedThread?.loopsConfig,
                "Cmd-N must not carry an ownerless delegated topology: \(routeID)")
            model.setSingleModel(routeID)
            model.prompt = "新聊天首回合 \(routeID)"

            // Exercise the same acceptance boundary without launching a live
            // provider in a unit test. An already-running sibling turn makes
            // the new session's first turn enter the canonical queue.
            model.isRunning = true
            model.submitCurrentChatTurn()

            XCTAssertEqual(model.queuedChatTurnCount, 1, routeID)
            XCTAssertEqual(model.prompt, "", routeID)
            XCTAssertTrue(
                model.composerHint?.contains("已插入佇列") == true,
                model.composerHint ?? "missing accepted-turn queue hint: \(routeID)")
        }
    }

    @MainActor
    func testRejectedSubmitShowsCanonicalOwnerReason() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-new-chat-visible-owner-block-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let thread = TatwoNativeChatThread(
            title: "unbound collaboration",
            loopsConfig: TatwoNativeThreadLoopsConfig(
                scenarioID:
                    TatwoScenarioConfigDefaults
                        .exactXXLSolOpusLunaGrokScenarioID,
                mode: .xxl,
                identitySummary: "unbound",
                tokenBudget: "test"))
        let store = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try store.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatNewThreadShortcutTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: directory))
        try await waitForInitialStoreLoad(model)
        model.prompt = "不得靜默丟棄"

        model.submitCurrentChatTurn()

        XCTAssertEqual(model.prompt, "不得靜默丟棄")
        XCTAssertTrue(
            model.composerHint?.contains(
                "普通 Chat 不會建立新 Goal／Contract") == true,
            model.composerHint ?? "missing visible rejection")
    }

    @MainActor
    private func waitForInitialStoreLoad(_ model: ChatPageModel) async throws {
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }
}
