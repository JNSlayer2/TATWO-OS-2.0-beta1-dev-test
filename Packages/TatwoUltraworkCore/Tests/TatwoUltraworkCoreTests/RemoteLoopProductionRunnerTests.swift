import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class RemoteLoopProductionRunnerTests: XCTestCase {
  /// File epoch anchors under pin-store root (avoids Keychain host coupling in unit tests).
  /// Memory private-key stores remain allowed; only TatwoDeviceTestFilePrivateKeyStore is banned.
  private let testEnv = [TatwoLoopJobChannelTrust.testModeEnvKey: "1"]

  private func tempRoot(_ label: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "tatwo-prod-runner-\(label)-\(UUID().uuidString)",
      isDirectory: true)
  }

  private func fileEpochAnchor(for storeRoot: URL) -> TatwoDeviceTrustPinStoreFileEpochAnchor {
    TatwoDeviceTrustPinStoreFileEpochAnchor(
      url: storeRoot.appendingPathComponent("epoch-anchor.json"))
  }

  func testProductionBootstrapRejectsEmptyPinStore() throws {
    let root = tempRoot("empty-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    try FileManager.default.createDirectory(at: pinRoot, withIntermediateDirectories: true)

    let keys = MemoryDevicePrivateKeyStore()
    // Enroll creates local identity only; durable root is empty of peer pins.
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: keys,
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: testEnv,
        allowTestOverrides: true)
    ) { error in
      // TEST_MODE without allow is hard-rejected first; with allow, empty store fails.
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .emptyPinStore)
    }
  }

  func testProductionBootstrapRejectsTestModeEnvironment() throws {
    let root = tempRoot("test-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinRoot, withIntermediateDirectories: true)
    let keys = MemoryDevicePrivateKeyStore()
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: keys,
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: testEnv,
        allowTestOverrides: false)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .testModeForbidden)
    }
  }

  func testProductionBootstrapRejectsNonCanonicalPinStoreRoot() throws {
    // F5: production rejects caller injection; pin-store override is still enforced once
    // layout is sealed under OS-native roots (layout-lock unit surface).
    let root = tempRoot("bad-root")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinRoot, withIntermediateDirectories: true)
    let store = TatwoProductionInstallAnchorFileStore(
      url: root.appendingPathComponent("install-anchor.json"))
    _ = try TatwoProductionLayoutLock.sealInstallAnchor(
      hostDeviceID: "runner-prod",
      requestedChannelRoot: channelRoot,
      environment: [:],
      installAnchorStore: store,
      applicationSupportBase: base)
    let layout = try TatwoProductionLayoutLock.resolve(
      hostDeviceID: "runner-prod",
      requestedChannelRoot: channelRoot,
      environment: [:],
      installAnchorStore: store,
      applicationSupportBase: base)
    XCTAssertNotEqual(pinRoot.standardizedFileURL.path, layout.pinStoreRoot.path)
    // Production bootstrap with injection is refused (F5).
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: [:],
        allowTestOverrides: false,
        installAnchorStore: store,
        applicationSupportBase: base)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("installAnchorStore"))
    }
  }

  func testProductionBootstrapRejectsUninitializedStore() throws {
    let root = tempRoot("uninit")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinRoot, withIntermediateDirectories: true)
    let keys = MemoryDevicePrivateKeyStore()
    // allowTestOverrides bypasses TEST_MODE and root checks but still requires init when
    // requireInitialized is true for production — with allowTestOverrides, requireInitialized is false.
    // Exercise requireInitialized directly via pin store.
    let trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-prod",
      privateKeyStore: keys,
      environment: testEnv)
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: pinRoot,
      authority: trust.authority,
      localIdentity: trust.localIdentity,
      epochAnchor: fileEpochAnchor(for: pinRoot),
      environment: testEnv)
    XCTAssertThrowsError(try pinStore.load(requireInitialized: true)) { error in
      XCTAssertEqual(error as? TatwoDeviceTrustPinStoreError, .storeNotInitialized)
    }
  }

  func testProductionBootstrapRejectsTestFileKeyStore() throws {
    let root = tempRoot("test-driver")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    let keyRoot = root.appendingPathComponent("keys", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: keyRoot, withIntermediateDirectories: true)

    let testStore = try TatwoDeviceTestFilePrivateKeyStore(
      rootURL: keyRoot,
      testModeAuthorized: true,
      environment: testEnv)

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: testStore,
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: testEnv,
        allowTestOverrides: true)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .testDriverForbidden)
    }
  }

  func testProductionBootstrapRequiresOriginPin() throws {
    let root = tempRoot("origin-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)

    let runnerKeys = MemoryDevicePrivateKeyStore()
    let peerKeys = MemoryDevicePrivateKeyStore()
    let runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-prod",
      privateKeyStore: runnerKeys,
      environment: testEnv)
    let peer = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "other-peer",
      privateKeyStore: peerKeys,
      environment: testEnv)
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: pinRoot,
      authority: runnerTrust.authority,
      localIdentity: runnerTrust.localIdentity,
      epochAnchor: fileEpochAnchor(for: pinRoot),
      environment: testEnv)
    try pinStore.pin(runnerTrust.localIdentity)
    try pinStore.pin(peer.localIdentity)

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: runnerKeys,
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: testEnv,
        allowTestOverrides: true)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .originNotPinned("origin-prod"))
    }
  }

  func testProductionBootstrapSucceedsWithOriginPin() throws {
    let root = tempRoot("happy")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)

    let runnerKeys = MemoryDevicePrivateKeyStore()
    let originKeys = MemoryDevicePrivateKeyStore()
    let runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-prod",
      privateKeyStore: runnerKeys,
      environment: testEnv)
    let origin = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-prod",
      privateKeyStore: originKeys,
      environment: testEnv)
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: pinRoot,
      authority: runnerTrust.authority,
      localIdentity: runnerTrust.localIdentity,
      epochAnchor: fileEpochAnchor(for: pinRoot),
      environment: testEnv)
    try pinStore.pin(runnerTrust.localIdentity)
    try pinStore.pin(origin.localIdentity)

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "runner-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: runnerKeys,
      pinStoreRoot: pinRoot,
      channelRoot: channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    XCTAssertEqual(boot.deviceID, "runner-prod")
    XCTAssertEqual(boot.originDeviceID, "origin-prod")
    XCTAssertGreaterThanOrEqual(boot.peerPinCount, 1)
    XCTAssertNotNil(boot.trust.pinnedIdentities["origin-prod"])
  }

  func testProductionBootstrapRejectsEpochServiceNamespaceOverride() throws {
    let root = tempRoot("epoch-ns")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinRoot, withIntermediateDirectories: true)
    let env = [
      TatwoDeviceTrustPinStoreKeychainEpochAnchor.serviceEnvKey: "evil.epoch.service"
    ]
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: env,
        allowTestOverrides: false)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .trustNamespaceOverrideForbidden(
          TatwoDeviceTrustPinStoreKeychainEpochAnchor.serviceEnvKey))
    }
  }

  func testProductionBootstrapRejectsKeychainServiceNamespaceOverride() throws {
    let env = [
      TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey: "evil.key.service"
    ]
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.rejectProductionTrustNamespaceOverrides(
        environment: env)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .trustNamespaceOverrideForbidden(
          TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey))
    }
  }

  func testProductionEpochServiceConfigurationRejectsOutsideTestMode() throws {
    XCTAssertThrowsError(
      try TatwoDeviceTrustPinStoreKeychainEpochAnchor.configuration(
        hostDeviceID: "runner-prod",
        storeRoot: URL(fileURLWithPath: "/tmp/pins"),
        environment: [
          TatwoDeviceTrustPinStoreKeychainEpochAnchor.serviceEnvKey: "evil.epoch.service"
        ])
    ) { error in
      guard case TatwoDeviceTrustPinStoreError.storeAnchorRejected = error else {
        return XCTFail("expected storeAnchorRejected, got \(error)")
      }
    }
  }

  func testTestModeEpochServiceConfigurationAllowsOverride() throws {
    let config = try TatwoDeviceTrustPinStoreKeychainEpochAnchor.configuration(
      hostDeviceID: "runner-prod",
      storeRoot: URL(fileURLWithPath: "/tmp/pins"),
      environment: [
        TatwoLoopJobChannelTrust.testModeEnvKey: "1",
        TatwoDeviceTrustPinStoreKeychainEpochAnchor.serviceEnvKey: "test.epoch.service",
      ])
    XCTAssertEqual(config.service, "test.epoch.service")
  }

  func testTestModeKeychainServiceConfigurationAllowsOverride() throws {
    let service = try TatwoDeviceKeychainPrivateKeyStore.configuration(
      environment: [
        TatwoLoopJobChannelTrust.testModeEnvKey: "1",
        TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey: "test.key.service",
      ])
    XCTAssertEqual(service, "test.key.service")
  }

  func testProductionKeychainServiceConfigurationRejectsOutsideTestMode() throws {
    XCTAssertThrowsError(
      try TatwoDeviceKeychainPrivateKeyStore.configuration(
        environment: [
          TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey: "evil.key.service"
        ])
    ) { error in
      XCTAssertEqual(
        error as? TatwoDeviceTrustError,
        .trustNamespaceOverrideForbidden(
          TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey))
    }
  }

  // MARK: - Wave 0 package E: production layout lock

  func testProductionRejectsNonCanonicalAppSupportEnv() throws {
    let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
        environment: [
          TatwoProductionLayoutLock.appSupportEnvKey: "/tmp/evil-app-support"
        ],
        applicationSupportBase: base)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .layoutEnvOverrideForbidden(TatwoProductionLayoutLock.appSupportEnvKey))
    }
  }

  func testProductionRejectsNonCanonicalStateDirEnv() throws {
    let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
        environment: [
          TatwoProductionLayoutLock.stateDirEnvKey: "/tmp/evil-state"
        ],
        applicationSupportBase: base)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .layoutEnvOverrideForbidden(TatwoProductionLayoutLock.stateDirEnvKey))
    }
  }

  func testProductionRejectsOSRootLayoutEnv() throws {
    let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
        environment: [
          TatwoProductionLayoutLock.osRootEnvKey: "/tmp/evil-os-root"
        ],
        applicationSupportBase: base)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .layoutEnvOverrideForbidden(TatwoProductionLayoutLock.osRootEnvKey))
    }
  }

  func testProductionLayoutResolveRejectsChannelDirBelowSealedAnchor() throws {
    let root = tempRoot("layout-channel")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let channelA = root.appendingPathComponent("channel-a", isDirectory: true)
    let channelB = root.appendingPathComponent("channel-b", isDirectory: true)
    try FileManager.default.createDirectory(at: channelA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: channelB, withIntermediateDirectories: true)
    let anchorURL = root.appendingPathComponent("install-anchor.json")
    let store = TatwoProductionInstallAnchorFileStore(url: anchorURL)

    _ = try TatwoProductionLayoutLock.sealInstallAnchor(
      hostDeviceID: "runner-prod",
      requestedChannelRoot: channelA,
      environment: [:],
      installAnchorStore: store,
      applicationSupportBase: base)

    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.resolve(
        hostDeviceID: "runner-prod",
        requestedChannelRoot: channelB,
        environment: [:],
        installAnchorStore: store,
        applicationSupportBase: base)
    ) { error in
      guard case TatwoProductionLayoutError.channelRootOverrideForbidden = error else {
        return XCTFail("expected channelRootOverrideForbidden, got \(error)")
      }
    }

    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.resolve(
        hostDeviceID: "runner-prod",
        requestedChannelRoot: nil,
        environment: [
          TatwoProductionLayoutLock.jobChannelEnvKey: channelB.path
        ],
        installAnchorStore: store,
        applicationSupportBase: base)
    ) { error in
      guard case TatwoProductionLayoutError.layoutEnvOverrideForbidden(
        TatwoProductionLayoutLock.jobChannelEnvKey) = error
      else {
        return XCTFail("expected job channel env reject, got \(error)")
      }
    }
  }

  func testProductionBootstrapRejectsAppSupportOverrideOnStartPath() throws {
    // Layout env rejection is enforced at layout lock; F5 refuses injection on bootstrap.
    let base = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    let env = [
      TatwoProductionLayoutLock.appSupportEnvKey: "/tmp/evil-app-support-boot"
    ]
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.rejectProductionLayoutEnvOverrides(
        environment: env,
        applicationSupportBase: base)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .layoutEnvOverrideForbidden(TatwoProductionLayoutLock.appSupportEnvKey))
    }
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        channelRoot: URL(fileURLWithPath: "/tmp/channel", isDirectory: true),
        environment: env,
        allowTestOverrides: false,
        installAnchorStore: TatwoProductionInstallAnchorFileStore(
          url: URL(fileURLWithPath: "/tmp/anchor.json")),
        applicationSupportBase: base)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("installAnchorStore"))
    }
  }

  func testProductionInjectionPrecedesMissingOriginLease() throws {
    let root = tempRoot("f17-injection-before-lease")
    defer { try? FileManager.default.removeItem(at: root) }
    let injectedAnchor = TatwoProductionInstallAnchorFileStore(
      url: root.appendingPathComponent("injected-anchor.json"))

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        environment: [:],
        allowTestOverrides: false,
        installAnchorStore: injectedAnchor)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("installAnchorStore"))
    }
  }

  func testProductionConsumeHighWaterAccountIsGlobalNotPathHashed() throws {
    let channelA = URL(fileURLWithPath: "/tmp/channel-ns-a", isDirectory: true)
    let channelB = URL(fileURLWithPath: "/tmp/channel-ns-b", isDirectory: true)
    let a = try TatwoLoopResultConsumeHighWaterKeychainAnchor.configuration(
      hostDeviceID: "runner-prod",
      channelRoot: channelA,
      environment: [:])
    let b = try TatwoLoopResultConsumeHighWaterKeychainAnchor.configuration(
      hostDeviceID: "runner-prod",
      channelRoot: channelB,
      environment: [:])
    XCTAssertEqual(a.accountPrefix, b.accountPrefix)
    XCTAssertTrue(a.accountPrefix.hasSuffix(":global"))
    XCTAssertFalse(a.accountPrefix.contains(TatwoLoopJobChannelTrust.sha256Hex(Data("/tmp".utf8)).prefix(8)))
  }

  func testProductionEpochAccountIsGlobalNotPathHashed() throws {
    let rootA = URL(fileURLWithPath: "/tmp/pins-ns-a", isDirectory: true)
    let rootB = URL(fileURLWithPath: "/tmp/pins-ns-b", isDirectory: true)
    let a = try TatwoDeviceTrustPinStoreKeychainEpochAnchor.configuration(
      hostDeviceID: "runner-prod",
      storeRoot: rootA,
      environment: [:])
    let b = try TatwoDeviceTrustPinStoreKeychainEpochAnchor.configuration(
      hostDeviceID: "runner-prod",
      storeRoot: rootB,
      environment: [:])
    XCTAssertEqual(a.account, b.account)
    XCTAssertTrue(a.account.hasSuffix(":global"))
  }

  func testGlobalAntiRollbackRejectsOldNamespaceReadbackBelowHighWater() throws {
    let root = tempRoot("global-ar")
    defer { try? FileManager.default.removeItem(at: root) }
    let anchor = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: root.appendingPathComponent("global-ar", isDirectory: true))
    try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
      observed: 5,
      anchor: anchor)
    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
        observed: 2,
        anchor: anchor)
    ) { error in
      guard case TatwoProductionLayoutError.globalAntiRollbackRegression = error else {
        return XCTFail("expected globalAntiRollbackRegression, got \(error)")
      }
    }

    try TatwoProductionLayoutLock.enforceConsumeAntiRollback(
      jobID: "job-1",
      dispatchNonce: "nonce-hi",
      jobCanonicalDigest: "sha256:job-hi",
      resultDigest: "sha256:result-hi",
      projectionSequence: 9,
      anchor: anchor)
    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.enforceConsumeAntiRollback(
        jobID: "job-1",
        dispatchNonce: "nonce-old",
        jobCanonicalDigest: "sha256:job-old",
        resultDigest: "sha256:result-old",
        projectionSequence: 1,
        anchor: anchor)
    ) { error in
      guard case TatwoProductionLayoutError.globalAntiRollbackRegression = error else {
        return XCTFail("expected consume anti-rollback reject, got \(error)")
      }
    }
  }

  func testOldNamespaceReadbackBelowGlobalHighWaterIsRejected() throws {
    // Explicit package-E gate: old registry/channel namespace readback (lower generation
    // or older attempt) is rejected by the fixed global anti-rollback anchor.
    let root = tempRoot("old-ns-readback")
    defer { try? FileManager.default.removeItem(at: root) }
    let global = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: root.appendingPathComponent("global-ar", isDirectory: true))
    try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
      observed: 4,
      anchor: global)
    try TatwoProductionLayoutLock.enforceConsumeAntiRollback(
      jobID: "job-ns",
      dispatchNonce: "nonce-prior",
      jobCanonicalDigest: "sha256:prior-job",
      resultDigest: "sha256:prior-result",
      projectionSequence: 7,
      anchor: global)

    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
        observed: 1,
        anchor: global)
    ) { error in
      guard case TatwoProductionLayoutError.globalAntiRollbackRegression = error else {
        return XCTFail("expected storeGeneration anti-rollback reject, got \(error)")
      }
    }
    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.enforceConsumeAntiRollback(
        jobID: "job-ns",
        dispatchNonce: "nonce-old-ns",
        jobCanonicalDigest: "sha256:old-job",
        resultDigest: "sha256:old-result",
        projectionSequence: 1,
        anchor: global)
    ) { error in
      guard case TatwoProductionLayoutError.globalAntiRollbackRegression = error else {
        return XCTFail("expected old namespace readback reject, got \(error)")
      }
    }
  }

  // MARK: - Wave 0 package H: claim/consumed auto-prune disabled

  /// Gen N claim+execute → advance N+2 → restore queued snapshot → engine still once.
  func testExecutedClaimSurvivesGenerationAdvanceAndBlocksReplay() throws {
    let root = tempRoot("claim-survives-gen")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let registryDir = root.appendingPathComponent("registry", isDirectory: true)
    let sandboxRoot = root.appendingPathComponent("sandbox", isDirectory: true)
    let nestedWork = sandboxRoot.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedWork, withIntermediateDirectories: true)
    try "probe".write(
      to: nestedWork.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

    let global = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: root.appendingPathComponent("global-ar", isDirectory: true))
    let genN: UInt64 = 5
    try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
      observed: genN, anchor: global)

    let originKeys = MemoryDevicePrivateKeyStore()
    let runnerKeys = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-prod", privateKeyStore: originKeys, environment: testEnv)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-prod", privateKeyStore: runnerKeys, environment: testEnv)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let originChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: originTrust, environment: testEnv,
      globalAntiRollbackAnchor: global)
    let runnerChannel = TatwoLoopJobChannel(
      rootURL: channelRoot, trust: runnerTrust, environment: testEnv,
      globalAntiRollbackAnchor: global)

    let job = TatwoLoopJobV1(
      jobID: "job-gen-survive",
      logicalJobID: "logical-gen-survive",
      dispatchNonce: "nonce-gen-survive",
      contractID: "contract-xl-coding-f51cfabe38f8",
      goalID: "goal-xl-coding-f51cfabe38f8",
      identity: .sub,
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: "contract-xl-coding-f51cfabe38f8",
          goalID: "goal-xl-coding-f51cfabe38f8",
          identity: .sub,
          mode: .xl,
          taskDescription: "job-gen-survive")),
      workPath: nestedWork.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 4_096),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_200))

    let originRegistry = TatwoDispatchRegistry(directoryURL: registryDir)
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: originRegistry,
      originDeviceID: "origin-prod",
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: registryDir))
    _ = try origin.enqueue(job)

    let snapshotDir = root.appendingPathComponent("queued-snapshot", isDirectory: true)
    try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
    try copyTree(from: channelRoot, to: snapshotDir.appendingPathComponent("channel"))
    try copyTree(from: registryDir, to: snapshotDir.appendingPathComponent("registry"))

    let engine = CountingLoopEngine()
    let loopEnv = [
      TatwoLoopJobChannelTrust.testModeEnvKey: "1",
      TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
      TatwoLoopSandboxUnlock.sandboxRootEnvKey: sandboxRoot.path,
    ]
    let runner = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: "runner-prod",
      pollIntervalSec: 0.01,
      environment: loopEnv,
      sandboxRootURL: sandboxRoot,
      engine: engine,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-registry", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root.appendingPathComponent("runner-registry")))
    let first = try runner.runUntilIdle()
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first.first?.status, .completed, first.first?.message ?? "")
    XCTAssertEqual(engine.invocationCount, 1)
    let claimed = try XCTUnwrap(try global.loadExecutedClaim(jobID: job.jobID))
    XCTAssertEqual(claimed.boundGeneration, genN)

    // Advance past lag-1 window (N → N+2). Old lag-1 prune would drop gen-N claims.
    try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
      observed: genN + 2, anchor: global)
    XCTAssertEqual(try global.loadStoreGenerationHighWater(), genN + 2)
    XCTAssertNotNil(
      try global.loadExecutedClaim(jobID: job.jobID),
      "executed claim must survive generation advance without auto-prune")

    // Restore queued channel + registry snapshot and attempt replay.
    try FileManager.default.removeItem(at: channelRoot)
    try FileManager.default.removeItem(at: registryDir)
    try copyTree(from: snapshotDir.appendingPathComponent("channel"), to: channelRoot)
    try copyTree(from: snapshotDir.appendingPathComponent("registry"), to: registryDir)

    let runner2 = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: "runner-prod",
      pollIntervalSec: 0.01,
      environment: loopEnv,
      sandboxRootURL: sandboxRoot,
      engine: engine,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-registry-2", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root.appendingPathComponent("runner-registry-2")))
    let replay = try runner2.runUntilIdle()
    XCTAssertTrue(replay.isEmpty, "queued snapshot must not re-enter engine after claim")
    XCTAssertEqual(
      engine.invocationCount, 1,
      "engine invocation must remain 1 after gen advance + snapshot restore")
    XCTAssertEqual(try XCTUnwrap(try global.loadExecutedClaim(jobID: job.jobID)), claimed)
  }

  /// Claim concurrent with generation advance: winner claim must not vanish mid-flight.
  func testClaimNotDeletedDuringConcurrentGenerationAdvance() throws {
    let root = tempRoot("claim-vs-gen")
    defer { try? FileManager.default.removeItem(at: root) }
    let global = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: root.appendingPathComponent("global-ar", isDirectory: true))
    let startGen: UInt64 = 4
    try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
      observed: startGen, anchor: global)

    let jobID = "job-claim-race-gen"
    let nonce = "nonce-claim-race"
    let digest = "sha256:claim-race-gen"
    let claimBox = ClaimRaceBox()
    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      do {
        try TatwoProductionLayoutLock.claimTargetExecution(
          jobID: jobID,
          dispatchNonce: nonce,
          jobCanonicalDigest: digest,
          anchor: global)
        claimBox.markClaimed()
        // Simulate engine work while generation advances.
        for _ in 0..<40 {
          if (try? global.loadExecutedClaim(jobID: jobID)) == nil {
            claimBox.fail("winner claim disappeared before engine completion")
            return
          }
          Thread.sleep(forTimeInterval: 0.002)
        }
        claimBox.markEngineDone()
      } catch {
        claimBox.fail("claim failed: \(error)")
      }
    }

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { group.leave() }
      // Advance generations past any historical lag-1 prune floor while claim is live.
      for offset in 1...12 {
        do {
          try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
            observed: startGen + UInt64(offset),
            anchor: global)
          // Explicit prune entrypoint must also leave claims intact (pilot).
          try global.pruneRecordsBelowGeneration(startGen + UInt64(offset))
        } catch {
          claimBox.fail("generation advance failed: \(error)")
        }
        Thread.sleep(forTimeInterval: 0.001)
      }
    }

    let waited = group.wait(timeout: .now() + 15)
    XCTAssertEqual(waited, .success, "concurrent claim/generation race timed out")
    if let err = claimBox.errorMessage {
      XCTFail(err)
    }
    XCTAssertTrue(claimBox.didClaim, "claim must succeed")
    XCTAssertTrue(claimBox.didEngineDone, "engine window must complete")
    let surviving = try XCTUnwrap(try global.loadExecutedClaim(jobID: jobID))
    XCTAssertEqual(surviving.dispatchNonce, nonce)
    XCTAssertEqual(surviving.jobCanonicalDigest, digest)
    XCTAssertGreaterThanOrEqual(try global.loadStoreGenerationHighWater(), startGen + 12)
  }

  // MARK: - Wave 0 package F: claim + seal atomicity (gate 2)

  func testTargetRejectsReplayedQueuedChannelAndRegistrySnapshot() throws {
    let root = tempRoot("target-replay")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let registryDir = root.appendingPathComponent("registry", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)

    let global = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: root.appendingPathComponent("global-ar", isDirectory: true))
    let originKeys = MemoryDevicePrivateKeyStore()
    let runnerKeys = MemoryDevicePrivateKeyStore()
    var originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-prod",
      privateKeyStore: originKeys,
      environment: testEnv)
    var runnerTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-prod",
      privateKeyStore: runnerKeys,
      environment: testEnv)
    originTrust = try originTrust.withPin(runnerTrust.localIdentity)
    runnerTrust = try runnerTrust.withPin(originTrust.localIdentity)

    let originChannel = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: originTrust,
      environment: testEnv,
      globalAntiRollbackAnchor: global)
    let runnerChannel = TatwoLoopJobChannel(
      rootURL: channelRoot,
      trust: runnerTrust,
      environment: testEnv,
      globalAntiRollbackAnchor: global)

    let job = TatwoLoopJobV1(
      jobID: "job-replay-claim",
      logicalJobID: "logical-job-replay-claim",
      dispatchNonce: "nonce-replay-1",
      contractID: "contract-xl-coding-f51cfabe38f8",
      goalID: "goal-xl-coding-f51cfabe38f8",
      identity: .sub,
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["once"])),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    let originRegistry = TatwoDispatchRegistry(directoryURL: registryDir)
    let origin = TatwoLoopOriginProjectorV1(
      channel: originChannel,
      registry: originRegistry,
      originDeviceID: "origin-prod",
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: registryDir))
    _ = try origin.enqueue(job)

    // Snapshot queued channel + registry before execution.
    let snapshotDir = root.appendingPathComponent("queued-snapshot", isDirectory: true)
    try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
    try copyTree(from: channelRoot, to: snapshotDir.appendingPathComponent("channel"))
    try copyTree(from: registryDir, to: snapshotDir.appendingPathComponent("registry"))

    let runnerRegistry = TatwoDispatchRegistry(
      directoryURL: root.appendingPathComponent("runner-registry", isDirectory: true))
    let runner = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: "runner-prod",
      pollIntervalSec: 0.01,
      environment: testEnv,
      localRegistry: runnerRegistry,
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root.appendingPathComponent("runner-registry")))
    let first = try runner.runUntilIdle()
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first.first?.status, .completed)

    // Claim must now be durable in global anti-rollback.
    let claimed = try XCTUnwrap(try global.loadExecutedClaim(jobID: job.jobID))
    XCTAssertEqual(claimed.dispatchNonce, job.dispatchNonce)

    // Restore queued channel + registry snapshot (namespace pathname unchanged).
    try FileManager.default.removeItem(at: channelRoot)
    try FileManager.default.removeItem(at: registryDir)
    try copyTree(from: snapshotDir.appendingPathComponent("channel"), to: channelRoot)
    try copyTree(from: snapshotDir.appendingPathComponent("registry"), to: registryDir)

    // Same runner path after rollback: must refuse re-execution (claim fence).
    let runner2 = try TatwoLoopRunnerV1(
      channel: runnerChannel,
      deviceID: "runner-prod",
      pollIntervalSec: 0.01,
      environment: testEnv,
      localRegistry: TatwoDispatchRegistry(
        directoryURL: root.appendingPathComponent("runner-registry-2", isDirectory: true)),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: root.appendingPathComponent("runner-registry-2")))
    let replay = try runner2.runUntilIdle()
    XCTAssertTrue(
      replay.isEmpty,
      "replayed queued channel+registry must not re-execute after global claim")
    // Claim binding unchanged (no second execution attempt recorded as new claim).
    let after = try XCTUnwrap(try global.loadExecutedClaim(jobID: job.jobID))
    XCTAssertEqual(after, claimed)
  }

  func testDualFirstBootDifferentChannelAnchorRaceIsRejected() throws {
    // Sequential dual-boot reject remains a valid negative. Cross-process concurrent
    // seal race is covered by testCrossProcessDualFirstSealExactlyOneWinner.
    let root = tempRoot("dual-boot")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let channelA = root.appendingPathComponent("channel-a", isDirectory: true)
    let channelB = root.appendingPathComponent("channel-b", isDirectory: true)
    try FileManager.default.createDirectory(at: channelA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: channelB, withIntermediateDirectories: true)
    let store = TatwoProductionInstallAnchorFileStore(
      url: root.appendingPathComponent("install-anchor.json"))

    let sealedA = try TatwoProductionLayoutLock.sealInstallAnchor(
      hostDeviceID: "runner-prod",
      requestedChannelRoot: channelA,
      environment: [:],
      installAnchorStore: store,
      applicationSupportBase: base)
    XCTAssertEqual(sealedA.jobChannelRoot.path, channelA.standardizedFileURL.path)

    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.sealInstallAnchor(
        hostDeviceID: "runner-prod",
        requestedChannelRoot: channelB,
        environment: [:],
        installAnchorStore: store,
        applicationSupportBase: base)
    ) { error in
      if case TatwoProductionLayoutError.channelRootOverrideForbidden = error { return }
      if case TatwoProductionLayoutError.installAnchorRejected = error { return }
      return XCTFail("expected dual-boot reject, got \(error)")
    }

    let kept = try XCTUnwrap(try store.load())
    XCTAssertEqual(kept.jobChannelRoot, channelA.standardizedFileURL.path)
    XCTAssertNotEqual(kept.jobChannelRoot, channelB.standardizedFileURL.path)
  }

  func testFailedBootstrapLeavesNoAnchor() throws {
    let root = tempRoot("fail-no-anchor")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let channel = root.appendingPathComponent("channel", isDirectory: true)
    try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
    let store = TatwoProductionInstallAnchorFileStore(
      url: root.appendingPathComponent("install-anchor.json"))

    // resolve must not create; production bootstrap refuses injection + missing keychain anchor.
    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.resolve(
        hostDeviceID: "runner-prod",
        requestedChannelRoot: channel,
        environment: [:],
        installAnchorStore: store,
        applicationSupportBase: base)
    ) { error in
      guard case TatwoProductionLayoutError.installAnchorRejected = error else {
        return XCTFail("expected missing install anchor reject, got \(error)")
      }
    }
    XCTAssertNil(try store.load(), "failed resolve must not leave install anchor")

    // Failed production bootstrap (injection refused / no seal) leaves file store empty.
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        channelRoot: channel,
        environment: [:],
        allowTestOverrides: false,
        installAnchorStore: store,
        applicationSupportBase: base)
    )
    XCTAssertNil(try store.load(), "failed bootstrap must not leave install anchor")
  }

  func testMissingAnchorWithoutInitRefusesStart() throws {
    let root = tempRoot("missing-anchor")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let channel = root.appendingPathComponent("channel", isDirectory: true)
    try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
    let store = TatwoProductionInstallAnchorFileStore(
      url: root.appendingPathComponent("install-anchor.json"))

    XCTAssertThrowsError(
      try TatwoProductionLayoutLock.resolve(
        hostDeviceID: "runner-prod",
        requestedChannelRoot: channel,
        environment: [
          TatwoProductionLayoutLock.jobChannelEnvKey: channel.path
        ],
        installAnchorStore: store,
        applicationSupportBase: base)
    ) { error in
      guard case let TatwoProductionLayoutError.installAnchorRejected(detail) = error else {
        return XCTFail("expected installAnchorRejected, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("missing install anchor"),
        "detail should name missing install gate, got \(detail)")
    }
    XCTAssertNil(try store.load())
  }

  func testProductionRefusesCallerInjectedAnchorsAndRegistryWhenNotTestMode() throws {
    let root = tempRoot("inject-refuse")
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = root.appendingPathComponent("channel", isDirectory: true)
    try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
    let store = TatwoProductionInstallAnchorFileStore(
      url: root.appendingPathComponent("install-anchor.json"))
    let global = TatwoLoopGlobalAntiRollbackFileAnchor(
      rootURL: root.appendingPathComponent("global-ar", isDirectory: true))
    let base = root.appendingPathComponent("Library/Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        channelRoot: channel,
        environment: [:],
        allowTestOverrides: false,
        installAnchorStore: store)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("installAnchorStore"))
    }

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        channelRoot: channel,
        environment: [:],
        allowTestOverrides: false,
        globalAntiRollbackAnchor: global)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("globalAntiRollbackAnchor"))
    }

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.bootstrap(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        channelRoot: channel,
        environment: [:],
        allowTestOverrides: false,
        applicationSupportBase: base)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("applicationSupportBase"))
    }

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.start(
        deviceID: "runner-prod",
        originDeviceID: "origin-prod",
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        channelRoot: channel,
        environment: [:],
        localRegistry: TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("reg")),
        allowTestOverrides: false)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("localRegistry"))
    }
  }

  // MARK: - Wave 0 package I: origin production dispatch

  /// Shared fixture: mutual pins + issued Work OS contract for production dispatch tests.
  private struct DispatchFixture {
    let root: URL
    let channelRoot: URL
    let pinRoot: URL
    let runnerPinRoot: URL
    let work: URL
    let stateDir: URL
    let runnerRegistryDir: URL
    let originKeys: MemoryDevicePrivateKeyStore
    let runnerKeys: MemoryDevicePrivateKeyStore
    let verifiedTargetIdentity: TatwoDevicePublicIdentityV1
    let goalStore: TatwoGoalRunStore
    let registry: TatwoDispatchRegistry
    let contract: TatwoWorkOSContractV1
    let remoteBorrowAuthorizationStore: TatwoRemoteBorrowAuthorizationStore
    let remoteBorrowSessionID: String
    let remoteBorrowGrant: TatwoRemoteSessionGrantV1
    let remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1
    let readinessProvider: ProductionDispatchFixtureReadinessProvider
  }

  private func makeDispatchFixture(
    label: String,
    mode: WorkModeID = .m,
    scenarioProfileID: String = "coding",
    objective: String = "pkg-j dispatch fixture"
  ) throws -> DispatchFixture {
    let root = tempRoot(label)
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    let stateDir = root.appendingPathComponent("state", isDirectory: true)
    let runnerRegistryDir = root.appendingPathComponent("runner-registry", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runnerRegistryDir, withIntermediateDirectories: true)

    let originKeys = MemoryDevicePrivateKeyStore()
    let runnerKeys = MemoryDevicePrivateKeyStore()
    let originTrustSeed = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-prod",
      privateKeyStore: originKeys,
      environment: testEnv)
    let runnerTrustSeed = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "runner-prod",
      privateKeyStore: runnerKeys,
      environment: testEnv)

    let originPinStore = TatwoDeviceTrustPinStore(
      rootURL: pinRoot,
      authority: originTrustSeed.authority,
      localIdentity: originTrustSeed.localIdentity,
      epochAnchor: fileEpochAnchor(for: pinRoot),
      environment: testEnv)
    try originPinStore.pin(originTrustSeed.localIdentity)
    try originPinStore.pin(runnerTrustSeed.localIdentity)

    let runnerPinRoot = root.appendingPathComponent("runner-pins", isDirectory: true)
    let runnerPinStore = TatwoDeviceTrustPinStore(
      rootURL: runnerPinRoot,
      authority: runnerTrustSeed.authority,
      localIdentity: runnerTrustSeed.localIdentity,
      epochAnchor: fileEpochAnchor(for: runnerPinRoot),
      environment: testEnv)
    try runnerPinStore.pin(runnerTrustSeed.localIdentity)
    try runnerPinStore.pin(originTrustSeed.localIdentity)

    let goalStore = TatwoGoalRunStore(directoryURL: stateDir)
    let registry = TatwoDispatchRegistry(directoryURL: stateDir)
    let contract = try WorkOSFactory.issueDetachedFixtureForTesting(
      mode: mode,
      scenarioProfileID: scenarioProfileID,
      objective: objective,
      store: goalStore)
    let remoteBorrowAuthorizationStore =
      TatwoRemoteBorrowAuthorizationStore.production(stateRoot: stateDir)
    let remoteBorrowSessionID = "thread-\(label)"
    let remoteBorrowGrant = try remoteBorrowAuthorizationStore.issueSessionGrant(
      sessionID: remoteBorrowSessionID,
      targetDeviceID: "runner-prod",
      contractID: contract.contractID)
    let remoteDispatchReadiness = TatwoRemoteDispatchReadinessBindingV1(
      workspaceBindingID: "workspace-\(label)",
      workspaceBindingDigest: String(repeating: "a", count: 64),
      agentModelCapabilityDigest: String(repeating: "b", count: 64),
      activeSkillSetDigest: String(repeating: "c", count: 64),
      challengeNonce: "challenge-\(label)")
    let readinessProvider = ProductionDispatchFixtureReadinessProvider(
      targetTrust: runnerTrustSeed,
      workspaceBindingID: remoteDispatchReadiness.workspaceBindingID,
      workspaceBindingDigest: remoteDispatchReadiness.workspaceBindingDigest,
      agentModelCapabilityDigest: remoteDispatchReadiness.agentModelCapabilityDigest,
      activeSkillSetDigest: remoteDispatchReadiness.activeSkillSetDigest)

    return DispatchFixture(
      root: root,
      channelRoot: channelRoot,
      pinRoot: pinRoot,
      runnerPinRoot: runnerPinRoot,
      work: work,
      stateDir: stateDir,
      runnerRegistryDir: runnerRegistryDir,
      originKeys: originKeys,
      runnerKeys: runnerKeys,
      verifiedTargetIdentity: runnerTrustSeed.localIdentity,
      goalStore: goalStore,
      registry: registry,
      contract: contract,
      remoteBorrowAuthorizationStore: remoteBorrowAuthorizationStore,
      remoteBorrowSessionID: remoteBorrowSessionID,
      remoteBorrowGrant: remoteBorrowGrant,
      remoteDispatchReadiness: remoteDispatchReadiness,
      readinessProvider: readinessProvider)
  }

  private func makeGrokBuildDispatchFixture(
    label: String,
    objective: String = "pkg-j grok-build dispatch fixture"
  ) throws -> DispatchFixture {
    let fixture = try makeDispatchFixture(
      label: label,
      scenarioProfileID: "general-m-sol",
      objective: objective)
    let grokBinding = try XCTUnwrap(
      fixture.contract.identityBindings.first {
        $0.identity == .sub
          && TatwoGatewayDispatchCatalog.normalize($0.modelID ?? "") == "grok-build"
      },
      "production grok-build fixture must have an issued matching sub binding")
    _ = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: fixture.contract.contractID,
      bindingID: grokBinding.id,
      sourceSlotID: grokBinding.sourceSlotID,
      identity: .sub,
      modelID: "grok-build",
      subtask: "issue production grok-build fixture binding",
      helperCap: 4,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    return fixture
  }

  private func makeDispatchJob(
    fixture: DispatchFixture,
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    contractID: String? = nil,
    goalID: String? = nil,
    identity: IdentityKind = .sub,
    payload: TatwoLoopJobPayloadV1? = nil,
    remoteBorrowInvocationOverride: TatwoRemoteBorrowInvocationV1? = nil,
    omitRemoteBorrowInvocation: Bool = false,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_300)
  ) -> TatwoLoopJobV1 {
    let resolvedContractID = contractID ?? fixture.contract.contractID
    let resolvedGoalID = goalID ?? fixture.contract.goalID
    let defaultRemoteBorrowInvocation = TatwoRemoteBorrowInvocationV1(
      sessionID: fixture.remoteBorrowSessionID,
      targetDeviceID: "runner-prod",
      contractID: resolvedContractID,
      goalID: resolvedGoalID,
      mode: .manual,
      risk: .lowRisk,
      grantID: fixture.remoteBorrowGrant.id)
    return TatwoLoopJobV1(
      jobID: jobID,
      logicalJobID: logicalJobID,
      dispatchNonce: dispatchNonce,
      contractID: resolvedContractID,
      goalID: resolvedGoalID,
      identity: identity,
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      remoteBorrowInvocation: omitRemoteBorrowInvocation
        ? nil
        : (remoteBorrowInvocationOverride ?? defaultRemoteBorrowInvocation),
      remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1(
        workspaceBindingID: fixture.remoteDispatchReadiness.workspaceBindingID,
        workspaceBindingDigest: fixture.remoteDispatchReadiness.workspaceBindingDigest,
        agentModelCapabilityDigest:
          fixture.remoteDispatchReadiness.agentModelCapabilityDigest,
        activeSkillSetDigest: fixture.remoteDispatchReadiness.activeSkillSetDigest,
        challengeNonce: "challenge-\(dispatchNonce)"),
      payload: payload
        ?? .shellSafe(TatwoShellSafePayloadV1(command: .echo, arguments: ["dispatched"])),
      workPath: fixture.work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(cancelFileSignal: true, rules: ["cancel-file"]),
      createdAt: createdAt)
  }

  private func makeRemoteBorrowDispatchJob(
    fixture: DispatchFixture,
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    remoteBorrowInvocationOverride: TatwoRemoteBorrowInvocationV1? = nil,
    omitRemoteBorrowInvocation: Bool = false
  ) -> TatwoLoopJobV1 {
    makeDispatchJob(
      fixture: fixture,
      jobID: jobID,
      logicalJobID: logicalJobID,
      dispatchNonce: dispatchNonce,
      payload: .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: fixture.contract.contractID,
          goalID: fixture.contract.goalID,
          identity: .sub,
          mode: .m,
          taskDescription: "borrow-gated remote agent task",
          agent: .grok,
          exactModelRouteID: "grok-build")),
      remoteBorrowInvocationOverride: remoteBorrowInvocationOverride,
      omitRemoteBorrowInvocation: omitRemoteBorrowInvocation)
  }

  private func assertChannelArtifactsAbsent(
    channel: TatwoLoopJobChannel,
    job: TatwoLoopJobV1,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let outbox = channel.rootURL
      .appendingPathComponent("outbox", isDirectory: true)
      .appendingPathComponent(job.targetDeviceID, isDirectory: true)
    let outboxEntries =
      (try? FileManager.default.contentsOfDirectory(
        at: outbox,
        includingPropertiesForKeys: nil)) ?? []
    XCTAssertTrue(
      outboxEntries.isEmpty,
      "outbox must stay empty on fail-closed reject",
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.jobSignatureURL(for: job).path),
      "job signature must not be written",
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.journalURL(forJobID: job.jobID).path),
      "journal must not be written",
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.ackURL(forJobID: job.jobID).path),
      "queued ack must not be written",
      file: file,
      line: line)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: channel.commitMarkerURL(forJobID: job.jobID).path),
      "commit marker must not be written",
      file: file,
      line: line)
  }

  private func assertBorrowDispatchRejected(
    fixture: DispatchFixture,
    job: TatwoLoopJobV1,
    expectedCode: TatwoRemoteBorrowAuthorizationBlockerV1,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: fixture.originKeys,
        pinStoreRoot: fixture.pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      guard case let .workOSContractGate(detail)? =
        error as? TatwoLoopProductionRunnerError
      else {
        return XCTFail(
          "expected workOSContractGate, got \(error)",
          file: file,
          line: line)
      }
      XCTAssertTrue(
        detail.contains(expectedCode.rawValue),
        detail,
        file: file,
        line: line)
    }

    XCTAssertNil(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID },
      "borrow rejection must occur before registry reservation",
      file: file,
      line: line)
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    assertChannelArtifactsAbsent(
      channel: boot.channel,
      job: job,
      file: file,
      line: line)
  }

  /// Signed job from production dispatch is accepted and executed once by a pinned target runner.
  func testProductionDispatchEnqueuesSignedJobForPinnedTarget() throws {
    let fixture = try makeDispatchFixture(label: "dispatch-happy")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-dispatch-1",
      logicalJobID: "logical-dispatch-1",
      dispatchNonce: "nonce-dispatch-1")

    let dispatched = try TatwoLoopProductionRunnerBootstrap.dispatch(
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      job: job,
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      localRegistry: fixture.registry,
      localGoalRunStore: fixture.goalStore,
      allowTestOverrides: true)

    XCTAssertEqual(dispatched.job.jobID, job.jobID)
    XCTAssertEqual(dispatched.job.dispatchNonce, job.dispatchNonce)
    XCTAssertEqual(dispatched.job.logicalJobID, job.logicalJobID)
    XCTAssertFalse(dispatched.jobCanonicalDigest.isEmpty)
    XCTAssertEqual(dispatched.channelRoot, fixture.channelRoot.standardizedFileURL.path)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dispatched.bootstrap.channel.jobSignatureURL(for: job).path),
      "origin must write signed job sidecar")

    // Target runner with mutual pin accepts and executes once.
    let runnerBoot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "runner-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.runnerKeys,
      pinStoreRoot: fixture.runnerPinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let runner = try TatwoLoopRunnerV1(
      channel: runnerBoot.channel,
      deviceID: "runner-prod",
      pollIntervalSec: 0.01,
      environment: testEnv,
      localRegistry: TatwoDispatchRegistry(directoryURL: fixture.runnerRegistryDir),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.runnerRegistryDir))
    let receipts = try runner.runUntilIdle()
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(receipts.first?.status, .completed, receipts.first?.message ?? "")
    XCTAssertEqual(receipts.first?.jobID, job.jobID)

    // Second poll must not re-execute.
    let again = try runner.runUntilIdle()
    XCTAssertTrue(again.isEmpty, "signed job must execute at most once")
  }

  /// Shell-safe dispatch is origin-signed and pin-bound, but does not borrow a
  /// Chat session or require a target readiness manifest.
  func testProductionDispatchShellSafeDoesNotRequireBorrowOrReadiness() throws {
    let fixture = try makeDispatchFixture(label: "dispatch-shell-safe-independent")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let job = TatwoLoopJobV1(
      jobID: "job-shell-safe-independent",
      logicalJobID: "logical-shell-safe-independent",
      dispatchNonce: "nonce-shell-safe-independent",
      contractID: fixture.contract.contractID,
      goalID: fixture.contract.goalID,
      identity: .sub,
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      payload: .shellSafe(
        TatwoShellSafePayloadV1(command: .echo, arguments: ["safe"])),
      workPath: fixture.work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 2, maxOutputBytes: 256),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_320))

    let dispatched = try TatwoLoopProductionRunnerBootstrap.dispatch(
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      job: job,
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      localRegistry: fixture.registry,
      localGoalRunStore: fixture.goalStore,
      allowTestOverrides: true)

    XCTAssertEqual(dispatched.job.jobID, job.jobID)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dispatched.bootstrap.channel.jobSignatureURL(for: job).path))
    XCTAssertNotNil(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID })
  }

  func testRunnerRejectsSkilletStoreAsActiveSkillRuntimeRoot() throws {
    let fixture = try makeDispatchFixture(label: "runner-skill-root-separation")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let runnerBoot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "runner-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.runnerKeys,
      pinStoreRoot: fixture.runnerPinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let readinessRegistry = TatwoRemoteDispatchReadinessRegistryStoreV1.production(
      stateRoot: fixture.stateDir,
      trust: runnerBoot.trust)

    XCTAssertThrowsError(
      try TatwoLoopRunnerV1(
        channel: runnerBoot.channel,
        deviceID: "runner-prod",
        environment: testEnv,
        workspaceRegistry: readinessRegistry,
        workspaceSkilletRootURL: fixture.root,
        workspaceSkillRuntimeRootURL: fixture.root)
    ) { error in
      XCTAssertEqual(
        error as? TatwoRemoteDispatchReadinessRegistryError,
        .bindingDrift("skillRuntimeRootMustNotBeSkilletStore"))
    }
  }

  func testRunnerReportsExpectedSkillDigestWhenBindingCannotBeBuilt() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "runner-skill-binding-missing")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-skill-binding-missing",
      logicalJobID: "logical-skill-binding-missing",
      dispatchNonce: "nonce-skill-binding-missing")
    _ = try TatwoLoopProductionRunnerBootstrap.dispatch(
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      job: job,
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      localRegistry: fixture.registry,
      localGoalRunStore: fixture.goalStore,
      allowTestOverrides: true,
      testReadinessProvider: fixture.readinessProvider)

    let runnerBoot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "runner-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.runnerKeys,
      pinStoreRoot: fixture.runnerPinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let engine = CountingLoopEngine()
    let runner = try TatwoLoopRunnerV1(
      channel: runnerBoot.channel,
      deviceID: "runner-prod",
      environment: [
        TatwoLoopSandboxUnlock.enableEnvKey: TatwoLoopSandboxUnlock.enableSandboxValue,
        TatwoLoopSandboxUnlock.sandboxRootEnvKey: fixture.root.path,
      ],
      engine: engine,
      localRegistry: TatwoDispatchRegistry(directoryURL: fixture.runnerRegistryDir),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.runnerRegistryDir))

    let receipts = try runner.runOnce()
    let receipt = try XCTUnwrap(receipts.first)
    XCTAssertEqual(receipt.failureCode, "agent_skill_binding_invalid")
    XCTAssertEqual(
      receipt.expectedActiveSkillSetDigest,
      fixture.remoteDispatchReadiness.activeSkillSetDigest)
    XCTAssertNil(receipt.actualLoadedSkillSetDigest)
    XCTAssertEqual(engine.invocationCount, 0)
  }

  func testProductionDispatchRejectsUnpinnedTarget() throws {
    let fixture = try makeDispatchFixture(label: "dispatch-unpinned")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // Separate pin root: origin + unrelated peer only (target absent).
    let pinRoot = fixture.root.appendingPathComponent("pins-unpinned", isDirectory: true)
    let originKeys = MemoryDevicePrivateKeyStore()
    let otherKeys = MemoryDevicePrivateKeyStore()
    let originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-prod",
      privateKeyStore: originKeys,
      environment: testEnv)
    let other = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "other-peer",
      privateKeyStore: otherKeys,
      environment: testEnv)
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: pinRoot,
      authority: originTrust.authority,
      localIdentity: originTrust.localIdentity,
      epochAnchor: fileEpochAnchor(for: pinRoot),
      environment: testEnv)
    try pinStore.pin(originTrust.localIdentity)
    try pinStore.pin(other.localIdentity)

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-unpinned-target",
      logicalJobID: "logical-unpinned-target",
      dispatchNonce: "nonce-unpinned",
      createdAt: Date(timeIntervalSince1970: 1_700_000_301))

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: originKeys,
        pinStoreRoot: pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .targetNotPinned("runner-prod"))
    }
  }

  func testProductionDispatchRejectsTestModeAndEnvOverride() throws {
    let root = tempRoot("dispatch-test-mode")
    defer { try? FileManager.default.removeItem(at: root) }
    let channelRoot = root.appendingPathComponent("channel", isDirectory: true)
    let pinRoot = root.appendingPathComponent("pins", isDirectory: true)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: channelRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pinRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    let job = TatwoLoopJobV1(
      jobID: "job-testmode",
      logicalJobID: "logical-testmode",
      dispatchNonce: "nonce-testmode",
      contractID: "contract-xl-coding-f51cfabe38f8",
      goalID: "goal-xl-coding-f51cfabe38f8",
      identity: .sub,
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_302))

    // Production path (allowTestOverrides=false) refuses TATWO_TEST_MODE=1.
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: testEnv,
        allowTestOverrides: false)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .testModeForbidden)
    }

    // Trust-namespace env override refused outside test mode.
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        pinStoreRoot: pinRoot,
        channelRoot: channelRoot,
        environment: [
          TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey: "evil.key.service"
        ],
        allowTestOverrides: false)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .trustNamespaceOverrideForbidden(
          TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey))
    }

    // Caller injection refused on production dispatch.
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: MemoryDevicePrivateKeyStore(),
        channelRoot: channelRoot,
        environment: [:],
        localRegistry: TatwoDispatchRegistry(directoryURL: root.appendingPathComponent("reg")),
        allowTestOverrides: false)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .productionInjectionForbidden("localRegistry"))
    }
  }

  // MARK: - Wave 0 package J: contract gate + prepare/commit

  func testProductionDispatchRejectsUnissuedContractWithoutChannelWrite() throws {
    let fixture = try makeDispatchFixture(label: "dispatch-unissued")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-unissued",
      logicalJobID: "logical-unissued",
      dispatchNonce: "nonce-unissued",
      contractID: "contract-m-coding-deadbeef0001",
      goalID: "goal-m-coding-deadbeef0001",
      createdAt: Date(timeIntervalSince1970: 1_700_000_310))

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: fixture.originKeys,
        pinStoreRoot: fixture.pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      guard case let .workOSContractGate(detail)? =
        error as? TatwoLoopProductionRunnerError
      else {
        return XCTFail("expected workOSContractGate, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("unregistered") || detail.contains("未由")
          || detail.contains("unauthorized"),
        detail)
    }

    // Bootstrap a channel view only to assert no artifacts (dispatch failed before write).
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  func testProductionDispatchRejectsGoalIDMismatchWithoutChannelWrite() throws {
    let fixture = try makeDispatchFixture(label: "dispatch-goal-mismatch")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-goal-mismatch",
      logicalJobID: "logical-goal-mismatch",
      dispatchNonce: "nonce-goal-mismatch",
      goalID: "goal-forged-mismatch",
      createdAt: Date(timeIntervalSince1970: 1_700_000_311))

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: fixture.originKeys,
        pinStoreRoot: fixture.pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      guard case let .workOSContractGate(detail)? =
        error as? TatwoLoopProductionRunnerError
      else {
        return XCTFail("expected workOSContractGate, got \(error)")
      }
      XCTAssertTrue(detail.contains("goalID mismatch"), detail)
    }

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  func testProductionDispatchRejectsSealedRunWithoutChannelWrite() throws {
    let fixture = try makeDispatchFixture(label: "dispatch-sealed")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // A finalized dispatch cycle remains resumable only through explicit cycle advance;
    // direct remote dispatch must still be refused at awaitingNextCycle.
    let first = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: fixture.contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "seed sealed set",
      helperCap: 4,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: fixture.contract.contractID,
      dispatchID: first.id,
      status: .completed,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    _ = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: fixture.contract.contractID,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(fixture.contract.contractID).status,
      .awaitingNextCycle)

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-sealed",
      logicalJobID: "logical-sealed",
      dispatchNonce: "nonce-sealed",
      createdAt: Date(timeIntervalSince1970: 1_700_000_312))

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: fixture.originKeys,
        pinStoreRoot: fixture.pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      guard case let .workOSContractGate(detail)? =
        error as? TatwoLoopProductionRunnerError
      else {
        return XCTFail("expected workOSContractGate, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("awaiting_next_cycle") || detail.contains("cannot begin"),
        detail)
    }

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  func testProductionDispatchSucceedsWithIssuedContract() throws {
    let fixture = try makeDispatchFixture(label: "dispatch-issued-ok")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-issued-ok",
      logicalJobID: "logical-issued-ok",
      dispatchNonce: "nonce-issued-ok",
      createdAt: Date(timeIntervalSince1970: 1_700_000_313))

    let dispatched = try TatwoLoopProductionRunnerBootstrap.dispatch(
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      job: job,
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      localRegistry: fixture.registry,
      localGoalRunStore: fixture.goalStore,
      allowTestOverrides: true)

    XCTAssertEqual(dispatched.job.contractID, fixture.contract.contractID)
    XCTAssertEqual(dispatched.job.goalID, fixture.contract.goalID)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dispatched.bootstrap.channel.jobSignatureURL(for: job).path))
    XCTAssertNotNil(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID })
  }

  func testRemoteBorrowRejectsMissingInvocationBeforeReservationOrChannel() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-missing-invocation")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-missing-invocation",
      logicalJobID: "logical-borrow-missing-invocation",
      dispatchNonce: "nonce-borrow-missing-invocation",
      omitRemoteBorrowInvocation: true)

    try assertBorrowDispatchRejected(
      fixture: fixture,
      job: job,
      expectedCode: .missingInvocation)
  }

  func testRemoteBorrowRejectsMissingSessionGrantBeforeReservationOrChannel() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-missing-grant")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let invocation = TatwoRemoteBorrowInvocationV1(
      sessionID: "thread-without-grant",
      targetDeviceID: "runner-prod",
      contractID: fixture.contract.contractID,
      goalID: fixture.contract.goalID,
      mode: .manual,
      risk: .lowRisk,
      grantID: "remote-grant-not-issued")
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-missing-grant",
      logicalJobID: "logical-borrow-missing-grant",
      dispatchNonce: "nonce-borrow-missing-grant",
      remoteBorrowInvocationOverride: invocation)

    try assertBorrowDispatchRejected(
      fixture: fixture,
      job: job,
      expectedCode: .sessionApprovalRequired)
  }

  func testRemoteBorrowRejectsGrantIDMismatchBeforeReservationOrChannel() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-grant-mismatch")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let invocation = TatwoRemoteBorrowInvocationV1(
      sessionID: fixture.remoteBorrowSessionID,
      targetDeviceID: "runner-prod",
      contractID: fixture.contract.contractID,
      goalID: fixture.contract.goalID,
      mode: .manual,
      risk: .lowRisk,
      grantID: "remote-grant-forged")
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-grant-mismatch",
      logicalJobID: "logical-borrow-grant-mismatch",
      dispatchNonce: "nonce-borrow-grant-mismatch",
      remoteBorrowInvocationOverride: invocation)

    try assertBorrowDispatchRejected(
      fixture: fixture,
      job: job,
      expectedCode: .grantIDMismatch)
  }

  func testRemoteBorrowRejectsRevokedGrantBeforeReservationOrChannel() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-revoked")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try fixture.remoteBorrowAuthorizationStore.revokeSession(
      sessionID: fixture.remoteBorrowSessionID)
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-revoked",
      logicalJobID: "logical-borrow-revoked",
      dispatchNonce: "nonce-borrow-revoked")

    try assertBorrowDispatchRejected(
      fixture: fixture,
      job: job,
      expectedCode: .sessionApprovalRequired)
  }

  func testRemoteBorrowRevokeBeforeAtomicReservationLeavesNoArtifacts() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-revoke-race")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-revoke-race",
      logicalJobID: "logical-borrow-revoke-race",
      dispatchNonce: "nonce-borrow-revoke-race")
    let reachedAuthorizationBoundary = DispatchSemaphore(value: 0)
    let allowAuthorizationBoundary = DispatchSemaphore(value: 0)
    let dispatchFinished = DispatchSemaphore(value: 0)
    let result = RemoteBorrowDispatchRaceResult()
    let environment = testEnv
    let readinessBoot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)

    DispatchQueue.global().async {
      defer { dispatchFinished.signal() }
      do {
        _ = try TatwoGoalRunDispatchLifecycle.beginRemote(
          job: job,
          goalStore: fixture.goalStore,
          dispatchRegistry: fixture.registry,
          authorizationStore: fixture.remoteBorrowAuthorizationStore,
          verifiedTargetIdentity: fixture.verifiedTargetIdentity,
          readinessTrust: readinessBoot.trust,
          readinessProvider: fixture.readinessProvider,
          environment: environment,
          afterPreflightAuthorization: {
            reachedAuthorizationBoundary.signal()
            _ = allowAuthorizationBoundary.wait(timeout: .now() + 5)
          })
        result.recordSuccess()
      } catch {
        result.record(error: error)
      }
    }
    defer { allowAuthorizationBoundary.signal() }

    XCTAssertEqual(
      reachedAuthorizationBoundary.wait(timeout: .now() + 5),
      .success,
      "dispatch did not reach the pre-authorization race boundary")
    let revoked = try fixture.remoteBorrowAuthorizationStore.revokeSession(
      sessionID: fixture.remoteBorrowSessionID)
    XCTAssertEqual(revoked.map(\.id), [fixture.remoteBorrowGrant.id])

    allowAuthorizationBoundary.signal()
    XCTAssertEqual(
      dispatchFinished.wait(timeout: .now() + 5),
      .success,
      "dispatch did not finish after revocation")

    guard case let .remoteDispatchUnauthorized(code, _)? =
      result.error as? TatwoGoalRunDispatchLifecycleError
    else {
      return XCTFail("expected remote authorization rejection, got \(result.description)")
    }
    XCTAssertEqual(
      code,
      TatwoRemoteBorrowAuthorizationBlockerV1.sessionApprovalRequired.rawValue)
    XCTAssertNil(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID },
      "a revoke completed before commit must prevent registry reservation")

    assertChannelArtifactsAbsent(channel: readinessBoot.channel, job: job)
  }

  func testRemoteBorrowRejectsExpiredGrantBeforeReservationOrChannel() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-expired")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let expiredSessionID = "thread-expired"
    let expiredGrant = try fixture.remoteBorrowAuthorizationStore.issueSessionGrant(
      sessionID: expiredSessionID,
      targetDeviceID: "runner-prod",
      contractID: fixture.contract.contractID,
      ttl: 300,
      now: Date().addingTimeInterval(-600))
    let invocation = TatwoRemoteBorrowInvocationV1(
      sessionID: expiredSessionID,
      targetDeviceID: "runner-prod",
      contractID: fixture.contract.contractID,
      goalID: fixture.contract.goalID,
      mode: .manual,
      risk: .lowRisk,
      grantID: expiredGrant.id)
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-expired",
      logicalJobID: "logical-borrow-expired",
      dispatchNonce: "nonce-borrow-expired",
      remoteBorrowInvocationOverride: invocation)

    try assertBorrowDispatchRejected(
      fixture: fixture,
      job: job,
      expectedCode: .sessionApprovalRequired)
  }

  func testAutomaticRemoteBorrowRequiresDeviceOptIn() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-auto-policy-off")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let invocation = TatwoRemoteBorrowInvocationV1(
      sessionID: fixture.remoteBorrowSessionID,
      targetDeviceID: "runner-prod",
      contractID: fixture.contract.contractID,
      goalID: fixture.contract.goalID,
      mode: .automatic,
      risk: .lowRisk,
      grantID: fixture.remoteBorrowGrant.id)
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-auto-policy-off",
      logicalJobID: "logical-borrow-auto-policy-off",
      dispatchNonce: "nonce-borrow-auto-policy-off",
      remoteBorrowInvocationOverride: invocation)

    try assertBorrowDispatchRejected(
      fixture: fixture,
      job: job,
      expectedCode: .automaticBorrowDisabled)
  }

  func testHighRiskRemoteBorrowRequiresUnimplementedOneShotGate() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "borrow-high-risk")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let invocation = TatwoRemoteBorrowInvocationV1(
      sessionID: fixture.remoteBorrowSessionID,
      targetDeviceID: "runner-prod",
      contractID: fixture.contract.contractID,
      goalID: fixture.contract.goalID,
      mode: .manual,
      risk: .highRisk,
      oneShotApprovalID: "one-shot-not-yet-consumable")
    let job = makeRemoteBorrowDispatchJob(
      fixture: fixture,
      jobID: "job-borrow-high-risk",
      logicalJobID: "logical-borrow-high-risk",
      dispatchNonce: "nonce-borrow-high-risk",
      remoteBorrowInvocationOverride: invocation)

    try assertBorrowDispatchRejected(
      fixture: fixture,
      job: job,
      expectedCode: .perInvocationApprovalRequired)
  }

  /// `.tatwoLoop` + agent payload: signed dispatch + contract gate still apply;
  /// unpinned target still fail-closed (no channel write).
  func testProductionDispatchTatwoLoopAgentSignedAndUnpinnedStillRejected() throws {
    let fixture = try makeGrokBuildDispatchFixture(label: "dispatch-tatwo-agent")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let agentPayload = TatwoLoopJobPayloadV1.tatwoLoop(
      TatwoLoopPayloadV1(
        contractID: fixture.contract.contractID,
        goalID: fixture.contract.goalID,
        identity: .sub,
        mode: .m,
        taskDescription: "remote agent task from origin",
        agent: .grok,
        exactModelRouteID: "grok-build"))
    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-tatwo-agent",
      logicalJobID: "logical-tatwo-agent",
      dispatchNonce: "nonce-tatwo-agent",
      payload: agentPayload,
      createdAt: Date(timeIntervalSince1970: 1_700_000_320))

    let dispatched = try TatwoLoopProductionRunnerBootstrap.dispatch(
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      job: job,
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      localRegistry: fixture.registry,
      localGoalRunStore: fixture.goalStore,
      allowTestOverrides: true,
      testReadinessProvider: fixture.readinessProvider)

    XCTAssertEqual(dispatched.job.contractID, fixture.contract.contractID)
    guard case let .tatwoLoop(loop) = dispatched.job.payload else {
      return XCTFail("expected tatwo-loop payload")
    }
    XCTAssertEqual(loop.agent, .grok)
    XCTAssertEqual(loop.taskDescription, "remote agent task from origin")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: dispatched.bootstrap.channel.jobSignatureURL(for: job).path),
      "agent tatwo-loop jobs must be origin-signed like shell-safe")
    // Signature verifies (digest binding intact).
    XCTAssertFalse(dispatched.jobCanonicalDigest.isEmpty)

    // Unpinned target still rejected with no channel write for a second agent job.
    let pinRoot = fixture.root.appendingPathComponent("pins-unpinned-agent", isDirectory: true)
    let originKeys = MemoryDevicePrivateKeyStore()
    let otherKeys = MemoryDevicePrivateKeyStore()
    let originTrust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "origin-prod",
      privateKeyStore: originKeys,
      environment: testEnv)
    let other = try TatwoLoopJobChannelTrust.enroll(
      deviceID: "other-peer",
      privateKeyStore: otherKeys,
      environment: testEnv)
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: pinRoot,
      authority: originTrust.authority,
      localIdentity: originTrust.localIdentity,
      epochAnchor: fileEpochAnchor(for: pinRoot),
      environment: testEnv)
    try pinStore.pin(originTrust.localIdentity)
    try pinStore.pin(other.localIdentity)

    let unpinnedJob = makeDispatchJob(
      fixture: fixture,
      jobID: "job-tatwo-agent-unpinned",
      logicalJobID: "logical-tatwo-agent-unpinned",
      dispatchNonce: "nonce-tatwo-agent-unpinned",
      payload: agentPayload,
      createdAt: Date(timeIntervalSince1970: 1_700_000_321))
    let unpinnedChannel = fixture.root.appendingPathComponent(
      "channel-unpinned-agent", isDirectory: true)
    try FileManager.default.createDirectory(at: unpinnedChannel, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: unpinnedJob,
        privateKeyStore: originKeys,
        pinStoreRoot: pinRoot,
        channelRoot: unpinnedChannel,
        environment: testEnv,
        localRegistry: TatwoDispatchRegistry(
          directoryURL: fixture.root.appendingPathComponent("state-unpinned")),
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      XCTAssertEqual(
        error as? TatwoLoopProductionRunnerError,
        .targetNotPinned("runner-prod"))
    }
    let outbox = unpinnedChannel
      .appendingPathComponent("outbox", isDirectory: true)
      .appendingPathComponent("runner-prod", isDirectory: true)
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: outbox, includingPropertiesForKeys: nil)) ?? []
    XCTAssertTrue(entries.isEmpty, "unpinned agent dispatch must not write channel artifacts")
  }

  /// Registry sealed before channel commit: outbox / signature / journal / ack stay empty.
  func testOriginEnqueueRegistrySealedLeavesNoChannelArtifacts() throws {
    let fixture = try makeDispatchFixture(label: "enqueue-sealed-order")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // Seed + seal registry set so beginRemote requireUnsealed fails.
    let seed = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: fixture.contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "seed",
      helperCap: 4,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    _ = try TatwoGoalRunDispatchLifecycle.update(
      contractID: fixture.contract.contractID,
      dispatchID: seed.id,
      status: .completed,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    _ = try TatwoGoalRunDispatchLifecycle.finalize(
      contractID: fixture.contract.contractID,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let origin = TatwoLoopOriginProjectorV1(
      channel: boot.channel,
      registry: fixture.registry,
      originDeviceID: "origin-prod",
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.stateDir))

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-reg-sealed",
      logicalJobID: "logical-reg-sealed",
      dispatchNonce: "nonce-reg-sealed",
      createdAt: Date(timeIntervalSince1970: 1_700_000_314))

    XCTAssertThrowsError(try origin.enqueue(job)) { error in
      guard case .runSealed = error as? TatwoDispatchRegistryError else {
        return XCTFail("expected runSealed, got \(error)")
      }
    }
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  /// Invalid contractID rejected at registry prepare: no channel artifacts.
  func testOriginEnqueueRegistryRejectLeavesNoChannelArtifacts() throws {
    let fixture = try makeDispatchFixture(label: "enqueue-reg-reject")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let origin = TatwoLoopOriginProjectorV1(
      channel: boot.channel,
      registry: fixture.registry,
      originDeviceID: "origin-prod",
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.stateDir))

    // Uppercase / underscore contractID fails fileURL validation in registry.
    let job = TatwoLoopJobV1(
      jobID: "job-reg-reject",
      logicalJobID: "logical-reg-reject",
      dispatchNonce: "nonce-reg-reject",
      contractID: "Contract_INVALID",
      goalID: "goal-invalid",
      identity: .sub,
      originDeviceID: "origin-prod",
      targetDeviceID: "runner-prod",
      payload: .shellSafe(TatwoShellSafePayloadV1(command: .true)),
      workPath: fixture.work.path,
      resourceCaps: TatwoLoopResourceCapsV1(maxDurationSec: 1, maxOutputBytes: 64),
      stopConditions: TatwoLoopStopConditionsV1(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_315))

    XCTAssertThrowsError(try origin.enqueue(job))
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  /// Persistence failure at registry prepare: no outbox/signature/journal/ack.
  func testOriginEnqueueRegistryPersistenceFailureLeavesNoChannelArtifacts() throws {
    let fixture = try makeDispatchFixture(label: "enqueue-reg-persist")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    // Point registry at a file path so write cannot create goals/*.json.
    let poisonFile = fixture.root.appendingPathComponent("not-a-directory")
    try Data("x".utf8).write(to: poisonFile)
    let poisonRegistry = TatwoDispatchRegistry(directoryURL: poisonFile)

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let origin = TatwoLoopOriginProjectorV1(
      channel: boot.channel,
      registry: poisonRegistry,
      originDeviceID: "origin-prod",
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.stateDir))

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-reg-persist",
      logicalJobID: "logical-reg-persist",
      dispatchNonce: "nonce-reg-persist",
      createdAt: Date(timeIntervalSince1970: 1_700_000_316))

    XCTAssertThrowsError(try origin.enqueue(job))
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  // MARK: - Wave 0 package K: unified prepare gate + atomic channel commit

  /// K1: GoalRun terminal (failed) after issue — prepare refuses reservation; no channel write.
  func testK1PrepareGateRejectsFailedGoalRunWithoutReservationOrChannel() throws {
    let fixture = try makeDispatchFixture(label: "k1-failed-goal")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let seed = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: fixture.contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "seed-to-running",
      helperCap: 4,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    _ = seed
    _ = try fixture.goalStore.updateStatus(
      contractID: fixture.contract.contractID,
      status: .failed)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(fixture.contract.contractID).status,
      .failed)

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-k1-failed",
      logicalJobID: "logical-k1-failed",
      dispatchNonce: "nonce-k1-failed",
      createdAt: Date(timeIntervalSince1970: 1_700_000_320))

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: fixture.originKeys,
        pinStoreRoot: fixture.pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      guard case let .workOSContractGate(detail)? =
        error as? TatwoLoopProductionRunnerError
      else {
        return XCTFail("expected workOSContractGate, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("failed") || detail.contains("cannot begin"),
        detail)
    }

    XCTAssertNil(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID },
      "registry reservation must not succeed for terminal GoalRun")

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  /// K1: GoalRun cancelled — prepare refuses; no reservation / channel artifacts.
  func testK1PrepareGateRejectsCancelledGoalRunWithoutReservationOrChannel() throws {
    let fixture = try makeDispatchFixture(label: "k1-cancelled-goal")
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    _ = try TatwoGoalRunDispatchLifecycle.begin(
      contractID: fixture.contract.contractID,
      bindingID: "binding-sub",
      sourceSlotID: "sub",
      identity: .sub,
      modelID: "gpt-5.6-sol",
      subtask: "seed-to-running",
      helperCap: 4,
      goalStore: fixture.goalStore,
      dispatchRegistry: fixture.registry)
    _ = try fixture.goalStore.updateStatus(
      contractID: fixture.contract.contractID,
      status: .cancelled)
    XCTAssertEqual(
      try fixture.goalStore.requireIssuedContract(fixture.contract.contractID).status,
      .cancelled)

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-k1-cancelled",
      logicalJobID: "logical-k1-cancelled",
      dispatchNonce: "nonce-k1-cancelled",
      createdAt: Date(timeIntervalSince1970: 1_700_000_321))

    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: job,
        privateKeyStore: fixture.originKeys,
        pinStoreRoot: fixture.pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      guard case let .workOSContractGate(detail)? =
        error as? TatwoLoopProductionRunnerError
      else {
        return XCTFail("expected workOSContractGate, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("cancelled") || detail.contains("cannot begin"),
        detail)
    }

    XCTAssertNil(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID })

    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    assertChannelArtifactsAbsent(channel: boot.channel, job: job)
  }

  /// K1: unified beginRemote is the production prepare path (not bare registry after authorize).
  func testK1ProductionDispatchUsesUnifiedBeginRemotePrepareGate() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // TatwoUltraworkCoreTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // package root
    let productionSource = try String(
      contentsOf: packageRoot
        .appendingPathComponent("Sources/TatwoUltraworkCore/RemoteLoopProductionRunner.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      productionSource.contains("goalStore: goalStore"),
      "production dispatch must pass goalStore into origin projector")
    XCTAssertTrue(
      productionSource.contains(
        "TatwoRemoteBorrowAuthorizationStore.production"),
      "production dispatch must derive borrow approvals from the locked state root")
    XCTAssertTrue(
      productionSource.contains(
        "remoteBorrowAuthorizationStore: remoteBorrowAuthorizationStore"),
      "production dispatch must pass the durable borrow store into unified prepare")
    XCTAssertTrue(
      productionSource.contains("verifiedTargetIdentity: targetPin"),
      "production dispatch must pass verified pin evidence, not a UI Boolean")
    XCTAssertFalse(
      productionSource.contains("authorizeRemoteDispatch("),
      "production must not separately authorize outside beginRemote")
    let originSource = try String(
      contentsOf: packageRoot
        .appendingPathComponent("Sources/TatwoUltraworkCore/RemoteLoopRunner.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      originSource.contains("TatwoGoalRunDispatchLifecycle.beginRemote"),
      "origin.enqueue must call unified beginRemote prepare gate")
    XCTAssertTrue(
      originSource.contains("quarantineChannelEnqueueFailure"),
      "channel commit failure must quarantine via lifecycle (not try?)")
    // Origin enqueue catch must use hard projectRemoteStatus (no try?) when goalStore is absent.
    XCTAssertTrue(
      originSource.contains(
        """
                _ = try registry.projectRemoteStatus(
                  contractID: job.contractID,
                  remoteJobID: job.jobID,
                  remoteStatus: .failed,
                  failureCode: "channel_enqueue_failed",
        """),
      "legacy enqueue reconciliation must not swallow projectRemoteStatus")
  }

  func testTestModeUnboundEnqueueFailureHardProjectsFailedStatus() throws {
    let fixture = try makeDispatchFixture(label: "test-mode-unbound-enqueue-failure")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let faultedChannel = TatwoLoopJobChannel(
      rootURL: boot.channel.rootURL,
      trust: boot.channel.trust,
      environment: testEnv,
      enqueueFaultBox: TatwoLoopChannelEnqueueFaultBox(failAt: .job))
    let origin = TatwoLoopOriginProjectorV1(
      channel: faultedChannel,
      registry: fixture.registry,
      originDeviceID: "origin-prod",
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.stateDir))
    let job = makeDispatchJob(
      fixture: fixture,
      jobID: "job-test-mode-unbound-enqueue-failure",
      logicalJobID: "logical-test-mode-unbound-enqueue-failure",
      dispatchNonce: "nonce-test-mode-unbound-enqueue-failure")

    XCTAssertThrowsError(try origin.enqueue(job))

    let remote = try XCTUnwrap(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID })
    XCTAssertEqual(remote.remoteStatus, .failed)
    XCTAssertEqual(remote.failureReceipt?.errorCode, "channel_enqueue_failed")
    XCTAssertTrue(
      remote.errorMessage?.contains("reconciliation_required:channel_enqueue:") == true
        || remote.failureReceipt?.operatorMessage.contains(
          "reconciliation_required:channel_enqueue:") == true)
  }

  /// K2: each enqueue write stage can fail; target must not execute; GoalRun reconciles.
  func testK2FaultInjectJobStageTargetDoesNotExecuteAndGoalRunReconciles() throws {
    try assertK2EnqueueStageFault(
      stage: .job,
      label: "k2-fault-job",
      jobID: "job-k2-job")
  }

  func testK2FaultInjectSignatureStageTargetDoesNotExecuteAndGoalRunReconciles() throws {
    try assertK2EnqueueStageFault(
      stage: .signature,
      label: "k2-fault-sig",
      jobID: "job-k2-sig")
  }

  func testK2FaultInjectJournalStageTargetDoesNotExecuteAndGoalRunReconciles() throws {
    try assertK2EnqueueStageFault(
      stage: .journal,
      label: "k2-fault-journal",
      jobID: "job-k2-journal")
  }

  func testK2FaultInjectAckStageTargetDoesNotExecuteAndGoalRunReconciles() throws {
    try assertK2EnqueueStageFault(
      stage: .ack,
      label: "k2-fault-ack",
      jobID: "job-k2-ack")
  }

  func testK2FaultInjectCommitMarkerStageTargetDoesNotExecuteAndGoalRunReconciles() throws {
    try assertK2EnqueueStageFault(
      stage: .commitMarker,
      label: "k2-fault-commit",
      jobID: "job-k2-commit")
  }

  private func assertK2EnqueueStageFault(
    stage: TatwoLoopChannelEnqueueStage,
    label: String,
    jobID: String
  ) throws {
    let fixture = try makeDispatchFixture(label: label)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let fault = TatwoLoopChannelEnqueueFaultBox(failAt: stage)
    let boot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "origin-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.originKeys,
      pinStoreRoot: fixture.pinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    // Rebuild channel with the same trust box but fault injection enabled.
    let faultedChannel = TatwoLoopJobChannel(
      rootURL: boot.channel.rootURL,
      trust: boot.channel.trust,
      environment: testEnv,
      enqueueFaultBox: fault)
    let origin = TatwoLoopOriginProjectorV1(
      channel: faultedChannel,
      registry: fixture.registry,
      originDeviceID: "origin-prod",
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.stateDir),
      goalStore: fixture.goalStore,
      remoteBorrowAuthorizationStore: fixture.remoteBorrowAuthorizationStore,
      verifiedTargetIdentity: try XCTUnwrap(
        boot.trust.pinnedIdentities["runner-prod"]),
      remoteReadinessProvider: fixture.readinessProvider,
      environment: testEnv)

    let job = makeDispatchJob(
      fixture: fixture,
      jobID: jobID,
      logicalJobID: "logical-\(jobID)",
      dispatchNonce: "nonce-\(jobID)",
      createdAt: Date(timeIntervalSince1970: 1_700_000_330))
    XCTAssertThrowsError(try origin.enqueue(job)) { error in
      guard case let .enqueueIncomplete(_, failedStage)? =
        error as? TatwoLoopJobStateError
      else {
        return XCTFail("expected enqueueIncomplete at \(stage), got \(error)")
      }
      XCTAssertEqual(failedStage, stage.rawValue)
    }

    XCTAssertFalse(
      faultedChannel.hasCommitMarker(forJobID: job.jobID),
      "commit marker must be absent after stage \(stage) fault")
    switch stage {
    case .job:
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: faultedChannel.jobURL(for: job).path))
    case .signature:
      XCTAssertTrue(FileManager.default.fileExists(atPath: faultedChannel.jobURL(for: job).path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: faultedChannel.jobSignatureURL(for: job).path))
    case .journal:
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: faultedChannel.jobSignatureURL(for: job).path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: faultedChannel.journalURL(forJobID: job.jobID).path))
    case .ack:
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: faultedChannel.journalURL(forJobID: job.jobID).path))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: faultedChannel.ackURL(forJobID: job.jobID).path))
    case .commitMarker:
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: faultedChannel.ackURL(forJobID: job.jobID).path))
      XCTAssertFalse(faultedChannel.hasCommitMarker(forJobID: job.jobID))
    }

    // GoalRun must be blocked / reconciliation-required; later prepare refuses.
    let goal = try fixture.goalStore.requireIssuedContract(fixture.contract.contractID)
    XCTAssertEqual(goal.status, .blocked)
    XCTAssertTrue(
      goal.statusReason?.hasPrefix("reconciliation_required:channel_enqueue:") == true,
      goal.statusReason ?? "nil")

    let remote = try XCTUnwrap(
      try fixture.registry.run(forContractID: fixture.contract.contractID)?
        .records.first { $0.remoteJobID == job.jobID })
    XCTAssertEqual(remote.remoteStatus, .failed)
    XCTAssertEqual(remote.failureReceipt?.errorCode, "channel_enqueue_failed")
    XCTAssertTrue(
      remote.errorMessage?.contains("reconciliation_required:channel_enqueue:") == true
        || remote.failureReceipt?.operatorMessage.contains("reconciliation_required:channel_enqueue:")
          == true,
      remote.errorMessage ?? remote.failureReceipt?.operatorMessage ?? "nil")

    // Target must not execute incomplete enqueue.
    let runnerBoot = try TatwoLoopProductionRunnerBootstrap.bootstrap(
      deviceID: "runner-prod",
      originDeviceID: "origin-prod",
      privateKeyStore: fixture.runnerKeys,
      pinStoreRoot: fixture.runnerPinRoot,
      channelRoot: fixture.channelRoot,
      environment: testEnv,
      allowTestOverrides: true)
    let engine = CountingLoopEngine()
    let runner = try TatwoLoopRunnerV1(
      channel: runnerBoot.channel,
      deviceID: "runner-prod",
      pollIntervalSec: 0.01,
      environment: testEnv,
      engine: engine,
      localRegistry: TatwoDispatchRegistry(directoryURL: fixture.runnerRegistryDir),
      memoryGate: MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: fixture.runnerRegistryDir))
    let receipts = try runner.runOnce()
    XCTAssertTrue(receipts.isEmpty, "target must not execute incomplete job at stage \(stage)")
    XCTAssertEqual(engine.invocationCount, 0)

    // Subsequent production dispatch is blocked by reconciliation GoalRun state.
    let retryJob = makeDispatchJob(
      fixture: fixture,
      jobID: "\(jobID)-retry",
      logicalJobID: "logical-\(jobID)-retry",
      dispatchNonce: "nonce-\(jobID)-retry",
      createdAt: Date(timeIntervalSince1970: 1_700_000_331))
    XCTAssertThrowsError(
      try TatwoLoopProductionRunnerBootstrap.dispatch(
        originDeviceID: "origin-prod",
        targetDeviceID: "runner-prod",
        job: retryJob,
        privateKeyStore: fixture.originKeys,
        pinStoreRoot: fixture.pinRoot,
        channelRoot: fixture.channelRoot,
        environment: testEnv,
        localRegistry: fixture.registry,
        localGoalRunStore: fixture.goalStore,
        allowTestOverrides: true)
    ) { error in
      guard case let .workOSContractGate(detail)? =
        error as? TatwoLoopProductionRunnerError
      else {
        return XCTFail("expected workOSContractGate after reconciliation, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("blocked") || detail.contains("cannot begin")
          || detail.contains("reconciliation"),
        detail)
    }
  }

  private func copyTree(from source: URL, to destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
  }
}

private struct ProductionDispatchFixtureReadinessProvider:
  TatwoRemoteDispatchReadinessProviding, Sendable
{
  let targetTrust: TatwoLoopJobChannelTrust
  let workspaceBindingID: String
  let workspaceBindingDigest: String
  let agentModelCapabilityDigest: String
  let activeSkillSetDigest: String

  func readinessReceipt(
    for request: TatwoRemoteDispatchReadinessRequestV1
  ) throws -> TatwoRemoteDispatchReadinessReceiptV1 {
    try TatwoRemoteDispatchReadinessReceiptV1.issue(
      request: request,
      observation: TatwoRemoteDispatchReadinessObservationV1(
        targetWorkspaceBindingID: workspaceBindingID,
        targetWorkspaceBindingDigest: workspaceBindingDigest,
        agentModelCapabilityDigest: agentModelCapabilityDigest,
        activeSkillSetDigest: activeSkillSetDigest,
        readbackNonce: request.challengeNonce),
      targetTrust: targetTrust)
  }
}

/// Counts tatwo-loop engine entries for anti-replay regression tests.
private final class CountingLoopEngine: TatwoLoopEngineBinding, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var invocationCount = 0
  private(set) var taskDescriptions: [String] = []

  func run(
    task: TatwoLoopEngineTaskV1,
    boundWorkPath: TatwoBoundWorkPath,
    caps: TatwoLoopResourceCapsV1,
    shouldCancel: @Sendable () -> Bool
  ) throws -> TatwoLoopEngineResultV1 {
    _ = boundWorkPath
    lock.lock()
    invocationCount += 1
    taskDescriptions.append(task.taskDescription)
    lock.unlock()
    return TatwoLoopEngineResultV1(exitCode: 0, outputData: Data("ok\n".utf8))
  }
}

/// Shared state for claim-vs-generation race.
private final class ClaimRaceBox: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var didClaim = false
  private(set) var didEngineDone = false
  private(set) var errorMessage: String?

  func markClaimed() {
    lock.lock()
    didClaim = true
    lock.unlock()
  }

  func markEngineDone() {
    lock.lock()
    didEngineDone = true
    lock.unlock()
  }

  func fail(_ message: String) {
    lock.lock()
    if errorMessage == nil { errorMessage = message }
    lock.unlock()
  }
}

private final class RemoteBorrowDispatchRaceResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?
  private var succeeded = false

  var error: Error? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }

  var description: String {
    lock.lock()
    defer { lock.unlock() }
    if let storedError { return String(describing: storedError) }
    return succeeded ? "unexpected success" : "no result"
  }

  func record(error: Error) {
    lock.lock()
    storedError = error
    lock.unlock()
  }

  func recordSuccess() {
    lock.lock()
    succeeded = true
    lock.unlock()
  }
}

/// In-memory private key store for unit tests only.
private final class MemoryDevicePrivateKeyStore:
  @unchecked Sendable,
  TatwoDevicePrivateKeyStore
{
  private let lock = NSLock()
  private var keys: [String: Data] = [:]

  private static func account(deviceID: String, generation: UInt64) -> String {
    "\(deviceID)#\(generation)"
  }

  func loadPrivateKey(deviceID: String, generation: UInt64) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return keys[Self.account(deviceID: deviceID, generation: generation)]
  }

  func storePrivateKey(_ key: Data, deviceID: String, generation: UInt64) throws {
    guard key.count == 32 else { throw TatwoDeviceTrustError.invalidPrivateKey }
    let account = Self.account(deviceID: deviceID, generation: generation)
    lock.lock()
    defer { lock.unlock() }
    if let existing = keys[account], existing != key {
      throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
    }
    keys[account] = key
  }
}
