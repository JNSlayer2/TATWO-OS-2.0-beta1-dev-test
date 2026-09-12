import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoNativeDevelopmentDispatchCoordinatorTests: XCTestCase {
  // MARK: Deprecated beginSolExecutor historical-contract references
  //
  // The M4c plan note is dated 2026-08-20. These calls intentionally remain
  // test-only references for the old Sol/Opus convenience contract; production
  // dispatch uses beginSelectedExecutor.

  func testExplicitGoalConfirmationBeginsExactSolExecutorDispatch() throws {
    let fixture = try makeFixture("begin")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let record = try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
      contract: fixture.contract,
      subtask: "修正 App 原生開發閉環",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    XCTAssertEqual(record.status, .running)
    XCTAssertEqual(record.identity, .sub)
    XCTAssertEqual(record.modelID, "gpt-5.6-sol")
    XCTAssertEqual(
      record.sourceSlotID,
      "general-xxl-native-development-loops-executor-sol")
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID).status,
      .running)
  }

  func testExplicitGoalConfirmationCanDispatchSelectedOpusLoopsSupervisor()
    throws
  {
    let fixture = try makeFixture("opus")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let record =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "重做 Tatwo Island Liquid Glass",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(record.status, .running)
    XCTAssertEqual(record.identity, .supervisor)
    XCTAssertEqual(record.modelID, "opus-5")
    XCTAssertEqual(
      record.sourceSlotID,
      "general-xxl-native-development-loops-supervisor-opus5")
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID).status,
      .running)
  }

  func testFableGrokScenarioBeginsExactFableMediumExecutor() throws {
    let fixture = try makeFixture(
      "fable-first",
      scenarioID:
        TatwoScenarioConfigDefaults
          .nativeDevelopmentXXLFableGrokScenarioID)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let record =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "fable-5",
        subtask: "先完成 Tatwo Island lane",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(record.status, .running)
    XCTAssertEqual(record.modelID, "fable-5")
    XCTAssertEqual(
      record.sourceSlotID,
      TatwoNativeDevelopmentDispatchCoordinator.fableExecutorSourceSlotID)
  }

  func testFableGrokScenarioBlocksGrokUntilFableTerminalReceiptAndOutputComplete()
    throws
  {
    let fixture = try makeFixture(
      "ordered-fable-grok",
      scenarioID:
        TatwoScenarioConfigDefaults
          .nativeDevelopmentXXLFableGrokScenarioID)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "grok-build",
        subtask: "不可搶先執行 Aurora lane",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    ) {
      XCTAssertEqual(
        $0 as? TatwoNativeDevelopmentDispatchCoordinatorError,
        .prerequisiteExecutorIncomplete(modelID: "grok-build"))
    }

    let fable =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "fable-5",
        subtask: "完成 Island lane",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
      contractID: fixture.contract.contractID,
      dispatchID: fable.id,
      outputRef: "native-run:fable-island",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    XCTAssertThrowsError(
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "grok-build",
        subtask: "缺 terminal receipt 不可開始 Aurora lane",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    ) {
      XCTAssertEqual(
        $0 as? TatwoNativeDevelopmentDispatchCoordinatorError,
        .prerequisiteExecutorIncomplete(modelID: "grok-build"))
    }

    let receiptedFable =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "fable-5",
        subtask: "重新完成 Island lane 並提交 terminal receipt",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
      contractID: fixture.contract.contractID,
      dispatchID: receiptedFable.id,
      receiptID: "native-terminal:fable-island",
      outputRef: "native-run:fable-island-receipted",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let grok =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "grok-build",
        subtask: "開始 Aurora lane",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(grok.status, .running)
    XCTAssertEqual(grok.modelID, "grok-build")
    XCTAssertEqual(
      grok.sourceSlotID,
      TatwoNativeDevelopmentDispatchCoordinator.grokExecutorSourceSlotID)
  }

  func testBeginRejectsAnyScenarioOtherThanExactNativeDevelopment() throws {
    let root = temporaryRoot("wrong-scenario")
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
      objective: "wrong scenario",
      store: goalStore)

    XCTAssertThrowsError(
      try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
        contract: contract,
        subtask: "must not dispatch",
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) {
      XCTAssertEqual(
        $0 as? TatwoNativeDevelopmentDispatchCoordinatorError,
        .scenarioMismatch(
          expected:
            TatwoScenarioConfigDefaults
              .nativeDevelopmentXXLSolOpusScenarioID,
          actual: contract.scenario))
    }
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .planned)
  }

  func testNativeTerminalUpdatesTheSameDispatchRecord() throws {
    let fixture = try makeFixture("terminal")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let running = try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
      contract: fixture.contract,
      subtask: "run native tools",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let completed =
      try TatwoNativeDevelopmentDispatchCoordinator.complete(
        contractID: fixture.contract.contractID,
        dispatchID: running.id,
        outputRef: "sha256:test-output",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(completed.id, running.id)
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(completed.outputRef, "sha256:test-output")
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID).status,
      .running,
      "One completed executor does not finalize the Sol/Opus dispatch set.")
  }

  func testNativeFailureFailsClosedThroughGoalLifecycle() throws {
    let fixture = try makeFixture("failure")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let running = try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
      contract: fixture.contract,
      subtask: "run native tools",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let failed = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: fixture.contract.contractID,
      dispatchID: running.id,
      errorCode: "native_runtime_unavailable",
      message: "credential unavailable",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    XCTAssertEqual(failed.id, running.id)
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID).status,
      .blocked)
  }

  // M4b 更新：唯一不把 Goal 轉 blocked 的失敗是 Fable+Grok 情境中
  // 精確、可稽核的 Grok dev attestation 未驗證；lane 本身仍是 failed。
  func testM4bExactGrokAttestationFailurePreservesRunningGoal() throws {
    let fixture = try makeFixture(
      "m4b-grok-attestation",
      scenarioID:
        TatwoScenarioConfigDefaults
          .nativeDevelopmentXXLFableGrokScenarioID)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fable =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "fable-5",
        subtask: "complete Fable lane",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
      contractID: fixture.contract.contractID,
      dispatchID: fable.id,
      receiptID: "native-terminal:fable",
      outputRef: "native-artifact:fable",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    let grok =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "grok-build",
        subtask: "attempt Grok lane",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    let failed = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: fixture.contract.contractID,
      dispatchID: grok.id,
      errorCode:
        TatwoNativeDevelopmentDispatchCoordinator
          .grokDevAttestationUnverifiedErrorCode,
      message:
        "Governed development session failed: "
          + TatwoNativeDevelopmentDispatchCoordinator
            .grokDevAttestationUnverifiedErrorCode,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(
      failed.failureReceipt?.errorCode,
      TatwoNativeDevelopmentDispatchCoordinator
        .grokDevAttestationUnverifiedErrorCode)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID).status,
      .running)
  }

  func testBlockedGoalRetriesFailedSelectedExecutorAsSecondAttempt() throws {
    let fixture = try makeFixture("selected-executor-retry")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "first Liquid Glass attempt",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: fixture.contract.contractID,
      dispatchID: first.id,
      errorCode: "gateway_error",
      message: "subscription runner failed before tool execution",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let retry =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "retry Liquid Glass in the same Goal",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(retry.status, .running)
    XCTAssertEqual(retry.goalID, fixture.contract.goalID)
    XCTAssertEqual(retry.bindingID, first.bindingID)
    XCTAssertEqual(retry.supersedes, first.id)
    XCTAssertEqual(retry.attempt, 2)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID).status,
      .running)
  }

  func testBlockedGoalCanContinueWithExactOpusAfterDifferentBindingFails()
    throws
  {
    let fixture = try makeFixture("cross-binding-retry")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let priorOpus =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "inspect Liquid Glass",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
      contractID: fixture.contract.contractID,
      dispatchID: priorOpus.id,
      outputRef: "native-run:prior-opus",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let failedSol =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSolExecutor(
        contract: fixture.contract,
        subtask: "repair native tool routing",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: fixture.contract.contractID,
      dispatchID: failedSol.id,
      errorCode: "gateway_error",
      message: "Native agent step limit reached",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let continuedOpus =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "continue the confirmed Liquid Glass stage",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(continuedOpus.status, .running)
    XCTAssertEqual(continuedOpus.bindingID, priorOpus.bindingID)
    XCTAssertEqual(continuedOpus.supersedes, failedSol.id)
    XCTAssertEqual(continuedOpus.attempt, 2)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID).status,
      .running)
  }

  func testBlockedNativeDevelopmentAllowsOneManualThirdAttemptButStillStopsAtThree()
    throws
  {
    let fixture = try makeFixture("bounded-third-attempt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let first =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "first subscription attempt",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: fixture.contract.contractID,
      dispatchID: first.id,
      errorCode: "claude_subscription_session_limit",
      message: "session limit before reset",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let second =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "second subscription attempt",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: fixture.contract.contractID,
      dispatchID: second.id,
      errorCode: "claude_subscription_session_limit",
      message: "session limit still active",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let third =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "manual retry after subscription reset",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(third.supersedes, second.id)
    XCTAssertEqual(third.resolvedAttempt, 3)

    _ = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: fixture.contract.contractID,
      dispatchID: third.id,
      errorCode: "native_runtime_failure",
      message: "third attempt failed",
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    XCTAssertThrowsError(
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: fixture.contract,
        selectedModelID: "opus-5",
        subtask: "must remain bounded",
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry)
    ) { error in
      guard let registryError = error as? TatwoDispatchRegistryError,
        case .retryBudgetExhausted = registryError
      else {
        return XCTFail("Expected retryBudgetExhausted, got \(error)")
      }
    }
  }

  private func makeFixture(
    _ suffix: String,
    scenarioID: String =
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID
  ) throws -> (
    root: URL,
    goalStore: TatwoGoalRunStore,
    registry: TatwoDispatchRegistry,
    contract: TatwoWorkOSContractV1
  ) {
    let root = temporaryRoot(suffix)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID: scenarioID,
      objective: "native development \(suffix)",
      store: goalStore)
    return (root, goalStore, registry, contract)
  }

  private func temporaryRoot(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-native-dispatch-\(suffix)-\(UUID().uuidString)",
      isDirectory: true)
  }
}
