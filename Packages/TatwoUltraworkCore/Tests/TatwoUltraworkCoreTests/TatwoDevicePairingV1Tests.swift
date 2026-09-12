import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDevicePairingV1Tests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let primary = "mini-primary"
  private let epoch: UInt64 = 3

  private func stableDevice(
    fingerprint: String = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ) -> TatwoDiscoveredDeviceV1 {
    TatwoDiscoveredDeviceV1(
      transport: .thunderbolt,
      name: "Peer-Mac",
      identityFingerprint: fingerprint,
      interfaces: ["thunderbolt"],
      capabilitiesObserved: [],
      trustState: TatwoDiscoveredDeviceV1.requiredTrustState)
  }

  private func unstableDevice() -> TatwoDiscoveredDeviceV1 {
    TatwoDiscoveredDeviceV1(
      transport: .usb,
      name: "Unknown-Hub",
      identityFingerprint: "unstable:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      interfaces: ["usb"],
      trustState: TatwoDiscoveredDeviceV1.requiredTrustState)
  }

  // MARK: - Full flow

  func testFullFlowReachesPairedWithoutCanBeManaged() throws {
    let device = stableDevice()
    let begun = try TatwoDevicePairingFacadeV1.beginPairing(
      device: device,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "ABCD1234",
      requestID: "req-1")
    var session = begun.session
    let request = begun.request

    XCTAssertEqual(session.state, .pairingRequested)
    XCTAssertEqual(request.pairingCode.seed, "ABCD1234")
    XCTAssertEqual(
      request.pairingCode.expiresAt.timeIntervalSince(request.pairingCode.createdAt),
      TatwoDevicePairingCodeRecordV1.ttlSeconds)
    XCTAssertFalse(request.grantsExecutionCapability)
    XCTAssertTrue(request.capabilityList.isEmpty)
    XCTAssertFalse(session.canBeManaged)

    try session.apply(.verifyPairingCode(seed: "ABCD1234"), now: now.addingTimeInterval(30))
    XCTAssertEqual(session.state, .pairingCodeVerified)
    XCTAssertNotNil(session.activeCode?.consumedAt)
    XCTAssertFalse(session.canBeManaged)

    try session.apply(.completePairing, now: now.addingTimeInterval(31))
    XCTAssertEqual(session.state, .paired)
    guard let proof = session.pairingProof else {
      return XCTFail("paired session must carry pairingProof")
    }
    XCTAssertEqual(proof.deviceFingerprint, device.identityFingerprint)
    XCTAssertNoThrow(try session.verifyPairedProof(proof))
    // Pairing ≠ manage / S3 enroll.
    XCTAssertFalse(session.canBeManaged)
    XCTAssertTrue(session.mayBecomeManagedAfterEnroll)

    // S3 seam may raise manage only after paired.
    try session.markEnrolledManagedForS3(pairingProof: proof)
    XCTAssertTrue(session.canBeManaged)
  }

  func testForgedPairingProofRejectedByS3ManageSeam() throws {
    let begun = try TatwoDevicePairingFacadeV1.beginPairing(
      device: stableDevice(),
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "PROOF001")
    var session = begun.session
    try session.apply(.verifyPairingCode(seed: "PROOF001"), now: now.addingTimeInterval(1))
    try session.apply(.completePairing, now: now.addingTimeInterval(2))
    guard let proof = session.pairingProof else {
      return XCTFail("missing proof")
    }
    let forged = TatwoDevicePairingProofV1(
      verificationDigest: "sha256:forged",
      verifiedAt: proof.verifiedAt,
      deviceFingerprint: proof.deviceFingerprint)
    XCTAssertThrowsError(try session.markEnrolledManagedForS3(pairingProof: forged)) { error in
      XCTAssertEqual(error as? TatwoDevicePairingErrorV1, .pairingProofInvalid)
    }
    XCTAssertFalse(session.canBeManaged)
  }

  // MARK: - Skip steps rejected

  func testStateMachineSkipsRejected() throws {
    let device = stableDevice()
    var session = TatwoDevicePairingSessionV1(
      device: device,
      authorityPrimary: primary,
      authorityEpoch: epoch)

    // discovered ↛ verify
    XCTAssertThrowsError(
      try session.apply(.verifyPairingCode(seed: "ABCD1234"), now: now)
    ) { error in
      guard let err = error as? TatwoDevicePairingErrorV1 else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertEqual(
        err,
        .invalidTransition(from: .discovered, event: "verifyPairingCode"))
    }

    // discovered ↛ complete
    XCTAssertThrowsError(try session.apply(.completePairing, now: now)) { error in
      XCTAssertEqual(
        error as? TatwoDevicePairingErrorV1,
        .invalidTransition(from: .discovered, event: "completePairing"))
    }

    let code = try TatwoDevicePairingCodeEngineV1.mint(
      createdBy: primary,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "SKIP0001")
    let request = try TatwoDevicePairingRequestV1.make(
      from: device, pairingCode: code, now: now)
    try session.apply(.requestPairing(request), now: now)

    // pairingRequested ↛ complete (must verify first)
    XCTAssertThrowsError(try session.apply(.completePairing, now: now)) { error in
      XCTAssertEqual(
        error as? TatwoDevicePairingErrorV1,
        .invalidTransition(from: .pairingRequested, event: "completePairing"))
    }

    try session.apply(.verifyPairingCode(seed: "SKIP0001"), now: now.addingTimeInterval(1))
    // pairingCodeVerified ↛ requestPairing
    let code2 = try TatwoDevicePairingCodeEngineV1.mint(
      createdBy: primary,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "SKIP0002")
    let request2 = try TatwoDevicePairingRequestV1.make(
      from: device, pairingCode: code2, now: now)
    XCTAssertThrowsError(try session.apply(.requestPairing(request2), now: now)) { error in
      XCTAssertEqual(
        error as? TatwoDevicePairingErrorV1,
        .invalidTransition(from: .pairingCodeVerified, event: "requestPairing"))
    }
  }

  // MARK: - Expired code

  func testExpiredCodeRejected() throws {
    let device = stableDevice()
    let code = try TatwoDevicePairingCodeEngineV1.mint(
      createdBy: primary,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "EXPIRE01")
    let request = try TatwoDevicePairingRequestV1.make(
      from: device, pairingCode: code, now: now)
    var session = TatwoDevicePairingSessionV1(
      device: device,
      authorityPrimary: primary,
      authorityEpoch: epoch)
    try session.apply(.requestPairing(request), now: now)

    let afterExpiry = now.addingTimeInterval(TatwoDevicePairingCodeRecordV1.ttlSeconds + 1)
    XCTAssertThrowsError(
      try session.apply(.verifyPairingCode(seed: "EXPIRE01"), now: afterExpiry)
    ) { error in
      XCTAssertEqual(error as? TatwoDevicePairingErrorV1, .codeExpired)
    }
    XCTAssertEqual(session.state, .pairingRequested)
  }

  // MARK: - Replay / reuse

  func testReusedCodeRejected() throws {
    let device = stableDevice()
    var session = try TatwoDevicePairingFacadeV1.beginPairing(
      device: device,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "REUSE001").session

    try session.apply(
      .verifyPairingCode(seed: "REUSE001"),
      now: now.addingTimeInterval(10))
    XCTAssertEqual(session.state, .pairingCodeVerified)

    // Same code again → already consumed.
    XCTAssertThrowsError(
      try session.apply(
        .verifyPairingCode(seed: "REUSE001"),
        now: now.addingTimeInterval(11))
    ) { error in
      XCTAssertEqual(error as? TatwoDevicePairingErrorV1, .codeAlreadyConsumed)
    }

    // Engine-level consume replay.
    let minted = try TatwoDevicePairingCodeEngineV1.mint(
      createdBy: primary,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "REUSE002")
    let once = try TatwoDevicePairingCodeEngineV1.consume(
      seed: "REUSE002",
      record: minted,
      expectedPrimary: primary,
      expectedEpoch: epoch,
      now: now.addingTimeInterval(5))
    XCTAssertNotNil(once.consumedAt)
    XCTAssertThrowsError(
      try TatwoDevicePairingCodeEngineV1.consume(
        seed: "REUSE002",
        record: once,
        expectedPrimary: primary,
        expectedEpoch: epoch,
        now: now.addingTimeInterval(6))
    ) { error in
      XCTAssertEqual(error as? TatwoDevicePairingErrorV1, .codeAlreadyConsumed)
    }
  }

  // MARK: - Unstable fingerprint

  func testUnstableFingerprintRejected() throws {
    let device = unstableDevice()
    XCTAssertTrue(device.hasUnstableIdentity)

    XCTAssertThrowsError(
      try TatwoDevicePairingFacadeV1.beginPairing(
        device: device,
        authorityPrimary: primary,
        authorityEpoch: epoch,
        now: now,
        seed: "BADFP001")
    ) { error in
      guard let err = error as? TatwoDevicePairingErrorV1,
        case let .unstableIdentityForbidden(fp) = err
      else {
        return XCTFail("expected unstableIdentityForbidden, got \(error)")
      }
      XCTAssertTrue(fp.hasPrefix("unstable:"))
    }

    let code = try TatwoDevicePairingCodeEngineV1.mint(
      createdBy: primary,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "BADFP002")
    XCTAssertThrowsError(
      try TatwoDevicePairingRequestV1.make(from: device, pairingCode: code, now: now)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDevicePairingErrorV1,
        .unstableIdentityForbidden(device.identityFingerprint))
    }
  }

  // MARK: - TTL constant alignment

  func testPairingCodeTTLIs180Seconds() throws {
    let code = try TatwoDevicePairingCodeEngineV1.mint(
      createdBy: primary,
      authorityPrimary: primary,
      authorityEpoch: epoch,
      now: now,
      seed: "TTL00001")
    XCTAssertEqual(TatwoDevicePairingCodeRecordV1.ttlSeconds, 180)
    XCTAssertEqual(code.expiresAt.timeIntervalSince(code.createdAt), 180)
  }
}
