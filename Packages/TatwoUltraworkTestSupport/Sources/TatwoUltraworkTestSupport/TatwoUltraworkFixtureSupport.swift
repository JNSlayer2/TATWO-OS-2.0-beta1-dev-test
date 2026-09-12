import Foundation
import TatwoUltraworkCore

/// Fixture-only persistence kept outside every production source target.
///
/// This target is a dependency of test targets only. It intentionally writes
/// historical detached records and raw current-session pointer bytes that no
/// product, executable, App, CLI, or MCP route may issue.
public enum TatwoUltraworkFixtureSupport {
  @discardableResult
  public static func writeRawPointer(
    _ pointer: TatwoSessionPointer,
    sessionStore: TatwoSessionStore
  ) throws -> TatwoSessionPointer {
    let fileURL = sessionStore.directoryURL.appendingPathComponent(
      "current-session.json",
      isDirectory: false)
    try FileManager.default.createDirectory(
      at: sessionStore.directoryURL,
      withIntermediateDirectories: true)
    try canonicalData(pointer).write(to: fileURL, options: [.atomic])
    return pointer
  }

  public static func issueDetachedContract(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String,
    objective rawObjective: String = "Tatwo Work OS goal",
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    loopPresetID: String? = nil,
    enabledLoopTemplateIDs: [String]? = nil,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    store: TatwoGoalRunStore,
    registry: TatwoDispatchRegistry? = nil
  ) throws -> TatwoWorkOSContractV1 {
    let contract = try WorkOSFactory.projectContract(
      mode: mode,
      scenarioProfileID: rawScenarioProfileID,
      objective: rawObjective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      loopPresetID: loopPresetID,
      enabledLoopTemplateIDs: enabledLoopTemplateIDs,
      routeBindingOverride: routeBindingOverride)
    try store.recordBegin(contract: contract)
    if let registry {
      try persistRegistryFixture(
        manifest: TatwoExecutionManifestFactory.make(contract: contract),
        registry: registry)
    }
    return contract
  }

  private static func persistRegistryFixture(
    manifest: TatwoExecutionManifestV1,
    registry: TatwoDispatchRegistry
  ) throws {
    let normalized = manifest.contractID.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    guard !normalized.isEmpty,
      normalized.lowercased() == normalized,
      normalized.allSatisfy({ allowed.contains($0) })
    else {
      throw TatwoDispatchRegistryError.invalidContractID(manifest.contractID)
    }
    let directory = registry.directoryURL.appendingPathComponent(
      "dispatches",
      isDirectory: true)
    let fileURL = directory.appendingPathComponent(
      "\(normalized).json",
      isDirectory: false)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    let run = TatwoStoredDispatchRun(
      schema: "TatwoStoredDispatchRunV2",
      contractID: manifest.contractID,
      executionManifest: manifest,
      executionManifestSHA256: try manifest.canonicalSHA256(),
      manifestEntryIDs: manifest.entries.map(\.id),
      records: [],
      updatedAt: manifest.generatedAt,
      activeCycleEpoch: 1,
      cycleSeals: [])
    try canonicalData(run).write(to: fileURL, options: [.atomic])
  }

  private static func canonicalData<T: Encodable>(
    _ value: T
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
}
