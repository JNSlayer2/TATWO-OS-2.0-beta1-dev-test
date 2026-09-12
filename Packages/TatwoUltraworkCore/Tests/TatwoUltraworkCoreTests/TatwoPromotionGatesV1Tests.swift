import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class TatwoPromotionGatesV1Tests: XCTestCase {
  private let revision = "sha256:ae1-revision"
  private let decidedAt = Date(timeIntervalSince1970: 1_785_283_200)

  private func stamp(
    revision: String? = nil,
    bindingClass: TatwoPromotionRevisionBindingClassV1 = .revisionBound
  ) -> TatwoPromotionRevisionStampV2 {
    TatwoPromotionRevisionStampV2(
      revisionDigest: revision ?? self.revision,
      bindingClass: bindingClass)
  }

  private func evidence(
    _ id: String,
    kind: TatwoPromotionEvidenceKindV1,
    producer: IdentityRef = "builder",
    revision: String? = nil,
    bindingClass: TatwoPromotionRevisionBindingClassV1 = .revisionBound,
    layer: TatwoPromotionLayerV1
  ) -> TatwoPromotionEvidenceV1 {
    TatwoPromotionEvidenceV1(
      evidenceID: id,
      kind: kind,
      producer: producer,
      revisionStamp: stamp(revision: revision, bindingClass: bindingClass),
      layer: layer)
  }

  private func gate(
    _ id: String,
    kind: TatwoPromotionGateKindV1,
    required: [TatwoPromotionGateV1.EvidenceKind],
    performedBy: IdentityRef?,
    layer: TatwoPromotionLayerV1
  ) -> TatwoPromotionGateV1 {
    TatwoPromotionGateV1(
      gateID: id,
      kind: kind,
      requiredEvidence: required,
      performedBy: performedBy,
      decidedAt: decidedAt,
      verdict: .passed,
      layer: layer)
  }

  private func reason(
    _ code: TatwoPromotionRejectionReasonCodeV1,
    in result: TatwoPromotionEvaluationV1
  ) -> TatwoPromotionRejectionV1? {
    result.reasons.first { $0.code == code }
  }

  func testCompletePromotionChainPassesAllThreeEvidenceLayersAndHumanGate() {
    let gates = [
      gate(
        "terra-source",
        kind: .review,
        required: [
          .testSuite, .revisionStamp, .dualDeviceReceipt, .securityScan,
          .snapshot, .lintLane, .memoryStress,
        ],
        performedBy: "terra-reviewer",
        layer: .sourceCandidate),
      gate(
        "luna-signed",
        kind: .review,
        required: [.revisionStamp, .developerID, .notarization, .signedAppcast],
        performedBy: "luna-reviewer",
        layer: .signedBuild),
      gate(
        "fable-direction",
        kind: .review,
        required: [.revisionStamp],
        performedBy: "fable-direction-reviewer",
        layer: .signedBuild),
      gate(
        "final-adversarial",
        kind: .review,
        required: [
          .revisionStamp, .vmCleanInstall, .vmUpdate, .vmMigration, .vmRollback,
        ],
        performedBy: "independent-final-reviewer",
        layer: .stableInstaller),
      gate(
        "H4",
        kind: .human,
        required: [.vmRollback],
        performedBy: .human("release-owner"),
        layer: .stableInstaller)
    ]
    let evidence = [
      evidence("source-tests", kind: .testSuite, layer: .sourceCandidate),
      evidence("source-stamp", kind: .revisionStamp, layer: .sourceCandidate),
      evidence("source-pair", kind: .dualDeviceReceipt, layer: .sourceCandidate),
      evidence("source-security", kind: .securityScan, layer: .sourceCandidate),
      evidence("source-snapshot", kind: .snapshot, layer: .sourceCandidate),
      evidence("source-lint", kind: .lintLane, layer: .sourceCandidate),
      evidence("source-memory", kind: .memoryStress, layer: .sourceCandidate),
      evidence("signed-stamp", kind: .revisionStamp, layer: .signedBuild),
      evidence("developer-id", kind: .developerID, layer: .signedBuild),
      evidence("notarization", kind: .notarization, layer: .signedBuild),
      evidence("signed-appcast", kind: .signedAppcast, layer: .signedBuild),
      evidence("stable-stamp", kind: .revisionStamp, layer: .stableInstaller),
      evidence("vm-clean-install", kind: .vmCleanInstall, layer: .stableInstaller),
      evidence("vm-update", kind: .vmUpdate, layer: .stableInstaller),
      evidence("vm-migration", kind: .vmMigration, layer: .stableInstaller),
      evidence("vm-rollback", kind: .vmRollback, layer: .stableInstaller)
    ]
    let approval = TatwoHumanPromotionApprovalV1(
      gateID: "H4",
      approver: .human("release-owner"),
      approvedAt: decidedAt,
      approvedRevisionDigest: revision)

    let result = TatwoPromotionChainV1(revisionDigest: revision, gates: gates)
      .evaluate(evidence: evidence, humanApprovals: [approval])

    XCTAssertTrue(result.passed)
    XCTAssertEqual(result.verdict, .passed)
    XCTAssertTrue(result.reasons.isEmpty)
  }

  func testRejectsEvidenceProducerReviewingOwnEvidence() throws {
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "terra",
          kind: .review,
          required: [.testSuite],
          performedBy: "same-identity",
          layer: .sourceCandidate)
      ])
      .evaluate(
        evidence: [
          evidence(
            "tests",
            kind: .testSuite,
            producer: IdentityRef(identityID: "same-identity", kind: .automated),
            layer: .sourceCandidate)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.producerReviewerIdentityConflict, in: result))
    XCTAssertEqual(rejection.gateID, "terra")
    XCTAssertEqual(rejection.evidenceID, "tests")
    XCTAssertEqual(rejection.evidenceKind, .testSuite)
  }

  func testRejectsSameIdentityOccupyingAdjacentReviewAndHumanGates() throws {
    let sameReviewer = IdentityRef(identityID: "dual-hat", kind: .automated)
    let sameHuman = IdentityRef.human("dual-hat")
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "fable-review",
          kind: .review,
          required: [.vmRollback],
          performedBy: sameReviewer,
          layer: .stableInstaller),
        gate(
          "H4",
          kind: .human,
          required: [.vmRollback],
          performedBy: sameHuman,
          layer: .stableInstaller)
      ])
      .evaluate(
        evidence: [
          evidence(
            "vm-rollback",
            kind: .vmRollback,
            producer: "independent-builder",
            layer: .stableInstaller)
        ],
        humanApprovals: [
          TatwoHumanPromotionApprovalV1(
            gateID: "H4",
            approver: sameHuman,
            approvedAt: decidedAt,
            approvedRevisionDigest: revision)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.reviewerHumanIdentityConflict, in: result))
    XCTAssertEqual(rejection.gateID, "H4")
  }

  func testRejectsRevisionMismatchedEvidence() throws {
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "terra",
          kind: .review,
          required: [.revisionStamp],
          performedBy: "reviewer",
          layer: .sourceCandidate)
      ])
      .evaluate(
        evidence: [
          evidence(
            "stale-stamp",
            kind: .revisionStamp,
            revision: "sha256:stale-revision",
            layer: .sourceCandidate)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.evidenceRevisionMismatch, in: result))
    XCTAssertEqual(rejection.gateID, "terra")
    XCTAssertEqual(rejection.evidenceID, "stale-stamp")
    XCTAssertEqual(rejection.evidenceKind, .revisionStamp)
  }

  func testRejectsAutomatedAttemptToSatisfyHumanGate() throws {
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "H4",
          kind: .human,
          required: [.vmRollback],
          performedBy: IdentityRef(identityID: "release-bot", kind: .automated),
          layer: .stableInstaller)
      ])
      .evaluate(
        evidence: [
          evidence("vm-rollback", kind: .vmRollback, layer: .stableInstaller)
        ],
        humanApprovals: [
          TatwoHumanPromotionApprovalV1(
            gateID: "H4",
            approver: IdentityRef(identityID: "release-bot", kind: .automated),
            approvedAt: decidedAt,
            approvedRevisionDigest: revision)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.humanGateAutomatedSatisfactionAttempt, in: result))
    XCTAssertEqual(rejection.gateID, "H4")
  }

  func testRejectsLowerLayerDualDeviceReceiptAtSignedBuildGate() throws {
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "signed-build",
          kind: .review,
          required: [.dualDeviceReceipt],
          performedBy: "signed-reviewer",
          layer: .signedBuild)
      ])
      .evaluate(
        evidence: [
          evidence(
            "source-pair",
            kind: .dualDeviceReceipt,
            layer: .sourceCandidate)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.evidenceLayerMismatch, in: result))
    XCTAssertEqual(rejection.gateID, "signed-build")
    XCTAssertNil(rejection.evidenceID)
    XCTAssertEqual(rejection.evidenceKind, .dualDeviceReceipt)
  }

  func testRejectsMissingRequiredEvidence() throws {
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "luna",
          kind: .review,
          required: [.developerID, .notarization],
          performedBy: "luna-reviewer",
          layer: .signedBuild)
      ])
      .evaluate(
        evidence: [
          evidence("developer-id", kind: .developerID, layer: .signedBuild)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.missingRequiredEvidence, in: result))
    XCTAssertEqual(rejection.gateID, "luna")
    XCTAssertEqual(rejection.evidenceKind, .notarization)
    XCTAssertNil(rejection.evidenceID)
  }

  func testRejectsRelabelledDualDeviceReceiptAtSignedLayer() throws {
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "source",
          kind: .review,
          required: [.testSuite],
          performedBy: "source-reviewer",
          layer: .sourceCandidate),
        gate(
          "signed",
          kind: .review,
          required: [.revisionStamp],
          performedBy: "signed-reviewer",
          layer: .signedBuild)
      ])
      .evaluate(
        evidence: [
          evidence("source-tests", kind: .testSuite, layer: .sourceCandidate),
          evidence("signed-stamp", kind: .revisionStamp, layer: .signedBuild),
          evidence(
            "forged-layer",
            kind: .dualDeviceReceipt,
            layer: .signedBuild)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.invalidEvidenceLayer, in: result))
    XCTAssertEqual(rejection.evidenceID, "forged-layer")
    XCTAssertEqual(rejection.evidenceKind, .dualDeviceReceipt)
    XCTAssertEqual(rejection.releaseLayer, .signedBuild)
  }

  func testRejectsNonRevisionBoundAndWrongSchemaStamps() {
    let gates = [
      gate(
        "source",
        kind: .review,
        required: [.testSuite, .revisionStamp],
        performedBy: "reviewer",
        layer: .sourceCandidate)
    ]
    let baseOnly = evidence(
      "base-only",
      kind: .testSuite,
      bindingClass: .baseProvenanceOnly,
      layer: .sourceCandidate)
    let wrongSchema = TatwoPromotionEvidenceV1(
      evidenceID: "wrong-schema",
      kind: .revisionStamp,
      producer: "builder",
      revisionStamp: TatwoPromotionRevisionStampV2(
        schema: "TatwoReviewRevisionStampV1",
        revisionDigest: revision,
        bindingClass: .revisionBound),
      layer: .sourceCandidate)

    let result = TatwoPromotionChainV1(revisionDigest: revision, gates: gates)
      .evaluate(evidence: [baseOnly, wrongSchema])

    XCTAssertEqual(result.verdict, .blocked)
    XCTAssertEqual(
      result.reasons.filter { $0.code == .evidenceNotRevisionBound }.count,
      2)
  }

  func testRejectsBlankHumanApproverIdentity() throws {
    let result = TatwoPromotionChainV1(
      revisionDigest: revision,
      gates: [
        gate(
          "source",
          kind: .review,
          required: [.testSuite],
          performedBy: "source-reviewer",
          layer: .sourceCandidate),
        gate(
          "signed",
          kind: .review,
          required: [.developerID],
          performedBy: "signed-reviewer",
          layer: .signedBuild),
        gate(
          "H4",
          kind: .human,
          required: [.vmRollback],
          performedBy: .human(""),
          layer: .stableInstaller)
      ])
      .evaluate(
        evidence: [
          evidence("source-tests", kind: .testSuite, layer: .sourceCandidate),
          evidence("developer-id", kind: .developerID, layer: .signedBuild),
          evidence("vm-rollback", kind: .vmRollback, layer: .stableInstaller)
        ],
        humanApprovals: [
          TatwoHumanPromotionApprovalV1(
            gateID: "H4",
            approver: .human(""),
            approvedAt: decidedAt,
            approvedRevisionDigest: revision)
        ])

    XCTAssertEqual(result.verdict, .blocked)
    let rejection = try XCTUnwrap(reason(.invalidIdentityID, in: result))
    XCTAssertEqual(rejection.gateID, "H4")
  }
}
