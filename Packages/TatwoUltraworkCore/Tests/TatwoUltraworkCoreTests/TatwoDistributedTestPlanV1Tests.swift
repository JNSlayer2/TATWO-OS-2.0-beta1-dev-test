import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDistributedTestPlanV1Tests: XCTestCase {
  private func fingerprint(
    swift: String = "6.4",
    host: String = "mini"
  ) -> TatwoToolchainFingerprintV1 {
    TatwoToolchainFingerprintV1(
      swiftVersion: swift,
      xcodePath: "/Applications/Xcode.app",
      xcodeVersion: "Xcode 27",
      os: "macOS 27",
      arch: "arm64",
      hostName: host,
      ramGB: 16,
      logicalCPU: 10,
      generatedAt: "2026-07-30T00:00:00Z")
  }

  private func shards() throws -> [TatwoTestShardFilterSetV1] {
    [
      try TatwoTestShardFilterSetV1(
        shardKey: "shard/2/0",
        expectedShardCount: 2,
        filters: ["--filter=Alpha", "--filter=Beta"]),
      try TatwoTestShardFilterSetV1(
        shardKey: "shard/2/1",
        expectedShardCount: 2,
        filters: ["--filter=Gamma"])
    ]
  }

  private func plan() throws -> TatwoDistributedTestPlanV1 {
    try TatwoDistributedTestPlanV1(
      shardFilters: shards(),
      targetDevices: [
        try TatwoDistributedTestDeviceCapabilityV1(
          deviceID: "device-a",
          toolchainFingerprint: fingerprint(host: "a"),
          freeDiskBytes: 10_000,
          maxConcurrent: 1,
          maxTimeoutSec: 60),
        try TatwoDistributedTestDeviceCapabilityV1(
          deviceID: "device-b",
          toolchainFingerprint: fingerprint(host: "b"),
          freeDiskBytes: 10_000,
          maxConcurrent: 1,
          maxTimeoutSec: 60)
      ],
      diskBudgetBytes: 1_000,
      timeoutSec: 30,
      originDeviceID: "origin-device",
      contractID: "contract-m2",
      goalID: "goal-m2")
  }

  private func result(
    _ spec: TatwoDistributedTestJobSpecV1,
    fingerprint: TatwoToolchainFingerprintV1? = nil,
    passed: Int = 2,
    failed: Int = 0,
    skipped: Int = 0,
    unavailableCapabilities: [String] = [],
    authority: TatwoDeviceTrustAuthority? = nil,
    identity: TatwoDevicePublicIdentityV1? = nil
  ) throws -> TatwoDistributedTestResultV1 {
    let unsigned = TatwoDistributedTestResultV1(
      shardKey: spec.shardKey,
      expectedShardCount: spec.expectedShardCount,
      filters: spec.filters,
      toolchainFingerprint: fingerprint ?? spec.expectedToolchain,
      logBytes: 128,
      passedSuites: passed,
      failedSuites: failed,
      skippedCount: skipped,
      unavailableCapabilities: unavailableCapabilities,
      jobID: spec.jobID,
      logicalJobID: spec.logicalJobID,
      dispatchNonce: spec.remoteLoopJob.dispatchNonce,
      jobCanonicalDigest: try spec.remoteLoopJob.canonicalDigest(),
      targetDeviceID: spec.targetDeviceID)
    guard let authority, let identity else { return unsigned }
    let signature = try authority.sign(
      payload: unsigned.signingPayload(),
      purpose: TatwoLoopChannelSignaturePurposeV1.loopResult.rawValue,
      identity: identity,
      signedAt: "2026-07-30T00:00:00Z")
    return TatwoDistributedTestResultV1(
      shardKey: unsigned.shardKey,
      expectedShardCount: unsigned.expectedShardCount,
      filters: unsigned.filters,
      toolchainFingerprint: unsigned.toolchainFingerprint,
      logBytes: unsigned.logBytes,
      passedSuites: unsigned.passedSuites,
      failedSuites: unsigned.failedSuites,
      skippedCount: unsigned.skippedCount,
      unavailableCapabilities: unsigned.unavailableCapabilities,
      jobID: unsigned.jobID,
      logicalJobID: unsigned.logicalJobID,
      dispatchNonce: unsigned.dispatchNonce,
      jobCanonicalDigest: unsigned.jobCanonicalDigest,
      targetDeviceID: unsigned.targetDeviceID,
      targetSignature: signature)
  }

  private func trustFixture() throws -> (
    trust: TatwoLoopJobChannelTrust,
    authority: TatwoDeviceTrustAuthority,
    identities: [String: TatwoDevicePublicIdentityV1]
  ) {
    let store = MemoryDevicePrivateKeyStore()
    let authority = TatwoDeviceTrustAuthority(privateKeyStore: store)
    let a = try authority.ensureIdentity(deviceID: "device-a", pinnedAt: "2026-07-30T00:00:00Z")
    let b = try authority.ensureIdentity(deviceID: "device-b", pinnedAt: "2026-07-30T00:00:00Z")
    let trust = TatwoLoopJobChannelTrust(
      authority: authority,
      localIdentity: a,
      pinnedIdentities: [a.deviceID: a, b.deviceID: b])
    return (trust, authority, [a.deviceID: a, b.deviceID: b])
  }

  func testPlanProducesFleetRemoteLoopJobsWithoutDispatching() throws {
    let fixture = try plan()
    XCTAssertFalse(TatwoDistributedTestPlanV1.isProductionDispatchReady)
    XCTAssertEqual(fixture.jobSpecs.count, 2)
    XCTAssertEqual(fixture.jobSpecs.map(\.targetDeviceID), ["device-a", "device-b"])
    XCTAssertEqual(fixture.jobSpecs[0].diskBudgetBytes, 1_000)
    XCTAssertEqual(fixture.jobSpecs[0].timeoutSec, 30)
    XCTAssertEqual(fixture.jobs.count, 2)
    XCTAssertTrue(fixture.jobs.allSatisfy {
      $0.remoteBorrowInvocation == nil
        && $0.remoteDispatchReadiness == nil
        && $0.workspaceLocator == nil
    })
    XCTAssertTrue(fixture.jobs.allSatisfy { job in
      do {
        try job.validate()
        return true
      } catch {
        return false
      }
    })
  }

  func testCompleteCollectionPasses() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let results = try fixture.jobSpecs.map {
      try result(
        $0,
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[$0.targetDeviceID])
    }
    let verification = fixture.verify(results: results, trust: fixtureTrust.trust)
    XCTAssertTrue(verification.passed)
    XCTAssertFalse(verification.degraded)
    XCTAssertEqual(verification.outcome, .pass)
    XCTAssertEqual(verification.trustSource, "fleet-signature")
  }

  func testMissingShardFailsWholeRollup() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let verification = fixture.verify(
      [try result(
        fixture.jobSpecs[0],
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID])],
      trust: fixtureTrust.trust)
    XCTAssertFalse(verification.passed)
    XCTAssertEqual(verification.missingShardKeys, ["shard/2/1"])
  }

  func testFailedSuitesFailWholeRollup() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let verification = fixture.verify(
      [
        try result(
          fixture.jobSpecs[0],
          failed: 1,
          authority: fixtureTrust.authority,
          identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID]),
        try result(
          fixture.jobSpecs[1],
          authority: fixtureTrust.authority,
          identity: fixtureTrust.identities[fixture.jobSpecs[1].targetDeviceID])
      ],
      trust: fixtureTrust.trust)
    XCTAssertFalse(verification.passed)
    XCTAssertEqual(verification.failedShardKeys, ["shard/2/0"])
  }

  func testSkippedCapabilityProducesPassWithSkipsWithoutInflatingPassedSuites() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let results = try [
      result(
        fixture.jobSpecs[0],
        passed: 1,
        skipped: 2,
        unavailableCapabilities: ["interactive-keychain"],
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID]),
      result(
        fixture.jobSpecs[1],
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[fixture.jobSpecs[1].targetDeviceID])
    ]

    XCTAssertEqual(results[0].passedSuites, 1)
    XCTAssertEqual(results[0].skippedCount, 2)

    let verification = fixture.verify(results: results, trust: fixtureTrust.trust)
    XCTAssertFalse(verification.passed)
    XCTAssertEqual(verification.outcome, .passWithSkips)
    XCTAssertEqual(verification.skippedCount, 2)
    XCTAssertEqual(verification.unavailableCapabilities, ["interactive-keychain"])
    XCTAssertTrue(verification.conclusion.contains("PASS_WITH_SKIPS"))
    XCTAssertTrue(verification.conclusion.contains("interactive-keychain"))
    XCTAssertTrue(verification.conclusion.contains("2 skipped"))
    XCTAssertTrue(verification.conclusion.contains("not a full pass"))
  }

  func testSkipCountWithoutCapabilityNameFailsClosed() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let results = try [
      result(
        fixture.jobSpecs[0],
        skipped: 1,
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID]),
      result(
        fixture.jobSpecs[1],
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[fixture.jobSpecs[1].targetDeviceID])
    ]
    let verification = fixture.verify(results: results, trust: fixtureTrust.trust)
    XCTAssertEqual(verification.outcome, .fail)
    XCTAssertTrue(verification.invalidShardKeys.contains("shard/2/0"))
  }

  func testSkipAndToolchainMismatchRemainPassWithSkipsWithDegradedDetail() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let results = try [
      result(
        fixture.jobSpecs[0],
        fingerprint: fingerprint(swift: "6.3", host: "legacy"),
        skipped: 1,
        unavailableCapabilities: ["interactive-keychain"],
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID]),
      result(
        fixture.jobSpecs[1],
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[fixture.jobSpecs[1].targetDeviceID])
    ]
    let verification = fixture.verify(results: results, trust: fixtureTrust.trust)
    XCTAssertEqual(verification.outcome, .passWithSkips)
    XCTAssertTrue(verification.degraded)
    XCTAssertTrue(verification.conclusion.contains("interactive-keychain"))
    XCTAssertTrue(verification.conclusion.contains("degraded toolchain"))
    XCTAssertTrue(verification.conclusion.contains("not a full pass"))
  }

  func testSkipAndTransportOnlyRemainPassWithSkipsWithTrustWarning() throws {
    let fixture = try plan()
    let results = try [
      result(
        fixture.jobSpecs[0],
        skipped: 1,
        unavailableCapabilities: ["interactive-keychain"]),
      result(fixture.jobSpecs[1])
    ]
    let verification = fixture.verify(
      results: results,
      allowUnsignedResults: true)
    XCTAssertEqual(verification.outcome, .passWithSkips)
    XCTAssertTrue(verification.degraded)
    XCTAssertEqual(verification.trustSource, "transport-only")
    XCTAssertTrue(verification.conclusion.contains("interactive-keychain"))
    XCTAssertTrue(verification.conclusion.contains("transport-only"))
  }

  func testLegacyZeroSkipSignatureStillVerifies() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let spec = fixture.jobSpecs[0]
    let legacyUnsigned = try result(spec)
    let identity = try XCTUnwrap(fixtureTrust.identities[spec.targetDeviceID])
    let signature = try fixtureTrust.authority.sign(
      payload: legacyUnsigned.legacySigningPayloadV1(),
      purpose: TatwoLoopChannelSignaturePurposeV1.loopResult.rawValue,
      identity: identity,
      signedAt: "2026-07-30T00:00:00Z")
    let legacySigned = TatwoDistributedTestResultV1(
      shardKey: legacyUnsigned.shardKey,
      expectedShardCount: legacyUnsigned.expectedShardCount,
      filters: legacyUnsigned.filters,
      toolchainFingerprint: legacyUnsigned.toolchainFingerprint,
      logBytes: legacyUnsigned.logBytes,
      passedSuites: legacyUnsigned.passedSuites,
      failedSuites: legacyUnsigned.failedSuites,
      jobID: legacyUnsigned.jobID,
      logicalJobID: legacyUnsigned.logicalJobID,
      dispatchNonce: legacyUnsigned.dispatchNonce,
      jobCanonicalDigest: legacyUnsigned.jobCanonicalDigest,
      targetDeviceID: legacyUnsigned.targetDeviceID,
      targetSignature: signature)
    let second = try result(
      fixture.jobSpecs[1],
      authority: fixtureTrust.authority,
      identity: fixtureTrust.identities[fixture.jobSpecs[1].targetDeviceID])
    let verification = fixture.verify(
      results: [legacySigned, second],
      trust: fixtureTrust.trust)
    XCTAssertEqual(verification.outcome, .pass)
    XCTAssertTrue(verification.conclusion.contains("legacy V1 zero-skip signature"))
  }

  func testLegacyJSONWithoutSkipFieldsDecodesAsZeroSkip() throws {
    let fixture = try plan()
    let result = try result(fixture.jobSpecs[0])
    let encoded = try JSONEncoder().encode(result)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "skippedCount")
    object.removeValue(forKey: "unavailableCapabilities")
    let legacyJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let decoded = try JSONDecoder().decode(
      TatwoDistributedTestResultV1.self, from: legacyJSON)
    XCTAssertEqual(decoded.skippedCount, 0)
    XCTAssertEqual(decoded.unavailableCapabilities, [])
  }

  func testToolchainMismatchIsDegradedButNotGreenwashed() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let verification = fixture.verify(
      [
        try result(
          fixture.jobSpecs[0],
          fingerprint: fingerprint(swift: "6.3", host: "legacy"),
          authority: fixtureTrust.authority,
          identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID]),
        try result(
          fixture.jobSpecs[1],
          authority: fixtureTrust.authority,
          identity: fixtureTrust.identities[fixture.jobSpecs[1].targetDeviceID])
      ],
      trust: fixtureTrust.trust)
    XCTAssertFalse(verification.passed)
    XCTAssertTrue(verification.degraded)
    XCTAssertEqual(verification.outcome, .degraded)
    XCTAssertTrue(verification.conclusion.contains("degraded toolchain"))
    XCTAssertTrue(verification.conclusion.contains("不等於通過"))
  }

  func testDuplicateShardFailsEvenWhenOtherShardIsGreen() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let first = try result(
      fixture.jobSpecs[0],
      authority: fixtureTrust.authority,
      identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID])
    let verification = fixture.verify(
      [
        first,
        first,
        try result(
          fixture.jobSpecs[1],
          authority: fixtureTrust.authority,
          identity: fixtureTrust.identities[fixture.jobSpecs[1].targetDeviceID])
      ],
      trust: fixtureTrust.trust)
    XCTAssertFalse(verification.passed)
    XCTAssertEqual(verification.duplicateShardKeys, ["shard/2/0"])
  }

  func testUnsignedShardResultFailsClosed() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let verification = fixture.verify(
      [try result(fixture.jobSpecs[0])],
      trust: fixtureTrust.trust)
    XCTAssertFalse(verification.passed)
    XCTAssertTrue(verification.invalidShardKeys.contains("shard/2/0"))
    XCTAssertTrue(verification.conclusion.contains("missing target signature"))
  }

  func testTamperedShardSignatureIsRejected() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let signed = try result(
      fixture.jobSpecs[0],
      authority: fixtureTrust.authority,
      identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID])
    let signature = try XCTUnwrap(signed.targetSignature)
    let tampered = TatwoDistributedTestResultV1(
      shardKey: signed.shardKey,
      expectedShardCount: signed.expectedShardCount,
      filters: signed.filters,
      toolchainFingerprint: signed.toolchainFingerprint,
      logBytes: signed.logBytes,
      passedSuites: signed.passedSuites,
      failedSuites: signed.failedSuites,
      skippedCount: signed.skippedCount,
      unavailableCapabilities: signed.unavailableCapabilities,
      jobID: signed.jobID,
      logicalJobID: signed.logicalJobID,
      dispatchNonce: signed.dispatchNonce,
      jobCanonicalDigest: signed.jobCanonicalDigest,
      targetDeviceID: signed.targetDeviceID,
      targetSignature: TatwoDeviceSignatureV1(
        purpose: signature.purpose,
        deviceID: signature.deviceID,
        keyID: signature.keyID,
        keyGeneration: signature.keyGeneration,
        payloadDigest: signature.payloadDigest,
        signedAt: signature.signedAt,
        signature: String(repeating: "00", count: 64)))
    let verification = fixture.verify(results: [tampered], trust: fixtureTrust.trust)
    XCTAssertFalse(verification.passed)
    XCTAssertTrue(verification.conclusion.contains("signature rejected"))
  }

  func testUnsignedResultsRequireExplicitTransportOnlyOptIn() throws {
    let fixture = try plan()
    let unsigned = try fixture.jobSpecs.map { try result($0) }
    let rejected = fixture.verify(results: unsigned)
    XCTAssertFalse(rejected.passed)
    XCTAssertEqual(rejected.trustSource, "none")

    let degraded = fixture.verify(
      results: unsigned,
      allowUnsignedResults: true)
    XCTAssertEqual(degraded.outcome, .degraded)
    XCTAssertEqual(degraded.trustSource, "transport-only")
    XCTAssertTrue(degraded.conclusion.contains("allowUnsignedResults"))
    XCTAssertTrue(degraded.conclusion.contains("不等於通過"))
  }

  func testMixedSignedAndUnsignedResultsFailWholeRollup() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let signed = try result(
      fixture.jobSpecs[0],
      authority: fixtureTrust.authority,
      identity: fixtureTrust.identities[fixture.jobSpecs[0].targetDeviceID])
    let unsigned = try result(fixture.jobSpecs[1])
    let verification = fixture.verify(
      results: [signed, unsigned],
      allowUnsignedResults: true)
    XCTAssertFalse(verification.passed)
    XCTAssertTrue(verification.invalidShardKeys.contains("signature-mode-mix"))
  }

  func testTransportOnlyVerificationIsExplicitlyDegraded() throws {
    let fixture = try plan()
    let fixtureTrust = try trustFixture()
    let results = try fixture.jobSpecs.map {
      try result(
        $0,
        authority: fixtureTrust.authority,
        identity: fixtureTrust.identities[$0.targetDeviceID])
    }
    let verification = fixture.verify(
      results: results,
      allowUnsignedResults: true)
    XCTAssertEqual(verification.outcome, .degraded)
    XCTAssertEqual(verification.trustSource, "transport-only")
    XCTAssertTrue(verification.conclusion.contains("trustSource: transport-only"))
    XCTAssertTrue(verification.conclusion.contains("不等於通過"))
  }
}

private final class MemoryDevicePrivateKeyStore:
  @unchecked Sendable,
  TatwoDevicePrivateKeyStore
{
  private var keys: [String: Data] = [:]

  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
    keys["\(deviceID):\(generation)"]
  }

  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws {
    keys["\(deviceID):\(generation)"] = key
  }
}
