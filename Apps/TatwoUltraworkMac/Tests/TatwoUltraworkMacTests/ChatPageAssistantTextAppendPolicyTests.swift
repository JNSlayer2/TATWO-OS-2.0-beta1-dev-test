import XCTest
@testable import TatwoUltraworkMac

final class ChatPageAssistantTextAppendPolicyTests: XCTestCase {
    func testFirstStreamedTokenReplacesEmptyPendingPlaceholderInPlace() {
        XCTAssertTrue(
            ChatPageAssistantTextAppendPolicy.isPendingPlaceholderBody(""))
        XCTAssertTrue(
            ChatPageAssistantTextAppendPolicy.isPendingPlaceholderBody("…"))
        XCTAssertTrue(
            ChatPageAssistantTextAppendPolicy.isPendingPlaceholderBody("..."))
        XCTAssertEqual(
            ChatPageAssistantTextAppendPolicy.appending("第一個 token", to: ""),
            "第一個 token")
        XCTAssertEqual(
            ChatPageAssistantTextAppendPolicy.appending("第一個 token", to: "…"),
            "第一個 token")
    }

    func testSubsequentFragmentsConcatenateWithoutDedup() {
        let first = ChatPageAssistantTextAppendPolicy.appending("Hello", to: "")
        let second = ChatPageAssistantTextAppendPolicy.appending("Hello", to: first)
        XCTAssertEqual(second, "HelloHello")
        XCTAssertEqual(
            ChatPageAssistantTextAppendPolicy.appending(" world", to: "Hello"),
            "Hello world")
    }

    func testPendingInFlightStatusIsTheBreathingTextActivityStatus() {
        XCTAssertEqual(
            ChatPageAssistantTextAppendPolicy.pendingInFlightStatus,
            "thinking")
        XCTAssertFalse(
            ChatPageAssistantTextAppendPolicy.isPendingPlaceholderBody("Hello"))
    }

    func testPendingPlaceholderRowIsVisibleCompactActivityNotInertStreaming() {
        let pending = ChatMessage(
            role: .assistant,
            text: "",
            status: ChatPageAssistantTextAppendPolicy.pendingInFlightStatus,
            eventKind: .message)
        let demotedStreaming = ChatMessage(
            role: .assistant,
            text: "",
            status: "streaming",
            eventKind: .message)

        XCTAssertFalse(pending.isInertAssistantStreamingPlaceholder)
        XCTAssertFalse(pending.isInertAssistantPlaceholder)
        XCTAssertTrue(demotedStreaming.isInertAssistantStreamingPlaceholder)
        XCTAssertTrue(demotedStreaming.isInertAssistantPlaceholder)

        let presentation = ChatInlineWorkPresentation.resolve(pending)
        XCTAssertEqual(presentation?.text, "正在思考")
        XCTAssertEqual(presentation?.isActive, true)
        XCTAssertEqual(presentation?.state, .running)
    }
}
