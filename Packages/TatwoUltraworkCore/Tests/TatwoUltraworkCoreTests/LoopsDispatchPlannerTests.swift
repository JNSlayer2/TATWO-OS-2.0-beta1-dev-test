import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class LoopsDispatchPlannerTests: XCTestCase {
  func testComposeSubTaskIncludesGoalSupervisorAndReceiptInstructions() {
    let task = TatwoLoopsDispatchPlanner.composeSubTask(
      session: makeSession(),
      subLabel: "Verifier A",
      subModelID: "gpt-5.6-sol")

    XCTAssertTrue(task.contains("Ship the verified data-layer planner."))
    XCTAssertTrue(task.contains("fable5"))
    XCTAssertTrue(task.contains("收據"))
    XCTAssertTrue(task.contains("Verifier A"))
    XCTAssertTrue(task.contains("gpt-5.6-sol"))
    XCTAssertTrue(task.contains("只做"))
    XCTAssertTrue(task.contains("回報給監工"))
    XCTAssertTrue(task.contains("不代表已派發"))
    XCTAssertTrue(task.contains("runtime dispatch record"))
  }

  func testEmptySessionIsExplicitPlanningPreviewWithNoRuntimeReceipt() {
    let truth = TatwoLoopsDispatchPlanner.runtimeTruth(session: makeSession())

    XCTAssertEqual(truth.state, .planningPreview)
    XCTAssertEqual(truth.headline, "規劃預覽")
    XCTAssertEqual(truth.dispatchLabel, "尚未派發")
    XCTAssertEqual(truth.runtimeReceiptLabel, "無 runtime receipt")
    XCTAssertEqual(truth.runtimeReceiptCount, 0)
    XCTAssertFalse(truth.countsAsRuntimeProgress)
  }

  func testPlannedAgentsAndEmptyCycleDoNotCountAsRuntimeProgress() {
    var session = makeSession()
    session.subAgents = [
      TatwoLoopsSubAgent(
        label: "Planned Reviewer",
        modelID: "gpt-5.6-sol",
        status: .planned)
    ]
    session.cycles = [
      TatwoLoopsCycleProgress(
        round: 1,
        totalRounds: 3,
        producedCount: 0,
        verifiedCount: 0,
        blockedCount: 0)
    ]

    let truth = TatwoLoopsDispatchPlanner.runtimeTruth(session: session)
    let briefing = TatwoLoopsDispatchPlanner.supervisorBriefing(session: session)

    XCTAssertEqual(truth.state, .notDispatched)
    XCTAssertEqual(truth.plannedAgentCount, 1)
    XCTAssertFalse(truth.countsAsRuntimeProgress)
    XCTAssertTrue(briefing.contains("規劃預覽／尚未派發"))
    XCTAssertTrue(briefing.contains("空 cycle 不算 runtime 進度"))
    XCTAssertTrue(briefing.contains("無 runtime receipt"))
  }

  func testDispatchObjectiveKeepsInheritedGoalInsteadOfReplacingItWithSupervisorChat() {
    var session = makeSession()
    session.messages = [
      TatwoLoopsMessage(
        role: "supervisor",
        authorModelID: "fable5",
        text: "只回目前 Goal 中的指定字串。",
        createdISO: "2026-07-17T00:00:00Z")
    ]

    XCTAssertEqual(
      TatwoLoopsDispatchPlanner.dispatchObjective(session: session),
      "Ship the verified data-layer planner.")
  }

  func testDispatchObjectiveUsesParentGoalForLegacyPlaceholderSession() {
    var session = makeSession()
    session.plg = TatwoLoopsPLG(
      plan: "（待監工填寫計畫）",
      loops: "主導：MiniMax M3",
      goal: "（待監工填寫目標）")
    session.messages = [
      TatwoLoopsMessage(
        role: "supervisor",
        authorModelID: "minimax-m3",
        text: "只回目前 Goal 中的指定字串。",
        createdISO: "2026-07-17T00:00:00Z")
    ]

    XCTAssertEqual(
      TatwoLoopsDispatchPlanner.dispatchObjective(
        session: session,
        fallbackObjective: "Tatwo Chat request: 僅在 sandbox 建立 harmless.txt"),
      "Tatwo Chat request: 僅在 sandbox 建立 harmless.txt")
  }

  func testFoldVerifiedResultAppendsMessageAndIncrementsLatestCycle() {
    var session = makeSession()
    session.cycles = [
      TatwoLoopsCycleProgress(
        round: 1,
        totalRounds: 3,
        producedCount: 2,
        verifiedCount: 1,
        blockedCount: 0)
    ]

    let folded = TatwoLoopsDispatchPlanner.foldSubResult(
      into: session,
      subLabel: "Verifier A",
      subModelID: "gpt-5.6-sol",
      resultText: "All checks passed.",
      verified: true)

    XCTAssertEqual(folded.messages.last?.role, "sub")
    XCTAssertEqual(folded.messages.last?.authorModelID, "gpt-5.6-sol")
    XCTAssertEqual(folded.messages.last?.text, "All checks passed.")
    XCTAssertEqual(folded.cycles.last?.producedCount, 3)
    XCTAssertEqual(folded.cycles.last?.verifiedCount, 2)
    XCTAssertEqual(folded.cycles.last?.blockedCount, 0)

    let truth = TatwoLoopsDispatchPlanner.runtimeTruth(session: folded)
    XCTAssertEqual(truth.state, .notDispatched)
    XCTAssertEqual(truth.runtimeReceiptCount, 0)
    XCTAssertTrue(truth.runtimeReceiptLabel.contains("無 runtime receipt"))
    XCTAssertFalse(truth.countsAsRuntimeProgress)
  }

  func testStaleSessionRunningAndArtifactCountersCannotClaimRuntimeProgress() {
    var session = makeSession()
    session.status = .running
    session.subAgents = [
      TatwoLoopsSubAgent(
        label: "Legacy runner",
        modelID: "fable5",
        status: .running)
    ]
    session.cycles = [
      TatwoLoopsCycleProgress(
        round: 2,
        totalRounds: 4,
        producedCount: 8,
        verifiedCount: 7,
        blockedCount: 1)
    ]

    let truth = TatwoLoopsDispatchPlanner.runtimeTruth(session: session)

    XCTAssertEqual(truth.state, .notDispatched)
    XCTAssertEqual(truth.activeAgentCount, 0)
    XCTAssertEqual(truth.runtimeReceiptCount, 0)
    XCTAssertFalse(truth.countsAsRuntimeProgress)
    XCTAssertTrue(truth.dispatchLabel.contains("session 狀態"))
  }

  func testRuntimeTruthOnlyAdvancesFromDispatchRecords() {
    let runningRecord = TatwoDispatchRecord(
      id: "dispatch-running",
      contractID: "contract-runtime",
      bindingID: "binding-runtime",
      sourceSlotID: "slot-runtime",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "Runtime truth",
      status: .running,
      startedAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2))

    let truth = TatwoLoopsDispatchPlanner.runtimeTruth(
      session: makeSession(),
      dispatchRecords: [runningRecord])

    XCTAssertEqual(truth.state, .running)
    XCTAssertEqual(truth.activeAgentCount, 1)
    XCTAssertTrue(truth.countsAsRuntimeProgress)
  }

  func testFoldVerifiedResultMarksExistingSubPassed() {
    var session = makeSession()
    session.subAgents = [
      TatwoLoopsSubAgent(
        label: "Verifier A",
        modelID: "gpt-5.6-sol",
        status: .running)
    ]

    let folded = TatwoLoopsDispatchPlanner.foldSubResult(
      into: session,
      subLabel: "Verifier A",
      subModelID: "gpt-5.6-sol",
      resultText: "Verified.",
      verified: true)

    XCTAssertEqual(folded.subAgents.count, 1)
    XCTAssertEqual(folded.subAgents[0].status, .passed)
  }

  func testFoldBlockedResultCreatesCycleAndAppendsBlockedSub() {
    let folded = TatwoLoopsDispatchPlanner.foldSubResult(
      into: makeSession(),
      subLabel: "Scout B",
      subModelID: "grok",
      resultText: "Blocked by missing fixture.",
      verified: false)

    XCTAssertEqual(folded.cycles.count, 1)
    XCTAssertEqual(folded.cycles[0].round, 1)
    XCTAssertEqual(folded.cycles[0].producedCount, 1)
    XCTAssertEqual(folded.cycles[0].verifiedCount, 0)
    XCTAssertEqual(folded.cycles[0].blockedCount, 1)
    XCTAssertEqual(folded.subAgents.last?.label, "Scout B")
    XCTAssertEqual(folded.subAgents.last?.modelID, "grok")
    XCTAssertEqual(folded.subAgents.last?.status, .blocked)
  }

  func testSupervisorBriefingIncludesPLGAllSubsAndLatestCycle() {
    var session = makeSession()
    session.subAgents = [
      TatwoLoopsSubAgent(
        label: "Verifier A",
        modelID: "gpt-5.6-sol",
        status: .passed),
      TatwoLoopsSubAgent(
        label: "Scout B",
        modelID: "grok",
        status: .blocked),
    ]
    session.cycles = [
      TatwoLoopsCycleProgress(
        round: 1,
        totalRounds: 3,
        producedCount: 2,
        verifiedCount: 1,
        blockedCount: 1),
      TatwoLoopsCycleProgress(
        round: 2,
        totalRounds: 3,
        producedCount: 4,
        verifiedCount: 3,
        blockedCount: 1),
    ]

    let briefing = TatwoLoopsDispatchPlanner.supervisorBriefing(session: session)

    XCTAssertTrue(briefing.contains("Map the bounded dispatch flow."))
    XCTAssertTrue(briefing.contains("Run sub work and fold receipts."))
    XCTAssertTrue(briefing.contains("Ship the verified data-layer planner."))
    XCTAssertTrue(briefing.contains("Verifier A"))
    XCTAssertTrue(briefing.contains("passed"))
    XCTAssertTrue(briefing.contains("Scout B"))
    XCTAssertTrue(briefing.contains("blocked"))
    XCTAssertTrue(briefing.contains("round 2"))
    XCTAssertTrue(briefing.contains("produced 4"))
    XCTAssertTrue(briefing.contains("verified artifacts 3"))
    XCTAssertTrue(briefing.contains("blocked 1"))
  }

  func testAdvanceRoundAppendsZeroedNextCycle() {
    var session = makeSession()
    session.cycles = [
      TatwoLoopsCycleProgress(
        round: 2,
        totalRounds: 4,
        producedCount: 5,
        verifiedCount: 4,
        blockedCount: 1)
    ]

    let advanced = TatwoLoopsDispatchPlanner.advanceRound(session)

    XCTAssertEqual(advanced.cycles.count, 2)
    XCTAssertEqual(advanced.cycles.last?.round, 3)
    XCTAssertEqual(advanced.cycles.last?.totalRounds, 4)
    XCTAssertEqual(advanced.cycles.last?.producedCount, 0)
    XCTAssertEqual(advanced.cycles.last?.verifiedCount, 0)
    XCTAssertEqual(advanced.cycles.last?.blockedCount, 0)
    XCTAssertEqual(advanced.status, session.status)
  }

  func testFoldAndAdvanceRoundDoNotChangeSupervisorModelID() {
    let session = makeSession(supervisorModelID: "fable5")
    let folded = TatwoLoopsDispatchPlanner.foldSubResult(
      into: session,
      subLabel: "Verifier A",
      subModelID: "gpt-5.6-sol",
      resultText: "Done.",
      verified: true)
    let advanced = TatwoLoopsDispatchPlanner.advanceRound(folded)

    XCTAssertEqual(folded.supervisorModelID, "fable5")
    XCTAssertEqual(advanced.supervisorModelID, "fable5")
  }

  func testFoldedSessionRetainsCodableRoundTripConsistency() throws {
    let folded = TatwoLoopsDispatchPlanner.foldSubResult(
      into: makeSession(),
      subLabel: "Verifier A",
      subModelID: "gpt-5.6-sol",
      resultText: "Receipt attached.",
      verified: true)

    let data = try JSONEncoder().encode(folded)
    let decoded = try JSONDecoder().decode(TatwoLoopsSession.self, from: data)

    XCTAssertEqual(decoded, folded)
  }

  private func makeSession(
    supervisorModelID: String = "fable5"
  ) -> TatwoLoopsSession {
    TatwoLoopsSupervisorRule.make(
      parentSupervisorModelID: supervisorModelID,
      parentKind: .mainChat,
      parentID: UUID(),
      projectID: UUID(),
      title: "Dispatch planner",
      plg: TatwoLoopsPLG(
        plan: "Map the bounded dispatch flow.",
        loops: "Run sub work and fold receipts.",
        goal: "Ship the verified data-layer planner."),
      reviewerModelID: "gpt-5.6-sol")
  }
}
