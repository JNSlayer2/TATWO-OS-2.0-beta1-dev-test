import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct TatwoGoalStoreGlobalLockInitializationReceiptV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let canonicalGoalStoreRootPath: String
  public let canonicalGoalStoreRootPathSHA256: String
  public let lockPath: String
  public let lockPathSHA256: String
  public let receiptPath: String
  public let receiptPathSHA256: String
  public let ownerUserID: UInt32
  public let ownerGroupID: UInt32
  public let mode: UInt32
  public let linkCount: UInt64
  public let size: UInt64
  public let deviceID: UInt64
  public let inode: UInt64
  public let createdAt: Date
}

struct TatwoGoalStoreGlobalLockValidatedIdentity: Sendable, Equatable {
  let canonicalGoalStoreRootPath: String
  let lockPath: String
  let receiptPath: String
  let ownerUserID: UInt32
  let ownerGroupID: UInt32
  let mode: UInt32
  let linkCount: UInt64
  let size: UInt64
  let deviceID: UInt64
  let inode: UInt64
  let initializationReceiptSHA256: String
}

public enum TatwoGoalStoreGlobalLockError:
  Error, LocalizedError, Sendable, Equatable
{
  case storeRootOpenFailed(path: String, code: Int32)
  case invalidStoreRoot(path: String, reason: String)
  case artifactAlreadyExists(path: String)
  case artifactMissing(path: String)
  case artifactOpenFailed(path: String, code: Int32)
  case artifactCreateFailed(path: String, code: Int32)
  case invalidArtifact(path: String, reason: String)
  case artifactIdentityMismatch(path: String)
  case artifactWriteFailed(path: String, code: Int32)
  case artifactReadFailed(path: String, code: Int32)
  case artifactSyncFailed(path: String, code: Int32)
  case exactReadbackMismatch(path: String)
  case invalidInitializationReceipt(reason: String)
  case acquireFailed(path: String, code: Int32)
  case timedOut(path: String, waited: TimeInterval)

  public var errorDescription: String? {
    switch self {
    case let .storeRootOpenFailed(path, code):
      return "Could not open Goal-store root \(path): errno \(code)"
    case let .invalidStoreRoot(path, reason):
      return "Invalid Goal-store root \(path): \(reason)"
    case .artifactAlreadyExists(let path):
      return "Goal-store lock initialization artifact already exists: \(path)"
    case .artifactMissing(let path):
      return "Goal-store lock initialization artifact is missing: \(path)"
    case let .artifactOpenFailed(path, code):
      return "Could not open Goal-store lock artifact \(path): errno \(code)"
    case let .artifactCreateFailed(path, code):
      return "Could not create Goal-store lock artifact \(path): errno \(code)"
    case let .invalidArtifact(path, reason):
      return "Invalid Goal-store lock artifact \(path): \(reason)"
    case .artifactIdentityMismatch(let path):
      return "Goal-store lock path/open identity mismatch: \(path)"
    case let .artifactWriteFailed(path, code):
      return "Could not write Goal-store lock artifact \(path): errno \(code)"
    case let .artifactReadFailed(path, code):
      return "Could not read Goal-store lock artifact \(path): errno \(code)"
    case let .artifactSyncFailed(path, code):
      return "Could not durably sync Goal-store lock artifact \(path): errno \(code)"
    case .exactReadbackMismatch(let path):
      return "Goal-store lock artifact exact readback mismatch: \(path)"
    case .invalidInitializationReceipt(let reason):
      return "Invalid Goal-store global-lock initialization receipt: \(reason)"
    case let .acquireFailed(path, code):
      return "Could not acquire Goal-store global lock \(path): errno \(code)"
    case let .timedOut(path, waited):
      return "Timed out acquiring Goal-store global lock \(path) after \(waited) seconds"
    }
  }
}

/// One fixed, store-global `flock(2)` fence for cooperative official Goal writers.
///
/// The lock is advisory only. It serializes writers that all enter this API; it is
/// not a same-UID security boundary and cannot prevent a local process from writing
/// Goal JSON directly. Ordinary acquisition never creates, repairs, truncates, or
/// replaces either initialization artifact.
public enum TatwoGoalStoreGlobalLock {
  public static let schema = "TatwoGoalStoreGlobalLockInitializationReceiptV1"
  public static let lockFileName = ".tatwo-goal-store.global.lock"
  public static let initializationReceiptFileName =
    ".tatwo-goal-store.global-lock.initialized.json"

  private static let requiredMode: mode_t = 0o600
  private static let maximumReceiptSize: off_t = 64 * 1024

  public static func lockURL(forGoalStoreRoot goalStoreRoot: URL) -> URL {
    canonicalRoot(goalStoreRoot)
      .appendingPathComponent(lockFileName, isDirectory: false)
  }

  public static func initializationReceiptURL(
    forGoalStoreRoot goalStoreRoot: URL
  ) -> URL {
    canonicalRoot(goalStoreRoot)
      .appendingPathComponent(initializationReceiptFileName, isDirectory: false)
  }

  /// Independently initializes the fixed lock and its immutable create-only receipt.
  ///
  /// This method only succeeds from a completely absent state. It durably creates
  /// and validates the zero-byte lock, then durably creates and exactly reads back
  /// the receipt, and stops. A failure after either create intentionally leaves the
  /// partial state visible; it is never rolled back or repaired automatically.
  public static func initializeCreateOnly(
    goalStoreRoot: URL,
    createdAt: Date = Date()
  ) throws -> TatwoGoalStoreGlobalLockInitializationReceiptV1 {
    try initializeCreateOnly(
      goalStoreRoot: goalStoreRoot,
      createdAt: createdAt,
      hooks: .production)
  }

  /// Opens the already initialized fixed lock and runs `body` only after every
  /// fail-closed validation and exclusive `flock` acquisition succeeds.
  public static func withExclusiveLock<T>(
    goalStoreRoot: URL,
    _ body: () throws -> T
  ) throws -> T {
    try withExclusiveLock(
      goalStoreRoot: goalStoreRoot,
      expectedUserID: getuid(),
      expectedGroupID: getgid(),
      hooks: .production,
      body)
  }

  static func initializeCreateOnly(
    goalStoreRoot: URL,
    createdAt: Date,
    hooks: TatwoGoalStoreGlobalLockHooks
  ) throws -> TatwoGoalStoreGlobalLockInitializationReceiptV1 {
    let root = canonicalRoot(goalStoreRoot)
    let lockURL = lockURL(forGoalStoreRoot: root)
    let receiptURL = initializationReceiptURL(forGoalStoreRoot: root)
    let rootFD = try openAndValidateRoot(root)
    defer { _ = close(rootFD) }

    try requireAbsent(lockURL)
    try requireAbsent(receiptURL)

    let lockFD = openat(
      rootFD,
      lockFileName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      requiredMode)
    guard lockFD >= 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactCreateFailed(
        path: lockURL.path, code: errno)
    }
    defer { _ = close(lockFD) }

    guard fchmod(lockFD, requiredMode) == 0 else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: lockURL.path, reason: "chmod_errno_\(errno)")
    }
    let lockStatus = try validateLock(
      descriptor: lockFD,
      url: lockURL,
      expectedUserID: getuid(),
      expectedGroupID: getgid())
    guard fsync(lockFD) == 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactSyncFailed(
        path: lockURL.path, code: errno)
    }
    guard fsync(rootFD) == 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactSyncFailed(
        path: root.path, code: errno)
    }
    let reopenedLockFD = openat(
      rootFD, lockFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard reopenedLockFD >= 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactOpenFailed(
        path: lockURL.path, code: errno)
    }
    let reopenedLockStatus: stat
    do {
      reopenedLockStatus = try validateLock(
        descriptor: reopenedLockFD,
        url: lockURL,
        expectedUserID: getuid(),
        expectedGroupID: getgid())
    } catch {
      _ = close(reopenedLockFD)
      throw error
    }
    _ = close(reopenedLockFD)
    guard sameIdentity(lockStatus, reopenedLockStatus) else {
      throw TatwoGoalStoreGlobalLockError.exactReadbackMismatch(
        path: lockURL.path)
    }

    try hooks.afterLockDurable()

    let receipt = TatwoGoalStoreGlobalLockInitializationReceiptV1(
      schema: schema,
      canonicalGoalStoreRootPath: root.path,
      canonicalGoalStoreRootPathSHA256: sha256(root.path),
      lockPath: lockURL.path,
      lockPathSHA256: sha256(lockURL.path),
      receiptPath: receiptURL.path,
      receiptPathSHA256: sha256(receiptURL.path),
      ownerUserID: UInt32(lockStatus.st_uid),
      ownerGroupID: UInt32(lockStatus.st_gid),
      mode: UInt32(lockStatus.st_mode & 0o7777),
      linkCount: UInt64(lockStatus.st_nlink),
      size: UInt64(lockStatus.st_size),
      deviceID: deviceID(lockStatus),
      inode: UInt64(lockStatus.st_ino),
      createdAt: Date(
        timeIntervalSince1970: floor(createdAt.timeIntervalSince1970)))
    let receiptBytes = try encode(receipt)

    let receiptFD = openat(
      rootFD,
      initializationReceiptFileName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      requiredMode)
    guard receiptFD >= 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactCreateFailed(
        path: receiptURL.path, code: errno)
    }
    defer { _ = close(receiptFD) }

    guard fchmod(receiptFD, requiredMode) == 0 else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: receiptURL.path, reason: "chmod_errno_\(errno)")
    }
    try writeAll(receiptBytes, descriptor: receiptFD, path: receiptURL.path)
    guard fsync(receiptFD) == 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactSyncFailed(
        path: receiptURL.path, code: errno)
    }
    let exactReadback = try readAndValidateReceiptArtifact(
      descriptor: receiptFD,
      url: receiptURL,
      expectedUserID: getuid(),
      expectedGroupID: getgid())
    guard exactReadback == receiptBytes else {
      throw TatwoGoalStoreGlobalLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }
    guard fsync(rootFD) == 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactSyncFailed(
        path: root.path, code: errno)
    }
    let reopenedReceiptFD = openat(
      rootFD,
      initializationReceiptFileName,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard reopenedReceiptFD >= 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactOpenFailed(
        path: receiptURL.path, code: errno)
    }
    let reopenedReceiptBytes: Data
    do {
      reopenedReceiptBytes = try readAndValidateReceiptArtifact(
        descriptor: reopenedReceiptFD,
        url: receiptURL,
        expectedUserID: getuid(),
        expectedGroupID: getgid())
    } catch {
      _ = close(reopenedReceiptFD)
      throw error
    }
    _ = close(reopenedReceiptFD)
    guard reopenedReceiptBytes == receiptBytes else {
      throw TatwoGoalStoreGlobalLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }

    let decoded = try decodeAndValidateReceipt(
      reopenedReceiptBytes,
      root: root,
      lockURL: lockURL,
      receiptURL: receiptURL,
      lockStatus: lockStatus)
    guard decoded == receipt else {
      throw TatwoGoalStoreGlobalLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }
    return decoded
  }

  static func withExclusiveLock<T>(
    goalStoreRoot: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t,
    expectedReceiptUserID: uid_t? = nil,
    expectedReceiptGroupID: gid_t? = nil,
    hooks: TatwoGoalStoreGlobalLockHooks,
    _ body: () throws -> T
  ) throws -> T {
    try TatwoGoalStoreLockOrder.withOperationIfNeeded(mode: .globalOnly) {
      try TatwoGoalStoreLockOrder.withGlobalScope {
        try withValidatedExclusiveLock(
          goalStoreRoot: goalStoreRoot,
          expectedUserID: expectedUserID,
          expectedGroupID: expectedGroupID,
          expectedReceiptUserID: expectedReceiptUserID,
          expectedReceiptGroupID: expectedReceiptGroupID,
          hooks: hooks
        ) { _ in
          try body()
        }
      }
    }
  }

  static func withValidatedExclusiveLock<T>(
    goalStoreRoot: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t,
    expectedReceiptUserID: uid_t? = nil,
    expectedReceiptGroupID: gid_t? = nil,
    hooks: TatwoGoalStoreGlobalLockHooks,
    _ body: (TatwoGoalStoreGlobalLockValidatedIdentity) throws -> T
  ) throws -> T {
    let root = canonicalRoot(goalStoreRoot)
    let lockURL = lockURL(forGoalStoreRoot: root)
    let receiptURL = initializationReceiptURL(forGoalStoreRoot: root)
    let rootFD = try openAndValidateRoot(root)
    defer { _ = close(rootFD) }

    let lockFD = openat(
      rootFD, lockFileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard lockFD >= 0 else {
      let code = errno
      if code == ENOENT {
        throw TatwoGoalStoreGlobalLockError.artifactMissing(path: lockURL.path)
      }
      throw TatwoGoalStoreGlobalLockError.artifactOpenFailed(
        path: lockURL.path, code: code)
    }
    defer { _ = close(lockFD) }

    try hooks.afterLockOpen()
    var lockStatus = try validateLock(
      descriptor: lockFD,
      url: lockURL,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID)

    let receiptFD = openat(
      rootFD,
      initializationReceiptFileName,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard receiptFD >= 0 else {
      let code = errno
      if code == ENOENT {
        throw TatwoGoalStoreGlobalLockError.artifactMissing(
          path: receiptURL.path)
      }
      throw TatwoGoalStoreGlobalLockError.artifactOpenFailed(
        path: receiptURL.path, code: code)
    }
    defer { _ = close(receiptFD) }

    let receiptBytes = try readAndValidateReceiptArtifact(
      descriptor: receiptFD,
      url: receiptURL,
      expectedUserID: expectedReceiptUserID ?? expectedUserID,
      expectedGroupID: expectedReceiptGroupID ?? expectedGroupID)
    _ = try decodeAndValidateReceipt(
      receiptBytes,
      root: root,
      lockURL: lockURL,
      receiptURL: receiptURL,
      lockStatus: lockStatus)

    let lockStartedAt = ProcessInfo.processInfo.systemUptime
    while hooks.flockOperation(lockFD, LOCK_EX | LOCK_NB) != 0 {
      let code = hooks.errnoProvider()
      if code == EINTR { continue }
      if code == EWOULDBLOCK || code == EAGAIN {
        let waited = ProcessInfo.processInfo.systemUptime - lockStartedAt
        guard waited < 8 else {
          throw TatwoGoalStoreGlobalLockError.timedOut(
            path: lockURL.path, waited: waited)
        }
        Thread.sleep(forTimeInterval: 0.02)
        continue
      }
      throw TatwoGoalStoreGlobalLockError.acquireFailed(
        path: lockURL.path, code: code)
    }
    defer { _ = flock(lockFD, LOCK_UN) }

    try validateRootIdentity(root, descriptor: rootFD)
    lockStatus = try validateLock(
      descriptor: lockFD,
      url: lockURL,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID)
    let lockedReceiptBytes = try readAndValidateReceiptArtifact(
      descriptor: receiptFD,
      url: receiptURL,
      expectedUserID: expectedReceiptUserID ?? expectedUserID,
      expectedGroupID: expectedReceiptGroupID ?? expectedGroupID)
    guard lockedReceiptBytes == receiptBytes else {
      throw TatwoGoalStoreGlobalLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }
    _ = try decodeAndValidateReceipt(
      lockedReceiptBytes,
      root: root,
      lockURL: lockURL,
      receiptURL: receiptURL,
      lockStatus: lockStatus)

    let identity = TatwoGoalStoreGlobalLockValidatedIdentity(
      canonicalGoalStoreRootPath: root.path,
      lockPath: lockURL.path,
      receiptPath: receiptURL.path,
      ownerUserID: UInt32(lockStatus.st_uid),
      ownerGroupID: UInt32(lockStatus.st_gid),
      mode: UInt32(lockStatus.st_mode & 0o7777),
      linkCount: UInt64(lockStatus.st_nlink),
      size: UInt64(lockStatus.st_size),
      deviceID: deviceID(lockStatus),
      inode: UInt64(lockStatus.st_ino),
      initializationReceiptSHA256: sha256(lockedReceiptBytes))
    return try body(identity)
  }

  private static func canonicalRoot(_ goalStoreRoot: URL) -> URL {
    goalStoreRoot.standardizedFileURL
  }

  private static func openAndValidateRoot(_ root: URL) throws -> Int32 {
    let descriptor = open(
      root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw TatwoGoalStoreGlobalLockError.storeRootOpenFailed(
        path: root.path, code: errno)
    }
    do {
      try validateRootIdentity(root, descriptor: descriptor)
      return descriptor
    } catch {
      _ = close(descriptor)
      throw error
    }
  }

  private static func validateRootIdentity(
    _ root: URL,
    descriptor: Int32
  ) throws {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else {
      throw TatwoGoalStoreGlobalLockError.invalidStoreRoot(
        path: root.path, reason: "fstat_errno_\(errno)")
    }
    guard opened.st_mode & S_IFMT == S_IFDIR else {
      throw TatwoGoalStoreGlobalLockError.invalidStoreRoot(
        path: root.path, reason: "not_directory")
    }
    var pathStatus = stat()
    guard lstat(root.path, &pathStatus) == 0 else {
      throw TatwoGoalStoreGlobalLockError.invalidStoreRoot(
        path: root.path, reason: "lstat_errno_\(errno)")
    }
    guard pathStatus.st_mode & S_IFMT == S_IFDIR else {
      throw TatwoGoalStoreGlobalLockError.invalidStoreRoot(
        path: root.path, reason: "symlink_or_not_directory")
    }
    guard sameIdentity(opened, pathStatus) else {
      throw TatwoGoalStoreGlobalLockError.invalidStoreRoot(
        path: root.path, reason: "path_open_identity_mismatch")
    }
  }

  private static func requireAbsent(_ url: URL) throws {
    var status = stat()
    if lstat(url.path, &status) == 0 {
      throw TatwoGoalStoreGlobalLockError.artifactAlreadyExists(
        path: url.path)
    }
    guard errno == ENOENT else {
      throw TatwoGoalStoreGlobalLockError.artifactOpenFailed(
        path: url.path, code: errno)
    }
  }

  private static func validateLock(
    descriptor: Int32,
    url: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t
  ) throws -> stat {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "fstat_errno_\(errno)")
    }
    try validateRegularArtifact(
      opened,
      url: url,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID,
      expectedSize: 0)
    try validatePathIdentity(url, openedStatus: opened)
    return opened
  }

  private static func readAndValidateReceiptArtifact(
    descriptor: Int32,
    url: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t
  ) throws -> Data {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "fstat_errno_\(errno)")
    }
    try validateRegularArtifact(
      opened,
      url: url,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID,
      expectedSize: nil)
    guard opened.st_size > 0, opened.st_size <= maximumReceiptSize else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "invalid_receipt_size_\(opened.st_size)")
    }
    try validatePathIdentity(url, openedStatus: opened)
    return try readExactly(
      descriptor: descriptor,
      count: Int(opened.st_size),
      path: url.path)
  }

  private static func validateRegularArtifact(
    _ status: stat,
    url: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t,
    expectedSize: off_t?
  ) throws {
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "not_regular_file")
    }
    guard status.st_uid == expectedUserID else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "wrong_owner_\(status.st_uid)")
    }
    guard status.st_gid == expectedGroupID else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "wrong_group_\(status.st_gid)")
    }
    guard status.st_mode & 0o7777 == requiredMode else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path,
        reason: "wrong_mode_\(String(status.st_mode & 0o7777, radix: 8))")
    }
    guard status.st_nlink == 1 else {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "wrong_nlink_\(status.st_nlink)")
    }
    if let expectedSize, status.st_size != expectedSize {
      throw TatwoGoalStoreGlobalLockError.invalidArtifact(
        path: url.path, reason: "wrong_size_\(status.st_size)")
    }
  }

  private static func validatePathIdentity(
    _ url: URL,
    openedStatus: stat
  ) throws {
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactIdentityMismatch(
        path: url.path)
    }
    guard pathStatus.st_mode & S_IFMT == S_IFREG,
      sameIdentity(openedStatus, pathStatus)
    else {
      throw TatwoGoalStoreGlobalLockError.artifactIdentityMismatch(
        path: url.path)
    }
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func deviceID(_ status: stat) -> UInt64 {
    UInt64(bitPattern: Int64(status.st_dev))
  }

  private static func encode(
    _ receipt: TatwoGoalStoreGlobalLockInitializationReceiptV1
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(receipt)
  }

  private static func decodeAndValidateReceipt(
    _ data: Data,
    root: URL,
    lockURL: URL,
    receiptURL: URL,
    lockStatus: stat
  ) throws -> TatwoGoalStoreGlobalLockInitializationReceiptV1 {
    let requiredKeys: Set<String> = [
      "schema",
      "canonicalGoalStoreRootPath",
      "canonicalGoalStoreRootPathSHA256",
      "lockPath",
      "lockPathSHA256",
      "receiptPath",
      "receiptPathSHA256",
      "ownerUserID",
      "ownerGroupID",
      "mode",
      "linkCount",
      "size",
      "deviceID",
      "inode",
      "createdAt",
    ]
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "invalid_json")
    }
    guard let dictionary = object as? [String: Any],
      Set(dictionary.keys) == requiredKeys
    else {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "closed_world_fields")
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receipt: TatwoGoalStoreGlobalLockInitializationReceiptV1
    do {
      receipt = try decoder.decode(
        TatwoGoalStoreGlobalLockInitializationReceiptV1.self,
        from: data)
    } catch {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "decode_failed")
    }
    let canonicalBytes: Data
    do {
      canonicalBytes = try encode(receipt)
    } catch {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "canonical_encode_failed")
    }
    guard canonicalBytes == data else {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "noncanonical_bytes")
    }
    guard receipt.schema == schema else {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "schema")
    }
    guard receipt.canonicalGoalStoreRootPath == root.path,
      receipt.canonicalGoalStoreRootPathSHA256 == sha256(root.path),
      receipt.lockPath == lockURL.path,
      receipt.lockPathSHA256 == sha256(lockURL.path),
      receipt.receiptPath == receiptURL.path,
      receipt.receiptPathSHA256 == sha256(receiptURL.path)
    else {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "canonical_paths")
    }
    guard receipt.ownerUserID == UInt32(lockStatus.st_uid),
      receipt.ownerGroupID == UInt32(lockStatus.st_gid),
      receipt.mode == UInt32(lockStatus.st_mode & 0o7777),
      receipt.linkCount == UInt64(lockStatus.st_nlink),
      receipt.size == UInt64(lockStatus.st_size),
      receipt.deviceID == deviceID(lockStatus),
      receipt.inode == UInt64(lockStatus.st_ino)
    else {
      throw TatwoGoalStoreGlobalLockError.invalidInitializationReceipt(
        reason: "lock_identity")
    }
    return receipt
  }

  private static func writeAll(
    _ data: Data,
    descriptor: Int32,
    path: String
  ) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let result = write(
          descriptor,
          baseAddress.advanced(by: written),
          bytes.count - written)
        if result < 0 {
          if errno == EINTR { continue }
          throw TatwoGoalStoreGlobalLockError.artifactWriteFailed(
            path: path, code: errno)
        }
        guard result > 0 else {
          throw TatwoGoalStoreGlobalLockError.artifactWriteFailed(
            path: path, code: EIO)
        }
        written += result
      }
    }
  }

  private static func readExactly(
    descriptor: Int32,
    count: Int,
    path: String
  ) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
      throw TatwoGoalStoreGlobalLockError.artifactReadFailed(
        path: path, code: errno)
    }
    var data = Data(count: count)
    var readCount = 0
    try data.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      while readCount < count {
        let result = read(
          descriptor,
          baseAddress.advanced(by: readCount),
          count - readCount)
        if result < 0 {
          if errno == EINTR { continue }
          throw TatwoGoalStoreGlobalLockError.artifactReadFailed(
            path: path, code: errno)
        }
        guard result > 0 else {
          throw TatwoGoalStoreGlobalLockError.artifactReadFailed(
            path: path, code: EIO)
        }
        readCount += result
      }
    }
    return data
  }

  private static func sha256(_ value: String) -> String {
    sha256(Data(value.utf8))
  }

  private static func sha256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }
}

struct TatwoGoalStoreGlobalLockHooks: @unchecked Sendable {
  let flockOperation: (Int32, Int32) -> Int32
  let errnoProvider: () -> Int32
  let afterLockOpen: () throws -> Void
  let afterLockDurable: () throws -> Void

  static let production = TatwoGoalStoreGlobalLockHooks(
    flockOperation: { flock($0, $1) },
    errnoProvider: { errno },
    afterLockOpen: {},
    afterLockDurable: {})
}
