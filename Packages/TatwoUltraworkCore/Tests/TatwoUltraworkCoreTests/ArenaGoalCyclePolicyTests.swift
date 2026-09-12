import XCTest

@testable import TatwoUltraworkCore

final class ArenaGoalCyclePolicyTests: XCTestCase {
  func testUniversalPlanLoopGoalProtocolAppliesToAllSandboxesAndRegistryTools() throws {
    let policy = TatwoArenaPolicyFactory.goalCyclePolicy
    let protocolSpec = TatwoArenaPolicyFactory.planLoopGoalProtocol()

    XCTAssertEqual(policy.maxGoalExecutionCycles, 5)
    XCTAssertEqual(policy.planRevisionLimit, "unlimited")
    XCTAssertEqual(policy.loopLedgerEntryLimit, "unlimited")
    XCTAssertTrue(policy.finalSubmissionSealRequired)

    XCTAssertTrue(protocolSpec.appliesToAllSandboxes)
    XCTAssertEqual(protocolSpec.mainlineName, "plan+loops+goal-主線")
    XCTAssertEqual(protocolSpec.branchName, "plan+loops+goal-支線優化")
    XCTAssertTrue(protocolSpec.mainlineRequiredArtifacts.contains("goal-contract.md"))
    XCTAssertTrue(protocolSpec.mainlineRequiredArtifacts.contains("loop-ledger.json"))
    XCTAssertTrue(protocolSpec.branchRequiredArtifacts.contains("tool-choice-ledger.json"))
    XCTAssertTrue(protocolSpec.allowedRegistryEntryIDs.contains("gitnexus"))
    XCTAssertTrue(protocolSpec.allowedRegistryEntryIDs.contains("chatgpt-pro-mcp"))
    XCTAssertTrue(protocolSpec.allowedRegistryEntryIDs.contains("web-check"))
    XCTAssertTrue(protocolSpec.allowedRegistryEntryIDs.contains("product-design"))
    XCTAssertTrue(protocolSpec.scoreAfterAllSandboxTests)
  }

  func testGoalCycleAssessmentForcesGradingAtFiveCyclesAndAfterSeal() throws {
    let canContinue = TatwoArenaPolicyFactory.assessGoalCycle(
      goalExecutionCycles: 4,
      finalSubmissionSealed: false)
    XCTAssertTrue(canContinue.canContinueImplementation)
    XCTAssertFalse(canContinue.mustEnterGrading)
    XCTAssertEqual(canContinue.remainingExecutionCycles, 1)

    let capReached = TatwoArenaPolicyFactory.assessGoalCycle(
      goalExecutionCycles: 5,
      finalSubmissionSealed: false)
    XCTAssertFalse(capReached.canContinueImplementation)
    XCTAssertTrue(capReached.mustEnterGrading)
    XCTAssertEqual(capReached.state, .readyForGrading)
    XCTAssertEqual(capReached.decisionCode, "goal_cycle_cap_reached_enter_grading")

    let sealed = TatwoArenaPolicyFactory.assessGoalCycle(
      goalExecutionCycles: 1,
      finalSubmissionSealed: true)
    XCTAssertTrue(sealed.mustEnterGrading)
    XCTAssertEqual(sealed.decisionCode, "sealed_enter_grading")

    let tampered = TatwoArenaPolicyFactory.assessGoalCycle(
      goalExecutionCycles: 1,
      finalSubmissionSealed: true,
      fileHashesChangedAfterSeal: true)
    XCTAssertEqual(tampered.state, .invalidSubmission)
    XCTAssertEqual(tampered.decisionCode, "sealed_hash_changed_invalid")
  }

  func testPlanLoopGoalScoreWaitsUntilAllSandboxTestsFinish() throws {
    let report = TatwoArenaPolicyFactory.scorePlanLoopGoal(
      modelSlug: "gpt-5.5",
      expectedSandboxTests: 3,
      completedSandboxTests: 2,
      missingSandboxTests: ["03-Pionex交易所複製/GPT5.5"],
      goalExecutionCycles: 5,
      finalSubmissionSealed: true,
      presentArtifacts: [
        "goal-contract.md",
        "plan.md",
        "loop-ledger.json",
        "mainline-decision.md",
        "final-submission/seal.json",
        "branch-optimization-plan.md",
        "branch-loop-ledger.json",
        "tool-choice-ledger.json",
        "receipt-index.json",
      ],
      toolChoicesAllRegistered: true)

    XCTAssertFalse(report.allSandboxTestsComplete)
    XCTAssertFalse(report.canScorePlanLoopGoal)
    XCTAssertNil(report.score)
    XCTAssertEqual(report.decisionCode, "sandbox_tests_incomplete_plg_score_blocked")
    XCTAssertFalse(report.modelSelfEvaluationAccepted)
  }

  func testPlanLoopGoalScoreRunsAfterAllSandboxTestsFinishAndGoalCloses() throws {
    let report = TatwoArenaPolicyFactory.scorePlanLoopGoal(
      modelSlug: "sonnet-5",
      expectedSandboxTests: 3,
      completedSandboxTests: 3,
      goalExecutionCycles: 5,
      finalSubmissionSealed: true,
      presentArtifacts: [
        "goal-contract.md",
        "plan.md",
        "loop-ledger.json",
        "mainline-decision.md",
        "final-submission/seal.json",
        "branch-optimization-plan.md",
        "branch-loop-ledger.json",
        "tool-choice-ledger.json",
        "receipt-index.json",
      ],
      toolChoicesAllRegistered: true)

    XCTAssertTrue(report.allSandboxTestsComplete)
    XCTAssertTrue(report.canScorePlanLoopGoal)
    XCTAssertFalse(report.inputsVerifiedFromDisk)
    XCTAssertTrue(report.inputsAssertedByCaller)
    XCTAssertFalse(report.scoreEligibleReceiptPresent)
    XCTAssertFalse(report.scoreUsableAsGateEvidence)
    XCTAssertEqual(report.decisionCode, "all_sandbox_tests_complete_score_plg")
    XCTAssertEqual(report.score?.total, 100)
    XCTAssertTrue(report.missingRequiredArtifacts.isEmpty)
  }

  func testPlanLoopGoalScoreOnlyBecomesGateEvidenceAfterDiskVerificationAndScoreEligibleReceipt() throws {
    let report = TatwoArenaPolicyFactory.scorePlanLoopGoal(
      modelSlug: "opus-5",
      expectedSandboxTests: 3,
      completedSandboxTests: 3,
      goalExecutionCycles: 5,
      finalSubmissionSealed: true,
      presentArtifacts: [
        "goal-contract.md",
        "plan.md",
        "loop-ledger.json",
        "mainline-decision.md",
        "final-submission/seal.json",
        "branch-optimization-plan.md",
        "branch-loop-ledger.json",
        "tool-choice-ledger.json",
        "receipt-index.json",
      ],
      toolChoicesAllRegistered: true,
      inputsVerifiedFromDisk: true,
      scoreEligibleReceiptPresent: true)

    XCTAssertTrue(report.canScorePlanLoopGoal)
    XCTAssertTrue(report.inputsVerifiedFromDisk)
    XCTAssertFalse(report.inputsAssertedByCaller)
    XCTAssertTrue(report.scoreEligibleReceiptPresent)
    XCTAssertTrue(report.scoreUsableAsGateEvidence)
    XCTAssertEqual(report.inputVerificationMode, "verified_from_disk")
  }

  func testWorkOSContractRequiresPLGReceiptsAndStopRules() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl,
      scenarioProfileID: "debug",
      objective: "debug arena plg smoke")

    XCTAssertEqual(contract.goalCyclePolicy.maxGoalExecutionCycles, 5)
    XCTAssertEqual(contract.planLoopGoalProtocol.mainlineName, "plan+loops+goal-主線")
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "plan-loop-goal-mainline" })
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "plan-loop-goal-branch" })
    XCTAssertTrue(contract.receiptRequirements.contains { $0.id == "goal-cycle-seal" })
    XCTAssertTrue(contract.stopRules.contains { $0.contains("沙盒評分才限制最多 5 次") })
    XCTAssertTrue(contract.stopRules.contains { $0.contains("正式工作 goal 不限制次數") })
    XCTAssertTrue(contract.stopRules.contains { $0.contains("tool-choice-ledger") })
  }

  func testMCPExposesArenaPLGPolicyAndGoalCycleAssessment() throws {
    let names = Set(TatwoMCPRegistry.tools.map(\.name))
    XCTAssertTrue(names.contains("tatwo.arena.plan_loop_goal.policy"))
    XCTAssertTrue(names.contains("tatwo.arena.plan_loop_goal.score"))
    XCTAssertTrue(names.contains("tatwo.arena.goal_cycle.assess"))

    let policy = TatwoMCPRegistry.call(
      tool: "tatwo_arena_plan_loop_goal_policy",
      arguments: [:])
    XCTAssertTrue(policy.ok, policy.error ?? "")
    let policyText = String(data: try JSONEncoder().encode(policy), encoding: .utf8) ?? ""
    XCTAssertTrue(policyText.contains("plan+loops+goal-主線"))
    XCTAssertTrue(policyText.contains("tool-choice-ledger"))

    let cap = TatwoMCPRegistry.call(
      tool: "tatwo_arena_goal_cycle_assess",
      arguments: ["goalExecutionCycles": .string("5")])
    XCTAssertTrue(cap.ok, cap.error ?? "")
    let capText = String(data: try JSONEncoder().encode(cap), encoding: .utf8) ?? ""
    XCTAssertTrue(capText.contains("goal_cycle_cap_reached_enter_grading"))

    let blockedScore = TatwoMCPRegistry.call(
      tool: "tatwo_arena_plan_loop_goal_score",
      arguments: [
        "modelSlug": .string("gpt-5.5"),
        "expectedSandboxTests": .string("3"),
        "completedSandboxTests": .string("2"),
        "goalExecutionCycles": .string("5"),
        "finalSubmissionSealed": .bool(true),
        "presentArtifacts": .string("goal-contract.md,plan.md,loop-ledger.json,mainline-decision.md,final-submission/seal.json,branch-optimization-plan.md,branch-loop-ledger.json,tool-choice-ledger.json,receipt-index.json"),
        "toolChoicesAllRegistered": .bool(true),
      ])
    XCTAssertTrue(blockedScore.ok, blockedScore.error ?? "")
    let scoreText = String(data: try JSONEncoder().encode(blockedScore), encoding: .utf8) ?? ""
    XCTAssertTrue(scoreText.contains("sandbox_tests_incomplete_plg_score_blocked"))
  }
}
