import Foundation

// MARK: - Offline copy merge (Shared Project S3 / K3 + L2a)

/// One provisional path mutation produced by an offline/online replica.
///
/// The digest is intentionally opaque to Core.  A caller-owned adapter may use
/// `sha256:<hex>`, a journal digest, or another content-addressed form; Core
/// only requires that a non-empty digest is present and never computes it by
/// reading the workspace.
public struct TatwoOfflineCopyProvisionalChangeV1: Codable, Sendable, Equatable {
  public let path: String
  public let sha256: String

  public init(path: String, sha256: String) {
    self.path = path
    self.sha256 = sha256
  }
}

/// Immutable observation of a replica.  `provisional` remains true until the
/// canonical writer applies a fast-forward plan and promotes a new head.
public struct TatwoOfflineCopyStateV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoOfflineCopyStateV1"

  public let schema: String
  public let replicaID: String
  public let deviceID: String
  public let baseVersionAnchor: TatwoSharedProjectVersionAnchorV1
  public let provisionalChanges: [TatwoOfflineCopyProvisionalChangeV1]
  public let state: TatwoOfflineCopyProvisionalStateV1
  public let provisional: Bool

  public init(
    schema: String = TatwoOfflineCopyStateV1.schemaName,
    replicaID: String,
    deviceID: String,
    baseVersionAnchor: TatwoSharedProjectVersionAnchorV1,
    provisionalChanges: [TatwoOfflineCopyProvisionalChangeV1],
    state: TatwoOfflineCopyProvisionalStateV1 = .provisionalDirty,
    provisional: Bool = true
  ) {
    self.schema = schema
    self.replicaID = replicaID
    self.deviceID = deviceID
    self.baseVersionAnchor = baseVersionAnchor
    self.provisionalChanges = provisionalChanges
    self.state = state
    self.provisional = provisional
  }

  /// Compatibility spelling used by callers that call the list `changes`.
  public var changes: [TatwoOfflineCopyProvisionalChangeV1] {
    provisionalChanges
  }

  public func validate() throws {
    guard schema == Self.schemaName else {
      throw TatwoOfflineCopyMergeErrorV1.invalidReplica("schema \(schema)")
    }
    guard !replicaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TatwoOfflineCopyMergeErrorV1.invalidReplica("empty replicaID")
    }
    guard TatwoLoopPathComponent.isValid(deviceID) else {
      throw TatwoOfflineCopyMergeErrorV1.invalidReplica("invalid deviceID \(deviceID)")
    }
    guard baseVersionAnchor.isWellFormed else {
      throw TatwoOfflineCopyMergeErrorV1.invalidReplica("invalid base version anchor")
    }
    guard provisional, TatwoOfflineCopyStateV1.isProvisionalState(state) else {
      throw TatwoOfflineCopyMergeErrorV1.invalidReplica(
        "offline copy must remain provisional until writer apply")
    }
    guard !provisionalChanges.isEmpty else {
      throw TatwoOfflineCopyMergeErrorV1.invalidReplica("no provisional changes")
    }

    var seen = Set<String>()
    for change in provisionalChanges {
      let path = change.path.trimmingCharacters(in: .whitespacesAndNewlines)
      let digest = change.sha256.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"),
        path != ".", path != "..", !path.contains("../"), !path.contains("..\\"),
        !digest.isEmpty
      else {
        throw TatwoOfflineCopyMergeErrorV1.invalidReplica(
          "invalid provisional change \(change.path)")
      }
      guard seen.insert(path).inserted else {
        throw TatwoOfflineCopyMergeErrorV1.invalidReplica(
          "duplicate provisional path \(path)")
      }
    }
  }

  private static func isProvisionalState(
    _ state: TatwoOfflineCopyProvisionalStateV1
  ) -> Bool {
    TatwoOfflineCopyStateMachineV1.isProvisional(state)
  }
}

/// Canonical head observation supplied by a read-only adapter.  Git changed
/// paths are optional evidence; Core never shells out to git.
public struct TatwoOfflineCopyCanonicalHeadV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoOfflineCopyCanonicalHeadV1"

  public let schema: String
  public let anchor: TatwoSharedProjectVersionAnchorV1
  public let changedPaths: [String]

  public init(
    schema: String = TatwoOfflineCopyCanonicalHeadV1.schemaName,
    anchor: TatwoSharedProjectVersionAnchorV1,
    changedPaths: [String] = []
  ) {
    self.schema = schema
    self.anchor = anchor
    self.changedPaths = Array(Set(changedPaths)).sorted()
  }

  /// Label-compatible spelling for callers that use `currentCanonicalHead`.
  public var currentCanonicalHead: TatwoSharedProjectVersionAnchorV1 {
    anchor
  }
}

public enum TatwoOfflineCopyMergeDecisionV1: Codable, Sendable, Equatable {
  case fastForward
  case needsRebase
  case conflict(paths: [String])
  case rejected(reason: String)

  private enum CodingKeys: String, CodingKey {
    case kind
    case paths
    case reason
  }

  private enum Kind: String, Codable {
    case fastForward
    case needsRebase
    case conflict
    case rejected
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .fastForward:
      try container.encode(Kind.fastForward, forKey: .kind)
    case .needsRebase:
      try container.encode(Kind.needsRebase, forKey: .kind)
    case let .conflict(paths):
      try container.encode(Kind.conflict, forKey: .kind)
      try container.encode(paths, forKey: .paths)
    case let .rejected(reason):
      try container.encode(Kind.rejected, forKey: .kind)
      try container.encode(reason, forKey: .reason)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .fastForward:
      self = .fastForward
    case .needsRebase:
      self = .needsRebase
    case .conflict:
      self = .conflict(
        paths: try container.decodeIfPresent([String].self, forKey: .paths) ?? [])
    case .rejected:
      self = .rejected(
        reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "rejected")
    }
  }

  public var statusLabel: String {
    switch self {
    case .fastForward: return "fastForward"
    case .needsRebase: return "needsRebase"
    case .conflict: return "conflict"
    case .rejected: return "rejected"
    }
  }

  public var conflictPaths: [String] {
    if case let .conflict(paths) = self { return paths }
    return []
  }

  public var rejectedReason: String? {
    if case let .rejected(reason) = self { return reason }
    return nil
  }
}

/// Git-backed output is a command *plan*, never a git execution request.
public struct TatwoOfflineCopyGitMergeInstructionV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoOfflineCopyGitMergeInstructionV1"

  public let schema: String
  public let wipBranch: String
  public let pushCommand: String
  public let writerMergeCommand: String
  public let requiresCanonicalWriter: Bool

  public init(
    schema: String = TatwoOfflineCopyGitMergeInstructionV1.schemaName,
    wipBranch: String,
    pushCommand: String,
    writerMergeCommand: String,
    requiresCanonicalWriter: Bool = true
  ) {
    self.schema = schema
    self.wipBranch = wipBranch
    self.pushCommand = pushCommand
    self.writerMergeCommand = writerMergeCommand
    self.requiresCanonicalWriter = requiresCanonicalWriter
  }
}

/// Pure merge plan.  `applicableBy` is always the manifest's current writer;
/// a replica/verifier may inspect the plan but cannot apply it.
public struct TatwoOfflineCopyMergePlanV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoOfflineCopyMergePlanV1"

  public let schema: String
  public let projectID: String
  public let replicaID: String
  public let sourceDeviceID: String
  public let baseVersionAnchor: TatwoSharedProjectVersionAnchorV1
  public let canonicalHead: TatwoOfflineCopyCanonicalHeadV1
  public let decision: TatwoOfflineCopyMergeDecisionV1
  public let applicableBy: String
  /// Always true in a plan.  It becomes false only in the application result.
  public let provisional: Bool
  public let gitInstruction: TatwoOfflineCopyGitMergeInstructionV1?

  public init(
    schema: String = TatwoOfflineCopyMergePlanV1.schemaName,
    projectID: String,
    replicaID: String,
    sourceDeviceID: String,
    baseVersionAnchor: TatwoSharedProjectVersionAnchorV1,
    canonicalHead: TatwoOfflineCopyCanonicalHeadV1,
    decision: TatwoOfflineCopyMergeDecisionV1,
    applicableBy: String,
    provisional: Bool = true,
    gitInstruction: TatwoOfflineCopyGitMergeInstructionV1? = nil
  ) {
    self.schema = schema
    self.projectID = projectID
    self.replicaID = replicaID
    self.sourceDeviceID = sourceDeviceID
    self.baseVersionAnchor = baseVersionAnchor
    self.canonicalHead = canonicalHead
    self.decision = decision
    self.applicableBy = applicableBy
    self.provisional = provisional
    self.gitInstruction = gitInstruction
  }

  public var outcome: TatwoOfflineCopyMergeDecisionV1 {
    decision
  }

  public var status: TatwoOfflineCopyMergeDecisionV1 {
    decision
  }

  public func apply(
    manifest: TatwoSharedProjectManifestV1,
    byDeviceID: String,
    promotedVersionAnchor: TatwoSharedProjectVersionAnchorV1
  ) throws -> TatwoOfflineCopyMergeApplicationV1 {
    try TatwoOfflineCopyMergeV1.apply(
      plan: self,
      manifest: manifest,
      byDeviceID: byDeviceID,
      promotedVersionAnchor: promotedVersionAnchor)
  }
}

public struct TatwoOfflineCopyMergeApplicationV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoOfflineCopyMergeApplicationV1"

  public let schema: String
  public let projectID: String
  public let replicaID: String
  public let appliedBy: String
  public let previousCanonicalHead: TatwoSharedProjectVersionAnchorV1
  public let promotedCanonicalHead: TatwoSharedProjectVersionAnchorV1
  public let provisional: Bool
  public let replicaState: TatwoOfflineCopyProvisionalStateV1

  public init(
    schema: String = TatwoOfflineCopyMergeApplicationV1.schemaName,
    projectID: String,
    replicaID: String,
    appliedBy: String,
    previousCanonicalHead: TatwoSharedProjectVersionAnchorV1,
    promotedCanonicalHead: TatwoSharedProjectVersionAnchorV1,
    provisional: Bool = false,
    replicaState: TatwoOfflineCopyProvisionalStateV1 = .cleanMirror
  ) {
    self.schema = schema
    self.projectID = projectID
    self.replicaID = replicaID
    self.appliedBy = appliedBy
    self.previousCanonicalHead = previousCanonicalHead
    self.promotedCanonicalHead = promotedCanonicalHead
    self.provisional = provisional
    self.replicaState = replicaState
  }
}

public enum TatwoOfflineCopyMergeErrorV1: Error, LocalizedError, Sendable, Equatable {
  case invalidManifest(String)
  case invalidReplica(String)
  case invalidCanonicalHead(String)
  case replicaNotRegistered(String)
  case notCanonicalWriter(expected: String, actual: String)
  case planMismatch(String)
  case planNotApplicable(String)
  case promotionDidNotAdvance

  public var errorDescription: String? {
    switch self {
    case let .invalidManifest(detail):
      return "offline merge manifest invalid: \(detail)"
    case let .invalidReplica(detail):
      return "offline replica invalid: \(detail)"
    case let .invalidCanonicalHead(detail):
      return "offline merge canonical head invalid: \(detail)"
    case let .replicaNotRegistered(deviceID):
      return "offline replica is not registered: \(deviceID)"
    case let .notCanonicalWriter(expected, actual):
      return "offline merge requires canonical writer \(expected), got \(actual)"
    case let .planMismatch(detail):
      return "offline merge plan mismatch: \(detail)"
    case let .planNotApplicable(detail):
      return "offline merge plan is not applicable: \(detail)"
    case .promotionDidNotAdvance:
      return "offline merge promotion must advance the canonical version anchor"
    }
  }
}

/// S3 merge planner/application seam.  It is deliberately pure: no file,
/// network, or git process is started by any method here.
public enum TatwoOfflineCopyMergeV1 {
  public static func plan(
    manifest: TatwoSharedProjectManifestV1,
    replica: TatwoOfflineCopyStateV1,
    canonicalHead: TatwoOfflineCopyCanonicalHeadV1
  ) -> TatwoOfflineCopyMergePlanV1 {
    let writer = manifest.writer.writerDeviceID
    do {
      try manifest.validateRequiredFields()
    } catch {
      return rejectedPlan(
        manifest: manifest,
        replica: replica,
        canonicalHead: canonicalHead,
        writer: writer,
        reason: "manifest: \(error.localizedDescription)")
    }
    do {
      try replica.validate()
    } catch {
      return rejectedPlan(
        manifest: manifest,
        replica: replica,
        canonicalHead: canonicalHead,
        writer: writer,
        reason: "replica: \(error.localizedDescription)")
    }
    guard canonicalHead.schema == TatwoOfflineCopyCanonicalHeadV1.schemaName,
      canonicalHead.anchor.isWellFormed
    else {
      return rejectedPlan(
        manifest: manifest,
        replica: replica,
        canonicalHead: canonicalHead,
        writer: writer,
        reason: "canonical head is malformed")
    }
    guard manifest.members.contains(where: {
      $0.deviceID == replica.deviceID && $0.role == .offlineCopy
    }) else {
      return rejectedPlan(
        manifest: manifest,
        replica: replica,
        canonicalHead: canonicalHead,
        writer: writer,
        reason: TatwoOfflineCopyMergeErrorV1.replicaNotRegistered(replica.deviceID)
          .localizedDescription)
    }
    guard sameAnchorKind(replica.baseVersionAnchor, canonicalHead.anchor) else {
      return rejectedPlan(
        manifest: manifest,
        replica: replica,
        canonicalHead: canonicalHead,
        writer: writer,
        reason: "base and canonical head use different channels")
    }

    let decision: TatwoOfflineCopyMergeDecisionV1
    switch compare(base: replica.baseVersionAnchor, current: canonicalHead.anchor) {
    case .equal:
      decision = .fastForward
    case .canonicalAhead:
      let canonicalPaths = Set(
        canonicalHead.changedPaths.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
      let provisionalPaths = Set(
        replica.provisionalChanges.map {
          $0.path.trimmingCharacters(in: .whitespacesAndNewlines)
        })
      let paths = canonicalPaths.intersection(provisionalPaths)
      decision = paths.isEmpty ? .needsRebase : .conflict(paths: paths.sorted())
    case .canonicalBehind:
      decision = .rejected(reason: "canonical head is behind replica base")
    case .incomparable:
      decision = .rejected(reason: "base and canonical head are not comparable")
    }

    return TatwoOfflineCopyMergePlanV1(
      projectID: manifest.projectID,
      replicaID: replica.replicaID,
      sourceDeviceID: replica.deviceID,
      baseVersionAnchor: replica.baseVersionAnchor,
      canonicalHead: canonicalHead,
      decision: decision,
      applicableBy: writer,
      provisional: true,
      gitInstruction: gitInstruction(
        manifest: manifest,
        replica: replica,
        decision: decision))
  }

  /// Convenience overload for callers that have an anchor and path evidence
  /// separately.  No git relationship is inferred here.
  public static func plan(
    manifest: TatwoSharedProjectManifestV1,
    replica: TatwoOfflineCopyStateV1,
    currentCanonicalHead: TatwoSharedProjectVersionAnchorV1,
    canonicalChangedPaths: [String] = []
  ) -> TatwoOfflineCopyMergePlanV1 {
    plan(
      manifest: manifest,
      replica: replica,
      canonicalHead: TatwoOfflineCopyCanonicalHeadV1(
        anchor: currentCanonicalHead,
        changedPaths: canonicalChangedPaths))
  }

  public static func apply(
    plan: TatwoOfflineCopyMergePlanV1,
    manifest: TatwoSharedProjectManifestV1,
    byDeviceID: String,
    promotedVersionAnchor: TatwoSharedProjectVersionAnchorV1
  ) throws -> TatwoOfflineCopyMergeApplicationV1 {
    try manifest.validateRequiredFields()
    guard byDeviceID == manifest.writer.writerDeviceID,
      byDeviceID == plan.applicableBy
    else {
      throw TatwoOfflineCopyMergeErrorV1.notCanonicalWriter(
        expected: manifest.writer.writerDeviceID,
        actual: byDeviceID)
    }
    guard plan.projectID == manifest.projectID else {
      throw TatwoOfflineCopyMergeErrorV1.planMismatch("projectID")
    }
    guard plan.canonicalHead.anchor == manifest.formalHead else {
      throw TatwoOfflineCopyMergeErrorV1.planMismatch(
        "plan canonical head does not match manifest formal head")
    }
    guard promotedVersionAnchor.isWellFormed else {
      throw TatwoOfflineCopyMergeErrorV1.invalidCanonicalHead(
        "promoted version anchor is malformed")
    }
    guard sameAnchorKind(plan.canonicalHead.anchor, promotedVersionAnchor) else {
      throw TatwoOfflineCopyMergeErrorV1.planMismatch(
        "promotion changes data channel")
    }
    guard plan.provisional else {
      throw TatwoOfflineCopyMergeErrorV1.planMismatch("plan is already applied")
    }
    guard case .fastForward = plan.decision else {
      throw TatwoOfflineCopyMergeErrorV1.planNotApplicable(
        "only fastForward plans can promote a head; rebase/conflict must be replanned")
    }
    guard advances(from: plan.canonicalHead.anchor, to: promotedVersionAnchor) else {
      throw TatwoOfflineCopyMergeErrorV1.promotionDidNotAdvance
    }

    return TatwoOfflineCopyMergeApplicationV1(
      projectID: manifest.projectID,
      replicaID: plan.replicaID,
      appliedBy: byDeviceID,
      previousCanonicalHead: plan.canonicalHead.anchor,
      promotedCanonicalHead: promotedVersionAnchor,
      provisional: false,
      replicaState: .cleanMirror)
  }

  // MARK: Internal helpers

  private enum AnchorRelation {
    case equal
    case canonicalAhead
    case canonicalBehind
    case incomparable
  }

  private static func compare(
    base: TatwoSharedProjectVersionAnchorV1,
    current: TatwoSharedProjectVersionAnchorV1
  ) -> AnchorRelation {
    switch (base, current) {
    case let (.git(baseCommit, baseTree), .git(currentCommit, currentTree)):
      if baseCommit == currentCommit {
        if baseTree == nil || currentTree == nil || baseTree == currentTree {
          return .equal
        }
        return .incomparable
      }
      // Opaque git hashes do not carry ancestry.  The canonical adapter must
      // provide changed paths; differing commits are conservatively treated as
      // canonical-ahead rather than guessed as a clean merge.
      return .canonicalAhead
    case let (.journal(baseSequence, baseDigest), .journal(currentSequence, currentDigest)):
      if baseSequence == currentSequence {
        if baseDigest == nil || currentDigest == nil || baseDigest == currentDigest {
          return .equal
        }
        return .incomparable
      }
      return currentSequence > baseSequence ? .canonicalAhead : .canonicalBehind
    default:
      return .incomparable
    }
  }

  private static func sameAnchorKind(
    _ lhs: TatwoSharedProjectVersionAnchorV1,
    _ rhs: TatwoSharedProjectVersionAnchorV1
  ) -> Bool {
    switch (lhs, rhs) {
    case (.git, .git), (.journal, .journal):
      return true
    default:
      return false
    }
  }

  private static func advances(
    from lhs: TatwoSharedProjectVersionAnchorV1,
    to rhs: TatwoSharedProjectVersionAnchorV1
  ) -> Bool {
    switch (lhs, rhs) {
    case let (.git(lhsCommit, lhsTree), .git(rhsCommit, rhsTree)):
      return lhsCommit != rhsCommit || lhsTree != rhsTree
    case let (.journal(lhsSequence, _), .journal(rhsSequence, _)):
      return rhsSequence > lhsSequence
    default:
      return false
    }
  }

  private static func gitInstruction(
    manifest: TatwoSharedProjectManifestV1,
    replica: TatwoOfflineCopyStateV1,
    decision: TatwoOfflineCopyMergeDecisionV1
  ) -> TatwoOfflineCopyGitMergeInstructionV1? {
    guard manifest.dataKinds.contains(.gitBacked) else { return nil }
    guard decision.statusLabel == "fastForward" || decision.statusLabel == "needsRebase" else {
      return nil
    }
    let project = TatwoLoopPathComponent.sanitize(manifest.projectID)
    let replicaID = TatwoLoopPathComponent.sanitize(replica.replicaID)
    let branch = "wip/\(project)/\(replicaID)"
    return TatwoOfflineCopyGitMergeInstructionV1(
      wipBranch: branch,
      pushCommand: "git push origin HEAD:refs/heads/\(branch)",
      writerMergeCommand: "git merge --no-ff \(branch)",
      requiresCanonicalWriter: true)
  }

  private static func rejectedPlan(
    manifest: TatwoSharedProjectManifestV1,
    replica: TatwoOfflineCopyStateV1,
    canonicalHead: TatwoOfflineCopyCanonicalHeadV1,
    writer: String,
    reason: String
  ) -> TatwoOfflineCopyMergePlanV1 {
    TatwoOfflineCopyMergePlanV1(
      projectID: manifest.projectID,
      replicaID: replica.replicaID,
      sourceDeviceID: replica.deviceID,
      baseVersionAnchor: replica.baseVersionAnchor,
      canonicalHead: canonicalHead,
      decision: .rejected(reason: reason),
      applicableBy: writer,
      provisional: true,
      gitInstruction: nil)
  }
}
