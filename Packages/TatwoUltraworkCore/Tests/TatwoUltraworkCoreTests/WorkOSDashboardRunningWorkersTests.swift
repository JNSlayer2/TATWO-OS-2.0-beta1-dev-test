import XCTest

@testable import TatwoUltraworkCore

/// B2: the dashboard's runningWorkers is sourced from real dispatch records — empty when none,
/// populated (and joinable to identity slots) when a dispatch exists.
final class WorkOSDashboardRunningWorkersTests: XCTestCase {
  func testRunningWorkersEmptyWithoutRegistry() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl, scenarioProfileID: "coding", objective: "dash empty")
    let snapshot = TatwoWorkOSDashboardFactory.make(contract: contract)
    XCTAssertTrue(snapshot.runningWorkers.isEmpty)
  }

  func testRunningWorkersPopulatedFromRegistryAndJoinToIdentitySlot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(directoryURL: root)

    let contract = try WorkOSFactory.projectContract(
      mode: .xl, scenarioProfileID: "coding", objective: "dash populated")
    let binding = try XCTUnwrap(contract.identityBindings.first)

    _ = try registry.begin(
      contractID: contract.contractID, bindingID: binding.id, sourceSlotID: binding.sourceSlotID,
      identity: binding.identity, modelID: "gpt-5.5", subtask: "review")

    let snapshot = TatwoWorkOSDashboardFactory.make(contract: contract, registry: registry)
    XCTAssertEqual(snapshot.runningWorkers.count, 1)
    let worker = try XCTUnwrap(snapshot.runningWorkers.first)
    XCTAssertEqual(worker.status, .queued)
    // The join key: a running worker's bindingID matches an identity slot's id (raw, unredacted).
    XCTAssertTrue(snapshot.identitySlots.contains { $0.id == worker.bindingID })
  }

  /// A registry read that THROWS (e.g. corrupt on-disk JSON) must degrade to an empty
  /// runningWorkers — the dashboard render path must never throw or crash.
  func testCorruptRegistryDegradesToEmptyRunningWorkers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TatwoDispatchRegistry(directoryURL: root)

    let contract = try WorkOSFactory.projectContract(
      mode: .xl, scenarioProfileID: "coding", objective: "dash corrupt")
    // Write garbage at the exact path the registry would read for this contract.
    let url = try registry.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not valid json".utf8).write(to: url)

    let snapshot = TatwoWorkOSDashboardFactory.make(contract: contract, registry: registry)
    XCTAssertTrue(snapshot.runningWorkers.isEmpty)  // degraded, not thrown
  }
}
