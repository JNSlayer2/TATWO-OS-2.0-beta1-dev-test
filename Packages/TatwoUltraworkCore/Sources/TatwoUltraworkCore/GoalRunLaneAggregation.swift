import Foundation

public enum TatwoGoalRunLaneStateV1: String, Codable, Sendable, CaseIterable, Equatable {
  case planned
  case waitingDependency = "waiting_dependency"
  case ready
  case running
  case humanGate = "human_gate"
  case blocked
  case superseded
  case passed
  case rollbackRequired = "rollback_required"

  init(goalStatus: GoalRunStatus, statusReason: String? = nil) {
    if goalStatus == .succeeded,
      statusReason?.hasPrefix(TatwoStoredGoalRun.dispatchSetFinalizedReasonPrefix) == true
    {
      self = .humanGate
      return
    }
    switch goalStatus {
    case .planned: self = .planned
    case .dispatching: self = .ready
    case .running: self = .running
    case .succeeded: self = .passed
    case .failed, .cancelled: self = .blocked
    case .superseded: self = .superseded
    case .humanGate: self = .humanGate
    case .awaitingNextCycle: self = .ready
    case .blocked: self = .blocked
    case .passed: self = .passed
    case .rollbackRequired: self = .rollbackRequired
    }
  }
}

public enum TatwoGoalRunLaneReceiptSourceV1: String, Codable, Sendable, CaseIterable, Equatable {
  case goal
  case dispatch
}

public struct TatwoGoalRunLaneReceiptV1: Codable, Sendable, Equatable {
  public let receiptID: String
  public let kind: String
  public let source: TatwoGoalRunLaneReceiptSourceV1
  public let sourceID: String
  public let observedAt: Date

  public init(
    receiptID: String,
    kind: String,
    source: TatwoGoalRunLaneReceiptSourceV1,
    sourceID: String,
    observedAt: Date
  ) {
    self.receiptID = receiptID
    self.kind = kind
    self.source = source
    self.sourceID = sourceID
    self.observedAt = observedAt
  }
}

public enum TatwoGoalRunLaneBlockerSourceV1: String, Codable, Sendable, CaseIterable, Equatable {
  case goal
  case dispatch
}

public struct TatwoGoalRunLaneBlockerV1: Codable, Sendable, Equatable {
  public let code: String
  public let source: TatwoGoalRunLaneBlockerSourceV1
  public let sourceID: String
  public let identity: IdentityKind?
  public let observedAt: Date

  public init(
    code: String,
    source: TatwoGoalRunLaneBlockerSourceV1,
    sourceID: String,
    identity: IdentityKind?,
    observedAt: Date
  ) {
    self.code = code
    self.source = source
    self.sourceID = sourceID
    self.identity = identity
    self.observedAt = observedAt
  }
}

public struct TatwoGoalRunLaneIdentityGroupV1: Codable, Sendable, Equatable {
  public let identity: IdentityKind
  public let workerCount: Int
  public let activeWorkerCount: Int
  public let failedWorkerCount: Int
  public let dispatchAttemptCount: Int
  public let modelIDs: [String]
  public let latestStatus: TatwoDispatchStatus
  public let updatedAt: Date

  public init(
    identity: IdentityKind,
    workerCount: Int,
    activeWorkerCount: Int,
    failedWorkerCount: Int,
    dispatchAttemptCount: Int,
    modelIDs: [String],
    latestStatus: TatwoDispatchStatus,
    updatedAt: Date
  ) {
    self.identity = identity
    self.workerCount = max(0, workerCount)
    self.activeWorkerCount = max(0, activeWorkerCount)
    self.failedWorkerCount = max(0, failedWorkerCount)
    self.dispatchAttemptCount = max(0, dispatchAttemptCount)
    self.modelIDs = Array(Set(modelIDs.filter { !$0.isEmpty })).sorted()
    self.latestStatus = latestStatus
    self.updatedAt = updatedAt
  }
}

public struct TatwoGoalRunLaneCostV1: Codable, Sendable, Equatable {
  public let mode: WorkModeID
  public let budgetLabel: String?
  public let dispatchAttemptCount: Int
  public let activeDispatchCount: Int
  public let distinctModelCount: Int

  public init(
    mode: WorkModeID,
    budgetLabel: String?,
    dispatchAttemptCount: Int,
    activeDispatchCount: Int,
    distinctModelCount: Int
  ) {
    self.mode = mode
    self.budgetLabel = budgetLabel
    self.dispatchAttemptCount = max(0, dispatchAttemptCount)
    self.activeDispatchCount = max(0, activeDispatchCount)
    self.distinctModelCount = max(0, distinctModelCount)
  }
}

public struct TatwoGoalRunLaneV1: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let goalID: String
  public let contractID: String
  public let title: String
  public let mode: WorkModeID
  public let scenario: String
  public let state: TatwoGoalRunLaneStateV1
  public let identityGroups: [TatwoGoalRunLaneIdentityGroupV1]
  public let cost: TatwoGoalRunLaneCostV1
  public let blockers: [TatwoGoalRunLaneBlockerV1]
  public let latestReceipt: TatwoGoalRunLaneReceiptV1?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    id: String,
    goalID: String,
    contractID: String,
    title: String,
    mode: WorkModeID,
    scenario: String,
    state: TatwoGoalRunLaneStateV1,
    identityGroups: [TatwoGoalRunLaneIdentityGroupV1],
    cost: TatwoGoalRunLaneCostV1,
    blockers: [TatwoGoalRunLaneBlockerV1],
    latestReceipt: TatwoGoalRunLaneReceiptV1?,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.goalID = goalID
    self.contractID = contractID
    self.title = title
    self.mode = mode
    self.scenario = scenario
    self.state = state
    self.identityGroups = identityGroups
    self.cost = cost
    self.blockers = blockers
    self.latestReceipt = latestReceipt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct TatwoGoalRunLaneSnapshotV1: Codable, Sendable, Equatable {
  public let schema: String
  public let observedAt: Date
  public let lanes: [TatwoGoalRunLaneV1]
  public let unboundDispatchContractIDs: [String]

  public init(
    schema: String = "TatwoGoalRunLaneSnapshotV1",
    observedAt: Date,
    lanes: [TatwoGoalRunLaneV1],
    unboundDispatchContractIDs: [String]
  ) {
    self.schema = schema
    self.observedAt = observedAt
    self.lanes = lanes
    self.unboundDispatchContractIDs = unboundDispatchContractIDs
  }
}

public enum TatwoGoalRunLaneAggregator {
  /// Read-only join of stored GoalRun truth with dispatch observations.
  ///
  /// One lane is emitted per valid GoalRun contract. Dispatch-only contracts are reported
  /// as unbound activity and never promoted into GoalRun lanes. No store, scheduler, gateway,
  /// process, clock, or other side effect is consulted.
  public static func aggregate(
    goalRecords: [TatwoStoredGoalRun],
    dispatchRuns: [TatwoStoredDispatchRun],
    catalog: TatwoCatalog = .defaults,
    observedAt: Date
  ) -> TatwoGoalRunLaneSnapshotV1 {
    let goalsByContract = newestGoalsByContract(goalRecords)
    let dispatchesByContract = groupedDispatchRuns(dispatchRuns)

    let lanes = goalsByContract.values.map { goal in
      makeLane(
        goal: goal,
        dispatchGroup: dispatchesByContract[goal.contractID],
        catalog: catalog)
    }
    .sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.contractID < $1.contractID
    }

    let unbound = Set(dispatchesByContract.keys)
      .subtracting(goalsByContract.keys)
      .sorted()

    return TatwoGoalRunLaneSnapshotV1(
      observedAt: observedAt,
      lanes: lanes,
      unboundDispatchContractIDs: unbound)
  }

  private struct DispatchGroup {
    var records: [TatwoDispatchRecord] = []
    var updatedAt: Date?
  }

  private static func newestGoalsByContract(
    _ records: [TatwoStoredGoalRun]
  ) -> [String: TatwoStoredGoalRun] {
    var result: [String: TatwoStoredGoalRun] = [:]
    for record in records {
      let contractID = record.contractID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !contractID.isEmpty else { continue }
      guard let existing = result[contractID] else {
        result[contractID] = record
        continue
      }
      if record.updatedAt > existing.updatedAt
        || (record.updatedAt == existing.updatedAt && record.goalID < existing.goalID)
      {
        result[contractID] = record
      }
    }
    return result
  }

  private static func groupedDispatchRuns(
    _ runs: [TatwoStoredDispatchRun]
  ) -> [String: DispatchGroup] {
    var result: [String: DispatchGroup] = [:]
    for run in runs {
      let contractID = run.contractID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !contractID.isEmpty else { continue }
      var group = result[contractID] ?? DispatchGroup()
      group.records.append(contentsOf: run.records)
      group.updatedAt = max(group.updatedAt ?? run.updatedAt, run.updatedAt)
      result[contractID] = group
    }
    return result
  }

  private static func makeLane(
    goal: TatwoStoredGoalRun,
    dispatchGroup: DispatchGroup?,
    catalog: TatwoCatalog
  ) -> TatwoGoalRunLaneV1 {
    let records = dispatchGroup?.records ?? []
    let latestWorkers = latestRecordsByBinding(records)
    let state = TatwoGoalRunLaneStateV1(
      goalStatus: goal.status,
      statusReason: goal.statusReason)
    let identityGroups = makeIdentityGroups(
      allRecords: records,
      latestWorkers: latestWorkers,
      isSuperseded: state == .superseded)
    let blockers = makeBlockers(
      goal: goal,
      state: state,
      latestWorkers: latestWorkers)
    let latestReceipt = makeLatestReceipt(goal: goal, dispatchRecords: records)
    let activeCount =
      state == .superseded
      ? 0
      : latestWorkers.filter { isActive($0.status) }.count
    let modelCount = Set(records.map(\.modelID).filter { !$0.isEmpty }).count
    let updatedAt =
      ([goal.updatedAt]
      + [dispatchGroup?.updatedAt].compactMap { $0 }
      + records.map(\.updatedAt)
      + goal.receipts.map(\.submittedAt)).max() ?? goal.updatedAt

    return TatwoGoalRunLaneV1(
      id: goal.goalID,
      goalID: goal.goalID,
      contractID: goal.contractID,
      title: goal.objective,
      mode: goal.mode,
      scenario: goal.scenario,
      state: state,
      identityGroups: identityGroups,
      cost: TatwoGoalRunLaneCostV1(
        mode: goal.mode,
        budgetLabel: catalog.mode(goal.mode)?.defaultBudget.tokenRangeLabel,
        dispatchAttemptCount: records.count,
        activeDispatchCount: activeCount,
        distinctModelCount: modelCount),
      blockers: blockers,
      latestReceipt: latestReceipt,
      createdAt: goal.issuedAt,
      updatedAt: updatedAt)
  }

  private static func latestRecordsByBinding(
    _ records: [TatwoDispatchRecord]
  ) -> [TatwoDispatchRecord] {
    var latest: [String: TatwoDispatchRecord] = [:]
    for record in records {
      let trimmedBinding = record.bindingID.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = trimmedBinding.isEmpty ? record.id : trimmedBinding
      guard let existing = latest[key] else {
        latest[key] = record
        continue
      }
      if record.updatedAt > existing.updatedAt
        || (record.updatedAt == existing.updatedAt && record.id < existing.id)
      {
        latest[key] = record
      }
    }
    return latest.values.sorted {
      if $0.identity != $1.identity { return $0.identity < $1.identity }
      if $0.bindingID != $1.bindingID { return $0.bindingID < $1.bindingID }
      return $0.id < $1.id
    }
  }

  private static func makeIdentityGroups(
    allRecords: [TatwoDispatchRecord],
    latestWorkers: [TatwoDispatchRecord],
    isSuperseded: Bool
  ) -> [TatwoGoalRunLaneIdentityGroupV1] {
    Dictionary(grouping: latestWorkers, by: \.identity)
      .compactMap { identity, workers in
        guard let newest = workers.max(by: dispatchRecordIsOlder) else { return nil }
        return TatwoGoalRunLaneIdentityGroupV1(
          identity: identity,
          workerCount: workers.count,
          activeWorkerCount:
            isSuperseded ? 0 : workers.filter { isActive($0.status) }.count,
          failedWorkerCount: workers.filter { $0.status == .failed }.count,
          dispatchAttemptCount: allRecords.filter { $0.identity == identity }.count,
          modelIDs: workers.map(\.modelID),
          latestStatus: newest.status,
          updatedAt: newest.updatedAt)
      }
      .sorted { $0.identity < $1.identity }
  }

  private static func makeBlockers(
    goal: TatwoStoredGoalRun,
    state: TatwoGoalRunLaneStateV1,
    latestWorkers: [TatwoDispatchRecord]
  ) -> [TatwoGoalRunLaneBlockerV1] {
    var blockers: [TatwoGoalRunLaneBlockerV1] = []
    if state == .blocked {
      blockers.append(
        TatwoGoalRunLaneBlockerV1(
          code: "goal_blocked",
          source: .goal,
          sourceID: goal.goalID,
          identity: nil,
          observedAt: goal.updatedAt))
    } else if state == .rollbackRequired {
      blockers.append(
        TatwoGoalRunLaneBlockerV1(
          code: "rollback_required",
          source: .goal,
          sourceID: goal.goalID,
          identity: nil,
          observedAt: goal.updatedAt))
    }

    if state != .superseded {
      blockers.append(
        contentsOf:
          latestWorkers
          .filter { $0.status == .failed }
          .map {
            TatwoGoalRunLaneBlockerV1(
              code: "dispatch_failed",
              source: .dispatch,
              sourceID: $0.bindingID.isEmpty ? $0.id : $0.bindingID,
              identity: $0.identity,
              observedAt: $0.updatedAt)
          })
    }

    return blockers.sorted {
      if $0.source != $1.source { return $0.source == .goal }
      if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
      return $0.sourceID < $1.sourceID
    }
  }

  private static func makeLatestReceipt(
    goal: TatwoStoredGoalRun,
    dispatchRecords: [TatwoDispatchRecord]
  ) -> TatwoGoalRunLaneReceiptV1? {
    let goalReceipts = goal.receipts.compactMap { receipt -> TatwoGoalRunLaneReceiptV1? in
      let receiptID = receipt.receiptID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !receiptID.isEmpty else { return nil }
      return TatwoGoalRunLaneReceiptV1(
        receiptID: receiptID,
        kind: receipt.kind,
        source: .goal,
        sourceID: goal.goalID,
        observedAt: receipt.submittedAt)
    }
    let dispatchReceipts = dispatchRecords.compactMap {
      record -> TatwoGoalRunLaneReceiptV1? in
      guard
        let receiptID = record.receiptID?.trimmingCharacters(in: .whitespacesAndNewlines),
        !receiptID.isEmpty
      else { return nil }
      return TatwoGoalRunLaneReceiptV1(
        receiptID: receiptID,
        kind: "dispatch",
        source: .dispatch,
        sourceID: record.bindingID.isEmpty ? record.id : record.bindingID,
        observedAt: record.updatedAt)
    }
    return (goalReceipts + dispatchReceipts).sorted {
      if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
      if $0.source != $1.source { return $0.source == .goal }
      return $0.receiptID < $1.receiptID
    }.first
  }

  private static func isActive(_ status: TatwoDispatchStatus) -> Bool {
    status == .queued || status == .running
  }

  private static func dispatchRecordIsOlder(
    _ lhs: TatwoDispatchRecord,
    _ rhs: TatwoDispatchRecord
  ) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
    return lhs.id > rhs.id
  }
}
