import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ChatInlineWorkTimelinePresentationTests: XCTestCase {
    func testRunningTimelineCombinesReasoningAndToolSteps() throws {
        let turnID = "turn-running"
        let rows = ChatTranscriptDisplayBuilder.build([
            message(
                id: "reasoning",
                text: "Inspecting the Chat presentation",
                status: "thinking|Inspecting the Chat presentation",
                modelID: "gpt-5.6-sol",
                kind: .thinking,
                turnID: turnID),
            message(
                id: "command",
                text: "swift test --filter ChatInlineWork",
                status: "running-command|swift test --filter ChatInlineWork",
                modelID: "gpt-5.6-sol",
                kind: .toolUse,
                turnID: turnID),
            message(
                id: "reconnect",
                text: "Reconnect attempt 2/5",
                status: "reconnecting 2/5|連線中斷，正在續接原工作",
                modelID: "gpt-5.6-sol",
                kind: .message,
                turnID: turnID),
        ])

        XCTAssertEqual(rows.count, 1)
        let timeline = try timeline(from: rows[0])
        XCTAssertEqual(timeline.modelID, "gpt-5.6-sol")
        XCTAssertEqual(
            timeline.messages.map(\.id),
            ["reasoning", "command", "reconnect"])
        XCTAssertTrue(timeline.presentation.isActive)
        XCTAssertEqual(timeline.presentation.state, .reconnecting)
        let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
        XCTAssertEqual(
            ChatInlineWorkTimelineSummary.containerLabel,
            "思考中")
        XCTAssertEqual(summary.compactText, "重新連線 · 3 個步驟")
    }

    func testTerminalUpdateWithSameItemIDCountsAsOneLogicalStep() throws {
        let turnID = "turn-coalesced"
        let rows = ChatTranscriptDisplayBuilder.build([
            message(
                id: "command-1",
                text: "swift test",
                status: "running-command|swift test",
                modelID: "gpt-5.6-sol",
                kind: .toolUse,
                turnID: turnID),
            message(
                id: "command-1",
                text: "swift test",
                status: "completed|swift test",
                modelID: "gpt-5.6-sol",
                kind: .toolUse,
                turnID: turnID),
            message(
                id: turnID,
                text: "All checks passed.",
                status: nil,
                modelID: "gpt-5.6-sol",
                kind: .message,
                turnID: turnID),
        ])

        let timeline = try timeline(from: rows[0])
        XCTAssertEqual(timeline.messages.count, 1)
        XCTAssertEqual(timeline.presentation.state, .completed)
        XCTAssertEqual(timeline.presentation.text, "已完成工作 · 1 個步驟")
    }

    func testExpansionPolicyCollapsesEveryStateByDefault() {
        for state in [
            ChatInlineWorkState.queued,
            .running,
            .tool,
            .reconnecting,
            .failed,
            .completed,
            .cancelled,
        ] {
            XCTAssertFalse(
                ChatInlineWorkTimelineExpansionPolicy.defaultIsExpanded(
                    for: .init(
                        state: state,
                        text: "must stay hidden",
                        isActive: ![.completed, .failed, .cancelled]
                            .contains(state))))
        }
    }

    func testCollapsedProjectionBuildsNoRowsAndExposesNoReasoning() throws {
        let secretReasoning =
            "PRIVATE_CHAIN_OF_THOUGHT: enumerate every internal inference"
        let rows = ChatTranscriptDisplayBuilder.build([
            message(
                id: "private-thinking",
                text: secretReasoning,
                status: "thinking|\(secretReasoning)",
                modelID: "gpt-5.6-sol",
                kind: .thinking,
                turnID: "turn-private"),
            message(
                id: "tool",
                text: "Checking project files",
                status: "checking|Checking project files",
                modelID: "gpt-5.6-sol",
                kind: .toolUse,
                turnID: "turn-private"),
        ])

        XCTAssertEqual(rows.count, 1)
        let timeline = try timeline(from: rows[0])
        let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
        let collapsedDetails = ChatInlineWorkTimelineDetailProjection.rows(
            for: timeline,
            isExpanded: false)

        XCTAssertEqual(ChatInlineWorkTimelineSummary.containerLabel, "思考中")
        XCTAssertEqual(summary.compactText, "使用工具 · 2 個步驟")
        XCTAssertTrue(collapsedDetails.isEmpty)
        XCTAssertFalse(summary.compactText.contains(secretReasoning))
    }

    func testExpandedProjectionHidesReasoningAndKeepsToolFailure() throws {
        let secretReasoning =
            "PRIVATE_CHAIN_OF_THOUGHT: hidden even after expansion"
        let toolError = "Permission denied while reading the selected file"
        let rows = ChatTranscriptDisplayBuilder.build([
            message(
                id: "private-thinking",
                text: secretReasoning,
                status: "thinking|\(secretReasoning)",
                modelID: "gpt-5.6-sol",
                kind: .thinking,
                turnID: "turn-failed"),
            message(
                id: "failed-tool",
                text: toolError,
                status: "failed|\(toolError)",
                modelID: "gpt-5.6-sol",
                kind: .toolUse,
                turnID: "turn-failed"),
        ])

        let timeline = try timeline(from: rows[0])
        let details = ChatInlineWorkTimelineDetailProjection.rows(
            for: timeline,
            isExpanded: true)

        XCTAssertEqual(details.count, 2)
        XCTAssertEqual(details[0].label, "分析進度")
        XCTAssertFalse(
            details.map(\.label).joined(separator: "\n")
                .contains(secretReasoning))
        XCTAssertTrue(details[1].label.contains(toolError))
        XCTAssertEqual(details[1].state, .failed)
    }

    func testCompactSummaryNeverRepeatsToolDetailsAcrossStates() throws {
        for status in ["queued", "thinking", "running-command", "reconnecting",
                       "completed", "failed", "cancelled"] {
            let detail = "Very long tool detail that belongs only in expanded rows"
            let rows = ChatTranscriptDisplayBuilder.build([
                message(
                    id: "step", text: detail, status: "\(status)|\(detail)",
                    modelID: "gpt-6", kind: .toolUse, turnID: "turn-\(status)"),
            ])
            let timeline = try timeline(from: XCTUnwrap(rows.first))
            let summary = ChatInlineWorkTimelineSummary.resolve(timeline)
            XCTAssertFalse(summary.compactText.contains(detail), status)
            XCTAssertTrue(summary.compactText.contains("1 個步驟"), status)
            let details = ChatInlineWorkTimelineDetailProjection.rows(
                for: timeline, isExpanded: true)
            XCTAssertTrue(details.contains { $0.label.contains(detail) }, status)
            if ["completed", "failed", "cancelled"].contains(status) {
                XCTAssertNotEqual(summary.label, "思考中", status)
                XCTAssertFalse(summary.isActive, status)
            }
        }
    }

    func testTatwo2UsesTheSameTestedTimelineProjection() throws {
        let paths = [
            "App/Sources/Tatwo2/Chat/ChatPageLeafViews+WorkTimeline.swift",
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageLeafViews+WorkTimeline.swift",
        ]
        let projections = try paths.map { path in
            let source = try String(contentsOf: repoRoot.appendingPathComponent(path))
            let start = try XCTUnwrap(source.range(of: "enum ChatInlineWorkState:"))
            let end = try XCTUnwrap(source.range(of: "struct ChatInlineWorkDetailRow:"))
            return String(source[start.lowerBound..<end.lowerBound])
        }
        XCTAssertEqual(projections[0], projections[1])
    }

    func testDifferentModelAttributionsNeverShareOneTimeline() throws {
        let turnID = "turn-route-boundary"
        let rows = ChatTranscriptDisplayBuilder.build([
            message(
                id: "sol-step",
                text: "Sol step",
                status: "completed|Sol step",
                modelID: "gpt-5.6-sol",
                kind: .toolUse,
                turnID: turnID),
            message(
                id: "opus-step",
                text: "Opus step",
                status: "completed|Opus step",
                modelID: "claude-opus-5",
                kind: .toolUse,
                turnID: turnID),
        ])

        XCTAssertEqual(rows.count, 2)
        let timelines = try rows.map(timeline(from:))
        XCTAssertEqual(
            Set(timelines.compactMap(\.modelID)),
            Set(["gpt-5.6-sol", "claude-opus-5"]))
        XCTAssertTrue(timelines.allSatisfy { $0.messages.count == 1 })
    }

    func testTimelineAccessibilityIdentifiersAreStateIndependent() throws {
        let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")

        XCTAssertTrue(
            source.contains(
                #".accessibilityIdentifier("chat-inline-work-timeline")"#))
        XCTAssertTrue(
            source.contains(
                #".accessibilityIdentifier("chat-inline-work-detail")"#))
        XCTAssertTrue(
            source.contains(
                #""chat-inline-work-timeline-summary""#))
        XCTAssertFalse(
            source.contains(
                #""chat-inline-work-timeline-\(timeline.presentation.state.rawValue)""#))
        XCTAssertTrue(source.contains(".accessibilityValue("))
        XCTAssertTrue(source.contains(#"isExpanded ? "已展開" : "已收合""#))
        XCTAssertFalse(source.contains("chat-thinking-fold-body"))
        XCTAssertFalse(source.contains("thinkingBody:"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("reduceMotion ? nil"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func message(
        id: String,
        text: String,
        status: String?,
        modelID: String,
        kind: TatwoNativeChatEventKind,
        turnID: String
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            text: text,
            status: status,
            modelID: modelID,
            eventKind: kind,
            turnID: turnID)
    }

    private func timeline(
        from row: ChatTranscriptDisplayItem
    ) throws -> ChatInlineWorkTimeline {
        guard case .workTimeline(let timeline) = row else {
            throw NSError(
                domain: "ChatInlineWorkTimelinePresentationTests",
                code: 1)
        }
        return timeline
    }
}
