import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// MARK: - Authorization (human gate token)

/// Per-apply human gate token. Core never applies without a matching plan digest.
///
/// CLI loads this from `--authorization <file>`; there is no default approver and
/// no default path to `~/.codex` / `~/.claude`.
public struct TatwoPluginApplyAuthorizationV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoPluginApplyAuthorizationV1"

  public let schema: String
  /// Digest of the exact staged plan approved by a human (see `TatwoPluginApplyEngineV1.planDigest`).
  public let approvedPlanDigest: String
  /// Canonical realpath-normalized target approved by the human.
  public let approvedTargetPath: String
  /// Canonical realpath-normalized targets approved by the human.  The
  /// singular field is retained for wire compatibility with S3 receipts.
  public let approvedTargetPaths: [String]
  /// Brand surface approved by the human.
  public let approvedBrand: TatwoPluginProjectionBrandV1
  public let approver: String
  /// RFC3339 / ISO-8601 timestamp of human approval.
  public let approvedAt: String

  public init(
    schema: String = TatwoPluginApplyAuthorizationV1.schemaName,
    approvedPlanDigest: String,
    approvedTargetPath: String,
    approvedBrand: TatwoPluginProjectionBrandV1,
    approver: String,
    approvedAt: String
  ) {
    self.schema = schema
    self.approvedPlanDigest = approvedPlanDigest.lowercased()
    self.approvedTargetPath = TatwoPluginApplyEngineV1.canonicalTargetPath(approvedTargetPath)
    self.approvedTargetPaths = [self.approvedTargetPath]
    self.approvedBrand = approvedBrand
    self.approver = approver
    self.approvedAt = approvedAt
  }

  public init(
    schema: String = TatwoPluginApplyAuthorizationV1.schemaName,
    approvedTargetPaths: [String],
    approvedPlanDigest: String,
    approvedBrand: TatwoPluginProjectionBrandV1,
    approver: String,
    approvedAt: String
  ) {
    let canonical = approvedTargetPaths
      .map { TatwoPluginApplyEngineV1.canonicalTargetPath($0) }
      .filter { !$0.isEmpty }
    var unique: [String] = []
    for path in canonical where !unique.contains(path) {
      unique.append(path)
    }
    self.schema = schema
    self.approvedPlanDigest = approvedPlanDigest.lowercased()
    self.approvedTargetPaths = unique
    self.approvedTargetPath = self.approvedTargetPaths.first ?? ""
    self.approvedBrand = approvedBrand
    self.approver = approver
    self.approvedAt = approvedAt
  }

  private enum CodingKeys: String, CodingKey {
    case schema
    case approvedPlanDigest
    case approvedTargetPath
    case approvedTargetPaths
    case approvedBrand
    case approver
    case approvedAt
  }

  /// Decode through the same canonicalization path as the public initializer.
  ///
  /// Synthesized `Decodable` would assign the wire value directly and could
  /// therefore leave a relative path, `~`, or a symlinked path un-normalized
  /// before the apply target comparison.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let schema = try c.decode(String.self, forKey: .schema)
    let digest = try c.decode(String.self, forKey: .approvedPlanDigest)
    let brand = try c.decode(TatwoPluginProjectionBrandV1.self, forKey: .approvedBrand)
    let approver = try c.decode(String.self, forKey: .approver)
    let approvedAt = try c.decode(String.self, forKey: .approvedAt)
    if let paths = try c.decodeIfPresent([String].self, forKey: .approvedTargetPaths) {
      self.init(
        schema: schema,
        approvedTargetPaths: paths,
        approvedPlanDigest: digest,
        approvedBrand: brand,
        approver: approver,
        approvedAt: approvedAt)
    } else {
      self.init(
        schema: schema,
        approvedPlanDigest: digest,
        approvedTargetPath: try c.decode(String.self, forKey: .approvedTargetPath),
        approvedBrand: brand,
        approver: approver,
        approvedAt: approvedAt)
    }
  }
}

// MARK: - Receipts

public enum TatwoPluginApplyStatusV1: String, Codable, Sendable, Equatable {
  case applied
  case noop
  case rejected
  case applyFailed = "apply_failed"
  case rolledBack = "rolled_back"
}

public struct TatwoPluginApplyReceiptV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoPluginApplyReceiptV1"

  public let schema: String
  public let status: TatwoPluginApplyStatusV1
  public let registryRevision: String
  public let planDigest: String
  public let targetPath: String
  public let targetPaths: [String]
  public let backupPath: String?
  public let backupPaths: [String]
  public let beforeSHA256: String?
  public let afterSHA256: String?
  public let ownershipRecords: [TatwoPluginOwnershipRecordV1]
  public let appliedEntryIDs: [String]
  public let skippedEntryIDs: [String]
  public let approver: String
  public let approvedAt: String
  public let recordedAt: String
  public let notes: [String]
  public let error: String?

  private enum CodingKeys: String, CodingKey {
    case schema, status, registryRevision, planDigest, targetPath, targetPaths
    case backupPath, backupPaths
    case beforeSHA256, afterSHA256, ownershipRecords, appliedEntryIDs
    case skippedEntryIDs, approver, approvedAt, recordedAt, notes, error
  }

  public init(
    schema: String = TatwoPluginApplyReceiptV1.schemaName,
    status: TatwoPluginApplyStatusV1,
    registryRevision: String,
    planDigest: String,
    targetPath: String,
    targetPaths: [String] = [],
    backupPath: String? = nil,
    backupPaths: [String] = [],
    beforeSHA256: String? = nil,
    afterSHA256: String? = nil,
    ownershipRecords: [TatwoPluginOwnershipRecordV1] = [],
    appliedEntryIDs: [String] = [],
    skippedEntryIDs: [String] = [],
    approver: String,
    approvedAt: String,
    recordedAt: String,
    notes: [String] = [],
    error: String? = nil
  ) {
    self.schema = schema
    self.status = status
    self.registryRevision = registryRevision
    self.planDigest = planDigest.lowercased()
    self.targetPath = targetPath
    self.targetPaths = targetPaths.isEmpty ? [targetPath] : targetPaths
    self.backupPath = backupPath
    self.backupPaths = backupPaths.isEmpty ? backupPath.map { [$0] } ?? [] : backupPaths
    self.beforeSHA256 = beforeSHA256?.lowercased()
    self.afterSHA256 = afterSHA256?.lowercased()
    self.ownershipRecords = ownershipRecords
    self.appliedEntryIDs = appliedEntryIDs
    self.skippedEntryIDs = skippedEntryIDs
    self.approver = approver
    self.approvedAt = approvedAt
    self.recordedAt = recordedAt
    self.notes = notes
    self.error = error
  }

  /// Keep receipts written before the M-wave notes field readable.  New
  /// security/provenance fields are additive; missing notes decode to [].
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.schema = try c.decode(String.self, forKey: .schema)
    self.status = try c.decode(TatwoPluginApplyStatusV1.self, forKey: .status)
    self.registryRevision = try c.decode(String.self, forKey: .registryRevision)
    self.planDigest = try c.decode(String.self, forKey: .planDigest).lowercased()
    self.targetPath = try c.decode(String.self, forKey: .targetPath)
    self.targetPaths =
      try c.decodeIfPresent([String].self, forKey: .targetPaths) ?? [self.targetPath]
    self.backupPath = try c.decodeIfPresent(String.self, forKey: .backupPath)
    self.backupPaths =
      try c.decodeIfPresent([String].self, forKey: .backupPaths)
      ?? self.backupPath.map { [$0] } ?? []
    self.beforeSHA256 = try c.decodeIfPresent(String.self, forKey: .beforeSHA256)?.lowercased()
    self.afterSHA256 = try c.decodeIfPresent(String.self, forKey: .afterSHA256)?.lowercased()
    self.ownershipRecords =
      try c.decodeIfPresent([TatwoPluginOwnershipRecordV1].self, forKey: .ownershipRecords) ?? []
    self.appliedEntryIDs =
      try c.decodeIfPresent([String].self, forKey: .appliedEntryIDs) ?? []
    self.skippedEntryIDs =
      try c.decodeIfPresent([String].self, forKey: .skippedEntryIDs) ?? []
    self.approver = try c.decode(String.self, forKey: .approver)
    self.approvedAt = try c.decode(String.self, forKey: .approvedAt)
    self.recordedAt = try c.decode(String.self, forKey: .recordedAt)
    self.notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    self.error = try c.decodeIfPresent(String.self, forKey: .error)
  }
}

public enum TatwoPluginRollbackStatusV1: String, Codable, Sendable, Equatable {
  case rollbackPassed = "rollback_passed"
  case rollbackFailed = "rollback_failed"
}

public struct TatwoPluginRollbackReceiptV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoPluginRollbackReceiptV1"

  public let schema: String
  public let status: TatwoPluginRollbackStatusV1
  public let targetPath: String
  public let backupPath: String?
  public let restoredSHA256: String?
  public let originalApplyPlanDigest: String
  public let originalApplyStatus: TatwoPluginApplyStatusV1
  public let ownershipRecordsBefore: [TatwoPluginOwnershipRecordV1]
  public let ownershipRecordsAfter: [TatwoPluginOwnershipRecordV1]
  public let provenanceNote: String
  public let recordedAt: String
  public let error: String?

  private enum CodingKeys: String, CodingKey {
    case schema, status, targetPath, backupPath, restoredSHA256
    case originalApplyPlanDigest, originalApplyStatus
    case ownershipRecordsBefore, ownershipRecordsAfter, provenanceNote
    case recordedAt, error
  }

  public init(
    schema: String = TatwoPluginRollbackReceiptV1.schemaName,
    status: TatwoPluginRollbackStatusV1,
    targetPath: String,
    backupPath: String? = nil,
    restoredSHA256: String? = nil,
    originalApplyPlanDigest: String,
    originalApplyStatus: TatwoPluginApplyStatusV1,
    ownershipRecordsBefore: [TatwoPluginOwnershipRecordV1] = [],
    ownershipRecordsAfter: [TatwoPluginOwnershipRecordV1] = [],
    provenanceNote: String = "",
    recordedAt: String,
    error: String? = nil
  ) {
    self.schema = schema
    self.status = status
    self.targetPath = targetPath
    self.backupPath = backupPath
    self.restoredSHA256 = restoredSHA256?.lowercased()
    self.originalApplyPlanDigest = originalApplyPlanDigest.lowercased()
    self.originalApplyStatus = originalApplyStatus
    self.ownershipRecordsBefore = ownershipRecordsBefore
    self.ownershipRecordsAfter = ownershipRecordsAfter
    self.provenanceNote = provenanceNote
    self.recordedAt = recordedAt
    self.error = error
  }

  /// Decode pre-provenance rollback receipts conservatively.  Missing
  /// ownership deltas are represented as empty arrays and an empty note.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.schema = try c.decode(String.self, forKey: .schema)
    self.status = try c.decode(TatwoPluginRollbackStatusV1.self, forKey: .status)
    self.targetPath = try c.decode(String.self, forKey: .targetPath)
    self.backupPath = try c.decodeIfPresent(String.self, forKey: .backupPath)
    self.restoredSHA256 = try c.decodeIfPresent(String.self, forKey: .restoredSHA256)?.lowercased()
    self.originalApplyPlanDigest =
      try c.decode(String.self, forKey: .originalApplyPlanDigest).lowercased()
    self.originalApplyStatus =
      try c.decode(TatwoPluginApplyStatusV1.self, forKey: .originalApplyStatus)
    self.ownershipRecordsBefore =
      try c.decodeIfPresent([TatwoPluginOwnershipRecordV1].self, forKey: .ownershipRecordsBefore) ?? []
    self.ownershipRecordsAfter =
      try c.decodeIfPresent([TatwoPluginOwnershipRecordV1].self, forKey: .ownershipRecordsAfter) ?? []
    self.provenanceNote = try c.decodeIfPresent(String.self, forKey: .provenanceNote) ?? ""
    self.recordedAt = try c.decode(String.self, forKey: .recordedAt)
    self.error = try c.decodeIfPresent(String.self, forKey: .error)
  }
}

// MARK: - Errors

public enum TatwoPluginApplyErrorV1: Error, LocalizedError, Sendable, Equatable {
  case planContainsConflict([String])
  case authorizationDigestMismatch(expected: String, approved: String)
  case authorizationTargetMismatch(expected: String, approved: String)
  case authorizationBrandMismatch(expected: TatwoPluginProjectionBrandV1, approved: TatwoPluginProjectionBrandV1)
  case authorizationMissingApprover
  case emptyTargetPath
  case userHomeConfigRequiresAck(String)
  case backupAlreadyExists(String)
  case backupReservationFailed(String)
  case backupMissing(String)
  case noApplyableItems
  case mixedBrands([String])
  case missingProjectedBody(String)
  case writeFailed(String)
  case readbackMismatch(String)
  case rollbackFailed(String)
  case unreadableTarget(String)
  case invalidPlanSchema(String)
  case multipleTargetsUnsupported(Int)
  case prepareFailed(String)
  case partialCommitRolledBack(restoredTargets: [String], detail: String)
  case recoveryFailed(String)

  public var errorDescription: String? {
    switch self {
    case .planContainsConflict(let ids):
      return "Apply rejected: plan contains conflict item(s) \(ids.joined(separator: ", ")); whole batch refused (no partial apply)"
    case .authorizationDigestMismatch(let expected, let approved):
      return "Apply rejected: humanGateToken.approvedPlanDigest \(approved) does not match plan digest \(expected)"
    case .authorizationTargetMismatch(let expected, let approved):
      return "Apply rejected: humanGateToken.approvedTargetPath \(approved) does not match canonical target \(expected)"
    case .authorizationBrandMismatch(let expected, let approved):
      return "Apply rejected: humanGateToken.approvedBrand \(approved.rawValue) does not match apply brand \(expected.rawValue)"
    case .authorizationMissingApprover:
      return "Apply rejected: humanGateToken.approver is empty"
    case .emptyTargetPath:
      return "Apply rejected: target path is empty (must inject fixture/target; no default home)"
    case .userHomeConfigRequiresAck(let path):
      return "Apply rejected: target \(path) is under user home agent config; pass acknowledgeUserConfigTarget / CLI --i-understand-user-config (human must add this flag)"
    case .backupAlreadyExists(let path):
      return "Apply rejected: backup already exists and will not be overwritten: \(path)"
    case .backupReservationFailed(let path):
      return "Apply rejected: could not reserve a unique backup path after bounded retries: \(path)"
    case .backupMissing(let path):
      return "Rollback fail-closed: backup missing at \(path)"
    case .noApplyableItems:
      return "Apply has no create/update items (noop requires valid gate still)"
    case .mixedBrands(let brands):
      return "Apply rejected: plan create/update items span mixed brands \(brands.joined(separator: ", ")); one target apply requires one brand"
    case .missingProjectedBody(let id):
      return "Apply rejected: item \(id) missing projectedBody"
    case .writeFailed(let detail):
      return "Apply write failed: \(detail)"
    case .readbackMismatch(let detail):
      return "Apply read-back mismatch: \(detail)"
    case .rollbackFailed(let detail):
      return "Rollback failed: \(detail)"
    case .unreadableTarget(let path):
      return "Apply target unreadable: \(path)"
    case .invalidPlanSchema(let schema):
      return "Apply rejected: unexpected plan schema \(schema)"
    case .multipleTargetsUnsupported(let count):
      return "Apply rejected: invalid target set (got \(count))"
    case .prepareFailed(let detail):
      return "Apply prepare failed: \(detail); no target was modified"
    case .partialCommitRolledBack(let restoredTargets, let detail):
      return "Apply partial commit rolled back: \(detail); restored targets: \(restoredTargets.joined(separator: ", "))"
    case .recoveryFailed(let detail):
      return "Apply crash recovery failed: \(detail)"
    }
  }
}

// MARK: - File IO (injectable for tests)

/// Narrow file surface used by the apply engine. Production uses `TatwoPluginDefaultApplyFileIO`.
public protocol TatwoPluginApplyFileIO: Sendable {
  func fileExists(at url: URL) -> Bool
  func readData(from url: URL) throws -> Data
  func writeAtomically(_ data: Data, to url: URL) throws
  func copyItem(at source: URL, to destination: URL) throws
  /// Reserve a destination without overwriting an existing path.
  ///
  /// This is a protocol requirement (rather than only an extension helper)
  /// so calls through `any TatwoPluginApplyFileIO` dynamically dispatch to
  /// production's POSIX O_EXCL implementation.
  func copyItemExclusively(at source: URL, to destination: URL) throws
  func removeItem(at url: URL) throws
  func createDirectory(at url: URL) throws
  func renameItem(at source: URL, to destination: URL) throws
  func appendData(_ data: Data, to url: URL) throws
}

public extension TatwoPluginApplyFileIO {
  /// Default compatibility path for test doubles. Production overrides this
  /// with a POSIX O_EXCL reservation.
  func copyItemExclusively(at source: URL, to destination: URL) throws {
    try copyItem(at: source, to: destination)
  }

  /// Test-double compatibility implementation. Production overrides this with
  /// a direct same-filesystem POSIX rename.
  func renameItem(at source: URL, to destination: URL) throws {
    let data = try readData(from: source)
    try writeAtomically(data, to: destination)
    try removeItem(at: source)
  }

  func appendData(_ data: Data, to url: URL) throws {
    let existing = fileExists(at: url) ? try readData(from: url) : Data()
    try writeAtomically(existing + data, to: url)
  }
}

public struct TatwoPluginDefaultApplyFileIO: TatwoPluginApplyFileIO {
  public init() {}

  public func fileExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  public func readData(from url: URL) throws -> Data {
    try Data(contentsOf: url)
  }

  public func writeAtomically(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).tatwo-apply.\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporary, options: [.atomic])
      let result = temporary.path.withCString { source in
        url.path.withCString { destination in
          rename(source, destination)
        }
      }
      guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  public func copyItem(at source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  public func copyItemExclusively(at source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let data = try Data(contentsOf: source)
    #if canImport(Darwin)
      let descriptor = Darwin.open(
        destination.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        S_IRUSR | S_IWUSR)
    #elseif canImport(Glibc)
      let descriptor = Glibc.open(
        destination.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        S_IRUSR | S_IWUSR)
    #endif
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var descriptorOpen = true
    var completed = false
    defer {
      if descriptorOpen {
        #if canImport(Darwin)
          _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
          _ = Glibc.close(descriptor)
        #endif
      }
      if !completed {
        try? FileManager.default.removeItem(at: destination)
      }
    }
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        #if canImport(Darwin)
          let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        #elseif canImport(Glibc)
          let written = Glibc.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        #endif
        if written < 0, errno == EINTR { continue }
        guard written > 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        offset += written
      }
    }
    #if canImport(Darwin)
      guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let closeResult = Darwin.close(descriptor)
      descriptorOpen = false
      guard closeResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    #elseif canImport(Glibc)
      guard Glibc.fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let closeResult = Glibc.close(descriptor)
      descriptorOpen = false
      guard closeResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    #endif
    completed = true
  }

  public func removeItem(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }

  public func createDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  public func renameItem(at source: URL, to destination: URL) throws {
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        rename(sourcePath, destinationPath)
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  public func appendData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      try data.write(to: url, options: [.atomic])
      return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }
}

public enum TatwoPluginApplyRecoveryStatusV1: String, Codable, Sendable, Equatable {
  case notNeeded = "not_needed"
  case recovered
}

public struct TatwoPluginApplyRecoveryReceiptV1: Codable, Sendable, Equatable {
  public static let schemaName = "TatwoPluginApplyRecoveryReceiptV1"

  public let schema: String
  public let status: TatwoPluginApplyRecoveryStatusV1
  public let journalPath: String
  public let restoredTargets: [String]
  public let cleanedTempPaths: [String]
  public let recordedAt: String
  public let error: String?

  public init(
    schema: String = TatwoPluginApplyRecoveryReceiptV1.schemaName,
    status: TatwoPluginApplyRecoveryStatusV1,
    journalPath: String,
    restoredTargets: [String] = [],
    cleanedTempPaths: [String] = [],
    recordedAt: String,
    error: String? = nil
  ) {
    self.schema = schema
    self.status = status
    self.journalPath = journalPath
    self.restoredTargets = restoredTargets
    self.cleanedTempPaths = cleanedTempPaths
    self.recordedAt = recordedAt
    self.error = error
  }
}

// MARK: - Engine

/// S3 apply engine: staged plan + **injected** target path + human gate token.
///
/// Never defaults to real `~/.codex` / `~/.claude`. Writing under those trees
/// requires explicit `acknowledgeUserConfigTarget: true` (CLI: `--i-understand-user-config`).
public enum TatwoPluginApplyEngineV1 {
  public static let engineVersion = "s3-apply-v1"
  public static let singleTargetPolicyNote =
    "legacy note: single-target callers are supported; batch apply uses the same transaction engine"
  public static let transactionNote =
    "two-phase transaction: prepare journal + same-filesystem temp rename + read-back verification"
  private static let backupReservationRetryLimit = 64
  private static let journalSchema = "TatwoPluginApplyJournalV1"

  private struct JournalRecord: Codable {
    let schema: String
    let transactionID: String
    let phase: String
    let targetPath: String?
    let tempPath: String?
    let backupPath: String?
    let existed: Bool?
    let beforeSHA256: String?
    let expectedSHA256: String?
    let occurredAt: String
    /// SHA-256 of the previous record in this transaction.  The first
    /// record is anchored to the approved plan digest.
    var chainDigest: String = ""
    /// Human-gate binding for the whole transaction.  Every record repeats it
    /// so recovery can reject mixed-authorisation journals before mutation.
    var transactionAuthorizationDigest: String = ""
    /// Canonical realpath-normalized targets approved for this transaction.
    /// Recovery uses this set to reject journal-directed paths outside the
    /// human-authorized target collection.
    var authorizationTargetPaths: [String] = []
  }

  private struct PreparedTarget {
    let targetURL: URL
    let tempURL: URL
    let backupURL: URL?
    let existed: Bool
    let beforeData: Data?
    let beforeSHA256: String?
    let expectedSHA256: String
    let payload: Data
  }

  // MARK: Digest

  /// Stable plan digest bound into the human gate token.
  public static func planDigest(_ plan: TatwoPluginStagedPlanDocumentV1) -> String {
    var lines: [String] = []
    lines.append("schema=\(plan.schema)")
    lines.append("registryRevision=\(plan.registryRevision)")
    lines.append("rendererVersion=\(plan.rendererVersion)")
    lines.append("brands=\(plan.brands.map(\.rawValue).sorted().joined(separator: ","))")
    for item in plan.items.sorted(by: { $0.id < $1.id }) {
      lines.append(
        [
          "id=\(item.id)",
          "action=\(item.action.rawValue)",
          "entryType=\(item.entryType.rawValue)",
          "logicalPath=\(item.logicalPath ?? "")",
          "templateID=\(item.templateID ?? "")",
          "projectedBody=\(item.projectedBody ?? "")",
          "desiredManagedText=\(item.desiredManagedText ?? "")",
          "observedManagedText=\(item.observedManagedText ?? "")",
          "unifiedDiff=\(item.unifiedDiff)",
          "reason=\(item.reason ?? "")",
        ].joined(separator: "|"))
    }
    return sha256Hex(Data(lines.joined(separator: "\n").utf8))
  }

  public static func loadAuthorization(from url: URL) throws -> TatwoPluginApplyAuthorizationV1 {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    let token = try decoder.decode(TatwoPluginApplyAuthorizationV1.self, from: data)
    guard token.schema == TatwoPluginApplyAuthorizationV1.schemaName else {
      throw TatwoPluginApplyErrorV1.authorizationMissingApprover
    }
    return token
  }

  // MARK: Apply

  /// Apply staged plan to an injected target path. Single-target callers use
  /// the same two-phase transaction engine as multi-target callers.
  @discardableResult
  public static func apply(
    plan: TatwoPluginStagedPlanDocumentV1,
    targetPath: String,
    humanGateToken: TatwoPluginApplyAuthorizationV1,
    acknowledgeUserConfigTarget: Bool = false,
    now: Date = Date(),
    fileIO: any TatwoPluginApplyFileIO = TatwoPluginDefaultApplyFileIO(),
    journalPath: String? = nil
  ) throws -> TatwoPluginApplyReceiptV1 {
    try apply(
      plan: plan,
      targetPaths: [targetPath],
      humanGateToken: humanGateToken,
      acknowledgeUserConfigTarget: acknowledgeUserConfigTarget,
      now: now,
      fileIO: fileIO,
      journalPath: journalPath)
  }

  /// Prepare and commit a plan across all targets as one logical transaction.
  /// No target is renamed until every target has a conflict-free backup, a
  /// same-directory temp file, and a durable prepare-journal record.
  @discardableResult
  public static func apply(
    plan: TatwoPluginStagedPlanDocumentV1,
    targetPaths: [String],
    humanGateToken: TatwoPluginApplyAuthorizationV1,
    acknowledgeUserConfigTarget: Bool = false,
    now: Date = Date(),
    fileIO: any TatwoPluginApplyFileIO = TatwoPluginDefaultApplyFileIO(),
    journalPath: String? = nil
  ) throws -> TatwoPluginApplyReceiptV1 {
    let recordedAt = iso8601(now)
    let digest = try validatePlanAndAuthorization(
      plan: plan,
      targetPaths: targetPaths,
      humanGateToken: humanGateToken,
      acknowledgeUserConfigTarget: acknowledgeUserConfigTarget)
    let canonicalTargets = targetPaths.map(canonicalTargetPath)
    let applyable = plan.items.filter { $0.action == .create || $0.action == .update }
    let skipped = plan.items
      .filter { $0.action == .unchanged || $0.action == .notProjectable }
      .map(\.entryID)
      .sorted()

    let expectedBrand: TatwoPluginProjectionBrandV1
    if applyable.isEmpty {
      guard plan.brands.count == 1, let brand = plan.brands.first else {
        throw TatwoPluginApplyErrorV1.mixedBrands(plan.brands.map(\.rawValue).sorted())
      }
      expectedBrand = brand
    } else {
      let brands = Set(applyable.map(\.brand))
      guard brands.count == 1, let brand = brands.first else {
        throw TatwoPluginApplyErrorV1.mixedBrands(brands.map(\.rawValue).sorted())
      }
      expectedBrand = brand
    }

    guard !applyable.isEmpty else {
      return TatwoPluginApplyReceiptV1(
        status: .noop,
        registryRevision: plan.registryRevision,
        planDigest: digest,
        targetPath: canonicalTargets[0],
        targetPaths: canonicalTargets,
        ownershipRecords: [],
        appliedEntryIDs: [],
        skippedEntryIDs: skipped,
        approver: humanGateToken.approver,
        approvedAt: humanGateToken.approvedAt,
        recordedAt: recordedAt,
        notes: [transactionNote])
    }
    for item in applyable where item.projectedBody == nil || item.projectedBody?.isEmpty == true {
      throw TatwoPluginApplyErrorV1.missingProjectedBody(item.entryID)
    }

    let transactionID = UUID().uuidString
    let journalURL = URL(fileURLWithPath: journalPath ?? defaultJournalPath(for: canonicalTargets))
    var prepared: [PreparedTarget] = []
    prepared.reserveCapacity(canonicalTargets.count)
    var journalPreviousDigest: String?

    do {
      for (index, targetPath) in canonicalTargets.enumerated() {
        let targetURL = URL(fileURLWithPath: targetPath)
        let existed = fileIO.fileExists(at: targetURL)
        let beforeData = existed ? try fileIO.readData(from: targetURL) : nil
        let beforeSHA = beforeData.map { sha256Hex($0) }
        let existingText = beforeData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let mergedText = try mergeProjectedBodies(
          existingText: existingText,
          brand: expectedBrand,
          items: applyable)
        let payload = Data(mergedText.utf8)
        let expectedSHA = sha256Hex(payload)

        var backupURL: URL?
        if existed {
          backupURL = try reserveBackup(
            targetURL: targetURL,
            now: now,
            fileIO: fileIO)
        }
        let tempURL = reserveTemp(
          targetURL: targetURL,
          transactionID: transactionID,
          index: index,
          fileIO: fileIO)
        try fileIO.writeAtomically(payload, to: tempURL)
        let preparedTarget = PreparedTarget(
          targetURL: targetURL,
          tempURL: tempURL,
          backupURL: backupURL,
          existed: existed,
          beforeData: beforeData,
          beforeSHA256: beforeSHA,
          expectedSHA256: expectedSHA,
          payload: payload)
        prepared.append(preparedTarget)
        try appendJournal(
          JournalRecord(
            schema: journalSchema,
            transactionID: transactionID,
            phase: "prepare",
            targetPath: targetURL.path,
            tempPath: tempURL.path,
            backupPath: backupURL?.path,
            existed: existed,
            beforeSHA256: beforeSHA,
            expectedSHA256: expectedSHA,
            occurredAt: recordedAt),
          to: journalURL,
          authorizationDigest: digest,
          authorizationTargetPaths: canonicalTargets,
          previousRecordDigest: &journalPreviousDigest,
          fileIO: fileIO)
      }
    } catch {
      for item in prepared {
        try? fileIO.removeItem(at: item.tempURL)
      }
      try? appendJournal(
        JournalRecord(
          schema: journalSchema,
          transactionID: transactionID,
          phase: "aborted",
          targetPath: nil,
          tempPath: nil,
          backupPath: nil,
          existed: nil,
          beforeSHA256: nil,
          expectedSHA256: nil,
          occurredAt: recordedAt),
        to: journalURL,
        authorizationDigest: digest,
        authorizationTargetPaths: canonicalTargets,
        previousRecordDigest: &journalPreviousDigest,
        fileIO: fileIO)
      throw TatwoPluginApplyErrorV1.prepareFailed(error.localizedDescription)
    }

    var committed = Set<Int>()
    do {
      try appendJournal(
        JournalRecord(
          schema: journalSchema,
          transactionID: transactionID,
          phase: "commitStarted",
          targetPath: nil,
          tempPath: nil,
          backupPath: nil,
          existed: nil,
          beforeSHA256: nil,
          expectedSHA256: nil,
          occurredAt: recordedAt),
        to: journalURL,
        authorizationDigest: digest,
        authorizationTargetPaths: canonicalTargets,
        previousRecordDigest: &journalPreviousDigest,
        fileIO: fileIO)
      for (index, item) in prepared.enumerated() {
        try fileIO.renameItem(at: item.tempURL, to: item.targetURL)
        committed.insert(index)
        try appendJournal(
          JournalRecord(
            schema: journalSchema,
            transactionID: transactionID,
            phase: "rename",
            targetPath: item.targetURL.path,
            tempPath: item.tempURL.path,
            backupPath: item.backupURL?.path,
            existed: item.existed,
            beforeSHA256: item.beforeSHA256,
            expectedSHA256: item.expectedSHA256,
            occurredAt: recordedAt),
          to: journalURL,
          authorizationDigest: digest,
          authorizationTargetPaths: canonicalTargets,
          previousRecordDigest: &journalPreviousDigest,
          fileIO: fileIO)
      }
    } catch {
      do {
        let restored = try rollbackPrepared(
          prepared,
          committed: committed,
          fileIO: fileIO)
        try appendJournal(
          JournalRecord(
            schema: journalSchema,
            transactionID: transactionID,
            phase: "rolledBack",
            targetPath: nil,
            tempPath: nil,
            backupPath: nil,
            existed: nil,
            beforeSHA256: nil,
            expectedSHA256: nil,
            occurredAt: recordedAt),
          to: journalURL,
          authorizationDigest: digest,
          authorizationTargetPaths: canonicalTargets,
          previousRecordDigest: &journalPreviousDigest,
          fileIO: fileIO)
        throw TatwoPluginApplyErrorV1.partialCommitRolledBack(
          restoredTargets: restored,
          detail: error.localizedDescription)
      } catch let applyError as TatwoPluginApplyErrorV1 {
        throw applyError
      } catch {
        throw TatwoPluginApplyErrorV1.rollbackFailed(error.localizedDescription)
      }
    }

    var afterData: [Data] = []
    do {
      for item in prepared {
        let data = try fileIO.readData(from: item.targetURL)
        guard sha256Hex(data).caseInsensitiveCompare(item.expectedSHA256) == .orderedSame,
          let text = String(data: data, encoding: .utf8)
        else {
          throw TatwoPluginApplyErrorV1.readbackMismatch(
            "target hash mismatch at \(item.targetURL.path)")
        }
        try verifyReadback(afterText: text, brand: expectedBrand, items: applyable)
        afterData.append(data)
      }
    } catch {
      do {
        let restored = try rollbackPrepared(
          prepared,
          committed: Set(prepared.indices),
          fileIO: fileIO)
        try appendJournal(
          JournalRecord(
            schema: journalSchema,
            transactionID: transactionID,
            phase: "rolledBack",
            targetPath: nil,
            tempPath: nil,
            backupPath: nil,
            existed: nil,
            beforeSHA256: nil,
            expectedSHA256: nil,
            occurredAt: recordedAt),
          to: journalURL,
          authorizationDigest: digest,
          authorizationTargetPaths: canonicalTargets,
          previousRecordDigest: &journalPreviousDigest,
          fileIO: fileIO)
        throw TatwoPluginApplyErrorV1.readbackMismatch(
          "\(error.localizedDescription); restored targets: \(restored.joined(separator: ", "))")
      } catch let applyError as TatwoPluginApplyErrorV1 {
        throw applyError
      } catch {
        throw TatwoPluginApplyErrorV1.rollbackFailed(error.localizedDescription)
      }
    }

    for item in prepared {
      try? fileIO.removeItem(at: item.tempURL)
    }
    try? appendJournal(
      JournalRecord(
        schema: journalSchema,
        transactionID: transactionID,
        phase: "complete",
        targetPath: nil,
        tempPath: nil,
        backupPath: nil,
        existed: nil,
        beforeSHA256: nil,
        expectedSHA256: nil,
        occurredAt: recordedAt),
      to: journalURL,
      authorizationDigest: digest,
      authorizationTargetPaths: canonicalTargets,
      previousRecordDigest: &journalPreviousDigest,
      fileIO: fileIO)
    let ownership = try ownershipRecords(
      for: applyable,
      brand: expectedBrand,
      registryRevision: plan.registryRevision,
      appliedAt: recordedAt)
    return TatwoPluginApplyReceiptV1(
      status: .applied,
      registryRevision: plan.registryRevision,
      planDigest: digest,
      targetPath: canonicalTargets[0],
      targetPaths: canonicalTargets,
      backupPath: prepared.first?.backupURL?.path,
      backupPaths: prepared.compactMap { $0.backupURL?.path },
      beforeSHA256: prepared.first?.beforeSHA256,
      afterSHA256: afterData.first.map(sha256Hex),
      ownershipRecords: ownership,
      appliedEntryIDs: applyable.map(\.entryID).sorted(),
      skippedEntryIDs: skipped,
      approver: humanGateToken.approver,
      approvedAt: humanGateToken.approvedAt,
      recordedAt: recordedAt,
      notes: [transactionNote])
  }

  public static func defaultJournalPath(for targetPaths: [String]) -> String {
    let first = targetPaths.first.map(canonicalTargetPath) ??
      FileManager.default.temporaryDirectory.path
    return first + ".tatwo-apply.journal.jsonl"
  }

  /// Recover an interrupted prepare/commit transaction. Completed and aborted
  /// journals are idempotent and return a `notNeeded` receipt.
  @discardableResult
  public static func recoverIfNeeded(
    journalPath: String,
    now: Date = Date(),
    fileIO: any TatwoPluginApplyFileIO = TatwoPluginDefaultApplyFileIO()
  ) throws -> TatwoPluginApplyRecoveryReceiptV1 {
    let journalURL = URL(fileURLWithPath: journalPath)
    let recordedAt = iso8601(now)
    guard fileIO.fileExists(at: journalURL) else {
      return TatwoPluginApplyRecoveryReceiptV1(
        status: .notNeeded,
        journalPath: journalPath,
        recordedAt: recordedAt)
    }
    let data: Data
    do {
      data = try fileIO.readData(from: journalURL)
    } catch {
      throw TatwoPluginApplyErrorV1.recoveryFailed(error.localizedDescription)
    }
    var records: [JournalRecord] = []
    do {
      guard let text = String(data: data, encoding: .utf8) else {
        throw TatwoPluginApplyErrorV1.recoveryFailed("invalid journal: not UTF-8")
      }
      let lines = text.split(separator: "\n")
      guard !lines.isEmpty else {
        throw TatwoPluginApplyErrorV1.recoveryFailed("invalid journal: empty")
      }
      for line in lines {
        records.append(try JSONDecoder().decode(JournalRecord.self, from: Data(line.utf8)))
      }
    } catch {
      throw TatwoPluginApplyErrorV1.recoveryFailed("invalid journal: \(error.localizedDescription)")
    }
    do {
      try validateJournalIntegrity(records)
    } catch let error as TatwoPluginApplyErrorV1 {
      throw error
    } catch {
      throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity: \(error.localizedDescription)")
    }
    let terminalPhases: Set<String> = ["complete", "aborted", "rolledBack", "recovered"]
    let recordsByTransaction = Dictionary(grouping: records, by: \.transactionID)
    // A journal path may be reused across sequential transactions.  Select
    // the newest transaction whose own tail is non-terminal instead of
    // trusting the global last line (a later completed transaction must not
    // mask an older interrupted one).
    guard let transactionID = records.reversed().compactMap({ record -> String? in
      guard let transactionRecords = recordsByTransaction[record.transactionID],
        let tail = transactionRecords.last,
        !terminalPhases.contains(tail.phase)
      else { return nil }
      return record.transactionID
    }).first else {
      return TatwoPluginApplyRecoveryReceiptV1(
        status: .notNeeded,
        journalPath: journalPath,
        recordedAt: recordedAt)
    }
    let preparedRecords = records.filter {
      $0.transactionID == transactionID && $0.phase == "prepare" && $0.targetPath != nil
    }
    guard !preparedRecords.isEmpty else {
      return TatwoPluginApplyRecoveryReceiptV1(
        status: .notNeeded,
        journalPath: journalPath,
        recordedAt: recordedAt)
    }
    let renamedPaths = Set(
      records
        .filter {
          $0.transactionID == transactionID && $0.phase == "rename"
        }
        .compactMap(\.targetPath)
        .map(canonicalTargetPath))
    let commitStarted = records.contains {
      $0.transactionID == transactionID && $0.phase == "commitStarted"
    }
    let transactionRecords = records.filter { $0.transactionID == transactionID }
    guard let authorizationRecord = transactionRecords.first else {
      throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity: transaction missing")
    }
    var recoveryPreviousDigest: String? = try journalRecordDigest(transactionRecords.last!)
    var restored: [String] = []
    var cleaned: [String] = []
    do {
      for record in preparedRecords {
        guard let rawTargetPath = record.targetPath,
          let tempPath = record.tempPath,
          let expectedSHA = record.expectedSHA256
        else { continue }
        let targetPath = canonicalTargetPath(rawTargetPath)
        let targetURL = URL(fileURLWithPath: targetPath)
        let tempURL = URL(fileURLWithPath: canonicalTargetPath(tempPath))
        let targetLooksCommitted: Bool
        if fileIO.fileExists(at: targetURL) {
          let current = try fileIO.readData(from: targetURL)
          let hashMatches =
            sha256Hex(current).caseInsensitiveCompare(expectedSHA) == .orderedSame
          let backupDiffersFromExpected: Bool
          if record.existed == true, let backupPath = record.backupPath {
            let backupURL = URL(fileURLWithPath: canonicalTargetPath(backupPath))
            if fileIO.fileExists(at: backupURL) {
              let backupData = try fileIO.readData(from: backupURL)
              backupDiffersFromExpected =
                sha256Hex(backupData).caseInsensitiveCompare(expectedSHA) != .orderedSame
            } else {
              backupDiffersFromExpected = false
            }
          } else {
            backupDiffersFromExpected = false
          }
          // The rename record is authoritative.  The hash/temp fallback only
          // covers a crash in the tiny window after POSIX rename succeeded but
          // before the append-only rename journal record was durable.  For an
          // existing target, a backup whose bytes differ from the expected
          // payload disambiguates a committed rename even if a stale temp is
          // left behind.  A missing target has no such witness and therefore
          // requires the temp to be gone.
          targetLooksCommitted = renamedPaths.contains(targetPath)
            || (commitStarted && hashMatches
              && (backupDiffersFromExpected || !fileIO.fileExists(at: tempURL)))
        } else {
          targetLooksCommitted = renamedPaths.contains(targetPath)
        }
        if targetLooksCommitted {
          if record.existed == true, let backupPath = record.backupPath {
            let backupURL = URL(fileURLWithPath: canonicalTargetPath(backupPath))
            guard fileIO.fileExists(at: backupURL) else {
              throw TatwoPluginApplyErrorV1.recoveryFailed(
                "backup missing for \(targetPath)")
            }
            try restoreBackup(backupURL: backupURL, targetURL: targetURL, fileIO: fileIO)
          } else if fileIO.fileExists(at: targetURL) {
            try fileIO.removeItem(at: targetURL)
          }
          restored.append(targetPath)
        }
        if fileIO.fileExists(at: tempURL) {
          try fileIO.removeItem(at: tempURL)
          cleaned.append(tempURL.path)
        }
      }
      try appendJournal(
        JournalRecord(
          schema: journalSchema,
          transactionID: transactionID,
          phase: "recovered",
          targetPath: nil,
          tempPath: nil,
          backupPath: nil,
          existed: nil,
          beforeSHA256: nil,
          expectedSHA256: nil,
          occurredAt: recordedAt),
        to: journalURL,
        authorizationDigest: authorizationRecord.transactionAuthorizationDigest,
        authorizationTargetPaths: authorizationRecord.authorizationTargetPaths,
        previousRecordDigest: &recoveryPreviousDigest,
        fileIO: fileIO)
      return TatwoPluginApplyRecoveryReceiptV1(
        status: .recovered,
        journalPath: journalPath,
        restoredTargets: restored.sorted(),
        cleanedTempPaths: cleaned.sorted(),
        recordedAt: recordedAt)
    } catch let error as TatwoPluginApplyErrorV1 {
      throw error
    } catch {
      throw TatwoPluginApplyErrorV1.recoveryFailed(error.localizedDescription)
    }
  }

  public static func recoverIfNeeded(
    journalPath: URL,
    now: Date = Date(),
    fileIO: any TatwoPluginApplyFileIO = TatwoPluginDefaultApplyFileIO()
  ) throws -> TatwoPluginApplyRecoveryReceiptV1 {
    try recoverIfNeeded(
      journalPath: journalPath.path,
      now: now,
      fileIO: fileIO)
  }

  private static func validatePlanAndAuthorization(
    plan: TatwoPluginStagedPlanDocumentV1,
    targetPaths: [String],
    humanGateToken: TatwoPluginApplyAuthorizationV1,
    acknowledgeUserConfigTarget: Bool
  ) throws -> String {
    guard !targetPaths.isEmpty else {
      throw TatwoPluginApplyErrorV1.emptyTargetPath
    }
    guard plan.schema == TatwoPluginStagedPlanDocumentV1.schemaName
      || plan.schema == "TatwoPluginStagedPlanV1"
    else {
      throw TatwoPluginApplyErrorV1.invalidPlanSchema(plan.schema)
    }
    let canonical = targetPaths.map { canonicalTargetPath($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard canonical.allSatisfy({ !$0.isEmpty }) else {
      throw TatwoPluginApplyErrorV1.emptyTargetPath
    }
    guard Set(canonical).count == canonical.count else {
      throw TatwoPluginApplyErrorV1.prepareFailed("duplicate target path")
    }
    for path in canonical {
      try assertTargetPathAllowed(path, acknowledgeUserConfigTarget: acknowledgeUserConfigTarget)
    }
    let conflictIDs = plan.items.filter { $0.action == .conflict }.map(\.entryID).sorted()
    if !conflictIDs.isEmpty {
      throw TatwoPluginApplyErrorV1.planContainsConflict(conflictIDs)
    }
    let applyable = plan.items.filter { $0.action == .create || $0.action == .update }
    let expectedBrand: TatwoPluginProjectionBrandV1
    if applyable.isEmpty {
      guard plan.brands.count == 1, let brand = plan.brands.first else {
        throw TatwoPluginApplyErrorV1.mixedBrands(plan.brands.map(\.rawValue).sorted())
      }
      expectedBrand = brand
    } else {
      let brands = Set(applyable.map(\.brand))
      guard brands.count == 1, let brand = brands.first else {
        throw TatwoPluginApplyErrorV1.mixedBrands(brands.map(\.rawValue).sorted())
      }
      expectedBrand = brand
    }
    guard !humanGateToken.approver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TatwoPluginApplyErrorV1.authorizationMissingApprover
    }
    let digest = planDigest(plan)
    guard humanGateToken.approvedPlanDigest.caseInsensitiveCompare(digest) == .orderedSame else {
      throw TatwoPluginApplyErrorV1.authorizationDigestMismatch(
        expected: digest,
        approved: humanGateToken.approvedPlanDigest)
    }
    guard humanGateToken.approvedTargetPaths == canonical else {
      throw TatwoPluginApplyErrorV1.authorizationTargetMismatch(
        expected: canonical.joined(separator: ","),
        approved: humanGateToken.approvedTargetPaths.joined(separator: ","))
    }
    guard humanGateToken.approvedBrand == expectedBrand else {
      throw TatwoPluginApplyErrorV1.authorizationBrandMismatch(
        expected: expectedBrand,
        approved: humanGateToken.approvedBrand)
    }
    return digest
  }

  private static func reserveBackup(
    targetURL: URL,
    now: Date,
    fileIO: any TatwoPluginApplyFileIO
  ) throws -> URL {
    let stamp = backupTimestamp(now)
    for sequence in 0..<backupReservationRetryLimit {
      let suffix = sequence == 0 ? stamp : "\(stamp)-\(sequence)"
      let candidate = URL(fileURLWithPath: targetURL.path + ".tatwo-backup-\(suffix)")
      do {
        try fileIO.copyItemExclusively(at: targetURL, to: candidate)
        return candidate
      } catch {
        if fileIO.fileExists(at: candidate) { continue }
        throw error
      }
    }
    throw TatwoPluginApplyErrorV1.backupReservationFailed(
      "\(targetURL.path).tatwo-backup-\(stamp)")
  }

  private static func reserveTemp(
    targetURL: URL,
    transactionID: String,
    index: Int,
    fileIO: any TatwoPluginApplyFileIO
  ) -> URL {
    var candidate = targetURL.deletingLastPathComponent()
      .appendingPathComponent(".\(targetURL.lastPathComponent).tatwo-apply-\(transactionID)-\(index).tmp")
    while fileIO.fileExists(at: candidate) {
      candidate = targetURL.deletingLastPathComponent()
        .appendingPathComponent(
          ".\(targetURL.lastPathComponent).tatwo-apply-\(transactionID)-\(UUID().uuidString).tmp")
    }
    return candidate
  }

  private static func rollbackPrepared(
    _ prepared: [PreparedTarget],
    committed: Set<Int>,
    fileIO: any TatwoPluginApplyFileIO
  ) throws -> [String] {
    var restored: [String] = []
    for (index, item) in prepared.enumerated() {
      let targetLooksCommitted: Bool
      if fileIO.fileExists(at: item.targetURL) {
        targetLooksCommitted = sha256Hex(try fileIO.readData(from: item.targetURL))
          .caseInsensitiveCompare(item.expectedSHA256) == .orderedSame
      } else {
        targetLooksCommitted = false
      }
      if committed.contains(index) || targetLooksCommitted {
        if item.existed, let backupURL = item.backupURL {
          try restoreBackup(backupURL: backupURL, targetURL: item.targetURL, fileIO: fileIO)
        } else if fileIO.fileExists(at: item.targetURL) {
          try fileIO.removeItem(at: item.targetURL)
        }
        restored.append(item.targetURL.path)
      }
      if fileIO.fileExists(at: item.tempURL) {
        try fileIO.removeItem(at: item.tempURL)
      }
    }
    return restored.sorted()
  }

  private static func journalRecordDigest(_ record: JournalRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return sha256Hex(try encoder.encode(record))
  }

  /// Validate every record and every transaction before recovery is allowed
  /// to touch a target/temp/backup path.  The chain is deliberately checked
  /// over the complete journal, not only the newest non-terminal transaction.
  private static func validateJournalIntegrity(_ records: [JournalRecord]) throws {
    var priorDigestByTransaction: [String: String] = [:]
    var authorizationByTransaction: [String: (digest: String, targets: [String])] = [:]

    for record in records {
      guard record.schema == journalSchema, !record.transactionID.isEmpty else {
        throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
      }
      let digest = record.transactionAuthorizationDigest.lowercased()
      guard !digest.isEmpty else {
        throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
      }
      let targets = record.authorizationTargetPaths.map(canonicalTargetPath)
      guard !targets.isEmpty, targets.allSatisfy({ !$0.isEmpty }),
        Set(targets).count == targets.count
      else {
        throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
      }
      if let prior = authorizationByTransaction[record.transactionID] {
        guard prior.digest.caseInsensitiveCompare(digest) == .orderedSame,
          prior.targets == targets
        else {
          throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
        }
      } else {
        authorizationByTransaction[record.transactionID] = (digest, targets)
      }

      let expectedChain = priorDigestByTransaction[record.transactionID] ?? digest
      guard record.chainDigest.caseInsensitiveCompare(expectedChain) == .orderedSame else {
        throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
      }
      priorDigestByTransaction[record.transactionID] = try journalRecordDigest(record)

      let phaseHasPaths = record.targetPath != nil
        || record.tempPath != nil
        || record.backupPath != nil
      if ["prepare", "rename"].contains(record.phase) {
        guard let targetPath = record.targetPath,
          let tempPath = record.tempPath,
          !targetPath.isEmpty,
          !tempPath.isEmpty,
          let expectedSHA = record.expectedSHA256,
          !expectedSHA.isEmpty
        else {
          throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
        }
        let canonicalTarget = canonicalTargetPath(targetPath)
        guard targets.contains(canonicalTarget) else {
          throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
        }
        let targetURL = URL(fileURLWithPath: canonicalTarget)
        let tempURL = URL(fileURLWithPath: canonicalTargetPath(tempPath))
        let expectedTempPrefix =
          ".\(targetURL.lastPathComponent).tatwo-apply-\(record.transactionID)-"
        guard tempURL.deletingLastPathComponent().path
          == targetURL.deletingLastPathComponent().path,
          tempURL.lastPathComponent.hasPrefix(expectedTempPrefix),
          tempURL.pathExtension == "tmp"
        else {
          throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
        }
        if record.existed == true {
          guard let backupPath = record.backupPath, !backupPath.isEmpty else {
            throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
          }
          let backupURL = URL(fileURLWithPath: canonicalTargetPath(backupPath))
          guard backupURL.deletingLastPathComponent().path
            == targetURL.deletingLastPathComponent().path,
            backupURL.lastPathComponent.hasPrefix(
              "\(targetURL.lastPathComponent).tatwo-backup-")
          else {
            throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
          }
        } else {
          guard record.backupPath == nil else {
            throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
          }
        }
      } else if phaseHasPaths {
        throw TatwoPluginApplyErrorV1.recoveryFailed("journal integrity")
      }
    }
  }

  private static func appendJournal(
    _ record: JournalRecord,
    to journalURL: URL,
    authorizationDigest: String,
    authorizationTargetPaths: [String],
    previousRecordDigest: inout String?,
    fileIO: any TatwoPluginApplyFileIO
  ) throws {
    var bound = record
    bound.chainDigest = previousRecordDigest ?? authorizationDigest.lowercased()
    bound.transactionAuthorizationDigest = authorizationDigest.lowercased()
    bound.authorizationTargetPaths = authorizationTargetPaths.map(canonicalTargetPath)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(bound)
    let line = encoded + Data([0x0a])
    try fileIO.appendData(line, to: journalURL)
    previousRecordDigest = sha256Hex(encoded)
  }

  // MARK: Rollback

  /// Restore target from the backup recorded on an apply receipt.
  /// Missing backup is fail-closed (no guessing alternate paths).
  public static func rollback(
    receipt: TatwoPluginApplyReceiptV1,
    now: Date = Date(),
    fileIO: any TatwoPluginApplyFileIO = TatwoPluginDefaultApplyFileIO()
  ) throws -> TatwoPluginRollbackReceiptV1 {
    let recordedAt = iso8601(now)
    let targetURL = URL(fileURLWithPath: (receipt.targetPath as NSString).expandingTildeInPath)

    guard let backupPath = receipt.backupPath, !backupPath.isEmpty else {
      let err = TatwoPluginApplyErrorV1.backupMissing("(receipt.backupPath is nil)")
      return TatwoPluginRollbackReceiptV1(
        status: .rollbackFailed,
        targetPath: receipt.targetPath,
        backupPath: nil,
        originalApplyPlanDigest: receipt.planDigest,
        originalApplyStatus: receipt.status,
        ownershipRecordsBefore: receipt.ownershipRecords,
        ownershipRecordsAfter: receipt.ownershipRecords.map { markedRolledBack($0) },
        provenanceNote: "rollback failed; ownership remains rolledBack to prevent false unchanged",
        recordedAt: recordedAt,
        error: err.errorDescription)
    }

    let backupURL = URL(fileURLWithPath: backupPath)
    guard fileIO.fileExists(at: backupURL) else {
      let err = TatwoPluginApplyErrorV1.backupMissing(backupPath)
      return TatwoPluginRollbackReceiptV1(
        status: .rollbackFailed,
        targetPath: receipt.targetPath,
        backupPath: backupPath,
        originalApplyPlanDigest: receipt.planDigest,
        originalApplyStatus: receipt.status,
        ownershipRecordsBefore: receipt.ownershipRecords,
        ownershipRecordsAfter: receipt.ownershipRecords.map { markedRolledBack($0) },
        provenanceNote: "rollback failed; ownership remains rolledBack to prevent false unchanged",
        recordedAt: recordedAt,
        error: err.errorDescription)
    }

    do {
      try restoreBackup(backupURL: backupURL, targetURL: targetURL, fileIO: fileIO)
      let restored = try fileIO.readData(from: targetURL)
      return TatwoPluginRollbackReceiptV1(
        status: .rollbackPassed,
        targetPath: targetURL.path,
        backupPath: backupPath,
        restoredSHA256: sha256Hex(restored),
        originalApplyPlanDigest: receipt.planDigest,
        originalApplyStatus: receipt.status,
        ownershipRecordsBefore: receipt.ownershipRecords,
        ownershipRecordsAfter: receipt.ownershipRecords.map { markedRolledBack($0) },
        provenanceNote: "ownership records marked rolledBack; feed ownershipRecordsAfter into next plan",
        recordedAt: recordedAt)
    } catch {
      return TatwoPluginRollbackReceiptV1(
        status: .rollbackFailed,
        targetPath: receipt.targetPath,
        backupPath: backupPath,
        originalApplyPlanDigest: receipt.planDigest,
        originalApplyStatus: receipt.status,
        ownershipRecordsBefore: receipt.ownershipRecords,
        ownershipRecordsAfter: receipt.ownershipRecords.map { markedRolledBack($0) },
        provenanceNote: "rollback failed; ownership remains rolledBack to prevent false unchanged",
        recordedAt: recordedAt,
        error: error.localizedDescription)
    }
  }

  // MARK: Path policy

  /// True when path is under the user's `~/.codex` or `~/.claude` trees (lexical + realpath).
  public static func isUserHomeAgentConfigPath(_ path: String) -> Bool {
    let home = NSHomeDirectory()
    let roots = [
      (home as NSString).appendingPathComponent(".codex"),
      (home as NSString).appendingPathComponent(".claude"),
    ]
    let expanded = canonicalTargetPath(path)
    for root in roots {
      let canonicalRoot = canonicalTargetPath(root)
      if pathIsInsideOrEqual(expanded, root: canonicalRoot) {
        return true
      }
    }
    return false
  }

  public static func assertTargetPathAllowed(
    _ path: String,
    acknowledgeUserConfigTarget: Bool
  ) throws {
    if isUserHomeAgentConfigPath(path), !acknowledgeUserConfigTarget {
      throw TatwoPluginApplyErrorV1.userHomeConfigRequiresAck(path)
    }
  }

  // MARK: Merge + verify

  static func mergeProjectedBodies(
    existingText: String,
    brand: TatwoPluginProjectionBrandV1,
    items: [TatwoPluginStagedPlanItemV1]
  ) throws -> String {
    switch brand {
    case .codex:
      return try mergeCodexTOML(existingText: existingText, items: items)
    case .claude:
      return try mergeClaudeJSON(existingText: existingText, items: items)
    }
  }

  private static func mergeCodexTOML(
    existingText: String,
    items: [TatwoPluginStagedPlanItemV1]
  ) throws -> String {
    // Split existing into: preamble (non mcp_servers tables) + per-server tables.
    var preamble: [String] = []
    var tables: [String: [String]] = [:]
    var order: [String] = []
    var currentID: String?

    for rawLine in existingText.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
        let body = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("mcp_servers.") {
          let rest = String(body.dropFirst("mcp_servers.".count))
          let id: String
          if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
            id = String(rest.dropFirst().dropLast())
          } else {
            id = rest
          }
          currentID = id
          if tables[id] == nil {
            tables[id] = []
            order.append(id)
          }
          tables[id, default: []].append(line)
          continue
        } else {
          currentID = nil
          preamble.append(line)
          continue
        }
      }
      if let id = currentID {
        tables[id, default: []].append(line)
      } else {
        preamble.append(line)
      }
    }

    for item in items {
      guard let body = item.projectedBody else { continue }
      let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      // drop trailing empty from final newline
      var bodyLines = lines
      if body.hasSuffix("\n"), let last = bodyLines.last, last.isEmpty {
        bodyLines.removeLast()
      }
      if tables[item.entryID] == nil {
        order.append(item.entryID)
      }
      tables[item.entryID] = bodyLines
    }

    var out: [String] = []
    // Keep preamble, but strip trailing empties we'll rejoin cleanly.
    while let last = preamble.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      preamble.removeLast()
    }
    out.append(contentsOf: preamble)
    if !out.isEmpty, out.last?.isEmpty == false {
      out.append("")
    }
    for id in order {
      guard let lines = tables[id] else { continue }
      out.append(contentsOf: lines)
      if out.last?.isEmpty == false {
        out.append("")
      }
    }
    var text = out.joined(separator: "\n")
    if !text.hasSuffix("\n") {
      text += "\n"
    }
    return text
  }

  private static func mergeClaudeJSON(
    existingText: String,
    items: [TatwoPluginStagedPlanItemV1]
  ) throws -> String {
    var root: [String: Any]
    if existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      root = ["mcpServers": [String: Any]()]
    } else {
      guard let data = existingText.data(using: .utf8) else {
        throw TatwoPluginApplyErrorV1.writeFailed("existing Claude JSON is not UTF-8")
      }
      let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      guard let dict = object as? [String: Any] else {
        throw TatwoPluginApplyErrorV1.writeFailed("existing Claude JSON root must be object")
      }
      root = dict
    }

    var servers: [String: Any]
    if let raw = root["mcpServers"] as? [String: Any] {
      servers = raw
    } else if root["mcpServers"] == nil {
      servers = [:]
    } else {
      throw TatwoPluginApplyErrorV1.writeFailed("mcpServers must be object")
    }

    for item in items {
      guard let body = item.projectedBody else { continue }
      guard let data = body.data(using: .utf8) else {
        throw TatwoPluginApplyErrorV1.writeFailed("projectedBody not UTF-8 for \(item.entryID)")
      }
      let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      guard let object = parsed as? [String: Any] else {
        throw TatwoPluginApplyErrorV1.writeFailed(
          "projectedBody for \(item.entryID) must be JSON object")
      }
      servers[item.entryID] = object
    }
    root["mcpServers"] = servers

    let data = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    guard var text = String(data: data, encoding: .utf8) else {
      throw TatwoPluginApplyErrorV1.writeFailed("failed to encode Claude JSON")
    }
    if !text.hasSuffix("\n") {
      text += "\n"
    }
    return text
  }

  private static func verifyReadback(
    afterText: String,
    brand: TatwoPluginProjectionBrandV1,
    items: [TatwoPluginStagedPlanItemV1]
  ) throws {
    let observed: [TatwoPluginObservedMcpServerV1]
    switch brand {
    case .codex:
      observed = try TatwoPluginConfigReadback.parseCodexMcpServersTOML(afterText)
    case .claude:
      guard let data = afterText.data(using: .utf8) else {
        throw TatwoPluginApplyErrorV1.readbackMismatch("after-text not UTF-8")
      }
      observed = try TatwoPluginConfigReadback.parseClaudeMcpJSON(data)
    }
    let byID = Dictionary(uniqueKeysWithValues: observed.map { ($0.serverID, $0) })

    for item in items {
      guard let body = item.projectedBody else {
        throw TatwoPluginApplyErrorV1.readbackMismatch("missing projectedBody for \(item.entryID)")
      }
      let expectedManaged = try managedFromProjectedBody(body, entryID: item.entryID, brand: brand)
      let expectedHash = try TatwoPluginProjectionV1.fragmentSHA256(
        managed: expectedManaged, brand: brand)
      guard let server = byID[item.entryID] else {
        throw TatwoPluginApplyErrorV1.readbackMismatch(
          "server \(item.entryID) missing after apply")
      }
      let actualManaged = TatwoPluginManagedMcpFieldsV1.fromObserved(server)
      let actualHash = try TatwoPluginProjectionV1.fragmentSHA256(
        managed: actualManaged, brand: brand)
      if actualHash.caseInsensitiveCompare(expectedHash) != .orderedSame
        || !actualManaged.managedEquals(expectedManaged)
      {
        throw TatwoPluginApplyErrorV1.readbackMismatch(
          "fragment hash mismatch for \(item.entryID): expected \(expectedHash) got \(actualHash)")
      }
    }
  }

  /// Parse a projected fragment body into managed fields (single-server fragment).
  private static func managedFromProjectedBody(
    _ body: String,
    entryID: String,
    brand: TatwoPluginProjectionBrandV1
  ) throws -> TatwoPluginManagedMcpFieldsV1 {
    switch brand {
    case .codex:
      let servers = try TatwoPluginConfigReadback.parseCodexMcpServersTOML(body)
      guard let server = servers.first(where: { $0.serverID == entryID }) ?? servers.first else {
        throw TatwoPluginApplyErrorV1.readbackMismatch(
          "projectedBody for \(entryID) has no mcp_servers table")
      }
      return TatwoPluginManagedMcpFieldsV1.fromObserved(server)
    case .claude:
      // projectedBody is a single server object; wrap for parser.
      let wrapped: [String: Any]
      guard let data = body.data(using: .utf8) else {
        throw TatwoPluginApplyErrorV1.readbackMismatch("projectedBody not UTF-8 for \(entryID)")
      }
      let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      if let object = parsed as? [String: Any], object["mcpServers"] == nil {
        wrapped = ["mcpServers": [entryID: object]]
      } else if let root = parsed as? [String: Any] {
        wrapped = root
      } else {
        throw TatwoPluginApplyErrorV1.readbackMismatch(
          "projectedBody for \(entryID) must be JSON object")
      }
      let wrapData = try JSONSerialization.data(withJSONObject: wrapped)
      let servers = try TatwoPluginConfigReadback.parseClaudeMcpJSON(wrapData)
      guard let server = servers.first(where: { $0.serverID == entryID }) ?? servers.first else {
        throw TatwoPluginApplyErrorV1.readbackMismatch(
          "projectedBody for \(entryID) missing server object")
      }
      return TatwoPluginManagedMcpFieldsV1.fromObserved(server)
    }
  }

  private static func ownershipRecords(
    for items: [TatwoPluginStagedPlanItemV1],
    brand: TatwoPluginProjectionBrandV1,
    registryRevision: String,
    appliedAt: String
  ) throws -> [TatwoPluginOwnershipRecordV1] {
    try items.map { item in
      guard let body = item.projectedBody else {
        throw TatwoPluginApplyErrorV1.missingProjectedBody(item.entryID)
      }
      let managed = try managedFromProjectedBody(body, entryID: item.entryID, brand: brand)
      let hash = try TatwoPluginProjectionV1.fragmentSHA256(managed: managed, brand: brand)
      let logical =
        item.logicalPath
        ?? (brand == .codex
          ? "~/.codex/config.toml#mcp_servers.\(item.entryID)"
          : "~/.claude/.mcp.json#mcpServers.\(item.entryID)")
      return TatwoPluginOwnershipRecordV1(
        serverID: item.entryID,
        brand: brand,
        targetPath: logical,
        appliedFragmentSHA256: hash,
        appliedAtRevision: registryRevision,
        appliedAt: appliedAt)
    }
    .sorted { $0.serverID < $1.serverID }
  }

  private static func restoreBackup(
    backupURL: URL,
    targetURL: URL,
    fileIO: any TatwoPluginApplyFileIO
  ) throws {
    let data = try fileIO.readData(from: backupURL)
    try fileIO.writeAtomically(data, to: targetURL)
  }

  // MARK: Helpers

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  /// Backup suffix uses filesystem-safe ISO-like stamp with nanoseconds:
  /// `20260730T120000Z-123456789`; bounded sequence retries handle equal Dates.
  static func backupTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let seconds = floor(date.timeIntervalSince1970)
    let nanos = Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000.0)
    return "\(formatter.string(from: date))-\(String(format: "%09d", max(0, nanos)))"
  }

  /// Canonicalize an absolute or relative path with real symlink resolution.
  ///
  /// Existing paths (including a leaf symlink to an existing target) go through
  /// `URL.resolvingSymlinksInPath()` so user symlinks collapse to one identity.
  /// Missing leaves climb to the nearest existing ancestor (resolving that
  /// ancestor, which covers a parent directory symlink) and re-append the
  /// missing components. Authorization load and apply both use this helper so
  /// `/var` vs `/private/var` never disagree across the two sides of a compare.
  ///
  /// Note: a prior component-wise `destinationOfSymbolicLink` walk could spin
  /// forever on macOS system links (`/var` → `private/var`) because Foundation
  /// rewrites existing `/private/var/...` paths back to `/var/...`, never
  /// reaching the user leaf symlink.
  public static func canonicalTargetPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let expanded = (trimmed as NSString).expandingTildeInPath
    let absolute: String
    if expanded.hasPrefix("/") {
      absolute = expanded
    } else {
      absolute = (FileManager.default.currentDirectoryPath as NSString)
        .appendingPathComponent(expanded)
    }
    var pending = URL(fileURLWithPath: absolute).standardizedFileURL.path

    // Bound symlink rewrites (malicious cycles).
    for _ in 0..<64 {
      if FileManager.default.fileExists(atPath: pending) {
        // fileExists follows the final symlink; resolvingSymlinksInPath then
        // collapses the full chain (leaf + intermediates) into one form.
        return URL(fileURLWithPath: pending)
          .resolvingSymlinksInPath()
          .standardizedFileURL
          .path
      }

      // Dangling symlink at the exact path: expand once and retry.
      if let destination = try? FileManager.default.destinationOfSymbolicLink(
        atPath: pending)
      {
        let next = joinSymlinkDestination(destination, parentOf: pending)
        if next == pending {
          return next
        }
        pending = next
        continue
      }

      // Missing leaf: climb to nearest existing or symlink ancestor.
      var ancestor = URL(fileURLWithPath: pending)
      var missing: [String] = []
      var rewritten: String?
      while ancestor.path != "/", !ancestor.path.isEmpty {
        if FileManager.default.fileExists(atPath: ancestor.path) {
          break
        }
        if let destination = try? FileManager.default.destinationOfSymbolicLink(
          atPath: ancestor.path)
        {
          var rebuilt = URL(
            fileURLWithPath: joinSymlinkDestination(
              destination, parentOf: ancestor.path))
          for part in missing.reversed() {
            rebuilt.appendPathComponent(part)
          }
          rewritten = rebuilt.standardizedFileURL.path
          break
        }
        let name = ancestor.lastPathComponent
        if name.isEmpty { break }
        missing.append(name)
        let parent = ancestor.deletingLastPathComponent()
        if parent.path == ancestor.path { break }
        ancestor = parent
      }

      if let rewritten {
        if rewritten == pending {
          return rewritten
        }
        pending = rewritten
        continue
      }

      if missing.isEmpty {
        return URL(fileURLWithPath: pending).standardizedFileURL.path
      }

      var base = ancestor
      if FileManager.default.fileExists(atPath: base.path) {
        base = base.resolvingSymlinksInPath()
      }
      for part in missing.reversed() {
        base.appendPathComponent(part)
      }
      return base.standardizedFileURL.path
    }
    return URL(fileURLWithPath: pending).standardizedFileURL.path
  }

  /// Join a readlink destination relative to the symlink's parent directory.
  /// Uses NSString path joining so multi-segment relative targets such as
  /// `private/var` stay intact (unlike a naive single-component append).
  private static func joinSymlinkDestination(
    _ destination: String,
    parentOf symlinkPath: String
  ) -> String {
    let joined: String
    if destination.hasPrefix("/") {
      joined = destination
    } else {
      let parent = (symlinkPath as NSString).deletingLastPathComponent
      joined = (parent as NSString).appendingPathComponent(destination)
    }
    return URL(fileURLWithPath: joined).standardizedFileURL.path
  }

  private static func markedRolledBack(
    _ record: TatwoPluginOwnershipRecordV1
  ) -> TatwoPluginOwnershipRecordV1 {
    TatwoPluginOwnershipRecordV1(
      serverID: record.serverID,
      brand: record.brand,
      targetPath: record.targetPath,
      appliedFragmentSHA256: record.appliedFragmentSHA256,
      appliedAtRevision: record.appliedAtRevision,
      appliedAt: record.appliedAt,
      state: .rolledBack)
  }

  private static func pathIsInsideOrEqual(_ path: String, root: String) -> Bool {
    let p = URL(fileURLWithPath: path).standardizedFileURL.path
    let r = URL(fileURLWithPath: root).standardizedFileURL.path
    if p == r { return true }
    let prefix = r.hasSuffix("/") ? r : r + "/"
    return p.hasPrefix(prefix)
  }
}
