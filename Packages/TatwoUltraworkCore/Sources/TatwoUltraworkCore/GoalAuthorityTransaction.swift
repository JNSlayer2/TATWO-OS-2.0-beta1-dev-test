import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum TatwoSessionAuthorityLockBootstrapDispositionV1:
  String, Codable, Sendable, Equatable
{
  case created
  case createdGlobalAndContractLifecycle =
    "created_global_and_contract_lifecycle"
  case createdContractLifecycle = "created_contract_lifecycle"
  case validatedExisting = "validated_existing"
}

public struct TatwoSessionAuthorityLockPreflightV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let canonicalGoalStoreRootPath: String
  public let contractID: String
  public let rootDeviceID: UInt64
  public let rootInode: UInt64
  public let presentArtifactNames: [String]
  public let artifactFingerprints: [String]

  public init(
    canonicalGoalStoreRootPath: String,
    contractID: String,
    rootDeviceID: UInt64,
    rootInode: UInt64,
    presentArtifactNames: [String],
    artifactFingerprints: [String]
  ) {
    schema = "TatwoSessionAuthorityLockPreflightV1"
    self.canonicalGoalStoreRootPath = canonicalGoalStoreRootPath
    self.contractID = contractID
    self.rootDeviceID = rootDeviceID
    self.rootInode = rootInode
    self.presentArtifactNames = presentArtifactNames
    self.artifactFingerprints = artifactFingerprints
  }
}

public struct TatwoSessionAuthorityLockBootstrapResultV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let disposition: TatwoSessionAuthorityLockBootstrapDispositionV1
  public let canonicalGoalStoreRootPath: String
  public let contractID: String
  public let globalInitializationReceiptSHA256: String
  public let lifecycleInitializationReceiptSHA256: String
  public let validatedPreflight:
    TatwoSessionAuthorityLockPreflightV1
  public let validatedAt: Date

  public init(
    disposition: TatwoSessionAuthorityLockBootstrapDispositionV1,
    canonicalGoalStoreRootPath: String,
    contractID: String,
    globalInitializationReceiptSHA256: String,
    lifecycleInitializationReceiptSHA256: String,
    validatedPreflight: TatwoSessionAuthorityLockPreflightV1,
    validatedAt: Date
  ) {
    schema = "TatwoSessionAuthorityLockBootstrapResultV1"
    self.disposition = disposition
    self.canonicalGoalStoreRootPath = canonicalGoalStoreRootPath
    self.contractID = contractID
    self.globalInitializationReceiptSHA256 =
      globalInitializationReceiptSHA256
    self.lifecycleInitializationReceiptSHA256 =
      lifecycleInitializationReceiptSHA256
    self.validatedPreflight = validatedPreflight
    self.validatedAt = Date(
      timeIntervalSince1970:
        validatedAt.timeIntervalSince1970.rounded(.down))
  }
}

public enum TatwoSessionAuthorityLockBootstrapError:
  Error, LocalizedError, Sendable, Equatable
{
  case mixedOrPartialState([String])
  case storeRootOpenFailed(path: String, code: Int32)
  case invalidStoreRoot(path: String)
  case bootstrapFenceAcquireFailed(path: String, code: Int32)
  case bootstrapFenceTimedOut(path: String, waited: TimeInterval)
  case preflightChanged
  case postBootstrapReadbackMismatch

  public var errorDescription: String? {
    switch self {
    case .mixedOrPartialState(let presentArtifacts):
      return
        "Authority-lock bootstrap requires all artifacts absent, all complete, "
        + "or the exact supported legacy lifecycle-directory migration state; "
        + "refusing mixed/partial state: "
        + presentArtifacts.joined(separator: ",")
    case let .storeRootOpenFailed(path, code):
      return "Could not open existing authority store root \(path): errno \(code)"
    case .invalidStoreRoot(let path):
      return "Authority bootstrap root identity is invalid or changed: \(path)"
    case let .bootstrapFenceAcquireFailed(path, code):
      return "Could not acquire root-scoped authority bootstrap fence \(path): errno \(code)"
    case let .bootstrapFenceTimedOut(path, waited):
      return "Timed out acquiring root-scoped authority bootstrap fence \(path) after \(waited) seconds"
    case .preflightChanged:
      return "Authority bootstrap preflight changed after human confirmation; refusing stale confirmation."
    case .postBootstrapReadbackMismatch:
      return "Authority-lock bootstrap post-create readback did not validate as complete existing state."
    }
  }
}

/// The one public, synchronous, operator-invoked authority-lock bootstrap.
///
/// It preflights the complete global/lifecycle artifact set before creating
/// anything. All absent means create-only initialization; all complete means
/// existing-only validation. An upgraded legacy state root may contain only
/// the already-valid lifecycle directory for a new contract; that exact shape
/// receives an explicit global-plus-contract migration without changing any
/// unrelated legacy artifacts. Every other mixed, partial, or corrupt state
/// fails closed without repair. Ordinary Goal/session writers never call this
/// primitive.
public enum TatwoSessionAuthorityLockBootstrap {
  /// Read-only UI/advisory snapshot. It is not authority: the mutating
  /// primitive recaptures and compares it while holding the root directory
  /// bootstrap fence.
  public static func preflightSnapshot(
    goalStoreRoot: URL,
    contractID: String
  ) throws -> TatwoSessionAuthorityLockPreflightV1 {
    try capturePreflight(
      root: canonicalBootstrapRoot(goalStoreRoot),
      contractID: contractID)
  }

  public static func bootstrapExplicitly(
    goalStoreRoot: URL,
    contractID: String,
    expectedPreflight:
      TatwoSessionAuthorityLockPreflightV1? = nil,
    createdAt: Date = Date()
  ) throws -> TatwoSessionAuthorityLockBootstrapResultV1 {
    let root = canonicalBootstrapRoot(goalStoreRoot)
    // This is the one explicitly operator-invoked provisioning boundary. A
    // first-run App/MCP state root may not exist yet; provision only that
    // container here before the create-only lock bootstrap. Ordinary
    // Goal/session writers still use existing-only lock acquisition and never
    // call this helper, so a missing authority lock remains fail closed.
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true)
    return try withRootBootstrapFence(root: root) {
      let authoritativePreflight = try capturePreflight(
        root: root,
        contractID: contractID)
      if let expectedPreflight,
        expectedPreflight != authoritativePreflight
      {
        throw TatwoSessionAuthorityLockBootstrapError.preflightChanged
      }
      let presentArtifacts =
        authoritativePreflight.presentArtifactNames
      let expectedNames = try expectedBootstrapArtifactNames(
        root: root,
        contractID: contractID)
      let expectedNameSet = Set(expectedNames)
      let globalNames = Set(expectedNames.prefix(2))
      let lifecycleDirectoryName = expectedNames[2]
      let contractLifecycleNames = Set(expectedNames.dropFirst(3))
      let present = Set(presentArtifacts)
      let allAbsent = present.isEmpty
      let allComplete = present == expectedNameSet
      let legacyLifecycleDirectoryOnly =
        present == Set([lifecycleDirectoryName])
      let globalComplete =
        globalNames.isSubset(of: present)
        && present.intersection(globalNames).count == globalNames.count
      let contractLifecycleAbsent =
        present.intersection(contractLifecycleNames).isEmpty
      let globalCompleteContractLifecycleAbsent =
        globalComplete
        && contractLifecycleAbsent
        && present.isSubset(
          of: globalNames.union([lifecycleDirectoryName]))
      guard
        allAbsent || allComplete || legacyLifecycleDirectoryOnly
          || globalCompleteContractLifecycleAbsent
      else {
        throw TatwoSessionAuthorityLockBootstrapError
          .mixedOrPartialState(presentArtifacts)
      }

      let disposition:
        TatwoSessionAuthorityLockBootstrapDispositionV1
      if allAbsent {
        _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
          goalStoreRoot: root,
          createdAt: createdAt)
        _ = try TatwoGoalStoreLifecycleLock.initializeCreateOnly(
          goalStoreRoot: root,
          contractID: contractID,
          createdAt: createdAt)
        disposition = .created
      } else if legacyLifecycleDirectoryOnly {
        _ = try TatwoGoalStoreGlobalLock.initializeCreateOnly(
          goalStoreRoot: root,
          createdAt: createdAt)
        _ = try TatwoGoalStoreLifecycleLock.initializeContractCreateOnly(
          goalStoreRoot: root,
          contractID: contractID,
          createdAt: createdAt)
        disposition = .createdGlobalAndContractLifecycle
      } else if globalCompleteContractLifecycleAbsent {
        _ = try TatwoGoalStoreLifecycleLock.initializeContractCreateOnly(
          goalStoreRoot: root,
          contractID: contractID,
          createdAt: createdAt)
        disposition = .createdContractLifecycle
      } else {
        disposition = .validatedExisting
      }

      _ = try TatwoGoalStoreGlobalLock.withExclusiveLock(
        goalStoreRoot: root
      ) {
        true
      }
      _ = try TatwoGoalStoreLifecycleLock.withExclusiveLock(
        goalStoreRoot: root,
        contractID: contractID
      ) {
        true
      }
      let globalReceiptURL =
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      let lifecycleReceiptURL =
        try TatwoGoalStoreLifecycleLock.initializationReceiptURL(
          forGoalStoreRoot: root,
          contractID: contractID)
      let globalReceiptData = try Data(contentsOf: globalReceiptURL)
      let lifecycleReceiptData = try Data(
        contentsOf: lifecycleReceiptURL)
      let validatedPreflight = try capturePreflight(
        root: root,
        contractID: contractID)
      return TatwoSessionAuthorityLockBootstrapResultV1(
        disposition: disposition,
        canonicalGoalStoreRootPath:
          validatedPreflight.canonicalGoalStoreRootPath,
        contractID: contractID,
        globalInitializationReceiptSHA256:
          "sha256:"
          + SHA256.hash(data: globalReceiptData)
            .map { String(format: "%02x", $0) }.joined(),
        lifecycleInitializationReceiptSHA256:
          "sha256:"
          + SHA256.hash(data: lifecycleReceiptData)
            .map { String(format: "%02x", $0) }.joined(),
        validatedPreflight: validatedPreflight,
        validatedAt: createdAt)
    }
  }

  private static func withRootBootstrapFence<T>(
    root: URL,
    _ body: () throws -> T
  ) throws -> T {
    let descriptor = open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw TatwoSessionAuthorityLockBootstrapError.storeRootOpenFailed(
        path: root.path,
        code: errno)
    }
    defer { _ = close(descriptor) }
    try validateRootIdentity(root, descriptor: descriptor)
    let lockStartedAt = ProcessInfo.processInfo.systemUptime
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      if code == EINTR { continue }
      if code == EWOULDBLOCK || code == EAGAIN {
        let waited = ProcessInfo.processInfo.systemUptime - lockStartedAt
        guard waited < 8 else {
          throw TatwoSessionAuthorityLockBootstrapError
            .bootstrapFenceTimedOut(path: root.path, waited: waited)
        }
        Thread.sleep(forTimeInterval: 0.02)
        continue
      }
      throw TatwoSessionAuthorityLockBootstrapError
        .bootstrapFenceAcquireFailed(path: root.path, code: code)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    try validateRootIdentity(root, descriptor: descriptor)
    return try body()
  }

  private static func capturePreflight(
    root: URL,
    contractID: String
  ) throws -> TatwoSessionAuthorityLockPreflightV1 {
    let descriptor = open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw TatwoSessionAuthorityLockBootstrapError.storeRootOpenFailed(
        path: root.path,
        code: errno)
    }
    defer { _ = close(descriptor) }
    try validateRootIdentity(root, descriptor: descriptor)
    var rootStatus = stat()
    guard fstat(descriptor, &rootStatus) == 0 else {
      throw TatwoSessionAuthorityLockBootstrapError.invalidStoreRoot(
        path: root.path)
    }
    let lifecycleLockURL =
      try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root,
        contractID: contractID)
    let lifecycleReceiptURL =
      try TatwoGoalStoreLifecycleLock.initializationReceiptURL(
        forGoalStoreRoot: root,
        contractID: contractID)
      let artifacts: [(String, URL)] = [
      (
        TatwoGoalStoreGlobalLock.lockFileName,
        TatwoGoalStoreGlobalLock.lockURL(
          forGoalStoreRoot: root)
      ),
      (
        TatwoGoalStoreGlobalLock.initializationReceiptFileName,
        TatwoGoalStoreGlobalLock.initializationReceiptURL(
          forGoalStoreRoot: root)
      ),
      (
        TatwoGoalStoreLifecycleLock.lifecycleDirectoryName,
        TatwoGoalStoreLifecycleLock.lifecycleDirectoryURL(
          forGoalStoreRoot: root)
      ),
      (lifecycleLockURL.lastPathComponent, lifecycleLockURL),
      (lifecycleReceiptURL.lastPathComponent, lifecycleReceiptURL),
    ]
    var present: [String] = []
    var fingerprints: [String] = []
    for (name, url) in artifacts {
      var artifactStatus = stat()
      if lstat(url.path, &artifactStatus) == 0 {
        present.append(name)
        var fingerprint =
          "\(name):\(UInt64(artifactStatus.st_dev)):"
          + "\(UInt64(artifactStatus.st_ino)):"
          + "\(UInt32(artifactStatus.st_mode)):"
          + "\(UInt32(artifactStatus.st_uid)):"
          + "\(UInt32(artifactStatus.st_gid)):"
          + "\(UInt64(artifactStatus.st_nlink)):"
          + "\(UInt64(artifactStatus.st_size))"
        if artifactStatus.st_mode & S_IFMT == S_IFREG {
          let data = try Data(contentsOf: url)
          fingerprint +=
            ":"
            + SHA256.hash(data: data)
              .map { String(format: "%02x", $0) }.joined()
        }
        fingerprints.append(fingerprint)
      } else if errno == ENOENT {
        fingerprints.append("\(name):absent")
      } else {
        throw TatwoSessionAuthorityLockBootstrapError.invalidStoreRoot(
          path: root.path)
      }
    }
    return TatwoSessionAuthorityLockPreflightV1(
      canonicalGoalStoreRootPath: root.path,
      contractID: contractID,
      rootDeviceID: UInt64(rootStatus.st_dev),
      rootInode: UInt64(rootStatus.st_ino),
      presentArtifactNames: present,
      artifactFingerprints: fingerprints)
  }

  private static func expectedBootstrapArtifactNames(
    root: URL,
    contractID: String
  ) throws -> [String] {
    let lifecycleLockURL =
      try TatwoGoalStoreLifecycleLock.lockURL(
        forGoalStoreRoot: root,
        contractID: contractID)
    let lifecycleReceiptURL =
      try TatwoGoalStoreLifecycleLock.initializationReceiptURL(
        forGoalStoreRoot: root,
        contractID: contractID)
    return [
      TatwoGoalStoreGlobalLock.lockFileName,
      TatwoGoalStoreGlobalLock.initializationReceiptFileName,
      TatwoGoalStoreLifecycleLock.lifecycleDirectoryName,
      lifecycleLockURL.lastPathComponent,
      lifecycleReceiptURL.lastPathComponent,
    ]
  }

  private static func canonicalBootstrapRoot(_ root: URL) -> URL {
    root.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func validateRootIdentity(
    _ root: URL,
    descriptor: Int32
  ) throws {
    var opened = stat()
    var pathStatus = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      lstat(root.path, &pathStatus) == 0,
      pathStatus.st_mode & S_IFMT == S_IFDIR,
      opened.st_dev == pathStatus.st_dev,
      opened.st_ino == pathStatus.st_ino
    else {
      throw TatwoSessionAuthorityLockBootstrapError.invalidStoreRoot(
        path: root.path)
    }
  }
}

public struct TatwoGoalAuthorityTransactionResultV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let transactionID: String
  public let authorityPlanSHA256: String
  public let manifestSHA256: String
  public let attachment: TatwoSessionAttachmentV1
  public let manifest: TatwoExecutionManifestV1
  public let recovered: Bool
  public let pointerHandoffFromSessionID: String?

  public init(
    schema: String = "TatwoGoalAuthorityTransactionResultV1",
    transactionID: String,
    authorityPlanSHA256: String,
    manifestSHA256: String,
    attachment: TatwoSessionAttachmentV1,
    manifest: TatwoExecutionManifestV1,
    recovered: Bool,
    pointerHandoffFromSessionID: String? = nil
  ) {
    self.schema = schema
    self.transactionID = transactionID
    self.authorityPlanSHA256 = authorityPlanSHA256
    self.manifestSHA256 = manifestSHA256
    self.attachment = attachment
    self.manifest = manifest
    self.recovered = recovered
    self.pointerHandoffFromSessionID = pointerHandoffFromSessionID
  }
}

public enum TatwoGoalAuthorityTransactionError:
  Error, LocalizedError, Sendable, Equatable
{
  case stateRootMismatch
  case stateRootIdentityChanged
  case ownerRequired
  case preexistingAuthorityArtifact(String)
  case planMismatch(String)
  case compareAndSwapMismatch(String)
  case artifactCorrupt(String)
  case quarantined(String)
  case exactReadbackMismatch(String)
  case interruptedAfterStage(String)

  public var errorDescription: String? {
    switch self {
    case .stateRootMismatch:
      return "Goal, session, and dispatch stores must share one canonical state root."
    case .stateRootIdentityChanged:
      return "Canonical Goal authority state-root identity changed before mutation."
    case .ownerRequired:
      return "Formal Goal authority begin requires a provider session/thread owner."
    case .preexistingAuthorityArtifact(let artifact):
      return "Authority transaction preflight found a preexisting artifact: \(artifact)."
    case .planMismatch(let field):
      return "Authority transaction plan mismatch: \(field)."
    case .compareAndSwapMismatch(let field):
      return "Authority transaction compare-and-swap mismatch: \(field)."
    case .artifactCorrupt(let artifact):
      return "Authority transaction artifact is corrupt: \(artifact)."
    case .quarantined(let reason):
      return "Authority transaction is quarantined: \(reason)."
    case .exactReadbackMismatch(let artifact):
      return "Authority transaction exact readback mismatch: \(artifact)."
    case .interruptedAfterStage(let stage):
      return "Authority transaction interrupted after durable stage \(stage)."
    }
  }
}

struct TatwoGoalAuthorityPlanBindingV1: Codable, Sendable, Equatable {
  let schema = "TatwoGoalAuthorityPlanBindingV1"
  let contract: TatwoWorkOSContractV1
  let owner: TatwoCanonicalSessionOwnerV1
  /// Manifest time is event metadata, not authority identity. Binding the
  /// complete entries keeps route/identity/subtask/status authority stable
  /// across a restart whose wall clock has advanced.
  let executionManifestEntries: [TatwoExecutionManifestEntry]
  let pointerGeneration: UInt64
}

struct TatwoGoalAuthorityIntentV1: Codable, Sendable, Equatable {
  let schema: String
  let transactionID: String
  let authorityPlanSHA256: String
  let goalRecordSHA256: String
  let manifestSHA256: String
  let expectedPointerState: String
  let contract: TatwoWorkOSContractV1
  let owner: TatwoCanonicalSessionOwnerV1
  let goalRecord: TatwoStoredGoalRun
  let executionManifest: TatwoExecutionManifestV1
  let pointer: TatwoSessionPointer
  let preparedAt: Date

  init(
    transactionID: String,
    authorityPlanSHA256: String,
    goalRecordSHA256: String,
    manifestSHA256: String,
    contract: TatwoWorkOSContractV1,
    owner: TatwoCanonicalSessionOwnerV1,
    goalRecord: TatwoStoredGoalRun,
    executionManifest: TatwoExecutionManifestV1,
    pointer: TatwoSessionPointer,
    preparedAt: Date
  ) {
    schema = "TatwoGoalAuthorityIntentV1"
    self.transactionID = transactionID
    self.authorityPlanSHA256 = authorityPlanSHA256
    self.goalRecordSHA256 = goalRecordSHA256
    self.manifestSHA256 = manifestSHA256
    expectedPointerState = "absent"
    self.contract = contract
    self.owner = owner
    self.goalRecord = goalRecord
    self.executionManifest = executionManifest
    self.pointer = pointer
    self.preparedAt = preparedAt
  }
}

enum TatwoGoalAuthorityStageV1: String, Codable, Sendable, Equatable {
  case goalMaterialized = "goal_materialized"
  case manifestMaterialized = "manifest_materialized"
  case pointerCommitted = "pointer_committed"
  case committed
  case quarantined
}

struct TatwoGoalAuthorityStageReceiptV1:
  Codable, Sendable, Equatable
{
  let schema: String
  let transactionID: String
  let authorityPlanSHA256: String
  let stage: TatwoGoalAuthorityStageV1
  let artifactSHA256: String
  let reason: String?
  let pointerHandoffFromSessionID: String?
  let recordedAt: Date

  init(
    transactionID: String,
    authorityPlanSHA256: String,
    stage: TatwoGoalAuthorityStageV1,
    artifactSHA256: String,
    reason: String? = nil,
    pointerHandoffFromSessionID: String? = nil,
    recordedAt: Date
  ) {
    schema = "TatwoGoalAuthorityStageReceiptV1"
    self.transactionID = transactionID
    self.authorityPlanSHA256 = authorityPlanSHA256
    self.stage = stage
    self.artifactSHA256 = artifactSHA256
    self.reason = reason
    self.pointerHandoffFromSessionID =
      pointerHandoffFromSessionID
    self.recordedAt = Date(
      timeIntervalSince1970:
        recordedAt.timeIntervalSince1970.rounded(.down))
  }
}

/// Canonical synchronous writer for a new current Goal authority plan.
///
/// Lock order is the repository's enforced order:
/// lifecycle -> store-global -> one logical record scope. The critical section
/// contains only bounded local file I/O and pure validation; it performs no
/// await, network, Keychain access, helper launch, or caller callback.
public struct TatwoGoalAuthorityTransaction: Sendable {
  public let sessionStore: TatwoSessionStore
  public let goalStore: TatwoGoalRunStore
  public let dispatchRegistry: TatwoDispatchRegistry

  public init(
    sessionStore: TatwoSessionStore,
    goalStore: TatwoGoalRunStore,
    dispatchRegistry: TatwoDispatchRegistry
  ) {
    self.sessionStore = sessionStore
    self.goalStore = goalStore
    self.dispatchRegistry = dispatchRegistry
  }

  public func begin(
    contract: TatwoWorkOSContractV1,
    owner: TatwoCanonicalSessionOwnerV1,
    scenarioBook: TatwoScenarioConfigBookV1 =
      TatwoScenarioConfigDefaults.book
  ) throws -> TatwoGoalAuthorityTransactionResultV1 {
    try begin(
      contract: contract,
      owner: owner,
      scenarioBook: scenarioBook,
      now: Date(),
      stopAfterStageForTesting: nil)
  }

  func begin(
    contract: TatwoWorkOSContractV1,
    owner: TatwoCanonicalSessionOwnerV1,
    scenarioBook: TatwoScenarioConfigBookV1 =
      TatwoScenarioConfigDefaults.book,
    now: Date,
    stopAfterStageForTesting: TatwoGoalAuthorityStageV1?
  ) throws -> TatwoGoalAuthorityTransactionResultV1 {
    let root = goalStore.directoryURL.standardizedFileURL
      .resolvingSymlinksInPath()
    guard
      sessionStore.directoryURL.standardizedFileURL
        .resolvingSymlinksInPath() == root,
      dispatchRegistry.directoryURL.standardizedFileURL
        .resolvingSymlinksInPath() == root
    else {
      throw TatwoGoalAuthorityTransactionError.stateRootMismatch
    }
    guard !owner.provider.isEmpty,
      !owner.externalProviderID.isEmpty,
      !owner.workspacePath.isEmpty
    else {
      throw TatwoGoalAuthorityTransactionError.ownerRequired
    }
    let preparedAt = Date(
      timeIntervalSince1970:
        now.timeIntervalSince1970.rounded(.down))
    let manifest = TatwoExecutionManifestFactory.make(
      contract: contract,
      generatedAt: preparedAt)
    try manifest.validateAuthorityBinding(contract: contract)
    let manifestSHA256 = try manifest.canonicalSHA256()
    let plan = TatwoGoalAuthorityPlanBindingV1(
      contract: contract,
      owner: owner,
      executionManifestEntries: manifest.entries,
      pointerGeneration: 1)
    let authorityPlanSHA256 = try Self.canonicalSHA256(plan)
    let transactionID =
      "goal-authority-"
      + String(authorityPlanSHA256.dropFirst("sha256:".count).prefix(40))
    let goalRecord = Self.initialGoalRecord(
      contract: contract,
      preparedAt: preparedAt)
    let goalRecordSHA256 = try Self.canonicalSHA256(goalRecord)
    let pointer = TatwoSessionPointer(
      schema: "TatwoSessionAuthorityPointerV3",
      contractID: contract.contractID,
      goalID: contract.goalID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      startedAt: preparedAt,
      ownerBinding: owner.binding(
        contractID: contract.contractID,
        goalID: contract.goalID),
      generation: 1,
      authorityTransactionID: transactionID,
      authorityPlanSHA256: authorityPlanSHA256,
      executionManifestSHA256: manifestSHA256)
    let proposedIntent = TatwoGoalAuthorityIntentV1(
      transactionID: transactionID,
      authorityPlanSHA256: authorityPlanSHA256,
      goalRecordSHA256: goalRecordSHA256,
      manifestSHA256: manifestSHA256,
      contract: contract,
      owner: owner,
      goalRecord: goalRecord,
      executionManifest: manifest,
      pointer: pointer,
      preparedAt: preparedAt)
    // Acquire the already-provisioned authority locks before consulting the
    // pointer. `authorityPointerData()` itself uses a pointer-side file lock,
    // so reading it first would create an incidental lock artifact in a root
    // whose authority locks are absent. Within beginLocked, a fresh begin
    // still rejects any pointer as `preexistingAuthorityArtifact`, while a
    // prepared transaction compares its persisted intent and quarantines a
    // foreign pointer instead of adopting it.
    let pinnedRootPreflight =
      try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
        goalStoreRoot: root,
        contractID: contract.contractID)

    return try TatwoGoalStoreLockOrder.withOperation(mode: .standard) {
      try TatwoGoalStoreLifecycleLock.withExclusiveLock(
        goalStoreRoot: root,
        contractID: contract.contractID
      ) {
        try TatwoGoalStoreGlobalLock.withExclusiveLock(
          goalStoreRoot: root
        ) {
          try TatwoGoalStoreLockOrder.withRecordScope(
            recordID: "goal-authority:\(contract.contractID)"
          ) {
            let lockedRootPreflight =
              try TatwoSessionAuthorityLockBootstrap.preflightSnapshot(
                goalStoreRoot: root,
                contractID: contract.contractID)
            guard lockedRootPreflight == pinnedRootPreflight else {
              throw TatwoGoalAuthorityTransactionError
                .stateRootIdentityChanged
            }
            return try beginLocked(
              proposedIntent: proposedIntent,
              scenarioBook: scenarioBook,
              stopAfterStageForTesting: stopAfterStageForTesting)
          }
        }
      }
    }
  }

  private func beginLocked(
    proposedIntent: TatwoGoalAuthorityIntentV1,
    scenarioBook: TatwoScenarioConfigBookV1,
    stopAfterStageForTesting: TatwoGoalAuthorityStageV1?
  ) throws -> TatwoGoalAuthorityTransactionResultV1 {
    let intentURL = transactionArtifactURL(
      transactionID: proposedIntent.transactionID,
      name: "00-intent.json")
    if let quarantine = try stageReceipt(
      .quarantined,
      intent: proposedIntent)
    {
      throw TatwoGoalAuthorityTransactionError.quarantined(
        quarantine.reason ?? "unspecified")
    }
    let intent: TatwoGoalAuthorityIntentV1
    let recovered: Bool
    var pointerHandoff: PointerHandoff?
    if FileManager.default.fileExists(atPath: intentURL.path) {
      recovered = true
      do {
        let decoded = try read(
          TatwoGoalAuthorityIntentV1.self,
          from: intentURL,
          artifactName: "intent")
        guard decoded.transactionID == proposedIntent.transactionID,
          decoded.authorityPlanSHA256
            == proposedIntent.authorityPlanSHA256,
          decoded.contract == proposedIntent.contract,
          decoded.owner == proposedIntent.owner,
          decoded.executionManifest.entries
            == proposedIntent.executionManifest.entries,
          decoded.pointer.generation
            == proposedIntent.pointer.generation,
          decoded.pointer.authorityTransactionID
            == proposedIntent.pointer.authorityTransactionID,
          decoded.pointer.authorityPlanSHA256
            == proposedIntent.pointer.authorityPlanSHA256,
          try Data(contentsOf: intentURL)
            == Self.canonicalData(decoded)
        else {
          throw TatwoGoalAuthorityTransactionError.planMismatch(
            "prepared_intent")
        }
        try Self.validateIntent(decoded)
        intent = decoded
      } catch {
        let corruptBytes = try? Data(contentsOf: intentURL)
        try quarantine(
          intent: proposedIntent,
          reason: "intent_corrupt_or_partial",
          artifactSHA256:
            corruptBytes.map(Self.sha256)
            ?? proposedIntent.authorityPlanSHA256)
      }
    } else {
      recovered = false
      pointerHandoff = try requirePristinePreflight(
        intent: proposedIntent)
      try TatwoAuthorityDurableArtifact.createOnly(
        try Self.canonicalData(proposedIntent),
        at: intentURL)
      intent = try read(
        TatwoGoalAuthorityIntentV1.self,
        from: intentURL,
        artifactName: "intent")
      guard intent == proposedIntent else {
        throw TatwoGoalAuthorityTransactionError.exactReadbackMismatch(
          "intent")
      }
      try Self.validateIntent(intent)
    }

    let pointerData = try sessionStore.authorityPointerData()
    let pointerAlreadyPublished: Bool
    if let pointerData {
      let expectedPointerData = try Self.canonicalData(intent.pointer)
      if pointerData == expectedPointerData {
        pointerAlreadyPublished = true
      } else if let pointerHandoff,
        pointerData == pointerHandoff.pointerData
      {
        // 2026-08-21 每對話一 session：pointer handoff（主導授權）
        // A fresh transaction may replace only the exact foreign pointer
        // admitted by preflight. Recovery retains the quarantine contract.
        pointerAlreadyPublished = false
      } else {
        try quarantine(
          intent: intent,
          reason: "foreign_or_mismatched_current_pointer",
          artifactSHA256: Self.sha256(pointerData))
      }
    } else {
      pointerAlreadyPublished = false
    }

    if !pointerAlreadyPublished {
      _ = try materializeGoal(intent: intent)
    }
    // Gen-3 K2 adapter: the Goal transaction remains the authority state
    // machine; it only publishes the create-only cross-store identity spine.
    // Recovery accepts an exact prior row and rejects every collision.
    _ = try TatwoWorkSpineStoreV1(directoryURL: goalStore.directoryURL)
      .ensureForGoalTransaction(
        TatwoWorkSpineV1(
          goalID: intent.contract.goalID,
          contractID: intent.contract.contractID,
          cycleEpoch: 1,
          threadID: intent.owner.externalProviderID))
    try recordStage(
      .goalMaterialized,
      intent: intent,
      artifactSHA256: intent.goalRecordSHA256)
    try stopIfRequested(
      .goalMaterialized,
      requested: stopAfterStageForTesting)

    let manifestReadback: TatwoExecutionManifestV1
    do {
      _ = try dispatchRegistry.recordManifest(
        intent.executionManifest)
      manifestReadback = try dispatchRegistry.requireExecutionManifest(
        contractID: intent.contract.contractID,
        expectedSHA256: intent.manifestSHA256)
      guard manifestReadback == intent.executionManifest else {
        try quarantine(
          intent: intent,
          reason: "full_manifest_readback_mismatch",
          artifactSHA256: try dispatchArtifactSHA256(
            contractID: intent.contract.contractID)
            ?? intent.manifestSHA256)
      }
    } catch let error as TatwoGoalAuthorityTransactionError {
      throw error
    } catch {
      try quarantine(
        intent: intent,
        reason: "execution_manifest_materialization_failed",
        artifactSHA256: try dispatchArtifactSHA256(
          contractID: intent.contract.contractID)
          ?? intent.manifestSHA256)
    }
    try recordStage(
      .manifestMaterialized,
      intent: intent,
      artifactSHA256: intent.manifestSHA256)
    try stopIfRequested(
      .manifestMaterialized,
      requested: stopAfterStageForTesting)

    if !pointerAlreadyPublished {
      try validatePrePointerCAS(intent: intent)
    }
    let pointerReadback: Data
    if let pointerData, pointerHandoff == nil {
      pointerReadback = pointerData
    } else if let pointerHandoff {
      pointerReadback = try sessionStore
        .replaceAuthorityPointerForHandoff(
          intent.pointer,
          replacing: pointerHandoff.pointerData)
    } else {
      pointerReadback = try sessionStore.publishAuthorityPointer(
        intent.pointer)
    }
    try recordStage(
      .pointerCommitted,
      intent: intent,
      artifactSHA256: Self.sha256(pointerReadback),
      pointerHandoffFromSessionID:
        pointerHandoff?.sessionID)
    try stopIfRequested(
      .pointerCommitted,
      requested: stopAfterStageForTesting)

    let attachment = try exactReadback(
      intent: intent,
      requireInitialGoalBytes: !pointerAlreadyPublished,
      scenarioBook: scenarioBook)
    try recordStage(
      .committed,
      intent: intent,
      artifactSHA256: try committedReadbackSHA256(
        intent: intent,
        goalRecord: intent.goalRecord))

    // 主導驗收機械修正：`??` 右側含 try 需整式標注（Swift 6），
    // 拆成顯式分支。
    let handoffSourceSessionID: String?
    if let pointerHandoff {
      handoffSourceSessionID = pointerHandoff.sessionID
    } else {
      handoffSourceSessionID =
        try stageReceipt(.pointerCommitted, intent: intent)?
          .pointerHandoffFromSessionID
    }
    return TatwoGoalAuthorityTransactionResultV1(
      transactionID: intent.transactionID,
      authorityPlanSHA256: intent.authorityPlanSHA256,
      manifestSHA256: intent.manifestSHA256,
      attachment: attachment,
      manifest: manifestReadback,
      recovered: recovered,
      pointerHandoffFromSessionID: handoffSourceSessionID)
  }

  private struct PointerHandoff {
    let sessionID: String
    let pointerData: Data
  }

  private func requirePristinePreflight(
    intent: TatwoGoalAuthorityIntentV1
  ) throws -> PointerHandoff? {
    var handoff: PointerHandoff?
    if let pointerData = try sessionStore.authorityPointerData() {
      let pointer: TatwoSessionPointer
      do {
        pointer = try Self.decodePointer(pointerData)
      } catch {
        throw TatwoGoalAuthorityTransactionError
          .artifactCorrupt("current-session")
      }
      guard let binding = pointer.ownerBinding,
        let ownerKind = binding.ownerKind
      else {
        throw TatwoGoalAuthorityTransactionError
          .preexistingAuthorityArtifact("current-session")
      }
      let sameOwner =
        binding.provider == intent.owner.provider
        && binding.sessionID == intent.owner.externalProviderID
        && ownerKind == intent.owner.ownerKind
        && binding.workspacePath == intent.owner.workspacePath
      if sameOwner {
        throw TatwoGoalAuthorityTransactionError
          .preexistingAuthorityArtifact("current-session")
      }
      handoff = PointerHandoff(
        sessionID: binding.sessionID,
        pointerData: pointerData)
    }
    if try goalStore.record(
      forContractID: intent.contract.contractID) != nil
    {
      throw TatwoGoalAuthorityTransactionError
        .preexistingAuthorityArtifact("goal-run")
    }
    if try dispatchRegistry.run(
      forContractID: intent.contract.contractID) != nil
    {
      throw TatwoGoalAuthorityTransactionError
        .preexistingAuthorityArtifact("dispatch-run")
    }
    return handoff
  }

  static func validateIntent(
    _ intent: TatwoGoalAuthorityIntentV1
  ) throws {
    try intent.executionManifest.validateAuthorityBinding(
      contract: intent.contract)
    let manifestSHA256 =
      try intent.executionManifest.canonicalSHA256()
    let plan = TatwoGoalAuthorityPlanBindingV1(
      contract: intent.contract,
      owner: intent.owner,
      executionManifestEntries:
        intent.executionManifest.entries,
      pointerGeneration: intent.pointer.generation ?? 0)
    let planSHA256 = try Self.canonicalSHA256(plan)
    let transactionID =
      "goal-authority-"
      + String(planSHA256.dropFirst("sha256:".count).prefix(40))
    let goalRecord = initialGoalRecord(
      contract: intent.contract,
      preparedAt: intent.preparedAt)
    let goalRecordSHA256 = try canonicalSHA256(goalRecord)
    guard intent.schema == "TatwoGoalAuthorityIntentV1",
      intent.expectedPointerState == "absent",
      intent.goalRecord == goalRecord,
      intent.goalRecordSHA256 == goalRecordSHA256,
      intent.manifestSHA256 == manifestSHA256,
      intent.authorityPlanSHA256 == planSHA256,
      intent.transactionID == transactionID,
      intent.pointer.schema == "TatwoSessionAuthorityPointerV3",
      intent.pointer.contractID == intent.contract.contractID,
      intent.pointer.goalID == intent.contract.goalID,
      intent.pointer.mode == intent.contract.mode,
      intent.pointer.scenario == intent.contract.scenario,
      TatwoObjectiveIdentity.make(intent.pointer.objective)
        .objectiveHash
        == TatwoObjectiveIdentity.make(intent.contract.objective)
          .objectiveHash,
      intent.pointer.startedAt
        == intent.executionManifest.generatedAt,
      intent.pointer.authorityTransactionID == transactionID,
      intent.pointer.authorityPlanSHA256 == planSHA256,
      intent.pointer.executionManifestSHA256 == manifestSHA256,
      intent.pointer.generation == 1,
      intent.pointer.ownerBinding?.provider
        == intent.owner.provider,
      intent.pointer.ownerBinding?.sessionID
        == intent.owner.externalProviderID,
      intent.pointer.ownerBinding?.ownerKind
        == intent.owner.ownerKind,
      intent.pointer.ownerBinding?.workspacePath
        == intent.owner.workspacePath,
      intent.pointer.ownerBinding?.contractID
        == intent.contract.contractID,
      intent.pointer.ownerBinding?.goalID
        == intent.contract.goalID
    else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "intent_authority_binding")
    }
  }

  private func materializeGoal(
    intent: TatwoGoalAuthorityIntentV1
  ) throws -> TatwoStoredGoalRun {
    let url = goalRecordURL(
      contractID: intent.contract.contractID)
    let expected = try Self.canonicalData(intent.goalRecord)
    if FileManager.default.fileExists(atPath: url.path) {
      let existing = try Data(contentsOf: url)
      guard existing == expected else {
        try quarantine(
          intent: intent,
          reason: "goal_exact_cas_mismatch",
          artifactSHA256: Self.sha256(existing))
      }
    } else {
      do {
        try TatwoCreateOnlyFile.write(
          expected,
          to: url
        ) {
          guard try Data(contentsOf: url) == expected else {
            throw TatwoGoalAuthorityTransactionError
              .compareAndSwapMismatch(
                "goal-run")
          }
        }
      } catch TatwoGoalAuthorityTransactionError
        .compareAndSwapMismatch(_)
      {
        let existing = try? Data(contentsOf: url)
        guard existing == expected else {
          try quarantine(
            intent: intent,
            reason: "goal_create_only_conflict",
            artifactSHA256: existing.map(Self.sha256)
              ?? intent.goalRecordSHA256)
        }
      } catch {
        try quarantine(
          intent: intent,
          reason: "goal_create_only_durability_failure",
          artifactSHA256: (try? Data(contentsOf: url)).map(
            Self.sha256)
            ?? intent.goalRecordSHA256)
      }
    }
    let readback = try Data(contentsOf: url)
    guard readback == expected,
      Self.sha256(readback) == intent.goalRecordSHA256,
      let record = try? Self.decode(
        TatwoStoredGoalRun.self,
        from: readback),
      record == intent.goalRecord
    else {
      try quarantine(
        intent: intent,
        reason: "goal_exact_readback_mismatch",
        artifactSHA256: Self.sha256(readback))
    }
    return record
  }

  private func exactReadback(
    intent: TatwoGoalAuthorityIntentV1,
    requireInitialGoalBytes: Bool,
    scenarioBook: TatwoScenarioConfigBookV1
  ) throws -> TatwoSessionAttachmentV1 {
    guard let pointerData = try sessionStore.authorityPointerData(),
      pointerData == (try Self.canonicalData(intent.pointer))
    else {
      throw TatwoGoalAuthorityTransactionError
        .exactReadbackMismatch("current-session")
    }
    if requireInitialGoalBytes {
      let goalBytes = try goalRecordBytes(
        contractID: intent.contract.contractID)
      guard Self.sha256(goalBytes) == intent.goalRecordSHA256 else {
        throw TatwoGoalAuthorityTransactionError
          .exactReadbackMismatch("goal-run")
      }
    }
    let manifest = try dispatchRegistry.requireExecutionManifest(
      contractID: intent.contract.contractID,
      expectedSHA256: intent.manifestSHA256)
    guard manifest == intent.executionManifest else {
      throw TatwoGoalAuthorityTransactionError
        .exactReadbackMismatch("execution-manifest")
    }
    return try sessionStore.resolveAuthorityCurrent(
      pointer: intent.pointer,
      ownerVerification: .canonicalV3(intent.owner),
      scenarioBook: scenarioBook,
      goalStore: goalStore)
  }

  private func validatePrePointerCAS(
    intent: TatwoGoalAuthorityIntentV1
  ) throws {
    let goalBytes = try goalRecordBytes(
      contractID: intent.contract.contractID)
    guard Self.sha256(goalBytes) == intent.goalRecordSHA256 else {
      try quarantine(
        intent: intent,
        reason: "goal_changed_before_pointer",
        artifactSHA256: Self.sha256(goalBytes))
    }
    do {
      let manifest = try dispatchRegistry.requireExecutionManifest(
        contractID: intent.contract.contractID,
        expectedSHA256: intent.manifestSHA256)
      guard manifest == intent.executionManifest else {
        try quarantine(
          intent: intent,
          reason: "manifest_changed_before_pointer",
          artifactSHA256: try dispatchArtifactSHA256(
            contractID: intent.contract.contractID)
            ?? intent.manifestSHA256)
      }
    } catch let error as TatwoGoalAuthorityTransactionError {
      throw error
    } catch {
      try quarantine(
        intent: intent,
        reason: "manifest_changed_before_pointer",
        artifactSHA256: try dispatchArtifactSHA256(
          contractID: intent.contract.contractID)
          ?? intent.manifestSHA256)
    }
  }

  private func recordStage(
    _ stage: TatwoGoalAuthorityStageV1,
    intent: TatwoGoalAuthorityIntentV1,
    artifactSHA256: String,
    reason: String? = nil,
    pointerHandoffFromSessionID: String? = nil
  ) throws {
    let receipt = TatwoGoalAuthorityStageReceiptV1(
      transactionID: intent.transactionID,
      authorityPlanSHA256: intent.authorityPlanSHA256,
      stage: stage,
      artifactSHA256: artifactSHA256,
      reason: reason,
      pointerHandoffFromSessionID:
        pointerHandoffFromSessionID,
      recordedAt: Date())
    let url = stageURL(stage, intent: intent)
    if FileManager.default.fileExists(atPath: url.path) {
      let existing = try read(
        TatwoGoalAuthorityStageReceiptV1.self,
        from: url,
        artifactName: stage.rawValue)
      guard existing.transactionID == receipt.transactionID,
        existing.authorityPlanSHA256 == receipt.authorityPlanSHA256,
        existing.stage == receipt.stage,
        existing.artifactSHA256 == receipt.artifactSHA256,
        existing.reason == receipt.reason,
        existing.pointerHandoffFromSessionID
          == receipt.pointerHandoffFromSessionID
      else {
        throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
          stage.rawValue)
      }
      return
    }
    try TatwoAuthorityDurableArtifact.createOnly(
      try Self.canonicalData(receipt),
      at: url)
    let exact = try read(
      TatwoGoalAuthorityStageReceiptV1.self,
      from: url,
      artifactName: stage.rawValue)
    guard exact == receipt else {
      throw TatwoGoalAuthorityTransactionError
        .exactReadbackMismatch(stage.rawValue)
    }
  }

  private func stopIfRequested(
    _ stage: TatwoGoalAuthorityStageV1,
    requested: TatwoGoalAuthorityStageV1?
  ) throws {
    if requested == stage {
      throw TatwoGoalAuthorityTransactionError.interruptedAfterStage(
        stage.rawValue)
    }
  }

  private func stageReceipt(
    _ stage: TatwoGoalAuthorityStageV1,
    intent: TatwoGoalAuthorityIntentV1
  ) throws -> TatwoGoalAuthorityStageReceiptV1? {
    let url = stageURL(stage, intent: intent)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return try read(
      TatwoGoalAuthorityStageReceiptV1.self,
      from: url,
      artifactName: stage.rawValue)
  }

  private func quarantine(
    intent: TatwoGoalAuthorityIntentV1,
    reason: String,
    artifactSHA256: String
  ) throws -> Never {
    try recordStage(
      .quarantined,
      intent: intent,
      artifactSHA256: artifactSHA256,
      reason: reason)
    throw TatwoGoalAuthorityTransactionError.quarantined(reason)
  }

  private func committedReadbackSHA256(
    intent: TatwoGoalAuthorityIntentV1,
    goalRecord: TatwoStoredGoalRun
  ) throws -> String {
    struct Readback: Codable {
      let transactionID: String
      let authorityPlanSHA256: String
      let manifestSHA256: String
      let goalRecord: TatwoStoredGoalRun
      let pointer: TatwoSessionPointer
    }
    return try Self.canonicalSHA256(
      Readback(
        transactionID: intent.transactionID,
        authorityPlanSHA256: intent.authorityPlanSHA256,
        manifestSHA256: intent.manifestSHA256,
        goalRecord: goalRecord,
        pointer: intent.pointer))
  }

  private func transactionArtifactURL(
    transactionID: String,
    name: String
  ) -> URL {
    goalStore.directoryURL
      .appendingPathComponent(
        "goal-authority-transactions", isDirectory: true)
      .appendingPathComponent(transactionID, isDirectory: true)
      .appendingPathComponent(name, isDirectory: false)
  }

  private func stageURL(
    _ stage: TatwoGoalAuthorityStageV1,
    intent: TatwoGoalAuthorityIntentV1
  ) -> URL {
    let prefix: String
    switch stage {
    case .goalMaterialized: prefix = "10"
    case .manifestMaterialized: prefix = "20"
    case .pointerCommitted: prefix = "30"
    case .committed: prefix = "40"
    case .quarantined: prefix = "90"
    }
    return transactionArtifactURL(
      transactionID: intent.transactionID,
      name: "\(prefix)-\(stage.rawValue).json")
  }

  private func goalRecordBytes(contractID: String) throws -> Data {
    let url = goalRecordURL(contractID: contractID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TatwoGoalAuthorityTransactionError
        .exactReadbackMismatch("goal-run")
    }
    return try Data(contentsOf: url)
  }

  private func goalRecordURL(contractID: String) -> URL {
    goalStore.directoryURL
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent("\(contractID).json", isDirectory: false)
  }

  private func dispatchArtifactSHA256(
    contractID: String
  ) throws -> String? {
    let url = try dispatchRegistry.fileURL(
      forContractID: contractID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return Self.sha256(try Data(contentsOf: url))
  }

  private func read<T: Decodable>(
    _ type: T.Type,
    from url: URL,
    artifactName: String
  ) throws -> T {
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(type, from: Data(contentsOf: url))
    } catch {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        artifactName)
    }
  }

  private static func canonicalData<T: Encodable>(
    _ value: T
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }

  private static func decodePointer(
    _ data: Data
  ) throws -> TatwoSessionPointer {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TatwoSessionPointer.self, from: data)
  }

  private static func canonicalSHA256<T: Encodable>(
    _ value: T
  ) throws -> String {
    sha256(try canonicalData(value))
  }

  private static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data
  ) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }

  static func initialGoalRecord(
    contract: TatwoWorkOSContractV1,
    preparedAt: Date
  ) -> TatwoStoredGoalRun {
    let canonicalPreparedAt = Date(
      timeIntervalSince1970:
        preparedAt.timeIntervalSince1970.rounded(.down))
    let issuedIdentityBindings =
      TatwoIssuedIdentityBindingV1.canonicalSnapshot(
        for: contract)
    var receipts: [TatwoStoredReceipt] = []
    if contract.receiptRequirements.contains(
      where: { $0.id == "goal-tracker" })
    {
      receipts.append(
        TatwoStoredReceipt(
          receiptID: "goal-tracker",
          kind: "goal_tracker",
          loopID: contract.mainlineLoop.id,
          submittedAt: canonicalPreparedAt))
    }
    return TatwoStoredGoalRun(
      goalID: contract.goalID,
      contractID: contract.contractID,
      mode: contract.mode,
      scenario: contract.scenario,
      objective: contract.objective,
      routeBindingOverride: contract.routeBindingOverride,
      authorityInstanceDiscriminator: contract.authorityInstanceDiscriminator,
      issuedIdentityBindings: issuedIdentityBindings,
      issuedIdentityBindingsDigest:
        TatwoIssuedIdentityBindingV1.deterministicDigest(
          for: issuedIdentityBindings),
      status: contract.goalRun.status,
      issuedAt: canonicalPreparedAt,
      updatedAt: canonicalPreparedAt,
      receipts: receipts)
  }

  /// Fail-closed read path for every V3 current-session consumer.
  ///
  /// A syntactically valid pointer is not authority. It must name the exact
  /// create-only intent, whose plan and hashes recompute, and the exact complete
  /// manifest persisted under the same canonical state root.
  public static func validatedIssuedContractReadback(
    pointer: TatwoSessionPointer,
    stateRoot: URL
  ) throws -> TatwoWorkOSContractV1 {
    guard pointer.schema == "TatwoSessionAuthorityPointerV3",
      let transactionID = pointer.authorityTransactionID,
      transactionID.hasPrefix("goal-authority-"),
      transactionID.count == "goal-authority-".count + 40,
      transactionID.dropFirst("goal-authority-".count)
        .allSatisfy(\.isHexDigit)
    else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "v3_transaction_id")
    }
    let intentURL = stateRoot.standardizedFileURL
      .appendingPathComponent(
        "goal-authority-transactions", isDirectory: true)
      .appendingPathComponent(transactionID, isDirectory: true)
      .appendingPathComponent("00-intent.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: intentURL.path)
    else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_intent_missing")
    }
    let intentData = try Data(contentsOf: intentURL)
    let intent: TatwoGoalAuthorityIntentV1
    do {
      intent = try decode(
        TatwoGoalAuthorityIntentV1.self,
        from: intentData)
    } catch {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_intent")
    }
    guard intentData == (try canonicalData(intent)) else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_intent_noncanonical_bytes")
    }
    try validateIntent(intent)
    guard pointer == intent.pointer,
      pointer.authorityTransactionID == intent.transactionID,
      pointer.authorityPlanSHA256 == intent.authorityPlanSHA256,
      pointer.executionManifestSHA256 == intent.manifestSHA256
    else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_pointer_intent_binding")
    }
    let registry = TatwoDispatchRegistry(
      directoryURL: stateRoot.standardizedFileURL)
    let manifest: TatwoExecutionManifestV1
    do {
      manifest = try registry.requireExecutionManifest(
        contractID: pointer.contractID,
        expectedSHA256: intent.manifestSHA256)
    } catch {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_manifest")
    }
    guard manifest == intent.executionManifest else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_manifest_binding")
    }
    let goalURL = stateRoot.standardizedFileURL
      .appendingPathComponent("goals", isDirectory: true)
      .appendingPathComponent(
        "\(pointer.contractID).json",
        isDirectory: false)
    guard FileManager.default.fileExists(atPath: goalURL.path)
    else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_goal_missing")
    }
    let goalRecord: TatwoStoredGoalRun
    do {
      goalRecord = try decode(
        TatwoStoredGoalRun.self,
        from: Data(contentsOf: goalURL))
    } catch {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_goal")
    }
    let expectedBindings =
      intent.goalRecord.issuedIdentityBindings
    let expectedBindingsDigest = expectedBindings.map {
      TatwoIssuedIdentityBindingV1.deterministicDigest(
        for: $0)
    }
    guard goalRecord.schema == intent.goalRecord.schema,
      goalRecord.contractID == pointer.contractID,
      goalRecord.contractID == intent.contract.contractID,
      goalRecord.goalID == pointer.goalID,
      goalRecord.goalID == intent.contract.goalID,
      goalRecord.mode == pointer.mode,
      goalRecord.mode == intent.contract.mode,
      goalRecord.scenario == pointer.scenario,
      goalRecord.scenario == intent.contract.scenario,
      TatwoObjectiveIdentity.make(goalRecord.objective)
        .objectiveHash
        == TatwoObjectiveIdentity.make(pointer.objective)
          .objectiveHash,
      TatwoObjectiveIdentity.make(goalRecord.objective)
        .objectiveHash
        == TatwoObjectiveIdentity.make(intent.contract.objective)
          .objectiveHash,
      goalRecord.routeBindingOverride
        == intent.goalRecord.routeBindingOverride,
      goalRecord.issuedAt == intent.goalRecord.issuedAt,
      goalRecord.issuedIdentityBindings == expectedBindings,
      goalRecord.issuedIdentityBindingsDigest
        == intent.goalRecord.issuedIdentityBindingsDigest,
      goalRecord.issuedIdentityBindingsDigest
        == expectedBindingsDigest
    else {
      throw TatwoGoalAuthorityTransactionError.artifactCorrupt(
        "authority_goal_binding")
    }
    return intent.contract
  }

  static func validateAuthorityReadback(
    pointer: TatwoSessionPointer,
    stateRoot: URL
  ) throws {
    _ = try validatedIssuedContractReadback(
      pointer: pointer,
      stateRoot: stateRoot)
  }

  static func sha256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }
}

enum TatwoAuthorityDurableArtifact {
  static func createOnly(_ data: Data, at url: URL) throws {
    try TatwoCreateOnlyFile.write(
      data,
      to: url
    ) {
      guard try Data(contentsOf: url) == data else {
        throw TatwoGoalAuthorityTransactionError
          .compareAndSwapMismatch(url.lastPathComponent)
      }
    }
    guard try Data(contentsOf: url) == data else {
      throw TatwoGoalAuthorityTransactionError
        .exactReadbackMismatch(url.lastPathComponent)
    }
  }
}
