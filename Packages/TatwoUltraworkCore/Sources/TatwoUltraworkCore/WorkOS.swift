import CryptoKit
import Foundation

public enum TatwoAuthorityInstanceDiscriminatorError:
  Error, LocalizedError, Sendable, Equatable
{
  case empty
  case malformed

  public var errorDescription: String? {
    switch self {
    case .empty:
      return "Authority instance discriminator is empty."
    case .malformed:
      return "Authority instance discriminator is not canonical."
    }
  }
}

public enum TatwoGoalCandidateCreateOnlyError: Error, LocalizedError, Sendable, Equatable {
  case missingAuthorizationBindingArtifactSHA256
  case missingAuthorizationBindingArtifactJSON
  case authorizationBindingArtifactHashMismatch(expected: String, actual: String)
  case authorizationBindingArtifactDecodeFailed
  case authorizationBindingArtifactClosedWorldMismatch([String])
  case authorizationBindingArtifactSchemaMismatch(String)
  case authorizationBindingArtifactRouteMismatch(String)
  case authorizationBindingArtifactMaxInvocationsMismatch(Int)
  case authorizationBindingArtifactOperationNonceEmpty
  case authorizationBindingArtifactModeMismatch(expected: String, actual: String)
  case authorizationBindingArtifactScenarioMismatch(expected: String, actual: String)
  case authorizationBindingArtifactObjectiveMismatch(expected: String, actual: String)
  case authorizationBindingArtifactScenarioConfigMismatch(expected: String, actual: String)
  case authorizationBindingArtifactScenarioConfigSourceMismatch(expected: String, actual: String)
  case authorizationBindingArtifactScenarioConfigRawMismatch(expected: String, actual: String)
  case authorizationBindingArtifactContractMismatch(expected: String, actual: String)
  case authorizationBindingArtifactGoalMismatch(expected: String, actual: String)
  case authorizationBindingArtifactIdentityBindingsMismatch(expected: String, actual: String)
  case authorizationBindingArtifactProjectedContractCanonicalJSONMismatch(
    expected: String, actual: String)
  case authorizationBindingArtifactIdentityBindingsCanonicalJSONMismatch(
    expected: String, actual: String)
  case authorizationBindingArtifactStoreSchemaMismatch(expected: String, actual: String)
  case authorizationBindingArtifactStoreManifestMismatch(expected: String, actual: String)
  case authorizationBindingArtifactTargetJSONPathMismatch(expected: String, actual: String)
  case authorizationBindingArtifactTargetLockPathMismatch(expected: String, actual: String)
  case authorizationBindingArtifactTargetJSONMustBeAbsent
  case authorizationBindingArtifactTargetLockMustBeAbsent
  case authorizationBindingArtifactTargetMustBeAbsent
  case authorizationBindingArtifactTargetStoreMismatch(String)
  case storedCandidateInvariant(String)

  public var errorDescription: String? {
    switch self {
    case .missingAuthorizationBindingArtifactSHA256:
      return "missing_authorization_binding_artifact_sha256"
    case .missingAuthorizationBindingArtifactJSON:
      return "missing_authorization_binding_artifact_json"
    case let .authorizationBindingArtifactHashMismatch(expected, actual):
      return "authorization_binding_artifact_hash_mismatch:expected=\(expected):actual=\(actual)"
    case .authorizationBindingArtifactDecodeFailed:
      return "authorization_binding_artifact_decode_failed"
    case .authorizationBindingArtifactClosedWorldMismatch(let keys):
      return "authorization_binding_artifact_closed_world_mismatch:\(keys.joined(separator: ","))"
    case .authorizationBindingArtifactSchemaMismatch(let actual):
      return "authorization_binding_artifact_schema_mismatch:\(actual)"
    case .authorizationBindingArtifactRouteMismatch(let actual):
      return "authorization_binding_artifact_route_mismatch:\(actual)"
    case .authorizationBindingArtifactMaxInvocationsMismatch(let actual):
      return "authorization_binding_artifact_max_invocations_mismatch:\(actual)"
    case .authorizationBindingArtifactOperationNonceEmpty:
      return "authorization_binding_artifact_operation_nonce_empty"
    case let .authorizationBindingArtifactModeMismatch(expected, actual):
      return "authorization_binding_artifact_mode_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactScenarioMismatch(expected, actual):
      return "authorization_binding_artifact_scenario_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactObjectiveMismatch(expected, actual):
      return "authorization_binding_artifact_objective_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactScenarioConfigMismatch(expected, actual):
      return "authorization_binding_artifact_scenario_config_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactScenarioConfigSourceMismatch(expected, actual):
      return "authorization_binding_artifact_scenario_config_source_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactScenarioConfigRawMismatch(expected, actual):
      return "authorization_binding_artifact_scenario_config_raw_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactContractMismatch(expected, actual):
      return "authorization_binding_artifact_contract_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactGoalMismatch(expected, actual):
      return "authorization_binding_artifact_goal_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactIdentityBindingsMismatch(expected, actual):
      return "authorization_binding_artifact_identity_bindings_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactProjectedContractCanonicalJSONMismatch(
      expected, actual):
      return "authorization_binding_artifact_projected_contract_canonical_json_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactIdentityBindingsCanonicalJSONMismatch(
      expected, actual):
      return "authorization_binding_artifact_identity_bindings_canonical_json_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactStoreSchemaMismatch(expected, actual):
      return "authorization_binding_artifact_store_schema_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactStoreManifestMismatch(expected, actual):
      return "authorization_binding_artifact_store_manifest_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactTargetJSONPathMismatch(expected, actual):
      return "authorization_binding_artifact_target_json_path_mismatch:expected=\(expected):actual=\(actual)"
    case let .authorizationBindingArtifactTargetLockPathMismatch(expected, actual):
      return "authorization_binding_artifact_target_lock_path_mismatch:expected=\(expected):actual=\(actual)"
    case .authorizationBindingArtifactTargetJSONMustBeAbsent:
      return "authorization_binding_artifact_target_json_must_be_absent"
    case .authorizationBindingArtifactTargetLockMustBeAbsent:
      return "authorization_binding_artifact_target_lock_must_be_absent"
    case .authorizationBindingArtifactTargetMustBeAbsent:
      return "authorization_binding_artifact_target_must_be_absent"
    case .authorizationBindingArtifactTargetStoreMismatch(let contractID):
      return "authorization_binding_artifact_target_store_mismatch:\(contractID)"
    case .storedCandidateInvariant(let reason):
      return "stored_goal_candidate_invariant:\(reason)"
    }
  }
}

public struct TatwoGoalCandidateCreateAuthorizationBindingV1:
  Codable, Sendable, Equatable
{
  public static let currentSchema = "TatwoGoalCandidateCreateAuthorizationBindingV1"
  public static let createRoute = "tatwo.os.goal.candidate.create"
  public static let storeSchema = "TatwoGoalRunStoreV1"
  static let exactFieldNames: Set<String> = [
    "schema",
    "route",
    "maxInvocations",
    "operationNonce",
    "mode",
    "scenario",
    "objectiveSHA256",
    "scenarioConfigStableHash",
    "scenarioConfigSourceKind",
    "scenarioConfigRawSHA256",
    "contractID",
    "goalID",
    "issuedIdentityBindingsDigest",
    "projectedContractCanonicalJSONSHA256",
    "issuedIdentityBindingsCanonicalJSONSHA256",
    "storeSchema",
    "goalStorePreflightCanonicalManifestSHA256",
    "targetJSONPath",
    "targetLockPath",
    "targetJSONMustBeAbsent",
    "targetLockMustBeAbsent",
    "targetMustBeAbsent",
  ]

  public let schema: String
  public let route: String
  public let maxInvocations: Int
  public let operationNonce: String
  public let mode: String
  public let scenario: String
  public let objectiveSHA256: String
  public let scenarioConfigStableHash: String
  public let scenarioConfigSourceKind: String
  public let scenarioConfigRawSHA256: String
  public let contractID: String
  public let goalID: String
  public let issuedIdentityBindingsDigest: String
  public let projectedContractCanonicalJSONSHA256: String
  public let issuedIdentityBindingsCanonicalJSONSHA256: String
  public let storeSchema: String
  public let goalStorePreflightCanonicalManifestSHA256: String
  public let targetJSONPath: String
  public let targetLockPath: String
  public let targetJSONMustBeAbsent: Bool
  public let targetLockMustBeAbsent: Bool
  public let targetMustBeAbsent: Bool

  public init(
    schema: String = Self.currentSchema,
    route: String = Self.createRoute,
    maxInvocations: Int = 1,
    operationNonce: String,
    mode: String,
    scenario: String,
    objectiveSHA256: String,
    scenarioConfigStableHash: String,
    scenarioConfigSourceKind: String,
    scenarioConfigRawSHA256: String,
    contractID: String,
    goalID: String,
    issuedIdentityBindingsDigest: String,
    projectedContractCanonicalJSONSHA256: String,
    issuedIdentityBindingsCanonicalJSONSHA256: String,
    storeSchema: String = Self.storeSchema,
    goalStorePreflightCanonicalManifestSHA256: String,
    targetJSONPath: String,
    targetLockPath: String,
    targetJSONMustBeAbsent: Bool = true,
    targetLockMustBeAbsent: Bool = true,
    targetMustBeAbsent: Bool = true
  ) {
    self.schema = schema
    self.route = route
    self.maxInvocations = maxInvocations
    self.operationNonce = operationNonce
    self.mode = mode
    self.scenario = scenario
    self.objectiveSHA256 = objectiveSHA256
    self.scenarioConfigStableHash = scenarioConfigStableHash
    self.scenarioConfigSourceKind = scenarioConfigSourceKind
    self.scenarioConfigRawSHA256 = scenarioConfigRawSHA256
    self.contractID = contractID
    self.goalID = goalID
    self.issuedIdentityBindingsDigest = issuedIdentityBindingsDigest
    self.projectedContractCanonicalJSONSHA256 =
      projectedContractCanonicalJSONSHA256
    self.issuedIdentityBindingsCanonicalJSONSHA256 =
      issuedIdentityBindingsCanonicalJSONSHA256
    self.storeSchema = storeSchema
    self.goalStorePreflightCanonicalManifestSHA256 =
      goalStorePreflightCanonicalManifestSHA256
    self.targetJSONPath = targetJSONPath
    self.targetLockPath = targetLockPath
    self.targetJSONMustBeAbsent = targetJSONMustBeAbsent
    self.targetLockMustBeAbsent = targetLockMustBeAbsent
    self.targetMustBeAbsent = targetMustBeAbsent
  }
}

public struct TatwoGoalCandidateCreateOnlyResultV1: Codable, Sendable, Equatable {
  public let schema: String
  public let route: String
  public let authorizationFenceSchema: String
  public let handlerFenceVersion: String
  public let authorizationBindingArtifactSHA256: String
  public let scenarioConfigStableHash: String
  public let storePreflight: TatwoGoalCandidateStorePreflightV1
  public let contract: TatwoWorkOSContractV1
  public let storeDisposition: TatwoGoalCandidateCreateOnlyStoreDispositionV1
  public let candidateResolvedRevision: UInt64

  public init(
    schema: String = "TatwoGoalCandidateCreateOnlyResultV1",
    route: String = TatwoGoalCandidateCreateAuthorizationBindingV1.createRoute,
    authorizationFenceSchema: String =
      TatwoGoalCandidateCreateAuthorizationBindingV1.currentSchema,
    handlerFenceVersion: String = "TatwoGoalCandidateCreateHandlerFenceV1",
    authorizationBindingArtifactSHA256: String,
    scenarioConfigStableHash: String,
    storePreflight: TatwoGoalCandidateStorePreflightV1,
    contract: TatwoWorkOSContractV1,
    storeDisposition: TatwoGoalCandidateCreateOnlyStoreDispositionV1,
    candidateResolvedRevision: UInt64
  ) {
    self.schema = schema
    self.route = route
    self.authorizationFenceSchema = authorizationFenceSchema
    self.handlerFenceVersion = handlerFenceVersion
    self.authorizationBindingArtifactSHA256 = authorizationBindingArtifactSHA256
    self.scenarioConfigStableHash = scenarioConfigStableHash
    self.storePreflight = storePreflight
    self.contract = contract
    self.storeDisposition = storeDisposition
    self.candidateResolvedRevision = candidateResolvedRevision
  }
}

public enum WorkOSFactory {
  private enum RouteTopologyError: Error, LocalizedError {
    case missingIdentity(IdentityKind)
    case conflictingEffort(modelID: String, phase: TatwoScenarioPhase)

    var errorDescription: String? {
      switch self {
      case .missingIdentity(let identity):
        return "Route picker override cannot be represented: contract has no \(identity.chineseName) binding."
      case .conflictingEffort(let modelID, let phase):
        return "Route picker override creates conflicting effort bindings for \(modelID) during \(phase.rawValue)."
      }
    }
  }

  private struct RoleIntentOverride: Equatable {
    let id: String
    let requiredReceipts: [WorkOSReceiptRequirement]
    let stopRules: [String]
    let mainlinePhases: [String]
    let nextStepSuffix: String?

    var isFable5LeadGPT55Loops: Bool {
      id == "fable5-lead-gpt55-loops"
    }

    static let none = RoleIntentOverride(
      id: "none",
      requiredReceipts: [],
      stopRules: [],
      mainlinePhases: [],
      nextStepSuffix: nil)
  }

  public static func inferContext(goalID: String?, contractID: String?) -> WorkOSContractContext? {
    for rawID in [contractID, goalID].compactMap({
      $0?.trimmingCharacters(in: .whitespacesAndNewlines)
    }) {
      guard !rawID.isEmpty else { continue }
      let tail: Substring
      if rawID.hasPrefix("goal-") {
        tail = rawID.dropFirst("goal-".count)
      } else if rawID.hasPrefix("contract-") {
        tail = rawID.dropFirst("contract-".count)
      } else {
        continue
      }

      let parts = tail.split(separator: "-", omittingEmptySubsequences: true)
      guard parts.count >= 3 else { continue }
      let hash = parts.last.map(String.init) ?? ""
      guard hash.count == 12, hash.allSatisfy({ $0.isHexDigit }) else { continue }
      guard let mode = try? WorkModeID.parse(String(parts[0]).uppercased()) else { continue }
      let scenario = parts.dropFirst().dropLast().joined(separator: "-")
      guard !scenario.isEmpty else { continue }
      return WorkOSContractContext(mode: mode, scenarioProfileID: scenario)
    }
    return nil
  }

  /// Rebuild the canonical contract projection for a contractID that was already issued into
  /// `TatwoGoalRunStore`.
  ///
  /// This is intentionally a projection, not a new `beginCanonical`: dashboard/enforce/handoff surfaces
  /// often need the full `TatwoWorkOSContractV1`, but they must not trust caller-supplied
  /// mode/scenario/objective values or silently mint a fresh contract that happens to disagree
  /// with the stored ledger. When a contractID is supplied, the stored GoalRun is the authority.
  public static func storedContractProjection(
    contractID rawContractID: String?,
    fallbackMode: WorkModeID,
    fallbackScenarioProfileID: String,
    fallbackObjective: String = "Tatwo Work OS goal",
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    store: TatwoGoalRunStore = .default()
  ) throws -> TatwoWorkOSContractV1 {
    let normalizedContractID = rawContractID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !normalizedContractID.isEmpty else {
      return try projectContract(
        mode: fallbackMode,
        scenarioProfileID: fallbackScenarioProfileID,
        objective: fallbackObjective,
        catalog: catalog,
        scenarioBook: scenarioBook)
    }

    let snapshot = try store.snapshot(forContractID: normalizedContractID)
    return try storedContractProjection(
      snapshot: snapshot,
      catalog: catalog,
      scenarioBook: scenarioBook,
      store: store)
  }

  /// Rebuild a contract from the exact GoalRun revision supplied by the caller.
  ///
  /// This overload never re-reads the GoalRun. Callers that also read dispatch
  /// state can therefore verify the same snapshot after that read and before
  /// publishing the combined projection.
  public static func storedContractProjection(
    snapshot: TatwoGoalRunSnapshotV1,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    store: TatwoGoalRunStore = .default()
  ) throws -> TatwoWorkOSContractV1 {
    let record = snapshot.record
    let contract = try projectContract(
      mode: record.mode,
      scenarioProfileID: record.scenario,
      objective: record.objective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      routeBindingOverride: record.routeBindingOverride,
      authorityInstanceDiscriminator: record.authorityInstanceDiscriminator)
    guard contract.contractID == record.contractID else {
      throw TatwoGoalRunStoreError.unregisteredContract(record.contractID)
    }
    _ = try store.verifyIssuedIdentityBindingsIfPresent(
      contract: contract,
      record: record)
    return applyingStoredStatus(record.status, to: contract)
  }

  /// Pure preview projection for UI / MCP read paths.
  public static func preview(
    mode: WorkModeID,
    scenarioProfileID: String,
    objective: String = "Tatwo Work OS goal",
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    loopPresetID: String? = nil,
    enabledLoopTemplateIDs: [String]? = nil,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil
  ) throws -> TatwoWorkOSContractV1 {
    try projectContract(
      mode: mode,
      scenarioProfileID: scenarioProfileID,
      objective: objective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      loopPresetID: loopPresetID,
      enabledLoopTemplateIDs: enabledLoopTemplateIDs,
      routeBindingOverride: routeBindingOverride)
  }

  private static func applyingStoredStatus(
    _ status: GoalRunStatus,
    to contract: TatwoWorkOSContractV1
  ) -> TatwoWorkOSContractV1 {
    let goalRun = GoalRun(
      schema: contract.goalRun.schema,
      goalID: contract.goalRun.goalID,
      contractID: contract.goalRun.contractID,
      objective: contract.goalRun.objective,
      mode: contract.goalRun.mode,
      scenario: contract.goalRun.scenario,
      status: status,
      currentLoopID: contract.goalRun.currentLoopID,
      createdAt: contract.goalRun.createdAt,
      // The initial durable GoalRun is created from this projection. Preserve
      // its canonical planned reason so begin's exact readback remains the
      // same authority contract that was issued; later lifecycle states still
      // report that their status came from the durable store.
      statusReason: status == contract.goalRun.status
        ? contract.goalRun.statusReason
        : "GoalRun status loaded from TatwoGoalRunStore: \(status.rawValue).")
    let mainlineLoop = MainlineLoop(
      id: contract.mainlineLoop.id,
      title: contract.mainlineLoop.title,
      ownerIdentity: contract.mainlineLoop.ownerIdentity,
      objective: contract.mainlineLoop.objective,
      phases: contract.mainlineLoop.phases,
      allowedTools: contract.mainlineLoop.allowedTools,
      requiredReceipts: contract.mainlineLoop.requiredReceipts,
      reviewerGateRequired: contract.mainlineLoop.reviewerGateRequired,
      status: status,
      nextStep: contract.mainlineLoop.nextStep)
    let showLoopsProjection = makeShowLoopsProjection(
      goalID: contract.goalID,
      contractID: contract.contractID,
      goalStatus: status,
      mainlineLoop: mainlineLoop,
      domainLoops: contract.domainLoops,
      receipts: contract.receiptRequirements,
      sandboxPolicy: contract.sandboxPolicy)

    return TatwoWorkOSContractV1(
      schema: contract.schema,
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      goalCyclePolicy: contract.goalCyclePolicy,
      planLoopGoalProtocol: contract.planLoopGoalProtocol,
      goalRun: goalRun,
      loopGovernorDecision: contract.loopGovernorDecision,
      mainlineLoop: mainlineLoop,
      domainLoops: contract.domainLoops,
      identityBindings: contract.identityBindings,
      routeBindingOverride: contract.routeBindingOverride,
      authorityInstanceDiscriminator: contract.authorityInstanceDiscriminator,
      sandboxPolicy: contract.sandboxPolicy,
      receiptRequirements: contract.receiptRequirements,
      stopRules: contract.stopRules,
      showLoopsProjection: showLoopsProjection,
      configStage: contract.configStage,
      gatewayRouteReservations: contract.gatewayRouteReservations,
      nextAction: contract.nextAction,
      failClosedRules: contract.failClosedRules)
  }

  /// Pure contract construction shared by initial issuance and durable rehydration.
  ///
  /// This function must never write GoalRun or dispatch-registry state. `beginCanonical` is the
  /// only issuance boundary; stored projections call this constructor directly so a
  /// reconnect cannot accidentally mint, activate, or re-record a GoalRun.
  public static func projectContract(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String,
    objective rawObjective: String = "Tatwo Work OS goal",
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    loopPresetID: String? = nil,
    enabledLoopTemplateIDs: [String]? = nil,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    authorityInstanceDiscriminator: String? = nil
  ) throws -> TatwoWorkOSContractV1 {
    let scenarioContext = try resolveScenarioContext(
      rawScenarioProfileID,
      scenarioBook: scenarioBook)
    let profile = scenarioContext.profile
    let scenario = scenarioContext.scenarioID
    let objective = sanitizedObjective(rawObjective)
    let modePlan = TatwoIdentityCatalog.modePlan(
      mode: mode, scenarioProfileID: profile.id, catalog: catalog)
    let governorDecision = TatwoLoopGovernor.decide(
      mode: mode,
      scenarioID: scenario,
      scenarioBook: scenarioBook)
    let normalizedRouteBindingOverride =
      routeBindingOverride?.isEmpty == false ? routeBindingOverride : nil
    // Explicit picker bindings outrank legacy objective-text role inference.
    // Both the runtime effort resolver and execution manifest must consume the
    // same topology, so rewrite the governor projection first and derive
    // identityBindings from that exact projection.
    let inferredRoleIntentOverride = roleIntentOverride(for: objective)
    // A declared Scenario modeConfig remains authoritative even when every
    // binding is empty, disabled, or invalid and the governor activates zero
    // slots. Only a truly absent modeConfig may use the legacy objective shim.
    let configuredTopologyPresent =
      scenarioBook.modeConfig(scenarioID: scenario, mode: mode) != nil
    let roleIntentOverride =
      normalizedRouteBindingOverride == nil && !configuredTopologyPresent
      ? inferredRoleIntentOverride
      : .none
    let effectiveGovernorDecision = try applyingRouteBindingOverride(
      normalizedRouteBindingOverride,
      to: governorDecision)
    let identityBindings = try applyingRouteBindingOverride(
      normalizedRouteBindingOverride,
      to: makeIdentityBindings(
        from: modePlan.identitySlots,
        governorDecision: effectiveGovernorDecision,
        configuredTopologyPresent: configuredTopologyPresent,
        routeBindingOverridePresent: normalizedRouteBindingOverride != nil,
        roleIntentOverride: roleIntentOverride))
    let scopedDiscriminator = try normalizedAuthorityInstanceDiscriminator(
      authorityInstanceDiscriminator)
    let hash: String
    if let scopedDiscriminator {
      let canonicalIdentity = TatwoAuthorityScopedContractIdentityV1(
        mode: mode.rawValue,
        scenario: scenario,
        objective: objective,
        routeBindingOverride: normalizedRouteBindingOverride,
        authorityInstanceDiscriminator: scopedDiscriminator)
      hash = try shortHash(canonicalJSONData(canonicalIdentity))
    } else {
      // Nil remains byte-for-byte compatible with the legacy ID derivation.
      // Only authority-scoped rows use the unambiguous canonical envelope.
      let baseContractIdentity = "\(mode.rawValue)|\(scenario)|\(objective)"
      let legacyContractIdentity = normalizedRouteBindingOverride.map {
        "\(baseContractIdentity)|\($0.contractIdentity)"
      } ?? baseContractIdentity
      hash = shortHash(legacyContractIdentity)
    }
    let goalID = "goal-\(mode.rawValue.lowercased())-\(scenario)-\(hash)"
    let contractID = "contract-\(mode.rawValue.lowercased())-\(scenario)-\(hash)"
    let initialBaseReceipts = uniqueReceipts(
      makeBaseReceipts(mode: mode, profile: profile) + roleIntentOverride.requiredReceipts)
    let selectedLoopTemplates = loopTemplates(
      for: mode,
      profile: profile,
      loopPresetID: loopPresetID,
      enabledLoopTemplateIDs: enabledLoopTemplateIDs)
    let isCustomLoopSelection = enabledLoopTemplateIDs != nil || loopPresetID != nil
    let unboundBaseLoops = selectedLoopTemplates.flatMap {
      makeDomainLoops(template: $0, mode: mode, profile: profile, contractID: contractID)
    }
    let baseLoops = bindDomainLoopsToIssuedSourceSlots(
      unboundBaseLoops,
      governorDecision: effectiveGovernorDecision)
    // T1/T7: 預設 loop 數大於 domain 模板數時，以 cycle 實例（同域 c2/c3/…，各自是
    // 完整子 plan+loops+goal）補足規模；自定義選單則完全尊重呼叫者列表不展開。
    let domainLoops =
      isCustomLoopSelection
      ? baseLoops
      : expandLoopsToTarget(baseLoops, target: maxLoopCount(for: mode, custom: false))
    let fanOutHardeningReceipts = fanOutReceipts(mode: mode, hasFanOut: !domainLoops.isEmpty)
    let baseReceipts = uniqueReceipts(initialBaseReceipts + fanOutHardeningReceipts)
    let domainReceipts = domainLoops.flatMap(\.requiredReceipts)
    let receipts = uniqueReceipts(baseReceipts + domainReceipts)
    let mainline = makeMainlineLoop(
      goalID: goalID,
      contractID: contractID,
      mode: mode,
      profile: profile,
      objective: objective,
      receipts: baseReceipts,
      roleIntentOverride: roleIntentOverride)
    let sandboxPolicy = makeSandboxPolicy(mode: mode)
    let stopRules = uniqueStrings(
      makeStopRules(mode: mode, modePlan: modePlan, profile: profile, hasFanOut: !domainLoops.isEmpty)
        + roleIntentOverride.stopRules)
    let goalStatus: GoalRunStatus = .planned
    let showLoopsProjection = makeShowLoopsProjection(
      goalID: goalID,
      contractID: contractID,
      goalStatus: goalStatus,
      mainlineLoop: mainline,
      domainLoops: domainLoops,
      receipts: receipts,
      sandboxPolicy: sandboxPolicy)
    let goalRun = GoalRun(
      goalID: goalID,
      contractID: contractID,
      objective: objective,
      mode: mode,
      scenario: scenario,
      status: goalStatus,
      currentLoopID: mainline.id,
      statusReason: mode >= .xl
        ? "XL 已規劃 mainline + domain loops；需沙盒與人工 gate 後才可實裝。"
        : "已建立 Work OS contract；下一步由 tatwo.os.next 指派。")
    let nextAction = [
      "呼叫 tatwo.os.next --goal \(goalID) --contract \(contractID)，不要讓 agent 自己猜下一步。",
      roleIntentOverride.nextStepSuffix,
    ].compactMap { $0 }.joined(separator: " ")
    let contract = TatwoWorkOSContractV1(
      goalID: goalID,
      contractID: contractID,
      mode: mode,
      scenario: scenario,
      objective: objective,
      goalCyclePolicy: TatwoArenaPolicyFactory.goalCyclePolicy,
      planLoopGoalProtocol: TatwoArenaPolicyFactory.planLoopGoalProtocol(catalog: catalog),
      goalRun: goalRun,
      loopGovernorDecision: effectiveGovernorDecision,
      mainlineLoop: mainline,
      domainLoops: domainLoops,
      identityBindings: identityBindings,
      routeBindingOverride: normalizedRouteBindingOverride,
      authorityInstanceDiscriminator: scopedDiscriminator,
      sandboxPolicy: sandboxPolicy,
      receiptRequirements: receipts,
      stopRules: stopRules,
      showLoopsProjection: showLoopsProjection,
      configStage: .staging,
      gatewayRouteReservations: gatewayRouteReservations(),
      nextAction: nextAction,
	      failClosedRules: uniqueStrings([
          "任何 agent action 沒有 contractID 一律 fail closed。",
          "App 只是 OS 控制台與可視化投影，不能直接放行 goal。",
          "所有 OS 設定先寫 staging config；sandbox selftest 通過後才可升 active config。",
          "驗收成功後必須提交 cleanup-inventory Markdown 盤點；未經人工確認不真刪檔。",
          "不改 signed Codex App bundle、不寫真實 LaunchAgent、不觸碰 auth/session。",
          "核心語義：plan → loops → cycles → goal；每個 cycle 內部是完整子 plan+loops+goal，正式 goal 的 cycle 數不設上限（受 token/風險/人工 gate 控制）；5-cycle 上限僅適用評分沙盒 seal 前。",
        ] + dispatchSupervisionHardRules(hasFanOut: !domainLoops.isEmpty) + roleIntentOverride.stopRules))
    return contract
  }

  public static func previewModePlan(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String? = nil,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    contract: TatwoWorkOSContractV1? = nil
  ) throws -> ModeIdentityPlan {
    let effectiveContract: TatwoWorkOSContractV1
    let baseMode: WorkModeID
    let baseScenarioProfileID: String?
    if let contract {
      effectiveContract = contract
      baseMode = contract.mode
      let requestedScenarioID =
        rawScenarioProfileID?.trimmingCharacters(in: .whitespacesAndNewlines)
      let metadataScenarioID: String
      if let requestedScenarioID, !requestedScenarioID.isEmpty {
        metadataScenarioID = requestedScenarioID
      } else {
        metadataScenarioID = contract.scenario
      }
      baseScenarioProfileID =
        TatwoIdentityCatalog.scenarioProfile(metadataScenarioID)?.id
        ?? scenarioBook.scenario(id: metadataScenarioID)?.baseScenario.map(profileID(for:))
    } else {
      let resolvedScenario = try resolveScenarioContext(
        rawScenarioProfileID ?? "coding",
        scenarioBook: scenarioBook)
      baseMode = mode
      baseScenarioProfileID = resolvedScenario.profile.id
      effectiveContract = try preview(
        mode: mode,
        scenarioProfileID: resolvedScenario.scenarioID,
        catalog: catalog,
        scenarioBook: scenarioBook)
    }
    let base = TatwoIdentityCatalog.modePlan(
      mode: baseMode,
      scenarioProfileID: baseScenarioProfileID,
      catalog: catalog)
    let previewSlots = effectiveContract.identityBindings.map { binding -> IdentitySlot in
      let templateSlot =
        base.identitySlots.first { $0.id == binding.sourceSlotID }
        ?? base.identitySlots.first { $0.kind == binding.identity }
      let candidates: [IdentityCandidate]
      if let engineID = binding.engineID, let modelID = binding.modelID {
        candidates = [
          IdentityCandidate(
            engineID: engineID,
            modelID: modelID,
            fitScore: 5,
            authority: binding.authority,
            canMutateHost: binding.canMutateHost,
            bestWhen: binding.bindingRule,
            caution: binding.bindingRule)
        ]
      } else {
        candidates = []
      }
      return IdentitySlot(
        id: binding.sourceSlotID,
        kind: binding.identity,
        label: binding.label,
        required: templateSlot?.required ?? true,
        budgetWeight: templateSlot?.budgetWeight ?? 1.0,
        helperCap: templateSlot?.helperCap ?? 0,
        responsibilities: templateSlot?.responsibilities ?? [binding.bindingRule],
        requiredEvidence: templateSlot?.requiredEvidence ?? [],
        candidates: candidates)
    }
    return ModeIdentityPlan(
      mode: base.mode,
      chineseName: base.chineseName,
      budgetLabel: base.budgetLabel,
      helperLimit: base.helperLimit,
      roundLimit: base.roundLimit,
      sandboxRequired: base.sandboxRequired,
      humanApprovalRequired: base.humanApprovalRequired,
      identitySlots: previewSlots,
      requiredReceipts: effectiveContract.receiptRequirements.map(\.id),
      stopRules: effectiveContract.stopRules)
  }

  /// Begin one new formal Work OS authority transaction.
  ///
  /// The typed canonical owner is carried unchanged into the durable plan,
  /// transaction intent, and V3 pointer. Rehydrate, dashboard, reconnect, and
  /// attach paths must use `storedContractProjection` instead.
  public static func beginCanonical(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String,
    objective rawObjective: String = "Tatwo Work OS goal",
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    loopPresetID: String? = nil,
    enabledLoopTemplateIDs: [String]? = nil,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    authorityInstanceDiscriminator: String? = nil,
    store: TatwoGoalRunStore,
    registry: TatwoDispatchRegistry,
    sessionStore: TatwoSessionStore,
    owner: TatwoCanonicalSessionOwnerV1
  ) throws -> TatwoSessionAttachmentV1 {
    let contract = try projectContract(
      mode: mode,
      scenarioProfileID: rawScenarioProfileID,
      objective: rawObjective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      loopPresetID: loopPresetID,
      enabledLoopTemplateIDs: enabledLoopTemplateIDs,
      routeBindingOverride: routeBindingOverride,
      authorityInstanceDiscriminator: authorityInstanceDiscriminator)
    return try TatwoGoalAuthorityTransaction(
      sessionStore: sessionStore,
      goalStore: store,
      dispatchRegistry: registry
    ).begin(
      contract: contract,
      owner: owner,
      scenarioBook: scenarioBook).attachment
  }

  /// Create a fresh, store-only Goal candidate without activating any runtime surface.
  ///
  /// The stored GoalRun intentionally remains a legacy-resolved revision 1
  /// (`revision == nil`). This route does not accept or derive a successor
  /// revision: a later predecessor-bound, human-gated promotion owns that
  /// authority.
  public static func createGoalCandidateOnly(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String,
    objective rawObjective: String = "Tatwo Work OS goal",
    authorizationBindingArtifactSHA256 rawAuthorizationBindingArtifactSHA256: String,
    authorizationBindingArtifactJSON rawAuthorizationBindingArtifactJSON: String,
    scenarioConfigSourceKind: String,
    scenarioConfigRawSHA256: String,
    catalog: TatwoCatalog = .defaults,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    loopPresetID: String? = nil,
    enabledLoopTemplateIDs: [String]? = nil,
    routeBindingOverride: WorkOSRouteBindingOverride? = nil,
    store: TatwoGoalRunStore
  ) throws -> TatwoGoalCandidateCreateOnlyResultV1 {
    guard !rawAuthorizationBindingArtifactSHA256
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw TatwoGoalCandidateCreateOnlyError
        .missingAuthorizationBindingArtifactSHA256
    }
    guard !rawAuthorizationBindingArtifactJSON.isEmpty else {
      throw TatwoGoalCandidateCreateOnlyError
        .missingAuthorizationBindingArtifactJSON
    }
    let authorizationArtifactBytes = Data(rawAuthorizationBindingArtifactJSON.utf8)
    let computedAuthorizationArtifactSHA256 = sha256(authorizationArtifactBytes)
    guard rawAuthorizationBindingArtifactSHA256 == computedAuthorizationArtifactSHA256 else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactHashMismatch(
        expected: rawAuthorizationBindingArtifactSHA256,
        actual: computedAuthorizationArtifactSHA256)
    }
    let artifactObject: [String: Any]
    do {
      guard let decodedObject = try JSONSerialization.jsonObject(
        with: authorizationArtifactBytes,
        options: []) as? [String: Any]
      else {
        throw TatwoGoalCandidateCreateOnlyError
          .authorizationBindingArtifactDecodeFailed
      }
      artifactObject = decodedObject
    } catch let error as TatwoGoalCandidateCreateOnlyError {
      throw error
    } catch {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactDecodeFailed
    }
    let artifactFieldNames = Set(artifactObject.keys)
    guard artifactFieldNames
      == TatwoGoalCandidateCreateAuthorizationBindingV1.exactFieldNames
    else {
      let fieldDelta = artifactFieldNames
        .symmetricDifference(
          TatwoGoalCandidateCreateAuthorizationBindingV1.exactFieldNames)
        .sorted()
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactClosedWorldMismatch(fieldDelta)
    }
    let authorizationArtifact: TatwoGoalCandidateCreateAuthorizationBindingV1
    do {
      authorizationArtifact = try JSONDecoder().decode(
        TatwoGoalCandidateCreateAuthorizationBindingV1.self,
        from: authorizationArtifactBytes)
    } catch {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactDecodeFailed
    }
    guard authorizationArtifact.schema
      == TatwoGoalCandidateCreateAuthorizationBindingV1.currentSchema
    else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactSchemaMismatch(
        authorizationArtifact.schema)
    }
    guard authorizationArtifact.route
      == TatwoGoalCandidateCreateAuthorizationBindingV1.createRoute
    else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactRouteMismatch(
        authorizationArtifact.route)
    }
    guard authorizationArtifact.maxInvocations == 1 else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactMaxInvocationsMismatch(
          authorizationArtifact.maxInvocations)
    }
    guard !authorizationArtifact.operationNonce
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactOperationNonceEmpty
    }
    let contract = try projectContract(
      mode: mode,
      scenarioProfileID: rawScenarioProfileID,
      objective: rawObjective,
      catalog: catalog,
      scenarioBook: scenarioBook,
      loopPresetID: loopPresetID,
      enabledLoopTemplateIDs: enabledLoopTemplateIDs,
      routeBindingOverride: routeBindingOverride)
    let objectiveSHA256 = sha256(Data(contract.objective.utf8))
    let issuedIdentityBindings = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
    let issuedIdentityBindingsDigest =
      TatwoIssuedIdentityBindingV1.deterministicDigest(for: issuedIdentityBindings)
    let projectedContractCanonicalJSONSHA256 =
      try canonicalJSONSHA256(contract)
    let issuedIdentityBindingsCanonicalJSONSHA256 =
      try canonicalJSONSHA256(issuedIdentityBindings)
    guard authorizationArtifact.mode == contract.mode.rawValue else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactModeMismatch(
        expected: contract.mode.rawValue,
        actual: authorizationArtifact.mode)
    }
    guard authorizationArtifact.scenario == contract.scenario else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactScenarioMismatch(
        expected: contract.scenario,
        actual: authorizationArtifact.scenario)
    }
    guard authorizationArtifact.objectiveSHA256 == objectiveSHA256 else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactObjectiveMismatch(
        expected: objectiveSHA256,
        actual: authorizationArtifact.objectiveSHA256)
    }
    guard authorizationArtifact.scenarioConfigStableHash == scenarioBook.stableHash else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactScenarioConfigMismatch(
          expected: scenarioBook.stableHash,
          actual: authorizationArtifact.scenarioConfigStableHash)
    }
    guard authorizationArtifact.scenarioConfigSourceKind == scenarioConfigSourceKind else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactScenarioConfigSourceMismatch(
          expected: scenarioConfigSourceKind,
          actual: authorizationArtifact.scenarioConfigSourceKind)
    }
    guard authorizationArtifact.scenarioConfigRawSHA256 == scenarioConfigRawSHA256 else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactScenarioConfigRawMismatch(
          expected: scenarioConfigRawSHA256,
          actual: authorizationArtifact.scenarioConfigRawSHA256)
    }
    guard authorizationArtifact.contractID == contract.contractID else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactContractMismatch(
        expected: contract.contractID,
        actual: authorizationArtifact.contractID)
    }
    guard authorizationArtifact.goalID == contract.goalID else {
      throw TatwoGoalCandidateCreateOnlyError.authorizationBindingArtifactGoalMismatch(
        expected: contract.goalID,
        actual: authorizationArtifact.goalID)
    }
    guard authorizationArtifact.issuedIdentityBindingsDigest
      == issuedIdentityBindingsDigest
    else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactIdentityBindingsMismatch(
          expected: issuedIdentityBindingsDigest,
          actual: authorizationArtifact.issuedIdentityBindingsDigest)
    }
    guard authorizationArtifact.projectedContractCanonicalJSONSHA256
      == projectedContractCanonicalJSONSHA256
    else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactProjectedContractCanonicalJSONMismatch(
          expected: projectedContractCanonicalJSONSHA256,
          actual: authorizationArtifact.projectedContractCanonicalJSONSHA256)
    }
    guard authorizationArtifact.issuedIdentityBindingsCanonicalJSONSHA256
      == issuedIdentityBindingsCanonicalJSONSHA256
    else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactIdentityBindingsCanonicalJSONMismatch(
          expected: issuedIdentityBindingsCanonicalJSONSHA256,
          actual: authorizationArtifact.issuedIdentityBindingsCanonicalJSONSHA256)
    }
    let storePreflight = try store.preflightCandidateCreate(
      contractID: contract.contractID)
    guard authorizationArtifact.storeSchema == storePreflight.storeSchema else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactStoreSchemaMismatch(
          expected: storePreflight.storeSchema,
          actual: authorizationArtifact.storeSchema)
    }
    guard authorizationArtifact.goalStorePreflightCanonicalManifestSHA256
      == storePreflight.canonicalManifestSHA256
    else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactStoreManifestMismatch(
          expected: storePreflight.canonicalManifestSHA256,
          actual: authorizationArtifact.goalStorePreflightCanonicalManifestSHA256)
    }
    guard authorizationArtifact.targetJSONPath == storePreflight.targetJSONPath else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactTargetJSONPathMismatch(
          expected: storePreflight.targetJSONPath,
          actual: authorizationArtifact.targetJSONPath)
    }
    guard authorizationArtifact.targetLockPath == storePreflight.targetLockPath else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactTargetLockPathMismatch(
          expected: storePreflight.targetLockPath,
          actual: authorizationArtifact.targetLockPath)
    }
    guard authorizationArtifact.targetJSONMustBeAbsent else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactTargetJSONMustBeAbsent
    }
    guard authorizationArtifact.targetLockMustBeAbsent else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactTargetLockMustBeAbsent
    }
    guard authorizationArtifact.targetMustBeAbsent else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactTargetMustBeAbsent
    }
    guard storePreflight.targetJSONAbsent,
      storePreflight.targetLockAbsent,
      storePreflight.targetAbsent
    else {
      throw TatwoGoalCandidateCreateOnlyError
        .authorizationBindingArtifactTargetStoreMismatch(contract.contractID)
    }
    let disposition = try store.createCandidateOnly(
      contract: contract,
      authorizationBindingArtifactSHA256: computedAuthorizationArtifactSHA256,
      expectedPreflight: storePreflight)
    let record = disposition.record
    guard record.contractID == contract.contractID,
      record.goalID == contract.goalID,
      record.status == .planned,
      record.revision == nil,
      record.resolvedRevision == 1
    else {
      throw TatwoGoalCandidateCreateOnlyError.storedCandidateInvariant(
        contract.contractID)
    }
    return TatwoGoalCandidateCreateOnlyResultV1(
      authorizationBindingArtifactSHA256: computedAuthorizationArtifactSHA256,
      scenarioConfigStableHash: scenarioBook.stableHash,
      storePreflight: storePreflight,
      contract: contract,
      storeDisposition: disposition,
      candidateResolvedRevision: record.resolvedRevision)
  }

  public static func next(
    goalID: String?,
    contractID: String?,
    mode: WorkModeID,
    scenarioProfileID: String,
    objective: String = "Tatwo Work OS goal",
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    store: TatwoGoalRunStore? = nil,
    registry: TatwoDispatchRegistry? = nil
  ) throws -> TatwoWorkOSNextAction {
    let gate = requireContractID(contractID)
    guard gate.ok else {
      return TatwoWorkOSNextAction(
        ok: false,
        goalID: goalID,
        contractID: contractID,
        currentLoopID: nil,
        nextStep: "blocked: missing contractID",
        requiredReceiptsBeforePass: [],
        decision: gate)
    }
    // With a store, next answers from the real ledger: the contract must be one
    // begin actually issued, mode/scenario/objective come from the stored run
    // (not caller assertion), and already-journaled receipts drop out of the
    // remaining-required list. Legacy callers (store == nil) keep the
    // caller-asserted behavior.
    var effectiveMode = mode
    var effectiveScenario = scenarioProfileID
    var effectiveObjective = objective
    var storedReceiptIDs: Set<String>? = nil
    var storedStatus: GoalRunStatus? = nil
    var storedSnapshot: TatwoGoalRunSnapshotV1? = nil
    if let store {
      let snapshot: TatwoGoalRunSnapshotV1
      do {
        snapshot = try store.snapshot(forContractID: contractID ?? "")
      } catch {
        return TatwoWorkOSNextAction(
          ok: false,
          goalID: goalID,
          contractID: contractID,
          currentLoopID: nil,
          nextStep: "blocked: unregistered contractID",
          requiredReceiptsBeforePass: [],
          decision: WorkOSGateDecision(
            ok: false,
            code: "unregistered_contract",
            message: "next 的 contractID 未由 tatwo.os.begin 登記；fail closed。\(error.localizedDescription)"))
      }
      let record = snapshot.record
      storedSnapshot = snapshot
      effectiveMode = record.mode
      effectiveScenario = record.scenario
      effectiveObjective = record.objective
      storedReceiptIDs = record.submittedReceiptIDs
      storedStatus = record.status
    }
    let contract: TatwoWorkOSContractV1
    if let store, let storedSnapshot {
      contract = try storedContractProjection(
        snapshot: storedSnapshot,
        scenarioBook: scenarioBook,
        store: store)
    } else {
      contract = try projectContract(
        mode: effectiveMode,
        scenarioProfileID: effectiveScenario,
        objective: effectiveObjective,
        scenarioBook: scenarioBook)
    }
    let resolvedGoalID = goalID ?? contract.goalID
    let resolvedContractID = contractID ?? contract.contractID
    let mainline = remapMainline(contract.mainlineLoop, goalID: resolvedGoalID)
    let requiredIDs = contract.receiptRequirements.filter(\.requiredForPass).map(\.id)
    let remainingIDs: [String]
    if let storedReceiptIDs {
      remainingIDs = requiredIDs.filter { !storedReceiptIDs.contains($0) }
    } else {
      remainingIDs = requiredIDs
    }
    let blockingStates = nextBlockingStates(
      contract: contract,
      remainingReceiptIDs: remainingIDs,
      storedReceiptIDs: storedReceiptIDs,
      storeBacked: store != nil,
      registry: registry,
      contractID: resolvedContractID)
    if let store, let storedSnapshot, !(try store.verifyCurrent(storedSnapshot)) {
      return TatwoWorkOSNextAction(
        ok: false,
        goalID: resolvedGoalID,
        contractID: resolvedContractID,
        currentLoopID: mainline.id,
        nextStep: "blocked: goalrun_snapshot_changed",
        requiredReceiptsBeforePass: remainingIDs,
        decision: WorkOSGateDecision(
          ok: false,
          code: "goalrun_snapshot_changed",
          message: "next 投影期間 GoalRun revision 已改變；請重讀後重試，禁止發布混合 revision。"),
        blockingStates: ["goalrun_snapshot_changed"])
    }
    if !blockingStates.isEmpty {
      let code = blockingStates.contains("supervision_gap") ? "supervision_gap" : "goal_tracker_missing"
      return TatwoWorkOSNextAction(
        ok: false,
        goalID: resolvedGoalID,
        contractID: resolvedContractID,
        currentLoopID: mainline.id,
        nextStep: "blocked: \(blockingStates.joined(separator: ","))",
        requiredReceiptsBeforePass: remainingIDs,
        decision: WorkOSGateDecision(
          ok: false,
          code: code,
          message: nextBlockingMessage(for: blockingStates)),
        blockingStates: blockingStates)
    }
    if storedStatus == .passed {
      return TatwoWorkOSNextAction(
        ok: true,
        goalID: resolvedGoalID,
        contractID: resolvedContractID,
        currentLoopID: mainline.id,
        nextStep: "goal already passed; no next action. Start a new Work OS goal for further work.",
        requiredReceiptsBeforePass: [],
        decision: WorkOSGateDecision(
          ok: true,
          code: "goal_already_passed",
          message: "stored GoalRun 已 passed；不得再對此 contract 派發下一步。"),
        blockingStates: [])
    }
    return TatwoWorkOSNextAction(
      ok: true,
      goalID: resolvedGoalID,
      contractID: resolvedContractID,
      currentLoopID: mainline.id,
      nextStep: mainline.nextStep,
      requiredReceiptsBeforePass: remainingIDs,
      decision: WorkOSGateDecision(
        ok: true,
        code: "next_action_ready",
        message: "依 Work OS contract 執行下一步；禁止 naked tool call。"),
      blockingStates: [])
  }

  public static func loopStatus(
    goalID: String?,
    contractID: String?,
    mode: WorkModeID,
    scenarioProfileID: String,
    objective: String = "Tatwo Work OS goal",
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    store: TatwoGoalRunStore? = nil
  ) throws -> WorkOSLoopStatusReport {
    let gate = requireContractID(contractID)
    guard gate.ok else {
      return WorkOSLoopStatusReport(
        ok: false,
        goalID: goalID,
        contractID: contractID,
        mainlineLoop: nil,
        domainLoops: [],
        decision: gate)
    }
    // With a store, loop status projects the stored run (issued contract only,
    // stored mode/scenario/objective) instead of trusting caller assertions.
    var effectiveMode = mode
    var effectiveScenario = scenarioProfileID
    var effectiveObjective = objective
    var projectedContract: TatwoWorkOSContractV1? = nil
    var storedSnapshot: TatwoGoalRunSnapshotV1? = nil
    if let store {
      let snapshot: TatwoGoalRunSnapshotV1
      do {
        snapshot = try store.snapshot(forContractID: contractID ?? "")
      } catch {
        return WorkOSLoopStatusReport(
          ok: false,
          goalID: goalID,
          contractID: contractID,
          mainlineLoop: nil,
          domainLoops: [],
          decision: WorkOSGateDecision(
            ok: false,
            code: "unregistered_contract",
            message: "loop status 的 contractID 未由 tatwo.os.begin 登記；fail closed。\(error.localizedDescription)"))
      }
      let record = snapshot.record
      storedSnapshot = snapshot
      effectiveMode = record.mode
      effectiveScenario = record.scenario
      effectiveObjective = record.objective
      projectedContract = try storedContractProjection(
        snapshot: snapshot,
        scenarioBook: scenarioBook,
        store: store)
    }
    let contract: TatwoWorkOSContractV1
    if let projectedContract {
      contract = projectedContract
    } else {
      contract = try projectContract(
        mode: effectiveMode,
        scenarioProfileID: effectiveScenario,
        objective: effectiveObjective,
        scenarioBook: scenarioBook)
    }
    let resolvedGoalID = goalID ?? contract.goalID
    let resolvedContractID = contractID ?? contract.contractID
    let mainline = remapMainline(contract.mainlineLoop, goalID: resolvedGoalID)
    let domainLoops = remapDomainLoops(
      contract.domainLoops,
      fromContractID: contract.contractID,
      toContractID: resolvedContractID)
    if let store, let storedSnapshot, !(try store.verifyCurrent(storedSnapshot)) {
      return WorkOSLoopStatusReport(
        ok: false,
        goalID: resolvedGoalID,
        contractID: resolvedContractID,
        mainlineLoop: nil,
        domainLoops: [],
        decision: WorkOSGateDecision(
          ok: false,
          code: "goalrun_snapshot_changed",
          message: "loop status 投影期間 GoalRun revision 已改變；請重讀後重試。"))
    }
    return WorkOSLoopStatusReport(
      ok: true,
      goalID: resolvedGoalID,
      contractID: resolvedContractID,
      mainlineLoop: mainline,
      domainLoops: domainLoops,
      decision: WorkOSGateDecision(
        ok: true,
        code: "loop_status_ready",
        message: "loop 狀態由 Work OS contract 投影；App 不可直接 promotion。"))
  }

  public static func submitReceipt(
    goalID: String?,
    contractID: String?,
    loopID: String?,
    receiptID: String?,
    receiptKind: String,
    satisfiesRequirementID: String? = nil,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    store: TatwoGoalRunStore? = nil
  ) -> WorkOSReceiptSubmissionResult {
    let gate = requireContractID(contractID)
    guard gate.ok else {
      return WorkOSReceiptSubmissionResult(
        ok: false,
        goalID: goalID,
        contractID: contractID,
        loopID: loopID,
        receiptID: receiptID,
        receiptKind: receiptKind,
        decision: gate,
        nextAction: "先呼叫 tatwo.os.begin 取得 contractID，再提交 receipt。")
    }
    let normalizedReceipt = receiptID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !normalizedReceipt.isEmpty else {
      let decision = WorkOSGateDecision(
        ok: false,
        code: "missing_receipt_id",
        message: "receipt submit 必須帶 receiptID；不能用模型文字自評當收據。")
      return WorkOSReceiptSubmissionResult(
        ok: false,
        goalID: goalID,
        contractID: contractID,
        loopID: loopID,
        receiptID: receiptID,
        receiptKind: receiptKind,
        decision: decision,
        nextAction: "補上可重跑的 receiptID。")
    }
    let trimmedRequirementID =
      satisfiesRequirementID?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRequirementID =
      trimmedRequirementID.flatMap { $0.isEmpty ? nil : $0 }
    if let normalizedRequirementID {
      guard let store else {
        return WorkOSReceiptSubmissionResult(
          ok: false,
          goalID: goalID,
          contractID: contractID,
          loopID: loopID,
          receiptID: receiptID,
          receiptKind: receiptKind,
          decision: WorkOSGateDecision(
            ok: false,
            code: "receipt_requirement_store_required",
            message:
              "evidence receipt 必須由已登記 contract 的 store 驗證 requirement 綁定。"),
          nextAction: "改由 store-backed receipt submit 提交真實證據。")
      }
      do {
        let contract = try storedContractProjection(
          contractID: contractID,
          fallbackMode: .s,
          fallbackScenarioProfileID: "coding",
          scenarioBook: scenarioBook,
          store: store)
        guard let requirement = contract.receiptRequirements.first(where: {
          $0.id == normalizedRequirementID
        }) else {
          return WorkOSReceiptSubmissionResult(
            ok: false,
            goalID: goalID,
            contractID: contractID,
            loopID: loopID,
            receiptID: receiptID,
            receiptKind: receiptKind,
            decision: WorkOSGateDecision(
              ok: false,
              code: "receipt_requirement_not_issued",
              message:
                "evidence receipt 只能滿足該 issued contract 的 exact requirement。"),
            nextAction: "保留 evidence receipt，不可自行發明 requirement 對應。")
        }
        guard receiptKind == requirement.kind else {
          return WorkOSReceiptSubmissionResult(
            ok: false,
            goalID: goalID,
            contractID: contractID,
            loopID: loopID,
            receiptID: receiptID,
            receiptKind: receiptKind,
            decision: WorkOSGateDecision(
              ok: false,
              code: "receipt_requirement_kind_mismatch",
              message:
                "evidence receipt kind 與 issued requirement kind 不一致；fail closed。"),
            nextAction: "使用 issued requirement 的 exact kind 重新提交。")
        }
      } catch {
        return WorkOSReceiptSubmissionResult(
          ok: false,
          goalID: goalID,
          contractID: contractID,
          loopID: loopID,
          receiptID: receiptID,
          receiptKind: receiptKind,
          decision: WorkOSGateDecision(
            ok: false,
            code: "receipt_store_error",
            message: "receipt requirement 無法驗證：\(error.localizedDescription)"),
          nextAction: "先修復 issued contract/store，再提交 receipt。")
      }
    }
    // Phase 0: with a store, a receipt only "accepts" if it is journaled against an
    // issued contract. A contractID begin never registered is rejected here instead of
    // silently echoing acceptance. Legacy callers (store == nil) keep the stateless echo.
    if let store {
      do {
        try store.appendReceipt(
          contractID: contractID ?? "",
          receiptID: normalizedReceipt,
          kind: receiptKind,
          loopID: loopID,
          satisfiesRequirementID: normalizedRequirementID)
      } catch {
        var code = "receipt_store_error"
        if case TatwoGoalRunStoreError.unregisteredContract = error {
          code = "unregistered_contract"
        }
        return WorkOSReceiptSubmissionResult(
          ok: false,
          goalID: goalID,
          contractID: contractID,
          loopID: loopID,
          receiptID: receiptID,
          receiptKind: receiptKind,
          decision: WorkOSGateDecision(
            ok: false,
            code: code,
            message: "receipt 無法登錄：\(error.localizedDescription)"),
          nextAction: "先用 tatwo.os.begin 取得已登記的 contractID，再提交 receipt。")
      }
    }
    return WorkOSReceiptSubmissionResult(
      ok: true,
      goalID: goalID,
      contractID: contractID,
      loopID: loopID,
      receiptID: normalizedReceipt,
      receiptKind: receiptKind,
      decision: WorkOSGateDecision(
        ok: true,
        code: "receipt_accepted_staging",
        message: "receipt 已被 staging 接收；goal close 仍需所有 required receipts。"),
      nextAction: "呼叫 tatwo.os.next 或在收據足夠時呼叫 tatwo.os.goal.close。")
  }

  public static func closeGoal(
    goalID: String?,
    contractID: String?,
    mode: WorkModeID,
    scenarioProfileID: String,
    objective: String = "Tatwo Work OS goal",
    suppliedReceiptIDs: [String],
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book,
    store: TatwoGoalRunStore? = nil,
    dispatchRegistry: TatwoDispatchRegistry? = nil
  ) throws -> WorkOSGoalCloseResult {
    let gate = requireContractID(contractID)
    guard gate.ok else {
      return WorkOSGoalCloseResult(
        ok: false,
        goalID: goalID,
        contractID: contractID,
        status: .blocked,
        suppliedReceiptIDs: suppliedReceiptIDs,
        missingReceiptIDs: [],
        decision: gate)
    }
    // Phase 0: with a store, close is store-verified, not caller-asserted.
    // - required receipts derive from the STORED mode/scenario (blocks the XL→S
    //   downgrade that shrinks the required set),
    // - supplied receipts come from the receipt journal (blocks echoing the
    //   required-ID list back without ever submitting a receipt),
    // - an unregistered contractID is rejected outright.
    // Legacy callers (store == nil) keep the caller-asserted behavior below.
    var effectiveMode = mode
    var effectiveScenario = scenarioProfileID
    var effectiveObjective = objective
    var storeSuppliedReceiptIDs: [String]? = nil
    var storedSnapshot: TatwoGoalRunSnapshotV1? = nil
    var projectedContract: TatwoWorkOSContractV1? = nil
    if let store {
      let snapshot: TatwoGoalRunSnapshotV1
      do {
        snapshot = try store.snapshot(forContractID: contractID ?? "")
      } catch {
        return WorkOSGoalCloseResult(
          ok: false,
          goalID: goalID,
          contractID: contractID,
          status: .blocked,
          suppliedReceiptIDs: [],
          missingReceiptIDs: [],
          decision: WorkOSGateDecision(
            ok: false,
            code: "unregistered_contract",
            message: "close 的 contractID 未由 tatwo.os.begin 登記；fail closed。\(error.localizedDescription)"))
      }
      let record = snapshot.record
      storedSnapshot = snapshot
      effectiveMode = record.mode
      effectiveScenario = record.scenario
      effectiveObjective = record.objective
      projectedContract = try storedContractProjection(
        snapshot: snapshot,
        scenarioBook: scenarioBook,
        store: store)
      var journaledReceiptIDs = record.satisfiedReceiptRequirementIDs
      // A close call that disagrees with the stored mode is an attempted route/mode
      // downgrade. Keep the close gate anchored to the stored contract and do not let
      // the activation-seeded goal-tracker receipt disappear from the required/missing
      // list on that adversarial path.
      if mode != record.mode {
        journaledReceiptIDs.remove("goal-tracker")
      }
      storeSuppliedReceiptIDs = Array(journaledReceiptIDs)
    }
    let contract: TatwoWorkOSContractV1
    if let projectedContract {
      contract = projectedContract
    } else {
      contract = try projectContract(
        mode: effectiveMode,
        scenarioProfileID: effectiveScenario,
        objective: effectiveObjective,
        scenarioBook: scenarioBook)
    }
    let required = Set(contract.receiptRequirements.filter(\.requiredForPass).map(\.id))
    let supplied = Set(
      (storeSuppliedReceiptIDs ?? suppliedReceiptIDs).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty })
    let missing = required.subtracting(supplied).sorted()
    let passed = missing.isEmpty
    let requiresCanonicalDispatch = contract.identityBindings.contains {
      TatwoExecutionManifestFactory.isDispatchable(modelID: $0.modelID)
    }
    let closedStatus: GoalRunStatus = passed ? .passed : .rollbackRequired
    if let store {
      if let storedSnapshot, !(try store.verifyCurrent(storedSnapshot)) {
        return WorkOSGoalCloseResult(
          ok: false,
          goalID: goalID ?? contract.goalID,
          contractID: contractID,
          status: .blocked,
          suppliedReceiptIDs: supplied.sorted(),
          missingReceiptIDs: missing,
          decision: WorkOSGateDecision(
            ok: false,
            code: "goalrun_snapshot_changed",
            message: "close 計算期間 GoalRun revision 已改變；禁止以混合 revision 關閉 goal。"))
      }
      // An incomplete close is a fail-closed decision, not an irreversible
      // GoalRun judgment. Keep the durable run open so receipts can still be
      // journaled and a later close can persist `.passed`.
      if passed {
        if let dispatchRegistry {
          let consistency =
            try TatwoGoalRunDispatchLifecycle.persistPassedIfTerminalConsistent(
              contractID: contractID ?? "",
              requiresCanonicalDispatch: requiresCanonicalDispatch,
              goalStore: store,
              dispatchRegistry: dispatchRegistry)
          guard consistency.ok else {
            return WorkOSGoalCloseResult(
              ok: false,
              goalID: goalID ?? contract.goalID,
              contractID: contractID,
              status: .blocked,
              suppliedReceiptIDs: supplied.sorted(),
              missingReceiptIDs: missing,
              decision: WorkOSGateDecision(
                ok: false,
                code: consistency.code,
                message: consistency.message))
          }
        } else if requiresCanonicalDispatch {
          return WorkOSGoalCloseResult(
            ok: false,
            goalID: goalID ?? contract.goalID,
            contractID: contractID,
            status: .blocked,
            suppliedReceiptIDs: supplied.sorted(),
            missingReceiptIDs: missing,
            decision: WorkOSGateDecision(
              ok: false,
              code: "dispatch_registry_unavailable",
              message:
                "Goal 尚未通過：此 contract 需要 canonical dispatch，"
                + "但 dispatch registry 不可用；fail closed。"))
        } else {
          let persisted = try store.updateStatus(
            contractID: contractID ?? "",
            status: closedStatus,
            authority: .goalClose,
            reason: "required_receipts_complete")
          guard persisted.status == closedStatus else {
            throw TatwoGoalRunStoreError.illegalStatusTransition(
              from: persisted.status,
              to: closedStatus,
              authority: "goal_close_persistence_verify")
          }
        }
      }
    }
    return WorkOSGoalCloseResult(
      ok: passed,
      goalID: goalID ?? contract.goalID,
      contractID: contractID,
      status: closedStatus,
      suppliedReceiptIDs: supplied.sorted(),
      missingReceiptIDs: missing,
      decision: WorkOSGateDecision(
        ok: passed,
        code: passed ? "goal_passed" : "receipt_incomplete",
        message: passed
          ? "required receipts 足夠，包含 cleanup-inventory；goal 可標記 passed。"
          : "required receipts 不足；必須 rollback_required 或繼續 loop，不可宣稱完成。"))
  }

  public static func availableLoopTemplates(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
  ) -> [WorkOSLoopTemplate] {
    let profile =
      (try? resolveScenarioContext(rawScenarioProfileID, scenarioBook: scenarioBook).profile)
      ?? TatwoIdentityCatalog.scenarioProfile("coding")
      ?? TatwoIdentityCatalog.scenarioProfiles.first
    guard let profile else { return [] }
    let templates = scenarioLoopTemplates(for: profile)
    if mode == .s {
      return templates.filter { $0.id == TatwoUIFireworksLoopTemplate.id }
    }
    if mode == .m { return templates }
    return templates.filter { template in
      template.defaultEnabledModes.contains(mode)
        || mode >= .xl
        || template.domain == primaryDomain(for: profile)
    }
  }

  private static func remapMainline(_ loop: MainlineLoop, goalID: String) -> MainlineLoop {
    MainlineLoop(
      id: "mainline-\(goalID)",
      title: loop.title,
      ownerIdentity: loop.ownerIdentity,
      objective: loop.objective,
      phases: loop.phases,
      allowedTools: loop.allowedTools,
      requiredReceipts: loop.requiredReceipts,
      reviewerGateRequired: loop.reviewerGateRequired,
      status: loop.status,
      nextStep: loop.nextStep)
  }

  private static func remapDomainLoops(
    _ loops: [DomainLoop],
    fromContractID: String,
    toContractID: String
  ) -> [DomainLoop] {
    loops.map { loop in
      DomainLoop(
        id: loop.id.replacingOccurrences(of: fromContractID, with: toContractID),
        domain: loop.domain,
        title: loop.title,
        ownerIdentity: loop.ownerIdentity,
        ownerSourceSlotID: loop.ownerSourceSlotID,
        allowedTools: loop.allowedTools,
        sandboxType: loop.sandboxType,
        requiredReceipts: loop.requiredReceipts,
        status: loop.status,
        autonomyLevel: loop.autonomyLevel,
        mergeBackRule: loop.mergeBackRule,
        cycleIndex: loop.cycleIndex)
    }
  }

  public static func collaborationPresets(
    mode: WorkModeID,
    scenarioProfileID rawScenarioProfileID: String,
    scenarioBook: TatwoScenarioConfigBookV1 = TatwoScenarioConfigDefaults.book
  ) -> [WorkOSCollaborationPreset] {
    let profile =
      (try? resolveScenarioContext(rawScenarioProfileID, scenarioBook: scenarioBook).profile)
      ?? TatwoIdentityCatalog.scenarioProfile("coding")
      ?? TatwoIdentityCatalog.scenarioProfiles.first
    guard let profile else { return [] }
    let templates = availableLoopTemplates(mode: mode, scenarioProfileID: profile.id)
    let recommendedIDs = defaultLoopTemplateIDs(for: mode, profile: profile)
    let primaryIDs = templates.filter { $0.domain == primaryDomain(for: profile) }.map(\.id)
    let wideIDs = Array(templates.prefix(maxLoopCount(for: mode, custom: true)).map(\.id))
    let budget = budgetNote(for: mode)
    return [
      WorkOSCollaborationPreset(
        id: "recommended",
        displayName: "OS 自動安排",
        mode: mode,
        scenarioProfileID: profile.id,
        plainPurpose: recommendedIDs.isEmpty
          ? "只跑主線與驗收，不額外開支線。"
          : "依情境與模式，自動挑最少必要支線。",
        loopTemplateIDs: recommendedIDs,
        editable: false,
        isRecommended: true,
        budgetNote: budget),
      WorkOSCollaborationPreset(
        id: "mainline-only",
        displayName: "只跑主線",
        mode: mode,
        scenarioProfileID: profile.id,
        plainPurpose: "不開支線；適合查找、小修、單點問題。",
        loopTemplateIDs: [],
        editable: false,
        budgetNote: budget),
      WorkOSCollaborationPreset(
        id: "single-domain",
        displayName: "單路加深",
        mode: mode,
        scenarioProfileID: profile.id,
        plainPurpose: "只開一條最相關支線，深入做完再回主線。",
        loopTemplateIDs: Array(primaryIDs.prefix(1)),
        editable: false,
        budgetNote: budget),
      WorkOSCollaborationPreset(
        id: "wide-domain",
        displayName: "多路並行",
        mode: mode,
        scenarioProfileID: profile.id,
        plainPurpose: "多條支線同時跑；適合 L/XL 或跨區塊專案。",
        loopTemplateIDs: wideIDs,
        editable: false,
        budgetNote: budget),
      uiFireworksPreset(
        mode: mode,
        scenarioProfileID: profile.id,
        templates: templates,
        budget: budget),
      WorkOSCollaborationPreset(
        id: "custom",
        displayName: "手動選路線",
        mode: mode,
        scenarioProfileID: profile.id,
        plainPurpose: "自己選要開哪些支線；OS 仍控風險與預算。",
        loopTemplateIDs: recommendedIDs,
        editable: true,
        budgetNote: budget),
    ].compactMap { $0 }
  }

  public static func gatewayRouteReservations() -> [WorkOSGatewayRouteReservation] {
    TatwoOSModeRouteCatalog.all.map { route in
      WorkOSGatewayRouteReservation(
        id: "route-\(route.route)",
        route: route.route,
        mode: route.mode,
        dryRunOnly: true,
        plainPurpose: route.modelDropdownPolicy)
    }
  }

  public static func requireContractID(_ contractID: String?) -> WorkOSGateDecision {
    let normalized = contractID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if normalized.isEmpty {
      return WorkOSGateDecision(
        ok: false,
        code: "missing_contract_id",
        message: "沒有 contractID 的 agent action / receipt / close 一律 fail closed。")
    }
    return WorkOSGateDecision(
      ok: true,
      code: "contract_present",
      message: "contractID present; action may continue inside Work OS rules.")
  }

  private struct ResolvedScenarioContext {
    let scenarioID: String
    let profile: ScenarioProfile
    let customConfig: TatwoCustomScenarioConfig?
  }

  private static func resolveScenarioContext(
    _ raw: String,
    scenarioBook: TatwoScenarioConfigBookV1
  ) throws -> ResolvedScenarioContext {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let profile = TatwoIdentityCatalog.scenarioProfile(
      normalized.isEmpty ? "coding" : normalized)
    {
      return ResolvedScenarioContext(scenarioID: profile.id, profile: profile, customConfig: nil)
    }
    if let config = scenarioBook.scenario(id: normalized) {
      let profileID = config.baseScenario.map(profileID(for:)) ?? "coding"
      let profile =
        TatwoIdentityCatalog.scenarioProfile(profileID)
        ?? TatwoIdentityCatalog.scenarioProfile("coding")
        ?? TatwoIdentityCatalog.scenarioProfiles.first
      guard let profile else { throw TatwoParseError.unknownScenario(raw) }
      return ResolvedScenarioContext(
        scenarioID: config.id,
        profile: profile,
        customConfig: config)
    }
    if let scenario = try? ScenarioID.parse(normalized),
      let profile = TatwoIdentityCatalog.scenarioProfile(profileID(for: scenario))
    {
      return ResolvedScenarioContext(scenarioID: profile.id, profile: profile, customConfig: nil)
    }
    throw TatwoParseError.unknownScenario(raw)
  }

  private static func resolveScenarioProfile(_ raw: String) throws -> ScenarioProfile {
    try resolveScenarioContext(raw, scenarioBook: TatwoScenarioConfigStore.loadDefaultStaging()).profile
  }

  private static func profileID(for scenario: ScenarioID) -> String {
    switch scenario {
    case .daily: return "daily"
    case .design: return "ui-ux"
    case .coding: return "coding"
    case .trading: return "trading-risk"
    case .modeling: return "modeling"
    }
  }

  private static func sanitizedObjective(_ raw: String) -> String {
    let normalized = TatwoObjectiveIdentity.normalize(raw)
    let safe = normalized.isEmpty ? "Tatwo Work OS goal" : TatwoPrivacyRedactor.redacted(normalized)
    return TatwoObjectiveIdentity.normalize(safe)
  }

  private static func normalizedAuthorityInstanceDiscriminator(
    _ raw: String?
  ) throws -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw TatwoAuthorityInstanceDiscriminatorError.empty
    }

    let components = trimmed.split(
      separator: "|",
      omittingEmptySubsequences: false)
    guard components.count == 3,
      components[0].hasPrefix("provider:"),
      components[1].hasPrefix("ownerKind:"),
      components[2].hasPrefix("sessionID:")
    else {
      throw TatwoAuthorityInstanceDiscriminatorError.malformed
    }

    let provider = components[0].dropFirst("provider:".count)
    let ownerKind = components[1].dropFirst("ownerKind:".count)
    let sessionID = components[2].dropFirst("sessionID:".count)
    guard isSafeAuthorityDiscriminatorComponent(provider),
      ownerKind == "thread" || ownerKind == "session",
      isSafeAuthorityDiscriminatorComponent(sessionID)
    else {
      throw TatwoAuthorityInstanceDiscriminatorError.malformed
    }

    // Return the original canonical bytes so existing valid records keep the
    // exact contract/goal IDs they were issued with.
    return trimmed
  }

  private static func isSafeAuthorityDiscriminatorComponent(
    _ value: Substring
  ) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { byte in
      (byte >= 48 && byte <= 57)
        || (byte >= 65 && byte <= 90)
        || (byte >= 97 && byte <= 122)
        || byte == 45
        || byte == 46
        || byte == 95
    }
  }

  /// Canonical, delimiter-independent identity for authority-scoped Goal rows.
  ///
  /// The legacy ID path concatenates fields with `|`. Model IDs and objectives
  /// can legally contain that byte, so using the same representation for a
  /// security boundary lets two distinct tuples hash to the same ID. Encoding
  /// typed fields as sorted-key JSON preserves boundaries through escaping and
  /// makes the authority discriminator part of one unambiguous envelope.
  private struct TatwoAuthorityScopedContractIdentityV1: Encodable {
    let schema = "TatwoAuthorityScopedContractIdentityV1"
    let mode: String
    let scenario: String
    let objective: String
    let routeBindingOverride: WorkOSRouteBindingOverride?
    let authorityInstanceDiscriminator: String
  }

  private static func makeIdentityBindings(
    from slots: [IdentitySlot],
    governorDecision: TatwoLoopGovernorDecisionV1? = nil,
    configuredTopologyPresent: Bool = false,
    routeBindingOverridePresent: Bool = false,
    roleIntentOverride: RoleIntentOverride = RoleIntentOverride.none
  ) -> [WorkOSIdentityBinding] {
    let baseBindings: [WorkOSIdentityBinding]
    if let governorDecision, !governorDecision.activatedBindings.isEmpty {
      baseBindings = governorDecision.activatedBindings.flatMap { binding -> [WorkOSIdentityBinding] in
        let kind = binding.identityKind ?? .consultant
        let models = binding.boundModelIDs.isEmpty ? [nil] : binding.boundModelIDs.map(Optional.some)
        let nativeMutationSourceSlotIDs: Set<String> = [
          TatwoNativeDevelopmentDispatchCoordinator.solExecutorSourceSlotID,
          TatwoNativeDevelopmentDispatchCoordinator.opusSupervisorSourceSlotID,
          TatwoNativeDevelopmentDispatchCoordinator.fableExecutorSourceSlotID,
          TatwoNativeDevelopmentDispatchCoordinator.grokExecutorSourceSlotID,
        ]
        let grantsNativeHostMutation =
          [
            TatwoScenarioConfigDefaults
              .nativeDevelopmentXXLSolOpusScenarioID,
            TatwoScenarioConfigDefaults
              .nativeDevelopmentXXLFableGrokScenarioID,
          ].contains(governorDecision.scenarioID)
          && binding.phase == .loops
          && nativeMutationSourceSlotIDs.contains(binding.id)
        return models.enumerated().map { index, modelID in
          WorkOSIdentityBinding(
            id: "binding-\(binding.id)-\(index)",
            identity: kind,
            label: "\(binding.phase.chineseName) \(binding.identity)",
            engineID: engineID(forModelID: modelID),
            modelID: modelID,
            authority:
              grantsNativeHostMutation ? .toolIntentBridge : .brainOnly,
            canMutateHost: grantsNativeHostMutation,
            sourceSlotID: binding.id,
            bindingRule:
              grantsNativeHostMutation
              ? "Loop Governor 依原生開發 scenario 啟用；只有已簽發 contract、running dispatch、當前明確工具意圖與 App 內原生 runtime 同時成立時，才可在 workspace lease 內修改主機。"
              : "Loop Governor 依 Dashboard Scenario Config 啟用；\(binding.dynamicActivation.chineseName)。")
          }
      }
    } else if configuredTopologyPresent && !routeBindingOverridePresent {
      baseBindings = []
    } else {
      baseBindings = slots.map { slot in
        let candidate = slot.primaryCandidate
        return WorkOSIdentityBinding(
          id: "binding-\(slot.id)",
          identity: slot.kind,
          label: slot.label,
          engineID: candidate?.engineID,
          modelID: candidate?.modelID,
          authority: candidate?.authority ?? .brainOnly,
          canMutateHost: false,
          sourceSlotID: slot.id,
          bindingRule: "身份組先決定；未找到 Dashboard config 時使用內建候選。")
      }
    }

    guard roleIntentOverride.isFable5LeadGPT55Loops else {
      return baseBindings
    }

    var rewritten = baseBindings.map { binding -> WorkOSIdentityBinding in
      switch binding.identity {
      case .lead:
        return WorkOSIdentityBinding(
          id: binding.id,
          identity: .lead,
          label: "Plan 主導",
          engineID: .claudeCLI,
          modelID: "fable-5",
          authority: .toolIntentBridge,
          canMutateHost: false,
          sourceSlotID: binding.sourceSlotID,
          bindingRule: "使用者指定 Fable5 回歸主導：route health/live smoke 健康時可作為主導 dispatch lane；只有當當前 route health 或 live smoke 顯示 quota/斷線時，才標記 degraded，不 retry-loop，也不阻斷 Codex host continuity。")
      case .sub:
        return WorkOSIdentityBinding(
          id: binding.id,
          identity: .sub,
          label: "Loops 執行",
          engineID: .codex,
          modelID: "gpt-5.5",
          authority: .toolIntentBridge,
          canMutateHost: false,
          sourceSlotID: binding.sourceSlotID,
          bindingRule: "使用者指定 GPT5.5 專心 loops：code/debug/ops 支線只交 receipt、diff intent 與測試結果；不得取代 Fable5 主導或最終驗收。")
      case .verifier:
        return WorkOSIdentityBinding(
          id: binding.id,
          identity: .verifier,
          label: "Codex host 驗收",
          engineID: .codex,
          modelID: "deterministic-checks",
          authority: .toolIntentBridge,
          canMutateHost: false,
          sourceSlotID: binding.sourceSlotID,
          bindingRule: "Codex host 主導 deterministic 驗收與 debug：跑測試、smoke、rollback、cleanup inventory；模型意見必須轉成可重跑收據。")
      default:
        return WorkOSIdentityBinding(
          id: binding.id,
          identity: binding.identity,
          label: binding.label,
          engineID: binding.engineID,
          modelID: binding.modelID,
          authority: binding.authority,
          canMutateHost: false,
          sourceSlotID: binding.sourceSlotID,
          bindingRule: "\(binding.bindingRule) Fable5/GPT5.5 role intent active；所有 loops 回主線驗收，缺 route-health 收據不得 pass。")
      }
    }

    if !rewritten.contains(where: { $0.identity == .lead }) {
      rewritten.insert(
        WorkOSIdentityBinding(
          id: "binding-fable5-lead",
          identity: .lead,
          label: "Plan 主導",
          engineID: .claudeCLI,
          modelID: "fable-5",
          authority: .toolIntentBridge,
          canMutateHost: false,
          sourceSlotID: "role-intent-fable5-lead",
          bindingRule: "使用者指定 Fable5 回歸主導；live route 健康時作為主導 dispatch lane，只有當前驗證失敗才降為 degraded。"),
        at: 0)
    }
    if !rewritten.contains(where: { $0.identity == .sub && $0.modelID == "gpt-5.5" }) {
      rewritten.append(
        WorkOSIdentityBinding(
          id: "binding-gpt55-loops",
          identity: .sub,
          label: "Loops 執行",
          engineID: .codex,
          modelID: "gpt-5.5",
          authority: .toolIntentBridge,
          canMutateHost: false,
          sourceSlotID: "role-intent-gpt55-loops",
          bindingRule: "使用者指定 GPT5.5 專心 loops；只交 evidence/receipt，不越權成最終主導。"))
    }
    return rewritten
  }

  private static func applyingRouteBindingOverride(
    _ override: WorkOSRouteBindingOverride?,
    to decision: TatwoLoopGovernorDecisionV1
  ) throws -> TatwoLoopGovernorDecisionV1 {
    guard let override else { return decision }
    var rewritten = decision.activatedBindings
    var overriddenSlotIDs = Set<String>()
    guard !rewritten.isEmpty else {
      return TatwoLoopGovernorDecisionV1(
        schema: decision.schema,
        configHash: decision.configHash,
        mode: decision.mode,
        scenarioID: decision.scenarioID,
        tokenBudget: decision.tokenBudget,
        activatedBindings: [],
        decisionReasons: decision.decisionReasons + [
          "Dashboard Scenario Config 未宣告身份 topology；Chat identity picker override 改套用到內建 mode identity plan。"
        ],
        humanGateRules: decision.humanGateRules,
        formalGoalCycleRule: decision.formalGoalCycleRule,
        sandboxCycleRule: decision.sandboxCycleRule)
    }

    if let primaryModelID = override.primaryModelID {
      var replacedLead = false
      rewritten = rewritten.map { binding in
        guard binding.identityKind == .lead else { return binding }
        replacedLead = true
        overriddenSlotIDs.insert(binding.id)
        var updated = binding
        updated.boundModelIDs = [primaryModelID]
        return updated
      }
      guard replacedLead else { throw RouteTopologyError.missingIdentity(.lead) }
    }

    if let secondaryModelID = override.secondaryModelID {
      var replacedSub = false
      rewritten = rewritten.map { binding in
        guard binding.identityKind == .sub else { return binding }
        replacedSub = true
        overriddenSlotIDs.insert(binding.id)
        var updated = binding
        updated.boundModelIDs = [secondaryModelID]
        return updated
      }
      guard replacedSub else { throw RouteTopologyError.missingIdentity(.sub) }
    }

    var effortVariantsByRoutePhase: [String: Set<String>] = [:]
    for binding in rewritten
    where overriddenSlotIDs.contains(binding.id)
      && binding.enabled
      && binding.dynamicActivation != .disabled
    {
      for modelID in binding.boundModelIDs {
        let canonical = TatwoGatewayDispatchCatalog.normalize(modelID)
        let key = "\(binding.phase.rawValue)|\(canonical)"
        effortVariantsByRoutePhase[key, default: []].insert(
          binding.reasoningEffort?.rawValue ?? "<route-default>")
        if effortVariantsByRoutePhase[key, default: []].count > 1 {
          throw RouteTopologyError.conflictingEffort(
            modelID: canonical,
            phase: binding.phase)
        }
      }
    }

    return TatwoLoopGovernorDecisionV1(
      schema: decision.schema,
      configHash: decision.configHash,
      mode: decision.mode,
      scenarioID: decision.scenarioID,
      tokenBudget: decision.tokenBudget,
      activatedBindings: rewritten,
      decisionReasons: decision.decisionReasons + [
        "Chat identity picker override 已投影到 Loop Governor；runtime 與 execution manifest 共用同一 topology。"
      ],
      humanGateRules: decision.humanGateRules,
      formalGoalCycleRule: decision.formalGoalCycleRule,
      sandboxCycleRule: decision.sandboxCycleRule)
  }

  private static func applyingRouteBindingOverride(
    _ override: WorkOSRouteBindingOverride?,
    to bindings: [WorkOSIdentityBinding]
  ) throws -> [WorkOSIdentityBinding] {
    guard let override else { return bindings }
    var rewritten = bindings

    func replace(
      identity: IdentityKind,
      modelID: String
    ) throws {
      var replaced = false
      rewritten = rewritten.map { binding in
        guard binding.identity == identity else { return binding }
        replaced = true
        return WorkOSIdentityBinding(
          id: binding.id,
          identity: binding.identity,
          label: binding.label,
          engineID: engineID(forModelID: modelID),
          modelID: modelID,
          authority: binding.authority,
          canMutateHost: binding.canMutateHost,
          sourceSlotID: binding.sourceSlotID,
          bindingRule:
            "\(binding.bindingRule) Chat identity picker 明確指定 \(identity.chineseName)=\(modelID)。")
      }
      guard replaced else { throw RouteTopologyError.missingIdentity(identity) }
    }

    if let primaryModelID = override.primaryModelID {
      try replace(identity: .lead, modelID: primaryModelID)
    }
    if let secondaryModelID = override.secondaryModelID {
      try replace(identity: .sub, modelID: secondaryModelID)
    }
    return rewritten
  }

  private static func roleIntentOverride(for objective: String) -> RoleIntentOverride {
    let lower = objective.lowercased()
    let mentionsFable = lower.contains("fable5") || lower.contains("fable-5") || lower.contains("fable 5")
    let mentionsGPT55 = lower.contains("gpt5.5") || lower.contains("gpt-5.5") || lower.contains("gpt 5.5")
    // This compatibility override is intentionally narrow. Mentioning Fable
    // alongside generic "loops/分工" text must not rewrite an exact scenario's
    // reviewer into a legacy Fable-lead + GPT5.5-sub topology.
    guard mentionsFable && mentionsGPT55 else { return .none }

    return RoleIntentOverride(
      id: "fable5-lead-gpt55-loops",
      requiredReceipts: [
        receipt(
          "fable5-route-health",
          "Fable5 route health receipt",
          "route_health",
          "記錄 Fable5 gateway/catalog/config/session/live smoke 狀態；健康時保持主導 dispatch lane，只有 quota/斷線時才標 degraded，不 retry-loop，不阻斷 Codex host continuity。")
      ],
      stopRules: [
        "Fable5 lead route 以當前 route-health/live smoke 為準；只有出現 quota/session-limit/斷線時才提交 degraded receipt，禁止用舊錯誤狀態硬降權或自動重試迴圈消耗額度。",
        "GPT5.5 loops 只處理 code/debug/ops 支線並回交 receipts；不得取代 Fable5 主導或繞過 Goal 驗收。",
        "Codex host 持續負責 patch、shell、測試、smoke、rollback 與 cleanup inventory；外部模型不能直接改主機。",
      ],
      mainlinePhases: [
        "Fable5 live route 健康時負責主導方向與主導 dispatch；不健康時才標 degraded 並由 Codex host continuity 承接。",
        "GPT5.5 專心跑 loops，所有輸出必須回到主線收據。",
        "驗收時檢查 loops 是否偏離 Fable5/OS 方向，並把 Fable5 當前 live route 結果寫入 route-health 收據。",
      ],
      nextStepSuffix:
        "本 goal 啟用 Fable5 lead / GPT5.5 loops：先補 fable5-route-health，再讓 GPT5.5 loops 產出 code/debug/ops receipts。")
  }

  private static func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func engineID(forModelID modelID: String?) -> EngineID? {
    guard let modelID else { return nil }
    if TatwoGatewayDispatchCatalog.allowedModels.contains(
      TatwoGatewayDispatchCatalog.normalize(modelID)
    ) {
      return .modelGateway
    }
    let lower = modelID.lowercased()
    if lower.contains("opus") || lower.contains("sonnet") || lower.contains("haiku") || lower.contains("fable") { return .claudeCLI }
    if lower.contains("grok") { return .grok }
    if lower.contains("minimax") { return .minimax }
    if lower.contains("chatgpt") { return .chatgptProMCP }
    return .codex
  }

  private static func makeBaseReceipts(mode: WorkModeID, profile: ScenarioProfile)
    -> [WorkOSReceiptRequirement]
  {
    var receipts = [
      receipt("contract-id", "OS contractID", "contract", "證明 agent 先進 Work OS。"),
      receipt("mode-budget", "模式 / 預算", "budget", "記錄 S/M/L/XL、token 預算與風險 gate；正式 goal 不限制次數。"),
      receipt("identity-bindings", "身份組綁定", "identity", "記錄主導、監督、顧問、sub、消息、驗收的候選綁定。"),
      receipt("plan-loop-goal-mainline", "Plan+Loops+Goal 主線", "planning", "所有沙盒都要提交 goal-contract、plan、loop-ledger 與主線決策。"),
      receipt("plan-loop-goal-branch", "Plan+Loops+Goal 支線優化", "planning", "支線優化與工具選擇要有 ledger，最後一起進 PLG 評分。"),
      receipt("goal-cycle-seal", "沙盒五巡迴與封存", "seal", "僅沙盒評分最多 5 次 execution cycles；正式 goal 不受此限制。"),
    ]
    switch mode {
    case .s:
      receipts.append(receipt("local-check", "S 本機檢查", "validation", "S 不 fan-out；用直接證據或本機檢查收斂。"))
      receipts.append(receipt("s-no-sub", "S no-sub note", "budget", "確認沒有啟動 sub/domain fan-out。"))
    case .m:
      receipts.append(receipt("scope-review", "M 影響範圍", "scope", "確認修改入口與不要碰的範圍。"))
      receipts.append(
        receipt("reviewer-gate", "M reviewer gate", "review", "至少一個非 builder 的 reviewer gate。"))
    case .l:
      receipts.append(receipt("scope-review", "L 影響範圍", "scope", "確認單領域深 loop 的邊界。"))
      receipts.append(
        receipt("sandbox", "L sandbox receipt", "sandbox", "先在臨時 workspace / dry-run 驗證。"))
      receipts.append(receipt("rollback", "L rollback receipt", "rollback", "留下回滾或 checkpoint。"))
    case .xl, .xxl:
      receipts.append(receipt("scope-review", "XL 影響範圍", "scope", "主線與多領域 loop 都要知道邊界。"))
      receipts.append(
        receipt("sandbox", "XL sandbox receipt", "sandbox", "沙盒必過才可談 host promotion。"))
      receipts.append(receipt("human-gate", "XL human gate", "human", "重型模式需明確授權。"))
      receipts.append(
        receipt("rollback", "XL rollback receipt", "rollback", "任何 gate 失敗可回滾或交 checkpoint。"))
    }
    if profile.baseScenario == .design || profile.id == "ui-ux" || profile.id == "editing" {
      receipts.append(
        receipt("visual-evidence", "UI/UJ visual evidence", "ui", "UI 必須有截圖、錄影或互動證據。"))
      receipts.append(
        receipt(
          "codex-app-parity",
          "Codex App parity gate",
          "ui_parity",
          "Chat/Codex-App-style UI 必須用同 run 的目前 Codex App baseline 對比 Tatwo 候選畫面，且 Codex verifier 與獨立 reviewer 都判定一致；reviewer 綁定依當次 Work OS identity contract，不寫死模型；未取得 current baseline 或任一方判 drift/blocked 則 UI/UJ 未通過。"))
    }
    receipts += TatwoProductDesignFactory.receiptRequirements(
      mode: mode, scenarioProfileID: profile.id)
    receipts += TatwoWebCheckFactory.receiptRequirements(mode: mode, scenarioProfileID: profile.id)
    receipts.append(PostValidationCleanupInventoryFactory.receiptRequirement)
    return receipts
  }

  private static func fanOutReceipts(mode: WorkModeID, hasFanOut: Bool) -> [WorkOSReceiptRequirement] {
    guard hasFanOut, mode >= .m else { return [] }
    return [
      receipt(
        "goal-tracker",
        "Visible Goal tracker at activation",
        "goal_tracker",
        "OS 啟動時必須已建立可視 GoalRun / task board；不可等使用者提醒後補。"),
      receipt(
        "dispatch-liveness",
        "Dispatch liveness watchdog",
        "dispatch_liveness",
        "每個 codex exec / background host dispatch 必須 < /dev/null 關 stdin、約 2 分鐘確認起跑、10 分鐘無輸出成長即告警介入。"),
      receipt(
        "supervision-patrol",
        "Lead supervision patrol",
        "supervision_patrol",
        "派工期間 Plan Lead / Loops Supervisor 必須約每 10 分鐘巡檢 process liveness、output growth、changed-file count、scope drift，且範圍偏差需裁決記錄。"),
    ]
  }

  private static func makeMainlineLoop(
    goalID: String,
    contractID: String,
    mode: WorkModeID,
    profile: ScenarioProfile,
    objective: String,
    receipts: [WorkOSReceiptRequirement],
    roleIntentOverride: RoleIntentOverride = .none
  ) -> MainlineLoop {
    var phases = [
      "定義目標與完成邊界",
      "身份組先於模型",
      "收據與停止條件",
      "驗收成功後建立待刪檔案盤點",
      "下一步由 tatwo.os.next 指派",
    ]
    if mode >= .m { phases.append("通過前必須副審") }
    if mode >= .l { phases.append("沙盒先跑並保留回滾收據") }
    if mode >= .xl { phases.append("主線監督多領域 loops 與人工 Gate") }
    if mode >= .m {
      phases.append("派工前必須建立 goal tracker；background dispatch 必須有 liveness/watchdog。")
      phases.append("派工期間主導約每 10 分鐘提交 supervision patrol；範圍偏差需裁決記錄。")
    }
    phases += roleIntentOverride.mainlinePhases
    let nextStep = [
      mode == .s
        ? "S：主線直接做最小檢查，不產生 domain fan-out。"
        : "先完成 scope / identity / sandbox gate，再分派或收斂 domain loops。",
      roleIntentOverride.nextStepSuffix,
    ].compactMap { $0 }.joined(separator: " ")
    let collaborationControlPlaneTools = mode >= .m
      ? [
        "multi_agent_v1.send_input",
        "multi_agent_v1.wait_agent",
        "multi_agent_v1.resume_agent",
        "multi_agent_v1.close_agent",
        "computer-use",
        "tatwo.gateway.dispatch",
        "tatwo.gateway.fanout",
      ]
      : []

    return MainlineLoop(
      id: "mainline-\(goalID)",
      title: "主線目標 Loop",
      ownerIdentity: .lead,
      objective: objective,
      phases: phases,
      allowedTools: [
        "tatwo.os.next",
        "tatwo.os.loop.status",
        "tatwo.os.receipt.submit",
        "tatwo.receipt.requirements",
        "tatwo.handoff.pack",
      ] + collaborationControlPlaneTools,
      requiredReceipts: receipts,
      reviewerGateRequired: mode >= .m,
      status: .planned,
      nextStep: nextStep
    )
  }

  private static func loopTemplates(
    for mode: WorkModeID,
    profile: ScenarioProfile,
    loopPresetID: String?,
    enabledLoopTemplateIDs: [String]?
  ) -> [WorkOSLoopTemplate] {
    let requestedIDs: [String]
    if let enabledLoopTemplateIDs {
      requestedIDs = enabledLoopTemplateIDs
    } else if let loopPresetID,
      let preset = collaborationPresets(mode: mode, scenarioProfileID: profile.id)
        .first(where: { $0.id == loopPresetID })
    {
      requestedIDs = preset.loopTemplateIDs
    } else {
      requestedIDs = defaultLoopTemplateIDs(for: mode, profile: profile)
    }

    let available = availableLoopTemplates(mode: mode, scenarioProfileID: profile.id)
    let maxCount = maxLoopCount(
      for: mode, custom: enabledLoopTemplateIDs != nil || loopPresetID == "custom")
    let containsUIFireworks = requestedIDs.contains(TatwoUIFireworksLoopTemplate.id)
    guard maxCount > 0 || containsUIFireworks else { return [] }

    let availableByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
    return
      requestedIDs
      .compactMap { availableByID[$0] }
      .prefix(containsUIFireworks ? max(1, maxCount) : maxCount)
      .map { $0 }
  }

  private static func defaultLoopTemplateIDs(for mode: WorkModeID, profile: ScenarioProfile)
    -> [String]
  {
    switch mode {
    case .s:
      return []
    case .m, .l:
      // T1: M 預設就有 domain loops（不再 mainline only），L 全 scenario domains 起跳；
      // 兩者不足額的部分由 expandLoopsToTarget 的 cycle 實例補到預設 loop 數。
      return scenarioLoopTemplates(for: profile)
        .filter { scenarioDomains(for: profile).contains($0.domain) }
        .filter { $0.id != TatwoUIFireworksLoopTemplate.id }
        .map(\.id)
    case .xl, .xxl:
      return scenarioLoopTemplates(for: profile)
        .filter { scenarioDomains(for: profile).contains($0.domain) }
        .filter { $0.id != TatwoUIFireworksLoopTemplate.id }
        .map(\.id)
    }
  }

  /// Round-robin duplicate the base domain loops as cycle instances until `target` is
  /// reached. Cycle >1 instances carry NO required-for-pass receipts (they report through
  /// their domain's cycle-1 receipt) so scaling loops never inflates the goal-close bar.
  static func expandLoopsToTarget(_ base: [DomainLoop], target: Int) -> [DomainLoop] {
    guard !base.isEmpty, base.count < target else { return base }
    var loops = base
    var cycle = 2
    while loops.count < target {
      for origin in base where loops.count < target {
        loops.append(
          DomainLoop(
            id: "\(origin.id)-c\(cycle)",
            domain: origin.domain,
            title: "\(origin.title) · cycle \(cycle)",
            ownerIdentity: origin.ownerIdentity,
            ownerSourceSlotID: origin.ownerSourceSlotID,
            allowedTools: origin.allowedTools,
            sandboxType: origin.sandboxType,
            requiredReceipts: [],
            status: .planned,
            autonomyLevel: "cycle 實例：內部是完整子 plan+loops+goal，成果回報同域 cycle 1 收據。",
            mergeBackRule: origin.mergeBackRule,
            cycleIndex: cycle))
      }
      cycle += 1
    }
    return loops
  }

  /// Turns a declared multi-lane loops topology into explicit, durable loop
  /// affinity before the contract is issued. Policy D consumes this field; it
  /// never chooses between peer bindings at projection time.
  private static func bindDomainLoopsToIssuedSourceSlots(
    _ loops: [DomainLoop],
    governorDecision: TatwoLoopGovernorDecisionV1
  ) -> [DomainLoop] {
    let loopsBindings = governorDecision.activatedBindings.filter {
      $0.phase == .loops
        && $0.enabled
        && $0.dynamicActivation != .disabled
        && $0.identityKind != nil
    }
    guard !loopsBindings.isEmpty else { return loops }

    return loops.flatMap { loop in
      let candidates = loopsBindings
        .filter { $0.identityKind == loop.ownerIdentity }
        .sorted { $0.id < $1.id }
      guard !candidates.isEmpty else { return [loop] }
      return candidates.enumerated().map { index, binding in
        let secondaryLane = candidates.count > 1 && index > 0
        let affinitySuffix = secondaryLane
          ? "-lane-\(shortHash(binding.id))"
          : ""
        let laneLabel = secondaryLane
          ? " · lane \(binding.id)"
          : ""
        return DomainLoop(
          id: "\(loop.id)\(affinitySuffix)",
          domain: loop.domain,
          title: "\(loop.title)\(laneLabel)",
          ownerIdentity: loop.ownerIdentity,
          ownerSourceSlotID: binding.id,
          allowedTools: loop.allowedTools,
          sandboxType: loop.sandboxType,
          requiredReceipts: loop.requiredReceipts,
          status: loop.status,
          autonomyLevel:
            "\(loop.autonomyLevel) binding-affinity=\(binding.id)",
          mergeBackRule: loop.mergeBackRule,
          cycleIndex: loop.cycleIndex)
      }
    }
  }

  static func scenarioDomains(for profile: ScenarioProfile) -> [WorkOSDomainKind] {
    switch profile.id {
    case "ui-ux", "editing": [.ui, .code, .ops]
    case "debug": [.code, .debug, .ops]
    case "video-research", "modeling": [.research, .modeling, .ops]
    case "trading-risk": [.research, .code, .ops]
    case "daily": [.code, .research, .ops]
    default: [.code, .debug, .ops]
    }
  }

  /// T1 模式強度重校 (2026-07-03, 使用者判定舊值太保守: L 才 1 loop / XL 才 3):
  /// S 維持 mainline only；M 預設 3 個 domain loops、自定義最多 8；
  /// L 預設 8、自定義最多 20；XL 預設 20、自定義最多 64。
  /// 超出 scenario domain 模板數的部分由 cycle 實例展開（同域 c2/c3/…）補足，
  /// 而不是硬造新 domain。helper cap（併發派工 S0/M4/L16/XL48/XXL4）與 loop 數是兩回事：
  /// loop 是工作單位、helper 是同時在跑的人，loop 多於 cap 就排隊。
  private static func maxLoopCount(for mode: WorkModeID, custom: Bool) -> Int {
    switch mode {
    case .s: return 0
    case .m: return custom ? 8 : 3
    case .l: return custom ? 20 : 8
    case .xl: return custom ? 64 : 20
    case .xxl: return custom ? 128 : 40
    }
  }

  private static func budgetNote(for mode: WorkModeID) -> String {
    switch mode {
    case .s: return "S：GPT5.4 + MiniMax M3 可長時間用；主線-only，重點是快速。"
    case .m: return "M：小型協作強度，由 Loop Governor 依 token / 風險動態開副審與 sub。"
    case .l: return "L：深度專案協作，可開多條 loops；重點是收據與副審。"
    case .xl: return "XL：Fable5/GPT5.6 + 全體模型重型協作；重點是 loops 效率與人工 gate。"
    case .xxl: return "XXL：最重型長線協作；多輪 loops + 對抗複核 + 動態 goal 邊界；人工 gate 與收據最嚴。"
    }
  }

  private static func scenarioLoopTemplates(for profile: ScenarioProfile) -> [WorkOSLoopTemplate] {
    let generic = WorkOSDomainKind.allCases.filter { $0 != .custom }.map { kind in
      loopTemplate(kind: kind, owner: ownerIdentity(for: kind, profile: profile))
    }
    let preferredOrder: [WorkOSDomainKind]
    switch profile.id {
    case "ui-ux", "editing":
      preferredOrder = [.ui, .code, .ops, .research, .debug, .modeling]
    case "debug":
      preferredOrder = [.code, .debug, .ops, .research, .ui, .modeling]
    case "video-research":
      preferredOrder = [.research, .modeling, .ops, .code, .ui, .debug]
    case "modeling":
      preferredOrder = [.research, .modeling, .ops, .code, .debug, .ui]
    case "trading-risk":
      preferredOrder = [.research, .code, .ops, .debug, .modeling, .ui]
    case "daily":
      preferredOrder = [.code, .research, .ops, .debug, .ui, .modeling]
    default:
      preferredOrder = [.code, .debug, .ops, .research, .ui, .modeling]
    }
    let rank = Dictionary(
      uniqueKeysWithValues: preferredOrder.enumerated().map { ($0.element, $0.offset) })
    let sorted = generic.sorted { lhs, rhs in
      (rank[lhs.domain] ?? 99, lhs.id) < (rank[rhs.domain] ?? 99, rhs.id)
    }
    guard profile.id == "ui-ux" || profile.id == "editing" else { return sorted }
    return [uiFireworksLoopTemplate()] + sorted
  }

  private static func uiFireworksPreset(
    mode: WorkModeID,
    scenarioProfileID: String,
    templates: [WorkOSLoopTemplate],
    budget: String
  ) -> WorkOSCollaborationPreset? {
    guard templates.contains(where: { $0.id == TatwoUIFireworksLoopTemplate.id }) else { return nil }
    return WorkOSCollaborationPreset(
      id: TatwoUIFireworksLoopTemplate.id,
      displayName: TatwoUIFireworksLoopTemplate.displayName,
      mode: mode,
      scenarioProfileID: scenarioProfileID,
      plainPurpose: TatwoUIFireworksLoopTemplate.plainDescription,
      loopTemplateIDs: [TatwoUIFireworksLoopTemplate.id],
      editable: false,
      isRecommended: false,
      budgetNote: "\(budget) \(TatwoUIFireworksLoopTemplate.branchStructureLabel)；探索 N=\(TatwoUIFireworksLoopTemplate.explorationBranchCount(for: mode))。")
  }

  private static func uiFireworksLoopTemplate() -> WorkOSLoopTemplate {
    WorkOSLoopTemplate(
      id: TatwoUIFireworksLoopTemplate.id,
      domain: .ui,
      title: TatwoUIFireworksLoopTemplate.displayName,
      shortLabel: TatwoUIFireworksLoopTemplate.shortLabel,
      ownerIdentity: .lead,
      defaultEnabledModes: [.s, .m, .l, .xl],
      allowedTools: allowedTools(for: .ui) + [
        "stance allocation table",
        "variant screenshots",
        "eight-dimension scorecards",
        "red-team adjudication",
        "synthesis diff",
      ],
      sandboxType: .tempWorkspace,
      receiptID: "ui-fireworks-final-snapshot",
      receiptTitle: "UI 煙火線 final snapshot",
      plainPurpose: TatwoUIFireworksLoopTemplate.plainDescription,
      mergeBackRule: "探索×N → 八維評審 → 紅隊精煉 → 合成單一候選；合成兩輪不過就降級 Top-1 原案交人類。",
      budgetWeight: 0.34)
  }

  private static func loopTemplate(kind: WorkOSDomainKind, owner: IdentityKind)
    -> WorkOSLoopTemplate
  {
    WorkOSLoopTemplate(
      id: "loop-template-\(kind.rawValue)",
      domain: kind,
      title: "\(kind.plainName) Loop",
      shortLabel: kind.plainName,
      ownerIdentity: owner,
      defaultEnabledModes: kind == .ui || kind == .code || kind == .ops || kind == .research
        || kind == .debug || kind == .modeling ? [.l, .xl] : [.xl],
      allowedTools: allowedTools(for: kind),
      sandboxType: kind == .ops ? .stagingConfig : .tempWorkspace,
      receiptID: "domain-\(kind.rawValue)-loop",
      receiptTitle: "\(kind.plainName) loop receipt",
      plainPurpose: "\(kind.plainName) 區塊自主搭建 / 驗證 / 回報，不直接越權實裝。",
      mergeBackRule: "只提交 receipt / diff intent / finding；由 mainline 合併或 rollback。",
      budgetWeight: budgetWeight(for: kind))
  }

  private static func budgetWeight(for kind: WorkOSDomainKind) -> Double {
    switch kind {
    case .ui: return 0.24
    case .code: return 0.26
    case .debug: return 0.20
    case .research: return 0.18
    case .modeling: return 0.20
    case .ops: return 0.12
    case .custom: return 0.10
    }
  }

  private static func domainKinds(for mode: WorkModeID, profile: ScenarioProfile)
    -> [WorkOSDomainKind]
  {
    switch mode {
    case .s, .m:
      return []
    case .l:
      return [primaryDomain(for: profile)]
    case .xl, .xxl:
      switch profile.id {
      case "ui-ux", "editing":
        return [.ui, .code, .ops]
      case "debug":
        return [.code, .debug, .ops]
      case "video-research":
        return [.research, .modeling, .ops]
      case "modeling":
        return [.research, .modeling, .ops]
      case "trading-risk":
        return [.research, .code, .ops]
      case "daily":
        return [.code, .research, .ops]
      default:
        return [.code, .debug, .ops]
      }
    }
  }

  private static func primaryDomain(for profile: ScenarioProfile) -> WorkOSDomainKind {
    switch profile.id {
    case "ui-ux", "editing": return .ui
    case "debug": return .debug
    case "video-research": return .research
    case "modeling": return .modeling
    case "trading-risk": return .research
    default: return .code
    }
  }

  private static func makeDomainLoops(
    template: WorkOSLoopTemplate,
    mode: WorkModeID,
    profile: ScenarioProfile,
    contractID: String
  ) -> [DomainLoop] {
    guard template.id == TatwoUIFireworksLoopTemplate.id else {
      return [makeDomainLoop(template: template, mode: mode, profile: profile, contractID: contractID)]
    }

    return TatwoUIFireworksLoopTemplate.branchStructure(for: mode).enumerated().map { offset, branch in
      let receipt: WorkOSReceiptRequirement
      let owner: IdentityKind
      let tools: [String]
      switch branch.kind {
      case .exploration:
        receipt = WorkOSReceiptRequirement(
          id: "\(branch.id)-snapshot",
          title: "\(branch.title) snapshot + stance",
          kind: "ui_fireworks_exploration",
          plainPurpose: "探索支線必須提交快照、立場聲明與取捨表。")
        owner = .sub
        tools = template.allowedTools
      case .review:
        receipt = WorkOSReceiptRequirement(
          id: "ui-fireworks-eight-dimension-scorecard",
          title: "UI 煙火線八維評分卡",
          kind: "ui_fireworks_review",
          plainPurpose: "評審支線引用 Core 八維常數，對每個探索方案 0-10 打分並列最強/最弱點。")
        owner = .supervisor
        tools = template.allowedTools + TatwoUIFireworksLoopTemplate.reviewDimensions.map { "dimension:\($0.id)" }
      case .adversarialRefinement:
        receipt = WorkOSReceiptRequirement(
          id: "ui-fireworks-red-team-adjudication",
          title: "UI 煙火線紅隊裁決",
          kind: "ui_fireworks_red_team",
          plainPurpose: "Top-2 互抓三缺陷，主導裁決缺陷是否成立。")
        owner = .supervisor
        tools = template.allowedTools
      case .synthesis:
        receipt = WorkOSReceiptRequirement(
          id: "ui-fireworks-synthesis-diff",
          title: "UI 煙火線合成 diff",
          kind: "ui_fireworks_synthesis",
          plainPurpose: "冠軍為骨、嫁接亞軍最強元素、修成立缺陷，附最終快照。")
        owner = .lead
        tools = template.allowedTools
      }

      return DomainLoop(
        id: "loop-\(branch.id)-\(contractID)",
        domain: .ui,
        title: "\(TatwoUIFireworksLoopTemplate.displayName) · \(branch.title)",
        ownerIdentity: owner,
        allowedTools: uniqueStrings(tools),
        sandboxType: mode >= .xl ? template.sandboxType : .stagingConfig,
        requiredReceipts: [receipt],
        status: .planned,
        autonomyLevel: "UI 煙火線支線 \(offset + 1)/\(TatwoUIFireworksLoopTemplate.totalBranchCount(for: mode))：\(branch.plainPurpose)",
        mergeBackRule: template.mergeBackRule,
        cycleIndex: 1)
    }
  }

  private static func makeDomainLoop(
    template: WorkOSLoopTemplate,
    mode: WorkModeID,
    profile: ScenarioProfile,
    contractID: String
  ) -> DomainLoop {
    let domainReceipt = receipt(
      template.receiptID,
      template.receiptTitle,
      "domain_loop",
      template.plainPurpose)
    let webCheckReceipts = TatwoWebCheckFactory.domainReceiptRequirements(
      mode: mode,
      scenarioProfileID: profile.id,
      domain: template.domain)
    let productDesignReceipts = TatwoProductDesignFactory.domainReceiptRequirements(
      mode: mode,
      scenarioProfileID: profile.id,
      domain: template.domain)
    return DomainLoop(
      id: "loop-\(template.domain.rawValue)-\(contractID)",
      domain: template.domain,
      title: template.title,
      ownerIdentity: template.ownerIdentity,
      allowedTools: template.allowedTools,
      sandboxType: mode >= .xl ? template.sandboxType : .stagingConfig,
      requiredReceipts: uniqueReceipts([domainReceipt] + productDesignReceipts + webCheckReceipts),
      status: .planned,
      autonomyLevel: mode >= .xl ? "區域自主，但不得偏離 mainline contract" : "模式預算內的自定義 loop",
      mergeBackRule: template.mergeBackRule)
  }

  private static func makeDomainLoop(
    kind: WorkOSDomainKind,
    mode: WorkModeID,
    profile: ScenarioProfile,
    contractID: String
  ) -> DomainLoop {
    let owner = ownerIdentity(for: kind, profile: profile)
    let receiptID = "domain-\(kind.rawValue)-loop"
    let productDesignReceipts = TatwoProductDesignFactory.domainReceiptRequirements(
      mode: mode,
      scenarioProfileID: profile.id,
      domain: kind)
    let webCheckReceipts = TatwoWebCheckFactory.domainReceiptRequirements(
      mode: mode,
      scenarioProfileID: profile.id,
      domain: kind)
    return DomainLoop(
      id: "loop-\(kind.rawValue)-\(contractID)",
      domain: kind,
      title: "\(kind.plainName) Domain Loop",
      ownerIdentity: owner,
      allowedTools: allowedTools(for: kind),
      sandboxType: mode >= .xl ? .tempWorkspace : .stagingConfig,
      requiredReceipts: uniqueReceipts([
        receipt(
          receiptID, "\(kind.plainName) loop receipt", "domain_loop",
          "\(kind.plainName) 自主搭建/驗證後回到 mainline 合併。")
      ] + productDesignReceipts + webCheckReceipts),
      status: .planned,
      autonomyLevel: mode >= .xl ? "區域自主，但不得偏離 mainline contract" : "單領域深 loop",
      mergeBackRule:
        "domain loop 只提交 receipt / diff intent / finding；由 mainline judge 合併或 rollback。")
  }

  private static func ownerIdentity(for kind: WorkOSDomainKind, profile: ScenarioProfile)
    -> IdentityKind
  {
    switch kind {
    case .research: return profile.allowsNewsIdentity ? .news : .consultant
    case .ops: return .verifier
    case .debug: return .supervisor
    case .ui: return .lead
    case .code, .modeling, .custom: return .sub
    }
  }

  private static func allowedTools(for kind: WorkOSDomainKind) -> [String] {
    switch kind {
    case .ui:
      return [
        "staging app data", "swift build", "screenshot / visual smoke",
        "product-design screenshot audit", "web-check local JSON scan",
        "tatwo.os.receipt.submit",
      ]
    case .code:
      return [
        "git diff", "swift test", "targeted CLI smoke", "web-check if frontend changed",
        "host apply_patch only after contract",
      ]
    case .debug:
      return [
        "read-only logs", "targeted reproduction", "web-check why file:line for frontend",
        "minimal patch intent", "regression test",
      ]
    case .research:
      return [
        "source check", "chatgpt-pro-mcp research receipt", "grok/news lane if installed",
        "claim/evidence table",
      ]
    case .modeling:
      return [
        "modeling checklist", "artifact validation", "first-principles review", "handoff pack",
      ]
    case .ops:
      return [
        "doctor --json", "sandbox preflight", "web-check report hash / redaction", "backup plan",
        "rollback plan", "redaction scan",
      ]
    case .custom:
      return ["declared tools only", "tatwo.os.receipt.submit"]
    }
  }

  private static func makeSandboxPolicy(mode: WorkModeID) -> WorkOSSandboxPolicy {
    WorkOSSandboxPolicy(
      required: mode >= .l,
      defaultType: mode >= .l ? .tempWorkspace : (mode == .m ? .stagingConfig : .none),
      allowedTypes: mode >= .l
        ? [.tempWorkspace, .colimaDryRun, .stagingConfig] : [.none, .stagingConfig],
      stagingConfigRequired: true,
      hostMutationAllowed: false,
      humanGateRequired: mode >= .xl,
      promotionRule: "staging config + sandbox selftest 通過後，才可由人類授權升 active；App 可視化不能直接放行。",
      forbiddenTargets: [
        "~/.codex real state",
        "signed Codex App bundle",
        "real LaunchAgent",
        "auth/session/token/browser profiles",
      ])
  }

  private static func makeStopRules(
    mode: WorkModeID,
    modePlan: ModeIdentityPlan,
    profile: ScenarioProfile,
    hasFanOut: Bool = false
  ) -> [String] {
    var rules = modePlan.stopRules
    rules.append("沒有 contractID 的 action / receipt / close 直接 fail closed。")
    rules.append("receipt 不足時 GoalRun 只能是 blocked 或 rollback_required。")
    rules.append("App/visualizer 只讀，不可直接 pass。")
    rules.append("所有沙盒都必須遵循 plan+loops+goal-主線 與 plan+loops+goal-支線優化。")
    rules.append("正式工作 goal 不限制次數；以 token、風險、人工 gate 與有效推進控制。")
    rules.append("沙盒評分才限制最多 5 次 execution cycles；plan 與 loop-ledger 不限量，封存後立即進評分。")
    rules.append("模型自行選 MCP/skills，但只能從 Ultrawork registry 登記項目選，並記錄 tool-choice-ledger。")
    rules.append("驗收成功後必須進入可移除檔案盤點，產生 cleanup-inventory Markdown 並放入待刪/垃圾桶審核包；真刪除必須人工核准。")
    rules.append("高階雙主導或主導+副審時，Plan 階段可跑對抗驗證迴圈（各模型獨立分析→refute-first 攻弱點→主導收斂），並記錄 plan-ledger 收據，使 Plan 更自動、客觀、縝密。")
    rules += dispatchSupervisionHardRules(hasFanOut: hasFanOut)
    if profile.baseScenario == .design {
      rules.append("UI/UJ 缺截圖或互動證據時，不可宣稱完成。")
    }
    return Array(NSOrderedSet(array: rules)) as? [String] ?? rules
  }

  private static func dispatchSupervisionHardRules(hasFanOut: Bool = true) -> [String] {
    guard hasFanOut else { return [] }
    return [
      "background host dispatch（codex exec 或等價工具）必須顯式關閉 stdin：codex exec ... < /dev/null。",
      "dispatch 必須約 2 分鐘內確認起跑：需看到超過 header / prompt echo 的輸出；否則不得報 running。",
      "dispatch 必須有 10 分鐘 stall watchdog：無 output growth 就告警並由 lead 介入。",
      "派工期間 lead / supervisor 必須約每 10 分鐘巡檢 process liveness、output growth、changed-file count、scope drift。",
      "任何超出 allowed paths 的變更需立即記錄 allow-with-note 或 reject-and-redo；未裁決 scope drift 阻擋通過。",
      "goal tracker 必須在 OS activation 建立；缺可視 tracker 證據時 tatwo.os.next 回 goal_tracker_missing。",
      // 2026-07-13 對抗驗證定案（fable5+sol+terra）
      "App 是控制台不是 loops 引擎：GUI 不得直接 spawn codex exec 當主要執行路徑；loops 執行走 OS 受契約治理的 dispatch（gateway route 或受治理背景 codex exec，都帶 contractID + 看門狗）。",
      "所有 loops 執行（cowork / gateway / 背景 dispatch）寫入單一 dispatch ledger/registry（唯一真相源）；App 只讀 ledger 顯示，不得建平行寫源。",
      "loops 引擎只認身份組（主導/副審/Sub/驗收），模型執行時經 WorkOSIdentityBinding 解析，禁止在引擎內寫死任何模型名。",
    ]
  }

  private static func nextBlockingStates(
    contract: TatwoWorkOSContractV1,
    remainingReceiptIDs: [String],
    storedReceiptIDs: Set<String>?,
    storeBacked: Bool,
    registry: TatwoDispatchRegistry?,
    contractID: String
  ) -> [String] {
    guard !contract.domainLoops.isEmpty else { return [] }
    let remaining = Set(remainingReceiptIDs)
    var states: [String] = []
    if storeBacked, remaining.contains("goal-tracker") {
      states.append("goal_tracker_missing")
    }
    if let registry,
      let run = try? registry.run(forContractID: contractID),
      run.records.contains(where: { $0.status == .queued || $0.status == .running }),
      remaining.contains("supervision-patrol")
    {
      states.append("supervision_gap")
    }
    return uniqueStrings(states)
  }

  private static func nextBlockingMessage(for states: [String]) -> String {
    var messages: [String] = []
    if states.contains("goal_tracker_missing") {
      messages.append("goal_tracker_missing：有 fan-out 目標但沒有可視 goal tracker / GoalRun task-board 收據；先提交 goal-tracker。")
    }
    if states.contains("supervision_gap") {
      messages.append("supervision_gap：已有派工但缺 supervision-patrol；lead 必須巡檢 process/output/files/scope drift 後提交收據。")
    }
    return messages.joined(separator: " ")
  }

  private static func makeShowLoopsProjection(
    goalID: String,
    contractID: String,
    goalStatus: GoalRunStatus,
    mainlineLoop: MainlineLoop,
    domainLoops: [DomainLoop],
    receipts: [WorkOSReceiptRequirement],
    sandboxPolicy: WorkOSSandboxPolicy
  ) -> WorkOSShowLoopsProjection {
    var nodes: [WorkOSShowLoopNode] = [
      WorkOSShowLoopNode(
        id: "task-intake",
        kind: .goal,
        title: "任務開始",
        ownerIdentity: .lead,
        status: goalStatus,
        receiptIDs: ["contract-id", "mode-budget"],
        canPromoteRunState: false,
        plainPurpose: "人類目標先進 GoalRun；AI 不直接跳工具或自行分工。"),
      WorkOSShowLoopNode(
        id: "contract",
        kind: .contract,
        title: "OS Contract",
        ownerIdentity: .lead,
        status: .planned,
        receiptIDs: ["contract-id", "identity-bindings"],
        canPromoteRunState: false,
        plainPurpose: "每個 action 都要帶 \(contractID)；缺 contractID 即 fail closed。"),
      WorkOSShowLoopNode(
        id: "plan-lead",
        kind: .mainline,
        title: "Plan / 主導",
        ownerIdentity: .lead,
        status: mainlineLoop.status,
        receiptIDs: mainlineLoop.requiredReceipts.map(\.id),
        canPromoteRunState: false,
        plainPurpose: "主導負責宏觀架構、工作標準、停止線與支線拆分。"),
      WorkOSShowLoopNode(
        id: "loops-cycle",
        kind: .mainline,
        title: "Loops / 副審 + Sub",
        ownerIdentity: .supervisor,
        status: .running,
        receiptIDs: ["reviewer-gate"],
        canPromoteRunState: false,
        plainPurpose: "副審監督支線 plan+loops+goal；sub 做量化、繁瑣、反例與便宜高頻工作。"),
    ]

    nodes += domainLoops.map { loop in
      WorkOSShowLoopNode(
        id: loop.id,
        kind: .domain,
        title: "支線 / \(loop.title)",
        ownerIdentity: loop.ownerIdentity,
        status: loop.status,
        receiptIDs: loop.requiredReceipts.map(\.id),
        canPromoteRunState: false,
        plainPurpose: "支線內部也必須跑 plan+loops+goal；\(loop.autonomyLevel)；\(loop.mergeBackRule)")
    }

    nodes += [
      WorkOSShowLoopNode(
        id: "supervisor-gate",
        kind: .gate,
        title: "副審驗收",
        ownerIdentity: .supervisor,
        status: .planned,
        receiptIDs: ["reviewer-gate"],
        canPromoteRunState: false,
        plainPurpose: "副審先擋錯誤與偏航；不過退回支線，通過才送主導。"),
      WorkOSShowLoopNode(
        id: "goal-lead-gate",
        kind: .gate,
        title: "Goal / 主導驗收",
        ownerIdentity: .lead,
        status: goalStatus,
        receiptIDs: receipts.map(\.id),
        canPromoteRunState: false,
        plainPurpose: "主導驗副審結論與支線是否離題；不過重派 loops，通過才收據入庫。"),
      WorkOSShowLoopNode(
        id: "receipts",
        kind: .receipt,
        title: "Receipts / 收據庫",
        ownerIdentity: .verifier,
        status: .planned,
        receiptIDs: receipts.map(\.id),
        canPromoteRunState: false,
        plainPurpose: "收測試、截圖、review、sandbox、rollback；缺必要收據不 pass。"),
      WorkOSShowLoopNode(
        id: "cleanup-inventory",
        kind: .receipt,
        title: "Cleanup Inventory",
        ownerIdentity: .verifier,
        status: .planned,
        receiptIDs: [PostValidationCleanupInventoryFactory.receiptID],
        canPromoteRunState: false,
        plainPurpose: "驗收成功後盤點可移除檔案，寫 README-待刪檔案來源.md，和候選垃圾檔一起進待刪審核包。"),
      WorkOSShowLoopNode(
        id: "sandbox-gate",
        kind: .gate,
        title: sandboxPolicy.required ? "Sandbox Gate" : "Staging Gate",
        ownerIdentity: .verifier,
        status: sandboxPolicy.required ? .humanGate : .planned,
        receiptIDs: sandboxPolicy.required ? ["sandbox"] : ["local-check"],
        canPromoteRunState: false,
        plainPurpose: sandboxPolicy.promotionRule),
      WorkOSShowLoopNode(
        id: "finish-human",
        kind: .gate,
        title: "完工 / 提交人類",
        ownerIdentity: .lead,
        status: goalStatus,
        receiptIDs: ["human-gate"],
        canPromoteRunState: false,
        plainPurpose: "App 視覺化只表示 ready/rollback；真正放行仍由人類確認。"),
    ]

    var edges: [WorkOSShowLoopEdge] = [
      WorkOSShowLoopEdge(id: "edge-task-contract", from: "task-intake", to: "contract", label: "begin"),
      WorkOSShowLoopEdge(id: "edge-contract-plan", from: "contract", to: "plan-lead", label: "主導 plan"),
      WorkOSShowLoopEdge(id: "edge-plan-loops", from: "plan-lead", to: "loops-cycle", label: "分派 loops"),
    ]

    if domainLoops.isEmpty {
      edges.append(
        WorkOSShowLoopEdge(
          id: "edge-loops-supervisor-direct", from: "loops-cycle", to: "supervisor-gate",
          label: "direct review"))
    } else {
      edges += domainLoops.map { loop in
        WorkOSShowLoopEdge(
          id: "edge-loops-\(loop.id)",
          from: "loops-cycle",
          to: loop.id,
          label: "支線 plan+loops+goal")
      }
      edges += domainLoops.map { loop in
        WorkOSShowLoopEdge(
          id: "edge-\(loop.id)-supervisor",
          from: loop.id,
          to: "supervisor-gate",
          label: "提交副審")
      }
    }

    edges += [
      WorkOSShowLoopEdge(id: "edge-supervisor-reject", from: "supervisor-gate", to: "loops-cycle", label: "副審不過重跑"),
      WorkOSShowLoopEdge(id: "edge-supervisor-pass", from: "supervisor-gate", to: "goal-lead-gate", label: "副審通過送主導"),
      WorkOSShowLoopEdge(id: "edge-goal-reject", from: "goal-lead-gate", to: "loops-cycle", label: "主導不過重派"),
      WorkOSShowLoopEdge(id: "edge-goal-receipts", from: "goal-lead-gate", to: "receipts", label: "主導通過收據入庫"),
      WorkOSShowLoopEdge(id: "edge-receipts-cleanup", from: "receipts", to: "cleanup-inventory", label: "post-pass inventory"),
      WorkOSShowLoopEdge(id: "edge-cleanup-sandbox", from: "cleanup-inventory", to: "sandbox-gate", label: "close gate"),
      WorkOSShowLoopEdge(id: "edge-sandbox-finish", from: "sandbox-gate", to: "finish-human", label: "ready or rollback"),
    ]

    return WorkOSShowLoopsProjection(
      sourceURL: "https://github.com/JNSlayer2/show-loops",
      sourceStatus:
        "optional_external_repo_not_accessible_or_private; using local show-loops-compatible projection",
      projectionStyle: "show-loops-compatible-plan-loops-goal-cycle",
      readOnly: true,
      visualizerCanPromoteRunState: false,
      layoutHint:
        "任務開始 → OS Contract → Plan(主導) → Loops(副審+Sub) → 支線 plan+loops+goal → 副審 Gate → Goal(主導驗收) → 收據 / cleanup / sandbox → 完工；不過就回 loops。",
      nodes: nodes,
      edges: edges)
  }

  private static func receipt(_ id: String, _ title: String, _ kind: String, _ purpose: String)
    -> WorkOSReceiptRequirement
  {
    WorkOSReceiptRequirement(id: id, title: title, kind: kind, plainPurpose: purpose)
  }

  private static func uniqueReceipts(_ receipts: [WorkOSReceiptRequirement])
    -> [WorkOSReceiptRequirement]
  {
    var seen = Set<String>()
    return receipts.filter { seen.insert($0.id).inserted }
  }

  private static func shortHash(_ raw: String) -> String {
    shortHash(Data(raw.utf8))
  }

  private static func shortHash(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }

  private static func canonicalJSONSHA256<T: Encodable>(_ value: T) throws -> String {
    sha256(try canonicalJSONData(value))
  }

  private static func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
}
