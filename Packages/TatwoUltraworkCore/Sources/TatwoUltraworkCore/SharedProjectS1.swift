import Foundation
import TatwoDomainContracts

// MARK: - Shared Project S1 (D9 / SHARED_PROJECT_DESIGN.md §11 S1)
//
// Pure Core under Domain Data Sync Plane B.
// Per-project canonical writer; shared ≠ multi-writer.
// Epoch / fencing semantics reuse handoff lease transfer
// (`TatwoHandoffLeaseTransferV1.leaseEpoch` + `fencingToken`) — no second
// sovereignty mechanism.

// MARK: - Fencing type aliases (handoff lease alignment)

/// Project writer epoch. Same integer generation rules as
/// `TatwoHandoffLeaseTransferV1.leaseEpoch` / `TatwoAuthorityLeaseV1.epoch`:
/// strictly increasing, never reused after retire.
public typealias TatwoProjectEpochV1 = UInt64

/// Project writer fencing token. Same opaque-token rules as
/// `TatwoHandoffLeaseTransferV1.fencingToken` / `TatwoAuthorityLeaseV1.fencingToken`:
/// unique per epoch generation; historical tokens fail-closed immediately.
public typealias TatwoProjectFencingTokenV1 = String

// MARK: - Errors (fail-closed)

public enum TatwoSharedProjectErrorV1: Error, LocalizedError, Equatable, Sendable {
  case missingManifest
  case corruptManifest(String)
  case schemaMismatch(String)
  case missingRequiredField(String)
  case invalidWriterLease(String)
  case dualActiveWriter
  case commitAlreadyExists
  case staleEpoch
  case epochNotMonotonic
  case fencingTokenReuse
  case domainFenceMissing
  case domainFenceMismatch
  case splitBrainLock
  case unassignedWriter
  case localNotWriter
  case deviceAuthorityFenced
  case formalWriteDenied(String)
  case invalidTransition(from: String, to: String)
  case registryLocked

  public var errorDescription: String? {
    switch self {
    case .missingManifest:
      "shared project manifest is missing"
    case let .corruptManifest(detail):
      "shared project manifest is corrupt: \(detail)"
    case let .schemaMismatch(schema):
      "shared project manifest schema mismatch: \(schema)"
    case let .missingRequiredField(field):
      "shared project manifest missing required field: \(field)"
    case let .invalidWriterLease(detail):
      "invalid project writer lease: \(detail)"
    case .dualActiveWriter:
      "two active writers claimed for the same project (split-brain)"
    case .commitAlreadyExists:
      // Align wording with TatwoHandoffLeaseTransferErrorV1.commitAlreadyExists
      "a writer lease commit already exists for this project epoch"
    case .staleEpoch:
      "project epoch is stale or fenced"
    case .epochNotMonotonic:
      "project epoch must strictly increase"
    case .fencingTokenReuse:
      "project fencing token must not be reused across epochs"
    case .domainFenceMissing:
      "registry mutation requires a valid domain lease fence"
    case .domainFenceMismatch:
      "domain lease fence does not match registry binding"
    case .splitBrainLock:
      "project is under split_brain_lock; formal and registry writes denied"
    case .unassignedWriter:
      "project has no assigned canonical writer; formal write denied"
    case .localNotWriter:
      "local device is not the project canonical writer"
    case .deviceAuthorityFenced:
      "project writer's device-level origin lease is fenced or revoked"
    case let .formalWriteDenied(detail):
      "formal write denied: \(detail)"
    case let .invalidTransition(from, to):
      "invalid merge/provisional transition \(from) → \(to)"
    case .registryLocked:
      "writer registry is locked"
    }
  }
}

// MARK: - Member role / data kind / version anchor

/// Member roles on a shared project (design §4.2).
public enum TatwoSharedProjectMemberRoleV1: String, Codable, Sendable, CaseIterable, Equatable {
  case writer
  case verifier
  /// Offline / online work replica — local writes only as provisional.
  case offlineCopy = "offline-copy"
}

/// Payload channel class (design §6). One project may later host both; S1
/// records the declared primary kind(s) for formal-head shape.
public enum TatwoSharedProjectDataKindV1: String, Codable, Sendable, CaseIterable, Equatable {
  case gitBacked = "git-backed"
  case journalBacked = "journal-backed"
}

/// Version anchor for formal head: git commit/tree or journal sequence.
public enum TatwoSharedProjectVersionAnchorV1: Codable, Sendable, Equatable {
  case git(commit: String, tree: String?)
  case journal(sequence: UInt64, digest: String?)

  private enum CodingKeys: String, CodingKey {
    case kind
    case commit
    case tree
    case sequence
    case digest
  }

  private enum Kind: String, Codable {
    case git
    case journal
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .git:
      let commit = try container.decode(String.self, forKey: .commit)
      let tree = try container.decodeIfPresent(String.self, forKey: .tree)
      self = .git(commit: commit, tree: tree)
    case .journal:
      let sequence = try container.decode(UInt64.self, forKey: .sequence)
      let digest = try container.decodeIfPresent(String.self, forKey: .digest)
      self = .journal(sequence: sequence, digest: digest)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .git(commit, tree):
      try container.encode(Kind.git, forKey: .kind)
      try container.encode(commit, forKey: .commit)
      try container.encodeIfPresent(tree, forKey: .tree)
    case let .journal(sequence, digest):
      try container.encode(Kind.journal, forKey: .kind)
      try container.encode(sequence, forKey: .sequence)
      try container.encodeIfPresent(digest, forKey: .digest)
    }
  }

  public var isWellFormed: Bool {
    switch self {
    case let .git(commit, _):
      !commit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .journal:
      true
    }
  }
}

// MARK: - Canonical writer lease (project-level; epoch/fencing = handoff shape)

/// Per-project canonical writer lease.
/// Field shapes intentionally mirror `TatwoHandoffLeaseTransferV1` /
/// `TatwoAuthorityLeaseV1` fencing (epoch + fencingToken + holder device).
/// A project lease is valid only while its writer device is the current
/// device-level origin authority; device lease revocation therefore fences
/// every formal project write.
public struct TatwoProjectWriterLeaseV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoProjectWriterLeaseV1"

  public let schema: String
  public let projectID: String
  /// Canonical writer device. Aligns with transfer `toDeviceID` / lease `holderDeviceID`.
  public let writerDeviceID: String
  /// Aligns with `TatwoHandoffLeaseTransferV1.leaseEpoch`.
  public let projectEpoch: TatwoProjectEpochV1
  /// Aligns with `TatwoHandoffLeaseTransferV1.fencingToken`.
  public let projectFencingToken: TatwoProjectFencingTokenV1
  public let since: Date

  public init(
    schema: String = TatwoProjectWriterLeaseV1.schemaName,
    projectID: String,
    writerDeviceID: String,
    projectEpoch: TatwoProjectEpochV1,
    projectFencingToken: TatwoProjectFencingTokenV1,
    since: Date
  ) {
    self.schema = schema
    self.projectID = projectID
    self.writerDeviceID = writerDeviceID
    self.projectEpoch = projectEpoch
    self.projectFencingToken = projectFencingToken
    self.since = since
  }

  /// Structural validation only (not domain authority).
  public func validateStructure() throws {
    if schema != Self.schemaName {
      throw TatwoSharedProjectErrorV1.schemaMismatch(schema)
    }
    let pid = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
    let did = writerDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = projectFencingToken.trimmingCharacters(in: .whitespacesAndNewlines)
    if pid.isEmpty {
      throw TatwoSharedProjectErrorV1.invalidWriterLease("empty projectID")
    }
    if did.isEmpty {
      throw TatwoSharedProjectErrorV1.invalidWriterLease("empty writerDeviceID")
    }
    if projectEpoch == 0 {
      throw TatwoSharedProjectErrorV1.invalidWriterLease("projectEpoch must be > 0")
    }
    if token.isEmpty {
      throw TatwoSharedProjectErrorV1.invalidWriterLease("empty projectFencingToken")
    }
  }
}

// MARK: - Members

public struct TatwoSharedProjectMemberV1: Codable, Sendable, Equatable {
  public let deviceID: String
  public let role: TatwoSharedProjectMemberRoleV1
  /// When `role == .offlineCopy`, true means local provisional edits exist.
  public let provisional: Bool

  public init(
    deviceID: String,
    role: TatwoSharedProjectMemberRoleV1,
    provisional: Bool = false
  ) {
    self.deviceID = deviceID
    self.role = role
    self.provisional = provisional
  }
}

// MARK: - Version floor

public struct TatwoSharedProjectVersionFloorV1: Codable, Sendable, Equatable {
  public let minSchemaVersion: Int
  public let minProtocolVersion: Int
  public let minAppVersion: String?

  public init(
    minSchemaVersion: Int,
    minProtocolVersion: Int,
    minAppVersion: String? = nil
  ) {
    self.minSchemaVersion = minSchemaVersion
    self.minProtocolVersion = minProtocolVersion
    self.minAppVersion = minAppVersion
  }

  public var isWellFormed: Bool {
    minSchemaVersion > 0 && minProtocolVersion > 0
  }
}

// MARK: - Manifest V1

/// Shared project identity + formal head + canonical writer + members.
/// Fail-closed on load: missing / corrupt / incomplete → not writable.
public struct TatwoSharedProjectManifestV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoSharedProjectManifestV1"

  public let schema: String
  public let projectID: String
  public let displayName: String
  public let dataKinds: [TatwoSharedProjectDataKindV1]
  public let formalHead: TatwoSharedProjectVersionAnchorV1
  public let writer: TatwoProjectWriterLeaseV1
  public let members: [TatwoSharedProjectMemberV1]
  public let versionFloor: TatwoSharedProjectVersionFloorV1
  public let createdAt: Date
  /// Optional precomputed content digest (`sha256:…`).
  public let manifestDigest: String?

  public init(
    schema: String = TatwoSharedProjectManifestV1.schemaName,
    projectID: String,
    displayName: String,
    dataKinds: [TatwoSharedProjectDataKindV1],
    formalHead: TatwoSharedProjectVersionAnchorV1,
    writer: TatwoProjectWriterLeaseV1,
    members: [TatwoSharedProjectMemberV1],
    versionFloor: TatwoSharedProjectVersionFloorV1,
    createdAt: Date,
    manifestDigest: String? = nil
  ) {
    self.schema = schema
    self.projectID = projectID
    self.displayName = displayName
    self.dataKinds = dataKinds
    self.formalHead = formalHead
    self.writer = writer
    self.members = members
    self.versionFloor = versionFloor
    self.createdAt = createdAt
    self.manifestDigest = manifestDigest
  }

  /// Build + validate; throws fail-closed errors on incomplete input.
  public static func build(
    projectID: String,
    displayName: String,
    dataKinds: [TatwoSharedProjectDataKindV1],
    formalHead: TatwoSharedProjectVersionAnchorV1,
    writer: TatwoProjectWriterLeaseV1,
    members: [TatwoSharedProjectMemberV1],
    versionFloor: TatwoSharedProjectVersionFloorV1,
    createdAt: Date = Date(),
    computeDigest: Bool = true
  ) throws -> TatwoSharedProjectManifestV1 {
    var draft = TatwoSharedProjectManifestV1(
      projectID: projectID,
      displayName: displayName,
      dataKinds: dataKinds,
      formalHead: formalHead,
      writer: writer,
      members: members,
      versionFloor: versionFloor,
      createdAt: createdAt,
      manifestDigest: nil)
    try draft.validateRequiredFields()
    if computeDigest {
      let digest = try draft.canonicalDigest()
      draft = TatwoSharedProjectManifestV1(
        projectID: draft.projectID,
        displayName: draft.displayName,
        dataKinds: draft.dataKinds,
        formalHead: draft.formalHead,
        writer: draft.writer,
        members: draft.members,
        versionFloor: draft.versionFloor,
        createdAt: draft.createdAt,
        manifestDigest: digest)
    }
    return draft
  }

  public func validateRequiredFields() throws {
    if schema != Self.schemaName {
      throw TatwoSharedProjectErrorV1.schemaMismatch(schema)
    }
    let pid = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if pid.isEmpty {
      throw TatwoSharedProjectErrorV1.missingRequiredField("projectID")
    }
    if name.isEmpty {
      throw TatwoSharedProjectErrorV1.missingRequiredField("displayName")
    }
    if dataKinds.isEmpty {
      throw TatwoSharedProjectErrorV1.missingRequiredField("dataKinds")
    }
    if !formalHead.isWellFormed {
      throw TatwoSharedProjectErrorV1.missingRequiredField("formalHead")
    }
    if !versionFloor.isWellFormed {
      throw TatwoSharedProjectErrorV1.missingRequiredField("versionFloor")
    }
    try writer.validateStructure()
    if writer.projectID != projectID {
      throw TatwoSharedProjectErrorV1.invalidWriterLease(
        "writer.projectID must match manifest.projectID")
    }
    let writers = members.filter { $0.role == .writer }
    if writers.count != 1 {
      throw TatwoSharedProjectErrorV1.invalidWriterLease(
        "members must list exactly one writer role")
    }
    if writers[0].deviceID != writer.writerDeviceID {
      throw TatwoSharedProjectErrorV1.invalidWriterLease(
        "member writer deviceID must match canonical writer")
    }
    if writers[0].provisional {
      throw TatwoSharedProjectErrorV1.invalidWriterLease(
        "canonical writer member must not be provisional")
    }
  }

  public func canonicalPayloadData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    // Digest excludes manifestDigest itself.
    let unsigned = TatwoSharedProjectManifestV1(
      schema: schema,
      projectID: projectID,
      displayName: displayName,
      dataKinds: dataKinds,
      formalHead: formalHead,
      writer: writer,
      members: members,
      versionFloor: versionFloor,
      createdAt: createdAt,
      manifestDigest: nil)
    return try encoder.encode(unsigned)
  }

  public func canonicalDigest() throws -> String {
    TatwoLoopJobDigest.sha256(try canonicalPayloadData())
  }
}

// MARK: - Manifest load (fail-closed)

public enum TatwoSharedProjectManifestLoaderV1 {
  /// Decode + validate. Any failure → fail-closed (not writable).
  public static func load(data: Data) throws -> TatwoSharedProjectManifestV1 {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest: TatwoSharedProjectManifestV1
    do {
      manifest = try decoder.decode(TatwoSharedProjectManifestV1.self, from: data)
    } catch {
      throw TatwoSharedProjectErrorV1.corruptManifest(String(describing: error))
    }
    try manifest.validateRequiredFields()
    if let claimed = manifest.manifestDigest {
      let actual = try manifest.canonicalDigest()
      if claimed != actual {
        throw TatwoSharedProjectErrorV1.corruptManifest(
          "manifestDigest mismatch")
      }
    }
    return manifest
  }

  public static func load(jsonUTF8: String) throws -> TatwoSharedProjectManifestV1 {
    guard let data = jsonUTF8.data(using: .utf8) else {
      throw TatwoSharedProjectErrorV1.corruptManifest("not utf-8")
    }
    return try load(data: data)
  }

  /// Fail-closed: nil / empty → missing (not writable).
  public static func loadOptional(data: Data?) throws -> TatwoSharedProjectManifestV1 {
    guard let data, !data.isEmpty else {
      throw TatwoSharedProjectErrorV1.missingManifest
    }
    return try load(data: data)
  }
}

// MARK: - Writer resolution / local write eligibility (three-state)

/// Three-state answer to “who is the current writer?”
public enum TatwoProjectWriterQueryResultV1: Sendable, Equatable {
  /// Exactly one active canonical writer.
  case assigned(TatwoProjectWriterLeaseV1)
  /// Explicitly unassigned; all formal writes denied.
  case unassigned
  /// Missing, corrupt, dual-writer, or split-brain — fail-closed.
  case unavailable(TatwoSharedProjectErrorV1)
}

/// Three-state answer to “may this local device write?”
public enum TatwoLocalWriteEligibilityV1: Sendable, Equatable {
  /// Local device is canonical writer; formal shared write allowed (if not locked).
  case formal
  /// Local device is offline-copy; only provisional writes allowed.
  case provisional
  /// Verifier, missing/corrupt, wrong fence, split-brain, unassigned, etc.
  case denied(TatwoSharedProjectErrorV1)
}

// MARK: - Retired writer history

public enum TatwoProjectWriterRetireReasonV1: String, Codable, Sendable, Equatable {
  case transfer
  case reclaim
  case splitBrainResolution = "split_brain_resolution"
}

public struct TatwoProjectWriterRetiredEntryV1: Codable, Sendable, Equatable {
  public let lease: TatwoProjectWriterLeaseV1
  public let reason: TatwoProjectWriterRetireReasonV1
  public let retiredAt: Date

  public init(
    lease: TatwoProjectWriterLeaseV1,
    reason: TatwoProjectWriterRetireReasonV1,
    retiredAt: Date
  ) {
    self.lease = lease
    self.reason = reason
    self.retiredAt = retiredAt
  }
}

// MARK: - Domain fence binding for registry mutations (P4)

/// Domain-plane fencing required to mutate the writer registry.
/// Reuses `TatwoAuthorityLeaseV1` epoch + fencingToken fields.
public struct TatwoDomainFenceBindingV1: Sendable, Equatable {
  public let domainID: String
  public let holderDeviceID: String
  public let leaseEpoch: UInt64
  public let fencingToken: String

  public init(
    domainID: String,
    holderDeviceID: String,
    leaseEpoch: UInt64,
    fencingToken: String
  ) {
    self.domainID = domainID
    self.holderDeviceID = holderDeviceID
    self.leaseEpoch = leaseEpoch
    self.fencingToken = fencingToken
  }

  public init(lease: TatwoAuthorityLeaseV1) {
    self.domainID = lease.domainID
    self.holderDeviceID = lease.holderDeviceID
    self.leaseEpoch = lease.epoch
    self.fencingToken = lease.fencingToken
  }

  public func matches(_ lease: TatwoAuthorityLeaseV1) -> Bool {
    domainID == lease.domainID
      && holderDeviceID == lease.holderDeviceID
      && leaseEpoch == lease.epoch
      && fencingToken == lease.fencingToken
      && lease.epoch > 0
      && !lease.fencingToken.isEmpty
  }
}

// MARK: - Writer registry (in-memory Core; S1)

/// Domain-scoped project writer registry.
/// Mutations are create-only per `(projectID, projectEpoch)` — same dual-writer
/// defense spirit as handoff lease `commitAlreadyExists` / create-only commit.
public final class TatwoProjectWriterRegistryV1: @unchecked Sendable {
  public static let schemaName = "TatwoProjectWriterRegistryV1"

  private let lock = NSLock()
  private let domainID: String
  /// Active lease per projectID (at most one).
  private var active: [String: TatwoProjectWriterLeaseV1] = [:]
  /// Create-only epoch slots: "\(projectID)#\(epoch)" → fencingToken.
  private var epochCommits: [String: String] = [:]
  /// All fencing tokens ever issued (reuse ban).
  private var seenTokens: Set<String> = []
  private var retired: [String: [TatwoProjectWriterRetiredEntryV1]] = [:]
  private var splitBrainProjects: Set<String> = []
  /// Bound domain fence for mutations; nil until first successful bind.
  private var boundDomainFence: TatwoDomainFenceBindingV1?

  public init(domainID: String) {
    self.domainID = domainID
    self.originAuthorityProvider = TatwoUnavailableOriginAuthorityProvider()
  }

  public init(
    domainID: String,
    originAuthorityProvider: any TatwoOriginAuthorityProviding
  ) {
    self.domainID = domainID
    self.originAuthorityProvider = originAuthorityProvider
  }

  public var registryDomainID: String { domainID }
  private let originAuthorityProvider: any TatwoOriginAuthorityProviding

  // MARK: Query

  public func currentWriter(projectID: String) -> TatwoProjectWriterQueryResultV1 {
    lock.lock()
    defer { lock.unlock() }
    if splitBrainProjects.contains(projectID) {
      return .unavailable(.splitBrainLock)
    }
    if let lease = active[projectID] {
      return .assigned(lease)
    }
    return .unassigned
  }

  public func isSplitBrainLocked(projectID: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return splitBrainProjects.contains(projectID)
  }

  public func retiredHistory(projectID: String) -> [TatwoProjectWriterRetiredEntryV1] {
    lock.lock()
    defer { lock.unlock() }
    return retired[projectID] ?? []
  }

  /// Query: who is writer + may local formal/provisional write?
  /// Fail-closed when manifest missing/corrupt (caller must not pass bad manifests).
  public func localWriteEligibility(
    manifest: TatwoSharedProjectManifestV1?,
    localDeviceID: String,
    loadError: TatwoSharedProjectErrorV1? = nil
  ) -> TatwoLocalWriteEligibilityV1 {
    if let loadError {
      return .denied(loadError)
    }
    guard let manifest else {
      return .denied(.missingManifest)
    }
    // Re-validate structure fail-closed.
    do {
      try manifest.validateRequiredFields()
    } catch let error as TatwoSharedProjectErrorV1 {
      return .denied(error)
    } catch {
      return .denied(.corruptManifest(String(describing: error)))
    }
    guard let claimedDigest = manifest.manifestDigest else {
      return .denied(.corruptManifest("manifestDigest is required for write eligibility"))
    }
    do {
      let actualDigest = try manifest.canonicalDigest()
      guard actualDigest == claimedDigest else {
        return .denied(.corruptManifest("manifestDigest mismatch"))
      }
    } catch {
      return .denied(.corruptManifest("manifestDigest could not be recomputed"))
    }

    lock.lock()
    let locked = splitBrainProjects.contains(manifest.projectID)
    let registryLease = active[manifest.projectID]
    lock.unlock()

    if locked {
      return .denied(.splitBrainLock)
    }

    // Prefer live registry if present; else manifest writer (fixture / cold load).
    let effective: TatwoProjectWriterLeaseV1
    if let registryLease {
      if registryLease.projectEpoch != manifest.writer.projectEpoch
        || registryLease.projectFencingToken != manifest.writer.projectFencingToken
        || registryLease.writerDeviceID != manifest.writer.writerDeviceID
      {
        // Manifest drifted from registry without transfer — fail-closed formal.
        // Offline-copy may still provisional if member role says so.
        return eligibilityFromMembers(
          manifest: manifest,
          localDeviceID: localDeviceID,
          formalAllowed: false)
      }
      effective = registryLease
    } else {
      effective = manifest.writer
    }

    guard let authorityEpoch = originAuthorityProvider.authorityEpoch,
      originAuthorityProvider.isOriginAuthority(
        deviceID: effective.writerDeviceID,
        epoch: authorityEpoch,
        now: Date())
    else {
      return .denied(.deviceAuthorityFenced)
    }

    if effective.writerDeviceID == localDeviceID {
      return .formal
    }
    return eligibilityFromMembers(
      manifest: manifest,
      localDeviceID: localDeviceID,
      formalAllowed: false)
  }

  private func eligibilityFromMembers(
    manifest: TatwoSharedProjectManifestV1,
    localDeviceID: String,
    formalAllowed: Bool
  ) -> TatwoLocalWriteEligibilityV1 {
    if formalAllowed, manifest.writer.writerDeviceID == localDeviceID {
      return .formal
    }
    if let member = manifest.members.first(where: { $0.deviceID == localDeviceID }) {
      switch member.role {
      case .writer:
        // Member list says writer but lease disagrees → deny formal.
        return .denied(.localNotWriter)
      case .offlineCopy:
        return .provisional
      case .verifier:
        return .denied(
          .formalWriteDenied("verifier is read-only"))
      }
    }
    return .denied(.localNotWriter)
  }

  // MARK: Mutations (domain fence + create-only)

  /// Bind / refresh domain fence. Required before any registry mutation.
  public func bindDomainFence(_ fence: TatwoDomainFenceBindingV1) throws {
    lock.lock()
    defer { lock.unlock() }
    guard fence.domainID == domainID else {
      throw TatwoSharedProjectErrorV1.domainFenceMismatch
    }
    guard fence.leaseEpoch > 0, !fence.fencingToken.isEmpty else {
      throw TatwoSharedProjectErrorV1.domainFenceMissing
    }
    try requireDeviceAuthority(
      deviceID: fence.holderDeviceID,
      epoch: fence.leaseEpoch,
      surface: "shared_project_bind_domain_fence")
    boundDomainFence = fence
  }

  public func bindDomainFence(lease: TatwoAuthorityLeaseV1) throws {
    try bindDomainFence(TatwoDomainFenceBindingV1(lease: lease))
  }

  /// Create-only install of the first / transferred writer for a project epoch.
  /// Dual create for the same epoch → `commitAlreadyExists` (handoff lease semantics).
  /// Second *active* writer with different epoch without retire → `dualActiveWriter` / split-brain.
  @discardableResult
  public func commitWriterLease(
    _ lease: TatwoProjectWriterLeaseV1,
    domainFence: TatwoDomainFenceBindingV1,
    now: Date = Date()
  ) throws -> TatwoProjectWriterLeaseV1 {
    try lease.validateStructure()

    lock.lock()
    defer { lock.unlock() }
    try assertDomainFenceLocked(domainFence)
    try assertProjectWriterDeviceAuthorityLocked(
      deviceID: lease.writerDeviceID,
      surface: "shared_project_commit_writer")

    if splitBrainProjects.contains(lease.projectID) {
      throw TatwoSharedProjectErrorV1.splitBrainLock
    }

    let slotKey = Self.epochSlotKey(projectID: lease.projectID, epoch: lease.projectEpoch)

    // Create-only: same epoch already committed.
    if let existingToken = epochCommits[slotKey] {
      if existingToken == lease.projectFencingToken,
        let activeLease = active[lease.projectID],
        activeLease == lease
      {
        // Idempotent replay of identical commit.
        return activeLease
      }
      throw TatwoSharedProjectErrorV1.commitAlreadyExists
    }

    // Fencing token never reused (any project in this registry).
    if seenTokens.contains(lease.projectFencingToken) {
      throw TatwoSharedProjectErrorV1.fencingTokenReuse
    }

    if let current = active[lease.projectID] {
      // Transfer path: new epoch must be strictly greater; old must retire first
      // via transferWriter. Direct dual active is split-brain.
      if lease.projectEpoch == current.projectEpoch {
        if lease.writerDeviceID != current.writerDeviceID
          || lease.projectFencingToken != current.projectFencingToken
        {
          splitBrainProjects.insert(lease.projectID)
          throw TatwoSharedProjectErrorV1.dualActiveWriter
        }
        return current
      }
      if lease.projectEpoch < current.projectEpoch {
        throw TatwoSharedProjectErrorV1.staleEpoch
      }
      // Higher epoch without explicit transfer/retire → refuse (no silent dual).
      throw TatwoSharedProjectErrorV1.dualActiveWriter
    }

    epochCommits[slotKey] = lease.projectFencingToken
    seenTokens.insert(lease.projectFencingToken)
    active[lease.projectID] = lease
    return lease
  }

  /// Explicit single-point transfer (design §8.6 shape). Retires old, commits new
  /// with create-only epoch slot. No dual-writer window.
  @discardableResult
  public func transferWriter(
    projectID: String,
    to newLease: TatwoProjectWriterLeaseV1,
    domainFence: TatwoDomainFenceBindingV1,
    reason: TatwoProjectWriterRetireReasonV1 = .transfer,
    now: Date = Date()
  ) throws -> TatwoProjectWriterLeaseV1 {
    try newLease.validateStructure()
    guard newLease.projectID == projectID else {
      throw TatwoSharedProjectErrorV1.invalidWriterLease("projectID mismatch")
    }

    lock.lock()
    defer { lock.unlock() }
    try assertDomainFenceLocked(domainFence)
    try assertProjectWriterDeviceAuthorityLocked(
      deviceID: newLease.writerDeviceID,
      surface: "shared_project_transfer_writer")

    if splitBrainProjects.contains(projectID) {
      throw TatwoSharedProjectErrorV1.splitBrainLock
    }
    guard let current = active[projectID] else {
      // First assignment uses commitWriterLease; transfer requires prior writer.
      throw TatwoSharedProjectErrorV1.unassignedWriter
    }
    guard newLease.projectEpoch == current.projectEpoch + 1 else {
      throw TatwoSharedProjectErrorV1.epochNotMonotonic
    }
    if seenTokens.contains(newLease.projectFencingToken) {
      throw TatwoSharedProjectErrorV1.fencingTokenReuse
    }
    if newLease.writerDeviceID == current.writerDeviceID {
      throw TatwoSharedProjectErrorV1.invalidWriterLease(
        "transfer receiver must be distinct from current writer")
    }

    let slotKey = Self.epochSlotKey(projectID: projectID, epoch: newLease.projectEpoch)
    if epochCommits[slotKey] != nil {
      throw TatwoSharedProjectErrorV1.commitAlreadyExists
    }

    let retiredEntry = TatwoProjectWriterRetiredEntryV1(
      lease: current,
      reason: reason,
      retiredAt: now)
    retired[projectID, default: []].append(retiredEntry)
    active.removeValue(forKey: projectID)

    epochCommits[slotKey] = newLease.projectFencingToken
    seenTokens.insert(newLease.projectFencingToken)
    active[projectID] = newLease
    return newLease
  }

  /// Record dual-writer evidence and enter split_brain_lock (no auto-election).
  public func enterSplitBrainLock(projectID: String) {
    lock.lock()
    defer { lock.unlock() }
    splitBrainProjects.insert(projectID)
  }

  /// Human-gated resolution: pick survivor lease, retire loser, clear lock.
  @discardableResult
  public func resolveSplitBrain(
    projectID: String,
    survivor: TatwoProjectWriterLeaseV1,
    domainFence: TatwoDomainFenceBindingV1,
    now: Date = Date()
  ) throws -> TatwoProjectWriterLeaseV1 {
    try survivor.validateStructure()
    guard survivor.projectID == projectID else {
      throw TatwoSharedProjectErrorV1.invalidWriterLease("projectID mismatch")
    }

    lock.lock()
    defer { lock.unlock() }
    try assertDomainFenceLocked(domainFence)
    try assertProjectWriterDeviceAuthorityLocked(
      deviceID: survivor.writerDeviceID,
      surface: "shared_project_resolve_split_brain")

    guard splitBrainProjects.contains(projectID) else {
      throw TatwoSharedProjectErrorV1.invalidWriterLease(
        "project is not in split_brain_lock")
    }
    // Survivor must use a fresh epoch beyond any committed slot for this project.
    let maxCommitted = epochCommits.keys.compactMap { key -> UInt64? in
      let parts = key.split(separator: "#", maxSplits: 1)
      guard parts.count == 2, parts[0] == projectID else { return nil }
      return UInt64(parts[1])
    }.max() ?? 0
    guard survivor.projectEpoch > maxCommitted else {
      throw TatwoSharedProjectErrorV1.epochNotMonotonic
    }
    if seenTokens.contains(survivor.projectFencingToken) {
      throw TatwoSharedProjectErrorV1.fencingTokenReuse
    }
    let slotKey = Self.epochSlotKey(projectID: projectID, epoch: survivor.projectEpoch)
    if epochCommits[slotKey] != nil {
      throw TatwoSharedProjectErrorV1.commitAlreadyExists
    }

    if let current = active[projectID], current != survivor {
      retired[projectID, default: []].append(
        TatwoProjectWriterRetiredEntryV1(
          lease: current,
          reason: .splitBrainResolution,
          retiredAt: now))
    }
    active.removeValue(forKey: projectID)
    epochCommits[slotKey] = survivor.projectFencingToken
    seenTokens.insert(survivor.projectFencingToken)
    active[projectID] = survivor
    splitBrainProjects.remove(projectID)
    return survivor
  }

  // MARK: Private

  /// Caller must hold `lock`.
  private func assertDomainFenceLocked(_ fence: TatwoDomainFenceBindingV1) throws {
    guard fence.domainID == domainID else {
      throw TatwoSharedProjectErrorV1.domainFenceMismatch
    }
    guard fence.leaseEpoch > 0, !fence.fencingToken.isEmpty else {
      throw TatwoSharedProjectErrorV1.domainFenceMissing
    }
    if let bound = boundDomainFence {
      guard bound.domainID == fence.domainID,
        bound.leaseEpoch == fence.leaseEpoch,
        bound.fencingToken == fence.fencingToken
      else {
        throw TatwoSharedProjectErrorV1.domainFenceMismatch
      }
    }
    try requireDeviceAuthority(
      deviceID: fence.holderDeviceID,
      epoch: fence.leaseEpoch,
      surface: "shared_project_domain_fence")
  }

  private func assertProjectWriterDeviceAuthorityLocked(
    deviceID: String,
    surface: String
  ) throws {
    guard let epoch = originAuthorityProvider.authorityEpoch else {
      throw TatwoSharedProjectErrorV1.formalWriteDenied(
        "device-level origin lease epoch is unavailable")
    }
    try requireDeviceAuthority(deviceID: deviceID, epoch: epoch, surface: surface)
  }

  private func requireDeviceAuthority(
    deviceID: String,
    epoch: UInt64,
    surface: String
  ) throws {
    do {
      try originAuthorityProvider.requireOriginAuthority(
        deviceID: deviceID,
        epoch: epoch,
        surface: surface,
        now: Date())
    } catch {
      throw TatwoSharedProjectErrorV1.formalWriteDenied(
        "device-level origin lease fenced: \(error.localizedDescription)")
    }
  }

  private static func epochSlotKey(projectID: String, epoch: UInt64) -> String {
    "\(projectID)#\(epoch)"
  }
}

// MARK: - Merge state machine (clean | conflict | pending-review)

/// Formal merge outcome states for S1 (design §4.4 core trio).
/// Full replica lifecycle (queued, version_blocked, …) lands in S3; S1 freezes
/// the three human-visible merge results and pure transition rules only.
public enum TatwoProjectMergeStateV1: String, Codable, Sendable, CaseIterable, Equatable {
  case clean
  case conflict
  case pendingReview = "pending-review"
}

public enum TatwoProjectMergeEventV1: String, Codable, Sendable, Equatable {
  /// Writer accepted proposal with no conflicts and policy auto-pass.
  case acceptClean = "accept_clean"
  /// Three-way / dual-parent conflict detected.
  case detectConflict = "detect_conflict"
  /// Policy requires human / gate even if mechanically mergeable.
  case requireReview = "require_review"
  /// Human / gate resolved conflict into a clean formal head.
  case resolveConflictClean = "resolve_conflict_clean"
  /// Human / gate approved pending review → clean formal head.
  case approveReview = "approve_review"
  /// Review rejected back to conflict for manual resolution.
  case rejectReviewToConflict = "reject_review_to_conflict"
  /// Fresh conflict found while in pending-review.
  case reviewFindsConflict = "review_finds_conflict"
}

public enum TatwoProjectMergeStateMachineV1 {
  /// Pure transition table. Returns nil if the edge is forbidden.
  public static func transition(
    from state: TatwoProjectMergeStateV1,
    event: TatwoProjectMergeEventV1
  ) -> TatwoProjectMergeStateV1? {
    switch (state, event) {
    case (.clean, .acceptClean):
      return .clean
    case (.clean, .detectConflict):
      return .conflict
    case (.clean, .requireReview):
      return .pendingReview

    case (.conflict, .resolveConflictClean):
      return .clean
    case (.conflict, .requireReview):
      return .pendingReview
    case (.conflict, .detectConflict):
      return .conflict

    case (.pendingReview, .approveReview):
      return .clean
    case (.pendingReview, .rejectReviewToConflict),
      (.pendingReview, .reviewFindsConflict),
      (.pendingReview, .detectConflict):
      return .conflict
    case (.pendingReview, .requireReview):
      return .pendingReview

    default:
      return nil
    }
  }

  public static func apply(
    from state: TatwoProjectMergeStateV1,
    event: TatwoProjectMergeEventV1
  ) throws -> TatwoProjectMergeStateV1 {
    guard let next = transition(from: state, event: event) else {
      throw TatwoSharedProjectErrorV1.invalidTransition(
        from: state.rawValue,
        to: event.rawValue)
    }
    return next
  }

  /// Formal shared head may advance only from outcomes that land on `clean`
  /// via accept/resolve/approve — never while still `conflict` or `pending-review`.
  public static func allowsFormalHeadAdvance(_ state: TatwoProjectMergeStateV1) -> Bool {
    state == .clean
  }
}

// MARK: - Offline copy provisional state (status column)

/// Offline-copy local status column (design §4.3 subset used by S1).
public enum TatwoOfflineCopyProvisionalStateV1: String, Codable, Sendable, CaseIterable, Equatable {
  /// Mirror of formal head; no local provisional edits.
  case cleanMirror = "clean_mirror"
  /// Local provisional dirty tree / journal.
  case provisionalDirty = "provisional_dirty"
  /// Merge proposal in flight (not yet a merge result).
  case mergePending = "merge_pending"
  /// Merge result: conflict.
  case conflict
  /// Merge result: pending human/gate review.
  case pendingReview = "pending_review"
}

public enum TatwoOfflineCopyEventV1: String, Codable, Sendable, Equatable {
  case localEdit = "local_edit"
  case submitMergeProposal = "submit_merge_proposal"
  case mergeResultClean = "merge_result_clean"
  case mergeResultConflict = "merge_result_conflict"
  case mergeResultPendingReview = "merge_result_pending_review"
  case clearProvisionalAfterPushback = "clear_provisional_after_pushback"
  case abandonLocal = "abandon_local"
}

public enum TatwoOfflineCopyStateMachineV1 {
  public static func transition(
    from state: TatwoOfflineCopyProvisionalStateV1,
    event: TatwoOfflineCopyEventV1
  ) -> TatwoOfflineCopyProvisionalStateV1? {
    switch (state, event) {
    case (.cleanMirror, .localEdit):
      return .provisionalDirty
    case (.cleanMirror, .abandonLocal):
      return .cleanMirror

    case (.provisionalDirty, .localEdit):
      return .provisionalDirty
    case (.provisionalDirty, .submitMergeProposal):
      return .mergePending
    case (.provisionalDirty, .abandonLocal):
      return .cleanMirror

    case (.mergePending, .mergeResultClean):
      return .cleanMirror
    case (.mergePending, .mergeResultConflict):
      return .conflict
    case (.mergePending, .mergeResultPendingReview):
      return .pendingReview
    case (.mergePending, .localEdit):
      // Further local edits while pending stay provisional dirty branch.
      return .provisionalDirty

    case (.conflict, .localEdit):
      return .provisionalDirty
    case (.conflict, .submitMergeProposal):
      return .mergePending
    case (.conflict, .abandonLocal):
      return .cleanMirror
    case (.conflict, .clearProvisionalAfterPushback):
      return .cleanMirror

    case (.pendingReview, .mergeResultClean),
      (.pendingReview, .clearProvisionalAfterPushback):
      return .cleanMirror
    case (.pendingReview, .mergeResultConflict):
      return .conflict
    case (.pendingReview, .localEdit):
      return .provisionalDirty
    case (.pendingReview, .abandonLocal):
      return .cleanMirror

    default:
      return nil
    }
  }

  public static func apply(
    from state: TatwoOfflineCopyProvisionalStateV1,
    event: TatwoOfflineCopyEventV1
  ) throws -> TatwoOfflineCopyProvisionalStateV1 {
    guard let next = transition(from: state, event: event) else {
      throw TatwoSharedProjectErrorV1.invalidTransition(
        from: state.rawValue,
        to: event.rawValue)
    }
    return next
  }

  /// Status column: edits are provisional (not formal shared truth).
  public static func isProvisional(_ state: TatwoOfflineCopyProvisionalStateV1) -> Bool {
    switch state {
    case .cleanMirror:
      false
    case .provisionalDirty, .mergePending, .conflict, .pendingReview:
      true
    }
  }

  /// Map merge machine result into offline-copy column after writer responds.
  public static func eventForMergeResult(
    _ merge: TatwoProjectMergeStateV1
  ) -> TatwoOfflineCopyEventV1 {
    switch merge {
    case .clean:
      .mergeResultClean
    case .conflict:
      .mergeResultConflict
    case .pendingReview:
      .mergeResultPendingReview
    }
  }
}

// MARK: - S2 seam (verifier mount; not implemented in S1)

/// Frozen interface for S2 read-only verifier mount. S1 does not implement transport.
public enum TatwoSharedProjectVerifierSeamV1 {
  /// Role a device claims when mounting without write authority.
  public static let verifierRole = TatwoSharedProjectMemberRoleV1.verifier

  /// Any formal write API from a verifier must fail-closed with this error.
  public static func denyFormalWrite() -> TatwoSharedProjectErrorV1 {
    .formalWriteDenied("verifier mount is read-only (S2)")
  }
}
