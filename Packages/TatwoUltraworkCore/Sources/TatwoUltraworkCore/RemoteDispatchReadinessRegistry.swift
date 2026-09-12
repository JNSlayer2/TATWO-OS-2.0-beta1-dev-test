import Foundation

public enum TatwoRemoteDispatchReadinessRegistryError:
  Error, LocalizedError, Sendable, Equatable
{
  case invalidField(String)
  case registryMissing
  case registryCorrupt(String)
  case signatureRejected
  case manifestStale
  case manifestNotYetValid
  case manifestLifetimeExceeded
  case bindingNotFound
  case bindingAmbiguous
  case bindingDrift(String)

  public var errorDescription: String? {
    switch self {
    case .invalidField(let field):
      return "remote readiness registry field is invalid: \(field)"
    case .registryMissing:
      return "target readiness registry is missing"
    case .registryCorrupt(let field):
      return "target readiness registry is corrupt: \(field)"
    case .signatureRejected:
      return "target readiness registry signature was rejected"
    case .manifestStale:
      return "target readiness manifest is stale"
    case .manifestNotYetValid:
      return "target readiness manifest is not yet valid"
    case .manifestLifetimeExceeded:
      return "target readiness manifest lifetime exceeds the allowed window"
    case .bindingNotFound:
      return "target readiness binding was not found"
    case .bindingAmbiguous:
      return "target readiness binding is ambiguous"
    case .bindingDrift(let field):
      return "target readiness binding drifted: \(field)"
    }
  }
}

/// Target-local durable readiness record.
///
/// `canonicalWorkspacePath` and the executable paths intentionally remain only
/// in the target registry. They are not copied into the portable advertisement
/// consumed by an origin.
public struct TatwoRemoteDispatchReadinessRegistryEntryV1:
  Codable, Sendable, Equatable
{
  public let workspaceBindingID: String
  public let canonicalWorkspacePath: String
  public let workspaceDigestInput: TatwoTargetWorkspaceDigestInputV1
  public let requestedAgent: TatwoRemoteAgentKindV1
  public let exactModelRouteID: String
  public let executablePin: TatwoAgentExecutablePinV1
  public let transportCapabilities: [String]
  public let activeSkillRevisions: [TatwoActiveSkillRevisionV1]
  public let updatedAt: Date

  public init(
    workspaceBindingID: String,
    canonicalWorkspacePath: String,
    workspaceDigestInput: TatwoTargetWorkspaceDigestInputV1,
    requestedAgent: TatwoRemoteAgentKindV1,
    exactModelRouteID: String,
    executablePin: TatwoAgentExecutablePinV1,
    transportCapabilities: [String],
    activeSkillRevisions: [TatwoActiveSkillRevisionV1],
    updatedAt: Date = Date()
  ) {
    self.workspaceBindingID = workspaceBindingID
    self.canonicalWorkspacePath = canonicalWorkspacePath
    self.workspaceDigestInput = workspaceDigestInput
    self.requestedAgent = requestedAgent
    self.exactModelRouteID = exactModelRouteID
    self.executablePin = executablePin
    self.transportCapabilities = transportCapabilities
    self.activeSkillRevisions = activeSkillRevisions
    self.updatedAt = updatedAt
  }

  public var workspaceBindingDigest: String {
    get throws { try workspaceDigestInput.canonicalDigest() }
  }

  public var agentModelCapabilityDigest: String {
    get throws {
      try TatwoAgentModelCapabilityDigestInputV1(
        requestedAgent: requestedAgent.rawValue,
        exactModelRouteID: exactModelRouteID,
        executableContentDigest: Self.unprefixedSHA256(executablePin.contentDigest),
        transportCapabilities: transportCapabilities
      ).canonicalDigest()
    }
  }

  public var activeSkillSetDigest: String {
    get throws {
      try TatwoActiveSkillSetDigestV1.canonicalDigest(activeSkillRevisions)
    }
  }

  public func validate() throws {
    guard workspaceBindingID == workspaceDigestInput.workspaceBindingID else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "workspaceBindingID")
    }
    guard
      !canonicalWorkspacePath.isEmpty,
      canonicalWorkspacePath.hasPrefix("/"),
      !canonicalWorkspacePath.contains("\0")
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "canonicalWorkspacePath")
    }
    guard executablePin.schema == "TatwoAgentExecutablePinV1",
      executablePin.agent == requestedAgent.rawValue
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField("executablePin")
    }
    guard
      TatwoModelIdentityRegistry.canonicalModelID(for: exactModelRouteID)
        == exactModelRouteID,
      TatwoModelIdentityRegistry.isActiveDispatchEligible(exactModelRouteID),
      requestedAgent.acceptsExactModelRouteID(exactModelRouteID)
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "exactModelRouteID")
    }
    _ = try workspaceBindingDigest
    _ = try agentModelCapabilityDigest
    _ = try activeSkillSetDigest
  }

  static func unprefixedSHA256(_ value: String) -> String {
    value.hasPrefix("sha256:") ? String(value.dropFirst("sha256:".count)) : value
  }
}

public enum TatwoRemoteDispatchReadinessTargetSnapshotBuilderV1 {
  public static let defaultTransportCapabilities = [
    "signed-readiness-v1",
    "stdin-task-v1",
  ]

  public static func build(
    workspaceBindingID: String,
    workspaceURL: URL,
    requestedAgent: TatwoRemoteAgentKindV1,
    exactModelRouteID: String,
    targetDeviceID: String,
    agentEngine: TatwoAgentEngineBinding = .production,
    skilletStore: TatwoSkilletRepositoryStore,
    transportCapabilities: [String] = defaultTransportCapabilities,
    now: Date = Date()
  ) throws -> TatwoRemoteDispatchReadinessRegistryEntryV1 {
    let canonicalWorkspacePath = TatwoPathCanonical.filePath(workspaceURL.path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: canonicalWorkspacePath,
      isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "workspaceUnavailable")
    }
    let attributes = try FileManager.default.attributesOfItem(
      atPath: canonicalWorkspacePath)
    guard
      let deviceNumber = attributes[.systemNumber] as? NSNumber,
      let inodeNumber = attributes[.systemFileNumber] as? NSNumber,
      deviceNumber.uint64Value > 0,
      inodeNumber.uint64Value > 0
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "workspaceFilesystemIdentity")
    }
    let workspaceInput = TatwoTargetWorkspaceDigestInputV1(
      workspaceBindingID: workspaceBindingID,
      canonicalPathDigest:
        TatwoRemoteDispatchReadinessRegistryEntryV1.unprefixedSHA256(
          TatwoLoopJobDigest.sha256(Data(canonicalWorkspacePath.utf8))),
      filesystemDeviceID: deviceNumber.uint64Value,
      filesystemInodeID: inodeNumber.uint64Value)

    let pin = try agentEngine.resolvePinnedExecutable(for: requestedAgent)
    try agentEngine.revalidatePin(pin)
    _ = try agentEngine.exactModelLaunchArgument(
      for: requestedAgent,
      exactModelRouteID: exactModelRouteID)
    let activeSkills = try activeSkillRevisions(
      targetDeviceID: targetDeviceID,
      store: skilletStore)
    let entry = TatwoRemoteDispatchReadinessRegistryEntryV1(
      workspaceBindingID: workspaceBindingID,
      canonicalWorkspacePath: canonicalWorkspacePath,
      workspaceDigestInput: workspaceInput,
      requestedAgent: requestedAgent,
      exactModelRouteID: exactModelRouteID,
      executablePin: pin,
      transportCapabilities: transportCapabilities,
      activeSkillRevisions: activeSkills,
      updatedAt: now)
    try entry.validate()
    return entry
  }

  public static func activeSkillRevisions(
    targetDeviceID: String,
    store: TatwoSkilletRepositoryStore
  ) throws -> [TatwoActiveSkillRevisionV1] {
    var revisions: [TatwoActiveSkillRevisionV1] = []
    for repositoryID in try store.listRepositoryIDs() {
      let repository = try store.loadRepository(id: repositoryID)
      let receipts = try store.loadReceipts(repositoryID: repositoryID)
      guard
        let head = repository.deviceHeads.first(where: {
          $0.deviceID == targetDeviceID && $0.activationState == .active
        }),
        repository.matchingDeviceReceipt(for: head, receipts: receipts) != nil
      else {
        continue
      }
      revisions.append(
        TatwoActiveSkillRevisionV1(
          repository: repositoryID,
          revision: head.revisionID,
          contentDigest: head.contentDigest))
    }
    guard !revisions.isEmpty else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "activeSkillSet.empty")
    }
    return revisions.sorted {
      ($0.repository, $0.revision, $0.contentDigest)
        < ($1.repository, $1.revision, $1.contentDigest)
    }
  }
}

/// Portable target-signed advertisement used by an origin to create the exact
/// readiness binding embedded in a job. It deliberately contains no absolute
/// target path, executable path, Skillet root, or skill source path.
public struct TatwoRemoteDispatchReadinessManifestV1:
  Codable, Sendable, Equatable
{
  public static let schemaName = "TatwoRemoteDispatchReadinessManifestV1"
  public static let maximumLifetime: TimeInterval = 60 * 60
  public static let allowedClockSkew: TimeInterval = 30

  public let schema: String
  public let targetDeviceID: String
  public let targetKeyID: String
  public let targetKeyGeneration: UInt64
  public let registryGeneration: UInt64
  public let workspaceBindingID: String
  public let workspaceBindingDigest: String
  public let requestedAgent: String
  public let exactModelRouteID: String
  public let agentModelCapabilityDigest: String
  public let activeSkillSetDigest: String
  public let issuedAt: Date
  public let expiresAt: Date
  public let targetSignature: TatwoDeviceSignatureV1

  public init(
    schema: String = TatwoRemoteDispatchReadinessManifestV1.schemaName,
    targetDeviceID: String,
    targetKeyID: String,
    targetKeyGeneration: UInt64,
    registryGeneration: UInt64,
    workspaceBindingID: String,
    workspaceBindingDigest: String,
    requestedAgent: String,
    exactModelRouteID: String,
    agentModelCapabilityDigest: String,
    activeSkillSetDigest: String,
    issuedAt: Date,
    expiresAt: Date,
    targetSignature: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.targetDeviceID = targetDeviceID
    self.targetKeyID = targetKeyID
    self.targetKeyGeneration = targetKeyGeneration
    self.registryGeneration = registryGeneration
    self.workspaceBindingID = workspaceBindingID
    self.workspaceBindingDigest = workspaceBindingDigest
    self.requestedAgent = requestedAgent
    self.exactModelRouteID = exactModelRouteID
    self.agentModelCapabilityDigest = agentModelCapabilityDigest
    self.activeSkillSetDigest = activeSkillSetDigest
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.targetSignature = targetSignature
  }

  public func binding(
    challengeNonce: String
  ) -> TatwoRemoteDispatchReadinessBindingV1 {
    TatwoRemoteDispatchReadinessBindingV1(
      workspaceBindingID: workspaceBindingID,
      workspaceBindingDigest: workspaceBindingDigest,
      agentModelCapabilityDigest: agentModelCapabilityDigest,
      activeSkillSetDigest: activeSkillSetDigest,
      challengeNonce: challengeNonce)
  }

  public func verify(
    trust: TatwoLoopJobChannelTrust,
    expectedTargetDeviceID: String,
    expectedAgent: TatwoRemoteAgentKindV1,
    expectedExactModelRouteID: String? = nil,
    now: Date = Date(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard schema == Self.schemaName else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField("manifest.schema")
    }
    guard targetDeviceID == expectedTargetDeviceID,
      requestedAgent == expectedAgent.rawValue
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField("manifest.scope")
    }
    if let expectedExactModelRouteID,
      exactModelRouteID != expectedExactModelRouteID
    {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "manifest.modelRouteScope")
    }
    guard expiresAt > issuedAt else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "manifest.freshnessWindow")
    }
    guard expiresAt.timeIntervalSince(issuedAt) <= Self.maximumLifetime else {
      throw TatwoRemoteDispatchReadinessRegistryError.manifestLifetimeExceeded
    }
    guard issuedAt <= now.addingTimeInterval(Self.allowedClockSkew) else {
      throw TatwoRemoteDispatchReadinessRegistryError.manifestNotYetValid
    }
    guard expiresAt > now else {
      throw TatwoRemoteDispatchReadinessRegistryError.manifestStale
    }
    guard targetSignature.signedAt == TatwoLoopJobChannelTrust.iso8601(issuedAt)
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "manifest.signedAt")
    }
    let binding = binding(challengeNonce: "manifest-verification")
    try binding.validate()
    guard
      TatwoModelIdentityRegistry.canonicalModelID(for: exactModelRouteID)
        == exactModelRouteID,
      TatwoModelIdentityRegistry.isActiveDispatchEligible(exactModelRouteID)
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "manifest.modelRoute")
    }
    do {
      try trust.verifyRemoteDispatchReadiness(
        payload: try unsignedPayload.canonicalData(),
        signature: targetSignature,
        targetDeviceID: expectedTargetDeviceID,
        now: now,
        maxAgeSec: Self.maximumLifetime,
        environment: environment)
    } catch {
      throw TatwoRemoteDispatchReadinessRegistryError.signatureRejected
    }
    guard
      let pinned = try trust.currentPinnedIdentity(
        deviceID: expectedTargetDeviceID,
        environment: environment),
      pinned.keyStatus == .active,
      pinned.keyID == targetKeyID,
      pinned.keyGeneration == targetKeyGeneration
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "manifest.targetIdentity")
    }
  }

  /// Fleet/CLI adapter boundary: validate the current sealed manifest against
  /// the already-minted physical attempt immediately before assignment.
  ///
  /// This intentionally rejects a manifest that was refreshed or replaced
  /// after the logical job was enqueued. A new manifest requires a new logical
  /// authorization/binding; the CLI must not silently rewrite the job.
  public func validateCurrentProductionAgentBinding(
    for job: TatwoLoopJobV1,
    trust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    guard case let .tatwoLoop(loop) = job.payload,
      let agent = loop.agent,
      let exactModelRouteID = loop.exactModelRouteID
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "job.agentRoute")
    }
    try verify(
      trust: trust,
      expectedTargetDeviceID: job.targetDeviceID,
      expectedAgent: agent,
      expectedExactModelRouteID: exactModelRouteID,
      now: now,
      environment: environment)
    guard let jobBinding = job.remoteDispatchReadiness,
      binding(challengeNonce: jobBinding.challengeNonce) == jobBinding
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "job.readinessBinding")
    }
    guard let locator = job.workspaceLocator,
      locator.workspaceBindingID == workspaceBindingID,
      locator.registryGeneration == registryGeneration
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.invalidField(
        "job.workspaceLocator")
    }
  }

  fileprivate var unsignedPayload: Unsigned {
    Unsigned(
      targetDeviceID: targetDeviceID,
      targetKeyID: targetKeyID,
      targetKeyGeneration: targetKeyGeneration,
      registryGeneration: registryGeneration,
      workspaceBindingID: workspaceBindingID,
      workspaceBindingDigest: workspaceBindingDigest,
      requestedAgent: requestedAgent,
      exactModelRouteID: exactModelRouteID,
      agentModelCapabilityDigest: agentModelCapabilityDigest,
      activeSkillSetDigest: activeSkillSetDigest,
      issuedAt: issuedAt,
      expiresAt: expiresAt)
  }

  fileprivate struct Unsigned: Encodable {
    let schema = TatwoRemoteDispatchReadinessManifestV1.schemaName
    let targetDeviceID: String
    let targetKeyID: String
    let targetKeyGeneration: UInt64
    let registryGeneration: UInt64
    let workspaceBindingID: String
    let workspaceBindingDigest: String
    let requestedAgent: String
    let exactModelRouteID: String
    let agentModelCapabilityDigest: String
    let activeSkillSetDigest: String
    let issuedAt: Date
    let expiresAt: Date

    func canonicalData() throws -> Data {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(self)
    }
  }
}

public struct TatwoRemoteDispatchReadinessRegistryStoreV1: Sendable {
  public static let directoryName = "remote-dispatch-readiness"
  public static let registryFileName = "registry-v1.json"

  public let rootURL: URL
  public let trust: TatwoLoopJobChannelTrust

  public init(rootURL: URL, trust: TatwoLoopJobChannelTrust) {
    self.rootURL = rootURL.standardizedFileURL
    self.trust = trust
  }

  public static func production(
    stateRoot: URL,
    trust: TatwoLoopJobChannelTrust
  ) -> Self {
    Self(
      rootURL: stateRoot.standardizedFileURL
        .appendingPathComponent(directoryName, isDirectory: true),
      trust: trust)
  }

  public var registryURL: URL {
    rootURL.appendingPathComponent(Self.registryFileName)
  }

  @discardableResult
  public func publish(
    _ entry: TatwoRemoteDispatchReadinessRegistryEntryV1,
    issuedAt: Date = Date(),
    expiresAt: Date? = nil
  ) throws -> TatwoRemoteDispatchReadinessManifestV1 {
    try entry.validate()
    return try TatwoFileLock.withExclusiveLock(for: registryURL) {
      var entries: [TatwoRemoteDispatchReadinessRegistryEntryV1] = []
      var nextGeneration: UInt64 = 1
      if FileManager.default.fileExists(atPath: registryURL.path) {
        let current = try loadVerified()
        entries = current.entries
        nextGeneration = current.generation + 1
      }
      entries.removeAll {
        $0.workspaceBindingID == entry.workspaceBindingID
          && $0.requestedAgent == entry.requestedAgent
      }
      entries.append(entry)
      entries.sort {
        ($0.workspaceBindingID, $0.requestedAgent.rawValue, $0.exactModelRouteID)
          < ($1.workspaceBindingID, $1.requestedAgent.rawValue, $1.exactModelRouteID)
      }
      let unsignedRegistry = SignedRegistry.Unsigned(
        targetDeviceID: trust.localIdentity.deviceID,
        targetKeyID: trust.localIdentity.keyID,
        targetKeyGeneration: trust.localIdentity.keyGeneration,
        generation: nextGeneration,
        updatedAt: issuedAt,
        entries: entries)
      let registrySignature = try trust.sign(
        payload: unsignedRegistry.canonicalData(),
        purpose: .loopTargetReadiness,
        signedAt: issuedAt)
      try write(
        SignedRegistry(
          unsigned: unsignedRegistry,
          targetSignature: registrySignature),
        to: registryURL)

      let expiry = expiresAt ?? issuedAt.addingTimeInterval(15 * 60)
      let unsignedManifest = TatwoRemoteDispatchReadinessManifestV1.Unsigned(
        targetDeviceID: trust.localIdentity.deviceID,
        targetKeyID: trust.localIdentity.keyID,
        targetKeyGeneration: trust.localIdentity.keyGeneration,
        registryGeneration: nextGeneration,
        workspaceBindingID: entry.workspaceBindingID,
        workspaceBindingDigest: try entry.workspaceBindingDigest,
        requestedAgent: entry.requestedAgent.rawValue,
        exactModelRouteID: entry.exactModelRouteID,
        agentModelCapabilityDigest: try entry.agentModelCapabilityDigest,
        activeSkillSetDigest: try entry.activeSkillSetDigest,
        issuedAt: issuedAt,
        expiresAt: expiry)
      let manifestSignature = try trust.sign(
        payload: unsignedManifest.canonicalData(),
        purpose: .loopTargetReadiness,
        signedAt: issuedAt)
      return TatwoRemoteDispatchReadinessManifestV1(
        targetDeviceID: unsignedManifest.targetDeviceID,
        targetKeyID: unsignedManifest.targetKeyID,
        targetKeyGeneration: unsignedManifest.targetKeyGeneration,
        registryGeneration: unsignedManifest.registryGeneration,
        workspaceBindingID: unsignedManifest.workspaceBindingID,
        workspaceBindingDigest: unsignedManifest.workspaceBindingDigest,
        requestedAgent: unsignedManifest.requestedAgent,
        exactModelRouteID: unsignedManifest.exactModelRouteID,
        agentModelCapabilityDigest: unsignedManifest.agentModelCapabilityDigest,
        activeSkillSetDigest: unsignedManifest.activeSkillSetDigest,
        issuedAt: unsignedManifest.issuedAt,
        expiresAt: unsignedManifest.expiresAt,
        targetSignature: manifestSignature)
    }
  }

  public func observation(
    for request: TatwoRemoteDispatchReadinessRequestV1,
    agentEngine: TatwoAgentEngineBinding = .production,
    skilletStore: TatwoSkilletRepositoryStore,
    now: Date = Date()
  ) throws -> TatwoRemoteDispatchReadinessObservationV1 {
    let registry = try loadVerified()
    let matches = registry.entries.filter { entry in
      entry.workspaceBindingID == request.expectedWorkspaceBindingID
        && (try? entry.workspaceBindingDigest) == request.expectedWorkspaceBindingDigest
        && (try? entry.agentModelCapabilityDigest)
          == request.expectedAgentModelCapabilityDigest
        && (try? entry.activeSkillSetDigest) == request.expectedActiveSkillSetDigest
        && (request.expectedAgent.map { $0 == entry.requestedAgent.rawValue } ?? true)
        && (request.expectedExactModelRouteID.map {
          $0 == entry.exactModelRouteID
        } ?? true)
    }
    guard matches.count == 1, let stored = matches.first else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingNotFound
    }
    let current = try TatwoRemoteDispatchReadinessTargetSnapshotBuilderV1.build(
      workspaceBindingID: stored.workspaceBindingID,
      workspaceURL: URL(
        fileURLWithPath: stored.canonicalWorkspacePath,
        isDirectory: true),
      requestedAgent: stored.requestedAgent,
      exactModelRouteID: stored.exactModelRouteID,
      targetDeviceID: trust.localIdentity.deviceID,
      agentEngine: agentEngine,
      skilletStore: skilletStore,
      transportCapabilities: stored.transportCapabilities,
      now: now)
    let comparisons: [(String, String, String)] = [
      (
        "workspaceBindingDigest",
        try current.workspaceBindingDigest,
        try stored.workspaceBindingDigest
      ),
      (
        "agentModelCapabilityDigest",
        try current.agentModelCapabilityDigest,
        try stored.agentModelCapabilityDigest
      ),
      (
        "activeSkillSetDigest",
        try current.activeSkillSetDigest,
        try stored.activeSkillSetDigest
      ),
    ]
    for (field, actual, expected) in comparisons where actual != expected {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(field)
    }
    return TatwoRemoteDispatchReadinessObservationV1(
      targetWorkspaceBindingID: stored.workspaceBindingID,
      targetWorkspaceBindingDigest: try current.workspaceBindingDigest,
      agentModelCapabilityDigest: try current.agentModelCapabilityDigest,
      activeSkillSetDigest: try current.activeSkillSetDigest,
      readbackNonce: request.challengeNonce)
  }

  /// Resolve and bind a production agent job exclusively from target-owned,
  /// signed registry truth. Origin `workPath` is never consulted.
  public func resolveAndBindWorkspace(
    for job: TatwoLoopJobV1,
    agentEngine: TatwoAgentEngineBinding = .production,
    skilletStore: TatwoSkilletRepositoryStore
  ) throws -> TatwoBoundWorkPath {
    guard case let .tatwoLoop(payload) = job.payload,
      let agent = payload.agent,
      let exactModelRouteID = payload.exactModelRouteID,
      let locator = job.workspaceLocator,
      let binding = job.remoteDispatchReadiness
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingNotFound
    }
    try locator.validate()
    try binding.validate()
    guard locator.workspaceBindingID == binding.workspaceBindingID else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(
        "workspaceBindingID")
    }

    let registry = try loadVerified()
    guard registry.generation == locator.registryGeneration else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(
        "registryGeneration")
    }
    let matches = registry.entries.filter {
      $0.workspaceBindingID == locator.workspaceBindingID
        && $0.requestedAgent == agent
        && $0.exactModelRouteID == exactModelRouteID
    }
    guard !matches.isEmpty else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingNotFound
    }
    guard matches.count == 1, let stored = matches.first else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingAmbiguous
    }
    guard TatwoPathCanonical.filePath(stored.canonicalWorkspacePath)
      == stored.canonicalWorkspacePath
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(
        "canonicalWorkspacePath")
    }
    let current = try TatwoRemoteDispatchReadinessTargetSnapshotBuilderV1.build(
      workspaceBindingID: stored.workspaceBindingID,
      workspaceURL: URL(
        fileURLWithPath: stored.canonicalWorkspacePath,
        isDirectory: true),
      requestedAgent: stored.requestedAgent,
      exactModelRouteID: stored.exactModelRouteID,
      targetDeviceID: trust.localIdentity.deviceID,
      agentEngine: agentEngine,
      skilletStore: skilletStore,
      transportCapabilities: stored.transportCapabilities)
    let comparisons: [(String, String, String)] = [
      ("workspaceBindingDigest", try current.workspaceBindingDigest,
        binding.workspaceBindingDigest),
      ("agentModelCapabilityDigest", try current.agentModelCapabilityDigest,
        binding.agentModelCapabilityDigest),
      ("activeSkillSetDigest", try current.activeSkillSetDigest,
        binding.activeSkillSetDigest),
    ]
    for (field, actual, expected) in comparisons where actual != expected {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(field)
    }
    let bound = try TatwoBoundWorkPath.bind(
      URL(fileURLWithPath: stored.canonicalWorkspacePath, isDirectory: true))
    guard bound.deviceID == current.workspaceDigestInput.filesystemDeviceID,
      bound.fileID == current.workspaceDigestInput.filesystemInodeID,
      TatwoPathCanonical.filePath(try bound.currentPathString())
        == stored.canonicalWorkspacePath
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.bindingDrift(
        "workspaceFilesystemIdentity")
    }
    try bound.assertUnchanged()
    return bound
  }

  private func loadVerified() throws -> SignedRegistry.Unsigned {
    guard FileManager.default.fileExists(atPath: registryURL.path) else {
      throw TatwoRemoteDispatchReadinessRegistryError.registryMissing
    }
    let registry: SignedRegistry
    do {
      registry = try decode(
        SignedRegistry.self,
        from: Data(contentsOf: registryURL))
    } catch {
      throw TatwoRemoteDispatchReadinessRegistryError.registryCorrupt("decode")
    }
    guard registry.schema == SignedRegistry.schemaName,
      registry.unsigned.schema == SignedRegistry.schemaName,
      registry.unsigned.targetDeviceID == trust.localIdentity.deviceID,
      registry.unsigned.targetKeyID == trust.localIdentity.keyID,
      registry.unsigned.targetKeyGeneration == trust.localIdentity.keyGeneration,
      registry.unsigned.generation > 0,
      registry.targetSignature.signedAt
        == TatwoLoopJobChannelTrust.iso8601(registry.unsigned.updatedAt)
    else {
      throw TatwoRemoteDispatchReadinessRegistryError.registryCorrupt("scope")
    }
    do {
      try trust.verify(
        payload: try registry.unsigned.canonicalData(),
        purpose: .loopTargetReadiness,
        signature: registry.targetSignature,
        expectedDeviceID: trust.localIdentity.deviceID,
        enforceFreshness: false)
    } catch {
      throw TatwoRemoteDispatchReadinessRegistryError.signatureRejected
    }
    do {
      try registry.unsigned.entries.forEach { try $0.validate() }
    } catch {
      throw TatwoRemoteDispatchReadinessRegistryError.registryCorrupt("entry")
    }
    return registry.unsigned
  }

  private struct SignedRegistry: Codable {
    static let schemaName = "TatwoRemoteDispatchReadinessRegistryV1"
    let schema: String
    let unsigned: Unsigned
    let targetSignature: TatwoDeviceSignatureV1

    init(
      schema: String = Self.schemaName,
      unsigned: Unsigned,
      targetSignature: TatwoDeviceSignatureV1
    ) {
      self.schema = schema
      self.unsigned = unsigned
      self.targetSignature = targetSignature
    }

    struct Unsigned: Codable {
      let schema: String
      let targetDeviceID: String
      let targetKeyID: String
      let targetKeyGeneration: UInt64
      let generation: UInt64
      let updatedAt: Date
      let entries: [TatwoRemoteDispatchReadinessRegistryEntryV1]

      init(
        schema: String = SignedRegistry.schemaName,
        targetDeviceID: String,
        targetKeyID: String,
        targetKeyGeneration: UInt64,
        generation: UInt64,
        updatedAt: Date,
        entries: [TatwoRemoteDispatchReadinessRegistryEntryV1]
      ) {
        self.schema = schema
        self.targetDeviceID = targetDeviceID
        self.targetKeyID = targetKeyID
        self.targetKeyGeneration = targetKeyGeneration
        self.generation = generation
        self.updatedAt = updatedAt
        self.entries = entries
      }

      func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
      }
    }
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try TatwoAtomicFile.write(try encoder.encode(value), to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
}
