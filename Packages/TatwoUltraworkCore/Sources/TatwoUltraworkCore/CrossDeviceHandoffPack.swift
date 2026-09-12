import Foundation
import TatwoDomainContracts
import TatwoWorkReceiptContracts

/// The signature purpose is intentionally distinct from fleet job signatures.
/// A fleet execution artifact must never be accepted as an origin-transfer offer.
public enum TatwoHandoffPackSignaturePurposeV1: String, Codable, Sendable, Equatable {
  case originTransferOffer = "origin_transfer_offer"
  case capabilityReport = "handoff_capability_report"
  case originTransferCommit = "origin_transfer_commit"
}

public struct TatwoHandoffGoalV1: Codable, Sendable, Equatable {
  public let goalHash: String
  public let description: String

  public init(goalHash: String, description: String) {
    self.goalHash = goalHash
    self.description = description
  }
}

public struct TatwoHandoffContextSummaryV1: Codable, Sendable, Equatable {
  public let summary: String
  public let sourceDigest: String?

  public init(summary: String, sourceDigest: String? = nil) {
    self.summary = summary
    self.sourceDigest = sourceDigest
  }
}

public struct TatwoHandoffPlanV1: Codable, Sendable, Equatable {
  public let planHash: String
  public let summary: String

  public init(planHash: String, summary: String) {
    self.planHash = planHash
    self.summary = summary
  }
}

public struct TatwoHandoffModificationStateV1: Codable, Sendable, Equatable {
  public let branch: String
  public let commit: String
  public let dirty: Bool
  public let wipBranch: String?
  public let treeHash: String?

  public init(
    branch: String,
    commit: String,
    dirty: Bool,
    wipBranch: String? = nil,
    treeHash: String? = nil
  ) {
    self.branch = branch
    self.commit = commit
    self.dirty = dirty
    self.wipBranch = wipBranch
    self.treeHash = treeHash
  }

  /// D3's descriptive name for the dirty-worktree archive branch.
  public var dirtyArchiveWipBranch: String? { wipBranch }
}

public struct TatwoHandoffIncompleteItemV1: Codable, Sendable, Equatable {
  public let id: String
  public let description: String

  public init(id: String, description: String) {
    self.id = id
    self.description = description
  }
}

public struct TatwoHandoffRequiredFileV1: Codable, Sendable, Equatable {
  public let path: String
  public let sha256: String

  public init(path: String, sha256: String) {
    self.path = path
    self.sha256 = sha256
  }
}

public typealias TatwoHandoffFileV1 = TatwoHandoffRequiredFileV1

public struct TatwoHandoffSessionRouteV1: Codable, Sendable, Equatable {
  public let engine: String
  public let model: String
  public let route: String
  public let sessionReference: String?

  public init(
    engine: String,
    model: String,
    route: String,
    sessionReference: String? = nil
  ) {
    self.engine = engine
    self.model = model
    self.route = route
    self.sessionReference = sessionReference
  }
}

public struct TatwoHandoffReceiptReferenceV1: Codable, Sendable, Equatable {
  public let receiptID: String
  public let contentHash: String
  public let kind: String

  public init(receiptID: String, contentHash: String, kind: String) {
    self.receiptID = receiptID
    self.contentHash = contentHash
    self.kind = kind
  }
}

public struct TatwoHandoffFreshnessWindowV1: Codable, Sendable, Equatable {
  public let durationSec: TimeInterval
  public let freshUntil: Date

  public init(durationSec: TimeInterval, freshUntil: Date) {
    self.durationSec = durationSec
    self.freshUntil = freshUntil
  }
}

public enum TatwoHandoffPackVerificationErrorCodeV1: String, Codable, Sendable, Equatable {
  case missingRequiredField = "missing_required_field"
  case invalidSchema = "invalid_schema"
  case invalidHashFormat = "invalid_hash_format"
  case invalidPath = "invalid_path"
  case invalidFreshness = "invalid_freshness"
  case freshnessExpired = "freshness_expired"
  case signatureMissing = "signature_missing"
  case signatureRejected = "signature_rejected"
  case signaturePurposeMismatch = "signature_purpose_mismatch"
  case producerMismatch = "producer_mismatch"
  case receiverMismatch = "receiver_mismatch"
  case digestMismatch = "digest_mismatch"
}

public struct TatwoHandoffPackVerificationIssueV1: Codable, Sendable, Equatable {
  public let code: TatwoHandoffPackVerificationErrorCodeV1
  public let detail: String

  public init(
    code: TatwoHandoffPackVerificationErrorCodeV1,
    detail: String
  ) {
    self.code = code
    self.detail = detail
  }
}

public struct TatwoHandoffPackVerificationResultV1: Codable, Sendable, Equatable {
  public let valid: Bool
  public let issues: [TatwoHandoffPackVerificationIssueV1]

  public init(valid: Bool, issues: [TatwoHandoffPackVerificationIssueV1]) {
    self.valid = valid && issues.isEmpty
    self.issues = issues
  }

  public var errorCodes: [TatwoHandoffPackVerificationErrorCodeV1] {
    issues.map(\.code)
  }

  public var firstErrorCode: TatwoHandoffPackVerificationErrorCodeV1? {
    issues.first?.code
  }
}

public struct TatwoHandoffPackVerificationExpectations: Sendable {
  public let trust: TatwoLoopJobChannelTrust?
  public let expectedProducerDeviceID: String?
  public let expectedReceiverDeviceID: String?
  /// Optional injected receiver declaration used by the pure S2 checker.
  /// Adapters may populate this after the pack has been verified.
  public let receiverCapabilities: TatwoHandoffReceiverCapabilitiesV1?
  public let now: Date
  public let clockSkewSec: TimeInterval

  public init(
    trust: TatwoLoopJobChannelTrust? = nil,
    expectedProducerDeviceID: String? = nil,
    expectedReceiverDeviceID: String? = nil,
    receiverCapabilities: TatwoHandoffReceiverCapabilitiesV1? = nil,
    now: Date = Date(),
    clockSkewSec: TimeInterval = TatwoLoopJobChannelTrust.signatureClockSkewSec
  ) {
    self.trust = trust
    self.expectedProducerDeviceID = expectedProducerDeviceID
    self.expectedReceiverDeviceID = expectedReceiverDeviceID
    self.receiverCapabilities = receiverCapabilities
    self.now = now
    self.clockSkewSec = clockSkewSec
  }
}

public enum TatwoHandoffPackBuildError: Error, LocalizedError, Sendable, Equatable {
  case invalid(TatwoHandoffPackVerificationIssueV1)
  case signingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let issue):
      return "\(issue.code.rawValue): \(issue.detail)"
    case .signingFailed(let detail):
      return "signing_failed: \(detail)"
    }
  }

  public var code: TatwoHandoffPackVerificationErrorCodeV1? {
    guard case .invalid(let issue) = self else { return nil }
    return issue.code
  }
}

/// Immutable, signed cross-device origin-transfer snapshot.
///
/// S1 deliberately owns only pack construction, canonicalization, and
/// verification. Transport, lease adoption, and UI remain later slices.
public struct TatwoHandoffPackV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoCrossDeviceHandoffPackV1"
  public static let maxFreshnessWindowSec: TimeInterval = 86_400

  public let schema: String
  public let handoffID: String
  public let logicalJobID: String
  public let jobID: String
  public let dispatchNonce: String
  public let goal: TatwoHandoffGoalV1
  public let context: TatwoHandoffContextSummaryV1
  public let plan: TatwoHandoffPlanV1
  public let modificationState: TatwoHandoffModificationStateV1
  public let incompleteItems: [TatwoHandoffIncompleteItemV1]
  public let requiredFiles: [TatwoHandoffRequiredFileV1]
  public let sessionRoute: TatwoHandoffSessionRouteV1
  public let receiptReferences: [TatwoHandoffReceiptReferenceV1]
  public let riskHints: [String]
  public let producerDevicePin: TatwoDevicePublicIdentityV1
  public let intendedReceiverDeviceID: String?
  public let priorOriginDeviceID: String
  public let requestedLeaseDomainID: String
  /// Optional producer declaration. S1 packs may omit it; S2 marks a
  /// mismatch as degraded rather than pretending the receiver can probe it.
  public let toolchainFingerprint: String?
  public let requiredRunnerIDs: [String]?
  public let requiredLanes: [String]?
  public let createdAt: Date
  public let freshnessWindowSec: TimeInterval
  public let freshUntil: Date
  public let jobCanonicalDigest: String
  public let packContentHash: String
  public let signingKeyFingerprint: String
  public let producerSignature: TatwoDeviceSignatureV1

  public var signature: TatwoDeviceSignatureV1 { producerSignature }
  public var freshnessWindow: TimeInterval { freshnessWindowSec }
  public var goalHash: String { goal.goalHash }
  public var goalDescription: String { goal.description }
  public var planHash: String { plan.planHash }
  public var contextSummary: String { context.summary }
  public var branch: String { modificationState.branch }
  public var commit: String { modificationState.commit }
  public var dirty: Bool { modificationState.dirty }
  public var wipBranch: String? { modificationState.wipBranch }
  public var unfinishedItems: [TatwoHandoffIncompleteItemV1] { incompleteItems }
  public var necessaryFiles: [TatwoHandoffRequiredFileV1] { requiredFiles }
  public var receipts: [TatwoHandoffReceiptReferenceV1] { receiptReferences }
  public var sessionRouting: TatwoHandoffSessionRouteV1 { sessionRoute }
  public var riskWarnings: [String] { riskHints }
  public var originDevicePin: TatwoDevicePublicIdentityV1 { producerDevicePin }
  public var requiredRunners: [String] { requiredRunnerIDs ?? [] }
  public var requiredCapabilityLanes: [String] { requiredLanes ?? [] }
  public var producerToolchainFingerprint: String? { toolchainFingerprint }

  public init(
    schema: String = TatwoHandoffPackV1.schemaName,
    handoffID: String,
    logicalJobID: String,
    jobID: String,
    dispatchNonce: String,
    goal: TatwoHandoffGoalV1,
    context: TatwoHandoffContextSummaryV1,
    plan: TatwoHandoffPlanV1,
    modificationState: TatwoHandoffModificationStateV1,
    incompleteItems: [TatwoHandoffIncompleteItemV1],
    requiredFiles: [TatwoHandoffRequiredFileV1],
    sessionRoute: TatwoHandoffSessionRouteV1,
    receiptReferences: [TatwoHandoffReceiptReferenceV1],
    riskHints: [String],
    producerDevicePin: TatwoDevicePublicIdentityV1,
    intendedReceiverDeviceID: String? = nil,
    priorOriginDeviceID: String,
    requestedLeaseDomainID: String,
    toolchainFingerprint: String? = nil,
    requiredRunnerIDs: [String]? = nil,
    requiredLanes: [String]? = nil,
    createdAt: Date,
    freshnessWindowSec: TimeInterval,
    freshUntil: Date,
    jobCanonicalDigest: String,
    packContentHash: String,
    signingKeyFingerprint: String,
    producerSignature: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.handoffID = handoffID
    self.logicalJobID = logicalJobID
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.goal = goal
    self.context = context
    self.plan = plan
    self.modificationState = modificationState
    self.incompleteItems = incompleteItems
    self.requiredFiles = requiredFiles
    self.sessionRoute = sessionRoute
    self.receiptReferences = receiptReferences
    self.riskHints = riskHints
    self.producerDevicePin = producerDevicePin
    self.intendedReceiverDeviceID = intendedReceiverDeviceID
    self.priorOriginDeviceID = priorOriginDeviceID
    self.requestedLeaseDomainID = requestedLeaseDomainID
    self.toolchainFingerprint = toolchainFingerprint
    self.requiredRunnerIDs = requiredRunnerIDs
    self.requiredLanes = requiredLanes
    self.createdAt = createdAt
    self.freshnessWindowSec = freshnessWindowSec
    self.freshUntil = freshUntil
    self.jobCanonicalDigest = jobCanonicalDigest
    self.packContentHash = packContentHash
    self.signingKeyFingerprint = signingKeyFingerprint
    self.producerSignature = producerSignature
  }

  /// Produce and sign a pack using the existing fleet/device Ed25519 trust
  /// authority. No second cryptographic implementation is introduced here.
  public static func make(
    handoffID: String,
    logicalJobID: String,
    jobID: String,
    dispatchNonce: String,
    goal: TatwoHandoffGoalV1,
    context: TatwoHandoffContextSummaryV1,
    plan: TatwoHandoffPlanV1,
    modificationState: TatwoHandoffModificationStateV1,
    incompleteItems: [TatwoHandoffIncompleteItemV1],
    requiredFiles: [TatwoHandoffRequiredFileV1],
    sessionRoute: TatwoHandoffSessionRouteV1,
    receiptReferences: [TatwoHandoffReceiptReferenceV1],
    riskHints: [String],
    trust: TatwoLoopJobChannelTrust,
    intendedReceiverDeviceID: String? = nil,
    priorOriginDeviceID: String,
    requestedLeaseDomainID: String,
    toolchainFingerprint: String? = nil,
    requiredRunnerIDs: [String]? = nil,
    requiredLanes: [String]? = nil,
    createdAt: Date = Date(),
    freshnessWindow: TimeInterval = 900
  ) throws -> TatwoHandoffPackV1 {
    let freshUntil = createdAt.addingTimeInterval(freshnessWindow)
    let unsigned = TatwoHandoffPackUnsignedV1(
      schema: schemaName,
      handoffID: handoffID,
      logicalJobID: logicalJobID,
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      goal: goal,
      context: context,
      plan: plan,
      modificationState: modificationState,
      incompleteItems: incompleteItems,
      requiredFiles: requiredFiles,
      sessionRoute: sessionRoute,
      receiptReferences: receiptReferences,
      riskHints: riskHints,
      producerDevicePin: trust.localIdentity,
      intendedReceiverDeviceID: intendedReceiverDeviceID,
      priorOriginDeviceID: priorOriginDeviceID,
      requestedLeaseDomainID: requestedLeaseDomainID,
      toolchainFingerprint: toolchainFingerprint,
      requiredRunnerIDs: requiredRunnerIDs,
      requiredLanes: requiredLanes,
      createdAt: createdAt,
      freshnessWindowSec: freshnessWindow,
      freshUntil: freshUntil)
    let candidate = unsigned.makeUnsignedPack()
    if let issue = candidate.firstValidationIssue() {
      throw TatwoHandoffPackBuildError.invalid(issue)
    }
    let payload = try candidate.canonicalPayloadData()
    let digest = TatwoLoopJobDigest.sha256(payload)
    let signedAt = TatwoLoopJobChannelTrust.iso8601(createdAt)
    let producerSignature: TatwoDeviceSignatureV1
    do {
      producerSignature = try trust.authority.sign(
        payload: payload,
        purpose: TatwoHandoffPackSignaturePurposeV1.originTransferOffer.rawValue,
        identity: trust.localIdentity,
        signedAt: signedAt)
    } catch {
      throw TatwoHandoffPackBuildError.signingFailed(String(describing: error))
    }
    return TatwoHandoffPackV1(
      schema: candidate.schema,
      handoffID: candidate.handoffID,
      logicalJobID: candidate.logicalJobID,
      jobID: candidate.jobID,
      dispatchNonce: candidate.dispatchNonce,
      goal: candidate.goal,
      context: candidate.context,
      plan: candidate.plan,
      modificationState: candidate.modificationState,
      incompleteItems: candidate.incompleteItems,
      requiredFiles: candidate.requiredFiles,
      sessionRoute: candidate.sessionRoute,
      receiptReferences: candidate.receiptReferences,
      riskHints: candidate.riskHints,
      producerDevicePin: candidate.producerDevicePin,
      intendedReceiverDeviceID: candidate.intendedReceiverDeviceID,
      priorOriginDeviceID: candidate.priorOriginDeviceID,
      requestedLeaseDomainID: candidate.requestedLeaseDomainID,
      toolchainFingerprint: candidate.toolchainFingerprint,
      requiredRunnerIDs: candidate.requiredRunnerIDs,
      requiredLanes: candidate.requiredLanes,
      createdAt: candidate.createdAt,
      freshnessWindowSec: candidate.freshnessWindowSec,
      freshUntil: candidate.freshUntil,
      jobCanonicalDigest: digest,
      packContentHash: digest,
      signingKeyFingerprint: trust.localIdentity.keyID,
      producerSignature: producerSignature)
  }

  /// Alias kept intentionally small so callers can use either make or create.
  public static func create(
    handoffID: String,
    logicalJobID: String,
    jobID: String,
    dispatchNonce: String,
    goal: TatwoHandoffGoalV1,
    context: TatwoHandoffContextSummaryV1,
    plan: TatwoHandoffPlanV1,
    modificationState: TatwoHandoffModificationStateV1,
    incompleteItems: [TatwoHandoffIncompleteItemV1],
    requiredFiles: [TatwoHandoffRequiredFileV1],
    sessionRoute: TatwoHandoffSessionRouteV1,
    receiptReferences: [TatwoHandoffReceiptReferenceV1],
    riskHints: [String],
    trust: TatwoLoopJobChannelTrust,
    intendedReceiverDeviceID: String? = nil,
    priorOriginDeviceID: String,
    requestedLeaseDomainID: String,
    toolchainFingerprint: String? = nil,
    requiredRunnerIDs: [String]? = nil,
    requiredLanes: [String]? = nil,
    createdAt: Date = Date(),
    freshnessWindow: TimeInterval = 900
  ) throws -> TatwoHandoffPackV1 {
    try make(
      handoffID: handoffID,
      logicalJobID: logicalJobID,
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      goal: goal,
      context: context,
      plan: plan,
      modificationState: modificationState,
      incompleteItems: incompleteItems,
      requiredFiles: requiredFiles,
      sessionRoute: sessionRoute,
      receiptReferences: receiptReferences,
      riskHints: riskHints,
      trust: trust,
      intendedReceiverDeviceID: intendedReceiverDeviceID,
      priorOriginDeviceID: priorOriginDeviceID,
      requestedLeaseDomainID: requestedLeaseDomainID,
      toolchainFingerprint: toolchainFingerprint,
      requiredRunnerIDs: requiredRunnerIDs,
      requiredLanes: requiredLanes,
      createdAt: createdAt,
      freshnessWindow: freshnessWindow)
  }

  public func canonicalPayloadData() throws -> Data {
    let unsigned = TatwoHandoffPackUnsignedV1(pack: self)
    return try unsigned.canonicalPayloadData()
  }

  public func canonicalDigest() throws -> String {
    TatwoLoopJobDigest.sha256(try canonicalPayloadData())
  }

  public static func verify(
    _ pack: TatwoHandoffPackV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) -> TatwoHandoffPackVerificationResultV1 {
    TatwoHandoffPackVerifierV1.verify(pack: pack, expectations: expectations)
  }

  public static func verify(
    pack: TatwoHandoffPackV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) -> TatwoHandoffPackVerificationResultV1 {
    verify(pack, expectations: expectations)
  }
}

/// D3's longer schema-oriented name; both names refer to the same immutable
/// S1 pack type.
public typealias TatwoCrossDeviceHandoffPackV1 = TatwoHandoffPackV1

public enum TatwoHandoffPackVerifierV1 {
  public static func verify(
    pack: TatwoHandoffPackV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) -> TatwoHandoffPackVerificationResultV1 {
    var issues: [TatwoHandoffPackVerificationIssueV1] = []
    if let issue = pack.firstValidationIssue() {
      issues.append(issue)
    }
    if let expectedProducer = expectations.expectedProducerDeviceID,
      pack.producerDevicePin.deviceID != expectedProducer
    {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .producerMismatch,
          detail: "producer device does not match expectation"))
    }
    if let expectedReceiver = expectations.expectedReceiverDeviceID,
      pack.intendedReceiverDeviceID != expectedReceiver
    {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .receiverMismatch,
          detail: "intended receiver does not match expectation"))
    }
    let now = expectations.now
    if now.timeIntervalSince(pack.freshUntil) > expectations.clockSkewSec {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .freshnessExpired,
          detail: "pack freshness window has expired"))
    }
    if pack.createdAt.timeIntervalSince(now) > expectations.clockSkewSec {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .invalidFreshness,
          detail: "pack creation time is too far in the future"))
    }

    do {
      let digest = try pack.canonicalDigest()
      if digest != pack.jobCanonicalDigest || digest != pack.packContentHash {
        issues.append(
          TatwoHandoffPackVerificationIssueV1(
            code: .digestMismatch,
            detail: "canonical pack digest does not match the signed envelope"))
      }
    } catch {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .digestMismatch,
          detail: "canonical pack encoding failed"))
    }

    guard let trust = expectations.trust else {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .signatureRejected,
          detail: "a pinned trust context is required"))
      return TatwoHandoffPackVerificationResultV1(valid: false, issues: issues)
    }
    guard let pinned = trust.pinnedIdentities[pack.producerDevicePin.deviceID] else {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .signatureRejected,
          detail: "producer device is not pinned in the verifier trust context"))
      return TatwoHandoffPackVerificationResultV1(valid: false, issues: issues)
    }
    if pack.producerSignature.purpose
      != TatwoHandoffPackSignaturePurposeV1.originTransferOffer.rawValue
    {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .signaturePurposeMismatch,
          detail: "signature purpose is not origin_transfer_offer"))
    }
    if pack.signingKeyFingerprint != pinned.keyID
      || pack.producerSignature.keyID != pinned.keyID
    {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .signatureRejected,
          detail: "signing key fingerprint does not match the pinned key"))
    }
    do {
      try TatwoDeviceTrustAuthority.verify(
        payload: pack.canonicalPayloadData(),
        purpose: TatwoHandoffPackSignaturePurposeV1.originTransferOffer.rawValue,
        signature: pack.producerSignature,
        pinnedIdentity: pinned)
    } catch {
      issues.append(
        TatwoHandoffPackVerificationIssueV1(
          code: .signatureRejected,
          detail: "Ed25519 signature verification failed"))
    }
    return TatwoHandoffPackVerificationResultV1(valid: issues.isEmpty, issues: issues)
  }
}

public typealias TatwoHandoffPackVerifier = TatwoHandoffPackVerifierV1

public func verify(
  _ pack: TatwoHandoffPackV1,
  _ expectations: TatwoHandoffPackVerificationExpectations = .init()
) -> TatwoHandoffPackVerificationResultV1 {
  TatwoHandoffPackVerifierV1.verify(pack: pack, expectations: expectations)
}

public func verify(
  pack: TatwoHandoffPackV1,
  expectations: TatwoHandoffPackVerificationExpectations = .init()
) -> TatwoHandoffPackVerificationResultV1 {
  verify(pack, expectations)
}

// MARK: - Verified pack gate (verify-before-assess)

/// Opaque carrier for a pack that has already passed `TatwoHandoffPackVerifierV1`.
/// The only public construction path is a successful `verify` call in this file;
/// capability checkers accept only this type so unsigned/tampered packs cannot
/// type-check into an `.accept` assessment.
public struct TatwoVerifiedHandoffPackV1: Sendable, Equatable {
  public let pack: TatwoHandoffPackV1
  /// Normalized SHA-256 of the pack canonical payload (same as packContentHash
  /// after a valid verify). Bound into every assessment signature payload.
  public let packDigest: String

  fileprivate init(pack: TatwoHandoffPackV1, packDigest: String) {
    self.pack = pack
    self.packDigest = packDigest
  }

  public var handoffID: String { pack.handoffID }
  public var logicalJobID: String { pack.logicalJobID }
  public var jobID: String { pack.jobID }
  public var dispatchNonce: String { pack.dispatchNonce }

  public static func verify(
    pack: TatwoHandoffPackV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) -> Result<TatwoVerifiedHandoffPackV1, TatwoVerifiedHandoffPackErrorV1> {
    let result = TatwoHandoffPackVerifierV1.verify(
      pack: pack,
      expectations: expectations)
    guard result.valid else {
      return .failure(.verificationFailed(result))
    }
    let digest: String
    do {
      digest = try pack.canonicalDigest()
    } catch {
      let issue = TatwoHandoffPackVerificationIssueV1(
        code: .digestMismatch,
        detail: "canonical pack encoding failed after structural verification")
      let failure = TatwoHandoffPackVerificationResultV1(
        valid: false,
        issues: [issue])
      return .failure(.verificationFailed(failure))
    }
    let verified = TatwoVerifiedHandoffPackV1(pack: pack, packDigest: digest)
    return .success(verified)
  }

  public static func verifyOrThrow(
    pack: TatwoHandoffPackV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) throws -> TatwoVerifiedHandoffPackV1 {
    try verify(pack: pack, expectations: expectations).get()
  }
}

public enum TatwoVerifiedHandoffPackErrorV1: Error, Equatable, Sendable {
  case verificationFailed(TatwoHandoffPackVerificationResultV1)

  public var verificationResult: TatwoHandoffPackVerificationResultV1 {
    switch self {
    case .verificationFailed(let result):
      return result
    }
  }
}

/// Ticket / short name for the type-gated verified pack.
public typealias VerifiedHandoffPack = TatwoVerifiedHandoffPackV1

// MARK: - S2 receiver assessment

public enum TatwoHandoffCapabilityDecisionV1: String, Codable, Sendable, Equatable {
  case accept
  case degraded
  case reject
}

public enum TatwoHandoffAssessmentReasonCodeV1: String, Codable, Sendable, Equatable {
  case projectCommitUnreachable = "project_commit_unreachable"
  case projectTreeUnreachable = "project_tree_unreachable"
  case protocolSchemaUnsupported = "protocol_schema_unsupported"
  case freshnessExpired = "freshness_expired"
  case freshnessRefetchable = "freshness_expired_refetchable"
  case toolchainFingerprintMismatch = "toolchain_fingerprint_mismatch"
  case runnerUnavailable = "runner_unavailable"
  case permissionInsufficient = "permission_insufficient"
  case receiverMismatch = "receiver_mismatch"
  case localWorktreeDirty = "local_worktree_dirty"
  case capabilityDeclarationMissing = "capability_declaration_missing"
  case packVerificationFailed = "pack_verification_failed"
  case packDigestMismatch = "pack_digest_mismatch"
  case attemptIdentityMismatch = "attempt_identity_mismatch"
}

public struct TatwoHandoffCapabilityCheckV1: Codable, Sendable, Equatable {
  public let id: String
  public let passed: Bool
  public let detail: String
  public let reasonCode: TatwoHandoffAssessmentReasonCodeV1?

  public init(
    id: String,
    passed: Bool,
    detail: String,
    reasonCode: TatwoHandoffAssessmentReasonCodeV1? = nil
  ) {
    self.id = id
    self.passed = passed
    self.detail = detail
    self.reasonCode = reasonCode
  }
}

/// Pure, serializable S2 result. It deliberately contains no lease mutation
/// or host probing; adapters inject a declaration and may sign this value.
/// Signature payload binds packDigest + full attempt identity so an accept
/// assessment cannot be transplanted onto a different pack/attempt.
public struct TatwoHandoffAssessmentV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoHandoffAssessmentV1"
  public let schema: String
  public let handoffID: String
  /// Normalized pack SHA-256; must match the assessed pack's canonical digest.
  public let packDigest: String
  public let logicalJobID: String
  public let jobID: String
  public let dispatchNonce: String
  public let decision: TatwoHandoffCapabilityDecisionV1
  public let checks: [TatwoHandoffCapabilityCheckV1]
  public let degradation: [String]
  public let reasonCodes: [TatwoHandoffAssessmentReasonCodeV1]
  public let reportedAt: Date
  public let reporterSignature: TatwoDeviceSignatureV1?

  public init(
    schema: String = TatwoHandoffAssessmentV1.schemaName,
    handoffID: String,
    packDigest: String,
    logicalJobID: String,
    jobID: String,
    dispatchNonce: String,
    decision: TatwoHandoffCapabilityDecisionV1,
    checks: [TatwoHandoffCapabilityCheckV1],
    degradation: [String] = [],
    reasonCodes: [TatwoHandoffAssessmentReasonCodeV1] = [],
    reportedAt: Date = Date(),
    reporterSignature: TatwoDeviceSignatureV1? = nil
  ) {
    self.schema = schema
    self.handoffID = handoffID
    self.packDigest = packDigest
    self.logicalJobID = logicalJobID
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.decision = decision
    self.checks = checks
    self.degradation = degradation
    self.reasonCodes = reasonCodes
    self.reportedAt = reportedAt
    self.reporterSignature = reporterSignature
  }

  public var isSigned: Bool { reporterSignature != nil }
  public var capabilityReport: TatwoHandoffAssessmentV1 { self }

  public func canonicalPayloadData() throws -> Data {
    let unsigned = TatwoHandoffAssessmentUnsignedV1(assessment: self)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(unsigned)
  }

  public func canonicalDigest() throws -> String {
    TatwoLoopJobDigest.sha256(try canonicalPayloadData())
  }

  public func signed(using trust: TatwoLoopJobChannelTrust) throws -> TatwoHandoffAssessmentV1 {
    let payload = try canonicalPayloadData()
    let signature = try trust.authority.sign(
      payload: payload,
      purpose: TatwoHandoffPackSignaturePurposeV1.capabilityReport.rawValue,
      identity: trust.localIdentity,
      signedAt: TatwoLoopJobChannelTrust.iso8601(reportedAt))
    return TatwoHandoffAssessmentV1(
      schema: schema,
      handoffID: handoffID,
      packDigest: packDigest,
      logicalJobID: logicalJobID,
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      decision: decision,
      checks: checks,
      degradation: degradation,
      reasonCodes: reasonCodes,
      reportedAt: reportedAt,
      reporterSignature: signature)
  }

  public static func sign(
    _ assessment: TatwoHandoffAssessmentV1,
    using trust: TatwoLoopJobChannelTrust
  ) throws -> TatwoHandoffAssessmentV1 {
    try assessment.signed(using: trust)
  }

  /// True iff this assessment is bound to the given pack's digest and attempt
  /// identity. Digest mismatch is always a hard reject for transplant defense.
  public func matchesPackBinding(_ pack: TatwoHandoffPackV1) -> Bool {
    let computedDigest: String
    do {
      computedDigest = try pack.canonicalDigest()
    } catch {
      return false
    }
    if packDigest != computedDigest {
      return false
    }
    if packDigest != pack.packContentHash || packDigest != pack.jobCanonicalDigest {
      return false
    }
    if handoffID != pack.handoffID {
      return false
    }
    if logicalJobID != pack.logicalJobID {
      return false
    }
    if jobID != pack.jobID {
      return false
    }
    if dispatchNonce != pack.dispatchNonce {
      return false
    }
    return true
  }

  public func matchesPackBinding(_ verifiedPack: TatwoVerifiedHandoffPackV1) -> Bool {
    if packDigest != verifiedPack.packDigest {
      return false
    }
    return matchesPackBinding(verifiedPack.pack)
  }

  public func verifySignature(
    using trust: TatwoLoopJobChannelTrust,
    expectedReporterDeviceID: String? = nil
  ) -> Bool {
    guard let signature = reporterSignature else { return false }
    if let expectedReporterDeviceID,
      signature.deviceID != expectedReporterDeviceID
    {
      return false
    }
    guard let pinned = trust.pinnedIdentities[signature.deviceID] else {
      return false
    }
    do {
      try TatwoDeviceTrustAuthority.verify(
        payload: canonicalPayloadData(),
        purpose: TatwoHandoffPackSignaturePurposeV1.capabilityReport.rawValue,
        signature: signature,
        pinnedIdentity: pinned)
      return true
    } catch {
      return false
    }
  }

  /// Signature verify plus pack digest / attempt-identity binding.
  /// Digest mismatch or identity mismatch always returns false (reject).
  public func verifySignature(
    using trust: TatwoLoopJobChannelTrust,
    expectedReporterDeviceID: String? = nil,
    against pack: TatwoHandoffPackV1
  ) -> Bool {
    guard matchesPackBinding(pack) else { return false }
    return verifySignature(
      using: trust,
      expectedReporterDeviceID: expectedReporterDeviceID)
  }

  public func verifySignature(
    using trust: TatwoLoopJobChannelTrust,
    expectedReporterDeviceID: String? = nil,
    against verifiedPack: TatwoVerifiedHandoffPackV1
  ) -> Bool {
    guard matchesPackBinding(verifiedPack) else { return false }
    return verifySignature(
      using: trust,
      expectedReporterDeviceID: expectedReporterDeviceID)
  }

  public static func verifySignature(
    _ assessment: TatwoHandoffAssessmentV1,
    using trust: TatwoLoopJobChannelTrust,
    expectedReporterDeviceID: String? = nil
  ) -> Bool {
    assessment.verifySignature(
      using: trust,
      expectedReporterDeviceID: expectedReporterDeviceID)
  }
}

/// Backward-compatible name retained for callers of the H1 interface.
public typealias TatwoHandoffCapabilityReportV1 = TatwoHandoffAssessmentV1

public struct TatwoHandoffReceiverCapabilitiesV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoHandoffReceiverCapabilitiesV1"

  public let schema: String
  public let deviceID: String
  public let projectCommit: String?
  public let projectTreeHash: String?
  public let reachableCommits: [String]
  public let reachableTreeHashes: [String]
  public let supportedPackSchemas: [String]
  public let swiftToolchainFingerprint: String?
  public let runnerAvailability: [String: Bool]
  public let permittedLanes: [String]
  public let canRefetchFreshData: Bool
  public let localWorktreeDirty: Bool

  public init(
    schema: String = TatwoHandoffReceiverCapabilitiesV1.schemaName,
    deviceID: String,
    projectCommit: String? = nil,
    projectTreeHash: String? = nil,
    reachableCommits: [String] = [],
    reachableTreeHashes: [String] = [],
    supportedPackSchemas: [String] = [
      TatwoHandoffPackV1.schemaName,
      "TatwoHandoffPackV1"
    ],
    swiftToolchainFingerprint: String? = nil,
    runnerAvailability: [String: Bool] = [:],
    permittedLanes: [String] = [],
    canRefetchFreshData: Bool = false,
    localWorktreeDirty: Bool = false
  ) {
    self.schema = schema
    self.deviceID = deviceID
    self.projectCommit = projectCommit
    self.projectTreeHash = projectTreeHash
    self.reachableCommits = reachableCommits
    self.reachableTreeHashes = reachableTreeHashes
    self.supportedPackSchemas = supportedPackSchemas
    self.swiftToolchainFingerprint = swiftToolchainFingerprint
    self.runnerAvailability = runnerAvailability
    self.permittedLanes = permittedLanes
    self.canRefetchFreshData = canRefetchFreshData
    self.localWorktreeDirty = localWorktreeDirty
  }

  public var availableRunners: [String: Bool] { runnerAvailability }
  public var allowedLanes: [String] { permittedLanes }

  public static func unavailable(deviceID: String = "") -> TatwoHandoffReceiverCapabilitiesV1 {
    TatwoHandoffReceiverCapabilitiesV1(deviceID: deviceID)
  }
}

public typealias TatwoHandoffReceiverCapabilityDeclarationV1 =
  TatwoHandoffReceiverCapabilitiesV1
public typealias TatwoHandoffCapabilityDeclarationV1 =
  TatwoHandoffReceiverCapabilitiesV1

/// S2 protocol. Capability assessment only accepts a type-gated verified pack.
/// Unsigned/tampered packs cannot reach this surface without first passing verify.
public protocol TatwoHandoffReceiverCapabilityCheckingV1: Sendable {
  func check(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    expectations: TatwoHandoffPackVerificationExpectations
  ) -> TatwoHandoffAssessmentV1
}

public extension TatwoHandoffReceiverCapabilityCheckingV1 {
  func check(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    capabilities: TatwoHandoffReceiverCapabilitiesV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) -> TatwoHandoffAssessmentV1 {
    let injected = TatwoHandoffPackVerificationExpectations(
      trust: expectations.trust,
      expectedProducerDeviceID: expectations.expectedProducerDeviceID,
      expectedReceiverDeviceID: expectations.expectedReceiverDeviceID,
      receiverCapabilities: capabilities,
      now: expectations.now,
      clockSkewSec: expectations.clockSkewSec)
    return check(verifiedPack: verifiedPack, expectations: injected)
  }
}

/// Deterministic S2 policy evaluator. It never invokes `git`, `swift`, a
/// runner, or a filesystem API; adapters own those probes and inject facts.
/// Entry points only accept `TatwoVerifiedHandoffPackV1` so verify-before-assess
/// is enforced at the type layer (not a runtime-only soft check).
public struct TatwoHandoffReceiverCapabilityCheckerV1:
  TatwoHandoffReceiverCapabilityCheckingV1
{
  public let capabilities: TatwoHandoffReceiverCapabilitiesV1

  public init(capabilities: TatwoHandoffReceiverCapabilitiesV1) {
    self.capabilities = capabilities
  }

  public init(declaration: TatwoHandoffReceiverCapabilitiesV1) {
    self.capabilities = declaration
  }

  public func check(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    expectations: TatwoHandoffPackVerificationExpectations
  ) -> TatwoHandoffAssessmentV1 {
    let injected = expectations.receiverCapabilities ?? capabilities
    return Self.assess(
      verifiedPack: verifiedPack,
      capabilities: injected,
      expectations: expectations)
  }

  public func check(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    capabilities: TatwoHandoffReceiverCapabilitiesV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) -> TatwoHandoffAssessmentV1 {
    Self.assess(
      verifiedPack: verifiedPack,
      capabilities: capabilities,
      expectations: expectations)
  }

  public static func assess(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    capabilities: TatwoHandoffReceiverCapabilitiesV1,
    expectations: TatwoHandoffPackVerificationExpectations = .init()
  ) -> TatwoHandoffAssessmentV1 {
    let pack = verifiedPack.pack
    var checks: [TatwoHandoffCapabilityCheckV1] = []
    var degradations: [String] = []
    var reasons: [TatwoHandoffAssessmentReasonCodeV1] = []
    var rejected = false

    func record(
      id: String,
      passed: Bool,
      detail: String,
      reason: TatwoHandoffAssessmentReasonCodeV1? = nil,
      rejection: Bool = false,
      degradation: String? = nil
    ) {
      checks.append(
        TatwoHandoffCapabilityCheckV1(
          id: id,
          passed: passed,
          detail: detail,
          reasonCode: reason))
      if let reason, !reasons.contains(reason) {
        reasons.append(reason)
      }
      if rejection {
        rejected = true
      }
      if let degradation {
        degradations.append(degradation)
      }
    }

    // Verified gate already passed; record an explicit check so receipts show
    // pack verification was required before capability evaluation.
    record(
      id: "pack_verification",
      passed: true,
      detail: "pack passed signature/digest verify before capability assessment")

    if !capabilities.deviceID.isEmpty,
      pack.intendedReceiverDeviceID == capabilities.deviceID
    {
      record(
        id: "receiver_identity",
        passed: true,
        detail: "pack is addressed to this receiver")
    } else {
      record(
        id: "receiver_identity",
        passed: false,
        detail: "pack intended receiver does not match the declaration",
        reason: .receiverMismatch,
        rejection: true)
    }

    let commitReachable =
      capabilities.projectCommit == pack.commit
      || capabilities.reachableCommits.contains(pack.commit)
    if commitReachable {
      record(
        id: "project_commit",
        passed: true,
        detail: "pack commit is reachable on the receiver")
    } else {
      record(
        id: "project_commit",
        passed: false,
        detail: "pack commit is not reachable on the receiver",
        reason: .projectCommitUnreachable,
        rejection: true)
    }

    let treeReachable: Bool
    if let treeHash = pack.modificationState.treeHash {
      treeReachable =
        capabilities.projectTreeHash == treeHash
        || capabilities.reachableTreeHashes.contains(treeHash)
    } else {
      treeReachable = false
    }
    if treeReachable {
      record(
        id: "project_tree",
        passed: true,
        detail: "pack tree is reachable on the receiver")
    } else {
      record(
        id: "project_tree",
        passed: false,
        detail: "pack tree is not reachable on the receiver",
        reason: .projectTreeUnreachable,
        rejection: true)
    }

    if capabilities.supportedPackSchemas.contains(pack.schema) {
      record(
        id: "protocol_schema",
        passed: true,
        detail: "pack schema is supported")
    } else {
      record(
        id: "protocol_schema",
        passed: false,
        detail: "receiver does not support \(pack.schema)",
        reason: .protocolSchemaUnsupported,
        rejection: true)
    }

    let expired = expectations.now.timeIntervalSince(pack.freshUntil)
      > expectations.clockSkewSec
    if !expired {
      record(
        id: "freshness",
        passed: true,
        detail: "pack is inside its freshness window")
    } else if capabilities.canRefetchFreshData {
      record(
        id: "freshness",
        passed: false,
        detail: "pack is stale; receiver can refetch a fresh snapshot",
        reason: .freshnessRefetchable,
        degradation: "freshness_refetch_required")
    } else {
      record(
        id: "freshness",
        passed: false,
        detail: "pack is stale and receiver cannot refetch it",
        reason: .freshnessExpired,
        rejection: true)
    }

    if let expected = pack.toolchainFingerprint {
      if capabilities.swiftToolchainFingerprint == expected {
        record(
          id: "swift_toolchain",
          passed: true,
          detail: "Swift toolchain fingerprint matches")
      } else {
        record(
          id: "swift_toolchain",
          passed: false,
          detail: "Swift toolchain fingerprint differs from the pack",
          reason: .toolchainFingerprintMismatch,
          degradation: "swift_toolchain_fingerprint_mismatch")
      }
    } else {
      record(
        id: "swift_toolchain",
        passed: true,
        detail: "pack did not declare a Swift toolchain fingerprint")
    }

    let requiredRunners = pack.requiredRunners
    let unavailableRunners = requiredRunners.filter {
      capabilities.runnerAvailability[$0] != true
    }
    if unavailableRunners.isEmpty {
      record(
        id: "runners",
        passed: true,
        detail: requiredRunners.isEmpty
          ? "pack declares no mandatory runner"
          : "all mandatory runners are available")
    } else {
      let names = unavailableRunners.sorted().joined(separator: ",")
      record(
        id: "runners",
        passed: false,
        detail: "mandatory runner unavailable: \(names)",
        reason: .runnerUnavailable,
        degradation: "runner_unavailable:\(names)")
    }

    let requiredLanes = pack.requiredCapabilityLanes
    let missingLanes = requiredLanes.filter {
      !capabilities.permittedLanes.contains($0)
    }
    if missingLanes.isEmpty {
      record(
        id: "permissions",
        passed: true,
        detail: requiredLanes.isEmpty
          ? "pack declares no additional lane permissions"
          : "all required lanes are permitted")
    } else {
      let names = missingLanes.sorted().joined(separator: ",")
      record(
        id: "permissions",
        passed: false,
        detail: "required lane is not permitted: \(names)",
        reason: .permissionInsufficient,
        rejection: true)
    }

    if capabilities.localWorktreeDirty {
      record(
        id: "local_worktree",
        passed: false,
        detail: "receiver has unmerged local worktree changes",
        reason: .localWorktreeDirty,
        rejection: true)
    } else {
      record(
        id: "local_worktree",
        passed: true,
        detail: "receiver worktree is clean")
    }

    // Priority is reject > degraded > accept. Degradation must never promote
    // a rejected pack into accept (sol5 fail-open regression guard).
    let decision: TatwoHandoffCapabilityDecisionV1
    if rejected {
      decision = .reject
    } else if !degradations.isEmpty {
      decision = .degraded
    } else {
      decision = .accept
    }
    return TatwoHandoffAssessmentV1(
      handoffID: pack.handoffID,
      packDigest: verifiedPack.packDigest,
      logicalJobID: pack.logicalJobID,
      jobID: pack.jobID,
      dispatchNonce: pack.dispatchNonce,
      decision: decision,
      checks: checks,
      degradation: degradations,
      reasonCodes: reasons,
      reportedAt: expectations.now)
  }
}

public typealias TatwoHandoffReceiverCapabilityChecker =
  TatwoHandoffReceiverCapabilityCheckerV1

private struct TatwoHandoffAssessmentUnsignedV1: Codable, Sendable, Equatable {
  let schema: String
  let handoffID: String
  let packDigest: String
  let logicalJobID: String
  let jobID: String
  let dispatchNonce: String
  let decision: TatwoHandoffCapabilityDecisionV1
  let checks: [TatwoHandoffCapabilityCheckV1]
  let degradation: [String]
  let reasonCodes: [TatwoHandoffAssessmentReasonCodeV1]
  let reportedAt: Date

  init(assessment: TatwoHandoffAssessmentV1) {
    self.schema = assessment.schema
    self.handoffID = assessment.handoffID
    self.packDigest = assessment.packDigest
    self.logicalJobID = assessment.logicalJobID
    self.jobID = assessment.jobID
    self.dispatchNonce = assessment.dispatchNonce
    self.decision = assessment.decision
    self.checks = assessment.checks
    self.degradation = assessment.degradation
    self.reasonCodes = assessment.reasonCodes
    self.reportedAt = assessment.reportedAt
  }
}

private struct TatwoHandoffPackUnsignedV1: Codable, Sendable, Equatable {
  let schema: String
  let handoffID: String
  let logicalJobID: String
  let jobID: String
  let dispatchNonce: String
  let goal: TatwoHandoffGoalV1
  let context: TatwoHandoffContextSummaryV1
  let plan: TatwoHandoffPlanV1
  let modificationState: TatwoHandoffModificationStateV1
  let incompleteItems: [TatwoHandoffIncompleteItemV1]
  let requiredFiles: [TatwoHandoffRequiredFileV1]
  let sessionRoute: TatwoHandoffSessionRouteV1
  let receiptReferences: [TatwoHandoffReceiptReferenceV1]
  let riskHints: [String]
  let producerDevicePin: TatwoDevicePublicIdentityV1
  let intendedReceiverDeviceID: String?
  let priorOriginDeviceID: String
  let requestedLeaseDomainID: String
  let toolchainFingerprint: String?
  let requiredRunnerIDs: [String]?
  let requiredLanes: [String]?
  let createdAt: Date
  let freshnessWindowSec: TimeInterval
  let freshUntil: Date

  init(
    schema: String,
    handoffID: String,
    logicalJobID: String,
    jobID: String,
    dispatchNonce: String,
    goal: TatwoHandoffGoalV1,
    context: TatwoHandoffContextSummaryV1,
    plan: TatwoHandoffPlanV1,
    modificationState: TatwoHandoffModificationStateV1,
    incompleteItems: [TatwoHandoffIncompleteItemV1],
    requiredFiles: [TatwoHandoffRequiredFileV1],
    sessionRoute: TatwoHandoffSessionRouteV1,
    receiptReferences: [TatwoHandoffReceiptReferenceV1],
    riskHints: [String],
    producerDevicePin: TatwoDevicePublicIdentityV1,
    intendedReceiverDeviceID: String?,
    priorOriginDeviceID: String,
    requestedLeaseDomainID: String,
    toolchainFingerprint: String? = nil,
    requiredRunnerIDs: [String]? = nil,
    requiredLanes: [String]? = nil,
    createdAt: Date,
    freshnessWindowSec: TimeInterval,
    freshUntil: Date
  ) {
    self.schema = schema
    self.handoffID = handoffID
    self.logicalJobID = logicalJobID
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.goal = goal
    self.context = context
    self.plan = plan
    self.modificationState = modificationState
    self.incompleteItems = incompleteItems
    self.requiredFiles = requiredFiles
    self.sessionRoute = sessionRoute
    self.receiptReferences = receiptReferences
    self.riskHints = riskHints
    self.producerDevicePin = producerDevicePin
    self.intendedReceiverDeviceID = intendedReceiverDeviceID
    self.priorOriginDeviceID = priorOriginDeviceID
    self.requestedLeaseDomainID = requestedLeaseDomainID
    self.toolchainFingerprint = toolchainFingerprint
    self.requiredRunnerIDs = requiredRunnerIDs
    self.requiredLanes = requiredLanes
    self.createdAt = createdAt
    self.freshnessWindowSec = freshnessWindowSec
    self.freshUntil = freshUntil
  }

  init(pack: TatwoHandoffPackV1) {
    self.init(
      schema: pack.schema,
      handoffID: pack.handoffID,
      logicalJobID: pack.logicalJobID,
      jobID: pack.jobID,
      dispatchNonce: pack.dispatchNonce,
      goal: pack.goal,
      context: pack.context,
      plan: pack.plan,
      modificationState: pack.modificationState,
      incompleteItems: pack.incompleteItems,
      requiredFiles: pack.requiredFiles,
      sessionRoute: pack.sessionRoute,
      receiptReferences: pack.receiptReferences,
      riskHints: pack.riskHints,
      producerDevicePin: pack.producerDevicePin,
      intendedReceiverDeviceID: pack.intendedReceiverDeviceID,
      priorOriginDeviceID: pack.priorOriginDeviceID,
      requestedLeaseDomainID: pack.requestedLeaseDomainID,
      toolchainFingerprint: pack.toolchainFingerprint,
      requiredRunnerIDs: pack.requiredRunnerIDs,
      requiredLanes: pack.requiredLanes,
      createdAt: pack.createdAt,
      freshnessWindowSec: pack.freshnessWindowSec,
      freshUntil: pack.freshUntil)
  }

  func makeUnsignedPack() -> TatwoHandoffPackV1 {
    TatwoHandoffPackV1(
      schema: schema,
      handoffID: handoffID,
      logicalJobID: logicalJobID,
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      goal: goal,
      context: context,
      plan: plan,
      modificationState: modificationState,
      incompleteItems: incompleteItems,
      requiredFiles: requiredFiles,
      sessionRoute: sessionRoute,
      receiptReferences: receiptReferences,
      riskHints: riskHints,
      producerDevicePin: producerDevicePin,
      intendedReceiverDeviceID: intendedReceiverDeviceID,
      priorOriginDeviceID: priorOriginDeviceID,
      requestedLeaseDomainID: requestedLeaseDomainID,
      toolchainFingerprint: toolchainFingerprint,
      requiredRunnerIDs: requiredRunnerIDs,
      requiredLanes: requiredLanes,
      createdAt: createdAt,
      freshnessWindowSec: freshnessWindowSec,
      freshUntil: freshUntil,
      jobCanonicalDigest: "",
      packContentHash: "",
      signingKeyFingerprint: "",
      producerSignature: TatwoDeviceSignatureV1(
        purpose: TatwoHandoffPackSignaturePurposeV1.originTransferOffer.rawValue,
        deviceID: producerDevicePin.deviceID,
        keyID: producerDevicePin.keyID,
        keyGeneration: producerDevicePin.keyGeneration,
        payloadDigest: "",
        signedAt: "",
        signature: "unsigned"))
  }

  func canonicalPayloadData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }
}

private extension TatwoHandoffPackV1 {
  func firstValidationIssue() -> TatwoHandoffPackVerificationIssueV1? {
    if schema != Self.schemaName && schema != "TatwoHandoffPackV1" {
      return .init(code: .invalidSchema, detail: "unsupported handoff pack schema")
    }
    let requiredStrings: [(String, String)] = [
      ("handoffID", handoffID),
      ("logicalJobID", logicalJobID),
      ("jobID", jobID),
      ("dispatchNonce", dispatchNonce),
      ("goal.description", goal.description),
      ("context.summary", context.summary),
      ("plan.summary", plan.summary),
      ("modificationState.branch", modificationState.branch),
      ("modificationState.commit", modificationState.commit),
      ("sessionRoute.engine", sessionRoute.engine),
      ("sessionRoute.model", sessionRoute.model),
      ("sessionRoute.route", sessionRoute.route),
      ("priorOriginDeviceID", priorOriginDeviceID),
      ("requestedLeaseDomainID", requestedLeaseDomainID),
      ("producerDevicePin.deviceID", producerDevicePin.deviceID),
      ("producerDevicePin.keyID", producerDevicePin.keyID),
      ("intendedReceiverDeviceID", intendedReceiverDeviceID ?? "")
    ]
    if let missing = requiredStrings.first(where: { Self.isBlank($0.1) }) {
      return .init(
        code: .missingRequiredField,
        detail: "\(missing.0) is required")
    }
    if !Self.isSHA256(goal.goalHash) {
      return .init(code: .invalidHashFormat, detail: "goalHash is not sha256")
    }
    if !Self.isSHA256(plan.planHash) {
      return .init(code: .invalidHashFormat, detail: "planHash is not sha256")
    }
    if receiptReferences.isEmpty {
      return .init(
        code: .missingRequiredField,
        detail: "receiptReferences must contain at least one receipt")
    }
    if requiredFiles.isEmpty {
      return .init(
        code: .missingRequiredField,
        detail: "requiredFiles must contain at least one file")
    }
    for receipt in receiptReferences {
      if Self.isBlank(receipt.receiptID) || Self.isBlank(receipt.kind) {
        return .init(
          code: .missingRequiredField,
          detail: "receipt reference id and kind are required")
      }
      if !Self.isSHA256(receipt.contentHash) {
        return .init(
          code: .invalidHashFormat,
          detail: "receipt \(receipt.receiptID) does not have a sha256 hash")
      }
    }
    for file in requiredFiles {
      if !Self.isRelativePath(file.path) {
        return .init(code: .invalidPath, detail: "required file path is not repo-relative")
      }
      if !Self.isSHA256(file.sha256) {
        return .init(
          code: .invalidHashFormat,
          detail: "required file \(file.path) does not have a sha256 hash")
      }
    }
    if modificationState.dirty && Self.isBlank(modificationState.wipBranch ?? "") {
      return .init(
        code: .missingRequiredField,
        detail: "dirty worktree requires a wipBranch")
    }
    if !Self.isSHA256(context.sourceDigest ?? String(repeating: "a", count: 64))
      && context.sourceDigest != nil
    {
      return .init(code: .invalidHashFormat, detail: "context sourceDigest is not sha256")
    }
    if !Self.isFinitePositive(freshnessWindowSec)
      || freshnessWindowSec > Self.maxFreshnessWindowSec
      || freshUntil <= createdAt
      || abs(freshUntil.timeIntervalSince(createdAt) - freshnessWindowSec) > 0.001
    {
      return .init(
        code: .invalidFreshness,
        detail: "freshness window must be positive, bounded, and consistent")
    }
    if producerDevicePin.keyStatus != .active {
      return .init(code: .signatureRejected, detail: "producer pin is not active")
    }
    if producerSignature.signature.isEmpty {
      return .init(code: .signatureMissing, detail: "producer signature is empty")
    }
    return nil
  }

  static func isBlank(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func isFinitePositive(_ value: TimeInterval) -> Bool {
    value.isFinite && value > 0
  }

  static func isSHA256(_ value: String) -> Bool {
    let raw = value.hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
    guard raw.count == 64 else { return false }
    return raw.allSatisfy { $0.isHexDigit }
  }

  static func isRelativePath(_ value: String) -> Bool {
    let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
      return false
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.contains("..") && !components.contains("")
  }
}

// MARK: - S3 lease transfer / origin fencing

public enum TatwoHandoffLeaseTransferErrorV1: Error, LocalizedError, Equatable, Sendable {
  case assessmentNotAccepted
  case assessmentBindingMismatch
  case assessmentSignatureRejected
  case originLeaseMismatch
  case leaseExpired
  case invalidReceiver
  case epochOverflow
  case commitAlreadyExists
  case forgedCommit
  case staleEpoch
  case receiverNotAcknowledged
  case transferNotCommitted
  case reclaimNotAllowed
  case durableStoreUnavailable(String)
  case staleDurableEpoch(current: UInt64, highWater: UInt64)
  case durableJournalCorrupt(String)
  case originWriteFenced

  public var errorDescription: String? {
    switch self {
    case .assessmentNotAccepted: "handoff assessment is not accept"
    case .assessmentBindingMismatch: "assessment is not bound to the verified pack"
    case .assessmentSignatureRejected: "receiver assessment signature was rejected"
    case .originLeaseMismatch: "current lease is not the pack origin lease"
    case .leaseExpired: "current origin lease is expired"
    case .invalidReceiver: "receiver must be distinct from the origin"
    case .epochOverflow: "lease epoch cannot be incremented"
    case .commitAlreadyExists: "a transfer commit already exists for this handoff"
    case .forgedCommit: "transfer commit signature or fields are invalid"
    case .staleEpoch: "epoch is stale or fenced"
    case .receiverNotAcknowledged: "receiver has not acknowledged the committed lease"
    case .transferNotCommitted: "transfer has not reached the commit point"
    case .reclaimNotAllowed: "lease reclaim is not allowed in the current state"
    case let .durableStoreUnavailable(detail):
      "durable lease store unavailable: \(detail)"
    case let .staleDurableEpoch(current, highWater):
      "lease epoch \(current) is below durable high-water \(highWater)"
    case let .durableJournalCorrupt(detail):
      "durable lease journal is corrupt: \(detail)"
    case .originWriteFenced:
      "origin write rejected by lease fencing"
    }
  }
}

/// Durable fencing configuration.  Production construction is intentionally
/// bound to the fleet Keychain high-water anchor; tests inject an in-memory
/// or file-backed `TatwoFleetHighWaterAnchor`.
public struct TatwoHandoffLeaseTransferDurableConfigurationV1: @unchecked Sendable {
  public let rootURL: URL
  public let highWater: any TatwoFleetHighWaterAnchor
  public let signingTrust: TatwoLoopJobChannelTrust

  public init(
    rootURL: URL,
    highWater: any TatwoFleetHighWaterAnchor,
    signingTrust: TatwoLoopJobChannelTrust
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.highWater = highWater
    self.signingTrust = signingTrust
  }

  /// Production path: the durable anti-rollback authority is Keychain-backed.
  /// The stable domain binding deliberately does not change when the lease
  /// holder changes from origin to receiver.
  public static func production(
    rootURL: URL,
    domainID: String,
    signingTrust: TatwoLoopJobChannelTrust
  ) -> TatwoHandoffLeaseTransferDurableConfigurationV1 {
    let binding = "handoff-domain:\(domainID)"
    return TatwoHandoffLeaseTransferDurableConfigurationV1(
      rootURL: rootURL,
      highWater: TatwoFleetKeychainHighWaterAnchor(originDeviceID: binding),
      signingTrust: signingTrust)
  }
}

private enum TatwoHandoffLeaseJournalEventV1: String, Codable {
  case initialLease
  case pendingTransfer
  case commit
  case receiverAcknowledged
  case adopt
  case reclaim
}

private struct TatwoHandoffLeaseJournalUnsignedV1: Codable, Sendable {
  let schema: String
  let sequence: UInt64
  let event: TatwoHandoffLeaseJournalEventV1
  let logicalLeaseID: String
  let epoch: UInt64
  let lease: TatwoAuthorityLeaseV1
  let transfer: TatwoHandoffLeaseTransferV1?
  let receiverAcknowledged: Bool
  let recordedAt: Date
}

private struct TatwoHandoffLeaseJournalEntryV1: Codable, Sendable {
  let unsigned: TatwoHandoffLeaseJournalUnsignedV1
  let authorization: TatwoDeviceSignatureV1
}

private struct TatwoHandoffLeaseCommitSlotV1: Codable, Sendable {
  let schema: String
  let logicalLeaseID: String
  let fromEpoch: UInt64
  let transfer: TatwoHandoffLeaseTransferV1
}

private struct TatwoHandoffLeaseTransferUnsignedV1: Codable, Sendable {
  let schema: String
  let transferID: String
  let handoffID: String
  let logicalJobID: String
  let packDigest: String
  let assessmentDigest: String
  let domainID: String
  let fromDeviceID: String
  let toDeviceID: String
  let previousEpoch: UInt64
  let leaseEpoch: UInt64
  let generation: UInt64
  let fencingToken: String
  let committedAt: Date
  let newLease: TatwoAuthorityLeaseV1
  let receiptMetadata: TatwoWorkReceiptMetadataV1
}

/// Immutable S3 transfer-commit record. The store's `finalizeCommit` is the
/// single commit point; a pending issued record never grants receiver writes.
public struct TatwoHandoffLeaseTransferV1: Codable, Equatable, Sendable {
  public static let schemaName = "TatwoHandoffLeaseTransferV1"
  public static let signaturePurpose = TatwoHandoffPackSignaturePurposeV1.originTransferCommit.rawValue

  public let schema: String
  public let transferID: String
  public let handoffID: String
  public let logicalJobID: String
  public let packDigest: String
  public let assessmentDigest: String
  public let domainID: String
  public let fromDeviceID: String
  public let toDeviceID: String
  public let previousEpoch: UInt64
  public let leaseEpoch: UInt64
  public let generation: UInt64
  public let fencingToken: String
  public let committedAt: Date
  public let newLease: TatwoAuthorityLeaseV1
  public let receiptMetadata: TatwoWorkReceiptMetadataV1
  public let originSignature: TatwoDeviceSignatureV1
  public let receiverSignature: TatwoDeviceSignatureV1

  public var epoch: UInt64 { leaseEpoch }
  public var leaseGeneration: UInt64 { generation }
  public var newEpoch: UInt64 { leaseEpoch }
  public var oldOriginDeviceID: String { fromDeviceID }
  public var newOriginDeviceID: String { toDeviceID }
  public var lease: TatwoAuthorityLeaseV1 { newLease }

  public init(
    schema: String = TatwoHandoffLeaseTransferV1.schemaName,
    transferID: String,
    handoffID: String,
    logicalJobID: String,
    packDigest: String,
    assessmentDigest: String,
    domainID: String,
    fromDeviceID: String,
    toDeviceID: String,
    previousEpoch: UInt64,
    leaseEpoch: UInt64,
    generation: UInt64,
    fencingToken: String,
    committedAt: Date,
    newLease: TatwoAuthorityLeaseV1,
    receiptMetadata: TatwoWorkReceiptMetadataV1,
    originSignature: TatwoDeviceSignatureV1,
    receiverSignature: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.transferID = transferID
    self.handoffID = handoffID
    self.logicalJobID = logicalJobID
    self.packDigest = packDigest
    self.assessmentDigest = assessmentDigest
    self.domainID = domainID
    self.fromDeviceID = fromDeviceID
    self.toDeviceID = toDeviceID
    self.previousEpoch = previousEpoch
    self.leaseEpoch = leaseEpoch
    self.generation = generation
    self.fencingToken = fencingToken
    self.committedAt = committedAt
    self.newLease = newLease
    self.receiptMetadata = receiptMetadata
    self.originSignature = originSignature
    self.receiverSignature = receiverSignature
  }

  public init(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    currentOriginLease: TatwoAuthorityLeaseV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    leaseDuration: TimeInterval? = nil
  ) throws {
    self = try Self.create(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      currentOriginLease: currentOriginLease,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now,
      leaseDuration: leaseDuration)
  }

  private func unsignedPayload() -> TatwoHandoffLeaseTransferUnsignedV1 {
    TatwoHandoffLeaseTransferUnsignedV1(
      schema: schema,
      transferID: transferID,
      handoffID: handoffID,
      logicalJobID: logicalJobID,
      packDigest: packDigest,
      assessmentDigest: assessmentDigest,
      domainID: domainID,
      fromDeviceID: fromDeviceID,
      toDeviceID: toDeviceID,
      previousEpoch: previousEpoch,
      leaseEpoch: leaseEpoch,
      generation: generation,
      fencingToken: fencingToken,
      committedAt: committedAt,
      newLease: newLease,
      receiptMetadata: receiptMetadata)
  }

  public func canonicalPayloadData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(unsignedPayload())
  }

  public func canonicalDigest() throws -> String {
    TatwoLoopJobDigest.sha256(try canonicalPayloadData())
  }

  public static func create(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    currentOriginLease: TatwoAuthorityLeaseV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    leaseDuration: TimeInterval? = nil
  ) throws -> TatwoHandoffLeaseTransferV1 {
    let pack = verifiedPack.pack
    guard acceptAssessment.decision == .accept else {
      throw TatwoHandoffLeaseTransferErrorV1.assessmentNotAccepted
    }
    guard acceptAssessment.matchesPackBinding(verifiedPack) else {
      throw TatwoHandoffLeaseTransferErrorV1.assessmentBindingMismatch
    }
    guard acceptAssessment.verifySignature(
      using: receiverTrust,
      expectedReporterDeviceID: pack.intendedReceiverDeviceID,
      against: verifiedPack
    ) else {
      throw TatwoHandoffLeaseTransferErrorV1.assessmentSignatureRejected
    }
    guard currentOriginLease.domainID == pack.requestedLeaseDomainID,
      currentOriginLease.holderDeviceID == pack.priorOriginDeviceID,
      currentOriginLease.holderDeviceID == originTrust.localIdentity.deviceID,
      currentOriginLease.epoch > 0,
      currentOriginLease.source == .humanConfirmed
    else {
      throw TatwoHandoffLeaseTransferErrorV1.originLeaseMismatch
    }
    guard let receiverID = pack.intendedReceiverDeviceID,
      !receiverID.isEmpty,
      receiverID == receiverTrust.localIdentity.deviceID,
      receiverID != currentOriginLease.holderDeviceID
    else {
      throw TatwoHandoffLeaseTransferErrorV1.invalidReceiver
    }
    guard currentOriginLease.expiresAt > now else {
      throw TatwoHandoffLeaseTransferErrorV1.leaseExpired
    }
    guard currentOriginLease.epoch < UInt64.max else {
      throw TatwoHandoffLeaseTransferErrorV1.epochOverflow
    }
    let nextEpoch = currentOriginLease.epoch + 1
    let duration = leaseDuration ?? currentOriginLease.expiresAt.timeIntervalSince(now)
    guard duration > 0, duration.isFinite else {
      throw TatwoHandoffLeaseTransferErrorV1.leaseExpired
    }
    let transferID = UUID().uuidString.lowercased()
    let receiptMetadata = TatwoWorkReceiptMetadataV1(
      receiptID: "handoff-transfer-\(transferID)",
      schema: TatwoHandoffLeaseTransferV1.schemaName,
      version: 1,
      correlationID: pack.handoffID,
      createdAt: now,
      sourceDeviceID: currentOriginLease.holderDeviceID)
    let newLease = TatwoAuthorityLeaseV1(
      domainID: currentOriginLease.domainID,
      holderDeviceID: receiverID,
      epoch: nextEpoch,
      fencingToken: UUID().uuidString.lowercased(),
      observedAt: now,
      expiresAt: now.addingTimeInterval(duration),
      source: .humanConfirmed,
      receiptMetadata: receiptMetadata)
    let assessmentDigest = try acceptAssessment.canonicalDigest()
    let unsigned = TatwoHandoffLeaseTransferUnsignedV1(
      schema: TatwoHandoffLeaseTransferV1.schemaName,
      transferID: transferID,
      handoffID: pack.handoffID,
      logicalJobID: pack.logicalJobID,
      packDigest: verifiedPack.packDigest,
      assessmentDigest: assessmentDigest,
      domainID: currentOriginLease.domainID,
      fromDeviceID: currentOriginLease.holderDeviceID,
      toDeviceID: receiverID,
      previousEpoch: currentOriginLease.epoch,
      leaseEpoch: nextEpoch,
      generation: nextEpoch,
      fencingToken: newLease.fencingToken,
      committedAt: now,
      newLease: newLease,
      receiptMetadata: receiptMetadata)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(unsigned)
    let originSignature = try originTrust.authority.sign(
      payload: payload,
      purpose: TatwoHandoffLeaseTransferV1.signaturePurpose,
      identity: originTrust.localIdentity,
      signedAt: TatwoLoopJobChannelTrust.iso8601(now))
    let receiverSignature = try receiverTrust.authority.sign(
      payload: payload,
      purpose: TatwoHandoffLeaseTransferV1.signaturePurpose,
      identity: receiverTrust.localIdentity,
      signedAt: TatwoLoopJobChannelTrust.iso8601(now))
    return TatwoHandoffLeaseTransferV1(
      transferID: transferID,
      handoffID: pack.handoffID,
      logicalJobID: pack.logicalJobID,
      packDigest: verifiedPack.packDigest,
      assessmentDigest: assessmentDigest,
      domainID: currentOriginLease.domainID,
      fromDeviceID: currentOriginLease.holderDeviceID,
      toDeviceID: receiverID,
      previousEpoch: currentOriginLease.epoch,
      leaseEpoch: nextEpoch,
      generation: nextEpoch,
      fencingToken: newLease.fencingToken,
      committedAt: now,
      newLease: newLease,
      receiptMetadata: receiptMetadata,
      originSignature: originSignature,
      receiverSignature: receiverSignature)
  }

  public static func commit(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    currentOriginLease: TatwoAuthorityLeaseV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    leaseDuration: TimeInterval? = nil
  ) throws -> TatwoHandoffLeaseTransferV1 {
    try create(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      currentOriginLease: currentOriginLease,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now,
      leaseDuration: leaseDuration)
  }

  public static func make(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    currentOriginLease: TatwoAuthorityLeaseV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    leaseDuration: TimeInterval? = nil
  ) throws -> TatwoHandoffLeaseTransferV1 {
    try create(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      currentOriginLease: currentOriginLease,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now,
      leaseDuration: leaseDuration)
  }

  public func verify(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    currentOriginLease: TatwoAuthorityLeaseV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date()
  ) throws {
    let pack = verifiedPack.pack
    guard schema == Self.schemaName,
      packDigest == verifiedPack.packDigest,
      handoffID == pack.handoffID,
      logicalJobID == pack.logicalJobID,
      domainID == pack.requestedLeaseDomainID,
      fromDeviceID == currentOriginLease.holderDeviceID,
      fromDeviceID == pack.priorOriginDeviceID,
      toDeviceID == pack.intendedReceiverDeviceID,
      currentOriginLease.domainID == domainID,
      previousEpoch == currentOriginLease.epoch,
      leaseEpoch == previousEpoch + 1,
      generation == leaseEpoch,
      newLease.epoch == leaseEpoch,
      newLease.holderDeviceID == toDeviceID,
      newLease.fencingToken == fencingToken,
      newLease.domainID == domainID,
      newLease.source == .humanConfirmed,
      newLease.expiresAt > committedAt,
      committedAt <= now.addingTimeInterval(TatwoLoopJobChannelTrust.signatureClockSkewSec)
    else {
      throw TatwoHandoffLeaseTransferErrorV1.forgedCommit
    }
    guard acceptAssessment.decision == .accept,
      acceptAssessment.matchesPackBinding(verifiedPack),
      try acceptAssessment.canonicalDigest() == assessmentDigest
    else {
      throw TatwoHandoffLeaseTransferErrorV1.assessmentBindingMismatch
    }
    guard acceptAssessment.verifySignature(
      using: receiverTrust,
      expectedReporterDeviceID: toDeviceID,
      against: verifiedPack
    ) else {
      throw TatwoHandoffLeaseTransferErrorV1.assessmentSignatureRejected
    }
    let payload = try canonicalPayloadData()
    guard let originPinned = originTrust.pinnedIdentities[fromDeviceID],
      let receiverPinned = receiverTrust.pinnedIdentities[toDeviceID]
    else {
      throw TatwoHandoffLeaseTransferErrorV1.forgedCommit
    }
    do {
      try TatwoDeviceTrustAuthority.verify(
        payload: payload,
        purpose: Self.signaturePurpose,
        signature: originSignature,
        pinnedIdentity: originPinned)
      try TatwoDeviceTrustAuthority.verify(
        payload: payload,
        purpose: Self.signaturePurpose,
        signature: receiverSignature,
        pinnedIdentity: receiverPinned)
    } catch {
      throw TatwoHandoffLeaseTransferErrorV1.forgedCommit
    }
  }

  public static func verify(
    _ transfer: TatwoHandoffLeaseTransferV1,
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    currentOriginLease: TatwoAuthorityLeaseV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date()
  ) throws {
    try transfer.verify(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      currentOriginLease: currentOriginLease,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now)
  }

  public func isOriginAuthority(deviceID: String, epoch: UInt64, now: Date = Date()) -> Bool {
    deviceID == toDeviceID && epoch == leaseEpoch && newLease.expiresAt > now
  }
}

public typealias TatwoOriginTransferCommittedV1 = TatwoHandoffLeaseTransferV1
public typealias TatwoOriginTransferReceiptV1 = TatwoHandoffLeaseTransferV1

public final class TatwoHandoffLeaseTransferStoreV1:
  @unchecked Sendable, TatwoOriginAuthorityProviding
{
  private static let journalSchema = "TatwoHandoffLeaseJournalV1"
  private static let journalSignaturePurpose = "handoff-lease-journal"
  private static let commitSlotSchema = "TatwoHandoffLeaseCommitSlotV1"

  private let lock = NSLock()
  private var activeLease: TatwoAuthorityLeaseV1
  private var pendingTransfer: TatwoHandoffLeaseTransferV1?
  private var transferCommit: TatwoHandoffLeaseTransferV1?
  private var receiverAcknowledged = false
  private var durableConfiguration: TatwoHandoffLeaseTransferDurableConfigurationV1?
  private var journalSequence: UInt64 = 0
  private var durableEpochHighWater: UInt64 = 0
  private var durableFault = false
  private var leaseAdopted = true

  /// RAM-only store for in-module fixtures via `@testable import`.
  /// No cross-process fencing authority — production must use the durable
  /// initializer below. Not part of the public product API.
  internal init(currentOriginLease: TatwoAuthorityLeaseV1) {
    self.activeLease = currentOriginLease
  }

  /// Production and crash-restore construction path. Public API only exposes
  /// this durable builder; RAM-only stores stay internal for tests.
  internal convenience init(
    currentOriginLease: TatwoAuthorityLeaseV1,
    durableConfiguration: TatwoHandoffLeaseTransferDurableConfigurationV1
  ) throws {
    self.init(currentOriginLease: currentOriginLease)
    self.durableConfiguration = durableConfiguration
    try restoreDurableState()
  }

  /// Canonical production constructor.  The durable root and Keychain-backed
  /// high-water are always selected together; callers cannot accidentally
  /// create a production provider backed only by RAM.
  public convenience init(
    productionOriginLease: TatwoAuthorityLeaseV1,
    durableRootURL: URL,
    signingTrust: TatwoLoopJobChannelTrust
  ) throws {
    // K1: a lease domain must already exist in the durable create-only
    // registry.  This prevents a caller from minting a new authority
    // namespace by changing only the domain string.
    try TatwoAuthorityDomainRegistryV1(rootURL: durableRootURL)
      .requireRegistered(domainID: productionOriginLease.domainID)
    let configuration = TatwoHandoffLeaseTransferDurableConfigurationV1.production(
      rootURL: durableRootURL,
      domainID: productionOriginLease.domainID,
      signingTrust: signingTrust)
    try self.init(
      currentOriginLease: productionOriginLease,
      durableConfiguration: configuration)
  }

  public var currentLease: TatwoAuthorityLeaseV1 {
    lock.lock()
    defer { lock.unlock() }
    return activeLease
  }

  public var authorityDomainID: String? {
    currentLease.domainID
  }

  public var authorityEpoch: UInt64? {
    currentLease.epoch
  }

  public var commit: TatwoHandoffLeaseTransferV1? {
    lock.lock()
    defer { lock.unlock() }
    return transferCommit
  }

  /// Issue a signed transfer offer without crossing the commit point.  Until
  /// `finalizeCommit` is called, the current origin remains the only writer.
  @discardableResult
  public func issueTransfer(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    leaseDuration: TimeInterval? = nil
  ) throws -> TatwoHandoffLeaseTransferV1 {
    lock.lock()
    defer { lock.unlock() }
    try assertOriginWritableLocked(originTrust: originTrust, now: now)
    if transferCommit != nil {
      throw TatwoHandoffLeaseTransferErrorV1.commitAlreadyExists
    }
    if let pendingTransfer {
      guard pendingTransfer.handoffID == verifiedPack.handoffID,
        pendingTransfer.packDigest == verifiedPack.packDigest,
        (try? acceptAssessment.canonicalDigest()) == pendingTransfer.assessmentDigest
      else {
        throw TatwoHandoffLeaseTransferErrorV1.commitAlreadyExists
      }
      return pendingTransfer
    }
    let issued = try TatwoHandoffLeaseTransferV1.create(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      currentOriginLease: activeLease,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now,
      leaseDuration: leaseDuration)
    pendingTransfer = issued
    try persistEventLocked(
      .pendingTransfer,
      lease: activeLease,
      transfer: issued,
      receiverAcknowledged: false)
    return issued
  }

  public func beginTransfer(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    leaseDuration: TimeInterval? = nil
  ) throws -> TatwoHandoffLeaseTransferV1 {
    try issueTransfer(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now,
      leaseDuration: leaseDuration)
  }

  public func createCommit(
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date(),
    leaseDuration: TimeInterval? = nil
  ) throws -> TatwoHandoffLeaseTransferV1 {
    lock.lock()
    defer { lock.unlock() }
    try validateDurableStateForMutationLocked()
    if let existing = transferCommit {
      guard existing.handoffID == verifiedPack.handoffID,
        existing.packDigest == verifiedPack.packDigest,
        existing.previousEpoch > 0,
        (try? acceptAssessment.canonicalDigest()) == existing.assessmentDigest
      else {
        throw TatwoHandoffLeaseTransferErrorV1.commitAlreadyExists
      }
      return existing
    }
    try assertOriginWritableLocked(originTrust: originTrust, now: now)
    if let pendingTransfer {
      guard pendingTransfer.handoffID == verifiedPack.handoffID,
        pendingTransfer.packDigest == verifiedPack.packDigest
      else {
        throw TatwoHandoffLeaseTransferErrorV1.commitAlreadyExists
      }
      guard receiverAcknowledged else {
        throw TatwoHandoffLeaseTransferErrorV1.receiverNotAcknowledged
      }
      try persistCommitLocked(pendingTransfer)
      transferCommit = pendingTransfer
      if durableConfiguration != nil {
        activeLease = pendingTransfer.newLease
        leaseAdopted = false
      }
      self.pendingTransfer = nil
      return pendingTransfer
    }
    let created = try TatwoHandoffLeaseTransferV1.create(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      currentOriginLease: activeLease,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now,
      leaseDuration: leaseDuration)
    try persistCommitLocked(created)
    transferCommit = created
    if durableConfiguration != nil {
      activeLease = created.newLease
      leaseAdopted = false
    }
    return created
  }

  public func acknowledgeReceiver(deviceID: String, epoch: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    try validateDurableStateForMutationLocked()
    guard let transfer = transferCommit ?? pendingTransfer,
      transfer.toDeviceID == deviceID,
      transfer.leaseEpoch == epoch
    else {
      throw TatwoHandoffLeaseTransferErrorV1.transferNotCommitted
    }
    receiverAcknowledged = true
    try persistEventLocked(
      .receiverAcknowledged,
      lease: activeLease,
      transfer: transfer,
      receiverAcknowledged: true)
  }

  @discardableResult
  public func finalizeCommit() throws -> TatwoHandoffLeaseTransferV1 {
    lock.lock()
    defer { lock.unlock() }
    // A durable production commit must carry an origin authority proof.  The
    // legacy no-argument API remains only for in-memory fixtures.
    guard durableConfiguration == nil else {
      throw TatwoHandoffLeaseTransferErrorV1.originWriteFenced
    }
    return try finalizeCommitLocked()
  }

  /// Origin-authorized durable finalization.  The target may propose a
  /// transfer, but only the current origin can cross the durable commit point.
  @discardableResult
  public func finalizeCommit(
    originTrust: TatwoLoopJobChannelTrust,
    now: Date = Date()
  ) throws -> TatwoHandoffLeaseTransferV1 {
    lock.lock()
    defer { lock.unlock() }
    try assertOriginWritableLocked(originTrust: originTrust, now: now)
    return try finalizeCommitLocked()
  }

  private func finalizeCommitLocked() throws -> TatwoHandoffLeaseTransferV1 {
    guard let pendingTransfer else {
      if let transferCommit {
        return transferCommit
      }
      throw TatwoHandoffLeaseTransferErrorV1.transferNotCommitted
    }
    guard receiverAcknowledged else {
      throw TatwoHandoffLeaseTransferErrorV1.receiverNotAcknowledged
    }
    try persistCommitLocked(pendingTransfer)
    transferCommit = pendingTransfer
    if durableConfiguration != nil {
      activeLease = pendingTransfer.newLease
      leaseAdopted = false
    }
    self.pendingTransfer = nil
    return pendingTransfer
  }

  @discardableResult
  public func installCommit(
    _ commit: TatwoHandoffLeaseTransferV1,
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date()
  ) throws -> TatwoHandoffLeaseTransferV1 {
    lock.lock()
    defer { lock.unlock() }
    try validateDurableStateForMutationLocked()
    if let existing = transferCommit {
      guard existing == commit else {
        throw TatwoHandoffLeaseTransferErrorV1.commitAlreadyExists
      }
      return existing
    }
    try assertOriginWritableLocked(originTrust: originTrust, now: now)
    try commit.verify(
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      currentOriginLease: activeLease,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now)
    try persistCommitLocked(commit)
    transferCommit = commit
    if durableConfiguration != nil {
      activeLease = commit.newLease
      leaseAdopted = false
    }
    return commit
  }

  @discardableResult
  public func adopt(receiverDeviceID: String, epoch: UInt64) throws -> TatwoAuthorityLeaseV1 {
    lock.lock()
    defer { lock.unlock() }
    try validateDurableStateForMutationLocked()
    guard let transferCommit else {
      throw TatwoHandoffLeaseTransferErrorV1.transferNotCommitted
    }
    guard transferCommit.toDeviceID == receiverDeviceID,
      transferCommit.leaseEpoch == epoch
    else {
      throw TatwoHandoffLeaseTransferErrorV1.staleEpoch
    }
    guard receiverAcknowledged else {
      throw TatwoHandoffLeaseTransferErrorV1.receiverNotAcknowledged
    }
    activeLease = transferCommit.newLease
    leaseAdopted = true
    try persistEventLocked(
      .adopt,
      lease: activeLease,
      transfer: transferCommit,
      receiverAcknowledged: true)
    return activeLease
  }

  public func isOriginAuthority(
    deviceID: String,
    epoch: UInt64,
    now: Date = Date()
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !durableFault else { return false }
    do {
      try validateDurableStateReadableLocked()
    } catch {
      durableFault = true
      return false
    }
    return isOriginAuthorityLocked(deviceID: deviceID, epoch: epoch, now: now)
  }

  public func canWrite(deviceID: String, epoch: UInt64, now: Date = Date()) -> Bool {
    isOriginAuthority(deviceID: deviceID, epoch: epoch, now: now)
  }

  /// Throwing production gate. Unlike the legacy Bool query, this preserves
  /// durable journal/high-water failures as structured fail-closed errors.
  public func requireOriginAuthority(
    deviceID: String,
    epoch: UInt64,
    surface: String,
    now: Date = Date()
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !durableFault else {
      throw TatwoOriginAuthorityError.durableStoreUnavailable(
        surface: surface,
        detail: "handoff lease journal/high-water is unavailable"
      )
    }
    do {
      try validateDurableStateReadableLocked()
    } catch {
      durableFault = true
      throw TatwoOriginAuthorityError.durableStoreUnavailable(
        surface: surface,
        detail: "handoff lease journal/high-water is unavailable: \(error.localizedDescription)"
      )
    }
    guard isOriginAuthorityLocked(deviceID: deviceID, epoch: epoch, now: now) else {
      throw TatwoOriginAuthorityError.originWriteFenced(
        surface: surface,
        domainID: activeLease.domainID,
        deviceID: deviceID,
        epoch: epoch
      )
    }
  }

  /// Gate the domain-side adoption transition. A receiver with an acknowledged
  /// durable transfer may cross this boundary once; ordinary writes still wait
  /// for the explicit `adopt` event.
  public func requireAuthorityLeaseAdoption(
    deviceID: String,
    epoch: UInt64,
    surface: String,
    now: Date = Date()
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !durableFault else {
      throw TatwoOriginAuthorityError.durableStoreUnavailable(
        surface: surface,
        detail: "handoff lease journal/high-water is unavailable"
      )
    }
    do {
      try validateDurableStateReadableLocked()
    } catch {
      durableFault = true
      throw TatwoOriginAuthorityError.durableStoreUnavailable(
        surface: surface,
        detail: "handoff lease journal/high-water is unavailable: \(error.localizedDescription)"
      )
    }
    if let transferCommit,
      receiverAcknowledged,
      transferCommit.toDeviceID == deviceID,
      transferCommit.leaseEpoch == epoch,
      transferCommit.newLease.expiresAt > now
    {
      return
    }
    guard isOriginAuthorityLocked(deviceID: deviceID, epoch: epoch, now: now) else {
      throw TatwoOriginAuthorityError.originWriteFenced(
        surface: surface,
        domainID: activeLease.domainID,
        deviceID: deviceID,
        epoch: epoch
      )
    }
  }

  @discardableResult
  public func recordCommit(
    _ commit: TatwoHandoffLeaseTransferV1,
    verifiedPack: TatwoVerifiedHandoffPackV1,
    acceptAssessment: TatwoHandoffAssessmentV1,
    originTrust: TatwoLoopJobChannelTrust,
    receiverTrust: TatwoLoopJobChannelTrust,
    now: Date = Date()
  ) throws -> TatwoHandoffLeaseTransferV1 {
    try installCommit(
      commit,
      verifiedPack: verifiedPack,
      acceptAssessment: acceptAssessment,
      originTrust: originTrust,
      receiverTrust: receiverTrust,
      now: now)
  }

  @discardableResult
  public func adoptAuthorityLease(
    receiverDeviceID: String,
    epoch: UInt64
  ) throws -> TatwoAuthorityLeaseV1 {
    try adopt(receiverDeviceID: receiverDeviceID, epoch: epoch)
  }

  @discardableResult
  public func reclaimExpiredLease(now: Date = Date()) throws -> TatwoAuthorityLeaseV1 {
    lock.lock()
    defer { lock.unlock() }
    try validateDurableStateForMutationLocked()
    guard transferCommit == nil, activeLease.expiresAt <= now else {
      throw TatwoHandoffLeaseTransferErrorV1.reclaimNotAllowed
    }
    guard activeLease.epoch < UInt64.max else {
      throw TatwoHandoffLeaseTransferErrorV1.epochOverflow
    }
    let nextEpoch = activeLease.epoch + 1
    let metadata = TatwoWorkReceiptMetadataV1(
      receiptID: "handoff-reclaim-\(UUID().uuidString.lowercased())",
      schema: "TatwoAuthorityLeaseReclaimV1",
      version: 1,
      correlationID: activeLease.receiptMetadata.correlationID,
      createdAt: now,
      sourceDeviceID: activeLease.holderDeviceID)
    let reclaimed = TatwoAuthorityLeaseV1(
      domainID: activeLease.domainID,
      holderDeviceID: activeLease.holderDeviceID,
      epoch: nextEpoch,
      fencingToken: UUID().uuidString.lowercased(),
      observedAt: now,
      expiresAt: now.addingTimeInterval(
        max(activeLease.expiresAt.timeIntervalSince(activeLease.observedAt), 1)),
      source: .humanConfirmed,
      receiptMetadata: metadata)
    activeLease = reclaimed
    pendingTransfer = nil
    receiverAcknowledged = false
    leaseAdopted = true
    try persistEventLocked(
      .reclaim,
      lease: activeLease,
      transfer: nil,
      receiverAcknowledged: false)
    return reclaimed
  }

  // MARK: - Durable journal / fencing

  /// Re-check the durable journal/high-water on every authority query.  A
  /// successfully restored store must not keep writing if another process
  /// deletes, truncates, or replaces its fencing evidence after startup.
  private func validateDurableStateReadableLocked() throws {
    guard let durableConfiguration else { return }
    let highWater = try durableConfiguration.highWater.loadAuthorityHighWater()
    guard let highWater else {
      throw TatwoHandoffLeaseTransferErrorV1.durableStoreUnavailable(
        "authority high-water is missing")
    }
    let journal = journalURL(
      rootURL: durableConfiguration.rootURL,
      logicalLeaseID: activeLease.domainID)
    guard FileManager.default.fileExists(atPath: journal.path) else {
      throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
        "authority journal is missing")
    }
    let raw = try Data(contentsOf: journal)
    let lines = raw.split(separator: 0x0A, omittingEmptySubsequences: true)
    var sequence: UInt64 = 0
    var maxEpoch: UInt64 = 0
    for line in lines {
      let entry = try decodeJSON(
        TatwoHandoffLeaseJournalEntryV1.self,
        from: Data(line))
      let expected = sequence + 1
      guard entry.unsigned.schema == Self.journalSchema,
        entry.unsigned.logicalLeaseID == activeLease.domainID,
        entry.unsigned.sequence == expected
      else {
        throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
          "authority journal sequence or domain mismatch")
      }
      guard let pinned = durableConfiguration.signingTrust.pinnedIdentities[
        entry.authorization.deviceID
      ] else {
        throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
          "authority journal signer is not pinned")
      }
      try TatwoDeviceTrustAuthority.verify(
        payload: encodeJSON(entry.unsigned),
        purpose: Self.journalSignaturePurpose,
        signature: entry.authorization,
        pinnedIdentity: pinned)
      sequence = entry.unsigned.sequence
      maxEpoch = max(maxEpoch, entry.unsigned.epoch)
    }
    guard sequence == journalSequence,
      maxEpoch <= durableEpochHighWater,
      highWater.ledgerSequence == journalSequence,
      highWater.authorityEpoch == durableEpochHighWater
    else {
      throw TatwoHandoffLeaseTransferErrorV1.durableStoreUnavailable(
        "authority journal/high-water changed after restore")
    }
  }

  private func validateDurableStateForMutationLocked() throws {
    guard durableConfiguration != nil else { return }
    guard !durableFault else {
      throw TatwoHandoffLeaseTransferErrorV1.durableStoreUnavailable(
        "previous durable mutation failed")
    }
    do {
      try validateDurableStateReadableLocked()
    } catch let error as TatwoHandoffLeaseTransferErrorV1 {
      durableFault = true
      throw error
    } catch {
      durableFault = true
      throw TatwoHandoffLeaseTransferErrorV1.durableStoreUnavailable(
        error.localizedDescription)
    }
  }

  private func assertOriginWritableLocked(
    originTrust: TatwoLoopJobChannelTrust,
    now: Date
  ) throws {
    guard !durableFault else {
      throw TatwoHandoffLeaseTransferErrorV1.durableStoreUnavailable(
        "previous durable mutation failed")
    }
    try validateDurableStateForMutationLocked()
    guard activeLease.holderDeviceID == originTrust.localIdentity.deviceID,
      isOriginAuthorityLocked(
        deviceID: originTrust.localIdentity.deviceID,
        epoch: activeLease.epoch,
        now: now)
    else {
      throw TatwoHandoffLeaseTransferErrorV1.originWriteFenced
    }
  }

  private func isOriginAuthorityLocked(
    deviceID: String,
    epoch: UInt64,
    now: Date
  ) -> Bool {
    guard activeLease.epoch == epoch, activeLease.expiresAt > now else {
      return false
    }
    if let transferCommit {
      // A commit fences the old origin immediately.  The receiver only becomes
      // writable after its explicit ACK and adopt transition.
      guard activeLease.epoch == transferCommit.leaseEpoch,
        activeLease.holderDeviceID == transferCommit.toDeviceID,
        receiverAcknowledged,
        leaseAdopted
      else {
        return false
      }
      return transferCommit.isOriginAuthority(deviceID: deviceID, epoch: epoch, now: now)
    }
    return activeLease.holderDeviceID == deviceID
  }

  private func persistCommitLocked(
    _ transfer: TatwoHandoffLeaseTransferV1
  ) throws {
    guard let durableConfiguration else { return }
    let slot = TatwoHandoffLeaseCommitSlotV1(
      schema: Self.commitSlotSchema,
      logicalLeaseID: transfer.domainID,
      fromEpoch: transfer.previousEpoch,
      transfer: transfer)
    let url = commitSlotURL(
      rootURL: durableConfiguration.rootURL,
      logicalLeaseID: transfer.domainID,
      fromEpoch: transfer.previousEpoch)
    do {
      try TatwoCreateOnlyFile.write(
        try encodeJSON(slot),
        to: url,
        onDuplicate: {
          throw TatwoHandoffLeaseTransferErrorV1.commitAlreadyExists
        })
      try persistEventLocked(
        .commit,
        lease: activeLease,
        transfer: transfer,
        receiverAcknowledged: receiverAcknowledged)
    } catch {
      durableFault = true
      throw error
    }
  }

  private func persistEventLocked(
    _ event: TatwoHandoffLeaseJournalEventV1,
    lease: TatwoAuthorityLeaseV1,
    transfer: TatwoHandoffLeaseTransferV1?,
    receiverAcknowledged: Bool
  ) throws {
    guard let durableConfiguration else { return }
    do {
      let nextSequence = journalSequence + 1
      let unsigned = TatwoHandoffLeaseJournalUnsignedV1(
        schema: Self.journalSchema,
        sequence: nextSequence,
        event: event,
        logicalLeaseID: lease.domainID,
        epoch: max(lease.epoch, transfer?.leaseEpoch ?? lease.epoch),
        lease: lease,
        transfer: transfer,
        receiverAcknowledged: receiverAcknowledged,
        recordedAt: Date())
      let payload = try encodeJSON(unsigned)
      let authorization = try durableConfiguration.signingTrust.authority.sign(
        payload: payload,
        purpose: Self.journalSignaturePurpose,
        identity: durableConfiguration.signingTrust.localIdentity,
        signedAt: TatwoLoopJobChannelTrust.iso8601(unsigned.recordedAt))
      let entry = TatwoHandoffLeaseJournalEntryV1(
        unsigned: unsigned,
        authorization: authorization)
      let url = journalURL(
        rootURL: durableConfiguration.rootURL,
        logicalLeaseID: lease.domainID)
      try TatwoFileLock.withExclusiveLock(for: url) {
        var data = Data()
        if FileManager.default.fileExists(atPath: url.path) {
          data = try Data(contentsOf: url)
        }
        var line = try encodeJSON(entry)
        line.append(Data("\n".utf8))
        try TatwoAtomicFile.write(data + line, to: url)
      }
      journalSequence = nextSequence
      durableEpochHighWater = max(durableEpochHighWater, unsigned.epoch)
      try storeHighWaterLocked(epoch: durableEpochHighWater)
    } catch {
      durableFault = true
      throw error
    }
  }

  private func storeHighWaterLocked(epoch: UInt64) throws {
    guard let durableConfiguration else { return }
    let value = TatwoFleetAuthorityHighWaterV1(
      authorityEpoch: max(epoch, durableEpochHighWater),
      ledgerSequence: journalSequence,
      // Stable binding: the lease holder changes, but the authority namespace
      // remains the same domain.
      originDeviceID: "handoff-domain:\(activeLease.domainID)",
      updatedAt: Date())
    try durableConfiguration.highWater.storeAuthorityHighWater(value)
  }

  private func restoreDurableState() throws {
    guard let durableConfiguration else { return }
    do {
      let highWater = try durableConfiguration.highWater.loadAuthorityHighWater()
      if let highWater, activeLease.epoch < highWater.authorityEpoch {
        throw TatwoHandoffLeaseTransferErrorV1.staleDurableEpoch(
          current: activeLease.epoch,
          highWater: highWater.authorityEpoch)
      }
      var maxJournalEpoch: UInt64 = 0
      let journal = journalURL(
        rootURL: durableConfiguration.rootURL,
        logicalLeaseID: activeLease.domainID)
      if FileManager.default.fileExists(atPath: journal.path) {
        let raw = try Data(contentsOf: journal)
        let lines = raw.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines {
          let entry: TatwoHandoffLeaseJournalEntryV1
          do {
            entry = try decodeJSON(
              TatwoHandoffLeaseJournalEntryV1.self,
              from: Data(line))
          } catch {
            throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
              "journal entry decode failed")
          }
          let expected = journalSequence + 1
          guard entry.unsigned.schema == Self.journalSchema,
            entry.unsigned.logicalLeaseID == activeLease.domainID,
            entry.unsigned.sequence == expected
          else {
            throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
              "non-contiguous or wrong-domain journal entry")
          }
          guard let pinned = durableConfiguration.signingTrust.pinnedIdentities[
            entry.authorization.deviceID
          ] else {
            throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
              "journal signer is not pinned")
          }
          try TatwoDeviceTrustAuthority.verify(
            payload: encodeJSON(entry.unsigned),
            purpose: Self.journalSignaturePurpose,
            signature: entry.authorization,
            pinnedIdentity: pinned)
          journalSequence = entry.unsigned.sequence
          maxJournalEpoch = max(maxJournalEpoch, entry.unsigned.epoch)
          switch entry.unsigned.event {
          case .initialLease, .pendingTransfer:
            if entry.unsigned.event == .pendingTransfer {
              pendingTransfer = entry.unsigned.transfer
            }
          case .commit:
            if let transfer = entry.unsigned.transfer {
              try verifyDurableCommitSignaturesLocked(transfer)
            }
            transferCommit = entry.unsigned.transfer
            receiverAcknowledged = entry.unsigned.receiverAcknowledged
            leaseAdopted = false
          case .receiverAcknowledged:
            receiverAcknowledged = true
            if transferCommit == nil {
              pendingTransfer = entry.unsigned.transfer
            }
          case .adopt, .reclaim:
            activeLease = entry.unsigned.lease
            if entry.unsigned.event == .adopt {
              receiverAcknowledged = true
              leaseAdopted = true
            } else {
              transferCommit = nil
              pendingTransfer = nil
              receiverAcknowledged = false
              leaseAdopted = true
            }
          }
        }
      } else {
        try persistEventLocked(
          .initialLease,
          lease: activeLease,
          transfer: nil,
          receiverAcknowledged: false)
        maxJournalEpoch = activeLease.epoch
      }

      if transferCommit == nil {
        let slotURL = commitSlotURL(
          rootURL: durableConfiguration.rootURL,
          logicalLeaseID: activeLease.domainID,
          fromEpoch: activeLease.epoch)
        if FileManager.default.fileExists(atPath: slotURL.path) {
          let slot = try decodeJSON(
            TatwoHandoffLeaseCommitSlotV1.self,
            from: Data(contentsOf: slotURL))
          guard slot.schema == Self.commitSlotSchema,
            slot.logicalLeaseID == activeLease.domainID,
            slot.fromEpoch == activeLease.epoch,
            slot.transfer.previousEpoch == activeLease.epoch
          else {
            throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
              "commit slot identity mismatch")
          }
          try verifyDurableCommitSignaturesLocked(slot.transfer)
          transferCommit = slot.transfer
          activeLease = slot.transfer.newLease
          leaseAdopted = false
        }
      }

      if transferCommit != nil, !leaseAdopted {
        activeLease = transferCommit!.newLease
      }

      let durableEpoch = max(
        maxJournalEpoch,
        transferCommit?.leaseEpoch ?? 0,
        highWater?.authorityEpoch ?? 0)
      guard activeLease.epoch >= (highWater?.authorityEpoch ?? 0)
        || transferCommit?.leaseEpoch == highWater?.authorityEpoch
      else {
        throw TatwoHandoffLeaseTransferErrorV1.staleDurableEpoch(
          current: activeLease.epoch,
          highWater: highWater?.authorityEpoch ?? 0)
      }
      durableEpochHighWater = durableEpoch
      if let highWater, highWater.authorityEpoch > maxJournalEpoch,
        transferCommit == nil,
        activeLease.epoch < highWater.authorityEpoch
      {
        throw TatwoHandoffLeaseTransferErrorV1.staleDurableEpoch(
          current: activeLease.epoch,
          highWater: highWater.authorityEpoch)
      }
      if highWater?.authorityEpoch ?? 0 < durableEpoch
        || highWater?.ledgerSequence ?? 0 < journalSequence
      {
        try storeHighWaterLocked(epoch: durableEpoch)
      }
    } catch {
      durableFault = true
      throw error
    }
  }

  private func journalURL(rootURL: URL, logicalLeaseID: String) -> URL {
    rootURL
      .appendingPathComponent("journal", isDirectory: true)
      .appendingPathComponent(
        "\(TatwoLoopPathComponent.sanitize(logicalLeaseID)).jsonl")
  }

  private func verifyDurableCommitSignaturesLocked(
    _ transfer: TatwoHandoffLeaseTransferV1
  ) throws {
    guard let durableConfiguration,
      let originPinned = durableConfiguration.signingTrust.pinnedIdentities[
        transfer.fromDeviceID
      ],
      let receiverPinned = durableConfiguration.signingTrust.pinnedIdentities[
        transfer.toDeviceID
      ]
    else {
      throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
        "commit signer is not pinned")
    }
    let payload = try transfer.canonicalPayloadData()
    do {
      try TatwoDeviceTrustAuthority.verify(
        payload: payload,
        purpose: TatwoHandoffLeaseTransferV1.signaturePurpose,
        signature: transfer.originSignature,
        pinnedIdentity: originPinned)
      try TatwoDeviceTrustAuthority.verify(
        payload: payload,
        purpose: TatwoHandoffLeaseTransferV1.signaturePurpose,
        signature: transfer.receiverSignature,
        pinnedIdentity: receiverPinned)
    } catch {
      throw TatwoHandoffLeaseTransferErrorV1.durableJournalCorrupt(
        "commit signature rejected")
    }
  }

  private func commitSlotURL(
    rootURL: URL,
    logicalLeaseID: String,
    fromEpoch: UInt64
  ) -> URL {
    let key = "\(logicalLeaseID)|\(fromEpoch)"
    let digest = TatwoLoopJobDigest.sha256(Data(key.utf8))
    return rootURL
      .appendingPathComponent("commit-slots", isDirectory: true)
      .appendingPathComponent("\(digest).json")
  }

  private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
}

public typealias TatwoHandoffLeaseTransferStore = TatwoHandoffLeaseTransferStoreV1
