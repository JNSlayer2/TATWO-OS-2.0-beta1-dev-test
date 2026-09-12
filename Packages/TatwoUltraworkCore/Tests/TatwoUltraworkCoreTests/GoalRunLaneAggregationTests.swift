import XCTest

@testable import TatwoUltraworkCore

final class GoalRunLaneAggregationTests: XCTestCase {
  func testAggregateBuildsOneLanePerGoalAndGroupsLatestWorkersByIdentity() {
    let goal = makeGoal(
      status: .running,
      mode: .l,
      updatedAt: date(120),
      receipts: [
        TatwoStoredReceipt(
          receiptID: "goal-plan",
          kind: "plan",
          submittedAt: date(115))
      ])
    let dispatches = TatwoStoredDispatchRun(
      contractID: goal.contractID,
      records: [
        makeDispatch(
          id: "sub-1",
          contractID: goal.contractID,
          bindingID: "sub-a",
          identity: .sub,
          modelID: "gpt-5.6-sol",
          status: .running,
          updatedAt: date(130)),
        makeDispatch(
          id: "sub-2",
          contractID: goal.contractID,
          bindingID: "sub-b",
          identity: .sub,
          modelID: "minimax-m3",
          status: .completed,
          updatedAt: date(140),
          receiptID: "sub-receipt"),
        makeDispatch(
          id: "verify-1",
          contractID: goal.contractID,
          bindingID: "verifier-a",
          identity: .verifier,
          modelID: "gpt-5.5",
          status: .completed,
          updatedAt: date(150),
          receiptID: "verify-receipt"),
      ],
      updatedAt: date(150))

    let snapshot = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [goal],
      dispatchRuns: [dispatches],
      observedAt: date(200))

    XCTAssertEqual(snapshot.lanes.count, 1)
    let lane = try! XCTUnwrap(snapshot.lanes.first)
    XCTAssertEqual(lane.id, goal.goalID)
    XCTAssertEqual(lane.state, .running)
    XCTAssertEqual(lane.identityGroups.map(\.identity), [.sub, .verifier])

    let sub = lane.identityGroups.first { $0.identity == .sub }
    XCTAssertEqual(sub?.workerCount, 2)
    XCTAssertEqual(sub?.activeWorkerCount, 1)
    XCTAssertEqual(sub?.failedWorkerCount, 0)
    XCTAssertEqual(sub?.dispatchAttemptCount, 2)
    XCTAssertEqual(sub?.modelIDs, ["gpt-5.6-sol", "minimax-m3"])

    XCTAssertEqual(lane.cost.mode, .l)
    XCTAssertEqual(lane.cost.budgetLabel, "約 8–30 萬")
    XCTAssertEqual(lane.cost.dispatchAttemptCount, 3)
    XCTAssertEqual(lane.cost.activeDispatchCount, 1)
    XCTAssertEqual(lane.cost.distinctModelCount, 3)
    XCTAssertEqual(lane.latestReceipt?.receiptID, "verify-receipt")
    XCTAssertEqual(lane.latestReceipt?.source, .dispatch)
    XCTAssertEqual(lane.updatedAt, date(150))
    XCTAssertTrue(lane.blockers.isEmpty)
  }

  func testLatestRetryPerBindingDrivesBlockersWhileCostCountsAllAttempts() {
    let goal = makeGoal(status: .running)
    let run = TatwoStoredDispatchRun(
      contractID: goal.contractID,
      records: [
        makeDispatch(
          id: "attempt-1",
          contractID: goal.contractID,
          bindingID: "worker-a",
          identity: .sub,
          status: .failed,
          updatedAt: date(100),
          errorMessage: "old failure"),
        makeDispatch(
          id: "attempt-2",
          contractID: goal.contractID,
          bindingID: "worker-a",
          identity: .sub,
          status: .completed,
          updatedAt: date(200),
          receiptID: "retry-pass"),
        makeDispatch(
          id: "attempt-3",
          contractID: goal.contractID,
          bindingID: "worker-b",
          identity: .sub,
          status: .failed,
          updatedAt: date(210),
          errorMessage: "latest failure"),
      ],
      updatedAt: date(210))

    let lane = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [goal],
      dispatchRuns: [run],
      observedAt: date(300)
    ).lanes[0]

    XCTAssertEqual(lane.cost.dispatchAttemptCount, 3)
    XCTAssertEqual(lane.identityGroups[0].workerCount, 2)
    XCTAssertEqual(lane.identityGroups[0].failedWorkerCount, 1)
    XCTAssertEqual(
      lane.blockers,
      [
        TatwoGoalRunLaneBlockerV1(
          code: "dispatch_failed",
          source: .dispatch,
          sourceID: "worker-b",
          identity: .sub,
          observedAt: date(210))
      ])
    XCTAssertEqual(lane.latestReceipt?.receiptID, "retry-pass")
  }

  func testGoalStatusesMapToLaneStatesWithoutStartingScheduler() {
    let pairs: [(GoalRunStatus, TatwoGoalRunLaneStateV1)] = [
      (.planned, .planned),
      (.running, .running),
      (.succeeded, .passed),
      (.humanGate, .humanGate),
      (.blocked, .blocked),
      (.superseded, .superseded),
      (.passed, .passed),
      (.rollbackRequired, .rollbackRequired),
    ]
    let goals = pairs.enumerated().map { index, pair in
      makeGoal(
        suffix: "\(index)",
        status: pair.0,
        updatedAt: date(Double(index)))
    }

    let snapshot = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: goals,
      dispatchRuns: [],
      observedAt: date(100))
    let statesByContract = Dictionary(
      uniqueKeysWithValues: snapshot.lanes.map { ($0.contractID, $0.state) })

    for (index, pair) in pairs.enumerated() {
      XCTAssertEqual(statesByContract["contract-\(index)"], pair.1)
    }
    XCTAssertEqual(
      snapshot.lanes.first { $0.state == .blocked }?.blockers.map(\.code),
      ["goal_blocked"])
    XCTAssertEqual(
      snapshot.lanes.first { $0.state == .rollbackRequired }?.blockers.map(\.code),
      ["rollback_required"])
    XCTAssertEqual(
      snapshot.lanes.first { $0.state == .superseded }?.blockers,
      [])
  }

  func testSupersededPredecessorDoesNotProjectHistoricalFailedDispatchAsBlocker() {
    let goal = makeGoal(
      suffix: "superseded-history",
      status: .superseded,
      updatedAt: date(200))
    let run = TatwoStoredDispatchRun(
      contractID: goal.contractID,
      records: [
        makeDispatch(
          id: "failed-before-revision",
          contractID: goal.contractID,
          bindingID: "old-worker",
          identity: .sub,
          status: .failed,
          updatedAt: date(150),
          errorMessage: "historical failure")
      ],
      updatedAt: date(150))

    let lane = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [goal],
      dispatchRuns: [run],
      observedAt: date(300)
    ).lanes[0]

    XCTAssertEqual(lane.state, .superseded)
    XCTAssertEqual(lane.blockers, [])
    XCTAssertEqual(lane.cost.dispatchAttemptCount, 1)
    XCTAssertEqual(lane.cost.activeDispatchCount, 0)
    XCTAssertEqual(lane.identityGroups.first?.failedWorkerCount, 1)
  }

  func testSupersededPredecessorZeroesActiveProjectionButPreservesHistory() {
    let goal = makeGoal(
      suffix: "superseded-active-history",
      status: .superseded,
      updatedAt: date(200))
    let run = TatwoStoredDispatchRun(
      contractID: goal.contractID,
      records: [
        makeDispatch(
          id: "queued-before-revision",
          contractID: goal.contractID,
          bindingID: "old-sub",
          identity: .sub,
          status: .queued,
          updatedAt: date(140)),
        makeDispatch(
          id: "running-before-revision",
          contractID: goal.contractID,
          bindingID: "old-verifier",
          identity: .verifier,
          status: .running,
          updatedAt: date(150)),
      ],
      updatedAt: date(150))

    let lane = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [goal],
      dispatchRuns: [run],
      observedAt: date(300)
    ).lanes[0]

    XCTAssertEqual(lane.state, .superseded)
    XCTAssertEqual(lane.cost.dispatchAttemptCount, 2)
    XCTAssertEqual(lane.cost.activeDispatchCount, 0)
    XCTAssertEqual(lane.identityGroups.map(\.workerCount), [1, 1])
    XCTAssertEqual(lane.identityGroups.map(\.activeWorkerCount), [0, 0])
    XCTAssertEqual(lane.blockers, [])
  }

  func testLegacyDispatchFinalizedSucceededProjectsAsHumanGateNotPassed() {
    let legacy = makeGoal(
      suffix: "legacy-finalized",
      status: .succeeded,
      statusReason: "dispatch_set_finalized:2:dispatch-seal-legacy")
    let unrelatedSucceeded = makeGoal(
      suffix: "unrelated-succeeded",
      status: .succeeded,
      statusReason: "legacy_terminal_success")

    let states = Dictionary(
      uniqueKeysWithValues: TatwoGoalRunLaneAggregator.aggregate(
        goalRecords: [legacy, unrelatedSucceeded],
        dispatchRuns: [],
        observedAt: date(100)
      ).lanes.map { ($0.contractID, $0.state) })

    XCTAssertEqual(states[legacy.contractID], .humanGate)
    XCTAssertNotEqual(states[legacy.contractID], .passed)
    XCTAssertEqual(states[unrelatedSucceeded.contractID], .passed)
  }

  func testGoalReceiptIsProjectedWhenDispatchDataIsMissing() {
    let goal = makeGoal(
      status: .planned,
      updatedAt: date(50),
      receipts: [
        TatwoStoredReceipt(
          receiptID: "older",
          kind: "plan",
          submittedAt: date(10)),
        TatwoStoredReceipt(
          receiptID: "newer",
          kind: "scope",
          submittedAt: date(40)),
      ])

    let lane = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [goal],
      dispatchRuns: [],
      observedAt: date(60)
    ).lanes[0]

    XCTAssertTrue(lane.identityGroups.isEmpty)
    XCTAssertEqual(lane.cost.dispatchAttemptCount, 0)
    XCTAssertEqual(lane.latestReceipt?.receiptID, "newer")
    XCTAssertEqual(lane.latestReceipt?.kind, "scope")
    XCTAssertEqual(lane.latestReceipt?.source, .goal)
  }

  func testOrphanDispatchDoesNotMasqueradeAsGoalLane() {
    let orphan = TatwoStoredDispatchRun(
      contractID: "orphan-contract",
      records: [
        makeDispatch(
          id: "orphan",
          contractID: "orphan-contract",
          bindingID: "worker",
          identity: .sub,
          status: .running,
          updatedAt: date(10))
      ],
      updatedAt: date(10))

    let snapshot = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [],
      dispatchRuns: [orphan],
      observedAt: date(20))

    XCTAssertEqual(snapshot.lanes, [])
    XCTAssertEqual(snapshot.unboundDispatchContractIDs, ["orphan-contract"])
  }

  func testDuplicateGoalContractUsesNewestRecordAndLaneOrderIsDeterministic() {
    let stale = makeGoal(
      suffix: "a",
      contractID: "shared-contract",
      objective: "stale",
      status: .planned,
      updatedAt: date(10))
    let fresh = makeGoal(
      suffix: "b",
      contractID: "shared-contract",
      objective: "fresh",
      status: .running,
      updatedAt: date(20))
    let other = makeGoal(
      suffix: "c",
      contractID: "other-contract",
      objective: "other",
      status: .planned,
      updatedAt: date(20))

    let lanes = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [stale, other, fresh],
      dispatchRuns: [],
      observedAt: date(30)
    ).lanes

    XCTAssertEqual(lanes.count, 2)
    XCTAssertEqual(lanes.map(\.contractID), ["other-contract", "shared-contract"])
    XCTAssertEqual(lanes.last?.goalID, fresh.goalID)
    XCTAssertEqual(lanes.last?.title, "fresh")
  }

  func testEmptyInputReturnsEmptyCodableSendableSnapshot() throws {
    let snapshot = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [],
      dispatchRuns: [],
      observedAt: date(999))

    XCTAssertEqual(snapshot.schema, "TatwoGoalRunLaneSnapshotV1")
    XCTAssertEqual(snapshot.observedAt, date(999))
    XCTAssertEqual(snapshot.lanes, [])
    XCTAssertEqual(snapshot.unboundDispatchContractIDs, [])

    let decoded = try JSONDecoder().decode(
      TatwoGoalRunLaneSnapshotV1.self,
      from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(decoded, snapshot)
    assertSendable(decoded)
  }

  func testBlankContractsAreSkippedAndBlankBindingFallsBackToDispatchID() {
    let invalidGoal = makeGoal(
      suffix: "invalid",
      contractID: "   ",
      status: .running)
    let validGoal = makeGoal(
      suffix: "valid",
      contractID: "valid-contract",
      status: .running)
    let validRun = TatwoStoredDispatchRun(
      contractID: validGoal.contractID,
      records: [
        makeDispatch(
          id: "dispatch-without-binding",
          contractID: validGoal.contractID,
          bindingID: "",
          identity: .sub,
          status: .failed,
          updatedAt: date(10))
      ],
      updatedAt: date(10))
    let blankRun = TatwoStoredDispatchRun(
      contractID: " ",
      updatedAt: date(20))

    let snapshot = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [invalidGoal, validGoal],
      dispatchRuns: [blankRun, validRun],
      observedAt: date(30))

    XCTAssertEqual(snapshot.lanes.map(\.contractID), ["valid-contract"])
    XCTAssertEqual(snapshot.lanes[0].blockers.map(\.sourceID), ["dispatch-without-binding"])
    XCTAssertEqual(snapshot.unboundDispatchContractIDs, [])
  }

  func testMissingCatalogBudgetDegradesToNilWithoutLosingCostCounts() {
    let goal = makeGoal(status: .running, mode: .xxl)
    let run = TatwoStoredDispatchRun(
      contractID: goal.contractID,
      records: [
        makeDispatch(
          id: "dispatch",
          contractID: goal.contractID,
          bindingID: "worker",
          identity: .sub,
          status: .queued,
          updatedAt: date(10))
      ],
      updatedAt: date(10))
    let emptyCatalog = TatwoCatalog(
      usageProviders: [],
      workModes: [],
      scenarios: [],
      compatibility: [],
      plugins: [])

    let cost = TatwoGoalRunLaneAggregator.aggregate(
      goalRecords: [goal],
      dispatchRuns: [run],
      catalog: emptyCatalog,
      observedAt: date(20)
    ).lanes[0].cost

    XCTAssertNil(cost.budgetLabel)
    XCTAssertEqual(cost.mode, .xxl)
    XCTAssertEqual(cost.dispatchAttemptCount, 1)
    XCTAssertEqual(cost.activeDispatchCount, 1)
  }

  private func makeGoal(
    suffix: String = "1",
    contractID: String? = nil,
    objective: String? = nil,
    status: GoalRunStatus,
    statusReason: String? = nil,
    mode: WorkModeID = .m,
    updatedAt: Date = Date(timeIntervalSince1970: 90),
    receipts: [TatwoStoredReceipt] = []
  ) -> TatwoStoredGoalRun {
    TatwoStoredGoalRun(
      goalID: "goal-\(suffix)",
      contractID: contractID ?? "contract-\(suffix)",
      mode: mode,
      scenario: "coding",
      objective: objective ?? "Goal \(suffix)",
      status: status,
      statusReason: statusReason,
      issuedAt: date(1),
      updatedAt: updatedAt,
      receipts: receipts)
  }

  private func makeDispatch(
    id: String,
    contractID: String,
    bindingID: String,
    identity: IdentityKind,
    modelID: String = "gpt-5.6-sol",
    status: TatwoDispatchStatus,
    updatedAt: Date,
    receiptID: String? = nil,
    errorMessage: String? = nil
  ) -> TatwoDispatchRecord {
    TatwoDispatchRecord(
      id: id,
      contractID: contractID,
      bindingID: bindingID,
      sourceSlotID: "slot-\(bindingID)",
      identity: identity,
      modelID: modelID,
      subtask: "task",
      status: status,
      startedAt: date(1),
      updatedAt: updatedAt,
      receiptID: receiptID,
      errorMessage: errorMessage)
  }

  private func date(_ seconds: Double) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
  }
}
