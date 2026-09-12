import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct TatwoGoalStoreLifecycleLockInitializationReceiptV1:
  Codable, Sendable, Equatable
{
  public let schema: String
  public let canonicalGoalStoreRootPath: String
  public let canonicalGoalStoreRootPathSHA256: String
  public let contractID: String
  public let lifecycleDirectoryPath: String
  public let lifecycleDirectoryPathSHA256: String
  public let lifecycleDirectoryOwnerUserID: UInt32
  public let lifecycleDirectoryOwnerGroupID: UInt32
  public let lifecycleDirectoryMode: UInt32
  public let lifecycleDirectoryDeviceID: UInt64
  public let lifecycleDirectoryInode: UInt64
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
  public let globalLockPath: String
  public let globalInitializationReceiptPath: String
  public let globalInitializationReceiptSHA256: String
  public let globalLockOwnerUserID: UInt32
  public let globalLockOwnerGroupID: UInt32
  public let globalLockMode: UInt32
  public let globalLockLinkCount: UInt64
  public let globalLockSize: UInt64
  public let globalLockDeviceID: UInt64
  public let globalLockInode: UInt64
  public let createdAt: Date
}

public enum TatwoGoalStoreLifecycleLockError:
  Error, LocalizedError, Sendable, Equatable
{
  case invalidContractID(String)
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
    case .invalidContractID(let contractID):
      return "Invalid Goal-store lifecycle contract ID: \(contractID)"
    case let .storeRootOpenFailed(path, code):
      return "Could not open Goal-store root \(path): errno \(code)"
    case let .invalidStoreRoot(path, reason):
      return "Invalid Goal-store root \(path): \(reason)"
    case .artifactAlreadyExists(let path):
      return "Goal-store lifecycle artifact already exists: \(path)"
    case .artifactMissing(let path):
      return "Goal-store lifecycle artifact is missing: \(path)"
    case let .artifactOpenFailed(path, code):
      return "Could not open Goal-store lifecycle artifact \(path): errno \(code)"
    case let .artifactCreateFailed(path, code):
      return "Could not create Goal-store lifecycle artifact \(path): errno \(code)"
    case let .invalidArtifact(path, reason):
      return "Invalid Goal-store lifecycle artifact \(path): \(reason)"
    case .artifactIdentityMismatch(let path):
      return "Goal-store lifecycle path/open identity mismatch: \(path)"
    case let .artifactWriteFailed(path, code):
      return "Could not write Goal-store lifecycle artifact \(path): errno \(code)"
    case let .artifactReadFailed(path, code):
      return "Could not read Goal-store lifecycle artifact \(path): errno \(code)"
    case let .artifactSyncFailed(path, code):
      return "Could not durably sync Goal-store lifecycle artifact \(path): errno \(code)"
    case .exactReadbackMismatch(let path):
      return "Goal-store lifecycle artifact exact readback mismatch: \(path)"
    case .invalidInitializationReceipt(let reason):
      return "Invalid Goal-store lifecycle initialization receipt: \(reason)"
    case let .acquireFailed(path, code):
      return "Could not acquire Goal-store lifecycle lock \(path): errno \(code)"
    case let .timedOut(path, waited):
      return "Timed out acquiring Goal-store lifecycle lock \(path) after \(waited) seconds"
    }
  }
}

/// Existing-only lifecycle fencing and a separate create-only initializer.
///
/// Ordinary acquisition never creates a directory, lock, receipt, or repair.
/// Initialization is a distinct global-fenced bootstrap operation and stops
/// after returning its durable receipt.
public enum TatwoGoalStoreLifecycleLock {
  public static let schema =
    "TatwoGoalStoreLifecycleLockInitializationReceiptV1"
  public static let lifecycleDirectoryName = "dispatch-lifecycle"

  private static let requiredDirectoryMode: mode_t = 0o700
  private static let requiredArtifactMode: mode_t = 0o600
  private static let maximumReceiptSize: off_t = 128 * 1024

  public static func lifecycleDirectoryURL(
    forGoalStoreRoot goalStoreRoot: URL
  ) -> URL {
    canonicalRoot(goalStoreRoot)
      .appendingPathComponent(lifecycleDirectoryName, isDirectory: true)
  }

  public static func lockURL(
    forGoalStoreRoot goalStoreRoot: URL,
    contractID: String
  ) throws -> URL {
    let contractID = try validatedContractID(contractID)
    return lifecycleDirectoryURL(forGoalStoreRoot: goalStoreRoot)
      .appendingPathComponent("\(contractID).state.lock", isDirectory: false)
  }

  public static func initializationReceiptURL(
    forGoalStoreRoot goalStoreRoot: URL,
    contractID: String
  ) throws -> URL {
    let contractID = try validatedContractID(contractID)
    return lifecycleDirectoryURL(forGoalStoreRoot: goalStoreRoot)
      .appendingPathComponent(
        "\(contractID).state.lock.initialized.json",
        isDirectory: false)
  }

  public static func initializeCreateOnly(
    goalStoreRoot: URL,
    contractID: String,
    createdAt: Date = Date()
  ) throws -> TatwoGoalStoreLifecycleLockInitializationReceiptV1 {
    try initializeCreateOnly(
      goalStoreRoot: goalStoreRoot,
      contractID: contractID,
      createdAt: createdAt,
      globalHooks: .production,
      lifecycleHooks: .production)
  }

  public static func withExclusiveLock<T>(
    goalStoreRoot: URL,
    contractID: String,
    _ body: () throws -> T
  ) throws -> T {
    try withExclusiveLock(
      goalStoreRoot: goalStoreRoot,
      contractID: contractID,
      expectedUserID: getuid(),
      expectedGroupID: getgid(),
      hooks: .production,
      body)
  }

  static func initializeCreateOnly(
    goalStoreRoot: URL,
    contractID: String,
    createdAt: Date,
    globalHooks: TatwoGoalStoreGlobalLockHooks,
    lifecycleHooks: TatwoGoalStoreLifecycleLockHooks
  ) throws -> TatwoGoalStoreLifecycleLockInitializationReceiptV1 {
    let contractID = try validatedContractID(contractID)
    return try TatwoGoalStoreLockOrder.withOperation(
      mode: .lifecycleBootstrap
    ) {
      try TatwoGoalStoreLockOrder.withGlobalScope {
        try TatwoGoalStoreGlobalLock.withValidatedExclusiveLock(
          goalStoreRoot: goalStoreRoot,
          expectedUserID: getuid(),
          expectedGroupID: getgid(),
          hooks: globalHooks
        ) { globalIdentity in
          try TatwoGoalStoreLockOrder.withLifecycleBootstrapScope {
            try initializeArtifactsCreateOnly(
              goalStoreRoot: goalStoreRoot,
              contractID: contractID,
              createdAt: createdAt,
              globalIdentity: globalIdentity,
              allowExistingLifecycleDirectory: false,
              hooks: lifecycleHooks)
          }
        }
      }
    }
  }

  static func initializeContractCreateOnly(
    goalStoreRoot: URL,
    contractID: String,
    createdAt: Date,
    globalHooks: TatwoGoalStoreGlobalLockHooks = .production,
    lifecycleHooks: TatwoGoalStoreLifecycleLockHooks = .production
  ) throws -> TatwoGoalStoreLifecycleLockInitializationReceiptV1 {
    let contractID = try validatedContractID(contractID)
    return try TatwoGoalStoreLockOrder.withOperation(
      mode: .lifecycleBootstrap
    ) {
      try TatwoGoalStoreLockOrder.withGlobalScope {
        try TatwoGoalStoreGlobalLock.withValidatedExclusiveLock(
          goalStoreRoot: goalStoreRoot,
          expectedUserID: getuid(),
          expectedGroupID: getgid(),
          hooks: globalHooks
        ) { globalIdentity in
          try TatwoGoalStoreLockOrder.withLifecycleBootstrapScope {
            try initializeArtifactsCreateOnly(
              goalStoreRoot: goalStoreRoot,
              contractID: contractID,
              createdAt: createdAt,
              globalIdentity: globalIdentity,
              allowExistingLifecycleDirectory: true,
              hooks: lifecycleHooks)
          }
        }
      }
    }
  }

  static func withExclusiveLock<T>(
    goalStoreRoot: URL,
    contractID: String,
    expectedUserID: uid_t,
    expectedGroupID: gid_t,
    expectedReceiptUserID: uid_t? = nil,
    expectedReceiptGroupID: gid_t? = nil,
    hooks: TatwoGoalStoreLifecycleLockHooks,
    _ body: () throws -> T
  ) throws -> T {
    let contractID = try validatedContractID(contractID)
    return try TatwoGoalStoreLockOrder.withOperationIfNeeded(mode: .standard) {
      try TatwoGoalStoreLockOrder.withLifecycleScope {
        try withValidatedExistingLock(
          goalStoreRoot: goalStoreRoot,
          contractID: contractID,
          expectedUserID: expectedUserID,
          expectedGroupID: expectedGroupID,
          expectedReceiptUserID: expectedReceiptUserID,
          expectedReceiptGroupID: expectedReceiptGroupID,
          hooks: hooks,
          body)
      }
    }
  }

  private static func initializeArtifactsCreateOnly(
    goalStoreRoot: URL,
    contractID: String,
    createdAt: Date,
    globalIdentity: TatwoGoalStoreGlobalLockValidatedIdentity,
    allowExistingLifecycleDirectory: Bool,
    hooks: TatwoGoalStoreLifecycleLockHooks
  ) throws -> TatwoGoalStoreLifecycleLockInitializationReceiptV1 {
    let root = canonicalRoot(goalStoreRoot)
    guard globalIdentity.canonicalGoalStoreRootPath == root.path else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "global_root_binding")
    }
    let directoryURL = lifecycleDirectoryURL(forGoalStoreRoot: root)
    let lockURL = try lockURL(
      forGoalStoreRoot: root, contractID: contractID)
    let receiptURL = try initializationReceiptURL(
      forGoalStoreRoot: root, contractID: contractID)
    let rootFD = try openAndValidateRoot(root)
    defer { _ = close(rootFD) }

    try requireAbsent(lockURL)
    try requireAbsent(receiptURL)

    let directoryFD: Int32
    let directoryStatus: stat
    let existingDirectoryFD = openat(
      rootFD,
      lifecycleDirectoryName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if existingDirectoryFD >= 0 {
      guard allowExistingLifecycleDirectory else {
        _ = close(existingDirectoryFD)
        throw TatwoGoalStoreLifecycleLockError.artifactAlreadyExists(
          path: directoryURL.path)
      }
      directoryFD = existingDirectoryFD
      directoryStatus = try validateDirectory(
        descriptor: directoryFD,
        url: directoryURL,
        expectedUserID: getuid(),
        expectedGroupID: getgid())
    } else {
      let openCode = errno
      guard openCode == ENOENT else {
        throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
          path: directoryURL.path, code: openCode)
      }
      guard mkdirat(rootFD, lifecycleDirectoryName, requiredDirectoryMode) == 0
      else {
        throw TatwoGoalStoreLifecycleLockError.artifactCreateFailed(
          path: directoryURL.path, code: errno)
      }
      guard fsync(rootFD) == 0 else {
        throw TatwoGoalStoreLifecycleLockError.artifactSyncFailed(
          path: root.path, code: errno)
      }

      let createdDirectoryFD = openat(
        rootFD,
        lifecycleDirectoryName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard createdDirectoryFD >= 0 else {
        throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
          path: directoryURL.path, code: errno)
      }
      directoryFD = createdDirectoryFD
      guard fchmod(directoryFD, requiredDirectoryMode) == 0 else {
        throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
          path: directoryURL.path, reason: "chmod_errno_\(errno)")
      }
      directoryStatus = try validateDirectory(
        descriptor: directoryFD,
        url: directoryURL,
        expectedUserID: getuid(),
        expectedGroupID: getgid())
      guard fsync(directoryFD) == 0 else {
        throw TatwoGoalStoreLifecycleLockError.artifactSyncFailed(
          path: directoryURL.path, code: errno)
      }
      try hooks.afterDirectoryDurable()
    }
    defer { _ = close(directoryFD) }

    let lockName = lockURL.lastPathComponent
    let lockFD = openat(
      directoryFD,
      lockName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      requiredArtifactMode)
    guard lockFD >= 0 else {
      throw TatwoGoalStoreLifecycleLockError.artifactCreateFailed(
        path: lockURL.path, code: errno)
    }
    defer { _ = close(lockFD) }
    guard fchmod(lockFD, requiredArtifactMode) == 0 else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: lockURL.path, reason: "chmod_errno_\(errno)")
    }
    let lockStatus = try validateLock(
      descriptor: lockFD,
      url: lockURL,
      expectedUserID: getuid(),
      expectedGroupID: getgid())
    guard fsync(lockFD) == 0, fsync(directoryFD) == 0 else {
      throw TatwoGoalStoreLifecycleLockError.artifactSyncFailed(
        path: lockURL.path, code: errno)
    }
    let reopenedLockFD = openat(
      directoryFD, lockName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard reopenedLockFD >= 0 else {
      throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
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
      throw TatwoGoalStoreLifecycleLockError.exactReadbackMismatch(
        path: lockURL.path)
    }
    try hooks.afterLockDurable()

    let receipt = TatwoGoalStoreLifecycleLockInitializationReceiptV1(
      schema: schema,
      canonicalGoalStoreRootPath: root.path,
      canonicalGoalStoreRootPathSHA256: sha256(root.path),
      contractID: contractID,
      lifecycleDirectoryPath: directoryURL.path,
      lifecycleDirectoryPathSHA256: sha256(directoryURL.path),
      lifecycleDirectoryOwnerUserID: UInt32(directoryStatus.st_uid),
      lifecycleDirectoryOwnerGroupID: UInt32(directoryStatus.st_gid),
      lifecycleDirectoryMode: UInt32(directoryStatus.st_mode & 0o7777),
      lifecycleDirectoryDeviceID: deviceID(directoryStatus),
      lifecycleDirectoryInode: UInt64(directoryStatus.st_ino),
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
      globalLockPath: globalIdentity.lockPath,
      globalInitializationReceiptPath: globalIdentity.receiptPath,
      globalInitializationReceiptSHA256:
        globalIdentity.initializationReceiptSHA256,
      globalLockOwnerUserID: globalIdentity.ownerUserID,
      globalLockOwnerGroupID: globalIdentity.ownerGroupID,
      globalLockMode: globalIdentity.mode,
      globalLockLinkCount: globalIdentity.linkCount,
      globalLockSize: globalIdentity.size,
      globalLockDeviceID: globalIdentity.deviceID,
      globalLockInode: globalIdentity.inode,
      createdAt: Date(
        timeIntervalSince1970: floor(createdAt.timeIntervalSince1970)))
    let receiptBytes = try encode(receipt)

    let receiptName = receiptURL.lastPathComponent
    let receiptFD = openat(
      directoryFD,
      receiptName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      requiredArtifactMode)
    guard receiptFD >= 0 else {
      throw TatwoGoalStoreLifecycleLockError.artifactCreateFailed(
        path: receiptURL.path, code: errno)
    }
    defer { _ = close(receiptFD) }
    guard fchmod(receiptFD, requiredArtifactMode) == 0 else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: receiptURL.path, reason: "chmod_errno_\(errno)")
    }
    try writeAll(
      receiptBytes, descriptor: receiptFD, path: receiptURL.path)
    guard fsync(receiptFD) == 0 else {
      throw TatwoGoalStoreLifecycleLockError.artifactSyncFailed(
        path: receiptURL.path, code: errno)
    }
    let exactReadback = try readAndValidateReceiptArtifact(
      descriptor: receiptFD,
      url: receiptURL,
      expectedUserID: getuid(),
      expectedGroupID: getgid())
    guard exactReadback == receiptBytes else {
      throw TatwoGoalStoreLifecycleLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }
    guard fsync(directoryFD) == 0, fsync(rootFD) == 0 else {
      throw TatwoGoalStoreLifecycleLockError.artifactSyncFailed(
        path: receiptURL.path, code: errno)
    }
    try hooks.afterReceiptDurable()

    let reopenedReceiptFD = openat(
      directoryFD, receiptName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard reopenedReceiptFD >= 0 else {
      throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
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
      throw TatwoGoalStoreLifecycleLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }
    let decoded = try decodeAndValidateReceipt(
      reopenedReceiptBytes,
      root: root,
      contractID: contractID,
      directoryURL: directoryURL,
      directoryStatus: directoryStatus,
      lockURL: lockURL,
      receiptURL: receiptURL,
      lockStatus: lockStatus,
      globalIdentity: globalIdentity)
    guard decoded == receipt else {
      throw TatwoGoalStoreLifecycleLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }
    return decoded
  }

  private static func withValidatedExistingLock<T>(
    goalStoreRoot: URL,
    contractID: String,
    expectedUserID: uid_t,
    expectedGroupID: gid_t,
    expectedReceiptUserID: uid_t?,
    expectedReceiptGroupID: gid_t?,
    hooks: TatwoGoalStoreLifecycleLockHooks,
    _ body: () throws -> T
  ) throws -> T {
    let root = canonicalRoot(goalStoreRoot)
    let directoryURL = lifecycleDirectoryURL(forGoalStoreRoot: root)
    let lockURL = try lockURL(
      forGoalStoreRoot: root, contractID: contractID)
    let receiptURL = try initializationReceiptURL(
      forGoalStoreRoot: root, contractID: contractID)
    let rootFD = try openAndValidateRoot(root)
    defer { _ = close(rootFD) }

    let directoryFD = openat(
      rootFD,
      lifecycleDirectoryName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else {
      let code = errno
      if code == ENOENT {
        throw TatwoGoalStoreLifecycleLockError.artifactMissing(
          path: directoryURL.path)
      }
      throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
        path: directoryURL.path, code: code)
    }
    defer { _ = close(directoryFD) }
    var directoryStatus = try validateDirectory(
      descriptor: directoryFD,
      url: directoryURL,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID)

    let lockFD = openat(
      directoryFD,
      lockURL.lastPathComponent,
      O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard lockFD >= 0 else {
      let code = errno
      if code == ENOENT {
        throw TatwoGoalStoreLifecycleLockError.artifactMissing(
          path: lockURL.path)
      }
      throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
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
      directoryFD,
      receiptURL.lastPathComponent,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard receiptFD >= 0 else {
      let code = errno
      if code == ENOENT {
        throw TatwoGoalStoreLifecycleLockError.artifactMissing(
          path: receiptURL.path)
      }
      throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
        path: receiptURL.path, code: code)
    }
    defer { _ = close(receiptFD) }
    let receiptBytes = try readAndValidateReceiptArtifact(
      descriptor: receiptFD,
      url: receiptURL,
      expectedUserID: expectedReceiptUserID ?? expectedUserID,
      expectedGroupID: expectedReceiptGroupID ?? expectedGroupID)

    let lockStartedAt = ProcessInfo.processInfo.systemUptime
    while hooks.flockOperation(lockFD, LOCK_EX | LOCK_NB) != 0 {
      let code = hooks.errnoProvider()
      if code == EINTR { continue }
      if code == EWOULDBLOCK || code == EAGAIN {
        let waited = ProcessInfo.processInfo.systemUptime - lockStartedAt
        guard waited < 8 else {
          throw TatwoGoalStoreLifecycleLockError.timedOut(
            path: lockURL.path, waited: waited)
        }
        Thread.sleep(forTimeInterval: 0.02)
        continue
      }
      throw TatwoGoalStoreLifecycleLockError.acquireFailed(
        path: lockURL.path, code: code)
    }
    defer { _ = flock(lockFD, LOCK_UN) }
    try hooks.afterFlock()

    try validateRootIdentity(root, descriptor: rootFD)
    directoryStatus = try validateDirectory(
      descriptor: directoryFD,
      url: directoryURL,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID)
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
      throw TatwoGoalStoreLifecycleLockError.exactReadbackMismatch(
        path: receiptURL.path)
    }
    let globalIdentity = try readCurrentGlobalIdentity(
      root: root,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID)
    _ = try decodeAndValidateReceipt(
      lockedReceiptBytes,
      root: root,
      contractID: contractID,
      directoryURL: directoryURL,
      directoryStatus: directoryStatus,
      lockURL: lockURL,
      receiptURL: receiptURL,
      lockStatus: lockStatus,
      globalIdentity: globalIdentity)
    return try body()
  }

  private static func readCurrentGlobalIdentity(
    root: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t
  ) throws -> TatwoGoalStoreGlobalLockValidatedIdentity {
    var captured: TatwoGoalStoreGlobalLockValidatedIdentity?
    try TatwoGoalStoreLockOrder.withGlobalScope {
      try TatwoGoalStoreGlobalLock.withValidatedExclusiveLock(
        goalStoreRoot: root,
        expectedUserID: expectedUserID,
        expectedGroupID: expectedGroupID,
        hooks: .production
      ) { identity in
        captured = identity
      }
    }
    guard let captured else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "missing_global_identity")
    }
    return captured
  }

  private static func canonicalRoot(_ root: URL) -> URL {
    root.standardizedFileURL
  }

  private static func validatedContractID(_ value: String) throws -> String {
    let bytes = value.utf8
    guard !value.isEmpty,
      bytes.count <= 255,
      !value.contains("/"),
      !value.contains("\0"),
      value != ".",
      value != "..",
      URL(fileURLWithPath: value).lastPathComponent == value
    else {
      throw TatwoGoalStoreLifecycleLockError.invalidContractID(value)
    }
    return value
  }

  private static func openAndValidateRoot(_ root: URL) throws -> Int32 {
    let descriptor = open(
      root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw TatwoGoalStoreLifecycleLockError.storeRootOpenFailed(
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
      throw TatwoGoalStoreLifecycleLockError.invalidStoreRoot(
        path: root.path, reason: "fstat_errno_\(errno)")
    }
    guard opened.st_mode & S_IFMT == S_IFDIR else {
      throw TatwoGoalStoreLifecycleLockError.invalidStoreRoot(
        path: root.path, reason: "not_directory")
    }
    var pathStatus = stat()
    guard lstat(root.path, &pathStatus) == 0,
      pathStatus.st_mode & S_IFMT == S_IFDIR,
      sameIdentity(opened, pathStatus)
    else {
      throw TatwoGoalStoreLifecycleLockError.invalidStoreRoot(
        path: root.path, reason: "path_open_identity_mismatch")
    }
  }

  private static func requireAbsent(_ url: URL) throws {
    var status = stat()
    if lstat(url.path, &status) == 0 {
      throw TatwoGoalStoreLifecycleLockError.artifactAlreadyExists(
        path: url.path)
    }
    guard errno == ENOENT else {
      throw TatwoGoalStoreLifecycleLockError.artifactOpenFailed(
        path: url.path, code: errno)
    }
  }

  private static func validateDirectory(
    descriptor: Int32,
    url: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t
  ) throws -> stat {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "fstat_errno_\(errno)")
    }
    guard opened.st_mode & S_IFMT == S_IFDIR else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "not_directory")
    }
    guard opened.st_uid == expectedUserID else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "wrong_owner_\(opened.st_uid)")
    }
    guard opened.st_gid == expectedGroupID else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "wrong_group_\(opened.st_gid)")
    }
    guard opened.st_mode & 0o7777 == requiredDirectoryMode else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path,
        reason: "wrong_mode_\(String(opened.st_mode & 0o7777, radix: 8))")
    }
    try validatePathIdentity(url, openedStatus: opened, expectedType: S_IFDIR)
    return opened
  }

  private static func validateLock(
    descriptor: Int32,
    url: URL,
    expectedUserID: uid_t,
    expectedGroupID: gid_t
  ) throws -> stat {
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "fstat_errno_\(errno)")
    }
    try validateRegularArtifact(
      opened,
      url: url,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID,
      expectedSize: 0)
    try validatePathIdentity(url, openedStatus: opened, expectedType: S_IFREG)
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
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "fstat_errno_\(errno)")
    }
    try validateRegularArtifact(
      opened,
      url: url,
      expectedUserID: expectedUserID,
      expectedGroupID: expectedGroupID,
      expectedSize: nil)
    guard opened.st_size > 0, opened.st_size <= maximumReceiptSize else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "invalid_receipt_size_\(opened.st_size)")
    }
    try validatePathIdentity(url, openedStatus: opened, expectedType: S_IFREG)
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
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "not_regular_file")
    }
    guard status.st_uid == expectedUserID else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "wrong_owner_\(status.st_uid)")
    }
    guard status.st_gid == expectedGroupID else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "wrong_group_\(status.st_gid)")
    }
    guard status.st_mode & 0o7777 == requiredArtifactMode else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path,
        reason: "wrong_mode_\(String(status.st_mode & 0o7777, radix: 8))")
    }
    guard status.st_nlink == 1 else {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "wrong_nlink_\(status.st_nlink)")
    }
    if let expectedSize, status.st_size != expectedSize {
      throw TatwoGoalStoreLifecycleLockError.invalidArtifact(
        path: url.path, reason: "wrong_size_\(status.st_size)")
    }
  }

  private static func validatePathIdentity(
    _ url: URL,
    openedStatus: stat,
    expectedType: mode_t
  ) throws {
    var pathStatus = stat()
    guard lstat(url.path, &pathStatus) == 0,
      pathStatus.st_mode & S_IFMT == expectedType,
      sameIdentity(openedStatus, pathStatus)
    else {
      throw TatwoGoalStoreLifecycleLockError.artifactIdentityMismatch(
        path: url.path)
    }
  }

  private static func decodeAndValidateReceipt(
    _ data: Data,
    root: URL,
    contractID: String,
    directoryURL: URL,
    directoryStatus: stat,
    lockURL: URL,
    receiptURL: URL,
    lockStatus: stat,
    globalIdentity: TatwoGoalStoreGlobalLockValidatedIdentity
  ) throws -> TatwoGoalStoreLifecycleLockInitializationReceiptV1 {
    let requiredKeys: Set<String> = [
      "schema", "canonicalGoalStoreRootPath",
      "canonicalGoalStoreRootPathSHA256", "contractID",
      "lifecycleDirectoryPath", "lifecycleDirectoryPathSHA256",
      "lifecycleDirectoryOwnerUserID", "lifecycleDirectoryOwnerGroupID",
      "lifecycleDirectoryMode", "lifecycleDirectoryDeviceID",
      "lifecycleDirectoryInode", "lockPath", "lockPathSHA256",
      "receiptPath", "receiptPathSHA256", "ownerUserID", "ownerGroupID",
      "mode", "linkCount", "size", "deviceID", "inode",
      "globalLockPath", "globalInitializationReceiptPath",
      "globalInitializationReceiptSHA256", "globalLockOwnerUserID",
      "globalLockOwnerGroupID", "globalLockMode", "globalLockLinkCount",
      "globalLockSize", "globalLockDeviceID", "globalLockInode", "createdAt",
    ]
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "invalid_json")
    }
    guard let dictionary = object as? [String: Any],
      Set(dictionary.keys) == requiredKeys
    else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "closed_world_fields")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let receipt: TatwoGoalStoreLifecycleLockInitializationReceiptV1
    do {
      receipt = try decoder.decode(
        TatwoGoalStoreLifecycleLockInitializationReceiptV1.self,
        from: data)
    } catch {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "decode_failed")
    }
    guard (try? encode(receipt)) == data else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "noncanonical_bytes")
    }
    guard receipt.schema == schema else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "schema")
    }
    guard receipt.canonicalGoalStoreRootPath == root.path,
      receipt.canonicalGoalStoreRootPathSHA256 == sha256(root.path),
      receipt.contractID == contractID,
      receipt.lifecycleDirectoryPath == directoryURL.path,
      receipt.lifecycleDirectoryPathSHA256 == sha256(directoryURL.path),
      receipt.lockPath == lockURL.path,
      receipt.lockPathSHA256 == sha256(lockURL.path),
      receipt.receiptPath == receiptURL.path,
      receipt.receiptPathSHA256 == sha256(receiptURL.path)
    else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "canonical_paths")
    }
    guard
      receipt.lifecycleDirectoryOwnerUserID
        == UInt32(directoryStatus.st_uid),
      receipt.lifecycleDirectoryOwnerGroupID
        == UInt32(directoryStatus.st_gid),
      receipt.lifecycleDirectoryMode
        == UInt32(directoryStatus.st_mode & 0o7777),
      receipt.lifecycleDirectoryDeviceID == deviceID(directoryStatus),
      receipt.lifecycleDirectoryInode == UInt64(directoryStatus.st_ino)
    else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "directory_identity")
    }
    guard receipt.ownerUserID == UInt32(lockStatus.st_uid),
      receipt.ownerGroupID == UInt32(lockStatus.st_gid),
      receipt.mode == UInt32(lockStatus.st_mode & 0o7777),
      receipt.linkCount == UInt64(lockStatus.st_nlink),
      receipt.size == UInt64(lockStatus.st_size),
      receipt.deviceID == deviceID(lockStatus),
      receipt.inode == UInt64(lockStatus.st_ino)
    else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "lock_identity")
    }
    guard receipt.globalLockPath == globalIdentity.lockPath,
      receipt.globalInitializationReceiptPath == globalIdentity.receiptPath,
      receipt.globalInitializationReceiptSHA256
        == globalIdentity.initializationReceiptSHA256,
      receipt.globalLockOwnerUserID == globalIdentity.ownerUserID,
      receipt.globalLockOwnerGroupID == globalIdentity.ownerGroupID,
      receipt.globalLockMode == globalIdentity.mode,
      receipt.globalLockLinkCount == globalIdentity.linkCount,
      receipt.globalLockSize == globalIdentity.size,
      receipt.globalLockDeviceID == globalIdentity.deviceID,
      receipt.globalLockInode == globalIdentity.inode
    else {
      throw TatwoGoalStoreLifecycleLockError.invalidInitializationReceipt(
        reason: "global_lock_binding")
    }
    return receipt
  }

  private static func encode(
    _ receipt: TatwoGoalStoreLifecycleLockInitializationReceiptV1
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(receipt)
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
          throw TatwoGoalStoreLifecycleLockError.artifactWriteFailed(
            path: path, code: errno)
        }
        guard result > 0 else {
          throw TatwoGoalStoreLifecycleLockError.artifactWriteFailed(
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
      throw TatwoGoalStoreLifecycleLockError.artifactReadFailed(
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
          throw TatwoGoalStoreLifecycleLockError.artifactReadFailed(
            path: path, code: errno)
        }
        guard result > 0 else {
          throw TatwoGoalStoreLifecycleLockError.artifactReadFailed(
            path: path, code: EIO)
        }
        readCount += result
      }
    }
    return data
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func deviceID(_ status: stat) -> UInt64 {
    UInt64(bitPattern: Int64(status.st_dev))
  }

  private static func sha256(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "sha256:\(digest)"
  }
}

struct TatwoGoalStoreLifecycleLockHooks: @unchecked Sendable {
  let flockOperation: (Int32, Int32) -> Int32
  let errnoProvider: () -> Int32
  let afterDirectoryDurable: () throws -> Void
  let afterLockOpen: () throws -> Void
  let afterLockDurable: () throws -> Void
  let afterReceiptDurable: () throws -> Void
  let afterFlock: () throws -> Void

  static let production = TatwoGoalStoreLifecycleLockHooks(
    flockOperation: { flock($0, $1) },
    errnoProvider: { errno },
    afterDirectoryDurable: {},
    afterLockOpen: {},
    afterLockDurable: {},
    afterReceiptDurable: {},
    afterFlock: {})
}
