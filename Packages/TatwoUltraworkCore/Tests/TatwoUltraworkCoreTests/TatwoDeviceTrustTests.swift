import Foundation
#if canImport(Security)
import Security
#endif
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDeviceTrustTests: XCTestCase {
  #if canImport(Security)
  func testKeychainInteractionDenialIsDistinctFromTimeout() {
    XCTAssertEqual(
      TatwoDeviceKeychainPrivateKeyStore.readError(
        for: Int32(errSecInteractionNotAllowed)),
      .interactionNotAllowed)
    XCTAssertEqual(
      TatwoDeviceKeychainPrivateKeyStore.readError(for: Int32(-50)),
      .keychain(-50))
    XCTAssertNil(
      TatwoDeviceKeychainPrivateKeyStore.readError(
        for: Int32(errSecSuccess)))
  }
  #endif

  func testDeviceSignsAndVerifiesOnlyAgainstPinnedActiveIdentity() throws {
    let store = MemoryDevicePrivateKeyStore()
    let authority = TatwoDeviceTrustAuthority(privateKeyStore: store)
    let identity = try authority.ensureIdentity(
      deviceID: "device-mini",
      pinnedAt: "2026-07-25T12:30:00Z")
    let payload = Data(#"{"requestID":"req-1"}"#.utf8)
    let signature = try authority.sign(
      payload: payload,
      purpose: "sync-request",
      identity: identity,
      signedAt: "2026-07-25T12:31:00Z")

    try TatwoDeviceTrustAuthority.verify(
      payload: payload,
      purpose: "sync-request",
      signature: signature,
      pinnedIdentity: identity)

    XCTAssertThrowsError(
      try TatwoDeviceTrustAuthority.verify(
        payload: Data(#"{"requestID":"tampered"}"#.utf8),
        purpose: "sync-request",
        signature: signature,
        pinnedIdentity: identity)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .invalidSignature)
    }

    let revoked = TatwoDevicePublicIdentityV1(
      deviceID: identity.deviceID,
      keyID: identity.keyID,
      publicKey: identity.publicKey,
      keyGeneration: identity.keyGeneration,
      keyStatus: .revoked,
      pinnedAt: identity.pinnedAt)
    XCTAssertThrowsError(
      try TatwoDeviceTrustAuthority.verify(
        payload: payload,
        purpose: "sync-request",
        signature: signature,
        pinnedIdentity: revoked)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .inactiveKey)
    }
  }

  func testUnknownOrMismatchedLocalPrivateKeyFailsClosed() throws {
    let firstStore = MemoryDevicePrivateKeyStore()
    let first = TatwoDeviceTrustAuthority(privateKeyStore: firstStore)
    let identity = try first.ensureIdentity(
      deviceID: "device-book",
      pinnedAt: "2026-07-25T12:30:00Z")

    let empty = TatwoDeviceTrustAuthority(
      privateKeyStore: MemoryDevicePrivateKeyStore())
    XCTAssertThrowsError(try empty.assertLocalPrivateKey(matches: identity)) {
      error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .missingPrivateKey)
    }

    let otherStore = MemoryDevicePrivateKeyStore()
    let other = TatwoDeviceTrustAuthority(privateKeyStore: otherStore)
    _ = try other.ensureIdentity(
      deviceID: identity.deviceID,
      generation: identity.keyGeneration,
      pinnedAt: identity.pinnedAt)
    XCTAssertThrowsError(try other.assertLocalPrivateKey(matches: identity)) {
      error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .invalidIdentity)
    }
  }

  func testRotationIsAuthorizedByOldKeyAndRejectsReplayAgainstNewGeneration()
    throws
  {
    let store = MemoryDevicePrivateKeyStore()
    let authority = TatwoDeviceTrustAuthority(privateKeyStore: store)
    let old = try authority.ensureIdentity(
      deviceID: "device-mini",
      pinnedAt: "2026-07-25T12:30:00Z")
    let rotation = try authority.rotate(
      identity: old,
      rotatedAt: "2026-07-25T13:00:00Z")

    XCTAssertEqual(rotation.identity.keyGeneration, 2)
    XCTAssertNotEqual(rotation.identity.keyID, old.keyID)
    try TatwoDeviceTrustAuthority.verifyRotation(
      rotation.receipt,
      oldIdentity: old)
    try authority.assertLocalPrivateKey(matches: rotation.identity)

    let stalePayload = Data("next-request".utf8)
    let staleSignature = try authority.sign(
      payload: stalePayload,
      purpose: "sync-request",
      identity: old,
      signedAt: "2026-07-25T13:01:00Z")
    XCTAssertThrowsError(
      try TatwoDeviceTrustAuthority.verify(
        payload: stalePayload,
        purpose: "sync-request",
        signature: staleSignature,
        pinnedIdentity: rotation.identity)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .invalidSignature)
    }

    var replay = rotation.receipt
    replay = TatwoDeviceKeyRotationReceiptV1(
      deviceID: replay.deviceID,
      oldKeyID: replay.oldKeyID,
      oldKeyGeneration: replay.oldKeyGeneration,
      newIdentity: TatwoDevicePublicIdentityV1(
        deviceID: replay.newIdentity.deviceID,
        keyID: replay.newIdentity.keyID,
        publicKey: replay.newIdentity.publicKey,
        keyGeneration: 3,
        keyStatus: .active,
        pinnedAt: replay.newIdentity.pinnedAt),
      rotatedAt: replay.rotatedAt,
      authorityEpoch: replay.authorityEpoch,
      supersedesRevocationEpoch: replay.supersedesRevocationEpoch,
      authorization: replay.authorization)
    XCTAssertThrowsError(
      try TatwoDeviceTrustAuthority.verifyRotation(
        replay,
        oldIdentity: old)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .invalidRotation)
    }
  }

  func testPrimarySignedRevocationBlocksTargetKeyAndRejectsWrongEpoch()
    throws
  {
    let store = MemoryDevicePrivateKeyStore()
    let authority = TatwoDeviceTrustAuthority(privateKeyStore: store)
    let primary = try authority.ensureIdentity(
      deviceID: "device-mini",
      pinnedAt: "2026-07-25T12:30:00Z")
    let target = try authority.ensureIdentity(
      deviceID: "device-book",
      pinnedAt: "2026-07-25T12:31:00Z")
    let revocation = try authority.revoke(
      targetIdentity: target,
      authorizedBy: primary,
      authorityEpoch: 7,
      reason: "device replaced",
      revokedAt: "2026-07-25T14:00:00Z")

    XCTAssertEqual(revocation.identity.keyStatus, .revoked)
    try TatwoDeviceTrustAuthority.verifyRevocation(
      revocation.receipt,
      targetIdentity: target,
      authorizerIdentity: primary,
      expectedAuthorityEpoch: 7)

    XCTAssertThrowsError(
      try TatwoDeviceTrustAuthority.verifyRevocation(
        revocation.receipt,
        targetIdentity: target,
        authorizerIdentity: primary,
        expectedAuthorityEpoch: 8)
    ) { error in
      XCTAssertEqual(error as? TatwoDeviceTrustError, .invalidRevocation)
    }
  }

  func testTestFileStoreRequiresExplicitAuthorizationAndStaysAtMode0600()
    throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatwo-device-trust-\(UUID().uuidString)")
    defer {
      if FileManager.default.fileExists(atPath: root.path) {
        try? FileManager.default.removeItem(at: root)
      }
    }
    let testEnv = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]

    XCTAssertThrowsError(
      try TatwoDeviceTestFilePrivateKeyStore(
        rootURL: root,
        testModeAuthorized: false,
        environment: testEnv)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDeviceTrustError,
        .testStorageNotAuthorized)
    }

    // Caller Boolean alone is insufficient without TATWO_TEST_MODE=1.
    XCTAssertThrowsError(
      try TatwoDeviceTestFilePrivateKeyStore(
        rootURL: root,
        testModeAuthorized: true,
        environment: [:])
    ) { error in
      XCTAssertEqual(
        error as? TatwoDeviceTrustError,
        .testStorageNotAuthorized)
    }

    let store = try TatwoDeviceTestFilePrivateKeyStore(
      rootURL: root,
      testModeAuthorized: true,
      environment: testEnv)
    let authority = TatwoDeviceTrustAuthority(privateKeyStore: store)
    _ = try authority.ensureIdentity(
      deviceID: "device-test",
      pinnedAt: "2026-07-25T12:30:00Z")

    let key = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil).first)
    let attributes = try FileManager.default.attributesOfItem(atPath: key.path)
    XCTAssertEqual(
      (attributes[.posixPermissions] as? NSNumber)?.intValue,
      0o600)
  }
}

private final class MemoryDevicePrivateKeyStore:
  @unchecked Sendable,
  TatwoDevicePrivateKeyStore
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
    let id = "\(deviceID):\(generation)"
    if let existing = keys[id], existing != key {
      throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
    }
    keys[id] = key
  }
}
