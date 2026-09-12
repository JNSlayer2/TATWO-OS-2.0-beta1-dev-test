import Foundation

// MARK: - Canonical promotion evidence vocabulary

/// Canonical receipt kinds used by the deployment-plane protocol.
///
/// Core's older UI/general-validation `EvidenceKind` does not contain these
/// receipt types and must not be coerced into representing them (for example,
/// a dual-device receipt is not a sandbox run).
public enum TatwoPromotionEvidenceKindV1: String, Codable, Sendable, CaseIterable,
  Equatable
{
  case testSuite = "test-suite"
  case revisionStamp = "revision-stamp"
  case dualDeviceReceipt = "dual-device-receipt"
  case securityScan = "security-scan"
  case snapshot
  case lintLane = "lint-lane"
  case memoryStress = "memory-stress"
  case developerID = "developer-id"
  case notarization
  case signedAppcast = "signed-appcast"
  case vmCleanInstall = "vm-clean-install"
  case vmUpdate = "vm-update"
  case vmMigration = "vm-migration"
  case vmRollback = "vm-rollback"

  /// Protocol-defined release layers in which this receipt kind is valid.
  /// Revision stamps are the sole cross-layer kind because they bind every
  /// gate to the revision under evaluation.
  public var allowedLayers: Set<TatwoPromotionLayerV1> {
    switch self {
    case .revisionStamp:
      return Set(TatwoPromotionLayerV1.allCases)
    case .testSuite, .dualDeviceReceipt, .securityScan, .snapshot, .lintLane,
      .memoryStress:
      return [.sourceCandidate]
    case .developerID, .notarization, .signedAppcast:
      return [.signedBuild]
    case .vmCleanInstall, .vmUpdate, .vmMigration, .vmRollback:
      return [.stableInstaller]
    }
  }
}

// MARK: - Promotion identities and revision binding

public enum IdentityRefKind: String, Codable, Sendable, CaseIterable, Equatable {
  case automated
  case human
}

public struct IdentityRef: Codable, Sendable, Hashable, RawRepresentable,
  ExpressibleByStringLiteral
{
  public let rawValue: String
  public let kind: IdentityRefKind

  public var identityID: String { rawValue }

  public init(rawValue: String) {
    self.init(identityID: rawValue)
  }

  public init(identityID: String, kind: IdentityRefKind = .automated) {
    self.rawValue = identityID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.kind = kind
  }

  public init(stringLiteral value: StringLiteralType) {
    self.init(identityID: value)
  }

  public static func human(_ identityID: String) -> IdentityRef {
    IdentityRef(identityID: identityID, kind: .human)
  }

  /// Authority kind does not create a second identity. Review separation is
  /// keyed only by the normalized identity ID.
  public static func == (lhs: IdentityRef, rhs: IdentityRef) -> Bool {
    lhs.rawValue == rhs.rawValue
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(rawValue)
  }
}

public enum TatwoPromotionRevisionBindingClassV1: String, Codable, Sendable, CaseIterable,
  Equatable
{
  case revisionBound = "revision-bound"
  case baseProvenanceOnly = "base-provenance-only"
}

/// The promotion-facing subset of `TatwoReviewRevisionStampV2`.
///
/// `revisionDigest` is the revision being promoted (normally the commit/tree
/// or an artifact-set digest). Formal gate evidence is accepted only when the
/// stamp schema is V2 and `bindingClass == revision-bound`.
public struct TatwoPromotionRevisionStampV2: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoReviewRevisionStampV2"

  public let schema: String
  public let revisionDigest: String
  public let bindingClass: TatwoPromotionRevisionBindingClassV1

  public init(
    schema: String = TatwoPromotionRevisionStampV2.schemaName,
    revisionDigest: String,
    bindingClass: TatwoPromotionRevisionBindingClassV1
  ) {
    self.schema = schema
    self.revisionDigest = revisionDigest.trimmingCharacters(in: .whitespacesAndNewlines)
    self.bindingClass = bindingClass
  }

  public var isRevisionBound: Bool {
    schema == Self.schemaName
      && bindingClass == .revisionBound
      && !revisionDigest.isEmpty
  }
}

// MARK: - Three release-evidence planes

public enum TatwoPromotionLayerV1: String, Codable, Sendable, CaseIterable, Equatable {
  case sourceCandidate = "source-candidate"
  case signedBuild = "signed-build"
  case stableInstaller = "stable-installer"

  fileprivate var requiredLayerPrefix: [TatwoPromotionLayerV1] {
    switch self {
    case .sourceCandidate:
      return [.sourceCandidate]
    case .signedBuild:
      return [.sourceCandidate, .signedBuild]
    case .stableInstaller:
      return [.sourceCandidate, .signedBuild, .stableInstaller]
    }
  }
}

public struct TatwoPromotionEvidenceV1: Codable, Sendable, Identifiable, Equatable {
  public let evidenceID: String
  public let kind: TatwoPromotionEvidenceKindV1
  public let producer: IdentityRef
  public let revisionStamp: TatwoPromotionRevisionStampV2
  public let layer: TatwoPromotionLayerV1

  public var id: String { evidenceID }

  public init(
    evidenceID: String,
    kind: TatwoPromotionEvidenceKindV1,
    producer: IdentityRef,
    revisionStamp: TatwoPromotionRevisionStampV2,
    layer: TatwoPromotionLayerV1
  ) {
    self.evidenceID = evidenceID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.kind = kind
    self.producer = producer
    self.revisionStamp = revisionStamp
    self.layer = layer
  }
}

// MARK: - Gates and human approval

public enum TatwoPromotionGateKindV1: String, Codable, Sendable, CaseIterable, Equatable {
  case automated
  case review
  case human
}

public enum TatwoPromotionGateVerdictV1: String, Codable, Sendable, CaseIterable, Equatable {
  case pending
  case passed
  case blocked
  case rejected
}

public struct TatwoPromotionGateV1: Codable, Sendable, Identifiable, Equatable {
  public typealias EvidenceKind = TatwoPromotionEvidenceKindV1

  public let gateID: String
  public let kind: TatwoPromotionGateKindV1
  public let requiredEvidence: [EvidenceKind]
  public let performedBy: IdentityRef?
  public let decidedAt: Date?
  public let verdict: TatwoPromotionGateVerdictV1
  public let layer: TatwoPromotionLayerV1

  public var id: String { gateID }

  public init(
    gateID: String,
    kind: TatwoPromotionGateKindV1,
    requiredEvidence: [EvidenceKind],
    performedBy: IdentityRef? = nil,
    decidedAt: Date? = nil,
    verdict: TatwoPromotionGateVerdictV1 = .pending,
    layer: TatwoPromotionLayerV1
  ) {
    self.gateID = gateID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.kind = kind
    self.requiredEvidence = requiredEvidence
    self.performedBy = performedBy
    self.decidedAt = decidedAt
    self.verdict = verdict
    self.layer = layer
  }
}

public struct TatwoHumanPromotionApprovalV1: Codable, Sendable, Equatable {
  public let gateID: String
  public let approver: IdentityRef
  public let approvedAt: Date
  public let approvedRevisionDigest: String

  public init(
    gateID: String,
    approver: IdentityRef,
    approvedAt: Date,
    approvedRevisionDigest: String
  ) {
    self.gateID = gateID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.approver = approver
    self.approvedAt = approvedAt
    self.approvedRevisionDigest =
      approvedRevisionDigest.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Fail-closed evaluation

public enum TatwoPromotionRejectionReasonCodeV1: String, Codable, Sendable, CaseIterable,
  Equatable
{
  case emptyRevision = "empty_revision"
  case emptyGateID = "empty_gate_id"
  case emptyEvidenceID = "empty_evidence_id"
  case invalidIdentityID = "invalid_identity_id"
  case duplicateGateID = "duplicate_gate_id"
  case duplicateEvidenceID = "duplicate_evidence_id"
  case duplicateHumanApproval = "duplicate_human_approval"
  case missingReleaseLayer = "missing_release_layer"
  case gateNotPassed = "gate_not_passed"
  case missingPerformer = "missing_performer"
  case missingDecisionTime = "missing_decision_time"
  case missingRequiredEvidence = "missing_required_evidence"
  case evidenceNotRevisionBound = "evidence_not_revision_bound"
  case evidenceRevisionMismatch = "evidence_revision_mismatch"
  case evidenceLayerMismatch = "evidence_layer_mismatch"
  case invalidEvidenceLayer = "invalid_evidence_layer"
  case producerReviewerIdentityConflict = "producer_reviewer_identity_conflict"
  case humanApprovalRequired = "human_approval_required"
  case humanGateAutomatedSatisfactionAttempt = "human_gate_automated_satisfaction_attempt"
  case humanApproverMismatch = "human_approver_mismatch"
  case humanApprovalRevisionMismatch = "human_approval_revision_mismatch"
  case reviewerHumanIdentityConflict = "reviewer_human_identity_conflict"
  case unexpectedHumanApproval = "unexpected_human_approval"
}

public struct TatwoPromotionRejectionV1: Codable, Sendable, Equatable {
  public let code: TatwoPromotionRejectionReasonCodeV1
  public let gateID: String?
  public let evidenceKind: TatwoPromotionEvidenceKindV1?
  public let evidenceID: String?
  public let releaseLayer: TatwoPromotionLayerV1?

  public init(
    code: TatwoPromotionRejectionReasonCodeV1,
    gateID: String? = nil,
    evidenceKind: TatwoPromotionEvidenceKindV1? = nil,
    evidenceID: String? = nil,
    releaseLayer: TatwoPromotionLayerV1? = nil
  ) {
    self.code = code
    self.gateID = gateID
    self.evidenceKind = evidenceKind
    self.evidenceID = evidenceID
    self.releaseLayer = releaseLayer
  }
}

public struct TatwoPromotionEvaluationV1: Codable, Sendable, Equatable {
  public let verdict: TatwoPromotionGateVerdictV1
  public let reasons: [TatwoPromotionRejectionV1]

  public var passed: Bool { verdict == .passed && reasons.isEmpty }
  public var isPassed: Bool { passed }

  public init(
    verdict: TatwoPromotionGateVerdictV1,
    reasons: [TatwoPromotionRejectionV1]
  ) {
    self.verdict = verdict
    self.reasons = reasons
  }
}

public struct TatwoPromotionChainV1: Codable, Sendable, Equatable {
  public let revisionDigest: String
  public let gates: [TatwoPromotionGateV1]

  public init(revisionDigest: String, gates: [TatwoPromotionGateV1]) {
    self.revisionDigest = revisionDigest.trimmingCharacters(in: .whitespacesAndNewlines)
    self.gates = gates
  }

  public func evaluate(
    evidence: [TatwoPromotionEvidenceV1],
    humanApprovals: [TatwoHumanPromotionApprovalV1] = []
  ) -> TatwoPromotionEvaluationV1 {
    Self.evaluate(
      revisionDigest: revisionDigest,
      gates: gates,
      evidence: evidence,
      humanApprovals: humanApprovals)
  }

  public static func evaluate(
    revisionDigest: String,
    gates: [TatwoPromotionGateV1],
    evidence: [TatwoPromotionEvidenceV1],
    humanApprovals: [TatwoHumanPromotionApprovalV1] = []
  ) -> TatwoPromotionEvaluationV1 {
    let revision = revisionDigest.trimmingCharacters(in: .whitespacesAndNewlines)
    var reasons: [TatwoPromotionRejectionV1] = []

    if revision.isEmpty {
      reasons.append(.init(code: .emptyRevision))
    }

    for gate in gates where normalizedID(gate.gateID).isEmpty {
      reasons.append(.init(code: .emptyGateID, gateID: gate.gateID))
    }

    for item in evidence where normalizedID(item.evidenceID).isEmpty {
      reasons.append(.init(code: .emptyEvidenceID, evidenceID: item.evidenceID))
    }

    for item in evidence where normalizedID(item.producer.identityID).isEmpty {
      reasons.append(
        .init(
          code: .invalidIdentityID,
          evidenceKind: item.kind,
          evidenceID: item.evidenceID))
    }

    for gate in gates {
      if let performer = gate.performedBy, normalizedID(performer.identityID).isEmpty {
        reasons.append(.init(code: .invalidIdentityID, gateID: gate.gateID))
      }
    }

    for approval in humanApprovals
    where normalizedID(approval.approver.identityID).isEmpty
    {
      reasons.append(.init(code: .invalidIdentityID, gateID: approval.gateID))
    }

    let duplicateGateIDs = duplicateValues(gates.map(\.gateID))
    for gateID in duplicateGateIDs {
      reasons.append(.init(code: .duplicateGateID, gateID: gateID))
    }

    let duplicateEvidenceIDs = duplicateValues(evidence.map(\.evidenceID))
    for evidenceID in duplicateEvidenceIDs {
      reasons.append(.init(code: .duplicateEvidenceID, evidenceID: evidenceID))
    }

    for item in evidence where !item.kind.allowedLayers.contains(item.layer) {
      reasons.append(
        .init(
          code: .invalidEvidenceLayer,
          evidenceKind: item.kind,
          evidenceID: item.evidenceID,
          releaseLayer: item.layer))
    }

    if let targetLayer = inferredTargetLayer(gates: gates) {
      let presentLayers = Set(gates.map(\.layer))
      for requiredLayer in targetLayer.requiredLayerPrefix
      where !presentLayers.contains(requiredLayer)
      {
        reasons.append(
          .init(code: .missingReleaseLayer, releaseLayer: requiredLayer))
      }
    } else {
      reasons.append(.init(code: .missingReleaseLayer, releaseLayer: .sourceCandidate))
    }

    let approvalsByGate = Dictionary(grouping: humanApprovals, by: \.gateID)
    for (gateID, approvals) in approvalsByGate where approvals.count > 1 {
      reasons.append(.init(code: .duplicateHumanApproval, gateID: gateID))
    }

    for approval in humanApprovals
    where gates.first(where: { $0.gateID == approval.gateID })?.kind != .human
    {
      reasons.append(.init(code: .unexpectedHumanApproval, gateID: approval.gateID))
    }

    var precedingReviewIdentity: IdentityRef?

    for gate in gates {
      guard gate.verdict == .passed else {
        reasons.append(.init(code: .gateNotPassed, gateID: gate.gateID))
        if gate.kind != .human { precedingReviewIdentity = gate.kind == .review ? gate.performedBy : nil }
        continue
      }

      guard gate.decidedAt != nil else {
        reasons.append(.init(code: .missingDecisionTime, gateID: gate.gateID))
        continue
      }

      switch gate.kind {
      case .automated, .review:
        guard let performer = gate.performedBy else {
          reasons.append(.init(code: .missingPerformer, gateID: gate.gateID))
          continue
        }

        if gate.kind == .review {
          for item in evidence
          where gate.requiredEvidence.contains(item.kind) && item.producer == performer
          {
            reasons.append(
              .init(
                code: .producerReviewerIdentityConflict,
                gateID: gate.gateID,
                evidenceKind: item.kind,
                evidenceID: item.evidenceID))
          }
          precedingReviewIdentity = performer
        } else {
          precedingReviewIdentity = nil
        }

      case .human:
        let approval = approvalsByGate[gate.gateID]?.first
        guard let approval else {
          let code: TatwoPromotionRejectionReasonCodeV1 =
            gate.performedBy == nil
            ? .humanApprovalRequired
            : .humanGateAutomatedSatisfactionAttempt
          reasons.append(.init(code: code, gateID: gate.gateID))
          precedingReviewIdentity = nil
          continue
        }

        guard approval.approver.kind == .human else {
          reasons.append(
            .init(code: .humanGateAutomatedSatisfactionAttempt, gateID: gate.gateID))
          precedingReviewIdentity = nil
          continue
        }

        if let performer = gate.performedBy {
          if performer.kind != .human {
            reasons.append(
              .init(code: .humanGateAutomatedSatisfactionAttempt, gateID: gate.gateID))
          } else if performer != approval.approver {
            reasons.append(.init(code: .humanApproverMismatch, gateID: gate.gateID))
          }
        }
        if approval.approvedRevisionDigest != revision {
          reasons.append(.init(code: .humanApprovalRevisionMismatch, gateID: gate.gateID))
        }
        if precedingReviewIdentity == approval.approver {
          reasons.append(.init(code: .reviewerHumanIdentityConflict, gateID: gate.gateID))
        }
        precedingReviewIdentity = nil
      }

      for requiredKind in gate.requiredEvidence {
        guard requiredKind.allowedLayers.contains(gate.layer) else {
          reasons.append(
            .init(
              code: .evidenceLayerMismatch,
              gateID: gate.gateID,
              evidenceKind: requiredKind,
              releaseLayer: gate.layer))
          continue
        }

        let matchingKind = evidence.filter { $0.kind == requiredKind }
        guard !matchingKind.isEmpty else {
          reasons.append(
            .init(
              code: .missingRequiredEvidence,
              gateID: gate.gateID,
              evidenceKind: requiredKind))
          continue
        }

        let revisionBound = matchingKind.filter(\.revisionStamp.isRevisionBound)
        guard !revisionBound.isEmpty else {
          reasons.append(
            .init(
              code: .evidenceNotRevisionBound,
              gateID: gate.gateID,
              evidenceKind: requiredKind,
              evidenceID: matchingKind.first?.evidenceID))
          continue
        }

        let matchingRevision = revisionBound.filter {
          $0.revisionStamp.revisionDigest == revision
        }
        guard !matchingRevision.isEmpty else {
          reasons.append(
            .init(
              code: .evidenceRevisionMismatch,
              gateID: gate.gateID,
              evidenceKind: requiredKind,
              evidenceID: revisionBound.first?.evidenceID))
          continue
        }

        guard matchingRevision.contains(where: { $0.layer == gate.layer }) else {
          reasons.append(
            .init(
              code: .evidenceLayerMismatch,
              gateID: gate.gateID,
              evidenceKind: requiredKind,
              evidenceID: matchingRevision.first?.evidenceID,
              releaseLayer: gate.layer))
          continue
        }
      }
    }

    return TatwoPromotionEvaluationV1(
      verdict: reasons.isEmpty ? .passed : .blocked,
      reasons: reasons)
  }

  private static func duplicateValues(_ values: [String]) -> [String] {
    Dictionary(grouping: values, by: { $0 })
      .filter { $0.value.count > 1 }
      .map(\.key)
      .sorted()
  }

  private static func normalizedID(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func inferredTargetLayer(
    gates: [TatwoPromotionGateV1]
  ) -> TatwoPromotionLayerV1? {
    if gates.contains(where: { $0.layer == .stableInstaller }) {
      return .stableInstaller
    }
    if gates.contains(where: { $0.layer == .signedBuild }) {
      return .signedBuild
    }
    if gates.contains(where: { $0.layer == .sourceCandidate }) {
      return .sourceCandidate
    }
    return nil
  }
}
