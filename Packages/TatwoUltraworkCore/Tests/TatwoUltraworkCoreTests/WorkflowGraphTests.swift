import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class WorkflowGraphTests: XCTestCase {
  private let goalHash = "goal-hash-aaa"
  private let planHash = "plan-hash-bbb"

  // MARK: Load validation (fail closed)

  func testLoadRejectsCycle() {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("a", title: "A"),
        node("b", title: "B"),
        node("c", title: "C"),
      ],
      edges: [
        edge("e1", from: "a", to: "b", .afterSuccess),
        edge("e2", from: "b", to: "c", .afterSuccess),
        edge("e3", from: "c", to: "a", .afterSuccess),
      ])

    XCTAssertThrowsError(try WorkflowGraphLoaderV1.load(revision)) { error in
      XCTAssertEqual(error as? WorkflowGraphLoadErrorV1, .cycleDetected)
    }
  }

  func testLoadRejectsDanglingEdge() {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [node("a", title: "A")],
      edges: [edge("e1", from: "a", to: "missing", .afterCompletion)])

    XCTAssertThrowsError(try WorkflowGraphLoaderV1.load(revision)) { error in
      XCTAssertEqual(
        error as? WorkflowGraphLoadErrorV1,
        .danglingEdge(edgeID: "e1", endpoint: "to", nodeID: "missing"))
    }
  }

  func testLoadRejectsDanglingFromEdge() {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [node("b", title: "B")],
      edges: [edge("e1", from: "ghost", to: "b", .afterCompletion)])

    XCTAssertThrowsError(try WorkflowGraphLoaderV1.load(revision)) { error in
      XCTAssertEqual(
        error as? WorkflowGraphLoadErrorV1,
        .danglingEdge(edgeID: "e1", endpoint: "from", nodeID: "ghost"))
    }
  }

  func testLoadRejectsDuplicateNodeID() {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("dup", title: "One"),
        node("dup", title: "Two"),
      ],
      edges: [])

    XCTAssertThrowsError(try WorkflowGraphLoaderV1.load(revision)) { error in
      XCTAssertEqual(error as? WorkflowGraphLoadErrorV1, .duplicateNodeID("dup"))
    }
  }

  func testLoadAcceptsDAGAndBindsHashes() throws {
    let loaded = try WorkflowGraphLoaderV1.load(sampleLinearRevision())
    XCTAssertEqual(loaded.goalHash, goalHash)
    XCTAssertEqual(loaded.planHash, planHash)
    XCTAssertEqual(loaded.topologicalOrder, ["build", "review", "ship"])
  }

  // MARK: Ready-set correctness

  func testReadyRootsWhenNoIncomingAndNotStarted() throws {
    let graph = try WorkflowGraphLoaderV1.load(sampleLinearRevision())
    let state = baseState()
    let readyIDs = WorkflowGraphSchedulerV1.ready(graph: graph, state: state).map(\.id)
    XCTAssertEqual(readyIDs, ["build"])
  }

  func testReadyRequiresAllPredecessorsForJoin() throws {
    // fan-in: ship waits for both left (afterSuccess) and right (afterSuccess)
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("left", title: "Left"),
        node("right", title: "Right"),
        node("ship", kind: .join, title: "Ship"),
      ],
      edges: [
        edge("eL", from: "left", to: "ship", .afterSuccess),
        edge("eR", from: "right", to: "ship", .afterSuccess),
      ])
    let graph = try WorkflowGraphLoaderV1.load(revision)

    var state = baseState(statuses: ["left": .succeeded])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: state).map(\.id),
      ["right"])

    state = baseState(statuses: [
      "left": .succeeded,
      "right": .succeeded,
    ])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: state).map(\.id),
      ["ship"])
  }

  func testAfterSuccessVsAfterCompletion() throws {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("work", title: "Work"),
        node("onDone", title: "On any terminal"),
        node("onOK", title: "On success only"),
      ],
      edges: [
        edge("eDone", from: "work", to: "onDone", .afterCompletion),
        edge("eOK", from: "work", to: "onOK", .afterSuccess),
      ])
    let graph = try WorkflowGraphLoaderV1.load(revision)

    // blocked is terminal but not success
    let blockedState = baseState(statuses: ["work": .blocked])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: blockedState).map(\.id),
      ["onDone"])

    let okState = baseState(statuses: ["work": .succeeded])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: okState).map(\.id),
      ["onDone", "onOK"])
  }

  func testOnFailureBranch() throws {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("work", title: "Work"),
        node("recover", title: "Recover"),
        node("continue", title: "Continue"),
      ],
      edges: [
        edge("eFail", from: "work", to: "recover", .onFailure),
        edge("eOK", from: "work", to: "continue", .afterSuccess),
      ])
    let graph = try WorkflowGraphLoaderV1.load(revision)

    let failed = baseState(statuses: ["work": .failed])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: failed).map(\.id),
      ["recover"])

    let ok = baseState(statuses: ["work": .succeeded])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: ok).map(\.id),
      ["continue"])
  }

  func testOnReceiptConditionUsesVerifiedReceiptsOnly() throws {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("probe", title: "Probe"),
        node("promote", title: "Promote", requiredReceipts: ["build-receipt"]),
      ],
      edges: [
        edge("eR", from: "probe", to: "promote", .onReceipt("build-receipt")),
      ])
    let graph = try WorkflowGraphLoaderV1.load(revision)

    // Predecessor finished but receipt not verified → not ready
    let noReceipt = baseState(statuses: ["probe": .succeeded])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: noReceipt).map(\.id),
      [])

    let withReceipt = WorkflowGraphRecordedStateV1(
      goalHash: goalHash,
      planHash: planHash,
      nodeStatuses: ["probe": .succeeded],
      verifiedReceipts: ["build-receipt"])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: withReceipt).map(\.id),
      ["promote"])
  }

  func testHumanGateNotPassedKeepsNodeOutOfReady() throws {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("ask", title: "Ask human", humanGate: true),
        node("after", title: "After gate"),
      ],
      edges: [
        edge("e1", from: "ask", to: "after", .afterSuccess),
      ])
    let graph = try WorkflowGraphLoaderV1.load(revision)

    let locked = baseState()
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: locked).map(\.id),
      [],
      "humanGate node must not be ready until gate is recorded as passed")

    let unlocked = WorkflowGraphRecordedStateV1(
      goalHash: goalHash,
      planHash: planHash,
      humanGatesPassed: ["ask"])
    XCTAssertEqual(
      WorkflowGraphSchedulerV1.ready(graph: graph, state: unlocked).map(\.id),
      ["ask"])
  }

  func testStartedNodesAreExcludedFromReady() throws {
    let graph = try WorkflowGraphLoaderV1.load(sampleLinearRevision())
    let state = baseState(statuses: ["build": .running])
    XCTAssertEqual(WorkflowGraphSchedulerV1.ready(graph: graph, state: state).map(\.id), [])
  }

  // MARK: Determinism

  func testReadyOrderIsDeterministicAcrossRepeatedCalls() throws {
    let revision = WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node("zulu", title: "Z"),
        node("alpha", title: "A"),
        node("mike", title: "M"),
      ],
      edges: [])
    let graph = try WorkflowGraphLoaderV1.load(revision)
    let state = baseState()

    let first = WorkflowGraphSchedulerV1.ready(graph: graph, state: state).map(\.id)
    let second = WorkflowGraphSchedulerV1.ready(graph: graph, state: state).map(\.id)
    XCTAssertEqual(first, ["alpha", "mike", "zulu"])
    XCTAssertEqual(first, second)

    let sim = WorkflowGraphSimulatorV1(graph: graph)
    let third = try sim.ready(state: state).map(\.id)
    let fourth = try sim.ready(state: state).map(\.id)
    XCTAssertEqual(third, first)
    XCTAssertEqual(fourth, first)
  }

  // MARK: Simulator + staleness + structural isolation

  func testSimulatorEmitsProposalsNotDispatches() throws {
    let graph = try WorkflowGraphLoaderV1.load(sampleLinearRevision())
    let sim = WorkflowGraphSimulatorV1(graph: graph)
    let proposals = try sim.readyProposals(state: baseState())
    XCTAssertEqual(proposals.count, 1)
    XCTAssertEqual(proposals[0].nodeID, "build")
    XCTAssertEqual(proposals[0].proposal?.intent, "implement change")
    // Ready proposal type has no dispatch surface fields — only ordering proposal data.
    XCTAssertEqual(proposals[0].title, "Build")
  }

  func testSimulatorRejectsStaleGoalOrPlanHash() throws {
    let graph = try WorkflowGraphLoaderV1.load(sampleLinearRevision())
    let sim = WorkflowGraphSimulatorV1(graph: graph)

    XCTAssertThrowsError(
      try sim.ready(state: WorkflowGraphRecordedStateV1(
        goalHash: "other-goal",
        planHash: planHash))
    ) { error in
      XCTAssertEqual(
        error as? WorkflowGraphStaleErrorV1,
        .goalHashMismatch(graph: goalHash, state: "other-goal"))
    }

    XCTAssertThrowsError(
      try sim.ready(state: WorkflowGraphRecordedStateV1(
        goalHash: goalHash,
        planHash: "other-plan"))
    ) { error in
      XCTAssertEqual(
        error as? WorkflowGraphStaleErrorV1,
        .planHashMismatch(graph: planHash, state: "other-plan"))
    }
  }

  func testStructuralIsolationSimulatorSourceHasNoDispatchSurface() throws {
    // Structural isolation is compile-time: WorkflowGraphSimulatorV1 has no
    // initializer or stored property for production dispatch/registry/channel/trust.
    // Runtime evidence: module source has no identifier references to those types,
    // and Mirror shows only the loaded graph + empty capability product.
    let sourceURL = workflowGraphSourceURL()
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let codeOnly = stripSwiftComments(source)

    let forbiddenTypeTokens = [
      "TatwoDispatchRegistry",
      "RemoteLoopJobChannel",
      "TatwoDeviceTrust",
      "TatwoDeviceTrustPinStore",
      "RemoteLoopProductionRunner",
    ]
    for token in forbiddenTypeTokens {
      XCTAssertFalse(
        codeOnly.contains(token),
        "WorkflowGraph.swift must not reference production type \(token)")
    }
    XCTAssertFalse(codeOnly.contains("func dispatch("))
    XCTAssertFalse(codeOnly.contains("func startDispatch("))
    XCTAssertFalse(codeOnly.contains("func acquireLease("))

    // Positive surface: simulator only takes loaded graph + recorded state.
    XCTAssertTrue(source.contains("struct WorkflowGraphSimulatorV1"))
    XCTAssertTrue(source.contains("struct WorkflowGraphNoDispatchCapabilityV1"))
    XCTAssertTrue(source.contains("WorkflowGraphRecordedStateV1"))
    XCTAssertTrue(
      source.contains("Constructing this type with live production objects is not expressible"))

    let sim = WorkflowGraphSimulatorV1(
      graph: try WorkflowGraphLoaderV1.load(sampleLinearRevision()))
    XCTAssertEqual(sim.noDispatchCapability, WorkflowGraphNoDispatchCapabilityV1())

    // Stored surface: only graph + empty capability (no production handles).
    let storedLabels = Mirror(reflecting: sim).children.compactMap(\.label).sorted()
    XCTAssertEqual(storedLabels, ["capability", "graph"])
    for child in Mirror(reflecting: sim).children {
      let typeName = String(describing: type(of: child.value))
      for token in forbiddenTypeTokens {
        XCTAssertFalse(typeName.contains(token), "stored property type leaked \(token)")
      }
    }

    // Output is proposal sequence, not a registry record type.
    let proposals = try sim.readyProposals(state: baseState())
    XCTAssertTrue(type(of: proposals) == [WorkflowGraphReadyProposalV1].self)

    // Compile-time guarantee (documented): these constructors do not exist.
    // WorkflowGraphSimulatorV1(graph:registry:) — no such overload
    // WorkflowGraphSimulatorV1(dispatch:) — no such overload
    // Passing TatwoDispatchRegistry into ready/readyProposals — no such parameter
  }

  private func stripSwiftComments(_ source: String) -> String {
    var result = ""
    var i = source.startIndex
    while i < source.endIndex {
      if source[i] == "/", source.index(after: i) < source.endIndex {
        let next = source.index(after: i)
        if source[next] == "/" {
          i = source[next...].firstIndex(of: "\n") ?? source.endIndex
          continue
        }
        if source[next] == "*" {
          let after = source.index(next, offsetBy: 1)
          if let end = source[after...].range(of: "*/") {
            i = end.upperBound
            continue
          }
          break
        }
      }
      result.append(source[i])
      i = source.index(after: i)
    }
    return result
  }

  func testConditionEvaluationDoesNotReadNodeOutputFields() throws {
    // Ready-set uses only lifecycle + verifiedReceipts. Fabricating "output"
    // is impossible because RecordedState has no output map — structural.
    let mirror = Mirror(reflecting: baseState())
    let labels = Set(mirror.children.compactMap(\.label))
    XCTAssertEqual(
      labels,
      Set(["goalHash", "planHash", "nodeStatuses", "humanGatesPassed", "verifiedReceipts"]))
    XCTAssertFalse(labels.contains("outputs"))
    XCTAssertFalse(labels.contains("nodeOutputs"))
  }

  // MARK: Production dual-track advisory

  func testRealmPhantomTypesAreDistinct() {
    let production = WorkflowGraphAdvisoryInput<ProductionRealm>()
    let simulation = WorkflowGraphAdvisoryInput<SimulationRealm>()
    XCTAssertNotEqual(
      String(reflecting: type(of: production)),
      String(reflecting: type(of: simulation)))

    let productionPermit = NodeExecutionPermit<ProductionRealm>(
      permitID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      isValid: true,
      issuedAtUnixMilliseconds: 100,
      expiresAtUnixMilliseconds: 200)
    let simulationPermit = NodeExecutionPermit<SimulationRealm>(
      permitID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      isValid: true,
      issuedAtUnixMilliseconds: 100,
      expiresAtUnixMilliseconds: 200)
    XCTAssertNotEqual(
      String(reflecting: type(of: productionPermit)),
      String(reflecting: type(of: simulationPermit)))

    // The following would be a compile-time error by construction:
    // WorkflowGraphAdvisoryEvaluator().evaluate(
    //   WorkflowGraphAdvisoryInput<SimulationRealm>(permit: simulationPermit))
    // A production evaluator has no SimulationRealm overload.
  }

  func testAdvisoryConjunctionDeniesEachCondition() {
    let evaluator = WorkflowGraphAdvisoryEvaluator()
    let cases: [(String, ProductionWorkflowGraphAdvisoryInput)] = [
      (
        WorkflowGraphAdvisoryReason.contractInvalid,
        committedAdvisoryInput(contractValid: false)),
      (
        WorkflowGraphAdvisoryReason.planInvalid,
        committedAdvisoryInput(planValid: false)),
      (
        WorkflowGraphAdvisoryReason.graphNotReady,
        committedAdvisoryInput(graphReady: false)),
      (
        WorkflowGraphAdvisoryReason.gatesNotAccepted,
        committedAdvisoryInput(gatesAccepted: false)),
      (
        WorkflowGraphAdvisoryReason.governorNotGranted,
        committedAdvisoryInput(governorGranted: false)),
      (
        WorkflowGraphAdvisoryReason.permitInvalid,
        committedAdvisoryInput(dispatchPermitValid: false)),
    ]

    for (reason, input) in cases {
      let decision = evaluator.evaluate(input)
      guard case .deny(let reasons) = decision else {
        return XCTFail("expected deny for \(reason)")
      }
      XCTAssertTrue(reasons.contains(reason), "missing reason \(reason)")
    }

    XCTAssertTrue(evaluator.evaluate(committedAdvisoryInput()).isAllowed)
  }

  func testAdvisoryMissingCommittedSourcesAndTimeFailClosed() {
    let evaluator = WorkflowGraphAdvisoryEvaluator()
    let empty = evaluator.evaluate(ProductionWorkflowGraphAdvisoryInput())
    guard case .deny(let emptyReasons) = empty else {
      return XCTFail("missing sources must deny")
    }
    XCTAssertTrue(emptyReasons.contains(WorkflowGraphAdvisoryReason.missingContract))

    let missingTime = evaluator.evaluate(
      committedAdvisoryInput(evaluationTimeUnixMilliseconds: nil))
    guard case .deny(let missingTimeReasons) = missingTime else {
      return XCTFail("missing injected evaluation time must deny")
    }
    XCTAssertTrue(
      missingTimeReasons.contains(WorkflowGraphAdvisoryReason.missingEvaluationTime))

    let missingPermit = evaluator.evaluate(
      ProductionWorkflowGraphAdvisoryInput(
        contract: WorkflowGraphCommittedContract<ProductionRealm>(isValid: true),
        plan: WorkflowGraphCommittedPlan<ProductionRealm>(isValid: true),
        gates: WorkflowGraphCommittedGates<ProductionRealm>(isAccepted: true),
        governor: WorkflowGraphCommittedGovernor<ProductionRealm>(isGranted: true),
        graphReady: true,
        evaluationTimeUnixMilliseconds: 150))
    guard case .deny(let missingPermitReasons) = missingPermit else {
      return XCTFail("missing permit must deny")
    }
    XCTAssertTrue(missingPermitReasons.contains(WorkflowGraphAdvisoryReason.missingPermit))
  }

  func testAdvisoryRejectsUncommittedFactsAndExpiredPermit() {
    let evaluator = WorkflowGraphAdvisoryEvaluator()
    let uncommitted = ProductionWorkflowGraphAdvisoryInput(
      contract: WorkflowGraphCommittedContract<ProductionRealm>(
        isValid: true,
        isCommitted: false),
      plan: WorkflowGraphCommittedPlan<ProductionRealm>(isValid: true),
      gates: WorkflowGraphCommittedGates<ProductionRealm>(isAccepted: true),
      governor: WorkflowGraphCommittedGovernor<ProductionRealm>(isGranted: true),
      permit: NodeExecutionPermit<ProductionRealm>(
        permitID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        isValid: true,
        issuedAtUnixMilliseconds: 100,
        expiresAtUnixMilliseconds: 200),
      graphReady: true,
      evaluationTimeUnixMilliseconds: 150)
    guard case .deny(let uncommittedReasons) = evaluator.evaluate(uncommitted) else {
      return XCTFail("uncommitted contract must deny")
    }
    XCTAssertTrue(
      uncommittedReasons.contains(WorkflowGraphAdvisoryReason.contractNotCommitted))

    let expired = committedAdvisoryInput(evaluationTimeUnixMilliseconds: 200)
    guard case .deny(let expiredReasons) = evaluator.evaluate(expired) else {
      return XCTFail("expired permit must deny")
    }
    XCTAssertTrue(expiredReasons.contains(WorkflowGraphAdvisoryReason.permitExpired))
  }

  func testAdvisorySourceHasNoAmbientInputReaders() throws {
    let sourceURL = workflowGraphAdvisorySourceURL()
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertFalse(source.contains("Date.now"))
    XCTAssertFalse(source.contains("FileManager"))
    XCTAssertFalse(source.contains("Process"))
    XCTAssertFalse(source.contains("stdout"))
    XCTAssertTrue(source.contains("evaluationTimeUnixMilliseconds"))
    XCTAssertTrue(
      source.contains(
        "evaluate(\n    _ input: WorkflowGraphAdvisoryInput<ProductionRealm>"))
    XCTAssertFalse(
      source.contains(
        "evaluate(\n    _ input: WorkflowGraphAdvisoryInput<SimulationRealm>"))
    XCTAssertFalse(source.contains("func dispatch("))
    XCTAssertFalse(source.contains("func startDispatch("))
    XCTAssertFalse(source.contains("func authorize("))
    XCTAssertFalse(source.contains("func issuePermit("))
    XCTAssertFalse(source.contains("func register("))
  }

  func testDivergenceLogRecordsThreeStatesAndCountsGraphLooserSeparately() throws {
    let input = committedAdvisoryInput()
    let allow = WorkflowGraphAdvisoryDecision.allow
    let deny = WorkflowGraphAdvisoryDecision.deny(
      reasons: [WorkflowGraphAdvisoryReason.contractInvalid])
    var log = WorkflowGraphDivergenceLog()

    // actual allow + graph deny = graph stricter
    try log.append(
      observationID: "obs-1",
      actualDecision: .allow,
      advisory: deny,
      input: input,
      sequence: 1,
      recordedAtUnixMilliseconds: 1_001)
    // actual deny + graph allow = graph looser (dangerous direction)
    try log.append(
      observationID: "obs-2",
      actualDecision: .deny,
      advisory: allow,
      input: input,
      sequence: 2,
      recordedAtUnixMilliseconds: 1_002)
    // both allow = agree
    try log.append(
      observationID: "obs-3",
      actualDecision: .allow,
      advisory: allow,
      input: input,
      sequence: 3,
      recordedAtUnixMilliseconds: 1_003)

    XCTAssertEqual(log.entries.map(\.state), [.graphStricter, .graphLooser, .agree])
    XCTAssertEqual(log.entries.map(\.inputDigest), [input.inputDigest, input.inputDigest, input.inputDigest])
    XCTAssertEqual(log.statistics.total, 3)
    XCTAssertEqual(log.statistics.distinctObservationCount, 3)
    XCTAssertEqual(log.statistics.agree, 1)
    XCTAssertEqual(log.statistics.graphStricter, 1)
    XCTAssertEqual(log.statistics.graphLooser, 1)
    XCTAssertEqual(log.statistics.graphLooserCount, 1)
    XCTAssertEqual(log.statistics.dangerousGraphLooserCount, 1)
    XCTAssertEqual(log.graphLooserCount, 1)
    XCTAssertTrue(log.statistics.summary.contains("GRAPH_LOOSER=1"))
  }

  func testDivergenceLogIsAppendOnlyFromPublicSurface() throws {
    let input = committedAdvisoryInput()
    let advisory = WorkflowGraphAdvisoryDecision.allow
    var log = WorkflowGraphDivergenceLog()
    try log.append(
      observationID: "obs-10",
      actualDecision: .allow,
      advisory: advisory,
      input: input,
      sequence: 10,
      recordedAtUnixMilliseconds: 10_000)
    let firstSnapshot = log.entries
    try log.append(
      observationID: "obs-11",
      actualDecision: .deny,
      advisory: advisory,
      input: input,
      sequence: 11,
      recordedAtUnixMilliseconds: 10_001)

    XCTAssertEqual(firstSnapshot.count, 1)
    XCTAssertEqual(log.entries.count, 2)
    XCTAssertEqual(log.entries.map(\.sequence), [10, 11])
    XCTAssertEqual(log.entries[0].sequence, firstSnapshot[0].sequence)
    XCTAssertEqual(log.entries[0].inputDigest, firstSnapshot[0].inputDigest)
  }

  func testDivergenceLogRejectsSequenceDiscontinuity() throws {
    let input = committedAdvisoryInput()
    var log = WorkflowGraphDivergenceLog()
    try log.append(
      observationID: "obs-seq-1",
      actualDecision: .allow,
      advisory: .allow,
      input: input,
      sequence: 10,
      recordedAtUnixMilliseconds: 10_000)

    XCTAssertThrowsError(
      try log.append(
        observationID: "obs-seq-3",
        actualDecision: .allow,
        advisory: .allow,
        input: input,
        sequence: 12,
        recordedAtUnixMilliseconds: 10_002)
    ) { error in
      XCTAssertEqual(
        error as? WorkflowGraphDivergenceLogError,
        .sequenceDiscontinuity(expected: 11, actual: 12))
    }
    XCTAssertEqual(log.entries.map(\.sequence), [10])
  }

  func testDivergenceLogDuplicateObservationIsIdempotentAndDoesNotInflateGraphLooser() throws {
    let input = committedAdvisoryInput()
    var log = WorkflowGraphDivergenceLog()
    let first = try log.append(
      observationID: "obs-replay",
      actualDecision: .deny,
      advisory: .allow,
      input: input,
      sequence: 1,
      recordedAtUnixMilliseconds: 1_000)
    XCTAssertEqual(first, .appended)
    let before = log.statistics

    let replay = try log.append(
      observationID: "obs-replay",
      actualDecision: .deny,
      advisory: .allow,
      input: input,
      sequence: 1,
      recordedAtUnixMilliseconds: 1_000)
    XCTAssertEqual(replay, .alreadyRecorded)
    XCTAssertEqual(log.statistics, before)
    XCTAssertEqual(log.statistics.total, 1)
    XCTAssertEqual(log.statistics.distinctObservationCount, 1)
    XCTAssertEqual(log.statistics.graphLooser, 1)
  }

  func testDivergenceLogRejectsConflictingReplayForSameObservation() throws {
    let input = committedAdvisoryInput()
    var log = WorkflowGraphDivergenceLog()
    try log.append(
      observationID: "obs-conflict",
      actualDecision: .deny,
      advisory: .allow,
      input: input,
      sequence: 1,
      recordedAtUnixMilliseconds: 1_000)

    XCTAssertThrowsError(
      try log.append(
        observationID: "obs-conflict",
        actualDecision: .allow,
        advisory: .allow,
        input: input,
        sequence: 2,
        recordedAtUnixMilliseconds: 1_001)
    ) { error in
      XCTAssertEqual(
        error as? WorkflowGraphDivergenceLogError,
        .observationConflict(observationID: "obs-conflict"))
    }
    XCTAssertEqual(log.statistics.total, 1)
    XCTAssertEqual(log.statistics.graphLooser, 1)
  }

  func testDivergenceLogPublicShapeRequiresEmptyStartAndObservationBinding() throws {
    let sourceURL = workflowGraphAdvisorySourceURL()
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertTrue(source.contains("public init()"))
    XCTAssertTrue(source.contains("init(entries: [WorkflowGraphDivergenceEntry])"))
    XCTAssertFalse(source.contains("public init(entries: [WorkflowGraphDivergenceEntry]"))
    XCTAssertTrue(source.contains("observationID: String"))
    XCTAssertTrue(source.contains("inputDigest: inputDigest"))
  }

  func testPublicDivergenceLogDecodingCannotHydrateArbitraryHistory() throws {
    let input = committedAdvisoryInput()
    let entry = WorkflowGraphDivergenceEntry(
      observationID: "decoded-history",
      sequence: 1,
      recordedAtUnixMilliseconds: 1_000,
      actualDecision: .deny,
      graphAdvisory: .allow,
      inputDigest: input.inputDigest)
    let encoder = JSONEncoder()
    let data = try encoder.encode(
      ["entries": [entry]]
    )
    XCTAssertThrowsError(
      try JSONDecoder().decode(WorkflowGraphDivergenceLog.self, from: data)
    )
  }

  // MARK: Decision journal (step 3 — journal before dispatch, still non-authoritative)

  func testDecisionJournalPendingThenDecidedOrder() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    let pending = try journal.beginPending(
      observationID: "obs-j1",
      input: input,
      sequence: 1)
    XCTAssertEqual(pending, .appended)
    XCTAssertEqual(journal.entries.map(\.phase), [.pending])
    XCTAssertEqual(journal.entries[0].inputDigest, input.inputDigest)
    XCTAssertEqual(
      journal.entries[0].evaluationTimeUnixMilliseconds,
      input.evaluationTimeUnixMilliseconds)
    XCTAssertEqual(
      journal.entries[0].chainDigest,
      WorkflowGraphDecisionJournal.genesisChainDigest)

    let advisory = WorkflowGraphAdvisoryEvaluator().evaluate(input)
    let decided = try journal.recordDecided(
      observationID: "obs-j1",
      advisory: advisory,
      sequence: 2)
    XCTAssertEqual(decided, .appended)
    XCTAssertEqual(journal.entries.map(\.phase), [.pending, .decided])
    XCTAssertEqual(journal.entries[1].chainDigest, journal.entries[0].entryDigest)
    XCTAssertEqual(journal.entries[1].advisoryDecision, advisory)
    XCTAssertFalse(journal.entries[1].reasonsDigest?.isEmpty ?? true)
  }

  func testDecisionJournalEvaluateAndRecordWritesPendingBeforeDecision() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    let decision = try journal.evaluateAndRecord(
      observationID: "obs-eval",
      input: input,
      pendingSequence: 1,
      decidedSequence: 2)
    XCTAssertTrue(decision.isAllowed)
    XCTAssertEqual(journal.entries.map(\.phase), [.pending, .decided])
    XCTAssertEqual(journal.entries.map(\.sequence), [1, 2])
    XCTAssertEqual(journal.entries.map(\.observationID), ["obs-eval", "obs-eval"])
  }

  func testDecisionJournalReplayMarksIncompleteWhenDecidedMissing() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    try journal.beginPending(observationID: "obs-crash", input: input, sequence: 1)
    // Simulate crash after pending — no decided entry.
    let replayed = try journal.replay()
    XCTAssertEqual(replayed.count, 1)
    guard case let .incomplete(observationID, inputDigest) = replayed[0] else {
      return XCTFail("expected incomplete replay for crash path")
    }
    XCTAssertEqual(observationID, "obs-crash")
    XCTAssertEqual(inputDigest, input.inputDigest)
  }

  func testDecisionJournalRejectsBrokenChainDigest() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    try journal.beginPending(observationID: "obs-chain", input: input, sequence: 1)
    let pending = journal.entries[0]
    let broken = WorkflowGraphDecisionJournalEntry(
      sequence: 2,
      observationID: "obs-chain",
      phase: .decided,
      evaluationTimeUnixMilliseconds: pending.evaluationTimeUnixMilliseconds,
      inputDigest: pending.inputDigest,
      chainDigest: String(repeating: "0", count: 64),
      entryDigest: String(repeating: "1", count: 64),
      advisoryDecision: .allow,
      reasonsDigest: WorkflowGraphDecisionJournalDigest.reasonsDigest(for: .allow))

    XCTAssertThrowsError(try WorkflowGraphDecisionJournal(entries: [pending, broken])) {
      error in
      guard case let .chainDigestMismatch(expected, actual, sequence)? =
        error as? WorkflowGraphDecisionJournalError
      else {
        return XCTFail("expected chainDigestMismatch, got \(error)")
      }
      XCTAssertEqual(expected, pending.entryDigest)
      XCTAssertEqual(actual, broken.chainDigest)
      XCTAssertEqual(sequence, 2)
    }
  }

  func testDecisionJournalRejectsSequenceDisorder() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    try journal.beginPending(observationID: "obs-seq", input: input, sequence: 1)
    let advisory = WorkflowGraphAdvisoryEvaluator().evaluate(input)
    XCTAssertThrowsError(
      try journal.recordDecided(
        observationID: "obs-seq",
        advisory: advisory,
        sequence: 3)
    ) { error in
      XCTAssertEqual(
        error as? WorkflowGraphDecisionJournalError,
        .sequenceDiscontinuity(expected: 2, actual: 3))
    }
    XCTAssertEqual(journal.entries.map(\.phase), [.pending])
  }

  func testDecisionJournalDuplicateObservationIsIdempotent() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    let firstPending = try journal.beginPending(
      observationID: "obs-idem",
      input: input,
      sequence: 1)
    XCTAssertEqual(firstPending, .appended)
    let replayPending = try journal.beginPending(
      observationID: "obs-idem",
      input: input,
      sequence: 1)
    XCTAssertEqual(replayPending, .alreadyRecorded)
    XCTAssertEqual(journal.entries.count, 1)

    let decision = WorkflowGraphAdvisoryEvaluator().evaluate(input)
    let firstDecided = try journal.recordDecided(
      observationID: "obs-idem",
      advisory: decision,
      sequence: 2)
    XCTAssertEqual(firstDecided, .appended)
    let replayDecided = try journal.recordDecided(
      observationID: "obs-idem",
      advisory: decision,
      sequence: 2)
    XCTAssertEqual(replayDecided, .alreadyRecorded)
    XCTAssertEqual(journal.entries.count, 2)
  }

  func testDecisionJournalReplayMatchesRecordedDecision() throws {
    let allowInput = committedAdvisoryInput()
    let denyInput = committedAdvisoryInput(contractValid: false)
    var journal = WorkflowGraphDecisionJournal()
    _ = try journal.evaluateAndRecord(
      observationID: "obs-match-allow",
      input: allowInput,
      pendingSequence: 1,
      decidedSequence: 2)
    _ = try journal.evaluateAndRecord(
      observationID: "obs-match-deny",
      input: denyInput,
      pendingSequence: 3,
      decidedSequence: 4)

    let replayed = try journal.replay()
    XCTAssertEqual(replayed.count, 2)
    guard case let .matched(obs1, decision1, _) = replayed[0] else {
      return XCTFail("expected matched allow")
    }
    XCTAssertEqual(obs1, "obs-match-allow")
    XCTAssertTrue(decision1.isAllowed)
    guard case let .matched(obs2, decision2, _) = replayed[1] else {
      return XCTFail("expected matched deny")
    }
    XCTAssertEqual(obs2, "obs-match-deny")
    XCTAssertFalse(decision2.isAllowed)
  }

  func testDecisionJournalReplayMismatchWhenRecordedDecisionTampered() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    try journal.beginPending(observationID: "obs-mismatch", input: input, sequence: 1)
    // Record a decision that disagrees with pure re-evaluation of the input.
    try journal.recordDecided(
      observationID: "obs-mismatch",
      advisory: .deny(reasons: [WorkflowGraphAdvisoryReason.contractInvalid]),
      sequence: 2)

    XCTAssertThrowsError(try journal.replay()) { error in
      guard case let .replayMismatch(details)? =
        error as? WorkflowGraphDecisionJournalError
      else {
        return XCTFail("expected replayMismatch, got \(error)")
      }
      XCTAssertEqual(details.observationID, "obs-mismatch")
      XCTAssertFalse(details.recordedDecision.isAllowed)
      XCTAssertTrue(details.replayedDecision.isAllowed)
      XCTAssertNotEqual(details.recordedReasonsDigest, details.replayedReasonsDigest)
    }
  }

  func testDecisionJournalPublicCannotHydrateHistory() throws {
    let input = committedAdvisoryInput()
    var live = WorkflowGraphDecisionJournal()
    try live.beginPending(observationID: "obs-hist", input: input, sequence: 1)
    let data = try JSONEncoder().encode(live)
    XCTAssertThrowsError(
      try JSONDecoder().decode(WorkflowGraphDecisionJournal.self, from: data))

    let source = try String(
      contentsOf: workflowGraphDecisionJournalSourceURL(), encoding: .utf8)
    XCTAssertTrue(source.contains("public init()"))
    XCTAssertTrue(source.contains("init(entries: [WorkflowGraphDecisionJournalEntry]) throws"))
    XCTAssertFalse(
      source.contains("public init(entries: [WorkflowGraphDecisionJournalEntry]"))
    // No dispatch / authorize surface on the journal type.
    XCTAssertFalse(source.contains("func dispatch("))
    XCTAssertFalse(source.contains("func startDispatch("))
    XCTAssertFalse(source.contains("func authorize("))
    XCTAssertFalse(source.contains("func issuePermit("))
    XCTAssertFalse(source.contains("DispatchRegistry"))
    XCTAssertFalse(source.contains("GoalRunDispatchLifecycle"))
  }

  func testDecisionJournalAndDivergenceLogAreIndependentButShareObservationID() throws {
    let input = committedAdvisoryInput()
    var journal = WorkflowGraphDecisionJournal()
    let advisory = try journal.evaluateAndRecord(
      observationID: "obs-cross-ref",
      input: input,
      pendingSequence: 1,
      decidedSequence: 2)

    var divergence = WorkflowGraphDivergenceLog()
    try divergence.append(
      observationID: "obs-cross-ref",
      actualDecision: .allow,
      advisory: advisory,
      input: input,
      sequence: 1,
      recordedAtUnixMilliseconds: 1_000)

    // Independent ledgers: neither overwrites the other.
    XCTAssertEqual(journal.entries.count, 2)
    XCTAssertEqual(divergence.entries.count, 1)
    XCTAssertEqual(journal.entries.map(\.observationID).first, "obs-cross-ref")
    XCTAssertEqual(divergence.entries[0].observationID, "obs-cross-ref")
    XCTAssertEqual(divergence.entries[0].inputDigest, journal.entries[0].inputDigest)
  }

  func testDecisionJournalRejectsDecidedWithoutPending() throws {
    var journal = WorkflowGraphDecisionJournal()
    XCTAssertThrowsError(
      try journal.recordDecided(
        observationID: "obs-no-pending",
        advisory: .allow,
        sequence: 1)
    ) { error in
      XCTAssertEqual(
        error as? WorkflowGraphDecisionJournalError,
        .pendingRequired(observationID: "obs-no-pending"))
    }
  }

  // MARK: Fixtures

  private func sampleLinearRevision() -> WorkflowGraphRevisionV1 {
    WorkflowGraphRevisionV1(
      goalHash: goalHash,
      planHash: planHash,
      nodes: [
        node(
          "build",
          title: "Build",
          proposal: WorkflowGraphProposalV1(intent: "implement change")),
        node("review", title: "Review"),
        node("ship", kind: .terminal, title: "Ship"),
      ],
      edges: [
        edge("e1", from: "build", to: "review", .afterSuccess),
        edge("e2", from: "review", to: "ship", .afterSuccess),
      ])
  }

  private func baseState(
    statuses: [String: WorkflowGraphNodeLifecycleV1] = [:]
  ) -> WorkflowGraphRecordedStateV1 {
    WorkflowGraphRecordedStateV1(
      goalHash: goalHash,
      planHash: planHash,
      nodeStatuses: statuses)
  }

  private func committedAdvisoryInput(
    contractValid: Bool = true,
    planValid: Bool = true,
    gatesAccepted: Bool = true,
    governorGranted: Bool = true,
    dispatchPermitValid: Bool = true,
    graphReady: Bool = true,
    evaluationTimeUnixMilliseconds: Int64? = 150
  ) -> ProductionWorkflowGraphAdvisoryInput {
    let permit = NodeExecutionPermit<ProductionRealm>(
      permitID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      isValid: dispatchPermitValid,
      digest: "permit-digest",
      issuedAtUnixMilliseconds: 100,
      expiresAtUnixMilliseconds: 200)
    return ProductionWorkflowGraphAdvisoryInput(
      contract: WorkflowGraphCommittedContract<ProductionRealm>(
        isValid: contractValid,
        digest: "contract-digest"),
      plan: WorkflowGraphCommittedPlan<ProductionRealm>(
        isValid: planValid,
        digest: "plan-digest"),
      gates: WorkflowGraphCommittedGates<ProductionRealm>(
        isAccepted: gatesAccepted,
        digest: "gates-digest"),
      governor: WorkflowGraphCommittedGovernor<ProductionRealm>(
        isGranted: governorGranted,
        digest: "governor-digest"),
      permit: permit,
      graphReady: graphReady,
      evaluationTimeUnixMilliseconds: evaluationTimeUnixMilliseconds)
  }

  private func node(
    _ id: String,
    kind: WorkflowGraphNodeKindV1 = .task,
    title: String,
    proposal: WorkflowGraphProposalV1? = nil,
    requiredReceipts: [String] = [],
    humanGate: Bool = false
  ) -> WorkflowGraphNodeV1 {
    WorkflowGraphNodeV1(
      id: id,
      kind: kind,
      title: title,
      goalCriterionRef: nil,
      proposal: proposal,
      requiredReceipts: requiredReceipts,
      humanGate: humanGate)
  }

  private func edge(
    _ id: String,
    from: String,
    to: String,
    _ condition: WorkflowGraphEdgeConditionV1
  ) -> WorkflowGraphEdgeV1 {
    WorkflowGraphEdgeV1(id: id, from: from, to: to, condition: condition)
  }

  private func workflowGraphSourceURL() -> URL {
    // Prefer repo-relative path from this test file location.
    let thisFile = URL(fileURLWithPath: #filePath)
    let candidates = [
      thisFile
        .deletingLastPathComponent() // Tests/...
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // TatwoUltraworkCore
        .appendingPathComponent("Sources/TatwoUltraworkCore/WorkflowGraph.swift"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(
          "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkflowGraph.swift"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return candidates[0]
  }

  private func workflowGraphAdvisorySourceURL() -> URL {
    let thisFile = URL(fileURLWithPath: #filePath)
    let candidates = [
      thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
          "Sources/TatwoUltraworkCore/WorkflowGraphAdvisory.swift"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(
          "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkflowGraphAdvisory.swift"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return candidates[0]
  }

  private func workflowGraphDecisionJournalSourceURL() -> URL {
    let thisFile = URL(fileURLWithPath: #filePath)
    let candidates = [
      thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
          "Sources/TatwoUltraworkCore/WorkflowGraphDecisionJournal.swift"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(
          "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkflowGraphDecisionJournal.swift"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return candidates[0]
  }
}
