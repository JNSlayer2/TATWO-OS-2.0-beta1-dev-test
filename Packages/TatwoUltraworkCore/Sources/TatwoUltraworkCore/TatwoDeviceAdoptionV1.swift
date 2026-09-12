import Foundation

// MARK: - Plug-and-Manage S3: adopt + revocable degrade (pure Core)
//
// Design: docs/protocol/PLUG_AND_MANAGE_DESIGN.md §4.4 / §6 (S3 manage seam).
// Inputs reuse:
// - N1: TatwoDiscoveredDeviceV1 identityFingerprint rules
// - O2/F21: TatwoDevicePairingSessionV1 + pairingProof (no public paired forge)
// - K2: TatwoDeviceCapabilityManifestV1 signed descriptors + high_risk per-invocation gate
//
// Iron rules:
// - adopted records cannot be public-memberwise constructed (internal init only).
// - adopt requires pairingProof match + signed capability declaration + stable identity.
// - adopt never grants standing high_risk authorization (K2 human-gate semantics remain).
// - pinReference is a string handle only; no Keychain / real pin store mutation here.
// - revoke voids pin reference + clears capabilities + bumps revocation epoch (monotonic).
// - residual fleet jobs are listed for origin disposal; this layer does not kill jobs.
// - No network, no physical device IO, no second crypto stack.

// MARK: - State / pin status

/// Lifecycle after a successful adopt. Distinct from pairing state machine.
public enum TatwoDeviceAdoptionStateV1: String, Codable, Sendable, CaseIterable, Equatable {
  /// Pin reference active; capability set as declared (may be empty).
  case adopted
  /// Pin still active; capability set has been strictly shrunk.
  case degraded
  /// Pin voided; capabilities empty; proofs at prior epochs rejected.
  case revoked
}

/// String pin handle status. Actual pin material lives in existing device-trust paths.
public enum TatwoDeviceAdoptionPinStatusV1: String, Codable, Sendable, CaseIterable, Equatable {
  case active
  case revoked
}

// MARK: - Residual in-flight jobs (fleet lease semantics, list-only)

/// Read-only view of a job that may still be leased/running on a target.
///
/// The attempt binding deliberately reuses the remote-loop job vocabulary:
/// `jobID` is the concrete attempt (not `logicalJobID`) and `dispatchNonce`
/// is the non-reusable attempt nonce from `TatwoLoopJobV1`.
///
/// Adoption revoke does **not** kill the job; it only classifies residuals.
public struct TatwoDeviceAdoptionInFlightJobV1: Codable, Sendable, Equatable {
  public let logicalJobID: String
  public let jobID: String
  public let targetDeviceID: String
  /// Existing remote-loop lifecycle state; free-form lease strings are not expressible.
  public let leaseState: TatwoLoopJobStatusV1
  /// Required attempt binding from the existing job type.
  public let dispatchNonce: String

  public init(
    logicalJobID: String,
    jobID: String,
    targetDeviceID: String,
    leaseState: TatwoLoopJobStatusV1,
    dispatchNonce: String
  ) {
    self.logicalJobID = logicalJobID
    self.jobID = jobID
    self.targetDeviceID = targetDeviceID
    self.leaseState = leaseState
    self.dispatchNonce = dispatchNonce
  }

  public init(
    logicalJobID: String,
    attemptJobID: String,
    targetDeviceID: String,
    leaseState: TatwoLoopJobStatusV1,
    dispatchNonce: String
  ) {
    self.init(
      logicalJobID: logicalJobID,
      jobID: attemptJobID,
      targetDeviceID: targetDeviceID,
      leaseState: leaseState,
      dispatchNonce: dispatchNonce)
  }

  /// Backward-compatible spelling for receipts that called the concrete attempt
  /// `attemptJobID`; it is still the same `jobID` binding.
  public var attemptJobID: String { jobID }

  /// Fail-closed validation before a residual can enter a revoke receipt.
  func validateAttemptBinding() throws {
    guard TatwoLoopPathComponent.isValid(jobID) else {
      throw TatwoDeviceAdoptionErrorV1.inFlightJobAttemptBindingMissing(jobID: jobID)
    }
    guard !dispatchNonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      TatwoLoopPathComponent.isValid(dispatchNonce)
    else {
      throw TatwoDeviceAdoptionErrorV1.inFlightJobAttemptBindingMissing(jobID: jobID)
    }
  }

  /// True when this job should be treated as in-progress under fleet lease semantics.
  public var isInProgressLease: Bool {
    switch leaseState {
    case .delivered, .accepted, .running:
      return true
    case .queued, .completed, .failed, .cancelled, .verified:
      return false
    }
  }
}

/// Read-only source of fleet/lease truth used by adoption revoke.
public protocol TatwoInFlightJobSource: Sendable {
  func inFlightJobs(forDevice deviceID: String) throws
    -> [TatwoDeviceAdoptionInFlightJobV1]
}

/// Production source backed by the existing remote-loop channel journal/outbox
/// readers. No second journal or lease vocabulary is introduced here.
public struct TatwoRemoteLoopChannelInFlightJobSource: TatwoInFlightJobSource, Sendable {
  public let channel: TatwoLoopJobChannel

  public init(channel: TatwoLoopJobChannel) {
    self.channel = channel
  }

  public func inFlightJobs(forDevice deviceID: String) throws
    -> [TatwoDeviceAdoptionInFlightJobV1]
  {
    let target = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return [] }
    let outbox = channel.rootURL
      .appendingPathComponent("outbox", isDirectory: true)
      .appendingPathComponent(TatwoLoopPathComponent.sanitize(target), isDirectory: true)
    let artifactCount: Int
    if FileManager.default.fileExists(atPath: outbox.path) {
      artifactCount = try FileManager.default.contentsOfDirectory(
          at: outbox,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles])
        .filter { $0.pathExtension == "json" }
        .count
    } else {
      artifactCount = 0
    }
    let jobs = try channel.jobs(forTargetDeviceID: target)
    guard jobs.count == artifactCount else {
      throw TatwoDeviceAdoptionErrorV1.inFlightJobSourceMalformed(
        detail: "channel job reader skipped one or more JSON artifacts")
    }
    return try jobs.compactMap { job in
      let status = try channel.currentStatus(for: job.jobID)
      guard status == .delivered || status == .accepted || status == .running else {
        return nil
      }
      return TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: job.logicalJobID,
        jobID: job.jobID,
        targetDeviceID: job.targetDeviceID,
        leaseState: status,
        dispatchNonce: job.dispatchNonce)
    }
  }
}

/// Production source backed by the existing dispatch registry projection.
/// This is an audit/read path only; it never mutates registry or channel state.
public struct TatwoDispatchRegistryInFlightJobSource: TatwoInFlightJobSource, Sendable {
  public let registry: TatwoDispatchRegistry

  public init(registry: TatwoDispatchRegistry) {
    self.registry = registry
  }

  public func inFlightJobs(forDevice deviceID: String) throws
    -> [TatwoDeviceAdoptionInFlightJobV1]
  {
    let target = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return [] }
    let dispatches = registry.directoryURL
      .appendingPathComponent("dispatches", isDirectory: true)
    let artifactCount: Int
    if FileManager.default.fileExists(atPath: dispatches.path) {
      artifactCount = try FileManager.default.contentsOfDirectory(
          at: dispatches,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles])
        .filter { $0.pathExtension == "json" }
        .count
    } else {
      artifactCount = 0
    }
    let runs = registry.allRuns()
    guard runs.count == artifactCount else {
      throw TatwoDeviceAdoptionErrorV1.inFlightJobSourceMalformed(
        detail: "dispatch registry reader skipped one or more JSON artifacts")
    }
    let records = runs.flatMap(\.records)
    return try records.compactMap { record in
      guard record.targetDeviceID == target else {
        return nil
      }
      // A record without a remote attempt is a local-only dispatch and is not
      // part of this source. Once a remote attempt is present, however, an
      // active projection without its nonce is malformed and must fail closed
      // rather than silently disappearing from the revoke inventory.
      guard let remoteJobID = record.remoteJobID else {
        return nil
      }
      guard let status = record.remoteStatus else {
        throw TatwoDeviceAdoptionErrorV1.inFlightJobAttemptBindingMissing(
          jobID: remoteJobID)
      }
      guard status == .delivered || status == .accepted || status == .running else {
        return nil
      }
      guard let dispatchNonce = record.remoteDispatchNonce else {
        throw TatwoDeviceAdoptionErrorV1.inFlightJobAttemptBindingMissing(
          jobID: remoteJobID)
      }
      return TatwoDeviceAdoptionInFlightJobV1(
        logicalJobID: record.logicalDispatchID ?? remoteJobID,
        jobID: remoteJobID,
        targetDeviceID: target,
        leaseState: status,
        dispatchNonce: dispatchNonce)
    }
  }
}

// MARK: - Records (receipt-shaped)

/// Capability proof minted only by `TatwoDeviceAdoptionV1.adopt` / `downgrade`.
///
/// Binds device identity, capability digest, and **revocation epoch**. After revoke,
/// epoch advances; any prior proof fails verification.
public struct TatwoDeviceAdoptionProofV1: Sendable, Equatable {
  public static let schemaName = "TatwoDeviceAdoptionProofV1"

  public let schema: String
  public let proofDigest: String
  public let deviceID: String
  public let identityFingerprint: String
  public let capabilitySetDigest: String
  /// Monotonic epoch bound into the proof. Starts at 0 on adopt; increments on revoke.
  public let revocationEpoch: UInt64
  public let mintedAt: Date

  internal init(
    proofDigest: String,
    deviceID: String,
    identityFingerprint: String,
    capabilitySetDigest: String,
    revocationEpoch: UInt64,
    mintedAt: Date
  ) {
    self.schema = Self.schemaName
    self.proofDigest = proofDigest
    self.deviceID = deviceID
    self.identityFingerprint = identityFingerprint
    self.capabilitySetDigest = capabilitySetDigest
    self.revocationEpoch = revocationEpoch
    self.mintedAt = mintedAt
  }
}

/// Adopted device record. Fields match the S3 ticket shape.
///
/// **Construction boundary (F21 discipline):** initializer is `internal`. Public
/// callers obtain instances only via `TatwoDeviceAdoptionV1.adopt` (or
/// `downgrade` / `revoke` mutations that return a new record).
public struct TatwoDeviceAdoptionRecordV1: Sendable, Equatable {
  public static let schemaName = "TatwoDeviceAdoptionRecordV1"

  public let schema: String
  public let deviceID: String
  public let identityFingerprint: String
  public let adoptedAt: Date
  public private(set) var capabilitySetDigest: String
  /// Opaque string reference to a pin held by existing device-trust machinery.
  /// This Core layer never touches Keychain or real pin material.
  public let pinReference: String
  public private(set) var adoptionProof: TatwoDeviceAdoptionProofV1

  public private(set) var state: TatwoDeviceAdoptionStateV1
  public private(set) var pinStatus: TatwoDeviceAdoptionPinStatusV1
  public private(set) var revocationEpoch: UInt64
  public private(set) var capabilityDescriptors: [TatwoDeviceCapabilityDescriptorV1]
  /// Always false: adoption never grants standing high_risk (K2 per-invocation gate).
  public let grantsHighRiskStandingAuthorization: Bool

  internal init(
    deviceID: String,
    identityFingerprint: String,
    adoptedAt: Date,
    capabilitySetDigest: String,
    pinReference: String,
    adoptionProof: TatwoDeviceAdoptionProofV1,
    state: TatwoDeviceAdoptionStateV1,
    pinStatus: TatwoDeviceAdoptionPinStatusV1,
    revocationEpoch: UInt64,
    capabilityDescriptors: [TatwoDeviceCapabilityDescriptorV1]
  ) {
    self.schema = Self.schemaName
    self.deviceID = deviceID
    self.identityFingerprint = identityFingerprint
    self.adoptedAt = adoptedAt
    self.capabilitySetDigest = capabilitySetDigest
    self.pinReference = pinReference
    self.adoptionProof = adoptionProof
    self.state = state
    self.pinStatus = pinStatus
    self.revocationEpoch = revocationEpoch
    self.capabilityDescriptors = capabilityDescriptors
    // Iron rule: never standing high_risk from adopt/downgrade.
    self.grantsHighRiskStandingAuthorization = false
  }

  public var isPinVoided: Bool { pinStatus == .revoked }
  public var isRevoked: Bool { state == .revoked }

  public var capabilityTemplateIDs: Set<String> {
    Set(capabilityDescriptors.map(\.templateID))
  }

  /// True when the adopted set contains high_risk templates (still not standing-authorized).
  public var containsHighRiskCapabilities: Bool {
    capabilityDescriptors.contains { $0.requiresHumanGate || $0.riskLevel == .highRisk }
  }
}

/// Revocation receipt: pin voided + capabilities cleared + epoch bump evidence.
public struct TatwoDeviceRevocationRecordV1: Sendable, Equatable {
  public static let schemaName = "TatwoDeviceRevocationRecordV1"

  public let schema: String
  public let deviceID: String
  public let reason: String
  public let revokedAt: Date
  /// Digest that was active at revoke time (then cleared on the record).
  public let voidedCapabilitySetDigest: String
  public let priorRevocationEpoch: UInt64
  public let newRevocationEpoch: UInt64
  public let pinReference: String
  public let residualJobsToInvalidate: [TatwoDeviceAdoptionInFlightJobV1]

  internal init(
    deviceID: String,
    reason: String,
    revokedAt: Date,
    voidedCapabilitySetDigest: String,
    priorRevocationEpoch: UInt64,
    newRevocationEpoch: UInt64,
    pinReference: String,
    residualJobsToInvalidate: [TatwoDeviceAdoptionInFlightJobV1]
  ) {
    self.schema = Self.schemaName
    self.deviceID = deviceID
    self.reason = reason
    self.revokedAt = revokedAt
    self.voidedCapabilitySetDigest = voidedCapabilitySetDigest
    self.priorRevocationEpoch = priorRevocationEpoch
    self.newRevocationEpoch = newRevocationEpoch
    self.pinReference = pinReference
    self.residualJobsToInvalidate = residualJobsToInvalidate
  }
}

/// Downgrade receipt: capability subset shrink only.
public struct TatwoDeviceDowngradeRecordV1: Sendable, Equatable {
  public static let schemaName = "TatwoDeviceDowngradeRecordV1"

  public let schema: String
  public let deviceID: String
  public let downgradedAt: Date
  public let fromCapabilitySetDigest: String
  public let toCapabilitySetDigest: String
  public let removedTemplateIDs: [String]
  public let remainingTemplateIDs: [String]
  public let revocationEpoch: UInt64

  internal init(
    deviceID: String,
    downgradedAt: Date,
    fromCapabilitySetDigest: String,
    toCapabilitySetDigest: String,
    removedTemplateIDs: [String],
    remainingTemplateIDs: [String],
    revocationEpoch: UInt64
  ) {
    self.schema = Self.schemaName
    self.deviceID = deviceID
    self.downgradedAt = downgradedAt
    self.fromCapabilitySetDigest = fromCapabilitySetDigest
    self.toCapabilitySetDigest = toCapabilitySetDigest
    self.removedTemplateIDs = removedTemplateIDs
    self.remainingTemplateIDs = remainingTemplateIDs
    self.revocationEpoch = revocationEpoch
  }
}

public struct TatwoDeviceRevokeResultV1: Sendable, Equatable {
  public let adoption: TatwoDeviceAdoptionRecordV1
  public let revocation: TatwoDeviceRevocationRecordV1
  /// Jobs origin should treat as invalid; **not** killed here.
  public let residualJobsToInvalidate: [TatwoDeviceAdoptionInFlightJobV1]

  internal init(
    adoption: TatwoDeviceAdoptionRecordV1,
    revocation: TatwoDeviceRevocationRecordV1,
    residualJobsToInvalidate: [TatwoDeviceAdoptionInFlightJobV1]
  ) {
    self.adoption = adoption
    self.revocation = revocation
    self.residualJobsToInvalidate = residualJobsToInvalidate
  }
}

public struct TatwoDeviceDowngradeResultV1: Sendable, Equatable {
  public let adoption: TatwoDeviceAdoptionRecordV1
  public let record: TatwoDeviceDowngradeRecordV1

  internal init(adoption: TatwoDeviceAdoptionRecordV1, record: TatwoDeviceDowngradeRecordV1) {
    self.adoption = adoption
    self.record = record
  }
}

// MARK: - Errors

public enum TatwoDeviceAdoptionErrorV1: Error, LocalizedError, Equatable, Sendable {
  case pairingProofMissing
  case pairingProofInvalid
  case sessionNotPaired(TatwoDevicePairingStateV1)
  case capabilityDeclarationUnsigned
  case capabilityDeclarationSignatureInvalid(String)
  case unstableIdentityForbidden(String)
  case emptyPinReference
  case emptyDeviceID
  case manifestDeviceMismatch(expected: String, actual: String)
  case identityFingerprintMismatch
  case adoptionProofInvalid
  case adoptionProofEpochMismatch(proofEpoch: UInt64, recordEpoch: UInt64)
  case adoptionRevoked
  case pinAlreadyVoided
  case emptyRevokeReason
  case downgradeNotSubset(extraTemplateIDs: [String])
  case downgradeRequiresShrink
  case unknownTemplateIDs([String])
  case epochRegressionForbidden(from: UInt64, to: UInt64)
  case inFlightJobAttemptBindingMissing(jobID: String)
  case inFlightJobSourceMalformed(detail: String)

  public var errorDescription: String? {
    switch self {
    case .pairingProofMissing:
      "adoption requires a pairingProof from a paired session"
    case .pairingProofInvalid:
      "pairingProof does not match the paired session/device"
    case let .sessionNotPaired(state):
      "adoption requires paired session, got \(state.rawValue)"
    case .capabilityDeclarationUnsigned:
      "capability declaration must be signed (producerSignature required)"
    case let .capabilityDeclarationSignatureInvalid(detail):
      "capability declaration signature invalid: \(detail)"
    case let .unstableIdentityForbidden(fp):
      "unstable identity fingerprint cannot be adopted: \(fp)"
    case .emptyPinReference:
      "pinReference must be a non-empty string handle (no Keychain write here)"
    case .emptyDeviceID:
      "deviceID must be non-empty"
    case let .manifestDeviceMismatch(expected, actual):
      "capability manifest targetDeviceID \(actual) != adopt deviceID \(expected)"
    case .identityFingerprintMismatch:
      "adoption identityFingerprint must match paired device fingerprint"
    case .adoptionProofInvalid:
      "adoptionProof is not bound to this adoption record"
    case let .adoptionProofEpochMismatch(proofEpoch, recordEpoch):
      "adoptionProof epoch \(proofEpoch) does not match record epoch \(recordEpoch)"
    case .adoptionRevoked:
      "adoption is revoked; re-enrollment required"
    case .pinAlreadyVoided:
      "pinReference already voided"
    case .emptyRevokeReason:
      "revoke reason must be non-empty"
    case let .downgradeNotSubset(extra):
      "downgrade expansion forbidden; unknown/extra templateIDs: \(extra.joined(separator: ","))"
    case .downgradeRequiresShrink:
      "downgrade must strictly shrink the capability set (identical set rejected)"
    case let .unknownTemplateIDs(ids):
      "templateIDs not in current capability set: \(ids.joined(separator: ","))"
    case let .epochRegressionForbidden(from, to):
      "revocation epoch must be monotonic (\(from) ↛ \(to))"
    case let .inFlightJobAttemptBindingMissing(jobID):
      "residual in-flight job \(jobID) is missing a valid jobID + dispatchNonce attempt binding"
    case let .inFlightJobSourceMalformed(detail):
      "residual in-flight job source rejected malformed inventory: \(detail)"
    }
  }
}

// MARK: - Engine

/// S3 adopt / revoke / downgrade facade (pure Core).
public enum TatwoDeviceAdoptionV1 {
  public static let purposeEnroll = "device_enroll"
  public static let purposeDegrade = "device_degrade"
  public static let purposeRevoke = "device_revoke"

  // MARK: Adopt

  /// Adopt a paired device with a **signed** capability declaration.
  ///
  /// Forces:
  /// 1. Missing / mismatched `pairingProof` → reject
  /// 2. Unsigned capability declaration → reject
  /// 3. `unstable:` identity fingerprint → reject
  /// 4. Never grants standing high_risk (`grantsHighRiskStandingAuthorization == false`)
  ///
  /// On success, raises the pairing session's S3 manage flag via the existing seam.
  public static func adopt(
    session: inout TatwoDevicePairingSessionV1,
    pairingProof: TatwoDevicePairingProofV1,
    capabilityManifest: TatwoDeviceCapabilityManifestV1,
    pinnedIdentity: TatwoDevicePublicIdentityV1,
    pinReference: String,
    now: Date = Date()
  ) throws -> TatwoDeviceAdoptionRecordV1 {
    // ③ unstable identity
    let fingerprint = session.device.identityFingerprint
    if session.device.hasUnstableIdentity || fingerprint.hasPrefix("unstable:") {
      throw TatwoDeviceAdoptionErrorV1.unstableIdentityForbidden(fingerprint)
    }
    guard fingerprint.hasPrefix("sha256:") else {
      throw TatwoDeviceAdoptionErrorV1.unstableIdentityForbidden(fingerprint)
    }

    // ① pairingProof required + bound
    guard session.state == .paired else {
      throw TatwoDeviceAdoptionErrorV1.sessionNotPaired(session.state)
    }
    do {
      try session.verifyPairedProof(pairingProof)
    } catch TatwoDevicePairingErrorV1.pairingProofMissing {
      throw TatwoDeviceAdoptionErrorV1.pairingProofMissing
    } catch TatwoDevicePairingErrorV1.pairingProofInvalid {
      throw TatwoDeviceAdoptionErrorV1.pairingProofInvalid
    } catch {
      throw TatwoDeviceAdoptionErrorV1.pairingProofInvalid
    }

    let pinRef = pinReference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pinRef.isEmpty else {
      throw TatwoDeviceAdoptionErrorV1.emptyPinReference
    }

    let deviceID = pinnedIdentity.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !deviceID.isEmpty else {
      throw TatwoDeviceAdoptionErrorV1.emptyDeviceID
    }
    if capabilityManifest.targetDeviceID != deviceID {
      throw TatwoDeviceAdoptionErrorV1.manifestDeviceMismatch(
        expected: deviceID,
        actual: capabilityManifest.targetDeviceID)
    }

    // ② capability declaration must be signed + verify via K2 path
    try verifySignedCapabilityDeclaration(
      manifest: capabilityManifest,
      pinnedIdentity: pinnedIdentity)

    // Raise S3 manage flag on the paired session (still no standing high_risk).
    try session.markEnrolledManagedForS3(pairingProof: pairingProof)

    let descriptors = capabilityManifest.descriptors
    let capabilitySetDigest = try computeCapabilitySetDigest(descriptors)
    let epoch: UInt64 = 0
    let proof = mintAdoptionProof(
      deviceID: deviceID,
      identityFingerprint: fingerprint,
      capabilitySetDigest: capabilitySetDigest,
      pinReference: pinRef,
      revocationEpoch: epoch,
      at: now)

    return TatwoDeviceAdoptionRecordV1(
      deviceID: deviceID,
      identityFingerprint: fingerprint,
      adoptedAt: now,
      capabilitySetDigest: capabilitySetDigest,
      pinReference: pinRef,
      adoptionProof: proof,
      state: .adopted,
      pinStatus: .active,
      revocationEpoch: epoch,
      capabilityDescriptors: descriptors)
  }

  // MARK: Verify proof (epoch-bound)

  /// Verify that `proof` is the live proof for `adoption`.
  /// After revoke, prior proofs fail (epoch / binding).
  public static func verifyAdoptionProof(
    _ proof: TatwoDeviceAdoptionProofV1,
    against adoption: TatwoDeviceAdoptionRecordV1
  ) throws {
    if adoption.isRevoked || adoption.isPinVoided {
      throw TatwoDeviceAdoptionErrorV1.adoptionRevoked
    }
    guard proof.schema == TatwoDeviceAdoptionProofV1.schemaName else {
      throw TatwoDeviceAdoptionErrorV1.adoptionProofInvalid
    }
    guard proof.deviceID == adoption.deviceID,
      proof.identityFingerprint == adoption.identityFingerprint,
      proof.capabilitySetDigest == adoption.capabilitySetDigest
    else {
      throw TatwoDeviceAdoptionErrorV1.adoptionProofInvalid
    }
    guard proof.revocationEpoch == adoption.revocationEpoch else {
      throw TatwoDeviceAdoptionErrorV1.adoptionProofEpochMismatch(
        proofEpoch: proof.revocationEpoch,
        recordEpoch: adoption.revocationEpoch)
    }
    guard proof == adoption.adoptionProof else {
      throw TatwoDeviceAdoptionErrorV1.adoptionProofInvalid
    }
  }

  /// Operations that present an adoptionProof must pass this gate.
  public static func requireActiveAdoption(
    _ adoption: TatwoDeviceAdoptionRecordV1,
    proof: TatwoDeviceAdoptionProofV1
  ) throws {
    try verifyAdoptionProof(proof, against: adoption)
  }

  // MARK: Revoke

  /// Void pin reference, clear capabilities, bump revocation epoch, list residual jobs.
  ///
  /// Does **not** kill jobs — returns the list origin should treat as invalid under
  /// fleet lease semantics (claim files stay; origin reclaim / new attempt elsewhere).
  public static func revoke(
    _ adoption: TatwoDeviceAdoptionRecordV1,
    reason: String,
    source: any TatwoInFlightJobSource,
    now: Date = Date()
  ) throws -> TatwoDeviceRevokeResultV1 {
    let reasonTrim = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reasonTrim.isEmpty else {
      throw TatwoDeviceAdoptionErrorV1.emptyRevokeReason
    }
    if adoption.isRevoked || adoption.isPinVoided {
      throw TatwoDeviceAdoptionErrorV1.pinAlreadyVoided
    }

    let priorEpoch = adoption.revocationEpoch
    let newEpoch = priorEpoch &+ 1
    if newEpoch <= priorEpoch {
      throw TatwoDeviceAdoptionErrorV1.epochRegressionForbidden(from: priorEpoch, to: newEpoch)
    }

    let voidedDigest = adoption.capabilitySetDigest
    let sourcedJobs = try source.inFlightJobs(forDevice: adoption.deviceID)
    let residual = try residualJobsToInvalidate(
      forDeviceID: adoption.deviceID,
      from: sourcedJobs)

    // Mint a tombstone proof at the new epoch with empty capability digest so any
    // prior proof (old epoch / old digest) fails equality + epoch checks.
    let emptyDigest = try computeCapabilitySetDigest([])
    let tombstoneProof = mintAdoptionProof(
      deviceID: adoption.deviceID,
      identityFingerprint: adoption.identityFingerprint,
      capabilitySetDigest: emptyDigest,
      pinReference: adoption.pinReference,
      revocationEpoch: newEpoch,
      at: now)

    var next = adoption
    next.applyRevocation(
      proof: tombstoneProof,
      capabilitySetDigest: emptyDigest,
      revocationEpoch: newEpoch)

    let revocation = TatwoDeviceRevocationRecordV1(
      deviceID: adoption.deviceID,
      reason: reasonTrim,
      revokedAt: now,
      voidedCapabilitySetDigest: voidedDigest,
      priorRevocationEpoch: priorEpoch,
      newRevocationEpoch: newEpoch,
      pinReference: adoption.pinReference,
      residualJobsToInvalidate: residual)

    return TatwoDeviceRevokeResultV1(
      adoption: next,
      revocation: revocation,
      residualJobsToInvalidate: residual)
  }

  public static func revoke(
    _ adoption: TatwoDeviceAdoptionRecordV1,
    reason: String,
    inFlightJobSource: any TatwoInFlightJobSource,
    now: Date = Date()
  ) throws -> TatwoDeviceRevokeResultV1 {
    try revoke(
      adoption,
      reason: reason,
      source: inFlightJobSource,
      now: now)
  }

  /// Validate and filter source-provided in-flight jobs for a target.
  /// This helper is internal so callers cannot bypass the source-backed revoke API.
  static func residualJobsToInvalidate(
    forDeviceID deviceID: String,
    from jobs: [TatwoDeviceAdoptionInFlightJobV1]
  ) throws -> [TatwoDeviceAdoptionInFlightJobV1] {
    let want = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    for job in jobs {
      try job.validateAttemptBinding()
    }
    return jobs.filter { job in
      job.targetDeviceID == want && job.isInProgressLease
    }
  }

  // MARK: Downgrade

  /// Shrink capability set to a **subset** of current templateIDs. Expansion rejects.
  public static func downgrade(
    _ adoption: TatwoDeviceAdoptionRecordV1,
    to capabilitySubset: [TatwoDeviceCapabilityDescriptorV1],
    proof: TatwoDeviceAdoptionProofV1,
    now: Date = Date()
  ) throws -> TatwoDeviceDowngradeResultV1 {
    try requireActiveAdoption(adoption, proof: proof)

    let currentIDs = adoption.capabilityTemplateIDs
    let subsetIDs = Set(capabilitySubset.map(\.templateID))
    let extras = subsetIDs.subtracting(currentIDs).sorted()
    if !extras.isEmpty {
      throw TatwoDeviceAdoptionErrorV1.downgradeNotSubset(extraTemplateIDs: extras)
    }
    // Every requested descriptor must match an existing templateID already held.
    // Content must come from the currently adopted set (no silent redefinition).
    var resolved: [TatwoDeviceCapabilityDescriptorV1] = []
    resolved.reserveCapacity(capabilitySubset.count)
    var seen = Set<String>()
    for requested in capabilitySubset {
      let id = requested.templateID
      if seen.contains(id) { continue }
      seen.insert(id)
      guard let existing = adoption.capabilityDescriptors.first(where: { $0.templateID == id })
      else {
        throw TatwoDeviceAdoptionErrorV1.unknownTemplateIDs([id])
      }
      // Subset by templateID identity only (descriptor already signed at adopt).
      _ = existing
      resolved.append(existing)
    }

    if resolved.count >= adoption.capabilityDescriptors.count {
      // Must strictly shrink (empty←empty is not a meaningful downgrade).
      throw TatwoDeviceAdoptionErrorV1.downgradeRequiresShrink
    }

    let fromDigest = adoption.capabilitySetDigest
    let toDigest = try computeCapabilitySetDigest(resolved)
    let removed = currentIDs.subtracting(Set(resolved.map(\.templateID))).sorted()
    let remaining = resolved.map(\.templateID).sorted()

    let newProof = mintAdoptionProof(
      deviceID: adoption.deviceID,
      identityFingerprint: adoption.identityFingerprint,
      capabilitySetDigest: toDigest,
      pinReference: adoption.pinReference,
      revocationEpoch: adoption.revocationEpoch,
      at: now)

    var next = adoption
    next.applyDowngrade(
      descriptors: resolved,
      capabilitySetDigest: toDigest,
      proof: newProof)

    let record = TatwoDeviceDowngradeRecordV1(
      deviceID: adoption.deviceID,
      downgradedAt: now,
      fromCapabilitySetDigest: fromDigest,
      toCapabilitySetDigest: toDigest,
      removedTemplateIDs: removed,
      remainingTemplateIDs: remaining,
      revocationEpoch: adoption.revocationEpoch)

    return TatwoDeviceDowngradeResultV1(adoption: next, record: record)
  }

  /// Convenience: downgrade by templateID set (must be strict subset).
  public static func downgrade(
    _ adoption: TatwoDeviceAdoptionRecordV1,
    toTemplateIDs: Set<String>,
    proof: TatwoDeviceAdoptionProofV1,
    now: Date = Date()
  ) throws -> TatwoDeviceDowngradeResultV1 {
    let extras = toTemplateIDs.subtracting(adoption.capabilityTemplateIDs).sorted()
    if !extras.isEmpty {
      throw TatwoDeviceAdoptionErrorV1.downgradeNotSubset(extraTemplateIDs: extras)
    }
    let subset = adoption.capabilityDescriptors.filter { toTemplateIDs.contains($0.templateID) }
    return try downgrade(adoption, to: subset, proof: proof, now: now)
  }

  // MARK: Digests / signing checks (reuse K2 / existing hash)

  public static func computeCapabilitySetDigest(
    _ descriptors: [TatwoDeviceCapabilityDescriptorV1]
  ) throws -> String {
    var lines: [String] = []
    lines.reserveCapacity(descriptors.count)
    for descriptor in descriptors {
      let digest: String
      if let claimed = descriptor.descriptorDigest {
        digest = claimed
      } else {
        digest = try descriptor.computeDescriptorDigest()
      }
      lines.append("\(descriptor.templateID)|\(digest)|\(descriptor.riskLevel.rawValue)")
    }
    lines.sort()
    let material = lines.joined(separator: "\n")
    return TatwoLoopJobDigest.sha256(Data(material.utf8))
  }

  /// Verify signed capability declaration using K2 manifest signature rules.
  public static func verifySignedCapabilityDeclaration(
    manifest: TatwoDeviceCapabilityManifestV1,
    pinnedIdentity: TatwoDevicePublicIdentityV1
  ) throws {
    guard let signature = manifest.producerSignature else {
      throw TatwoDeviceAdoptionErrorV1.capabilityDeclarationUnsigned
    }
    if pinnedIdentity.deviceID != manifest.targetDeviceID {
      throw TatwoDeviceAdoptionErrorV1.capabilityDeclarationSignatureInvalid(
        "pinned identity is not the manifest owner")
    }
    if let fingerprint = manifest.signingKeyFingerprint, fingerprint != pinnedIdentity.keyID {
      throw TatwoDeviceAdoptionErrorV1.capabilityDeclarationSignatureInvalid(
        "signingKeyFingerprint mismatch")
    }
    do {
      let expectedDigest = try manifest.computeManifestDigest()
      if expectedDigest != manifest.manifestDigest {
        throw TatwoDeviceAdoptionErrorV1.capabilityDeclarationSignatureInvalid(
          "manifestDigest mismatch")
      }
      for descriptor in manifest.descriptors {
        guard let claimed = descriptor.descriptorDigest,
          let actual = try? descriptor.computeDescriptorDigest(),
          claimed == actual
        else {
          throw TatwoDeviceAdoptionErrorV1.capabilityDeclarationSignatureInvalid(
            "descriptorDigest missing or mismatched")
        }
      }
      try TatwoDeviceTrustAuthority.verify(
        payload: try manifest.unsignedCanonicalPayload(),
        purpose: TatwoMutualControlPurposeV1.deviceCapabilityManifest.rawValue,
        signature: signature,
        pinnedIdentity: pinnedIdentity)
    } catch let error as TatwoDeviceAdoptionErrorV1 {
      throw error
    } catch {
      throw TatwoDeviceAdoptionErrorV1.capabilityDeclarationSignatureInvalid(
        "verification failed")
    }
  }

  // MARK: Internals

  private static func mintAdoptionProof(
    deviceID: String,
    identityFingerprint: String,
    capabilitySetDigest: String,
    pinReference: String,
    revocationEpoch: UInt64,
    at now: Date
  ) -> TatwoDeviceAdoptionProofV1 {
    let material = [
      deviceID,
      identityFingerprint,
      capabilitySetDigest,
      pinReference,
      String(revocationEpoch),
      TatwoPluginApplyEngineV1.iso8601(now),
      purposeEnroll,
    ].joined(separator: "|")
    let digest = TatwoLoopJobDigest.sha256(Data(material.utf8))
    return TatwoDeviceAdoptionProofV1(
      proofDigest: digest,
      deviceID: deviceID,
      identityFingerprint: identityFingerprint,
      capabilitySetDigest: capabilitySetDigest,
      revocationEpoch: revocationEpoch,
      mintedAt: now)
  }
}

// MARK: - Private mutation helpers (same-file; keeps public fields private(set))

extension TatwoDeviceAdoptionRecordV1 {
  fileprivate mutating func applyRevocation(
    proof: TatwoDeviceAdoptionProofV1,
    capabilitySetDigest: String,
    revocationEpoch: UInt64
  ) {
    self.state = .revoked
    self.pinStatus = .revoked
    self.capabilityDescriptors = []
    self.capabilitySetDigest = capabilitySetDigest
    self.revocationEpoch = revocationEpoch
    self.adoptionProof = proof
  }

  fileprivate mutating func applyDowngrade(
    descriptors: [TatwoDeviceCapabilityDescriptorV1],
    capabilitySetDigest: String,
    proof: TatwoDeviceAdoptionProofV1
  ) {
    self.capabilityDescriptors = descriptors
    self.capabilitySetDigest = capabilitySetDigest
    self.adoptionProof = proof
    self.state = .degraded
  }
}
