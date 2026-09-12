import XCTest

@testable import TatwoUltraworkCore

/// Phase 0 hardening tests. Each proves that a fail-closed promise that was cosmetic in the
/// stateless design becomes real once a `TatwoGoalRunStore` is injected — and that the legacy
/// store-less path is byte-for-byte unchanged (so the existing suite stays valid).
final class GoalRunStoreTests: XCTestCase {
  private func makeStore() -> (TatwoGoalRunStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    return (TatwoGoalRunStore(directoryURL: root), root)
  }

  private func requiredIDs(_ contract: TatwoWorkOSContractV1) -> [String] {
    contract.receiptRequirements.filter(\.requiredForPass).map(\.id)
  }

  func testKnownNoSpaceStateRootNormalizesButArbitraryExplicitRootDoesNot() {
    let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
    let legacy = applicationSupport
      .appendingPathComponent("TatwoUltrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
    let canonical = applicationSupport
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
    XCTAssertEqual(
      TatwoGoalRunStore(directoryURL: legacy).directoryURL.standardizedFileURL,
      canonical.standardizedFileURL)

    let arbitrary = FileManager.default.temporaryDirectory
      .appendingPathComponent("TatwoUltrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
    XCTAssertEqual(TatwoGoalRunStore(directoryURL: arbitrary).directoryURL, arbitrary)
  }

  func testImplicitDefaultPathResolutionDoesNotMutateStateDirectoryEntries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-goal-store-default-resolution-\(UUID().uuidString)",
      isDirectory: true)
    let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
    let state = appSupport
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let sentinel = state.appendingPathComponent("existing.json")
    try Data("sentinel".utf8).write(to: sentinel)
    defer { try? FileManager.default.removeItem(at: root) }

    let before = try Set(FileManager.default.contentsOfDirectory(atPath: state.path))
    for _ in 0..<20 {
      XCTAssertEqual(
        TatwoGoalRunStore.implicitDefaultDirectory(
          environment: [:],
          applicationSupportBase: appSupport),
        state.standardizedFileURL)
    }
    let after = try Set(FileManager.default.contentsOfDirectory(atPath: state.path))

    XCTAssertEqual(after, before)
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
  }

  func testExplicitStateDirectoryNeverSilentlyFallsBack() {
    let explicit = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-explicit-state-\(UUID().uuidString)")
      .appendingPathComponent("blocked-parent")
      .appendingPathComponent("state")

    XCTAssertEqual(
      TatwoGoalRunStore.default(
        environment: ["TATWO_ULTRAWORK_STATE_DIR": explicit.path]
      ).directoryURL.path,
      explicit.standardizedFileURL.path)
  }

  func testImplicitDefaultFallsBackWhenExistingAncestorIsNotDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-goal-store-unwritable-ancestor-\(UUID().uuidString)")
    try Data("not-a-directory".utf8).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolved = TatwoGoalRunStore.implicitDefaultDirectory(
      environment: [:],
      applicationSupportBase: root)
    let expected = FileManager.default.temporaryDirectory
      .appendingPathComponent("Tatwo Ultrawork", isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)

    XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    XCTAssertEqual(try Data(contentsOf: root), Data("not-a-directory".utf8))
  }

  // MARK: Registry

  func testBeginRegistersIssuedContractInStore() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "phase0", store: store)

    let record = try store.record(forContractID: contract.contractID)
    XCTAssertNotNil(record)
    XCTAssertEqual(record?.contractID, contract.contractID)
    XCTAssertEqual(record?.mode, .xl)
    XCTAssertEqual(record?.scenario, contract.scenario)
    XCTAssertEqual(record?.receipts.map(\.receiptID), ["goal-tracker"])
    XCTAssertEqual(
      record?.issuedIdentityBindings,
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract))
    XCTAssertEqual(
      record?.issuedIdentityBindingsDigest,
      TatwoIssuedIdentityBindingV1.deterministicDigest(
        for: TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)))
    XCTAssertEqual(
      try store.requireIssuedIdentityBindings(contractID: contract.contractID),
      record?.issuedIdentityBindings)
    XCTAssertEqual(
      try store.requireIssuedIdentityBindingsDigest(contractID: contract.contractID),
      record?.issuedIdentityBindingsDigest)
    XCTAssertNoThrow(try store.verifyIssuedIdentityBindings(contract: contract))
  }

  func testRecordBeginIsIdempotentAndPreservesReceipts() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m, scenarioProfileID: "coding", objective: "idem", store: store)
    _ = WorkOSFactory.submitReceipt(
      goalID: contract.goalID, contractID: contract.contractID, loopID: nil,
      receiptID: "scope-review", receiptKind: "scope", store: store)

    // Re-begin the same contract must not wipe the journaled receipt.
    _ = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m, scenarioProfileID: "coding", objective: "idem", store: store)

    let submitted = try store.submittedReceiptIDs(contractID: contract.contractID)
    XCTAssertTrue(submitted.contains("scope-review"))
  }

  func testGoalRunSnapshotDetectsExactByteRevisionChange() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "exact persisted GoalRun snapshot",
      store: store)
    let snapshot = try store.snapshot(forContractID: contract.contractID)

    XCTAssertEqual(snapshot.record.contractID, contract.contractID)
    XCTAssertTrue(try store.verifyCurrent(snapshot))

    // Re-encode the same decoded values with different JSON formatting. Exact
    // revision verification must reject the replacement even though it decodes
    // to an equal GoalRun.
    let url = try store.fileURL(forContractID: contract.contractID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(snapshot.record).write(to: url, options: [.atomic])

    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID),
      snapshot.record)
    XCTAssertFalse(try store.verifyCurrent(snapshot))
  }

  func testGoalRunSnapshotRejectsInterveningReceiptMutation() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "snapshot must fence receipt mutation",
      store: store)
    let snapshot = try store.snapshot(forContractID: contract.contractID)

    _ = try store.appendReceipt(
      contractID: contract.contractID,
      receiptID: "snapshot-intervening-receipt",
      kind: "snapshot-test",
      loopID: contract.mainlineLoop.id)

    XCTAssertFalse(try store.verifyCurrent(snapshot))
    XCTAssertFalse(
      snapshot.record.receipts.contains {
        $0.receiptID == "snapshot-intervening-receipt"
      })
  }

  func testStoredContractProjectionUsesOnlySuppliedGoalRunSnapshot() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "project one exact GoalRun revision",
      store: store)
    let snapshot = try store.snapshot(forContractID: contract.contractID)

    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .dispatching)
    let projected = try WorkOSFactory.storedContractProjection(
      snapshot: snapshot,
      store: store)

    XCTAssertEqual(snapshot.record.status, .planned)
    XCTAssertEqual(projected.goalRun.status, .planned)
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .dispatching)
    XCTAssertFalse(try store.verifyCurrent(snapshot))
  }

  func testStoredContractProjectionRejectsScenarioIdentityBindingDrift() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "daily",
      objective: "issued routing is immutable",
      store: store)

    var driftedBook = TatwoScenarioConfigDefaults.book
    let scenarioIndex = try XCTUnwrap(
      driftedBook.scenarios.firstIndex(where: { $0.id == contract.scenario }))
    var scenario = driftedBook.scenarios[scenarioIndex]
    var modeConfig = try XCTUnwrap(scenario.modeConfigs[.m])
    let bindingIndex = try XCTUnwrap(
      modeConfig.bindings.firstIndex(where: { !$0.boundModelIDs.isEmpty }))
    modeConfig.bindings[bindingIndex].boundModelIDs = ["drifted-route"]
    scenario.modeConfigs[.m] = modeConfig
    driftedBook.scenarios[scenarioIndex] = scenario

    XCTAssertThrowsError(
      try WorkOSFactory.storedContractProjection(
        contractID: contract.contractID,
        fallbackMode: .s,
        fallbackScenarioProfileID: "daily",
        scenarioBook: driftedBook,
        store: store)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsMismatch(contract.contractID))
    }
  }

  func testStoredContractProjectionUpgradesOnlyLegacyNativeDevelopmentToolBridgeBindings()
    throws
  {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID,
      objective: "project the issued native-development contract")
    let currentBindings =
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
    let legacySourceSlotIDs: Set<String> = [
      TatwoNativeDevelopmentDispatchCoordinator.solExecutorSourceSlotID,
      TatwoNativeDevelopmentDispatchCoordinator.opusSupervisorSourceSlotID,
    ]
    let legacyBindings = currentBindings.map { binding in
      guard legacySourceSlotIDs.contains(binding.sourceSlotID) else {
        return binding
      }
      return TatwoIssuedIdentityBindingV1(
        id: binding.id,
        sourceSlotID: binding.sourceSlotID,
        identity: binding.identity,
        modelID: binding.modelID,
        authority: .brainOnly,
        engineID: binding.engineID,
        reasoningEffort: binding.reasoningEffort,
        canMutateHost: false)
    }
    XCTAssertEqual(
      legacyBindings.filter {
        legacySourceSlotIDs.contains($0.sourceSlotID)
          && $0.authority == .brainOnly
          && !$0.canMutateHost
      }.count,
      2)

    let record = TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      routeBindingOverride: contract.routeBindingOverride,
      issuedIdentityBindings: legacyBindings,
      issuedIdentityBindingsDigest:
        TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: legacyBindings),
      status: .planned,
      issuedAt: Date(timeIntervalSince1970: 1_785_427_200))
    let url = try store.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: url, options: [.atomic])

    let projected = try WorkOSFactory.storedContractProjection(
      contractID: contract.contractID,
      fallbackMode: .s,
      fallbackScenarioProfileID: "daily",
      store: store)
    let projectedBindings =
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: projected)
    XCTAssertEqual(projectedBindings, currentBindings)
    XCTAssertNoThrow(
      try store.verifyIssuedIdentityBindings(contract: projected))
    XCTAssertEqual(
      projectedBindings.filter {
        legacySourceSlotIDs.contains($0.sourceSlotID)
          && $0.authority == .toolIntentBridge
          && $0.canMutateHost
      }.count,
      2)

    let storedAfterProjection =
      try store.requireIssuedContract(contract.contractID)
    XCTAssertEqual(
      storedAfterProjection.issuedIdentityBindings,
      TatwoIssuedIdentityBindingV1.canonicalized(legacyBindings))
    XCTAssertEqual(
      storedAfterProjection.issuedIdentityBindingsDigest,
      TatwoIssuedIdentityBindingV1.deterministicDigest(
        for: legacyBindings))
    XCTAssertTrue(
      TatwoConfigAuditLog(directoryURL: root).entries().contains {
        $0.action == "legacy_binding_upgrade_grandfathered"
      })
  }

  func testLegacyNativeDevelopmentCompatibilityRejectsContractIssuedAtCutoff()
    throws
  {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID,
      objective: "reject post-cutoff legacy native-development bindings")
    let legacySourceSlotIDs: Set<String> = [
      TatwoNativeDevelopmentDispatchCoordinator.solExecutorSourceSlotID,
      TatwoNativeDevelopmentDispatchCoordinator.opusSupervisorSourceSlotID,
    ]
    let legacyBindings =
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract).map {
        binding in
        guard legacySourceSlotIDs.contains(binding.sourceSlotID) else {
          return binding
        }
        return TatwoIssuedIdentityBindingV1(
          id: binding.id,
          sourceSlotID: binding.sourceSlotID,
          identity: binding.identity,
          modelID: binding.modelID,
          authority: .brainOnly,
          engineID: binding.engineID,
          reasoningEffort: binding.reasoningEffort,
          canMutateHost: false)
      }
    let record = TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      routeBindingOverride: contract.routeBindingOverride,
      issuedIdentityBindings: legacyBindings,
      issuedIdentityBindingsDigest:
        TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: legacyBindings),
      status: .planned,
      issuedAt:
        TatwoLegacyNativeDevelopmentBindingUpgradePolicy
          .grandfatheringCutoff)
    let url = try store.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: url, options: [.atomic])

    XCTAssertThrowsError(
      try WorkOSFactory.storedContractProjection(
        contractID: contract.contractID,
        fallbackMode: .s,
        fallbackScenarioProfileID: "daily",
        store: store)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsMismatch(contract.contractID))
    }
    XCTAssertFalse(
      TatwoConfigAuditLog(directoryURL: root).entries().contains {
        $0.action == "legacy_binding_upgrade_grandfathered"
      })
  }

  func testLegacyNativeDevelopmentCompatibilityRejectsOtherIssuedBindingDrift()
    throws
  {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.nativeDevelopmentXXLSolOpusScenarioID,
      objective: "reject non-authority drift in legacy compatibility")
    let legacySourceSlotIDs: Set<String> = [
      TatwoNativeDevelopmentDispatchCoordinator.solExecutorSourceSlotID,
      TatwoNativeDevelopmentDispatchCoordinator.opusSupervisorSourceSlotID,
    ]
    let driftedBindings =
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract).map {
        binding in
        guard legacySourceSlotIDs.contains(binding.sourceSlotID) else {
          return binding
        }
        return TatwoIssuedIdentityBindingV1(
          id: binding.id,
          sourceSlotID: binding.sourceSlotID,
          identity: binding.identity,
          modelID:
            binding.sourceSlotID
              == TatwoNativeDevelopmentDispatchCoordinator.solExecutorSourceSlotID
              ? "drifted-model"
              : binding.modelID,
          authority: .brainOnly,
          engineID: binding.engineID,
          reasoningEffort: binding.reasoningEffort,
          canMutateHost: false)
      }
    let record = TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      routeBindingOverride: contract.routeBindingOverride,
      issuedIdentityBindings: driftedBindings,
      issuedIdentityBindingsDigest:
        TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: driftedBindings),
      status: .planned)
    let url = try store.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: url, options: [.atomic])

    XCTAssertThrowsError(
      try WorkOSFactory.storedContractProjection(
        contractID: contract.contractID,
        fallbackMode: .s,
        fallbackScenarioProfileID: "daily",
        store: store)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsMismatch(contract.contractID))
    }
  }

  func testRerecordSameContractPreservesOriginalIssuedIdentitySnapshot() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "daily",
      objective: "same contract different config",
      store: store)
    let before = try store.requireIssuedContract(original.contractID)

    var driftedBook = TatwoScenarioConfigDefaults.book
    let scenarioIndex = try XCTUnwrap(
      driftedBook.scenarios.firstIndex(where: { $0.id == original.scenario }))
    var scenario = driftedBook.scenarios[scenarioIndex]
    var modeConfig = try XCTUnwrap(scenario.modeConfigs[.m])
    let bindingIndex = try XCTUnwrap(
      modeConfig.bindings.firstIndex(where: { !$0.boundModelIDs.isEmpty }))
    modeConfig.bindings[bindingIndex].boundModelIDs = ["must-not-overwrite-issued-snapshot"]
    scenario.modeConfigs[.m] = modeConfig
    driftedBook.scenarios[scenarioIndex] = scenario

    XCTAssertThrowsError(
      try WorkOSFactory.issueDetachedFixtureForTesting(
        mode: .m,
        scenarioProfileID: "daily",
        objective: "same contract different config",
        scenarioBook: driftedBook,
        store: store)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsMismatch(original.contractID))
    }

    let after = try store.requireIssuedContract(original.contractID)
    XCTAssertEqual(after.issuedIdentityBindings, before.issuedIdentityBindings)
    XCTAssertEqual(after.issuedIdentityBindingsDigest, before.issuedIdentityBindingsDigest)
  }

  func testLegacyRecordDecodesButStrictIdentityBindingReadFails() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .s, scenarioProfileID: "daily", objective: "legacy snapshot fixture")
    let legacy = TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      status: .planned)
    let url = try store.fileURL(forContractID: contract.contractID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(legacy).write(to: url, options: [.atomic])

    XCTAssertNotNil(try store.record(forContractID: contract.contractID))
    XCTAssertThrowsError(
      try store.requireIssuedIdentityBindings(contractID: contract.contractID)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsUnavailable(contract.contractID))
    }
    XCTAssertThrowsError(
      try store.requireIssuedIdentityBindingsDigest(contractID: contract.contractID)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsUnavailable(contract.contractID))
    }
    XCTAssertNoThrow(
      try WorkOSFactory.storedContractProjection(
        contractID: contract.contractID,
        fallbackMode: .xl,
        fallbackScenarioProfileID: "ui-ux",
        store: store))

    _ = try store.recordBegin(contract: contract)
    let rerecordedLegacy = try store.requireIssuedContract(contract.contractID)
    XCTAssertNil(rerecordedLegacy.issuedIdentityBindings)
    XCTAssertNil(rerecordedLegacy.issuedIdentityBindingsDigest)
  }

  func testIssuedIdentityBindingDigestIsDeterministicAndOrderSafe() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: TatwoScenarioConfigDefaults.exactXXLSolFableLunaGrokScenarioID,
      objective: "digest order")
    let bindings = TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)

    XCTAssertTrue(bindings.contains { $0.reasoningEffort == .xhigh })
    XCTAssertEqual(
      TatwoIssuedIdentityBindingV1.deterministicDigest(for: bindings),
      TatwoIssuedIdentityBindingV1.deterministicDigest(for: Array(bindings.reversed())))
  }

  func testGoalRunStatusSchemaAcceptsDispatchLifecycleWithoutDroppingLegacyCases() {
    for raw in ["dispatching", "succeeded", "failed", "cancelled"] {
      XCTAssertNotNil(GoalRunStatus(rawValue: raw), raw)
    }
    for raw in ["planned", "running", "human_gate", "blocked", "passed", "rollback_required"] {
      XCTAssertNotNil(GoalRunStatus(rawValue: raw), raw)
    }
  }

  func testPlannedGoalCannotJumpDirectlyToRunningWithoutLedgerBeginAck() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "state machine", store: store)

    XCTAssertThrowsError(
      try store.updateStatus(contractID: contract.contractID, status: .running))
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .planned)
  }

  func testDispatchLifecycleRejectsSucceededThroughGenericStatusAPI() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "legal lifecycle", store: store)

    XCTAssertEqual(
      try store.updateStatus(contractID: contract.contractID, status: .dispatching).status,
      .dispatching)
    XCTAssertThrowsError(
      try store.updateStatus(contractID: contract.contractID, status: .running))
    XCTAssertEqual(
      try store.updateStatus(
        contractID: contract.contractID,
        status: .running,
        authority: .ledgerBeginAck,
        evidence: .ledger(dispatchID: "dispatch-test")).status,
      .running)
    XCTAssertThrowsError(
      try store.updateStatus(contractID: contract.contractID, status: .succeeded))
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .running)
  }

  func testCooldownTransitionCanOnlyRoundTripPlannedAndBlocked() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "cooldown lifecycle", store: store)

    XCTAssertEqual(
      try store.updateStatus(
        contractID: contract.contractID,
        status: .blocked,
        authority: .cooldownFence,
        reason: "session_limit").status,
      .blocked)
    XCTAssertEqual(
      try store.updateStatus(
        contractID: contract.contractID,
        status: .planned,
        authority: .cooldownFence,
        reason: "probe_passed").status,
      .planned)
  }

  func testCallerCannotAssertDispatchRetryOrLedgerAcknowledgeAuthority() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let retryContract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "authority retry", store: store)
    _ = try store.updateStatus(
      contractID: retryContract.contractID,
      status: .blocked,
      authority: .cooldownFence,
      reason: "blocked")

    XCTAssertThrowsError(
      try store.updateStatus(
        contractID: retryContract.contractID,
        status: .dispatching,
        authority: .dispatchRetry,
        reason: "forged retry"))
    XCTAssertEqual(
      try store.requireIssuedContract(retryContract.contractID).status,
      .blocked)

    let ackContract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "authority ack", store: store)
    _ = try store.updateStatus(
      contractID: ackContract.contractID,
      status: .dispatching)
    XCTAssertThrowsError(
      try store.updateStatus(
        contractID: ackContract.contractID,
        status: .running,
        authority: .ledgerBeginAck,
        reason: "forged ack"))
    XCTAssertEqual(
      try store.requireIssuedContract(ackContract.contractID).status,
      .dispatching)
  }

  // MARK: Receipt authenticity

  func testSubmitReceiptRejectsUnregisteredContract() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    // No begin() ever registered this contractID.
    let result = WorkOSFactory.submitReceipt(
      goalID: "goal-xl-coding-aaaaaaaaaaaa",
      contractID: "contract-xl-coding-aaaaaaaaaaaa",
      loopID: nil, receiptID: "scope-review", receiptKind: "scope", store: store)

    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.decision.code, "unregistered_contract")
  }

  func testSubmitReceiptJournalsAgainstIssuedContract() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l, scenarioProfileID: "coding", objective: "journal", store: store)
    let result = WorkOSFactory.submitReceipt(
      goalID: contract.goalID, contractID: contract.contractID, loopID: nil,
      receiptID: "rollback", receiptKind: "rollback", store: store)

    XCTAssertTrue(result.ok)
    let submitted = try store.submittedReceiptIDs(contractID: contract.contractID)
    XCTAssertEqual(submitted, ["goal-tracker", "rollback"])
  }

  // M4b 更新：真實 artifact ID 保持為 receiptID，只能明確滿足 issued requirement。
  func testEvidenceReceiptRequirementBindingIsExactIdempotentAndCloseVisible() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l,
      scenarioProfileID: "coding",
      objective: "M4b evidence receipt binding",
      store: store)
    let requirements = Dictionary(
      uniqueKeysWithValues: contract.receiptRequirements.map { ($0.id, $0) })
    let sandbox = try XCTUnwrap(requirements["sandbox"])
    let rollback = try XCTUnwrap(requirements["rollback"])
    let artifactID = "/tmp/tatwo-m4b-evidence.json"

    for requirement in [sandbox, rollback, sandbox] {
      let result = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: artifactID,
        receiptKind: requirement.kind,
        satisfiesRequirementID: requirement.id,
        store: store)
      XCTAssertTrue(result.ok, result.decision.message)
    }

    let record = try store.requireIssuedContract(contract.contractID)
    let mapped = record.receipts.filter {
      $0.receiptID == artifactID
        && $0.satisfiesRequirementID != nil
    }
    XCTAssertEqual(mapped.count, 2)
    XCTAssertEqual(
      Set(mapped.compactMap(\.satisfiesRequirementID)),
      ["sandbox", "rollback"])
    XCTAssertTrue(record.satisfiedReceiptRequirementIDs.contains("sandbox"))
    XCTAssertTrue(record.satisfiedReceiptRequirementIDs.contains("rollback"))

    let collision = WorkOSFactory.submitReceipt(
      goalID: contract.goalID,
      contractID: contract.contractID,
      loopID: contract.mainlineLoop.id,
      receiptID: "human-gate",
      receiptKind: sandbox.kind,
      satisfiesRequirementID: sandbox.id,
      store: store)
    XCTAssertTrue(collision.ok, collision.decision.message)
    let collisionRecord = try store.requireIssuedContract(contract.contractID)
    XCTAssertFalse(
      collisionRecord.satisfiedReceiptRequirementIDs.contains("human-gate"),
      "An evidence ID that resembles another requirement must satisfy only its explicit binding.")

    let forged = WorkOSFactory.submitReceipt(
      goalID: contract.goalID,
      contractID: contract.contractID,
      loopID: contract.mainlineLoop.id,
      receiptID: artifactID,
      receiptKind: "seal",
      satisfiesRequirementID: "m4b-not-issued-requirement",
      store: store)
    XCTAssertFalse(forged.ok)
    XCTAssertEqual(forged.decision.code, "receipt_requirement_not_issued")

    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store)
    XCTAssertFalse(close.ok)
    XCTAssertTrue(close.suppliedReceiptIDs.contains("sandbox"))
    XCTAssertTrue(close.suppliedReceiptIDs.contains("rollback"))
    XCTAssertFalse(close.missingReceiptIDs.contains("sandbox"))
    XCTAssertFalse(close.missingReceiptIDs.contains("rollback"))
    XCTAssertTrue(close.missingReceiptIDs.contains("goal-cycle-seal"))
  }

  // MARK: The core adversarial gate — fabricated receipts must not close a goal

  func testCloseGoalIgnoresFabricatedReceiptsWhenStorePresent() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "fab", store: store)
    let required = requiredIDs(contract)
    XCTAssertGreaterThan(required.count, 1)

    // Journal only ONE real receipt.
    _ = WorkOSFactory.submitReceipt(
      goalID: contract.goalID, contractID: contract.contractID, loopID: nil,
      receiptID: required[0], receiptKind: "seal", store: store)

    // Attack: hand the full required list back as suppliedReceiptIDs (the classic
    // "echo os.next output" fabrication). The store must ignore it.
    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID, contractID: contract.contractID,
      mode: .xl, scenarioProfileID: "coding", objective: "fab",
      suppliedReceiptIDs: required, store: store)

    XCTAssertFalse(close.ok)
    XCTAssertEqual(close.status, .rollbackRequired)
    XCTAssertEqual(close.decision.code, "receipt_incomplete")
    // Everything except the journaled receipt and the activation-seeded goal tracker is still missing.
    XCTAssertEqual(Set(close.missingReceiptIDs), Set(required).subtracting([required[0], "goal-tracker"]))
    XCTAssertEqual(Set(close.suppliedReceiptIDs), [required[0], "goal-tracker"])
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .planned,
      "an incomplete close decision must not durably terminalize the GoalRun")
  }

  func testCloseGoalPassesWhenEveryRequiredReceiptIsJournaled() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "full", store: store)
    for id in requiredIDs(contract) {
      _ = WorkOSFactory.submitReceipt(
        goalID: contract.goalID, contractID: contract.contractID, loopID: nil,
        receiptID: id, receiptKind: "test", store: store)
    }

    let registry = TatwoDispatchRegistry(directoryURL: root)
    try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: store, registry: registry)
    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID, contractID: contract.contractID,
      mode: .xl, scenarioProfileID: "coding", objective: "full",
      suppliedReceiptIDs: [], store: store, dispatchRegistry: registry)

    XCTAssertTrue(close.ok)
    XCTAssertEqual(close.status, .passed)
    XCTAssertTrue(close.missingReceiptIDs.isEmpty)
    XCTAssertEqual(try store.record(forContractID: contract.contractID)?.status, .passed)
  }

  func testDispatchFinalizeRemainsOpenAfterIncompleteCloseAndCanLaterPass() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "finalize is not goal judgment",
      store: store)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let finalized = try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: store, registry: registry)
    let sealID = try XCTUnwrap(finalized.latestDispatchCycleSealID)

    XCTAssertEqual(finalized.status, .awaitingNextCycle)
    XCTAssertEqual(
      finalized.statusReason,
      "dispatch_cycle_finalized:1:1:\(sealID)")
    XCTAssertNotEqual(finalized.status, .passed)
    XCTAssertNotEqual(finalized.status, .rollbackRequired)
    XCTAssertEqual(
      try store.finalizeDispatchSet(
        contractID: contract.contractID,
        sealID: sealID,
        recordCount: 1),
      finalized)
    XCTAssertThrowsError(
      try store.finalizeDispatchSet(
        contractID: contract.contractID,
        sealID: "dispatch-seal-other",
        recordCount: 1)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .illegalStatusTransition(
          from: .awaitingNextCycle,
          to: .awaitingNextCycle,
          authority: "dispatch_finalize_retry"))
    }

    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store,
      dispatchRegistry: registry)

    XCTAssertFalse(close.ok)
    XCTAssertEqual(close.status, .rollbackRequired)
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .awaitingNextCycle)

    for id in requiredIDs(contract) {
      let result = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: id,
        receiptKind: "post-incomplete-close",
        store: store)
      XCTAssertTrue(result.ok, result.decision.message)
    }

    let passed = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store,
      dispatchRegistry: registry)

    XCTAssertTrue(passed.ok)
    XCTAssertEqual(passed.status, .passed)
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .passed)
  }

  func testLegacyDispatchFinalizedSucceededCanJournalReceiptsAndClosePassed() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "legacy awaiting judgment",
      store: store)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let finalized = try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: store, registry: registry)
    let sealID = try XCTUnwrap(finalized.latestDispatchCycleSealID)
    var legacy = try store.requireIssuedContract(contract.contractID)
    legacy.status = .succeeded
    legacy.statusReason = "dispatch_set_finalized:1:\(sealID)"
    try writeGoalRecord(legacy, to: store)

    for id in requiredIDs(contract) {
      let result = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: id,
        receiptKind: "legacy-awaiting-judgment",
        store: store)
      XCTAssertTrue(result.ok, result.decision.message)
    }
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .succeeded)

    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: store,
      dispatchRegistry: registry)

    XCTAssertTrue(close.ok)
    XCTAssertEqual(close.status, .passed)
    XCTAssertEqual(
      try store.requireIssuedContract(contract.contractID).status,
      .passed)
  }

  func testStoredContractProjectionUsesStoredPassedStatus() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l, scenarioProfileID: "coding", objective: "dashboard status", store: store)
    for id in requiredIDs(contract) {
      _ = WorkOSFactory.submitReceipt(
        goalID: contract.goalID, contractID: contract.contractID, loopID: nil,
        receiptID: id, receiptKind: "test", store: store)
    }
    let registry = TatwoDispatchRegistry(directoryURL: root)
    try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: store, registry: registry)
    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID, contractID: contract.contractID,
      mode: .l, scenarioProfileID: "coding", objective: "dashboard status",
      suppliedReceiptIDs: [], store: store, dispatchRegistry: registry)
    XCTAssertEqual(close.status, .passed)

    let projected = try WorkOSFactory.storedContractProjection(
      contractID: contract.contractID,
      fallbackMode: .s,
      fallbackScenarioProfileID: "daily",
      fallbackObjective: "caller fallback must not win",
      store: store)
    let dashboard = TatwoWorkOSDashboardFactory.make(
      contract: projected,
      submittedReceiptIDs: Array(try store.submittedReceiptIDs(contractID: contract.contractID)))

    XCTAssertEqual(projected.goalRun.status, .passed)
    XCTAssertEqual(projected.mainlineLoop.status, .passed)
    XCTAssertEqual(dashboard.goal.status, .passed)
    XCTAssertEqual(dashboard.lanes.first(where: { $0.id == "goal" })?.status, .passed)
    XCTAssertEqual(dashboard.receiptRail.missingCount, 0)
  }

  func testNextAndLoopStatusRespectStoredPassedStatus() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .l, scenarioProfileID: "coding", objective: "terminal next", store: store)
    for id in requiredIDs(contract) {
      _ = WorkOSFactory.submitReceipt(
        goalID: contract.goalID, contractID: contract.contractID, loopID: nil,
        receiptID: id, receiptKind: "test", store: store)
    }
    let registry = TatwoDispatchRegistry(directoryURL: root)
    try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: store, registry: registry)
    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID, contractID: contract.contractID,
      mode: .l, scenarioProfileID: "coding", objective: "terminal next",
      suppliedReceiptIDs: [], store: store, dispatchRegistry: registry)
    XCTAssertEqual(close.status, .passed)

    let next = try WorkOSFactory.next(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .s,
      scenarioProfileID: "daily",
      objective: "caller fallback must not win",
      store: store)
    XCTAssertTrue(next.ok)
    XCTAssertEqual(next.decision.code, "goal_already_passed")
    XCTAssertEqual(next.requiredReceiptsBeforePass, [])
    XCTAssertTrue(next.nextStep.contains("no next action"))

    let loops = try WorkOSFactory.loopStatus(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: .s,
      scenarioProfileID: "daily",
      objective: "caller fallback must not win",
      store: store)
    XCTAssertTrue(loops.ok)
    XCTAssertEqual(loops.mainlineLoop?.status, .passed)
  }

  // MARK: Mode-downgrade attack

  func testCloseGoalBlocksModeDowngradeWhenStorePresent() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let xl = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl, scenarioProfileID: "coding", objective: "dg", store: store)
    let xlRequired = Set(requiredIDs(xl))
    let sRequired = Set(
      requiredIDs(
        try WorkOSFactory.projectContract(mode: .s, scenarioProfileID: "coding", objective: "dg")))
    XCTAssertNotEqual(xlRequired, sRequired)

    // Attack: close the XL contract while claiming mode=.s to shrink the required set.
    let close = try WorkOSFactory.closeGoal(
      goalID: xl.goalID, contractID: xl.contractID,
      mode: .s, scenarioProfileID: "coding", objective: "dg",
      suppliedReceiptIDs: [], store: store)

    XCTAssertFalse(close.ok)
    // Missing set reflects the STORED XL requirements, not the downgraded S set.
    XCTAssertEqual(Set(close.missingReceiptIDs), xlRequired)
  }

  func testCloseGoalRejectsUnregisteredContractWhenStorePresent() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let close = try WorkOSFactory.closeGoal(
      goalID: "goal-xl-coding-bbbbbbbbbbbb",
      contractID: "contract-xl-coding-bbbbbbbbbbbb",
      mode: .xl, scenarioProfileID: "coding", objective: "nope",
      suppliedReceiptIDs: ["contract-id"], store: store)

    XCTAssertFalse(close.ok)
    XCTAssertEqual(close.status, .blocked)
    XCTAssertEqual(close.decision.code, "unregistered_contract")
  }

  // MARK: Legacy path must be unchanged (guards the existing 170-test suite)

  func testLegacyStorelessPathIsUnchanged() throws {
    let contract = try WorkOSFactory.projectContract(
      mode: .xl, scenarioProfileID: "coding", objective: "legacy")
    let required = requiredIDs(contract)

    // Without a store, close still reconciles against caller-supplied IDs (pre-hardening
    // behavior). This is intentional and documents why store-less callers are unaffected.
    let close = try WorkOSFactory.closeGoal(
      goalID: contract.goalID, contractID: "any-non-empty",
      mode: .xl, scenarioProfileID: "coding", objective: "legacy",
      suppliedReceiptIDs: required)
    XCTAssertTrue(close.ok)
    XCTAssertEqual(close.status, .passed)

    // And a store-less submit still echoes acceptance for any non-empty receiptID.
    let submit = WorkOSFactory.submitReceipt(
      goalID: nil, contractID: "any-non-empty", loopID: nil,
      receiptID: "whatever", receiptKind: "test")
    XCTAssertTrue(submit.ok)
    XCTAssertEqual(submit.decision.code, "receipt_accepted_staging")
  }

  func testRecoveryGoalRunIsAppendOnlyAndReferencesFailedOrigin() throws {
    let (store, root) = makeStore()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let routeOverride = WorkOSRouteBindingOverride(
      primaryModelID: "gpt-5.6-sol",
      secondaryModelID: "grok-build")
    let original = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl,
      scenarioProfileID: "coding",
      objective: "failed original",
      routeBindingOverride: routeOverride,
      store: store)
    _ = try store.updateStatus(
      contractID: original.contractID,
      status: .dispatching,
      authority: .caller,
      reason: "dispatch_begin_requested")
    _ = try store.updateStatus(
      contractID: original.contractID,
      status: .running,
      authority: .ledgerBeginAck,
      reason: "dispatch_started",
      evidence: .ledger(dispatchID: "dispatch-recovery"))
    _ = try store.updateStatus(
      contractID: original.contractID,
      status: .failed,
      authority: .dispatchFailure,
      reason: "dispatch_failed",
      evidence: .failure(dispatchID: "dispatch-recovery"))
    let originalBeforeRecovery = try store.requireIssuedContract(original.contractID)

    let recovery = try store.createRecovery(
      originalContractID: original.contractID,
      authorizationToken: "human-emergency-authority",
      reason: "Fable5 PASS_TO_RECOVERY_IMPLEMENTATION",
      adjudicationRef: "fable5-recovery-adjudication")

    XCTAssertNotEqual(recovery.contractID, original.contractID)
    XCTAssertNotEqual(recovery.goalID, original.goalID)
    XCTAssertEqual(recovery.status, .planned)
    XCTAssertEqual(recovery.recoversGoalID, original.goalID)
    XCTAssertEqual(recovery.recoversContractID, original.contractID)
    XCTAssertEqual(recovery.routeBindingOverride, routeOverride)
    XCTAssertTrue(recovery.recoveryReceiptHash?.hasPrefix("sha256:") == true)
    XCTAssertTrue(recovery.recoveryAuthorizationHash?.hasPrefix("sha256:") == true)
    XCTAssertEqual(
      try store.requireIssuedContract(original.contractID),
      originalBeforeRecovery)
  }

  func testRecoveryRejectsNonFailedOrigin() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "still planned",
      store: store)

    XCTAssertThrowsError(
      try store.createRecovery(
        originalContractID: original.contractID,
        authorizationToken: "human-emergency-authority",
        reason: "must fail",
        adjudicationRef: "test")
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .recoveryRequiresFailedOrigin(status: .planned))
    }
  }

  func testFailedOriginRejectsAllInPlaceStatusRewrites() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "immutable failed origin",
      store: store)
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .dispatching,
      authority: .caller,
      reason: "begin")
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .running,
      authority: .ledgerBeginAck,
      reason: "ack",
      evidence: .ledger(dispatchID: "dispatch-origin"))
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .failed,
      authority: .dispatchFailure,
      reason: "terminal origin",
      evidence: .failure(dispatchID: "dispatch-origin"))
    let url = try store.fileURL(forContractID: contract.contractID)
    let before = try Data(contentsOf: url)

    XCTAssertThrowsError(
      try store.updateStatus(
        contractID: contract.contractID,
        status: .failed,
        authority: .dispatchFailure,
        reason: "rewrite"))
    XCTAssertThrowsError(
      try store.updateStatus(
        contractID: contract.contractID,
        status: .passed,
        authority: .goalClose,
        reason: "revive"))
    XCTAssertThrowsError(
      try store.updateStatus(
        contractID: contract.contractID,
        status: .rollbackRequired,
        authority: .goalClose,
        reason: "revive"))
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  func testGoalCloseCannotFlipAnExistingGoalJudgeDecision() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let passed = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "passed Goal Judge decision is immutable",
      store: store)
    _ = try store.updateStatus(
      contractID: passed.contractID,
      status: .passed,
      authority: .goalClose,
      reason: "first Goal Judge decision")
    let repeatedPassed = try store.updateStatus(
      contractID: passed.contractID,
      status: .passed,
      authority: .goalClose,
      reason: "idempotent Goal Judge retry")
    XCTAssertEqual(repeatedPassed.status, .passed)
    let passedURL = try store.fileURL(forContractID: passed.contractID)
    let passedBytes = try Data(contentsOf: passedURL)

    XCTAssertThrowsError(
      try store.updateStatus(
        contractID: passed.contractID,
        status: .rollbackRequired,
        authority: .goalClose,
        reason: "stale contradictory retry")
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .illegalStatusTransition(
          from: .passed,
          to: .rollbackRequired,
          authority: TatwoGoalRunTransitionAuthority.goalClose.rawValue))
    }
    XCTAssertEqual(try Data(contentsOf: passedURL), passedBytes)

    let rollback = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "rollback Goal Judge decision is immutable",
      store: store)
    _ = try store.updateStatus(
      contractID: rollback.contractID,
      status: .rollbackRequired,
      authority: .goalClose,
      reason: "first Goal Judge decision")
    let repeatedRollback = try store.updateStatus(
      contractID: rollback.contractID,
      status: .rollbackRequired,
      authority: .goalClose,
      reason: "idempotent Goal Judge retry")
    XCTAssertEqual(repeatedRollback.status, .rollbackRequired)
    let rollbackURL = try store.fileURL(forContractID: rollback.contractID)
    let rollbackBytes = try Data(contentsOf: rollbackURL)

    XCTAssertThrowsError(
      try store.updateStatus(
        contractID: rollback.contractID,
        status: .passed,
        authority: .goalClose,
        reason: "stale contradictory retry")
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .illegalStatusTransition(
          from: .rollbackRequired,
          to: .passed,
          authority: TatwoGoalRunTransitionAuthority.goalClose.rawValue))
    }
    XCTAssertEqual(try Data(contentsOf: rollbackURL), rollbackBytes)

    let cancelled = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "cancelled execution cannot be revived by Goal Judge close",
      store: store)
    _ = try store.updateStatus(
      contractID: cancelled.contractID,
      status: .dispatching,
      authority: .caller,
      reason: "begin cancelled fixture")
    _ = try store.updateStatus(
      contractID: cancelled.contractID,
      status: .running,
      authority: .ledgerBeginAck,
      reason: "run cancelled fixture",
      evidence: .ledger(dispatchID: "dispatch-cancelled-goal-close"))
    _ = try store.updateStatus(
      contractID: cancelled.contractID,
      status: .cancelled,
      authority: .caller,
      reason: "user cancelled")
    let cancelledURL = try store.fileURL(forContractID: cancelled.contractID)
    let cancelledBytes = try Data(contentsOf: cancelledURL)

    for target in [GoalRunStatus.passed, .rollbackRequired] {
      XCTAssertThrowsError(
        try store.updateStatus(
          contractID: cancelled.contractID,
          status: target,
          authority: .goalClose,
          reason: "must not revive cancelled work")
      ) { error in
        XCTAssertEqual(
          error as? TatwoGoalRunStoreError,
          .illegalStatusTransition(
            from: .cancelled,
            to: target,
            authority: TatwoGoalRunTransitionAuthority.goalClose.rawValue))
      }
      XCTAssertEqual(try Data(contentsOf: cancelledURL), cancelledBytes)
    }
  }

  func testRecordBeginCannotRewriteTerminalOrigin() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xl,
      scenarioProfileID: "ui-ux",
      objective: "terminal reuse",
      store: store)
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .dispatching,
      authority: .caller)
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .running,
      authority: .ledgerBeginAck,
      evidence: .ledger(dispatchID: "dispatch-record-begin"))
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .failed,
      authority: .dispatchFailure,
      reason: "failed",
      evidence: .failure(dispatchID: "dispatch-record-begin"))
    let url = try store.fileURL(forContractID: contract.contractID)
    let before = try Data(contentsOf: url)

    XCTAssertThrowsError(try store.recordBegin(contract: contract))
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  // MARK: Path-traversal defense on the storage filename

  func testStoreRejectsTraversalStyleContractID() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try store.fileURL(forContractID: "../../etc/passwd")) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError, .invalidContractID("../../etc/passwd"))
    }
    XCTAssertThrowsError(try store.fileURL(forContractID: "")) { error in
      guard case TatwoGoalRunStoreError.invalidContractID = error else {
        return XCTFail("expected invalidContractID, got \(error)")
      }
    }
    // A well-formed contractID maps under goals/.
    let good = try store.fileURL(forContractID: "contract-xl-coding-c5e41f6ab147")
    XCTAssertTrue(good.path.contains("/goals/"))
    XCTAssertTrue(good.lastPathComponent.hasSuffix(".json"))
  }

  func testSupersededGoalRejectsLateReceiptWithoutChangingDurableBytes() throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "immutable superseded receipts",
      store: store)
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .dispatching,
      authority: .caller)
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .running,
      authority: .ledgerBeginAck,
      evidence: .ledger(dispatchID: "old-revision"))
    _ = try store.updateStatus(
      contractID: contract.contractID,
      status: .superseded,
      authority: .revisionPromotion,
      reason: "superseded_by_revision:next")
    let url = try store.fileURL(forContractID: contract.contractID)
    let before = try Data(contentsOf: url)

    XCTAssertThrowsError(
      try store.appendReceipt(
        contractID: contract.contractID,
        receiptID: "late",
        kind: "loop")
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .staleGoalRevision(contract.contractID))
    }
    XCTAssertEqual(try Data(contentsOf: url), before)
  }

  private func writeGoalRecord(
    _ record: TatwoStoredGoalRun,
    to store: TatwoGoalRunStore
  ) throws {
    let url = try store.fileURL(forContractID: record.contractID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: url, options: [.atomic])
  }
}
