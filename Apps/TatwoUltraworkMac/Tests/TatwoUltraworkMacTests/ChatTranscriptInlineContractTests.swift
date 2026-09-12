import Foundation
import XCTest
import TatwoUltraworkCore
@testable import TatwoUltraworkMac

final class ChatTranscriptInlineContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - Source contracts (transcript-only activity)

    func testInlineWorkStateMachineUsesResponsibleTextAndStopsTerminalAnimation() throws {
        let reconnecting = try XCTUnwrap(
            ChatInlineWorkPresentation.resolve(
                ChatMessage(
                    role: .assistant,
                    text: "",
                    status: "reconnecting|連線中斷，正在續接 2/3",
                    eventKind: .message)))
        XCTAssertEqual(reconnecting.state, .reconnecting)
        XCTAssertEqual(reconnecting.text, "連線中斷，正在續接 2/3")
        XCTAssertTrue(reconnecting.isActive)

        let failed = try XCTUnwrap(
            ChatInlineWorkPresentation.resolve(
                ChatMessage(
                    role: .assistant,
                    text: "swift test",
                    status: "failed|測試程序未完成",
                    eventKind: .toolUse)))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.text, "工作中斷 · 測試程序未完成")
        XCTAssertFalse(failed.isActive)

        let cancelled = try XCTUnwrap(
            ChatInlineWorkPresentation.resolve(
                ChatMessage(
                    role: .assistant,
                    text: "",
                    status: "stopped",
                    eventKind: .message)))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.text, "已取消，未採用後續結果")
        XCTAssertFalse(cancelled.isActive)
    }

    func testDisplayBuilderGroupsWorkInsideAssistantTurnAndKeepsFinalContentSeparate() throws {
        let turnID = "turn-inline"
        let messages = [
            ChatMessage(
                id: "activity-1",
                role: .assistant,
                text: "讀取 4 個檔案",
                status: "completed|讀取 4 個檔案",
                modelID: "gpt-5.6-sol",
                eventKind: .toolUse,
                turnID: turnID,
                createdAt: Date(timeIntervalSince1970: 10)),
            ChatMessage(
                id: "activity-2",
                role: .assistant,
                text: "Chat tests",
                status: "completed|4 項測試通過",
                modelID: "gpt-5.6-sol",
                eventKind: .toolUse,
                turnID: turnID,
                createdAt: Date(timeIntervalSince1970: 11)),
            ChatMessage(
                id: turnID,
                role: .assistant,
                text: "已完成 Chat 修復。",
                modelID: "gpt-5.6-sol",
                eventKind: .message,
                turnID: turnID,
                createdAt: Date(timeIntervalSince1970: 12)),
        ]

        let rows = ChatTranscriptDisplayBuilder.build(messages)
        XCTAssertEqual(rows.count, 2)
        guard case .workTimeline(let timeline) = rows[0] else {
            return XCTFail("work events must be grouped into one inline timeline")
        }
        XCTAssertEqual(timeline.turnID, turnID)
        XCTAssertEqual(timeline.messages.count, 2)
        XCTAssertEqual(timeline.presentation.state, .completed)
        XCTAssertEqual(timeline.presentation.text, "已完成工作 · 2 個步驟")
        XCTAssertFalse(timeline.presentation.isActive)
        guard case .message(let final) = rows[1] else {
            return XCTFail("final assistant content must remain a normal transcript row")
        }
        XCTAssertEqual(final.text, "已完成 Chat 修復。")
    }

    func testDisplayBuilderKeepsPlanQuestionsAsInteractiveMessage() throws {
        let message = ChatMessage(
            id: "plan-questions",
            role: .assistant,
            text: "",
            status: "waiting",
            eventKind: .message,
            planQuestions: [
                PlanQuestionV1(
                    id: "scope",
                    question: "Which scope?",
                    options: [
                        .init(label: "Current project", detail: "Keep it narrow."),
                    ]),
            ])

        let rows = ChatTranscriptDisplayBuilder.build([message])

        XCTAssertEqual(rows.count, 1)
        guard case .message(let interactiveMessage) = rows[0] else {
            return XCTFail("plan questions must not be swallowed by work timeline")
        }
        XCTAssertEqual(interactiveMessage.planQuestions, message.planQuestions)
    }

    func testTerminalInlineStateFencesLateRunningActivityForSameTurn() throws {
        let turnID = "turn-terminal-fence"
        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: turnID,
                workMessages: [
                    ChatMessage(
                        id: "activity-running",
                        role: .assistant,
                        text: "",
                        status: "testing|Chat runtime",
                        eventKind: .toolUse,
                        turnID: turnID,
                        createdAt: Date(timeIntervalSince1970: 20)),
                    ChatMessage(
                        id: "activity-failed",
                        role: .assistant,
                        text: "",
                        status: "failed|runtime disconnected",
                        eventKind: .toolUse,
                        turnID: turnID,
                        createdAt: Date(timeIntervalSince1970: 21)),
                    ChatMessage(
                        id: "activity-late-running",
                        role: .assistant,
                        text: "",
                        status: "working|late callback",
                        eventKind: .toolUse,
                        turnID: turnID,
                        createdAt: Date(timeIntervalSince1970: 22)),
                ],
                turnMessages: []))

        XCTAssertEqual(timeline.presentation.state, .failed)
        XCTAssertEqual(timeline.messages.map(\.id), [
            "activity-running",
            "activity-failed",
        ])
        XCTAssertEqual(timeline.presentation.text, "工作中斷 · 2 個步驟")
        XCTAssertFalse(timeline.presentation.isActive)
    }

    func testCancelledTerminalRejectsLateCallbacksUntilExplicitRetryEpoch() throws {
        let turnID = "turn-cancelled-fence"
        let acceptedWork = [
            ChatMessage(
                id: "activity-running",
                role: .assistant,
                text: "",
                status: "testing|targeted gate",
                eventKind: .toolUse,
                turnID: turnID),
            ChatMessage(
                id: "activity-cancelled",
                role: .assistant,
                text: "",
                status: "cancelled|user requested",
                eventKind: .message,
                turnID: turnID),
        ]
        let baseline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: turnID,
                workMessages: acceptedWork,
                turnMessages: []))
        let rows = ChatTranscriptDisplayBuilder.build(
            acceptedWork + [
                ChatMessage(
                    id: "activity-late-active",
                    role: .assistant,
                    text: "",
                    status: "working|late active callback",
                    eventKind: .message,
                    turnID: turnID),
                ChatMessage(
                    id: "activity-late-tool",
                    role: .assistant,
                    text: "",
                    status: "calling-tool|late tool callback",
                    eventKind: .toolUse,
                    turnID: turnID),
                ChatMessage(
                    id: "activity-late-completed",
                    role: .assistant,
                    text: "",
                    status: "completed|late completed callback",
                    eventKind: .toolUse,
                    turnID: turnID),
            ])

        XCTAssertEqual(rows.count, 1)
        guard case .workTimeline(let timeline) = rows[0] else {
            return XCTFail("cancelled turn must retain one authoritative timeline")
        }
        XCTAssertEqual(timeline.presentation, baseline.presentation)
        XCTAssertEqual(timeline.presentation.state, .cancelled)
        XCTAssertEqual(
            timeline.presentation.text,
            "已取消，未採用後續結果 · 2 個步驟")
        XCTAssertFalse(timeline.presentation.isActive)
        XCTAssertEqual(
            timeline.messages.map(\.id),
            ["activity-running", "activity-cancelled"])
        XCTAssertEqual(
            timeline.messages
                .compactMap(ChatInlineWorkPresentation.resolve)
                .filter { !$0.isActive }
                .map(\.state),
            [.cancelled])
    }

    func testExplicitReconnectStartsNewRetryEpochAfterTerminalState() throws {
        let turnID = "turn-retry-epoch"
        let timeline = try XCTUnwrap(
            ChatInlineWorkTimeline.make(
                turnID: turnID,
                workMessages: [
                    ChatMessage(
                        id: "activity-failed",
                        role: .assistant,
                        text: "",
                        status: "failed|first attempt",
                        eventKind: .toolUse,
                        turnID: turnID),
                    ChatMessage(
                        id: "activity-reconnecting",
                        role: .assistant,
                        text: "",
                        status: "reconnecting|正在續接 2/3",
                        eventKind: .message,
                        turnID: turnID),
                    ChatMessage(
                        id: "activity-retry-running",
                        role: .assistant,
                        text: "",
                        status: "testing|retry",
                        eventKind: .toolUse,
                        turnID: turnID),
                ],
                turnMessages: []))

        XCTAssertEqual(timeline.presentation.state, .tool)
        XCTAssertEqual(timeline.presentation.text, "正在測試 retry")
        XCTAssertTrue(timeline.presentation.isActive)
    }

    func testFailureAndCancellationProseRemainNormalTranscriptRows() {
        for (turnID, status, text, expectedState, expectedTimelineText) in [
            (
                "turn-failure-prose",
                "failed|compiler error",
                "編譯失敗，已保留錯誤摘要。",
                ChatInlineWorkState.failed,
                "工作中斷 · 1 個步驟"
            ),
            (
                "turn-cancel-prose",
                "cancelled",
                "已依照你的要求停止。",
                ChatInlineWorkState.cancelled,
                "已取消，未採用後續結果 · 1 個步驟"
            ),
            (
                "turn-cancel-detail-prose",
                "cancelled|user requested stop",
                "已依照你的要求取消。",
                ChatInlineWorkState.cancelled,
                "已取消，未採用後續結果 · 1 個步驟"
            ),
            (
                "turn-stopped-detail-prose",
                "stopped|manual stop",
                "工作已停止，未採用後續結果。",
                ChatInlineWorkState.cancelled,
                "已取消，未採用後續結果 · 1 個步驟"
            ),
            (
                "turn-canceled-detail-prose",
                "canceled|user requested",
                "已依照你的要求取消。",
                ChatInlineWorkState.cancelled,
                "已取消，未採用後續結果 · 1 個步驟"
            ),
            (
                "turn-cancelled-normalized-prose",
                "  CANCELLED | user requested  ",
                "已依照你的要求停止。",
                ChatInlineWorkState.cancelled,
                "已取消，未採用後續結果 · 1 個步驟"
            ),
            (
                "turn-completed-detail-prose",
                "completed|normal",
                "工作正常完成。",
                ChatInlineWorkState.completed,
                "已完成工作 · 1 個步驟"
            ),
        ] {
            let rows = ChatTranscriptDisplayBuilder.build([
                ChatMessage(
                    id: "\(turnID)-work",
                    role: .assistant,
                    text: "",
                    status: "testing|targeted gate",
                    eventKind: .toolUse,
                    turnID: turnID),
                ChatMessage(
                    id: "\(turnID)-final",
                    role: .assistant,
                    text: text,
                    status: status,
                    eventKind: .message,
                    turnID: turnID),
            ])

            XCTAssertEqual(rows.count, 2)
            guard case .workTimeline(let timeline) = rows[0] else {
                return XCTFail("terminal turn must retain its inline timeline")
            }
            XCTAssertEqual(timeline.presentation.state, expectedState)
            XCTAssertEqual(timeline.presentation.text, expectedTimelineText)
            XCTAssertFalse(timeline.presentation.isActive)
            guard case .message(let final) = rows[1] else {
                return XCTFail("terminal assistant prose must stay visible")
            }
            XCTAssertEqual(final.text, text)
        }
    }

    func testFiveHundredItemTranscriptDeterministicallyGroupsLocalWorkAndKeepsRemoteRows() {
        var messages: [ChatMessage] = []
        messages.reserveCapacity(500)
        for index in 0..<100 {
            let turnID = "turn-\(index)"
            messages.append(
                ChatMessage(
                    id: "activity-\(index)-1",
                    role: .assistant,
                    text: "",
                    status: "testing|step \(index)",
                    eventKind: .toolUse,
                    turnID: turnID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index * 5))))
            messages.append(
                ChatMessage(
                    id: "activity-\(index)-2",
                    role: .assistant,
                    text: "",
                    status: "completed|step \(index)",
                    eventKind: .toolUse,
                    turnID: turnID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index * 5 + 1))))
            messages.append(
                ChatMessage(
                    id: "activity-\(index)-3",
                    role: .assistant,
                    text: "",
                    status: "working|late callback \(index)",
                    eventKind: .toolUse,
                    turnID: turnID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index * 5 + 2))))
            messages.append(
                ChatMessage(
                    id: "final-\(index)",
                    role: .assistant,
                    text: "final \(index)",
                    eventKind: .message,
                    turnID: turnID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index * 5 + 3))))
            messages.append(
                ChatMessage(
                    id: "remote-\(index)",
                    role: .assistant,
                    text: "remote \(index)",
                    status: ChatRemoteJobInlinePresentation.status(
                        state: .running,
                        runtimeTruth: .observedThisProcess,
                        blocker: nil,
                        details: ["jobID": "job-\(index)"]),
                    eventKind: .toolUse,
                    turnID: turnID,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index * 5 + 4))))
        }

        let rows = ChatTranscriptDisplayBuilder.build(messages)

        XCTAssertEqual(messages.count, 500)
        XCTAssertEqual(rows.count, 300)
        XCTAssertEqual(rows.first?.id, "chat-inline-work-timeline:turn-0")
        XCTAssertEqual(rows.last?.id, "message:remote-99")

        for index in [0, 49, 99] {
            let rowOffset = index * 3
            guard case .workTimeline(let timeline) = rows[rowOffset] else {
                return XCTFail("turn \(index) must begin with its local work timeline")
            }
            XCTAssertEqual(timeline.turnID, "turn-\(index)")
            XCTAssertEqual(
                timeline.messages.map(\.id),
                [
                    "activity-\(index)-1",
                    "activity-\(index)-2",
                ])
            XCTAssertEqual(
                timeline.messages.map(\.status),
                ["testing|step \(index)", "completed|step \(index)"])
            XCTAssertEqual(timeline.presentation.state, .completed)
            XCTAssertEqual(
                timeline.presentation.text,
                "已完成工作 · 2 個步驟")
            XCTAssertFalse(timeline.presentation.isActive)

            guard case .message(let finalMessage) = rows[rowOffset + 1] else {
                return XCTFail("turn \(index) final prose must follow its timeline")
            }
            XCTAssertEqual(finalMessage.id, "final-\(index)")
            XCTAssertEqual(finalMessage.text, "final \(index)")

            guard case .message(let remoteMessage) = rows[rowOffset + 2] else {
                return XCTFail("turn \(index) remote row must follow final prose")
            }
            XCTAssertEqual(remoteMessage.id, "remote-\(index)")
            XCTAssertEqual(remoteMessage.text, "remote \(index)")
            let remotePayload = ChatRemoteJobInlinePresentation.payload(
                from: remoteMessage.status)
            XCTAssertEqual(
                remotePayload?.state,
                .running)
            XCTAssertEqual(remotePayload?.details["jobID"], "job-\(index)")
        }

        XCTAssertEqual(
            rows.filter {
                guard case .workTimeline = $0 else { return false }
                return true
            }.count,
            100)
        XCTAssertEqual(
            rows.filter {
                guard case .message(let message) = $0 else { return false }
                return message.id.hasPrefix("remote-")
            }.count,
            100)
    }

    func testRemoteInlineLabelUsesStructuredTerminalOutcomeWithoutParsingNarrative() {
        let payload = ChatRemoteJobInlinePresentation.Payload(
            state: nil,
            terminalOutcome: .failed,
            blocker: "terminal",
            details: [:])

        XCTAssertEqual(
            ChatRemoteJobInlineLabel.title(
                for: payload,
                narrative: ""),
            ChatRemoteJobTerminalOutcome.failed.rawValue)
        XCTAssertEqual(
            ChatRemoteJobInlineLabel.title(
                for: payload,
                narrative: "遠端工作失敗：terminal"),
            "遠端工作失敗：terminal")
    }

    func testTranscriptProjectionSuppressesMeaninglessEmptyAssistantPlaceholders() {
        let placeholder = ChatMessage(
            role: .assistant,
            text: "",
            status: "streaming",
            eventKind: .message)
        let emptyAssistant = ChatMessage(
            role: .assistant,
            text: "",
            status: nil,
            eventKind: .message)
        let actionableFailure = ChatMessage(
            role: .assistant,
            text: "",
            status: "failed",
            eventKind: .message)
        let visibleStream = ChatMessage(
            role: .assistant,
            text: "已收到第一段",
            status: "streaming",
            eventKind: .message)
        let userEllipsis = ChatMessage(
            role: .user,
            text: "…",
            status: nil,
            eventKind: .message)
        let activity = ChatMessage(
            role: .assistant,
            text: "",
            status: "thinking",
            eventKind: .thinking)
        let liveInlineActivity = ChatMessage(
            role: .assistant,
            text: "",
            status: "building|TatwoUltraworkMac",
            eventKind: .message)

        XCTAssertTrue(placeholder.isInertAssistantStreamingPlaceholder)
        XCTAssertTrue(placeholder.isInertAssistantPlaceholder)
        XCTAssertTrue(emptyAssistant.isInertAssistantPlaceholder)
        XCTAssertFalse(actionableFailure.isInertAssistantPlaceholder)
        XCTAssertFalse(visibleStream.isInertAssistantStreamingPlaceholder)
        XCTAssertFalse(visibleStream.isInertAssistantPlaceholder)
        XCTAssertFalse(userEllipsis.isInertAssistantStreamingPlaceholder)
        XCTAssertFalse(userEllipsis.isInertAssistantPlaceholder)
        XCTAssertFalse(activity.isInertAssistantStreamingPlaceholder)
        XCTAssertFalse(activity.isInertAssistantPlaceholder)
        XCTAssertFalse(liveInlineActivity.isInertAssistantStreamingPlaceholder)
        XCTAssertFalse(liveInlineActivity.isInertAssistantPlaceholder)

        let pendingInFlight = ChatMessage(
            role: .assistant,
            text: "",
            status: ChatPageAssistantTextAppendPolicy.pendingInFlightStatus,
            eventKind: .message)
        XCTAssertFalse(pendingInFlight.isInertAssistantStreamingPlaceholder)
        XCTAssertFalse(pendingInFlight.isInertAssistantPlaceholder)
        XCTAssertEqual(
            ChatInlineWorkPresentation.resolve(pendingInFlight)?.text,
            "正在思考")
        XCTAssertEqual(
            ChatInlineWorkPresentation.resolve(pendingInFlight)?.isActive,
            true)
    }

    func testChatPageKeepsActivityInTranscriptInsteadOfAComposerStrip() throws {
        let chatPage = try ChatSourceFamily.read("ChatPage.swift")
        let leafViews = try ChatSourceFamily.read("ChatPageLeafViews.swift")
        let obsoleteStripPath = repoRoot.appendingPathComponent(
            "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatActivityFeedStrip.swift")

        // Activity belongs to Codex-style inline transcript rows, not another
        // "recent/live work" box above the composer.
        XCTAssertFalse(chatPage.contains("liveWorkActivityStrip"))
        XCTAssertFalse(chatPage.contains("private var liveWorkActivityStrip: some View"))
        XCTAssertFalse(chatPage.contains("model.liveWorkActivities"))
        XCTAssertTrue(leafViews.contains("CodexActivityInlineText("))
        XCTAssertTrue(leafViews.contains("private struct CodexActivityInlineText: View"))
        let activityTextStart = try XCTUnwrap(
            leafViews.range(of: "private struct CodexActivityInlineText: View"))
        let activityTextEnd = try XCTUnwrap(
            leafViews.range(
                of: "\n\nstruct MatrixChip: View",
                range: activityTextStart.lowerBound..<leafViews.endIndex))
        let activityText = String(
            leafViews[activityTextStart.lowerBound..<activityTextEnd.lowerBound])
        XCTAssertFalse(activityText.contains("TimelineView"))
        XCTAssertTrue(
            activityText.contains(
                "@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        XCTAssertTrue(activityText.contains(".repeatForever(autoreverses: true)"))
        XCTAssertTrue(
            activityText.contains(
                "guard isActive, !reduceMotion, !Self.isSnapshotExport else"))
        XCTAssertTrue(activityText.contains(".onChange(of: isActive)"))
        XCTAssertTrue(activityText.contains(".onChange(of: reduceMotion)"))
        XCTAssertTrue(activityText.contains("withAnimation(.none)"))
        XCTAssertTrue(
            activityText.contains("TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"))
        XCTAssertTrue(
            activityText.contains("TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"))
        XCTAssertTrue(leafViews.contains("ChatTranscriptDisplayBuilder"))
        XCTAssertTrue(leafViews.contains("ChatInlineWorkTimelineView"))
        XCTAssertTrue(leafViews.contains("chat-inline-work-timeline-"))
        let assistantBodyStart = try XCTUnwrap(
            leafViews.range(of: "private var transcriptTextAndAttachmentsBody: some View"))
        let assistantBodyEnd = try XCTUnwrap(
            leafViews.range(
                of: "@ViewBuilder\n    private func transcriptText",
                range: assistantBodyStart.lowerBound..<leafViews.endIndex))
        let assistantBody = String(
            leafViews[assistantBodyStart.lowerBound..<assistantBodyEnd.lowerBound])
        XCTAssertFalse(assistantBody.contains("Text(\"…\")"))

        // The paused queue action stays available as a compact toolbar control.
        XCTAssertTrue(chatPage.contains("if model.queuedChatTurnCount > 0"))
        XCTAssertTrue(chatPage.contains("model.chatQueuePaused"))
        XCTAssertTrue(chatPage.contains("model.resumeQueuedChatTurns()"))

        let cacheViewStart = try XCTUnwrap(
            leafViews.range(of: "private struct ChatAssistantTranscriptCachedText: View"))
        let cacheViewEnd = try XCTUnwrap(
            leafViews.range(
                of: "\n\nenum ChatRemoteJobInlineLabel {",
                range: cacheViewStart.lowerBound..<leafViews.endIndex))
        let cacheView = String(leafViews[cacheViewStart.lowerBound..<cacheViewEnd.lowerBound])
        // 2026-08-29 合約更新：舊斷言鎖死 `cacheKey` 與
        // `latestRequestedKey` 的舊字面形式。實作現在於 task 起點擷取
        // requestedIdentity / requestedMarkdown，並由 beginRequest 產生固定大小的
        // request generation；isCurrent 同時驗證同 messageID 的最新 generation
        // 與 key metadata。合約本體仍是：cache miss 清舊 document、parse 前與
        // MainActor 落地後各一組 identity/latest-request stale gate、parse 只能吃
        // task 起點擷取的 markdown、store 受同一 request 保護、view 不得自行
        // Task.detached。
        let cacheViewCompact = cacheView.filter { !$0.isWhitespace }
        XCTAssertTrue(cacheView.contains("document = nil"))
        // parse 吃的是 task 起點擷取的 markdown，不是每次 body 重讀的屬性。
        XCTAssertTrue(cacheViewCompact.contains("letrequestedMarkdown=markdown"))
        XCTAssertTrue(
            cacheViewCompact.contains(
                "letrequest=cache.beginRequest(for:requestedKey)"))
        let parseCall =
            "letparsed=awaitcache.parseDocumentWithMetadata("
                + "markdown:requestedMarkdown)"
        XCTAssertTrue(
            cacheViewCompact.contains(parseCall))
        XCTAssertFalse(
            cacheViewCompact.contains(
                "parseDocumentWithMetadata(markdown:markdown)"))
        // stale gate 必須成雙：parse 之前一組、MainActor 落地之後一組。
        let identityGate = "guardrequestedIdentity==renderIdentityelse{return}"
        let latestRequestGate =
            "guardcache.isCurrent(request,for:requestedKey)else{return}"
        XCTAssertEqual(
            cacheViewCompact.components(separatedBy: identityGate).count - 1, 2)
        XCTAssertEqual(
            cacheViewCompact.components(separatedBy: latestRequestGate).count - 1, 2)
        let parseStart = try XCTUnwrap(cacheViewCompact.range(of: parseCall))
        let preParseBody = String(cacheViewCompact[..<parseStart.lowerBound])
        XCTAssertTrue(preParseBody.contains(identityGate))
        XCTAssertTrue(preParseBody.contains(latestRequestGate))
        let landingStart = try XCTUnwrap(cacheViewCompact.range(of: "awaitMainActor.run{"))
        let landingBody = String(cacheViewCompact[landingStart.upperBound...])
        XCTAssertTrue(landingBody.contains(identityGate))
        XCTAssertTrue(landingBody.contains(latestRequestGate))
        XCTAssertTrue(
            landingBody.contains(
                "guardcache.storeIfCurrent(parsed.document,"
                    + "documentResidentBytes:parsed.estimatedResidentBytes,"
                    + "for:requestedKey,request:request)else{return}"))
        XCTAssertFalse(cacheView.contains("Task.detached"))

        // The rejected boxed V2 skeleton is removed, not merely hidden behind
        // another feature flag that could reintroduce duplicate activity UI.
        XCTAssertFalse(chatPage.contains("ChatActivityFeedFeatureFlags"))
        XCTAssertFalse(chatPage.contains("ChatActivityFeedStrip("))
        XCTAssertFalse(chatPage.contains("chat-activity-feed-strip-v2"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: obsoleteStripPath.path),
            "rejected boxed activity strip must not remain in the App source target")
    }

    func testComposerKeepsPersistentStatusDrawerWithoutRepeatingRunningActivity() throws {
        let chatPage = try ChatSourceFamily.read("ChatPage.swift")
        // 2026-08-20 使用者裁決回歸：獨立梯形抽屜保留（一體化撤回），
        // 極光只在 composerStatusBar 內換玻璃皮——原始呼叫點合約還原。
        XCTAssertTrue(
            chatPage.contains(
                "if model.mode != .cli {\n                composerStatusBar"))
        let statusBarCallSiteStart = try XCTUnwrap(
            chatPage.range(
                of: "if model.mode != .cli {\n                composerStatusBar"))
        let statusBarCallSiteBody = String(chatPage[statusBarCallSiteStart.lowerBound...])
        let statusBarCallSiteEnd = try XCTUnwrap(
            statusBarCallSiteBody.range(
                of: "if model.mode == .cli, model.lastCommand != \"尚未執行\""))
        let statusBarCallSite = String(
            statusBarCallSiteBody[..<statusBarCallSiteEnd.lowerBound])
        XCTAssertTrue(statusBarCallSite.contains(".zIndex(-1)"))
        XCTAssertTrue(statusBarCallSite.contains(".padding(.top, -13)"))
        XCTAssertFalse(
            chatPage.contains(
                "if model.mode != .cli, !composerStatusText.isEmpty"))
        let drawerStart = try XCTUnwrap(
            chatPage.range(of: "var composerStatusBar: some View"))
        let drawerBody = String(chatPage[drawerStart.lowerBound...])
        let drawerEnd = try XCTUnwrap(
            drawerBody.range(of: "func composerStatusTextColor"))
        let drawerOnly = String(drawerBody[..<drawerEnd.lowerBound])
        XCTAssertFalse(drawerOnly.contains("if !composerStatusText.isEmpty"))
        XCTAssertTrue(
            drawerOnly.contains(
                "let state = model.composerFooterState"))
        XCTAssertTrue(
            drawerOnly.contains(
                "let hasActiveStatus = state.isActive"))
        XCTAssertTrue(
            drawerOnly.contains(
                "let visibleStatusText = state.presentationText"))
        XCTAssertTrue(
            drawerOnly.contains(
                "? composerStatusDotColor(for: state)"))
        // 2026-08-21 修約：composerHint 被 8/13 改版逐出抽屜後全 app 零渲染點，
        // 所有 flashComposerHint（含 /goal //plg 失敗原因）永遠不可見＝閉環
        // 驗收「靜默丟棄」的顯示層真兇。抽屜自此為 hint 官方顯示面，hint
        // 優先於中性狀態文字；仍維持單點單文字行、無新形狀。
        XCTAssertTrue(
            drawerOnly.contains("Text(showsHint ? (hint ?? \"\") : visibleStatusText)"))
        XCTAssertEqual(drawerOnly.components(separatedBy: "Circle()").count - 1, 1)
        XCTAssertEqual(
            drawerOnly.components(
                separatedBy: "Text(showsHint ? (hint ?? \"\") : visibleStatusText)"
            ).count - 1, 1)
        XCTAssertFalse(drawerOnly.contains("Work OS 狀態"))
        XCTAssertTrue(
            drawerOnly.contains(
                ".font(.system(size: 12, weight: showsHint ? .semibold : .medium))"))
        XCTAssertTrue(drawerOnly.contains(": Color.secondary.opacity(0.88))"))
        XCTAssertTrue(
            drawerOnly.contains(
                "RoundedInvertedTrapezoid(sideSlope: 5, cornerRadius: 16)"))
        XCTAssertTrue(drawerOnly.contains(".padding(.horizontal, 12)"))
        XCTAssertTrue(drawerOnly.contains(".padding(.horizontal, 14)"))
        // 2026-08-13 使用者實機裁定：抽屜必須黏合輸入框下緣（tuck）。call site zIndex(-1)+top(-13)，body top(13)/bottom(5) 取代 vertical(5)。
        XCTAssertTrue(drawerOnly.contains(".padding(.top, 13)"))
        XCTAssertTrue(drawerOnly.contains(".padding(.bottom, 5)"))
        XCTAssertTrue(drawerOnly.contains(".fill(Color.primary.opacity(0.075))"))
        XCTAssertTrue(drawerOnly.contains(".stroke(Color.primary.opacity(0.16), lineWidth: 1)"))
        XCTAssertTrue(
            drawerOnly.contains(
                ".frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)"))
        XCTAssertFalse(drawerOnly.contains(".padding(.top, -13)"))
        XCTAssertFalse(drawerOnly.contains(".zIndex(-1)"))
        XCTAssertFalse(
            drawerOnly.range(
                of: #"\.padding\(\.top,\s*-\d+(\.\d+)?\)"#,
                options: .regularExpression) != nil)
        XCTAssertFalse(
            drawerOnly.range(
                of: #"\.zIndex\(\s*-\d+(\.\d+)?\s*\)"#,
                options: .regularExpression) != nil)
        XCTAssertFalse(
            drawerOnly.range(
                of: #"\.offset\(\s*(x:\s*[^,]+,\s*)?y:\s*-\d+(\.\d+)?\s*\)"#,
                options: .regularExpression) != nil)
        // 2026-08-21 修約：hint 顯示層重建（見上）——抽屜必須讀 composerHint。
        XCTAssertTrue(drawerOnly.contains("model.composerHint"))
        XCTAssertTrue(drawerOnly.contains("let showsHint = !(hint ?? \"\").isEmpty"))
        XCTAssertFalse(drawerOnly.contains("selectedWorkOSStateMessage"))
        XCTAssertFalse(drawerOnly.contains("selectedRouteCooldownStatusText"))
        XCTAssertFalse(drawerOnly.contains("model.isRunning"))
        XCTAssertFalse(drawerOnly.contains("liveWorkActivities"))
        XCTAssertFalse(drawerOnly.contains("planning"))
        XCTAssertFalse(drawerOnly.contains("checking"))
        XCTAssertFalse(drawerOnly.contains("passed"))

        let pageModel = try ChatSourceFamily.read("ChatPageModel.swift")
        let projectorStart = try XCTUnwrap(
            pageModel.range(of: "var composerFooterState: ChatComposerFooterState"))
        let projectorBody = String(pageModel[projectorStart.lowerBound...])
        let projectorEnd = try XCTUnwrap(
            projectorBody.range(of: "var canResumeActiveGoal: Bool"))
        let projectorOnly = String(projectorBody[..<projectorEnd.lowerBound])
        XCTAssertTrue(projectorOnly.contains("isCLI: mode == .cli"))
        XCTAssertTrue(
            projectorOnly.contains(
                "explicitWorkScope: selectedThread?.loopsConfig != nil"))
        XCTAssertTrue(
            projectorOnly.contains(
                "activePLGRun?.phase == .rollbackRequired"))
        XCTAssertTrue(
            projectorOnly.contains(
                "activePLGRun?.phase == .awaitingHumanAuth"))
        XCTAssertTrue(
            projectorOnly.contains(
                "workOSBindingMutationRecoveryBlocked"))
        XCTAssertTrue(
            projectorOnly.contains(
                "selectedRouteCooldownGate.canDispatch"))
        XCTAssertFalse(projectorOnly.contains("selectedRouteCooldownStatusText"))
        XCTAssertFalse(projectorOnly.contains("composerHint"))
        XCTAssertFalse(projectorOnly.contains("selectedWorkOSStateMessage"))
        XCTAssertFalse(projectorOnly.contains("isRunning"))
        XCTAssertFalse(projectorOnly.contains("request_user_input"))
        XCTAssertFalse(projectorOnly.contains("elicitation"))
        XCTAssertFalse(projectorOnly.contains("contractChanged"))
    }

    func testChatKeepsGoalStatusInRightThreadCardAndGoalJudgeAboveComposer() throws {
        let chatPage = try ChatSourceFamily.read("ChatPage.swift")
        let leafViews = try ChatSourceFamily.read("ChatPageLeafViews.swift")
        let pageModel = try ChatSourceFamily.read("ChatPageModel.swift")
        let journalIntegration = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatTranscriptJournalIntegration.swift"),
            encoding: .utf8)
        let deviceCard = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicePressureMonitorCard.swift"),
            encoding: .utf8)
        let mainPaneStart = try XCTUnwrap(
            chatPage.range(of: "func mainPane("))
        let floatingPanelStart = try XCTUnwrap(
            chatPage.range(
                of: "@ViewBuilder\n    func chatFloatingPanelOverlay",
                range: mainPaneStart.lowerBound..<chatPage.endIndex))
        let mainPane = String(
            chatPage[mainPaneStart.lowerBound..<floatingPanelStart.lowerBound])

        XCTAssertTrue(
            mainPane.contains(
                "if model.mode == .chat,\n"
                    + "               model.selectedThreadHasWorkOSGoal"))
        XCTAssertTrue(
            mainPane.contains(
                "activeGoalInlineCard(contentMaxWidth: contentMaxWidth)"))
        XCTAssertTrue(chatPage.contains("var threadPlanSection: some View"))
        XCTAssertTrue(chatPage.contains("if model.shouldShowActiveGoalInlineCard"))
        XCTAssertFalse(chatPage.contains("ChatActivityFeedStrip("))
        XCTAssertTrue(leafViews.contains("chat-remote-job-inline-item"))
        XCTAssertTrue(leafViews.contains("DisclosureGroup(\"詳細資料\")"))
        XCTAssertTrue(journalIntegration.contains("terminalOutcome: ChatRemoteJobTerminalOutcome?"))
        XCTAssertFalse(leafViews.contains("narrative.contains("))
        let remoteRowStart = try XCTUnwrap(
            leafViews.range(of: "private func remoteJobInlineRow("))
        let remoteRowEnd = try XCTUnwrap(
            leafViews.range(
                of: "private var remoteJobPayload:",
                range: remoteRowStart.lowerBound..<leafViews.endIndex))
        let remoteRow = String(
            leafViews[remoteRowStart.lowerBound..<remoteRowEnd.lowerBound])
        XCTAssertTrue(remoteRow.contains("ChatRemoteJobInlineLabel.title("))
        XCTAssertTrue(remoteRow.contains("CodexActivityInlineText("))
        XCTAssertFalse(remoteRow.contains("Text(message.text)"))
        XCTAssertFalse(remoteRow.contains("Image(systemName:"))
        let headerStart = try XCTUnwrap(
            leafViews.range(of: "private var shouldShowHeader: Bool"))
        let headerEnd = try XCTUnwrap(
            leafViews.range(
                of: "private var shouldShowStatus: Bool",
                range: headerStart.lowerBound..<leafViews.endIndex))
        let headerProjection = String(
            leafViews[headerStart.lowerBound..<headerEnd.lowerBound])
        XCTAssertTrue(
            headerProjection.contains("if remoteJobPayload != nil { return false }"))

        let transcriptStart = try XCTUnwrap(
            pageModel.range(of: "var transcriptMessages: [ChatMessage]"))
        let transcriptEnd = try XCTUnwrap(
            pageModel.range(
                of: "var selectedThreadPluginIDs:",
                range: transcriptStart.lowerBound..<pageModel.endIndex))
        let transcriptProjection = String(
            pageModel[transcriptStart.lowerBound..<transcriptEnd.lowerBound])
        XCTAssertTrue(
            transcriptProjection.contains("isInertAssistantPlaceholder"))
        XCTAssertFalse(deviceCard.contains("立即借用此設備"))
        XCTAssertFalse(deviceCard.contains("authorizeImmediateBorrow"))
        XCTAssertFalse(deviceCard.contains("等待下一個一般 Chat 回合"))
        XCTAssertFalse(deviceCard.contains("沒有派工"))
        XCTAssertFalse(deviceCard.contains("workPath ="))
        XCTAssertFalse(deviceCard.contains("UUID().uuidString"))
    }
}
