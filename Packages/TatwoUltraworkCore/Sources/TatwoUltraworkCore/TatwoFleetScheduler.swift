import Foundation
import TatwoDomainContracts

// MARK: - Errors

public enum TatwoFleetError: Error, LocalizedError, Sendable, Equatable {
  case invalidDevice(String)
  case invalidLogicalJob(String)
  case invalidAssignment(String)
  case deviceNotRegistered(String)
  case logicalJobNotFound(String)
  case logicalJobAlreadyExists(String)
  case logicalAlreadyCommitted(String)
  case missingFleetRoot
  case dispatchFailed(String)
  case invalidPayload(String)
  case missingAuthority(String)
  case signatureRejected(String)
  case bindingMismatch(String)
  case authorityFenced(String)

  public var errorDescription: String? {
    switch self {
    case let .invalidDevice(message):
      return "Fleet device invalid: \(message)"
    case let .invalidLogicalJob(message):
      return "Fleet logical job invalid: \(message)"
    case let .invalidAssignment(message):
      return "Fleet assignment invalid: \(message)"
    case let .deviceNotRegistered(deviceID):
      return "Fleet device not registered: \(deviceID)"
    case let .logicalJobNotFound(id):
      return "Fleet logical job not found: \(id)"
    case let .logicalJobAlreadyExists(id):
      return "Fleet logical job already exists: \(id)"
    case let .logicalAlreadyCommitted(id):
      return "Fleet logical job already committed: \(id)"
    case .missingFleetRoot:
      return "Fleet root is required"
    case let .dispatchFailed(message):
      return "Fleet dispatch failed: \(message)"
    case let .invalidPayload(message):
      return "Fleet payload invalid: \(message)"
    case let .missingAuthority(message):
      return "Fleet authority missing: \(message)"
    case let .signatureRejected(message):
      return "Fleet signature rejected: \(message)"
    case let .bindingMismatch(message):
      return "Fleet binding mismatch: \(message)"
    case let .authorityFenced(message):
      return "Fleet authority fenced: \(message)"
    }
  }
}

// MARK: - Models

public enum TatwoFleetLogicalJobStatusV1: String, Codable, Sendable, Equatable {
  case pending
  case assigned
  case committed
}

public enum TatwoFleetAssignmentStatusV1: String, Codable, Sendable, Equatable {
  case assigned
  case leaseExpired
  case committed
  case superseded
}

/// Target capacity + capability report.
///
/// Agents are **detected** at register time (executable whitelist), never trusted
/// from an unvalidated self-claim alone. Target emits target-signed envelopes to
/// `fleet/ingest/devices/`; origin promotes to origin-signed `fleet/devices/`.
public struct TatwoFleetDeviceV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let deviceID: String
  /// Detected agent executables present on the host.
  public let agents: [TatwoRemoteAgentKindV1]
  public let maxConcurrent: Int
  /// Currently occupied slots as reported by the target.
  public let inflight: Int
  /// Mini/origin compares this against mini clock for freshness.
  public let lastHeartbeatAt: Date
  public let authorityEpoch: UInt64
  public let originDeviceID: String
  public let ledgerSequence: UInt64

  public var id: String { deviceID }

  public init(
    schema: String = "TatwoFleetDeviceV1",
    deviceID: String,
    agents: [TatwoRemoteAgentKindV1],
    maxConcurrent: Int,
    inflight: Int,
    lastHeartbeatAt: Date,
    authorityEpoch: UInt64 = 0,
    originDeviceID: String = "",
    ledgerSequence: UInt64 = 0
  ) {
    self.schema = schema
    self.deviceID = deviceID
    self.agents = agents
    self.maxConcurrent = maxConcurrent
    self.inflight = inflight
    self.lastHeartbeatAt = lastHeartbeatAt
    self.authorityEpoch = authorityEpoch
    self.originDeviceID = originDeviceID
    self.ledgerSequence = ledgerSequence
  }

  public func validate() throws {
    guard schema == "TatwoFleetDeviceV1",
      TatwoLoopPathComponent.isValid(deviceID),
      maxConcurrent > 0,
      inflight >= 0
    else {
      throw TatwoFleetError.invalidDevice(deviceID)
    }
  }
}

/// Pending / in-progress logical work identity (exactly-once commit key).
public struct TatwoFleetLogicalJobV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let logicalJobID: String
  public let originDeviceID: String
  public let contractID: String
  public let goalID: String
  public let identity: IdentityKind
  public let workPath: String
  public let payload: TatwoLoopJobPayloadV1
  public let resourceCaps: TatwoLoopResourceCapsV1
  public let stopConditions: TatwoLoopStopConditionsV1
  public let requiredAgent: TatwoRemoteAgentKindV1?
  /// Target-scoped Chat/session authorization for a production agent job.
  ///
  /// The target is immutable while this logical job is pending or recovering:
  /// a grant for one device must never be rewritten and reused for another.
  public let remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1?
  /// Stable readiness expectations copied into each physical attempt.
  ///
  /// `challengeNonce` is only a serialized template value here. The scheduler
  /// always replaces it with a fresh nonce when minting a physical attempt.
  public let remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1?
  /// Target-owned workspace selector. It is valid only for the target bound by
  /// `remoteBorrowInvocation`.
  public let workspaceLocator: TatwoRemoteWorkspaceLocatorV1?
  public let status: TatwoFleetLogicalJobStatusV1
  public let enqueuedAt: Date
  public let updatedAt: Date
  public let authorityEpoch: UInt64
  public let ledgerSequence: UInt64

  public var id: String { logicalJobID }

  public init(
    schema: String = "TatwoFleetLogicalJobV1",
    logicalJobID: String,
    originDeviceID: String,
    contractID: String,
    goalID: String,
    identity: IdentityKind,
    workPath: String,
    payload: TatwoLoopJobPayloadV1,
    resourceCaps: TatwoLoopResourceCapsV1,
    stopConditions: TatwoLoopStopConditionsV1,
    requiredAgent: TatwoRemoteAgentKindV1?,
    remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1? = nil,
    remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1? = nil,
    workspaceLocator: TatwoRemoteWorkspaceLocatorV1? = nil,
    status: TatwoFleetLogicalJobStatusV1,
    enqueuedAt: Date,
    updatedAt: Date,
    authorityEpoch: UInt64 = 0,
    ledgerSequence: UInt64 = 0
  ) {
    self.schema = schema
    self.logicalJobID = logicalJobID
    self.originDeviceID = originDeviceID
    self.contractID = contractID
    self.goalID = goalID
    self.identity = identity
    self.workPath = workPath
    self.payload = payload
    self.resourceCaps = resourceCaps
    self.stopConditions = stopConditions
    self.requiredAgent = requiredAgent
    self.remoteBorrowInvocation = remoteBorrowInvocation
    self.remoteDispatchReadiness = remoteDispatchReadiness
    self.workspaceLocator = workspaceLocator
    self.status = status
    self.enqueuedAt = enqueuedAt
    self.updatedAt = updatedAt
    self.authorityEpoch = authorityEpoch
    self.ledgerSequence = ledgerSequence
  }

  public func validate() throws {
    let hasLegacyWorkPath = !workPath.isEmpty && !workPath.contains("\0")
    guard schema == "TatwoFleetLogicalJobV1",
      !logicalJobID.isEmpty,
      !logicalJobID.contains("\0"),
      TatwoLoopPathComponent.isValid(originDeviceID),
      !contractID.isEmpty,
      !goalID.isEmpty,
      hasLegacyWorkPath || workspaceLocator != nil
    else {
      throw TatwoFleetError.invalidLogicalJob(logicalJobID)
    }
    try resourceCaps.validate()
    try payload.validate()
    let productionFieldCount = [
      remoteBorrowInvocation != nil,
      remoteDispatchReadiness != nil,
      workspaceLocator != nil,
    ].filter { $0 }.count
    switch payload {
    case .shellSafe:
      guard productionFieldCount == 0, hasLegacyWorkPath else {
        throw TatwoFleetError.invalidLogicalJob(
          "shell-safe logical jobs cannot carry remote-agent bindings")
      }
    case .tatwoLoop(let loop):
      guard requiredAgent == loop.agent else {
        throw TatwoFleetError.invalidLogicalJob(
          "requiredAgent does not match tatwo-loop payload agent")
      }
      // All-nil remains the explicitly legacy/test-compatible path. Once any
      // production field is present, the complete target-scoped set is
      // required so a partial queue record cannot look dispatch-ready.
      guard productionFieldCount == 0 || productionFieldCount == 3 else {
        throw TatwoFleetError.invalidLogicalJob(
          "remote-agent logical jobs require borrow, readiness, and workspace bindings together")
      }
      if let remoteBorrowInvocation,
        let remoteDispatchReadiness,
        let workspaceLocator
      {
        try remoteBorrowInvocation.validate(
          targetDeviceID: remoteBorrowInvocation.targetDeviceID,
          contractID: contractID,
          goalID: goalID)
        try remoteDispatchReadiness.validate()
        try workspaceLocator.validate()
        guard workspaceLocator.workspaceBindingID
          == remoteDispatchReadiness.workspaceBindingID
        else {
          throw TatwoFleetError.invalidLogicalJob(
            "workspace locator does not match readiness binding")
        }
      } else {
        guard hasLegacyWorkPath else {
          throw TatwoFleetError.invalidLogicalJob(
            "legacy tatwo-loop logical jobs require workPath")
        }
      }
    }
  }

  /// A production remote-agent authorization is scoped to exactly one target.
  public var requiredTargetDeviceID: String? {
    remoteBorrowInvocation?.targetDeviceID
  }

  public func withStatus(
    _ status: TatwoFleetLogicalJobStatusV1,
    at now: Date,
    authorityEpoch: UInt64? = nil,
    ledgerSequence: UInt64? = nil
  ) -> TatwoFleetLogicalJobV1 {
    TatwoFleetLogicalJobV1(
      schema: schema,
      logicalJobID: logicalJobID,
      originDeviceID: originDeviceID,
      contractID: contractID,
      goalID: goalID,
      identity: identity,
      workPath: workPath,
      payload: payload,
      resourceCaps: resourceCaps,
      stopConditions: stopConditions,
      requiredAgent: requiredAgent,
      remoteBorrowInvocation: remoteBorrowInvocation,
      remoteDispatchReadiness: remoteDispatchReadiness,
      workspaceLocator: workspaceLocator,
      status: status,
      enqueuedAt: enqueuedAt,
      updatedAt: now,
      authorityEpoch: authorityEpoch ?? self.authorityEpoch,
      ledgerSequence: ledgerSequence ?? self.ledgerSequence)
  }
}

/// One physical attempt (jobID) for a logical job.
public struct TatwoFleetAssignmentV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let logicalJobID: String
  public let jobID: String
  public let dispatchNonce: String
  public let targetDeviceID: String
  public let originDeviceID: String
  /// Mini-side assign clock (lease judgements use mini clock only).
  public let assignedAt: Date
  public let leaseSeconds: TimeInterval
  public let attempt: Int
  public let status: TatwoFleetAssignmentStatusV1
  /// Required: binds commit gate to the signed physical job digest.
  public let jobCanonicalDigest: String
  public let dispatchRecordID: String?
  public let authorityEpoch: UInt64
  public let ledgerSequence: UInt64

  public var id: String { jobID }

  public init(
    schema: String = "TatwoFleetAssignmentV1",
    logicalJobID: String,
    jobID: String,
    dispatchNonce: String,
    targetDeviceID: String,
    originDeviceID: String,
    assignedAt: Date,
    leaseSeconds: TimeInterval,
    attempt: Int,
    status: TatwoFleetAssignmentStatusV1,
    jobCanonicalDigest: String,
    dispatchRecordID: String? = nil,
    authorityEpoch: UInt64 = 0,
    ledgerSequence: UInt64 = 0
  ) {
    self.schema = schema
    self.logicalJobID = logicalJobID
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.targetDeviceID = targetDeviceID
    self.originDeviceID = originDeviceID
    self.assignedAt = assignedAt
    self.leaseSeconds = leaseSeconds
    self.attempt = attempt
    self.status = status
    self.jobCanonicalDigest = jobCanonicalDigest
    self.dispatchRecordID = dispatchRecordID
    self.authorityEpoch = authorityEpoch
    self.ledgerSequence = ledgerSequence
  }

  public func validate() throws {
    guard schema == "TatwoFleetAssignmentV1",
      TatwoLoopPathComponent.isValid(jobID),
      TatwoLoopPathComponent.isValid(dispatchNonce),
      TatwoLoopPathComponent.isValid(targetDeviceID),
      TatwoLoopPathComponent.isValid(originDeviceID),
      !logicalJobID.isEmpty,
      !jobCanonicalDigest.isEmpty,
      leaseSeconds > 0,
      attempt >= 1
    else {
      throw TatwoFleetError.invalidAssignment(jobID)
    }
  }

  public func withStatus(
    _ status: TatwoFleetAssignmentStatusV1,
    authorityEpoch: UInt64? = nil,
    ledgerSequence: UInt64? = nil
  ) -> TatwoFleetAssignmentV1 {
    TatwoFleetAssignmentV1(
      schema: schema,
      logicalJobID: logicalJobID,
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      targetDeviceID: targetDeviceID,
      originDeviceID: originDeviceID,
      assignedAt: assignedAt,
      leaseSeconds: leaseSeconds,
      attempt: attempt,
      status: status,
      jobCanonicalDigest: jobCanonicalDigest,
      dispatchRecordID: dispatchRecordID,
      authorityEpoch: authorityEpoch ?? self.authorityEpoch,
      ledgerSequence: ledgerSequence ?? self.ledgerSequence)
  }

  public func leaseDeadline(graceSeconds: TimeInterval) -> Date {
    assignedAt.addingTimeInterval(leaseSeconds + max(0, graceSeconds))
  }
}

/// Exactly-once logical commit record (origin-signed, create-only + high-water).
public struct TatwoFleetLogicalCommitV1: Codable, Sendable, Equatable {
  public let schema: String
  public let logicalJobID: String
  public let winningJobID: String
  public let winningDispatchNonce: String
  public let targetDeviceID: String
  public let originDeviceID: String
  public let resultStatus: TatwoLoopJobStatusV1
  public let resultDigest: String?
  public let jobCanonicalDigest: String
  public let committedAt: Date
  public let authorityEpoch: UInt64
  public let ledgerSequence: UInt64

  public init(
    schema: String = "TatwoFleetLogicalCommitV1",
    logicalJobID: String,
    winningJobID: String,
    winningDispatchNonce: String,
    targetDeviceID: String,
    originDeviceID: String,
    resultStatus: TatwoLoopJobStatusV1,
    resultDigest: String?,
    jobCanonicalDigest: String,
    committedAt: Date,
    authorityEpoch: UInt64 = 0,
    ledgerSequence: UInt64 = 0
  ) {
    self.schema = schema
    self.logicalJobID = logicalJobID
    self.winningJobID = winningJobID
    self.winningDispatchNonce = winningDispatchNonce
    self.targetDeviceID = targetDeviceID
    self.originDeviceID = originDeviceID
    self.resultStatus = resultStatus
    self.resultDigest = resultDigest
    self.jobCanonicalDigest = jobCanonicalDigest
    self.committedAt = committedAt
    self.authorityEpoch = authorityEpoch
    self.ledgerSequence = ledgerSequence
  }
}

/// Late/duplicate attempt result rejected after a logical commit.
public struct TatwoFleetSupersededResultV1: Codable, Sendable, Equatable {
  public let schema: String
  public let logicalJobID: String
  public let jobID: String
  public let dispatchNonce: String
  public let winningJobID: String
  public let reason: String
  public let seenAt: Date
  public let authorityEpoch: UInt64
  public let originDeviceID: String
  public let ledgerSequence: UInt64

  public init(
    schema: String = "TatwoFleetSupersededResultV1",
    logicalJobID: String,
    jobID: String,
    dispatchNonce: String,
    winningJobID: String,
    reason: String,
    seenAt: Date,
    authorityEpoch: UInt64 = 0,
    originDeviceID: String = "",
    ledgerSequence: UInt64 = 0
  ) {
    self.schema = schema
    self.logicalJobID = logicalJobID
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.winningJobID = winningJobID
    self.reason = reason
    self.seenAt = seenAt
    self.authorityEpoch = authorityEpoch
    self.originDeviceID = originDeviceID
    self.ledgerSequence = ledgerSequence
  }
}

public struct TatwoFleetSchedulerStateV1: Codable, Sendable, Equatable {
  public let schema: String
  /// Last device chosen by round-robin (deviceID); next pick is after this in sorted order.
  public let roundRobinCursorDeviceID: String?
  public let authorityEpoch: UInt64
  public let originDeviceID: String
  public let ledgerSequence: UInt64

  public init(
    schema: String = "TatwoFleetSchedulerStateV1",
    roundRobinCursorDeviceID: String? = nil,
    authorityEpoch: UInt64 = 0,
    originDeviceID: String = "",
    ledgerSequence: UInt64 = 0
  ) {
    self.schema = schema
    self.roundRobinCursorDeviceID = roundRobinCursorDeviceID
    self.authorityEpoch = authorityEpoch
    self.originDeviceID = originDeviceID
    self.ledgerSequence = ledgerSequence
  }
}

public struct TatwoFleetTickResultV1: Codable, Sendable, Equatable {
  public let schema: String
  public let assigned: [TatwoFleetAssignmentV1]
  public let leaseRecoveries: [TatwoFleetAssignmentV1]
  public let commits: [TatwoFleetLogicalCommitV1]
  public let superseded: [TatwoFleetSupersededResultV1]
  public let pendingRemaining: Int
  public let skippedFullCapacity: Int
  public let skippedStaleHeartbeat: Int
  public let skippedMissingCapability: Int
  public let ingestedDevices: Int

  public init(
    schema: String = "TatwoFleetTickResultV1",
    assigned: [TatwoFleetAssignmentV1],
    leaseRecoveries: [TatwoFleetAssignmentV1],
    commits: [TatwoFleetLogicalCommitV1],
    superseded: [TatwoFleetSupersededResultV1],
    pendingRemaining: Int,
    skippedFullCapacity: Int,
    skippedStaleHeartbeat: Int,
    skippedMissingCapability: Int,
    ingestedDevices: Int = 0
  ) {
    self.schema = schema
    self.assigned = assigned
    self.leaseRecoveries = leaseRecoveries
    self.commits = commits
    self.superseded = superseded
    self.pendingRemaining = pendingRemaining
    self.skippedFullCapacity = skippedFullCapacity
    self.skippedStaleHeartbeat = skippedStaleHeartbeat
    self.skippedMissingCapability = skippedMissingCapability
    self.ingestedDevices = ingestedDevices
  }
}

public struct TatwoFleetStatusV1: Codable, Sendable, Equatable {
  public let schema: String
  public let devices: [TatwoFleetDeviceV1]
  public let pendingCount: Int
  public let assignedCount: Int
  public let inFlightCount: Int
  public let committedCount: Int
  public let supersededCount: Int
  public let assignments: [TatwoFleetAssignmentV1]
  public let commits: [TatwoFleetLogicalCommitV1]

  public init(
    schema: String = "TatwoFleetStatusV1",
    devices: [TatwoFleetDeviceV1],
    pendingCount: Int,
    assignedCount: Int,
    inFlightCount: Int,
    committedCount: Int,
    supersededCount: Int,
    assignments: [TatwoFleetAssignmentV1],
    commits: [TatwoFleetLogicalCommitV1]
  ) {
    self.schema = schema
    self.devices = devices
    self.pendingCount = pendingCount
    self.assignedCount = assignedCount
    self.inFlightCount = inFlightCount
    self.committedCount = committedCount
    self.supersededCount = supersededCount
    self.assignments = assignments
    self.commits = commits
  }
}

public struct TatwoFleetTickConfigV1: Sendable, Equatable {
  public var leaseSeconds: TimeInterval
  /// Extra mini-clock slack so modest clock skew does not thrash recoveries.
  public var leaseGraceSeconds: TimeInterval
  public var heartbeatMaxAgeSeconds: TimeInterval

  public init(
    leaseSeconds: TimeInterval = 300,
    leaseGraceSeconds: TimeInterval = 30,
    heartbeatMaxAgeSeconds: TimeInterval = 90
  ) {
    self.leaseSeconds = leaseSeconds
    self.leaseGraceSeconds = leaseGraceSeconds
    self.heartbeatMaxAgeSeconds = heartbeatMaxAgeSeconds
  }
}

/// Dispatch receipt returned by the injected production dispatch path.
public struct TatwoFleetDispatchReceiptV1: Sendable, Equatable {
  public let jobID: String
  public let dispatchNonce: String
  public let targetDeviceID: String
  public let jobCanonicalDigest: String
  public let dispatchRecordID: String

  public init(
    jobID: String,
    dispatchNonce: String,
    targetDeviceID: String,
    jobCanonicalDigest: String,
    dispatchRecordID: String
  ) {
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.targetDeviceID = targetDeviceID
    self.jobCanonicalDigest = jobCanonicalDigest
    self.dispatchRecordID = dispatchRecordID
  }
}

public typealias TatwoFleetDispatchHandler =
  @Sendable (TatwoLoopJobV1) throws -> TatwoFleetDispatchReceiptV1
public typealias TatwoFleetResultProbe =
  @Sendable (String) throws -> TatwoLoopJobResultReceiptV1?
/// Verified signed-job loader for commit binding (logical/origin/target/digest).
/// Failures must throw — never return nil for a missing job.
public typealias TatwoFleetSignedJobProbe =
  @Sendable (String) throws -> TatwoLoopJobV1

// MARK: - Store

/// File layout under `fleetRoot`:
/// ```
/// ingest/devices/<deviceID>.json   // target-signed only; target→origin pull
/// devices/<deviceID>.json          // origin-signed accepted view
/// queue/<logical>.json             // origin-signed
/// assignments/<jobID>.json         // origin-signed
/// commits/<logical>.json           // origin-signed create-only
/// ledger/<sequence>.json           // origin-signed append-only
/// high-water/                      // authority + commit high-water (not bi-synced)
/// superseded/<jobID>.json
/// scheduler-state.json             // origin-local; never bi-synced
/// tick.json
/// ```
///
/// **Sync rule:** only `ingest/` may be pulled target→origin. Never bi-sync
/// queue/assignments/commits/ledger/devices/scheduler-state/high-water.
public struct TatwoFleetStore: Sendable {
  public let rootURL: URL
  public let originAuthority: TatwoFleetOriginAuthority?
  public let originAuthorityProvider: any TatwoOriginAuthorityProviding

  public init(
    rootURL: URL,
    originAuthority: TatwoFleetOriginAuthority? = nil,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.originAuthority = originAuthority
    self.originAuthorityProvider =
      originAuthorityProvider ?? TatwoDefaultOriginAuthorityProvider()
  }

  /// Default: `<channelRoot>/fleet`.
  public static func underChannelRoot(
    _ channelRoot: URL,
    originAuthority: TatwoFleetOriginAuthority? = nil,
    originAuthorityProvider: (any TatwoOriginAuthorityProviding)? = nil
  ) -> TatwoFleetStore {
    TatwoFleetStore(
      rootURL: channelRoot.appendingPathComponent("fleet", isDirectory: true),
      originAuthority: originAuthority,
      originAuthorityProvider: originAuthorityProvider)
  }

  public var devicesDirectory: URL {
    rootURL.appendingPathComponent("devices", isDirectory: true)
  }

  public var ingestDevicesDirectory: URL {
    rootURL
      .appendingPathComponent("ingest", isDirectory: true)
      .appendingPathComponent("devices", isDirectory: true)
  }

  public var queueDirectory: URL {
    rootURL.appendingPathComponent("queue", isDirectory: true)
  }

  public var assignmentsDirectory: URL {
    rootURL.appendingPathComponent("assignments", isDirectory: true)
  }

  public var commitsDirectory: URL {
    rootURL.appendingPathComponent("commits", isDirectory: true)
  }

  public var ledgerDirectory: URL {
    rootURL.appendingPathComponent("ledger", isDirectory: true)
  }

  public var supersededDirectory: URL {
    rootURL.appendingPathComponent("superseded", isDirectory: true)
  }

  public var schedulerStateURL: URL {
    rootURL.appendingPathComponent("scheduler-state.json")
  }

  public var tickLockURL: URL {
    rootURL.appendingPathComponent("tick.json")
  }

  public func ensureLayout() throws {
    let fm = FileManager.default
    for dir in [
      rootURL, devicesDirectory, ingestDevicesDirectory, queueDirectory,
      assignmentsDirectory, commitsDirectory, ledgerDirectory, supersededDirectory,
    ] {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  private func requireOrigin() throws -> TatwoFleetOriginAuthority {
    guard let originAuthority else {
      throw TatwoFleetError.missingAuthority("origin authority required for fleet control-plane")
    }
    return originAuthority
  }

  private func requireOriginMutation(
    _ origin: TatwoFleetOriginAuthority,
    surface: String,
    now: Date
  ) throws {
    try originAuthorityProvider.requireOriginAuthority(
      deviceID: origin.originDeviceID,
      epoch: origin.authorityEpoch,
      surface: surface,
      now: now)
  }

  // MARK: Devices (origin-signed accepted view)

  public func deviceURL(for deviceID: String) -> URL {
    devicesDirectory.appendingPathComponent("\(TatwoLoopPathComponent.sanitize(deviceID)).json")
  }

  public func ingestDeviceURL(for deviceID: String) -> URL {
    ingestDevicesDirectory.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(deviceID)).json")
  }

  /// Origin-signed write of an accepted device view (after verifying target report).
  public func writeDevice(_ device: TatwoFleetDeviceV1) throws {
    try device.validate()
    try ensureLayout()
    let origin = try requireOrigin()
    try requireOriginMutation(
      origin,
      surface: "fleet_device_write",
      now: Date())
    let seq = try origin.nextLedgerSequence()
    var stamped = device
    stamped = TatwoFleetDeviceV1(
      deviceID: device.deviceID,
      agents: device.agents,
      maxConcurrent: device.maxConcurrent,
      inflight: device.inflight,
      lastHeartbeatAt: device.lastHeartbeatAt,
      authorityEpoch: origin.authorityEpoch,
      originDeviceID: origin.originDeviceID,
      ledgerSequence: seq)
    try writeOriginEnvelope(
      stamped, purpose: .device, recordID: stamped.deviceID, ledgerSequence: seq,
      to: deviceURL(for: stamped.deviceID))
  }

  /// Target-signed ingest write (never origin control-plane state).
  public func writeTargetDeviceIngest(
    _ device: TatwoFleetDeviceV1,
    signer: TatwoFleetTargetSigner
  ) throws {
    try device.validate()
    try ensureLayout()
    let envelope = try signer.sealDeviceReport(device)
    try writeEnvelope(envelope, to: ingestDeviceURL(for: device.deviceID))
  }

  /// Whether a target ingest envelope exists (presence only — not capability truth).
  public func hasIngestDevice(deviceID: String) -> Bool {
    FileManager.default.fileExists(atPath: ingestDeviceURL(for: deviceID).path)
  }

  /// Read last target ingest body **only after** full target signature +
  /// signer/device/path/body four-way binding. Never decode untrusted body for
  /// capability/capacity inheritance.
  public func loadVerifiedIngestDeviceBody(
    deviceID: String,
    trust: TatwoLoopJobChannelTrust,
    expectedOriginDeviceID: String
  ) throws -> TatwoFleetDeviceV1? {
    let url = ingestDeviceURL(for: deviceID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let envelope = try? JSONDecoder.fleet.decode(
      TatwoFleetSignedEnvelopeV1.self, from: data)
    else {
      throw TatwoFleetError.signatureRejected(
        "unsigned or non-envelope device ingest at \(url.lastPathComponent)")
    }
    let pathRelative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: rootURL)
    let pathDeviceID = url.deletingPathExtension().lastPathComponent
    let expectedIdentity = TatwoFleetRecordIdentityV1(
      purpose: .deviceReport,
      canonicalRelativePath: pathRelative,
      originDeviceID: envelope.originDeviceID,
      ledgerSequence: envelope.ledgerSequence,
      authorityEpoch: envelope.authorityEpoch)
    // Path-derived identity must match signed envelope fields.
    guard envelope.purpose == TatwoFleetSignaturePurposeV1.deviceReport.rawValue,
      envelope.canonicalRelativePath == pathRelative,
      envelope.recordID == pathDeviceID,
      envelope.originDeviceID == expectedOriginDeviceID
    else {
      throw TatwoFleetError.bindingMismatch(
        "device ingest path/purpose/origin bind failed at \(pathRelative)")
    }
    guard envelope.bodyDigest == TatwoLoopJobDigest.sha256(envelope.body) else {
      throw TatwoFleetError.signatureRejected("device ingest body digest mismatch")
    }
    let signerID = envelope.authorization.deviceID
    let pinned = trust.pinnedIdentities[signerID] ?? {
      trust.localIdentity.deviceID == signerID ? trust.localIdentity : nil
    }()
    guard let pinned else {
      throw TatwoFleetError.signatureRejected(
        "device ingest signer \(signerID) not pinned/local")
    }
    let sealMaterial = try TatwoFleetOriginAuthority.encodeBody(
      TatwoFleetSealMaterialV2(
        identity: expectedIdentity,
        recordID: envelope.recordID,
        bodyDigest: envelope.bodyDigest))
    do {
      try TatwoDeviceTrustAuthority.verify(
        payload: sealMaterial,
        purpose: TatwoFleetSignaturePurposeV1.deviceReport.rawValue,
        signature: envelope.authorization,
        pinnedIdentity: pinned)
    } catch {
      throw TatwoFleetError.signatureRejected(
        "device ingest signature rejected: \(error)")
    }
    // Seal material identity fields must match envelope.recordIdentity too.
    let got = envelope.recordIdentity
    guard got.recordKind == expectedIdentity.recordKind,
      got.canonicalRelativePath == expectedIdentity.canonicalRelativePath,
      got.originDeviceID == expectedIdentity.originDeviceID,
      got.ledgerSequence == expectedIdentity.ledgerSequence,
      got.authorityEpoch == expectedIdentity.authorityEpoch
    else {
      throw TatwoFleetError.bindingMismatch(
        "device ingest signed identity mismatch at \(pathRelative)")
    }
    let report = try envelope.decodeBody(TatwoFleetDeviceV1.self)
    try report.validate()
    // Four-way: signer, body.deviceID, envelope.recordID, path-derived id.
    guard report.deviceID == signerID,
      report.deviceID == envelope.recordID,
      report.deviceID == pathDeviceID,
      report.deviceID == deviceID
    else {
      throw TatwoFleetError.bindingMismatch(
        "device ingest id \(report.deviceID) must equal signer \(signerID), "
          + "recordID \(envelope.recordID), path \(pathDeviceID), query \(deviceID)")
    }
    return report
  }

  /// - Warning: Unverified decode. Prefer `loadVerifiedIngestDeviceBody` for any
  ///   capability/capacity decision. Kept only for diagnostic callers that must not
  ///   treat the body as authoritative.
  public func loadIngestDeviceBody(deviceID: String) throws -> TatwoFleetDeviceV1? {
    let url = ingestDeviceURL(for: deviceID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let envelope = try readEnvelope(from: url)
    return try envelope.decodeBody(TatwoFleetDeviceV1.self)
  }

  public func loadDevice(deviceID: String) throws -> TatwoFleetDeviceV1? {
    let url = deviceURL(for: deviceID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let origin = try requireOrigin()
    return try readOriginEnvelope(
      TatwoFleetDeviceV1.self, purpose: .device, expectedSigner: origin.originDeviceID, from: url)
  }

  public func listDevices() throws -> [TatwoFleetDeviceV1] {
    try ensureLayout()
    let origin = try requireOrigin()
    let urls = try listJSONFiles(in: devicesDirectory)
    var devices: [TatwoFleetDeviceV1] = []
    for url in urls {
      let device = try readOriginEnvelope(
        TatwoFleetDeviceV1.self, purpose: .device, expectedSigner: origin.originDeviceID,
        from: url)
      try device.validate()
      devices.append(device)
    }
    return devices.sorted { $0.deviceID < $1.deviceID }
  }

  /// Ingest all target-signed device reports; promote to origin-signed devices.
  @discardableResult
  public func ingestTargetDeviceReports() throws -> Int {
    try ensureLayout()
    let origin = try requireOrigin()
    let urls = try listJSONFiles(in: ingestDevicesDirectory)
    var count = 0
    for url in urls {
      let envelope = try readEnvelope(from: url)
      let pathRelative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: rootURL)
      let pathDeviceID = url.deletingPathExtension().lastPathComponent
      let expectedIdentity = TatwoFleetRecordIdentityV1(
        purpose: .deviceReport,
        canonicalRelativePath: pathRelative,
        originDeviceID: envelope.originDeviceID,
        ledgerSequence: envelope.ledgerSequence,
        authorityEpoch: envelope.authorityEpoch)
      try origin.verifyEnvelope(
        envelope,
        expectedPurpose: .deviceReport,
        expectedSignerDeviceID: envelope.authorization.deviceID,
        expectedIdentity: expectedIdentity)
      let report = try envelope.decodeBody(TatwoFleetDeviceV1.self)
      try report.validate()
      // AND binding: signer, body, envelope recordID, and path-derived ID must agree.
      guard report.deviceID == envelope.authorization.deviceID
        && report.deviceID == envelope.recordID
        && report.deviceID == pathDeviceID
      else {
        throw TatwoFleetError.bindingMismatch(
          "device report id \(report.deviceID) must equal signer \(envelope.authorization.deviceID), "
            + "recordID \(envelope.recordID), and path \(pathDeviceID)")
      }
      try writeDevice(report)
      count += 1
    }
    return count
  }

  // MARK: Queue

  public func queueURL(for logicalJobID: String) -> URL {
    queueDirectory.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(logicalJobID)).json")
  }

  public func writeLogicalJob(_ job: TatwoFleetLogicalJobV1) throws {
    try job.validate()
    try ensureLayout()
    let origin = try requireOrigin()
    guard job.originDeviceID == origin.originDeviceID else {
      throw TatwoFleetError.bindingMismatch(
        "logical job origin \(job.originDeviceID) != authority \(origin.originDeviceID)")
    }
    try requireOriginMutation(
      origin,
      surface: "fleet_logical_job_write",
      now: Date())
    let seq = try origin.nextLedgerSequence()
    let stamped = TatwoFleetLogicalJobV1(
      schema: job.schema,
      logicalJobID: job.logicalJobID,
      originDeviceID: job.originDeviceID,
      contractID: job.contractID,
      goalID: job.goalID,
      identity: job.identity,
      workPath: job.workPath,
      payload: job.payload,
      resourceCaps: job.resourceCaps,
      stopConditions: job.stopConditions,
      requiredAgent: job.requiredAgent,
      remoteBorrowInvocation: job.remoteBorrowInvocation,
      remoteDispatchReadiness: job.remoteDispatchReadiness,
      workspaceLocator: job.workspaceLocator,
      status: job.status,
      enqueuedAt: job.enqueuedAt,
      updatedAt: job.updatedAt,
      authorityEpoch: origin.authorityEpoch,
      ledgerSequence: seq)
    try writeOriginEnvelope(
      stamped, purpose: .queue, recordID: stamped.logicalJobID, ledgerSequence: seq,
      to: queueURL(for: stamped.logicalJobID))
  }

  public func loadLogicalJob(logicalJobID: String) throws -> TatwoFleetLogicalJobV1? {
    let url = queueURL(for: logicalJobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let origin = try requireOrigin()
    return try readOriginEnvelope(
      TatwoFleetLogicalJobV1.self, purpose: .queue, expectedSigner: origin.originDeviceID,
      from: url)
  }

  public func listLogicalJobs() throws -> [TatwoFleetLogicalJobV1] {
    try ensureLayout()
    let origin = try requireOrigin()
    let urls = try listJSONFiles(in: queueDirectory)
    var jobs: [TatwoFleetLogicalJobV1] = []
    for url in urls {
      let job = try readOriginEnvelope(
        TatwoFleetLogicalJobV1.self, purpose: .queue, expectedSigner: origin.originDeviceID,
        from: url)
      try job.validate()
      jobs.append(job)
    }
    return jobs.sorted {
      if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
      return $0.logicalJobID < $1.logicalJobID
    }
  }

  // MARK: Assignments

  public func assignmentURL(for jobID: String) -> URL {
    assignmentsDirectory.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).json")
  }

  public func writeAssignment(_ assignment: TatwoFleetAssignmentV1) throws {
    try assignment.validate()
    try ensureLayout()
    let origin = try requireOrigin()
    guard assignment.originDeviceID == origin.originDeviceID else {
      throw TatwoFleetError.bindingMismatch(
        "assignment origin \(assignment.originDeviceID) != authority \(origin.originDeviceID)")
    }
    try requireOriginMutation(
      origin,
      surface: "fleet_assignment_write",
      now: Date())
    let seq = try origin.nextLedgerSequence()
    let stamped = assignment.withStatus(
      assignment.status,
      authorityEpoch: origin.authorityEpoch,
      ledgerSequence: seq)
    try writeOriginEnvelope(
      stamped, purpose: .assignment, recordID: stamped.jobID, ledgerSequence: seq,
      to: assignmentURL(for: stamped.jobID))
  }

  public func loadAssignment(jobID: String) throws -> TatwoFleetAssignmentV1? {
    let url = assignmentURL(for: jobID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let origin = try requireOrigin()
    return try readOriginEnvelope(
      TatwoFleetAssignmentV1.self, purpose: .assignment,
      expectedSigner: origin.originDeviceID, from: url)
  }

  public func listAssignments() throws -> [TatwoFleetAssignmentV1] {
    try ensureLayout()
    let origin = try requireOrigin()
    let urls = try listJSONFiles(in: assignmentsDirectory)
    var items: [TatwoFleetAssignmentV1] = []
    for url in urls {
      let item = try readOriginEnvelope(
        TatwoFleetAssignmentV1.self, purpose: .assignment,
        expectedSigner: origin.originDeviceID, from: url)
      try item.validate()
      items.append(item)
    }
    return items.sorted {
      if $0.assignedAt != $1.assignedAt { return $0.assignedAt < $1.assignedAt }
      return $0.jobID < $1.jobID
    }
  }

  // MARK: Commits (create-only + high-water)

  public func commitURL(for logicalJobID: String) -> URL {
    commitsDirectory.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(logicalJobID)).json")
  }

  public func loadCommit(logicalJobID: String) throws -> TatwoFleetLogicalCommitV1? {
    let origin = try requireOrigin()
    let hw = try origin.highWater.loadCommitHighWater(logicalJobID: logicalJobID)
    let url = commitURL(for: logicalJobID)
    let fileExists = FileManager.default.fileExists(atPath: url.path)

    if let hw, !fileExists {
      // Fail closed: durable high-water says committed but file is gone (deletion attack).
      throw TatwoFleetAuthorityError.commitHighWaterWithoutFile(logicalJobID)
    }
    if !fileExists { return nil }
    // Fail closed: file without durable marker (partial publish or marker wipe).
    guard let hw else {
      throw TatwoFleetAuthorityError.commitFileWithoutHighWater(logicalJobID)
    }

    let commit = try readOriginEnvelope(
      TatwoFleetLogicalCommitV1.self, purpose: .commit,
      expectedSigner: origin.originDeviceID, from: url)
    let digest = try TatwoLoopJobDigest.canonicalJSONDigest(commit)
    guard hw.commitDigest == digest,
      hw.winningJobID == commit.winningJobID,
      hw.winningDispatchNonce == commit.winningDispatchNonce,
      hw.jobCanonicalDigest == commit.jobCanonicalDigest,
      hw.ledgerSequence == commit.ledgerSequence,
      hw.authorityEpoch == commit.authorityEpoch
    else {
      throw TatwoFleetAuthorityError.commitHighWaterMismatch(logicalJobID)
    }
    return commit
  }

  public func listCommits() throws -> [TatwoFleetLogicalCommitV1] {
    try ensureLayout()
    let origin = try requireOrigin()
    let urls = try listJSONFiles(in: commitsDirectory)
    // Every commit file must pass the durable high-water gate (no fail-open listing).
    var items: [TatwoFleetLogicalCommitV1] = []
    for url in urls {
      let body = try readOriginEnvelope(
        TatwoFleetLogicalCommitV1.self, purpose: .commit,
        expectedSigner: origin.originDeviceID, from: url)
      guard let verified = try loadCommit(logicalJobID: body.logicalJobID) else {
        throw TatwoFleetAuthorityError.commitFileWithoutHighWater(body.logicalJobID)
      }
      items.append(verified)
    }
    return items.sorted { $0.logicalJobID < $1.logicalJobID }
  }

  /// Exactly-once logical commit fence: durable high-water first, then create-only file.
  ///
  /// Publish order is reserve-marker → file. Partial failure stays fail closed:
  /// marker without file is rejected by `loadCommit`; file without marker is rejected.
  ///
  /// - Returns: `(commit, created)` where `created == false` means an existing
  ///   commit was loaded (caller must treat its own attempt as superseded if different).
  @discardableResult
  public func commitLogical(
    _ commit: TatwoFleetLogicalCommitV1
  ) throws -> (commit: TatwoFleetLogicalCommitV1, created: Bool) {
    try ensureLayout()
    let origin = try requireOrigin()
    try origin.assertWritable()
    try originAuthorityProvider.requireOriginAuthority(
      deviceID: origin.originDeviceID,
      epoch: origin.authorityEpoch,
      surface: "fleet_logical_commit",
      now: Date())

    // High-water present without file → fail closed (do not swallow with try?).
    if let existing = try loadCommit(logicalJobID: commit.logicalJobID) {
      return (existing, false)
    }

    let seq = try origin.nextLedgerSequence()
    let stamped = TatwoFleetLogicalCommitV1(
      logicalJobID: commit.logicalJobID,
      winningJobID: commit.winningJobID,
      winningDispatchNonce: commit.winningDispatchNonce,
      targetDeviceID: commit.targetDeviceID,
      originDeviceID: origin.originDeviceID,
      resultStatus: commit.resultStatus,
      resultDigest: commit.resultDigest,
      jobCanonicalDigest: commit.jobCanonicalDigest,
      committedAt: commit.committedAt,
      authorityEpoch: origin.authorityEpoch,
      ledgerSequence: seq)
    let commitDigest = try TatwoLoopJobDigest.canonicalJSONDigest(stamped)
    let highWater = TatwoFleetCommitHighWaterV1(
      logicalJobID: stamped.logicalJobID,
      ledgerSequence: stamped.ledgerSequence,
      authorityEpoch: stamped.authorityEpoch,
      originDeviceID: stamped.originDeviceID,
      winningJobID: stamped.winningJobID,
      winningDispatchNonce: stamped.winningDispatchNonce,
      jobCanonicalDigest: stamped.jobCanonicalDigest,
      commitDigest: commitDigest,
      committedAt: stamped.committedAt)

    // 1) Reserve durable fence BEFORE publishing the commit file.
    try origin.highWater.createCommitHighWater(highWater)

    // 2) Publish signed create-only file. If this fails, marker remains and load fails closed.
    let url = commitURL(for: stamped.logicalJobID)
    let relative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: rootURL)
    let envelope = try origin.sealEncodable(
      stamped,
      purpose: .commit,
      recordID: stamped.logicalJobID,
      ledgerSequence: seq,
      canonicalRelativePath: relative)
    let data = try Self.encodeJSON(envelope)
    var loaded: TatwoFleetLogicalCommitV1?
    try TatwoCreateOnlyFile.write(data, to: url) {
      loaded = try readOriginEnvelope(
        TatwoFleetLogicalCommitV1.self, purpose: .commit,
        expectedSigner: origin.originDeviceID, from: url)
    }
    if let existing = loaded {
      // Race: file already present. Accept only if it matches the reserved durable fence.
      let existingDigest = try TatwoLoopJobDigest.canonicalJSONDigest(existing)
      guard existingDigest == commitDigest,
        existing.winningJobID == stamped.winningJobID,
        existing.winningDispatchNonce == stamped.winningDispatchNonce,
        existing.ledgerSequence == stamped.ledgerSequence
      else {
        throw TatwoFleetAuthorityError.commitHighWaterMismatch(stamped.logicalJobID)
      }
      return (existing, false)
    }

    try appendLedger(
      purpose: .commit, recordID: stamped.logicalJobID, bodyDigest: envelope.bodyDigest,
      ledgerSequence: seq)
    try origin.advanceHighWater(ledgerSequence: seq)
    return (stamped, true)
  }

  // MARK: Superseded

  public func supersededURL(for jobID: String) -> URL {
    supersededDirectory.appendingPathComponent(
      "\(TatwoLoopPathComponent.sanitize(jobID)).json")
  }

  public func writeSuperseded(_ entry: TatwoFleetSupersededResultV1) throws {
    try ensureLayout()
    let origin = try requireOrigin()
    try requireOriginMutation(
      origin,
      surface: "fleet_superseded_write",
      now: Date())
    let seq = try origin.nextLedgerSequence()
    let stamped = TatwoFleetSupersededResultV1(
      logicalJobID: entry.logicalJobID,
      jobID: entry.jobID,
      dispatchNonce: entry.dispatchNonce,
      winningJobID: entry.winningJobID,
      reason: entry.reason,
      seenAt: entry.seenAt,
      authorityEpoch: origin.authorityEpoch,
      originDeviceID: origin.originDeviceID,
      ledgerSequence: seq)
    let url = supersededURL(for: stamped.jobID)
    let relative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: rootURL)
    let envelope = try origin.sealEncodable(
      stamped,
      purpose: .superseded,
      recordID: stamped.jobID,
      ledgerSequence: seq,
      canonicalRelativePath: relative)
    let data = try Self.encodeJSON(envelope)
    // Create-only fence. First writer owns `seq` and must finalize ledger binding
    // before any read path: exact ledger proof rejects envelopes without a matching row.
    // Do NOT call readOriginEnvelope on our own fresh write before appendLedger —
    // that was the R1 regression (orphan reject on the normal superseded path).
    var alreadyPresent = false
    try TatwoCreateOnlyFile.write(data, to: url) {
      alreadyPresent = true
    }
    if alreadyPresent {
      // Idempotent re-mark: prior file must already be fully ledger-bound.
      // Sequence we reserved was never published; nextLedgerSequence stays reusable.
      _ = try readOriginEnvelope(
        TatwoFleetSupersededResultV1.self, purpose: .superseded,
        expectedSigner: origin.originDeviceID, from: url)
      return
    }
    // Same durable order as writeOriginEnvelope: path HW → ledger row → global HW.
    try origin.highWater.storePathHighWater(
      TatwoFleetPathHighWaterV1(
        purpose: TatwoFleetSignaturePurposeV1.superseded.rawValue,
        canonicalRelativePath: relative,
        recordID: stamped.jobID,
        ledgerSequence: seq,
        bodyDigest: envelope.bodyDigest,
        authorityEpoch: origin.authorityEpoch,
        updatedAt: origin.now()))
    try appendLedger(
      purpose: .superseded, recordID: stamped.jobID, bodyDigest: envelope.bodyDigest,
      ledgerSequence: seq)
    try origin.advanceHighWater(ledgerSequence: seq)
  }

  public func listSuperseded() throws -> [TatwoFleetSupersededResultV1] {
    try ensureLayout()
    let origin = try requireOrigin()
    let urls = try listJSONFiles(in: supersededDirectory)
    return try urls.map {
      try readOriginEnvelope(
        TatwoFleetSupersededResultV1.self, purpose: .superseded,
        expectedSigner: origin.originDeviceID, from: $0)
    }
    .sorted { $0.jobID < $1.jobID }
  }

  // MARK: Scheduler state (origin-local; signed; never bi-synced)

  public func loadSchedulerState() throws -> TatwoFleetSchedulerStateV1 {
    try ensureLayout()
    guard FileManager.default.fileExists(atPath: schedulerStateURL.path) else {
      return TatwoFleetSchedulerStateV1()
    }
    let origin = try requireOrigin()
    return try readOriginEnvelope(
      TatwoFleetSchedulerStateV1.self, purpose: .schedulerState,
      expectedSigner: origin.originDeviceID, from: schedulerStateURL)
  }

  public func writeSchedulerState(_ state: TatwoFleetSchedulerStateV1) throws {
    try ensureLayout()
    let origin = try requireOrigin()
    let seq = try origin.nextLedgerSequence()
    let stamped = TatwoFleetSchedulerStateV1(
      roundRobinCursorDeviceID: state.roundRobinCursorDeviceID,
      authorityEpoch: origin.authorityEpoch,
      originDeviceID: origin.originDeviceID,
      ledgerSequence: seq)
    try writeOriginEnvelope(
      stamped, purpose: .schedulerState, recordID: "scheduler-state", ledgerSequence: seq,
      to: schedulerStateURL)
  }

  // MARK: Envelope IO

  private func writeOriginEnvelope<T: Encodable>(
    _ value: T,
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    ledgerSequence: UInt64,
    to url: URL
  ) throws {
    let origin = try requireOrigin()
    try requireOriginMutation(
      origin,
      surface: "fleet_\(purpose.rawValue)_write",
      now: origin.now())
    let relative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: rootURL)
    let envelope = try origin.sealEncodable(
      value,
      purpose: purpose,
      recordID: recordID,
      ledgerSequence: ledgerSequence,
      canonicalRelativePath: relative)
    try writeEnvelope(envelope, to: url)
    // Durable per-path high-water before/with global advance so same-path replay
    // of a lower-sequence envelope is rejected even if the file is restored.
    try origin.highWater.storePathHighWater(
      TatwoFleetPathHighWaterV1(
        purpose: purpose.rawValue,
        canonicalRelativePath: relative,
        recordID: recordID,
        ledgerSequence: ledgerSequence,
        bodyDigest: envelope.bodyDigest,
        authorityEpoch: origin.authorityEpoch,
        updatedAt: origin.now()))
    try appendLedger(
      purpose: purpose, recordID: recordID, bodyDigest: envelope.bodyDigest,
      ledgerSequence: ledgerSequence)
    try origin.advanceHighWater(ledgerSequence: ledgerSequence)
  }

  private func writeEnvelope(_ envelope: TatwoFleetSignedEnvelopeV1, to url: URL) throws {
    try TatwoAtomicFile.write(try Self.encodeJSON(envelope), to: url)
  }

  private func readEnvelope(from url: URL) throws -> TatwoFleetSignedEnvelopeV1 {
    try readJSON(TatwoFleetSignedEnvelopeV1.self, from: url)
  }

  private func readOriginEnvelope<T: Decodable>(
    _ type: T.Type,
    purpose: TatwoFleetSignaturePurposeV1,
    expectedSigner: String,
    from url: URL
  ) throws -> T {
    let origin = try requireOrigin()
    // Fail closed: bare JSON body (unsigned legacy) is rejected.
    let data = try Data(contentsOf: url)
    guard let envelope = try? JSONDecoder.fleet.decode(
      TatwoFleetSignedEnvelopeV1.self, from: data)
    else {
      throw TatwoFleetError.signatureRejected(
        "unsigned or non-envelope control-plane record at \(url.lastPathComponent)")
    }
    // Path-derived relative path + recordID must match signed identity (not envelope alone).
    let pathRelative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: rootURL)
    let expectedRecordID = TatwoFleetRecordIdentityV1.expectedRecordID(
      purpose: purpose,
      canonicalRelativePath: pathRelative,
      ledgerSequence: envelope.ledgerSequence)
    guard envelope.recordID == expectedRecordID else {
      throw TatwoFleetError.bindingMismatch(
        "envelope recordID \(envelope.recordID) != path-derived \(expectedRecordID) at \(pathRelative)")
    }
    let expectedIdentity = TatwoFleetRecordIdentityV1(
      purpose: purpose,
      canonicalRelativePath: pathRelative,
      originDeviceID: envelope.originDeviceID,
      ledgerSequence: envelope.ledgerSequence,
      authorityEpoch: envelope.authorityEpoch)
    try origin.verifyEnvelope(
      envelope,
      expectedPurpose: purpose,
      expectedSignerDeviceID: expectedSigner,
      expectedIdentity: expectedIdentity,
      expectedRecordID: expectedRecordID)
    if purpose != .deviceReport {
      guard envelope.originDeviceID == origin.originDeviceID else {
        throw TatwoFleetError.bindingMismatch(
          "envelope origin \(envelope.originDeviceID) != \(origin.originDeviceID)")
      }
      guard envelope.authorityEpoch <= origin.authorityEpoch else {
        // Future epoch from another replica: reject.
        throw TatwoFleetError.authorityFenced(
          "envelope epoch \(envelope.authorityEpoch) ahead of local \(origin.authorityEpoch)")
      }
    }

    // Same-path replay fence: durable high-water for this pathname must match
    // (or be raised by) the envelope. Lower sequence is always rejected.
    try enforcePathHighWater(
      origin: origin,
      purpose: purpose,
      recordID: expectedRecordID,
      pathRelative: pathRelative,
      envelope: envelope)

    // Triple binding: body recordID == envelope.recordID == path-derived recordID.
    let bodyRecordID = try TatwoFleetBodyRecordIDExtractor.extract(
      purpose: purpose, body: envelope.body)
    guard bodyRecordID == envelope.recordID, bodyRecordID == expectedRecordID else {
      throw TatwoFleetError.bindingMismatch(
        "body recordID \(bodyRecordID) must equal envelope \(envelope.recordID) "
          + "and path-derived \(expectedRecordID) at \(pathRelative)")
    }

    return try envelope.decodeBody(type)
  }

  /// Reject same-path restores of older signed envelopes.
  /// Missing path markers never bootstrap from the mutable current file alone.
  private func enforcePathHighWater(
    origin: TatwoFleetOriginAuthority,
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    pathRelative: String,
    envelope: TatwoFleetSignedEnvelopeV1
  ) throws {
    let prior = try origin.highWater.loadPathHighWater(
      purpose: purpose.rawValue,
      canonicalRelativePath: pathRelative)
    if let prior {
      if envelope.ledgerSequence < prior.ledgerSequence {
        throw TatwoFleetError.authorityFenced(
          "path replay rejected: envelope seq \(envelope.ledgerSequence) "
            + "< path high-water \(prior.ledgerSequence) at \(pathRelative)")
      }
      if envelope.ledgerSequence == prior.ledgerSequence {
        guard envelope.bodyDigest == prior.bodyDigest,
          envelope.authorityEpoch == prior.authorityEpoch,
          envelope.recordID == prior.recordID
        else {
          throw TatwoFleetError.bindingMismatch(
            "path high-water identity mismatch at \(pathRelative)#\(envelope.ledgerSequence)")
        }
        return
      }
      // Envelope ahead of path index (partial write recovery): require exact ledger row.
      try proveEnvelopeAgainstLedger(
        origin: origin,
        purpose: purpose,
        recordID: recordID,
        pathRelative: pathRelative,
        envelope: envelope)
      try origin.highWater.storePathHighWater(
        TatwoFleetPathHighWaterV1(
          purpose: purpose.rawValue,
          canonicalRelativePath: pathRelative,
          recordID: recordID,
          ledgerSequence: envelope.ledgerSequence,
          bodyDigest: envelope.bodyDigest,
          authorityEpoch: envelope.authorityEpoch,
          updatedAt: origin.now()))
      return
    }

    // Missing path marker: never trust mutable current file as bootstrap truth.
    // Reconstruct only from verified ledger proof consistent with durable global HW.
    try proveEnvelopeAgainstLedger(
      origin: origin,
      purpose: purpose,
      recordID: recordID,
      pathRelative: pathRelative,
      envelope: envelope)
    try origin.highWater.storePathHighWater(
      TatwoFleetPathHighWaterV1(
        purpose: purpose.rawValue,
        canonicalRelativePath: pathRelative,
        recordID: recordID,
        ledgerSequence: envelope.ledgerSequence,
        bodyDigest: envelope.bodyDigest,
        authorityEpoch: envelope.authorityEpoch,
        updatedAt: origin.now()))
  }

  /// Ledger-backed proof that `envelope` is authorized for this pathname.
  ///
  /// Recovery requires a ledger row at the **exact** envelope sequence whose
  /// `purpose + recordID + bodyDigest + authorityEpoch + originDeviceID` all match.
  /// Orphan envelopes (signed current written before ledger/global HW advanced,
  /// then sequence reused by another pathname) are rejected — never accepted merely
  /// because `envelope.sequence <= globalHW`.
  ///
  /// Path high-water may be rebuilt only after the **entire** ledger chain
  /// `1...global.ledgerSequence` validates (exact inventory, no gaps, no extras).
  private func proveEnvelopeAgainstLedger(
    origin: TatwoFleetOriginAuthority,
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    pathRelative: String,
    envelope: TatwoFleetSignedEnvelopeV1
  ) throws {
    let global = try origin.highWater.loadAuthorityHighWater()
    guard let global else {
      // Virgin authority (no global HW): still refuse file-only bootstrap.
      throw TatwoFleetError.authorityFenced(
        "path high-water missing and no durable global high-water for \(pathRelative); "
          + "refuse current-file bootstrap")
    }
    if envelope.ledgerSequence == 0 || envelope.ledgerSequence > global.ledgerSequence {
      throw TatwoFleetError.authorityFenced(
        "envelope seq \(envelope.ledgerSequence) outside durable global high-water "
          + "\(global.ledgerSequence) at \(pathRelative)")
    }
    // Full chain validation is mandatory before any path-HW rebuild.
    let chain = try loadValidatedLedgerChain(
      origin: origin, terminalSequence: global.ledgerSequence)

    // Exact sequence row is mandatory (closes signed-orphan / sequence-reuse).
    guard let row = chain.first(where: { $0.ledgerSequence == envelope.ledgerSequence }) else {
      throw TatwoFleetError.authorityFenced(
        "ledger quarantine: missing exact sequence \(envelope.ledgerSequence) for \(pathRelative)")
    }
    guard row.purpose == purpose.rawValue,
      row.recordID == recordID,
      row.bodyDigest == envelope.bodyDigest,
      row.authorityEpoch == envelope.authorityEpoch,
      row.originDeviceID == envelope.originDeviceID
    else {
      throw TatwoFleetError.authorityFenced(
        "orphan envelope rejected at \(pathRelative)#\(envelope.ledgerSequence): "
          + "ledger row purpose/recordID/bodyDigest/epoch/origin mismatch "
          + "(sequence may belong to another record); quarantine")
    }

    // Stale current vs a later proven mutation for the same pathname.
    let proven = latestLedgerProof(in: chain, purpose: purpose, recordID: recordID)
    if let proven, envelope.ledgerSequence < proven.ledgerSequence {
      throw TatwoFleetError.authorityFenced(
        "path replay rejected via ledger: envelope seq \(envelope.ledgerSequence) "
          + "< proven \(proven.ledgerSequence) at \(pathRelative)")
    }
  }

  private struct ValidatedLedgerRow: Equatable, Sendable {
    let ledgerSequence: UInt64
    let purpose: String
    let recordID: String
    let bodyDigest: String
    let authorityEpoch: UInt64
    let originDeviceID: String
  }

  /// Verify ledger rows **1...terminalSequence** in order. Missing, duplicate-identity,
  /// extra/non-canonical JSON, or any invalid row quarantines the fleet (no skip-and-continue).
  private func loadValidatedLedgerChain(
    origin: TatwoFleetOriginAuthority,
    terminalSequence: UInt64
  ) throws -> [ValidatedLedgerRow] {
    guard terminalSequence > 0 else {
      try assertLedgerInventoryExact(terminalSequence: 0)
      return []
    }
    // Inventory fence first: filename set must equal exactly the canonical chain.
    try assertLedgerInventoryExact(terminalSequence: terminalSequence)
    var rows: [ValidatedLedgerRow] = []
    rows.reserveCapacity(Int(min(terminalSequence, UInt64(Int.max))))
    for seq in 1...terminalSequence {
      let filename = String(format: "%020llu.json", seq)
      let url = ledgerDirectory.appendingPathComponent(filename)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: missing sequence \(seq) of \(terminalSequence)")
      }
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: unreadable sequence \(seq): \(error.localizedDescription)")
      }
      guard
        let envelope = try? JSONDecoder.fleet.decode(TatwoFleetSignedEnvelopeV1.self, from: data)
      else {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: invalid envelope at sequence \(seq)")
      }
      let pathRelative = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: rootURL)
      let expectedRecordID = TatwoFleetRecordIdentityV1.expectedRecordID(
        purpose: .ledger,
        canonicalRelativePath: pathRelative,
        ledgerSequence: seq)
      let expectedPath = TatwoFleetRecordIdentityV1.expectedRelativePath(
        purpose: .ledger, recordID: expectedRecordID, ledgerSequence: seq)
      guard pathRelative == expectedPath,
        expectedRecordID == "ledger-\(seq)",
        envelope.recordID == expectedRecordID,
        envelope.ledgerSequence == seq,
        envelope.canonicalRelativePath == expectedPath
      else {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: filename/envelope identity mismatch at sequence \(seq) "
            + "(path=\(pathRelative) recordID=\(envelope.recordID) seq=\(envelope.ledgerSequence))")
      }
      let expectedIdentity = TatwoFleetRecordIdentityV1(
        purpose: .ledger,
        canonicalRelativePath: expectedPath,
        originDeviceID: origin.originDeviceID,
        ledgerSequence: seq,
        authorityEpoch: envelope.authorityEpoch)
      do {
        try origin.verifyEnvelope(
          envelope,
          expectedPurpose: .ledger,
          expectedSignerDeviceID: origin.originDeviceID,
          expectedIdentity: expectedIdentity,
          expectedRecordID: expectedRecordID)
      } catch {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: signature/identity failure at sequence \(seq): \(error)")
      }
      let entry: TatwoFleetLedgerEntryV1
      do {
        entry = try envelope.decodeBody(TatwoFleetLedgerEntryV1.self)
      } catch {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: body decode failed at sequence \(seq)")
      }
      let bodyRecordID = try TatwoFleetBodyRecordIDExtractor.extract(
        purpose: .ledger, body: envelope.body)
      // Envelope recordID is ledger-N; entry.recordID is the subject mutation id.
      // entry.bodyDigest is the subject mutation digest (not the ledger envelope body).
      guard bodyRecordID == expectedRecordID,
        entry.ledgerSequence == seq,
        entry.originDeviceID == origin.originDeviceID,
        entry.authorityEpoch == envelope.authorityEpoch
      else {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: body sequence/epoch/origin/recordID mismatch at sequence \(seq)")
      }
      rows.append(
        ValidatedLedgerRow(
          ledgerSequence: seq,
          purpose: entry.purpose,
          recordID: entry.recordID,
          bodyDigest: entry.bodyDigest,
          authorityEpoch: entry.authorityEpoch,
          originDeviceID: entry.originDeviceID))
    }
    guard rows.count == Int(terminalSequence),
      rows.last?.ledgerSequence == terminalSequence
    else {
      throw TatwoFleetError.authorityFenced(
        "ledger quarantine: terminal sequence \(rows.last?.ledgerSequence ?? 0) "
          + "!= global high-water \(terminalSequence)")
    }
    return rows
  }

  /// Require `ledger/` directory entries == `{000...001.json … terminal.json}` exactly.
  /// Any unexpected entry (hidden, extension case variant, Unicode lookalike, symlink,
  /// directory, non-regular) is quarantine — never silently filtered.
  private func assertLedgerInventoryExact(terminalSequence: UInt64) throws {
    guard FileManager.default.fileExists(atPath: ledgerDirectory.path) else {
      if terminalSequence == 0 { return }
      throw TatwoFleetError.authorityFenced(
        "ledger quarantine: missing ledger directory while global high-water "
          + "\(terminalSequence) exists")
    }
    let listed: [URL]
    do {
      // No .skipsHiddenFiles: hidden names must quarantine, not disappear.
      listed = try FileManager.default.contentsOfDirectory(
        at: ledgerDirectory,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ],
        options: [])
    } catch {
      throw TatwoFleetError.authorityFenced(
        "ledger quarantine: cannot enumerate ledger directory: \(error.localizedDescription)")
    }
    var actualNames: [String] = []
    actualNames.reserveCapacity(listed.count)
    var ignoredExactDSStore = 0
    for url in listed {
      let name = url.lastPathComponent
      if name == "." || name == ".." { continue }
      let values: URLResourceValues
      do {
        values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])
      } catch {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: cannot stat entry \(name): \(error.localizedDescription)")
      }
      // Type checks first: symlink/dir named ".DS_Store" must quarantine.
      if values.isSymbolicLink == true {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: unexpected symlink \(name)")
      }
      if values.isDirectory == true {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: unexpected directory \(name)")
      }
      guard values.isRegularFile == true else {
        throw TatwoFleetError.authorityFenced(
          "ledger quarantine: unexpected non-regular entry \(name)")
      }
      // Narrow macOS Finder noise only: exact basename ".DS_Store" as a
      // regular file. Not case-folded, not prefix/suffix variants.
      if name == ".DS_Store" {
        ignoredExactDSStore += 1
        continue
      }
      actualNames.append(name)
    }
    if ignoredExactDSStore > 0 {
      // Intentional narrow ignore: record via fenced-safe stderr breadcrumb only.
      let line =
        "tatwo-fleet: ledger inventory ignored \(ignoredExactDSStore) exact .DS_Store\n"
      if let data = line.data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
      }
    }
    let actual = Set(actualNames)
    if actualNames.count != actual.count {
      throw TatwoFleetError.authorityFenced(
        "ledger quarantine: duplicate ledger filenames in inventory")
    }
    let expected: Set<String>
    if terminalSequence == 0 {
      expected = []
    } else {
      expected = Set(
        (1...terminalSequence).map { String(format: "%020llu.json", $0) })
    }
    if actual != expected {
      let extra = actual.subtracting(expected).sorted()
      let missing = expected.subtracting(actual).sorted()
      throw TatwoFleetError.authorityFenced(
        "ledger quarantine: inventory mismatch terminal=\(terminalSequence) "
          + "extra=\(extra.prefix(8).joined(separator: ",")) "
          + "missing=\(missing.prefix(8).joined(separator: ","))")
    }
  }

  private func latestLedgerProof(
    in chain: [ValidatedLedgerRow],
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String
  ) -> ValidatedLedgerRow? {
    var best: ValidatedLedgerRow?
    for row in chain where row.purpose == purpose.rawValue && row.recordID == recordID {
      if let current = best {
        if row.ledgerSequence > current.ledgerSequence { best = row }
      } else {
        best = row
      }
    }
    return best
  }

  private func appendLedger(
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    bodyDigest: String,
    ledgerSequence: UInt64
  ) throws {
    let origin = try requireOrigin()
    let entry = TatwoFleetLedgerEntryV1(
      ledgerSequence: ledgerSequence,
      authorityEpoch: origin.authorityEpoch,
      originDeviceID: origin.originDeviceID,
      purpose: purpose,
      recordID: recordID,
      bodyDigest: bodyDigest,
      recordedAt: origin.now())
    let relative = TatwoFleetRecordIdentityV1.expectedRelativePath(
      purpose: .ledger, recordID: "ledger-\(ledgerSequence)", ledgerSequence: ledgerSequence)
    let envelope = try origin.sealEncodable(
      entry,
      purpose: .ledger,
      recordID: "ledger-\(ledgerSequence)",
      ledgerSequence: ledgerSequence,
      canonicalRelativePath: relative)
    let url = ledgerDirectory.appendingPathComponent(
      String(format: "%020llu.json", ledgerSequence))
    // Append-only: create-only so sequence cannot be overwritten.
    try TatwoCreateOnlyFile.write(try Self.encodeJSON(envelope), to: url) {
      // duplicate sequence — verify match
      let prior = try readEnvelope(from: url)
      guard prior.bodyDigest == envelope.bodyDigest else {
        throw TatwoFleetAuthorityError.ledgerSequenceRegression(
          got: ledgerSequence, highWater: ledgerSequence)
      }
    }
  }

  // MARK: IO helpers

  private func listJSONFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try JSONDecoder.fleet.decode(type, from: data)
  }

  private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(value)
  }
}

private extension JSONDecoder {
  static var fleet: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

// MARK: - Scheduler

/// Mini-authoritative fleet scheduler.
///
/// Safety model:
/// - at-least-once execution (lease recovery mints new attempts; old claims stay)
/// - exactly-once logical commit (origin-signed create-only + durable high-water)
/// - origin-signed queue/assignment; target-signed device ingest only
/// - authority epoch fencing prevents stale/copied origin keys from writing
/// - no target work-stealing; no scheduler failover
public struct TatwoFleetScheduler: Sendable {
  public let store: TatwoFleetStore
  public let now: @Sendable () -> Date
  public let agentBinding: TatwoAgentEngineBinding
  /// Target-only signer for register/heartbeat ingest path.
  public let targetSigner: TatwoFleetTargetSigner?
  /// Optional verified job loader for commit binding against signed channel jobs.
  public let signedJobProbe: TatwoFleetSignedJobProbe?

  public init(
    store: TatwoFleetStore,
    now: @escaping @Sendable () -> Date = { Date() },
    agentBinding: TatwoAgentEngineBinding = .production,
    targetSigner: TatwoFleetTargetSigner? = nil,
    signedJobProbe: TatwoFleetSignedJobProbe? = nil
  ) {
    self.store = store
    self.now = now
    self.agentBinding = agentBinding
    self.targetSigner = targetSigner
    self.signedJobProbe = signedJobProbe
  }

  // MARK: A — Device register / heartbeat

  /// Detect available agents and emit a target-signed ingest report when `targetSigner`
  /// is configured; otherwise origin-stamps the device (single-host / test path).
  @discardableResult
  public func registerDevice(
    deviceID: String,
    maxConcurrent: Int,
    inflight: Int = 0,
    /// Test injection: override detected agents (production leaves nil).
    detectedAgentsOverride: [TatwoRemoteAgentKindV1]? = nil
  ) throws -> TatwoFleetDeviceV1 {
    let trimmed = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard TatwoLoopPathComponent.isValid(trimmed) else {
      throw TatwoFleetError.invalidDevice(deviceID)
    }
    guard maxConcurrent > 0 else {
      throw TatwoFleetError.invalidDevice("maxConcurrent must be > 0")
    }
    guard inflight >= 0 else {
      throw TatwoFleetError.invalidDevice("inflight must be >= 0")
    }
    let agents: [TatwoRemoteAgentKindV1]
    if let detectedAgentsOverride {
      agents = detectedAgentsOverride
    } else {
      agents = agentBinding.detectCapableAgents()
    }
    let originID = targetSigner?.originDeviceID
      ?? store.originAuthority?.originDeviceID
      ?? ""
    let epoch = targetSigner?.authorityEpoch
      ?? store.originAuthority?.authorityEpoch
      ?? 0
    let device = TatwoFleetDeviceV1(
      deviceID: trimmed,
      agents: agents,
      maxConcurrent: maxConcurrent,
      inflight: inflight,
      lastHeartbeatAt: now(),
      authorityEpoch: epoch,
      originDeviceID: originID,
      ledgerSequence: 0)
    if let targetSigner {
      try store.writeTargetDeviceIngest(device, signer: targetSigner)
    } else {
      try store.writeDevice(device)
    }
    return device
  }

  /// Target capacity report (heartbeat refresh).
  ///
  /// - Agents are **always re-probed** (never inherited from ingest/body claims).
  /// - `maxConcurrent` comes only from controlled local input or origin-accepted
  ///   device capacity — never from an unverified/modifiable ingest body.
  /// - Unverified ingest decode is never used as a capability/capacity baseline.
  @discardableResult
  public func reportHeartbeat(
    deviceID: String,
    inflight: Int,
    /// Controlled local capacity. When nil, use origin-accepted device capacity
    /// or (only if signature-verified) last self-signed ingest capacity.
    maxConcurrent: Int? = nil,
    /// Kept for API compatibility; heartbeat always re-probes agents regardless.
    redetectAgents: Bool = true
  ) throws -> TatwoFleetDeviceV1 {
    _ = redetectAgents
    let existingAccepted = try? store.loadDevice(deviceID: deviceID)
    // Verified ingest only — never decode untrusted body for baseline.
    let verifiedIngest: TatwoFleetDeviceV1?
    if let targetSigner {
      verifiedIngest = try? store.loadVerifiedIngestDeviceBody(
        deviceID: deviceID,
        trust: targetSigner.trust,
        expectedOriginDeviceID: targetSigner.originDeviceID)
    } else if let origin = store.originAuthority {
      verifiedIngest = try? store.loadVerifiedIngestDeviceBody(
        deviceID: deviceID,
        trust: origin.trust,
        expectedOriginDeviceID: origin.originDeviceID)
    } else {
      verifiedIngest = nil
    }
    let registered =
      existingAccepted != nil
      || verifiedIngest != nil
      || store.hasIngestDevice(deviceID: deviceID)
    guard registered || targetSigner != nil else {
      throw TatwoFleetError.deviceNotRegistered(deviceID)
    }
    // Always re-probe — capability is not a durable claim from prior bodies.
    let agents = agentBinding.detectCapableAgents()
    let originID = targetSigner?.originDeviceID
      ?? existingAccepted?.originDeviceID
      ?? verifiedIngest?.originDeviceID
      ?? store.originAuthority?.originDeviceID
      ?? ""
    let epoch = targetSigner?.authorityEpoch
      ?? existingAccepted?.authorityEpoch
      ?? verifiedIngest?.authorityEpoch
      ?? store.originAuthority?.authorityEpoch
      ?? 0
    let resolvedMax: Int
    if let maxConcurrent {
      guard maxConcurrent > 0 else {
        throw TatwoFleetError.invalidDevice("maxConcurrent must be > 0")
      }
      resolvedMax = maxConcurrent
    } else if let accepted = existingAccepted {
      // Origin-accepted capacity is controlled control-plane state.
      resolvedMax = accepted.maxConcurrent
    } else if let verifiedIngest {
      // Self-signed prior report only after full signature verification.
      resolvedMax = verifiedIngest.maxConcurrent
    } else {
      // Fail closed to minimum controlled default — never from raw file bytes.
      resolvedMax = 1
    }
    let device = TatwoFleetDeviceV1(
      deviceID: deviceID,
      agents: agents,
      maxConcurrent: resolvedMax,
      inflight: max(0, inflight),
      lastHeartbeatAt: now(),
      authorityEpoch: epoch,
      originDeviceID: originID,
      ledgerSequence: 0)
    if let targetSigner {
      try store.writeTargetDeviceIngest(device, signer: targetSigner)
    } else {
      try store.writeDevice(device)
    }
    return device
  }

  // MARK: D — Enqueue

  /// Enqueue one or more logical jobs (count >= 1). Does not dispatch yet.
  @discardableResult
  public func enqueue(
    originDeviceID: String,
    logicalJobIDPrefix: String,
    count: Int = 1,
    contractID: String,
    goalID: String,
    identity: IdentityKind,
    workPath: String,
    payload: TatwoLoopJobPayloadV1,
    resourceCaps: TatwoLoopResourceCapsV1,
    remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1? = nil,
    remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1? = nil,
    workspaceLocator: TatwoRemoteWorkspaceLocatorV1? = nil,
    stopConditions: TatwoLoopStopConditionsV1 = TatwoLoopStopConditionsV1(
      cancelFileSignal: true, rules: ["cancel-file"])
  ) throws -> [TatwoFleetLogicalJobV1] {
    guard let authority = store.originAuthority else {
      throw TatwoFleetError.missingAuthority("enqueue requires origin authority")
    }
    try authority.assertWritable()
    guard originDeviceID == authority.originDeviceID else {
      throw TatwoFleetError.bindingMismatch(
        "enqueue origin \(originDeviceID) != authority \(authority.originDeviceID)")
    }
    guard count >= 1 else {
      throw TatwoFleetError.invalidLogicalJob("count must be >= 1")
    }
    try payload.validate()
    try resourceCaps.validate()
    let requiredAgent: TatwoRemoteAgentKindV1?
    switch payload {
    case let .tatwoLoop(loop):
      requiredAgent = loop.agent
    case .shellSafe:
      requiredAgent = nil
    }
    let timestamp = now()
    var created: [TatwoFleetLogicalJobV1] = []
    for index in 0..<count {
      let logicalJobID: String
      if count == 1 {
        logicalJobID = logicalJobIDPrefix
      } else {
        logicalJobID = "\(logicalJobIDPrefix)-\(index + 1)"
      }
      if try store.loadLogicalJob(logicalJobID: logicalJobID) != nil {
        throw TatwoFleetError.logicalJobAlreadyExists(logicalJobID)
      }
      if try store.loadCommit(logicalJobID: logicalJobID) != nil {
        throw TatwoFleetError.logicalAlreadyCommitted(logicalJobID)
      }
      let job = TatwoFleetLogicalJobV1(
        logicalJobID: logicalJobID,
        originDeviceID: originDeviceID,
        contractID: contractID,
        goalID: goalID,
        identity: identity,
        workPath: workPath,
        payload: payload,
        resourceCaps: resourceCaps,
        stopConditions: stopConditions,
        requiredAgent: requiredAgent,
        remoteBorrowInvocation: remoteBorrowInvocation,
        remoteDispatchReadiness: remoteDispatchReadiness,
        workspaceLocator: workspaceLocator,
        status: .pending,
        enqueuedAt: timestamp,
        updatedAt: timestamp)
      try job.validate()
      try store.writeLogicalJob(job)
      created.append(try store.loadLogicalJob(logicalJobID: logicalJobID) ?? job)
    }
    return created
  }

  // MARK: Status

  public func status() throws -> TatwoFleetStatusV1 {
    let devices = try store.listDevices()
    let jobs = try store.listLogicalJobs()
    let assignments = try store.listAssignments()
    let commits = try store.listCommits()
    let superseded = try store.listSuperseded()
    let pending = jobs.filter { $0.status == .pending }.count
    let assignedJobs = jobs.filter { $0.status == .assigned }.count
    let committedJobs = jobs.filter { $0.status == .committed }.count
      + commits.count  // commits may exist even if queue rewritten
    let inFlight = assignments.filter {
      $0.status == .assigned || $0.status == .leaseExpired
    }.count
    // Deduplicate committed count preference: unique logical commits.
    let committedUnique = Set(commits.map(\.logicalJobID)).count
    return TatwoFleetStatusV1(
      devices: devices,
      pendingCount: pending,
      assignedCount: assignedJobs,
      inFlightCount: inFlight,
      committedCount: max(committedJobs, committedUnique),
      supersededCount: superseded.count,
      assignments: assignments,
      commits: commits)
  }

  // MARK: Tick (assign + lease recover + converge)

  /// One scheduler tick under a single-host exclusive file lock (serializes re-entry).
  ///
  /// Note: tick lock is cooperative advisory only. Exactly-once commit authority is
  /// the origin-signed commit file + durable high-water, not the flock.
  public func tick(
    config: TatwoFleetTickConfigV1 = TatwoFleetTickConfigV1(),
    dispatch: TatwoFleetDispatchHandler,
    resultProbe: TatwoFleetResultProbe? = nil
  ) throws -> TatwoFleetTickResultV1 {
    try store.ensureLayout()
    return try TatwoFileLock.withExclusiveLock(for: store.tickLockURL) {
      try tickUnlocked(config: config, dispatch: dispatch, resultProbe: resultProbe)
    }
  }

  /// Test helper: tick without lock (use only when lock is held externally).
  public func tickUnlocked(
    config: TatwoFleetTickConfigV1,
    dispatch: TatwoFleetDispatchHandler,
    resultProbe: TatwoFleetResultProbe?
  ) throws -> TatwoFleetTickResultV1 {
    guard store.originAuthority != nil else {
      throw TatwoFleetError.missingAuthority("tick requires origin authority")
    }
    try store.originAuthority?.assertWritable()
    let timestamp = now()
    var leaseRecoveries: [TatwoFleetAssignmentV1] = []
    var commits: [TatwoFleetLogicalCommitV1] = []
    var superseded: [TatwoFleetSupersededResultV1] = []
    var assigned: [TatwoFleetAssignmentV1] = []
    var skippedFull = 0
    var skippedStale = 0
    var skippedCap = 0

    // 0) Ingest target-signed device reports (explicit target→origin path).
    let ingested = try store.ingestTargetDeviceReports()

    // 1) Converge results first (free capacity + commit gate).
    if let resultProbe {
      let converge = try convergeResults(resultProbe: resultProbe, at: timestamp)
      commits.append(contentsOf: converge.commits)
      superseded.append(contentsOf: converge.superseded)
    }

    // 2) Lease recovery: mint new attempts for expired assignments without result,
    //    without revoking old claims. Skip if logical already committed.
    let recoveries = try recoverExpiredLeases(
      config: config,
      at: timestamp,
      resultProbe: resultProbe)
    leaseRecoveries.append(contentsOf: recoveries)

    // 3) Assign pending logical jobs.
    let assignOutcome = try assignPending(
      config: config,
      at: timestamp,
      dispatch: dispatch)
    assigned.append(contentsOf: assignOutcome.assigned)
    skippedFull += assignOutcome.skippedFullCapacity
    skippedStale += assignOutcome.skippedStaleHeartbeat
    skippedCap += assignOutcome.skippedMissingCapability

    let pendingRemaining = try store.listLogicalJobs().filter { $0.status == .pending }.count
    return TatwoFleetTickResultV1(
      assigned: assigned,
      leaseRecoveries: leaseRecoveries,
      commits: commits,
      superseded: superseded,
      pendingRemaining: pendingRemaining,
      skippedFullCapacity: skippedFull,
      skippedStaleHeartbeat: skippedStale,
      skippedMissingCapability: skippedCap,
      ingestedDevices: ingested)
  }

  // MARK: Commit gate (exactly-once logical)

  /// Apply a target-signed terminal attempt result to the logical commit gate (L-commit).
  ///
  /// Requires origin-signed assignment load path, result↔assignment binding
  /// (`jobID`, `dispatchNonce`, `jobCanonicalDigest`), and a **required** signed
  /// physical job (passed in or loaded via `signedJobProbe` — probe failures throw;
  /// never optional / never `try?` → nil).
  ///
  /// SEMANTICS NOTE (H3/C3 + scale-up before multi-host promotion):
  /// - L-commit input is **only** target-signed terminals: `completed` / `failed` /
  ///   `cancelled`. Channel `verified` is origin acceptance (A-commit / converge output)
  ///   and is **rejected** as commit input (forged or genuine).
  /// - Logical `committed` means origin arbitrated a bound terminal **result receipt** —
  ///   it is **not** 5.6-1「已驗收」and does **not** guarantee full attempt output bytes
  ///   are durable/fetchable on every peer. Do not claim `committed == verified` or
  ///   `committed == output fully available` until attempt-complete envelopes bind
  ///   output digest/bytes and transfer-complete fencing is required.
  @discardableResult
  public func acceptAttemptResult(
    assignment: TatwoFleetAssignmentV1,
    result: TatwoLoopJobResultReceiptV1,
    at timestamp: Date? = nil,
    signedJob: TatwoLoopJobV1? = nil
  ) throws -> (
    commit: TatwoFleetLogicalCommitV1?,
    superseded: TatwoFleetSupersededResultV1?,
    created: Bool
  ) {
    let now = timestamp ?? now()
    try assignment.validate()

    // Re-load assignment from signed store when possible (reject in-memory forgery).
    let verifiedAssignment: TatwoFleetAssignmentV1
    if let loaded = try store.loadAssignment(jobID: assignment.jobID) {
      verifiedAssignment = loaded
    } else {
      // First-write path in unit tests may pass pre-persisted assignment; require store write first.
      throw TatwoFleetError.signatureRejected(
        "assignment \(assignment.jobID) must be origin-signed on disk before commit")
    }

    // Bind result to this assignment attempt (including digest — grafting defense).
    guard result.jobID == verifiedAssignment.jobID,
      result.dispatchNonce == verifiedAssignment.dispatchNonce,
      result.jobCanonicalDigest == verifiedAssignment.jobCanonicalDigest
    else {
      throw TatwoFleetError.bindingMismatch(
        "result binding mismatch for \(verifiedAssignment.jobID)")
    }

    // Signed physical job is required (not optional).
    let job: TatwoLoopJobV1
    if let signedJob {
      job = signedJob
    } else if let probe = signedJobProbe {
      job = try probe(verifiedAssignment.jobID)
    } else {
      throw TatwoFleetError.bindingMismatch(
        "signed job required for commit gate \(verifiedAssignment.jobID)")
    }
    guard job.jobID == verifiedAssignment.jobID,
      job.dispatchNonce == verifiedAssignment.dispatchNonce,
      job.logicalJobID == verifiedAssignment.logicalJobID,
      job.originDeviceID == verifiedAssignment.originDeviceID,
      job.targetDeviceID == verifiedAssignment.targetDeviceID
    else {
      throw TatwoFleetError.bindingMismatch(
        "assignment vs signed job identity mismatch for \(verifiedAssignment.jobID)")
    }
    let jobDigest = try job.canonicalDigest()
    guard jobDigest == verifiedAssignment.jobCanonicalDigest,
      jobDigest == result.jobCanonicalDigest
    else {
      throw TatwoFleetError.bindingMismatch(
        "assignment/job/result digest mismatch for \(verifiedAssignment.jobID)")
    }

    // H3/C3: commit gate accepts target-signed terminals only.
    // `verified` is origin-side acceptance output, never an L-commit input.
    guard [.completed, .failed, .cancelled].contains(result.status) else {
      return (nil, nil, false)
    }

    let resultDigest = try? result.canonicalDigest()
    let candidate = TatwoFleetLogicalCommitV1(
      logicalJobID: verifiedAssignment.logicalJobID,
      winningJobID: verifiedAssignment.jobID,
      winningDispatchNonce: verifiedAssignment.dispatchNonce,
      targetDeviceID: verifiedAssignment.targetDeviceID,
      originDeviceID: verifiedAssignment.originDeviceID,
      resultStatus: result.status,
      resultDigest: resultDigest,
      jobCanonicalDigest: verifiedAssignment.jobCanonicalDigest,
      committedAt: now)
    let (commit, created) = try store.commitLogical(candidate)
    if created {
      try store.writeAssignment(verifiedAssignment.withStatus(.committed))
      if let job = try store.loadLogicalJob(logicalJobID: verifiedAssignment.logicalJobID) {
        try store.writeLogicalJob(job.withStatus(.committed, at: now))
      }
      return (commit, nil, true)
    }

    // Existing commit: this attempt is superseded if it is not the winner.
    if commit.winningJobID == verifiedAssignment.jobID {
      // Idempotent re-accept of the winner.
      try store.writeAssignment(verifiedAssignment.withStatus(.committed))
      return (commit, nil, false)
    }
    let entry = TatwoFleetSupersededResultV1(
      logicalJobID: verifiedAssignment.logicalJobID,
      jobID: verifiedAssignment.jobID,
      dispatchNonce: verifiedAssignment.dispatchNonce,
      winningJobID: commit.winningJobID,
      reason: "logical_job_already_committed",
      seenAt: now)
    try store.writeSuperseded(entry)
    try store.writeAssignment(verifiedAssignment.withStatus(.superseded))
    return (nil, entry, false)
  }

  // MARK: Internals

  private func convergeResults(
    resultProbe: TatwoFleetResultProbe,
    at timestamp: Date
  ) throws -> (commits: [TatwoFleetLogicalCommitV1], superseded: [TatwoFleetSupersededResultV1]) {
    var commits: [TatwoFleetLogicalCommitV1] = []
    var superseded: [TatwoFleetSupersededResultV1] = []
    let open = try store.listAssignments().filter {
      $0.status == .assigned || $0.status == .leaseExpired
    }
    for assignment in open {
      guard let result = try resultProbe(assignment.jobID) else { continue }
      let outcome = try acceptAttemptResult(
        assignment: assignment, result: result, at: timestamp)
      if let commit = outcome.commit, outcome.created {
        commits.append(commit)
      }
      if let entry = outcome.superseded {
        superseded.append(entry)
      }
    }
    return (commits, superseded)
  }

  private func recoverExpiredLeases(
    config: TatwoFleetTickConfigV1,
    at timestamp: Date,
    resultProbe: TatwoFleetResultProbe?
  ) throws -> [TatwoFleetAssignmentV1] {
    var recoveries: [TatwoFleetAssignmentV1] = []
    let open = try store.listAssignments().filter { $0.status == .assigned }
    for assignment in open {
      if try store.loadCommit(logicalJobID: assignment.logicalJobID) != nil {
        continue
      }
      if let resultProbe, try resultProbe(assignment.jobID) != nil {
        continue
      }
      let deadline = assignment.leaseDeadline(graceSeconds: config.leaseGraceSeconds)
      guard timestamp >= deadline else { continue }

      // Mark lease expired — do NOT delete or revoke the old claim/assignment identity.
      let expired = assignment.withStatus(.leaseExpired)
      try store.writeAssignment(expired)

      // Re-queue logical job as pending so assignPending mints a new attempt.
      if let job = try store.loadLogicalJob(logicalJobID: assignment.logicalJobID),
        job.status != .committed
      {
        try store.writeLogicalJob(job.withStatus(.pending, at: timestamp))
      }
      recoveries.append(expired)
    }
    return recoveries
  }

  private struct AssignOutcome {
    var assigned: [TatwoFleetAssignmentV1]
    var skippedFullCapacity: Int
    var skippedStaleHeartbeat: Int
    var skippedMissingCapability: Int
  }

  private func assignPending(
    config: TatwoFleetTickConfigV1,
    at timestamp: Date,
    dispatch: TatwoFleetDispatchHandler
  ) throws -> AssignOutcome {
    var outcome = AssignOutcome(
      assigned: [], skippedFullCapacity: 0, skippedStaleHeartbeat: 0,
      skippedMissingCapability: 0)
    var devices = try store.listDevices()
    var state = try store.loadSchedulerState()
    // Local inflight overlay (scheduler-visible open assignments).
    var localInflight = Dictionary(
      grouping: try store.listAssignments().filter {
        $0.status == .assigned
      },
      by: \.targetDeviceID
    ).mapValues(\.count)

    let pending = try store.listLogicalJobs().filter { $0.status == .pending }
    for job in pending {
      // Already committed (race with converge) — skip.
      if try store.loadCommit(logicalJobID: job.logicalJobID) != nil {
        try store.writeLogicalJob(job.withStatus(.committed, at: timestamp))
        continue
      }

      // Refresh device list capacity view each pick.
      devices = try store.listDevices()
      let pick = pickDevice(
        for: job,
        devices: devices,
        localInflight: localInflight,
        cursor: state.roundRobinCursorDeviceID,
        config: config,
        at: timestamp)
      switch pick {
      case .noneAvailable(let reason):
        switch reason {
        case .full:
          outcome.skippedFullCapacity += 1
        case .stale:
          outcome.skippedStaleHeartbeat += 1
        case .capability:
          outcome.skippedMissingCapability += 1
        }
        // Leave job pending (no loss, no infinite re-dispatch of same attempt).
        continue
      case .device(let device):
        let attempt = try nextAttemptNumber(for: job.logicalJobID)
        let jobID = UUID().uuidString
        let dispatchNonce = UUID().uuidString
        let physical = TatwoLoopJobV1(
          jobID: jobID,
          logicalJobID: job.logicalJobID,
          dispatchNonce: dispatchNonce,
          contractID: job.contractID,
          goalID: job.goalID,
          identity: job.identity,
          originDeviceID: job.originDeviceID,
          targetDeviceID: device.deviceID,
          remoteBorrowInvocation: job.remoteBorrowInvocation,
          remoteDispatchReadiness: job.remoteDispatchReadiness.map {
            TatwoRemoteDispatchReadinessBindingV1(
              workspaceBindingID: $0.workspaceBindingID,
              workspaceBindingDigest: $0.workspaceBindingDigest,
              agentModelCapabilityDigest: $0.agentModelCapabilityDigest,
              activeSkillSetDigest: $0.activeSkillSetDigest,
              challengeNonce: UUID().uuidString)
          },
          workspaceLocator: job.workspaceLocator,
          payload: job.payload,
          workPath: job.workPath,
          resourceCaps: job.resourceCaps,
          stopConditions: job.stopConditions,
          createdAt: timestamp)
        try physical.validate()
        let receipt: TatwoFleetDispatchReceiptV1
        do {
          receipt = try dispatch(physical)
        } catch {
          throw TatwoFleetError.dispatchFailed(error.localizedDescription)
        }
        // Bind assignment to the just-minted physical job (full identity + digest).
        let expectedDigest = try physical.canonicalDigest()
        guard receipt.jobID == physical.jobID,
          receipt.dispatchNonce == physical.dispatchNonce,
          receipt.targetDeviceID == physical.targetDeviceID,
          !receipt.jobCanonicalDigest.isEmpty,
          receipt.jobCanonicalDigest == expectedDigest
        else {
          throw TatwoFleetError.dispatchFailed(
            "dispatch receipt must match physical jobID/nonce/target/digest")
        }
        let assignment = TatwoFleetAssignmentV1(
          logicalJobID: job.logicalJobID,
          jobID: receipt.jobID,
          dispatchNonce: receipt.dispatchNonce,
          targetDeviceID: receipt.targetDeviceID,
          originDeviceID: job.originDeviceID,
          assignedAt: timestamp,
          leaseSeconds: config.leaseSeconds,
          attempt: attempt,
          status: .assigned,
          jobCanonicalDigest: receipt.jobCanonicalDigest,
          dispatchRecordID: receipt.dispatchRecordID)
        try store.writeAssignment(assignment)
        try store.writeLogicalJob(job.withStatus(.assigned, at: timestamp))
        localInflight[device.deviceID, default: 0] += 1
        state = TatwoFleetSchedulerStateV1(roundRobinCursorDeviceID: device.deviceID)
        try store.writeSchedulerState(state)
        outcome.assigned.append(
          try store.loadAssignment(jobID: receipt.jobID) ?? assignment)
      }
    }
    return outcome
  }

  private enum PickReason: Sendable {
    case full
    case stale
    case capability
  }

  private enum PickResult: Sendable {
    case device(TatwoFleetDeviceV1)
    case noneAvailable(PickReason)
  }

  private func pickDevice(
    for job: TatwoFleetLogicalJobV1,
    devices: [TatwoFleetDeviceV1],
    localInflight: [String: Int],
    cursor: String?,
    config: TatwoFleetTickConfigV1,
    at timestamp: Date
  ) -> PickResult {
    let sorted = devices.sorted { $0.deviceID < $1.deviceID }
    guard !sorted.isEmpty else { return .noneAvailable(.stale) }

    var sawCapable = false
    var sawFreshCapable = false
    var sawFreshCapableWithRoom = false

    // Round-robin: start after cursor.
    let startIndex: Int
    if let cursor, let idx = sorted.firstIndex(where: { $0.deviceID == cursor }) {
      startIndex = (idx + 1) % sorted.count
    } else {
      startIndex = 0
    }

    for offset in 0..<sorted.count {
      let device = sorted[(startIndex + offset) % sorted.count]
      if let requiredTargetDeviceID = job.requiredTargetDeviceID,
        device.deviceID != requiredTargetDeviceID
      {
        continue
      }
      let capable: Bool
      if let required = job.requiredAgent {
        capable = device.agents.contains(required)
      } else {
        capable = true
      }
      if !capable { continue }
      sawCapable = true

      let age = timestamp.timeIntervalSince(device.lastHeartbeatAt)
      if age > config.heartbeatMaxAgeSeconds {
        continue
      }
      sawFreshCapable = true

      let reported = device.inflight
      let scheduled = localInflight[device.deviceID] ?? 0
      let effective = max(reported, scheduled)
      if effective >= device.maxConcurrent {
        continue
      }
      sawFreshCapableWithRoom = true
      return .device(device)
    }

    if !sawCapable { return .noneAvailable(.capability) }
    if !sawFreshCapable { return .noneAvailable(.stale) }
    // sawFreshCapableWithRoom is false whenever we reach here after scanning.
    _ = sawFreshCapableWithRoom
    return .noneAvailable(.full)
  }

  private func nextAttemptNumber(for logicalJobID: String) throws -> Int {
    let existing = try store.listAssignments().filter { $0.logicalJobID == logicalJobID }
    return (existing.map(\.attempt).max() ?? 0) + 1
  }
}
