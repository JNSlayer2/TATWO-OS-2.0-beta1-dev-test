import CryptoKit
import Darwin
import XCTest

@_spi(TatwoBootstrapRecoveryHost) @testable import TatwoUltraworkCore

final class GoalRevisionBootstrapRecoveryTests: XCTestCase {
  private struct FixtureTrustAnchor:
    TatwoBootstrapRecoveryTrustAnchorProviding
  {
    let rawRepresentation: Data

    func trustedPublicKeyRawRepresentation() throws -> Data {
      rawRepresentation
    }
  }

  private struct Fixture {
    let root: URL
    let goalStore: TatwoGoalRunStore
    let sessionStore: TatwoSessionStore
    let registry: TatwoDispatchRegistry
    let old: TatwoWorkOSContractV1
    let new: TatwoWorkOSContractV1
    let oldRecord: TatwoStoredGoalRun
    let pointer: TatwoSessionPointerSnapshotV1
    let hostKey: Curve25519.Signing.PrivateKey
    let now: Date
    let evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1

    var trustAnchor: FixtureTrustAnchor {
      FixtureTrustAnchor(
        rawRepresentation: hostKey.publicKey.rawRepresentation)
    }

    var verifier: TatwoProductionHumanGateVerifier {
      TatwoProductionHumanGateVerifier(
        stateDirectoryURL: root,
        bootstrapRecoveryTrustAnchorProvider: trustAnchor)
    }

    var issuer: TatwoGoalRevisionBootstrapRecoveryIssuer {
      TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: root,
        trustAnchorProvider: trustAnchor)
    }
  }

  func testHostSignedRecoveryTransitionsOnceAndColdReadsExactSuccessor()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let issuer = fixture.issuer
    let receipt = try signedReceipt(fixture, issuer: issuer)
    let promotionStore = TatwoGoalRevisionPromotionAuthorizationStore(
      directoryURL: fixture.root.appendingPathComponent(
        "goal-revision-authorizations", isDirectory: true))
    let promotion = try promotionStore.authorizeAfterBootstrapRecovery(
      id: "bootstrap-promotion",
      humanGateReceipt: receipt,
      now: fixture.now,
      trustAnchorProvider: fixture.trustAnchor)
    let beforeReceiptIDs = fixture.oldRecord.receipts

    let first = try fixture.sessionStore.transitionCurrentToPlannedRevision(
      authorizationID: promotion.id,
      now: fixture.now,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry,
      authorizationStore: promotionStore,
      humanGateVerifier: fixture.verifier)

    XCTAssertFalse(first.reconciled)
    XCTAssertEqual(first.predecessor.status, .superseded)
    XCTAssertEqual(first.predecessor.receipts, beforeReceiptIDs)
    XCTAssertEqual(first.successor.status, .running)
    XCTAssertEqual(first.pointer.contractID, fixture.new.contractID)
    XCTAssertEqual(first.pointer.goalID, fixture.new.goalID)
    XCTAssertEqual(
      first.pointer.generation,
      (fixture.pointer.pointer.generation ?? 1) + 1)
    XCTAssertEqual(
      first.supersessionReceipt.promotionIssuerDomain,
      TatwoGoalRevisionBootstrapRecoveryIssuer.issuerDomain)
    XCTAssertEqual(
      first.supersessionReceipt.oldReceiptsDigest,
      fixture.evidence.oldReceiptsDigest)
    XCTAssertEqual(
      first.supersessionReceipt.bootstrapRecoveryContextDigest,
      fixture.evidence.authorityContextDigest)

    let consumptionURL = fixture.root
      .appendingPathComponent(
        "human-gate-authority/consumptions", isDirectory: true)
      .appendingPathComponent("\(receipt.id).json")
    let firstConsumptionBytes = try Data(contentsOf: consumptionURL)
    let retry = try fixture.sessionStore.transitionCurrentToPlannedRevision(
      authorizationID: promotion.id,
      now: fixture.now.addingTimeInterval(1),
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry,
      authorizationStore: promotionStore)
    XCTAssertTrue(retry.reconciled)
    XCTAssertEqual(retry.pointer, first.pointer)
    XCTAssertEqual(
      try Data(contentsOf: consumptionURL),
      firstConsumptionBytes)

    let cold = try fixture.sessionStore.inspectCurrent(
      expectedContractID: fixture.new.contractID,
      expectedGoalID: fixture.new.goalID,
      expectedMode: fixture.new.mode,
      expectedScenario: fixture.new.scenario,
      expectedObjective: fixture.new.objective,
      goalStore: fixture.goalStore)
    XCTAssertEqual(cold?.goalRecord.status, .running)
    XCTAssertEqual(
      cold?.goalRecord.predecessorContractID,
      fixture.old.contractID)
  }

  func testRootOwnedGrantTransitionsOnceAndColdReadsExactSuccessor()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installation = try installRootGrant(fixture)
    let issuer = TatwoGoalRevisionBootstrapRecoveryIssuer(
      stateDirectoryURL: fixture.root,
      trustAnchorProvider: installation.provider)
    let receipt = try issuer.acceptRootOwnedGrantEvidence(
      installation.plan.evidence,
      now: fixture.now)
    XCTAssertEqual(
      receipt.proofDigest,
      "root-grant:\(installation.plan.grantFileDigest)")

    let promotionStore = TatwoGoalRevisionPromotionAuthorizationStore(
      directoryURL: fixture.root.appendingPathComponent(
        "goal-revision-authorizations", isDirectory: true))
    let promotion = try promotionStore.authorizeAfterBootstrapRecovery(
      id: installation.plan.evidence.authorizationID,
      humanGateReceipt: receipt,
      now: fixture.now,
      trustAnchorProvider: installation.provider)
    let beforeReceiptIDs = fixture.oldRecord.receipts
    let first = try fixture.sessionStore.transitionCurrentToPlannedRevision(
      authorizationID: promotion.id,
      now: fixture.now,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry,
      authorizationStore: promotionStore,
      humanGateVerifier: TatwoProductionHumanGateVerifier(
        stateDirectoryURL: fixture.root,
        bootstrapRecoveryTrustAnchorProvider: installation.provider))

    XCTAssertFalse(first.reconciled)
    XCTAssertEqual(first.predecessor.status, .superseded)
    XCTAssertEqual(first.predecessor.receipts, beforeReceiptIDs)
    XCTAssertEqual(first.successor.status, .running)
    XCTAssertEqual(first.pointer.contractID, fixture.new.contractID)
    XCTAssertEqual(
      first.pointer.generation,
      (fixture.pointer.pointer.generation ?? 1) + 1)

    let coldSessionStore = TatwoSessionStore(directoryURL: fixture.root)
    let coldGoalStore = TatwoGoalRunStore(directoryURL: fixture.root)
    let cold = try coldSessionStore.inspectCurrent(
      expectedContractID: fixture.new.contractID,
      expectedGoalID: fixture.new.goalID,
      expectedMode: fixture.new.mode,
      expectedScenario: fixture.new.scenario,
      expectedObjective: fixture.new.objective,
      goalStore: coldGoalStore)
    XCTAssertEqual(cold?.goalRecord.status, .running)
    XCTAssertEqual(
      cold?.goalRecord.predecessorContractID,
      fixture.old.contractID)
    let consumptionURL = fixture.root
      .appendingPathComponent(
        "human-gate-authority/consumptions", isDirectory: true)
      .appendingPathComponent("\(receipt.id).json")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: consumptionURL.path))
  }

  func testRootOwnedGrantRejectsWrongOwnerWritableParentAndSymlinkParent()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let wrongOwner = try installRootGrant(
      fixture,
      expectedOwnerUID: 0,
      expectedGroupID: 0)
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: fixture.root,
        trustAnchorProvider: wrongOwner.provider
      ).acceptRootOwnedGrantEvidence(
        wrongOwner.plan.evidence,
        now: fixture.now)
    )

    let writable = try installRootGrant(fixture)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777],
      ofItemAtPath: writable.grantDirectoryURL
        .deletingLastPathComponent().path)
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: fixture.root,
        trustAnchorProvider: writable.provider
      ).acceptRootOwnedGrantEvidence(
        writable.plan.evidence,
        now: fixture.now)
    )

    let symlinked = try installRootGrant(fixture)
    let realDirectory = symlinked.grantDirectoryURL
      .deletingLastPathComponent()
      .appendingPathComponent("v1-real", isDirectory: true)
    try FileManager.default.moveItem(
      at: symlinked.grantDirectoryURL,
      to: realDirectory)
    try FileManager.default.createSymbolicLink(
      at: symlinked.grantDirectoryURL,
      withDestinationURL: realDirectory)
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: fixture.root,
        trustAnchorProvider: symlinked.provider
      ).acceptRootOwnedGrantEvidence(
        symlinked.plan.evidence,
        now: fixture.now)
    )
  }

  func testRootOwnedGrantRejectsLeafSymlinkHardLinkAndNoncanonicalBytes()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let leafSymlink = try installRootGrant(fixture)
    let realLeaf = leafSymlink.grantDirectoryURL
      .appendingPathComponent("real.grant")
    try FileManager.default.moveItem(
      at: leafSymlink.grantURL,
      to: realLeaf)
    try FileManager.default.createSymbolicLink(
      at: leafSymlink.grantURL,
      withDestinationURL: realLeaf)
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: fixture.root,
        trustAnchorProvider: leafSymlink.provider
      ).acceptRootOwnedGrantEvidence(
        leafSymlink.plan.evidence,
        now: fixture.now)
    )

    let hardLinked = try installRootGrant(fixture)
    let secondLink = hardLinked.grantDirectoryURL
      .appendingPathComponent("second-link.grant")
    try FileManager.default.linkItem(
      at: hardLinked.grantURL,
      to: secondLink)
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: fixture.root,
        trustAnchorProvider: hardLinked.provider
      ).acceptRootOwnedGrantEvidence(
        hardLinked.plan.evidence,
        now: fixture.now)
    )

    let noncanonical = try installRootGrant(fixture)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: noncanonical.grantURL.path)
    let handle = try FileHandle(forWritingTo: noncanonical.grantURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: noncanonical.grantURL.path)
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryIssuer(
        stateDirectoryURL: fixture.root,
        trustAnchorProvider: noncanonical.provider
      ).acceptRootOwnedGrantEvidence(
        noncanonical.plan.evidence,
        now: fixture.now)
    )
  }

  func testRootOwnedGrantBindsReceiptIDAndRejectsGrantScopedReplay()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installation = try installRootGrant(fixture)
    let issuer = TatwoGoalRevisionBootstrapRecoveryIssuer(
      stateDirectoryURL: fixture.root,
      trustAnchorProvider: installation.provider)
    let receipt = try issuer.acceptRootOwnedGrantEvidence(
      installation.plan.evidence,
      now: fixture.now)
    let receiptBytes = try Data(
      contentsOf: issuer.receiptStore.url(for: receipt.id))
    let replay = copyEvidence(
      installation.plan.evidence,
      id: "bootstrap-human-replay")

    XCTAssertThrowsError(
      try issuer.acceptRootOwnedGrantEvidence(
        replay,
        now: fixture.now)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: issuer.receiptStore.url(for: replay.id).path))
    XCTAssertEqual(
      try Data(contentsOf: issuer.receiptStore.url(for: receipt.id)),
      receiptBytes)
  }

  func testCanonicalLiveStateChallengeFactoryBuildsReadOnlyExactGrant()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pointerBefore = try fixture.sessionStore.snapshotCurrent()
    let oldBefore = try fixture.goalStore.snapshot(
      forContractID: fixture.old.contractID)
    let newBefore = try fixture.goalStore.snapshot(
      forContractID: fixture.new.contractID)

    let plan =
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: challengeInput(fixture),
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(plan.evidence.oldContractID, fixture.old.contractID)
    XCTAssertEqual(plan.evidence.oldGoalID, fixture.old.goalID)
    XCTAssertEqual(plan.evidence.newContractID, fixture.new.contractID)
    XCTAssertEqual(plan.evidence.newGoalID, fixture.new.goalID)
    XCTAssertEqual(
      plan.evidence.oldPointerRevisionDigest,
      fixture.pointer.revision.digest)
    XCTAssertEqual(
      plan.evidence.oldReceiptsDigest,
      TatwoGoalRevisionPromotionAuthorizationV1.receiptsDigest(
        fixture.oldRecord.receipts))
    XCTAssertEqual(plan.evidence.shortCode.count, 8)
    XCTAssertTrue(plan.grant.body.matches(plan.evidence))
    XCTAssertEqual(
      try TatwoGoalRevisionRootOwnedRecoveryGrantV1.decodeCanonical(
        plan.canonicalGrantBytes),
      plan.grant)
    XCTAssertEqual(
      try fixture.sessionStore.snapshotCurrent(),
      pointerBefore)
    XCTAssertEqual(
      try fixture.goalStore.snapshot(
        forContractID: fixture.old.contractID),
      oldBefore)
    XCTAssertEqual(
      try fixture.goalStore.snapshot(
        forContractID: fixture.new.contractID),
      newBefore)
  }

  func testCanonicalLiveStateChallengeFactoryRejectsSuccessorRegistryArtifact()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.registry.begin(
      contractID: fixture.new.contractID,
      goalID: fixture.new.goalID,
      bindingID: "published-successor",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "fixture",
      subtask: "must block revision promotion",
      now: fixture.now)

    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: challengeInput(fixture),
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry)
    ) { error in
      XCTAssertEqual(
        error as?
          TatwoGoalRevisionBootstrapRecoveryChallengeError,
        .successorNotPristine("dispatch_registry"))
    }
  }

  func testCanonicalLiveStateChallengeFactoryAllowsExactManifestOnlySuccessor()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifest = TatwoExecutionManifestFactory.make(
      contract: fixture.new,
      generatedAt: fixture.now)
    let stored = try fixture.registry.recordManifest(manifest)

    let plan =
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: challengeInput(fixture),
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry)

    XCTAssertEqual(plan.evidence.newContractID, fixture.new.contractID)
    XCTAssertEqual(stored.manifestEntryIDs, manifest.entries.map(\.id))
    XCTAssertTrue(stored.records.isEmpty)
    XCTAssertEqual(stored.activeCycleEpoch, 1)
    let readback = try XCTUnwrap(
      fixture.registry.run(forContractID: fixture.new.contractID))
    XCTAssertEqual(readback.schema, stored.schema)
    XCTAssertEqual(readback.contractID, stored.contractID)
    XCTAssertEqual(readback.manifestEntryIDs, stored.manifestEntryIDs)
    XCTAssertEqual(readback.records, stored.records)
    XCTAssertEqual(readback.activeCycleEpoch, stored.activeCycleEpoch)
    XCTAssertEqual(readback.cycleSeals, stored.cycleSeals)
  }

  func testCanonicalLiveStateChallengeFactoryRejectsMismatchedManifestIDs()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifest = TatwoExecutionManifestFactory.make(
      contract: fixture.new,
      generatedAt: fixture.now)
    var stored = try fixture.registry.recordManifest(manifest)
    stored.manifestEntryIDs = ["dispatch-plan-not-an-issued-binding"]
    try writeDispatchRun(stored, registry: fixture.registry)

    try assertChallengeRejectsSuccessorRegistry(fixture)
  }

  func testCanonicalLiveStateChallengeFactoryRejectsUnknownRegistrySchema()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifest = TatwoExecutionManifestFactory.make(
      contract: fixture.new,
      generatedAt: fixture.now)
    let stored = try fixture.registry.recordManifest(manifest)
    let malformed = TatwoStoredDispatchRun(
      schema: "TatwoStoredDispatchRunV999",
      contractID: stored.contractID,
      manifestEntryIDs: stored.manifestEntryIDs,
      records: stored.records,
      updatedAt: stored.updatedAt,
      activeCycleEpoch: stored.activeCycleEpoch,
      cycleSeals: stored.cycleSeals)
    try writeDispatchRun(malformed, registry: fixture.registry)

    try assertChallengeRejectsSuccessorRegistry(fixture)
  }

  func testCanonicalLiveStateChallengeFactoryRejectsAdvancedOrSealedRegistry()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let manifest = TatwoExecutionManifestFactory.make(
      contract: fixture.new,
      generatedAt: fixture.now)
    let stored = try fixture.registry.recordManifest(manifest)
    let advanced = TatwoStoredDispatchRun(
      contractID: stored.contractID,
      manifestEntryIDs: stored.manifestEntryIDs,
      records: [],
      updatedAt: stored.updatedAt,
      activeCycleEpoch: 2,
      cycleSeals: [])
    try writeDispatchRun(advanced, registry: fixture.registry)
    try assertChallengeRejectsSuccessorRegistry(fixture)

    let sealed = TatwoStoredDispatchRun(
      contractID: stored.contractID,
      manifestEntryIDs: stored.manifestEntryIDs,
      records: [],
      updatedAt: stored.updatedAt,
      sealID: "dispatch-cycle-seal-test",
      sealedAt: fixture.now,
      sealedRecordIDs: ["published-record"],
      sealedGoalID: fixture.new.goalID,
      activeCycleEpoch: 1,
      cycleSeals: [
        TatwoDispatchCycleSealV1(
          epoch: 1,
          sealID: "dispatch-cycle-seal-test",
          sealedAt: fixture.now,
          recordIDs: ["published-record"],
          goalID: fixture.new.goalID)
      ])
    try writeDispatchRun(sealed, registry: fixture.registry)
    try assertChallengeRejectsSuccessorRegistry(fixture)
  }

  func testCanonicalLiveStateChallengeFactoryRejectsCompletedSuccessorRecord()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.registry.begin(
      contractID: fixture.new.contractID,
      goalID: fixture.new.goalID,
      bindingID: "published-successor",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "fixture",
      subtask: "completed publication still blocks revision",
      now: fixture.now)
    var run = try XCTUnwrap(
      fixture.registry.run(forContractID: fixture.new.contractID))
    run.records[0].status = .completed
    try writeDispatchRun(run, registry: fixture.registry)

    try assertChallengeRejectsSuccessorRegistry(fixture)
  }

  func testCanonicalLiveStateChallengeFactoryRejectsPredecessorDispatchDrift()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: challengeInput(fixture),
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry,
        beforeFinalStateValidation: {
          _ = try fixture.registry.begin(
            contractID: fixture.old.contractID,
            goalID: fixture.old.goalID,
            bindingID: "late-predecessor-dispatch",
            sourceSlotID: "sub",
            identity: .sub,
            modelID: "fixture",
            subtask: "must invalidate recovery candidate",
            now: fixture.now)
        })
    ) { error in
      guard
        let typed =
          error as? TatwoGoalRevisionBootstrapRecoveryChallengeError,
        case .predecessorDispatchActive(let ids) = typed
      else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(ids.count, 1)
    }
    XCTAssertEqual(
      try fixture.sessionStore.snapshotCurrent()?.pointer.contractID,
      fixture.old.contractID)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.old.contractID).status,
      .running)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.new.contractID).status,
      .planned)
  }

  func testCanonicalLiveStateChallengeFactoryRejectsSymlinkedSuccessorOutbox()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outboxRoot = fixture.root.appendingPathComponent(
      "remote-outbox-intents",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: outboxRoot,
      withIntermediateDirectories: true)
    let emptyTarget = fixture.root.appendingPathComponent(
      "empty-outbox-target",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: emptyTarget,
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: outboxRoot.appendingPathComponent(
        TatwoLoopPathComponent.sanitize(fixture.new.contractID),
        isDirectory: true),
      withDestinationURL: emptyTarget)

    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: challengeInput(fixture),
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry)
    ) { error in
      XCTAssertEqual(
        error as?
          TatwoGoalRevisionBootstrapRecoveryChallengeError,
        .successorNotPristine("remote_outbox"))
    }
  }

  func testChallengeRejectsOpaqueOrControlRichCallerAuditContext() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let opaque = copyChallengeInput(
      challengeInput(fixture),
      humanMessage: Data([0xff, 0xfe]))
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: opaque,
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry)
    ) { error in
      XCTAssertEqual(
        error as?
          TatwoGoalRevisionBootstrapRecoveryChallengeError,
        .invalidInput("humanMessage"))
    }

    let controlRich = copyChallengeInput(
      challengeInput(fixture),
      eventID: "fabricated\nevent")
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: controlRich,
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry)
    ) { error in
      XCTAssertEqual(
        error as?
          TatwoGoalRevisionBootstrapRecoveryChallengeError,
        .invalidInput("eventID"))
    }
  }

  func testRecoveryFailsClosedWithoutTrustedHostProvider() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let issuer = TatwoGoalRevisionBootstrapRecoveryIssuer(
      stateDirectoryURL: fixture.root)

    XCTAssertThrowsError(
      try issuer.signingPayload(
        for: fixture.evidence,
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .unavailable)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: issuer.receiptStore.url(for: fixture.evidence.id).path))
  }

  func testMutableStatePublicKeyReplacementCannotMintRecovery() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pointerBefore = try XCTUnwrap(
      fixture.sessionStore.snapshotCurrent())
    let oldBefore = try fixture.goalStore.requireIssuedContract(
      fixture.old.contractID)
    let newBefore = try fixture.goalStore.requireIssuedContract(
      fixture.new.contractID)
    let attackerKey = Curve25519.Signing.PrivateKey()
    let attackerKeyURL = fixture.root
      .appendingPathComponent(
        "bootstrap-recovery-authority", isDirectory: true)
      .appendingPathComponent("host-public-key")
    try FileManager.default.createDirectory(
      at: attackerKeyURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try attackerKey.publicKey.rawRepresentation.write(
      to: attackerKeyURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: attackerKeyURL.path)

    let issuer = TatwoGoalRevisionBootstrapRecoveryIssuer(
      stateDirectoryURL: fixture.root)
    XCTAssertThrowsError(
      try issuer.signingPayload(
        for: copyEvidence(
          fixture.evidence,
          hostKeyID:
            TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
              attackerKey.publicKey.rawRepresentation)),
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .unavailable)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: issuer.receiptStore.url(for: fixture.evidence.id).path))
    XCTAssertEqual(
      try fixture.sessionStore.snapshotCurrent()?.pointer,
      pointerBefore.pointer)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.old.contractID),
      oldBefore)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(
        fixture.new.contractID),
      newBefore)
  }

  func testProductionRecoveryAuthorizationFailsClosedAndColdStateIsUnchanged()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let receipt = try signedReceipt(fixture, issuer: fixture.issuer)
    let pointerBefore = try XCTUnwrap(
      fixture.sessionStore.snapshotCurrent())
    let oldBefore = try fixture.goalStore.requireIssuedContract(
      fixture.old.contractID)
    let newBefore = try fixture.goalStore.requireIssuedContract(
      fixture.new.contractID)
    let promotionStore = TatwoGoalRevisionPromotionAuthorizationStore(
      directoryURL: fixture.root.appendingPathComponent(
        "goal-revision-authorizations", isDirectory: true))

    XCTAssertThrowsError(
      try promotionStore.authorizeAfterBootstrapRecovery(
        id: fixture.evidence.authorizationID,
        humanGateReceipt: receipt,
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .unavailable)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: promotionStore.directoryURL
          .appendingPathComponent(
            "\(fixture.evidence.authorizationID).json").path))

    let coldSessionStore = TatwoSessionStore(
      directoryURL: fixture.root)
    let coldGoalStore = TatwoGoalRunStore(
      directoryURL: fixture.root)
    XCTAssertEqual(
      try coldSessionStore.snapshotCurrent()?.pointer,
      pointerBefore.pointer)
    XCTAssertEqual(
      try coldGoalStore.requireIssuedContract(
        fixture.old.contractID),
      oldBefore)
    XCTAssertEqual(
      try coldGoalStore.requireIssuedContract(
        fixture.new.contractID),
      newBefore)
  }

  func testRecoveryRejectsWrongSignatureAndTamperedUserEvent() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let issuer = fixture.issuer
    let payload = try issuer.signingPayload(
      for: fixture.evidence,
      now: fixture.now)
    let wrongKey = Curve25519.Signing.PrivateKey()
    let wrongProof = "ed25519:\(try wrongKey.signature(for: payload).base64EncodedString())"
    XCTAssertThrowsError(
      try issuer.acceptHostSignedEvidence(
        fixture.evidence,
        proofDigest: wrongProof,
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .signatureRejected)
    }

    let validProof =
      "ed25519:\(try fixture.hostKey.signature(for: payload).base64EncodedString())"
    let tampered = copyEvidence(
      fixture.evidence,
      humanMessageDigest: digest("different-user-event"))
    XCTAssertThrowsError(
      try issuer.acceptHostSignedEvidence(
        tampered,
        proofDigest: validProof,
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .signatureRejected)
    }
  }

  func testRecoveryRequiresSingleUseAndExactRecoveryOnlyScope() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let issuer = fixture.issuer

    for invalid in [
      copyEvidence(fixture.evidence, maxUses: 2),
      copyEvidence(
        fixture.evidence,
        allowedOperations: ["build", "goal_revision_transition"]),
      copyEvidence(
        fixture.evidence,
        deniedOperations: ["auth"]),
      copyEvidence(
        fixture.evidence,
        observedRole: "assistant"),
    ] {
      XCTAssertThrowsError(
        try issuer.signingPayload(for: invalid, now: fixture.now)
      ) { error in
        XCTAssertEqual(
          error as? TatwoHumanGateVerificationError,
          .invalid("bootstrap_recovery_evidence"))
      }
    }
  }

  func testRecoveryReceiptCreateOnlyRetryIsByteIdenticalAndScopeConflictFails()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let issuer = fixture.issuer
    let payload = try issuer.signingPayload(
      for: fixture.evidence,
      now: fixture.now)
    let proof =
      "ed25519:\(try fixture.hostKey.signature(for: payload).base64EncodedString())"
    let first = try issuer.acceptHostSignedEvidence(
      fixture.evidence,
      proofDigest: proof,
      now: fixture.now)
    let receiptURL = issuer.receiptStore.url(for: first.id)
    let firstBytes = try Data(contentsOf: receiptURL)
    let retried = try issuer.acceptHostSignedEvidence(
      fixture.evidence,
      proofDigest: proof,
      now: fixture.now)
    XCTAssertEqual(retried, first)
    XCTAssertEqual(try Data(contentsOf: receiptURL), firstBytes)

    let conflictingEvidence = copyEvidence(
      fixture.evidence,
      eventID: "different-event")
    let conflictingPayload = try issuer.signingPayload(
      for: conflictingEvidence,
      now: fixture.now)
    let conflictingProof =
      "ed25519:\(try fixture.hostKey.signature(for: conflictingPayload).base64EncodedString())"
    XCTAssertThrowsError(
      try issuer.acceptHostSignedEvidence(
        conflictingEvidence,
        proofDigest: conflictingProof,
        now: fixture.now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHumanGateVerificationError,
        .consumptionConflict)
    }
    XCTAssertEqual(try Data(contentsOf: receiptURL), firstBytes)
  }

  func testRecoveryAuthorizationRejectsPredecessorReceiptDrift() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let issuer = fixture.issuer
    let receipt = try signedReceipt(fixture, issuer: issuer)
    let promotionStore = TatwoGoalRevisionPromotionAuthorizationStore(
      directoryURL: fixture.root.appendingPathComponent(
        "goal-revision-authorizations", isDirectory: true))
    let promotion = try promotionStore.authorizeAfterBootstrapRecovery(
      id: "bootstrap-promotion",
      humanGateReceipt: receipt,
      now: fixture.now,
      trustAnchorProvider: fixture.trustAnchor)
    _ = try fixture.goalStore.appendReceipt(
      contractID: fixture.old.contractID,
      receiptID: "late-receipt",
      kind: "scope-drift")

    XCTAssertThrowsError(
      try fixture.sessionStore.transitionCurrentToPlannedRevision(
        authorizationID: promotion.id,
        now: fixture.now,
        goalStore: fixture.goalStore,
        dispatchRegistry: fixture.registry,
        authorizationStore: promotionStore,
        humanGateVerifier: fixture.verifier)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSessionMutationError,
        .revisionPromotionAuthorization("old_receipts"))
    }
    XCTAssertEqual(
      try fixture.sessionStore.snapshotCurrent()?.pointer.contractID,
      fixture.old.contractID)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(fixture.new.contractID).status,
      .planned)
  }

  func testRootAdminEnrollmentInstallsExactGrantWithoutGoalMutation()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let input = try makeEnrollmentInput(fixture)
    let targetRoot = try makeEnrollmentTargetRoot(fixture)
    let pointerBefore = try fixture.sessionStore.snapshotCurrent()
    let oldBefore = try fixture.goalStore.snapshot(
      forContractID: fixture.old.contractID)
    let newBefore = try fixture.goalStore.snapshot(
      forContractID: fixture.new.contractID)
    var review = Data()

    let result =
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { review.append($0) },
          readConfirmation: {
            try self.enrollmentShortCode(from: review)
          }))

    XCTAssertTrue(result.mutationPerformed)
    XCTAssertTrue(result.grantInstalled)
    XCTAssertFalse(result.goalMutationPerformed)
    XCTAssertFalse(result.grantConsumed)
    XCTAssertFalse(result.authorizationCreated)
    XCTAssertEqual(result.localUserUID, UInt32(getuid()))
    XCTAssertEqual(result.oldContractID, fixture.old.contractID)
    XCTAssertEqual(result.newContractID, fixture.new.contractID)

    let reviewText = try XCTUnwrap(
      String(data: review, encoding: .utf8))
    XCTAssertTrue(reviewText.contains(input.humanText))
    XCTAssertTrue(reviewText.contains(input.legacyText))
    XCTAssertTrue(reviewText.contains(fixture.old.contractID))
    XCTAssertTrue(reviewText.contains(fixture.new.contractID))
    XCTAssertTrue(reviewText.contains("COMPLETE OLD/NEW GOAL LINE DIFF"))
    XCTAssertTrue(reviewText.contains(result.grantBodyDigest))
    XCTAssertTrue(reviewText.contains(result.grantFileDigest))
    XCTAssertTrue(reviewText.contains(result.shortCode))

    let installedURL = URL(fileURLWithPath: result.targetPath)
    let installedBytes = try Data(contentsOf: installedURL)
    XCTAssertEqual(
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(installedBytes),
      result.grantFileDigest)
    let decoded =
      try TatwoGoalRevisionRootOwnedRecoveryGrantV1.decodeCanonical(
        installedBytes)
    XCTAssertEqual(decoded.bodyDigest, result.grantBodyDigest)
    XCTAssertEqual(decoded.body.shortCode, result.shortCode)
    var status = stat()
    XCTAssertEqual(Darwin.lstat(installedURL.path, &status), 0)
    XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
    XCTAssertEqual(status.st_uid, getuid())
    XCTAssertEqual(status.st_gid, getgid())
    XCTAssertEqual(status.st_mode & 0o777, 0o444)
    XCTAssertEqual(status.st_nlink, 1)
    XCTAssertEqual(status.st_size, off_t(installedBytes.count))

    XCTAssertEqual(try fixture.sessionStore.snapshotCurrent(), pointerBefore)
    XCTAssertEqual(
      try fixture.goalStore.snapshot(
        forContractID: fixture.old.contractID),
      oldBefore)
    XCTAssertEqual(
      try fixture.goalStore.snapshot(
        forContractID: fixture.new.contractID),
      newBefore)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent(
          "human-gate-authority/consumptions").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent(
          "goal-revision-authorizations").path))
  }

  func testRootAdminEnrollmentRequiresRootAndMatchingSudoUID() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let input = try makeEnrollmentInput(fixture)
    let targetRoot = try makeEnrollmentTargetRoot(fixture)

    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          effectiveUID: getuid(),
          writeReview: { _ in },
          readConfirmation: { "" }))
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionRootAdminEnrollmentError,
        .effectiveRootRequired)
    }

    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          sourceExpectedOwnerUID: getuid() &+ 1,
          writeReview: { _ in },
          readConfirmation: { "" }))
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionRootAdminEnrollmentError,
        .invalidSudoUID)
    }
  }

  func testRootAdminEnrollmentRejectsSymlinkAndHardLinkedSources()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let input = try makeEnrollmentInput(fixture)
    let targetRoot = try makeEnrollmentTargetRoot(fixture)
    let symlinkURL = fixture.root.appendingPathComponent(
      "human-message-link.txt")
    try FileManager.default.createSymbolicLink(
      at: symlinkURL,
      withDestinationURL: input.humanURL)
    let resolvedFixtureRoot = try resolvedPath(fixture.root.path)
    let symlinkRequest = TatwoGoalRevisionRootAdminEnrollmentRequestV1(
      successorContractID: input.request.successorContractID,
      threadID: input.request.threadID,
      turnID: input.request.turnID,
      eventID: input.request.eventID,
      humanMessageSourcePath:
        URL(fileURLWithPath: resolvedFixtureRoot)
        .appendingPathComponent(symlinkURL.lastPathComponent).path,
      legacyUnavailableEvidenceSourcePath:
        input.request.legacyUnavailableEvidenceSourcePath,
      legacyAppVersion: input.request.legacyAppVersion,
      legacyAppBuild: input.request.legacyAppBuild,
      deviceID: input.request.deviceID,
      ttlSeconds: input.request.ttlSeconds)

    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: symlinkRequest,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { _ in },
          readConfirmation: { "" }))
    ) { error in
      guard case .invalidSource(let field) =
        error as? TatwoGoalRevisionRootAdminEnrollmentError
      else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(field.contains("human_message"))
    }

    try FileManager.default.removeItem(at: symlinkURL)
    let realParent = fixture.root.appendingPathComponent(
      "real-source-parent", isDirectory: true)
    try FileManager.default.createDirectory(
      at: realParent,
      withIntermediateDirectories: false)
    let parentSource = realParent.appendingPathComponent("human.txt")
    try Data(input.humanText.utf8).write(to: parentSource)
    let fakeParent = fixture.root.appendingPathComponent(
      "fake-source-parent", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: fakeParent,
      withDestinationURL: realParent)
    let parentSymlinkRequest =
      TatwoGoalRevisionRootAdminEnrollmentRequestV1(
        successorContractID: input.request.successorContractID,
        threadID: input.request.threadID,
        turnID: input.request.turnID,
        eventID: input.request.eventID,
        humanMessageSourcePath:
          URL(fileURLWithPath: resolvedFixtureRoot)
          .appendingPathComponent(fakeParent.lastPathComponent)
          .appendingPathComponent(parentSource.lastPathComponent).path,
        legacyUnavailableEvidenceSourcePath:
          input.request.legacyUnavailableEvidenceSourcePath,
        legacyAppVersion: input.request.legacyAppVersion,
        legacyAppBuild: input.request.legacyAppBuild,
        deviceID: input.request.deviceID,
        ttlSeconds: input.request.ttlSeconds)
    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: parentSymlinkRequest,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { _ in },
          readConfirmation: { "" }))
    ) { error in
      guard case .invalidSource(let field) =
        error as? TatwoGoalRevisionRootAdminEnrollmentError
      else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(field.contains("human_message_parent"))
    }

    let hardLinkURL = fixture.root.appendingPathComponent(
      "human-message-hard-link.txt")
    try FileManager.default.linkItem(
      at: input.humanURL,
      to: hardLinkURL)
    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { _ in },
          readConfirmation: { "" }))
    ) { error in
      guard case .invalidSource(let field) =
        error as? TatwoGoalRevisionRootAdminEnrollmentError
      else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(field.contains("human_message"))
    }
  }

  func testRootAdminEnrollmentRejectsWritableOrTTYControlSource()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let input = try makeEnrollmentInput(fixture)
    let targetRoot = try makeEnrollmentTargetRoot(fixture)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o666],
      ofItemAtPath: input.humanURL.path)

    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { _ in },
          readConfirmation: { "" }))
    ) { error in
      guard case .invalidSource(let field) =
        error as? TatwoGoalRevisionRootAdminEnrollmentError
      else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(field, "human_message_metadata")
    }

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: input.humanURL.path)
    try Data("visible\u{001B}[2Jspoof".utf8).write(
      to: input.humanURL,
      options: [.atomic])
    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { _ in },
          readConfirmation: { "" }))
    ) { error in
      guard case .invalidSource(let field) =
        error as? TatwoGoalRevisionRootAdminEnrollmentError
      else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(field, "human_message_changed_or_encoding")
    }
  }

  func testRootAdminEnrollmentRequiresExactTTYCodeAndRereadsSources()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let input = try makeEnrollmentInput(fixture)
    let targetRoot = try makeEnrollmentTargetRoot(fixture)

    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { _ in },
          readConfirmation: { "WRONG-CODE" }))
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionRootAdminEnrollmentError,
        .confirmationMismatch)
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: targetRoot,
        includingPropertiesForKeys: nil),
      [])

    var review = Data()
    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { review.append($0) },
          readConfirmation: {
            try Data("changed after review".utf8).write(
              to: input.humanURL,
              options: [.atomic])
            return try self.enrollmentShortCode(from: review)
          }))
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionRootAdminEnrollmentError,
        .candidateChanged)
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: targetRoot,
        includingPropertiesForKeys: nil),
      [])
  }

  func testRootAdminEnrollmentUsesCreateOnlyTargetAndNeverOverwrites()
    throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let input = try makeEnrollmentInput(fixture)
    let targetRoot = try makeEnrollmentTargetRoot(fixture)
    var firstReview = Data()
    let first =
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { firstReview.append($0) },
          readConfirmation: {
            try self.enrollmentShortCode(from: firstReview)
          }))
    let original = try Data(
      contentsOf: URL(fileURLWithPath: first.targetPath))

    var secondReview = Data()
    XCTAssertThrowsError(
      try TatwoGoalRevisionRootAdminEnrollment.perform(
        request: input.request,
        context: enrollmentContext(
          fixture: fixture,
          targetRoot: targetRoot,
          writeReview: { secondReview.append($0) },
          readConfirmation: {
            try self.enrollmentShortCode(from: secondReview)
          }))
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalRevisionRootAdminEnrollmentError,
        .targetAlreadyExists)
    }
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: first.targetPath)),
      original)
  }

  func testLegacyAppReceiptSigningPayloadRemainsByteCompatible() {
    let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let expiresAt = issuedAt.addingTimeInterval(600)
    let artifact = TatwoHumanGateIssuerArtifactIdentityV1(
      bundleIdentifier: "com.tatwo.ultrawork",
      teamIdentifier: "TEAM",
      codeDirectoryHash: "cdhash",
      executableSHA256: String(repeating: "a", count: 64))
    let receipt = TatwoHumanGateReceiptV1(
      id: "legacy-app",
      issuerDomain: "app.tatwo.ultrawork.human-gate",
      sessionID: "session",
      oldContractID: "old-contract",
      oldGoalID: "old-goal",
      newContractID: "new-contract",
      newGoalID: "new-goal",
      subjectDigest: digest("subject"),
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      nonce: "nonce",
      proofDigest: "")
    let expected = Data([
      "TatwoHumanGateReceiptV1",
      "legacy-app",
      "app.tatwo.ultrawork.human-gate",
      "session",
      "old-contract",
      "old-goal",
      "new-contract",
      "new-goal",
      digest("subject"),
      String(Int64(issuedAt.timeIntervalSince1970)),
      String(Int64(expiresAt.timeIntervalSince1970)),
      "nonce",
      [
        artifact.schema,
        artifact.bundleIdentifier,
        artifact.teamIdentifier ?? "ad-hoc",
        artifact.codeDirectoryHash,
        artifact.executableSHA256,
      ].joined(separator: "\n"),
    ].joined(separator: "\n").utf8)
    let receiptWithArtifact = TatwoHumanGateReceiptV1(
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
      nonce: receipt.nonce,
      proofDigest: receipt.proofDigest,
      issuerArtifactIdentity: artifact)
    XCTAssertEqual(receiptWithArtifact.signingPayload, expected)
  }

  private struct EnrollmentInput {
    let request: TatwoGoalRevisionRootAdminEnrollmentRequestV1
    let humanURL: URL
    let legacyURL: URL
    let humanText: String
    let legacyText: String
  }

  private func makeEnrollmentInput(
    _ fixture: Fixture
  ) throws -> EnrollmentInput {
    let humanText =
      "Fresh human action-time confirmation for the exact successor Goal."
    let legacyText =
      "Installed Build 25 cannot mint the successor recovery authority."
    let humanURL = fixture.root.appendingPathComponent(
      "human-message.txt")
    let legacyURL = fixture.root.appendingPathComponent(
      "legacy-unavailable-evidence.txt")
    try Data(humanText.utf8).write(to: humanURL)
    try Data(legacyText.utf8).write(to: legacyURL)
    return EnrollmentInput(
      request: TatwoGoalRevisionRootAdminEnrollmentRequestV1(
        successorContractID: fixture.new.contractID,
        threadID: "codex-thread",
        turnID: "codex-turn",
        eventID: "codex-user-event",
        humanMessageSourcePath: try resolvedPath(humanURL.path),
        legacyUnavailableEvidenceSourcePath:
          try resolvedPath(legacyURL.path),
        legacyAppVersion: "0.1.11",
        legacyAppBuild: "25",
        deviceID: "fixture-device",
        ttlSeconds: 600),
      humanURL: humanURL,
      legacyURL: legacyURL,
      humanText: humanText,
      legacyText: legacyText)
  }

  private func makeEnrollmentTargetRoot(
    _ fixture: Fixture
  ) throws -> URL {
    let root = fixture.root.appendingPathComponent(
      "root-admin-enrollment-target-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: root.path)
    return root
  }

  private func enrollmentContext(
    fixture: Fixture,
    targetRoot: URL,
    effectiveUID: uid_t = 0,
    sourceExpectedOwnerUID: uid_t = getuid(),
    writeReview: @escaping (Data) throws -> Void,
    readConfirmation: @escaping () throws -> String
  ) -> TatwoGoalRevisionRootAdminEnrollmentContext {
    TatwoGoalRevisionRootAdminEnrollmentContext(
      effectiveUID: effectiveUID,
      sudoUID: getuid(),
      stateDirectoryURL: fixture.root,
      sourceExpectedOwnerUID: sourceExpectedOwnerUID,
      targetRootURL: targetRoot,
      targetDirectoryComponents:
        TatwoGoalRevisionRootAdminEnrollmentContext
        .productionDirectoryComponents,
      targetExpectedOwnerUID: getuid(),
      targetExpectedGroupID: getgid(),
      executableProvenance: fixtureExecutableProvenance(fixture),
      clock: { fixture.now },
      writeReview: writeReview,
      readConfirmation: readConfirmation)
  }

  private func fixtureExecutableProvenance(
    _ fixture: Fixture
  ) -> TatwoGoalRevisionRootAdminExecutableProvenanceV1 {
    TatwoGoalRevisionRootAdminExecutableProvenanceV1(
      executablePath: fixture.root.appendingPathComponent(
        "fixture-root-admin-executable").path,
      executableSHA256: String(repeating: "a", count: 64),
      parentChainDigest: String(repeating: "b", count: 64),
      device: 1,
      inode: 2,
      byteCount: 3)
  }

  private func enrollmentShortCode(
    from review: Data
  ) throws -> String {
    let text = try XCTUnwrap(String(data: review, encoding: .utf8))
    let marker = "Exact short code: "
    let line = try XCTUnwrap(
      text.split(separator: "\n").first {
        $0.hasPrefix(marker)
      })
    return String(line.dropFirst(marker.count))
  }

  private func resolvedPath(_ path: String) throws -> String {
    guard let value = path.withCString({
      Darwin.realpath($0, nil)
    }) else {
      throw POSIXError(
        POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }
    defer { Darwin.free(value) }
    return String(cString: value)
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-bootstrap-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true)
    let goalStore = TatwoGoalRunStore(directoryURL: root)
    let sessionStore = TatwoSessionStore(directoryURL: root)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let owner = TatwoSessionOwnerExpectationV1(
      provider: "codex",
      sessionID: "host-session",
      workspacePath: root.appendingPathComponent("workspace").path)
    let predecessor = try WorkOSFactory.projectContract(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "legacy objective")
    _ = try TatwoSessionAuthorityLockBootstrap.bootstrapExplicitly(
      goalStoreRoot: root,
      contractID: predecessor.contractID)
    let oldAttachment = try sessionStore.beginCurrent(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "legacy objective",
      owner: .session(owner),
      goalStore: goalStore,
      dispatchRegistry: registry)
    let old = oldAttachment.contract
    _ = try goalStore.updateStatus(
      contractID: old.contractID,
      status: .running,
      authority: .revisionPromotion,
      reason: "bootstrap-recovery-fixture")
    _ = try goalStore.appendReceipt(
      contractID: old.contractID,
      receiptID: "legacy-receipt",
      kind: "evidence")
    let new = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: .m,
      scenarioProfileID: "coding",
      objective: "successor objective",
      store: goalStore)
    let oldRecord = try goalStore.requireIssuedContract(old.contractID)
    let newRecord = try goalStore.requireIssuedContract(new.contractID)
    let pointer = try XCTUnwrap(sessionStore.snapshotCurrent())
    let hostKey = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let requestedScopeDigest = digest(
      [
        "revision_activation_only",
        "none",
        "",
        "none",
        "none",
        "none",
      ].joined(separator: "\n"))
    let evidence = TatwoGoalRevisionBootstrapRecoveryEvidenceV1(
      id: "bootstrap-human",
      challengeID: "bootstrap-challenge",
      threadID: "codex-thread",
      turnID: "codex-turn",
      eventID: "codex-user-event",
      observedRole: "user",
      humanMessageDigest: digest("user requested exact successor"),
      legacyAppBundleIdentifier: "com.tatwo.ultrawork",
      legacyAppVersion: "0.1.11",
      legacyAppBuild: "25",
      legacyIssuerAvailability: "unavailable",
      legacyUnavailableEvidenceDigest:
        digest("legacy app issuer cannot mint successor recovery"),
      hostKeyID:
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
          hostKey.publicKey.rawRepresentation),
      authorizationID: "bootstrap-promotion",
      grantID: "bootstrap-grant",
      shortCode: "ABC123",
      localUserUID: UInt32(getuid()),
      deviceID: "fixture-device",
      recoveryReason: "installed_app_confirmation_unavailable",
      sessionID: owner.sessionID,
      oldPointerRevisionDigest: pointer.revision.digest,
      oldPointerGeneration: pointer.pointer.generation ?? 1,
      oldContractID: old.contractID,
      oldGoalID: old.goalID,
      oldGoalRevision: oldRecord.resolvedRevision,
      oldActivationEpoch: oldRecord.resolvedRevision,
      oldObjectiveDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
          oldRecord.objective),
      oldReceiptsDigest:
        TatwoGoalRevisionPromotionAuthorizationV1.receiptsDigest(
          oldRecord.receipts),
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
      requestedHostScopeDigest: requestedScopeDigest,
      allowedOperations:
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .requiredAllowedOperations,
      deniedOperations:
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .requiredDeniedOperations,
      maxUses: 1,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(600),
      nonce: "bootstrap-nonce")
    return Fixture(
      root: root,
      goalStore: goalStore,
      sessionStore: sessionStore,
      registry: registry,
      old: old,
      new: new,
      oldRecord: oldRecord,
      pointer: pointer,
      hostKey: hostKey,
      now: now,
      evidence: evidence)
  }

  private func signedReceipt(
    _ fixture: Fixture,
    issuer: TatwoGoalRevisionBootstrapRecoveryIssuer
  ) throws -> TatwoHumanGateReceiptV1 {
    let payload = try issuer.signingPayload(
      for: fixture.evidence,
      now: fixture.now)
    let signature = try fixture.hostKey.signature(for: payload)
    return try issuer.acceptHostSignedEvidence(
      fixture.evidence,
      proofDigest: "ed25519:\(signature.base64EncodedString())",
      now: fixture.now)
  }

  private struct RootGrantInstallation {
    let plan: TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1
    let provider: TatwoRootOwnedBootstrapRecoveryGrantProvider
    let grantDirectoryURL: URL
    let grantURL: URL
  }

  private func installRootGrant(
    _ fixture: Fixture,
    expectedOwnerUID: uid_t = getuid(),
    expectedGroupID: gid_t = getgid()
  ) throws -> RootGrantInstallation {
    let anchor = fixture.root.appendingPathComponent(
      "root-grant-anchor-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(
      at: anchor,
      withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: anchor.path)
    let components = [
      "Library",
      "Application Support",
      "Tatwo Ultrawork",
      "GoalRecoveryGrants",
      "v1",
    ]
    var directory = anchor
    for component in components {
      directory.appendPathComponent(component, isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: directory.path)
    }
    let plan =
      try TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1.prepare(
        evidence: fixture.evidence)
    let fileName =
      try TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1.fileName(
        bodyDigest: plan.grant.bodyDigest)
    let grantURL = directory.appendingPathComponent(fileName)
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: grantURL.path,
        contents: plan.canonicalGrantBytes))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444],
      ofItemAtPath: grantURL.path)
    return RootGrantInstallation(
      plan: plan,
      provider: TatwoRootOwnedBootstrapRecoveryGrantProvider(
        anchorDirectoryURL: anchor,
        directoryComponents: components,
        expectedOwnerUID: expectedOwnerUID,
        expectedGroupID: expectedGroupID),
      grantDirectoryURL: directory,
      grantURL: grantURL)
  }

  private func challengeInput(
    _ fixture: Fixture
  ) -> TatwoGoalRevisionBootstrapRecoveryChallengeInputV1 {
    TatwoGoalRevisionBootstrapRecoveryChallengeInputV1(
      successorContractID: fixture.new.contractID,
      threadID: "codex-thread",
      turnID: "codex-turn",
      eventID: "codex-user-event",
      humanMessage: Data("user requested exact successor".utf8),
      legacyAppVersion: "0.1.11",
      legacyAppBuild: "25",
      legacyUnavailableEvidence: Data(
        "legacy app issuer cannot mint successor recovery".utf8),
      deviceID: "fixture-device",
      localUserUID: UInt32(getuid()),
      issuedAt: fixture.now,
      expiresAt: fixture.now.addingTimeInterval(600))
  }

  private func assertChallengeRejectsSuccessorRegistry(
    _ fixture: Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertThrowsError(
      try TatwoGoalRevisionBootstrapRecoveryChallengeFactory.prepare(
        input: challengeInput(fixture),
        goalStore: fixture.goalStore,
        sessionStore: fixture.sessionStore,
        dispatchRegistry: fixture.registry),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as?
          TatwoGoalRevisionBootstrapRecoveryChallengeError,
        .successorNotPristine("dispatch_registry"),
        file: file,
        line: line)
    }
  }

  private func writeDispatchRun(
    _ run: TatwoStoredDispatchRun,
    registry: TatwoDispatchRegistry
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(run).write(
      to: registry.fileURL(forContractID: run.contractID),
      options: [.atomic])
  }

  private func copyChallengeInput(
    _ value: TatwoGoalRevisionBootstrapRecoveryChallengeInputV1,
    eventID: String? = nil,
    humanMessage: Data? = nil
  ) -> TatwoGoalRevisionBootstrapRecoveryChallengeInputV1 {
    TatwoGoalRevisionBootstrapRecoveryChallengeInputV1(
      successorContractID: value.successorContractID,
      threadID: value.threadID,
      turnID: value.turnID,
      eventID: eventID ?? value.eventID,
      humanMessage: humanMessage ?? value.humanMessage,
      legacyAppVersion: value.legacyAppVersion,
      legacyAppBuild: value.legacyAppBuild,
      legacyUnavailableEvidence: value.legacyUnavailableEvidence,
      deviceID: value.deviceID,
      localUserUID: value.localUserUID,
      recoveryReason: value.recoveryReason,
      issuedAt: value.issuedAt,
      expiresAt: value.expiresAt)
  }

  private func copyEvidence(
    _ value: TatwoGoalRevisionBootstrapRecoveryEvidenceV1,
    id: String? = nil,
    eventID: String? = nil,
    observedRole: String? = nil,
    humanMessageDigest: String? = nil,
    authorityKind: String? = nil,
    hostKeyID: String? = nil,
    allowedOperations: [String]? = nil,
    deniedOperations: [String]? = nil,
    maxUses: UInt64? = nil
  ) -> TatwoGoalRevisionBootstrapRecoveryEvidenceV1 {
    TatwoGoalRevisionBootstrapRecoveryEvidenceV1(
      schema: value.schema,
      id: id ?? value.id,
      challengeID: value.challengeID,
      threadID: value.threadID,
      turnID: value.turnID,
      eventID: eventID ?? value.eventID,
      observedRole: observedRole ?? value.observedRole,
      humanMessageDigest:
        humanMessageDigest ?? value.humanMessageDigest,
      legacyAppBundleIdentifier: value.legacyAppBundleIdentifier,
      legacyAppVersion: value.legacyAppVersion,
      legacyAppBuild: value.legacyAppBuild,
      legacyIssuerAvailability: value.legacyIssuerAvailability,
      legacyUnavailableEvidenceDigest:
        value.legacyUnavailableEvidenceDigest,
      authorityKind: authorityKind ?? value.authorityKind,
      hostKeyID: hostKeyID ?? value.hostKeyID,
      authorizationID: value.authorizationID,
      grantID: value.grantID,
      shortCode: value.shortCode,
      localUserUID: value.localUserUID,
      deviceID: value.deviceID,
      recoveryReason: value.recoveryReason,
      sessionID: value.sessionID,
      oldPointerRevisionDigest: value.oldPointerRevisionDigest,
      oldPointerGeneration: value.oldPointerGeneration,
      oldContractID: value.oldContractID,
      oldGoalID: value.oldGoalID,
      oldGoalRevision: value.oldGoalRevision,
      oldActivationEpoch: value.oldActivationEpoch,
      oldObjectiveDigest: value.oldObjectiveDigest,
      oldReceiptsDigest: value.oldReceiptsDigest,
      newContractID: value.newContractID,
      newGoalID: value.newGoalID,
      newGoalRevision: value.newGoalRevision,
      newObjectiveDigest: value.newObjectiveDigest,
      topologyDigest: value.topologyDigest,
      capabilityDigest: value.capabilityDigest,
      requestedHostScopeDigest: value.requestedHostScopeDigest,
      allowedOperations:
        allowedOperations ?? value.allowedOperations,
      deniedOperations: deniedOperations ?? value.deniedOperations,
      maxUses: maxUses ?? value.maxUses,
      issuedAt: value.issuedAt,
      expiresAt: value.expiresAt,
      nonce: value.nonce)
  }

  private func digest(_ value: String) -> String {
    TatwoGoalRevisionPromotionAuthorizationV1.digest(value)
  }
}
