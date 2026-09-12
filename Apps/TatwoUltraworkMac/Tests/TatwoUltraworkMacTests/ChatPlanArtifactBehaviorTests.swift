import Foundation
import XCTest

@testable import TatwoUltraworkCore
@testable import TatwoUltraworkMac

@MainActor
final class ChatPlanArtifactBehaviorTests: XCTestCase {
  func testPlanCommandShowsOriginalUserInputWithoutCreatingEmptyPlanArtifact()
    async throws
  {
    let fixture = try makeFixture("create")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let goalCountBefore = fileCount(
      in: fixture.root.appendingPathComponent("goals", isDirectory: true))
    let dispatchCountBefore = fileCount(
      in: fixture.root.appendingPathComponent("dispatches", isDirectory: true))

    let visibleInput = "/plan Refactor calculator safely"
    fixture.model.prompt = visibleInput
    fixture.model.handlePlanSlashCommand()

    XCTAssertNil(
      fixture.model.activePlanArtifact,
      "Codex does not create or pin an empty Plan before model output exists")
    XCTAssertTrue(fixture.model.isPlanModeEnabled)
    XCTAssertEqual(
      fixture.model.messages.last(where: { $0.role == .user })?.text,
      visibleInput,
      "Internal Plan instructions must never replace the visible user turn")
    XCTAssertTrue(fixture.model.prompt.isEmpty)
    XCTAssertEqual(
      fileCount(in: fixture.root.appendingPathComponent("goals", isDirectory: true)),
      goalCountBefore)
    XCTAssertEqual(
      fileCount(in: fixture.root.appendingPathComponent("dispatches", isDirectory: true)),
      dispatchCountBefore)
  }

  func testPlanOffKeepsArtifactAndThreadSwitchRestoresIndependentArtifact()
    async throws
  {
    let fixture = try makeFixture("thread-scope", threadCount: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    fixture.model.prompt = "/plan First plan"
    fixture.model.handlePlanSlashCommand()
    fixture.model.updatePlanArtifactFromCompletedResponse(
      "# Plan\n\n## Steps\nFirst",
      threadID: fixture.threadID)
    let firstArtifact = try XCTUnwrap(fixture.model.activePlanArtifact)

    fixture.model.selectedThreadID = fixture.otherThreadID
    fixture.model.prompt = "/plan Second plan"
    fixture.model.handlePlanSlashCommand()
    fixture.model.updatePlanArtifactFromCompletedResponse(
      "# Plan\n\n## Steps\nSecond",
      threadID: try XCTUnwrap(fixture.otherThreadID))
    let secondArtifact = try XCTUnwrap(fixture.model.activePlanArtifact)
    XCTAssertNotEqual(firstArtifact.planID, secondArtifact.planID)

    fixture.model.prompt = "/plan off"
    fixture.model.handlePlanSlashCommand()
    XCTAssertFalse(fixture.model.isPlanModeEnabled)
    XCTAssertEqual(fixture.model.activePlanArtifact, secondArtifact)

    fixture.model.selectedThreadID = fixture.threadID
    XCTAssertEqual(fixture.model.activePlanArtifact, firstArtifact)
  }

  func testConfirmationAndLaterPlanDiscussionReopensArtifact() async throws {
    let fixture = try makeFixture("confirm")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    fixture.model.prompt = "/plan Initial plan"
    fixture.model.handlePlanSlashCommand()
    fixture.model.updatePlanArtifactFromCompletedResponse(
      "# Plan\n\n## Steps\nInitial",
      threadID: fixture.threadID)
    fixture.model.isRunning = false
    fixture.model.confirmActivePlan()
    try await waitForPlanConfirmation(fixture.model)
    XCTAssertEqual(fixture.model.activePlanArtifact?.state, .confirmed)
    let planID = fixture.model.activePlanArtifact?.planID
    let createdAt = fixture.model.activePlanArtifact?.createdAt

    // Isolate artifact revision semantics from the confirmation-triggered
    // Goal dispatch. That dispatch intentionally fails closed in this fixture
    // because it has no authority-lock bootstrap, so a second slash-command
    // cannot produce a real completed Plan turn here.
    fixture.model.pendingPlanObjectives[fixture.threadID] = "Refined plan"
    fixture.model.updatePlanArtifactFromCompletedResponse(
      "# Plan\n\n## Steps\nRefined",
      threadID: fixture.threadID)

    XCTAssertEqual(fixture.model.activePlanArtifact?.state, .discussing)
    XCTAssertEqual(fixture.model.activePlanArtifact?.planID, planID)
    XCTAssertEqual(fixture.model.activePlanArtifact?.createdAt, createdAt)
    let markdown = try XCTUnwrap(fixture.model.planMarkdownForCopy())
    XCTAssertTrue(markdown.contains("## Objective\n\nRefined plan"))
    XCTAssertTrue(markdown.contains("## Steps\n\nRefined"))
  }

  /// 2026-08-21 互動定案：確認後依模式開工——單模型（無 loopsConfig）
  /// 走 /goal 管線；結果必須可見（goal 綁定或失敗原因），不得靜默。
  func testConfirmationRoutesSingleModelToGoalPipelineVisibly() async throws {
    let fixture = try makeFixture("confirm-goal-route")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    fixture.model.prompt = "/plan Auto goal entry"
    fixture.model.handlePlanSlashCommand()
    fixture.model.updatePlanArtifactFromCompletedResponse(
      "# Plan\n\n## Steps\nExecute",
      threadID: fixture.threadID)
    fixture.model.isRunning = false
    XCTAssertFalse(
      fixture.model.collaborationIsEnabled,
      "本夾具必須是單模型情境，才驗 goal 路由")
    fixture.model.confirmActivePlan()
    try await waitForPlanConfirmation(fixture.model)

    XCTAssertEqual(fixture.model.activePlanArtifact?.state, .confirmed)
    let visibleOutcome =
      fixture.model.selectedThread?.workOSGoalID != nil
      || fixture.model.composerHint?.isEmpty == false
      || !fixture.model.selectedWorkOSStateMessage.isEmpty
    XCTAssertTrue(visibleOutcome, "goal 進入結果必須可見，不得靜默")
  }

  func testConfirmationWhileRunningKeepsArtifactDiscussingAndRetryable()
    async throws
  {
    let fixture = try makeFixture("confirm-while-running")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    fixture.model.prompt = "/plan Wait for active turn"
    fixture.model.handlePlanSlashCommand()
    fixture.model.updatePlanArtifactFromCompletedResponse(
      "# Plan\n\n## Steps\nWait",
      threadID: fixture.threadID)
    let planID = try XCTUnwrap(fixture.model.activePlanArtifact?.planID)
    fixture.model.isRunning = true

    fixture.model.confirmActivePlan()

    XCTAssertEqual(fixture.model.activePlanArtifact?.state, .discussing)
    XCTAssertEqual(fixture.model.activePlanArtifact?.planID, planID)
    XCTAssertFalse(fixture.model.planConfirmInFlight)
    XCTAssertTrue(
      fixture.model.composerHint?.contains("請等回合結束") == true)
  }

  func testMissingActivePlanConfirmationShowsVisibleFailureReason() async throws {
    let fixture = try makeFixture("missing-confirm")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    fixture.model.confirmActivePlan()

    XCTAssertEqual(fixture.model.composerHint, "沒有可確認的計劃書。")
  }

  func testBoundRevisedPlanTurnUsesCurrentObjectiveInsteadOfStaleArtifact()
    async throws
  {
    let fixture = try makeFixture("bound-current-objective")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let stale = TatwoPlanArtifactV1(
      threadID: fixture.threadID,
      objective: "修復 Chromium 空白頁",
      sections: [.init(title: "舊計畫", body: "舊內容")],
      sourceAssistantMessageID: "old-plan-assistant")
    XCTAssertTrue(fixture.model.persistPlanArtifact(stale))
    let user = ChatMessage(
      id: "current-plan-user",
      role: .user,
      text: "建立或更新 Work OS Goal Contract 與 Plan，顯示送交 Work OS。",
      eventKind: .message)
    let assistant = ChatMessage(
      id: "current-plan-assistant",
      role: .assistant,
      text: "## Goal\n建立瀏覽器研究 Goal。\n\n## Validation\n只採官方來源。",
      eventKind: .message)
    fixture.model.messages = [user, assistant]
    let binding = ChatPlanTurnBinding(
      threadID: fixture.threadID,
      sourceUserMessageID: user.id,
      assistantMessageID: assistant.id,
      objectiveCandidate: user.text,
      startingPlanID: stale.planID,
      startingObjective: stale.objective,
      startingArtifactUpdatedAt: stale.updatedAt)

    fixture.model.updatePlanArtifactFromCompletedResponse(
      assistant.text,
      threadID: fixture.threadID,
      assistantMessageID: assistant.id,
      planTurnBinding: binding)

    XCTAssertEqual(fixture.model.activePlanArtifact?.objective, user.text)
    XCTAssertEqual(
      fixture.model.activePlanArtifact?.sourceAssistantMessageID,
      assistant.id)
    XCTAssertEqual(
      fixture.model.activePlanArtifact?.sections.map(\.title),
      ["Goal", "Validation"])
  }

  func testBoundPLGSectionsCreateArtifactWhenJournalProjectionLags()
    async throws
  {
    let fixture = try makeFixture("bound-plg-projection-lag")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let user = ChatMessage(
      id: "plg-plan-user",
      role: .user,
      text: "建立 Plan→PLG artifact 並顯示送交 Work OS 入口。",
      eventKind: .message)
    fixture.model.messages = [user]
    let assistantID = "plg-plan-assistant"
    let response = """
      ## Goal Contract
      建立可確認的瀏覽器任務。

      ## Context / Architecture
      綁定目前 thread 與 Work OS contract。

      ## Plan
      1. 確認 artifact。
      2. 送交 Work OS。
      """
    let binding = ChatPlanTurnBinding(
      threadID: fixture.threadID,
      sourceUserMessageID: user.id,
      assistantMessageID: assistantID,
      objectiveCandidate: user.text,
      startingPlanID: nil,
      startingObjective: nil,
      startingArtifactUpdatedAt: nil)

    fixture.model.updatePlanArtifactFromCompletedResponse(
      response,
      threadID: fixture.threadID,
      assistantMessageID: assistantID,
      planTurnBinding: binding)

    let artifact = try XCTUnwrap(fixture.model.activePlanArtifact)
    XCTAssertEqual(artifact.objective, user.text)
    XCTAssertEqual(artifact.sourceAssistantMessageID, assistantID)
    XCTAssertEqual(
      artifact.sections.map(\.title),
      ["Goal Contract", "Context / Architecture", "Plan"])
    XCTAssertNil(fixture.model.pendingPlanObjectives[fixture.threadID])
  }

  func testBoundUnstructuredCompletionStaysRetryableInsteadOfBecomingPlan()
    async throws
  {
    let fixture = try makeFixture("bound-unstructured-retry")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let user = ChatMessage(
      id: "retry-plan-user",
      role: .user,
      text: "建立正式 Plan sections。",
      eventKind: .message)
    let assistant = ChatMessage(
      id: "retry-plan-assistant",
      role: .assistant,
      text: "I looked at it and will explain more later.",
      eventKind: .message)
    fixture.model.messages = [user, assistant]
    let binding = ChatPlanTurnBinding(
      threadID: fixture.threadID,
      sourceUserMessageID: user.id,
      assistantMessageID: assistant.id,
      objectiveCandidate: user.text,
      startingPlanID: nil,
      startingObjective: nil,
      startingArtifactUpdatedAt: nil)

    fixture.model.updatePlanArtifactFromCompletedResponse(
      assistant.text,
      threadID: fixture.threadID,
      assistantMessageID: assistant.id,
      planTurnBinding: binding)

    XCTAssertNil(fixture.model.activePlanArtifact)
    XCTAssertEqual(
      fixture.model.pendingPlanObjectives[fixture.threadID],
      user.text)
    XCTAssertTrue(
      fixture.model.composerHint?.contains(
        "未回傳可解析的完整 Markdown Plan") == true)
  }

  func testBoundPermissionBlockerDoesNotOverwriteLegalExistingPlan()
    async throws
  {
    let fixture = try makeFixture("bound-permission-blocker")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let existing = TatwoPlanArtifactV1(
      threadID: fixture.threadID,
      objective: "保留合法既有計畫",
      sections: [.init(title: "Plan", body: "Do not replace this.")],
      sourceAssistantMessageID: "legal-plan-source")
    XCTAssertTrue(fixture.model.persistPlanArtifact(existing))
    let user = ChatMessage(
      id: "blocked-plan-user",
      role: .user,
      text: "更新 Plan 並顯示送交 Work OS。",
      eventKind: .message)
    let blockerText = """
      目前權限不足，本回合未執行。
      blocker_class=permission_denied authority_source=runner
      """
    let assistant = ChatMessage(
      id: "blocked-plan-assistant",
      role: .assistant,
      text: blockerText,
      status: "blocked",
      eventKind: .message)
    fixture.model.messages = [user, assistant]
    let binding = ChatPlanTurnBinding(
      threadID: fixture.threadID,
      sourceUserMessageID: user.id,
      assistantMessageID: assistant.id,
      objectiveCandidate: user.text,
      startingPlanID: existing.planID,
      startingObjective: existing.objective,
      startingArtifactUpdatedAt: existing.updatedAt)

    fixture.model.updatePlanArtifactFromCompletedResponse(
      blockerText,
      threadID: fixture.threadID,
      assistantMessageID: assistant.id,
      planTurnBinding: binding)

    XCTAssertEqual(fixture.model.activePlanArtifact, existing)
    XCTAssertEqual(
      fixture.model.pendingPlanObjectives[fixture.threadID],
      user.text)
    XCTAssertTrue(
      fixture.model.composerHint?.contains(
        "不會把錯誤文字當成 Plan") == true)
  }

  func testMismatchedAssistantCannotSetPlanArtifactSource() async throws {
    let fixture = try makeFixture("assistant-binding-mismatch")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let existing = TatwoPlanArtifactV1(
      threadID: fixture.threadID,
      objective: "Original objective",
      sections: [.init(title: "Original", body: "Keep.")],
      sourceAssistantMessageID: "original-source")
    XCTAssertTrue(fixture.model.persistPlanArtifact(existing))
    let user = ChatMessage(
      id: "bound-user",
      role: .user,
      text: "Revise the Plan.",
      eventKind: .message)
    let expectedAssistant = ChatMessage(
      id: "bound-assistant",
      role: .assistant,
      text: "## Expected\nBound result.",
      eventKind: .message)
    let staleAssistant = ChatMessage(
      id: "stale-assistant",
      role: .assistant,
      text: "## Stale\nMust not publish.",
      eventKind: .message)
    fixture.model.messages = [user, expectedAssistant, staleAssistant]
    let binding = ChatPlanTurnBinding(
      threadID: fixture.threadID,
      sourceUserMessageID: user.id,
      assistantMessageID: expectedAssistant.id,
      objectiveCandidate: user.text,
      startingPlanID: existing.planID,
      startingObjective: existing.objective,
      startingArtifactUpdatedAt: existing.updatedAt)

    fixture.model.updatePlanArtifactFromCompletedResponse(
      staleAssistant.text,
      threadID: fixture.threadID,
      assistantMessageID: staleAssistant.id,
      planTurnBinding: binding)

    XCTAssertEqual(fixture.model.activePlanArtifact, existing)
    XCTAssertEqual(
      fixture.model.pendingPlanObjectives[fixture.threadID],
      user.text)
    XCTAssertTrue(
      fixture.model.composerHint?.contains(
        "assistant response 與本輪 Plan binding 不一致") == true)
  }

  func testPlanRevisionIntentDistinguishesTransitionFromClarification() {
    XCTAssertEqual(
      ChatPlanRevisionIntent.objectiveCandidate(
        userTurn:
          "現在建立或更新 Work OS Goal Contract 與 Plan，然後顯示送交 Work OS。",
        pendingObjective: nil,
        existingObjective: "舊目標"),
      "現在建立或更新 Work OS Goal Contract 與 Plan，然後顯示送交 Work OS。")
    XCTAssertNil(
      ChatPlanRevisionIntent.objectiveCandidate(
        userTurn: "使用目前專案，驗證 UI 和資料保存。",
        pendingObjective: nil,
        existingObjective: "既有目標"))
    XCTAssertEqual(
      ChatPlanRevisionIntent.objectiveCandidate(
        userTurn: "簡短回答",
        pendingObjective: "明確 /plan 新目標",
        existingObjective: "既有目標"),
      "明確 /plan 新目標")
  }

  private func makeFixture(
    _ suffix: String,
    threadCount: Int = 1,
    extraEnvironment: [String: String] = [:],
    dispatchService: any ChatDispatchService = DefaultChatDispatchService()
  ) throws -> (
    root: URL,
    model: ChatPageModel,
    threadID: UUID,
    otherThreadID: UUID?
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-plan-artifact-\(suffix)-\(UUID().uuidString)",
      isDirectory: true)
    let threadID = UUID()
    let otherThreadID = threadCount > 1 ? UUID() : nil
    var threads = [TatwoNativeChatThread(id: threadID, title: "First")]
    if let otherThreadID {
      threads.append(TatwoNativeChatThread(id: otherThreadID, title: "Second"))
    }
    let store = TatwoNativeChatStore(
      url: root.appendingPathComponent("native-chat.json"),
      fallbackURLs: [],
      mirrorsToUnifiedLedger: false)
    try store.save(TatwoNativeChatStoreDocument(threads: threads))
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    var environment = [
      "XCTestConfigurationFilePath": "ChatPlanArtifactBehaviorTests",
      "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
      "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
    ]
    environment.merge(extraEnvironment) { _, new in new }
    let model = ChatPageModel(
      environment: environment,
      store: store,
      transcriptJournalStore: ChatTranscriptJournalDiskStore(
        fileURL: root.appendingPathComponent("journal.json")),
      goalRunStore: goalStore,
      dispatchService: dispatchService)
    return (root, model, threadID, otherThreadID)
  }

  private func waitForInitialStoreLoad(
    _ model: ChatPageModel
  ) async throws {
    let deadline = Date().addingTimeInterval(5)
    while model.isLoadingStore && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(model.isLoadingStore)
  }

  private func waitForPlanConfirmation(
    _ model: ChatPageModel
  ) async throws {
    let deadline = Date().addingTimeInterval(5)
    while model.planConfirmInFlight && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertFalse(model.planConfirmInFlight)
  }

  private func fileCount(in directory: URL) -> Int {
    (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil))?.count ?? 0
  }

  private func goalRunFileCount(in root: URL) throws -> Int {
    let goals = root.appendingPathComponent("goals", isDirectory: true)
    guard FileManager.default.fileExists(atPath: goals.path) else { return 0 }
    return try FileManager.default.contentsOfDirectory(
      at: goals,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
      .count
  }

  /// Current Codex renders Plan as a transcript summary after model output.
  /// It does not pin a canvas above the composer or expose TATWO execution
  /// controls inside /plan.
  func testPlanCanvasSourceMeetsCodexParityContract() throws {
    let source = try chatPageSource()
    let transcriptSource =
      source.components(separatedBy: "private struct PlanTranscriptMarkdownView")
        .first ?? source
    for marker in [
      "PlanTranscriptSummaryView",
      "\"plan-summary-download\"",
      "\"plan-summary-copy\"",
      "\"plan-summary-side-panel\"",
      "\"Writing plan\"",
      "\"Plan\"",
      "ChatAssistantTranscriptBlockView(",
      "TatwoAssistantTranscriptPresentation.document(",
      "PlanTranscriptInspectorView",
      "@Binding var isSidePanelPresented: Bool",
      ".inspector(isPresented: $planInspectorPresented)",
    ] {
      XCTAssertTrue(source.contains(marker), "Plan transcript summary 缺 \(marker)")
    }
    for forbidden in [
      "planArtifactCanvas",
      "planFlowSelectionCard",
      "\"plan-canvas-confirm\"",
      "\"plan-canvas-edit\"",
      "TextEditor(text: $planCanvasDraft)",
      "@State private var isSidePanelPresented",
      "private var collapsedHeight",
      ".defaultScrollAnchor(.top)",
      "\"plan-summary-toggle\"",
      "\"plan-summary-expand-button\"",
    ] {
      XCTAssertFalse(
        transcriptSource.contains(forbidden),
        "/plan transcript preview 不應包含 \(forbidden)")
    }
  }

  func testTranscriptPlanKeepsAssistantTextAndClarificationsVisibleWithArtifact()
    throws
  {
    let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")
    let start = try XCTUnwrap(
      source.range(of: "    private var messageContainer: some View {")?
        .lowerBound)
    let end = try XCTUnwrap(
      source.range(
        of: "    @ViewBuilder\n    private var roleMarker",
        range: start..<source.endIndex)?.lowerBound)
    let messageContainerSource = String(source[start..<end])

    XCTAssertTrue(
      messageContainerSource.contains(
        """
                    messageBody
                    if let planArtifact, message.role == .assistant {
        """),
      "Codex keeps the assistant summary text visible before the Plan card")
    XCTAssertTrue(
      messageContainerSource.contains(
        "if !message.planQuestions.isEmpty {"),
      "A later clarification request must remain visible even when a Plan artifact exists")
    XCTAssertFalse(
      messageContainerSource.contains(
        "if planArtifact == nil, !message.planQuestions.isEmpty"),
      "An existing Plan artifact must not suppress a newer clarification card")
  }

  func testAnsweringRealPlanQuestionsConsumesPendingCardWhileQueued()
    async throws
  {
    let fixture = try makeFixture("consume-real-questions")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let question = PlanQuestionV1(
      id: "scope",
      question: "Which scope?",
      options: [
        .init(label: "Current project", detail: "Keep it narrow.")
      ])
    let olderQuestion = PlanQuestionV1(
      id: "older-scope",
      question: "Which earlier scope?",
      options: [
        .init(label: "Earlier project", detail: "Keep historical context.")
      ])
    fixture.model.messages = [
      ChatMessage(
        id: "original-plan-user",
        role: .user,
        text: "/plan Keep the current project scope narrow.",
        eventKind: .message),
      ChatMessage(
        id: "older-clarification",
        role: .assistant,
        text: "An older clarification remains historical.",
        planQuestions: [olderQuestion]),
      ChatMessage(
        id: "clarification",
        role: .assistant,
        text: "I need one clarification.",
        planQuestions: [question])
    ]
    // This fixture deliberately disables every real runtime. Marking an
    // existing turn active exercises the accepted queue path without launching
    // a process; the previous version accidentally exercised a rejected start.
    fixture.model.isRunning = true

    fixture.model.answerPlanQuestions([
      PlanQuestionAnswerV1(
        questionID: question.id,
        selectedOptions: [question.options[0]])
    ])

    XCTAssertEqual(fixture.model.queuedChatTurnCount, 1)
    XCTAssertNil(
      fixture.model.planClarificationRoundCountByThread[fixture.threadID],
      "Queue admission alone is not an accepted clarification round")
    XCTAssertTrue(
      fixture.model.messages.first(where: { $0.id == "clarification" })?
        .planQuestions.isEmpty == true,
      "The question card clears only after its continuation turn is accepted")
    XCTAssertEqual(
      fixture.model.messages.first(where: { $0.id == "older-clarification" })?
        .planQuestions.map(\.id),
      [olderQuestion.id],
      "Acceptance must consume only the exact newest source question")
    let queuedContinuation = try XCTUnwrap(fixture.model.chatQueue.first)
    XCTAssertTrue(
      queuedContinuation.visibleTurn.contains(
        "/plan Keep the current project scope narrow."),
      "The internal continuation must remain bound to the original objective")
  }

  func testQueuedPlanQuestionStartFailureRestoresRetryableCard()
    async throws
  {
    let dispatchService = RejectingPlanClarificationDispatchService()
    let fixture = try makeFixture(
      "queued-question-start-failure",
      dispatchService: dispatchService)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let question = PlanQuestionV1(
      id: "scope",
      question: "Which scope?",
      options: [
        .init(label: "Current project", detail: "Keep it narrow.")
      ])
    fixture.model.messages = [
      ChatMessage(
        id: "original-plan-user",
        role: .user,
        text: "/plan Keep the current project scope narrow.",
        eventKind: .message),
      ChatMessage(
        id: "clarification",
        role: .assistant,
        text: "I need one clarification.",
        planQuestions: [question])
    ]
    fixture.model.isRunning = true

    fixture.model.answerPlanQuestions([
      PlanQuestionAnswerV1(
        questionID: question.id,
        selectedOptions: [question.options[0]])
    ])

    XCTAssertEqual(fixture.model.queuedChatTurnCount, 1)
    XCTAssertTrue(
      fixture.model.messages.first(where: { $0.id == "clarification" })?
        .planQuestions.isEmpty == true)
    XCTAssertNil(
      fixture.model.planClarificationRoundCountByThread[fixture.threadID])

    // Dequeue reaches startTurn, and the injected dispatch seam rejects runner
    // identity creation. The exact source card must become retryable again.
    fixture.model.isRunning = false
    fixture.model.resumeQueuedChatTurns()

    XCTAssertEqual(
      dispatchService.startCount,
      1,
      "The test must reach the real dispatch identity rejection boundary")
    XCTAssertEqual(fixture.model.queuedChatTurnCount, 0)
    XCTAssertFalse(fixture.model.isRunning)
    XCTAssertNil(
      fixture.model.planClarificationRoundCountByThread[fixture.threadID],
      "A dequeue-time start failure is not an accepted round")
    let restoredSourceRows = fixture.model.messages.filter {
      $0.id == "clarification"
    }
    XCTAssertEqual(
      restoredSourceRows.count,
      1,
      "The failed continuation must not duplicate its source row")
    XCTAssertEqual(restoredSourceRows.first?.id, "clarification")
    XCTAssertEqual(
      restoredSourceRows.first?.planQuestions.map(\.id),
      [question.id],
      "The failed queued continuation must restore its authoritative question")
    XCTAssertEqual(
      fixture.model.messages.first(where: { $0.eventKind == .failure })?
        .status,
      "failed",
      "Restoring the source card must preserve the new terminal failure row")
    XCTAssertTrue(
      fixture.model.prompt.isEmpty,
      "The internal continuation envelope must not leak into the composer")
    XCTAssertTrue(
      fixture.model.composerHint?.contains("澄清卡已恢復") == true)
  }

  func testRejectedPlanQuestionContinuationPreservesPendingCard()
    async throws
  {
    let dispatchService = RejectingPlanClarificationDispatchService()
    let fixture = try makeFixture(
      "reject-real-questions",
      dispatchService: dispatchService)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let question = PlanQuestionV1(
      id: "scope",
      question: "Which scope?",
      options: [
        .init(label: "Current project", detail: "Keep it narrow.")
      ])
    fixture.model.messages = [
      ChatMessage(
        id: "original-plan-user",
        role: .user,
        text: "/plan Keep the current project scope narrow.",
        eventKind: .message),
      ChatMessage(
        id: "clarification",
        role: .assistant,
        text: "I need one clarification.",
        planQuestions: [question])
    ]

    // With no active turn, the injected dispatch seam rejects runner identity
    // creation. The answer must remain retryable.
    fixture.model.answerPlanQuestions([
      PlanQuestionAnswerV1(
        questionID: question.id,
        selectedOptions: [question.options[0]])
    ])

    XCTAssertEqual(
      dispatchService.startCount,
      1,
      "The test must reach the real dispatch identity rejection boundary")
    XCTAssertEqual(fixture.model.queuedChatTurnCount, 0)
    XCTAssertNil(
      fixture.model.planClarificationRoundCountByThread[fixture.threadID])
    let restoredSourceRows = fixture.model.messages.filter {
      $0.id == "clarification"
    }
    XCTAssertEqual(
      restoredSourceRows.count,
      1,
      "A rejected continuation must not duplicate its source row")
    XCTAssertEqual(restoredSourceRows.first?.id, "clarification")
    XCTAssertEqual(
      restoredSourceRows.first?.planQuestions.map(\.id),
      [question.id],
      "A rejected continuation must not consume its authoritative answer card")
    XCTAssertEqual(
      fixture.model.messages.first(where: { $0.eventKind == .failure })?
        .status,
      "failed",
      "Retry restoration must retain the dispatch failure status")
    XCTAssertTrue(
      fixture.model.prompt.isEmpty,
      "A rejected internal continuation must not leak into the composer")
  }

  func testPlanQuestionDoesNotPublishPartialPlanOrReplaceArtifactSource()
    async throws
  {
    let fixture = try makeFixture("plan-plus-question")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let existing = TatwoPlanArtifactV1(
      threadID: fixture.threadID,
      objective: "Keep the existing import plan",
      sections: [
        .init(title: "Existing", body: "Preserve this legal plan.")
      ],
      sourceAssistantMessageID: "existing-plan-source")
    XCTAssertTrue(fixture.model.persistPlanArtifact(existing))
    fixture.model.messages.append(ChatMessage(
      id: "plan-plus-question",
      role: .assistant,
      text: "I drafted the stable portion and need one decision.",
      planQuestions: [
        PlanQuestionV1(
          id: "scope",
          question: "Which scope?",
          options: [
            .init(label: "Current project", detail: "Keep it narrow.")
          ])
      ]))

    fixture.model.updatePlanArtifactFromCompletedResponse(
      """
      ## Implementation

      Preserve the already-known import path.

      ## Validation

      Exercise the visible flow after the clarification is answered.
      """,
      threadID: fixture.threadID)

    XCTAssertEqual(
      fixture.model.activePlanArtifact,
      existing,
      "A Plan question is not a completed revision and must not replace legal sections or source binding")
    XCTAssertEqual(
      fixture.model.messages.last?.planQuestions.map(\.id),
      ["scope"],
      "Rejecting a partial Plan must not consume the still-pending clarification")
  }

  func testTerminalClarificationPublishesOriginalObjectiveAndConsumesExtraQuestion()
    async throws
  {
    let fixture = try makeFixture("terminal-final-plan")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let originalObjective =
      "/plan 用 Computer Use 體驗 TATWO OS 並搭建安全瀏覽器"
    let internalEnvelope = """
      [TATWO Plan terminal clarification answers]
      questionID=final-runner-prompt-output
      """
    let user = ChatMessage(
      id: "original-plan-user",
      role: .user,
      text: originalObjective,
      eventKind: .message)
    let assistant = ChatMessage(
      id: "terminal-final-assistant",
      role: .assistant,
      text: """
        ## Goal

        在同一個 staging 中完成安全瀏覽器流程。

        ## Validation

        用 Computer Use 驗證 Google 搜尋、session 隔離與 Work OS 送交流程。
        """,
      eventKind: .message,
      planQuestions: [
        PlanQuestionV1(
          id: "should-not-waterfall",
          question: "還要再補一題嗎？",
          options: [
            .init(label: "不用", detail: "直接使用完整定稿。")
          ])
      ])
    fixture.model.messages = [user, assistant]
    let binding = ChatPlanTurnBinding(
      threadID: fixture.threadID,
      sourceUserMessageID: user.id,
      assistantMessageID: assistant.id,
      objectiveCandidate: internalEnvelope,
      startingPlanID: nil,
      startingObjective: nil,
      startingArtifactUpdatedAt: nil)

    fixture.model.updatePlanArtifactFromCompletedResponse(
      assistant.text,
      threadID: fixture.threadID,
      assistantMessageID: assistant.id,
      planTurnBinding: binding,
      isTerminalClarificationCompletion: true)

    let artifact = try XCTUnwrap(fixture.model.activePlanArtifact)
    XCTAssertEqual(artifact.objective, originalObjective)
    XCTAssertFalse(
      artifact.objective.contains("[TATWO Plan"),
      "Internal clarification transport must never become user objective")
    XCTAssertEqual(artifact.sourceAssistantMessageID, assistant.id)
    XCTAssertEqual(artifact.state, .discussing)
    XCTAssertEqual(artifact.sections.map(\.title), ["Goal", "Validation"])
    XCTAssertTrue(
      fixture.model.messages.first(where: { $0.id == assistant.id })?
        .planQuestions.isEmpty == true,
      "A terminal final Plan cannot reopen the clarification waterfall")

    fixture.model.updatePlanArtifactFromCompletedResponse(
      assistant.text,
      threadID: fixture.threadID,
      assistantMessageID: assistant.id,
      planTurnBinding: binding,
      isTerminalClarificationCompletion: true)

    XCTAssertEqual(
      fixture.model.activePlanArtifact,
      artifact,
      "A duplicate terminal callback must be idempotent")
    XCTAssertTrue(
      fixture.model.messages.first(where: { $0.id == assistant.id })?
        .planQuestions.isEmpty == true,
      "A duplicate terminal callback must not resurrect a consumed question")
  }

  func testTerminalClarificationWithoutPlanShowsBlockerAndPublishesNothing()
    async throws
  {
    let fixture = try makeFixture("terminal-empty-plan")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)
    fixture.model.selectedThreadID = fixture.threadID

    let user = ChatMessage(
      id: "terminal-empty-user",
      role: .user,
      text: "/plan 輸出完整瀏覽器計畫",
      eventKind: .message)
    let assistant = ChatMessage(
      id: "terminal-empty-assistant",
      role: .assistant,
      text: "",
      eventKind: .message,
      planQuestions: [
        PlanQuestionV1(
          id: "unexpected-question",
          question: "仍然沒有定稿，要繼續嗎？",
          options: [
            .init(label: "繼續", detail: "")
          ])
      ])
    fixture.model.messages = [user, assistant]
    let binding = ChatPlanTurnBinding(
      threadID: fixture.threadID,
      sourceUserMessageID: user.id,
      assistantMessageID: assistant.id,
      objectiveCandidate:
        "[TATWO Plan terminal clarification answers]",
      startingPlanID: nil,
      startingObjective: nil,
      startingArtifactUpdatedAt: nil)

    fixture.model.updatePlanArtifactFromCompletedResponse(
      assistant.text,
      threadID: fixture.threadID,
      assistantMessageID: assistant.id,
      planTurnBinding: binding,
      isTerminalClarificationCompletion: true)

    XCTAssertNil(fixture.model.activePlanArtifact)
    XCTAssertEqual(
      fixture.model.pendingPlanObjectives[fixture.threadID],
      user.text,
      "Terminal clarification failure must preserve the original objective for retry")
    XCTAssertTrue(
      fixture.model.composerHint?.contains(
        "未回傳可解析的完整 Markdown Plan") == true)
    XCTAssertTrue(
      fixture.model.composerHint?.contains(
        "沒有建立 Goal、dispatch 或 runner，原目標已保留，可重試") == true)
    XCTAssertFalse(fixture.model.isRunning)
    XCTAssertNil(fixture.model.selectedWorkOSContract)
    XCTAssertEqual(
      fileCount(
        in: fixture.root.appendingPathComponent(
          "dispatches",
          isDirectory: true)),
      0)
  }

  func testPlanSummaryHeaderMatchesCurrentCodexLabelsAndFortyPointHeight()
    throws
  {
    let source = try chatPageSource()
    for marker in [
      ".frame(height: 40)",
      ".help(\"Download plan\")",
      ".accessibilityLabel(\"Download plan\")",
      "\"Open plan in side panel\"",
      "\"Close plan side panel\"",
      ".font(.system(size: 14, weight: .regular))",
      ".font(.system(size: 14))",
    ] {
      XCTAssertTrue(source.contains(marker), "Plan header 缺 Codex marker \(marker)")
    }
    for forbidden in [
      ".frame(height: 38)",
      "\"Download as PLAN.md\"",
      "\"Open in side panel\"",
      "\"Close side panel\"",
      ".help(isExpanded ? \"Collapse plan\" : \"Expand plan\")",
      ".help(isExpanded ? \"Collapse\" : \"Expand\")",
    ] {
      XCTAssertFalse(source.contains(forbidden), "Plan header 不應保留 \(forbidden)")
    }
  }

  func testTranscriptPlanUsesCodexPreviewMaskAndSidePanelInsteadOfLocalExpand()
    throws
  {
    let source = try chatPageSource()
    let transcriptSource =
      source.components(separatedBy: "private struct PlanTranscriptMarkdownView")
        .first ?? source
    for marker in [
      "private static let collapsedContentHeight: CGFloat = 160",
      "private static let collapsedCardHeight: CGFloat = 200",
      "height: Self.collapsedContentHeight",
      "LinearGradient(",
      "openPlanSidePanel()",
      "if !isSidePanelPresented",
    ] {
      XCTAssertTrue(source.contains(marker), "Plan collapsed card 缺 \(marker)")
    }
    for forbidden in [
      "if constrained {\n            ScrollView",
      "@State private var isExpanded",
      "Button(\"Expand plan\")",
      "\"plan-summary-expand-button\"",
      "\"plan-summary-toggle\"",
    ] {
      XCTAssertFalse(
        transcriptSource.contains(forbidden),
        "Current Codex transcript preview does not use local expansion: \(forbidden)")
    }
  }

  func testTranscriptPlanFadeMatchesCodexLastFourRemMaskWithoutExtraTint()
    throws
  {
    let source = try chatPageSource()
    let transcriptSource =
      source.components(separatedBy: "private struct PlanTranscriptMarkdownView")
        .first ?? source

    XCTAssertTrue(
      transcriptSource.contains(
        ".init(color: .black, location: 0.6)"),
      "Codex keeps the first 96pt of the 160pt preview opaque, then fades only the final 4rem / 64pt")
    XCTAssertFalse(
      transcriptSource.contains(
        "Color(nsColor: .windowBackgroundColor).opacity(0.94)"),
      "Codex thread preview uses a mask-image only; an extra background tint changes the shipped fade")
  }

  func testPlanMarkdownUsesCodexSixteenByTwelveContentPadding() throws {
    let source = try chatPageSource()
    let start = try XCTUnwrap(
      source.range(of: "private struct PlanTranscriptMarkdownView")?
        .lowerBound)
    let end = try XCTUnwrap(
      source.range(
        of: "struct PlanTranscriptInspectorView",
        range: start..<source.endIndex)?.lowerBound)
    let markdownSource = String(source[start..<end])

    XCTAssertTrue(markdownSource.contains(".padding(.horizontal, 16)"))
    XCTAssertTrue(markdownSource.contains(".padding(.vertical, 12)"))
    XCTAssertFalse(
      markdownSource.contains(".padding(12)"),
      "Codex markdown wrapper is px-4 py-3, not 12pt on every edge")
  }

  func testPlanHeaderActionsUseCodexFourPointGapAndElectronIconTargets()
    throws
  {
    let source = try chatPageSource()
    let actionStart = try XCTUnwrap(
      source.range(of: "    private var planHeaderActions: some View {")?
        .lowerBound)
    let actionEnd = try XCTUnwrap(
      source.range(
        of: "    private func planBody(",
        range: actionStart..<source.endIndex)?.lowerBound)
    let actionSource = String(source[actionStart..<actionEnd])

    XCTAssertTrue(actionSource.contains("HStack(spacing: 4)"))
    XCTAssertEqual(
      actionSource.components(separatedBy: ".planSummaryActionStyle()").count
        - 1,
      3,
      "Codex Electron icon buttons use an 18pt glyph plus 4pt padding, yielding a 26pt target")

    let inspectorStart = try XCTUnwrap(
      source.range(of: "    private var inspectorHeader: some View {")?
        .lowerBound)
    let inspectorEnd = try XCTUnwrap(
      source.range(
        of: "    private func inspectorBody(",
        range: inspectorStart..<source.endIndex)?.lowerBound)
    let inspectorSource = String(source[inspectorStart..<inspectorEnd])
    XCTAssertTrue(inspectorSource.contains("HStack(spacing: 4)"))
    XCTAssertEqual(
      inspectorSource.components(separatedBy: ".planSummaryActionStyle()").count
        - 1,
      4,
      "Plan inspector 的下載、複製、編輯、收合按鈕必須使用同尺寸 target")
  }

  func testTatwoPlanInspectorAddsGoalPLGAndUltraworkExecutionChoices()
    throws
  {
    let source = try chatPageSource()
    for marker in [
      "private struct PlanExecutionHandoffView",
      "Text(\"接續執行\")",
      "title: \"/goal\"",
      "title: \"/plg\"",
      "title: \"單模型\"",
      "title: \"Ultrawork\"",
      "\"plan-execution-goal\"",
      "\"plan-execution-plg\"",
      "\"plan-execution-single-model\"",
      "\"plan-execution-ultrawork\"",
      "\"plan-execution-run\"",
      "\"plan-execution-selection\"",
      "\"plan-execution-run-guard\"",
      "executionBlocker",
      "onOpenUltrawork",
      "onExecute",
    ] {
      XCTAssertTrue(
        source.contains(marker),
        "完成 Plan 後必須能看見 TATWO OS 接續選項：\(marker)")
    }
    XCTAssertTrue(
      source.contains("PlanExecutionHandoffView("),
      "TATWO 執行選項必須接在右側 Plan inspector 內")
    XCTAssertFalse(
      source.contains("先選擇 TATWO OS 接續方式；本輪只完成 UI，不會直接派工。"),
      "工程備註不可顯示在正式 UI")
  }

  func testPlanUltraworkReplacesOnlyExecutionHandoffCardInsteadOfInspectorCanvas()
    throws
  {
    let source = try chatPageSource()
    let inspectorStart = try XCTUnwrap(
      source.range(of: "struct PlanTranscriptInspectorView")?
        .lowerBound)
    let inspectorEnd = try XCTUnwrap(
      source.range(
        of: "\nprivate struct PlanExecutionHandoffView",
        range: inspectorStart..<source.endIndex)?.lowerBound)
    let inspectorSource = String(source[inspectorStart..<inspectorEnd])

    for marker in [
      "@State private var showsUltraworkCanvas = false",
      "let ultraworkPanel: AnyView",
      "if showsUltraworkCanvas",
      "Button(\"返回接續選項\")",
      "showsUltraworkCanvas = true",
      "ultraworkPanel",
    ] {
      XCTAssertTrue(
        inspectorSource.contains(marker),
        "Ultrawork 必須在接續執行卡片原地切換：\(marker)")
    }
    let bodyPosition = try XCTUnwrap(
      inspectorSource.range(
        of: "inspectorBody(markdown: artifact.markdownExport())")?
        .lowerBound)
    let switchPosition = try XCTUnwrap(
      inspectorSource.range(
        of: "if showsUltraworkCanvas",
        range: bodyPosition..<inspectorSource.endIndex)?.lowerBound)
    let handoffPosition = try XCTUnwrap(
      inspectorSource.range(
        of: "PlanExecutionHandoffView(",
        range: switchPosition..<inspectorSource.endIndex)?.lowerBound)
    XCTAssertLessThan(
      bodyPosition,
      switchPosition,
      "Plan 內容必須保留在上方，不能被 Ultrawork 滿版取代")
    XCTAssertLessThan(
      switchPosition,
      handoffPosition,
      "只允許在原接續執行卡片位置切換 Ultrawork／接續選項")
    XCTAssertFalse(
      inspectorSource.contains(
        """
            if showsUltraworkCanvas {
                VStack(alignment: .leading, spacing: 0) {
        """),
      "不可把整個 Plan inspector 換成新的 Ultrawork 滿版")

    let inspectorCallStart = try XCTUnwrap(
      source.range(of: "            PlanTranscriptInspectorView(")?
        .lowerBound)
    let inspectorCallEnd = try XCTUnwrap(
      source.range(
        of: "\n        .onAppear",
        range: inspectorCallStart..<source.endIndex)?.lowerBound)
    let inspectorCallSource = String(
      source[inspectorCallStart..<inspectorCallEnd])
    XCTAssertTrue(
      inspectorCallSource.contains(
        "ultraworkPanel: AnyView(planUltraworkCanvasPanel)"),
      "Plan inspector 必須收到內嵌 Ultrawork 面板")
    XCTAssertFalse(
      inspectorCallSource.contains("showUltraworkPanel = true"),
      "Plan 的 Ultrawork 選項不可再打開 Chat composer 全域浮動面板")
  }

  func testPlanInspectorSupportsPencilCheckmarkInlineEditing() throws {
    let source = try chatPageSource()
    let inspectorStart = try XCTUnwrap(
      source.range(of: "struct PlanTranscriptInspectorView")?
        .lowerBound)
    let inspectorEnd = try XCTUnwrap(
      source.range(
        of: "\nprivate struct PlanExecutionHandoffView",
        range: inspectorStart..<source.endIndex)?.lowerBound)
    let inspectorSource = String(source[inspectorStart..<inspectorEnd])

    for marker in [
      "@State private var isEditing = false",
      "@State private var editedText = \"\"",
      "Image(systemName: isEditing ? \"checkmark\" : \"pencil\")",
      "TextEditor(text: $editedText)",
      "onSaveEditedText(editedText)",
      "\"Edit plan\"",
      "\"Finish editing plan\"",
    ] {
      XCTAssertTrue(
        inspectorSource.contains(marker),
        "Plan inspector 缺少人工編輯互動：\(marker)")
    }
  }

  func testUltraworkRoleSlotsFollowSMLXLXXLCountsAndReuseRouteCatalog()
    throws
  {
    XCTAssertEqual(UltraworkRoleConfiguration.auxiliaryCount(for: .s), 0)
    XCTAssertEqual(UltraworkRoleConfiguration.auxiliaryCount(for: .m), 1)
    XCTAssertEqual(UltraworkRoleConfiguration.auxiliaryCount(for: .l), 2)
    XCTAssertEqual(UltraworkRoleConfiguration.auxiliaryCount(for: .xl), 3)
    XCTAssertEqual(UltraworkRoleConfiguration.auxiliaryCount(for: .xxl), 4)

    let source = try chatPageSource()
    XCTAssertTrue(source.contains("loopsTeamRow(level: visualLevel)"))
    XCTAssertFalse(
      source.contains("collaborationRoleSlotControls"),
      "獨立主／輔選模列必須移除，模型改由團隊 chip 直接選")
    XCTAssertTrue(source.contains("collaborationRoleModelPickerPanel"))
    XCTAssertTrue(
      source.contains("ChatRouteChoice.brandSections("),
      "Ultrawork 角色選模必須沿用單模型 picker 的品牌目錄")
    XCTAssertTrue(
      source.contains("ultraworkRolePickerTarget = slot"),
      "點團隊 chip 必須在 Plan 畫布原地展開角色模型目錄")
    XCTAssertTrue(source.contains("\"ultrawork-role-primary\""))
    XCTAssertFalse(
      source.contains("collaborationModelPairControls"),
      "舊的固定主／輔兩格 UI 必須退役")
  }

  func testPlanUltraworkPanelRemovesScenarioMenuAndUsesReadableAdaptiveRoleLayout()
    throws
  {
    let source = try chatPageSource()
    let sliderStart = try XCTUnwrap(
      source.range(
        of: "    func collaborationStrengthSlider(")?
        .lowerBound)
    let sliderEnd = try XCTUnwrap(
      source.range(
        of: "    func collaborationSliderTrack(",
        range: sliderStart..<source.endIndex)?.lowerBound)
    let sliderSource = String(source[sliderStart..<sliderEnd])

    XCTAssertFalse(
      sliderSource.contains("collaborationScenarioMiniMenu"),
      "Plan 內嵌 Ultrawork 面板不可再顯示「通用 · 模型主導」情境列")
    XCTAssertTrue(
      sliderSource.contains("loopsTeamRow(level: visualLevel)"),
      "Ultrawork 展開後必須直接以團隊 chip 顯示並選擇模型")
    XCTAssertFalse(
      sliderSource.contains("collaborationRoleSlotControls"),
      "滑桿下方不可再有第二排獨立模型選項")

    let teamStart = try XCTUnwrap(
      source.range(of: "    func loopsTeamRow(")?
        .lowerBound)
    let teamEnd = try XCTUnwrap(
      source.range(
        of: "    /// 團隊 chip 用短名",
        range: teamStart..<source.endIndex)?.lowerBound)
    let teamSource = String(source[teamStart..<teamEnd])
    XCTAssertTrue(
      teamSource.contains("VStack(alignment: .leading, spacing: 6)"),
      "角色列應採垂直滿寬排列，避免窄 Plan inspector 內的 adaptive grid 壓縮文字")
    XCTAssertFalse(
      teamSource.contains("LazyVGrid"),
      "角色選擇已改為可讀的滿寬列，不應退回容易截斷模型名稱的緊縮網格")
    XCTAssertTrue(teamSource.contains("UltraworkRoleConfiguration.auxiliaryCount"))
    XCTAssertTrue(teamSource.contains("Button {"))
    XCTAssertTrue(teamSource.contains("ultraworkRolePickerTarget = slot"))
    XCTAssertTrue(teamSource.contains(".font(.system(size: 10"))
    XCTAssertTrue(teamSource.contains(".frame(minHeight: 38)"))
    XCTAssertTrue(teamSource.contains(".frame(maxWidth: .infinity)"))
    XCTAssertFalse(
      teamSource.contains("Text(mode.rawValue)"),
      "滑桿已標模式，團隊區不可再重複顯示圓形模式 logo")
  }

  func testUltraworkSliderCommitsTeamLevelImmediatelyBeforeVisualSettle()
    throws
  {
    let source = try chatPageSource()
    let trackStart = try XCTUnwrap(
      source.range(of: "    func collaborationSliderTrack(")?
        .lowerBound)
    let trackEnd = try XCTUnwrap(
      source.range(
        of: "    func collaborationSliderPointerDebugLog(",
        range: trackStart..<source.endIndex)?.lowerBound)
    let trackSource = String(source[trackStart..<trackEnd])
    let releaseStart = try XCTUnwrap(
      trackSource.range(of: "withTransaction(releaseTransaction) {")?
        .lowerBound)
    let firstDelay = try XCTUnwrap(
      trackSource.range(
        of: "DispatchQueue.main.asyncAfter",
        range: releaseStart..<trackSource.endIndex)?.lowerBound)
    let immediateRelease = String(trackSource[releaseStart..<firstDelay])
    XCTAssertTrue(
      immediateRelease.contains("model.setCollaborationLevel(next)"),
      "放開滑桿時下方團隊選項必須立即切級別，不可等 settle 動畫")

    let delayedSource = String(trackSource[firstDelay..<trackSource.endIndex])
    XCTAssertFalse(
      delayedSource.contains("model.setCollaborationLevel(next)"),
      "延遲區塊只准收尾視覺狀態，不可延後首次 model commit")
  }

  /// 2026-08-27 缺陷 B：/plg + Ultrawork S 的角色設定畫面顯示「主導 terra」，
  /// 回到接續執行卡片卻報「Ultrawork 尚未指定主導模型」且 Execute 反灰。
  /// 根因是接續執行卡片自己組 selection 時從來不填 primary/secondary。
  func testPlanExecutionHandoffCarriesConfiguredUltraworkLeaderIntoSelection()
    throws
  {
    let source = try chatPageSource()
    let handoffStart = try XCTUnwrap(
      source.range(of: "private struct PlanExecutionHandoffView")?.lowerBound)
    let handoffEnd = try XCTUnwrap(
      source.range(
        of: "enum ChatSidebarLayoutPolicy",
        range: handoffStart..<source.endIndex)?.lowerBound)
    let handoffSource = String(source[handoffStart..<handoffEnd])

    for marker in [
      "let ultraworkPrimaryModelID: String",
      "let ultraworkSecondaryModelID: String?",
      "let ultraworkAuxiliaryCount: Int",
      "primaryModelID: isUltrawork ? ultraworkPrimaryModelID : nil",
      "auxiliaryModelCount: isUltrawork ? ultraworkAuxiliaryCount : nil",
    ] {
      XCTAssertTrue(
        handoffSource.contains(marker),
        "接續執行卡片必須把已設定的 Ultrawork 主導帶進 plan flow selection：\(marker)")
    }

    let inspectorCallStart = try XCTUnwrap(
      source.range(of: "            PlanTranscriptInspectorView(")?
        .lowerBound)
    let inspectorCallEnd = try XCTUnwrap(
      source.range(
        of: "\n        .onAppear",
        range: inspectorCallStart..<source.endIndex)?.lowerBound)
    let inspectorCallSource = String(source[inspectorCallStart..<inspectorCallEnd])
    XCTAssertTrue(
      inspectorCallSource.contains(
        "ultraworkPrimaryModelID:\n                    collaborationRoleModelID(for: .primary)"),
      "Plan inspector 必須拿到和角色 chip 同一份主導模型")
    XCTAssertTrue(
      inspectorCallSource.contains(
        "ultraworkAuxiliaryCount: planUltraworkAuxiliaryCount"),
      "S 沒有副審欄位時，執行閘門不可再要求副審模型")
  }

  /// 顯示中的主導／副審必須跟著這一列 thread 的協作設定走，app-wide 記憶
  /// 只能當預設，否則另一個 session 的選擇會顯示到這裡。
  func testUltraworkRoleChipPrefersPerSessionLoopsConfigOverAppWideMemory()
    throws
  {
    let source = try chatPageSource()
    let helper = try XCTUnwrap(
      source.slice(
        from: "    func collaborationRoleModelID(",
        through: "    static func normalizedRoleModelID("))
    XCTAssertTrue(
      helper.contains("model.activeLoopsConfig?.primaryModelID"),
      "主導 chip 必須先讀這一列 thread 的 loopsConfig")
    XCTAssertTrue(
      helper.contains("model.activeLoopsConfig?.secondaryModelID"),
      "副審 chip 必須先讀這一列 thread 的 loopsConfig")
    XCTAssertTrue(
      helper.contains("ultraworkRoleConfiguration.primaryModelID"),
      "app-wide 記憶仍保留為未設定時的預設")

    let picker = try XCTUnwrap(
      source.slice(
        from: "    func selectCollaborationRoleModel(",
        through: "    func applyStoredUltraworkRoleConfigurationToModel("))
    XCTAssertTrue(
      picker.contains("syncPlanFlowSelectionUltraworkRoles()"),
      "選完角色模型必須立刻寫回這一列的計劃書選擇")
  }

  func testUltraworkRoleConfigurationPersistsAppWide() throws {
    let suiteName = "tatwo.plan.ultrawork-role.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UltraworkRoleConfigurationStore(defaults: defaults)
    let expected = UltraworkRoleConfiguration(
      primaryModelID: "gpt-5.5",
      auxiliaryModelIDs: [
        "sonnet-5", "grok-build", "haiku-4-5", "fable-5",
      ])

    store.save(expected)

    XCTAssertEqual(store.load(), expected)
  }

  func testPlanHeaderActionsUseUniformCompactTargetsAndBalancedSaveGlyph()
    throws
  {
    let source = try chatPageSource()
    let styleStart = try XCTUnwrap(
      source.range(of: "    func planSummaryActionStyle() -> some View {")?
        .lowerBound)
    let styleEnd = try XCTUnwrap(
      source.range(
        of: "\n    }\n}",
        range: styleStart..<source.endIndex)?.upperBound)
    let styleSource = String(source[styleStart..<styleEnd])

    XCTAssertTrue(
      styleSource.contains("font(.system(size: 14, weight: .medium))"))
    XCTAssertTrue(styleSource.contains(".frame(width: 28, height: 28)"))
    XCTAssertTrue(
      source.contains("Image(systemName: \"tray.and.arrow.down\")"),
      "儲存／下載需改成視覺重量較平衡的 tray 圖示")
    XCTAssertFalse(source.contains("Image(systemName: \"arrow.down.doc\")"))
  }

  func testChatSidebarUsesAdaptiveWidthAndFullWidthModeSwitcher()
    throws
  {
    let source = try chatPageSource()
    XCTAssertTrue(
      source.contains("ChatSidebarLayoutPolicy.width(for: layoutWidth)"))
    XCTAssertTrue(
      source.contains("enum ChatSidebarLayoutPolicy"))
    XCTAssertTrue(
      source.contains("min(max(layoutWidth * 0.29, 272), 300)"))

    let sidebarStart = try XCTUnwrap(
      source.range(of: "    var chatSidebar: some View {")?
        .lowerBound)
    let sidebarEnd = try XCTUnwrap(
      source.range(
        of: "\n    var userRowTrailingControls",
        range: sidebarStart..<source.endIndex)?.lowerBound)
    let sidebarSource = String(source[sidebarStart..<sidebarEnd])
    XCTAssertFalse(
      sidebarSource.contains(
        """
                workspaceModeSection
                    .padding(.horizontal, 12)
        """),
      "分頁列不可再被面板 18pt padding 外再縮 12pt")
    XCTAssertFalse(
      sidebarSource.contains(
        """
                .chatGlassChip()
                .padding(.horizontal, 12)
        """),
      "搜尋列需與加寬後分頁列使用同一內容寬度")
  }

  func testPlanInspectorMatchesCodexGenericExpandableSummaryContract() throws {
    let source = try chatPageSource()
    for marker in [
      "struct PlanTranscriptInspectorView",
      "private static let collapsedHeight: CGFloat = 320",
      "@State private var isCollapsed = false",
      "\"Expand plan summary\"",
      "\"Collapse plan summary\"",
      ".help(isCollapsed ? \"Expand\" : \"Collapse\")",
      "Button(\"Expand plan\")",
    ] {
      XCTAssertTrue(
        source.contains(marker),
      "Plan side panel generic summary 缺 Codex marker \(marker)")
    }
  }

  func testPlanMarkdownTracksNarrowInspectorWidthInsteadOfClippingText() throws {
    let chatPage = try chatPageSource()
    let leafSource = try ChatSourceFamily.read("ChatPageLeafViews.swift")

    XCTAssertTrue(
      chatPage.contains("tracksAvailableWidth: true"),
      "Plan markdown 必須要求 TextKit 隨 transcript／inspector 實際欄寬換行")
    XCTAssertTrue(
      leafSource.contains(
        "textView.textContainer?.widthTracksTextView = tracksAvailableWidth"),
      "Plan inspector 不能以 chat fallback 寬度排版後再被窄欄裁切")

    let inspectorStart = try XCTUnwrap(
      chatPage.range(of: "struct PlanTranscriptInspectorView")?
        .lowerBound)
    let inspectorEnd = try XCTUnwrap(
      chatPage.range(
        // PlanTranscriptInspectorView lives in ChatPage+Plan.swift since the
        // 2026-09-02 split; the next top-level declaration there bounds it.
        of: "\nprivate struct PlanExecutionHandoffView",
        range: inspectorStart..<chatPage.endIndex)?.lowerBound)
    let inspectorSource = String(chatPage[inspectorStart..<inspectorEnd])
    XCTAssertTrue(
      inspectorSource.contains("GeometryReader { viewport in"),
      "垂直 ScrollView 的內容寬度必須綁定 inspector viewport；否則 nil proposal 會回退到 chat 欄寬")
    XCTAssertTrue(
      inspectorSource.contains("width: viewport.size.width")
        && inspectorSource.contains("alignment: .leading"),
      "Plan 卡必須以 inspector 實際 viewport 寬度量測，不能保留 640pt ideal width 後被裁切")
  }

  func testWritingPlanUsesPlanIconAndAnimatedTitleInsteadOfProgressSpinner()
    throws
  {
    let source = try chatPageSource()
    XCTAssertTrue(source.contains("PlanWritingAnimatedText"))
    XCTAssertTrue(source.contains("Image(systemName: \"list.bullet.rectangle\")"))
    XCTAssertFalse(
      source.contains("if isWriting {\n                    ProgressView()"),
      "Writing plan 應保留 Plan icon，不使用 ProgressView spinner")
  }

  func testPlanDownloadPolicyDefaultsToDownloadsAndAvoidsOverwriting()
    throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-plan-download-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("PLAN.md"))
    try Data().write(to: root.appendingPathComponent("PLAN 2.md"))

    XCTAssertFalse(
      PlanDownloadPolicy.shouldPromptForLocation(defaults: UserDefaults()))
    XCTAssertEqual(
      PlanDownloadPolicy.availableDestination(in: root).lastPathComponent,
      "PLAN 3.md")
  }

  func testPlanDownloadPolicyCanOptIntoSavePanel() throws {
    let suite = "tatwo-plan-download-policy-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(
      true,
      forKey: PlanDownloadPolicy.promptForLocationDefaultsKey)

    XCTAssertTrue(
      PlanDownloadPolicy.shouldPromptForLocation(defaults: defaults))
  }

  func testPlanClarificationCardSourceMatchesCodexInteractionContract() throws {
    let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")
    for marker in [
      "PlanClarificationRequestCard",
      "Image(systemName: \"pencil\")",
      "\"Skip\"",
      "\"Next\"",
      "secondaryActionLabel(for: question)",
      ".frame(minHeight: 32)",
      "question.allowsMultipleSelections",
      "Image(systemName: \"checkmark\")",
      "Circle()",
      "onMoveCommand",
      "onExitCommand",
      "planKeyboardShortcutButtons(for: question)",
      "@FocusState private var isCardFocused: Bool",
      ".disabled(planShortcutsDisabled)",
      "PlanClarificationInteractionPolicy.allowsCardShortcuts(",
      "allowsMultipleSelections",
      "questionIndex",
      "drafts",
      "180_000_000",
      "initializeSelections",
      "question.allowsOtherResponse",
      "defaultOtherPlaceholder",
      "optionPointSize",
      "PlanClarificationCodexPresentation.composerMarkerSize",
      "roundMarkerSurface(isActive:",
      ".glassEffect(.regular, in: Circle())",
      "LiquidGlassTokens.ultraworkGradient",
      "option.codexDisplayLabel",
      "option.isCodexRecommended",
      ".chatLiquidSection(",
      "LiquidGlassTokens.ultraworkGradient",
      "chat-plan-question-previous",
      "chat-plan-question-next",
      "!question.allowsMultipleSelections",
      "if !message.planQuestions.isEmpty { return false }",
    ] {
      XCTAssertTrue(source.contains(marker), "clarification card 缺 \(marker)")
    }
    for forbidden in [
      "Text(\"Other\")",
      "Button(isFinalQuestion ? \"Submit\" : \"Continue\")",
      "LiquidGlassTokens.brandAccent.opacity(isSelected ? 0.10 : 0.035)",
      "placeholder: \"Type your answer\"",
    ] {
      XCTAssertFalse(
        source.contains(forbidden),
        "clarification card 不應保留非 Codex immediate-response 樣式 \(forbidden)")
    }
    // Browser approval buttons elsewhere in the family are not Plan options.
    let planCardSource = try ChatSourceFamily.read("ChatPageLeafViews+PlanCards.swift")
    XCTAssertFalse(planCardSource.contains(".buttonStyle(.borderedProminent)"))
  }

  func testPlanClarificationCardClaimsInitialKeyboardFocusLikeCodex()
  {
    XCTAssertTrue(
      PlanClarificationInteractionPolicy.shouldClaimInitialFocus(
        isLatestAssistantMessage: true,
        alreadyClaimed: false),
      "The newest Codex immediate-response card claims keyboard focus once")
    XCTAssertFalse(
      PlanClarificationInteractionPolicy.shouldClaimInitialFocus(
        isLatestAssistantMessage: true,
        alreadyClaimed: true),
      "LazyVStack re-realization must not steal focus back from the composer")
    XCTAssertFalse(
      PlanClarificationInteractionPolicy.shouldClaimInitialFocus(
        isLatestAssistantMessage: false,
        alreadyClaimed: false),
      "Historical clarification cards must never claim current keyboard focus")
  }

  func testPlanClarificationInitialFocusClaimPersistsAboveLazyRow() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let pageSource = try ChatSourceFamily.read("ChatPage.swift")
    let leafSource = try ChatSourceFamily.read("ChatPageLeafViews.swift")

    for marker in [
      "initialFocusClaimedPlanQuestionMessageIDs",
      "isLatestAssistantMessage:",
      "initialPlanQuestionFocusClaimed:",
      "onInitialPlanQuestionFocusClaimed:",
      ".insert(message.id)",
    ] {
      XCTAssertTrue(
        pageSource.contains(marker),
        "The one-shot focus claim must persist above LazyVStack rows: \(marker)")
    }
    for marker in [
      "claimInitialCardFocusIfNeeded()",
      "alreadyClaimed: initialFocusAlreadyClaimed",
      "onInitialFocusClaimed()",
      "isCardFocused = true",
    ] {
      XCTAssertTrue(
        leafSource.contains(marker),
        "The card must apply the persisted latest-message focus policy: \(marker)")
    }
  }

  func testPlanClarificationVerticalArrowSelectsCodexOptionOrFocusesOther() {
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.initialFocusedOptionIndex(
        allowsMultipleSelections: false,
        optionCount: 3),
      0,
      "Codex single-select questions begin on their default first option")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.initialFocusedOptionIndex(
        allowsMultipleSelections: true,
        optionCount: 3),
      -1,
      "Codex empty multi-select questions begin with no selected option")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.verticalMove(
        from: -1,
        direction: .up,
        optionCount: 3),
      .selectOption(index: 2),
      "Codex ArrowUp from an empty multi-select question wraps to the final option")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.verticalMove(
        from: -1,
        direction: .down,
        optionCount: 3),
      .selectOption(index: 0),
      "Codex ArrowDown from an empty multi-select question selects the first option")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.verticalMove(
        from: 0,
        direction: .down,
        optionCount: 3),
      .selectOption(index: 1),
      "Codex ArrowDown selects the next option; it does not only draw focus")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.verticalMove(
        from: 1,
        direction: .up,
        optionCount: 3),
      .selectOption(index: 0))
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.verticalMove(
        from: 2,
        direction: .down,
        optionCount: 3),
      .focusOther,
      "ArrowDown from the final option moves into Other")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.verticalMove(
        from: 3,
        direction: .up,
        optionCount: 3),
      .selectOption(index: 2),
      "ArrowUp from Other returns to and selects the final option")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.verticalMove(
        from: 2,
        direction: .down,
        optionCount: 3,
        allowsOtherResponse: false),
      .stay,
      "ArrowDown stays on the final option when this question has no Other row")
  }

  func testPlanClarificationNumericShortcutsIncludeCodexOtherRow() {
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.numericShortcut(
        number: 1,
        optionCount: 3),
      .selectOption(index: 0))
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.numericShortcut(
        number: 4,
        optionCount: 3),
      .focusOther,
      "Codex assigns the number immediately after the options to Other")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.numericShortcut(
        number: 5,
        optionCount: 3),
      .ignore)
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.numericShortcut(
        number: 4,
        optionCount: 3,
        allowsOtherResponse: false),
      .ignore,
      "The number after the final option is unused when this question has no Other row")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.numericShortcut(
        number: 10,
        optionCount: 9),
      .ignore,
      "Codex numeric accelerators are limited to 1...9")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.numericShortcut(
        number: 4,
        optionCount: 3,
        autoAdvancePending: true),
      .ignore,
      "Codex blocks every numeric shortcut while a 180ms single-select advance is pending")
    XCTAssertFalse(
      PlanClarificationInteractionPolicy
        .allowsKeyboardQuestionNavigation(autoAdvancePending: true),
      "Codex blocks Left/Right keyboard navigation while auto-advance is pending")
    XCTAssertTrue(
      PlanClarificationInteractionPolicy
        .allowsKeyboardQuestionNavigation(autoAdvancePending: false))
  }

  func testPlanClarificationCardShortcutsDoNotConsumeOtherTyping() {
    XCTAssertFalse(
      PlanClarificationInteractionPolicy.allowsCardShortcuts(
        isOtherEditorFocused: true),
      "Current Codex leaves digits and Return inside the Other editor")
    XCTAssertTrue(
      PlanClarificationInteractionPolicy.allowsCardShortcuts(
        isOtherEditorFocused: false),
      "Card shortcuts remain available after the Other editor releases focus")
  }

  func testPlanClarificationAutoAdvanceRestoresFocusOnDestinationQuestion()
    throws
  {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")
    let advanceStart = try XCTUnwrap(
      source.range(of: "    private func advance(skipping: Bool) {")?
        .lowerBound)
    let advanceEnd = try XCTUnwrap(
      source.range(
        of: "    private func cancelAutoAdvance()",
        range: advanceStart..<source.endIndex)?.lowerBound)
    let advanceSource = String(source[advanceStart..<advanceEnd])

    XCTAssertTrue(
      advanceSource.contains("restoreCardFocusAfterAction()"),
      "Changing questions must restore card ownership after the destination view replaces the source card")
  }

  func testPlanClarificationWaitsForConfirmedOtherBlurBeforeFinalRefocus()
    throws
  {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")

    for marker in [
      "@State private var restoreCardFocusWhenOtherBlurs = false",
      "prepareToLeaveOtherForCardAction()",
      "if restoreCardFocusWhenOtherBlurs",
      "restoreCardFocusWhenOtherBlurs = false",
      "restoreCardFocusAfterAction()",
    ] {
      XCTAssertTrue(
        source.contains(marker),
        "Confirmed AppKit blur focus restoration is missing \(marker)")
    }
  }

  func testPlanClarificationShortcutsDoNotConsumeMainComposerTyping() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let leafSource = try ChatSourceFamily.read("ChatPageLeafViews.swift")
    let cardStart = try XCTUnwrap(
      leafSource.range(of: "struct PlanClarificationRequestCard: View")?
        .lowerBound)
    let cardEnd = try XCTUnwrap(
      leafSource.range(
        // PlanClarificationRequestCard closes ChatPageLeafViews+PlanCards.swift
        // since the 2026-09-02 split; the family reader joins the next file
        // (starting with its imports) right after it.
        of: "\nimport ",
        range: cardStart..<leafSource.endIndex)?.lowerBound)
    let cardSource = String(leafSource[cardStart..<cardEnd])

    XCTAssertTrue(
      cardSource.contains("@FocusState private var isCardFocused: Bool"),
      "The clarification card needs explicit focus state so shortcuts cannot leak into the main composer")
    XCTAssertTrue(
      cardSource.contains(".focused($isCardFocused)"),
      "The focusable clarification card must bind its focus state")
    XCTAssertTrue(
      cardSource.contains(".keyboardShortcut("),
      "Focus-scoped key equivalents must handle Computer Use and physical keyboard events through AppKit performKeyEquivalent")
    XCTAssertTrue(
      cardSource.contains(".disabled(planShortcutsDisabled)"),
      "Digits and Return must share one production focus gate")
    XCTAssertTrue(
      cardSource.contains(
        "PlanClarificationInteractionPolicy.allowsCardShortcuts("),
      "The shipping shortcut gate must use the tested Other-editor policy")
    XCTAssertTrue(
      cardSource.contains("planKeyboardShortcutButtons(for: question)"),
      "All no-modifier shortcuts must live in one focus-gated helper")
    XCTAssertGreaterThanOrEqual(
      cardSource.components(
        separatedBy: "restoreCardFocusAfterAction()").count,
      4,
      "After a shortcut or option-button action, focus must return to the card so the next numeric shortcut still works")
    for marker in [
      "@State private var focusRestoreGeneration = 0",
      "@State private var isRestoringCardFocus = false",
      "Task { @MainActor in",
      "await Task.yield()",
      "generation == focusRestoreGeneration",
      "handleOtherReturnKey()",
      "handleOtherArrowUp()",
      "navigateQuestionAndRestoreFocus(by:",
      "handleOtherSecondaryAction()",
    ] {
      XCTAssertTrue(
        cardSource.contains(marker),
        "Focus restoration contract is missing \(marker)")
    }
    XCTAssertFalse(
      cardSource.contains(
        "DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)"),
      "A fixed 50ms disabled window drops fast consecutive shortcuts")
    XCTAssertFalse(
      cardSource.contains("PlanClarificationShortcutMonitor("),
      "The zero-sized representable lifecycle is not reliable enough for the card shortcut contract")
  }

  func testPlanClarificationNumericOtherMatchesCodexMultiSelectReset() {
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.selectionOrderAfterNumericOther(
        allowsMultipleSelections: true,
        selectedOptionLabels: ["UI flow", "Recovery"]),
      [],
      "Codex's numeric shortcut to Other clears multi-select option state")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.selectionOrderAfterNumericOther(
        allowsMultipleSelections: false,
        selectedOptionLabels: ["Current project"]),
      ["Current project"],
      "The single-select clear remains owned by the common focusOther path")
  }

  func testHiddenPlanPromptEmitsCurrentCodexQuestionSchema() throws {
    let source = try ChatSourceFamily.read("ChatPageModel.swift")

    for required in [
      "one or more options; do not impose a three-option cap",
      "\"allowsMultipleSelections\":false",
      "\"allowsOtherResponse\":true",
      "\"option (Recommended)\"",
      "Set allowsOtherResponse=false",
      "exact suffix \" (Recommended)\"",
    ] {
      XCTAssertTrue(
        source.contains(required),
        "Hidden /plan prompt is missing current Codex schema guidance: \(required)")
    }
    XCTAssertFalse(
      source.contains("Ask one question at a time with 2–3 options"),
      "The hidden /plan prompt must not keep the obsolete 2–3 option cap")
  }

  func testPlanClarificationMultiSelectFocusTracksCodexSelectionOrder() {
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.updatedMultiSelectOrder(
        selectedOptionLabels: [],
        toggledOptionLabel: "UI flow"),
      ["UI flow"])
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.updatedMultiSelectOrder(
        selectedOptionLabels: ["UI flow", "Recovery"],
        toggledOptionLabel: "UI flow"),
      ["Recovery"],
      "Removing one checkbox focuses the most recently retained Codex selection")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.updatedMultiSelectOrder(
        selectedOptionLabels: ["Recovery"],
        toggledOptionLabel: "Recovery"),
      [],
      "Removing the final checkbox restores Codex's -1 empty focus state")
  }

  func testPlanClarificationOtherMarkerMatchesCodexActiveState() {
    XCTAssertTrue(
      PlanClarificationInteractionPolicy.otherMarkerIsActive(
        isFocused: false,
        selectedOptionCount: 0,
        otherText: "Custom scope"))
    XCTAssertTrue(
      PlanClarificationInteractionPolicy.otherMarkerIsActive(
        isFocused: true,
        selectedOptionCount: 1,
        otherText: "Preserved draft"))
    XCTAssertFalse(
      PlanClarificationInteractionPolicy.otherMarkerIsActive(
        isFocused: false,
        selectedOptionCount: 1,
        otherText: "Preserved draft"),
      "Codex preserves Other text after selecting an option but deactivates the pencil marker")
  }

  func testPlanClarificationSkipPreservesEnteredCodexResponse() {
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.skipIntent(
        allowsMultipleSelections: true,
        selectedOptionCount: 2,
        otherText: ""),
      .submitAnswer,
      "Codex keeps multi-select choices when Skip is clicked after answering")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.skipIntent(
        allowsMultipleSelections: false,
        selectedOptionCount: 1,
        otherText: "Use the existing migration"),
      .submitAnswer,
      "Codex keeps a non-empty Other response")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.skipIntent(
        allowsMultipleSelections: false,
        selectedOptionCount: 1,
        otherText: "   "),
      .skip,
      "A default single-select choice does not prevent an intentional Skip")
  }

  func testPlanClarificationReturnKeyMatchesCodexImmediateResponseSemantics() {
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.returnIntent(
        allowsMultipleSelections: false,
        selectedOptionIndex: 0),
      .reselectOption(index: 0),
      "Enter on a selected single option reselects it and restarts Codex's 180ms advance")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.returnIntent(
        allowsMultipleSelections: false,
        selectedOptionIndex: nil),
      .advance,
      "Enter with Other active advances the explicit freeform response")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.returnIntent(
        allowsMultipleSelections: true,
        selectedOptionIndex: 1),
      .advance,
      "Codex submits multi-select state instead of reselecting one checkbox")
  }

  func testPlanClarificationSelectionTimingMatchesCodexCommitSemantics() {
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.selectionIntent(
        allowsMultipleSelections: false,
        source: .explicitCommit,
        autoAdvancePending: false),
      .selectAndAutoAdvance,
      "Mouse, number-key, and Return commits start one 180ms single-select timer")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.selectionIntent(
        allowsMultipleSelections: false,
        source: .explicitCommit,
        autoAdvancePending: true),
      .ignore,
      "Codex ignores repeated commits while its first 180ms timer is pending")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.selectionIntent(
        allowsMultipleSelections: false,
        source: .verticalNavigation,
        autoAdvancePending: false),
      .selectOnly,
      "ArrowUp/ArrowDown update the highlighted option without auto-advancing")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.selectionIntent(
        allowsMultipleSelections: false,
        source: .verticalNavigation,
        autoAdvancePending: true),
      .ignore,
      "Codex blocks keyboard selection changes while auto-advance is pending")
    XCTAssertEqual(
      PlanClarificationInteractionPolicy.selectionIntent(
        allowsMultipleSelections: true,
        source: .explicitCommit,
        autoAdvancePending: false),
      .selectOnly,
      "Multi-select commits toggle a checkbox without auto-advance")
  }

  func testPlanClarificationOtherEditorMatchesCodexMultilineArrowSemantics()
    throws
  {
    XCTAssertEqual(
      PlanClarificationOtherEditorPolicy.arrowUpIntent(
        renderedHeight: 18,
        singleLineHeight: 18),
      .focusPreviousOption,
      "ArrowUp leaves a one-line Other field and returns to the final option")
    XCTAssertEqual(
      PlanClarificationOtherEditorPolicy.arrowUpIntent(
        renderedHeight: 40,
        singleLineHeight: 18),
      .preserveEditorNavigation,
      "ArrowUp stays inside a wrapped or newline-containing Other response")

    let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")
    XCTAssertTrue(
      source.contains("otherEditorHeight"),
      "ArrowUp must use the rendered editor height instead of always leaving the field")
    XCTAssertTrue(
      source.contains("maximumHeight: otherEditorMaximumHeight"),
      "The inline Other editor must grow while retaining a bounded four-line card")
    XCTAssertTrue(
      source.contains("ChatComposerTextView("),
      "The Other editor must use the AppKit-backed multiline editor because SwiftUI TextField consumes ArrowUp before onKeyPress")
    XCTAssertTrue(
      source.contains("onArrowUpAtSingleVisualLine:"),
      "The inline editor must explicitly hand a one-line ArrowUp back to option navigation")

    let appKitSource = try ChatSourceFamily.read("ChatPageAppKitBridges.swift")
    XCTAssertTrue(
      appKitSource.contains("isSingleVisualLine"),
      "The AppKit editor must distinguish one visual line from wrapped or newline content")
    XCTAssertTrue(
      appKitSource.contains("event.keyCode == 126"),
      "The AppKit editor must recognize the macOS ArrowUp key code")
    let keyDownStart = try XCTUnwrap(
      appKitSource.range(
        of: "        override func keyDown(with event: NSEvent) {")?
        .lowerBound)
    let keyDownEnd = try XCTUnwrap(
      appKitSource.range(
        of: "            if consumeAsSuggestionKey(event) { return }",
        range: keyDownStart..<appKitSource.endIndex)?.upperBound)
    let arrowUpSource = String(appKitSource[keyDownStart..<keyDownEnd])
    XCTAssertTrue(
      arrowUpSource.contains("!hasMarkedText()"),
      "Zhuyin/Pinyin composition must keep ArrowUp inside the IME candidate UI")
    XCTAssertTrue(
      appKitSource.contains(
        "else if textView.window?.firstResponder === textView"),
      "Selecting a normal option must actually blur the Other NSTextView so later number keys remain Codex shortcuts")
    XCTAssertTrue(
      appKitSource.contains("context.coordinator.wantsFocus = isFocused"),
      "Deferred AppKit focus work must track the newest SwiftUI focus intent")
    XCTAssertTrue(
      appKitSource.contains("coordinator.wantsFocus == true"),
      "A stale blur update must not cancel a newer numeric shortcut that focuses Other")
    XCTAssertTrue(
      appKitSource.contains("coordinator.wantsFocus == false"),
      "A stale focus update must not undo an explicit option-selection blur")
    XCTAssertTrue(
      appKitSource.contains("allowsProgrammaticBlur = false"),
      "The main composer must not be blurred by a stale initial SwiftUI focus snapshot")
    XCTAssertTrue(
      source.contains("allowsProgrammaticBlur: true"),
      "Only the inline Other editor needs state-driven blur after a keyboard option selection")
    XCTAssertTrue(
      source.contains("resignsFocusOnSubmit: true"),
      "Other Return must synchronously release the NSTextView before the destination card receives the next key")
    XCTAssertTrue(
      appKitSource.contains("if resignsFocusOnSubmit"),
      "The AppKit editor must support an opt-in synchronous blur before invoking Other submit")
  }

  func testSelectingSingleOptionPreservesCodexOtherDraft() throws {
    let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")
    let selectStart = try XCTUnwrap(
      source.range(of: "    private func select(")?.lowerBound)
    let selectEnd = try XCTUnwrap(
      source.range(
        of: "    private func draftBinding(",
        range: selectStart..<source.endIndex)?.lowerBound)
    let selectSource = String(source[selectStart..<selectEnd])
    XCTAssertFalse(
      selectSource.contains("drafts[question.id] = \"\""),
      "Current Codex preserves freeformText when a normal option is selected")
    XCTAssertTrue(
      source.contains("handleReturnKey()"),
      "The visible Skip/Next click and the Enter-key path must remain distinct")
  }

  func testUntouchedDefaultSingleSelectionSubmitsAsSkipped() throws {
    let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")
    XCTAssertTrue(
      source.contains(
        "@State private var explicitlyAnsweredQuestionIDs: Set<String> = []"),
      "Visual default selection and an explicit user answer must be tracked separately")
    XCTAssertTrue(
      source.contains(
        "let wasExplicitlyAnswered = explicitlyAnsweredQuestionIDs.contains(question.id)"),
      "Submission must determine whether each default-looking answer was actually touched")
    XCTAssertTrue(
      source.contains(
        "let shouldSkip = explicitlySkipped || !wasExplicitlyAnswered"),
      "Navigating past an untouched default must submit skipped=true")
    XCTAssertTrue(
      source.contains("selectedOptions: shouldSkip ? [] :"),
      "An untouched visual default must not leak into the serialized answer")
  }

  func testPlanParityFixtureSupportsWritingSummaryAndQuestions() throws {
    let source = try ChatSourceFamily.read("ChatPageModel.swift")
    XCTAssertTrue(
      source.contains("TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE"))
    for scene in [
      "writing",
      "summary",
      "anchor-failure",
      "existing-plan-writing",
      "questions",
      "contract",
    ] {
      XCTAssertTrue(source.contains("case \"\(scene)\""))
    }
  }

  func testPlanParityLongSummaryFixtureProvidesScrollableInspectorContent()
    async throws
  {
    let fixture = try makeFixture(
      "long-summary-fixture",
      extraEnvironment: [
        "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
        "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE": "long-summary",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)

    let markdown = try XCTUnwrap(
      fixture.model.activePlanArtifact?.markdownExport())
    XCTAssertGreaterThan(
      markdown.split(separator: "\n", omittingEmptySubsequences: false).count,
      40,
      "The long-summary fixture must exceed the inspector viewport so vertical scrolling can be verified live")
    XCTAssertTrue(markdown.contains("## Rollback"))
    XCTAssertFalse(fixture.model.isRunning)
  }

  func testPlanParityAnchorFailureFixtureKeepsArtifactOnProducingAssistant()
    async throws
  {
    let fixture = try makeFixture(
      "anchor-failure-fixture",
      extraEnvironment: [
        "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
        "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE": "anchor-failure",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)

    XCTAssertEqual(
      fixture.model.activePlanArtifact?.sourceAssistantMessageID,
      "fixture-plan-summary-assistant")
    XCTAssertEqual(
      fixture.model.messages.last(where: { $0.role == .assistant })?.id,
      "fixture-plan-failed-assistant")
    XCTAssertFalse(fixture.model.isActivePlanTurnWriting)
  }

  func testPlanParityExistingArtifactWritingFixtureShowsNewWritingState()
    async throws
  {
    let fixture = try makeFixture(
      "existing-plan-writing-fixture",
      extraEnvironment: [
        "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
        "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE": "existing-plan-writing",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)

    XCTAssertNotNil(fixture.model.activePlanArtifact)
    XCTAssertTrue(
      fixture.model.isActivePlanTurnWriting,
      "An existing Plan must remain visible while the new Plan turn shows Writing plan")
  }

  func testPlanParityContractFixtureShowsRecommendedWithoutOther()
    async throws
  {
    let fixture = try makeFixture(
      "question-contract-fixture",
      extraEnvironment: [
        "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
        "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE": "contract",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)

    let question = try XCTUnwrap(
      fixture.model.messages.last(where: { $0.role == .assistant })?
        .planQuestions.first)
    XCTAssertFalse(question.allowsOtherResponse)
    XCTAssertEqual(question.options.count, 2)
    XCTAssertTrue(question.options[0].isCodexRecommended)
    XCTAssertEqual(question.options[0].codexDisplayLabel, "Current project")
  }

  func testPlanParityQuestionFixtureCompletesLocallyWithoutDispatchingModel()
    async throws
  {
    let fixture = try makeFixture(
      "question-fixture-submit",
      extraEnvironment: [
        "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
        "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE": "questions",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)

    XCTAssertEqual(
      fixture.model.messages.last(where: { $0.role == .assistant })?
        .planQuestions.count,
      2)
    fixture.model.answerPlanQuestions([
      PlanQuestionAnswerV1(
        questionID: "import-scope",
        selectedOptions: [
          .init(
            label: "Current project",
            detail: "Keep the change narrow and reversible.")
        ]),
      PlanQuestionAnswerV1(
        questionID: "validation",
        selectedOptions: [
          .init(
            label: "UI flow",
            detail: "Cover visible import interactions."),
          .init(
            label: "Persistence",
            detail: "Cover restart and durable state."),
        ],
        otherText: "Additional audit"),
    ])

    let deadline = Date().addingTimeInterval(2)
    while fixture.model.activePlanArtifact == nil && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNotNil(
      fixture.model.activePlanArtifact,
      "UI-only fixture submission must finish as a local Plan summary")
    XCTAssertFalse(
      fixture.model.isRunning,
      "UI-only fixture must never leave a model runner active")
    XCTAssertTrue(
      fixture.model.messages.last(where: { $0.role == .assistant })?
        .planQuestions.isEmpty == true)
    XCTAssertTrue(
      fixture.model.activePlanArtifact?.markdownExport().contains(
        "UI flow, Persistence, Additional audit") == true,
      "multi-select answers must preserve the simultaneous Other response")
  }

  func testTraditionalChinesePlanQuestionFixtureCompletesLocallyInChinese()
    async throws
  {
    let fixture = try makeFixture(
      "question-zh-hant-fixture-submit",
      extraEnvironment: [
        "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
        "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE": "questions-zh-hant",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)

    XCTAssertEqual(
      fixture.model.messages.first(where: { $0.role == .user })?.text,
      "/plan 規劃一個安全的中文專案匯入流程，包含驗證、復原與使用者確認，只做規劃不要修改檔案")
    let questions = try XCTUnwrap(
      fixture.model.messages.last(where: { $0.role == .assistant })?
        .planQuestions)
    XCTAssertEqual(questions.map(\.question), [
      "這份計畫要處理哪個匯入範圍？",
      "需要涵蓋哪些驗證路徑？",
    ])
    XCTAssertEqual(questions[0].options.map(\.label), [
      "目前專案",
      "所有專案",
    ])
    XCTAssertEqual(questions[1].options.map(\.label), [
      "介面流程",
      "資料保存",
      "復原流程",
    ])

    fixture.model.answerPlanQuestions([
      PlanQuestionAnswerV1(
        questionID: "import-scope-zh-hant",
        selectedOptions: [
          .init(
            label: "所有專案",
            detail: "涵蓋較廣的遷移範圍並增加驗證。")
        ]),
      PlanQuestionAnswerV1(
        questionID: "validation-zh-hant",
        selectedOptions: [
          .init(
            label: "介面流程",
            detail: "驗證使用者看得到的匯入互動。"),
          .init(
            label: "資料保存",
            detail: "驗證重新啟動與持久狀態。"),
        ],
        otherText: "額外稽核"),
    ])

    let deadline = Date().addingTimeInterval(2)
    while fixture.model.activePlanArtifact == nil && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let markdown = try XCTUnwrap(
      fixture.model.activePlanArtifact?.markdownExport())
    XCTAssertFalse(fixture.model.isRunning)
    XCTAssertTrue(markdown.contains("匯入範圍：所有專案"))
    XCTAssertTrue(markdown.contains("驗證路徑：介面流程、資料保存、額外稽核"))
    XCTAssertTrue(markdown.contains("使用者明確確認後才寫入"))
  }

  func testTraditionalChineseProjectPlanCanCreateExactlyOneGoal()
    async throws
  {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "tatwo-plan-goal-project-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let fixture = try makeFixture(
      "question-zh-hant-project-goal",
      extraEnvironment: [
        "TATWO_ULTRAWORK_CHAT_FIXTURE": "chat-transcript",
        "TATWO_ULTRAWORK_CHAT_PLAN_FIXTURE": "questions-zh-hant",
        "TATWO_ULTRAWORK_CHAT_WORKDIR": workspace.path,
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await waitForInitialStoreLoad(fixture.model)

    XCTAssertNotNil(fixture.model.selectedProjectID)
    XCTAssertEqual(
      fixture.model.selectedThread?.sourceMarker,
      TatwoNativeChatThreadSourceMarker.userOwned)
    XCTAssertEqual(
      fixture.model.selectedProject?.workdir,
      workspace.standardizedFileURL.path)

    fixture.model.answerPlanQuestions([
      PlanQuestionAnswerV1(
        questionID: "import-scope-zh-hant",
        selectedOptions: [
          .init(
            label: "目前專案",
            detail: "維持範圍精簡且容易復原。")
        ]),
      PlanQuestionAnswerV1(
        questionID: "validation-zh-hant",
        selectedOptions: [
          .init(
            label: "介面流程",
            detail: "驗證使用者看得到的匯入互動。"),
          .init(
            label: "資料保存",
            detail: "驗證重新啟動與持久狀態。"),
          .init(
            label: "復原流程",
            detail: "驗證取消操作與格式錯誤資料。"),
        ],
        otherText: "Goal UI 顯示完成"),
    ])
    let planDeadline = Date().addingTimeInterval(2)
    while fixture.model.activePlanArtifact == nil && Date() < planDeadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    fixture.model.updatePlanFlowSelection(.init(
      destination: .goal,
      collaboration: .singleModel,
      modelAssignment: .single))
    fixture.model.confirmActivePlan()
    try await waitForPlanConfirmation(fixture.model)
    try await Task.sleep(nanoseconds: 500_000_000)

    let contractID = try XCTUnwrap(
      fixture.model.selectedThread?.workOSContractID,
      fixture.model.selectedWorkOSStateMessage)
    XCTAssertNotNil(fixture.model.selectedThread?.workOSGoalID)
    XCTAssertNil(
      fixture.model.selectedThread?.loopsConfig,
      "Plan 選擇單模型後不得偷偷物化 Ultrawork 拓撲")
    XCTAssertNil(
      fixture.model.selectedThread?.bindingInvalidation,
      "單模型 Goal 建立後不得立刻自我取消並留下綁定失效標記")
    let goalStore = TatwoGoalRunStore(directoryURL: fixture.root)
    XCTAssertNotEqual(
      try goalStore.requireIssuedContract(contractID).status,
      .cancelled)
    XCTAssertEqual(
      try goalRunFileCount(in: fixture.root),
      1,
      "同一次 Plan 確認只能建立一個 GoalRun")
  }

  func testPlanTranscriptScrollDestinationKeepsStructuredTurnStartVisible() {
    XCTAssertEqual(
      ChatTranscriptScrollDestination.resolve(
        latestAssistantMessageID: "assistant",
        hasPlanArtifact: true,
        isPlanWriting: false,
        latestAssistantHasPlanQuestions: false,
        contentHeight: 420,
        viewportHeight: 600),
      .none)

    XCTAssertEqual(
      ChatTranscriptScrollDestination.resolve(
        latestAssistantMessageID: "assistant",
        hasPlanArtifact: false,
        isPlanWriting: false,
        latestAssistantHasPlanQuestions: true,
        contentHeight: 900,
        viewportHeight: 600),
      .itemTop("message:assistant"))

    XCTAssertEqual(
      ChatTranscriptScrollDestination.resolve(
        latestAssistantMessageID: "assistant",
        hasPlanArtifact: false,
        isPlanWriting: true,
        latestAssistantHasPlanQuestions: false,
        contentHeight: 900,
        viewportHeight: 600),
      .itemTop("tatwo-plan-writing-summary"))
  }

  func testPlanTranscriptAnchorsCompletedArtifactToItsProducingAssistant() throws {
    let source = try chatPageSource()

    XCTAssertTrue(
      source.contains("planArtifact?.sourceAssistantMessageID"),
      "A completed Plan must remain attached to the assistant turn that produced it")
    XCTAssertTrue(
      source.contains("message.id == planArtifactMessageID"),
      "A later failed assistant turn must not inherit the previous Plan card")
    XCTAssertFalse(
      source.contains(
        """
        message.id
                                                    == latestAssistantMessageID
                                                    ? planArtifact
        """),
      "Latest-assistant placement moves an older Plan underneath unrelated failures")
  }

  func testPlanArtifactProjectionPlacementTruthTable() {
    XCTAssertEqual(
      ChatPlanArtifactTranscriptProjection.placement(
        hasArtifact: false,
        sourceAssistantMessageID: nil,
        isPlanWriting: false),
      .init(completedArtifact: .none, includesWritingRow: false))

    XCTAssertEqual(
      ChatPlanArtifactTranscriptProjection.placement(
        hasArtifact: false,
        sourceAssistantMessageID: nil,
        isPlanWriting: true),
      .init(completedArtifact: .none, includesWritingRow: true))

    XCTAssertEqual(
      ChatPlanArtifactTranscriptProjection.placement(
        hasArtifact: true,
        sourceAssistantMessageID: nil,
        isPlanWriting: false),
      .init(completedArtifact: .standalone, includesWritingRow: false))

    XCTAssertEqual(
      ChatPlanArtifactTranscriptProjection.placement(
        hasArtifact: true,
        sourceAssistantMessageID: nil,
        isPlanWriting: true),
      .init(completedArtifact: .standalone, includesWritingRow: true))

    XCTAssertEqual(
      ChatPlanArtifactTranscriptProjection.placement(
        hasArtifact: true,
        sourceAssistantMessageID: "plan-assistant",
        isPlanWriting: false),
      .init(
        completedArtifact: .attachedToSourceAssistant,
        includesWritingRow: false))

    XCTAssertEqual(
      ChatPlanArtifactTranscriptProjection.placement(
        hasArtifact: true,
        sourceAssistantMessageID: "plan-assistant",
        isPlanWriting: true),
      .init(
        completedArtifact: .attachedToSourceAssistant,
        includesWritingRow: true))
  }

  func testExistingPlanDoesNotSuppressWritingPlanForANewPlanTurn() throws {
    let source = try chatPageSource()

    XCTAssertTrue(
      source.contains("isPlanWriting: model.isActivePlanTurnWriting"),
      "A new Plan turn must show Writing plan even when the thread already has a Plan artifact")
    XCTAssertFalse(
      source.contains(
        """
        model.isPlanModeEnabled
                && model.isRunning
                && model.activePlanArtifact == nil
        """),
      "An existing Plan artifact must not suppress the current Writing plan state")
  }

  func testOrdinaryTranscriptStillFollowsBottomSentinel() {
    XCTAssertEqual(
      ChatTranscriptScrollDestination.resolve(
        latestAssistantMessageID: "assistant",
        hasPlanArtifact: false,
        isPlanWriting: false,
        latestAssistantHasPlanQuestions: false,
        contentHeight: 900,
        viewportHeight: 600),
      .bottom)
  }

  private func chatPageSource() throws -> String {
    try ChatSourceFamily.read("ChatPage.swift")
  }
}

@MainActor
private final class RejectingPlanClarificationDispatchService:
  ChatDispatchService
{
  private(set) var startCount = 0

  func startRuntime(
    model: ChatPageModel,
    command: ChatCLICommand,
    nativePrompt: String,
    dispatchSnapshot: ChatTurnDispatchSnapshot,
    runID: String,
    activityTurnID: String,
    allowsNativeGovernanceFallback: Bool,
    nativeGovernanceFallbackCommand: ChatCLICommand?,
    onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
  ) -> ChatRunnerAttemptIdentity? {
    startCount += 1
    model.lastNativeRuntimeStartBlocker = "test_forced_rejection"
    return nil
  }
}
