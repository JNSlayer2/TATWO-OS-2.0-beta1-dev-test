import XCTest

@testable import TatwoUltraworkCore

/// Phase 2: staging scenario-config mutation is a write action gated behind a registered
/// contract. Before this, any local process could rewrite the config that every future
/// `tatwo.os.begin` reads — with no contractID and no enforce. These tests prove the gate.
final class ScenarioConfigGateTests: XCTestCase {
  func testConfigMutationRequiresRegisteredContract() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let configPath = dir.appendingPathComponent("scenario-config.json")
    setenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH", configPath.path, 1)
    setenv("TATWO_ULTRAWORK_STATE_DIR", dir.path, 1)
    defer {
      unsetenv("TATWO_ULTRAWORK_SCENARIO_CONFIG_PATH")
      unsetenv("TATWO_ULTRAWORK_STATE_DIR")
      try? FileManager.default.removeItem(at: dir)
    }

    // No contractID → fail closed.
    let noContract = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.config.add",
      arguments: ["displayName": .string("Rogue"), "baseScenario": .string("daily")])
    XCTAssertFalse(noContract.ok)

    // A never-issued contractID → fail closed.
    let forged = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.config.add",
      arguments: [
        "contractID": .string("contract-m-coding-ffffffffffff"),
        "displayName": .string("Rogue"), "baseScenario": .string("daily"),
      ])
    XCTAssertFalse(forged.ok)

    // A rejected mutation must not have written the config file.
    XCTAssertFalse(FileManager.default.fileExists(atPath: configPath.path))

    // A registered contract → allowed.
    let begin = TatwoMCPRegistry.call(
      tool: "tatwo.os.begin",
      arguments: try WorkOSMCPBeginTestSupport.arguments(
        mode: "M", scenario: "coding", objective: "config gate ok"))
    guard case .object(let payload)? = begin.payload,
      case .string(let contractID)? = payload["contractID"]
    else { return XCTFail("expected contractID from os.begin") }

    let allowed = TatwoMCPRegistry.call(
      tool: "tatwo.scenario.config.add",
      arguments: [
        "contractID": .string(contractID),
        "displayName": .string("Legit"), "baseScenario": .string("daily"),
      ])
    XCTAssertTrue(allowed.ok, allowed.error ?? "")
    XCTAssertTrue(FileManager.default.fileExists(atPath: configPath.path))
  }
}
