import Foundation
import XCTest
import TatwoDomainContracts
import TatwoWorkReceiptContracts

@testable import TatwoUltraworkCore

final class TatwoOriginAuthorityIntegrationTests: XCTestCase {
  private let environment = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]
  private let originID = "origin-k1"
  private let targetID = "target-k1"

  private func makeTrust() throws -> TatwoLoopJobChannelTrust {
    try TatwoLoopJobChannelTrust.enroll(
      deviceID: originID,
      privateKeyStore: K1MemoryPrivateKeyStore(),
      environment: environment)
  }

  private func makeJob() -> TatwoLoopJobV1 {
    TatwoLoopJobV1(
      jobID: "job-k1",
      logicalJobID: "logical-k1",
      dispatchNonce: "nonce-k1",
      contractID: "contract-k1",
      goalID: "goal-k1",
      identity: .sub,
      originDeviceID: originID,
      targetDeviceID: targetID,
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: "/tmp/k1",
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: 1,
        maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000))
  }

  private func assertFenced(_ operation: () throws -> Void) {
    XCTAssertThrowsError(try operation()) { error in
      guard case .originWriteFenced = error as? TatwoOriginAuthorityError else {
        return XCTFail("expected structured originWriteFenced, got \(error)")
      }
    }
  }

  func testNoLeaseChannelEnqueuePreservesLegacyBehavior() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-no-lease-\(UUID().uuidString)")
    let trust = try makeTrust()
    let channel = TatwoLoopJobChannel(
      rootURL: root,
      trust: trust,
      environment: environment)

    XCTAssertNoThrow(try channel.enqueue(makeJob()))
    XCTAssertTrue(channel.hasCommitMarker(forJobID: "job-k1"))
  }

  func testCurrentOriginWithLeaseAllowsChannelWriter() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-origin-allowed-\(UUID().uuidString)")
    let trust = try makeTrust()
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: true,
      expectedDeviceID: originID,
      expectedEpoch: 7)
    let channel = TatwoLoopJobChannel(
      rootURL: root,
      trust: trust,
      environment: environment,
      originAuthorityProvider: provider)

    XCTAssertNoThrow(try channel.enqueue(makeJob()))
    XCTAssertTrue(channel.hasCommitMarker(forJobID: "job-k1"))
  }

  func testNoLeaseDispatchRegistryPreservesLegacyBehavior() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-registry-no-lease-\(UUID().uuidString)")
    let registry = TatwoDispatchRegistry(directoryURL: root)

    XCTAssertNoThrow(try registry.beginRemoteTestFixtureUnbound(job: makeJob()))
  }

  func testOriginProjectorWriterRejectsExpiredOriginWithoutCanWriteCaller() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-projector-expired-\(UUID().uuidString)")
    let trust = try makeTrust()
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: false)
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel", isDirectory: true),
      trust: trust,
      environment: environment)
    let registry = TatwoDispatchRegistry(directoryURL: root)
    let projector = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: registry,
      originDeviceID: originID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root),
      originAuthorityProvider: provider)

    assertFenced {
      _ = try projector.enqueue(makeJob())
    }
  }

  func testOriginProjectorWriterAllowsCurrentOriginWithoutCanWriteCaller() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-projector-allowed-\(UUID().uuidString)")
    let trust = try makeTrust()
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: true,
      expectedDeviceID: originID,
      expectedEpoch: 7)
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel", isDirectory: true),
      trust: trust,
      environment: environment,
      originAuthorityProvider: provider)
    let registry = TatwoDispatchRegistry(
      directoryURL: root,
      originAuthorityProvider: provider)
    let projector = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: registry,
      originDeviceID: originID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root),
      originAuthorityProvider: provider)

    XCTAssertNoThrow(_ = try projector.enqueue(makeJob()))
  }

  func testNilDomainAuthorityAlwaysAllowsLegacyProjectorPath() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("f17-nil-domain-\(UUID().uuidString)")
    let provider = K1TestAuthorityProvider(
      authorityDomainID: nil,
      authorityEpoch: 7,
      allowed: false)
    let trust = try makeTrust()
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel", isDirectory: true),
      trust: trust,
      environment: environment,
      originAuthorityProvider: provider)
    let registry = TatwoDispatchRegistry(
      directoryURL: root,
      originAuthorityProvider: provider)
    let projector = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: registry,
      originDeviceID: originID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root),
      originAuthorityProvider: provider)

    XCTAssertNoThrow(try projector.enqueue(makeJob()))
  }

  func testResourceGatePrecedesLeaseAuthorityFence() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("f17-gate-before-authority-\(UUID().uuidString)")
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: false)
    let trust = try makeTrust()
    let channel = TatwoLoopJobChannel(
      rootURL: root.appendingPathComponent("channel", isDirectory: true),
      trust: trust,
      environment: environment,
      originAuthorityProvider: provider)
    let registry = TatwoDispatchRegistry(
      directoryURL: root,
      originAuthorityProvider: provider)
    let projector = TatwoLoopOriginProjectorV1(
      channel: channel,
      registry: registry,
      originDeviceID: originID,
      memoryGate: MemoryPressureGate(
        minFreePercent: 50,
        freePercentProvider: { 10 },
        journalDirectoryURL: root),
      originAuthorityProvider: provider)

    XCTAssertThrowsError(try projector.enqueue(makeJob())) { error in
      guard case let .resourceGateBlocked(reason) = error as? TatwoLoopJobStateError else {
        return XCTFail("expected resource gate before lease authority, got \(error)")
      }
      XCTAssertTrue(reason.contains("below gate"))
    }
  }

  func testChannelWriterRejectsExpiredOriginWithoutCanWriteCaller() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-expired-\(UUID().uuidString)")
    let trust = try makeTrust()
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: false)
    let channel = TatwoLoopJobChannel(
      rootURL: root,
      trust: trust,
      environment: environment,
      originAuthorityProvider: provider)

    assertFenced {
      _ = try channel.enqueue(makeJob())
    }
    XCTAssertFalse(channel.hasCommitMarker(forJobID: "job-k1"))
  }

  func testLeaseDomainStillFailsClosedAfterNilDomainBypass() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("f17-lease-still-fenced-\(UUID().uuidString)")
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: false)
    let channel = TatwoLoopJobChannel(
      rootURL: root,
      trust: try makeTrust(),
      environment: environment,
      originAuthorityProvider: provider)

    assertFenced {
      _ = try channel.enqueue(makeJob())
    }
  }

  func testChannelTransitionWriterRejectsExpiredOriginWithoutCanWriteCaller() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-transition-\(UUID().uuidString)")
    let trust = try makeTrust()
    let allowedProvider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: true,
      expectedDeviceID: originID,
      expectedEpoch: 7)
    let channel = TatwoLoopJobChannel(
      rootURL: root,
      trust: trust,
      environment: environment,
      originAuthorityProvider: allowedProvider)
    _ = try channel.enqueue(makeJob())

    allowedProvider.revoke()
    assertFenced {
      _ = try channel.transition(
        jobID: "job-k1",
        to: .delivered,
        reason: "target-discovered")
    }
  }

  func testProductionChannelWithoutLeaseProviderFailsClosed() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-production-rebind-\(UUID().uuidString)")
    let trust = try makeTrust()
    let channel = TatwoLoopJobChannel(
      rootURL: root,
      trust: trust,
      environment: [:],
      originAuthorityProvider: K1TestAuthorityProvider(
        authorityDomainID: "domain-k1",
        authorityEpoch: 7,
        allowed: true,
        expectedDeviceID: originID,
        expectedEpoch: 7))
    let rebound = channel.replacingOriginAuthorityProvider(
      K1TestAuthorityProvider(
        authorityDomainID: "domain-k1",
        authorityEpoch: 7,
        allowed: true,
        expectedDeviceID: originID,
        expectedEpoch: 7))
    assertFenced {
      _ = try rebound.enqueue(makeJob())
    }
  }

  func testDispatchRegistryWriterRejectsExpiredOrigin() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-registry-\(UUID().uuidString)")
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: false)
    let registry = TatwoDispatchRegistry(
      directoryURL: root,
      originAuthorityProvider: provider)

    assertFenced {
      _ = try registry.beginRemoteTestFixtureUnbound(job: makeJob())
    }
  }

  func testFleetLogicalCommitWriterRejectsExpiredOrigin() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-fleet-\(UUID().uuidString)")
    let trust = try makeTrust()
    let authority = TatwoFleetOriginAuthority(
      originDeviceID: originID,
      authorityEpoch: 7,
      trust: trust,
      highWater: TatwoFleetFileHighWaterAnchor(rootURL: root))
    let provider = K1TestAuthorityProvider(
      authorityDomainID: "domain-k1",
      authorityEpoch: 7,
      allowed: false)
    let store = TatwoFleetStore(
      rootURL: root,
      originAuthority: authority,
      originAuthorityProvider: provider)
    let commit = TatwoFleetLogicalCommitV1(
      logicalJobID: "logical-k1",
      winningJobID: "job-k1",
      winningDispatchNonce: "nonce-k1",
      targetDeviceID: targetID,
      originDeviceID: originID,
      resultStatus: .completed,
      resultDigest: nil,
      jobCanonicalDigest: "sha256:\(String(repeating: "a", count: 64))",
      committedAt: Date(timeIntervalSince1970: 1_800_000_001))

    assertFenced {
      _ = try store.commitLogical(commit)
    }
  }

  func testDurableQueryFailureRejectsWithStructuredError() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-durable-fault-\(UUID().uuidString)")
    let trust = try makeTrust()
    let provider = K1ThrowingAuthorityProvider()
    let channel = TatwoLoopJobChannel(
      rootURL: root,
      trust: trust,
      environment: environment,
      originAuthorityProvider: provider)

    XCTAssertThrowsError(try channel.enqueue(makeJob())) { error in
      guard case let .durableStoreUnavailable(surface, _) =
        error as? TatwoOriginAuthorityError
      else {
        return XCTFail("expected structured durableStoreUnavailable, got \(error)")
      }
      XCTAssertEqual(surface, "remote_loop_dispatch")
    }
  }

  func testDurableStoreCurrentOriginAllowsAuthorityQuery() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-durable-allowed-\(UUID().uuidString)")
    let trust = try makeTrust()
    let lease = TatwoAuthorityLeaseV1(
      domainID: "domain-k1",
      holderDeviceID: originID,
      epoch: 7,
      fencingToken: "fence-k1",
      observedAt: Date(timeIntervalSince1970: 1_800_000_000),
      expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
      source: .humanConfirmed,
      receiptMetadata: TatwoWorkReceiptMetadataV1(
        receiptID: "lease-k1",
        schema: "TatwoAuthorityLeaseV1",
        version: 1,
        correlationID: "contract-k1",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        sourceDeviceID: originID))
    let configuration = TatwoHandoffLeaseTransferDurableConfigurationV1(
      rootURL: root,
      highWater: TatwoFleetFileHighWaterAnchor(
        rootURL: root.appendingPathComponent("high-water", isDirectory: true)),
      signingTrust: trust)
    let store = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: lease,
      durableConfiguration: configuration)

    XCTAssertTrue(
      store.isOriginAuthority(
        deviceID: originID,
        epoch: lease.epoch,
        now: Date(timeIntervalSince1970: 1_800_000_001)))
    XCTAssertNoThrow(
      try store.requireOriginAuthority(
        deviceID: originID,
        epoch: lease.epoch,
        surface: "remote_loop_dispatch",
        now: Date(timeIntervalSince1970: 1_800_000_001)))
    XCTAssertFalse(
      store.isOriginAuthority(
        deviceID: originID,
        epoch: lease.epoch,
        now: Date(timeIntervalSince1970: 1_800_000_601)))
    XCTAssertThrowsError(
      try store.requireOriginAuthority(
        deviceID: originID,
        epoch: lease.epoch,
        surface: "remote_loop_dispatch",
        now: Date(timeIntervalSince1970: 1_800_000_601))
    ) { error in
      guard case .originWriteFenced = error as? TatwoOriginAuthorityError else {
        return XCTFail("expected expired lease fence, got \(error)")
      }
    }
  }

  func testDurableJournalCorruptionRejectsAfterRestore() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-durable-journal-\(UUID().uuidString)")
    let trust = try makeTrust()
    let lease = TatwoAuthorityLeaseV1(
      domainID: "domain-k1",
      holderDeviceID: originID,
      epoch: 7,
      fencingToken: "fence-k1",
      observedAt: Date(timeIntervalSince1970: 1_800_000_000),
      expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
      source: .humanConfirmed,
      receiptMetadata: TatwoWorkReceiptMetadataV1(
        receiptID: "lease-k1",
        schema: "TatwoAuthorityLeaseV1",
        version: 1,
        correlationID: "contract-k1",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        sourceDeviceID: originID))
    let configuration = TatwoHandoffLeaseTransferDurableConfigurationV1(
      rootURL: root,
      highWater: TatwoFleetFileHighWaterAnchor(
        rootURL: root.appendingPathComponent("high-water", isDirectory: true)),
      signingTrust: trust)
    let store = try TatwoHandoffLeaseTransferStoreV1(
      currentOriginLease: lease,
      durableConfiguration: configuration)
    let journal = root
      .appendingPathComponent("journal", isDirectory: true)
      .appendingPathComponent("\(lease.domainID).jsonl")
    var bytes = try Data(contentsOf: journal)
    bytes.append(Data("{\"tampered\":true}\n".utf8))
    try bytes.write(to: journal, options: .atomic)

    XCTAssertFalse(
      store.isOriginAuthority(
        deviceID: originID,
        epoch: lease.epoch,
        now: Date(timeIntervalSince1970: 1_800_000_001)))
    XCTAssertThrowsError(
      try store.requireOriginAuthority(
        deviceID: originID,
        epoch: lease.epoch,
        surface: "remote_loop_dispatch",
        now: Date(timeIntervalSince1970: 1_800_000_001))
    ) { error in
      guard case let .durableStoreUnavailable(surface, _) =
        error as? TatwoOriginAuthorityError
      else {
        return XCTFail("expected structured durableStoreUnavailable, got \(error)")
      }
      XCTAssertEqual(surface, "remote_loop_dispatch")
    }
    XCTAssertThrowsError(
      try store.acknowledgeReceiver(deviceID: targetID, epoch: lease.epoch + 1)
    ) { error in
      guard case .durableStoreUnavailable =
        error as? TatwoHandoffLeaseTransferErrorV1
      else {
        return XCTFail("expected direct mutation fence, got \(error)")
      }
    }
  }

  func testAuthorityDomainRegistryIsCreateOnlyAndSchemaBound() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-domain-registry-\(UUID().uuidString)")
    let registry = TatwoAuthorityDomainRegistryV1(rootURL: root)
    try registry.register(domainID: "domain-k1", registeredAt: Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertTrue(registry.isRegistered(domainID: "domain-k1"))
    XCTAssertThrowsError(try registry.register(domainID: "domain-k1")) { error in
      XCTAssertEqual(
        error as? TatwoAuthorityDomainRegistryError,
        .domainAlreadyRegistered("domain-k1"))
    }

    let marker = root
      .appendingPathComponent("domains", isDirectory: true)
      .appendingPathComponent("domain-k1.json")
    try Data(
      #"{"schema":"WrongSchema","domainID":"domain-k1","registeredAt":"2026-07-30T00:00:00Z","source":"test"}"#.utf8
    ).write(to: marker, options: .atomic)
    XCTAssertFalse(registry.isRegistered(domainID: "domain-k1"))
  }

  func testProductionLeaseConstructionRejectsUnregisteredDomain() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("k1-unregistered-lease-\(UUID().uuidString)")
    let trust = try makeTrust()
    let lease = TatwoAuthorityLeaseV1(
      domainID: "unregistered-domain",
      holderDeviceID: originID,
      epoch: 1,
      fencingToken: "fence-unregistered",
      observedAt: Date(timeIntervalSince1970: 1_800_000_000),
      expiresAt: Date(timeIntervalSince1970: 1_800_000_600),
      source: .humanConfirmed,
      receiptMetadata: TatwoWorkReceiptMetadataV1(
        receiptID: "lease-unregistered",
        schema: "TatwoAuthorityLeaseV1",
        version: 1,
        correlationID: "contract-k1",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        sourceDeviceID: originID))

    XCTAssertThrowsError(
      try TatwoHandoffLeaseTransferStoreV1(
        productionOriginLease: lease,
        durableRootURL: root,
        signingTrust: trust)
    ) { error in
      XCTAssertEqual(
        error as? TatwoAuthorityDomainRegistryError,
        .domainNotRegistered("unregistered-domain"))
    }
  }

  func testProductionBootstrapRejectsMissingOriginLease() throws {
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: originID,
        originDeviceID: originID,
        privateKeyStore: K1MemoryPrivateKeyStore())
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .missingOriginLease)
    }
  }
}

private final class K1TestAuthorityProvider:
  TatwoOriginAuthorityProviding,
  @unchecked Sendable
{
  let authorityDomainID: String?
  let authorityEpoch: UInt64?
  private let lock = NSLock()
  private var allowed: Bool
  let expectedDeviceID: String?
  let expectedEpoch: UInt64?

  init(
    authorityDomainID: String?,
    authorityEpoch: UInt64?,
    allowed: Bool,
    expectedDeviceID: String? = nil,
    expectedEpoch: UInt64? = nil
  ) {
    self.authorityDomainID = authorityDomainID
    self.authorityEpoch = authorityEpoch
    self.allowed = allowed
    self.expectedDeviceID = expectedDeviceID
    self.expectedEpoch = expectedEpoch
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
    guard allowed else { return false }
    if let expectedDeviceID, deviceID != expectedDeviceID {
      return false
    }
    if let expectedEpoch, epoch != expectedEpoch {
      return false
    }
    return true
  }
}

private struct K1ThrowingAuthorityProvider: TatwoOriginAuthorityProviding {
  let authorityDomainID: String? = "domain-k1"
  let authorityEpoch: UInt64? = 7

  func isOriginAuthority(
    deviceID: String,
    epoch: UInt64,
    now: Date
  ) -> Bool {
    false
  }

  func requireOriginAuthority(
    deviceID: String,
    epoch: UInt64,
    surface: String,
    now: Date
  ) throws {
    throw TatwoOriginAuthorityError.durableStoreUnavailable(
      surface: surface,
      detail: "test journal corruption")
  }
}

private final class K1MemoryPrivateKeyStore:
  TatwoDevicePrivateKeyStore,
  @unchecked Sendable
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
