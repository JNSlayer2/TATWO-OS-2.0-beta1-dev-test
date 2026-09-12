import XCTest

@testable import TatwoUltraworkCore

/// B2: the execution manifest turns a contract's identity bindings into a per-binding
/// dispatch plan whose eligibility matches the real gateway allowlist.
final class ExecutionManifestTests: XCTestCase {
  func testIsDispatchableMatchesGatewayAllowlist() {
    XCTAssertTrue(TatwoExecutionManifestFactory.isDispatchable(modelID: "minimax-m3"))
    XCTAssertFalse(TatwoExecutionManifestFactory.isDispatchable(modelID: "sonnet-5"))
    XCTAssertFalse(TatwoExecutionManifestFactory.isDispatchable(modelID: nil))
    XCTAssertFalse(TatwoExecutionManifestFactory.isDispatchable(modelID: ""))
    XCTAssertFalse(TatwoExecutionManifestFactory.isDispatchable(modelID: "totally-bogus-model"))
  }

  func testManifestEntryCountMatchesIdentityBindings() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl, scenarioProfileID: "ui-ux", objective: "manifest count")
    let manifest = TatwoExecutionManifestFactory.make(contract: contract)

    XCTAssertEqual(manifest.entries.count, contract.identityBindings.count)
    XCTAssertEqual(manifest.contractID, contract.contractID)
    XCTAssertEqual(manifest.goalID, contract.goalID)
    XCTAssertEqual(Set(manifest.entries.map(\.bindingID)), Set(contract.identityBindings.map(\.id)))
  }

  func testManifestStatusMatchesDispatchabilityPerBinding() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl, scenarioProfileID: "coding", objective: "manifest status")
    let manifest = TatwoExecutionManifestFactory.make(contract: contract)

    for entry in manifest.entries {
      let expected: TatwoExecutionManifestStatus =
        TatwoExecutionManifestFactory.isDispatchable(modelID: entry.modelID) ? .planned : .skipped
      XCTAssertEqual(entry.status, expected, "binding \(entry.bindingID) model \(entry.modelID ?? "nil")")
    }
  }
}
