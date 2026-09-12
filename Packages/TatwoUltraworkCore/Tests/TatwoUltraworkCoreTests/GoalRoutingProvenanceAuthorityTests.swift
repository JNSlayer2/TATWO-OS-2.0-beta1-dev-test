import XCTest

@testable import TatwoUltraworkCore

/// Regression cover for the 2026-08-27 staging61 `/goal` routing and
/// mutation-authority failure (thread `34b8b85a…`, run `339CAEFE…`).
final class GoalRoutingProvenanceAuthorityTests: XCTestCase {

  // MARK: Live failure 1 — stale XXL inheritance

  func testOrdinaryGoalFromSingleModelThreadStaysSingleModel() {
    XCTAssertEqual(
      TatwoGoalTopologyAuthority.requestedTopology(
        commandText:
          "/goal 在 session-plan-goal-terra-r1 內完成 task_counter.py、README.md、test_task_counter.py"),
      .singleModel)
  }

  func testCarriedThreadTopologyIsNeverItsOwnAuthority() {
    // The exact live shape: thread `34b8b85a…` still carried
    // `general-xxl-sol-opus5-luna-grok-exact` (mode XXL,
    // `primaryModelID: gpt-5.5`) from an earlier `/plan`. Carried state must
    // not be readable back as a user request — no thread input exists here at
    // all, which is what makes the inheritance impossible to express.
    XCTAssertEqual(
      TatwoGoalTopologyAuthority.requestedTopology(
        commandText: "/goal 建立三個檔案並跑 unittest",
        explicitUltraworkRequest: false),
      .singleModel)
  }

  func testDevelopmentShapedObjectiveAloneNeverRequestsUltrawork() {
    // The visible-turn intent classifier says "this asks for development".
    // That must not be readable as "the user asked for an Ultrawork topology".
    let objective = "/goal 在 calc.py 加 divide 函式；跑測試"
    XCTAssertTrue(
      TatwoChatCommandPlanner.nativeDevelopmentDecision(
        currentVisibleTurn: objective,
        mode: .chat,
        interactionMode: .plan,
        scenarioPhase: .plan,
        contractStatus: .planned
      ).requested)
    XCTAssertEqual(
      TatwoGoalTopologyAuthority.requestedTopology(commandText: objective),
      .singleModel)
  }

  // MARK: Positive explicit-XXL controls

  func testExplicitUltraworkTokensRequestUltraworkTopology() {
    for command in [
      "/goal ultrawork XXL 完成這個重構",
      "/goal 用 XXL 拓撲處理",
      "$tatwo-ultrawork mode: xxl\n/goal 完成這個重構",
      "/goal 用 ultra-work 模式跑完",
    ] {
      XCTAssertEqual(
        TatwoGoalTopologyAuthority.requestedTopology(commandText: command),
        .ultrawork,
        command)
    }
  }

  /// The Plan canvas is the one out-of-band explicit request: the user picks
  /// Ultrawork collaboration and Goal as the destination in a single action.
  func testPlanCanvasUltraworkSelectionRequestsUltraworkTopology() {
    XCTAssertEqual(
      TatwoGoalTopologyAuthority.requestedTopology(
        commandText: "/goal 完成這個重構",
        explicitUltraworkRequest: true),
      .ultrawork)
  }

  func testNegatedOrQuotedUltraworkMentionIsNotAuthority() {
    for command in [
      "/goal 不要 ultrawork，單模型就好",
      "/goal without XXL topology please",
      "> /goal ultrawork XXL",
      "/goal 見說明\n```\nultrawork XXL\n```",
    ] {
      XCTAssertEqual(
        TatwoGoalTopologyAuthority.requestedTopology(commandText: command),
        .singleModel,
        command)
    }
  }

  // MARK: Live failure 3 — mutation after authority changed

  func testCancelledSupersededGoalBlocksHostMutationCapableSpawn() {
    let denial = TatwoGoalDispatchAuthorityGate.denial(
      frozenContractID:
        "contract-xxl-general-xxl-sol-opus5-luna-grok-exact-2cd42154892f",
      runtimeAdapter: .codexExec,
      computerHostAuthorized: false,
      boundContractID: nil,
      goalStatus: .cancelled,
      goalStatusReason: "superseded_before_dispatch")
    XCTAssertEqual(denial, .goalTerminalBeforeDispatch)
    XCTAssertEqual(
      TatwoGoalDispatchAuthorityGate.blocker(
        try XCTUnwrap(denial),
        goalStatus: .cancelled,
        goalStatusReason: "superseded_before_dispatch"),
      "goal_terminal_before_dispatch status=cancelled reason=superseded_before_dispatch")
  }

  func testSupersededGoalBlocksEveryHostMutationCapableTransport() {
    for adapter in [
      TatwoChatRuntimeAdapter.codexExec,
      .claudeCLI,
      .grokCLI,
      .nativeAgent,
    ] {
      XCTAssertEqual(
        TatwoGoalDispatchAuthorityGate.denial(
          frozenContractID: "contract-a",
          runtimeAdapter: adapter,
          computerHostAuthorized: false,
          boundContractID: "contract-a",
          goalStatus: .superseded,
          goalStatusReason: nil),
        .goalTerminalBeforeDispatch,
        adapter.rawValue)
    }
  }

  func testBrainOnlyTransportIsNotGatedByATerminalGoal() {
    for adapter in [
      TatwoChatRuntimeAdapter.gatewayDirect,
      .minimaxDirect,
      .unavailable,
    ] {
      XCTAssertNil(
        TatwoGoalDispatchAuthorityGate.denial(
          frozenContractID: "contract-a",
          runtimeAdapter: adapter,
          computerHostAuthorized: false,
          boundContractID: "contract-a",
          goalStatus: .cancelled,
          goalStatusReason: "superseded_before_dispatch"),
        adapter.rawValue)
    }
  }

  func testComputerHostAuthorityIsGatedOnAnyTransport() {
    XCTAssertEqual(
      TatwoGoalDispatchAuthorityGate.denial(
        frozenContractID: "contract-a",
        runtimeAdapter: .gatewayDirect,
        computerHostAuthorized: true,
        boundContractID: "contract-a",
        goalStatus: .cancelled,
        goalStatusReason: "superseded_before_dispatch"),
      .goalTerminalBeforeDispatch)
  }

  func testNonRevokedActiveGoalStatesStillPassLastMileGate() {
    for status in [
      GoalRunStatus.planned, .dispatching, .running, .awaitingNextCycle,
    ] {
      XCTAssertNil(
        TatwoGoalDispatchAuthorityGate.denial(
          frozenContractID: "contract-a",
          runtimeAdapter: .codexExec,
          computerHostAuthorized: false,
          boundContractID: "contract-a",
          goalStatus: status,
          goalStatusReason: nil),
        status.rawValue)
    }
  }

  func testRevokedOrHumanGatedGoalStatesBlockHostMutation() {
    for status in [
      GoalRunStatus.cancelled, .superseded, .humanGate, .blocked,
      .rollbackRequired,
    ] {
      XCTAssertEqual(
        TatwoGoalDispatchAuthorityGate.denial(
          frozenContractID: "contract-a",
          runtimeAdapter: .codexExec,
          computerHostAuthorized: false,
          boundContractID: "contract-a",
          goalStatus: status,
          goalStatusReason: nil),
        .goalTerminalBeforeDispatch,
        status.rawValue)
    }
  }

  func testNaturalCompletionAllowsOnlyAlreadyFrozenFollowUpTurn() {
    // This is intentionally a last-mile-only allowance. The lifecycle refuses
    // to begin a new dispatch from succeeded/failed/passed GoalRuns.
    for status in [
      GoalRunStatus.succeeded, .failed, .passed,
    ] {
      XCTAssertNil(
        TatwoGoalDispatchAuthorityGate.denial(
          frozenContractID: "contract-a",
          runtimeAdapter: .codexExec,
          computerHostAuthorized: false,
          boundContractID: "contract-a",
          goalStatus: status,
          goalStatusReason: nil),
        status.rawValue)
    }
  }

  func testReasonTextCannotRevokeOrExpandAuthorityPolicy() {
    for reason in [
      "superseded_before_dispatch",
      "rollback_required",
      "human_gate_required",
      "future_writer_invented_revocation_phrase",
    ] {
      XCTAssertNil(
      TatwoGoalDispatchAuthorityGate.denial(
        frozenContractID: "contract-a",
        runtimeAdapter: .codexExec,
        computerHostAuthorized: false,
        boundContractID: "contract-a",
        goalStatus: .running,
        goalStatusReason: reason),
        reason)
    }
  }

  func testUnverifiableGoalRecordFailsClosed() {
    XCTAssertEqual(
      TatwoGoalDispatchAuthorityGate.denial(
        frozenContractID: "contract-a",
        runtimeAdapter: .codexExec,
        computerHostAuthorized: false,
        boundContractID: "contract-a",
        goalStatus: nil,
        goalStatusReason: nil),
      .goalRecordUnverifiable)
  }

  func testDriftedContractAuthorityFailsClosed() {
    XCTAssertEqual(
      TatwoGoalDispatchAuthorityGate.denial(
        frozenContractID: "contract-a",
        runtimeAdapter: .codexExec,
        computerHostAuthorized: false,
        boundContractID: "contract-b",
        goalStatus: .running,
        goalStatusReason: nil),
      .contractAuthorityDrifted)
  }

  func testMissingDurableContractBindingFailsClosedInCoreGate() {
    XCTAssertEqual(
      TatwoGoalDispatchAuthorityGate.denial(
        frozenContractID: "contract-a",
        runtimeAdapter: .codexExec,
        computerHostAuthorized: false,
        boundContractID: nil,
        goalStatus: .running,
        goalStatusReason: nil),
      .durableContractBindingMissing)
  }

  func testUncontractedChatTurnIsNeverGated() {
    XCTAssertNil(
      TatwoGoalDispatchAuthorityGate.denial(
        frozenContractID: nil,
        runtimeAdapter: .codexExec,
        computerHostAuthorized: false,
        boundContractID: nil,
        goalStatus: nil,
        goalStatusReason: nil))
  }
}
