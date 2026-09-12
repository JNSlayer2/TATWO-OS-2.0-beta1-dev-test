import XCTest

@testable import TatwoUltraworkCore

final class GoalRunDispatchLifecycleTests: XCTestCase {
  private enum InjectedFailure: Error {
    case ledgerBegin
    case ledgerAcknowledge
    case ledgerFail
  }

  private func makeStores() -> (TatwoGoalRunStore, TatwoDispatchRegistry, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-dispatch-lifecycle-\(UUID().uuidString)",
      isDirectory: true)
    return (
      TatwoGoalRunStore(directoryURL: root),
      TatwoDispatchRegistry(directoryURL: root),
      root)
  }

  private func beginContract(
    store: TatwoGoalRunStore,
    objective: String
  ) throws -> TatwoWorkOSContractV1 {
    try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: objective,
      store: store)
  }

  private func remoteJob(
    contract: TatwoWorkOSContractV1,
    identity: IdentityKind = .sub,
    exactModelRouteID: String? = nil,
    workPath: String,
    shellSafe: Bool = false
  ) -> TatwoLoopJobV1 {
    let payload: TatwoLoopJobPayloadV1
    if shellSafe {
      payload = .shellSafe(TatwoShellSafePayloadV1(command: .true))
    } else {
      let route = exactModelRouteID
      let agent: TatwoRemoteAgentKindV1?
      if route?.hasPrefix("grok-") == true {
        agent = .grok
      } else if route?.hasPrefix("fable-") == true
        || route?.hasPrefix("opus-") == true
        || route?.hasPrefix("sonnet-") == true
      {
        agent = .claude
      } else if route != nil {
        agent = .codex
      } else {
        agent = nil
      }
      payload = .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: contract.contractID,
          goalID: contract.goalID,
          identity: identity,
          mode: TatwoLoopModeV1(rawValue: contract.mode.rawValue) ?? .m,
          taskDescription: "remote route authorization",
          agent: agent,
          exactModelRouteID: route))
    }
    return TatwoLoopJobV1(
      jobID: "job-\(UUID().uuidString)",
      logicalJobID: "logical-\(UUID().uuidString)",
      dispatchNonce: "nonce-\(UUID().uuidString)",
      contractID: contract.contractID,
      goalID: contract.goalID,
      identity: identity,
      originDeviceID: "origin-route-test",
      targetDeviceID: "target-route-test",
      payload: payload,
      workPath: workPath,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 1,
        maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func originChannel(
    root: URL,
    cancelFaultBox: TatwoLoopCancelFaultBox? = nil
  ) throws -> TatwoLoopJobChannel {
    let environment = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
    let trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-route-test",
      privateKeyStore: GoalRunLifecycleMemoryPrivateKeyStore(),
      environment: environment)
    return TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel", isDirectory: true),
      trust: trust,
      environment: environment,
      cancelFaultBox: cancelFaultBox)
  }

  func testRemoteDispatchAuthorizationReprojectsPersistedRouteBindingOverride() throws {
    let (goalStore, _, root) = makeStores()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let routeOverride = WorkOSRouteBindingOverride(
      primaryModelID: "opus-5",
      secondaryModelID: "grok-build")
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "custom remote route",
      routeBindingOverride: routeOverride,
      store: goalStore)
    let leadBindings = contract.identityBindings.filter { $0.identity == .lead }
    let subBindings = contract.identityBindings.filter { $0.identity == .sub }

    XCTAssertFalse(leadBindings.isEmpty)
    XCTAssertFalse(subBindings.isEmpty)
    XCTAssertTrue(leadBindings.allSatisfy { $0.modelID == "opus-5" })
    XCTAssertTrue(subBindings.allSatisfy { $0.modelID == "grok-build" })

    let projectionWithoutOverride = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "custom remote route")
    XCTAssertNotEqual(projectionWithoutOverride.contractID, contract.contractID)
    XCTAssertNotEqual(projectionWithoutOverride.goalID, contract.goalID)

    let job = remoteJob(
      contract: contract,
      exactModelRouteID: "grok-build",
      workPath: root.path)

    let authorized = try TatwoGoalRunDispatchLifecycle.authorizeRemoteDispatch(
      job: job,
      goalStore: goalStore,
      environment: [:])

    XCTAssertEqual(authorized.contractID, contract.contractID)
    XCTAssertEqual(authorized.goalID, contract.goalID)
    XCTAssertEqual(authorized.routeBindingOverride, routeOverride)
  }

  func testRemoteDispatchRejectsScenarioConfigDriftWithSameContractID() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "daily",
      objective: "remote route survives only its issued topology",
      store: goalStore)
    let issuedRoute = try XCTUnwrap(
      contract.identityBindings.first(where: { $0.identity == .sub })?.modelID)
    var driftedBook = TatwoScenarioConfigDefaults.book
    let scenarioIndex = try XCTUnwrap(
      driftedBook.scenarios.firstIndex(where: { $0.id == contract.scenario }))
    var scenario = driftedBook.scenarios[scenarioIndex]
    var modeConfig = try XCTUnwrap(scenario.modeConfigs[.m])
    let bindingIndex = try XCTUnwrap(
      modeConfig.bindings.firstIndex(where: { $0.identityKind == .sub }))
    modeConfig.bindings[bindingIndex].boundModelIDs = ["gpt-5.6-luna"]
    scenario.modeConfigs[.m] = modeConfig
    driftedBook.scenarios[scenarioIndex] = scenario

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.authorizeRemoteDispatch(
        job: remoteJob(
          contract: contract,
          exactModelRouteID: issuedRoute,
          workPath: root.path),
        goalStore: goalStore,
        environment: [:],
        scenarioBook: driftedBook)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsMismatch(contract.contractID))
    }
  }

  func testRemoteDispatchResolvesExactModelFromCombinedIssuedSourceSlot() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    var combinedBook = TatwoScenarioConfigDefaults.book
    let scenarioIndex = try XCTUnwrap(
      combinedBook.scenarios.firstIndex(where: { $0.id == "daily" }))
    var scenario = combinedBook.scenarios[scenarioIndex]
    var modeConfig = try XCTUnwrap(scenario.modeConfigs[.m])
    let bindingIndex = try XCTUnwrap(
      modeConfig.bindings.firstIndex(where: { $0.identityKind == .sub }))
    let sourceSlotID = modeConfig.bindings[bindingIndex].id
    modeConfig.bindings[bindingIndex].boundModelIDs = ["gpt-5.6-luna", "grok-build"]
    scenario.modeConfigs[.m] = modeConfig
    combinedBook.scenarios[scenarioIndex] = scenario
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "daily",
      objective: "combined source slot exact remote route",
      scenarioBook: combinedBook,
      store: goalStore)

    let authorized = try TatwoGoalRunDispatchLifecycle.authorizeRemoteDispatch(
      job: remoteJob(
        contract: contract,
        exactModelRouteID: "grok-build",
        workPath: root.path),
      goalStore: goalStore,
      environment: [:],
      scenarioBook: combinedBook)

    XCTAssertEqual(authorized.contractID, contract.contractID)
    XCTAssertEqual(
      authorized.issuedIdentityBindings?.filter {
        $0.sourceSlotID == sourceSlotID && $0.identity == .sub
      }.map(\.modelID),
      ["gpt-5.6-luna", "grok-build"])
  }

  func testRemoteDispatchRejectsAmbiguousDuplicateIssuedIdentityModel() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    var duplicateBook = TatwoScenarioConfigDefaults.book
    let scenarioIndex = try XCTUnwrap(
      duplicateBook.scenarios.firstIndex(where: { $0.id == "daily" }))
    var scenario = duplicateBook.scenarios[scenarioIndex]
    var modeConfig = try XCTUnwrap(scenario.modeConfigs[.m])
    modeConfig.bindings.removeAll { $0.identityKind == .sub }
    modeConfig.bindings.append(
      contentsOf: [
        TatwoScenarioIdentityBinding(
          id: "duplicate-sub-a",
          phase: .loops,
          identity: "sub",
          boundModelIDs: ["gpt-5.6-luna"],
          responsibility: "first duplicate"),
        TatwoScenarioIdentityBinding(
          id: "duplicate-sub-b",
          phase: .loops,
          identity: "sub",
          boundModelIDs: ["gpt-5.6-luna"],
          responsibility: "second duplicate"),
      ])
    scenario.modeConfigs[.m] = modeConfig
    duplicateBook.scenarios[scenarioIndex] = scenario
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "daily",
      objective: "ambiguous remote route",
      scenarioBook: duplicateBook,
      store: goalStore)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.authorizeRemoteDispatch(
        job: remoteJob(
          contract: contract,
          exactModelRouteID: "gpt-5.6-luna",
          workPath: root.path),
        goalStore: goalStore,
        environment: [:],
        scenarioBook: duplicateBook)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .dispatchBindingAmbiguous(
          identity: .sub,
          modelID: "gpt-5.6-luna",
          bindingIDs: [
            "binding-duplicate-sub-a-0",
            "binding-duplicate-sub-b-0",
          ]))
    }
  }

  func testShellSafeReservationPersistsExactIssuedBindingTuple() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "shell-safe exact issued binding")
    let issuedMatches = try XCTUnwrap(
      try goalStore.requireIssuedContract(contract.contractID)
        .issuedIdentityBindings)
      .filter { $0.identity == .sub }
    XCTAssertEqual(issuedMatches.count, 1)
    let issued = try XCTUnwrap(issuedMatches.first)
    let job = remoteJob(
      contract: contract,
      workPath: root.path,
      shellSafe: true)

    let record = try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
      job: job,
      goalStore: goalStore,
      dispatchRegistry: registry,
      environment: [:])

    XCTAssertEqual(record.bindingID, issued.id)
    XCTAssertEqual(record.sourceSlotID, issued.sourceSlotID)
    XCTAssertEqual(record.identity, issued.identity)
    XCTAssertEqual(record.modelID, issued.modelID)
  }

  func testShellSafeReservationRejectsAmbiguousIssuedIdentity() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    var duplicateBook = TatwoScenarioConfigDefaults.book
    let scenarioIndex = try XCTUnwrap(
      duplicateBook.scenarios.firstIndex(where: { $0.id == "daily" }))
    var scenario = duplicateBook.scenarios[scenarioIndex]
    var modeConfig = try XCTUnwrap(scenario.modeConfigs[.m])
    modeConfig.bindings.removeAll { $0.identityKind == .sub }
    modeConfig.bindings.append(
      contentsOf: [
        TatwoScenarioIdentityBinding(
          id: "shell-sub-a",
          phase: .loops,
          identity: "sub",
          boundModelIDs: ["gpt-5.6-luna"],
          responsibility: "first shell binding"),
        TatwoScenarioIdentityBinding(
          id: "shell-sub-b",
          phase: .loops,
          identity: "sub",
          boundModelIDs: ["grok-build"],
          responsibility: "second shell binding"),
      ])
    scenario.modeConfigs[.m] = modeConfig
    duplicateBook.scenarios[scenarioIndex] = scenario
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "daily",
      objective: "ambiguous shell-safe route",
      scenarioBook: duplicateBook,
      store: goalStore)
    let job = remoteJob(
      contract: contract,
      workPath: root.path,
      shellSafe: true)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
        job: job,
        goalStore: goalStore,
        dispatchRegistry: registry,
        environment: [:],
        scenarioBook: duplicateBook)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .dispatchBindingAmbiguous(
          identity: .sub,
          modelID: "<identity-only>",
          bindingIDs: [
            "binding-shell-sub-a-0",
            "binding-shell-sub-b-0",
          ]))
    }
    XCTAssertTrue(
      try registry.run(forContractID: contract.contractID)?.records.isEmpty ?? true)
  }

  func testRemoteDispatchRejectsMissingIssuedBindingSnapshot() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "missing issued route snapshot")
    try mutateStoredGoalJSON(contractID: contract.contractID, store: goalStore) {
      $0.removeValue(forKey: "issuedIdentityBindings")
      $0.removeValue(forKey: "issuedIdentityBindingsDigest")
    }

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.authorizeRemoteDispatch(
        job: remoteJob(
          contract: contract,
          exactModelRouteID: "gpt-5.6-sol",
          workPath: root.path),
        goalStore: goalStore,
        environment: [:])
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .remoteDispatchUnauthorized(
          code: "issued_route_snapshot_missing",
          message: "remote dispatch requires the durable identity-binding snapshot issued by tatwo.os.begin"))
    }
  }

  func testRemoteDispatchRejectsIssuedBindingDigestMismatch() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "tampered issued route digest")
    try mutateStoredGoalJSON(contractID: contract.contractID, store: goalStore) {
      $0["issuedIdentityBindingsDigest"] = "sha256:\(String(repeating: "0", count: 64))"
    }

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.authorizeRemoteDispatch(
        job: remoteJob(
          contract: contract,
          exactModelRouteID: "gpt-5.6-sol",
          workPath: root.path),
        goalStore: goalStore,
        environment: [:])
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .issuedIdentityBindingsDigestMismatch(contract.contractID))
    }
  }

  func testRemoteDispatchSnapshotRevisionRaceFailsBeforeRegistryMutation() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "remote revision fence")
    let job = remoteJob(
      contract: contract,
      workPath: root.path,
      shellSafe: true)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
        job: job,
        goalStore: goalStore,
        dispatchRegistry: registry,
        environment: [:],
        afterSnapshotProjection: {
          _ = try goalStore.appendReceipt(
            contractID: contract.contractID,
            receiptID: "intervening-route-revision",
            kind: "race-test")
        })
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .remoteDispatchUnauthorized(
          code: "goal_run_snapshot_stale",
          message: "GoalRun changed while remote dispatch authorization was being verified"))
    }
    XCTAssertTrue(
      try registry.run(forContractID: contract.contractID)?.records.isEmpty ?? true)
  }

  func testRemoteDispatchHoldsGoalRevisionLockThroughRegistryReservation() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "linearized remote reservation")
    let job = remoteJob(
      contract: contract,
      workPath: root.path,
      shellSafe: true)
    let currentRevisionLocked = DispatchSemaphore(value: 0)
    let allowReservation = DispatchSemaphore(value: 0)
    let mutationStarted = DispatchSemaphore(value: 0)
    let mutationFinished = DispatchSemaphore(value: 0)
    let dispatchFinished = DispatchSemaphore(value: 0)
    let results = LockedResults()

    DispatchQueue.global().async {
      defer { dispatchFinished.signal() }
      do {
        _ = try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
          job: job,
          goalStore: goalStore,
          dispatchRegistry: registry,
          environment: [:],
          afterCurrentSnapshotVerified: {
            currentRevisionLocked.signal()
            _ = allowReservation.wait(timeout: .now() + 2)
          })
      } catch {
        results.append("dispatch:\(error)")
      }
    }
    XCTAssertEqual(currentRevisionLocked.wait(timeout: .now() + 2), .success)

    DispatchQueue.global().async {
      mutationStarted.signal()
      defer { mutationFinished.signal() }
      do {
        _ = try goalStore.appendReceipt(
          contractID: contract.contractID,
          receiptID: "post-reservation-mutation",
          kind: "race-test")
      } catch {
        results.append("mutation:\(error)")
      }
    }
    XCTAssertEqual(mutationStarted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(
      mutationFinished.wait(timeout: .now() + 0.1),
      .timedOut,
      "GoalRun mutation must block while exact revision and registry reservation are linearized")

    allowReservation.signal()
    XCTAssertEqual(dispatchFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(mutationFinished.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(results.snapshot().isEmpty, "\(results.snapshot())")
    XCTAssertEqual(
      try registry.run(forContractID: contract.contractID)?.records.count,
      1)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .planned)
    XCTAssertTrue(
      try goalStore.submittedReceiptIDs(contractID: contract.contractID)
        .contains("post-reservation-mutation"))
  }

  func testRemoteOutboxCrashAfterPreparedIntentReconcilesForward() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "prepared crash recovery")
    let job = remoteJob(contract: contract, workPath: root.path, shellSafe: true)
    let channel = try originChannel(root: root)
    let fault = TatwoRemoteOutboxIntentFaultBox(failAt: .afterIntentPrepared)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
        job: job,
        goalStore: goalStore,
        dispatchRegistry: registry,
        environment: [:],
        intentFaultBox: fault))
    XCTAssertEqual(
      try TatwoGoalRunDispatchLifecycle.remoteOutboxIntent(
        contractID: job.contractID,
        jobID: job.jobID,
        goalStore: goalStore)?.state,
      .prepared)
    XCTAssertTrue(try registry.run(forContractID: job.contractID)?.records.isEmpty ?? true)

    let recovered = try TatwoGoalRunDispatchLifecycle.reconcileRemoteOutbox(
      contractID: job.contractID,
      jobID: job.jobID,
      goalStore: goalStore,
      dispatchRegistry: registry,
      channel: channel,
      environment: [:])
    XCTAssertEqual(recovered.state, .committed)
    XCTAssertTrue(channel.hasCommitMarker(forJobID: job.jobID))
    XCTAssertEqual(try registry.run(forContractID: job.contractID)?.records.count, 1)
  }

  func testRemoteOutboxCrashAfterReservationReusesExactRegistryRow() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "reservation crash recovery")
    let job = remoteJob(contract: contract, workPath: root.path, shellSafe: true)
    let channel = try originChannel(root: root)
    let fault = TatwoRemoteOutboxIntentFaultBox(failAt: .afterRegistryReservation)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
        job: job,
        goalStore: goalStore,
        dispatchRegistry: registry,
        environment: [:],
        intentFaultBox: fault))
    let reservedID = try XCTUnwrap(
      registry.run(forContractID: job.contractID)?.records.first?.id)

    let recovered = try TatwoGoalRunDispatchLifecycle.reconcileRemoteOutbox(
      contractID: job.contractID,
      jobID: job.jobID,
      goalStore: goalStore,
      dispatchRegistry: registry,
      channel: channel,
      environment: [:])
    XCTAssertEqual(recovered.registryDispatchID, reservedID)
    XCTAssertEqual(try registry.run(forContractID: job.contractID)?.records.count, 1)
  }

  func testRemoteOutboxCrashAfterMarkerOnlyAdvancesIntent() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "marker crash recovery")
    let job = remoteJob(contract: contract, workPath: root.path, shellSafe: true)
    let channel = try originChannel(root: root)
    _ = try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
      job: job,
      goalStore: goalStore,
      dispatchRegistry: registry,
      environment: [:])
    let fault = TatwoRemoteOutboxIntentFaultBox(failAt: .afterChannelCommitMarker)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.commitRemoteChannel(
        job: job,
        goalStore: goalStore,
        environment: [:],
        intentFaultBox: fault
      ) {
        try channel.enqueue(job)
      })
    XCTAssertTrue(channel.hasCommitMarker(forJobID: job.jobID))
    XCTAssertEqual(
      try TatwoGoalRunDispatchLifecycle.remoteOutboxIntent(
        contractID: job.contractID,
        jobID: job.jobID,
        goalStore: goalStore)?.state,
      .publishing)

    let recovered = try TatwoGoalRunDispatchLifecycle.reconcileRemoteOutbox(
      contractID: job.contractID,
      jobID: job.jobID,
      goalStore: goalStore,
      dispatchRegistry: registry,
      channel: channel,
      environment: [:])
    XCTAssertEqual(recovered.state, .committed)
  }

  func testRemoteOutboxPublicCancellationWinsBeforePublication() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "cancel before publication")
    let job = remoteJob(contract: contract, workPath: root.path, shellSafe: true)
    let channel = try originChannel(root: root)
    _ = try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
      job: job,
      goalStore: goalStore,
      dispatchRegistry: registry,
      environment: [:])

    let cancelled = try TatwoGoalRunDispatchLifecycle.cancelRemoteOutbox(
      contractID: job.contractID,
      jobID: job.jobID,
      goalStore: goalStore,
      dispatchRegistry: registry,
      channel: channel)

    XCTAssertEqual(cancelled.state, .cancelled)
    XCTAssertFalse(channel.hasCommitMarker(forJobID: job.jobID))
    XCTAssertEqual(
      try registry.run(forContractID: job.contractID)?.records.first?.remoteStatus,
      .cancelled)
  }

  func testOrdinaryOutboxReconcileIgnoresBodyOnlyCancelAndPublishes() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "ignore attacker cancel body")
    let job = remoteJob(contract: contract, workPath: root.path, shellSafe: true)
    let channel = try originChannel(root: root)
    let intentFault = TatwoRemoteOutboxIntentFaultBox(failAt: .afterIntentPrepared)
    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
        job: job,
        goalStore: goalStore,
        dispatchRegistry: registry,
        environment: [:],
        intentFaultBox: intentFault))
    XCTAssertEqual(
      try TatwoGoalRunDispatchLifecycle.remoteOutboxIntent(
        contractID: job.contractID,
        jobID: job.jobID,
        goalStore: goalStore)?.state,
      .prepared)
    let tombstone = TatwoLoopCancelTombstoneV1(
      jobID: job.jobID,
      logicalJobID: job.logicalJobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      reason: "origin-cancel-requested",
      requestedAt: job.createdAt)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bodyURL = channel.cancelURL(forJobID: job.jobID)
    try FileManager.default.createDirectory(
      at: bodyURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try encoder.encode(tombstone).write(to: bodyURL, options: .atomic)

    let recovered = try TatwoGoalRunDispatchLifecycle.reconcileRemoteOutbox(
      contractID: job.contractID,
      jobID: job.jobID,
      goalStore: goalStore,
      dispatchRegistry: registry,
      channel: channel,
      environment: [:])

    XCTAssertEqual(recovered.state, .committed)
    XCTAssertTrue(channel.hasCommitMarker(forJobID: job.jobID))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: channel.cancelSignatureURL(forJobID: job.jobID).path))
    XCTAssertEqual(try channel.currentStatus(for: job.jobID), .queued)

    // The same preplanted exact body becomes signable only after the public
    // cancellation chokepoint first persists explicit origin intent.
    let cancelled = try TatwoGoalRunDispatchLifecycle.cancelRemoteOutbox(
      contractID: job.contractID,
      jobID: job.jobID,
      goalStore: goalStore,
      dispatchRegistry: registry,
      channel: channel)
    XCTAssertEqual(cancelled.state, .cancelled)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: channel.cancelSignatureURL(forJobID: job.jobID).path))
    XCTAssertEqual(try channel.currentStatus(for: job.jobID), .cancelled)
  }

  func testDurableCancellingIntentRecoversEveryCancelCrashBoundary() throws {
    for point in [
      TatwoLoopCancelFaultPoint.afterBody,
      .afterSignature,
      .afterJournal,
      .afterAck,
    ] {
      let (goalStore, registry, root) = makeStores()
      defer { try? FileManager.default.removeItem(at: root) }
      let contract = try beginContract(
        store: goalStore,
        objective: "recover cancel boundary \(point.rawValue)")
      let job = remoteJob(contract: contract, workPath: root.path, shellSafe: true)
      let cancelFault = TatwoLoopCancelFaultBox(failAt: point)
      let channel = try originChannel(root: root, cancelFaultBox: cancelFault)
      _ = try TatwoGoalRunDispatchLifecycle.beginRemoteShellSafe(
        job: job,
        goalStore: goalStore,
        dispatchRegistry: registry,
        environment: [:])
      _ = try TatwoGoalRunDispatchLifecycle.commitRemoteChannel(
        job: job,
        goalStore: goalStore,
        environment: [:]
      ) {
        try channel.enqueue(job)
      }

      XCTAssertThrowsError(
        try TatwoGoalRunDispatchLifecycle.cancelRemoteOutbox(
          contractID: job.contractID,
          jobID: job.jobID,
          goalStore: goalStore,
          dispatchRegistry: registry,
          channel: channel),
        "expected injected crash at \(point.rawValue)")
      XCTAssertEqual(
        try TatwoGoalRunDispatchLifecycle.remoteOutboxIntent(
          contractID: job.contractID,
          jobID: job.jobID,
          goalStore: goalStore)?.state,
        .cancelling)

      if point == .afterBody {
        XCTAssertFalse(
          FileManager.default.fileExists(
            atPath: channel.cancelSignatureURL(forJobID: job.jobID).path))
      } else {
        XCTAssertTrue(
          FileManager.default.fileExists(
            atPath: channel.cancelSignatureURL(forJobID: job.jobID).path))
      }
      if point == .afterJournal {
        XCTAssertEqual(try channel.currentStatus(for: job.jobID), .cancelled)
        XCTAssertEqual(try channel.ack(for: job.jobID)?.status, .queued)
        // Simulate an ACK body/signature crash gap. The signed cancelled
        // journal is sufficient to forward-repair a nil-result cancelled ACK.
        try FileManager.default.removeItem(at: channel.ackSignatureURL(forJobID: job.jobID))
        // A missing enqueue marker cannot override a signed terminal journal.
        try FileManager.default.removeItem(at: channel.commitMarkerURL(forJobID: job.jobID))
        try FileManager.default.removeItem(
          at: channel.commitMarkerSignatureURL(forJobID: job.jobID))
      }

      cancelFault.setFailAt(nil)
      let recovered = try TatwoGoalRunDispatchLifecycle.reconcileRemoteOutbox(
        contractID: job.contractID,
        jobID: job.jobID,
        goalStore: goalStore,
        dispatchRegistry: registry,
        channel: channel,
        environment: [:])

      XCTAssertEqual(recovered.state, .cancelled, point.rawValue)
      XCTAssertEqual(try channel.currentStatus(for: job.jobID), .cancelled, point.rawValue)
      XCTAssertEqual(try channel.ack(for: job.jobID)?.status, .cancelled, point.rawValue)
      XCTAssertNil(try channel.ack(for: job.jobID)?.result, point.rawValue)
      XCTAssertNil(try channel.resultForAudit(for: job.jobID), point.rawValue)
      XCTAssertEqual(
        try registry.run(forContractID: job.contractID)?
          .records.first(where: { $0.remoteJobID == job.jobID })?.remoteStatus,
        .cancelled,
        point.rawValue)
    }
  }

  func testSuccessfulLedgerBeginMovesGoalRunToRunning() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "successful begin")

    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "loops review",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(record.status, .running)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)
  }

  func testWrongBindingIDFailsClosedBeforeLedgerBegin() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "wrong binding")

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        bindingID: "wrong-binding",
        sourceSlotID: "sub",
        identity: .sub,
        modelID: "gpt-5.6-sol",
        subtask: "must not enter ledger",
        helperCap: 4,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) {
      XCTAssertEqual(
        $0 as? TatwoGoalRunDispatchLifecycleError,
        .dispatchBindingMismatch(
          field: "bindingID",
          expected: "binding-sub",
          actual: "wrong-binding"))
    }

    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .planned)
    XCTAssertTrue(
      try registry.run(forContractID: contract.contractID)?.records.isEmpty ?? true)
  }

  func testWrongModelIDFailsClosedBeforeLedgerBegin() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "wrong model")

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        bindingID: "binding-sub",
        sourceSlotID: "sub",
        identity: .sub,
        modelID: "gpt-5.6-luna",
        subtask: "must not enter ledger",
        helperCap: 4,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) {
      XCTAssertEqual(
        $0 as? TatwoGoalRunDispatchLifecycleError,
        .dispatchBindingMismatch(
          field: "modelID",
          expected: "gpt-5.6-sol",
          actual: "gpt-5.6-luna"))
    }

    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .planned)
    XCTAssertTrue(
      try registry.run(forContractID: contract.contractID)?.records.isEmpty ?? true)
  }

  func testLedgerBeginFailureRollsGoalRunBackToPlanned() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "begin failure")

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        bindingID: "binding-sub",
        sourceSlotID: "sub",
        identity: .sub,
        modelID: "gpt-5.6-sol",
        subtask: "must not start",
        helperCap: 0,
        goalStore: goalStore,
        dispatchRegistry: registry))

    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .planned)
    XCTAssertTrue(
      try registry.run(forContractID: contract.contractID)?.records.isEmpty ?? true)
  }

  func testLedgerAcknowledgeFailureNeverMovesGoalRunToRunning() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "ack failure")
    let queued = TatwoDispatchRecord(
      id: "dispatch-injected",
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "ack failure",
      status: .queued,
      startedAt: Date(),
      updatedAt: Date())
    var failedRecordID: String?

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        goalStore: goalStore,
        ledgerBegin: { queued },
        ledgerAcknowledge: { _ in throw InjectedFailure.ledgerAcknowledge },
        ledgerFail: { record, _ in failedRecordID = record.id }))

    XCTAssertEqual(failedRecordID, queued.id)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .planned)
  }

  func testLedgerAcknowledgeAndFailureDoubleFaultQuarantinesGoalRun() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "ack double fault")
    let queued = TatwoDispatchRecord(
      id: "dispatch-double-fault",
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "ack double fault",
      status: .queued,
      startedAt: Date(),
      updatedAt: Date())

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        goalStore: goalStore,
        ledgerBegin: { queued },
        ledgerAcknowledge: { _ in throw InjectedFailure.ledgerAcknowledge },
        ledgerFail: { _, _ in throw InjectedFailure.ledgerFail }))

    let quarantined = try goalStore.requireIssuedContract(contract.contractID)
    XCTAssertEqual(quarantined.status, .blocked)
    XCTAssertTrue(quarantined.statusReason?.hasPrefix("reconciliation_required:") == true)
    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        goalStore: goalStore,
        ledgerBegin: { queued },
        ledgerAcknowledge: { $0 },
        ledgerFail: { _, _ in }))
  }

  func testCompletedDispatchDoesNotSealGoalRunAndSequentialBeginStillSucceeds() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "sequential dispatches")
    let first = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "review",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: first.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)

    let second = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "adversarial",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(second.status, .running)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)
  }

  func testAllCompletedDispatchesRequireExplicitFinalizeBarrier() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "explicit finalize")
    let first = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "review",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let second = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "adversarial",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: first.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: second.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)

    let finalized = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(finalized.status, .awaitingNextCycle)
    XCTAssertTrue(
      finalized.statusReason?
        .hasPrefix("dispatch_cycle_finalized:1:2:dispatch-cycle-seal-") == true)
    XCTAssertNotEqual(finalized.status, .passed)
    XCTAssertNotEqual(finalized.status, .rollbackRequired)
  }

  func testFinalizeRejectsEmptyOrIncompleteDispatchSet() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "finalize guards")

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.finalize(
        contractID: contract.contractID,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .dispatchSetEmpty(contract.contractID))
    }

    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "still running",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.finalize(
        contractID: contract.contractID,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .dispatchSetIncomplete([record.id]))
    }
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)
  }

  // M4b 更新：Grok dev attestation 尚未啟用時保留 failed lane，
  // Goal 必須維持 running，且 canonical finalize 仍拒絕 seal。
  func testUnverifiedGrokDevelopmentLaneStaysRunningAndCannotFinalize() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults
          .nativeDevelopmentXXLFableGrokScenarioID,
      objective: "M4b Fable and Grok cycle",
      store: goalStore)
    let fable =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: contract,
        selectedModelID: "fable-5",
        subtask: "complete Fable lane",
        goalStore: goalStore,
        dispatchRegistry: registry)
    _ = try TatwoNativeDevelopmentDispatchCoordinator.complete(
      contractID: contract.contractID,
      dispatchID: fable.id,
      receiptID: "terminal:fable",
      outputRef: "artifact:fable",
      goalStore: goalStore,
      dispatchRegistry: registry)
    let grok =
      try TatwoNativeDevelopmentDispatchCoordinator.beginSelectedExecutor(
        contract: contract,
        selectedModelID: "grok-build",
        subtask: "attempt Grok lane",
        goalStore: goalStore,
        dispatchRegistry: registry)
    let failed = try TatwoNativeDevelopmentDispatchCoordinator.fail(
      contractID: contract.contractID,
      dispatchID: grok.id,
      errorCode:
        TatwoNativeDevelopmentDispatchCoordinator
          .grokDevAttestationUnverifiedErrorCode,
      message:
        "Governed development session failed: "
          + TatwoNativeDevelopmentDispatchCoordinator
            .grokDevAttestationUnverifiedErrorCode,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(
      failed.failureReceipt?.errorCode,
      TatwoNativeDevelopmentDispatchCoordinator
        .grokDevAttestationUnverifiedErrorCode)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)
    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.finalize(
        contractID: contract.contractID,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .dispatchSetIncomplete([grok.id]))
    }
    XCTAssertNil(
      try registry.run(forContractID: contract.contractID)?.sealID)
  }

  func testFinalizeSealsGoalRunAgainstFurtherDispatches() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "sealed run")
    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "complete",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: record.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        bindingID: "binding-sub",
        sourceSlotID: "sub",
        identity: .sub,
        modelID: "gpt-5.6-sol",
        subtask: "must not reopen",
        helperCap: 4,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .goalRunCannotBegin(status: .awaitingNextCycle))
    }
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .awaitingNextCycle)
  }

  func testFinalizeRetryReturnsSameHumanGateSeal() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "idempotent finalize")
    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "complete",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: record.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)

    let first = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let retry = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(retry, first)
    XCTAssertEqual(
      try registry.run(forContractID: contract.contractID)?.sealedRecordIDs,
      [record.id])
  }

  func testSameGoalCanRunAndSealTwoImmutableDispatchCycles() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "two cycle goal")
    let first = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "cycle one",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(first.cycleEpoch, 1)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: first.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let boundary1 = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let seal1 = try XCTUnwrap(boundary1.latestDispatchCycleSealID)

    let opened2 = try TatwoGoalRunDispatchLifecycle.advanceCycle(
      contractID: contract.contractID,
      expectedSealID: seal1,
      goalStore: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(opened2.status, .running)
    XCTAssertEqual(
      try TatwoGoalRunDispatchLifecycle.advanceCycle(
        contractID: contract.contractID,
        expectedSealID: seal1,
        goalStore: goalStore,
        dispatchRegistry: registry),
      opened2)

    let second = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "cycle two",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(second.cycleEpoch, 2)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: second.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let boundary2 = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(boundary2.status, .awaitingNextCycle)
    XCTAssertEqual(boundary2.latestDispatchCycleEpoch, 2)
    let run = try XCTUnwrap(registry.run(forContractID: contract.contractID))
    XCTAssertEqual(run.cycleSeals?.map(\.epoch), [1, 2])
    XCTAssertEqual(run.cycleSeals?.first?.sealID, seal1)
    XCTAssertEqual(run.cycleSeals?.first?.recordIDs, [first.id])
    XCTAssertEqual(run.cycleSeals?.last?.recordIDs, [second.id])
    XCTAssertNotEqual(run.cycleSeals?.last?.sealID, seal1)
  }

  func testAdvanceCycleRejectsStaleSealAndTerminalGoal() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "advance guards")
    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "complete",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: record.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let boundary = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let sealID = try XCTUnwrap(boundary.latestDispatchCycleSealID)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.advanceCycle(
        contractID: contract.contractID,
        expectedSealID: "stale-seal",
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDispatchRegistryError,
        .staleCycleBoundary(expected: "stale-seal", actual: sealID))
    }

    _ = try goalStore.updateStatus(
      contractID: contract.contractID,
      status: .passed,
      authority: .goalClose,
      reason: "judge passed")
    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.advanceCycle(
        contractID: contract.contractID,
        expectedSealID: sealID,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .goalRunCannotBegin(status: .passed))
    }
  }

  func testFinalizeRecoversWhenRegistryWasSealedBeforeGoalStatusWrite() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "seal recovery")
    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "complete",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: record.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let sealed = try registry.sealCompletedSet(contractID: contract.contractID)

    let finalized = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: contract.contractID,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(finalized.status, .awaitingNextCycle)
    XCTAssertTrue(finalized.statusReason?.contains(sealed.sealID ?? "missing") == true)
  }

  func testConcurrentBeginAndFinalizeNeverLeaveHumanGateGoalWithActiveDispatch() throws {
    for iteration in 0..<20 {
      let (goalStore, registry, root) = makeStores()
      defer { try? FileManager.default.removeItem(at: root) }
      let contract = try beginContract(
        store: goalStore,
        objective: "begin finalize race \(iteration)")
      let first = try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        bindingID: "binding-sub",
        sourceSlotID: "sub",
        identity: .sub,
        modelID: "gpt-5.6-sol",
        subtask: "complete",
        helperCap: 4,
        goalStore: goalStore,
        dispatchRegistry: registry)
      _ = try TatwoGoalRunDispatchLifecycle.update(
        contractID: contract.contractID,
        dispatchID: first.id,
        status: .completed,
        goalStore: goalStore,
        dispatchRegistry: registry)

      let ready = DispatchSemaphore(value: 0)
      let start = DispatchSemaphore(value: 0)
      let group = DispatchGroup()
      let results = RaceResults()

      group.enter()
      DispatchQueue.global().async {
        ready.signal()
        start.wait()
        do {
          _ = try TatwoGoalRunDispatchLifecycle.finalize(
            contractID: contract.contractID,
            goalStore: goalStore,
            dispatchRegistry: registry)
          results.recordFinalizeSuccess()
        } catch {
          results.record(error)
        }
        group.leave()
      }

      group.enter()
      DispatchQueue.global().async {
        ready.signal()
        start.wait()
        do {
          _ = try TatwoGoalRunDispatchLifecycle.begin(
            contractID: contract.contractID,
        bindingID: "binding-sub",
        sourceSlotID: "sub",
        identity: .sub,
        modelID: "gpt-5.6-sol",
            subtask: "racing begin",
            helperCap: 4,
            goalStore: goalStore,
            dispatchRegistry: registry)
          results.recordBeginSuccess()
        } catch {
          results.record(error)
        }
        group.leave()
      }

      ready.wait()
      ready.wait()
      start.signal()
      start.signal()
      XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

      let goal = try goalStore.requireIssuedContract(contract.contractID)
      let run = try XCTUnwrap(registry.run(forContractID: contract.contractID))
      let active = run.records.filter { $0.status == .queued || $0.status == .running }
      XCTAssertFalse(
        goal.status == .awaitingNextCycle && !active.isEmpty,
        "iteration \(iteration) produced awaiting_next_cycle + active: \(results.snapshot())")
      if goal.status == .awaitingNextCycle {
        XCTAssertEqual(run.records.count, 1)
        XCTAssertNotNil(run.sealID)
      } else {
        XCTAssertEqual(goal.status, .running)
        XCTAssertEqual(run.records.count, 2)
        XCTAssertEqual(active.count, 1)
      }
    }
  }

  func testLegacyDispatchFinalizedSucceededAdvancesWithoutRewritingOldSeal() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "legacy succeeded remains sealed")
    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "complete before legacy migration",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: record.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    let sealed = try registry.sealCompletedSet(
      contractID: contract.contractID,
      goalID: contract.goalID)
    let sealID = try XCTUnwrap(sealed.sealID)
    var legacyRun = try XCTUnwrap(registry.run(forContractID: contract.contractID))
    legacyRun.activeCycleEpoch = nil
    legacyRun.cycleSeals = nil
    try writeDispatchRun(legacyRun, to: registry)
    var legacy = try goalStore.requireIssuedContract(contract.contractID)
    legacy.status = .succeeded
    legacy.statusReason = "dispatch_set_finalized:1:\(sealID)"
    try writeGoalRecord(legacy, to: goalStore)

    let advanced = try TatwoGoalRunDispatchLifecycle.advanceCycle(
      contractID: contract.contractID,
      expectedSealID: sealID,
      goalStore: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(advanced.status, .running)
    XCTAssertEqual(
      advanced.statusReason,
      "dispatch_cycle_opened:2:after:\(sealID)")
    let advancedRun = try XCTUnwrap(registry.run(forContractID: contract.contractID))
    XCTAssertEqual(advancedRun.activeCycleEpoch, 2)
    XCTAssertEqual(advancedRun.cycleSeals?.count, 1)
    XCTAssertEqual(advancedRun.cycleSeals?.first?.sealID, sealID)
    XCTAssertEqual(advancedRun.cycleSeals?.first?.migratedLegacy, true)
  }

  func testFinalizeRejectsUnrelatedHumanGateEvenWhenDispatchRegistryIsSealed() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "unrelated human gate is not finalize retry")
    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "complete before unrelated gate",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: record.id,
      status: .completed,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try registry.sealCompletedSet(
      contractID: contract.contractID,
      goalID: contract.goalID)
    var unrelatedGate = try goalStore.requireIssuedContract(contract.contractID)
    unrelatedGate.status = .humanGate
    unrelatedGate.statusReason = "manual_goal_judge_review"
    try writeGoalRecord(unrelatedGate, to: goalStore)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.finalize(
        contractID: contract.contractID,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .goalRunCannotFinalize(status: .humanGate))
    }
    let unchanged = try goalStore.requireIssuedContract(contract.contractID)
    XCTAssertEqual(unchanged.status, .humanGate)
    XCTAssertEqual(unchanged.statusReason, "manual_goal_judge_review")
  }

  func testRetryableFailureBlocksGoalRunAndAllowsSupersedingRetry() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "retryable child failure")
    let first = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "refute first",
      logicalDispatchID: "logical-sol-review",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: first.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      errorMessage: "server_error",
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .blocked)

    let retry = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "refute first retry",
      logicalDispatchID: "logical-sol-review",
      supersedes: first.id,
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(retry.attempt, 2)
    XCTAssertEqual(retry.supersedes, first.id)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)
  }

  func testBeginRejectsRetryAttemptCapBelowSettlementFloorWithoutMutatingStores() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "reject retry cap below settlement floor")
    let goalBefore = try goalStore.requireIssuedContract(contract.contractID)
    let ledgerBefore = try registry.run(forContractID: contract.contractID)
    let retryAttemptCap = TatwoGoalRunStore.dispatchRetryAttemptCap - 1

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        bindingID: "binding-supervisor",
        sourceSlotID: "supervisor",
        identity: .supervisor,
        modelID: "gpt-5.6-terra",
        subtask: "must not mutate",
        retryAttemptCap: retryAttemptCap,
        helperCap: 4,
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunStoreError,
        .dispatchRetryAttemptCapBelowSettlementFloor(
          requested: retryAttemptCap,
          floor: TatwoGoalRunStore.dispatchRetryAttemptCap))
    }

    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID),
      goalBefore)
    XCTAssertEqual(
      try registry.run(forContractID: contract.contractID),
      ledgerBefore)
  }

  func testBeginAcceptsRetryAttemptCapAtSettlementFloor() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "accept retry cap at settlement floor")

    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "settlement floor",
      retryAttemptCap: TatwoGoalRunStore.dispatchRetryAttemptCap,
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(record.attempt, 1)
    XCTAssertEqual(record.status, .running)
  }

  func testBeginAcceptsExplicitRetryAttemptCapAboveSettlementFloor() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "accept explicitly relaxed retry cap")

    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "explicitly relaxed settlement ceiling",
      retryAttemptCap: TatwoGoalRunStore.dispatchRetryAttemptCap + 1,
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(record.attempt, 1)
    XCTAssertEqual(record.status, .running)
  }

  func testRetryableFailureAtAttemptBudgetMovesGoalRunToFailed() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "retry budget exhausted")
    let first = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "first attempt",
      logicalDispatchID: "logical-sol-budget",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: first.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "timeout",
      errorMessage: "timeout",
      goalStore: goalStore,
      dispatchRegistry: registry)
    let second = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "second attempt",
      logicalDispatchID: "logical-sol-budget",
      supersedes: first.id,
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: second.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      errorMessage: "server_error",
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .failed)
  }

  func testSupersededFailureReplayCannotResetRetryBudget() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "retry replay")
    let first = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "attempt one",
      logicalDispatchID: "logical-replay",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: first.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      errorMessage: "attempt one failed",
      goalStore: goalStore,
      dispatchRegistry: registry)
    let second = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-supervisor",
      sourceSlotID: "supervisor",
      identity: .supervisor,
      modelID: "gpt-5.6-terra",
      subtask: "attempt two",
      logicalDispatchID: "logical-replay",
      supersedes: first.id,
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.update(
        contractID: contract.contractID,
        dispatchID: first.id,
        status: .failed,
        failureClass: .retryable,
        errorCode: "timeout",
        errorMessage: "stale replay",
        goalStore: goalStore,
        dispatchRegistry: registry))
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .running)

    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: second.id,
      status: .failed,
      failureClass: .retryable,
      errorCode: "server_error",
      errorMessage: "attempt two failed",
      goalStore: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .failed)
    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.begin(
        contractID: contract.contractID,
        bindingID: "binding-supervisor",
        sourceSlotID: "supervisor",
        identity: .supervisor,
        modelID: "gpt-5.6-terra",
        subtask: "attempt three",
        logicalDispatchID: "logical-replay",
        supersedes: second.id,
        helperCap: 4,
        goalStore: goalStore,
        dispatchRegistry: registry))
  }

  func testTerminalFailedDispatchMovesGoalRunToFailed() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(store: goalStore, objective: "failure terminal")
    let record = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "ui validation",
      helperCap: 4,
      goalStore: goalStore,
      dispatchRegistry: registry)

    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: contract.contractID,
      dispatchID: record.id,
      status: .failed,
      failureClass: .terminal,
      errorCode: "policy_violation",
      errorMessage: "policy_violation",
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      .failed)
  }

  private final class RaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func recordBeginSuccess() {
      record("begin=success")
    }

    func recordFinalizeSuccess() {
      record("finalize=success")
    }

    func record(_ error: Error) {
      record("error=\(error)")
    }

    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }

    private func record(_ value: String) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }
  }

  private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }

    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
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

  private func writeDispatchRun(
    _ run: TatwoStoredDispatchRun,
    to registry: TatwoDispatchRegistry
  ) throws {
    let url = try registry.fileURL(forContractID: run.contractID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(run).write(to: url, options: [.atomic])
  }

  private func mutateStoredGoalJSON(
    contractID: String,
    store: TatwoGoalRunStore,
    _ mutate: (inout [String: Any]) -> Void
  ) throws {
    let url = try store.fileURL(forContractID: contractID)
    let data = try Data(contentsOf: url)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    mutate(&object)
    let mutated = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys])
    try mutated.write(to: url, options: [.atomic])
  }

  func testSupersededRevisionRejectsLateDispatchUpdateWithoutMutatingStores() throws {
    let (goalStore, registry, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "stale revision dispatch update")
    let binding = try XCTUnwrap(
      contract.identityBindings.first(where: { $0.identity == .sub }))
    let running = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: contract.contractID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: binding.modelID ?? "",
      subtask: "old revision work",
      helperCap: 1,
      goalStore: goalStore,
      dispatchRegistry: registry)
    _ = try goalStore.updateStatus(
      contractID: contract.contractID,
      status: .superseded,
      authority: .revisionPromotion,
      reason: "superseded_by_revision:next")
    let goalURL = try goalStore.fileURL(forContractID: contract.contractID)
    let registryURL = try registry.fileURL(forContractID: contract.contractID)
    let goalBefore = try Data(contentsOf: goalURL)
    let registryBefore = try Data(contentsOf: registryURL)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.update(
        contractID: contract.contractID,
        dispatchID: running.id,
        status: .completed,
        receiptID: "late-receipt",
        goalStore: goalStore,
        dispatchRegistry: registry)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .staleGoalRevision(contract.contractID))
    }
    XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)
    XCTAssertEqual(try Data(contentsOf: registryURL), registryBefore)
  }

  func testRemoteAuthorizationMapsSupersededRevisionToExplicitStaleError() throws {
    let (goalStore, _, root) = makeStores()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try beginContract(
      store: goalStore,
      objective: "stale remote revision")
    _ = try goalStore.updateStatus(
      contractID: contract.contractID,
      status: .dispatching,
      authority: .caller)
    _ = try goalStore.updateStatus(
      contractID: contract.contractID,
      status: .running,
      authority: .ledgerBeginAck,
      evidence: .ledger(dispatchID: "stale-remote"))
    _ = try goalStore.updateStatus(
      contractID: contract.contractID,
      status: .superseded,
      authority: .revisionPromotion,
      reason: "superseded_by_revision:next")
    let route = try XCTUnwrap(
      contract.identityBindings.first(where: { $0.identity == .sub })?.modelID)
    let job = remoteJob(
      contract: contract,
      exactModelRouteID: route,
      workPath: root.path)

    XCTAssertThrowsError(
      try TatwoGoalRunDispatchLifecycle.authorizeRemoteDispatch(
        job: job,
        goalStore: goalStore,
        environment: [:])
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRunDispatchLifecycleError,
        .staleGoalRevision(contract.contractID))
    }
  }
}

/// File-local in-memory key store for GoalRun lifecycle channel tests.
///
/// The unique name avoids relying on other test files' `private` fixtures or
/// creating module-wide same-name ambiguity.
private final class GoalRunLifecycleMemoryPrivateKeyStore:
  TatwoDevicePrivateKeyStore,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  func loadPrivateKey(
    deviceID: String,
    generation: UInt64
  ) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys["\(deviceID):\(generation)"]
  }

  func storePrivateKey(
    _ key: Data,
    deviceID: String,
    generation: UInt64
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let slot = "\(deviceID):\(generation)"
    if let existing = keys[slot], existing != key {
      throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
    }
    keys[slot] = key
  }
}
