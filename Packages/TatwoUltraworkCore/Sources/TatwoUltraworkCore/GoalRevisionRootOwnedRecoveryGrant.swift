import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Canonical, one-time recovery authority installed by a fresh macOS
/// administrator interaction. The grant is not a reusable issuer or key. It is
/// a single capability object bound to one exact Goal revision transition.
@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionRootOwnedRecoveryGrantBodyV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let grantID: String
  public let receiptID: String
  public let authorizationID: String
  public let challengeID: String
  public let threadID: String
  public let turnID: String
  public let eventID: String
  public let observedRole: String
  public let humanMessageDigest: String
  public let shortCode: String
  public let localUserUID: UInt32
  public let deviceID: String
  public let recoveryReason: String
  public let legacyAppBundleIdentifier: String
  public let legacyAppVersion: String
  public let legacyAppBuild: String
  public let legacyIssuerAvailability: String
  public let legacyUnavailableEvidenceDigest: String
  public let sessionID: String
  public let oldPointerRevisionDigest: String
  public let oldPointerGeneration: UInt64
  public let oldContractID: String
  public let oldGoalID: String
  public let oldGoalRevision: UInt64
  public let oldActivationEpoch: UInt64
  public let oldObjectiveDigest: String
  public let oldReceiptsDigest: String
  public let newContractID: String
  public let newGoalID: String
  public let newGoalRevision: UInt64
  public let newObjectiveDigest: String
  public let topologyDigest: String
  public let capabilityDigest: String
  public let requestedHostScopeDigest: String
  public let allowedOperations: [String]
  public let deniedOperations: [String]
  public let maxUses: UInt64
  public let issuedAt: Date
  public let expiresAt: Date
  public let nonce: String

  init(evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1) {
    self.schema = "TatwoGoalRevisionRootOwnedRecoveryGrantBodyV1"
    self.grantID = evidence.grantID
    self.receiptID = evidence.id
    self.authorizationID = evidence.authorizationID
    self.challengeID = evidence.challengeID
    self.threadID = evidence.threadID
    self.turnID = evidence.turnID
    self.eventID = evidence.eventID
    self.observedRole = evidence.observedRole
    self.humanMessageDigest = evidence.humanMessageDigest
    self.shortCode = evidence.shortCode
    self.localUserUID = evidence.localUserUID
    self.deviceID = evidence.deviceID
    self.recoveryReason = evidence.recoveryReason
    self.legacyAppBundleIdentifier = evidence.legacyAppBundleIdentifier
    self.legacyAppVersion = evidence.legacyAppVersion
    self.legacyAppBuild = evidence.legacyAppBuild
    self.legacyIssuerAvailability = evidence.legacyIssuerAvailability
    self.legacyUnavailableEvidenceDigest =
      evidence.legacyUnavailableEvidenceDigest
    self.sessionID = evidence.sessionID
    self.oldPointerRevisionDigest = evidence.oldPointerRevisionDigest
    self.oldPointerGeneration = evidence.oldPointerGeneration
    self.oldContractID = evidence.oldContractID
    self.oldGoalID = evidence.oldGoalID
    self.oldGoalRevision = evidence.oldGoalRevision
    self.oldActivationEpoch = evidence.oldActivationEpoch
    self.oldObjectiveDigest = evidence.oldObjectiveDigest
    self.oldReceiptsDigest = evidence.oldReceiptsDigest
    self.newContractID = evidence.newContractID
    self.newGoalID = evidence.newGoalID
    self.newGoalRevision = evidence.newGoalRevision
    self.newObjectiveDigest = evidence.newObjectiveDigest
    self.topologyDigest = evidence.topologyDigest
    self.capabilityDigest = evidence.capabilityDigest
    self.requestedHostScopeDigest = evidence.requestedHostScopeDigest
    self.allowedOperations = evidence.allowedOperations
    self.deniedOperations = evidence.deniedOperations
    self.maxUses = evidence.maxUses
    self.issuedAt =
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.wholeSecond(
        evidence.issuedAt)
    self.expiresAt =
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.wholeSecond(
        evidence.expiresAt)
    self.nonce = evidence.nonce
  }

  var digest: String {
    TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.canonicalData([
        schema,
        grantID,
        receiptID,
        authorizationID,
        challengeID,
        threadID,
        turnID,
        eventID,
        observedRole,
        humanMessageDigest,
        shortCode,
        String(localUserUID),
        deviceID,
        recoveryReason,
        legacyAppBundleIdentifier,
        legacyAppVersion,
        legacyAppBuild,
        legacyIssuerAvailability,
        legacyUnavailableEvidenceDigest,
        sessionID,
        oldPointerRevisionDigest,
        String(oldPointerGeneration),
        oldContractID,
        oldGoalID,
        String(oldGoalRevision),
        String(oldActivationEpoch),
        oldObjectiveDigest,
        oldReceiptsDigest,
        newContractID,
        newGoalID,
        String(newGoalRevision),
        newObjectiveDigest,
        topologyDigest,
        capabilityDigest,
        requestedHostScopeDigest,
        allowedOperations.joined(separator: "\u{1f}"),
        deniedOperations.joined(separator: "\u{1f}"),
        String(maxUses),
        String(Int64(issuedAt.timeIntervalSince1970)),
        String(Int64(expiresAt.timeIntervalSince1970)),
        nonce,
      ]))
  }

  func matches(
    _ evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1
  ) -> Bool {
    self == Self(evidence: evidence)
      && evidence.authorityKind
        == TatwoGoalRevisionBootstrapRecoveryEvidenceV1
          .rootOwnedGrantAuthorityKind
      && evidence.hostKeyID == digest
  }
}

@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionRootOwnedRecoveryGrantV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let bodyDigest: String
  public let body: TatwoGoalRevisionRootOwnedRecoveryGrantBodyV1

  init(body: TatwoGoalRevisionRootOwnedRecoveryGrantBodyV1) {
    self.schema = "TatwoGoalRevisionRootOwnedRecoveryGrantV1"
    self.bodyDigest = body.digest
    self.body = body
  }

  var canonicalData: Data {
    get throws {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(self)
    }
  }

  var fileDigest: String {
    get throws {
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(
        try canonicalData)
    }
  }

  static func decodeCanonical(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= 64 * 1024 else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_size")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let value: Self
    do {
      value = try decoder.decode(Self.self, from: data)
    } catch {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_encoding")
    }
    guard value.schema == "TatwoGoalRevisionRootOwnedRecoveryGrantV1",
      value.body.schema
        == "TatwoGoalRevisionRootOwnedRecoveryGrantBodyV1",
      value.bodyDigest == value.body.digest,
      try value.canonicalData == data
    else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_canonical_bytes")
    }
    return value
  }
}

/// Read-only output for the human/admin enrollment gate. Preparing this value
/// never creates a directory, writes a grant, invokes sudo, or mutates Goal
/// state.
@_spi(TatwoBootstrapRecoveryHost)
public struct TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1:
  Sendable, Equatable
{
  public static let productionDirectoryPath =
    "/Library/Application Support/Tatwo Ultrawork/GoalRecoveryGrants/v1"

  public let evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1
  public let grant: TatwoGoalRevisionRootOwnedRecoveryGrantV1
  public let canonicalGrantBytes: Data
  public let targetPath: String
  public let grantFileDigest: String

  public static func prepare(
    evidence draft: TatwoGoalRevisionBootstrapRecoveryEvidenceV1
  ) throws -> Self {
    let body = TatwoGoalRevisionRootOwnedRecoveryGrantBodyV1(
      evidence: draft)
    let evidence = draft.bindingRootOwnedGrant(
      bodyDigest: body.digest)
    guard body.matches(evidence) else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_evidence_binding")
    }
    let grant = TatwoGoalRevisionRootOwnedRecoveryGrantV1(body: body)
    let bytes = try grant.canonicalData
    let fileName = try Self.fileName(bodyDigest: grant.bodyDigest)
    return Self(
      evidence: evidence,
      grant: grant,
      canonicalGrantBytes: bytes,
      targetPath:
        "\(productionDirectoryPath)/\(fileName)",
      grantFileDigest: try grant.fileDigest)
  }

  static func fileName(bodyDigest: String) throws -> String {
    guard
      TatwoGoalRevisionBootstrapRecoveryEvidenceV1.isSHA256Digest(
        bodyDigest)
    else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_body_digest")
    }
    return
      "goal-revision-\(bodyDigest.dropFirst("sha256:".count)).grant"
  }
}

struct TatwoValidatedRootOwnedBootstrapRecoveryGrant: Sendable {
  let grant: TatwoGoalRevisionRootOwnedRecoveryGrantV1
  let fileDigest: String
}

/// Production trust provider for the one-time root-owned recovery grant.
///
/// The production initializer has no path or environment override. Tests may
/// inject a different already-trusted anchor directory and expected uid/gid.
struct TatwoRootOwnedBootstrapRecoveryGrantProvider:
  TatwoBootstrapRecoveryTrustAnchorProviding
{
  private let anchorDirectoryURL: URL
  private let directoryComponents: [String]
  private let expectedOwnerUID: uid_t
  private let expectedFileGroupID: gid_t

  init() {
    self.anchorDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
    self.directoryComponents = [
      "Library",
      "Application Support",
      "Tatwo Ultrawork",
      "GoalRecoveryGrants",
      "v1",
    ]
    self.expectedOwnerUID = 0
    self.expectedFileGroupID = 0
  }

  init(
    anchorDirectoryURL: URL,
    directoryComponents: [String],
    expectedOwnerUID: uid_t,
    expectedGroupID: gid_t
  ) {
    self.anchorDirectoryURL = anchorDirectoryURL
    self.directoryComponents = directoryComponents
    self.expectedOwnerUID = expectedOwnerUID
    self.expectedFileGroupID = expectedGroupID
  }

  func trustedPublicKeyRawRepresentation() throws -> Data {
    throw TatwoHumanGateVerificationError.unavailable
  }

  func trustedRootGrant(
    for evidence: TatwoGoalRevisionBootstrapRecoveryEvidenceV1
  ) throws -> TatwoValidatedRootOwnedBootstrapRecoveryGrant {
    #if canImport(Darwin)
    guard evidence.localUserUID == UInt32(getuid()) else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_local_user")
    }
    let fileName =
      try TatwoGoalRevisionRootOwnedRecoveryGrantPlanV1.fileName(
        bodyDigest: evidence.hostKeyID)
    let rootFD = anchorDirectoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard rootFD >= 0 else {
      throw Self.openError(field: "root_grant_anchor")
    }
    defer { _ = Darwin.close(rootFD) }
    try validateDirectory(
      descriptor: rootFD,
      field: "root_grant_anchor")

    var currentFD = Darwin.dup(rootFD)
    guard currentFD >= 0 else {
      throw TatwoHumanGateVerificationError.unavailable
    }
    defer { _ = Darwin.close(currentFD) }
    for component in directoryComponents {
      guard Self.isSafeComponent(component) else {
        throw TatwoHumanGateVerificationError.invalid(
          "root_grant_path")
      }
      let nextFD = component.withCString { name in
        Darwin.openat(
          currentFD,
          name,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard nextFD >= 0 else {
        throw Self.openError(field: "root_grant_parent")
      }
      do {
        try validateDirectory(
          descriptor: nextFD,
          field: "root_grant_parent")
      } catch {
        _ = Darwin.close(nextFD)
        throw error
      }
      _ = Darwin.close(currentFD)
      currentFD = nextFD
    }

    let fileFD = fileName.withCString { name in
      Darwin.openat(
        currentFD,
        name,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard fileFD >= 0 else {
      throw Self.openError(field: "root_grant_file")
    }
    defer { _ = Darwin.close(fileFD) }
    var status = stat()
    guard Darwin.fstat(fileFD, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == expectedOwnerUID,
      status.st_gid == expectedFileGroupID,
      (status.st_mode & 0o777) == 0o444,
      status.st_nlink == 1,
      status.st_size > 0,
      status.st_size <= 64 * 1024
    else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_file_metadata")
    }
    let data = try Self.readExactly(
      descriptor: fileFD,
      expectedSize: Int(status.st_size))
    let grant = try TatwoGoalRevisionRootOwnedRecoveryGrantV1
      .decodeCanonical(data)
    guard grant.bodyDigest == evidence.hostKeyID,
      grant.body.matches(evidence)
    else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_evidence_binding")
    }
    return TatwoValidatedRootOwnedBootstrapRecoveryGrant(
      grant: grant,
      fileDigest:
        TatwoGoalRevisionBootstrapRecoveryEvidenceV1.digest(data))
    #else
    throw TatwoHumanGateVerificationError.unavailable
    #endif
  }

  #if canImport(Darwin)
  private func validateDirectory(
    descriptor: Int32,
    field: String
  ) throws {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFDIR,
      status.st_uid == expectedOwnerUID,
      (status.st_mode & 0o022) == 0
    else {
      throw TatwoHumanGateVerificationError.invalid(field)
    }
  }

  private static func readExactly(
    descriptor: Int32,
    expectedSize: Int
  ) throws -> Data {
    var result = Data()
    result.reserveCapacity(expectedSize)
    var buffer = [UInt8](repeating: 0, count: min(4096, expectedSize))
    while result.count < expectedSize {
      let remaining = expectedSize - result.count
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(
          descriptor,
          bytes.baseAddress,
          min(bytes.count, remaining))
      }
      if count < 0, errno == EINTR {
        continue
      }
      guard count > 0 else {
        throw TatwoHumanGateVerificationError.invalid(
          "root_grant_short_read")
      }
      result.append(contentsOf: buffer.prefix(count))
    }
    var trailingByte: UInt8 = 0
    let trailingCount = Darwin.read(descriptor, &trailingByte, 1)
    guard trailingCount == 0 else {
      throw TatwoHumanGateVerificationError.invalid(
        "root_grant_trailing_bytes")
    }
    return result
  }

  private static func openError(
    field: String
  ) -> TatwoHumanGateVerificationError {
    if errno == ENOENT || errno == EACCES {
      return .unavailable
    }
    return .invalid(field)
  }
  #endif

  private static func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\0")
  }
}
