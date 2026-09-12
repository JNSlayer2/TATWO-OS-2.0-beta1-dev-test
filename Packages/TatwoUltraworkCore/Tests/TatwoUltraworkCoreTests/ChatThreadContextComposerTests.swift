import XCTest
@testable import TatwoUltraworkCore

final class TatwoChatThreadContextComposerTests: XCTestCase {
  func testNewEngineSessionReceivesCompleteVisibleThreadHistory() {
    let messages = [
      message(role: "user", text: "先前的使用者問題"),
      message(role: "assistant", text: "先前的 GPT 回覆", modelID: "gpt-5.5"),
      message(role: "assistant", text: "internal thinking", modelID: "gpt-5.5", eventKind: .thinking),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "切到 Claude 後的問題",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .claudeCLI,
      targetHasResumableSession: false)

    XCTAssertTrue(composed.contains("先前的使用者問題"))
    XCTAssertTrue(composed.contains("先前的 GPT 回覆"))
    XCTAssertFalse(composed.contains("internal thinking"))
    XCTAssertTrue(composed.hasSuffix("切到 Claude 後的問題"))
  }

  func testReturningEngineReceivesOnlyTurnsSinceItsLastAssistantMessage() {
    let messages = [
      message(role: "user", text: "GPT 已經看過的問題"),
      message(role: "assistant", text: "GPT 已經看過的回答", modelID: "gpt-5.5"),
      message(role: "user", text: "切到 Claude 的問題"),
      message(role: "assistant", text: "Claude 的回答", modelID: "haiku4.5"),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "切回 GPT 的問題",
      messages: messages,
      targetEngine: .codex,
      targetRuntimeAdapter: .codexExec,
      targetHasResumableSession: true)

    XCTAssertFalse(composed.contains("GPT 已經看過的問題"))
    XCTAssertFalse(composed.contains("GPT 已經看過的回答"))
    XCTAssertTrue(composed.contains("切到 Claude 的問題"))
    XCTAssertTrue(composed.contains("Claude 的回答"))
    XCTAssertTrue(composed.hasSuffix("切回 GPT 的問題"))
  }

  func testStatelessGatewayRouteAlwaysReceivesVisibleTranscript() {
    let messages = [
      message(role: "user", text: "目前 engine 已看過的問題"),
      message(role: "assistant", text: "目前 engine 已看過的回答", modelID: "sonnet4.6"),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "同 engine 下一輪",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: false)

    XCTAssertTrue(composed.contains("目前 engine 已看過的問題"))
    XCTAssertTrue(composed.contains("目前 engine 已看過的回答"))
    XCTAssertTrue(composed.hasSuffix("同 engine 下一輪"))
  }

  func testStatelessGatewayBridgeUsesPlainConversationEnvelopeInsteadOfHiddenInstructionWrapper() {
    let messages = [
      message(
        role: "assistant",
        text: "未執行。仍在 Plan mode。",
        modelID: "sonnet5",
        runtimeAdapter: .claudeCLI),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "同一條 thread，現在請只回：PLAN_OFF_OK_717",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: false)

    XCTAssertTrue(composed.contains("Conversation history from this same Tatwo thread:"))
    XCTAssertTrue(composed.contains("Current user request:"))
    XCTAssertFalse(composed.contains("Hidden TATWO"))
    XCTAssertFalse(composed.contains("do not quote"))
    XCTAssertTrue(composed.hasSuffix("同一條 thread，現在請只回：PLAN_OFF_OK_717"))
  }

  func testContaminatedImportedUserHistoryDoesNotRebridgeTransportContext() {
    let messages = [
      message(
        role: "user",
        text: """
          Conversation history from this same Tatwo thread:
          bridgePolicy=capped-stateless; includedMessages=1; omittedMessages=0; maxCharacters=120000
          [assistant] old answer

          Current user request:
          [Hidden TATWO Chat interface contract]
          private interface
          [/Hidden TATWO Chat interface contract]

          Keep the real imported request.
          """),
      message(
        role: "user",
        text: """
          <codex_delegation>
            <source_thread_id>019fb652-a553-7890-b177-b939073e4f0d</source_thread_id>
            <input>Keep the delegated request.</input>
          </codex_delegation>
          """),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "Continue this session.",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: false)

    XCTAssertTrue(composed.contains("Keep the real imported request."))
    XCTAssertTrue(composed.contains("Keep the delegated request."))
    XCTAssertFalse(composed.contains("[Hidden"))
    XCTAssertFalse(composed.contains("bridgePolicy=capped-stateless; includedMessages=1"))
    XCTAssertFalse(composed.contains("<codex_delegation>"))
    XCTAssertTrue(composed.hasSuffix("Continue this session."))
  }

  func testCodexSessionDoesNotTreatStatelessGatewayTurnAsAlreadySeen() {
    let messages = [
      message(role: "user", text: "Codex session 內的問題"),
      message(role: "assistant", text: "Codex session 內的回答", modelID: "gpt-5.5"),
      message(role: "user", text: "送到 gateway 的問題"),
      message(role: "assistant", text: "gateway 的回答", modelID: "minimax-m3"),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "回 Codex 繼續",
      messages: messages,
      targetEngine: .codex,
      targetRuntimeAdapter: .codexExec,
      targetHasResumableSession: true)

    XCTAssertTrue(composed.contains("送到 gateway 的問題"))
    XCTAssertTrue(composed.contains("gateway 的回答"))
    XCTAssertFalse(composed.contains("Codex session 內的回答"))
  }

  func testNewDiscussionAdapterReceivesForkSnapshotAndChildTranscript() {
    let inherited = [
      message(role: "user", text: "Main-session decision"),
      message(role: "assistant", text: "Main-session answer", modelID: "gpt-5.5"),
    ]
    let child = [
      message(role: "user", text: "Discussion-only exploration"),
      message(role: "assistant", text: "Discussion-only result", modelID: "sonnet4.6"),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "Continue the child session",
      messages: child,
      inheritedMessages: inherited,
      targetEngine: .claude,
      targetRuntimeAdapter: .claudeCLI,
      targetHasResumableSession: false)

    XCTAssertTrue(composed.contains("Main-session decision"))
    XCTAssertTrue(composed.contains("Main-session answer"))
    XCTAssertTrue(composed.contains("Discussion-only exploration"))
    XCTAssertTrue(composed.contains("Discussion-only result"))
    XCTAssertTrue(composed.hasSuffix("Continue the child session"))
  }

  func testResumedDiscussionAdapterOnlyReceivesChildDeltaNotForkSnapshot() {
    let inherited = [
      message(role: "user", text: "Main session must not be rebridged"),
    ]
    let child = [
      message(role: "user", text: "Child request already seen"),
      message(role: "assistant", text: "Child response already seen", modelID: "gpt-5.5"),
      message(role: "user", text: "Child delta after resume"),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "Continue with child delta",
      messages: child,
      inheritedMessages: inherited,
      targetEngine: .codex,
      targetRuntimeAdapter: .codexExec,
      targetHasResumableSession: true)

    XCTAssertFalse(composed.contains("Main session must not be rebridged"))
    XCTAssertFalse(composed.contains("Child request already seen"))
    XCTAssertFalse(composed.contains("Child response already seen"))
    XCTAssertTrue(composed.contains("Child delta after resume"))
    XCTAssertTrue(composed.hasSuffix("Continue with child delta"))
  }

  func testResumedNativeClaudePlanDoesNotReinjectEarlierDoneClaims() {
    let messages = [
      message(role: "user", text: "現在直接執行 touch /tmp/old.txt"),
      message(role: "assistant", text: "DONE", modelID: "haiku4.5"),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "Plan 模式健檢：只回答是否仍在 Plan mode",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .claudeCLI,
      targetHasResumableSession: true)

    XCTAssertEqual(composed, "Plan 模式健檢：只回答是否仍在 Plan mode")
    XCTAssertFalse(composed.contains("DONE"))
    XCTAssertFalse(composed.contains("touch /tmp/old.txt"))
  }

  func testResumedNativeClaudeBridgesOnlyGatewayTurnsAfterLastNativeCheckpoint() {
    let messages = [
      message(
        role: "assistant",
        text: "Native Claude already saw this",
        modelID: "haiku4.5",
        runtimeAdapter: .claudeCLI),
      message(role: "user", text: "Stateless gateway follow-up"),
      message(
        role: "assistant",
        text: "Gateway-only answer",
        modelID: "haiku4.5",
        runtimeAdapter: .gatewayDirect),
    ]

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "Resume native plan",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .claudeCLI,
      targetHasResumableSession: true)

    XCTAssertFalse(composed.contains("Native Claude already saw this"))
    XCTAssertTrue(composed.contains("Stateless gateway follow-up"))
    XCTAssertTrue(composed.contains("Gateway-only answer"))
  }

  func testStatelessBridgeCapsLongHistoryAndKeepsNewestConversation() {
    let messages = (0..<180).flatMap { index in
      [
        message(role: "user", text: "user-\(index)-" + String(repeating: "u", count: 900)),
        message(role: "assistant", text: "assistant-\(index)-" + String(repeating: "a", count: 900), modelID: "sonnet5"),
      ]
    }

    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "current-turn",
      messages: messages,
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: false)

    XCTAssertLessThanOrEqual(
      composed.count,
      TatwoChatThreadContextComposer.maxBridgedCharacters + 1_500)
    XCTAssertFalse(composed.contains("user-0-"))
    XCTAssertTrue(composed.contains("assistant-179-"))
    XCTAssertTrue(composed.contains("omittedMessages="))
    XCTAssertTrue(composed.hasSuffix("current-turn"))
  }

  func testOrdinaryChatComposedPromptOmitsWorkOSLecturePhrases() {
    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "今天天氣怎麼樣？",
      messages: [
        message(role: "user", text: "嗨"),
        message(role: "assistant", text: "你好", modelID: "grok-4"),
      ],
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: false,
      promptSurface: .ordinaryChat)

    XCTAssertTrue(composed.contains("You are a capable assistant in Tatwo Chat."))
    XCTAssertTrue(
      composed.contains(
        "Never proactively mention Work OS, contracts, lanes, or authority"))
    XCTAssertTrue(composed.hasSuffix("今天天氣怎麼樣？"))
    for phrase in TatwoChatThreadContextComposer.ordinaryChatForbiddenLecturePhrases {
      XCTAssertFalse(
        composed.contains(phrase),
        "ordinary chat prompt must not lecture with \(phrase)")
    }
  }

  func testLoopsLaneComposedPromptKeepsAuthorityFrame() {
    let composed = TatwoChatThreadContextComposer.compose(
      currentTurn: "Continue the loop review.",
      messages: [
        message(role: "user", text: "請副審這段"),
      ],
      targetEngine: .claude,
      targetRuntimeAdapter: .gatewayDirect,
      targetHasResumableSession: false,
      promptSurface: .loops)

    XCTAssertTrue(composed.contains("TATWO Work OS authority frame"))
    XCTAssertTrue(composed.contains("blocker_class="))
    XCTAssertTrue(composed.contains("authority_source="))
    XCTAssertTrue(
      composed.contains(TatwoChatThreadContextComposer.workOSAuthorityFrame))
    XCTAssertTrue(composed.hasSuffix("Continue the loop review."))
  }

  func testWorkOSSurfaceKeepsAuthorityFrameWhileOrdinaryFrameDoesNot() {
    let ordinary = TatwoChatThreadContextComposer.systemFrame(for: .ordinaryChat)
    let workOS = TatwoChatThreadContextComposer.systemFrame(for: .workOS)
    let loops = TatwoChatThreadContextComposer.systemFrame(for: .loops)

    for phrase in TatwoChatThreadContextComposer.ordinaryChatForbiddenLecturePhrases {
      XCTAssertFalse(ordinary.contains(phrase), phrase)
    }
    XCTAssertTrue(workOS.contains("TATWO Work OS authority frame"))
    XCTAssertTrue(loops.contains("TATWO Work OS authority frame"))
    XCTAssertEqual(
      TatwoChatThreadContextComposer.systemFrame(for: .workOS)
        .contains("blocker_class="),
      true)
    XCTAssertTrue(loops.contains(TatwoChatThreadContextComposer.workOSAuthorityFrame))
  }

  func testWorkOSAuthoritySeparatesNativeCodingToolsFromComputerHost() {
    let frame = TatwoChatThreadContextComposer.workOSAuthorityFrame

    XCTAssertTrue(
      frame.contains(
        "provider-native filesystem, edit, and shell tools are the normal path"))
    XCTAssertTrue(
      frame.contains(
        "Computer Host means visible macOS GUI input or screen interaction only"))
    XCTAssertTrue(
      frame.contains(
        "Never tell the user to open Computer Host for source edits, builds, tests"))
    XCTAssertTrue(
      frame.contains(
        "report tool_unavailable and recommend a native coding route"))
    XCTAssertTrue(
      TatwoChatThreadContextComposer.systemFrame(for: .workOS).contains(
        "emit at most one short status sentence"))
    XCTAssertTrue(
      TatwoChatThreadContextComposer.systemFrame(for: .workOS).contains(
        "Never describe filtered/focused tests as a full-suite pass"))
    XCTAssertTrue(
      TatwoChatThreadContextComposer.systemFrame(for: .ordinaryChat).contains(
        "The UI owns the changed-file list and line counts"))
  }

  private func message(
    role: String,
    text: String,
    modelID: String? = nil,
    eventKind: TatwoNativeChatEventKind = .message,
    runtimeAdapter: TatwoChatRuntimeAdapter? = nil
  ) -> TatwoNativeChatStoredMessage {
    TatwoNativeChatStoredMessage(
      role: role,
      text: text,
      modelID: modelID,
      eventKind: eventKind,
      runtimeAdapterID: runtimeAdapter?.rawValue)
  }
}
