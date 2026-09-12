import XCTest

@testable import TatwoUltraworkCore

/// Q1: the persistent session pointer that lets a new terminal / Claude Code conversation
/// re-attach to the active OS session.
final class SessionPointerTests: XCTestCase {
  func testRawPointerFixtureRoundTripUsesOnlyIsolatedRootCleanup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoSessionStore(directoryURL: root)

    XCTAssertNil(try store.current())  // nothing active yet

    let pointer = TatwoSessionPointer(
      contractID: "contract-xl-coding-abc123def456", goalID: "goal-xl-coding-abc123def456",
      mode: .xl, scenario: "coding", objective: "session test")
    try store.writeRawPointerFixtureForTesting(pointer)

    let loaded = try store.current()
    XCTAssertEqual(loaded, pointer)
    XCTAssertEqual(loaded?.contractID, pointer.contractID)
    XCTAssertEqual(loaded?.mode, .xl)
    XCTAssertEqual(loaded?.scenario, "coding")

  }

  func testBeginCurrentPublishesOneCanonicalGoalAndPointerAttachment() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let owner = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      sessionID: "session-begin-current",
      workspacePath: root.appendingPathComponent(
        "workspace", isDirectory: true).path)
    let routeOverride = WorkOSRouteBindingOverride(
      primaryModelID: "gpt-5.6-sol",
      secondaryModelID: "fable-5")
    let objective =
      "publish one canonical GoalRun and current-session pointer"
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: objective,
      routeBindingOverride: routeOverride)
    try initializeFormalAuthorityLocks(
      at: root,
      contractID: contract.contractID)
    let registry = TatwoDispatchRegistry(directoryURL: root)

    let attachment = try sessionStore.beginCurrent(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: objective,
      routeBindingOverride: routeOverride,
      owner: .session(owner),
      goalStore: goalStore,
      dispatchRegistry: registry)

    XCTAssertEqual(attachment.schema, "TatwoSessionAttachmentV1")
    XCTAssertEqual(attachment.pointer.schema, "TatwoSessionAuthorityPointerV3")
    XCTAssertEqual(attachment.pointer, try sessionStore.current())
    XCTAssertEqual(
      attachment.goalRecord,
      try goalStore.requireIssuedContract(attachment.contract.contractID))
    XCTAssertEqual(attachment.pointer.contractID, attachment.contract.contractID)
    XCTAssertEqual(attachment.pointer.goalID, attachment.contract.goalID)
    XCTAssertEqual(attachment.goalRecord.contractID, attachment.contract.contractID)
    XCTAssertEqual(attachment.goalRecord.goalID, attachment.contract.goalID)
    XCTAssertEqual(attachment.contract.routeBindingOverride, routeOverride)
    XCTAssertEqual(attachment.goalRecord.routeBindingOverride, routeOverride)
    let manifest = try registry.requireExecutionManifest(
      contractID: attachment.contract.contractID,
      expectedSHA256: try XCTUnwrap(
        attachment.pointer.executionManifestSHA256))
    XCTAssertEqual(
      manifest.entries,
      TatwoExecutionManifestFactory.make(
        contract: attachment.contract,
        generatedAt: manifest.generatedAt).entries)
    XCTAssertEqual(try goalRunJSONFiles(in: root).count, 1)
  }

  func testFormalV3SessionAndThreadPersistExactOwnerKind() throws {
    for kind in [TatwoSessionOwnerKindV1.session, .thread] {
      let fixture = try makeFormalV3Fixture(ownerKind: kind)
      defer { try? FileManager.default.removeItem(at: fixture.root) }

      XCTAssertEqual(fixture.attachment.pointer.ownerBinding?.ownerKind, kind)
      XCTAssertEqual(try fixture.sessionStore.current()?.ownerBinding?.ownerKind, kind)
    }
  }

  func testV3CanonicalVerificationRequiresExactKindAndAllowsStatusOnlyInspect()
    throws
  {
    let fixture = try makeFormalV3Fixture(ownerKind: .thread)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let wrongKind = TatwoCanonicalSessionOwnerV1(
      provider: fixture.owner.provider,
      locator: .session(fixture.owner.externalProviderID),
      workspacePath: fixture.owner.workspacePath)

    XCTAssertNotNil(
      try fixture.sessionStore.inspectCurrent(
        goalStore: fixture.goalStore))
    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("missing"))
    }
    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .canonicalV3(wrongKind),
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("ownerKind"))
    }
    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .legacyV2(fixture.owner.expectation),
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("verificationSchema"))
    }

    let inspected = try XCTUnwrap(
      fixture.sessionStore.inspectCurrent(
        ownerVerification: .canonicalV3(fixture.owner),
        goalStore: fixture.goalStore))
    let attached = try fixture.sessionStore.attachCurrent(
      ownerVerification: .canonicalV3(fixture.owner),
      goalStore: fixture.goalStore)
    XCTAssertEqual(inspected.pointer, attached.pointer)
  }

  func testV2AcceptsOnlyExplicitLegacyVerification() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let expectation = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      externalProviderSessionID: fixture.sessionID,
      workspacePath: fixture.workspacePath)

    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("missing"))
    }
    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .canonicalV3(.session(expectation)),
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("verificationSchema"))
    }
    XCTAssertNoThrow(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .legacyV2(expectation),
        goalStore: fixture.goalStore))
  }

  func testV3MissingOwnerKindRejectsBeforeProjection() throws {
    let fixture = try makeFormalV3Fixture(ownerKind: .session)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pointer = fixture.attachment.pointer
    let owner = try XCTUnwrap(pointer.ownerBinding)
    let tampered = TatwoSessionPointer(
      schema: pointer.schema,
      contractID: pointer.contractID,
      goalID: pointer.goalID,
      mode: pointer.mode,
      scenario: pointer.scenario,
      objective: pointer.objective,
      startedAt: pointer.startedAt,
      ownerBinding: TatwoSessionOwnerBindingV1(
        provider: owner.provider,
        sessionID: owner.sessionID,
        ownerKind: nil,
        workspacePath: owner.workspacePath,
        contractID: owner.contractID,
        goalID: owner.goalID),
      generation: pointer.generation,
      authorityTransactionID: pointer.authorityTransactionID,
      authorityPlanSHA256: pointer.authorityPlanSHA256,
      executionManifestSHA256: pointer.executionManifestSHA256)
    try fixture.sessionStore.writeRawPointerFixtureForTesting(tampered)

    XCTAssertThrowsError(
      try fixture.sessionStore.inspectCurrent(
        ownerVerification: .canonicalV3(fixture.owner),
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .invalidOwnerBinding("v3_owner"))
    }
  }

  func testV3KindCollisionRejectsAllDestructiveRoutesWithoutByteChanges()
    throws
  {
    let fixture = try makeFormalV3Fixture(ownerKind: .thread)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pointerURL = fixture.root.appendingPathComponent("current-session.json")
    let goalURL = try XCTUnwrap(
      try goalRunJSONFiles(in: fixture.root).first)
    let pointerBefore = try Data(contentsOf: pointerURL)
    let goalBefore = try Data(contentsOf: goalURL)
    let snapshot = try XCTUnwrap(fixture.sessionStore.snapshotCurrent())
    let wrongKind = TatwoCanonicalSessionOwnerV1(
      provider: fixture.owner.provider,
      locator: .session(fixture.owner.externalProviderID),
      workspacePath: fixture.owner.workspacePath)
    let wrongVerification =
      TatwoSessionOwnerVerificationV1.canonicalV3(wrongKind)

    XCTAssertThrowsError(
      try fixture.sessionStore.stopCurrent(
        ownerVerification: wrongVerification,
        goalStore: fixture.goalStore))
    XCTAssertThrowsError(
      try fixture.sessionStore.compareAndClearCurrent(
        snapshot: snapshot,
        ownerVerification: wrongVerification,
        goalStore: fixture.goalStore))
    XCTAssertThrowsError(
      try fixture.sessionStore.supersedePristinePlannedCurrent(
        ownerVerification: wrongVerification,
        expectedContractID: fixture.attachment.contract.contractID,
        expectedGoalID: fixture.attachment.contract.goalID,
        expectedMode: fixture.attachment.contract.mode,
        expectedScenario: fixture.attachment.contract.scenario,
        expectedObjective: fixture.attachment.contract.objective,
        goalStore: fixture.goalStore))
    XCTAssertThrowsError(
      try fixture.sessionStore.reconcileSupersededTerminalCurrent(
        ownerVerification: wrongVerification,
        goalStore: fixture.goalStore))
    XCTAssertThrowsError(
      try fixture.sessionStore.closeAndClearCurrent(
        ownerVerification: wrongVerification,
        expectedContractID: fixture.attachment.contract.contractID,
        expectedGoalID: fixture.attachment.contract.goalID,
        expectedMode: fixture.attachment.contract.mode,
        expectedScenario: fixture.attachment.contract.scenario,
        expectedObjective: fixture.attachment.contract.objective,
        goalStore: fixture.goalStore))

    XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
    XCTAssertEqual(try Data(contentsOf: goalURL), goalBefore)
  }

  func testBeginCurrentRejectsEmptyTypedOwnerBeforeCreatingArtifacts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)

    XCTAssertThrowsError(
      try sessionStore.beginCurrent(
        mode: .m,
        scenarioProfileID: "coding",
        objective: "empty typed owner must fail before authority bootstrap",
        owner: TatwoCanonicalSessionOwnerV1(
          provider: "",
          locator: .session(""),
          workspacePath: ""),
        goalStore: goalStore,
        dispatchRegistry: TatwoDispatchRegistry(directoryURL: root))
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .ownerRequired)
    }
    XCTAssertTrue(try GoalStoreTestSupport.relativeArtifacts(under: root).isEmpty)
  }

  func testBeginCurrentRejectsMissingAuthorityLocksWithoutImplicitBootstrap() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let objective = "missing authority locks remain fail closed"

    XCTAssertThrowsError(
      try sessionStore.beginCurrent(
        mode: .m,
        scenarioProfileID: "coding",
        objective: objective,
        owner: .session(
          formalOwner(
            at: root,
            sessionID: "session-missing-locks")),
        goalStore: goalStore,
        dispatchRegistry: TatwoDispatchRegistry(directoryURL: root))
    ) { error in
      guard let lifecycleError =
        error as? TatwoGoalStoreLifecycleLockError,
        case .artifactMissing = lifecycleError
      else {
        return XCTFail("expected lifecycle artifactMissing, got \(error)")
      }
    }
    XCTAssertTrue(try GoalStoreTestSupport.relativeArtifacts(under: root).isEmpty)
  }

  func testBeginCurrentRejectsExistingPointerBeforeMintingAnotherGoal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let owner = formalOwner(
      at: root,
      sessionID: "session-existing-pointer")
    let firstContract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "the only published current session")
    try initializeFormalAuthorityLocks(
      at: root,
      contractID: firstContract.contractID)
    let first = try sessionStore.beginCurrent(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "the only published current session",
      owner: .session(owner),
      goalStore: goalStore,
      dispatchRegistry: TatwoDispatchRegistry(directoryURL: root))
    let pointerURL = root.appendingPathComponent("current-session.json")
    let pointerBefore = try Data(contentsOf: pointerURL)
    let goalFilesBefore = try goalRunJSONFiles(in: root)
    let goalBytesBefore = try Dictionary(
      uniqueKeysWithValues: goalFilesBefore.map {
        ($0.lastPathComponent, try Data(contentsOf: $0))
      })

    let secondContract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "must not mint while another pointer exists")
    try initializeFormalAuthorityLocks(
      at: root,
      contractID: secondContract.contractID)
    XCTAssertThrowsError(
      try sessionStore.beginCurrent(
        mode: .xxl,
        scenarioProfileID: "coding",
        objective: "must not mint while another pointer exists",
        owner: .session(owner),
        goalStore: goalStore,
        dispatchRegistry: TatwoDispatchRegistry(directoryURL: root))
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .preexistingAuthorityArtifact("current-session"))
    }

    XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
    XCTAssertEqual(try sessionStore.current(), first.pointer)
    let goalFilesAfter = try goalRunJSONFiles(in: root)
    XCTAssertEqual(
      goalFilesAfter.map(\.lastPathComponent),
      goalFilesBefore.map(\.lastPathComponent))
    for goalFile in goalFilesAfter {
      XCTAssertEqual(
        try Data(contentsOf: goalFile),
        goalBytesBefore[goalFile.lastPathComponent])
    }
  }

  func testBeginCurrentCrossProcessContentionPublishesExactlyOneSession() throws {
    if let child = beginCurrentContentionChildConfiguration() {
      try runBeginCurrentContentionChild(child)
      return
    }

    let temporaryBase = beginCurrentContentionTemporaryBase()
    try FileManager.default.createDirectory(
      at: temporaryBase,
      withIntermediateDirectories: true)
    let root = temporaryBase.appendingPathComponent(
      "tatwo-session-pointer-contention-\(UUID().uuidString)",
      isDirectory: true)
    let barrier = root.appendingPathComponent("barrier", isDirectory: true)
    try FileManager.default.createDirectory(
      at: barrier,
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "cross-process beginCurrent contention")
    try initializeFormalAuthorityLocks(
      at: root,
      contractID: contract.contractID)

    let children = try (1...2).map { worker in
      try spawnBeginCurrentContentionChild(
        root: root,
        barrier: barrier,
        worker: worker)
    }
    defer {
      for child in children where child.process.isRunning {
        child.process.terminate()
      }
    }

    try releaseBeginCurrentContentionBarrier(
      barrier,
      children: children)
    try waitForBeginCurrentContentionChildren(children, timeout: 20)

    let outcomes = try children.map { child in
      try String(contentsOf: child.resultURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let successfulContractIDs = outcomes.compactMap { outcome -> String? in
      let prefix = "success:"
      guard outcome.hasPrefix(prefix) else { return nil }
      return String(outcome.dropFirst(prefix.count))
    }
    XCTAssertEqual(
      successfulContractIDs.count,
      2,
      "same owner+plan contention must converge through one recoverable authority transaction; outcomes=\(outcomes)"
    )
    XCTAssertEqual(
      Set(successfulContractIDs).count,
      1,
      "both idempotent callers must read back the same contract; outcomes=\(outcomes)")

    let pointerFiles = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])
      .filter { $0.lastPathComponent == "current-session.json" }
    XCTAssertEqual(pointerFiles.count, 1)

    let sessionStore = TatwoSessionStore(directoryURL: root)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let pointer = try XCTUnwrap(sessionStore.current())
    XCTAssertEqual(pointer.contractID, try XCTUnwrap(successfulContractIDs.first))
    let goalFiles = try goalRunJSONFiles(in: root)
    XCTAssertEqual(goalFiles.count, 1)
    let storedGoal = try goalStore.requireIssuedContract(pointer.contractID)
    XCTAssertEqual(storedGoal.contractID, pointer.contractID)
    XCTAssertEqual(storedGoal.goalID, pointer.goalID)
  }

  func testBeginCurrentRollsBackGoalAndPointerWhenOwnerValidationFails() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)

    XCTAssertThrowsError(
      try sessionStore.beginCurrent(
        mode: .m,
        scenarioProfileID: "coding",
        objective: "invalid owner must not leave an orphan GoalRun",
        owner: .session(
          TatwoSessionOwnerExpectationV1(
            provider: " ",
            sessionID: "session-invalid-owner",
            workspacePath: root.path)),
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .ownerRequired)
    }

    XCTAssertNil(try sessionStore.current())
    XCTAssertTrue(try goalRunJSONFiles(in: root).isEmpty)
  }

  func testAttachCurrentRehydratesExactStoredGoalWithoutMintingAnotherRun() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let routeOverride = WorkOSRouteBindingOverride(
      primaryModelID: "gpt-5.6-sol",
      secondaryModelID: "grok-build")
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "attach the exact current session",
      routeBindingOverride: routeOverride,
      store: goalStore)
    let pointer = TatwoSessionPointer(
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective)
    try sessionStore.writeRawPointerFixtureForTesting(pointer)
    let goalDirectory = root.appendingPathComponent("goals", isDirectory: true)
    let goalFilesBefore = try FileManager.default.contentsOfDirectory(
      at: goalDirectory,
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let goalFile = try XCTUnwrap(goalFilesBefore.first)
    let goalDataBefore = try Data(contentsOf: goalFile)
    let pointerFile = root.appendingPathComponent("current-session.json", isDirectory: false)
    let pointerDataBefore = try Data(contentsOf: pointerFile)
    let recordBefore = try goalStore.requireIssuedContract(contract.contractID)

    let attachment = try sessionStore.attachCurrent(
      expectedContractID: contract.contractID,
      expectedGoalID: contract.goalID,
      expectedMode: .xxl,
      expectedScenario: contract.scenario,
      expectedObjective: contract.objective,
      goalStore: goalStore)

    XCTAssertEqual(attachment.schema, "TatwoSessionAttachmentV1")
    XCTAssertEqual(attachment.pointer, pointer)
    XCTAssertEqual(attachment.contract.contractID, contract.contractID)
    XCTAssertEqual(attachment.contract.goalID, contract.goalID)
    XCTAssertEqual(attachment.goalRecord.contractID, contract.contractID)
    XCTAssertEqual(attachment.goalRecord.routeBindingOverride, routeOverride)
    XCTAssertEqual(attachment.contract.routeBindingOverride, routeOverride)
    let leadBindings = attachment.contract.identityBindings.filter { $0.identity == .lead }
    let subBindings = attachment.contract.identityBindings.filter { $0.identity == .sub }
    XCTAssertFalse(leadBindings.isEmpty)
    XCTAssertFalse(subBindings.isEmpty)
    XCTAssertTrue(
      leadBindings.allSatisfy { $0.modelID == routeOverride.primaryModelID })
    XCTAssertTrue(
      subBindings.allSatisfy { $0.modelID == routeOverride.secondaryModelID })
    let goalFilesAfter = try FileManager.default.contentsOfDirectory(
      at: goalDirectory,
      includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertEqual(goalFilesAfter.map(\.lastPathComponent), goalFilesBefore.map(\.lastPathComponent))
    XCTAssertEqual(try Data(contentsOf: goalFile), goalDataBefore)
    XCTAssertEqual(try Data(contentsOf: pointerFile), pointerDataBefore)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(contract.contractID).status,
      recordBefore.status)
  }

  func testOwnedV2PointerRoundTripsAndAttachesWithExactOwnerIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "owned current session",
      store: goalStore)
    let legacy = TatwoSessionPointer(
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective)
    let owned = legacy.owned(
      provider: "codex",
      sessionID: "019fb652-a553-7890-b177-b939073e4f0d",
      workspacePath: "/tmp/tatwo2-fixture/AI/Codex/project/多模型協作/../多模型協作")
    try sessionStore.writeRawPointerFixtureForTesting(owned)

    let attachment = try sessionStore.attachCurrent(
      ownerVerification: .legacyV2(
        TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID:
            "019fb652-a553-7890-b177-b939073e4f0d",
          workspacePath:
            "/tmp/tatwo2-fixture/AI/Codex/project/多模型協作")),
      goalStore: goalStore)

    XCTAssertEqual(attachment.pointer.schema, "TatwoSessionPointerV2")
    XCTAssertEqual(
      attachment.pointer.ownerBinding,
      TatwoSessionOwnerBindingV1(
        provider: "codex",
        sessionID: "019fb652-a553-7890-b177-b939073e4f0d",
        workspacePath: "/tmp/tatwo2-fixture/AI/Codex/project/多模型協作",
        contractID: contract.contractID,
        goalID: contract.goalID))
    XCTAssertEqual(attachment.contract.contractID, contract.contractID)
    XCTAssertEqual(attachment.goalRecord.goalID, contract.goalID)
  }

  func testExpectedOwnerExactIdentityPassesForInspectAndAttach() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let expectedOwner = TatwoSessionOwnerExpectationV1(
      provider: " codex ",
      externalProviderSessionID: fixture.sessionID,
      workspacePath: "\(fixture.workspacePath)/nested/..")
    let inspected = try XCTUnwrap(
      fixture.sessionStore.inspectCurrent(
        ownerVerification: .legacyV2(expectedOwner),
        goalStore: fixture.goalStore))
    XCTAssertEqual(inspected.pointer.ownerBinding?.provider, "codex")
    XCTAssertEqual(inspected.pointer.ownerBinding?.sessionID, fixture.sessionID)
    XCTAssertEqual(
      inspected.pointer.ownerBinding?.workspacePath,
      fixture.workspacePath)

    let attached = try fixture.sessionStore.attachCurrent(
      ownerVerification: .legacyV2(expectedOwner),
      goalStore: fixture.goalStore)
    XCTAssertEqual(attached.pointer, inspected.pointer)
    XCTAssertEqual(attached.goalRecord.goalID, fixture.contract.goalID)
  }

  func testExpectedOwnerRejectsWrongProvider() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "claude",
          externalProviderSessionID: fixture.sessionID,
          workspacePath: fixture.workspacePath)),
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("provider"))
    }
  }

  func testExpectedOwnerRejectsWrongExternalProviderSessionID() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: "different-session",
          workspacePath: fixture.workspacePath)),
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("sessionID"))
    }
  }

  func testExpectedOwnerRejectsWrongNormalizedWorkspacePath() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: fixture.sessionID,
          workspacePath: "\(fixture.workspacePath)/sibling")),
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("workspacePath"))
    }
  }

  func testExpectedOwnerFailsClosedForLegacyV1Pointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "legacy pointer owner gate",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))

    let expectedOwner = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      externalProviderSessionID: "external-session",
      workspacePath: "/tmp/tatwo-owner")
    XCTAssertThrowsError(
      try sessionStore.inspectCurrent(
        ownerVerification: .legacyV2(expectedOwner),
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("verificationSchema"))
    }
    XCTAssertThrowsError(
      try sessionStore.attachCurrent(
        ownerVerification: .legacyV2(expectedOwner),
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("verificationSchema"))
    }
  }

  func testLegacyV1OwnerMigrationUsesExactRevisionAndPreservesCanonicalIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "migrate one uniquely proven project mirror owner",
      store: goalStore)
    let legacy = TatwoSessionPointer(
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      startedAt: Date(timeIntervalSince1970: 1_785_500_000))
    try sessionStore.writeRawPointerFixtureForTesting(legacy)
    let snapshot = try XCTUnwrap(sessionStore.snapshotCurrent())
    let owner = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      externalProviderSessionID: "019fb652-a553-7890-b177-b939073e4f0d",
      workspacePath: "/tmp/tatwo2-fixture/AI/Codex/project/多模型協作")

    let migrated = try sessionStore.migrateCurrentV1Owner(
      snapshot: snapshot,
      legacyOwnerExpectation: owner)

    XCTAssertEqual(migrated.schema, "TatwoSessionPointerV2")
    XCTAssertEqual(migrated.contractID, legacy.contractID)
    XCTAssertEqual(migrated.goalID, legacy.goalID)
    XCTAssertEqual(migrated.mode, legacy.mode)
    XCTAssertEqual(migrated.scenario, legacy.scenario)
    XCTAssertEqual(migrated.objective, legacy.objective)
    XCTAssertEqual(migrated.startedAt, legacy.startedAt)
    XCTAssertEqual(
      migrated.ownerBinding,
      TatwoSessionOwnerBindingV1(
        provider: owner.provider,
        externalProviderSessionID: owner.externalProviderSessionID,
        workspacePath: owner.workspacePath,
        contractID: legacy.contractID,
        goalID: legacy.goalID))
    let attachment = try sessionStore.attachCurrent(
      ownerVerification: .legacyV2(owner),
      goalStore: goalStore)
    XCTAssertEqual(attachment.pointer, migrated)
    XCTAssertEqual(attachment.contract.contractID, contract.contractID)
    XCTAssertEqual(attachment.goalRecord.goalID, contract.goalID)
  }

  func testLegacyV1OwnerMigrationRejectsStaleRevisionWithoutMutatingWinner() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "reject stale session pointer revision",
      store: goalStore)
    let legacy = TatwoSessionPointer(
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective)
    try sessionStore.writeRawPointerFixtureForTesting(legacy)
    let staleSnapshot = try XCTUnwrap(sessionStore.snapshotCurrent())
    let winner = legacy.owned(
      provider: "codex",
      sessionID: "winner-session",
      workspacePath: "/tmp/tatwo-winner")
    try sessionStore.writeRawPointerFixtureForTesting(winner)
    let pointerURL = root.appendingPathComponent("current-session.json")
    let winnerBytes = try Data(contentsOf: pointerURL)

    XCTAssertThrowsError(
      try sessionStore.migrateCurrentV1Owner(
        snapshot: staleSnapshot,
        legacyOwnerExpectation: TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: "loser-session",
          workspacePath: "/tmp/tatwo-loser"))
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionChanged)
    }
    XCTAssertEqual(try Data(contentsOf: pointerURL), winnerBytes)
    XCTAssertEqual(try sessionStore.current(), winner)
  }

  func testLegacyV1OwnerMigrationRejectsInvalidOwnerWithoutMutation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let legacy = TatwoSessionPointer(
      contractID: "contract-xxl-coding-owner-gate",
      goalID: "goal-xxl-coding-owner-gate",
      mode: .xxl,
      scenario: "coding",
      objective: "invalid owner must not mutate pointer")
    try sessionStore.writeRawPointerFixtureForTesting(legacy)
    let snapshot = try XCTUnwrap(sessionStore.snapshotCurrent())
    let pointerURL = root.appendingPathComponent("current-session.json")
    let originalBytes = try Data(contentsOf: pointerURL)

    XCTAssertThrowsError(
      try sessionStore.migrateCurrentV1Owner(
        snapshot: snapshot,
        legacyOwnerExpectation: TatwoSessionOwnerExpectationV1(
          provider: " ",
          externalProviderSessionID: "session",
          workspacePath: "/tmp/tatwo-owner"))
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .invalidOwnerExpectation("provider"))
    }
    XCTAssertEqual(try Data(contentsOf: pointerURL), originalBytes)
    XCTAssertEqual(try sessionStore.current(), legacy)
  }

  func testCompareAndClearCurrentRemovesExactValidatedRevision() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try XCTUnwrap(fixture.sessionStore.snapshotCurrent())
    let pointerURL = fixture.root.appendingPathComponent("current-session.json")
    let expectedOwner = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      externalProviderSessionID: fixture.sessionID,
      workspacePath: fixture.workspacePath)

    let attachment = try fixture.sessionStore.compareAndClearCurrent(
      snapshot: snapshot,
      ownerVerification: .legacyV2(expectedOwner),
      expectedContractID: fixture.contract.contractID,
      expectedGoalID: fixture.contract.goalID,
      expectedMode: fixture.contract.mode,
      expectedScenario: fixture.contract.scenario,
      expectedObjective: fixture.contract.objective,
      goalStore: fixture.goalStore)

    XCTAssertEqual(attachment.pointer, snapshot.pointer)
    XCTAssertEqual(attachment.goalRecord.contractID, fixture.contract.contractID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pointerURL.path))
    XCTAssertNil(try fixture.sessionStore.current())
  }

  func testCompareAndClearCurrentRejectsStaleRevisionWithoutMutatingWinner() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let staleSnapshot = try XCTUnwrap(fixture.sessionStore.snapshotCurrent())
    let winner = staleSnapshot.pointer.owned(
      provider: "codex",
      sessionID: "winner-session",
      workspacePath: "/tmp/tatwo-winner")
    try fixture.sessionStore.writeRawPointerFixtureForTesting(winner)
    let pointerURL = fixture.root.appendingPathComponent("current-session.json")
    let winnerBytes = try Data(contentsOf: pointerURL)

    XCTAssertThrowsError(
      try fixture.sessionStore.compareAndClearCurrent(
        snapshot: staleSnapshot,
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: fixture.sessionID,
          workspacePath: fixture.workspacePath)),
        expectedContractID: fixture.contract.contractID,
        expectedGoalID: fixture.contract.goalID,
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionChanged)
    }
    XCTAssertEqual(try Data(contentsOf: pointerURL), winnerBytes)
    XCTAssertEqual(try fixture.sessionStore.current(), winner)
  }

  func testCompareAndClearCurrentMismatchDoesNotDeletePointer() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try XCTUnwrap(fixture.sessionStore.snapshotCurrent())
    let pointerURL = fixture.root.appendingPathComponent("current-session.json")
    let originalBytes = try Data(contentsOf: pointerURL)

    XCTAssertThrowsError(
      try fixture.sessionStore.compareAndClearCurrent(
        snapshot: snapshot,
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: fixture.sessionID,
          workspacePath: fixture.workspacePath)),
        expectedContractID: "contract-other",
        expectedGoalID: fixture.contract.goalID,
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .callerExpectationMismatch("contractID"))
    }
    XCTAssertEqual(try Data(contentsOf: pointerURL), originalBytes)
    XCTAssertEqual(try fixture.sessionStore.current(), snapshot.pointer)
  }

  func testCompareAndClearCurrentAllowsTerminalGoalRecord() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    for receipt in fixture.contract.receiptRequirements where receipt.requiredForPass {
      let result = WorkOSFactory.submitReceipt(
        goalID: fixture.contract.goalID,
        contractID: fixture.contract.contractID,
        loopID: fixture.contract.mainlineLoop.id,
        receiptID: receipt.id,
        receiptKind: "terminal-clear-test",
        store: fixture.goalStore)
      XCTAssertTrue(result.ok, result.decision.message)
    }
    let registry = TatwoDispatchRegistry(directoryURL: fixture.root)
    try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: fixture.contract, store: fixture.goalStore, registry: registry)
    let closed = try WorkOSFactory.closeGoal(
      goalID: fixture.contract.goalID,
      contractID: fixture.contract.contractID,
      mode: fixture.contract.mode,
      scenarioProfileID: fixture.contract.scenario,
      objective: fixture.contract.objective,
      suppliedReceiptIDs: [],
      store: fixture.goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(closed.status, .passed)
    let snapshot = try XCTUnwrap(fixture.sessionStore.snapshotCurrent())

    let attachment = try fixture.sessionStore.compareAndClearCurrent(
      snapshot: snapshot,
      ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
        provider: "codex",
        externalProviderSessionID: fixture.sessionID,
        workspacePath: fixture.workspacePath)),
      expectedContractID: fixture.contract.contractID,
      expectedGoalID: fixture.contract.goalID,
      expectedMode: fixture.contract.mode,
      expectedScenario: fixture.contract.scenario,
      expectedObjective: fixture.contract.objective,
      goalStore: fixture.goalStore)

    XCTAssertEqual(attachment.goalRecord.status, .passed)
    XCTAssertNil(try fixture.sessionStore.current())
  }

  func testCloseAndClearCurrentPreservesOpenGoalAndPointerWhenReceiptsAreIncomplete() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pointerBefore = try XCTUnwrap(fixture.sessionStore.current())
    let goalBefore = try fixture.goalStore.requireIssuedContract(
      fixture.contract.contractID)

    XCTAssertThrowsError(
      try fixture.sessionStore.closeAndClearCurrent(
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: fixture.sessionID,
          workspacePath: fixture.workspacePath)),
        expectedContractID: fixture.contract.contractID,
        expectedGoalID: fixture.contract.goalID,
        expectedMode: fixture.contract.mode,
        expectedScenario: fixture.contract.scenario,
        expectedObjective: fixture.contract.objective,
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionGoalCloseIncomplete)
    }
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID
      ),
      goalBefore)
    XCTAssertEqual(try fixture.sessionStore.current(), pointerBefore)
  }

  func testCloseAndClearCurrentOwnerMismatchLeavesGoalAndPointerUnchanged() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pointerURL = fixture.root.appendingPathComponent("current-session.json")
    let pointerBefore = try Data(contentsOf: pointerURL)
    let goalBefore = try fixture.goalStore.requireIssuedContract(
      fixture.contract.contractID)

    XCTAssertThrowsError(
      try fixture.sessionStore.closeAndClearCurrent(
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "codex",
          externalProviderSessionID: "wrong-session",
          workspacePath: fixture.workspacePath)),
        expectedContractID: fixture.contract.contractID,
        expectedGoalID: fixture.contract.goalID,
        expectedMode: fixture.contract.mode,
        expectedScenario: fixture.contract.scenario,
        expectedObjective: fixture.contract.objective,
        goalStore: fixture.goalStore))

    XCTAssertEqual(try Data(contentsOf: pointerURL), pointerBefore)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.contract.contractID),
      goalBefore)
  }

  func testFailedExpectedOwnerAttachLeavesPointerAndGoalJSONByteIdentical() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let goalFile = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(
        at: fixture.root.appendingPathComponent("goals", isDirectory: true),
        includingPropertiesForKeys: nil)
        .first(where: { $0.pathExtension == "json" }))
    let pointerFile = fixture.root.appendingPathComponent(
      "current-session.json",
      isDirectory: false)
    let goalDataBefore = try Data(contentsOf: goalFile)
    let pointerDataBefore = try Data(contentsOf: pointerFile)

    XCTAssertThrowsError(
      try fixture.sessionStore.attachCurrent(
        ownerVerification: .legacyV2(TatwoSessionOwnerExpectationV1(
          provider: "wrong-provider",
          externalProviderSessionID: fixture.sessionID,
          workspacePath: fixture.workspacePath)),
        goalStore: fixture.goalStore)
    )
    XCTAssertEqual(try Data(contentsOf: goalFile), goalDataBefore)
    XCTAssertEqual(try Data(contentsOf: pointerFile), pointerDataBefore)
  }

  func testOwnedV2PointerFailsClosedWhenOwnerContractDoesNotMatchPointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "reject tampered owner",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        schema: "TatwoSessionPointerV2",
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective,
        ownerBinding: TatwoSessionOwnerBindingV1(
          provider: "codex",
          sessionID: UUID().uuidString.lowercased(),
          workspacePath: "/tmp/tatwo-owner",
          contractID: "contract-tampered",
          goalID: contract.goalID)))

    XCTAssertThrowsError(
      try sessionStore.attachCurrent(goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .invalidOwnerBinding("contractID"))
    }
  }

  func testStoredContractProjectionBypassesBeginIssuanceBoundary() throws {
    let repoRoot = ChatPageSourceScanner.repoRoot(fromCoreTestFile: #filePath)
    let source = try ChatPageSourceScanner.readRelative(
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/WorkOS.swift",
      repoRoot: repoRoot)
    let projection = try XCTUnwrap(
      source.slice(
        from: "public static func storedContractProjection(",
        through: "private static func applyingStoredStatus("))

    XCTAssertTrue(projection.contains("projectContract("))
    XCTAssertFalse(
      projection.contains("begin("),
      "stored rehydrate must never cross the begin issuance boundary")
  }

  func testAttachCurrentRefusesTerminalStoredGoalRun() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "terminal current session must not revive",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))
    for receipt in contract.receiptRequirements where receipt.requiredForPass {
      let result = WorkOSFactory.submitReceipt(
        goalID: contract.goalID,
        contractID: contract.contractID,
        loopID: contract.mainlineLoop.id,
        receiptID: receipt.id,
        receiptKind: "terminal-attach-test",
        store: goalStore)
      XCTAssertTrue(result.ok, result.decision.message)
    }
    let registry = TatwoDispatchRegistry(directoryURL: root)
    try GoalStoreTestSupport.finalizeSuccessfulDispatch(
      contract: contract, store: goalStore, registry: registry)
    let closed = try WorkOSFactory.closeGoal(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenarioProfileID: contract.scenario,
      objective: contract.objective,
      suppliedReceiptIDs: [],
      store: goalStore,
      dispatchRegistry: registry)
    XCTAssertEqual(closed.status, .passed)

    XCTAssertThrowsError(
      try sessionStore.attachCurrent(goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .terminalGoalRun(.passed))
    }
    let inspection = try XCTUnwrap(
      sessionStore.inspectCurrent(goalStore: goalStore))
    XCTAssertEqual(inspection.contract.contractID, contract.contractID)
    XCTAssertEqual(inspection.contract.goalRun.status, .passed)
    XCTAssertEqual(inspection.goalRecord.status, .passed)
  }

  func testAttachCurrentAllowsDispatchFinalizedHumanGateGoalRun() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "human judgment remains attachable",
      store: goalStore)
    var awaitingJudgment = try goalStore.requireIssuedContract(contract.contractID)
    awaitingJudgment.status = .humanGate
    awaitingJudgment.statusReason =
      "dispatch_set_finalized:1:dispatch-seal-human-gate"
    try writeGoalRecord(awaitingJudgment, to: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))

    let attachment = try sessionStore.attachCurrent(goalStore: goalStore)

    XCTAssertEqual(attachment.goalRecord.status, .humanGate)
    XCTAssertEqual(attachment.contract.goalRun.status, .humanGate)
  }

  func testAttachCurrentAllowsLegacyDispatchFinalizedSucceededGoalRun() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "legacy succeeded awaits judgment",
      store: goalStore)
    var legacy = try goalStore.requireIssuedContract(contract.contractID)
    legacy.status = .succeeded
    legacy.statusReason =
      "dispatch_set_finalized:1:dispatch-seal-legacy"
    try writeGoalRecord(legacy, to: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))

    let attachment = try sessionStore.attachCurrent(goalStore: goalStore)

    XCTAssertEqual(attachment.goalRecord.status, .succeeded)
    XCTAssertEqual(attachment.contract.goalRun.status, .succeeded)
    XCTAssertTrue(attachment.goalRecord.isAttachableAwaitingJudgment)
  }

  func testSupersedePristinePlannedCurrentCancelsGoalAndClearsExactPointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let historical = try beginHistoricalV2CurrentForMutationTest(
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      objective: "route picker may revise untouched plan")
    let attachment = historical.attachment

    let cancelled = try sessionStore.supersedePristinePlannedCurrent(
      ownerVerification: .legacyV2(historical.owner),
      expectedContractID: attachment.contract.contractID,
      expectedGoalID: attachment.contract.goalID,
      expectedMode: attachment.contract.mode,
      expectedScenario: attachment.contract.scenario,
      expectedObjective: attachment.contract.objective,
      goalStore: goalStore)

    XCTAssertEqual(cancelled.goalRecord.status, .cancelled)
    XCTAssertEqual(
      cancelled.goalRecord.statusReason,
      "superseded_before_dispatch")
    XCTAssertNil(try sessionStore.current())
    XCTAssertEqual(
      try goalStore.requireIssuedContract(
        attachment.contract.contractID).status,
      .cancelled)
  }

  func testSupersedeFormalV3PlanningManifestOnlyCurrentCancelsGoalAndClearsPointer() throws {
    let fixture = try makeFormalV3Fixture(ownerKind: .thread)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertNotNil(
      try TatwoDispatchRegistry(directoryURL: fixture.root).run(
        forContractID: fixture.attachment.contract.contractID),
      "formal V3 begin must persist the authority planning manifest")

    let cancelled = try fixture.sessionStore.supersedePristinePlannedCurrent(
      ownerVerification: .canonicalV3(fixture.owner),
      expectedContractID: fixture.attachment.contract.contractID,
      expectedGoalID: fixture.attachment.contract.goalID,
      expectedMode: fixture.attachment.contract.mode,
      expectedScenario: fixture.attachment.contract.scenario,
      expectedObjective: fixture.attachment.contract.objective,
      goalStore: fixture.goalStore)

    XCTAssertEqual(cancelled.goalRecord.status, .cancelled)
    XCTAssertEqual(
      cancelled.goalRecord.statusReason,
      "superseded_before_dispatch")
    XCTAssertNil(try fixture.sessionStore.current())
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.attachment.contract.contractID).status,
      .cancelled)
  }

  func testSupersedeMapsPostCancellationFaultAndRestartReconcilesExactPointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let liveStore = TatwoSessionStore(directoryURL: root)
    let historical = try beginHistoricalV2CurrentForMutationTest(
      root: root,
      goalStore: goalStore,
      sessionStore: liveStore,
      objective: "restart completes a partially committed route supersession")
    let attachment = historical.attachment
    let faultedStore = TatwoSessionStore(
      directoryURL: root,
      afterSupersessionCancellation: {
        throw SupersessionFault.injected
      },
      removeSupersededPointer: {
        try FileManager.default.removeItem(at: $0)
      })

    XCTAssertThrowsError(
      try faultedStore.supersedePristinePlannedCurrent(
        ownerVerification: .legacyV2(historical.owner),
        expectedContractID: attachment.contract.contractID,
        expectedGoalID: attachment.contract.goalID,
        expectedMode: attachment.contract.mode,
        expectedScenario: attachment.contract.scenario,
        expectedObjective: attachment.contract.objective,
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionSupersededPointerCleanupRequired)
    }
    XCTAssertEqual(
      try goalStore.requireIssuedContract(
        attachment.contract.contractID).status,
      .cancelled)
    XCTAssertEqual(
      try liveStore.current()?.contractID,
      attachment.contract.contractID)

    let reconciled = try XCTUnwrap(
      liveStore.reconcileSupersededTerminalCurrent(
        ownerVerification: .legacyV2(historical.owner),
        expectedContractID: attachment.contract.contractID,
        expectedGoalID: attachment.contract.goalID,
        expectedMode: attachment.contract.mode,
        expectedScenario: attachment.contract.scenario,
        expectedObjective: attachment.contract.objective,
        goalStore: goalStore))

    XCTAssertEqual(reconciled.goalRecord.status, .cancelled)
    XCTAssertEqual(
      reconciled.goalRecord.statusReason,
      "superseded_before_dispatch")
    XCTAssertNil(try liveStore.current())
  }

  func testSupersedeMapsPointerRemovalFaultAndRestartReconcilesExactPointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let liveStore = TatwoSessionStore(directoryURL: root)
    let historical = try beginHistoricalV2CurrentForMutationTest(
      root: root,
      goalStore: goalStore,
      sessionStore: liveStore,
      objective: "pointer deletion failure remains a typed partial commit")
    let attachment = historical.attachment
    let faultedStore = TatwoSessionStore(
      directoryURL: root,
      afterSupersessionCancellation: nil,
      removeSupersededPointer: { _ in
        throw SupersessionFault.injected
      })

    XCTAssertThrowsError(
      try faultedStore.supersedePristinePlannedCurrent(
        ownerVerification: .legacyV2(historical.owner),
        expectedContractID: attachment.contract.contractID,
        expectedGoalID: attachment.contract.goalID,
        expectedMode: attachment.contract.mode,
        expectedScenario: attachment.contract.scenario,
        expectedObjective: attachment.contract.objective,
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionSupersededPointerCleanupRequired)
    }
    XCTAssertEqual(
      try goalStore.requireIssuedContract(
        attachment.contract.contractID).status,
      .cancelled)
    XCTAssertEqual(
      try liveStore.current()?.contractID,
      attachment.contract.contractID)

    XCTAssertNotNil(
      try liveStore.reconcileSupersededTerminalCurrent(
        ownerVerification: .legacyV2(historical.owner),
        expectedContractID: attachment.contract.contractID,
        expectedGoalID: attachment.contract.goalID,
        expectedMode: attachment.contract.mode,
        expectedScenario: attachment.contract.scenario,
        expectedObjective: attachment.contract.objective,
        goalStore: goalStore))
    XCTAssertNil(try liveStore.current())
  }

  func testReconcileSupersededTerminalCurrentRefusesOtherCancelledGoal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let historical = try beginHistoricalV2CurrentForMutationTest(
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      objective: "ordinary cancellation is not route supersession cleanup")
    let attachment = historical.attachment
    var cancelled = try goalStore.requireIssuedContract(
      attachment.contract.contractID)
    cancelled.status = .cancelled
    cancelled.statusReason = "cancelled_by_user"
    try writeGoalRecord(cancelled, to: goalStore)

    XCTAssertNil(
      try sessionStore.reconcileSupersededTerminalCurrent(
        ownerVerification: .legacyV2(historical.owner),
        goalStore: goalStore))
    XCTAssertEqual(
      try sessionStore.current()?.contractID,
      attachment.contract.contractID)
  }

  func testReconcileSupersededTerminalCurrentRequiresOwnerForV2Pointer() throws {
    let fixture = try makeOwnedSessionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var cancelled = try fixture.goalStore.requireIssuedContract(
      fixture.contract.contractID)
    cancelled.status = .cancelled
    cancelled.statusReason = "superseded_before_dispatch"
    try writeGoalRecord(cancelled, to: fixture.goalStore)

    XCTAssertThrowsError(
      try fixture.sessionStore.reconcileSupersededTerminalCurrent(
        expectedContractID: fixture.contract.contractID,
        expectedGoalID: fixture.contract.goalID,
        expectedMode: fixture.contract.mode,
        expectedScenario: fixture.contract.scenario,
        expectedObjective: fixture.contract.objective,
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("missing"))
    }
    XCTAssertEqual(
      try fixture.sessionStore.current()?.contractID,
      fixture.contract.contractID)
  }

  func testSupersedePlannedCurrentRejectsPublishedReceiptAndPreservesPointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let historical = try beginHistoricalV2CurrentForMutationTest(
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      objective: "published work cannot be silently rebound")
    let attachment = historical.attachment
    _ = try goalStore.appendReceipt(
      contractID: attachment.contract.contractID,
      receiptID: "published-work",
      kind: "scope",
      loopID: attachment.contract.mainlineLoop.id)

    XCTAssertThrowsError(
      try sessionStore.supersedePristinePlannedCurrent(
        ownerVerification: .legacyV2(historical.owner),
        expectedContractID: attachment.contract.contractID,
        expectedGoalID: attachment.contract.goalID,
        expectedMode: attachment.contract.mode,
        expectedScenario: attachment.contract.scenario,
        expectedObjective: attachment.contract.objective,
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionHasPublishedWork)
    }
    XCTAssertEqual(
      try sessionStore.current()?.contractID,
      attachment.contract.contractID)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(
        attachment.contract.contractID).status,
      .planned)
  }

  func testSupersedePlannedCurrentRejectsPublishedDispatchManifestAndPreservesPointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let historical = try beginHistoricalV2CurrentForMutationTest(
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      objective: "dispatch publication prevents silent route supersession")
    let attachment = historical.attachment
    let registry = TatwoDispatchRegistry(directoryURL: root)
    _ = try registry.recordManifest(
      TatwoExecutionManifestFactory.make(
        contract: attachment.contract,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000)))

    XCTAssertThrowsError(
      try sessionStore.supersedePristinePlannedCurrent(
        ownerVerification: .legacyV2(historical.owner),
        expectedContractID: attachment.contract.contractID,
        expectedGoalID: attachment.contract.goalID,
        expectedMode: attachment.contract.mode,
        expectedScenario: attachment.contract.scenario,
        expectedObjective: attachment.contract.objective,
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionHasPublishedWork)
    }
    XCTAssertEqual(
      try sessionStore.current()?.contractID,
      attachment.contract.contractID)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(
        attachment.contract.contractID).status,
      .planned)
  }

  func testSupersedeFormalV3CurrentRejectsExecutableDispatchRecordAndPreservesPointer() throws {
    let fixture = try makeFormalV3Fixture(ownerKind: .thread)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let binding = try XCTUnwrap(
      fixture.attachment.contract.identityBindings.first {
        $0.modelID != nil
      })
    let registry = TatwoDispatchRegistry(directoryURL: fixture.root)
    _ = try registry.begin(
      contractID: fixture.attachment.contract.contractID,
      goalID: fixture.attachment.contract.goalID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: try XCTUnwrap(binding.modelID),
      subtask: "executable publication blocks silent supersession",
      now: Date(timeIntervalSince1970: 1_700_000_100))

    XCTAssertThrowsError(
      try fixture.sessionStore.supersedePristinePlannedCurrent(
        ownerVerification: .canonicalV3(fixture.owner),
        expectedContractID: fixture.attachment.contract.contractID,
        expectedGoalID: fixture.attachment.contract.goalID,
        expectedMode: fixture.attachment.contract.mode,
        expectedScenario: fixture.attachment.contract.scenario,
        expectedObjective: fixture.attachment.contract.objective,
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionHasPublishedWork)
    }
    XCTAssertEqual(
      try fixture.sessionStore.current()?.contractID,
      fixture.attachment.contract.contractID)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.attachment.contract.contractID).status,
      .planned)
  }

  func testSupersedePlannedCurrentRejectsRemoteOutboxEvidenceAndPreservesPointer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let historical = try beginHistoricalV2CurrentForMutationTest(
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      objective: "remote outbox preparation prevents silent route supersession")
    let attachment = historical.attachment
    let outboxDirectory = root
      .appendingPathComponent("remote-outbox-intents", isDirectory: true)
      .appendingPathComponent(
        TatwoLoopPathComponent.sanitize(attachment.contract.contractID),
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: outboxDirectory,
      withIntermediateDirectories: true)
    try Data("prepared".utf8).write(
      to: outboxDirectory.appendingPathComponent("job-prepared.json"),
      options: [.atomic])

    XCTAssertThrowsError(
      try sessionStore.supersedePristinePlannedCurrent(
        ownerVerification: .legacyV2(historical.owner),
        expectedContractID: attachment.contract.contractID,
        expectedGoalID: attachment.contract.goalID,
        expectedMode: attachment.contract.mode,
        expectedScenario: attachment.contract.scenario,
        expectedObjective: attachment.contract.objective,
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .currentSessionHasPublishedWork)
    }
    XCTAssertEqual(
      try sessionStore.current()?.contractID,
      attachment.contract.contractID)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(
        attachment.contract.contractID).status,
      .planned)
  }

  func testAttachCurrentRejectsUnsupportedPointerSchema() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "unsupported pointer schema",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        schema: "TatwoSessionPointerV0",
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))

    XCTAssertThrowsError(
      try sessionStore.attachCurrent(goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .unsupportedPointerSchema("TatwoSessionPointerV0"))
    }
  }

  func testAttachCurrentFailsClosedWhenPointerObjectiveDoesNotMatchStoredGoal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "canonical objective",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: "tampered objective"))

    XCTAssertThrowsError(
      try sessionStore.attachCurrent(goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .pointerGoalRunMismatch("objective"))
    }
  }

  func testAttachCurrentFailsClosedWhenCallerExpectsAnotherContract() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "caller expectation gate",
      store: goalStore)
    try sessionStore.writeRawPointerFixtureForTesting(
      TatwoSessionPointer(
        contractID: contract.contractID,
        goalID: contract.goalID,
        mode: contract.mode,
        scenario: contract.scenario,
        objective: contract.objective))

    XCTAssertThrowsError(
      try sessionStore.attachCurrent(
        expectedContractID: "contract-m-coding-different",
        goalStore: goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .callerExpectationMismatch("contractID"))
    }
  }

  private struct BeginCurrentContentionChild {
    let root: URL
    let barrier: URL
    let resultURL: URL
    let worker: String
  }

  private struct BeginCurrentContentionProcess {
    let process: Process
    let resultURL: URL
    let logURL: URL
  }

  private func beginCurrentContentionChildConfiguration()
    -> BeginCurrentContentionChild?
  {
    let environment = ProcessInfo.processInfo.environment
    guard environment["TATWO_SESSION_POINTER_CONTENTION_CHILD"] == "1",
      let root = environment["TATWO_SESSION_POINTER_CONTENTION_ROOT"],
      let barrier = environment["TATWO_SESSION_POINTER_CONTENTION_BARRIER"],
      let result = environment["TATWO_SESSION_POINTER_CONTENTION_RESULT"],
      let worker = environment["TATWO_SESSION_POINTER_CONTENTION_WORKER"]
    else {
      return nil
    }
    return BeginCurrentContentionChild(
      root: URL(fileURLWithPath: root, isDirectory: true),
      barrier: URL(fileURLWithPath: barrier, isDirectory: true),
      resultURL: URL(fileURLWithPath: result, isDirectory: false),
      worker: worker)
  }

  private func runBeginCurrentContentionChild(
    _ child: BeginCurrentContentionChild
  ) throws {
    let readyURL = child.barrier.appendingPathComponent(
      "ready-\(child.worker)",
      isDirectory: false)
    try TatwoCreateOnlyFile.write(
      Data(child.worker.utf8),
      to: readyURL,
      onDuplicate: {
        throw NSError(
          domain: "SessionPointerTests.BeginCurrentContention",
          code: 4,
          userInfo: [NSLocalizedDescriptionKey: "duplicate child ready marker"])
      })
    let goURL = child.barrier.appendingPathComponent("go", isDirectory: false)
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: goURL.path),
      Date() < deadline
    {
      Thread.sleep(forTimeInterval: 0.005)
    }
    guard FileManager.default.fileExists(atPath: goURL.path) else {
      throw NSError(
        domain: "SessionPointerTests.BeginCurrentContention",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "parent barrier release timed out"])
    }

    let sessionStore = TatwoSessionStore(directoryURL: child.root)
    let goalStore = TatwoGoalRunStore(directoryURL: child.root)
    do {
      let attachment = try sessionStore.beginCurrent(
        mode: .m,
        scenarioProfileID: "coding",
        objective: "cross-process beginCurrent contention",
        owner: .session(
          formalOwner(
            at: child.root,
            sessionID: "session-contention-owner")),
        goalStore: goalStore,
        dispatchRegistry: TatwoDispatchRegistry(
          directoryURL: child.root))
      try "success:\(attachment.contract.contractID)".write(
        to: child.resultURL,
        atomically: true,
        encoding: .utf8)
    } catch {
      try? "unexpected:\(String(reflecting: error))".write(
        to: child.resultURL,
        atomically: true,
        encoding: .utf8)
      throw error
    }
  }

  private func spawnBeginCurrentContentionChild(
    root: URL,
    barrier: URL,
    worker: Int
  ) throws -> BeginCurrentContentionProcess {
    let testBundle = Bundle(for: type(of: self))
    guard testBundle.bundlePath.hasSuffix(".xctest") else {
      throw XCTSkip("SessionPointer contention helper requires an XCTest bundle.")
    }
    let resultURL = root.appendingPathComponent(
      "result-\(worker).txt",
      isDirectory: false)
    let logURL = root.appendingPathComponent(
      "child-\(worker).log",
      isDirectory: false)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "xctest",
      "-XCTest",
      "TatwoUltraworkCoreTests.SessionPointerTests/testBeginCurrentCrossProcessContentionPublishesExactlyOneSession",
      testBundle.bundleURL.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["TMPDIR"] = root.deletingLastPathComponent().path
    environment["TATWO_SESSION_POINTER_CONTENTION_CHILD"] = "1"
    environment["TATWO_SESSION_POINTER_CONTENTION_ROOT"] = root.path
    environment["TATWO_SESSION_POINTER_CONTENTION_BARRIER"] = barrier.path
    environment["TATWO_SESSION_POINTER_CONTENTION_RESULT"] = resultURL.path
    environment["TATWO_SESSION_POINTER_CONTENTION_WORKER"] = String(worker)
    process.environment = environment
    XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
    let logHandle = try FileHandle(forWritingTo: logURL)
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()
    try logHandle.close()
    return BeginCurrentContentionProcess(
      process: process,
      resultURL: resultURL,
      logURL: logURL)
  }

  private func releaseBeginCurrentContentionBarrier(
    _ barrier: URL,
    children: [BeginCurrentContentionProcess]
  ) throws {
    let expectedReadyCount = children.count
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      let readyCount =
        ((try? FileManager.default.contentsOfDirectory(atPath: barrier.path))
          ?? [])
        .filter { $0.hasPrefix("ready-") }
        .count
      if readyCount == expectedReadyCount {
        try TatwoCreateOnlyFile.write(
          Data("go".utf8),
          to: barrier.appendingPathComponent("go", isDirectory: false),
          onDuplicate: {
            throw NSError(
              domain: "SessionPointerTests.BeginCurrentContention",
              code: 5,
              userInfo: [NSLocalizedDescriptionKey: "duplicate parent go marker"])
          })
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    let diagnostics = children.map { child in
      let log =
        (try? String(contentsOf: child.logURL, encoding: .utf8))
        ?? "<missing child log>"
      let status =
        child.process.isRunning
        ? "running"
        : "exit=\(child.process.terminationStatus)"
      return "\(status): \(log)"
    }.joined(separator: "\n---\n")
    XCTFail(
      "beginCurrent contention barrier timed out waiting for \(expectedReadyCount) children\n\(diagnostics)")
    throw NSError(
      domain: "SessionPointerTests.BeginCurrentContention",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "children did not reach contention barrier"])
  }

  private func waitForBeginCurrentContentionChildren(
    _ children: [BeginCurrentContentionProcess],
    timeout: TimeInterval
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    for child in children {
      while child.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      guard !child.process.isRunning else {
        child.process.terminate()
        XCTFail("beginCurrent contention child timed out")
        throw NSError(
          domain: "SessionPointerTests.BeginCurrentContention",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "contention child timed out"])
      }
      XCTAssertEqual(
        child.process.terminationStatus,
        0,
        "beginCurrent contention child exited nonzero")
      guard child.process.terminationStatus == 0 else {
        let outcome =
          (try? String(contentsOf: child.resultURL, encoding: .utf8))
          ?? "<missing result>"
        let log =
          (try? String(contentsOf: child.logURL, encoding: .utf8))
          ?? "<missing child log>"
        throw NSError(
          domain: "SessionPointerTests.BeginCurrentContention",
          code: Int(child.process.terminationStatus),
          userInfo: [
            NSLocalizedDescriptionKey:
              "contention child exited nonzero; outcome=\(outcome); log=\(log)"
          ])
      }
    }
  }

  private func beginCurrentContentionTemporaryBase() -> URL {
    if let configured = ProcessInfo.processInfo.environment[
      "TATWO_TEST_TMPDIR"
    ]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !configured.isEmpty
    {
      return URL(fileURLWithPath: configured, isDirectory: true)
    }

    let preferred = URL(
      fileURLWithPath: "/tmp/tatwo2-fixture/tmp",
      isDirectory: true)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(
      atPath: preferred.path,
      isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return preferred
    }
    return FileManager.default.temporaryDirectory
  }

  private func formalOwner(
    at root: URL,
    sessionID: String
  ) -> TatwoSessionOwnerExpectationV1 {
    TatwoSessionOwnerExpectationV1(
      provider: "codex",
      sessionID: sessionID,
      workspacePath: root.appendingPathComponent(
        "workspace", isDirectory: true).path)
  }

  private func initializeFormalAuthorityLocks(
    at root: URL,
    contractID: String
  ) throws {
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // The authority bootstrap, rather than the single-contract primitive,
    // handles a second contract in the same root: global artifacts validate
    // existing and only the new contract lifecycle artifacts are create-only.
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: root,
      contractID: contractID)
  }

  private func beginHistoricalV2CurrentForMutationTest(
    root: URL,
    goalStore: TatwoGoalRunStore,
    sessionStore: TatwoSessionStore,
    objective: String
  ) throws -> (
    attachment: TatwoSessionAttachmentV1,
    owner: TatwoSessionOwnerExpectationV1
  ) {
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: objective,
      store: goalStore)
    try initializeFormalAuthorityLocks(
      at: root,
      contractID: contract.contractID)
    let owner = formalOwner(
      at: root,
      sessionID: "historical-v2-\(contract.goalID)")
    let pointer = TatwoSessionPointer(
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective)
      .owned(
        provider: owner.provider,
        sessionID: owner.sessionID,
        workspacePath: owner.workspacePath)
    XCTAssertEqual(pointer.schema, "TatwoSessionPointerV2")
    try sessionStore.writeRawPointerFixtureForTesting(pointer)
    return (
      TatwoSessionAttachmentV1(
        pointer: pointer,
        contract: contract,
        goalRecord: try goalStore.requireIssuedContract(
          contract.contractID)),
      owner)
  }

  private func makeFormalV3Fixture(
    ownerKind: TatwoSessionOwnerKindV1
  ) throws -> (
    root: URL,
    goalStore: TatwoGoalRunStore,
    sessionStore: TatwoSessionStore,
    owner: TatwoCanonicalSessionOwnerV1,
    attachment: TatwoSessionAttachmentV1
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let externalID = "same-provider-id-workspace"
    let owner = TatwoCanonicalSessionOwnerV1(
      provider: "codex",
      locator: ownerKind == .thread
        ? .thread(externalID)
        : .session(externalID),
      workspacePath: root.appendingPathComponent(
        "workspace", isDirectory: true).path)
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "formal V3 owner verification fixture")
    try initializeFormalAuthorityLocks(
      at: root,
      contractID: contract.contractID)
    let attachment = try sessionStore.beginCurrent(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "formal V3 owner verification fixture",
      owner: owner,
      goalStore: goalStore,
      dispatchRegistry: TatwoDispatchRegistry(directoryURL: root))
    return (root, goalStore, sessionStore, owner, attachment)
  }

  private func makeOwnedSessionFixture(
    workspacePath: String = "/tmp/tatwo-owner/project/../project"
  ) throws -> (
    root: URL,
    goalStore: TatwoGoalRunStore,
    sessionStore: TatwoSessionStore,
    contract: TatwoWorkOSContractV1,
    sessionID: String,
    workspacePath: String
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "expected owner fixture",
      store: goalStore)
    let sessionID = "external-session-\(contract.goalID)"
    let pointer = TatwoSessionPointer(
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective)
      .owned(
        provider: "codex",
        sessionID: sessionID,
        workspacePath: workspacePath)
    try sessionStore.writeRawPointerFixtureForTesting(pointer)
    return (
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      contract: contract,
      sessionID: sessionID,
      workspacePath: URL(fileURLWithPath: workspacePath, isDirectory: true)
        .standardizedFileURL
        .path)
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

  private func goalRunJSONFiles(in root: URL) throws -> [URL] {
    let goals = root.appendingPathComponent("goals", isDirectory: true)
    guard FileManager.default.fileExists(atPath: goals.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: goals,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private enum SupersessionFault: Error {
    case injected
  }
}
