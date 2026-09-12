import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoDeviceTrustPinStoreTests: XCTestCase {
  private let testEnv = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]

  private func tempRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-pin-store-\(label)-\(UUID().uuidString)",
      isDirectory: true)
  }

  private func fileEpochAnchor(for storeRoot: URL) -> TatwoDeviceTrustPinStoreFileEpochAnchor {
    TatwoDeviceTrustPinStoreFileEpochAnchor(
      url: storeRoot.appendingPathComponent("epoch-anchor.json"))
  }

  private func enrollHost(
    deviceID: String,
    keyStore: MemoryDevicePrivateKeyStore = MemoryDevicePrivateKeyStore(),
    storeRoot: URL
  ) throws -> (
    trust: TatwoLoopJobChannelTrust,
    pinStore: TatwoDeviceTrustPinStore,
    keyStore: MemoryDevicePrivateKeyStore
  ) {
    let trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: deviceID,
      privateKeyStore: keyStore,
      environment: testEnv)
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: storeRoot,
      authority: trust.authority,
      localIdentity: trust.localIdentity,
      epochAnchor: fileEpochAnchor(for: storeRoot),
      environment: testEnv)
    try pinStore.pin(trust.localIdentity)
    return (trust, pinStore, keyStore)
  }

  private func writeIdentityFile(
    _ identity: TatwoDevicePublicIdentityV1,
    in directory: URL,
    name: String = "identity.json"
  ) throws -> (url: URL, fingerprint: String) {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(identity)
    try data.write(to: url, options: .atomic)
    return (url, TatwoDeviceTrustPinStore.sha256Fingerprint(of: data))
  }

  func testTamperedPinRecordIsDroppedOnLoad() throws {
    let root = tempRoot("tamper")
    defer { try? FileManager.default.removeItem(at: root) }

    let hostKeys = MemoryDevicePrivateKeyStore()
    let peerKeys = MemoryDevicePrivateKeyStore()
    let host = try enrollHost(deviceID: "host-a", keyStore: hostKeys, storeRoot: root)
    let peer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "peer-b",
      privateKeyStore: peerKeys)

    try host.pinStore.pin(peer.localIdentity)
    let loadedOK = try host.pinStore.load()
    XCTAssertEqual(loadedOK.pins["peer-b"]?.deviceID, "peer-b")
    XCTAssertEqual(loadedOK.rejectedPinCount, 0)

    // Hand-edit public key material inside the co-signed pin record.
    let pinURL = root
      .appendingPathComponent("pins", isDirectory: true)
      .appendingPathComponent("peer-b.json")
    var raw = String(decoding: try Data(contentsOf: pinURL), as: UTF8.self)
    // Flip a character inside the base64 public key field without re-signing.
    if let range = raw.range(of: #""publicKey"\s*:\s*"[A-Za-z0-9+/=]+""#, options: .regularExpression) {
      var slice = String(raw[range])
      if let idx = slice.lastIndex(where: { $0.isLetter || $0.isNumber }) {
        let ch = slice[idx]
        let replacement: Character = ch == "A" ? "B" : "A"
        slice.replaceSubrange(idx...idx, with: String(replacement))
        raw.replaceSubrange(range, with: slice)
      }
    } else {
      return XCTFail("could not locate publicKey field to tamper")
    }
    try Data(raw.utf8).write(to: pinURL)

    let reloaded = try host.pinStore.load()
    XCTAssertNil(reloaded.pins["peer-b"], "tampered pin must be dropped")
    XCTAssertGreaterThanOrEqual(reloaded.rejectedPinCount, 1)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: host.pinStore.journalURL.path),
      "reject must be journaled")
  }

  func testPinImportFingerprintMismatchIsHardReject() throws {
    let root = tempRoot("fp-mismatch")
    defer { try? FileManager.default.removeItem(at: root) }

    let host = try enrollHost(deviceID: "host-fp", storeRoot: root)
    let peer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "peer-fp",
      privateKeyStore: MemoryDevicePrivateKeyStore())
    let file = try writeIdentityFile(
      peer.localIdentity,
      in: root.appendingPathComponent("export", isDirectory: true))

    XCTAssertThrowsError(
      try host.pinStore.pinImport(
        identityFileURL: file.url,
        expectedFingerprint: String(repeating: "ab", count: 32))
    ) { error in
      guard case TatwoDeviceTrustPinStoreError.fingerprintMismatch = error else {
        return XCTFail("expected fingerprintMismatch, got \(error)")
      }
    }
    let loaded = try host.pinStore.load()
    XCTAssertNil(loaded.pins["peer-fp"])
  }

  func testRevocationPersistsAcrossReload() throws {
    let root = tempRoot("revoke-persist")
    defer { try? FileManager.default.removeItem(at: root) }

    let hostKeys = MemoryDevicePrivateKeyStore()
    let peerKeys = MemoryDevicePrivateKeyStore()
    let host = try enrollHost(deviceID: "host-rev", keyStore: hostKeys, storeRoot: root)
    let peer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "peer-rev",
      privateKeyStore: peerKeys)
    try host.pinStore.pin(peer.localIdentity)

    // Authorizer = host self (already pinned), target = peer.
    var trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "host-rev",
      privateKeyStore: hostKeys,
      durablePinStoreRoot: root,
      loadDurablePins: true,
      environment: testEnv)
    XCTAssertEqual(trust.pinnedIdentities["peer-rev"]?.keyStatus, .active)

    let revocation = try trust.authority.revoke(
      targetIdentity: peer.localIdentity,
      authorizedBy: trust.localIdentity,
      authorityEpoch: 7,
      reason: "device retired",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    trust = try trust.ingestRevocationReceipt(
      revocation.receipt,
      expectedAuthorityEpoch: 7,
      durableStore: host.pinStore)
    XCTAssertEqual(trust.pinnedIdentities["peer-rev"]?.keyStatus, .revoked)

    // "Process restart": new enroll from same keys + durable store.
    let reloaded = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "host-rev",
      privateKeyStore: hostKeys,
      durablePinStoreRoot: root,
      loadDurablePins: true,
      environment: testEnv)
    XCTAssertEqual(reloaded.pinnedIdentities["peer-rev"]?.keyStatus, .revoked)

    let payload = Data("post-reload".utf8)
    let sig = try peer.sign(payload: payload, purpose: .loopJob)
    XCTAssertThrowsError(
      try reloaded.verify(
        payload: payload,
        purpose: .loopJob,
        signature: sig,
        expectedDeviceID: "peer-rev")
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: "peer-rev",
          reason: TatwoLoopChannelRejectReasonV1.revoked.rawValue))
    }
  }

  func testTwoIndependentStoresMutualPinJobChainAndUnpinnedReject() throws {
    let miniRoot = tempRoot("mini")
    let bookRoot = tempRoot("book")
    let channelRoot = tempRoot("channel")
    defer {
      try? FileManager.default.removeItem(at: miniRoot)
      try? FileManager.default.removeItem(at: bookRoot)
      try? FileManager.default.removeItem(at: channelRoot)
    }

    let miniKeys = MemoryDevicePrivateKeyStore()
    let bookKeys = MemoryDevicePrivateKeyStore()
    let miniHost = try enrollHost(
      deviceID: "mini-dispatch",
      keyStore: miniKeys,
      storeRoot: miniRoot)
    let bookHost = try enrollHost(
      deviceID: "macbook-runner",
      keyStore: bookKeys,
      storeRoot: bookRoot)

    // Out-of-band export + fingerprint pin-import (simulate ssh/device-sync copy).
    let exportDir = tempRoot("exports")
    defer { try? FileManager.default.removeItem(at: exportDir) }
    let miniExport = try writeIdentityFile(
      miniHost.trust.localIdentity,
      in: exportDir,
      name: "mini.json")
    let bookExport = try writeIdentityFile(
      bookHost.trust.localIdentity,
      in: exportDir,
      name: "book.json")

    _ = try miniHost.pinStore.pinImport(
      identityFileURL: bookExport.url,
      expectedFingerprint: bookExport.fingerprint)
    _ = try bookHost.pinStore.pinImport(
      identityFileURL: miniExport.url,
      expectedFingerprint: miniExport.fingerprint)

    // Reload as if restarting each host process.
    let miniTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "mini-dispatch",
      privateKeyStore: miniKeys,
      durablePinStoreRoot: miniRoot,
      loadDurablePins: true,
      environment: testEnv)
    let bookTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "macbook-runner",
      privateKeyStore: bookKeys,
      durablePinStoreRoot: bookRoot,
      loadDurablePins: true,
      environment: testEnv)
    XCTAssertNotNil(miniTrust.pinnedIdentities["macbook-runner"])
    XCTAssertNotNil(bookTrust.pinnedIdentities["mini-dispatch"])

    let miniChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: miniTrust, environment: testEnv)
    let bookChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: bookTrust, environment: testEnv)

    let work = channelRoot.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = TatwoLoopJobV1(
      jobID: "job-mutual-pin",
      logicalJobID: "logical-job-mutual-pin",
      contractID: "contract-pin-e2e",
      goalID: "goal-pin-e2e",
      identity: .sub,
      originDeviceID: "mini-dispatch",
      targetDeviceID: "macbook-runner",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["mutual-pin"])),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 2,
        maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    _ = try miniChannel.enqueue(job)
    let accepted = try bookChannel.jobs(forTargetDeviceID: "macbook-runner")
    XCTAssertTrue(accepted.contains { $0.jobID == job.jobID })

    let runner = try TatwoLoopRunnerV1(
      channel: bookChannel,
      deviceID: "macbook-runner",
      pollIntervalSec: 0.01,
      environment: [:],
      engine: ProcessEngineBinding.sandboxProbe,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: bookRoot.appendingPathComponent("runner-state", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 }))
    let receipts = try runner.runUntilIdle()
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts[0].jobID, job.jobID)
    XCTAssertEqual(receipts[0].status, .completed, receipts[0].message ?? "")
    XCTAssertNotNil(try bookChannel.result(for: job.jobID))
    XCTAssertNotNil(try bookChannel.ack(for: job.jobID))
    // Origin (mini) can verify runner-signed result via durable pin.
    let resultPayload = try Data(
      contentsOf: bookChannel.resultURL(forJobID: job.jobID))
    let resultSig = try JSONDecoder().decode(
      TatwoDeviceSignatureV1.self,
      from: Data(contentsOf: bookChannel.resultSignatureURL(forJobID: job.jobID)))
    try miniTrust.verify(
      payload: resultPayload,
      purpose: .loopResult,
      signature: resultSig,
      expectedDeviceID: "macbook-runner")

    // Unpinned stranger still rejected (empty third store / no pin).
    let stranger = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "stranger",
      privateKeyStore: MemoryDevicePrivateKeyStore())
    let strangerChannel = TatwoLoopJobChannel(rootURL: channelRoot, trust: stranger, environment: testEnv)

    // Stranger-signed artifact rejected by book (unknown_identity).
    let forgedJob = TatwoLoopJobV1(
      jobID: "job-stranger",
      logicalJobID: "logical-job-stranger",
      contractID: "contract-pin-e2e",
      goalID: "goal-pin-e2e",
      identity: .sub,
      originDeviceID: "stranger",
      targetDeviceID: "macbook-runner",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["nope"])),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 2,
        maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try strangerChannel.enqueue(forgedJob)
    let bookSees = try bookChannel.jobs(forTargetDeviceID: "macbook-runner")
    XCTAssertFalse(bookSees.contains { $0.jobID == forgedJob.jobID })
    let rejects = try bookChannel.rejections(for: forgedJob.jobID)
    XCTAssertTrue(
      rejects.contains { $0.reason == .unknownIdentity },
      "expected unknown_identity reject, got \(rejects.map(\.reason.rawValue))")
  }

  func testEmptyDurableStoreDoesNotDefaultTrustPeers() throws {
    let root = tempRoot("empty")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let keys = MemoryDevicePrivateKeyStore()
    let trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "solo",
      privateKeyStore: keys,
      durablePinStoreRoot: root,
      loadDurablePins: true,
      environment: testEnv)
    XCTAssertEqual(trust.pinnedIdentities.count, 1)
    XCTAssertNotNil(trust.pinnedIdentities["solo"])

    let peer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "peer-untrusted",
      privateKeyStore: MemoryDevicePrivateKeyStore(),
      environment: testEnv)
    let payload = Data("x".utf8)
    let sig = try peer.sign(payload: payload, purpose: .loopJob)
    XCTAssertThrowsError(
      try trust.verify(
        payload: payload,
        purpose: .loopJob,
        signature: sig,
        expectedDeviceID: "peer-untrusted")
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopJobStateError,
        .signatureRejected(
          jobID: "peer-untrusted",
          reason: TatwoLoopChannelRejectReasonV1.unknownIdentity.rawValue))
    }
  }

  func testRevokedDurablePinCannotBeOverwrittenByAdditionalPinsOrWithPin() throws {
    let root = tempRoot("revoke-merge")
    defer { try? FileManager.default.removeItem(at: root) }

    let hostKeys = MemoryDevicePrivateKeyStore()
    let peerKeys = MemoryDevicePrivateKeyStore()
    let host = try enrollHost(deviceID: "host-merge", keyStore: hostKeys, storeRoot: root)
    let peer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "peer-merge",
      privateKeyStore: peerKeys,
      environment: testEnv)
    try host.pinStore.pin(peer.localIdentity)

    var trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "host-merge",
      privateKeyStore: hostKeys,
      durablePinStoreRoot: root,
      loadDurablePins: true,
      environment: testEnv)
    let revocation = try trust.authority.revoke(
      targetIdentity: peer.localIdentity,
      authorizedBy: trust.localIdentity,
      authorityEpoch: 3,
      reason: "compromised",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    trust = try trust.ingestRevocationReceipt(
      revocation.receipt,
      expectedAuthorityEpoch: 3,
      durableStore: host.pinStore)
    XCTAssertEqual(trust.pinnedIdentities["peer-merge"]?.keyStatus, .revoked)

    // additionalPins must not resurrect a durable revoked pin.
    XCTAssertThrowsError(
      try TatwoLoopJobChannelTrust.enroll(
        deviceID: "host-merge",
        privateKeyStore: hostKeys,
        additionalPins: [peer.localIdentity],
        durablePinStoreRoot: root,
        loadDurablePins: true,
        environment: testEnv)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDeviceTrustPinMergeError,
        .cannotUnrevoke(deviceID: "peer-merge"))
    }

    // withPin must use the same monotonic merge policy.
    XCTAssertThrowsError(
      try trust.withPin(peer.localIdentity)
    ) { error in
      XCTAssertEqual(
        error as? TatwoDeviceTrustPinMergeError,
        .cannotUnrevoke(deviceID: "peer-merge"))
    }
  }

  func testDeletingRevocationAndReplayingActivePinFailsClosedOnLoad() throws {
    let root = tempRoot("revoke-rollback")
    defer { try? FileManager.default.removeItem(at: root) }

    let hostKeys = MemoryDevicePrivateKeyStore()
    let peerKeys = MemoryDevicePrivateKeyStore()
    let host = try enrollHost(deviceID: "host-roll", keyStore: hostKeys, storeRoot: root)
    let peer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "peer-roll",
      privateKeyStore: peerKeys,
      environment: testEnv)
    try host.pinStore.pin(peer.localIdentity)

    // Snapshot the co-signed active pin record before revocation.
    let pinURL = root
      .appendingPathComponent("pins", isDirectory: true)
      .appendingPathComponent("peer-roll.json")
    let activePinBytes = try Data(contentsOf: pinURL)

    let trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "host-roll",
      privateKeyStore: hostKeys,
      durablePinStoreRoot: root,
      loadDurablePins: true,
      environment: testEnv)
    let revocation = try trust.authority.revoke(
      targetIdentity: peer.localIdentity,
      authorizedBy: trust.localIdentity,
      authorityEpoch: 11,
      reason: "retired",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    _ = try trust.ingestRevocationReceipt(
      revocation.receipt,
      expectedAuthorityEpoch: 11,
      durableStore: host.pinStore)

    // Attacker deletes revocation tombstone and restores pre-revoke active pin.
    let revDir = root.appendingPathComponent("revocations", isDirectory: true)
    let revFiles = try FileManager.default.contentsOfDirectory(
      at: revDir,
      includingPropertiesForKeys: nil)
    for file in revFiles {
      try FileManager.default.removeItem(at: file)
    }
    try activePinBytes.write(to: pinURL, options: .atomic)

    XCTAssertThrowsError(try host.pinStore.load()) { error in
      guard case TatwoDeviceTrustPinStoreError.missingRevocationTombstone(
        let deviceID,
        let epoch
      ) = error else {
        return XCTFail("expected missingRevocationTombstone, got \(error)")
      }
      XCTAssertEqual(deviceID, "peer-roll")
      XCTAssertEqual(epoch, 11)
    }
  }

  func testSignatureMaxAgeOverrideRequiresTestModeAndRejectsHugeValues() throws {
    // Production path ignores env and stays at 900s.
    let production = try TatwoLoopJobChannelTrust.signatureMaxAgeSec(
      environment: [TatwoLoopJobChannelTrust.signatureMaxAgeEnvKey: "1e300"])
    XCTAssertEqual(production, TatwoLoopJobChannelTrust.defaultSignatureMaxAgeSec)

    // Test mode with absurd value refuses startup (throw, no clamp).
    XCTAssertThrowsError(
      try TatwoLoopJobChannelTrust.signatureMaxAgeSec(
        environment: [
          TatwoLoopJobChannelTrust.testModeEnvKey: "1",
          TatwoLoopJobChannelTrust.signatureMaxAgeEnvKey: "1e300",
        ])
    ) { error in
      guard case TatwoLoopJobStateError.invalidPayload = error else {
        return XCTFail("expected invalidPayload, got \(error)")
      }
    }

    let ok = try TatwoLoopJobChannelTrust.signatureMaxAgeSec(
      environment: [
        TatwoLoopJobChannelTrust.testModeEnvKey: "1",
        TatwoLoopJobChannelTrust.signatureMaxAgeEnvKey: "120",
      ])
    XCTAssertEqual(ok, 120)
  }

  func testRunOnceReloadsTrustAfterDurableRevocation() throws {
    let root = tempRoot("live-reload")
    let channelRoot = tempRoot("live-reload-channel")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: channelRoot)
    }

    let hostKeys = MemoryDevicePrivateKeyStore()
    let peerKeys = MemoryDevicePrivateKeyStore()
    let host = try enrollHost(deviceID: "runner-live", keyStore: hostKeys, storeRoot: root)
    let origin = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-live",
      privateKeyStore: peerKeys,
      environment: testEnv)
    try host.pinStore.pin(origin.localIdentity)
    // Origin must pin runner to sign jobs targeting it (mutual durable pins).
    let originStore = TatwoDeviceTrustPinStore(
      rootURL: root.appendingPathComponent("origin-store", isDirectory: true),
      authority: origin.authority,
      localIdentity: origin.localIdentity,
      epochAnchor: fileEpochAnchor(
        for: root.appendingPathComponent("origin-store", isDirectory: true)),
      environment: testEnv)
    try originStore.pin(origin.localIdentity)
    try originStore.pin(host.trust.localIdentity)

    let runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-live",
      privateKeyStore: hostKeys,
      durablePinStoreRoot: root,
      loadDurablePins: true,
      environment: testEnv)
    XCTAssertEqual(runnerTrust.pinnedIdentities["origin-live"]?.keyStatus, .active)
    let originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-live",
      privateKeyStore: peerKeys,
      durablePinStoreRoot: root.appendingPathComponent("origin-store"),
      loadDurablePins: true,
      environment: testEnv)

    let channel = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: runnerTrust,
      environment: testEnv)
    let originChannel = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: originTrust,
      environment: testEnv)
    let work = channelRoot.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let job = TatwoLoopJobV1(
      jobID: "job-live-revoke",
      logicalJobID: "logical-job-live-revoke",
      contractID: "contract-live",
      goalID: "goal-live",
      identity: .sub,
      originDeviceID: "origin-live",
      targetDeviceID: "runner-live",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["should-not-run"])),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["cancel-file"]),
      createdAt: Date())
    _ = try originChannel.enqueue(job)

    // Long-running consumer still holds the pre-revocation snapshot generation.
    let generationBefore = runnerTrust.pinStoreGeneration
    let revocation = try runnerTrust.authority.revoke(
      targetIdentity: origin.localIdentity,
      authorizedBy: runnerTrust.localIdentity,
      authorityEpoch: 5,
      reason: "key leak",
      revokedAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    // Durable ingest only (simulate CLI ingest while runner process keeps old trust).
    _ = try host.pinStore.ingestRevocation(
      revocation.receipt,
      expectedAuthorityEpoch: 5)
    XCTAssertGreaterThan(try host.pinStore.currentStoreGeneration(), generationBefore)

    let runner = try TatwoLoopRunnerV1(
      channel: channel,
      deviceID: "runner-live",
      pollIntervalSec: 0.01,
      environment: testEnv,
      engine: ProcessEngineBinding.sandboxProbe,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-state", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 }))
    let receipts = try runner.runOnce()
    XCTAssertEqual(receipts.count, 0, "revoked origin must not execute after live reload")
    XCTAssertEqual(channel.trust.pinnedIdentities["origin-live"]?.keyStatus, .revoked)
    let listed = try channel.jobs(forTargetDeviceID: "runner-live")
    XCTAssertFalse(listed.contains { $0.jobID == job.jobID })
  }
}

/// In-memory private key store for unit tests only.
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
    let slot = "\(deviceID):\(generation)"
    if let existing = keys[slot], existing != key {
      throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
    }
    keys[slot] = key
  }
}
