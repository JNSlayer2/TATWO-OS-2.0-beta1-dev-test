import Foundation

@testable import TatwoUltraworkCore

enum WorkOSMCPBeginTestSupport {
  static func arguments(
    mode: String,
    scenario: String,
    objective: String
  ) throws -> [String: JSONValue] {
    let parsedMode = try WorkModeID.parse(mode)
    let scenarioBook = TatwoScenarioConfigStore.loadDefaultStaging()
    let contract = try WorkOSFactory.projectContract(
      mode: parsedMode,
      scenarioProfileID: scenario,
      objective: objective,
      scenarioBook: scenarioBook)
    let stateRoot = TatwoGoalRunStore.default().directoryURL
    try FileManager.default.createDirectory(
      at: stateRoot,
      withIntermediateDirectories: true)
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: stateRoot,
      contractID: contract.contractID)

    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-mcp-workspace", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspace,
      withIntermediateDirectories: true)
    return [
      "mode": .string(mode),
      "scenario": .string(scenario),
      "objective": .string(objective),
      "provider": .string("codex"),
      "workspace": .string(workspace.path),
      "stateRoot": .string(stateRoot.path),
      // A re-begin in the same staged state root is the same MCP owner, so
      // the registry can exercise the explicit pristine supersession path.
      "ownerThread": .string("mcp-test-owner"),
    ]
  }
}
