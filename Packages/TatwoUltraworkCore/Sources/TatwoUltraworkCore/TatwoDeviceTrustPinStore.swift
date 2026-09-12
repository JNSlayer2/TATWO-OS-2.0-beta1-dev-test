import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// Durable, fail-closed device pin store under App Support `device-trust/pin-store/`.
///
/// Each pinned identity and each stored revocation receipt is co-signed by the
/// **local** device private key. On load, every record is verified; invalid
/// entries are dropped and journaled (per-entry fail-closed — never trust a
/// whole-file edit that lacks the local private key).
///
/// Empty store ⇒ no peer pins (callers still self-pin on enroll). No default trust.
public enum TatwoDeviceTrustPinStoreError: Error, Equatable, LocalizedError {
  case fingerprintMismatch(expected: String, actual: String)
  case invalidFingerprint
  case invalidStoreRecord(String)
  case missingPin(String)
  case unsafePath(String)
  case symlinkRefused(String)
  case storeGenerationRegression(expected: UInt64, observed: UInt64)
  case missingRevocationTombstone(deviceID: String, epoch: UInt64)
  case storeAnchorRejected(String)
  case storeNotInitialized
  case reEnrollmentRequired(deviceID: String)
  case reEnrollmentRejected(deviceID: String, detail: String)

  public var errorDescription: String? {
    switch self {
    case .fingerprintMismatch(let expected, let actual):
      "Pin-import fingerprint mismatch (expected \(expected), got \(actual))."
    case .invalidFingerprint:
      "Fingerprint must be 64 lowercase hexadecimal characters."
    case .invalidStoreRecord(let detail):
      "Device trust pin-store record rejected: \(detail)."
    case .missingPin(let deviceID):
      "Pinned identity not found in durable store: \(deviceID)."
    case .unsafePath(let detail):
      "Unsafe device-trust pin-store path: \(detail)."
    case .symlinkRefused(let path):
      "Refusing symlink device-trust pin-store path: \(path)."
    case .storeGenerationRegression(let expected, let observed):
      "Device trust pin-store generation regression (anchor \(expected), observed \(observed))."
    case .missingRevocationTombstone(let deviceID, let epoch):
      "Device trust pin-store missing revocation tombstone for \(deviceID) epoch \(epoch)."
    case .storeAnchorRejected(let detail):
      "Device trust pin-store epoch anchor rejected: \(detail)."
    case .storeNotInitialized:
      "Device trust pin-store is not initialized (missing anchor and store-meta). Run device-trust init."
    case .reEnrollmentRequired(let deviceID):
      "Active pin for previously revoked device \(deviceID) requires authority-signed re-enrollment."
    case .reEnrollmentRejected(let deviceID, let detail):
      "Re-enrollment for \(deviceID) rejected: \(detail)."
    }
  }
}

/// Monotonic store authority high-water marks (external to pin/revocation files).
public struct TatwoDeviceTrustPinStoreEpochState: Codable, Equatable, Sendable {
  public var schema: String
  public var storeGeneration: UInt64
  public var deviceHighestKeyGeneration: [String: UInt64]
  public var deviceHighestRevocationEpoch: [String: UInt64]

  public init(
    schema: String = "TatwoDeviceTrustPinStoreEpochStateV1",
    storeGeneration: UInt64 = 0,
    deviceHighestKeyGeneration: [String: UInt64] = [:],
    deviceHighestRevocationEpoch: [String: UInt64] = [:]
  ) {
    self.schema = schema
    self.storeGeneration = storeGeneration
    self.deviceHighestKeyGeneration = deviceHighestKeyGeneration
    self.deviceHighestRevocationEpoch = deviceHighestRevocationEpoch
  }

  public static let empty = TatwoDeviceTrustPinStoreEpochState()
}

/// Side-channel store for pin-store generation / revocation high-water marks.
public protocol TatwoDeviceTrustPinStoreEpochAnchor: Sendable {
  func load() throws -> TatwoDeviceTrustPinStoreEpochState?
  func save(_ state: TatwoDeviceTrustPinStoreEpochState) throws
}

/// File-backed epoch anchor (test mode / non-Keychain hosts).
public struct TatwoDeviceTrustPinStoreFileEpochAnchor: TatwoDeviceTrustPinStoreEpochAnchor {
  public let url: URL

  public init(url: URL) {
    self.url = url.standardizedFileURL
  }

  public func load() throws -> TatwoDeviceTrustPinStoreEpochState? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw TatwoDeviceTrustPinStoreError.symlinkRefused(url.path)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(TatwoDeviceTrustPinStoreEpochState.self, from: data)
  }

  public func save(_ state: TatwoDeviceTrustPinStoreEpochState) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if FileManager.default.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        throw TatwoDeviceTrustPinStoreError.symlinkRefused(url.path)
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(state)
    try TatwoAtomicFile.write(data, to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
  }
}

/// Keychain side-item epoch anchor (production hosts).
public struct TatwoDeviceTrustPinStoreKeychainEpochAnchor: TatwoDeviceTrustPinStoreEpochAnchor {
  public static let serviceEnvKey = "TATWO_DEVICE_TRUST_PIN_STORE_EPOCH_SERVICE"
  public static let canonicalService = "ai.tatwo.ultrawork.device-trust.pin-store-epoch"

  private let service: String
  private let account: String

  public static func configuration(
    hostDeviceID: String,
    storeRoot: URL,
    environment: [String: String]
  ) throws -> (service: String, account: String) {
    let testMode = environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1"
    let configured =
      environment[serviceEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let override = configured.flatMap { $0.isEmpty ? nil : $0 }
    if override != nil, !testMode {
      // Production: env override is a clean-namespace bypass; refuse startup (do not clamp).
      throw TatwoDeviceTrustPinStoreError.storeAnchorRejected(
        "\(serviceEnvKey) is only allowed when \(TatwoLoopJobChannelTrust.testModeEnvKey)=1")
    }
    let resolvedService = override ?? canonicalService
    let safeHost = hostDeviceID.replacingOccurrences(of: ":", with: "_")
    // Production: fixed global epoch account (not pin-store path hashed) so
    // APP_SUPPORT / layout env cannot open a clean older epoch namespace.
    // Test mode retains path hash for fixture isolation across temp roots.
    let account: String
    if testMode {
      let rootToken = TatwoLoopJobChannelTrust.sha256Hex(
        Data(storeRoot.standardizedFileURL.path.utf8))
      account = "pin-store-epoch:\(safeHost):\(String(rootToken.prefix(24)))"
    } else {
      account = "pin-store-epoch:\(safeHost):global"
    }
    return (resolvedService, account)
  }

  /// Fail-closed stand-in when production namespace policy is violated.
  public struct Rejecting: TatwoDeviceTrustPinStoreEpochAnchor {
    public let detail: String

    public init(detail: String) {
      self.detail = detail
    }

    public func load() throws -> TatwoDeviceTrustPinStoreEpochState? {
      throw TatwoDeviceTrustPinStoreError.storeAnchorRejected(detail)
    }

    public func save(_ state: TatwoDeviceTrustPinStoreEpochState) throws {
      throw TatwoDeviceTrustPinStoreError.storeAnchorRejected(detail)
    }
  }

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  public func load() throws -> TatwoDeviceTrustPinStoreEpochState? {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = value as? Data else {
      throw TatwoDeviceTrustPinStoreError.storeAnchorRejected(
        "keychain read status \(status)")
    }
    return try JSONDecoder().decode(TatwoDeviceTrustPinStoreEpochState.self, from: data)
    #else
    throw TatwoDeviceTrustPinStoreError.storeAnchorRejected("keychain unavailable")
    #endif
  }

  public func save(_ state: TatwoDeviceTrustPinStoreEpochState) throws {
    #if canImport(Security)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(state)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    if updateStatus == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw TatwoDeviceTrustPinStoreError.storeAnchorRejected(
          "keychain add status \(addStatus)")
      }
      return
    }
    throw TatwoDeviceTrustPinStoreError.storeAnchorRejected(
      "keychain update status \(updateStatus)")
    #else
    throw TatwoDeviceTrustPinStoreError.storeAnchorRejected("keychain unavailable")
    #endif
  }
}

public struct TatwoDeviceTrustPinStoreJournalEntryV1: Codable, Equatable, Sendable {
  public let schema: String
  public let event: String
  public let deviceID: String?
  public let reason: String
  public let detail: String?
  public let occurredAt: String

  public init(
    schema: String = "TatwoDeviceTrustPinStoreJournalEntryV1",
    event: String,
    deviceID: String? = nil,
    reason: String,
    detail: String? = nil,
    occurredAt: String
  ) {
    self.schema = schema
    self.event = event
    self.deviceID = deviceID
    self.reason = reason
    self.detail = detail.map { String(TatwoPrivacyRedactor.redacted($0).prefix(256)) }
    self.occurredAt = occurredAt
  }
}

public struct TatwoDeviceTrustPinnedIdentityRecordV1: Codable, Equatable, Sendable {
  public let schema: String
  public let identity: TatwoDevicePublicIdentityV1
  public let storedAt: String
  public let storeHostDeviceID: String
  public let authorization: TatwoDeviceSignatureV1

  public init(
    schema: String = "TatwoDeviceTrustPinnedIdentityRecordV1",
    identity: TatwoDevicePublicIdentityV1,
    storedAt: String,
    storeHostDeviceID: String,
    authorization: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.identity = identity
    self.storedAt = storedAt
    self.storeHostDeviceID = storeHostDeviceID
    self.authorization = authorization
  }
}

public struct TatwoDeviceTrustStoredRevocationRecordV1: Codable, Equatable, Sendable {
  public let schema: String
  public let receipt: TatwoDeviceKeyRevocationReceiptV1
  public let storedAt: String
  public let storeHostDeviceID: String
  public let authorization: TatwoDeviceSignatureV1

  public init(
    schema: String = "TatwoDeviceTrustStoredRevocationRecordV1",
    receipt: TatwoDeviceKeyRevocationReceiptV1,
    storedAt: String,
    storeHostDeviceID: String,
    authorization: TatwoDeviceSignatureV1
  ) {
    self.schema = schema
    self.receipt = receipt
    self.storedAt = storedAt
    self.storeHostDeviceID = storeHostDeviceID
    self.authorization = authorization
  }
}

public struct TatwoDeviceTrustPinListEntryV1: Codable, Equatable, Sendable {
  public let schema: String
  public let deviceID: String
  public let keyID: String
  public let keyGeneration: UInt64
  public let keyStatus: TatwoDeviceKeyStatusV1
  public let fingerprint: String
  public let pinnedAt: String
  public let storedAt: String?

  public init(
    schema: String = "TatwoDeviceTrustPinListEntryV1",
    deviceID: String,
    keyID: String,
    keyGeneration: UInt64,
    keyStatus: TatwoDeviceKeyStatusV1,
    fingerprint: String,
    pinnedAt: String,
    storedAt: String? = nil
  ) {
    self.schema = schema
    self.deviceID = deviceID
    self.keyID = keyID
    self.keyGeneration = keyGeneration
    self.keyStatus = keyStatus
    self.fingerprint = fingerprint
    self.pinnedAt = pinnedAt
    self.storedAt = storedAt
  }
}

public struct TatwoDeviceTrustPinStoreLoadResult: Sendable, Equatable {
  public let pins: [String: TatwoDevicePublicIdentityV1]
  public let rejectedPinCount: Int
  public let rejectedRevocationCount: Int
  public let appliedRevocationCount: Int
  public let storeGeneration: UInt64

  public init(
    pins: [String: TatwoDevicePublicIdentityV1],
    rejectedPinCount: Int,
    rejectedRevocationCount: Int,
    appliedRevocationCount: Int,
    storeGeneration: UInt64 = 0
  ) {
    self.pins = pins
    self.rejectedPinCount = rejectedPinCount
    self.rejectedRevocationCount = rejectedRevocationCount
    self.appliedRevocationCount = appliedRevocationCount
    self.storeGeneration = storeGeneration
  }
}

/// File-backed pin store. Production hosts use Keychain-backed private keys;
/// tests inject `TatwoDeviceTestFilePrivateKeyStore` / in-memory stores.
public struct TatwoDeviceTrustPinStore: Sendable {
  public static let pinRecordPurpose = "device-trust-pin-record"
  public static let revocationRecordPurpose = "device-trust-revocation-record"
  public static let storeMetaPurpose = "device-trust-pin-store-meta"
  public static let storeMetaFileName = "store-meta.json"

  public let rootURL: URL
  public let authority: TatwoDeviceTrustAuthority
  public let localIdentity: TatwoDevicePublicIdentityV1
  public let epochAnchor: any TatwoDeviceTrustPinStoreEpochAnchor

  public init(
    rootURL: URL,
    authority: TatwoDeviceTrustAuthority,
    localIdentity: TatwoDevicePublicIdentityV1,
    epochAnchor: (any TatwoDeviceTrustPinStoreEpochAnchor)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    let standardized = rootURL.standardizedFileURL
    self.rootURL = standardized
    self.authority = authority
    self.localIdentity = localIdentity
    if let epochAnchor {
      self.epochAnchor = epochAnchor
    } else {
      self.epochAnchor = Self.defaultEpochAnchor(
        rootURL: standardized,
        hostDeviceID: localIdentity.deviceID,
        environment: environment)
    }
  }

  public static func defaultEpochAnchor(
    rootURL: URL,
    hostDeviceID: String,
    environment: [String: String]
  ) -> any TatwoDeviceTrustPinStoreEpochAnchor {
    // Test mode: file under the pin-store root (survives pin/revocation file deletes
    // when the test only rolls those back). Production: Keychain side item.
    if environment[TatwoLoopJobChannelTrust.testModeEnvKey] == "1" {
      // Test mode may still resolve a custom Keychain service for isolation tests.
      if let configured = environment[
        TatwoDeviceTrustPinStoreKeychainEpochAnchor.serviceEnvKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !configured.isEmpty
      {
        do {
          let config = try TatwoDeviceTrustPinStoreKeychainEpochAnchor.configuration(
            hostDeviceID: hostDeviceID,
            storeRoot: rootURL,
            environment: environment)
          return TatwoDeviceTrustPinStoreKeychainEpochAnchor(
            service: config.service,
            account: config.account)
        } catch {
          return TatwoDeviceTrustPinStoreKeychainEpochAnchor.Rejecting(
            detail: "\(error)")
        }
      }
      return TatwoDeviceTrustPinStoreFileEpochAnchor(
        url: rootURL.appendingPathComponent("epoch-anchor.json", isDirectory: false))
    }
    do {
      let config = try TatwoDeviceTrustPinStoreKeychainEpochAnchor.configuration(
        hostDeviceID: hostDeviceID,
        storeRoot: rootURL,
        environment: environment)
      return TatwoDeviceTrustPinStoreKeychainEpochAnchor(
        service: config.service,
        account: config.account)
    } catch {
      // Production path: never clamp to a writable file anchor when policy fails.
      return TatwoDeviceTrustPinStoreKeychainEpochAnchor.Rejecting(
        detail: "\(error)")
    }
  }

  public var storeMetaURL: URL {
    rootURL.appendingPathComponent(Self.storeMetaFileName, isDirectory: false)
  }

  public func currentStoreGeneration() throws -> UInt64 {
    let anchor = try epochAnchor.load()
    let meta = try loadStoreMetaIfPresent()
    if let anchor, let meta, anchor.storeGeneration != meta.storeGeneration {
      throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
        expected: anchor.storeGeneration,
        observed: meta.storeGeneration)
    }
    return max(anchor?.storeGeneration ?? 0, meta?.storeGeneration ?? 0)
  }

  public static func defaultRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    TatwoRuntimeLayout.deviceTrustPinStoreRoot(environment: environment)
  }

  // MARK: - Fingerprints

  /// Lowercase hex SHA-256 of raw bytes (file contents or public-key material).
  public static func sha256Fingerprint(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Fingerprint of the public key (raw 32 bytes). Stable across export formatting.
  public static func publicKeyFingerprint(
    of identity: TatwoDevicePublicIdentityV1
  ) throws -> String {
    guard let key = Data(base64Encoded: identity.publicKey), key.count == 32 else {
      throw TatwoDeviceTrustError.invalidPublicKey
    }
    return sha256Fingerprint(of: key)
  }

  public static func normalizeFingerprint(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
      throw TatwoDeviceTrustPinStoreError.invalidFingerprint
    }
    return trimmed
  }

  // MARK: - Paths

  public var pinsDirectoryURL: URL {
    rootURL.appendingPathComponent(
      TatwoRuntimeLayout.deviceTrustPinsDirectoryName,
      isDirectory: true)
  }

  public var revocationsDirectoryURL: URL {
    rootURL.appendingPathComponent(
      TatwoRuntimeLayout.deviceTrustRevocationsDirectoryName,
      isDirectory: true)
  }

  public var journalURL: URL {
    rootURL.appendingPathComponent(
      TatwoRuntimeLayout.deviceTrustPinStoreJournalFileName,
      isDirectory: false)
  }

  // MARK: - Mutating API

  /// Import a peer public identity after out-of-band fingerprint check.
  /// `expectedFingerprint` is SHA-256 of the **file bytes** being imported
  /// (anti mid-path swap), not the public-key fingerprint alone.
  public func pinImport(
    identityFileURL: URL,
    expectedFingerprint: String,
    storedAt: String = TatwoLoopJobChannelTrust.iso8601(Date())
  ) throws -> TatwoDevicePublicIdentityV1 {
    let data = try Data(contentsOf: identityFileURL)
    let actual = Self.sha256Fingerprint(of: data)
    let expected = try Self.normalizeFingerprint(expectedFingerprint)
    guard actual == expected else {
      throw TatwoDeviceTrustPinStoreError.fingerprintMismatch(
        expected: expected,
        actual: actual)
    }
    let identity = try JSONDecoder().decode(
      TatwoDevicePublicIdentityV1.self,
      from: data)
    try pin(identity, storedAt: storedAt)
    return identity
  }

  public func pin(
    _ identity: TatwoDevicePublicIdentityV1,
    storedAt: String = TatwoLoopJobChannelTrust.iso8601(Date()),
    rotationReceipt: TatwoDeviceKeyRotationReceiptV1? = nil,
    authorizingIdentity: TatwoDevicePublicIdentityV1? = nil
  ) throws {
    try TatwoDeviceTrustAuthority.validatePublicIdentity(identity)
    // Enforce monotonic high-water against the external epoch anchor.
    if let anchor = try epochAnchor.load() {
      if let highest = anchor.deviceHighestKeyGeneration[identity.deviceID],
        identity.keyGeneration < highest
      {
        throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
          expected: highest,
          observed: identity.keyGeneration)
      }
      if let revEpoch = anchor.deviceHighestRevocationEpoch[identity.deviceID],
        revEpoch > 0,
        identity.keyStatus == .active
      {
        let highestKey = anchor.deviceHighestKeyGeneration[identity.deviceID] ?? 0
        if identity.keyGeneration <= highestKey {
          throw TatwoDeviceTrustPinStoreError.missingRevocationTombstone(
            deviceID: identity.deviceID,
            epoch: revEpoch)
        }
        // Higher-generation active after revocation requires authority re-enrollment.
        guard let rotationReceipt, rotationReceipt.isReEnrollment else {
          throw TatwoDeviceTrustPinStoreError.reEnrollmentRequired(
            deviceID: identity.deviceID)
        }
        if rotationReceipt.supersedesRevocationEpoch < revEpoch {
          throw TatwoDeviceTrustPinStoreError.reEnrollmentRejected(
            deviceID: identity.deviceID,
            detail:
              "supersedesRevocationEpoch \(rotationReceipt.supersedesRevocationEpoch) < \(revEpoch)"
          )
        }
        guard rotationReceipt.deviceID == identity.deviceID,
          rotationReceipt.newIdentity.keyID == identity.keyID,
          rotationReceipt.newIdentity.keyGeneration == identity.keyGeneration,
          rotationReceipt.newIdentity.publicKey == identity.publicKey
        else {
          throw TatwoDeviceTrustPinStoreError.reEnrollmentRejected(
            deviceID: identity.deviceID,
            detail: "rotation newIdentity mismatch")
        }
        let existingPins = try loadPinnedIdentitiesOnly().pins
        let priorPin = existingPins[identity.deviceID]
        let oldIdentity = TatwoDevicePublicIdentityV1(
          deviceID: identity.deviceID,
          keyID: rotationReceipt.oldKeyID,
          publicKey: priorPin?.publicKey ?? rotationReceipt.newIdentity.publicKey,
          keyGeneration: rotationReceipt.oldKeyGeneration,
          keyStatus: .revoked,
          pinnedAt: priorPin?.pinnedAt ?? identity.pinnedAt)
        // Prefer explicit authorizer pin; fall back to host only if it matches receipt signer.
        // SPEC (pre multi-gen re-enroll): before claiming cross-generation
        // rotate/revoke/re-enroll is production-ready, require
        // `authorizingIdentity` to be proven from the durable *active* pin set
        // (not only caller-supplied material). Initial dual-host enablement
        // does not depend on re-enrollment; post-revoke stays fail-closed until
        // that durable-membership check is implemented and tested.
        let authorizer: TatwoDevicePublicIdentityV1
        if let authorizingIdentity {
          authorizer = authorizingIdentity
        } else if let matched = existingPins.values.first(where: {
          $0.deviceID == rotationReceipt.authorization.deviceID
            && $0.keyID == rotationReceipt.authorization.keyID
            && $0.keyStatus == .active
        }) {
          authorizer = matched
        } else if localIdentity.deviceID == rotationReceipt.authorization.deviceID,
          localIdentity.keyID == rotationReceipt.authorization.keyID,
          localIdentity.keyStatus == .active
        {
          authorizer = localIdentity
        } else {
          throw TatwoDeviceTrustPinStoreError.reEnrollmentRejected(
            deviceID: identity.deviceID,
            detail: "missing active authorizing identity")
        }
        do {
          try TatwoDeviceTrustAuthority.verifyRotation(
            rotationReceipt,
            oldIdentity: oldIdentity,
            authorizingIdentity: authorizer)
        } catch {
          throw TatwoDeviceTrustPinStoreError.reEnrollmentRejected(
            deviceID: identity.deviceID,
            detail: String(describing: error))
        }
      }
    }
    let body = PinRecordBody(
      identity: identity,
      storedAt: storedAt,
      storeHostDeviceID: localIdentity.deviceID)
    let payload = try Self.canonicalJSON(body)
    let authorization = try authority.sign(
      payload: payload,
      purpose: Self.pinRecordPurpose,
      identity: localIdentity,
      signedAt: storedAt)
    let record = TatwoDeviceTrustPinnedIdentityRecordV1(
      identity: identity,
      storedAt: storedAt,
      storeHostDeviceID: localIdentity.deviceID,
      authorization: authorization)
    try writeRecord(record, to: pinURL(forDeviceID: identity.deviceID))
    try bumpEpochAfterMutation { state in
      let prior = state.deviceHighestKeyGeneration[identity.deviceID] ?? 0
      state.deviceHighestKeyGeneration[identity.deviceID] = max(
        prior,
        identity.keyGeneration)
      if let rotationReceipt, rotationReceipt.isReEnrollment {
        let priorRev = state.deviceHighestRevocationEpoch[identity.deviceID] ?? 0
        if rotationReceipt.supersedesRevocationEpoch >= priorRev {
          state.deviceHighestRevocationEpoch[identity.deviceID] = 0
        }
      }
    }
  }

  /// Persist a verified revocation receipt and rewrite the target pin as revoked.
  public func ingestRevocation(
    _ receipt: TatwoDeviceKeyRevocationReceiptV1,
    expectedAuthorityEpoch: UInt64,
    storedAt: String = TatwoLoopJobChannelTrust.iso8601(Date())
  ) throws -> TatwoDevicePublicIdentityV1 {
    let loaded = try loadPinnedIdentitiesOnly()
    guard let target = loaded.pins[receipt.targetDeviceID] else {
      throw TatwoDeviceTrustPinStoreError.missingPin(receipt.targetDeviceID)
    }
    guard let authorizer = loaded.pins[receipt.authorizedByDeviceID] else {
      throw TatwoDeviceTrustPinStoreError.missingPin(receipt.authorizedByDeviceID)
    }
    try TatwoDeviceTrustAuthority.verifyRevocation(
      receipt,
      targetIdentity: target,
      authorizerIdentity: authorizer,
      expectedAuthorityEpoch: expectedAuthorityEpoch)

    let body = RevocationRecordBody(
      receipt: receipt,
      storedAt: storedAt,
      storeHostDeviceID: localIdentity.deviceID)
    let payload = try Self.canonicalJSON(body)
    let authorization = try authority.sign(
      payload: payload,
      purpose: Self.revocationRecordPurpose,
      identity: localIdentity,
      signedAt: storedAt)
    let record = TatwoDeviceTrustStoredRevocationRecordV1(
      receipt: receipt,
      storedAt: storedAt,
      storeHostDeviceID: localIdentity.deviceID,
      authorization: authorization)
    try writeRecord(record, to: revocationURL(for: receipt))

    let revoked = TatwoDevicePublicIdentityV1(
      deviceID: target.deviceID,
      keyID: target.keyID,
      publicKey: target.publicKey,
      keyGeneration: target.keyGeneration,
      keyStatus: .revoked,
      pinnedAt: target.pinnedAt)
    // Write revoked pin without a second generation bump (single mutation).
    try writePinnedIdentityRecord(revoked, storedAt: storedAt)
    try bumpEpochAfterMutation { state in
      let priorKey = state.deviceHighestKeyGeneration[revoked.deviceID] ?? 0
      state.deviceHighestKeyGeneration[revoked.deviceID] = max(
        priorKey,
        revoked.keyGeneration)
      let priorEpoch = state.deviceHighestRevocationEpoch[revoked.deviceID] ?? 0
      state.deviceHighestRevocationEpoch[revoked.deviceID] = max(
        priorEpoch,
        receipt.authorityEpoch)
    }
    return revoked
  }

  // MARK: - Load / list

  /// Load pins, apply durable revocations via the same verification path as
  /// `TatwoLoopJobChannelTrust.ingestRevocationReceipt`, fail-closed per entry.
  ///
  /// Whole-store fail-closed when the external epoch anchor shows a higher
  /// generation or a revocation tombstone that is no longer present.
  /// Explicit first-time store initialization (anchor + store-meta generation 0→1).
  /// Production runners must not implicitly create a trust root.
  public func initializeIfNeeded(
    at storedAt: String = TatwoLoopJobChannelTrust.iso8601(Date())
  ) throws {
    let anchor = try epochAnchor.load()
    let meta = try loadStoreMetaIfPresent()
    if anchor != nil || meta != nil {
      // Already initialized (possibly generation 0 empty marker).
      if anchor == nil || meta == nil {
        throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
          expected: anchor?.storeGeneration ?? 0,
          observed: meta?.storeGeneration ?? 0)
      }
      return
    }
    var state = TatwoDeviceTrustPinStoreEpochState.empty
    state.storeGeneration = 1
    try epochAnchor.save(state)
    try writeStoreMeta(storeGeneration: 1)
    appendJournal(
      event: "store_initialized",
      deviceID: localIdentity.deviceID,
      reason: "device-trust-init",
      detail: storedAt)
  }

  public func load(
    requireInitialized: Bool = false
  ) throws -> TatwoDeviceTrustPinStoreLoadResult {
    let anchor = try epochAnchor.load()
    let meta = try loadStoreMetaIfPresent()
    if requireInitialized, anchor == nil, meta == nil {
      throw TatwoDeviceTrustPinStoreError.storeNotInitialized
    }
    if let anchor, let meta {
      if meta.storeGeneration < anchor.storeGeneration {
        throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
          expected: anchor.storeGeneration,
          observed: meta.storeGeneration)
      }
      if meta.storeGeneration > anchor.storeGeneration {
        throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
          expected: anchor.storeGeneration,
          observed: meta.storeGeneration)
      }
    } else if let anchor, anchor.storeGeneration > 0, meta == nil {
      throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
        expected: anchor.storeGeneration,
        observed: 0)
    } else if let meta, meta.storeGeneration > 0, anchor == nil {
      throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
        expected: 0,
        observed: meta.storeGeneration)
    } else if requireInitialized, (anchor == nil) != (meta == nil) {
      throw TatwoDeviceTrustPinStoreError.storeNotInitialized
    }

    let pinPhase = try loadPinnedIdentitiesOnly()
    var pins = pinPhase.pins
    var rejectedRevocations = 0
    var applied = 0
    var maxAppliedRevocationEpoch: [String: UInt64] = [:]

    let revocationFiles = try listJSONFiles(in: revocationsDirectoryURL)
    for url in revocationFiles {
      do {
        let record = try readRevocationRecord(at: url)
        try verifyRevocationRecord(record)
        guard let target = pins[record.receipt.targetDeviceID] else {
          throw TatwoDeviceTrustPinStoreError.missingPin(record.receipt.targetDeviceID)
        }
        guard let authorizer = pins[record.receipt.authorizedByDeviceID] else {
          throw TatwoDeviceTrustPinStoreError.missingPin(
            record.receipt.authorizedByDeviceID)
        }
        // Active-status check in verifyRevocation would reject already-revoked
        // target pins after first load. If pin is already revoked with matching
        // key material, treat as applied; otherwise verify against active snapshot.
        if target.keyStatus == .revoked,
          target.keyID == record.receipt.targetKeyID,
          target.keyGeneration == record.receipt.targetKeyGeneration
        {
          applied += 1
          let prior = maxAppliedRevocationEpoch[record.receipt.targetDeviceID] ?? 0
          maxAppliedRevocationEpoch[record.receipt.targetDeviceID] = max(
            prior,
            record.receipt.authorityEpoch)
          continue
        }
        let activeTarget = TatwoDevicePublicIdentityV1(
          deviceID: target.deviceID,
          keyID: target.keyID,
          publicKey: target.publicKey,
          keyGeneration: target.keyGeneration,
          keyStatus: .active,
          pinnedAt: target.pinnedAt)
        let activeAuthorizer: TatwoDevicePublicIdentityV1
        if authorizer.keyStatus == .active {
          activeAuthorizer = authorizer
        } else {
          activeAuthorizer = TatwoDevicePublicIdentityV1(
            deviceID: authorizer.deviceID,
            keyID: authorizer.keyID,
            publicKey: authorizer.publicKey,
            keyGeneration: authorizer.keyGeneration,
            keyStatus: .active,
            pinnedAt: authorizer.pinnedAt)
        }
        try TatwoDeviceTrustAuthority.verifyRevocation(
          record.receipt,
          targetIdentity: activeTarget,
          authorizerIdentity: activeAuthorizer,
          expectedAuthorityEpoch: record.receipt.authorityEpoch)
        let revoked = TatwoDevicePublicIdentityV1(
          deviceID: activeTarget.deviceID,
          keyID: activeTarget.keyID,
          publicKey: activeTarget.publicKey,
          keyGeneration: activeTarget.keyGeneration,
          keyStatus: .revoked,
          pinnedAt: activeTarget.pinnedAt)
        pins[revoked.deviceID] = revoked
        applied += 1
        let prior = maxAppliedRevocationEpoch[revoked.deviceID] ?? 0
        maxAppliedRevocationEpoch[revoked.deviceID] = max(
          prior,
          record.receipt.authorityEpoch)
      } catch {
        rejectedRevocations += 1
        appendJournal(
          event: "revocation_load_rejected",
          deviceID: nil,
          reason: "invalid_store_record",
          detail: String(describing: error))
      }
    }

    if let anchor {
      for (deviceID, expectedEpoch) in anchor.deviceHighestRevocationEpoch
      where expectedEpoch > 0 {
        let seen = maxAppliedRevocationEpoch[deviceID] ?? 0
        if seen < expectedEpoch {
          throw TatwoDeviceTrustPinStoreError.missingRevocationTombstone(
            deviceID: deviceID,
            epoch: expectedEpoch)
        }
      }
      for (deviceID, highestKeyGen) in anchor.deviceHighestKeyGeneration
      where highestKeyGen > 0 {
        // Missing pin after per-entry reject stays untrusted (not whole-store fail).
        // Present pin with generation below high-water is rollback → fail closed.
        if let pin = pins[deviceID], pin.keyGeneration < highestKeyGen {
          throw TatwoDeviceTrustPinStoreError.storeGenerationRegression(
            expected: highestKeyGen,
            observed: pin.keyGeneration)
        }
      }
    }

    let storeGeneration = max(
      anchor?.storeGeneration ?? 0,
      meta?.storeGeneration ?? 0)

    return TatwoDeviceTrustPinStoreLoadResult(
      pins: pins,
      rejectedPinCount: pinPhase.rejected,
      rejectedRevocationCount: rejectedRevocations,
      appliedRevocationCount: applied,
      storeGeneration: storeGeneration)
  }

  public func listPins() throws -> [TatwoDeviceTrustPinListEntryV1] {
    let result = try load()
    return try result.pins.values
      .sorted { $0.deviceID < $1.deviceID }
      .map { identity in
        TatwoDeviceTrustPinListEntryV1(
          deviceID: identity.deviceID,
          keyID: identity.keyID,
          keyGeneration: identity.keyGeneration,
          keyStatus: identity.keyStatus,
          fingerprint: try Self.publicKeyFingerprint(of: identity),
          pinnedAt: identity.pinnedAt)
      }
  }

  // MARK: - Private load helpers

  private struct StoreMetaBody: Codable {
    let storeGeneration: UInt64
    let storeHostDeviceID: String
    let updatedAt: String
  }

  private struct StoreMetaRecord: Codable {
    let schema: String
    let storeGeneration: UInt64
    let storeHostDeviceID: String
    let updatedAt: String
    let authorization: TatwoDeviceSignatureV1
  }

  private func writePinnedIdentityRecord(
    _ identity: TatwoDevicePublicIdentityV1,
    storedAt: String
  ) throws {
    try TatwoDeviceTrustAuthority.validatePublicIdentity(identity)
    let body = PinRecordBody(
      identity: identity,
      storedAt: storedAt,
      storeHostDeviceID: localIdentity.deviceID)
    let payload = try Self.canonicalJSON(body)
    let authorization = try authority.sign(
      payload: payload,
      purpose: Self.pinRecordPurpose,
      identity: localIdentity,
      signedAt: storedAt)
    let record = TatwoDeviceTrustPinnedIdentityRecordV1(
      identity: identity,
      storedAt: storedAt,
      storeHostDeviceID: localIdentity.deviceID,
      authorization: authorization)
    try writeRecord(record, to: pinURL(forDeviceID: identity.deviceID))
  }

  private func bumpEpochAfterMutation(
    _ mutate: (inout TatwoDeviceTrustPinStoreEpochState) -> Void
  ) throws {
    var state = try epochAnchor.load() ?? .empty
    if state.storeGeneration == UInt64.max {
      throw TatwoDeviceTrustPinStoreError.storeAnchorRejected("storeGeneration overflow")
    }
    state.storeGeneration += 1
    mutate(&state)
    try epochAnchor.save(state)
    try writeStoreMeta(storeGeneration: state.storeGeneration)
  }

  private func writeStoreMeta(storeGeneration: UInt64) throws {
    let updatedAt = TatwoLoopJobChannelTrust.iso8601(Date())
    let body = StoreMetaBody(
      storeGeneration: storeGeneration,
      storeHostDeviceID: localIdentity.deviceID,
      updatedAt: updatedAt)
    let payload = try Self.canonicalJSON(body)
    let authorization = try authority.sign(
      payload: payload,
      purpose: Self.storeMetaPurpose,
      identity: localIdentity,
      signedAt: updatedAt)
    let record = StoreMetaRecord(
      schema: "TatwoDeviceTrustPinStoreMetaV1",
      storeGeneration: storeGeneration,
      storeHostDeviceID: localIdentity.deviceID,
      updatedAt: updatedAt,
      authorization: authorization)
    try writeRecord(record, to: storeMetaURL)
  }

  private func loadStoreMetaIfPresent() throws -> StoreMetaRecord? {
    guard FileManager.default.fileExists(atPath: storeMetaURL.path) else {
      return nil
    }
    try refuseSymlink(storeMetaURL)
    let data = try Data(contentsOf: storeMetaURL)
    let record = try JSONDecoder().decode(StoreMetaRecord.self, from: data)
    guard record.schema == "TatwoDeviceTrustPinStoreMetaV1" else {
      throw TatwoDeviceTrustPinStoreError.invalidStoreRecord("store-meta schema")
    }
    guard record.storeHostDeviceID == localIdentity.deviceID else {
      throw TatwoDeviceTrustPinStoreError.invalidStoreRecord("store-meta host")
    }
    let body = StoreMetaBody(
      storeGeneration: record.storeGeneration,
      storeHostDeviceID: record.storeHostDeviceID,
      updatedAt: record.updatedAt)
    let payload = try Self.canonicalJSON(body)
    try TatwoDeviceTrustAuthority.verify(
      payload: payload,
      purpose: Self.storeMetaPurpose,
      signature: record.authorization,
      pinnedIdentity: localIdentity)
    return record
  }

  private struct LoadedPins {
    let pins: [String: TatwoDevicePublicIdentityV1]
    let rejected: Int
  }

  private func loadPinnedIdentitiesOnly() throws -> LoadedPins {
    var pins: [String: TatwoDevicePublicIdentityV1] = [:]
    var rejected = 0
    let files = try listJSONFiles(in: pinsDirectoryURL)
    for url in files {
      do {
        let record = try readPinRecord(at: url)
        try verifyPinRecord(record)
        pins[record.identity.deviceID] = record.identity
      } catch {
        rejected += 1
        appendJournal(
          event: "pin_load_rejected",
          deviceID: url.deletingPathExtension().lastPathComponent,
          reason: "invalid_store_record",
          detail: String(describing: error))
      }
    }
    return LoadedPins(pins: pins, rejected: rejected)
  }

  private func verifyPinRecord(
    _ record: TatwoDeviceTrustPinnedIdentityRecordV1
  ) throws {
    guard record.schema == "TatwoDeviceTrustPinnedIdentityRecordV1" else {
      throw TatwoDeviceTrustPinStoreError.invalidStoreRecord("schema")
    }
    guard record.storeHostDeviceID == localIdentity.deviceID else {
      throw TatwoDeviceTrustPinStoreError.invalidStoreRecord("storeHostDeviceID")
    }
    try TatwoDeviceTrustAuthority.validatePublicIdentity(record.identity)
    let body = PinRecordBody(
      identity: record.identity,
      storedAt: record.storedAt,
      storeHostDeviceID: record.storeHostDeviceID)
    let payload = try Self.canonicalJSON(body)
    try TatwoDeviceTrustAuthority.verify(
      payload: payload,
      purpose: Self.pinRecordPurpose,
      signature: record.authorization,
      pinnedIdentity: localIdentity)
  }

  private func verifyRevocationRecord(
    _ record: TatwoDeviceTrustStoredRevocationRecordV1
  ) throws {
    guard record.schema == "TatwoDeviceTrustStoredRevocationRecordV1" else {
      throw TatwoDeviceTrustPinStoreError.invalidStoreRecord("schema")
    }
    guard record.storeHostDeviceID == localIdentity.deviceID else {
      throw TatwoDeviceTrustPinStoreError.invalidStoreRecord("storeHostDeviceID")
    }
    let body = RevocationRecordBody(
      receipt: record.receipt,
      storedAt: record.storedAt,
      storeHostDeviceID: record.storeHostDeviceID)
    let payload = try Self.canonicalJSON(body)
    try TatwoDeviceTrustAuthority.verify(
      payload: payload,
      purpose: Self.revocationRecordPurpose,
      signature: record.authorization,
      pinnedIdentity: localIdentity)
  }

  private func readPinRecord(
    at url: URL
  ) throws -> TatwoDeviceTrustPinnedIdentityRecordV1 {
    try refuseSymlink(url)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(
      TatwoDeviceTrustPinnedIdentityRecordV1.self,
      from: data)
  }

  private func readRevocationRecord(
    at url: URL
  ) throws -> TatwoDeviceTrustStoredRevocationRecordV1 {
    try refuseSymlink(url)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(
      TatwoDeviceTrustStoredRevocationRecordV1.self,
      from: data)
  }

  private func writeRecord<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if FileManager.default.fileExists(atPath: url.path) {
      try refuseSymlink(url)
    }
    let data = try Self.canonicalPrettyJSON(value)
    try TatwoAtomicFile.write(data, to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path)
  }

  private func pinURL(forDeviceID deviceID: String) throws -> URL {
    let token = try Self.fileToken(deviceID, field: "deviceID")
    return pinsDirectoryURL.appendingPathComponent("\(token).json", isDirectory: false)
  }

  private func revocationURL(
    for receipt: TatwoDeviceKeyRevocationReceiptV1
  ) throws -> URL {
    let target = try Self.fileToken(receipt.targetDeviceID, field: "targetDeviceID")
    let key = try Self.fileToken(receipt.targetKeyID, field: "targetKeyID")
    let name = "\(target)-\(key)-epoch-\(receipt.authorityEpoch).json"
    return revocationsDirectoryURL.appendingPathComponent(name, isDirectory: false)
  }

  private func listJSONFiles(in directory: URL) throws -> [URL] {
    let manager = FileManager.default
    guard manager.fileExists(atPath: directory.path) else {
      return []
    }
    try refuseSymlink(directory)
    let contents = try manager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    return contents
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func appendJournal(
    event: String,
    deviceID: String?,
    reason: String,
    detail: String?
  ) {
    let entry = TatwoDeviceTrustPinStoreJournalEntryV1(
      event: event,
      deviceID: deviceID,
      reason: reason,
      detail: detail,
      occurredAt: TatwoLoopJobChannelTrust.iso8601(Date()))
    do {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var line = try encoder.encode(entry)
      line.append(contentsOf: "\n".utf8)
      if FileManager.default.fileExists(atPath: journalURL.path) {
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      } else {
        try line.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: journalURL.path)
      }
    } catch {
      // Journal is best-effort; pin rejection already fail-closed.
    }
  }

  private func refuseSymlink(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    if values.isSymbolicLink == true {
      throw TatwoDeviceTrustPinStoreError.symlinkRefused(url.path)
    }
  }

  private static func fileToken(_ value: String, field: String) throws -> String {
    guard !value.isEmpty,
      !value.contains("/"),
      !value.contains("\\"),
      !value.contains("\0"),
      value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    else {
      throw TatwoDeviceTrustPinStoreError.unsafePath(field)
    }
    return value
  }

  private struct PinRecordBody: Codable {
    let identity: TatwoDevicePublicIdentityV1
    let storedAt: String
    let storeHostDeviceID: String
  }

  private struct RevocationRecordBody: Codable {
    let receipt: TatwoDeviceKeyRevocationReceiptV1
    let storedAt: String
    let storeHostDeviceID: String
  }

  private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func canonicalPrettyJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

extension TatwoDeviceTrustAuthority {
  /// Public validation entry used by the pin store (identity schema / key material).
  public static func validatePublicIdentity(
    _ identity: TatwoDevicePublicIdentityV1
  ) throws {
    // Mirror private validate() without exposing private helpers.
    guard identity.schema == "TatwoDevicePublicIdentityV1",
      identity.algorithm == "Ed25519",
      identity.keyGeneration > 0
    else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
    guard !identity.deviceID.isEmpty,
      !identity.deviceID.contains("\n"),
      !identity.deviceID.contains("\r"),
      !identity.deviceID.contains("\0"),
      !identity.keyID.isEmpty,
      !identity.pinnedAt.isEmpty
    else {
      throw TatwoDeviceTrustError.invalidIdentity
    }
    guard let publicKey = Data(base64Encoded: identity.publicKey),
      publicKey.count == 32,
      (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil
    else {
      throw TatwoDeviceTrustError.invalidPublicKey
    }
    let digest = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    guard identity.keyID == "ed25519-\(digest)" else {
      throw TatwoDeviceTrustError.invalidPublicKey
    }
  }
}
