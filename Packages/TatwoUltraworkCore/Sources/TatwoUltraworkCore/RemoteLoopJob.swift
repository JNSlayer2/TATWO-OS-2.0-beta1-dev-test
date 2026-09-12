import CryptoKit
import Foundation

public enum TatwoLoopJobStatusV1: String, Codable, Sendable, Equatable, CaseIterable {
  case queued
  case delivered
  /// Design 5.6-1「已啟動」= runner accepted the job (reason often `runner-accepted`).
  /// Wire case name stays `accepted` for channel/ack compatibility.
  /// **Not** design「已驗收」— that maps to `.verified` (see `designSemanticLabel`).
  case accepted
  case running
  case completed
  case failed
  case cancelled
  /// Design 5.6-1「已驗收」= origin consume + converge (`origin-verified`).
  /// Design handoff §10.1 code `accepted` collides with wire `.accepted`; product
  /// acceptance is this case, never the mid-lifecycle runner accept.
  case verified

  /// Monotonic rank for registry projection. Higher = later in the lifecycle.
  /// Terminal outcomes share a rank; flipping among them is also rejected.
  public var remoteProjectionRank: Int {
    switch self {
    case .queued: return 0
    case .delivered: return 1
    case .accepted: return 2
    case .running: return 3
    case .completed, .failed, .cancelled: return 4
    case .verified: return 5
    }
  }

  /// Stable UI / receipt projection labels for issue.md 5.6-1 five-state vocabulary.
  /// Prefer this over raw `rawValue` when presenting remote-loop lifecycle.
  /// Note: wire `.accepted` projects as **已啟動(runner接受)**, not 已驗收.
  public var designSemanticLabel: String {
    switch self {
    case .queued: return "已排隊"
    case .delivered: return "已送達"
    case .accepted: return "已啟動(runner接受)"
    case .running: return "執行中"
    case .completed: return "已完成"
    case .failed: return "失敗"
    case .cancelled: return "已取消"
    case .verified: return "已驗收"
    }
  }

  /// Whether a projection may move `from` → `to` without regressing.
  /// Same status is allowed (idempotent re-project). Terminal → earlier is rejected.
  public static func allowsRemoteStatusProjection(
    from: TatwoLoopJobStatusV1,
    to: TatwoLoopJobStatusV1
  ) -> Bool {
    if from == to { return true }
    if to.remoteProjectionRank > from.remoteProjectionRank { return true }
    return false
  }
}

public enum TatwoLoopJobStateError: Error, LocalizedError, Sendable, Equatable {
  case invalidTransition(from: TatwoLoopJobStatusV1, to: TatwoLoopJobStatusV1)
  case invalidJob(String)
  case invalidResourceCaps
  case invalidPayload(String)
  case jobNotFound(String)
  case duplicateJob(String)
  case malformedJournal(String)
  case missingChannelRoot
  case missingChannelTrust
  case runnerLimitReached
  case signatureRejected(jobID: String, reason: String)
  case resourceGateBlocked(reason: String)
  /// Registry job digest/nonce does not match the channel signed job (stale replay).
  case jobBindingMismatch(jobID: String, detail: String)
  /// consumeResult saw a different result after a prior consume marker.
  case resultConsumeConflict(jobID: String, detail: String)
  /// Artifact dispatchNonce/job digest does not match the current signed job attempt.
  case attemptBindingMismatch(jobID: String, detail: String)
  /// Enqueue write stage failed (or test fault-injection) before the commit marker.
  case enqueueIncomplete(jobID: String, stage: String)
  /// Target/origin saw job artifacts without a final commit marker.
  case missingCommitMarker(jobID: String)

  public var errorDescription: String? {
    switch self {
    case let .invalidTransition(from, to):
      return "Invalid remote loop job transition \(from.rawValue) -> \(to.rawValue)."
    case let .invalidJob(jobID):
      return "Invalid remote loop job identifier: \(jobID)"
    case .invalidResourceCaps:
      return "Remote loop job resource caps must be positive."
    case let .invalidPayload(message):
      return "Invalid remote loop job payload: \(message)"
    case let .jobNotFound(jobID):
      return "Remote loop job not found: \(jobID)"
    case let .duplicateJob(jobID):
      return "Remote loop job already exists with different content: \(jobID)"
    case let .malformedJournal(jobID):
      return "Remote loop job journal is malformed: \(jobID)"
    case .missingChannelRoot:
      return "TATWO_ULTRAWORK_JOB_CHANNEL_DIR is required for the file channel."
    case .missingChannelTrust:
      return "Remote loop job channel requires device trust (TatwoDeviceTrust) for signed artifacts."
    case .runnerLimitReached:
      return "Remote loop runner reached its polling limit before becoming idle."
    case let .signatureRejected(jobID, reason):
      return "Remote loop channel rejected artifact for \(jobID): \(reason)"
    case let .resourceGateBlocked(reason):
      return "resource_gate_blocked: \(reason)"
    case let .jobBindingMismatch(jobID, detail):
      return "Remote loop job binding mismatch for \(jobID): \(detail)"
    case let .resultConsumeConflict(jobID, detail):
      return "Remote loop result consume conflict for \(jobID): \(detail)"
    case let .attemptBindingMismatch(jobID, detail):
      return "Remote loop attempt binding mismatch for \(jobID): \(detail)"
    case let .enqueueIncomplete(jobID, stage):
      return "Remote loop enqueue incomplete for \(jobID) at stage \(stage)."
    case let .missingCommitMarker(jobID):
      return "Remote loop job \(jobID) is missing its enqueue commit marker."
    }
  }
}

/// Ordered channel write stages for atomic enqueue (commit marker last).
public enum TatwoLoopChannelEnqueueStage: String, Sendable, Equatable, CaseIterable {
  case job
  case signature
  case journal
  case ack
  case commitMarker = "commit_marker"
}

/// Test-only fault injection for channel enqueue write stages.
public final class TatwoLoopChannelEnqueueFaultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var failAt: TatwoLoopChannelEnqueueStage?

  public init(failAt: TatwoLoopChannelEnqueueStage? = nil) {
    self.failAt = failAt
  }

  public func setFailAt(_ stage: TatwoLoopChannelEnqueueStage?) {
    lock.lock()
    defer { lock.unlock() }
    failAt = stage
  }

  public func currentFailAt() -> TatwoLoopChannelEnqueueStage? {
    lock.lock()
    defer { lock.unlock() }
    return failAt
  }

  func check(_ stage: TatwoLoopChannelEnqueueStage, jobID: String) throws {
    lock.lock()
    let match = failAt == stage
    lock.unlock()
    if match {
      throw TatwoLoopJobStateError.enqueueIncomplete(jobID: jobID, stage: stage.rawValue)
    }
  }
}

/// Final origin-signed marker proving job/signature/journal/ack are fully committed.
public struct TatwoLoopJobCommitMarkerV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let committedAt: Date

  public init(
    schema: String = "TatwoLoopJobCommitMarkerV1",
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    committedAt: Date
  ) {
    self.schema = schema
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.committedAt = committedAt
  }
}

public enum TatwoLoopJobStateMachine {
  @discardableResult
  public static func validate(
    from: TatwoLoopJobStatusV1,
    to: TatwoLoopJobStatusV1
  ) throws -> TatwoLoopJobStatusV1 {
    let allowed: Bool
    switch from {
    case .queued:
      allowed = to == .delivered
    case .delivered:
      allowed = to == .accepted
    case .accepted:
      allowed = to == .running
    case .running:
      allowed = [.completed, .failed, .cancelled].contains(to)
    case .completed, .failed, .cancelled:
      allowed = to == .verified
    case .verified:
      allowed = false
    }
    guard allowed else {
      throw TatwoLoopJobStateError.invalidTransition(from: from, to: to)
    }
    return to
  }
}

public struct TatwoLoopResourceCapsV1: Codable, Sendable, Equatable {
  /// Local hard ceiling: remote-declared caps cannot exceed this (host protection first).
  public static let localHardMaxDurationSec: TimeInterval = 120
  /// Local hard ceiling for captured process output (bytes).
  public static let localHardMaxOutputBytes: Int = 1_048_576

  public let maxDurationSec: TimeInterval
  public let maxOutputBytes: Int

  public init(maxDurationSec: TimeInterval, maxOutputBytes: Int) {
    self.maxDurationSec = maxDurationSec
    self.maxOutputBytes = maxOutputBytes
  }

  public func validate() throws {
    guard maxDurationSec.isFinite, maxDurationSec > 0, maxOutputBytes > 0 else {
      throw TatwoLoopJobStateError.invalidResourceCaps
    }
  }

  /// Clamp remote-declared caps to local hard limits before execution.
  public func clampedForLocalExecution() -> TatwoLoopResourceCapsV1 {
    TatwoLoopResourceCapsV1(
      maxDurationSec: min(maxDurationSec, Self.localHardMaxDurationSec),
      maxOutputBytes: min(maxOutputBytes, Self.localHardMaxOutputBytes))
  }
}

public struct TatwoLoopStopConditionsV1: Codable, Sendable, Equatable {
  public let cancelFileSignal: Bool
  public let rules: [String]

  public init(cancelFileSignal: Bool = true, rules: [String] = []) {
    self.cancelFileSignal = cancelFileSignal
    self.rules = rules
  }
}

public enum TatwoShellSafeCommandV1: String, Codable, Sendable, Equatable, CaseIterable {
  case echo
  case sleep
  case `true`
  case `false`
}

public struct TatwoShellSafePayloadV1: Codable, Sendable, Equatable {
  public let command: TatwoShellSafeCommandV1
  public let arguments: [String]

  public init(command: TatwoShellSafeCommandV1, arguments: [String] = []) {
    self.command = command
    self.arguments = arguments
  }
}

public enum TatwoLoopModeV1: String, Codable, Sendable, Equatable, CaseIterable {
  case s = "S"
  case m = "M"
  case l = "L"
  case xl = "XL"
  case xxl = "XXL"
}

/// Target-local agent CLI selected for `.tatwoLoop` remote compute.
/// Origin may declare intent; target `TatwoAgentEngineBinding` resolves a
/// fail-closed absolute-path whitelist before launch.
public enum TatwoRemoteAgentKindV1: String, Codable, Sendable, Equatable, CaseIterable {
  case grok
  case codex
  case claude

  /// Exact model families that this target-local CLI is allowed to launch.
  ///
  /// This is intentionally shared by payload validation, target readiness and
  /// the executable binding so an origin cannot claim one route while the
  /// target silently launches another brand/model family.
  public func acceptsExactModelRouteID(_ modelRouteID: String) -> Bool {
    switch self {
    case .claude:
      return modelRouteID.hasPrefix("fable-")
        || modelRouteID.hasPrefix("opus-")
        || modelRouteID.hasPrefix("sonnet-")
        || modelRouteID.hasPrefix("haiku-")
    case .codex:
      return modelRouteID.hasPrefix("gpt-")
        || modelRouteID.hasPrefix("chatgpt-")
    case .grok:
      return modelRouteID.hasPrefix("grok-")
    }
  }
}

public struct TatwoLoopPayloadV1: Codable, Sendable, Equatable {
  public let contractID: String
  public let goalID: String
  public let identity: IdentityKind
  public let mode: TatwoLoopModeV1
  public let taskDescription: String
  /// Optional remote agent kind (grok/codex/claude). Omitted in legacy payloads.
  public let agent: TatwoRemoteAgentKindV1?
  /// Canonical model route committed into the signed job digest.
  ///
  /// Legacy payloads may decode without it, but production dispatch and the
  /// target agent engine both fail closed until an exact route is present.
  public let exactModelRouteID: String?

  public init(
    contractID: String,
    goalID: String,
    identity: IdentityKind,
    mode: TatwoLoopModeV1,
    taskDescription: String,
    agent: TatwoRemoteAgentKindV1? = nil,
    exactModelRouteID: String? = nil
  ) {
    self.contractID = contractID
    self.goalID = goalID
    self.identity = identity
    self.mode = mode
    self.taskDescription = taskDescription
    self.agent = agent
    self.exactModelRouteID = exactModelRouteID
  }

  /// The interface is intentionally present for schema compatibility, but execution is
  /// hard-disabled in WS1. A decoded payload is never allowed to opt itself in.
  public var isDisabled: Bool { true }

  public func validate() throws {
    let identifiers = [contractID, goalID, taskDescription]
    guard identifiers.allSatisfy({
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !$0.contains("\0")
    }) else {
      throw TatwoLoopJobStateError.invalidPayload(
        "tatwo-loop requires contractID, goalID, and taskDescription")
    }
    if let exactModelRouteID {
      guard let agent else {
        throw TatwoLoopJobStateError.invalidPayload(
          "tatwo-loop exactModelRouteID requires an exact agent")
      }
      guard
        TatwoModelIdentityRegistry.canonicalModelID(for: exactModelRouteID)
          == exactModelRouteID,
        TatwoModelIdentityRegistry.isActiveDispatchEligible(exactModelRouteID),
        agent.acceptsExactModelRouteID(exactModelRouteID)
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "tatwo-loop exact model route is invalid for \(agent.rawValue)")
      }
    }
  }
}

public enum TatwoLoopJobPayloadV1: Codable, Sendable, Equatable {
  case shellSafe(TatwoShellSafePayloadV1)
  case tatwoLoop(TatwoLoopPayloadV1)

  private enum CodingKeys: String, CodingKey {
    case kind
    case command
    case arguments
    case contractID
    case goalID
    case identity
    case mode
    case taskDescription
    case agent
    case exactModelRouteID
    case engineBinding
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .shellSafe(payload):
      try container.encode("shell-safe", forKey: .kind)
      try container.encode(payload.command, forKey: .command)
      try container.encode(payload.arguments, forKey: .arguments)
    case let .tatwoLoop(payload):
      try container.encode("tatwo-loop", forKey: .kind)
      try container.encode(payload.contractID, forKey: .contractID)
      try container.encode(payload.goalID, forKey: .goalID)
      try container.encode(payload.identity, forKey: .identity)
      try container.encode(payload.mode, forKey: .mode)
      try container.encode(payload.taskDescription, forKey: .taskDescription)
      try container.encodeIfPresent(payload.agent, forKey: .agent)
      try container.encodeIfPresent(payload.exactModelRouteID, forKey: .exactModelRouteID)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "shell-safe":
      let arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
      let command = try container.decode(TatwoShellSafeCommandV1.self, forKey: .command)
      self = .shellSafe(
        TatwoShellSafePayloadV1(command: command, arguments: arguments))
    case "tatwo-loop":
      guard !container.contains(.engineBinding) else {
        throw TatwoLoopJobStateError.invalidPayload(
          "engineBinding is forbidden in tatwo-loop payloads")
      }
      self = .tatwoLoop(
        TatwoLoopPayloadV1(
          contractID: try container.decode(String.self, forKey: .contractID),
          goalID: try container.decode(String.self, forKey: .goalID),
          identity: try container.decode(IdentityKind.self, forKey: .identity),
          mode: try container.decode(TatwoLoopModeV1.self, forKey: .mode),
          taskDescription: try container.decode(String.self, forKey: .taskDescription),
          agent: try container.decodeIfPresent(TatwoRemoteAgentKindV1.self, forKey: .agent),
          exactModelRouteID: try container.decodeIfPresent(
            String.self,
            forKey: .exactModelRouteID)))
    default:
      throw TatwoLoopJobStateError.invalidPayload("unknown kind \(kind)")
    }
  }

  public func validate() throws {
    switch self {
    case let .shellSafe(payload):
      switch payload.command {
      case .echo:
        break
      case .sleep:
        guard payload.arguments.count == 1,
          let duration = Double(payload.arguments[0]),
          duration.isFinite,
          duration >= 0
        else {
          throw TatwoLoopJobStateError.invalidPayload("sleep requires one non-negative duration")
        }
      case .true, .false:
        guard payload.arguments.isEmpty else {
          throw TatwoLoopJobStateError.invalidPayload(
            "\(payload.command.rawValue) does not accept arguments")
        }
      }
    case let .tatwoLoop(payload):
      try payload.validate()
    }
  }
}

public struct TatwoRemoteDispatchReadinessBindingV1: Codable, Sendable, Equatable {
  /// Stable target-owned workspace mapping identifier.
  public let workspaceBindingID: String
  /// Digest of the target-owned canonical path plus stable filesystem identity
  /// (for example volume/device/inode identity). The origin never derives this
  /// value from its own filesystem view.
  public let workspaceBindingDigest: String
  public let agentModelCapabilityDigest: String
  public let activeSkillSetDigest: String
  /// Per-attempt challenge. Recovery dispatches must mint a fresh value.
  public let challengeNonce: String

  public init(
    workspaceBindingID: String,
    workspaceBindingDigest: String,
    agentModelCapabilityDigest: String,
    activeSkillSetDigest: String,
    challengeNonce: String
  ) {
    self.workspaceBindingID = workspaceBindingID
    self.workspaceBindingDigest = workspaceBindingDigest
    self.agentModelCapabilityDigest = agentModelCapabilityDigest
    self.activeSkillSetDigest = activeSkillSetDigest
    self.challengeNonce = challengeNonce
  }

  public func validate() throws {
    let values = [
      workspaceBindingID,
      workspaceBindingDigest,
      agentModelCapabilityDigest,
      activeSkillSetDigest,
      challengeNonce,
    ]
    guard values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
      throw TatwoLoopJobStateError.invalidPayload(
        "remote dispatch readiness binding contains an empty or invalid value")
    }
    let digests = [
      workspaceBindingDigest,
      agentModelCapabilityDigest,
      activeSkillSetDigest,
    ]
    guard digests.allSatisfy({
      $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }) else {
      throw TatwoLoopJobStateError.invalidPayload(
        "remote dispatch readiness digests must be lowercase SHA-256")
    }
  }
}

/// Portable, opaque selector for a target-owned workspace registry entry.
///
/// It deliberately carries no path. `registryGeneration` fences stale mappings
/// while recovery attempts for the same target preserve the selector.
public struct TatwoRemoteWorkspaceLocatorV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoRemoteWorkspaceLocatorV1"
  public let schema: String
  public let version: Int
  public let workspaceBindingID: String
  public let registryGeneration: UInt64

  public init(
    schema: String = Self.schemaName,
    version: Int = 1,
    workspaceBindingID: String,
    registryGeneration: UInt64
  ) {
    self.schema = schema
    self.version = version
    self.workspaceBindingID = workspaceBindingID
    self.registryGeneration = registryGeneration
  }

  public func validate() throws {
    guard schema == Self.schemaName,
      version == 1,
      registryGeneration > 0,
      !workspaceBindingID.isEmpty,
      !workspaceBindingID.contains("\0")
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "remote workspace locator is invalid")
    }
  }
}

public struct TatwoLoopJobV1: Codable, Sendable, Equatable, Identifiable {
  public let schema: String
  public let schemaVersion: Int
  public let jobID: String
  /// Stable logical work identity across recovery re-dispatches.
  public let logicalJobID: String
  /// Non-reusable dispatch attempt binding.
  ///
  /// Execution claims are keyed by `jobID` (not logicalJobID). After crash-after-claim,
  /// recovery must mint a **new jobID + new dispatchNonce** while keeping `logicalJobID`.
  /// Reusing the same jobID with a different nonce is a binding conflict, not a new attempt.
  public let dispatchNonce: String
  public let contractID: String
  public let goalID: String
  public let identity: IdentityKind
  public let originDeviceID: String
  public let targetDeviceID: String
  /// Production remote-compute authorization bound into the signed job digest.
  ///
  /// Legacy/test jobs may decode without this field, but production dispatch
  /// rejects a missing invocation before registry reservation or channel write.
  public let remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1?
  /// Target readiness expectations committed into the signed job digest.
  ///
  /// Legacy jobs may decode without this additive field. The production
  /// GoalRun dispatch path rejects it before registry reservation.
  public let remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1?
  /// Opaque target-owned workspace selector. Production agent jobs require it;
  /// `workPath` remains only for legacy tests and shell-safe compatibility.
  public let workspaceLocator: TatwoRemoteWorkspaceLocatorV1?
  public let payload: TatwoLoopJobPayloadV1
  public let workPath: String
  public let resourceCaps: TatwoLoopResourceCapsV1
  public let stopConditions: TatwoLoopStopConditionsV1
  public let createdAt: Date

  public var id: String { jobID }

  public init(
    schema: String = "TatwoLoopJobV1",
    schemaVersion: Int = 1,
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String = UUID().uuidString,
    contractID: String,
    goalID: String,
    identity: IdentityKind,
    originDeviceID: String,
    targetDeviceID: String,
    remoteBorrowInvocation: TatwoRemoteBorrowInvocationV1? = nil,
    remoteDispatchReadiness: TatwoRemoteDispatchReadinessBindingV1? = nil,
    workspaceLocator: TatwoRemoteWorkspaceLocatorV1? = nil,
    payload: TatwoLoopJobPayloadV1,
    workPath: String,
    resourceCaps: TatwoLoopResourceCapsV1,
    stopConditions: TatwoLoopStopConditionsV1,
    createdAt: Date
  ) {
    self.schema = schema
    self.schemaVersion = schemaVersion
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.contractID = contractID
    self.goalID = goalID
    self.identity = identity
    self.originDeviceID = originDeviceID
    self.targetDeviceID = targetDeviceID
    self.remoteBorrowInvocation = remoteBorrowInvocation
    self.remoteDispatchReadiness = remoteDispatchReadiness
    self.workspaceLocator = workspaceLocator
    self.payload = payload
    self.workPath = workPath
    self.resourceCaps = resourceCaps
    self.stopConditions = stopConditions
    self.createdAt = createdAt
  }

  public func validate() throws {
    let pathIDs = [jobID, originDeviceID, targetDeviceID, dispatchNonce]
    let freeForm = [logicalJobID, contractID, goalID]
    guard schema == "TatwoLoopJobV1",
      schemaVersion == 1,
      pathIDs.allSatisfy({ TatwoLoopPathComponent.isValid($0) }),
      freeForm.allSatisfy({ !$0.isEmpty && !$0.contains("\0") })
    else {
      throw TatwoLoopJobStateError.invalidJob(jobID)
    }
    if let remoteBorrowInvocation {
      try remoteBorrowInvocation.validate(
        targetDeviceID: targetDeviceID,
        contractID: contractID,
        goalID: goalID)
    }
    try remoteDispatchReadiness?.validate()
    try workspaceLocator?.validate()
    if let workspaceLocator, let remoteDispatchReadiness {
      guard workspaceLocator.workspaceBindingID
        == remoteDispatchReadiness.workspaceBindingID
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "workspace locator does not match readiness binding")
      }
    }
    try resourceCaps.validate()
    try payload.validate()
    switch payload {
    case let .tatwoLoop(loop):
      guard workspaceLocator != nil || (!workPath.isEmpty && !workPath.contains("\0")) else {
        throw TatwoLoopJobStateError.invalidPayload(
          "tatwo-loop requires a workspace locator or legacy workPath")
      }
      guard loop.contractID == contractID,
        loop.goalID == goalID,
        loop.identity == identity
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "tatwo-loop scope does not match the enclosing job")
      }
    case .shellSafe:
      guard !workPath.isEmpty, !workPath.contains("\0") else {
        throw TatwoLoopJobStateError.invalidPayload(
          "shell-safe requires workPath")
      }
    }
  }

  /// Stable signed-job digest used by registry binding and converge replay guards.
  public func canonicalDigest() throws -> String {
    try TatwoLoopJobDigest.canonicalJSONDigest(self)
  }

  /// Crash-after-claim / lease-recovery dispatch: new `jobID` + new `dispatchNonce`,
  /// same `logicalJobID`. Optional `newTargetDeviceID` retargets a fleet reassignment.
  ///
  /// Target execution claims are durable per jobID. Retrying the same jobID after a claim
  /// without a result is refuse-by-design; operators re-dispatch via this helper.
  /// Never revokes the prior claim (anti-replay stays intact).
  public func mintRecoveryDispatch(
    newJobID: String = UUID().uuidString,
    newDispatchNonce: String = UUID().uuidString,
    newTargetDeviceID: String? = nil,
    newReadinessChallengeNonce: String = UUID().uuidString,
    createdAt: Date = Date()
  ) -> TatwoLoopJobV1 {
    TatwoLoopJobV1(
      schema: schema,
      schemaVersion: schemaVersion,
      jobID: newJobID,
      logicalJobID: logicalJobID,
      dispatchNonce: newDispatchNonce,
      contractID: contractID,
      goalID: goalID,
      identity: identity,
      originDeviceID: originDeviceID,
      targetDeviceID: newTargetDeviceID ?? targetDeviceID,
      remoteBorrowInvocation: remoteBorrowInvocation.map {
        TatwoRemoteBorrowInvocationV1(
          sessionID: $0.sessionID,
          targetDeviceID: newTargetDeviceID ?? $0.targetDeviceID,
          contractID: $0.contractID,
          goalID: $0.goalID,
          mode: $0.mode,
          risk: $0.risk,
          grantID: $0.grantID,
          oneShotApprovalID: $0.oneShotApprovalID)
      },
      remoteDispatchReadiness: remoteDispatchReadiness.map {
        if let newTargetDeviceID, newTargetDeviceID != targetDeviceID {
          // A target-owned workspace/capability/Skill binding is not portable
          // across devices. Retargeted recovery must supply a new binding later;
          // production dispatch will reject this nil binding until then.
          return nil
        }
        return TatwoRemoteDispatchReadinessBindingV1(
          workspaceBindingID: $0.workspaceBindingID,
          workspaceBindingDigest: $0.workspaceBindingDigest,
          agentModelCapabilityDigest: $0.agentModelCapabilityDigest,
          activeSkillSetDigest: $0.activeSkillSetDigest,
          challengeNonce: newReadinessChallengeNonce)
      } ?? nil,
      workspaceLocator: {
        if let newTargetDeviceID, newTargetDeviceID != targetDeviceID {
          return nil
        }
        return workspaceLocator
      }(),
      payload: payload,
      workPath: workPath,
      resourceCaps: resourceCaps,
      stopConditions: stopConditions,
      createdAt: createdAt)
  }
}

/// Strict path-component whitelist for channel filenames (jobID / deviceID).
/// ASCII alnum + `-` + `_` only. Rejects empty, `.`, `..`, separators, NUL.
public enum TatwoLoopPathComponent {
  private static let allowed = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

  public static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty,
      value != ".",
      value != "..",
      !value.contains("/"),
      !value.contains("\\"),
      !value.contains("\0"),
      value.allSatisfy({ allowed.contains($0) })
    else {
      return false
    }
    return true
  }

  /// Path-safe form: valid values pass through; anything else becomes `invalid-<digest>`.
  public static func sanitize(_ value: String) -> String {
    if isValid(value) { return value }
    let digest = TatwoLoopJobDigest.sha256(Data(value.utf8))
    return "invalid-\(digest.dropFirst(7))"
  }
}

public struct TatwoLoopJobJournalEntryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let logicalJobID: String
  /// Attempt binding — must match the signed job's dispatchNonce.
  public let dispatchNonce: String
  /// Attempt binding — must match the signed job's canonical digest.
  public let jobCanonicalDigest: String
  /// Monotonic 1-based index within the signed journal (projection sequence source).
  public let sequence: UInt64
  public let from: TatwoLoopJobStatusV1?
  public let to: TatwoLoopJobStatusV1
  public let reason: String
  public let occurredAt: Date

  public init(
    schema: String = "TatwoLoopJobJournalEntryV1",
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    sequence: UInt64,
    from: TatwoLoopJobStatusV1?,
    to: TatwoLoopJobStatusV1,
    reason: String,
    occurredAt: Date
  ) {
    self.schema = schema
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.sequence = sequence
    self.from = from
    self.to = to
    self.reason = reason
    self.occurredAt = occurredAt
  }
}

/// Design 5.6-1「已啟動」typed receipt (handoff-started equivalent for remote-loop).
///
/// **Why a typed reader, not a second on-disk artifact:** the durable channel
/// journal already records `to=.accepted` with reason `runner-accepted`, attempt
/// bindings (`dispatchNonce` + `jobCanonicalDigest`), `occurredAt`, and a
/// re-signed journal ledger (target/origin signer). Writing a separate start
/// file would duplicate evidence without a stronger safety property. Callers
/// should use `TatwoLoopJobChannel.startReceipt(for:)` to project this shape.
///
/// **Signer semantics:** `journalSignature` is the **current** journal ledger
/// signature at read time. Allowed signers are origin **or** target. This is
/// **not** a frozen target-only start artifact from accept-time; origin may
/// legitimately re-sign the journal later. Consumers must not interpret
/// `journalSignature` as "receiver-only accept proof".
public struct TatwoLoopStartReceiptV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoLoopStartReceiptV1"
  /// Canonical journal reason for runner「已啟動」.
  public static let runnerAcceptedReason = "runner-accepted"

  public let schema: String
  public let jobID: String
  /// Attempt key (channel `dispatchNonce`).
  public let attempt: String
  public let jobCanonicalDigest: String
  public let acceptedAt: Date
  public let journalSequence: UInt64
  public let reason: String
  public let targetDeviceID: String
  /// Current journal ledger signature (origin or target; see type docs).
  public let journalSignature: TatwoDeviceSignatureV1

  /// Convenience: signer device id of `journalSignature` (not necessarily target).
  public var journalSignerDeviceID: String { journalSignature.deviceID }

  public init(
    schema: String = TatwoLoopStartReceiptV1.schemaName,
    jobID: String,
    attempt: String,
    jobCanonicalDigest: String,
    acceptedAt: Date,
    journalSequence: UInt64,
    reason: String = TatwoLoopStartReceiptV1.runnerAcceptedReason,
    targetDeviceID: String,
    journalSignature: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.jobID = jobID
    self.attempt = attempt
    self.jobCanonicalDigest = jobCanonicalDigest
    self.acceptedAt = acceptedAt
    self.journalSequence = journalSequence
    self.reason = reason
    self.targetDeviceID = targetDeviceID
    self.journalSignature = journalSignature
  }

  /// Build from a durable journal entry + verified journal signature (no extra disk write).
  public static func fromJournalEntry(
    _ entry: TatwoLoopJobJournalEntryV1,
    job: TatwoLoopJobV1,
    journalSignature: TatwoDeviceSignatureV1
  ) throws -> TatwoLoopStartReceiptV1 {
    guard entry.to == .accepted else {
      throw TatwoLoopJobStateError.invalidPayload(
        "start receipt requires journal to=.accepted, got \(entry.to.rawValue)")
    }
    guard entry.jobID == job.jobID else {
      throw TatwoLoopJobStateError.invalidPayload(
        "start receipt jobID mismatch entry=\(entry.jobID) job=\(job.jobID)")
    }
    guard entry.dispatchNonce == job.dispatchNonce,
      entry.jobCanonicalDigest == (try job.canonicalDigest())
    else {
      throw TatwoLoopJobStateError.attemptBindingMismatch(
        jobID: job.jobID,
        detail: "start receipt attempt binding does not match signed job")
    }
    let allowedSigners = Set([job.originDeviceID, job.targetDeviceID])
    guard allowedSigners.contains(journalSignature.deviceID) else {
      throw TatwoLoopJobStateError.signatureRejected(
        jobID: job.jobID,
        reason: "start receipt journal signer \(journalSignature.deviceID) not origin/target")
    }
    return TatwoLoopStartReceiptV1(
      jobID: entry.jobID,
      attempt: entry.dispatchNonce,
      jobCanonicalDigest: entry.jobCanonicalDigest,
      acceptedAt: entry.occurredAt,
      journalSequence: entry.sequence,
      reason: entry.reason,
      targetDeviceID: job.targetDeviceID,
      journalSignature: journalSignature)
  }
}

public struct TatwoLoopJobResultReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  /// Signed projection sequence derived from journal transition index at result write.
  public let projectionSequence: UInt64
  public let status: TatwoLoopJobStatusV1
  public let outputDigest: String?
  public let outputBytes: Int
  /// True when engine output was truncated to `maxOutputBytes` (digest covers truncated bytes).
  public let outputTruncated: Bool
  public let exitCode: Int32?
  public let failureCode: String?
  public let message: String?
  /// Readiness digest committed into the signed job.
  public let expectedActiveSkillSetDigest: String?
  /// Target agent's post-launch readback of the exact loaded Skill projection.
  public let actualLoadedSkillSetDigest: String?
  /// Provider-observed model identity. Request-side route alone is insufficient.
  public let modelExecutionAttestation: TatwoModelExecutionAttestationV1?
  public let startedAt: Date
  public let finishedAt: Date

  public init(
    schema: String = "TatwoLoopJobResultReceiptV1",
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    projectionSequence: UInt64,
    status: TatwoLoopJobStatusV1,
    outputDigest: String?,
    outputBytes: Int,
    exitCode: Int32?,
    failureCode: String?,
    message: String?,
    startedAt: Date,
    finishedAt: Date,
    outputTruncated: Bool = false,
    expectedActiveSkillSetDigest: String? = nil,
    actualLoadedSkillSetDigest: String? = nil,
    modelExecutionAttestation: TatwoModelExecutionAttestationV1? = nil
  ) {
    self.schema = schema
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.projectionSequence = projectionSequence
    self.status = status
    self.outputDigest = outputDigest
    self.outputBytes = max(0, outputBytes)
    self.outputTruncated = outputTruncated
    self.exitCode = exitCode
    self.failureCode = failureCode
    self.message = message.map {
      String(TatwoPrivacyRedactor.redacted($0).prefix(512))
    }
    self.expectedActiveSkillSetDigest = expectedActiveSkillSetDigest
    self.actualLoadedSkillSetDigest = actualLoadedSkillSetDigest
    self.modelExecutionAttestation = modelExecutionAttestation
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  /// Convenience binder from the signed job + journal-derived sequence.
  public init(
    job: TatwoLoopJobV1,
    projectionSequence: UInt64,
    status: TatwoLoopJobStatusV1,
    outputDigest: String?,
    outputBytes: Int,
    exitCode: Int32?,
    failureCode: String?,
    message: String?,
    startedAt: Date,
    finishedAt: Date,
    outputTruncated: Bool = false,
    actualLoadedSkillSetDigest: String? = nil,
    modelExecutionAttestation: TatwoModelExecutionAttestationV1? = nil
  ) throws {
    let expectedActiveSkillSetDigest = job.remoteDispatchReadiness?.activeSkillSetDigest
    if case .tatwoLoop = job.payload,
      status == .completed,
      expectedActiveSkillSetDigest != actualLoadedSkillSetDigest
    {
      throw TatwoLoopJobStateError.invalidPayload(
        "completed agent result requires matching actual-loaded Skill-set digest")
    }
    self.init(
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      jobCanonicalDigest: try job.canonicalDigest(),
      projectionSequence: projectionSequence,
      status: status,
      outputDigest: outputDigest,
      outputBytes: outputBytes,
      exitCode: exitCode,
      failureCode: failureCode,
      message: message,
      startedAt: startedAt,
      finishedAt: finishedAt,
      outputTruncated: outputTruncated,
      expectedActiveSkillSetDigest: expectedActiveSkillSetDigest,
      actualLoadedSkillSetDigest: actualLoadedSkillSetDigest,
      modelExecutionAttestation: modelExecutionAttestation)
    try validateModelExecutionAttestation(for: job)
  }

  private enum CodingKeys: String, CodingKey {
    case schema
    case jobID
    case dispatchNonce
    case jobCanonicalDigest
    case projectionSequence
    case status
    case outputDigest
    case outputBytes
    case outputTruncated
    case exitCode
    case failureCode
    case message
    case expectedActiveSkillSetDigest
    case actualLoadedSkillSetDigest
    case modelExecutionAttestation
    case startedAt
    case finishedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(String.self, forKey: .schema)
    jobID = try container.decode(String.self, forKey: .jobID)
    dispatchNonce = try container.decode(String.self, forKey: .dispatchNonce)
    jobCanonicalDigest = try container.decode(String.self, forKey: .jobCanonicalDigest)
    projectionSequence = try container.decode(UInt64.self, forKey: .projectionSequence)
    status = try container.decode(TatwoLoopJobStatusV1.self, forKey: .status)
    outputDigest = try container.decodeIfPresent(String.self, forKey: .outputDigest)
    outputBytes = max(0, try container.decode(Int.self, forKey: .outputBytes))
    // Historical receipts omit the flag; default false keeps cross-check fail-closed only when set.
    outputTruncated = try container.decodeIfPresent(Bool.self, forKey: .outputTruncated) ?? false
    exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
    failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    expectedActiveSkillSetDigest = try container.decodeIfPresent(
      String.self,
      forKey: .expectedActiveSkillSetDigest)
    actualLoadedSkillSetDigest = try container.decodeIfPresent(
      String.self,
      forKey: .actualLoadedSkillSetDigest)
    modelExecutionAttestation = try container.decodeIfPresent(
      TatwoModelExecutionAttestationV1.self,
      forKey: .modelExecutionAttestation)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    finishedAt = try container.decode(Date.self, forKey: .finishedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schema, forKey: .schema)
    try container.encode(jobID, forKey: .jobID)
    try container.encode(dispatchNonce, forKey: .dispatchNonce)
    try container.encode(jobCanonicalDigest, forKey: .jobCanonicalDigest)
    try container.encode(projectionSequence, forKey: .projectionSequence)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(outputDigest, forKey: .outputDigest)
    try container.encode(outputBytes, forKey: .outputBytes)
    try container.encode(outputTruncated, forKey: .outputTruncated)
    try container.encodeIfPresent(exitCode, forKey: .exitCode)
    try container.encodeIfPresent(failureCode, forKey: .failureCode)
    try container.encodeIfPresent(message, forKey: .message)
    try container.encodeIfPresent(
      expectedActiveSkillSetDigest,
      forKey: .expectedActiveSkillSetDigest)
    try container.encodeIfPresent(
      actualLoadedSkillSetDigest,
      forKey: .actualLoadedSkillSetDigest)
    try container.encodeIfPresent(
      modelExecutionAttestation,
      forKey: .modelExecutionAttestation)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(finishedAt, forKey: .finishedAt)
  }

  /// Canonical digest of the result receipt bytes (binds receiptID / consume markers).
  public func canonicalDigest() throws -> String {
    try TatwoLoopJobDigest.canonicalJSONDigest(self)
  }

  public var hasMatchingActiveSkillReadback: Bool {
    guard let expectedActiveSkillSetDigest else {
      return actualLoadedSkillSetDigest == nil
    }
    return actualLoadedSkillSetDigest == expectedActiveSkillSetDigest
      && expectedActiveSkillSetDigest.range(
        of: #"^[0-9a-f]{64}$"#,
        options: .regularExpression) != nil
  }

  public func validateActiveSkillReadback(for job: TatwoLoopJobV1) throws {
    guard case .tatwoLoop = job.payload else {
      guard expectedActiveSkillSetDigest == nil,
        actualLoadedSkillSetDigest == nil
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "shell-safe result must not claim an agent Skill readback")
      }
      return
    }
    guard let readinessDigest = job.remoteDispatchReadiness?.activeSkillSetDigest else {
      guard expectedActiveSkillSetDigest == nil,
        actualLoadedSkillSetDigest == nil
      else {
        throw TatwoLoopJobStateError.invalidPayload(
          "legacy agent result must not claim unbound Skill readback")
      }
      return
    }
    guard expectedActiveSkillSetDigest == readinessDigest else {
      throw TatwoLoopJobStateError.invalidPayload(
        "agent result expected Skill digest does not match readiness")
    }
    switch status {
    case .completed:
      guard hasMatchingActiveSkillReadback else {
        throw TatwoLoopJobStateError.invalidPayload(
          "completed agent result Skill readback does not match readiness digest")
      }
    case .failed, .cancelled:
      if let actualLoadedSkillSetDigest {
        guard actualLoadedSkillSetDigest.range(
          of: #"^[0-9a-f]{64}$"#,
          options: .regularExpression) != nil
        else {
          throw TatwoLoopJobStateError.invalidPayload(
            "terminal agent Skill readback is not a SHA-256 digest")
        }
        guard actualLoadedSkillSetDigest == readinessDigest else {
          throw TatwoLoopJobStateError.invalidPayload(
            "terminal agent Skill readback does not match readiness digest")
        }
      }
    case .queued, .delivered, .accepted, .running, .verified:
      throw TatwoLoopJobStateError.invalidPayload(
        "agent result receipt must be terminal before Skill readback validation")
    }
  }

  /// Completion trust for exact-route Claude work comes from provider-observed
  /// evidence, never from the requested route or a valid target signature alone.
  ///
  /// Failed/cancelled receipts may preserve mismatch evidence for diagnosis.
  /// Only `.completed` is eligible for origin acceptance, so it must carry a
  /// verified exact attestation bound to the signed job route.
  public func validateModelExecutionAttestation(for job: TatwoLoopJobV1) throws {
    guard case let .tatwoLoop(payload) = job.payload, payload.agent == .claude else {
      return
    }
    guard status == .completed else { return }
    guard let modelExecutionAttestation else {
      throw TatwoLoopJobStateError.invalidPayload(
        "completed Claude result requires provider model attestation")
    }
    guard let exactModelRouteID = payload.exactModelRouteID else {
      throw TatwoLoopJobStateError.invalidPayload(
        "completed Claude result is not bound to an exact model route")
    }
    let expectedVendorModelID = try TatwoAgentEngineBinding.production
      .exactModelLaunchArgument(
        for: .claude,
        exactModelRouteID: exactModelRouteID)
    guard
      modelExecutionAttestation.requestedCanonicalModelID == exactModelRouteID,
      modelExecutionAttestation.requestedVendorModelID == expectedVendorModelID,
      modelExecutionAttestation.isVerifiedExact
    else {
      throw TatwoLoopJobStateError.invalidPayload(
        "completed Claude result exact-model attestation does not match signed job route")
    }
    let primaryRouteModels: Set<String> = [
      "claude-fable-5",
      "claude-opus-5",
      "claude-sonnet-5",
      "claude-haiku-4-5",
    ]
    let unexpectedClaudeUsage = modelExecutionAttestation.modelUsageKeys.contains { modelID in
      primaryRouteModels.contains(modelID)
        && modelID != modelExecutionAttestation.requestedVendorModelID
    }
    guard !unexpectedClaudeUsage else {
      throw TatwoLoopJobStateError.invalidPayload(
        "completed Claude result modelUsage contains a different Claude model")
    }
  }

  /// Registry receiptID bound to the result digest (not jobID alone).
  public func boundReceiptID() throws -> String {
    let digest = try canonicalDigest()
    let bare = digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
    return "remote-loop-result-\(jobID)-\(bare.prefix(32))"
  }
}

/// Verified target-produced raw output payload (channel `outputs/<jobID>`).
public struct TatwoLoopOutputArtifactV1: Sendable, Equatable {
  public let jobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let outputDigest: String
  public let outputBytes: Int
  public let outputTruncated: Bool
  public let status: TatwoLoopJobStatusV1
  public let exitCode: Int32?
  public let data: Data

  public init(
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    outputDigest: String,
    outputBytes: Int,
    outputTruncated: Bool,
    status: TatwoLoopJobStatusV1,
    exitCode: Int32?,
    data: Data
  ) {
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.outputDigest = outputDigest
    self.outputBytes = outputBytes
    self.outputTruncated = outputTruncated
    self.status = status
    self.exitCode = exitCode
    self.data = data
  }
}

/// One-time monotonic consume marker for state-changing result reads.
/// Signed by the consumer; high-water prevents resurrection after marker delete.
public struct TatwoLoopResultConsumeMarkerV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let resultDigest: String
  public let projectionSequence: UInt64
  public let consumedAt: Date
  public let authorization: TatwoDeviceSignatureV1?

  public init(
    schema: String = "TatwoLoopResultConsumeMarkerV1",
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    resultDigest: String,
    projectionSequence: UInt64,
    consumedAt: Date = Date(),
    authorization: TatwoDeviceSignatureV1? = nil
  ) {
    self.schema = schema
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.resultDigest = resultDigest
    self.projectionSequence = projectionSequence
    self.consumedAt = consumedAt
    self.authorization = authorization
  }
}

/// Monotonic consume high-water (durable anchor; production Keychain, test-mode file).
public struct TatwoLoopResultConsumeHighWaterV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let resultDigest: String
  public let projectionSequence: UInt64
  public let updatedAt: Date
  public let authorization: TatwoDeviceSignatureV1

  public init(
    schema: String = "TatwoLoopResultConsumeHighWaterV1",
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    resultDigest: String,
    projectionSequence: UInt64,
    updatedAt: Date = Date(),
    authorization: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.resultDigest = resultDigest
    self.projectionSequence = projectionSequence
    self.updatedAt = updatedAt
    self.authorization = authorization
  }
}

public struct TatwoLoopJobAckV1: Codable, Sendable, Equatable {
  public let schema: String
  public let jobID: String
  public let logicalJobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let status: TatwoLoopJobStatusV1
  public let updatedAt: Date
  public let result: TatwoLoopJobResultReceiptV1?

  public init(
    schema: String = "TatwoLoopJobAckV1",
    jobID: String,
    logicalJobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    status: TatwoLoopJobStatusV1,
    updatedAt: Date,
    result: TatwoLoopJobResultReceiptV1? = nil
  ) {
    self.schema = schema
    self.jobID = jobID
    self.logicalJobID = logicalJobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.status = status
    self.updatedAt = updatedAt
    self.result = result
  }
}

public enum TatwoLoopJobDigest {
  public static func sha256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "sha256:\(digest)"
  }

  public static func canonicalJSONDigest<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return sha256(try encoder.encode(value))
  }
}
