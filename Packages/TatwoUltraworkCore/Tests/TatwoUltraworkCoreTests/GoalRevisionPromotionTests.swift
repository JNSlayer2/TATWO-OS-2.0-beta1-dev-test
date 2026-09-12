import XCTest

@_spi(TatwoHumanGateApp) @testable import TatwoUltraworkCore

final class GoalRevisionPromotionTests: XCTestCase {
  private struct Verifier: TatwoHumanGateVerifying {
    func verify(
      receipt: TatwoHumanGateReceiptV1,
      subjectDigest: String,
      now: Date
    ) throws {
      guard receipt.schema == "TatwoHumanGateReceiptV1" else {
        throw TatwoHumanGateVerificationError.invalid("schema")
      }
      guard receipt.subjectDigest == subjectDigest else {
        throw TatwoHumanGateVerificationError.invalid("subject")
      }
      guard receipt.issuedAt <= now, receipt.expiresAt > now else {
        throw TatwoHumanGateVerificationError.expired
      }
    }
  }

  private struct Fixture {
    let root: URL
    let workspace: URL
    let goalStore: TatwoGoalRunStore
    let sessionStore: TatwoSessionStore
    let approvalStore: TatwoHostApprovalStore
    let old: TatwoWorkOSContractV1
    let new: TatwoWorkOSContractV1
    let authorization: TatwoHostOperationAuthorizationV1
    let now: Date
  }

  private struct TransitionFixture {
    let root: URL
    let goalStore: TatwoGoalRunStore
    let sessionStore: TatwoSessionStore
    let registry: TatwoDispatchRegistry
    let old: TatwoWorkOSContractV1
    let new: TatwoWorkOSContractV1
    let authorization: TatwoGoalRevisionPromotionAuthorizationV1
    let authorizationStore: TatwoGoalRevisionPromotionAuthorizationStore
    let humanStore: TatwoHumanGateReceiptStore
    let now: Date
  }

  private func promotedReadFixture(
    useProductionHumanGate: Bool = false,
    action: TatwoHostActionKind = .readFile,
    argumentComponents: [String] = ["allowed.txt"]
  ) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-goal-revision-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspace, withIntermediateDirectories: true)
    try Data("ok".utf8).write(
      to: workspace.appendingPathComponent("allowed.txt"))

    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let owner = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      sessionID: "revision-session",
      workspacePath: workspace.path)
    let predecessor = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "old objective")
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: root,
      contractID: predecessor.contractID)
    let oldAttachment = try sessionStore.beginCurrent(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "old objective",
      owner: .session(owner),
      goalStore: goalStore,
      dispatchRegistry: registry)
    let old = oldAttachment.contract
    _ = try goalStore.updateStatus(
      contractID: old.contractID,
      status: .running,
      authority: .revisionPromotion,
      reason: "fixture_running")
    let new = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "new objective",
      store: goalStore)
    let pointerSnapshot = try XCTUnwrap(sessionStore.snapshotCurrent())
    let oldRecord = try goalStore.requireIssuedContract(old.contractID)
    let newRecord = try goalStore.requireIssuedContract(new.contractID)
    // Keep the fixture authorization in the recent past because Host Executor
    // re-validates issuedAt against its live clock on every operation.
    let base = Date().addingTimeInterval(-10)
    let bounds = TatwoHostResourceBoundsV1(
      maxDurationSeconds: 60,
      maxOutputBytes: 512,
      maxFileCount: 1)
    let argumentDigest = TatwoHostOperationAuthorizationV1.argumentDigest(
      action: action,
      components: argumentComponents)
    let authorizationIssuer =
      useProductionHumanGate
      ? TatwoAppHumanGateAuthorizationStore.issuerDomain
      : "test.app"
    let scopeDraft = TatwoHostOperationAuthorizationV1(
      id: "host-op-draft",
      issuerDomain: authorizationIssuer,
      contractID: new.contractID,
      goalID: new.goalID,
      goalRevision: 2,
      pointerGeneration: (pointerSnapshot.pointer.generation ?? 1) + 1,
      activationEpoch: 2,
      completedTransitionReceiptID: "pending",
      humanGateReceiptID: "human-revision",
      canonicalWorkspacePath: workspace.path,
      action: action,
      argumentDigest: argumentDigest,
      outputRoots: [workspace.path],
      resourceBounds: bounds,
      issuedAt: base,
      expiresAt: base.addingTimeInterval(3_600),
      nonce: "draft-nonce",
      proofDigest: "draft-proof")
    let promotionDraft = TatwoGoalRevisionPromotionAuthorizationV1(
      id: "promotion-revision",
      issuerDomain: authorizationIssuer,
      sessionID: owner.sessionID,
      oldPointerRevisionDigest: pointerSnapshot.revision.digest,
      oldPointerGeneration: pointerSnapshot.pointer.generation ?? 1,
      oldContractID: old.contractID,
      oldGoalID: old.goalID,
      oldGoalRevision: oldRecord.resolvedRevision,
      oldObjectiveDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
          oldRecord.objective),
      newContractID: new.contractID,
      newGoalID: new.goalID,
      newGoalRevision: oldRecord.resolvedRevision + 1,
      newObjectiveDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
          newRecord.objective),
      topologyDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.topologyDigest(
          sessionID: owner.sessionID,
          oldContractID: old.contractID,
          oldGoalID: old.goalID,
          newContractID: new.contractID,
          newGoalID: new.goalID),
      capabilityDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.capabilityDigest(
          oldBindingsDigest: oldRecord.issuedIdentityBindingsDigest,
          newBindingsDigest: newRecord.issuedIdentityBindingsDigest),
      humanGateReceiptID: "human-revision",
      requestedHostScopeDigest: scopeDraft.requestedScopeDigest,
      issuedAt: base,
      expiresAt: base.addingTimeInterval(3_600),
      nonce: "promotion-nonce",
      proofDigest: "promotion-proof-000000000000000000000001")
    let promotionStore = TatwoGoalRevisionPromotionAuthorizationStore(
      directoryURL: root.appendingPathComponent(
        "goal-revision-authorizations", isDirectory: true))
    let humanStore = TatwoHumanGateReceiptStore(
      directoryURL: root.appendingPathComponent(
        "human-gate-receipts", isDirectory: true))
    let promotion: TatwoGoalRevisionPromotionAuthorizationV1
    if useProductionHumanGate {
      let humanReceipt = try TatwoAppHumanGateAuthorizationStore(
        stateDirectoryURL: root
      ).authorizeAfterHumanConfirmation(
        id: "human-revision",
        sessionID: owner.sessionID,
        oldContractID: old.contractID,
        oldGoalID: old.goalID,
        newContractID: new.contractID,
        newGoalID: new.goalID,
        subjectDigest: promotionDraft.humanGateSubjectDigest,
        issuerArtifactIdentity: issuerArtifactIdentity(),
        ttl: 3_600,
        now: base)
      promotion = try promotionStore.authorizeAfterHumanConfirmation(
        id: promotionDraft.id,
        sessionID: promotionDraft.sessionID,
        oldPointerRevisionDigest: promotionDraft.oldPointerRevisionDigest,
        oldPointerGeneration: promotionDraft.oldPointerGeneration,
        oldContractID: promotionDraft.oldContractID,
        oldGoalID: promotionDraft.oldGoalID,
        oldGoalRevision: promotionDraft.oldGoalRevision,
        oldObjectiveDigest: promotionDraft.oldObjectiveDigest,
        newContractID: promotionDraft.newContractID,
        newGoalID: promotionDraft.newGoalID,
        newGoalRevision: promotionDraft.newGoalRevision,
        newObjectiveDigest: promotionDraft.newObjectiveDigest,
        topologyDigest: promotionDraft.topologyDigest,
        capabilityDigest: promotionDraft.capabilityDigest,
        humanGateReceipt: humanReceipt,
        requestedHostScopeDigest: promotionDraft.requestedHostScopeDigest,
        ttl: 3_600,
        now: base)
    } else {
      promotion = promotionDraft
      try promotionStore.persistFixture(promotion)
      try humanStore.persistFixture(
        TatwoHumanGateReceiptV1(
          id: "human-revision",
          issuerDomain: "test.human",
          sessionID: owner.sessionID,
          oldContractID: old.contractID,
          oldGoalID: old.goalID,
          newContractID: new.contractID,
          newGoalID: new.goalID,
          subjectDigest: promotion.humanGateSubjectDigest,
          issuedAt: base,
          expiresAt: base.addingTimeInterval(3_600),
          nonce: "human-nonce",
          proofDigest: "human-proof"))
    }
    let transition = try sessionStore.transitionCurrentToPlannedRevision(
      authorizationID: promotion.id,
      now: base,
      goalStore: goalStore,
      dispatchRegistry: registry,
      authorizationStore: promotionStore,
      humanGateReceiptStore: humanStore,
      humanGateVerifier: useProductionHumanGate ? nil : Verifier())
    let issueTime = base.addingTimeInterval(1)
    let hostAuthorizationStore = TatwoHostOperationAuthorizationStore(
      directoryURL: root.appendingPathComponent(
        "host-operation-authorizations", isDirectory: true))
    let authorizationDraft = TatwoHostOperationAuthorizationV1(
      id: "host-op-read",
      issuerDomain: authorizationIssuer,
      contractID: new.contractID,
      goalID: new.goalID,
      goalRevision: 2,
      pointerGeneration: transition.pointer.generation ?? 2,
      activationEpoch: 2,
      completedTransitionReceiptID: transition.supersessionReceipt.id,
      humanGateReceiptID: "human-revision",
      canonicalWorkspacePath: workspace.path,
      action: action,
      argumentDigest: argumentDigest,
      outputRoots: [workspace.path],
      resourceBounds: bounds,
      issuedAt: issueTime,
      expiresAt: issueTime.addingTimeInterval(600),
      nonce: "host-op-nonce",
      proofDigest: useProductionHumanGate ? "" : "host-op-proof")
    let authorization: TatwoHostOperationAuthorizationV1
    if useProductionHumanGate {
      authorization = try hostAuthorizationStore
        .authorizeAfterHumanConfirmation(authorizationDraft)
    } else {
      authorization = authorizationDraft
      try hostAuthorizationStore.persistFixture(authorization)
    }
    let approvalStore = TatwoHostApprovalStore(
      directoryURL: root.appendingPathComponent(
        "approvals", isDirectory: true),
      goalRunStore: goalStore,
      hostOperationAuthorizationStore: hostAuthorizationStore,
      humanGateReceiptStore: humanStore)
    return Fixture(
      root: root,
      workspace: workspace,
      goalStore: goalStore,
      sessionStore: sessionStore,
      approvalStore: approvalStore,
      old: old,
      new: new,
      authorization: authorization,
      now: issueTime)
  }

  func testPromotedRevisionUsesExactHostOperationAuthorization() throws {
    let fixture = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertTrue(
      fixture.new.identityBindings.allSatisfy { !$0.canMutateHost })
    let lease = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      humanGateVerifier: Verifier(),
      now: fixture.now)
    let executor = TatwoHostExecutor(
      approvalStore: fixture.approvalStore,
      backupRoot: fixture.root.appendingPathComponent(
        "backups", isDirectory: true))

    let receipt = try executor.readFile(
      contractID: fixture.new.contractID,
      leaseID: lease.id,
      workspaceRoot: fixture.workspace.path,
      relativePath: "allowed.txt")

    XCTAssertTrue(receipt.ok)
    XCTAssertEqual(receipt.result, "ok")
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.old.contractID).status,
      .superseded)
  }

  func testManifestOnlySuccessorCanBePromotedWithoutDiscardingManifest() throws {
    let fixture = try transitionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifest = TatwoExecutionManifestFactory.make(
      contract: fixture.new,
      generatedAt: fixture.now)
    _ = try fixture.registry.recordManifest(manifest)

    let result = try Self.performTransition(fixture)

    XCTAssertEqual(result.predecessor.status, .superseded)
    XCTAssertEqual(result.successor.status, .running)
    XCTAssertEqual(result.pointer.contractID, fixture.new.contractID)
    let run = try XCTUnwrap(
      fixture.registry.run(forContractID: fixture.new.contractID))
    XCTAssertEqual(run.manifestEntryIDs.sorted(), manifest.entries.map(\.id).sorted())
    XCTAssertTrue(run.records.isEmpty)
  }

  func testPristinePlannedPredecessorCanBePromotedBeforeDispatch() throws {
    let fixture = try transitionFixture(activatePredecessor: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.old.contractID).status,
      .planned)

    let result = try Self.performTransition(fixture)

    XCTAssertEqual(result.predecessor.status, .superseded)
    XCTAssertEqual(result.successor.status, .running)
    XCTAssertEqual(result.pointer.contractID, fixture.new.contractID)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.old.contractID).successorContractID,
      fixture.new.contractID)
  }

  func testPublishedSuccessorRecordRejectsPromotionWithoutMutation() throws {
    let fixture = try transitionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let binding = try XCTUnwrap(fixture.new.identityBindings.first)
    _ = try fixture.registry.begin(
      contractID: fixture.new.contractID,
      goalID: fixture.new.goalID,
      bindingID: binding.id,
      sourceSlotID: binding.sourceSlotID,
      identity: binding.identity,
      modelID: binding.modelID ?? "",
      subtask: "published successor work")
    let pointerBefore = try XCTUnwrap(fixture.sessionStore.snapshotCurrent())
    let oldBefore = try fixture.goalStore.snapshot(
      forContractID: fixture.old.contractID)
    let newBefore = try fixture.goalStore.snapshot(
      forContractID: fixture.new.contractID)

    XCTAssertThrowsError(try Self.performTransition(fixture)) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .revisionPromotionNewGoalPublishedWork)
    }
    XCTAssertEqual(
      try fixture.sessionStore.snapshotCurrent(),
      pointerBefore)
    XCTAssertEqual(
      try fixture.goalStore.snapshot(forContractID: fixture.old.contractID),
      oldBefore)
    XCTAssertEqual(
      try fixture.goalStore.snapshot(forContractID: fixture.new.contractID),
      newBefore)
  }

  func testPromotionHoldsPredecessorLifecycleLockUntilSupersessionCompletes() throws {
    let fixture = try transitionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let prepared = DispatchSemaphore(value: 0)
    let releasePromotion = DispatchSemaphore(value: 0)
    let promotionDone = DispatchSemaphore(value: 0)
    let beginStarted = DispatchSemaphore(value: 0)
    let beginDone = DispatchSemaphore(value: 0)
    let promotionOutcome = AsyncOutcome()
    let beginOutcome = AsyncOutcome()
    let faultingSessionStore = TatwoSessionStore(
      directoryURL: fixture.root,
      revisionPromotionFault: { stage in
        guard stage == .prepared else { return }
        prepared.signal()
        releasePromotion.wait()
      })
    let oldBinding = try XCTUnwrap(fixture.old.identityBindings.first)

    DispatchQueue.global().async {
      do {
        _ = try Self.performTransition(
          fixture,
          sessionStore: faultingSessionStore)
        promotionOutcome.recordSuccess()
      } catch {
        promotionOutcome.record(error)
      }
      promotionDone.signal()
    }
    XCTAssertEqual(prepared.wait(timeout: .now() + 5), .success)

    DispatchQueue.global().async {
      beginStarted.signal()
      do {
        _ = try TatwoGoalRunDispatchLifecycle.begin(
          contractID: fixture.old.contractID,
          bindingID: oldBinding.id,
          sourceSlotID: oldBinding.sourceSlotID,
          identity: oldBinding.identity,
          modelID: oldBinding.modelID ?? "",
          subtask: "racing predecessor dispatch",
          helperCap: 1,
          goalStore: fixture.goalStore,
          dispatchRegistry: fixture.registry)
        beginOutcome.recordSuccess()
      } catch {
        beginOutcome.record(error)
      }
      beginDone.signal()
    }
    XCTAssertEqual(beginStarted.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(
      beginDone.wait(timeout: .now() + 0.25),
      .timedOut,
      "dispatch begin must remain blocked while promotion holds both lifecycle locks")

    releasePromotion.signal()
    XCTAssertEqual(promotionDone.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(beginDone.wait(timeout: .now() + 5), .success)
    XCTAssertNil(promotionOutcome.error)
    XCTAssertEqual(
      beginOutcome.error as? TatwoGoalRunDispatchLifecycleError,
      .staleGoalRevision(fixture.old.contractID))
    // Canonical begin publishes a planning-only execution manifest before the
    // V3 pointer. Promotion must preserve that non-executable ledger entry,
    // not delete it as though it were a dispatched run.
    let predecessorRun = try XCTUnwrap(
      fixture.registry.run(forContractID: fixture.old.contractID))
    XCTAssertNotNil(predecessorRun.executionManifest)
    XCTAssertTrue(predecessorRun.records.isEmpty)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.old.contractID).status,
      .superseded)
  }

  func testReconciliationAcceptsManifestOnlySuccessorAfterOldSupersededCrash() throws {
    let fixture = try transitionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifest = TatwoExecutionManifestFactory.make(
      contract: fixture.new,
      generatedAt: fixture.now)
    _ = try fixture.registry.recordManifest(manifest)
    let faultingSessionStore = TatwoSessionStore(
      directoryURL: fixture.root,
      revisionPromotionFault: { stage in
        if stage == .oldSuperseded {
          throw PromotionFault.injected
        }
      })

    XCTAssertThrowsError(
      try Self.performTransition(
        fixture,
        sessionStore: faultingSessionStore)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .revisionPromotionReconciliationRequired(
          TatwoGoalRevisionPromotionJournalStageV1.oldSuperseded.rawValue))
    }

    let reconciled = try fixture.sessionStore.reconcileRevisionPromotion(
      authorizationID: fixture.authorization.id,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    XCTAssertTrue(reconciled.reconciled)
    XCTAssertEqual(reconciled.predecessor.status, .superseded)
    XCTAssertEqual(reconciled.successor.status, .running)
    XCTAssertEqual(reconciled.pointer.contractID, fixture.new.contractID)
    let run = try XCTUnwrap(
      fixture.registry.run(forContractID: fixture.new.contractID))
    XCTAssertEqual(run.manifestEntryIDs.sorted(), manifest.entries.map(\.id).sorted())
    XCTAssertTrue(run.records.isEmpty)
  }

  func testConsumedAuthorizationReturnsSameFiniteLeaseUntilRevoked() throws {
    let fixture = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let first = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      humanGateVerifier: Verifier(),
      now: fixture.now)

    let consumptionURL = fixture.root
      .appendingPathComponent(
        "host-operation-authorization-consumptions", isDirectory: true)
      .appendingPathComponent("\(fixture.authorization.id).json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: consumptionURL.path))
    let consumptionBytes = try Data(contentsOf: consumptionURL)
    let retried = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      humanGateVerifier: Verifier(),
      now: fixture.now.addingTimeInterval(1))
    XCTAssertEqual(retried, first)
    XCTAssertEqual(try Data(contentsOf: consumptionURL), consumptionBytes)

    try fixture.approvalStore.revoke(id: first.id)
    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now.addingTimeInterval(2))
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalReplayRejected)
    }
  }

  func testLeasePersistenceConflictDoesNotConsumeAuthorizationAndRetryCompletes()
    throws
  {
    let fixture = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let approvalURL = fixture.approvalStore.directoryURL
      .appendingPathComponent("\(fixture.authorization.id).json")
    try FileManager.default.createDirectory(
      at: approvalURL, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalScopeMismatch)
    }
    let consumptionURL = fixture.root
      .appendingPathComponent(
        "host-operation-authorization-consumptions", isDirectory: true)
      .appendingPathComponent("\(fixture.authorization.id).json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: consumptionURL.path))

    try FileManager.default.moveItem(
      at: approvalURL,
      to: approvalURL.deletingLastPathComponent()
        .appendingPathComponent("fixture-blocker"))
    let lease = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      humanGateVerifier: Verifier(),
      now: fixture.now.addingTimeInterval(1))

    XCTAssertEqual(lease, try expectedRevisionBoundLease(fixture))
    XCTAssertTrue(FileManager.default.fileExists(atPath: consumptionURL.path))
  }

  func testPreparedRevisionBoundLeaseWithoutConsumptionCannotExecute() throws {
    let fixture = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let prepared = try expectedRevisionBoundLease(fixture)
    let approvalURL = fixture.approvalStore.directoryURL
      .appendingPathComponent("\(prepared.id).json")
    let preparedBytes = try persistJSON(prepared, to: approvalURL)

    XCTAssertThrowsError(
      try TatwoHostExecutor(
        approvalStore: fixture.approvalStore,
        backupRoot: fixture.root.appendingPathComponent(
          "backups", isDirectory: true)
      ).readFile(
        contractID: fixture.new.contractID,
        leaseID: prepared.id,
        workspaceRoot: fixture.workspace.path,
        relativePath: "allowed.txt")
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalRequired)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: hostConsumptionURL(fixture).path))
    XCTAssertEqual(try Data(contentsOf: approvalURL), preparedBytes)
  }

  func testIdenticalPreparedLeaseWithoutConsumptionBecomesIdempotent() throws {
    let fixture = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let prepared = try expectedRevisionBoundLease(fixture)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let approvalURL = fixture.approvalStore.directoryURL
      .appendingPathComponent("\(prepared.id).json")
    try FileManager.default.createDirectory(
      at: approvalURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try encoder.encode(prepared).write(to: approvalURL, options: [.atomic])
    let preparedBytes = try Data(contentsOf: approvalURL)

    let reconciled = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      humanGateVerifier: Verifier(),
      now: fixture.now.addingTimeInterval(1))

    XCTAssertEqual(reconciled, prepared)
    XCTAssertEqual(try Data(contentsOf: approvalURL), preparedBytes)
    XCTAssertEqual(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now.addingTimeInterval(2)),
      prepared)
    try fixture.approvalStore.revoke(id: prepared.id)
    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now.addingTimeInterval(3))
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalReplayRejected)
    }
  }

  func testCrashAfterAuthorizationConsumptionReturnsIdenticalLeaseIdempotently()
    throws
  {
    let fixture = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let prepared = try expectedRevisionBoundLease(fixture)
    let approvalURL = fixture.approvalStore.directoryURL
      .appendingPathComponent("\(prepared.id).json")
    let approvalBytes = try persistJSON(prepared, to: approvalURL)
    let consumption = TatwoHostOperationAuthorizationConsumptionV1(
      authorizationID: fixture.authorization.id,
      issuerDomain: fixture.authorization.issuerDomain,
      authorizationProofDigest: fixture.authorization.proofDigest,
      approvalID: prepared.id,
      consumedAt: fixture.now)
    let consumptionURL = hostConsumptionURL(fixture)
    let consumptionBytes = try persistJSON(consumption, to: consumptionURL)

    let reconciled = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      humanGateVerifier: Verifier(),
      now: fixture.now.addingTimeInterval(1))

    XCTAssertEqual(reconciled, prepared)
    XCTAssertEqual(try Data(contentsOf: approvalURL), approvalBytes)
    XCTAssertEqual(try Data(contentsOf: consumptionURL), consumptionBytes)
    let coldStore = TatwoHostApprovalStore(
      directoryURL: fixture.approvalStore.directoryURL,
      goalRunStore: fixture.goalStore,
      hostOperationAuthorizationStore:
        fixture.approvalStore.hostOperationAuthorizationStore,
      humanGateReceiptStore: fixture.approvalStore.humanGateReceiptStore)
    XCTAssertEqual(
      try coldStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now.addingTimeInterval(2)),
      prepared)
    XCTAssertEqual(try Data(contentsOf: approvalURL), approvalBytes)
    XCTAssertEqual(try Data(contentsOf: consumptionURL), consumptionBytes)
    try fixture.approvalStore.revoke(id: prepared.id)
    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now.addingTimeInterval(3))
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalReplayRejected)
    }
  }

  func testConsumedCrashReconciliationRejectsMismatchedArtifacts() throws {
    let approvalMismatch = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: approvalMismatch.root) }
    let approvalMismatchLease = try expectedRevisionBoundLease(approvalMismatch)
    _ = try persistJSON(
      approvalMismatchLease,
      to: approvalMismatch.approvalStore.directoryURL
        .appendingPathComponent("\(approvalMismatchLease.id).json"))
    _ = try persistJSON(
      TatwoHostOperationAuthorizationConsumptionV1(
        authorizationID: approvalMismatch.authorization.id,
        issuerDomain: approvalMismatch.authorization.issuerDomain,
        authorizationProofDigest: approvalMismatch.authorization.proofDigest,
        approvalID: "different-approval",
        consumedAt: approvalMismatch.now),
      to: hostConsumptionURL(approvalMismatch))
    assertHostExchangeReplayRejected(approvalMismatch)

    let authorizationMismatch = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: authorizationMismatch.root) }
    let authorizationMismatchLease =
      try expectedRevisionBoundLease(authorizationMismatch)
    _ = try persistJSON(
      authorizationMismatchLease,
      to: authorizationMismatch.approvalStore.directoryURL
        .appendingPathComponent("\(authorizationMismatchLease.id).json"))
    _ = try persistJSON(
      TatwoHostOperationAuthorizationConsumptionV1(
        authorizationID: authorizationMismatch.authorization.id,
        issuerDomain: authorizationMismatch.authorization.issuerDomain,
        authorizationProofDigest: "mismatched-authorization-proof",
        approvalID: authorizationMismatchLease.id,
        consumedAt: authorizationMismatch.now),
      to: hostConsumptionURL(authorizationMismatch))
    assertHostExchangeReplayRejected(authorizationMismatch)

    let leaseMismatch = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: leaseMismatch.root) }
    let leaseMismatchApproval = try expectedRevisionBoundLease(leaseMismatch)
    let leaseURL = leaseMismatch.approvalStore.directoryURL
      .appendingPathComponent("\(leaseMismatchApproval.id).json")
    var mismatchedLeaseBytes = try persistJSON(leaseMismatchApproval, to: leaseURL)
    mismatchedLeaseBytes.append(0x20)
    try mismatchedLeaseBytes.write(to: leaseURL, options: [.atomic])
    _ = try persistJSON(
      TatwoHostOperationAuthorizationConsumptionV1(
        authorizationID: leaseMismatch.authorization.id,
        issuerDomain: leaseMismatch.authorization.issuerDomain,
        authorizationProofDigest: leaseMismatch.authorization.proofDigest,
        approvalID: leaseMismatchApproval.id,
        consumedAt: leaseMismatch.now),
      to: hostConsumptionURL(leaseMismatch))
    XCTAssertThrowsError(
      try TatwoHostExecutor(
        approvalStore: leaseMismatch.approvalStore,
        backupRoot: leaseMismatch.root.appendingPathComponent(
          "backups", isDirectory: true)
      ).readFile(
        contractID: leaseMismatch.new.contractID,
        leaseID: leaseMismatchApproval.id,
        workspaceRoot: leaseMismatch.workspace.path,
        relativePath: "allowed.txt")
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalScopeMismatch)
    }
    assertHostExchangeReplayRejected(leaseMismatch)
  }

  func testHostOperationRebuildsHumanSubjectInsteadOfSelfComparingReceipt() throws {
    let fixture = try promotedReadFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let humanStore = fixture.approvalStore.humanGateReceiptStore
    let existing = try humanStore.require(id: "human-revision")
    try humanStore.persistFixture(
      TatwoHumanGateReceiptV1(
        id: existing.id,
        issuerDomain: existing.issuerDomain,
        sessionID: existing.sessionID,
        oldContractID: existing.oldContractID,
        oldGoalID: existing.oldGoalID,
        newContractID: existing.newContractID,
        newGoalID: existing.newGoalID,
        subjectDigest: "tampered",
        issuedAt: existing.issuedAt,
        expiresAt: existing.expiresAt,
        nonce: existing.nonce,
        proofDigest: existing.proofDigest))

    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .invalid("subject"))
    }
  }

  func testProductionHumanAuthorizationIsPersistedConsumedAndExchangedForHostLease()
    throws
  {
    let fixture = try promotedReadFixture(useProductionHumanGate: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let consumptionURL = fixture.root
      .appendingPathComponent(
        "human-gate-authority/consumptions", isDirectory: true)
      .appendingPathComponent("human-revision.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: consumptionURL.path))

    let lease = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      now: fixture.now)
    let receipt = try TatwoHostExecutor(
      approvalStore: fixture.approvalStore,
      backupRoot: fixture.root.appendingPathComponent(
        "backups", isDirectory: true)
    ).readFile(
      contractID: fixture.new.contractID,
      leaseID: lease.id,
      workspaceRoot: fixture.workspace.path,
      relativePath: "allowed.txt")

    XCTAssertEqual(receipt.result, "ok")
    XCTAssertTrue(lease.isRevisionBound)
  }

  func testProductionHostExchangeRejectsPostConsumptionHumanReceiptTampering()
    throws
  {
    let fixture = try promotedReadFixture(useProductionHumanGate: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let humanStore = fixture.approvalStore.humanGateReceiptStore
    let receipt = try humanStore.require(id: "human-revision")
    try humanStore.persistFixture(
      TatwoHumanGateReceiptV1(
        id: receipt.id,
        issuerDomain: receipt.issuerDomain,
        sessionID: receipt.sessionID,
        oldContractID: receipt.oldContractID,
        oldGoalID: receipt.oldGoalID,
        newContractID: receipt.newContractID,
        newGoalID: receipt.newGoalID,
        subjectDigest: receipt.subjectDigest,
        issuedAt: receipt.issuedAt,
        expiresAt: receipt.expiresAt,
        nonce: "post-consumption-tamper",
        proofDigest: receipt.proofDigest,
        issuerArtifactIdentity: receipt.issuerArtifactIdentity))

    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .signatureRejected)
    }
    let hostConsumptionURL = fixture.root
      .appendingPathComponent(
        "host-operation-authorization-consumptions", isDirectory: true)
      .appendingPathComponent("\(fixture.authorization.id).json")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: hostConsumptionURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.approvalStore.directoryURL
          .appendingPathComponent("\(fixture.authorization.id).json").path))
  }

  func testProductionHumanAuthorizationRejectsTamperingBeforeConsumption()
    throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-human-gate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let subject = TatwoGoalRevisionPromotionAuthorizationV1.digest(
      "revision-subject")
    let receipt = try TatwoAppHumanGateAuthorizationStore(
      stateDirectoryURL: root
    ).authorizeAfterHumanConfirmation(
      id: "human-tamper",
      sessionID: "session",
      oldContractID: "old-contract",
      oldGoalID: "old-goal",
      newContractID: "new-contract",
      newGoalID: "new-goal",
      subjectDigest: subject,
      issuerArtifactIdentity: issuerArtifactIdentity(),
      now: now)
    let tampered = TatwoHumanGateReceiptV1(
      id: receipt.id,
      issuerDomain: receipt.issuerDomain,
      sessionID: receipt.sessionID,
      oldContractID: receipt.oldContractID,
      oldGoalID: receipt.oldGoalID,
      newContractID: receipt.newContractID,
      newGoalID: receipt.newGoalID,
      subjectDigest: receipt.subjectDigest,
      issuedAt: receipt.issuedAt,
      expiresAt: receipt.expiresAt,
      nonce: "tampered-nonce",
      proofDigest: receipt.proofDigest,
      issuerArtifactIdentity: receipt.issuerArtifactIdentity)

    XCTAssertThrowsError(
      try TatwoProductionHumanGateVerifier(
        stateDirectoryURL: root
      ).verify(
        receipt: tampered,
        subjectDigest: subject,
        now: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .signatureRejected)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          "human-gate-authority/consumptions/human-tamper.json").path))
  }

  func testProductionHumanAuthorizationRetryReturnsExistingByteIdenticalReceipt()
    throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-human-retry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoAppHumanGateAuthorizationStore(stateDirectoryURL: root)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let subject = TatwoGoalRevisionPromotionAuthorizationV1.digest(
      "retry-subject")

    let first = try store.authorizeAfterHumanConfirmation(
      id: "human-retry",
      sessionID: "session",
      oldContractID: "old-contract",
      oldGoalID: "old-goal",
      newContractID: "new-contract",
      newGoalID: "new-goal",
      subjectDigest: subject,
      issuerArtifactIdentity: issuerArtifactIdentity(),
      now: now)
    let receiptURL = root.appendingPathComponent(
      "human-gate-receipts/human-retry.json")
    let firstBytes = try Data(contentsOf: receiptURL)
    let retried = try store.authorizeAfterHumanConfirmation(
      id: "human-retry",
      sessionID: "session",
      oldContractID: "old-contract",
      oldGoalID: "old-goal",
      newContractID: "new-contract",
      newGoalID: "new-goal",
      subjectDigest: subject,
      issuerArtifactIdentity: issuerArtifactIdentity(),
      now: now.addingTimeInterval(30))

    XCTAssertEqual(retried, first)
    XCTAssertEqual(try Data(contentsOf: receiptURL), firstBytes)
  }

  func testProductionHumanAuthorizationRetryRejectsSameIDScopeMismatch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-human-retry-mismatch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TatwoAppHumanGateAuthorizationStore(stateDirectoryURL: root)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try store.authorizeAfterHumanConfirmation(
      id: "human-retry",
      sessionID: "session",
      oldContractID: "old-contract",
      oldGoalID: "old-goal",
      newContractID: "new-contract",
      newGoalID: "new-goal",
      subjectDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.digest("scope-a"),
      issuerArtifactIdentity: issuerArtifactIdentity(),
      now: now)

    XCTAssertThrowsError(
      try store.authorizeAfterHumanConfirmation(
        id: "human-retry",
        sessionID: "session",
        oldContractID: "old-contract",
        oldGoalID: "old-goal",
        newContractID: "new-contract",
        newGoalID: "new-goal",
        subjectDigest:
          TatwoGoalRevisionPromotionAuthorizationV1.digest("scope-b"),
        issuerArtifactIdentity: issuerArtifactIdentity(),
        now: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .consumptionConflict)
    }
  }

  func testProductionHostOperationAuthorizationRejectsForgedProofAndUnsignedJSON()
    throws
  {
    let forged = try promotedReadFixture(useProductionHumanGate: true)
    defer { try? FileManager.default.removeItem(at: forged.root) }
    try forged.approvalStore.hostOperationAuthorizationStore.persistFixture(
      copyHostAuthorization(
        forged.authorization,
        proofDigest:
          "ed25519:\(Data(repeating: 0xA5, count: 64).base64EncodedString())"))
    XCTAssertThrowsError(
      try forged.approvalStore.issueHostOperationBound(
        authorizationID: forged.authorization.id,
        sessionStore: forged.sessionStore,
        now: forged.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalScopeMismatch)
    }

    let unsigned = try promotedReadFixture(useProductionHumanGate: true)
    defer { try? FileManager.default.removeItem(at: unsigned.root) }
    try unsigned.approvalStore.hostOperationAuthorizationStore.persistFixture(
      copyHostAuthorization(
        unsigned.authorization,
        proofDigest: "hand-written-json"))
    XCTAssertThrowsError(
      try unsigned.approvalStore.issueHostOperationBound(
        authorizationID: unsigned.authorization.id,
        sessionStore: unsigned.sessionStore,
        now: unsigned.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalScopeMismatch)
    }
  }

  func testProductionHostOperationAuthorizationSignatureBindsIssuerDomain()
    throws
  {
    let fixture = try promotedReadFixture(useProductionHumanGate: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.approvalStore.hostOperationAuthorizationStore.persistFixture(
      copyHostAuthorization(
        fixture.authorization,
        issuerDomain: "other.app"))

    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalScopeMismatch)
    }
  }

  func testProductionPromotionAppIssuerIsCreateOnlyAndIdempotent() throws {
    let fixture = try promotionIssuerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let first = try issuePromotion(fixture)
    let firstBytes = try Data(contentsOf: fixture.authorizationURL)
    let second = try issuePromotion(fixture)

    XCTAssertEqual(first, second)
    XCTAssertEqual(firstBytes, try Data(contentsOf: fixture.authorizationURL))
    XCTAssertEqual(
      first.issuerDomain,
      TatwoAppHumanGateAuthorizationStore.issuerDomain)
    XCTAssertEqual(first.humanGateReceiptID, fixture.humanReceipt.id)
    XCTAssertEqual(first.humanGateSubjectDigest, fixture.humanReceipt.subjectDigest)
    XCTAssertEqual(
      try fixture.store.require(id: first.id, now: fixture.now),
      first)
  }

  func testProductionPromotionAppIssuerRejectsExistingIDConflict() throws {
    let fixture = try promotionIssuerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try issuePromotion(fixture)
    var bytes = try Data(contentsOf: fixture.authorizationURL)
    bytes.append(0x20)
    try bytes.write(to: fixture.authorizationURL)

    XCTAssertThrowsError(try issuePromotion(fixture)) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionPromotionAuthorizationError,
        .conflict)
    }
  }

  func testProductionPromotionAppIssuerRejectsTamperedHumanReceipt() throws {
    let fixture = try promotionIssuerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipt = fixture.humanReceipt
    let tampered = TatwoHumanGateReceiptV1(
      id: receipt.id,
      issuerDomain: receipt.issuerDomain,
      sessionID: receipt.sessionID,
      oldContractID: receipt.oldContractID,
      oldGoalID: receipt.oldGoalID,
      newContractID: receipt.newContractID,
      newGoalID: receipt.newGoalID,
      subjectDigest: receipt.subjectDigest,
      issuedAt: receipt.issuedAt,
      expiresAt: receipt.expiresAt,
      nonce: "tampered-nonce",
      proofDigest: receipt.proofDigest,
      issuerArtifactIdentity: receipt.issuerArtifactIdentity)

    XCTAssertThrowsError(
      try issuePromotion(fixture, humanGateReceipt: tampered)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionPromotionAuthorizationError,
        .scopeMismatch("human_gate_receipt_bytes"))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.authorizationURL.path))
  }

  func testProductionPromotionStoreRejectsTamperedAuthorizationAndWrongDomain()
    throws
  {
    let tamperedFixture = try promotionIssuerFixture()
    defer { try? FileManager.default.removeItem(at: tamperedFixture.root) }
    let issued = try issuePromotion(tamperedFixture)
    try tamperedFixture.store.persistFixture(
      copyAuthorization(
        issued,
        requestedHostScopeDigest:
          TatwoGoalRevisionPromotionAuthorizationV1.digest("tampered-scope")))
    XCTAssertThrowsError(
      try tamperedFixture.store.require(id: issued.id, now: tamperedFixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionPromotionAuthorizationError,
        .invalid)
    }

    let wrongDomainFixture = try promotionIssuerFixture()
    defer { try? FileManager.default.removeItem(at: wrongDomainFixture.root) }
    let wrongDomainIssued = try issuePromotion(wrongDomainFixture)
    try wrongDomainFixture.store.persistFixture(
      copyAuthorization(wrongDomainIssued, issuerDomain: "other.app"))
    XCTAssertThrowsError(
      try wrongDomainFixture.store.require(
        id: wrongDomainIssued.id,
        now: wrongDomainFixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionPromotionAuthorizationError,
        .invalid)
    }
  }

  func testProductionPromotionAppIssuerRejectsExpiredAndWrongDomainReceipts()
    throws
  {
    let expired = try promotionIssuerFixture(
      humanIssuedAt: Date(timeIntervalSince1970: 1_799_996_000))
    defer { try? FileManager.default.removeItem(at: expired.root) }
    XCTAssertThrowsError(try issuePromotion(expired)) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionPromotionAuthorizationError,
        .expired)
    }

    let wrongDomain = try promotionIssuerFixture()
    defer { try? FileManager.default.removeItem(at: wrongDomain.root) }
    let receipt = wrongDomain.humanReceipt
    let testReceipt = TatwoHumanGateReceiptV1(
      id: receipt.id,
      issuerDomain: "test.app",
      sessionID: receipt.sessionID,
      oldContractID: receipt.oldContractID,
      oldGoalID: receipt.oldGoalID,
      newContractID: receipt.newContractID,
      newGoalID: receipt.newGoalID,
      subjectDigest: receipt.subjectDigest,
      issuedAt: receipt.issuedAt,
      expiresAt: receipt.expiresAt,
      nonce: receipt.nonce,
      proofDigest: receipt.proofDigest,
      issuerArtifactIdentity: receipt.issuerArtifactIdentity)
    XCTAssertThrowsError(
      try issuePromotion(wrongDomain, humanGateReceipt: testReceipt)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionPromotionAuthorizationError,
        .scopeMismatch("human_gate_receipt"))
    }
  }

  #if os(macOS)
  func testProductionRevisionBoundComputerAuthorizationReachesComputerHost()
    throws
  {
    let appName = "Tatwo-Intentional-Missing-\(UUID().uuidString)"
    let fixture = try promotedReadFixture(
      useProductionHumanGate: true,
      action: .computerUse,
      argumentComponents: [TatwoComputerActionKind.openApp.rawValue, appName])
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let lease = try fixture.approvalStore.issueHostOperationBound(
      authorizationID: fixture.authorization.id,
      sessionStore: fixture.sessionStore,
      now: fixture.now)
    let receipt = try TatwoComputerHost(
      approvalStore: fixture.approvalStore
    ).execute(
      contractID: fixture.new.contractID,
      leaseID: lease.id,
      workspaceRoot: fixture.workspace.path,
      action: .openApp,
      value: appName)

    XCTAssertEqual(receipt.action, .openApp)
    XCTAssertFalse(receipt.ok)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.approvalStore.directoryURL
          .appendingPathComponent("\(lease.id).json").path))
  }
  #endif

  private enum PromotionFault: Error {
    case injected
  }

  private final class AsyncOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
      lock.lock()
      defer { lock.unlock() }
      return storedError
    }

    func recordSuccess() {
      lock.lock()
      storedError = nil
      lock.unlock()
    }

    func record(_ error: Error) {
      lock.lock()
      storedError = error
      lock.unlock()
    }
  }

  private func transitionFixture(
    activatePredecessor: Bool = true
  ) throws -> TransitionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-goal-transition-\(UUID().uuidString)", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspace, withIntermediateDirectories: true)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let owner = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      sessionID: "revision-transition-session",
      workspacePath: workspace.path)
    let predecessor = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "old transition objective")
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: root,
      contractID: predecessor.contractID)
    let oldAttachment = try sessionStore.beginCurrent(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "old transition objective",
      owner: .session(owner),
      goalStore: goalStore,
      dispatchRegistry: registry)
    let old = oldAttachment.contract
    if activatePredecessor {
      _ = try goalStore.updateStatus(
        contractID: old.contractID,
        status: .running,
        authority: .revisionPromotion,
        reason: "fixture_running")
    }
    let new = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "new transition objective",
      store: goalStore)
    let pointerSnapshot = try XCTUnwrap(sessionStore.snapshotCurrent())
    let oldRecord = try goalStore.requireIssuedContract(old.contractID)
    let newRecord = try goalStore.requireIssuedContract(new.contractID)
    let now = Date(timeIntervalSince1970: 1_775_000_000)
    let authorization = TatwoGoalRevisionPromotionAuthorizationV1(
      id: "promotion-transition",
      issuerDomain: "test.app",
      sessionID: owner.sessionID,
      oldPointerRevisionDigest: pointerSnapshot.revision.digest,
      oldPointerGeneration: pointerSnapshot.pointer.generation ?? 1,
      oldContractID: old.contractID,
      oldGoalID: old.goalID,
      oldGoalRevision: oldRecord.resolvedRevision,
      oldObjectiveDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
          oldRecord.objective),
      newContractID: new.contractID,
      newGoalID: new.goalID,
      newGoalRevision: oldRecord.resolvedRevision + 1,
      newObjectiveDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
          newRecord.objective),
      topologyDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.topologyDigest(
          sessionID: owner.sessionID,
          oldContractID: old.contractID,
          oldGoalID: old.goalID,
          newContractID: new.contractID,
          newGoalID: new.goalID),
      capabilityDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.capabilityDigest(
          oldBindingsDigest: oldRecord.issuedIdentityBindingsDigest,
          newBindingsDigest: newRecord.issuedIdentityBindingsDigest),
      humanGateReceiptID: "human-transition",
      requestedHostScopeDigest: "scope-transition",
      issuedAt: now,
      expiresAt: now.addingTimeInterval(3_600),
      nonce: "promotion-transition-nonce",
      proofDigest: "promotion-transition-proof-000000000001")
    let authorizationStore = TatwoGoalRevisionPromotionAuthorizationStore(
      directoryURL: root.appendingPathComponent(
        "goal-revision-authorizations", isDirectory: true))
    let humanStore = TatwoHumanGateReceiptStore(
      directoryURL: root.appendingPathComponent(
        "human-gate-receipts", isDirectory: true))
    try authorizationStore.persistFixture(authorization)
    try humanStore.persistFixture(
      TatwoHumanGateReceiptV1(
        id: authorization.humanGateReceiptID,
        issuerDomain: "test.human",
        sessionID: owner.sessionID,
        oldContractID: old.contractID,
        oldGoalID: old.goalID,
        newContractID: new.contractID,
        newGoalID: new.goalID,
        subjectDigest: authorization.humanGateSubjectDigest,
        issuedAt: now,
        expiresAt: now.addingTimeInterval(3_600),
        nonce: "human-transition-nonce",
        proofDigest: "human-transition-proof"))
    return TransitionFixture(
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      registry: registry,
      old: old,
      new: new,
      authorization: authorization,
      authorizationStore: authorizationStore,
      humanStore: humanStore,
      now: now)
  }

  private static func performTransition(
    _ fixture: TransitionFixture,
    sessionStore: TatwoSessionStore? = nil
  ) throws -> TatwoGoalRevisionPromotionResultV1 {
    try (sessionStore ?? fixture.sessionStore)
      .transitionCurrentToPlannedRevision(
        authorizationID: fixture.authorization.id,
        now: fixture.now,
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry,
        authorizationStore: fixture.authorizationStore,
        humanGateReceiptStore: fixture.humanStore,
        humanGateVerifier: Verifier())
  }

  private func issuerArtifactIdentity()
    -> TatwoHumanGateIssuerArtifactIdentityV1
  {
    TatwoHumanGateIssuerArtifactIdentityV1(
      bundleIdentifier: "com.tatwo.ultrawork",
      teamIdentifier: "TESTTEAM",
      codeDirectoryHash: "fixture-cdhash",
      executableSHA256: String(repeating: "a", count: 64))
  }

  private struct PromotionIssuerFixture {
    let root: URL
    let store: TatwoGoalRevisionPromotionAuthorizationStore
    let draft: TatwoGoalRevisionPromotionAuthorizationV1
    let humanReceipt: TatwoHumanGateReceiptV1
    let now: Date

    var authorizationURL: URL {
      store.directoryURL.appendingPathComponent("\(draft.id).json")
    }
  }

  private func promotionIssuerFixture(
    humanIssuedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
  ) throws -> PromotionIssuerFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-promotion-app-\(UUID().uuidString)", isDirectory: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let digest: (String) -> String = {
      TatwoGoalRevisionPromotionAuthorizationV1.digest($0)
    }
    let draft = TatwoGoalRevisionPromotionAuthorizationV1(
      id: "promotion-app",
      issuerDomain: TatwoAppHumanGateAuthorizationStore.issuerDomain,
      sessionID: "session-app",
      oldPointerRevisionDigest: digest("pointer"),
      oldPointerGeneration: 4,
      oldContractID: "old-contract",
      oldGoalID: "old-goal",
      oldGoalRevision: 7,
      oldObjectiveDigest: digest("old-objective"),
      newContractID: "new-contract",
      newGoalID: "new-goal",
      newGoalRevision: 8,
      newObjectiveDigest: digest("new-objective"),
      topologyDigest: digest("topology"),
      capabilityDigest: digest("capability"),
      humanGateReceiptID: "human-app",
      requestedHostScopeDigest: digest("host-scope"),
      issuedAt: humanIssuedAt,
      expiresAt: humanIssuedAt.addingTimeInterval(600),
      nonce: "draft",
      proofDigest: "draft")
    let humanReceipt = try TatwoAppHumanGateAuthorizationStore(
      stateDirectoryURL: root
    ).authorizeAfterHumanConfirmation(
      id: draft.humanGateReceiptID,
      sessionID: draft.sessionID,
      oldContractID: draft.oldContractID,
      oldGoalID: draft.oldGoalID,
      newContractID: draft.newContractID,
      newGoalID: draft.newGoalID,
      subjectDigest: draft.humanGateSubjectDigest,
      issuerArtifactIdentity: issuerArtifactIdentity(),
      ttl: 600,
      now: humanIssuedAt)
    return PromotionIssuerFixture(
      root: root,
      store: TatwoGoalRevisionPromotionAuthorizationStore(
        directoryURL: root.appendingPathComponent(
          "goal-revision-authorizations", isDirectory: true)),
      draft: draft,
      humanReceipt: humanReceipt,
      now: now)
  }

  private func issuePromotion(
    _ fixture: PromotionIssuerFixture,
    humanGateReceipt: TatwoHumanGateReceiptV1? = nil
  ) throws -> TatwoGoalRevisionPromotionAuthorizationV1 {
    let draft = fixture.draft
    return try fixture.store.authorizeAfterHumanConfirmation(
      id: draft.id,
      sessionID: draft.sessionID,
      oldPointerRevisionDigest: draft.oldPointerRevisionDigest,
      oldPointerGeneration: draft.oldPointerGeneration,
      oldContractID: draft.oldContractID,
      oldGoalID: draft.oldGoalID,
      oldGoalRevision: draft.oldGoalRevision,
      oldObjectiveDigest: draft.oldObjectiveDigest,
      newContractID: draft.newContractID,
      newGoalID: draft.newGoalID,
      newGoalRevision: draft.newGoalRevision,
      newObjectiveDigest: draft.newObjectiveDigest,
      topologyDigest: draft.topologyDigest,
      capabilityDigest: draft.capabilityDigest,
      humanGateReceipt: humanGateReceipt ?? fixture.humanReceipt,
      requestedHostScopeDigest: draft.requestedHostScopeDigest,
      ttl: 600,
      now: fixture.now)
  }

  private func copyAuthorization(
    _ value: TatwoGoalRevisionPromotionAuthorizationV1,
    issuerDomain: String? = nil,
    requestedHostScopeDigest: String? = nil
  ) -> TatwoGoalRevisionPromotionAuthorizationV1 {
    TatwoGoalRevisionPromotionAuthorizationV1(
      schema: value.schema,
      id: value.id,
      issuerDomain: issuerDomain ?? value.issuerDomain,
      sessionID: value.sessionID,
      oldPointerRevisionDigest: value.oldPointerRevisionDigest,
      oldPointerGeneration: value.oldPointerGeneration,
      oldContractID: value.oldContractID,
      oldGoalID: value.oldGoalID,
      oldGoalRevision: value.oldGoalRevision,
      oldObjectiveDigest: value.oldObjectiveDigest,
      newContractID: value.newContractID,
      newGoalID: value.newGoalID,
      newGoalRevision: value.newGoalRevision,
      newObjectiveDigest: value.newObjectiveDigest,
      topologyDigest: value.topologyDigest,
      capabilityDigest: value.capabilityDigest,
      humanGateReceiptID: value.humanGateReceiptID,
      requestedHostScopeDigest:
        requestedHostScopeDigest ?? value.requestedHostScopeDigest,
      issuedAt: value.issuedAt,
      expiresAt: value.expiresAt,
      nonce: value.nonce,
      proofDigest: value.proofDigest)
  }

  private func copyHostAuthorization(
    _ value: TatwoHostOperationAuthorizationV1,
    issuerDomain: String? = nil,
    proofDigest: String? = nil
  ) -> TatwoHostOperationAuthorizationV1 {
    TatwoHostOperationAuthorizationV1(
      schema: value.schema,
      id: value.id,
      issuerDomain: issuerDomain ?? value.issuerDomain,
      contractID: value.contractID,
      goalID: value.goalID,
      goalRevision: value.goalRevision,
      pointerGeneration: value.pointerGeneration,
      activationEpoch: value.activationEpoch,
      completedTransitionReceiptID: value.completedTransitionReceiptID,
      humanGateReceiptID: value.humanGateReceiptID,
      canonicalWorkspacePath: value.canonicalWorkspacePath,
      action: value.action,
      argumentDigest: value.argumentDigest,
      outputRoots: value.outputRoots,
      resourceBounds: value.resourceBounds,
      issuedAt: value.issuedAt,
      expiresAt: value.expiresAt,
      nonce: value.nonce,
      proofDigest: proofDigest ?? value.proofDigest)
  }

  private func expectedRevisionBoundLease(
    _ fixture: Fixture
  ) throws -> TatwoHostApprovalLeaseV1 {
    let authorization = try fixture.approvalStore
      .hostOperationAuthorizationStore.require(
        id: fixture.authorization.id,
        now: fixture.now)
    return TatwoHostApprovalLeaseV1(
      id: authorization.id,
      contractID: authorization.contractID,
      workspaceRoot: authorization.canonicalWorkspacePath,
      allowedActions: [authorization.action],
      issuedAt: authorization.issuedAt,
      expiresAt: authorization.expiresAt,
      goalID: authorization.goalID,
      goalRevision: authorization.goalRevision,
      humanGateReceiptID: authorization.humanGateReceiptID,
      hostOperationAuthorizationID: authorization.id,
      pointerGeneration: authorization.pointerGeneration,
      activationEpoch: authorization.activationEpoch,
      completedTransitionReceiptID: authorization.completedTransitionReceiptID,
      canonicalWorkspaceDigest: authorization.canonicalWorkspaceDigest,
      argumentDigest: authorization.argumentDigest,
      outputRoots: authorization.outputRoots,
      resourceBounds: authorization.resourceBounds)
  }

  private func hostConsumptionURL(_ fixture: Fixture) -> URL {
    fixture.root
      .appendingPathComponent(
        "host-operation-authorization-consumptions", isDirectory: true)
      .appendingPathComponent("\(fixture.authorization.id).json")
  }

  @discardableResult
  private func persistJSON<Value: Encodable>(
    _ value: Value,
    to url: URL
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(value)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try encoded.write(to: url, options: [.atomic])
    return encoded
  }

  private func assertHostExchangeReplayRejected(
    _ fixture: Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try fixture.approvalStore.issueHostOperationBound(
        authorizationID: fixture.authorization.id,
        sessionStore: fixture.sessionStore,
        humanGateVerifier: Verifier(),
        now: fixture.now.addingTimeInterval(1)),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? TatwoHostExecutorError,
        .approvalReplayRejected,
        file: file,
        line: line)
    }
  }
}
