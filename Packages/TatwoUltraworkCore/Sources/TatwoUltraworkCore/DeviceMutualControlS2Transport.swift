import Foundation
import TatwoDomainContracts

// MARK: - Device mutual-control S2: transport via existing fleet job channel
//
// Design: docs/protocol/DEVICE_MUTUAL_CONTROL_DESIGN.md §12 S2 + K2 S1 types.
// Iron rules:
// - Reuse `TatwoLoopJobV1` (RemoteLoopJob path in RemoteLoopJob.swift) — no
//   second transport/scheduler.
// - Descriptor validation must already have passed (S1 validator).
// - high_risk requires a human-gate token on the job payload.
// - Result accept requires target signature (fleet `TatwoDeviceTrustAuthority`
//   / channel trust sign+verify) — no custom crypto.
// - Origin authority: when a lease domain is bound, source must pass
//   `isOriginAuthority` before dispatch.
// - Pure Core: builds job envelopes + verifies receipts; does **not** open
//   network, spawn processes, or write channel files.

/// Design/ticket alias: fleet job type lives in `RemoteLoopJob.swift` as `TatwoLoopJobV1`.
public typealias RemoteLoopJob = TatwoLoopJobV1

// MARK: - Job payload (carried inside fleet job taskDescription JSON)

/// Mutual-control payload embedded in a fleet `TatwoLoopJobV1` (RemoteLoopJob).
///
/// Fields required by the work order: descriptor id, argv, resource limits,
/// human-gate token (mandatory for high_risk).
public struct TatwoMutualControlJobPayloadV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoMutualControlJobPayloadV1"
  /// Marker stored in `TatwoLoopPayloadV1.taskDescription` prefix.
  public static let taskDescriptionPrefix = "mutual-control-job-v1:"

  public let schema: String
  public let templateID: String
  public let descriptorDigest: String
  public let resolvedExecutable: String
  public let resolvedArgv: [String]
  public let timeoutSec: TimeInterval
  public let maxOutputBytes: Int
  public let humanGateToken: String?
  public let riskLevel: TatwoMutualControlRiskLevelV1
  public let highRiskCategory: TatwoMutualControlHighRiskCategoryV1?
  public let requiresHumanGate: Bool
  public let invokeCanonicalDigest: String
  public let logicalControlID: String
  public let capabilityVersion: UInt64
  public let sourceDeviceID: String
  public let operatorPrincipalID: String
  public let targetDeviceID: String

  public init(
    schema: String = TatwoMutualControlJobPayloadV1.schemaName,
    templateID: String,
    descriptorDigest: String,
    resolvedExecutable: String,
    resolvedArgv: [String],
    timeoutSec: TimeInterval,
    maxOutputBytes: Int,
    humanGateToken: String?,
    riskLevel: TatwoMutualControlRiskLevelV1,
    highRiskCategory: TatwoMutualControlHighRiskCategoryV1? = nil,
    requiresHumanGate: Bool,
    invokeCanonicalDigest: String,
    logicalControlID: String,
    capabilityVersion: UInt64,
    sourceDeviceID: String,
    operatorPrincipalID: String,
    targetDeviceID: String
  ) {
    self.schema = schema
    self.templateID = templateID
    self.descriptorDigest = descriptorDigest
    self.resolvedExecutable = resolvedExecutable
    self.resolvedArgv = resolvedArgv
    self.timeoutSec = timeoutSec
    self.maxOutputBytes = maxOutputBytes
    self.humanGateToken = humanGateToken
    self.riskLevel = riskLevel
    self.highRiskCategory = highRiskCategory
    self.requiresHumanGate = requiresHumanGate
    self.invokeCanonicalDigest = invokeCanonicalDigest
    self.logicalControlID = logicalControlID
    self.capabilityVersion = capabilityVersion
    self.sourceDeviceID = sourceDeviceID
    self.operatorPrincipalID = operatorPrincipalID
    self.targetDeviceID = targetDeviceID
  }

  public func encodeTaskDescription() throws -> String {
    let data = try TatwoMutualControlCanonicalJSON.encode(self)
    guard let json = String(data: data, encoding: .utf8) else {
      throw TatwoMutualControlDispatchErrorV1.schemaInvalid("payload UTF-8 encode failed")
    }
    return Self.taskDescriptionPrefix + json
  }

  public static func decodeTaskDescription(_ taskDescription: String) throws
    -> TatwoMutualControlJobPayloadV1
  {
    guard taskDescription.hasPrefix(taskDescriptionPrefix) else {
      throw TatwoMutualControlDispatchErrorV1.schemaInvalid(
        "taskDescription missing mutual-control prefix")
    }
    let json = String(taskDescription.dropFirst(taskDescriptionPrefix.count))
    guard let data = json.data(using: .utf8) else {
      throw TatwoMutualControlDispatchErrorV1.schemaInvalid("taskDescription not UTF-8")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let value = try decoder.decode(TatwoMutualControlJobPayloadV1.self, from: data)
    guard value.schema == schemaName else {
      throw TatwoMutualControlDispatchErrorV1.schemaInvalid(
        "payload schema \(value.schema)")
    }
    return value
  }
}

// MARK: - Dispatch envelope

/// Explicit authority context for every mutual-control dispatch.
public enum TatwoLeaseDomainBindingV1: Codable, Sendable, Equatable {
  case none(justification: String)
  case domain(id: String)

  public var domainID: String? {
    switch self {
    case .none:
      return nil
    case let .domain(id):
      return id
    }
  }

  fileprivate func validate() throws {
    switch self {
    case let .none(justification):
      guard !justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TatwoMutualControlDispatchErrorV1.leaseDomainBindingInvalid(
          "none requires an explicit justification")
      }
    case let .domain(id):
      guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TatwoMutualControlDispatchErrorV1.leaseDomainBindingInvalid(
          "domain id is empty")
      }
    }
  }
}

/// Explicit provider for a target that is intentionally outside every lease
/// domain.  Callers must name this type; nil is never an implicit no-lease
/// bypass.
public struct TatwoNoLeaseDomainAuthority: TatwoOriginAuthorityProviding {
  public let authorityDomainID: String? = nil
  public let authorityEpoch: UInt64? = nil

  public init() {}

  public func isOriginAuthority(deviceID: String, epoch: UInt64, now: Date) -> Bool {
    _ = deviceID
    _ = epoch
    _ = now
    return true
  }
}

public enum TatwoMutualControlDispatchErrorV1: Error, LocalizedError, Equatable, Sendable {
  case validationNotAccepted(TatwoMutualControlErrorCodeV1?, String)
  case validationProofInvalid
  case descriptorDigestRequired
  case highRiskMissingHumanGateToken
  case leaseDomainBindingInvalid(String)
  case leaseDomainBindingMismatch
  case originAuthorityProviderRequired
  case originAuthorityDenied(deviceID: String, epoch: UInt64)
  case resultSignatureMissing
  case resultSignatureInvalid(String)
  case attemptBindingMismatch(String)
  case schemaInvalid(String)
  case unsignedResultRejected

  public var errorDescription: String? {
    switch self {
    case let .validationNotAccepted(code, detail):
      "mutual-control dispatch requires accepted validation (\(code?.rawValue ?? "nil")): \(detail)"
    case .validationProofInvalid:
      "mutual-control dispatch rejected: validation was not issued by the signed-manifest validator"
    case .descriptorDigestRequired:
      "mutual-control dispatch requires a bound descriptor digest"
    case .highRiskMissingHumanGateToken:
      "high_risk mutual-control dispatch requires human gate token"
    case let .leaseDomainBindingInvalid(detail):
      "mutual-control dispatch lease-domain binding invalid: \(detail)"
    case .leaseDomainBindingMismatch:
      "mutual-control dispatch lease-domain binding does not match invocation"
    case .originAuthorityProviderRequired:
      "mutual-control dispatch requires an explicit origin-authority provider"
    case let .originAuthorityDenied(deviceID, epoch):
      "origin authority denied for device \(deviceID) epoch \(epoch)"
    case .resultSignatureMissing, .unsignedResultRejected:
      "mutual-control result rejected: target signature missing"
    case let .resultSignatureInvalid(detail):
      "mutual-control result signature invalid: \(detail)"
    case let .attemptBindingMismatch(detail):
      "mutual-control attempt binding mismatch: \(detail)"
    case let .schemaInvalid(detail):
      "mutual-control dispatch schema invalid: \(detail)"
    }
  }
}

/// Validated invocation packaged as an existing fleet `RemoteLoopJob` (`TatwoLoopJobV1`).
///
/// Does **not** enqueue, network, or execute. Callers that later write the job
/// must still go through `RemoteLoopJobChannel` / fleet scheduler.
public struct TatwoMutualControlDispatchV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoMutualControlDispatchV1"
  public static let contractID = "device-mutual-control-s2"
  public static let goalID = "device-mutual-control-invoke"

  public let schema: String
  public let dispatchID: String
  /// Existing fleet job type (`RemoteLoopJob` typealias → `TatwoLoopJobV1`).
  public let remoteLoopJob: TatwoLoopJobV1
  public let payload: TatwoMutualControlJobPayloadV1
  public let leaseDomainBinding: TatwoLeaseDomainBindingV1
  public let producedAt: Date

  internal init(
    schema: String = TatwoMutualControlDispatchV1.schemaName,
    dispatchID: String = UUID().uuidString,
    remoteLoopJob: TatwoLoopJobV1,
    payload: TatwoMutualControlJobPayloadV1,
    leaseDomainBinding: TatwoLeaseDomainBindingV1,
    producedAt: Date
  ) {
    self.schema = schema
    self.dispatchID = dispatchID
    self.remoteLoopJob = remoteLoopJob
    self.payload = payload
    self.leaseDomainBinding = leaseDomainBinding
    self.producedAt = producedAt
  }

  /// Ticket/doc alias for the fleet job field.
  public var fleetJob: TatwoLoopJobV1 { remoteLoopJob }

  /// Build a dispatch envelope from a **pre-validated** invocation.
  ///
  /// Force points:
  /// 1. `validation.accepted` must be true
  /// 2. high_risk requires non-empty human gate token (approvalID)
  /// 3. when lease domain is bound, source must pass `isOriginAuthority`
  public static func make(
    invocation: TatwoMutualControlInvocationV1,
    validation: TatwoMutualControlValidationResultV1,
    resourceLimits: TatwoMutualControlResourceLimitsV1,
    descriptorDigest: String?,
    leaseDomainBinding: TatwoLeaseDomainBindingV1,
    originAuthorityProvider: any TatwoOriginAuthorityProviding,
    now: Date = Date(),
    dispatchID: String = UUID().uuidString
  ) throws -> TatwoMutualControlDispatchV1 {
    try leaseDomainBinding.validate()
    guard validation.accepted else {
      throw TatwoMutualControlDispatchErrorV1.validationNotAccepted(
        validation.errorCode,
        validation.detail ?? "validation not accepted")
    }
    guard validation.isValidatorIssued else {
      throw TatwoMutualControlDispatchErrorV1.validationProofInvalid
    }
    guard invocation.leaseDomainBinding == leaseDomainBinding else {
      throw TatwoMutualControlDispatchErrorV1.leaseDomainBindingMismatch
    }
    guard let descriptorDigest,
      !descriptorDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      validation.descriptorDigest == descriptorDigest
    else {
      throw TatwoMutualControlDispatchErrorV1.descriptorDigestRequired
    }

    let risk = validation.riskLevel ?? .normal
    let requiresGate = validation.requiresHumanGate || risk == .highRisk
    let humanGateToken = invocation.approvalID?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if requiresGate {
      guard let humanGateToken, !humanGateToken.isEmpty else {
        throw TatwoMutualControlDispatchErrorV1.highRiskMissingHumanGateToken
      }
    }

    switch leaseDomainBinding {
    case .none:
      guard originAuthorityProvider is TatwoNoLeaseDomainAuthority else {
        throw TatwoMutualControlDispatchErrorV1.leaseDomainBindingInvalid(
          "none requires TatwoNoLeaseDomainAuthority()")
      }
      try originAuthorityProvider.requireOriginAuthority(
        deviceID: invocation.sourceDeviceID,
        epoch: originAuthorityProvider.authorityEpoch ?? 0,
        surface: "device-mutual-control-s2",
        now: now)
    case let .domain(id):
      guard originAuthorityProvider.authorityDomainID == id else {
        throw TatwoMutualControlDispatchErrorV1.leaseDomainBindingInvalid(
          "provider domain does not match binding")
      }
      let epoch = originAuthorityProvider.authorityEpoch ?? 0
      do {
        try originAuthorityProvider.requireOriginAuthority(
          deviceID: invocation.sourceDeviceID,
          epoch: epoch,
          surface: "device-mutual-control-s2",
          now: now)
      } catch {
        throw TatwoMutualControlDispatchErrorV1.originAuthorityDenied(
          deviceID: invocation.sourceDeviceID,
          epoch: epoch)
      }
    }

    let digest = try validation.invokeCanonicalDigest
      ?? invocation.invokeCanonicalDigest
      ?? invocation.computeInvokeCanonicalDigest()
    let resolvedArgv = validation.resolvedArgv ?? []
    let resolvedExecutable = validation.resolvedExecutable ?? ""
    guard !resolvedExecutable.isEmpty else {
      throw TatwoMutualControlDispatchErrorV1.schemaInvalid(
        "validated invocation missing resolvedExecutable")
    }

    let timeoutSec = min(
      invocation.requestedTimeoutSec ?? resourceLimits.timeoutSec,
      resourceLimits.timeoutSec)
    let maxOutputBytes = min(
      invocation.requestedMaxOutputBytes ?? resourceLimits.maxOutputBytes,
      resourceLimits.maxOutputBytes)

    let payload = TatwoMutualControlJobPayloadV1(
      templateID: validation.templateID ?? invocation.templateID,
      descriptorDigest: descriptorDigest,
      resolvedExecutable: resolvedExecutable,
      resolvedArgv: resolvedArgv,
      timeoutSec: timeoutSec,
      maxOutputBytes: maxOutputBytes,
      humanGateToken: humanGateToken,
      riskLevel: risk,
      highRiskCategory: validation.highRiskCategory,
      requiresHumanGate: requiresGate,
      invokeCanonicalDigest: digest,
      logicalControlID: invocation.logicalControlID,
      capabilityVersion: validation.capabilityVersion ?? invocation.capabilityVersion,
      sourceDeviceID: invocation.sourceDeviceID,
      operatorPrincipalID: invocation.operatorPrincipalID,
      targetDeviceID: invocation.targetDeviceID)

    let taskDescription = try payload.encodeTaskDescription()
    let loopPayload = TatwoLoopJobPayloadV1.tatwoLoop(
      TatwoLoopPayloadV1(
        contractID: contractID,
        goalID: goalID,
        identity: .sub,
        mode: .m,
        taskDescription: taskDescription,
        agent: nil))

    // Path components must satisfy TatwoLoopPathComponent (alnum/_/-).
    let jobID = TatwoLoopPathComponent.sanitize(invocation.jobID)
    let dispatchNonce = TatwoLoopPathComponent.sanitize(invocation.dispatchNonce)
    let originID = TatwoLoopPathComponent.sanitize(invocation.sourceDeviceID)
    let targetID = TatwoLoopPathComponent.sanitize(invocation.targetDeviceID)

    let job = TatwoLoopJobV1(
      jobID: jobID,
      logicalJobID: invocation.logicalControlID,
      dispatchNonce: dispatchNonce,
      contractID: contractID,
      goalID: goalID,
      identity: .sub,
      originDeviceID: originID,
      targetDeviceID: targetID,
      payload: loopPayload,
      workPath: "mutual-control/\(jobID)",
      resourceCaps: TatwoLoopResourceCapsV1(
        maxDurationSec: timeoutSec,
        maxOutputBytes: maxOutputBytes),
      stopConditions: TatwoLoopStopConditionsV1(
        cancelFileSignal: true,
        rules: ["mutual-control", "human-gate-if-high-risk"]),
      createdAt: now)
    try job.validate()

    return TatwoMutualControlDispatchV1(
      dispatchID: dispatchID,
      remoteLoopJob: job,
      payload: payload,
      leaseDomainBinding: leaseDomainBinding,
      producedAt: now)
  }
}

// MARK: - Result recovery (signed)

/// Unsigned body signed by the target for result recovery (fleet authority).
public struct TatwoMutualControlResultBindingV1: Codable, Sendable, Equatable {
  public let jobID: String
  public let dispatchNonce: String
  public let invokeCanonicalDigest: String
  public let exitCode: Int32?
  public let actualArgv: [String]
  public let executableResolved: String
  public let startedAt: String
  public let endedAt: String
  public let stdoutArtifactPath: String?
  public let stdoutArtifactHash: String?
  public let stderrArtifactPath: String?
  public let stderrArtifactHash: String?

  public init(
    jobID: String,
    dispatchNonce: String,
    invokeCanonicalDigest: String,
    exitCode: Int32?,
    actualArgv: [String],
    executableResolved: String,
    startedAt: String,
    endedAt: String,
    stdoutArtifactPath: String? = nil,
    stdoutArtifactHash: String? = nil,
    stderrArtifactPath: String? = nil,
    stderrArtifactHash: String? = nil
  ) {
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.invokeCanonicalDigest = invokeCanonicalDigest
    self.exitCode = exitCode
    self.actualArgv = actualArgv
    self.executableResolved = executableResolved
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.stdoutArtifactPath = stdoutArtifactPath
    self.stdoutArtifactHash = stdoutArtifactHash
    self.stderrArtifactPath = stderrArtifactPath
    self.stderrArtifactHash = stderrArtifactHash
  }

  public func canonicalPayload() throws -> Data {
    try TatwoMutualControlCanonicalJSON.encode(self)
  }
}

/// Pure Core result accept: require target signature via fleet trust authority.
public enum TatwoMutualControlResultRecoveryV1 {
  /// Purpose string for target-signed results (reuses device-trust sign/verify API;
  /// not a new crypto algorithm).
  public static let resultPurpose = "device_mutual_control_result"

  /// Accept a completed result. Unsigned results are rejected.
  ///
  /// - Parameters:
  ///   - dispatch: original dispatch envelope (attempt binding source)
  ///   - binding: target-reported result binding
  ///   - targetSignature: required; missing → reject
  ///   - targetTrust: target's channel trust used to sign (or peer pin set)
  ///   - verifierTrust: origin-side trust that pins the target identity
  public static func acceptCompleted(
    dispatch: TatwoMutualControlDispatchV1,
    binding: TatwoMutualControlResultBindingV1,
    targetSignature: TatwoDeviceSignatureV1?,
    verifierTrust: TatwoLoopJobChannelTrust,
    receiptID: String = UUID().uuidString,
    outputSummary: String? = nil
  ) throws -> TatwoMutualControlReceiptV1 {
    guard let targetSignature else {
      throw TatwoMutualControlDispatchErrorV1.unsignedResultRejected
    }

    // Attempt binding must match the fleet job.
    let job = dispatch.remoteLoopJob
    let payload = dispatch.payload
    if binding.jobID != job.jobID
      || binding.dispatchNonce != job.dispatchNonce
      || binding.invokeCanonicalDigest != payload.invokeCanonicalDigest
    {
      throw TatwoMutualControlDispatchErrorV1.attemptBindingMismatch(
        "jobID/dispatchNonce/invokeCanonicalDigest")
    }
    if binding.actualArgv != payload.resolvedArgv
      || binding.executableResolved != payload.resolvedExecutable
    {
      throw TatwoMutualControlDispatchErrorV1.attemptBindingMismatch(
        "actualArgv/executable must match dispatch payload")
    }

    let canonical = try binding.canonicalPayload()
    // Reuse fleet signature verification path (TatwoDeviceTrustAuthority via channel trust).
    // Target signs with `.loopResult` purpose (same crypto as RemoteLoopJobChannel results).
    do {
      try verifierTrust.verify(
        payload: canonical,
        purpose: .loopResult,
        signature: targetSignature,
        expectedDeviceID: payload.targetDeviceID,
        enforceFreshness: false)
    } catch {
      throw TatwoMutualControlDispatchErrorV1.resultSignatureInvalid(
        String(describing: error))
    }

    let stdout: TatwoMutualControlOutputArtifactRefV1?
    if let path = binding.stdoutArtifactPath, let hash = binding.stdoutArtifactHash {
      stdout = TatwoMutualControlOutputArtifactRefV1(relativePath: path, contentHash: hash)
    } else {
      stdout = nil
    }
    let stderr: TatwoMutualControlOutputArtifactRefV1?
    if let path = binding.stderrArtifactPath, let hash = binding.stderrArtifactHash {
      stderr = TatwoMutualControlOutputArtifactRefV1(relativePath: path, contentHash: hash)
    } else {
      stderr = nil
    }

    return TatwoMutualControlReceiptV1(
      receiptID: receiptID,
      status: .completed,
      logicalControlID: payload.logicalControlID,
      jobID: job.jobID,
      dispatchNonce: job.dispatchNonce,
      invokeCanonicalDigest: payload.invokeCanonicalDigest,
      sourceDeviceID: payload.sourceDeviceID,
      operatorPrincipalID: payload.operatorPrincipalID,
      targetDeviceID: payload.targetDeviceID,
      templateID: payload.templateID,
      capabilityVersion: payload.capabilityVersion,
      actualArgv: binding.actualArgv,
      executableResolved: binding.executableResolved,
      startedAt: binding.startedAt,
      endedAt: binding.endedAt,
      exitCode: binding.exitCode,
      outputSummary: outputSummary,
      stdoutArtifact: stdout,
      stderrArtifact: stderr,
      approvalID: payload.humanGateToken,
      requiresHumanGate: payload.requiresHumanGate,
      riskLevel: payload.riskLevel,
      highRiskCategory: payload.highRiskCategory,
      targetSignature: targetSignature,
      signingKeyFingerprint: targetSignature.keyID)
  }

  /// Sign a result binding as the target (test / target-side helper).
  /// Uses fleet channel trust signing (`loop-result` purpose) — no custom crypto.
  public static func signResultBinding(
    binding: TatwoMutualControlResultBindingV1,
    targetTrust: TatwoLoopJobChannelTrust,
    signedAt: Date = Date()
  ) throws -> TatwoDeviceSignatureV1 {
    try targetTrust.sign(
      payload: try binding.canonicalPayload(),
      purpose: .loopResult,
      signedAt: signedAt)
  }

}

// MARK: - Transport seam implementation (in-memory / pure; no IO)

/// S2 pure-Core seam: packages dispatch and accepts signed receipts without
/// touching the network or channel filesystem. Production hosts may wrap this
/// and hand `remoteLoopJob` to `RemoteLoopJobChannel.enqueue`.
public struct TatwoMutualControlCoreTransportV1: TatwoMutualControlTransportSeamV1, Sendable {
  public let resourceLimits: TatwoMutualControlResourceLimitsV1
  public let originAuthorityProvider: any TatwoOriginAuthorityProviding
  public let leaseDomainBinding: TatwoLeaseDomainBindingV1
  public let verifierTrust: TatwoLoopJobChannelTrust?

  public init(
    resourceLimits: TatwoMutualControlResourceLimitsV1,
    originAuthorityProvider: any TatwoOriginAuthorityProviding,
    leaseDomainBinding: TatwoLeaseDomainBindingV1,
    verifierTrust: TatwoLoopJobChannelTrust? = nil
  ) {
    self.resourceLimits = resourceLimits
    self.originAuthorityProvider = originAuthorityProvider
    self.leaseDomainBinding = leaseDomainBinding
    self.verifierTrust = verifierTrust
  }

  public func deliverInvoke(
    invocation: TatwoMutualControlInvocationV1,
    validation: TatwoMutualControlValidationResultV1
  ) async throws -> String {
    let dispatch = try TatwoMutualControlDispatchV1.make(
      invocation: invocation,
      validation: validation,
      resourceLimits: resourceLimits,
      descriptorDigest: validation.descriptorDigest,
      leaseDomainBinding: leaseDomainBinding,
      originAuthorityProvider: originAuthorityProvider)
    // Pure Core: return dispatch id only; no channel write / no process.
    return dispatch.dispatchID
  }

  public func awaitReceipt(
    jobID: String,
    dispatchNonce: String,
    invokeCanonicalDigest: String
  ) async throws -> TatwoMutualControlReceiptV1 {
    // S2 pure Core cannot poll a real channel. Callers must use
    // `TatwoMutualControlResultRecoveryV1.acceptCompleted` with a signed binding.
    throw TatwoMutualControlDispatchErrorV1.schemaInvalid(
      "awaitReceipt requires host channel adapter; use acceptCompleted with signed binding (jobID=\(jobID)/\(dispatchNonce)/\(invokeCanonicalDigest))")
  }
}
