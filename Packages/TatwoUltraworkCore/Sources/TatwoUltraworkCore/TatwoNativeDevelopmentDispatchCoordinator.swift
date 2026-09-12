import Foundation

public enum TatwoNativeDevelopmentDispatchCoordinatorError:
  Error, LocalizedError, Sendable, Equatable
{
  case scenarioMismatch(expected: String, actual: String)
  case contractMismatch
  case exactExecutorBindingMissing
  case exactExecutorAuthorityMismatch
  case exactExecutorActivationMissing
  case exactExecutorEffortMismatch
  case selectedExecutorBindingMissing(modelID: String)
  case selectedExecutorAuthorityMismatch(modelID: String)
  case selectedExecutorActivationMissing(modelID: String)
  case selectedExecutorEffortMismatch(modelID: String)
  case prerequisiteExecutorIncomplete(modelID: String)
  case replacementRequiresTerminalFailedDispatch
  case replacementDispatchStillActive(ids: [String])
  case helperLimitMissing

  public var errorDescription: String? {
    switch self {
    case let .scenarioMismatch(expected, actual):
      return "Native development scenario mismatch: expected=\(expected) actual=\(actual)."
    case .contractMismatch:
      return "Native development contract does not match the issued GoalRun."
    case .exactExecutorBindingMissing:
      return "Exact Sol native-development executor binding is missing or ambiguous."
    case .exactExecutorAuthorityMismatch:
      return "Exact Sol native-development executor lacks the contract's host-mutation bridge."
    case .exactExecutorActivationMissing:
      return "Exact Sol native-development executor activation is missing."
    case .exactExecutorEffortMismatch:
      return "Exact Sol native-development executor must use high effort."
    case let .selectedExecutorBindingMissing(modelID):
      return "Selected native-development executor binding is missing or ambiguous: \(modelID)."
    case let .selectedExecutorAuthorityMismatch(modelID):
      return "Selected native-development executor lacks the contract's host-mutation bridge: \(modelID)."
    case let .selectedExecutorActivationMissing(modelID):
      return "Selected native-development executor activation is missing: \(modelID)."
    case let .selectedExecutorEffortMismatch(modelID):
      return "Selected native-development executor effort does not match the contract: \(modelID)."
    case let .prerequisiteExecutorIncomplete(modelID):
      return "Selected native-development executor is waiting for its prerequisite completed receipt: \(modelID)."
    case .replacementRequiresTerminalFailedDispatch:
      return "Native-development Goal replacement requires a blocked Goal with an exact failed dispatch receipt."
    case let .replacementDispatchStillActive(ids):
      return "Native-development Goal replacement is blocked by active dispatches: \(ids.joined(separator: ","))."
    case .helperLimitMissing:
      return "Native development mode has no dispatch helper limit."
    }
  }
}

/// The single App-facing chokepoint for native-development dispatch lifecycle.
///
/// The App may request an exact, already-issued native-development binding
/// after an explicit human Goal confirmation. It never writes the dispatch
/// registry directly: begin and terminal updates remain atomic with GoalRun
/// state through `TatwoGoalRunDispatchLifecycle`.
public enum TatwoNativeDevelopmentDispatchCoordinator {
  public static let solExecutorSourceSlotID =
    "general-xxl-native-development-loops-executor-sol"
  public static let opusSupervisorSourceSlotID =
    "general-xxl-native-development-loops-supervisor-opus5"
  public static let fableExecutorSourceSlotID =
    "general-xxl-native-development-loops-executor-fable5"
  public static let grokExecutorSourceSlotID =
    "general-xxl-native-development-loops-executor-grok46"
  public static let solModelID = "gpt-5.6-sol"
  public static let grokDevAttestationUnverifiedErrorCode =
    "grok_dev_attestation_unverified"

  /// Deprecated historical Sol/Opus convenience entrypoint.
  ///
  /// The M4c reconnaissance note is dated 2026-08-20 (one day after this
  /// 2026-08-19 implementation). It records that production App code has no
  /// caller and only tests consume this API. It remains as a non-deleted
  /// reference for the historical Sol/Opus scenario contract; new callers
  /// should use `beginSelectedExecutor`.
  @discardableResult
  @available(
    *, deprecated,
    message:
      "Historical Sol/Opus contract reference retained for tests; use beginSelectedExecutor.")
  public static func beginSolExecutor(
    contract: TatwoWorkOSContractV1,
    subtask: String,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 =
      TatwoScenarioConfigDefaults.book
  ) throws -> TatwoDispatchRecord {
    let expectedScenario =
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID
    guard contract.scenario == expectedScenario else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError.scenarioMismatch(
        expected: expectedScenario,
        actual: contract.scenario)
    }
    let issued = try goalStore.requireIssuedContract(contract.contractID)
    guard issued.contractID == contract.contractID,
      issued.goalID == contract.goalID,
      issued.scenario == contract.scenario
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError.contractMismatch
    }
    try goalStore.verifyIssuedIdentityBindings(contract: contract)

    let normalizedSol = TatwoGatewayDispatchCatalog.normalize(solModelID)
    let bindings = contract.identityBindings.filter {
      $0.sourceSlotID == solExecutorSourceSlotID
        && $0.identity == .sub
        && $0.modelID.map(TatwoGatewayDispatchCatalog.normalize)
          == normalizedSol
    }
    guard bindings.count == 1, let binding = bindings.first else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .exactExecutorBindingMissing
    }
    guard binding.authority == .toolIntentBridge,
      binding.canMutateHost
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .exactExecutorAuthorityMismatch
    }
    let activations = contract.loopGovernorDecision.activatedBindings.filter {
      $0.id == solExecutorSourceSlotID
        && $0.phase == .loops
        && $0.enabled
        && $0.dynamicActivation != .disabled
        && $0.boundModelIDs.contains {
          TatwoGatewayDispatchCatalog.normalize($0) == normalizedSol
        }
    }
    guard activations.count == 1, let activation = activations.first else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .exactExecutorActivationMissing
    }
    guard activation.reasoningEffort == .high else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .exactExecutorEffortMismatch
    }
    guard let helperCap = catalog.mode(contract.mode)?.maxHelpers,
      helperCap > 0
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError.helperLimitMissing
    }
    let supersedes = try retrySupersedesIfBlocked(
      contractID: contract.contractID,
      goalID: contract.goalID,
      goalStatus: issued.status,
      goalStatusReason: issued.statusReason,
      dispatchRegistry: dispatchRegistry)

    return try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: solModelID,
      subtask: subtask,
      supersedes: supersedes,
      retryAttemptCap: 3,
      helperCap: helperCap,
      goalStore: goalStore,
      dispatchRegistry: dispatchRegistry,
      catalog: catalog,
      scenarioBook: scenarioBook)
  }

  @discardableResult
  public static func beginSelectedExecutor(
    contract: TatwoWorkOSContractV1,
    selectedModelID: String,
    subtask: String,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 =
      TatwoScenarioConfigDefaults.book
  ) throws -> TatwoDispatchRecord {
    let expectedScenario =
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID
    let fableGrokScenario =
      TatwoScenarioConfigDefaults.nativeDevelopmentXXLFableGrokScenarioID
    guard contract.scenario == expectedScenario
      || contract.scenario == fableGrokScenario
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError.scenarioMismatch(
        expected: "\(expectedScenario)|\(fableGrokScenario)",
        actual: contract.scenario)
    }
    let issued = try goalStore.requireIssuedContract(contract.contractID)
    guard issued.contractID == contract.contractID,
      issued.goalID == contract.goalID,
      issued.scenario == contract.scenario
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError.contractMismatch
    }
    try goalStore.verifyIssuedIdentityBindings(contract: contract)

    let normalizedModel =
      TatwoGatewayDispatchCatalog.normalize(selectedModelID)
    if contract.scenario == fableGrokScenario,
      normalizedModel == TatwoGatewayDispatchCatalog.normalize("grok-build")
    {
      let records =
        try dispatchRegistry.run(forContractID: contract.contractID)?
          .records ?? []
      guard records.contains(where: {
        $0.sourceSlotID == fableExecutorSourceSlotID
          && $0.status == .completed
          && $0.receiptID != nil
          && $0.outputRef != nil
      }) else {
        throw TatwoNativeDevelopmentDispatchCoordinatorError
          .prerequisiteExecutorIncomplete(modelID: selectedModelID)
      }
    }
    let identityPreference: [IdentityKind] = [.sub, .supervisor, .verifier]
    let modelBindings = contract.identityBindings.filter {
      $0.modelID.map(TatwoGatewayDispatchCatalog.normalize) == normalizedModel
    }
    let modelActivations =
      contract.loopGovernorDecision.activatedBindings.filter {
        $0.phase == .loops
          && $0.enabled
          && $0.dynamicActivation != .disabled
          && $0.boundModelIDs.contains {
            TatwoGatewayDispatchCatalog.normalize($0) == normalizedModel
          }
      }
    guard let selectedIdentity = identityPreference.first(where: { identity in
      modelBindings.contains { $0.identity == identity }
    }) else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .selectedExecutorBindingMissing(modelID: selectedModelID)
    }
    let bindings = modelBindings.filter { $0.identity == selectedIdentity }
    guard bindings.count == 1, let binding = bindings.first else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .selectedExecutorBindingMissing(modelID: selectedModelID)
    }
    guard binding.authority == .toolIntentBridge,
      binding.canMutateHost
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .selectedExecutorAuthorityMismatch(modelID: selectedModelID)
    }
    let activations = modelActivations.filter {
      $0.id == binding.sourceSlotID
    }
    guard activations.count == 1, let activation = activations.first else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .selectedExecutorActivationMissing(modelID: selectedModelID)
    }
    let requiredEffort: TatwoCodexReasoningEffort =
      normalizedModel == TatwoGatewayDispatchCatalog.normalize("fable-5")
        ? .medium
        : .high
    guard activation.reasoningEffort == requiredEffort else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .selectedExecutorEffortMismatch(modelID: selectedModelID)
    }
    guard let helperCap = catalog.mode(contract.mode)?.maxHelpers,
      helperCap > 0
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError.helperLimitMissing
    }
    let supersedes = try retrySupersedesIfBlocked(
      contractID: contract.contractID,
      goalID: contract.goalID,
      goalStatus: issued.status,
      goalStatusReason: issued.statusReason,
      dispatchRegistry: dispatchRegistry)

    return try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: selectedModelID,
      subtask: subtask,
      supersedes: supersedes,
      retryAttemptCap: 3,
      helperCap: helperCap,
      goalStore: goalStore,
      dispatchRegistry: dispatchRegistry,
      catalog: catalog,
      scenarioBook: scenarioBook)
  }

  private static func retrySupersedesIfBlocked(
    contractID: String,
    goalID: String,
    goalStatus: GoalRunStatus,
    goalStatusReason: String?,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> String? {
    guard goalStatus == .blocked else { return nil }
    let prefix = "dispatch_failed:"
    guard let goalStatusReason,
      goalStatusReason.hasPrefix(prefix)
    else { return nil }
    let failedDispatchID =
      goalStatusReason.dropFirst(prefix.count)
        .split(separator: ":", maxSplits: 1)
        .first
        .map(String.init) ?? ""
    guard !failedDispatchID.isEmpty,
      let run = try dispatchRegistry.run(forContractID: contractID),
      run.records.contains(where: {
        $0.id == failedDispatchID
          && $0.goalID == goalID
          && $0.status == .failed
      })
    else { return nil }
    return failedDispatchID
  }

  /// Finalize an explicitly abandoned native-development Goal only after its
  /// exact failed dispatch is durable and no dispatch remains active.
  ///
  /// This does not delete or supersede the old Goal. It makes the failure
  /// terminal so the App can clear the exact current-session pointer, preserve
  /// the old Chat row and receipts, then create a separate main Chat for a
  /// materially different `/goal`.
  @discardableResult
  public static func finalizeBlockedGoalForReplacement(
    contractID: String,
    goalID: String,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoStoredGoalRun {
    let issued = try goalStore.requireIssuedContract(contractID)
    guard issued.goalID == goalID,
      let failedDispatchID = try retrySupersedesIfBlocked(
        contractID: contractID,
        goalID: goalID,
        goalStatus: issued.status,
        goalStatusReason: issued.statusReason,
        dispatchRegistry: dispatchRegistry)
    else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .replacementRequiresTerminalFailedDispatch
    }
    let records =
      try dispatchRegistry.run(forContractID: contractID)?.records ?? []
    let activeIDs = records.filter { record in
      guard record.goalID == nil || record.goalID == goalID else {
        return false
      }
      if record.status == .queued || record.status == .running {
        return true
      }
      if let remote = record.remoteStatus {
        return [.queued, .delivered, .accepted, .running].contains(remote)
      }
      return false
    }.map(\.id).sorted()
    guard activeIDs.isEmpty else {
      throw TatwoNativeDevelopmentDispatchCoordinatorError
        .replacementDispatchStillActive(ids: activeIDs)
    }
    return try goalStore.updateStatus(
      contractID: contractID,
      status: .failed,
      authority: .dispatchFailure,
      reason:
        "replaced_after_terminal_dispatch_failure:\(failedDispatchID)",
      evidence: .failure(dispatchID: failedDispatchID))
  }

  @discardableResult
  public static func complete(
    contractID: String,
    dispatchID: String,
    receiptID: String? = nil,
    outputRef: String? = nil,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoDispatchRecord {
    try TatwoGoalRunDispatchLifecycle.update(
      contractID: contractID,
      dispatchID: dispatchID,
      status: .completed,
      receiptID: receiptID,
      outputRef: outputRef,
      goalStore: goalStore,
      dispatchRegistry: dispatchRegistry)
  }

  @discardableResult
  public static func fail(
    contractID: String,
    dispatchID: String,
    errorCode: String,
    message: String,
    failureClass: TatwoDispatchFailureClass = .unknown,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) throws -> TatwoDispatchRecord {
    try TatwoGoalRunDispatchLifecycle.update(
      contractID: contractID,
      dispatchID: dispatchID,
      status: .failed,
      failureClass: failureClass,
      errorCode: errorCode,
      errorMessage: message,
      goalStore: goalStore,
      dispatchRegistry: dispatchRegistry)
  }
}
