import Foundation
import TatwoDomainContracts

/// Production remote-loop runner bootstrap (Keychain identity + mandatory durable pins).
///
/// Test/sandbox drivers must not call this path. Production refuses empty pin stores,
/// load rejections, and epoch/root regression (via pin-store load).
public enum TatwoLoopProductionRunnerError: Error, LocalizedError, Sendable, Equatable {
  case missingDeviceID
  case missingOriginDeviceID
  case missingTargetDeviceID
  case emptyPinStore
  case pinStoreRejections(pins: Int, revocations: Int)
  case originNotPinned(String)
  case originRevoked(String)
  case targetNotPinned(String)
  case targetRevoked(String)
  case jobDeviceBindingMismatch(String)
  case testDriverForbidden
  case testModeForbidden
  case missingChannelRoot
  case pinStoreRootOverrideForbidden(String)
  case pinStoreNotInitialized
  case trustNamespaceOverrideForbidden(String)
  case layoutEnvOverrideForbidden(String)
  case channelRootOverrideForbidden(String)
  case layoutLock(TatwoProductionLayoutError)
  case productionInjectionForbidden(String)
  case missingOriginLease
  /// Work OS contract gate rejected remote dispatch (see TatwoGoalRunDispatchLifecycle).
  case workOSContractGate(String)

  public var errorDescription: String? {
    switch self {
    case .missingDeviceID:
      return "remote-runner requires --device-id"
    case .missingOriginDeviceID:
      return "remote-runner requires --origin-device-id"
    case .missingTargetDeviceID:
      return "remote-runner dispatch requires --target-device-id"
    case .emptyPinStore:
      return "production remote-runner refuses empty durable pin store"
    case let .pinStoreRejections(pins, revocations):
      return
        "production remote-runner refuses pin store with rejections (pins=\(pins), revocations=\(revocations))"
    case let .originNotPinned(id):
      return "production remote-runner requires active pin for origin device \(id)"
    case let .originRevoked(id):
      return "production remote-runner refuses revoked origin pin \(id)"
    case let .targetNotPinned(id):
      return "production remote-runner dispatch requires active pin for target device \(id)"
    case let .targetRevoked(id):
      return "production remote-runner dispatch refuses revoked target pin \(id)"
    case let .jobDeviceBindingMismatch(detail):
      return "production remote-runner dispatch job binding mismatch: \(detail)"
    case .testDriverForbidden:
      return "production remote-runner must not use the sandbox test driver"
    case .testModeForbidden:
      return "production remote-runner refuses TATWO_TEST_MODE=1"
    case .missingChannelRoot:
      return "TATWO_ULTRAWORK_JOB_CHANNEL_DIR is required for production remote-runner"
    case let .pinStoreRootOverrideForbidden(path):
      return "production remote-runner refuses non-canonical --pin-store-root: \(path)"
    case .pinStoreNotInitialized:
      return "production pin-store is not initialized; run device-trust init first"
    case let .trustNamespaceOverrideForbidden(envKey):
      return "production remote-runner refuses trust-namespace env override: \(envKey)"
    case let .layoutEnvOverrideForbidden(envKey):
      return "production remote-runner refuses non-canonical layout env: \(envKey)"
    case let .channelRootOverrideForbidden(path):
      return "production remote-runner refuses non-canonical channel root: \(path)"
    case let .layoutLock(error):
      return error.errorDescription
    case let .productionInjectionForbidden(detail):
      return "production remote-runner refuses caller injection: \(detail)"
    case .missingOriginLease:
      return "production remote-runner requires a registered, durable origin lease"
    case let .workOSContractGate(detail):
      return "production remote-runner dispatch Work OS contract gate: \(detail)"
    }
  }
}

public struct TatwoLoopProductionRunnerBootstrapResult: Sendable {
  public let trust: TatwoLoopJobChannelTrust
  public let channel: TatwoLoopJobChannel
  public let deviceID: String
  public let originDeviceID: String
  public let pinStoreGeneration: UInt64
  public let peerPinCount: Int
  /// Locked production state root (registry / GoalRunStore). Nil under test overrides.
  public let lockedStateRoot: URL?

  public init(
    trust: TatwoLoopJobChannelTrust,
    channel: TatwoLoopJobChannel,
    deviceID: String,
    originDeviceID: String,
    pinStoreGeneration: UInt64,
    peerPinCount: Int,
    lockedStateRoot: URL? = nil
  ) {
    self.trust = trust
    self.channel = channel
    self.deviceID = deviceID
    self.originDeviceID = originDeviceID
    self.pinStoreGeneration = pinStoreGeneration
    self.peerPinCount = peerPinCount
    self.lockedStateRoot = lockedStateRoot
  }
}

/// Origin-side production dispatch receipt (signed job enqueued into sealed channel).
public struct TatwoLoopProductionDispatchResult: Sendable {
  public let bootstrap: TatwoLoopProductionRunnerBootstrapResult
  public let job: TatwoLoopJobV1
  public let jobCanonicalDigest: String
  public let channelRoot: String
  public let dispatchRecordID: String

  public init(
    bootstrap: TatwoLoopProductionRunnerBootstrapResult,
    job: TatwoLoopJobV1,
    jobCanonicalDigest: String,
    channelRoot: String,
    dispatchRecordID: String
  ) {
    self.bootstrap = bootstrap
    self.job = job
    self.jobCanonicalDigest = jobCanonicalDigest
    self.channelRoot = channelRoot
    self.dispatchRecordID = dispatchRecordID
  }
}

public enum TatwoLoopProductionRunnerBootstrap {
  /// Enroll production trust: Keychain (or injected store) + **forced** durable pin load.
  /// Caller cannot disable durable pin loading on this path.
  public static func bootstrap(
    deviceID: String,
    originDeviceID: String,
    privateKeyStore: any TatwoDevicePrivateKeyStore,
    pinStoreRoot: URL? = nil,
    channelRoot: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    /// Test-only: allow non-canonical pin-store root and TEST_MODE under unit tests.
    allowTestOverrides: Bool = false,
    /// Production install-anchor store (Keychain by default). Tests may inject file store.
    installAnchorStore: (any TatwoProductionInstallAnchorStore)? = nil,
    /// Production global anti-rollback (Keychain by default).
    globalAntiRollbackAnchor: (any TatwoLoopGlobalAntiRollbackAnchor)? = nil,
    applicationSupportBase: URL? = nil,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil,
    currentOriginLease: TatwoAuthorityLeaseV1? = nil
  ) throws -> TatwoLoopProductionRunnerBootstrapResult {
    let trimmedDevice = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedOrigin = originDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDevice.isEmpty, TatwoLoopPathComponent.isValid(trimmedDevice) else {
      throw TatwoLoopProductionRunnerError.missingDeviceID
    }
    guard !trimmedOrigin.isEmpty, TatwoLoopPathComponent.isValid(trimmedOrigin) else {
      throw TatwoLoopProductionRunnerError.missingOriginDeviceID
    }
    // Production hard-rejects test mode environment (not only test file keystores).
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1", !allowTestOverrides {
      throw TatwoLoopProductionRunnerError.testModeForbidden
    }
    if privateKeyStore is TatwoDeviceTestFilePrivateKeyStore {
      throw TatwoLoopProductionRunnerError.testDriverForbidden
    }
    // Fail closed on trust Keychain namespace relocation (same class as root switching).
    if !allowTestOverrides {
      try Self.rejectProductionTrustNamespaceOverrides(environment: environment)
    }

    // E1: production layout roots are sealed install-anchor / OS-native — not env-defined.
    // F5: when allowTestOverrides=false, refuse all caller-supplied layout/anchor injections.
    if !allowTestOverrides {
      if installAnchorStore != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "installAnchorStore")
      }
      if globalAntiRollbackAnchor != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "globalAntiRollbackAnchor")
      }
      if applicationSupportBase != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "applicationSupportBase")
      }
    }
    // K1: production cannot fall back to the legacy allow-all provider.  Keep
    // this after the existing injection fence so caller-injection errors
    // retain their established precedence.
    if !allowTestOverrides, currentOriginLease == nil {
      throw TatwoLoopProductionRunnerError.missingOriginLease
    }

    let lockedLayout: TatwoProductionResolvedLayout?
    let storeRoot: URL
    let resolvedChannelRoot: URL
    let lockedStateRoot: URL?
    let antiRollbackForChannel: (any TatwoLoopGlobalAntiRollbackAnchor)?
    if allowTestOverrides {
      lockedLayout = nil
      lockedStateRoot = nil
      // Test path may still use env-derived roots (isolated fixtures).
      let envCanonical = TatwoDeviceTrustPinStore.defaultRoot(environment: environment)
        .standardizedFileURL
      if let pinStoreRoot {
        storeRoot = pinStoreRoot.standardizedFileURL
      } else {
        storeRoot = envCanonical
      }
      if let channelRoot {
        resolvedChannelRoot = channelRoot.standardizedFileURL
      } else {
        guard let raw = environment["TATWO_ULTRAWORK_JOB_CHANNEL_DIR"]?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
        else {
          throw TatwoLoopProductionRunnerError.missingChannelRoot
        }
        resolvedChannelRoot = URL(fileURLWithPath: raw, isDirectory: true)
      }
      // Optional test injection of global anti-rollback (claim + consume high-water).
      antiRollbackForChannel = globalAntiRollbackAnchor
    } else {
      // Production: always locked Keychain + OS-native roots (no caller injection).
      let anchorStore = TatwoProductionInstallAnchorKeychainStore()
      let layout: TatwoProductionResolvedLayout
      do {
        // F4: resolve requires an already-sealed install anchor (no implicit create).
        layout = try TatwoProductionLayoutLock.resolve(
          hostDeviceID: trimmedDevice,
          requestedChannelRoot: channelRoot,
          environment: environment,
          installAnchorStore: anchorStore,
          applicationSupportBase: nil)
      } catch let error as TatwoProductionLayoutError {
        throw mapLayoutError(error)
      }
      lockedLayout = layout
      lockedStateRoot = layout.stateRoot
      storeRoot = layout.pinStoreRoot
      resolvedChannelRoot = layout.jobChannelRoot
      if let pinStoreRoot {
        let requested = pinStoreRoot.standardizedFileURL
        if requested.path != storeRoot.path {
          throw TatwoLoopProductionRunnerError.pinStoreRootOverrideForbidden(requested.path)
        }
      }
      let keychainAntiRollback =
        TatwoLoopGlobalAntiRollbackKeychainAnchor(hostDeviceID: trimmedDevice)
      // Package G split accounts do not read package-F whole-blob
      // `global-anti-rollback:<host>`. Fresh pilot hosts are empty; non-empty legacy
      // claims must not be silently ignored (migration or explicit empty confirm).
      do {
        try keychainAntiRollback.requireLegacyWholeBlobAbsentOrEmpty()
      } catch let error as TatwoProductionLayoutError {
        throw mapLayoutError(error)
      }
      antiRollbackForChannel = keychainAntiRollback
    }

    // loadDurablePins is forced true — no caller switch.
    let trust = try TatwoLoopJobChannelTrust.enroll(
      deviceID: trimmedDevice,
      privateKeyStore: privateKeyStore,
      durablePinStoreRoot: storeRoot,
      loadDurablePins: true,
      environment: environment)

    let authority = trust.authority
    let pinStore = TatwoDeviceTrustPinStore(
      rootURL: storeRoot,
      authority: authority,
      localIdentity: trust.localIdentity,
      environment: environment)
    let loaded: TatwoDeviceTrustPinStoreLoadResult
    do {
      loaded = try pinStore.load(requireInitialized: !allowTestOverrides)
    } catch TatwoDeviceTrustPinStoreError.storeNotInitialized {
      throw TatwoLoopProductionRunnerError.pinStoreNotInitialized
    }

    if loaded.rejectedPinCount > 0 || loaded.rejectedRevocationCount > 0 {
      throw TatwoLoopProductionRunnerError.pinStoreRejections(
        pins: loaded.rejectedPinCount,
        revocations: loaded.rejectedRevocationCount)
    }

    let effectiveOriginAuthorityProvider: (any TatwoOriginAuthorityProviding)?
    if let currentOriginLease {
      if !allowTestOverrides, originAuthorityProvider != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "originAuthorityProvider when currentOriginLease is configured")
      }
      if allowTestOverrides, let originAuthorityProvider {
        effectiveOriginAuthorityProvider = originAuthorityProvider
      } else {
        let authorityRoot = (lockedStateRoot ?? resolvedChannelRoot)
          .appendingPathComponent("handoff-authority", isDirectory: true)
        // Production handoff leases are never backed by the RAM-only fixture
        // initializer. Restore failures propagate and fail the bootstrap closed.
        effectiveOriginAuthorityProvider =
          try TatwoHandoffLeaseTransferStoreV1(
            productionOriginLease: currentOriginLease,
            durableRootURL: authorityRoot,
            signingTrust: trust)
      }
    } else {
      // Test fixtures may retain the historical no-lease path.  Production
      // was rejected above and therefore never receives an allow-all provider.
      effectiveOriginAuthorityProvider =
        allowTestOverrides
        ? originAuthorityProvider
        : TatwoUnavailableOriginAuthorityProvider()
    }

    // E2/E3: global anti-rollback against store-generation namespace replay.
    if let antiRollback = antiRollbackForChannel, !allowTestOverrides {
      do {
        try TatwoProductionLayoutLock.enforceStoreGenerationAntiRollback(
          observed: loaded.storeGeneration,
          anchor: antiRollback)
      } catch let error as TatwoProductionLayoutError {
        throw mapLayoutError(error)
      }
    }

    let peerPins = loaded.pins.filter { $0.key != trimmedDevice }
    if peerPins.isEmpty && loaded.pins.count <= 1 {
      // Empty durable store (or only self) is fail-closed for production cross-device run.
      throw TatwoLoopProductionRunnerError.emptyPinStore
    }

    guard let originPin = loaded.pins[trimmedOrigin] ?? trust.pinnedIdentities[trimmedOrigin]
    else {
      throw TatwoLoopProductionRunnerError.originNotPinned(trimmedOrigin)
    }
    guard originPin.keyStatus == .active else {
      throw TatwoLoopProductionRunnerError.originRevoked(trimmedOrigin)
    }

    let channel = TatwoLoopJobChannel(
      rootURL: resolvedChannelRoot,
      trust: trust,
      environment: environment,
      globalAntiRollbackAnchor: antiRollbackForChannel,
      originAuthorityProvider: effectiveOriginAuthorityProvider)

    _ = lockedLayout  // sealed during resolve; roots applied above
    return TatwoLoopProductionRunnerBootstrapResult(
      trust: trust,
      channel: channel,
      deviceID: trimmedDevice,
      originDeviceID: trimmedOrigin,
      pinStoreGeneration: loaded.storeGeneration,
      peerPinCount: peerPins.count,
      lockedStateRoot: lockedStateRoot)
  }

  /// Keychain-backed production entry used by the CLI.
  public static func bootstrapWithKeychain(
    deviceID: String,
    originDeviceID: String,
    pinStoreRoot: URL? = nil,
    channelRoot: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil,
    currentOriginLease: TatwoAuthorityLeaseV1? = nil
  ) throws -> TatwoLoopProductionRunnerBootstrapResult {
    try rejectProductionTrustNamespaceOverrides(environment: environment)
    let service = try TatwoDeviceKeychainPrivateKeyStore.configuration(environment: environment)
    let store = TatwoDeviceKeychainPrivateKeyStore(service: service)
    return try bootstrap(
      deviceID: deviceID,
      originDeviceID: originDeviceID,
      privateKeyStore: store,
      pinStoreRoot: pinStoreRoot,
      channelRoot: channelRoot,
      environment: environment,
      originAuthorityProvider: originAuthorityProvider,
      currentOriginLease: currentOriginLease)
  }

  /// Production refuses env keys that relocate pin-store epoch or private-key Keychain namespaces.
  public static func rejectProductionTrustNamespaceOverrides(
    environment: [String: String]
  ) throws {
    let testMode = environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
    if testMode {
      return
    }
    let blocked = [
      TatwoDeviceTrustPinStoreKeychainEpochAnchor.serviceEnvKey,
      TatwoDeviceKeychainPrivateKeyStore.serviceEnvKey,
      TatwoLoopResultConsumeHighWaterKeychainAnchor.serviceEnvKey,
    ]
    for key in blocked {
      if let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
      {
        throw TatwoLoopProductionRunnerError.trustNamespaceOverrideForbidden(key)
      }
    }
  }

  /// Production refuses layout env that is non-canonical relative to OS-native roots.
  /// Install-anchor comparison is performed in `TatwoProductionLayoutLock.resolve`.
  public static func rejectProductionLayoutEnvOverrides(
    environment: [String: String],
    applicationSupportBase: URL? = nil
  ) throws {
    let testMode = environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
    if testMode {
      return
    }
    let appSupport = TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
      applicationSupportBase: applicationSupportBase)
    let state = TatwoProductionLayoutLock.osNativeStateRoot(
      applicationSupportBase: applicationSupportBase)
    do {
      try TatwoProductionLayoutLock.rejectNonCanonicalLayoutEnv(
        environment: environment,
        osNativeAppSupport: appSupport,
        osNativeState: state,
        sealedChannelRoot: nil)
    } catch let error as TatwoProductionLayoutError {
      throw mapLayoutError(error)
    }
  }

  private static func mapLayoutError(
    _ error: TatwoProductionLayoutError
  ) -> TatwoLoopProductionRunnerError {
    switch error {
    case let .layoutEnvOverrideForbidden(key):
      return .layoutEnvOverrideForbidden(key)
    case let .channelRootOverrideForbidden(path):
      return .channelRootOverrideForbidden(path)
    case let .productionInjectionForbidden(detail):
      return .productionInjectionForbidden(detail)
    default:
      return .layoutLock(error)
    }
  }

  /// Run the production runner until idle after a successful bootstrap.
  public static func start(
    deviceID: String,
    originDeviceID: String,
    privateKeyStore: (any TatwoDevicePrivateKeyStore)? = nil,
    pinStoreRoot: URL? = nil,
    channelRoot: URL? = nil,
    pollIntervalSec: TimeInterval = 0.05,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    engine: any TatwoLoopEngineBinding = ProcessEngineBinding.sandboxProbe,
    localRegistry: TatwoDispatchRegistry? = nil,
    allowTestOverrides: Bool = false,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil,
    currentOriginLease: TatwoAuthorityLeaseV1? = nil
  ) throws -> (bootstrap: TatwoLoopProductionRunnerBootstrapResult, receipts: [TatwoLoopJobResultReceiptV1]) {
    // F5: production start refuses caller-injected registry.
    if !allowTestOverrides, localRegistry != nil {
      throw TatwoLoopProductionRunnerError.productionInjectionForbidden("localRegistry")
    }

    let boot: TatwoLoopProductionRunnerBootstrapResult
    if let privateKeyStore {
      boot = try bootstrap(
        deviceID: deviceID,
        originDeviceID: originDeviceID,
        privateKeyStore: privateKeyStore,
        pinStoreRoot: pinStoreRoot,
        channelRoot: channelRoot,
        environment: environment,
        allowTestOverrides: allowTestOverrides,
        originAuthorityProvider: originAuthorityProvider,
        currentOriginLease: currentOriginLease)
    } else {
      if allowTestOverrides {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "allowTestOverrides requires privateKeyStore (not keychain path)")
      }
      boot = try bootstrapWithKeychain(
        deviceID: deviceID,
        originDeviceID: originDeviceID,
        pinStoreRoot: pinStoreRoot,
        channelRoot: channelRoot,
        environment: environment,
        originAuthorityProvider: originAuthorityProvider,
        currentOriginLease: currentOriginLease)
    }

    // E3: production registry uses locked state root (not STATE_DIR / OS_ROOT env).
    let registry: TatwoDispatchRegistry
    if allowTestOverrides, let localRegistry {
      registry = localRegistry
    } else if let locked = boot.lockedStateRoot {
      registry = TatwoDispatchRegistry(
        directoryURL: locked,
        originAuthorityProvider: boot.channel.originAuthorityProvider)
    } else if allowTestOverrides {
      registry =
        localRegistry
        ?? TatwoDispatchRegistry(
          directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL,
          originAuthorityProvider: boot.channel.originAuthorityProvider)
    } else {
      // Production must have locked state root from install-anchor resolve.
      throw TatwoLoopProductionRunnerError.layoutLock(
        .installAnchorRejected("missing locked state root after production bootstrap"))
    }
    // Production target start always installs a target-side readiness handler.
    // Its default observer fails closed with an explicit missing-binding receipt;
    // only explicit test overrides may omit the handler.
    let readinessHandler: TatwoRemoteDispatchReadinessTargetHandlerV1?
    let workspaceRegistry: TatwoRemoteDispatchReadinessRegistryStoreV1?
    let workspaceSkilletRootURL: URL?
    let workspaceSkillRuntimeRootURL: URL?
    if allowTestOverrides {
      readinessHandler = nil
      workspaceRegistry = nil
      workspaceSkilletRootURL = nil
      workspaceSkillRuntimeRootURL = nil
    } else {
      guard let lockedStateRoot = boot.lockedStateRoot else {
        throw TatwoLoopProductionRunnerError.layoutLock(
          .installAnchorRejected(
            "missing locked state root for target readiness registry"))
      }
      let readinessRegistry =
        TatwoRemoteDispatchReadinessRegistryStoreV1.production(
          stateRoot: lockedStateRoot,
          trust: boot.trust)
      let skilletStore = TatwoSkilletRepositoryStore(
        rootURL: lockedStateRoot.deletingLastPathComponent()
          .appendingPathComponent("skillet", isDirectory: true))
      readinessHandler = TatwoRemoteDispatchReadinessTargetHandlerV1(
        channel: boot.channel,
        observe: TatwoRemoteDispatchReadinessTargetObservationProviderV1.production(
          registryStore: readinessRegistry,
          skilletStore: skilletStore))
      workspaceRegistry = readinessRegistry
      workspaceSkilletRootURL = skilletStore.rootURL
      workspaceSkillRuntimeRootURL = lockedStateRoot.deletingLastPathComponent()
        .appendingPathComponent("skills-runtime", isDirectory: true)
    }
    let pressureAdmissionController = TatwoRunnerPressureAdmissionControllerV1.production(
      channel: boot.channel,
      trust: boot.trust,
      deviceID: boot.deviceID,
      stateRoot: boot.lockedStateRoot,
      environment: environment)
    let runner = try TatwoLoopRunnerV1(
      channel: boot.channel,
      deviceID: boot.deviceID,
      pollIntervalSec: pollIntervalSec,
      environment: environment,
      engine: engine,
      localRegistry: registry,
      readinessHandler: readinessHandler,
      workspaceRegistry: workspaceRegistry,
      workspaceSkilletRootURL: workspaceSkilletRootURL,
      workspaceSkillRuntimeRootURL: workspaceSkillRuntimeRootURL,
      workspaceAgentEngine: engine as? TatwoAgentEngineBinding ?? .production,
      pressureAdmissionController: pressureAdmissionController)
    let receipts = try runner.runUntilIdle()
    return (boot, receipts)
  }

  /// Production origin dispatch: Keychain/test identity + sealed channel + target pin required.
  ///
  /// Signs `job` with the origin private key and enqueues into the sealed channel.
  /// Target must already be present as an active durable peer pin (fail-closed).
  /// Does not weaken start-path trust hardening — reuses the same bootstrap gates.
  public static func dispatch(
    originDeviceID: String,
    targetDeviceID: String,
    job: TatwoLoopJobV1,
    privateKeyStore: (any TatwoDevicePrivateKeyStore)? = nil,
    pinStoreRoot: URL? = nil,
    channelRoot: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    localRegistry: TatwoDispatchRegistry? = nil,
    /// Test-only GoalRunStore (issued contracts). Production uses locked state root.
    localGoalRunStore: TatwoGoalRunStore? = nil,
    allowTestOverrides: Bool = false,
    installAnchorStore: (any TatwoProductionInstallAnchorStore)? = nil,
    globalAntiRollbackAnchor: (any TatwoLoopGlobalAntiRollbackAnchor)? = nil,
    applicationSupportBase: URL? = nil,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil,
    currentOriginLease: TatwoAuthorityLeaseV1? = nil,
    /// Target-signed readiness advertisement used to bind production jobs.
    /// The origin may transport this artifact, but cannot mint or edit it.
    targetReadinessManifest: TatwoRemoteDispatchReadinessManifestV1? = nil,
    /// Test-only target readiness seam. Production always uses the signed
    /// file-channel provider and refuses caller injection.
    testReadinessProvider: (any TatwoRemoteDispatchReadinessProviding)? = nil
  ) throws -> TatwoLoopProductionDispatchResult {
    let trimmedOrigin = originDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedTarget = targetDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOrigin.isEmpty, TatwoLoopPathComponent.isValid(trimmedOrigin) else {
      throw TatwoLoopProductionRunnerError.missingOriginDeviceID
    }
    guard !trimmedTarget.isEmpty, TatwoLoopPathComponent.isValid(trimmedTarget) else {
      throw TatwoLoopProductionRunnerError.missingTargetDeviceID
    }
    guard trimmedOrigin != trimmedTarget else {
      throw TatwoLoopProductionRunnerError.jobDeviceBindingMismatch(
        "origin and target device IDs must differ")
    }
    guard job.originDeviceID == trimmedOrigin else {
      throw TatwoLoopProductionRunnerError.jobDeviceBindingMismatch(
        "job.originDeviceID \(job.originDeviceID) != \(trimmedOrigin)")
    }
    guard job.targetDeviceID == trimmedTarget else {
      throw TatwoLoopProductionRunnerError.jobDeviceBindingMismatch(
        "job.targetDeviceID \(job.targetDeviceID) != \(trimmedTarget)")
    }
    try job.validate()

    // F5: production dispatch refuses caller-injected registry / layout / goal store.
    if !allowTestOverrides {
      if localRegistry != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden("localRegistry")
      }
      if localGoalRunStore != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden("localGoalRunStore")
      }
      if installAnchorStore != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "installAnchorStore")
      }
      if globalAntiRollbackAnchor != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "globalAntiRollbackAnchor")
      }
      if applicationSupportBase != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "applicationSupportBase")
      }
      if testReadinessProvider != nil {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "testReadinessProvider")
      }
    }

    // Bootstrap as the origin host. Self-as-origin pin is satisfied via local identity;
    // empty peer store still fails closed. Target pin is enforced below.
    let boot: TatwoLoopProductionRunnerBootstrapResult
    if let privateKeyStore {
      boot = try bootstrap(
        deviceID: trimmedOrigin,
        originDeviceID: trimmedOrigin,
        privateKeyStore: privateKeyStore,
        pinStoreRoot: pinStoreRoot,
        channelRoot: channelRoot,
        environment: environment,
        allowTestOverrides: allowTestOverrides,
        installAnchorStore: installAnchorStore,
        globalAntiRollbackAnchor: globalAntiRollbackAnchor,
        applicationSupportBase: applicationSupportBase,
        originAuthorityProvider: originAuthorityProvider,
        currentOriginLease: currentOriginLease)
    } else {
      if allowTestOverrides {
        throw TatwoLoopProductionRunnerError.productionInjectionForbidden(
          "allowTestOverrides requires privateKeyStore (not keychain path)")
      }
      boot = try bootstrapWithKeychain(
        deviceID: trimmedOrigin,
        originDeviceID: trimmedOrigin,
        pinStoreRoot: pinStoreRoot,
        channelRoot: channelRoot,
        environment: environment,
        originAuthorityProvider: originAuthorityProvider,
        currentOriginLease: currentOriginLease)
    }

    guard let targetPin = boot.trust.pinnedIdentities[trimmedTarget] else {
      throw TatwoLoopProductionRunnerError.targetNotPinned(trimmedTarget)
    }
    guard targetPin.keyStatus == .active else {
      throw TatwoLoopProductionRunnerError.targetRevoked(trimmedTarget)
    }
    let requiresRemoteAgentGate: Bool
    switch job.payload {
    case .tatwoLoop:
      requiresRemoteAgentGate = true
    case .shellSafe:
      // Shell-safe commands are the bounded, non-agent path. They remain
      // origin-signed, pin-bound, and GoalRun-gated, but do not borrow a Chat
      // session or require target readiness evidence.
      requiresRemoteAgentGate = false
    }
    if !allowTestOverrides, requiresRemoteAgentGate {
      guard let targetReadinessManifest else {
        throw TatwoLoopProductionRunnerError.workOSContractGate(
          "target-signed readiness manifest is required")
      }
      do {
        try targetReadinessManifest.validateCurrentProductionAgentBinding(
          for: job,
          trust: boot.trust,
          environment: environment)
      } catch let error as TatwoRemoteDispatchReadinessRegistryError {
        throw TatwoLoopProductionRunnerError.workOSContractGate(
          error.errorDescription ?? String(describing: error))
      }
    }

    let registry: TatwoDispatchRegistry
    let goalStore: TatwoGoalRunStore
    if allowTestOverrides, let localRegistry {
      registry = localRegistry
      // Prefer explicit store; otherwise share registry directory so tests stay colocated.
      goalStore =
        localGoalRunStore
        ?? TatwoGoalRunStore(directoryURL: localRegistry.directoryURL)
    } else if let locked = boot.lockedStateRoot {
      registry = TatwoDispatchRegistry(
        directoryURL: locked,
        originAuthorityProvider: boot.channel.originAuthorityProvider)
      goalStore = localGoalRunStore ?? TatwoGoalRunStore(directoryURL: locked)
    } else if allowTestOverrides {
      registry =
        localRegistry
        ?? TatwoDispatchRegistry(
          directoryURL: TatwoGoalRunStore.default(environment: environment).directoryURL,
          originAuthorityProvider: boot.channel.originAuthorityProvider)
      goalStore =
        localGoalRunStore
        ?? TatwoGoalRunStore(directoryURL: registry.directoryURL)
    } else {
      throw TatwoLoopProductionRunnerError.layoutLock(
        .installAnchorRejected("missing locked state root after production dispatch bootstrap"))
    }
    let authorizationStateRoot = boot.lockedStateRoot ?? registry.directoryURL
    let remoteBorrowAuthorizationStore: TatwoRemoteBorrowAuthorizationStore? =
      requiresRemoteAgentGate
      ? TatwoRemoteBorrowAuthorizationStore.production(
        stateRoot: authorizationStateRoot)
      : nil

    // Tests disable the host memory gate so unit fixtures stay deterministic.
    let memoryGate: MemoryPressureGate
    if allowTestOverrides {
      memoryGate = MemoryPressureGate(
        minFreePercent: 0,
        freePercentProvider: { 100 },
        journalDirectoryURL: registry.directoryURL)
    } else {
      memoryGate = MemoryPressureGate.default(
        journalDirectoryURL: registry.directoryURL)
    }
    // Production GoalRun dispatch always uses the signed target readiness
    // transport. The challenge is derived from this attempt's job binding;
    // callers cannot inject a process-global/static nonce.
    let readinessRequirements: TatwoRemoteDispatchReadinessRequirementsV1?
    let readinessProvider: (any TatwoRemoteDispatchReadinessProviding)?
    if requiresRemoteAgentGate {
      do {
        readinessRequirements = try TatwoRemoteDispatchReadinessRequirementsV1(job: job)
      } catch let error as TatwoRemoteDispatchReadinessError {
        throw TatwoLoopProductionRunnerError.workOSContractGate(
          error.errorDescription ?? String(describing: error))
      }
      readinessProvider =
        testReadinessProvider
        ?? TatwoRemoteDispatchReadinessChannelProviderV1(channel: boot.channel)
    } else {
      readinessRequirements = nil
      readinessProvider = nil
    }
    // K1: unified prepare gate inside origin.enqueue via beginRemote
    // (authorize + GoalRun re-check + registry reservation under one lifecycle lock).
    // Never authorize then call bare registry.beginRemote.
    let origin = TatwoLoopOriginProjectorV1(
      channel: boot.channel,
      registry: registry,
      originDeviceID: trimmedOrigin,
      memoryGate: memoryGate,
      goalStore: goalStore,
      remoteBorrowAuthorizationStore: remoteBorrowAuthorizationStore,
      verifiedTargetIdentity: targetPin,
      remoteReadinessProvider: readinessProvider,
      remoteReadinessRequirements: readinessRequirements,
      environment: environment,
      originAuthorityProvider: boot.channel.originAuthorityProvider)
    // K2: origin.enqueue is prepare(lifecycle) then commit(channel+commit-marker).
    let record: TatwoDispatchRecord
    do {
      record = try origin.enqueue(job)
    } catch let error as TatwoGoalRunDispatchLifecycleError {
      throw TatwoLoopProductionRunnerError.workOSContractGate(
        error.errorDescription ?? String(describing: error))
    } catch let error as TatwoGoalRunStoreError {
      throw TatwoLoopProductionRunnerError.workOSContractGate(
        error.errorDescription ?? String(describing: error))
    }
    let digest = try job.canonicalDigest()
    return TatwoLoopProductionDispatchResult(
      bootstrap: boot,
      job: job,
      jobCanonicalDigest: digest,
      channelRoot: boot.channel.rootURL.path,
      dispatchRecordID: record.id)
  }
}
