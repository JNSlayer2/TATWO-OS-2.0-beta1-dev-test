import Foundation

// MARK: - Shared Project S2 (read-only verifier)
//
// This file deliberately contains no writer lease, registry, or mutation
// surface.  The verifier consumes the S1 manifest and an injected local
// observation only.  Write eligibility remains the independent S1
// `TatwoProjectWriterRegistryV1.localWriteEligibility` decision.

/// A git observation needs an injected relationship when the two commit IDs
/// are not equal.  The verifier never shells out to git and never guesses a
/// history relationship from opaque hashes.
public enum TatwoSharedProjectGitLocalRelationshipV1: Sendable, Equatable {
  case unknown
  case behind(delta: UInt64)
  case ahead(unexpected: UInt64)
  case divergent
}

/// Immutable local observation supplied by a caller-owned read-only adapter.
///
/// `gitRelationship` is used only for git observations whose commit differs
/// from the manifest head.  Journal observations are ordered by sequence and
/// therefore need no external graph.
public struct TatwoSharedProjectLocalStateV1: Sendable, Equatable {
  public let anchor: TatwoSharedProjectVersionAnchorV1
  public let gitRelationship: TatwoSharedProjectGitLocalRelationshipV1

  public init(
    anchor: TatwoSharedProjectVersionAnchorV1,
    gitRelationship: TatwoSharedProjectGitLocalRelationshipV1 = .unknown
  ) {
    self.anchor = anchor
    self.gitRelationship = gitRelationship
  }

  public static func git(
    commit: String,
    tree: String? = nil,
    relationship: TatwoSharedProjectGitLocalRelationshipV1 = .unknown
  ) -> Self {
    Self(
      anchor: .git(commit: commit, tree: tree),
      gitRelationship: relationship)
  }

  /// Label-compatible spelling for callers that use `relation`.
  public static func git(
    commit: String,
    tree: String? = nil,
    relation: TatwoSharedProjectGitLocalRelationshipV1
  ) -> Self {
    git(commit: commit, tree: tree, relationship: relation)
  }

  public static func gitBehind(
    commit: String,
    tree: String? = nil,
    delta: UInt64 = 1
  ) -> Self {
    git(
      commit: commit,
      tree: tree,
      relationship: .behind(delta: delta))
  }

  public static func gitAhead(
    commit: String,
    tree: String? = nil,
    unexpected: UInt64 = 1
  ) -> Self {
    git(
      commit: commit,
      tree: tree,
      relationship: .ahead(unexpected: unexpected))
  }

  public static func gitDivergent(
    commit: String,
    tree: String? = nil
  ) -> Self {
    git(commit: commit, tree: tree, relationship: .divergent)
  }

  public static func journal(
    sequence: UInt64,
    digest: String? = nil
  ) -> Self {
    Self(anchor: .journal(sequence: sequence, digest: digest))
  }
}

/// Read-only verifier outcome.  `behind` and `ahead` carry a positive
/// distance; `ahead` is explicitly labelled unexpected because local work
/// beyond the formal writer head is not shared truth.
public enum TatwoSharedProjectVerifierResultV1: Sendable, Equatable {
  case inSync
  case behind(delta: UInt64)
  case ahead(unexpected: UInt64)
  case divergent

  public var statusLabel: String {
    switch self {
    case .inSync:
      return "inSync"
    case .behind:
      return "behind"
    case .ahead:
      return "ahead"
    case .divergent:
      return "divergent"
    }
  }
}

/// Compatibility spelling for callers that use “verification” rather than
/// “verifier” in their result type.
public typealias TatwoSharedProjectVerificationResultV1 =
  TatwoSharedProjectVerifierResultV1
public typealias TatwoSharedProjectVerifierStatusV1 =
  TatwoSharedProjectVerifierResultV1
public typealias TatwoSharedProjectVerifierLocalStateV1 =
  TatwoSharedProjectLocalStateV1

/// An immutable mounted view.  It carries only observations; it cannot
/// acquire a writer lease or mutate a registry/shared project.
public struct TatwoSharedProjectVerifierMountV1: Sendable, Equatable {
  public static let schemaName = "TatwoSharedProjectVerifierMountV1"

  public let schema: String
  public let projectID: String
  public let verifierDeviceID: String?
  public let formalHead: TatwoSharedProjectVersionAnchorV1
  public let localState: TatwoSharedProjectLocalStateV1
  public let result: TatwoSharedProjectVerifierResultV1

  fileprivate init(
    projectID: String,
    verifierDeviceID: String?,
    formalHead: TatwoSharedProjectVersionAnchorV1,
    localState: TatwoSharedProjectLocalStateV1,
    result: TatwoSharedProjectVerifierResultV1
  ) {
    self.schema = Self.schemaName
    self.projectID = projectID
    self.verifierDeviceID = verifierDeviceID
    self.formalHead = formalHead
    self.localState = localState
    self.result = result
  }
}

/// S2 read-only verifier.
///
/// The type intentionally has no reference to `TatwoProjectWriterLeaseV1`,
/// `TatwoProjectWriterRegistryV1`, or any mutating operation.  Its optional
/// device ID is used only to confirm that a mounted device is listed as a
/// verifier member; it is not an authority claim.
public struct TatwoSharedProjectVerifierV1: Sendable {
  public static let role = TatwoSharedProjectMemberRoleV1.verifier

  public let verifierDeviceID: String?

  public init(verifierDeviceID: String? = nil) {
    self.verifierDeviceID = verifierDeviceID
  }

  public init(deviceID: String) {
    self.init(verifierDeviceID: deviceID)
  }

  public var deviceID: String? { verifierDeviceID }

  /// Verify an already decoded S1 manifest and injected local observation.
  /// Missing or malformed manifest data throws instead of manufacturing a
  /// status, so callers cannot mistake a connection for `inSync`.
  public func verify(
    manifest: TatwoSharedProjectManifestV1?,
    localState: TatwoSharedProjectLocalStateV1
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    guard let manifest else {
      throw TatwoSharedProjectErrorV1.missingManifest
    }
    try manifest.validateRequiredFields()
    try requireVerifierMembershipIfBound(to: manifest)
    try validateLocalState(localState)
    return compare(formal: manifest.formalHead, local: localState)
  }

  /// Verify a manifest payload without granting the caller any write access.
  public func verify(
    manifestData: Data?,
    localState: TatwoSharedProjectLocalStateV1
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    let manifest = try TatwoSharedProjectManifestLoaderV1.loadOptional(data: manifestData)
    return try verify(manifest: manifest, localState: localState)
  }

  /// Convenience injection for git-backed callers that already have the
  /// commit/tree observation in separate fields.
  public func verify(
    manifest: TatwoSharedProjectManifestV1?,
    localCommit: String,
    localTree: String? = nil,
    relationship: TatwoSharedProjectGitLocalRelationshipV1 = .unknown
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    try verify(
      manifest: manifest,
      localState: .git(
        commit: localCommit,
        tree: localTree,
        relationship: relationship))
  }

  /// Convenience injection for journal-backed callers.
  public func verify(
    manifest: TatwoSharedProjectManifestV1?,
    localJournalSequence: UInt64,
    localJournalDigest: String? = nil
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    try verify(
      manifest: manifest,
      localState: .journal(
        sequence: localJournalSequence,
        digest: localJournalDigest))
  }

  /// Produce an immutable mount receipt/view for UI or state-receipt
  /// consumers.  This does not persist anything.
  public func mount(
    manifest: TatwoSharedProjectManifestV1?,
    localState: TatwoSharedProjectLocalStateV1
  ) throws -> TatwoSharedProjectVerifierMountV1 {
    guard let manifest else {
      throw TatwoSharedProjectErrorV1.missingManifest
    }
    let result = try verify(manifest: manifest, localState: localState)
    return TatwoSharedProjectVerifierMountV1(
      projectID: manifest.projectID,
      verifierDeviceID: verifierDeviceID,
      formalHead: manifest.formalHead,
      localState: localState,
      result: result)
  }

  /// Fixed read-only role marker for callers that need to project the S2
  /// surface.  This is not a write API.
  public var role: TatwoSharedProjectMemberRoleV1 { Self.role }

  /// Fail-closed response for an attempted formal write through a verifier
  /// surface.  Actual write eligibility remains owned by S1's registry.
  public func denyFormalWrite() -> TatwoSharedProjectErrorV1 {
    TatwoSharedProjectVerifierSeamV1.denyFormalWrite()
  }

  public static func verify(
    manifest: TatwoSharedProjectManifestV1?,
    localState: TatwoSharedProjectLocalStateV1
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    try Self().verify(manifest: manifest, localState: localState)
  }

  public static func verify(
    manifestData: Data?,
    localState: TatwoSharedProjectLocalStateV1
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    try Self().verify(manifestData: manifestData, localState: localState)
  }

  public static func verify(
    manifest: TatwoSharedProjectManifestV1?,
    localCommit: String,
    localTree: String? = nil,
    relationship: TatwoSharedProjectGitLocalRelationshipV1 = .unknown
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    try Self().verify(
      manifest: manifest,
      localCommit: localCommit,
      localTree: localTree,
      relationship: relationship)
  }

  public static func verify(
    manifest: TatwoSharedProjectManifestV1?,
    localJournalSequence: UInt64,
    localJournalDigest: String? = nil
  ) throws -> TatwoSharedProjectVerifierResultV1 {
    try Self().verify(
      manifest: manifest,
      localJournalSequence: localJournalSequence,
      localJournalDigest: localJournalDigest)
  }

  // MARK: Private read-only comparison helpers

  private func requireVerifierMembershipIfBound(
    to manifest: TatwoSharedProjectManifestV1
  ) throws {
    guard let verifierDeviceID else { return }
    guard manifest.members.contains(where: {
      $0.deviceID == verifierDeviceID && $0.role == Self.role
    }) else {
      throw TatwoSharedProjectErrorV1.formalWriteDenied(
        "device is not registered as a verifier")
    }
  }

  private func validateLocalState(
    _ localState: TatwoSharedProjectLocalStateV1
  ) throws {
    guard localState.anchor.isWellFormed else {
      throw TatwoSharedProjectErrorV1.corruptManifest(
        "local verifier state has an invalid version anchor")
    }
    switch localState.gitRelationship {
    case .behind(let delta):
      guard delta > 0 else {
        throw TatwoSharedProjectErrorV1.corruptManifest(
          "git behind delta must be positive")
      }
    case .ahead(let unexpected):
      guard unexpected > 0 else {
        throw TatwoSharedProjectErrorV1.corruptManifest(
          "git ahead unexpected delta must be positive")
      }
    case .unknown, .divergent:
      break
    }
  }

  private func compare(
    formal: TatwoSharedProjectVersionAnchorV1,
    local: TatwoSharedProjectLocalStateV1
  ) -> TatwoSharedProjectVerifierResultV1 {
    switch (formal, local.anchor) {
    case let (.git(formalCommit, formalTree), .git(localCommit, localTree)):
      if formalCommit == localCommit {
        // A nil formal tree means the manifest intentionally anchors only the
        // commit.  If a tree is declared, it must round-trip exactly.
        if formalTree == nil || formalTree == localTree {
          return .inSync
        }
        return .divergent
      }

      switch local.gitRelationship {
      case .behind(let delta):
        return .behind(delta: delta)
      case .ahead(let unexpected):
        return .ahead(unexpected: unexpected)
      case .divergent, .unknown:
        // Opaque commit IDs alone cannot prove ancestry.  Fail closed rather
        // than guessing which side is newer.
        return .divergent
      }

    case let (.journal(formalSequence, formalDigest), .journal(localSequence, localDigest)):
      if localSequence == formalSequence {
        if let formalDigest, let localDigest, formalDigest != localDigest {
          return .divergent
        }
        return .inSync
      }
      if localSequence < formalSequence {
        return .behind(delta: formalSequence - localSequence)
      }
      return .ahead(unexpected: localSequence - formalSequence)

    case (.git, .journal), (.journal, .git):
      return .divergent
    }
  }
}
