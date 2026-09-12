import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDeviceAdoptionV1Tests: XCTestCase {
  private struct StubInFlightJobSource: TatwoInFlightJobSource {
    let jobs: [TatwoDeviceAdoptionInFlightJobV1]

    func inFlightJobs(forDevice deviceID: String) throws
      -> [TatwoDeviceAdoptionInFlightJobV1]
    {
      jobs
    }
  }

  private let now = Date(timeIntervalSince1970: 1_800_100_000)
  private let primary = "mini-primary"
  private let epoch: UInt64 = 3
  private let testEnvironment = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
  private let deviceID = "peer-mac-b"
  private let fingerprint =
    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  // MARK: - Fixtures

  private func stableDevice(
    fingerprint: String? = nil
  ) -> TatwoDiscoveredDeviceV1 {
    TatwoDiscoveredDeviceV1(
      transport: .thunderbolt,
      name: "Peer-Mac-B",
      identityFingerprint: fingerprint ?? self.fingerprint,
      interfaces: ["thunderbolt"],
      capabilitiesObserved: [],
      trustState: TatwoDiscoveredDeviceV1.requiredTrustState)
  }

  private func unstableDevice() -> TatwoDiscoveredDeviceV1 {
    TatwoDiscoveredDeviceV1(
      transport: .usb,
      name: "Unknown-Hub",
      identityFingerprint:
        "unstable:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      interfaces: ["usb"],
      trustState: TatwoDiscoveredDeviceV1.requiredTrustState)
  }

  private func makeTrust(deviceID: String? = nil) throws -> TatwoLoopJobChannelTrust {
    try TatwoLoopJobChannelTrust.enroll(
      deviceID: deviceID ?? self.deviceID,
      privateKeyStore: AdoptionMemoryPrivateKeyStore(),
      pinnedAt: now,
      environment: testEnvironment)
  }

  private func listDirDescriptor(
    risk: TatwoMutualControlRiskLevelV1 = .normal,
    highRisk: TatwoMutualControlHighRiskCategoryV1? = nil
  ) -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "fs.list_dir",
      displayName: "List directory",
      executable: "/bin/ls",
      argvTemplate: ["-la", "{path}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "path",
          constraint: .pathPrefix(["/tmp/adopt"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 30,
        maxOutputBytes: 64_000),
      riskLevel: risk,
      highRiskCategory: highRisk,
      sideEffectClass: .readOnly,
      enabled: true)
  }

  private func doctorDescriptor() -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "tatwo.doctor.json",
      executable: "/usr/local/bin/tatwo-ultrawork",
      argvTemplate: ["doctor", "--format", "{format}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "format",
          constraint: .enumValues(["json", "text"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 15,
        maxOutputBytes: 32_000),
      riskLevel: .normal,
      sideEffectClass: .readOnly)
  }

  private func deleteDescriptor() -> TatwoDeviceCapabilityDescriptorV1 {
    TatwoDeviceCapabilityDescriptorV1(
      templateID: "fs.trash_path",
      displayName: "Trash path",
      executable: "/usr/bin/trash",
      argvTemplate: ["{path}"],
      paramSlots: [
        TatwoMutualControlParamSlotV1(
          name: "path",
          constraint: .pathPrefix(["/tmp/adopt"]))
      ],
      resourceLimits: TatwoMutualControlResourceLimitsV1(
        timeoutSec: 60,
        maxOutputBytes: 8_192),
      riskLevel: .highRisk,
      highRiskCategory: .delete,
      sideEffectClass: .localMutable,
      enabled: true)
  }

  private func signedManifest(
    trust: TatwoLoopJobChannelTrust,
    descriptors: [TatwoDeviceCapabilityDescriptorV1],
    version: UInt64 = 1
  ) throws -> TatwoDeviceCapabilityManifestV1 {
    try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: trust.localIdentity.deviceID,
      capabilityVersion: version,
      descriptors: descriptors,
      producedAt: now,
      trust: trust)
  }

  private func unsignedManifest(
    deviceID: String,
    descriptors: [TatwoDeviceCapabilityDescriptorV1]
  ) throws -> TatwoDeviceCapabilityManifestV1 {
    // Intentionally no trust → no producerSignature.
    try TatwoDeviceCapabilityManifestV1.make(
      targetDeviceID: deviceID,
      capabilityVersion: 1,
      descriptors: descriptors,
      producedAt: now,
      trust: nil)
  }

  private func pairedSession(
    device: TatwoDiscoveredDeviceV1? = nil,
    seed: String = "ADOPT001"
  ) throws -> (session: TatwoDevicePairingSessionV1, proof: TatwoDevicePairingProofV1) {
    let begun = try TatwoDevicePairingFacadeV1.beginPairing(
      device: device ?? stableDevice(),
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: seed)
    var session = begun.session
    try session.apply(.verifyPairingCode(seed: seed), now: now.addingTimeInterval(1))
    try session.apply(.completePairing, now: now.addingTimeInterval(2))
    guard let proof = session.pairingProof else {
      throw NSError(domain: "test", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "paired session missing proof",
      ])
    }
    return (session, proof)
  }

  private func adoptHappy(
    descriptors: [TatwoDeviceCapabilityDescriptorV1]? = nil,
    seed: String = "ADOPT001"
  ) throws -> (
    adoption: TatwoDeviceAdoptionRecordV1,
    session: TatwoDevicePairingSessionV1,
    trust: TatwoLoopJobChannelTrust
  ) {
    let trust = try makeTrust()
    var pair = try pairedSession(seed: seed)
    let caps = descriptors ?? [listDirDescriptor(), doctorDescriptor()]
    let manifest = try signedManifest(trust: trust, descriptors: caps)
    let adoption = try TatwoDeviceAdoptionV1.adopt(
      session: &pair.session,
      pairingProof: pair.proof,
      capabilityManifest: manifest,
      pinnedIdentity: trust.localIdentity,
      pinReference: "pin-ref:\(deviceID):gen-1",
      now: now.addingTimeInterval(10))
    return (adoption, pair.session, trust)
  }

  // MARK: - Four adoption forces

  func testAdoptRejectsMissingPairingProofOnUnpairedSession() throws {
    let trust = try makeTrust()
    let device = stableDevice()
    var session = TatwoDevicePairingSessionV1(
      device: device,
      authorityPrimary: primary,
      authorityEpoch: epoch)
    // Internal forge of a proof for adversarial shape; session has no real proof.
    let forged = TatwoDevicePairingProofV1(
      verificationDigest: "sha256:forged",
      verifiedAt: now,
      deviceFingerprint: fingerprint)
    let manifest = try signedManifest(trust: trust, descriptors: [listDirDescriptor()])
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.adopt(
        session: &session,
        pairingProof: forged,
        capabilityManifest: manifest,
        pinnedIdentity: trust.localIdentity,
        pinReference: "pin-ref:x",
        now: now)
    ) { error in
      let err = error as? TatwoDeviceAdoptionErrorV1
      XCTAssertTrue(
        err == .sessionNotPaired(.discovered)
          || err == .pairingProofMissing
          || err == .pairingProofInvalid,
        "expected pairing force reject, got \(String(describing: error))")
    }
  }

  func testAdoptRejectsMismatchedPairingProof() throws {
    let trust = try makeTrust()
    var pair = try pairedSession(seed: "PROOFBAD")
    let forged = TatwoDevicePairingProofV1(
      verificationDigest: "sha256:not-the-real-proof",
      verifiedAt: pair.proof.verifiedAt,
      deviceFingerprint: pair.proof.deviceFingerprint)
    let manifest = try signedManifest(trust: trust, descriptors: [listDirDescriptor()])
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.adopt(
        session: &pair.session,
        pairingProof: forged,
        capabilityManifest: manifest,
        pinnedIdentity: trust.localIdentity,
        pinReference: "pin-ref:x",
        now: now)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceAdoptionErrorV1, .pairingProofInvalid)
    }
    XCTAssertFalse(pair.session.canBeManaged)
  }

  func testAdoptRejectsUnsignedCapabilityDeclaration() throws {
    var pair = try pairedSession(seed: "UNSIGN01")
    let unsigned = try unsignedManifest(
      deviceID: deviceID,
      descriptors: [listDirDescriptor()])
    XCTAssertNil(unsigned.producerSignature)
    // Need a pinned identity; use trust identity that matches deviceID but
    // signature is still missing on the unsigned manifest.
    let trust = try makeTrust()
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.adopt(
        session: &pair.session,
        pairingProof: pair.proof,
        capabilityManifest: unsigned,
        pinnedIdentity: trust.localIdentity,
        pinReference: "pin-ref:x",
        now: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDeviceAdoptionErrorV1,
        .capabilityDeclarationUnsigned)
    }
  }

  func testAdoptRejectsUnstableIdentityFingerprint() throws {
    let trust = try makeTrust()
    // Unstable cannot even complete pairing; force the adoption gate directly
    // by constructing a session that somehow got past pairing is impossible via
    // public facade — verify pairing rejects, and adoption would too if given
    // an unstable device on a session.
    XCTAssertThrowsError(
      try TatwoDevicePairingFacadeV1.beginPairing(
        device: unstableDevice(),
        authorityPrimary: primary,
        authorityEpoch: epoch,
        now: now,
        seed: "UNSTAB01")
    ) { error in
      XCTAssertEqual(
        error as? TatwoDevicePairingErrorV1,
        .unstableIdentityForbidden(unstableDevice().identityFingerprint))
    }

    // Direct adoption path: internal session with unstable device (discovered only).
    var session = TatwoDevicePairingSessionV1(
      device: unstableDevice(),
      authorityPrimary: primary,
      authorityEpoch: epoch)
    let fakeProof = TatwoDevicePairingProofV1(
      verificationDigest: "sha256:x",
      verifiedAt: now,
      deviceFingerprint: unstableDevice().identityFingerprint)
    let manifest = try signedManifest(trust: trust, descriptors: [])
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.adopt(
        session: &session,
        pairingProof: fakeProof,
        capabilityManifest: manifest,
        pinnedIdentity: trust.localIdentity,
        pinReference: "pin-ref:x",
        now: now)
    ) { error in
      guard let err = error as? TatwoDeviceAdoptionErrorV1,
        case let .unstableIdentityForbidden(fp) = err
      else {
        return XCTFail("expected unstableIdentityForbidden, got \(error)")
      }
      XCTAssertTrue(fp.hasPrefix("unstable:"))
    }
  }

  func testAdoptDoesNotGrantHighRiskStandingAuthorization() throws {
    let result = try adoptHappy(
      descriptors: [listDirDescriptor(), deleteDescriptor()],
      seed: "HIRISK01")
    XCTAssertFalse(result.adoption.grantsHighRiskStandingAuthorization)
    XCTAssertTrue(result.adoption.containsHighRiskCapabilities)
    // K2 semantics: high_risk descriptor still requires per-invocation human gate.
    let high = result.adoption.capabilityDescriptors.first { $0.templateID == "fs.trash_path" }
    XCTAssertEqual(high?.riskLevel, .highRisk)
    XCTAssertEqual(high?.requiresHumanGate, true)
    XCTAssertTrue(result.session.canBeManaged)
    XCTAssertEqual(result.adoption.state, .adopted)
    XCTAssertEqual(result.adoption.pinStatus, .active)
    XCTAssertEqual(result.adoption.revocationEpoch, 0)
    XCTAssertNoThrow(
      try TatwoDeviceAdoptionV1.verifyAdoptionProof(
        result.adoption.adoptionProof,
        against: result.adoption))
  }

  // MARK: - Revoke / epoch / old proof

  func testRevokeVoidsPinClearsCapabilitiesAndRejectsOldProof() throws {
    let happy = try adoptHappy(seed: "REVOKE01")
    let oldProof = happy.adoption.adoptionProof
    let priorDigest = happy.adoption.capabilitySetDigest
    XCTAssertFalse(priorDigest.isEmpty)

    let inFlight = [
      TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: "logical-1",
        jobID: "job-1",
        targetDeviceID: deviceID,
        leaseState: .running,
        dispatchNonce: "nonce-1"),
      TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: "logical-2",
        jobID: "job-2",
        targetDeviceID: deviceID,
        leaseState: .accepted,
        dispatchNonce: "nonce-2"),
      TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: "logical-other",
        jobID: "job-3",
        targetDeviceID: "other-device",
        leaseState: .running,
        dispatchNonce: "nonce-3"),
      TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: "logical-done",
        jobID: "job-4",
        targetDeviceID: deviceID,
        leaseState: .completed,
        dispatchNonce: "nonce-4"),
    ]

    let revoked = try TatwoDeviceAdoptionV1.revoke(
      happy.adoption,
      reason: "operator removed trust",
      source: StubInFlightJobSource(jobs: inFlight),
      now: now.addingTimeInterval(60))

    XCTAssertEqual(revoked.adoption.state, .revoked)
    XCTAssertEqual(revoked.adoption.pinStatus, .revoked)
    XCTAssertTrue(revoked.adoption.isPinVoided)
    XCTAssertTrue(revoked.adoption.capabilityDescriptors.isEmpty)
    XCTAssertEqual(revoked.revocation.voidedCapabilitySetDigest, priorDigest)
    XCTAssertEqual(revoked.revocation.reason, "operator removed trust")
    XCTAssertEqual(revoked.revocation.priorRevocationEpoch, 0)
    XCTAssertEqual(revoked.revocation.newRevocationEpoch, 1)
    XCTAssertEqual(revoked.adoption.revocationEpoch, 1)

    // Residual jobs: in-progress for this device only; not killed, just listed.
    let residualIDs = Set(revoked.residualJobsToInvalidate.map(\.logicalJobID))
    XCTAssertEqual(residualIDs, Set(["logical-1", "logical-2"]))
    XCTAssertEqual(revoked.revocation.residualJobsToInvalidate.count, 2)

    // Old adoptionProof rejected.
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.verifyAdoptionProof(oldProof, against: revoked.adoption)
    ) { error in
      let err = error as? TatwoDeviceAdoptionErrorV1
      XCTAssertTrue(
        err == .adoptionRevoked
          || {
            if case .adoptionProofEpochMismatch = err { return true }
            return false
          }(),
        "expected old proof reject, got \(String(describing: error))")
    }
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.requireActiveAdoption(revoked.adoption, proof: oldProof)
    )
  }

  func testRevocationEpochIsMonotonicAndCannotRegress() throws {
    let happy = try adoptHappy(seed: "EPOCH001")
    let r1 = try TatwoDeviceAdoptionV1.revoke(
      happy.adoption,
      reason: "first revoke",
      source: StubInFlightJobSource(jobs: []),
      now: now.addingTimeInterval(10))
    XCTAssertEqual(r1.adoption.revocationEpoch, 1)
    XCTAssertGreaterThan(r1.revocation.newRevocationEpoch, r1.revocation.priorRevocationEpoch)

    // Second revoke on already-voided pin fails (no epoch rollback path).
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.revoke(
        r1.adoption,
        reason: "again",
        source: StubInFlightJobSource(jobs: []),
        now: now.addingTimeInterval(11))
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceAdoptionErrorV1, .pinAlreadyVoided)
    }

    // Adversarial: forged proof with epoch rollback is rejected against live adopted.
    let live = try adoptHappy(seed: "EPOCH002")
    let rolledBack = TatwoDeviceAdoptionProofV1(
      proofDigest: live.adoption.adoptionProof.proofDigest,
      deviceID: live.adoption.deviceID,
      identityFingerprint: live.adoption.identityFingerprint,
      capabilitySetDigest: live.adoption.capabilitySetDigest,
      revocationEpoch: live.adoption.revocationEpoch &- 1, // would underflow to max if 0
      mintedAt: now)
    // For epoch 0, &- 1 wraps; still must not equal record epoch 0 equality path fails.
    if rolledBack.revocationEpoch != live.adoption.revocationEpoch {
      XCTAssertThrowsError(
        try TatwoDeviceAdoptionV1.verifyAdoptionProof(rolledBack, against: live.adoption)
      ) { error in
        let err = error as? TatwoDeviceAdoptionErrorV1
        XCTAssertTrue(
          err == .adoptionProofInvalid
            || {
              if case .adoptionProofEpochMismatch = err { return true }
              return false
            }(),
          "got \(String(describing: error))")
      }
    }
  }

  // MARK: - Downgrade shrink-only

  func testDowngradeAllowsStrictSubsetOnly() throws {
    let happy = try adoptHappy(
      descriptors: [listDirDescriptor(), doctorDescriptor(), deleteDescriptor()],
      seed: "DOWN0001")
    let proof = happy.adoption.adoptionProof
    let fromDigest = happy.adoption.capabilitySetDigest

    let down = try TatwoDeviceAdoptionV1.downgrade(
      happy.adoption,
      toTemplateIDs: ["fs.list_dir"],
      proof: proof,
      now: now.addingTimeInterval(20))

    XCTAssertEqual(down.adoption.state, .degraded)
    XCTAssertEqual(down.adoption.capabilityTemplateIDs, Set(["fs.list_dir"]))
    XCTAssertEqual(down.record.removedTemplateIDs.sorted(), ["fs.trash_path", "tatwo.doctor.json"])
    XCTAssertNotEqual(down.adoption.capabilitySetDigest, fromDigest)
    XCTAssertEqual(down.record.fromCapabilitySetDigest, fromDigest)
    XCTAssertEqual(down.record.toCapabilitySetDigest, down.adoption.capabilitySetDigest)
    // Pin remains active; epoch unchanged.
    XCTAssertEqual(down.adoption.pinStatus, .active)
    XCTAssertEqual(down.adoption.revocationEpoch, 0)
    XCTAssertFalse(down.adoption.grantsHighRiskStandingAuthorization)

    // Old proof (pre-downgrade digest) must fail against new record.
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.verifyAdoptionProof(proof, against: down.adoption)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceAdoptionErrorV1, .adoptionProofInvalid)
    }
    // New proof works.
    XCTAssertNoThrow(
      try TatwoDeviceAdoptionV1.verifyAdoptionProof(
        down.adoption.adoptionProof,
        against: down.adoption))
  }

  func testDowngradeExpansionRejected() throws {
    let happy = try adoptHappy(
      descriptors: [listDirDescriptor()],
      seed: "EXPAND01")
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.downgrade(
        happy.adoption,
        toTemplateIDs: ["fs.list_dir", "tatwo.doctor.json"],
        proof: happy.adoption.adoptionProof,
        now: now)
    ) { error in
      guard let err = error as? TatwoDeviceAdoptionErrorV1,
        case let .downgradeNotSubset(extra) = err
      else {
        return XCTFail("expected downgradeNotSubset, got \(error)")
      }
      XCTAssertEqual(extra, ["tatwo.doctor.json"])
    }
  }

  func testDowngradeIdenticalSetRejected() throws {
    let happy = try adoptHappy(
      descriptors: [listDirDescriptor(), doctorDescriptor()],
      seed: "SAME0001")
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.downgrade(
        happy.adoption,
        toTemplateIDs: happy.adoption.capabilityTemplateIDs,
        proof: happy.adoption.adoptionProof,
        now: now)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceAdoptionErrorV1, .downgradeRequiresShrink)
    }
  }

  func testDowngradeRejectedAfterRevokeWithOldProof() throws {
    let happy = try adoptHappy(seed: "POSTREV1")
    let oldProof = happy.adoption.adoptionProof
    let revoked = try TatwoDeviceAdoptionV1.revoke(
      happy.adoption,
      reason: "done",
      source: StubInFlightJobSource(jobs: []),
      now: now.addingTimeInterval(5))
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.downgrade(
        revoked.adoption,
        toTemplateIDs: [],
        proof: oldProof,
        now: now.addingTimeInterval(6))
    ) { error in
      let err = error as? TatwoDeviceAdoptionErrorV1
      XCTAssertTrue(
        err == .adoptionRevoked
          || {
            if case .adoptionProofEpochMismatch = err { return true }
            return false
          }()
          || err == .adoptionProofInvalid,
        "got \(String(describing: error))")
    }
  }

  // MARK: - Residual job listing

  func testRevokeReturnsResidualInFlightJobsOnly() throws {
    let happy = try adoptHappy(seed: "RESJOB01")
    let jobs = [
      TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: "L1",
        jobID: "A1",
        targetDeviceID: deviceID,
        leaseState: .running,
        dispatchNonce: "nonce-A1"),
      TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: "L2",
        jobID: "A2",
        targetDeviceID: deviceID,
        leaseState: .failed,
        dispatchNonce: "nonce-A2"),
      TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: "L3",
        jobID: "A3",
        targetDeviceID: "someone-else",
        leaseState: .running,
        dispatchNonce: "nonce-A3"),
    ]
    let result = try TatwoDeviceAdoptionV1.revoke(
      happy.adoption,
      reason: "inventory residual",
      source: StubInFlightJobSource(jobs: jobs),
      now: now)
    XCTAssertEqual(result.residualJobsToInvalidate.map(\.logicalJobID), ["L1"])
    // Origin disposal only — no kill API on the result type.
    XCTAssertEqual(
      result.residualJobsToInvalidate.first?.leaseState,
      .running)
  }

  func testRevokeRejectsResidualJobMissingAttemptBinding() throws {
    let happy = try adoptHappy(seed: "MISSBIND")
    let malformed = TatwoDeviceAdoptionInFlightJobV1(
      logicalJobID: "missing-nonce",
      jobID: "job-missing-nonce",
      targetDeviceID: deviceID,
      leaseState: .running,
      dispatchNonce: "")

    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.revoke(
        happy.adoption,
        reason: "reject malformed inventory",
        source: StubInFlightJobSource(jobs: [malformed]),
        now: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDeviceAdoptionErrorV1,
        .inFlightJobAttemptBindingMissing(jobID: "job-missing-nonce"))
    }
  }

  func testResidualJobStateIsTypedAndBindsJobIDAndDispatchNonce() throws {
    let source = try String(contentsOf: adoptionSourceURL(), encoding: .utf8)
    XCTAssertTrue(source.contains("leaseState: TatwoLoopJobStatusV1"))
    XCTAssertTrue(source.contains("public let dispatchNonce: String"))
    XCTAssertFalse(source.contains("leaseState: String"))
    XCTAssertFalse(source.contains("inFlightJobs: [TatwoDeviceAdoptionInFlightJobV1] ="))
  }

  func testProductionRegistrySourceReadsExistingRemoteStatus() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("adoption-registry-source-\(UUID().uuidString)")
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let job = TatwoLoopJobV1(
      jobID: "source-job",
      logicalJobID: "source-logical",
      dispatchNonce: "source-nonce",
      contractID: "source-contract",
      goalID: "source-goal",
      identity: .sub,
      originDeviceID: "source-origin",
      targetDeviceID: deviceID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: "/tmp/source",
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: now)
    _ = try registry.beginRemoteTestFixtureUnbound(job: job)
    _ = try registry.projectRemoteStatus(
      contractID: job.contractID,
      remoteJobID: job.jobID,
      remoteStatus: .running,
      now: now.addingTimeInterval(1))

    let source = TatwoDispatchRegistryInFlightJobSource(registry: registry)
    let jobs = try source.inFlightJobs(forDevice: deviceID)
    XCTAssertEqual(jobs.count, 1)
    XCTAssertEqual(jobs[0].jobID, job.jobID)
    XCTAssertEqual(jobs[0].dispatchNonce, job.dispatchNonce)
    XCTAssertEqual(jobs[0].leaseState, .running)
  }

  func testProductionRegistrySourceRejectsActiveRemoteRecordMissingNonce() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("adoption-registry-missing-nonce-\(UUID().uuidString)")
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let job = TatwoLoopJobV1(
      jobID: "missing-nonce-job",
      logicalJobID: "missing-nonce-logical",
      dispatchNonce: "missing-nonce-attempt",
      contractID: "missing-nonce-contract",
      goalID: "missing-nonce-goal",
      identity: .sub,
      originDeviceID: "missing-nonce-origin",
      targetDeviceID: deviceID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: "/tmp/missing-nonce",
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: now)
    _ = try registry.beginRemoteTestFixtureUnbound(job: job)
    _ = try registry.projectRemoteStatus(
      contractID: job.contractID,
      remoteJobID: job.jobID,
      remoteStatus: .running,
      now: now.addingTimeInterval(1))

    let url = try registry.fileURL(forContractID: job.contractID)
    var decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var run = try decoder.decode(
      TatwoStoredDispatchRun.self,
      from: Data(contentsOf: url))
    run.records[0].remoteDispatchNonce = nil
    var encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(run).write(to: url, options: .atomic)

    let source = TatwoDispatchRegistryInFlightJobSource(registry: registry)
    XCTAssertThrowsError(try source.inFlightJobs(forDevice: deviceID)) { error in
      XCTAssertEqual(
        error as? TatwoDeviceAdoptionErrorV1,
        .inFlightJobAttemptBindingMissing(jobID: job.jobID))
    }
  }

  // MARK: - Public construction boundary (API shape)

  func testAdoptedRecordPublicConstructionBoundary() throws {
    // API shape: adopted records are minted only via adopt (internal init).
    // @testable can see internal init — that is a same-module / same-process
    // DOCUMENTED_LIMIT (USERLAND_AUTHORITY_LIMITS), not a public API path.
    //
    // Public surface proof:
    // 1) Happy path yields a fully-formed record only through adopt.
    // 2) Forged proof (internal) is rejected by verify against a real adoption.
    let happy = try adoptHappy(seed: "BOUND001")
    XCTAssertEqual(happy.adoption.schema, TatwoDeviceAdoptionRecordV1.schemaName)
    XCTAssertFalse(happy.adoption.pinReference.isEmpty)
    XCTAssertFalse(happy.adoption.adoptionProof.proofDigest.isEmpty)

    let forgedProof = TatwoDeviceAdoptionProofV1(
      proofDigest: "sha256:forged-adoption",
      deviceID: happy.adoption.deviceID,
      identityFingerprint: happy.adoption.identityFingerprint,
      capabilitySetDigest: happy.adoption.capabilitySetDigest,
      revocationEpoch: 0,
      mintedAt: now)
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.verifyAdoptionProof(forgedProof, against: happy.adoption)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceAdoptionErrorV1, .adoptionProofInvalid)
    }

    // Direct internal record with mismatched proof fails verify.
    let rogue = TatwoDeviceAdoptionRecordV1(
      deviceID: happy.adoption.deviceID,
      identityFingerprint: happy.adoption.identityFingerprint,
      adoptedAt: now,
      capabilitySetDigest: happy.adoption.capabilitySetDigest,
      pinReference: happy.adoption.pinReference,
      adoptionProof: forgedProof,
      state: .adopted,
      pinStatus: .active,
      revocationEpoch: 0,
      capabilityDescriptors: happy.adoption.capabilityDescriptors)
    XCTAssertThrowsError(
      try TatwoDeviceAdoptionV1.verifyAdoptionProof(
        happy.adoption.adoptionProof,
        against: rogue)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceAdoptionErrorV1, .adoptionProofInvalid)
    }
  }

  func testHappyPathAdoptFields() throws {
    let happy = try adoptHappy(seed: "HAPPY001")
    let a = happy.adoption
    XCTAssertEqual(a.deviceID, deviceID)
    XCTAssertEqual(a.identityFingerprint, fingerprint)
    XCTAssertEqual(a.pinReference, "pin-ref:\(deviceID):gen-1")
    XCTAssertFalse(a.capabilitySetDigest.isEmpty)
    XCTAssertEqual(a.adoptionProof.deviceID, deviceID)
    XCTAssertEqual(a.adoptionProof.revocationEpoch, 0)
    XCTAssertEqual(a.capabilityDescriptors.count, 2)
    XCTAssertTrue(happy.session.canBeManaged)
  }

  private func adoptionSourceURL() -> URL {
    let thisFile = URL(fileURLWithPath: #filePath)
    let candidates = [
      thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
          "Sources/TatwoUltraworkCore/TatwoDeviceAdoptionV1.swift"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(
          "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoDeviceAdoptionV1.swift"),
    ]
    return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
      ?? candidates[0]
  }
}

// MARK: - Test key store (memory only; no Keychain)

private final class AdoptionMemoryPrivateKeyStore: TatwoDevicePrivateKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys["\(deviceID)#\(generation)"]
  }

  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    keys["\(deviceID)#\(generation)"] = key
  }
}
