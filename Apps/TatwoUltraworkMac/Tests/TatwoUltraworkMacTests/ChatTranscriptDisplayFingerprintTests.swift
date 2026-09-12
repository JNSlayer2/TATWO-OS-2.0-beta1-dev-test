import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ChatTranscriptDisplayFingerprintTests: XCTestCase {
    func testFingerprintChangesWhenSameLengthTextChanges() {
        let original = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            text: "alpha")
        let sameLength = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            text: "gamma")

        XCTAssertEqual(original.text.utf8.count, sameLength.text.utf8.count)
        XCTAssertNotEqual(
            ChatTranscriptDisplayFingerprint([original]),
            ChatTranscriptDisplayFingerprint([sameLength]))
    }

    func testFingerprintChangesWhenModelIDIsAttached() {
        let before = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            text: "hello")
        let after = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            text: "hello",
            modelID: "grok-4.3")

        XCTAssertNil(before.modelID)
        XCTAssertEqual(before.text, after.text)
        XCTAssertNotEqual(
            ChatTranscriptDisplayFingerprint([before]),
            ChatTranscriptDisplayFingerprint([after]))
    }

    func testFingerprintChangesWhenPlanQuestionsAreAttached() {
        var message = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            text: "hello")
        let before = ChatTranscriptDisplayFingerprint([message])
        message.planQuestions.append(
            PlanQuestionV1(
                id: "q1",
                question: "Which path?",
                options: [
                    .init(label: "A", detail: "one"),
                    .init(label: "B", detail: "two")
                ]))

        XCTAssertNotEqual(before, ChatTranscriptDisplayFingerprint([message]))
    }

    func testFingerprintChangesWhenPlanPresentationBindingChanges() {
        let message = ChatMessage(
            id: "assistant-1",
            role: .assistant,
            text: "same transcript")

        let ordinary = ChatTranscriptDisplayFingerprint([message])
        let artifactBound = ChatTranscriptDisplayFingerprint(
            [message],
            planArtifactSourceMessageID: message.id)
        let writingBound = ChatTranscriptDisplayFingerprint(
            [message],
            activePlanTurnAssistantMessageID: message.id,
            isPlanWriting: true)

        XCTAssertNotEqual(ordinary, artifactBound)
        XCTAssertNotEqual(artifactBound, writingBound)
        XCTAssertNotEqual(ordinary, writingBound)
    }

    func testFingerprintTracksFoldedExecutionPromptOutsideTail() {
        let ordinaryUser = ChatMessage(
            id: "user-execution",
            role: .user,
            text: "普通使用者訊息",
            eventKind: .message)
        let confirmedExecution = ChatMessage(
            id: ordinaryUser.id,
            role: .user,
            text: """
                依照以下已由使用者確認的計畫直接實作。現在是執行階段，不要重新規劃、不要只重述計畫。
                必須使用可用工具直接執行計畫。
                # Plan
                """,
            eventKind: .message)
        let unchangedTail = ChatMessage(
            id: "assistant-tail",
            role: .assistant,
            text: "tail remains unchanged",
            eventKind: .message)

        XCTAssertNotEqual(
            ChatTranscriptDisplayFingerprint([ordinaryUser, unchangedTail]),
            ChatTranscriptDisplayFingerprint(
                [confirmedExecution, unchangedTail]))
    }
}
