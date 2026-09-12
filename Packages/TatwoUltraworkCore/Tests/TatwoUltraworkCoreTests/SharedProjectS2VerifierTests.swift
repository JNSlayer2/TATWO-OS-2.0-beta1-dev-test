import Foundation
import TatwoDomainContracts
import XCTest
@testable import TatwoUltraworkCore

final class SharedProjectS2VerifierTests: XCTestCase {
  private let projectID = "shared-project-s2"
  private let writerDeviceID = "writer-device"
  private let verifierDeviceID = "verifier-device"
  private let domainID = "domain-s2"

  private func manifest(
    formalHead: TatwoSharedProjectVersionAnchorV1 = .git(
      commit: "commit-head",
      tree: "tree-head")
  ) throws -> TatwoSharedProjectManifestV1 {
    let writer = TatwoProjectWriterLeaseV1(
      projectID: projectID,
      writerDeviceID: writerDeviceID,
      projectEpoch: 1,
      projectFencingToken: "project-token-1",
      since: Date(timeIntervalSince1970: 1_700_000_000))
    return try TatwoSharedProjectManifestV1.build(
      projectID: projectID,
      displayName: "S2 fixture",
      dataKinds: [.gitBacked],
      formalHead: formalHead,
      writer: writer,
      members: [
        TatwoSharedProjectMemberV1(
          deviceID: writerDeviceID,
          role: .writer),
        TatwoSharedProjectMemberV1(
          deviceID: verifierDeviceID,
          role: .verifier)
      ],
      versionFloor: TatwoSharedProjectVersionFloorV1(
        minSchemaVersion: 1,
        minProtocolVersion: 1),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  func testFourVerificationStates() throws {
    let verifier = TatwoSharedProjectVerifierV1(
      verifierDeviceID: verifierDeviceID)

    let gitManifest = try manifest()
    XCTAssertEqual(
      try verifier.verify(
        manifest: gitManifest,
        localState: .git(commit: "commit-head", tree: "tree-head")),
      .inSync)

    let journalManifest = try manifest(
      formalHead: .journal(sequence: 10, digest: "journal-digest-10"))
    XCTAssertEqual(
      try verifier.verify(
        manifest: journalManifest,
        localState: .journal(sequence: 7, digest: "journal-digest-10")),
      .behind(delta: 3))
    XCTAssertEqual(
      try verifier.verify(
        manifest: journalManifest,
        localState: .journal(sequence: 12, digest: "journal-digest-12")),
      .ahead(unexpected: 2))

    XCTAssertEqual(
      try verifier.verify(
        manifest: gitManifest,
        localState: .gitDivergent(
          commit: "other-commit",
          tree: "other-tree")),
      .divergent)
  }

  func testGitHistoryRelationshipIsInjectedRatherThanGuessed() throws {
    let verifier = TatwoSharedProjectVerifierV1(
      verifierDeviceID: verifierDeviceID)
    let fixture = try manifest()

    XCTAssertEqual(
      try verifier.verify(
        manifest: fixture,
        localState: .gitBehind(
          commit: "ancestor-commit",
          tree: "ancestor-tree",
          delta: 4)),
      .behind(delta: 4))
    XCTAssertEqual(
      try verifier.verify(
        manifest: fixture,
        localState: .gitAhead(
          commit: "local-commit",
          tree: "local-tree",
          unexpected: 2)),
      .ahead(unexpected: 2))

    // Opaque hashes with no injected ancestry are fail-closed.
    XCTAssertEqual(
      try verifier.verify(
        manifest: fixture,
        localState: .git(
          commit: "unknown-commit",
          tree: "unknown-tree")),
      .divergent)
  }

  func testManifestMissingFailsClosed() {
    let verifier = TatwoSharedProjectVerifierV1(
      verifierDeviceID: verifierDeviceID)
    XCTAssertThrowsError(
      try verifier.verify(
        manifest: nil,
        localState: .journal(sequence: 1))
    ) { error in
      XCTAssertEqual(
        error as? TatwoSharedProjectErrorV1,
        .missingManifest)
    }
    XCTAssertThrowsError(
      try verifier.verify(
        manifestData: nil,
        localState: .journal(sequence: 1))
    ) { error in
      XCTAssertEqual(
        error as? TatwoSharedProjectErrorV1,
        .missingManifest)
    }
  }

  func testVerifierResultDoesNotBecomeWriteAuthority() throws {
    let fixture = try manifest(
      formalHead: .journal(sequence: 10, digest: "journal-digest-10"))
    let verifier = TatwoSharedProjectVerifierV1(
      verifierDeviceID: verifierDeviceID)
    XCTAssertEqual(
      try verifier.verify(
        manifest: fixture,
        localState: .journal(sequence: 9, digest: "journal-digest-10")),
      .behind(delta: 1))

    let provider = S2AllowingAuthorityProvider(
      domainID: domainID,
      epoch: 1)
    let registry = TatwoProjectWriterRegistryV1(
      domainID: domainID,
      originAuthorityProvider: provider)
    let fence = TatwoDomainFenceBindingV1(
      domainID: domainID,
      holderDeviceID: writerDeviceID,
      leaseEpoch: 1,
      fencingToken: "domain-token-1")
    try registry.bindDomainFence(fence)
    try registry.commitWriterLease(fixture.writer, domainFence: fence)

    // The verifier's behind result does not change the independent S1 write
    // decision for the canonical writer.
    XCTAssertEqual(
      registry.localWriteEligibility(
        manifest: fixture,
        localDeviceID: writerDeviceID),
      .formal)
    XCTAssertEqual(
      registry.localWriteEligibility(
        manifest: fixture,
        localDeviceID: verifierDeviceID),
      .denied(.formalWriteDenied("verifier is read-only")))
    XCTAssertEqual(
      verifier.denyFormalWrite(),
      .formalWriteDenied("verifier mount is read-only (S2)"))
    XCTAssertEqual(verifier.role, .verifier)
  }

  func testDigestMismatchIsDivergentEvenWhenJournalSequenceMatches() throws {
    let fixture = try manifest(
      formalHead: .journal(sequence: 10, digest: "formal-digest"))
    let verifier = TatwoSharedProjectVerifierV1(
      verifierDeviceID: verifierDeviceID)
    XCTAssertEqual(
      try verifier.verify(
        manifest: fixture,
        localState: .journal(sequence: 10, digest: "local-digest")),
      .divergent)
  }
}

private final class S2AllowingAuthorityProvider:
  TatwoOriginAuthorityProviding,
  @unchecked Sendable
{
  let authorityDomainID: String?
  let authorityEpoch: UInt64?

  init(domainID: String, epoch: UInt64) {
    authorityDomainID = domainID
    authorityEpoch = epoch
  }

  func isOriginAuthority(
    deviceID: String,
    epoch: UInt64,
    now: Date
  ) -> Bool {
    epoch == authorityEpoch
  }
}
