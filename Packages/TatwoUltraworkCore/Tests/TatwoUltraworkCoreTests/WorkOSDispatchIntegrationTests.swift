import XCTest

@testable import TatwoUltraworkCore

/// Phase 1 end-to-end proof: the persistence store is now wired into the real MCP dispatch,
/// so the hardening holds through `TatwoMCPRegistry.call(...)`, not just when a store is passed
/// directly to the factory. `TATWO_ULTRAWORK_APP_SUPPORT` is redirected to a temp dir so these
/// dispatch calls never touch the real `~/Library/Application Support`.
final class WorkOSDispatchIntegrationTests: XCTestCase {
  private func withTempAppSupport(_ body: () throws -> Void) rethrows {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-os-dispatch-\(UUID().uuidString)", isDirectory: true)
    setenv("TATWO_ULTRAWORK_APP_SUPPORT", tmp.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_APP_SUPPORT")
      try? FileManager.default.removeItem(at: tmp)
    }
    try body()
  }

  /// Side-effect-free (store == nil): compute the deterministic contract + required receipts
  /// the dispatch `begin` will produce for the same inputs.
  private func plannedContract(objective: String) throws -> (id: String, required: [String]) {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl, scenarioProfileID: "coding", objective: objective)
    return (contract.contractID, contract.receiptRequirements.filter(\.requiredForPass).map(\.id))
  }

  func testDispatchBeginRegistersContractOnDisk() throws {
    try withTempAppSupport {
      let objective = "phase1 register"
      let planned = try plannedContract(objective: objective)

      let begin = TatwoMCPRegistry.call(
        tool: "tatwo.os.begin",
        arguments: try WorkOSMCPBeginTestSupport.arguments(
          mode: "XL", scenario: "coding", objective: objective))
      XCTAssertTrue(begin.ok)

      // The dispatch wrote a record under the deterministic contractID we computed.
      let store = TatwoGoalRunStore.default()
      XCTAssertNotNil(try store.record(forContractID: planned.id))
    }
  }

  func testFabricatedReceiptsRejectedThroughMCPDispatch() throws {
    try withTempAppSupport {
      let objective = "phase1 fabricate"
      let planned = try plannedContract(objective: objective)
      XCTAssertGreaterThan(planned.required.count, 1)

      let begin = TatwoMCPRegistry.call(
        tool: "tatwo.os.begin",
        arguments: try WorkOSMCPBeginTestSupport.arguments(
          mode: "XL", scenario: "coding", objective: objective))
      XCTAssertTrue(begin.ok)

      // Attack through dispatch: never submit a receipt, but hand the full required list
      // back as receiptIDs. The store-backed close ignores the caller list.
      let close = TatwoMCPRegistry.call(
        tool: "tatwo.os.goal.close",
        arguments: [
          "contractID": .string(planned.id), "mode": .string("XL"),
          "scenario": .string("coding"), "objective": .string(objective),
          "receiptIDs": .array(planned.required.map { JSONValue.string($0) }),
        ])
      XCTAssertFalse(close.ok)
      // Rejected for incompleteness (journal empty), NOT for an unregistered contract —
      // proving the fabrication path specifically is closed.
      XCTAssertEqual(close.error?.contains("不足"), true)
    }
  }

  func testSubmitThenCloseThroughMCPDispatchPasses() throws {
    try withTempAppSupport {
      let objective = "phase1 happy"
      let planned = try plannedContract(objective: objective)

      XCTAssertTrue(
        TatwoMCPRegistry.call(
          tool: "tatwo.os.begin",
          arguments: try WorkOSMCPBeginTestSupport.arguments(
            mode: "XL", scenario: "coding", objective: objective)
        ).ok)

      // Journal every required receipt through the real dispatch.
      for id in planned.required {
        let submit = TatwoMCPRegistry.call(
          tool: "tatwo.os.receipt.submit",
          arguments: [
            "contractID": .string(planned.id), "receiptID": .string(id),
            "receiptKind": .string("test"),
          ])
        XCTAssertTrue(submit.ok, "submit \(id)")
      }

      let store = TatwoGoalRunStore.default()
      let registry = TatwoDispatchRegistry.default()
      let contract = try WorkOSFactory.storedContractProjection(
        contractID: planned.id,
        fallbackMode: .xl,
        fallbackScenarioProfileID: "coding",
        store: store)
      try GoalStoreTestSupport.finalizeSuccessfulDispatch(
        contract: contract, store: store, registry: registry)

      // Close with NO caller-supplied receipts: journal + canonical terminal ledger.
      let close = TatwoMCPRegistry.call(
        tool: "tatwo.os.goal.close",
        arguments: [
          "contractID": .string(planned.id), "mode": .string("XL"),
          "scenario": .string("coding"), "objective": .string(objective),
        ])
      XCTAssertTrue(close.ok)
    }
  }

  func testSubmitRejectsUnregisteredContractThroughMCPDispatch() throws {
    withTempAppSupport {
      let submit = TatwoMCPRegistry.call(
        tool: "tatwo.os.receipt.submit",
        arguments: [
          "contractID": .string("contract-xl-coding-ffffffffffff"),
          "receiptID": .string("scope-review"), "receiptKind": .string("scope"),
        ])
      XCTAssertFalse(submit.ok)
    }
  }

  func testCloseRejectsUnregisteredContractThroughMCPDispatch() throws {
    withTempAppSupport {
      let close = TatwoMCPRegistry.call(
        tool: "tatwo.os.goal.close",
        arguments: [
          "contractID": .string("contract-xl-coding-ffffffffffff"),
          "mode": .string("XL"), "scenario": .string("coding"),
          "objective": .string("never began"),
        ])
      XCTAssertFalse(close.ok)
    }
  }
}
