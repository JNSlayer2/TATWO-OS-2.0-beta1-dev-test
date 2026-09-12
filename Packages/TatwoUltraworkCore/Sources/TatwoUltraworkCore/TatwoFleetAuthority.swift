import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Signature purposes

/// Fleet control-plane signature purposes (device-trust Ed25519 envelopes).
public enum TatwoFleetSignaturePurposeV1: String, Codable, Sendable, Equatable {
  /// Target-signed capacity/capability report under `fleet/ingest/devices/`.
  case deviceReport = "fleet-device-report"
  /// Origin-signed accepted device view under `fleet/devices/`.
  case device = "fleet-device"
  case queue = "fleet-queue"
  case assignment = "fleet-assignment"
  case commit = "fleet-commit"
  case ledger = "fleet-ledger"
  case schedulerState = "fleet-scheduler-state"
  case superseded = "fleet-superseded"
  /// Origin-signed V1→V2 migration journal / pre-receipt (human-gated only).
  case sealMigration = "fleet-seal-migration"
}

// MARK: - Errors

public enum TatwoFleetAuthorityError: Error, LocalizedError, Sendable, Equatable {
  case missingAuthority(String)
  case signatureRejected(String)
  case staleAuthorityEpoch(current: UInt64, highWater: UInt64)
  case ledgerSequenceRegression(got: UInt64, highWater: UInt64)
  case commitHighWaterWithoutFile(String)
  /// Commit file present but durable high-water marker missing (fail closed).
  case commitFileWithoutHighWater(String)
  case commitHighWaterMismatch(String)
  case forgedOrUnsignedRecord(String)
  case authorityDeviceMismatch(expected: String, got: String)
  case bindingMismatch(String)
  case recordIdentityMismatch(String)

  public var errorDescription: String? {
    switch self {
    case let .missingAuthority(detail):
      return "Fleet authority missing: \(detail)"
    case let .signatureRejected(detail):
      return "Fleet signature rejected: \(detail)"
    case let .staleAuthorityEpoch(current, highWater):
      return "Fleet authority epoch \(current) behind high-water \(highWater)"
    case let .ledgerSequenceRegression(got, highWater):
      return "Fleet ledger sequence \(got) regresses high-water \(highWater)"
    case let .commitHighWaterWithoutFile(id):
      return "Fleet commit high-water present but commit file missing for \(id)"
    case let .commitFileWithoutHighWater(id):
      return "Fleet commit file present but durable high-water marker missing for \(id)"
    case let .commitHighWaterMismatch(id):
      return "Fleet commit high-water mismatch for \(id)"
    case let .forgedOrUnsignedRecord(detail):
      return "Fleet forged or unsigned record: \(detail)"
    case let .authorityDeviceMismatch(expected, got):
      return "Fleet authority device mismatch expected=\(expected) got=\(got)"
    case let .bindingMismatch(detail):
      return "Fleet binding mismatch: \(detail)"
    case let .recordIdentityMismatch(detail):
      return "Fleet record identity mismatch: \(detail)"
    }
  }
}

// MARK: - Record identity (pathname-bound)

/// Canonical identity bound into every fleet control-plane signature.
/// Prevents transplanting a valid signed record onto another pathname/key.
public struct TatwoFleetRecordIdentityV1: Codable, Sendable, Equatable {
  public let recordKind: String
  public let canonicalRelativePath: String
  public let originDeviceID: String
  public let ledgerSequence: UInt64
  public let authorityEpoch: UInt64

  public init(
    recordKind: String,
    canonicalRelativePath: String,
    originDeviceID: String,
    ledgerSequence: UInt64,
    authorityEpoch: UInt64
  ) {
    self.recordKind = recordKind
    self.canonicalRelativePath = Self.normalizeRelativePath(canonicalRelativePath)
    self.originDeviceID = originDeviceID
    self.ledgerSequence = ledgerSequence
    self.authorityEpoch = authorityEpoch
  }

  public init(
    purpose: TatwoFleetSignaturePurposeV1,
    canonicalRelativePath: String,
    originDeviceID: String,
    ledgerSequence: UInt64,
    authorityEpoch: UInt64
  ) {
    self.init(
      recordKind: purpose.rawValue,
      canonicalRelativePath: canonicalRelativePath,
      originDeviceID: originDeviceID,
      ledgerSequence: ledgerSequence,
      authorityEpoch: authorityEpoch)
  }

  public static func normalizeRelativePath(_ path: String) -> String {
    var p = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    while p.contains("//") {
      p = p.replacingOccurrences(of: "//", with: "/")
    }
    return p
  }

  /// Relative path of `fileURL` under `rootURL`, fail closed if outside root.
  public static func relativePath(of fileURL: URL, under rootURL: URL) throws -> String {
    let file = fileURL.standardizedFileURL.path
    let root = rootURL.standardizedFileURL.path
    let rootPrefix = root.hasSuffix("/") ? root : root + "/"
    guard file == root || file.hasPrefix(rootPrefix) else {
      throw TatwoFleetAuthorityError.recordIdentityMismatch(
        "path \(file) not under fleet root \(root)")
    }
    if file == root {
      throw TatwoFleetAuthorityError.recordIdentityMismatch("record path is fleet root")
    }
    return normalizeRelativePath(String(file.dropFirst(rootPrefix.count)))
  }

  /// Derive expected recordID from API purpose + canonical pathname (not envelope).
  public static func expectedRecordID(
    purpose: TatwoFleetSignaturePurposeV1,
    canonicalRelativePath: String,
    ledgerSequence: UInt64 = 0
  ) -> String {
    let path = normalizeRelativePath(canonicalRelativePath)
    switch purpose {
    case .schedulerState:
      return "scheduler-state"
    case .ledger:
      return "ledger-\(ledgerSequence)"
    case .deviceReport, .device, .queue, .assignment, .commit, .superseded, .sealMigration:
      let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
      return base
    }
  }

  public static func expectedRelativePath(
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    ledgerSequence: UInt64 = 0
  ) -> String {
    let safe = TatwoLoopPathComponent.sanitize(recordID)
    switch purpose {
    case .deviceReport:
      return "ingest/devices/\(safe).json"
    case .device:
      return "devices/\(safe).json"
    case .queue:
      return "queue/\(safe).json"
    case .assignment:
      return "assignments/\(safe).json"
    case .commit:
      return "commits/\(safe).json"
    case .ledger:
      return "ledger/\(String(format: "%020llu", ledgerSequence)).json"
    case .schedulerState:
      return "scheduler-state.json"
    case .superseded:
      return "superseded/\(safe).json"
    case .sealMigration:
      return "receipts/\(safe).json"
    }
  }
}

/// Material whose digest is signed (identity + recordID + body digest).
/// Body alone is never signed; `recordID` is bound into the seal so it cannot
/// redirect high-water lookups without invalidating the signature.
///
/// Production seal schema is **V2**. V1 material is accepted only by the
/// human-gated offline migration path — never by the general loader.
public struct TatwoFleetSealMaterialV2: Codable, Sendable, Equatable {
  public let schema: String
  public let recordKind: String
  public let canonicalRelativePath: String
  public let originDeviceID: String
  public let ledgerSequence: UInt64
  public let authorityEpoch: UInt64
  public let recordID: String
  public let bodyDigest: String

  public static let schemaName = "TatwoFleetSealMaterialV2"
  /// Migration-only legacy schema (general loader rejects).
  public static let legacySchemaName = "TatwoFleetSealMaterialV1"

  public init(
    schema: String = TatwoFleetSealMaterialV2.schemaName,
    identity: TatwoFleetRecordIdentityV1,
    recordID: String,
    bodyDigest: String
  ) {
    self.schema = schema
    self.recordKind = identity.recordKind
    self.canonicalRelativePath = identity.canonicalRelativePath
    self.originDeviceID = identity.originDeviceID
    self.ledgerSequence = identity.ledgerSequence
    self.authorityEpoch = identity.authorityEpoch
    self.recordID = recordID
    self.bodyDigest = bodyDigest
  }

  public var identity: TatwoFleetRecordIdentityV1 {
    TatwoFleetRecordIdentityV1(
      recordKind: recordKind,
      canonicalRelativePath: canonicalRelativePath,
      originDeviceID: originDeviceID,
      ledgerSequence: ledgerSequence,
      authorityEpoch: authorityEpoch)
  }
}

/// Backward-compatible name for call sites still using the V1 type alias.
public typealias TatwoFleetSealMaterialV1 = TatwoFleetSealMaterialV2

// MARK: - Signed envelope

/// Origin/target signed control-plane envelope. Authorization signs
/// `TatwoFleetSealMaterialV2` (identity + recordID + bodyDigest), not bare body bytes.
///
/// Production envelope schema is **V2**. V1 envelopes are rejected by the general
/// loader and may only be re-signed via human-gated offline migration.
public struct TatwoFleetSignedEnvelopeV1: Codable, Sendable, Equatable {
  public let schema: String
  public let purpose: String
  public let authorityEpoch: UInt64
  public let originDeviceID: String
  public let ledgerSequence: UInt64
  public let recordID: String
  public let recordKind: String
  public let canonicalRelativePath: String
  public let bodyDigest: String
  public let body: Data
  public let authorization: TatwoDeviceSignatureV1

  public static let schemaName = "TatwoFleetSignedEnvelopeV2"
  /// Migration-only legacy schema (general loader rejects).
  public static let legacySchemaName = "TatwoFleetSignedEnvelopeV1"

  public init(
    schema: String = TatwoFleetSignedEnvelopeV1.schemaName,
    purpose: TatwoFleetSignaturePurposeV1,
    authorityEpoch: UInt64,
    originDeviceID: String,
    ledgerSequence: UInt64,
    recordID: String,
    canonicalRelativePath: String,
    body: Data,
    authorization: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.purpose = purpose.rawValue
    self.authorityEpoch = authorityEpoch
    self.originDeviceID = originDeviceID
    self.ledgerSequence = ledgerSequence
    self.recordID = recordID
    self.recordKind = purpose.rawValue
    self.canonicalRelativePath = TatwoFleetRecordIdentityV1.normalizeRelativePath(
      canonicalRelativePath)
    self.bodyDigest = TatwoLoopJobDigest.sha256(body)
    self.body = body
    self.authorization = authorization
  }

  public var recordIdentity: TatwoFleetRecordIdentityV1 {
    TatwoFleetRecordIdentityV1(
      recordKind: recordKind,
      canonicalRelativePath: canonicalRelativePath,
      originDeviceID: originDeviceID,
      ledgerSequence: ledgerSequence,
      authorityEpoch: authorityEpoch)
  }

  public func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
    try TatwoFleetOriginAuthority.decodeBody(type, from: body)
  }
}

/// Append-only origin ledger entry (one sequence number per control-plane mutation).
public struct TatwoFleetLedgerEntryV1: Codable, Sendable, Equatable {
  public let schema: String
  public let ledgerSequence: UInt64
  public let authorityEpoch: UInt64
  public let originDeviceID: String
  public let purpose: String
  public let recordID: String
  public let bodyDigest: String
  public let recordedAt: Date

  public init(
    schema: String = "TatwoFleetLedgerEntryV1",
    ledgerSequence: UInt64,
    authorityEpoch: UInt64,
    originDeviceID: String,
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    bodyDigest: String,
    recordedAt: Date
  ) {
    self.schema = schema
    self.ledgerSequence = ledgerSequence
    self.authorityEpoch = authorityEpoch
    self.originDeviceID = originDeviceID
    self.purpose = purpose.rawValue
    self.recordID = recordID
    self.bodyDigest = bodyDigest
    self.recordedAt = recordedAt
  }
}

/// Durable logical-commit high-water (independent of deletable commit files).
public struct TatwoFleetCommitHighWaterV1: Codable, Sendable, Equatable {
  public let schema: String
  public let logicalJobID: String
  public let ledgerSequence: UInt64
  public let authorityEpoch: UInt64
  public let originDeviceID: String
  public let winningJobID: String
  public let winningDispatchNonce: String
  public let jobCanonicalDigest: String
  public let commitDigest: String
  public let committedAt: Date

  public init(
    schema: String = "TatwoFleetCommitHighWaterV1",
    logicalJobID: String,
    ledgerSequence: UInt64,
    authorityEpoch: UInt64,
    originDeviceID: String,
    winningJobID: String,
    winningDispatchNonce: String,
    jobCanonicalDigest: String,
    commitDigest: String,
    committedAt: Date
  ) {
    self.schema = schema
    self.logicalJobID = logicalJobID
    self.ledgerSequence = ledgerSequence
    self.authorityEpoch = authorityEpoch
    self.originDeviceID = originDeviceID
    self.winningJobID = winningJobID
    self.winningDispatchNonce = winningDispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.commitDigest = commitDigest
    self.committedAt = committedAt
  }
}

public struct TatwoFleetAuthorityHighWaterV1: Codable, Sendable, Equatable {
  public let schema: String
  public let authorityEpoch: UInt64
  public let ledgerSequence: UInt64
  public let originDeviceID: String
  public let updatedAt: Date

  public init(
    schema: String = "TatwoFleetAuthorityHighWaterV1",
    authorityEpoch: UInt64,
    ledgerSequence: UInt64,
    originDeviceID: String,
    updatedAt: Date
  ) {
    self.schema = schema
    self.authorityEpoch = authorityEpoch
    self.ledgerSequence = ledgerSequence
    self.originDeviceID = originDeviceID
    self.updatedAt = updatedAt
  }
}

/// Per-pathname current-state high-water: blocks same-path envelope replay.
/// Authority key is immutable `(purpose, canonicalRelativePath)` — never derived
/// from envelope-declared `recordID` (which is still stored for binding checks).
public struct TatwoFleetPathHighWaterV1: Codable, Sendable, Equatable {
  public let schema: String
  public let purpose: String
  public let canonicalRelativePath: String
  public let recordID: String
  public let ledgerSequence: UInt64
  public let bodyDigest: String
  public let authorityEpoch: UInt64
  public let updatedAt: Date

  public init(
    schema: String = "TatwoFleetPathHighWaterV1",
    purpose: String,
    canonicalRelativePath: String,
    recordID: String,
    ledgerSequence: UInt64,
    bodyDigest: String,
    authorityEpoch: UInt64,
    updatedAt: Date
  ) {
    self.schema = schema
    self.purpose = purpose
    self.canonicalRelativePath = TatwoFleetRecordIdentityV1.normalizeRelativePath(
      canonicalRelativePath)
    self.recordID = recordID
    self.ledgerSequence = ledgerSequence
    self.bodyDigest = bodyDigest
    self.authorityEpoch = authorityEpoch
    self.updatedAt = updatedAt
  }

  public var key: String {
    Self.makeKey(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath)
  }

  public static func makeKey(
    purpose: String,
    canonicalRelativePath: String
  ) -> String {
    let path = TatwoFleetRecordIdentityV1.normalizeRelativePath(canonicalRelativePath)
    return "\(purpose)|\(path)"
  }
}

// MARK: - High-water anchor

/// Anti-rollback anchors for fleet authority epoch, ledger sequence, logical commits,
/// and per-pathname current-state envelopes.
public protocol TatwoFleetHighWaterAnchor: Sendable {
  func loadAuthorityHighWater() throws -> TatwoFleetAuthorityHighWaterV1?
  func storeAuthorityHighWater(_ value: TatwoFleetAuthorityHighWaterV1) throws
  func loadCommitHighWater(logicalJobID: String) throws -> TatwoFleetCommitHighWaterV1?
  /// Create-only; matching prior is OK; mismatch throws.
  func createCommitHighWater(_ value: TatwoFleetCommitHighWaterV1) throws
  /// Latest accepted envelope identity for a control-plane pathname.
  /// Keyed only by `(purpose, canonicalRelativePath)` — not envelope recordID.
  func loadPathHighWater(
    purpose: String,
    canonicalRelativePath: String
  ) throws -> TatwoFleetPathHighWaterV1?
  /// Monotonic store: sequence may only rise; equal sequence requires identical digest.
  func storePathHighWater(_ value: TatwoFleetPathHighWaterV1) throws
}

/// File-backed fleet high-water (tests + optional cache). Layout under fleet root:
/// `high-water/authority-high-water.json`, `high-water/commits/<logical>.json`.
///
/// Production authority must use `TatwoFleetKeychainHighWaterAnchor` (or the
/// caching wrapper). File alone is not an anti-rollback boundary under the
/// fleet threat model (files can be deleted/restored).
public struct TatwoFleetFileHighWaterAnchor: TatwoFleetHighWaterAnchor {
  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  public static func underFleetRoot(_ fleetRoot: URL) -> TatwoFleetFileHighWaterAnchor {
    TatwoFleetFileHighWaterAnchor(
      rootURL: fleetRoot.appendingPathComponent("high-water", isDirectory: true))
  }

  public func loadAuthorityHighWater() throws -> TatwoFleetAuthorityHighWaterV1? {
    try loadJSON(TatwoFleetAuthorityHighWaterV1.self, from: authorityURL)
  }

  public func storeAuthorityHighWater(_ value: TatwoFleetAuthorityHighWaterV1) throws {
    try ensureRoot()
    if let prior = try loadAuthorityHighWater() {
      if value.authorityEpoch < prior.authorityEpoch {
        throw TatwoFleetAuthorityError.staleAuthorityEpoch(
          current: value.authorityEpoch, highWater: prior.authorityEpoch)
      }
      if value.ledgerSequence < prior.ledgerSequence {
        throw TatwoFleetAuthorityError.ledgerSequenceRegression(
          got: value.ledgerSequence, highWater: prior.ledgerSequence)
      }
      if prior.originDeviceID != value.originDeviceID, prior.ledgerSequence > 0 {
        throw TatwoFleetAuthorityError.authorityDeviceMismatch(
          expected: prior.originDeviceID, got: value.originDeviceID)
      }
    }
    try TatwoAtomicFile.write(try Self.encode(value), to: authorityURL)
  }

  public func loadCommitHighWater(logicalJobID: String) throws -> TatwoFleetCommitHighWaterV1? {
    try loadJSON(TatwoFleetCommitHighWaterV1.self, from: commitURL(logicalJobID))
  }

  public func createCommitHighWater(_ value: TatwoFleetCommitHighWaterV1) throws {
    try ensureRoot()
    let url = commitURL(value.logicalJobID)
    let data = try Self.encode(value)
    try TatwoCreateOnlyFile.write(data, to: url) {
      guard let prior = try loadCommitHighWater(logicalJobID: value.logicalJobID) else {
        throw TatwoFleetAuthorityError.commitHighWaterMismatch(value.logicalJobID)
      }
      guard Self.commitMatches(prior, value) else {
        throw TatwoFleetAuthorityError.commitHighWaterMismatch(value.logicalJobID)
      }
    }
  }

  public func loadPathHighWater(
    purpose: String,
    canonicalRelativePath: String
  ) throws -> TatwoFleetPathHighWaterV1? {
    try loadJSON(TatwoFleetPathHighWaterV1.self, from: pathURL(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath))
  }

  public func storePathHighWater(_ value: TatwoFleetPathHighWaterV1) throws {
    try ensureRoot()
    try FileManager.default.createDirectory(
      at: pathsDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if let prior = try loadPathHighWater(
      purpose: value.purpose,
      canonicalRelativePath: value.canonicalRelativePath)
    {
      if value.ledgerSequence < prior.ledgerSequence {
        throw TatwoFleetAuthorityError.ledgerSequenceRegression(
          got: value.ledgerSequence, highWater: prior.ledgerSequence)
      }
      if value.ledgerSequence == prior.ledgerSequence {
        guard value.bodyDigest == prior.bodyDigest,
          value.authorityEpoch == prior.authorityEpoch,
          value.recordID == prior.recordID
        else {
          throw TatwoFleetAuthorityError.recordIdentityMismatch(
            "path high-water digest/epoch mismatch at \(value.canonicalRelativePath)#\(value.ledgerSequence)")
        }
        return
      }
    }
    try TatwoAtomicFile.write(
      try Self.encode(value),
      to: pathURL(
        purpose: value.purpose,
        canonicalRelativePath: value.canonicalRelativePath))
  }

  /// Test helper: wipe authority + commit markers (simulates attacker deleting files).
  public func dangerousTestOnlyDeleteAll() throws {
    if FileManager.default.fileExists(atPath: rootURL.path) {
      try FileManager.default.removeItem(at: rootURL)
    }
  }

  /// Test helper: drop only path high-water markers (global HW / commits retained).
  public func dangerousTestOnlyDeletePathMarkers() throws {
    if FileManager.default.fileExists(atPath: pathsDirectory.path) {
      try FileManager.default.removeItem(at: pathsDirectory)
    }
  }

  fileprivate static func commitMatches(
    _ prior: TatwoFleetCommitHighWaterV1, _ value: TatwoFleetCommitHighWaterV1
  ) -> Bool {
    prior.logicalJobID == value.logicalJobID
      && prior.winningJobID == value.winningJobID
      && prior.winningDispatchNonce == value.winningDispatchNonce
      && prior.jobCanonicalDigest == value.jobCanonicalDigest
      && prior.commitDigest == value.commitDigest
      && prior.ledgerSequence == value.ledgerSequence
      && prior.authorityEpoch == value.authorityEpoch
      && prior.originDeviceID == value.originDeviceID
  }

  private var authorityURL: URL {
    rootURL.appendingPathComponent("authority-high-water.json")
  }

  private var pathsDirectory: URL {
    rootURL.appendingPathComponent("paths", isDirectory: true)
  }

  private func commitURL(_ logicalJobID: String) -> URL {
    rootURL
      .appendingPathComponent("commits", isDirectory: true)
      .appendingPathComponent("\(TatwoLoopPathComponent.sanitize(logicalJobID)).json")
  }

  private func pathURL(
    purpose: String,
    canonicalRelativePath: String
  ) -> URL {
    let key = TatwoFleetPathHighWaterV1.makeKey(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath)
    let digest = TatwoLoopJobDigest.sha256(Data(key.utf8))
    return pathsDirectory.appendingPathComponent("\(digest).json")
  }

  private func ensureRoot() throws {
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("commits", isDirectory: true),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      at: pathsDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
}

// MARK: Keychain high-water (production authority)

/// Production fleet high-water: create-only / monotonic markers in Keychain.
/// Mirrors loop global anti-rollback (`TatwoLoopGlobalAntiRollbackKeychainAnchor`).
public struct TatwoFleetKeychainHighWaterAnchor: TatwoFleetHighWaterAnchor {
  public static let defaultService = "ai.tatwo.ultrawork.fleet-high-water"

  private let serviceName: String
  private let hostScope: String

  public init(
    originDeviceID: String,
    service: String = Self.defaultService
  ) {
    self.serviceName = service
    self.hostScope = originDeviceID.replacingOccurrences(of: ":", with: "_")
  }

  /// Injectable service+scope for isolation in unit tests.
  public init(service: String, hostScope: String) {
    self.serviceName = service
    self.hostScope = hostScope.replacingOccurrences(of: ":", with: "_")
  }

  public func loadAuthorityHighWater() throws -> TatwoFleetAuthorityHighWaterV1? {
    // Prefer non-downgradable max markers. Individual per-value markers are
    // audit residue only — deleting them must not lower high-water.
    let epochMax = try loadMonotonicMax(account: epochMaxAccount())
    let seqMax = try loadMonotonicMax(account: ledgerMaxAccount())
    // Migration: if max accounts are missing, fall back to scanning residue markers
    // once, then re-seal the max so subsequent deletes cannot regress.
    let epochScan = try maxMarker(prefix: epochPrefix())
    let seqScan = try maxMarker(prefix: ledgerPrefix())
    let epoch = max(epochMax, epochScan)
    let seq = max(seqMax, seqScan)
    guard epoch > 0 || seq > 0 else { return nil }
    if epoch > epochMax {
      try raiseMonotonicMax(account: epochMaxAccount(), value: epoch)
    }
    if seq > seqMax {
      try raiseMonotonicMax(account: ledgerMaxAccount(), value: seq)
    }
    let origin = try loadOriginBinding() ?? hostScope
    return TatwoFleetAuthorityHighWaterV1(
      authorityEpoch: epoch == 0 ? 1 : epoch,
      ledgerSequence: seq,
      originDeviceID: origin,
      updatedAt: Date())
  }

  public func storeAuthorityHighWater(_ value: TatwoFleetAuthorityHighWaterV1) throws {
    if let prior = try loadAuthorityHighWater() {
      if value.authorityEpoch < prior.authorityEpoch {
        throw TatwoFleetAuthorityError.staleAuthorityEpoch(
          current: value.authorityEpoch, highWater: prior.authorityEpoch)
      }
      if value.ledgerSequence < prior.ledgerSequence {
        throw TatwoFleetAuthorityError.ledgerSequenceRegression(
          got: value.ledgerSequence, highWater: prior.ledgerSequence)
      }
      if prior.originDeviceID != value.originDeviceID, prior.ledgerSequence > 0 {
        throw TatwoFleetAuthorityError.authorityDeviceMismatch(
          expected: prior.originDeviceID, got: value.originDeviceID)
      }
    }
    try bindOrigin(value.originDeviceID)
    // Per-value markers (best-effort audit). Authority is the monotonic max accounts.
    try createMarker(account: epochAccount(value.authorityEpoch), payload: "\(value.authorityEpoch)")
    try createMarker(account: ledgerAccount(value.ledgerSequence), payload: "\(value.ledgerSequence)")
    try raiseMonotonicMax(account: epochMaxAccount(), value: value.authorityEpoch)
    try raiseMonotonicMax(account: ledgerMaxAccount(), value: value.ledgerSequence)
  }

  public func loadCommitHighWater(logicalJobID: String) throws -> TatwoFleetCommitHighWaterV1? {
    try keychainLoad(account: commitAccount(logicalJobID))
  }

  public func createCommitHighWater(_ value: TatwoFleetCommitHighWaterV1) throws {
    let account = commitAccount(value.logicalJobID)
    let data = try Self.encode(value)
    try keychainCreateOnly(account: account, data: data) {
      guard let prior: TatwoFleetCommitHighWaterV1 = try keychainLoad(account: account) else {
        throw TatwoFleetAuthorityError.commitHighWaterMismatch(value.logicalJobID)
      }
      guard TatwoFleetFileHighWaterAnchor.commitMatches(prior, value) else {
        throw TatwoFleetAuthorityError.commitHighWaterMismatch(value.logicalJobID)
      }
    }
  }

  public func loadPathHighWater(
    purpose: String,
    canonicalRelativePath: String
  ) throws -> TatwoFleetPathHighWaterV1? {
    try keychainLoad(account: pathAccount(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath))
  }

  public func storePathHighWater(_ value: TatwoFleetPathHighWaterV1) throws {
    let account = pathAccount(
      purpose: value.purpose,
      canonicalRelativePath: value.canonicalRelativePath)
    if let prior: TatwoFleetPathHighWaterV1 = try keychainLoad(account: account) {
      if value.ledgerSequence < prior.ledgerSequence {
        throw TatwoFleetAuthorityError.ledgerSequenceRegression(
          got: value.ledgerSequence, highWater: prior.ledgerSequence)
      }
      if value.ledgerSequence == prior.ledgerSequence {
        guard value.bodyDigest == prior.bodyDigest,
          value.authorityEpoch == prior.authorityEpoch,
          value.recordID == prior.recordID
        else {
          throw TatwoFleetAuthorityError.recordIdentityMismatch(
            "path high-water digest/epoch mismatch at \(value.canonicalRelativePath)#\(value.ledgerSequence)")
        }
        return
      }
      try keychainUpdate(account: account, data: try Self.encode(value))
      return
    }
    let data = try Self.encode(value)
    try keychainCreateOnly(account: account, data: data) {
      // Race: another writer created first — re-check monotonic rules.
      guard let raced: TatwoFleetPathHighWaterV1 = try keychainLoad(account: account) else {
        throw TatwoFleetAuthorityError.missingAuthority("path high-water race missing")
      }
      if value.ledgerSequence < raced.ledgerSequence {
        throw TatwoFleetAuthorityError.ledgerSequenceRegression(
          got: value.ledgerSequence, highWater: raced.ledgerSequence)
      }
      if value.ledgerSequence == raced.ledgerSequence {
        guard value.bodyDigest == raced.bodyDigest,
          value.authorityEpoch == raced.authorityEpoch,
          value.recordID == raced.recordID
        else {
          throw TatwoFleetAuthorityError.recordIdentityMismatch(
            "path high-water race digest mismatch at \(value.canonicalRelativePath)")
        }
        return
      }
      try keychainUpdate(account: account, data: data)
    }
  }

  /// Test helper: delete all markers for this scope (requires unique test service).
  public func dangerousTestOnlyDeleteAllMarkers() throws {
    #if canImport(Security)
    for account in try listAccounts(prefix: "fleet:") {
      if account.contains(":\(hostScope):") || account.contains(":\(hostScope)") {
        // Match both `:<scope>:` residue markers and `:<scope>:global` max accounts.
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: serviceName,
          kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
      }
    }
    #endif
  }

  /// Test helper: delete per-value epoch/ledger residue markers while keeping max accounts.
  /// Used to prove high-water does not regress when individual markers are wiped.
  public func dangerousTestOnlyDeletePerValueMarkersKeepingMax() throws {
    #if canImport(Security)
    let epochMax = epochMaxAccount()
    let ledgerMax = ledgerMaxAccount()
    for account in try listAccounts(prefix: "fleet:") {
      guard account.contains(":\(hostScope):") || account.contains(":\(hostScope)") else {
        continue
      }
      if account == epochMax || account == ledgerMax || account == originAccount() {
        continue
      }
      // Keep commit markers; only wipe per-value epoch/ledger residue.
      if account.hasPrefix(epochPrefix()) || account.hasPrefix(ledgerPrefix()) {
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: serviceName,
          kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
      }
    }
    #endif
  }

  // MARK: account naming

  private func epochPrefix() -> String { "fleet:epoch:\(hostScope):" }
  private func ledgerPrefix() -> String { "fleet:ledger:\(hostScope):" }
  private func epochAccount(_ epoch: UInt64) -> String {
    "fleet:epoch:\(hostScope):\(epoch):global"
  }
  private func ledgerAccount(_ seq: UInt64) -> String {
    "fleet:ledger:\(hostScope):\(seq):global"
  }
  /// Non-deletable-by-regression max: deleting individual epoch markers must not lower this.
  private func epochMaxAccount() -> String {
    "fleet:epoch-max:\(hostScope):global"
  }
  /// Non-deletable-by-regression max: deleting individual ledger markers must not lower this.
  private func ledgerMaxAccount() -> String {
    "fleet:ledger-max:\(hostScope):global"
  }
  private func commitAccount(_ logicalJobID: String) -> String {
    "fleet:commit:\(hostScope):\(TatwoLoopPathComponent.sanitize(logicalJobID)):global"
  }
  private func pathAccount(
    purpose: String,
    canonicalRelativePath: String
  ) -> String {
    let key = TatwoFleetPathHighWaterV1.makeKey(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath)
    let digest = TatwoLoopJobDigest.sha256(Data(key.utf8))
    return "fleet:path:\(hostScope):\(digest):global"
  }
  private func originAccount() -> String {
    "fleet:origin:\(hostScope):global"
  }

  private func bindOrigin(_ originDeviceID: String) throws {
    let data = Data(originDeviceID.utf8)
    try keychainCreateOnly(account: originAccount(), data: data) {
      guard let prior = try keychainLoadData(account: originAccount()),
        let text = String(data: prior, encoding: .utf8),
        text == originDeviceID
      else {
        throw TatwoFleetAuthorityError.authorityDeviceMismatch(
          expected: originDeviceID, got: "bound-mismatch")
      }
    }
  }

  private func loadOriginBinding() throws -> String? {
    guard let data = try keychainLoadData(account: originAccount()) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func createMarker(account: String, payload: String) throws {
    try keychainCreateOnly(account: account, data: Data(payload.utf8)) {
      // Matching marker already present is fine.
    }
  }

  private func loadMonotonicMax(account: String) throws -> UInt64 {
    guard let data = try keychainLoadData(account: account),
      let text = String(data: data, encoding: .utf8),
      let value = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      return 0
    }
    return value
  }

  /// Raise a single max account; never lowers. Create if missing; update if higher.
  private func raiseMonotonicMax(account: String, value: UInt64) throws {
    let prior = try loadMonotonicMax(account: account)
    if value < prior {
      throw TatwoFleetAuthorityError.ledgerSequenceRegression(
        got: value, highWater: prior)
    }
    if value == prior, prior > 0 {
      return
    }
    let payload = Data("\(value)".utf8)
    if prior == 0 {
      try keychainCreateOnly(account: account, data: payload) {
        // Race: another writer may have created; re-check and update if needed.
        let raced = try loadMonotonicMax(account: account)
        if value < raced {
          throw TatwoFleetAuthorityError.ledgerSequenceRegression(
            got: value, highWater: raced)
        }
        if value > raced {
          try keychainUpdate(account: account, data: payload)
        }
      }
      return
    }
    try keychainUpdate(account: account, data: payload)
  }

  private func maxMarker(prefix: String) throws -> UInt64 {
    var maxValue: UInt64 = 0
    for account in try listAccounts(prefix: prefix) {
      // fleet:epoch:<host>:<N>:global  (skip *-max: accounts — different prefix)
      let parts = account.split(separator: ":")
      guard parts.count >= 4, parts.last == "global",
        let n = UInt64(parts[parts.count - 2])
      else { continue }
      if n > maxValue { maxValue = n }
    }
    return maxValue
  }

  private func keychainLoad<T: Decodable>(account: String) throws -> T? {
    guard let data = try keychainLoadData(account: account) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  }

  private func keychainLoadData(account: String) throws -> Data? {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      // Never block on auth UI in headless/agent runners.
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else {
      throw TatwoFleetAuthorityError.missingAuthority(
        "keychain read status \(status) account \(account)")
    }
    return data
    #else
    throw TatwoFleetAuthorityError.missingAuthority("keychain unavailable")
    #endif
  }

  private func keychainCreateOnly(
    account: String, data: Data, onDuplicate: () throws -> Void
  ) throws {
    #if canImport(Security)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      // Fail closed immediately if the environment cannot write without UI.
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecSuccess { return }
    if status == errSecDuplicateItem {
      try onDuplicate()
      return
    }
    throw TatwoFleetAuthorityError.missingAuthority(
      "keychain create-only add status \(status) account \(account)")
    #else
    throw TatwoFleetAuthorityError.missingAuthority("keychain unavailable")
    #endif
  }

  private func keychainUpdate(account: String, data: Data) throws {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    let attrs: [String: Any] = [
      kSecValueData as String: data,
    ]
    let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    if status == errSecSuccess { return }
    if status == errSecItemNotFound {
      // Create if missing (no regression path — caller already checked).
      try keychainCreateOnly(account: account, data: data) {
        // Duplicate after race: update again.
        let retry = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard retry == errSecSuccess else {
          throw TatwoFleetAuthorityError.missingAuthority(
            "keychain update-after-race status \(retry) account \(account)")
        }
      }
      return
    }
    throw TatwoFleetAuthorityError.missingAuthority(
      "keychain update status \(status) account \(account)")
    #else
    throw TatwoFleetAuthorityError.missingAuthority("keychain unavailable")
    #endif
  }

  private func listAccounts(prefix: String) throws -> [String] {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else {
      throw TatwoFleetAuthorityError.missingAuthority("keychain list status \(status)")
    }
    guard let items = value as? [[String: Any]] else {
      throw TatwoFleetAuthorityError.missingAuthority("keychain list unexpected shape")
    }
    var accounts: [String] = []
    for item in items {
      guard let account = item[kSecAttrAccount as String] as? String else { continue }
      if account.hasPrefix(prefix) {
        accounts.append(account)
      }
    }
    return accounts
    #else
    throw TatwoFleetAuthorityError.missingAuthority("keychain unavailable")
    #endif
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
}

/// Durable authority + optional file cache. **Authority is durable**; file is cache only.
/// Missing cache with durable commit present is not a reset — loaders must fail closed.
public struct TatwoFleetCachingHighWaterAnchor: TatwoFleetHighWaterAnchor {
  public let durable: any TatwoFleetHighWaterAnchor
  public let fileCache: TatwoFleetFileHighWaterAnchor?

  public init(
    durable: any TatwoFleetHighWaterAnchor,
    fileCache: TatwoFleetFileHighWaterAnchor? = nil
  ) {
    self.durable = durable
    self.fileCache = fileCache
  }

  public static func production(
    originDeviceID: String,
    fleetRoot: URL,
    keychainService: String = TatwoFleetKeychainHighWaterAnchor.defaultService
  ) -> TatwoFleetCachingHighWaterAnchor {
    TatwoFleetCachingHighWaterAnchor(
      durable: TatwoFleetKeychainHighWaterAnchor(
        originDeviceID: originDeviceID, service: keychainService),
      fileCache: .underFleetRoot(fleetRoot))
  }

  public func loadAuthorityHighWater() throws -> TatwoFleetAuthorityHighWaterV1? {
    if let durableValue = try durable.loadAuthorityHighWater() {
      return durableValue
    }
    // No durable value: ignore file cache (cannot elevate from deletable file alone).
    return nil
  }

  public func storeAuthorityHighWater(_ value: TatwoFleetAuthorityHighWaterV1) throws {
    try durable.storeAuthorityHighWater(value)
    // Best-effort cache; durable is authority.
    try? fileCache?.storeAuthorityHighWater(value)
  }

  public func loadCommitHighWater(logicalJobID: String) throws -> TatwoFleetCommitHighWaterV1? {
    if let durableValue = try durable.loadCommitHighWater(logicalJobID: logicalJobID) {
      return durableValue
    }
    // Do not accept file-only commit high-water (rollback via durable wipe is N/A;
    // file alone must not authorize).
    return nil
  }

  public func createCommitHighWater(_ value: TatwoFleetCommitHighWaterV1) throws {
    try durable.createCommitHighWater(value)
    try? fileCache?.createCommitHighWater(value)
  }

  public func loadPathHighWater(
    purpose: String,
    canonicalRelativePath: String
  ) throws -> TatwoFleetPathHighWaterV1? {
    if let durableValue = try durable.loadPathHighWater(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath)
    {
      return durableValue
    }
    // Do not elevate from deletable file cache alone.
    return nil
  }

  public func storePathHighWater(_ value: TatwoFleetPathHighWaterV1) throws {
    try durable.storePathHighWater(value)
    try? fileCache?.storePathHighWater(value)
  }
}

// MARK: - Origin authority

/// Origin-only fleet control-plane authority: signs queue/assignment/commit/ledger,
/// enforces authority epoch fencing, and maintains append-only ledger + high-water.
public struct TatwoFleetOriginAuthority: Sendable {
  public let originDeviceID: String
  public let authorityEpoch: UInt64
  public let trust: TatwoLoopJobChannelTrust
  public let highWater: any TatwoFleetHighWaterAnchor
  public let now: @Sendable () -> Date

  public init(
    originDeviceID: String,
    authorityEpoch: UInt64 = 1,
    trust: TatwoLoopJobChannelTrust,
    highWater: any TatwoFleetHighWaterAnchor,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.originDeviceID = originDeviceID
    self.authorityEpoch = authorityEpoch
    self.trust = trust
    self.highWater = highWater
    self.now = now
  }

  /// Fail closed when this process holds a stale epoch relative to durable high-water.
  public func assertWritable() throws {
    guard trust.localIdentity.deviceID == originDeviceID else {
      throw TatwoFleetAuthorityError.authorityDeviceMismatch(
        expected: originDeviceID, got: trust.localIdentity.deviceID)
    }
    if let hw = try highWater.loadAuthorityHighWater() {
      if hw.originDeviceID != originDeviceID, hw.ledgerSequence > 0 {
        throw TatwoFleetAuthorityError.authorityDeviceMismatch(
          expected: hw.originDeviceID, got: originDeviceID)
      }
      if authorityEpoch < hw.authorityEpoch {
        throw TatwoFleetAuthorityError.staleAuthorityEpoch(
          current: authorityEpoch, highWater: hw.authorityEpoch)
      }
    }
  }

  public func nextLedgerSequence() throws -> UInt64 {
    try assertWritable()
    let current = try highWater.loadAuthorityHighWater()?.ledgerSequence ?? 0
    return current + 1
  }

  public func sealEncodable<T: Encodable>(
    _ value: T,
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    ledgerSequence: UInt64,
    canonicalRelativePath: String
  ) throws -> TatwoFleetSignedEnvelopeV1 {
    try seal(
      body: try Self.encodeBody(value),
      purpose: purpose,
      recordID: recordID,
      ledgerSequence: ledgerSequence,
      canonicalRelativePath: canonicalRelativePath)
  }

  public func seal(
    body: Data,
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    ledgerSequence: UInt64,
    canonicalRelativePath: String
  ) throws -> TatwoFleetSignedEnvelopeV1 {
    try assertWritable()
    let identity = TatwoFleetRecordIdentityV1(
      purpose: purpose,
      canonicalRelativePath: canonicalRelativePath,
      originDeviceID: originDeviceID,
      ledgerSequence: ledgerSequence,
      authorityEpoch: authorityEpoch)
    return try sealPreservingIdentity(
      body: body, purpose: purpose, recordID: recordID, identity: identity)
  }

  /// Seal with an explicit identity (migration re-sign keeps legacy sequence/epoch).
  public func sealPreservingIdentity(
    body: Data,
    purpose: TatwoFleetSignaturePurposeV1,
    recordID: String,
    identity: TatwoFleetRecordIdentityV1
  ) throws -> TatwoFleetSignedEnvelopeV1 {
    try assertWritable()
    guard identity.originDeviceID == originDeviceID else {
      throw TatwoFleetAuthorityError.authorityDeviceMismatch(
        expected: originDeviceID, got: identity.originDeviceID)
    }
    guard identity.recordKind == purpose.rawValue else {
      throw TatwoFleetAuthorityError.recordIdentityMismatch(
        "identity kind \(identity.recordKind) != purpose \(purpose.rawValue)")
    }
    let bodyDigest = TatwoLoopJobDigest.sha256(body)
    let sealMaterial = try Self.encodeBody(
      TatwoFleetSealMaterialV2(
        identity: identity, recordID: recordID, bodyDigest: bodyDigest))
    let authorization = try trust.authority.sign(
      payload: sealMaterial,
      purpose: purpose.rawValue,
      identity: trust.localIdentity,
      signedAt: Self.iso8601(now()))
    return TatwoFleetSignedEnvelopeV1(
      purpose: purpose,
      authorityEpoch: identity.authorityEpoch,
      originDeviceID: identity.originDeviceID,
      ledgerSequence: identity.ledgerSequence,
      recordID: recordID,
      canonicalRelativePath: identity.canonicalRelativePath,
      body: body,
      authorization: authorization)
  }

  public func verifyEnvelope(
    _ envelope: TatwoFleetSignedEnvelopeV1,
    expectedPurpose: TatwoFleetSignaturePurposeV1,
    expectedSignerDeviceID: String,
    expectedIdentity: TatwoFleetRecordIdentityV1? = nil,
    expectedRecordID: String? = nil
  ) throws {
    // General loader: V2 only. No dual-read / V1 fallback (mixed fleet must migrate).
    if envelope.schema == TatwoFleetSignedEnvelopeV1.legacySchemaName {
      throw TatwoFleetAuthorityError.signatureRejected(
        "legacy V1 envelope; run human-gated fleet migrate-seal-v2 "
          + "(mixed-version fleet is fail closed)")
    }
    guard envelope.schema == TatwoFleetSignedEnvelopeV1.schemaName else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "bad schema \(envelope.schema); expected \(TatwoFleetSignedEnvelopeV1.schemaName)")
    }
    guard envelope.purpose == expectedPurpose.rawValue else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "purpose \(envelope.purpose) != \(expectedPurpose.rawValue)")
    }
    guard envelope.recordKind == expectedPurpose.rawValue else {
      throw TatwoFleetAuthorityError.recordIdentityMismatch(
        "recordKind \(envelope.recordKind) != \(expectedPurpose.rawValue)")
    }
    guard envelope.bodyDigest == TatwoLoopJobDigest.sha256(envelope.body) else {
      throw TatwoFleetAuthorityError.signatureRejected("body digest mismatch")
    }
    guard envelope.authorization.deviceID == expectedSignerDeviceID else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "signer \(envelope.authorization.deviceID) != \(expectedSignerDeviceID)")
    }
    guard let pinned = trust.pinnedIdentities[expectedSignerDeviceID] else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "unknown identity \(expectedSignerDeviceID)")
    }
    if let expectedRecordID {
      guard envelope.recordID == expectedRecordID else {
        throw TatwoFleetAuthorityError.recordIdentityMismatch(
          "recordID \(envelope.recordID) != expected \(expectedRecordID)")
      }
    }

    let sealMaterial = try Self.encodeBody(
      TatwoFleetSealMaterialV2(
        identity: envelope.recordIdentity,
        recordID: envelope.recordID,
        bodyDigest: envelope.bodyDigest))
    do {
      try TatwoDeviceTrustAuthority.verify(
        payload: sealMaterial,
        purpose: expectedPurpose.rawValue,
        signature: envelope.authorization,
        pinnedIdentity: pinned)
    } catch {
      throw TatwoFleetAuthorityError.signatureRejected(String(describing: error))
    }

    if let expectedIdentity {
      let got = envelope.recordIdentity
      guard got.recordKind == expectedIdentity.recordKind,
        got.canonicalRelativePath == expectedIdentity.canonicalRelativePath,
        got.originDeviceID == expectedIdentity.originDeviceID,
        got.ledgerSequence == expectedIdentity.ledgerSequence,
        got.authorityEpoch == expectedIdentity.authorityEpoch
      else {
        throw TatwoFleetAuthorityError.recordIdentityMismatch(
          "signed identity \(got.canonicalRelativePath)#\(got.ledgerSequence) "
            + "!= path identity \(expectedIdentity.canonicalRelativePath)"
            + "#\(expectedIdentity.ledgerSequence)")
      }
    }
  }

  /// Migration-only: verify a legacy V1 envelope against V1 seal material.
  /// Never called from the general loader (no dual-read).
  public func verifyLegacyEnvelopeV1ForMigrationOnly(
    _ envelope: TatwoFleetSignedEnvelopeV1,
    expectedPurpose: TatwoFleetSignaturePurposeV1,
    expectedSignerDeviceID: String,
    expectedIdentity: TatwoFleetRecordIdentityV1,
    expectedRecordID: String
  ) throws {
    guard envelope.schema == TatwoFleetSignedEnvelopeV1.legacySchemaName else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "migration expects legacy schema \(TatwoFleetSignedEnvelopeV1.legacySchemaName), "
          + "got \(envelope.schema)")
    }
    guard envelope.purpose == expectedPurpose.rawValue else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "purpose \(envelope.purpose) != \(expectedPurpose.rawValue)")
    }
    guard envelope.recordKind == expectedPurpose.rawValue else {
      throw TatwoFleetAuthorityError.recordIdentityMismatch(
        "recordKind \(envelope.recordKind) != \(expectedPurpose.rawValue)")
    }
    guard envelope.bodyDigest == TatwoLoopJobDigest.sha256(envelope.body) else {
      throw TatwoFleetAuthorityError.signatureRejected("body digest mismatch")
    }
    guard envelope.authorization.deviceID == expectedSignerDeviceID else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "signer \(envelope.authorization.deviceID) != \(expectedSignerDeviceID)")
    }
    guard let pinned = trust.pinnedIdentities[expectedSignerDeviceID] else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "unknown identity \(expectedSignerDeviceID)")
    }
    guard envelope.recordID == expectedRecordID else {
      throw TatwoFleetAuthorityError.recordIdentityMismatch(
        "recordID \(envelope.recordID) != path-derived \(expectedRecordID)")
    }
    let got = envelope.recordIdentity
    guard got.recordKind == expectedIdentity.recordKind,
      got.canonicalRelativePath == expectedIdentity.canonicalRelativePath,
      got.originDeviceID == expectedIdentity.originDeviceID,
      got.ledgerSequence == expectedIdentity.ledgerSequence,
      got.authorityEpoch == expectedIdentity.authorityEpoch
    else {
      throw TatwoFleetAuthorityError.recordIdentityMismatch(
        "legacy identity mismatch at \(expectedIdentity.canonicalRelativePath)")
    }
    // Prefer V1 material with recordID; fall back to pre-recordID material (migration only).
    let withRecordID = try Self.encodeBody(
      TatwoFleetSealMaterialV2(
        schema: TatwoFleetSealMaterialV2.legacySchemaName,
        identity: envelope.recordIdentity,
        recordID: envelope.recordID,
        bodyDigest: envelope.bodyDigest))
    let legacyNoRecordID = try Self.encodeBody(
      TatwoFleetLegacySealMaterialNoRecordID(
        identity: envelope.recordIdentity,
        bodyDigest: envelope.bodyDigest))
    var verified = false
    for payload in [withRecordID, legacyNoRecordID] {
      do {
        try TatwoDeviceTrustAuthority.verify(
          payload: payload,
          purpose: expectedPurpose.rawValue,
          signature: envelope.authorization,
          pinnedIdentity: pinned)
        verified = true
        break
      } catch {
        continue
      }
    }
    guard verified else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "legacy V1 seal verification failed for \(expectedIdentity.canonicalRelativePath)")
    }
  }

  public func advanceHighWater(ledgerSequence: UInt64) throws {
    try assertWritable()
    let prior = try highWater.loadAuthorityHighWater()
    let epoch = max(authorityEpoch, prior?.authorityEpoch ?? 0)
    guard ledgerSequence >= (prior?.ledgerSequence ?? 0) else {
      throw TatwoFleetAuthorityError.ledgerSequenceRegression(
        got: ledgerSequence, highWater: prior?.ledgerSequence ?? 0)
    }
    try highWater.storeAuthorityHighWater(
      TatwoFleetAuthorityHighWaterV1(
        authorityEpoch: epoch,
        ledgerSequence: ledgerSequence,
        originDeviceID: originDeviceID,
        updatedAt: now()))
  }

  public static func encodeBody<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  public static func decodeBody<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}

// MARK: - Target signer (heartbeat / capacity only)

/// Target-side signer for device reports written to the origin ingest directory.
/// Never signs queue/assignment/commit (origin-only).
public struct TatwoFleetTargetSigner: Sendable {
  public let trust: TatwoLoopJobChannelTrust
  /// Origin this report is addressed to (metadata; not the signer).
  public let originDeviceID: String
  /// Last known origin authority epoch (fencing metadata on the report).
  public let authorityEpoch: UInt64
  public let now: @Sendable () -> Date

  public init(
    trust: TatwoLoopJobChannelTrust,
    originDeviceID: String,
    authorityEpoch: UInt64 = 1,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.trust = trust
    self.originDeviceID = originDeviceID
    self.authorityEpoch = authorityEpoch
    self.now = now
  }

  public func sealDeviceReport(
    _ device: TatwoFleetDeviceV1,
    ledgerSequence: UInt64 = 0
  ) throws -> TatwoFleetSignedEnvelopeV1 {
    let body = try TatwoFleetOriginAuthority.encodeBody(device)
    let bodyDigest = TatwoLoopJobDigest.sha256(body)
    let relative = TatwoFleetRecordIdentityV1.expectedRelativePath(
      purpose: .deviceReport, recordID: device.deviceID)
    let identity = TatwoFleetRecordIdentityV1(
      purpose: .deviceReport,
      canonicalRelativePath: relative,
      originDeviceID: originDeviceID,
      ledgerSequence: ledgerSequence,
      authorityEpoch: authorityEpoch)
    let sealMaterial = try TatwoFleetOriginAuthority.encodeBody(
      TatwoFleetSealMaterialV2(
        identity: identity, recordID: device.deviceID, bodyDigest: bodyDigest))
    let authorization = try trust.authority.sign(
      payload: sealMaterial,
      purpose: TatwoFleetSignaturePurposeV1.deviceReport.rawValue,
      identity: trust.localIdentity,
      signedAt: {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now())
      }())
    return TatwoFleetSignedEnvelopeV1(
      purpose: .deviceReport,
      authorityEpoch: authorityEpoch,
      originDeviceID: originDeviceID,
      ledgerSequence: ledgerSequence,
      recordID: device.deviceID,
      canonicalRelativePath: relative,
      body: body,
      authorization: authorization)
  }
}

// MARK: - Legacy seal material (migration only)

/// Pre-recordID seal material. Used only to verify ancient V1 signatures during
/// human-gated offline migration — never by the general loader.
struct TatwoFleetLegacySealMaterialNoRecordID: Codable, Sendable, Equatable {
  let schema: String
  let recordKind: String
  let canonicalRelativePath: String
  let originDeviceID: String
  let ledgerSequence: UInt64
  let authorityEpoch: UInt64
  let bodyDigest: String

  init(identity: TatwoFleetRecordIdentityV1, bodyDigest: String) {
    self.schema = TatwoFleetSealMaterialV2.legacySchemaName
    self.recordKind = identity.recordKind
    self.canonicalRelativePath = identity.canonicalRelativePath
    self.originDeviceID = identity.originDeviceID
    self.ledgerSequence = identity.ledgerSequence
    self.authorityEpoch = identity.authorityEpoch
    self.bodyDigest = bodyDigest
  }
}

// MARK: - Body recordID extractor (triple binding)

/// Canonical body → recordID for every control-plane purpose.
/// Loader requires bodyRecordID == envelope.recordID == pathDerivedRecordID.
public enum TatwoFleetBodyRecordIDExtractor {
  public static func extract(
    purpose: TatwoFleetSignaturePurposeV1,
    body: Data
  ) throws -> String {
    switch purpose {
    case .device, .deviceReport:
      return try TatwoFleetOriginAuthority.decodeBody(TatwoFleetDeviceV1.self, from: body).deviceID
    case .queue:
      return try TatwoFleetOriginAuthority.decodeBody(TatwoFleetLogicalJobV1.self, from: body)
        .logicalJobID
    case .assignment:
      return try TatwoFleetOriginAuthority.decodeBody(TatwoFleetAssignmentV1.self, from: body).jobID
    case .commit:
      return try TatwoFleetOriginAuthority.decodeBody(TatwoFleetLogicalCommitV1.self, from: body)
        .logicalJobID
    case .superseded:
      return try TatwoFleetOriginAuthority.decodeBody(TatwoFleetSupersededResultV1.self, from: body)
        .jobID
    case .schedulerState:
      _ = try TatwoFleetOriginAuthority.decodeBody(TatwoFleetSchedulerStateV1.self, from: body)
      return "scheduler-state"
    case .ledger:
      let entry = try TatwoFleetOriginAuthority.decodeBody(
        TatwoFleetLedgerEntryV1.self, from: body)
      return "ledger-\(entry.ledgerSequence)"
    case .sealMigration:
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal-migration purpose has no body-derived recordID; "
          + "identity is sealed with an explicit recordID")
    }
  }
}

// MARK: - Human-gated seal V2 migration

/// Receipt for offline V1→V2 re-sign. Supports rollback via `backupDirectory`.
public struct TatwoFleetSealMigrationReceiptV1: Codable, Sendable, Equatable {
  public let schema: String
  public let originDeviceID: String
  public let fromEnvelopeSchema: String
  public let toEnvelopeSchema: String
  public let confirmToken: String
  public let fleetRootPath: String
  public let inventoryDigest: String
  public let migrationPlanHash: String
  public let backupDirectory: String
  /// Bound to the authority epoch that sealed the migration (resume must match).
  public let authorityEpoch: UInt64
  /// Digest of the pre-switch backup tree; resume recomputes and compares.
  public let backupDigest: String
  public let migrated: [TatwoFleetSealMigrationItemV1]
  public let skippedAlreadyV2: Int
  public let completedAt: Date

  public init(
    schema: String = "TatwoFleetSealMigrationReceiptV1",
    originDeviceID: String,
    fromEnvelopeSchema: String = TatwoFleetSignedEnvelopeV1.legacySchemaName,
    toEnvelopeSchema: String = TatwoFleetSignedEnvelopeV1.schemaName,
    confirmToken: String,
    fleetRootPath: String,
    inventoryDigest: String,
    migrationPlanHash: String,
    backupDirectory: String,
    authorityEpoch: UInt64,
    backupDigest: String,
    migrated: [TatwoFleetSealMigrationItemV1],
    skippedAlreadyV2: Int,
    completedAt: Date
  ) {
    self.schema = schema
    self.originDeviceID = originDeviceID
    self.fromEnvelopeSchema = fromEnvelopeSchema
    self.toEnvelopeSchema = toEnvelopeSchema
    self.confirmToken = confirmToken
    self.fleetRootPath = fleetRootPath
    self.inventoryDigest = inventoryDigest
    self.migrationPlanHash = migrationPlanHash
    self.backupDirectory = backupDirectory
    self.authorityEpoch = authorityEpoch
    self.backupDigest = backupDigest
    self.migrated = migrated
    self.skippedAlreadyV2 = skippedAlreadyV2
    self.completedAt = completedAt
  }
}

public struct TatwoFleetSealMigrationItemV1: Codable, Sendable, Equatable {
  public let relativePath: String
  public let purpose: String
  public let recordID: String
  public let ledgerSequence: UInt64
  public let priorBodyDigest: String
  public let priorEnvelopeDigest: String
  public let newEnvelopeDigest: String

  public init(
    relativePath: String,
    purpose: String,
    recordID: String,
    ledgerSequence: UInt64,
    priorBodyDigest: String,
    priorEnvelopeDigest: String,
    newEnvelopeDigest: String
  ) {
    self.relativePath = relativePath
    self.purpose = purpose
    self.recordID = recordID
    self.ledgerSequence = ledgerSequence
    self.priorBodyDigest = priorBodyDigest
    self.priorEnvelopeDigest = priorEnvelopeDigest
    self.newEnvelopeDigest = newEnvelopeDigest
  }
}

/// Preflight plan for transactional V1→V2 migration (confirm binds its hash).
public struct TatwoFleetSealMigrationPlanV1: Codable, Sendable, Equatable {
  public let schema: String
  public let fleetRootPath: String
  public let originDeviceID: String
  public let inventoryDigest: String
  public let migrationPlanHash: String
  public let candidates: [TatwoFleetSealMigrationPlanCandidateV1]
  public let alreadyV2RelativePaths: [String]

  public init(
    schema: String = "TatwoFleetSealMigrationPlanV1",
    fleetRootPath: String,
    originDeviceID: String,
    inventoryDigest: String,
    migrationPlanHash: String,
    candidates: [TatwoFleetSealMigrationPlanCandidateV1],
    alreadyV2RelativePaths: [String]
  ) {
    self.schema = schema
    self.fleetRootPath = fleetRootPath
    self.originDeviceID = originDeviceID
    self.inventoryDigest = inventoryDigest
    self.migrationPlanHash = migrationPlanHash
    self.candidates = candidates
    self.alreadyV2RelativePaths = alreadyV2RelativePaths
  }
}

public struct TatwoFleetSealMigrationPlanCandidateV1: Codable, Sendable, Equatable {
  public let relativePath: String
  public let purpose: String
  public let recordID: String
  public let ledgerSequence: UInt64
  public let priorBodyDigest: String
  public let priorEnvelopeDigest: String

  public init(
    relativePath: String,
    purpose: String,
    recordID: String,
    ledgerSequence: UInt64,
    priorBodyDigest: String,
    priorEnvelopeDigest: String
  ) {
    self.relativePath = relativePath
    self.purpose = purpose
    self.recordID = recordID
    self.ledgerSequence = ledgerSequence
    self.priorBodyDigest = priorBodyDigest
    self.priorEnvelopeDigest = priorEnvelopeDigest
  }
}

/// Offline, human-gated re-sign of legacy V1 envelopes to production V2.
/// General loaders never dual-read V1; mixed-version fleets fail closed until migrated.
///
/// Transaction shape: exclusive lock → full preflight inventory → bound confirm →
/// backup tree + origin-signed pre-switch receipt → stage tree + fsync →
/// origin-signed journal → atomic per-file switch (path-contained) →
/// completion journal (resumable only with matching confirm + verified journal).
public enum TatwoFleetSealMigration {
  /// Historical fixed string — **not** a valid confirm by itself.
  /// Confirm must bind fleet-root + inventory digest + plan hash.
  public static let confirmTokenPrefix = "I-CONFIRM-FLEET-SEAL-V2-MIGRATION"

  /// Back-compat alias (tests/CLI docs); never accept this alone as confirm.
  public static let confirmToken = confirmTokenPrefix

  private static let journalFileName = "seal-v2-migration.journal.json"
  private static let journalRecordID = "seal-v2-migration.journal"
  private static let journalRelativePath = "receipts/seal-v2-migration.journal.json"
  private static let lockFileName = "seal-v2-migration.lock"
  private static let stageDirName = ".seal-v2-stage"
  private static let backupDirPrefix = "seal-v2-backup-"
  private static let consumeHighWaterRelativePath =
    "receipts/seal-v2-migration-consume-hw.json"

  public static func expectedConfirmToken(
    fleetRoot: URL,
    inventoryDigest: String,
    migrationPlanHash: String
  ) -> String {
    let root = fleetRoot.standardizedFileURL.path
    let material =
      "\(confirmTokenPrefix)|\(root)|\(inventoryDigest)|\(migrationPlanHash)"
    return TatwoLoopJobDigest.sha256(Data(material.utf8))
  }

  /// Build verified preflight plan (no writes).
  public static func buildPlan(
    fleetRoot: URL,
    origin: TatwoFleetOriginAuthority
  ) throws -> TatwoFleetSealMigrationPlanV1 {
    try origin.assertWritable()
    let root = fleetRoot.standardizedFileURL
    let inventory = try collectInventory(root: root, origin: origin)
    let inventoryDigest = inventoryDigest(for: inventory)
    let candidates = inventory.v1
    let planBody = candidates.map {
      "\($0.relativePath)|\($0.purpose)|\($0.recordID)|\($0.ledgerSequence)|"
        + "\($0.priorEnvelopeDigest)|\($0.priorBodyDigest)"
    }.joined(separator: "\n")
    let migrationPlanHash = TatwoLoopJobDigest.sha256(Data(planBody.utf8))
    return TatwoFleetSealMigrationPlanV1(
      fleetRootPath: root.path,
      originDeviceID: origin.originDeviceID,
      inventoryDigest: inventoryDigest,
      migrationPlanHash: migrationPlanHash,
      candidates: candidates.map {
        TatwoFleetSealMigrationPlanCandidateV1(
          relativePath: $0.relativePath,
          purpose: $0.purpose.rawValue,
          recordID: $0.recordID,
          ledgerSequence: $0.ledgerSequence,
          priorBodyDigest: $0.priorBodyDigest,
          priorEnvelopeDigest: $0.priorEnvelopeDigest)
      },
      alreadyV2RelativePaths: inventory.v2Paths.sorted())
  }

  public static func migrateFleetTree(
    fleetRoot: URL,
    origin: TatwoFleetOriginAuthority,
    confirm: String,
    now: Date = Date(),
    /// Test-only seam: invoked after each successful staged→live swap on the
    /// first-run (non-resume) path, with the relative path just completed.
    testHookAfterFirstRunSwap: ((String) -> Void)? = nil,
    /// Test-only seam: invoked immediately before the durable final receipt write
    /// (first-run and resume). Used to inject real-directory receipts transplant.
    testHookBeforeFinalReceiptWrite: (() -> Void)? = nil
  ) throws -> TatwoFleetSealMigrationReceiptV1 {
    try origin.assertWritable()
    let root = fleetRoot.standardizedFileURL
    // TatwoFileLock appends ".lock"; pass stem path.
    let lockStem = root.appendingPathComponent("seal-v2-migration")
    return try TatwoFileLock.withExclusiveLock(for: lockStem) {
      try migrateLocked(
        root: root,
        origin: origin,
        confirm: confirm,
        now: now,
        testHookAfterFirstRunSwap: testHookAfterFirstRunSwap,
        testHookBeforeFinalReceiptWrite: testHookBeforeFinalReceiptWrite)
    }
  }

  /// Fleet-root-relative path of the origin-signed durable completion receipt
  /// Core writes via pinned-root fd IO. Empty when nothing was migrated.
  /// CLI must report this path only — never rewrite the receipt by pathname.
  public static func signedCompletionReceiptRelativePath(
    for receipt: TatwoFleetSealMigrationReceiptV1
  ) -> String {
    guard !receipt.migrated.isEmpty else { return "" }
    let stamp = Int(receipt.completedAt.timeIntervalSince1970)
    return "receipts/seal-v2-migration-\(stamp).json"
  }

  // MARK: Internal migration steps

  private struct PreparedV1 {
    let relativePath: String
    let purpose: TatwoFleetSignaturePurposeV1
    let recordID: String
    let ledgerSequence: UInt64
    let authorityEpoch: UInt64
    let originDeviceID: String
    let priorBodyDigest: String
    let priorEnvelopeDigest: String
    let body: Data
    let sourceURL: URL
  }

  private struct Inventory {
    let v1: [PreparedV1]
    let v2Paths: [String]
  }

  private struct StageManifestEntry: Codable, Equatable {
    var relativePath: String
    var newEnvelopeDigest: String
  }

  /// Origin-bound migration journal body (always sealed under sealMigration purpose).
  private struct Journal: Codable, Equatable {
    var schema: String
    var phase: String
    var fleetRootPath: String
    var originDeviceID: String
    var authorityEpoch: UInt64
    /// One-time migration identity (UUID). Bound into journal + consume high-water.
    var migrationID: String
    /// Monotonic sequence allocated at start; completed sequences cannot resume again.
    var migrationSequence: UInt64
    var inventoryDigest: String
    var migrationPlanHash: String
    var backupDirectory: String
    var backupDigest: String
    var confirmToken: String
    var stageManifest: [StageManifestEntry]
    var pendingRelativePaths: [String]
    var completedRelativePaths: [String]
    var preReceiptRelativePath: String
    var preReceiptDigest: String

    init(
      schema: String = "TatwoFleetSealMigrationJournalV1",
      phase: String,
      fleetRootPath: String,
      originDeviceID: String,
      authorityEpoch: UInt64,
      migrationID: String,
      migrationSequence: UInt64,
      inventoryDigest: String,
      migrationPlanHash: String,
      backupDirectory: String,
      backupDigest: String,
      confirmToken: String,
      stageManifest: [StageManifestEntry],
      pendingRelativePaths: [String],
      completedRelativePaths: [String],
      preReceiptRelativePath: String,
      preReceiptDigest: String
    ) {
      self.schema = schema
      self.phase = phase
      self.fleetRootPath = fleetRootPath
      self.originDeviceID = originDeviceID
      self.authorityEpoch = authorityEpoch
      self.migrationID = migrationID
      self.migrationSequence = migrationSequence
      self.inventoryDigest = inventoryDigest
      self.migrationPlanHash = migrationPlanHash
      self.backupDirectory = backupDirectory
      self.backupDigest = backupDigest
      self.confirmToken = confirmToken
      self.stageManifest = stageManifest
      self.pendingRelativePaths = pendingRelativePaths
      self.completedRelativePaths = completedRelativePaths
      self.preReceiptRelativePath = preReceiptRelativePath
      self.preReceiptDigest = preReceiptDigest
    }
  }

  /// Durable consume high-water so same-epoch old journals cannot resume after completion.
  private struct MigrationConsumeHighWater: Codable, Equatable {
    var schema: String
    var allocatedMax: UInt64
    var completedMax: UInt64
    /// Last allocated migrationID (audit; sequence is authoritative for consume).
    var lastMigrationID: String

    init(
      schema: String = "TatwoFleetSealMigrationConsumeHighWaterV1",
      allocatedMax: UInt64,
      completedMax: UInt64,
      lastMigrationID: String
    ) {
      self.schema = schema
      self.allocatedMax = allocatedMax
      self.completedMax = completedMax
      self.lastMigrationID = lastMigrationID
    }
  }

  private static func migrateLocked(
    root: URL,
    origin: TatwoFleetOriginAuthority,
    confirm: String,
    now: Date,
    testHookAfterFirstRunSwap: ((String) -> Void)? = nil,
    testHookBeforeFinalReceiptWrite: (() -> Void)? = nil
  ) throws -> TatwoFleetSealMigrationReceiptV1 {
    // Transaction-scoped pin: parent + root + receipts dirfds held until migration ends.
    // Never re-resolve fleet root or "receipts" by pathname between writer calls.
    let pin = try MigrationTxnPin.begin(root: root)
    defer { pin.close() }

    let journalURL = root.appendingPathComponent(journalRelativePath)

    // Resume path: journal left mid-swap. Signature always verified; caller
    // confirm is required *before* any resume write (not for a finished journal).
    if FileManager.default.fileExists(atPath: journalURL.path) {
      let journal = try loadAndVerifySignedJournal(
        at: journalURL, root: root, origin: origin)
      if journal.phase == "swapping" || journal.phase == "staged" {
        try assertConfirmMatchesJournal(confirm: confirm, journal: journal, root: root)
        return try resumeFromJournal(
          journal: journal,
          journalURL: journalURL,
          root: root,
          origin: origin,
          confirm: confirm,
          now: now,
          pin: pin,
          testHookBeforeFinalReceiptWrite: testHookBeforeFinalReceiptWrite)
      }
    }

    let plan = try buildPlan(fleetRoot: root, origin: origin)
    let expected = expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash)
    guard confirm == expected else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration confirm must bind fleet-root + inventory digest + plan hash "
          + "(expected \(expected.prefix(16))…, not a fixed string)")
    }

    if plan.candidates.isEmpty {
      return TatwoFleetSealMigrationReceiptV1(
        originDeviceID: origin.originDeviceID,
        confirmToken: expected,
        fleetRootPath: root.path,
        inventoryDigest: plan.inventoryDigest,
        migrationPlanHash: plan.migrationPlanHash,
        backupDirectory: "",
        authorityEpoch: origin.authorityEpoch,
        backupDigest: "",
        migrated: [],
        skippedAlreadyV2: plan.alreadyV2RelativePaths.count,
        completedAt: now)
    }

    // Re-load prepared V1 with live bytes for staging.
    let inventory = try collectInventory(root: root, origin: origin)
    guard inventoryDigest(for: inventory) == plan.inventoryDigest else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration inventory changed between preflight and execute")
    }

    let migrationID = UUID().uuidString.lowercased()
    let migrationSequence = try allocateMigrationSequence(
      root: root, migrationID: migrationID, pin: pin)

    let stamp = Int(now.timeIntervalSince1970)
    let backupRelPrefix = "receipts/\(backupDirPrefix)\(stamp)"
    let backupDir = try containedURL(relative: backupRelPrefix, under: root)

    // Backup original V1 bytes before any live mutation (txn-pinned FDs).
    for item in inventory.v1 {
      try assertSafeMigrationRelativePath(item.relativePath)
      let liveData = try pin.readFile(relative: item.relativePath)
      try pin.writeAtomic(
        relative: "\(backupRelPrefix)/\(item.relativePath)",
        data: liveData)
    }
    let backupDigest = try directoryContentDigest(at: backupDir)

    // Stage cleanup is rootFD-relative; unbound root name → stop without deleting.
    pin.removeTreeIfPresentBestEffort(relative: stageDirName)
    // Create stage root under the same pinned fleet root (reject if symlink).
    try pin.ensureDirectory(relative: stageDirName, createIntermediates: true)

    var migrated: [TatwoFleetSealMigrationItemV1] = []
    migrated.reserveCapacity(inventory.v1.count)
    var stageManifest: [StageManifestEntry] = []
    stageManifest.reserveCapacity(inventory.v1.count)
    for item in inventory.v1 {
      try assertSafeMigrationRelativePath(item.relativePath)
      let expectedIdentity = TatwoFleetRecordIdentityV1(
        purpose: item.purpose,
        canonicalRelativePath: item.relativePath,
        originDeviceID: item.originDeviceID,
        ledgerSequence: item.ledgerSequence,
        authorityEpoch: item.authorityEpoch)
      let fixed = try origin.sealPreservingIdentity(
        body: item.body,
        purpose: item.purpose,
        recordID: item.recordID,
        identity: expectedIdentity)
      let newData = try TatwoFleetOriginAuthority.encodeBody(fixed)
      try pin.writeAtomic(
        relative: "\(stageDirName)/\(item.relativePath)",
        data: newData)
      let digest = TatwoLoopJobDigest.sha256(newData)
      migrated.append(
        TatwoFleetSealMigrationItemV1(
          relativePath: item.relativePath,
          purpose: item.purpose.rawValue,
          recordID: item.recordID,
          ledgerSequence: item.ledgerSequence,
          priorBodyDigest: item.priorBodyDigest,
          priorEnvelopeDigest: item.priorEnvelopeDigest,
          newEnvelopeDigest: digest))
      stageManifest.append(
        StageManifestEntry(relativePath: item.relativePath, newEnvelopeDigest: digest))
    }

    // Pre-switch receipt (includes backup path) before any live rename — origin-signed.
    let receipt = TatwoFleetSealMigrationReceiptV1(
      originDeviceID: origin.originDeviceID,
      confirmToken: expected,
      fleetRootPath: root.path,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash,
      backupDirectory: backupDir.path,
      authorityEpoch: origin.authorityEpoch,
      backupDigest: backupDigest,
      migrated: migrated,
      skippedAlreadyV2: inventory.v2Paths.count,
      completedAt: now)
    let preRelName = "seal-v2-migration-pre-\(stamp).json"
    let preRelativePath = "receipts/\(preRelName)"
    let preReceiptDigest = try writeSignedMigrationArtifact(
      bodyValue: receipt,
      pin: pin,
      relativePath: preRelativePath,
      origin: origin,
      recordID: preRelName.replacingOccurrences(of: ".json", with: ""))

    var journal = Journal(
      phase: "staged",
      fleetRootPath: root.path,
      originDeviceID: origin.originDeviceID,
      authorityEpoch: origin.authorityEpoch,
      migrationID: migrationID,
      migrationSequence: migrationSequence,
      inventoryDigest: plan.inventoryDigest,
      migrationPlanHash: plan.migrationPlanHash,
      backupDirectory: backupDir.path,
      backupDigest: backupDigest,
      confirmToken: expected,
      stageManifest: stageManifest,
      pendingRelativePaths: migrated.map(\.relativePath),
      completedRelativePaths: [],
      preReceiptRelativePath: preRelativePath,
      preReceiptDigest: preReceiptDigest)
    try writeSignedJournal(journal, pin: pin, origin: origin)

    journal.phase = "swapping"
    try writeSignedJournal(journal, pin: pin, origin: origin)

    // Atomic per-file switch from stage → live (fd-relative + digest-bound).
    let pending = journal.pendingRelativePaths
    for rel in pending {
      try applyStagedSwap(
        relativePath: rel,
        journal: journal,
        pin: pin,
        origin: origin)
      journal.completedRelativePaths.append(rel)
      journal.pendingRelativePaths.removeAll { $0 == rel }
      try writeSignedJournal(journal, pin: pin, origin: origin)
      // Injection seam for first-run completed-live tamper tests only.
      testHookAfterFirstRunSwap?(rel)
    }
    // Final evidence gate (same as resume): exact partition + completed-live
    // digest/signature reverify before phase=done / consume / final receipt.
    try assertJournalPartitionExact(journal)
    try reverifyCompletedLiveFiles(journal: journal, pin: pin, origin: origin)
    journal.phase = "done"
    try writeSignedJournal(journal, pin: pin, origin: origin)
    try markMigrationConsumed(
      sequence: journal.migrationSequence,
      migrationID: journal.migrationID,
      root: root,
      pin: pin)

    // FD-relative stage cleanup only while $FLEET name still binds start inode.
    pin.removeTreeIfPresentBestEffort(relative: stageDirName)

    // Final durable receipt next to journal (origin-signed, txn-pinned receipts FD).
    // CLI must not rewrite this by pathname.
    let finalRelName = "seal-v2-migration-\(stamp).json"
    let finalRelativePath = "receipts/\(finalRelName)"
    testHookBeforeFinalReceiptWrite?()
    _ = try writeSignedMigrationArtifact(
      bodyValue: receipt,
      pin: pin,
      relativePath: finalRelativePath,
      origin: origin,
      recordID: finalRelName.replacingOccurrences(of: ".json", with: ""))
    return receipt
  }

  private static func resumeFromJournal(
    journal: Journal,
    journalURL: URL,
    root: URL,
    origin: TatwoFleetOriginAuthority,
    confirm: String,
    now: Date,
    pin: MigrationTxnPin,
    testHookBeforeFinalReceiptWrite: (() -> Void)? = nil
  ) throws -> TatwoFleetSealMigrationReceiptV1 {
    _ = journalURL
    // Confirm already verified by caller; re-check fail-closed.
    try assertConfirmMatchesJournal(confirm: confirm, journal: journal, root: root)
    // Same-epoch replay of a completed migration sequence is rejected.
    try assertMigrationResumable(
      sequence: journal.migrationSequence,
      migrationID: journal.migrationID,
      root: root)
    try assertJournalPartitionExact(journal)
    try reverifyBackupDigest(journal: journal, root: root)
    // Completed live state must still match stage manifest (no blind trust).
    try reverifyCompletedLiveFiles(journal: journal, pin: pin, origin: origin)

    var journal = journal
    let pending = journal.pendingRelativePaths.filter {
      !journal.completedRelativePaths.contains($0)
    }
    for rel in pending {
      try applyStagedSwap(
        relativePath: rel,
        journal: journal,
        pin: pin,
        origin: origin)
      journal.completedRelativePaths.append(rel)
      journal.pendingRelativePaths.removeAll { $0 == rel }
      try writeSignedJournal(journal, pin: pin, origin: origin)
    }
    // After pending swaps, every stage path must be verified live.
    try assertJournalPartitionExact(journal)
    try reverifyCompletedLiveFiles(journal: journal, pin: pin, origin: origin)
    journal.pendingRelativePaths = []
    journal.phase = "done"
    try writeSignedJournal(journal, pin: pin, origin: origin)
    try markMigrationConsumed(
      sequence: journal.migrationSequence,
      migrationID: journal.migrationID,
      root: root,
      pin: pin)
    // FD-relative stage cleanup only while $FLEET name still binds start inode.
    pin.removeTreeIfPresentBestEffort(relative: stageDirName)

    // Bound pre-receipt only — never scan "latest name" in receipts/.
    // Receipt reflects actually verified state (re-checked live digests + backup).
    let verified = try loadBoundVerifiedReceipt(
      journal: journal, root: root, pin: pin, origin: origin, now: now)
    // Durable signed completion receipt (txn-pinned receipts FD). CLI reports path only.
    let finalRel = signedCompletionReceiptRelativePath(for: verified)
    if !finalRel.isEmpty {
      let finalName = URL(fileURLWithPath: finalRel).lastPathComponent
      testHookBeforeFinalReceiptWrite?()
      _ = try writeSignedMigrationArtifact(
        bodyValue: verified,
        pin: pin,
        relativePath: finalRel,
        origin: origin,
        recordID: finalName.replacingOccurrences(of: ".json", with: ""))
    }
    return verified
  }

  private static func applyStagedSwap(
    relativePath: String,
    journal: Journal,
    pin: MigrationTxnPin,
    origin: TatwoFleetOriginAuthority
  ) throws {
    try assertSafeMigrationRelativePath(relativePath)
    guard let manifest = journal.stageManifest.first(where: { $0.relativePath == relativePath })
    else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration path \(relativePath) not in signed stage manifest")
    }
    let stageRel = "\(stageDirName)/\(relativePath)"
    let stageData: Data
    do {
      stageData = try pin.readFile(relative: stageRel)
    } catch let error as TatwoFleetAuthorityError {
      // Preserve pin binding failures (root/receipts transplant) fail-closed as-is.
      throw error
    } catch {
      throw TatwoFleetAuthorityError.missingAuthority(
        "seal V2 migration resume missing staged file \(relativePath)")
    }
    let stageDigest = TatwoLoopJobDigest.sha256(stageData)
    guard stageDigest == manifest.newEnvelopeDigest else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration staged digest mismatch for \(relativePath)")
    }
    // Stage bytes must be origin-signed V2 envelopes with pathname identity.
    try verifyStagedEnvelopeData(
      stageData, relativePath: relativePath, origin: origin)
    // Live write under transaction-pinned root (mid-path symlink → reject).
    try pin.writeAtomic(relative: relativePath, data: stageData)
  }

  private static func verifyStagedEnvelopeData(
    _ data: Data,
    relativePath: String,
    origin: TatwoFleetOriginAuthority
  ) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope: TatwoFleetSignedEnvelopeV1
    do {
      envelope = try decoder.decode(TatwoFleetSignedEnvelopeV1.self, from: data)
    } catch {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration staged bytes are not a signed envelope at \(relativePath)")
    }
    guard envelope.schema == TatwoFleetSignedEnvelopeV1.schemaName else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration staged envelope not V2 at \(relativePath)")
    }
    guard let purpose = TatwoFleetSignaturePurposeV1(rawValue: envelope.purpose) else {
      throw TatwoFleetAuthorityError.signatureRejected(
        "unknown purpose on staged envelope at \(relativePath)")
    }
    if purpose == .sealMigration {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration must not promote migration artifacts to live paths")
    }
    let expectedRecordID = TatwoFleetRecordIdentityV1.expectedRecordID(
      purpose: purpose,
      canonicalRelativePath: relativePath,
      ledgerSequence: envelope.ledgerSequence)
    let expectedIdentity = TatwoFleetRecordIdentityV1(
      purpose: purpose,
      canonicalRelativePath: relativePath,
      originDeviceID: envelope.originDeviceID,
      ledgerSequence: envelope.ledgerSequence,
      authorityEpoch: envelope.authorityEpoch)
    try origin.verifyEnvelope(
      envelope,
      expectedPurpose: purpose,
      expectedSignerDeviceID: origin.originDeviceID,
      expectedIdentity: expectedIdentity,
      expectedRecordID: expectedRecordID)
  }

  private static func loadAndVerifySignedJournal(
    at url: URL,
    root: URL,
    origin: TatwoFleetOriginAuthority
  ) throws -> Journal {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw TatwoFleetAuthorityError.missingAuthority(
        "seal V2 migration journal unreadable: \(error.localizedDescription)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // Unsigned legacy journals are rejected (no confused-deputy resume).
    let envelope: TatwoFleetSignedEnvelopeV1
    do {
      envelope = try decoder.decode(TatwoFleetSignedEnvelopeV1.self, from: data)
    } catch {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration journal must be origin-signed envelope")
    }
    let expectedIdentity = TatwoFleetRecordIdentityV1(
      purpose: .sealMigration,
      canonicalRelativePath: journalRelativePath,
      originDeviceID: origin.originDeviceID,
      ledgerSequence: 0,
      authorityEpoch: origin.authorityEpoch)
    try origin.verifyEnvelope(
      envelope,
      expectedPurpose: .sealMigration,
      expectedSignerDeviceID: origin.originDeviceID,
      expectedIdentity: expectedIdentity,
      expectedRecordID: journalRecordID)
    let journal = try TatwoFleetOriginAuthority.decodeBody(Journal.self, from: envelope.body)
    guard journal.schema == "TatwoFleetSealMigrationJournalV1" else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration journal schema \(journal.schema)")
    }
    guard journal.fleetRootPath == root.path else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal fleetRoot mismatch")
    }
    guard journal.originDeviceID == origin.originDeviceID else {
      throw TatwoFleetAuthorityError.authorityDeviceMismatch(
        expected: origin.originDeviceID, got: journal.originDeviceID)
    }
    guard journal.authorityEpoch == origin.authorityEpoch else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal authorityEpoch mismatch")
    }
    guard !journal.migrationID.isEmpty else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal missing migrationID")
    }
    guard journal.migrationSequence > 0 else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal migrationSequence must be > 0")
    }
    // Exact partition: pending ∪ completed == stageManifest, disjoint, no dups.
    try assertJournalPartitionExact(journal)
    for entry in journal.stageManifest {
      try assertSafeMigrationRelativePath(entry.relativePath)
    }
    try assertSafeMigrationRelativePath(journal.preReceiptRelativePath)
    return journal
  }

  private static func assertJournalPartitionExact(_ journal: Journal) throws {
    let manifestPaths = journal.stageManifest.map(\.relativePath)
    let manifestSet = Set(manifestPaths)
    guard manifestPaths.count == manifestSet.count else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration stage manifest has duplicate paths")
    }
    let pending = journal.pendingRelativePaths
    let completed = journal.completedRelativePaths
    let pendingSet = Set(pending)
    let completedSet = Set(completed)
    guard pending.count == pendingSet.count else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal pending has duplicates")
    }
    guard completed.count == completedSet.count else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal completed has duplicates")
    }
    guard pendingSet.isDisjoint(with: completedSet) else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal pending/completed overlap")
    }
    let union = pendingSet.union(completedSet)
    guard union == manifestSet else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration journal partition must equal stage manifest exactly")
    }
    for rel in pending + completed {
      try assertSafeMigrationRelativePath(rel)
    }
  }

  private static func reverifyBackupDigest(journal: Journal, root: URL) throws {
    let backupURL = URL(fileURLWithPath: journal.backupDirectory, isDirectory: true)
      .standardizedFileURL
    guard isStrictlyUnderRoot(backupURL, root: root)
      || backupURL.path == root.appendingPathComponent(
        "receipts", isDirectory: true).standardizedFileURL.path
      || isStrictlyUnderRoot(
        backupURL,
        root: root.appendingPathComponent("receipts", isDirectory: true))
    else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration backupDirectory escapes fleet root")
    }
    // Prefer relative recompute under pinned root when backup is receipts/…
    let rootStd = root.standardizedFileURL
    let prefix = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"
    guard backupURL.path.hasPrefix(prefix) else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration backupDirectory not under fleet root")
    }
    let rel = String(backupURL.path.dropFirst(prefix.count))
    try assertSafeMigrationRelativePath(rel)
    let recomputed = try directoryContentDigest(at: backupURL)
    guard recomputed == journal.backupDigest else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration backup digest mismatch on resume")
    }
  }

  private static func reverifyCompletedLiveFiles(
    journal: Journal,
    pin: MigrationTxnPin,
    origin: TatwoFleetOriginAuthority
  ) throws {
    let manifestByPath = Dictionary(
      uniqueKeysWithValues: journal.stageManifest.map {
        ($0.relativePath, $0.newEnvelopeDigest)
      })
    for rel in journal.completedRelativePaths {
      guard let expectedDigest = manifestByPath[rel] else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration completed path \(rel) not in stage manifest")
      }
      let liveData: Data
      do {
        liveData = try pin.readFile(relative: rel)
      } catch let error as TatwoFleetAuthorityError {
        // Preserve pin binding/identity failures (e.g. mid-txn root transplant).
        throw error
      } catch {
        throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
          "seal V2 migration completed live missing or unreadable: \(rel)")
      }
      let liveDigest = TatwoLoopJobDigest.sha256(liveData)
      guard liveDigest == expectedDigest else {
        throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
          "seal V2 migration completed live digest mismatch for \(rel) "
            + "(quarantine; refusing blind resume)")
      }
      try verifyStagedEnvelopeData(liveData, relativePath: rel, origin: origin)
    }
  }

  private static func allocateMigrationSequence(
    root: URL,
    migrationID: String,
    pin: MigrationTxnPin
  ) throws -> UInt64 {
    var hw = try loadConsumeHighWater(root: root)
    if hw.completedMax > hw.allocatedMax {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration consume high-water corrupt "
          + "(completedMax \(hw.completedMax) > allocatedMax \(hw.allocatedMax))")
    }
    hw.allocatedMax += 1
    hw.lastMigrationID = migrationID
    try storeConsumeHighWater(hw, pin: pin)
    return hw.allocatedMax
  }

  private static func assertMigrationResumable(
    sequence: UInt64,
    migrationID: String,
    root: URL
  ) throws {
    let hw = try loadConsumeHighWater(root: root)
    guard sequence > 0, sequence <= hw.allocatedMax else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration sequence \(sequence) not allocated "
          + "(allocatedMax=\(hw.allocatedMax)); refusing resume")
    }
    guard sequence > hw.completedMax else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration sequence \(sequence) already consumed "
          + "(completedMax=\(hw.completedMax)); refusing same-epoch journal replay")
    }
    // migrationID is advisory audit; sequence is authoritative. Empty ID rejected earlier.
    _ = migrationID
  }

  private static func markMigrationConsumed(
    sequence: UInt64,
    migrationID: String,
    root: URL,
    pin: MigrationTxnPin
  ) throws {
    var hw = try loadConsumeHighWater(root: root)
    guard sequence > hw.completedMax else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration sequence \(sequence) already consumed")
    }
    guard sequence <= hw.allocatedMax else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration cannot complete unallocated sequence \(sequence)")
    }
    // Single-flight: only the next incomplete sequence may complete.
    guard sequence == hw.completedMax + 1 else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration complete out of order "
          + "(got \(sequence), expected \(hw.completedMax + 1))")
    }
    hw.completedMax = sequence
    hw.lastMigrationID = migrationID
    try storeConsumeHighWater(hw, pin: pin)
  }

  private static func loadConsumeHighWater(root: URL) throws -> MigrationConsumeHighWater {
    let url = try containedURL(relative: consumeHighWaterRelativePath, under: root)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return MigrationConsumeHighWater(
        allocatedMax: 0, completedMax: 0, lastMigrationID: "")
    }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    let hw = try decoder.decode(MigrationConsumeHighWater.self, from: data)
    guard hw.schema == "TatwoFleetSealMigrationConsumeHighWaterV1" else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration consume high-water schema \(hw.schema)")
    }
    return hw
  }

  private static func storeConsumeHighWater(
    _ hw: MigrationConsumeHighWater,
    pin: MigrationTxnPin
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(hw)
    try pin.writeAtomic(relative: consumeHighWaterRelativePath, data: data)
  }

  private static func assertConfirmMatchesJournal(
    confirm: String,
    journal: Journal,
    root: URL
  ) throws {
    let expected = expectedConfirmToken(
      fleetRoot: root,
      inventoryDigest: journal.inventoryDigest,
      migrationPlanHash: journal.migrationPlanHash)
    guard confirm == expected, confirm == journal.confirmToken, expected == journal.confirmToken
    else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration resume confirm must match journal-bound confirm "
          + "(expected \(expected.prefix(16))…)")
    }
  }

  private static func loadBoundVerifiedReceipt(
    journal: Journal,
    root: URL,
    pin: MigrationTxnPin,
    origin: TatwoFleetOriginAuthority,
    now: Date
  ) throws -> TatwoFleetSealMigrationReceiptV1 {
    try assertSafeMigrationRelativePath(journal.preReceiptRelativePath)
    let data = try pin.readFile(relative: journal.preReceiptRelativePath)
    let digest = TatwoLoopJobDigest.sha256(data)
    guard digest == journal.preReceiptDigest else {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration pre-receipt digest mismatch "
          + "(forged newer pre-receipt is ignored; bound digest must match)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope: TatwoFleetSignedEnvelopeV1
    do {
      envelope = try decoder.decode(TatwoFleetSignedEnvelopeV1.self, from: data)
    } catch {
      throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
        "seal V2 migration pre-receipt must be origin-signed")
    }
    let preRecordID = URL(fileURLWithPath: journal.preReceiptRelativePath)
      .deletingPathExtension().lastPathComponent
    let expectedIdentity = TatwoFleetRecordIdentityV1(
      purpose: .sealMigration,
      canonicalRelativePath: journal.preReceiptRelativePath,
      originDeviceID: origin.originDeviceID,
      ledgerSequence: 0,
      authorityEpoch: origin.authorityEpoch)
    try origin.verifyEnvelope(
      envelope,
      expectedPurpose: .sealMigration,
      expectedSignerDeviceID: origin.originDeviceID,
      expectedIdentity: expectedIdentity,
      expectedRecordID: preRecordID)
    let receipt = try TatwoFleetOriginAuthority.decodeBody(
      TatwoFleetSealMigrationReceiptV1.self, from: envelope.body)
    guard receipt.confirmToken == journal.confirmToken,
      receipt.inventoryDigest == journal.inventoryDigest,
      receipt.migrationPlanHash == journal.migrationPlanHash,
      receipt.fleetRootPath == journal.fleetRootPath,
      receipt.authorityEpoch == journal.authorityEpoch,
      receipt.backupDigest == journal.backupDigest,
      receipt.backupDirectory == journal.backupDirectory
    else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration pre-receipt binding does not match journal")
    }
    // Full stage manifest must match receipt.migrated digests/paths.
    let receiptManifest = Dictionary(
      uniqueKeysWithValues: receipt.migrated.map {
        ($0.relativePath, $0.newEnvelopeDigest)
      })
    let journalManifest = Dictionary(
      uniqueKeysWithValues: journal.stageManifest.map {
        ($0.relativePath, $0.newEnvelopeDigest)
      })
    guard receiptManifest == journalManifest,
      Set(receipt.migrated.map(\.relativePath))
        == Set(journal.stageManifest.map(\.relativePath))
    else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration pre-receipt stage manifest does not match journal")
    }
    // Recompute backup digest (defense in depth; also done before swaps).
    try reverifyBackupDigest(journal: journal, root: root)
    // Return a receipt reflecting actually verified completion time.
    return TatwoFleetSealMigrationReceiptV1(
      originDeviceID: receipt.originDeviceID,
      fromEnvelopeSchema: receipt.fromEnvelopeSchema,
      toEnvelopeSchema: receipt.toEnvelopeSchema,
      confirmToken: receipt.confirmToken,
      fleetRootPath: receipt.fleetRootPath,
      inventoryDigest: receipt.inventoryDigest,
      migrationPlanHash: receipt.migrationPlanHash,
      backupDirectory: receipt.backupDirectory,
      authorityEpoch: receipt.authorityEpoch,
      backupDigest: receipt.backupDigest,
      migrated: receipt.migrated,
      skippedAlreadyV2: receipt.skippedAlreadyV2,
      completedAt: now)
  }

  /// Reject absolute / empty / `.` / `..` and non-component-safe relative paths.
  private static func assertSafeMigrationRelativePath(_ relative: String) throws {
    guard !relative.isEmpty else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration relative path must not be empty")
    }
    guard !relative.hasPrefix("/"), !relative.hasPrefix("~") else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration relative path must not be absolute: \(relative)")
    }
    guard relative != ".", relative != ".." else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration relative path rejects \(relative)")
    }
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration relative path has no components")
    }
    for part in parts {
      if part.isEmpty || part == "." || part == ".." {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration relative path rejects component '\(part)' in \(relative)")
      }
      if part.contains("\0") {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration relative path rejects NUL in \(relative)")
      }
    }
  }

  /// Build URL under root and require standardized path stays under root by
  /// component-boundary check (not bare hasPrefix).
  private static func containedURL(relative: String, under root: URL) throws -> URL {
    try assertSafeMigrationRelativePath(relative)
    let rootStd = root.standardizedFileURL
    let candidate = rootStd.appendingPathComponent(relative).standardizedFileURL
    guard isStrictlyUnderRoot(candidate, root: rootStd) else {
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration path escapes root: \(relative)")
    }
    return candidate
  }

  private static func isStrictlyUnderRoot(_ child: URL, root: URL) -> Bool {
    let childPath = child.standardizedFileURL.path
    let parentPath = root.standardizedFileURL.path
    let parentParts = parentPath.split(separator: "/", omittingEmptySubsequences: true)
    let childParts = childPath.split(separator: "/", omittingEmptySubsequences: true)
    // Must be strictly under root (file path ≠ root directory).
    guard childParts.count > parentParts.count else { return false }
    return childParts.starts(with: parentParts)
  }

  private static func writeSignedJournal(
    _ journal: Journal,
    pin: MigrationTxnPin,
    origin: TatwoFleetOriginAuthority
  ) throws {
    _ = try writeSignedMigrationArtifact(
      bodyValue: journal,
      pin: pin,
      relativePath: journalRelativePath,
      origin: origin,
      recordID: journalRecordID)
  }

  @discardableResult
  private static func writeSignedMigrationArtifact<T: Encodable>(
    bodyValue: T,
    pin: MigrationTxnPin,
    relativePath: String,
    origin: TatwoFleetOriginAuthority,
    recordID: String
  ) throws -> String {
    try assertSafeMigrationRelativePath(relativePath)
    let body = try TatwoFleetOriginAuthority.encodeBody(bodyValue)
    let envelope = try origin.seal(
      body: body,
      purpose: .sealMigration,
      recordID: recordID,
      ledgerSequence: 0,
      canonicalRelativePath: relativePath)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(envelope)
    // Receipts-bound artifacts use the transaction-pinned receipts dirfd.
    try pin.writeAtomic(relative: relativePath, data: data)
    return TatwoLoopJobDigest.sha256(data)
  }

  // MARK: - Transaction-scoped root + receipts pin

  /// Holds fleet-parent + fleet-root + `receipts/` directory FDs for an entire
  /// migration transaction.
  /// - Writes under `receipts/` always use the receipts dirfd opened at begin.
  /// - Fleet root pathname is re-checked via `openat(parentFD, basename)` against
  ///   the start `(st_dev, st_ino)` so a real-directory transplant of `$FLEET`
  ///   fail-closes (fstat on the held rootFD alone cannot see that attack).
  /// - Stage cleanup is rootFD-relative and aborts without deleting if the root
  ///   name is unbound.
  private final class MigrationTxnPin {
    private let parentFD: Int32
    private let rootBasename: String
    private let rootFD: Int32
    private let receiptsFD: Int32
    private let rootDev: dev_t
    private let rootIno: ino_t
    private let receiptsDev: dev_t
    private let receiptsIno: ino_t
    private var closed = false

    private init(
      parentFD: Int32,
      rootBasename: String,
      rootFD: Int32,
      receiptsFD: Int32,
      rootDev: dev_t,
      rootIno: ino_t,
      receiptsDev: dev_t,
      receiptsIno: ino_t
    ) {
      self.parentFD = parentFD
      self.rootBasename = rootBasename
      self.rootFD = rootFD
      self.receiptsFD = receiptsFD
      self.rootDev = rootDev
      self.rootIno = rootIno
      self.receiptsDev = receiptsDev
      self.receiptsIno = receiptsIno
    }

    deinit {
      close()
    }

    static func begin(root: URL) throws -> MigrationTxnPin {
      #if canImport(Darwin)
      let rootURL = root.standardizedFileURL
      let path = rootURL.path
      let basename = rootURL.lastPathComponent
      guard !basename.isEmpty, basename != "/", path != "/" else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root path is not pin-able")
      }
      let parentPath = rootURL.deletingLastPathComponent().path

      var lst = stat()
      let lstatRC = path.withCString { cPath in lstat(cPath, &lst) }
      guard lstatRC == 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration cannot lstat fleet root errno=\(errno)")
      }
      if (lst.st_mode & S_IFMT) == S_IFLNK {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root must not be a symlink")
      }

      // Pin the parent directory FD so we can re-resolve basename without
      // walking the $FLEET pathname string again mid-transaction.
      let parentFD = parentPath.withCString { cPath in
        Darwin.open(cPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      }
      guard parentFD >= 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration cannot pin fleet parent directory errno=\(errno)")
      }
      var parentOwned = true
      defer {
        if parentOwned { _ = Darwin.close(parentFD) }
      }

      let rootFD = basename.withCString { cName in
        Darwin.openat(
          parentFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard rootFD >= 0 else {
        if errno == ELOOP {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration fleet root must not be a symlink")
        }
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration cannot pin fleet root directory errno=\(errno)")
      }
      var rootOwned = true
      defer {
        if rootOwned { _ = Darwin.close(rootFD) }
      }
      var rootSt = stat()
      guard fstat(rootFD, &rootSt) == 0, (rootSt.st_mode & S_IFMT) == S_IFDIR else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration pinned root is not a directory")
      }
      guard rootSt.st_ino == lst.st_ino, rootSt.st_dev == lst.st_dev else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root symlink/replace race")
      }

      try ContainedPathIO.ensureDirectory(
        rootFD: rootFD, relative: "receipts", createIntermediates: true)

      let receiptsFD = "receipts".withCString { cName in
        Darwin.openat(
          rootFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard receiptsFD >= 0 else {
        if errno == ELOOP {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration rejects mid-path symlink at receipts")
        }
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration cannot pin receipts directory errno=\(errno)")
      }
      var receiptsOwned = true
      defer {
        if receiptsOwned { _ = Darwin.close(receiptsFD) }
      }
      var receiptsSt = stat()
      guard fstat(receiptsFD, &receiptsSt) == 0,
        (receiptsSt.st_mode & S_IFMT) == S_IFDIR
      else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration pinned receipts is not a directory")
      }

      let pin = MigrationTxnPin(
        parentFD: parentFD,
        rootBasename: basename,
        rootFD: rootFD,
        receiptsFD: receiptsFD,
        rootDev: rootSt.st_dev,
        rootIno: rootSt.st_ino,
        receiptsDev: receiptsSt.st_dev,
        receiptsIno: receiptsSt.st_ino)
      parentOwned = false
      rootOwned = false
      receiptsOwned = false
      return pin
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    func close() {
      #if canImport(Darwin)
      guard !closed else { return }
      closed = true
      _ = Darwin.close(receiptsFD)
      _ = Darwin.close(rootFD)
      _ = Darwin.close(parentFD)
      #endif
    }

    func writeAtomic(relative: String, data: Data) throws {
      let (fd, sub) = try resolve(relative)
      if isUnderReceipts(relative) {
        try assertReceiptsNameBound()
      } else {
        try assertRootNameBound()
      }
      try ContainedPathIO.writeAtomic(rootFD: fd, relative: sub, data: data)
      if isUnderReceipts(relative) {
        try assertReceiptsNameBound()
      } else {
        try assertRootNameBound()
      }
    }

    func readFile(relative: String) throws -> Data {
      let (fd, sub) = try resolve(relative)
      if isUnderReceipts(relative) {
        try assertReceiptsNameBound()
      } else {
        try assertRootNameBound()
      }
      return try ContainedPathIO.readFile(rootFD: fd, relative: sub)
    }

    func ensureDirectory(relative: String, createIntermediates: Bool) throws {
      let (fd, sub) = try resolve(relative)
      if isUnderReceipts(relative) || relative == "receipts" {
        try assertReceiptsNameBound()
      } else {
        try assertRootNameBound()
      }
      try ContainedPathIO.ensureDirectory(
        rootFD: fd, relative: sub, createIntermediates: createIntermediates)
    }

    /// Best-effort recursive remove under the held rootFD.
    /// If `$FLEET` name is unbound mid-transaction, **stop without deleting**
    /// (pathname-based cleanup would hit a transplanted victim tree).
    func removeTreeIfPresentBestEffort(relative: String) {
      #if canImport(Darwin)
      guard !closed else { return }
      do {
        try assertRootNameBound()
      } catch {
        // Unbound root name: never delete by path or by a confused tree.
        return
      }
      try? ContainedPathIO.removeTreeIfPresent(rootFD: rootFD, relative: relative)
      #endif
    }

    /// Fail closed if `$FLEET` pathname no longer names the start root inode.
    func assertRootNameBound() throws {
      #if canImport(Darwin)
      guard !closed else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration pin already closed")
      }
      var pinnedRoot = stat()
      guard fstat(rootFD, &pinnedRoot) == 0,
        pinnedRoot.st_dev == rootDev,
        pinnedRoot.st_ino == rootIno,
        (pinnedRoot.st_mode & S_IFMT) == S_IFDIR
      else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration pinned root identity changed")
      }
      let namedRoot = rootBasename.withCString { cName in
        Darwin.openat(
          parentFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard namedRoot >= 0 else {
        if errno == ELOOP {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration fleet root became a symlink mid-transaction")
        }
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root name missing mid-transaction errno=\(errno)")
      }
      defer { _ = Darwin.close(namedRoot) }
      var named = stat()
      guard fstat(namedRoot, &named) == 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root fstat failed errno=\(errno)")
      }
      guard named.st_dev == rootDev, named.st_ino == rootIno else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root directory replaced mid-transaction")
      }
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    /// Fail closed if `$FLEET/receipts` no longer names the pinned inode.
    func assertReceiptsNameBound() throws {
      #if canImport(Darwin)
      // Root pathname binding first — receipts openat(rootFD, …) alone cannot
      // detect a full `$FLEET` real-directory transplant.
      try assertRootNameBound()
      var pinnedReceipts = stat()
      guard fstat(receiptsFD, &pinnedReceipts) == 0,
        pinnedReceipts.st_dev == receiptsDev,
        pinnedReceipts.st_ino == receiptsIno,
        (pinnedReceipts.st_mode & S_IFMT) == S_IFDIR
      else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration pinned receipts identity changed")
      }
      let check = "receipts".withCString { cName in
        Darwin.openat(
          rootFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard check >= 0 else {
        if errno == ELOOP {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration rejects receipts symlink mid-transaction")
        }
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration receipts name missing mid-transaction errno=\(errno)")
      }
      defer { _ = Darwin.close(check) }
      var named = stat()
      guard fstat(check, &named) == 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration receipts fstat failed errno=\(errno)")
      }
      guard named.st_dev == receiptsDev, named.st_ino == receiptsIno else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration receipts directory replaced mid-transaction")
      }
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    private func isUnderReceipts(_ relative: String) -> Bool {
      relative == "receipts" || relative.hasPrefix("receipts/")
    }

    /// Map fleet-relative path onto the appropriate held dirfd.
    private func resolve(_ relative: String) throws -> (Int32, String) {
      try assertSafeMigrationRelativePath(relative)
      guard !closed else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration pin already closed")
      }
      if relative == "receipts" {
        // Directory ops that target the receipts component itself go via rootFD.
        return (rootFD, "receipts")
      }
      if relative.hasPrefix("receipts/") {
        let rest = String(relative.dropFirst("receipts/".count))
        try assertSafeMigrationRelativePath(rest)
        return (receiptsFD, rest)
      }
      return (rootFD, relative)
    }
  }

  // MARK: - Pinned-root fd-relative path IO (no mid-path symlink escape)

  /// Low-level openat/renameat helpers used under a transaction pin.
  /// Intermediate symlink components are rejected (ELOOP). Callers that need
  /// transaction-lifetime containment must use `MigrationTxnPin`, not reopen
  /// by pathname between writes.
  private enum ContainedPathIO {
    static func withPinnedRoot<T>(
      _ root: URL,
      _ body: (Int32) throws -> T
    ) throws -> T {
      #if canImport(Darwin)
      let path = root.standardizedFileURL.path
      // Reject root itself being a symlink by comparing lstat vs fstat after open.
      var lst = stat()
      let lstatRC = path.withCString { cPath in lstat(cPath, &lst) }
      guard lstatRC == 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration cannot lstat fleet root errno=\(errno)")
      }
      if (lst.st_mode & S_IFMT) == S_IFLNK {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root must not be a symlink")
      }
      let fd = path.withCString { cPath in
        Darwin.open(cPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      }
      guard fd >= 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration cannot pin fleet root directory errno=\(errno)")
      }
      defer { _ = Darwin.close(fd) }
      var st = stat()
      guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration pinned root is not a directory")
      }
      guard st.st_ino == lst.st_ino, st.st_dev == lst.st_dev else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fleet root symlink/replace race")
      }
      return try body(fd)
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    static func ensureDirectory(
      rootFD: Int32,
      relative: String,
      createIntermediates: Bool
    ) throws {
      #if canImport(Darwin)
      try assertSafeMigrationRelativePath(relative)
      let parts = relative.split(separator: "/").map(String.init)
      try withWalkedParent(
        rootFD: rootFD,
        components: parts,
        createIntermediates: createIntermediates
      ) { parentFD, name in
        // Open-or-create the final directory component with O_NOFOLLOW.
        let existing = name.withCString { cName in
          Darwin.openat(
            parentFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if existing >= 0 {
          _ = Darwin.close(existing)
          return
        }
        if errno == ELOOP {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration rejects mid-path symlink at \(relative)")
        }
        if errno == ENOENT && createIntermediates {
          let mk = name.withCString { cName in
            Darwin.mkdirat(parentFD, cName, 0o700)
          }
          if mk != 0, errno != EEXIST {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration mkdirat failed errno=\(errno) at \(relative)")
          }
          let reopened = name.withCString { cName in
            Darwin.openat(
              parentFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          }
          guard reopened >= 0 else {
            if errno == ELOOP {
              throw TatwoFleetAuthorityError.bindingMismatch(
                "seal V2 migration rejects mid-path symlink at \(relative)")
            }
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration openat(dir) failed errno=\(errno) at \(relative)")
          }
          _ = Darwin.close(reopened)
          return
        }
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration ensureDirectory failed errno=\(errno) at \(relative)")
      }
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    static func readFile(rootFD: Int32, relative: String) throws -> Data {
      #if canImport(Darwin)
      try assertSafeMigrationRelativePath(relative)
      let parts = relative.split(separator: "/").map(String.init)
      guard let base = parts.last, !base.isEmpty else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration empty relative path")
      }
      let dirs = Array(parts.dropLast())
      var result: Data?
      try walkToParent(
        rootFD: rootFD,
        dirComponents: dirs,
        createIntermediates: false
      ) { parentFD in
        let fd = base.withCString { cName in
          Darwin.openat(
            parentFD, cName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
          if errno == ELOOP {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration rejects symlink file at \(relative)")
          }
          throw TatwoFleetAuthorityError.missingAuthority(
            "seal V2 migration openat(read) failed errno=\(errno) for \(relative)")
        }
        defer { _ = Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
          throw TatwoFleetAuthorityError.missingAuthority(
            "seal V2 migration fstat failed errno=\(errno) for \(relative)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration path is not a regular file: \(relative)")
        }
        let size = Int(st.st_size)
        if size == 0 {
          result = Data()
          return
        }
        var data = Data(count: size)
        let readCount: Int = try data.withUnsafeMutableBytes { raw in
          guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else {
            throw TatwoFleetAuthorityError.missingAuthority(
              "seal V2 migration read buffer unavailable for \(relative)")
          }
          var offset = 0
          while offset < size {
            let n = Darwin.read(fd, ptr.advanced(by: offset), size - offset)
            if n < 0 {
              if errno == EINTR { continue }
              throw TatwoFleetAuthorityError.missingAuthority(
                "seal V2 migration read failed errno=\(errno) for \(relative)")
            }
            if n == 0 { break }
            offset += n
          }
          return offset
        }
        if readCount < size {
          data.count = readCount
        }
        result = data
      }
      guard let result else {
        throw TatwoFleetAuthorityError.missingAuthority(
          "seal V2 migration read produced no data for \(relative)")
      }
      return result
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    static func writeAtomic(rootFD: Int32, relative: String, data: Data) throws {
      #if canImport(Darwin)
      try assertSafeMigrationRelativePath(relative)
      let parts = relative.split(separator: "/").map(String.init)
      guard let base = parts.last, !base.isEmpty else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration empty relative path")
      }
      let dirs = Array(parts.dropLast())
      try walkToParent(
        rootFD: rootFD,
        dirComponents: dirs,
        createIntermediates: true
      ) { parentFD in
        let tmpName = ".\(base).\(UUID().uuidString).tmp"
        let fd = tmpName.withCString { cTmp in
          Darwin.openat(
            parentFD,
            cTmp,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
          if errno == ELOOP {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration rejects symlink at temp \(relative)")
          }
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration openat(temp) failed errno=\(errno) for \(relative)")
        }
        var stillOpen = true
        defer {
          if stillOpen { _ = Darwin.close(fd) }
          _ = tmpName.withCString { cTmp in
            Darwin.unlinkat(parentFD, cTmp, 0)
          }
        }
        try data.withUnsafeBytes { raw in
          guard let basePtr = raw.bindMemory(to: UInt8.self).baseAddress else {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration empty write buffer")
          }
          var written = 0
          let total = raw.count
          while written < total {
            let n = Darwin.write(fd, basePtr.advanced(by: written), total - written)
            if n < 0 {
              if errno == EINTR { continue }
              throw TatwoFleetAuthorityError.bindingMismatch(
                "seal V2 migration write failed errno=\(errno) for \(relative)")
            }
            written += n
          }
        }
        guard Darwin.fsync(fd) == 0 else {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration fsync failed errno=\(errno) for \(relative)")
        }
        stillOpen = false
        guard Darwin.close(fd) == 0 else {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration close failed errno=\(errno) for \(relative)")
        }
        let ren = tmpName.withCString { cTmp in
          base.withCString { cBase in
            Darwin.renameat(parentFD, cTmp, parentFD, cBase)
          }
        }
        // renameat success: prevent defer unlink of destination name.
        if ren == 0 {
          // Clear tmp unlink by "forgetting" — defer still unlinks tmp; if rename
          // succeeded tmp is gone so unlinkat is harmless ENOENT.
          return
        }
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration renameat failed errno=\(errno) for \(relative)")
      }
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    /// Recursive unlinkat/rmdir under a held rootFD. Missing path is a no-op.
    /// Never re-opens the fleet root by pathname.
    static func removeTreeIfPresent(rootFD: Int32, relative: String) throws {
      #if canImport(Darwin)
      try assertSafeMigrationRelativePath(relative)
      let parts = relative.split(separator: "/").map(String.init)
      guard !parts.isEmpty else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration empty relative path for remove")
      }
      try withWalkedParent(
        rootFD: rootFD,
        components: parts,
        createIntermediates: false
      ) { parentFD, name in
        var st = stat()
        let stRC = name.withCString { cName in
          fstatat(parentFD, cName, &st, AT_SYMLINK_NOFOLLOW)
        }
        if stRC != 0 {
          if errno == ENOENT { return }
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration fstatat(remove) failed errno=\(errno) at \(relative)")
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
          try removeDirectoryTree(parentFD: parentFD, name: name)
        } else {
          let un = name.withCString { cName in
            Darwin.unlinkat(parentFD, cName, 0)
          }
          if un != 0, errno != ENOENT {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration unlinkat failed errno=\(errno) at \(relative)")
          }
        }
      }
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    #if canImport(Darwin)
    /// Empty a directory (fd-relative) then AT_REMOVEDIR it from its parent.
    private static func removeDirectoryTree(parentFD: Int32, name: String) throws {
      let dirFD = name.withCString { cName in
        Darwin.openat(
          parentFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      if dirFD < 0 {
        if errno == ENOENT { return }
        if errno == ELOOP {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration rejects symlink directory during stage cleanup")
        }
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration openat(dir remove) failed errno=\(errno)")
      }
      // fdopendir takes ownership of its fd; keep dirFD for fstatat/unlinkat via dirfd.
      guard let dirp = fdopendir(dirFD) else {
        let e = errno
        _ = Darwin.close(dirFD)
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration fdopendir failed errno=\(e)")
      }
      defer { _ = closedir(dirp) }
      let walkFD = dirfd(dirp)
      guard walkFD >= 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration dirfd failed during stage cleanup")
      }

      while true {
        errno = 0
        guard let ent = readdir(dirp) else {
          if errno != 0 {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration readdir failed errno=\(errno)")
          }
          break
        }
        let child: String = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
          ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cPtr in
            String(cString: cPtr)
          }
        }
        if child == "." || child == ".." { continue }
        var childSt = stat()
        let childRC = child.withCString { cName in
          fstatat(walkFD, cName, &childSt, AT_SYMLINK_NOFOLLOW)
        }
        if childRC != 0 {
          if errno == ENOENT { continue }
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration fstatat(child) failed errno=\(errno)")
        }
        if (childSt.st_mode & S_IFMT) == S_IFDIR {
          try removeDirectoryTree(parentFD: walkFD, name: child)
        } else {
          let un = child.withCString { cName in
            Darwin.unlinkat(walkFD, cName, 0)
          }
          if un != 0, errno != ENOENT {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration unlinkat(child) failed errno=\(errno)")
          }
        }
      }

      let rm = name.withCString { cName in
        Darwin.unlinkat(parentFD, cName, AT_REMOVEDIR)
      }
      if rm != 0, errno != ENOENT {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration rmdirat failed errno=\(errno)")
      }
    }
    #endif

    /// Walk dir components with O_NOFOLLOW|O_DIRECTORY; invoke body with parent fd.
    private static func walkToParent<T>(
      rootFD: Int32,
      dirComponents: [String],
      createIntermediates: Bool,
      body: (Int32) throws -> T
    ) throws -> T {
      #if canImport(Darwin)
      var current = Darwin.dup(rootFD)
      guard current >= 0 else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration dup(rootFD) failed errno=\(errno)")
      }
      defer { _ = Darwin.close(current) }
      for dir in dirComponents {
        if dir.isEmpty || dir == "." || dir == ".." {
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal V2 migration rejects bad dir component \(dir)")
        }
        var next = dir.withCString { cName in
          Darwin.openat(
            current, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if next < 0 {
          if errno == ELOOP {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration rejects mid-path symlink component \(dir)")
          }
          if errno == ENOENT && createIntermediates {
            let mk = dir.withCString { cName in
              Darwin.mkdirat(current, cName, 0o700)
            }
            if mk != 0, errno != EEXIST {
              throw TatwoFleetAuthorityError.bindingMismatch(
                "seal V2 migration mkdirat failed errno=\(errno) component \(dir)")
            }
            next = dir.withCString { cName in
              Darwin.openat(
                current, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
              if errno == ELOOP {
                throw TatwoFleetAuthorityError.bindingMismatch(
                  "seal V2 migration rejects mid-path symlink component \(dir)")
              }
              throw TatwoFleetAuthorityError.bindingMismatch(
                "seal V2 migration openat(dir) failed errno=\(errno) component \(dir)")
            }
          } else {
            throw TatwoFleetAuthorityError.bindingMismatch(
              "seal V2 migration openat(dir) failed errno=\(errno) component \(dir)")
          }
        }
        _ = Darwin.close(current)
        current = next
      }
      return try body(current)
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }

    private static func withWalkedParent<T>(
      rootFD: Int32,
      components: [String],
      createIntermediates: Bool,
      body: (Int32, String) throws -> T
    ) throws -> T {
      #if canImport(Darwin)
      guard let last = components.last else {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal V2 migration empty path components")
      }
      let dirs = Array(components.dropLast())
      return try walkToParent(
        rootFD: rootFD,
        dirComponents: dirs,
        createIntermediates: createIntermediates
      ) { parentFD in
        try body(parentFD, last)
      }
      #else
      throw TatwoFleetAuthorityError.bindingMismatch(
        "seal V2 migration fd-relative IO requires Darwin")
      #endif
    }
  }

  private static func directoryContentDigest(at root: URL) throws -> String {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
    else {
      throw TatwoFleetAuthorityError.missingAuthority("cannot enumerate backup tree")
    }
    var lines: [String] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      let rel = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: root)
      let digest = TatwoLoopJobDigest.sha256(try Data(contentsOf: url))
      lines.append("\(rel)|\(digest)")
    }
    lines.sort()
    return TatwoLoopJobDigest.sha256(Data(lines.joined(separator: "\n").utf8))
  }

  private static func collectInventory(
    root: URL,
    origin: TatwoFleetOriginAuthority
  ) throws -> Inventory {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
    else {
      throw TatwoFleetAuthorityError.missingAuthority("cannot enumerate fleet root")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var v1: [PreparedV1] = []
    var v2Paths: [String] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "json" else { continue }
      // Skip migration artifacts.
      let rel = try TatwoFleetRecordIdentityV1.relativePath(of: url, under: root)
      if rel.hasPrefix("receipts/") || rel.hasPrefix("\(stageDirName)/")
        || rel == lockFileName || rel.hasSuffix(".\(lockFileName)")
      {
        continue
      }
      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        throw TatwoFleetAuthorityError.missingAuthority(
          "seal V2 preflight cannot read \(rel): \(error.localizedDescription)")
      }
      guard let envelope = try? decoder.decode(TatwoFleetSignedEnvelopeV1.self, from: data)
      else {
        // Non-envelope JSON is out of scope (not fail).
        continue
      }
      if envelope.schema == TatwoFleetSignedEnvelopeV1.schemaName {
        // Already V2: verify signature so mixed corruption cannot hide as "skip".
        guard let purpose = TatwoFleetSignaturePurposeV1(rawValue: envelope.purpose) else {
          throw TatwoFleetAuthorityError.signatureRejected(
            "unknown purpose on V2 envelope at \(rel)")
        }
        if purpose == .sealMigration {
          // Migration artifacts under non-receipt paths are unexpected.
          throw TatwoFleetAuthorityError.bindingMismatch(
            "seal-migration envelope outside receipts/ at \(rel)")
        }
        if purpose != .deviceReport {
          let expectedRecordID = TatwoFleetRecordIdentityV1.expectedRecordID(
            purpose: purpose,
            canonicalRelativePath: rel,
            ledgerSequence: envelope.ledgerSequence)
          let expectedIdentity = TatwoFleetRecordIdentityV1(
            purpose: purpose,
            canonicalRelativePath: rel,
            originDeviceID: envelope.originDeviceID,
            ledgerSequence: envelope.ledgerSequence,
            authorityEpoch: envelope.authorityEpoch)
          try origin.verifyEnvelope(
            envelope,
            expectedPurpose: purpose,
            expectedSignerDeviceID: origin.originDeviceID,
            expectedIdentity: expectedIdentity,
            expectedRecordID: expectedRecordID)
        }
        v2Paths.append(rel)
        continue
      }
      guard envelope.schema == TatwoFleetSignedEnvelopeV1.legacySchemaName else {
        throw TatwoFleetAuthorityError.forgedOrUnsignedRecord(
          "unsupported envelope schema \(envelope.schema) at \(rel)")
      }
      guard let purpose = TatwoFleetSignaturePurposeV1(rawValue: envelope.purpose) else {
        throw TatwoFleetAuthorityError.signatureRejected(
          "unknown purpose \(envelope.purpose) at \(rel)")
      }
      if purpose == .deviceReport {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "device-report V1 at \(rel) cannot be origin-migrated; "
            + "targets must re-emit V2 heartbeats")
      }
      if purpose == .sealMigration {
        throw TatwoFleetAuthorityError.bindingMismatch(
          "seal-migration V1 is unsupported at \(rel)")
      }
      let expectedRecordID = TatwoFleetRecordIdentityV1.expectedRecordID(
        purpose: purpose,
        canonicalRelativePath: rel,
        ledgerSequence: envelope.ledgerSequence)
      let expectedIdentity = TatwoFleetRecordIdentityV1(
        purpose: purpose,
        canonicalRelativePath: rel,
        originDeviceID: envelope.originDeviceID,
        ledgerSequence: envelope.ledgerSequence,
        authorityEpoch: envelope.authorityEpoch)
      try origin.verifyLegacyEnvelopeV1ForMigrationOnly(
        envelope,
        expectedPurpose: purpose,
        expectedSignerDeviceID: origin.originDeviceID,
        expectedIdentity: expectedIdentity,
        expectedRecordID: expectedRecordID)
      let bodyID = try TatwoFleetBodyRecordIDExtractor.extract(
        purpose: purpose, body: envelope.body)
      guard bodyID == expectedRecordID, bodyID == envelope.recordID else {
        throw TatwoFleetAuthorityError.recordIdentityMismatch(
          "migration triple bind failed body=\(bodyID) envelope=\(envelope.recordID) "
            + "path=\(expectedRecordID) at \(rel)")
      }
      v1.append(
        PreparedV1(
          relativePath: rel,
          purpose: purpose,
          recordID: expectedRecordID,
          ledgerSequence: envelope.ledgerSequence,
          authorityEpoch: envelope.authorityEpoch,
          originDeviceID: envelope.originDeviceID,
          priorBodyDigest: envelope.bodyDigest,
          priorEnvelopeDigest: TatwoLoopJobDigest.sha256(data),
          body: envelope.body,
          sourceURL: url))
    }
    v1.sort { $0.relativePath < $1.relativePath }
    return Inventory(v1: v1, v2Paths: v2Paths)
  }

  private static func inventoryDigest(for inventory: Inventory) -> String {
    var lines: [String] = []
    for item in inventory.v1 {
      lines.append(
        "v1|\(item.relativePath)|\(item.purpose.rawValue)|\(item.recordID)|"
          + "\(item.ledgerSequence)|\(item.priorEnvelopeDigest)")
    }
    for path in inventory.v2Paths.sorted() {
      lines.append("v2|\(path)")
    }
    return TatwoLoopJobDigest.sha256(Data(lines.joined(separator: "\n").utf8))
  }

  #if canImport(Darwin)
  private static func optionalOpen(_ path: String) -> Int32? {
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    return fd >= 0 ? fd : nil
  }
  #endif
}
