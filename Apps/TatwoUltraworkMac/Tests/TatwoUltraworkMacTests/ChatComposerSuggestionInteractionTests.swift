import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ChatComposerSuggestionInteractionTests: XCTestCase {
    private var repoRoot: URL {
        ChatPageSourceScanner.repoRoot()
    }

    private var chatPageSource: String {
        get throws {
            try ChatPageSourceScanner.combinedSource(repoRoot: repoRoot)
        }
    }

    func testNextAndPreviousSelectionMatchSkillAndSlashKeyboardSemantics() {
        XCTAssertEqual(
            ChatComposerSuggestionSelection.next(current: nil, count: 4),
            0)
        XCTAssertEqual(
            ChatComposerSuggestionSelection.next(current: 0, count: 4),
            1)
        XCTAssertEqual(
            ChatComposerSuggestionSelection.next(current: 3, count: 4),
            3)
        XCTAssertNil(
            ChatComposerSuggestionSelection.previous(current: 0, count: 4))
        XCTAssertEqual(
            ChatComposerSuggestionSelection.previous(current: 2, count: 4),
            1)
    }

    func testCanonicalTatwoUltraworkAppearsInDollarSkillSuggestions() throws {
        let suggestions = ChatComposerSkillCatalog.suggestions(
            in: TatwoPluginRegistryBookV1(),
            query: "tatwo")

        let canonical = try XCTUnwrap(
            suggestions.first { $0.id == "tatwo-ultrawork" })
        XCTAssertEqual(canonical.kind, .skill)
    }

    func testCanonicalTatwoUltraworkIsVisibleWhenDollarQueryIsEmpty() {
        let suggestions = ChatComposerSkillCatalog.suggestions(
            in: TatwoPluginRegistryBookV1(),
            query: "")

        XCTAssertTrue(suggestions.contains { $0.id == "tatwo-ultrawork" })
    }

    func testPlanInteractionDoesNotAppendGoalOrPLGLifecyclePromptContext() {
        XCTAssertFalse(
            ChatLifecyclePromptContextPolicy.shouldAppend(
                interactionMode: .plan))
        XCTAssertTrue(
            ChatLifecyclePromptContextPolicy.shouldAppend(
                interactionMode: .standard))
    }

    func testOrdinaryMCPDoesNotLeakIntoDollarSkillSuggestions() {
        let suggestions = ChatComposerSkillCatalog.suggestions(
            in: TatwoPluginRegistryBookV1(),
            query: "chatgpt-pro")

        XCTAssertFalse(suggestions.contains { $0.id == "chatgpt-pro-mcp" })
    }

    func testSlashSuggestionsDisappearAfterCommandGetsAnArgument() {
        XCTAssertEqual(
            ChatComposerSlashCatalog.matches(prompt: "/pl").map(\.command),
            ["/plg", "/plan"])
        XCTAssertEqual(
            ChatComposerSlashCatalog.matches(prompt: "/plan").map(\.command),
            ["/plan"])
        XCTAssertTrue(
            ChatComposerSlashCatalog.matches(prompt: "/plan 修正鍵盤").isEmpty)
    }

    func testSelectingSlashCommandOnlyInsertsItBeforeExecution() {
        XCTAssertEqual(
            ChatComposerSlashCatalog.inserting(command: "/plan", into: "/pl"),
            "/plan ")
        XCTAssertEqual(
            ChatComposerSlashCatalog.inserting(command: "/goal", into: "/"),
            "/goal ")
    }

    func testPlanAndGoalContinueThroughTheSameChatTurnLikeCodex() throws {
        let source = try chatPageSource

        let planSection = try XCTUnwrap(
            source.slice(
                from: "func triggerPLGFromPrompt()",
                through: "func startPLGRun(objective: String)"))
        XCTAssertTrue(planSection.contains("guard !obj.isEmpty"))
        XCTAssertTrue(planSection.contains("submitCurrentChatTurn(applyPromptCollaboration: false)"))

        let goalSection = try XCTUnwrap(
            source.slice(
                from: "func commitPLGGoalFromPrompt()",
                through: "func triggerDistillFromPrompt()"))
        XCTAssertFalse(goalSection.contains("開始執行已確認的計畫"))
        XCTAssertTrue(goalSection.contains(
            "confirmPLGPlanAndStartLoops("))
        XCTAssertTrue(goalSection.contains(
            "nativeTaskOverride: note.isEmpty ? nil : note"))
        XCTAssertTrue(goalSection.contains("selectedWorkOSContract?.objective"))
        XCTAssertTrue(goalSection.contains(
            "beginSelectedNativeDevelopmentDispatch("))
        XCTAssertTrue(goalSection.contains(
            "selectedModelID: selectedModelID"))
        XCTAssertTrue(goalSection.contains("prompt = nativeTask"))
        XCTAssertTrue(goalSection.contains("submitCurrentChatTurn(applyPromptCollaboration: false)"))
        XCTAssertTrue(goalSection.contains("guard advancePLGFromPlanning()"))
        XCTAssertTrue(goalSection.contains("PLG 未能進入 Goal"))
        XCTAssertTrue(goalSection.contains("requestOpenLoopsPanel = true"))

        XCTAssertTrue(source.contains("if isPlanModeEnabled"))
        XCTAssertTrue(source.contains("if selectedThreadHasWorkOSGoal"))
        XCTAssertTrue(source.contains("planMode=active"))
        XCTAssertTrue(source.contains("goalMode=active"))
        XCTAssertTrue(source.contains("同一個 thread"))
        XCTAssertTrue(source.contains("var currentChatInteractionMode"))
        XCTAssertTrue(source.contains("interactionMode: currentChatInteractionMode"))
    }

    func testPLGStartAndAdvanceFailuresStayVisibleAndFailClosed() throws {
        let source = try chatPageSource
        let startSection = try XCTUnwrap(
            source.slice(
                from: "func startPLGRun(objective: String) async -> Bool",
                through: "private func makePLGDomainProjection"))
        XCTAssertTrue(startSection.contains("PLG 只能從 Chat 主 thread 啟動"))

        let advanceSection = try XCTUnwrap(
            source.slice(
                from: "func advancePLGFromPlanning()",
                through: "func endPLGRun()"))
        XCTAssertTrue(advanceSection.contains("-> Bool"))
        XCTAssertTrue(advanceSection.contains("return applyPLG"))
    }

    func testSlashCommandsRouteBeforeOrdinaryChatSubmission() throws {
        let source = try chatPageSource
        let sendSection = try XCTUnwrap(
            source.slice(
                from: "func send()",
                through: "func submitCurrentChatTurn"))

        let plgRoute = try XCTUnwrap(sendSection.range(of: "triggerPLGFromPrompt()"))
        let planRoute = try XCTUnwrap(sendSection.range(of: "handlePlanSlashCommand()"))
        let goalRoute = try XCTUnwrap(sendSection.range(of: "commitOrActivateGoalFromPrompt()"))
        let ordinarySubmit = try XCTUnwrap(sendSection.range(of: "submitCurrentChatTurn()"))
        XCTAssertLessThan(plgRoute.lowerBound, ordinarySubmit.lowerBound)
        XCTAssertLessThan(planRoute.lowerBound, ordinarySubmit.lowerBound)
        XCTAssertLessThan(goalRoute.lowerBound, ordinarySubmit.lowerBound)
        XCTAssertFalse(
            try XCTUnwrap(
                source.slice(
                    from: "func triggerPLGFromPrompt()",
                    through: "func handlePlanSlashCommand()"))
                .contains("newChat()"))
    }

    func testComposerSendButtonExposesExplicitComputerUseAction() throws {
        let source = try chatPageSource
        let sendButton = try XCTUnwrap(
            source.slice(
                from: "func composerSendButton(",
                through: "var composerStopButton"))

        XCTAssertTrue(sendButton.contains(#".accessibilityLabel("送出")"#))
        XCTAssertTrue(
            sendButton.contains(
                #".accessibilityIdentifier("chat-composer-send")"#))
        XCTAssertTrue(
            sendButton.range(
                of: #"\.accessibilityAction\s*\{\s*model\.send\(\)\s*\}"#,
                options: .regularExpression
            ) != nil)
    }

    func testIssueSlashCommandIsSuggestedMatchedAndProjectsZeroIssuesOnEmptyInput() {
        XCTAssertTrue(ChatComposerSlashCatalog.commands.contains("/issue"))
        XCTAssertEqual(
            ChatComposerSlashCatalog.matches(prompt: "/iss").map(\.command),
            ["/issue"])
        // matchesSlash 委派 TatwoSlashCommandParser：/issue 與 /issue list 都要命中
        XCTAssertTrue(TatwoSlashCommandParser.matchesCommand(in: "/issue", commands: ["/issue"]))
        XCTAssertTrue(TatwoSlashCommandParser.matchesCommand(in: "/issue list", commands: ["/issue"]))
        XCTAssertEqual(
            TatwoSlashCommandParser.objective(from: "/issue list", commands: ["/issue"]),
            "list")
        // handler 的 list 行為對空 goalRun / dispatch 輸入必得 0 筆（對應「Issue 0 筆」hint）
        XCTAssertTrue(
            TatwoIssueQueueProjector.project(goalRuns: [], dispatchFailures: [], now: Date())
                .isEmpty)
    }

    func testIssueSlashCommandRoutesToComposerHintNotThreadSubmission() throws {
        let source = try chatPageSource
        let sendSection = try XCTUnwrap(
            source.slice(
                from: "func send()",
                through: "func submitCurrentChatTurn"))
        let issueRoute = try XCTUnwrap(sendSection.range(of: "handleIssueSlashCommand()"))
        let ordinarySubmit = try XCTUnwrap(sendSection.range(of: "submitCurrentChatTurn()"))
        XCTAssertLessThan(issueRoute.lowerBound, ordinarySubmit.lowerBound)

        let handlerSection = try XCTUnwrap(
            source.slice(
                from: "func handleIssueSlashCommand()",
                through: "// MARK: #16 /plg 執行流"))
        XCTAssertTrue(handlerSection.contains("issueListStore.capture"))
        XCTAssertTrue(handlerSection.contains("reloadIssueList"))
        XCTAssertTrue(handlerSection.contains("removeIssueListEntry"))
        XCTAssertFalse(handlerSection.contains("submitCurrentChatTurn"))
        XCTAssertTrue(source.contains("SlashCommandItem(cmd: \"/issue\""))
    }

    func testAppKitArrowAndReturnRoutingPreservesNormalCursorBehavior() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageAppKitBridges.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("case 124, 125"))
        XCTAssertTrue(source.contains("cursorAtEnd ? onSuggestionKey(.next) : false"))
        XCTAssertTrue(source.contains("case 123, 126"))
        XCTAssertTrue(source.contains("return onSuggestionKey(.prev)"))
        XCTAssertTrue(source.contains("return onSuggestionKey(.commit)"))
    }
}
