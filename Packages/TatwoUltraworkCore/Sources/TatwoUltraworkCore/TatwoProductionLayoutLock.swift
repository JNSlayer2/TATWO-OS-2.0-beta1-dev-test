import CryptoKit
import Foundation
#if canImport(Security)
import Security
import LocalAuthentication
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

/// Production trust/state layout lock failures (fail closed before runner start).
public enum TatwoProductionLayoutError: Error, LocalizedError, Sendable, Equatable {
  case layoutEnvOverrideForbidden(String)
  case channelRootOverrideForbidden(String)
  case installAnchorMismatch(role: String, expected: String, observed: String)
  case installAnchorReadTimeout
  case installAnchorAuthenticationInteractionDenied
  case installAnchorRejected(String)
  case localInternalInstallAnchorRejected(String)
  case globalAntiRollbackRegression(String)
  case targetExecutionAlreadyClaimed(jobID: String)
  case productionInjectionForbidden(String)

  public var errorDescription: String? {
    switch self {
    case let .layoutEnvOverrideForbidden(envKey):
      return "production remote-runner refuses non-canonical layout env: \(envKey)"
    case let .channelRootOverrideForbidden(path):
      return "production remote-runner refuses non-canonical channel root: \(path)"
    case let .installAnchorMismatch(role, expected, observed):
      return
        "production install-anchor mismatch for \(role): expected \(expected), observed \(observed)"
    case .installAnchorReadTimeout:
      return "production install-anchor Keychain read timed out"
    case .installAnchorAuthenticationInteractionDenied:
      return "production install-anchor Keychain authentication interaction is not allowed"
    case let .installAnchorRejected(detail):
      return "production install-anchor rejected: \(detail)"
    case let .localInternalInstallAnchorRejected(detail):
      return "local-internal install-anchor rejected: \(detail)"
    case let .globalAntiRollbackRegression(detail):
      return "production global anti-rollback regression: \(detail)"
    case let .targetExecutionAlreadyClaimed(jobID):
      return "production target execution already claimed for job \(jobID)"
    case let .productionInjectionForbidden(detail):
      return "production remote-runner refuses caller injection: \(detail)"
    }
  }
}

// MARK: - Install anchor (fixed Keychain identity; not path-hashed)

/// Sealed production layout roots. Authority is this record, not process env.
public struct TatwoProductionInstallAnchorV1: Codable, Sendable, Equatable {
  public let schema: String
  public let hostDeviceID: String
  public let applicationSupportRoot: String
  public let stateRoot: String
  public let pinStoreRoot: String
  public let jobChannelRoot: String
  public let sealedAt: String

  public init(
    schema: String = "TatwoProductionInstallAnchorV1",
    hostDeviceID: String,
    applicationSupportRoot: String,
    stateRoot: String,
    pinStoreRoot: String,
    jobChannelRoot: String,
    sealedAt: String
  ) {
    self.schema = schema
    self.hostDeviceID = hostDeviceID
    self.applicationSupportRoot = applicationSupportRoot
    self.stateRoot = stateRoot
    self.pinStoreRoot = pinStoreRoot
    self.jobChannelRoot = jobChannelRoot
    self.sealedAt = sealedAt
  }
}

public protocol TatwoProductionInstallAnchorStore: Sendable {
  func load() throws -> TatwoProductionInstallAnchorV1?
  /// Create-only seal. Existing matching anchor is accepted; mismatch is rejected.
  func save(_ anchor: TatwoProductionInstallAnchorV1) throws
}

/// File-backed install anchor (unit tests). Create-only via O_EXCL.
public struct TatwoProductionInstallAnchorFileStore: TatwoProductionInstallAnchorStore {
  public let url: URL

  public init(url: URL) {
    self.url = url.standardizedFileURL
  }

  public func load() throws -> TatwoProductionInstallAnchorV1? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(
      TatwoProductionInstallAnchorV1.self,
      from: Data(contentsOf: url))
  }

  public func save(_ anchor: TatwoProductionInstallAnchorV1) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(anchor)
    do {
      try TatwoCreateOnlyFile.write(data, to: url, onDuplicate: {
        guard let existing = try load() else {
          throw TatwoProductionLayoutError.installAnchorRejected(
            "create-only race: item missing after EEXIST")
        }
        if existing == anchor { return }
        throw TatwoProductionLayoutError.installAnchorRejected(
          "create-only: existing install anchor differs (refusing overwrite)")
      })
    } catch let error as TatwoProductionLayoutError {
      throw error
    } catch {
      throw TatwoProductionLayoutError.installAnchorRejected(
        "create-only write failed: \(error.localizedDescription)")
    }
  }
}

/// Production Keychain install anchor (single global account; no path hash).
/// Create-only: never SecItemUpdate; duplicate → load-and-compare.
struct TatwoProductionInstallAnchorKeychainReadResult: Sendable, Equatable {
  let status: Int32
  let data: Data?
}

private final class TatwoProductionInstallAnchorKeychainResultBox<Value: Sendable>:
  @unchecked Sendable
{
  private let lock = NSLock()
  private var value: Value?

  func store(_ value: Value) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func load() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

public struct TatwoProductionInstallAnchorKeychainStore: TatwoProductionInstallAnchorStore {
  public static let service = "ai.tatwo.ultrawork.production-layout-install"
  public static let account = "layout-install:global"

  private static let readTimeoutSeconds: TimeInterval = 1
  private let serviceName: String
  private let accountName: String
  #if canImport(Security)
  private let readTimeout: TimeInterval
  private let readOperation:
    @Sendable (String, String) -> TatwoProductionInstallAnchorKeychainReadResult
  #endif

  public init(
    service: String = Self.service,
    account: String = Self.account
  ) {
    self.serviceName = service
    self.accountName = account
    #if canImport(Security)
    self.readTimeout = Self.readTimeoutSeconds
    self.readOperation = Self.readFromKeychain
    #endif
  }

  #if canImport(Security)
  init(
    service: String = Self.service,
    account: String = Self.account,
    readTimeoutSeconds: TimeInterval,
    readOperation:
      @escaping @Sendable (String, String) -> TatwoProductionInstallAnchorKeychainReadResult
  ) {
    self.serviceName = service
    self.accountName = account
    self.readTimeout = readTimeoutSeconds
    self.readOperation = readOperation
  }

  static func readQuery(
    service: String,
    account: String
  ) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
  }

  private static func readFromKeychain(
    service: String,
    account: String
  ) -> TatwoProductionInstallAnchorKeychainReadResult {
    let query = readQuery(service: service, account: account)
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    return TatwoProductionInstallAnchorKeychainReadResult(
      status: Int32(status),
      data: value as? Data)
  }

  private static func performWithTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () -> Value
  ) throws -> Value {
    let completed = DispatchSemaphore(value: 0)
    let result = TatwoProductionInstallAnchorKeychainResultBox<Value>()
    DispatchQueue.global(qos: .userInitiated).async {
      result.store(operation())
      completed.signal()
    }
    guard completed.wait(timeout: .now() + max(seconds, 0.01)) == .success,
      let value = result.load()
    else {
      throw TatwoProductionLayoutError.installAnchorReadTimeout
    }
    return value
  }
  #endif

  public func load() throws -> TatwoProductionInstallAnchorV1? {
    #if canImport(Security)
    let service = serviceName
    let account = accountName
    let operation = readOperation
    let result = try Self.performWithTimeout(seconds: readTimeout) {
      operation(service, account)
    }
    if result.status == errSecItemNotFound { return nil }
    if result.status == errSecInteractionNotAllowed {
      throw TatwoProductionLayoutError.installAnchorAuthenticationInteractionDenied
    }
    guard result.status == errSecSuccess else {
      throw TatwoProductionLayoutError.installAnchorRejected(
        "keychain read status \(result.status)")
    }
    guard let data = result.data else {
      throw TatwoProductionLayoutError.installAnchorRejected(
        "keychain read returned no install-anchor data")
    }
    do {
      return try JSONDecoder().decode(TatwoProductionInstallAnchorV1.self, from: data)
    } catch {
      throw TatwoProductionLayoutError.installAnchorRejected(
        "keychain install-anchor decode failed: \(error.localizedDescription)")
    }
    #else
    throw TatwoProductionLayoutError.installAnchorRejected("keychain unavailable")
    #endif
  }

  public func save(_ anchor: TatwoProductionInstallAnchorV1) throws {
    #if canImport(Security)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(anchor)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    if addStatus == errSecSuccess { return }
    if addStatus == errSecDuplicateItem {
      guard let existing = try load() else {
        throw TatwoProductionLayoutError.installAnchorRejected(
          "create-only race: keychain item missing after duplicate")
      }
      if existing == anchor { return }
      throw TatwoProductionLayoutError.installAnchorRejected(
        "create-only: existing install anchor differs (refusing overwrite)")
    }
    throw TatwoProductionLayoutError.installAnchorRejected(
      "keychain create-only add status \(addStatus)")
    #else
    throw TatwoProductionLayoutError.installAnchorRejected("keychain unavailable")
    #endif
  }
}

// MARK: - Local-internal receipt-bound install anchor

/// Replaceable local-internal install seal. Each replacement advances one
/// generation and binds to the exact prior anchor bytes.
public struct TatwoLocalInternalInstallAnchorV1: Codable, Sendable, Equatable {
  public let schema: String
  public let candidateID: String
  public let receiptID: String
  public let receiptFilename: String
  public let receiptSHA256: String
  public let pointerSHA256: String
  public let canonicalAppPath: String
  public let canonicalStateRoot: String
  public let deviceID: String
  public let installGeneration: UInt64
  public let previousAnchorSHA256: String?
  public let createdAt: String

  public init(
    schema: String = "TatwoLocalInternalInstallAnchorV1",
    candidateID: String,
    receiptID: String,
    receiptFilename: String,
    receiptSHA256: String,
    pointerSHA256: String,
    canonicalAppPath: String,
    canonicalStateRoot: String,
    deviceID: String,
    installGeneration: UInt64,
    previousAnchorSHA256: String?,
    createdAt: String
  ) {
    self.schema = schema
    self.candidateID = candidateID
    self.receiptID = receiptID
    self.receiptFilename = receiptFilename
    self.receiptSHA256 = receiptSHA256
    self.pointerSHA256 = pointerSHA256
    self.canonicalAppPath = canonicalAppPath
    self.canonicalStateRoot = canonicalStateRoot
    self.deviceID = deviceID
    self.installGeneration = installGeneration
    self.previousAnchorSHA256 = previousAnchorSHA256
    self.createdAt = createdAt
  }
}

/// Fixed local-internal anchor file under
/// `<Application Support>/local-app-install/local-internal-install-anchor.json`.
///
/// Unlike the formal-production Keychain seal, this file is replaceable. The
/// generation and previous-byte digest form a fail-closed update chain.
public struct TatwoLocalInternalInstallAnchorFileStore: Sendable {
  public static let fileName = "local-internal-install-anchor.json"
  private static let maximumBytes = 64 * 1024

  public let installerRootURL: URL
  public let url: URL

  public init(installerRootURL: URL) {
    let root = installerRootURL.standardizedFileURL
    self.installerRootURL = root
    self.url = root.appendingPathComponent(
      Self.fileName,
      isDirectory: false)
  }

  public func load() throws -> TatwoLocalInternalInstallAnchorV1? {
    guard FileManager.default.fileExists(atPath: installerRootURL.path) else {
      return nil
    }
    try requireSafeInstallerRoot()
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try readAnchorData()
    let anchor: TatwoLocalInternalInstallAnchorV1
    do {
      anchor = try JSONDecoder().decode(
        TatwoLocalInternalInstallAnchorV1.self,
        from: data)
    } catch {
      throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
        "decode failed: \(error.localizedDescription)")
    }
    try Self.validate(anchor)
    return anchor
  }

  /// Atomic replacement with exact generation/previous-byte-digest binding.
  public func save(_ anchor: TatwoLocalInternalInstallAnchorV1) throws {
    try requireSafeInstallerRoot()
    try Self.validate(anchor)

    let priorData: Data?
    let priorAnchor: TatwoLocalInternalInstallAnchorV1?
    if FileManager.default.fileExists(atPath: url.path) {
      let data = try readAnchorData()
      let decoded: TatwoLocalInternalInstallAnchorV1
      do {
        decoded = try JSONDecoder().decode(
          TatwoLocalInternalInstallAnchorV1.self,
          from: data)
      } catch {
        throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
          "existing anchor decode failed")
      }
      try Self.validate(decoded)
      if decoded == anchor {
        return
      }
      priorData = data
      priorAnchor = decoded
    } else {
      priorData = nil
      priorAnchor = nil
    }

    if let priorData, let priorAnchor {
      guard anchor.installGeneration == priorAnchor.installGeneration + 1,
        anchor.previousAnchorSHA256 == Self.sha256Hex(priorData)
      else {
        throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
          "replacement generation or previous anchor digest mismatch")
      }
    } else {
      guard anchor.installGeneration == 1,
        anchor.previousAnchorSHA256 == nil
      else {
        throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
          "first anchor must use generation 1 without a previous digest")
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(anchor)
    try TatwoAtomicFile.write(data, to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
    guard try load() == anchor else {
      throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
        "atomic replacement read-back mismatch")
    }
  }

  static func validate(
    _ anchor: TatwoLocalInternalInstallAnchorV1
  ) throws {
    guard anchor.schema == "TatwoLocalInternalInstallAnchorV1",
      isLowercaseHex(anchor.candidateID),
      isLowercaseHex(anchor.receiptID),
      anchor.receiptFilename
        == "local-app-install-\(anchor.receiptID).txt",
      isLowercaseHex(anchor.receiptSHA256),
      isLowercaseHex(anchor.pointerSHA256),
      canonicalAbsolutePath(anchor.canonicalAppPath),
      canonicalAbsolutePath(anchor.canonicalStateRoot),
      safeDeviceID(anchor.deviceID),
      anchor.installGeneration > 0,
      ISO8601DateFormatter().date(from: anchor.createdAt) != nil
    else {
      throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
        "invalid schema, binding field, path, device, generation, or timestamp")
    }
    if anchor.installGeneration == 1 {
      guard anchor.previousAnchorSHA256 == nil else {
        throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
          "generation 1 must not name a previous anchor")
      }
    } else {
      guard let digest = anchor.previousAnchorSHA256,
        isLowercaseHex(digest)
      else {
        throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
          "replacement anchor requires a previous anchor digest")
      }
    }
  }

  private func requireSafeInstallerRoot() throws {
    var rootStatus = stat()
    guard lstat(installerRootURL.path, &rootStatus) == 0,
      rootStatus.st_mode & S_IFMT == S_IFDIR,
      installerRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        == installerRootURL.path,
      url.deletingLastPathComponent().standardizedFileURL.path
        == installerRootURL.path,
      url.lastPathComponent == Self.fileName
    else {
      throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
        "anchor path escapes a plain non-symlink installer root")
    }
  }

  private func readAnchorData() throws -> Data {
    let descriptor = open(
      url.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
        "anchor is missing, inaccessible, or a symlink")
    }
    defer { _ = close(descriptor) }

    var fileStatus = stat()
    guard fstat(descriptor, &fileStatus) == 0,
      fileStatus.st_mode & S_IFMT == S_IFREG,
      fileStatus.st_mode & 0o777 == 0o600,
      fileStatus.st_uid == geteuid(),
      fileStatus.st_size > 0,
      fileStatus.st_size <= off_t(Self.maximumBytes)
    else {
      throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
        "anchor must be a user-owned regular 0600 file within the size limit")
    }

    var data = Data(count: Int(fileStatus.st_size))
    try data.withUnsafeMutableBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else {
        throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
          "anchor data buffer unavailable")
      }
      var offset = 0
      while offset < rawBuffer.count {
        let count = read(
          descriptor,
          base.advanced(by: offset),
          rawBuffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw TatwoProductionLayoutError.localInternalInstallAnchorRejected(
            "anchor read was truncated")
        }
        offset += count
      }
    }
    return data
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func isLowercaseHex(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      }
  }

  private static func canonicalAbsolutePath(_ value: String) -> Bool {
    guard value.hasPrefix("/") else { return false }
    return URL(fileURLWithPath: value).standardizedFileURL.path == value
  }

  private static func safeDeviceID(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 256
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0)
          || CharacterSet(charactersIn: "._:-").contains($0)
      }
  }
}

// MARK: - Global anti-rollback (independent create-only records)

/// Result of a create-only claim / high-water record insert.
public enum TatwoLoopCreateOnlyResult: Sendable, Equatable {
  /// This attempt created the durable record (won the fence).
  case created
  /// Record already existed with identical binding (idempotent replay).
  case alreadyPresentMatching
}

public struct TatwoLoopGlobalConsumedJobHighWaterV1: Codable, Sendable, Equatable {
  public let jobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  public let resultDigest: String
  public let projectionSequence: UInt64
  /// Store-generation high-water observed when this record was sealed (retention stamp).
  public let boundGeneration: UInt64

  public init(
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    resultDigest: String,
    projectionSequence: UInt64,
    boundGeneration: UInt64 = 0
  ) {
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.resultDigest = resultDigest
    self.projectionSequence = projectionSequence
    self.boundGeneration = boundGeneration
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    jobID = try c.decode(String.self, forKey: .jobID)
    dispatchNonce = try c.decode(String.self, forKey: .dispatchNonce)
    jobCanonicalDigest = try c.decode(String.self, forKey: .jobCanonicalDigest)
    resultDigest = try c.decode(String.self, forKey: .resultDigest)
    projectionSequence = try c.decode(UInt64.self, forKey: .projectionSequence)
    boundGeneration = try c.decodeIfPresent(UInt64.self, forKey: .boundGeneration) ?? 0
  }

  private enum CodingKeys: String, CodingKey {
    case jobID, dispatchNonce, jobCanonicalDigest, resultDigest, projectionSequence,
      boundGeneration
  }
}

/// Target-side execution claim (jobID + attempt binding). Claim-before-execute fence.
public struct TatwoLoopGlobalExecutedClaimV1: Codable, Sendable, Equatable {
  public let jobID: String
  public let dispatchNonce: String
  public let jobCanonicalDigest: String
  /// Store-generation high-water observed when this claim was sealed (retention stamp).
  public let boundGeneration: UInt64

  public init(
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    boundGeneration: UInt64 = 0
  ) {
    self.jobID = jobID
    self.dispatchNonce = dispatchNonce
    self.jobCanonicalDigest = jobCanonicalDigest
    self.boundGeneration = boundGeneration
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    jobID = try c.decode(String.self, forKey: .jobID)
    dispatchNonce = try c.decode(String.self, forKey: .dispatchNonce)
    jobCanonicalDigest = try c.decode(String.self, forKey: .jobCanonicalDigest)
    boundGeneration = try c.decodeIfPresent(UInt64.self, forKey: .boundGeneration) ?? 0
  }

  private enum CodingKeys: String, CodingKey {
    case jobID, dispatchNonce, jobCanonicalDigest, boundGeneration
  }

  /// Binding equality ignores retention stamp.
  public func bindingMatches(dispatchNonce: String, jobCanonicalDigest: String) -> Bool {
    self.dispatchNonce == dispatchNonce && self.jobCanonicalDigest == jobCanonicalDigest
  }
}

/// Read-only assembly of independent durable records (not a mutable overwrite blob).
public struct TatwoLoopGlobalAntiRollbackStateV1: Codable, Sendable, Equatable {
  public var schema: String
  public var storeGenerationHighWater: UInt64
  public var consumedJobs: [String: TatwoLoopGlobalConsumedJobHighWaterV1]
  public var executedClaims: [String: TatwoLoopGlobalExecutedClaimV1]

  public init(
    schema: String = "TatwoLoopGlobalAntiRollbackStateV1",
    storeGenerationHighWater: UInt64 = 0,
    consumedJobs: [String: TatwoLoopGlobalConsumedJobHighWaterV1] = [:],
    executedClaims: [String: TatwoLoopGlobalExecutedClaimV1] = [:]
  ) {
    self.schema = schema
    self.storeGenerationHighWater = storeGenerationHighWater
    self.consumedJobs = consumedJobs
    self.executedClaims = executedClaims
  }

  public static let empty = TatwoLoopGlobalAntiRollbackStateV1()
}

/// Global anti-rollback store: **independent create-only records**, not whole-JSON RMW.
///
/// Security truth is create-only (`SecItemAdd` / `O_CREAT|O_EXCL`). Cooperative `mutationLockURL`
/// flock is optional serialization only and must never be required for claim correctness.
public protocol TatwoLoopGlobalAntiRollbackAnchor: Sendable {
  /// Cooperative flock path only (not security authority).
  var mutationLockURL: URL { get }

  func loadStoreGenerationHighWater() throws -> UInt64
  /// Create-only marker for `generation`. Returns resulting high-water (max of known markers).
  @discardableResult
  func ensureStoreGeneration(_ generation: UInt64) throws -> UInt64

  func loadExecutedClaim(jobID: String) throws -> TatwoLoopGlobalExecutedClaimV1?
  /// Create-only claim. Matching prior → `.alreadyPresentMatching`; binding mismatch throws.
  @discardableResult
  func createExecutedClaim(_ claim: TatwoLoopGlobalExecutedClaimV1) throws
    -> TatwoLoopCreateOnlyResult

  func loadConsumedJob(jobID: String) throws -> TatwoLoopGlobalConsumedJobHighWaterV1?
  /// Create-only consume high-water. Matching prior → `.alreadyPresentMatching`; else throw.
  @discardableResult
  func createConsumedJob(_ record: TatwoLoopGlobalConsumedJobHighWaterV1) throws
    -> TatwoLoopCreateOnlyResult

  /// Read-only snapshot assembled from independent records.
  func loadSnapshot() throws -> TatwoLoopGlobalAntiRollbackStateV1

  /// Pilot: must **not** auto-delete claim/consumed anti-replay records.
  ///
  /// Pre-scale MUSTFIX: durable replay-floor bounded retention (job generation/epoch in
  /// signed canonical digest; claim rejects below floor; floor advance covers in-flight).
  /// Until that ships, accept bounded growth; generation markers may advance independently.
  func pruneRecordsBelowGeneration(_ floor: UInt64) throws
}

// MARK: File store (test) — O_CREAT|O_EXCL per record

/// Directory-backed independent records. Layout:
/// `root/store-gen/<N>`, `root/claims/<job>.json`, `root/consumed/<job>.json`.
public struct TatwoLoopGlobalAntiRollbackFileAnchor: TatwoLoopGlobalAntiRollbackAnchor {
  public let rootURL: URL

  /// - Parameter rootURL: Directory root for independent create-only records.
  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  /// Convenience: treat `url` as the directory root (not a single JSON blob).
  public init(url: URL) {
    self.rootURL = url.standardizedFileURL
  }

  public var mutationLockURL: URL {
    rootURL.appendingPathComponent("cooperative.lock")
  }

  public func loadStoreGenerationHighWater() throws -> UInt64 {
    try ensureRoot()
    let dir = storeGenDir()
    guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    var maxGen: UInt64 = 0
    for name in names {
      if let value = UInt64(name), value > maxGen { maxGen = value }
    }
    return maxGen
  }

  @discardableResult
  public func ensureStoreGeneration(_ generation: UInt64) throws -> UInt64 {
    try ensureRoot()
    let url = storeGenDir().appendingPathComponent(String(generation))
    let payload = Data("\(generation)\n".utf8)
    try TatwoCreateOnlyFile.write(payload, to: url, onDuplicate: { /* marker exists */ })
    return try loadStoreGenerationHighWater()
  }

  public func loadExecutedClaim(jobID: String) throws -> TatwoLoopGlobalExecutedClaimV1? {
    try loadJSON(TatwoLoopGlobalExecutedClaimV1.self, from: claimURL(jobID: jobID))
  }

  @discardableResult
  public func createExecutedClaim(_ claim: TatwoLoopGlobalExecutedClaimV1) throws
    -> TatwoLoopCreateOnlyResult
  {
    try createOnlyJSON(
      claim,
      to: claimURL(jobID: claim.jobID),
      matching: { (prior: TatwoLoopGlobalExecutedClaimV1) in
        prior.jobID == claim.jobID
          && prior.bindingMatches(
            dispatchNonce: claim.dispatchNonce,
            jobCanonicalDigest: claim.jobCanonicalDigest)
      },
      mismatch: {
        TatwoProductionLayoutError.globalAntiRollbackRegression(
          "job \(claim.jobID) target execution claim binding mismatch")
      })
  }

  public func loadConsumedJob(jobID: String) throws -> TatwoLoopGlobalConsumedJobHighWaterV1? {
    try loadJSON(TatwoLoopGlobalConsumedJobHighWaterV1.self, from: consumedURL(jobID: jobID))
  }

  @discardableResult
  public func createConsumedJob(_ record: TatwoLoopGlobalConsumedJobHighWaterV1) throws
    -> TatwoLoopCreateOnlyResult
  {
    try createOnlyJSON(
      record,
      to: consumedURL(jobID: record.jobID),
      matching: { (prior: TatwoLoopGlobalConsumedJobHighWaterV1) in
        prior.jobID == record.jobID
          && prior.dispatchNonce == record.dispatchNonce
          && prior.jobCanonicalDigest == record.jobCanonicalDigest
          && prior.resultDigest == record.resultDigest
          && prior.projectionSequence == record.projectionSequence
      },
      mismatch: {
        TatwoProductionLayoutError.globalAntiRollbackRegression(
          "job \(record.jobID) consume high-water binding mismatch")
      })
  }

  public func loadSnapshot() throws -> TatwoLoopGlobalAntiRollbackStateV1 {
    try ensureRoot()
    var claims: [String: TatwoLoopGlobalExecutedClaimV1] = [:]
    var consumed: [String: TatwoLoopGlobalConsumedJobHighWaterV1] = [:]
    let claimsDir = claimsDirURL()
    if FileManager.default.fileExists(atPath: claimsDir.path) {
      for name in try FileManager.default.contentsOfDirectory(atPath: claimsDir.path)
      where name.hasSuffix(".json") {
        let url = claimsDir.appendingPathComponent(name)
        if let claim = try loadJSON(TatwoLoopGlobalExecutedClaimV1.self, from: url) {
          claims[claim.jobID] = claim
        }
      }
    }
    let consumedDir = consumedDirURL()
    if FileManager.default.fileExists(atPath: consumedDir.path) {
      for name in try FileManager.default.contentsOfDirectory(atPath: consumedDir.path)
      where name.hasSuffix(".json") {
        let url = consumedDir.appendingPathComponent(name)
        if let row = try loadJSON(TatwoLoopGlobalConsumedJobHighWaterV1.self, from: url) {
          consumed[row.jobID] = row
        }
      }
    }
    return TatwoLoopGlobalAntiRollbackStateV1(
      storeGenerationHighWater: try loadStoreGenerationHighWater(),
      consumedJobs: consumed,
      executedClaims: claims)
  }

  public func pruneRecordsBelowGeneration(_ floor: UInt64) throws {
    // PILOT: never auto-delete claim/consumed records (anti-replay truth).
    // Generation markers may be compacted; high-water remains max(existing markers).
    // MUSTFIX before sustained-use scale: durable replay-floor retention (epoch in signed
    // digest; claim rejects below floor; floor advance must cover in-flight jobs).
    _ = floor
    try ensureRoot()
    // Intentionally no claim/consumed deletion. Do not re-enable lag-N prune without floor.
  }

  // MARK: paths

  private func ensureRoot() throws {
    try FileManager.default.createDirectory(
      at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  private func storeGenDir() -> URL {
    rootURL.appendingPathComponent("store-gen", isDirectory: true)
  }

  private func claimsDirURL() -> URL {
    rootURL.appendingPathComponent("claims", isDirectory: true)
  }

  private func consumedDirURL() -> URL {
    rootURL.appendingPathComponent("consumed", isDirectory: true)
  }

  private func claimURL(jobID: String) -> URL {
    claimsDirURL().appendingPathComponent("\(Self.safeFileComponent(jobID)).json")
  }

  private func consumedURL(jobID: String) -> URL {
    consumedDirURL().appendingPathComponent("\(Self.safeFileComponent(jobID)).json")
  }

  private static func safeFileComponent(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: ":", with: "_")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\\", with: "_")
  }

  private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }

  private func createOnlyJSON<T: Codable>(
    _ value: T,
    to url: URL,
    matching: (T) -> Bool,
    mismatch: () -> TatwoProductionLayoutError
  ) throws -> TatwoLoopCreateOnlyResult {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    var result: TatwoLoopCreateOnlyResult = .created
    try TatwoCreateOnlyFile.write(data, to: url, onDuplicate: {
      guard let prior = try loadJSON(T.self, from: url) else {
        throw TatwoProductionLayoutError.globalAntiRollbackRegression(
          "create-only race: item missing after EEXIST at \(url.lastPathComponent)")
      }
      if matching(prior) {
        result = .alreadyPresentMatching
        return
      }
      throw mismatch()
    })
    return result
  }
}

// MARK: Keychain store (production) — SecItemAdd create-only per record

public struct TatwoLoopGlobalAntiRollbackKeychainAnchor: TatwoLoopGlobalAntiRollbackAnchor {
  public static let service = "ai.tatwo.ultrawork.loop-global-anti-rollback"

  private let serviceName: String
  private let hostScope: String
  private let lockRootBase: URL?

  public init(
    hostDeviceID: String,
    service: String = Self.service,
    applicationSupportBase: URL? = nil
  ) {
    self.serviceName = service
    self.hostScope = hostDeviceID.replacingOccurrences(of: ":", with: "_")
    self.lockRootBase = applicationSupportBase
  }

  public init(
    service: String,
    hostScope: String,
    applicationSupportBase: URL? = nil
  ) {
    self.serviceName = service
    self.hostScope = hostScope.replacingOccurrences(of: ":", with: "_")
    self.lockRootBase = applicationSupportBase
  }

  /// Cooperative lock path only (not claim authority).
  public var mutationLockURL: URL {
    TatwoProductionLayoutLock.globalAntiRollbackLockURL(
      accountName: "scope-\(hostScope)",
      applicationSupportBase: lockRootBase)
  }

  public func loadStoreGenerationHighWater() throws -> UInt64 {
    let markers = try listAccounts(prefix: storeGenAccountPrefix())
    var maxGen: UInt64 = 0
    for account in markers {
      if let gen = parseStoreGenAccount(account), gen > maxGen { maxGen = gen }
    }
    return maxGen
  }

  @discardableResult
  public func ensureStoreGeneration(_ generation: UInt64) throws -> UInt64 {
    let account = storeGenAccount(generation)
    let payload = Data("\(generation)".utf8)
    try keychainCreateOnly(account: account, data: payload, onDuplicate: { /* ok */ })
    return try loadStoreGenerationHighWater()
  }

  public func loadExecutedClaim(jobID: String) throws -> TatwoLoopGlobalExecutedClaimV1? {
    try keychainLoad(account: execClaimAccount(jobID: jobID))
  }

  @discardableResult
  public func createExecutedClaim(_ claim: TatwoLoopGlobalExecutedClaimV1) throws
    -> TatwoLoopCreateOnlyResult
  {
    try keychainCreateOnlyJSON(
      claim,
      account: execClaimAccount(jobID: claim.jobID),
      matching: { (prior: TatwoLoopGlobalExecutedClaimV1) in
        prior.jobID == claim.jobID
          && prior.bindingMatches(
            dispatchNonce: claim.dispatchNonce,
            jobCanonicalDigest: claim.jobCanonicalDigest)
      },
      mismatch: {
        TatwoProductionLayoutError.globalAntiRollbackRegression(
          "job \(claim.jobID) target execution claim binding mismatch")
      })
  }

  public func loadConsumedJob(jobID: String) throws -> TatwoLoopGlobalConsumedJobHighWaterV1? {
    try keychainLoad(account: consumedAccount(jobID: jobID))
  }

  @discardableResult
  public func createConsumedJob(_ record: TatwoLoopGlobalConsumedJobHighWaterV1) throws
    -> TatwoLoopCreateOnlyResult
  {
    try keychainCreateOnlyJSON(
      record,
      account: consumedAccount(jobID: record.jobID),
      matching: { (prior: TatwoLoopGlobalConsumedJobHighWaterV1) in
        prior.jobID == record.jobID
          && prior.dispatchNonce == record.dispatchNonce
          && prior.jobCanonicalDigest == record.jobCanonicalDigest
          && prior.resultDigest == record.resultDigest
          && prior.projectionSequence == record.projectionSequence
      },
      mismatch: {
        TatwoProductionLayoutError.globalAntiRollbackRegression(
          "job \(record.jobID) consume high-water binding mismatch")
      })
  }

  public func loadSnapshot() throws -> TatwoLoopGlobalAntiRollbackStateV1 {
    var claims: [String: TatwoLoopGlobalExecutedClaimV1] = [:]
    for account in try listAccounts(prefix: execClaimAccountPrefix()) {
      if let claim: TatwoLoopGlobalExecutedClaimV1 = try keychainLoad(account: account) {
        claims[claim.jobID] = claim
      }
    }
    var consumed: [String: TatwoLoopGlobalConsumedJobHighWaterV1] = [:]
    for account in try listAccounts(prefix: consumedAccountPrefix()) {
      if let row: TatwoLoopGlobalConsumedJobHighWaterV1 = try keychainLoad(account: account) {
        consumed[row.jobID] = row
      }
    }
    return TatwoLoopGlobalAntiRollbackStateV1(
      storeGenerationHighWater: try loadStoreGenerationHighWater(),
      consumedJobs: consumed,
      executedClaims: claims)
  }

  public func pruneRecordsBelowGeneration(_ floor: UInt64) throws {
    // PILOT: never auto-delete claim/consumed Keychain records (anti-replay truth).
    // Store-generation markers still advance via ensureStoreGeneration; pin-store
    // generation advance must never imply "job claim expired" and delete.
    // MUSTFIX before sustained-use scale: durable replay-floor bounded retention.
    _ = floor
  }

  /// Package-F whole-blob account `global-anti-rollback:<host>`. Package G uses split
  /// accounts; non-empty legacy blobs must not be silently ignored on production enable.
  public static func legacyWholeBlobAccount(hostDeviceID: String) -> String {
    let safe = hostDeviceID.replacingOccurrences(of: ":", with: "_")
    return "global-anti-rollback:\(safe)"
  }

  /// Fail closed when a pre-G whole-JSON anti-rollback Keychain account still holds data.
  /// Fresh dual-host pilot (no prior production claims) sees empty/absent and proceeds.
  public func requireLegacyWholeBlobAbsentOrEmpty() throws {
    let account = Self.legacyWholeBlobAccount(hostDeviceID: hostScope)
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess else {
      throw TatwoProductionLayoutError.globalAntiRollbackRegression(
        "legacy whole-blob keychain read status \(status) account \(account)")
    }
    guard let data = value as? Data else {
      throw TatwoProductionLayoutError.globalAntiRollbackRegression(
        "legacy whole-blob keychain unexpected result shape account \(account)")
    }
    if data.isEmpty { return }
    fputs(
      "tatwo: legacy global-anti-rollback whole-blob account non-empty (\(account)); "
        + "explicit migration or empty confirmation required before production enable\n",
      stderr)
    throw TatwoProductionLayoutError.globalAntiRollbackRegression(
      "legacy whole-blob anti-rollback account non-empty (\(account)); "
        + "migrate or confirm empty before enable — package G split accounts do not read it")
    #else
    throw TatwoProductionLayoutError.globalAntiRollbackRegression("keychain unavailable")
    #endif
  }

  // MARK: account naming — exec-claim:<host>:<jobID>:global

  private func storeGenAccountPrefix() -> String { "store-gen:\(hostScope):" }
  private func storeGenAccount(_ generation: UInt64) -> String {
    "store-gen:\(hostScope):\(generation):global"
  }
  private func parseStoreGenAccount(_ account: String) -> UInt64? {
    // store-gen:<host>:<N>:global
    let parts = account.split(separator: ":")
    guard parts.count >= 4, parts.first == "store-gen", parts.last == "global" else { return nil }
    return UInt64(parts[parts.count - 2])
  }

  private func execClaimAccountPrefix() -> String { "exec-claim:\(hostScope):" }
  private func execClaimAccount(jobID: String) -> String {
    "exec-claim:\(hostScope):\(jobID):global"
  }

  private func consumedAccountPrefix() -> String { "consumed:\(hostScope):" }
  private func consumedAccount(jobID: String) -> String {
    "consumed:\(hostScope):\(jobID):global"
  }

  // MARK: keychain primitives

  private func keychainLoad<T: Decodable>(account: String) throws -> T? {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else {
      throw TatwoProductionLayoutError.globalAntiRollbackRegression(
        "keychain read status \(status) account \(account)")
    }
    return try JSONDecoder().decode(T.self, from: data)
    #else
    throw TatwoProductionLayoutError.globalAntiRollbackRegression("keychain unavailable")
    #endif
  }

  private func keychainCreateOnly(account: String, data: Data, onDuplicate: () throws -> Void)
    throws
  {
    #if canImport(Security)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecSuccess { return }
    if status == errSecDuplicateItem {
      try onDuplicate()
      return
    }
    throw TatwoProductionLayoutError.globalAntiRollbackRegression(
      "keychain create-only add status \(status) account \(account)")
    #else
    throw TatwoProductionLayoutError.globalAntiRollbackRegression("keychain unavailable")
    #endif
  }

  private func keychainCreateOnlyJSON<T: Codable>(
    _ value: T,
    account: String,
    matching: (T) -> Bool,
    mismatch: () -> TatwoProductionLayoutError
  ) throws -> TatwoLoopCreateOnlyResult {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    var result: TatwoLoopCreateOnlyResult = .created
    try keychainCreateOnly(account: account, data: data, onDuplicate: {
      guard let prior: T = try keychainLoad(account: account) else {
        throw TatwoProductionLayoutError.globalAntiRollbackRegression(
          "create-only race: keychain item missing after duplicate account \(account)")
      }
      if matching(prior) {
        result = .alreadyPresentMatching
        return
      }
      throw mismatch()
    })
    return result
  }

  private func keychainDelete(account: String) throws {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return }
    throw TatwoProductionLayoutError.globalAntiRollbackRegression(
      "keychain delete status \(status) account \(account)")
    #else
    throw TatwoProductionLayoutError.globalAntiRollbackRegression("keychain unavailable")
    #endif
  }

  private func listAccounts(prefix: String) throws -> [String] {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else {
      throw TatwoProductionLayoutError.globalAntiRollbackRegression(
        "keychain list status \(status)")
    }
    // Security truth must not silently treat unexpected shapes as empty.
    guard let items = value as? [[String: Any]] else {
      throw TatwoProductionLayoutError.globalAntiRollbackRegression(
        "keychain list unexpected result shape (expected [[String: Any]])")
    }
    var accounts: [String] = []
    accounts.reserveCapacity(items.count)
    for item in items {
      guard let account = item[kSecAttrAccount as String] as? String else {
        throw TatwoProductionLayoutError.globalAntiRollbackRegression(
          "keychain list item missing kSecAttrAccount")
      }
      if account.hasPrefix(prefix) {
        accounts.append(account)
      }
    }
    return accounts
    #else
    throw TatwoProductionLayoutError.globalAntiRollbackRegression("keychain unavailable")
    #endif
  }
}

// MARK: - Layout lock

public struct TatwoProductionResolvedLayout: Sendable, Equatable {
  public let applicationSupportRoot: URL
  public let stateRoot: URL
  public let pinStoreRoot: URL
  public let jobChannelRoot: URL
  public let installAnchor: TatwoProductionInstallAnchorV1

  public var remoteExecutionAuthorizationRoot: URL {
    stateRoot.appendingPathComponent(
      "remote-execution-authorization",
      isDirectory: true)
  }

  public init(
    applicationSupportRoot: URL,
    stateRoot: URL,
    pinStoreRoot: URL,
    jobChannelRoot: URL,
    installAnchor: TatwoProductionInstallAnchorV1
  ) {
    self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
    self.stateRoot = stateRoot.standardizedFileURL
    self.pinStoreRoot = pinStoreRoot.standardizedFileURL
    self.jobChannelRoot = jobChannelRoot.standardizedFileURL
    self.installAnchor = installAnchor
  }
}

/// Production layout authority: OS-native + sealed Keychain install anchor.
/// Process env may only match; it never defines the trust/state namespace.
public enum TatwoProductionLayoutLock {
  public static let appSupportEnvKey = "TATWO_ULTRAWORK_APP_SUPPORT"
  public static let stateDirEnvKey = "TATWO_ULTRAWORK_STATE_DIR"
  public static let osRootEnvKey = "TATWO_OS_ROOT"
  public static let jobChannelEnvKey = "TATWO_ULTRAWORK_JOB_CHANNEL_DIR"

  public static let layoutEnvKeys = [
    appSupportEnvKey,
    stateDirEnvKey,
    osRootEnvKey,
    jobChannelEnvKey,
  ]

  /// Application Support root with **zero** layout env influence.
  public static func osNativeApplicationSupportRoot(
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    TatwoRuntimeLayout.applicationSupportRoot(
      environment: [:],
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
  }

  public static func osNativeStateRoot(
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    osNativeApplicationSupportRoot(
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager
    ).appendingPathComponent("state", isDirectory: true)
  }

  public static func osNativePinStoreRoot(
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    TatwoRuntimeLayout.deviceTrustPinStoreRoot(
      environment: [:],
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
  }

  /// Canonical flock path for global anti-rollback Keychain mutations.
  public static func globalAntiRollbackLockURL(
    accountName: String,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default
  ) -> URL {
    let safe = accountName
      .replacingOccurrences(of: ":", with: "_")
      .replacingOccurrences(of: "/", with: "_")
    return osNativeApplicationSupportRoot(
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager
    )
    .appendingPathComponent("locks", isDirectory: true)
    .appendingPathComponent("global-anti-rollback-\(safe).lock")
  }

  /// Fail closed when production env relocates layout roots away from OS-native / install anchor.
  public static func rejectNonCanonicalLayoutEnv(
    environment: [String: String],
    osNativeAppSupport: URL,
    osNativeState: URL,
    sealedChannelRoot: URL?
  ) throws {
    if let raw = nonempty(environment[appSupportEnvKey]) {
      let observed = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
      if observed.path != osNativeAppSupport.standardizedFileURL.path {
        throw TatwoProductionLayoutError.layoutEnvOverrideForbidden(appSupportEnvKey)
      }
    }
    if let raw = nonempty(environment[stateDirEnvKey]) {
      let observed = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
      if observed.path != osNativeState.standardizedFileURL.path {
        throw TatwoProductionLayoutError.layoutEnvOverrideForbidden(stateDirEnvKey)
      }
    }
    // TATWO_OS_ROOT always relocates GoalRunStore/registry away from App Support state.
    if nonempty(environment[osRootEnvKey]) != nil {
      throw TatwoProductionLayoutError.layoutEnvOverrideForbidden(osRootEnvKey)
    }
    if let raw = nonempty(environment[jobChannelEnvKey]) {
      let observed = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
      if let sealed = sealedChannelRoot,
        observed.path != sealed.standardizedFileURL.path
      {
        throw TatwoProductionLayoutError.layoutEnvOverrideForbidden(jobChannelEnvKey)
      }
    }
  }

  /// Resolve production layout against an **already sealed** install anchor.
  /// Missing anchor is fail-closed (explicit `sealInstallAnchor` / install gate required).
  public static func resolve(
    hostDeviceID: String,
    requestedChannelRoot: URL?,
    environment: [String: String],
    installAnchorStore: any TatwoProductionInstallAnchorStore,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default,
    sealedAt: String = TatwoLoopJobChannelTrust.iso8601(Date())
  ) throws -> TatwoProductionResolvedLayout {
    _ = sealedAt
    let roots = try computeNativeRoots(
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)

    let existing = try installAnchorStore.load()
    guard let existing else {
      throw TatwoProductionLayoutError.installAnchorRejected(
        "missing install anchor; run device-trust install gate / sealInstallAnchor first")
    }

    let sealedChannel = URL(fileURLWithPath: existing.jobChannelRoot, isDirectory: true)
      .standardizedFileURL

    try rejectNonCanonicalLayoutEnv(
      environment: environment,
      osNativeAppSupport: roots.appSupport,
      osNativeState: roots.state,
      sealedChannelRoot: sealedChannel)

    let channelFromEnv = nonempty(environment[jobChannelEnvKey]).map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    let requested = requestedChannelRoot?.standardizedFileURL

    if let requested, requested.path != sealedChannel.path {
      throw TatwoProductionLayoutError.channelRootOverrideForbidden(requested.path)
    }
    if let channelFromEnv, channelFromEnv.path != sealedChannel.path {
      throw TatwoProductionLayoutError.layoutEnvOverrideForbidden(jobChannelEnvKey)
    }

    try requireMatch(
      role: "applicationSupportRoot",
      expected: existing.applicationSupportRoot,
      observed: roots.appSupport.path)
    try requireMatch(
      role: "stateRoot",
      expected: existing.stateRoot,
      observed: roots.state.path)
    try requireMatch(
      role: "pinStoreRoot",
      expected: existing.pinStoreRoot,
      observed: roots.pinStore.path)
    try requireMatch(
      role: "jobChannelRoot",
      expected: existing.jobChannelRoot,
      observed: sealedChannel.path)
    try requireMatch(
      role: "hostDeviceID",
      expected: existing.hostDeviceID,
      observed: hostDeviceID)

    return TatwoProductionResolvedLayout(
      applicationSupportRoot: roots.appSupport,
      stateRoot: roots.state,
      pinStoreRoot: roots.pinStore,
      jobChannelRoot: sealedChannel,
      installAnchor: existing)
  }

  /// Explicit install-gate seal (create-only). Not called implicitly by resolve/bootstrap.
  public static func sealInstallAnchor(
    hostDeviceID: String,
    requestedChannelRoot: URL?,
    environment: [String: String],
    installAnchorStore: any TatwoProductionInstallAnchorStore,
    applicationSupportBase: URL? = nil,
    fileManager: FileManager = .default,
    sealedAt: String = TatwoLoopJobChannelTrust.iso8601(Date())
  ) throws -> TatwoProductionResolvedLayout {
    let roots = try computeNativeRoots(
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)

    let existing = try installAnchorStore.load()
    let sealedChannel = existing.map {
      URL(fileURLWithPath: $0.jobChannelRoot, isDirectory: true).standardizedFileURL
    }

    try rejectNonCanonicalLayoutEnv(
      environment: environment,
      osNativeAppSupport: roots.appSupport,
      osNativeState: roots.state,
      sealedChannelRoot: sealedChannel)

    let channelFromEnv = nonempty(environment[jobChannelEnvKey]).map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }
    let requested = requestedChannelRoot?.standardizedFileURL

    let channelRoot: URL
    if let sealedChannel {
      if let requested, requested.path != sealedChannel.path {
        throw TatwoProductionLayoutError.channelRootOverrideForbidden(requested.path)
      }
      if let channelFromEnv, channelFromEnv.path != sealedChannel.path {
        throw TatwoProductionLayoutError.layoutEnvOverrideForbidden(jobChannelEnvKey)
      }
      channelRoot = sealedChannel
    } else if let requested {
      channelRoot = requested
    } else if let channelFromEnv {
      channelRoot = channelFromEnv
    } else {
      throw TatwoProductionLayoutError.channelRootOverrideForbidden(
        "(missing \(jobChannelEnvKey) / --channel-dir)")
    }

    if let existing {
      try requireMatch(
        role: "applicationSupportRoot",
        expected: existing.applicationSupportRoot,
        observed: roots.appSupport.path)
      try requireMatch(
        role: "stateRoot",
        expected: existing.stateRoot,
        observed: roots.state.path)
      try requireMatch(
        role: "pinStoreRoot",
        expected: existing.pinStoreRoot,
        observed: roots.pinStore.path)
      try requireMatch(
        role: "jobChannelRoot",
        expected: existing.jobChannelRoot,
        observed: channelRoot.path)
      try requireMatch(
        role: "hostDeviceID",
        expected: existing.hostDeviceID,
        observed: hostDeviceID)
      // Re-save is create-only load-and-compare (idempotent if equal).
      try installAnchorStore.save(existing)
      return TatwoProductionResolvedLayout(
        applicationSupportRoot: roots.appSupport,
        stateRoot: roots.state,
        pinStoreRoot: roots.pinStore,
        jobChannelRoot: channelRoot,
        installAnchor: existing)
    }

    let anchor = TatwoProductionInstallAnchorV1(
      hostDeviceID: hostDeviceID,
      applicationSupportRoot: roots.appSupport.path,
      stateRoot: roots.state.path,
      pinStoreRoot: roots.pinStore.path,
      jobChannelRoot: channelRoot.path,
      sealedAt: sealedAt)
    try installAnchorStore.save(anchor)
    // Read-back: ensure durable seal matches what we intended.
    guard let readBack = try installAnchorStore.load() else {
      throw TatwoProductionLayoutError.installAnchorRejected(
        "install anchor missing after create-only save")
    }
    if readBack != anchor {
      throw TatwoProductionLayoutError.installAnchorRejected(
        "install anchor read-back mismatch after seal")
    }
    return TatwoProductionResolvedLayout(
      applicationSupportRoot: roots.appSupport,
      stateRoot: roots.state,
      pinStoreRoot: roots.pinStore,
      jobChannelRoot: channelRoot,
      installAnchor: readBack)
  }

  /// Raise global store-generation high-water via create-only generation markers.
  /// Refuse regression (old namespace). Independent of lock inodes.
  ///
  /// Store-generation markers advance monotonically. Pin-store generation advance must
  /// **never** imply that a job claim/consumed record is stale or deletable.
  ///
  /// Pilot: claim/consumed auto-prune is **disabled** (accept finite growth). Before
  /// sustained-use scale, ship durable replay-floor bounded retention:
  /// - include job generation/epoch in the signed canonical digest
  /// - reject claims below the durable floor
  /// - only advance the floor after in-flight jobs (and signature freshness windows)
  ///   are covered; then prune is safe
  public static func enforceStoreGenerationAntiRollback(
    observed: UInt64,
    anchor: any TatwoLoopGlobalAntiRollbackAnchor
  ) throws {
    let current = try anchor.loadStoreGenerationHighWater()
    if observed < current {
      throw TatwoProductionLayoutError.globalAntiRollbackRegression(
        "storeGeneration \(observed) < global high-water \(current)")
    }
    if observed > current {
      let highWater = try anchor.ensureStoreGeneration(observed)
      if highWater < observed {
        throw TatwoProductionLayoutError.globalAntiRollbackRegression(
          "storeGeneration create-only failed to reach \(observed) (high-water \(highWater))")
      }
      // PILOT: do not auto-prune claim/consumed records on generation advance.
      // Lag-1 prune previously deleted still-valid anti-replay claims and allowed
      // restored queued snapshots to re-claim. Disabled until durable replay floor.
    }
  }

  /// Refuse replaying an older attempt when a durable per-job consume record exists.
  /// Create-only per jobID — no whole-document overwrite path.
  public static func enforceConsumeAntiRollback(
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    resultDigest: String,
    projectionSequence: UInt64,
    anchor: any TatwoLoopGlobalAntiRollbackAnchor
  ) throws {
    if let prior = try anchor.loadConsumedJob(jobID: jobID) {
      if prior.dispatchNonce == dispatchNonce,
        prior.jobCanonicalDigest == jobCanonicalDigest,
        prior.resultDigest == resultDigest,
        prior.projectionSequence == projectionSequence
      {
        return
      }
      if projectionSequence < prior.projectionSequence
        || prior.dispatchNonce != dispatchNonce
        || prior.jobCanonicalDigest != jobCanonicalDigest
      {
        throw TatwoProductionLayoutError.globalAntiRollbackRegression(
          "job \(jobID) readback below global consume high-water")
      }
      throw TatwoProductionLayoutError.globalAntiRollbackRegression(
        "job \(jobID) consume evidence mismatch vs global high-water")
    }
    let boundGeneration = try anchor.loadStoreGenerationHighWater()
    let record = TatwoLoopGlobalConsumedJobHighWaterV1(
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      jobCanonicalDigest: jobCanonicalDigest,
      resultDigest: resultDigest,
      projectionSequence: projectionSequence,
      boundGeneration: boundGeneration)
    switch try anchor.createConsumedJob(record) {
    case .created, .alreadyPresentMatching:
      return
    }
  }

  /// Target-side create-only claim before any channel transition or engine execution.
  ///
  /// Atomic fence is the create-only record for account/path
  /// `exec-claim:<host>:<jobID>:global` (Keychain `SecItemAdd` / file `O_EXCL`).
  /// Matching prior → already claimed (caller refuses replay). Binding mismatch → reject.
  public static func claimTargetExecution(
    jobID: String,
    dispatchNonce: String,
    jobCanonicalDigest: String,
    anchor: any TatwoLoopGlobalAntiRollbackAnchor
  ) throws {
    let boundGeneration = try anchor.loadStoreGenerationHighWater()
    let claim = TatwoLoopGlobalExecutedClaimV1(
      jobID: jobID,
      dispatchNonce: dispatchNonce,
      jobCanonicalDigest: jobCanonicalDigest,
      boundGeneration: boundGeneration)
    switch try anchor.createExecutedClaim(claim) {
    case .created:
      return
    case .alreadyPresentMatching:
      throw TatwoProductionLayoutError.targetExecutionAlreadyClaimed(jobID: jobID)
    }
  }

  private struct NativeRoots {
    let appSupport: URL
    let state: URL
    let pinStore: URL
  }

  private static func computeNativeRoots(
    applicationSupportBase: URL?,
    fileManager: FileManager
  ) throws -> NativeRoots {
    let appSupport = osNativeApplicationSupportRoot(
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    let state = osNativeStateRoot(
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    let pinStore = osNativePinStoreRoot(
      applicationSupportBase: applicationSupportBase,
      fileManager: fileManager)
    return NativeRoots(appSupport: appSupport, state: state, pinStore: pinStore)
  }

  private static func requireMatch(role: String, expected: String, observed: String) throws {
    if expected != observed {
      throw TatwoProductionLayoutError.installAnchorMismatch(
        role: role,
        expected: expected,
        observed: observed)
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
