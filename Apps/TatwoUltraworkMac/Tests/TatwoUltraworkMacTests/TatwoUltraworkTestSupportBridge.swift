import TatwoUltraworkCore
import TatwoUltraworkTestSupport
import XCTest

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
  /// Seed execution evidence, not a passed Goal: the caller still exercises
  /// the actual close path after the canonical dispatch set has been sealed.
  static func finalizeSuccessfulDispatchFixtureForTesting(
    contract: TatwoWorkOSContractV1,
    store: TatwoGoalRunStore,
    registry: TatwoDispatchRegistry
  ) throws {
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: store.directoryURL,
      contractID: contract.contractID)
    let binding = try XCTUnwrap(
      contract.identityBindings.first {
        TatwoExecutionManifestFactory.isDispatchable(modelID: $0.modelID)
      })
    let dispatch = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: try XCTUnwrap(binding.modelID),
      subtask: "canonical terminal chat fixture",
      helperCap: try XCTUnwrap(TatwoCatalog.defaults.mode(contract.mode)?.maxHelpers),
      goalStore: store,
      dispatchRegistry: registry,
      scenarioBook: TatwoScenarioConfigDefaults.book)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: dispatch.id,
      status: .completed,
      receiptID: "terminal:\(dispatch.id)",
      outputRef: "tatwo-test://terminal-chat/\(dispatch.id)",
      goalStore: store,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: store,
      dispatchRegistry: registry)
  }

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
