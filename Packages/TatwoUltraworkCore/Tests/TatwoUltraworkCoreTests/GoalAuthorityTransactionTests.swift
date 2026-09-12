import XCTest

@testable import TatwoUltraworkCore

final class GoalAuthorityTransactionTests: XCTestCase {
  func testForeignOwnerPointerHandsOffWithoutMutatingOldAuthorityArtifacts()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldContract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "old thread authority remains durable")
    try bootstrapAuthorityLocks(
      root: root,
      contractID: oldContract.contractID)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let oldOwner = makeOwner(root: root, suffix: "old-thread")
    let oldResult = try TatwoGoalAuthorityTransaction(
      sessionStore: sessionStore,
      goalStore: goalStore,
      dispatchRegistry: registry
    ).begin(
      contract: oldContract,
      owner: oldOwner,
      now: Date(timeIntervalSince1970: 900),
      stopAfterStageForTesting: nil)
    let oldGoalURL = try goalStore.fileURL(
      forContractID: oldContract.contractID)
    let oldDispatchURL = try registry.fileURL(
      forContractID: oldContract.contractID)
    let oldGoalBytes = try Data(contentsOf: oldGoalURL)
    let oldDispatchBytes = try Data(contentsOf: oldDispatchURL)

    let newContract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "new thread atomically takes current pointer")
    try bootstrapAuthorityLocks(
      root: root,
      contractID: newContract.contractID)
    let newOwner = makeOwner(root: root, suffix: "new-thread")
    let result = try TatwoGoalAuthorityTransaction(
      sessionStore: sessionStore,
      goalStore: goalStore,
      dispatchRegistry: registry
    ).begin(
      contract: newContract,
      owner: newOwner,
      now: Date(timeIntervalSince1970: 1_000),
      stopAfterStageForTesting: nil)

    XCTAssertEqual(
      result.pointerHandoffFromSessionID,
      oldOwner.externalProviderID)
    XCTAssertEqual(
      try sessionStore.authorityPointerData(),
      try canonicalData(result.attachment.pointer))
    XCTAssertEqual(try sessionStore.current(), result.attachment.pointer)
    XCTAssertEqual(try Data(contentsOf: oldGoalURL), oldGoalBytes)
    XCTAssertEqual(try Data(contentsOf: oldDispatchURL), oldDispatchBytes)
    XCTAssertEqual(
      try goalStore.requireIssuedContract(oldContract.contractID)
        .contractID,
      oldResult.attachment.pointer.contractID)
  }

  func testSameOwnerResidualPointerStillFailsPristinePreflight()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstContract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "same owner first authority")
    try bootstrapAuthorityLocks(
      root: root,
      contractID: firstContract.contractID)
    let owner = makeOwner(root: root, suffix: "same-owner")
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    _ = try TatwoGoalAuthorityTransaction(
      sessionStore: sessionStore,
      goalStore: goalStore,
      dispatchRegistry: registry
    ).begin(
      contract: firstContract,
      owner: owner,
      now: Date(timeIntervalSince1970: 1_100),
      stopAfterStageForTesting: nil)

    let secondContract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "same owner residual must fail")
    try bootstrapAuthorityLocks(
      root: root,
      contractID: secondContract.contractID)
    XCTAssertThrowsError(
      try TatwoGoalAuthorityTransaction(
        sessionStore: sessionStore,
        goalStore: goalStore,
        dispatchRegistry: registry
      ).begin(
        contract: secondContract,
        owner: owner,
        now: Date(timeIntervalSince1970: 1_200),
        stopAfterStageForTesting: nil)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .preexistingAuthorityArtifact("current-session"))
    }
  }

  func testCorruptPointerStillFailsClosedBeforeAuthorityMaterialization()
    throws
  {
    let fixture = try makeFixture(
      objective: "corrupt pointer remains fail closed")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data(#"{"schema":"broken""#.utf8).write(
      to: fixture.sessionStore.authorityPointerFileURL,
      options: [.atomic])

    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 1_300),
        stopAfterStageForTesting: nil)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .artifactCorrupt("current-session"))
    }
    XCTAssertNil(
      try fixture.goalStore.record(
        forContractID: fixture.contract.contractID))
    XCTAssertNil(
      try fixture.registry.run(
        forContractID: fixture.contract.contractID))
  }

  func testRestartAfterManifestUsesPersistedIntentWhenClockAdvances()
    throws
  {
    let fixture = try makeFixture(
      objective: "resume one prepared Goal authority transaction")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 1_000),
        stopAfterStageForTesting: .manifestMaterialized)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .interruptedAfterStage("manifest_materialized"))
    }
    XCTAssertNil(try fixture.sessionStore.current())
    XCTAssertNotNil(
      try fixture.goalStore.record(
        forContractID: fixture.contract.contractID))
    XCTAssertNotNil(
      try fixture.registry.requireExecutionManifest(
        contractID: fixture.contract.contractID))

    let restarted = TatwoGoalAuthorityTransaction(
      sessionStore: TatwoSessionStore(directoryURL: fixture.root),
      goalStore: TatwoGoalRunStore(directoryURL: fixture.root),
      dispatchRegistry: TatwoDispatchRegistry(
        directoryURL: fixture.root))
    let result = try restarted.begin(
      contract: fixture.contract,
      owner: fixture.owner,
      now: Date(timeIntervalSince1970: 2_000),
      stopAfterStageForTesting: nil)

    XCTAssertTrue(result.recovered)
    XCTAssertEqual(
      result.attachment.pointer.schema,
      "TatwoSessionAuthorityPointerV3")
    XCTAssertEqual(
      result.attachment.pointer.authorityTransactionID,
      result.transactionID)
    XCTAssertEqual(
      result.attachment.pointer.authorityPlanSHA256,
      result.authorityPlanSHA256)
    XCTAssertEqual(
      result.attachment.pointer.executionManifestSHA256,
      result.manifestSHA256)
    XCTAssertEqual(
      result.manifest.generatedAt,
      Date(timeIntervalSince1970: 1_000))
  }

  func testTruncatedIntentCreatesAddressBoundQuarantine()
    throws
  {
    let fixture = try makeFixture(
      objective: "quarantine a truncated durable intent")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 2_100),
        stopAfterStageForTesting: .goalMaterialized))

    let transactionDirectory = try authorityTransactionDirectory(
      root: fixture.root)
    let intentURL = transactionDirectory
      .appendingPathComponent("00-intent.json", isDirectory: false)
    try Data(#"{"schema":"TatwoGoalAuthorityIntentV1""#.utf8)
      .write(to: intentURL, options: [.atomic])

    for attempt in 0..<2 {
      XCTAssertThrowsError(
        try fixture.transaction.begin(
          contract: fixture.contract,
          owner: fixture.owner,
          now: Date(
            timeIntervalSince1970: 2_200 + Double(attempt)),
          stopAfterStageForTesting: nil)
      ) { error in
        XCTAssertEqual(
          error as? TatwoGoalAuthorityTransactionError,
          .quarantined("intent_corrupt_or_partial"))
      }
    }
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: transactionDirectory
          .appendingPathComponent(
            "90-quarantined.json",
            isDirectory: false)
          .path))
  }

  func testForeignPointerAfterPreparedStateQuarantinesInsteadOfAdopting()
    throws
  {
    let fixture = try makeFixture(
      objective: "quarantine foreign pointer during restart")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 3_000),
        stopAfterStageForTesting: .manifestMaterialized))

    let foreign = TatwoSessionPointer(
      contractID: "contract-m-coding-foreign000001",
      goalID: "goal-m-coding-foreign000001",
      mode: .m,
      scenario: "coding",
      objective: "foreign current session")
    try fixture.sessionStore.writeRawPointerFixtureForTesting(foreign)

    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 4_000),
        stopAfterStageForTesting: nil)
    ) { error in
      guard let transactionError =
        error as? TatwoGoalAuthorityTransactionError
      else {
        return XCTFail("expected transaction error, got \(error)")
      }
      guard case .quarantined(
        "foreign_or_mismatched_current_pointer"
      ) = transactionError else {
        return XCTFail("expected quarantine, got \(error)")
      }
    }
    XCTAssertEqual(try fixture.sessionStore.current(), foreign)
  }

  func testRestartAfterGoalStatusTamperQuarantinesBeforePointerPublication()
    throws
  {
    let fixture = try makeFixture(
      objective: "quarantine a status-mutated prepared Goal")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 5_000),
        stopAfterStageForTesting: .goalMaterialized))

    let goalURL = fixture.root
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent(
        "\(fixture.contract.contractID).json",
        isDirectory: false)
    var tampered = try fixture.goalStore.requireIssuedContract(
      fixture.contract.contractID)
    tampered.status = .blocked
    tampered.statusReason = "foreign_writer_after_intent"
    try canonicalData(tampered).write(
      to: goalURL,
      options: [.atomic])

    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 5_100),
        stopAfterStageForTesting: nil)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .quarantined("goal_exact_cas_mismatch"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.sessionStore.authorityPointerFileURL.path))
  }

  func testRestartAfterGoalReceiptTamperQuarantinesBeforePointerPublication()
    throws
  {
    let fixture = try makeFixture(
      objective: "quarantine a receipt-mutated prepared Goal")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 6_000),
        stopAfterStageForTesting: .goalMaterialized))

    let goalURL = fixture.root
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent(
        "\(fixture.contract.contractID).json",
        isDirectory: false)
    var tampered = try fixture.goalStore.requireIssuedContract(
      fixture.contract.contractID)
    tampered.receipts.append(
      TatwoStoredReceipt(
        receiptID: "foreign-receipt",
        kind: "foreign_writer",
        submittedAt: Date(timeIntervalSince1970: 6_050)))
    try canonicalData(tampered).write(
      to: goalURL,
      options: [.atomic])

    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 6_100),
        stopAfterStageForTesting: nil)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .quarantined("goal_exact_cas_mismatch"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.sessionStore.authorityPointerFileURL.path))
  }

  func testRestartAfterManifestTamperCreatesQuarantine()
    throws
  {
    let fixture = try makeFixture(
      objective: "quarantine a tampered materialized manifest")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 7_000),
        stopAfterStageForTesting: .manifestMaterialized))

    let dispatchURL = try fixture.registry.fileURL(
      forContractID: fixture.contract.contractID)
    var run = try XCTUnwrap(
      fixture.registry.run(
        forContractID: fixture.contract.contractID))
    run.executionManifestSHA256 =
      "sha256:" + String(repeating: "a", count: 64)
    try canonicalData(run).write(
      to: dispatchURL,
      options: [.atomic])

    XCTAssertThrowsError(
      try fixture.transaction.begin(
        contract: fixture.contract,
        owner: fixture.owner,
        now: Date(timeIntervalSince1970: 7_100),
        stopAfterStageForTesting: nil)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalAuthorityTransactionError,
        .quarantined(
          "execution_manifest_materialization_failed"))
    }
  }

  func testCurrentRejectsShapeValidV3WithoutDurableAuthorityArtifacts()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let contractID = "contract-xxl-coding-fakeauthority01"
    let goalID = "goal-xxl-coding-fakeauthority01"
    let pointer = TatwoSessionPointer(
      schema: "TatwoSessionAuthorityPointerV3",
      contractID: contractID,
      goalID: goalID,
      mode: .xxl,
      scenario: "coding",
      objective: "shape-valid pointer is not durable authority",
      ownerBinding: TatwoSessionOwnerBindingV1(
        provider: "codex",
        sessionID: "thread-fake-authority",
        workspacePath: root.path,
        contractID: contractID,
        goalID: goalID),
      generation: 1,
      authorityTransactionID:
        "goal-authority-" + String(repeating: "a", count: 40),
      authorityPlanSHA256:
        "sha256:" + String(repeating: "b", count: 64),
      executionManifestSHA256:
        "sha256:" + String(repeating: "c", count: 64))
    try sessionStore.writeRawPointerFixtureForTesting(pointer)

    XCTAssertThrowsError(try sessionStore.current()) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .pointerGoalRunMismatch("v3_authority_artifacts"))
    }
  }

  func testCurrentRejectsV3WhenBoundManifestIsTampered()
    throws
  {
    let fixture = try makeFixture(
      objective: "reject current pointer after manifest tamper")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.transaction.begin(
      contract: fixture.contract,
      owner: fixture.owner,
      now: Date(timeIntervalSince1970: 8_000),
      stopAfterStageForTesting: nil)
    XCTAssertNotNil(try fixture.sessionStore.current())

    let dispatchURL = try fixture.registry.fileURL(
      forContractID: fixture.contract.contractID)
    var run = try XCTUnwrap(
      fixture.registry.run(
        forContractID: fixture.contract.contractID))
    run.executionManifestSHA256 =
      "sha256:" + String(repeating: "d", count: 64)
    try canonicalData(run).write(
      to: dispatchURL,
      options: [.atomic])

    XCTAssertThrowsError(
      try fixture.sessionStore.current()
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .pointerGoalRunMismatch("v3_authority_artifacts"))
    }
  }

  func testCurrentRejectsV3WhenBoundGoalIsMissing()
    throws
  {
    let fixture = try makeFixture(
      objective: "reject current pointer after Goal removal")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.transaction.begin(
      contract: fixture.contract,
      owner: fixture.owner,
      now: Date(timeIntervalSince1970: 8_100),
      stopAfterStageForTesting: nil)
    let goalURL = fixture.root
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent(
        "\(fixture.contract.contractID).json",
        isDirectory: false)
    try FileManager.default.removeItem(at: goalURL)

    XCTAssertThrowsError(
      try fixture.sessionStore.current()
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .pointerGoalRunMismatch("v3_authority_artifacts"))
    }
  }

  func testCurrentRejectsV3WhenBoundGoalIdentityIsTampered()
    throws
  {
    let fixture = try makeFixture(
      objective: "reject current pointer after Goal identity tamper")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.transaction.begin(
      contract: fixture.contract,
      owner: fixture.owner,
      now: Date(timeIntervalSince1970: 8_200),
      stopAfterStageForTesting: nil)
    let goalURL = fixture.root
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent(
        "\(fixture.contract.contractID).json",
        isDirectory: false)
    let original = try fixture.goalStore.requireIssuedContract(
      fixture.contract.contractID)
    let tampered = TatwoStoredGoalRun(
      goalID: "goal-xxl-coding-identitytamper01",
      contractID: original.contractID,
      mode: original.mode,
      scenario: original.scenario,
      objective: original.objective,
      routeBindingOverride: original.routeBindingOverride,
      issuedIdentityBindings: original.issuedIdentityBindings,
      issuedIdentityBindingsDigest:
        original.issuedIdentityBindingsDigest,
      status: original.status,
      statusReason: original.statusReason,
      issuedAt: original.issuedAt,
      updatedAt: original.updatedAt,
      receipts: original.receipts)
    try canonicalData(tampered).write(
      to: goalURL,
      options: [.atomic])

    XCTAssertThrowsError(
      try fixture.sessionStore.current()
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .pointerGoalRunMismatch("v3_authority_artifacts"))
    }
  }

  func testCurrentAllowsMutableGoalStatusAndReceiptsAfterPointerCommit()
    throws
  {
    let fixture = try makeFixture(
      objective: "allow legitimate Goal lifecycle mutation")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = try fixture.transaction.begin(
      contract: fixture.contract,
      owner: fixture.owner,
      now: Date(timeIntervalSince1970: 8_300),
      stopAfterStageForTesting: nil)
    let goalURL = fixture.root
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent(
        "\(fixture.contract.contractID).json",
        isDirectory: false)
    var mutated = try fixture.goalStore.requireIssuedContract(
      fixture.contract.contractID)
    mutated.status = .blocked
    mutated.statusReason = "waiting_for_bounded_integration"
    mutated.updatedAt = Date(timeIntervalSince1970: 8_350)
    mutated.receipts.append(
      TatwoStoredReceipt(
        receiptID: "mutable-lifecycle-receipt",
        kind: "test",
        submittedAt: Date(timeIntervalSince1970: 8_350)))
    try canonicalData(mutated).write(
      to: goalURL,
      options: [.atomic])

    XCTAssertEqual(
      try fixture.sessionStore.current(),
      result.attachment.pointer)
  }

  func testAuthorityResolverRequiresExactCanonicalOwnerKindWithoutMutation()
    throws
  {
    let fixture = try makeFixture(
      objective: "reject colliding owner kind before authority projection")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = try fixture.transaction.begin(
      contract: fixture.contract,
      owner: fixture.owner,
      now: Date(timeIntervalSince1970: 8_400),
      stopAfterStageForTesting: nil)
    let exact = try fixture.sessionStore.resolveAuthorityCurrent(
      pointer: result.attachment.pointer,
      ownerVerification: .canonicalV3(fixture.owner),
      scenarioBook: TatwoScenarioConfigDefaults.book,
      goalStore: fixture.goalStore)
    XCTAssertEqual(exact, result.attachment)

    let pointerBytes = try XCTUnwrap(
      fixture.sessionStore.authorityPointerData())
    let goalURL = try fixture.goalStore.fileURL(
      forContractID: fixture.contract.contractID)
    let goalBytes = try Data(contentsOf: goalURL)
    let collidingOwner = TatwoCanonicalSessionOwnerV1(
      provider: fixture.owner.provider,
      locator: fixture.owner.ownerKind == .thread
        ? .session(fixture.owner.externalProviderID)
        : .thread(fixture.owner.externalProviderID),
      workspacePath: fixture.owner.workspacePath)

    XCTAssertThrowsError(
      try fixture.sessionStore.resolveAuthorityCurrent(
        pointer: result.attachment.pointer,
        ownerVerification: .canonicalV3(collidingOwner),
        scenarioBook: TatwoScenarioConfigDefaults.book,
        goalStore: fixture.goalStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAttachmentError,
        .ownerExpectationMismatch("ownerKind"))
    }
    XCTAssertEqual(
      try fixture.sessionStore.authorityPointerData(),
      pointerBytes)
    XCTAssertEqual(try Data(contentsOf: goalURL), goalBytes)
  }

  func testDetachedStoreAndRegistryBeginPersistsWithoutPointer()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)

    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "preserve detached CLI begin compatibility",
      store: store,
      registry: registry)

    XCTAssertNotNil(
      try store.record(forContractID: contract.contractID))
    let manifest = try registry.requireExecutionManifest(
      contractID: contract.contractID)
    XCTAssertEqual(manifest.contractID, contract.contractID)
    XCTAssertEqual(manifest.goalID, contract.goalID)
    XCTAssertNil(
      try TatwoSessionStore(directoryURL: root).current())
  }

  func testOwnerBoundBeginRequiresPreinitializedLifecycleLock()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "require explicit authority lock bootstrap")
    let transaction = TatwoGoalAuthorityTransaction(
      sessionStore: TatwoSessionStore(directoryURL: root),
      goalStore: TatwoGoalRunStore(directoryURL: root),
      dispatchRegistry: TatwoDispatchRegistry(
        directoryURL: root))

    XCTAssertThrowsError(
      try transaction.begin(
        contract: contract,
        owner: makeOwner(root: root, suffix: "no-lock-bootstrap"))
    ) { error in
      guard case TatwoGoalStoreLifecycleLockError
        .artifactMissing(let path) = error
      else {
        return XCTFail(
          "expected typed lifecycle bootstrap precondition, got \(error)")
      }
      XCTAssertTrue(path.hasSuffix("dispatch-lifecycle"))
    }
  }

  func testFormalWorkOSBeginPersistsFullManifestAndV3Pointer()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = makeOwner(root: root, suffix: "formal-workos")
    let projected = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "formal begin is one durable authority transaction")
    try bootstrapAuthorityLocks(
      root: root,
      contractID: projected.contractID)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)

    let attachment = try WorkOSFactory.beginCanonical(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: "formal begin is one durable authority transaction",
      store: goalStore,
      registry: registry,
      sessionStore: sessionStore,
      owner: owner)
    let contract = attachment.contract

    let pointer = try XCTUnwrap(sessionStore.current())
    XCTAssertEqual(pointer.schema, "TatwoSessionAuthorityPointerV3")
    XCTAssertEqual(pointer.contractID, contract.contractID)
    let run = try XCTUnwrap(
      registry.run(forContractID: contract.contractID))
    XCTAssertEqual(run.schema, "TatwoStoredDispatchRunV2")
    let manifest = try XCTUnwrap(run.executionManifest)
    XCTAssertEqual(manifest.contractID, contract.contractID)
    XCTAssertEqual(manifest.goalID, contract.goalID)
    XCTAssertEqual(
      run.executionManifestSHA256,
      try manifest.canonicalSHA256())
    XCTAssertEqual(
      run.manifestEntryIDs,
      manifest.entries.map(\.id))
    XCTAssertEqual(
      try goalStore.requireIssuedIdentityBindings(
        contractID: contract.contractID),
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(
        for: contract))
  }

  func testExplicitAuthorityBootstrapCreatesThenFreshlyValidates()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "explicit bootstrap readback")

    let created =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: contract.contractID,
        createdAt: Date(timeIntervalSince1970: 200))
    let readback =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: contract.contractID,
        createdAt: Date(timeIntervalSince1970: 201))

    XCTAssertEqual(created.disposition, .created)
    XCTAssertEqual(readback.disposition, .validatedExisting)
    XCTAssertEqual(
      created.globalInitializationReceiptSHA256,
      readback.globalInitializationReceiptSHA256)
    XCTAssertEqual(
      created.lifecycleInitializationReceiptSHA256,
      readback.lifecycleInitializationReceiptSHA256)
  }

  func testExplicitAuthorityBootstrapAddsSecondContractLifecycleWithoutRecreatingGlobal()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstContract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "first contract owns the initial global bootstrap")
    let secondContract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
      objective: "second contract must add only its own lifecycle")

    let first =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: firstContract.contractID,
        createdAt: Date(timeIntervalSince1970: 300))
    let globalReceiptURL =
      TatwoGoalStoreGlobalLock.initializationReceiptURL(
        forGoalStoreRoot: root)
    let globalReceiptBefore = try Data(contentsOf: globalReceiptURL)

    let second =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: secondContract.contractID,
        createdAt: Date(timeIntervalSince1970: 301))
    let secondReadback =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: secondContract.contractID,
        createdAt: Date(timeIntervalSince1970: 302))

    XCTAssertEqual(first.disposition, .created)
    XCTAssertEqual(second.disposition, .createdContractLifecycle)
    XCTAssertEqual(secondReadback.disposition, .validatedExisting)
    XCTAssertEqual(try Data(contentsOf: globalReceiptURL), globalReceiptBefore)
    XCTAssertEqual(
      second.globalInitializationReceiptSHA256,
      first.globalInitializationReceiptSHA256)
    XCTAssertEqual(
      second.lifecycleInitializationReceiptSHA256,
      secondReadback.lifecycleInitializationReceiptSHA256)
    XCTAssertNotEqual(
      first.lifecycleInitializationReceiptSHA256,
      second.lifecycleInitializationReceiptSHA256)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          try TatwoGoalStoreLifecycleLock.lockURL(
            forGoalStoreRoot: root,
            contractID: firstContract.contractID).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          try TatwoGoalStoreLifecycleLock.lockURL(
            forGoalStoreRoot: root,
            contractID: secondContract.contractID).path))
  }

  func testExplicitAuthorityBootstrapMigratesLegacyLifecycleDirectoryWithoutGlobalLocks()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID:
        TatwoScenarioConfigDefaults.exactXXLSolOpusLunaGrokScenarioID,
      objective:
        "migrate an upgraded App state root that already has the legacy lifecycle directory")
    let lifecycleDirectory =
      TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
        forGoalStoreRoot: root)
    try FileManager.default.createDirectory(
      at: lifecycleDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let legacyArtifact = lifecycleDirectory.appendingPathComponent(
      "contract-legacy-preserved.state.lock",
      isDirectory: false)
    let legacyBytes = Data("legacy-lock-must-survive".utf8)
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: legacyArtifact.path,
        contents: legacyBytes,
        attributes: [.posixPermissions: 0o600]))

    let preflight =
      try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
        goalStoreRoot: root,
        contractID: contract.contractID)
    XCTAssertEqual(
      preflight.presentArtifactNames,
      [TatwoGoalStoreLifecycleLock.lifecycleDirectoryName])

    let migrated =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: contract.contractID,
        expectedPreflight: preflight,
        createdAt: Date(timeIntervalSince1970: 350))
    let readback =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: contract.contractID,
        createdAt: Date(timeIntervalSince1970: 351))

    XCTAssertEqual(
      migrated.disposition,
      .createdGlobalAndContractLifecycle)
    XCTAssertEqual(readback.disposition, .validatedExisting)
    XCTAssertEqual(try Data(contentsOf: legacyArtifact), legacyBytes)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          TatwoGoalStoreGlobalLock.lockURL(
            forGoalStoreRoot: root).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          TatwoGoalStoreGlobalLock.initializationReceiptURL(
            forGoalStoreRoot: root).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          try TatwoGoalStoreLifecycleLock.lockURL(
            forGoalStoreRoot: root,
            contractID: contract.contractID).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          try TatwoGoalStoreLifecycleLock.initializationReceiptURL(
            forGoalStoreRoot: root,
            contractID: contract.contractID).path))
  }

  func testExplicitAuthorityBootstrapUsesCanonicalSymlinkRoot()
    throws
  {
    let realRoot = try makeRoot()
    defer { try? FileManager.default.removeItem(at: realRoot) }
    let linkRoot = realRoot.deletingLastPathComponent()
      .appendingPathComponent(
        "tatwo-goal-authority-link-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: linkRoot) }
    try FileManager.default.createSymbolicLink(
      at: linkRoot,
      withDestinationURL: realRoot)
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "canonical symlinked authority root")

    let preflight =
      try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
        goalStoreRoot: linkRoot,
        contractID: contract.contractID)
    let result =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: linkRoot,
        contractID: contract.contractID,
        expectedPreflight: preflight)
    let readback =
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: realRoot,
        contractID: contract.contractID)

    XCTAssertEqual(
      preflight.canonicalGoalStoreRootPath,
      realRoot.resolvingSymlinksInPath().standardizedFileURL.path)
    XCTAssertEqual(
      result.canonicalGoalStoreRootPath,
      readback.canonicalGoalStoreRootPath)
    XCTAssertEqual(readback.disposition, .validatedExisting)
  }

  func testExplicitAuthorityBootstrapPreflightsLifecyclePartialBeforeGlobalCreate()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "partial lifecycle must block all creation")
    let lifecycleDirectory =
      TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
        forGoalStoreRoot: root)
    try FileManager.default.createDirectory(
      at: lifecycleDirectory,
      withIntermediateDirectories: false)
    let lifecycleLock =
      try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root,
        contractID: contract.contractID)
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: lifecycleLock.path,
        contents: Data()))

    XCTAssertThrowsError(
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: contract.contractID))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath:
          TatwoGoalStoreGlobalLock.lockURL(
            forGoalStoreRoot: root).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath:
          TatwoGoalStoreGlobalLock.initializationReceiptURL(
            forGoalStoreRoot: root).path))
  }

  func testExplicitAuthorityBootstrapRejectsStaleAbsentConfirmationAfterAnotherBootstrap()
    throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let contract = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "stale confirmation must not become existing success")
    let stale =
      try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
        goalStoreRoot: root,
        contractID: contract.contractID)
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: root,
      contractID: contract.contractID)

    XCTAssertThrowsError(
      try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
        goalStoreRoot: root,
        contractID: contract.contractID,
        expectedPreflight: stale)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionAuthorityLockBootstrapError,
        .preflightChanged)
    }
  }

  private struct Fixture {
    let root: URL
    let contract: TatwoWorkOSContractV1
    let owner: TatwoCanonicalSessionOwnerV1
    let goalStore: TatwoGoalRunStore
    let sessionStore: TatwoSessionStore
    let registry: TatwoDispatchRegistry
    let transaction: TatwoGoalAuthorityTransaction
  }

  private func makeFixture(objective: String) throws -> Fixture {
    let root = try makeRoot()
    let contract = try WorkOSFactory.projectContract(
      mode: .xxl,
      scenarioProfileID: "coding",
      objective: objective)
    try bootstrapAuthorityLocks(
      root: root,
      contractID: contract.contractID)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    return Fixture(
      root: root,
      contract: contract,
      owner: makeOwner(root: root, suffix: objective),
      goalStore: goalStore,
      sessionStore: sessionStore,
      registry: registry,
      transaction: TatwoGoalAuthorityTransaction(
        sessionStore: sessionStore,
        goalStore: goalStore,
        dispatchRegistry: registry))
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "tatwo-goal-authority-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    return root
  }

  private func authorityTransactionDirectory(
    root: URL
  ) throws -> URL {
    let parent = root.appendingPathComponent(
      "goal-authority-transactions",
      isDirectory: true)
    let children = try FileManager.default.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: [.isDirectoryKey])
      .filter {
        (try? $0.resourceValues(
          forKeys: [.isDirectoryKey]).isDirectory) == true
      }
    return try XCTUnwrap(children.first)
  }

  private func makeOwner(
    root: URL,
    suffix: String
  ) -> TatwoCanonicalSessionOwnerV1 {
    TatwoCanonicalSessionOwnerV1(
      provider: "codex",
      locator: .thread(
        "thread-\(TatwoLoopPathComponent.sanitize(suffix))"),
      workspacePath: root.appendingPathComponent(
        "workspace", isDirectory: true).path)
  }

  private func bootstrapAuthorityLocks(
    root: URL,
    contractID: String
  ) throws {
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: root,
      contractID: contractID,
      createdAt: Date(timeIntervalSince1970: 100))
  }

  private func canonicalData<T: Encodable>(
    _ value: T
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
}
