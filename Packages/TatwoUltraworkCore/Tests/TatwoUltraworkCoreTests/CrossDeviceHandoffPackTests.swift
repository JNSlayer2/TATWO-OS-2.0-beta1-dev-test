import Foundation
import XCTest
import TatwoDomainContracts
import TatwoWorkReceiptContracts

@testable import TatwoUltraworkCore

final class CrossDeviceHandoffPackTests: XCTestCase {
  private let testEnvironment = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
  private let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
  private let sha256Hash = String(repeating: "a", count: 64)

  private func makeTrustPair() throws -> (
    origin: TatwoLoopJobChannelTrust,
    receiver: TatwoLoopJobChannelTrust
  ) {
    var origin = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "handoff-origin",
      privateKeyStore: HandoffMemoryPrivateKeyStore(),
      pinnedAt: createdAt,
      environment: testEnvironment)
    var receiver = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "handoff-receiver",
      privateKeyStore: HandoffMemoryPrivateKeyStore(),
      pinnedAt: createdAt,
      environment: testEnvironment)
    origin = try origin.withPin(receiver.localIdentity)
    receiver = try receiver.withPin(origin.localIdentity)
    return (origin, receiver)
  }

  private func makePack(
    trust: TatwoLoopJobChannelTrust,
    handoffID: String = "handoff-1",
    logicalJobID: String = "logical-1",
    jobID: String = "attempt-1",
    dispatchNonce: String = "nonce-1",
    freshnessWindow: TimeInterval = 900,
    receiptReferences: [TatwoHandoffReceiptReferenceV1]? = nil,
    requiredFiles: [TatwoHandoffRequiredFileV1]? = nil,
    toolchainFingerprint: String? = nil,
    requiredRunnerIDs: [String]? = nil,
    requiredLanes: [String]? = nil,
    goalDescription: String = "continue the goal"
  ) throws -> TatwoHandoffPackV1 {
    try TatwoHandoffPackV1.make(
      handoffID: handoffID,
      logicalJobID: logicalJobID,
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      goal: TatwoHandoffGoalV1(goalHash: sha256Hash, description: goalDescription),
      context: TatwoHandoffContextSummaryV1(summary: "context summary"),
      plan: TatwoHandoffPlanV1(planHash: sha256Hash, summary: "next plan step"),
      modificationState: TatwoHandoffModificationStateV1(
        branch: "feat/handoff",
        commit: sha256Hash,
        dirty: true,
        wipBranch: "wip/handoff-1",
        treeHash: sha256Hash),
      incompleteItems: [
        TatwoHandoffIncompleteItemV1(id: "todo-1", description: "finish verification")
      ],
      requiredFiles: requiredFiles ?? [
        TatwoHandoffRequiredFileV1(path: "Sources/Goal.swift", sha256: sha256Hash)
      ],
      sessionRoute: TatwoHandoffSessionRouteV1(
        engine: "codex",
        model: "gpt-5",
        route: "native-pane",
        sessionReference: "session-ref-1"),
      receiptReferences: receiptReferences ?? [
        TatwoHandoffReceiptReferenceV1(
          receiptID: "receipt-1",
          contentHash: sha256Hash,
          kind: "validation")
      ],
      riskHints: ["human gate required before lease transfer"],
      trust: trust,
      intendedReceiverDeviceID: "handoff-receiver",
      priorOriginDeviceID: trust.localIdentity.deviceID,
      requestedLeaseDomainID: "domain-1",
      toolchainFingerprint: toolchainFingerprint,
      requiredRunnerIDs: requiredRunnerIDs,
      requiredLanes: requiredLanes,
      createdAt: createdAt,
      freshnessWindow: freshnessWindow)
  }

  private func makeCapabilities(
    for pack: TatwoHandoffPackV1,
    projectCommit: String? = nil,
    projectTreeHash: String? = nil,
    swiftToolchainFingerprint: String? = nil,
    runnerAvailability: [String: Bool] = [:],
    permittedLanes: [String] = [],
    canRefetchFreshData: Bool = false,
    localWorktreeDirty: Bool = false
  ) -> TatwoHandoffReceiverCapabilitiesV1 {
    TatwoHandoffReceiverCapabilitiesV1(
      deviceID: "handoff-receiver",
      projectCommit: projectCommit ?? pack.commit,
      projectTreeHash: projectTreeHash ?? pack.modificationState.treeHash,
      swiftToolchainFingerprint: swiftToolchainFingerprint,
      runnerAvailability: runnerAvailability,
      permittedLanes: permittedLanes,
      canRefetchFreshData: canRefetchFreshData,
      localWorktreeDirty: localWorktreeDirty)
  }

  private func verifyExpectations(
    trust: TatwoLoopJobChannelTrust,
    now: Date? = nil
  ) -> TatwoHandoffPackVerificationExpectations {
    TatwoHandoffPackVerificationExpectations(
      trust: trust,
      expectedProducerDeviceID: "handoff-origin",
      expectedReceiverDeviceID: "handoff-receiver",
      now: now ?? createdAt.addingTimeInterval(1))
  }

  private func verifiedPack(
    _ pack: TatwoHandoffPackV1,
    trust: TatwoLoopJobChannelTrust,
    now: Date? = nil
  ) throws -> TatwoVerifiedHandoffPackV1 {
    try TatwoVerifiedHandoffPackV1.verifyOrThrow(
      pack: pack,
      expectations: verifyExpectations(trust: trust, now: now))
  }

  private func encode(_ pack: TatwoHandoffPackV1) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(pack)
  }

  private func decode(_ data: Data) throws -> TatwoHandoffPackV1 {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoHandoffPackV1.self, from: data)
  }

  func testHandoffHappyPathProducesStableSignedPackAndVerifies() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let result = TatwoHandoffPackV1.verify(
      pack,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: pair.receiver,
        expectedProducerDeviceID: pair.origin.localIdentity.deviceID,
        expectedReceiverDeviceID: pair.receiver.localIdentity.deviceID,
        now: createdAt.addingTimeInterval(1)))

    XCTAssertTrue(result.valid, "\(result.issues)")
    XCTAssertEqual(pack.jobCanonicalDigest, pack.packContentHash)
    XCTAssertEqual(try pack.canonicalDigest(), pack.jobCanonicalDigest)
    XCTAssertEqual(pack.producerSignature.purpose, "origin_transfer_offer")
    XCTAssertEqual(pack.schema, TatwoHandoffPackV1.schemaName)
  }

  func testHandoffMissingReceiptListFailsClosedAtProducer() throws {
    let pair = try makeTrustPair()
    XCTAssertThrowsError(
      try makePack(trust: pair.origin, receiptReferences: [])
    ) { error in
      let buildError = error as? TatwoHandoffPackBuildError
      XCTAssertEqual(buildError?.code, .missingRequiredField)
    }
  }

  func testHandoffTamperedPayloadIsRejectedBySignatureAndDigest() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encode(pack)) as? [String: Any])
    var goal = try XCTUnwrap(object["goal"] as? [String: Any])
    goal["description"] = "tampered"
    object["goal"] = goal
    let tampered = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys])
    let decoded = try decode(tampered)
    let result = TatwoHandoffPackV1.verify(
      decoded,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: pair.receiver,
        now: createdAt.addingTimeInterval(1)))

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.errorCodes.contains(.digestMismatch))
    XCTAssertTrue(result.errorCodes.contains(.signatureRejected))
  }

  func testHandoffTamperedSignatureIsRejected() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encode(pack)) as? [String: Any])
    var signature = try XCTUnwrap(
      object["producerSignature"] as? [String: Any])
    signature["signature"] = "tampered"
    object["producerSignature"] = signature
    let tampered = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys])
    let decoded = try decode(tampered)
    let result = TatwoHandoffPackV1.verify(
      decoded,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: pair.receiver,
        now: createdAt.addingTimeInterval(1)))

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.errorCodes.contains(.signatureRejected))
  }

  func testHandoffExpiredFreshnessIsRejected() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin, freshnessWindow: 60)
    let result = TatwoHandoffPackV1.verify(
      pack,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: pair.receiver,
        now: createdAt.addingTimeInterval(181)))

    XCTAssertFalse(result.valid)
    XCTAssertTrue(result.errorCodes.contains(.freshnessExpired))
  }

  func testHandoffInvalidRequiredFileHashIsRejected() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encode(pack)) as? [String: Any])
    object["requiredFiles"] = [["path": "Sources/Goal.swift", "sha256": "bad"]]
    let tampered = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys])
    let decoded = try decode(tampered)
    let result = TatwoHandoffPackV1.verify(
      decoded,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: pair.receiver,
        now: createdAt.addingTimeInterval(1)))

    XCTAssertFalse(result.valid)
    XCTAssertEqual(result.firstErrorCode, .invalidHashFormat)
  }

  func testHandoffS2AcceptsWhenAllInjectedCapabilitiesMatch() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(
      trust: pair.origin,
      toolchainFingerprint: "swift-6.1-arm64",
      requiredRunnerIDs: ["swift-runner"],
      requiredLanes: ["host_delegate"])
    let verified = try verifiedPack(pack, trust: pair.receiver)
    let capabilities = makeCapabilities(
      for: pack,
      swiftToolchainFingerprint: "swift-6.1-arm64",
      runnerAvailability: ["swift-runner": true],
      permittedLanes: ["host_delegate"])
    let assessment = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities
    ).check(
      verifiedPack: verified,
      expectations: TatwoHandoffPackVerificationExpectations(
        trust: pair.receiver,
        now: createdAt.addingTimeInterval(1)))

    XCTAssertEqual(assessment.decision, .accept)
    XCTAssertTrue(assessment.reasonCodes.isEmpty)
    XCTAssertTrue(assessment.checks.allSatisfy(\.passed))
    XCTAssertEqual(assessment.packDigest, verified.packDigest)
    XCTAssertEqual(assessment.logicalJobID, pack.logicalJobID)
    XCTAssertEqual(assessment.jobID, pack.jobID)
    XCTAssertEqual(assessment.dispatchNonce, pack.dispatchNonce)
  }

  func testHandoffS2RejectsUnreachableProjectVersion() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let verified = try verifiedPack(pack, trust: pair.receiver)
    let capabilities = makeCapabilities(
      for: pack,
      projectCommit: String(repeating: "b", count: 64))
    let assessment = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities
    ).check(
      verifiedPack: verified,
      expectations: .init(now: createdAt.addingTimeInterval(1)))

    XCTAssertEqual(assessment.decision, .reject)
    XCTAssertTrue(
      assessment.reasonCodes.contains(.projectCommitUnreachable))
  }

  func testHandoffS2RejectsInsufficientLanePermission() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(
      trust: pair.origin,
      requiredLanes: ["host_delegate"])
    let verified = try verifiedPack(pack, trust: pair.receiver)
    let capabilities = makeCapabilities(for: pack, permittedLanes: ["reviewer"])
    let assessment = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities
    ).check(
      verifiedPack: verified,
      expectations: .init(now: createdAt.addingTimeInterval(1)))

    XCTAssertEqual(assessment.decision, .reject)
    XCTAssertTrue(assessment.reasonCodes.contains(.permissionInsufficient))
  }

  func testHandoffS2DegradedStacksFreshnessToolchainAndRunnerReasons() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(
      trust: pair.origin,
      freshnessWindow: 60,
      toolchainFingerprint: "swift-6.1-arm64",
      requiredRunnerIDs: ["swift-runner", "colima-runner"])
    // Verify while still fresh; re-assess later when stale (S2 freshness).
    let verified = try verifiedPack(
      pack,
      trust: pair.receiver,
      now: createdAt.addingTimeInterval(1))
    let capabilities = makeCapabilities(
      for: pack,
      swiftToolchainFingerprint: "swift-5.10-arm64",
      runnerAvailability: ["swift-runner": false, "colima-runner": false],
      canRefetchFreshData: true)
    let assessment = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities
    ).check(
      verifiedPack: verified,
      expectations: .init(now: createdAt.addingTimeInterval(181)))

    XCTAssertEqual(assessment.decision, .degraded)
    XCTAssertTrue(assessment.reasonCodes.contains(.freshnessRefetchable))
    XCTAssertTrue(
      assessment.reasonCodes.contains(.toolchainFingerprintMismatch))
    XCTAssertTrue(assessment.reasonCodes.contains(.runnerUnavailable))
    XCTAssertEqual(assessment.degradation.count, 3)
    XCTAssertNotEqual(assessment.decision, .accept)
  }

  func testHandoffS2SignedAssessmentRoundTripsAndRejectsTampering() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let verified = try verifiedPack(pack, trust: pair.receiver)
    let capabilities = makeCapabilities(for: pack)
    let unsigned = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities
    ).check(
      verifiedPack: verified,
      expectations: .init(now: createdAt.addingTimeInterval(1)))
    let signed = try unsigned.signed(using: pair.receiver)
    let encoded = try encodeAssessment(signed)
    let decoded = try decodeAssessment(encoded)

    XCTAssertTrue(
      decoded.verifySignature(
        using: pair.origin,
        expectedReporterDeviceID: pair.receiver.localIdentity.deviceID,
        against: pack))
    XCTAssertEqual(try decoded.canonicalDigest(), try signed.canonicalDigest())
    XCTAssertEqual(decoded.packDigest, verified.packDigest)

    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["degradation"] = ["tampered"]
    let tampered = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys])
    let tamperedAssessment = try decodeAssessment(tampered)
    XCTAssertFalse(tamperedAssessment.verifySignature(using: pair.origin))
  }

  // MARK: - SOL-5 / F11 attack-path regressions (C-1, C-2)

  /// API shape: public checker entry only accepts VerifiedHandoffPack.
  /// Raw TatwoHandoffPackV1 cannot be passed without a compile error.
  func testHandoffS2CheckerAPIRequiresVerifiedPackShape() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let verified = try verifiedPack(pack, trust: pair.receiver)
    let capabilities = makeCapabilities(for: pack)
    let checker = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities)

    // Type-level surface under test: only VerifiedHandoffPack is accepted.
    let checkEntry:
      (TatwoVerifiedHandoffPackV1, TatwoHandoffPackVerificationExpectations)
        -> TatwoHandoffAssessmentV1 = checker.check(verifiedPack:expectations:)
    let assessEntry:
      (TatwoVerifiedHandoffPackV1, TatwoHandoffReceiverCapabilitiesV1,
        TatwoHandoffPackVerificationExpectations) -> TatwoHandoffAssessmentV1 =
        TatwoHandoffReceiverCapabilityCheckerV1.assess(
          verifiedPack:capabilities:expectations:)

    let assessment = checkEntry(
      verified,
      .init(now: createdAt.addingTimeInterval(1)))
    let assessed = assessEntry(
      verified,
      capabilities,
      .init(now: createdAt.addingTimeInterval(1)))

    XCTAssertEqual(assessment.decision, .accept)
    XCTAssertEqual(assessed.decision, .accept)
    XCTAssertEqual(assessment.packDigest, verified.packDigest)
    // Document alias used by the ticket wording.
    let _: VerifiedHandoffPack = verified
  }

  /// Tampered / unsigned-equivalent pack fails verify → cannot produce a
  /// VerifiedHandoffPack, so capability matching cannot reach .accept.
  func testHandoffS2TamperedPackVerifyFailsCannotProduceAssessment() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: encode(pack)) as? [String: Any])
    // Attack: rewrite receiver/commit/tree/freshness-relevant fields while
    // keeping capability declarations matchable.
    object["intendedReceiverDeviceID"] = "handoff-receiver"
    var mod = try XCTUnwrap(object["modificationState"] as? [String: Any])
    mod["commit"] = sha256Hash
    object["modificationState"] = mod
    var goal = try XCTUnwrap(object["goal"] as? [String: Any])
    goal["description"] = "attacker-controlled goal"
    object["goal"] = goal
    let tamperedData = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys])
    let tampered = try decode(tamperedData)

    let verifyResult = TatwoVerifiedHandoffPackV1.verify(
      pack: tampered,
      expectations: verifyExpectations(trust: pair.receiver))
    switch verifyResult {
    case .success:
      XCTFail("tampered pack must not produce VerifiedHandoffPack")
    case .failure(let error):
      let failure = error.verificationResult
      XCTAssertFalse(failure.valid)
      XCTAssertTrue(
        failure.errorCodes.contains(.digestMismatch)
          || failure.errorCodes.contains(.signatureRejected),
        "\(failure.errorCodes)")
    }

    // Matching capabilities are irrelevant when verify already failed closed.
    let capabilities = makeCapabilities(for: pack)
    XCTAssertEqual(capabilities.deviceID, "handoff-receiver")
  }

  /// Signed accept assessment for pack A must reject when replayed against
  /// pack B even if handoffID collides (transplant / digest mismatch).
  func testHandoffS2AssessmentTransplantAcrossPacksIsRejected() throws {
    let pair = try makeTrustPair()
    let packA = try makePack(
      trust: pair.origin,
      jobID: "attempt-1",
      dispatchNonce: "nonce-a",
      goalDescription: "goal A")
    let packB = try makePack(
      trust: pair.origin,
      jobID: "attempt-2",
      dispatchNonce: "nonce-b",
      goalDescription: "goal B")
    XCTAssertEqual(packA.handoffID, packB.handoffID)
    XCTAssertNotEqual(packA.packContentHash, packB.packContentHash)

    let verifiedA = try verifiedPack(packA, trust: pair.receiver)
    let capabilities = makeCapabilities(for: packA)
    let assessmentA = try TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: capabilities
    ).check(
      verifiedPack: verifiedA,
      expectations: .init(now: createdAt.addingTimeInterval(1))
    ).signed(using: pair.receiver)

    XCTAssertEqual(assessmentA.decision, .accept)
    XCTAssertTrue(
      assessmentA.verifySignature(
        using: pair.origin,
        expectedReporterDeviceID: pair.receiver.localIdentity.deviceID,
        against: packA))

    // Transplant: same handoffID, different pack digest / attempt identity.
    XCTAssertFalse(
      assessmentA.matchesPackBinding(packB),
      "assessment bound to pack A must not match pack B")
    XCTAssertFalse(
      assessmentA.verifySignature(
        using: pair.origin,
        expectedReporterDeviceID: pair.receiver.localIdentity.deviceID,
        against: packB),
      "signature verify against foreign pack must reject on digest mismatch")

    // Even if an attacker rewrites stored packDigest to pack B's digest, the
    // Ed25519 payload still covers the original packDigest → signature fails.
    let forgedBinding = TatwoHandoffAssessmentV1(
      handoffID: assessmentA.handoffID,
      packDigest: packB.packContentHash,
      logicalJobID: packB.logicalJobID,
      jobID: packB.jobID,
      dispatchNonce: packB.dispatchNonce,
      decision: assessmentA.decision,
      checks: assessmentA.checks,
      degradation: assessmentA.degradation,
      reasonCodes: assessmentA.reasonCodes,
      reportedAt: assessmentA.reportedAt,
      reporterSignature: assessmentA.reporterSignature)
    XCTAssertFalse(
      forgedBinding.verifySignature(
        using: pair.origin,
        against: packB))
  }

  /// Degradation stacking must stay `.degraded` (or `.reject` when combined
  /// with a hard rejection) and never promote into `.accept`.
  func testHandoffS2DegradationStackDoesNotBypassToAccept() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(
      trust: pair.origin,
      freshnessWindow: 60,
      toolchainFingerprint: "swift-6.1-arm64",
      requiredRunnerIDs: ["swift-runner"],
      requiredLanes: ["host_delegate"])
    let verified = try verifiedPack(
      pack,
      trust: pair.receiver,
      now: createdAt.addingTimeInterval(1))

    // Pure degradation path (refetchable stale + toolchain + runner).
    let degradedCaps = makeCapabilities(
      for: pack,
      swiftToolchainFingerprint: "other",
      runnerAvailability: ["swift-runner": false],
      permittedLanes: ["host_delegate"],
      canRefetchFreshData: true)
    let degraded = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: degradedCaps
    ).check(
      verifiedPack: verified,
      expectations: .init(now: createdAt.addingTimeInterval(181)))
    XCTAssertEqual(degraded.decision, .degraded)
    XCTAssertNotEqual(degraded.decision, .accept)
    XCTAssertFalse(degraded.degradation.isEmpty)

    // Degradation reasons + hard rejection (missing lane) → still reject.
    let rejectCaps = makeCapabilities(
      for: pack,
      swiftToolchainFingerprint: "other",
      runnerAvailability: ["swift-runner": false],
      permittedLanes: ["reviewer"],
      canRefetchFreshData: true)
    let rejected = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: rejectCaps
    ).check(
      verifiedPack: verified,
      expectations: .init(now: createdAt.addingTimeInterval(181)))
    XCTAssertEqual(rejected.decision, .reject)
    XCTAssertTrue(rejected.reasonCodes.contains(.permissionInsufficient))
    XCTAssertTrue(
      rejected.reasonCodes.contains(.freshnessRefetchable)
        || rejected.degradation.contains("freshness_refetch_required"))
    XCTAssertNotEqual(rejected.decision, .accept)
    XCTAssertNotEqual(rejected.decision, .degraded)
  }

  private func makeOriginLease(
    holderDeviceID: String,
    epoch: UInt64 = 1,
    observedAt: Date? = nil,
    expiresAt: Date? = nil
  ) -> TatwoAuthorityLeaseV1 {
    let observed = observedAt ?? createdAt
    return TatwoAuthorityLeaseV1(
      domainID: "domain-1",
      holderDeviceID: holderDeviceID,
      epoch: epoch,
      fencingToken: "fence-\(epoch)",
      observedAt: observed,
      expiresAt: expiresAt ?? observed.addingTimeInterval(600),
      source: .humanConfirmed,
      receiptMetadata: TatwoWorkReceiptMetadataV1(
        receiptID: "lease-\(epoch)",
        schema: "TatwoAuthorityLeaseV1",
        version: 1,
        correlationID: "handoff-1",
        createdAt: observed,
        sourceDeviceID: holderDeviceID))
  }

  private func makeAcceptAssessment(
    pack: TatwoHandoffPackV1,
    pair: (origin: TatwoLoopJobChannelTrust, receiver: TatwoLoopJobChannelTrust)
  ) throws -> (TatwoVerifiedHandoffPackV1, TatwoHandoffAssessmentV1) {
    let verified = try verifiedPack(pack, trust: pair.receiver)
    let caps = makeCapabilities(for: pack)
    let unsigned = TatwoHandoffReceiverCapabilityCheckerV1(
      capabilities: caps
    ).check(
      verifiedPack: verified,
      expectations: .init(
        trust: pair.receiver,
        expectedReceiverDeviceID: pair.receiver.localIdentity.deviceID,
        now: createdAt.addingTimeInterval(1)))
    XCTAssertEqual(unsigned.decision, .accept)
    return (verified, try unsigned.signed(using: pair.receiver))
  }

  func testS3NormalTransferFencesOldOriginUntilReceiverAdopts() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let (verified, assessment) = try makeAcceptAssessment(pack: pack, pair: pair)
    let now = createdAt.addingTimeInterval(1)
    let store = TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: makeOriginLease(
        holderDeviceID: pair.origin.localIdentity.deviceID))

    XCTAssertTrue(store.isOriginAuthority(
      deviceID: pair.origin.localIdentity.deviceID,
      epoch: 1,
      now: now))
    let commit = try store.createCommit(
      verifiedPack: verified,
      acceptAssessment: assessment,
      originTrust: pair.origin,
      receiverTrust: pair.receiver,
      now: now)
    XCTAssertEqual(commit.leaseEpoch, 2)
    XCTAssertFalse(store.isOriginAuthority(
      deviceID: pair.origin.localIdentity.deviceID,
      epoch: 1,
      now: now))
    XCTAssertFalse(store.canWrite(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: 2,
      now: now))
    try store.acknowledgeReceiver(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: 2)
    _ = try store.adopt(
      receiverDeviceID: pair.receiver.localIdentity.deviceID,
      epoch: 2)
    XCTAssertTrue(store.isOriginAuthority(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: 2,
      now: now))
  }

  func testS3SameEpochConcurrentWritersAreRejected() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let (verified, assessment) = try makeAcceptAssessment(pack: pack, pair: pair)
    let now = createdAt.addingTimeInterval(1)
    let store = TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: makeOriginLease(
        holderDeviceID: pair.origin.localIdentity.deviceID))
    _ = try store.createCommit(
      verifiedPack: verified,
      acceptAssessment: assessment,
      originTrust: pair.origin,
      receiverTrust: pair.receiver,
      now: now)
    XCTAssertFalse(store.canWrite(
      deviceID: pair.origin.localIdentity.deviceID,
      epoch: 2,
      now: now))
    XCTAssertFalse(store.canWrite(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: 1,
      now: now))
  }

  func testS3UnackedTransferExpiresAndReclaimsMonotonicEpoch() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let (verified, assessment) = try makeAcceptAssessment(pack: pack, pair: pair)
    let expiry = createdAt.addingTimeInterval(10)
    let store = TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: makeOriginLease(
        holderDeviceID: pair.origin.localIdentity.deviceID,
        expiresAt: expiry))
    let issued = try store.issueTransfer(
      verifiedPack: verified,
      acceptAssessment: assessment,
      originTrust: pair.origin,
      receiverTrust: pair.receiver,
      now: createdAt.addingTimeInterval(1))
    XCTAssertTrue(store.canWrite(
      deviceID: pair.origin.localIdentity.deviceID,
      epoch: 1,
      now: createdAt.addingTimeInterval(2)))
    try store.acknowledgeReceiver(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: issued.leaseEpoch)
    XCTAssertFalse(store.canWrite(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: issued.leaseEpoch,
      now: createdAt.addingTimeInterval(2)))
    let reclaimed = try store.reclaimExpiredLease(
      now: createdAt.addingTimeInterval(11))
    XCTAssertEqual(reclaimed.epoch, 2)
    XCTAssertTrue(store.canWrite(
      deviceID: pair.origin.localIdentity.deviceID,
      epoch: 2,
      now: createdAt.addingTimeInterval(11)))
    XCTAssertFalse(store.canWrite(
      deviceID: pair.origin.localIdentity.deviceID,
      epoch: 1,
      now: createdAt.addingTimeInterval(11)))
  }

  func testS3ForgedCommitWithWrongSignatureIsRejected() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let (verified, assessment) = try makeAcceptAssessment(pack: pack, pair: pair)
    let now = createdAt.addingTimeInterval(1)
    let lease = makeOriginLease(holderDeviceID: pair.origin.localIdentity.deviceID)
    let commit = try TatwoHandoffLeaseTransferV1.create(
      verifiedPack: verified,
      acceptAssessment: assessment,
      currentOriginLease: lease,
      originTrust: pair.origin,
      receiverTrust: pair.receiver,
      now: now)
    let forged = TatwoHandoffLeaseTransferV1(
      transferID: commit.transferID,
      handoffID: commit.handoffID,
      logicalJobID: commit.logicalJobID,
      packDigest: commit.packDigest,
      assessmentDigest: commit.assessmentDigest,
      domainID: commit.domainID,
      fromDeviceID: commit.fromDeviceID,
      toDeviceID: commit.toDeviceID,
      previousEpoch: commit.previousEpoch,
      leaseEpoch: commit.leaseEpoch,
      generation: commit.generation,
      fencingToken: commit.fencingToken,
      committedAt: commit.committedAt,
      newLease: commit.newLease,
      receiptMetadata: commit.receiptMetadata,
      originSignature: commit.receiverSignature,
      receiverSignature: commit.receiverSignature)
    let store = TatwoHandoffLeaseTransferStoreV1(currentOriginLease: lease)
    XCTAssertThrowsError(
      try store.installCommit(
        forged,
        verifiedPack: verified,
        acceptAssessment: assessment,
        originTrust: pair.origin,
        receiverTrust: pair.receiver,
        now: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoHandoffLeaseTransferErrorV1,
        .forgedCommit)
    }
  }

  // MARK: - F13 durable fencing regressions

  func testF13TwoDurableStoresCannotMintTwoCommitsFromOneEpoch() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let (verified, assessment) = try makeAcceptAssessment(pack: pack, pair: pair)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-f13-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let highWater = MemoryFleetHighWaterAnchor()
    let configuration = TatwoHandoffLeaseTransferDurableConfigurationV1(
      rootURL: root,
      highWater: highWater,
      signingTrust: pair.origin)
    let lease = makeOriginLease(holderDeviceID: pair.origin.localIdentity.deviceID)
    let first = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: lease,
      durableConfiguration: configuration)
    // The second process restores before the first process commits, so both
    // start from the same old lease snapshot.
    let second = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: lease,
      durableConfiguration: configuration)

    _ = try first.createCommit(
      verifiedPack: verified,
      acceptAssessment: assessment,
      originTrust: pair.origin,
      receiverTrust: pair.receiver,
      now: createdAt.addingTimeInterval(1))

    // An independent durable reader must recover the single persisted winner.
    let third = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: first.currentLease,
      durableConfiguration: configuration)
    XCTAssertEqual(third.currentLease.epoch, lease.epoch + 1)
    XCTAssertEqual(third.commit?.newLease.epoch, lease.epoch + 1)

    XCTAssertThrowsError(
      try second.createCommit(
        verifiedPack: verified,
        acceptAssessment: assessment,
        originTrust: pair.origin,
        receiverTrust: pair.receiver,
        now: createdAt.addingTimeInterval(1))
    ) { error in
      // Both codes are valid fail-closed outcomes for the double-mint race:
      // .commitAlreadyExists when the create-only slot collision is observed
      // directly, or .durableStoreUnavailable when the loser's authority stack
      // detects its snapshot went stale after the winner's commit (K1 wiring
      // made restore checks stricter). Either way the second mint is blocked.
      switch error as? TatwoHandoffLeaseTransferErrorV1 {
      case .commitAlreadyExists, .durableStoreUnavailable:
        break
      default:
        XCTFail("expected fail-closed double-mint rejection, got \(error)")
      }
    }
  }

  func testF13CrashRestoreUsesJournalAndHighWaterAndRejectsStaleSnapshot() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let (verified, assessment) = try makeAcceptAssessment(pack: pack, pair: pair)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-f13-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let highWater = MemoryFleetHighWaterAnchor()
    let configuration = TatwoHandoffLeaseTransferDurableConfigurationV1(
      rootURL: root,
      highWater: highWater,
      signingTrust: pair.origin)
    let originLease = makeOriginLease(
      holderDeviceID: pair.origin.localIdentity.deviceID)
    let store = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: originLease,
      durableConfiguration: configuration)
    let commit = try store.createCommit(
      verifiedPack: verified,
      acceptAssessment: assessment,
      originTrust: pair.origin,
      receiverTrust: pair.receiver,
      now: createdAt.addingTimeInterval(1))
    try store.acknowledgeReceiver(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: commit.leaseEpoch)
    XCTAssertFalse(
      store.canWrite(
        deviceID: pair.receiver.localIdentity.deviceID,
        epoch: commit.leaseEpoch,
        now: createdAt.addingTimeInterval(2)))
    let adopted = try store.adopt(
      receiverDeviceID: pair.receiver.localIdentity.deviceID,
      epoch: commit.leaseEpoch)
    XCTAssertEqual(adopted.epoch, 2)

    let restored = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: adopted,
      durableConfiguration: configuration)
    XCTAssertEqual(restored.currentLease.epoch, 2)
    XCTAssertTrue(
      restored.canWrite(
        deviceID: pair.receiver.localIdentity.deviceID,
        epoch: 2,
        now: createdAt.addingTimeInterval(2)))
    XCTAssertThrowsError(
      try TatwoHandoffLeaseTransferStoreV1(
        currentOriginLease: originLease,
        durableConfiguration: configuration)
    ) { error in
      guard case let .staleDurableEpoch(current, highWater) =
        error as? TatwoHandoffLeaseTransferErrorV1
      else {
        return XCTFail("expected stale durable epoch, got \(error)")
      }
      XCTAssertEqual(current, 1)
      XCTAssertEqual(highWater, 2)
    }
  }

  func testF13OldEpochProductionWriteIsRejectedAfterDurableAdopt() throws {
    let pair = try makeTrustPair()
    let pack = try makePack(trust: pair.origin)
    let (verified, assessment) = try makeAcceptAssessment(pack: pack, pair: pair)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-f13-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = TatwoHandoffLeaseTransferDurableConfigurationV1(
      rootURL: root,
      highWater: MemoryFleetHighWaterAnchor(),
      signingTrust: pair.origin)
    let store = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: makeOriginLease(
        holderDeviceID: pair.origin.localIdentity.deviceID),
      durableConfiguration: configuration)
    let commit = try store.createCommit(
      verifiedPack: verified,
      acceptAssessment: assessment,
      originTrust: pair.origin,
      receiverTrust: pair.receiver,
      now: createdAt.addingTimeInterval(1))
    try store.acknowledgeReceiver(
      deviceID: pair.receiver.localIdentity.deviceID,
      epoch: commit.leaseEpoch)
    _ = try store.adopt(
      receiverDeviceID: pair.receiver.localIdentity.deviceID,
      epoch: commit.leaseEpoch)

    XCTAssertFalse(
      store.canWrite(
        deviceID: pair.origin.localIdentity.deviceID,
        epoch: 1,
        now: createdAt.addingTimeInterval(2)))
    XCTAssertThrowsError(
      try store.issueTransfer(
        verifiedPack: verified,
        acceptAssessment: assessment,
        originTrust: pair.origin,
        receiverTrust: pair.receiver,
        now: createdAt.addingTimeInterval(2))
    ) { error in
      XCTAssertEqual(
        error as? TatwoHandoffLeaseTransferErrorV1,
        .originWriteFenced)
    }
  }

  func testF13DurableJournalTamperFailsClosedOnRestore() throws {
    let pair = try makeTrustPair()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-f13-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = TatwoHandoffLeaseTransferDurableConfigurationV1(
      rootURL: root,
      highWater: MemoryFleetHighWaterAnchor(),
      signingTrust: pair.origin)
    let lease = makeOriginLease(holderDeviceID: pair.origin.localIdentity.deviceID)
    _ = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: lease,
      durableConfiguration: configuration)
    let journal = root
      .appendingPathComponent("journal", isDirectory: true)
      .appendingPathComponent("\(lease.domainID).jsonl")
    var bytes = try Data(contentsOf: journal)
    bytes.append(Data("{\"tampered\":true}\n".utf8))
    try bytes.write(to: journal)

    XCTAssertThrowsError(
      try TatwoHandoffLeaseTransferStoreV1(
        currentOriginLease: lease,
        durableConfiguration: configuration)
    ) { error in
      guard case .durableJournalCorrupt = error as? TatwoHandoffLeaseTransferErrorV1
      else {
        return XCTFail("expected journal corruption, got \(error)")
      }
    }
  }

  private func encodeAssessment(_ assessment: TatwoHandoffAssessmentV1) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(assessment)
  }

  private func decodeAssessment(_ data: Data) throws -> TatwoHandoffAssessmentV1 {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoHandoffAssessmentV1.self, from: data)
  }
}

private final class HandoffMemoryPrivateKeyStore:
  @unchecked Sendable,
  TatwoDevicePrivateKeyStore
{
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
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
    keys["\(deviceID):\(generation)"] = key
  }
}

private final class MemoryFleetHighWaterAnchor:
  TatwoFleetHighWaterAnchor,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var authority: TatwoFleetAuthorityHighWaterV1?
  private var commits: [String: TatwoFleetCommitHighWaterV1] = [:]
  private var paths: [String: TatwoFleetPathHighWaterV1] = [:]

  func loadAuthorityHighWater() throws -> TatwoFleetAuthorityHighWaterV1? {
    lock.lock(); defer { lock.unlock() }
    return authority
  }

  func storeAuthorityHighWater(_ value: TatwoFleetAuthorityHighWaterV1) throws {
    lock.lock(); defer { lock.unlock() }
    if let prior = authority {
      guard value.authorityEpoch >= prior.authorityEpoch,
        value.ledgerSequence >= prior.ledgerSequence
      else {
        throw TatwoFleetAuthorityError.staleAuthorityEpoch(
          current: value.authorityEpoch,
          highWater: prior.authorityEpoch)
      }
    }
    authority = value
  }

  func loadCommitHighWater(logicalJobID: String) throws -> TatwoFleetCommitHighWaterV1? {
    lock.lock(); defer { lock.unlock() }
    return commits[logicalJobID]
  }

  func createCommitHighWater(_ value: TatwoFleetCommitHighWaterV1) throws {
    lock.lock(); defer { lock.unlock() }
    if let prior = commits[value.logicalJobID], prior != value {
      throw TatwoFleetAuthorityError.commitHighWaterMismatch(value.logicalJobID)
    }
    commits[value.logicalJobID] = value
  }

  func loadPathHighWater(
    purpose: String,
    canonicalRelativePath: String
  ) throws -> TatwoFleetPathHighWaterV1? {
    lock.lock(); defer { lock.unlock() }
    return paths[TatwoFleetPathHighWaterV1.makeKey(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath)]
  }

  func storePathHighWater(_ value: TatwoFleetPathHighWaterV1) throws {
    lock.lock(); defer { lock.unlock() }
    let key = value.key
    if let prior = paths[key], value.ledgerSequence < prior.ledgerSequence {
      throw TatwoFleetAuthorityError.ledgerSequenceRegression(
        got: value.ledgerSequence,
        highWater: prior.ledgerSequence)
    }
    paths[key] = value
  }
}
