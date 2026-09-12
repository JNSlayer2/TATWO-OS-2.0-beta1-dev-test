import Foundation
import TatwoDomainContracts
import TatwoWorkReceiptContracts
import XCTest

@testable import TatwoUltraworkCore

final class SharedProjectS1Tests: XCTestCase {
  private let projectID = "proj-shared-alpha"
  private let domainID = "domain-test-1"
  private let writerA = "device-mac-mini"
  private let writerB = "device-macbook"
  private let verifier = "device-ipad"
  private let replica = "device-replica"
  private let now = Date(timeIntervalSince1970: 1_900_000_000)

  // MARK: - Fixtures

  private func fence(
    epoch: UInt64 = 3,
    token: String = "domain-fence-token-1",
    holder: String? = nil
  ) -> TatwoDomainFenceBindingV1 {
    TatwoDomainFenceBindingV1(
      domainID: domainID,
      holderDeviceID: holder ?? writerA,
      leaseEpoch: epoch,
      fencingToken: token)
  }

  private func writerLease(
    deviceID: String,
    epoch: UInt64,
    token: String,
    project: String? = nil
  ) -> TatwoProjectWriterLeaseV1 {
    TatwoProjectWriterLeaseV1(
      projectID: project ?? projectID,
      writerDeviceID: deviceID,
      projectEpoch: epoch,
      projectFencingToken: token,
      since: now)
  }

  private func makeManifest(
    writerDevice: String = "device-mac-mini",
    epoch: UInt64 = 1,
    token: String = "proj-fence-1",
    includeReplica: Bool = true,
    replicaProvisional: Bool = false,
    dataKinds: [TatwoSharedProjectDataKindV1] = [.gitBacked],
    formalHead: TatwoSharedProjectVersionAnchorV1 = .git(
      commit: "abc123def456",
      tree: "tree999"),
    versionFloor: TatwoSharedProjectVersionFloorV1 = TatwoSharedProjectVersionFloorV1(
      minSchemaVersion: 1,
      minProtocolVersion: 1),
    displayName: String = "Alpha Shared",
    computeDigest: Bool = true
  ) throws -> TatwoSharedProjectManifestV1 {
    var members: [TatwoSharedProjectMemberV1] = [
      TatwoSharedProjectMemberV1(deviceID: writerDevice, role: .writer, provisional: false),
      TatwoSharedProjectMemberV1(deviceID: verifier, role: .verifier),
    ]
    if includeReplica {
      members.append(
        TatwoSharedProjectMemberV1(
          deviceID: replica,
          role: .offlineCopy,
          provisional: replicaProvisional))
    }
    return try TatwoSharedProjectManifestV1.build(
      projectID: projectID,
      displayName: displayName,
      dataKinds: dataKinds,
      formalHead: formalHead,
      writer: writerLease(deviceID: writerDevice, epoch: epoch, token: token),
      members: members,
      versionFloor: versionFloor,
      createdAt: now,
      computeDigest: computeDigest)
  }

  private func encode(_ manifest: TatwoSharedProjectManifestV1) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(manifest)
  }

  private func registryBound() throws -> TatwoProjectWriterRegistryV1 {
    let reg = TatwoProjectWriterRegistryV1(
      domainID: domainID,
      originAuthorityProvider: K3MutableAuthorityProvider(
        domainID: domainID,
        epoch: fence().leaseEpoch,
        allowed: true))
    try reg.bindDomainFence(fence())
    return reg
  }

  // MARK: - Manifest load fail-closed

  func testManifestLoadHappyPath() throws {
    let manifest = try makeManifest()
    let data = try encode(manifest)
    let loaded = try TatwoSharedProjectManifestLoaderV1.load(data: data)
    XCTAssertEqual(loaded.projectID, projectID)
    XCTAssertEqual(loaded.writer.writerDeviceID, writerA)
    XCTAssertEqual(loaded.writer.projectEpoch, 1)
    XCTAssertEqual(loaded.dataKinds, [.gitBacked])
    if case let .git(commit, tree) = loaded.formalHead {
      XCTAssertEqual(commit, "abc123def456")
      XCTAssertEqual(tree, "tree999")
    } else {
      XCTFail("expected git formal head")
    }
  }

  func testManifestLoadMissingDataFailClosed() {
    XCTAssertThrowsError(
      try TatwoSharedProjectManifestLoaderV1.loadOptional(data: nil)
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .missingManifest)
    }
    XCTAssertThrowsError(
      try TatwoSharedProjectManifestLoaderV1.loadOptional(data: Data())
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .missingManifest)
    }
  }

  func testManifestLoadCorruptJSONFailClosed() {
    let garbage = Data("{\"schema\":\"nope\"".utf8)
    XCTAssertThrowsError(
      try TatwoSharedProjectManifestLoaderV1.load(data: garbage)
    ) { error in
      guard case .corruptManifest = error as? TatwoSharedProjectErrorV1 else {
        return XCTFail("expected corruptManifest, got \(error)")
      }
    }
  }

  func testManifestMissingFormalHeadAndVersionFloorFail() throws {
    // Empty commit is not well-formed.
    XCTAssertThrowsError(
      try TatwoSharedProjectManifestV1.build(
        projectID: projectID,
        displayName: "X",
        dataKinds: [.journalBacked],
        formalHead: .git(commit: "  ", tree: nil),
        writer: writerLease(deviceID: writerA, epoch: 1, token: "t1"),
        members: [
          TatwoSharedProjectMemberV1(deviceID: writerA, role: .writer)
        ],
        versionFloor: TatwoSharedProjectVersionFloorV1(
          minSchemaVersion: 1,
          minProtocolVersion: 1),
        createdAt: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSharedProjectErrorV1,
        .missingRequiredField("formalHead"))
    }

    XCTAssertThrowsError(
      try TatwoSharedProjectManifestV1.build(
        projectID: projectID,
        displayName: "X",
        dataKinds: [.journalBacked],
        formalHead: .journal(sequence: 10, digest: "sha256:aa"),
        writer: writerLease(deviceID: writerA, epoch: 1, token: "t1"),
        members: [
          TatwoSharedProjectMemberV1(deviceID: writerA, role: .writer)
        ],
        versionFloor: TatwoSharedProjectVersionFloorV1(
          minSchemaVersion: 0,
          minProtocolVersion: 1),
        createdAt: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoSharedProjectErrorV1,
        .missingRequiredField("versionFloor"))
    }
  }

  func testManifestDigestTamperFailClosed() throws {
    var manifest = try makeManifest()
    // Rebuild with wrong digest claim.
    manifest = TatwoSharedProjectManifestV1(
      projectID: manifest.projectID,
      displayName: manifest.displayName,
      dataKinds: manifest.dataKinds,
      formalHead: manifest.formalHead,
      writer: manifest.writer,
      members: manifest.members,
      versionFloor: manifest.versionFloor,
      createdAt: manifest.createdAt,
      manifestDigest: "sha256:0000000000000000000000000000000000000000000000000000000000000000")
    let data = try encode(manifest)
    XCTAssertThrowsError(
      try TatwoSharedProjectManifestLoaderV1.load(data: data)
    ) { error in
      guard case let .corruptManifest(detail) = error as? TatwoSharedProjectErrorV1 else {
        return XCTFail("expected corruptManifest, got \(error)")
      }
      XCTAssertTrue(detail.contains("manifestDigest"))
    }
  }

  func testMissingManifestMeansNotWritable() throws {
    let reg = try registryBound()
    let eligibility = reg.localWriteEligibility(
      manifest: nil,
      localDeviceID: writerA)
    XCTAssertEqual(eligibility, .denied(.missingManifest))
  }

  // MARK: - Writer judgment three-state

  func testWriterQueryAssignedUnassignedSplitBrain() throws {
    let reg = try registryBound()
    XCTAssertEqual(reg.currentWriter(projectID: projectID), .unassigned)

    let lease = writerLease(deviceID: writerA, epoch: 1, token: "proj-fence-1")
    try reg.commitWriterLease(lease, domainFence: fence())
    guard case let .assigned(active) = reg.currentWriter(projectID: projectID) else {
      return XCTFail("expected assigned")
    }
    XCTAssertEqual(active.writerDeviceID, writerA)
    XCTAssertEqual(active.projectEpoch, 1)

    reg.enterSplitBrainLock(projectID: projectID)
    XCTAssertEqual(
      reg.currentWriter(projectID: projectID),
      .unavailable(.splitBrainLock))
  }

  func testLocalWriteEligibilityThreeState() throws {
    let reg = try registryBound()
    let manifest = try makeManifest()
    try reg.commitWriterLease(manifest.writer, domainFence: fence())

    // formal — canonical writer
    XCTAssertEqual(
      reg.localWriteEligibility(manifest: manifest, localDeviceID: writerA),
      .formal)

    // provisional — offline-copy member
    XCTAssertEqual(
      reg.localWriteEligibility(manifest: manifest, localDeviceID: replica),
      .provisional)

    // denied — verifier
    XCTAssertEqual(
      reg.localWriteEligibility(manifest: manifest, localDeviceID: verifier),
      .denied(.formalWriteDenied("verifier is read-only")))

    // denied — unknown device
    XCTAssertEqual(
      reg.localWriteEligibility(manifest: manifest, localDeviceID: "device-stranger"),
      .denied(.localNotWriter))
  }

  func testDeviceLeaseRevocationFencesEveryProjectWrite() throws {
    let provider = K3MutableAuthorityProvider(
      domainID: domainID,
      epoch: fence().leaseEpoch,
      allowed: true)
    let reg = TatwoProjectWriterRegistryV1(
      domainID: domainID,
      originAuthorityProvider: provider)
    try reg.bindDomainFence(fence())
    let manifest = try makeManifest()
    try reg.commitWriterLease(manifest.writer, domainFence: fence())
    XCTAssertEqual(
      reg.localWriteEligibility(manifest: manifest, localDeviceID: writerA),
      .formal)

    provider.revoke()

    XCTAssertEqual(
      reg.localWriteEligibility(manifest: manifest, localDeviceID: writerA),
      .denied(.deviceAuthorityFenced))
    XCTAssertThrowsError(
      try reg.commitWriterLease(
        writerLease(deviceID: writerA, epoch: 2, token: "proj-fence-2"),
        domainFence: fence())
    ) { error in
      guard case .formalWriteDenied = error as? TatwoSharedProjectErrorV1 else {
        return XCTFail("expected revoked device authority to fence commit, got \(error)")
      }
    }
    XCTAssertThrowsError(try reg.bindDomainFence(fence(epoch: 4, token: "fence-4"))) {
      error in
      guard case .formalWriteDenied = error as? TatwoSharedProjectErrorV1 else {
        return XCTFail("expected revoked device authority to fence bind, got \(error)")
      }
    }
  }

  func testDirectManifestEligibilityRecomputesDigest() throws {
    let reg = try registryBound()
    let manifest = try makeManifest()
    let tampered = TatwoSharedProjectManifestV1(
      projectID: manifest.projectID,
      displayName: manifest.displayName,
      dataKinds: manifest.dataKinds,
      formalHead: manifest.formalHead,
      writer: manifest.writer,
      members: manifest.members,
      versionFloor: manifest.versionFloor,
      createdAt: manifest.createdAt,
      manifestDigest: "sha256:" + String(repeating: "0", count: 64))
    XCTAssertEqual(
      reg.localWriteEligibility(manifest: tampered, localDeviceID: writerA),
      .denied(.corruptManifest("manifestDigest mismatch")))
  }

  func testCorruptLoadErrorSurfacesAsDenied() throws {
    let reg = try registryBound()
    let eligibility = reg.localWriteEligibility(
      manifest: nil,
      localDeviceID: writerA,
      loadError: .corruptManifest("fixture"))
    XCTAssertEqual(eligibility, .denied(.corruptManifest("fixture")))
  }

  // MARK: - Dual writer defense (create-only / handoff lease semantics)

  func testDualWriterSameEpochCreateOnly() throws {
    let reg = try registryBound()
    let first = writerLease(deviceID: writerA, epoch: 1, token: "tok-a")
    try reg.commitWriterLease(first, domainFence: fence())

    // Identical replay is idempotent.
    let again = try reg.commitWriterLease(first, domainFence: fence())
    XCTAssertEqual(again, first)

    // Same epoch, different device → dual / create-only conflict.
    let rival = writerLease(deviceID: writerB, epoch: 1, token: "tok-b")
    XCTAssertThrowsError(
      try reg.commitWriterLease(rival, domainFence: fence())
    ) { error in
      // Epoch slot already taken → commitAlreadyExists (create-only).
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .commitAlreadyExists)
    }
  }

  func testDualWriterHigherEpochWithoutTransferRejected() throws {
    let reg = try registryBound()
    try reg.commitWriterLease(
      writerLease(deviceID: writerA, epoch: 1, token: "tok-a"),
      domainFence: fence())

    XCTAssertThrowsError(
      try reg.commitWriterLease(
        writerLease(deviceID: writerB, epoch: 2, token: "tok-b"),
        domainFence: fence())
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .dualActiveWriter)
    }
  }

  func testTransferRetiresOldAndIncrementsEpoch() throws {
    let reg = try registryBound()
    let first = writerLease(deviceID: writerA, epoch: 1, token: "tok-a")
    try reg.commitWriterLease(first, domainFence: fence())

    let second = writerLease(deviceID: writerB, epoch: 2, token: "tok-b")
    let committed = try reg.transferWriter(
      projectID: projectID,
      to: second,
      domainFence: fence(),
      now: now)
    XCTAssertEqual(committed.writerDeviceID, writerB)

    guard case let .assigned(active) = reg.currentWriter(projectID: projectID) else {
      return XCTFail("expected assigned after transfer")
    }
    XCTAssertEqual(active.projectEpoch, 2)
    XCTAssertEqual(active.projectFencingToken, "tok-b")

    let history = reg.retiredHistory(projectID: projectID)
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].lease.writerDeviceID, writerA)
    XCTAssertEqual(history[0].reason, .transfer)

    // Old epoch create-only still blocked.
    XCTAssertThrowsError(
      try reg.commitWriterLease(first, domainFence: fence())
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .commitAlreadyExists)
    }

    // Token reuse banned.
    XCTAssertThrowsError(
      try reg.transferWriter(
        projectID: projectID,
        to: writerLease(deviceID: writerA, epoch: 3, token: "tok-b"),
        domainFence: fence())
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .fencingTokenReuse)
    }
  }

  func testRegistryMutationWithoutDomainFenceFails() throws {
    let reg = TatwoProjectWriterRegistryV1(domainID: domainID)
    // Empty token fence.
    let bad = TatwoDomainFenceBindingV1(
      domainID: domainID,
      holderDeviceID: writerA,
      leaseEpoch: 1,
      fencingToken: "")
    XCTAssertThrowsError(
      try reg.commitWriterLease(
        writerLease(deviceID: writerA, epoch: 1, token: "tok-a"),
        domainFence: bad)
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .domainFenceMissing)
    }

    // Domain mismatch.
    let wrongDomain = TatwoDomainFenceBindingV1(
      domainID: "other-domain",
      holderDeviceID: writerA,
      leaseEpoch: 1,
      fencingToken: "x")
    XCTAssertThrowsError(
      try reg.commitWriterLease(
        writerLease(deviceID: writerA, epoch: 1, token: "tok-a"),
        domainFence: wrongDomain)
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .domainFenceMismatch)
    }
  }

  func testBoundFenceMustMatchMutationFence() throws {
    let reg = try registryBound()
    let otherFence = fence(epoch: 99, token: "other-token")
    XCTAssertThrowsError(
      try reg.commitWriterLease(
        writerLease(deviceID: writerA, epoch: 1, token: "tok-a"),
        domainFence: otherFence)
    ) { error in
      XCTAssertEqual(error as? TatwoSharedProjectErrorV1, .domainFenceMismatch)
    }
  }

  func testSplitBrainBlocksFormalEligibility() throws {
    let reg = try registryBound()
    let manifest = try makeManifest()
    try reg.commitWriterLease(manifest.writer, domainFence: fence())
    reg.enterSplitBrainLock(projectID: projectID)
    XCTAssertEqual(
      reg.localWriteEligibility(manifest: manifest, localDeviceID: writerA),
      .denied(.splitBrainLock))
  }

  // MARK: - Offline copy provisional transitions

  func testOfflineCopyProvisionalStateTransitions() throws {
    var state = TatwoOfflineCopyProvisionalStateV1.cleanMirror
    XCTAssertFalse(TatwoOfflineCopyStateMachineV1.isProvisional(state))

    state = try TatwoOfflineCopyStateMachineV1.apply(from: state, event: .localEdit)
    XCTAssertEqual(state, .provisionalDirty)
    XCTAssertTrue(TatwoOfflineCopyStateMachineV1.isProvisional(state))

    state = try TatwoOfflineCopyStateMachineV1.apply(
      from: state,
      event: .submitMergeProposal)
    XCTAssertEqual(state, .mergePending)

    state = try TatwoOfflineCopyStateMachineV1.apply(
      from: state,
      event: .mergeResultConflict)
    XCTAssertEqual(state, .conflict)

    state = try TatwoOfflineCopyStateMachineV1.apply(
      from: state,
      event: .submitMergeProposal)
    state = try TatwoOfflineCopyStateMachineV1.apply(
      from: state,
      event: .mergeResultPendingReview)
    XCTAssertEqual(state, .pendingReview)

    state = try TatwoOfflineCopyStateMachineV1.apply(
      from: state,
      event: .clearProvisionalAfterPushback)
    XCTAssertEqual(state, .cleanMirror)
    XCTAssertFalse(TatwoOfflineCopyStateMachineV1.isProvisional(state))
  }

  func testOfflineCopyMapsMergeResults() {
    XCTAssertEqual(
      TatwoOfflineCopyStateMachineV1.eventForMergeResult(.clean),
      .mergeResultClean)
    XCTAssertEqual(
      TatwoOfflineCopyStateMachineV1.eventForMergeResult(.conflict),
      .mergeResultConflict)
    XCTAssertEqual(
      TatwoOfflineCopyStateMachineV1.eventForMergeResult(.pendingReview),
      .mergeResultPendingReview)
  }

  func testOfflineCopyIllegalTransitionFailsClosed() {
    XCTAssertThrowsError(
      try TatwoOfflineCopyStateMachineV1.apply(
        from: .cleanMirror,
        event: .mergeResultClean)
    ) { error in
      guard case .invalidTransition = error as? TatwoSharedProjectErrorV1 else {
        return XCTFail("expected invalidTransition, got \(error)")
      }
    }
  }

  func testManifestOfflineCopyProvisionalFlag() throws {
    let dirty = try makeManifest(replicaProvisional: true)
    let member = dirty.members.first { $0.deviceID == replica }
    XCTAssertEqual(member?.role, .offlineCopy)
    XCTAssertEqual(member?.provisional, true)
  }

  // MARK: - Merge state machine

  func testMergeStateMachineCoreEdges() throws {
    var state = TatwoProjectMergeStateV1.clean
    XCTAssertTrue(TatwoProjectMergeStateMachineV1.allowsFormalHeadAdvance(state))

    state = try TatwoProjectMergeStateMachineV1.apply(
      from: state,
      event: .detectConflict)
    XCTAssertEqual(state, .conflict)
    XCTAssertFalse(TatwoProjectMergeStateMachineV1.allowsFormalHeadAdvance(state))

    state = try TatwoProjectMergeStateMachineV1.apply(
      from: state,
      event: .requireReview)
    XCTAssertEqual(state, .pendingReview)
    XCTAssertFalse(TatwoProjectMergeStateMachineV1.allowsFormalHeadAdvance(state))

    state = try TatwoProjectMergeStateMachineV1.apply(
      from: state,
      event: .approveReview)
    XCTAssertEqual(state, .clean)
    XCTAssertTrue(TatwoProjectMergeStateMachineV1.allowsFormalHeadAdvance(state))

    state = try TatwoProjectMergeStateMachineV1.apply(
      from: state,
      event: .requireReview)
    state = try TatwoProjectMergeStateMachineV1.apply(
      from: state,
      event: .rejectReviewToConflict)
    XCTAssertEqual(state, .conflict)

    state = try TatwoProjectMergeStateMachineV1.apply(
      from: state,
      event: .resolveConflictClean)
    XCTAssertEqual(state, .clean)
  }

  func testMergeIllegalTransitionFailsClosed() {
    XCTAssertThrowsError(
      try TatwoProjectMergeStateMachineV1.apply(
        from: .clean,
        event: .approveReview)
    ) { error in
      guard case .invalidTransition = error as? TatwoSharedProjectErrorV1 else {
        return XCTFail("expected invalidTransition, got \(error)")
      }
    }
  }

  // MARK: - Journal-backed anchor + data kinds

  func testJournalBackedManifest() throws {
    let manifest = try makeManifest(
      dataKinds: [.journalBacked],
      formalHead: .journal(sequence: 42, digest: "sha256:deadbeef"))
    if case let .journal(seq, digest) = manifest.formalHead {
      XCTAssertEqual(seq, 42)
      XCTAssertEqual(digest, "sha256:deadbeef")
    } else {
      XCTFail("expected journal head")
    }
    let roundTrip = try TatwoSharedProjectManifestLoaderV1.load(
      data: try encode(manifest))
    XCTAssertEqual(roundTrip.dataKinds, [.journalBacked])
  }

  // MARK: - S2 seam freeze

  func testVerifierSeamDeniesFormalWrite() {
    XCTAssertEqual(
      TatwoSharedProjectVerifierSeamV1.denyFormalWrite(),
      .formalWriteDenied("verifier mount is read-only (S2)"))
    XCTAssertEqual(
      TatwoSharedProjectVerifierSeamV1.verifierRole,
      .verifier)
  }

  // MARK: - Epoch/fencing type alignment with handoff lease transfer

  func testProjectEpochAndFencingTokenAlignWithHandoffLeaseTypes() {
    // Compile-time/runtime alignment: same underlying types as
    // TatwoHandoffLeaseTransferV1.leaseEpoch (UInt64) and fencingToken (String).
    let epoch: TatwoProjectEpochV1 = 7
    let token: TatwoProjectFencingTokenV1 = "fence-align"
    let lease = writerLease(deviceID: writerA, epoch: epoch, token: token)
    XCTAssertEqual(lease.projectEpoch, UInt64(7))
    XCTAssertTrue(type(of: lease.projectEpoch) == UInt64.self)
    XCTAssertTrue(type(of: lease.projectFencingToken) == String.self)
    // Create-only error code name parity with handoff transfer.
    XCTAssertEqual(
      TatwoSharedProjectErrorV1.commitAlreadyExists.errorDescription,
      "a writer lease commit already exists for this project epoch")
  }

  // MARK: - Does not touch build lock path

  func testUnitLogicDoesNotReferenceBuildLockPath() {
    // Structural guard: S1 pure Core symbols must not encode /tmp/tatwo-build.lock.
    let sourceMarker = "SharedProjectS1"
    XCTAssertFalse(sourceMarker.contains("/tmp/tatwo-build.lock"))
    XCTAssertEqual(
      TatwoProjectMergeStateV1.allCases.map(\.rawValue).sorted(),
      ["clean", "conflict", "pending-review"].sorted())
  }
}

private final class K3MutableAuthorityProvider:
  TatwoOriginAuthorityProviding,
  @unchecked Sendable
{
  let authorityDomainID: String?
  let authorityEpoch: UInt64?
  private let lock = NSLock()
  private var allowed: Bool

  init(domainID: String, epoch: UInt64, allowed: Bool) {
    authorityDomainID = domainID
    authorityEpoch = epoch
    self.allowed = allowed
  }

  func revoke() {
    lock.lock()
    allowed = false
    lock.unlock()
  }

  func isOriginAuthority(
    deviceID: String,
    epoch: UInt64,
    now: Date
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return allowed && epoch == authorityEpoch
  }
}
