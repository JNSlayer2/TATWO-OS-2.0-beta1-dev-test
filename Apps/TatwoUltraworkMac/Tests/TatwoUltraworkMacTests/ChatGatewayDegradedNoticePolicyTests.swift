import XCTest

@testable import TatwoUltraworkMac

final class ChatGatewayDegradedNoticePolicyTests: XCTestCase {
    func testRecognizesStrictFirstLineDegradedNotices() {
        let notices = [
            "[gateway-notice] fable-5 upstream degraded (unavailable/operational): spawn E2BIG",
            "[gateway-notice] fable-5 upstream degraded (auth): OAuth session expired",
            "[gateway-notice] fable_5 upstream degraded (quota): session limit reached",
            "[gateway-notice] model.v5 upstream degraded (auth/quota): route cannot continue",
            "[gateway-notice] fable-5 upstream degraded (model_attestation/configuration): fallback detected",
            "[gateway-notice] gpt-5.6-sol upstream degraded (upstream_5xx/transient): upstream HTTP 503",
            "[gateway-notice] grok-4.6 upstream degraded (network/transient): connection reset",
            "\n\n[gateway-notice] fable-5 upstream degraded (unavailable): upstream offline",
        ]

        for notice in notices {
            XCTAssertTrue(
                ChatGatewayDegradedNoticePolicy.isRouteBlockedNotice(notice),
                notice)
        }
    }

    func testRejectsQuotedInlineLaterMalformedAndUnknownNotices() {
        let nonNotices = [
            "Normal assistant answer.\n[gateway-notice] fable-5 upstream degraded (auth): expired",
            "> [gateway-notice] fable-5 upstream degraded (auth): expired",
            "The text `[gateway-notice] fable-5 upstream degraded (auth): expired` is diagnostic.",
            "[gateway-notice] upstream degraded (auth): expired",
            "[gateway-notice] fable 5 upstream degraded (auth): expired",
            "[gateway-notice] fable-5 upstream degraded (): expired",
            "[gateway-notice] fable-5 upstream degraded (auth/): expired",
            "[gateway-notice] fable-5 upstream degraded (networking): expired",
            "[gateway-notice] fable-5 upstream degraded (auth):",
            "[gateway-notice] fable-5 upstream degraded (auth):   ",
        ]

        for text in nonNotices {
            XCTAssertFalse(
                ChatGatewayDegradedNoticePolicy.isRouteBlockedNotice(text),
                text)
        }
    }

    func testRouteBlockedNoticeCannotPublishCompletedLiveStatus() {
        let notice =
            "[gateway-notice] fable-5 upstream degraded (unavailable/operational): spawn E2BIG"

        XCTAssertTrue(ChatGatewayDegradedNoticePolicy.shouldMarkRouteBlocked(
            exitStatus: 0,
            wasUserInitiatedStop: false,
            assistantText: notice))
        XCTAssertFalse(ChatGatewayDegradedNoticePolicy.shouldMarkRouteBlocked(
            exitStatus: 1,
            wasUserInitiatedStop: false,
            assistantText: notice))
        XCTAssertFalse(ChatGatewayDegradedNoticePolicy.shouldMarkRouteBlocked(
            exitStatus: 0,
            wasUserInitiatedStop: true,
            assistantText: notice))
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.liveWorkStatus(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                assistantStatus: "route-blocked"),
            "blocked|本輪受阻")
    }

    func testNakedToolCallsGatewayNoticeIsCollapsedAndNeverLooksCompleted() {
        let notice = """
        [gateway-notice] fable-5 upstream degraded (model_attestation/configuration): {"tool_calls":[{"type":"function_call","name":"exec_command","arguments":{"cmd":"find /tmp"}}]}
        Codex model_gateway returned this as a completed assistant message so Codex App will not enter a retry loop.
        """

        let projection = ChatRuntimeTextHumanizer.projectedOutput(notice)

        XCTAssertTrue(projection.collapsedDiagnostic)
        XCTAssertTrue(projection.isBlocker)
        XCTAssertFalse(projection.text.contains("tool_calls"))
        XCTAssertFalse(projection.text.contains("exec_command"))
        XCTAssertEqual(projection.text, "模型路線執行失敗，本回合未完成。")
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.liveWorkStatus(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                assistantStatus: "blocked"),
            "blocked|本輪受阻")
    }

    func testBlockedTerminalCannotPromoteGatewayContinuation() {
        XCTAssertFalse(
            ChatAssistantTerminalStatusPolicy.allowsContinuationPromotion(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                assistantStatus: "route-blocked"))
        XCTAssertFalse(
            ChatAssistantTerminalStatusPolicy.allowsContinuationPromotion(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                assistantStatus: "blocked|本輪受阻"))
        XCTAssertFalse(
            ChatAssistantTerminalStatusPolicy.allowsContinuationPromotion(
                exitStatus: 143,
                wasUserInitiatedStop: true,
                assistantStatus: nil))
        XCTAssertTrue(
            ChatAssistantTerminalStatusPolicy.allowsContinuationPromotion(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                assistantStatus: nil))
    }

    func testSIGTERMOnlyLooksStoppedWhenUserActuallyRequestedStop() {
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedStatus(
                exitStatus: 143,
                wasUserInitiatedStop: false,
                currentStatus: nil),
            "failed 143")
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.liveWorkStatus(
                exitStatus: 143,
                wasUserInitiatedStop: false,
                assistantStatus: nil),
            "failed|exit 143")
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedStatus(
                exitStatus: 143,
                wasUserInitiatedStop: true,
                currentStatus: nil),
            "stopped")
    }

    func testNonUserNonzeroExitProjectsAsFailureIssue() {
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedEventKind(
                exitStatus: 143,
                wasUserInitiatedStop: false,
                currentEventKind: .message),
            .failure)
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedEventKind(
                exitStatus: 143,
                wasUserInitiatedStop: true,
                currentEventKind: .message),
            .message)
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedEventKind(
                exitStatus: 143,
                wasUserInitiatedStop: true,
                currentEventKind: .failure),
            .message)
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedEventKind(
                exitStatus: 1,
                wasUserInitiatedStop: false,
                currentEventKind: .message),
            .failure)
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.resolvedEventKind(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                currentEventKind: .message),
            .message)
    }

    func testOrdinarySuccessfulAnswerRemainsCompleted() {
        let answer = "Normal assistant answer."

        XCTAssertFalse(
            ChatGatewayDegradedNoticePolicy.isRouteBlockedNotice(answer))
        XCTAssertEqual(
            ChatAssistantTerminalStatusPolicy.liveWorkStatus(
                exitStatus: 0,
                wasUserInitiatedStop: false,
                assistantStatus: nil),
            "completed|本輪完成")
    }

    func testExitedAssistantPublishesMatchedNoticeAsRouteBlockedFailure() throws {
        let source = try ChatPageSourceScanner.combinedSource()
        let preparation = try XCTUnwrap(source.slice(
            from: "private func preparedExitedAssistantMessage(",
            through: "private func preparedFailureAssistantMessage("))

        XCTAssertTrue(preparation.contains(
            "ChatGatewayDegradedNoticePolicy.shouldMarkRouteBlocked("))
        XCTAssertTrue(preparation.contains(
            "ChatAssistantTerminalStatusPolicy.resolvedEventKind("))
        XCTAssertTrue(preparation.contains(#"candidate.status = "route-blocked""#))
        XCTAssertTrue(preparation.contains("candidate.eventKind = .failure"))

        let finalization = try XCTUnwrap(source.slice(
            from: "func finishActiveAssistant(",
            through: "private func appendRawFallback("))
        XCTAssertEqual(
            finalization.components(
                separatedBy:
                    "ChatAssistantTerminalStatusPolicy.resolvedEventKind(")
                .count - 1,
            2)
    }
}
