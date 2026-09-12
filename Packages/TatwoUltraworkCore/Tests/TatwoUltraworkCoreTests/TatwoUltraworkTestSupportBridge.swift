import TatwoUltraworkCore
import TatwoUltraworkTestSupport

extension TatwoSessionStore {
  @discardableResult
  func writeRawPointerFixtureForTesting(
    _ pointer: TatwoSessionPointer
  ) throws -> TatwoSessionPointer {
    try TatwoUltraworkFixtureSupport.writeRawPointer(
      pointer,
      sessionStore: self)
  }
}

extension WorkOSFactory {
  static func issueDetachedFixtureForTesting(
    mode: WorkModeID,
    scenarioProfileID: String,
    objective: String = "Tatwo Work OS goal",
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    loopPresetID: String? = nil,
    enabledLoopTemplateIDs: [String]? = nil,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    store: TatwoGoalRunStore,
    registry: TatwoDispatchRegistry? = nil
  ) throws -> TatwoWorkOSContractV1 {
    try TatwoUltraworkFixtureSupport.issueDetachedContract(
      mode: mode,
      scenarioProfileID: scenarioProfileID,
      objective: objective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      loopPresetID: loopPresetID,
      enabledLoopTemplateIDs: enabledLoopTemplateIDs,
      routeBindingOverride: routeBindingOverride,
      store: store,
      registry: registry)
  }
}
