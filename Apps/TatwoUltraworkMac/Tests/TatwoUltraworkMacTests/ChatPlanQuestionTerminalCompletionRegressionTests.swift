import Foundation
import TatwoUltraworkCore
import XCTest

@testable import TatwoUltraworkMac

final class ChatPlanClarificationContinuationPolicyTests: XCTestCase {
    func testFinalPromptSelectionForcesTerminalNoMoreQuestionsEnvelope() {
        let answers = [
            PlanQuestionAnswerV1(
                questionID: "final-runner-prompt-output",
                selectedOptions: [
                    .init(
                        label: "輸出最終 runner prompt",
                        detail: "現在定稿並輸出完整提示詞。")
                ])
        ]

        XCTAssertTrue(
            ChatPlanClarificationContinuationPolicy.shouldFinalize(
                answers: answers,
                acceptedRound: 2))
        let prompt =
            ChatPlanClarificationContinuationPolicy.continuationPrompt(
                answerBlocks: ["questionID=final-runner-prompt-output"],
                originalObjective: "用 Computer Use 搭建安全瀏覽器",
                forceFinal: true)
        XCTAssertTrue(
            ChatPlanClarificationContinuationPolicy.isTerminalEnvelope(
                prompt))
        XCTAssertTrue(prompt.contains("Do not ask another question"))
        XCTAssertTrue(prompt.contains("do not emit TATWO_PLAN_QUESTION"))
        XCTAssertTrue(prompt.contains("complete Markdown Plan"))
        XCTAssertTrue(prompt.contains("用 Computer Use 搭建安全瀏覽器"))
        XCTAssertTrue(prompt.contains("planning-only"))
    }

    func testMoreDetailAndPauseSelectionsDoNotFalsePositiveAsTerminal() {
        for label in [
            "再補測試矩陣",
            "暫停，先不要輸出最終 prompt",
            "繼續問一個必要問題",
        ] {
            XCTAssertFalse(
                ChatPlanClarificationContinuationPolicy.shouldFinalize(
                    answers: [
                        PlanQuestionAnswerV1(
                            questionID: "follow-up",
                            selectedOptions: [
                                .init(label: label, detail: "")
                            ])
                    ],
                    acceptedRound: 2),
                "label=\(label)")
        }
    }

    func testClarificationRoundCapForcesTerminalCompletion() {
        XCTAssertFalse(
            ChatPlanClarificationContinuationPolicy.shouldFinalize(
                answers: [
                    PlanQuestionAnswerV1(
                        questionID: "scope",
                        selectedOptions: [
                            .init(label: "目前專案", detail: "")
                        ])
                ],
                acceptedRound:
                    ChatPlanClarificationContinuationPolicy
                    .maximumAcceptedRounds - 1))
        XCTAssertTrue(
            ChatPlanClarificationContinuationPolicy.shouldFinalize(
                answers: [
                    PlanQuestionAnswerV1(
                        questionID: "scope",
                        selectedOptions: [
                            .init(label: "目前專案", detail: "")
                        ])
                ],
                acceptedRound:
                    ChatPlanClarificationContinuationPolicy
                    .maximumAcceptedRounds))
    }

    func testClarificationEnvelopePreservesExternalOriginalObjective() {
        let envelope = """
            [TATWO Plan terminal clarification answers]
            questionID=final-runner-prompt-output
            """

        XCTAssertEqual(
            ChatPlanClarificationContinuationPolicy.objectiveCandidate(
                userTurn: envelope,
                pendingObjective: nil,
                existingObjective: "既有安全瀏覽器目標",
                boundUserTurn: "/plan 不應覆蓋既有目標"),
            "既有安全瀏覽器目標")
        XCTAssertEqual(
            ChatPlanClarificationContinuationPolicy.objectiveCandidate(
                userTurn: envelope,
                pendingObjective: nil,
                existingObjective: nil,
                boundUserTurn: "/plan 用 Computer Use 搭建瀏覽器"),
            "/plan 用 Computer Use 搭建瀏覽器")
        XCTAssertEqual(
            ChatPlanClarificationContinuationPolicy.recoveredObjective(
                bindingObjective: envelope,
                pendingObjective: "原始 pending objective",
                existingObjective: nil,
                boundUserTurn: "/plan fallback"),
            "原始 pending objective")
    }
}

/// staging-62 live regression, thread 8d47658b / run 5007AE99.
///
/// The runner produced a terminal `item.completed` `agent_message` whose whole
/// body was a `<TATWO_PLAN_QUESTION>` payload, then `turn.completed` and exit 0
/// with `durableFormalSuccess=true`. The App still lost the turn: the transcript
/// collapsed back to the user message alone, nothing reached the canonical
/// journal, and the plan-artifact completion hook never ran.
///
/// These tests lock the three decision points that discarded that successful
/// completion.
final class ChatPlanQuestionTerminalCompletionRegressionTests: XCTestCase {
    /// Verbatim `item.completed.item.text` from the failing run's stdout JSONL.
    private static let failingAgentMessage = """
        <TATWO_PLAN_QUESTION>{"id":"sample-task-list","question":"內建範例任務清單要採用哪一組固定資料？","allowsMultipleSelections":false,"allowsOtherResponse":true,"options":[{"label":"3 todo、2 done (Recommended)","detail":"範例清楚、測試涵蓋剛好。"},{"label":"2 todo、2 done","detail":"最對稱的最小範例。"}]}</TATWO_PLAN_QUESTION>
        """

    private func failingQuestions() throws -> [PlanQuestionV1] {
        var parser = TatwoPlanQuestionStreamParser()
        let streamed = parser.consume(Self.failingAgentMessage)
        let flushed = parser.consume("", isFinal: true)
        let questions = streamed.questions + flushed.questions

        // The whole terminal payload is the question block, so the assistant
        // row this turn produces has no visible text at all.
        XCTAssertEqual(streamed.visibleText, "")
        XCTAssertEqual(flushed.visibleText, "")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions.first?.id, "sample-task-list")
        XCTAssertEqual(questions.first?.options.count, 2)
        return questions
    }

    // MARK: - Terminal visibility

    func testTerminalPlanQuestionOnlyReplyIsNotAnEmptyPlaceholder() throws {
        let questions = try failingQuestions()

        XCTAssertFalse(
            ChatAssistantTerminalVisibilityPolicy.hasNoUserVisibleReply(
                text: "",
                eventKind: .message,
                planQuestions: questions),
            "A terminal clarification request is the turn's real output; "
                + "treating it as an empty placeholder deletes the row, skips "
                + "the journal commit and skips the plan-artifact hook")

        // Same row without the questions is exactly the state the old code saw,
        // and it must still be dropped.
        XCTAssertTrue(
            ChatAssistantTerminalVisibilityPolicy.hasNoUserVisibleReply(
                text: "",
                eventKind: .message,
                planQuestions: []))
    }

    func testPlanQuestionSurvivesEvenOnAThinkingOrToolPlaceholderRow() throws {
        let questions = try failingQuestions()
        for kind in [TatwoNativeChatEventKind.thinking, .toolUse] {
            XCTAssertFalse(
                ChatAssistantTerminalVisibilityPolicy.hasNoUserVisibleReply(
                    text: "",
                    eventKind: kind,
                    planQuestions: questions),
                "eventKind=\(kind.rawValue)")
            XCTAssertEqual(
                ChatAssistantTerminalVisibilityPolicy.resolvedEventKind(
                    currentEventKind: kind,
                    planQuestions: questions),
                .message,
                "questions must be journaled through a result row")
        }
    }

    func testPlaceholderBodiesWithoutQuestionsStayNonVisible() {
        for text in ["", "   ", "…", "..."] {
            XCTAssertTrue(
                ChatAssistantTerminalVisibilityPolicy.hasNoUserVisibleReply(
                    text: text,
                    eventKind: .message,
                    planQuestions: []),
                "text=\(text.debugDescription)")
        }
        XCTAssertFalse(
            ChatAssistantTerminalVisibilityPolicy.hasNoUserVisibleReply(
                text: "計畫已定案",
                eventKind: .message,
                planQuestions: []))
    }

    // MARK: - Canonical journal durability

    func testTerminalPlanQuestionRowRoundTripsThroughCanonicalJournal() throws {
        let questions = try failingQuestions()
        var journal = ChatTranscriptJournalV1()
        let threadID = "thread:8d47658b-6422-4173-919a-a2d221432f18"

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "5007AE99-C88A-4D21-8C05-0DD54960AA8D",
                    role: .assistant,
                    text: "",
                    status: nil,
                    modelID: "gpt-5.6-terra",
                    eventKind: .message,
                    turnID: "5007AE99-C88A-4D21-8C05-0DD54960AA8D",
                    planQuestions: questions),
                threadID: threadID,
                to: &journal
            ).wasAppended,
            "an empty-text clarification turn must still be journaled")

        let projected = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: threadID,
            from: journal)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(
            projected.first?.planQuestions,
            questions,
            "the projection replaces `messages` right after the terminal "
                + "commit; losing the questions there re-hides the card")
    }

    func testAnsweredPlanQuestionIsNotResurrectedByALaterTurn() throws {
        let questions = try failingQuestions()
        var journal = ChatTranscriptJournalV1()
        let threadID = "thread:8d47658b-6422-4173-919a-a2d221432f18"

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "assistant-question",
                    role: .assistant,
                    text: "",
                    modelID: "gpt-5.6-terra",
                    eventKind: .message,
                    turnID: "assistant-question",
                    planQuestions: questions),
                threadID: threadID,
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "assistant-plan",
                    role: .assistant,
                    text: "計畫已定案。",
                    modelID: "gpt-5.6-terra",
                    eventKind: .message,
                    turnID: "assistant-plan"),
                threadID: threadID,
                to: &journal
            ).wasAppended)

        let projected = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: threadID,
            from: journal)
        XCTAssertEqual(projected.count, 2)
        XCTAssertTrue(
            projected.first?.planQuestions.isEmpty == true,
            "journal items are terminal once completed, so a consumed question "
                + "set must be demoted by the later turn instead of offering a "
                + "second live card")
        XCTAssertTrue(projected.last?.planQuestions.isEmpty == true)
    }
}

/// staging-63 live regression, thread bb8974ad / run E9B1E92C.
///
/// The staging-62 repair above landed: the runner exits 0, the terminal
/// `agent_message` survives, and the canonical journal now carries an assistant
/// `result` item with a non-empty `planQuestions` attribute. The App still
/// showed the user message alone.
///
/// `ChatPageModel.transcriptMessages` filters every one of its three sources
/// (live `messages`, the canonical journal projection, and the legacy stored
/// fallback) through `!isInertAssistantPlaceholder`, and that predicate judged
/// an assistant `.message` row by transcript text / attachments / status only.
/// A clarification-only row is empty on all three, so the row that carried the
/// question was deleted after the journal had correctly stored it.
final class ChatPlanQuestionTranscriptVisibilityRegressionTests: XCTestCase {
    private static let threadID = "thread:bb8974ad-4a9d-4791-a95a-dd3d3130a2c7"
    private static let runID = "E9B1E92C-7315-4522-88AA-97BFAE3DB993"

    private func failingQuestions() throws -> [PlanQuestionV1] {
        var parser = TatwoPlanQuestionStreamParser()
        let streamed = parser.consume(
            "<TATWO_PLAN_QUESTION>{\"id\":\"staging63-scope\","
                + "\"question\":\"這一輪要先修哪一段？\","
                + "\"allowsMultipleSelections\":false,"
                + "\"allowsOtherResponse\":true,"
                + "\"options\":[{\"label\":\"轉錄過濾 (Recommended)\","
                + "\"detail\":\"最小改動。\"},"
                + "{\"label\":\"整段重寫\",\"detail\":\"風險高。\"}]}"
                + "</TATWO_PLAN_QUESTION>")
        let flushed = parser.consume("", isFinal: true)
        let questions = streamed.questions + flushed.questions
        XCTAssertEqual(streamed.visibleText, "")
        XCTAssertEqual(flushed.visibleText, "")
        XCTAssertEqual(questions.count, 1)
        return questions
    }

    /// The exact live row shape: assistant `.message`, empty text, no
    /// attachments, no status, non-empty `planQuestions`.
    private func clarificationOnlyRow(
        id: String = ChatPlanQuestionTranscriptVisibilityRegressionTests.runID,
        status: String? = nil,
        questions: [PlanQuestionV1]
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            text: "",
            status: status,
            modelID: "gpt-5.6-terra",
            eventKind: .message,
            turnID: Self.runID,
            planQuestions: questions)
    }

    // MARK: - Row policy

    func testClarificationOnlyAssistantRowIsNotAnInertPlaceholder() throws {
        let questions = try failingQuestions()
        let row = clarificationOnlyRow(questions: questions)

        XCTAssertFalse(
            row.isInertAssistantPlaceholder,
            "the clarification card is this turn's only output; classifying "
                + "the row as inert deletes it from every transcript source")
        XCTAssertFalse(row.isTranscriptNoise)

        // A mid-stream row that already parsed its questions must survive too.
        XCTAssertFalse(
            clarificationOnlyRow(status: "streaming", questions: questions)
                .isInertAssistantStreamingPlaceholder)
        XCTAssertFalse(
            clarificationOnlyRow(status: "streaming", questions: questions)
                .isInertAssistantPlaceholder)
    }

    func testEmptyAssistantRowWithoutQuestionsIsStillDropped() {
        XCTAssertTrue(
            clarificationOnlyRow(questions: []).isInertAssistantPlaceholder,
            "the original placeholder suppression must not be widened")
        XCTAssertTrue(
            clarificationOnlyRow(status: "streaming", questions: [])
                .isInertAssistantPlaceholder)
    }

    // MARK: - Canonical projection survives the transcript filter

    func testCanonicalProjectionOfTheFailingRunSurvivesTranscriptFiltering()
        throws
    {
        let questions = try failingQuestions()
        var journal = ChatTranscriptJournalV1()
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: ChatMessage(
                    id: "user-turn",
                    role: .user,
                    text: "/plan 修好澄清卡片",
                    eventKind: .message,
                    turnID: "user-turn"),
                threadID: Self.threadID,
                to: &journal
            ).wasAppended)
        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: clarificationOnlyRow(questions: questions),
                threadID: Self.threadID,
                to: &journal
            ).wasAppended)

        let projected = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: Self.threadID,
            from: journal)
        let clarification = try XCTUnwrap(
            projected.first(where: { $0.role == .assistant }))
        XCTAssertEqual(clarification.eventKind, .message)
        XCTAssertEqual(clarification.text, "")
        XCTAssertNil(clarification.status)
        XCTAssertEqual(clarification.planQuestions, questions)

        // Verbatim `ChatPageModel.transcriptMessages` predicate.
        let visible = projected.filter {
            !$0.isTranscriptNoise && !$0.isInertAssistantPlaceholder
        }
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(
            visible.last?.planQuestions,
            questions,
            "the canonical row reached the filter intact but was discarded "
                + "before PlanClarificationRequestCard could render it")
    }
}

/// Live `ChatPageModel.transcriptMessages` proof for the same failing shape.
@MainActor
final class ChatPlanQuestionLiveTranscriptVisibilityTests: XCTestCase {
    func testLiveTranscriptKeepsTheClarificationOnlyAssistantRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-staging63-clarification-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let threadID = UUID()
        let store = TatwoNativeChatStore(
            url: root.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try store.save(TatwoNativeChatStoreDocument(
            threads: [TatwoNativeChatThread(id: threadID, title: "staging63")]))
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatPlanQuestionLiveTranscriptVisibilityTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: store,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: root.appendingPathComponent("journal.json")),
            goalRunStore: TatwoGoalRunStore(directoryURL: root))

        let deadline = Date().addingTimeInterval(5)
        while model.isLoadingStore && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
        model.selectedThreadID = threadID

        let question = PlanQuestionV1(
            id: "staging63-scope",
            question: "這一輪要先修哪一段？",
            options: [
                .init(label: "轉錄過濾", detail: "最小改動。"),
                .init(label: "整段重寫", detail: "風險高。"),
            ])
        model.messages = [
            ChatMessage(
                id: "user-turn",
                role: .user,
                text: "/plan 修好澄清卡片",
                eventKind: .message),
            ChatMessage(
                id: "E9B1E92C-7315-4522-88AA-97BFAE3DB993",
                role: .assistant,
                text: "",
                status: nil,
                modelID: "gpt-5.6-terra",
                eventKind: .message,
                planQuestions: [question]),
        ]

        let visible = model.transcriptMessages
        XCTAssertEqual(
            visible.map(\.id),
            ["user-turn", "E9B1E92C-7315-4522-88AA-97BFAE3DB993"],
            "the live transcript collapsed to the user message alone")
        XCTAssertEqual(visible.last?.planQuestions, [question])
    }
}
