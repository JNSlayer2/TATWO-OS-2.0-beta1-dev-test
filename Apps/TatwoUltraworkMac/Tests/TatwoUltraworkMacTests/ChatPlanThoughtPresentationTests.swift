import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class ChatPlanThoughtPresentationTests: XCTestCase {
    private let planMarkdown = """
        # Plan

        ## Objective

        Build the browser safely.

        ## Steps

        1. Open Google.
        2. Use official sources.
        """

    func testPlanArtifactSourceFoldsWithoutDuplicatingPlanBody() throws {
        let original = ChatMessage(
            id: "assistant-plan",
            role: .assistant,
            text: planMarkdown,
            modelID: "gpt-5.5",
            eventKind: .message,
            turnID: "plan-turn",
            createdAt: Date(timeIntervalSince1970: 100))

        let projected = ChatPlanThoughtPresentation.projectedMessage(
            original,
            planArtifactSourceMessageID: original.id)

        XCTAssertEqual(projected.id, original.id)
        XCTAssertEqual(projected.turnID, original.turnID)
        XCTAssertEqual(projected.createdAt, original.createdAt)
        XCTAssertEqual(projected.role, .assistant)
        XCTAssertEqual(projected.eventKind, .thinking)
        XCTAssertTrue(projected.text.isEmpty)
        XCTAssertEqual(projected.status, "completed|計畫已整理")
        XCTAssertFalse(projected.text.contains(planMarkdown))
    }

    func testStreamingPlanUsesStableIdentityAndConciseProgress() throws {
        let original = ChatMessage(
            id: "assistant-plan-stream",
            role: .assistant,
            text: "# Plan\n\n## Objective\n\nStill streaming",
            status: "streaming",
            modelID: "gpt-5.5",
            eventKind: .message,
            turnID: "plan-turn",
            createdAt: Date(timeIntervalSince1970: 200))

        let first = ChatPlanThoughtPresentation.projectedMessage(
            original,
            planArtifactSourceMessageID: original.id)
        let second = ChatPlanThoughtPresentation.projectedMessage(
            original,
            planArtifactSourceMessageID: original.id)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(
            first.displaySemanticIdentity,
            second.displaySemanticIdentity)
        XCTAssertEqual(first.status, "planning|計畫已整理")
        XCTAssertFalse(first.status?.contains("Still streaming") == true)
    }

    func testConfirmedExecutionEnvelopeBecomesOneFoldedThoughtTimeline() throws {
        let wrapper = confirmedExecutionMessage(status: nil)
        let projected = ChatPlanThoughtPresentation.projectedMessages(
            [wrapper],
            planArtifactSourceMessageID: nil)

        let only = try XCTUnwrap(projected.first)
        XCTAssertEqual(only.id, wrapper.id)
        XCTAssertEqual(only.role, .assistant)
        XCTAssertEqual(only.eventKind, .thinking)
        XCTAssertTrue(only.text.isEmpty)
        XCTAssertEqual(only.status, "queued|已送交 Work OS／等待 runner")
        XCTAssertFalse(only.status?.hasPrefix("completed|") == true)

        let items = ChatTranscriptDisplayBuilder.build(projected)
        guard case .workTimeline(let timeline) = try XCTUnwrap(items.first)
        else {
            return XCTFail("Expected one folded work timeline")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(
            ChatInlineWorkTimelineSummary.containerLabel,
            ChatPlanThoughtPresentation.accessibilityLabel)
        XCTAssertFalse(
            ChatInlineWorkTimelineExpansionPolicy.defaultIsExpanded(
                for: timeline.presentation))
        XCTAssertTrue(
            ChatInlineWorkTimelineDetailProjection.rows(
                for: timeline,
                isExpanded: false).isEmpty)
        let expanded = ChatInlineWorkTimelineDetailProjection.rows(
            for: timeline,
            isExpanded: true)
        XCTAssertEqual(expanded.count, 1)
        XCTAssertTrue(expanded[0].label.contains("已送交 Work OS"))
        XCTAssertFalse(expanded[0].label.contains(planMarkdown))
    }

    func testQueuedTimelineStaysQueuedWhenOrdinaryFinalMessageArrives() throws {
        let turnID = "queued-with-final"
        let queued = ChatMessage(
            id: "queued-work",
            role: .assistant,
            text: "private runner handoff payload",
            status: "queued|已送交 Work OS",
            modelID: "gpt-5.5",
            eventKind: .thinking,
            turnID: turnID)
        let ordinaryFinal = ChatMessage(
            id: "ordinary-final",
            role: .assistant,
            text: "I have recorded the request.",
            modelID: "gpt-5.5",
            eventKind: .message,
            turnID: turnID)

        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: turnID,
                workMessages: [queued],
                turnMessages: [queued, ordinaryFinal]))
        let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
        let details = ChatInlineWorkTimelineDetailProjection.rows(
            for: timeline,
            isExpanded: true)

        XCTAssertEqual(timeline.presentation.state, .queued)
        XCTAssertTrue(timeline.presentation.isActive)
        XCTAssertEqual(summary.compactText, "等待中 · 1 個步驟")
        XCTAssertTrue(details.first?.label.contains("已送交 Work OS") == true)
        XCTAssertFalse(summary.compactText.contains("private runner handoff payload"))
        XCTAssertFalse(details.contains {
            $0.label.contains("private runner handoff payload")
        })
    }

    func testOrdinaryUserPlanTextIsNotMisclassified() {
        let ordinary = ChatMessage(
            id: "ordinary-user",
            role: .user,
            text: "請依照以下計畫直接實作，但這是我自己輸入的。",
            eventKind: .message)

        XCTAssertFalse(
            ChatPlanThoughtPresentation
                .isConfirmedPlanExecutionPrompt(ordinary))
        XCTAssertEqual(
            ChatPlanThoughtPresentation.projectedMessage(
                ordinary,
                planArtifactSourceMessageID: nil),
            ordinary)
    }

    func testOrdinaryAssistantWithoutArtifactIsNeverFolded() {
        let ordinary = ChatMessage(
            id: "ordinary-assistant",
            role: .assistant,
            text: "This is a normal answer, not a Plan artifact.",
            eventKind: .message)

        XCTAssertEqual(
            ChatPlanThoughtPresentation.projectedMessages(
                [ordinary],
                planArtifactSourceMessageID: nil,
                activePlanTurnAssistantMessageID: nil),
            [ordinary])
    }

    func testOnlyExactlyBoundActivePlanAssistantFoldsWhileWriting() {
        let older = ChatMessage(
            id: "older-assistant",
            role: .assistant,
            text: "Keep this prior answer visible.",
            eventKind: .message)
        let active = ChatMessage(
            id: "active-plan-assistant",
            role: .assistant,
            text: "Long Plan narration that must be folded.",
            status: "streaming",
            eventKind: .message)

        let projected = ChatPlanThoughtPresentation.projectedMessages(
            [older, active],
            planArtifactSourceMessageID: nil,
            activePlanTurnAssistantMessageID: active.id)

        XCTAssertEqual(projected[0], older)
        XCTAssertEqual(projected[1].eventKind, .thinking)
        XCTAssertEqual(projected[1].status, "planning|計畫整理中")
        XCTAssertTrue(projected[1].text.isEmpty)
    }

    func testHistoricalJournalReloadKeepsOnlyConciseFoldedState() throws {
        var journal = ChatTranscriptJournalV1()
        let wrapper = confirmedExecutionMessage(status: nil)

        XCTAssertTrue(
            ChatTranscriptJournalAdapter.append(
                message: wrapper,
                threadID: "thread-plan",
                to: &journal
            ).wasAppended)

        let encoded = try journal.encodedSnapshot()
        let reloaded = try ChatTranscriptJournalV1.restoring(from: encoded)
        let rows = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: "thread-plan",
            from: reloaded)
        let row = try XCTUnwrap(rows.first)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.eventKind, .thinking)
        XCTAssertTrue(row.text.isEmpty)
        XCTAssertEqual(row.status, "completed|已送交 Work OS")
        XCTAssertFalse(row.text.contains(planMarkdown))
        XCTAssertFalse(
            encoded.range(
                of: Data(planMarkdown.utf8)) != nil,
            "Durable journal must not contain the full Plan body")

        let presented = ChatPlanThoughtPresentation.projectedMessage(
            row,
            planArtifactSourceMessageID: nil)
        XCTAssertEqual(presented.id, row.id)
        XCTAssertEqual(
            presented.displaySemanticIdentity,
            row.displaySemanticIdentity)
    }

    func testFailedFoldedPromptKeepsFailureVisibleWithoutRawPlan() {
        let failed = confirmedExecutionMessage(
            status: "failed|runner unavailable")
        let projected = ChatPlanThoughtPresentation.projectedMessage(
            failed,
            planArtifactSourceMessageID: nil)

        XCTAssertEqual(projected.status, "failed|runner unavailable")
        XCTAssertTrue(projected.text.isEmpty)
        XCTAssertEqual(
            ChatInlineWorkPresentation.resolve(projected)?.state,
            .failed)
    }

    func testFailedTimelineShowsFailureAndKeepsStructuredReasonInExpandedDetail() throws {
        let failed = ChatPlanThoughtPresentation.projectedMessage(
            confirmedExecutionMessage(status: "failed|runner unavailable"),
            planArtifactSourceMessageID: nil)
        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: failed.turnID ?? failed.id,
                workMessages: [failed],
                turnMessages: [failed]))
        let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
        let details = ChatInlineWorkTimelineDetailProjection.rows(
            for: timeline,
            isExpanded: true)

        XCTAssertEqual(timeline.presentation.state, .failed)
        XCTAssertEqual(summary.label, "發生錯誤")
        XCTAssertEqual(summary.compactText, "1 個步驟")
        XCTAssertTrue(details.first?.label.contains("runner unavailable") == true)
    }

    func testStructuredThinkingDetailIsNotReplacedByAnalysisProgress() throws {
        let message = ChatMessage(
            id: "structured-thinking",
            role: .assistant,
            text: "private reasoning must stay hidden",
            status: "checking|權限與路由已確認",
            eventKind: .thinking,
            turnID: "structured-thinking-turn")
        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: "structured-thinking-turn",
                workMessages: [message],
                turnMessages: [message]))
        let details = ChatInlineWorkTimelineDetailProjection.rows(
            for: timeline,
            isExpanded: true)

        XCTAssertEqual(details.count, 1)
        XCTAssertTrue(details[0].label.contains("權限與路由已確認"))
        XCTAssertFalse(details[0].label.contains("分析進度"))
        XCTAssertFalse(details[0].label.contains("private reasoning"))
    }

    func testConfirmedExecutionOnlyExplicitSuccessBecomesCompleted() {
        let completed = ChatPlanThoughtPresentation.projectedMessage(
            confirmedExecutionMessage(status: "completed|runner finished"),
            planArtifactSourceMessageID: nil)
        let succeeded = ChatPlanThoughtPresentation.projectedMessage(
            confirmedExecutionMessage(status: "succeeded|runner finished"),
            planArtifactSourceMessageID: nil)
        let unknown = ChatPlanThoughtPresentation.projectedMessage(
            confirmedExecutionMessage(status: "accepted|runner handoff"),
            planArtifactSourceMessageID: nil)

        XCTAssertEqual(completed.status, "completed|runner finished")
        XCTAssertEqual(succeeded.status, "completed|runner finished")
        XCTAssertEqual(unknown.status, "queued|runner handoff")
        XCTAssertFalse(unknown.status?.hasPrefix("completed|") == true)
    }

    func testManyReasoningDeltasConvergeToOneStructuralJournalItem()
        throws
    {
        var journal = ChatTranscriptJournalV1()
        let context = ChatTranscriptJournalContext(
            threadID: "thread-thinking",
            turnID: "turn-thinking",
            runID: "run-thinking",
            source: ChatTranscriptSourceMetadataV1(
                source: "provider",
                model: "test-model",
                runtime: "test-runtime",
                runID: "run-thinking"))
        let rawDeltas = [
            "private chain of thought step one",
            "private chain of thought step two",
            "private chain of thought final",
        ]

        for (index, delta) in rawDeltas.enumerated() {
            _ = ChatTranscriptJournalAdapter.appendReasoningSummary(
                text: delta,
                rawType: "reasoning_delta_\(index)",
                context: context,
                to: &journal)
        }

        let turn = try XCTUnwrap(
            journal.turn(
                threadID: context.threadID,
                turnID: context.turnID))
        let thinkingItems = turn.items.filter {
            $0.kind == .reasoningSummary
        }
        XCTAssertEqual(thinkingItems.count, 1)
        XCTAssertEqual(thinkingItems.first?.summary, "思考中")

        let encoded = try journal.encodedSnapshot()
        for delta in rawDeltas {
            XCTAssertNil(
                encoded.range(of: Data(delta.utf8)),
                "Raw reasoning must never enter the durable journal")
        }
        let projected = ChatTranscriptJournalAdapter.projectedMessages(
            threadID: context.threadID,
            from: journal)
        let thinkingRows = projected.filter { $0.eventKind == .thinking }
        XCTAssertEqual(thinkingRows.count, 1)
        XCTAssertEqual(thinkingRows.first?.text, "")
        XCTAssertEqual(thinkingRows.first?.status, "completed|思考中")
        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: context.turnID,
                workMessages: thinkingRows,
                turnMessages: thinkingRows))
        let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
        let details = ChatInlineWorkTimelineDetailProjection.rows(
            for: timeline,
            isExpanded: true)
        for delta in rawDeltas {
            XCTAssertFalse(summary.compactText.contains(delta))
            XCTAssertFalse(details.contains { $0.label.contains(delta) })
            XCTAssertFalse(thinkingRows.contains { $0.text.contains(delta) })
        }
    }

    func testCompletedThinkingSummaryDoesNotRepeatThinkingOrCompletionLabels()
        throws
    {
        let message = ChatMessage(
            id: "completed-thinking",
            role: .assistant,
            text: "",
            status: "completed|思考中",
            eventKind: .thinking,
            turnID: "completed-thinking-turn")
        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: "completed-thinking-turn",
                workMessages: [message],
                turnMessages: [message]))

        let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
        // Finished turns read 已完成 in the label (Codex "Worked for …"), so the
        // compact text no longer repeats the status word.
        XCTAssertEqual(summary.label, "已完成")
        XCTAssertEqual(summary.compactText, "1 個步驟")
    }

    func testThoughtTimelineUsesCenteredCodexStyleProgressCapsule()
        throws
    {
        let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")
        let timelineStart = try XCTUnwrap(
            source.range(of: "struct ChatInlineWorkTimelineView: View"))
        let discStart = try XCTUnwrap(
            source.range(
                of: "private struct ChatInlineWorkProgressDisc: View",
                range: timelineStart.upperBound..<source.endIndex))
        let timelineBody = String(
            source[timelineStart.lowerBound..<discStart.lowerBound])
        let discBody = String(source[discStart.lowerBound...])

        XCTAssertTrue(timelineBody.contains(
            "VStack(alignment: .center, spacing: 4)"))
        XCTAssertTrue(timelineBody.contains("ChatInlineWorkProgressDisc("))
        XCTAssertTrue(timelineBody.contains(
            ".frame(maxWidth: .infinity, alignment: .center)"))
        XCTAssertTrue(timelineBody.contains(
            "in: Capsule(style: .continuous)"))
        XCTAssertTrue(timelineBody.contains(
            ".frame(maxWidth: 220, alignment: .leading)"))
        XCTAssertTrue(timelineBody.contains(
            ".padding(.vertical, 4)"))
        XCTAssertFalse(timelineBody.contains(
            "ChatModelAvatar(route: resolvedRoute)"))
        XCTAssertTrue(discBody.contains(
            ".progressViewStyle(.circular)"))
        XCTAssertTrue(discBody.contains(
            ".accessibilityIdentifier(\"chat-inline-work-progress-disc\")"))
    }

    func testChangedFilesSummaryParsesPerFileLineCounts() {
        let parsed = ChatPageModel.parseGitNumstat(
            """
            127\t44\tApps/TatwoUltraworkMac/ChatPageLeafViews.swift
            53\t0\tApps/TatwoUltraworkMac/ChatPlanThoughtPresentationTests.swift
            -\t-\tAssets/reference.png
            """)

        XCTAssertEqual(
            parsed["Apps/TatwoUltraworkMac/ChatPageLeafViews.swift"]?.additions,
            127)
        XCTAssertEqual(
            parsed["Apps/TatwoUltraworkMac/ChatPageLeafViews.swift"]?.deletions,
            44)
        XCTAssertEqual(
            parsed["Apps/TatwoUltraworkMac/ChatPlanThoughtPresentationTests.swift"]?.additions,
            53)
        XCTAssertEqual(parsed["Assets/reference.png"]?.additions, 0)
        XCTAssertEqual(parsed["Assets/reference.png"]?.deletions, 0)
    }

    func testChangedFilesSummaryUsesCodexStyleCompletionCard() throws {
        let leafViews = try ChatSourceFamily.read("ChatPageLeafViews.swift")
        let chatPage = try ChatSourceFamily.read("ChatPage.swift")
        let chatPageModel = try ChatSourceFamily.read("ChatPageModel.swift")
        let start = try XCTUnwrap(
            leafViews.range(of: "struct ChatChangedFilesSummaryView: View"))
        let body = String(leafViews[start.lowerBound...])

        XCTAssertTrue(body.contains(
            "Text(\"已編輯 \\(totalFileCount) 個檔案\")"))
        XCTAssertTrue(body.contains("Text(\"+\\(totalAdditions)\")"))
        XCTAssertTrue(body.contains("Text(\"-\\(totalDeletions)\")"))
        XCTAssertTrue(body.contains("Text(file.path)"))
        XCTAssertTrue(body.contains("Button(\"查看\")"))
        XCTAssertTrue(body.contains(
            ".accessibilityIdentifier(\"chat-changed-files-view\")"))
        XCTAssertTrue(body.contains(
            ".accessibilityIdentifier(\"chat-changed-files-undo\")"))
        XCTAssertFalse(body.contains(".popover("))
        XCTAssertTrue(chatPage.contains(
            "ChatChangedFilesSummaryView("))
        XCTAssertTrue(chatPage.contains(
            ".id(\"tatwo-chat-changed-files-summary\")"))
        XCTAssertTrue(chatPage.contains(
            "message.id == latestAssistantMessageID"))
        XCTAssertTrue(chatPage.contains("!isRunning"))
        XCTAssertTrue(chatPage.contains("rightPanelContent = .diff"))
        XCTAssertFalse(chatPage.contains(
            "if gitChangedFileCount > 0 {\n                                    ChatChangedFilesSummaryView("))
        XCTAssertTrue(chatPageModel.contains(
            "TATWO_ULTRAWORK_CHAT_COMPLETION_REPORT_FIXTURE"))
        XCTAssertTrue(chatPageModel.contains(
            "fixture-completion-assistant"))
        XCTAssertTrue(chatPageModel.contains(
            "gitChangedLineAdditions = 23"))
        XCTAssertTrue(chatPageModel.contains(
            "gitChangedLineDeletions = 18"))
    }

    func testNonCLIRawEventsHaveNoAssistantTranscriptFallbackBuffer()
        throws
    {
        let source = try ChatSourceFamily.read("ChatPageModel.swift")

        XCTAssertTrue(source.contains("case .raw(let text):"))
        XCTAssertTrue(
            source.contains(
                #"recordLiveWork(status: "working|接收結構化工作事件")"#))
        XCTAssertFalse(source.contains("appendRawFallback"))
        XCTAssertFalse(source.contains("pendingRawFallbackText"))
        XCTAssertFalse(source.contains("cleanedRawAssistantFallback"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func confirmedExecutionMessage(
        status: String?
    ) -> ChatMessage {
        ChatMessage(
            id: "confirmed-plan-execution",
            role: .user,
            text: """
                依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃、不要只重述計畫。
                必須使用可用工具直接執行計畫；只有計畫明確要求時才修改檔案。

                \(planMarkdown)
                """,
            status: status,
            eventKind: .message,
            createdAt: Date(timeIntervalSince1970: 300))
    }
}
